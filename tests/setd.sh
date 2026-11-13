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
policy=${SETD_POLICY:-/usr/share/dbus-1/system.d/net.seilent.Blockie.Settings.conf}
[[ -f $policy ]] || policy=$here/../system_files/usr/share/dbus-1/system.d/net.seilent.Blockie.Settings.conf
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

mkdir -p "$t/schema" "$t/store" "$t/sessions" "$t/etc" "$t/td" "$t/lt" "$t/run" "$t/x" "$t/xrun"
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
cat > "$t/x/10-x.json" << 'EOF'
{
  "keys": {
    "x.a": {"type": "s", "default": "on", "enum": ["on", "off"], "map": true},
    "x.b": {"type": "s", "default": "off", "enum": ["on", "off"], "map": true},
    "x.n": {"type": "u", "default": 7, "map": true},
    "x.on": {"type": "b", "default": true, "map": true},
    "x.off": {"type": "b", "default": false, "map": false},
    "x.free": {"type": "s", "default": "x", "map": true},
    "x.spaced": {"type": "s", "default": "a b", "enum": ["a b"], "map": true},
    "x.int": {"type": "b", "default": false, "map": 1},
    "x.zone": {"type": "s", "default": "UTC", "enum_from": "zones", "backend": "timedate1"}
  },
  "rules": [
    {"need": ["on"], "keys": ["x.a", "x.b"], "message": "x needs one on"},
    {"need": ["on"], "keys": ["x.a", "x.gone"], "message": "names a gone key"},
    {"need": ["off"], "keys": ["x.a"], "message": "the defaults break this"},
    {"need": "on", "keys": ["x.a"], "message": "bad shape"},
    {"need": ["on"], "keys": ["x.zone"], "message": "names a backend key"}
  ]
}
EOF
printf 'DEFAULT=yes\n' > "$t/sessions/emulation.conf"
printf 'DEFAULT="yes"\n' > "$t/sessions/funeos.conf"
printf 'DEFAULT=no\n' > "$t/sessions/test-a.conf"
export BLOCKIE_SETD_SCHEMAS=$t/schema BLOCKIE_SETD_STORE=$t/store/settings.json BLOCKIE_SETD_SESSIONS=$t/sessions
export BLOCKIE_SETD_LOCALTIME=$t/etc/localtime BLOCKIE_SETD_ZONETAB=$t/zone.tab BLOCKIE_SETD_TIMEDATE_MS=1000
export BLOCKIE_SETD_EFFECTIVE=$t/run

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

store = os.environ["BLOCKIE_SETD_STORE"]
run = os.environ["BLOCKIE_SETD_EFFECTIVE"]
logs = []
m.log = logs.append
buttons = [f"buttons.{b}.{g}" for b in ("home", "extra1", "extra2", "extra3") for g in ("tap", "hold")]
words = ["none", "switcher", "game-menu", "game-quit"]
defaults = {"buttons.home.tap": "none", "buttons.home.hold": "switcher", "buttons.extra1.tap": "none",
            "buttons.extra1.hold": "none", "buttons.extra2.tap": "none", "buttons.extra2.hold": "none",
            "buttons.extra3.tap": "game-menu", "buttons.extra3.hold": "game-quit"}
default_map = ["version 1", "home tap none", "home hold switcher", "home free no", "extra1 tap none",
               "extra1 hold none", "extra1 free yes", "extra2 tap none", "extra2 hold none", "extra2 free yes",
               "extra3 tap game-menu", "extra3 hold game-quit", "extra3 free no"]
rules = m.load_rules(keys)
check(all(keys[k]["type"] == "s" and keys[k]["enum"] == words and keys[k]["map"] is True
          and keys[k]["group"] == "buttons" for k in buttons) and {k: keys[k]["default"] for k in buttons} == defaults,
      "the 8 buttons keys load with their enum, group, map and defaults")
check([r["message"] for r in rules] == ["the session switcher needs a button",
                                       "a game needs a button for its menu or quit"]
      and [r["need"] for r in rules] == [["switcher"], ["game-menu", "game-quit"]]
      and all(r["keys"] == buttons for r in rules),
      f"R-switch and R-game load over the 8 keys: {rules}")
