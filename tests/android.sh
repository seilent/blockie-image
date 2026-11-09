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
  [units, "blockie", "blockie-android-music.service", "start", "yes"],
  [units, "blockie", "blockie-android-music.service", "stop", "none"],
  [units, "blockie", "blockie-android-music.service", "restart", "none"],
  [units, "blockie", "blockie-android-music@x.service", "start", "none"],
  [units, "other", "blockie-android-music.service", "start", "none"],
  [units, "blockie", "blockie-android-pad.service", "start", "yes"],
  [units, "blockie", "blockie-android-pad.service", "stop", "none"],
  [units, "blockie", "blockie-android-pad.service", "restart", "none"],
  [units, "blockie", "blockie-android-pad@x.service", "start", "none"],
  [units, "other", "blockie-android-pad.service", "start", "none"],
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
  res $rc "polkit: blockie may start and stop waydroid-container and start the two freeze instances, the music and the pad unit, nothing else"
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
for f in blockie-android-prep blockie-android-lxcd blockie-android-freeze blockie-android-check blockie-android-run \
  blockie-android-music blockie-android-pad; do
  [[ -f $lx/$f && $(stat -c %a "$lx/$f") == 755 ]] || { ok=1; echo "  $f"; }
done
bash -n "$lx/blockie-android-lxcd" && bash -n "$lx/blockie-android-check" && bash -n "$lx/blockie-android-music" &&
  bash -n "$lx/blockie-android-pad" &&
  sh -n "$lx/blockie-android-freeze" || ok=1
for f in blockie-android-prep blockie-android-run; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$lx/$f" || ok=1
done
res $ok "the android scripts are 755 and parse"

sd=/usr/lib/systemd/system
ud=/usr/lib/systemd/user
ok=0
for l in Requires=blockie-data.service After=blockie-data.service RequiresMountsFor=/var/lib/blockie/data \
  Type=oneshot ExecStart=/usr/libexec/blockie/blockie-android-prep WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-android-prep.service || { ok=1; echo "  prep: $l"; }
done
! grep -q '^RemainAfterExit=' $sd/blockie-android-prep.service || { ok=1; echo "  prep stays active, a start would not run it"; }
for l in DefaultDependencies=no Requires=blockie-data.service After=blockie-data.service Conflicts=shutdown.target \
  Before=shutdown.target PathChanged=/var/lib/blockie/data/android/images/stamp Unit=blockie-android-prep.service \
  WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-android-prep.path || { ok=1; echo "  prep.path: $l"; }
done
drop=$sd/waydroid-container.service.d/50-blockie.conf
for l in Requires=blockie-android-prep.service After=blockie-android-prep.service \
  RequiresMountsFor=/var/lib/blockie/data ExecStartPre=/usr/libexec/blockie/blockie-android-lxcd \
  'ExecStop=-/usr/bin/timeout 6 /usr/bin/waydroid shell -- /system/bin/reboot -p' \
  'ExecStopPost=-/usr/bin/lxc-stop -P /var/lib/waydroid/lxc -n waydroid -k' \
  'ExecStopPost=-/usr/bin/sync -f /var/lib/blockie/data' TimeoutStopSec=15; do
  grep -qxF "$l" "$drop" || { ok=1; echo "  container: $l"; }
done
[[ $(grep '^ExecStopPost=' "$drop" | head -n 1) == *lxc-stop* ]] || ok=1
for u in blockie-data.service blockie-android-prep.service blockie-android-prep.path; do
  [[ -L /etc/systemd/system/multi-user.target.wants/$u ]] || { ok=1; echo "  $u not enabled"; }
done
[[ -z $(find /etc/systemd/system /usr/lib/systemd/system -path '*.wants/*' -name waydroid-container.service) ]] ||
  { ok=1; echo "  waydroid-container.service enabled"; }
f=$sd/blockie-android-freeze@.service
grep -qx 'Type=oneshot' "$f" && grep -qx 'ExecStart=/usr/libexec/blockie/blockie-android-freeze %i' "$f" &&
  ! grep -q '^\[Install\]' "$f" || { ok=1; echo "  freeze@"; }
[[ $(cat "$sd/blockie-android-freeze@freeze.service.d/50-blockie.conf") == $'[Unit]\nConflicts=blockie-android-freeze@thaw.service\nAfter=blockie-android-freeze@thaw.service' ]] ||
  { ok=1; echo "  freeze and thaw do not conflict"; }
f=$sd/blockie-android-music.service
for l in After=waydroid-container.service PartOf=waydroid-container.service CollectMode=inactive-or-failed Type=oneshot \
  TimeoutStartSec=infinity ExecStart=/usr/libexec/blockie/blockie-android-music; do
  grep -qxF "$l" "$f" || { ok=1; echo "  music: $l"; }
done
! grep -q '^\[Install\]' "$f" || { ok=1; echo "  music has [Install]"; }
f=$sd/blockie-android-pad.service
for l in After=waydroid-container.service PartOf=waydroid-container.service CollectMode=inactive-or-failed Type=oneshot \
  TimeoutStartSec=infinity ExecStart=/usr/libexec/blockie/blockie-android-pad; do
  grep -qxF "$l" "$f" || { ok=1; echo "  pad: $l"; }
done
! grep -q '^\[Install\]' "$f" || { ok=1; echo "  pad has [Install]"; }
au=$ud/blockie-android.service
for l in 'UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH VK_DRIVER_FILES' \
  Environment=XDG_DATA_HOME=/var/lib/blockie/data/android/user ExecStart=/usr/libexec/blockie/blockie-android-run \
  'ExecStop=/usr/bin/systemctl stop waydroid-container.service' \
  'ExecStopPost=-/usr/bin/systemctl stop waydroid-container.service' TimeoutStartSec=infinity TimeoutStopSec=25; do
  grep -qxF "$l" "$au" || { ok=1; echo "  user unit: $l"; }
done
[[ $(grep '^ExecStartPre=' "$au") == $'ExecStartPre=/usr/bin/mountpoint -q /var/lib/blockie/data\nExecStartPre=/usr/bin/systemctl start waydroid-container.service' ]] ||
  { ok=1; echo "  user unit ExecStartPre order"; }
! grep -q '^\[Install\]' "$au" || { ok=1; echo "  user unit has [Install]"; }
systemd-analyze verify --man=no $sd/waydroid-container.service $sd/blockie-android-prep.service $sd/blockie-android-prep.path \
  $sd/blockie-data.service $sd/blockie-android-music.service $sd/blockie-android-pad.service > "$t/verify" 2>&1 || { ok=1; sed 's/^/  /' "$t/verify"; }
xdg=$t/xdg
mkdir -p "$xdg"
XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no "$au" > "$t/verify" 2>&1 || { ok=1; sed 's/^/  /' "$t/verify"; }
res $ok "units: prep after data and again on a stamp change, the container after prep with the generator and a bounded clean stop, the freeze instances conflict, the music and pad oneshots after the container and part of it with no [Install], the user unit starts and stops the container"

ok=0
[[ $(readlink /usr/share/waydroid-extra/images) == /var/lib/blockie/data/android/images ]] || { ok=1; echo "  images link"; }
grep -qxF 'd /run/blockie-android 0755 root root -' /usr/lib/tmpfiles.d/blockie.conf || { ok=1; echo "  run dir"; }
[[ ! -e /usr/share/dbus-1/system-services/id.waydro.Container.service ]] || { ok=1; echo "  D-Bus activation"; }
[[ ! -e /var/lib/waydroid ]] || { ok=1; echo "  /var/lib/waydroid in the image"; }
rule=/usr/lib/udev/rules.d/62-blockie-pad.rules
[[ $(cat "$rule") == 'ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="AYANEO Controller", ATTRS{phys}=="ayaneo-gamepad/input0", ATTRS{id/bustype}=="0019", ATTRS{id/vendor}=="4001", ATTRS{id/product}=="0428", SYMLINK+="input/by-blockie/pad"' ]] ||
  { ok=1; echo "  pad rule"; }
! udevadm verify --help > /dev/null 2>&1 || udevadm verify --resolve-names=never "$rule" > /dev/null 2>&1 ||
  { ok=1; echo "  udevadm verify"; }
base=/usr/lib/waydroid/data/configs/config_base
for f in devices music memory; do
  grep -qxF "lxc.include = /run/blockie-android/lxc.d/$f.conf" "$base" || { ok=1; echo "  config_base lacks $f.conf"; }
done
! grep -q 'pad\.conf' "$base" || { ok=1; echo "  config_base includes pad.conf"; }
! grep -rqs 'event-pad' /usr/lib/waydroid || { ok=1; echo "  an event-pad entry in /usr/lib/waydroid"; }
res $ok "image: the images link to data, no D-Bus activation, no /var/lib/waydroid, the pad link rule, the three includes and no pad bind"

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
mkdir -p "$c/bin" "$c/run" "$c/data/android/images"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$c" > "$c/bin/mountpoint"
chmod 755 "$c/bin/mountpoint"
ck() {
  PATH=$c/bin:$PATH BLOCKIE_DATA_DIR=$c/data BLOCKIE_ANDROID_RUN=$c/run timeout 5 "$lx/blockie-android-check" > "$c/out" 2>&1
  rc=$?
}
cstate() {
  rm -f "${c:?}/run/state" "${c:?}/mounted" "${c:?}/data/android/images/"*
  [[ $1 == - ]] || echo "$1" > "$c/run/state"
  [[ $2 != mounted ]] || : > "$c/mounted"
  [[ $3 != images ]] || : > "$c/data/android/images/system.img"
  [[ $3 != images ]] || : > "$c/data/android/images/vendor.img"
}
ok=0
for x in "-|no|no|1|not mounted" "missing /var/lib/blockie/data is not mounted|no|no|1|/var/lib/blockie/data is not mounted" \
  "failed change pending, stop Android|no|no|2|change pending" "ok|no|images|1|not mounted" \
  "ok|mounted|no|1|no android/images/system.img" "-|mounted|images|2|prep not run" \
  "failed pin incomplete|mounted|images|2|pin incomplete" "missing no images/vendor.img|mounted|images|1|no images/vendor.img" \
  "ok|mounted|images|0|"; do
  IFS='|' read -r s m i want why <<< "$x"
  cstate "$s" "$m" "$i"
  ck
  [[ $rc == "$want" ]] && { [[ -z $why ]] && [[ ! -s $c/out ]] || grep -qF -- "$why" "$c/out"; } ||
    { ok=1; echo "  state '$s' $m $i: rc $rc $(cat "$c/out")"; }
done
res $ok "check: 0 only with data mounted, both images and state ok; 1 for an unmounted data or a missing image; 2 for prep failures and no prep, each with its reason"


