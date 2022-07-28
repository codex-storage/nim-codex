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

To build the project, clone it and run:

```bash
make update && make exec
```

The executable will be placed under the `build` directory under the project root.

Run the client with:

```bash
./build/codex
```

### CLI Options

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

### Example: running two Codex clients

```bash
./build/codex --data-dir="$(pwd)/Codex1" -i=127.0.0.1
```

This will start codex with a data directory pointing to `Codex` under the current execution directory and announce itself on the DHT under `127.0.0.1`.

To run a second client that automatically discovers nodes on the network, we need to get the Signed Peer Record (SPR) of first client, Client1. We can do this by querying the `/info` endpoint of the node's REST API.

`curl http://127.0.0.1:8080/api/codex/v1/info`

This should output information about Client1, including its PeerID, TCP/UDP addresses, data directory, and SPR:

```json
{
  "id": "16Uiu2HAm92LGXYTuhtLaZzkFnsCx6FFJsNmswK6o9oPXFbSKHQEa",
  "addrs": [
    "/ip4/0.0.0.0/udp/8090",
    "/ip4/0.0.0.0/tcp/49336"
  ],
  "repo": "/repos/status-im/nim-codex/Codex1",
  "spr": "spr:CiUIAhIhAmqg5fVU2yxPStLdUOWgwrkWZMHW2MHf6i6l8IjA4tssEgIDARpICicAJQgCEiECaqDl9VTbLE9K0t1Q5aDCuRZkwdbYwd_qLqXwiMDi2ywQ5v2VlAYaCwoJBH8AAAGRAh-aGgoKCAR_AAABBts3KkcwRQIhAPOKl38CviplVbMVnA_9q3N1K_nk5oGuNp7DWeOqiJzzAiATQ2acPyQvPxLU9YS-TiVo4RUXndRcwMFMX2Yjhw8k3A"
}
```

Now, let's start a second client, Client2. Because we're already using the default ports TCP (:8080) and UDP (:8090) for the first client, we have to specify new ports to avoid a collision. Additionally, we can specify the SPR from Client1 as the bootstrap node for discovery purposes, allowing Client2 to determine where content is located in the network.

```bash
./build/codex --data-dir="$(pwd)/Codex2" -i=127.0.0.1 --api-port=8081 --udp-port=8091 --bootstrap-node=spr:CiUIAhIhAmqg5fVU2yxPStLdUOWgwrkWZMHW2MHf6i6l8IjA4tssEgIDARpICicAJQgCEiECaqDl9VTbLE9K0t1Q5aDCuRZkwdbYwd_qLqXwiMDi2ywQ5v2VlAYaCwoJBH8AAAGRAh-aGgoKCAR_AAABBts3KkcwRQIhAPOKl38CviplVbMVnA_9q3N1K_nk5oGuNp7DWeOqiJzzAiATQ2acPyQvPxLU9YS-TiVo4RUXndRcwMFMX2Yjhw8k3A
```

There are now two clients running. We could upload a file to Client1 and download that file (given its CID) using Client2, by using the clients' REST API.

## Interacting with the client

The client exposes a REST API that can be used to interact with the clients. These commands could be invoked with any HTTP client, however the following endpoints assume the use of the `curl` command.

### `/api/codex/v1/connect/{peerId}`

Connect to a peer identified by its peer id. Takes an optional `addrs` parameter with a list of valid [multiaddresses](https://multiformats.io/multiaddr/). If `addrs` is absent, the peer will be discovered over the DHT.

Example:

```bash
curl "127.0.0.1:8080/api/codex/v1/connect/<peer id>?addrs=<multiaddress>"
```

### `/api/codex/v1/download/{id}`

Download data identified by a `Cid`.

Example:

```bash
 curl -vvv "127.0.0.1:8080/api/codex/v1/download/<Cid of the content>" --output <name of output file>
 ```

### `/api/codex/v1/upload`

Upload a file, upon success returns the `Cid` of the uploaded file.

Example:

```bash
curl -vvv -H "Tranfer-Encoding: chunked" "127.0.0.1:8080/api/codex/v1/upload" -X POST --data-binary "@<path to file>"
```

### `/api/codex/v1/info`

Get useful node info such as its peer id, address and SPR.

Example:

```bash
curl -vvv "127.0.0.1:8080/api/codex/v1/info"
```
