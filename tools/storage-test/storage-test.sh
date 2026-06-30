#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

REMOTE_SSH_HOST="${REMOTE_SSH_HOST:-storage@172.235.163.25}"
REMOTE_API_PORT="${REMOTE_API_PORT:-18080}"
LOCAL_API_PORT="${LOCAL_API_PORT:-8080}"
TUNNEL_CONTROL_PATH="${TUNNEL_CONTROL_PATH:-/tmp/logos-storage-tunnel-${USER:-user}.ctl}"
CID_STATE_FILE="${CID_STATE_FILE:-${HOME}/.logos/storage/test/cids.log}"
TEST_FILES_DIR="${TEST_FILES_DIR:-${HOME}/.logos/storage/test/files}"
TEST_FILE_SIZES="${TEST_FILE_SIZES:-4K 1M 10M}"
TEST_KEEP_FILES="${TEST_KEEP_FILES:-0}"
STORAGE_LIB_CTL="${STORAGE_LIB_CTL:-${ROOT_DIR}/tools/libstorage-cpp/storage_lib_ctl}"
STORAGE_LIB_SOCKET="${STORAGE_LIB_SOCKET:-${HOME}/.logos/storage/libstorage/storage_lib.sock}"

LOCAL_API="http://127.0.0.1:${LOCAL_API_PORT}/api/storage/v1"
REMOTE_API="http://127.0.0.1:${REMOTE_API_PORT}/api/storage/v1"

usage() {
  cat <<EOF
Usage: $0 <target> <command> [args]
       $0 <global-command> [args]

Targets:
  local                 Local REST node at $LOCAL_API
  remote                Remote REST node through SSH tunnel at $REMOTE_API
  lib                   Local storage_lib daemon via Unix socket

Target commands:
  <target> upload <file>
      Upload a file and print the returned CID.

  <target> upload-random <size> [--keep]
      Create random content, upload it, print CID.

  <target> download <cid> <output-file> [--local]
      Download CID into output-file. For lib, --local means local store only.

  <target> fetch <cid> [--wait]
      Fetch CID from network into target local store. --wait is REST-only.

  <target> stream-sink <cid> [--local]
      Stream CID and discard data. Used by test metrics.

  <target> list
      List manifest CIDs stored locally by target.

  <target> delete <cid>
      Delete CID from target local storage.

  <target> delete-all --yes
      Delete every CID returned by list from target local storage.

  <target> exists <cid>
      Check whether target has CID locally.

  <target> space
      Show target storage space information.

  <target> peerid
      Show target peer ID.

  <target> test
      Upload random files to remote, measure manifest/network-stream/local-write,
      validate hashes, and clean up involved CIDs. Supported targets: local, lib.

Lib-only target commands:
  lib spr
  lib debug
  lib peers
  lib manifest <cid>
  lib connect <peer-id> [addr...]

Global commands:
  help
      Show this help.

  tunnel start|stop|status
      Manage SSH tunnel to the remote REST API.

  make-file <size> [output-file]
      Create random content with dd. Example: make-file 10M /tmp/logos-10M.bin

  last-cid [target]
      Print the most recent CID from CID_STATE_FILE, optionally filtered by target.

Environment:
  REMOTE_SSH_HOST       SSH host for the remote node [$REMOTE_SSH_HOST]
  REMOTE_API_PORT       Local tunnel port for remote API [$REMOTE_API_PORT]
  LOCAL_API_PORT        Local node API port [$LOCAL_API_PORT]
  STORAGE_LIB_CTL       Path to storage_lib_ctl [$STORAGE_LIB_CTL]
  STORAGE_LIB_SOCKET    Unix socket for storage_lib [$STORAGE_LIB_SOCKET]
  CID_STATE_FILE        Upload history log [$CID_STATE_FILE]
  TEST_FILES_DIR        Generated test file directory [$TEST_FILES_DIR]
  TEST_FILE_SIZES       Sizes used by '<target> test' [$TEST_FILE_SIZES]
  TEST_KEEP_FILES       Keep test workspace when set to 1 [$TEST_KEEP_FILES]

Examples:
  $0 tunnel start
  $0 remote upload-random 10M
  $0 local fetch <CID> --wait
  $0 local download <CID> /tmp/downloaded.bin
  $0 lib download <CID> /tmp/downloaded.bin
  $0 lib test
  $0 local test
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

is_target() {
  case "${1:-}" in
    local|remote|lib) return 0 ;;
    *) return 1 ;;
  esac
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
      die "REST target must be 'local' or 'remote'"
      ;;
  esac
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

