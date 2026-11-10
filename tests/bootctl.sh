#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
bc=$(readlink -f "${BOOTCTL:-/usr/bin/blockie-bootctl}")
ab=$(readlink -f "${ABCTL:-/usr/bin/abctl}")
top=$(mktemp -d "${TMPDIR:-/tmp}/bootctl.XXXXXX")
trap 'rm -rf "${top:?}"' EXIT
fails=0
ID=0f0e0d0c-0b0a-4908-8706-050403020100

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
    echo "bootctl: $fails failed"
    exit 1
  fi
  echo "bootctl: ok"
  exit 0
}

rules=${BOOT_RULES:-/usr/share/polkit-1/rules.d/50-blockie-boot.rules}
[[ -f $rules ]] || rules=$here/../system_files/usr/share/polkit-1/rules.d/50-blockie-boot.rules

polkit() {
  RULES=$rules node - > "$top/polkit.out" 2>&1 << 'EOF'
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const units = "org.freedesktop.systemd1.manage-units";
const cases = [];
for (const t of ["reboot", "android", "recovery", "fastboot"]) {
  cases.push([units, "blockie", `blockie-boot@${t}.service`, "start", "yes"]);
  cases.push([units, "blockie", `blockie-boot@${t}.service`, "stop", "none"]);
  cases.push([units, "blockie", `blockie-boot@${t}.service`, "restart", "none"]);
  cases.push([units, "other", `blockie-boot@${t}.service`, "start", "none"]);
}
for (const u of ["blockie-boot@test-b.service", "blockie-boot@healthy.service", "blockie-boot@.service",
                 "blockie-boot@android.service.d", "blockie-boot@Android.service", "blockie-boot@android;x.service",
                 "blockie-boot-state.service", "blockie-boot-healthy.service", "blockie-boot-ok.service"]) {
  cases.push([units, "blockie", u, "start", "none"]);
}
cases.push(["org.freedesktop.systemd1.manage-unit-files", "blockie", "blockie-boot@android.service", "start", "none"]);
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
  [[ $rc == 0 ]] || sed 's/^/  /' "$top/polkit.out"
  res $rc "polkit: blockie may start blockie-boot@ reboot, android, recovery and fastboot, nothing else"
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "bootctl: polkit needs node" >&2; exit 2; }
  polkit
  done_
fi
if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/bootctl.sh polkit) evaluates the rules"
fi

mkmisc() {
  python3 - "$@" << 'EOF'
import sys
import zlib
path, suffix, a, b = sys.argv[1:5]
kw = dict(x.split("=", 1) for x in sys.argv[5:])
bc = bytearray(32)
bc[0:2] = suffix.encode()
bc[4:8] = b"BCAB"
bc[8] = 1
bc[9] = 2
for i, s in enumerate((a, b)):
    p, t, ok = (int(v) for v in s.split("/"))
    bc[12 + 2 * i] = p | t << 4 | ok << 7
bc[28:32] = zlib.crc32(bytes(bc[:28])).to_bytes(4, "little")
if kw.get("crc") == "bad":
    bc[28] ^= 1
m = bytearray((i * 7 + 3) & 0xff for i in range(8192))
m[0:2048] = bytes(2048)
cmd = kw.get("cmd", "").encode()
m[0:len(cmd)] = cmd
rec = kw.get("rec", "").replace("\\n", "\n").encode()
m[64:64 + len(rec)] = rec
ref = kw.get("refresh", "").encode()
m[448:448 + len(ref)] = ref
m[0x800:0x820] = bc
with open(path, "wb") as f:
    f.write(m)
EOF
}

