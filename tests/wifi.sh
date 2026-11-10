#!/usr/bin/env bash
set -euo pipefail

fail() { echo "wifi: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")" && pwd)
rules=${NETWORK_RULES:-/usr/share/polkit-1/rules.d/50-blockie-network.rules}
[[ -f $rules ]] || rules=$here/../system_files/usr/share/polkit-1/rules.d/50-blockie-network.rules
grants=(org.freedesktop.NetworkManager.enable-disable-wifi)

polkit() {
  RULES=$rules GRANTS="${grants[*]}" node - << 'EOF' || fail "polkit: blockie may use NetworkManager's enable-disable-wifi, nothing else"
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const nm = "org.freedesktop.NetworkManager.";
const grants = process.env.GRANTS.split(" ");
const others = ["network-control", "wifi.scan", "settings.modify.system", "enable-disable-network", "reload",
  "sleep-wake", "enable-disable-wwan", "enable-disable-wimax", "wifi.share.protected", "wifi.share.open",
  "settings.modify.own", "settings.modify.hostname", "settings.modify.global-dns", "checkpoint-rollback",
  "enable-disable-statistics", "enable-disable-connectivity-check", "enable-disable-wifi2", "network-control2",
  "wifi", "settings.modify"].map((a) => nm + a);
const cases = [];
for (const id of grants) {
  cases.push([id, "blockie", "yes"]);
  for (const user of ["blockie-set", "root", "nobody", "blockie2"]) {
    cases.push([id, user, "none"]);
  }
  cases.push([id.replace(nm, "org.freedesktop.NetworkManagerX."), "blockie", "none"]);
}
for (const id of others) {
  cases.push([id, "blockie", "none"]);
}
cases.push(["org.freedesktop.systemd1.manage-units", "blockie", "none"]);
cases.push(["org.freedesktop.timedate1.set-timezone", "blockie", "none"]);
cases.push(["org.freedesktop.login1.power-off", "blockie", "none"]);
let bad = 0;
for (const [id, user, want] of cases) {
  const action = { id: id, lookup: () => undefined };
  let got = "none";
  for (const r of rules) {
    const v = r(action, { user: user });
    if (v !== undefined) {
      got = v;
      break;
    }
  }
  if (got !== want) {
    console.log(`${id} ${user}: ${got}, want ${want}`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
EOF
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "wifi: polkit needs node" >&2; exit 2; }
  polkit
  echo "wifi: polkit ok"
  exit 0
fi

rpm -q blk-wmt blockie-tools wpa_supplicant NetworkManager-wifi iw wireless-regdb > /dev/null || fail "packages"
for f in blk-wmt blockie-wifi; do
  [[ -x /usr/libexec/blockie/$f ]] || fail "/usr/libexec/blockie/$f not executable"
done
[[ $(od -A n -t x1 -N 4 /usr/libexec/blockie/blk-wmt | tr -d ' ') == 7f454c46 ]] || fail "blk-wmt is not an ELF"
[[ -f /usr/lib/firmware/regulatory.db && -f /usr/lib/firmware/regulatory.db.p7s ]] || fail "regulatory.db"
[[ $(stat -L -c %d:%i /lib/firmware/regulatory.db) == $(stat -L -c %d:%i /usr/lib/firmware/regulatory.db) ]] ||
  fail "/lib/firmware/regulatory.db is not the /usr/lib one"
compgen -G '/usr/lib64/NetworkManager/*/libnm-device-plugin-wifi.so' > /dev/null || fail "NetworkManager wifi plugin"

for u in blockie-wifi.service blockie-regdom.service; do
  [[ $(readlink -f "/etc/systemd/system/multi-user.target.wants/$u") == "/usr/lib/systemd/system/$u" ]] ||
    fail "$u not enabled"
  grep -qx 'Before=.*NetworkManager.service.*' "/usr/lib/systemd/system/$u" || fail "$u not before NetworkManager"
done
grep -qx 'After=blockie-wifi.service' /usr/lib/systemd/system/blockie-regdom.service || fail "regdom not after wifi"
grep -qx 'ExecStart=/usr/bin/iw reg set JP' /usr/lib/systemd/system/blockie-regdom.service || fail "regdom country"
grep -qxF "ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do iw reg get | awk \"/^global/ { g = 1; next } g && /^country / { print; exit }\" | grep -q \"^country JP:\" && exit 0; sleep 0.5; done; exit 1'" \
  /usr/lib/systemd/system/blockie-regdom.service ||
  fail "regdom does not check the country"
[[ $(< /etc/sysconfig/regdomain) == COUNTRY=JP ]] || fail "/etc/sysconfig/regdomain is not COUNTRY=JP"
for l in RefuseManualStop=yes IgnoreOnIsolate=yes RemainAfterExit=yes ConditionPathIsDirectory=/run/blockie TimeoutStartSec=600; do
  grep -qxF "$l" /usr/lib/systemd/system/blockie-wifi.service || fail "blockie-wifi.service lacks $l"
done
! grep -q '^RuntimeDirectory=' /usr/lib/systemd/system/blockie-wifi.service || fail "blockie-wifi.service would remove /run/blockie"
for d in /etc/NetworkManager/system-connections /usr/lib/NetworkManager/system-connections; do
  [[ ! -d $d ]] || [[ -z $(find "$d" -mindepth 1 -print -quit) ]] || fail "$d is not empty"
done
only='unmanaged-devices=interface-name:ap0;interface-name:wlan1;interface-name:p2p0;interface-name:waydroid0;interface-name:veth*'
fw='firewall-backend=none'
for l in "$only" "$fw"; do
  grep -qxF "$l" /usr/lib/NetworkManager/conf.d/50-blockie-wifi.conf || fail "50-blockie-wifi.conf lacks $l"
done
nm=$(NetworkManager --print-config 2> /dev/null) || fail "NetworkManager --print-config failed"
grep -qxF "$only" <<< "$nm" || fail "NetworkManager's merged config does not leave ap0, wlan1, p2p0, waydroid0 and veth* unmanaged"
grep -qxF "$fw" <<< "$nm" || fail "NetworkManager's merged config has a firewall backend"
[[ $(stat -c '%a %U' /usr/share/polkit-1/rules.d/50-blockie-network.rules 2> /dev/null) == '644 root' ]] ||
  fail "50-blockie-network.rules is not a 644 file owned by root"
for a in "${grants[@]}"; do
  grep -qF "id=\"$a\"" /usr/share/polkit-1/actions/org.freedesktop.NetworkManager.policy ||
    fail "the NetworkManager policy has no $a action"
done
if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/wifi.sh polkit) evaluates the rule"
fi
echo "wifi: ok"
