# Sandbox.jl

[`Sandbox.jl`](https://github.com/JuliaContainerization/Sandbox.jl) runs commands in a
root filesystem of your choice, with the host paths you choose mounted in it, on Linux,
with user namespaces.  See the README for an introduction.

```@docs
SandboxConfig
Sandbox.command
run(::SandboxConfig, ::Cmd)
```

## Mounts

```@docs
Bind
Overlay
Tmpfs
Symlink
Sandbox.Devpts
Sandbox.CgroupView
Sandbox.default_mounts
```

## Persistence

```@docs
Sandbox.scratch_persist_dir
Sandbox.probe_persist
Sandbox.remove_persist
```

## Other architectures

```@docs
Sandbox.register_multiarch
```

## Utilities

```@docs
Sandbox.debian_rootfs
Sandbox.multiarch_rootfs
Sandbox.getuid
Sandbox.getgid
Sandbox.disable_apparmor_userns_restrictions
```
