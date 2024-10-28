# Sandbox.jl

[![Stable][docs-stable-img]][docs-stable-url]
[![Dev][docs-dev-img]][docs-dev-url]
[![Build Status][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://staticfloat.github.io/Sandbox.jl/stable
[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://staticfloat.github.io/Sandbox.jl/dev
[ci-img]: https://github.com/JuliaContainerization/Sandbox.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/JuliaContainerization/Sandbox.jl/actions/workflows/ci.yml
[codecov-img]: https://codecov.io/gh/JuliaContainerization/Sandbox.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaContainerization/Sandbox.jl

> The cultured host's toolkit for ill-mannered Linux guests.

This package provides basic containerization tools for running Linux guests on a variety of platforms.
As of the time of writing, it supports two execution backends:

* A Linux User Namespaces executor, which is very fast and lightweight

* A [Docker](https://www.docker.com/) (or [Podman](https://podman.io/)) executor which is slower, but more compatible (it works on macOS, and may work on Windows)

The executors are responsible for running/virtualizing a given `Cmd` within a root filesystem that is defined by the user, along with various paths that can be mounted within the sandbox.
These capabilities were originally built for [BinaryBuilder.jl](https://github.com/JuliaPackaging/BinaryBuilder.jl), however this functionality is now mature enough that it may be useful elsewhere.

## Basic usage

To make use of this toolkit, you will need to have a root filesystem image that you want to use.
This package can download a minimal Debian rootfs that can be used for quick tests; to launch `/bin/bash` in an interactive shell run the following:

```julia
using Sandbox

config = SandboxConfig(
    Dict("/" => Sandbox.debian_rootfs());
    stdin, stdout, stderr,
)
with_executor() do exe
    run(exe, config, `/bin/bash -l`)
end
```

While this launches an interactive session due to hooking up `stdout`/`stdin`, one can easily capture output by setting `stdout` to an `IOBuffer`, or even a `PipeBuffer` to chain together multiple processes from different sandboxes.

## Getting more rootfs images

To use more interesting rootfs images, you can either create your own using tools such as [`debootstrap`](https://wiki.debian.org/Debootstrap) or you can pull one from docker by using the `pull_docker_image()` function defined within this package.  See the [`contrib`](contrib/) directory for examples of both.

You can also check out the latest releases of the [`JuliaCI/rootfs-images` repository](https://github.com/JuliaCI/rootfs-images/), which curates a collection of rootfs images for use in CI workloads.

## Multiarch usage

Sandbox contains facilities for automatically registering `qemu-user-static` interpreters with `binfmt_misc` to support running on multiple architectures.
As of the time of this writing, this is only supported on when running on a Linux host with the `x86_64`, `aarch64` or `powerpc64le` host architectures.
The target architectures supported are `x86_64`, `i686`, `aarch64`, `armv7l` and `powerpc64le`.
Note that while `qemu-user-static` is a marvel of modern engineering, it does still impose some performance penalties, and there may be occasional bugs that break emulation faithfulness.
