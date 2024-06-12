# Codex Two-Client Test

The two-client test is a manual test you can perform to check your setup and familiarize yourself with the Codex API. These steps will guide you through running and connecting two nodes, in order to upload a file to one and then download that file from the other. This test also includes running a local blockchain node in order to have the Marketplace functionality available. However, running a local blockchain node is not strictly necessary, and you can skip steps marked as optional if you choose not start a local blockchain node.

## Prerequisite

Make sure you have built the client, and can run it as explained in the [README](../README.md).

## Steps

### 0. Setup blockchain node (optional)

You need to have installed NodeJS and npm in order to spinup a local blockchain node.

Go to directory `vendor/codex-contracts-eth` and run these two commands:
```
npm ci
npm start
```

This will launch a local Ganache blockchain.

### 1. Launch Node #1

Open a terminal and run:
- Mac/Unx: `"build/codex" --data-dir="$(pwd)/Data1" --listen-addrs="/ip4/127.0.0.1/tcp/8070" --api-port=8080  --disc-port=8090`
- Windows: `"build/codex.exe" --data-dir="Data1" --listen-addrs="/ip4/127.0.0.1/tcp/8070" --api-port=8080 --disc-port=8090`

Optionally, if you want to use the Marketplace blockchain functionality, you need to also include these flags: `--persistence --eth-account=<account>`, where `account` can be one following:

  - `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
  - `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC`
  - `0x90F79bf6EB2c4f870365E785982E1f101E93b906`
  - `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65`

**For each node use a different account!**

| Argument       | Description                                                           |
|----------------|-----------------------------------------------------------------------|
| `data-dir`     | We specify a relative path where the node will store its data.        |
| `listen-addrs` | Multiaddress where the node will accept connections from other nodes. |
| `api-port`     | Port on localhost where the node will expose its API.                 |
| `disc-port`    | Port the node will use for its discovery service.                     |
| `persistence`  | Enables Marketplace functionality. Requires a blockchain connection.    |
| `eth-account`  | Defines which blockchain account the node should use.                     |

Codex uses sane defaults for most of its arguments. Here we specify some explicitly for the purpose of this walk-through.

### 2. Sign of life

Run the command :

```bash
curl -X GET http://127.0.0.1:8080/api/codex/v1/debug/info
```

This GET request will return the node's debug information. The response will be in JSON and should look like:

```json
{
  "id": "16Uiu2HAmJ3TSfPnrJNedHy2DMsjTqwBiVAQQqPo579DuMgGxmG99",
  "addrs": [
    "/ip4/127.0.0.1/tcp/8070"
  ],
  "repo": "/Users/user/projects/nim-codex/Data1",
  "spr": "spr:CiUIAhIhA1AL2J7EWfg7x77iOrR9YYBisY6CDtU2nEhuwDaQyjpkEgIDARo8CicAJQgCEiEDUAvYnsRZ-DvHvuI6tH1hgGKxjoIO1TacSG7ANpDKOmQQ2MWasAYaCwoJBH8AAAGRAh-aKkYwRAIgB2ooPfAyzWEJDe8hD2OXKOBnyTOPakc4GzqKqjM2OGoCICraQLPWf0oSEuvmSroFebVQx-3SDtMqDoIyWhjq1XFF",
  "announceAddresses": [
    "/ip4/127.0.0.1/tcp/8070"
  ],
  "table": {
    "localNode": {
      "nodeId": "f6e6d48fa7cd171688249a57de0c1aba15e88308c07538c91e1310c9f48c860a",
      "peerId": "16Uiu2HAmJ3TSfPnrJNedHy2DMsjTqwBiVAQQqPo579DuMgGxmG99",
      "record": "...",
      "address": "0.0.0.0:8090",
      "seen": false
    },
    "nodes": []
  },
  "codex": {
    "version": "untagged build",
    "revision": "b3e626a5"
  }
}
```

| Field   | Description                                                                              |
| ------- | ---------------------------------------------------------------------------------------- |
| `id`    | Id of the node. Also referred to as 'peerId'.                                            |
| `addrs` | Multiaddresses currently open to accept connections from other nodes.                    |
| `repo`  | Path of this node's data folder.                                                         |
| `spr`   | Signed Peer Record, encoded information about this node and its location in the network. |
| `announceAddresses`   | Multiaddresses used for annoucning this node
| `table`   | Table of nodes present in the node's DHT
| `codex`   | Codex version information

### 3. Launch Node #2

We will need the signed peer record (SPR) from the first node that you got in the previous step.

Replace `<SPR HERE>` in the following command with the SPR returned from the previous command. (Note that it should include the `spr:` at the beginning.)

Open a new terminal and run:
- Mac/Linux: `"build/codex" --data-dir="$(pwd)/Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=<SPR HERE>`
- Windows: `"build/codex.exe" --data-dir="Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=<SPR HERE>`

