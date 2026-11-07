#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
(cd /srcpkg && sha256sum -c --quiet "$src/SOURCE.sha256")
spec=$src/libretro-mupen64plus-next.spec
grep -qx "%global commit $SOURCE_COMMIT" "$spec" || { echo "build.sh: spec commit is not $SOURCE_COMMIT" >&2; exit 1; }
grep -qx "%global shortcommit ${SOURCE_COMMIT:0:7}" "$spec" || { echo "build.sh: spec shortcommit is not ${SOURCE_COMMIT:0:7}" >&2; exit 1; }
day=$(date -u -d "@$SOURCE_EPOCH" +%Y%m%d)
grep -Eqx "Release: +[0-9]+\.${day}git%\{shortcommit\}%\{\?dist\}" "$spec" || { echo "build.sh: spec Release date is not $day" >&2; exit 1; }
top=/var/tmp/libretro-mupen64plus-next-build
mkdir -p "$top/SOURCES"
cp "/srcpkg/$SOURCE_TAR" "$top/SOURCES/"
cp "$src/no-graphicbuffer.patch" "$top/SOURCES/"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "_smp_ncpus_max 6" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
f=$(find "$top/RPMS" -name 'libretro-mupen64plus-next-[0-9]*.rpm')
[[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one libretro-mupen64plus-next RPM, found: $f" >&2; exit 1; }
cp "$f" "$out/"
