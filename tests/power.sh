#!/usr/bin/env bash
set -u

[[ -e /run/.containerenv ]] || { echo "power: runs only in a container, so blockie-sleep can never reach the host's /sys/power" >&2; exit 2; }
hooks=/usr/lib/blockie/hooks.d
off=/usr/libexec/blockie/blockie-poweroff
sl=/usr/libexec/blockie/blockie-sleep
t=$(mktemp -d "${TMPDIR:-/tmp}/power.XXXXXX")
fails=0
trap 'exec 4>&-; rm -rf "${t:?}"' EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

s=$t/state
led=$t/sys/class/leds/lcd-backlight
mkdir -p "$t/bin" "$t/run" "$s" "$led"
cat > "$t/bin/wlopm" << EOF
#!/bin/sh
echo "wlopm \$*" >> "$t/log"
[ ! -f "$s/wlopm.hang" ] || exec sleep 30
exit \$(cat "$s/wlopm.rc" 2> /dev/null || echo 0)
EOF
cat > "$t/bin/systemctl" << EOF
#!/bin/sh
n=\$(cat "$s/active" 2> /dev/null || echo 0)
case "\$*" in
  '--user show -P ActiveState blockie-game.scope')
    if [ "\$n" = 0 ]; then echo inactive; else echo active; fi
    ;;
  '--user is-active --quiet blockie-game.scope')
    [ "\$n" = 0 ] && exit 3
    [ "\$n" -lt 0 ] || echo \$((n - 1)) > "$s/active"
    ;;
  '--user kill --signal=SIGSTOP blockie-game.scope' | '--user kill --signal=SIGCONT blockie-game.scope')
    echo "systemctl \$*" >> "$t/log"
    echo "\${3#--signal=}" >> "$s/calls"
    [ "\$3" != --signal=SIGCONT ] || date +%s%6N > "$s/cont.us"
    if [ "\$n" = 0 ]; then
      echo "Failed to kill unit blockie-game.scope: Unit blockie-game.scope not loaded." >&2
      exit 1
    fi
    rc=\$(cat "$s/kill.rc" 2> /dev/null || echo 0)
    [ "\$rc" != 0 ] || { [ "\$3" = --signal=SIGSTOP ] && : > "$s/stopped" || rm -f "$s/stopped"; }
    exit "\$rc"
    ;;
  'start --no-block blockie-android-freeze@freeze.service')
    echo "systemctl \$*" >> "$t/log"
    exit \$(cat "$s/freeze.rc" 2> /dev/null || echo 0)
    ;;
  is-system-running) cat "$s/sysrun" 2> /dev/null || echo running ;;
  '--user show -P ActiveState blockie-poweroff.service') cat "$s/po.state" 2> /dev/null || echo inactive ;;
  '--user show -P FreezerState blockie-emulation.slice') cat "$s/slice" 2> /dev/null || echo running ;;
  'start blockie-boot@'*)
    echo "systemctl \$*" >> "$t/log"
    exit \$(cat "$s/boot.rc" 2> /dev/null || echo 0)
    ;;
  '--user list-units --plain --no-legend --state=activating,active,deactivating,reloading blockie-reboot@*')
    cat "$s/rb.units" 2> /dev/null
    ;;
  *) echo "systemctl \$*" >> "$t/log" ;;
esac
EOF
cat > "$t/bin/busctl" << EOF
#!/bin/sh
case "\$*" in
  *' org.freedesktop.login1.Manager ListSessions')
    echo ListSessions >> "$s/calls"
    [ ! -f "$s/ls.fail" ] || exit 1
    [ ! -f "$s/ls.hang" ] || exec sleep 30
    if [ -f "$s/two" ]; then
      echo 'a(susso) 3 "8" $(id -u) "blockie" "seat0" "/org/freedesktop/login1/session/_38" "9" $(id -u) "blockie" "" "/org/freedesktop/login1/session/_39" "7" $(id -u) "blockie" "seat0" "/org/freedesktop/login1/session/_37"'
    else
      echo 'a(susso) 4 "c1" 0 "root" "" "/org/freedesktop/login1/session/c1" "5" $(($(id -u) + 1)) "other" "seat0" "/org/freedesktop/login1/session/_35" "9" $(id -u) "blockie" "" "/org/freedesktop/login1/session/_39" "7" $(id -u) "blockie" "seat0" "/org/freedesktop/login1/session/_37"'
    fi
    ;;
  'get-property org.freedesktop.login1 '*' org.freedesktop.login1.Session Active')
    echo "get-property \$3" >> "$s/calls"
    [ ! -f "$s/gp.hang" ] || exec sleep 30
    if [ -f "$s/act\${3##*/}" ]; then echo 'b true'; else echo 'b false'; fi
    ;;
  *' SetBrightness ssu leds lcd-backlight '*)
    echo "busctl \$*" >> "$t/log"
    for v; do :; done
    echo "SetBrightness \$3 \$v" >> "$s/calls"
    if grep -qxF -- "\$3" "$s/gone" 2> /dev/null; then
      echo "Call failed: Unknown object '\$3'." >&2
      exit 1
    fi
    [ ! -f "$s/sb.fail" ] || exit 1
    [ ! -f "$s/sb.hang" ] || exec sleep 30
    echo "\$v" > "$led/brightness"
    ;;
  'get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager BlockInhibited')
    echo "s \"\$(cat "$s/inhibit" 2> /dev/null)\""
    ;;
  *)
    echo "busctl \$*" >> "$t/log"
    echo "\$5" >> "$s/calls"
    ;;
