using Base.BinaryPlatforms, EnumX
const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, <:IO}

@enumx MountType begin
    ReadWrite
    ReadOnly
    Overlayed
    OverlayedReadOnly
end
struct MountInfo
    host_path::String
    type::MountType.T
end
export MountInfo, MountType

"""
    SandboxConfig(read_only_maps, read_write_maps, env)

Sandbox executors require a configuration to set up the environment properly.

- `read_only_maps`: Directories that are mapped into the sandbox as read-only mappings.
   - Specified as pairs, e.g. `sandbox_path => host_path`.  All paths must be absolute.
   - Must always include a mapping for root, e.g. `"/" => rootfs_path`.

- `read_write_maps`: Directories that are mapped into the sandbox as read-write mappings.
   - Specified as pairs, e.g. `sandbox_path => host_path`.  All paths must be absolute.
   - Note that some executors may not show perfect live updates; consistency is guaranteed
     only after execution is finished.

- `env`: Dictionary mapping of environment variables that should be set within the sandbox.

- `entrypoint`: Executable that gets passed the actual command being run.
  - This is a path within the sandbox, and must be absolute.
  - Defaults to `nothing`, which causes the command to be executed directly.

- `pwd`: Set the working directory of the command that will be run.
  - This is a path within the sandbox, and must be absolute.

- `persist`: Tell the executor object to persist changes made to the rootfs.
  - This is a boolean value, it is up to interpretation by the executor.
  - Persistence is a property of an individual executor and changes live only as long
    as the executor object itself.
  - You cannot transfer persistent changes from one executor to another.

- `multiarch`: Request multiarch executable support
  - This is an array of `Platform` objects
  - Sandbox will ensure that interpreters (such as `qemu-*-static` binaries) are
    available for each platform.
  - Requesting multiarch support for a platform that we don't support results in
    an `ArgumentError`.

- `uid` and `gid`: Numeric user and group identifiers to spawn the sandboxed process as.
  - By default, these are both `0`, signifying `root` inside the sandbox.

- `stdin`, `stdout`, `stderr`: input/output streams for the sandboxed process.
  - Can be any kind of `IO`, `TTY`, `devnull`, etc...

- `hostname`: Set the hostname within the sandbox, defaults to the current hostname

- `verbose`: Set whether the sandbox construction process should be more or less verbose.
"""
struct SandboxConfig
    mounts::Dict{String,MountInfo}
    env::Dict{String,String}
    entrypoint::Union{String,Nothing}
    pwd::String
    persist::Bool
    multiarch_formats::Vector{BinFmtRegistration}
    uid::Cint
    gid::Cint
    tmpfs_size::Union{String, Nothing}
    hostname::Union{String, Nothing}

    stdin::AnyRedirectable
    stdout::AnyRedirectable
    stderr::AnyRedirectable
    verbose::Bool

    function SandboxConfig(mounts::Dict{String,MountInfo},
                           env::Dict{String,String} = Dict{String,String}();
                           entrypoint::Union{String,Nothing} = nothing,
                           pwd::String = "/",
                           persist::Bool = true,
                           multiarch::Vector{<:Platform} = Platform[],
                           uid::Integer=0,
                           gid::Integer=0,
                           tmpfs_size::Union{String, Nothing}=nothing,
                           hostname::Union{String, Nothing}=nothing,
                           stdin::AnyRedirectable = Base.devnull,
                           stdout::AnyRedirectable = Base.stdout,
                           stderr::AnyRedirectable = Base.stderr,
                           verbose::Bool = false)
        # Lint the maps to ensure that all are absolute paths:
        for path in [keys(mounts)..., [v.host_path for v in values(mounts)]...,
                     something(entrypoint, "/"), pwd]
            if !startswith(path, "/")
                throw(ArgumentError("Path mapping $(path) is not absolute!"))
            end
        end

        for (sandbox_path, mount_info) in mounts
            # Force every path to be `realpath()`'ed (up to the point of existence)
            # This allows us to point to as-of-yet nonexistant files, but to collapse
            # as many symlinks as possible.
            mount_info = MountInfo(realpath_stem(mount_info.host_path), mount_info.type)
            mounts[sandbox_path] = mount_info

            # Disallow ecryptfs mount points, they don't play well with user namespaces.
            crypt, mountpoint = is_ecryptfs(mount_info.host_path; verbose)
            if crypt
                throw(ArgumentError("Path $(mount_info.host_path) is mounted on the ecryptfs filesystem $(mountpoint)!"))
            end
        end

        # Ensure that read_only_maps contains a mapping for the root in the guest:
        if !haskey(mounts, "/") || mounts["/"].type != MountType.Overlayed
            throw(ArgumentError("Must provide an overlayed root mapping!"))
        end

        # Collect all multiarch platforms, mapping to the known interpreter for that platform.
        multiarch_formats = Set{BinFmtRegistration}()
        interp_platforms = collect(keys(platform_qemu_registrations))
        for platform in multiarch
            # If this platform is natively runnable, skip it
            if natively_runnable(platform)
                continue
            end

            platform_idx = findfirst(p -> platforms_match(platform, p), interp_platforms)
            if platform_idx === nothing
                throw(ArgumentError("Platform $(triplet(platform)) unsupported for multiarch!"))
            end
            push!(multiarch_formats, platform_qemu_registrations[interp_platforms[platform_idx]])
        end

        return new(mounts, env, entrypoint, pwd, persist, collect(multiarch_formats), Cint(uid), Cint(gid), tmpfs_size, hostname, stdin, stdout, stderr, verbose)
    end
end

# Compatibility shim for `read_only_maps`/`read_write_maps` API:
function SandboxConfig(read_only_maps::Dict{String,String},
                       read_write_maps::Dict{String,String} = Dict{String,String}(),
                       env::Dict{String,String} = Dict{String,String}();
                       kwargs...)
    # Our new API uses a unified `mounts` with mount types set:
    mounts = Dict{String,MountInfo}()
    for (sandbox_path, host_path) in read_only_maps
        mt = sandbox_path == "/" ? MountType.Overlayed : MountType.ReadOnly
        mounts[sandbox_path] = MountInfo(host_path, mt)
    end
    for (sandbox_path, host_path) in read_write_maps
        if sandbox_path ∈ keys(mounts)
            throw(ArgumentError("Cannot specify the same sandbox path twice in maps! ('$(sandbox_path)')"))
        end
        mounts[sandbox_path] = MountInfo(host_path, MountType.ReadWrite)
    end
    return SandboxConfig(mounts, env; kwargs...)
end
