# Codex Two-Client Test

The two-client test is a manual test you can perform to check your setup and familiarize yourself with the Codex API. These steps will guide you through running and connecting two nodes, in order to upload a file to one and then download that file from the other. For the purpose of this test we will be running Codex disconnected from any Ethereum nodes, so no currency is required. Additionally, the contracts/sales/marketplace APIs will be unavailable for this reason.

## Prerequisite

Make sure you have built the client, and can run it as explained in the [README](../README.md).

## Steps

### 1. Launch Node #1

Open a terminal and run:
- Mac/Unx: `"build/codex" --data-dir="$(pwd)\Data1" --listen-addrs=/ip4/127.0.0.1/tcp/8070 --api-port=8080  --disc-port=8090`
- Windows: `"build/codex.exe" --data-dir="Data1" --listen-addrs=/ip4/127.0.0.1/tcp/8070 --api-port=8080 --disc-port=8090`

(Hint: If your terminal interprets the '/' in the listen-address as a reference to your root path, try running the command from a shell-script!)

| Argument       | Description                                                           |
| -------------- | --------------------------------------------------------------------- |
| `data-dir`     | We specify a relative path where the node will store its data.        |
| `listen-addrs` | Multiaddress where the node will accept connections from other nodes. |
| `api-port`     | Port on localhost where the node will expose its API.                 |
| `disc-port`    | Port the node will use for its discovery service.                     |

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
- Mac/Unx: `"build/codex" --data-dir="$(pwd)\Data2" --listen-addrs=/ip4/127.0.0.1/tcp/8071 --api-port=8081 --disc-port=8091 --bootstrap-node=<SPR HERE>`
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
 curl -H "content-type: application/octet-stream" -H "Expect: 100-continue" -T "<FILE PATH>" 127.0.0.1:8080/api/codex/v1/upload -X POST
```

(Hint: if curl is reluctant to show you the response, add `-o <FILENAME>` to write the result to a file.)

Depending on the file size this may take a moment. Codex is processing the file by cutting it into blocks and generating erasure-recovery data. When the process is finished, the request will return the content-identifier (CID) of the uploaded file. It should look something like `zdj7WVxH8HHHenKtid8Vkgv5Z5eSUbCxxr8xguTUBMCBD8F2S`.

### 6. Download The File

Replace `<CID>` with the identifier returned in the previous step. Replace `<OUTPUT FILE>` with the filename where you want to store the downloaded file.

```bash
 curl 127.0.0.1:8081/api/codex/v1/download/zdj7Wfm18wewSWL9SPqddhJuu5ii1TJD39rtt3JbVYdKcqM1K --output <OUTPUT FILE>
 ```

Notice we are connecting to the second node in order to download the file. The CID we provide contains the information needed to locate the file within the network.

### 7. Verify The Results

If your file is downloaded and identical to the file you uploaded, then this manual test has passed. Rejoice! If on the other hand that didn't happen or you were unable to complete any of these steps, please leave us a message detailing your troubles.

