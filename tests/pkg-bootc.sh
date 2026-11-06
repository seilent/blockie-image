#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-bootc: $*" >&2; exit 1; }

out=${1:?usage: pkg-bootc.sh <outdir>}
shopt -s nullglob
rpms=("$out"/bootc-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one bootc RPM, found ${#rpms[@]}"
rpm=${rpms[0]}

root=$(mktemp -d)
trap 'rm -rf "${root:?}"' EXIT
rpm2cpio "$rpm" | (cd "$root" && cpio -idm --quiet)
bin=$root/usr/bin/bootc
gen=$root/usr/lib/systemd/system-generators/bootc-systemd-generator
[[ -x $bin && -x $gen ]] || fail "no bootc or bootc-systemd-generator in ${rpm##*/}"
"$bin" --version > /dev/null || fail "bootc --version fails"

if ! err=$(unshare -rm true 2>&1); then
  fail "test harness, not bootc: unshare -rm (a new user namespace) is refused here, for example by AppArmor's restrict_unprivileged_userns, so the missing /proc/1/ns/ipc path cannot be tested: $err"
fi
if ! err=$(unshare -rm bash -c 'mount -t tmpfs none /proc/1/ns' 2>&1); then
  fail "test harness, not bootc: the tmpfs mount over /proc/1/ns is refused in the user namespace, so the missing /proc/1/ns/ipc path cannot be tested: $err"
fi

mkdir -p "$root/gen/normal" "$root/gen/early" "$root/gen/late"
sandbox=$(unshare -rm bash -c '
  caps=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status)
  (( (0x$caps >> 21) & 1 )) || { echo "test harness: no CAP_SYS_ADMIN in the user namespace"; exit 20; }
  mount -t tmpfs none /proc/1/ns
  ! readlink /proc/1/ns/ipc > /dev/null 2>&1 || { echo "test harness: /proc/1/ns/ipc still visible"; exit 21; }
  "$1" --version || exit 13
  PATH=$(dirname "$1"):$PATH "$2" "$3/normal" "$3/early" "$3/late" || exit 14
' bash "$bin" "$gen" "$root/gen" 2>&1) || fail "without /proc/1/ns/ipc (rc $?): $sandbox"

[[ $(rpm -qp --qf '%{NAME} %{VERSION}' "$rpm") == "bootc 1.17.1" ]] || fail "name or version"
release=$(rpm -qp --qf '%{RELEASE}' "$rpm")
[[ $release == *.blockie ]] || fail "release $release has no .blockie suffix"
[[ $(rpm --eval "%{lua: print(rpm.vercmp('1.17.1-$release', '1.17.1-1.fc44'))}") == 1 ]] ||
  fail "1.17.1-$release does not sort above 1.17.1-1.fc44"
echo "pkg-bootc: ${rpm##*/} ok"