record_cid() {
  local target="$1"
  local cid="$2"
  local file="$3"
  mkdir -p "$(dirname "$CID_STATE_FILE")"
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$target" "$cid" "$file" >> "$CID_STATE_FILE"
}

last_cid() {
  local target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      local|remote|lib)
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

lib_ctl_raw() {
  [[ -x "$STORAGE_LIB_CTL" ]] || die "storage_lib_ctl not executable: $STORAGE_LIB_CTL"
  "$STORAGE_LIB_CTL" --socket "$STORAGE_LIB_SOCKET" "$@"
}

lib_result() {
  check_common_deps
  local response
  response="$(lib_ctl_raw "$@")"
  if ! printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null; then
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s\n' "$response" | jq -r '.result'
}

abs_existing_path() {
  local path="$1"
  [[ -e "$path" ]] || die "path not found: $path"
  local dir base
  dir="$(cd "$(dirname "$path")" && pwd)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

abs_output_path() {
  local path="$1"
  local dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  printf '%s/%s\n' "$dir" "$base"
}

rest_upload_file() {
  check_common_deps
  local target="$1"
  local file="$2"
  [[ -f "$file" ]] || die "file not found: $file"
  local api
  api="$(target_api "$target")"
  curl -fsS \
    -H 'Content-Type: application/octet-stream' \
    --data-binary "@${file}" \
    "${api}/data"
}

target_upload_file() {
  local target="$1"
  local file="$2"
  [[ -n "$file" ]] || die 'upload requires <file>'
  local cid
  if [[ "$target" == 'lib' ]]; then
    cid="$(lib_result upload "$(abs_existing_path "$file")")"
  else
    cid="$(rest_upload_file "$target" "$file")"
  fi
  printf '%s\n' "$cid"
  record_cid "$target" "$cid" "$file"
}

target_upload_random() {
  local target="$1"
  local size="${2:-}"
  local keep=false
  [[ -n "$size" ]] || die 'upload-random requires <size> [--keep]'

  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) keep=true ;;
      *) die "unknown upload-random option: $1" ;;
    esac
    shift
  done

  local tmp cid
  tmp="$(mktemp "${TMPDIR:-/tmp}/logos-storage-test.XXXXXX")"
  dd if=/dev/urandom of="$tmp" bs="$size" count=1 status=progress >&2
  cid="$(target_upload_file "$target" "$tmp")"
  printf '%s\n' "$cid"

  if [[ "$keep" == true ]]; then
    printf 'kept file: %s\n' "$tmp" >&2
  else
    rm -f "$tmp"
  fi
}

target_list_cids() {
  local target="$1"
  if [[ "$target" == 'lib' ]]; then
    lib_result list | jq -r '.[]?.cid'
    return 0
  fi

  check_common_deps
  local api
  api="$(target_api "$target")"
  curl -fsS "${api}/data" | jq -r '.content[]?.cid'
}

target_delete_cid() {
  local target="$1"
  local cid="${2:-}"
  [[ -n "$cid" ]] || die 'delete requires <cid>'
  if [[ "$target" == 'lib' ]]; then
    lib_result delete "$cid" >/dev/null
  else
    check_common_deps
    local api
    api="$(target_api "$target")"
    curl -fsS -X DELETE "${api}/data/${cid}" >/dev/null
  fi
  printf 'deleted %s from %s\n' "$cid" "$target"
}

target_delete_all() {
  local target="$1"
  local yes="${2:-}"
  [[ "$yes" == '--yes' ]] || die 'delete-all requires --yes'

  local cid count=0
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    target_delete_cid "$target" "$cid"
    count=$((count + 1))
  done < <(target_list_cids "$target")
  printf 'deleted %d CID(s) from %s\n' "$count" "$target"
}

