#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CLIENT="${STORAGE_CLIENT:-storage}"
BINARY="${STORAGE_BINARY:-${ROOT_DIR}/build/storage}"
LIB_BINARY="${STORAGE_LIB_BINARY:-${ROOT_DIR}/tools/libstorage-cpp/storage_lib}"
STORAGE_DATA_DIR_DEFAULT="${HOME}/.logos/storage/local-node"
LIB_DATA_DIR_DEFAULT="${HOME}/.logos/storage/libstorage/node"
DATA_DIR="${STORAGE_DATA_DIR:-}"
LOG_LEVEL="${STORAGE_LOG_LEVEL:-info}"
LISTEN_PORT="${STORAGE_LISTEN_PORT:-8071}"
DISC_PORT="${STORAGE_DISC_PORT:-8091}"
API_BINDADDR="${STORAGE_API_BINDADDR:-127.0.0.1}"
API_PORT="${STORAGE_API_PORT:-8080}"
NETWORK="${STORAGE_NETWORK:-logos.test}"
LIB_SOCKET="${STORAGE_LIB_SOCKET:-${HOME}/.logos/storage/libstorage/storage_lib.sock}"
LIB_TIMEOUT_MS="${STORAGE_LIB_TIMEOUT_MS:-0}"
LIB_CHUNK_SIZE="${STORAGE_LIB_CHUNK_SIZE:-65536}"
CONFIG_SOURCE="${STORAGE_CONFIG:-${HOME}/.logos/storage}"
CONFIG_FILE=""

usage() {
  cat <<EOF
Usage: $0 [options] [-- extra args]

Start a local Logos Storage node in the foreground so logs are visible.

Options:
  --client <name>       Client to launch: storage or lib [$CLIENT]
  --binary <path>       Storage binary [$BINARY]
  --lib-binary <path>   Libstorage daemon binary [$LIB_BINARY]
  --data-dir <path>     Data directory [storage: $STORAGE_DATA_DIR_DEFAULT, lib: $LIB_DATA_DIR_DEFAULT]
  --log-level <level>   Log level: trace, debug, info, notice, warn, error [$LOG_LEVEL]
  --listen-port <port>  Local libp2p TCP listen port [$LISTEN_PORT]
  --disc-port <port>    Local discovery UDP port [$DISC_PORT]
  --api-bindaddr <ip>   REST API bind address [$API_BINDADDR]
  --api-port <port>     REST API port [$API_PORT]
  --network <name>      Network preset [$NETWORK]
  --config <path>       Config file or directory [$CONFIG_SOURCE]
  --socket <path>       Libstorage Unix socket [$LIB_SOCKET]
  --timeout-ms <ms>     Libstorage async timeout, 0 waits forever [$LIB_TIMEOUT_MS]
  --chunk-size <bytes>  Libstorage upload/download chunk size [$LIB_CHUNK_SIZE]
  -h, --help            Show this help.

Environment overrides:
  STORAGE_CLIENT, STORAGE_BINARY, STORAGE_LIB_BINARY, STORAGE_DATA_DIR,
  STORAGE_LOG_LEVEL, STORAGE_LISTEN_PORT, STORAGE_DISC_PORT, STORAGE_API_BINDADDR,
  STORAGE_API_PORT, STORAGE_NETWORK, STORAGE_LIB_SOCKET, STORAGE_LIB_TIMEOUT_MS,
  STORAGE_LIB_CHUNK_SIZE, STORAGE_CONFIG

Examples:
  $0
  $0 --client lib
  $0 --log-level debug
  $0 --data-dir /tmp/logos-storage-local --listen-port 8072 --disc-port 8092
  $0 --log-level trace -- --metrics --metrics-address=127.0.0.1

The node runs in the foreground. Press Ctrl-C to stop it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)
      CLIENT="${2:-}"
      shift 2
      ;;
    --binary)
      BINARY="${2:-}"
      shift 2
      ;;
    --lib-binary)
      LIB_BINARY="${2:-}"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="${2:-}"
      shift 2
      ;;
    --log-level)
      LOG_LEVEL="${2:-}"
      shift 2
      ;;
    --listen-port)
      LISTEN_PORT="${2:-}"
      shift 2
      ;;
    --disc-port)
      DISC_PORT="${2:-}"
      shift 2
      ;;
    --api-bindaddr)
      API_BINDADDR="${2:-}"
      shift 2
      ;;
    --api-port)
      API_PORT="${2:-}"
      shift 2
      ;;
    --network)
      NETWORK="${2:-}"
      shift 2
      ;;
    --config)
      CONFIG_SOURCE="${2:-}"
      shift 2
      ;;
    --socket)
      LIB_SOCKET="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      LIB_TIMEOUT_MS="${2:-}"
      shift 2
      ;;
    --chunk-size)
      LIB_CHUNK_SIZE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'error: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$CLIENT" in
  storage|lib) ;;
  *) printf 'error: --client must be storage or lib\n' >&2; exit 1 ;;
