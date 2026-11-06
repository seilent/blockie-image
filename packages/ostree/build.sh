#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
srpm=/srpm/${SRPM_URL##*/}
echo "$SRPM_SHA256  $srpm" | sha256sum -c --quiet -
top=/var/tmp/ostree-build
mkdir -p "$top"
rpm -i --define "_topdir $top" "$srpm"
cp "$src/selinux-disabled-skip.patch" "$top/SOURCES/"
spec=$top/SPECS/ostree.spec
sed -i -e 's/^Release:\( *\)%autorelease$/Release:\1%autorelease.blockie/' \
  -e '/^Source0:/a Patch0: selinux-disabled-skip.patch' "$spec"
grep -qx 'Release: *%autorelease\.blockie' "$spec" || { echo "build.sh: Release not rewritten" >&2; exit 1; }
grep -qx 'Patch0: *selinux-disabled-skip\.patch' "$spec" || { echo "build.sh: Patch0 not added" >&2; exit 1; }
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  --define "debug_package %{nil}" \
  "$spec"
for n in $RPMS; do
  f=$(find "$top/RPMS" -name "$n-[0-9]*.rpm")
  [[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one $n RPM, found: $f" >&2; exit 1; }
  cp "$f" "$out/"
done
