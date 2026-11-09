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

mkdir -p "$t/usr" "$t/etc" "$t/usr/test-a.conf.d"
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
  BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_TABLES="${TABLES:-$t/usr:$t/etc}" BLOCKIE_HOTKEYD_CURRENT=$t/current \
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

printf 'emulation 1 1\n' > "$t/current"
TABLES=$tables run 'echo extra3 down; sleep 0.1; echo extra3 up; echo extra3 down; sleep 0.5; echo extra3 up
  echo home down; sleep 0.5; echo home up; echo extra1 down; sleep 0.5; echo extra1 up'
[[ $(cat "$t/out") == $'action extra3 tap hook game-menu\naction extra3 hold hook game-quit\naction home hold switcher' ]] &&
  ! grep -q ignored "$t/err"
res $? "emulation: the shipped rows give logo tap game-menu and hold game-quit, home hold stays the switcher, extra1 has no row"

printf 'nobody-here 1 1\n' > "$t/current"
run 'echo power down; echo power up; echo home down; sleep 0.5; echo home up; echo volup down; echo volup up
  echo extra3 down; echo extra3 up; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power tap blank\ngrab\naction power tap blank\nungrab\nresync' ]]
res $? "power tap blanks and grabs, other keys fire nothing while blanked, the next power tap wakes, ungrabs and resyncs"

run 'echo power down; sleep 2.3; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power hold=2000 menu\ngrab keys\naction power tap blank\nungrab\nresync\ngrab' ]]
res $? "a lost power release: the second down starts a new press and its tap closes the menu and blanks"

ok=0
run 'echo power down; sleep 1.9; echo power up'
[[ $(cat "$t/out") == $'action power tap blank\ngrab' ]] || { ok=1; echo "  1.9 s: $(paste -sd '|' "$t/out")"; }
run 'echo power down; sleep 4.6; echo power up'
[[ $(cat "$t/out") == $'action power hold=2000 menu\ngrab keys\naction power hold=4000 unit blockie-poweroff.service\nungrab\nresync\ngrab' ]] &&
  grep -qx 'menu start from=awake state=/run/blockie/boot/state' "$t/hooks.log" || { ok=1; echo "  no shown: $(paste -sd '|' "$t/out")"; }
mq '0.2 shown'
run 'echo power down; sleep 4.6; echo power up'
[[ $(cat "$t/out") == $'action power hold=2000 menu\ngrab keys' ]] || { ok=1; echo "  shown: $(paste -sd '|' "$t/out")"; }
mq '0.2 shown' '0.2 cancel'
run 'echo power down; sleep 2.6; echo power up; sleep 0.3'
[[ $(cat "$t/out") == $'action power hold=2000 menu\ngrab keys\nungrab\nresync' ]] || { ok=1; echo "  cancel: $(paste -sd '|' "$t/out")"; }
res $ok "default power rows: a release before 2000 ms taps blank; 2000 ms opens the menu and grabs the key nodes; 4000 ms starts blockie-poweroff.service only when the menu printed no shown, its lit-frozen taking the full grab; leaving the menu ungrabs"

printf 'power tap none\npower hold none\n' > "$t/usr/test-p.conf"
printf 'test-p 1 1\n' > "$t/current"
run 'echo power down; echo power up; echo power down; sleep 4.3; echo power up'
[[ $(cat "$t/out") == $'action power tap none\naction power hold none' ]]
res $? "session power rows replace the default tap and every default hold stage"

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
  *) echo "systemctl \$*" >> "$t/hooks.log" ;;
esac
EOF
chmod 755 "$t/fbin/systemctl"

