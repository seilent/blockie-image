#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
tar -C "$src/src" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - . |
  gzip -n > "$top/SOURCES/blk-wmt-src.tar.gz"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$src/blk-wmt.spec"
find "$top/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
