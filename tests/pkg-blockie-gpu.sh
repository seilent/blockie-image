#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blockie-gpu.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blockie-gpu-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blockie-gpu: expected one blockie-gpu RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blockie-gpu noarch" ]] || { echo "pkg-blockie-gpu: name or arch" >&2; exit 1; }
want=$(printf '%s\n' /usr/lib/udev/rules.d/60-blockie-gpu.rules /usr/libexec/blockie/blockie-gpufreq \
  /usr/share/blockie/blobs.d/rk-g29p1.conf /usr/share/blockie/vulkan /usr/share/blockie/vulkan/rk-g29p1.json)
[[ $(rpm -qpl "${rpms[0]}" | sort) == "$want" ]] || { echo "pkg-blockie-gpu: file list" >&2; exit 1; }
for r in blockie-tools systemd-udev; do
  rpm -qpR "${rpms[0]}" | grep -qx "$r" || { echo "pkg-blockie-gpu: no Requires $r" >&2; exit 1; }
done
echo "pkg-blockie-gpu: ok"
