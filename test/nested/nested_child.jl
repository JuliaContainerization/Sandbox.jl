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

# This rootfs was downloaded within the sandbox in the `Pkg.instantiate()` above, and the
# outer sandbox's root can't hold the changes of another overlay, so they go to a
# directory from outside.
config = SandboxConfig(;
    rootfs=Sandbox.debian_rootfs(),
    mounts=["/tmp/readwrite" => Bind("/tmp/readwrite"; writable=true)],
    persist=mktempdir("/sandbox_persistence"; cleanup=false),
    verbose=true,
)

# Prove that we can write into the `readwrite` location
write("/tmp/readwrite/single_nested.txt", "aperture\n")

inner_stderr = IOBuffer()
@test success(pipeline(Sandbox.command(config, `/bin/sh -c "echo science > /tmp/readwrite/double_nested.txt"`);
                       stderr=inner_stderr))
@test read("/tmp/readwrite/double_nested.txt", String) == "science\n"

# The launcher's mode is what it is told, also when started as root in the sandbox.
inner_log = String(take!(inner_stderr))
print(stderr, inner_log)
@test occursin("running in unprivileged container mode", inner_log)
