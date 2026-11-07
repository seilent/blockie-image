#!/usr/bin/env bash
set -euo pipefail

name=libretro-ppsspp
core=ppsspp
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libretro-ppsspp.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
assets=/usr/share/libretro/ppsspp/PPSSPP
files=$(rpm -qpl "$rpm")
bad=$(grep -v -e "^/usr/lib64/libretro\(/${core}_libretro.so\)\?$" -e "^$lic\(/.*\)\?$" -e "^/usr/share/libretro\(/ppsspp\)\?$" \
  -e "^$assets\(/.*\)\?$" <<< "$files" || true)
[[ -z $bad ]] || fail "files outside the core, licence and asset dirs: $bad"
for f in "/usr/lib64/libretro/${core}_libretro.so" "$lic/LICENSE.TXT" "$lic/COPYING.LGPLv2.1" "$lic/LICENSE.md" \
  "$lic/ext/glslang/LICENSE.txt" "$lic/ext/SPIRV-Cross/LICENSE" "$lic/ext/zstd/LICENSE" "$lic/ext/libchdr/LICENSE.txt" \
  "$lic/ext/freetype/LICENSE.TXT" "$lic/ext/cityhash/COPYING" "$lic/ext/gason/LICENSE" "$lic/ext/udis86/LICENSE" \
  "$lic/ext/snappy/COPYING" "$lic/ext/aemu_postoffice/gpl-3.0.txt" "$lic/ext/sfmt19937/LICENSE.txt" \
  "$lic/flash0-font/NOTICE" "$lic/flash0-font/UmeFont-license.html" "$lic/flash0-font/SourceHanSans-LICENSE.txt" \
  "$assets/compat.ini" "$assets/ppge_atlas.zim" "$assets/flash0/font/ltn0.pgf" "$assets/lang"; do
  grep -qx "$f" <<< "$files" || fail "missing $f"
done
! grep -q "^$assets/debugger" <<< "$files" || fail "debugger assets packaged"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "GPL-2.0-or-later AND GPL-3.0-or-later AND GPL-3.0-only AND GPL-3.0-or-later WITH Bison-exception-2.2 AND LGPL-2.1-or-later AND Apache-2.0 AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Zlib AND CC0-1.0 AND LicenseRef-Fedora-Public-Domain AND LicenseRef-disarm AND (FTL OR GPL-2.0-or-later) AND mplus AND OFL-1.1" ]] \
  || fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
so=$t/usr/lib64/libretro/${core}_libretro.so
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$t$lic/COPYING.LGPLv2.1" || fail "FFmpeg licence text"
grep -q 'Version 3, 29 June 2007' "$t$lic/ext/aemu_postoffice/gpl-3.0.txt" || fail "GPL-3.0 text"
for n in "ext/libzip|Dieter Baron and Thomas Klausner|Redistribution and use" "ext/sfmt19937|Mutsuo Saito|LICENSE.txt" \
  "ext/pugixml|Arseny Kapoulkine|Permission is hereby granted" "ext/lua|Lua.org, PUC-Rio|Permission is hereby granted" \
  "ext/vma|Advanced Micro Devices|Permission is hereby granted" "ext/basis_universal|Binomial LLC|Apache License" \
  "ext/libkirk|General Public License|version 3" "ext/xbrz|Zenju|General Public License" \
  "ext/xxhash|Yann Collet|Redistribution and use" "ext/riscv-disas|Michael Clark|Permission is hereby granted" \
  "ext/loongarch-disasm|Loongson Technology|Permission is hereby granted" "ext/disarm|Gareth McCaughan|copyright notice" \
  "Common/GPU/OpenGL|The Android Open Source Project|Apache License" \
  "libretro/libretro-common|The RetroArch team|Permission is hereby granted"; do
  IFS='|' read -r d a b <<< "$n"
  f=$t$lic/$d/NOTICE
  [[ -s $f ]] && grep -qF "$a" "$f" && grep -qF "$b" "$f" || fail "notice $d"
done
grep -q 'Redistribution and use' "$t$lic/ext/sfmt19937/LICENSE.txt" || fail "SFMT licence text"
f=$t$lic/flash0-font
grep -q 'fa50bb1976065c4f8b1b47af227d367fe9771555' "$f/NOTICE" && grep -q '#13510' "$f/NOTICE" && grep -q 'dc34bea8' "$f/NOTICE" \
  || fail "flash0 font notice"
[[ $(sha256sum < "$f/UmeFont-license.html") == "88d5d5a1bf928ff316e3f80d2e665b1a3ab0f46af80ae7d1ec0046b16ea64cdb  -" ]] \
  && grep -qF 'Unlimited permission is granted to use, copy, and distribute it,' "$f/UmeFont-license.html" || fail "Ume font licence text"
[[ $(sha256sum < "$f/SourceHanSans-LICENSE.txt") == "0983abed9371adc8958c321bf8d8036324b4a2e8cc324682b0fe0c699e63a009  -" ]] \
  && grep -qF 'SIL OPEN FONT LICENSE Version 1.1' "$f/SourceHanSans-LICENSE.txt" || fail "Source Han Sans licence text"
[[ $(readelf -dW "$t/usr/lib64/libretro/${core}_libretro.so") != *libav* ]] || fail "FFmpeg linked dynamically"
sections=$(readelf -SW "$so")
[[ $sections != *.debug_info* ]] || fail "debug info not stripped"
[[ $sections != *" .symtab "* ]] || fail "symbol table not stripped"
[[ $(readelf -dW "$so") == *"(FLAGS)"*BIND_NOW* ]] || fail "not linked with -z now"
segments=$(readelf -lW "$so")
[[ $segments == *GNU_RELRO* ]] || fail "no GNU_RELRO"
[[ $(awk '$1 == "GNU_STACK" { print $(NF - 1) }' <<< "$segments") == RW ]] || fail "GNU_STACK is not RW"
python3 - "$so" <<'EOF' || fail "core load"
import ctypes, os, sys

so = sys.argv[1]
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
assert info.library_name == b"PPSSPP", info.library_name
assert info.library_version == b"v1.20.4", info.library_version
assert b"iso" in info.valid_extensions.split(b"|"), info.valid_extensions
EOF
echo "pkg-$name: ok"
