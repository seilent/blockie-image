#!/usr/bin/env bash
set -euo pipefail

name=libjpeg8
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libjpeg8.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
arch=$(uname -m)
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $arch" ]] || fail "name or arch"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "IJG AND BSD-3-Clause AND Zlib" ]] || fail "licence tag"
dir=/usr/lib64/blockie-ports
c=$dir/compat
lic=/usr/share/licenses/$name
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
real=$(readlink "$t$c/libjpeg.so.8") || fail "libjpeg.so.8 is not a link"
[[ $real =~ ^libjpeg\.so\.8\.[0-9]+\.[0-9]+$ && -f $t$c/$real && ! -L $t$c/$real ]] || fail "libjpeg.so.8 links to $real"
want=$(printf '%s\n' "$dir" "$c" "$c/libjpeg.so.8" "$c/$real" "$lic" "$lic/LICENSE.md" "$lic/README.ijg" | LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
provides=$(rpm -qp --provides "$rpm")
! grep -qE '^libjpeg\.so' <<< "$provides" || fail "provides a libjpeg name: $(tr '\n' ' ' <<< "$provides")"
grep -q 'Independent JPEG Group' "$t$lic/README.ijg" || fail "IJG text"
grep -q 'Modified (3-clause) BSD License' "$t$lic/LICENSE.md" && grep -q 'zlib License' "$t$lic/LICENSE.md" ||
  fail "BSD-3-Clause and zlib texts"
f=$t$c/$real
case $arch in
  x86_64) machine="Advanced Micro Devices X86-64" ;;
  aarch64) machine=AArch64 ;;
  *) fail "no machine name for $arch" ;;
esac
[[ $(readelf -hW "$f" | sed -n 's/^ *Machine: *//p') == "$machine" ]] || fail "$real is not for $arch"
[[ $(readelf -dW "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p') == libjpeg.so.8 ]] || fail "soname"
[[ $(readelf -dW "$f") != *"PATH)"* ]] || fail "rpath or runpath set"
[[ $(readelf -dW "$f") == *"(FLAGS)"*BIND_NOW* ]] || fail "not linked with -z now"
[[ $(readelf -SW "$f") != *" .symtab "* ]] || fail "symbol table not stripped"
readelf -VW "$f" | grep -qE 'Name: LIBJPEG_8\.0$' || fail "no LIBJPEG_8.0 version node"
sym=$(readelf --dyn-syms -W "$f" | grep -E ' jpeg_CreateDecompress@' || :)
grep -qE ' jpeg_CreateDecompress@{1,2}LIBJPEG_8\.0( |$)' <<< "$sym" || fail "jpeg_CreateDecompress is not LIBJPEG_8.0: ${sym:-absent}"
echo "pkg-$name: ok"
