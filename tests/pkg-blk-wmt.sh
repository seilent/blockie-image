#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: pkg-blk-wmt.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blk-wmt-*.rpm)
(( ${#rpms[@]} == 1 )) || { echo "pkg-blk-wmt: expected one blk-wmt RPM, found ${#rpms[@]}" >&2; exit 1; }
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blk-wmt $(uname -m)" ]] || { echo "pkg-blk-wmt: name or arch" >&2; exit 1; }
[[ $(rpm -qpl "${rpms[0]}") == /usr/libexec/blockie/blk-wmt ]] || { echo "pkg-blk-wmt: file list" >&2; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "${rpms[0]}" | cpio -idm --quiet)
bin=$t/usr/libexec/blockie/blk-wmt
[[ $(od -A n -t x1 -N 4 "$bin" | tr -d ' ') == 7f454c46 ]] || { echo "pkg-blk-wmt: not an ELF" >&2; exit 1; }
"$bin" > /dev/null 2>&1 && { echo "pkg-blk-wmt: no arguments exited 0" >&2; exit 1; }
[[ $("$bin" 2>&1 || true) == *"usage: blk-wmt"* ]] || { echo "pkg-blk-wmt: no usage text" >&2; exit 1; }
echo "pkg-blk-wmt: ok"
