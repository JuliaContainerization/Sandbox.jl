using Test, Sandbox

# The launcher's command line, as other callers than Sandbox.jl's own may use it.  Only
# against a binary built from this checkout, in each mode the host supports.
launcher_modes = Symbol[]
if should_build_local_sandbox && UserNSSandbox_jll.is_available()
    Sandbox.getuid() != 0 && push!(launcher_modes, :userns)
    Sys.which("sudo") !== nothing && success(`sudo -k -n true`) && push!(launcher_modes, :sudo)
end

function launcher_cmd(mode, args; env=String[])
    exe = UserNSSandbox_jll.sandbox_path
    if mode == :sudo
        args = `$(args[1:2]) --privileged $(args[3:end])`
        return `sudo -n /usr/bin/env -i PATH=/usr/bin:/bin $(env) SUDO_UID=$(Sandbox.getuid()) SUDO_GID=$(Sandbox.getgid()) $(exe) $(args)`
    end
    return setenv(`$(exe) $(args)`, ["PATH=/usr/bin:/bin"; env])
end

# Runs `script` in a sandbox of the debian rootfs with the operations `ops`, returning
# `(exitcode, stdout, stderr)`.
function launch(mode, ops, script="true"; options=``, env=String[])
    rootfs = Sandbox.debian_rootfs()
    cmd = launcher_cmd(mode, `--rootfs $(rootfs) $(options) $(ops) -- /bin/sh -c $(script)`; env)
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(cmd); stdout=out, stderr=err))
    return p.exitcode, String(take!(out)), String(take!(err))
end

