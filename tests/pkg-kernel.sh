#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-kernel: $*" >&2; exit 1; }

out=${1:?usage: pkg-kernel.sh <outdir>}
kver=5.10.233-android12-9+
k=/usr/lib/modules/$kver
shopt -s nullglob
rpms=("$out"/blockie-kernel-*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one blockie-kernel RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "blockie-kernel aarch64" ]] || fail "name or arch"
want=$(printf '%s\n' "$k" "$k/System.map" "$k/config" "$k/extra" "$k/extra/hci_vhci.ko" "$k/extra/softdog.ko" \
  "$k/vmlinuz" /usr/share/licenses/blockie-kernel/LICENSE.kernel | LC_ALL=C sort)
got=$(rpm -qpl "$rpm" | grep -vF "$k/modules." | LC_ALL=C sort)
[[ $got == "$want" ]] || fail "file list: $got"

root=$(mktemp -d)
trap 'rm -rf "${root:?}"' EXIT
rpm2cpio "$rpm" | (cd "$root" && cpio -idm --quiet)
mods=("$root"/usr/lib/modules/*)
[[ ${#mods[@]} == 1 && ${mods[0]} == "$root$k" ]] || fail "modules dirs ${mods[*]}"
[[ $(find "$root" -name '*.ko*' | LC_ALL=C sort) == "$root$k/extra/hci_vhci.ko"$'\n'"$root$k/extra/softdog.ko" ]] ||
  fail "module set"
for f in modules.builtin modules.builtin.modinfo modules.order modules.dep; do
  [[ -s $root$k/$f ]] || fail "no $f"
done
for m in softdog hci_vhci; do
  grep -q "^extra/$m.ko:" "$root$k/modules.dep" || fail "modules.dep lacks $m"
done
zcat "$root$k/vmlinuz" > "$root/Image"
[[ $(head -c 60 "$root/Image" | tail -c 4) == ARMd ]] || fail "vmlinuz is not a gzip arm64 Image"
grep -aqF "Linux version $kver " "$root/Image" || fail "vmlinuz banner"
for s in DEVTMPFS DEVTMPFS_MOUNT FHANDLE AUTOFS_FS LTO_CLANG_FULL MODVERSIONS; do
  grep -qx "CONFIG_$s=y" "$root$k/config" || fail "CONFIG_$s is not y"
done
grep -qxF 'CONFIG_LOCALVERSION="-android12-9"' "$root$k/config" || fail "CONFIG_LOCALVERSION"
echo "pkg-kernel: ${rpm##*/} ok"
