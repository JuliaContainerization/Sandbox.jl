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

include("SandboxConfig.jl")
include("UserNamespaces.jl")
include("Docker.jl")
include("Sandbox.jl")
include("Nesting.jl")
include("Multiarch.jl")
