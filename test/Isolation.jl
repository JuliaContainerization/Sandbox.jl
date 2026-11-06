using Test, Sandbox

# These tests cover behaviour of the sandbox binary that the released UserNSSandbox_jll
# does not have yet, so they only run against a binary built from this checkout.  Where
# an executor can run, a sandbox that fails to start must fail the tests rather than
# drop the executor from them, so only the host's support is checked up front.
userns_executors = Type{<:UserNamespacesExecutor}[]
if should_build_local_sandbox && UserNSSandbox_jll.is_available() &&
   Sandbox.check_kernel_version() && Sandbox.check_overlayfs_loaded()
    if Sandbox.getuid() != 0
        push!(userns_executors, UnprivilegedUserNamespacesExecutor)
    end
    if Sys.which("sudo") !== nothing && success(`sudo -k -n true`)
        push!(userns_executors, PrivilegedUserNamespacesExecutor)
    end
    for executor in userns_executors
        @test executor_available(executor)
    end
end

# Run a shell script in the sandbox, returning `(success, stdout, stderr)`.
function sandbox_sh(executor, script; mounts=Dict{String,MountInfo}(), kwargs...)
    stdout, stderr = IOBuffer(), IOBuffer()
    config = SandboxConfig(
        Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed), mounts...),
        Dict("PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        stdout, stderr, persist=false, kwargs...,
    )
    ok = with_executor(executor) do exe
        success(exe, config, ignorestatus(`/bin/sh -c $(script)`))
    end
    return ok, String(take!(stdout)), String(take!(stderr))
end

host_cgroup2 = any(eachline("/proc/self/mounts")) do line
    fields = split(line)
    return fields[2] == "/sys/fs/cgroup" && fields[3] == "cgroup2"
end
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

for executor in userns_executors
    @testset "$(executor) isolation" begin
        @testset "file maps create parent directories" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                ok, out, err = sandbox_sh(executor, "cat /does/not/exist/note.txt";
                    mounts=Dict("/does/not/exist/note.txt" => MountInfo(joinpath(dir, "note.txt"), MountType.ReadOnly)))
                @test ok
                @test out == "great success"
                @test isempty(err)
            end
        end

        @testset "map destinations are resolved in the rootfs" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                note = MountInfo(joinpath(dir, "note.txt"), MountType.ReadOnly)
                host_target = joinpath(dir, "created_by_sandbox")
                stdout, stderr = IOBuffer(), IOBuffer()
                config(mounts...) = SandboxConfig(
                    Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed), mounts...),
                    Dict("PATH" => "/usr/bin:/bin");
                    stdout, stderr, persist=true,
                )
                with_executor(executor) do exe
                    # Symlinks left behind by an earlier run: one pointing at the host
                    # path, a dangling relative one like Ubuntu's /etc/resolv.conf, and
                    # one to the root
                    @test success(exe, config(), `/bin/sh -c """
                        ln -s $(host_target) /escape
                        ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
                        ln -s / /root_alias
                        """`)
                    @test success(exe, config("/escape" => note, "/etc/resolv.conf" => note),
                                  `/bin/sh -c "cat /escape; cat /etc/resolv.conf"`)
                    # A map cannot replace the root, even with a working rootfs
                    @test !success(exe, config("/root_alias" => MountInfo(Sandbox.debian_rootfs(), MountType.ReadOnly)),
                                   `/bin/true`)
                end
                @test String(take!(stdout)) == "great success"^2
                @test occursin("it is the root of the sandbox", String(take!(stderr)))
                @test !ispath(host_target)
            end
        end

        @testset "maps of any host path" begin
            # Without `persist`, the rootfs changes go in a tmpfs, which must not hide
            # a host directory from the maps
            ok, out, err = sandbox_sh(executor, "test -x /hostbin/sh && echo found";
                mounts=Dict("/hostbin" => MountInfo("/bin", MountType.ReadOnly)))
            @test ok
            @test out == "found\n"
        end

        @testset "no mount propagation from the host" begin
            # None of the sandbox's mounts is a peer or slave of a host mount
            ok, out, err = sandbox_sh(executor, "grep -cE ' (shared|master):' /proc/self/mountinfo")
            @test out == "0\n"
        end

        @testset "private IPC namespace and /dev/shm" begin
            # A marker in the host's /dev/shm must not be visible inside
            marker = "sandbox-isolation-test-$(getpid())"
            host_shm = isdir("/dev/shm") ? joinpath("/dev/shm", marker) : nothing
            host_shm === nothing || touch(host_shm)
            try
                ok, out, err = sandbox_sh(executor, """
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
            @test sandbox_sh(executor, script; shm_size="32M")[1]
            ok, out, err = sandbox_sh(executor, script; shm_size="8M")
            @test !ok
            @test occursin("No space left on device", err)
        end

        @testset "cgroup namespace and read-only cgroup2 view" begin
            ok, out, err = sandbox_sh(executor, """
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
                # the unprivileged executor is ours.
                if executor == UnprivilegedUserNamespacesExecutor
                    @test Set(split(lines[5])) == Set(readdir(host_cgroup_dir()))
                end

                # Neither limits nor membership can be changed through it
                @test !sandbox_sh(executor, "echo max > /sys/fs/cgroup/memory.max")[1]
                @test !sandbox_sh(executor, "echo \$\$ > /sys/fs/cgroup/cgroup.procs")[1]
                @test !sandbox_sh(executor, "mkdir /sys/fs/cgroup/child")[1]
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
                ok, out, err = sandbox_sh(executor, script)
                @test !ok
                ok && @error("Escape '$(name)' succeeded", script, out, err)
            end

            # Things that still work: being root with all capabilities in the (nested)
            # user namespace, mounting things of our own, including a procfs for our PID
            # namespace (as a nested sandbox in privileged mode does), and setting the
            # hostname.
            all_caps = string((UInt64(1) << (parse(Int, readchomp("/proc/sys/kernel/cap_last_cap")) + 1)) - 1;
                              base=16, pad=16)
            ok, out, err = sandbox_sh(executor, """
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
                    config = SandboxConfig(
                        Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed),
                             "/info" => MountInfo(dir, MountType.ReadOnly)),
                        Dict("PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
                        persist=false,
                    )
                    with_executor(executor) do exe
                        inner = Sandbox.build_executor_command(exe, config, `/bin/sh -c $(delegated_escapes)`)
                        cmd = `systemd-run --user --scope --quiet -p Delegate=yes /bin/bash $(driver) $(inner.exec)`
                        # systemd-run needs to reach the user manager
                        env = copy(something(inner.env, String[]))
                        for var in ("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
                            haskey(ENV, var) && push!(env, "$(var)=$(ENV[var])")
                        end
                        run(pipeline(setenv(cmd, env); stdout, stderr))
                    end
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
