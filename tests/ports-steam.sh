#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/ports-steam.XXXXXX")
trap 'rm -rf "${t:?}"' EXIT
fails=0

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

done_() {
  if (( fails )); then
    echo "ports-steam: $fails failed"
    exit 1
  fi
  echo "ports-steam: ok"
  exit 0
}

sf=$here/../system_files
rules=${STEAM_RULES:-/usr/share/polkit-1/rules.d/50-blockie-steam.rules}
[[ -f $rules ]] || rules=$sf/usr/share/polkit-1/rules.d/50-blockie-steam.rules

polkit() {
  RULES=$rules node - > "$t/polkit.out" 2>&1 << 'EOF'
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const units = "org.freedesktop.systemd1.manage-units";
const cases = [];
for (const u of ["blockie-steam-dd@x.service", "blockie-steam-dd@alpha.zip.service", "blockie-steam-dd@account.service"]) {
  cases.push([units, "blockie", u, "start", "yes"]);
  cases.push([units, "blockie", u, "stop", "yes"]);
  for (const v of ["restart", "reload", "kill", "reset-failed"]) {
    cases.push([units, "blockie", u, v, "none"]);
  }
  cases.push([units, "blockie-steam", u, "start", "none"]);
  cases.push([units, "other", u, "stop", "none"]);
}
for (const u of ["blockie-steam-dd@.service", "blockie-steam-dd@X.service", "blockie-steam-dd@x.service.d",
                 "blockie-steam-dd@x;y.service", "blockie-steam-dd@../x.service", "blockie-ports-sync.service",
                 "waydroid-container.service", "blockie-steam-ddx@x.service"]) {
  cases.push([units, "blockie", u, "start", "none"]);
}
cases.push(["org.freedesktop.systemd1.manage-unit-files", "blockie", "blockie-steam-dd@x.service", "start", "none"]);
let bad = 0;
for (const [id, user, unit, verb, want] of cases) {
  const details = { unit: unit, verb: verb };
  const action = { id: id, lookup: (k) => details[k] };
  let got = "none";
  for (const r of rules) {
    const v = r(action, { user: user });
    if (v !== undefined) {
      got = v;
      break;
    }
  }
  if (got !== want) {
    console.log(`${id} ${user} ${verb} ${unit}: ${got}, want ${want}`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
EOF
  local rc=$?
  [[ $rc == 0 ]] || sed 's/^/  /' "$t/polkit.out"
  res $rc "polkit: blockie may start and stop blockie-steam-dd@ instances, no other unit, verb or user"
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "ports-steam: polkit needs node" >&2; exit 2; }
  polkit
  done_
fi
if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/ports-steam.sh polkit) evaluates the rules"
fi

[[ -e /run/.containerenv ]] ||
  { echo "ports-steam: runs only in a container, it starts fake units and a fake DepotDownloader" >&2; exit 2; }
unit=/usr/lib/systemd/system/blockie-steam-dd@.service
[[ -f $unit ]] || unit=$sf/usr/lib/systemd/system/blockie-steam-dd@.service
helper=/usr/libexec/blockie/blockie-ports
[[ -x $helper ]] || helper=$sf/usr/libexec/blockie/blockie-ports

if [[ $unit == /usr/* ]]; then
  mkdir -m 0700 "$t/ddhome"
  v=$(HOME=$t/ddhome /usr/libexec/blockie/depotdownloader -V 2>&1)
  rc=$?
  [[ $rc == 0 && $v == "DepotDownloader v3.4.0"* ]]
  ok=$?
  if [[ $ok != 0 ]]; then
    echo "  rc $rc, output:"
    head -n 20 <<< "$v" | sed 's/^/    /'
    echo "  dotnet --list-runtimes:"
    /usr/bin/dotnet --list-runtimes 2>&1 | head -n 10 | sed 's/^/    /'
  fi
  res $ok "depotdownloader -V in the image with a HOME that exists prints 3.4.0 and exits 0"
  [[ -x /usr/bin/dotnet ]] && rpm -qf /usr/bin/dotnet | grep -q '^dotnet-host-'
  res $? "/usr/bin/dotnet comes from dotnet-host: $(readlink -f /usr/bin/dotnet) $(rpm -qf /usr/bin/dotnet 2>&1)"
  echo "  setpriv: $(rpm -qf /usr/bin/setpriv 2>&1), systemd-coredump: $(rpm -q systemd-coredump 2>&1), libicu: $(rpm -q libicu 2>&1)"
  policy=/usr/share/polkit-1/actions/org.freedesktop.login1.policy
  python3 - "$policy" << 'EOF'
import re
import sys
s = open(sys.argv[1]).read()
m = re.search(r'<action id="org.freedesktop.login1.inhibit-block-idle">.*?<allow_any>(\w+)</allow_any>', s, re.S)
sys.exit(0 if m and m.group(1) == "yes" else 1)
EOF
  res $? "logind lets any user take the idle block inhibitor (inhibit-block-idle allow_any yes), so no idle polkit rule"
  systemd-sysusers > /dev/null 2>&1
  [[ $(getent passwd | awk -F: '$3 == 1001 { print $1 }') == blockie-steam &&
    $(getent group | awk -F: '$3 == 1001 { print $1 }') == blockie-steam &&
    $(id -u blockie-steam):$(id -g blockie-steam) == 1001:1001 ]]
  res $? "uid 1001 and gid 1001 name blockie-steam and nothing else"
  systemd-analyze verify --man=no "$unit" > "$t/verify.out" 2>&1
  rc=$?
  [[ $rc == 0 ]] || sed 's/^/  /' "$t/verify.out"
  res $rc "systemd-analyze verify reads the unit"
fi

ok=0
want=("User=blockie-steam" "Group=blockie-steam" "UMask=0027" "PrivateTmp=yes" "StandardInput=null" "StandardOutput=null"
  "StandardError=null" "LimitCORE=0" "OOMScoreAdjust=1000" "MemoryMax=768M" "NoNewPrivileges=yes" "ProtectSystem=strict"
  "ReadWritePaths=/var/lib/blockie/data/steam /var/lib/blockie/data/steam-dl /run/blockie-steam" "RuntimeMaxSec=6h"
  "TimeoutStopSec=5s" "KillMode=control-group" "Type=exec"
  "ExecStart=/usr/libexec/blockie/blockie-ports steam-unit %i" "ExecStopPost=/usr/bin/rm -f /run/blockie-steam/%i.fifo"
  "Environment=BLOCKIE_DD_CONFIG=/var/lib/blockie/data/steam/account.config BLOCKIE_DD_DEVICE=Blockie"
  "Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_EnableDiagnostics=0 DOTNET_DbgEnableMiniDump=0"
  "Environment=DOTNET_GCHeapHardLimit=0x20000000" "Environment=HOME=/var/lib/blockie/data/steam/home TMPDIR=/tmp"
  "Environment=SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem")
for l in "${want[@]}"; do
  grep -qxF "$l" "$unit" || { ok=1; echo "  no '$l'"; }
done
! grep -qE '^(SupplementaryGroups|DynamicUser|AmbientCapabilities)=' "$unit" || { ok=1; echo "  extra groups or capabilities"; }
! grep -q '^\[Install\]' "$unit" || { ok=1; echo "  installable"; }
res $ok "unit: blockie-steam with no extra group, umask 0027, private tmp, null output, no core, limits, three writable paths"

d=/usr/lib/blockie/data-tmpfiles.conf
[[ -f $d ]] || d=$sf/usr/lib/blockie/data-tmpfiles.conf
r=/usr/lib/tmpfiles.d/blockie.conf
[[ -f $r ]] || r=$sf/usr/lib/tmpfiles.d/blockie.conf
s=/usr/lib/sysusers.d/blockie.conf
[[ -f $s ]] || s=$sf/usr/lib/sysusers.d/blockie.conf
grep -qxF 'd /var/lib/blockie/data/steam 0700 blockie-steam blockie-steam -' "$d" &&
  grep -qxF 'd /var/lib/blockie/data/steam-dl 2750 blockie-steam blockie -' "$d" &&
  grep -qxF 'd /run/blockie-steam 2750 blockie-steam blockie -' "$r" &&
  grep -qxF 'd /run/blockie-steam/req 2750 blockie blockie-steam -' "$r" &&
  grep -qxF 'g blockie-steam 1001' "$s" && grep -qxF 'u blockie-steam 1001:1001 "Blockie Steam" /var/lib/blockie/data/steam' "$s"
res $? "tmpfiles: steam/ 0700 and steam-dl/ 2750 on the data partition, /run/blockie-steam and req/ 2750; blockie-steam pinned at 1001:1001"

shipped=/usr/share/blockie/ports
[[ -f $shipped/steam-map.tsv ]] || shipped=$sf/usr/share/blockie/ports
mkdir -p "$t/py"
PORTS_BIN=$helper FAKE_HM=$here/ports-helper/fakehm FIXTURES=$here/ports-steam T=$t/py SHIPPED=$shipped \
  timeout -k 10 600 python3 "$here/ports-steam.py" > "$t/py.out" 2>&1
rc=$?
cat "$t/py.out"
n=$(grep -c '^FAIL ' "$t/py.out")
fails=$((fails + n))
(( rc == 0 || n > 0 )) || { echo "FAIL python cases ended with rc $rc"; fails=$((fails + 1)); }
done_
