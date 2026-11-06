using Test, Sandbox, Base.BinaryPlatforms
using Sandbox: Devpts, CgroupView, default_mounts, all_mounts, command

# The launcher operations of `config` (without persist, tmpfs_size or hostname).
operations(config) = (args = command(config, `/bin/true`).exec;
                      args[findfirst(==("--gid"), args)+2:findfirst(==("--"), args)-1])

@testset "SandboxConfig" begin
    rootfs = "/rootfs"

    @testset "minimal config" begin
        config = SandboxConfig(; rootfs)
        @test config.rootfs == rootfs
        @test isempty(config.mounts)
        @test config.defaults
        @test isempty(config.env)
        @test config.cwd == "/"
        @test (config.uid, config.gid) == (0, 0)
        @test config.persist === nothing
        @test config.mode == :userns
        @test all_mounts(config) == default_mounts()
    end

    @testset "mounts" begin
        # A vector keeps its order, also for repeated destinations
        mounts = ["/b" => Bind("/x"), "/a/c" => Tmpfs(), "/a" => Bind("/y"), "/b" => Symlink("t")]
        config = SandboxConfig(; rootfs, mounts, defaults=false)
        @test config.mounts == mounts
        @test operations(config) == ["--ro-bind", "/x", "/b", "--tmpfs", "/a/c", "mode=755",
                                     "--ro-bind", "/y", "/a", "--symlink", "t", "/b"]

        # A dictionary goes parents first, component-wise
        config = SandboxConfig(; rootfs, defaults=false, mounts=Dict(
            "/usr/lib/x" => Tmpfs(), "/usr-local" => Tmpfs(), "/usr" => Tmpfs(), "/usr/lib" => Tmpfs()))
        @test first.(config.mounts) == ["/usr", "/usr/lib", "/usr/lib/x", "/usr-local"]

        # Destinations are normalized
        config = SandboxConfig(; rootfs, defaults=false, mounts=["/a//b/../c/" => Tmpfs()])
        @test first.(config.mounts) == ["/a/c"]

        # Any collection of pairs will do
        for mounts in (Any["/a" => Tmpfs()], Pair{String,Any}["/a" => Tmpfs()], Dict{String,Any}("/a" => Tmpfs()))
            @test SandboxConfig(; rootfs, mounts).mounts == ["/a" => Tmpfs()]
        end

        @testset "operations" begin
            for (mount, op) in [
                    Bind("/s") => ["--ro-bind", "/s", "/d"],
                    Bind("/s"; writable=true) => ["--bind", "/s", "/d"],
                    Bind("/s"; devices=true) => ["--ro-dev-bind", "/s", "/d"],
                    Bind("/s"; writable=true, devices=true, optional=true) => ["--dev-bind-try", "/s", "/d"],
                    Bind("/s"; optional=true) => ["--ro-bind-try", "/s", "/d"],
                    Overlay("/s") => ["--overlay", "/s", "/d"],
                    Overlay("/s"; readonly=true) => ["--ro-overlay", "/s", "/d"],
                    Tmpfs() => ["--tmpfs", "/d", "mode=755"],
                    Tmpfs(size="1G", mode=0o1777) => ["--tmpfs", "/d", "mode=1777,size=1G"],
                    Tmpfs(size=1024) => ["--tmpfs", "/d", "mode=755,size=1024"],
                    Symlink("../t") => ["--symlink", "../t", "/d"],
                    Devpts() => ["--devpts", "/d"],
                    CgroupView() => ["--cgroup", "/d"],
                ]
                @test operations(SandboxConfig(; rootfs, defaults=false, mounts=["/d" => mount])) == op
            end
        end
    end

    @testset "defaults" begin
        defaults = first.(default_mounts())
        @test defaults[1] == "/dev"
        @test "/dev/null" in defaults && "/dev/shm" in defaults && "/sys/fs/cgroup" in defaults
        # They come first, and a mount at or above one replaces it
        config = SandboxConfig(; rootfs, mounts=["/dev/shm" => Tmpfs(size="8G"), "/data" => Bind("/data")])
        dests = first.(all_mounts(config))
        @test dests == [filter(!=("/dev/shm"), defaults); "/dev/shm"; "/data"]
        @test all_mounts(config)[end-1] == ("/dev/shm" => Tmpfs(size="8G"))
        config = SandboxConfig(; rootfs, mounts=["/dev" => Bind("/dev"; writable=true, devices=true)])
        @test first.(all_mounts(config)) == ["/sys", "/sys/fs/cgroup", "/dev"]
        # Without defaults, only what is asked for
        config = SandboxConfig(; rootfs, defaults=false, mounts=["/dev/shm" => Tmpfs()])
        @test first.(all_mounts(config)) == ["/dev/shm"]
    end

    @testset "command" begin
        config = SandboxConfig(; rootfs, env=Dict("A" => "1", "B" => "2"), cwd="/work", uid=1, gid=2,
                               hostname="sandy", persist="/persist", tmpfs_size="2G", verbose=true)
        cmd = command(config, setenv(`/bin/echo hi`, "B" => "3", "C" => "4"))
        args = cmd.exec
        @test args[1] == Sandbox.UserNSSandbox_jll.sandbox_path
        @test "--verbose" in args
        @test "--privileged" ∉ args
        for (opt, value) in ("--rootfs" => rootfs, "--cd" => "/work", "--uid" => "1", "--gid" => "2",
                             "--hostname" => "sandy", "--persist" => "/persist", "--tmpfs-size" => "2G")
            @test args[findfirst(==(opt), args) + 1] == value
        end
        @test args[end-2:end] == ["--", "/bin/echo", "hi"]
        # The command's environment adds to the config's
        @test cmd.env == ["A=1", "B=3", "C=4"]

        # Execution flags carry over
        cmd = command(config, Cmd(`/bin/true`; ignorestatus=true, detach=true, cpus=UInt16[0]))
        @test cmd.ignorestatus
        @test cmd.flags & Base.UV_PROCESS_DETACHED != 0
        @test cmd.cpus == UInt16[0]
        @test !command(config, `/bin/true`).ignorestatus

        # The working directory is the config's
        @test_throws ArgumentError command(config, Cmd(`/bin/true`; dir="/tmp"))

        # In sudo mode, the environment goes through `env`, with our ids
        config = SandboxConfig(; rootfs, env=Dict("A" => "1"), mode=:sudo)
        cmd = command(config, `/bin/true`)
        @test cmd.exec[1:5] == ["sudo", "/usr/bin/env", "-i", "--", "A=1"]
        @test cmd.exec[6:7] == ["SUDO_UID=$(Sandbox.getuid())", "SUDO_GID=$(Sandbox.getgid())"]
        @test "--privileged" in cmd.exec
        @test isempty(cmd.env)
    end

    @testset "errors" begin
        @test_throws ArgumentError SandboxConfig(; rootfs="rootfs")
        @test_throws ArgumentError SandboxConfig(; rootfs, cwd="work")
        @test_throws ArgumentError SandboxConfig(; rootfs, mode=:docker)
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["d" => Tmpfs()])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/" => Tmpfs()])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/a/.." => Tmpfs()])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/proc/sys" => Tmpfs()])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/d" => Bind("relative")])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/d" => Overlay("relative")])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/d" => "/s"])
        @test_throws ArgumentError SandboxConfig(; rootfs, mounts=["/d" => Overlay("/a"), "/d/" => Overlay("/b")])
        @test_throws ArgumentError SandboxConfig(; rootfs, tmpfs_size="lots")
        @test_throws ArgumentError Tmpfs(size="1T")
        @test_throws ArgumentError Tmpfs(mode=0o10000)
        @test_throws ArgumentError SandboxConfig(; rootfs, multiarch=[Platform("armv6l", "linux")])
        @test_throws ArgumentError SandboxConfig(; rootfs, multiarch=[Platform(arch(HostPlatform()), "windows")])
    end
end