p=$t/prep
mkdir -p "$p/bin" "$p/data/android/images" "$p/work" "$p/run"
cp /usr/lib/waydroid/data/configs/config_base "$p/config_base"
sys1=$(printf '%064d' 1)
ven1=$(printf '%064d' 2)
zip=$(printf '%064d' 3)
pin() {
  printf 'system.img https://example.invalid/system.zip %s 4096 %s\nvendor.img https://example.invalid/vendor.zip %s 2048\n' \
    "$1" "$zip" "$2" > "$p/pin"
  printf 'system.img 4096 %s\nvendor.img 2048 %s\n' "$1" "$2" > "$p/data/android/images/stamp"
}
pin "$sys1" "$ven1"
truncate -s 4096 "$p/data/android/images/system.img"
truncate -s 2048 "$p/data/android/images/vendor.img"
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
  PATH=$p/bin:$PATH BLOCKIE_DATA_DIR=$p/data BLOCKIE_ANDROID_RUN=$p/run BLOCKIE_WAYDROID_WORK=$p/work \
    BLOCKIE_ANDROID_PIN=${1:-$p/pin} BLOCKIE_WAYDROID_BASE=$p/config_base BLOCKIE_ANDROID_PAYLOAD=$p/payload \
    BLOCKIE_LOCALTIME=$p/localtime BLOCKIE_ANDROID_DRM_STATE=${drmstate-} timeout 20 "$lx/blockie-android-prep" > "$p/out" 2>&1
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
mkdir -p "$p/data/android/images.old" "$p/zoneinfo/Asia"
: > "$p/zoneinfo/Asia/Tokyo"
ln -sfn "$p/zoneinfo/Asia/Tokyo" "$p/localtime"
prun
[[ $rc == 0 && $st == ok && $(cat "$p/calls") == '--details-to-stdout init' ]] || { ok=1; echo "  first: rc $rc '$st' $(cat "$p/calls")"; }
for kv in properties:persist.waydroid.width:960 properties:persist.waydroid.height:720 properties:persist.waydroid.uevent:false \
  properties:persist.waydroid.suspend:false properties:ro.sf.lcd_density:240 properties:persist.sys.timezone:Asia/Tokyo \
  properties:ro.vendor.blockie.vsync_period_ns:16666814 waydroid:suspend_action:freeze \
  waydroid:mount_overlays:True; do
  IFS=: read -r sec key val <<< "$kv"
  [[ $(cfgget "$sec" "$key") == "$val" ]] || { ok=1; echo "  $sec $key: $(cfgget "$sec" "$key")"; }
done
cmp -s /usr/share/blockie/android/Vendor_4001_Product_0428.kl "$p/work/overlay/system/usr/keylayout/Vendor_4001_Product_0428.kl" &&
  [[ -d $p/work/overlay/vendor ]] || { ok=1; echo "  keylayout"; }
[[ $(sed -n 1p "$p/data/android/prepared") == 'waydroid 1.6.3-1.fc44.blockie' && $(wc -l < "$p/data/android/prepared") == 5 &&
  $(sed -n 5p "$p/data/android/prepared") == 'gpu soft' ]] ||
  { ok=1; echo "  prepared"; }
[[ ! -e $p/data/android/images.old ]] || { ok=1; echo "  images.old kept"; }
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
vs='vsync period\|display mode\|crtc\|not checked\|cannot read'
prun
[[ $rc == 0 && $st == ok ]] && ! grep -q "$vs" "$p/out" || { ok=1; echo "  off: rc $rc $(cat "$p/out")"; }
dstate() {
  printf 'plane[31]: plane-0\n\tcrtc=crtc-1\n\tfb=50\n'
  printf 'crtc[44]: crtc-0\n\tenable=0\n\tactive=0\n\tself_refresh_active=0\n\tplane_mask=0\n'
  printf '\tmode: "960x720": 59 %s 960 970 980 1000 720 730 740 800 0x48 0xa\n' "$1"
  printf 'crtc[45]: crtc-1\n\tenable=1\n\tactive=1\n\tself_refresh_active=0\n\tplane_mask=1\n'
  printf '\tmode: "960x720": 60 %s 960 970 980 1000 720 730 740 800 0x48 0xa\n' "$2"
  printf 'connector[47]: DSI-1\n\tcrtc=crtc-1\n\tself_refresh_aware=0\n'
}
drmstate=$p/drmstate
dstate 47200 48000 > "$drmstate"
prun
[[ $rc == 0 && $st == ok && ! -s $p/calls && $(grep -c "$vs" "$p/out") == 1 ]] &&
  grep -qx 'blockie-android-prep: vsync period 16666667 ns, pinned 16666814' "$p/out" || { ok=1; echo "  active: $(cat "$p/out")"; }
dstate 48000 47200 > "$drmstate"
prun
[[ $rc == 0 && $st == ok && $(grep -c "$vs" "$p/out") == 2 ]] &&
  grep -qx 'blockie-android-prep: vsync period 16949153 ns, pinned 16666814' "$p/out" &&
  grep -qx 'blockie-android-prep: warning: the display mode is 16940 ppm off the pinned vsync period' "$p/out" ||
  { ok=1; echo "  warning: $(cat "$p/out")"; }
dstate 48000 48000 | sed 's/ 0x48 0xa$//' > "$drmstate"
prun
[[ $rc == 0 && $st == ok && $(grep -c "$vs" "$p/out") == 1 ]] && grep -qx "blockie-android-prep: no active crtc mode in $drmstate" "$p/out" ||
  { ok=1; echo "  unparsable: $(cat "$p/out")"; }
rm -f "${drmstate:?}"
prun
[[ $rc == 0 && $st == ok && $(grep -c "$vs" "$p/out") == 1 ]] && grep -qx "blockie-android-prep: no $drmstate, vsync period not checked" "$p/out" ||
  { ok=1; echo "  missing: $(cat "$p/out")"; }
unset drmstate
res $ok "prep: the debugfs state read is off with BLOCKIE_ANDROID_DRM_STATE empty; it takes the mode line of the active crtc, not the inactive one, logs htotal * vtotal / clock against 16666814 (8.8 ppm, no warning) and warns past 10 ppm; an unparsable state and a missing file log one line each and prep goes on, state ok"

ok=0
mkdir -p "$p/payload" "$p/data/android/images.old"
printf 'populated 1\nfrozen 0\n' > "$p/payload/cgroup.events"
echo 'lxc.mount.auto = sys:ro' >> "$p/config_base"
prun
[[ $rc == 1 && $st == "failed change pending, stop Android" && ! -s $p/calls && -d $p/data/android/images.old ]] ||
  { ok=1; echo "  running: rc $rc '$st' $(cat "$p/calls")"; }
printf 'populated 0\nfrozen 0\n' > "$p/payload/cgroup.events"
prun
[[ $rc == 0 && $st == ok && $(cat "$p/calls") == '--details-to-stdout upgrade --offline' && ! -e $p/data/android/images.old ]] ||
  { ok=1; echo "  stopped: rc $rc $(cat "$p/calls")"; }
rm -rf "${p:?}/payload"
res $ok "prep: with a populated payload nothing runs and the state says change pending; an empty leftover payload is not running, so the upgrade runs and the state is ok"

ok=0
rm -f "${p:?}/data/android/images/vendor.img"
prun
[[ $rc == 1 && $st == "missing no images/vendor.img" && ! -s $p/calls ]] || { ok=1; echo "  missing: '$st'"; }
truncate -s 2047 "$p/data/android/images/vendor.img"
prun
[[ $rc == 1 && $st == "failed images/vendor.img is 2047 bytes, the pin says 2048" ]] || { ok=1; echo "  size: '$st'"; }
truncate -s 2048 "$p/data/android/images/vendor.img"
printf 'system.img 4096 %s\nvendor.img 2048 %s\n' "$(printf '%064d' 4)" "$(printf '%064d' 5)" > "$p/data/android/images/stamp"
prun
[[ $rc == 1 && $st == "failed the image stamp does not match the pin" ]] || { ok=1; echo "  stamp: '$st'"; }
rm -f "${p:?}/data/android/images/stamp"
prun
[[ $rc == 1 && $st == "failed no image stamp" ]] || { ok=1; echo "  no stamp: '$st'"; }
pin "$(printf '%064d' 4)" "$ven1"
rm -f "${p:?}/mounted"
prun
[[ $rc == 1 && $st == "missing $p/data is not mounted" ]] || { ok=1; echo "  unmounted: '$st'"; }
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

g=$t/gpu
ov=$g/work/overlay/vendor
mkdir -p "$g/bin" "$g/data/android/images" "$g/work/overlay/vendor" "$g/run" "$g/vendor" "$g/hwc" "$g/zoneinfo/Asia"
cp /usr/lib/waydroid/data/configs/config_base "$g/config_base"
: > "$g/zoneinfo/Asia/Tokyo"
ln -sfn "$g/zoneinfo/Asia/Tokyo" "$g/localtime"
: > "$g/mounted"
echo 1.6.3-1.fc44.blockie > "$g/version"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$g" > "$g/bin/mountpoint"
printf '#!/bin/sh\ncat "%s/version"\n' "$g" > "$g/bin/rpm"
printf '#!/bin/sh\nf=$3\n: > "$f"\necho "mknod $*" >> "%s/mknod.calls"\n[ ! -e "%s/mknodfail" ] || exit 1\n' "$g" "$g" > "$g/bin/mknod"
sed "s#$p/#$g/#g" "$p/bin/waydroid" > "$g/bin/waydroid"
chmod 755 "$g/bin/"*
gsys=$(printf '%064d' 7)
gven=$(printf '%064d' 8)
gzip=$(printf '%064d' 9)
printf 'system.img https://example.invalid/system.zip %s 4096 %s\nvendor.img https://example.invalid/vendor.zip %s 2048\n' "$gsys" "$gzip" "$gven" > "$g/imgpin"
printf 'system.img 4096 %s\nvendor.img 2048 %s\n' "$gsys" "$gven" > "$g/data/android/images/stamp"
truncate -s 4096 "$g/data/android/images/system.img"
truncate -s 2048 "$g/data/android/images/vendor.img"
echo '1 0' > "$g/armed"
echo gpu-boot-one > "$g/bootid"
printf 'blockie-hwc-shim-content\n' > "$g/hwc/hwcomposer.blockie.so"
gshim=$(sha256sum < "$g/hwc/hwcomposer.blockie.so" | cut -d' ' -f1)
shipgpin=/usr/share/blockie/android.d/gpu-mt6768.conf
gbuildvendor() {
  rm -rf "${g:?}/vendor"
  mkdir -p "$g/vendor"
  python3 - "$shipgpin" "$g/vendor" "${1:-}" << 'PY'
import os, sys
pin, ven, salt = sys.argv[1], sys.argv[2], sys.argv[3]
stock = ("service vendor.gralloc-4-0 /vendor/bin/hw/android.hardware.graphics.allocator@4.0-service-mediatek\n"
         "    class hal\n    user system\n    group system graphics\n"
         "    interface android.hardware.graphics.allocator@4.0::IAllocator default\n"
         "    disabled\n\nservice other stuff\n    class late_start\n")
for line in open(pin):
    f = line.split()
    if not f:
        continue
    if f[0] == "f":
        full = os.path.join(ven, f[1])
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w").write(salt + f[1])
        os.chmod(full, 0o755 if (len(f) > 2 and f[2] == "0755") else 0o644)
    elif f[0] == "l":
        full = os.path.join(ven, f[1])
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if not os.path.lexists(full):
            os.symlink(f[2], full)
    elif f[0] == "rc":
        full = os.path.join(ven, f[2])
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, "w").write(stock)
PY
}
gpin() {
  sed '/^shim /d; /^digest /d' "$shipgpin" > "$g/gpin"
  echo "shim $gshim" >> "$g/gpin"
  [[ -z ${1:-} ]] || echo "digest $1" >> "$g/gpin"
}
grun() {
  : > "$g/calls"
  rm -f "${g:?}/mknod.calls"
  PATH=$g/bin:$PATH BLOCKIE_DATA_DIR=$g/data BLOCKIE_ANDROID_RUN=$g/run BLOCKIE_WAYDROID_WORK=$g/work \
    BLOCKIE_ANDROID_PIN=$g/imgpin BLOCKIE_WAYDROID_BASE=$g/config_base BLOCKIE_ANDROID_PAYLOAD=$g/payload \
    BLOCKIE_LOCALTIME=$g/localtime BLOCKIE_ANDROID_GPU_PIN=$g/gpin BLOCKIE_ANDROID_VENDOR=$g/vendor \
    BLOCKIE_ANDROID_HWC_SHIM=$g/hwc/hwcomposer.blockie.so BLOCKIE_KBASE_ARMED=$g/armed BLOCKIE_BOOT_ID=$g/bootid \
    BLOCKIE_SETD_STORE=$g/gpusetting BLOCKIE_ANDROID_DRM_STATE='' \
    timeout 20 "$lx/blockie-android-prep" > "$g/out" 2>&1
  rc=$?
  st=$(cat "$g/run/state" 2> /dev/null)
}
gdigest() {
  PATH=$g/bin:$PATH BLOCKIE_ANDROID_GPU_PIN=$g/gpin BLOCKIE_ANDROID_VENDOR=$g/vendor \
    "$lx/blockie-android-prep" gpu-digest
}
gcfg() { python3 -c 'import configparser, sys; c = configparser.ConfigParser(); c.read(sys.argv[1]); print(c.get("properties", sys.argv[2], fallback="-"))' "$g/work/waydroid.cfg" "$1"; }

