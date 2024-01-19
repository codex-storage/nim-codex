#!/usr/bin/env bash

# This is the compiler version that will get used everywher.
NIM_VERSION="f45bdea94ac4ed9a9bae03426275456aeb0cab2a"
NIM_REPO_URL="https://github.com/gmega/Nim"

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"

ENV_FILE="${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh"

export NIM_COMMIT="${NIM_COMMIT:-${NIM_VERSION}}"
if ! [ -f "$ENV_FILE" ]; then
  # Before the first "make update", the env file doesn't exist, so just run
  # the command that comes after (without a child shell), if any. Running
  # ./env.sh make update will cause the right compiler to be built right from
  # the start.
  echo "Nimbus env file not found"
  "$@"
else
  source "${ENV_FILE}"
fi