target_simple_get() {
  local target="$1"
  local path="$2"
  if [[ "$target" == 'lib' ]]; then
    case "$path" in
      space) lib_result space ;;
      peerid) lib_result peer-id ;;
      *) die "unsupported lib get path: $path" ;;
    esac
    return 0
  fi

  check_common_deps
  local api
  api="$(target_api "$target")"
  curl -fsS "${api}/${path}"
  printf '\n'
}

target_exists_cid() {
  local target="$1"
  local cid="${2:-}"
  [[ -n "$cid" ]] || die 'exists requires <cid>'
  if [[ "$target" == 'lib' ]]; then
    lib_result exists "$cid"
  else
    target_simple_get "$target" "data/${cid}/exists"
  fi
}

target_fetch_cid() {
  local target="$1"
  local cid="${2:-}"
  local wait="${3:-}"
  [[ -n "$cid" ]] || die 'fetch requires <cid> [--wait]'
  [[ -z "$wait" || "$wait" == '--wait' ]] || die 'only supported option is --wait'

  if [[ "$target" == 'lib' ]]; then
    [[ -z "$wait" ]] || printf 'warning: --wait is ignored for lib fetch\n' >&2
    lib_result fetch "$cid"
    return 0
  fi

  check_common_deps
  local api response download_id
  api="$(target_api "$target")"
  response="$(curl -fsS -X POST "${api}/data/${cid}/network")"
  printf '%s\n' "$response" | jq .

  if [[ "$wait" != '--wait' ]]; then
    return 0
  fi

  download_id="$(printf '%s\n' "$response" | jq -r '.downloadId // empty')"
  [[ -n "$download_id" ]] || die 'response did not contain downloadId'

  while true; do
    local progress active received total
    progress="$(curl -fsS "${api}/data/${cid}/network/progress/${download_id}")"
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

target_download_cid() {
  local target="$1"
  local cid="${2:-}"
  local out="${3:-}"
  local local_only=false
  [[ -n "$cid" && -n "$out" ]] || die 'download requires <cid> <output-file> [--local]'
  if [[ "${4:-}" == '--local' ]]; then
    local_only=true
  elif [[ -n "${4:-}" ]]; then
    die 'download only supports optional --local'
  fi

  out="$(abs_output_path "$out")"

  if [[ "$target" == 'lib' ]]; then
    lib_result download "$cid" "$out" "$local_only" >/dev/null
  else
    check_common_deps
    local api
    api="$(target_api "$target")"
    curl -fL "${api}/data/${cid}/network/stream" -o "$out"
  fi
  printf '%s\n' "$out"
}

lib_only_command() {
  local command="$1"
  shift
  case "$command" in
    spr)
      [[ $# -eq 0 ]] || die "$command does not accept arguments"
      lib_result "$command"
      ;;
    debug)
      [[ $# -eq 0 ]] || die 'debug does not accept arguments'
      lib_result debug | jq .
      ;;
    peers)
      [[ $# -eq 0 ]] || die 'peers does not accept arguments'
      lib_result debug | jq -r '.table.nodes | length'
      ;;
    manifest)
      [[ $# -eq 1 ]] || die 'manifest requires <cid>'
      lib_result manifest "$1"
      ;;
    connect)
      [[ $# -ge 1 ]] || die 'connect requires <peer-id> [addr...]'
      lib_result connect "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

size_to_bytes() {
  local value="$1"
  local number suffix
  number="${value%[KkMmGg]}"
  suffix="${value:${#number}}"
  [[ "$number" =~ ^[0-9]+$ ]] || die "invalid size: $value"
  case "$suffix" in
    K|k) printf '%s\n' $((number * 1024)) ;;
    M|m) printf '%s\n' $((number * 1024 * 1024)) ;;
    G|g) printf '%s\n' $((number * 1024 * 1024 * 1024)) ;;
    '') printf '%s\n' "$number" ;;
    *) die "invalid size suffix: $value" ;;
  esac
}

now_ns() {
  date +%s%N
}

elapsed_seconds() {
  local start_ns="$1"
  local end_ns="$2"
  awk -v start="$start_ns" -v end="$end_ns" 'BEGIN { printf "%.3f", (end - start) / 1000000000 }'
}

sum_seconds() {
  awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN { printf "%.3f", a + b + c }'
}

format_speed() {
  local bytes="$1"
  local seconds="$2"
  awk -v bytes="$bytes" -v seconds="$seconds" '
    BEGIN {
      if (seconds <= 0) {
        printf "n/a"
        exit
      }
      speed = bytes / seconds
      unit = "B/s"
      if (speed >= 1024) { speed /= 1024; unit = "KiB/s" }
      if (speed >= 1024) { speed /= 1024; unit = "MiB/s" }
      if (speed >= 1024) { speed /= 1024; unit = "GiB/s" }
      printf "%.2f %s", speed, unit
    }
  '
}

target_manifest_cid() {
  local target="$1"
  local cid="${2:-}"
  [[ -n "$cid" ]] || die 'manifest requires <cid>'
  if [[ "$target" == 'lib' ]]; then
    lib_result manifest "$cid" >/dev/null
    return 0
  fi

  check_common_deps
  local api
  api="$(target_api "$target")"
  curl -fsS "${api}/data/${cid}/network/manifest" >/dev/null
}

target_stream_sink() {
  local target="$1"
  local cid="${2:-}"
  local local_flag="${3:-}"
  [[ -n "$cid" ]] || die 'stream-sink requires <cid> [--local]'
  [[ -z "$local_flag" || "$local_flag" == '--local' ]] || die 'stream-sink only supports optional --local'

  if [[ "$target" == 'lib' ]]; then
    lib_result stream-sink "$cid" "$([[ "$local_flag" == '--local' ]] && printf true || printf false)" >/dev/null
    return 0
  fi

  check_common_deps
  local api path
  api="$(target_api "$target")"
  if [[ "$local_flag" == '--local' ]]; then
    path="${api}/data/${cid}"
  else
    path="${api}/data/${cid}/network/stream"
  fi
  curl -fLsS "$path" -o /dev/null
}

target_download_local_cid() {
  local target="$1"
  local cid="${2:-}"
  local out="${3:-}"
  [[ -n "$cid" && -n "$out" ]] || die 'local download requires <cid> <output-file>'
  if [[ "$target" == 'lib' ]]; then
    target_download_cid lib "$cid" "$out" --local >/dev/null
    return 0
  fi

  check_common_deps
  local api
  api="$(target_api "$target")"
  curl -fLsS "${api}/data/${cid}" -o "$out"
}

target_test() {
  local target="$1"
  [[ "$target" == 'local' || "$target" == 'lib' ]] || die 'test is supported only for local and lib targets'
  check_common_deps
  need sha256sum

  local max_bytes=$((10 * 1024 * 1024))
  local workspace report_ts report_path start_time start_epoch cleanup_done=0 cleanup_failures=0
  workspace="$(mktemp -d "${TMPDIR:-/tmp}/logos-storage-test.XXXXXX")"
  report_ts="$(date +%Y-%m-%d_%H-%M-%S)"
  report_path="./report-${report_ts}.md"
  start_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start_epoch="$(date +%s)"
  local -a cids=()
  local -a local_cids=()
  local -a result_sizes=()
  local -a result_bytes=()
  local -a result_sources=()
  local -a result_downloads=()
  local -a result_cids=()
  local -a result_hashes=()
  local -a result_manifest_times=()
  local -a result_network_times=()
  local -a result_network_speeds=()
  local -a result_write_times=()
  local -a result_write_speeds=()
  local -a result_total_times=()
  local -a result_total_speeds=()
  local -a cleanup_messages=()

  cleanup() {
    if [[ "$cleanup_done" == '1' ]]; then
      return 0
    fi
    cleanup_done=1
    local cid
    for cid in "${local_cids[@]:-}"; do
      if target_delete_cid "$target" "$cid" >/dev/null 2>&1; then
        cleanup_messages+=("deleted $cid from $target")
      else
        cleanup_messages+=("failed to delete $cid from $target")
        cleanup_failures=$((cleanup_failures + 1))
      fi
    done
    for cid in "${cids[@]:-}"; do
      if target_delete_cid remote "$cid" >/dev/null 2>&1; then
        cleanup_messages+=("deleted $cid from remote")
      else
        cleanup_messages+=("failed to delete $cid from remote")
        cleanup_failures=$((cleanup_failures + 1))
      fi
    done
    if [[ "$TEST_KEEP_FILES" != '1' ]]; then
      rm -rf "$workspace"
      cleanup_messages+=("removed workspace $workspace")
    else
      printf 'kept test workspace: %s\n' "$workspace" >&2
      cleanup_messages+=("kept workspace $workspace")
    fi
  }
  trap cleanup ERR

  write_report() {
    local end_time end_epoch duration i
    end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    end_epoch="$(date +%s)"
    duration=$((end_epoch - start_epoch))

    {
      printf '# Logos Storage Test Report\n\n'
      printf -- '- **Status:** PASS\n'
      printf -- "- **Started:** \`%s\`\n" "$start_time"
      printf -- "- **Finished:** \`%s\`\n" "$end_time"
      printf -- "- **Duration:** \`%ss\`\n" "$duration"
      printf -- "- **Target:** \`%s\`\n" "$target"
      printf -- "- **Remote source:** \`remote\`\n"
      printf -- "- **File sizes:** \`%s\`\n" "$TEST_FILE_SIZES"
      printf -- "- **Workspace:** \`%s\`\n" "$workspace"
      printf -- "- **Cleanup failures:** \`%s\`\n\n" "$cleanup_failures"

      printf '## Files\n\n'
      printf '| # | Size | Bytes | Manifest Time | Network Stream Time | Network Stream Speed | Local Write Time | Local Write Speed | Total Time | Total Speed | CID | SHA-256 | Source | Download |\n'
      printf '|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|---|\n'
      for i in "${!result_cids[@]}"; do
        printf "| %d | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` | \`%s\` |\n" \
          "$((i + 1))" \
          "${result_sizes[$i]}" \
          "${result_bytes[$i]}" \
          "${result_manifest_times[$i]}" \
          "${result_network_times[$i]}" \
          "${result_network_speeds[$i]}" \
          "${result_write_times[$i]}" \
          "${result_write_speeds[$i]}" \
          "${result_total_times[$i]}" \
          "${result_total_speeds[$i]}" \
          "${result_cids[$i]}" \
          "${result_hashes[$i]}" \
          "${result_sources[$i]}" \
          "${result_downloads[$i]}"
      done

      printf '\n## Cleanup\n\n'
      if [[ ${#cleanup_messages[@]} -eq 0 ]]; then
        printf -- '- No cleanup actions recorded.\n'
      else
        for i in "${!cleanup_messages[@]}"; do
          printf -- '- %s\n' "${cleanup_messages[$i]}"
        done
      fi
    } > "$report_path"
  }

  printf 'Starting Logos Storage remote-to-%s test\n' "$target"
  printf '  workspace: %s\n' "$workspace"
  printf '  report:    %s\n' "$report_path"
  printf '  sizes:     %s\n' "$TEST_FILE_SIZES"

  local size index=0
  for size in $TEST_FILE_SIZES; do
    local bytes src out cid src_hash out_hash
    local manifest_start manifest_end network_start network_end write_start write_end
    local manifest_seconds network_seconds write_seconds total_seconds
    local network_speed write_speed total_speed
    bytes="$(size_to_bytes "$size")"
    (( bytes <= max_bytes )) || die "test file size exceeds 10MB limit: $size"

    index=$((index + 1))
    src="${workspace}/source-${index}-${size}.bin"
    out="${workspace}/download-${index}-${size}.bin"
    dd if=/dev/urandom of="$src" bs="$size" count=1 status=none
    src_hash="$(sha256sum "$src" | awk '{ print $1 }')"

    printf '\n[%d] Generate %s random file (%s bytes)\n' "$index" "$size" "$bytes"
    printf '[%d] Upload to remote\n' "$index"
    cid="$(target_upload_file remote "$src")"
    cids+=("$cid")

    printf '[%d] Resolve manifest via %s: %s\n' "$index" "$target" "$cid"
    manifest_start="$(now_ns)"
    target_manifest_cid "$target" "$cid"
    manifest_end="$(now_ns)"
    manifest_seconds="$(elapsed_seconds "$manifest_start" "$manifest_end")"

    printf '[%d] Network stream via %s\n' "$index" "$target"
    network_start="$(now_ns)"
    target_stream_sink "$target" "$cid"
    network_end="$(now_ns)"
    network_seconds="$(elapsed_seconds "$network_start" "$network_end")"
    network_speed="$(format_speed "$bytes" "$network_seconds")"
    local_cids+=("$cid")

    printf '[%d] Local write via %s\n' "$index" "$target"
    write_start="$(now_ns)"
    target_download_local_cid "$target" "$cid" "$out"
    write_end="$(now_ns)"
    write_seconds="$(elapsed_seconds "$write_start" "$write_end")"
    write_speed="$(format_speed "$bytes" "$write_seconds")"
    total_seconds="$(sum_seconds "$manifest_seconds" "$network_seconds" "$write_seconds")"
    total_speed="$(format_speed "$bytes" "$total_seconds")"

    out_hash="$(sha256sum "$out" | awk '{ print $1 }')"
    [[ "$src_hash" == "$out_hash" ]] || die "hash mismatch for cid $cid"
    result_sizes+=("$size")
    result_bytes+=("$bytes")
    result_sources+=("$src")
    result_downloads+=("$out")
    result_cids+=("$cid")
    result_hashes+=("$src_hash")
    result_manifest_times+=("${manifest_seconds}s")
    result_network_times+=("${network_seconds}s")
    result_network_speeds+=("$network_speed")
    result_write_times+=("${write_seconds}s")
    result_write_speeds+=("$write_speed")
    result_total_times+=("${total_seconds}s")
    result_total_speeds+=("$total_speed")
    printf '[%d] Manifest:       %ss\n' "$index" "$manifest_seconds"
    printf '[%d] Network stream: %ss, %s\n' "$index" "$network_seconds" "$network_speed"
    printf '[%d] Local write:    %ss, %s\n' "$index" "$write_seconds" "$write_speed"
    printf '[%d] Total:          %ss, %s\n' "$index" "$total_seconds" "$total_speed"
    printf '[%d] OK sha256=%s\n' "$index" "$src_hash"
  done

  printf '\nCleaning up remote and %s CIDs...\n' "$target"
  cleanup
  trap - ERR
  write_report

  printf '\nTest passed\n'
  printf '  target:           %s\n' "$target"
  printf '  files validated:  %d\n' "$index"
  printf '  cleanup failures: %d\n' "$cleanup_failures"
  printf '  report:           %s\n' "$report_path"
}

target_command() {
  local target="$1"
  local command="${2:-help}"
  shift 2 || true

  case "$command" in
    upload) target_upload_file "$target" "${1:-}" ;;
    upload-random) target_upload_random "$target" "$@" ;;
    download) target_download_cid "$target" "$@" ;;
    fetch) target_fetch_cid "$target" "$@" ;;
    stream-sink) target_stream_sink "$target" "$@" ;;
    list) [[ $# -eq 0 ]] || die 'list does not accept arguments'; target_list_cids "$target" ;;
    delete) target_delete_cid "$target" "$@" ;;
    delete-all) target_delete_all "$target" "$@" ;;
    exists) target_exists_cid "$target" "$@" ;;
    space) [[ $# -eq 0 ]] || die 'space does not accept arguments'; target_simple_get "$target" 'space' ;;
    peerid) [[ $# -eq 0 ]] || die 'peerid does not accept arguments'; target_simple_get "$target" 'peerid' ;;
    test) [[ $# -eq 0 ]] || die 'test does not accept arguments yet'; target_test "$target" ;;
    spr|debug|peers|manifest|connect)
      [[ "$target" == 'lib' ]] || die "$command is currently supported only for lib target"
      lib_only_command "$command" "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown command for target '$target': $command"
      ;;
  esac
}

cmd="${1:-help}"
shift || true

if is_target "$cmd"; then
  target_command "$cmd" "$@"
  exit 0
fi

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
  last-cid) last_cid "$@" ;;
  *)
    usage >&2
    exit 1
    ;;
esac
