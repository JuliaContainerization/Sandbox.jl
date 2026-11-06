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
        # The tree was written by the sandbox, and `chmod` would follow a symlink to
        # wherever it points on the host.
        islink(path) && continue
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
        if isdir(path)
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

# The launcher's mount operations for the sandbox's /dev, /sys and cgroup view, then for
# `config.mounts`, parents before their children.  A mount replaces the defaults at or
# below its destination.
function mount_operations(config::SandboxConfig)
    defaults = Pair{String,Vector{String}}[
        "/dev" => ["--tmpfs", "/dev", "mode=0755"],
        ("/dev/$(node)" => ["--dev-bind", "/dev/$(node)", "/dev/$(node)"]
         for node in ("null", "zero", "full", "random", "urandom"))...,
        "/dev/tty" => ["--dev-bind-try", "/dev/tty", "/dev/tty"],
        "/dev/pts" => ["--devpts", "/dev/pts"],
        "/dev/ptmx" => ["--symlink", "pts/ptmx", "/dev/ptmx"],
        "/dev/fd" => ["--symlink", "/proc/self/fd", "/dev/fd"],
        ("/dev/$(name)" => ["--symlink", "/proc/self/fd/$(fd)", "/dev/$(name)"]
         for (fd, name) in zip(0:2, ("stdin", "stdout", "stderr")))...,
        "/dev/shm" => ["--tmpfs", "/dev/shm",
                       config.shm_size === nothing ? "mode=1777" : "mode=1777,size=$(config.shm_size)"],
        "/sys" => ["--ro-bind", "/sys", "/sys"],
        "/sys/fs/cgroup" => ["--cgroup", "/sys/fs/cgroup"],
    ]
    mounts = sort([m for m in config.mounts if m.first != "/"]; by=m -> splitpath(m.first))
    within(path, dir) = splitpath(path)[1:min(end, length(splitpath(dir)))] == splitpath(dir)
    ops = String[]
    for (dest, op) in defaults
        any(m -> within(dest, m.first), mounts) || append!(ops, op)
    end
    for (dest, info) in mounts
        # Device nodes in maps keep working, as they did before binds were nodev.
        flag = info.type == MountType.ReadOnly ? "--ro-dev-bind" :
               info.type == MountType.ReadWrite ? "--dev-bind" :
               info.type == MountType.Overlayed ? "--overlay" : "--ro-overlay"
        append!(ops, [flag, info.host_path, dest])
    end
    return ops
end

function build_executor_command(exe::UserNamespacesExecutor, config::SandboxConfig, user_cmd::Base.CmdRedirect)
    return Base.CmdRedirect(build_executor_command(exe, config, user_cmd.cmd), user_cmd.handle, user_cmd.stream_no, user_cmd.readable)
end

