#!/usr/bin/env bash
set -u

script=${DATA_SCRIPT:-/usr/libexec/blockie/blockie-data}
unit=${DATA_UNIT:-/usr/lib/systemd/system/blockie-data.service}
conf=${DATA_TMPFILES:-/usr/lib/blockie/data-tmpfiles.conf}
drop=${DATA_DROPIN:-/usr/lib/systemd/system/user@.service.d/52-blockie-data.conf}
top=$(mktemp -d "${TMPDIR:-/tmp}/data.XXXXXX")
trap 'rm -rf "${top:?}"' EXIT
fails=0

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

for kv in Type=oneshot RemainAfterExit=yes TimeoutStartSec=120 ExecStart=/usr/libexec/blockie/blockie-data \
  "ExecStartPost=/usr/bin/systemd-tmpfiles --create /usr/lib/blockie/data-tmpfiles.conf" \
  RequiresMountsFor=/var/lib/blockie WantedBy=multi-user.target; do
  grep -qxF "$kv" "$unit"
  res $? "unit has $kv"
done
! grep -q '^Requires=\|^RequiredBy=\|^Before=multi-user' "$unit"
res $? "unit: no hard dependency, a missing p4 fails only this unit"
for kv in Wants=blockie-data.service After=blockie-data.service; do
  grep -qxF "$kv" "$drop"
  res $? "user@ drop-in has $kv"
done
! grep -q '^Requires=\|^Requisite=\|^BindsTo=' "$drop"
res $? "user@ drop-in: no hard dependency, a missing p4 does not stop the session"
seat=${DATA_SEAT:-/usr/lib/systemd/system/blockie-seat.service}
grep -qE '^After=(.* )?blockie-data\.service( |$)' "$seat" && grep -qE '^Wants=(.* )?blockie-data\.service( |$)' "$seat" &&
  ! grep -qE '^(Requires|Requisite|BindsTo)=.*blockie-data' "$seat"
res $? "seat: Wants and After blockie-data, so its PAM call never waits on the data step"
if [[ -z ${DATA_UNIT:-} ]]; then
  [[ -L /etc/systemd/system/multi-user.target.wants/blockie-data.service ]]
  res $? "unit enabled"
  ! grep -qw blockie-data.service /usr/lib/blockie/boot-ok.conf
  res $? "boot-ok does not wait on blockie-data"
fi

