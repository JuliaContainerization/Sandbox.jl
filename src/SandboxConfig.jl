using Base.BinaryPlatforms, EnumX
const AnyRedirectable = Union{Base.AbstractCmd, Base.TTY, <:IO}

@enumx MountType begin
    ReadWrite
    ReadOnly
    Overlayed
    OverlayedReadOnly
end
"""
    MountInfo(host_path, type)
    MountInfo(host_paths, type)

Describes what to mount at a path in the sandbox: the host path `host_path`, mounted as
`type` (a `MountType`).

An `Overlayed` or `OverlayedReadOnly` mount can stack several host directories, given
as `host_paths` in the order overlayfs lists its lower directories: topmost first, with
the base directory last.  A file in a directory shadows the same file in the directories
after it; changes made in the sandbox go into the overlay's own writable layer, as with
any overlayed mount.  All paths must be absolute.

`m.host_path` is the host path of a mount that has only one.
"""
struct MountInfo
    host_paths::Vector{String}
    type::MountType.T

    function MountInfo(host_paths::AbstractVector{<:AbstractString}, type::MountType.T)
        if isempty(host_paths)
            throw(ArgumentError("A mount needs at least one host path"))
        end
        if length(host_paths) > 1 && type ∉ (MountType.Overlayed, MountType.OverlayedReadOnly)
            throw(ArgumentError("Only Overlayed and OverlayedReadOnly mounts can have several host paths, not $(type) mounts"))
        end
        return new(String.(host_paths), type)
    end
end
MountInfo(host_path::AbstractString, type::MountType.T) = MountInfo([host_path], type)
function Base.getproperty(m::MountInfo, name::Symbol)
    if name === :host_path
        host_paths = getfield(m, :host_paths)
        if length(host_paths) != 1
            throw(ArgumentError("This mount has $(length(host_paths)) host paths; use `host_paths`"))
        end
        return only(host_paths)
    end
    return getfield(m, name)
end
Base.propertynames(::MountInfo) = (:host_paths, :type, :host_path)
Base.:(==)(a::MountInfo, b::MountInfo) = a.host_paths == b.host_paths && a.type == b.type
Base.hash(m::MountInfo, h::UInt) = hash(m.type, hash(m.host_paths, hash(MountInfo, h)))
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

- `tmpfs_size`: Size of the tmpfs that holds changes to the rootfs when `persist` is
  `false` (user namespace executors only), e.g. `"2G"`.

- `shm_size`: Size of the sandbox's private `/dev/shm`, e.g. `"1G"`.
  - Defaults to `nothing`, which leaves it at the executor's default (half of the
    memory for the user namespace executors, 64 MB for Docker).

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
    shm_size::Union{String, Nothing}
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
                           shm_size::Union{String, Nothing}=nothing,
                           hostname::Union{String, Nothing}=nothing,
                           stdin::AnyRedirectable = Base.devnull,
                           stdout::AnyRedirectable = Base.stdout,
                           stderr::AnyRedirectable = Base.stderr,
                           verbose::Bool = false)
        # Lint the maps to ensure that all are absolute paths:
        host_paths = [p for v in values(mounts) for p in v.host_paths]
        for path in [keys(mounts)..., host_paths..., something(entrypoint, "/"), pwd]
            if !startswith(path, "/")
                throw(ArgumentError("Path mapping $(path) is not absolute!"))
            end
        end
        # Executors list paths separated by colons
        for path in [keys(mounts)..., host_paths...]
            if occursin(':', path)
                throw(ArgumentError("Path mapping $(path) contains a colon!"))
            end
        end

        for (sandbox_path, mount_info) in mounts
            # Force every path to be `realpath()`'ed (up to the point of existence)
            # This allows us to point to as-of-yet nonexistant files, but to collapse
            # as many symlinks as possible.
            mount_info = MountInfo(realpath_stem.(mount_info.host_paths), mount_info.type)
            mounts[sandbox_path] = mount_info

            # Disallow ecryptfs mount points, they don't play well with user namespaces.
            for path in mount_info.host_paths
                crypt, mountpoint = is_ecryptfs(path; verbose)
                if crypt
                    throw(ArgumentError("Path $(path) is mounted on the ecryptfs filesystem $(mountpoint)!"))
                end
            end
        end

        # Ensure that read_only_maps contains a mapping for the root in the guest:
        if !haskey(mounts, "/") || mounts["/"].type != MountType.Overlayed
            throw(ArgumentError("Must provide an overlayed root mapping!"))
        end
        if length(mounts["/"].host_paths) != 1
            throw(ArgumentError("The root mapping must have a single host path; put the files in the rootfs, or overlay a subdirectory"))
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

        return new(mounts, env, entrypoint, pwd, persist, collect(multiarch_formats), Cint(uid), Cint(gid), tmpfs_size, shm_size, hostname, stdin, stdout, stderr, verbose)
    end

    # Inner constructor that takes an existing SandboxConfig and allows modifying stdio
    function SandboxConfig(config::SandboxConfig;
                           stdin::AnyRedirectable = config.stdin,
                           stdout::AnyRedirectable = config.stdout,
                           stderr::AnyRedirectable = config.stderr)
        return new(config.mounts, config.env, config.entrypoint, config.pwd,
                   config.persist, config.multiarch_formats, config.uid, config.gid,
                   config.tmpfs_size, config.shm_size, config.hostname, stdin, stdout, stderr, config.verbose)
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
