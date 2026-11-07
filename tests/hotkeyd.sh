#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin=${HOTKEYD_BIN:-/usr/libexec/blockie/blockie-hotkeyd}
[[ -x $bin ]] || bin=$here/../system_files/usr/libexec/blockie/blockie-hotkeyd
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
    BLOCKIE_HOTKEYD_TABLES="$t/usr:$t/etc" BLOCKIE_HOTKEYD_CURRENT=$t/current \
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
res $? "a second down without an up is ignored"

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
