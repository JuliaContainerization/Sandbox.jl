using Documenter, Sandbox

makedocs(;
    modules = [Sandbox],
    sitename = "Sandbox.jl",
    checkdocs = :exports,
)

deploydocs(;
    repo = "github.com/JuliaContainerization/Sandbox.jl.git",
    push_preview = true,
    devbranch = "main",
)
