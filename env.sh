#!/usr/bin/env bash

# We use ${BASH_SOURCE[0]} instead of $0 to allow sourcing this file
# and we fall back to a Zsh-specific special var to also support Zsh.
REL_PATH="$(dirname ${BASH_SOURCE[0]:-${(%):-%x}})"
ABS_PATH="$(cd ${REL_PATH}; pwd)"

# This determines the compiler version that gets used.
export NIM_COMMIT="v1.6.16"
source ${ABS_PATH}/vendor/nimbus-build-system/scripts/env.sh
