module Sandbox

using Base.BinaryPlatforms, LazyArtifacts, Scratch, UserNSSandbox_jll

export SandboxConfig, Bind, Overlay, Tmpfs, Symlink

include("utils.jl")
include("binfmt_misc.jl")
include("mounts.jl")
include("SandboxConfig.jl")
include("persist.jl")

"""
    Sandbox.debian_rootfs(; platform=HostPlatform())

A minimal Debian rootfs, for tests and examples.
"""
debian_rootfs(; platform=HostPlatform()) = @artifact_str("debian-minimal-rootfs-$(arch(platform))")

"""
    Sandbox.multiarch_rootfs()

A rootfs with the C libraries of every platform that `multiarch` supports.
"""
multiarch_rootfs(; platform=nothing) = artifact"multiarch-rootfs"

end # module
