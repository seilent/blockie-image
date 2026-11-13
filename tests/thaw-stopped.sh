#!/usr/bin/env bash
set -u

[[ ! -e /run/.containerenv ]] || { echo "thaw-stopped: needs a user systemd manager, not a container" >&2; exit 2; }
systemctl --user show -P Version > /dev/null 2>&1 || { echo "thaw-stopped: no user systemd manager" >&2; exit 2; }
slice=thaw-stopped-$$.slice
scope=thaw-stopped-$$.scope
trap 'systemctl --user stop "$scope" 2> /dev/null; systemctl --user stop "$slice" 2> /dev/null' EXIT

systemd-run --user --scope --quiet --unit="${scope%.scope}" --slice="$slice" -- sleep 60 &
pid=$!
for _ in $(seq 50); do
  [[ $(systemctl --user show -P ActiveState "$scope") == active ]] && break
  sleep 0.1
done
state() { sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$pid/status"; }
systemctl --user kill --signal=SIGSTOP "$scope"
sleep 0.2
s0=$(state)
systemctl --user freeze "$slice"
f1=$(systemctl --user show -P FreezerState "$slice")
systemctl --user thaw "$slice"
f2=$(systemctl --user show -P FreezerState "$slice")
sleep 0.2
s2=$(state)
t0=${EPOCHREALTIME//[!0-9]/}
systemctl --user stop "$scope"
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
wait "$pid"
a=$(systemctl --user show -P ActiveState "$scope")
echo "systemd $(systemctl --user show -P Version): stopped $s0, frozen $f1, thawed $f2, after the thaw $s2, stop $ms ms, $a"
if [[ $s0 == T && $f1 == frozen && $f2 == running && $s2 == T && $a != active ]] && ((ms < 1000)); then
  echo "ok   T4: a freeze and thaw of the slice leaves the stopped scope at State T, and its stop ends it at once"
  exit 0
fi
echo "FAIL T4: a freeze and thaw of the slice leaves the stopped scope at State T, and its stop ends it at once"
exit 1
