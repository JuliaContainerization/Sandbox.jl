using Test, Sandbox, SHA
using Sandbox: command

for mode in modes
    @testset "Sandboxing ($(mode))" begin
        config(; kwargs...) = SandboxConfig(; rootfs=rootfs_dir, mode, env=Dict("PATH" => default_path), kwargs...)

        @testset "standard streams" begin
            p, out, err = sandbox_run(config(), `/bin/sh -c "echo stdout; echo stderr >&2"`)
            @test success(p)
            @test (out, err) == ("stdout\n", "stderr\n")
            @test read(pipeline(command(config(), `/bin/sh -c "read x; echo \$x\$x"`); stdin=IOBuffer("ab\n")),
                       String) == "abab\n"
            # Between two sandboxes
            out = read(pipeline(command(config(), `/bin/sh -c "echo 'ignore me'; echo 'pick this up foo'"`),
                                command(config(), `/bin/grep foo`)), String)
            @test out == "pick this up foo\n"
            # Other fds than the standard ones (which sudo closes)
            if mode == :userns
                buf = IOBuffer()
                @test success(Base.CmdRedirect(command(config(), `/bin/sh -c "echo hello >&3"`), buf, 3))
                @test String(take!(buf)) == "hello\n"
            end
        end

        @testset "exit status" begin
            @test_throws ProcessFailedException run(config(), `/bin/false`)
            @test !success(command(config(), `/bin/false`))
            @test run(config(), ignorestatus(`/bin/false`)).exitcode == 1
        end

        @testset "environment" begin
            env = Dict("PATH" => "/usr/bin:/bin", "LD_LIBRARY_PATH" => "science", "SHELL" => "monster")
            # The command sees exactly the environment asked for, nothing added by the
            # launcher or by sudo
            p, out, err = sandbox_run(config(; env), setenv(`/usr/bin/env`, "SHELL" => "friend"))
            @test success(p)
            @test sort(split(out, '\n'; keepempty=false)) ==
                  ["LD_LIBRARY_PATH=science", "PATH=/usr/bin:/bin", "SHELL=friend"]
            @test isempty(err)
        end

        @testset "binds" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                p, out, err = sandbox_run(config(; mounts=["/glados" => Bind(dir)]),
                                          `/bin/sh -c "cat /glados/note.txt; touch /glados/x"`)
                @test !success(p)
                @test out == "great success"
                @test occursin("Read-only file system", err)
                @test success(run(config(; mounts=["/glados" => Bind(dir; writable=true)]),
                                  `/bin/sh -c "echo aperture > /glados/science.txt"`))
                @test read(joinpath(dir, "science.txt"), String) == "aperture\n"
                # A single file, at a destination whose parents don't exist yet
                p, out, err = sandbox_run(config(; mounts=["/does/not/exist" => Bind(joinpath(dir, "note.txt"))]),
                                          `/bin/cat /does/not/exist`)
                @test (success(p), out) == (true, "great success")
                # Optional sources may be missing
                p, out, err = sandbox_run(config(; mounts=["/m" => Bind(joinpath(dir, "nope"); optional=true)]),
                                          `/bin/sh -c "test -e /m || echo skipped"`)
                @test (success(p), out) == (true, "skipped\n")
                @test sandbox_run(config(; mounts=["/m" => Bind(joinpath(dir, "nope"))]), `/bin/true`)[1].exitcode == 125
            end
        end

        @testset "devices" begin
            # Device nodes only work in binds that ask for them, such as the default ones
            p, out, err = sandbox_run(config(; mounts=["/null" => Bind("/dev/null"; writable=true)]),
                                      `/bin/sh -c "echo > /null"`)
            @test !success(p)
            @test occursin("Permission denied", err)
            @test success(run(config(; mounts=["/null" => Bind("/dev/null"; writable=true, devices=true)]),
                              `/bin/sh -c "echo > /null && echo > /dev/null"`))
        end

        @testset "defaults" begin
            p, out, err = sandbox_run(config(), `/bin/ls /dev`)
            @test issubset(["fd", "full", "null", "ptmx", "pts", "random", "shm", "stderr", "stdin", "stdout",
                            "urandom", "zero"], split(out))
            p, out, err = sandbox_run(config(), `/usr/bin/stat -f -c %T /dev /dev/shm /dev/pts`)
            @test split(out) == ["tmpfs", "tmpfs", "devpts"]
            # A mount replaces the default at its destination
            script = "dd if=/dev/zero of=/dev/shm/blob bs=1M count=16"
            @test success(run(config(; mounts=["/dev/shm" => Tmpfs(size="32M", mode=0o1777)]), `/bin/sh -c $(script)`))
            p, out, err = sandbox_run(config(; mounts=["/dev/shm" => Tmpfs(size="8M", mode=0o1777)]), `/bin/sh -c $(script)`)
            @test !success(p)
            @test occursin("No space left on device", err)
            # Without the defaults, /dev is the rootfs's
            p, out, err = sandbox_run(config(; defaults=false), `/usr/bin/stat -f -c %T /dev`)
            @test (success(p), out) == (true, "overlayfs\n")
        end

        @testset "symlinks" begin
            p, out, err = sandbox_run(config(; mounts=["/etc/alias" => Symlink("hostname")]), `/bin/cat /etc/alias`)
            @test success(p)
            @test out == read(joinpath(rootfs_dir, "etc", "hostname"), String)
        end

        @testset "overlays, without persist" begin
            mktempdir() do dir
                mounts = ["/overlayed" => Overlay(dir)]
                for _ in 1:2
                    # Changes to the rootfs and overlays are gone after each run
                    p, out, err = sandbox_run(config(; mounts),
                        `/bin/sh -c "echo aperture >> /bin/science; echo aperture >> /overlayed/science; cat /bin/science /overlayed/science"`)
                    @test (success(p), out, err) == (true, "aperture\naperture\n", "")
                end
                @test isempty(readdir(dir))
                @test !ispath(joinpath(rootfs_dir, "bin", "science"))
            end
        end

        @testset "tmpfs_size" begin
            script = "dd if=/dev/zero of=/sample bs=50M count=1"
            @test success(run(config(; tmpfs_size="1G"), `/bin/sh -c "$(script) 2>/dev/null"`))
            p, out, err = sandbox_run(config(; tmpfs_size="10M"), `/bin/sh -c $(script)`)
            @test !success(p)
            @test occursin("No space left on device", err)
        end

        @testset "persistence" begin
            mktempdir() do dir
                mkdir(joinpath(dir, "lower"))
                mkdir(joinpath(dir, "empty"))
                persist = new_persist_dir()
                try
                    cfg(mounts...) = config(; persist, mounts=collect(mounts))
                    cmd = `/bin/sh -c "echo aperture >> /bin/science; echo aperture >> /o/science; cat /bin/science /o/science"`
                    @test sandbox_run(cfg("/o" => Overlay(joinpath(dir, "lower"))), cmd)[2] == "aperture\n"^2
                    @test sandbox_run(cfg("/o" => Overlay(joinpath(dir, "lower"))), cmd)[2] == "aperture\n"^4
                    @test isempty(readdir(joinpath(dir, "lower")))
                    # A read-only overlay of another directory at the same place shows what
                    # was persisted there (BinaryBuilder2 reads the results of a build so)
                    p, out, err = sandbox_run(cfg("/o" => Overlay(joinpath(dir, "empty"); readonly=true)),
                                              `/bin/sh -c "cat /o/science; touch /o/x"`)
                    @test out == "aperture\n"^2
                    @test occursin("Read-only file system", err)
                finally
                    remove_persist(persist, mode)
                end
                @test !ispath(persist)
            end
        end

        @testset "user and group" begin
            for (uid, gid) in [(0, 0), (999, 0), (0, 999), (999, 999)]
                p, out, err = sandbox_run(config(; uid, gid), `/usr/bin/id`)
                @test occursin("uid=$(uid)", out)
                @test occursin("gid=$(gid)", out)
            end
        end

        @testset "cwd" begin
            @test sandbox_run(config(; cwd="/does/not/exist"), `/bin/pwd`)[2] == "/does/not/exist\n"
        end

        @testset "hostname" begin
            @test sandbox_run(config(; hostname="sandy"), `/bin/uname -n`)[2] == "sandy\n"
        end

        # Under sudo, the launcher's parent is sudo, which handles signals itself
        mode == :userns && @testset "signals" begin
            # Killing the command is seen as such
            @test run(config(), ignorestatus(`/bin/sh -c "kill -s TERM \$\$"`)).termsignal == Base.SIGTERM

            # Signals for the launcher reach the command
            out = IOBuffer()
            script = """
                trap "echo received SIGINT" INT
                trap "echo received SIGTERM ; trap - TERM; kill -s TERM \$\$" TERM
                echo ready
                sleep 2 & wait; sleep 2 & wait
                """
            p = run(pipeline(command(config(), ignorestatus(`/bin/sh -c $(script)`)); stdout=out); wait=false)
            while !occursin("ready", String(copy(out.data[1:out.size]))); sleep(0.01); end
            kill(p, Base.SIGINT)
            sleep(0.1)
            kill(p, Base.SIGTERM)
            wait(p)
            @test p.termsignal == Base.SIGTERM
            @test String(take!(out)) == "ready\nreceived SIGINT\nreceived SIGTERM\n"
        end

        @testset "Internet access" begin
            mktempdir() do rw_dir
                # Mount in `/etc/resolv.conf`, so that we have DNS
                resolv_conf = joinpath(rw_dir, "resolv.conf")
                cp("/etc/resolv.conf", resolv_conf; follow_symlinks=true)
                socrates_url = "https://github.com/staticfloat/small_bin/raw/master/socrates.tar.xz"
                socrates_hash = "61bcf109fcb749ee7b6a570a6057602c08c836b6f81091eab7aa5f5870ec6475"
                # apt needs xattrs in the overlay, which the tmpfs only has without
                # root since Linux 6.6
                persist = new_persist_dir()
                cfg = config(; env=Dict("PATH" => default_path, "HOME" => "/root"), persist,
                             mounts=["/etc/resolv.conf" => Bind(resolv_conf), "/tmp/rw_dir" => Bind(rw_dir; writable=true)])
                try
                    @test success(pipeline(command(cfg, `/bin/sh -c "apt update && apt install -y curl && curl -L $(socrates_url) -o /tmp/rw_dir/$(basename(socrates_url))"`);
                                           stdout=devnull, stderr=devnull))
                finally
                    remove_persist(persist, mode)
                end
                socrates_path = joinpath(rw_dir, basename(socrates_url))
                @test isfile(socrates_path)
                @test open(io -> bytes2hex(sha256(io)), socrates_path) == socrates_hash
            end
        end
    end
