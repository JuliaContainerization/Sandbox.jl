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

host_cgroup2 = any(eachline("/proc/self/mounts")) do line
    fields = split(line)
    return fields[2] == "/sys/fs/cgroup" && fields[3] == "cgroup2"
end
host_cgroup_dir() = "/sys/fs/cgroup" * replace(readline("/proc/self/cgroup"), r"^0::" => "")

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

        @testset "private IPC namespace and /dev/shm" begin
            # A marker in the host's /dev/shm must not be visible inside
            marker = "sandbox-isolation-test-$(getpid())"
            host_shm = isdir("/dev/shm") ? joinpath("/dev/shm", marker) : nothing
            host_shm === nothing || touch(host_shm)
            try
                ok, out, err = sandbox_sh(executor, """
                    readlink /proc/self/ns/ipc
                    stat -f -c %T /dev/shm
                    stat -c %a /dev/shm
                    ls -A /dev/shm
                    """)
                @test ok
                lines = split(out, '\n')
                @test lines[1] != readlink("/proc/self/ns/ipc")
                @test lines[2] == "tmpfs"
                @test lines[3] == "1777"
                @test lines[4] == ""
            finally
                host_shm === nothing || rm(host_shm; force=true)
            end

            # The size of /dev/shm can be limited
            script = "dd if=/dev/zero of=/dev/shm/blob bs=1M count=16"
            @test sandbox_sh(executor, script; shm_size="32M")[1]
            ok, out, err = sandbox_sh(executor, script; shm_size="8M")
            @test !ok
            @test occursin("No space left on device", err)
        end

        @testset "cgroup namespace and read-only cgroup2 view" begin
            ok, out, err = sandbox_sh(executor, """
                readlink /proc/self/ns/cgroup
                grep '^0::' /proc/self/cgroup || echo none
                stat -f -c %T /sys/fs/cgroup
                grep ' /sys/fs/cgroup ' /proc/self/mounts | tail -n 1 | cut -d' ' -f3,4
                ls -A /sys/fs/cgroup | tr '\\n' ' '
                """)
            @test ok
            lines = split(out, '\n')
            @test lines[1] != readlink("/proc/self/ns/cgroup")
            if host_cgroup2
                @test lines[2] == "0::/"
                @test lines[3] == "cgroup2fs"
                fstype, options = split(lines[4])
                @test fstype == "cgroup2"
                @test "ro" in split(options, ',')
                # The view is rooted at the cgroup the sandbox was started in, which for
                # the unprivileged executor is ours.
                if executor == UnprivilegedUserNamespacesExecutor
                    @test Set(split(lines[5])) == Set(readdir(host_cgroup_dir()))
                end

                # Neither limits nor membership can be changed through it
                @test !sandbox_sh(executor, "echo max > /sys/fs/cgroup/memory.max")[1]
                @test !sandbox_sh(executor, "echo \$\$ > /sys/fs/cgroup/cgroup.procs")[1]
                @test !sandbox_sh(executor, "mkdir /sys/fs/cgroup/child")[1]
            else
                @test lines[3] == "tmpfs"
                @test isempty(strip(lines[5]))
            end
        end
    end
end
