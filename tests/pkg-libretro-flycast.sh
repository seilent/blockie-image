#!/usr/bin/env bash
set -euo pipefail

name=libretro-flycast
core=flycast
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libretro-flycast.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
lic=/usr/share/licenses/$name
files=(LICENSE core/deps/libchdr/LICENSE.txt core/deps/libchdr/deps/lzma-24.05/LICENSE
  core/deps/libchdr/deps/zlib-1.3.1/LICENSE core/deps/libchdr/deps/zstd-1.5.6/LICENSE
  core/deps/libchdr/deps/zstd-1.5.6/COPYING core/deps/glslang/LICENSE.txt core/deps/Vulkan-Headers/LICENSE.md
  core/deps/Vulkan-Headers/LICENSES/Apache-2.0.txt core/deps/Vulkan-Headers/LICENSES/MIT.txt
  core/deps/VulkanMemoryAllocator/LICENSE.txt core/deps/libzip/LICENSE core/deps/miniupnpc/LICENSE
  core/deps/nowide/LICENSE core/deps/picotcp/COPYING core/deps/picotcp/LICENSE.GPLv2 core/deps/picotcp/LICENSE.GPLv3
  core/deps/tinygettext/LICENSE.md core/deps/xbrz/License.txt core/deps/xxHash/LICENSE core/deps/glm/copying.txt
  core/deps/asio/asio/COPYING core/deps/asio/asio/LICENSE_1_0.txt)
files+=(core/deps/libelf/NOTICE core/deps/json/NOTICE core/deps/libretro-common/NOTICE core/hw/bba/NOTICE
  core/network/NOTICE core/deps/md5/LICENSE)
[[ $(uname -m) != x86_64 ]] || files+=(core/deps/xbyak/COPYRIGHT)
[[ $(uname -m) != aarch64 ]] || files+=(core/deps/vixl/NOTICE)
want=$(for f in "${files[@]}"; do
  echo "$lic/$f"
  while [[ $f == */* ]]; do f=${f%/*}; echo "$lic/$f"; done
done; printf '%s\n' /usr/lib64/libretro "/usr/lib64/libretro/${core}_libretro.so" "$lic")
want=$(LC_ALL=C sort -u <<< "$want")
[[ $(rpm -qpl "$rpm" | LC_ALL=C sort) == "$want" ]] || fail "file list: $(rpm -qpl "$rpm" | tr '\n' ' ')"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "GPL-2.0-or-later AND GPL-3.0-only AND GPL-3.0-or-later WITH Bison-exception-2.2 AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Apache-2.0 AND BSL-1.0 AND Zlib AND LicenseRef-Fedora-Public-Domain AND (Apache-2.0 OR MIT) AND (MIT OR Unlicense) AND (BSD-3-Clause OR GPL-2.0-only) AND (GPL-2.0-only OR GPL-3.0-only)" ]] \
  || fail "licence tag"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
so=$t/usr/lib64/libretro/${core}_libretro.so
grep -q 'GNU GENERAL PUBLIC LICENSE' "$t$lic/LICENSE" || fail "licence text"
notices=("core/deps/libelf/NOTICE|University of New South Wales|Redistribution and use"
  "core/deps/json/NOTICE|Niels Lohmann|Permission is hereby"
  "core/deps/libretro-common/NOTICE|The RetroArch team|Permission is hereby granted"
  "core/hw/bba/NOTICE|Igor Kovalenko|Permission is hereby granted"
  "core/network/NOTICE|Kenneth MacKay|Redistribution and use"
  "core/deps/md5/LICENSE|Marek Ulwański|Permission is hereby granted")
[[ $(uname -m) != aarch64 ]] || notices+=("core/deps/vixl/NOTICE|VIXL authors|Redistribution and use")
for n in "${notices[@]}"; do
  IFS='|' read -r f a b <<< "$n"
  grep -q 'Copyright' "$t$lic/$f" && grep -qF "$a" "$t$lic/$f" && grep -qF "$b" "$t$lic/$f" || fail "notice $f"
done
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
assert info.library_name == b"Flycast", info.library_name
assert info.library_version == b"v2.7", info.library_version
assert b"gdi" in info.valid_extensions.split(b"|"), info.valid_extensions
EOF
echo "pkg-$name: ok"
