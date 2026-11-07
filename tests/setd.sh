#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
setd=${SETD_BIN:-/usr/libexec/blockie/blockie-setd}
[[ -x $setd ]] || setd=$here/../system_files/usr/libexec/blockie/blockie-setd
cli=${SET_BIN:-/usr/bin/blockie-set}
[[ -x $cli ]] || cli=$here/../system_files/usr/bin/blockie-set
schema=${SETD_SCHEMA:-/usr/share/blockie/schema.d}
[[ -d $schema ]] || schema=$here/../system_files/usr/share/blockie/schema.d
t=$(mktemp -d "${TMPDIR:-/tmp}/setd.XXXXXX")
fails=0
pids=()
cleanup() {
  local p
  for p in "${pids[@]}"; do
    kill "$p" 2> /dev/null
  done
  wait 2> /dev/null
  rm -rf "${t:?}"
}
trap cleanup EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

mkdir -p "$t/schema" "$t/store" "$t/sessions"
cp "$schema"/*.json "$t/schema/"
cat > "$t/schema/20-test.json" << 'EOF'
{
  "keys": {
    "test.level": {"type": "u", "default": 3, "min": 1, "max": 9},
    "test.mode": {"type": "s", "default": "a", "enum": ["a", "b"]},
    "test.on": {"type": "b", "default": false},
    "test.ratio": {"type": "d", "default": 0.5, "min": 0, "max": 1},
    "test.fixed": {"type": "s", "default": "x", "writable": false},
    "test.big": {"type": "u", "default": 1},
    "test.neg": {"type": "i", "default": 0},
    "test.bad": {"type": "q", "default": 1},
    "test.baddefault": {"type": "u", "default": 20, "max": 9},
    "session.default": {"type": "s", "default": "other"}
  }
}
EOF
printf 'DEFAULT=yes\n' > "$t/sessions/emulation.conf"
printf 'DEFAULT="yes"\n' > "$t/sessions/funeos.conf"
printf 'DEFAULT=no\n' > "$t/sessions/test-a.conf"
export BLOCKIE_SETD_SCHEMAS=$t/schema BLOCKIE_SETD_STORE=$t/store/settings.json BLOCKIE_SETD_SESSIONS=$t/sessions

python3 - "$setd" > "$t/unit.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import json
import os
import sys

loader = importlib.machinery.SourceFileLoader("setd", sys.argv[1])
spec = importlib.util.spec_from_loader("setd", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
fails = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        fails.append(what)


def refused(f, kind):
    try:
        f()
    except m.Refused as err:
        return err.kind == kind
    return False


keys = m.load_schema()
check("test.bad" not in keys and "test.baddefault" not in keys, "a key with a bad type or a refused default is dropped")
check(keys["session.default"]["default"] == "emulation", "a key defined twice keeps the first file's definition")
check(m.default_sessions() == ["emulation", "funeos"], "default sessions: DEFAULT=yes, quoted or not")
s = m.Store(keys)
check(s.get("test.level") == 3 and s.get("session.default") == "emulation", "defaults before any write")
check(s.set("test.level", 7) and s.get("test.level") == 7, "set a valid value")
check(not s.set("test.level", 7), "setting the same stored value again changes nothing")
check(refused(lambda: s.set("test.level", 10), "Invalid") and refused(lambda: s.set("test.level", 0), "Invalid"),
      "min and max")
check(refused(lambda: s.set("test.level", True), "Invalid") and refused(lambda: s.set("test.level", "7"), "Invalid"),
      "type u refuses a boolean and a string")
check(refused(lambda: s.set("test.mode", "c"), "Invalid") and s.set("test.mode", "b"), "enum")
check(s.set("test.ratio", 1) and s.get("test.ratio") == 1.0, "type d takes an integer as a float")
check(refused(lambda: s.set("test.big", 2**32), "Invalid") and refused(lambda: s.set("test.big", -1), "Invalid")
      and s.set("test.big", 2**32 - 1), "type u is an unsigned 32 bit range")
check(refused(lambda: s.set("test.neg", 2**31), "Invalid") and refused(lambda: s.set("test.neg", -2**31 - 1), "Invalid")
      and s.set("test.neg", -2**31), "type i is a signed 32 bit range")
check(refused(lambda: s.set("test.fixed", "y"), "ReadOnly"), "writable false refuses")
check(refused(lambda: s.set("test.nope", 1), "UnknownKey") and refused(lambda: s.get("test.nope"), "UnknownKey"),
      "unknown key")
check(refused(lambda: s.set("session.default", "test-a"), "Invalid") and s.set("session.default", "funeos"),
      "session.default takes only DEFAULT=yes sessions")
with open(os.environ["BLOCKIE_SETD_STORE"]) as f:
    stored = json.load(f)
check(stored == {"session.default": "funeos", "test.big": 2**32 - 1, "test.level": 7, "test.mode": "b",
                 "test.neg": -2**31, "test.ratio": 1.0},
      f"store holds exactly the set values: {stored}")
check(oct(os.stat(os.environ["BLOCKIE_SETD_STORE"]).st_mode & 0o777) == "0o644", "store mode 0644")
check(not [n for n in os.listdir(os.path.dirname(os.environ["BLOCKIE_SETD_STORE"])) if n.startswith(".settings.")],
      "no temp file left")
with open(os.environ["BLOCKIE_SETD_STORE"], "w") as f:
    json.dump({"test.level": 99, "test.mode": "b", "gone.key": 1}, f)
s2 = m.Store(keys)
check(s2.get("test.level") == 3 and s2.get("test.mode") == "b", "a stored value out of range falls back to the default")
with open(os.environ["BLOCKIE_SETD_STORE"], "w") as f:
    f.write("{not json")
check(m.Store(keys).get("test.mode") == "a", "a corrupt store starts from the defaults")
os.unlink(os.environ["BLOCKIE_SETD_STORE"])
sys.exit(1 if fails else 0)
EOF
r=$?
cat "$t/unit.out"
res $r "store and schema logic"

if command -v dbus-daemon > /dev/null; then
  cat > "$t/bus.conf" << EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$t/bus</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
  dbus-daemon --config-file="$t/bus.conf" --nofork --nopidfile &
  pids+=($!)
  for _ in $(seq 50); do [[ -S $t/bus ]] && break; sleep 0.1; done
  export BLOCKIE_SETD_BUS=unix:path=$t/bus
  me=$(id -un)
  BLOCKIE_SETD_WRITERS=$me python3 "$setd" 2> "$t/setd.err" &
  pids+=($!)
  for _ in $(seq 50); do "$cli" get test.mode > /dev/null 2>&1 && break; sleep 0.1; done
  DBUS_SESSION_BUS_ADDRESS=$BLOCKIE_SETD_BUS gdbus monitor --session --dest net.seilent.Blockie.Settings > "$t/mon" 2>&1 &
  pids+=($!)
  sleep 0.5

  [[ $("$cli" get test.mode) == a && $("$cli" get test.on) == false ]]
  res $? "bus: get returns schema defaults"
  "$cli" set test.level 5 && "$cli" set test.on true && "$cli" set test.ratio 0.25
  res $? "bus: set u, b and d through the CLI"
  [[ $("$cli" list test.) == $'test.big=1\ntest.fixed=x\ntest.level=5\ntest.mode=a\ntest.neg=0\ntest.on=true\ntest.ratio=0.25' ]]
  res $? "bus: list by prefix"
  "$cli" set test.level 12 2> "$t/err"
  r=$?
  [[ $r != 0 ]] && grep -q 'at most 9' "$t/err" && [[ $("$cli" get test.level) == 5 ]]
  res $? "bus: an out of range value is refused with the reason, the old value stays"
  "$cli" set test.level x 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'takes u' "$t/err"
  res $? "bus: the CLI refuses a value that does not parse for the type"
  "$cli" set test.big 4294967296 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'out of range' "$t/err" && [[ $("$cli" get test.big) == 1 ]]
  res $? "bus: the CLI refuses a u value over 32 bits"
  gd() {
    DBUS_SESSION_BUS_ADDRESS=$BLOCKIE_SETD_BUS gdbus call --session --dest net.seilent.Blockie.Settings \
      --object-path /net/seilent/Blockie/Settings --method net.seilent.Blockie.Settings1.Set "$@" 2>&1
  }
  out=$(gd test.big '<uint64 1099511627776>')
  [[ $out == *"takes u, not t"* && $("$cli" get test.big) == 1 ]]
  res $? "bus: a raw uint64 variant for a u key is refused, nothing stored"
  out=$(gd test.big '<int64 5>')
  [[ $out == *"takes u, not x"* ]]
  res $? "bus: an int64 variant for a u key is refused"
  [[ $("$cli" list test.) == *test.big=1* ]] && "$cli" get test.mode > /dev/null
  res $? "bus: Get and List still answer after the refused variants"
  "$cli" set test.nope 1 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'no key test.nope' "$t/err"
  res $? "bus: unknown key"
  "$cli" schema test.mode | python3 -c 'import json,sys; d=json.load(sys.stdin)["keys"]; sys.exit(list(d) != ["test.mode"] or d["test.mode"]["enum"] != ["a", "b"])'
  res $? "bus: schema by prefix"
  sleep 0.3
  grep -q "Changed ('test.level', <uint32 5>)" "$t/mon" && grep -q "Changed ('test.on', <true>)" "$t/mon"
  res $? "bus: Changed signals for the set keys"
  grep -q '"test.level": 5' "$t/store/settings.json"
  res $? "bus: the daemon wrote the store"

  kill "${pids[1]}"
  wait "${pids[1]}" 2> /dev/null
  BLOCKIE_SETD_WRITERS=nobody python3 "$setd" 2>> "$t/setd.err" &
  pids[1]=$!
  for _ in $(seq 50); do "$cli" get test.level > /dev/null 2>&1 && break; sleep 0.1; done
  [[ $("$cli" get test.level) == 5 ]]
  res $? "bus: values survive a daemon restart"
  "$cli" set test.level 6 2> "$t/err"
  [[ $? != 0 ]] && grep -q "may not set test.level" "$t/err" && [[ $("$cli" get test.level) == 5 ]]
  res $? "bus: a caller outside the writers is refused"
else
  echo "setd: no dbus-daemon here, the bus part did not run"
  fails=$((fails + 1))
fi

if (( fails )); then
  echo "setd: $fails failed"
  exit 1
fi
echo "setd: ok"
