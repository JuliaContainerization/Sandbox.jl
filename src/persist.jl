"""
    Sandbox.scratch_persist_dir() -> String

A new directory in Sandbox.jl's scratch space, to use as a `persist` directory.  It is the
caller's: nothing removes it automatically.  The scratch space is in the Julia depot,
which can be on a filesystem that can't hold the changes of an overlay (see
[`Sandbox.probe_persist`](@ref)).
"""
scratch_persist_dir() = mktempdir(@get_scratch!("persist"); cleanup=false)

"""
    Sandbox.probe_persist(dir; rootfs=Sandbox.debian_rootfs(), mode=:userns, verbose=false) -> Bool

Whether `persist` directories in `dir` work with this kernel, filesystem and `mode`:
overlayfs needs extended attributes and whiteouts on the filesystem of `dir`, which some
(such as ZFS, or another overlayfs) lack, and some of which a user namespace may not
create.  Runs two sandboxes of `rootfs` with a new directory in `dir`, which it then
removes.
"""
function probe_persist(dir::AbstractString; rootfs::AbstractString=debian_rootfs(),
                       mode::Symbol=:userns, verbose::Bool=false)
    mktempdir() do tmp
        lower = joinpath(tmp, "lower")
        mkpath(joinpath(lower, "d"))
        write(joinpath(lower, "d", "f"), "f")
        write(joinpath(lower, "g"), "g")
        state = mktempdir(dir; cleanup=false)
        err = IOBuffer()
        config(mount) = SandboxConfig(; rootfs, mounts=["/p" => mount], persist=state, mode,
                                      env=Dict("PATH" => "/usr/bin:/bin"), verbose)
        # A directory deleted and created again must hide what the lower layer has in it,
        # also when mounted again later, and a modified file must keep its changes.
        ok = try
            success(pipeline(command(config(Overlay(lower)),
                                     `/bin/sh -c 'rm -r /p/d && mkdir /p/d && echo x > /p/g'`);
                             stdout=devnull, stderr=err)) &&
            success(pipeline(command(config(Overlay(lower; readonly=true)),
                                     `/bin/sh -c 'test -d /p/d && test ! -e /p/d/f && test "$(cat /p/g)" = x'`);
                             stdout=devnull, stderr=err))
        finally
            remove_persist(state; mode)
        end
        if !ok
            verbose && @warn("Overlays don't work with a persist directory in $(dir)", stderr=String(take!(err)))
            mode == :userns && check_restricted_unprivileged_userns()
        end
        return ok
    end
end

"""
    Sandbox.remove_persist(dir; mode=:userns)

Removes the persist directory `dir`, which no sandbox may be using.  overlayfs leaves
directories in it that can't be read (mode 000), so this gives everything in it to the
user to remove, including the files that hard links in it share with others (which only
the host can put there).  In `:sudo` mode, its directories belong to root, so this uses
`sudo` then.
"""
function remove_persist(dir::AbstractString; mode::Symbol=:userns)
    mode in (:userns, :sudo) || throw(ArgumentError("mode must be :userns or :sudo, not $(repr(mode))"))
    # Without a trailing `/` or `/.`, which would look through a symlink
    path = isempty(dir) ? dir : rstrip(normpath(dir), '/')
    isempty(path) && throw(ArgumentError("persist directory \"$(dir)\" is empty or the root"))
    islink(path) && throw(ArgumentError("persist directory \"$(dir)\" is a symlink"))
    dir = path
    if mode == :sudo
        run(`sudo rm -rf -- $(dir)`)
    else
        run(`chmod -R u+rwX -- $(dir)`)
        rm(dir; recursive=true)
    end
end
