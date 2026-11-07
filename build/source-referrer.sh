#!/usr/bin/env bash
set -euo pipefail

(( $# == 2 )) || { echo "usage: source-referrer.sh <repo@digest> <SOURCE.sha256>" >&2; exit 2; }
ref=$1
pins=$2
type=application/vnd.blockie.source.v1
[[ $ref =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] || { echo "source-referrer: bad ref $ref" >&2; exit 2; }
want=$(awk '{ print $2 " sha256:" $1 }' "$pins" | LC_ALL=C sort)
[[ -n $want ]] || { echo "source-referrer: $pins is empty" >&2; exit 2; }
repo=${ref%@*}
list=$(oras discover --artifact-type "$type" --format json "$ref")
while read -r d; do
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || continue
  got=$(oras manifest fetch "$repo@$d" |
    jq -r '.layers[] | "\(.annotations["org.opencontainers.image.title"]) \(.digest)"' | LC_ALL=C sort)
  if [[ $got == "$want" ]]; then
    echo "$d"
    exit 0
  fi
done < <(jq -r '.referrers[]?.digest' <<< "$list")
echo "source-referrer: no $type referrer on $ref holds the files of $pins" >&2
exit 1