gbuildvendor
gpin
D=$(gdigest)
gpin "$D"

ok=0
grun
[[ $rc == 0 && $st == ok ]] || { ok=1; echo "  mali rc $rc '$st' $(cat "$g/out")"; }
for kv in ro.hardware.egl:mali ro.hardware.gralloc:mediatek ro.hardware.vulkan:mt6768 ro.sf.lcd_density:240 \
  ro.vendor.blockie.vsync_period_ns:16666814; do
  IFS=: read -r k v <<< "$kv"
  [[ $(gcfg "$k") == "$v" ]] || { ok=1; echo "  prop $k is $(gcfg "$k")"; }
done
[[ $(gcfg ro.hardware.hwcomposer) == - ]] || { ok=1; echo "  hwcomposer prop set"; }
[[ -f $ov/lib64/egl/libGLES_mali.so && -f $ov/lib/egl/egl.cfg ]] || { ok=1; echo "  files not staged"; }
[[ $(stat -c '%a' "$ov/bin/hw/android.hardware.graphics.allocator@4.0-service-mediatek") == 755 &&
  $(stat -c '%a' "$ov/lib64/libged.so") == 644 && $(stat -c '%a' "$ov/lib64") == 755 ]] || { ok=1; echo "  modes"; }
[[ $(readlink "$ov/lib64/hw/vulkan.mt6768.so") == /vendor/lib64/egl/libGLES_mali.so &&
  $(readlink "$ov/lib/libdpframework.so") == mt6768/libdpframework.so ]] || { ok=1; echo "  links by target"; }
[[ -f $ov/lib64/hw/hwcomposer.blockie.so ]] || { ok=1; echo "  shim not staged"; }
[[ -f $ov/etc/init/blockie.graphics.allocator@4.0-mediatek.rc ]] &&
  [[ $(grep -c '^    mount none ' "$ov/etc/init/blockie.graphics.allocator@4.0-mediatek.rc") == 3 ]] &&
  grep -q '^    enable vendor.gralloc-4-0$' "$ov/etc/init/blockie.graphics.allocator@4.0-mediatek.rc" ||
  { ok=1; echo "  blockie rc"; }
[[ ! -e $ov/etc/init/android.hardware.graphics.allocator@4.0-service-mediatek.rc ]] || { ok=1; echo "  stock rc staged"; }
[[ $(grep -c ' c 0 0$' "$g/mknod.calls") == 3 ]] || { ok=1; echo "  whiteout mknods $(cat "$g/mknod.calls")"; }
[[ $(sed -n 5p "$g/data/android/prepared") == "gpu $D shim $gshim" ]] || { ok=1; echo "  prepared gpu line $(sed -n 5p "$g/data/android/prepared")"; }
grep -qxF "lib64/hw/hwcomposer.blockie.so" "$g/data/android/gpu-staged" && grep -qxF "lib/egl/egl.cfg" "$g/data/android/gpu-staged" ||
  { ok=1; echo "  gpu-staged list"; }
res $ok "prep gpu: a matching set, armed and a matching shim stage the files, links by target, whiteouts, the blockie allocator rc (3 vintf binds, enable) and the shim, write egl, gralloc, vulkan and density props but no hwcomposer prop, never stage the stock rc, and record the gpu line and the staged list"

ok=0
rm -f "${g:?}/hwc/hwcomposer.blockie.so"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == mali && ! -e $ov/lib64/hw/hwcomposer.blockie.so &&
  $(sed -n 5p "$g/data/android/prepared") == "gpu $D" ]] || { ok=1; echo "  no shim: '$st' $(sed -n 5p "$g/data/android/prepared")"; }
printf 'blockie-hwc-shim-content\n' > "$g/hwc/hwcomposer.blockie.so"
res $ok "prep gpu: a missing shim stays mali (the hwcomposer prop is gated on the device tear run, not shipped yet) and the prepared line drops the shim, it is not a fall back to soft"

ok=0
echo gpu-boot-two > "$g/bootid"
gbuildvendor other-content
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == - && $(sed -n 5p "$g/data/android/prepared") == 'gpu soft' ]] &&
  grep -q 'gpu set changed, soft for this start' "$g/out" || { ok=1; echo "  mismatch: '$st' $(gcfg ro.hardware.egl)"; }
res $ok "prep gpu: a vendor set that no longer matches the pinned digest falls back to soft for the start, removes the hardware props and logs the reason, state ok"

ok=0
echo gpu-boot-three > "$g/bootid"
gbuildvendor
rm -f "${g:?}/vendor/lib64/libged.so"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == - ]] && grep -q 'no gpu set, soft for this start' "$g/out" ||
  { ok=1; echo "  missing file: '$st'"; }
res $ok "prep gpu: a pinned vendor file missing from the host falls back to soft and logs no gpu set, state ok"

ok=0
echo gpu-boot-four > "$g/bootid"
gbuildvendor
echo '0 0' > "$g/armed"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == - ]] && grep -q 'kbase hook not armed, soft for this start' "$g/out" ||
  { ok=1; echo "  not armed: '$st'"; }
echo '1 0' > "$g/armed"
res $ok "prep gpu: with the kbase hook site 1 not armed prep uses soft for the start and logs it, state ok"

ok=0
echo gpu-boot-five > "$g/bootid"
gbuildvendor
grun
[[ $(gcfg ro.hardware.egl) == mali ]] || { ok=1; echo "  re-mali before removal"; }
echo '0 0' > "$g/armed"
grun
[[ $rc == 0 && $(gcfg ro.hardware.egl) == - && $(gcfg ro.sf.lcd_density) == 240 && $(gcfg ro.hardware.vulkan) == - &&
  $(gcfg ro.vendor.blockie.vsync_period_ns) == 16666814 ]] || { ok=1; echo "  props not removed in soft"; }
echo '1 0' > "$g/armed"
res $ok "prep gpu: a switch to soft removes the hardware props (egl, gralloc, vulkan) from waydroid.cfg and keeps the density and the vsync period"

ok=0
echo gpu-boot-six > "$g/bootid"
gbuildvendor
grun
[[ $(gcfg ro.hardware.egl) == mali && -f $ov/lib64/libged.so ]] || { ok=1; echo "  setup for pin change"; }
sed -i '\#^f lib64/libgpud.so$#d' "$g/gpin"
D2=$(gdigest)
sed -i "s/^digest .*/digest $D2/" "$g/gpin"
echo gpu-boot-six-b > "$g/bootid"
grun
[[ $rc == 0 && $(gcfg ro.hardware.egl) == mali && ! -e $ov/lib64/libgpud.so ]] &&
  ! grep -qxF 'lib64/libgpud.so' "$g/data/android/gpu-staged" || { ok=1; echo "  removal by gpu-staged"; }
gpin "$D"
res $ok "prep gpu: a pin that drops a file restages and removes the dropped path by the gpu-staged list, not by the new pin"

ok=0
echo gpu-boot-seven > "$g/bootid"
gbuildvendor
grun
[[ $(gcfg ro.hardware.egl) == mali ]] || { ok=1; echo "  setup running"; }
mkdir -p "$g/payload"
printf 'populated 1\nfrozen 0\n' > "$g/payload/cgroup.events"
echo '0 0' > "$g/armed"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == mali && -f $ov/lib64/libged.so && ! -s $g/calls ]] &&
  grep -q 'gpu change waits for stop' "$g/out" || { ok=1; echo "  gpu-only while running: rc $rc '$st' $(gcfg ro.hardware.egl)"; }
rm -rf "${g:?}/payload"
echo '1 0' > "$g/armed"
res $ok "prep gpu: a gpu only change while Android runs is not refused, the overlay and props are left as they are, nothing is upgraded, and it is logged"

ok=0
echo gpu-boot-eight > "$g/bootid"
gbuildvendor
grun
[[ $(gcfg ro.hardware.egl) == mali ]] || { ok=1; echo "  cache setup"; }
gbuildvendor changed-after-cache
grun
[[ $(gcfg ro.hardware.egl) == mali ]] || { ok=1; echo "  cache not reused within a boot"; }
echo gpu-boot-nine > "$g/bootid"
grun
[[ $(gcfg ro.hardware.egl) == - ]] && grep -q 'gpu set changed' "$g/out" || { ok=1; echo "  cache not refreshed on a new boot"; }
gbuildvendor
echo gpu-boot-ten > "$g/bootid"
res $ok "prep gpu: the host digest is computed once per boot id and cached, so a vendor change within a boot is not reread; a new boot id recomputes it"