want=$(printf 'd /var/lib/blockie/data/%s 0755 blockie blockie -\n' cache media saves states)
[[ $(cat "$conf") == "$want" ]]
res $? "tmpfiles: cache, media, saves, states owned by blockie"
! grep -qE 'data/(roms|bios)|data/? |data -' "$conf"
res $? "tmpfiles: no line for roms/, bios/ or the mount root"
[[ ! -e /usr/lib/tmpfiles.d/blockie-data.conf ]] && ! grep -rqs 'blockie/data' /usr/lib/tmpfiles.d
res $? "tmpfiles: not in tmpfiles.d, so nothing is made under /var before the mount"
[[ -z $(awk '$2 == "/var/lib/blockie" && $4 != "root"' /usr/lib/tmpfiles.d/*.conf 2> /dev/null) ]]
res $? "tmpfiles: /var/lib/blockie stays root owned, so uid 1000 cannot make data/ under it"

if [[ -z ${DATA_TMPFILES:-} ]] && command -v systemd-tmpfiles > /dev/null; then
  r=$top/root
  mkdir -p "$r/etc" "$r/var/lib/blockie/data/roms/gba" "$r/var/lib/blockie/data/bios"
  systemd-sysusers > /dev/null 2>&1
  getent passwd > "$r/etc/passwd"
  getent group > "$r/etc/group"
  printf 'invented rom\n' > "$r/var/lib/blockie/data/roms/gba/test.gba"
  printf 'invented bios\n' > "$r/var/lib/blockie/data/bios/test.bin"
  before=$(cd "$r/var/lib/blockie/data" && find roms bios -printf '%p %u %g %m\n' | sort)
  systemd-tmpfiles --root="$r" --create "$conf" > "$top/tmpfiles.out" 2>&1
  ok=$?
  for n in cache media saves states; do
    [[ $(stat -c '%U %G %a' "$r/var/lib/blockie/data/$n") == "blockie blockie 755" ]] || ok=1
  done
  [[ $(cd "$r/var/lib/blockie/data" && find roms bios -printf '%p %u %g %m\n' | sort) == "$before" ]] || ok=1
  res $ok "tmpfiles applied: four blockie dirs, roms/ and bios/ unchanged"
fi

setup() {
  d=$top/$1
  sys=$d/sys
  mkdir -p "$d/bin" "$d/dev" "$d/target"
  part 11240000.mmc mmcblk1 mmcblk1p3 BLOCKIE_OS
  part 11240000.mmc mmcblk1 mmcblk1p4 BLOCKIE_DATA
  part 11230000.mmc mmcblk0 mmcblk0p20 userdata
  echo ext4 > "$d/type.mmcblk1p4"
  echo BLOCKIE_DATA > "$d/label.mmcblk1p4"
  : > "$d/calls"
  cat > "$d/bin/mountpoint" << EOF2
#!/bin/sh
[ -e "$d/mounted" ]
EOF2
  cat > "$d/bin/blkid" << EOF2
#!/bin/sh
n=\${6##*/}
case \$5 in
TYPE) cat "$d/type.\$n" ;;
LABEL) cat "$d/label.\$n" 2> /dev/null ;;
esac
EOF2
  echo 0 > "$d/fsck.rc"
  cat > "$d/bin/e2fsck" << EOF2
#!/bin/sh
echo "e2fsck \$*" >> "$d/calls"
exit \$(cat "$d/fsck.rc")
EOF2
  cat > "$d/bin/mount" << EOF2
#!/bin/sh
echo "mount \$*" >> "$d/calls"
EOF2
  chmod 755 "$d/bin/mountpoint" "$d/bin/blkid" "$d/bin/e2fsck" "$d/bin/mount"
}

part() {
  local p=$sys/devices/platform/$1/mmc_host/mmc0/mmc0:0001/block/$2/$3
  mkdir -p "$p" "$sys/class/block"
  printf 'MAJOR=179\nDEVNAME=%s\nDEVTYPE=partition\nPARTNAME=%s\n' "$3" "$4" > "$p/uevent"
  echo 1 > "$p/partition"
  ln -sfn "$p" "$sys/class/block/$3"
}

run() {
  PATH="$d/bin:$PATH" BLOCKIE_SYS=$sys BLOCKIE_DEV=$d/dev BLOCKIE_DATA_DIR=$d/target "$script" > "$d/out" 2>&1
  rc=$?
}

setup one
run
mounted="mount -t ext4 -o rw,noatime,nodev,nosuid,noexec $d/dev/mmcblk1p4 $d/target"
[[ $rc == 0 && $(cat "$d/calls") == "$(printf 'e2fsck -p %s\n%s' "$d/dev/mmcblk1p4" "$mounted")" ]]
res $? "script: e2fsck -p, then the one BLOCKIE_DATA partition on the SD host mounted rw,noatime,nodev,nosuid,noexec"

setup fsck-fixed
echo 1 > "$d/fsck.rc"
run
mounted="mount -t ext4 -o rw,noatime,nodev,nosuid,noexec $d/dev/mmcblk1p4 $d/target"
[[ $rc == 0 && $(tail -n 1 "$d/calls") == "$mounted" ]] && ! grep -q reboot "$d/out"
res $? "script: e2fsck rc 1 (errors fixed): mounted"

