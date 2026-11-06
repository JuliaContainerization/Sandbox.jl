using Test, Sandbox

using Sandbox: command

# Run a shell script in the sandbox, returning `(success, stdout, stderr)`.
function sandbox_sh(mode, script; mounts=Pair{String,Sandbox.Mount}[], env=Dict{String,String}(), kwargs...)
    config = SandboxConfig(; rootfs=Sandbox.debian_rootfs(), mode, mounts,
                           env=Dict("PATH" => default_path, env...), kwargs...)
    p, out, err = sandbox_run(config, `/bin/sh -c $(script)`)
    return success(p), out, err
end

host_cgroup2 = any(eachline("/proc/self/mounts")) do line
    fields = split(line)
    return fields[2] == "/sys/fs/cgroup" && fields[3] == "cgroup2"
end
host_sys_submounts = any(l -> startswith(split(l)[2], "/sys/"), eachline("/proc/self/mounts"))
host_cgroup_dir() = "/sys/fs/cgroup" * replace(readline("/proc/self/cgroup"), r"^0::" => "")

# A cgroup delegated to us, laid out like a job scheduler's: the scheduler in `sup/`, the
# sandbox in `job/`, another job in `other/`.  Needs a systemd user manager, and nsdelegate
# for the kernel to treat a cgroup namespace as a delegation boundary.
delegation_available = host_cgroup2 &&
    any(l -> occursin(r" /sys/fs/cgroup cgroup2 \S*\bnsdelegate\b", l), eachline("/proc/self/mounts")) &&
    Sys.which("systemd-run") !== nothing &&
    success(pipeline(`systemd-run --user --scope --quiet true`; stdout=devnull, stderr=devnull))
const delegated_driver = raw"""
    set -eu
    root=/sys/fs/cgroup$(sed 's/^0:://' /proc/self/cgroup)
    mkdir "$root/sup" "$root/job" "$root/other"
    echo "${root#/sys/fs/cgroup}" > "$(dirname "$0")/cgroup"
    echo $$ > "$root/sup/cgroup.procs"
    echo +memory +pids > "$root/cgroup.subtree_control"
    echo 1G > "$root/job/memory.max"
    echo 1G > "$root/other/memory.max"
    sh -c 'echo $$ > "$1/job/cgroup.procs"; shift; exec "$@"' sh "$root" "$@" || true
    mapfile -t sup < "$root/sup/cgroup.procs"
    echo "job=$(cat "$root/job/memory.max") other=$(cat "$root/other/memory.max") sup=${#sup[@]}" >&2
    """
# Attempts to change limits or leave the job cgroup, each of which ends by reporting the
# cgroup it is in.  `$CG` is the job's parent cgroup as seen on the host.
const delegated_escapes = raw"""
    export CG=$(cat /info/cgroup)
    try() { sh -c "{ $1; } >/dev/null 2>&1; echo \$(cat /proc/self/cgroup) $2"; }
    try 'echo max > /sys/fs/cgroup/memory.max' own-limit
    try 'umount -l /sys/fs/cgroup; echo max > /sys/fs/cgroup$CG/other/memory.max' umount-sibling
    try 'umount -l /sys/fs/cgroup; echo $$ > /sys/fs/cgroup$CG/sup/cgroup.procs' umount-escape
    try 'mkdir -p /tmp/s && mount --rbind /sys /tmp/s && umount -l /tmp/s/fs/cgroup; echo max > /tmp/s/fs/cgroup$CG/other/memory.max' rbind-sibling
    try 'mkdir -p /tmp/c && mount -t cgroup2 none /tmp/c && echo max > /tmp/c$CG/other/memory.max' mount-sibling
    try 'mkdir -p /tmp/c && unshare -C sh -c "mount -t cgroup2 none /tmp/c && echo max > /tmp/c/memory.max"' cgroupns-own-limit
    echo "$(cat /proc/self/cgroup) end"
    """

