#!/usr/bin/env bash
#
# Entrypoint script for a storage node in the NAT integration test.
set -euo pipefail

STORAGE_BINARY=${STORAGE_BINARY:-/app/build/storage}

echoerr() {
  echo "$@" >&2
}

echoerr "Starting node..."

# Base command, shared by all node types.
storage_cmd=(
  ${STORAGE_BINARY}
  --listen-ip=0.0.0.0
  # api-bindaddr=0.0.0.0 so the published host port reaches the REST API.
  --api-bindaddr=0.0.0.0
  --listen-port=8070
  --disc-port=8090
  --api-port=8080
  --data-dir=/data
  --log-level=DEBUG
)

add_bootstrap_options() {
  local bootstrap_api_url="$1" spr=""
  if [[ -z "$bootstrap_api_url" ]]; then
    echoerr "Node is a primary bootstrap node."
    storage_cmd+=(--no-bootstrap-node)
    return 0
  fi

  echoerr "Attempt to fetch bootstrap SPR from $bootstrap_api_url ..."
  for _ in $(seq 1 60); do
    spr=$(curl -fsS -H 'Accept: text/plain' "$bootstrap_api_url/api/storage/v1/spr" || true)
    [[ -n "$spr" ]] && break
    sleep 1
  done

  if [[ -z "$spr" ]]; then
    echoerr "ERROR: could not fetch bootstrap SPR" >&2
    return 1
  fi
  echoerr "Successfully fetched bootstrap SPR: $spr"
  storage_cmd+=(--bootstrap-node="$spr")
}

public_node() {
  local wan_ip="$1"
  local bootstrap_api_url="${2:-}"
  echoerr "Node is on the WAN (public IP is $wan_ip)"

  add_bootstrap_options "$bootstrap_api_url"
  if [[ "$wan_ip" != "nonprimary" ]]; then
    echoerr "Primary bootstrap external address: $wan_ip"
    storage_cmd+=(
      --autonat-server
      --nat=extip:$wan_ip
    )
  fi
}

private_node() {
  local router_lan_ip="$1"
  local bootstrap_api_url="$2"
  echoerr "Node is behind NAT (router LAN IP is $router_lan_ip)"
  # Redirect the traffic to our router instead of podman's own gateway to put the
  # node behind the NAT. A node on the wan (reachable) leaves ROUTER_LAN_IP unset
  # and keeps its default route.
  ip route replace default via "$router_lan_ip"

  if [[ -z "$bootstrap_api_url" ]]; then
    echoerr "Private nodes require a bootstrap API URL."
    help
    return 1
  fi

  add_bootstrap_options "$bootstrap_api_url"

  storage_cmd+=(
    --nat-num-peers-to-ask=1
    --nat-max-queue-size=1
    --nat-min-confidence=1.0
    --nat-schedule-interval=30s
  )
}

help() {
  echo "Usage: $0 <public|private> <args> -- [extra_args], where:"
  echo "  public <wan_ip>: launches a primary bootstrap node."
  echo "  public nonprimary <primary_api_url>: launches a non-primary, public node"
  echo "    which bootstraps from the primary and becomes a bootstrap node itself."
  echo "  private <router_lan_ip> <bootstrap_api_url>: launches a private node"
  echo "    which uses router_lan_ip as its gateway to the public internet."
  echo "  extra_args: passed on to the storage binary as they are."
}

builder_cmd=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    break
  fi
  builder_cmd+=("$1")
  shift
done

# Builds the actual storage command.
"${builder_cmd[@]}"

# Launches storage.
exec "${storage_cmd[@]}" "$@"