setup() {
  d=$top/$1
  shift
  mkdir -p "$d/run" "$d/state" "$d/etc" "$d/dev" "$d/bin" "$d/sys/block/mmcblk0/mmcblk0p6" "$d/sys/block/mmcblk0/mmcblk0p7"
  echo mmcblk0 > "$d/run/emmc"
  printf 'MAJOR=179\nDEVNAME=mmcblk0p6\nDEVTYPE=partition\nPARTNAME=boot_para\n' > "$d/sys/block/mmcblk0/mmcblk0p6/uevent"
  printf 'MAJOR=179\nDEVNAME=mmcblk0p7\nDEVTYPE=partition\nPARTNAME=misc\n' > "$d/sys/block/mmcblk0/mmcblk0p7/uevent"
  head -c 8192 /dev/zero > "$d/dev/mmcblk0p6"
  m=$d/dev/mmcblk0p7
  mkmisc "$m" "$@"
  echo "$ID" > "$d/bootid"
  : > "$d/run/product"
  : > "$d/calls"
  cat > "$d/bin/abctl" << EOF
#!/bin/sh
echo "abctl \$3" >> "$d/calls"
[ ! -f "$d/fail.\$3" ] || exit "\$(cat "$d/fail.\$3")"
[ -f "$d/old" ] || exec "$ab" "\$@"
"$ab" "\$@" > "$d/old.out"
rc=\$?
grep -vx 'bproof 1' "$d/old.out"
exit \$rc
EOF
  cat > "$d/bin/systemctl" << EOF
#!/bin/sh
echo "systemctl \$*" >> "$d/calls"
exit "\$(cat "$d/systemctl.rc" 2> /dev/null || echo 0)"
EOF
  chmod 755 "$d/bin/abctl" "$d/bin/systemctl"
}

run() {
  local lw=(BLOCKIE_BOOT_LOCK_WAIT=1)
  [[ -z ${LW+x} ]] || lw=()
  env PATH="$d/bin:$PATH" BLOCKIE_RUN="$d/run" BLOCKIE_BOOT_STATE="$d/state" BLOCKIE_ETC="$d/etc" BLOCKIE_SYSFS="$d/sys" \
    BLOCKIE_DEV="$d/dev" BLOCKIE_ABCTL="$d/bin/abctl" BLOCKIE_BOOT_ID="$d/bootid" "${lw[@]}" \
    timeout -k 5 30 "$bc" "$@" > "$d/out" 2>&1
  rc=$?
}

hold() {
  rm -f "$d/held"
  mkdir -p "$d/run/boot"
  ( exec 8>> "$d/run/boot/lock"; flock 8; : > "$d/held"; exec sleep "$1" ) &
  lp=$!
  for _ in $(seq 200); do
    [[ -e $d/held ]] && break
    sleep 0.05
  done
}

unhold() {
  kill "$lp" 2> /dev/null
  wait "$lp" 2> /dev/null
}

st() {
  "$ab" -d "$m" show 2> /dev/null |
    sed -n 's/^suffix //p; s/^slot . priority \([0-9]*\) tries \([0-9]*\) successful \([0-9]*\) .*/\1\/\2\/\3/p; s/^message //p' |
    paste -sd ' '
}
gate() { cat "$d/run/boot/state" 2> /dev/null; }
writes() { grep -v '^abctl show$' "$d/calls" | paste -sd '|'; }
gw() { printf '%s\n' "$@"; }
D='_a 15/3/0 13/1/1 zero'
U='_a 15/3/0 13/1/0 zero'
G0=$(gw state=default arm=default android=bootable return=host recovery=no fastboot=no)

setup healthy _a 15/2/0 13/1/1
run healthy
[[ $rc == 0 && $(st) == "$D" && $(writes) == "abctl default-a" && $(gate) == "$G0" && -e $d/run/boot/healthy ]] &&
  cmp -s <(head -c 4096 "$m") "$d/state/misc.last" && [[ $(stat -c %a "$d/run/boot/state") == 644 ]] &&
  [[ $(stat -c %a "$d/run/boot/lock") == 600 ]]
res $? "healthy on a 15/2/0, b 13/1/1: default-a, misc.last, the healthy marker, state=default with the gates (0644), the lock file 0600"
: > "$d/calls"
run healthy
[[ $rc == 0 && ! -s $d/calls && $(st) == "$D" ]] && grep -q 'already ran' "$d/out"
res $? "healthy once per boot: a second run reads and writes nothing"

setup kpoc _a 15/3/0 12/1/1
run healthy
[[ $rc == 0 && $(st) == "$D" && $(writes) == "abctl default-a" && $(gate) == "$G0" ]]
res $? "healthy on b 12 (a KPOC refund spent): default-a writes b 13"

setup same _a 15/3/0 13/1/1
run healthy
[[ $rc == 0 && $(st) == "$D" && -z $(writes) && $(gate) == "$G0" && -s $d/state/misc.last ]]
res $? "healthy on a block already at default-a: no write, state=default"