for mode in modes
    @testset "isolation ($(mode))" begin
        @testset "file maps create parent directories" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                ok, out, err = sandbox_sh(mode, "cat /does/not/exist/note.txt";
                    mounts=["/does/not/exist/note.txt" => Bind(joinpath(dir, "note.txt"))])
                @test ok
                @test out == "great success"
                @test isempty(err)
            end
        end

        @testset "map destinations are resolved in the rootfs" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                note = Bind(joinpath(dir, "note.txt"))
                host_target = joinpath(dir, "created_by_sandbox")
                persist = new_persist_dir()
                config(mounts...) = SandboxConfig(; rootfs=Sandbox.debian_rootfs(), mode, persist,
                                                  mounts=collect(mounts), env=Dict("PATH" => "/usr/bin:/bin"))
                try
                    # Symlinks left behind by an earlier run: one pointing at the host
                    # path, a dangling relative one like Ubuntu's /etc/resolv.conf, and
                    # one to the root
                    @test success(run(config(), `/bin/sh -c """
                        ln -s $(host_target) /escape
                        ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                        ln -s / /root_alias
                        """`))
                    p, out, err = sandbox_run(config("/escape" => note, "/etc/resolv.conf" => note),
                                              `/bin/sh -c "cat /escape; cat /etc/resolv.conf"`)
                    @test out == "great success"^2
                    # A map cannot replace the root, even with a working rootfs
                    p, out, err = sandbox_run(config("/root_alias" => Bind(Sandbox.debian_rootfs())), `/bin/true`)
                    @test !success(p)
                    @test occursin("it is the root of the sandbox", err)
                finally
                    remove_persist(persist, mode)
                end
                @test !ispath(host_target)
            end
        end

        @testset "maps of any host path" begin
            # Without `persist`, the rootfs changes go in a tmpfs, which must not hide
            # a host directory from the maps
            ok, out, err = sandbox_sh(mode, "test -x /hostbin/sh && echo found";
                mounts=["/hostbin" => Bind("/bin")])
            @test ok
            @test out == "found\n"
        end

        @testset "no host processes below /proc" begin
            # The procfs of the command's PID namespace is its own to unmount, which must
            # not reveal a procfs of the host's
            host_init = replace(read("/proc/1/cmdline", String), '\0' => ' ')
            ok, out, err = sandbox_sh(mode, "umount /proc && tr '\\0' ' ' < /proc/1/cmdline")
            @test ok
            @test !isempty(out)
            @test out != host_init
        end

        @testset "no mount propagation from the host" begin
            # None of the sandbox's mounts is a peer or slave of a host mount
            ok, out, err = sandbox_sh(mode, "grep -cE ' (shared|master):' /proc/self/mountinfo")
            @test out == "0\n"
        end

        # SANDBOX_MOUNT_SETATTR=0 has the launcher do without mount_setattr(2), as on
        # kernels before 5.12
        @testset "read-only maps include their submounts (mount_setattr: $(setattr))" for setattr in ("1", "0")
            env = Dict("SANDBOX_MOUNT_SETATTR" => setattr)
            # mounts below `dir` that are not read-only
            writable(dir) = "awk '(\$2 == \"$(dir)\" || \$2 ~ \"^$(dir)/\") && \$4 !~ /^ro(,|\$)/' /proc/self/mounts"
            ok, out, err = sandbox_sh(mode, writable("/sys"); env)
            @test ok
            @test out == ""

            if host_sys_submounts
                ok, out, err = sandbox_sh(mode, """
                    grep -c ' /hostsys/' /proc/self/mounts
                    $(writable("/hostsys"))
                    """; env, mounts=["/hostsys" => Bind("/sys")])
                @test ok
                @test parse(Int, readline(IOBuffer(out))) > 0
                @test countlines(IOBuffer(out)) == 1
            end

            # Nested mounts at a path that /proc/self/mountinfo shows longer than
            # PATH_MAX, as it escapes spaces (mounting them on the host takes root)
            if :sudo in modes
                mktempdir() do dir
                    rel = joinpath(fill(" "^64, 20)...)
                    outer = joinpath(dir, rel)
                    inner = joinpath(outer, "inner")
                    mkpath(outer)
                    run(`sudo -n mount -t tmpfs -o mode=1777 none $(outer)`)
                    try
                        mkdir(inner)
                        run(`sudo -n mount -t tmpfs -o mode=1777 none $(inner)`)
                        for path in (joinpath("/m", rel, "x"), joinpath("/m", rel, "inner", "x"))
                            ok, out, err = sandbox_sh(mode, "touch '$(path)'"; env,
                                mounts=["/m" => Bind(dir)])
                            @test !ok
                            @test occursin("Read-only file system", err)
                        end
                    finally
                        run(`sudo -n umount -R $(outer)`)
                    end
                end
            end
        end

        @testset "no device nodes or setuid in the image" begin
            # A world-writable device node, as an image could contain (making one
            # takes root, which we have if the sudo mode is tested)
            if :sudo in modes
                mktempdir() do dir
                    node = joinpath(dir, "null")
                    run(`sudo -n mknod -m 666 $(node) c 1 3`)
                    try
                        ok, out, err = sandbox_sh(mode, "echo > /image/null";
                            mounts=["/image" => Overlay(dir)])
                        @test !ok
                        @test occursin("Permission denied", err)
                    finally
                        run(`sudo -n rm $(node)`)
                    end
                end
            end
            ok, out, err = sandbox_sh(mode, "grep -E ' / ' /proc/self/mounts | tail -n 1")
            @test ok
            @test issubset(["nodev", "nosuid"], split(split(out)[4], ','))
        end

        # Only for callers that do not have root's identity themselves
        if :sudo in modes &&
           Sandbox.getuid() != 0 && Sandbox.getgid() != 0
            @testset "no supplementary groups of root" begin
                # A host file that only root and its group can read
                mktempdir() do dir
                    secret = joinpath(dir, "secret")
                    write(secret, "secret")
                    run(`sudo -n chown root:root $(secret)`)
                    run(`sudo -n chmod 640 $(secret)`)
                    try
                        ok, out, err = sandbox_sh(mode, "cat /m/secret";
                            mounts=["/m" => Bind(dir)])
                        @test !ok
                        @test occursin("Permission denied", err)
                    finally
                        run(`sudo -n rm $(secret)`)
                    end
                end
            end
        end

        @testset "private IPC namespace and /dev/shm" begin
            # A marker in the host's /dev/shm must not be visible inside
            marker = "sandbox-isolation-test-$(getpid())"
            host_shm = isdir("/dev/shm") ? joinpath("/dev/shm", marker) : nothing
            host_shm === nothing || touch(host_shm)
            try
                ok, out, err = sandbox_sh(mode, """
                    readlink /proc/self/ns/ipc
                    stat -f -c %T /dev/shm
                    stat -c %a /dev/shm
                    ls -A /dev/shm
                    """)
                @test ok
                lines = split(out, '\n')
                @test lines[1] != readlink("/proc/self/ns/ipc")
                @test lines[2] == "tmpfs"
                @test lines[3] == "1777"
                @test lines[4] == ""
            finally
                host_shm === nothing || rm(host_shm; force=true)
            end

            # The size of /dev/shm can be limited
            script = "dd if=/dev/zero of=/dev/shm/blob bs=1M count=16"
            @test sandbox_sh(mode, script; mounts=["/dev/shm" => Tmpfs(size="32M", mode=0o1777)])[1]
            ok, out, err = sandbox_sh(mode, script; mounts=["/dev/shm" => Tmpfs(size="8M", mode=0o1777)])
            @test !ok
            @test occursin("No space left on device", err)
        end

        @testset "cgroup namespace and read-only cgroup2 view" begin
            ok, out, err = sandbox_sh(mode, """
                readlink /proc/self/ns/cgroup
                grep '^0::' /proc/self/cgroup || echo none
                stat -f -c %T /sys/fs/cgroup
                grep ' /sys/fs/cgroup ' /proc/self/mounts | tail -n 1 | cut -d' ' -f3,4
                ls -A /sys/fs/cgroup | tr '\\n' ' '
                """)
            @test ok
            lines = split(out, '\n')
            @test lines[1] != readlink("/proc/self/ns/cgroup")
            if host_cgroup2
                @test lines[2] == "0::/"
                @test lines[3] == "cgroup2fs"
                fstype, options = split(lines[4])
                @test fstype == "cgroup2"
                @test "ro" in split(options, ',')
                # The view is rooted at the cgroup the sandbox was started in, which for
                # the :userns mode is ours.
                if mode == :userns
                    @test Set(split(lines[5])) == Set(readdir(host_cgroup_dir()))
                end

                # Neither limits nor membership can be changed through it
                @test !sandbox_sh(mode, "echo max > /sys/fs/cgroup/memory.max")[1]
                @test !sandbox_sh(mode, "echo \$\$ > /sys/fs/cgroup/cgroup.procs")[1]
                @test !sandbox_sh(mode, "mkdir /sys/fs/cgroup/child")[1]
            else
                @test lines[3] == "tmpfs"
                @test isempty(strip(lines[5]))
            end
        end

        @testset "mounts are locked" begin
            # Each of these would reveal or reopen the host's cgroup hierarchy
            escapes = [
                "umount" => "umount /sys/fs/cgroup",
                "lazy umount" => "umount -l /sys/fs/cgroup",
                "remount rw" => "mount -o remount,bind,rw /sys/fs/cgroup",
                "remount /sys rw" => "mount -o remount,bind,rw /sys",
                "cgroup2 elsewhere" => "mkdir -p /tmp/cg && mount -t cgroup2 none /tmp/cg",
                "rbind /sys, umount" => "mkdir -p /tmp/sys && mount --rbind /sys /tmp/sys && umount /tmp/sys/fs/cgroup",
                "rbind /sys, remount rw" => "mkdir -p /tmp/sys && mount --rbind /sys /tmp/sys && mount -o remount,bind,rw /tmp/sys/fs/cgroup",
                # A cgroup namespace of our own may be mounted, but it is rooted at (or
                # below) our cgroup, whose limits nsdelegate keeps out of reach
                "own cgroupns" => "mkdir -p /tmp/cg && unshare -C sh -c 'mount -t cgroup2 none /tmp/cg && echo max > /tmp/cg/memory.max'",
            ]
            for (name, script) in escapes
                ok, out, err = sandbox_sh(mode, script)
                @test !ok
                ok && @error("Escape '$(name)' succeeded", script, out, err)
            end

            # Things that still work: being root with all capabilities in the (nested)
            # user namespace, mounting things of our own, including a procfs for our PID
            # namespace (as a nested sandbox in privileged mode does), and setting the
            # hostname.
            all_caps = string((UInt64(1) << (parse(Int, readchomp("/proc/sys/kernel/cap_last_cap")) + 1)) - 1;
                              base=16, pad=16)
            ok, out, err = sandbox_sh(mode, """
                id -u
                grep CapEff /proc/self/status | cut -f2
                mkdir -p /tmp/t && mount -t tmpfs none /tmp/t && echo mounted
                mount -t proc proc /tmp/t && echo proc
                hostname changed && hostname
                """; hostname="sandy")
            @test ok
            @test split(out) == ["0", all_caps, "mounted", "proc", "changed"]
            @test isempty(err)
        end

        if delegation_available
            @testset "delegated cgroup" begin
                mktempdir() do dir
                    driver = joinpath(dir, "driver.sh")
                    write(driver, delegated_driver)
                    stdout, stderr = IOBuffer(), IOBuffer()
                    config = SandboxConfig(; rootfs=Sandbox.debian_rootfs(), mode,
                                           mounts=["/info" => Bind(dir)], env=Dict("PATH" => default_path))
                    inner = command(config, `/bin/sh -c $(delegated_escapes)`)
                    cmd = `systemd-run --user --scope --quiet -p Delegate=yes /bin/bash $(driver) $(inner.exec)`
                    # systemd-run needs to reach the user manager
                    env = copy(inner.env)
                    for var in ("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
                        haskey(ENV, var) && push!(env, "$(var)=$(ENV[var])")
                    end
                    run(pipeline(setenv(cmd, env); stdout, stderr))
                    out, err = String(take!(stdout)), String(take!(stderr))
                    results = split(strip(out), '\n')
                    @test length(results) == 7
                    for line in results
                        cgroup, name = split(line)
                        @test cgroup == "0::/"
                        cgroup == "0::/" || @error("Escape '$(name)' left the job cgroup", cgroup)
                    end
                    m = match(r"job=(\S+) other=(\S+) sup=(\d+)", err)
                    @test m !== nothing
                    if m !== nothing
                        @test m[1] == "1073741824"
                        @test m[2] == "1073741824"
                        # only the driver itself
                        @test m[3] == "1"
                    end
                end
            end
        end
    end
end
