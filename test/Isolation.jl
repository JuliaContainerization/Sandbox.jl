using Test, Sandbox

# These tests cover behaviour of the sandbox binary that the released UserNSSandbox_jll
# does not have yet, so they only run against a binary built from this checkout.  Where
# an executor can run, a sandbox that fails to start must fail the tests rather than
# drop the executor from them, so only the host's support is checked up front.
userns_executors = Type{<:UserNamespacesExecutor}[]
if should_build_local_sandbox && UserNSSandbox_jll.is_available() &&
   Sandbox.check_kernel_version() && Sandbox.check_overlayfs_loaded()
    if Sandbox.getuid() != 0
        push!(userns_executors, UnprivilegedUserNamespacesExecutor)
    end
    if Sys.which("sudo") !== nothing && success(`sudo -k -n true`)
        push!(userns_executors, PrivilegedUserNamespacesExecutor)
    end
    for executor in userns_executors
        @test executor_available(executor)
    end
end

# Run a shell script in the sandbox, returning `(success, stdout, stderr)`.
function sandbox_sh(executor, script; mounts=Dict{String,MountInfo}(), kwargs...)
    stdout, stderr = IOBuffer(), IOBuffer()
    config = SandboxConfig(
        Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed), mounts...),
        Dict("PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        stdout, stderr, persist=false, kwargs...,
    )
    ok = with_executor(executor) do exe
        success(exe, config, ignorestatus(`/bin/sh -c $(script)`))
    end
    return ok, String(take!(stdout)), String(take!(stderr))
end

for executor in userns_executors
    @testset "$(executor) isolation" begin
        @testset "file maps create parent directories" begin
            mktempdir() do dir
                write(joinpath(dir, "note.txt"), "great success")
                ok, out, err = sandbox_sh(executor, "cat /does/not/exist/note.txt";
                    mounts=Dict("/does/not/exist/note.txt" => MountInfo(joinpath(dir, "note.txt"), MountType.ReadOnly)))
                @test ok
                @test out == "great success"
                @test isempty(err)
            end
        end
    end
end
