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

Instructions below correspond roughly to environmental setups in nim-codex's [CI workflow](https://github.com/codex-storage/nim-codex/blob/main/.github/workflows/ci.yml) and are known to work.

Other approaches may be viable. On macOS, some users may prefer [MacPorts](https://www.macports.org/) to [Homebrew](https://brew.sh/). On Windows, rather than use MSYS2, some users may prefer to install developer tools with [winget](https://docs.microsoft.com/en-us/windows/package-manager/winget/), [Scoop](https://scoop.sh/), or [Chocolatey](https://chocolatey.org/), or download installers for e.g. Make and CMake while otherwise relying on official Windows developer tools. Community contributions to these docs and our build system are welcome!

### Rust

The current implementation of Codex's zero-knowledge proving circuit requires the installation of rust v1.76.0 or greater. Be sure to install it for your OS and add it to your terminal's path such that the command `cargo --version` gives a compatible version.

### Linux

*Package manager commands may require `sudo` depending on OS setup.*

On a bare bones installation of Debian (or a distribution derived from Debian, such as Ubuntu), run

```shell
$ apt-get update && apt-get install build-essential cmake curl git rustc cargo libzip-dev
```

Non-Debian distributions have different package managers: `apk`, `dnf`, `pacman`, `rpm`, `yum`, etc.

For example, on a bare bones installation of Fedora, run

```shell
dnf install @development-tools cmake gcc-c++ libzip rust cargo
```

In case your distribution does not provide required Rust version, we may install it using [rustup](https://www.rust-lang.org/tools/install)
```shell
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs/ | sh -s -- --default-toolchain=1.76.0 -y

. "$HOME/.cargo/env"
```

### macOS

Install the [Xcode Command Line Tools](https://mac.install.guide/commandlinetools/index.html) by opening a terminal and running
```shell
xcode-select --install
```

Install [Homebrew (`brew`)](https://brew.sh/) and in a new terminal run
```shell
brew install bash cmake rust libzip
```

Check that `PATH` is setup correctly
```shell
which bash cmake

# /usr/local/bin/bash
# /usr/local/bin/cmake
```

### Windows + MSYS2

*Instructions below assume the OS is 64-bit Windows and that the hardware or VM is [x86-64](https://en.wikipedia.org/wiki/X86-64) compatible.*

Download and run the installer from [msys2.org](https://www.msys2.org/).

Launch an MSYS2 [environment](https://www.msys2.org/docs/environments/). UCRT64 is generally recommended: from the Windows *Start menu* select `MSYS2 MinGW UCRT x64`.

Assuming a UCRT64 environment, in Bash run
```shell
pacman -Suy
pacman -S base-devel git unzip mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-rust
```

<!-- #### Headless Windows container -->
<!-- add instructions re: getting setup with MSYS2 in a Windows container -->
<!-- https://github.com/StefanScherer/windows-docker-machine -->

#### Optional: VSCode Terminal integration

You can link the MSYS2-UCRT64 terminal into VSCode by modifying the configuration file as shown below.
File: `C:/Users/<username>/AppData/Roaming/Code/User/settings.json`
```json
{
    ...
    "terminal.integrated.profiles.windows": {
      ...
      "MSYS2-UCRT64": {
        "path": "C:\\msys64\\usr\\bin\\bash.exe",
        "args": [
          "--login",
          "-i"
        ],
        "env": {
          "MSYSTEM": "UCRT64",
          "CHERE_INVOKING": "1",
          "MSYS2_PATH_TYPE": "inherit"
        }
      }
    }
}
```

### Other

It is possible that nim-codex can be built and run on other platforms supported by the [Nim](https://nim-lang.org/) language: BSD family, older versions of Windows, etc. There has not been sufficient experimentation with nim-codex on such platforms, so instructions are not provided. Community contributions to these docs and our build system are welcome!

## Repository

In Bash run
```shell
git clone https://github.com/codex-storage/nim-codex.git repos/nim-codex && cd repos/nim-codex
```

nim-codex uses the [nimbus-build-system](https://github.com/status-im/nimbus-build-system), so next run
```shell
make update
```

This step can take a while to complete because by default it builds the [Nim compiler](https://nim-lang.org/docs/nimc.html).

To see more output from `make` pass `V=1`. This works for all `make` targets in projects using the nimbus-build-system
```shell
make V=1 update
```

## Executable

In Bash run
```shell
make
```

The default `make` target creates the `build/codex` executable.

## Example usage

See the [instructions](README.md#cli-options) in the main readme.

## Tests

In Bash run
```shell
make test
```

### testAll

#### Prerequisites

To run the integration tests, an Ethereum test node is required. Follow these instructions to set it up.

##### Windows (do this before 'All platforms')

1. Download and install Visual Studio 2017 or newer. (Not VSCode!) In the Workloads overview, enable `Desktop development with C++`. ( https://visualstudio.microsoft.com )

##### All platforms

1. Install NodeJS (tested with v18.14.0), consider using NVM as a version manager. [Node Version Manager (`nvm`)](https://github.com/nvm-sh/nvm#readme)
1. Open a terminal
1. Go to the vendor/codex-contracts-eth folder: `cd /<git-root>/vendor/codex-contracts-eth/`
1. `npm install` -> Should complete with the number of packages added and an overview of known vulnerabilities.
1. `npm test` -> Should output test results. May take a minute.

Before the integration tests are started, you must start the Ethereum test node manually.
1. Open a terminal
1. Go to the vendor/codex-contracts-eth folder: `cd /<git-root>/vendor/codex-contracts-eth/`
1. `npm start` -> This should launch Hardhat, and output a number of keys and a warning message.

#### Run

The `testAll` target runs the same tests as `make test` and also runs tests for nim-codex's Ethereum contracts, as well a basic suite of integration tests.

To run `make testAll`.

Use a new terminal to run:
```shell
make testAll
```