check(not [line for line in logs if "rule" in line], f"the shipped rules load with no log: {logs}")
clocks = keys["power.clocks"]
check(clocks["type"] == "s" and clocks["default"] == "trip72-big1443"
      and clocks["enum"] == ["trip72-big1443", "trip65", "trip72", "trip80"] and clocks["group"] == "power"
      and clocks["label"] == "Clocks" and clocks["map"] is True,
      f"power.clocks loads with its four ids, default trip72-big1443, group power, map true: {clocks}")


def stored():
    try:
        with open(store) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def read(name, d=run):
    with open(os.path.join(d, name)) as f:
        return f.read().splitlines()


def message(f):
    try:
        f()
    except m.Refused as err:
        return err.kind, str(err)
    return None


s = m.Store(keys, rules)
s.publish()
check(read("buttons") == default_map and oct(os.stat(os.path.join(run, "buttons")).st_mode & 0o777) == "0o644",
      f"the buttons map holds the defaults in 13 lines, 0644: {read('buttons')}")
check(read("settings") == ["version 1"] + [f"{k} {defaults[k]}" for k in sorted(buttons)] + ["power.clocks trip72-big1443"]
      and oct(os.stat(os.path.join(run, "settings")).st_mode & 0o777) == "0o644",
      f"the settings map holds every map key in sorted order with its effective value: {read('settings')}")
check(refused(lambda: s.set("buttons.home.tap", "back"), "Invalid") and stored() is None, "an unknown word is Invalid")
saves = []
save = s.save
s.save = lambda values: saves.append(dict(values)) or save(values)
check(message(lambda: s.set("buttons.home.hold", "none")) == ("Invalid", "the session switcher needs a button")
      and stored() is None and not saves, "the Set that clears the last switcher is Invalid with R-switch's message")
check(s.set_many({"buttons.extra1.hold": "switcher", "buttons.home.hold": "none"}) == ["buttons.extra1.hold",
                                                                                      "buttons.home.hold"]
      and stored() == {"buttons.extra1.hold": "switcher", "buttons.home.hold": "none"} and len(saves) == 1,
      "the same move as one SetMany is taken in one store write and names both keys as changed")
s.publish()
moved = read("buttons")
check(moved[1:7] == ["home tap none", "home hold none", "home free yes", "extra1 tap none", "extra1 hold switcher",
                     "extra1 free no"] and moved[7:] == default_map[7:], f"the map follows the move: {moved}")
check(message(lambda: s.reset(["buttons.extra1.hold"])) == ("Invalid", "the session switcher needs a button")
      and stored() == {"buttons.extra1.hold": "switcher", "buttons.home.hold": "none"} and len(saves) == 1
      and read("buttons") == moved,
      "a partial Reset that leaves no switcher is Invalid, the store and the map unchanged")
check(s.set("buttons.extra3.tap", "none") and s.get("buttons.extra3.tap") == "none",
      "with extra3 hold game-quit, extra3 tap none passes")
check(message(lambda: s.set("buttons.extra3.hold", "none")) == ("Invalid", "a game needs a button for its menu or quit")
      and s.get("buttons.extra3.hold") == "game-quit", "then extra3 hold none is Invalid with R-game's message")
before, n = stored(), len(saves)
check(refused(lambda: s.set_many({"buttons.extra2.tap": "switcher", "buttons.extra2.hold": "bogus"}), "Invalid")
      and refused(lambda: s.set_many({"buttons.extra2.tap": "switcher", "buttons.nope": "none"}), "UnknownKey")
      and refused(lambda: s.set_many({"buttons.extra2.tap": "switcher", "test.fixed": "y"}), "ReadOnly")
      and stored() == before and len(saves) == n, "a SetMany with one bad key changes nothing")
check(message(lambda: s.set_many({"system.timezone": "UTC"})) == ("ReadOnly", "system.timezone takes only Set")
      and message(lambda: s.reset(["system.timezone"])) == ("ReadOnly", "system.timezone takes only Set")
      and refused(lambda: s.reset(["buttons.nope"]), "UnknownKey") and stored() == before,
      "SetMany and Reset refuse a backend key with ReadOnly and an unknown key with UnknownKey")
