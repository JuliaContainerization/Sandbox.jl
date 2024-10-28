using Pkg.Artifacts, SHA, Scratch, ghr_jll, Base.BinaryPlatforms, Downloads, TreeArchival

## Download and create our `multiarch-testing` artifact, which contains HelloWorldC_jll for all our architectures.
HWC_version = v"1.3.0+0"
HWC_platforms = (
    Platform("x86_64", "linux"; libc="glibc"),
    Platform("x86_64", "linux"; libc="musl"),
    Platform("i686", "linux"; libc="glibc"),
    Platform("i686", "linux"; libc="musl"),
    Platform("aarch64", "linux"; libc="glibc"),
    Platform("aarch64", "linux"; libc="musl"),
    Platform("armv7l", "linux"; libc="glibc"),
    Platform("armv7l", "linux"; libc="musl"),
    Platform("powerpc64le", "linux"; libc="glibc"),
    # We don't have this one yet
    #Platform("powerpc64le", "linux"; libc="musl"),
)

artifact_hash = create_artifact() do dir
    for platform in HWC_platforms
        url = "https://github.com/JuliaBinaryWrappers/HelloWorldC_jll.jl/releases/download/HelloWorldC-v$(HWC_version)/HelloWorldC.v$(HWC_version.major).$(HWC_version.minor).$(HWC_version.patch).$(triplet(platform)).tar.gz"
        mktempdir() do temp_dir
            tarball_path = joinpath(temp_dir, basename(url))
            Downloads.download(url, tarball_path)
            TreeArchival.unarchive(tarball_path, joinpath(temp_dir, "out"))
            try
                mv(joinpath(temp_dir, "out", "bin", "hello_world"), joinpath(dir, "hello_world.$(triplet(platform))"))
            catch
            end
        end
    end
end

@info("Archiving")
tarball_path = joinpath(@get_scratch!("archived"), "multiarch-testing.tar.gz")
archive_artifact(artifact_hash, tarball_path)

# Hash the tarball
@info("Hashing tarball")
tarball_hash = open(io -> bytes2hex(sha256(io)), tarball_path)

# Upload it to `JuliaContainerization/Sandbox.jl`
tag_name = "multiarch-testing-$(bytes2hex(artifact_hash.bytes[end-3:end]))"
@info("Uploading to JuliaContainerization/Sandbox.jl@$(tag_name)")
run(`$(ghr_jll.ghr()) -replace $(tag_name) $(tarball_path)`)
tarball_url = "https://github.com/JuliaContainerization/Sandbox.jl/releases/download/$(tag_name)/$(basename(tarball_path))"

# Bind it into our Artifacts.toml (advertising support for both glibc and musl)
bind_artifact!(
    joinpath(@__DIR__, "..", "Artifacts.toml"),
    "multiarch-testing",
    artifact_hash;
    download_info=[(tarball_url, tarball_hash)],
    force=true,
    lazy=true,
)
