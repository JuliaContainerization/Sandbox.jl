# Decides whether CI should test the launcher from UserNSSandbox_jll, or build it from
# `deps/`: a JLL is only built after a change to the launcher is merged, so until then, the
# change can only be tested with a local build.  Like LLVM.jl's `deps/build_ci.jl`, this
# compares the date of the last commit to the launcher's sources with that of the JLL's tag.

const LAUNCHER_SOURCES = ["*.c", "*.h", "Makefile"]

"""
    launcher_changed_since(jll_version) -> Bool

Whether the launcher's sources in this checkout changed after UserNSSandbox_jll
`jll_version` was built, and true if that can't be determined because this is not a git
checkout.
"""
function launcher_changed_since(jll_version::VersionNumber)
    git = Sys.which("git")
    if git === nothing || !success(`$(git) -C $(@__DIR__) rev-parse --git-dir`)
        @warn("Sandbox.jl is not a git checkout, so the launcher is built from source")
        return true
    end

    sources_date = parse(Int, readchomp(`$(git) -C $(@__DIR__) log -1 --format=%ct -- $(LAUNCHER_SOURCES)`))
    @info("Last change to the launcher: $(Libc.strftime("%F %T", sources_date))")

    tag = "UserNSSandbox-v$(jll_version)"
    jll_date = mktempdir() do dir
        run(`$(git) clone -q --bare --filter=blob:none https://github.com/JuliaBinaryWrappers/UserNSSandbox_jll.jl $(dir)`)
        date = readchomp(`$(git) -C $(dir) for-each-ref "--format=%(creatordate:unix)" refs/tags/$(tag)`)
        isempty(date) && error("UserNSSandbox_jll has no tag $(tag)")
        parse(Int, date)
    end
    @info("UserNSSandbox_jll $(jll_version) was tagged on $(Libc.strftime("%F %T", jll_date))")

    return sources_date > jll_date
end