ok=0
gbuildvendor
rm -rf "${g:?}/work/rootfs" "${g:?}/data/android/prepared" "${g:?}/work/overlay/vendor"
mkdir -p "$g/work/overlay/vendor"
grun
pre=$(cat "$g/data/android/prepared" 2> /dev/null)
echo 1 > "$g/waydroid.rc"
gbuildvendor nextset
D3=$(gdigest)
sed -i "s/^digest .*/digest $D3/" "$g/gpin"
echo gpu-boot-eleven > "$g/bootid"
grun
[[ $rc == 1 && $st == 'failed waydroid upgrade exited 1' && -f $ov/lib/egl/egl.cfg && $(gcfg ro.hardware.egl) == mali &&
  -n $pre && $(cat "$g/data/android/prepared") == "$pre" ]] || { ok=1; echo "  mali midway: rc $rc '$st'"; }
rm -f "${g:?}/waydroid.rc"
gpin "$D"
gbuildvendor
echo gpu-boot-twelve > "$g/bootid"
res $ok "prep gpu: when waydroid upgrade fails staging mali, the files and props stay and prepared is not advanced, so the next start retries"

ok=0
gbuildvendor
gpin "$D"
rm -f "${g:?}/waydroid.rc"
echo g-soft-midway > "$g/bootid"
grun
[[ $(gcfg ro.hardware.egl) == mali ]] || { ok=1; echo "  soft midway setup not mali"; }
echo '0 0' > "$g/armed"
echo 1 > "$g/waydroid.rc"
echo g-soft-midway-b > "$g/bootid"
grun
[[ $rc == 1 && $st == 'failed waydroid upgrade exited 1' && $(gcfg ro.hardware.egl) == - && -f $ov/lib/egl/egl.cfg &&
  $(sed -n 5p "$g/data/android/prepared") != 'gpu soft' ]] || { ok=1; echo "  soft midway: rc $rc '$st' $(gcfg ro.hardware.egl)"; }
rm -f "${g:?}/waydroid.rc"
echo '1 0' > "$g/armed"
res $ok "prep gpu: when waydroid upgrade fails switching to soft, the hardware props are gone from the cfg but the staged files stay and prepared keeps the mali line, so the next start retries"

ok=0
shipg=/usr/share/blockie/android.d/gpu-mt6768.conf
cat > "$g/wdvendor.list" << 'EOF'
lib/libdrm.so
lib64/libdrm.so
lib/libc.so
lib/hw/android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so
lib64/hw/android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa.so
etc/init/android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa.rc
EOF
bad=$(awk '$1 == "f" || $1 == "l" { print $2 }' "$shipg" | grep -Fxf "$g/wdvendor.list" || true)
[[ -z $bad ]] || { ok=1; echo "  staged path shadows a Waydroid vendor path: $bad"; }
awk '$1 == "f" || $1 == "l" { print $2 }' "$shipg" | grep -qxE 'lib/libdrm\.so|lib64/libdrm\.so' && { ok=1; echo "  libdrm.so is pinned"; } || true
for w in $(awk '$1 == "w" { print $2 }' "$shipg"); do
  grep -qxF "$w" "$g/wdvendor.list" || { ok=1; echo "  whiteout $w is not a Waydroid vendor path"; }
done
res $ok "prep gpu pin: no staged file or link is a Waydroid vendor path (libdrm.so stays Waydroid's, outside the pin), and every whiteout targets a real Waydroid vendor path so it hides the minigbm files"

ok=0
aj=/usr/share/blockie/schema.d/20-android.json
python3 -m json.tool "$aj" > /dev/null 2>&1 || { ok=1; echo "  schema invalid json"; }
python3 - "$aj" << 'PY' || { ok=1; echo "  schema fields"; }
import json, sys
k = json.load(open(sys.argv[1]))["keys"]["android.gpu"]
ok = (k["type"] == "s" and k["default"] == "mali" and k["enum"] == ["mali", "soft"]
      and k["group"] == "android" and k["label"] == "Android GPU")
sys.exit(0 if ok else 1)
PY
res $ok "schema: android.gpu is a string, default mali, enum mali or soft, group android, labelled Android GPU"

gbuildvendor
gpin
D=$(gdigest)
gpin "$D"
rm -f "${g:?}/gpusetting" "${g:?}/data/android/gpu-failed"

ok=0
echo '{"android.gpu":"soft"}' > "$g/gpusetting"
echo g2-boot-one > "$g/bootid"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == - && $(sed -n 5p "$g/data/android/prepared") == 'gpu soft' ]] ||
  { ok=1; echo "  setting soft: '$st' $(gcfg ro.hardware.egl)"; }
rm -f "${g:?}/gpusetting"
res $ok "prep gpu: android.gpu set to soft keeps Android on software even with a matching set and armed hook, removing the hardware props"

ok=0
echo '{"android.gpu":"mali"}' > "$g/gpusetting"
echo g2-boot-two > "$g/bootid"
grun
[[ $(gcfg ro.hardware.egl) == mali && $(cat "$g/data/android/gpu-failed") == "$D 0" ]] || { ok=1; echo "  arm baseline $(cat "$g/data/android/gpu-failed" 2> /dev/null)"; }
printf '%s 2\n' "$D" > "$g/data/android/gpu-failed"
echo g2-boot-two-b > "$g/bootid"
grun
[[ $rc == 0 && $st == ok && $(gcfg ro.hardware.egl) == - ]] && grep -q "gpu failed twice on $D, soft" "$g/out" ||
  { ok=1; echo "  honoured: '$st' $(gcfg ro.hardware.egl)"; }
res $ok "prep gpu: a matching set arms the fail marker at zero, and two consecutive boot misses on that digest make prep use soft and log it, state ok"

ok=0
printf '%s 2\n' "$(printf '%064d' 1)" > "$g/data/android/gpu-failed"
echo g2-boot-three > "$g/bootid"
grun
[[ $(gcfg ro.hardware.egl) == mali && $(cat "$g/data/android/gpu-failed") == "$D 0" ]] ||
  { ok=1; echo "  new digest clears: $(cat "$g/data/android/gpu-failed" 2> /dev/null)"; }
res $ok "prep gpu: a fail marker left by a different digest does not disable the GPU; prep rearms the marker at zero for the current digest and uses mali"

ok=0
printf '%s 2\n' "$D" > "$g/data/android/gpu-failed"
echo '{"android.gpu":"soft"}' > "$g/gpusetting"
echo g2-boot-four > "$g/bootid"
grun
[[ $(gcfg ro.hardware.egl) == - && ! -e $g/data/android/gpu-failed ]] || { ok=1; echo "  soft clears marker"; }
rm -f "${g:?}/gpusetting"
res $ok "prep gpu: setting android.gpu to soft clears the fail marker, so a later switch back to mali tries the GPU again"

l=$t/lxcd
mkdir -p "$l/proc" "$l/run" "$l/bin" "$l/data/music" "$l/data/android/guest/data/media/0"
printf '#!/bin/sh\n[ -e "%s/mounted" ]\n' "$l" > "$l/bin/mountpoint"
chmod 755 "$l/bin/mountpoint"
: > "$l/mounted"
echo ok > "$l/run/state"
printf 'Character devices:\n  1 mem\n  5 /dev/tty\n 10 misc\n 13 input\n136 pts\n488 binder\n489 dma_heap\n491 pmsg\n\nBlock devices:\n  7 loop\n490 binder\n492 pmsg\n' \
  > "$l/proc/devices"
