#!/usr/bin/env bash
set -euo pipefail

name=gptokeyb2
commit=647b46f4c49ea7d379fc67126bbfe2910d83e2d9
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-gptokeyb2.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
arch=$(uname -m)
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $arch" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
src=/usr/share/blockie/sources/portmaster/$name
dir=/usr/lib64/blockie-ports
want=$(printf '%s\n' "$dir" "$dir/gptokeyb2" "$dir/libinterpose.$arch.so" "$lic" "$lic/LICENSE.txt" "$lic/LICENSE-inih.txt" \
  /usr/share/blockie/sources /usr/share/blockie/sources/portmaster "$src" "$src/$name-$commit.tar.gz" \
  "$src/no-kill-mode.patch" | LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "GPL-2.0-or-later AND BSD-3-Clause" ]] || fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
bin=$t$dir/gptokeyb2
so=$t$dir/libinterpose.$arch.so
grep -q 'Version 2, June 1991' "$t$lic/LICENSE.txt" || fail "GPL-2.0 text"
grep -q 'New BSD license' "$t$lic/LICENSE-inih.txt" || fail "inih licence text"
tar -tzf "$t$src/$name-$commit.tar.gz" "$name-$commit/src/state.c" "$name-$commit/interpose/interpose.c" > /dev/null ||
  fail "source tarball"
grep -q '^-bool process_kill();$' "$t$src/no-kill-mode.patch" || fail "kill mode patch"
case $arch in
  x86_64) machine="Advanced Micro Devices X86-64" ;;
  aarch64) machine=AArch64 ;;
  *) fail "no machine name for $arch" ;;
esac
for f in "$bin" "$so"; do
  [[ $(readelf -hW "$f" | sed -n 's/^ *Machine: *//p') == "$machine" ]] || fail "${f#"$t"} is not for $arch"
  [[ $(readelf -SW "$f") != *" .symtab "* ]] || fail "${f#"$t"}: symbol table not stripped"
  [[ $(readelf -dW "$f") == *"(FLAGS)"*BIND_NOW* ]] || fail "${f#"$t"}: not linked with -z now"
  [[ $(readelf -dW "$f") != *"PATH)"* ]] || fail "${f#"$t"}: rpath or runpath set"
  [[ $(readelf -lW "$f") == *GNU_RELRO* ]] || fail "${f#"$t"}: no GNU_RELRO"
done
[[ $(readelf -dW "$so" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p') == "libinterpose.$arch.so" ]] || fail "libinterpose soname"
needed=$(readelf -dW "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
for l in "libinterpose.$arch.so" libSDL2-2.0.so.0; do
  grep -qxF "$l" <<< "$needed" || fail "gptokeyb2 does not link $l"
done
! grep -qxF libinterpose.so <<< "$needed" || fail "gptokeyb2 still links libinterpose.so"
for s in pgrep 'kill -9' 'killed successfully'; do
  ! grep -aqF "$s" "$bin" || fail "kill mode left in gptokeyb2: $s"
done
v=$(env LD_PRELOAD="$so" "$bin" -1 -k -Z -X -P -sudokill app -v) || fail "gptokeyb2 refuses the script flags"
[[ $v == *"gptokeyb2 2.00.03" ]] || fail "gptokeyb2 -v: $v"
echo "pkg-$name: ok"
