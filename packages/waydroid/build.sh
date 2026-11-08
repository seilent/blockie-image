#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
srpm=/srpm/${SRPM_URL##*/}
echo "$SRPM_SHA256  $srpm" | sha256sum -c --quiet -
top=/var/tmp/waydroid-build
mkdir -p "$top"
rpm -i --define "_topdir $top" "$srpm"
patches=(namespaces-includes.patch no-debugfs-bind.patch net-filter-ipforward.patch lxc-debug-log.patch container-session.patch
  dbus-policy.patch)
for p in "${patches[@]}"; do
  cp "$src/$p" "$top/SOURCES/"
done
spec=$top/SPECS/waydroid.spec
sed -i -e 's/^\(Release: *1%{?dist}\)$/\1.blockie/' \
  -e '/^Patch1: *mount-secontext\.patch$/d' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch3:         namespaces-includes.patch' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch4:         no-debugfs-bind.patch' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch5:         net-filter-ipforward.patch' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch6:         lxc-debug-log.patch' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch7:         container-session.patch' \
  -e '/^Patch2: *no-apparmor\.patch$/a Patch8:         dbus-policy.patch' \
  -e '/^Requires: *gtk3$/d' \
  -e '/^Requires: *nftables$/d' \
  -e '/^Requires: *(%{name}-selinux = %{version}-%{release} if selinux-policy-%{selinuxtype})$/d' \
  -e '/^Requires: *dnsmasq$/a Requires:       iptables-legacy' \
  -e '/^%make_install /s/ USE_DBUS_ACTIVATION=1 / USE_DBUS_ACTIVATION=0 /' \
  -e '\#^%{_datadir}/dbus-1/system-services/id\.waydro\.Container\.service$#d' \
  -e '/^waydroid upgrade -o > \/dev\/null || :$/d' "$spec"
check() { grep -qx -- "$1" "$spec" || { echo "build.sh: $2" >&2; exit 1; }; }
absent() { ! grep -q -- "$1" "$spec" || { echo "build.sh: $2" >&2; exit 1; }; }
check 'Release: *1%{?dist}\.blockie' "Release not rewritten"
check 'Patch3: *namespaces-includes\.patch' "Patch3 not added"
check 'Patch4: *no-debugfs-bind\.patch' "Patch4 not added"
check 'Patch5: *net-filter-ipforward\.patch' "Patch5 not added"
check 'Patch6: *lxc-debug-log\.patch' "Patch6 not added"
check 'Patch7: *container-session\.patch' "Patch7 not added"
check 'Patch8: *dbus-policy\.patch' "Patch8 not added"
check 'Requires: *iptables-legacy' "iptables-legacy not required"
check '%make_install .* USE_DBUS_ACTIVATION=0 .*' "D-Bus activation not turned off"
absent '^Patch1:' "mount-secontext.patch still applied"
absent '^Requires: *\(gtk3\|nftables\)$' "gtk3 or nftables still required"
absent '^Requires: *(%{name}-selinux' "waydroid-selinux still required"
absent 'system-services/id\.waydro\.Container\.service' "the activation file is still listed"
absent '^waydroid upgrade' "%post still runs waydroid upgrade"
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
