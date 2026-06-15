#!/usr/bin/env bash

set -euo pipefail

# Redirect the traffic to our router instead
# of podman's own gateway to put B behind the NAT.
ip route replace default via "$ROUTER_LAN_IP"

# Fetch the bootstrap SPR (retry: the bootstrap may still be starting).
echo "fetching bootstrap SPR from $BOOTSTRAP_API ..."
spr=""
for _ in $(seq 1 60); do
  spr=$(curl -fsS -H 'Accept: text/plain' "$BOOTSTRAP_API/api/storage/v1/spr" || true)
  [[ -n "$spr" ]] && break
  sleep 1
done
[[ -n "$spr" ]] || { echo "ERROR: could not fetch bootstrap SPR" >&2; exit 1; }

# api-bindaddr=0.0.0.0 so the published host port reaches the REST API.
exec /app/build/storage \
  --listen-ip=0.0.0.0 --api-bindaddr=0.0.0.0 \
  --listen-port=8070 --disc-port=8090 --api-port=8080 \
  --bootstrap-node="$spr" \
  --nat-num-peers-to-ask=1 --nat-max-queue-size=1 \
  --nat-min-confidence=1.0 --nat-schedule-interval=30s \
  --data-dir=/data --log-level=DEBUG \
  ${EXTRA_STORAGE_ARGS:-}
