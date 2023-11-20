#!/bin/bash

# Parameters
if [[ "${NAT_IP_AUTO}" == "true" && -z "${NAT_PUBLIC_IP_AUTO}" ]]; then
  export CODEX_NAT=$(hostname --ip-address)
  echo "Internal: Set CODEX_NAT: ${CODEX_NAT}"
fi

if [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
  # Run for 60 seconds if fail
  WAIT=60
  SECONDS=0
  SLEEP=5
  while (( SECONDS < WAIT )); do
    export CODEX_NAT=$(curl -s -f -m 5 "${NAT_PUBLIC_IP_AUTO}")
    # Check if exit code is 0 and returned value is not empty
    [[ $? -eq 0 && -n "${CODEX_NAT}" ]] && { echo "Public: Set CODEX_NAT: ${CODEX_NAT}"; break; } || { echo "Can't get Public IP - Retry in $SLEEP seconds / $((WAIT - SECONDS))"; }
    # Sleep and check again
    sleep $SLEEP
  done
fi

# Stop Codex run if can't get Public IP
[[ -z "${CODEX_NAT}" ]] && { echo "Can't get Public IP in $WAIT seconds - Stop Codex run"; exit 1; }

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
