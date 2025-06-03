module Sandbox
using Preferences, Scratch, LazyArtifacts, TOML, Libdl

import Base: run, success
export SandboxExecutor, DockerExecutor, UserNamespacesExecutor, SandboxConfig,
       preferred_executor, executor_available, probe_executor, run, cleanup, with_executor
using Base.BinaryPlatforms

# Include some utilities for things like file manipulation, uname() parsing, etc...
include("utils.jl")

"""
    SandboxExecutor

This represents the base type for all execution backends within this package.
Valid concrete subtypes must implement at least the following methods:

* `T()`: no-argument constructor to ready an execution engine with all defaults.

* `executor_available(::DataType{T})`: Checks whether executor type `T` is available
  on this system.  For example, `UserNamespacesExecutor`s are only available on
  Linux, and even then only on certain kernels.  Availablility checks may run a
  program to determine whether that executor is actually available.

* `build_executor_command(exe::T, config::SandboxConfig, cmd::Cmd)`: Builds the
  `Cmd` object that, when run, executes the user's desired command within the given
  sandbox.  The `config` object contains all necessary metadata such as shard
  mappings, environment variables, `stdin`/`stdout`/`stderr` redirection, etc...

* `cleanup(exe::T)`: Cleans up any persistent data storage that this executor may
  have built up over the course of its execution.

Note that while you can manually construct and cleanup an executor, it is recommended
that users instead make use of the `with_executor()` convenience function:

    with_executor(UnprivilegedUserNamespacesExecutor) do exe
        run(exe, config, ...)
    end
"""
abstract type SandboxExecutor; end

# Utilities to help with reading `binfmt_misc` entries in `/proc`
include("binfmt_misc.jl")

# Our SandboxConfig object, defining the environment sandboxed executions happen within
include("SandboxConfig.jl")

# Load the Docker executor
include("Docker.jl")

# Load the UserNamespace executor
include("UserNamespaces.jl")

all_executors = Type{<:SandboxExecutor}[
    # We always prefer the UserNamespaces executor, if we can use it,
    # and the unprivileged one most of all.  Only after that do we try `docker`.
    UnprivilegedUserNamespacesExecutor,
    PrivilegedUserNamespacesExecutor,
    DockerExecutor,
]

function select_executor(verbose::Bool)
    # If `FORCE_SANDBOX_MODE` is set, we're a nested Sandbox.jl invocation, and we should always use whatever it says
    executor = load_env_pref("FORCE_SANDBOX_MODE", "executor", nothing)
    if executor !== nothing
        executor = lowercase(executor)
        if executor ∈ ("unprivilegedusernamespacesexecutor", "unprivileged", "userns")
            return UnprivilegedUserNamespacesExecutor
        elseif executor ∈ ("privilegedusernamespacesexecutor", "privileged")
            return PrivilegedUserNamespacesExecutor
        elseif executor ∈ ("dockerexecutor", "docker")
            return DockerExecutor
        end
    end

    # Otherwise, just try them in priority order
    for executor in all_executors
        if executor_available(executor; verbose)
            return executor
        end
    end
    error("""Could not find any available executors for $(triplet(HostPlatform()))!
             On Linux this could mean user namespaces are unavailable.
             On macOS and Windows this could mean Docker is not installed.""")
end

_preferred_executor = nothing
const _preferred_executor_lock = ReentrantLock()
function preferred_executor(;verbose::Bool = false)
    lock(_preferred_executor_lock) do
        # If we've already asked this question, return the old answer
        global _preferred_executor
        if _preferred_executor === nothing
            _preferred_executor = select_executor(verbose)
        end
        return _preferred_executor
    end
end

# Helper function for warning about privileged execution trying to invoke `sudo`
function warn_priviledged(::PrivilegedUserNamespacesExecutor)
    @info("Running privileged container via `sudo`, may ask for your password:", maxlog=1)
    return nothing
end
warn_priviledged(::SandboxExecutor) = nothing

