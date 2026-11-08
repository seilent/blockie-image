#!/usr/bin/env bash
set -u

hooks=/usr/lib/blockie/hooks.d
off=/usr/libexec/blockie/blockie-poweroff
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
  *)
    echo "busctl \$*" >> "$t/log"
    echo "\$5" >> "$s/calls"
    ;;
esac
EOF
chmod 755 "$t/bin/wlopm" "$t/bin/systemctl" "$t/bin/busctl"

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
  BLOCKIE_SYSFS=$t/sys XDG_RUNTIME_DIR=$t/run PATH=$t/bin:$PATH timeout 20 "$@" > "$t/out" 2> "$t/err"
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
for h in blank-on blank-off screen-on; do
  [[ -x $hooks/$h && $(head -n 1 "$hooks/$h") == '#!/bin/sh' ]] && sh -n "$hooks/$h" || { ok=1; echo "  $h"; }
done
[[ -x $off && $(head -n 1 "$off") == '#!/bin/sh' ]] && sh -n "$off" || { ok=1; echo "  $off"; }
res $ok "the display hooks and blockie-poweroff are executable sh scripts"

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
state 0 running
run "$off"
line=
read -r -t 0.5 line <&4
[[ $rc == 0 && -z $line && ! -s $t/err ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\n'"$off_line" && ((ms < 5000))
res $? "blockie-poweroff with no game: wlopm --on, SIGCONT (its failure not logged), no QUIT, then PowerOff at once ($ms ms)"

ok=0
for c in 1:0:5000 11:2000:5000 -1:5000:15000; do
  IFS=: read -r n lo hi <<< "$c"
  state "$n" stopped
  run "$off"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\n'"$off_line" &&
    ((ms >= lo && ms < hi)) || { ok=1; echo "  active $n: rc $rc line '$line' $ms ms"; }
  stopped && { ok=1; echo "  active $n: still stopped"; }
  if [[ $n == -1 ]]; then
    grep -q 'still active after 5 s, powering off anyway' "$t/err" || { ok=1; echo "  active $n: no log line"; }
  fi
done
res $ok "blockie-poweroff: wlopm --on, SIGCONT, QUIT, then PowerOff when the scope ends at once, after 2 s or never (5 s), inside 15 s"

state 1 stopped
echo 1 > "$s/kill.rc"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\n'"$off_line" &&
  grep -q 'SIGCONT to blockie-game.scope failed' "$t/err"
res $? "blockie-poweroff: a failing SIGCONT to an active scope is logged, QUIT and PowerOff still follow"

state -1 stopped
: > "$s/wlopm.hang"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$bl102"$'\n'"$off_line" &&
  grep -q 'wlopm --on failed' "$t/err" && ((ms >= 7000 && ms < 15000))
res $? "blockie-poweroff with a hanging wlopm and a game that never ends: PowerOff still called inside 15 s ($ms ms)"
exec 4>&-

if (( fails )); then
  echo "power: $fails failed"
  exit 1
fi
echo "power: ok"
