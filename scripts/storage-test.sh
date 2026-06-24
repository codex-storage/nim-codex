#!/usr/bin/env bash
set -euo pipefail

REMOTE_SSH_HOST="${REMOTE_SSH_HOST:-storage@172.235.163.25}"
REMOTE_API_PORT="${REMOTE_API_PORT:-18080}"
LOCAL_API_PORT="${LOCAL_API_PORT:-8080}"
TUNNEL_CONTROL_PATH="${TUNNEL_CONTROL_PATH:-/tmp/logos-storage-tunnel-${USER:-user}.ctl}"
CID_STATE_FILE="${CID_STATE_FILE:-${HOME}/.logos/storage/test/cids.log}"
TEST_FILES_DIR="${TEST_FILES_DIR:-${HOME}/.logos/storage/test/files}"

LOCAL_API="http://127.0.0.1:${LOCAL_API_PORT}/api/storage/v1"
REMOTE_API="http://127.0.0.1:${REMOTE_API_PORT}/api/storage/v1"

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Environment:
  REMOTE_SSH_HOST       SSH host for the remote node [$REMOTE_SSH_HOST]
  REMOTE_API_PORT       Local tunnel port for remote API [$REMOTE_API_PORT]
  LOCAL_API_PORT        Local node API port [$LOCAL_API_PORT]
  TUNNEL_CONTROL_PATH   SSH control socket path [$TUNNEL_CONTROL_PATH]
  CID_STATE_FILE        Upload history log [$CID_STATE_FILE]
  TEST_FILES_DIR        Default generated test file directory [$TEST_FILES_DIR]

Targets:
  local                 API at $LOCAL_API
  remote                API through SSH tunnel at $REMOTE_API

Commands:
  help
      Show this help.

  tunnel start|stop|status
      Manage SSH tunnel to the remote node API.

  make-file <size> [output-file]
      Create random content with dd. Example: make-file 10M /tmp/logos-10M.bin

  upload <target> <file>
      Upload a file to target node and print the returned CID. Appends CID to
      CID_STATE_FILE. Example: upload remote /tmp/logos-10M.bin

  upload-random <target> <size> [--keep]
      Create a temporary random file, upload it, print CID. Deletes temp file
      unless --keep is passed. Example: upload-random remote 10M

  last-cid [target]
      Print the most recent CID from CID_STATE_FILE, optionally filtered by
      target.

  list <target>
      List manifest CIDs stored locally by target node.

  delete <target> <cid>
      Delete CID from target node local storage.

  delete-all <target> --yes
      Delete every CID returned by list from target node local storage.

  exists <target> <cid>
      Check whether target node has CID locally.

  space <target>
      Show target node storage space information.

  peerid <target>
      Show target node peer ID.

  fetch-local <cid> [--wait]
      Ask local node to fetch CID from the network. With --wait, poll progress
      until the background download is inactive or complete.

  stream-local <cid> <output-file>
      Stream CID from the network through local node into output-file.

Examples:
  $0 tunnel start
  $0 upload-random remote 10M
  $0 fetch-local <CID> --wait
  $0 stream-local <CID> /tmp/downloaded.bin
  $0 delete remote <CID>
  $0 delete-all local --yes
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

check_common_deps() {
  need curl
  need jq
}

tunnel_status() {
  ssh -S "$TUNNEL_CONTROL_PATH" -O check "$REMOTE_SSH_HOST" >/dev/null 2>&1
}

tunnel_start() {
  need ssh
  if tunnel_status; then
    printf 'tunnel already running: 127.0.0.1:%s -> %s:127.0.0.1:8080\n' \
      "$REMOTE_API_PORT" "$REMOTE_SSH_HOST"
    return 0
  fi

  ssh \
    -M \
    -S "$TUNNEL_CONTROL_PATH" \
    -fN \
    -L "127.0.0.1:${REMOTE_API_PORT}:127.0.0.1:8080" \
    "$REMOTE_SSH_HOST"

  printf 'started tunnel: 127.0.0.1:%s -> %s:127.0.0.1:8080\n' \
    "$REMOTE_API_PORT" "$REMOTE_SSH_HOST"
}

tunnel_stop() {
  need ssh
  if tunnel_status; then
    ssh -S "$TUNNEL_CONTROL_PATH" -O exit "$REMOTE_SSH_HOST" >/dev/null
    printf 'stopped tunnel\n'
  else
    printf 'tunnel not running\n'
  fi
}

target_api() {
  case "${1:-}" in
    local)
      printf '%s\n' "$LOCAL_API"
      ;;
    remote)
      tunnel_start >/dev/null
      printf '%s\n' "$REMOTE_API"
      ;;
    *)
      die "target must be 'local' or 'remote'"
      ;;
  esac
}

make_file() {
  local size="${1:-}"
  local out="${2:-}"
  [[ -n "$size" ]] || die 'make-file requires <size>'
  if [[ -z "$out" ]]; then
    mkdir -p "$TEST_FILES_DIR"
    out="${TEST_FILES_DIR}/logos-test-${size}-$(date -u +%Y%m%dT%H%M%SZ).bin"
  fi
  dd if=/dev/urandom of="$out" bs="$size" count=1 status=progress
  printf '%s\n' "$out"
}

upload_file() {
  check_common_deps
  local target="${1:-}"
  local file="${2:-}"
  [[ -n "$file" ]] || die 'upload requires <target> <file>'
  [[ -f "$file" ]] || die "file not found: $file"
  [[ -z "${3:-}" ]] || die 'upload does not accept extra options'

  local api cid
  api="$(target_api "$target")"
  cid="$(curl -fsS \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@${file}" \
    "${api}/data")"

  printf '%s\n' "$cid"
  mkdir -p "$(dirname "$CID_STATE_FILE")"
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" "$cid" "$file" >> "$CID_STATE_FILE"
}

