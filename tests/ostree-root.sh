#!/usr/bin/env bash
set -euo pipefail

fail() { echo "ostree-root: $*" >&2; exit 1; }

img=${1:?usage: ostree-root.sh <root ext4 image, changed by the test> <ostree-root functions>}
funcs=${2:?usage: ostree-root.sh <root ext4 image, changed by the test> <ostree-root functions>}
bb=${BUSYBOX:-/bin/busybox}
[[ $(id -u) == 0 ]] || fail "run as root"
[[ -x $bb && $(file -b "$bb") == *statically\ linked* ]] || fail "$bb is not a static busybox"

if [[ -z ${OSTREE_ROOT_NS:-} ]]; then
  exec unshare -m --propagation private env OSTREE_ROOT_NS=1 "$0" "$(realpath "$img")" "$(realpath "$funcs")"
fi

m=$(mktemp -d)
mount -t tmpfs mini "$m"
mkdir -p "$m"/{bin,proc,sys,dev,run,tmp,mnt/root,blockie/lib}
cp "$bb" "$m/bin/busybox"
chroot "$m" /bin/busybox --install -s /bin
cp "$funcs" "$m/blockie/lib/ostree-root"
mount -t proc proc "$m/proc"
mount --bind /sys "$m/sys"
mount --rbind /dev "$m/dev"
mount -t tmpfs run "$m/run"
mkdir "$m/run/blockie"
mount -o loop,rw "$img" "$m/mnt/root"

fn() { chroot "$m" /bin/sh -c ". /blockie/lib/ostree-root; $1"; }

out=$(fn 'ostree_pick /mnt/root || { echo "fail=$ot_fail"; exit 0; }; echo "pick=$ot_pick by=$ot_by"')
[[ $out == "pick="*" by=default" ]] || fail "ostree_pick: $out"
d=${out#pick=}
d=${d%% *}
echo "ostree-root: pick $d by=default"

out=$(fn 'ostree_pick /mnt/root && ostree_cmdline /run/blockie/cmdline; echo "fail=$ot_fail"')
[[ $out == "fail=" ]] || fail "ostree_cmdline: $out"
mkdir "$m/run/ostree"
out=$(fn 'ostree_pick /mnt/root && ostree_cmdline /run/blockie/cmdline && ostree_prepare /mnt/root /run/blockie/cmdline; echo "fail=$ot_fail"')
[[ $out == *"fail=run_exists" ]] || fail "a pre made /run/ostree did not refuse: $out"
dep=/mnt/root/ostree/deploy/default/deploy/$d
rc=0
err=$(chroot "$m" "$dep/usr/lib/ld-linux-aarch64.so.1" --library-path "$dep/usr/lib64" "$dep/usr/lib/ostree/ostree-prepare-root" \
  /mnt/root "$(cat "$m/run/blockie/cmdline")" 2>&1) || rc=$?
(( rc != 0 )) || fail "ostree-prepare-root ran with /run/ostree present"
grep -q 'Failed to create /run/ostree' <<< "$err" || fail "prepare-root failed for another reason: $err"
rmdir "$m/run/ostree"
[[ ! -e $m/sysroot.tmp && ! -e $m/run/ostree-booted && -d $m/mnt/root/ostree && ! -e $m/mnt/root/usr ]] \
  || fail "the refused prepare-root changed state"
echo "ostree-root: /run/ostree present: the functions refuse, prepare-root exits $rc (Failed to create /run/ostree)"

printf '%s androidboot.slot_suffix=_a\n' "$(cat /proc/cmdline)" > "$m/tmp/cmdline.android"
mount --bind "$m/tmp/cmdline.android" "$m/proc/cmdline"
out=$(fn 'ostree_pick /mnt/root && ostree_cmdline /run/blockie/cmdline; echo "fail=$ot_fail"')
umount "$m/proc/cmdline"
[[ $out == *"fail=androidboot" ]] || fail "an androidboot word did not refuse: $out"
echo "ostree-root: androidboot refuses"

out=$(fn 'ostree_pick /mnt/root && ostree_cmdline /run/blockie/cmdline && ostree_prepare /mnt/root /run/blockie/cmdline; echo "fail=$ot_fail rc=$ot_rc usr=$ot_usr sysroot=$ot_sysroot booted=$ot_booted"')
[[ $out == *"fail= rc=0 usr=ro sysroot=ro booted=yes" ]] || fail "ostree_prepare: $out"
grep -q " blockie.deploy=$d blockie.pick=default$" "$m/run/blockie/cmdline" || fail "cmdline: $(cat "$m/run/blockie/cmdline")"
grep -q " ostree=/ostree/boot\.[01]/default/[0-9a-f]\{64\}/0 " "$m/run/blockie/cmdline" || fail "no ostree= in the cmdline"
grep -qx 'ID=blockie' "$m/mnt/root/usr/lib/os-release" || fail "/mnt/root is not the deployment"
[[ -d $m/mnt/root/sysroot/ostree/repo ]] || fail "/mnt/root/sysroot is not the physical root"
{ touch "$m/mnt/root/etc/.ostree-root-test" && rm "$m/mnt/root/etc/.ostree-root-test"; } || fail "/etc is not writable"
[[ -e $m/run/ostree-booted && ! -e $m/sysroot.tmp ]] || fail "run state after prepare"
echo "ostree-root: ok $d"
