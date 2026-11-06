#!/usr/bin/env bash
set -u

unit=$(readlink -f "${BT_UNIT:-$(dirname "$0")/../system_files/usr/lib/systemd/system/blockie-bt.service}")
[[ $(id -u) != 0 ]] || { echo "bt-unit: refuses to run as root"; exit 1; }
systemctl --user show-environment > /dev/null 2>&1 || { echo "bt-unit: needs a systemd user manager"; exit 1; }
rt=${XDG_RUNTIME_DIR:?}/systemd/user
id=bt-unit-$$
bt=$id-bt.service
wifi=$id-wifi.service
top=$(mktemp -d "${TMPDIR:-/tmp}/bt-unit.XXXXXX")
fails=0

cleanup() {
  systemctl --user stop "$bt" "$wifi" > /dev/null 2>&1
  rm -f "${rt:?}/$bt" "${rt:?}/$wifi"
  systemctl --user daemon-reload
  systemctl --user reset-failed "$bt" "$wifi" > /dev/null 2>&1
  rm -rf "${top:?}"
}
trap cleanup EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

printf '#!/bin/sh\necho pre >> %s/log\n' "$top" > "$top/pre"
cat > "$top/post" << EOF
#!/bin/sh
echo "post \$1 res=\$SERVICE_RESULT" >> $top/log
EOF
cat > "$top/wifi" << EOF
#!/bin/sh
exit "\$(cat $top/wifi.rc)"
EOF
cat > "$top/run" << EOF
#!/usr/bin/env python3
import os, signal, socket, time
with open("$top/log", "a") as f:
    f.write("run\n")
a = os.environ["NOTIFY_SOCKET"]
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(b"READY=1", "\0" + a[1:] if a.startswith("@") else a)
if open("$top/run.mode").read().strip() == "crash":
    os.kill(os.getpid(), signal.SIGKILL)
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
while True:
    time.sleep(1)
EOF
chmod 755 "$top/pre" "$top/post" "$top/wifi" "$top/run"

mkdir -p "$rt"
sed -e "s|/usr/libexec/blockie/blockie-bt|$top/pre|" -e "s|/usr/libexec/blockie/blk-bt run|$top/run|" \
  -e "s|/usr/libexec/blockie/blk-bt stop-post|$top/post stop-post|" -e "s|blockie-wifi\.service|$wifi|g" \
  -e "s|/sys/class/net/wlan0|$top/wlan0|" -e "s|/vendor/lib/modules/bt_drv_connac1x\.ko|$top/bt_drv_connac1x.ko|" \
  "$unit" > "$rt/$bt"
! grep -qE '/usr/libexec|/sys/|/vendor/|blockie-wifi' "$rt/$bt"
res $? "every path and the Wi-Fi unit of the real unit are replaced"
printf '[Unit]\nConditionPathExists=%s/wmtcfg\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=%s/wifi\n' \
  "$top" "$top" > "$rt/$wifi"
systemctl --user daemon-reload

case_() {
  systemctl --user stop "$bt" "$wifi" > /dev/null 2>&1
  systemctl --user reset-failed "$bt" "$wifi" > /dev/null 2>&1
  rm -f "$top/wmtcfg" "$top/wlan0" "$top/bt_drv_connac1x.ko" "$top/log"
  : > "$top/log"
  echo "$1" > "$top/wifi.rc"
  echo "$2" > "$top/run.mode"
  shift 2
  for f in "$@"; do
    : > "$top/$f"
  done
  timeout 20 systemctl --user start "$bt" > /dev/null 2>&1
}

log() {
  tr '\n' ' ' < "$top/log" | sed 's/ $//'
}

case_ 1 ready wmtcfg wlan0 bt_drv_connac1x.ko
[ -z "$(log)" ] && [ "$(systemctl --user show -p ActiveState --value "$bt")" != active ]
res $? "a failed Wi-Fi unit: the bridge never starts, no ExecStartPre, ExecStart or ExecStopPost ($(log))"
case_ 0 ready bt_drv_connac1x.ko
[ -z "$(log)" ]
res $? "a Wi-Fi unit skipped by its condition and no wlan0: nothing runs ($(log))"
case_ 0 ready wmtcfg bt_drv_connac1x.ko
[ -z "$(log)" ] && [ "$(systemctl --user show -p ConditionResult --value "$bt")" = no ]
res $? "Wi-Fi up but no wlan0: skipped by the condition, no ExecStopPost ($(log))"
case_ 0 ready wmtcfg wlan0
[ -z "$(log)" ]
res $? "no Bluetooth module: skipped, no ExecStopPost ($(log))"
case_ 0 ready wmtcfg wlan0 bt_drv_connac1x.ko
up=$(systemctl --user show -p ActiveState --value "$bt")
systemctl --user stop "$bt"
[ "$up" = active ] && [ "$(log)" = "pre run post stop-post res=success" ]
res $? "Wi-Fi up and wlan0: starts after READY, a clean stop runs stop-post with success ($(log))"
case_ 0 crash wmtcfg wlan0 bt_drv_connac1x.ko
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(systemctl --user show -p ActiveState --value "$bt") == failed ]] && break
  sleep 0.5
done
[ "$(log)" = "pre run post stop-post res=signal" ] && [ "$(systemctl --user show -p NRestarts --value "$bt")" = 0 ]
res $? "a crash after READY: stop-post once with signal, no restart ($(log))"

echo "$fails failures"
[[ $fails == 0 ]]
