#!/usr/bin/env julia

using Sandbox, Pkg.Artifacts, Scratch, SHA, ghr_jll

if isempty(ARGS)
    println("Usage: julia --project build_docker_image.jl <dir>")
    println("  Where <dir> is something like `debian-julia-python3`")
end

image_name = ARGS[1]
run(`docker build -t $(image_name) $(image_name)`)

artifact_hash = create_artifact() do dir
    @info("Building $(image_name)")
    Sandbox.export_docker_image(image_name, dir; verbose=true)
    @info("Hashing")
end

# Write out to a file
tarball_path = joinpath(@get_scratch!("archived"), "$(image_name).tar.gz")
@info("Archiving out to $(tarball_path)")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload to `JuliaContainerization/Sandbox.jl`, create a tag based on this docker image
tag_name = "$(image_name)-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to JuliaContainerization/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)

# Bind it into `Artifacts.toml`
tarball_url = "https://github.com/JuliaContainerization/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"
bind_artifact!(
    joinpath(dirname(@__DIR__), "Artifacts.toml"),
    "$(image_name)-rootfs",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    lazy=true,
    force=true,
)
