#!/usr/bin/env bash
set -euo pipefail

name=libretro-mupen64plus-next
core=mupen64plus_next
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libretro-mupen64plus-next.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
want=$(printf '%s\n' /usr/lib64/libretro "/usr/lib64/libretro/${core}_libretro.so" "$lic" "$lic/GLideN64" \
  "$lic/GLideN64/LICENSE" "$lic/GLideN64/licenses" "$lic/GLideN64/licenses/GLSL-FXAA" \
  "$lic/GLideN64/licenses/GLSL-FXAA/LICENSE.md" "$lic/GLideN64/licenses/Glow" "$lic/GLideN64/licenses/Glow/LICENSE" \
  "$lic/GLideN64/licenses/gles2n64" "$lic/GLideN64/licenses/gles2n64/LICENSE" "$lic/GLideN64/licenses/readerwriterqueue" \
  "$lic/GLideN64/licenses/readerwriterqueue/LICENSE.md" "$lic/LICENSE" "$lic/libretro-common" \
  "$lic/libretro-common/NOTICE" "$lic/mupen64plus-core" "$lic/mupen64plus-core/LICENSES" "$lic/mupen64plus-core/src" \
  "$lic/mupen64plus-core/src/device" "$lic/mupen64plus-core/src/device/pif" "$lic/mupen64plus-core/src/device/pif/NOTICE" \
  "$lic/mupen64plus-rsp-hle" "$lic/mupen64plus-rsp-hle/LICENSES" | LC_ALL=C sort)
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
tag="GPL-2.0-only AND GPL-2.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Zlib AND Libpng"
tag+=" AND LicenseRef-Fedora-Public-Domain"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "$tag" ]] || fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
so=$t/usr/lib64/libretro/${core}_libretro.so
grep -q 'GNU GENERAL PUBLIC LICENSE' "$t$lic/LICENSE" || fail "licence text"
n=$t$lic/libretro-common/NOTICE
grep -q 'Copyright' "$n" && grep -q 'Permission is hereby granted' "$n" || fail "libretro-common notice"
n=$t$lic/mupen64plus-core/src/device/pif/NOTICE
grep -q 'Copyright 2011 X-Scale' "$n" && grep -q 'Redistribution and use' "$n" || fail "n64_cic_nus_6105 notice"
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


class Value(ctypes.Structure):
    _fields_ = [("value", ctypes.c_char_p), ("label", ctypes.c_char_p)]


class Definition(ctypes.Structure):
    _fields_ = [("key", ctypes.c_char_p), ("desc", ctypes.c_char_p), ("desc_categorized", ctypes.c_char_p),
                ("info", ctypes.c_char_p), ("info_categorized", ctypes.c_char_p), ("category_key", ctypes.c_char_p),
                ("values", Value * 128), ("default_value", ctypes.c_char_p)]


class Options(ctypes.Structure):
    _fields_ = [("categories", ctypes.c_void_p), ("definitions", ctypes.POINTER(Definition))]


class Intl(ctypes.Structure):
    _fields_ = [("us", ctypes.POINTER(Options)), ("local", ctypes.POINTER(Options))]


seen = {}


def collect(options):
    i = 0
    while options.definitions[i].key:
        d = options.definitions[i]
        values = []
        for v in d.values:
            if not v.value:
                break
            values.append(v.value)
        seen[d.key] = (d.default_value, values)
        i += 1


@ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_uint, ctypes.c_void_p)
def environment(cmd, data):
    if cmd == 52:
        ctypes.cast(data, ctypes.POINTER(ctypes.c_uint))[0] = 2
        return True
    if cmd == 68:
        collect(ctypes.cast(data, ctypes.POINTER(Intl))[0].us[0])
        return True
    if cmd == 67:
        collect(ctypes.cast(data, ctypes.POINTER(Options))[0])
        return True
    return False


lib = ctypes.CDLL(so)
for sym in ("retro_init", "retro_deinit", "retro_run", "retro_load_game", "retro_unload_game",
            "retro_get_system_av_info"):
    getattr(lib, sym)
lib.retro_api_version.restype = ctypes.c_uint
assert lib.retro_api_version() == 1, "retro_api_version"
info = Info()
lib.retro_get_system_info(ctypes.byref(info))
assert info.library_name == b"Mupen64Plus-Next", info.library_name
assert info.library_version.endswith(commit.encode()), info.library_version
assert b"z64" in info.valid_extensions.split(b"|"), info.valid_extensions
lib.retro_set_environment(environment)
for key, want in ((b"mupen64plus-rdp-plugin", b"gliden64"), (b"mupen64plus-rsp-plugin", b"hle")):
    default, values = seen[key]
    assert default == want, (key, default)
    assert b"parallel" not in values, (key, values)
EOF
echo "pkg-$name: ok"
