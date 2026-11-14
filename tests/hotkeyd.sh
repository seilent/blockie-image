#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
[[ -e /run/.containerenv ]] || { echo "hotkeyd: runs only in a container, so a sleep case can never reach the host's /sys/power" >&2; exit 2; }
bin=${HOTKEYD_BIN:-/usr/libexec/blockie/blockie-hotkeyd}
[[ -x $bin ]] || bin=$here/../system_files/usr/libexec/blockie/blockie-hotkeyd
runner=${HOOK_BIN:-/usr/libexec/blockie/blockie-hook}
[[ -x $runner ]] || runner=$here/../system_files/usr/libexec/blockie/blockie-hook
tables=/usr/lib/blockie/hotkeys.d
[[ -d $tables ]] || tables=$here/../system_files/usr/lib/blockie/hotkeys.d
schema=/usr/share/blockie/schema.d/30-buttons.json
[[ -f $schema ]] || schema=$here/../system_files/usr/share/blockie/schema.d/30-buttons.json
t=$(mktemp -d "${TMPDIR:-/tmp}/hotkeyd.XXXXXX")
fails=0
trap 'rm -rf "${t:?}"' EXIT
export t

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

if [[ ${HOTKEYD_CASES:-} != qs11 ]]; then
mkdir -p "$t/usr" "$t/etc" "$t/usr/test-a.conf.d" "$t/run"
printf 'test-a 1 1\n' > "$t/current"
cat > "$t/usr/test-a.conf" << 'EOF'
home hold next
home tap switch test-b
extra1 tap call net.seilent.Test /net/seilent/Test net.seilent.Test1 Ping
extra2 hold unit blockie-test.service
extra3 tap switch Bad
volup tap hook volume-up
voldown press switch test-b
power hold none
nonsense tap none
home wiggle none
home hold menu
EOF
printf 'extra3 press hook beep\nextra3 tap none\n' > "$t/usr/test-a.conf.d/50-x.conf"
printf 'extra2 hold back\n' > "$t/etc/test-a.conf"

mkdir -p "$t/fbin"
: > "$t/menu.q"
cat > "$t/fbin/fake-menu" << EOF
#!/bin/sh
echo "menu start from=\$BLOCKIE_POWERMENU_FROM state=\$BLOCKIE_BOOT_STATE" >> "$t/hooks.log"
echo \$\$ > "$t/menu.pid"
if [ -n "\${BLOCKIE_POWERMENU_MODE:-}" ]; then
  echo "menu mode=\$BLOCKIE_POWERMENU_MODE" >> "$t/hooks.log"
  exec 4<&0
  while read -r w <&4; do echo "menu stdin \$w" >> "$t/hooks.log"; done &
fi
trap 'echo "menu term" >> "$t/hooks.log"; echo "term \$(date +%s%3N)" >> "$t/times"; [ -f "$t/menu.ignore" ] || { rm -f "$t/menu.pid"; exit 0; }' TERM
while read -r d line; do
  sleep "\$d" > /dev/null &
  wait \$!
  if [ "\$line" = exit ]; then
    echo "menu exit" >> "$t/hooks.log"
    rm -f "$t/menu.pid"
    exit 0
  fi
  echo "\$line"
done < "$t/menu.q"
while :; do
  sleep 20 > /dev/null &
  wait \$!
done
EOF
cat > "$t/fbin/fake-backlight" << EOF
#!/bin/sh
echo "backlight \$*" >> "$t/hooks.log"
echo "backlight-\$1 \$(date +%s%3N)" >> "$t/times"
EOF
chmod 755 "$t/fbin/fake-menu" "$t/fbin/fake-backlight"
endmenu() {
  [[ ! -f $t/menu.pid ]] || kill -9 "$(< "$t/menu.pid")" 2> /dev/null
  rm -f "$t/menu.pid" "$t/menu.ignore"
  : > "$t/menu.q"
}
mq() { printf '%s\n' "$@" > "$t/menu.q"; }

run() {
  local script=$1
  rm -f "$t/fifo" "$t/hooks.log"
  mkfifo "$t/fifo"
  XDG_RUNTIME_DIR=$t/run BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_TABLES="${TABLES:-$t/usr:$t/etc}" BLOCKIE_HOTKEYD_CURRENT=$t/current \
    BLOCKIE_HOTKEYD_BUTTONS="${MAP:-$t/nomap}" \
    BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_MENU=$t/fbin/fake-menu \
    timeout -k 5 20 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  timeout -k 5 60 bash -c "exec > '$t/fifo'; $script"
  wait "$pid"
  endmenu
  touch "$t/hooks.log"
}

run 'echo home down; sleep 0.5; echo home up'
[[ $(cat "$t/out") == "action home hold next" ]]
res $? "home hold past 300 ms fires the session's hold row"

run 'echo home down; sleep 0.1; echo home up'
[[ $(cat "$t/out") == "action home tap switch test-b" ]]
res $? "a short home press fires the tap row, not the hold row"

run 'echo extra2 down; sleep 0.5; echo extra2 up'
[[ $(cat "$t/out") == "action extra2 hold back" ]]
res $? "/etc row overrides the /usr row for the same key and gesture"

run 'echo extra3 down; sleep 0.65; echo extra3 up'
n=$(grep -c '^action extra3 press hook beep$' "$t/out")
(( n >= 3 && n <= 5 )) && ! grep -q 'extra3 tap' "$t/out"
res $? "a press row repeats while held ($n times in 650 ms) and drops the tap row"

run 'echo volup down; echo volup up'
[[ $(cat "$t/out") == "action volup tap hook volume-up" ]]
res $? "a session tap row replaces the default volume press row"

run 'echo extra1 down; echo extra1 up; echo power down; sleep 0.5; echo power up'
[[ $(cat "$t/out") == $'action extra1 tap call net.seilent.Test /net/seilent/Test net.seilent.Test1 Ping\naction power hold none' ]]
res $? "call row and an explicit none row"

grep -q 'test-a.conf:5: ignored: extra3 tap switch Bad' "$t/err" && grep -q 'test-a.conf:7: ignored: voldown press' "$t/err" &&
  grep -q 'test-a.conf:9: ignored: nonsense' "$t/err" && grep -q 'test-a.conf:10: ignored: home wiggle' "$t/err" &&
  grep -q 'test-a.conf:11: ignored: home hold menu' "$t/err"
res $? "bad names, press rows that are not hooks, unknown keys and gestures, and menu on a key other than power are ignored with their line"

printf 'home tap switch test-b\n' > "$t/usr/test-c.conf"
printf 'test-c 1 1\n' > "$t/current"
run 'echo home down; sleep 0.5; echo home up'
[[ $(cat "$t/out") == "action home hold switcher" ]]
res $? "a session tap row keeps the default hold row of the same key"

printf 'nobody-here 1 1\n' > "$t/current"
run 'echo home down; sleep 0.5; echo home up; echo voldown down; echo voldown up'
[[ $(cat "$t/out") == $'action home hold switcher\naction voldown press hook volume-down' ]]
res $? "a session without a table gets the defaults"

printf 'test-a 1 1\n' > "$t/current"
run 'echo home down; sleep 0.1; printf "x\n" > /dev/null; echo home down; echo home up'
[[ $(cat "$t/out") == "action home tap switch test-b" ]]
res $? "a second down without an up starts a new press, so its release is a tap"

layout() {
  local a b
  declare -A x=([home.tap]=none [home.hold]=switcher [extra1.tap]=none [extra1.hold]=none [extra2.tap]=none
    [extra2.hold]=none [extra3.tap]=game-menu [extra3.hold]=game-quit)
  for a in "${@:2}"; do
    x[${a%%=*}]=${a#*=}
  done
  {
    echo 'version 1'
    for b in home extra1 extra2 extra3; do
      echo "$b tap ${x[$b.tap]}"
      echo "$b hold ${x[$b.hold]}"
      if [[ ${x[$b.tap]} == none && ${x[$b.hold]} == none ]]; then echo "$b free yes"; else echo "$b free no"; fi
    done
  } > "$1.new" && mv -f "$1.new" "$1"
}

printf 'emulation 1 1\n' > "$t/current"
both='echo home down; sleep 0.5; echo home up; echo extra3 down; sleep 0.1; echo extra3 up; echo extra3 down; sleep 0.5; echo extra3 up'
TABLES=$tables run "$both; echo extra1 down; sleep 0.5; echo extra1 up; $both"
[[ ! -e $tables ]] && ! grep -q ignored "$t/err" && [[ $(cat "$t/out") == $'action home hold switcher\naction extra3 tap game-menu\naction extra3 hold hook game-quit\naction home hold switcher\naction extra3 tap game-menu\naction extra3 hold hook game-quit' &&
  $(grep -c "no $t/nomap: the built in button defaults apply" "$t/err") == 1 ]]
r=$?
printf 'android 1 1\n' > "$t/current"
TABLES=$tables run "$both"
[[ $r == 0 && $(cat "$t/out") == "action home hold switcher" ]]
res $? "map: none, the shipped hotkeys.d absent: the built in defaults, home hold the switcher, logo tap and hold the game hooks in emulation only, extra1 nothing, logged once"

printf 'emulation 1 1\n' > "$t/current"
layout "$t/map" extra1.hold=switcher home.hold=none
MAP=$t/map TABLES=$t/none run 'echo extra1 down; sleep 0.5; echo extra1 up; echo home down; sleep 0.5; echo home up'
[[ $(cat "$t/out") == "action extra1 hold switcher" ]] &&
  grep -q "$t/map: home none none, extra1 none switcher, extra2 none none, extra3 game-menu game-quit" "$t/err"
res $? "map: the switcher moved to extra1: extra1 hold fires it, home hold nothing"

layout "$t/map"
layout "$t/map.b" home.hold=none home.tap=switcher
MAP=$t/map TABLES=$t/none run "echo home down; sleep 0.5; echo home up; sleep 0.2; mv -f '$t/map.b' '$t/map'; echo home down; sleep 0.5; echo home up"
[[ $(cat "$t/out") == $'action home hold switcher\naction home tap switcher' ]]
res $? "map: a map written between two presses: the second press follows it"

ok=0
for c in short bogus; do
  layout "$t/map" extra1.hold=switcher home.hold=$([[ $c == bogus ]] && echo next || echo none)
  [[ $c == bogus ]] || sed -i '$d' "$t/map"
  MAP=$t/map TABLES=$t/none run 'echo extra1 down; sleep 0.5; echo extra1 up; echo home down; sleep 0.5; echo home up
    echo home down; sleep 0.5; echo home up'
  [[ $(cat "$t/out") == $'action home hold switcher\naction home hold switcher' &&
    $(grep -c "$t/map is not the 13 line button map: the built in button defaults apply" "$t/err") == 1 ]] ||
    { ok=1; echo "  $c: $(paste -sd '|' "$t/out") $(paste -sd '|' "$t/err")"; }
done
res $ok "map: a short map or an unknown word: the built in defaults, one log line"

mkdir -p "$t/u5" "$t/e5"
printf '%s\n' 'home tap hook u5home' 'extra2 tap hook u5extra2' 'volup tap hook u5volup' > "$t/u5/emulation.conf"
printf 'extra1 hold hook e5extra1\n' > "$t/e5/emulation.conf"
layout "$t/map" extra1.hold=switcher home.hold=none
MAP=$t/map TABLES=$t/u5:@settings:$t/e5 run 'echo home down; echo home up; echo extra2 down; echo extra2 up; echo volup down
  echo volup up; echo extra1 down; sleep 0.5; echo extra1 up; echo home down; echo home up'
[[ $(cat "$t/out") == $'action volup tap hook u5volup\naction extra1 hold hook e5extra1' &&
  $(grep -c "$t/u5/emulation.conf: rows for extra2, home dropped, the button settings own them" "$t/err") == 1 ]]
res $? "@settings: button rows above the marker are dropped with one log per file version, other rows stay, a row below it beats the map"

printf 'nobody-here 1 1\n' > "$t/current"
run 'echo power down; echo power up; echo home down; sleep 0.5; echo home up; echo volup down; echo volup up
  echo extra3 down; echo extra3 up; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power tap blank\ngrab\naction power tap blank\nungrab\nresync' ]]
res $? "power tap blanks and grabs, other keys fire nothing while blanked, the next power tap wakes, ungrabs and resyncs"

run 'echo power down; sleep 1.3; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power hold=1000 menu\ngrab keys\naction power tap blank\nungrab\nresync\ngrab' ]]
res $? "a lost power release: the second down starts a new press and its tap closes the menu and blanks"

ok=0
run 'echo power down; sleep 0.9; echo power up'
[[ $(cat "$t/out") == $'action power tap blank\ngrab' ]] || { ok=1; echo "  0.9 s: $(paste -sd '|' "$t/out")"; }
run 'echo power down; sleep 3.6; echo power up'
[[ $(cat "$t/out") == $'action power hold=1000 menu\ngrab keys\naction power hold=3000 unit blockie-poweroff.service\nungrab\nresync\ngrab' ]] &&
  grep -qx 'menu start from=awake state=/run/blockie/boot/state' "$t/hooks.log" || { ok=1; echo "  no shown: $(paste -sd '|' "$t/out")"; }
mq '0.2 shown'
run 'echo power down; sleep 3.6; echo power up'
[[ $(cat "$t/out") == $'action power hold=1000 menu\ngrab keys' ]] || { ok=1; echo "  shown: $(paste -sd '|' "$t/out")"; }
mq '0.2 shown' '0.2 cancel'
run 'echo power down; sleep 1.6; echo power up; sleep 0.3'
[[ $(cat "$t/out") == $'action power hold=1000 menu\ngrab keys\nungrab\nresync' ]] || { ok=1; echo "  cancel: $(paste -sd '|' "$t/out")"; }
res $ok "default power rows: a release before 1000 ms (at 900 ms) taps blank; 1000 ms opens the menu and grabs the key nodes; 3000 ms starts blockie-poweroff.service only when the menu printed no shown, its lit-frozen taking the full grab; leaving the menu ungrabs"

printf 'power tap none\npower hold none\n' > "$t/usr/test-p.conf"
printf 'test-p 1 1\n' > "$t/current"
run 'echo power down; echo power up; echo power down; sleep 3.3; echo power up'
[[ $(cat "$t/out") == $'action power tap none\naction power hold none' ]]
res $? "session power rows replace the default tap and both default hold stages"

printf '%s\n' 'power hold blank on' 'power hold=1200 unit blockie-test.service' 'power hold=abc none' 'power hold=0 none' \
  'power hold=70000 none' 'power tap blank off' > "$t/usr/test-h.conf"
printf 'test-h 1 1\n' > "$t/current"
run 'echo power down; sleep 0.7; echo power up; echo power down; sleep 1.5; echo power up'
[[ $(cat "$t/out") == $'action power hold blank on\ngrab\naction power hold blank on\naction power hold=1200 unit blockie-test.service' ]] &&
  grep -q 'test-h.conf:3: ignored: power hold=abc none' "$t/err" && grep -q 'test-h.conf:4: ignored: power hold=0 none' "$t/err" &&
  grep -q 'test-h.conf:5: ignored: power hold=70000 none' "$t/err" && grep -q 'test-h.conf:6: ignored: power tap blank off' "$t/err"
res $? "hold=<ms> rows add a stage each next to the plain hold, blanked to lit-frozen keeps the full grab; bad hold times and blank arguments are ignored with their line"

hk=$t/hooks
mkdir -p "$hk"
for h in blank-on blank-off screen-on menu-on; do
  cat > "$hk/$h" << EOF
#!/bin/sh
echo "start $h" >> "$t/hooks.log"
echo "start $h \$(date +%s%3N)" >> "$t/times"
s=0.5
[ ! -f "$hk/$h.sleep" ] || read -r s < "$hk/$h.sleep"
sleep "\$s"
rc=0
[ ! -f "$hk/$h.rc" ] || read -r rc < "$hk/$h.rc"
echo "exit $h" >> "$t/hooks.log"
echo "exit $h \$(date +%s%3N)" >> "$t/times"
exit "\$rc"
EOF
  chmod 755 "$hk/$h"
