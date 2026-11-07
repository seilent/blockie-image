#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin=${HOTKEYD_BIN:-/usr/libexec/blockie/blockie-hotkeyd}
[[ -x $bin ]] || bin=$here/../system_files/usr/libexec/blockie/blockie-hotkeyd
tables=/usr/lib/blockie/hotkeys.d
[[ -d $tables ]] || tables=$here/../system_files/usr/lib/blockie/hotkeys.d
t=$(mktemp -d "${TMPDIR:-/tmp}/hotkeyd.XXXXXX")
fails=0
trap 'rm -rf "${t:?}"' EXIT

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
    timeout 20 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  bash -c "$script" > "$t/fifo"
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
s=0.5
[ ! -f "$hk/$h.sleep" ] || read -r s < "$hk/$h.sleep"
sleep "\$s"
rc=0
[ ! -f "$hk/$h.rc" ] || read -r rc < "$hk/$h.rc"
echo "exit $h" >> "$t/hooks.log"
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
  local script=$1
  rm -f "$t/fifo" "$t/hooks.log"
  mkfifo "$t/fifo"
  PATH=$t/fbin:$PATH BLOCKIE_HOTKEYD_INPUT=$t/fifo BLOCKIE_HOTKEYD_HOOKS=$hk BLOCKIE_HOTKEYD_LONG_MS=300 \
    BLOCKIE_HOTKEYD_HOOK_MS=${HOOK_MS:-5000} BLOCKIE_HOTKEYD_BACKSTOP_MS=${BACKSTOP_MS:-20000} BLOCKIE_HOTKEYD_TABLES=$t/usr:$t/etc BLOCKIE_HOTKEYD_CURRENT=$t/current \
    timeout 30 python3 "$bin" > "$t/out" 2> "$t/err" &
  local pid=$!
  bash -c "$script" > "$t/fifo"
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
BLOCKIE_HOTKEYD_SYSFS=$S python3 - "$bin" "$S" > "$t/phys.out" 2>&1 << 'EOF'
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

if (( fails )); then
  echo "hotkeyd: $fails failed"
  exit 1
fi
echo "hotkeyd: ok"
