using Documenter, Sandbox

makedocs(
    modules = [Sandbox],
    sitename = "Sandbox.jl",
)

deploydocs(
    repo = "github.com/JuliaContainerization/Sandbox.jl.git",
    push_preview = true,
    devbranch = "main",
)
