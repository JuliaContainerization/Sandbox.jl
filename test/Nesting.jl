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

        # Also nest as root, as BinaryBuilder's runner does.  Only our own executor lets
        # us pick the uid.
        uids = [Sandbox.getuid()]
        if executor <: UnprivilegedUserNamespacesExecutor
            push!(uids, 0)
        end
        unique!(uids)

        for uid in uids
            @testset "$(executor) Nesting (uid $(uid))" begin
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
                        uid,
                        gid = uid == 0 ? 0 : Sandbox.getgid(),
                    )

                    cmd = `/bin/sh -c "julia --color=yes test/nested/nested_child.jl"`
                    with_executor(executor) do exe
                        @test success(exe, config, cmd)
                    end
                    @test isfile(joinpath(rw_dir, "single_nested.txt"))
                    @test isfile(joinpath(rw_dir, "double_nested.txt"))
                    @test String(read(joinpath(rw_dir, "single_nested.txt"))) == "aperture\n"
                    @test String(read(joinpath(rw_dir, "double_nested.txt"))) == "science\n"
                end
            end
        end
    end
end

# The launcher of Sandbox.jl 2.0.2 (UserNSSandbox_jll 2024.6.23), which the Buildkite sandbox
# plugin pins, in a sandbox as the sandboxed Buildkite agent sets it up: as root, with
# FORCE_SANDBOX_MODE and a writable /persist.  Its rootfs is on the sandbox's root, as the
# plugin downloads it there.
if Sys.islinux() && arch(HostPlatform()) == "x86_64" && executor_available(UnprivilegedUserNamespacesExecutor)
    @testset "Nesting the launcher of Sandbox.jl 2" begin
        old = @get_scratch!("UserNSSandbox-2024.6.23")
        if !isfile(joinpath(old, "bin", "sandbox"))
            Pkg.PlatformEngines.download_verify_unpack(
                "https://github.com/JuliaBinaryWrappers/UserNSSandbox_jll.jl/releases/download/UserNSSandbox-v2024.6.23+0/UserNSSandbox.v2024.6.23.x86_64-linux-gnu.tar.gz",
                "982ed4e57d5a205bea64e9518d138096127c604161ee022d2c7c389fe67ce236", old; ignore_existence=true)
        end
        mktempdir() do dir
            persist, ws = mkpath(joinpath(dir, "persist")), mkpath(joinpath(dir, "ws"))
            config = SandboxConfig(
                Dict("/" => Sandbox.debian_rootfs(), "/old" => old),
                Dict("/persist" => persist, "/ws" => ws),
                Dict("PATH" => "/usr/bin:/bin", "FORCE_SANDBOX_MODE" => "unprivileged",
                     "SANDBOX_PERSISTENCE_DIR" => "/persist");
                persist=false, stdout=IOBuffer(),
            )
            # A rootfs of `dash`, whose changes persist from one run to the next
            script = raw"""
                set -e
                mkdir -p /r/proc /r/dev/pts /r/sys /r/ws
                touch /r/dev/null /r/dev/tty /r/dev/zero /r/dev/random /r/dev/urandom /r/dev/ptmx
                cp --parents /bin/dash $(ldd /bin/dash | grep -o '/[^ ]*') /r/
                for i in 1 2; do
                    /old/bin/sandbox --rootfs /r --cd /ws --mount /ws:/ws:rw --persist /persist/p \
                        --userxattr --uid 0 --gid 0 -- /bin/dash -c '{ read l < /x; } 2>/dev/null && echo $l; echo $0 > /x' run$i
                done > /ws/out
                """
            with_executor(UnprivilegedUserNamespacesExecutor) do exe
                @test success(exe, config, `/bin/sh -c $(script)`)
            end
            @test read(joinpath(ws, "out"), String) == "run1\n"
            run(`chmod -R u+rwX $(dir)`)
        end
    end
end
