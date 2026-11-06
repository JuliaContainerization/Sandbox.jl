using Test, Sandbox

# The launcher's command line, as other callers than Sandbox.jl's own may use it.  Only
# against a binary built from this checkout, in each mode the host supports.
launcher_modes = Symbol[]
if should_build_local_sandbox && UserNSSandbox_jll.is_available()
    Sandbox.getuid() != 0 && push!(launcher_modes, :userns)
    Sys.which("sudo") !== nothing && success(`sudo -k -n true`) && push!(launcher_modes, :sudo)
end

function launcher_cmd(mode, args)
    exe = UserNSSandbox_jll.sandbox_path
    if mode == :sudo
        return `sudo -n /usr/bin/env -i PATH=/usr/bin:/bin SUDO_UID=$(Sandbox.getuid()) SUDO_GID=$(Sandbox.getgid()) FORCE_SANDBOX_MODE=privileged $(exe) $(args)`
    end
    return setenv(`$(exe) $(args)`, "PATH" => "/usr/bin:/bin", "FORCE_SANDBOX_MODE" => "unprivileged")
end

# Runs `script` in a sandbox of the debian rootfs with the operations `ops`, returning
# `(exitcode, stdout, stderr)`.
function launch(mode, ops, script="true"; options=``)
    rootfs = Sandbox.debian_rootfs()
    cmd = launcher_cmd(mode, `--rootfs $(rootfs) $(options) $(ops) -- /bin/sh -c $(script)`)
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
            code, out, err = launch(mode, `--bind /dev/null /dev/null`, "echo x > /dev/null && echo ok")
            @test (code, out) == (0, "ok\n")
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
        end
    end
end
