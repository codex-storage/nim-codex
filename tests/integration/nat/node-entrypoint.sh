#!/usr/bin/env bash
#
# Entrypoint script for a storage node in the NAT integration test.
set -euo pipefail

STORAGE_BINARY=${STORAGE_BINARY:-/app/build/storage}

# In-memory configuration for the node.
config_opts=()

echoerr() {
  echo "$@" >&2
}

base_config() {
  config_opts+=(
    "${STORAGE_BINARY}"
    --listen-ip=0.0.0.0
    # api-bindaddr=0.0.0.0 so the published host port reaches the REST API.
    --api-bindaddr=0.0.0.0
    --listen-port=8070
    --disc-port=8090
    --api-port=8080
    --data-dir=/data
    --log-level=DEBUG
  )
}

add_bootstrap_options() {
  local bootstrap_addr="$1" spr=""
  if [[ -z "$bootstrap_addr" ]]; then
    echoerr "Node is a primary bootstrap node."
    config_opts+=(--no-bootstrap-node)
    return 0
  fi

  echoerr "Attempt to fetch bootstrap SPR from $bootstrap_addr ..."
  for _ in $(seq 1 60); do
    spr=$(curl -fsS -H 'Accept: text/plain' "http://$bootstrap_addr:8080/api/storage/v1/spr" || true)
    [[ -n "$spr" ]] && break
    sleep 1
  done

  if [[ -z "$spr" ]]; then
    echoerr "ERROR: could not fetch bootstrap SPR" >&2
    return 1
  fi
  echoerr "Successfully fetched bootstrap SPR: $spr"
  config_opts+=(--bootstrap-node="$spr")
}

public_node() {
  local wan_ip="$1"
  local bootstrap_addr="${2:-}"
  echoerr "Node is on the WAN (public IP is $wan_ip)"

  add_bootstrap_options "$bootstrap_addr"
  if [[ "$wan_ip" != "nonprimary" ]]; then
    echoerr "Primary bootstrap external address: $wan_ip"
    config_opts+=(
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

  config_opts+=(
    --nat-num-peers-to-ask=1
    --nat-max-queue-size=1
    --nat-min-confidence=1.0
    --nat-schedule-interval=30s
  )
}

enable_mix() {
  local info

  config_opts+=(
    --mix-enabled
  )

  rm -rf /tmp/mixinfo.jsonl || true

  for mix_ip in "$@"; do
    info=$(curl -s "http://$mix_ip:8080/api/storage/v1/debug/info")
    echo "$info" | jq '{
      peerid: .table.localNode.peerId,
      multiAddr: .providerAddresses[0],
      mixPubKey: .mixPubKey,
      libp2pPubKey: .libp2pPubKey
    }' >> /tmp/mixinfo.jsonl
    cmd+=(--dht-mix-proxy="echo $info | jq .providerRecord")
  done

  if [[ -s /tmp/mixinfo.jsonl ]]; then
    mix_pool_json_str=$(cat /tmp/mixinfo.jsonl | jq '{
      version: 1,
      relays: [inputs]
    } | tostring')
    config_opts+=(--mix-pool-json="$mix_pool_json_str")
  fi
}

enable_relay() {
  config_opts+=("--relay-server")
}

launch() {
  echoerr "Starting node..."
  exec "${config_opts[@]}"
}

# Added by default.
base_config

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # This will run commands separated by % as a chain.
  while [[ $# -gt 0 ]]; do
    current_cmd=()
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "%" ]]; then
        shift
        break
      fi
      current_cmd+=("$1")
      shift
    done
    "${current_cmd[@]}"
  done

  echoerr "#### Config opts ####"
  echoerr "${config_opts[@]}"
  echoerr "#####################"

  # Once we're done, launch the node.
  launch "$@"
fi
