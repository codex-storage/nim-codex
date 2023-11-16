#!/bin/bash

# Parameters
if [[ "${NAT_IP_AUTO}" == "true" ]]; then
  export CODEX_NAT=$(hostname --ip-address)
  echo "Internal: Set CODEX_NAT: ${CODEX_NAT}"
fi

# Get Public IP
if [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
  # Waith 60 seconds
  WAIT=60
  SECONDS=0
  while (( SECONDS < WAIT )); do
    export CODEX_NAT=$(curl -m 5 "${NAT_PUBLIC_IP_AUTO}")
    # Check the exit code is 0 and returned value is not empty
    [[ $? -eq 0 && -n "${CODEX_NAT}" ]] && { echo "Public: Set CODEX_NAT: ${CODEX_NAT}"; break; }
    # Sleep and check again
    sleep 5
  done
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
