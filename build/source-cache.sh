#!/usr/bin/env bash
set -euo pipefail

cache=$(realpath -m "${1:?usage: source-cache.sh <cache dir>}")
: "${IMAGE:?}" "${SOURCE_TYPE:?}" "${PUBKEY:?}"
pubkey=$(realpath "$PUBKEY")
cd "$(dirname "$0")/.."
mkdir -p "$cache"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

tags=()
while read -r c; do
  tags+=("testing-${c::7}")
done < <(git rev-list --first-parent --skip=1 --max-count=5 HEAD)
tags+=(testing)

found=
for tag in "${tags[@]}"; do
  if ! refs=$(oras discover --artifact-type "$SOURCE_TYPE" --format json --depth 1 "$IMAGE:$tag" 2> /dev/null | jq -r '.referrers[]?.digest'); then
    echo "source-cache: no $IMAGE:$tag"
    continue
  fi
  for d in $refs; do
    [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || continue
    if ! cosign verify --key "$pubkey" "$IMAGE@$d" > /dev/null 2>&1; then
      echo "::warning::$IMAGE@$d (source of $tag) fails cosign verify, not used"
      continue
    fi
    layer=$(oras manifest fetch "$IMAGE@$d" | jq -r '.layers[] | select(.annotations["org.opencontainers.image.title"] == "SOURCES") | .digest')
    [[ $layer == sha256:* && $layer != *$'\n'* ]] || continue
    oras blob fetch --output "$tmp/prev.SOURCES" "$IMAGE@$layer"
    found=$tag
    break 2
  done
  echo "source-cache: no signed SOURCES on $IMAGE:$tag"
done
if [[ -z $found ]]; then
  echo "::notice::no signed source artifact on the last five main commits or $IMAGE:testing, every source rpm comes from koji"
  exit 0
fi
nevra='^([A-Za-z0-9][A-Za-z0-9._+~^-]*)-([A-Za-z0-9._+~^]+)-([A-Za-z0-9._+~^]+)\.src\.rpm$'
while read -r f sum _; do
  [[ $f =~ $nevra && $f != */* && $f != *..* && $sum =~ ^[0-9a-f]{64}$ ]] || continue
  (( $(jobs -rp | wc -l) < 8 )) || wait -n
  { oras blob fetch --output "$cache/$f" "$IMAGE@sha256:$sum" > /dev/null 2>&1 || rm -f "$cache/$f"; } &
done < "$tmp/prev.SOURCES"
wait
echo "::notice::$(find "$cache" -name '*.src.rpm' | wc -l) source rpms from $IMAGE:$found"
