#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-names test: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
names=$(realpath "${1:-$here/build/pkg-names.sh}")
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT

mkdir -p "$t/spec" "$t/srpm" "$t/none"
printf 'Name: foo\n%%package libs\n%%package -n bar\n' > "$t/spec/foo.spec"
printf 'SRPM_URL=https://kojipkgs.example/packages/bootc/1.17.1/1.fc44/src/bootc-1.17.1-1.fc44.src.rpm\nSRPM_SHA256=%064d\n' 0 \
  > "$t/srpm/SOURCE.env"
printf 'KERNEL_RELEASE=5.10.233-android12-9+\n' > "$t/none/SOURCE.env"

[[ $("$names" "$t/spec" 2>&1) == $'foo\nfoo-libs\nbar' ]] || fail "spec package: $("$names" "$t/spec" 2>&1)"
[[ $("$names" "$t/srpm" 2>&1) == bootc ]] || fail "SRPM_URL package: $("$names" "$t/srpm" 2>&1)"
[[ -z $("$names" "$t/none" 2>&1) ]] || fail "no spec and no SRPM_URL: $("$names" "$t/none" 2>&1)"
echo "pkg-names test: ok"
