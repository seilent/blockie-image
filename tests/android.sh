#!/usr/bin/env bash
set -u

root=${BLOCKIE_ANDROID_ROOT:-}
lx=$root/usr/libexec/blockie
t=$(mktemp -d "${TMPDIR:-/tmp}/android.XXXXXX")
fails=0
trap 'rm -rf "${t:?}"' EXIT

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
    echo "android: $fails failed"
    exit 1
  fi
  echo "android: ok"
  exit 0
}

polkit() {
  RULES=$root/usr/share/polkit-1/rules.d/50-blockie-android.rules node - > "$t/polkit.out" 2>&1 << 'EOF'
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const units = "org.freedesktop.systemd1.manage-units";
const cases = [
  [units, "blockie", "waydroid-container.service", "start", "yes"],
  [units, "blockie", "waydroid-container.service", "stop", "yes"],
  [units, "blockie", "waydroid-container.service", "restart", "none"],
  [units, "blockie", "blockie-android-freeze@freeze.service", "start", "yes"],
  [units, "blockie", "blockie-android-freeze@thaw.service", "start", "yes"],
  [units, "blockie", "blockie-android-freeze@freeze.service", "stop", "none"],
  [units, "blockie", "blockie-android-freeze@x.service", "start", "none"],
  [units, "blockie", "blockie-android-prep.service", "start", "none"],
  [units, "blockie", "lxc.service", "start", "none"],
  [units, "other", "waydroid-container.service", "start", "none"],
  [units, "other", "blockie-android-freeze@thaw.service", "start", "none"],
  ["org.freedesktop.systemd1.manage-unit-files", "blockie", "waydroid-container.service", "start", "none"],
];
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
  res $rc "polkit: blockie may start and stop waydroid-container and start the two freeze instances, nothing else"
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "android: polkit needs node" >&2; exit 2; }
  polkit
  done_
fi
[[ -e /run/.containerenv ]] || { echo "android: runs only in the image container" >&2; exit 2; }

if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/android.sh polkit) evaluates the rules"
fi

ok=0
for f in blockie-data2 blockie-android-prep blockie-android-lxcd blockie-android-freeze blockie-android-check \
  blockie-android-run; do
  [[ -f $lx/$f && $(stat -c %a "$lx/$f") == 755 ]] || { ok=1; echo "  $f"; }
done
bash -n "$lx/blockie-data2" && bash -n "$lx/blockie-android-lxcd" && bash -n "$lx/blockie-android-check" &&
  sh -n "$lx/blockie-android-freeze" || ok=1
for f in blockie-android-prep blockie-android-run; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$lx/$f" || ok=1
done
res $ok "the android scripts are 755 and parse"

sd=/usr/lib/systemd/system
ud=/usr/lib/systemd/user
ok=0
for l in Requires=blockie-data2.service After=blockie-data2.service RequiresMountsFor=/var/lib/blockie/data2 \
  Type=oneshot ExecStart=/usr/libexec/blockie/blockie-android-prep WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-android-prep.service || { ok=1; echo "  prep: $l"; }
done
! grep -q '^RemainAfterExit=' $sd/blockie-android-prep.service || { ok=1; echo "  prep stays active, a start would not run it"; }
for l in DefaultDependencies=no Requires=blockie-data2.service After=blockie-data2.service Conflicts=shutdown.target \
  Before=shutdown.target PathChanged=/var/lib/blockie/data2/android/images/stamp Unit=blockie-android-prep.service \
  WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-android-prep.path || { ok=1; echo "  prep.path: $l"; }
done
for l in RequiresMountsFor=/var/lib/blockie Type=oneshot RemainAfterExit=yes ExecStart=/usr/libexec/blockie/blockie-data2 \
  "ExecStartPost=/usr/bin/systemd-tmpfiles --create /usr/lib/blockie/data2-tmpfiles.conf" WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-data2.service || { ok=1; echo "  data2: $l"; }
done
drop=$sd/waydroid-container.service.d/50-blockie.conf
for l in Requires=blockie-android-prep.service After=blockie-android-prep.service \
  RequiresMountsFor=/var/lib/blockie/data2 ExecStartPre=/usr/libexec/blockie/blockie-android-lxcd \
  'ExecStop=-/usr/bin/timeout 6 /usr/bin/waydroid shell -- /system/bin/reboot -p' \
  'ExecStopPost=-/usr/bin/lxc-stop -P /var/lib/waydroid/lxc -n waydroid -k' \
  'ExecStopPost=-/usr/bin/sync -f /var/lib/blockie/data2' TimeoutStopSec=15; do
  grep -qxF "$l" "$drop" || { ok=1; echo "  container: $l"; }
done
[[ $(grep '^ExecStopPost=' "$drop" | head -n 1) == *lxc-stop* ]] || ok=1
for u in blockie-data2.service blockie-android-prep.service blockie-android-prep.path; do
  [[ -L /etc/systemd/system/multi-user.target.wants/$u ]] || { ok=1; echo "  $u not enabled"; }
done
[[ -z $(find /etc/systemd/system /usr/lib/systemd/system -path '*.wants/*' -name waydroid-container.service) ]] ||
  { ok=1; echo "  waydroid-container.service enabled"; }
f=$sd/blockie-android-freeze@.service
grep -qx 'Type=oneshot' "$f" && grep -qx 'ExecStart=/usr/libexec/blockie/blockie-android-freeze %i' "$f" &&
  ! grep -q '^\[Install\]' "$f" || { ok=1; echo "  freeze@"; }
[[ $(cat "$sd/blockie-android-freeze@freeze.service.d/50-blockie.conf") == $'[Unit]\nConflicts=blockie-android-freeze@thaw.service\nAfter=blockie-android-freeze@thaw.service' ]] ||
  { ok=1; echo "  freeze and thaw do not conflict"; }
au=$ud/blockie-android.service
for l in 'UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH VK_DRIVER_FILES' \
  Environment=XDG_DATA_HOME=/var/lib/blockie/data2/android/user ExecStart=/usr/libexec/blockie/blockie-android-run \
  'ExecStop=/usr/bin/systemctl stop waydroid-container.service' \
  'ExecStopPost=-/usr/bin/systemctl stop waydroid-container.service' TimeoutStartSec=infinity TimeoutStopSec=25; do
  grep -qxF "$l" "$au" || { ok=1; echo "  user unit: $l"; }
