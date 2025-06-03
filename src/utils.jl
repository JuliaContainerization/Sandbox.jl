"""
    max_directory_ctime(prefix::String)

Takes the `stat()` of all files in a directory root, keeping the maximum ctime,
recursively.  Comparing just this value allows for quick directory change detection.
"""
function max_directory_ctime(prefix::String)
    max_time = 0.0
    for (root, dirs, files) in walkdir(prefix)
        for f in files
            max_time = max(max_time, lstat(joinpath(root, f)).ctime)
        end
    end
    return max_time
end

function get_mounts(;verbose::Bool = false)
    # Get a listing of the current mounts.  If we can't do this, just give up
    if !isfile("/proc/mounts")
        if verbose
            @info("Couldn't open /proc/mounts, returning...")
        end
        return Tuple{String,SubString{String}}[]
    end
    mounts = String(read("/proc/mounts"))

    # Grab the fstype and the mountpoints
    mounts = [split(m)[2:3] for m in split(mounts, "\n") if !isempty(m)]

    # Canonicalize mountpoints now so as to dodge symlink difficulties
    mounts = [(abspath(m[1]*"/"), m[2]) for m in mounts]
    return mounts
end

"""
    realpath_stem(path::AbstractString)

Given a path, return the `realpath` of it.  If it does not exist, try to
resolve the `realpath` of its containing directory, then append the tail
portion onto the end of that resolved stem.  This iterates until we find a stem
that can be resolved.

This allows for resolving directory symlinks halfway through a path, while not
requiring that the final path leaf exist at the time of calling
`realpath_stem()`.  Of course, if the final path leaf is itself a symlink, this
will not work correctly, so this should be considered a "best effort" function.

Internally, we use this to attempt to discover the actual mountpoint a mapping
is or will be stored on.
"""
function realpath_stem(path::AbstractString)
    if ispath(path)
        return realpath(path)
    end

    dir, leaf = splitdir(path)
    if dir == path
        # This shouldn't really be possible
        throw(ArgumentError("Unable to find any real component of path!"))
    end
    return joinpath(realpath_stem(dir), leaf)
end

"""
    is_ecryptfs(path::AbstractString; verbose::Bool=false)

Checks to see if the given `path` (or any parent directory) is placed upon an
`ecryptfs` mount.  This is known not to work on current kernels, see this bug
for more details: https://bugzilla.kernel.org/show_bug.cgi?id=197603

This method returns whether it is encrypted or not, and what mountpoint it used
to make that decision.
"""
function is_ecryptfs(path::AbstractString; verbose::Bool=false)
    # Canonicalize `path` immediately, and if it's a directory, add a "/" so
    # as to be consistent with the rest of this function
    path = abspath(path)
    if isdir(path)
        path = abspath(path * "/")
    end

    if verbose
        @info("Checking to see if $path is encrypted...")
    end

    # Get a listing of the current mounts.  If we can't do this, just give up
    mounts = get_mounts()
    if isempty(mounts)
        return false, path
    end

    # Fast-path asking for a mountpoint directly (e.g. not a subdirectory)
    direct_path = [m[1] == path for m in mounts]
    local parent
    if any(direct_path)
        parent = mounts[findfirst(direct_path)]
    else
        # Find the longest prefix mount:
        parent_mounts = [m for m in mounts if startswith(path, m[1])]
        if isempty(parent_mounts)
            # This is weird; this means that we can't find any mountpoints that
            # hold the given path.  I've only ever seen this in `chroot`'ed scenarios.
            return false, path
        end
        parent = parent_mounts[argmax(map(m->length(m[1]), parent_mounts))]
    end

    # Return true if this mountpoint is an ecryptfs mount
    val = parent[2] == "ecryptfs"
    if verbose && val
        @info("  -> $path is encrypted from mountpoint $(parent[1])")
    end
    return val, parent[1]
end

