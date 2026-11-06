#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
in=/input
. "$src/SOURCE.env"
kver=$KERNEL_RELEASE

[[ -d $in ]] || { echo "build.sh: no PKG_INPUT at $in, see LOCAL" >&2; exit 1; }
diff <(cd "$in" && find . -type f -printf '%P\n' | LC_ALL=C sort) <(awk '{ print $2 }' "$src/INPUT.sha256" | LC_ALL=C sort) ||
  { echo "build.sh: $in does not hold exactly the files of INPUT.sha256" >&2; exit 1; }
(cd "$in" && sha256sum --quiet -c "$src/INPUT.sha256")

top=$(mktemp -d)
trap 'rm -rf "${top:?}"' EXIT
zcat "$in/vmlinuz" > "$top/Image"
grep -aqF "Linux version $kver " "$top/Image" || { echo "build.sh: vmlinuz is not $kver" >&2; exit 1; }
for ko in "$in"/extra/*.ko; do
  got=$(modinfo -F vermagic "$ko")
  [[ $got == "$kver SMP preempt mod_unload modversions aarch64" ]] || { echo "build.sh: ${ko##*/} vermagic $got" >&2; exit 1; }
done

stage=$top/stage
moddir=$stage/usr/lib/modules/$kver
install -Dm644 "$in/vmlinuz" "$moddir/vmlinuz"
install -Dm644 "$src/config" "$moddir/config"
install -Dm644 -t "$moddir" "$in/System.map" "$in/modules.builtin" "$in/modules.builtin.modinfo"
install -Dm644 -t "$moddir/extra" "$in"/extra/*.ko
(cd "$moddir" && printf '%s\n' extra/*.ko > modules.order)
install -Dm644 "$src/LICENSE.kernel" "$stage/usr/share/licenses/blockie-kernel/LICENSE.kernel"
if ! depmod -b "$stage/usr" -e -F "$moddir/System.map" "$kver" 2> "$top/depmod.err" || [[ -s $top/depmod.err ]]; then
  cat "$top/depmod.err" >&2
  exit 1
fi
[[ -s $moddir/modules.dep ]] || { echo "build.sh: depmod wrote no $moddir/modules.dep" >&2; exit 1; }

export SOURCE_DATE_EPOCH
rpmbuild -bb --target aarch64 \
  --define "_topdir $top/rpm" \
  --define "_buildhost blockie" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  --define "kversion ${kver%%-*}" \
  --define "kver $kver" \
  --define "stage $stage" \
  "$src/blockie-kernel.spec"
find "$top/rpm/RPMS" -name '*.rpm' -exec cp -t "$out" {} +
