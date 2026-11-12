#!/usr/bin/env bash
set -euo pipefail

name=portmaster
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-portmaster.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
arch=$(uname -m)
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $arch" ]] || fail "name or arch"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "MIT AND GPL-2.0-only AND Apache-2.0 AND BSD-3-Clause AND PSF-2.0 AND OFL-1.1 AND Bitstream-Vera AND Arev AND Zlib AND LicenseRef-Fedora-Public-Domain" ]] ||
  fail "licence tag"
requires=$(rpm -qpR "$rpm")
for r in gptokeyb gptokeyb2 love luajit 7zip-standalone-all innoextract xdelta libtheora squashfs-tools python3; do
  grep -qx "$r" <<< "$requires" || fail "no Requires $r"
done
root=/usr/share/blockie/portmaster
lic=/usr/share/licenses/$name
files=$(rpm -qpl "$rpm")
bad=$(grep -v -e "^$root\(/.*\)\?$" -e "^$lic\(/.*\)\?$" <<< "$files" || true)
[[ -z $bad ]] || fail "files outside $root and $lic: $bad"
bad=$(grep -iE 'x86_64|armhf' <<< "$files" || true)
[[ -z $bad ]] || fail "x86_64 or armhf files: $bad"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
pm=$t$root/PortMaster

