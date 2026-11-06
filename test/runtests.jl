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

# Remove `SANDBOX_FORCE_MODE`, as we want to test all modes
if haskey(ENV, "FORCE_SANDBOX_MODE")
    @warn("Un-setting `FORCE_SANDBOX_MODE` for tests...")
    delete!(ENV, "FORCE_SANDBOX_MODE")
end

using Test, Sandbox, Scratch

# If we're on a UserNSSandbox_jll-compatible system, ensure that the sandbox is coming from where we expect.
UserNSSandbox_jll = Sandbox.UserNSSandbox_jll
if UserNSSandbox_jll.is_available()
    Artifacts = Sandbox.UserNSSandbox_jll.Artifacts
    sandbox_path = Sandbox.UserNSSandbox_jll.sandbox_path
    @info("On a UserNSSandbox_jll-capable platform", sandbox_path)
    if should_build_local_sandbox
        @test startswith(UserNSSandbox_jll.sandbox_path, Scratch.scratch_dir())
    else
        @test any(startswith(UserNSSandbox_jll.sandbox_path, d) for d in Artifacts.artifacts_dirs())
    end
end

# Ensure we're not running as root; that breaks unprivileged user namespaces testing
if Sandbox.getuid() == 0
    @warn("You are running Sandbox.jl tests as root!  This cannot test unprivileged namespaces!")
end

# The executor test sets skip executors that aren't available. Where all of them should
# work (e.g. our CI), fail instead, so that a broken setup can't fall back unnoticed.
if parse(Bool, get(ENV, "SANDBOX_TEST_REQUIRE_EXECUTORS", "false"))
    @testset "required executors" begin
        @testset "$executor" for executor in Sandbox.all_executors
            available = executor_available(executor)
            if !available
                # rerun verbosely to show why
                executor_available(executor; verbose=true)
            end
            @test available
        end
    end
end

include("aqua.jl")
# captured variables that get boxed (`Core.Box`) lose their type
if isdefined(Test, :detect_closure_boxes)
    @testset "closure boxes" begin
        @test Test.detect_closure_boxes(Sandbox) == []
    end
end
include("SandboxConfig.jl")
include("UserNamespaces.jl")
include("Docker.jl")
include("Sandbox.jl")

if Sys.islinux()
    include("Nesting.jl")
    include("Multiarch.jl")
end
