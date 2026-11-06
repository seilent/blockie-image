#!/usr/bin/env bash
set -euo pipefail

fail() { echo "bt: $*" >&2; exit 1; }

unit=/usr/lib/systemd/system/blockie-bt.service
rpm -q blk-bt blockie-tools blk-wmt bluez > /dev/null || fail "packages"
for f in blk-bt blockie-bt; do
  [[ -x /usr/libexec/blockie/$f ]] || fail "/usr/libexec/blockie/$f not executable"
done
[[ $(od -A n -t x1 -N 4 /usr/libexec/blockie/blk-bt | tr -d ' ') == 7f454c46 ]] || fail "blk-bt is not an ELF"
[[ $(/usr/libexec/blockie/blk-bt 2>&1 || true) == *"run | stop-post"* ]] || fail "blk-bt has no stop-post"
rpm -q --requires blockie-tools | grep -qx blk-bt || fail "blockie-tools does not require blk-bt"

for l in Requires=blockie-wifi.service After=blockie-wifi.service Before=bluetooth.service \
  ConditionPathExists=/vendor/lib/modules/bt_drv_connac1x.ko ConditionPathExists=/sys/class/net/wlan0 \
  StartLimitIntervalSec=600 StartLimitBurst=3 Type=notify Restart=no \
  ExecStartPre=/usr/libexec/blockie/blockie-bt "ExecStart=/usr/libexec/blockie/blk-bt run" \
  "ExecStopPost=/usr/libexec/blockie/blk-bt stop-post" WantedBy=multi-user.target; do
  grep -qxF "$l" "$unit" || fail "blockie-bt.service lacks $l"
done
[[ $(grep -c '^Restart' "$unit") == 1 ]] || fail "blockie-bt.service has a Restart line other than Restart=no"
! grep -q '^ExecCondition=' "$unit" || fail "blockie-bt.service has ExecCondition=, which runs ExecStopPost= when it skips"
for d in /usr/lib/systemd/system /etc/systemd/system; do
  [[ ! -e $d/blockie-bt.service.d ]] || fail "$d/blockie-bt.service.d overrides the unit"
done
[[ $(readlink -f /etc/systemd/system/multi-user.target.wants/blockie-bt.service) == "$unit" ]] || fail "blockie-bt.service not enabled"
[[ $(readlink -f /etc/systemd/system/bluetooth.target.wants/bluetooth.service) == /usr/lib/systemd/system/bluetooth.service ]] ||
  fail "bluetooth.service not enabled"
echo "bt: ok"