printf ' 59 ashmem\n229 fuse\n239 uhid\n200 tun\n 61 binder\n' > "$l/proc/misc"
ln -s /dev/full "$l/pad"
lrun() {
  rm -rf "${l:?}/run/lxc.d"
  env PATH="$l/bin:$PATH" BLOCKIE_PROC="$l/proc" BLOCKIE_ANDROID_PAD="$l/pad" BLOCKIE_ANDROID_RUN="$l/run" \
    BLOCKIE_ANDROID_PAYLOAD="$l/payload" BLOCKIE_DATA_DIR="$l/data" "$@" timeout 10 "$lx/blockie-android-lxcd" > "$l/out" 2>&1
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
$a 491:* rwm
$a 10:59 rwm
$a 10:229 rwm
$a 10:239 rwm
$a 10:200 rwm
$a 1:7 rwm"
ok=0
lrun
[[ $rc == 0 && $(cat "$l/run/lxc.d/devices.conf") == "$want" ]] || { ok=1; echo "  devices: rc $rc"; diff <(echo "$want") "$l/run/lxc.d/devices.conf"; }
[[ ! -e $l/run/lxc.d/pad.conf ]] || { ok=1; echo "  pad.conf written"; }
[[ $(cat "$l/run/lxc.d/memory.conf") == $'lxc.cgroup2.memory.high = 1900M\nlxc.cgroup2.memory.max = 2200M' ]] || { ok=1; echo "  memory.conf"; }
[[ $(cat "$l/run/lxc.d/music.conf") == "lxc.mount.entry = $l/data/music data/media/0/Music none bind,ro,create=dir,optional 0 0" ]] ||
  { ok=1; echo "  music.conf"; }
res $ok "lxcd: deny all first, then c rules with rwm for the base nodes, the binder, dma_heap and pmsg char majors, the misc minors and the pad; no pad.conf; the read only music bind; memory high and max"

ok=0
lrun BLOCKIE_ANDROID_NODEVICES=1
[[ $rc == 0 && -f $l/run/lxc.d/devices.conf && ! -s $l/run/lxc.d/devices.conf && ! -e $l/run/lxc.d/pad.conf && -s $l/run/lxc.d/memory.conf ]] ||
  { ok=1; echo "  nodevices: rc $rc"; }
rmdir "${l:?}/data/music"
lrun
[[ $rc == 0 && -f $l/run/lxc.d/music.conf && ! -s $l/run/lxc.d/music.conf && -s $l/run/lxc.d/devices.conf ]] && grep -q 'no .*/music, Android starts without it' "$l/out" ||
  { ok=1; echo "  no music: rc $rc"; }
mkdir "$l/data/music"
rmdir "${l:?}/data/android/guest/data/media/0"
lrun
[[ $rc == 0 && -f $l/run/lxc.d/music.conf && ! -s $l/run/lxc.d/music.conf ]] && grep -q 'Android has not made /data/media/0 yet' "$l/out" ||
  { ok=1; echo "  no media/0: rc $rc"; }
mkdir "$l/data/android/guest/data/media/0"
rm -f "${l:?}/pad"
sed -i '/ binder$/d' "$l/proc/devices"
lrun
[[ $rc == 0 && ! -e $l/run/lxc.d/pad.conf && $(tail -n 1 "$l/run/lxc.d/devices.conf") == "$a 10:200 rwm" ]] &&
  ! grep -q '488:' "$l/run/lxc.d/devices.conf" && grep -q 'no binder major' "$l/out" &&
  grep -q 'no pad at .*, Android starts without it' "$l/out" || { ok=1; echo "  no pad: rc $rc"; }
: > "$l/pad"
lrun
[[ $rc == 0 && $(tail -n 1 "$l/run/lxc.d/devices.conf") == "$a 10:200 rwm" ]] && grep -q 'no pad at .*, Android starts without it' "$l/out" ||
  { ok=1; echo "  regular file pad: rc $rc"; }
rm -f "${l:?}/pad"
ln -s /dev/full "$l/pad"
res $ok "lxcd: BLOCKIE_ANDROID_NODEVICES=1 writes devices.conf empty; no music/ or no guest /data/media/0 yet gives an empty music.conf; no pad or a pad that is no char device gives no pad rule and no pad.conf; a missing major is logged and left out"

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
res $ok "lxcd: the container start is refused unless data is mounted and the prep state is ok, so a start that skips the prep dependency fails here"

printf '#!/bin/sh\ncase "$*" in *gpu/dev*) exit 1 ;; *) [ -e "%s/mounted" ] ;; esac\n' "$l" > "$l/bin/mountpoint"
printf '#!/bin/sh\necho "mount $*" >> "%s/mount.calls"\n' "$l" > "$l/bin/mount"
printf '#!/bin/sh\n: > "$3"\necho "mknod $*" >> "%s/mknod.calls"\n' "$l" > "$l/bin/mknod"
chmod 755 "$l/bin/mountpoint" "$l/bin/mount" "$l/bin/mknod"
sed -i '/ mali0$/d' "$l/proc/misc"
printf '114 mali0\n' >> "$l/proc/misc"
mkdir -p "$l/dev/dma_heap"
for h in mtk_mm mtk_mm-uncached system system-uncached; do : > "$l/dev/dma_heap/$h"; done
lgrun() {
  rm -rf "${l:?}/run/lxc.d" "${l:?}/mount.calls" "${l:?}/mknod.calls"
  env PATH="$l/bin:$PATH" BLOCKIE_PROC="$l/proc" BLOCKIE_DEV="$l/dev" BLOCKIE_ANDROID_PAD="$l/pad" \
    BLOCKIE_ANDROID_RUN="$l/run" BLOCKIE_ANDROID_PAYLOAD="$l/payload" BLOCKIE_DATA_DIR="$l/data" \
    timeout 10 "$lx/blockie-android-lxcd" > "$l/out" 2>&1
  rc=$?
}
ok=0
echo mali > "$l/run/gpu-mode"
lgrun
[[ $rc == 0 ]] || { ok=1; echo "  mali rc $rc"; }
want="lxc.mount.entry = $l/run/gpu/dev/mali0 dev/mali0 none bind,create=file 0 0"
for h in mtk_mm mtk_mm-uncached system system-uncached; do
  want+=$'\n'"lxc.mount.entry = $l/run/gpu/dev/dma_heap/$h dev/dma_heap/$h none bind,create=file 0 0"
done
[[ $(cat "$l/run/lxc.d/gpu.conf") == "$want" ]] || { ok=1; echo "  gpu.conf"; diff <(echo "$want") "$l/run/lxc.d/gpu.conf"; }
[[ $(tail -n 1 "$l/run/lxc.d/devices.conf") == "lxc.cgroup2.devices.allow = c 10:114 rwm" ]] || { ok=1; echo "  mali rule"; }
grep -qxF "mount -t tmpfs -o dev,nosuid,noexec,mode=0755,size=64k blockie-gpu $l/run/gpu/dev" "$l/mount.calls" || { ok=1; echo "  tmpfs mount"; }
grep -qxF "mknod -m 0666 $l/run/gpu/dev/mali0 c 10 114" "$l/mknod.calls" || { ok=1; echo "  mali0 node"; }
[[ $(grep -c 'mknod -m 0444 .*/dma_heap/' "$l/mknod.calls") == 4 ]] || { ok=1; echo "  heap nodes"; }
[[ $(stat -c '%a' "$l/run/gpu") == 700 && $(stat -c '%a' "$l/run/gpu/dev") == 755 ]] || { ok=1; echo "  gpu dir modes"; }
res $ok "lxcd: in mali mode the guest nodes are made in a private 0700 tmpfs, mali0 at 0666 c 10:minor and each present heap at 0444, gpu.conf binds them after config_nodes, and devices.conf gains the mali rule"

ok=0
rm -f "${l:?}/dev/dma_heap/system-uncached"
lgrun
[[ $rc == 0 ]] && grep -q 'no system-uncached heap' "$l/out" &&
  ! grep -q 'system-uncached' "$l/run/lxc.d/gpu.conf" && grep -q '/dma_heap/system ' "$l/run/lxc.d/gpu.conf" ||
  { ok=1; echo "  missing heap"; }
: > "$l/dev/dma_heap/system-uncached"
res $ok "lxcd: a heap the kernel does not expose is logged and left out of gpu.conf, the others still bind"

ok=0
echo soft > "$l/run/gpu-mode"
lgrun
[[ $rc == 0 && -f $l/run/lxc.d/gpu.conf && ! -s $l/run/lxc.d/gpu.conf && ! -e $l/mknod.calls ]] &&
  ! grep -q '10:114' "$l/run/lxc.d/devices.conf" || { ok=1; echo "  soft: rc $rc"; }
rm -f "${l:?}/run/gpu-mode"
lgrun
[[ $rc == 0 && -f $l/run/lxc.d/gpu.conf && ! -s $l/run/lxc.d/gpu.conf ]] || { ok=1; echo "  default soft: rc $rc"; }
res $ok "lxcd: soft mode or no gpu-mode makes no node, writes an empty gpu.conf and adds no mali rule to devices.conf"

ok=0
echo mali > "$l/run/gpu-mode"
sed -i '/ mali0$/d' "$l/proc/misc"
lgrun
[[ $rc == 0 && -f $l/run/lxc.d/gpu.conf && ! -s $l/run/lxc.d/gpu.conf ]] && grep -q 'no mali0 minor' "$l/out" &&
  ! grep -q '10:114' "$l/run/lxc.d/devices.conf" || { ok=1; echo "  no mali0 minor: rc $rc"; }
printf '114 mali0\n' >> "$l/proc/misc"
rm -f "${l:?}/run/gpu-mode"
res $ok "lxcd: with no mali0 in /proc/misc mali mode writes an empty gpu.conf and no mali rule, logged, so the container still starts"

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

m=$t/music
mkdir -p "$m/bin" "$m/guest/bin" "$m/guest/data/system/environ" "$m/run/lxc.d" "$m/payload"
cat > "$m/bin/lxc-attach" << EOF
#!/bin/sh
a=
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do
  a="\$a \$1"
  shift
done
[ "\$1" = -- ] || exit 2
shift
echo "\${a# }" >> "$m/attach"
echo "\$*" >> "$m/shell"
! grep -qx 'frozen 1' "$m/payload/cgroup.events" || echo "\$*" >> "$m/frozen-call"
if [ "\$1" = sh ] && [ "\$2" = -c ]; then
  set -- sh -c "\$(printf '%s' "\$3" | sed 's|/mnt/pass_through|$m/guest/mnt/pass_through|g; s|/data/media|$m/guest/data/media|g; s|/proc/self/mountinfo|$m/mountinfo|g')"
elif [ "\$1" = /system/bin/cat ]; then
  echo 'export NOISECLASSPATH /noise.jar' >&2
  set -- cat "$m/guest\$2"
fi
{ PATH=$m/guest/bin:\$PATH "\$@"; echo \$? > "$m/attach.rc"; } | sed 's/\$/\r/'
exit \$(cat "$m/attach.rc")
EOF
printf '#!/bin/sh\necho "waydroid $*" >> "%s/waydroid"\n' "$m" > "$m/bin/waydroid"
printf '%s\n' 'export BOOTCLASSPATH /apex/x.jar:/system/framework/framework.jar' 'export DEX2OATBOOTCLASSPATH /apex/y.jar' \
  'export SYSTEMSERVERCLASSPATH /system/framework/services.jar' 'export ANDROID_ASSETS /system/app' 'export BAD-CLASSPATH /bad.jar' \
  'export EMPTYCLASSPATH' > "$m/guest/data/system/environ/classpath"
cat > "$m/guest/bin/mount" << EOF
#!/bin/sh
echo "mount \$*" >> "$m/calls"
if [ -e "$m/mountfail" ]; then
  [ ! -e "$m/stoponmount" ] || printf 'populated 0\nfrozen 0\n' > "$m/payload/cgroup.events"
  echo 'mount: permission denied' >&2
  exit 1
fi
[ "\$1" != --bind ] || echo "99 30 179:4 /music \$3 rw,relatime - ext4 /dev/block/mmcblk1p4 rw" >> "$m/mountinfo"
EOF
cat > "$m/guest/bin/content" << EOF
#!/bin/sh
echo "content \$*" >> "$m/calls"
[ ! -e "$m/stoponscan" ] || printf 'populated 0\nfrozen 0\n' > "$m/payload/cgroup.events"
[ -e "$m/scanempty" ] || echo "Result: null"
EOF
cat > "$m/bin/timeout" << EOF
#!/bin/sh
case "\$*" in
  *scan_volume*) [ ! -e "$m/scan.rc" ] || exit \$(cat "$m/scan.rc") ;;
esac
h=\$(cat "$m/hang" 2> /dev/null)
if [ -n "\$h" ]; then
  case "\$*" in
    *"\$h"*)
      rm -f "$m/hang"
      echo "\$*" >> "$m/hung"
      printf 'populated 1\nfrozen 1\n' > "$m/payload/cgroup.events"
      (i=0; while [ \$i -lt 150 ] && ! grep -q 'Android is frozen, waiting for the thaw' "$m/out" 2> /dev/null; do sleep 0.1; i=\$((i + 1)); done; printf 'populated 1\nfrozen 0\n' > "$m/payload/cgroup.events") > /dev/null 2>&1 &
      exit 124
      ;;
  esac