setup unproven _a 15/2/0 13/1/0
run healthy
[[ $rc == 0 && $(st) == "$U" && $(writes) == "abctl default-a" && $(gate) == "$G0" && -e $d/run/boot/healthy ]]
r1=$?
setup sameunproven _a 15/3/0 13/1/0
run healthy
[[ $rc == 0 && $(st) == "$U" && -z $(writes) && $(gate) == "$G0" ]]
res $((r1 || $?)) "healthy on an unproven b (successful 0): default-a keeps b 13/1/0; a block at 15/3/0, 13/1/0 needs no write"

setup testarm _a 15/0/0 14/1/1
run healthy
[[ $rc == 0 && $(st) == '_a 15/0/0 14/1/1 zero' && -z $(writes) && ! -e $d/run/boot/healthy && ! -e $d/state/misc.last ]] &&
  [[ $(gate) == "$(gw state=pending arm=test android=unavailable 'reason=test arm' return=host recovery=no fastboot=no)" ]]
res $? "healthy on a test arm (b 14): no write, no marker, state=pending reason=test arm"

setup menu _a 15/2/0 13/1/1 cmd=boot-recovery 'rec=recovery\n--blockie=menu'
: > "$d/etc/recovery"
run healthy
[[ $rc == 0 && $(st) == "$D" && $(writes) == "abctl default-a|abctl bcb-clear" ]] &&
  [[ $(cat "$d/state/recovery.state") == "$(gw recovery=no "base=$(sha256sum < "$d/etc/recovery" | cut -d' ' -f1)" "boot=$ID")" ]] &&
  [[ $(gate) == "$(gw state=default arm=default android=bootable return=host recovery=no fastboot=no)" ]]
res $? "healthy with a menu bcb: default-a before bcb-clear, recovery=no recorded with the base's sha256 and the boot id, recovery=no despite the base file"

setup menurefresh _a 15/2/0 13/1/1 cmd=boot-recovery 'rec=recovery\n--blockie=menu' refresh=blockie-refresh=3
: > "$d/etc/recovery"
[[ $(st) == '_a 15/2/0 13/1/1 command "boot-recovery" reason menu refresh 3' ]]
r1=$?
run healthy
[[ $rc == 0 && $(st) == "$D" && $(writes) == "abctl default-a|abctl bcb-clear" ]] &&
  [[ $(cat "$d/state/recovery.state") == "$(gw recovery=no "base=$(sha256sum < "$d/etc/recovery" | cut -d' ' -f1)" "boot=$ID")" ]] &&
  cmp -s <(head -c 512 "$m") <(head -c 512 /dev/zero)
res $((r1 || $?)) "healthy with a menu bcb and a refresh counter at misc+448: recovery=no recorded, bcb-clear zeroes sector 0 with the counter"

setup fallback _a 15/0/0 13/1/1 cmd=boot-recovery 'rec=recovery\n--blockie=fallback'
: > "$d/etc/recovery"
run healthy
[[ $rc == 0 && $(st) == "$D" && $(writes) == "abctl default-a|abctl bcb-clear" && ! -e $d/state/recovery.state ]] &&
  [[ $(gate) == "$(gw state=default arm=default android=bootable return=host recovery=yes fastboot=no)" ]]
res $? "healthy with a fallback bcb: re-armed and cleared, recovery stays yes"

setup foreign _a 15/2/0 13/1/1 cmd=boot-recovery 'rec=recovery\n--wipe_data\n'
run healthy
[[ $rc == 0 && $(st) == '_a 15/3/0 13/1/1 command "boot-recovery"' && $(writes) == "abctl default-a" ]]
res $? "healthy leaves a bcb that is not ours (Android's --wipe_data) in place"

setup reset _a 15/7/0 15/7/0
run healthy
[[ $rc == 0 && $(st) == "$U" && $(writes) == "abctl default-a" ]] &&
  [[ $(gate) == "$(gw state=default arm=default android=bootable reason=reset return=host recovery=no fastboot=no)" ]]
res $? "healthy on class reset (both 15/7/0): default-a (b 13/1/0, successful as read), state=default reason=reset"

setup mtkreset _a 15/7/1 15/7/0
run healthy
[[ $rc == 0 && $(st) == "$U" && $(writes) == "abctl default-a" ]] &&
  [[ $(gate) == "$(gw state=default arm=default android=bootable reason=reset return=host recovery=no fastboot=no)" ]]
