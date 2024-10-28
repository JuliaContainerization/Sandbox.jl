#!/usr/bin/env julia

# This is an example invocation of `debootstrap` to generate a Debian/Ubuntu-based rootfs
using Scratch, Tar, Pkg, Pkg.Artifacts, ghr_jll, SHA

if Sys.which("debootstrap") === nothing
    error("Must install `debootstrap`!")
end

# Utility functions
getuid() = ccall(:getuid, Cint, ())
getgid() = ccall(:getgid, Cint, ())

artifact_hash = create_artifact() do rootfs
    release = "buster"
    @info("Running debootstrap")
    run(`sudo debootstrap --variant=minbase --include=locales $(release) "$(rootfs)"`)

    # Remove special `dev` files
    @info("Cleaning up `/dev`")
    for f in readdir(joinpath(rootfs, "dev"); join=true)
        # Keep the symlinks around (such as `/dev/fd`), as they're useful
        if !islink(f)
            run(`sudo rm -rf "$(f)"`)
        end
    end

    # take ownership of the entire rootfs
    @info("Chown'ing rootfs")
    run(`sudo chown $(getuid()):$(getgid()) -R "$(rootfs)"`)

    # Write out a reasonable default resolv.conf
    open(joinpath(rootfs, "etc", "resolv.conf"), write=true) do io
        write(io, """
        nameserver 1.1.1.1
        nameserver 8.8.8.8
        nameserver 8.8.4.4
        nameserver 4.4.4.4
        """)
    end

    # Remove `_apt` user so that `apt` doesn't try to `setgroups()`
    @info("Removing `_apt` user")
    open(joinpath(rootfs, "etc", "passwd"), write=true, read=true) do io
        filtered_lines = filter(l -> !startswith(l, "_apt:"), readlines(io))
        truncate(io, 0)
        seek(io, 0)
        for l in filtered_lines
            println(io, l)
        end
    end

    # Set up the one true locale
    @info("Setting up UTF-8 locale")
    open(joinpath(rootfs, "etc", "locale.gen"), "a") do io
        println(io, "en_US.UTF-8 UTF-8")
    end
    @info("Regenerating locale")
    run(`sudo chroot --userspec=$(getuid()):$(getgid()) $(rootfs) locale-gen`)
    @info("Done!")
end

# Archive it into a `.tar.gz` file
@info("Archiving")
tarball_path = joinpath(@get_scratch!("archived"), "debian_minimal.tar.gz")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload it to `JuliaContainerization/Sandbox.jl`
tag_name = "debian-minimal-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to JuliaContainerization/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)

# Bind this artifact into our Artifacts.toml
tarball_url = "https://github.com/JuliaContainerization/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"
bind_artifact!(
    joinpath(dirname(@__DIR__), "Artifacts.toml"),
    "debian-minimal-rootfs",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    lazy=true,
    force=true,
)
