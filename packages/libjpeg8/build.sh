#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
(cd /srcpkg && sha256sum -c --quiet "$src/SOURCE.sha256")
spec=$src/libjpeg8.spec
grep -Eqx "Version: +$SOURCE_VERSION" "$spec" || { echo "build.sh: spec Version is not $SOURCE_VERSION" >&2; exit 1; }
[[ $SOURCE_TAR == "libjpeg-turbo-$SOURCE_VERSION.tar.gz" ]] || { echo "build.sh: SOURCE_TAR is not libjpeg-turbo-$SOURCE_VERSION.tar.gz" >&2; exit 1; }
top=/var/tmp/libjpeg8-build
mkdir -p "$top/SOURCES"
cp "/srcpkg/$SOURCE_TAR" "$top/SOURCES/"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "_smp_ncpus_max 6" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
f=$(find "$top/RPMS" -name 'libjpeg8-[0-9]*.rpm')
[[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one libjpeg8 RPM, found: $f" >&2; exit 1; }
cp "$f" "$out/"
