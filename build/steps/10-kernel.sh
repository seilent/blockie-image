#!/usr/bin/env bash
set -euo pipefail

mapfile -t old < <(rpm -qa --qf '%{NAME}\n' 'kernel*' | sort -u)
if (( ${#old[@]} )); then
  dnf -y remove "${old[@]}"
fi
rm -rf /usr/lib/modules/*

rpms=()
for f in /rpms/blockie-kernel-*.rpm; do
  [[ -f $f && $f != *.src.rpm ]] && rpms+=("$f")
done
[[ ${#rpms[@]} -eq 1 ]] || { echo "10-kernel: expected one blockie-kernel rpm in /rpms" >&2; exit 1; }
read -ra opts <<< "${BLOCKIE_DNF_OPTS:-}"
dnf -y "${opts[@]}" install "${rpms[0]}"

kver=$(rpm -qlp "${rpms[0]}" | sed -n 's|^/usr/lib/modules/\([^/]*\)$|\1|p')
mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && ${mods[0]} == "/usr/lib/modules/$kver" && -n $kver ]] || { echo "10-kernel: modules dirs ${mods[*]}, rpm kver $kver" >&2; exit 1; }
[[ -f /usr/lib/modules/$kver/vmlinuz ]] || { echo "10-kernel: no vmlinuz in /usr/lib/modules/$kver" >&2; exit 1; }
