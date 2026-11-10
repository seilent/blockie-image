#!/usr/bin/env bash
set -u

script=$(readlink -f "${BOOT_OK_SCRIPT:-/usr/libexec/blockie/blockie-boot-ok}")
lib=$(readlink -f "${OSTREE_ROOT_LIB:-/repo-boot/ostree-root}")
top=$(mktemp -d "${TMPDIR:-/tmp}/boot-ok.XXXXXX")
trap 'rm -rf "${top:?}"' EXIT
fails=0
A=$(printf 'a%.0s' {1..64}).0
B=$(printf 'b%.0s' {1..64}).1
C=$(printf 'c%.0s' {1..64}).0
I=$(printf '1%.0s' {1..32})
J=$(printf '2%.0s' {1..32})

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

setup() {
  d=$top/$1
  s=$d/sysroot
  dep=$s/ostree/deploy/default/deploy
  mkdir -p "$d/bin" "$d/state" "$dep/$A" "$dep/$B" "$dep/$C" "$s/boot/loader/entries"
  local n=1 id
  for id in "$A" "$B"; do
    mkdir -p "$s/ostree/boot.1/default/$n$n$n"
    ln -s "../../../deploy/default/deploy/$id" "$s/ostree/boot.1/default/$n$n$n/0"
    printf 'title Blockie\nversion %s\noptions root=UUID=x rw ostree=/ostree/boot.1/default/%s/0\n' "$((3 - n))" "$n$n$n" \
      > "$s/boot/loader/entries/ostree-$n-default.conf"
    n=$((n + 1))
  done
  echo "console=tty0 ostree=/ostree/boot.1/default/111/0 blockie.deploy=$A blockie.pick=default" > "$d/cmdline"
  printf '%s 1\n%s 2\n%s 1\nnot a line\n' "$A" "$B" "$C" > "$d/state/tries"
  echo '/dev/mmcblk1p3[/ostree/deploy/default/var]' > "$d/varsrc"
  echo NetworkManager.service > "$d/active"
  : > "$d/failed"
  : > "$d/calls"
  echo 0 > "$d/bootc.rc"
  cat > "$d/conf" << 'EOF'
BLOCKIE_BOOT_OK_FAILED="ostree-remount.service blockie-adbd.service NetworkManager.service"
BLOCKIE_BOOT_OK_ACTIVE="NetworkManager.service"
BLOCKIE_BOOT_OK_NOT_EXIT1="blockie-dl1.service"
EOF
  cat > "$d/bin/findmnt" << EOF
#!/bin/sh
cat "$d/varsrc"
EOF
  cat > "$d/bin/systemctl" << EOF
#!/bin/sh
case "\$1" in
is-failed) grep -qxF "\$3" "$d/failed" ;;
is-active) grep -qxF "\$3" "$d/active" ;;
show) cat "$d/exit.\$5" 2> /dev/null || echo 0 ;;
--user)
  echo "\$*" >> "$d/shows"
  [ "\$2" = show ] && cat "$d/user.show" 2> /dev/null ;;
*) exit 9 ;;
esac
EOF
  cat > "$d/bin/setpriv" << EOF
#!/bin/sh
echo "\$*" >> "$d/setpriv"
while [ "\${1#--}" != "\$1" ]; do shift; done
exec "\$@"
EOF
  cat > "$d/bin/bootc" << EOF
#!/bin/sh
echo "bootc \$*" >> "$d/calls"
exit \$(cat "$d/bootc.rc")
EOF
  cat > "$d/bin/blockie-bootctl" << EOF
#!/bin/sh
echo "bootctl \$* confirmed=\$(cat "$d/state/confirmed" 2> /dev/null)" >> "$d/calls"
exit \$(cat "$d/bootctl.rc" 2> /dev/null || echo 0)
EOF
  chmod 755 "$d/bin/findmnt" "$d/bin/systemctl" "$d/bin/setpriv" "$d/bin/bootc" "$d/bin/blockie-bootctl"
  root=$dep/$A
}

