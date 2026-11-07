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
  '--user show -P FreezerState blockie-game.scope') cat "$s/freezer" 2> /dev/null || echo running ;;
  '--user is-active --quiet blockie-game.scope')
    [ "\$n" = 0 ] && exit 3
    [ "\$n" -lt 0 ] || echo \$((n - 1)) > "$s/active"
    ;;
  '--user freeze blockie-game.scope' | '--user thaw blockie-game.scope')
    echo "systemctl \$*" >> "$t/log"
    rc=\$(cat "$s/\$2.rc" 2> /dev/null || echo 0)
    [ "\$rc" != 0 ] || { [ "\$2" = freeze ] && echo frozen || echo running; } > "$s/freezer"
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
  echo "$2" > "$s/freezer"
}
run() {
  local t0=${EPOCHREALTIME//[!0-9]/}
  XDG_RUNTIME_DIR=$t/run PATH=$t/bin:$PATH timeout 20 "$@" > "$t/out" 2> "$t/err"
  rc=$?
  ms=$(((${EPOCHREALTIME//[!0-9]/} - t0) / 1000))
  touch "$t/log"
}
logis() { [[ $(< "$t/log") == "$1" ]]; }
freezer() { [[ $(< "$s/freezer") == "$1" ]]; }
off_line='busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PowerOff b false'

ok=0
for h in blank-on blank-off screen-on; do
  [[ -x $hooks/$h && $(head -n 1 "$hooks/$h") == '#!/bin/sh' ]] && sh -n "$hooks/$h" || { ok=1; echo "  $h"; }
done
[[ -x $off && $(head -n 1 "$off") == '#!/bin/sh' ]] && sh -n "$off" || { ok=1; echo "  $off"; }
res $ok "the display hooks and blockie-poweroff are executable sh scripts"

state 1 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *' && freezer frozen
r1=$?
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *\nwlopm --off *'
res $((r1 || $?)) "blank-on freezes a running game before wlopm --off, a second blank-on only turns the output off"

run "$hooks/blank-off"
[[ $rc == 0 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *\nwlopm --off *\nwlopm --on *\nsystemctl --user thaw blockie-game.scope' &&
  freezer running
r1=$?
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis 'wlopm --on *'
res $((r1 || $?)) "blank-off runs wlopm --on before the thaw, a second blank-off only turns the output on"

ok=0
state 0 running
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis 'wlopm --off *' || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis 'wlopm --on *' || ok=1
state 1 frozen-by-parent
run "$hooks/blank-on"
[[ $rc == 0 ]] && logis 'wlopm --off *' || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 0 ]] && logis 'wlopm --on *' || ok=1
res $ok "no game scope, or one frozen with its parked slice: no freeze or thaw, exit 0"

ok=0
state 1 running
echo 1 > "$s/wlopm.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *' || ok=1
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\nsystemctl --user thaw blockie-game.scope' && freezer running || ok=1
state 1 running
echo 1 > "$s/freeze.rc"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *' || ok=1
res $ok "a failing wlopm or freeze exits 1 and the other step still runs"

state 1 frozen
run "$hooks/screen-on"
[[ $rc == 0 ]] && logis 'wlopm --on *' && freezer frozen
res $? "screen-on turns the output on and leaves the game frozen"

ok=0
state 1 running
: > "$s/wlopm.hang"
run "$hooks/blank-on"
[[ $rc == 1 ]] && logis $'systemctl --user freeze blockie-game.scope\nwlopm --off *' && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-on: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/blank-off"
[[ $rc == 1 ]] && logis $'wlopm --on *\nsystemctl --user thaw blockie-game.scope' && ((ms >= 2000 && ms < 5000)) ||
  { ok=1; echo "  blank-off: rc $rc $ms ms"; }
rm -f "$t/log"
run "$hooks/screen-on"
[[ $rc != 0 ]] && logis 'wlopm --on *' && ((ms >= 2000 && ms < 5000)) || { ok=1; echo "  screen-on: rc $rc $ms ms"; }
res $ok "a hanging wlopm is cut at 2 s: each hook exits nonzero inside the 5 s hook limit, freeze and thaw still run"

mkfifo -m 600 "$t/run/blockie-game.cmd"
exec 4<> "$t/run/blockie-game.cmd"
state 0 running
run "$off"
line=
read -r -t 0.5 line <&4
[[ $rc == 0 && -z $line ]] && logis $'wlopm --on *\n'"$off_line" && ((ms < 5000))
res $? "blockie-poweroff with no game: wlopm --on, no QUIT, then PowerOff at once ($ms ms)"

ok=0
for c in 1:0:5000 11:2000:5000 -1:5000:15000; do
  IFS=: read -r n lo hi <<< "$c"
  state "$n" frozen
  run "$off"
  line=
  read -r -t 1 line <&4
  [[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\nsystemctl --user thaw blockie-game.scope\n'"$off_line" &&
    ((ms >= lo && ms < hi)) || { ok=1; echo "  active $n: rc $rc line '$line' $ms ms"; }
  if [[ $n == -1 ]]; then
    grep -q 'still active after 5 s, powering off anyway' "$t/err" || { ok=1; echo "  active $n: no log line"; }
  fi
done
res $ok "blockie-poweroff: wlopm --on, thaw, QUIT, then PowerOff when the scope ends at once, after 2 s or never (5 s), inside 15 s"

state -1 frozen
: > "$s/wlopm.hang"
run "$off"
line=
read -r -t 1 line <&4
[[ $rc == 0 && $line == QUIT ]] && logis $'wlopm --on *\nsystemctl --user thaw blockie-game.scope\n'"$off_line" &&
  grep -q 'wlopm --on failed' "$t/err" && ((ms >= 7000 && ms < 15000))
res $? "blockie-poweroff with a hanging wlopm and a game that never ends: PowerOff still called inside 15 s ($ms ms)"
exec 4>&-

if (( fails )); then
  echo "power: $fails failed"
  exit 1
fi
echo "power: ok"
