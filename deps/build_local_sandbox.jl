using Pkg, Scratch, Preferences

# Use `cc` to build `sandbox.c` into a scratch space owned by `Sandbox`
sandbox_uuid = Base.UUID("9307e30f-c43e-9ca7-d17c-c2dc59df670d")
sdir = get_scratch!(sandbox_uuid, "local_sandbox")
run(`make -C $(@__DIR__) -j$(Sys.CPU_THREADS) bindir=$(sdir)`)

# Tell UserNSSandbox_jll to load our `sandbox` instead of the default artifact one
jll_uuid = Base.UUID("b88861f7-1d72-59dd-91e7-a8cc876a4984")
set_preferences!(
    jll_uuid,
    "sandbox_path" => joinpath(sdir, "userns_sandbox");
    force=true,
)
