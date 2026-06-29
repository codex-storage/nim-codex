# libstorage C++ CLI

This directory contains C++ tools around `library/libstorage.h`.

- `storage_lib_cli`: one-shot command-line wrapper.
- `storage_lib`: daemon-like libstorage process using Unix socket IPC.
- `storage_lib_ctl`: small client that sends one command to `storage_lib`.

Build libstorage first from the repository root:

```bash
make libstorage
```

If the local compiler hits the known secp256k1 `-march=native` issue on Linux amd64, use:

```bash
make libstorage NIMFLAGS="-d:disableMarchNative"
```

Then build the CLI:

```bash
cd tools/libstorage-cpp
make
```

`--timeout-ms 0` means wait indefinitely for libstorage async operations.

Examples:

```bash
./storage_lib_cli info
./storage_lib_cli spr
./storage_lib_cli debug
./storage_lib_cli list
./storage_lib_cli upload ./payload.txt
./storage_lib_cli --local download <cid> ./downloaded.txt
./storage_lib_cli --local roundtrip ./payload.txt ./payload.roundtrip
./storage_lib_cli --local repeat-roundtrip ./payload.txt ./payload.out 10
./storage_lib_cli upload-many ./payload.txt 10
./storage_lib_cli --local download-many <cid> ./payload.download 10
```

Options must come before the command. Some libstorage networking diagnostics are
currently printed directly by the library, so scripts should treat the final line
as the command result for commands such as `upload`.

Use `make clean` to remove the binary and the default data directory.

## Daemon Mode

Start the libstorage daemon:

```bash
./storage_lib \
  --socket ./storage_lib.sock \
  --data-dir ./storage-lib-data \
  --log-level WARN \
  --listen-port 8071 \
  --disc-port 8091 \
  --network logos.test \
  --timeout-ms 0
```

Send commands with `storage_lib_ctl`:

```bash
./storage_lib_ctl --socket ./storage_lib.sock info
./storage_lib_ctl --socket ./storage_lib.sock spr
./storage_lib_ctl --socket ./storage_lib.sock debug
./storage_lib_ctl --socket ./storage_lib.sock upload README.md
./storage_lib_ctl --socket ./storage_lib.sock manifest <cid>
./storage_lib_ctl --socket ./storage_lib.sock exists <cid>
./storage_lib_ctl --socket ./storage_lib.sock download <cid> ./downloaded.md true
./storage_lib_ctl --socket ./storage_lib.sock stream-sink <cid> false
./storage_lib_ctl --socket ./storage_lib.sock delete <cid>
./storage_lib_ctl --socket ./storage_lib.sock shutdown
```

If `--socket` is omitted, `storage_lib_ctl` uses `STORAGE_LIB_SOCKET` when set,
otherwise `~/.logos/storage/libstorage/storage_lib.sock`.

The IPC request protocol is one whitespace-separated command line per connection.
Paths with spaces are not supported yet. Responses are one JSON line:

```json
{"ok":true,"result":"..."}
```

or:

```json
{"ok":false,"error":"..."}
```

## Commands

- `info`: prints version, revision, repo, and peer id.
- `spr`: prints the node signed peer record.
- `debug`: prints debug JSON.
- `connect <peer-id> [addr...]`: connects to a peer using optional multiaddresses.
- `manifest <cid>`: prints manifest JSON.
- `delete <cid>`: deletes locally stored content.
- `fetch <cid>`: fetches content into the local store.
- `stream-sink <cid> [local]`: streams content and discards data, returning transferred bytes.
- `shutdown`: cleanly shuts down the node and stops the daemon.
- `roundtrip <in> <out>`: uploads one file, downloads it, compares bytes, and prints the cid.
- `repeat-roundtrip <in> <out-prefix> <count>`: repeats roundtrip in one node session.
- `upload-many <file> <count>`: uploads the same file repeatedly in one node session.
- `download-many <cid> <out-prefix> <count>`: downloads the same cid repeatedly in one node session.

Options must appear before the command, for example `--local roundtrip`, not
`roundtrip --local`.
