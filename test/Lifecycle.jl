using Test, Sandbox

using Sandbox: command

# How the launcher starts, reports on and stops the sandboxed command.

sandbox_config(mode; mounts=Pair{String,Sandbox.Mount}[]) =
    SandboxConfig(; rootfs=Sandbox.debian_rootfs(), mode, mounts, env=Dict("PATH" => default_path))

# Run `cmd` in the sandbox, returning the finished process.
function lifecycle_run(mode, cmd; stdout=devnull, stderr=devnull, kwargs...)
    return run(pipeline(command(sandbox_config(mode; kwargs...), ignorestatus(cmd)); stdout, stderr))
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

for mode in modes
    @testset "lifecycle ($(mode))" begin
        @testset "no launcher fds in the sandbox" begin
            # Fds our own process inherited without close-on-exec (as on CI runners)
            # reach any command we run; the sandbox may only add none of its own.
            script = "for fd in \$(seq 3 63); do [ -e /proc/\$\$/fd/\$fd ] && echo \$fd; done; true"
            inherited = readlines(`/bin/sh -c $(script)`)
            stdout = IOBuffer()
            p = lifecycle_run(mode, `/bin/sh -c $(script)`; stdout)
            @test success(p)
            @test setdiff(split(String(take!(stdout))), inherited) == []

            # Writing a fake status to the launcher's pipe must not hide the real one,
            # whether through an inherited fd or the fds of the PID namespace's init.
            for script in ["for fd in 3 4 5 6 7 8 9; do printf '\\0\\0\\0\\0' >&\$fd; done; exit 3",
                           "for fd in /proc/1/fd/*; do case \${fd##*/} in [012]) ;; *) printf '\\0\\0\\0\\0' > \$fd;; esac; done; exit 3"]
                p = lifecycle_run(mode, `/bin/sh -c $(script)`)
                @test p.exitcode == 3
            end
        end

        @testset "exit codes" begin
            @test lifecycle_run(mode, `/bin/sh -c 'exit 42'`).exitcode == 42
            @test lifecycle_run(mode, `/does/not/exist`).exitcode == 127
            @test lifecycle_run(mode, `/etc/passwd`).exitcode == 126
            # The sandbox couldn't be set up
            mounts = ["/mnt" => Bind("/does/not/exist")]
            @test lifecycle_run(mode, `/bin/true`; mounts).exitcode == 125
        end

        @testset "killing the launcher kills the sandbox" begin
            # `@testset` seeds the RNG, so it would give each mode the same token
            token = string(1_000_000 + time_ns() % 1_000_000)
            sudo = mode == :sudo ? ["sudo"] : String[]
            sandboxed() = find_pids(pid -> token in cmdline(pid))
            begin
                cmd = command(sandbox_config(mode), `/bin/sleep $(token)`)
                p = run(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull); wait=false)
                try
                    @test wait_until(() -> !isempty(find_pids(pid -> cmdline(pid) == ["/bin/sleep", token])))
                    # Not `p`, which is sudo in privileged mode: it can't pass on a SIGKILL.
                    # The JLL installs the launcher as `sandbox`, a local build as `userns_sandbox`
                    name = first(basename(Sandbox.UserNSSandbox_jll.sandbox_path), 15)
                    launcher = only(find_pids(pid -> comm(pid) == name &&
                                                     comm(ppid(pid)) != name &&
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
                begin
                    cmd = command(sandbox_config(mode), `/bin/sh -c 'kill -QUIT $$'`)
                    script = raw"""ulimit -c unlimited 2>/dev/null; "$@"; echo $?"""
                    stdout, stderr = IOBuffer(), IOBuffer()
                    wrapper = setenv(`$(Sys.which("bash")) -c $(script) -- $(cmd.exec)`, cmd.env; dir)
                    run(pipeline(wrapper; stdout, stderr))
                    @test String(take!(stdout)) == "$(128 + Base.SIGQUIT)\n"
                    # Under sudo, the process that dies is sudo, which may dump a core
                    # of its own when it re-raises the signal (sudo-rs does).
                    if mode == :userns
                        @test !occursin("core dumped", String(take!(stderr)))
                        @test isempty(readdir(dir))
                    end
                end
            end
            @test lifecycle_run(mode, `/bin/sh -c 'kill -QUIT $$'`).termsignal == Base.SIGQUIT
        end

        # Under sudo, the launcher would be on a terminal of sudo's
        if mode == :userns &&
           all(exe -> Sys.which(exe) !== nothing, ("bash", "script", "timeout", "cc"))
            @testset "terminal signals" begin
                mktempdir() do dir
                    write(joinpath(dir, "count.c"), count_sigint_c)
                    run(`cc -static -O2 -o $(dir)/count $(dir)/count.c`)
                    mounts = ["/count" => Bind(joinpath(dir, "count"))]
                    begin
                        cmd = command(sandbox_config(mode; mounts), `/count`)

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
