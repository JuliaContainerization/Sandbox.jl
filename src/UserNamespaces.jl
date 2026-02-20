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
        if !islink(path) && isdir(path)
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
    userxattr::Bool
    UnprivilegedUserNamespacesExecutor() = new(nothing, false)
end
mutable struct PrivilegedUserNamespacesExecutor <: UserNamespacesExecutor
    persistence_dir::Union{String,Nothing}
    userxattr::Bool
    PrivilegedUserNamespacesExecutor() = new(nothing, false)
end

Base.show(io::IO, exe::UnprivilegedUserNamespacesExecutor) = write(io, "Unprivileged User Namespaces Executor")
Base.show(io::IO, exe::PrivilegedUserNamespacesExecutor) = write(io, "Privileged User Namespaces Executor")

function executor_available(::Type{T}; verbose::Bool=false) where {T <: UserNamespacesExecutor}
    # If we're on a platform that doesn't even have `sandbox` available, return false
    if !UserNSSandbox_jll.is_available()
        return false
    end
    return with_executor(T) do exe
        ret = check_kernel_version(;verbose) &&
               check_overlayfs_loaded(;verbose) &&
               probe_executor(exe; verbose)
        if T == UnprivilegedUserNamespacesExecutor && !ret
            check_restricted_unprivileged_userns()
        end
        return ret
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

function build_executor_command(exe::UserNamespacesExecutor, config::SandboxConfig, user_cmd::Base.CmdRedirect)
    return Base.CmdRedirect(build_executor_command(exe, config, user_cmd.cmd), user_cmd.handle, user_cmd.stream_no, user_cmd.readable)
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
    append!(cmd_string, ["--rootfs", config.mounts["/"].host_path])

    # Add our `--cd` command
    append!(cmd_string, ["--cd", config.pwd])

    # Add in read-only mappings (skipping the rootfs)
    # Sort mounts by path length (longest first) because userns processes mounts back to front
    sorted_mounts = sort(collect(config.mounts), by=x->length(x[1]), rev=true)
    for (sandbox_path, mount_info) in sorted_mounts
        if sandbox_path == "/"
            continue
        end
        local mount_type_str
        if mount_info.type == MountType.ReadOnly
            mount_type_str = ":ro"
        elseif mount_info.type == MountType.ReadWrite
            mount_type_str = ":rw"
        elseif mount_info.type == MountType.Overlayed
            mount_type_str = ":ov"
        elseif mount_info.type == MountType.OverlayedReadOnly
            mount_type_str = ":rov"
        else
            throw(ArgumentError("Unknown mount type: $(mount_info.type)"))
        end
        append!(cmd_string, ["--mount", "$(mount_info.host_path):$(sandbox_path)$(mount_type_str)"])
    end

    # Add in entrypoint, if it is set
    if config.entrypoint !== nothing
        append!(cmd_string, ["--entrypoint", config.entrypoint])
    end

    # If we have a `--persist` argument, check to see if we already have a persistence_dir
    # setup, if we do not, create a temporary directory and set it into our executor
    if config.persist
        if exe.persistence_dir === nothing
            # Search for a functional persistence directory
            persist_root, userxattr = find_persist_dir_root(config.mounts["/"].host_path; verbose=config.verbose)

            if persist_root === nothing
                throw(ArgumentError("Unable to find a persistence directory root that works!"))
            end
            exe.persistence_dir = mktempdir(persist_root)
            exe.userxattr = userxattr
        end
        append!(cmd_string, ["--persist", exe.persistence_dir])

        if exe.userxattr
            push!(cmd_string, "--userxattr")
        end
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

_userns_sysctl_props = ("apparmor_restrict_unprivileged_userns", "apparmor_restrict_unprivileged_unconfined")
function check_restricted_unprivileged_userns()
    if !Sys.islinux()
        return
    end

    # Ubuntu 23.10 is slowly choking off our access to unprivileged user namespaces.
    # In particular, they have made it so that `unconfined` isn't actually unconfined,
    # and is unable to create unprivileged user namespaces.  This is super frustrating,
    # because there's no way to launch a process using unpriv userns without needing
    # superuser intervention (e.g. to create an apparmor profile).  Furthermore, it's
    # annoying to even install one, as the path to our executable is unreliable, since
    # it's in a content-addressed location.
    #
    # And so, I regret more and more every day that I don't just give up and reimplement
    # everything on top of podman.  Until then, just ask the user to turn off these
    # annoying protections:
    if Sys.which("sysctl") !== nothing
        failed_props = String[]
        for prop in _userns_sysctl_props
            if readchomp(`sysctl kernel.$(prop)`) == "kernel.$(prop) = 1"
                push!(failed_props, prop)
            end
        end
        if !isempty(failed_props)
            @error("""
            You have likely run into an issue due to over-zealous apparmor protections:
            https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces

            To disable these protections, run: `Sandbox.disable_apparmor_userns_restrictions()`
            This will require your sudo password.
            """)
        end
    end
end

function disable_apparmor_userns_restrictions()
    sysctl_commands = IOBuffer()
    for prop in _userns_sysctl_props
        println(sysctl_commands, "kernel.$(prop) = 0")
    end
    seekstart(sysctl_commands)
    run(pipeline(`sudo tee /etc/sysctl.d/99-sandbox-unprivileged-user-namespaces.conf`, stdin=sysctl_commands, stdout=devnull))
    for prop in _userns_sysctl_props
        run(`sudo sysctl -w kernel.$(prop)=0`)
    end
end
