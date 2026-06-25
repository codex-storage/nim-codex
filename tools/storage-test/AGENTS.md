# Storage Test Tooling Notes

This folder contains local/Linode test helpers for comparing the standard REST node with the libstorage C++ daemon target.

## Current Layout

- `start-local-node.sh`: foreground launcher for either the standard storage binary or the libstorage daemon.
- `storage-test.sh`: target-first test helper for local REST, remote REST, and libstorage daemon targets.
- `README.md`: operator-facing usage guide.
- `SETUP_STORAGE_NODE.md`: Linode/headless node setup recipe.

Related C++ libstorage tools live in `../libstorage-cpp/`:

- `storage_client.hpp` / `storage_client.cpp`: shared C++ wrapper around `library/libstorage.h`.
- `storage_lib_cli`: one-shot libstorage CLI.
- `storage_lib`: daemon-like libstorage process using Unix socket IPC.
- `storage_lib_ctl`: control client that sends one command to `storage_lib`.

## Build Notes

On the current AMD Ryzen AI 9 HX 370 machine, local Nim builds should use:

```bash
make NIMFLAGS="-d:disableMarchNative"
make libstorage NIMFLAGS="-d:disableMarchNative"
```

This avoids the known GCC/secp256k1 x86_64 asm failure caused by `-march=native`.

Build libstorage C++ tools with:

```bash
cd tools/libstorage-cpp
make
```

Generated C++ binaries, daemon data dirs, sockets, logs, and report files are ignored/cleaned by the relevant Makefile or `.gitignore` entries.

## Launcher Model

`start-local-node.sh` supports two clients:

```bash
tools/storage-test/start-local-node.sh --client storage
tools/storage-test/start-local-node.sh --client lib
```

Shared config between both clients:

- `--data-dir`
- `--log-level`
- `--listen-port`
- `--disc-port`
- `--network`

Standard storage-only config:

- `--binary`
- `--api-bindaddr`
- `--api-port`

Lib daemon-only config:

- `--lib-binary`
- `--socket`
- `--timeout-ms`
- `--chunk-size`

Default data dirs intentionally differ to avoid datastore locking conflicts:

- Standard REST node: `~/.logos/storage/local-node`
- Libstorage daemon: `~/.logos/storage/libstorage/node`

## storage-test.sh Command Model

The script is target-first. Do not reintroduce command-first compatibility unless explicitly requested.

```bash
tools/storage-test/storage-test.sh <target> <command> [args]
```

Targets:

- `local`: local standard REST node at `127.0.0.1:${LOCAL_API_PORT}`.
- `remote`: Linode REST node through SSH tunnel at `127.0.0.1:${REMOTE_API_PORT}`.
- `lib`: local `storage_lib` daemon through `storage_lib_ctl` and Unix socket.

Global commands remain targetless:

- `help`
- `tunnel start|stop|status`
- `make-file`
- `last-cid [target]`

Common target commands:

- `upload <file>`
- `upload-random <size> [--keep]`
- `download <cid> <output-file> [--local]`
- `fetch <cid> [--wait]`
- `stream-sink <cid> [--local]`
- `list`
- `delete <cid>`
- `delete-all --yes`
- `exists <cid>`
- `space`
- `peerid`
- `test`

Lib-only target commands:

- `spr`
- `debug`
- `manifest <cid>`
- `connect <peer-id> [addr...]`

## Lib Target Details

`storage-test.sh lib` invokes `storage_lib_ctl`. Socket resolution for `storage_lib_ctl` is:

1. `--socket <path>`
2. `STORAGE_LIB_SOCKET`
3. `~/.logos/storage/libstorage/storage_lib.sock`

`storage-test.sh` passes `--socket "$STORAGE_LIB_SOCKET"` explicitly.

The daemon IPC protocol is intentionally simple:

- Request: one whitespace-separated command line per connection.
- Response: one JSON line like `{"ok":true,"result":"..."}` or `{"ok":false,"error":"..."}`.
- Paths with spaces are not supported yet.

Important: lib daemon file paths are resolved in the daemon process working directory. `storage-test.sh` converts upload/download paths to absolute paths before sending them to `storage_lib_ctl`.

`--timeout-ms 0` means wait indefinitely in libstorage C++ tooling.

## Test Scenario

`storage-test.sh <local|lib> test` currently runs the remote-to-local scenario:

1. Generate random files with sizes from `TEST_FILE_SIZES`.
2. Upload each file to the `remote` Linode REST node.
3. Measure manifest resolution through selected target.
4. Measure network stream-to-sink through selected target.
5. Measure local-only write through selected target.
6. Validate SHA-256 of source and downloaded file.
7. Delete involved CIDs from the selected local target and `remote`.
8. Remove temp workspace unless `TEST_KEEP_FILES=1`.
9. Write a Markdown report in the caller's current directory: `./report-YYYY-MM-DD_HH-MM-SS.md`.

Defaults:

- `TEST_FILE_SIZES="4K 1M 10M"`
- `TEST_KEEP_FILES=0`
- Max per-file test size is 10 MB.

The report includes timestamps, duration, target, file size list, workspace path, per-file CID/hash/path details, manifest time, network stream time/speed, local write time/speed, total time/speed, and cleanup results. `report-*.md` is ignored by the root `.gitignore`.

The metrics flow intentionally mirrors storage-module/UI primitives while splitting work for more detail. REST local uses `/network/manifest`, `/network/stream` to `/dev/null`, then local-only `/data/{cid}`. Lib uses daemon `manifest`, `stream-sink`, then local-only `download`.

## Verification Commands

Use lightweight checks before/after edits:

```bash
bash -n tools/storage-test/storage-test.sh
bash -n tools/storage-test/start-local-node.sh
tools/storage-test/storage-test.sh --help
tools/storage-test/start-local-node.sh --help
```

For lib daemon smoke tests:

```bash
cd tools/libstorage-cpp
make storage_lib storage_lib_ctl
cd ../..
tools/storage-test/start-local-node.sh --client lib --data-dir /tmp/storage-lib-data --socket /tmp/storage-lib.sock --log-level FATAL --timeout-ms 0
```

In another shell:

```bash
STORAGE_LIB_SOCKET=/tmp/storage-lib.sock tools/storage-test/storage-test.sh lib peerid
STORAGE_LIB_SOCKET=/tmp/storage-lib.sock tools/libstorage-cpp/storage_lib_ctl shutdown
```

Full `local test` and `lib test` contact the Linode remote and perform real uploads/downloads; run them deliberately.

## Future Work

- Add reverse scenario: selected local/lib target uploads, remote downloads/fetches, validates hashes, and cleans up.
- Consider changing daemon IPC to JSON requests if argument quoting or paths with spaces become important.
- Keep long-running/scenario behavior in `storage-test.sh`, not in the daemon, so scenarios can run against all targets.