done
[[ $(grep '^ExecStartPre=' "$au") == $'ExecStartPre=/usr/bin/mountpoint -q /var/lib/blockie/data2\nExecStartPre=/usr/bin/systemctl start waydroid-container.service' ]] ||
  { ok=1; echo "  user unit ExecStartPre order"; }
! grep -q '^\[Install\]' "$au" || { ok=1; echo "  user unit has [Install]"; }
systemd-analyze verify --man=no $sd/waydroid-container.service $sd/blockie-android-prep.service $sd/blockie-android-prep.path \
  $sd/blockie-data2.service \
  > "$t/verify" 2>&1 || { ok=1; sed 's/^/  /' "$t/verify"; }
xdg=$t/xdg
mkdir -p "$xdg"
XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no "$au" > "$t/verify" 2>&1 || { ok=1; sed 's/^/  /' "$t/verify"; }
res $ok "units: prep after data2 and again on a stamp change, the container after prep with the generator and a bounded clean stop, the freeze instances conflict, the user unit starts and stops the container"

ok=0
[[ $(readlink /usr/share/waydroid-extra/images) == /var/lib/blockie/data2/android/images ]] || { ok=1; echo "  images link"; }
[[ $(cat /usr/lib/blockie/data2-tmpfiles.conf) == $'d /var/lib/blockie/data2/android 0755 root root -\nd /var/lib/blockie/data2/android/images 0755 root root -\nd /var/lib/blockie/data2/android/user 0700 blockie blockie -\nd /var/lib/blockie/data2/android/guest 0700 root root -\nd /var/lib/blockie/data2/android/guest/data 0771 blockie blockie -' ]] ||
  { ok=1; echo "  data2 tmpfiles"; }
grep -qxF 'd /run/blockie-android 0755 root root -' /usr/lib/tmpfiles.d/blockie.conf || { ok=1; echo "  run dir"; }
[[ ! -e /usr/share/dbus-1/system-services/id.waydro.Container.service ]] || { ok=1; echo "  D-Bus activation"; }
[[ ! -e /var/lib/waydroid ]] || { ok=1; echo "  /var/lib/waydroid in the image"; }
rule=/usr/lib/udev/rules.d/62-blockie-pad.rules
[[ $(cat "$rule") == 'ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="AYANEO Controller", ATTRS{phys}=="ayaneo-gamepad/input0", ATTRS{id/bustype}=="0019", ATTRS{id/vendor}=="4001", ATTRS{id/product}=="0428", SYMLINK+="input/by-blockie/pad"' ]] ||
  { ok=1; echo "  pad rule"; }
! udevadm verify --help > /dev/null 2>&1 || udevadm verify --resolve-names=never "$rule" > /dev/null 2>&1 ||
  { ok=1; echo "  udevadm verify"; }
base=/usr/lib/waydroid/data/configs/config_base
for f in devices pad memory; do
  grep -qxF "lxc.include = /run/blockie-android/lxc.d/$f.conf" "$base" || { ok=1; echo "  config_base lacks $f.conf"; }
done
res $ok "image: the images link to data2, the data2 dirs, no D-Bus activation, no /var/lib/waydroid, the pad link rule, the three includes"

kl=/usr/share/blockie/android/Vendor_4001_Product_0428.kl
want='key 305   BUTTON_A
key 304   BUTTON_B
key 308   BUTTON_X
key 307   BUTTON_Y
key 310   BUTTON_L1
key 311   BUTTON_R1
key 312   BUTTON_L2
key 313   BUTTON_R2
key 314   BUTTON_SELECT
key 315   BUTTON_START
key 316   BUTTON_MODE

axis 0x09 GAS
axis 0x0a BRAKE
axis 0x10 HAT_X
axis 0x11 HAT_Y'
cmp -s <(printf '%s\n' "$want") "$kl"
res $? "keylayout: A on the bottom BTN_EAST, B on the right BTN_SOUTH, X left, Y top, shoulders, Select, Start, Mode, triggers as GAS and BRAKE, the D-pad as HAT"

conf=/usr/lib/blockie/sessions.d/android.conf
ok=0
for l in LABEL=Android UNIT=blockie-android.service APP_ID=Waydroid DEFAULT=no BACKGROUND=stop PARK_FIRST=yes \
  CHECK=/usr/libexec/blockie/blockie-android-check; do
  grep -qxF "$l" "$conf" || { ok=1; echo "  $l"; }
done
w=$(sed -n 's/^START_WAIT=//p' "$conf")
[[ $w =~ ^[0-9]+$ ]] && ((w >= 1 && w <= 600)) || { ok=1; echo "  START_WAIT=$w"; }
! grep -q '^SLICE=' "$conf" || ok=1
blockie-session list 2> /dev/null | grep -qxF $'android\tAndroid\tno' || { ok=1; echo "  blockie-session does not list android"; }
res $ok "sessions.d/android.conf: Android, stop in the background, park first, the check, no slice, listed"

c=$t/check
mkdir -p "$c/bin" "$c/run" "$c/data2/android/images"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$c" > "$c/bin/mountpoint"
chmod 755 "$c/bin/mountpoint"
ck() {
  PATH=$c/bin:$PATH BLOCKIE_DATA2_DIR=$c/data2 BLOCKIE_ANDROID_RUN=$c/run timeout 5 "$lx/blockie-android-check" > "$c/out" 2>&1
  rc=$?
}
cstate() {
  rm -f "${c:?}/run/state" "${c:?}/mounted" "${c:?}/data2/android/images/"*
  [[ $1 == - ]] || echo "$1" > "$c/run/state"
  [[ $2 != mounted ]] || : > "$c/mounted"
  [[ $3 != images ]] || : > "$c/data2/android/images/system.img"
  [[ $3 != images ]] || : > "$c/data2/android/images/vendor.img"
}
ok=0
for x in "-|no|no|1|not mounted" "missing no BLOCKIE_DATA2 partition on 11240000.mmc|no|no|1|no BLOCKIE_DATA2 partition" \
  "failed e2fsck -p /dev/mmcblk1p2 exited 4, not mounted|no|no|2|exited 4" "ok|no|images|1|not mounted" \
  "ok|mounted|no|1|no android/images/system.img" "-|mounted|images|2|prep not run" \
  "failed pin incomplete|mounted|images|2|pin incomplete" "missing no images/vendor.img|mounted|images|1|no images/vendor.img" \
  "ok|mounted|images|0|"; do
  IFS='|' read -r s m i want why <<< "$x"
  cstate "$s" "$m" "$i"
  ck
  [[ $rc == "$want" ]] && { [[ -z $why ]] && [[ ! -s $c/out ]] || grep -qF -- "$why" "$c/out"; } ||
    { ok=1; echo "  state '$s' $m $i: rc $rc $(cat "$c/out")"; }