end

@testset "persist directories" begin
    for mode in modes
        dir = Sandbox.scratch_persist_dir()
        @test isdir(dir)
        @test Sandbox.probe_persist(dir; rootfs=rootfs_dir, mode)
        @test isempty(readdir(dir))
        # A probe that fails cleans up as well
        @test !Sandbox.probe_persist(dir; rootfs=joinpath(dir, "nope"), mode)
        @test isempty(readdir(dir))
        rm(dir)
    end

    # What overlayfs and the sandbox leave behind can be removed, and nothing is
    # changed through symlinks
    mktempdir() do dir
        victim = joinpath(dir, "victim")
        write(victim, "")
        chmod(victim, 0o400)
        persist = mkpath(joinpath(dir, "persist", "work", "rootfs", "work"))
        chmod(persist, 0o000)
        symlink(victim, joinpath(dir, "persist", "link"))
        symlink("/does/not/exist", joinpath(dir, "persist", "dangling"))
        symlink(joinpath(dir, "persist"), joinpath(dir, "alias"))
        write(joinpath(dir, "persist", "file"), "")
        for alias in ("alias", "alias/", "alias/.", "alias//")
            @test_throws ArgumentError Sandbox.remove_persist(joinpath(dir, alias))
        end
        @test isfile(joinpath(dir, "persist", "file"))
        cd(joinpath(dir, "persist")) do
            @test_throws ArgumentError Sandbox.remove_persist("")
            @test_throws ArgumentError Sandbox.remove_persist("/")
        end
        @test isfile(joinpath(dir, "persist", "file"))
        @test_throws ArgumentError Sandbox.remove_persist(joinpath(dir, "persist"); mode=:root)
        Sandbox.remove_persist(joinpath(dir, "persist"))
        @test !ispath(joinpath(dir, "persist"))
        @test filemode(victim) & 0o777 == 0o400
    end
end
