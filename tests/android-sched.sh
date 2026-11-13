#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
lx=/usr/libexec/blockie
[[ -x $lx/blockie-android-sched ]] || lx=$here/../system_files/usr/libexec/blockie
sys=/usr/lib/systemd/system
[[ -f $sys/blockie-android-sched.service ]] || sys=$here/../system_files/usr/lib/systemd/system
schema=/usr/share/blockie/schema.d/20-android.json
[[ -f $schema ]] || schema=$here/../system_files/usr/share/blockie/schema.d/20-android.json
unit=$sys/blockie-android-sched.service
t=$(mktemp -d "${TMPDIR:-/tmp}/android-sched.XXXXXX")
fails=0
trap 'rm -rf "${t:?}"' EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

[[ -x $lx/blockie-android-sched && -x $lx/blockie-android-sched-restore ]]
res $? "the service and its ExecStopPost script are installed executable"

ok=0
want=(
  'After=waydroid-container.service' 'PartOf=waydroid-container.service' 'StartLimitIntervalSec=60'
  'StartLimitBurst=3' 'Type=notify' 'WatchdogSec=10' 'TimeoutAbortSec=2s' 'TimeoutStopSec=5s' 'Restart=on-failure'
  'Nice=-5' 'RuntimeDirectory=blockie-android-sched' 'RuntimeDirectoryPreserve=yes'
  'ExecStartPre=/usr/libexec/blockie/blockie-android-sched orig' 'ExecStart=/usr/libexec/blockie/blockie-android-sched'
  'ExecStopPost=/usr/libexec/blockie/blockie-android-sched-restore' 'WantedBy=waydroid-container.service'
)
for l in "${want[@]}"; do
  grep -qxF "$l" "$unit" || { ok=1; echo "  no '$l'"; }
done
[[ $(grep -c '^ExecStopPost=' "$unit") == 1 && $(grep -c '^ExecStartPre=' "$unit") == 1 ]] || { ok=1; echo "  one ExecStartPre and one ExecStopPost"; }
res $ok "unit: notify with a 10 s watchdog, 2 s abort and 5 s stop timeouts, 3 starts per 60 s, Nice -5, orig before the start, the restore script after the stop, ordered after, part of and wanted by waydroid-container"

if [[ $sys == /usr/lib/systemd/system ]]; then
  [[ -L /etc/systemd/system/waydroid-container.service.wants/blockie-android-sched.service ]]
  res $? "unit: enabled into waydroid-container.service.wants by the preset"
fi

python3 - "$schema" << 'PY'
import json, sys
k = json.load(open(sys.argv[1]))["keys"]["android.perf"]
sys.exit(0 if (k["type"] == "s" and k["default"] == "policy" and k["enum"] == ["policy", "off"]
               and k["group"] == "android" and k["label"] == "Android performance") else 1)
PY
res $? "schema: android.perf is a string, default policy, enum policy or off, group android, labelled Android performance"

SCHED_BIN=$lx/blockie-android-sched RESTORE_BIN=${RESTORE_BIN:-$lx/blockie-android-sched-restore} T=$t \
  timeout -k 10 600 python3 "$here/android-sched.py" > "$t/py.out" 2>&1
rc=$?
cat "$t/py.out"
n=$(grep -c '^FAIL ' "$t/py.out")
fails=$((fails + n))
(( rc == 0 || n > 0 )) || { echo "FAIL python cases ended with rc $rc"; fails=$((fails + 1)); }

if (( fails )); then
  echo "android-sched: $fails failed"
  exit 1
fi
echo "android-sched: ok"
