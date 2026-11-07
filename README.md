# Sandbox.jl

[![Stable][docs-stable-img]][docs-stable-url]
[![Dev][docs-dev-img]][docs-dev-url]
[![Build Status][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://juliacontainerization.github.io/Sandbox.jl/stable
[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://juliacontainerization.github.io/Sandbox.jl/dev
[ci-img]: https://github.com/JuliaContainerization/Sandbox.jl/actions/workflows/ci.yml/badge.svg?branch=main
[ci-url]: https://github.com/JuliaContainerization/Sandbox.jl/actions/workflows/ci.yml
[codecov-img]: https://codecov.io/gh/JuliaContainerization/Sandbox.jl/branch/main/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaContainerization/Sandbox.jl

> The cultured host's toolkit for ill-mannered Linux guests.

Sandbox.jl runs commands in a root filesystem of your choice, with the host paths you
choose mounted in it, on Linux, without privileges: it uses user namespaces.  It was
built for [BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl), and also
runs the jobs of Julia's CI.

## Basic usage

A `SandboxConfig` says what the sandbox is made of, and `Sandbox.command` turns it and a
command into a `Cmd` that runs the command in it.  That is an ordinary `Cmd`: `run` it,
`read` it, `pipeline` it or `open` it as any other.

```julia
using Sandbox

config = SandboxConfig(; rootfs=Sandbox.debian_rootfs(),
                       mounts=["/work" => Bind(pwd(); writable=true)],
                       env=Dict("PATH" => "/usr/bin:/bin"), cwd="/work")

run(config, `/bin/bash -l`)                                  # interactive
read(Sandbox.command(config, `/bin/uname -a`), String)       # capture output
run(pipeline(Sandbox.command(config, `/bin/ls`); stdout="listing.txt"))
```

`run(config, cmd)` is `run(Sandbox.command(config, cmd))`, after registering the
interpreters for `multiarch` (see below).  `Sandbox.command` itself has no side effects.

The command exits as it would outside, or with 125 when the sandbox could not be set up,
126 when the command could not be executed, and 127 when it was not found.

## Mounts

`mounts` are `destination => mount` pairs, mounted in order (a dictionary is mounted
parents first):

* `Bind(source; writable=false, devices=false, optional=false)`: a host file or
  directory, read-only unless `writable`.  Device nodes in it only work with `devices`
  (for `/dev/kvm` or a GPU), and setuid bits never do.  An `optional` source may be
  missing.
* `Overlay(source; readonly=false)`: a host directory, whose changes go to the persist
  directory (or nowhere, see below) instead of `source`.  With `readonly`, an overlay
  shows what an earlier overlay at the same destination persisted.
* `Tmpfs(; size=nothing, mode=0o755)`: a fresh tmpfs.
* `Symlink(target)`: a symbolic link.

Before these come the default mounts (`Sandbox.default_mounts()`): a fresh `/dev` with
`null`, `zero`, `full`, `random`, `urandom`, `tty`, pseudo-terminals and `/dev/shm`, the
host's `/sys` read-only, and a read-only view of the sandbox's cgroup at
`/sys/fs/cgroup`.  A mount at or above one of their destinations replaces it, e.g.
`"/dev/shm" => Tmpfs(size="8G", mode=0o1777)`, and `defaults=false` leaves them all out.
`/proc` is always the procfs of the sandbox's PID namespace.

## Persistence

The sandbox sees an overlay of `rootfs`.  Its changes, and those to `Overlay` mounts, go
to a tmpfs (of `tmpfs_size`, 1G by default) and are gone when the command exits, unless
`persist` names a directory to keep them in.  A later sandbox with the same `persist`
directory sees them again.

```julia
persist = Sandbox.scratch_persist_dir()      # or any directory you choose
Sandbox.probe_persist(persist)               # can it hold the changes of an overlay?
config = SandboxConfig(; rootfs=Sandbox.debian_rootfs(), persist)
run(config, `/bin/sh -c "apt update && apt install -y curl"`)
run(config, `/usr/bin/curl --version`)
Sandbox.remove_persist(persist)
```

The directory is yours: Sandbox.jl creates what it needs in it (`upper/` and `work/`, with
a subdirectory per overlay, and `xattrs`), and only one sandbox at a time may use it.  It
must be on a filesystem that can hold overlayfs's upper layer (not ZFS, nor another
overlayfs, such as the root of a sandbox).  `Sandbox.remove_persist` removes it,
including the work directories that overlayfs makes unreadable.

## Privileges

`mode=:userns`, the default, sets up the sandbox in a user namespace, as the calling
user.  Where the kernel doesn't allow mounting an overlay in a user namespace (before
Linux 5.11, unless the distribution patched it in), `mode=:sudo` mounts as root through
`sudo` instead; the command still runs as the calling user, without its supplementary
groups.  Sandbox.jl never escalates on its own.

### Ubuntu and AppArmor

Since 23.10, Ubuntu uses AppArmor to prevent unprivileged processes from creating user
namespaces.  To lift the restriction, run the following (it uses `sudo`, and persists the
setting in `/etc/sysctl.d`):

```julia
using Sandbox
Sandbox.disable_apparmor_userns_restrictions()
```

## What the sandbox isolates

A sandbox gets its own PID, mount, user, UTS (hostname), IPC and cgroup namespaces; it shares
the host's network.  Inside it:

* `/proc` is a fresh procfs that shows only the sandbox's processes, and `/dev` and
  `/dev/shm` are fresh tmpfs instead of the host's.
* `/sys` is the host's, read-only.  `/sys/fs/cgroup` shows only the cgroup the sandbox was
  started in (and its children), read-only, so programs can read their own limits but not
  reach other cgroups.  That they cannot change their own limits either (through a cgroup2
  mount of a cgroup namespace of their own) also needs the host to mount cgroup2 with
  `nsdelegate`, as systemd does.  On hosts without cgroup v2, `/sys/fs/cgroup` is empty.
* The sandboxed processes run in a nested user namespace in which every mount made while
  setting up the sandbox is locked: they cannot be unmounted to reveal what they cover, nor
  made writable.  The exception is `/proc`, which is the sandbox's own; below it is a procfs
  of the launcher's PID namespace in the sandbox, not the host's.  They are root there (unless `uid` says otherwise), own their PID, UTS and
  IPC namespaces, and can create namespaces and mount filesystems of their own, so
  sandboxes can be nested (with a `persist` directory bound in from outside, as the
  sandbox's root can't hold the changes of another overlay).

## Getting more rootfs images

To use more interesting rootfs images, you can either create your own using tools such as
[`debootstrap`](https://wiki.debian.org/Debootstrap) or export one from a docker image.
See the [`contrib`](contrib/) directory for examples of both.

You can also check out the latest releases of the
[`JuliaCI/rootfs-images` repository](https://github.com/JuliaCI/rootfs-images/), which
curates a collection of rootfs images for use in CI workloads.

## Multiarch usage

Sandbox can register `qemu-user-static` interpreters with `binfmt_misc` to run executables
of other architectures, on Linux hosts with the `x86_64`, `aarch64` or `powerpc64le`
architectures.  The target architectures supported are `x86_64`, `i686`, `aarch64`,
`armv7l` and `powerpc64le`.  Note that while `qemu-user-static` is a marvel of modern
engineering, it does still impose some performance penalties, and there may be occasional
bugs that break emulation faithfulness.

For example, to run an aarch64 (ARM v8) shell:

```julia
using Base.BinaryPlatforms, Sandbox

aarch64 = Platform("aarch64", "linux")
config = SandboxConfig(; rootfs=Sandbox.debian_rootfs(; platform=aarch64), multiarch=[aarch64])

# `run` registers the interpreter (with `sudo`) if needed; before `Sandbox.command`,
# call `Sandbox.register_multiarch(config)`.
run(config, `/bin/bash -l`)
```

## Upgrading from Sandbox.jl 2

See [NEWS.md](NEWS.md).
