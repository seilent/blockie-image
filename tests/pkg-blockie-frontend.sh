#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-blockie-frontend: $*" >&2; exit 1; }

out=${1:?usage: pkg-blockie-frontend.sh <outdir>}
shopt -s nullglob
rpms=("$out"/blockie-frontend-*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one blockie-frontend RPM, found ${#rpms[@]}"
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "${rpms[0]}") == "blockie-frontend aarch64" ]] || fail "name or arch"
lic=/usr/share/licenses/blockie-frontend
fonts=/usr/share/blockie/fonts
want=$(printf '%s\n' /usr/libexec/blockie/blockie-frontend /usr/lib/systemd/user/blockie-frontend.service "$fonts" \
  "$fonts/selawk.ttf" "$fonts/selawkb.ttf" "$fonts/selawkl.ttf" "$fonts/selawksl.ttf" "$lic/Selawik-LICENSE.txt" "$lic/sqlite-NOTICE" "$lic" "$lic/LICENSE" "$lic/fribidi-COPYING" "$lic/harfbuzz-COPYING" \
  "$lic/libspng-LICENSE" "$lic/qrcodegen.h" "$lic/stb_truetype.h" "$lic/zlib-LICENSE" | LC_ALL=C sort)
[[ $(rpm -qpl "${rpms[0]}" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "${rpms[0]}" | tr '\n' ' ')"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "${rpms[0]}" | cpio -idm --quiet)
bin=$t/usr/libexec/blockie/blockie-frontend
unit=$t/usr/lib/systemd/user/blockie-frontend.service
modes=$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "${rpms[0]}")
grep -qxF -- '-rwxr-xr-x /usr/libexec/blockie/blockie-frontend' <<< "$modes" || fail "binary mode"
grep -qxF -- '-rw-r--r-- /usr/lib/systemd/user/blockie-frontend.service' <<< "$modes" || fail "unit mode"
grep -qx 'ExecStart=/usr/libexec/blockie/blockie-frontend' "$unit" || fail "unit ExecStart is not the binary"
grep -qx 'Slice=blockie-emulation.slice' "$unit" || fail "unit is not in blockie-emulation.slice"
! grep -q '^\[Install\]' "$unit" || fail "unit has an [Install] section"
[[ $(head -c 4 "$bin" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] || fail "blockie-frontend is not ELF"
[[ $(od -An -tx1 -j18 -N2 "$bin" | tr -d ' \n') == b700 ]] || fail "blockie-frontend is not aarch64"
hdr=$(LC_ALL=C readelf -hW "$bin")
dyn=$(LC_ALL=C readelf -dW "$bin")
phdr=$(LC_ALL=C readelf -lW "$bin")
syms=$(LC_ALL=C readelf --dyn-syms -W "$bin")
grep -Eq '^ +Type: +DYN ' <<< "$hdr" || fail "blockie-frontend is not ET_DYN"
grep -Eq '\(FLAGS_1\) +Flags:.* PIE( |$)' <<< "$dyn" || fail "blockie-frontend lacks the PIE flag"
grep -Eq '\(FLAGS\) +.*BIND_NOW' <<< "$dyn" || fail "blockie-frontend lacks BIND_NOW"
grep -Eq '^ +GNU_RELRO ' <<< "$phdr" || fail "blockie-frontend lacks GNU_RELRO"
grep -Eq ' __[A-Za-z0-9_]+_chk(@| |$)' <<< "$syms" || fail "blockie-frontend has no fortified __*_chk call"
grep -q 'Additional permission under GNU GPL version 3 section 7' "$t$lic/LICENSE" || fail "LICENSE lacks the additional permission"
reqs=$(rpm -qpR "${rpms[0]}")
grep -q '^libwayland-client\.so' <<< "$reqs" || fail "no libwayland-client requirement"
grep -q '^libxkbcommon\.so' <<< "$reqs" || fail "no libxkbcommon requirement"
grep -q 'SIL Open Font License, Version 1.1' "$t$lic/Selawik-LICENSE.txt" || fail "Selawik-LICENSE.txt is not the OFL"
grep -q 'here is a blessing' "$t$lic/sqlite-NOTICE" || fail "sqlite-NOTICE lacks the blessing"
echo "pkg-blockie-frontend: ok"