fi
exec $(command -v timeout) "\$@"
EOF
chmod 755 "$m/bin/"* "$m/guest/bin/"*
mrun() {
  rm -f "${m:?}/shell" "${m:?}/calls" "${m:?}/frozen-call" "${m:?}/attach" "${m:?}/waydroid" "${m:?}/hung"
  env PATH="$m/bin:$PATH" BLOCKIE_ANDROID_PAYLOAD="$m/payload" BLOCKIE_ANDROID_RUN="$m/run" BLOCKIE_ANDROID_MUSIC_WAIT=2 "$@" \
    timeout 20 "$lx/blockie-android-music" > "$m/out" 2>&1
  rc=$?
}
media=/data/media/0/Music
pass=/mnt/pass_through/0/emulated/0/Music
minfo() {
  printf '30 1 179:4 / %s rw,relatime - ext4 /dev/block/mmcblk1p4 rw\n' "$m/guest/data" > "$m/mountinfo"
  [[ ${1:-} == nomedia ]] || printf '40 30 179:4 /music %s rw,relatime - ext4 /dev/block/mmcblk1p4 rw\n' "$m/guest$media" >> "$m/mountinfo"
}
up() { printf 'populated 1\nfrozen 0\n' > "$m/payload/cgroup.events"; }
aenv='-P /var/lib/waydroid/lxc -n waydroid --clear-env --set-var PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin --set-var ANDROID_ROOT=/system --set-var ANDROID_DATA=/data --set-var ANDROID_STORAGE=/storage --set-var ANDROID_ART_ROOT=/apex/com.android.art --set-var ANDROID_I18N_ROOT=/apex/com.android.i18n --set-var ANDROID_TZDATA_ROOT=/apex/com.android.tzdata --set-var ANDROID_RUNTIME_ROOT=/apex/com.android.runtime'
boot=/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/core-icu4j.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/framework-atb-backward-compatibility.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar:/apex/com.android.media/javalib/updatable-media.jar:/apex/com.android.mediaprovider/javalib/framework-mediaprovider.jar:/apex/com.android.os.statsd/javalib/framework-statsd.jar:/apex/com.android.permission/javalib/framework-permission.jar:/apex/com.android.sdkext/javalib/framework-sdkextensions.jar:/apex/com.android.wifi/javalib/framework-wifi.jar:/apex/com.android.tethering/javalib/framework-tethering.jar
scan='content call --uri content://media --method scan_volume --arg external_primary'
cls=/system/bin/cat' /data/system/environ/classpath'
full="$aenv --set-var BOOTCLASSPATH=/apex/x.jar:/system/framework/framework.jar --set-var DEX2OATBOOTCLASSPATH=/apex/y.jar --set-var SYSTEMSERVERCLASSPATH=/system/framework/services.jar"
ok=0
echo "lxc.mount.entry = /var/lib/blockie/data/music data/media/0/Music none bind,ro,create=dir,optional 0 0" > "$m/run/lxc.d/music.conf"
mrun
[[ $rc == 0 && ! -e $m/shell ]] && grep -q 'no running Android payload' "$m/out" || { ok=1; echo "  no payload: rc $rc"; }
printf 'populated 0\nfrozen 0\n' > "$m/payload/cgroup.events"
mrun
[[ $rc == 0 && ! -e $m/shell ]] || { ok=1; echo "  not populated: rc $rc"; }
up
: > "$m/run/lxc.d/music.conf"
mrun
[[ $rc == 0 && ! -e $m/shell ]] && grep -q 'no music bind' "$m/out" || { ok=1; echo "  empty music.conf: rc $rc"; }
res $ok "music helper: no populated payload or an empty music.conf exits 0 and runs nothing in the guest"

