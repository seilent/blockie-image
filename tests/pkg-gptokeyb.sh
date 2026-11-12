#!/usr/bin/env bash
set -euo pipefail

name=gptokeyb
commit=5b1284e1502548d476aa38e5979b0a8f48cb7b94
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-gptokeyb.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
src=/usr/share/blockie/sources/portmaster/$name
want=$(printf '%s\n' /usr/lib64/blockie-ports /usr/lib64/blockie-ports/gptokeyb "$lic" "$lic/LICENSE.md" \
  /usr/share/blockie/sources /usr/share/blockie/sources/portmaster "$src" "$src/$name-$commit.tar.gz" \
  "$src/no-kill-mode.patch" | LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == GPL-2.0-or-later ]] || fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
bin=$t/usr/lib64/blockie-ports/gptokeyb
grep -q 'GNU GENERAL PUBLIC LICENSE' "$t$lic/LICENSE.md" && grep -q 'Version 2, June 1991' "$t$lic/LICENSE.md" ||
  fail "GPL-2.0 text"
tar -tzf "$t$src/$name-$commit.tar.gz" "$name-$commit/src/gptokeyb.cpp" > /dev/null || fail "source tarball"
grep -q '^-void doKillMode();$' "$t$src/no-kill-mode.patch" || fail "kill mode patch"
case $(uname -m) in
  x86_64) machine="Advanced Micro Devices X86-64" ;;
  aarch64) machine=AArch64 ;;
  *) fail "no machine name for $(uname -m)" ;;
esac
[[ $(readelf -hW "$bin" | sed -n 's/^ *Machine: *//p') == "$machine" ]] || fail "the binary is not for $(uname -m)"
needed=$(readelf -dW "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
for l in libSDL2-2.0.so.0; do
  grep -qxF "$l" <<< "$needed" || fail "gptokeyb does not link $l"
done
for s in pkill pgrep Killing; do
  ! grep -aqF "$s" "$bin" || fail "kill mode left in gptokeyb: $s"
done
grep -aqF -- -sudokill "$bin" || fail "gptokeyb does not take -sudokill"
sections=$(readelf -SW "$bin")
[[ $sections != *" .symtab "* ]] || fail "symbol table not stripped"
[[ $(readelf -dW "$bin") == *"(FLAGS)"*BIND_NOW* ]] || fail "not linked with -z now"
[[ $(readelf -dW "$bin") != *"PATH)"* ]] || fail "rpath or runpath set"
segments=$(readelf -lW "$bin")
[[ $segments == *GNU_RELRO* ]] || fail "no GNU_RELRO"
[[ $(awk '$1 == "GNU_STACK" { print $(NF - 1) }' <<< "$segments") == RW ]] || fail "GNU_STACK is not RW"
echo "pkg-$name: ok"