upload_random() {
  local target="${1:-}"
  local size="${2:-}"
  local keep=false
  [[ -n "$target" && -n "$size" ]] || die 'upload-random requires <target> <size> [--keep]'

  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep)
        keep=true
        ;;
      *)
        die "unknown upload-random option: $1"
        ;;
    esac
    shift
  done

  local tmp cid
  tmp="$(mktemp "${TMPDIR:-/tmp}/logos-storage-test.XXXXXX")"
  dd if=/dev/urandom of="$tmp" bs="$size" count=1 status=progress >&2
  cid="$(upload_file "$target" "$tmp")"
  printf '%s\n' "$cid"

  if [[ "$keep" == true ]]; then
    printf 'kept file: %s\n' "$tmp" >&2
  else
    rm -f "$tmp"
  fi
}

last_cid() {
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      local|remote)
        [[ -z "$target" ]] || die 'target specified more than once'
        target="$1"
        ;;
      *)
        die "unknown last-cid option: $1"
        ;;
    esac
    shift
  done

  [[ -f "$CID_STATE_FILE" ]] || die "CID state file not found: $CID_STATE_FILE"

  local cid
  if [[ -n "$target" ]]; then
    cid="$(awk -v target="$target" '$2 == target { cid = $3 } END { print cid }' "$CID_STATE_FILE")"
  else
    cid="$(awk 'NF >= 3 { cid = $3 } END { print cid }' "$CID_STATE_FILE")"
  fi

  [[ -n "$cid" ]] || die 'no matching CID found'
  printf '%s\n' "$cid"
}

list_cids() {
  check_common_deps
  local api
  api="$(target_api "${1:-}")"
  curl -fsS "${api}/data" | jq -r '.content[]?.cid'
}

delete_cid() {
  check_common_deps
  local target="${1:-}"
  local cid="${2:-}"
  [[ -n "$cid" ]] || die 'delete requires <target> <cid>'
  local api
  api="$(target_api "$target")"
  curl -fsS -X DELETE "${api}/data/${cid}" >/dev/null
  printf 'deleted %s from %s\n' "$cid" "$target"
}

delete_all() {
  local target="${1:-}"
  local yes="${2:-}"
  [[ "$yes" == '--yes' ]] || die 'delete-all requires --yes'

  local cid count=0
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    delete_cid "$target" "$cid"
    count=$((count + 1))
  done < <(list_cids "$target")
  printf 'deleted %d CID(s) from %s\n' "$count" "$target"
}

simple_get() {
  check_common_deps
  local target="${1:-}"
  local path="${2:-}"
  local api
  api="$(target_api "$target")"
  curl -fsS "${api}/${path}"
  printf '\n'
}

exists_cid() {
  local target="${1:-}"
  local cid="${2:-}"
  [[ -n "$cid" ]] || die 'exists requires <target> <cid>'
  simple_get "$target" "data/${cid}/exists"
}

fetch_local() {
  check_common_deps
  local cid="${1:-}"
  local wait="${2:-}"
  [[ -n "$cid" ]] || die 'fetch-local requires <cid> [--wait]'
  [[ -z "$wait" || "$wait" == '--wait' ]] || die 'only supported option is --wait'

  local response download_id
  response="$(curl -fsS -X POST "${LOCAL_API}/data/${cid}/network")"
  printf '%s\n' "$response" | jq .

  if [[ "$wait" != '--wait' ]]; then
    return 0
  fi

  download_id="$(printf '%s\n' "$response" | jq -r '.downloadId // empty')"
  [[ -n "$download_id" ]] || die 'response did not contain downloadId'

  while true; do
    local progress active received total
    progress="$(curl -fsS "${LOCAL_API}/data/${cid}/network/progress/${download_id}")"
    printf '%s\n' "$progress" | jq .
    active="$(printf '%s\n' "$progress" | jq -r '.active')"
    received="$(printf '%s\n' "$progress" | jq -r '.received // 0')"
    total="$(printf '%s\n' "$progress" | jq -r '.total // 0')"
    if [[ "$active" != 'true' || ( "$total" != '0' && "$received" == "$total" ) ]]; then
      break
    fi
    sleep 2
  done
}

stream_local() {
  local cid="${1:-}"
  local out="${2:-}"
  [[ -n "$cid" && -n "$out" ]] || die 'stream-local requires <cid> <output-file>'
  curl -fL "${LOCAL_API}/data/${cid}/network/stream" -o "$out"
  printf '%s\n' "$out"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  help|--help|-h)
    usage
    ;;
  tunnel)
    case "${1:-}" in
      start) tunnel_start ;;
      stop) tunnel_stop ;;
      status)
        if tunnel_status; then
          printf 'tunnel running\n'
        else
          printf 'tunnel stopped\n'
          exit 1
        fi
        ;;
      *) die 'usage: tunnel start|stop|status' ;;
    esac
    ;;
  make-file) make_file "$@" ;;
  upload) upload_file "$@" ;;
  upload-random) upload_random "$@" ;;
  last-cid) last_cid "$@" ;;
  list) list_cids "$@" ;;
  delete) delete_cid "$@" ;;
  delete-all) delete_all "$@" ;;
  exists) exists_cid "$@" ;;
  space) simple_get "${1:-}" 'space' ;;
  peerid) simple_get "${1:-}" 'peerid' ;;
  fetch-local) fetch_local "$@" ;;
  stream-local) stream_local "$@" ;;
  *)
    usage >&2
    exit 1
    ;;
esac