done
sed -i "3i [ ! -f '$t/run/blockie-game.paused' ] || echo 'flag blank-off' >> '$t/hooks.log'" "$hk/blank-off"
nowus() { python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000000))'; }
move() {
  echo "$1" > "$t/unit.state"
  echo "${2:-success}" > "$t/unit.result"
  nowus > "$t/unit.since"
}
export -f nowus move
cat > "$t/fbin/systemctl" << EOF
#!/bin/sh
nowus() { python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000000))'; }
case "\$*" in
  '--user show -p LoadState -p ActiveState -p Result -p StateChangeTimestampMonotonic '*)
    n=\$(cat "$t/unit.bad" 2> /dev/null || echo 0)
    if [ "\$n" -gt 0 ]; then
      echo \$((n - 1)) > "$t/unit.bad"
      [ "\$n" != 1 ] || exit 0
      printf 'LoadState=loaded\nActiveState=failed\nResult=exit-code\nStateChangeTimestampMonotonic=%s\n' "\$(nowus)"
      exit 1
    fi
    echo "LoadState=\$(cat "$t/unit.load" 2> /dev/null || echo loaded)"
    echo "ActiveState=\$(cat "$t/unit.state" 2> /dev/null || echo inactive)"
    echo "Result=\$(cat "$t/unit.result" 2> /dev/null || echo success)"
    echo "StateChangeTimestampMonotonic=\$(cat "$t/unit.since" 2> /dev/null || echo 0)"
    ;;
  '--user start --no-block '*)
    echo "systemctl \$*" >> "$t/hooks.log"
    [ ! -f "$t/unit.startrc" ] || exit "\$(cat "$t/unit.startrc")"
    cp "$t/unit.stamp" "$t/unit.since" 2> /dev/null || nowus > "$t/unit.since"
    ;;
  is-system-running) cat "$t/sysrun" 2> /dev/null || echo running ;;
  '--user show -P ActiveState blockie-game.scope')
    s=\$(cat "$t/scope.state" 2> /dev/null || echo inactive)
    [ "\$s" != error ] || exit 1
    echo "\$s"
    ;;
  *) echo "systemctl \$*" >> "$t/hooks.log" ;;
esac
EOF
chmod 755 "$t/fbin/systemctl"

live() {
  local script=$1 e=() x
  for x in ${FAST:-}; do
    e+=("BLOCKIE_HOTKEYD_$x")
  done
  rm -f "$t/fifo" "$t/hooks.log" "$t/times" "$t/qn" "$t/slept" "$t/unit.since" "$t/runner.pid"
  mkfifo "$t/fifo"
  PATH=$t/fbin:$PATH BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_HOOKS=$hk BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_HOOK_MS=${HOOK_MS:-5000} BLOCKIE_HOTKEYD_BACKSTOP_MS=${BACKSTOP_MS:-20000} BLOCKIE_HOTKEYD_TABLES=$t/usr:$t/etc BLOCKIE_HOTKEYD_CURRENT=$t/current \
    XDG_RUNTIME_DIR=$t/run BLOCKIE_HOTKEYD_BUTTONS="${MAP:-$t/nomap}" \
    BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_SLEPT=$t/slept BLOCKIE_HOTKEYD_SYSFS=$t/psys \
    BLOCKIE_HOTKEYD_KNOB=$t/knob BLOCKIE_HOTKEYD_HOOK_RUNNER=${RUNNER:-$runner} DBUS_SESSION_BUS_ADDRESS=unix:path=$t/nobus \
    BLOCKIE_HOTKEYD_MENU=$t/fbin/fake-menu BLOCKIE_HOTKEYD_BACKLIGHT=$t/fbin/fake-backlight BLOCKIE_BOOT_STATE=$t/boot.state \
    env "${e[@]}" timeout -k 5 30 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  echo "$pid" > "$t/hk.pid"
  timeout -k 5 60 bash -c "exec > '$t/fifo'; $script"
  wait "$pid"
  endmenu
  touch "$t/hooks.log"
}
logis() { [[ $(< "$t/hooks.log") == "$1" ]]; }
tap='echo power down; echo power up'
woke=$'start blank-off\nexit blank-off'

printf 'nobody-here 1 1\n' > "$t/current"
live 'sleep 1'
logis "$woke"
res $? "hooks run: start runs blank-off once, the applied state starts unknown"

live "sleep 1; $tap; sleep 0.1; $tap; sleep 1.5"
logis "$woke"$'\nstart blank-on\nexit blank-on\nstart blank-off\nexit blank-off'
res $? "hooks run: two taps inside one blank-on run blank-off after it, never overlapping"

live "sleep 1; $tap; sleep 0.1; $tap; sleep 0.1; $tap; sleep 1.2"
logis "$woke"$'\nstart blank-on\nexit blank-on'
res $? "hooks run: three taps inside one blank-on coalesce, one blank-on, ending blanked"

printf '%s\n' 'power hold blank on' 'power hold=600 unit blockie-poweroff.service' > "$t/usr/test-l.conf"
printf 'test-l 1 1\n' > "$t/current"
echo 1 > "$hk/blank-on.sleep"
live "sleep 1; echo power down; sleep 0.8; echo power up; sleep 0.7; $tap; sleep 1.5"
logis "$woke"$'\nstart blank-on\nexit blank-on\nstart screen-on\nexit screen-on\nsystemctl --user start --no-block blockie-poweroff.service'
res $? "hooks run: a long hold while blank-on runs: screen-on after blank-on, the unit after screen-on, a tap during screen-on runs no blank-on"
rm -f "$hk/blank-on.sleep"

started=$'start blank-on\nexit blank-on\nstart screen-on\nexit screen-on\nsystemctl --user start --no-block blockie-poweroff.service'
echo activating > "$t/unit.state"
live "sleep 1; echo power down; sleep 1.5; echo power up; sleep 0.3; $tap; sleep 0.5; echo failed > '$t/unit.state'; $tap
  sleep 1.2"
logis "$woke"$'\n'"$started"$'\n'"$woke" && grep -q 'blockie-poweroff.service is failed: back to awake' "$t/err"
res $? "hooks run: after the power off unit starts, a tap does nothing while it is activating and wakes once it failed"

echo activating > "$t/unit.state"
BACKSTOP_MS=1500 live "sleep 1; echo power down; sleep 1.5; echo power up; sleep 2.5"
logis "$woke"$'\n'"$started"$'\n'"$woke" && grep -q 'started 1500 ms ago and the power is still on: back to awake' "$t/err"
res $? "hooks run: the backstop wakes the screen when the power is still on after the unit start"
rm -f "$t/unit.state"

printf 'nobody-here 1 1\n' > "$t/current"
echo 3 > "$hk/blank-on.sleep"
HOOK_MS=1000 live "sleep 1; $tap; sleep 2.6; $tap; sleep 1.2"
logis "$woke"$'\nstart blank-on\nstart blank-on\n'"$woke" && grep -q 'blank-on: killed, once more' "$t/err"
res $? "hooks run: a blank-on killed at the limit runs once more, then the applied state is unknown and a tap runs blank-off"
rm -f "$hk/blank-on.sleep"

echo 1 > "$hk/blank-on.rc"
live "sleep 1; $tap; sleep 2.5"
logis "$woke"$'\nstart blank-on\nexit blank-on\nstart blank-on\nexit blank-on' && grep -q 'blank-on: exit 1$' "$t/err"
res $? "hooks run: a blank-on that always fails runs twice for one press, no loop"
rm -f "$hk/blank-on.rc"

rd=$t/rdirs
mkdir -p "$rd/etc/x.d" "$rd/usr/x.d" "$rd/usr/y.d" "$rd/usr/z.d" "$rd/usr/w.d" "$rd/usr/blank-off.d"
part() {
  printf '#!/bin/sh\necho %s >> "%s"\nsleep %s\nexit %s\n' "$2" "$t/parts.log" "${3:-0}" "${4:-0}" > "$1"
  chmod 755 "$1"
}
part "$rd/usr/x" main 0 3
part "$rd/usr/x.d/a" usr-a
part "$rd/etc/x.d/b" etc-b 0 1
part "$rd/usr/x.d/c" usr-c
part "$rd/etc/x.d/c" etc-c
part "$rd/usr/x.d/d" usr-d
part "$rd/etc/x.d/d" etc-d
chmod 644 "$rd/etc/x.d/d"
part "$rd/usr/x.d/e.sh" usr-e
part "$rd/usr/x.d/f~" usr-f
part "$rd/usr/y.d/a" hung 5
part "$rd/usr/z" main 0.2
for n in a b c; do
  part "$rd/usr/z.d/$n" "z-$n" 1
done
part "$rd/usr/w" main 3
part "$rd/usr/w.d/a" w-a
part "$rd/usr/blank-off" main
part "$rd/usr/blank-off.d/funeos" funeos
hrun() {
  rm -f "${t:?}/parts.log"
  BLOCKIE_HOOK_DIRS=$rd/etc:$rd/usr "$runner" "$@" 2> "$t/runner.err"
  local rc=$?
  touch "$t/parts.log"
  return "$rc"
}
now() { date +%s%3N; }

hrun x
r=$?
[[ $r == 3 && $(paste -sd ' ' "$t/parts.log") == "main usr-a etc-b etc-c" ]] && grep -q 'x.d/e.sh: skipped' "$t/runner.err" &&
  grep -q 'x.d/f~: skipped' "$t/runner.err"
res $? "runner: the main hook's rc $r, parts sorted across dirs, /etc masks a name (a non executable one too), part rc ignored, other names skipped"
s0=$(now)
hrun y
r=$?
s1=$(now)
[[ $r == 0 ]] && grep -q 'y.d/a: cut at 1000 ms' "$t/runner.err" && (( s1 - s0 >= 900 && s1 - s0 < 1600 ))
res $? "runner: no main hook exits 0, a hung part is cut at 1 s ($(( s1 - s0 )) ms)"
s0=$(now)
BLOCKIE_HOOK_MS=1500 hrun z
s1=$(now)
grep -q 'z.d/c: skipped' "$t/runner.err" && (( s1 - s0 < 1800 ))
res $? "runner: budget 1500 ms, a 0.2 s main and three 1 s parts end in $(( s1 - s0 )) ms with the skip logged"
s0=$(now)
BLOCKIE_HOOK_MS=500 hrun w
r=$?
s1=$(now)
got=$(paste -sd ' ' "$t/parts.log")
[[ $r == 124 && $got == "main w-a" ]] && (( s1 - s0 < 1600 ))
res $? "runner: a main hook over the budget exits 124 and the part still runs after it (rc $r, ran '$got', $(( s1 - s0 )) ms)"
hrun blank-off
r=$?
[[ $r == 0 && $(paste -sd ' ' "$t/parts.log") == "main funeos" ]]
res $? "runner: blank-off with a blank-off.d part runs both (the ExecStopPost form)"
hrun Bad
r1=$?
hrun
r2=$?
[[ $r1 == 2 && $r2 == 2 ]]
res $? "runner: a bad name or no name exits 2"

cat > "$t/fbin/fake-runner" << EOF
#!/bin/sh
echo \$\$ > "$t/runner.pid"
echo "runner \$*" >> "$t/hooks.log"
exec "$runner" "\$@"
EOF
cat > "$t/fbin/blockie-session" << EOF
#!/bin/sh
echo "blockie-session \$*" >> "$t/hooks.log"
echo "next \$(date +%s%3N)" >> "$t/times"
EOF
chmod 755 "$t/fbin/fake-runner" "$t/fbin/blockie-session"
dpart() {
  mkdir -p "$hk/$1.d"
  cat > "$hk/$1.d/funeos" << EOF
#!/bin/sh
echo "part $1" >> "$t/hooks.log"
echo "part \$(date +%s%3N)" >> "$t/times"
s=0
[ ! -f "$hk/$1.d.sleep" ] || read -r s < "$hk/$1.d.sleep"
sleep "\$s"
exit 1
EOF
  chmod 755 "$hk/$1.d/funeos"
}
fr=$t/fbin/fake-runner

printf 'nobody-here 1 1\n' > "$t/current"
dpart blank-on
RUNNER=$fr live "sleep 1; $tap; sleep 1.5"
logis "$woke"$'\nrunner blank-on\nstart blank-on\nexit blank-on\npart blank-on' && ! grep -q 'blank-on: exit' "$t/err"
res $? "hooks run: a blank-on.d part runs after the main hook through the runner, its exit 1 leaves blanked applied"
echo 5 > "$hk/blank-on.d.sleep"
RUNNER=$fr live "sleep 1; $tap; sleep 0.1; $tap; sleep 3"
g=$(awk '$1 == "exit" && $2 == "blank-on" {e = $3} $1 == "start" && $2 == "blank-off" {b = $3} END {print b - e}' "$t/times")
logis "$woke"$'\nrunner blank-on\nstart blank-on\nexit blank-on\npart blank-on\n'"$woke" && ((g >= 900 && g < 1600))
res $? "hooks run: a hung blank-on.d part delays the next blank-off by at most 1 s ($g ms)"
rm -rf "${hk:?}/blank-on.d" "${hk:?}/blank-on.d.sleep"

mv "$hk/screen-on" "$t/screen-on.main"
dpart screen-on
printf 'test-l 1 1\n' > "$t/current"
RUNNER=$fr live "sleep 1; echo power down; sleep 0.8; echo power up; sleep 1.2"
logis "$woke"$'\nstart blank-on\nexit blank-on\nrunner screen-on\npart screen-on\nsystemctl --user start --no-block blockie-poweroff.service'
res $? "hooks run: only a screen-on.d dir and no main hook: the part runs and lit-frozen applies"
rm -rf "${hk:?}/screen-on.d"
mv "$t/screen-on.main" "$hk/screen-on"

printf 'nobody-here 1 1\n' > "$t/current"
RUNNER=$fr live "sleep 1; echo volup down; echo volup up; sleep 0.5"
logis "$woke" && grep -q "no hook volume-up in $hk" "$t/err"
res $? "hooks run: no main hook and no .d dir: no runner spawned, logged once"

dpart switcher-open
RUNNER=$fr live "sleep 1; echo home down; sleep 0.5; echo home up; sleep 1"
logis "$woke"$'\nrunner switcher-open\npart switcher-open\nblockie-session next'
res $? "switcher: a switcher-open.d part runs before the switcher opens (blockie-session next without the overlay)"
echo 5 > "$hk/switcher-open.d.sleep"
RUNNER=$fr live "sleep 1; echo home down; sleep 0.5; echo home up; sleep 2.5"
g=$(awk '$1 == "part" {p = $2} $1 == "next" {n = $2} END {print n - p}' "$t/times")
logis "$woke"$'\nrunner switcher-open\npart switcher-open\nblockie-session next' && ((g >= 900 && g < 1700))
res $? "switcher: a hung switcher-open part delays it by at most about 1.5 s ($g ms)"
rm -rf "${hk:?}/switcher-open.d" "${hk:?}/switcher-open.d.sleep"

on=class/power_supply/mtk-master-charger/online
mkdir -p "$t/psys/${on%/*}" "$t/psys/class/power_supply/battery"
: > "$t/queue"
cat > "$t/fbin/fake-sleep" << EOF
#!/bin/sh
n=\$((\$(cat "$t/qn" 2> /dev/null || echo 0) + 1))
echo "\$n" > "$t/qn"
line=\$(sed -n "\${n}p" "$t/queue")
[ -n "\$line" ] || line='0 0 refused test'
echo "helper\${1:+ \$1}" >> "$t/hooks.log"
echo "helper \$(date +%s%3N)" >> "$t/times"
set -- \$line
[ "\$1" != hang ] || exec sleep 30
trap 'echo "helper term" >> "$t/hooks.log"; echo refused cancelled; exit 0' TERM
[ "\$1" = 0 ] || echo \$((\$(cat "$t/slept" 2> /dev/null || echo 0) + \$1)) > "$t/slept"
d=\$2
shift 2
[ "\$2" != plug ] || echo 1 > "$t/psys/$on"
sleep "\$d" > /dev/null &
wait \$!
echo "\$*"
EOF
chmod 755 "$t/fbin/fake-sleep"
until_n() {
  local i=0 n
  while :; do
    n=$(grep -c -- "$1" "$2" 2> /dev/null)
    ((${n:-0} >= ${3:-1})) && return 0
    ((++i < 600)) || return 1
    sleep 0.05
  done
}
export -f until_n
bat() {
  echo "$1" > "$t/psys/$on"
  echo "$2" > "$t/psys/class/power_supply/battery/capacity"
  echo 3900000 > "$t/psys/class/power_supply/battery/voltage_now"
}
lines() {
  local i
  for ((i = 0; i < $1; i++)); do
    printf '%s\n' "$2"
  done
}
ev() { grep -v '^exit ' "$t/hooks.log" | paste -sd ' '; }
calls() { grep -c '^helper\( first\)\?$' "$t/hooks.log"; }
tms() { grep "^$1 [0-9]*$" "$t/times" | awk '{print $NF}'; }
gaps() { tms helper | awk 'NR > 1 {printf "%d ", $1 - p} {p = $1}'; }
gap() { [[ -n $1 && -n $2 ]] && echo $(($1 - $2)) || echo -1; }
fast='SETTLE_MS=300 RESLEEP_MS=300 WAKE_MS=1500 LOST_MS=1000 RETRY_MS=300 RETRY_SLOW_MS=2000 SLEEP_KILL_MS=1000 VBUS_MS=300'
for h in blank-on blank-off screen-on menu-on; do
  echo 0.1 > "$hk/$h.sleep"