"""
    uname()

On Linux systems, return the strings returned by the `uname()` function in libc.
"""
function uname()
    @static if !Sys.islinux()
        return String[]
    end

    # The uname struct can have wildly differing layouts; we take advantage
    # of the fact that it is just a bunch of NULL-terminated strings laid out
    # one after the other, and that it is (as best as I can tell) at maximum
    # around 1.5KB long.  We bump up to 2KB to be safe.
    uname_struct = zeros(UInt8, 2048)
    ccall(:uname, Cint, (Ptr{UInt8},), uname_struct)

    # Parse out all the strings embedded within this struct
    strings = String[]
    idx = 1
    while idx < length(uname_struct)
        # Extract string
        new_string = unsafe_string(pointer(uname_struct, idx))
        push!(strings, new_string)
        idx += length(new_string) + 1

        # Skip trailing zeros
        while uname_struct[idx] == 0 && idx < length(uname_struct)
            idx += 1
        end
    end

    return strings
end

"""
    get_kernel_version(;verbose::Bool = false)

Use `uname()` to get the kernel version and parse it out as a `VersionNumber`,
returning `nothing` if parsing fails or this is not `Linux`.
"""
function get_kernel_version(;verbose::Bool = false)
    if !Sys.islinux()
        return nothing
    end

    uname_strings = try
        uname()
    catch e
        if isa(e, InterruptException)
            rethrow(e)
        end

        @warn("Unable to run `uname()` to check version number!")
        return nothing
    end

    # Some distributions tack extra stuff onto the version number.  We walk backwards
    # from the end, searching for the longest string that we can extract a VersionNumber
    # out of.  We choose a minimum length of 5, as all kernel version numbers will be at
    # least `X.Y.Z`.
    for end_idx in length(uname_strings[3]):-1:5
        try
            return VersionNumber(uname_strings[3][1:end_idx])
        catch e
            if isa(e, InterruptException)
                rethrow(e)
            end
        end
    end

    # We could never parse anything good out of it. :(
    if verbose
        @warn("Unablet to parse a VersionNumber out of uname output", uname_strings)
    end
    return nothing
end

"""
    get_loaded_modules()

Returns a list of modules currently loaded by the system.  On non-Linux platforms,
returns an empty list.
"""
function get_loaded_modules()
    @static if !Sys.islinux()
        return Vector{String}[]
    end

    !isfile("/proc/modules") && return Vector{SubString{String}}[]
    filter!(split.(readlines("/proc/modules"))) do (name, size, count, deps, state, addr)
        state == "Live"
    end
end

"""
    getuid()

Wrapper around libc's `getuid()` function
"""
getuid() = ccall(:getuid, Cint, ())

"""
    getgid()

Wrapper around libc's `getgid()` function
"""
getgid() = ccall(:getgid, Cint, ())

_sudo_cmd = nothing
function sudo_cmd()
    global _sudo_cmd

    # Use cached value if we've already run this
    if _sudo_cmd !== nothing
        return _sudo_cmd
    end

    if getuid() == 0
        # If we're already root, don't use any kind of sudo program
        _sudo_cmd = String[]
    elseif Sys.which("sudo") !== nothing && success(`sudo -V`)
        # If `sudo` is available, use that
        _sudo_cmd = ["sudo"]
    elseif Sys.which("su") !== nothing && success(`su --version`)
        # Fall back to `su` if all else fails
        _sudo_cmd = ["su", "root", "-c"]
    else
        @warn("No known sudo-like wrappers!")
        _sudo_cmd = String[]
    end
    return _sudo_cmd
end

_env_pref_dict = Dict{AbstractString,Union{AbstractString,Nothing}}()
"""
    load_env_pref(env_var, prefs_name, default)

Many pieces of `Sandbox.jl` functionality can be controlled either through
environment variables or preferences.  This utility function makes it easy
to check first the environment, then preferences, finally falling back to
the default.  Additionally, it memoizes the result in a caching dictionary.
"""
function load_env_pref(env_var::AbstractString, prefs_name::AbstractString,
                       default::Union{AbstractString,Nothing})
    if !haskey(_env_pref_dict, env_var)
        _env_pref_dict[env_var] = get(ENV, env_var, @load_preference(prefs_name, default))
    end

    return _env_pref_dict[env_var]