function build_executor_command(exe::UserNamespacesExecutor, config::SandboxConfig, user_cmd::Cmd)
    # While we would usually prefer to use the `executable_product()` function to get a
    # `Cmd` object that has all of the `PATH` and `LD_LIBRARY_PATH` environment variables
    # set properly so that the executable product can be run, we are careful to ensure
    # that `sandbox` has no dependencies (as much as that is possible).
    cmd_string = String[UserNSSandbox_jll.sandbox_path, "--protocol", "3"]
    isa(exe, PrivilegedUserNamespacesExecutor) && push!(cmd_string, "--privileged")

    # Enable verbose mode on the sandbox wrapper itself
    if config.verbose
        push!(cmd_string, "--verbose")
    end

    # Extract the rootfs, as it's treated specially
    append!(cmd_string, ["--rootfs", config.mounts["/"].host_path])

    # Add our `--cd` command
    append!(cmd_string, ["--cd", config.pwd])

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
        # The launcher picks `userxattr` itself.
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

    append!(cmd_string, mount_operations(config))

    # Finally, append the user-requested command string
    push!(cmd_string, "--")
    config.entrypoint === nothing || push!(cmd_string, config.entrypoint)
    append!(cmd_string, user_cmd.exec)

    # The sandboxed command gets the SandboxConfig's env, overridden by the user command's
    env = setenv(``, config.env)
    if user_cmd.env !== nothing
        env = addenv(env, user_cmd.env)
    end
    env = env.env

    # In privileged mode, run the sandbox through `sudo` (or `su`, if `sudo` doesn't exist)
    if isa(exe, PrivilegedUserNamespacesExecutor) && !isempty(sudo_cmd())
        if get(sudo_cmd(), 1, "") == "sudo"
            # sudo adds variables of its own (`HOME`, `USER`, `SUDO_*`, ...), and sudo-rs
            # doesn't support `-E`, so set the environment with `env -i` instead. The sandbox
            # reads the caller's IDs from `SUDO_UID` and `SUDO_GID`, and unsets them.
            prepend!(cmd_string, String[sudo_cmd()..., "/usr/bin/env", "-i", "--", env...,
                                        "SUDO_UID=$(getuid())", "SUDO_GID=$(getgid())"])
        else
            prepend!(cmd_string, sudo_cmd())
        end
        sandbox_cmd = setenv(Cmd(cmd_string), String[])
    else
        sandbox_cmd = setenv(Cmd(cmd_string), env)
    end

    # If the user has asked that this command be allowed to fail silently, pass that on
    if user_cmd.ignorestatus
        sandbox_cmd = ignorestatus(sandbox_cmd)
    end

    return sandbox_cmd
end

_userns_sysctl_props = ("apparmor_restrict_unprivileged_userns", "apparmor_restrict_unprivileged_unconfined")
function _userns_sysctl_path(prop; proc_sys::AbstractString="/proc/sys")
    return joinpath(proc_sys, "kernel", replace(prop, "." => "/"))
end

function _userns_sysctl_exists(prop; proc_sys::AbstractString="/proc/sys")
    return isfile(_userns_sysctl_path(prop; proc_sys))
end

function _read_userns_sysctl(prop; proc_sys::AbstractString="/proc/sys")
    if !_userns_sysctl_exists(prop; proc_sys)
        return nothing
    end

    try
        return readchomp(_userns_sysctl_path(prop; proc_sys))
    catch e
        if isa(e, Base.IOError)
            return nothing
        end
        rethrow(e)
    end
end

function _available_userns_sysctl_props(; sysctl_exists::Function=_userns_sysctl_exists)
    return String[prop for prop in _userns_sysctl_props if sysctl_exists(prop)]
end

function _restricted_userns_sysctl_props(; read_sysctl::Function=_read_userns_sysctl)
    failed_props = String[]
    for prop in _userns_sysctl_props
        if read_sysctl(prop) == "1"
            push!(failed_props, prop)
        end
    end
    return failed_props
end

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
    failed_props = _restricted_userns_sysctl_props()
    if !isempty(failed_props)
        @error("""
        You have likely run into an issue due to over-zealous apparmor protections:
        https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces

        To disable these protections, run: `Sandbox.disable_apparmor_userns_restrictions()`
        This will require your sudo password.
        """)
    end
end

function disable_apparmor_userns_restrictions()
    if !Sys.islinux()
        @info("AppArmor user namespace restrictions are Linux-specific; nothing to disable.")
        return nothing
    end

    available_props = _available_userns_sysctl_props()
    if isempty(available_props)
        @info("No AppArmor user namespace restriction sysctls found; nothing to disable.")
        return nothing
    end

    missing_props = setdiff(collect(_userns_sysctl_props), available_props)
    if !isempty(missing_props)
        @info("Skipping absent AppArmor user namespace restriction sysctls", missing_props)
    end

    sysctl_commands = IOBuffer()
    for prop in available_props
        println(sysctl_commands, "kernel.$(prop) = 0")
    end
    seekstart(sysctl_commands)
    run(pipeline(`sudo tee /etc/sysctl.d/99-sandbox-unprivileged-user-namespaces.conf`, stdin=sysctl_commands, stdout=devnull))
    for prop in available_props
        run(`sudo sysctl -w kernel.$(prop)=0`)
    end
end
