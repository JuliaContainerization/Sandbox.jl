using Test, LazyArtifacts, Sandbox

@testset "SandboxConfig" begin
    rootfs_dir = Sandbox.debian_rootfs()

    @testset "minimal config" begin
        config = SandboxConfig(Dict("/" => rootfs_dir))

        @test haskey(config.mounts, "/")
        @test config.mounts["/"].host_path == realpath(rootfs_dir)
        @test isempty([m for (k, m) in config.mounts if m.type == MountType.ReadWrite])
        @test isempty(config.env)
        @test config.pwd == "/"
        @test config.stdin == Base.devnull
        @test config.stdout == Base.stdout
        @test config.stderr == Base.stderr
        @test config.hostname === nothing
    end

    @testset "full options" begin
        stdout = IOBuffer()
        config = SandboxConfig(
            # read-only maps
            Dict(
                "/" => rootfs_dir,
                "/lib" => rootfs_dir,
            ),
            # read-write maps
            Dict("/workspace" => @__DIR__),
            # env
            Dict("PATH" => "/bin:/usr/bin");
            entrypoint = "/init",
            pwd = "/lib",
            persist = true,
            stdin = Base.stdout,
            stdout = stdout,
            stderr = Base.devnull,
            hostname="sandy",
        )

        # Test the old style API getting mapped to the new MountInfo API:
        @test config.mounts["/"].host_path == realpath(rootfs_dir)
        @test config.mounts["/"].type == MountType.Overlayed
        @test config.mounts["/lib"].host_path == realpath(rootfs_dir)
        @test config.mounts["/lib"].type == MountType.ReadOnly
        @test config.mounts["/workspace"].host_path == realpath(@__DIR__)
        @test config.mounts["/workspace"].type == MountType.ReadWrite

        @test config.env["PATH"] == "/bin:/usr/bin"
        @test config.entrypoint == "/init"
        @test config.pwd == "/lib"
        @test config.persist
        @test config.stdin == Base.stdout
        @test config.stdout == stdout
        @test config.stderr == Base.devnull
        @test config.hostname == "sandy"
    end

    @testset "copy constructor with stdio kwargs" begin
        # Create an initial config
        config1 = SandboxConfig(
            Dict("/" => MountInfo(rootfs_dir, MountType.Overlayed)),
            Dict("TEST_VAR" => "test_value");
            pwd = "/home",
            verbose = true,
            hostname = "test-host"
        )

        # Test copying with modified stdout/stderr
        io_buffer1 = IOBuffer()
        io_buffer2 = IOBuffer()
        config2 = SandboxConfig(config1; stdout=io_buffer1, stderr=io_buffer2)

        # Check that all fields are preserved except stdio
        @test config2.mounts == config1.mounts
        @test config2.env == config1.env
        @test config2.entrypoint == config1.entrypoint
        @test config2.pwd == config1.pwd
        @test config2.persist == config1.persist
        @test config2.multiarch_formats == config1.multiarch_formats
        @test config2.uid == config1.uid
        @test config2.gid == config1.gid
        @test config2.tmpfs_size == config1.tmpfs_size
        @test config2.hostname == config1.hostname
        @test config2.verbose == config1.verbose

        # Check that stdio was modified
        @test config2.stdin == config1.stdin  # unchanged
        @test config2.stdout == io_buffer1
        @test config2.stderr == io_buffer2

        # Test copying with only one stdio changed
        config3 = SandboxConfig(config1; stdin=io_buffer1)
        @test config3.stdin == io_buffer1
        @test config3.stdout == config1.stdout
        @test config3.stderr == config1.stderr
    end

    @testset "errors" begin
        # No root dir error
        @test_throws ArgumentError SandboxConfig(Dict("/rootfs" => rootfs_dir))

        # relative dirs error
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir, "rootfs" => rootfs_dir))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir, "/rootfs" => basename(rootfs_dir)))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir), Dict("rootfs" => rootfs_dir))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir), Dict("/rootfs" => basename(rootfs_dir)))
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir); pwd="lib")
        @test_throws ArgumentError SandboxConfig(Dict("/" => rootfs_dir); entrypoint="init")
    end

    using Sandbox: realpath_stem
    @testset "realpath_stem" begin
        mktempdir() do dir
            dir = realpath(dir)
            mkdir(joinpath(dir, "bar"))
            touch(joinpath(dir, "bar", "foo"))
            symlink("foo", joinpath(dir, "bar", "l_foo"))
            symlink("bar", joinpath(dir, "l_bar"))
            symlink(joinpath(dir, "l_bar", "foo"), joinpath(dir, "l_bar_foo"))

            # Test that `realpath_stem` works just like `realpath()` on existent paths:
            existent_paths = [
                joinpath(dir, "bar"),
                joinpath(dir, "bar", "foo"),
                joinpath(dir, "bar", "l_foo"),
                joinpath(dir, "l_bar"),
                joinpath(dir, "l_bar", "foo"),
                joinpath(dir, "l_bar", "l_foo"),
                joinpath(dir, "l_bar_foo"),
            ]
            for path in existent_paths
                @test realpath_stem(path) == realpath(path)
            end

            # Test that `realpath_stem` gives good answers for non-existent paths:
            non_existent_path_mappings = [
                joinpath(dir, "l_bar", "spoon") => joinpath(dir, "bar", "spoon"),
                joinpath(dir, "l_bar", "..", "l_bar", "spoon") => joinpath(dir, "bar", "spoon"),
            ]
            for (non_path, path) in non_existent_path_mappings
                @test realpath_stem(non_path) == path
            end
        end
    end
end
