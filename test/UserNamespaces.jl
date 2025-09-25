using Test, Sandbox

if Sys.islinux()
    @test isa(Sandbox.get_kernel_version(), VersionNumber)
    @test Sandbox.check_kernel_version()
end

if executor_available(UnprivilegedUserNamespacesExecutor)
    @testset "UnprivilegedUserNamespacesExecutor" begin
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            @test probe_executor(exe)
        end
    end
    # Can run these tests only if we can actually mount tmpfs with unprivileged executor.
    @testset "Customize the tempfs size" begin
        rootfs_dir = Sandbox.debian_rootfs()
        mounts = Dict(
            "/" => MountInfo(rootfs_dir, MountType.Overlayed),
        )
        env = Dict(
            "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "HOME" => "/home/juliaci",
            "USER" => "juliaci",
        )
        cmd = `/bin/sh -c "mkdir -p /home/juliaci && cd /home/juliaci && dd if=/dev/zero of=sample.txt bs=50M count=1"`
        @testset "tempfs is big enough" begin
            stdout = IOBuffer()
            stderr = IOBuffer()
            config = SandboxConfig(mounts, env; tmpfs_size = "1G", stdout, stderr, persist=false)
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test success(exe, config, cmd)
                @test isempty(take!(stdout))
                @test startswith(strip(String(take!(stderr))), strip("""
                1+0 records in
                1+0 records out"""))
            end
        end
        @testset "tempfs is too small" begin
            stdout = IOBuffer()
            stderr = IOBuffer()
            config = SandboxConfig(mounts, env; tmpfs_size = "10M", stdout, stderr, persist=false)
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test !success(exe, config, cmd)
                @test startswith(strip(String(take!(stderr))), strip("""
                dd: error writing 'sample.txt': No space left on device
                1+0 records in
                0+0 records out"""))
            end
        end
    end

    @testset "Signal Handling" begin
        # This test ensures that killing the child returns a receivable signal
        config = SandboxConfig(Dict("/" => Sandbox.debian_rootfs()))
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            p = run(exe, config, ignorestatus(`/bin/sh -c "kill -s TERM \$\$"`))
            @test p.termsignal == Base.SIGTERM
        end

        # This test ensures that killing the sandbox executable passes the
        # signal on to the child (which then returns a receivable signal)
        config = SandboxConfig(Dict("/" => Sandbox.debian_rootfs()))
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            stdout = IOBuffer()
            stderr = IOBuffer()

            signal_test = """
            trap "echo received SIGINT" INT
            trap "echo received SIGTERM ; trap - TERM; kill -s TERM \$\$" TERM

            sleep 2
            """

            # We use `build_executor_command()` here so that we can use `run(; wait=false)`.
            signal_cmd = pipeline(
                ignorestatus(Sandbox.build_executor_command(exe, config, `/bin/sh -c "$(signal_test)"`));
                stdout,
                stderr
            )
            p = run(signal_cmd; wait=false)
            sleep(0.1)

            # Send SIGINT, wait a bit
            kill(p, Base.SIGINT)
            sleep(0.01)

            # Send SIGTERM, wait for process termination
            kill(p, Base.SIGTERM)
            wait(p)

            # Ensure that the sandbox died as we expected, but that the child process got
            # the messages and responded appropriately.
            @test p.termsignal == Base.SIGTERM
            @test String(take!(stdout)) == "received SIGINT\nreceived SIGTERM\n"
        end
    end

    @testset "Extra fds" begin
        config = SandboxConfig(Dict("/" => Sandbox.debian_rootfs()))
        with_executor(UnprivilegedUserNamespacesExecutor) do exe
            buf = IOBuffer()
            @test success(exe, config, Base.CmdRedirect(`/bin/sh -c "echo hello >&3"`, buf, 3))
            @test String(take!(buf)) == "hello\n"
        end
    end
else
    @error("Skipping Unprivileged tests, as it does not seem to be available")
end

# Only test privileged runner if sudo doesn't require a password
if Sys.which("sudo") !== nothing && success(`sudo -k -n true`)
    if executor_available(PrivilegedUserNamespacesExecutor)
        @testset "PrivilegedUserNamespacesExecutor" begin
            with_executor(PrivilegedUserNamespacesExecutor) do exe
                @test probe_executor(exe)
            end
        end
    else
        @error("Skipping Privileged tests, as it does not seem to be available")
    end
end
