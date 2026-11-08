#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
setd=${SETD_BIN:-/usr/libexec/blockie/blockie-setd}
[[ -x $setd ]] || setd=$here/../system_files/usr/libexec/blockie/blockie-setd
cli=${SET_BIN:-/usr/bin/blockie-set}
[[ -x $cli ]] || cli=$here/../system_files/usr/bin/blockie-set
schema=${SETD_SCHEMA:-/usr/share/blockie/schema.d}
[[ -d $schema ]] || schema=$here/../system_files/usr/share/blockie/schema.d
rules=${SETD_RULES:-/usr/share/polkit-1/rules.d/50-blockie-timezone.rules}
[[ -f $rules ]] || rules=$here/../system_files/usr/share/polkit-1/rules.d/50-blockie-timezone.rules
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

done_() {
  if (( fails )); then
    echo "setd: $fails failed"
    exit 1
  fi
  echo "setd: ok"
  exit 0
}

polkit() {
  RULES=$rules node - > "$t/polkit.out" 2>&1 << 'EOF'
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const td = "org.freedesktop.timedate1.";
const cases = [
  [td + "set-timezone", "blockie-set", "yes"],
  [td + "set-timezone", "blockie", "none"],
  [td + "set-timezone", "blockie-setd", "none"],
  [td + "set-timezone2", "blockie-set", "none"],
  [td + "set-time", "blockie-set", "none"],
  [td + "set-ntp", "blockie-set", "none"],
  [td + "set-local-rtc", "blockie-set", "none"],
  ["org.freedesktop.systemd1.manage-units", "blockie-set", "none"],
];
let bad = 0;
for (const [id, user, want] of cases) {
  const action = { id: id, lookup: () => undefined };
  let got = "none";
  for (const r of rules) {
    const v = r(action, { user: user });
    if (v !== undefined) {
      got = v;
      break;
    }
  }
  if (got !== want) {
    console.log(`${id} ${user}: ${got}, want ${want}`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
EOF
  local rc=$?
  [[ $rc == 0 ]] || sed 's/^/  /' "$t/polkit.out"
  res $rc "polkit: blockie-set may set the time zone, nothing else"
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "setd: polkit needs node" >&2; exit 2; }
  polkit
  done_
fi

mkdir -p "$t/schema" "$t/store" "$t/sessions" "$t/etc" "$t/td" "$t/lt"
cat > "$t/zone.tab" << 'EOF'
# tzdb timezone descriptions
#
#country-code	coordinates	TZ	comments
AR	-3436-05827	America/Argentina/Buenos_Aires	Buenos Aires (BA, CF)
HT	+1832-07220	America/Port-au-Prince
TT	+1039-06131	America/Port_of_Spain
US	+470659-1011757	America/North_Dakota/New_Salem	Central - ND (Morton rural)
AQ	-6640+14001	Antarctica/DumontDUrville	Dumont-d'Urville

SJ	+7800+01600	Arctic/Longyearbyen
JP	+353916+1394441	Asia/Tokyo
GB	+513030-0000731	Europe/London
FR	+4852+00220	Europe/Paris
JP	+353916+1394441	Asia/Tokyo
EOF
ln -s ../usr/share/zoneinfo/Asia/Tokyo "$t/etc/localtime"
: > "$t/td/calls"
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
    "test.zone": {"type": "s", "default": "UTC", "enum_from": "zones", "backend": "timedate1"},
    "test.zonetype": {"type": "b", "default": false, "enum_from": "zones", "backend": "timedate1"},
    "test.backend": {"type": "s", "default": "x", "backend": "other"},
    "session.default": {"type": "s", "default": "other"}
  }
}
EOF
printf 'DEFAULT=yes\n' > "$t/sessions/emulation.conf"
printf 'DEFAULT="yes"\n' > "$t/sessions/funeos.conf"
printf 'DEFAULT=no\n' > "$t/sessions/test-a.conf"
export BLOCKIE_SETD_SCHEMAS=$t/schema BLOCKIE_SETD_STORE=$t/store/settings.json BLOCKIE_SETD_SESSIONS=$t/sessions
export BLOCKIE_SETD_LOCALTIME=$t/etc/localtime BLOCKIE_SETD_ZONETAB=$t/zone.tab BLOCKIE_SETD_TIMEDATE_MS=1000

python3 - "$setd" > "$t/unit.out" 2>&1 << 'EOF'
import importlib.machinery
import importlib.util
import json
import os
import sys
import types

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
check(keys["system.timezone"]["backend"] == "timedate1"
      and not {"test.zone", "test.zonetype", "test.backend"} & set(keys),
      "only one timedate1 key of type s with enum_from zones loads, other backend keys are dropped")
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

t = os.path.dirname(os.environ["BLOCKIE_SETD_ZONETAB"])
check(m.zones() == {"UTC", "America/Argentina/Buenos_Aires", "America/North_Dakota/New_Salem", "America/Port-au-Prince",
                    "America/Port_of_Spain", "Antarctica/DumontDUrville", "Arctic/Longyearbyen", "Asia/Tokyo",
                    "Europe/London", "Europe/Paris"}, f"zones from the fixture: {sorted(m.zones())}")
for name, target in {"rel": "../usr/share/zoneinfo/Asia/Tokyo", "abs": "/usr/share/zoneinfo/Europe/London",
                     "posix": "../usr/share/zoneinfo/posix/Asia/Tokyo", "other": "../lib/Asia/Tokyo"}.items():
    os.symlink(target, f"{t}/lt/{name}")
with open(f"{t}/lt/file", "w") as f:
    f.write("TZif")
got = {}
for name in ("rel", "abs", "posix", "other", "file", "missing"):
    m.LOCALTIME = f"{t}/lt/{name}"
    got[name] = m.read_zone()
m.LOCALTIME = os.environ["BLOCKIE_SETD_LOCALTIME"]
check(got == {"rel": "Asia/Tokyo", "abs": "Europe/London", "posix": "posix/Asia/Tokyo", "other": "", "file": "",
              "missing": "UTC"}, f"Get reads the link, UTC when missing, empty when not a zoneinfo link: {got}")
zone = keys["system.timezone"]
try:
    m.check("system.timezone", zone, "Mars/Olympus")
    text = None
except m.Refused as err:
    text = (err.kind, str(err))
check(text is not None and text[0] == "Invalid" and "not a zone.tab zone" in text[1] and "Asia/" not in text[1]
      and "Europe/" not in text[1], f"a name outside zone.tab is Invalid with no zone list: {text}")
check(m.check("system.timezone", zone, "UTC") == "UTC"
      and m.check("system.timezone", zone, "Arctic/Longyearbyen") == "Arctic/Longyearbyen"
      and refused(lambda: m.check("system.timezone", zone, "Etc/UTC"), "Invalid"), "zone.tab ids and UTC are taken")
m.ZONETAB = f"{t}/none"
check(m.zones() == {"UTC"} and refused(lambda: m.check("system.timezone", zone, "Asia/Tokyo"), "Invalid"),
      "without zone.tab only UTC is taken")
with open(f"{t}/empty.tab", "w") as f:
    f.write("XX\t+0000+00000\t\tno name\nXX\t+0000+00000\t \n")
m.ZONETAB = f"{t}/empty.tab"
check(m.zones() == {"UTC"} and refused(lambda: m.check("system.timezone", zone, ""), "Invalid"),
      "a zone.tab line with an empty name adds nothing")
m.ZONETAB = os.environ["BLOCKIE_SETD_ZONETAB"]
with open(os.environ["BLOCKIE_SETD_STORE"], "w") as f:
    json.dump({"system.timezone": "Europe/Paris", "test.mode": "b"}, f)
s3 = m.Store(keys)
check("system.timezone" not in s3.values and s3.get("system.timezone") == "Asia/Tokyo" and s3.get("test.mode") == "b",
      "the store drops system.timezone, Get reads the link")
s3.set("test.level", 4)
with open(os.environ["BLOCKIE_SETD_STORE"]) as f:
    check("system.timezone" not in json.load(f), "the store never writes system.timezone")
order = []


class Mon:
    def connect(self, signal, f):
        order.append("connect")


class File:
    def monitor_file(self, flags, cancellable):
        order.append("monitor")
        return Mon()


gio, read = m.Gio, m.read_zone
m.Gio = types.SimpleNamespace(File=types.SimpleNamespace(new_for_path=lambda p: File()),
                              FileMonitorFlags=types.SimpleNamespace(WATCH_MOVES=1))
m.read_zone = lambda: order.append("read") or "UTC"
z = m.Timezone(None, "system.timezone")
m.Gio, m.read_zone = gio, read
check(order == ["monitor", "connect", "read"] and z.last_sent == "UTC" and isinstance(z.monitor, Mon),
      f"the monitor is created and kept before the seed read: {order}")
os.unlink(os.environ["BLOCKIE_SETD_STORE"])
sys.exit(1 if fails else 0)
EOF
r=$?
cat "$t/unit.out"
res $r "store and schema logic"

if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/setd.sh polkit) evaluates the rule"
fi

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
  python3 "$here/fake-timedate1.py" "$BLOCKIE_SETD_BUS" "$t/etc/localtime" "$t/td" 2> "$t/td.err" &
  pids+=($!)
  for _ in $(seq 50); do [[ -e $t/td/ready ]] && break; sleep 0.1; done
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

  gg() {
    DBUS_SESSION_BUS_ADDRESS=$BLOCKIE_SETD_BUS gdbus call --session --dest net.seilent.Blockie.Settings \
      --object-path /net/seilent/Blockie/Settings --method net.seilent.Blockie.Settings1.Get "$@" 2>&1
  }
  zl() { readlink "$t/etc/localtime"; }
  zn() { grep -c "Changed ('system.timezone'" "$t/mon"; }
  zlast() { grep "Changed ('system.timezone'" "$t/mon" | tail -n 1; }
  zvals() { grep "Changed ('system.timezone'" "$t/mon" | tail -n "+$(($1 + 1))" | sed "s/.*, <'\(.*\)'>)\$/\1/"; }
  zc() { wc -l < "$t/td/calls"; }
  zmode() { echo "$*" > "$t/td/mode"; }
  zi=../usr/share/zoneinfo

  c=$(zc)
  [[ $("$cli" get system.timezone) == Asia/Tokyo && $("$cli" list system.) == system.timezone=Asia/Tokyo && $(zc) == "$c" ]]
  res $? "zone: Get and List read the link and call nothing"
  "$cli" schema system.timezone | python3 -c 'import json,sys; d=json.load(sys.stdin)["keys"]["system.timezone"]; sys.exit(d["backend"] != "timedate1" or d["enum_from"] != "zones")'
  res $? "zone: schema"

  n=$(zn)
  "$cli" set system.timezone Europe/London
  r=$?
  sleep 0.4
  [[ $r == 0 && $(zl) == $zi/Europe/London && $("$cli" get system.timezone) == Europe/London && $(zn) == $((n + 1)) &&
    $(zlast) == *"<'Europe/London'>)" && $(tail -n 1 "$t/td/calls") == "Europe/London false" ]]
  res $? "zone: blockie-set set system.timezone Europe/London calls SetTimezone, the link changes, one Changed"

  n=$(zn) c=$(zc)
  "$cli" set system.timezone Europe/London
  r=$?
  sleep 0.3
  [[ $r == 0 && $(zc) == "$c" && $(zn) == "$n" ]]
  res $? "zone: the live zone again makes no call and no Changed"

  out=$(gd system.timezone "<'Mars/Olympus'>")
  [[ $out == *Settings.Error.Invalid:*"not a zone.tab zone"* && $out != *Asia/* && $out != *Europe/* && $(zc) == "$c" ]]
  res $? "zone: a name outside zone.tab is Invalid with no zone list and no call"

  for f in deny:InteractiveAuthorizationRequired invalid:InvalidArgs; do
    zmode "${f%%:*}"
    n=$(zn)
    out=$(gd system.timezone "<'Europe/Paris'>")
    sleep 0.3
    [[ $out == *Settings.Error.Failed:*"${f#*:}"* && $(zl) == $zi/Europe/London && $(zn) == "$n" ]]
    res $? "zone: ${f%%:*}: Failed with ${f#*:}, the link unchanged, no Changed"
  done

  zmode hang 1500
  n=$(zn)
  gd system.timezone "<'Europe/Paris'>" > "$t/hang" &
  hp=$!
  sleep 0.2
  g=$(gg system.timezone)
  kill -0 "$hp" 2> /dev/null
  alive=$?
  wait "$hp"
  busy=$(gd system.timezone "<'Asia/Tokyo'>")
  sleep 1.5
  [[ $(< "$t/hang") == *Settings.Error.Timeout:* && $g == "(<'Europe/London'>,)" && $alive == 0 &&
    $busy == *Settings.Error.Busy:* && $(zl) == $zi/Europe/Paris && $(zn) == $((n + 1)) && $(zlast) == *"<'Europe/Paris'>)" ]]
  res $? "zone: hang: a Get answered meanwhile, Timeout, Busy right after, the late write gives one Changed"

  zmode delay 500
  n=$(zn) c=$(zc)
  gd system.timezone "<'Europe/London'>" > "$t/delay" &
  hp=$!
  sleep 0.15
  busy=$(gd system.timezone "<'Asia/Tokyo'>")
  bad=$(gd system.timezone "<'Mars/Olympus'>")
  kill -0 "$hp" 2> /dev/null
  alive=$?
  wait "$hp"
  r=$?
  sleep 0.4
  [[ $busy == *Settings.Error.Busy:* && $bad == *Settings.Error.Busy:* && $alive == 0 && $r == 0 &&
    $(zl) == $zi/Europe/London && $(zn) == $((n + 1)) && $(zc) == $((c + 1)) ]]
  res $? "zone: delay: a second Set, valid or not, is Busy at once, the first lands with one Changed"

  zmode delay 1400
  out=$(gd system.timezone "<'Europe/Paris'>")
  busy=$(gd system.timezone "<'Asia/Tokyo'>")
  sleep 0.6
  zmode ok
  ok=$(gd system.timezone "<'Asia/Tokyo'>")
  sleep 0.4
  [[ $out == *Settings.Error.Timeout:* && $busy == *Settings.Error.Busy:* && $ok == "()" && $(zl) == $zi/Asia/Tokyo ]]
  res $? "zone: a late reply ends the Busy before the second timeout period"

  n=$(zn)
  ln -s $zi/Europe/Paris "$t/etc/.localtime.new" && mv -T "$t/etc/.localtime.new" "$t/etc/localtime"
  sleep 0.4
  [[ $(zn) == $((n + 1)) && $(zlast) == *"<'Europe/Paris'>)" && $("$cli" get system.timezone) == Europe/Paris ]]
  res $? "zone: an outside atomic link change gives one Changed"

  n=$(zn) c=$(zc)
  "$cli" set system.timezone Asia/Tokyo
  r=$?
  sleep 0.4
  [[ $r == 0 && $(zl) == $zi/Asia/Tokyo && $(zvals "$n") == Asia/Tokyo && $(zc) == $((c + 3)) &&
    $(tail -n 3 "$t/td/calls") == $'Asia/Tokyo false\nEurope/Paris false\nAsia/Tokyo false' ]]
  res $? "zone: stale: a Set of the zone timedated remembers resyncs through the link's zone, one Changed"

  zmode stale-all
  n=$(zn) c=$(zc)
  out=$(gd system.timezone "<'Europe/London'>")
  sleep 0.3
  [[ $out == *Settings.Error.Failed:*"link is Asia/Tokyo after SetTimezone"* && $(zl) == $zi/Asia/Tokyo &&
    $(zn) == "$n" && $(zc) == $((c + 3)) &&
    $(tail -n 3 "$t/td/calls") == $'Europe/London false\nAsia/Tokyo false\nEurope/London false' ]]
  res $? "zone: stale-all: still not the zone after the resync gives Failed with the link, no Changed"

  ln -s $zi/Europe/Paris "$t/etc/.localtime.new" && mv -T "$t/etc/.localtime.new" "$t/etc/localtime"
  sleep 0.4
  zmode stale-all 1200
  c=$(zc)
  out=$(gd system.timezone "<'Europe/London'>")
  sleep 1.6
  [[ $out == *Settings.Error.Timeout:* && $(zl) == $zi/Europe/Paris && $(zc) == $((c + 2)) &&
    $(tail -n 2 "$t/td/calls") == $'Europe/London false\nEurope/Paris false' ]]
  res $? "zone: the resync steps share one deadline, the second step times out and no third call goes out"

  zmode ok
  printf 'TZif' > "$t/etc/.localtime.new" && mv -T "$t/etc/.localtime.new" "$t/etc/localtime"
  sleep 0.4
  [[ $("$cli" get system.timezone) == "" ]]
  r=$?
  n=$(zn) c=$(zc)
  "$cli" set system.timezone Asia/Tokyo
  r2=$?
  sleep 0.4
  [[ $r == 0 && $r2 == 0 && $(zl) == $zi/Asia/Tokyo && $(zvals "$n") == $'UTC\nAsia/Tokyo' && $(zc) == $((c + 3)) &&
    $(tail -n 3 "$t/td/calls") == $'Asia/Tokyo false\nUTC false\nAsia/Tokyo false' ]]
  res $? "zone: with a regular file at the link the resync goes through UTC and lands on the zone"

  n=$(zn)
  rm -f "${t:?}/etc/localtime"
  sleep 0.04
  ln -s $zi/Europe/London "$t/etc/localtime"
  sleep 0.4
  [[ $(zvals "$n") == Europe/London ]]
  res $? "zone: an outside rm then ln -s within 50 ms gives one Changed, never UTC"

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
  [[ $("$cli" get system.timezone) == Europe/London ]]
  res $? "zone: a restarted setd reads the link"
  "$cli" set system.timezone Europe/Paris 2> "$t/err"
  [[ $? != 0 ]] && grep -q "may not set system.timezone" "$t/err" && [[ $(zl) == $zi/Europe/London ]]
  res $? "zone: a caller outside the writers may not set the zone"
else
  echo "setd: no dbus-daemon here, the bus part did not run"
  fails=$((fails + 1))
fi

done_