check(s.set_many({"buttons.extra1.hold": "switcher"}) == [] and len(saves) == n,
      "a SetMany of the stored values changes and writes nothing")
check(s.reset(buttons) == ["buttons.extra1.hold", "buttons.extra3.tap", "buttons.home.hold"] and stored() == {}
      and len(saves) == n + 1, "a Reset of all 8 passes in one write and names the keys whose value changed")
s.publish()
check(read("buttons") == default_map, "after the full Reset the map holds the defaults again")
check(not [f for f in os.listdir(run) if f.startswith(".")], "no temp file left in the map dir")
check(refused(lambda: s.set("power.clocks", "trip90"), "Invalid") and s.get("power.clocks") == "trip72-big1443",
      "power.clocks refuses an id outside its enum, the default stays")
check(s.set("power.clocks", "trip80") and s.get("power.clocks") == "trip80", "power.clocks takes trip80")
s.publish()
check("power.clocks trip80" in read("settings") and "power.clocks trip72-big1443" not in read("settings"),
      f"the settings map carries power.clocks after a Set: {read('settings')}")

with open(store, "w") as f:
    json.dump({"buttons.home.hold": "none", "buttons.extra3.tap": "none", "buttons.extra2.tap": "switcher",
               "test.mode": "b"}, f)
logs.clear()
s = m.Store(keys, rules)
check(s.get("buttons.extra2.tap") == "switcher" and s.get("buttons.home.hold") == "none"
      and s.get("buttons.extra3.tap") == "none" and not logs,
      f"a stored layout that keeps the rules loads as stored: {logs}")
with open(store, "w") as f:
    json.dump({"buttons.home.hold": "none", "buttons.extra3.tap": "none", "buttons.extra1.tap": "game-quit",
               "test.mode": "b"}, f)
logs.clear()
s = m.Store(keys, rules)
check(all(s.get(k) == defaults[k] for k in buttons) and s.get("test.mode") == "b"
      and [line for line in logs if "the session switcher needs a button" in line],
      f"a stored layout breaking R-switch at load: the rule's keys use the defaults, logged, other keys stay: {logs}")
with open(store, "w") as f:
    f.write("{not json")
logs.clear()
s = m.Store(keys, rules)
check(all(s.get(k) == defaults[k] for k in buttons) and [line for line in logs if "starting from the defaults" in line],
      f"a corrupt store starts from the defaults, logged: {logs}")
os.unlink(store)

x = os.path.join(os.path.dirname(store), "..", "x")
m.SCHEMAS = x
logs.clear()
xkeys = m.load_schema()
check(set(xkeys) == {"x.a", "x.b", "x.n", "x.on", "x.off", "x.zone"}
      and len([line for line in logs if "map takes true or false" in line]) == 3,
      f"map must be a boolean and a mapped s key needs an enum of words: {sorted(xkeys)} {logs}")
logs.clear()
xrules = m.load_rules(xkeys)
check([r["message"] for r in xrules] == ["x needs one on"], f"only the sound fixture rule stays: {xrules}")
check([line for line in logs if "rule 2 names unknown key x.gone, dropped" in line]
      and [line for line in logs if "rule 3: the defaults break it (the defaults break this), dropped" in line]
      and [line for line in logs if "rule 4 is not need, keys and message, dropped" in line]
      and [line for line in logs if "rule 5 names unknown key x.zone, dropped" in line],
      f"a rule naming an unknown or backend key, a rule its defaults break and a malformed rule are dropped: {logs}")
m.SCHEMAS = os.environ["BLOCKIE_SETD_SCHEMAS"]
xrun = os.path.join(os.path.dirname(store), "..", "xrun")
m.EFFECTIVE = xrun
with open(os.path.join(xrun, "buttons"), "w") as f:
    f.write("version 1\n")
xs = m.Store(xkeys, xrules)
xs.publish()
check(read("settings", xrun) == ["version 1", "x.a on", "x.b off", "x.n 7", "x.on true"]
      and not os.path.exists(os.path.join(xrun, "buttons")),
      f"the settings map has b lowercase and u in decimal; no buttons keys, no buttons map: {read('settings', xrun)}")