run() {
  PATH="$d/bin:$PATH" BLOCKIE_BOOT_OK_CONF=$d/conf BLOCKIE_BOOT_STATE=$d/state BLOCKIE_CMDLINE=$d/cmdline \
    BLOCKIE_SYSROOT=$s BLOCKIE_ROOT=$root BLOCKIE_OSTREE_ROOT=$lib BLOCKIE_PRODUCT_FILE=$d/product \
    BLOCKIE_SESSION_READY=$d/ready BLOCKIE_BOOTCTL=$d/bin/blockie-bootctl BLOCKIE_HEALTHY_WAIT=${HW:-3} \
    BLOCKIE_BOOT_GATES=$d/gates BLOCKIE_HEALTHY_SETTLE=${HS:-0} BLOCKIE_SESSION_USER=root \
    "$script" "$@" > "$d/out" 2>&1
  rc=$?
}

refused() {
  [[ $rc == 1 && ! -e $d/state/confirmed ]] && grep -q "$2" "$d/out" && [[ $(cat "$d/state/tries") == "$(printf '%s 1\n%s 2\n%s 1\nnot a line' "$A" "$B" "$C")" ]]
  res $? "$1"
}

setup default
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/state/tries") == "$B 2" && ! -s $d/calls ]] \
  && grep -qx "blockie-boot-ok: confirmed $A (default)" "$d/out"
res $? "default: confirmed, booted and orphan and bad lines dropped, other kept, no bootc"
[[ $(ls -A "$d/state" | sort | tr '\n' ' ') == "confirmed tries " ]]
res $? "default: no temp files left in the state dir"

setup runconf
sed -i 's/pick=default/pick=runconf/' "$d/cmdline"
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/state/tries") == "$B 2" && ! -s $d/calls ]]
res $? "runconf of the default entry: confirmed, never rolls back"

setup runconf-old
sed -i "s/pick=default/pick=runconf/; s/blockie.deploy=$A/blockie.deploy=$B/" "$d/cmdline"
root=$dep/$B
run
[[ $rc == 0 && ! -e $d/state/confirmed && ! -s $d/calls ]] \
  && [[ $(cat "$d/state/tries") == "$(printf '%s 1\n%s 2\n%s 1\nnot a line' "$A" "$B" "$C")" ]] \
  && grep -qx "blockie-boot-ok: runconf boot of $B, the default entry is $A: nothing written" "$d/out"
res $? "runconf of an older entry: nothing written, unit succeeds"

setup fallback
sed -i 's/pick=default/pick=fallback/' "$d/cmdline"
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && ! -s $d/state/tries && $(cat "$d/calls") == "bootc rollback" ]]
res $? "fallback: one bootc rollback, then every tries line dropped"

setup fallback-fails
sed -i 's/pick=default/pick=fallback/' "$d/cmdline"
echo 1 > "$d/bootc.rc"
run
[[ $rc == 1 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/state/tries") == "$B 2" && $(cat "$d/calls") == "bootc rollback" ]] \
  && grep -q "bootc rollback failed" "$d/out"
res $? "fallback without bootc: confirmed, other tries lines kept, unit fails"

setup no-tries
rm -f "$d/state/tries"
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && -f $d/state/tries && ! -s $d/state/tries ]]
res $? "no tries file: confirmed, empty tries"

setup dl1-exit2
echo 2 > "$d/exit.blockie-dl1.service"
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" ]]
res $? "dl1 exit 2 (no card): confirmed"

setup var
echo '/dev/mmcblk1p2[/var]' > "$d/varsrc"
run
refused "wrong /var source refused" "not the stateroot var"

setup root
root=$dep/$B
run
refused "/ not the cmdline deployment refused" "is not the deployment"

setup no-entry
sed -i "s/blockie.deploy=$A/blockie.deploy=$C/" "$d/cmdline"
root=$dep/$C
run
refused "deployment without a boot entry refused" "no boot entry names"

setup bad-pick
sed -i 's/pick=default/pick=other/' "$d/cmdline"
run
refused "unknown pick refused" "pick is 'other'"

setup no-deploy
sed -i "s/ blockie.deploy=$A//" "$d/cmdline"
run
refused "cmdline without blockie.deploy refused" "names no deployment"

