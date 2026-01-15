# Logos Storage Decentralized Engine

> The Logos Storage project aims to create a decentralized engine that allows persisting data in p2p networks.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/logos-storage/logos-storage-nim/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/logos-storage/logos-storage-nim/actions/workflows/ci.yml?query=branch%3Amaster)
[![Docker](https://github.com/logos-storage/logos-storage-nim/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/logos-storage/logos-storage-nim/actions/workflows/docker.yml?query=branch%3Amaster)
[![Codecov](https://codecov.io/gh/logos-storage/logos-storage-nim/branch/master/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/logos-storage/logos-storage-nim)
[![Discord](https://img.shields.io/discord/895609329053474826)](https://discord.gg/CaJTh24ddQ)
![Docker Pulls](https://img.shields.io/docker/pulls/codexstorage/nim-codex)


## Build and Run

For detailed instructions on preparing to build logos-storagenim see [*Build Logos Storage*](https://docs.codex.storage/learn/build).

To build the project, clone it and run:

```bash
make update && make
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
build/storage
```

## Configuration

It is possible to configure a Logos Storage node in several ways:
 1. CLI options
 2. Environment variables
 3. Configuration file

The order of priority is the same as above: CLI options --> Environment variables --> Configuration file.

Please check [documentation](https://docs.codex.storage/learn/run#configuration) for more information.

## Guides

To get acquainted with Logos Storage, consider:
* running the simple [Logos Storage Two-Client Test](https://docs.codex.storage/learn/local-two-client-test) for a start, and;
* if you are feeling more adventurous, try [Running a Local Logos Storage Network with Marketplace Support](https://docs.codex.storage/learn/local-marketplace) using a local blockchain as well.

## API

The client exposes a REST API that can be used to interact with the clients. Overview of the API can be found on [api.codex.storage](https://api.codex.storage).

## Bindings

Logos Storage provides a C API that can be wrapped by other languages. The bindings is located in the `library` folder.
Currently, only a Go binding is included.

### Build the C library

```bash
make libstorage
```

This produces the shared library under `build/`.

### Run the Go example

Build the Go example:

```bash
go build -o storage-go examples/golang/storage.go
```

Export the library path:

```bash
export LD_LIBRARY_PATH=build
```

Run the example:

```bash
./storage-go
```

### Static vs Dynamic build

By default, Logos Storage builds a dynamic library (`libstorage.so`), which you can load at runtime.
If you prefer a static library (`libstorage.a`), set the `STATIC` flag:

```bash
# Build dynamic (default)
make libstorage

# Build static
make STATIC=1 libstorage
```

### Limitation

Callbacks must be fast and non-blocking; otherwise, the working thread will hang and prevent other requests from being processed.

## Contributing and development

Feel free to dive in, contributions are welcomed! Open an issue or submit PRs.

### Linting and formatting

`logos-storage-nim` uses [nph](https://github.com/arnetheduck/nph) for formatting our code and it is required to adhere to its styling.
If you are setting up fresh setup, in order to get `nph` run `make build-nph`.
In order to format files run `make nph/<file/folder you want to format>`. 
If you want you can install Git pre-commit hook using `make install-nph-commit`, which will format modified files prior committing them. 
If you are using VSCode and the [NimLang](https://marketplace.visualstudio.com/items?itemName=NimLang.nimlang) extension you can enable "Format On Save" (eq. the `nim.formatOnSave` property) that will format the files using `nph`.