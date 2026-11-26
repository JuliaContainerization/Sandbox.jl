"""
    Sandbox.getuid()

The user id of the calling process.
"""
getuid() = ccall(:getuid, Cuint, ())

"""
    Sandbox.getgid()

The group id of the calling process.
"""
getgid() = ccall(:getgid, Cuint, ())

const _userns_sysctl_props = ("apparmor_restrict_unprivileged_userns", "apparmor_restrict_unprivileged_unconfined")
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

# Since 23.10, Ubuntu keeps unconfined processes from creating user namespaces with
# AppArmor.  Lifting that for our launcher alone would take an AppArmor profile for its
# content-addressed path, so we can only point at the sysctls.
function check_restricted_unprivileged_userns()
    if !Sys.islinux()
        return
    end
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

"""
    Sandbox.disable_apparmor_userns_restrictions()

Lifts Ubuntu's AppArmor restrictions on unprivileged user namespaces, which the `:userns`
mode needs, now and at boot (in `/etc/sysctl.d`).  Uses `sudo`.
"""
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
