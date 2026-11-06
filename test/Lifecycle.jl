using Test, Sandbox

# How the sandbox binary starts, reports on and stops the sandboxed command, against the
# executors that Isolation.jl found (`userns_executors`).

function sandbox_config(; mounts=Dict{String,MountInfo}(), kwargs...)
    return SandboxConfig(
        Dict("/" => MountInfo(Sandbox.debian_rootfs(), MountType.Overlayed), mounts...),
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

# Counts the SIGINTs it gets until it reads a line.  The handler is slow so that a second
# SIGINT that arrives while it runs stays pending instead of merging with the first.
const count_sigint_c = raw"""
    #include <signal.h>
    #include <stdio.h>
    #include <time.h>
    static volatile sig_atomic_t count = 0;
    static void handler(int sig) {
      count++;
      struct timespec t = {0, 100000000};
      nanosleep(&t, NULL);
    }
    int main() {
      char line[16];
      signal(SIGINT, handler);
      printf("ready\n");
      fflush(stdout);
      fgets(line, sizeof(line), stdin);
      printf("count=%d\n", (int)count);
      return 0;
    }
    """

# Run `cmd` as the foreground job of a job-control shell on a terminal of its own, and
# type each of `keys` once it has printed "ready".  Returns everything that appeared on
# the terminal.
function run_on_terminal(cmd, keys)
    shell = raw"""set -m; "$@"; echo "status=$?"; fg; echo done"""
    inner = Base.shell_escape(`$(Sys.which("bash")) -c $(shell) -- $(cmd.exec)`)
    terminal = `$(Sys.which("timeout")) 30 $(Sys.which("script")) -qfec $(inner) /dev/null`
    proc = open(setenv(terminal, cmd.env), "r+")
    out = readuntil(proc, "ready")
    for key in keys
        sleep(0.5)
        write(proc, key)
    end
    out *= read(proc, String)
    close(proc)
    return replace(out, '\r' => "")
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

        @testset "exit codes" begin
            @test sandbox_run(executor, `/bin/sh -c 'exit 42'`).exitcode == 42
            @test sandbox_run(executor, `/does/not/exist`; stderr=devnull).exitcode == 127
            @test sandbox_run(executor, `/etc/passwd`; stderr=devnull).exitcode == 126
            # The sandbox couldn't be set up
            mounts = Dict("/mnt" => MountInfo("/does/not/exist", MountType.ReadOnly))
            @test sandbox_run(executor, `/bin/true`; mounts, stderr=devnull).exitcode == 125
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

        @testset "dying of a signal" begin
            # The launcher dies of the command's signal, but leaves the core to the command
            mktempdir() do dir
                with_executor(executor) do exe
                    cmd = Sandbox.build_executor_command(exe, sandbox_config(), `/bin/sh -c 'kill -QUIT $$'`)
                    script = raw"""ulimit -c unlimited 2>/dev/null; "$@"; echo $?"""
                    stdout, stderr = IOBuffer(), IOBuffer()
                    wrapper = setenv(`$(Sys.which("bash")) -c $(script) -- $(cmd.exec)`, cmd.env; dir)
                    run(pipeline(wrapper; stdout, stderr))
                    @test String(take!(stdout)) == "$(128 + Base.SIGQUIT)\n"
                    # Under sudo, the process that dies is sudo, which may dump a core
                    # of its own when it re-raises the signal (sudo-rs does).
                    if executor == UnprivilegedUserNamespacesExecutor
                        @test !occursin("core dumped", String(take!(stderr)))
                        @test isempty(readdir(dir))
                    end
                end
            end
            @test sandbox_run(executor, `/bin/sh -c 'kill -QUIT $$'`).termsignal == Base.SIGQUIT
        end

        # Under sudo, the launcher would be on a terminal of sudo's
        if executor == UnprivilegedUserNamespacesExecutor &&
           all(exe -> Sys.which(exe) !== nothing, ("bash", "script", "timeout", "cc"))
            @testset "terminal signals" begin
                mktempdir() do dir
                    write(joinpath(dir, "count.c"), count_sigint_c)
                    run(`cc -static -O2 -o $(dir)/count $(dir)/count.c`)
                    mounts = Dict("/count" => MountInfo(joinpath(dir, "count"), MountType.ReadOnly))
                    with_executor(executor) do exe
                        cmd = Sandbox.build_executor_command(exe, sandbox_config(; mounts), `/count`)

                        # Each Ctrl-C reaches the command once
                        out = run_on_terminal(cmd, ["\x03", "\x03", "\x03", "\n"])
                        @test occursin("count=3\n", out)
                        @test occursin("status=0\n", out)

                        # Ctrl-Z stops the job (128 + SIGTSTP), which then continues in
                        # the foreground
                        out = run_on_terminal(cmd, ["\x1a", "\n"])
                        @test occursin("status=$(128 + 20)\n", out)
                        @test occursin("count=0\n", out)
                        @test occursin("done\n", out)
                    end
                end
            end
        end
    end
end
