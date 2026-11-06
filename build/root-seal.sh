#!/usr/bin/env bash
set -euo pipefail

img=${1:?usage: root-seal.sh <image> <gz out>}
gz=${2:?usage: root-seal.sh <image> <gz out>}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

start=$(date +%s%N)
mark() { echo $(( ($(date +%s%N) - start) / 1000000 )) > "$tmp/ms.$1"; }

head -c 1048576 "$img" | sha256sum > "$tmp/head"
mark head
{ sha256sum < "$img" > "$tmp/whole"; mark whole; } &
p1=$!
{ tail -c +1048577 "$img" | sha256sum > "$tmp/body"; mark body; } &
p2=$!
{ pigz -1 -c "$img" | { tee "$gz"; mark compress; } | pigz -dc | sha256sum > "$tmp/unpack"; mark unpack; } &
p3=$!
rc=0
for p in "$p1" "$p2" "$p3"; do
  wait "$p" || rc=1
done
(( rc == 0 )) || { echo "::error::root-seal: hashing or compressing $img failed" >&2; exit 1; }
sha256sum < "$gz" > "$tmp/gz"
mark gz
echo "root-seal: ms from start: head $(< "$tmp/ms.head"), whole $(< "$tmp/ms.whole"), body $(< "$tmp/ms.body"), compress $(< "$tmp/ms.compress"), unpack $(< "$tmp/ms.unpack"), gz sha256 $(< "$tmp/ms.gz")" >&2

sum() {
  local s
  s=$(cut -d' ' -f1 "$tmp/$1")
  [[ $s =~ ^[0-9a-f]{64}$ ]] || { echo "::error::root-seal: no $1 sha256" >&2; exit 1; }
  echo "$s"
}
whole=$(sum whole)
body=$(sum body)
head=$(sum head)
unpack=$(sum unpack)
gzsum=$(sum gz)
[[ $unpack == "$whole" ]] || { echo "::error::${gz##*/} does not unpack to the image" >&2; exit 1; }
echo "ROOT_GZ_SHA=$gzsum"
echo "ROOT_SHA=$whole"
echo "ROOT_HEAD_SHA=$head"
echo "ROOT_BODY_SHA=$body"
