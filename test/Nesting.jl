using Test, Sandbox, Scratch, Pkg, Base.BinaryPlatforms

curr_version() = VersionNumber(VERSION.major, VERSION.minor, VERSION.patch)
function get_nestable_julia(target_arch = arch(HostPlatform()), version=VERSION)
    function get_julia_url()
        arch_folder = target_arch
        if target_arch == "x86_64"
            arch_folder = "x64"
        elseif target_arch == "i686"
            arch_folder = "x86"
        end

        if !isempty(version.prerelease)
            # Get the latest version in this major.minor series:
            return "https://julialangnightlies-s3.julialang.org/bin/linux/$(target_arch)/$(version.major).$(version.minor)/julia-latest-linux-$(target_arch).tar.gz"
        else
            return "https://julialang-s3.julialang.org/bin/linux/$(arch_folder)/$(version.major).$(version.minor)/julia-$(version)-linux-$(target_arch).tar.gz"
        end
    end

    sanitized_version = VersionNumber(version.major, version.minor, version.patch)
    julia_dir = @get_scratch!("julia-$(target_arch)-$(sanitized_version)")
    if !isfile(joinpath(julia_dir, "julia-$(sanitized_version)", "bin", "julia"))
        url = get_julia_url()
        rm(julia_dir; force=true, recursive=true)
        Pkg.PlatformEngines.download_verify_unpack(url, nothing, julia_dir; ignore_existence=true, verbose=true)
    end
    return joinpath(julia_dir, only(readdir(julia_dir)))
end

@testset "Nesting Sandbox.jl" begin
    all_executors = Sandbox.all_executors
    rootfs_dir = Sandbox.debian_rootfs()
    for executor in all_executors
        if !executor_available(executor)
            @error("Skipping $(executor) tests, as it does not seem to be available")
            continue
        end

        # Nested sandboxing explicitly does not work with privileged user namespaces,
        # since the whole issue is that once we've dropped privileges the kernel cannot
        # sandbox properly (hence the need to use privileged executor at all).
        if executor <: PrivilegedUserNamespacesExecutor
            continue
        end

        @testset "$(executor) Nesting" begin
            pkgdir = dirname(@__DIR__)
            mktempdir() do dir
                # Directory to hold read-writing from nested sandboxen
                rw_dir = joinpath(dir, "rw")
                mkpath(rw_dir)
                mkpath(joinpath(rw_dir, "home"))

                # Directory to hold sandbox persistence data
                persist_dir = mktempdir(first(Sandbox.find_persist_dir_root(rootfs_dir)))

                ro_mappings = Dict(
                    # Mount in the rootfs
                    "/" => rootfs_dir,
                    # Mount our package in at its own location
                    pkgdir => pkgdir,
                    # Mount our current active project, which may contain a local
                    # preferences file with a custom sandbox path.
                    "/project" => dirname(Base.active_project()),
                    # Mount in a Julia that can run in this sandbox
                    "/usr/local/julia" => get_nestable_julia(),
                )

                # On the off-chance that we're using a custom `sandbox`,
                # make sure it's available at the path that the project will expect
                if UserNSSandbox_jll.is_available()
                    sandbox_path = dirname(Sandbox.UserNSSandbox_jll.sandbox_path)
                    ro_mappings[sandbox_path] = sandbox_path
                end

                # Mount in `/etc/resolv.conf` as a read-only mount if using a UserNS executor, so that we have DNS
                if executor <: UserNamespacesExecutor && isfile("/etc/resolv.conf")
                    resolv_conf = joinpath(rw_dir, "resolv.conf")
                    cp("/etc/resolv.conf", resolv_conf; follow_symlinks=true)
                    ro_mappings["/etc/resolv.conf"] = resolv_conf
                end

                # read-write mappings
                rw_mappings = Dict(
                    # Mount a temporary directory in as writable
                    "/tmp/readwrite" => rw_dir,
                    # Mount a directory to hold our persistent sandbox data
                    "/sandbox_persistence" => persist_dir,
                )

                # Build environment mappings
                env = Dict(
                    "PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin",
                    "HOME" => "/tmp/readwrite/home",
                    # Because overlayfs nesting with persistence requires mounting an overlayfs with
                    # a non-tmpfs-hosted workdir, and that's illegal on top of another overlayfs, we
                    # need to thread our persistence mappings through to the client.  We do so by
                    # bind-mounting `/sandbox_persistence` into the sandbox for future recursive mountings
                    "SANDBOX_PERSISTENCE_DIR" => "/sandbox_persistence",
                )
                # If we're a nested sandbox, pass the forcing through
                if haskey(ENV, "FORCE_SANDBOX_MODE")
                    env["FORCE_SANDBOX_MODE"] = ENV["FORCE_SANDBOX_MODE"]
                end

                config = SandboxConfig(
                    ro_mappings,
                    rw_mappings,
                    env;
                    pwd = pkgdir,
                    uid = Sandbox.getuid(),
                    gid = Sandbox.getgid(),
                )

                cmd = `/bin/sh -c "julia --color=yes test/nested/nested_child.jl"`
                with_executor(executor) do exe
                    @test success(exe, config, cmd)
                end
                @test isfile(joinpath(rw_dir, "single_nested.txt"))
                @test isfile(joinpath(rw_dir, "double_nested.txt"))
                @test String(read(joinpath(rw_dir, "single_nested.txt"))) == "aperture\n"
                @test String(read(joinpath(rw_dir, "double_nested.txt"))) == "science\n"

                if executor <: DockerExecutor
                    stderr = IOBuffer()
                    config_with_stderr = SandboxConfig(
                        ro_mappings,
                        # Mount a temporary directory in as writable
                        Dict("/tmp/readwrite" => rw_dir),
                        # Add the path to `julia` onto the path
                        Dict(
                            "PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin",
                            "HOME" => "/tmp/readwrite/home",
                        );
                        pwd = pkgdir,
                        uid = Sandbox.getuid(),
                        gid = Sandbox.getgid(),
                        stderr = stderr,
                        persist = false,
                    )

                    for privileges in [:no_new_privileges, :unprivileged]
                        with_executor(executor; privileges) do exe
                            @test !success(exe, config_with_stderr, cmd)
                            # Ensure that we get the nested sandbox unable to run any nested sandboxing
                            @test occursin("Could not find any available executors", String(take!(stderr)))
                        end
                    end
                end
            end
        end
    end
end
