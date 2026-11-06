#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blockie-tools.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blockie-tools-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blockie-tools: expected one blockie-tools RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blockie-tools noarch" ]] || { echo "pkg-blockie-tools: name or arch" >&2; exit 1; }
[[ $(rpm -qpl "${rpms[0]}") == /usr/libexec/blockie/blockie-wifi ]] || { echo "pkg-blockie-tools: file list" >&2; exit 1; }
for r in blk-wmt kmod util-linux-core; do
  rpm -qpR "${rpms[0]}" | grep -qx "$r" || { echo "pkg-blockie-tools: no Requires $r" >&2; exit 1; }
done
echo "pkg-blockie-tools: ok"
