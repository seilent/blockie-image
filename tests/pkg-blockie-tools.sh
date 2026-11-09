#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blockie-tools.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blockie-tools-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blockie-tools: expected one blockie-tools RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blockie-tools $(uname -m)" ]] || { echo "pkg-blockie-tools: name or arch" >&2; exit 1; }
want=$(printf '%s\n' /usr/bin/abctl /usr/bin/blockie-bootctl /usr/libexec/blockie/blockie-blobs \
  /usr/libexec/blockie/blockie-boot-ok /usr/libexec/blockie/blockie-bt /usr/libexec/blockie/blockie-wifi \
  /usr/share/blockie /usr/share/blockie/blobs.d)
[[ $(rpm -qpl "${rpms[0]}" | sort) == "$want" ]] || { echo "pkg-blockie-tools: file list" >&2; exit 1; }
for r in blk-wmt blk-bt kmod util-linux-core; do
  rpm -qpR "${rpms[0]}" | grep -qx "$r" || { echo "pkg-blockie-tools: no Requires $r" >&2; exit 1; }
done
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "${rpms[0]}" | cpio -idm --quiet)
bin=$t/usr/bin/abctl
[[ $(od -A n -t x1 -N 4 "$bin" | tr -d ' ') == 7f454c46 ]] || { echo "pkg-blockie-tools: abctl is not an ELF" >&2; exit 1; }
rc=0
"$bin" > /dev/null 2> "$t/err" || rc=$?
[[ $rc == 2 && $(< "$t/err") == "usage: abctl"* ]] || { echo "pkg-blockie-tools: abctl with no arguments gave rc $rc" >&2; exit 1; }
echo "pkg-blockie-tools: ok"