done
res $ok "check: 0 only with data2 mounted, both images and state ok; 1 for a missing partition or image; 2 for fsck, prep failures and no prep, each with its reason"

part() {
  local p=$sys/devices/platform/$1/mmc_host/mmc0/mmc0:0001/block/$2/$3
  mkdir -p "$p" "$sys/class/block"
  printf 'MAJOR=179\nDEVNAME=%s\nDEVTYPE=partition\nPARTNAME=%s\n' "$3" "$4" > "$p/uevent"
  echo 1 > "$p/partition"
  ln -sfn "$p" "$sys/class/block/$3"
}
dsetup() {
  d=$t/data2-$1
  sys=$d/sys
  mkdir -p "$d/bin" "$d/dev" "$d/run"
  part 11240000.mmc mmcblk1 mmcblk1p2 BLOCKIE_DATA2
  part 11240000.mmc mmcblk1 mmcblk1p3 BLOCKIE_OS
  part 11240000.mmc mmcblk1 mmcblk1p4 BLOCKIE_DATA
  : > "$d/calls"
  printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$d" > "$d/bin/mountpoint"
  printf '#!/bin/sh\ncase $5 in TYPE) echo ext4 ;; LABEL) echo BLOCKIE_DATA2 ;; esac\n' > "$d/bin/blkid"
  printf '#!/bin/sh\necho "e2fsck $*" >> "%s/calls"\nexit $(cat "%s/fsck.rc" 2> /dev/null || echo 0)\n' "$d" "$d" > "$d/bin/e2fsck"
  printf '#!/bin/sh\necho "mount $*" >> "%s/calls"\n' "$d" > "$d/bin/mount"
  chmod 755 "$d/bin/"*
}
drun() {
  PATH=$d/bin:$PATH BLOCKIE_SYS=$sys BLOCKIE_DEV=$d/dev BLOCKIE_DATA2_DIR=$d/target BLOCKIE_ANDROID_RUN=$d/run \
    timeout 10 "$lx/blockie-data2" > "$d/out" 2>&1
  rc=$?
}
ok=0
dsetup one
drun
[[ $rc == 0 && $(tail -n 1 "$d/calls") == "mount -t ext4 -o rw,noatime,nodev,nosuid $d/dev/mmcblk1p2 $d/target" && ! -e $d/run/state ]] ||
  { ok=1; echo "  one: rc $rc $(cat "$d/calls")"; }
dsetup fsck
echo 4 > "$d/fsck.rc"
drun
[[ $rc == 1 && $(cat "$d/run/state") == "failed e2fsck -p $d/dev/mmcblk1p2 exited 4, not mounted" ]] && ! grep -q '^mount' "$d/calls" ||
  { ok=1; echo "  fsck: rc $rc $(cat "$d/run/state" 2> /dev/null)"; }
dsetup none
rm -f "${sys:?}/class/block/mmcblk1p2"
drun
[[ $rc == 1 && $(cat "$d/run/state") == "missing no BLOCKIE_DATA2 partition on 11240000.mmc" && ! -s $d/calls ]] ||
  { ok=1; echo "  none: rc $rc $(cat "$d/run/state" 2> /dev/null)"; }
res $ok "data2: the BLOCKIE_DATA2 partition mounted rw,noatime,nodev,nosuid with exec; e2fsck rc 4 and a missing partition refused with the reason in the state file"

