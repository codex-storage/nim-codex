# Codex Decentralized Durability Engine

> The Codex project aims to create a decentralized durability engine that allows persisting data in p2p networks. In other words, it allows storing files and data with predictable durability guarantees for later retrieval.

> WARNING: This project is under active development and is considered pre-alfa.

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)](#stability)
[![CI](https://github.com/status-im/nim-codex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/status-im/nim-codex/actions?query=workflow%3ACI+branch%3Amain)
[![Codecov](https://codecov.io/gh/status-im/nim-codex/branch/main/graph/badge.svg?token=XFmCyPSNzW)](https://codecov.io/gh/status-im/nim-codex)


## Build and Run

To build the project clone it and run `make update` and `make exec`, the executable will be placed under the `build` directory under the project root.

```
./build/codex --help
Usage:

codex [OPTIONS]... command

The following options are available:

     --log-level            Sets the log level [=LogLevel.INFO].
     --metrics              Enable the metrics server [=false].
     --metrics-address      Listening address of the metrics server [=127.0.0.1].
     --metrics-port         Listening HTTP port of the metrics server [=8008].
 -d, --data-dir             The directory where codex will store configuration and data..
 -l, --listen-port          Specifies one or more listening ports for the node to listen on. [=0].
 -i, --listen-ip            The public IP [=0.0.0.0].
     --udp-port             Specify the discovery (UDP) port [=8090].
     --net-privkey          Source of network (secp256k1) private key file (random|<path>) [=random].
 -b, --bootstrap-node       Specifies one or more bootstrap nodes to use when connecting to the network..
     --max-peers            The maximum number of peers to connect to [=160].
     --agent-string         Node agent string which is used as identifier in network [=Codex].
 -p, --api-port             The REST Api port [=8080].
 -c, --cache-size           The size in MiB of the block cache, 0 disables the cache [=100].
     --eth-provider         The URL of the JSON-RPC API of the Ethereum node [=ws://localhost:8545].
     --eth-account          The Ethereum account that is used for storage contracts [=EthAddress.default].
     --eth-deployment       The json file describing the contract deployment [=string.default].

Available sub-commands:

codex initNode
```

### Examples:

```bash
./build/codex --data-dir=`pwd`"/Codex1" -i=127.0.0.1
```

This will start codex with a data directory pointing to `Codex` under the current execution directory and announce itself on the DHT under `127.0.0.1`.

```bash
./build/codex --data-dir=`pwd`"/Codex2" -i=127.0.0.1 --api-port=8081 --udp-port=8091 --bootstrap-node=spr:CiUIAhIhAmqg5fVU2yxPStLdUOWgwrkWZMHW2MHf6i6l8IjA4tssEgIDARpICicAJQgCEiECaqDl9VTbLE9K0t1Q5aDCuRZkwdbYwd_qLqXwiMDi2ywQ5v2VlAYaCwoJBH8AAAGRAh-aGgoKCAR_AAABBts3KkcwRQIhAPOKl38CviplVbMVnA_9q3N1K_nk5oGuNp7DWeOqiJzzAiATQ2acPyQvPxLU9YS-TiVo4RUXndRcwMFMX2Yjhw8k3A
```

Same as the first example, but this time the REST api is listening on port 8081 and the DHT on port 8091. The `--bootstrap-node` is a serialized peer record that allows bootstrapping the DHT, this should point to a valid peer record produced by another node. This can be obtained using the [info](#apicodexv1info) endpoint.

## Interacting with the client

The client exposes a REST api that can be invoked with any http client, the following examples assume the use of the `curl` command.

#### `/api/codex/v1/connect/{peerId}`

Connect to a peer identified by its peer id. Takes an optional `addrs` parameter with a list of valid [multiaddresses](https://multiformats.io/multiaddr/). If `addrs` is absent, the peer will be discovered over the DHT.

Example:

```bash
curl "127.0.0.1:8080/api/codex/v1/connect/<peer id>?addrs=<multiaddress>"
```

#### `/api/codex/v1/download/{id}`

Download data identified by a `Cid`.

Example:

```bash
 curl -vvv "127.0.0.1:8080/api/codex/v1/download/<Cid of the content>" --output <name of output file>
 ```

#### `/api/codex/v1/upload`

Upload a file, upon success returns the `Cid` of the uploaded file.

Example:

```bash
curl -vvv -H "Tranfer-Encoding: chunked" "127.0.0.1:8080 api/codex/v1/upload" -F file=@<path to file>
```

#### `/api/codex/v1/info`

Get useful node info such as it's peer id, address and Spr.

Example:

```bash
curl -vvv "127.0.0.1:8080/api/codex/v1/info"
```
