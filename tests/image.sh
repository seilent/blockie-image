#!/usr/bin/env bash
set -euo pipefail

fail() { echo "image: $*" >&2; exit 1; }

mods=(/usr/lib/modules/*)
[[ ${#mods[@]} -eq 1 && -d ${mods[0]} ]] || fail "expected one modules dir, found ${mods[*]}"
kver=${mods[0]##*/}
rpm -q blockie-kernel > /dev/null || fail "blockie-kernel not installed"
rpm -qf "/usr/lib/modules/$kver/vmlinuz" | grep -q '^blockie-kernel-' || fail "vmlinuz is not from blockie-kernel"
[[ -z $(rpm -qa 'kernel*') ]] || fail "Fedora kernel rpms left: $(rpm -qa 'kernel*' | tr '\n' ' ')"
[[ -z $(rpm -qa 'fedora-release*') ]] || fail "fedora-release rpms left"
rpm -q generic-release generic-logos > /dev/null || fail "generic-release or generic-logos missing"

for kv in NAME=Blockie ID=blockie ID_LIKE=fedora VERSION_ID=44 DEFAULT_HOSTNAME=blockie; do
  grep -qx "$kv" /usr/lib/os-release || fail "os-release lacks $kv"
done
grep -qx "$(cat /usr/lib/blockie/version)" /usr/lib/os-release || fail "version file and os-release differ"
[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || fail "/etc/os-release is not the relative symlink"

grep -qx 'SELINUX=disabled' /etc/selinux/config || fail "SELinux is not disabled"
[[ $(sed -n '/^\[composefs\]/,/^\[/s/^enabled *= *//p' /usr/lib/ostree/prepare-root.conf) == no ]] || fail "composefs is not off"
[[ $(sed -n '/^\[sysroot\]/,/^\[/s/^readonly *= *//p' /usr/lib/ostree/prepare-root.conf) == true ]] || fail "sysroot is not read only"
for d in /blockie /vendor; do
  [[ -d $d && ! -L $d && -z $(ls -A "$d") ]] || fail "$d is not an empty directory"
done
[[ $(readlink /mnt) == var/mnt ]] || fail "/mnt is $(readlink /mnt), not var/mnt"
[[ $(readlink /roms) == var/lib/blockie/data/roms ]] || fail "/roms is $(readlink /roms), not var/lib/blockie/data/roms"

for u in systemd-oomd.service systemd-oomd.socket systemd-pstore.service systemd-firstboot.service \
  bootloader-update.service udisks2.service fstrim.timer fstrim.service fwupd.service fwupd-refresh.service \
  fwupd-refresh.timer sleep.target suspend.target hibernate.target hybrid-sleep.target \
  suspend-then-hibernate.target systemd-repart.service systemd-repart.socket systemd-growfs-root.service \
  bootc-generic-growpart.service lvm2-monitor.service lvm2-lvmpolld.socket lvm-devices-import.path \
  lvm-devices-import.service dm-event.socket irqbalance.service selinux-autorelabel-mark.service \
  var-lib-nfs-rpc_pipefs.mount bootc-fetch-apply-updates.timer sshd.service sshd.socket systemd-soft-reboot.service \
  alsa-restore.service alsa-state.service alsa-card-wait@.service; do
  [[ $(readlink "/etc/systemd/system/$u") == /dev/null ]] || fail "$u is not masked"
done
for g in systemd-gpt-auto-generator systemd-ssh-generator; do
  [[ $(readlink "/etc/systemd/system-generators/$g") == /dev/null ]] || fail "$g is not masked"
done
[[ -f /usr/lib/udev/rules.d/90-alsa-restore.rules ]] || fail "alsa-utils has no 90-alsa-restore.rules to mask"
[[ $(readlink /etc/udev/rules.d/90-alsa-restore.rules) == /dev/null ]] || fail "90-alsa-restore.rules is not masked"

systemd-sysusers > /dev/null 2>&1
[[ $(id -u blockie):$(id -g blockie) == 1000:1000 ]] || fail "blockie is not 1000:1000"
groups=$(id -nG blockie)
for g in wheel systemd-journal input video render audio; do
  [[ " $groups " == *" $g "* ]] || fail "blockie is not in $g"
done
[[ $(getent passwd blockie | cut -d: -f6,7) == /var/home/blockie:/bin/bash ]] || fail "blockie home or shell"
grep -qx 'd /var/home/blockie 0700 blockie blockie -' /usr/lib/tmpfiles.d/blockie.conf || fail "home tmpfiles line"
[[ $(< /usr/lib/udev/rules.d/70-blockie-uinput.rules) == 'KERNEL=="uinput", GROUP="blockie", MODE="0660"' ]] &&
  getent group blockie > /dev/null || fail "/dev/uinput is not 0660 to the blockie group"
cmp -s <(printf 'd /var/lib/blockie/data/%s\n' 'cache 0755 blockie blockie -' 'roms 0755 root root -' \
  'roms/ports 0755 blockie blockie -' 'ports-home 0700 blockie blockie -' 'cache/ports-tmp 0700 blockie blockie -') \
  <(grep -E '^d /var/lib/blockie/data/(cache|roms|ports-home)[/ ]' /usr/lib/blockie/data-tmpfiles.conf) ||
  fail "the data tmpfiles do not make cache, roms, roms/ports, ports-home and cache/ports-tmp in that order"
[[ -s /usr/share/blockie/ports/alsa.conf ]] || fail "the ports alsa.conf is missing"
for p in /var/cache/libX11 /var/cache/libX11/compose /var/lib/alsa /var/lib/bluetooth /var/lib/bluetooth/mesh /var/lib/geoclue \
  /var/lib/lxc /var/cache/lxc /var/lib/lxcfs; do
  [[ -d $p && ! -L $p ]] || fail "$p is not a directory in the image"
  l="d $p $(stat -c '%04a %U %G' "$p") -"
  grep -qxF "$l" /usr/lib/tmpfiles.d/blockie.conf || fail "no tmpfiles line '$l'"
done
grep -qx 'enable blockie-\*' /usr/lib/systemd/system-preset/50-blockie.preset || fail "blockie preset"

rpm -q systemd bootc ostree skopeo podman NetworkManager kmod > /dev/null || fail "base rpms missing"
[[ $(rpm -q --qf '%{RELEASE}' bootc) == *.blockie ]] || fail "bootc is not the blockie build: $(rpm -q bootc)"
for p in ostree ostree-libs; do
  [[ $(rpm -q --qf '%{RELEASE}' "$p") == *.blockie ]] || fail "$p is not the blockie build: $(rpm -q "$p")"
done
rpm -q e2fsprogs tzdata erofs-utils vulkan-tools egl-utils drm-utils strace file procps-ng jq libwayland-client \
  libwayland-server NetworkManager-wifi wpa_supplicant iw wireless-regdb iperf3 bluez alsa-ucm alsa-ucm-utils \
  alsa-utils retroarch libretro-mgba libretro-pcsx-rearmed kmscube glmark2 > /dev/null || fail "packages missing"
rpm -q gptokeyb gptokeyb2 portmaster SDL2_mixer SDL2_ttf SDL2_image love luajit innoextract xdelta turbojpeg \
  7zip-standalone-all squashfs-tools sdl2-compat openal-soft libtheora libvorbis libjpeg8 > /dev/null || fail "ports packages missing"
compat=/usr/lib64/blockie-ports/compat
[[ -f $compat/libjpeg.so.8 && $(rpm -qf --qf '%{NAME}' "$compat/libjpeg.so.8") == libjpeg8 ]] &&
  grep -qaF LIBJPEG_8.0 "$compat/libjpeg.so.8" || fail "$compat/libjpeg.so.8 is not libjpeg8's LIBJPEG_8.0 library"
[[ $(readlink "$compat/libbz2.so.1.0") == /usr/lib64/libbz2.so.1 && -f $compat/libbz2.so.1.0 ]] ||
  fail "$compat/libbz2.so.1.0 does not resolve to /usr/lib64/libbz2.so.1"
! rpm -q --whatprovides 'libjpeg.so.8()(64bit)' > /dev/null 2>&1 || fail "a package provides libjpeg.so.8()(64bit)"
for l in libEGL.so libGLESv2.so; do
  [[ ! -e /usr/lib64/$l && ! -L /usr/lib64/$l ]] || fail "/usr/lib64/$l is in the image"
done
grep -qE '^[dD]!? /tmp/\.X11-unix ' /usr/lib/tmpfiles.d/x11.conf || fail "x11.conf does not make /tmp/.X11-unix"
[[ -z $(find -L /usr/share/blockie/portmaster/PortMaster -type l) ]] ||
  fail "dangling links in the PortMaster tree: $(find -L /usr/share/blockie/portmaster/PortMaster -type l | tr '\n' ' ')"
[[ $(readlink /etc/localtime) == ../usr/share/zoneinfo/Asia/Tokyo && -f /usr/share/zoneinfo/Asia/Tokyo ]] ||
  fail "/etc/localtime is not Asia/Tokyo"
[[ -f /usr/share/zoneinfo/zone.tab ]] || fail "zone.tab missing"
jq -e '.keys["system.timezone"] | .backend == "timedate1" and .enum_from == "zones"' \
  /usr/share/blockie/schema.d/10-system.json > /dev/null || fail "10-system.json lacks the timedate1 system.timezone key"
jq -e '[.keys | to_entries[] | select(.key | test("^buttons\\.(home|extra[123])\\.(tap|hold)$")) | .value.map] |
  length == 8 and all' /usr/share/blockie/schema.d/30-buttons.json > /dev/null || fail "30-buttons.json lacks the 8 mapped buttons keys"
for l in RuntimeDirectory=blockie-set RuntimeDirectoryMode=0755 RuntimeDirectoryPreserve=yes; do
  grep -qx "$l" /usr/lib/systemd/system/blockie-setd.service || fail "blockie-setd.service lacks $l"
done
[[ $(stat -c '%a %U' /usr/share/polkit-1/rules.d/50-blockie-timezone.rules 2> /dev/null) == '644 root' ]] ||
  fail "50-blockie-timezone.rules is not a 644 file owned by root"
grep -q 'id="org.freedesktop.timedate1.set-timezone"' /usr/share/polkit-1/actions/org.freedesktop.timedate1.policy ||
  fail "the timedate1 policy has no set-timezone action"
[[ -x /usr/lib/systemd/systemd-timedated && -f /usr/lib/systemd/system/systemd-timedated.service &&
  $(readlink /etc/systemd/system/systemd-timedated.service) != /dev/null &&
  $(readlink /etc/systemd/system/dbus-org.freedesktop.timedate1.service) != /dev/null ]] ||
  fail "systemd-timedated is missing or masked"
for id in gambatte nestopia mgba pcsx_rearmed snes9x genesis_plus_gx mupen64plus_next ppsspp flycast; do
  so=/usr/lib64/libretro/${id}_libretro.so
  pkg=libretro-${id//_/-}
  [[ -f $so && $(head -c 4 "$so") == $'\x7fELF' ]] || fail "$so is missing or not an ELF"
  [[ $(rpm -qf --qf '%{NAME}' "$so") == "$pkg" ]] || fail "$so is not from $pkg"
  grep -qv '^(contains no files)$' <<< "$(rpm -qL "$pkg")" || fail "$pkg ships no licence text"
done
[[ -x /usr/bin/blockie-game && -f /usr/share/blockie/retroarch/blockie.cfg ]] || fail "blockie-game or its base config missing"
[[ $(rpm -q --qf '%{RELEASE}' retroarch) == *.blockie ]] || fail "retroarch is not the blockie GLES build: $(rpm -q retroarch)"
features=$(retroarch --features)
grep -qxF '  OpenGLES        - Video driver: yes' <<< "$features" || fail "retroarch has no GLES video driver"
[[ $(rpm -qa --qf '%{NAME}\n' 'retroarch*') == retroarch ]] || fail "a Fedora retroarch subpackage is installed: $(rpm -qa 'retroarch*' | tr '\n' ' ')"
rpm -q libretro-shaders-blockie > /dev/null || fail "libretro-shaders-blockie not installed"
for p in crt-gdv-mini lcd3x gb-zfast-lcd gba-zfast-lcd lcd1x sameboy-lcd retro-v2 sp101-color gba-zfast-lcd-sp101; do
  f=/usr/share/libretro/shaders/blockie/$p.glslp
  [[ -f $f && $(rpm -qf --qf '%{NAME}' "$f") == libretro-shaders-blockie ]] || fail "preset $p.glslp missing"
done
ra=/usr/share/blockie/retroarch
[[ -f $ra/shader-defaults ]] || fail "shader-defaults missing"
declare -A seen=()
while read -r s p extra || [[ -n $s ]]; do
  [[ -n $s ]] || continue
  [[ $s =~ ^(gb|gbc|nes|snes|genesis|gba|ps1|n64|psp|dc)$ && -z ${seen[$s]:-} && -n $p && -z $extra ]] ||
    fail "shader-defaults line '$s $p $extra' is not one <system> <preset> line per wrapper system"
  seen[$s]=1
  r=$(realpath -e -- "$p" 2> /dev/null) || r=
  [[ $p == /usr/share/libretro/shaders/*.glslp && -f $r && $r == /usr/share/libretro/shaders/*.glslp ]] ||
    [[ $p == /var/lib/blockie/shaders/*.slangp && $(realpath -m -- "$p") == "$p" ]] ||
    fail "shader-defaults $s: $p is not an existing .glslp under /usr/share/libretro/shaders or a .slangp under /var/lib/blockie/shaders"
done < "$ra/shader-defaults"
cmp -s <(printf '%s\n' 'gambatte_gb_colorization = "auto"' 'gambatte_gb_internal_palette = "GBC - Pastel Mix"' \
  'gambatte_gbc_color_correction = "always"' 'gambatte_mix_frames = "lcd_ghosting"') "$ra/core/gambatte.opt" || fail "core/gambatte.opt"
cmp -s <(printf '%s\n' 'mgba_interframe_blending = "mix_smart"') "$ra/core/mgba.opt" || fail "core/mgba.opt"
grep -qxF 'menu_show_load_content_animation = "false"' "$ra/blockie.cfg" || fail "the load content animation is not off"
! grep -HE '^input_[a-z0-9_]+ = "f1[345]"|^input_[a-z0-9_]+_btn = "10"' "$ra/blockie.cfg" "$ra"/autoconfig/udev/*.cfg \
  "$ra"/core/*.cfg || fail "a shipped RetroArch config binds f13 to f15 or joypad button 10"
kr=/usr/lib/udev/rules.d/61-blockie-keys.rules
[[ $(grep -c . "$kr") == 2 ]] || fail "61-blockie-keys.rules is not two lines"
[[ $(sed -n 1p "$kr") == 'ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="odm:gpio_keys", ENV{KEYBOARD_KEY_1}="f14", ENV{KEYBOARD_KEY_2}="f13", ENV{KEYBOARD_KEY_3}="f15", ENV{.BLOCKIE_KEYS}="1"' ]] ||
  fail "61-blockie-keys.rules line 1 is not the gpio-keys match with indexes 1 to 3 on f14, f13, f15 and the marker"
[[ $(sed -n 2p "$kr") == 'ENV{.BLOCKIE_KEYS}=="1", IMPORT{builtin}="keyboard"' ]] ||
  fail "61-blockie-keys.rules line 2 is not the keyboard builtin on the marker alone"
[[ $(grep -c 'ENV{KEYBOARD_KEY_.*IMPORT\|IMPORT.*ENV{KEYBOARD_KEY_' "$kr") == 0 ]] ||
  fail "an IMPORT shares a line with ENV{KEYBOARD_KEY_"
[[ $(grep -o 'KEYBOARD_KEY_[0-9a-f]*' "$kr" | sort | paste -sd ' ') == 'KEYBOARD_KEY_1 KEYBOARD_KEY_2 KEYBOARD_KEY_3' ]] ||
  fail "61-blockie-keys.rules maps other indexes than 1 to 3 (index 0 is volume down)"
[[ ! -e /usr/lib/blockie/hotkeys.d/emulation.conf.d/50-game.conf ]] || fail "50-game.conf is still shipped"
for f in /usr/lib/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /etc/sysctl.d/*.conf /etc/sysctl.conf; do
  [[ -f $f ]] || continue
  while read -r v; do
    [[ $v == 0 || $v == 16 ]] || fail "$f sets kernel.sysrq to $v"
  done < <(sed -n 's/^[[:space:]]*-\{0,1\}kernel[./]sysrq[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f")
done
[[ -f /usr/lib/firmware/regulatory.db ]] || fail "regulatory.db missing"

jq -e '. == {
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {"ghcr.io/seilent/blockie": [{"type": "sigstoreSigned",
      "keyPaths": ["/usr/share/blockie/keys/blockie.pub"], "signedIdentity": {"type": "matchRepository"}}]},
    "oci": {"": [{"type": "insecureAcceptAnything"}]}
  }}' /etc/containers/policy.json > /dev/null || fail "policy.json is not exactly the planned policy"
[[ -s /usr/share/blockie/keys/blockie.pub ]] || fail "public key missing"
grep -qx 'SystemMaxUse=200M' /usr/lib/systemd/journald.conf.d/50-blockie.conf || fail "journal size not capped"
cmp -s <(printf '[Service]\nExecStart=\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=input\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=drm --subsystem-match=dma_heap\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=misc --sysname-match=mali0 --sysname-match=uinput\n') \
  /usr/lib/systemd/system/systemd-udev-trigger.service.d/50-blockie.conf || fail "coldplug drop-in"
cmp -s <(printf '[zram0]\nzram-size = ram\ncompression-algorithm = zstd\nswap-priority = 100\n') \
  /usr/lib/systemd/zram-generator.conf || fail "zram-generator.conf"
rpm -q zram-generator > /dev/null || fail "zram-generator missing"
cmp -s <(printf '[Service]\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=block --sysname-match=zram*\n') \
  /usr/lib/systemd/system/systemd-udev-trigger.service.d/51-blockie-zram.conf || fail "zram coldplug drop-in"
for u in blockie-boot-ok.service blockie-blobs.service; do
  [[ -L /etc/systemd/system/multi-user.target.wants/$u ]] || fail "$u is not enabled"
done
for v in FAILED ACTIVE NOT_EXIT1; do
  grep -q "^BLOCKIE_BOOT_OK_$v=" /usr/lib/blockie/boot-ok.conf || fail "boot-ok.conf lacks BLOCKIE_BOOT_OK_$v"
done
grep -qxF 'BLOCKIE_BOOT_OK_NOT_EXIT1=${BLOCKIE_BOOT_OK_NOT_EXIT1:-blockie-dl1.service blockie-clocks.service}' \
  /usr/lib/blockie/boot-ok.conf || fail "boot-ok.conf does not hold blockie-dl1 and blockie-clocks in BLOCKIE_BOOT_OK_NOT_EXIT1"
grep -qxF 'BLOCKIE_BOOT_OK_NO_FILE=${BLOCKIE_BOOT_OK_NO_FILE:-/run/blockie-clocks/failed}' /usr/lib/blockie/boot-ok.conf ||
  fail "boot-ok.conf does not name /run/blockie-clocks/failed in BLOCKIE_BOOT_OK_NO_FILE"
sd=/usr/lib/systemd/system
for l in Type=oneshot RemainAfterExit=yes SuccessExitStatus=2 'ExecStart=/usr/libexec/blockie/blockie-clocks apply' \
  'ExecStop=/usr/libexec/blockie/blockie-clocks restore' TimeoutStartSec=60s TimeoutStopSec=5s \
  'Wants=blockie-setd.service blockie-clocks-change.service' After=blockie-setd.service Before=waydroid-container.service \
  '[Install]' WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-clocks.service || fail "blockie-clocks.service lacks '$l'"
done
for l in Type=oneshot SuccessExitStatus=2 'ExecStart=/usr/libexec/blockie/blockie-clocks change' TimeoutStartSec=60s \
  After=blockie-clocks.service Requisite=blockie-clocks.service PartOf=blockie-clocks.service; do
  grep -qxF "$l" $sd/blockie-clocks-change.service || fail "blockie-clocks-change.service lacks '$l'"
done
sed -n '/^\[Unit\]/,/^\[/p' $sd/blockie-clocks-change.service | grep -qxF StartLimitIntervalSec=0 ||
  fail "blockie-clocks-change.service lacks StartLimitIntervalSec=0 in [Unit]"
! grep -q '^\[Install\]' $sd/blockie-clocks-change.service || fail "blockie-clocks-change.service has an [Install] section"
for l in DefaultDependencies=no After=blockie-clocks.service Requisite=blockie-clocks.service PartOf=blockie-clocks.service \
  Conflicts=shutdown.target Before=shutdown.target PathChanged=/run/blockie-set/settings Unit=blockie-clocks-change.service \
  '[Install]' WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-clocks.path || fail "blockie-clocks.path lacks '$l'"
done
for l in OnActiveSec=60s OnUnitInactiveSec=60s Unit=blockie-clocks-change.service After=blockie-clocks.service \
  Requisite=blockie-clocks.service PartOf=blockie-clocks.service '[Install]' WantedBy=multi-user.target; do
  grep -qxF "$l" $sd/blockie-clocks-change.timer || fail "blockie-clocks-change.timer lacks '$l'"
done
! grep -q '^RuntimeDirectory' $sd/blockie-clocks.service $sd/blockie-clocks-change.service $sd/blockie-clocks.path \
  $sd/blockie-clocks-change.timer || fail "a clocks unit carries RuntimeDirectory="
for u in blockie-clocks.service blockie-clocks.path blockie-clocks-change.timer; do
  [[ -L /etc/systemd/system/multi-user.target.wants/$u ]] || fail "$u is not enabled"
done
cmp -s <(printf '[Unit]\nAfter=blockie-clocks.service\n') "$sd/user@.service.d/60-blockie-clocks.conf" ||
  fail "the user@ drop-in is not After=blockie-clocks.service alone"
[[ $(stat -c %a /usr/libexec/blockie/blockie-clocks 2> /dev/null) == 755 ]] || fail "blockie-clocks is not a 755 file"
cfs=$(sed -n 's/^\[\(.*\)\]$/\1/p' /usr/lib/blockie/clocks.conf | paste -sd' ')
cenum=$(jq -r '.keys["power.clocks"].enum | join(" ")' /usr/share/blockie/schema.d/30-clocks.json)
[[ $cenum == "$cfs" ]] || fail "power.clocks enum $cenum, clocks.conf sections $cfs"
cdef=$(jq -r '.keys["power.clocks"].default' /usr/share/blockie/schema.d/30-clocks.json)
[[ $(sed -n 's/^default=//p' /usr/lib/blockie/clocks.conf) == "$cdef" ]] ||
  fail "clocks.conf default=$(sed -n 's/^default=//p' /usr/lib/blockie/clocks.conf), power.clocks default $cdef"
jq -e '.keys["power.clocks"] | .type == "s" and .map == true and .group == "power"' \
  /usr/share/blockie/schema.d/30-clocks.json > /dev/null || fail "30-clocks.json: power.clocks is not a mapped s key on power"
for f in line_65000:trip-65000.line line_72000:trip-72000.line line_80000:trip-80000.line read_boot:tzcpu-boot.read \
  read_65000:tzcpu-65000.read read_72000:tzcpu-72000.read read_80000:tzcpu-80000.read; do
  pin=$(sed -n "s/^pin_${f%%:*}=\([0-9a-f]\{64\}\)\$/\1/p" /usr/libexec/blockie/blockie-clocks)
  [[ -n $pin && $(sha256sum < "/usr/lib/blockie/clocks/${f#*:}") == "$pin  -" ]] ||
    fail "/usr/lib/blockie/clocks/${f#*:} does not hash to pin_${f%%:*} in blockie-clocks"
done
[[ -d /usr/share/blockie/blobs.d ]] || fail "no blobs.d"
rpm -q blockie-gpu > /dev/null || fail "blockie-gpu not installed"
[[ -f /usr/share/blockie/blobs.d/rk-g29p1.conf && -f /usr/share/blockie/vulkan/rk-g29p1.json ]] || fail "gpu conf or icd missing"
[[ -x /usr/libexec/blockie/blockie-gpufreq && -f /usr/lib/udev/rules.d/60-blockie-gpu.rules ]] || fail "gpufreq or gpu rules missing"
[[ ! -e /etc/ld.so.preload ]] || fail "/etc/ld.so.preload present"
rpm -q labwc blockie-compositor > /dev/null || fail "labwc or blockie-compositor not installed"
[[ -x /usr/libexec/blockie/blockie-compositor && -f /usr/lib64/blockie/libblockie-nocursor.so && -f /usr/lib64/blockie/libblockie-glfinish.so ]] || fail "compositor wrapper or shims missing"
[[ -f /usr/share/blockie/labwc/rc.xml && -f /usr/share/icons/blockie-none/cursors/blockie-none ]] || fail "labwc config or cursor theme missing"
[[ -f /usr/lib/systemd/user/blockie-.service.d/50-blockie-gpu.conf ]] || fail "blockie user unit gpu drop-in missing"
rpm -q blockie-frontend > /dev/null || fail "blockie-frontend not installed"
[[ -x /usr/libexec/blockie/blockie-frontend && -f /usr/lib/systemd/user/blockie-frontend.service ]] || fail "frontend binary or unit missing"
xdg=$(mktemp -d)
XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no /usr/lib/systemd/user/blockie-frontend.service ||
  fail "blockie-frontend.service does not verify"
XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no /usr/lib/systemd/user/blockie-poweroff.service ||
  fail "blockie-poweroff.service does not verify"
XDG_RUNTIME_DIR=$xdg systemd-analyze verify --user --man=no /usr/lib/systemd/user/blockie-funeos.service ||
  fail "blockie-funeos.service does not verify"
rm -rf "${xdg:?}"
rpm -q wlopm > /dev/null || fail "wlopm not installed"
rpm -q waydroid lxc dnsmasq iptables-legacy > /dev/null || fail "waydroid, lxc, dnsmasq or iptables-legacy not installed"
[[ $(rpm -q --qf '%{RELEASE}' waydroid) == *.blockie ]] || fail "waydroid is not the blockie build: $(rpm -q waydroid)"
! rpm -q waydroid-selinux > /dev/null || fail "waydroid-selinux is installed"
grep -qx 'd /var/lib/dnsmasq 0755 root dnsmasq -' /usr/lib/tmpfiles.d/dnsmasq.conf || fail "no tmpfiles line for /var/lib/dnsmasq"
for h in blank-on blank-off screen-on menu-on; do
  [[ -f /usr/lib/blockie/hooks.d/$h && $(stat -c %a "/usr/lib/blockie/hooks.d/$h") == 755 ]] || fail "hook $h is not a 755 file"
done
[[ -x /usr/libexec/blockie/blockie-poweroff ]] || fail "blockie-poweroff missing"
for f in blockie-hook blockie-funeos blockie-funeos-check; do
  [[ $(stat -c %a "/usr/libexec/blockie/$f" 2> /dev/null) == 755 ]] || fail "$f is not a 755 file"
done
grep -qxF 'ExecStart=/usr/bin/blockie-session request %i app' /usr/lib/systemd/system/blockie-session-appswitch@.service ||
  fail "blockie-session-appswitch@.service missing or not requesting with reason app"
grep -qF '/^blockie-session-(switch|appswitch|revive)@[a-z0-9][a-z0-9-]*\.service$/' \
  /usr/share/polkit-1/rules.d/50-blockie-session.rules || fail "the session polkit rule lacks appswitch@"
[[ $(stat -c %a /usr/libexec/blockie/blockie-backlight 2> /dev/null) == 755 ]] || fail "blockie-backlight is not a 755 file"
[[ $(stat -c %a /usr/libexec/blockie/blockie-sleep 2> /dev/null) == 755 ]] || fail "blockie-sleep is not a 755 file"
for l in 'z /sys/power/state 0664 root blockie -' 'z /sys/power/wakeup_count 0664 root blockie -' \
  'd /run/blockie-sleep 0755 root root -'; do
  grep -qxF "$l" /usr/lib/tmpfiles.d/blockie.conf || fail "no tmpfiles line '$l'"
done
po=/usr/lib/systemd/user/blockie-poweroff.service
grep -qx 'Type=oneshot' "$po" && grep -qx 'TimeoutStartSec=25s' "$po" && ! grep -q '^\[Install\]' "$po" ||
  fail "blockie-poweroff.service is not a 25 s oneshot without [Install]"
grep -qx 'ExecStopPost=-/usr/libexec/blockie/blockie-hook blank-off' /usr/lib/systemd/user/blockie-hotkeyd.service ||
  fail "a hotkeyd stop does not wake the screen"
cmp -s <(printf '[Login]\nHandlePowerKey=ignore\nHandlePowerKeyLongPress=ignore\n') /usr/lib/systemd/logind.conf.d/50-blockie.conf ||
  fail "logind drop-in is not the two ignore lines"
! grep -q '^\[Install\]' /usr/lib/systemd/system/geoclue.service || fail "geoclue.service can be enabled"
[[ -z $(find /etc/systemd /usr/lib/systemd -path '*.wants/*' \( -name 'geoclue*' -o -name 'xdg-*portal*' \)) ]] || fail "a geoclue or portal unit is enabled"

vt=$(mktemp -d)
wp=/usr/share/wireplumber
for l in 'name = blockie/volume-limit.lua, type = script/lua' 'provides = custom.blockie-volume-limit' \
  'requires = [ support.settings, api.mixer ]' 'after = [ support.standard-event-source ]' 'before = [ monitor.alsa ]' \
  'type = virtual, provides = custom.blockie-audio' \
  'wants = [ custom.blockie-volume-limit ]' 'custom.blockie-audio = required'; do
  grep -qxF "    $l" "$wp/wireplumber.conf.d/60-blockie-volume-limit.conf" ||
    grep -qxF "  $l" "$wp/wireplumber.conf.d/60-blockie-volume-limit.conf" || fail "60-blockie-volume-limit.conf lacks $l"
done
spa-json-dump "$wp/wireplumber.conf.d/60-blockie-volume-limit.conf" > "$vt/vl.json" || fail "60-blockie-volume-limit.conf does not parse"
jq -e '.["wireplumber.settings.schema"]["blockie.volume-limit"] | .type == "float" and .default == 1.0 and .min == 0.05
  and .max == 1.0' "$vt/vl.json" > /dev/null || fail "the blockie.volume-limit schema entry: $(cat "$vt/vl.json")"
[[ -s $wp/scripts/blockie/volume-limit.lua ]] || fail "volume-limit.lua missing"
pf=/usr/share/pipewire/pipewire.conf.d/60-blockie-volume-limit.conf
spa-json-dump "$pf" > "$vt/pf.json" || fail "$pf does not parse"
jq -e '.["context.modules"] | length == 1 and (.[0] | .name == "libpipewire-module-filter-chain" and (has("flags") | not)
  and (.args | (has("audio.rate") | not) and .["audio.channels"] == 2 and .["audio.position"] == ["FL", "FR"]
  and .["filter.graph"] == {"nodes": [{"type": "builtin", "name": "gain", "label": "linear",
    "control": {"Mult": 0.0, "Add": 0.0}}], "inputs": ["gain:In"], "outputs": ["gain:Out"]}
  and .["capture.props"] == {"node.name": "blockie.volume-limit", "media.class": "Audio/Sink", "filter.smart": true,
    "filter.smart.name": "blockie-volume-limit",
    "filter.smart.target": {"api.alsa.card.name": "mt6768-mt6358", "media.class": "Audio/Sink"},
    "state.restore-props": "false"}
  and .["playback.props"] == {"node.name": "blockie.volume-limit.output", "node.passive": true,
    "node.dont-fallback": true, "node.linger": true, "state.restore-props": "false", "state.restore-target": "false"}))' \
  "$vt/pf.json" > /dev/null || fail "60-blockie-volume-limit.conf is not the planned silent filter: $(cat "$vt/pf.json")"
u=/usr/lib/systemd/user
for l in Type=oneshot "ExecStart=/usr/libexec/blockie/blockie-volume limit" After=wireplumber.service StartLimitIntervalSec=0 WantedBy=wireplumber.service; do
  grep -qxF "$l" "$u/blockie-volume-limit.service" || fail "blockie-volume-limit.service lacks $l"
done
! grep -Eq '^(RemainAfterExit|PartOf)=' "$u/blockie-volume-limit.service" || fail "blockie-volume-limit.service has RemainAfterExit or PartOf"
for l in PathChanged=/run/blockie-set/settings Unit=blockie-volume-limit.service WantedBy=default.target; do
  grep -qxF "$l" "$u/blockie-volume-limit.path" || fail "blockie-volume-limit.path lacks $l"
done
[[ $(readlink -f /etc/systemd/user/wireplumber.service.wants/blockie-volume-limit.service) == "$u/blockie-volume-limit.service" &&
  $(readlink -f /etc/systemd/user/default.target.wants/blockie-volume-limit.path) == "$u/blockie-volume-limit.path" ]] ||
  fail "the preset does not enable blockie-volume-limit.service and .path"
rm -rf "${vt:?}"

echo "image: dnf5 $(rpm -q dnf5)"
echo "image: ok $kver"