p=$t/prep
mkdir -p "$p/bin" "$p/data2/android/images" "$p/work" "$p/run"
cp /usr/lib/waydroid/data/configs/config_base "$p/config_base"
sys1=$(printf '%064d' 1)
ven1=$(printf '%064d' 2)
zip=$(printf '%064d' 3)
pin() {
  printf 'system.img https://example.invalid/system.zip %s 4096 %s\nvendor.img https://example.invalid/vendor.zip %s 2048\n' \
    "$1" "$zip" "$2" > "$p/pin"
  printf 'system.img 4096 %s\nvendor.img 2048 %s\n' "$1" "$2" > "$p/data2/android/images/stamp"
}
pin "$sys1" "$ven1"
truncate -s 4096 "$p/data2/android/images/system.img"
truncate -s 2048 "$p/data2/android/images/vendor.img"
: > "$p/mounted"
echo 1.6.3-1.fc44.blockie > "$p/version"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$p" > "$p/bin/mountpoint"
printf '#!/bin/sh\ncat "%s/version"\n' "$p" > "$p/bin/rpm"
cat > "$p/bin/waydroid" << EOF
#!/usr/bin/python3
import configparser, os, sys
work = os.environ["BLOCKIE_WAYDROID_WORK"]
with open("$p/calls", "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
rc = int(open("$p/waydroid.rc").read()) if os.path.exists("$p/waydroid.rc") else 0
if rc == 0 and "init" in sys.argv:
    os.makedirs(work + "/rootfs", exist_ok=True)
    os.makedirs(work + "/overlay", exist_ok=True)
    cfg = configparser.ConfigParser()
    cfg.read(work + "/waydroid.cfg")
    cfg["waydroid"]["images_path"] = "/usr/share/waydroid-extra/images"
    cfg["waydroid"]["mount_overlays"] = "False"
    with open(work + "/waydroid.cfg", "w") as f:
        cfg.write(f)
sys.exit(rc)
EOF
chmod 755 "$p/bin/"*
prun() {
  : > "$p/calls"
  PATH=$p/bin:$PATH BLOCKIE_DATA2_DIR=$p/data2 BLOCKIE_ANDROID_RUN=$p/run BLOCKIE_WAYDROID_WORK=$p/work \
    BLOCKIE_ANDROID_PIN=${1:-$p/pin} BLOCKIE_WAYDROID_BASE=$p/config_base BLOCKIE_ANDROID_PAYLOAD=$p/payload \
    timeout 20 "$lx/blockie-android-prep" > "$p/out" 2>&1
  rc=$?
  st=$(cat "$p/run/state" 2> /dev/null)
}
cfgget() { python3 -c 'import configparser, sys; c = configparser.ConfigParser(); c.read(sys.argv[1]); print(c.get(sys.argv[2], sys.argv[3], fallback=""))' "$p/work/waydroid.cfg" "$1" "$2"; }

prun /usr/share/blockie/android.d/lineage-20-gapps.conf
shipped=/usr/share/blockie/android.d/lineage-20-gapps.conf
ok=0
[[ $(awk '{ print $1, NF }' "$shipped") == $'system.img 5\nvendor.img 5' ]] || { ok=1; echo "  shipped pin layout"; }
grep -q '^system\.img https://sourceforge\.net/projects/waydroid/files/images/system/lineage/waydroid_arm64/lineage-20\.0-[0-9]*-GAPPS-waydroid_arm64-system\.zip/download ' "$shipped" &&
  grep -q '^vendor\.img https://sourceforge\.net/projects/waydroid/files/images/vendor/waydroid_arm64/lineage-20\.0-[0-9]*-MAINLINE-waydroid_arm64-vendor\.zip/download ' "$shipped" ||
  { ok=1; echo "  shipped pin urls"; }
if awk '{ for (i = 1; i <= NF; i++) if ($i == "-") f = 1 } END { exit !f }' "$shipped"; then
  [[ $rc == 1 && $st == "failed pin incomplete" && ! -s $p/calls ]] || { ok=1; echo "  incomplete pin: rc $rc '$st'"; }
else
  [[ $st != "failed pin incomplete" && $st != "failed pin line"* ]] || { ok=1; echo "  complete pin refused: '$st'"; }
fi
res $ok "prep: the shipped pin names the GAPPS system and MAINLINE vendor zips; while a field is '-' prep refuses with pin incomplete and runs nothing"

ok=0
mkdir -p "$p/data2/android/images.old"
prun
[[ $rc == 0 && $st == ok && $(cat "$p/calls") == '--details-to-stdout init' ]] || { ok=1; echo "  first: rc $rc '$st' $(cat "$p/calls")"; }
for kv in properties:persist.waydroid.width:960 properties:persist.waydroid.height:720 properties:persist.waydroid.uevent:false \
  properties:persist.waydroid.suspend:false waydroid:suspend_action:freeze waydroid:mount_overlays:True; do
  IFS=: read -r sec key val <<< "$kv"
  [[ $(cfgget "$sec" "$key") == "$val" ]] || { ok=1; echo "  $sec $key: $(cfgget "$sec" "$key")"; }
done
cmp -s /usr/share/blockie/android/Vendor_4001_Product_0428.kl "$p/work/overlay/system/usr/keylayout/Vendor_4001_Product_0428.kl" &&
  [[ -d $p/work/overlay/vendor ]] || { ok=1; echo "  keylayout"; }
[[ $(sed -n 1p "$p/data2/android/prepared") == 'waydroid 1.6.3-1.fc44.blockie' && $(wc -l < "$p/data2/android/prepared") == 4 ]] ||
  { ok=1; echo "  prepared"; }
[[ ! -e $p/data2/android/images.old ]] || { ok=1; echo "  images.old kept"; }
res $ok "prep: first run writes the properties, pins freeze and overlays (back to True after init), runs init once, copies the keylayout, records the stamp, drops images.old"

ok=0
prun
[[ $rc == 0 && $st == ok && ! -s $p/calls ]] || { ok=1; echo "  again: rc $rc $(cat "$p/calls")"; }
echo 'lxc.mount.auto = proc' >> "$p/config_base"
prun
[[ $rc == 0 && $st == ok && $(cat "$p/calls") == '--details-to-stdout upgrade --offline' ]] || { ok=1; echo "  base: $(cat "$p/calls")"; }
prun
[[ ! -s $p/calls ]] || { ok=1; echo "  base again: $(cat "$p/calls")"; }
pin "$(printf '%064d' 4)" "$ven1"
prun
[[ $(cat "$p/calls") == '--details-to-stdout upgrade --offline' ]] || { ok=1; echo "  images: $(cat "$p/calls")"; }
echo 1.6.4-1.fc44.blockie > "$p/version"
prun
[[ $(cat "$p/calls") == '--details-to-stdout upgrade --offline' ]] || { ok=1; echo "  version: $(cat "$p/calls")"; }
prun
[[ $rc == 0 && ! -s $p/calls ]] || { ok=1; echo "  settled: $(cat "$p/calls")"; }
res $ok "prep: no change runs nothing; a new config_base, image stamp or waydroid version runs upgrade --offline once"

ok=0
mkdir -p "$p/payload" "$p/data2/android/images.old"
printf 'populated 1\nfrozen 0\n' > "$p/payload/cgroup.events"
echo 'lxc.mount.auto = sys:ro' >> "$p/config_base"
prun
[[ $rc == 1 && $st == "failed change pending, stop Android" && ! -s $p/calls && -d $p/data2/android/images.old ]] ||
  { ok=1; echo "  running: rc $rc '$st' $(cat "$p/calls")"; }
printf 'populated 0\nfrozen 0\n' > "$p/payload/cgroup.events"
prun
[[ $rc == 0 && $st == ok && $(cat "$p/calls") == '--details-to-stdout upgrade --offline' && ! -e $p/data2/android/images.old ]] ||
  { ok=1; echo "  stopped: rc $rc $(cat "$p/calls")"; }
rm -rf "${p:?}/payload"
res $ok "prep: with a populated payload nothing runs and the state says change pending; an empty leftover payload is not running, so the upgrade runs and the state is ok"

ok=0
rm -f "${p:?}/data2/android/images/vendor.img"
prun
[[ $rc == 1 && $st == "missing no images/vendor.img" && ! -s $p/calls ]] || { ok=1; echo "  missing: '$st'"; }
truncate -s 2047 "$p/data2/android/images/vendor.img"
prun
[[ $rc == 1 && $st == "failed images/vendor.img is 2047 bytes, the pin says 2048" ]] || { ok=1; echo "  size: '$st'"; }
truncate -s 2048 "$p/data2/android/images/vendor.img"
printf 'system.img 4096 %s\nvendor.img 2048 %s\n' "$(printf '%064d' 4)" "$(printf '%064d' 5)" > "$p/data2/android/images/stamp"
prun
[[ $rc == 1 && $st == "failed the image stamp does not match the pin" ]] || { ok=1; echo "  stamp: '$st'"; }
rm -f "${p:?}/data2/android/images/stamp"
prun
[[ $rc == 1 && $st == "failed no image stamp" ]] || { ok=1; echo "  no stamp: '$st'"; }
pin "$(printf '%064d' 4)" "$ven1"
rm -f "${p:?}/mounted"
prun
[[ $rc == 1 && $st == "missing $p/data2 is not mounted" ]] || { ok=1; echo "  unmounted: '$st'"; }
: > "$p/mounted"
rm -rf "${p:?}/work/rootfs"
echo 1 > "$p/waydroid.rc"
prun
[[ $rc == 1 && $st == "failed waydroid init exited 1" ]] || { ok=1; echo "  init fails: '$st'"; }
rm -f "${p:?}/waydroid.rc"
printf 'system.img https://example.invalid/s.zip - 4096\nvendor.img https://example.invalid/v.zip %s 2048\n' "$ven1" > "$p/pin2"
prun "$p/pin2"
[[ $rc == 1 && $st == "failed pin incomplete" ]] || { ok=1; echo "  dash: '$st'"; }
printf 'system.img https://example.invalid/s.zip %s 4096\n' "$sys1" > "$p/pin2"
prun "$p/pin2"
[[ $rc == 1 && $st == "failed pin incomplete" ]] || { ok=1; echo "  one image: '$st'"; }
res $ok "prep: a missing image is missing, a wrong size, stamp or no stamp, a failed init, a '-' or a missing image line is failed, each with the reason"

l=$t/lxcd
mkdir -p "$l/proc" "$l/run" "$l/bin" "$l/data2"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$l" > "$l/bin/mountpoint"
chmod 755 "$l/bin/mountpoint"
: > "$l/mounted"
echo ok > "$l/run/state"
printf 'Character devices:\n  1 mem\n  5 /dev/tty\n 10 misc\n 13 input\n136 pts\n488 binder\n489 dma_heap\n\nBlock devices:\n  7 loop\n490 binder\n' \
  > "$l/proc/devices"
printf ' 59 ashmem\n229 fuse\n239 uhid\n200 tun\n 61 binder\n' > "$l/proc/misc"
ln -s /dev/full "$l/pad"
lrun() {
  rm -rf "${l:?}/run/lxc.d"
  env PATH="$l/bin:$PATH" BLOCKIE_PROC="$l/proc" BLOCKIE_ANDROID_PAD="$l/pad" BLOCKIE_ANDROID_RUN="$l/run" \
    BLOCKIE_ANDROID_PAYLOAD="$l/payload" BLOCKIE_DATA2_DIR="$l/data2" "$@" timeout 10 "$lx/blockie-android-lxcd" > "$l/out" 2>&1
  rc=$?
}
a='lxc.cgroup2.devices.allow = c'
want="lxc.cgroup2.devices.deny = a
$a 1:3 rwm
$a 1:5 rwm
$a 1:7 rwm
$a 1:8 rwm
$a 1:9 rwm
$a 1:11 rwm
$a 5:0 rwm
$a 5:1 rwm
$a 5:2 rwm
$a 136:* rwm
$a 488:* rwm
$a 489:* rwm
$a 10:59 rwm
$a 10:229 rwm
$a 10:239 rwm
$a 10:200 rwm
$a 1:7 rwm"
ok=0
lrun
[[ $rc == 0 && $(cat "$l/run/lxc.d/devices.conf") == "$want" ]] || { ok=1; echo "  devices: rc $rc"; diff <(echo "$want") "$l/run/lxc.d/devices.conf"; }
[[ $(cat "$l/run/lxc.d/pad.conf") == "lxc.mount.entry = $l/pad dev/input/event-pad none bind,create=file 0 0" ]] || { ok=1; echo "  pad.conf"; }
[[ $(cat "$l/run/lxc.d/memory.conf") == $'lxc.cgroup2.memory.high = 1600M\nlxc.cgroup2.memory.max = 1900M' ]] || { ok=1; echo "  memory.conf"; }
res $ok "lxcd: deny all first, then c rules with rwm for the base nodes, the binder and dma_heap majors, the misc minors and the pad; the pad bind; memory high and max"

ok=0
lrun BLOCKIE_ANDROID_NODEVICES=1
[[ $rc == 0 && -f $l/run/lxc.d/devices.conf && ! -s $l/run/lxc.d/devices.conf && -s $l/run/lxc.d/pad.conf && -s $l/run/lxc.d/memory.conf ]] ||
  { ok=1; echo "  nodevices: rc $rc"; }
rm -f "${l:?}/pad"
sed -i '/ binder$/d' "$l/proc/devices"
lrun
[[ $rc == 0 && ! -s $l/run/lxc.d/pad.conf && $(tail -n 1 "$l/run/lxc.d/devices.conf") == "$a 10:200 rwm" ]] &&
  ! grep -q '488:' "$l/run/lxc.d/devices.conf" && grep -q 'no binder major' "$l/out" || { ok=1; echo "  no pad: rc $rc"; }
ln -s /dev/full "$l/pad"
res $ok "lxcd: BLOCKIE_ANDROID_NODEVICES=1 writes devices.conf empty; no pad gives an empty pad.conf and no pad rule; a missing major is logged and left out"

ok=0
mkdir -p "$l/payload/a/b" "$l/payload/c"
lrun
[[ $rc == 0 && ! -e $l/payload && -s $l/run/lxc.d/devices.conf ]] && grep -q 'removed the stale' "$l/out" || { ok=1; echo "  stale: rc $rc"; }
mkdir -p "$l/payload"
echo 'populated 1' > "$l/payload/cgroup.events"
lrun
[[ $rc == 1 && -d $l/payload && ! -e $l/run/lxc.d/devices.conf ]] && grep -q 'still holds processes' "$l/out" || { ok=1; echo "  busy: rc $rc"; }
rm -rf "${l:?}/payload"
res $ok "lxcd: an empty leftover payload cgroup is removed before lxc starts; one that holds processes fails the start and writes nothing"

ok=0
echo 'failed pin incomplete' > "$l/run/state"
lrun
[[ $rc == 1 && ! -e $l/run/lxc.d/devices.conf ]] && grep -q "state is 'failed pin incomplete', not ok" "$l/out" || { ok=1; echo "  state: rc $rc"; }
rm -f "${l:?}/run/state"
lrun
[[ $rc == 1 && ! -e $l/run/lxc.d/devices.conf ]] && grep -q "state is 'none', not ok" "$l/out" || { ok=1; echo "  no state: rc $rc"; }
echo ok > "$l/run/state"
rm -f "${l:?}/mounted"
lrun
[[ $rc == 1 && ! -e $l/run/lxc.d/devices.conf ]] && grep -q 'is not mounted' "$l/out" || { ok=1; echo "  unmounted: rc $rc"; }
: > "$l/mounted"
res $ok "lxcd: the container start is refused unless data2 is mounted and the prep state is ok, so a start that skips the prep dependency fails here"

z=$t/freeze
mkdir -p "$z/bin" "$z/payload"
printf '#!/bin/sh\necho "systemd-run $*" >> "%s/calls"\n' "$z" > "$z/bin/systemd-run"
chmod 755 "$z/bin/systemd-run"
zrun() {
  : > "$z/calls"
  PATH=$z/bin:$PATH BLOCKIE_ANDROID_PAYLOAD=$z/payload timeout 5 "$lx/blockie-android-freeze" "$@" > "$z/out" 2>&1
  rc=$?
}
ok=0
echo 0 > "$z/payload/cgroup.freeze"
zrun freeze
[[ $rc == 0 && $(cat "$z/payload/cgroup.freeze") == 1 && $(cat "$z/calls") == "systemd-run --quiet --no-block --collect --on-active=2 /usr/bin/cat $z/payload/cgroup.events" ]] ||
  { ok=1; echo "  freeze: rc $rc $(cat "$z/calls")"; }
zrun thaw
[[ $rc == 0 && $(cat "$z/payload/cgroup.freeze") == 0 ]] || { ok=1; echo "  thaw: rc $rc"; }
rm -rf "${z:?}/payload"
zrun freeze
[[ $rc == 0 && ! -s $z/calls ]] || { ok=1; echo "  absent: rc $rc"; }
zrun stop
[[ $rc == 2 ]] || { ok=1; echo "  bad: rc $rc"; }
res $ok "freeze helper: writes 1 or 0 to cgroup.freeze and schedules the cgroup.events log 2 s on without waiting, exits 0 with no payload"

h=$t/hooks
mkdir -p "$h/bin" "$h/run" "$h/rundir" "$h/sys/class/leds/lcd-backlight" "$h/payload"
cat > "$h/bin/systemctl" << EOF
#!/bin/sh
case "\$*" in
  '--user show -P ActiveState blockie-game.scope') echo inactive ;;
  '--user is-active --quiet blockie-game.scope') exit 3 ;;
  '--user show -P FreezerState blockie-emulation.slice') echo running ;;
  *) echo "systemctl \$*" >> "$h/log" ;;
