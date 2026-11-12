#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
(cd /srcpkg && sha256sum -c --quiet "$src/SOURCE.sha256")
spec=$src/portmaster.spec
grep -qx "%global commit $SOURCE_COMMIT" "$spec" || { echo "build.sh: spec commit is not $SOURCE_COMMIT" >&2; exit 1; }
grep -qx "%global tag $SOURCE_TAG" "$spec" || { echo "build.sh: spec tag is not $SOURCE_TAG" >&2; exit 1; }
grep -Eqx "Version: +${SOURCE_TAG//-/.}" "$spec" || { echo "build.sh: spec Version is not ${SOURCE_TAG//-/.}" >&2; exit 1; }
top=/var/tmp/portmaster-build
mkdir -p "$top/SOURCES"
cp "/srcpkg/$SOURCE_TAR" "$top/SOURCES/"
cp "$src/files/patcher.txt" "$src/charset_normalizer-LICENSE" "$src/gamecontrollerdb-LICENSE" "$top/SOURCES/"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
f=$(find "$top/RPMS" -name 'portmaster-[0-9]*.rpm')
[[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one portmaster RPM, found: $f" >&2; exit 1; }
cp "$f" "$out/"
