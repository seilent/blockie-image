#!/usr/bin/env bash
set -euo pipefail

name=gl4es
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-gl4es.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
dir=/usr/lib64/gl4es
lic=/usr/share/licenses/$name
want=$(printf '%s\n' "$dir" "$dir/libGL.so.1" "$dir/egl" "$dir/egl/libEGL.so.1" "$lic" "$lic/LICENSE" "$lic/THIRD-PARTY" |
  LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "MIT AND LicenseRef-Fedora-Public-Domain" ]] || fail "licence tag"
provides=$(rpm -qp --provides "$rpm")
! grep -qE '^lib(GL|EGL)\.so' <<< "$provides" || fail "provides a GL or EGL library: $(tr '\n' ' ' <<< "$provides")"
requires=$(rpm -qp --requires "$rpm")
! grep -qE '^lib(GL|EGL)\.so' <<< "$requires" || fail "requires a GL or EGL library: $(tr '\n' ' ' <<< "$requires")"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
grep -q 'Permission is hereby granted, free of charge' "$t$lic/LICENSE" && grep -q 'Sebastien Chevalier' "$t$lic/LICENSE" ||
  fail "MIT text"
for w in Chajdas 'Benjamin Dobell' 'Attractive Chaos' 'Brian Paul'; do
  [[ $(grep -c 'Permission is hereby granted' "$t$lic/THIRD-PARTY") == 4 ]] && grep -qF "$w" "$t$lic/THIRD-PARTY" ||
    fail "THIRD-PARTY lacks the notice of $w"
done
case $(uname -m) in
  x86_64) machine="Advanced Micro Devices X86-64" ;;
  aarch64) machine=AArch64 ;;
  *) fail "no machine name for $(uname -m)" ;;
esac
for p in libGL.so.1 egl/libEGL.so.1; do
  l=${p##*/}
  f=$t$dir/$p
  [[ -f $f && ! -L $f ]] || fail "$l is not a file"
  [[ $(readelf -hW "$f" | sed -n 's/^ *Machine: *//p') == "$machine" ]] || fail "$l is not for $(uname -m)"
  [[ $(readelf -dW "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p') == "$l" ]] || fail "$l soname"
  [[ $(readelf -SW "$f") != *" .symtab "* ]] || fail "$l symbol table not stripped"
  [[ $(readelf -dW "$f") == *"(FLAGS)"*BIND_NOW* ]] || fail "$l not linked with -z now"
  [[ $(readelf -dW "$f") != *"PATH)"* ]] || fail "$l rpath or runpath set"
  segments=$(readelf -lW "$f")
  [[ $segments == *GNU_RELRO* ]] || fail "$l no GNU_RELRO"
  [[ $(awk '$1 == "GNU_STACK" { print $(NF - 1) }' <<< "$segments") == RW ]] || fail "$l GNU_STACK is not RW"
done
needed() { readelf -dW "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
grep -qxF libX11.so.6 <<< "$(needed "$t$dir/libGL.so.1")" || fail "libGL.so.1 does not link libX11.so.6"
grep -qxF libGL.so.1 <<< "$(needed "$t$dir/egl/libEGL.so.1")" || fail "libEGL.so.1 does not link libGL.so.1"
! grep -qE '^lib(EGL|GLESv2|GLESv1_CM|mali)\.so' <<< "$(needed "$t$dir/libGL.so.1")" ||
  fail "libGL.so.1 links a GLES or EGL library"
! grep -qE '^lib(EGL|GLESv2|GLESv1_CM|mali)\.so' <<< "$(needed "$t$dir/egl/libEGL.so.1")" ||
  fail "libEGL.so.1 links a GLES or EGL library"
syms=$(readelf --dyn-syms -W "$t$dir/libGL.so.1" | awk '$7 != "UND" { print $8 }')
for s in glXCreateContext glXMakeCurrent glXSwapBuffers glBegin glGetString; do
  grep -qxF "$s" <<< "$syms" || fail "libGL.so.1 does not export $s"
done
syms=$(readelf --dyn-syms -W "$t$dir/egl/libEGL.so.1" | awk '$7 != "UND" { print $8 }')
for s in eglGetDisplay eglBindAPI eglCreateContext; do
  grep -qxF "$s" <<< "$syms" || fail "libEGL.so.1 does not export $s"
done
both=0
for p in libGL.so.1 egl/libEGL.so.1; do
  dsyms=$(readelf --dyn-syms -W "$t$dir/$p")
  core=$(awk '$7 != "UND" && $8 == "eglGetPlatformDisplay" { print $2 }' <<< "$dsyms")
  ext=$(awk '$7 != "UND" && $8 == "eglGetPlatformDisplayEXT" { print $2 }' <<< "$dsyms")
  [[ -n $core && -n $ext ]] || continue
  both=1
  [[ $core != "$ext" ]] || fail "${p##*/} exports eglGetPlatformDisplayEXT as an alias of eglGetPlatformDisplay"
done
(( both )) || fail "no library exports both eglGetPlatformDisplay and eglGetPlatformDisplayEXT"
echo "pkg-$name: ok"