esac
EOF
cat > "$h/bin/busctl" << EOF
#!/bin/sh
case "\$*" in
  *' ListSessions') echo 'a(susso) 1 "7" $(id -u) "blockie" "seat0" "/org/freedesktop/login1/session/_37"' ;;
  *' SetBrightness '*) for v; do :; done; echo "brightness \$v" >> "$h/log" ;;
  *PowerOff*) echo PowerOff >> "$h/log" ;;
esac
EOF
printf '#!/bin/sh\necho "wlopm $*" >> "%s/log"\n' "$h" > "$h/bin/wlopm"
printf '#!/bin/sh\necho sync >> "%s/log"\n' "$h" > "$h/bin/sync"
chmod 755 "$h/bin/"*
hrun() {
  : > "$h/log"
  echo "${2:-102}" > "$h/sys/class/leds/lcd-backlight/brightness"
  echo 255 > "$h/sys/class/leds/lcd-backlight/max_brightness"
  PATH=$h/bin:$PATH BLOCKIE_SYSFS=$h/sys XDG_RUNTIME_DIR=$h/run BLOCKIE_RUNDIR=$h/rundir BLOCKIE_ANDROID_PAYLOAD=$h/payload \
    timeout 10 "$1" > "$h/out" 2>&1
  rc=$?
}
freeze='systemctl start --no-block blockie-android-freeze@freeze.service'
ok=0
echo 'android blockie-android.service 7' > "$h/rundir/session-current"
hrun /usr/lib/blockie/hooks.d/blank-on
[[ $rc == 0 && $(cat "$h/log") == $'wlopm --off *\nbrightness 0\n'"$freeze" ]] || { ok=1; echo "  blank-on android: $(tr '\n' '|' < "$h/log")"; }
echo 'emulation blockie-frontend.service 8' > "$h/rundir/session-current"
hrun /usr/lib/blockie/hooks.d/blank-on
[[ $rc == 0 && $(cat "$h/log") == $'wlopm --off *\nbrightness 0' ]] || { ok=1; echo "  blank-on emulation: $(tr '\n' '|' < "$h/log")"; }
hrun /usr/lib/blockie/hooks.d/blank-off 0
[[ $rc == 0 && $(sed -n '1,2p' "$h/log") == $'systemctl start blockie-android-freeze@thaw.service\nwlopm --on *' ]] &&
  grep -qx 'brightness [1-9][0-9]*' "$h/log" || { ok=1; echo "  blank-off: $(tr '\n' '|' < "$h/log")"; }
