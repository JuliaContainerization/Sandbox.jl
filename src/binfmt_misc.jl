using Base.BinaryPlatforms

"""
    check_binfmt_misc_loaded()

Check that the `binfmt_misc` kernel module is loaded and enabled.
"""
function check_binfmt_misc_loaded()
    # If we're not running on Linux, then clearly `binfmt_misc` is not available
    if !Sys.islinux()
        return false
    end

    # If the `binfmt_misc` directory doesn't exist, the kernel module is likely not installed
    if !isdir("/proc/sys/fs/binfmt_misc")
        return false
    end

    # If the `status` file does not exist, the kernel module may not be loaded, or the
    # special `binfmt_misc` filesystem may not be mounted.
    if !isfile("/proc/sys/fs/binfmt_misc/status")
        return false
    end

    # Finally, check that the module itself has not been disabled.
    return strip(String(read("/proc/sys/fs/binfmt_misc/status"))) == "enabled"
end

"""
    BinFmtRegistration

Provides a structured view of a `binfmt_misc` interpreter registration.  Note that only "magic"
matching rules are allowed, we do not support "extension" matching rules.
"""
struct BinFmtRegistration
    name::String
    interpreter::String
    flags::Vector{Symbol}
    offset::Int64
    magic::Vector{UInt8}
    mask::Vector{UInt8}

    function BinFmtRegistration(name::AbstractString,
                                interpreter::AbstractString,
                                flags::Union{AbstractString,Vector{Symbol}},
                                offset::Integer,
                                magic::Vector{UInt8},
                                mask::Union{Nothing,Vector{UInt8}} = nothing)
        # Default mask is all `0xff`.
        if mask === nothing
            mask = UInt8[0xff for _ in 1:length(magic)]
        end
        if isa(flags, AbstractString)
            flags = Symbol.(collect(flags))
        end
        return new(String(name), String(interpreter), sort(flags), Int64(offset), magic, mask)
    end
end

"""
    register_string(reg::BinFmtRegistration)

Constructs the string used to register a `binfmt_misc` registration with the `register`
file endpoint within `/proc/sys/fs/binfmt_misc/register`.  To actually register the
interpreter, use `write_binfmt_misc_registration()`.
"""
function register_string(reg::BinFmtRegistration)
    return string(
        ":",
        reg.name,
        ":",
        # We only support `magic` style registrations
        "M",
        ":",
        string(reg.offset),
        ":",
        # We need to actually emit double-escaped hex codes, since that's what `/register` expects.
        join([string("\\x", string(x, base=16, pad=2)) for x in reg.magic], ""),
        ":",
        join([string("\\x", string(x, base=16, pad=2)) for x in reg.mask], ""),
        ":",
        reg.interpreter,
        ":",
        join(String.(reg.flags), ""),
    )
end

macro check_specified(name)
    return quote
        if $(esc(name)) === nothing
            throw(ArgumentError($("Error, $(name) must be specified")))
        end
    end
end

"""
    BinFmtRegistration(file::String)

Reads a `binfmt_misc` registration in from disk, if it cannot be parsed (because it is
malformed, or uses unsupported features) it an `ArgumentError` will be thrown.
"""
function BinFmtRegistration(file::String)
    enabled = false
    interpreter = nothing
    flags = nothing
    offset = nothing
    magic = nothing
    mask = nothing
    for l in strip.(filter(!isempty, split(String(read(file)), "\n")))
        # Handle enabled/disabled line
        if l in ("enabled", "disabled")
            enabled = l == "enabled"
        elseif startswith(l, "interpreter ")
            interpreter = l[13:end]
        elseif startswith(l, "flags:")
            flags = l[8:end]
        elseif startswith(l, "offset ")
            offset = parse(Int64, l[8:end])
        elseif startswith(l, "magic ")
            magic = hex2bytes(l[7:end])
        elseif startswith(l, "mask ")
            mask = hex2bytes(l[6:end])
        else
            @warn("Unknown `binfmt_misc` configuration directive", line=l)
        end
    end

    # Ensure we are only dealing with properly fully-specified binfmt_misc registrations
    @check_specified interpreter
    @check_specified flags
    @check_specified offset
    @check_specified magic

    # If we found a disabled binfmt_misc registration, just ignore it
    if !enabled
        return nothing
    end

    return BinFmtRegistration(basename(file), interpreter, flags, offset, magic, mask)
end

function formats_match(a::BinFmtRegistration, b::BinFmtRegistration)
    return (a.magic .& a.mask) == (b.magic .& b.mask)
end


"""
    read_binfmt_misc_registrations()

Return a list of `BinFmtRegistration` objects, one per readable registration, as found
sitting in `/proc/sys/fs/binfmt_misc/*`.  Registrations that cannot be parsed are
silently ignored.
"""
function read_binfmt_misc_registrations()
    if !check_binfmt_misc_loaded()
        return String[]
    end

    registrations = BinFmtRegistration[]
    for f in readdir("/proc/sys/fs/binfmt_misc"; join=true)
        # Skip "special" files
        if basename(f) ∈ ("register", "status")
            continue
        end

        try
            reg = BinFmtRegistration(f)
            if reg !== nothing
                push!(registrations, reg)
            end
        catch e
            if isa(e, ArgumentError)
                continue
            end
            rethrow(e)
        end
    end
    return registrations
end

sudo_tee(f::Function, path::String) = open(f, Cmd([sudo_cmd()..., "tee", "-a", path]), write=true)

