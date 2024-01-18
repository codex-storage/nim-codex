#!/usr/bin/env bash

# This is the version that gets used if NIM_COMMIT is not specified.
NIM_VERSION="v1.6.16"

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"

export NIM_COMMIT="${NIM_COMMIT:-${NIM_VERSION}}"
source ${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh
