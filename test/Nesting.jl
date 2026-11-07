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

# Sandbox.jl in a sandbox, running a sandbox of its own (which the sandbox's root, an
# overlay, can't hold the changes of: it gets a persist directory from outside).  Also as
# root, as BinaryBuilder's runner does.
if :userns in modes
    @testset "Nesting Sandbox.jl (uid $(uid))" for uid in unique([Sandbox.getuid(), 0])
        pkgdir = dirname(@__DIR__)
        mktempdir() do dir
            rw_dir = mkpath(joinpath(dir, "rw"))
            mkpath(joinpath(rw_dir, "home"))
            persist_dir = new_persist_dir()
            resolv_conf = joinpath(rw_dir, "resolv.conf")
            cp("/etc/resolv.conf", resolv_conf; follow_symlinks=true)
            mounts = [
                pkgdir => Bind(pkgdir),
                # Our active project, with the local preferences that say which launcher
                "/project" => Bind(dirname(Base.active_project())),
                dirname(UserNSSandbox_jll.sandbox_path) => Bind(dirname(UserNSSandbox_jll.sandbox_path)),
                "/usr/local/julia" => Bind(get_nestable_julia()),
                "/etc/resolv.conf" => Bind(resolv_conf),
                "/tmp/readwrite" => Bind(rw_dir; writable=true),
                "/sandbox_persistence" => Bind(persist_dir; writable=true),
            ]
            config = SandboxConfig(; rootfs=rootfs_dir, mounts, cwd=pkgdir, uid,
                                   gid=uid == 0 ? 0 : Sandbox.getgid(),
                                   env=Dict("PATH" => "/usr/local/julia/bin:/usr/local/bin:/usr/bin:/bin",
                                            "HOME" => "/tmp/readwrite/home"))
            try
                @test success(run(config, `/bin/sh -c "julia --color=yes test/nested/nested_child.jl"`))
            finally
                remove_persist(persist_dir, :userns)
            end
            @test read(joinpath(rw_dir, "single_nested.txt"), String) == "aperture\n"
            @test read(joinpath(rw_dir, "double_nested.txt"), String) == "science\n"
        end
    end
end

# The launcher of Sandbox.jl 2.0.2 (UserNSSandbox_jll 2024.6.23), which the Buildkite sandbox
# plugin pins, in a sandbox as the sandboxed Buildkite agent sets it up: as root, with
# FORCE_SANDBOX_MODE and a writable /persist.  Its rootfs is on the sandbox's root, as the
# plugin downloads it there.
if :userns in modes && arch(HostPlatform()) == "x86_64"
    @testset "Nesting the launcher of Sandbox.jl 2" begin
        old = @get_scratch!("UserNSSandbox-2024.6.23")
        if !isfile(joinpath(old, "bin", "sandbox"))
            Pkg.PlatformEngines.download_verify_unpack(
                "https://github.com/JuliaBinaryWrappers/UserNSSandbox_jll.jl/releases/download/UserNSSandbox-v2024.6.23+0/UserNSSandbox.v2024.6.23.x86_64-linux-gnu.tar.gz",
                "982ed4e57d5a205bea64e9518d138096127c604161ee022d2c7c389fe67ce236", old; ignore_existence=true)
        end
        mktempdir() do dir
            persist, ws = mkpath(joinpath(dir, "persist")), mkpath(joinpath(dir, "ws"))
            config = SandboxConfig(;
                rootfs=rootfs_dir,
                mounts=["/old" => Bind(old), "/persist" => Bind(persist; writable=true),
                        "/ws" => Bind(ws; writable=true)],
                env=Dict("PATH" => "/usr/bin:/bin", "FORCE_SANDBOX_MODE" => "unprivileged",
                         "SANDBOX_PERSISTENCE_DIR" => "/persist"),
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
            @test success(run(config, `/bin/sh -c $(script)`))
            @test read(joinpath(ws, "out"), String) == "run1\n"
            run(`chmod -R u+rwX $(dir)`)
        end
    end
end