end

"""
    default_persist_root_dirs()

Returns the default list of directories that should be attempted to be used as
persistence storage.  Influenced by the `SANDBOX_PERSISTENCE_DIR` environment
variable, as well as the `persist_dir` preference.  The last place searched by
default is the `persist_dirs` scratch space.
"""
function default_persist_root_dirs()
    # While this function appears to be duplicating much of the logic within
    # `load_env_pref()`, it actually collects all of the given values, rather
    # than choosing just one.
    dirs = String[]

    # When doing nested sandboxing, we pass information via environment variables:
    if haskey(ENV, "SANDBOX_PERSISTENCE_DIR")
        push!(dirs, ENV["SANDBOX_PERSISTENCE_DIR"])
    end

    # If the user has set a persistence dir preference, try that too
    ppd_pref = @load_preference("persist_dir", nothing)
    if ppd_pref !== nothing
        push!(dirs, ppd_pref)
    end

    # Storing in a scratch space (which is within our writable depot) usually works,
    # except when our depot is on a `zfs` or `ecryptfs` mount, for example.
    push!(dirs, @get_scratch!("persist_dirs"))
    return dirs
end

function find_persist_dir_root(rootfs_path::String, dir_hints::Vector{String} = default_persist_root_dirs(); verbose::Bool = false)
    function probe_overlay_mount(rootfs_path, mount_path; verbose::Bool = false, userxattr::Bool = false)
        probe_exe = UserNSSandbox_jll.overlay_probe_path
        probe_args = String[]
        if verbose
            push!(probe_args, "--verbose")
        end
        if userxattr
            push!(probe_args, "--userxattr")
        end

        return success(run(pipeline(ignorestatus(
            `$(probe_exe) $(probe_args) $(realpath(rootfs_path)) $(realpath(mount_path))`
        ); stdout = verbose ? stdout : devnull, stderr = verbose ? stderr : devnull)))
    end

    # If one of our `dir_hints` works, use that, as those are typically our first
    # choices; things like a scratchspace, a user-supplied path, etc...
    for mount_path in dir_hints, userxattr in (true, false)
        if probe_overlay_mount(rootfs_path, mount_path; userxattr, verbose)
            return (mount_path, userxattr)
        end
    end

    # Otherwise, walk over the list of mounts, excluding mount types we know won't work
    disallowed_mount_types = Set([
        # ecryptfs doesn't play nicely with sandboxes at all
        "ecryptfs",
        # zfs does not support features (RENAME_WHITEOUT) required for overlay upper dirs
        "zfs",
        # overlays cannot stack, of course
        "overlay",

        # Exclude mount types that are not for storing data:
        "auristorfs",
        "autofs",
        "binfmt_misc",
        "bpf",
        "cgroup2",
        "configfs",
        "debugfs",
        "devpts",
        "devtmpfs",
        "efivarfs",
        "fusectl",
        "hugetlbfs",
        "mqueue",
        "proc",
        "pstore",
        "ramfs",
        "rpc_pipefs",
        "securityfs",
        "sysfs",
        "tracefs",
        "nsfs"
    ])

    mounts = first.(filter(((path, type),) -> type ∉ disallowed_mount_types, get_mounts()))

    # Filter each `mount` point on a set of criteria that we like (e.g. the mount point
    # is owned by us (user-specific `tmpdir`, for instance))
    function owned_by_me(path)
        try
            return stat(path).uid == getuid()
        catch e
            if isa(e, Base.IOError) && -e.code ∈ (Base.Libc.EACCES,)
                return false
            end
            rethrow(e)
        end
    end
    sort!(mounts; by = owned_by_me, rev=true)

    for mount_path in mounts, userxattr in (true, false)
        if probe_overlay_mount(rootfs_path, mount_path; userxattr, verbose)
            return (mount_path, userxattr)
        end
    end

    # Not able to find a SINGLE persistent directory location that works!
    return (nothing, false)
end
