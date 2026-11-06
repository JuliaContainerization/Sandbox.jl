"""
    SandboxConfig(; rootfs, mounts=[], defaults=true, env=Dict(), cwd="/", uid=0, gid=0,
                  hostname=nothing, persist=nothing, tmpfs_size=nothing, mode=:userns,
                  multiarch=Platform[], verbose=false)

What a sandbox is made of.  [`Sandbox.command`](@ref) turns it and a command into a
`Cmd` that runs the command in it.

- `rootfs`: the host directory that is the sandbox's `/`.  The sandbox sees an overlay
  of it: its changes go to `persist`, not to `rootfs`.
- `mounts`: `destination => mount` pairs, mounted in order after the default mounts (see
  [`Sandbox.default_mounts`](@ref)); each mount is a [`Bind`](@ref), [`Overlay`](@ref),
  [`Tmpfs`](@ref) or [`Symlink`](@ref).  A later mount at the same place covers an
  earlier one.  A dictionary is mounted parents first.  A mount at or above a default
  mount's destination replaces that default.
- `defaults`: whether to start from the default mounts.
- `env`: the environment of the command, to which that of the command itself is added.
- `cwd`: the command's working directory, created if it doesn't exist.
- `uid`, `gid`: who the command runs as, root by default.  Whatever the ids in the
  sandbox, files are created as the calling user on the host.
- `hostname`: the sandbox's hostname.
- `persist`: a directory that keeps the changes to the rootfs and to the overlays, for a
  later sandbox with the same directory to see.  It belongs to the caller, who creates
  it and removes it, and only one sandbox may use it at a time.  See
  [`Sandbox.probe_persist`](@ref).  Without it, changes go to a tmpfs and are gone when
  the command exits.
- `tmpfs_size`: the size of that tmpfs, `"1G"` by default.
- `mode`: `:userns` sets up the sandbox in a user namespace, without privileges.  `:sudo`
  sets it up as root, through `sudo`, for kernels that don't allow an overlay in a user
  namespace; the command still runs as the calling user.
- `multiarch`: platforms whose executables the sandbox should be able to run, through
  QEMU.  [`Sandbox.register_multiarch`](@ref) registers what that needs with the kernel
  (`run` does so itself).
- `verbose`: have the launcher tell what it sets up.
"""
struct SandboxConfig
    rootfs::String
    mounts::Vector{Pair{String,Mount}}
    defaults::Bool
    env::Dict{String,String}
    cwd::String
    uid::UInt32
    gid::UInt32
    hostname::Union{Nothing,String}
    persist::Union{Nothing,String}
    tmpfs_size::Union{Nothing,String}
    mode::Symbol
    multiarch::Vector{Platform}
    verbose::Bool

    function SandboxConfig(; rootfs::AbstractString,
                           mounts::Union{AbstractVector,AbstractDict} = Pair{String,Mount}[],
                           defaults::Bool = true,
                           env = Dict{String,String}(),
                           cwd::AbstractString = "/",
                           uid::Integer = 0,
                           gid::Integer = 0,
                           hostname::Union{Nothing,AbstractString} = nothing,
                           persist::Union{Nothing,AbstractString} = nothing,
                           tmpfs_size::Union{Nothing,Integer,AbstractString} = nothing,
                           mode::Symbol = :userns,
                           multiarch::AbstractVector{<:Platform} = Platform[],
                           verbose::Bool = false)
        isabspath(rootfs) || throw(ArgumentError("rootfs \"$(rootfs)\" is not absolute"))
        mounts = normalize_mounts(mounts)
        overlays = [dest for (dest, m) in mounts if m isa Overlay]
        allunique(overlays) ||
            throw(ArgumentError("more than one overlay at the same destination, which would share their changes"))
        for (dest, m) in mounts
            if m isa Union{Bind,Overlay} && !isabspath(m.source)
                throw(ArgumentError("mount source \"$(m.source)\" of \"$(dest)\" is not absolute"))
            end
        end
        isabspath(cwd) || throw(ArgumentError("cwd \"$(cwd)\" is not absolute"))
        mode in (:userns, :sudo) || throw(ArgumentError("mode must be :userns or :sudo, not $(repr(mode))"))
        tmpfs_size === nothing || (tmpfs_size = Tmpfs(size=tmpfs_size).size)
        multiarch_formats(multiarch)  # throws for unsupported platforms
        return new(rootfs, mounts, defaults, Dict{String,String}(env), cwd, uid, gid,
                   hostname, persist === nothing ? nothing : abspath(persist), tmpfs_size,
                   mode, multiarch, verbose)
    end