for mode in launcher_modes
    @testset "launcher operations ($(mode))" begin
        @testset "malformed requests" begin
            rootfs = Sandbox.debian_rootfs()
            for (args, message) in [
                    `--rootfs $(rootfs) --no-such-op /x -- /bin/true` => "unknown option",
                    `--rootfs $(rootfs) --bind /tmp -- /bin/true` => "takes more arguments",
                    `--rootfs $(rootfs) --bind /tmp` => "takes more arguments",
                    `--rootfs $(rootfs) /bin/true` => "unknown option",
                    `--rootfs $(rootfs) --` => "no command",
                    `-- /bin/true` => "--rootfs is required",
                    `--rootfs $(rootfs) --rootfs $(rootfs) -- /bin/true` => "more than once",
                    `--rootfs $(rootfs) --uid -1 -- /bin/true` => "invalid uid",
                    `--rootfs $(rootfs) --gid 1x -- /bin/true` => "invalid gid",
                    `--rootfs $(rootfs) --bind tmp /x -- /bin/true` => "not absolute",
                    `--rootfs $(rootfs) --bind /tmp x -- /bin/true` => "not absolute",
                    `--rootfs $(rootfs) --tmpfs /proc/x mode=755 -- /bin/true` => "in /proc",
                    `--rootfs $(rootfs) --tmpfs /x/../proc/sys mode=755 -- /bin/true` => "in /proc",
                    `--rootfs $(rootfs) --symlink /proc /p --tmpfs /p/sys mode=755 -- /bin/true` => "in /proc",
                    `--rootfs $(rootfs) --symlink /proc /p --symlink x /p/self/y -- /bin/true` => "in /proc",
                    `--rootfs $(rootfs) --symlink /proc /p --bind /etc/hostname /p/version -- /bin/true` => "in /proc",
                    `--rootfs $(rootfs) --overlay /tmp /x --overlay /tmp /x -- /bin/true` => "more than one overlay",
                ]
                err = IOBuffer()
                p = run(pipeline(ignorestatus(launcher_cmd(mode, `$(args)`)); stderr=err))
                @test p.exitcode == 125
                @test occursin(message, String(take!(err)))
            end
        end

        @testset "order" begin
            mktempdir() do dir
                a, b = joinpath(dir, "a"), joinpath(dir, "b")
                mkdir(a); write(joinpath(a, "f"), "a")
                mkdir(b); write(joinpath(b, "f"), "b")
                # The later of two mounts at the same destination is the one that shows
                code, out, err = launch(mode, `--bind $(a) /m --bind $(b) /m --ro-bind $(a) /m/sub`,
                                        "cat /m/f /m/sub/f")
                @test (code, out) == (0, "ba")
                # A mount at a parent covers what was mounted below it before
                code, out, err = launch(mode, `--bind $(a) /m/sub --tmpfs /m mode=0700`,
                                        "stat -c %a /m; ls -A /m")
                @test (code, out) == (0, "700\n")
                code, out, err = launch(mode, `--tmpfs /m mode=0700 --bind $(a) /m/sub`, "cat /m/sub/f")
                @test (code, out) == (0, "a")
            end
        end

        @testset "tmpfs" begin
            code, out, err = launch(mode, `--tmpfs /t mode=1777,size=1m`,
                                    "stat -c %a /t; yes | head -c 2000000 > /t/f")
            @test code != 0
            @test startswith(out, "1777\n")
            @test occursin("No space left on device", err)
            code, out, err = launch(mode, `--tmpfs /t no-such-option`)
            @test code == 125
            @test occursin("Failed to mount a tmpfs at '/t'", err)
        end

        @testset "symlinks" begin
            mktempdir() do dir
                code, out, err = launch(mode, `--symlink /etc/hostname /l --symlink /etc/hostname /l`,
                                        "readlink /l")
                @test (code, out) == (0, "/etc/hostname\n")
                code, out, err = launch(mode, `--symlink a /l --symlink b /l`)
                @test code == 125
                @test occursin("something else is there", err)
                # A symlink on the way leads to a path in the root, not on the host
                code, out, err = launch(mode, `--tmpfs /t mode=0755 --symlink $(dir) /t/esc --symlink x /t/esc/l`,
                                        "readlink $(dir)/l")
                @test (code, out) == (0, "x\n")
                @test isempty(readdir(dir))
            end
        end

        @testset "binds" begin
            # Device nodes only work in dev- binds, and setuid bits never do
            code, out, err = launch(mode, `--bind /dev/null /dev/null`, "echo x > /dev/null")
            @test code != 0
            @test occursin("Permission denied", err)
            code, out, err = launch(mode, `--dev-bind /dev/null /dev/null`, "echo x > /dev/null && echo ok")
            @test (code, out) == (0, "ok\n")
            options(dest) = "grep ' $(dest) ' /proc/self/mounts | cut -d' ' -f4"
            mktempdir() do dir
                code, out, err = launch(mode, `--bind $(dir) /a --dev-bind $(dir) /b --ro-dev-bind $(dir) /c`,
                                        "$(options("/a")); $(options("/b")); $(options("/c"))")
                @test code == 0
                a, b, c = split.(split(out), ',')
                @test "nosuid" in a && "nodev" in a && "rw" in a
                @test "nosuid" in b && ("nodev" in b) == ("nodev" in split(readchomp(`findmnt -no OPTIONS --target $(dir)`), ','))
                @test "nosuid" in c && "ro" in c
            end
            # Including the mounts below the bind (mounting them on the host takes root),
            # also without mount_setattr(2), as before Linux 5.12
            if :sudo in launcher_modes
                mktempdir() do dir
                    sub = mkdir(joinpath(dir, "sub"))
                    run(`sudo -n mount -t tmpfs none $(sub)`)
                    try
                        @testset "mount_setattr: $(setattr)" for setattr in ("1", "0")
                            code, out, err = launch(mode, `--bind $(dir) /a --dev-bind $(dir) /b`,
                                                    "$(options("/a/sub")); $(options("/b/sub"))";
                                                    env=["SANDBOX_MOUNT_SETATTR=$(setattr)"])
                            @test code == 0
                            a, b = split.(split(out), ',')
                            @test "nosuid" in a && "nodev" in a
                            @test "nosuid" in b && "nodev" ∉ b
                        end
                    finally
                        run(`sudo -n umount $(sub)`)
                    end
                end
            end
            code, out, err = launch(mode, `--ro-bind /etc /m`, "touch /m/x")
            @test code != 0
            @test occursin("Read-only file system", err)
            code, out, err = launch(mode, `--bind-try /does/not/exist /m`, "test -e /m || echo skipped")
            @test (code, out) == (0, "skipped\n")
            code, out, err = launch(mode, `--bind /does/not/exist /m`)
            @test code == 125
            @test occursin("Failed to open '/does/not/exist'", err)
            code, out, err = launch(mode, `--tmpfs /x/.. mode=0755`)
            @test code == 125
            @test occursin("it is the root of the sandbox", err)
        end

        @testset "devpts and cgroup at other places" begin
            code, out, err = launch(mode, `--devpts /pts --cgroup /cg`,
                                    "stat -f -c %T /pts /cg; grep ' /cg ' /proc/self/mounts | cut -d' ' -f4 | cut -d, -f1")
            @test code == 0
            lines = split(out)
            @test lines[1] == "devpts"
            @test lines[2] in ("cgroup2fs", "tmpfs")
            @test lines[end] == "ro"
        end

        @testset "overlays" begin
            mktempdir() do dir
                lower, empty, persist = joinpath(dir, "lower"), joinpath(dir, "empty"), joinpath(dir, "persist")
                mkdir(lower); mkdir(empty)
                write(joinpath(lower, "f"), "lower")
                code, out, err = launch(mode, `--overlay $(lower) /o`, "echo changed > /o/f; cat /o/f";
                                        options=`--persist $(persist)`)
                @test (code, out) == (0, "changed\n")
                @test read(joinpath(lower, "f"), String) == "lower"
                # A read-only overlay at the same place shows what the earlier one persisted
                code, out, err = launch(mode, `--ro-overlay $(empty) /o`, "cat /o/f; touch /o/g";
                                        options=`--persist $(persist)`)
                @test code != 0
                @test out == "changed\n"
                @test occursin("Read-only file system", err)
                run(mode == :sudo ? `sudo -n rm -rf $(persist)` : `chmod -R u+rwX $(persist)`)
            end

            # The persist directory records how overlayfs's xattrs are kept, and a
            # sandbox that can't read them that way refuses it
            mktempdir() do dir
                persist = joinpath(dir, "persist")
                code, out, err = launch(mode, ``; options=`--persist $(persist)`)
                @test code == 0
                # (`userxattr` needs Linux 5.11, and real root does without it)
                @test read(joinpath(persist, "xattrs"), String) in ("user\n", mode == :sudo ? "trusted\n" : "user\n")
                @test launch(mode, ``; options=`--persist $(persist)`)[1] == 0
                persist = joinpath(dir, "other")
                mkdir(persist)
                for (xattrs, ok) in ("bogus\n" => false, "trusted\n" => mode == :sudo,
                                     "trusted-userns\n" => mode == :userns)
                    write(joinpath(persist, "xattrs"), xattrs)
                    code, out, err = launch(mode, ``; options=`--persist $(persist)`)
                    @test (code == 0) == ok
                    ok || @test occursin("can't read them", err)
                end
                # Changes that don't say how they were made
                rm(joinpath(persist, "xattrs"))
                code, out, err = launch(mode, ``; options=`--persist $(persist)`)
                @test code == 125
                @test occursin("no `xattrs`", err)
                run(mode == :sudo ? `sudo -n rm -rf $(dir)/persist $(dir)/other` : `chmod -R u+rwX $(dir)`)
            end

            # One sandbox at a time per persist directory
            mktempdir() do dir
                persist = joinpath(dir, "persist")
                rootfs = Sandbox.debian_rootfs()
                first = launcher_cmd(mode, `--rootfs $(rootfs) --persist $(persist) -- /bin/sh -c 'echo up; read x; true'`)
                p = open(first, "r+")
                try
                    @test readline(p) == "up"
                    code, out, err = launch(mode, ``; options=`--persist $(persist)`)
                    @test code == 125
                    @test occursin("in use by another sandbox", err)
                finally
                    close(p.in)
                    wait(p)
                end
                @test success(p)
                @test launch(mode, ``; options=`--persist $(persist)`)[1] == 0
                run(mode == :sudo ? `sudo -n rm -rf $(persist)` : `chmod -R u+rwX $(persist)`)
            end

            # Overlays at different places keep their changes apart.  These two
            # destinations had the same 32-bit hash in the name of their state.
            mktempdir() do dir
                lower, persist = joinpath(dir, "lower"), joinpath(dir, "persist")
                mkdir(lower)
                code, out, err = launch(mode, `--overlay $(lower) /d248049/o --overlay $(lower) /d276786/o`,
                                        "echo a > /d248049/o/f; ls /d276786/o"; options=`--persist $(persist)`)
                @test (code, out) == (0, "")
                run(mode == :sudo ? `sudo -n rm -rf $(persist)` : `chmod -R u+rwX $(persist)`)
            end
        end
    end
end