setup fsck-reboot
echo 2 > "$d/fsck.rc"
run
mounted="mount -t ext4 -o rw,noatime,nodev,nosuid,noexec $d/dev/mmcblk1p4 $d/target"
[[ $rc == 0 && $(tail -n 1 "$d/calls") == "$mounted" ]] && grep -q "asks for a reboot, mounting anyway" "$d/out"
res $? "script: e2fsck rc 2 (reboot asked): logged, mounted"

setup fsck-fixed-reboot
echo 3 > "$d/fsck.rc"
run
mounted="mount -t ext4 -o rw,noatime,nodev,nosuid,noexec $d/dev/mmcblk1p4 $d/target"
[[ $rc == 0 && $(tail -n 1 "$d/calls") == "$mounted" ]] && grep -q "asks for a reboot, mounting anyway" "$d/out"
res $? "script: e2fsck rc 3 (fixed, reboot asked): logged, mounted"

setup fsck-left
echo 4 > "$d/fsck.rc"
run
[[ $rc == 1 ]] && ! grep -q '^mount' "$d/calls" && grep -q "exited 4, not mounted" "$d/out"
res $? "script: e2fsck rc 4 (errors left): refused, not mounted"

setup fsck-error
echo 8 > "$d/fsck.rc"
run
[[ $rc == 1 ]] && ! grep -q '^mount' "$d/calls" && grep -q "exited 8, not mounted" "$d/out"
res $? "script: e2fsck rc 8 (operational error): refused, not mounted"

setup mounted
: > "$d/mounted"
run
[[ $rc == 0 && ! -s $d/calls ]] && grep -q "already mounted" "$d/out"
res $? "script: already mounted, no second mount"

setup none
rm -rf "$sys/class/block/mmcblk1p4"
run
[[ $rc == 1 && ! -s $d/calls ]] && grep -q "found 0" "$d/out"
res $? "script: no p4, refused, nothing mounted"

setup two
part 11240000.mmc mmcblk1 mmcblk1p5 BLOCKIE_DATA
run
[[ $rc == 1 && ! -s $d/calls ]] && grep -q "found 2" "$d/out"
res $? "script: two BLOCKIE_DATA partitions, refused"

setup emmc
rm -rf "$sys/class/block/mmcblk1p4"
part 11230000.mmc mmcblk0 mmcblk0p21 BLOCKIE_DATA
run
[[ $rc == 1 && ! -s $d/calls ]]
res $? "script: a BLOCKIE_DATA partition on the eMMC host is not taken"

setup not-ext4
echo vfat > "$d/type.mmcblk1p4"
run
[[ $rc == 1 && ! -s $d/calls ]] && grep -q "not ext4" "$d/out"
res $? "script: not ext4, refused"

setup label
echo OTHER > "$d/label.mmcblk1p4"
run
[[ $rc == 1 && ! -s $d/calls ]] && grep -q "not labelled" "$d/out"
res $? "script: a filesystem label other than BLOCKIE_DATA, refused"

if [[ $(id -u) == 0 ]] && command -v setpriv > /dev/null; then
  chmod 0755 "$top"
  as_user() { setpriv --reuid=1000 --regid=1000 --clear-groups "$@" 2> /dev/null; }

  setup bare-first
  chmod 0755 "$d"
  rm -rf "$d/target" "$sys/class/block/mmcblk1p4"
  run
  [[ $rc == 1 && ! -e $d/target ]] && ! as_user mkdir -p "$d/target/cache"
  res $? "unmounted, never mounted: no target dir and uid 1000 cannot make one"

  setup bare-after
  chmod 0755 "$d"
  rm -rf "$d/target"
  run
  [[ $rc == 0 && $(stat -c '%U %G %a' "$d/target") == "root root 755" && -z $(ls -A "$d/target") ]] &&
    ! as_user mkdir "$d/target/cache" && ! as_user touch "$d/target/x"
  res $? "unmounted after a mount: the bare target is root 0755, empty, and uid 1000 cannot write it"
fi

if [[ $fails == 0 ]]; then
  echo "data: all ok"
  exit 0
fi
echo "data: $fails failed"
exit 1
