#!/bin/bash

# Parameters
if [[ "${NAT_IP_AUTO}" == "true" ]]; then
  export CODEX_NAT=$(hostname --ip-address)
  echo "Internal: Set CODEX_NAT: ${CODEX_NAT}"
fi

if [[ "${NAT_PUBLIC_IP_AUTO}" == "true" ]]; then
  export CODEX_NAT=$(curl https://ipinfo.io/ip)
  echo "Public: Set CODEX_NAT: ${CODEX_NAT}"
fi

# If marketplace is enabled from the testing environment,
# The file has to be written before Codex starts.
if [ -n "${PRIV_KEY}" ]; then
  echo ${PRIV_KEY} > "private.key"
  chmod 600 "private.key"
  export CODEX_ETH_PRIVATE_KEY="private.key"
  echo "Private key set"
fi

# Run
echo "Run Codex node"
exec "$@"
