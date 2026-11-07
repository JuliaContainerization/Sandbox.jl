# Sandbox.jl release notes

## 3.0

Sandbox.jl 3 is for Linux hosts with user namespaces.  A `SandboxConfig` describes the
sandbox, and `Sandbox.command(config, cmd)` returns the `Cmd` that runs `cmd` in it: there
are no executors anymore, and running, redirecting and waiting are Base's.

The launcher's command line changed, so Sandbox.jl 3 requires the exact UserNSSandbox_jll
built from it.  Inner sandboxes of Sandbox.jl 2, with their own launcher, still work in a
Sandbox.jl 3 sandbox.

The Docker executor, which 2.x used where user namespaces were unavailable, is gone.  It
never worked on Windows, and on macOS it ignored overlays other than the rootfs.  On macOS
or Windows, run Sandbox.jl in a Linux VM or in WSL2.

### Upgrading

| Sandbox.jl 2 | Sandbox.jl 3 |
|---|---|
| `SandboxConfig(Dict("/" => rootfs, "/a" => ro), Dict("/b" => rw), env)` | `SandboxConfig(; rootfs, mounts=["/a" => Bind(ro), "/b" => Bind(rw; writable=true)], env)` |
| `MountInfo(p, MountType.ReadOnly)` / `ReadWrite` | `Bind(p)` / `Bind(p; writable=true)` (add `devices=true` for device nodes, such as `/dev/kvm`) |
| `MountInfo(p, MountType.Overlayed)` / `OverlayedReadOnly` | `Overlay(p)` / `Overlay(p; readonly=true)` |
| `pwd=` | `cwd=` |
| `persist=true` (a directory found and owned by the executor) | `persist=dir`, a directory you own: `Sandbox.scratch_persist_dir()`, checked with `Sandbox.probe_persist(dir)`, removed with `Sandbox.remove_persist(dir)` |
| `shm_size="1G"` | `mounts=["/dev/shm" => Tmpfs(size="1G", mode=0o1777)]` |
| `stdin=`, `stdout=`, `stderr=` in the config | `pipeline(Sandbox.command(config, cmd); stdin, stdout, stderr)` |
| `entrypoint="/init"` | `` Sandbox.command(config, `/init $(cmd)`) `` |
| `with_executor(exe -> run(exe, config, cmd))` | `run(config, cmd)` |
| `Sandbox.build_executor_command(exe, config, cmd)` | `Sandbox.command(config, cmd)` (and `Sandbox.register_multiarch(config)` once, if `multiarch` is used) |
| `PrivilegedUserNamespacesExecutor`, `FORCE_SANDBOX_MODE=privileged` | `mode=:sudo` |
| `DockerExecutor`, `pull_docker_image`, `export_docker_image` | gone; see `contrib/build_docker_image.jl` for exporting an image |
| `executor_available`, `preferred_executor`, `probe_executor` | gone; `mode=:userns` unless asked otherwise |

Behaviour that changed:

- Mounts are made in the order given; a `Dict` is mounted parents first.  The default
  mounts (`Sandbox.default_mounts()`: `/dev`, `/dev/shm`, `/sys`, `/sys/fs/cgroup`) come
  first, and a mount at or above one of them replaces it.
- `/dev` is a fresh tmpfs with the usual nodes, `fd` and `std*` symlinks, rather than the
  rootfs's `/dev` with some nodes bound into it.
- Binds are nosuid, and nodev unless `devices=true`.
- Without `persist`, changes go to a tmpfs (`tmpfs_size`, 1G by default).  Sandbox.jl 2
  persisted by default, in a directory that `with_executor` removed at the end.
- A persist directory can only be used by one sandbox at a time; another fails (exit
  code 125).
- The launcher no longer sets `FORCE_SANDBOX_MODE=unprivileged` in the sandbox, and doesn't
  read it.  A caller that nests Sandbox.jl 2 sets it in `env` itself.
- `Sandbox.command` doesn't register binfmt interpreters for `multiarch`; `run` and
  `Sandbox.register_multiarch` do.

### Examples

A build, as BinaryBuilder2 runs them: overlays that keep the build's changes in a persist
directory, then a read-only overlay of another directory at the same place, to extract the
results.

```julia
# Sandbox.jl 2
build = Dict(
    "/" => MountInfo(rootfs, MountType.Overlayed),
    "/workspace/destdir" => MountInfo(destdir, MountType.Overlayed),
    "/var/cache/ccache" => MountInfo(ccache, MountType.ReadWrite),
)
exe = Sandbox.preferred_executor()()
run(exe, SandboxConfig(build, env; persist=true, stdout, stderr), `/bin/bash -c $(script)`)
extract = merge(build, Dict("/workspace/destdir" => MountInfo(mktempdir(), MountType.OverlayedReadOnly),
                            "/workspace/extract" => MountInfo(outdir, MountType.ReadWrite)))
run(exe, SandboxConfig(extract, env; persist=true), `/bin/bash -c $(extract_script)`)
Sandbox.cleanup(exe)

# Sandbox.jl 3
persist = Sandbox.scratch_persist_dir()
build = ["/workspace/destdir" => Overlay(destdir), "/var/cache/ccache" => Bind(ccache; writable=true)]
run(pipeline(Sandbox.command(SandboxConfig(; rootfs, env, persist, mounts=build), `/bin/bash -c $(script)`);
             stdout, stderr))
extract = ["/workspace/destdir" => Overlay(mktempdir(); readonly=true),
           "/var/cache/ccache" => Bind(ccache; writable=true),
           "/workspace/extract" => Bind(outdir; writable=true)]
run(SandboxConfig(; rootfs, env, persist, mounts=extract), `/bin/bash -c $(extract_script)`)
Sandbox.remove_persist(persist)
```

The sandboxed Buildkite agent, which runs the command itself, in a cgroup of its own:

```julia
# Sandbox.jl 2
with_executor(UnprivilegedUserNamespacesExecutor) do exe
    exe.persistence_dir, exe.userxattr = agent_persist_info(brg, agent_name)
    wrap(Sandbox.build_executor_command(exe, config, cmd))
end

# Sandbox.jl 3: `persist` is in the config, and found once at startup with
# `Sandbox.probe_persist`; `Sandbox.register_multiarch(config)` when preparing the job.
wrap(Sandbox.command(config, cmd))
```

The Buildkite sandbox plugin, which writes the command into a replacement for `/bin/bash`:

```julia
# Sandbox.jl 2: the arguments unquoted, and the environment dropped
c = Sandbox.build_executor_command(UnprivilegedUserNamespacesExecutor(), config, ``)
println(io, join(c.exec, " "), " /bin/bash \"\$@\"")

# Sandbox.jl 3: the job's environment still goes through, with `config.env` on top
c = Sandbox.command(config, `/bin/bash`)
println(io, "exec /usr/bin/env ", Base.shell_escape(c.env...), " ",
        Base.shell_escape(c.exec...), " \"\$@\"")
```

Inside an agent's job, its `persist` directory goes in `/persist`
(`SANDBOX_PERSISTENCE_DIR`): `persist=mktempdir(ENV["SANDBOX_PERSISTENCE_DIR"])`.
