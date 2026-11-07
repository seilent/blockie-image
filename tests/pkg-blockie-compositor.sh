#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blockie-compositor.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blockie-compositor-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blockie-compositor: expected one blockie-compositor RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blockie-compositor aarch64" ]] || { echo "pkg-blockie-compositor: name or arch" >&2; exit 1; }
want=$(printf '%s\n' /usr/lib/systemd/user/blockie-.service.d /usr/lib/systemd/user/blockie-.service.d/50-blockie-gpu.conf \
  /usr/lib64/blockie /usr/lib64/blockie/libblockie-glfinish.so /usr/lib64/blockie/libblockie-nocursor.so \
  /usr/libexec/blockie/blockie-compositor /usr/share/blockie/labwc /usr/share/blockie/labwc/autostart /usr/share/blockie/labwc/rc.xml \
  /usr/share/icons/blockie-none /usr/share/icons/blockie-none/cursors /usr/share/icons/blockie-none/cursors/blockie-none | LC_ALL=C sort)
[[ $(rpm -qpl "${rpms[0]}" | LC_ALL=C sort) == "$want" ]] || { echo "pkg-blockie-compositor: file list" >&2; exit 1; }
rpm -qpR "${rpms[0]}" | grep -qx labwc || { echo "pkg-blockie-compositor: no Requires labwc" >&2; exit 1; }
echo "pkg-blockie-compositor: ok"
