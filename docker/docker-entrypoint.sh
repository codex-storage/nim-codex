#!/bin/bash

# Parameters
if [[ -z "${CODEX_NAT}" ]]; then
  if [[ "${NAT_IP_AUTO}" == "true" && -z "${NAT_PUBLIC_IP_AUTO}" ]]; then
    export CODEX_NAT=$(hostname --ip-address)
    echo "Private: CODEX_NAT=${CODEX_NAT}"
  elif [[ -n "${NAT_PUBLIC_IP_AUTO}" ]]; then
    # Run for 60 seconds if fail
    WAIT=120
    SECONDS=0
    SLEEP=5
    while (( SECONDS < WAIT )); do
      export CODEX_NAT=$(curl -s -f -m 5 "${NAT_PUBLIC_IP_AUTO}")
      # Check if exit code is 0 and returned value is not empty
      if [[ $? -eq 0 && -n "${CODEX_NAT}" ]]; then
        echo "Public: CODEX_NAT=${CODEX_NAT}"
        break
      else
        # Sleep and check again
        echo "Can't get Public IP - Retry in $SLEEP seconds / $((WAIT - SECONDS))"
        sleep $SLEEP
      fi
    done
  fi
fi

# Stop Codex run if can't get NAT IP when requested
if [[ "${NAT_IP_AUTO}" == "true" && -z "${CODEX_NAT}" ]]; then
  echo "Can't get Private IP - Stop Codex run"
  exit 1
elif [[ -n "${NAT_PUBLIC_IP_AUTO}" && -z "${CODEX_NAT}" ]]; then
  echo "Can't get Public IP in $WAIT seconds - Stop Codex run"
  exit 1
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
