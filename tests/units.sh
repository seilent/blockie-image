#!/usr/bin/env bash
set -euo pipefail

fail() { echo "units: $*" >&2; exit 1; }

runtime=(blockie-adbd.service blockie-beat.service blockie-getty.service blockie-live.service blockie-tick.service
  blockie-tick.timer blockie-end.service blockie-feed-finalize.service)
for u in "${runtime[@]}"; do
  for d in /usr/lib/systemd/system /etc/systemd/system; do
    [[ ! -e $d/$u && ! -e $d/$u.d ]] || fail "$d/$u or $u.d has the name of a ramdisk runtime unit"
  done
done
for d in /usr/lib/udev/rules.d /etc/udev/rules.d; do
  [[ ! -e $d/99-blockie-emmc.rules ]] || fail "$d/99-blockie-emmc.rules has the name of the ramdisk eMMC rule"
done
cycles=$(systemd-analyze verify --man=no default.target 2>&1 | grep 'ordering cycle' | head -n 3 || true)
[[ -z $cycles ]] || fail "ordering cycles in the default.target transaction: $cycles"

units=()
for u in /usr/lib/systemd/system/blockie-*; do
  [[ -f $u ]] && units+=("$u")
done
if (( ${#units[@]} == 0 )); then
  echo "units: ok, no blockie units yet"
  exit 0
fi
systemd-analyze verify --man=no "${units[@]}" || fail "systemd-analyze verify"
echo "units: ok ${#units[@]}"
