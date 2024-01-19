#!/usr/bin/env bash

NIM_VERSION="f45bdea94ac4ed9a9bae03426275456aeb0cab2a"
NIM_REPO_URL="https://github.com/gmega/Nim"

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"

export NIM_COMMIT="${NIM_COMMIT:-${NIM_VERSION}}"
export NIM_REPO="${NIM_REPO_URL:-${NIM_REPO_URL}}"
source ${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh
