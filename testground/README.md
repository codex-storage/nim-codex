# Codex Testground

Codex Testground makes use of [Testground](https://github.com/testground/testground) and [testground-nim-sdk](https://github.com/status-im/testground-nim-sdk) for flexible end-to-end testing and infra simulations of the Codex Network.

## Prerequisites

[Testground](https://github.com/testground/testground) must be built, installed, and available in `PATH` when running `make testground`

```text
$ export PATH="${HOME}/go/bin:${PATH}"
```

## Running a Codex Testground plan locally
*Assumes a local Docker daemon. For example, on macOS [Docker Desktop](https://www.docker.com/products/docker-desktop/) should be installed and running.*

To run the default Codex Testground plan

```text
$ make testground
```

It's possible to modify a plan's build and runtime configuration via `make` variables

```text
TESTGROUND_BUILDER
TESTGROUND_OPTIONS
TESTGROUND_PLAN
TESTGROUND_RUNNER
TESTGROUND_TESTCASE
```

For example

```text
$ make \
  TESTGROUND_PLAN=simple_libp2p \
  TESTGROUND_OPTIONS="--instances=8" \
  testground
```

Take care re: shell quoting shenanigans `(╯°□°）╯︵ ┻━┻`

## Adding a new plan

When adding a Tesground plan it should have the following basic structure

```text
testground/[plan]/
├── Dockerfile
├── config.nims
├── main.nim
└── manifest.toml
```

That basic structure can be copied from e.g. `testground/simple_tcp_ping`, but take care to replace `simple_tcp_ping` with the new plan's name in `Dockerfile` and `manifest.toml`.

## Running a plan in AWS, etc.

Write me. Should mainly be a matter of passing cloud credentials and configuration via `make` variables mentioned above. Additional `make` variables may need to be added.
