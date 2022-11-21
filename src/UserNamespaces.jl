using UserNSSandbox_jll

# Use User Namespaces to provide isolation on Linux hosts whose kernels support it
export UserNamespacesExecutor, UnprivilegedUserNamespacesExecutor, PrivilegedUserNamespacesExecutor

abstract type UserNamespacesExecutor <: SandboxExecutor; end

# A version of `chmod()` that hides all of its errors.
function chmod_recursive(root::String, perms, use_sudo::Bool)
    files = String[]
    try
        files = readdir(root)
    catch e
        if !isa(e, Base.IOError)
            rethrow(e)
        end
    end
    for f in files
        path = joinpath(root, f)
        try
            if use_sudo
                run(`$(sudo_cmd()) chmod $(string(perms, base=8)) $(path)`)
            else
                chmod(path, perms)
            end
        catch e
            if !isa(e, Base.IOError)
                rethrow(e)
            end
        end
        if isdir(path) && !islink(path)
            chmod_recursive(path, perms, use_sudo)
        end
    end
end


function cleanup(exe::UserNamespacesExecutor)
    if exe.persistence_dir !== nothing && isdir(exe.persistence_dir)
        # Because a lot of these files are unreadable, we must `chmod +r` them before deleting
        chmod_recursive(exe.persistence_dir, 0o777, isa(exe, PrivilegedUserNamespacesExecutor))
        try
            rm(exe.persistence_dir; force=true, recursive=true)
        catch
        end
    end
end

# Because we can run in "privileged" or "unprivileged" mode, let's treat
# these as two separate, but very similar, executors.
mutable struct UnprivilegedUserNamespacesExecutor <: UserNamespacesExecutor
    persistence_dir::Union{String,Nothing}
    UnprivilegedUserNamespacesExecutor() = new(nothing)
end
mutable struct PrivilegedUserNamespacesExecutor <: UserNamespacesExecutor
    persistence_dir::Union{String,Nothing}
    PrivilegedUserNamespacesExecutor() = new(nothing)
end

Base.show(io::IO, exe::UnprivilegedUserNamespacesExecutor) = write(io, "Unprivileged User Namespaces Executor")
Base.show(io::IO, exe::PrivilegedUserNamespacesExecutor) = write(io, "Privileged User Namespaces Executor")

function executor_available(::Type{T}; verbose::Bool=false) where {T <: UserNamespacesExecutor}
    # If we're on a platform that doesn't even have `sandbox` available, return false
    if !UserNSSandbox_jll.is_available()
        return false
    end
    return with_executor(T) do exe
        return check_kernel_version(;verbose) &&
               check_overlayfs_loaded(;verbose) &&
               probe_executor(exe; test_read_only_map=true, test_read_write_map=true, verbose)
    end
end

function check_kernel_version(;verbose::Bool = false)
    # Don't bother to do anything on non-Linux
    if !Sys.islinux()
        return false
    end
    kernel_version = get_kernel_version()

    # If we were unable to parse any part of the version number, then warn and exit.
    if kernel_version === nothing
        @warn("Unable to check version number")
        return false
    end

    # Otherwise, we have a kernel version and if it's too old, we should freak out.
    if kernel_version < v"3.18"
        @warn("Kernel version too old: detected $(kernel_version), need at least 3.18!")
        return false
    end

    if verbose
        @info("Parsed kernel version \"$(kernel_version)\"")
    end
    return true
end

function check_overlayfs_loaded(;verbose::Bool = false)
    if !Sys.islinux()
        return false
    end

    # If the user has disabled this check, return `true`
    if parse(Bool, get(ENV, "SANDBOX_SKIP_OVERLAYFS_CHECK", "false"))
        return true
    end

    mods = get_loaded_modules()
    if verbose
        @info("Found $(length(mods)) loaded modules")
    end

    filter!(mods) do (name, size, count, deps, state, addr)
        return name == "overlay"
    end
    if isempty(mods)
        @warn("""
              The `overlay` kernel module is needed for the UserNS executors, but could not find it loaded.
              Try `sudo modprobe overlay` or export SANDBOX_SKIP_OVERLAYFS_CHECK=true to disable this check!
              """)
        return false
    end

    if verbose
        @info("Found loaded `overlay` module")
    end
    return true
end