esac

resolve_config_file() {
  local source="$1"
  local name

  [[ -n "$source" ]] || return 0

  if [[ "$CLIENT" == 'storage' ]]; then
    name='config.toml'
  else
    name='config.json'
  fi

  if [[ -f "$source" ]]; then
    CONFIG_FILE="$source"
  elif [[ -d "$source" && -f "$source/$name" ]]; then
    CONFIG_FILE="$source/$name"
  fi
}

resolve_config_file "$CONFIG_SOURCE"

if [[ -z "$DATA_DIR" ]]; then
  if [[ "$CLIENT" == 'lib' ]]; then
    DATA_DIR="$LIB_DATA_DIR_DEFAULT"
  else
    DATA_DIR="$STORAGE_DATA_DIR_DEFAULT"
  fi
fi

if [[ "$CLIENT" == 'storage' ]]; then
  [[ -n "$BINARY" ]] || { printf 'error: --binary cannot be empty\n' >&2; exit 1; }
  [[ -x "$BINARY" ]] || { printf 'error: storage binary not executable: %s\n' "$BINARY" >&2; exit 1; }
else
  [[ -n "$LIB_BINARY" ]] || { printf 'error: --lib-binary cannot be empty\n' >&2; exit 1; }
  [[ -x "$LIB_BINARY" ]] || { printf 'error: libstorage daemon binary not executable: %s\n' "$LIB_BINARY" >&2; exit 1; }
fi

if [[ -z "$CONFIG_FILE" ]]; then
  mkdir -p "$DATA_DIR"
fi

printf 'Starting local Logos Storage node\n'
printf '  client:      %s\n' "$CLIENT"
if [[ "$CLIENT" == 'storage' ]]; then
  printf '  binary:      %s\n' "$BINARY"
else
  printf '  binary:      %s\n' "$LIB_BINARY"
fi
if [[ -n "$CONFIG_FILE" ]]; then
  printf '  config:      %s\n' "$CONFIG_FILE"
else
  printf '  data dir:    %s\n' "$DATA_DIR"
  printf '  log level:   %s\n' "$LOG_LEVEL"
  printf '  listen TCP:  %s\n' "$LISTEN_PORT"
  printf '  discovery:   %s/udp\n' "$DISC_PORT"
  printf '  network:     %s\n' "$NETWORK"
fi
if [[ "$CLIENT" == 'storage' ]]; then
  if [[ -z "$CONFIG_FILE" ]]; then
    printf '  REST API:    %s:%s\n' "$API_BINDADDR" "$API_PORT"
  fi
else
  printf '  socket:      %s\n' "$LIB_SOCKET"
  printf '  timeout ms:  %s\n' "$LIB_TIMEOUT_MS"
  printf '  chunk size:  %s\n' "$LIB_CHUNK_SIZE"
fi
printf '\n'

if [[ "$CLIENT" == 'storage' ]]; then
  if [[ -n "$CONFIG_FILE" ]]; then
    exec "$BINARY" --config-file="$CONFIG_FILE" "$@"
  fi

  exec "$BINARY" \
    --data-dir="$DATA_DIR" \
    --log-level="$LOG_LEVEL" \
    --listen-port="$LISTEN_PORT" \
    --disc-port="$DISC_PORT" \
    --api-bindaddr="$API_BINDADDR" \
    --api-port="$API_PORT" \
    --network="$NETWORK" \
    "$@"
fi

if [[ -n "$CONFIG_FILE" ]]; then
  exec "$LIB_BINARY" \
    --config-file "$CONFIG_FILE" \
    --socket "$LIB_SOCKET" \
    --timeout-ms "$LIB_TIMEOUT_MS" \
    --chunk-size "$LIB_CHUNK_SIZE" \
    "$@"
fi

exec "$LIB_BINARY" \
  --data-dir "$DATA_DIR" \
  --log-level "$LOG_LEVEL" \
  --listen-port "$LISTEN_PORT" \
  --disc-port "$DISC_PORT" \
  --network "$NETWORK" \
  --socket "$LIB_SOCKET" \
  --timeout-ms "$LIB_TIMEOUT_MS" \
  --chunk-size "$LIB_CHUNK_SIZE" \
  "$@"
