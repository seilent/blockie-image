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
for p in /var/cache/libX11 /var/cache/libX11/compose /var/lib/alsa /var/lib/bluetooth /var/lib/bluetooth/mesh; do
  [[ -d $p && ! -L $p ]] || fail "$p is not a directory in the image"
  l="d $p $(stat -c '%04a %U %G' "$p") -"
  grep -qxF "$l" /usr/lib/tmpfiles.d/blockie.conf || fail "no tmpfiles line '$l'"
done
grep -qx 'enable blockie-\*' /usr/lib/systemd/system-preset/50-blockie.preset || fail "blockie preset"

rpm -q systemd bootc ostree skopeo podman NetworkManager kmod > /dev/null || fail "base rpms missing"
rpm -q e2fsprogs erofs-utils vulkan-tools egl-utils drm-utils strace file procps-ng jq libwayland-client \
  libwayland-server NetworkManager-wifi wpa_supplicant iw wireless-regdb iperf3 bluez alsa-ucm alsa-ucm-utils \
  alsa-utils retroarch libretro-mgba libretro-pcsx-rearmed > /dev/null || fail "packages missing"
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
cmp -s <(printf '[Service]\nExecStart=\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=input\n') \
  /usr/lib/systemd/system/systemd-udev-trigger.service.d/50-blockie.conf || fail "coldplug drop-in"

echo "image: ok $kver"
