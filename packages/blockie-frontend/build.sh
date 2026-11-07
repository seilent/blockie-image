#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
spec=$src/blockie-frontend.spec
top=/var/tmp/blockie-frontend
mkdir -m 755 "$top"
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
(cd /srcpkg && sha256sum --quiet -c "$src/SOURCE.sha256") || { echo "build.sh: /srcpkg differs from SOURCE.sha256" >&2; exit 1; }
want=$(awk '{ print $2 }' "$src/SOURCE.sha256" | LC_ALL=C sort)
parsed=$(rpmspec -P "$spec")
got=$(sed -n 's/^Source[0-9]*:[[:space:]]*//p' <<< "$parsed" | sed 's|.*#/||; s|.*/||' | LC_ALL=C sort)
[[ $got == "$want" ]] || { echo "build.sh: the spec's Source names are not SOURCE.sha256's" >&2; exit 1; }
while read -r _ name; do
  cp "/srcpkg/$name" "$top/SOURCES/"
done < "$src/SOURCE.sha256"
grep -q "^Source0: *https://github.com/seilent/blockie-frontend/archive/$(sed -n 's/^%global commit //p' "$spec").tar.gz#/" <<< "$parsed" ||
  { echo "build.sh: Source0 is not the pinned commit" >&2; exit 1; }
c=$(sed -n 's/^%global commit //p' "$spec")
[[ $(sed -n 's/^%global shortcommit //p' "$spec") == "${c:0:7}" ]] || { echo "build.sh: shortcommit is not the commit's prefix" >&2; exit 1; }
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
find "$top/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