end

# The mounts, defaults included, in the order the launcher mounts them.
function all_mounts(config::SandboxConfig)
    config.defaults || return config.mounts
    defaults = filter(default_mounts()) do (dest, _)
        !any(m -> within(dest, m.first), config.mounts)
    end
    return [defaults; config.mounts]
end

"""
    Sandbox.command(config::SandboxConfig, cmd::Cmd) -> Cmd

The command that runs `cmd` in the sandbox `config`.  Run it as any other, with `run`,
`pipeline`, `open` or `read`: its standard streams are those of `cmd` in the sandbox.  It
exits as `cmd` does, or with 125 if the sandbox could not be set up, 126 if `cmd` could not
be executed, and 127 if it was not found.

`cmd`'s executable is a path in the sandbox, not looked up in its `PATH`.  Its environment
is `config.env` plus that of `cmd`, and nothing else; `ignorestatus`, `detach` and `cpus`
carry over.  `cmd` can't have a `dir`: the working directory is `config.cwd`.

This has no side effects.  Unlike `run(config, cmd)`, it doesn't register the interpreters
for `config.multiarch` (see [`Sandbox.register_multiarch`](@ref)).
"""
function command(config::SandboxConfig, cmd::Cmd)
    isempty(cmd.dir) ||
        throw(ArgumentError("the working directory in the sandbox is the config's `cwd`, not the command's `dir`"))
    args = String[UserNSSandbox_jll.sandbox_path, "--protocol", "3"]
    config.verbose && push!(args, "--verbose")
    config.mode == :sudo && push!(args, "--privileged")
    append!(args, ["--rootfs", config.rootfs, "--cd", config.cwd,
                   "--uid", string(config.uid), "--gid", string(config.gid)])
    config.persist === nothing || append!(args, ["--persist", config.persist])
    config.tmpfs_size === nothing || append!(args, ["--tmpfs-size", config.tmpfs_size])
    config.hostname === nothing || append!(args, ["--hostname", config.hostname])
    for (dest, m) in all_mounts(config)
        append!(args, operation(dest, m))
    end
    push!(args, "--")
    append!(args, cmd.exec)

    env = copy(config.env)
    for var in something(cmd.env, String[])
        name, value = split(var, '='; limit=2)
        env[name] = value
    end
    env = sort!(["$(name)=$(value)" for (name, value) in env])
    if config.mode == :sudo
        # sudo adds variables of its own (`HOME`, `USER`, `SUDO_*`, ...), and sudo-rs doesn't
        # support `-E`, so set the environment with `env -i` instead.  The launcher reads
        # the caller's ids from `SUDO_UID` and `SUDO_GID`, and unsets them.
        args = ["sudo", "/usr/bin/env", "-i", "--", env...,
                "SUDO_UID=$(getuid())", "SUDO_GID=$(getgid())", args...]
        env = String[]
    end
    return Cmd(Cmd(args); env, ignorestatus=cmd.ignorestatus, cpus=cmd.cpus,
               detach=cmd.flags & Base.UV_PROCESS_DETACHED != 0)
end

"""
    run(config::SandboxConfig, cmd::Cmd; wait=true)

Registers the interpreters for `config.multiarch`, if needed, then runs `cmd` in the
sandbox.  Shorthand for `run(Sandbox.command(config, cmd); wait)` after
[`Sandbox.register_multiarch(config)`](@ref Sandbox.register_multiarch).
"""
function Base.run(config::SandboxConfig, cmd::Cmd; wait::Bool=true)
    register_multiarch(config)
    return run(command(config, cmd); wait)
end
