#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
(cd /srcpkg && sha256sum -c --quiet "$src/SOURCE.sha256")
spec=$src/depotdownloader.spec
grep -qx "%global commit $SOURCE_COMMIT" "$spec" || { echo "build.sh: spec commit is not $SOURCE_COMMIT" >&2; exit 1; }
grep -qx "%global tag $SOURCE_TAG" "$spec" || { echo "build.sh: spec tag is not $SOURCE_TAG" >&2; exit 1; }
grep -Eqx "Version: +${SOURCE_TAG#DepotDownloader_}" "$spec" || { echo "build.sh: spec Version is not ${SOURCE_TAG#DepotDownloader_}" >&2; exit 1; }
grep -qx "%global skcommit $STEAMKIT_COMMIT" "$spec" || { echo "build.sh: spec skcommit is not $STEAMKIT_COMMIT" >&2; exit 1; }
grep -qx "%global sktag $STEAMKIT_TAG" "$spec" || { echo "build.sh: spec sktag is not $STEAMKIT_TAG" >&2; exit 1; }
locks=("$src/locks/DepotDownloader/packages.lock.json" "$src/locks/SteamKit2/packages.lock.json")
nugetid=$(cat "${locks[@]}" | sha256sum | cut -c1-8)
nuget=depotdownloader-nuget-$nugetid.tar
grep -qE "^[0-9a-f]{64}  $nuget\$" "$src/SOURCE.sha256" || { echo "build.sh: SOURCE.sha256 does not pin $nuget" >&2; exit 1; }
top=/var/tmp/depotdownloader-build
mkdir -p "$top/SOURCES"
cp "/srcpkg/$SOURCE_TAR" "/srcpkg/$STEAMKIT_TAR" "/srcpkg/$nuget" "$src/nuget.config" "$src/depotdownloader-blockie.patch" \
  "$src/Apache-2.0.txt" "$src/protobuf-net-Licence.txt" "$src/QRCoder-LICENSE.txt" "$src/ZstdSharp-LICENSE.txt" \
  "$src/dotnet-runtime-LICENSE.TXT" "$src/CsWin32-LICENSE.txt" "$top/SOURCES/"
cp "${locks[0]}" "$top/SOURCES/DepotDownloader.packages.lock.json"
cp "${locks[1]}" "$top/SOURCES/SteamKit2.packages.lock.json"
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "_smp_ncpus_max 6" \
  --define "nugetid $nugetid" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  "$spec"
f=$(find "$top/RPMS" -name 'depotdownloader-[0-9]*.rpm')
[[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one depotdownloader RPM, found: $f" >&2; exit 1; }
cp "$f" "$out/"