hrun /usr/lib/blockie/hooks.d/screen-on 0
[[ $rc == 0 && $(sed -n 1p "$h/log") == 'wlopm --on *' && $(tail -n 1 "$h/log") == 'systemctl start --no-block blockie-android-freeze@thaw.service' ]] ||
  { ok=1; echo "  screen-on: $(tr '\n' '|' < "$h/log")"; }
hrun /usr/libexec/blockie/blockie-poweroff
a1=$(grep -n 'blockie-android-freeze@thaw' "$h/log" | cut -d: -f1)
c1=$(grep -nx 'systemctl stop waydroid-container.service' "$h/log" | cut -d: -f1)
s0=$(grep -nx sync "$h/log" | head -n 1 | cut -d: -f1)
s1=$(grep -nx sync "$h/log" | tail -n 1 | cut -d: -f1)
[[ -n $a1 && -n $c1 && -n $s0 && -n $s1 ]] && ((a1 < s0 && s0 < c1 && c1 < s1)) && [[ $(tail -n 1 "$h/log") == PowerOff ]] ||
  { ok=1; echo "  poweroff: $(tr '\n' '|' < "$h/log")"; }
rmdir "${h:?}/payload"
hrun /usr/lib/blockie/hooks.d/blank-off 0
prev=$(cat "$h/log")
hrun /usr/lib/blockie/hooks.d/screen-on 0
prev+=$(cat "$h/log")
hrun /usr/libexec/blockie/blockie-poweroff
! grep -q 'freeze\|waydroid-container' <<< "$prev$(cat "$h/log")" || { ok=1; echo "  no payload: a freeze unit was started"; }
res $ok "hooks: blank-on freezes Android after the screen is off only when android is current; blank-off thaws before the screen comes on; screen-on and blockie-poweroff thaw; poweroff syncs, stops the container and syncs again; nothing without a payload"

