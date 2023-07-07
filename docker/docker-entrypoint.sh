#!/bin/bash

# Parameters
if [[ "${NAT_IP_AUTO}" == "true" ]]; then
  export CODEX_NAT=$(hostname --ip-address)
  echo "Set CODEX_NAT: ${CODEX_NAT}"
fi

# Run
echo "Run Codex node"
exec "$@"
