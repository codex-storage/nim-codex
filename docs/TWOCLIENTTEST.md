# Codex Two-Client Test

The two-client test is a manual test you can perform to check your setup and familiarize yourself with the Codex API. These steps will guide you through running and connecting two nodes, in order to upload a file to one and then download that file from the other. This test also includes running a local blockchain node in order to have the Marketplace functionality available. However, running a local blockchain node is not strictly necessary, and you can skip steps marked as optional if you choose not start a local blockchain node.

## Prerequisite

Make sure you have built the client, and can run it as explained in the [README](../README.md).

## Steps

### 0. Setup blockchain node (optional)

You need to have installed NodeJS and npm in order to spinup a local blockchain node.

Go to directory `vendor/codex-contracts-eth` and run these commands:
```
$ npm ci
$ npm start
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

```bash
curl --request GET \
  --url http://127.0.0.1:8080/api/codex/v1/debug/info
```

This GET request will return the node's debug information. The response JSON should look like:

```json
{
	"id": "16Uiu2HAmGzJQEvNRYVVJNxHSb1Gd5xzxTK8XRZuMJzuoDaz7fADb",
	"addrs": [
		"/ip4/127.0.0.1/tcp/8070"
	],
	"repo": "Data1",
	"spr": "spr:CiUIAhIhA0BhMXo12O4h8DSdfnvU6MWUQx3kd-xw_2sCZrWOWChOEgIDARo8CicAJQgCEiEDQGExejXY7iHwNJ1-e9ToxZRDHeR37HD_awJmtY5YKE4Q7aqInwYaCwoJBH8AAAGRAh-aKkYwRAIgSHGvrb4mxQbOTU5wdcJJYz3fErkVx4v09nqHE4n9d4ECIGWyfF58pmfUKeC7MWCtIhBDCgNJkjHz2JkKfJoYgqHW"
}
```

| Field   | Description                                                                              |
| ------- | ---------------------------------------------------------------------------------------- |
| `id`    | Id of the node. Also referred to as 'peerId'.                                            |
| `addrs` | Multiaddresses currently open to accept connections from other nodes.                    |
| `repo`  | Path of this node's data folder.                                                         |
| `spr`   | Signed Peer Record, encoded information about this node and its location in the network. |

### 3. Launch Node #2

Replace `<SPR HERE>` in the next command with the string value for `spr`, returned by the first node's `debug/info` response.

Open a new terminal and run:
- Mac/Unx: `"build/codex" --data-dir="$(pwd)/Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=<SPR HERE>`
- Windows: `"build/codex.exe" --data-dir="Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=<SPR HERE>`

Notice we're using a new data-dir, and we've increased each port number by one. This is needed so that the new node won't try to open ports already in use by the first node.

We're now also including the `bootstrap-node` argument. This allows us to link the new node to another one, bootstrapping our own little peer-to-peer network. (SPR strings always start with "spr:".)

### 4. Connect The Two

Use the command we've used in step 2 to retrieve the debug information from node 2:

```bash
curl --request GET \
  --url http://127.0.0.1:8081/api/codex/v1/debug/info
```

In the JSON response copy the value for `id`, and use it to replace `<PEER ID HERE>` in the following command:

```bash
curl --request GET \
  --url http://127.0.0.1:8080/api/codex/v1/connect/<PEER ID HERE>?addrs=/ip4/127.0.0.1/tcp/8071
```

Notice that we are sending the peerId and the multiaddress of node 2 to the `/connect` endpoint of node 1. This provides node 1 all the information it needs to communicate with node 2. The response to this request should be `Successfully connected to peer`.

### 5. Upload The File

We're now ready to upload a file to the network. In this example we'll use node 1 for uploading and node 2 for downloading. But the reverse also works.

Replace `<FILE PATH>` with the path to the file you want to upload in the following command:

```bash
 curl -H "content-type: application/octet-stream" -H "Expect: 100-continue" -T "<FILE PATH>" 127.0.0.1:8080/api/codex/v1/data -X POST
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

### 8. Offer your storage for sale (optional)

```bash
curl --location 'http://localhost:8081/api/codex/v1/sales/availability' \
--header 'Content-Type: application/json' \
--data '{
    "size": "1000000",
    "duration": "3600",
    "minPrice": "1000",
    "maxCollateral": "1"
}'
```

This informs your node that you are available to store 1MB of data for a duration of one hour (3600 seconds) at a minimum price of 1,000 tokens, automatically matching any storage requests announced on the network.

### 9. Create storage Request (optional)

```bash
curl --location 'http://localhost:8080/api/codex/v1/storage/request/<CID>' \
--header 'Content-Type: application/json' \
--data '{
    "reward": "1024",
    "duration": "120",
    "proofProbability": "8"
    "collateral": "1"
}'
```

This creates a storage Request for `<CID>` (that you have to fill in) for
duration of 2 minutes and with reward of 1024 tokens. It expects hosts to
provide a storage proof once every 8 periods on average.

It returns Request ID which you can then use to query for the Request's state as follows:

```bash
curl --location 'http://localhost:8080/api/codex/v1/storage/purchases/<RequestID>'
```

## Notes

When using the Ganache blockchain, there are some deviations from the expected behavior, mainly linked to how blocks are mined, which affects certain functionalities in the Sales module.
Therefore, if you are manually testing processes such as payout collection after a request is finished or proof submissions, you need to mine some blocks manually for it to work correctly. You can do this by using the following curl command:

```bash
$ curl -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":67}' 127.0.0.1:8545
```
