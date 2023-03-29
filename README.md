# Codex Decentralized Durability Engine

> The Codex project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alpha.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/status-im/nim-codex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/status-im/nim-codex/actions?query=workflow%3ACI+branch%3Amain)
[![Codecov](https://codecov.io/gh/status-im/nim-codex/branch/main/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/status-im/nim-codex)
[![Discord](https://img.shields.io/discord/895609329053474826)](https://discord.gg/CaJTh24ddQ)


## Build and Run

For detailed instructions on preparing to build nim-codex see [*Building Codex*](BUILDING.md).

To build the project, clone it and run:

```bash
make update && make
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
build/codex
```

### CLI Options

```
build/codex --help
Usage:

codex [OPTIONS]... command

The following options are available:

     --log-level            Sets the log level [=INFO].
     --metrics              Enable the metrics server [=false].
     --metrics-address      Listening address of the metrics server [=127.0.0.1].
     --metrics-port         Listening HTTP port of the metrics server [=8008].
 -d, --data-dir             The directory where codex will store configuration and data..
 -i, --listen-addrs         Multi Addresses to listen on [=/ip4/0.0.0.0/tcp/0].
 -a, --nat                  IP Addresses to announce behind a NAT [=127.0.0.1].
 -e, --disc-ip              Discovery listen address [=0.0.0.0].
 -u, --disc-port            Discovery (UDP) port [=8090].
     --net-privkey          Source of network (secp256k1) private key file path or name [=key].
 -b, --bootstrap-node       Specifies one or more bootstrap nodes to use when connecting to the network..
     --max-peers            The maximum number of peers to connect to [=160].
     --agent-string         Node agent string which is used as identifier in network [=Codex].
 -p, --api-port             The REST Api port [=8080].
     --repo-kind            backend for main repo store (fs, sqlite) [=fs].
 -q, --storage-quota        The size of the total storage quota dedicated to the node [=8589934592].
 -t, --block-ttl            Default block timeout in seconds - 0 disables the ttl [=86400].
 -c, --cache-size           The size in MiB of the block cache, 0 disables the cache - might help on slow
                            hardrives [=0].
     --persistence          Enables persistence mechanism, requires an Ethereum node [=false].
     --eth-provider         The URL of the JSON-RPC API of the Ethereum node [=ws://localhost:8545].
     --eth-account          The Ethereum account that is used for storage contracts [=EthAddress.none].
     --eth-deployment       The json file describing the contract deployment [=string.none].

Available sub-commands:

codex initNode
```

### Example: running two Codex clients

To get acquainted with Codex, consider running the manual two-client test described [HERE](docs/TWOCLIENTTEST.md).

## API

The client exposes a REST API that can be used to interact with the clients. Overview of the API can be found on [api.codex.storage](https://api.codex.storage).
