#!/usr/bin/env bash
set -euo pipefail

name=libretro-snes9x
core=snes9x
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libretro-snes9x.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
want=$(printf '%s\n' /usr/lib64/libretro "/usr/lib64/libretro/${core}_libretro.so" "$lic" "$lic/LICENSE" "$lic/filter" \
  "$lic/filter/snes_ntsc-license.txt" "$lic/libretro" "$lic/libretro/libretro-common" \
  "$lic/libretro/libretro-common/NOTICE" | LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "LicenseRef-Snes9x AND LGPL-2.1-or-later AND MIT AND LicenseRef-Fedora-Public-Domain" ]] ||
  fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
so=$t/usr/lib64/libretro/${core}_libretro.so
grep -q 'Snes9x' "$t$lic/LICENSE" || fail "licence text"
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$t$lic/filter/snes_ntsc-license.txt" || fail "LGPL text"
n=$t$lic/libretro/libretro-common/NOTICE
grep -q 'Copyright' "$n" && grep -q 'Permission is hereby granted' "$n" || fail "libretro-common notice"
sections=$(readelf -SW "$so")
[[ $sections != *.debug_info* ]] || fail "debug info not stripped"
[[ $sections != *" .symtab "* ]] || fail "symbol table not stripped"
[[ $(readelf -dW "$so") == *"(FLAGS)"*BIND_NOW* ]] || fail "not linked with -z now"
segments=$(readelf -lW "$so")
[[ $segments == *GNU_RELRO* ]] || fail "no GNU_RELRO"
[[ $(awk '$1 == "GNU_STACK" { print $(NF - 1) }' <<< "$segments") == RW ]] || fail "GNU_STACK is not RW"
short=$(rpm -qp --qf '%{RELEASE}' "$rpm" | sed -n 's/^[0-9]\{1,\}\.[0-9]\{8\}git\([0-9a-f]\{7\}\)\..*/\1/p')
[[ -n $short ]] || fail "release has no short commit"
python3 - "$so" "$short" <<'EOF' || fail "core load"
import ctypes, os, sys

so, commit = sys.argv[1], sys.argv[2]
with open(so, "rb") as f:
    head = f.read(20)
machine = {"aarch64": 0xB7, "x86_64": 0x3E}[os.uname().machine]
assert head[:4] == b"\x7fELF", "not an ELF"
assert int.from_bytes(head[18:20], "little") == machine, "ELF machine"


class Info(ctypes.Structure):
    _fields_ = [("library_name", ctypes.c_char_p), ("library_version", ctypes.c_char_p),
                ("valid_extensions", ctypes.c_char_p), ("need_fullpath", ctypes.c_bool),
                ("block_extract", ctypes.c_bool)]


lib = ctypes.CDLL(so)
for sym in ("retro_init", "retro_deinit", "retro_run", "retro_load_game", "retro_unload_game",
            "retro_set_environment", "retro_get_system_av_info"):
    getattr(lib, sym)
lib.retro_api_version.restype = ctypes.c_uint
assert lib.retro_api_version() == 1, "retro_api_version"
info = Info()
lib.retro_get_system_info(ctypes.byref(info))
assert info.library_name == b"Snes9x", info.library_name
assert info.library_version.endswith(commit.encode()), info.library_version
assert b"sfc" in info.valid_extensions.split(b"|"), info.valid_extensions
EOF
echo "pkg-$name: ok"
