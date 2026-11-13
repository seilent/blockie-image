#!/usr/bin/env bash
set -euo pipefail

name=depotdownloader
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-depotdownloader.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name noarch" ]] || fail "name or arch"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "GPL-1.0-or-later AND LGPL-2.1-only AND Apache-2.0 AND MIT" ]] || fail "licence tag"
rpm -qpR "$rpm" | grep -qx 'dotnet-runtime-10.0' || fail "no Requires dotnet-runtime-10.0"
root=/usr/lib/blockie/depotdownloader
lic=/usr/share/licenses/$name
files=$(rpm -qpl "$rpm")
bad=$(grep -v -e "^$root\(/[^/]*\)\?$" -e "^$lic\(/.*\)\?$" -e '^/usr/libexec/blockie\(/depotdownloader\)\?$' \
  -e '^/usr/lib/blockie$' <<< "$files" || true)
[[ -z $bad ]] || fail "files outside $root, $lic and the launcher: $bad"
bad=$(grep -iE '/runtimes|\.exe$|\.pdb$|\.so$|\.dylib$|\.xml$' <<< "$(grep "^$root/" <<< "$files")" || true)
[[ -z $bad ]] || fail "Windows, x64, arm32 or native files: $bad"
for f in "$root/DepotDownloader.dll" "$root/SteamKit2.dll" "$root/DepotDownloader.runtimeconfig.json" \
  "$root/DepotDownloader.deps.json" "$lic/LICENSE" "$lic/SteamKit2-LICENSE" "$lic/SteamKit2-license.txt" \
  "$lic/SteamKit2-3rd-party.txt" "$lic/Apache-2.0.txt" "$lic/protobuf-net-Licence.txt" "$lic/QRCoder-LICENSE.txt" \
  "$lic/ZstdSharp-LICENSE.txt" "$lic/dotnet-runtime-LICENSE.TXT" "$lic/CsWin32-LICENSE.txt"; do
  grep -qx "$f" <<< "$files" || fail "missing $f"
done
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
grep -q 'GNU GENERAL PUBLIC LICENSE' "$t$lic/LICENSE" && grep -q 'Version 2, June 1991' "$t$lic/LICENSE" || fail "GPLv2 text"
grep -q 'GNU LESSER GENERAL PUBLIC LICENSE' "$t$lic/SteamKit2-LICENSE" || fail "LGPL text"
[[ $(sha256sum < "$t$lic/Apache-2.0.txt") == "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  -" ]] ||
  fail "Apache-2.0 text"
launcher=$(< "$t/usr/libexec/blockie/depotdownloader")
[[ $launcher == $'#!/usr/bin/sh\nexec /usr/bin/dotnet /usr/lib/blockie/depotdownloader/DepotDownloader.dll "$@"' ]] ||
  fail "launcher, first line: ${launcher%%$'\n'*}"
[[ $(stat -c %a "$t/usr/libexec/blockie/depotdownloader") == 755 ]] || fail "launcher mode"
python3 - "$t$root" << 'EOF' || fail "runtimeconfig, IL only assemblies or the patch's names"
import json
import os
import struct
import sys

d = sys.argv[1]
rc = json.load(open(f"{d}/DepotDownloader.runtimeconfig.json"))["runtimeOptions"]
assert rc.get("rollForward") == "LatestPatch", rc
assert rc.get("configProperties", {}).get("System.Globalization.Invariant") is True, rc
assert rc["framework"]["name"] == "Microsoft.NETCore.App" and rc["framework"]["version"].startswith("10.0."), rc
for f in sorted(os.listdir(d)):
    if not f.endswith(".dll"):
        continue
    b = open(f"{d}/{f}", "rb").read()
    pe = struct.unpack_from("<I", b, 0x3c)[0]
    assert b[pe:pe + 4] == b"PE\0\0", f
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    dirs = opt + (96 if magic == 0x10b else 112)
    clr_rva = struct.unpack_from("<I", b, dirs + 14 * 8)[0]
    assert clr_rva, f"{f} is not a .NET assembly"
    sec = opt + struct.unpack_from("<H", b, pe + 20)[0]
    for i in range(nsec):
        size, va = struct.unpack_from("<II", b, sec + i * 40 + 8)
        raw = struct.unpack_from("<I", b, sec + i * 40 + 20)[0]
        if va <= clr_rva < va + size:
            flags = struct.unpack_from("<I", b, clr_rva - va + raw + 16)[0]
            assert flags & 1, f"{f} is not IL only"
            break
    else:
        raise AssertionError(f"{f}: no section holds the CLR header")
dll = open(f"{d}/DepotDownloader.dll", "rb").read()
for n in ("BLOCKIE_DD_FD", "BLOCKIE_DD_CONFIG", "BLOCKIE_DD_DEVICE"):
    assert n.encode("utf-16-le") in dll, n
EOF
command -v dotnet > /dev/null || fail "no dotnet in the builder to run the build"
dd=$t$root/DepotDownloader.dll
printf 'not deflate' > "$t/account.config"
v=$(BLOCKIE_DD_CONFIG=$t/account.config DOTNET_CLI_HOME=$t HOME=$t dotnet "$dd" -V 2> /dev/null) || fail "-V with a corrupt account file: $v"
[[ $v == "DepotDownloader v3.4.0"* ]] || fail "-V printed $v"
rm -f "$t/account.config"
rc=0
BLOCKIE_DD_FD=3 BLOCKIE_DD_CONFIG=$t/account.config DOTNET_CLI_HOME=$t HOME=$t \
  timeout -k 2 10 dotnet "$dd" -app 900001 -qr -remember-password -dir "$t/dl" 3> "$t/channel" < /dev/null > /dev/null 2>&1 || rc=$?
[[ $rc != 0 ]] || fail "a run with no network exited 0"
[[ ! -e $t/account.config ]] || fail "a run with no network wrote account.config"
! grep -q '^qr' "$t/channel" || fail "a run with no network wrote a qr line"
bad=$(grep -vE '^fail	(network|login|other)$' "$t/channel" || true)
[[ -z $bad ]] || fail "lines other than one fail line on the channel: $bad"
blockie_mode() {
  local rc=0
  BLOCKIE_DD_FD=3 BLOCKIE_DD_CONFIG=$t/account.config DOTNET_CLI_HOME=$t HOME=$t \
    timeout -k 2 10 dotnet "$dd" "$@" 3> "$t/channel" < /dev/null > /dev/null 2>&1 || rc=$?
  [[ $rc == 1 && $(< "$t/channel") == $'fail\tother' ]] || fail "$* with no network: rc $rc, $(< "$t/channel")"
}
blockie_mode -blockie-scan
blockie_mode -blockie-library -blockie-scan "$t/list"
echo "pkg-$name: ok"
