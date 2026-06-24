#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BINARY="${STORAGE_BINARY:-${ROOT_DIR}/build/storage}"
DATA_DIR="${STORAGE_DATA_DIR:-${HOME}/.logos/storage/local-node}"
LOG_LEVEL="${STORAGE_LOG_LEVEL:-info}"
LISTEN_PORT="${STORAGE_LISTEN_PORT:-8071}"
DISC_PORT="${STORAGE_DISC_PORT:-8091}"
API_BINDADDR="${STORAGE_API_BINDADDR:-127.0.0.1}"
API_PORT="${STORAGE_API_PORT:-8080}"
NETWORK="${STORAGE_NETWORK:-logos.test}"

usage() {
  cat <<EOF
Usage: $0 [options] [-- extra storage args]

Start a local Logos Storage node in the foreground so logs are visible.

Options:
  --binary <path>       Storage binary [$BINARY]
  --data-dir <path>     Data directory [$DATA_DIR]
  --log-level <level>   Log level: trace, debug, info, notice, warn, error [$LOG_LEVEL]
  --listen-port <port>  Local libp2p TCP listen port [$LISTEN_PORT]
  --disc-port <port>    Local discovery UDP port [$DISC_PORT]
  --api-bindaddr <ip>   REST API bind address [$API_BINDADDR]
  --api-port <port>     REST API port [$API_PORT]
  --network <name>      Network preset [$NETWORK]
  -h, --help            Show this help.

Environment overrides:
  STORAGE_BINARY, STORAGE_DATA_DIR, STORAGE_LOG_LEVEL, STORAGE_LISTEN_PORT,
  STORAGE_DISC_PORT, STORAGE_API_BINDADDR, STORAGE_API_PORT, STORAGE_NETWORK

Examples:
  $0
  $0 --log-level debug
  $0 --data-dir /tmp/logos-storage-local --listen-port 8072 --disc-port 8092
  $0 --log-level trace -- --metrics --metrics-address=127.0.0.1

The node runs in the foreground. Press Ctrl-C to stop it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY="${2:-}"
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

[[ -n "$BINARY" ]] || { printf 'error: --binary cannot be empty\n' >&2; exit 1; }
[[ -x "$BINARY" ]] || { printf 'error: storage binary not executable: %s\n' "$BINARY" >&2; exit 1; }

mkdir -p "$DATA_DIR"

printf 'Starting local Logos Storage node\n'
printf '  binary:      %s\n' "$BINARY"
printf '  data dir:    %s\n' "$DATA_DIR"
printf '  log level:   %s\n' "$LOG_LEVEL"
printf '  listen TCP:  %s\n' "$LISTEN_PORT"
printf '  discovery:   %s/udp\n' "$DISC_PORT"
printf '  REST API:    %s:%s\n' "$API_BINDADDR" "$API_PORT"
printf '  network:     %s\n' "$NETWORK"
printf '\n'

exec "$BINARY" \
  --data-dir="$DATA_DIR" \
  --log-level="$LOG_LEVEL" \
  --listen-port="$LISTEN_PORT" \
  --disc-port="$DISC_PORT" \
  --api-bindaddr="$API_BINDADDR" \
  --api-port="$API_PORT" \
  --network="$NETWORK" \
  "$@"
