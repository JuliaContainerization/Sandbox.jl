# If our test harness requests a local sandbox, make it so!
REPO_ROOT = dirname(@__DIR__)
should_build_local_sandbox = parse(Bool, get(ENV, "SANDBOX_BUILD_LOCAL_SANDBOX", "false"))
if should_build_local_sandbox
    @info("Building local sandbox")
    run(`$(Base.julia_cmd()) --project=$(Base.active_project()) $(REPO_ROOT)/deps/build_local_sandbox.jl`)
else
    # Clear out any `LocalPreferences.toml` files that we may or may not have.
    for prefix in (REPO_ROOT, joinpath(REPO_ROOT, "test"))
        local_prefs = joinpath(prefix, "LocalPreferences.toml")
        if isfile(local_prefs)
            @warn("Wiping $(local_prefs) as SANDBOX_BUILD_LOCAL_SANDBOX not set...")
            rm(local_prefs)
        end
    end
end

using Test, Sandbox, Scratch

# Ensure that the sandbox is coming from where we expect.
UserNSSandbox_jll = Sandbox.UserNSSandbox_jll
@info("Testing with launcher", UserNSSandbox_jll.sandbox_path)
if should_build_local_sandbox
    @test startswith(UserNSSandbox_jll.sandbox_path, Scratch.scratch_dir())
else
    @test any(startswith(UserNSSandbox_jll.sandbox_path, d) for d in Sandbox.UserNSSandbox_jll.Artifacts.artifacts_dirs())
end

# The modes the host supports: unprivileged unless we are root (which hides what an
# unprivileged sandbox can't do), and through sudo if it doesn't ask for a password.
if Sandbox.getuid() == 0
    @warn("You are running Sandbox.jl tests as root!  This cannot test unprivileged namespaces!")
end
candidate_modes = Symbol[]
Sandbox.getuid() != 0 && push!(candidate_modes, :userns)
Sys.which("sudo") !== nothing && success(`sudo -k -n true`) && push!(candidate_modes, :sudo)
rootfs_dir = Sandbox.debian_rootfs()
sandbox_works(mode) = success(pipeline(Sandbox.command(SandboxConfig(; rootfs=rootfs_dir, mode), `/bin/true`);
                                       stdout=devnull, stderr=devnull))
# Where all of them should work (e.g. our CI), fail instead of skipping one, so that a
# broken setup can't go unnoticed.
if parse(Bool, get(ENV, "SANDBOX_TEST_REQUIRE_EXECUTORS", "false"))
    @testset "required modes" begin
        @test !isempty(candidate_modes)
        @testset "$(mode)" for mode in candidate_modes
            @test sandbox_works(mode)
            @test Sandbox.probe_persist(@get_scratch!("persist"); rootfs=rootfs_dir, mode, verbose=true)
        end
    end
    modes = candidate_modes
else
    modes = filter(sandbox_works, candidate_modes)
end
isempty(modes) && @error("Skipping the tests that run sandboxes, as none can run here")

# A new persist directory, and its removal.
new_persist_dir() = Sandbox.scratch_persist_dir()
remove_persist(dir, mode) = Sandbox.remove_persist(dir; mode)

# Runs `cmd` in a sandbox of `config`, returning `(process, stdout, stderr)`.
function sandbox_run(config::SandboxConfig, cmd::Cmd)
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(Sandbox.command(config, ignorestatus(cmd)); stdout=out, stderr=err))
    return p, String(take!(out)), String(take!(err))
end

const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

include("aqua.jl")
# captured variables that get boxed (`Core.Box`) lose their type
if isdefined(Test, :detect_closure_boxes)
    @testset "closure boxes" begin
        @test Test.detect_closure_boxes(Sandbox) == []
    end
end
include("utils.jl")
include("SandboxConfig.jl")
include("Launcher.jl")
include("Sandbox.jl")
include("Isolation.jl")
include("Lifecycle.jl")
include("Nesting.jl")
include("Multiarch.jl")
