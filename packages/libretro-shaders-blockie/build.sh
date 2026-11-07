#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
spec=$src/libretro-shaders-blockie.spec
(cd /srcpkg && sha256sum --quiet -c "$src/SOURCE.sha256") || { echo "build.sh: /srcpkg differs from SOURCE.sha256" >&2; exit 1; }
urls=$(rpmspec -P "$spec" | sed -n 's|^Source[0-9]*:[[:space:]]*\(https://.*\)$|\1|p')
[[ $(sed 's|.*/||' <<< "$urls" | LC_ALL=C sort) == "$(awk '{ print $2 }' "$src/SOURCE.sha256" | LC_ALL=C sort)" ]] ||
  { echo "build.sh: the spec's Source URLs are not SOURCE.sha256's files" >&2; exit 1; }
c=$(sed -n 's/^%global commit //p' "$spec")
[[ $c =~ ^[0-9a-f]{40}$ ]] || { echo "build.sh: the spec's commit is not a full sha" >&2; exit 1; }
! grep -qv "^https://raw.githubusercontent.com/libretro/glsl-shaders/$c/" <<< "$urls" ||
  { echo "build.sh: a Source URL is not at glsl-shaders $c" >&2; exit 1; }
top=$(mktemp -d)
chmod 755 "$top"
trap 'rm -rf "${top:?}"' EXIT
mkdir -p "$top/SOURCES"
tar -C "$src" --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner -cf - LICENSE blockie |
  gzip -n > "$top/SOURCES/libretro-shaders-blockie-src.tar.gz"
while read -r _ name; do
  cp "/srcpkg/$name" "$top/SOURCES/"
done < "$src/SOURCE.sha256"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
find "$top/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
