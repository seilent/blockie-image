#!/usr/bin/env bash
set -euo pipefail

name=box64
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-box64.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{VERSION} %{ARCH}' "$rpm") == "$name 0.4.4 aarch64" ]] || fail "name, version or arch"
lic=/usr/share/licenses/$name
rc=/etc/box64.box64rc
want=$(printf '%s\n' /usr/bin/box64 /usr/bin/box64-sd845 "$rc" "$lic" "$lic/LICENSE" "$lic/THIRD-PARTY" | LC_ALL=C sort)
files=$(rpm -qpl "$rpm" | LC_ALL=C sort)
[[ $files == "$want" ]] || fail "file list: $(tr '\n' ' ' <<< "$files")"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "MIT AND HPND-sell-variant AND Zlib AND Unlicense" ]] || fail "licence tag"
! grep -q binfmt <<< "$files" || fail "a binfmt file is in the package"
requires=$(rpm -qp --requires "$rpm")
! grep -q '^box64-data' <<< "$requires" || fail "requires box64-data"
[[ $(rpm -qp --configfiles "$rpm") == "$rc" ]] || fail "config files: $(rpm -qp --configfiles "$rpm" | tr '\n' ' ')"
flags=$(rpm -qp --qf '[%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$rpm" | awk -v f="$rc" '$2 == f { print $1 }')
[[ $flags == *c* && $flags == *n* ]] || fail "$rc is not config(noreplace): $flags"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
grep -q 'Permission is hereby granted, free of charge' "$t$lic/LICENSE" && grep -q 'Copyright (c) 2020 ptitSeb' "$t$lic/LICENSE" ||
  fail "MIT text"
for w in 'Pyry Haulos' 'SciTech Software' 'Attractive Chaos' 'unlicense.org' 'Sam Lantinga' 'Joakim Sindholt'; do
  grep -qF "$w" "$t$lic/THIRD-PARTY" || fail "THIRD-PARTY lacks the notice of $w"
done
grep -qxF '# System-wide .box64rc' "$t$rc" && grep -qxF '[*setup*]' "$t$rc" || fail "$rc is not upstream's box64rc"
while IFS= read -r -d '' f; do
  [[ $(head -c 4 "$f" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] || continue
  [[ $(readelf -hW "$f" | sed -n 's/^ *Machine: *//p') == AArch64 ]] || fail "${f#"$t"} is not an AArch64 ELF"
done < <(find "$t" -type f -print0)
allowed=$(printf '%s\n' libc.so.6 libm.so.6 libresolv.so.2 libgcc_s.so.1 ld-linux-aarch64.so.1 libdl.so.2 \
  libpthread.so.0 librt.so.1 libutil.so.1)
for b in box64 box64-sd845; do
  f=$t/usr/bin/$b
  [[ -f $f && ! -L $f ]] || fail "$b is not a file"
  [[ $(readelf -hW "$f" | sed -n 's/^ *Machine: *//p') == AArch64 ]] || fail "$b is not for aarch64"
  [[ $(readelf -SW "$f") != *" .symtab "* ]] || fail "$b symbol table not stripped"
  [[ $(readelf -dW "$f") == *"(FLAGS)"*BIND_NOW* ]] || fail "$b not linked with -z now"
  [[ $(readelf -dW "$f") != *"PATH)"* ]] || fail "$b rpath or runpath set"
  segments=$(readelf -lW "$f")
  [[ $segments == *GNU_RELRO* ]] || fail "$b no GNU_RELRO"
  [[ $(awk '$1 == "GNU_STACK" { print $(NF - 1) }' <<< "$segments") == RW ]] || fail "$b GNU_STACK is not RW"
  needed=$(readelf -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  grep -qxF libc.so.6 <<< "$needed" || fail "$b does not link libc.so.6"
  while IFS= read -r l; do
    grep -qxF "$l" <<< "$allowed" || fail "$b links $l"
  done <<< "$needed"
  grep -aqF 'Box64 arm64 v0.4.4 nogit' "$f" || fail "$b is not the 0.4.4 ARM64 dynarec build"
done
! cmp -s "$t/usr/bin/box64" "$t/usr/bin/box64-sd845" || fail "box64-sd845 is the generic build"
echo "pkg-$name: ok"
