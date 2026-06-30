#!/usr/bin/env bash
# Script for generating configuration files and network presets for
# Logos Storage.

set -euo pipefail

# Valid networks
declare -A _networks
#_networks=([test]="Logos testnet" [dev]="Logos devnet")
_networks=([dev]="Logos devnet")

require() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 is not installed" >&2
        exit 1
    fi
}

check_network() {
    local network=$1
    if [[ -z "${_networks[$network]+x}" ]]; then
        echo "Invalid network: $network. Use one of: ${!_networks[*]}" >&2
        exit 1
    fi
}

raw_data() {
    local network=$1
    check_network "$network"
    curl -s "https://fleets.logos.co/logos-${network}/storage-network.json"
}

mix_pool_json() {
    local network=$1
    check_network "$network"
    raw_data "$network" | jq 'map({
      "peerId": .peerId,
      "mixPubKey": .mixPubKey,
      "libp2pPubKey": .libp2pPubKey,
      "multiAddr": "/ip4/\(.address)/tcp/\(.port)",
    })'
}

bootstrap_sprs() {
    local network="$1"
    check_network "$network"
    raw_data "$network" | jq '[.[].spr]'
}

mix_proxy_sprs() {
    local network="$1"
    check_network "$network"
    raw_data "$network" | jq '[.[].tcpSpr]'
}

full_config() {
    local network="$1"
    check_network "$network"
    cat <<EOF
    {
        "log-level": "${STORAGE_LOG_LEVEL:-info}",
        "nat": "${STORAGE_NAT:-any}",
        "network": "logos.${network}",
        "mix-enabled": true,
        "dht-mix-proxy": $(mix_proxy_sprs "$network"),
        "mix-pool-json": $(mix_pool_json "$network"),
    }
EOF
}

generate_presets() {
   cat <<EOF
   {
     "presets": [
EOF

    for network in "${!_networks[@]}"; do
    cat <<EOF
       {
         "name": "logos.${network}",
         "description": "${_networks[$network]}",
         "records": $(bootstrap_sprs "$network")
       }$( [[ "$network" != "${!_networks[*]: -1}" ]] && echo "," )
EOF
    done

cat <<EOF
     ]
   }
EOF
}

require jq

usage() {
    cat <<EOF
Usage: $0 <command> [network]

Generates configuration files and network presets for Logos Storage.

Commands:
  raw_data <network>        Fetch raw storage-network data from fleets.logos.co
  mix_pool_json <network>   Generate mix pool JSON configuration
  bootstrap_sprs <network>  List bootstrap SPRs
  mix_proxy_sprs <network>  List mix proxy SPRs (tcpSpr)
  full_config <network>     Generate full node configuration JSON
  presets                   Generate network presets JSON for all networks

Networks:
  ${!_networks[*]}

Examples:
  $0 bootstrap_sprs dev
  $0 full_config dev
  $0 presets
EOF
}

if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" || "$1" == "help" ]]; then
    usage
    exit 0
fi

if [ "$1" == "presets" ]; then
    generate_presets | jq .
    exit 0
fi

"$@" | jq .