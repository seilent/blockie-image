#!/usr/bin/env bash
set -euo pipefail

min=${1:?usage: ci-disk.sh <minimum free GB> [path]}
path=${2:-/}
[[ $min =~ ^[0-9]+$ ]] || { echo "::error::ci-disk: minimum '$min' is not a number of GB"; exit 1; }
avail=$(df -B1 --output=avail "$path" | tail -n 1 | tr -d ' ')
[[ $avail =~ ^[0-9]+$ ]] || { echo "::error::ci-disk: no free space figure for $path: '$avail'"; exit 1; }
gb=$(( avail / 1000000000 ))
echo "ci-disk: $path has $avail bytes free ($gb GB), minimum $min GB"
(( avail >= min * 1000000000 )) || { echo "::error::$path has $gb GB free, below $min GB"; exit 1; }