r=$t/run
mkdir -p "$r/bin" "$r/usr/lib/blockie/sessions.d" "$r/lib/tools/interfaces"
printf 'LABEL=Android\nUNIT=blockie-android.service\nAPP_ID=Waydroid\nSTART_WAIT=2\n' > "$r/usr/lib/blockie/sessions.d/android.conf"
: > "$r/lib/tools/__init__.py"
: > "$r/lib/tools/interfaces/__init__.py"
cat > "$r/lib/tools/interfaces/IPlatform.py" << EOF
import os
class P:
    def settingsGetString(self, mode, key):
        with open("$r/calls", "a") as f:
            f.write(f"get {mode} {key}\n")
        try:
            return open("$r/setting").read().strip()
        except FileNotFoundError:
            return "60000"
    def settingsPutInt(self, mode, key, value):
        with open("$r/calls", "a") as f:
            f.write(f"put {mode} {key} {value}\n")
        n = int(open("$r/putfail").read()) if os.path.exists("$r/putfail") else 0
        if n > 0:
            with open("$r/putfail", "w") as f:
                f.write(str(n - 1))
            return
        with open("$r/setting", "w") as f:
            f.write(str(value))
def get_service(args):
    return P()
EOF
cat > "$r/bin/waydroid" << EOF
#!/bin/sh
case "\$*" in
  show-full-ui)
    trap 'echo term >> "$r/ui"; exit 0' TERM
    echo start >> "$r/ui"
    [ ! -f "$r/ui.rc" ] || exit \$(cat "$r/ui.rc")
    while :; do sleep 0.05; done
    ;;
  'prop get sys.boot_completed') echo props >> "$r/ui"; cat "$r/boot" 2> /dev/null ;;
esac
EOF
printf '#!/bin/sh\n[ -e "%s/window" ]\n' "$r" > "$r/bin/wlrctl"
cat > "$r/bin/systemctl" << EOF
#!/bin/sh
case "\$*" in
  is-system-running) cat "$r/system" 2> /dev/null || echo running ;;
  *) cat "$r/unit" 2> /dev/null || echo active ;;
esac
EOF
chmod 755 "$r/bin/"*
rsetup() {
  rm -rf "${r:?}/payload" "${r:?}/window" "${r:?}/boot" "${r:?}/calls" "${r:?}/setting" "${r:?}/putfail" "${r:?}/ui" \
    "${r:?}/ui.rc" "${r:?}/unit" "${r:?}/system"
}
rstart() {
  PATH=$r/bin:$PATH BLOCKIE_ROOT=$r BLOCKIE_ANDROID_PAYLOAD=$r/payload BLOCKIE_WAYDROID_LIB=$r/lib BLOCKIE_ANDROID_STEP=0.05 \
    timeout 20 "$lx/blockie-android-run" > "$r/out" 2>&1 &
  rp=$!
}
rwait() {
  wait "$rp"
  rc=$?
}
until_() {
  local i n=${2:-100}
  for i in $(seq "$n"); do
    eval "$1" && return 0
    sleep 0.05
  done
  return 1
}
cg() {
  mkdir -p "$r/payload"
  printf 'populated %s\nfrozen %s\n' "$1" "${2:-0}" > "$r/payload/cgroup.events"
}

ok=0
rsetup
echo 0 > "$r/ui.rc"
rstart
rwait
[[ $rc == 1 ]] && grep -q 'exited before a window of Waydroid appeared' "$r/out" || { ok=1; echo "  early exit: rc $rc"; }
rsetup
rstart
rwait
[[ $rc == 1 && $(grep -c term "$r/ui") == 1 ]] && grep -q 'the Android payload was not populated within 2 s' "$r/out" ||
  { ok=1; echo "  no payload: rc $rc"; }
res $ok "run: show-full-ui ending with rc 0 before the window is a failure; no populated payload by START_WAIT fails and stops show-full-ui"

