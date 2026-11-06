#!/usr/bin/env bash
set -euo pipefail

fail() { echo "wifi: $*" >&2; exit 1; }

rpm -q blk-wmt blockie-tools wpa_supplicant NetworkManager-wifi iw wireless-regdb > /dev/null || fail "packages"
for f in blk-wmt blockie-wifi; do
  [[ -x /usr/libexec/blockie/$f ]] || fail "/usr/libexec/blockie/$f not executable"
done
[[ $(od -A n -t x1 -N 4 /usr/libexec/blockie/blk-wmt | tr -d ' ') == 7f454c46 ]] || fail "blk-wmt is not an ELF"
[[ -f /usr/lib/firmware/regulatory.db && -f /usr/lib/firmware/regulatory.db.p7s ]] || fail "regulatory.db"
[[ $(stat -L -c %d:%i /lib/firmware/regulatory.db) == $(stat -L -c %d:%i /usr/lib/firmware/regulatory.db) ]] ||
  fail "/lib/firmware/regulatory.db is not the /usr/lib one"
compgen -G '/usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so' > /dev/null || fail "NetworkManager wifi plugin"

for u in blockie-wifi.service blockie-regdom.service; do
  [[ $(readlink -f "/etc/systemd/system/multi-user.target.wants/$u") == "/usr/lib/systemd/system/$u" ]] ||
    fail "$u not enabled"
  grep -qx 'Before=.*NetworkManager.service.*' "/usr/lib/systemd/system/$u" || fail "$u not before NetworkManager"
done
grep -qx 'After=blockie-wifi.service' /usr/lib/systemd/system/blockie-regdom.service || fail "regdom not after wifi"
grep -qx 'ExecStart=/usr/bin/iw reg set JP' /usr/lib/systemd/system/blockie-regdom.service || fail "regdom country"
grep -qxF "ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do iw reg get | awk \"/^global/ { g = 1; next } g && /^country / { print; exit }\" | grep -q \"^country JP:\" && exit 0; sleep 0.5; done; exit 1'" \
  /usr/lib/systemd/system/blockie-regdom.service ||
  fail "regdom does not check the country"
for l in RefuseManualStop=yes IgnoreOnIsolate=yes RemainAfterExit=yes ConditionPathIsDirectory=/run/blockie TimeoutStartSec=600; do
  grep -qxF "$l" /usr/lib/systemd/system/blockie-wifi.service || fail "blockie-wifi.service lacks $l"
done
! grep -q '^RuntimeDirectory=' /usr/lib/systemd/system/blockie-wifi.service || fail "blockie-wifi.service would remove /run/blockie"
for d in /etc/NetworkManager/system-connections /usr/lib/NetworkManager/system-connections; do
  [[ ! -d $d ]] || [[ -z $(find "$d" -mindepth 1 -print -quit) ]] || fail "$d is not empty"
done
echo "wifi: ok"
