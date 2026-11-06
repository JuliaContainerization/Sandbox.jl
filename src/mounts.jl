"""
    Mount

What goes at a destination in the sandbox: a [`Bind`](@ref), [`Overlay`](@ref),
[`Tmpfs`](@ref) or [`Symlink`](@ref), or, among the default mounts, `Sandbox.Devpts()` and
`Sandbox.CgroupView()`.
"""
abstract type Mount end

"""
    Bind(source; writable=false, devices=false, optional=false)

The host path `source` (a directory or a file), including the mounts below it.

- `writable`: writes go to `source`; otherwise it is read-only, including the mounts
  below it.
- `devices`: device nodes in it work, as for `/dev/kvm` or a GPU.  Otherwise they can't
  be opened.  Setuid bits never take effect.
- `optional`: skip it if `source` doesn't exist, rather than fail.
"""
struct Bind <: Mount
    source::String
    writable::Bool
    devices::Bool
    optional::Bool
end
Bind(source::AbstractString; writable::Bool=false, devices::Bool=false, optional::Bool=false) =
    Bind(String(source), writable, devices, optional)

"""
    Overlay(source; readonly=false)

The host directory `source`, with changes that go to the config's `persist` directory (or
are gone after the run without one) instead of `source`.

The changes are kept per destination: with `readonly=true`, an overlay shows (read-only)
what an earlier overlay at the same destination wrote to the same `persist` directory,
over `source`.
"""
struct Overlay <: Mount
    source::String
    readonly::Bool
end
Overlay(source::AbstractString; readonly::Bool=false) = Overlay(String(source), readonly)

"""
    Tmpfs(; size=nothing, mode=0o755)

A fresh tmpfs, of at most `size` bytes (an integer, or a string such as `"1G"` or `"50%"`
of the memory; by default, half of the memory), whose root directory has permissions
`mode`.
"""
struct Tmpfs <: Mount
    size::Union{Nothing,String}
    mode::UInt16
    function Tmpfs(; size::Union{Nothing,Integer,AbstractString}=nothing, mode::Integer=0o755)
        if size !== nothing
            size = string(size)
            occursin(r"^[0-9]+[kKmMgG%]?$", size) || throw(ArgumentError("invalid tmpfs size \"$(size)\""))
        end
        0 <= mode <= 0o7777 || throw(ArgumentError("invalid mode $(string(mode, base=8))"))
        return new(size, mode)
    end
end

"""
    Symlink(target)

A symbolic link to `target`, which is resolved in the sandbox.  A link that is already
there with the same target is fine; anything else there is an error.
"""
struct Symlink <: Mount
    target::String
end
Symlink(target::AbstractString) = Symlink(String(target))

"""
    Sandbox.Devpts()

A new instance of devpts, for the pseudo-terminals of the sandbox.
"""
struct Devpts <: Mount end

"""
    Sandbox.CgroupView()

The sandbox's cgroup, read-only, as the root of a cgroup2 hierarchy: limits can be read
but not changed, and no other cgroup is visible.  On hosts without cgroup2, an empty
read-only directory.
"""
struct CgroupView <: Mount end

operation(dest, m::Bind) = String[
    string("--", m.writable ? "" : "ro-", m.devices ? "dev-" : "", "bind", m.optional ? "-try" : ""),
    m.source, dest]
operation(dest, m::Overlay) = String[m.readonly ? "--ro-overlay" : "--overlay", m.source, dest]
operation(dest, m::Tmpfs) = String["--tmpfs", dest,
    join(["mode=$(string(m.mode, base=8))"; m.size === nothing ? String[] : ["size=$(m.size)"]], ",")]
operation(dest, m::Symlink) = String["--symlink", m.target, dest]
operation(dest, ::Devpts) = String["--devpts", dest]
operation(dest, ::CgroupView) = String["--cgroup", dest]

"""
    Sandbox.default_mounts()

The mounts every sandbox gets before those of its config, unless it says
`defaults=false`: a fresh `/dev` with the usual device nodes, pseudo-terminals and
`/dev/shm`, the host's `/sys` read-only, and a read-only view of the sandbox's cgroup.
(/proc is always the procfs of the sandbox's PID namespace.)
"""
function default_mounts()
    mounts = Pair{String,Mount}["/dev" => Tmpfs(mode=0o755)]
    for node in ("null", "zero", "full", "random", "urandom")
        push!(mounts, "/dev/$(node)" => Bind("/dev/$(node)"; writable=true, devices=true))
    end
    append!(mounts, Pair{String,Mount}[
        "/dev/tty" => Bind("/dev/tty"; writable=true, devices=true, optional=true),
        "/dev/pts" => Devpts(),
        "/dev/ptmx" => Symlink("pts/ptmx"),
        "/dev/fd" => Symlink("/proc/self/fd"),
        "/dev/stdin" => Symlink("/proc/self/fd/0"),
        "/dev/stdout" => Symlink("/proc/self/fd/1"),
        "/dev/stderr" => Symlink("/proc/self/fd/2"),
        "/dev/shm" => Tmpfs(mode=0o1777),
        "/sys" => Bind("/sys"),
        "/sys/fs/cgroup" => CgroupView(),
    ])
    return mounts
end

# Normalizes a destination, lexically; the launcher resolves it in the sandbox.
function destination(path::AbstractString)
    startswith(path, "/") || throw(ArgumentError("mount destination \"$(path)\" is not absolute"))
    path = normpath(path)
    length(path) > 1 && endswith(path, "/") && (path = chop(path))
    path == "/" && throw(ArgumentError("the root of the sandbox is its `rootfs`, not a mount"))
    within(path, "/proc") && throw(ArgumentError("mount destination \"$(path)\" is in /proc, which the sandbox mounts itself"))
    return String(path)
end

# Whether `path` is `dir` or below it.
within(path, dir) = (p = splitpath(path); d = splitpath(dir); length(p) >= length(d) && p[1:length(d)] == d)

# The mounts given to `SandboxConfig`, in order: a vector as it is, a dictionary with
# parents before their children.
function normalize_mounts(mounts::AbstractVector)
    normalized = Pair{String,Mount}[]
    for m in mounts
        m isa Pair && m.first isa AbstractString && m.second isa Mount ||
            throw(ArgumentError("mounts must be `destination => mount` pairs, not $(repr(m))"))
        push!(normalized, destination(m.first) => m.second)
    end
    return normalized
end
normalize_mounts(mounts::AbstractDict) =
    sort!(normalize_mounts(collect(mounts)); by=m -> splitpath(m.first))
