# Codex Decentralized Durability Engine

> The Codex project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/codex-storage/nim-codex/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/codex-storage/nim-codex/actions/workflows/ci.yml?query=branch%3Amaster)
[![Docker](https://github.com/codex-storage/nim-codex/actions/workflows/docker.yml/badge.svg?branch=master)](https://github.com/codex-storage/nim-codex/actions/workflows/docker.yml?query=branch%3Amaster)
[![Codecov](https://codecov.io/gh/codex-storage/nim-codex/branch/master/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/codex-storage/nim-codex)
[![Discord](https://img.shields.io/discord/895609329053474826)](https://discord.gg/CaJTh24ddQ)
![Docker Pulls](https://img.shields.io/docker/pulls/codexstorage/nim-codex)


## Build and Run

For detailed instructions on preparing to build nim-codex see [*Build Codex*](https://docs.codex.storage/learn/build).

To build the project, clone it and run:

```bash
make update && make
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
build/codex
```
## Configuration

It is possible to configure a Codex node in several ways:
 1. CLI options
 2. Env. variable
 3. Config

The order of priority is the same as above: Cli arguments > Env variables > Config file values.

### Environment variables

In order to set a configuration option using environment variables, first find the desired CLI option
and then transform it in the following way:

 1. prepend it with `CODEX_`
 2. make it uppercase
 3. replace `-` with `_`

For example, to configure `--log-level`, use `CODEX_LOG_LEVEL` as the environment variable name.

### Configuration file

A [TOML](https://toml.io/en/) configuration file can also be used to set configuration values. Configuration option names and corresponding values are placed in the file, separated by `=`. Configuration option names can be obtained from the `codex --help` command, and should not include the `--` prefix. For example, a node's log level (`--log-level`) can be configured using TOML as follows:

```toml
log-level = "trace"
```

The Codex node can then read the configuration from this file using the `--config-file` CLI parameter, like `codex --config-file=/path/to/your/config.toml`.

### CLI Options

```
build/codex --help
Usage:

codex [OPTIONS]... command

The following options are available:

     --config-file          Loads the configuration from a TOML file [=none].
     --log-level            Sets the log level [=info].
     --metrics              Enable the metrics server [=false].
     --metrics-address      Listening address of the metrics server [=127.0.0.1].
     --metrics-port         Listening HTTP port of the metrics server [=8008].
 -d, --data-dir             The directory where codex will store configuration and data.
 -i, --listen-addrs         Multi Addresses to listen on [=/ip4/0.0.0.0/tcp/0].
 -a, --nat                  IP Addresses to announce behind a NAT [=127.0.0.1].
 -e, --disc-ip              Discovery listen address [=0.0.0.0].
 -u, --disc-port            Discovery (UDP) port [=8090].
     --net-privkey          Source of network (secp256k1) private key file path or name [=key].
 -b, --bootstrap-node       Specifies one or more bootstrap nodes to use when connecting to the network.
     --max-peers            The maximum number of peers to connect to [=160].
     --agent-string         Node agent string which is used as identifier in network [=Codex].
     --api-bindaddr         The REST API bind address [=127.0.0.1].
 -p, --api-port             The REST Api port [=8080].
     --api-cors-origin      The REST Api CORS allowed origin for downloading data. '*' will allow all
                            origins, '' will allow none. [=Disallow all cross origin requests to download
                            data].
     --repo-kind            Backend for main repo store (fs, sqlite, leveldb) [=fs].
 -q, --storage-quota        The size of the total storage quota dedicated to the node [=$DefaultQuotaBytes].
 -t, --block-ttl            Default block timeout in seconds - 0 disables the ttl [=$DefaultBlockTtl].
     --block-mi             Time interval in seconds - determines frequency of block maintenance cycle: how
                            often blocks are checked for expiration and cleanup
                            [=$DefaultBlockMaintenanceInterval].
     --block-mn             Number of blocks to check every maintenance cycle [=1000].
 -c, --cache-size           The size of the block cache, 0 disables the cache - might help on slow hardrives
                            [=0].

Available sub-commands:

codex persistence [OPTIONS]... command

The following options are available:

     --eth-provider         The URL of the JSON-RPC API of the Ethereum node [=ws://localhost:8545].
     --eth-account          The Ethereum account that is used for storage contracts.
     --eth-private-key      File containing Ethereum private key for storage contracts.
     --marketplace-address  Address of deployed Marketplace contract.
     --validator            Enables validator, requires an Ethereum node [=false].
     --validator-max-slots  Maximum number of slots that the validator monitors [=1000].
     --validator-partition-size  Slot validation partition size [=1].
                            A number indicating total number of partitions into which the whole slot id
                            space will be divided. The value must be greater than 0.
     --validator-partition-index  Slot validation partition index [=0].
                            The value provided must be in the range [0, partitionSize). Only slot ids
                            satisfying condition [(slotId mod partitionSize) == partitionIndex] will be
                            observed by the validator.

Available sub-commands:

codex persistence prover [OPTIONS]...

The following options are available:

     --circom-r1cs          The r1cs file for the storage circuit.
     --circom-wasm          The wasm file for the storage circuit.
     --circom-zkey          The zkey file for the storage circuit.
     --circom-no-zkey       Ignore the zkey file - use only for testing! [=false].
     --proof-samples        Number of samples to prove [=5].
     --max-slot-depth       The maximum depth of the slot tree [=32].
     --max-dataset-depth    The maximum depth of the dataset tree [=8].
     --max-block-depth      The maximum depth of the network block merkle tree [=5].
     --max-cell-elements    The maximum number of elements in a cell [=67].
```

#### Logging

Codex uses [Chronicles](https://github.com/status-im/nim-chronicles) logging library, which allows great flexibility in working with logs.
Chronicles has the concept of topics, which categorize log entries into semantic groups.

Using the `log-level` parameter, you can set the top-level log level like `--log-level="trace"`, but more importantly,
you can set log levels for specific topics like `--log-level="info; trace: marketplace,node; error: blockexchange"`,
which sets the top-level log level to `info` and then for topics `marketplace` and `node` sets the level to `trace` and so on.

### Guides

To get acquainted with Codex, consider:
* running the simple [Codex Two-Client Test](docs/TwoClientTest.md) for a start, and;
* if you are feeling more adventurous, try [Running a Local Codex Network with Marketplace Support](docs/Marketplace.md) using a local blockchain as well.

## API

The client exposes a REST API that can be used to interact with the clients. Overview of the API can be found on [api.codex.storage](https://api.codex.storage).
