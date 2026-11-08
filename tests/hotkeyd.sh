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
EOF
printf 'extra3 press hook beep\nextra3 tap none\n' > "$t/usr/test-a.conf.d/50-x.conf"
printf 'extra2 hold back\n' > "$t/etc/test-a.conf"

run() {
  local script=$1
  rm -f "$t/fifo"
  mkfifo "$t/fifo"
  BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_TABLES="${TABLES:-$t/usr:$t/etc}" BLOCKIE_HOTKEYD_CURRENT=$t/current \
    BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_SYSFS=$t/psys \
    timeout -k 5 20 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  timeout -k 5 60 bash -c "exec > '$t/fifo'; $script"
  wait "$pid"
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
  grep -q 'test-a.conf:9: ignored: nonsense' "$t/err" && grep -q 'test-a.conf:10: ignored: home wiggle' "$t/err"
res $? "bad names, press rows that are not hooks, unknown keys and gestures are ignored with their line"

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

run 'echo power down; sleep 0.5; echo power down; echo power up'
[[ $(cat "$t/out") == $'action power hold blank on\ngrab\naction power tap blank\nungrab\nresync' ]]
res $? "a lost power release: the second down starts a new press and its tap wakes"

run 'echo power down; sleep 2; echo power up; echo power down; sleep 3.3; echo power up'
[[ $(cat "$t/out") == $'action power hold blank on\ngrab\naction power hold blank on\naction power hold=3000 unit blockie-poweroff.service\nungrab\nresync' ]]
res $? "default power hold: blank at the plain hold time, a release at 2 s stays blanked, 3000 ms starts blockie-poweroff.service"

printf 'power tap none\npower hold none\n' > "$t/usr/test-p.conf"
printf 'test-p 1 1\n' > "$t/current"
run 'echo power down; echo power up; echo power down; sleep 3.3; echo power up'
[[ $(cat "$t/out") == $'action power tap none\naction power hold none' ]]
res $? "session power rows replace the default tap and both default hold stages"

printf '%s\n' 'power hold blank on' 'power hold=1200 unit blockie-test.service' 'power hold=abc none' 'power hold=0 none' \
  'power hold=70000 none' 'power tap blank off' > "$t/usr/test-h.conf"
printf 'test-h 1 1\n' > "$t/current"
run 'echo power down; sleep 0.7; echo power up; echo power down; sleep 1.5; echo power up'
[[ $(cat "$t/out") == $'action power hold blank on\ngrab\naction power hold blank on\naction power hold=1200 unit blockie-test.service\nungrab\nresync' ]] &&
  grep -q 'test-h.conf:3: ignored: power hold=abc none' "$t/err" && grep -q 'test-h.conf:4: ignored: power hold=0 none' "$t/err" &&
  grep -q 'test-h.conf:5: ignored: power hold=70000 none' "$t/err" && grep -q 'test-h.conf:6: ignored: power tap blank off' "$t/err"
res $? "hold=<ms> rows add a stage each next to the plain hold; bad hold times and blank arguments are ignored with their line"

hk=$t/hooks
mkdir -p "$hk" "$t/fbin"
for h in blank-on blank-off screen-on; do
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
cat > "$t/fbin/systemctl" << EOF
#!/bin/sh
case "\$*" in
  '--user show -P ActiveState '*) cat "$t/unit.state" 2> /dev/null || echo inactive ;;
  *) echo "systemctl \$*" >> "$t/hooks.log" ;;
esac
EOF
chmod 755 "$t/fbin/systemctl"

live() {
  local script=$1 e=() x
  for x in ${FAST:-}; do
    e+=("BLOCKIE_HOTKEYD_$x")
  done
  rm -f "$t/fifo" "$t/hooks.log" "$t/times" "$t/qn" "$t/slept"
  mkfifo "$t/fifo"
  PATH=$t/fbin:$PATH BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_HOOKS=$hk BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_HOOK_MS=${HOOK_MS:-5000} BLOCKIE_HOTKEYD_BACKSTOP_MS=${BACKSTOP_MS:-20000} BLOCKIE_HOTKEYD_TABLES=$t/usr:$t/etc BLOCKIE_HOTKEYD_CURRENT=$t/current \
    BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep BLOCKIE_HOTKEYD_SLEPT=$t/slept BLOCKIE_HOTKEYD_SYSFS=$t/psys \
    BLOCKIE_HOTKEYD_KNOB=$t/knob BLOCKIE_HOTKEYD_HOOK_RUNNER=${RUNNER:-$runner} DBUS_SESSION_BUS_ADDRESS=unix:path=$t/nobus \
    env "${e[@]}" timeout -k 5 30 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  timeout -k 5 60 bash -c "exec > '$t/fifo'; $script"
  wait "$pid"
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
for h in blank-on blank-off screen-on; do
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
FAST="$fast SETTLE_MS=1500" live "$up; until_n '^exit blank-on$' $t/hooks.log; echo power down; sleep 2.2; echo power up; sleep 0.5"
[[ $(ev) == "start blank-off start blank-on" ]]
res $? "sleep: a power down during the settle wait holds it off, no helper call while the key is down"

echo '5 0 slept power 5' > "$t/queue"
FAST=$fast live "$up; until_n 'slept power' $t/err; echo power down; until_n '$offs' $t/hooks.log; echo power up; sleep 0.5"
[[ $(ev) == "start blank-off start blank-on helper first start screen-on systemctl --user start --no-block blockie-poweroff.service" ]]
res $? "sleep: a hold from asleep starts blockie-poweroff.service at 3000 ms after screen-on, no blank-off, no helper call while lit-frozen"

: > "$t/queue"
FAST=$fast live "sleep 0.4; echo power down; sleep 2; date +%s%3N > $t/rel; echo power up; until_n '^helper' $t/hooks.log; sleep 0.2"
g=$(gap "$(tms helper | head -n 1)" "$(cat "$t/rel" 2> /dev/null)")
[[ $(ev) == "start blank-off start blank-on helper first" ]] && ((g >= 280))
res $? "sleep: a hold released at 2 s stays blanked and sleeps one settle wait after the release ($g ms)"

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

for h in blank-on blank-off screen-on; do
  rm -f "$hk/$h.sleep"
done

BLOCKIE_HOTKEYD_DRY=1 BLOCKIE_HOTKEYD_LONG_MS=300 BLOCKIE_HOTKEYD_CURRENT=$t/none BLOCKIE_HOTKEYD_SYSFS=$t/psys \
  BLOCKIE_HOTKEYD_INPUT=/dev/null BLOCKIE_HOTKEYD_SLEEP=$t/fbin/fake-sleep timeout -k 5 60 python3 - "$bin" > "$t/drain.out" 2>&1 << 'EOF'
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
d, dev, out, seen = case("queued down, held", [[(116, 1)]], [116], run_ms=3800)
if "action power hold blank on" not in out or "action power hold=3000 unit blockie-poweroff.service" not in out \
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
        d.set_grab(True)
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
d, out, seen = case("awake after one failure", a, lambda d: d.set_grab(False))
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

env -u BLOCKIE_HOTKEYD_BACKSTOP_MS timeout -k 5 60 python3 - "$bin" > "$t/backstop.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("hotkeyd", sys.argv[1])
spec = importlib.util.spec_from_loader("hotkeyd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
print(m.BACKSTOP_MS)
sys.exit(0 if m.BACKSTOP_MS == 35000 else 1)
EOF
res $? "the power off backstop defaults to 35000 ms, past the 25 s limit of blockie-poweroff.service"

if (( fails )); then
  echo "hotkeyd: $fails failed"
  exit 1
fi
echo "hotkeyd: ok"