Alternatively on Mac, Linux, or MSYS2 and a recent Codex binary you can run it in one command like:

```sh
"build/codex" --data-dir="$(pwd)/Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=$(curl -H "Accept: text/plain" http://127.0.0.1:8080/api/codex/v1/spr)
```

Notice we're using a new data-dir, and we've increased each port number by one. This is needed so that the new node won't try to open ports already in use by the first node.

We're now also including the `bootstrap-node` argument. This allows us to link the new node to another one, bootstrapping our own little peer-to-peer network. (SPR strings always start with "spr:".)

### 4. Connect The Two

Normally the two nodes will automatically connect. If they do not automatically connect or you want to manually connect nodes you can use the peerId to connect nodes.

You can get the first node's peer id by running the following command and finding the `"peerId"` in the results:

```bash
curl -X GET -H "Accept: text/plain" http://127.0.0.1:8081/api/codex/v1/debug/info
```

Next replace `<PEER ID HERE>` in the following command with the peerId returned from the previous command:

```bash
curl -X GET http://127.0.0.1:8080/api/codex/v1/connect/<PEER ID HERE>?addrs=/ip4/127.0.0.1/tcp/8071
```

Alternatively on Mac, Linux, or MSYS2 and a recent Codex binary you can run it in one command like:

```bash
curl -X GET http://127.0.0.1:8080/api/codex/v1/connect/$(curl -X GET -H "Accept: text/plain" http://127.0.0.1:8081/api/codex/v1/peerid)\?addrs=/ip4/127.0.0.1/tcp/8071
```

Notice that we are sending the peerId and the multiaddress of node 2 to the `/connect` endpoint of node 1. This provides node 1 all the information it needs to communicate with node 2. The response to this request should be `Successfully connected to peer`.

### 5. Upload The File

We're now ready to upload a file to the network. In this example we'll use node 1 for uploading and node 2 for downloading. But the reverse also works.

Next replace `<FILE PATH>` with the path to the file you want to upload in the following command:

```bash
 curl -H "Content-Type: application/octet-stream" -H "Expect: 100-continue" -T "<FILE PATH>" 127.0.0.1:8080/api/codex/v1/data -X POST
```

(Hint: if curl is reluctant to show you the response, add `-o <FILENAME>` to write the result to a file.)

Depending on the file size this may take a moment. Codex is processing the file by cutting it into blocks and generating erasure-recovery data. When the process is finished, the request will return the content-identifier (CID) of the uploaded file. It should look something like `zdj7WVxH8HHHenKtid8Vkgv5Z5eSUbCxxr8xguTUBMCBD8F2S`.

### 6. Download The File

Replace `<CID>` with the identifier returned in the previous step. Replace `<OUTPUT FILE>` with the filename where you want to store the downloaded file.

```bash
 curl 127.0.0.1:8081/api/codex/v1/data/<CID>/network --output <OUTPUT FILE>
 ```

Notice we are connecting to the second node in order to download the file. The CID we provide contains the information needed to locate the file within the network.

### 7. Verify The Results

If your file is downloaded and identical to the file you uploaded, then this manual test has passed. Rejoice! If on the other hand that didn't happen or you were unable to complete any of these steps, please leave us a message detailing your troubles.

## Notes

When using the Ganache blockchain, there are some deviations from the expected behavior, mainly linked to how blocks are mined, which affects certain functionalities in the Sales module.
Therefore, if you are manually testing processes such as payout collection after a request is finished or proof submissions, you need to mine some blocks manually for it to work correctly. You can do this by using the following curl command:

```bash
$ curl -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":67}' 127.0.0.1:8545
```
