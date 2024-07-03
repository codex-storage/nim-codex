#!/usr/bin/env bash

# Example - generating 64 MiB file
# ./generate-mb.sh my_file.bin 64

fname=$1
size=$2

dd if=/dev/urandom of="$fname" bs=1m count="$size"