done
printf 'nobody-here 1 1\n' > "$t/current"
rm -f "$t/unit.state" "$t/unit.result" "$t/sysrun"
nt() { grep -vx 'menu term' "$t/hooks.log"; }
termed() { grep -qx 'menu term' "$t/hooks.log"; }
mo=$'start menu-on\nexit menu-on\nmenu start from=awake state='"$t/boot.state"
hold='sleep 0.5; echo power down; sleep 1.3; echo power up'
lit=$'start screen-on\nexit screen-on'
reboot_line='systemctl --user start --no-block blockie-reboot@android.service'
poff_line='systemctl --user start --no-block blockie-poweroff.service'

ok=0
for c in 'cancel|blank-off|no' 'screen-off|blank-on|no' 'failed wayland|blank-off|no' 'bogus line|blank-off|yes'; do
  IFS='|' read -r line h term <<< "$c"
  mq '0.1 shown' "0.2 $line"
  live "$hold; sleep 1"
  [[ $(nt) == "$woke"$'\n'"$mo"$'\nstart '"$h"$'\nexit '"$h" ]] || { ok=1; echo "  $line: $(nt | paste -sd '|')"; }
  if [[ $term == yes ]]; then
    termed && grep -q 'not a result: bogus line: back to awake' "$t/err" || { ok=1; echo "  $line: no SIGTERM"; }
  else
    ! termed || { ok=1; echo "  $line: SIGTERM to a child that exits by itself"; }
  fi
done
mq '0.1 shown' '0.2 poweroff'
live "$hold; sleep 1"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$poff_line" ]] && grep -q 'lit-frozen: 0 key nodes and 0 more grabbed' "$t/err" ||
  { ok=1; echo "  poweroff: $(paste -sd '|' "$t/hooks.log")"; }