res $? "healthy on MTK's default block (a 15/7/1, b 15/7/0): default-a gives a 15/3/0, b 13/1/0, reason=reset"

setup invalid _a 15/2/0 13/1/1 crc=bad
before=$(md5sum < "$m")
run healthy
[[ $rc == 1 && $(md5sum < "$m") == "$before" && -z $(writes) && ! -e $d/run/boot/healthy ]] &&
  [[ $(gate) == "$(gw state=error arm=other android=unavailable 'reason=misc invalid' return=host recovery=no fastboot=no)" ]]
res $? "healthy on class invalid: no write, state=error, exit 1"

setup bprio _b 14/3/0 15/1/1
run healthy
[[ $rc == 1 && -z $(writes) && $(sed -n 1p "$d/run/boot/state") == state=error ]] && grep -qx 'reason=slot b priority 15' "$d/run/boot/state"
res $? "healthy on b 15 (Android default): no write, state=error"

setup noproduct _a 15/2/0 13/1/1
rm -f "$d/run/product"
run healthy
[[ $rc == 1 && ! -s $d/calls && ! -e $d/run/boot/state && $(st) == '_a 15/2/0 13/1/1 zero' ]]
res $? "healthy on a boot that is not a product boot: refused, nothing read or written"

ok=0
for x in android recovery test-b; do
  setup "mark-$x" _a 15/2/0 13/1/1
  mkdir -p "$d/run/boot"
  : > "$d/run/boot/$x"
  run healthy
  [[ $rc == 0 && ! -s $d/calls && $(st) == '_a 15/2/0 13/1/1 zero' ]] || { ok=1; echo "  $x: rc $rc"; }
done
res $ok "healthy writes nothing while an android, recovery or test-b marker exists"

setup lock _a 15/2/0 13/1/1
hold 6
run healthy
unhold
[[ -e $d/held && $rc == 1 && ! -s $d/calls && ! -e $d/run/boot/healthy && ! -e $d/run/boot/state ]] && grep -q 'lock is busy' "$d/out"
res $? "a held boot lock refuses healthy before any read or marker"

setup lockand _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
hold 6
run android
unhold
[[ -e $d/held && $rc == 1 && ! -s $d/calls && ! -e $d/run/boot/android && $(st) == "$D" && $(gate) == "$G0" ]] &&
  grep -q 'android refused: the boot lock is busy' "$d/out"
res $? "a held boot lock refuses android before any read, marker or write"

