#!/usr/bin/env bash
set -euo pipefail

cp -a /ctx/system_files/. /

while read -r t u g; do
  if [[ $t == m && $u == blockie ]] && ! grep -q "^$g:" /etc/group; then
    grep "^$g:" /usr/lib/group >> /etc/group
  fi
done < /usr/lib/sysusers.d/blockie.conf

units=()
for u in /usr/lib/systemd/system/blockie-*; do
  if [[ -f $u ]] && grep -q '^\[Install\]' "$u"; then
    units+=("${u##*/}")
  fi
done
if (( ${#units[@]} )); then
  systemctl preset "${units[@]}"
fi

systemctl mask \
  systemd-oomd.service \
  systemd-oomd.socket \
  systemd-pstore.service \
  systemd-firstboot.service \
  bootloader-update.service \
  udisks2.service \
  fstrim.timer \
  fstrim.service \
  fwupd.service \
  fwupd-refresh.service \
  fwupd-refresh.timer \
  sleep.target \
  suspend.target \
  hibernate.target \
  hybrid-sleep.target \
  suspend-then-hibernate.target \
  systemd-repart.service \
  systemd-repart.socket \
  systemd-growfs-root.service \
  bootc-generic-growpart.service \
  lvm2-monitor.service \
  lvm2-lvmpolld.socket \
  lvm-devices-import.path \
  lvm-devices-import.service \
  dm-event.socket \
  irqbalance.service \
  selinux-autorelabel-mark.service \
  var-lib-nfs-rpc_pipefs.mount \
  bootc-fetch-apply-updates.timer \
  sshd.service \
  sshd.socket \
  systemd-soft-reboot.service \
  alsa-restore.service \
  alsa-state.service \
  alsa-card-wait@.service
install -d /etc/systemd/system-generators /etc/udev/rules.d
ln -sf /dev/null /etc/systemd/system-generators/systemd-gpt-auto-generator
ln -sf /dev/null /etc/systemd/system-generators/systemd-ssh-generator
ln -sf /dev/null /etc/udev/rules.d/90-alsa-restore.rules

sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
grep -qx 'SELINUX=disabled' /etc/selinux/config || { echo "40-system-files: SELINUX not disabled" >&2; exit 1; }

install -d -m 755 /blockie /vendor