check(message(lambda: xs.set_many({"x.a": "off"})) == ("Invalid", "x needs one on")
      and xs.set_many({"x.a": "off", "x.b": "on"}),
      "a fixture rule refuses and passes as the shipped ones do")
m.EFFECTIVE = run
os.unlink(store)
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

python3 - "$policy" > "$t/policy.out" 2>&1 << 'EOF'
import sys
import xml.etree.ElementTree as ET

want = ("Set", "SetMany", "Reset")
got = {}
for p in ET.parse(sys.argv[1]).getroot().iter("policy"):
    for a in p.iter("allow"):
        if a.get("send_member") in want:
            got.setdefault(a.get("send_member"), set()).add(p.get("user") or p.get("context"))
print(got)
sys.exit(0 if got == {m: {"root", "blockie"} for m in want} else 1)
EOF
r=$?
[[ $r == 0 ]] || sed 's/^/  /' "$t/policy.out"
res $r "policy: Set, SetMany and Reset go to root and blockie only"

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
  rm -f "${t:?}/run/buttons" "${t:?}/run/settings"
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

  bm() { cat "$t/run/buttons"; }
  bc() { grep -c "Changed ('buttons\." "$t/mon"; }
  bdbus() {
    DBUS_SESSION_BUS_ADDRESS=$BLOCKIE_SETD_BUS gdbus call --session --dest net.seilent.Blockie.Settings \
      --object-path /net/seilent/Blockie/Settings --method "net.seilent.Blockie.Settings1.$1" "$2" 2>&1
  }
  dmap=$'version 1\nhome tap none\nhome hold switcher\nhome free no\nextra1 tap none\nextra1 hold none\nextra1 free yes'
  dmap+=$'\nextra2 tap none\nextra2 hold none\nextra2 free yes\nextra3 tap game-menu\nextra3 hold game-quit\nextra3 free no'
  [[ $(bm) == "$dmap" && $(stat -c %a "$t/run/buttons") == 644 && $(wc -l < "$t/run/buttons") == 13 &&
    $(head -n 1 "$t/run/settings") == "version 1" && $(grep -c '^buttons\.' "$t/run/settings") == 8 ]]
  res $? "bus: setd writes the buttons map (13 lines, 0644) and the settings map with the defaults at start"
  "$cli" schema buttons. | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(len(d["keys"]) != 8 or [r["message"] for r in d["rules"]] != ["the session switcher needs a button", "a game needs a button for its menu or quit"])'
  r=$?
  "$cli" schema test. | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["rules"] != [])'
  [[ $r == 0 && $? == 0 ]]
  res $? "bus: Schema(buttons.) carries the 8 keys with R-switch and R-game, another prefix no rule"
  "$cli" set buttons.home.tap back 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'buttons.home.tap is one of none, switcher, game-menu, game-quit' "$t/err"
  res $? "bus: an unknown word is refused"
  cp "$t/store/settings.json" "$t/store.before"
  "$cli" set buttons.home.hold none 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'the session switcher needs a button' "$t/err" &&
    cmp -s "$t/store/settings.json" "$t/store.before" && [[ $(bm) == "$dmap" ]]
  res $? "bus: the Set that clears the last switcher exits 1 with R-switch's message, store and map unchanged"
  n=$(bc)
  "$cli" set buttons.extra1.hold switcher && "$cli" set buttons.home.hold none
  r=$?
  sleep 0.3
  [[ $r == 0 && $(sed -n 2,7p "$t/run/buttons") == $'home tap none\nhome hold none\nhome free yes\nextra1 tap none\nextra1 hold switcher\nextra1 free no' &&
    $(bc) == $((n + 2)) ]] && grep -qx 'buttons.extra1.hold switcher' "$t/run/settings"
  res $? "bus: two Sets move the switcher to extra1, new place first; both maps and Changed follow"
  n=$(bc)
  "$cli" set-many buttons.extra2.hold=switcher buttons.extra1.hold=none
  r=$?
  sleep 0.3
  [[ $r == 0 && $(sed -n 5,10p "$t/run/buttons") == $'extra1 tap none\nextra1 hold none\nextra1 free yes\nextra2 tap none\nextra2 hold switcher\nextra2 free no' &&
    $(bc) == $((n + 2)) ]] && grep -q "Changed ('buttons.extra1.hold', <'none'>)" "$t/mon" &&
    grep -q "Changed ('buttons.extra2.hold', <'switcher'>)" "$t/mon"
  res $? "bus: set-many moves it again in one call, one Changed per changed key"
  cp "$t/run/buttons" "$t/map.before"
  cp "$t/store/settings.json" "$t/store.before"
  "$cli" reset buttons.extra2.hold 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'the session switcher needs a button' "$t/err" && cmp -s "$t/run/buttons" "$t/map.before" &&
    cmp -s "$t/store/settings.json" "$t/store.before"
  res $? "bus: a partial reset that leaves no switcher exits 1 with R-switch's message, store and map unchanged"
  "$cli" set-many buttons.extra3.tap=switcher buttons.extra3.hold=bogus 2> "$t/err"
  r=$?
  "$cli" set-many buttons.extra3.tap 2>> "$t/err"
  [[ $r != 0 && $? != 0 ]] && grep -q 'buttons.extra3.hold is one of' "$t/err" && grep -q 'is not <key>=<value>' "$t/err" &&
    cmp -s "$t/run/buttons" "$t/map.before" && cmp -s "$t/store/settings.json" "$t/store.before"
  res $? "bus: a set-many with one bad value or no = changes nothing"
  a=$(bdbus SetMany "{'system.timezone': <'UTC'>}")
  b=$(bdbus Reset "['system.timezone']")
  c=$(bdbus SetMany "{'buttons.home.tap': <5>}")
  [[ $a == *Settings.Error.ReadOnly:* && $b == *Settings.Error.ReadOnly:* && $c == *"takes s, not i"* ]] &&
    cmp -s "$t/store/settings.json" "$t/store.before"
  res $? "bus: SetMany and Reset of a backend key are ReadOnly, a wrong variant type is Invalid"
  n=$(bc)
  "$cli" reset buttons.home.tap buttons.home.hold buttons.extra1.tap buttons.extra1.hold buttons.extra2.tap \
    buttons.extra2.hold buttons.extra3.tap buttons.extra3.hold
  r=$?
  sleep 0.3
  [[ $r == 0 && $(bm) == "$dmap" && $(bc) == $((n + 2)) ]] &&
    ! grep -q '"buttons\.' "$t/store/settings.json" && ! ls -A "$t/run" | grep -q '^\.'
  res $? "bus: a reset of all 8 restores the default map, Changed for the two keys that changed, no temp file"
  [[ $(grep -c '^power\.clocks ' "$t/run/settings") == 1 ]] && grep -qx 'power.clocks trip72-big1443' "$t/run/settings"
  res $? "bus: the settings map holds power.clocks at its default trip72-big1443"
  "$cli" set power.clocks trip65
  r=$?
  sleep 0.3
  [[ $r == 0 && $("$cli" get power.clocks) == trip65 ]] && grep -qx 'power.clocks trip65' "$t/run/settings"
  res $? "bus: blockie-set set power.clocks trip65 lands in the settings map"
  "$cli" set power.clocks trip90 2> "$t/err"
  [[ $? != 0 ]] && grep -q 'power.clocks is one of trip72-big1443, trip65, trip72, trip80' "$t/err" &&
    grep -qx 'power.clocks trip65' "$t/run/settings"
  res $? "bus: an id outside the enum is refused, the map keeps trip65"

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
  printf 'version 1\n' > "$t/run/buttons"
  BLOCKIE_SETD_WRITERS=nobody python3 "$setd" 2>> "$t/setd.err" &
  pids[1]=$!
  for _ in $(seq 50); do "$cli" get test.level > /dev/null 2>&1 && break; sleep 0.1; done
  [[ $("$cli" get test.level) == 5 ]]
  res $? "bus: values survive a daemon restart"
  [[ $(bm) == "$dmap" ]]
  res $? "bus: a restarted setd writes the map again"
  "$cli" reset buttons.home.hold 2> "$t/err"
  r=$?
  "$cli" set-many buttons.extra1.hold=switcher 2>> "$t/err"
  [[ $r != 0 && $? != 0 && $(grep -c "may not set" "$t/err") == 2 ]]
  res $? "bus: a caller outside the writers may not reset or set-many"
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