entries() { find "$pm/$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' '; }
sorted() { printf '%s\n' "$@" | LC_ALL=C sort | paste -sd' '; }
lics=(LICENSE-ansimarkup.txt LICENSE-colorama.txt LICENSE-dejavu.txt LICENSE-idna.md LICENSE-loguru.txt LICENSE-noto.txt
  LICENSE-requests.txt LICENSE-typing_extension.txt LICENSE-urllib3.txt)
[[ $(entries .) == "$(sorted .Backup "7zzs.$arch" PortMasterDialog.txt control.txt device_info.txt exlibs funcs.txt \
  gamecontrollerdb.txt gptokeyb gptokeyb2 "innoextract.$arch" libgl_Batocera.txt libgl_EmuELEC.txt libgl_JELOS.txt \
  libgl_Miyoo.txt libgl_REGLinux.txt libgl_ROCKNIX.txt libgl_UnofficialOS.txt libgl_default.txt libgl_knulli.txt \
  libgl_muOS.txt libgl_uConsole.txt "libinterpose.$arch.so" "libs.$arch" licenses mod_.txt pylibs runtimes tasksetter utils \
  version xdelta3)" ]] || fail "top entries: $(entries .)"
[[ $(entries exlibs) == "$(sorted __pycache__ ansimarkup charset_normalizer colorama idna loguru requests \
  typing_extensions.py urllib3)" ]] || fail "exlibs: $(entries exlibs)"
[[ $(entries pylibs) == "harbourmaster resources" ]] || fail "pylibs: $(entries pylibs)"
[[ $(entries pylibs/resources) == "DejaVuSans.ttf NotoSansHK-Regular.ttf NotoSansJP-Regular.ttf NotoSansKR-Regular.ttf NotoSansSC-Regular.ttf NotoSansTC-Regular.ttf" ]] ||
  fail "pylibs/resources: $(entries pylibs/resources)"
[[ $(entries .Backup) == "donottouch.txt donottouch_x.txt" ]] || fail ".Backup: $(entries .Backup)"
[[ $(entries utils) == patcher.txt ]] || fail "utils: $(entries utils)"
[[ $(entries runtimes) == love_11.5 ]] || fail "runtimes: $(entries runtimes)"
[[ $(entries runtimes/love_11.5) == "$(sorted "libs.$arch" "love.$arch" love.txt)" ]] ||
  fail "runtimes/love_11.5: $(entries runtimes/love_11.5)"
[[ -d $pm/runtimes/love_11.5/libs.$arch && -z $(entries "runtimes/love_11.5/libs.$arch") ]] ||
  fail "runtimes/love_11.5/libs.$arch is not an empty dir"
[[ $(entries "libs.$arch") == libtheoradec.so.1 ]] || fail "libs.$arch: $(entries "libs.$arch")"
[[ $(entries licenses) == "$(sorted "${lics[@]}")" ]] || fail "licenses: $(entries licenses)"

links=$(cd "$pm" && find . -type l -printf '%P %l\n' | LC_ALL=C sort)
want=$(printf '%s\n' "gptokeyb /usr/lib64/blockie-ports/gptokeyb" "gptokeyb2 /usr/lib64/blockie-ports/gptokeyb2" \
  "libinterpose.$arch.so /usr/lib64/blockie-ports/libinterpose.$arch.so" "7zzs.$arch /usr/bin/7zz" \
  "innoextract.$arch /usr/bin/innoextract" "xdelta3 /usr/bin/xdelta3" \
  "libs.$arch/libtheoradec.so.1 /usr/lib64/libtheoradec.so.1" "runtimes/love_11.5/love.$arch /usr/bin/love" | LC_ALL=C sort)
[[ $links == "$want" ]] || fail "links: $links"

while read -r kind n from; do
  n=${n//@/$arch}
  if [[ $kind == tree ]]; then
    [[ -e $pm/$n || -L $pm/$n ]] || fail "$n ($from) is not in the tree"
  else
    [[ ! -e $pm/$n && ! -L $pm/$n ]] || fail "$n ($kind, $from) is in the tree"
  fi
done <<'EOF'
tree control.txt 1536
tree device_info.txt 296
tree utils/patcher.txt 166
tree libgl_default.txt 154
tree xdelta3 149
tree runtimes/love_11.5/love.txt 66
tree tasksetter 47
tree 7zzs.@ 32
tree gamecontrollerdb.txt 4
tree PortMasterDialog.txt 2
tree innoextract.@ 2
tree runtimes/love_11.5/libs.@ 2
tree runtimes/love_11.5/love.@ 1
tree libinterpose.@.so 1
tree funcs.txt control.txt
tree gptokeyb control.txt
tree gptokeyb2 control.txt
tree version funcs.txt
tree libs.@ funcs.txt
farm mod_Blockie.txt 1532
farm libs 313
farm harbourmaster 277
farm resources funcs.txt
none libgl_Blockie.txt 177
drop oga_controls 5
drop astcenc.@ 1
drop mapper.py control.txt
drop portmsg.@ funcs.txt
drop pugwash PortMasterDialog.txt
EOF

elfs=$(cat <<'EOF'
026b2287c9d68f920cf541b68b94f1a691168e4bbf301a8793f4114808aa8f95
045e82c4113cbe3e88da943e6904ae2572d7e55b93aef0533d335c3ea14b7797
049fe67af5b3f634914a9ddc359885f58075ad17a722d284c327a8cb6ef51bb6
09560c9dfe3a438e3c9aca2a93a762422825d2784e42a76dbeb0be34041842f3
09aaaa41ef869bb3e387f19778b4db64ee026d628d42a21b5a0823042316ad74
15d7f430d0e59cfcefcfd80773afd89cd000aac8ce16527286e2055555ac72e6
1783abbb3f3825c0bc5e440e800ace3539eab2373d8474eca7000cecd808edda
21f802831e9c529aad4d355a88c19587bde323bc1bbd9e2aa9daacae8eb7b155
2b8bd8073b0d4327d9f2b34a1bd8e2c044df8baaa4d5f072920ea309ccb5dfee
2d1ed9941c7ae988a439a5d1d8d58f879683bf95c10390c62795b2bcc64e0369
33d0a585a6c4b68ecae9b2879b755c91ba5520646cff224ba1116300dc27103a
38b4787b8870c5ff38f3d46c804cf239cf6a5a0717cc521d013700ce3eeb7d1d
38bb20468e53436e499f8359da8c4a749a78e961e57237e689ff4f56ff2cc7de
3d54d2d829287faa5140ff8c1b2ea778a00548c66b1faa786d2fdfd08c9d2543
4152e075dcc7367d6e40d53d12e1efe27afbbe4b9b38b25625a4ed7597b428ea
5bebcf593f8f1f7d6489546380f186712f8c3dfd9bdac3f42d2917c4be8718b8
613b4f7c7be223c99f4b341674d63a9f411ea64344828eee2adaca90fb545b83
66015f344b53895affd3ff153f402097ebaa2add33246bea2d7fca27b682e07a
674b6e40e490ae48455339f4f2ded664d4f2141a65c09a2105841faa53700a70
6fbd8fddd2f37c702b408d5b3ca9f6a0da1fc4a8e28d8c0dc2f3ca4da10fcb1d
74a6cb55ed600b2315d37c8273d7aae4041915bddfad47a6a834387f50283148
7a44bf955c93ec5caf0fe90bf2f65451fec53ed55b1d3288cbda065dc91cb9d0
7b6d63c8ac313cbf976c4fdfe4e6a55d4503ad646cf708fcb52a4008e027e073
83380ac1069f81dce4f6aa551ad19a6aecec3ef7d11b17a58aa07fd684a030a4
87dc50b64c2cb6ca174de8bf2f3199eafadcf7c4368356e37aee739969139f12
a50c83729cb0e1c4d8389eaaa827f0a6e7f3362814d0504ca84074dd0e47c379
abf15ed10ca329465c6c689fd7f4b3918e320fd6100656c76c80a1dc7e72bfb0
ac3e6765e4f51f53e4eb38b987260ed0e06a2e9caf27105639cec77c5fff0eed
b314f7eabdd5d8adcf0498d5908f1454c5bbf5d719b3f67ba2bdc032fdb93773
b4b29431056a11fb2309d1327ac941193ad8113ca7bf48584af9965846fabc65
bb66e10d9000821e2d4368069c1627e39e05daa4ea3e4556025d538bc6dd8193
c20f05eb428750d4b0006084ff6be5ba2a0580b16b339487f4a875034484f6a7
c65cbf300dae1e72d2166530309810ce188c04669c9c05b05daafdf3c8716de6
c6c64453ed6163c8aeb14d303bad1e4d9ecc4d628097b3c6420ada2fa6a8690f
d30c882e7128874f5a112b4c80d20863eb3663b647038affd4b3b410ae4eb4ea
e40659d7b6d0fb994a8414c464805d22111ec1e9602cf8c03b6565359a02bde5
eb66c7eca2f937e6ba7ac2209233a13e5d387ca176f982bc9ed3916d91e8d1c9
f1a42f522fc5ddbb331f5cb1ed43f088c633043fd4948764a4846da429a82b7b
fd127c333d86c567f62a6b482f33313724cf5f45711311fdba8d75afc97aa3f0
fe18dbb6ef527671b00a1248c40bc4050182d33b895c31bfec3b0a8beddd7d6b
EOF
)
while IFS= read -r -d '' f; do
  [[ $(od -An -N4 -tx1 "$f" | tr -d ' \n') != 7f454c46 ]] || fail "ELF in the package: ${f#"$t"}"
  ! grep -qxF "$(sha256sum < "$f" | cut -d' ' -f1)" <<< "$elfs" || fail "upstream prebuilt binary: ${f#"$t"}"
done < <(find "$t" -type f -print0)

[[ $(< "$pm/version") == 2026.11.12-1059 ]] || fail "version: $(< "$pm/version")"
p=$pm/utils/patcher.txt
bash -n "$p" || fail "patcher.txt syntax"
grep -qF -- '--choose' "$p" && grep -qF -- '--progress' "$p" && grep -qF -- '--close' "$p" || fail "patcher.txt is not Blockie's"
! grep -qF LOVE_RUN "$p" || fail "patcher.txt runs the LOVE patcher"
grep -qx '    return "/etc/pki/tls/certs/ca-bundle.crt"' "$pm/exlibs/requests/certs.py" || fail "requests certs"

[[ $(find "$t$lic" -mindepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' ') == "$(sorted LICENSE LICENSE-charset_normalizer.txt LICENSE-gamecontrollerdb.txt "${lics[@]}")" ]] ||
  fail "licence files"
for f in "${lics[@]}"; do
  cmp -s "$pm/licenses/$f" "$t$lic/$f" || fail "$f differs from the tree's"
done
grep -q 'Copyright (c) 2023-2025 Jacob' "$t$lic/LICENSE" && grep -q 'Permission is hereby granted' "$t$lic/LICENSE" ||
  fail "PortMaster MIT text"
grep -q 'TAHRI Ahmed' "$t$lic/LICENSE-charset_normalizer.txt" || fail "charset_normalizer licence text"
grep -q 'Sam Lantinga' "$t$lic/LICENSE-gamecontrollerdb.txt" || fail "gamecontrollerdb licence text"

python3 - "$pm" "$root/PortMaster" "$t$root/tree.sha256" <<'EOF' || fail "bytecode or tree.sha256"
import hashlib, importlib.util, marshal, os, sys

pm, dest, stamp = sys.argv[1:]
for top in ("pylibs", "exlibs"):
    for d, _, files in os.walk(os.path.join(pm, top)):
        for n in files:
            if not n.endswith(".py"):
                continue
            src = os.path.join(d, n)
            with open(importlib.util.cache_from_source(src), "rb") as f:
                data = f.read()
            assert data[:4] == importlib.util.MAGIC_NUMBER, src
            assert int.from_bytes(data[4:8], "little") == 1, src
            assert marshal.loads(data[16:]).co_filename == os.path.join(dest, os.path.relpath(src, pm)), src
entries = []
for d, dirs, files in os.walk(pm):
    dirs[:] = [n for n in dirs if n != "__pycache__"]
    for n in dirs + files:
        p = os.path.join(d, n)
        if os.path.islink(p):
            v = "l\t" + os.readlink(p)
        elif os.path.isdir(p):
            v = "d"
        else:
            with open(p, "rb") as f:
                v = "f\t" + hashlib.sha256(f.read()).hexdigest()
        entries.append((os.path.relpath(p, pm).encode(), v))
text = "".join(f"{rel.decode()}\t{v}\n" for rel, v in sorted(entries))
with open(stamp) as f:
    assert f.read() == hashlib.sha256(text.encode()).hexdigest() + "\n", "tree.sha256"
EOF
env -i PATH=/usr/bin HOME="$t" HM_TOOLS_DIR="$t/ports" HM_PORTS_DIR="$t/ports" HM_SCRIPTS_DIR="$t/ports" \
  python3 -I -B - "$pm" <<'EOF' || fail "harbourmaster does not import from the tree"
import sys

sys.path[:0] = [sys.argv[1] + "/pylibs", sys.argv[1] + "/exlibs"]
import harbourmaster
import requests.certs

assert requests.certs.where() == "/etc/pki/tls/certs/ca-bundle.crt"
EOF
echo "pkg-$name: ok"