ok=0
rsetup
: > "$r/window"
echo 1 > "$r/boot"
cg 1
rstart
until_ '[[ $(cat "$r/setting" 2> /dev/null) == 2147483647 ]] && grep -q "screen_off_timeout is 2147483647" "$r/out"' ||
  { ok=1; echo "  not set"; }
[[ $(cat "$r/calls" 2> /dev/null) == $'get 1 screen_off_timeout\nput 1 screen_off_timeout 2147483647\nget 1 screen_off_timeout' ]] ||
  { ok=1; echo "  calls: $(tr '\n' '|' < "$r/calls")"; }
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  run ended early"; }
t0=${EPOCHREALTIME//[!0-9]/}
cg 0
rwait
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
[[ $rc == 1 && $(grep -c term "$r/ui") == 1 ]] && grep -q 'the Android payload ended$' "$r/out" && ((ms < 2000)) ||
  { ok=1; echo "  dead: rc $rc $ms ms"; }
res $ok "run: after boot_completed screen_off_timeout is read, set and read back once; populated 0 ends the unit with rc 1 at once ($ms ms) and stops show-full-ui"

ok=0
rsetup
: > "$r/window"
echo 1 > "$r/boot"
echo 2147483647 > "$r/setting"
cg 1
rstart
until_ 'grep -q "screen_off_timeout is 2147483647" "$r/out"' 200 || ok=1
[[ $(cat "$r/calls" 2> /dev/null) == $'get 1 screen_off_timeout\nget 1 screen_off_timeout' ]] || { ok=1; echo "  calls: $(tr '\n' '|' < "$r/calls")"; }
kill -TERM "$rp"
rwait
rsetup
: > "$r/window"
echo 1 > "$r/boot"
echo 1 > "$r/putfail"
cg 1
rstart
until_ 'grep -q "screen_off_timeout is 2147483647" "$r/out"' 200 || ok=1
[[ $(grep -c '^put' "$r/calls" 2> /dev/null) == 2 && $(cat "$r/setting") == 2147483647 ]] && grep -q 'not set (exit 1), trying again' "$r/out" ||
  { ok=1; echo "  retry: $(tr '\n' '|' < "$r/calls")"; }
kill -TERM "$rp"
rwait
rsetup
: > "$r/window"
echo 1 > "$r/boot"
echo 9 > "$r/putfail"
cg 1
rstart
until_ 'grep -q "after 3 tries, the next session tries again" "$r/out"' 300 || ok=1
[[ $(grep -c '^put' "$r/calls" 2> /dev/null) == 3 && ! -e $r/setting ]] || { ok=1; echo "  give up: $(tr '\n' '|' < "$r/calls")"; }
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  a failed set ended the unit"; }
kill -TERM "$rp"
rwait
[[ $rc == 0 ]] || { ok=1; echo "  term: rc $rc"; }
res $ok "run: no put when the value is already set; a put that does not read back is tried again, at most 3 times per session, and never ends the unit"

ok=0
rsetup
: > "$r/window"
echo 1 > "$r/boot"
cg 1 1
rstart
sleep 1
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  frozen ended the unit"; }
! grep -q props "$r/ui" && [[ ! -e $r/calls ]] || { ok=1; echo "  polled while frozen"; }
cg 1 0
until_ '[[ -e $r/calls ]]' || { ok=1; echo "  no poll after thaw"; }
kill -TERM "$rp"
rwait
res $ok "run: frozen 1 keeps the unit running and holds the boot poll, which would thaw Android; after the thaw it polls"

ok=0
rsetup
: > "$r/window"
cg 0
rstart
sleep 0.5
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  populated 0 before 1 ended the unit"; }
cg 1
until_ 'grep -q "payload is populated" "$r/out"' || ok=1
cg 0
rwait
[[ $rc == 1 ]] && grep -q 'the Android payload ended$' "$r/out" || { ok=1; echo "  dead after 1: rc $rc"; }
rsetup
: > "$r/window"
cg 0
rstart
rwait
[[ $rc == 1 ]] && grep -q 'not populated within 2 s' "$r/out" || { ok=1; echo "  never populated: rc $rc"; }
res $ok "run: populated 0 before the first populated 1 is a start, not a death, until START_WAIT; after populated 1 it is a death"

ok=0
rsetup
: > "$r/window"
cg 1
rstart
until_ 'grep -q "payload is populated" "$r/out"' || ok=1
sleep 0.3
rm -rf "${r:?}/payload"
rwait
[[ $rc == 1 ]] || { ok=1; echo "  removed: rc $rc"; }
rsetup
: > "$r/window"
cg 1
rstart
until_ 'grep -q "payload is populated" "$r/out"' || ok=1
echo deactivating > "$r/unit"
cg 0
rwait
[[ $rc == 0 ]] && grep -q 'ended while waydroid-container.service or the system stops' "$r/out" || { ok=1; echo "  stopping: rc $rc"; }
rsetup
: > "$r/window"
cg 1
rstart
until_ 'grep -q "payload is populated" "$r/out"' || ok=1
kill -TERM "$rp"
rwait
[[ $rc == 0 && $(grep -c term "$r/ui") == 1 ]] || { ok=1; echo "  term: rc $rc"; }
rsetup
: > "$r/window"
cg 1
echo 3 > "$r/ui.rc"
rstart
rwait
[[ $rc == 3 ]] || { ok=1; echo "  rc 3: rc $rc"; }
rsetup
: > "$r/window"
cg 1
rstart
until_ 'grep -q "payload is populated" "$r/out"' || ok=1
echo stopping > "$r/system"
cg 0
rwait
[[ $rc == 0 ]] && grep -q 'or the system stops' "$r/out" || { ok=1; echo "  system stopping: rc $rc"; }
rsetup
echo stopping > "$r/system"
echo 0 > "$r/ui.rc"
rstart
rwait
[[ $rc == 0 ]] && grep -q 'while the system stops' "$r/out" || { ok=1; echo "  ui ends while stopping: rc $rc"; }
res $ok "run: a removed payload is dead too; the payload or show-full-ui ending while the system stops is rc 0; a payload ending while the container unit stops, or a SIGTERM, ends with rc 0; show-full-ui's own rc passes through"

done_