"""
    write_binfmt_misc_registration(reg::BinFmtRegistration)

Write a `binfmt_misc` registration out to the kernel's `register` file endpoint.
Requires `sudo` privileges.
"""
function write_binfmt_misc_registration!(reg::BinFmtRegistration)
    try
        sudo_tee("/proc/sys/fs/binfmt_misc/register") do io
            write(io, register_string(reg))
        end
    catch e
        @error("Unable to register binfmt_misc format", register_string=register_string(reg))
        rethrow(e)
    end
end

function clear_binfmt_misc_registrations!()
    sudo_tee("/proc/sys/fs/binfmt_misc/status") do io
        write(io, "-1")
    end
    return nothing
end

"""
    register_requested_formats(formats::Vector{BinFmtRegistration})

Given the list of `binfmt_misc` formats, check the currently-registered formats through
`read_binfmt_misc_registrations()`, check to see if any in `formats` are not yet
registered, and if they are not, call `write_binfmt_misc_registration!()` to register
it with an artifact-sourced `qemu-*-static` binary.
"""
function register_requested_formats!(formats::Vector{BinFmtRegistration}; verbose::Bool = false)
    # Do nothing if we're not asking for any formats.
    if isempty(formats)
        return nothing
    end

    # Read in the current binfmt_misc registrations:
    if !check_binfmt_misc_loaded()
        error("Cannot provide multiarch support if `binfmt_misc` not loaded!")
    end
    regs = read_binfmt_misc_registrations()

    # For each format, If there are no pre-existing registrations add it to `formats_to_register`
    formats_to_register = BinFmtRegistration[]
    for reg in formats
        if !any(formats_match.(Ref(reg), regs))
            # This artifact contains the necessary QEMU executable (for the current host
            # architecture). Older QEMU builds, which we still use for 64-bit guests on
            # 32-bit hosts, name it with a `-static` suffix.
            interpreter = joinpath(@artifact_str(reg.name), reg.name)
            if !isfile(interpreter)
                interpreter *= "-static"
            end
            push!(formats_to_register, BinFmtRegistration(
                reg.name,
                interpreter,
                reg.flags,
                reg.offset,
                reg.magic,
                reg.mask,
            ))
        end
    end

    # Notify the user if we have any formats to register, then register them.
    if !isempty(formats_to_register)
        format_names = sort([f.name for f in formats_to_register])
        msg = "Registering $(length(formats_to_register)) binfmt_misc entries, this may ask for your `sudo` password."
        if verbose
            @info(msg, formats=format_names)
        elseif (Sys.which("sudo") !== nothing) && (success(`sudo -k -n true`))
            # in this case, we know that `sudo` will not prompt the user for a password
        else
            @info(msg)
        end
        write_binfmt_misc_registration!.(formats_to_register)
    end
    return nothing
end


## binfmt_misc registration templates for various architectures.
## Note that these are true no matter the host architecture; e.g. these
## can just as easily point at `x86_64-qemu-aarch64-static` as `ppc64le-qemu-aarch64-static`.
## In fact, the interpreter path typically gets overwritten in `build_executor_command` anyway.
const qemu_x86_64 = BinFmtRegistration(
    "qemu-x86_64",
    "/usr/bin/qemu-x86_64-static",
    "OFC",
    0,
    UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x3e, 0x00],
    UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xfe, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
)
const qemu_i386 = BinFmtRegistration(
    "qemu-i386",
    "/usr/bin/qemu-i386-static",
    "OFC",
    0,
    UInt8[0x7f, 0x45, 0x4c, 0x46, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x03, 0x00],
    UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xfe, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
)
const qemu_aarch64 = BinFmtRegistration(
    "qemu-aarch64",
    "/usr/bin/qemu-aarch64-static",
    "OFC",
    0,
    UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0xb7, 0x00],
    UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
)
const qemu_arm = BinFmtRegistration(
    "qemu-arm",
    "/usr/bin/qemu-arm-static",
    "OFC",
    0,
    UInt8[0x7f, 0x45, 0x4c, 0x46, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x28, 0x00],
    UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff],
)
const qemu_ppc64le = BinFmtRegistration(
    "qemu-ppc64le",
    "/usr/bin/qemu-ppc64le-static",
    "OFC",
    0,
    UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x15, 0x00],
    UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfc, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xff, 0xff, 0x00],
)

const platform_qemu_registrations = Dict(
    # We register these `qemu-*-static` executables as capable of interpreting both `glibc` and `musl` platforms:
    Platform("x86_64", "linux"; libc="glibc") => qemu_x86_64,
    Platform("x86_64", "linux"; libc="musl") => qemu_x86_64,
    Platform("i686", "linux"; libc="glibc") => qemu_i386,
    Platform("i686", "linux"; libc="musl") => qemu_i386,
    Platform("aarch64", "linux"; libc="glibc") => qemu_aarch64,
    Platform("aarch64", "linux"; libc="musl") => qemu_aarch64,
    Platform("armv7l", "linux"; libc="glibc") => qemu_arm,
    Platform("armv7l", "linux"; libc="musl") => qemu_arm,
    Platform("ppc64le", "linux"; libc="glibc") => qemu_ppc64le,
    Platform("ppc64le", "linux"; libc="musl") => qemu_ppc64le,
)

# Define what is a natively-runnable
const host_arch = arch(HostPlatform())
function natively_runnable(p::Platform)
    if host_arch == "x86_64"
        return arch(p) ∈ ("x86_64", "i686")
    end
    # Disabling this for now until I figure out how to reliably determine whether this is true.
    #=
    if host_arch == "aarch64"
        return arch(p) ∈ ("aarch64", "armv7l")
    end
    =#
    return host_arch == arch(p)
end
