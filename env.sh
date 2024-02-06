#!/usr/bin/env bash

# This is the compiler version that will get used everywhere by default.
NIM_VERSION="f45bdea94ac4ed9a9bae03426275456aeb0cab2a"
NIM_REPO_URL="https://github.com/gmega/Nim"

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"

ENV_FILE="${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh"

# This makes it look nicer in the CI: if the version in the matrix says
# "repo_current", then we'll use the version that's registered here.
if [ "${NIM_COMMIT}" = "repo_current" ] || [ "${NIM_COMMIT}" = "" ]; then
  export NIM_COMMIT="${NIM_VERSION}"
  export NIM_REPO="${NIM_REPO_URL}"
fi

if ! [ -f "$ENV_FILE" ]; then
  # Before the first "make update", the env file doesn't exist.
  echo "Nimbus build system env file not found."
  # If more than one argument is passed, we assume it's a command to run.
  # Probably "make update".
  if [ $# -gt 0 ]; then
    "$@"
  # Otherwise just print a little reminder to the user.
  else
    echo "You need to run:                     "
    echo "                                     "
    echo "   ./env.sh make -j{CPU_CORES} update"
    echo "                                     "
    echo "to build the compiler.               "
  fi
else
  source "${ENV_FILE}"
fi
