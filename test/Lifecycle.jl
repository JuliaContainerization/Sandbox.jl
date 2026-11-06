using Test, Sandbox

# How the sandbox binary starts, reports on and stops the sandboxed command.  Like the
# isolation tests, these cover behaviour the released UserNSSandbox_jll does not have yet,
# and run against the executors that Isolation.jl found (`userns_executors`).

function sandbox_config(; kwargs...)
    return SandboxConfig(
        Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed)),
        Dict("PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
        persist=false, kwargs...,
    )
end

# Run `cmd` in the sandbox, returning the finished process.
function sandbox_run(executor, cmd; kwargs...)
    with_executor(executor) do exe
        run(exe, sandbox_config(; kwargs...), ignorestatus(cmd))
    end
end

for executor in userns_executors
    @testset "$(executor) lifecycle" begin
        @testset "no launcher fds in the sandbox" begin
            # Fds our own process inherited without close-on-exec (as on CI runners)
            # reach any command we run; the sandbox may only add none of its own.
            script = "for fd in \$(seq 3 63); do [ -e /proc/\$\$/fd/\$fd ] && echo \$fd; done; true"
            inherited = readlines(`/bin/sh -c $(script)`)
            stdout = IOBuffer()
            p = sandbox_run(executor, `/bin/sh -c $(script)`; stdout, stderr=devnull)
            @test success(p)
            @test setdiff(split(String(take!(stdout))), inherited) == []

            # Writing a fake status to the launcher's pipe must not hide the real one,
            # whether through an inherited fd or the fds of the PID namespace's init.
            for script in ["for fd in 3 4 5 6 7 8 9; do printf '\\0\\0\\0\\0' >&\$fd; done; exit 3",
                           "for fd in /proc/1/fd/*; do case \${fd##*/} in [012]) ;; *) printf '\\0\\0\\0\\0' > \$fd;; esac; done; exit 3"]
                p = sandbox_run(executor, `/bin/sh -c $(script)`; stderr=devnull)
                @test p.exitcode == 3
            end
        end
    end
end
