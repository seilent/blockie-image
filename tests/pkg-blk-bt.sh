#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blk-bt.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blk-bt-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blk-bt: expected one blk-bt RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blk-bt $(uname -m)" ]] || { echo "pkg-blk-bt: name or arch" >&2; exit 1; }
[[ $(rpm -qpl "${rpms[0]}") == /usr/libexec/blockie/blk-bt ]] || { echo "pkg-blk-bt: file list" >&2; exit 1; }
rpm -qpR "${rpms[0]}" | grep -qx blk-wmt || { echo "pkg-blk-bt: no Requires blk-wmt" >&2; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "${rpms[0]}" | cpio -idm --quiet)
bin=$t/usr/libexec/blockie/blk-bt
[[ $(od -A n -t x1 -N 4 "$bin" | tr -d ' ') == 7f454c46 ]] || { echo "pkg-blk-bt: not an ELF" >&2; exit 1; }
"$bin" > /dev/null 2>&1 && { echo "pkg-blk-bt: no arguments exited 0" >&2; exit 1; }
[[ $("$bin" 2>&1 || true) == *"usage: blk-bt"*"run | stop-post"* ]] || { echo "pkg-blk-bt: no usage text" >&2; exit 1; }
! grep -qa 'FAKE_TRACE' "$bin" || { echo "pkg-blk-bt: the test seam build was packaged" >&2; exit 1; }
echo "pkg-blk-bt: ok"