setup remount
echo ostree-remount.service > "$d/failed"
run
refused "failed ostree-remount refused" "ostree-remount.service failed"

setup adbd
echo blockie-adbd.service > "$d/failed"
run
refused "failed blockie-adbd refused" "blockie-adbd.service failed"

setup nm
: > "$d/active"
run
refused "inactive NetworkManager refused" "NetworkManager.service is not active"

setup dl1-exit1
echo 1 > "$d/exit.blockie-dl1.service"
run
refused "dl1 exit 1 refused" "blockie-dl1.service exited 1"

setup glob
sed -i 's/pick=default/pick=d*/' "$d/cmdline"
mkdir -p "$d/cwd"
: > "$d/cwd/blockie.pick=default"
cd "$d/cwd" || exit 1
run
cd / || exit 1
refused "a glob in a cmdline word is not expanded" "pick is 'd\*'"

init_default() {
  (. "$lib"; ostree_list "$s" | LC_ALL=C sort -n -r -k 1,1 | head -n 1 | cut -d' ' -f2)
}

setup tie
sed -i 's/^version .*/version 1/' "$s"/boot/loader/entries/*.conf
sed -i 's/pick=default/pick=runconf/' "$d/cmdline"
run
[[ $rc == 0 && ! -e $d/state/confirmed && $(init_default) == "$B" ]] \
  && grep -qx "blockie-boot-ok: runconf boot of $A, the default entry is $B: nothing written" "$d/out"
res $? "version tie: the default is init's pick (the higher id), a runconf boot of the other writes nothing"

setup tokens
printf 'title Blockie\nversion 2\noptions root=UUID=x ostree=/ostree/boot.1/default/111/0\tostree=/ostree/boot.1/default/222/0\noptions ostree=/ostree/boot.1/default/111/0\n' \
  > "$s/boot/loader/entries/ostree-1-default.conf"
rm -f "$s/boot/loader/entries/ostree-2-default.conf"
run
refused "two ostree= tokens: the last one counts, so $A has no entry" "no boot entry names"
sed -i "s/blockie.deploy=$A/blockie.deploy=$B/; s/pick=default/pick=runconf/" "$d/cmdline"
root=$dep/$B
run
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$B" && $(init_default) == "$B" ]]
res $? "two ostree= tokens: the runconf boot of the last one's deployment is the default and confirms"

setup nested
mkdir -p "$dep/x/$B"
rm -f "$s/ostree/boot.1/default/222/0"
ln -s "../../../deploy/default/deploy/x/$B" "$s/ostree/boot.1/default/222/0"
sed -i 's/^version .*/version 5/' "$s/boot/loader/entries/ostree-2-default.conf"
sed -i 's/pick=default/pick=runconf/' "$d/cmdline"
run
[[ $rc == 0 && ! -e $d/state/confirmed && $(init_default) == "$B" ]] \
  && grep -qx "blockie-boot-ok: runconf boot of $A, the default entry is $B: nothing written" "$d/out"
res $? "an entry two levels under deploy/ counts as init counts it"

setup list-fails
printf 'ostree_list() {\n    printf "%%s %%s %%s\\n" 1 %s x\n    return 1\n}\n' "$A" > "$d/lib"
lib_real=$lib
lib=$d/lib
run
lib=$lib_real
refused "ostree_list printing one entry then failing: refused, nothing written" "ostree_list failed (rc 1)"

setup no-conf
rm -f "$d/conf"
run
refused "missing boot-ok.conf refused" "missing"

tries0=$(printf '%s 1\n%s 2\n%s 1\nnot a line' "$A" "$B" "$C")
product() {
  setup "$1"
  : > "$d/product"
  echo "emulation blockie-frontend.service $I" > "$d/ready"
  printf 'InvocationID=%s\nActiveState=active\n' "$I" > "$d/user.show"
  printf '%s\n' state=pending "arm=${2:-default}" android=bootable return=host recovery=no fastboot=no > "$d/gates"
}