live() {
  local script=$1 e=() x
  for x in ${FAST:-}; do
    e+=("BLOCKIE_HOTKEYD_$x")
  done
  rm -f "$t/fifo" "$t/hooks.log" "$t/times" "$t/qn" "$t/slept" "$t/unit.since"
  mkfifo "$t/fifo"
  PATH=$t/fbin:$PATH BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_HOOKS=$hk BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_HOOK_MS=${HOOK_MS:-5000} BLOCKIE_HOTKEYD_BACKSTOP_MS=${BACKSTOP_MS:-20000} BLOCKIE_HOTKEYD_TABLES=$t/usr:$t/etc BLOCKIE_HOTKEYD_CURRENT=$t/current \
    BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_SLEPT=$t/slept BLOCKIE_HOTKEYD_SYSFS=$t/psys \
    BLOCKIE_HOTKEYD_KNOB=$t/knob BLOCKIE_HOTKEYD_HOOK_RUNNER=${RUNNER:-$runner} DBUS_SESSION_BUS_ADDRESS=unix:path=$t/nobus \
    BLOCKIE_HOTKEYD_MENU=$t/fbin/fake-menu BLOCKIE_HOTKEYD_BACKLIGHT=$t/fbin/fake-backlight BLOCKIE_BOOT_STATE=$t/boot.state \
    env "${e[@]}" timeout -k 5 30 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
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
hold='sleep 0.5; echo power down; sleep 2.3; echo power up'
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
live 'sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 0.5'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo" ]] && grep -q 'blockie-powermenu showed: unit blockie-poweroff.service skipped' "$t/err"
res $? "menu: after shown a hold to 4000 ms starts nothing"

mq '0.1 shown' '0.3 cancel'
live 'sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 0.5'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && grep -q 'blockie-powermenu showed: unit blockie-poweroff.service skipped' "$t/err"
res $? "menu: shown, then closed inside the same hold: the 4000 ms stage stays skipped"

: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 1'
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
res $? "menu: no shown by 4000 ms: SIGTERM to the child, then backlight off and about 300 ms later on, then screen-on and the blockie-poweroff.service start"

echo activating > "$t/unit.state"
ok=0
FAST="MENU=$t/none" live "sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 0.8; $tap; sleep 0.5"
blinked "$woke"$'\nstart menu-on\nexit menu-on\n'"$woke" && ! grep -q 'start blank-on' "$t/hooks.log" &&
  grep -q "cannot run $t/none" "$t/err" || ok=1
mq '0.1 failed wayland'
live "sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 0.8; $tap; sleep 0.5"
blinked "$woke"$'\n'"$mo"$'\n'"$woke" && ! grep -q 'start blank-on' "$t/hooks.log" || ok=1
res $ok "menu: with the menu binary missing, or failed before shown, the 4000 ms stage blinks and powers off through screen-on in lit-frozen, and a tap after it runs no blank-on"
rm -f "$t/unit.state"

echo 2.1 > "$hk/menu-on.sleep"
: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 4.6; echo power up; sleep 1'
e=$(tms 'exit menu-on')
bon=$(tms backlight-on)
[[ -n $e && -n $bon ]] && ((e < bon)) && ! grep -q '^menu start' "$t/hooks.log" && grep -qx "$poff_line" "$t/hooks.log"
res $? "menu: a menu-on that ends inside the 4000 ms blink starts no child"
echo 0.1 > "$hk/menu-on.sleep"

: > "$t/menu.q"
FAST='SHOWN_MS=1500' live "$hold; sleep 2"
[[ $(nt) == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && termed && grep -q 'printed no shown in 1500 ms: back to awake' "$t/err"
res $? "menu: a child with no shown within the shown limit is ended and hotkeyd goes back to awake"

: > "$t/menu.q"
live 'sleep 0.5; echo power down; sleep 3; echo power up; sleep 2'
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo" ]]
res $? "menu: a release at 3000 ms with no shown starts nothing and keeps the child"

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

echo 'home tap hook beep' >> "$t/usr/test-m.conf"
keys='echo home down; echo home up; echo home down; sleep 0.5; echo home up; echo volup down; echo volup up; echo extra3 down; echo extra3 up'
ok=0
mq '0.1 shown' '0.2 boot reboot'
live "sleep 0.5; echo extra3 down; echo extra3 up; sleep 0.3; $hold; sleep 0.5; $keys; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\nbeep\n'"$mo"$'\n'"$lit"$'\nsystemctl --user start --no-block blockie-reboot@reboot.service' ]] ||
  { ok=1; echo "  boot reboot: $(paste -sd '|' "$t/hooks.log")"; }
echo activating > "$t/unit.state"
: > "$t/menu.q"
live "sleep 0.5; echo extra3 down; echo extra3 up; sleep 0.3; echo power down; sleep 4.6; echo power up; sleep 0.3; $keys; sleep 0.5"
blinked "$woke"$'\nbeep\n'"$mo" term || ok=1
rm -f "$t/unit.state"
res $ok "lit-frozen: after boot reboot and after the 4000 ms fallback a home tap, a home hold, volup and extra3 fire nothing"

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
FAST='MENU_KILL_MS=6000' live "$hold; sleep 0.8; echo power down; sleep 2.3; echo power up; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$woke" ]] && grep -q 'menu: ignored, blockie-powermenu still runs' "$t/err"
res $? "menu: a menu stage while the fading child still runs is ignored"

echo activating > "$t/unit.state"
mq '0.1 shown' '0.2 poweroff'
live "$hold; sleep 0.5; echo power down; sleep 2.3; echo power up; sleep 0.5"
[[ $(< "$t/hooks.log") == "$woke"$'\n'"$mo"$'\n'"$lit"$'\n'"$poff_line" ]] && grep -q 'menu: ignored, lit-frozen' "$t/err" &&
  grep -q 'blockie-powermenu still running after 2000 ms: killed' "$t/err"
res $? "menu: a menu stage in lit-frozen is ignored; a child that said poweroff and stays is killed at the kill time"
rm -f "$t/unit.state"

dpart switcher-open
echo 5 > "$hk/switcher-open.d.sleep"
: > "$t/menu.q"
RUNNER=$fr live 'sleep 0.5; echo power down; sleep 1.2; echo home down; sleep 0.4; echo home up; sleep 1; echo power up; sleep 1.5'
[[ $(< "$t/hooks.log") == "$woke"$'\nrunner switcher-open\npart switcher-open\n'"$mo" ]] && grep -q 'switcher-open killed for the power menu' "$t/err"
res $? "menu: a running switcher-open is killed and no switcher follows"
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
FAST="$fast SETTLE_MS=1500" live "$up; until_n '^exit blank-on$' $t/hooks.log; echo power down; sleep 1.8; echo power up; sleep 0.5"
[[ $(ev) == "start blank-off start blank-on start blank-off" ]]
res $? "sleep: a power down during the settle wait holds it off, no helper call while the key is down"

echo '5 0 slept power 5' > "$t/queue"
: > "$t/menu.q"
FAST=$fast live "$up; until_n 'slept power' $t/err; echo power down; until_n '^menu start' $t/hooks.log; sleep 0.6; echo power up; sleep 0.6"
[[ $(ev) == "start blank-off start blank-on helper first start menu-on menu start from=dark state=$t/boot.state" ]]
res $? "sleep: a hold right after a power wake opens the menu from dark: menu-on, then the child, no blank-off, no helper call in menu"

: > "$t/queue"
mq '0.1 shown' '0.2 screen-off' '1 exit'
FAST=$fast live "sleep 0.4; echo power down; sleep 2.3; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2"
[[ $(ev) == "start blank-off start menu-on menu start from=awake state=$t/boot.state start blank-on menu exit helper first" ]]
res $? "sleep: screen-off from the menu blanks and sleeps only once the child is gone"

: > "$t/queue"
FAST=$fast live "sleep 0.4; echo power down; sleep 1.5; date +%s%3N > $t/rel; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2"
g=$(gap "$(tms helper | head -n 1)" "$(cat "$t/rel" 2> /dev/null)")
[[ $(ev) == "start blank-off start blank-on helper first" ]] && ((g >= 280))
res $? "sleep: a press released at 1.5 s blanks at the release and sleeps one settle wait after it ($g ms)"

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
d, dev, out, seen = case("queued down, held", [[(116, 1)]], [116], run_ms=4700)
if "action power hold=2000 menu" not in out or "action power hold=4000 unit blockie-poweroff.service" not in out \
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
    d.extra[P1] = (dev, real)
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
    want = ungrab + keys + ["grab mtk-pmic-keys", "grab odm:gpio_keys", "hook menu-on"]
    if ev != want or d.menu_from != "dark" or d.grabbed != "keys":
        bad.append(f"from blanked: {ev}, from {d.menu_from}")
    ev.clear()
    d.applied = "menu"
    d.want("awake")
    if ev != ungrab + keys + ["hook blank-off"] or d.grabbed:
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
    head = ["ungrab mtk-pmic-keys", "ungrab AYANEO Controller", "keys mtk-pmic-keys", "keys AYANEO Controller",
            "grab mtk-pmic-keys", "busy AYANEO Controller", "hook screen-on"]
    if ev[:7] != head or ev[7:] != ["busy AYANEO Controller", "busy AYANEO Controller", "grab AYANEO Controller"] \
            or d.regrab or d.regrab_timer or d.grabbed != "all" or "lit-frozen: 2 key nodes and 0 more grabbed" not in err.getvalue() \
            or err.getvalue().count("grabbed on retry") != 1:
        bad.append(f"entering lit-frozen with the pad held: {ev}, grabbed {d.grabbed}, log {err.getvalue().splitlines()}")
    ev.clear()
    d.applied = "lit-frozen"
    d.want("awake")
    if ev != ["ungrab mtk-pmic-keys", "ungrab AYANEO Controller", "keys mtk-pmic-keys", "keys AYANEO Controller",
              "hook blank-off"] or d.grabbed:
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
for b in bad:
    print(f"FAILED {b}")
sys.exit(1 if bad else 0)
EOF
r=$?
((r == 0)) || sed 's/^/  /' "$t/lgrab.out"
res $r "lit-frozen grab: from the menu it ungrabs and resyncs, then takes every node; the pad the child still holds gets EBUSY and is taken on the retry once it is free, and at once in the child's exit; leaving for awake ungrabs and resyncs"

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

env -u BLOCKIE_HOTKEYD_BACKSTOP_MS -u BLOCKIE_HOTKEYD_BOOT_BACKSTOP_MS timeout -k 5 60 python3 - "$bin" > "$t/backstop.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
print(m.BACKSTOP_MS, m.BOOT_BACKSTOP_MS, m.SHOWN_MS, m.MENU_KILL_MS, m.TOAST_MS, m.POLL_MS)
ok = (m.BACKSTOP_MS, m.BOOT_BACKSTOP_MS, m.SHOWN_MS, m.MENU_KILL_MS, m.TOAST_MS, m.POLL_MS) == (35000, 50000, 5000, 2000, 5100, 1000)
sys.exit(0 if ok and m.TOAST_MS >= 350 + 3500 + 250 + m.POLL_MS and m.BOOT_BACKSTOP_MS > 45000 else 1)
EOF
res $? "defaults: the power off backstop 35000 ms (past the 25 s limit of blockie-poweroff.service), the boot unit backstop 50000 ms (past the 45 s limit of blockie-reboot@.service), the menu shown limit 5000 ms, kill 2000 ms, toast 5100 ms (toast in 350, hold 3500, out 250 plus one poll), reboot unit poll 1000 ms"

if (( fails )); then
  echo "hotkeyd: $fails failed"
  exit 1
fi
echo "hotkeyd: ok"