function build_executor_command(exe::UserNamespacesExecutor, config::SandboxConfig, user_cmd::Cmd)
    # While we would usually prefer to use the `executable_product()` function to get a
    # `Cmd` object that has all of the `PATH` and `LD_LIBRARY_PATH` environment variables
    # set properly so that the executable product can be run, we are careful to ensure
    # that `sandbox` has no dependencies (as much as that is possible).
    cmd_string = String[UserNSSandbox_jll.sandbox_path]

    # Enable verbose mode on the sandbox wrapper itself
    if config.verbose
        push!(cmd_string, "--verbose")
    end

    # Extract the rootfs, as it's treated specially
    append!(cmd_string, ["--rootfs", config.read_only_maps["/"]])

    # Add our `--cd` command
    append!(cmd_string, ["--cd", config.pwd])

    # Add in read-only mappings (skipping the rootfs)
    for (dst, src) in config.read_only_maps
        if dst == "/"
            continue
        end
        append!(cmd_string, ["--map", "$(src):$(dst)"])
    end

    # Add in read-write mappings
    for (dst, src) in config.read_write_maps
        append!(cmd_string, ["--workspace", "$(src):$(dst)"])
    end

    # Add in overlay mappings
    for (dst, src) in config.overlay_maps
        config.persist || error("Cannot use overlay mappings without persistence enabled")
        append!(cmd_string, ["--overlay", "$(src):$(dst)"])
    end

    # Add in entrypoint, if it is set
    if config.entrypoint !== nothing
        append!(cmd_string, ["--entrypoint", config.entrypoint])
    end

    # If we have a `--persist` argument, check to see if we already have a persistence_dir
    # setup, if we do not, create a temporary directory and set it into our executor
    if config.persist
        if exe.persistence_dir === nothing
            persist_parent_dir = get(ENV, "SANDBOX_PERSISTENCE_DIR", tempdir())
            mkpath(persist_parent_dir)
            exe.persistence_dir = mktempdir(persist_parent_dir)
        end
        append!(cmd_string, ["--persist", exe.persistence_dir])
    end

    # For each platform requested by `multiarch`, ensure its matching interpreter is registered.
    register_requested_formats!(config.multiarch_formats; verbose=config.verbose)

    # Set the user and group, if requested
    append!(cmd_string, ["--uid", string(config.uid), "--gid", string(config.gid)])

    # Set the custom tmpfs_size, if requested
    if config.tmpfs_size !== nothing
        append!(cmd_string, ["--tmpfs-size", config.tmpfs_size])
    end

    if config.hostname !== nothing
        append!(cmd_string, ["--hostname", config.hostname])
    end

    # If we're running in privileged mode, we need to add `sudo` (or `su`, if `sudo` doesn't exist)
    if isa(exe, PrivilegedUserNamespacesExecutor)
        # Next, prefer `sudo`, but allow fallback to `su`. Also, force-set our
        # environmental mappings with sudo, because many of these are often  lost
        # and forgotten due to `sudo` restrictions on setting `LD_LIBRARY_PATH`, etc...
        if get(sudo_cmd(), 1, "") == "sudo"
            sudo_envs = vcat([["-E", "$k=$(config.env[k])"] for k in keys(config.env)]...)
            if user_cmd.env !== nothing
                append!(sudo_envs, vcat([["-E", pair] for pair in user_cmd.env]...))
            end
            prepend!(cmd_string, String[sudo_cmd()..., sudo_envs...])
        else
            prepend!(cmd_string, sudo_cmd())
        end
    end

    # Finally, append the user-requested command string
    push!(cmd_string, "--")
    append!(cmd_string, user_cmd.exec)

    # Construct a `Cmd` object off of those, with the SandboxConfig's env (if this is an unprivileged runner):
    sandbox_cmd = setenv(Cmd(cmd_string), String[])
    if isa(exe, UnprivilegedUserNamespacesExecutor)
        sandbox_cmd = setenv(sandbox_cmd, config.env)

        # If the user has provided an environment with their command, merge that in as well
        if user_cmd.env !== nothing
            sandbox_cmd = addenv(sandbox_cmd, user_cmd.env)
        end
    end

    # If the user has asked that this command be allowed to fail silently, pass that on
    if user_cmd.ignorestatus
        sandbox_cmd = ignorestatus(sandbox_cmd)
    end

    return sandbox_cmd
end