mq '0.1 shown' '0.2 boot android'
live "$hold; sleep 2"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line" ]] && grep -q 'reboot is under way' "$t/err" ||
  { ok=1; echo "  boot android: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "menu: menu-on exits before the child starts (from awake, the boot state path passed); cancel, screen-off, failed, a stray line, poweroff and boot android each run their hook or unit; only the stray line and no exit line get SIGTERM, boot keeps the child"

mq '0.1 shown'
live 'sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 0.5'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo" ]] && grep -q 'blockie-powermenu showed: unit blockie-poweroff.service skipped' "$t/err"
res $? "menu: after shown a hold to 3000 ms starts nothing"

mq '0.1 shown' '0.3 cancel'
live 'sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 0.5'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && grep -q 'blockie-powermenu showed: unit blockie-poweroff.service skipped' "$t/err"
res $? "menu: shown, then closed inside the same hold: the 3000 ms stage stays skipped"

: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 1'
blinked() {
  local g a b
  g=$(gap "$(tms backlight-on)" "$(tms backlight-off)")
  a=$(gap "$(tms backlight-off)" "$(tms term)")
  b=$(gap "$(tms 'start screen-on')" "$(tms backlight-on)")
  [[ $(nt | grep -v '^backlight ') == "$1"$'\n'"$lit"$'\n'"$poff_line" ]] && grep -q 'lit-frozen: 0 key nodes and 0 more grabbed' "$t/err" &&
    [[ $(grep '^backlight ' "$t/hooks.log") == $'backlight off\nbacklight on' ]] && ((g >= 250 && g < 700 && b >= -20)) &&
    { [[ ${2:-} != term ]] || { termed && ((a >= -20)); }; } || { echo "  log $(paste -sd '|' "$t/hooks.log"), blink $g ms, term to off $a, on to screen-on $b"; return 1; }
}
blinked "$woke"$'\n'"$mo" term
res $? "menu: no shown by 3000 ms: SIGTERM to the child, then backlight off and about 300 ms later on, then screen-on and the blockie-poweroff.service start"

echo activating > "$t/unit.state"
ok=0
FAST="MENU=$t/none" live "sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 0.8; $tap; sleep 0.5"
blinked "$woke"$'\nstart menu-on\nexit menu-on\n'"$woke" && ! grep -q 'start blank-on' "$t/hooks.log" &&
  grep -q "cannot run $t/none" "$t/err" || ok=1
mq '0.1 failed wayland'
live "sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 0.8; $tap; sleep 0.5"
blinked "$woke"$'\n'"$mo"$'\n'"$woke" && ! grep -q 'start blank-on' "$t/hooks.log" || ok=1
res $ok "menu: with the menu binary missing, or failed before shown, the 3000 ms stage blinks and powers off through screen-on in lit-frozen, and a tap after it runs no blank-on"
rm -f "$t/unit.state"

echo 2.1 > "$hk/menu-on.sleep"
: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 3.6; echo power up; sleep 1'
e=$(tms 'exit menu-on')
bon=$(tms backlight-on)
[[ -n $e && -n $bon ]] && ((e < bon)) && ! grep -q '^menu start' "$t/hooks.log" && grep -qx "$poff_line" "$t/hooks.log"
res $? "menu: a menu-on that ends inside the 3000 ms blink starts no child"
echo 0.1 > "$hk/menu-on.sleep"

: > "$t/menu.q"
FAST='SHOWN_MS=1500' live "$hold; sleep 2"
[[ $(nt) == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && termed && grep -q 'printed no shown in 1500 ms: back to awake' "$t/err"
res $? "menu: a child with no shown within the shown limit is ended and hotkeyd goes back to awake"

: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 2; echo power up; sleep 2'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo" ]]
res $? "menu: a release at 2000 ms with no shown starts nothing and keeps the child"

mq '0.1 shown' '0.2 boot android'
FAST='BOOT_BACKSTOP_MS=3000' live "$hold; sleep 4.5"
[[ $(nt) == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] && termed && grep -q 'reboot is under way' "$t/err" &&
  grep -q 'blockie-reboot@android.service started 3000 ms ago and the power is still on: back to awake' "$t/err"
res $? "menu: boot android with the unit inactive and Result=success stays lit-frozen until the boot unit backstop (not the 20 s power off one), which SIGTERMs the child"

echo failed > "$t/unit.state"
echo exit-code > "$t/unit.result"
echo stopping > "$t/sysrun"
mq '0.1 shown' '0.2 boot android'
live "$hold; sleep 2.5"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line" ]] && grep -q 'while the system is stopping: ignored' "$t/err"
res $? "menu: the reboot unit failed while is-system-running prints stopping: ignored"
rm -f "$t/sysrun"

ok=0
mq '0.1 shown' '0.2 boot android' '1.6 exit'
live "$hold; sleep 3"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\nmenu exit\n'"$woke" ]] || { ok=1; echo "  child lives: $(paste -sd '|' "$t/hooks.log")"; }
mq '0.1 shown' '0.2 boot android' '5.6 exit'
live "$hold; sleep 7"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\nmenu exit\n'"$woke" ]] ||
  { ok=1; echo "  child ends 4.6 s after the count: $(paste -sd '|' "$t/hooks.log")"; }
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 2.5"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] ||
  { ok=1; echo "  child gone: $(paste -sd '|' "$t/hooks.log")"; }
mq '0.1 shown' '0.2 boot android'
FAST='TOAST_MS=1000' live "$hold; sleep 3.5"
[[ $(nt) == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] && termed || { ok=1; echo "  toast bound: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "menu: a failed reboot unit gives awake after the child's exit (also 4.6 s after the count, inside the 5100 ms toast time), at once when the child is gone, and SIGTERMs a child still up after the toast time"
rm -f "$t/unit.state" "$t/unit.result"

ok=0
echo 0 > "$t/unit.stamp"
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 2.5"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line" ]] && ! grep -q 'under way\|back to awake' "$t/err" ||
  { ok=1; echo "  fresh: $(paste -sd '|' "$t/hooks.log")"; }
echo 1 > "$t/unit.stamp"
echo failed > "$t/unit.state"
echo exit-code > "$t/unit.result"
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 2.5"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line" ]] && ! grep -q 'back to awake' "$t/err" ||
  { ok=1; echo "  stale failed: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$t/unit.stamp" "$t/unit.state" "$t/unit.result"
echo not-found > "$t/unit.load"
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 2.5"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] &&
  grep -q 'blockie-reboot@android.service is not-found: back to awake' "$t/err" || { ok=1; echo "  not-found: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$t/unit.load"
echo failed > "$t/unit.state"
echo start-limit-hit > "$t/unit.result"
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 2.5"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] &&
  grep -q 'blockie-reboot@android.service is failed start-limit-hit: back to awake' "$t/err" ||
  { ok=1; echo "  inactive to failed with no activation: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$t/unit.state" "$t/unit.result"
res $ok "menu: the reboot unit poll ignores a never started unit and a failed state older than this start, and counts a unit not loaded, or moved from inactive to failed with no activation, as failed"

echo activating > "$t/unit.state"
echo 2 > "$t/unit.bad"
mq '0.1 shown' '0.2 boot android'
FAST='POLL_MS=300' live "$hold; sleep 1.4; move inactive; sleep 0.8"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line" ]] && [[ $(< "$t/unit.bad") == 0 ]] &&
  [[ $(grep -c 'gave no state: polling on' "$t/err") == 2 ]] && grep -q 'reboot is under way' "$t/err" && ! grep -q 'back to awake' "$t/err"
res $? "menu: an unreadable and an empty systemctl show keep polling, then activating and the reboot goes ahead"
rm -f "$t/unit.state" "$t/unit.result" "$t/unit.bad"

echo 1 > "$t/unit.startrc"
mq '0.1 shown' '0.2 boot android' '0 exit'
live "$hold; sleep 0.8"
[[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$reboot_line"$'\n'"$woke" ]] &&
  grep -q 'blockie-reboot@android.service is refused (start exit 1): back to awake' "$t/err"
res $? "menu: a boot unit start that systemctl refuses counts as failed at once, before any poll"
rm -f "$t/unit.startrc"

printf '#!/bin/sh\necho beep >> "%s"\n' "$t/hooks.log" > "$hk/beep"
chmod 755 "$hk/beep"
printf '%s\n' 'volup press hook beep' 'home hold hook beep' 'extra3 tap hook beep' > "$t/usr/test-m.conf"
printf 'test-m 1 1\n' > "$t/current"
mq '0.1 shown'
live "sleep 0.5; echo extra3 down; echo extra3 up; sleep 0.3; $hold; sleep 0.3; echo volup down; echo volup up; echo home down; sleep 0.5
  echo home up; echo extra3 down; echo extra3 up; sleep 0.2; $tap; sleep 1"
[[ $(nt) == "$woke"$'\nbeep\n'"$mo"$'\nstart blank-on\nexit blank-on' ]] && termed && grep -q 'SIGTERM to blockie-powermenu' "$t/err"
res $? "menu: volup, home hold and extra3 rows fire nothing while it is up (extra3 fires before it), a power tap SIGTERMs the child and runs blank-on"

printf '#!/bin/sh\necho game-menu >> "%s"\n' "$t/hooks.log" > "$hk/game-menu"
chmod 755 "$hk/game-menu"
printf 'emulation 1 1\n' > "$t/current"
layout "$t/map" extra2.tap=game-menu
mq '0.1 shown'
MAP=$t/map live "sleep 0.5; echo extra2 down; echo extra2 up; sleep 0.3; $hold; sleep 0.3; echo extra2 down; echo extra2 up; sleep 0.2
  $tap; sleep 1"
[[ $(nt) == "$woke"$'\ngame-menu\n'"$mo"$'\nstart blank-on\nexit blank-on' ]]
res $? "menu: a button the map binds fires before the menu and nothing while it is up"
rm -f "$hk/game-menu"
printf 'test-m 1 1\n' > "$t/current"

echo 'home tap hook beep' >> "$t/usr/test-m.conf"
keys='echo home down; echo home up; echo home down; sleep 0.5; echo home up; echo volup down; echo volup up; echo extra3 down; echo extra3 up'
ok=0
mq '0.1 shown' '0.2 boot reboot'
live "sleep 0.5; echo extra3 down; echo extra3 up; sleep 0.3; $hold; sleep 0.5; $keys; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\nbeep\n'"$mo"$'\n'"$lit"$'\nsystemctl --user start --no-block blockie-reboot@reboot.service' ]] ||
  { ok=1; echo "  boot reboot: $(paste -sd '|' "$t/hooks.log")"; }
echo activating > "$t/unit.state"
: > "$t/menu.q"
live "sleep 0.5; echo extra3 down; echo extra3 up; sleep 0.3; echo power down; sleep 3.6; echo power up; sleep 0.3; $keys; sleep 0.5"
blinked "$woke"$'\nbeep\n'"$mo" term || ok=1
rm -f "$t/unit.state"
res $ok "lit-frozen: after boot reboot and after the 3000 ms fallback a home tap, a home hold, volup and extra3 fire nothing"

printf '%s\n' 'home tap hook beep' 'home hold=1500 hook beep' > "$t/usr/test-n.conf"
printf 'test-n 1 1\n' > "$t/current"
echo failed > "$t/unit.state"
echo exit-code > "$t/unit.result"
ok=0
for c in 'tap|0' 'hold|1.6'; do
  IFS='|' read -r what held <<< "$c"
  mq '0.1 shown' '0.2 boot reboot' '0 exit'
  FAST='POLL_MS=300' live "sleep 0.5; echo home down; echo home up; $hold; until_n '^start screen-on$' $t/hooks.log; echo home down
    until_n 'back to awake' $t/err; sleep $held; echo home up; sleep 0.5"
  [[ $(grep -vx 'menu exit' "$t/hooks.log") == "$woke"$'\nbeep\n'"$mo"$'\n'"$lit"$'\nsystemctl --user start --no-block blockie-reboot@reboot.service\n'"$woke" ]] &&
    grep -q 'blockie-reboot@reboot.service is failed exit-code: back to awake' "$t/err" ||
    { ok=1; echo "  $what: $(paste -sd '|' "$t/hooks.log")"; }
done
rm -f "$t/unit.state" "$t/unit.result" "$t/usr/test-n.conf"
printf 'test-m 1 1\n' > "$t/current"
res $ok "lit-frozen: a home press that starts after boot reboot and ends after a counted failure moved the state to awake fires nothing, as a tap or with its 1500 ms hold reached in awake"

echo activating > "$t/unit.state"
mq '0.1 shown' '0.2 poweroff'
live "$hold; until_n '^$poff_line\$' $t/hooks.log; sleep 0.3; echo failed > $t/unit.state; $tap; sleep 0.8"
lg=$(grep -n 'lit-frozen: 0 key nodes and 0 more grabbed' "$t/err" | head -n 1 | cut -d: -f1)
la=$(grep -n 'blockie-poweroff.service is failed: back to awake' "$t/err" | head -n 1 | cut -d: -f1)
lu=$(grep -n 'ungrabbed$' "$t/err" | tail -n 1 | cut -d: -f1)
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$poff_line"$'\n'"$woke" && -n $lg && -n $la && -n $lu ]] && ((lg < la && la < lu))
res $? "lit-frozen: after a POWER OFF pick the full grab is taken, a power tap still reads the unit and wakes once it failed, and leaving for awake ungrabs"
rm -f "$t/unit.state"
rm -f "$hk/beep" "$t/usr/test-m.conf"
printf 'nobody-here 1 1\n' > "$t/current"

mq '0.1 shown' '0.2 cancel' '4 exit'
FAST='MENU_KILL_MS=6000' live "$hold; sleep 0.8; echo power down; sleep 1.3; echo power up; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && grep -q 'menu: ignored, blockie-powermenu still runs' "$t/err"
res $? "menu: a menu stage while the fading child still runs is ignored"

mq '0.1 shown' '0.2 cancel' '6 exit'
FAST='MENU_KILL_MS=8000' live "$hold; sleep 0.8; echo power down; sleep 3.6; echo power up; sleep 0.5"
blinked "$woke"$'\n'"$mo"$'\n'"$woke" && grep -q 'menu: ignored, blockie-powermenu still runs' "$t/err" && ! termed
res $? "menu: a hold that starts while the closing child still waits for its keys finds it alive: the 1000 ms stage is ignored, and the same hold to 3000 ms powers off by the fallback"

echo activating > "$t/unit.state"
mq '0.1 shown' '0.2 poweroff'
live "$hold; sleep 1.5; echo power down; sleep 1.3; echo power up; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$poff_line" ]] && grep -q 'menu: ignored, lit-frozen' "$t/err" &&
  grep -q 'blockie-powermenu still running after 2000 ms: killed' "$t/err"
res $? "menu: a menu stage in lit-frozen is ignored; a child that said poweroff and stays is killed at the kill time"
rm -f "$t/unit.state"

dpart switcher-open
echo 5 > "$hk/switcher-open.d.sleep"
: > "$t/menu.q"
RUNNER=$fr live "sleep 0.5; echo power down; sleep 0.2; echo home down; sleep 0.4; echo home up; until_n '^runner switcher-open\$' $t/hooks.log
  p=\$(< $t/runner.pid); while kill -0 \"\$p\" 2> /dev/null; do sleep 0.02; done; date +%s%3N > $t/runner.dead; sleep 0.5; echo power up; sleep 0.5"
g=$(gap "$(cat "$t/runner.dead" 2> /dev/null)" "$(tms 'start menu-on')")
[[ $(< "$t/hooks.log") == "$woke"$'\nrunner switcher-open\npart switcher-open\n'"$mo" ]] && grep -q 'switcher-open killed for the power menu' "$t/err" &&
  ((g > -300 && g < 300))
res $? "menu: a running switcher-open is killed at the menu stage ($g ms from the menu-on start) and no switcher follows in the 1 s after its death"
rm -rf "${hk:?}/switcher-open.d" "${hk:?}/switcher-open.d.sleep"

echo 1 > "$hk/menu-on.rc"
live "$hold; sleep 1"
[[ $(< "$t/hooks.log") == "$woke"$'\nstart menu-on\nexit menu-on\nstart menu-on\nexit menu-on\n'"$woke" ]] && grep -q 'menu-on failed twice: back to awake' "$t/err"
res $? "menu: menu-on failing twice gives awake and no child"
rm -f "$hk/menu-on.rc"

mq '0.1 shown' '0.2 cancel' '0 poweroff'
live "$hold; sleep 1"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && grep -q 'dropped: poweroff' "$t/err"
res $? "menu: a line after the first result is dropped"

mq '0.3 exit'
live "$hold; sleep 1"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\nmenu exit\n'"$woke" ]] && grep -q 'ended with no result: back to awake' "$t/err"
res $? "menu: an exit with no line gives awake"

: > "$t/menu.ignore"
mq '0.1 shown'
FAST='MENU_KILL_MS=800' live "$hold; sleep 0.3; $tap; until_n '^menu term$' $t/hooks.log; s0=\$(date +%s%3N); p=\$(< $t/menu.pid)
  while kill -0 \"\$p\" 2> /dev/null; do sleep 0.02; done; echo \$((\$(date +%s%3N) - s0)) > $t/killed.ms; sleep 0.3"
g=$(cat "$t/killed.ms" 2> /dev/null || echo -1)
((g >= 600 && g < 1400)) && grep -q 'blockie-powermenu still running after 800 ms: killed' "$t/err"
res $? "menu: a child ignoring SIGTERM is killed at the kill time ($g ms)"

printf '#!/bin/sh\necho game-menu >> "%s"\n' "$t/hooks.log" > "$hk/game-menu"
printf '#!/bin/sh\necho game-quit >> "%s"\n' "$t/hooks.log" > "$hk/game-quit"
chmod 755 "$hk/game-menu" "$hk/game-quit"
printf 'emulation 1 1\n' > "$t/current"
port=$t/run/blockie-game.port
flag=$t/run/blockie-game.paused
pmo="$mo"$'\nmenu mode=pause'
lt='sleep 0.5; echo extra3 down; echo extra3 up'
lh='echo extra3 down; sleep 0.5; echo extra3 up'
running() { rm -f "$flag"; : > "$port"; echo active > "$t/scope.state"; }
nogame() { rm -f "$port" "$flag" "$t/scope.state"; }
after() { nt | tail -n +7 | sort | paste -sd '|'; }

running
mq '0.1 shown'
PATH=$t/fbin:$PATH run "$lt; sleep 0.5"
[[ $(cat "$t/out") == $'action extra3 tap game-menu\ngrab keys' && -e $flag ]] && grep -q 'blockie-powermenu started in pause mode' "$t/err"
r=$?
nogame
PATH=$t/fbin:$PATH run "$lt; sleep 0.5"
[[ $r == 0 && $(cat "$t/out") == 'action extra3 tap game-menu' && ! -e $flag ]]
res $? "pause (dry): a logo tap with blockie-game.port and an active scope grabs the key nodes and starts the pause child; with neither it is the plain game-menu"

running
mq '0.1 shown' '0.3 resume' '0.3 exit'
PATH=$t/fbin:$PATH run "$lt; sleep 1.2"
[[ $(cat "$t/out") == $'action extra3 tap game-menu\ngrab keys\nungrab\nresync\nresync' && ! -e $flag ]]
res $? "pause (dry): a pause child's exit runs resync, after the ungrab's own, so a key forwarded by it cannot stay down"

running
mq '0.1 shown' '0.8 resume'
live "$lt; sleep 0.4; echo extra3 down; echo extra3 up; sleep 1.2"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nmenu stdin back\n'"$woke" && ! -e $flag ]] && ! termed && ! grep -qx game-menu "$t/hooks.log"
res $? "pause: a logo tap runs menu-on and the pause child, a second tap writes back to it, its resume removes blockie-game.paused before blank-off continues the scope"

ok=0
nogame
echo active > "$t/scope.state"
live "$lt; sleep 0.5"
logis "$woke"$'\ngame-menu' && [[ ! -e $flag ]] || { ok=1; echo "  no port file: $(paste -sd '|' "$t/hooks.log")"; }
: > "$port"
echo inactive > "$t/scope.state"
live "$lt; sleep 0.5"
logis "$woke"$'\ngame-menu' && [[ ! -e $flag ]] || { ok=1; echo "  scope inactive: $(paste -sd '|' "$t/hooks.log")"; }
printf 'android 1 1\n' > "$t/current"
running
live "$lt; sleep 0.5"
logis "$woke" && [[ ! -e $flag ]] || { ok=1; echo "  android: $(paste -sd '|' "$t/hooks.log")"; }
printf 'emulation 1 1\n' > "$t/current"
res $ok "pause: without blockie-game.port (scope active) or with the scope inactive the logo tap runs the game-menu hook (RetroArch's menu); in another session nothing"

running
mq '0.1 shown' '1.2 cancel'
live "$hold; sleep 0.2; echo extra3 down; echo extra3 up; sleep 1.5"
logis "$woke"$'\n'"$mo"$'\n'"$woke" && [[ ! -e $flag ]]
res $? "pause: a logo tap during the power menu does nothing, and after its cancel the state is awake with no pause"

ok=0
running
mq '0.1 shown'
live "$lt; sleep 0.5; $lh; sleep 1"
[[ $(nt | head -n 6) == "$woke"$'\n'"$pmo" && $(after) == 'exit blank-off|game-quit|start blank-off' && ! -e $flag ]] && termed ||
  { ok=1; echo "  hold: $(paste -sd '|' "$t/hooks.log")"; }
running
mq '0.1 shown' '0.3 quit'
live "$lt; sleep 1"
[[ $(nt | head -n 6) == "$woke"$'\n'"$pmo" && $(after) == 'exit blank-off|game-quit|start blank-off' && ! -e $flag ]] && ! termed ||
  { ok=1; echo "  quit line: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "pause: a logo hold (SIGTERM to the child) and the child's quit each run the game-quit hook and remove blockie-game.paused before blank-off"

running
mq '0.1 shown'
live "$lt; sleep 0.5; $tap; sleep 0.5; [ -e '$flag' ] && : > '$t/kept'; $tap; sleep 1"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nstart blank-on\nexit blank-on\n'"$pmo" && -e $flag && -e $t/kept ]] && termed
res $? "pause: a power tap ends the child and blanks with blockie-game.paused kept; the wake runs menu-on and a new pause child, no blank-off"
rm -f "$t/kept"

running
mq '0.1 shown' '2.2 shown power' '0.5 cancel'
live "$lt; sleep 0.3; $hold; sleep 1.2; echo extra3 down; echo extra3 up; sleep 0.5"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nmenu stdin power\nmenu stdin back' && -e $flag ]] && ! termed &&
  grep -q 'blockie-powermenu: shown power' "$t/err" && grep -q 'blockie-powermenu: cancel' "$t/err"
res $? "pause: a power hold writes power to the child; its cancel returns to the pause with no hook, and a logo tap then writes back"

running
mq '0.1 shown'
FAST='POLL_MS=300' live "$lt; sleep 0.6; echo inactive > '$t/scope.state'; sleep 1"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\n'"$woke" && ! -e $flag ]] && termed && grep -q 'blockie-game.scope is inactive: the pause ends' "$t/err"
res $? "pause: the scope going inactive ends the child, removes blockie-game.paused and runs blank-off"

running
mq '0.1 shown'
FAST='POLL_MS=300' live "$lt; sleep 0.6; printf 'android 1 1\n' > '$t/current'; sleep 0.8; printf 'emulation 1 1\n' > '$t/current'; sleep 1"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nstart blank-off\nflag blank-off\nexit blank-off\n'"$pmo" && -e $flag ]] && termed
res $? "pause: session-current android ends the child, blank-off keeps the scope stopped with blockie-game.paused kept; back in emulation the pause opens again"
printf 'emulation 1 1\n' > "$t/current"

ok=0
running
: > "$flag"
mq '0.1 shown'
live 'sleep 1'
logis $'start blank-off\nflag blank-off\nexit blank-off\n'"$pmo" && [[ -e $flag ]] ||
  { ok=1; echo "  active: $(paste -sd '|' "$t/hooks.log")"; }
echo inactive > "$t/scope.state"
: > "$flag"
live 'sleep 1'
[[ $(grep -v '^flag ' "$t/hooks.log") == "$woke" && ! -e $flag ]] || { ok=1; echo "  inactive: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "pause: a start with blockie-game.paused runs blank-off with the scope kept stopped, then with an active scope enters the pause (menu-on, a pause child); with the scope not active the file is removed"

running
mq '0.1 shown'
FAST='POLL_MS=300' live "$lt; sleep 0.6; echo error > '$t/scope.state'; sleep 1.2"
[[ $(nt) == "$woke"$'\n'"$pmo" && -e $flag ]] && ! termed && grep -q 'gave no state: the pause stays' "$t/err"
res $? "pause: a systemctl show with no state keeps the pause and its child, the poll retries"

running
mq '0.1 shown'
FAST='POLL_MS=300' live "$lt; sleep 0.6; mv -f '$flag' '$t/flag.gone'; sleep 1"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\n'"$woke" && ! -e $flag ]] && termed && grep -q 'blockie-game.paused is gone: the pause ends' "$t/err"
res $? "pause: blockie-game.paused removed from outside ends the pause at the next poll"

running
mq '0.1 shown'
live "$lt; sleep 0.6; kill -TERM \$(< '$t/hk.pid'); sleep 0.5"
[[ $(nt) == "$woke"$'\n'"$pmo" && ! -e $flag ]] && grep -q 'SIGTERM while paused: the pause ends' "$t/err"
res $? "pause: a SIGTERM to hotkeyd while paused removes blockie-game.paused before hotkeyd quits"

running
mq '0.1 shown'
live "$lt; sleep 0.5; $tap; sleep 0.5; mv -f '$port' '$t/port.gone'; $tap; sleep 1"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nstart blank-on\nexit blank-on\n'"$woke" && ! -e $flag ]] && termed &&
  grep -q 'is gone: the pause ends' "$t/err"
res $? "pause: a wake after the port ended while blanked ends the pause: blank-off with no flag, no new pause child"

running
echo error > "$t/scope.state"
mq '0.1 shown'
live "$lt; sleep 0.8"
[[ $(nt) == "$woke"$'\n'"$pmo" && -e $flag ]]
res $? "pause: a logo tap with blockie-game.port and no scope state from systemctl still pauses"

ok=0
running
mq '0.1 shown' '2.2 shown power' '0.5 boot reboot' '1.5 failed boot'
live "$lt; sleep 0.3; $hold; sleep 3; echo extra3 down; echo extra3 up; sleep 0.5"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nmenu stdin power\n'"$lit"$'\nsystemctl --user start --no-block blockie-reboot@reboot.service\nstart menu-on\nexit menu-on\nmenu stdin back' && -e $flag ]] &&
  ! termed && grep -q 'blockie-powermenu: failed boot: back to awake, the redirect decides' "$t/err" || { ok=1; echo "  line: $(paste -sd '|' "$t/hooks.log")"; }
echo failed > "$t/unit.state"
echo exit-code > "$t/unit.result"
running
mq '0.1 shown' '2.2 shown power' '0.5 boot reboot' '2.4 failed boot'
FAST='TOAST_MS=1500 POLL_MS=300' live "$lt; sleep 0.3; $hold; sleep 6"
[[ $(nt | tail -n 2 | paste -sd '|') == 'start menu-on|exit menu-on' && -e $flag ]] && ! termed &&
  grep -q "waiting for the pause child's failed boot" "$t/err" || { ok=1; echo "  failed unit: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$t/unit.state" "$t/unit.result"
res $ok "pause: a boot from the pause that ran and failed: the child's failed boot moves lit-frozen to paused (menu-on), the child is kept, even when hotkeyd read the failure first"

ok=0
running
mq '0.1 shown' '2.2 shown power' '0.5 boot reboot' '1.0 failed boot'
live "$lt; sleep 0.3; $hold; sleep 1.4; mv -f '$port' '$t/port.gone'; echo inactive > '$t/scope.state'; sleep 2"
[[ $(nt | tail -n 2 | paste -sd '|') == 'start blank-off|exit blank-off' && ! -e $flag ]] && termed &&
  [[ $(grep -c '^start menu-on' "$t/hooks.log") == 1 ]] &&
  [[ $(grep -c '^menu start' "$t/hooks.log") == 1 ]] && ! grep -q 'flag blank-off' "$t/hooks.log" ||
  { ok=1; echo "  port gone: $(paste -sd '|' "$t/hooks.log")"; }
echo failed > "$t/unit.state"
echo exit-code > "$t/unit.result"
running
mq '0.1 shown' '2.2 shown power' '0.5 boot reboot'
FAST='TOAST_MS=1000 POLL_MS=300' live "$lt; sleep 0.3; $hold; sleep 4.5"
termed && [[ $(grep -c '^menu start' "$t/hooks.log") == 2 && -e $flag ]] || { ok=1; echo "  hung child: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$t/unit.state" "$t/unit.result"
res $ok "pause: after a failed boot with the port gone the pause ends (SIGTERM, blank-off, no dialog over the home); a child that never says failed boot is ended at 2 x the toast time and the pause opens again"

running
mq '0.1 shown' '2.2 shown power' '0.5 failed gate'
live "$lt; sleep 0.3; $hold; sleep 1.2; echo extra3 down; echo extra3 up; sleep 0.5"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\nmenu stdin power\nmenu stdin back' && -e $flag ]] && ! termed &&
  grep -q 'blockie-powermenu: failed gate' "$t/err"
res $? "pause: the child's failed gate from the power dialog returns to the pause with no hook, and a logo tap then writes back"

ok=0
layout "$t/map" extra1.tap=game-menu
running
mq '0.1 shown' '0.3 key extra1 1' '0.05 key extra1 0'
MAP=$t/map live "$lt; sleep 1"
logis "$woke"$'\n'"$pmo"$'\nmenu stdin back' && [[ -e $flag ]] || { ok=1; echo "  paused: $(paste -sd '|' "$t/hooks.log")"; }
layout "$t/map" extra1.tap=game-menu
running
mq '0.1 shown' '2.0 key extra1 1' '0.05 key extra1 0'
MAP=$t/map live "$lt; sleep 0.3; $hold; sleep 1.5"
logis "$woke"$'\n'"$pmo"$'\nmenu stdin power' || { ok=1; echo "  menu: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "pause: the child's key extra1 lines act as extra1 in paused (its game-menu row writes back), and do nothing in menu"

printf '#!/bin/sh\necho volume-up >> "%s"\n' "$t/hooks.log" > "$hk/volume-up"
chmod 755 "$hk/volume-up"
running
mq '0.1 shown'
live "$lt; sleep 0.5; echo volup down; echo volup up; sleep 0.3"
logis "$woke"$'\n'"$pmo"$'\nvolume-up' && [[ -e $flag ]]
res $? "pause: the volume rows act while paused, as in a game"
rm -f "$hk/volume-up"

running
mq '0.1 shown' '0.8 resume'
live "$lt; sleep 0.4; mv -f '$flag' '$t/flag.gone'; mkdir '$flag'; : > '$flag/x'; sleep 1.2; $tap; sleep 0.4; $tap; sleep 0.6"
grep -qx 'systemctl --user kill --signal=SIGCONT blockie-game.scope' "$t/hooks.log" && grep -q 'cannot remove' "$t/err" &&
  [[ $(nt | tail -n 4 | paste -sd '|') == 'start blank-on|exit blank-on|start blank-off|exit blank-off' ]] &&
  ! grep -qx 'flag blank-off' "$t/hooks.log" && [[ $(grep -c '^menu start' "$t/hooks.log") == 1 ]]
res $? "T7: when blockie-game.paused cannot be removed hotkeyd sends SIGCONT to the scope itself, and a later blank and wake with the directory still there is a plain wake"
rm -rf "${flag:?}"

nogame
mkfifo "$port"
echo active > "$t/scope.state"
live "$lt; sleep 0.5"
logis "$woke"$'\ngame-menu' && [[ ! -e $flag ]]
res $? "pause: a FIFO at blockie-game.port is no running port: the logo tap runs the game-menu hook and nothing blocks"
rm -f "$port"

ok=0
running
echo 1 > "$hk/menu-on.rc"
live "$lt; sleep 1"
logis "$woke"$'\nstart menu-on\nexit menu-on\nstart menu-on\nexit menu-on\n'"$woke" && [[ ! -e $flag ]] &&
  grep -q 'menu-on failed twice: the pause ends' "$t/err" || { ok=1; echo "  menu-on: $(paste -sd '|' "$t/hooks.log")"; }
rm -f "$hk/menu-on.rc"
running
: > "$t/menu.q"
FAST='SHOWN_MS=800' live "$lt; sleep 1.5"
[[ $(nt) == "$woke"$'\n'"$pmo"$'\n'"$woke" && ! -e $flag ]] && termed || { ok=1; echo "  no shown: $(paste -sd '|' "$t/hooks.log")"; }
res $ok "T7: menu-on failing twice and a child with no shown remove blockie-game.paused before blank-off continues the scope"

bat 1 50
printf '#!/bin/sh\necho volume-up >> "%s"\n' "$t/hooks.log" > "$hk/volume-up"
chmod 755 "$hk/volume-up"
nogame
ok=0
for k in home extra2 extra3 volup voldown extra1; do
  mq '0.1 shown' '0.2 screen-off' '0.1 exit'
  live "$hold; until_n '^exit blank-on$' $t/hooks.log; sleep 0.3; echo $k down; echo $k up; until_n '^start blank-off$' $t/hooks.log 2
    sleep 0.3"
  [[ $(grep -E '^start blank-(on|off)$' "$t/hooks.log" | paste -sd ' ') == 'start blank-off start blank-on start blank-off' ]] &&
    ! grep -qx volume-up "$t/hooks.log" && grep -q "idle blank on usb: $k wakes" "$t/err" &&
    ! grep -qE "blockie-hotkeyd: $k (tap|hold|press)" "$t/err" || { ok=1; echo "  $k: $(paste -sd '|' "$t/hooks.log")"; }
done
res $ok "qs11 live: on usb after the power menu's screen-off home, extra2, extra3, volup, voldown and extra1 each wake (blank-on, then blank-off) and fire no row"
rm -f "${hk:?}/volume-up"

ok=0
for k in extra2 extra3; do
  running
  mq '0.1 shown' '0.3 screen-off' '0.1 exit'
  live "$lt; until_n '^exit blank-on$' $t/hooks.log; printf '0.1 shown\n' > $t/menu.q; sleep 0.3; echo $k down; echo $k up
    until_n '^menu mode=pause$' $t/hooks.log 2; sleep 0.3"
  [[ $(grep -c '^start menu-on$' "$t/hooks.log") == 2 && $(grep -c '^menu mode=pause$' "$t/hooks.log") == 2 &&
    $(grep -c '^start blank-off$' "$t/hooks.log") == 1 && -e $flag ]] && ! grep -q '^menu stdin' "$t/hooks.log" &&
    ! grep -q 'no pause child to tell' "$t/err" && grep -q "idle blank on usb: $k wakes" "$t/err" ||
    { ok=1; echo "  $k: $(paste -sd '|' "$t/hooks.log")"; }
done
res $ok "qs11 live: on usb after the pause box's screen-off extra2 and extra3 wake into the pause (menu-on, a new pause child, no blank-off, blockie-game.paused kept) and the logo's release writes no back"

running
mq '0.1 shown' '0.3 screen-off' '0.1 exit'
live "$lt; until_n '^exit blank-on$' $t/hooks.log; mv -f '$port' '$t/port.gone'; sleep 0.3; echo extra2 down; echo extra2 up
  until_n '^start blank-off$' $t/hooks.log 2; sleep 0.3"
[[ $(grep -c '^menu mode=pause$' "$t/hooks.log") == 1 && $(grep -c '^start blank-off$' "$t/hooks.log") == 2 && ! -e $flag ]] &&
  grep -q 'is gone: the pause ends' "$t/err" && grep -q 'idle blank on usb: extra2 wakes' "$t/err"
res $? "qs11 live: a key wake after the pause box's screen-off with the port gone ends the pause: blank-off shows the home, no new pause child, blockie-game.paused removed"

running
mq '0.1 shown' '0.3 screen-off' '0.1 exit'
live "$lt; until_n '^exit blank-on$' $t/hooks.log; printf 'android 1 1\n' > '$t/current'; sleep 0.3; echo extra2 down; echo extra2 up
  until_n '^start blank-off$' $t/hooks.log 2; sleep 0.3"
[[ $(grep -c '^start menu-on$' "$t/hooks.log") == 1 && $(grep -c '^start blank-off$' "$t/hooks.log") == 2 && -e $flag ]] &&
  grep -qx 'flag blank-off' "$t/hooks.log" && grep -q 'idle blank on usb: extra2 wakes' "$t/err"
res $? "qs11 live: a key wake after the pause box's screen-off in another session keeps the pause and wakes to awake: blank-off with blockie-game.paused kept, no menu-on"
printf 'emulation 1 1\n' > "$t/current"

running
mq '0.1 shown' '2.2 shown power' '0.5 screen-off' '0.1 exit'
live "$lt; sleep 0.3; $hold; until_n '^exit blank-on$' $t/hooks.log; printf '0.1 shown\n' > $t/menu.q; sleep 0.3; echo extra3 down
  echo extra3 up; until_n '^menu mode=pause$' $t/hooks.log 2; sleep 0.3"
[[ $(grep -c '^menu mode=pause$' "$t/hooks.log") == 2 && $(grep -c '^start blank-off$' "$t/hooks.log") == 1 && -e $flag ]] &&
  grep -qx 'menu stdin power' "$t/hooks.log" && grep -q 'blockie-powermenu: shown power' "$t/err" &&
  grep -q 'idle blank on usb: extra3 wakes' "$t/err"
res $? "qs11 live: on usb after the screen-off of the power dialog over the pause a logo down wakes into the pause: menu-on, a new pause child, no blank-off"
nogame
rm -f "$hk/game-menu" "$hk/game-quit"
printf 'nobody-here 1 1\n' > "$t/current"

for h in blank-on blank-off screen-on menu-on; do
  echo 0.1 > "$hk/$h.sleep"
done
printf 'nobody-here 1 1\n' > "$t/current"
up="sleep 0.4; $tap"
offs='^systemctl --user start --no-block blockie-poweroff.service$'

bat 0 50
: > "$t/queue"
FAST=$fast live "$up; until_n 'refused test' $t/err"
g=$(gap "$(tms helper | head -n 1)" "$(tms 'exit blank-on' | head -n 1)")
[[ $(ev) == "start blank-off start blank-on helper first" ]] && ((g >= 280)) &&
  grep -q 'sleep first: capacity 50 voltage_now 3900000 online 0$' "$t/err" &&
  grep -q 'refused test: capacity 50 voltage_now 3900000 online 0, suspend_stats success' "$t/err"
res $? "sleep: a tap runs blank-on and one helper call with first $g ms after it, entry and result logged with capacity, voltage and online"

echo '5 0 slept power 5' > "$t/queue"
FAST=$fast live "$up; until_n '^start blank-off$' $t/hooks.log 2; sleep 0.3"
g=$(gap "$(tms 'start blank-off' | sed -n 2p)" "$(tms helper | head -n 1)")
[[ $(ev) == "start blank-off start blank-on helper first start blank-off" ]] && ((g >= 950)) &&
  grep -q 'no key event in 1000 ms: wake' "$t/err"
res $? "sleep: slept power with no key event wakes after the lost event wait ($g ms after the helper start)"

echo '5 0 slept power 5' > "$t/queue"
FAST=$fast live "$up; until_n 'slept power' $t/err; $tap; sleep 2; $tap; until_n '^start blank-on$' $t/hooks.log 2; sleep 0.2"
[[ $(ev) == "start blank-off start blank-on helper first start blank-off start blank-on"* ]]
res $? "sleep: a power tap inside the wake window wakes once, a tap after it blanks again"

echo '5 0 slept power 5' > "$t/queue"
FAST=$fast live "$up; until_n 'slept power' $t/err; $tap; $tap; until_n '^start blank-off$' $t/hooks.log 2; sleep 1"
[[ $(ev) == "start blank-off start blank-on helper first start blank-off" ]]
res $? "sleep: two taps queued after a power wake give one blank-off and no blank-on"

lines 6 '1 0 slept rtc 1' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 6; sleep 0.2"
read -ra gs <<< "$(gaps)"
((${#gs[@]} == 5 && gs[0] < 1000 && gs[1] < 1000 && gs[2] < 1000 && gs[3] < 1000 && gs[4] >= 1150)) &&
  grep -q 'resleep in 1200 ms' "$t/err"
res $? "sleep: an rtc wake sleeps again after the resleep wait, which grows x4 after 5 wakes in 60 s (gaps ${gs[*]})"

lines 6 '720 0 slept rtc 720' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 6; sleep 0.2"
read -ra gs <<< "$(gaps)"
((${#gs[@]} == 5 && gs[0] < 1000 && gs[1] < 1000 && gs[2] < 1000 && gs[3] < 1000 && gs[4] < 1000)) &&
  ! grep -q 'resleep in 1200' "$t/err"
res $? "sleep: 6 rtc wakes 12 min apart in boot time keep the resleep wait (gaps ${gs[*]})"

lines 7 '0 0 busy step=suspend errno=-16 grew=fail' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 7; sleep 0.1"
read -ra gs <<< "$(gaps)"
((${#gs[@]} == 6 && gs[0] < 1000 && gs[4] < 1000 && gs[5] >= 1900)) && grep -q 'retry 6 in 2000 ms' "$t/err"
res $? "sleep: busy retries 5 times at the short wait, then at the slow one (gaps ${gs[*]})"

echo '0 0 refused deadman' > "$t/queue"
FAST=$fast live "$up; until_n 'refused deadman' $t/err; sleep 1"
[[ $(calls) == 1 ]]
res $? "sleep: refused is not retried until the next tap"

: > "$t/queue"
printf 'power hold=60000 none\n' > "$t/usr/test-q.conf"
printf 'test-q 1 1\n' > "$t/current"
FAST="$fast SETTLE_MS=1500" live "$up; until_n '^exit blank-on$' $t/hooks.log; echo power down; sleep 1.8; echo power up; sleep 0.5"
rm -f "$t/usr/test-q.conf"
printf 'nobody-here 1 1\n' > "$t/current"
[[ $(ev) == "start blank-off start blank-on start blank-off" ]]
res $? "sleep: a power down during the settle wait holds it off, no helper call while the key is down"

echo '5 0 slept power 5' > "$t/queue"
: > "$t/menu.q"
FAST=$fast live "$up; until_n 'slept power' $t/err; echo power down; until_n '^menu start' $t/hooks.log; sleep 0.6; echo power up; sleep 0.6"
[[ $(ev) == "start blank-off start blank-on helper first start menu-on menu start from=dark state=$t/boot.state" ]]
res $? "sleep: a hold right after a power wake opens the menu from dark: menu-on, then the child, no blank-off, no helper call in menu"

: > "$t/queue"
mq '0.1 shown' '0.2 screen-off' '1 exit'
FAST=$fast live "sleep 0.4; echo power down; sleep 1.3; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2"
[[ $(ev) == "start blank-off start menu-on menu start from=awake state=$t/boot.state start blank-on menu exit helper first" ]]
res $? "sleep: screen-off from the menu blanks and sleeps only once the child is gone"

: > "$t/queue"
FAST=$fast live "sleep 0.4; echo power down; sleep 0.9; date +%s%3N > $t/rel; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2"
g=$(gap "$(tms helper | head -n 1)" "$(cat "$t/rel" 2> /dev/null)")
[[ $(ev) == "start blank-off start blank-on helper first" ]] && ((g >= 280))
res $? "sleep: a press released at 0.9 s blanks at the release and sleeps one settle wait after it ($g ms)"

bat 1 50
FAST=$fast live "$up; sleep 1.5; date +%s%3N > $t/rel; echo 0 > $t/psys/$on; until_n '^helper' $t/hooks.log; sleep 0.2"
g=$(gap "$(tms helper | head -n 1)" "$(cat "$t/rel" 2> /dev/null)")
[[ $(calls) == 1 ]] && ((g >= 0)) && grep -q 'on usb power: blanked awake' "$t/err"
res $? "sleep: on usb power the tap only blanks, the sleep starts once online reads 0"

bat 1 50
: > "$t/knob"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log; sleep 0.2"
[[ $(calls) == 1 ]]
res $? "sleep: the knob lets it sleep on usb power"

bat 0 50
rm -f "$t/knob"
echo '5 0 slept plug 5' > "$t/queue"
FAST=$fast live "$up; until_n 'slept plug' $t/err; sleep 1.5"
r1=$(calls)
grep -q 'on usb power: blanked awake' "$t/err" || r1=x
bat 0 50
: > "$t/knob"
FAST=$fast live "$up; until_n 'slept plug' $t/err; until_n '^helper' $t/hooks.log 2; sleep 0.2"
r2=$(calls)
rm -f "$t/knob"
[[ $r1 == 1 && $r2 -ge 2 ]]
res $? "sleep: a plug wake stays blanked awake on usb power, with the knob it sleeps again (calls $r1, $r2)"

bat 0 50
printf '%s\n' '5 0 slept power 5' '5 0 slept rtc 5' > "$t/queue"
FAST=$fast live "$up; until_n 'slept power' $t/err; echo volup down; echo volup up; until_n '^helper' $t/hooks.log 2; sleep 0.2"
[[ $(ev) == "start blank-off start blank-on helper first helper"* && $(ev) != *"helper first"*"blank-off"* ]] &&
  grep -q 'only a volume up event: back to sleep' "$t/err"
res $? "sleep: a power wake with only a volume up event sleeps again"

echo '0 3 slept rtc 1' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log; sleep 0.2; $tap; until_n '^helper term$' $t/hooks.log; until_n '^start blank-off$' $t/hooks.log 2; sleep 0.2"
[[ $(ev) == "start blank-off start blank-on helper first"*"start blank-off"* ]] && grep -qx 'helper term' "$t/hooks.log" &&
  grep -q 'SIGTERM to blockie-sleep' "$t/err"
res $? "sleep: a tap while the helper runs sends it SIGTERM and wakes"

echo hang > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 2; sleep 0.2"
[[ $(calls) == 2 ]] && grep -q 'still running after 1000 ms: killed' "$t/err" && grep -q 'retry 1 in 300 ms' "$t/err"
res $? "sleep: a helper that never exits is killed at the limit and retried"

ok=0
poff="start screen-on systemctl --user start --no-block blockie-poweroff.service"
bat 0 3
echo '5 0 slept rtc 5' > "$t/queue"
FAST=$fast live "$up; until_n '$offs' $t/hooks.log; sleep 0.3"
[[ $(ev) == "start blank-off start blank-on helper first $poff" ]] && grep -q 'capacity 3 on battery: powering off' "$t/err" ||
  { ok=1; echo "  rtc at 3 %: $(ev)"; }
bat 0 4
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 2; sleep 0.3"
[[ $(calls) -ge 2 && $(ev) != *screen-on* ]] || { ok=1; echo "  rtc at 4 %: $(ev)"; }
bat 0 3
echo '5 0 slept power 5' > "$t/queue"
FAST=$fast live "$up; until_n '^start blank-off$' $t/hooks.log 2; sleep 0.3"
[[ $(ev) == "start blank-off start blank-on helper first start blank-off" ]] || { ok=1; echo "  power at 3 %: $(ev)"; }
bat 1 3
: > "$t/knob"
echo '5 0 slept rtc 5' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 2; sleep 0.3"
rm -f "$t/knob"
[[ $(calls) -ge 2 && $(ev) != *screen-on* ]] || { ok=1; echo "  usb at 3 %: $(ev)"; }
bat 0 3
lines 6 '0 0 busy step=suspend errno=-16 grew=fail' > "$t/queue"
FAST=$fast live "$up; until_n '^helper' $t/hooks.log 6; until_n '$offs' $t/hooks.log; sleep 0.3"
[[ $(calls) == 6 && $(ev) == *" $poff" ]] || { ok=1; echo "  busy at 3 %: $(ev)"; }
res $ok "sleep: at 3 % on battery an rtc wake or a slow retry tick powers off through screen-on; 4 %, a power wake or usb power do not"

bat 0 50
echo '0 0 slept rtc 1' > "$t/queue"
FAST="$fast RESLEEP_MS=3000" live "$up; until_n 'slept rtc' $t/err; $tap; $tap; until_n '^start blank-off$' $t/hooks.log 2; sleep 0.5"
[[ $(ev) == "start blank-off start blank-on helper first start blank-off"* && $(grep -c '^start blank-on$' "$t/hooks.log") == 1 ]]
res $? "sleep: a slept line with no clock jump still counts as a resume, so taps after it only wake"

lines 31 '15 0 slept rtc 15' > "$t/queue"
FAST="$fast RESLEEP_MS=20" live "$up; until_n '^helper' $t/hooks.log 30; sleep 0.6"
[[ $(calls) == 30 ]] && grep -q '30 wakes in 10 min: blanked awake' "$t/err"
res $? "sleep: 30 wakes in 10 min of boot time hold it blanked awake"

: > "$t/queue"
FAST=$fast live "until_n '^exit blank-off$' $t/hooks.log; echo 30 > $t/slept; $tap; until_n '^start blank-off$' $t/hooks.log 2; sleep 0.5"
[[ $(ev) == "start blank-off start blank-off" ]] && grep -q 'resume: ' "$t/err"
res $? "sleep: a sleep seen while awake runs blank-off again and the tap after it does not blank"

bat 1 50
ok=0
BLOCKIE_HOTKEYD_KNOB=$t/knob run 'echo power down; echo power up; echo home down; sleep 0.5; echo home up; echo volup down; echo volup up
  echo extra3 down; echo extra3 up; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power tap blank\ngrab\nvbus\naction power tap blank\nungrab\nresync' ]] ||
  { ok=1; echo "  tap blank on usb: $(paste -sd '|' "$t/out")"; }
for c in battery knob; do
  : > "$t/queue"
  mq '0.1 shown' '0.2 screen-off' '1 exit'
  if [[ $c == knob ]]; then
    bat 1 50
    : > "$t/knob"
  else
    bat 0 50
  fi
  FAST=$fast live "sleep 0.4; echo power down; sleep 1.3; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2; echo home down
    echo home up; sleep 0.5"
  [[ $(ev) == "start blank-off start menu-on menu start from=awake state=$t/boot.state start blank-on menu exit helper first" ]] &&
    ! grep -q 'idle blank on usb' "$t/err" || { ok=1; echo "  $c: $(ev)"; }
done
rm -f "${t:?}/knob"
bat 0 50
res $ok "qs11 live: a power tap blank on usb stays power only (home, volup, extra3 do nothing); after the power menu's screen-off on battery or with the knob a home press does not wake and the helper runs"

for h in blank-on blank-off screen-on menu-on; do
  rm -f "$hk/$h.sleep"
done

BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_LONG_MS=300 BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys \
  BLOCKIE_HOTKEYD_INPUT=/dev/null BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_MENU=$t/none timeout -k 5 60 python3 - "$bin" > "$t/drain.out" 2>&1 << 'EOF'
import contextlib
import importlib.machinery
import importlib.util
import io
import sys
import time

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
GLib = m.GLib


class Ev:
    def __init__(self, code, value):
        self.type, self.code, self.value = 1, code, value


class Dev:
    def __init__(self, batches, held):
        self.name = "mtk-pmic-keys"
        self.q = [[Ev(*e) for e in b] for b in batches]
        self.held = set(held)
        self.calls = []

    def read(self):
        if not self.q:
            raise BlockingIOError
        return iter(self.q.pop(0))

    def active_keys(self):
        self.calls.append((len(self.q), sorted(self.held)))
        return list(self.held)

    def grab(self):
        pass

    def ungrab(self):
        pass


def case(name, batches, held, before=False, run_ms=0):
    print(f"case {name}: batches {batches}, EVIOCGKEY held {sorted(held)}", file=sys.stderr, flush=True)
    loop = GLib.MainLoop()
    d = m.Hotkeyd(loop)
    dev = Dev(batches, held)
    d.devices = {"/dev/input/event0": (dev, {116: "power", 115: "volup"}, 0)}
    d.wanted = d.applied = "blanked"
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        if before:
            d.handle("power", 1)
            time.sleep(0.01)
        d.resume()
        if run_ms:
            GLib.timeout_add(run_ms, loop.quit)
            loop.run()
    k = d.keys["power"]
    seen = (f"{name}: printed {out.getvalue().splitlines()}, EVIOCGKEY calls (events still queued, held)"
            f" {dev.calls}, events left {len(dev.q)}, wanted {d.wanted}, applied {d.applied}, power down {k.down},"
            f" hold timer {bool(k.timer)}")
    print(seen, file=sys.stderr, flush=True)
    return d, dev, out.getvalue().splitlines(), seen


bad = []
d, dev, out, seen = case("queued tap", [[(116, 1)], [(116, 0)]], [])
if out.count("action power tap blank") != 1 or d.wanted != "awake" or dev.calls[:1] != [(0, [])]:
    bad.append(seen)
d, dev, out, seen = case("queued down, held", [[(116, 1)]], [116], run_ms=3700)
if "action power hold=1000 menu" not in out or "action power hold=3000 unit blockie-poweroff.service" not in out \
        or "action power tap blank" in out or dev.calls[:1] != [(0, [116])] or not d.keys["power"].down:
    bad.append(seen)
d, dev, out, seen = case("down after the resume, up by EVIOCGKEY", [[(116, 1)]], [])
if out.count("action power tap blank") != 1 or d.wanted != "awake" or d.keys["power"].down:
    bad.append(seen)
d, dev, out, seen = case("down before the resume, up by EVIOCGKEY", [], [], before=True)
if any(o.startswith("action power") for o in out) or d.keys["power"].down or d.keys["power"].timer \
        or d.wanted != "blanked":
    bad.append(seen)
for b in bad:
    print(f"FAILED {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/drain.out"
res $r "resume: queued key events are drained before EVIOCGKEY, a down read after the resume and up is a release, an older one is cleared"

BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_INPUT=/dev/null \
  BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_GRAB_RETRY_MS=50 timeout -k 5 60 python3 - "$bin" > "$t/grab.out" 2>&1 << 'EOF'
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import os
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
GLib = m.GLib
P0 = "/dev/input/event0"


class Dev:
    def __init__(self, busy, err=errno.EBUSY):
        self.busy = busy
        self.err = err
        self.calls = 0
        self.closed = False

    def grab(self):
        self.calls += 1
        if self.busy:
            self.busy -= 1
            raise OSError(self.err, "Device or resource busy" if self.err == errno.EBUSY else "No such device")

    def ungrab(self):
        pass

    def active_keys(self):
        return []

    def close(self):
        self.closed = True


class Done:
    def wait_finish(self, res):
        pass

    def get_if_exited(self):
        return True

    def get_exit_status(self):
        return 0


def case(name, dev, step=None, run_ms=400):
    loop = GLib.MainLoop()
    d = m.Hotkeyd(loop)
    d.devices = {P0: (dev, {116: "power"}, 0)}
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        d.set_grab("all")
        if step:
            step(d)
        GLib.timeout_add(run_ms, loop.quit)
        loop.run()
    out = err.getvalue()
    seen = (f"{name}: grab calls {dev.calls}, retry set {sorted(d.regrab)}, timer {bool(d.regrab_timer)},"
            f" applied {d.applied}, log {out.splitlines()}")
    print(seen, file=sys.stderr, flush=True)
    return d, out, seen


def swap(d, new):
    d.devices[P0] = (new, {116: "power"}, 0)


def applied(d):
    d.wanted = "blanked"
    d.busy = True
    d.hook_done(Done(), None, "blanked")


bad = []
a = Dev(2)
d, out, seen = case("EBUSY twice", a)
if a.calls != 3 or out.count("grab: Device or resource busy") != 1 or out.count("grabbed on retry") != 1 \
        or d.regrab or d.regrab_timer:
    bad.append(seen)
a = Dev(100)
d, out, seen = case("awake after one failure", a, lambda d: d.set_grab(""))
if a.calls != 1 or d.regrab or d.regrab_timer:
    bad.append(seen)
a = Dev(100)
d, out, seen = case("dropped mid retry", a, lambda d: GLib.timeout_add(75, lambda: d.drop(P0) or False))
if a.calls > 3 or d.regrab or d.regrab_timer:
    bad.append(seen)
a, b = Dev(100), Dev(0)
d, out, seen = case("replaced at the same path", a, lambda d: swap(d, b))
if a.calls != 1 or b.calls != 0 or d.regrab or d.regrab_timer:
    bad.append(f"{seen}, new node grab calls {b.calls}")
P1 = "/dev/input/event1"
REAL = os.path.realpath(os.path.join(m.SYSFS, "class/input", "event1"))


def extra(d, dev, real):
    d.extra[P1] = (dev, real, 0)
    d.grab(dev, P1)


e = Dev(100)
d, out, seen = case("extra node replaced in sysfs", Dev(0), lambda d: extra(d, e, "/elsewhere"))
if e.calls != 1 or not e.closed or P1 in d.extra or d.regrab or d.regrab_timer:
    bad.append(f"{seen}, extra grab calls {e.calls}, closed {e.closed}")
e = Dev(100, errno.ENODEV)
d, out, seen = case("extra node gone, ENODEV", Dev(0), lambda d: extra(d, e, REAL))
if e.calls != 2 or not e.closed or P1 in d.extra or d.regrab or d.regrab_timer:
    bad.append(f"{seen}, extra grab calls {e.calls}, closed {e.closed}")
m.GRAB_RETRY_MS = 10000
a = Dev(1)
d, out, seen = case("blank-on applied", a, applied, run_ms=100)
if a.calls != 2 or d.regrab or d.regrab_timer or d.applied != "blanked":
    bad.append(seen)
for x in bad:
    print(f"FAILED {x}", file=sys.stderr)
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/grab.out"
res $r "grab: an EBUSY node is retried every 250 ms while blanked, one log line; waking, a dropped or replaced node and a gone extra node end it; blank-on applied retries at once"

BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_INPUT=/dev/null BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep \
  timeout -k 5 60 python3 - "$bin" > "$t/mgrab.out" 2>&1 << 'EOF'
import contextlib
import importlib.machinery
import importlib.util
import io
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


class Dev:
    def __init__(self, name, ev):
        self.name = name
        self.ev = ev

    def grab(self):
        self.ev.append(f"grab {self.name}")

    def ungrab(self):
        self.ev.append(f"ungrab {self.name}")

    def active_keys(self):
        self.ev.append(f"keys {self.name}")
        return []


def make(state):
    ev = []
    d = m.Hotkeyd(m.GLib.MainLoop())
    d.devices = {"/dev/input/event0": (Dev("mtk-pmic-keys", ev), {116: "power"}, 0),
                 "/dev/input/event1": (Dev("AYANEO Controller", ev), {316: "extra1"}, 0),
                 "/dev/input/event2": (Dev("odm:gpio_keys", ev), {0x2F2: "extra3"}, 0)}
    d.spawn = lambda name, ms: (ev.append(f"hook {name}"), (None, True, 0))[1]
    d.wanted = d.applied = state
    d.set_grab("all" if state == "blanked" else "")
    ev.clear()
    return d, ev


bad = []
keys = ["keys mtk-pmic-keys", "keys AYANEO Controller", "keys odm:gpio_keys"]
ungrab = ["ungrab mtk-pmic-keys", "ungrab AYANEO Controller", "ungrab odm:gpio_keys"]
with contextlib.redirect_stderr(io.StringIO()):
    d, ev = make("blanked")
    d.open_menu()
    want = keys + ["grab mtk-pmic-keys", "grab odm:gpio_keys", "hook menu-on"]
    if sorted(ev[:3]) != sorted(ungrab) or ev[3:] != want or d.menu_from != "dark" or d.grabbed != "keys":
        bad.append(f"from blanked: {ev}, from {d.menu_from}")
    ev.clear()
    d.applied = "menu"
    d.want("awake")
    if sorted(ev[:3]) != sorted(ungrab) or ev[3:] != keys + ["hook blank-off"] or d.grabbed:
        bad.append(f"leaving: {ev}")
    d, ev = make("awake")
    d.open_menu()
    if ev != ["grab mtk-pmic-keys", "grab odm:gpio_keys", "hook menu-on"] or d.menu_from != "awake":
        bad.append(f"from awake: {ev}, from {d.menu_from}")
    for state in ("menu", "lit-frozen"):
        d, ev = make(state)
        d.open_menu()
        if ev:
            bad.append(f"{state}: {ev}")
    for state, eaten in (("blanked", True), ("menu", True), ("lit-frozen", True), ("awake", False)):
        d, ev = make(state)
        d.handle("home", 1)
        k = d.keys["home"]
        if k.consumed != eaten or bool(k.timer) == eaten:
            bad.append(f"home down in {state}: consumed {k.consumed}, hold timer {bool(k.timer)}")
        d.handle("home", 0)
for b in bad:
    print(f"FAILED {b}")
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/mgrab.out"
res $r "menu grab: entering the menu from blanked ungrabs and resyncs before it grabs the key nodes (not the pad) and runs menu-on; leaving ungrabs and resyncs; no menu-on from menu or lit-frozen; a home down is consumed with no hold timer in blanked, menu and lit-frozen, and arms its hold when awake"

BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_INPUT=/dev/null BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep \
  BLOCKIE_HOTKEYD_GRAB_RETRY_MS=50 timeout -k 5 60 python3 - "$bin" > "$t/lgrab.out" 2>&1 << 'EOF'
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


class Dev:
    def __init__(self, name, ev, busy=0):
        self.name = name
        self.ev = ev
        self.busy = busy

    def grab(self):
        if self.busy:
            self.busy -= 1
            self.ev.append(f"busy {self.name}")
            raise OSError(errno.EBUSY, "Device or resource busy")
        self.ev.append(f"grab {self.name}")

    def ungrab(self):
        self.ev.append(f"ungrab {self.name}")

    def active_keys(self):
        self.ev.append(f"keys {self.name}")
        return []


ev = []
loop = m.GLib.MainLoop()
d = m.Hotkeyd(loop)
d.devices = {"/dev/input/event0": (Dev("mtk-pmic-keys", ev), {116: "power"}, 0),
             "/dev/input/event1": (Dev("AYANEO Controller", ev, busy=3), {316: "extra1"}, 0)}
d.spawn = lambda name, ms: (ev.append(f"hook {name}"), (None, True, 0))[1]
d.wanted = d.applied = "menu"
d.set_grab("keys")
ev.clear()
err = io.StringIO()
bad = []
with contextlib.redirect_stderr(err):
    d.want("lit-frozen")
    m.GLib.timeout_add(400, loop.quit)
    loop.run()
    head = ["keys mtk-pmic-keys", "keys AYANEO Controller", "grab mtk-pmic-keys", "busy AYANEO Controller",
            "hook screen-on"]
    if sorted(ev[:2]) != ["ungrab AYANEO Controller", "ungrab mtk-pmic-keys"] or ev[2:7] != head \
            or ev[7:] != ["busy AYANEO Controller", "busy AYANEO Controller", "grab AYANEO Controller"] \
            or d.regrab or d.regrab_timer or d.grabbed != "all" or "lit-frozen: 2 key nodes and 0 more grabbed" not in err.getvalue() \
            or err.getvalue().count("grabbed on retry") != 1:
        bad.append(f"entering lit-frozen with the pad held: {ev}, grabbed {d.grabbed}, log {err.getvalue().splitlines()}")
    ev.clear()
    d.applied = "lit-frozen"
    d.want("awake")
    if sorted(ev[:2]) != ["ungrab AYANEO Controller", "ungrab mtk-pmic-keys"] \
            or ev[2:] != ["keys mtk-pmic-keys", "keys AYANEO Controller", "hook blank-off"] or d.grabbed:
        bad.append(f"leaving lit-frozen: {ev}, grabbed {d.grabbed}")


class Gone:
    def wait_finish(self, res):
        pass

    def get_if_exited(self):
        return True

    def get_exit_status(self):
        return 0


m.GRAB_RETRY_MS = 10000
ev = []
d = m.Hotkeyd(loop)
d.devices = {"/dev/input/event0": (Dev("mtk-pmic-keys", ev), {116: "power"}, 0),
             "/dev/input/event1": (Dev("AYANEO Controller", ev, busy=1), {316: "extra1"}, 0)}
d.spawn = lambda name, ms: (ev.append(f"hook {name}"), (None, True, 0))[1]
d.wanted = d.applied = "lit-frozen"
child = m.Menu(Gone())
d.menu = d.last = child
with contextlib.redirect_stderr(io.StringIO()):
    d.set_grab("all")
    held = (sorted(d.regrab), bool(d.regrab_timer))
    ev.clear()
    d.menu_exited(Gone(), None, child)
if held != (["/dev/input/event1"], True) or ev != ["grab AYANEO Controller"] or d.regrab or d.regrab_timer or d.menu:
    bad.append(f"child exit: held before {held}, then {ev}, retry set {sorted(d.regrab)}, timer {bool(d.regrab_timer)}")


class Stuck:
    def __init__(self):
        self.signals = []

    def send_signal(self, sig):
        self.signals.append(sig)

    def force_exit(self):
        self.signals.append(9)


runs = []
d = m.Hotkeyd(loop)
d.spawn = lambda name, ms: (None, True, 0)
d.run = lambda argv: runs.append(argv)
d.wanted = d.applied = "awake"
child = m.Menu(Stuck())
child.shown = True
d.menu = d.last = child
err = io.StringIO()
with contextlib.redirect_stderr(err):
    d.end_menu(child)
    d.kill_menu(child)
    k = d.keys["power"]
    k.down = True
    k.down_at = m.time.monotonic() + 1
    d.fire("power", "hold=3000", ("unit", "blockie-poweroff.service"), True)
if child.proc.signals != [15, 9] or child.kill or d.menu is not child or runs != [[m.BACKLIGHT, "off"]] \
        or "power hold=3000: unit blockie-poweroff.service" not in err.getvalue() or "skipped" in err.getvalue():
    bad.append(f"killed, not reaped: signals {child.proc.signals}, runs {runs}, log {err.getvalue().splitlines()}")
for b in bad:
    print(f"FAILED {b}")
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/lgrab.out"
res $r "lit-frozen grab: from the menu it ungrabs and resyncs, then takes every node; the pad the child still holds gets EBUSY and is taken on the retry once it is free, and at once in the child's exit; leaving for awake ungrabs and resyncs; a child killed but not yet reaped no longer skips the 3000 ms fallback"

S=$t/sys
sysnode() {
  local d=$S/devices/$1
  mkdir -p "$d/id" "$d/event${1##*input}"
  printf '%s\n' "$2" > "$d/id/bustype"
  printf '%s\n' "$3" > "$d/id/vendor"
  printf '%s\n' "$4" > "$d/id/product"
  printf '%s\n' "$5" > "$d/phys"
}
sysnode virtual/input/input5 0019 4001 0428 ayaneo-gamepad/input0
sysnode virtual/input/input6 0019 0001 0428 ayaneo-gamepad/input0
sysnode virtual/input/input7 0019 4001 0428 ""
sysnode virtual/input/input8 0019 4001 0428 ayaneo-gamepad/input0
sysnode platform/odm/odm:gpio_keys/input/input0 0019 0001 0001 gpio-keys/input0
mkdir -p "$S/devices/virtual/input/input9/event9"
BLOCKIE_HOTKEYD_SYSFS=$S timeout -k 5 60 python3 - "$bin" "$S" > "$t/phys.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
s = sys.argv[2]
cases = [
    ("virtual/input/input5/event5", "AYANEO Controller", True),
    ("virtual/input/input6/event6", "AYANEO Controller", False),
    ("virtual/input/input7/event7", "AYANEO Controller", False),
    ("virtual/input/input8/event8", "uinput mirror", False),
    ("virtual/input/input9/event9", "AYANEO Controller", False),
    ("platform/odm/odm:gpio_keys/input/input0/event0", "odm:gpio_keys", True),
]
bad = [c[0] for c in cases if m.Hotkeyd.physical(None, f"{s}/devices/{c[0]}", c[1]) != c[2]]
if m.Hotkeyd.physical(None, "/elsewhere/input5/event5", "AYANEO Controller"):
    bad.append("outside")
print(bad)
sys.exit(1 if bad else 0)
EOF
res $? "virtual nodes stay out except the AYANEO Controller by name, ids and phys"
fi

mkdir -p "$t/krun"
BLOCKIE_HOTKEYD_CURRENT=$t/kcur BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_INPUT=/dev/null BLOCKIE_HOTKEYD_KNOB=$t/kknob \
  BLOCKIE_HOTKEYD_TABLES=$t/none BLOCKIE_HOTKEYD_BUTTONS=$t/nomap BLOCKIE_HOTKEYD_SLEEP=$t/none BLOCKIE_HOTKEYD_MENU=$t/none \
  BLOCKIE_HOTKEYD_UP_MS=200 XDG_RUNTIME_DIR=$t/krun timeout -k 5 60 python3 - "$bin" > "$t/qs11.out" 2>&1 << 'EOF'
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import os
import sys
import time
import types

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
GLib = m.GLib
NODE = m.Node
ctx = GLib.MainContext.default()
removed = set()
source_remove = GLib.source_remove
GLib.source_remove = lambda source: (removed.add(source), source_remove(source))[1]
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
KEY_POWER, HOME, BTN_SOUTH, BTN_EAST, BTN_TOUCH, BTN_MODE = 116, 0x2F1, 0x130, 0x131, 0x14A, 316
ABS_HAT0Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x11, 0x35, 0x36, 0x39
PMIC, PAD, GPIO, TOUCH, PAD2 = (f"/dev/input/event{n}" for n in range(5))
SYN = (EV_SYN, 0, 0)
TOUCH_DOWN = [(EV_KEY, BTN_TOUCH, 1), (EV_ABS, ABS_MT_TRACKING_ID, 7), (EV_ABS, ABS_MT_POSITION_X, 120),
              (EV_ABS, ABS_MT_POSITION_Y, 340), SYN]
TOUCH_UP = [(EV_ABS, ABS_MT_TRACKING_ID, -1), (EV_KEY, BTN_TOUCH, 0), SYN]
UNGRAB = ["ungrab mtk-pmic-keys", "ungrab AYANEO Controller", "ungrab odm:gpio_keys"]
CLOSED = ["close hyn_ts", "close Wireless Controller"]
RELEASED = sorted(UNGRAB + CLOSED)
online = os.path.join(m.SYSFS, m.ONLINE)
os.makedirs(os.path.dirname(online), exist_ok=True)
with open(m.CURRENT, "w") as f:
    f.write("emulation 1 1\n")


def key(code, value):
    return [(EV_KEY, code, value), SYN]


def no_open(path):
    raise AssertionError(f"evdev.InputDevice({path})")


class Ev:
    def __init__(self, type, code, value):
        self.type, self.code, self.value = type, code, value


class Dev:
    def __init__(self, name, ev, caps, axes=()):
        self.name = name
        self.ev = ev
        self.fd, self.w = os.pipe()
        self.caps = list(caps)
        self.abs = dict.fromkeys(axes, 0)
        self.q = []
        self.held = set()
        self.broken = False
        self.keys_broken = False
        self.slow = 0

    def push(self, *evs):
        for t, c, v in evs:
            if t == EV_KEY and v:
                self.held.add(c)
            elif t == EV_KEY:
                self.held.discard(c)
            elif t == EV_ABS and c in self.abs:
                self.abs[c] = v
        self.q.append([Ev(*e) for e in evs])
        os.write(self.w, b"x")

    def fail(self):
        self.broken = True
        os.write(self.w, b"x")

    def read(self):
        if self.broken:
            raise OSError(errno.ENODEV, "No such device")
        if not self.q:
            raise BlockingIOError
        os.read(self.fd, 1)
        return iter(self.q.pop(0))

    def active_keys(self):
        if self.keys_broken:
            raise OSError(errno.ENODEV, "No such device")
        return sorted(self.held)

    def absinfo(self, axis):
        return types.SimpleNamespace(value=self.abs[axis])

    def capabilities(self, absinfo=True):
        return {EV_KEY: self.caps, EV_ABS: list(self.abs)}

    def grab(self):
        self.ev.append(f"grab {self.name}")

    def ungrab(self):
        time.sleep(self.slow)
        self.ev.append(f"ungrab {self.name}")

    def close(self):
        time.sleep(self.slow)
        self.ev.append(f"close {self.name}")


class Proc:
    def send_signal(self, sig):
        pass

    def force_exit(self):
        pass

    def wait_finish(self, res):
        pass

    def get_if_exited(self):
        return True

    def get_exit_status(self):
        return 0


def pump():
    for _ in range(100):
        if not ctx.pending():
            break
        ctx.iteration(False)


def make(usb="1", knob=False):
    with open(online, "w") as f:
        f.write(f"{usb}\n")
    if knob:
        open(m.KNOB, "w").close()
    elif os.path.exists(m.KNOB):
        os.unlink(m.KNOB)
    ev = []
    d = m.Hotkeyd(GLib.MainLoop())
    n = {"pmic": Dev("mtk-pmic-keys", ev, [KEY_POWER, 115]),
         "pad": Dev("AYANEO Controller", ev, [BTN_SOUTH, BTN_EAST, BTN_MODE], [0x10, ABS_HAT0Y, 0x09, 0x0A]),
         "gpio": Dev("odm:gpio_keys", ev, [0x2F0, HOME, 0x2F2, 114]),
         "touch": Dev("hyn_ts", ev, [BTN_TOUCH], [ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID]),
         "pad2": Dev("Wireless Controller", ev, [BTN_SOUTH, BTN_EAST])}
    for path, name in ((PMIC, "pmic"), (PAD, "pad"), (GPIO, "gpio")):
        dev = n[name]
        watch = GLib.io_add_watch(dev.fd, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, d.readable, path)
        d.devices[path] = (dev, d.keymap(dev.name, set(dev.caps)), watch)
    extras = {TOUCH: n["touch"], PAD2: n["pad2"]}
    m.glob.glob = lambda pattern: sorted([*d.devices, *extras]) if pattern == "/dev/input/event*" else []
    m.Node = lambda path: extras[path]
    m.evdev.InputDevice = no_open
    d.spawn = lambda name, ms: (ev.append(f"hook {name}"), (None, True, 0))[1]
    resync = d.resync
    d.resync = lambda resumed=None: (ev.append("resync"), resync(resumed))[1]
    fire = d.fire
    d.fire = lambda k, gesture, row, fallback=False: (ev.append(f"fire {k} {gesture}"), fire(k, gesture, row, fallback))[1]
    return d, n, ev


def screen_off(d, pause=False):
    child = m.Menu(Proc())
    child.pause = pause
    d.menu = d.last = child
    d.menu_due = d.pause_due = False
    d.menu_said(child, ["screen-off"])
    d.menu_exited(Proc(), None, child)
    d.grab_more()


def idle_blank(d):
    d.open_menu()
    screen_off(d)


def tap_blank(d):
    d.blank([])
    d.grab_more()


def pause_blank(d):
    for f in (m.PORT, m.PAUSED):
        open(f, "w").close()
    d.paused = True
    d.scope = True
    d.want("paused")
    screen_off(d, True)


def idle(d, n, ev):
    idle_blank(d)
    ev.clear()


def state(d):
    return f"wanted {d.wanted}, grabbed {d.grabbed!r}, hold {d.hold!r}, hold timer {bool(d.hold_timer)}"


def k1(node, down, up, name=None):
    def run(err):
        d, n, ev = make()
        idle(d, n, ev)
        watches = [w for _, _, w in d.extra.values()]
        n[node].push(*down)
        pump()
        if (d.wanted, d.grabbed, d.hold, ev) != ("awake", "all", "", ["hook blank-off"]):
            return f"after the down {state(d)}, {ev}"
        k = d.keys.get(name)
        if k and (not k.consumed or k.timer):
            return f"{name} consumed {k.consumed}, hold timer {bool(k.timer)}"
        n[node].push(*up)
        pump()
        left = [w for w in watches if not w or w not in removed]
        if ev[:1] + sorted(ev[1:-1]) + ev[-1:] != ["hook blank-off", *RELEASED, "resync"] or d.extra or left or d.grabbed \
                or d.hold is not None or d.hold_timer or "idle blank on usb: " not in err.getvalue():
            return f"after the up {state(d)}, {ev}, extras {sorted(d.extra)}, watches left {left}"
        return ""
    return run


def k1b(err):
    d, n, ev = make()
    idle(d, n, ev)
    n["pad"].push(*key(BTN_EAST, 1))
    pump()
    n["touch"].push(*TOUCH_DOWN)
    pump()
    n["pad"].push(*key(BTN_EAST, 0))
    pump()
    if d.grabbed != "all" or d.hold != "":
        return f"after the pad up {state(d)}"
    n["touch"].push(*TOUCH_UP)
    pump()
    if d.grabbed or d.hold is not None or UNGRAB[0] not in ev:
        return f"after the lift {state(d)}, {ev}"
    return ""


def k1c(err):
    d, n, ev = make()
    idle(d, n, ev)
    n["touch"].keys_broken = True
    n["pad"].push(*key(BTN_EAST, 1))
    pump()
    if d.wanted != "awake" or d.grabbed != "all":
        return f"after the down {state(d)}"
    n["pad"].push(*key(BTN_EAST, 0))
    pump()
    if d.grabbed or d.hold is not None or UNGRAB[0] not in ev:
        return f"after the pad up {state(d)}, {ev}"
    return ""


def k1d(err):
    d, n, ev = make()
    idle(d, n, ev)
    d.regrab[PAD] = n["pad"]
    n["pad"].push(*key(BTN_EAST, 1))
    pump()
    if d.wanted != "blanked" or d.grabbed != "all" or d.hold is not None or ev:
        return f"{state(d)}, {ev}"
    return ""


def k1e(node, down):
    def run(err):
        d, n, ev = make()
        idle(d, n, ev)
        watch = d.extra[TOUCH][2]
        n[node].push(*down)
        pump()
        if d.wanted != "awake" or d.grabbed != "all":
            return f"after the down {state(d)}"
        n[node].fail()
        pump()
        log = err.getvalue()
        path = TOUCH if node == "touch" else PAD
        if "Traceback" in log or d.grabbed or d.hold is not None or d.hold_timer or f"{path} gone" not in log \
                or path in d.extra or path in d.devices or f"close {n[node].name}" not in ev:
            return f"after the read error {state(d)}, {ev}"
        if node == "touch" and watch in removed:
            return "the watch removed in its own callback, then ended by its False"
        return ""
    return run


def k1g(err):
    d, n, ev = make()
    idle(d, n, ev)
    n["touch"].push(*TOUCH_DOWN)
    n["pad2"].push(*key(BTN_SOUTH, 1))
    d.resume()
    pump()
    if d.wanted != "blanked" or d.hold is not None or n["touch"].q or n["pad2"].q or "wakes" in err.getvalue():
        return f"{state(d)}, queued {len(n['touch'].q)} {len(n['pad2'].q)}"
    return ""


def k1h(err):
    d, n, ev = make()
    idle(d, n, ev)
    d.regrab[TOUCH] = n["touch"]
    n["touch"].held.add(BTN_TOUCH)
    n["pad"].push(*key(BTN_EAST, 1))
    pump()
    if d.wanted != "awake" or d.grabbed != "all":
        return f"after the down {state(d)}"
    n["pad"].push(*key(BTN_EAST, 0))
    pump()
    if d.grabbed or d.hold is not None:
        return f"after the pad up {state(d)}"
    return ""


def k1f(err):
    d, n, ev = make()
    idle_blank(d)
    d.open_menu()
    if d.menu_from != "dark":
        return f"menu from {d.menu_from}"
    screen_off(d)
    ev.clear()
    n["gpio"].push(*key(HOME, 1))
    pump()
    if d.wanted != "awake" or d.grabbed != "all" or "idle blank on usb: home wakes" not in err.getvalue():
        return f"{state(d)}, {ev}"
    return ""


def k2(err):
    d, n, ev = make()
    try:
        pause_blank(d)
        ev.clear()
        n["pad"].push(*key(BTN_EAST, 1))
        pump()
        if (d.wanted, d.pause_due, d.grabbed, d.hold, ev) != ("paused", True, "all", "keys", ["hook menu-on"]):
            return f"after the down {state(d)}, pause due {d.pause_due}, {ev}"
        n["pad"].push(*key(BTN_EAST, 0))
        pump()
        if ev[:1] + sorted(ev[1:6]) + ev[6:] != ["hook menu-on", *RELEASED, "resync", "grab mtk-pmic-keys", "grab odm:gpio_keys"] \
                or d.grabbed != "keys" or d.hold is not None or not os.path.exists(m.PAUSED):
            return f"after the up {state(d)}, {ev}, paused {os.path.exists(m.PAUSED)}"
        return ""
    finally:
        for f in (m.PORT, m.PAUSED):
            if os.path.exists(f):
                os.unlink(f)


def k3(err):
    d, n, ev = make()
    idle(d, n, ev)
    t0 = time.monotonic()
    n["pad"].push(*key(BTN_EAST, 1))
    pump()
    timer = d.hold_timer
    n["pad2"].push(*key(BTN_SOUTH, 1))
    pump()
    if not timer or d.hold_timer != timer or timer in removed or d.grabbed != "all" or d.hold != "":
        return f"after the second down: timer {timer} then {d.hold_timer}, removed {timer in removed}, {state(d)}"
    loop = GLib.MainLoop()
    seen = {}

    def poll():
        t = time.monotonic() - t0
        if d.grabbed != "all":
            seen["released"] = t
        if d.grabbed != "all" or t > 1.5:
            loop.quit()
            return False
        return True

    GLib.timeout_add(10, poll)
    loop.run()
    r = seen.get("released")
    if r is None or r < m.UP_MS / 1000 or d.hold is not None or d.hold_timer \
            or f"still down {m.UP_MS} ms after the wake" not in err.getvalue() or d.wanted != "awake":
        return f"released at {r} s, {state(d)}"
    return ""


def k4(blank, push, usb="1", knob=False, draining=False):
    def run(err):
        d, n, ev = make(usb, knob)
        blank(d)
        ev.clear()
        d.draining = draining
        node, evs = push
        n[node].push(*evs)
        pump()
        d.draining = False
        home = d.keys["home"]
        if d.wanted != "blanked" or d.grabbed != "all" or d.hold is not None or ev or "wakes" in err.getvalue() \
                or (node == "gpio" and not home.consumed):
            return f"{state(d)}, {ev}, home consumed {home.consumed}"
        return ""
    return run


def menu_cancel_tap(d):
    idle_blank(d)
    d.open_menu()
    child = m.Menu(Proc())
    d.menu = d.last = child
    d.menu_said(child, ["cancel"])
    d.menu_exited(Proc(), None, child)
    tap_blank(d)


def blank_on(d):
    idle_blank(d)
    d.blank(["on"])
    d.grab_more()


def tap_menu_screen_off(d):
    tap_blank(d)
    d.open_menu()
    screen_off(d)


def k56(act):
    def run(err):
        d, n, ev = make()
        idle(d, n, ev)
        n["pad"].push(*key(BTN_EAST, 1))
        pump()
        if d.wanted != "awake" or d.hold != "":
            return f"after the down {state(d)}"
        act(d, n)
        pump()
        if d.wanted != "blanked" or d.grabbed != "all" or d.hold is not None or d.hold_timer or d.idle_blank:
            return f"after the blank {state(d)}, mark {d.idle_blank}, {ev}"
        loop = GLib.MainLoop()
        GLib.timeout_add(m.UP_MS + 150, loop.quit)
        loop.run()
        if d.grabbed != "all":
            return f"{m.UP_MS + 150} ms later {state(d)}, {ev}"
        return ""
    return run


def k7(end):
    def run(err):
        d, n, ev = make()
        if end == "power":
            tap_blank(d)
        else:
            idle(d, n, ev)
            n["pad"].push(*key(BTN_EAST, 1))
            pump()
        for dev in n.values():
            dev.slow = 0.12
        spans = []
        ungrab = d.ungrab
        log = m.log

        def timed():
            t = time.monotonic()
            ungrab()
            spans.append(time.monotonic() - t)

        d.ungrab = timed
        m.log = lambda msg: (msg == "ungrabbed" and ev.append("log ungrabbed"), log(msg))[1]
        ev.clear()
        try:
            if end == "power":
                power_tap(d, n)
                pump()
            elif end == "up":
                n["pad"].push(*key(BTN_EAST, 0))
                pump()
            else:
                loop = GLib.MainLoop()
                GLib.timeout_add(10, lambda: d.grabbed == "all" or loop.quit())
                GLib.timeout_add(1500, loop.quit)
                loop.run()
        finally:
            m.log = log
        rel = [e for e in ev if e.startswith(("ungrab ", "close "))]
        if len(spans) != 1 or spans[0] > 0.3 or sorted(rel) != RELEASED or "resync" not in ev \
                or "log ungrabbed" not in ev or min(ev.index("resync"), ev.index("log ungrabbed")) < max(map(ev.index, rel)) \
                or d.grabbed or d.wanted != "awake" or d.hold is not None:
            return f"ungrab spans {[round(x, 3) for x in spans]} s with each node's release 0.12 s, {state(d)}, {ev}"
        return ""
    return run


def k7c(err):
    start = m.threading.Thread.start

    def refuse(self):
        raise RuntimeError("can't start new thread")

    m.threading.Thread.start = refuse
    try:
        d, n, ev = make()
        idle(d, n, ev)
        n["pad"].push(*key(BTN_EAST, 1))
        pump()
        ev.clear()
        n["pad"].push(*key(BTN_EAST, 0))
        pump()
    finally:
        m.threading.Thread.start = start
    rel = [e for e in ev if e.startswith(("ungrab ", "close "))]
    if sorted(rel) != RELEASED or "resync" not in ev or ev.index("resync") < max(map(ev.index, rel)) or d.grabbed \
            or d.extra or "Traceback" in err.getvalue():
        return f"with no thread start {state(d)}, extras {sorted(d.extra)}, {ev}"
    return ""


def k7d(err):
    class Bad:
        def __init__(self, e):
            self.e = e

        def ungrab(self):
            raise self.e

    d = m.Hotkeyd(GLib.MainLoop())
    for e in (OSError(errno.EBADF, "Bad file descriptor"), ValueError("file descriptor cannot be a negative integer (-1)")):
        d.release(Bad(e))
    return ""


def k7b(err):
    calls = []
    ioctl = m.fcntl.ioctl
    r, w = os.pipe()
    node = object.__new__(NODE)
    node.fd = r
    m.fcntl.ioctl = lambda fd, request, arg=0: calls.append((fd, request, arg))
    try:
        node.ungrab()
    finally:
        m.fcntl.ioctl = ioctl
        node.fd = -1
        os.close(r)
        os.close(w)
    if calls != [(r, 0x40044590, 0)]:
        return f"ioctl calls {calls}"
    return ""


def power_tap(d, n):
    n["pmic"].push(*key(KEY_POWER, 1))
    pump()
    n["pmic"].push(*key(KEY_POWER, 0))


HOME_DOWN = ("gpio", key(HOME, 1))
cases = [
    ("K1 home", k1("gpio", key(HOME, 1), key(HOME, 0), "home")),
    ("K1 east", k1("pad", key(BTN_EAST, 1), key(BTN_EAST, 0))),
    ("K1 hat", k1("pad", [(EV_ABS, ABS_HAT0Y, -1), SYN], [(EV_ABS, ABS_HAT0Y, 0), SYN])),
    ("K1 touch", k1("touch", TOUCH_DOWN, TOUCH_UP)),
    ("K1 pad2", k1("pad2", key(BTN_SOUTH, 1), key(BTN_SOUTH, 0))),
    ("K1b touch still down", k1b),
    ("K1c touch keys error", k1c),
    ("K1d retry set", k1d),
    ("K1e touch read error", k1e("touch", TOUCH_DOWN)),
    ("K1e pad read error", k1e("pad", key(BTN_EAST, 1))),
    ("K1f idle blank, power hold, screen-off", k1f),
    ("K1g resume drains the extras", k1g),
    ("K1h a node in the retry set holds nothing", k1h),
    ("K2 pause", k2),
    ("K3 bound", k3),
    ("K4 tap blank", k4(tap_blank, HOME_DOWN)),
    ("K4 online 0", k4(idle_blank, HOME_DOWN, usb="0")),
    ("K4 knob", k4(idle_blank, HOME_DOWN, knob=True)),
    ("K4 value 0", k4(idle_blank, ("pad", key(BTN_EAST, 0)))),
    ("K4 value 2", k4(idle_blank, ("pad", key(BTN_EAST, 2)))),
    ("K4 draining", k4(idle_blank, HOME_DOWN, draining=True)),
    ("K4 menu from idle, cancel, tap blank", k4(menu_cancel_tap, HOME_DOWN)),
    ("K4 blank on row", k4(blank_on, HOME_DOWN)),
    ("K4 tap blank, power hold, screen-off", k4(tap_menu_screen_off, HOME_DOWN)),
    ("K5 power tap in the hold", k56(power_tap)),
    ("K6 blank on row in the hold", k56(lambda d, n: d.blank(["on"]))),
    ("K7 the nodes release at once: the last up", k7("up")),
    ("K7 the nodes release at once: the bound", k7("bound")),
    ("K7 the nodes release at once: a power tap wake", k7("power")),
    ("K7b a node ungrabs by EVIOCGRAB 0 through fcntl", k7b),
    ("K7c a thread that cannot start releases its node inline", k7c),
    ("K7d a release ignores OSError and ValueError", k7d),
]
bad = []
for name, fn in cases:
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            why = fn(err)
    except Exception as e:
        why = f"{type(e).__name__}: {e}"
    print(f"{name}: {why or 'ok'}")
    if why:
        bad.append(f"{name}: {why}, log {err.getvalue().splitlines()}")
for b in bad:
    print(f"FAILED {b}")
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/qs11.out"
res $r "qs11: after an idle blank on usb a non-power key, pad button, hat or touch down wakes and is swallowed, the full grab held until every node the next grab mode releases is up, a held node goes or the bound; no wake after a tap blank (also through the dark menu), on battery, with the knob, for value 0 or 2, while draining or from a node in the retry set; a power tap or a blank on row in the hold ends it with the grab kept; a node in the retry set holds nothing; a resume drains the extras; every node releases at once, each by EVIOCGRAB 0 through fcntl, inline when a thread cannot start, before ungrabbed is logged"

env -u BLOCKIE_HOTKEYD_BACKSTOP_MS -u BLOCKIE_HOTKEYD_BOOT_BACKSTOP_MS -u BLOCKIE_HOTKEYD_UP_MS timeout -k 5 60 python3 - "$bin" > "$t/backstop.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import os
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
os.environ["BLOCKIE_HOTKEYD_UP_MS"] = "5000"
up = importlib.util.module_from_spec(spec)
loader.exec_module(up)
print(m.BACKSTOP_MS, m.BOOT_BACKSTOP_MS, m.SHOWN_MS, m.MENU_KILL_MS, m.TOAST_MS, m.POLL_MS, m.UP_MS, up.UP_MS)
ok = (m.BACKSTOP_MS, m.BOOT_BACKSTOP_MS, m.SHOWN_MS, m.MENU_KILL_MS, m.TOAST_MS, m.POLL_MS, m.UP_MS, up.UP_MS) \
    == (35000, 50000, 5000, 2000, 5100, 1000, 1000, 1000)
sys.exit(0 if ok and m.TOAST_MS >= 350 + 3500 + 250 + m.POLL_MS and m.BOOT_BACKSTOP_MS > 45000 else 1)
EOF
res $? "defaults: the power off backstop 35000 ms (past the 25 s limit of blockie-poweroff.service), the boot unit backstop 50000 ms (past the 45 s limit of blockie-reboot@.service), the menu shown limit 5000 ms, kill 2000 ms, toast 5100 ms (toast in 350, hold 3500, out 250 plus one poll), reboot unit poll 1000 ms, the wake hold bound 1000 ms, also with BLOCKIE_HOTKEYD_UP_MS 5000 (at or below the pause child's 1000 ms busy wait)"

if [[ ${HOTKEYD_CASES:-} != qs11 ]]; then

BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys BLOCKIE_HOTKEYD_INPUT=/dev/null \
  timeout -k 5 60 python3 - "$bin" > "$t/codes.out" 2>&1 << 'EOF'
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


class Dev:
    def __init__(self, caps):
        self.name = "odm:gpio_keys"
        self.fd, self.w = os.pipe()
        self.caps = caps

    def capabilities(self, absinfo=True):
        return {m.evdev.ecodes.EV_KEY: self.caps}

    def close(self):
        pass


devs = {"/dev/input/event3": Dev([0x2F0, 0x2F1, 0x2F2, 114]), "/dev/input/event4": Dev([0x2F1]),
        "/dev/input/event5": Dev([183, 184, 185, 114]), "/dev/input/event6": Dev([183])}
m.glob.glob = lambda pattern: sorted(devs) if pattern == "/dev/input/event*" else []
m.Node = lambda path: devs[path]


def no_open(path):
    raise AssertionError(f"evdev.InputDevice({path})")


m.evdev.InputDevice = no_open
m.Hotkeyd.physical = lambda self, real, name: True
gpio = {0x2F1: "home", 183: "home", 0x2F0: "extra2", 184: "extra2", 0x2F2: "extra3", 185: "extra3"}
want = {p: {**gpio, **({114: "voldown"} if 114 in devs[p].caps else {})} for p in devs}
with contextlib.redirect_stderr(io.StringIO()):
    d = m.Hotkeyd(m.GLib.MainLoop())
    d.rescan()
got = {p: d.devices[p][1] for p in d.devices}
print(got)
sys.exit(0 if got == want else 1)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/codes.out"
res $r "codes: a node named odm:gpio_keys maps both codes of home, extra2 and extra3 whether its caps list the gpio codes, F13 to F15 or one of them; voldown, one code, only when its caps list it"

timeout -k 5 60 python3 - "$bin" "$schema" > "$t/bdef.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import json
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
with open(sys.argv[2]) as f:
    keys = json.load(f)["keys"]
want = {tuple(k.split(".")[1:]): v["default"] for k, v in keys.items()}
print(m.LAYOUT_DEFAULTS, want)
sys.exit(0 if m.LAYOUT_DEFAULTS == want and all(v["enum"] == list(m.ACTIONS) for v in keys.values()) else 1)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/bdef.out"
res $r "map: the built in button defaults and words equal 30-buttons.json"
fi

if (( fails )); then
  echo "hotkeyd: $fails failed"
  exit 1
fi
echo "hotkeyd: ok"
