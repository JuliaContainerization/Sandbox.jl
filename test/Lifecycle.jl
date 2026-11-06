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

function cmdline(pid)
    try
        return split(read("/proc/$(pid)/cmdline", String), '\0'; keepempty=false)
    catch
        return String[]
    end
end
comm(pid) = try readchomp("/proc/$(pid)/comm") catch; "" end
function ppid(pid)
    stat = try read("/proc/$(pid)/stat", String) catch; return 0 end
    return parse(Int, split(stat[findlast(')', stat)+1:end])[2])
end
function find_pids(f)
    pids = Int[]
    for entry in readdir("/proc")
        pid = tryparse(Int, entry)
        pid !== nothing && f(pid) && push!(pids, pid)
    end
    return pids
end
function wait_until(f; timeout=10)
    t0 = time()
    while !f()
        time() - t0 > timeout && return false
        sleep(0.05)
    end
    return true
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

        @testset "killing the launcher kills the sandbox" begin
            # `@testset` seeds the RNG, so it would give each executor the same token
            token = string(1_000_000 + time_ns() % 1_000_000)
            sudo = executor == PrivilegedUserNamespacesExecutor ? Sandbox.sudo_cmd() : String[]
            sandboxed() = find_pids(pid -> token in cmdline(pid))
            with_executor(executor) do exe
                cmd = Sandbox.build_executor_command(exe, sandbox_config(), `/bin/sleep $(token)`)
                p = run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull); wait=false)
                try
                    @test wait_until(() -> !isempty(find_pids(pid -> cmdline(pid) == ["/bin/sleep", token])))
                    # Not `p`, which is sudo in privileged mode: it can't pass on a SIGKILL.
                    launcher = only(find_pids(pid -> comm(pid) == "userns_sandbox" &&
                                                     comm(ppid(pid)) != "userns_sandbox" &&
                                                     token in cmdline(pid)))
                    run(`$(sudo) kill -KILL $(launcher)`)
                    wait(p)
                    @test wait_until(() -> isempty(sandboxed()))
                finally
                    process_running(p) && kill(p, Base.SIGKILL)
                    pids = sandboxed()
                    isempty(pids) || run(ignorestatus(`$(sudo) kill -KILL $(pids)`))
                end
            end
        end
    end
end