esac
EOF
printf '#!/bin/sh\necho sync >> "%s"\n' "$t/log" > "$t/bin/sync"
chmod 755 "$t/bin/wlopm" "$t/bin/systemctl" "$t/bin/busctl" "$t/bin/sync"

state() {
  rm -f "${s:?}"/* "$t/log"
  echo "$1" > "$s/active"
  [[ $2 != stopped ]] || : > "$s/stopped"
  echo 102 > "$led/brightness"
  echo 255 > "$led/max_brightness"
  rm -f "$t/run/blockie-backlight" "$t/run/blockie-backlight.session"
}
run() {
  local t0=${EPOCHREALTIME//[!0-9]/}
  BLOCKIE_SYSFS=$t/sys BLOCKIE_SLEEP_KNOB=$t/knob XDG_RUNTIME_DIR=$t/run BLOCKIE_BOOT_GATES=$s/gates PATH=$t/bin:$PATH \
    timeout -k 2 20 "$@" > "$t/out" 2> "$t/err"
  rc=$?
  ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
  touch "$t/log"
}
logis() { [[ $(< "$t/log") == "$1" ]]; }
stopped() { [[ -e $s/stopped ]]; }
stop_line='systemctl --user kill --signal=SIGSTOP blockie-game.scope'
cont_line='systemctl --user kill --signal=SIGCONT blockie-game.scope'
bl() { printf 'busctl call org.freedesktop.login1 /org/freedesktop/login1/session/%s org.freedesktop.login1.Session SetBrightness ssu leds lcd-backlight %s' "${2:-_37}" "$1"; }
bl0=$(bl 0)
sp=/org/freedesktop/login1/session
cache=$t/run/blockie-backlight.session
bl102=$(bl 102)
off_line='busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PowerOff b false'

ok=0
for h in blank-on blank-off screen-on menu-on; do
  [[ -x $hooks/$h && $(head -n 1 "$hooks/$h") == '#!/bin/sh' ]] && sh -n "$hooks/$h" || { ok=1; echo "  $h"; }
done
for f in "$off" "$sl"; do
  [[ -x $f && $(head -n 1 "$f") == '#!/bin/sh' ]] && sh -n "$f" || { ok=1; echo "  $f"; }
done
res $ok "the display hooks, blockie-poweroff and blockie-sleep are executable sh scripts"

state 1 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$bl0" && stopped
r1=$?
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$bl0"$'\n'"$stop_line"$'\nwlopm --off *\n'"$bl0" && stopped
res $((r1 || $?)) "blank-on sends SIGSTOP to an active game scope before wlopm --off, again on a second blank-on"

rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line" && ! stopped
r1=$?
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line"
res $((r1 || $?)) "blank-off runs wlopm --on before SIGCONT, and sends SIGCONT again on a second blank-off"

ok=0
state 0 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis $'wlopm --off *\n'"$bl0" || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 && ! -s $t/err ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line" || ok=1
res $ok "no game scope: blank-on sends no signal, blank-off still sends SIGCONT, its failure is not an error, exit 0"

ok=0
state 1 running
echo 1 > "$s/wlopm.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$bl0" && stopped || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line" && ! stopped || ok=1
state 1 running
echo 1 > "$s/kill.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$bl0" || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line" || ok=1
res $ok "a failing wlopm, or a failing signal to an active scope, exits 1 and the other step still runs"

state 1 stopped
run "$hooks/screen-on"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$bl102" && stopped
res $? "screen-on turns the output on and leaves the game stopped"

rd=$t/rundir
mkdir -p "$rd"
freeze_line='systemctl start --no-block blockie-android-freeze@freeze.service'
menu_on() { run env BLOCKIE_RUNDIR="$rd" "$hooks/menu-on"; }
ok=0
printf 'emulation blockie-emulation.service 3\n' > "$rd/session-current"
state 1 running
menu_on
[[ $rc == 0 ]] && logis "$stop_line"$'\nwlopm --on *\n'"$bl102" && stopped || { ok=1; echo "  game: rc $rc $(tr '\n' '|' < "$t/log")"; }
state 0 running
menu_on
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$bl102" && ! grep -q SIGSTOP "$t/log" || { ok=1; echo "  no game: rc $rc $(tr '\n' '|' < "$t/log")"; }
printf 'android blockie-android.service 7\n' > "$rd/session-current"
state 1 running
menu_on
[[ $rc == 0 ]] && logis "$stop_line"$'\n'"$freeze_line"$'\nwlopm --on *\n'"$bl102" && stopped ||
  { ok=1; echo "  android: rc $rc $(tr '\n' '|' < "$t/log")"; }
res $ok "menu-on SIGSTOPs only an active game scope, freezes Android only with android current, then lights the panel"

ok=0
printf 'emulation blockie-emulation.service 3\n' > "$rd/session-current"
state 1 running
echo 1 > "$s/wlopm.rc"
: > "$s/sb.fail"
menu_on
[[ $rc == 0 ]] && stopped || { ok=1; echo "  wlopm and backlight fail: rc $rc"; }
state 1 running
: > "$s/wlopm.hang"
menu_on
[[ $rc == 0 ]] && ((ms >= 2000 && ms < 5000)) || { ok=1; echo "  wlopm hangs: rc $rc $ms ms"; }
state 1 running
echo 1 > "$s/kill.rc"
menu_on
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --on *\n'"$bl102" || { ok=1; echo "  SIGSTOP fails: rc $rc"; }
printf 'android blockie-android.service 7\n' > "$rd/session-current"
state 0 running
echo 1 > "$s/freeze.rc"
menu_on
[[ $rc == 1 ]] && logis "$freeze_line"$'\nwlopm --on *\n'"$bl102" || { ok=1; echo "  freeze fails: rc $rc $(tr '\n' '|' < "$t/log")"; }
res $ok "menu-on exits 0 when wlopm or the backlight fail or wlopm hangs (cut at 2 s), 1 when the SIGSTOP or the Android freeze fail"

ok=0
state 1 running
: > "$s/wlopm.hang"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$bl0" && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-on: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$bl102"$'\n'"$cont_line" && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-off: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/screen-on"
[[ $rc != 0 ]] && logis $'wlopm --on *\n'"$bl102" && ((ms >= 2000 && ms < 5000)) || { ok=1; echo "  screen-on: rc $rc $ms ms"; }
res $ok "a hanging wlopm is cut at 2 s: each hook exits nonzero inside the 5 s hook limit, SIGSTOP and SIGCONT still go out"

ok=0
state 0 running
run "$hooks/blank-on"
[[ $rc == 0 && $(< "$t/run/blockie-backlight") == 102 && $(< "$led/brightness") == 0 ]] || ok=1
run "$hooks/blank-on"
[[ $rc == 0 && $(< "$t/run/blockie-backlight") == 102 && $(< "$led/brightness") == 0 ]] || ok=1
run "$hooks/blank-off"
[[ $rc == 0 && ! -e $t/run/blockie-backlight && $(< "$led/brightness") == 102 ]] || ok=1
res $ok "blank-on saves a nonzero brightness and sets 0, a second blank-on keeps the saved value, blank-off restores it"

ok=0
for c in 0:200:80 0:-:102 77:255:77; do
  IFS=: read -r b m want <<< "$c"
  state 0 running
  echo "$b" > "$led/brightness"
  [[ $m != - ]] || rm -f "$led/max_brightness"
  [[ $m == - ]] || echo "$m" > "$led/max_brightness"
  run "$hooks/blank-off"
  [[ $rc == 0 && $(< "$led/brightness") == "$want" ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$(bl "$want")" ||
    { ok=1; echo "  brightness $b max $m: rc $rc, now $(< "$led/brightness")"; }
done
res $ok "a wake with no saved value keeps a nonzero brightness, else sets 40 % of max_brightness, else 102, never 0"

ok=0
state 1 running
: > "$s/sb.fail"
run "$hooks/blank-on"
[[ $rc == 1 ]] && grep -q 'SetBrightness 0 on /org/freedesktop/login1/session/_37 failed' "$t/err" || { ok=1; echo "  blank-on rc $rc"; }
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 && -e $t/run/blockie-backlight ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102" && ! stopped &&
  grep -q 'SetBrightness 102 on' "$t/err" || { ok=1; echo "  blank-off rc $rc"; }
run "$hooks/screen-on"
[[ $rc == 0 ]] || { ok=1; echo "  screen-on rc $rc"; }
rm -f "$s/sb.fail"
: > "$s/ls.fail"
run "$hooks/blank-off"
[[ $rc == 0 ]] && grep -q 'no seat0 session of uid' "$t/err" || { ok=1; echo "  no session: rc $rc"; }
rm -f "$s/ls.fail" "$t/log"
: > "$s/ls.hang"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$cont_line" && ((ms >= 1000 && ms < 2500)) || { ok=1; echo "  hang: rc $rc $ms ms"; }
res $ok "a failing or hanging busctl: blank-on exits 1, every wake still exits 0 with SIGCONT sent, the failure logged, the saved value kept"

ok=0
state 0 running
: > "$s/two"
: > "$s/act_37"
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis $'wlopm --off *\n'"$(bl 0 _37)" || { ok=1; echo "  second active: rc $rc"; }
rm -f "$s/act_37" "$t/log" "$cache"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$(bl 102 _38)" || { ok=1; echo "  none active: rc $rc"; }
: > "$s/act_38"
: > "$s/act_37"
rm -f "$t/log" "$cache"
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis $'wlopm --off *\n'"$(bl 0 _38)" || { ok=1; echo "  both active: rc $rc"; }
: > "$s/gp.hang"
rm -f "$t/log" "$cache"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$(bl 102 _38)" && ((ms >= 1000 && ms < 2500)) ||
  { ok=1; echo "  Active hangs: rc $rc $ms ms"; }
res $ok "two seat0 sessions of the uid: the first active one gets SetBrightness, none active or Active hanging past the 1 s lookup gives the first row"

ok=0
state 0 running
run "$hooks/blank-on"
[[ $(< "$cache") == "$sp/_37" && $(< "$s/calls") == "ListSessions"$'\n'"SetBrightness $sp/_37 0" ]] || { ok=1; echo "  off: $(tr '\n' ' ' < "$s/calls")"; }
echo "$sp/_34" > "$cache"
rm -f "$s/calls"
run "$hooks/blank-off"
[[ $rc == 0 && $(< "$s/calls") == "SetBrightness $sp/_34 102"$'\n'SIGCONT && $(< "$led/brightness") == 102 ]] ||
  { ok=1; echo "  on: $(tr '\n' ' ' < "$s/calls")"; }
rm -f "$s/calls"
run "$hooks/blank-on"
[[ $rc == 0 && $(< "$s/calls") == "SetBrightness $sp/_34 0" ]] || { ok=1; echo "  cached off: $(tr '\n' ' ' < "$s/calls")"; }
res $ok "the session path is cached at off; a cached wake is one SetBrightness on it, then SIGCONT, and a cached off one SetBrightness, with no ListSessions"

ok=0
state 0 running
echo 0 > "$led/brightness"
echo 102 > "$t/run/blockie-backlight"
echo "$sp/_36" > "$cache"
echo "$sp/_36" > "$s/gone"
run "$hooks/blank-off"
[[ $rc == 0 && $(< "$s/calls") == "SetBrightness $sp/_36 102"$'\n'SIGCONT$'\n'"ListSessions"$'\n'"SetBrightness $sp/_37 102" ]] &&
  [[ $(< "$cache") == "$sp/_37" && $(< "$led/brightness") == 102 && ! -s $t/err ]] || { ok=1; echo "  stale: $(tr '\n' ' ' < "$s/calls")"; }
state 0 running
echo 0 > "$led/brightness"
run "$hooks/blank-off"
[[ $rc == 0 && $(< "$s/calls") == SIGCONT$'\n'"ListSessions"$'\n'"SetBrightness $sp/_37 102" && $(< "$cache") == "$sp/_37" ]] ||
  { ok=1; echo "  no cache: $(tr '\n' ' ' < "$s/calls")"; }
state 0 running
echo "$sp/_37" > "$cache"
: > "$s/sb.hang"
run "$hooks/blank-off"
[[ $rc == 0 && $(< "$s/calls") == "SetBrightness $sp/_37 102"$'\n'SIGCONT ]] && grep -q 'timed out' "$t/err" && ((ms >= 1000 && ms < 1800)) ||
  { ok=1; echo "  hung logind: rc $rc $ms ms $(tr '\n' ' ' < "$s/calls")"; }
res $ok "SIGCONT never waits on the lookup: stale cache is cached call, SIGCONT, lookup and cache rewrite; no cache is SIGCONT, lookup; a timed out cached call (logind hung) is SIGCONT and no lookup"

ok=0
for h in blank-on blank-off; do
  state 0 running
  for f in wlopm.hang two gp.hang sb.hang; do
    : > "$s/$f"
  done
  echo "$sp/_36" > "$cache"
  echo "$sp/_36" > "$s/gone"
  s0=${EPOCHREALTIME//[!0-9]/}
  run "$hooks/$h"
  ((rc == 1 && ms >= 4000 && ms < 4800)) && grep -q 'SetBrightness [0-9]* on /org/freedesktop/login1/session/_38 failed' "$t/err" ||
    { ok=1; echo "  $h: rc $rc $ms ms"; }
  if [[ $h == blank-off ]]; then
    c=$((($(< "$s/cont.us") - s0) / 1000))
    ((c >= 1900 && c < 2600)) || { ok=1; echo "  $h: SIGCONT $c ms after the start"; }
  fi
done
res $ok "the worst case stays inside 4 s plus a little and hotkeyd's 5 s hook limit (wlopm 2 s, a stale cached call, lookup 1 s, SetBrightness 1 s), and blank-off sends SIGCONT about 2.1 s in, before the lookup"

ok=0
for f in "$hooks/blank-on" "$hooks/blank-off" "$hooks/screen-on" "$off" /usr/libexec/blockie/blockie-backlight; do
  ! grep -q 'login1/session/' "$f" || { ok=1; echo "  $f names a session object"; }
done
[[ -x /usr/libexec/blockie/blockie-backlight ]] || ok=1
res $ok "the session object comes from ListSessions at run time (the uid's seat0 session _37 above, past another uid's seat0 session and the uid's seatless one), no script names one"

mkfifo -m 600 "$t/run/blockie-game.cmd"
exec 4<> "$t/run/blockie-game.cmd"
po=blockie-poweroff
dark() { state "$@"; echo 0 > "$led/brightness"; }
dark 0 running
run "$off"
line=
read -r -t 0.5 line <&4
[[ $rc == 0 && -z $line && $(< "$t/err") == "$po: sync done" ]] &&
  logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\n'"$off_line" && ((ms < 5000))
res $? "blockie-poweroff with no game on a dark screen: wlopm --on, SIGCONT (its failure not logged), no QUIT, sync, then PowerOff at once ($ms ms)"

ok=0
for c in 1:0:5000 11:2000:5000 -1:5000:15000; do
  IFS=: read -r n lo hi <<< "$c"
  dark "$n" stopped
  run "$off"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\n'"$off_line" &&
    ((ms >= lo && ms < hi)) || { ok=1; echo "  active $n: rc $rc line '$line' $ms ms"; }
  stopped && { ok=1; echo "  active $n: still stopped"; }
  if [[ $n == -1 ]]; then
    want="$po: QUIT sent"$'\n'"$po: blockie-game.scope still active after 5 s, powering off anyway"$'\n'"$po: sync done"
  else
    want="$po: QUIT sent"$'\n'"$po: blockie-game.scope inactive"$'\n'"$po: sync done"
  fi
  [[ $(< "$t/err") == "$want" ]] || { ok=1; echo "  active $n: stderr $(tr '\n' '|' < "$t/err")"; }
done
res $ok "blockie-poweroff on a dark screen: wlopm --on, SIGCONT, QUIT, sync, then PowerOff when the scope ends at once, after 2 s or never (5 s), inside 15 s, each step on stderr"

ok=0
for n in 2 -1; do
  state "$n" stopped
  run "$off"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] && logis "$cont_line"$'\nsync\n'"$off_line" && ! stopped || { ok=1; echo "  lit, active $n: rc $rc line '$line'"; }
  grep -q ListSessions "$s/calls" 2> /dev/null && { ok=1; echo "  lit, active $n: backlight lookup"; }
  if [[ $n == 2 ]]; then
    [[ $(< "$t/err") == "$po: QUIT sent"$'\n'"$po: blockie-game.scope inactive"$'\n'"$po: sync done" ]] || ok=1
  else
    [[ $(sed -n 2p "$t/err") == *'still active after 5 s'* && $(sed -n 3p "$t/err") == "$po: sync done" ]] || ok=1
  fi
done
res $ok "blockie-poweroff on a lit screen skips wlopm and both backlight calls, still sends SIGCONT and QUIT, and syncs after the scope ends or the 5 s wait, before PowerOff"

dark 1 stopped
echo 1 > "$s/kill.rc"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\n'"$off_line" &&
  grep -q 'SIGCONT to blockie-game.scope failed' "$t/err"
res $? "blockie-poweroff: a failing SIGCONT to an active scope is logged, QUIT, sync and PowerOff still follow"

dark 1 stopped
echo frozen > "$s/slice"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] &&
  logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsystemctl --user thaw blockie-emulation.slice\nsync\n'"$off_line"
res $? "blockie-poweroff thaws a frozen blockie-emulation.slice before QUIT"

dark -1 stopped
: > "$s/wlopm.hang"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\n'"$off_line" &&
  grep -q 'wlopm --on failed' "$t/err" && ((ms >= 7000 && ms < 15000))
res $? "blockie-poweroff with a hanging wlopm and a game that never ends: PowerOff still called inside 15 s ($ms ms)"

open_gates() { printf '%s\n' state=default arm=default android=bootable return=host recovery=yes fastboot=yes > "$s/gates"; }
ok=0
for x in reboot android recovery fastboot; do
  dark 1 stopped
  open_gates
  run "$off" --reboot "$x"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] &&
    logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\n'"systemctl start blockie-boot@$x.service" || { ok=1; echo "  $x: rc $rc line '$line'"; }
done
res $ok "blockie-poweroff --reboot <t>: the power off sequence, then systemctl start blockie-boot@<t>.service in place of PowerOff"

dark 0 running
open_gates
echo 1 > "$s/boot.rc"
run "$off" --reboot android
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\nsync\nsystemctl start blockie-boot@android.service' &&
  grep -q 'start of blockie-boot@android.service failed (rc 1)' "$t/err"
r1=$?
dark 0 running
open_gates
echo 1 > "$s/boot.rc"
echo stopping > "$s/sysrun"
run "$off" --reboot android
[[ $rc == 0 ]] && grep -q 'exited 1 while the system stops' "$t/err"
res $((r1 || $?)) "blockie-poweroff --reboot: a failed blockie-boot@ start exits 1, or 0 while is-system-running prints stopping"

ok=0
for a in '--reboot' '--reboot test-b' '--reboot android x' '--now' '--reboot ../x'; do
  dark 1 stopped
  read -ra args <<< "$a"
  run "$off" "${args[@]}"
  line=
  read -r -t 0.3 line <&4
  [[ $rc == 2 && -z $line && ! -s $t/log ]] && stopped || { ok=1; echo "  '$a': rc $rc"; }
done
res $ok "blockie-poweroff takes only --reboot reboot, android, recovery or fastboot, and refuses anything else before any step"

ok=0
pay=$t/payload
mkdir -p "$pay"
gcase() {
  dark 1 stopped
  [[ $1 == - ]] || printf '%s\n' "${@:3}" > "$s/gates"
  line=
  BLOCKIE_ANDROID_PAYLOAD=$pay run "$off" --reboot "$2"
  read -r -t 0.3 line <&4
  [[ $rc == 1 && -z $line && ! -s $t/log ]] && stopped || { ok=1; echo "  $2 $1: rc $rc line '$line' $(tr '\n' '|' < "$t/log")"; }
}
gcase - android
grep -qx 'blockie-poweroff: android refused: no gate file' "$t/err" || { ok=1; echo "  no gate file: $(< "$t/err")"; }
gcase pending android state=pending arm=test android=unavailable 'reason=test arm' recovery=yes fastboot=no
grep -qx 'blockie-poweroff: android refused: state=pending (test arm)' "$t/err" || { ok=1; echo "  pending: $(< "$t/err")"; }
gcase noandroid android state=default arm=default android=unavailable 'reason=slot b unbootable' recovery=yes fastboot=no
grep -qx 'blockie-poweroff: android refused: android=unavailable (slot b unbootable)' "$t/err" || ok=1
gcase norecovery recovery state=default arm=default android=bootable recovery=no fastboot=no
grep -qx 'blockie-poweroff: recovery refused: recovery=no' "$t/err" || ok=1
gcase recpending recovery state=android arm=default android=bootable recovery=yes fastboot=yes
grep -qx 'blockie-poweroff: recovery refused: state=android' "$t/err" || ok=1
gcase nofastboot fastboot state=default arm=default android=bootable recovery=yes fastboot=no
grep -qx 'blockie-poweroff: fastboot refused: fastboot=no' "$t/err" || ok=1
dark 1 stopped
printf '%s\n' state=pending arm=other android=unavailable recovery=no fastboot=no > "$s/gates"
run "$off" --reboot reboot
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && grep -qx 'systemctl start blockie-boot@reboot.service' "$t/log" || { ok=1; echo "  reboot: rc $rc"; }
dark 1 stopped
rm -f "$s/gates"
run "$off" --reboot reboot
read -r -t 1 line <&4
[[ $rc == 0 ]] && grep -qx 'systemctl start blockie-boot@reboot.service' "$t/log" || { ok=1; echo "  reboot without gates: rc $rc"; }
res $ok "blockie-poweroff --reboot reads the gate file first: a closed target exits 1 with the reason, game stopped and Android untouched; reboot has no gate"
exec 4>&-

P=$t/sys/power
wr=$t/sys/kernel/wakeup_reasons
counters=(fail failed_freeze failed_prepare failed_suspend failed_suspend_late failed_suspend_noirq failed_resume
  failed_resume_early failed_resume_noirq)
bg=()
sfix() {
  state 0 running
  rm -rf "${t:?}/sys/power" "${t:?}/sys/kernel" "${t:?}/sys/class/wakeup"
  mkdir -p "$P/suspend_stats" "$wr" "$t/sys/class/wakeup/wakeup0" "$t/sys/class/wakeup/wakeup1"
  : > "$P/state"
  printf 7 > "$P/wakeup_count"
  for c in success "${counters[@]}"; do
    echo 0 > "$P/suspend_stats/$c"
  done
  echo suspend > "$P/suspend_stats/last_failed_step"
  echo -16 > "$P/suspend_stats/last_failed_errno"
  echo alarmtimer.3.auto > "$P/suspend_stats/last_failed_dev"
  printf '%s\n' "${1-333 mtk-pmic-keys}" > "$wr/last_resume_reason"
  echo '12.500000000 10.250000000' > "$wr/last_suspend_time"
  echo disp_crtc0_wakelock > "$t/sys/class/wakeup/wakeup0/name"
  echo 120 > "$t/sys/class/wakeup/wakeup0/active_time_ms"
  echo alarmtimer.3.auto > "$t/sys/class/wakeup/wakeup1/name"
  echo 0 > "$t/sys/class/wakeup/wakeup1/active_time_ms"
}
grow() {
  rm -f "$P/suspend_stats/$1"
  mkfifo "$P/suspend_stats/$1"
  { printf '0\n1\n'; exec sleep 30; } > "$P/suspend_stats/$1" &
  bg+=($!)
}
reap() {
  ((${#bg[@]})) || return 0
  kill "${bg[@]}" 2> /dev/null
  wait "${bg[@]}" 2> /dev/null
  bg=()
}
untouched() { [[ ! -s $P/state ]] && ! grep -qx sync "$t/log"; }

ok=0
sfix
run "$sl" first
[[ $rc == 0 && $(< "$t/out") == "slept power 10.250000000" && $(< "$P/state") == mem ]] &&
  cmp -s <(printf '7\n') "$P/wakeup_count" && grep -qx sync "$t/log" || { ok=1; echo "  first: $(< "$t/out")"; }
sfix
run "$sl"
[[ $(< "$t/out") == "slept power 10.250000000" && $(< "$P/state") == mem ]] && ! grep -qx sync "$t/log" ||
  { ok=1; echo "  again: $(< "$t/out")"; }
res $ok "blockie-sleep reads wakeup_count, writes the same count back, writes mem, syncs only on the first attempt"

ok=0
cases=("313 mt6397-rtc" rtc "194 type_c_port0" plug "142 wlan0" other "-1 Wakeup reason not found" other
  "Abort: Pending Wakeup Sources: alarmtimer.3.auto" other "" other $'313 mt6397-rtc\n333 mtk-pmic-keys' power
  $'194 type_c_port0\n313 mt6397-rtc' rtc)
for ((i = 0; i < ${#cases[@]}; i += 2)); do
  sfix "${cases[i]}"
  run "$sl"
  [[ $(< "$t/out") == "slept ${cases[i + 1]} 10.250000000" ]] || { ok=1; echo "  '${cases[i]}': $(< "$t/out")"; }
done
sfix
rm -f "$wr/last_resume_reason" "$wr/last_suspend_time"
run "$sl"
[[ $(< "$t/out") == "slept other" && ! -s $t/err ]] || { ok=1; echo "  no reason files: $(< "$t/out")"; }
res $ok "blockie-sleep names the wake by its irq name: power before rtc before plug, anything else other"

ok=0
sfix
rm -f "$P/wakeup_count"
mkfifo "$P/wakeup_count"
run "$sl" first
[[ $(< "$t/out") == "active disp_crtc0_wakelock" ]] && ((ms >= 3000 && ms < 6500)) && [[ ! -s $P/state ]] ||
  { ok=1; echo "  held: $(< "$t/out") $ms ms"; }
sfix
rm -f "$P/wakeup_count"
ln -s /dev/full "$P/wakeup_count"
run "$sl"
[[ $(< "$t/out") == events && ! -s $P/state ]] || { ok=1; echo "  events: $(< "$t/out")"; }
res $ok "a wakeup_count read held past 3 s gives active with the active sources, a rejected count write gives events, no mem write"

sfix
rm -f "$P/wakeup_count"
mkfifo "$P/wakeup_count"
: > "$t/knob"
run "$sl" first
rm -f "$t/knob"
[[ $(< "$t/out") == "slept power 10.250000000" && $(< "$P/state") == mem ]] && ((ms < 2500)) &&
  grep -qx "blockie-sleep: $t/knob set, wakeup_count skipped, active: disp_crtc0_wakelock" "$t/err"
res $? "with the test knob set the wakeup_count handshake is skipped (a held source no longer blocks), the active sources are logged and mem is written ($ms ms)"

ok=0
sfix
rm -f "$P/state"
ln -s /dev/full "$P/state"
grow fail
grow failed_suspend
run "$sl"
reap
[[ $(< "$t/out") == "busy step=suspend errno=-16 grew=fail,failed_suspend dev=alarmtimer.3.auto" ]] ||
  { ok=1; echo "  suspend: $(< "$t/out")"; }
sfix
rm -f "$P/state"
ln -s /dev/full "$P/state"
echo freeze > "$P/suspend_stats/last_failed_step"
grow fail
grow failed_freeze
run "$sl"
reap
[[ $(< "$t/out") == "busy step=freeze errno=-16 grew=fail,failed_freeze" ]] || { ok=1; echo "  freeze: $(< "$t/out")"; }
res $ok "a failed mem write gives busy with the step, errno and grown counters, the device only when a suspend callback failed"

ok=0
sfix
echo stopping > "$s/sysrun"
run "$sl" first
[[ $(< "$t/out") == "refused stopping" ]] && untouched || { ok=1; echo "  stopping: $(< "$t/out")"; }
sfix
bash -c 'exec -a @blk-deadman sleep 30' &
dp=$!
for _ in $(seq 100); do
  pgrep -f '^@blk-deadman( |$)' > /dev/null && break
  sleep 0.05
done
run "$sl" first
kill "$dp"
wait "$dp" 2> /dev/null
[[ $(< "$t/out") == "refused deadman" ]] && untouched || { ok=1; echo "  deadman: $(< "$t/out")"; }
sfix
echo activating > "$s/po.state"
run "$sl" first
[[ $(< "$t/out") == "refused poweroff" ]] && untouched || { ok=1; echo "  poweroff: $(< "$t/out")"; }
sfix
echo 'blockie-reboot@android.service loaded activating start Quit the game and reboot to android' > "$s/rb.units"
run "$sl" first
[[ $(< "$t/out") == "refused reboot" ]] && untouched || { ok=1; echo "  reboot: $(< "$t/out")"; }
sfix
echo handle-power-key:sleep > "$s/inhibit"
run "$sl" first
[[ $(< "$t/out") == "refused inhibited" ]] && untouched || { ok=1; echo "  inhibited: $(< "$t/out")"; }
sfix
echo shutdown > "$s/inhibit"
run "$sl"
[[ $(< "$t/out") == "slept power 10.250000000" ]] || { ok=1; echo "  shutdown inhibitor: $(< "$t/out")"; }
res $ok "blockie-sleep refuses while stopping, under the deadman, during blockie-poweroff or a blockie-reboot@ unit and under a sleep block inhibitor, with no sync and no mem write"

sfix
rm -f "$P/wakeup_count"
mkfifo "$P/wakeup_count"
t0=${EPOCHREALTIME//[!0-9]/}
BLOCKIE_SYSFS=$t/sys BLOCKIE_SLEEP_KNOB=$t/knob XDG_RUNTIME_DIR=$t/run PATH=$t/bin:$PATH timeout -k 10 20 "$sl" first > "$t/out" 2> "$t/err" &
hp=$!
sleep 0.5
kill -TERM "$hp"
wait "$hp"
rc=$?
ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
[[ $rc == 0 && $(< "$t/out") == "refused cancelled" && ! -s $P/state ]] && ((ms < 6500))
res $? "a SIGTERM before the mem write gives refused cancelled and no mem write ($ms ms)"

if (( fails )); then
  echo "power: $fails failed"
  exit 1
fi
echo "power: ok"
