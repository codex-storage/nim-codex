# Building Codex

## Table of Contents

- [Install developer tools](#prerequisites)
  - [Linux](#linux)
  - [macOS](#macos)
  - [Windows + MSYS2](#windows--msys2)
  - [Other](#other)
- [Clone and prepare the Git repository](#repository)
- [Build the executable](#executable)
- [Run the example](#example-usage)

**Optional**
- [Run the tests](#tests)

## Prerequisites

To build nim-codex, developer tools need to be installed and accessible in the OS.

Instructions below correspond roughly to environmental setups in nim-codex's [CI workflow](https://github.com/status-im/nim-codex/blob/main/.github/workflows/ci.yml) and are known to work.

Other approaches may be viable. On macOS, some users may prefer [MacPorts](https://www.macports.org/) to [Homebrew](https://brew.sh/). On Windows, rather than use MSYS2, some users may prefer to install developer tools with [winget](https://docs.microsoft.com/en-us/windows/package-manager/winget/), [Scoop](https://scoop.sh/), or [Chocolatey](https://chocolatey.org/), or download installers for e.g. Make and CMake while otherwise relying on official Windows developer tools. Community contributions to these docs and our build system are welcome!

### Linux

*Package manager commands may require `sudo` depending on OS setup.*

On a bare bones installation of Debian (or a distribution derived from Debian, such as Ubuntu), run

```text
$ apt-get update && apt-get install build-essential cmake curl git
```

Non-Debian distributions have different package managers: `apk`, `dnf`, `pacman`, `rpm`, `yum`, etc.

For example, on a bare bones installation of Fedora, run

```text
$ dnf install @development-tools cmake gcc-c++ which
```

### macOS

Install the [Xcode Command Line Tools](https://mac.install.guide/commandlinetools/index.html) by opening a terminal and running
```text
$ xcode-select --install
```

Install [Homebrew (`brew`)](https://brew.sh/) and in a new terminal run
```text
$ brew install bash cmake
```

Check that `PATH` is setup correctly
```text
$ which bash cmake
/usr/local/bin/bash
/usr/local/bin/cmake
```

### Windows + MSYS2

*Instructions below assume the OS is 64-bit Windows and that the hardware or VM is [x86-64](https://en.wikipedia.org/wiki/X86-64) compatible.*

Download and run the installer from [msys2.org](https://www.msys2.org/).

Launch an MSYS2 [environment](https://www.msys2.org/docs/environments/). UCRT64 is generally recommended: from the Windows *Start menu* select `MSYS2 MinGW UCRT x64`.

Assuming a UCRT64 environment, in Bash run
```text
$ pacman -S base-devel git unzip mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-cmake
```

<!-- #### Headless Windows container -->
<!-- add instructions re: getting setup with MSYS2 in a Windows container -->
<!-- https://github.com/StefanScherer/windows-docker-machine -->

### Other

It is possible that nim-codex can be built and run on other platforms supported by the [Nim](https://nim-lang.org/) language: BSD family, older versions of Windows, etc. There has not been sufficient experimentation with nim-codex on such platforms, so instructions are not provided. Community contributions to these docs and our build system are welcome!

## Repository

In Bash run
```text
$ git clone https://github.com/status-im/nim-codex.git repos/nim-codex && cd repos/nim-codex
```

nim-codex uses the [nimbus-build-system](https://github.com/status-im/nimbus-build-system#readme), so next run
```text
$ make update
```

This step can take a while to complete because by default it builds the [Nim compiler](https://nim-lang.org/docs/nimc.html).

To see more output from `make` pass `V=1`. This works for all `make` targets in projects using the nimbus-build-system
```text
$ make V=1 update
```

## Executable

In Bash run
```text
$ make exec
```

The `exec` target creates the `build/codex` executable.

## Example usage

See the [instructions](README.md#cli-options) in the main readme.

## Tests

In Bash run
```text
$ make test
```

### testAll

The `testAll` target runs the same tests as `make test` and also runs tests for nim-codex's Ethereum contracts, as well a basic suite of integration tests.

To run `make testAll`, Node.js needs to be installed. [Node Version Manager (`nvm`)](https://github.com/nvm-sh/nvm#readme) is a flexible means to do that and it works on Linux, macOS, and Windows + MSYS2.

With `nvm` installed, launch a separate terminal and download the latest LTS version of Node.js
```text
$ nvm install --lts
```

In that same terminal run
```text
$ cd repos/nim-codex/vendor/dagger-contracts && npm install && npm start
```

Those commands install and launch a [Hardhat](https://hardhat.org/) environment with nim-codex's Ethereum contracts.

In the other terminal run
```text
$ make testAll
```
