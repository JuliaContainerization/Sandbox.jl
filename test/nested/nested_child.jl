# Recreate the parent's test environment from `/project`, which is read-only. Its
# manifest (if any) refers to host paths, or lives in the workspace root and wasn't
# copied, so re-resolve against the mounted checkout. Otherwise Pkg would quietly pick
# the registered Sandbox.jl. `LocalPreferences.toml` is kept so a locally built
# `sandbox` binary is used here too.
original_app_directory = "/project"
new_app_directory = mktempdir(; cleanup = true)
cp(original_app_directory, new_app_directory; force=true)
rm.(joinpath.(Ref(new_app_directory), Base.manifest_names); force = true)

using Pkg
Pkg.activate(new_app_directory)
Pkg.develop(path=dirname(dirname(@__DIR__)))
Pkg.instantiate()
Pkg.precompile()

# Load Sandbox, then try to launch a nested sandbox
using Sandbox, Test
@test pkgdir(Sandbox) == dirname(dirname(@__DIR__))

rootfs_dir = Sandbox.debian_rootfs()

inner_stderr = IOBuffer()
config = SandboxConfig(
    # This rootfs was downloaded within the sandbox in the `Pkg.instantiate()` above
    Dict("/" => rootfs_dir),
    # Propagate our readwrite mounting into the nested sandbox
    Dict{String,String}("/tmp/readwrite" => "/tmp/readwrite"),
    persist=true,
    verbose=true,
    stderr=inner_stderr,
)

# Prove that we can write into the `readwrite` location
open("/tmp/readwrite/single_nested.txt", "w") do io
    println(io, "aperture")
end

# For debugging, dump the list of mounts:
#run(`mount`)

# This should always default to the unprivileged executor, since if we're nested, `FORCE_SANDBOX_MODE` should be set
with_executor() do exe
    @test success(exe, config, `/bin/sh -c "echo science > /tmp/readwrite/double_nested.txt"`)
end
@test String(read("/tmp/readwrite/double_nested.txt")) == "science\n"

# The sandbox binary picks its mode from its own euid, as `FORCE_SANDBOX_MODE` is not in
# the nested sandbox's environment: started as root, it runs privileged, mounting the
# rootfs before creating its user namespace and a procfs for its PID namespace after.
inner_log = String(take!(inner_stderr))
print(stderr, inner_log)
mode = Sandbox.getuid() == 0 ? "privileged" : "unprivileged"
@test occursin("running in $(mode) container mode", inner_log)
