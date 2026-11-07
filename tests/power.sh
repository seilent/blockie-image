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
mkdir -p "$t/bin" "$t/run" "$s"
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
echo "busctl \$*" >> "$t/log"
EOF
chmod 755 "$t/bin/wlopm" "$t/bin/systemctl" "$t/bin/busctl"

state() {
  rm -f "${s:?}"/* "$t/log"
  echo "$1" > "$s/active"
  [[ $2 != stopped ]] || : > "$s/stopped"
}
run() {
  local t0=${EPOCHREALTIME//[!0-9]/}
  XDG_RUNTIME_DIR=$t/run PATH=$t/bin:$PATH timeout 20 "$@" > "$t/out" 2> "$t/err"
  rc=$?
  ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
  touch "$t/log"
}
logis() { [[ $(< "$t/log") == "$1" ]]; }
stopped() { [[ -e $s/stopped ]]; }
stop_line='systemctl --user kill --signal=SIGSTOP blockie-game.scope'
cont_line='systemctl --user kill --signal=SIGCONT blockie-game.scope'
off_line='busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PowerOff b false'

ok=0
for h in blank-on blank-off screen-on; do
  [[ -x $hooks/$h && $(head -n 1 "$hooks/$h") == '#!/bin/sh' ]] && sh -n "$hooks/$h" || { ok=1; echo "  $h"; }
done
[[ -x $off && $(head -n 1 "$off") == '#!/bin/sh' ]] && sh -n "$off" || { ok=1; echo "  $off"; }
res $ok "the display hooks and blockie-poweroff are executable sh scripts"

state 1 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis "$stop_line"$'\nwlopm --off *' && stopped
r1=$?
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis "$stop_line"$'\nwlopm --off *\n'"$stop_line"$'\nwlopm --off *' && stopped
res $((r1 || $?)) "blank-on sends SIGSTOP to an active game scope before wlopm --off, again on a second blank-on"

rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$cont_line" && ! stopped
r1=$?
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'wlopm --on *\n'"$cont_line"
res $((r1 || $?)) "blank-off runs wlopm --on before SIGCONT, and sends SIGCONT again on a second blank-off"

ok=0
state 0 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis 'wlopm --off *' || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 && ! -s $t/err ]] && logis $'wlopm --on *\n'"$cont_line" || ok=1
res $ok "no game scope: blank-on sends no signal, blank-off still sends SIGCONT, its failure is not an error, exit 0"

ok=0
state 1 running
echo 1 > "$s/wlopm.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *' && stopped || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$cont_line" && ! stopped || ok=1
state 1 running
echo 1 > "$s/kill.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *' || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$cont_line" || ok=1
res $ok "a failing wlopm, or a failing signal to an active scope, exits 1 and the other step still runs"

state 1 stopped
run "$hooks/screen-on"
[[ $rc == 0 ]] && logis 'wlopm --on *' && stopped
res $? "screen-on turns the output on and leaves the game stopped"

ok=0
state 1 running
: > "$s/wlopm.hang"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis "$stop_line"$'\nwlopm --off *' && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-on: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\n'"$cont_line" && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-off: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/screen-on"
[[ $rc != 0 ]] && logis 'wlopm --on *' && ((ms >= 2000 && ms < 5000)) || { ok=1; echo "  screen-on: rc $rc $ms ms"; }
res $ok "a hanging wlopm is cut at 2 s: each hook exits nonzero inside the 5 s hook limit, SIGSTOP and SIGCONT still go out"

mkfifo -m 600 "$t/run/blockie-game.cmd"
exec 4<> "$t/run/blockie-game.cmd"
state 0 running
run "$off"
line=
read -r -t 0.5 line <&4
[[ $rc == 0 && -z $line && ! -s $t/err ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$off_line" && ((ms < 5000))
res $? "blockie-poweroff with no game: wlopm --on, SIGCONT (its failure not logged), no QUIT, then PowerOff at once ($ms ms)"

ok=0
for c in 1:0:5000 11:2000:5000 -1:5000:15000; do
  IFS=: read -r n lo hi <<< "$c"
  state "$n" stopped
  run "$off"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$off_line" &&
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
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$off_line" &&
  grep -q 'SIGCONT to blockie-game.scope failed' "$t/err"
res $? "blockie-poweroff: a failing SIGCONT to an active scope is logged, QUIT and PowerOff still follow"

state -1 stopped
: > "$s/wlopm.hang"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\n'"$cont_line"$'\n'"$off_line" &&
  grep -q 'wlopm --on failed' "$t/err" && ((ms >= 7000 && ms < 15000))
res $? "blockie-poweroff with a hanging wlopm and a game that never ends: PowerOff still called inside 15 s ($ms ms)"
exec 4>&-

if (( fails )); then
  echo "power: $fails failed"
  exit 1
fi
echo "power: ok"
