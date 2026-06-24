# Storage Test Scripts

Helpers for running a local Logos Storage node and testing it against the Linode node.

## Remote Node

The Linode node is running as a `systemd` service:

```bash
ssh storage@172.235.163.25
systemctl status logos-storage.service
journalctl -u logos-storage.service -f
```

Remote node ports:

| Purpose | Address |
|---|---|
| P2P TCP | `172.235.163.25:8070` |
| Discovery UDP | `172.235.163.25:8090` |
| REST API | `127.0.0.1:8080` on the Linode only |

The REST API is not exposed publicly. Use the SSH tunnel managed by `storage-test.sh`.

## Start A Local Node

Build the local binary first if needed:

```bash
make -j1 NIMFLAGS="-d:disableMarchNative"
```

Start a local node in the foreground:

```bash
scripts/start-local-node.sh
```

Default local settings:

| Setting | Default |
|---|---|
| Binary | `./build/storage` |
| Data dir | `~/.logos/storage/local-node` |
| Log level | `info` |
| P2P TCP | `8071` |
| Discovery UDP | `8091` |
| REST API | `127.0.0.1:8080` |
| Network | `logos.test` |

`info` is a good default log level: it shows startup, networking, and high-level node events without the volume of `debug` or `trace`.

Use `debug` when diagnosing behavior:

```bash
scripts/start-local-node.sh --log-level debug
```

Use `trace` only for detailed protocol/debug investigation because it can be noisy:

```bash
scripts/start-local-node.sh --log-level trace
```

Show all local-node options:

```bash
scripts/start-local-node.sh --help
```

The local node runs in the foreground. Press `Ctrl-C` to stop it.

## Test Helper

Show commands:

```bash
scripts/storage-test.sh --help
```

Defaults:

| Setting | Default |
|---|---|
| Remote SSH | `storage@172.235.163.25` |
| Remote API tunnel | `127.0.0.1:18080` |
| Local API | `127.0.0.1:8080` |
| CID state file | `~/.logos/storage/test/cids.log` |
| Generated test files | `~/.logos/storage/test/files/` |

`cids.log` is a simple upload history. Each upload appends the timestamp, target, returned CID, and source file path. It is useful when running frequent tests because you can recover old CIDs and delete them later without scrolling terminal history.

Recover the latest CID from the upload history:

```bash
scripts/storage-test.sh last-cid
scripts/storage-test.sh last-cid remote
```

## SSH Tunnel

Start the tunnel:

```bash
scripts/storage-test.sh tunnel start
```

Check it:

```bash
scripts/storage-test.sh tunnel status
```

Stop it:

```bash
scripts/storage-test.sh tunnel stop
```

You do not have to stop the tunnel after each test. It is safe to leave it running while you are actively testing. Stop it when you are done, when you want to free local port `18080`, or before changing tunnel settings.

Commands that target `remote` start the tunnel automatically if it is not already running.

## Typical Workflow

Terminal 1: start local node and watch logs.

```bash
scripts/start-local-node.sh --log-level info
```

Terminal 2: upload random content to the Linode node.

```bash
CID="$(scripts/storage-test.sh upload-random remote 10M)"
printf '%s\n' "$CID"
```

If you prefer copy/paste, you can also run the upload command directly and copy the printed CID:

```bash
scripts/storage-test.sh upload-random remote 10M
```

Recover it later from the upload history:

```bash
CID="$(scripts/storage-test.sh last-cid remote)"
```

Ask the local node to fetch and store the content from the network:

```bash
scripts/storage-test.sh fetch-local "$CID" --wait
```

Or stream the content through the local node without explicitly storing it first:

```bash
scripts/storage-test.sh stream-local "$CID" /tmp/logos-download.bin
```

Check local presence:

```bash
scripts/storage-test.sh exists local "$CID"
```

List local and remote CIDs:

```bash
scripts/storage-test.sh list local
scripts/storage-test.sh list remote
```

Delete by CID:

```bash
scripts/storage-test.sh delete local "$CID"
scripts/storage-test.sh delete remote "$CID"
```

Delete all local CIDs:

```bash
scripts/storage-test.sh delete-all local --yes
```

Delete all remote CIDs:

```bash
scripts/storage-test.sh delete-all remote --yes
```

## Useful API Endpoints

| Operation | Endpoint |
|---|---|
| Upload | `POST /api/storage/v1/data` |
| List local content | `GET /api/storage/v1/data` |
| Delete local content | `DELETE /api/storage/v1/data/{cid}` |
| Fetch from network into node | `POST /api/storage/v1/data/{cid}/network` |
| Fetch progress | `GET /api/storage/v1/data/{cid}/network/progress/{downloadId}` |
| Stream from network | `GET /api/storage/v1/data/{cid}/network/stream` |
| Local existence check | `GET /api/storage/v1/data/{cid}/exists` |
| Storage space | `GET /api/storage/v1/space` |

## Cleanup

Stop the local node with `Ctrl-C`.

Stop the SSH tunnel when finished:

```bash
scripts/storage-test.sh tunnel stop
```

Remove local test data if desired:

```bash
rm -rf ~/.logos/storage/local-node
rm -rf ~/.logos/storage/test
```