ok=0
echo "lxc.mount.entry = /var/lib/blockie/data/music data/media/0/Music none bind,ro,create=dir,optional 0 0" > "$m/run/lxc.d/music.conf"
mkdir -p "$m/guest$media" "$m/guest$pass"
minfo
mrun
[[ $rc == 0 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass"$'\n'"$scan" ]] &&
  grep -qF " $m/guest$pass rw" "$m/mountinfo" && grep -q "bound $media onto $pass" "$m/out" && grep -q 'scanned external_primary' "$m/out" ||
  { ok=1; echo "  normal: rc $rc $(tr '\n' '|' < "$m/calls") $(tr '\n' '|' < "$m/out")"; }
grep -qF "grep -q \"^[0-9]* [0-9]* [0-9]*:[0-9]* [^ ]* $media \" /proc/self/mountinfo" "$m/shell" &&
  grep -qF "if grep -q \"^[0-9]* [0-9]* [0-9]*:[0-9]* [^ ]* $pass \" /proc/self/mountinfo; then" "$m/shell" && ! grep -q mountpoint "$m/shell" &&
  [[ $(tail -n 1 "$m/shell") == "$scan" ]] || { ok=1; echo "  shell: $(tr '\n' '|' < "$m/shell")"; }
[[ $(grep -cxF "$cls" "$m/shell") == 1 && $(tail -n 2 "$m/shell" | head -n 1) == "$cls" ]] || { ok=1; echo "  classpath read: $(tr '\n' '|' < "$m/shell")"; }
[[ $(head -n 1 "$m/attach") == "$aenv --set-var BOOTCLASSPATH=$boot" ]] || { ok=1; echo "  first attach: $(head -n 1 "$m/attach")"; }
[[ $(tail -n 1 "$m/attach") == "$full" ]] || { ok=1; echo "  scan attach: $(tail -n 1 "$m/attach")"; }
[[ ! -e $m/waydroid ]] || { ok=1; echo "  waydroid called: $(tr '\n' '|' < "$m/waydroid")"; }
mrun
[[ $rc == 0 && $(cat "$m/calls" 2> /dev/null) == "$scan" ]] && grep -q "already bound onto $pass" "$m/out" ||
  { ok=1; echo "  again: rc $rc $(tr '\n' '|' < "$m/calls")"; }
res $ok "music helper: attaches with lxc-attach and the Android environment, never waydroid shell; finds the $media bind and its own $pass bind in mountinfo field 5; reads the classpath once with /system/bin/cat, parses only its stdout and adds the CLASSPATH and SYSTEMSERVER keys, skipping a bad name and an empty value; a second run does not mount again"

ok=0
minfo nomedia
mrun
[[ $rc == 1 && ! -e $m/calls ]] && grep -q "did not appear in the guest within 2 s" "$m/out" && (($(wc -l < "$m/shell") >= 2)) ||
  { ok=1; echo "  no media line: rc $rc $(tr '\n' '|' < "$m/out")"; }
res $ok "music helper: an existing $media with no mountinfo line is not ready, the helper keeps waiting and binds nothing"

ok=0
minfo
echo 124 > "$m/scan.rc"
mrun
[[ $rc == 0 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass" ]] &&
  grep -q 'did not answer in 120 s, MediaProvider goes on scanning' "$m/out" || { ok=1; echo "  scan timeout: rc $rc $(tr '\n' '|' < "$m/out")"; }
rm -f "${m:?}/scan.rc"
: > "$m/scanempty"
mrun
[[ $rc == 1 && $(cat "$m/calls" 2> /dev/null) == "$scan" ]] && grep -q 'scan_volume external_primary failed (exit 0): no output' "$m/out" ||
  { ok=1; echo "  scan empty: rc $rc $(tr '\n' '|' < "$m/out")"; }
rm -f "${m:?}/scanempty"
mv "$m/guest/data/system/environ/classpath" "$m/classpath"
mrun
[[ $rc == 0 && $(tail -n 1 "$m/attach") == "$aenv --set-var BOOTCLASSPATH=$boot" ]] &&
  grep -q 'cannot read /data/system/environ/classpath (exit 1: .*No such file.*), scanning with the base environment' "$m/out" ||
  { ok=1; echo "  no classpath: rc $rc $(tr '\n' '|' < "$m/out")"; }
mv "$m/classpath" "$m/guest/data/system/environ/classpath"
res $ok "music helper: a scan that times out (rc 124) unfrozen is logged and rc 0, MediaProvider goes on; a scan with no output and rc 0 is rc 1; no guest classpath scans with the base environment and logs the stderr"

ok=0
rm -rf "${m:?}/guest/mnt"
minfo
printf 'populated 1\nfrozen 1\n' > "$m/payload/cgroup.events"
(sleep 2; up; sleep 0.5; mkdir -p "$m/guest$pass") &
s0=$(date +%s%3N)
mrun
s1=$(date +%s%3N)
wait
[[ $rc == 0 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass"$'\n'"$scan" ]] &&
  grep -q 'Android is frozen, waiting for the thaw' "$m/out" && ((s1 - s0 >= 1800)) ||
  { ok=1; echo "  frozen: rc $rc $((s1 - s0)) ms $(tr '\n' '|' < "$m/out")"; }
[[ ! -e $m/frozen-call ]] || { ok=1; echo "  guest called while frozen: $(tr '\n' '|' < "$m/frozen-call")"; }
res $ok "music helper: a frozen payload gets no guest call until it thaws, and the frozen time does not count against the wait"

ok=0
minfo
echo __ready > "$m/hang"
mrun
[[ $rc == 0 && $(wc -l < "$m/hung") == 1 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass"$'\n'"$scan" ]] &&
  grep -q 'Android is frozen, waiting for the thaw' "$m/out" && [[ ! -e $m/frozen-call ]] || { ok=1; echo "  ready hang: rc $rc $(tr '\n' '|' < "$m/out")"; }
echo /system/bin/cat > "$m/hang"
mrun
[[ $rc == 0 && $(wc -l < "$m/hung") == 1 && $(tail -n 1 "$m/attach") == "$full" ]] && grep -q 'scanned external_primary' "$m/out" ||
  { ok=1; echo "  classpath hang: rc $rc $(tr '\n' '|' < "$m/out")"; }
echo scan_volume > "$m/hang"
mrun
[[ $rc == 0 && $(wc -l < "$m/hung") == 1 && $(cat "$m/calls" 2> /dev/null) == "$scan" ]] && grep -q 'scanned external_primary' "$m/out" &&
  [[ ! -e $m/frozen-call ]] || { ok=1; echo "  scan hang: rc $rc $(tr '\n' '|' < "$m/out")"; }
up
res $ok "music helper: a guest call that times out while Android is frozen waits for the thaw and runs once more, for the ready check, the classpath read and the scan"

ok=0
rm -f "${m:?}/mountinfo"
minfo
: > "$m/mountfail"
mrun
[[ $rc == 1 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass" ]] &&
  grep -q "cannot bind $media onto $pass: mount: permission denied" "$m/out" || { ok=1; echo "  mount fails: rc $rc $(cat "$m/out")"; }
rm -f "${m:?}/mountfail"
rm -rf "${m:?}/guest/mnt"
mrun
[[ $rc == 1 && ! -e $m/calls ]] && grep -q "did not appear in the guest within 2 s" "$m/out" &&
  (($(wc -l < "$m/shell") >= 2)) || { ok=1; echo "  no pass_through: rc $rc $(cat "$m/out")"; }
res $ok "music helper: a failed mount and a pass_through dir that never appears are rc 1 with the reason, and nothing is scanned"

ok=0
(sleep 1.5; printf 'populated 0\nfrozen 0\n' > "$m/payload/cgroup.events") &
s0=$(date +%s%3N)
mrun BLOCKIE_ANDROID_MUSIC_WAIT=10
s1=$(date +%s%3N)
wait
[[ $rc == 0 && ! -e $m/calls ]] && grep -qx 'blockie-android-music: Android stopped' "$m/out" && ((s1 - s0 < 5000)) ||
  { ok=1; echo "  stopped in the wait: rc $rc $((s1 - s0)) ms $(tr '\n' '|' < "$m/out")"; }
up
mkdir -p "$m/guest$pass"
minfo
: > "$m/mountfail"
: > "$m/stoponmount"
mrun
[[ $rc == 0 && $(cat "$m/calls" 2> /dev/null) == "mount --bind $m/guest$media $m/guest$pass" ]] && grep -qx 'blockie-android-music: Android stopped' "$m/out" ||
  { ok=1; echo "  stopped in the bind: rc $rc $(tr '\n' '|' < "$m/out")"; }
rm -f "${m:?}/mountfail" "${m:?}/stoponmount"
up
: > "$m/scanempty"
: > "$m/stoponscan"
mrun
[[ $rc == 0 && $(tail -n 1 "$m/calls" 2> /dev/null) == "$scan" ]] && grep -qx 'blockie-android-music: Android stopped' "$m/out" ||
  { ok=1; echo "  stopped in the scan: rc $rc $(tr '\n' '|' < "$m/out")"; }
rm -f "${m:?}/scanempty" "${m:?}/stoponscan"
printf 'populated 1\nfrozen 1\n' > "$m/payload/cgroup.events"
(sleep 1; printf 'populated 0\nfrozen 0\n' > "$m/payload/cgroup.events") &
mrun
wait
[[ $rc == 0 && ! -e $m/shell ]] && grep -qx 'blockie-android-music: Android stopped' "$m/out" ||
  { ok=1; echo "  frozen then stopped: rc $rc $(tr '\n' '|' < "$m/out")"; }
up
res $ok "music helper: Android stopping during the wait, a failed bind or a failed scan, or while frozen, ends the helper with rc 0 and the stop message"

d=$t/pad
mkdir -p "$d/bin" "$d/guest/bin" "$d/payload"
cat > "$d/bin/lxc-attach" << EOF
#!/bin/sh
a=
while [ \$# -gt 0 ] && [ "\$1" != -- ]; do
  a="\$a \$1"
  shift
done
[ "\$1" = -- ] || exit 2
shift
echo "\${a# }" >> "$d/attach"
echo "\$*" >> "$d/shell"
! grep -qx 'frozen 1' "$d/payload/cgroup.events" || echo "\$*" >> "$d/frozen-call"
if [ "\$1" = sh ] && [ "\$2" = -c ]; then
  set -- sh -c "\$(printf '%s' "\$3" | sed 's|/dev/|$d/guest/dev/|g')"
fi
{ PATH=$d/guest/bin:\$PATH "\$@"; echo \$? > "$d/attach.rc"; } | sed 's/\$/\r/'
exit \$(cat "$d/attach.rc")
EOF
cat > "$d/bin/timeout" << EOF
#!/bin/sh
h=\$(cat "$d/hang" 2> /dev/null)
if [ -n "\$h" ]; then
  case "\$*" in
    *"\$h"*)
      rm -f "$d/hang"
      echo "\$*" >> "$d/hung"
      printf 'populated 1\nfrozen 1\n' > "$d/payload/cgroup.events"
      (i=0; while [ \$i -lt 150 ] && ! grep -q 'Android is frozen, waiting for the thaw' "$d/out" 2> /dev/null; do sleep 0.1; i=\$((i + 1)); done; printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events") > /dev/null 2>&1 &
      exit 124
      ;;
  esac
fi
exec $(command -v timeout) "\$@"
EOF
printf '#!/bin/sh\necho "waydroid $*" >> "%s/waydroid"\n' "$d" > "$d/bin/waydroid"
cat > "$d/guest/bin/mknod" << EOF
#!/bin/sh
echo "mknod \$*" >> "$d/calls"
[ ! -e "$d/mknodfail" ] || { echo 'mknod: Operation not permitted' >&2; exit 1; }
[ "\$1" = -m ] || exit 1
: > "\$3"
$(command -v chmod) "\$2" "\$3"
EOF
cat > "$d/guest/bin/stat" << EOF
#!/bin/sh
[ ! -e "$d/stat" ] || exec cat "$d/stat"
exec $(command -v stat) "\$@"
EOF
printf '#!/bin/sh\necho "chown $*" >> "%s/calls"\n' "$d" > "$d/guest/bin/chown"
for c in ln rm; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexec %s "$@"\n' "$c" "$d" "$(command -v "$c")" > "$d/guest/bin/$c"
done
printf '#!/bin/sh\n[ "$1" = input ] && [ -e "%s/dumpsys" ] && cat "%s/dumpsys"\n' "$d" "$d" > "$d/guest/bin/dumpsys"
chmod 755 "$d/bin/"* "$d/guest/bin/"*
drun() {
  rm -f "${d:?}/shell" "${d:?}/calls" "${d:?}/frozen-call" "${d:?}/attach" "${d:?}/waydroid" "${d:?}/hung"
  env PATH="$d/bin:$PATH" BLOCKIE_ANDROID_PAYLOAD="$d/payload" BLOCKIE_ANDROID_PAD="$d/pad" BLOCKIE_ANDROID_PAD_WAIT=2 \
    BLOCKIE_ANDROID_PAD_LIST_WAIT=2 "$@" timeout 30 "$lx/blockie-android-pad" > "$d/out" 2>&1
  rc=$?
}
g=$d/guest/dev
attach='-P /var/lib/waydroid/lxc -n waydroid --clear-env --set-var PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin --set-var ANDROID_ROOT=/system --set-var ANDROID_DATA=/data'
ln -s /dev/full "$d/pad"
ok=0
rmdir "${d:?}/payload"
drun
[[ $rc == 0 && ! -e $d/shell ]] && grep -q 'no running Android payload' "$d/out" || { ok=1; echo "  no payload: rc $rc"; }
mkdir "$d/payload"
printf 'populated 0\nfrozen 0\n' > "$d/payload/cgroup.events"
drun
[[ $rc == 0 && ! -e $d/shell ]] || { ok=1; echo "  not populated: rc $rc"; }
printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events"
rm -f "${d:?}/pad"
drun
[[ $rc == 0 && ! -e $d/shell ]] && grep -q "no pad at $d/pad, Android runs without it" "$d/out" || { ok=1; echo "  no pad: rc $rc"; }
: > "$d/pad"
drun
[[ $rc == 0 && ! -e $d/shell ]] && grep -q "no pad at $d/pad, Android runs without it" "$d/out" || { ok=1; echo "  regular file pad: rc $rc"; }
rm -f "${d:?}/pad"
ln -s /dev/full "$d/pad"
res $ok "pad helper: no populated payload, no host pad or a pad that is no char device exits 0 and runs nothing in the guest"

ok=0
mkdir -p "$g/input"
echo '      Path: /dev/input/event-pad' > "$d/dumpsys"
drun
want="rm -f $g/input/event-pad $g/.blockie-pad
mknod -m 0660 $g/.blockie-pad c 1 7
chown root:input $g/.blockie-pad
ln $g/.blockie-pad $g/input/event-pad
rm $g/.blockie-pad"
[[ $rc == 0 && $(cat "$d/calls" 2> /dev/null) == "$want" && -f $g/input/event-pad && ! -e $g/.blockie-pad &&
  $(stat -c %a "$g/input/event-pad") == 660 ]] || { ok=1; echo "  make: rc $rc"; diff <(echo "$want") "$d/calls"; }
[[ $(grep mknod "$d/shell") == *'mknod -m 0660 /dev/.blockie-pad c 1 7 && chown root:input /dev/.blockie-pad && ln /dev/.blockie-pad /dev/input/event-pad && rm /dev/.blockie-pad; then echo __made'* ]] &&
  ! grep -q chmod "$d/shell" || { ok=1; echo "  shell: $(tr '\n' '|' < "$d/shell")"; }
grep -q 'made /dev/input/event-pad as c 1:7 root:input 0660 in the guest' "$d/out" && grep -q 'the input service has /dev/input/event-pad' "$d/out" &&
  [[ $(tail -n 1 "$d/shell") == 'dumpsys input' ]] || { ok=1; echo "  make out: $(tr '\n' '|' < "$d/out")"; }
[[ $(sort -u "$d/attach") == "$attach" && ! -e $d/waydroid ]] || { ok=1; echo "  attach: $(sort -u "$d/attach" | tr '\n' '|')"; }
res $ok "pad helper: attaches with lxc-attach and the Android PATH, never waydroid shell; makes the node with mknod -m 0660 outside /dev/input, chowns it root:input, hard links it in and removes the first name, then finds it in dumpsys input"

ok=0
rm -f "${g:?}/input/event-pad"
ln -s /dev/full "$g/input/event-pad"
echo '1 7 root input 660' > "$d/stat"
drun
[[ $rc == 0 && ! -e $d/calls ]] && grep -q 'is already c 1:7 root:input 0660 in the guest' "$d/out" && grep -q 'the input service has' "$d/out" ||
  { ok=1; echo "  already: rc $rc $(tr '\n' '|' < "$d/out")"; }
for s in '1 7 root input 666' '1 7 root root 660' '1 3 root input 660'; do
  rm -f "${g:?}/input/event-pad"
  ln -s /dev/full "$g/input/event-pad"
  echo "$s" > "$d/stat"
  drun
  [[ $rc == 0 && $(sed -n 2p "$d/calls" 2> /dev/null) == "mknod -m 0660 $g/.blockie-pad c 1 7" && ! -L $g/input/event-pad ]] &&
    grep -q 'made /dev/input/event-pad' "$d/out" || { ok=1; echo "  $s: rc $rc $(tr '\n' '|' < "$d/calls")"; }
done
rm -f "${d:?}/stat"
res $ok "pad helper: a node with the pad's number, root:input and 660 is left alone; another mode, group or number is made again"

ok=0
rm -f "${d:?}/dumpsys"
drun
[[ $rc == 1 ]] && grep -q 'the input service did not list /dev/input/event-pad within 2 s' "$d/out" &&
  (($(grep -cx 'dumpsys input' "$d/shell") >= 2)) || { ok=1; echo "  not listed: rc $rc $(tr '\n' '|' < "$d/out")"; }
echo '      Path: /dev/input/event-pad' > "$d/dumpsys"
rm -f "${g:?}/input/event-pad"
: > "$d/mknodfail"
drun
[[ $rc == 1 && ! -e $g/input/event-pad ]] && grep -q 'cannot make /dev/input/event-pad in the guest: mknod: Operation not permitted' "$d/out" &&
  ! grep -qx 'dumpsys input' "$d/shell" || { ok=1; echo "  mknod fails: rc $rc $(tr '\n' '|' < "$d/out")"; }
rm -f "${d:?}/mknodfail"
rm -rf "${g:?}/input"
drun
[[ $rc == 1 && ! -e $d/calls ]] && grep -q '/dev/input did not appear in the guest within 2 s' "$d/out" &&
  (($(wc -l < "$d/shell") >= 2)) || { ok=1; echo "  no /dev/input: rc $rc $(tr '\n' '|' < "$d/out")"; }
res $ok "pad helper: a node dumpsys input does not list within the list wait, a failed mknod and a /dev/input that never appears are rc 1 with the reason"

ok=0
(sleep 1.5; printf 'populated 0\nfrozen 0\n' > "$d/payload/cgroup.events") &
s0=$(date +%s%3N)
drun BLOCKIE_ANDROID_PAD_WAIT=10
s1=$(date +%s%3N)
wait
[[ $rc == 0 && ! -e $d/calls ]] && grep -qx 'blockie-android-pad: Android stopped' "$d/out" && ((s1 - s0 < 5000)) ||
  { ok=1; echo "  stopped in the dir wait: rc $rc $((s1 - s0)) ms $(tr '\n' '|' < "$d/out")"; }
printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events"
mkdir -p "$g/input"
rm -f "${d:?}/dumpsys"
(sleep 1.5; printf 'populated 0\nfrozen 0\n' > "$d/payload/cgroup.events") &
s0=$(date +%s%3N)
drun BLOCKIE_ANDROID_PAD_LIST_WAIT=10
s1=$(date +%s%3N)
wait
[[ $rc == 0 && $(sed -n 2p "$d/calls" 2> /dev/null) == "mknod -m 0660 $g/.blockie-pad c 1 7" ]] && grep -qx 'blockie-android-pad: Android stopped' "$d/out" &&
  ((s1 - s0 < 5000)) || { ok=1; echo "  stopped in the list wait: rc $rc $((s1 - s0)) ms $(tr '\n' '|' < "$d/out")"; }
echo '      Path: /dev/input/event-pad' > "$d/dumpsys"
res $ok "pad helper: Android stopping during the /dev/input wait or the dumpsys wait ends the helper with rc 0"

ok=0
rm -rf "${g:?}/input"
printf 'populated 1\nfrozen 1\n' > "$d/payload/cgroup.events"
(sleep 2; printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events"; sleep 0.5; mkdir -p "$g/input") &
s0=$(date +%s%3N)
drun
s1=$(date +%s%3N)
wait
[[ $rc == 0 && $(sed -n 2p "$d/calls" 2> /dev/null) == "mknod -m 0660 $g/.blockie-pad c 1 7" ]] &&
  grep -q 'Android is frozen, waiting for the thaw' "$d/out" && ((s1 - s0 >= 1800)) ||
  { ok=1; echo "  frozen: rc $rc $((s1 - s0)) ms $(tr '\n' '|' < "$d/out")"; }
[[ ! -e $d/frozen-call ]] || { ok=1; echo "  guest called while frozen: $(tr '\n' '|' < "$d/frozen-call")"; }
res $ok "pad helper: a frozen payload gets no guest call until it thaws, and the frozen time does not count against the wait"

ok=0
rm -f "${g:?}/input/event-pad"
echo mknod > "$d/hang"
drun
[[ $rc == 0 && $(wc -l < "$d/hung") == 1 && $(grep -c '^mknod ' "$d/calls") == 1 && -f $g/input/event-pad ]] &&
  grep -q 'Android is frozen, waiting for the thaw' "$d/out" && grep -q 'made /dev/input/event-pad' "$d/out" && [[ ! -e $d/frozen-call ]] ||
  { ok=1; echo "  make hang: rc $rc $(tr '\n' '|' < "$d/out")"; }
echo 'dumpsys input' > "$d/hang"
drun
[[ $rc == 0 && $(wc -l < "$d/hung") == 1 ]] && grep -q 'the input service has /dev/input/event-pad' "$d/out" ||
  { ok=1; echo "  dumpsys hang: rc $rc $(tr '\n' '|' < "$d/out")"; }
printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events"
res $ok "pad helper: a guest call that times out while Android is frozen waits for the thaw and runs once more, for the make and the dumpsys check"

ok=0
printf 'populated 1\nfrozen 1\n' > "$d/payload/cgroup.events"
(sleep 1; printf 'populated 0\nfrozen 0\n' > "$d/payload/cgroup.events") &
drun
wait
[[ $rc == 0 && ! -e $d/shell ]] && grep -qx 'blockie-android-pad: Android stopped' "$d/out" ||
  { ok=1; echo "  frozen then stopped: rc $rc $(tr '\n' '|' < "$d/out")"; }
printf 'populated 1\nfrozen 0\n' > "$d/payload/cgroup.events"
res $ok "pad helper: Android stopping while frozen ends the helper with rc 0 and no guest call"

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
  'start --no-block blockie-android-music.service' | 'start --no-block blockie-android-pad.service')
    echo "\$*" >> "$r/starts"
    [ ! -f "$r/start.hang" ] || [ "\$3" != blockie-android-pad.service ] || exec sleep 30
    [ ! -f "$r/start.rc" ] || { echo 'Access denied' >&2; exit \$(cat "$r/start.rc"); }
    ;;
  *) cat "$r/unit" 2> /dev/null || echo active ;;
esac
EOF
chmod 755 "$r/bin/"*
rsetup() {
  rm -rf "${r:?}/payload" "${r:?}/window" "${r:?}/boot" "${r:?}/calls" "${r:?}/setting" "${r:?}/putfail" "${r:?}/ui" \
    "${r:?}/ui.rc" "${r:?}/unit" "${r:?}/system" "${r:?}/starts" "${r:?}/start.rc" "${r:?}/start.hang"
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
until_ 'grep -q "started blockie-android-music.service" "$r/out"' || { ok=1; echo "  music unit not started"; }
[[ $(cat "$r/starts" 2> /dev/null) == $'start --no-block blockie-android-pad.service\nstart --no-block blockie-android-music.service' ]] ||
  { ok=1; echo "  starts: $(tr '\n' '|' < "$r/starts")"; }
s1=$(grep -n 'screen_off_timeout is 2147483647' "$r/out" | cut -d: -f1)
m1=$(grep -n 'started blockie-android-music.service' "$r/out" | cut -d: -f1)
p1=$(grep -n 'started blockie-android-pad.service' "$r/out" | cut -d: -f1)
[[ -n $s1 && -n $m1 && -n $p1 ]] && ((s1 < p1 && p1 < m1)) || { ok=1; echo "  pad and music before screen_off_timeout: $(tr '\n' '|' < "$r/out")"; }
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  run ended early"; }
t0=${EPOCHREALTIME//[!0-9]/}
cg 0
rwait
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
[[ $rc == 1 && $(grep -c term "$r/ui") == 1 ]] && grep -q 'the Android payload ended$' "$r/out" && ((ms < 2000)) ||
  { ok=1; echo "  dead: rc $rc $ms ms"; }
res $ok "run: after boot_completed screen_off_timeout is read, set and read back once, then the pad and music units are started once each in that order without waiting; populated 0 ends the unit with rc 1 at once ($ms ms) and stops show-full-ui"

ok=0
rsetup
: > "$r/window"
echo 1 > "$r/boot"
echo 2147483647 > "$r/setting"
echo 1 > "$r/start.rc"
cg 1
rstart
until_ 'grep -q "screen_off_timeout is 2147483647" "$r/out"' 200 || ok=1
[[ $(cat "$r/calls" 2> /dev/null) == $'get 1 screen_off_timeout\nget 1 screen_off_timeout' ]] || { ok=1; echo "  calls: $(tr '\n' '|' < "$r/calls")"; }
until_ 'grep -q "cannot start blockie-android-music.service (exit 1): Access denied" "$r/out"' || { ok=1; echo "  start failure not logged"; }
until_ 'grep -q "cannot start blockie-android-pad.service (exit 1): Access denied" "$r/out"' || { ok=1; echo "  pad start failure not logged"; }
sleep 0.3
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  a failed music start ended the unit"; }
kill -TERM "$rp"
rwait
rsetup
: > "$r/window"
echo 1 > "$r/boot"
echo 2147483647 > "$r/setting"
: > "$r/start.hang"
cg 1
rstart
until_ 'grep -q "cannot start blockie-android-pad.service (no answer in 10 s)" "$r/out"' 300 ||
  { ok=1; echo "  hung start not logged"; }
until_ 'grep -q "started blockie-android-music.service" "$r/out"' || { ok=1; echo "  music unit not started after the hung pad start"; }
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  a hung pad start ended the unit"; }
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
until_ 'grep -q "started blockie-android-music.service" "$r/out"' || { ok=1; echo "  pad and music units not started after the give up"; }
sleep 0.3
[[ $(wc -l < "$r/starts") == 2 ]] || { ok=1; echo "  starts: $(tr '\n' '|' < "$r/starts")"; }
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  a failed set ended the unit"; }
kill -TERM "$rp"
rwait
[[ $rc == 0 ]] || { ok=1; echo "  term: rc $rc"; }
res $ok "run: no put when the value is already set; a put that does not read back is tried again, at most 3 times per session, and never ends the unit; the pad and music units still start once each, and a refused start or one with no answer in 10 s is logged, keeps the unit running and does not hold back the next start"

ok=0
rsetup
: > "$r/window"
echo 1 > "$r/boot"
cg 1 1
rstart
sleep 1
kill -0 "$rp" 2> /dev/null || { ok=1; echo "  frozen ended the unit"; }
! grep -q props "$r/ui" && [[ ! -e $r/calls && ! -e $r/starts ]] || { ok=1; echo "  polled while frozen"; }
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

ok=0
rsetup
mkdir -p "$r/run" "$r/android"
GD=$(printf '%064d' 3)
echo "boot-xyz $GD" > "$r/run/gpu-digest"
grunrc() {
  PATH=$r/bin:$PATH BLOCKIE_ROOT=$r BLOCKIE_ANDROID_PAYLOAD=$r/payload BLOCKIE_WAYDROID_LIB=$r/lib BLOCKIE_ANDROID_STEP=0.05 \
    BLOCKIE_ANDROID_RUN=$r/run BLOCKIE_DATA_DIR=$r timeout 20 "$lx/blockie-android-run" > "$r/out" 2>&1
  rc=$?
}
echo mali > "$r/run/gpu-mode"
printf '%s 0\n' "$GD" > "$r/android/gpu-failed"
grunrc
[[ $rc == 1 && $(cat "$r/android/gpu-failed") == "$GD 1" ]] && grep -q 'not seen within the start wait' "$r/out" ||
  { ok=1; echo "  marker written: rc $rc $(cat "$r/android/gpu-failed")"; }
echo soft > "$r/run/gpu-mode"
printf '%s 0\n' "$GD" > "$r/android/gpu-failed"
grunrc
[[ $(cat "$r/android/gpu-failed") == "$GD 0" ]] || { ok=1; echo "  soft leaves marker: $(cat "$r/android/gpu-failed")"; }
res $ok "run: in mali mode no sys.boot_completed within START_WAIT increments the gpu fail marker for the booted digest and logs it; in soft mode the marker is left alone"

done_
