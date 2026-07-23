#!/usr/bin/env bash

source "$(dirname "$0")/router-common.sh"

echo "router ready (wan iface $wanif)"

hold_until_stopped
