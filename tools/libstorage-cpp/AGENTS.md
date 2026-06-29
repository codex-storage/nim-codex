# Libstorage C++ Tooling Notes

This folder contains small C++ tools built on top of `library/libstorage.h`.

## Components

- `storage_client.hpp`: shared wrapper declarations and result structs.
- `storage_client.cpp`: shared wrapper implementation around the async libstorage C API.
- `storage_lib_cli.cpp`: one-shot command-line tool that starts a libstorage node, runs one command, and exits.
- `storage_lib.cpp`: long-running libstorage daemon with Unix socket IPC.
- `storage_lib_ctl.cpp`: control client that sends one IPC command to `storage_lib`.
- `Makefile`: builds `storage_lib_cli`, `storage_lib`, and `storage_lib_ctl` against `../../build/libstorage.so`.
- `README.md`: operator-facing usage notes.

`tools/storage-test/` consumes the daemon target through `storage_lib_ctl`.

## Build Notes

Build libstorage first. On the current AMD Ryzen AI 9 HX 370 machine, use:

```bash
make libstorage NIMFLAGS="-d:disableMarchNative"
```

This avoids the known GCC/secp256k1 x86_64 asm failure caused by `-march=native`.

Then build the C++ tools:

```bash
cd tools/libstorage-cpp
make
```

The Makefile links explicitly against `../../build/libstorage.so`. If only `libstorage.a` exists, build the shared library first with `make libstorage`.

## StorageClient Behavior

`StorageClient` wraps the async libstorage C API with blocking helper methods.

Important callback behavior:

- `RET_PROGRESS` is intermediate and must not complete a wait.
- `RET_OK` and `RET_ERR` are terminal.
- Callbacks run on libstorage worker context; keep callback logic fast and non-blocking.

Timeout behavior:

- Positive `timeout_ms` waits up to that duration.
- `timeout_ms == 0` waits indefinitely.

Follow the existing pattern of returning structured results instead of throwing. Keep the C++ wrapper small and direct.

## CLI vs Daemon Responsibilities

`storage_lib_cli` is for one-shot checks and manual experiments.

`storage_lib` is a primitive daemon that keeps one libstorage node alive across commands.

Keep daemon commands low-level:

- `info`
- `version`
- `revision`
- `repo`
- `peer-id`
- `spr`
- `debug`
- `metrics`
- `list`
- `space`
- `upload`
- `download`
- `exists`
- `delete`
- `fetch`
- `stream-sink`
- `manifest`
- `connect`
- `shutdown`
- `destroy`

Do not add scenario commands like `roundtrip`, `many`, or cross-target tests to the daemon unless explicitly requested. Put scenario orchestration in `tools/storage-test/storage-test.sh` so the same scenario can run against REST targets and the libstorage daemon target.

## Daemon IPC

`storage_lib` listens on a Unix domain socket.

Protocol:

- One client connection per command.
- Request is one whitespace-separated line.
- Response is one JSON line.
- Success shape: `{"ok":true,"result":"..."}`.
- Failure shape: `{"ok":false,"error":"..."}`.

The protocol currently does not support paths or arguments containing spaces. If that becomes important, prefer moving to JSON requests rather than adding ad-hoc escaping.

`storage_lib_ctl` socket resolution order:

1. `--socket <path>`
2. `STORAGE_LIB_SOCKET`
3. `~/.logos/storage/libstorage/storage_lib.sock`

`storage_lib_ctl` should return nonzero when the daemon responds with `"ok":false`.

Lifecycle IPC commands are daemon-level state controls over the libstorage C API:

- The daemon starts one libstorage node during process startup.
- `shutdown` and `destroy` are aliases; both call `StorageClient::shutdown()`, which uses `storage_shutdown()` to stop, close, and free the libstorage context before stopping the daemon loop.
- Do not expose lower-level `start`, `stop`, or `close` IPC commands; normal clients should use the daemon as running-until-shutdown.

`stream-sink <cid> [local]` uses released libstorage download primitives: `storage_download_init` followed by `storage_download_stream` with an empty output path. It discards progress bytes while counting transferred byte lengths and waits for terminal completion.

File paths sent over IPC are resolved by the daemon process. Callers that run from a different working directory, such as `tools/storage-test/storage-test.sh`, should send absolute paths.

## Daemon Options

Current daemon options include:

- `--data-dir`
- `--socket`
- `--log-level`
- `--listen-port`
- `--disc-port`
- `--network`
- `--chunk-size`
- `--timeout-ms`

Use a distinct data directory from any running standard storage node to avoid datastore locking conflicts.

Default libstorage daemon paths used by storage-test tooling:

- Data dir: `~/.logos/storage/libstorage/node`
- Socket: `~/.logos/storage/libstorage/storage_lib.sock`

## Verification

Lightweight build and smoke-check flow:

```bash
make libstorage NIMFLAGS="-d:disableMarchNative"
cd tools/libstorage-cpp
make
```

Run daemon from repo root or with absolute paths:

```bash
tools/libstorage-cpp/storage_lib --data-dir /tmp/storage-lib-data --socket /tmp/storage-lib.sock --log-level FATAL --timeout-ms 0
```

In another shell:

```bash
tools/libstorage-cpp/storage_lib_ctl --socket /tmp/storage-lib.sock info
tools/libstorage-cpp/storage_lib_ctl --socket /tmp/storage-lib.sock peer-id
tools/libstorage-cpp/storage_lib_ctl --socket /tmp/storage-lib.sock shutdown
```

Storage-test integration smoke checks:

```bash
tools/storage-test/start-local-node.sh --client lib --data-dir /tmp/storage-lib-data --socket /tmp/storage-lib.sock --log-level FATAL --timeout-ms 0
STORAGE_LIB_SOCKET=/tmp/storage-lib.sock tools/storage-test/storage-test.sh lib peerid
STORAGE_LIB_SOCKET=/tmp/storage-lib.sock tools/libstorage-cpp/storage_lib_ctl shutdown
```

Full `tools/storage-test/storage-test.sh lib test` contacts the configured remote Linode and performs real uploads/downloads. Run it deliberately.

## Style Guidance

- Keep the wrapper minimal and boring.
- Prefer small local functions over broad abstractions.
- Do not add backward-compatible command aliases unless there is an explicit need.
- Keep scenario logic out of `storage_lib`.
- Preserve JSON responses for daemon IPC so shell scripts can parse success/failure reliably.
- Avoid blocking work in libstorage callbacks.