product prod-ok
run
[[ $rc == 0 && ! -e $d/state/confirmed && $(cat "$d/state/tries") == "$tries0" && ! -s $d/calls ]] &&
  grep -qx "blockie-boot-ok: checks passed, on a default armed product boot blockie-boot-healthy confirms $A" "$d/out"
res $? "default armed product boot (b 13): boot-ok runs the checks and writes nothing, the confirm waits for healthy"

ok=0
for w in test other none; do
  product "prod-$w" "$w"
  [[ $w != none ]] || rm -f "$d/gates"
  run
  [[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/state/tries") == "$B 2" && ! -s $d/calls ]] &&
    grep -qx "blockie-boot-ok: confirmed $A (default)" "$d/out" || { ok=1; echo "  ok $w: rc $rc"; }
  : > "$d/calls"
  run healthy
  [[ $rc == 0 && ! -s $d/calls && $(cat "$d/state/confirmed") == "$A" ]] && grep -q 'nothing to do' "$d/out" ||
    { ok=1; echo "  healthy $w: rc $rc"; }
done
res $ok "a product boot on a test arm (b 14), another arm or no gate file: boot-ok confirms as before, healthy exits 0 at once"

product prod-ok-fail
: > "$d/active"
run
refused "product boot: a failed check still fails boot-ok" "NetworkManager.service is not active"

product healthy
run healthy
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/state/tries") == "$B 2" ]] &&
  [[ $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] &&
  [[ $(cat "$d/shows") == "--user show -p InvocationID,ActiveState blockie-frontend.service" ]] &&
  [[ $(cat "$d/setpriv") == "--reuid=0 --regid=0 --init-groups --no-new-privs env -i PATH="*" XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus timeout 5 systemctl --user show -p InvocationID,ActiveState blockie-frontend.service" ]] &&
  grep -qx "blockie-boot-ok: ready: emulation blockie-frontend.service $I" "$d/out"
res $? "healthy with the ready report written before multi-user: the session user's manager says the unit is active on the reported invocation, confirmed first, then blockie-bootctl healthy"

product healthy-late
echo "emulation blockie-frontend.service" > "$d/ready"
( sleep 1.5; echo "emulation blockie-frontend.service $I" > "$d/ready" ) &
t0=${EPOCHREALTIME//[!0-9]/}
run healthy
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
wait
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] && ((ms >= 1000))
res $? "healthy waits for a ready report that comes after it started, a report without an invocation id does not count ($ms ms)"

product healthy-long
rm -f "$d/ready"
( sleep 2.5; echo "emulation blockie-frontend.service $I" > "$d/ready" ) &
t0=${EPOCHREALTIME//[!0-9]/}
HW=1 run healthy
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
wait
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] && ((ms >= 2000)) &&
  [[ $(grep -c "not confirmed after 1 s, still waiting for a ready report from the default session" "$d/out") == 1 ]] &&
  ! grep -q 'No such file' "$d/out"
res $? "healthy has no deadline: one line at BLOCKIE_HEALTHY_WAIT, no error per pass for the missing file, then the confirm on a later report ($ms ms)"

product healthy-settle
t0=${EPOCHREALTIME//[!0-9]/}
HS=2 run healthy
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] && ((ms >= 2000))
res $? "healthy confirms only after the settle ($ms ms, 2 s here, 30 s by default)"

ok=0
for st in "activating $I" "active $J"; do
  product "healthy-stale-${st%% *}"
  printf 'InvocationID=%s\nActiveState=%s\n' "${st#* }" "${st%% *}" > "$d/user.show"
  ( sleep 2.5; printf 'InvocationID=%s\nActiveState=active\n' "$J" > "$d/user.show"
    echo "emulation blockie-frontend.service $J" > "$d/ready" ) &
  t0=${EPOCHREALTIME//[!0-9]/}
  HS=1 run healthy
  ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
  wait
  [[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] && ((ms >= 2500)) &&
    [[ $(grep -c "blockie-frontend.service is not active on invocation $I after 1 s, waiting for a fresh ready report" "$d/out") == 1 ]] &&
    grep -qx "blockie-boot-ok: ready: emulation blockie-frontend.service $J" "$d/out" || { ok=1; echo "  ${st%% *}: rc $rc, $ms ms"; }
done
res $ok "a stale report (the unit restarting, or active on another invocation) is never confirmed: healthy waits for a fresh report and confirms that one"

product healthy-unread
rm -f "$d/user.show"
( sleep 1.5; printf 'InvocationID=%s\nActiveState=active\n' "$I" > "$d/user.show" ) &
t0=${EPOCHREALTIME//[!0-9]/}
run healthy
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
wait
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && $(cat "$d/calls") == "bootctl healthy confirmed=$A" ]] && ((ms >= 1500)) &&
  [[ $(grep -c "cannot read blockie-frontend.service from the user manager, retrying" "$d/out") == 1 ]] &&
  ! grep -q 'not active on invocation' "$d/out"
res $? "a user manager query with no answer does not make the report stale: healthy retries and confirms the same report once it answers ($ms ms)"

setup healthy-dev
echo "emulation blockie-frontend.service" > "$d/ready"
run healthy
[[ $rc == 1 && ! -e $d/state/confirmed && ! -s $d/calls ]] && grep -q "only on a product boot" "$d/out"
res $? "healthy on a boot that is not a product boot: refused, nothing written"

product healthy-check
echo blockie-adbd.service > "$d/failed"
run healthy
[[ $rc == 1 && ! -e $d/state/confirmed && ! -s $d/calls ]] && grep -q "blockie-adbd.service failed" "$d/out"
res $? "healthy re-runs the unit checks: a failed blockie-adbd refuses, no re-arm"

product healthy-fallback
sed -i 's/pick=default/pick=fallback/' "$d/cmdline"
run healthy
[[ $rc == 0 && $(cat "$d/state/confirmed") == "$A" && ! -s $d/state/tries ]] &&
  [[ $(cat "$d/calls") == "bootc rollback"$'\n'"bootctl healthy confirmed=$A" ]]
res $? "healthy on a fallback pick: confirmed, bootc rollback, then blockie-bootctl healthy"

product healthy-fallback-fails
sed -i 's/pick=default/pick=fallback/' "$d/cmdline"
echo 1 > "$d/bootc.rc"
run healthy
[[ $rc == 1 && $(cat "$d/calls") == "bootc rollback" ]]
res $? "healthy with a failed bootc rollback: no re-arm"

product healthy-runconf
sed -i "s/pick=default/pick=runconf/; s/blockie.deploy=$A/blockie.deploy=$B/" "$d/cmdline"
root=$dep/$B
run healthy
[[ $rc == 0 && ! -e $d/state/confirmed && $(cat "$d/calls") == "bootctl healthy confirmed=" ]]
res $? "healthy on a runconf boot of an older entry: nothing confirmed, slot a still re-armed"

product healthy-bootctl
echo 1 > "$d/bootctl.rc"
run healthy
[[ $rc == 1 && $(cat "$d/state/confirmed") == "$A" ]]
res $? "a failed blockie-bootctl healthy fails the healthy unit after the confirm"

product usage
run other
[[ $rc == 2 && ! -e $d/state/confirmed && ! -s $d/calls ]]
res $? "boot-ok takes no argument or healthy"

hu=/usr/lib/systemd/system/blockie-boot-healthy.service
if [[ -f $hu ]]; then
  grep -qx 'After=multi-user.target blockie-boot-ok.service' "$hu" && grep -qx 'ConditionPathExists=/run/blockie/product' "$hu" &&
    grep -qx 'ExecStart=/usr/libexec/blockie/blockie-boot-ok healthy' "$hu" && grep -qx 'TimeoutStartSec=infinity' "$hu" &&
    [[ -L /etc/systemd/system/multi-user.target.wants/blockie-boot-healthy.service ]]
  res $? "blockie-boot-healthy.service runs boot-ok healthy after multi-user.target on product boots with no start timeout, enabled"
fi

if [[ $fails == 0 ]]; then
  echo "boot-ok: all ok"
  exit 0
fi
echo "boot-ok: $fails failed"
exit 1
