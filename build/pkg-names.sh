#!/usr/bin/env bash
set -euo pipefail

dir=${1:?usage: pkg-names.sh <packages/name dir>}
shopt -s nullglob
specs=("$dir"/*.spec)
if (( ${#specs[@]} )); then
  awk '$1 == "Name:" { n = $2; print n } $1 == "%package" { print ($2 == "-n" ? $3 : n "-" $2) }' "${specs[@]}"
elif [[ -f $dir/SOURCE.env ]]; then
  url=$(sed -n 's/^SRPM_URL=//p' "$dir/SOURCE.env")
  rpms=$(sed -n 's/^RPMS="\(.*\)"$/\1/p' "$dir/SOURCE.env")
  f=${url##*/}
  if [[ -n $url && -n $rpms ]]; then
    tr -s ' ' '\n' <<< "$rpms"
  elif [[ -n $url ]]; then
    echo "${f%-*-*.src.rpm}"
  fi
fi