setup lockboot _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
hold 12
t0=${EPOCHREALTIME//[!0-9]/}
LW='' run boot android
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
unhold
[[ $rc == 1 && ! -s $d/calls && $(st) == "$D" ]] && grep -q 'lock is busy' "$d/out" && ((ms >= 4500 && ms < 9000))
res $? "boot waits 5 s for the lock by default, then refuses with nothing read or written ($ms ms)"

setup gates _a 15/2/0 13/1/1
run gates
[[ $rc == 0 && $(gate) == "$(gw state=pending arm=default android=bootable return=host recovery=no fastboot=no)" ]]
r1=$?
run android
[[ $rc == 1 && $(st) == '_a 15/2/0 13/1/1 zero' && -z $(writes) && ! -e $d/run/boot/android ]] && grep -q 'state=pending' "$d/out"
r2=$?
run recovery
[[ $rc == 1 && -z $(writes) && ! -e $d/run/boot/recovery ]] && grep -q 'state=pending' "$d/out"
r3=$?
res $((r1 || r2 || r3)) "gates at boot write state=pending; android and recovery are refused before state=default, no marker"
: > "$d/calls"
run boot reboot
[[ $rc == 0 && $(paste -sd '|' "$d/calls") == "systemctl reboot" && $(sed -n 1p "$d/run/boot/state") == state=pending ]]
res $? "boot reboot has no state gate: at state=pending it calls systemctl reboot and writes nothing"

ok=0
for c in '13/1/1 default' '12/1/1 default' '14/1/1 test' '15/1/1 other' '0/0/0 other'; do
  read -r b w <<< "$c"
  a=15/2/0
  [[ $b != 15/1/1 ]] || a=14/3/0
  setup "arm-${b%%/*}" _a "$a" "$b"
  run gates
  [[ $rc == 0 ]] && grep -qx "arm=$w" "$d/run/boot/state" || { ok=1; echo "  b $b: $(paste -sd '|' "$d/run/boot/state")"; }
done
setup arm-reset _a 15/7/0 15/7/0
run gates
grep -qx arm=default "$d/run/boot/state" || { ok=1; echo "  reset"; }
: > "$d/calls"
run healthy
[[ $rc == 0 && $(writes) == "abctl default-a" && $(st) == "$U" ]] && grep -qx arm=default "$d/run/boot/state" &&
  grep -qx reason=reset "$d/run/boot/state" || { ok=1; echo "  reset healthy: rc $rc $(writes)"; }
setup arm-invalid _a 15/2/0 13/1/1 crc=bad
run gates
grep -qx arm=other "$d/run/boot/state" || { ok=1; echo "  invalid"; }
setup arm-keep _a 15/2/0 13/1/1
run gates
run healthy
run android
[[ $(st) == '_b 14/3/0 15/1/1 zero' ]] && grep -qx arm=default "$d/run/boot/state" || { ok=1; echo "  keep: $(paste -sd '|' "$d/run/boot/state")"; }
res $ok "gates write the boot's arm from b's priority (12 or 13 default, 14 test, else other; a reset block default, so healthy re-arms it; invalid other), later writes keep it"

setup gates2 _a 15/2/0 13/1/1
rm -f "$d/run/product"
run gates
[[ $rc == 0 ]] && grep -qx 'reason=not a product boot' "$d/run/boot/state"
r1=$?
printf 'state=default\n' > "$d/run/boot/state"
run gates
[[ $rc == 0 && $(gate) == state=default ]]
res $((r1 || $?)) "gates on a boot that is not a product boot says so; a second gates run leaves the file alone"

setup base _a 15/2/0 13/1/1
: > "$d/etc/return"
: > "$d/etc/recovery"
: > "$d/etc/fastboot"
run healthy
[[ $(gate) == "$(gw state=default arm=default android=bootable return=keys recovery=yes fastboot=yes)" ]]
res $? "the base files give return=keys, recovery=yes and fastboot=yes; missing files give host, no and no"

setup android _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
run android
[[ $rc == 0 && $(st) == '_b 14/3/0 15/1/1 zero' && $(writes) == "abctl hold-b" && -e $d/run/boot/android ]] &&
  [[ $(sed -n 1p "$d/run/boot/state") == state=android ]]
r1=$?
: > "$d/calls"
run android
[[ $rc == 1 && -z $(writes) ]]
res $((r1 || $?)) "android after healthy: hold-b (a 14/3/0, b 15/1/1, suffix _b), the android marker, state=android; a second android is refused"

setup unproven-android _a 15/2/0 13/1/0
run healthy
: > "$d/calls"
run android
[[ $rc == 0 && $(st) == '_b 14/3/0 15/1/0 zero' && $(writes) == "abctl hold-b" && -e $d/run/boot/android ]]
r1=$?
setup untested _a 15/2/0 13/1/0
mkdir -p "$d/run/boot"
printf 'state=default\n' > "$d/run/boot/state"
run android
[[ $rc == 1 && -z $(writes) && ! -e $d/run/boot/android ]] && grep -q 'slot b untested' "$d/out"
res $((r1 || $?)) "android on an unproven b after healthy (a 15/3/0): hold-b gives b 15/1/0, one try; refused with no marker while a reads 15/2/0, as abctl's hold-b rule"

setup noproof _a 15/2/0 13/1/1
: > "$d/old"
: > "$d/etc/recovery"
run healthy
[[ $rc == 1 && -z $(writes) && ! -e $d/run/boot/healthy ]] && grep -q 'no bproof 1' "$d/out" &&
  grep -qx state=error "$d/run/boot/state" && grep -qx 'reason=abctl without bproof' "$d/run/boot/state"
ok=$?
for x in android recovery test-b; do
  printf 'state=default\n' > "$d/run/boot/state"
  run "$x"
  [[ $rc == 1 && -z $(writes) && ! -e $d/run/boot/$x ]] && grep -q 'no bproof 1' "$d/out" &&
    grep -qx state=error "$d/run/boot/state" && grep -qx 'reason=abctl without bproof' "$d/run/boot/state" ||
    { ok=1; echo "  $x: rc $rc"; }
done
[[ $(st) == '_a 15/2/0 13/1/1 zero' ]] || ok=1
res $ok "an abctl whose show prints no bproof 1: healthy, android, recovery and test-b refuse before any write, no marker, misc unchanged, state=error reason=abctl without bproof"

setup holdfail _a 15/2/0 13/1/1
run healthy
echo 4 > "$d/fail.hold-b"
run android
[[ $rc == 1 && ! -e $d/run/boot/android ]] && grep -qx 'state=error' "$d/run/boot/state" && grep -qx 'reason=hold-b failed' "$d/run/boot/state"
r1=$?
setup holdref _a 15/2/0 13/1/1
run healthy
echo 1 > "$d/fail.hold-b"
run android
[[ $rc == 1 && ! -e $d/run/boot/android && $(gate) == "$G0" ]]
res $((r1 || $?)) "a failed hold-b removes the marker: exit 4 gives state=error, a refusal (exit 1) keeps state=default"

setup recovery _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
run recovery
[[ $rc == 1 && -z $(writes) && ! -e $d/run/boot/recovery ]] && grep -q 'not proven' "$d/out"
r1=$?
: > "$d/etc/recovery"
run recovery
[[ $rc == 0 && $(st) == '_a 15/3/0 13/1/1 command "boot-recovery" reason menu' && $(writes) == "abctl bcb-recovery" ]] &&
  [[ -e $d/run/boot/recovery && $(sed -n 1p "$d/run/boot/state") == state=recovery ]]
r2=$?
setup recno _a 15/2/0 13/1/1
echo proof-1 > "$d/etc/recovery"
printf 'recovery=no\nbase=%s\nboot=%s\n' "$(sha256sum < "$d/etc/recovery" | cut -d' ' -f1)" "$ID" > "$d/state/recovery.state"
run healthy
grep -qx recovery=no "$d/run/boot/state"
r3=$?
run recovery
[[ $rc == 1 && ! -e $d/run/boot/recovery ]]
r4=$?
setup recnew _a 15/2/0 13/1/1
echo proof-2 > "$d/etc/recovery"
printf 'recovery=no\nbase=%s\nboot=%s\n' "$(echo proof-1 | sha256sum | cut -d' ' -f1)" "$ID" > "$d/state/recovery.state"
run healthy
grep -qx recovery=yes "$d/run/boot/state"
res $((r1 || r2 || r3 || r4 || $?)) "recovery needs the base file: refused without it, bcb-recovery menu with it; recovery.state turns it to no only while its base sha256 matches"

setup bootrb _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
run boot reboot
[[ $rc == 0 && $(paste -sd '|' "$d/calls") == "systemctl reboot" && $(st) == "$D" ]]
res $? "boot reboot at state=default: systemctl reboot, no misc write"

setup bootand _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
run boot android
[[ $rc == 0 && $(writes) == "abctl hold-b|systemctl reboot" && $(st) == '_b 14/3/0 15/1/1 zero' ]]
r1=$?
setup undoand _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
echo 1 > "$d/systemctl.rc"
run boot android
[[ $rc == 1 && $(writes) == "abctl hold-b|systemctl reboot|abctl default-a" && $(st) == "$D" ]] &&
  [[ ! -e $d/run/boot/android && $(gate) == "$G0" ]] && grep -q 'write is undone' "$d/out"
r2=$?
setup undoforeign _a 15/2/0 13/1/1 cmd=boot-recovery 'rec=recovery\n--wipe_data\n'
run healthy
: > "$d/calls"
echo 1 > "$d/systemctl.rc"
run boot android
[[ $rc == 1 && $(writes) == "abctl hold-b|systemctl reboot|abctl default-a" && $(st) == '_a 15/3/0 13/1/1 command "boot-recovery"' ]]
res $((r1 || r2 || $?)) "boot android: hold-b, then the reboot; a failed reboot call runs default-a, no bcb-clear when sector 0 holds nothing of ours (a foreign bcb stays)"

setup undorec _a 15/2/0 13/1/1
: > "$d/etc/recovery"
run healthy
: > "$d/calls"
echo 1 > "$d/systemctl.rc"
run boot recovery
[[ $rc == 1 && $(writes) == "abctl bcb-recovery|systemctl reboot|abctl bcb-clear" && $(st) == "$D" && ! -e $d/run/boot/recovery ]]
res $? "boot recovery with a failed reboot call: the bcb is cleared again"

setup fastboot _a 15/2/0 13/1/1
run healthy
: > "$d/calls"
run boot fastboot
[[ $rc == 1 && ! -s $d/calls ]] && grep -q 'not proven' "$d/out"
r1=$?
: > "$d/etc/fastboot"
run boot fastboot
[[ $rc == 0 && $(paste -sd '|' "$d/calls") == "systemctl reboot bootloader" && $(st) == "$D" ]]
res $((r1 || $?)) "boot fastboot needs the base file, then systemctl reboot bootloader with no misc write"

ok=0
setup badtarget _a 15/2/0 13/1/1
for x in test-b healthy gates '' 'android x'; do
  read -ra args <<< "$x"
  run boot "${args[@]}"
  [[ $rc == 2 && ! -s $d/calls ]] || { ok=1; echo "  boot $x: rc $rc"; }
done
res $ok "boot takes only reboot, android, recovery and fastboot"

setup testb _a 15/2/0 13/1/1
run test-b
[[ $rc == 1 && ! -e $d/run/boot/test-b ]]
r1=$?
run healthy
: > "$d/calls"
run test-b
[[ $rc == 0 && $(writes) == "abctl test-b" && $(st) == '_b 14/3/0 15/1/0 zero' && -e $d/run/boot/test-b ]] &&
  [[ $(gate) == "$(gw state=pending arm=default android=unavailable 'reason=test b' return=host recovery=no fastboot=no)" ]]
r2=$?
run android
[[ $rc == 1 ]]
res $((r1 || r2 || $?)) "test-b only at state=default: a 14/3/0, b 15/1/0, state=pending, android refused after it"

setup status _a 15/2/0 13/1/1
run healthy
run status
[[ $rc == 0 ]] && grep -qx state=default "$d/out" && grep -qx "misc $m" "$d/out" && grep -qx 'class ours' "$d/out"
res $? "status prints the gate file and the misc decode"

setup nomisc _a 15/2/0 13/1/1
echo mmcblk9 > "$d/run/emmc"
run healthy
[[ $rc == 1 && $(st) == '_a 15/2/0 13/1/1 zero' ]] && grep -qx 'reason=misc unreadable' "$d/run/boot/state"
res $? "no misc partition on the recorded eMMC: state=error reason=misc unreadable"

if [[ -d /usr/lib/systemd/system && -f /usr/lib/systemd/system/blockie-boot@.service ]]; then
  ok=0
  bu=/usr/lib/systemd/system/blockie-boot@.service
  ru=/usr/lib/systemd/user/blockie-reboot@.service
  su=/usr/lib/systemd/system/blockie-boot-state.service
  for f in "$bu" "$ru"; do
    ! grep -q '^Condition' "$f" && grep -qx 'Type=oneshot' "$f" && ! grep -q '^\[Install\]' "$f" || { ok=1; echo "  $f"; }
  done
  grep -qx 'ExecStart=/usr/bin/blockie-bootctl boot %i' "$bu" && grep -qx 'TimeoutStartSec=15s' "$bu" &&
    grep -qx 'CollectMode=inactive-or-failed' "$bu" || { ok=1; echo "  $bu"; }
  grep -qx 'ExecStart=/usr/libexec/blockie/blockie-poweroff --reboot %i' "$ru" && grep -qx 'TimeoutStartSec=45s' "$ru" &&
    grep -qx 'Conflicts=blockie-poweroff.service' "$ru" || { ok=1; echo "  $ru"; }
  grep -qx 'ExecStart=/usr/bin/blockie-bootctl gates' "$su" &&
    [[ -L /etc/systemd/system/sysinit.target.wants/blockie-boot-state.service ]] || { ok=1; echo "  $su"; }
  xdg=$(mktemp -d)
  XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no "$ru" > "$top/verify" 2>&1 || { ok=1; sed 's/^/  /' "$top/verify"; }
  rm -rf "${xdg:?}"
  [[ $(stat -c '%a %U' /usr/share/polkit-1/rules.d/50-blockie-boot.rules 2> /dev/null) == '644 root' ]] || { ok=1; echo "  rules"; }
  res $ok "blockie-boot@ (15 s, collected when failed) and blockie-reboot@ (45 s, conflicts with blockie-poweroff) are oneshots with no Condition and no [Install]; the gate unit is wanted by sysinit.target"
fi

done_