for f in (:run, :success)
    @eval begin
        function $f(exe::SandboxExecutor, config::SandboxConfig, user_cmd::Cmd)
            # Because Julia 1.8+ closes IOBuffers like `stdout` and `stderr`, we create temporary
            # IOBuffers that get copied over to the persistent `stdin`/`stdout` after the run is complete.
            temp_stdout = isa(config.stdout, IOBuffer) ? IOBuffer() : config.stdout
            temp_stderr = isa(config.stderr, IOBuffer) ? IOBuffer() : config.stderr
            cmd = pipeline(build_executor_command(exe, config, user_cmd); config.stdin, stdout=temp_stdout, stderr=temp_stderr)
            if config.verbose
                @info("Running sandboxed command", user_cmd.exec)
            end
            warn_priviledged(exe)
            ret = $f(cmd)

            # If we were using temporary IOBuffers, write the result out to `config.std{out,err}`
            if isa(temp_stdout, IOBuffer)
                write(config.stdout, take!(temp_stdout))
            end
            if isa(temp_stderr, IOBuffer)
                write(config.stderr, take!(temp_stderr))
            end
            return ret
        end
    end
end

"""
    with_executor(f::Function, ::Type{<:SandboxExecutor} = preferred_executor(); kwargs...)
"""
function with_executor(f::F, ::Type{T} = preferred_executor();
                       kwargs...) where {F <: Function, T <: SandboxExecutor}
    exe = T(; kwargs...)
    try
        return f(exe)
    finally
        cleanup(exe)
    end
end

function probe_executor(executor::SandboxExecutor; verbose::Bool = false)
    mktempdir() do tmpdir
        rw_dir = joinpath(tmpdir, "rw")
        mkpath(rw_dir)
        mounts = Dict(
            "/" => MountInfo(debian_rootfs(), MountType.Overlayed),
            "/read_write" => MountInfo(rw_dir, MountType.ReadWrite),
        )

        # Do a quick test that this executor works
        inner_cmd = """
        echo 'hello julia'
        echo 'read-write mapping successful' >> /read_write/foo
        """

        cmd_stdout = IOBuffer()
        cmd_stderr = IOBuffer()
        config = SandboxConfig(
            mounts,
            Dict("PATH" => "/bin:/usr/bin");
            stdout=cmd_stdout,
            stderr=cmd_stderr,
            verbose,
        )
        user_cmd = `/bin/bash -c "$(inner_cmd)"`

        # Command should execute successfully
        user_cmd = ignorestatus(user_cmd)
        proc = try
            run(executor, config, user_cmd)
        catch e
            if isa(e, ArgumentError)
                if verbose
                    @warn("Unable to build executor command: ", e.msg)
                end
                return false
            end
            rethrow(e)
        end
        if !success(proc)
            if verbose
                cmd_stdout = String(take!(cmd_stdout))
                cmd_stderr = String(take!(cmd_stderr))
                @warn("Unable to run `sandbox` itself", cmd_stdout)
                println(cmd_stderr)
            end
            return false
        end

        # stdout should contain "hello julia" as its own line
        cmd_stdout = String(take!(cmd_stdout))
        stdout_lines = split(cmd_stdout, "\n")
        if !("hello julia" in stdout_lines)
            cmd_stderr = String(take!(cmd_stderr))
            stderr_lines = split(cmd_stderr, "\n")
            if verbose
                @warn(" -> Basic stdout sentinel missing!", stdout_lines, stderr_lines)
            end
            return false
        end

        foo_file = joinpath(joinpath(tmpdir, "rw", "foo"))
        if !isfile(foo_file)
            if verbose
                @warn(" -> Read-write mapping sentinel file missing!")
            end
            return false
        end

        foo_file_contents = String(read(foo_file))
        if foo_file_contents != "read-write mapping successful\n"
            if verbose
                @warn(" -> Read-write mapping data corrupted", foo_file_contents)
            end
            return false
        end
        return true
    end
end

# Convenience function for other users who want to do some testing
function debian_rootfs(;platform=HostPlatform())
    return @artifact_str("debian-minimal-rootfs-$(arch(platform))")
end
# The multiarch rootfs is truly multiarch
multiarch_rootfs(;platform=nothing) = artifact"multiarch-rootfs"

# Precompilation section
let
    f(exe) = run(exe, SandboxConfig(Dict("/" => "/")), `/bin/bash -c exit`)
    precompile(select_executor, (Bool,))
    precompile(with_executor, (typeof(f),))
end

end # module
