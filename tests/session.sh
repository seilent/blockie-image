#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin=${SESSION_BIN:-/usr/bin/blockie-session}
[[ -x $bin ]] || bin=$here/../system_files/usr/bin/blockie-session
t=$(mktemp -d "${TMPDIR:-/tmp}/session.XXXXXX")
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

done_() {
  if (( fails )); then
    echo "session: $fails failed"
    exit 1
  fi
  echo "session: ok"
  exit 0
}

rules=${SESSION_RULES:-/usr/share/polkit-1/rules.d/50-blockie-session.rules}
[[ -f $rules ]] || rules=$here/../system_files/usr/share/polkit-1/rules.d/50-blockie-session.rules

polkit() {
  RULES=$rules node - > "$t/polkit.out" 2>&1 << 'EOF'
const fs = require("fs");
const rules = [];
const polkit = { Result: { YES: "yes", NO: "no", AUTH_ADMIN: "auth_admin" }, addRule: (f) => rules.push(f) };
new Function("polkit", fs.readFileSync(process.env.RULES, "utf8"))(polkit);
const units = "org.freedesktop.systemd1.manage-units";
const cases = [
  [units, "blockie", "blockie-session-switch@x.service", "start", "yes"],
  [units, "blockie", "blockie-session-appswitch@x.service", "start", "yes"],
  [units, "blockie", "blockie-session-revive@x.service", "start", "yes"],
  [units, "blockie", "blockie-session-switch@x.service", "stop", "none"],
  [units, "blockie", "blockie-session-appswitch@x.service", "stop", "none"],
  [units, "blockie", "blockie-session-revive@x.service", "stop", "none"],
  [units, "blockie", "blockie-session-switch@x.service", "restart", "none"],
  [units, "blockie", "blockie-session-appswitch@x.service", "restart", "none"],
  [units, "blockie", "blockie-session-revive@x.service", "restart", "none"],
  [units, "blockie", "blockie-session-appswitch@X.service", "start", "none"],
  [units, "blockie", "blockie-session-appswitch@.service", "start", "none"],
  [units, "blockie", "blockie-session-appswitch@x;y.service", "start", "none"],
  [units, "blockie", "blockie-session-switcher.service", "start", "none"],
  [units, "blockie", "blockie-session-boot.service", "start", "none"],
  [units, "blockie", "blockie-session-ready@0123456789abcdef0123456789abcdef.service", "start", "yes"],
  [units, "blockie", "blockie-session-ready@0123456789abcdef0123456789abcdef.service", "stop", "none"],
  [units, "blockie", "blockie-session-ready@0123456789abcdef0123456789abcdef.service", "restart", "none"],
  [units, "blockie", "blockie-session-ready.service", "start", "none"],
  [units, "blockie", "blockie-session-ready@x.service", "start", "none"],
  [units, "blockie", "blockie-session-ready@0123456789abcdef0123456789abcde.service", "start", "none"],
  [units, "blockie", "blockie-session-ready@0123456789abcdef0123456789abcdef0.service", "start", "none"],
  [units, "blockie", "blockie-session-ready@0123456789ABCDEF0123456789ABCDEF.service", "start", "none"],
  [units, "other", "blockie-session-ready@0123456789abcdef0123456789abcdef.service", "start", "none"],
  [units, "blockie", "blockie-poweroff.service", "start", "none"],
  [units, "other", "blockie-session-switch@x.service", "start", "none"],
  [units, "other", "blockie-session-appswitch@x.service", "start", "none"],
  [units, "other", "blockie-session-revive@x.service", "start", "none"],
  ["org.freedesktop.systemd1.manage-unit-files", "blockie", "blockie-session-appswitch@x.service", "start", "none"],
];
let bad = 0;
for (const [id, user, unit, verb, want] of cases) {
  const details = { unit: unit, verb: verb };
  const action = { id: id, lookup: (k) => details[k] };
  let got = "none";
  for (const r of rules) {
    const v = r(action, { user: user });
    if (v !== undefined) {
      got = v;
      break;
    }
  }
  if (got !== want) {
    console.log(`${id} ${user} ${verb} ${unit}: ${got}, want ${want}`);
    bad++;
  }
}
process.exit(bad ? 1 : 0);
EOF
  local rc=$?
  [[ $rc == 0 ]] || sed 's/^/  /' "$t/polkit.out"
  res $rc "polkit: blockie may start switch@, appswitch@ and revive@ of a session name and ready@ of a 32 hex invocation id, nothing else"
}

if [[ ${1:-} == polkit ]]; then
  command -v node > /dev/null || { echo "session: polkit needs node" >&2; exit 2; }
  polkit
  done_
fi
if command -v node > /dev/null; then
  polkit
else
  echo "polkit: no node in the image, the host leg (tests/session.sh polkit) evaluates the rules"
fi

R=$t/root
mkdir -p "$R/usr/lib/blockie/sessions.d" "$R/etc/blockie/sessions.d" "$R/usr/lib/systemd/user" "$t/bin" "$t/run" \
  "$t/state" "$t/units" "$t/win"
printf '0.50 0.50\n' > "$t/uptime"

session() {
  local dir=$1 name=$2
  shift 2
  printf '%s\n' "$@" > "$R/$dir/$name.conf"
}
for n in a b c d; do
  : > "$R/usr/lib/systemd/user/blockie-test-$n.service"
done
session usr/lib/blockie/sessions.d a LABEL=Alpha UNIT=blockie-test-a.service APP_ID=test.a DEFAULT=yes
session usr/lib/blockie/sessions.d b 'LABEL="Bravo"' UNIT=blockie-test-b.service APP_ID=test.b DEFAULT=no
session usr/lib/blockie/sessions.d c LABEL=Charlie UNIT=blockie-test-c.service APP_ID=test.c BACKGROUND=stop
session usr/lib/blockie/sessions.d d LABEL=Delta UNIT=blockie-test-d.service APP_ID=test.d BACKGROUND=run \
  CHECK=/usr/libexec/check-d INSTALL=/usr/libexec/install-d
session usr/lib/blockie/sessions.d bad1 UNIT=blockie-none.service APP_ID=test.x
session usr/lib/blockie/sessions.d bad2 UNIT=blockie-test-a.service 'APP_ID=bad app'
session usr/lib/blockie/sessions.d bad3 UNIT=blockie-test-a.service APP_ID=test.y BACKGROUND=sleep
session usr/lib/blockie/sessions.d bad4 UNIT=../x.service APP_ID=test.z
session usr/lib/blockie/sessions.d bad8 UNIT=blockie-test-a.service APP_ID=test.y CHECK=/usr/../tmp/x
session usr/lib/blockie/sessions.d bad9 UNIT=blockie-test-a.service APP_ID=test.y INSTALL=/usr/lib/../../tmp/x
: > "$R/usr/lib/systemd/user/pipewire.service"
session usr/lib/blockie/sessions.d bad10 UNIT=pipewire.service APP_ID=test.y
session etc/blockie/sessions.d b LABEL=Bravo2 UNIT=blockie-test-b.service APP_ID=test.b DEFAULT=yes
mkdir -p "$R/usr/libexec"
printf '#!/bin/sh\nexit "${CHECK_RC:-0}"\n' > "$R/usr/libexec/check-d"
chmod +x "$R/usr/libexec/check-d"

cat > "$t/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE/log"
u=${*: -1}
st=$FAKE/units/$u
if [[ $1 == --user ]]; then
  shift
  case $1 in
    show)
      p=$3
      case $p in
        ActiveState) [[ -f $st.active ]] && echo active || echo inactive ;;
        FreezerState) [[ -f $st.frozen ]] && echo frozen || echo running ;;
        Job) [[ ! -f $st.job ]] || echo 1 ;;
        InvocationID) cat "$st.inv" 2> /dev/null ;;
      esac
      ;;
    start)
      [[ ! -f $FAKE/fail-start ]] || exit 1
      app=$(sed -n "s/^$u //p" "$FAKE/apps")
      if [[ -f $FAKE/slow ]]; then
        read -r da dw < "$FAKE/slow"
        g=$RANDOM$RANDOM
        echo "$g" > "$st.gen"
        touch "$st.job"
        (
          sleep "$da"
          [[ $(cat "$st.gen" 2> /dev/null) == "$g" ]] || exit 0
          touch "$st.active"
          rm -f "$st.job"
          if [[ -f $FAKE/die ]]; then
            sleep 0.3
            rm -f "$st.active"
            exit 0
          fi
          [[ ! -f $FAKE/no-window ]] || exit 0
          sleep "$dw"
          [[ $(cat "$st.gen" 2> /dev/null) == "$g" ]] && touch "$FAKE/win/$app"
        ) > /dev/null 2>&1 &
        exit 0
      fi
      touch "$st.active"
      [[ -f $FAKE/no-window ]] || touch "$FAKE/win/$app"
      ;;
    stop)
      rm -f "$st.active" "$st.frozen" "$st.job" "$st.gen" "$FAKE/win/$(sed -n "s/^$u //p" "$FAKE/apps")"
      [[ ! -x $FAKE/on-stop ]] || "$FAKE/on-stop" "$u"
      ;;
    freeze) touch "$st.frozen" ;;
    is-active) [[ -f $st.active ]] && echo active || echo inactive ;;
    thaw) rm -f "$st.frozen" ;;
  esac
elif [[ $1 == start && -f $FAKE/start-rc ]]; then
  exit "$(cat "$FAKE/start-rc")"
fi
exit 0
EOF
cat > "$t/bin/wlrctl" << 'EOF'
#!/usr/bin/env bash
echo "wlrctl $*" >> "$FAKE/log"
app=${3#app_id:}
case $2 in
  waitfor | find | focus | minimize) [[ -f $FAKE/win/$app ]] ;;
esac
EOF
cat > "$t/bin/blockie-set" << 'EOF'
#!/usr/bin/env bash
echo "blockie-set $*" >> "$FAKE/log"
[[ $1 == get && -f $FAKE/default ]] && cat "$FAKE/default"
[[ $1 != get || -f $FAKE/default ]]
EOF
cat > "$t/bin/id" << 'EOF'
#!/usr/bin/env bash
if [[ $# == 1 ]]; then echo "${FAKE_UID:-0}"; else echo 0; fi
EOF
cat > "$t/bin/getent" << 'EOF'
#!/usr/bin/env bash
echo "root:x:0:0:root:/root:/bin/bash"
EOF
chmod +x "$t/bin/"*
for n in a b c d; do
  echo "blockie-test-$n.service test.$n" >> "$t/apps"
done

export FAKE=$t PATH=$t/bin:$PATH BLOCKIE_ROOT=$R BLOCKIE_RUNDIR=$t/run BLOCKIE_STATEDIR=$t/state \
  BLOCKIE_SESSION_USER=root BLOCKIE_UPTIME=$t/uptime BLOCKIE_SESSION_STEP=0.05 BLOCKIE_SESSION_START_WAIT=1 \
  BLOCKIE_SESSION_STOP_WAIT=1 BLOCKIE_SESSION_LOCK_WAIT=2 BLOCKIE_SESSION_POLL=0.05

bs() { "$bin" "$@"; }
go() {
  : > "$t/log"
  bs request "$1" > "$t/out" 2>&1 && bs switcher >> "$t/out" 2>&1
}
cur() { cut -d' ' -f1-2 "$t/run/session-current" 2> /dev/null; }
logged() { grep -qxF -- "$1" "$t/log"; }
up() { [[ -f $t/units/$1.active && ! -f $t/units/$1.frozen ]]; }
frozen() { [[ -f $t/units/$1.active && -f $t/units/$1.frozen ]]; }

out=$(bs list)
want=$(printf 'a\tAlpha\tyes\nb\tBravo2\tyes\nc\tCharlie\tno\nd\tDelta\tno')
[[ $out == "$want" ]]
res $? "list: valid sessions only, /etc overrides /usr/lib, quoted values unquoted"

go a
r=$?
[[ $r == 0 && $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service &&
  logged "systemctl --user start --no-block blockie-test-a.service" && logged "wlrctl toplevel focus app_id:test.a"
res $? "first switch starts a and focuses its window"
[[ ! -e $t/run/session-pending && $(cat "$t/state/last") == a ]]
res $? "pending cleared, last session stored"

go b
[[ $(cur) == "b blockie-test-b.service" ]] && up blockie-test-b.service && frozen blockie-test-a.service &&
  logged "wlrctl toplevel minimize app_id:test.a" && logged "systemctl --user freeze blockie-test-a.service"
res $? "switch to b: b up and focused, a minimized and frozen"
f=$(grep -nxF 'wlrctl toplevel focus app_id:test.b' "$t/log" | head -1 | cut -d: -f1)
m=$(grep -nxF 'wlrctl toplevel minimize app_id:test.a' "$t/log" | head -1 | cut -d: -f1)
[[ -n $f && -n $m ]] && (( f < m ))
res $? "the target is focused before the source is parked"

go a
[[ $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service && frozen blockie-test-b.service &&
  logged "systemctl --user thaw blockie-test-a.service" &&
  ! logged "systemctl --user start --no-block blockie-test-a.service"
res $? "back to a: thawed, not restarted; b frozen"

go a
[[ $(cur) == "a blockie-test-a.service" ]] && ! logged "systemctl --user freeze blockie-test-a.service" &&
  grep -q 'a is current' "$t/out"
res $? "switch to the current session only focuses it"

go c
go a
[[ ! -f $t/units/blockie-test-c.service.active ]] && logged "systemctl --user stop --no-block blockie-test-c.service"
res $? "BACKGROUND=stop stops c when it is left"

go d
go a
up blockie-test-d.service && logged "wlrctl toplevel minimize app_id:test.d" &&
  ! logged "systemctl --user freeze blockie-test-d.service"
res $? "BACKGROUND=run keeps d running, only minimized"

touch "$t/fail-start"
go c
r=$?
rm -f "$t/fail-start"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service &&
  logged "wlrctl toplevel focus app_id:test.a"
res $? "a target that does not start: rc $r, current stays a and a is focused again"

touch "$t/no-window"
go c
r=$?
rm -f "$t/no-window"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && grep -q 'no window of test.c' "$t/out"
res $? "a target without a window: rc $r, current stays a"
bs request c > /dev/null 2>&1
bs request bad1 > "$t/out" 2>&1
r=$?
[[ $r != 0 ]] && grep -q 'not a listed session' "$t/out" && [[ $(cut -d' ' -f1 "$t/run/session-wanted") == c ]]
res $? "request of an unlisted session refused, the earlier request stays"
rm -f "$t/run/session-pending" "$t/units/blockie-test-c.service.active"

: > "$t/log"
bs next > /dev/null 2>&1
[[ -e $t/run/session-pending && $(cut -d' ' -f1 "$t/run/session-wanted") == b ]] &&
  ! grep -q 'blockie-session-switcher' "$t/log"
res $? "next from a requests b as root (pending file for the path unit, no systemctl start)"

echo d > "$t/run/session-current"
rm -f "$t/run/session-pending"
bs next > /dev/null 2>&1
[[ $(cut -d' ' -f1 "$t/run/session-wanted") == a ]]
res $? "next wraps from the last listed session to the first"
printf 'a blockie-test-a.service 1\n' > "$t/run/session-current"

: > "$t/log"
FAKE_UID=1000 bs switch b > /dev/null 2>&1
logged "systemctl start --no-block blockie-session-switch@b.service"
res $? "switch as the session user starts blockie-session-switch@b.service"

[[ $(bs get-default 2> /dev/null) == a ]]
res $? "get-default without a stored value falls back to a listed default session"
echo b > "$t/default"
[[ $(bs get-default) == b ]]
res $? "get-default takes session.default from the settings daemon"
echo c > "$t/default"
[[ $(BLOCKIE_SESSION_FALLBACK=b bs get-default) == b ]]
res $? "a stored default that is not DEFAULT=yes falls back"
rm -f "$t/default"

: > "$t/log"
bs set-default b > /dev/null 2>&1
logged "blockie-set set session.default b"
res $? "set-default goes through blockie-set"

echo b > "$t/default"
: > "$t/log"
bs back > /dev/null 2>&1
[[ $(cut -d' ' -f1 "$t/run/session-wanted") == b ]]
res $? "back requests the default session"
printf 'b blockie-test-b.service 2\n' > "$t/run/session-current"
bs back > "$t/out" 2>&1
grep -q 'back: b is current' "$t/out"
res $? "back on the default session does nothing"
rm -f "$t/default"

out=$(bs menu a)
grep -qxF "$(printf 'a\tAlpha\tavailable\tno\tcurrent')" <<< "$out" &&
  grep -qxF "$(printf 'd\tDelta\tavailable\tyes\tother')" <<< "$out"
res $? "menu lists state, install and current"
[[ $(CHECK_RC=1 bs menu a | grep '^d' | cut -f3) == not-installed && $(CHECK_RC=2 bs menu a | grep '^d' | cut -f3) == refused ]]
res $? "menu maps CHECK exit 1 and 2 to not-installed and refused"

bs switch 'x;y' > /dev/null 2>&1
[[ $? == 2 ]]
res $? "a bad name is a usage error"

: > "$R/usr/lib/systemd/user/blockie-test-e.service"
echo "blockie-test-e.service test.e" >> "$t/apps"
session usr/lib/blockie/sessions.d e LABEL=Echo UNIT=blockie-test-e.service APP_ID=test.e SLICE=blockie-test-e.slice \
  'FOCUS=test.game test.other'
session usr/lib/blockie/sessions.d bad5 UNIT=blockie-test-e.service APP_ID=test.e SLICE=x.service
session usr/lib/blockie/sessions.d bad6 UNIT=blockie-test-e.service APP_ID=test.e 'FOCUS=ok bad/id'
session usr/lib/blockie/sessions.d bad7 UNIT=blockie-test-e.service APP_ID=test.e SLICE=session.slice
bs list | cut -f1 | grep -qx e && ! bs list | cut -f1 | grep -q 'bad5\|bad6\|bad7'
res $? "SLICE must be a blockie-*.slice (never session.slice) and every FOCUS id must be valid"
printf 'a blockie-test-a.service 3\n' > "$t/run/session-current"
go e
touch "$t/units/blockie-test-e.slice.active" "$t/win/test.game"
go a
logged "systemctl --user freeze blockie-test-e.slice" && ! logged "systemctl --user freeze blockie-test-e.service" &&
  logged "wlrctl toplevel minimize app_id:test.game" && logged "wlrctl toplevel minimize app_id:test.e"
res $? "leaving e freezes its active slice and minimizes its FOCUS and APP_ID windows"
touch "$t/units/blockie-test-e.slice.frozen"
go e
logged "systemctl --user thaw blockie-test-e.slice" && logged "wlrctl toplevel focus app_id:test.game" &&
  ! logged "wlrctl toplevel focus app_id:test.e"
res $? "back to e thaws the slice and focuses the first FOCUS id that has a window"

for n in f p; do
  : > "$R/usr/lib/systemd/user/blockie-test-$n.service"
  echo "blockie-test-$n.service test.$n" >> "$t/apps"
done
session usr/lib/blockie/sessions.d f LABEL=Foxtrot UNIT=blockie-test-f.service APP_ID=test.f START_WAIT=3
session usr/lib/blockie/sessions.d p LABEL=Papa UNIT=blockie-test-p.service APP_ID=test.p START_WAIT=2 PARK_FIRST=yes
session usr/lib/blockie/sessions.d bad11 UNIT=blockie-test-f.service APP_ID=test.f START_WAIT=601
session usr/lib/blockie/sessions.d bad12 UNIT=blockie-test-f.service APP_ID=test.f START_WAIT=0
session usr/lib/blockie/sessions.d bad13 UNIT=blockie-test-f.service APP_ID=test.f START_WAIT=1.5
session usr/lib/blockie/sessions.d bad14 UNIT=blockie-test-f.service APP_ID=test.f PARK_FIRST=maybe
bs list | cut -f1 | grep -qx f && bs list | cut -f1 | grep -qx p && ! bs list | cut -f1 | grep -q 'bad1[1-4]'
res $? "START_WAIT is 1 to 600 s, PARK_FIRST is yes or no"

fresh() { rm -f "${t:?}/units/blockie-test-$1.service".* "${t:?}/win/test.$1"; }
ms() { echo $(( $(date +%s%N) / 1000000 )); }

go a
fresh f
echo '0 1.5' > "$t/slow"
go f
r=$?
rm -f "$t/slow"
[[ $r == 0 && $(cur) == "f blockie-test-f.service" && ! -e $t/run/session-starting ]] && up blockie-test-f.service
res $? "a window 1.5 s after the start shows inside the session's START_WAIT of 3 s"

go a
fresh f
echo '1.5 2' > "$t/slow"
go f
r=$?
rm -f "$t/slow"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service && ! up blockie-test-f.service &&
  grep -q 'no window of test.f after 3 s' "$t/out" && logged "systemctl --user stop --no-block blockie-test-f.service"
res $? "the unit wait and the window share one deadline, which stops the target"

fresh f
echo '0.3 0' > "$t/slow"
touch "$t/die"
s0=$(ms)
go f
r=$?
s1=$(ms)
rm -f "$t/slow" "$t/die"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service &&
  grep -q 'blockie-test-f.service stopped while starting' "$t/out" && (( s1 - s0 < 2500 ))
res $? "the target unit ends during the start: the switch fails at once, $(( s1 - s0 )) ms"

fresh f
echo '0 2' > "$t/slow"
( sleep 0.5; bs request b > /dev/null 2>&1 ) &
go f
r=$?
wait $!
rm -f "$t/slow"
[[ $r == 0 && $(cur) == "a blockie-test-a.service" && -e $t/run/session-pending && $(cat "$t/run/session-wanted") == "b requested" ]] &&
  ! up blockie-test-f.service && up blockie-test-a.service && grep -q 'start of f cancelled, b wanted' "$t/out"
res $? "a request for another session during the start stops the target, stays pending, rc $r"
bs switcher > /dev/null 2>&1
[[ $(cur) == "b blockie-test-b.service" ]] && up blockie-test-b.service && frozen blockie-test-a.service
res $? "the next switcher run takes that request"

go a
fresh f
echo '0 1.5' > "$t/slow"
( sleep 0.5; bs request f > /dev/null 2>&1 ) &
go f
r=$?
wait $!
rm -f "$t/slow"
[[ $r == 0 && $(cur) == "f blockie-test-f.service" && ! -e $t/run/session-pending ]] &&
  grep -q 'f requested again, still starting' "$t/out" && ! logged "systemctl --user stop --no-block blockie-test-f.service"
res $? "a request for the target itself during the start is consumed"

go a
fresh p
go p
f=$(grep -nxF 'systemctl --user freeze blockie-test-a.service' "$t/log" | head -1 | cut -d: -f1)
s=$(grep -nxF 'systemctl --user start --no-block blockie-test-p.service' "$t/log" | head -1 | cut -d: -f1)
[[ $(cur) == "p blockie-test-p.service" && -n $f && -n $s ]] && (( f < s )) && frozen blockie-test-a.service &&
  up blockie-test-p.service
res $? "PARK_FIRST=yes freezes the source before the target starts"

go a
fresh p
touch "$t/no-window"
go p
r=$?
rm -f "$t/no-window"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && up blockie-test-a.service && ! up blockie-test-p.service &&
  logged "systemctl --user thaw blockie-test-a.service" && logged "wlrctl toplevel focus app_id:test.a"
res $? "PARK_FIRST: a target without a window is stopped, the frozen source thawed and focused"

go c
fresh p
touch "$t/no-window" "$t/units/graphical-session.target.active"
printf '#!/usr/bin/env bash\necho "ended $1" >> "$FAKE/log"\nexec %q ended "$1"\n' "$bin" > "$t/on-stop"
chmod +x "$t/on-stop"
go p
r=$?
rm -f "$t/no-window" "$t/units/graphical-session.target.active" "$t/on-stop"
o=$(grep -nxF 'systemctl --user stop --no-block blockie-test-c.service' "$t/log" | head -1 | cut -d: -f1)
s=$(grep -nxF 'systemctl --user start --no-block blockie-test-c.service' "$t/log" | head -1 | cut -d: -f1)
[[ $r != 0 && $(cur) == "c blockie-test-c.service" && -n $o && -n $s ]] && (( o < s )) && up blockie-test-c.service &&
  ! up blockie-test-p.service
res $? "PARK_FIRST: a stopped source is started again when the target fails"
logged "ended blockie-test-c.service" && ! grep -q 'revive@' "$t/log" && [[ ! -e $t/run/revive-hold ]]
res $? "PARK_FIRST: the stop of the source during the switch starts no revive, the hold is cleared after"

go a
fresh p
touch "$t/no-window"
: > "$t/log"
bs request p > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
sleep 1
kill -TERM "$pid"
wait "$pid"
r=$?
rm -f "$t/no-window"
[[ $r == 143 && $(cur) == "a blockie-test-a.service" && ! -e $t/run/session-starting ]] && up blockie-test-a.service &&
  ! up blockie-test-p.service && logged "systemctl --user stop --no-block blockie-test-p.service" &&
  logged "systemctl --user thaw blockie-test-a.service"
res $? "PARK_FIRST: TERM during the start stops the target and thaws the parked source, rc $r"

go c
fresh p
touch "$t/no-window"
: > "$t/log"
bs request p > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
sleep 1
s0=$(ms)
kill -TERM "$pid"
wait "$pid"
r=$?
s1=$(ms)
rm -f "$t/no-window"
[[ $r == 143 && $(cur) == "c blockie-test-c.service" && ! -e $t/run/revive-hold ]] && up blockie-test-c.service &&
  ! up blockie-test-p.service && logged "systemctl --user start --no-block blockie-test-c.service" && (( s1 - s0 < 900 ))
res $? "PARK_FIRST: TERM during the start starts a stopped source again without waiting for it, rc $r, $(( s1 - s0 )) ms"

go a
fresh f
go f
go a
rm -f "$t/win/test.f"
go f
r=$?
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && frozen blockie-test-f.service && up blockie-test-a.service &&
  logged "systemctl --user thaw blockie-test-f.service" && logged "systemctl --user freeze blockie-test-f.service" &&
  ! logged "systemctl --user stop --no-block blockie-test-f.service"
res $? "a target this switch did not start is parked again on failure, not stopped"

fresh f
rm -f "$t/run/session-current"
touch "$t/no-window"
go f
r=$?
rm -f "$t/no-window"
[[ $r == 0 && $(cur) == "f blockie-test-f.service" ]] && up blockie-test-f.service && grep -q 'f kept without a window' "$t/out" &&
  ! logged "systemctl --user stop --no-block blockie-test-f.service"
res $? "with no session to go back to, a target whose window is late stays and becomes current"
go a

rm -f "$t/units/blockie-test-a.service.active"
touch "$t/no-window"
go c
r=$?
rm -f "$t/no-window"
[[ $r != 0 && $(cur) == "a blockie-test-a.service" ]] && grep -q 'a is not running either' "$t/out" &&
  logged "systemctl start --no-block blockie-session-revive@a.service"
res $? "a failed switch whose source is not running either starts a revive of the source"
go a

rm -f "$t/units/blockie-test-d.service.active"
CHECK_RC=1 go d
r=$?
[[ $r != 0 && $(cur) == "a blockie-test-a.service" && ! -e $t/units/blockie-test-d.service.active ]] &&
  grep -q 'd is not-installed' "$t/out" && ! logged "systemctl --user start --no-block blockie-test-d.service" &&
  ! logged "wlrctl toplevel focus app_id:test.d"
res $? "switch refuses a session whose CHECK says not installed, d never starts"
printf 'c blockie-test-c.service 9\n' > "$t/run/session-current"
rm -f "$t/run/session-pending"
CHECK_RC=1 bs next > /dev/null 2>&1
[[ $(cut -d' ' -f1 "$t/run/session-wanted") == e ]]
res $? "next skips a session whose CHECK says not installed"
printf 'a blockie-test-a.service 10\n' > "$t/run/session-current"
rm -f "$t/run/session-pending"
echo b > "$t/run/session-starting"
bs next > /dev/null 2>&1
[[ $(cut -d' ' -f1 "$t/run/session-wanted") == c ]]
res $? "next during a start goes on from the session being started"
echo 'c requested' > "$t/run/session-wanted"
: > "$t/run/session-pending"
bs next > /dev/null 2>&1
[[ $(cut -d' ' -f1 "$t/run/session-wanted") == d ]]
res $? "next goes on from a pending request before the session being started"
echo b > "$t/default"
printf 'b blockie-test-b.service 11\n' > "$t/run/session-current"
rm -f "$t/run/session-pending"
echo c > "$t/run/session-starting"
bs back > /dev/null 2>&1
[[ -e $t/run/session-pending && $(cut -d' ' -f1 "$t/run/session-wanted") == b ]]
res $? "back during the start of another session requests the default"
rm -f "$t/run/session-pending"
echo b > "$t/run/session-starting"
bs back > "$t/out" 2>&1
[[ ! -e $t/run/session-pending ]] && grep -q 'back: b is starting' "$t/out"
res $? "back during the start of the default does nothing"
rm -f "$t/default" "$t/run/session-starting" "$t/run/session-pending"
printf 'a blockie-test-a.service 12\n' > "$t/run/session-current"

mkdir -p "$t/run/lock"
exec 8> "$t/run/lock/session.lock"
flock 8
bs request a > /dev/null 2>&1
BLOCKIE_SESSION_LOCK_WAIT=1 bs switcher > "$t/out" 2>&1
r=$?
exec 8>&-
[[ $r == 75 ]] && grep -q 'session lock busy' "$t/out"
res $? "a held session lock: switcher exits 75"

rm -f "$t/default"
export BLOCKIE_SESSION_REVIVE_WAIT=0
go a
touch "$t/units/graphical-session.target.active"
: > "$t/log"
bs ended blockie-test-a.service
logged "systemctl start --no-block blockie-session-revive@a.service"
res $? "ended: the current session's unit stopped, revive@ of that session is started"
: > "$t/log"
bs ended blockie-test-b.service
! grep -q 'revive@' "$t/log"
res $? "ended: another unit stopped, nothing"
rm -f "$t/units/graphical-session.target.active"
: > "$t/log"
bs ended blockie-test-a.service
! grep -q 'revive@' "$t/log"
res $? "ended: the graphical session is not active (logout, seat restart), nothing"

rv() {
  rm -f "$t/run/session-pending" "$t/run/session-wanted"
  printf '%s.00 %s.00\n' "$1" "$1" > "$t/uptime"
  bs revive "$2" > "$t/out" 2>&1
}
rm -f "$t/run/revived" "$t/units/blockie-test-a.service.active"
rv 10 a
r=$?
[[ $r == 0 && $(cat "$t/run/session-wanted") == "a revive" && -e $t/run/session-pending ]] && grep -q 'back to a' "$t/out"
res $? "revive: the default's unit ended, the default is requested again"
bs switcher > /dev/null 2>&1
up blockie-test-a.service && [[ $(cur) == "a blockie-test-a.service" ]]
res $? "revive: the switcher starts the default again"
rv 11 a
[[ ! -e $t/run/session-pending ]]
res $? "revive: the unit is active again (its own restart), nothing"
rv 12 b
[[ ! -e $t/run/session-pending ]] && grep -q 'not the current session' "$t/out"
res $? "revive: a session that is not current, nothing"
ok=0
for u in 13 14; do
  rm -f "$t/units/blockie-test-a.service.active"
  rv "$u" a || ok=1
done
rm -f "$t/units/blockie-test-a.service.active"
rv 15 a
r=$?
[[ $ok == 0 && $r == 1 && ! -e $t/run/session-pending ]] && grep -q 'brought back 3 times in 300 s, not again' "$t/out"
res $? "revive: a fourth time for the same default inside 300 s is refused"
rv 400 a
[[ -e $t/run/session-pending && $(wc -l < "$t/run/revived") == 1 ]]
res $? "revive: past the window it is allowed again and old entries are dropped"
go c
rm -f "$t/units/blockie-test-c.service.active"
rv 500 c
[[ $(cat "$t/run/session-wanted") == "a revive" ]] && grep -q 'blockie-test-c.service of c ended, back to a' "$t/out"
res $? "revive: another session's unit ended, the default is requested"
FAKE_UID=1000 bs revive a > /dev/null 2>&1
[[ $? == 2 ]]
res $? "revive runs as root only"
printf 'a blockie-test-a.service 20\n' > "$t/run/session-current"
rm -f "$t/units/blockie-test-a.service.active"
echo b > "$t/run/session-starting"
exec 8> "$t/run/lock/session.lock"
flock 8
rv 600 a
exec 8>&-
[[ ! -e $t/run/session-pending && -e $t/run/session-starting ]] && grep -q 'a switch is running' "$t/out"
res $? "revive: a switch holds the lock and is starting a session, nothing"
rv 601 a
[[ -e $t/run/session-pending && ! -e $t/run/session-starting && $(cat "$t/run/session-wanted") == "a revive" ]]
res $? "revive: a session-starting left without a switch holding the lock is removed, the revive goes on"
rm -f "$t/run/session-starting"
unset BLOCKIE_SESSION_REVIVE_WAIT

sf=${bin%/usr/bin/blockie-session}
run=/run/blockie-session
grep -qxF "rundir=\${BLOCKIE_RUNDIR:-$run}" "$bin" &&
  grep -qxF "d $run 0755 root root -" "$sf/usr/lib/tmpfiles.d/blockie.conf" &&
  grep -qxF "PathExists=$run/session-pending" "$sf/usr/lib/systemd/system/blockie-session-switcher.path" &&
  grep -q "^ReadWritePaths=$run\( \|$\)" "$sf/usr/lib/systemd/system/blockie-session-switcher.service" &&
  grep -q "^ReadWritePaths=$run\( \|$\)" "$sf/usr/lib/systemd/system/blockie-session-switch@.service" &&
  grep -qF "\"$run/session-current\"" "$sf/usr/libexec/blockie/blockie-hotkeyd" &&
  ! grep -qs "/run/blockie/" "$bin" "$sf/usr/lib/systemd/system"/blockie-session-* "$sf/usr/libexec/blockie/blockie-hotkeyd"
res $? "the runtime dir is $run everywhere, nothing in the init's /run/blockie"

sw=$sf/usr/lib/systemd/system/blockie-session-switcher.service
grep -qxF 'TimeoutStartSec=1320' "$sw" && grep -qxF 'TimeoutStopSec=90' "$sw"
res $? "the switcher's start limit covers lock, park, START_WAIT 600, undo and a source restart of 600 s plus 60 s"
sed -n '/^\[Unit\]/,/^\[/p' "$sw" | grep -qxF 'StartLimitIntervalSec=0'
res $? "the switcher has no start rate limit, so a burst of requests never stops the path unit"

grep -qxF 'ExecStopPost=-+/usr/bin/setpriv --reuid=blockie --regid=blockie --init-groups /usr/bin/env XDG_RUNTIME_DIR=/run/user/1000 /usr/bin/systemctl --user stop blockie-compositor.service' \
  "$sf/usr/lib/systemd/system/blockie-seat.service" && grep -q '^u blockie 1000:1000 ' "$sf/usr/lib/sysusers.d/blockie.conf"
res $? "seat stop stops the compositor on the user bus of uid 1000, the uid sysusers gives blockie, without a PAM session"

grep -qxF 'ExecStopPost=-/usr/bin/blockie-session ended %n' "$sf/usr/lib/systemd/user/blockie-.service.d/60-blockie-session.conf" &&
  grep -qxF 'ExecStart=/usr/bin/blockie-session revive %i' "$sf/usr/lib/systemd/system/blockie-session-revive@.service" &&
  grep -qxF "ReadWritePaths=$run" "$sf/usr/lib/systemd/system/blockie-session-revive@.service" &&
  grep -qF 'blockie-session-(switch|appswitch|revive)@' "$sf/usr/share/polkit-1/rules.d/50-blockie-session.rules"
res $? "every blockie user unit reports its stop, revive@ runs as root, polkit lets blockie start it"

as=$sf/usr/lib/systemd/system/blockie-session-appswitch@.service
grep -qxF 'ExecStart=/usr/bin/blockie-session request %i app' "$as" && grep -qxF "ReadWritePaths=$run" "$as" &&
  grep -qxF 'CapabilityBoundingSet=' "$as" && grep -qxF 'PrivateDevices=yes' "$as" &&
  grep -qxF "d $run/lock 0700 root root -" "$sf/usr/lib/tmpfiles.d/blockie.conf" &&
  grep -qxF "f $run/lock/request.lock 0600 root root -" "$sf/usr/lib/tmpfiles.d/blockie.conf"
res $? "appswitch@ requests with reason app in the switch@ sandbox; tmpfiles makes the lock dir and the request lock"

fo=$sf/usr/libexec/blockie/blockie-funeos
mkdir -p "$t/fdev" "$t/fbin"
for d in fdev fbin; do
  for x in funeos funeos-ctl; do
    printf '#!/bin/sh\necho "%s %s $*"\n' "$d" "$x" > "$t/$d/$x"
    chmod +x "$t/$d/$x"
  done
done
fe() { BLOCKIE_FUNEOS_DEV=$1 BLOCKIE_FUNEOS_BIN=$2 BLOCKIE_DATA_DIR=$3 "$fo" "${@:4}" 2> /dev/null; }
fe "$t/none" "$t/none" /proc check > /dev/null
r1=$?
o2=$(fe "$t/none" "$t/fbin" /proc funeos-ctl leave b requested)
o3=$(fe "$t/fdev" "$t/fbin" /proc funeos-ctl leave b requested)
fe "$t/fdev" "$t/fbin" /proc check > /dev/null
r4=$?
fe "$t/fdev" "$t/fbin" "$t" check > /dev/null
r5=$?
fe "$t/fdev" "$t/fbin" /proc nope
r6=$?
rm -f "${t:?}/fdev/funeos-ctl"
fe "$t/fdev" "$t/fbin" /proc funeos-ctl leave > /dev/null
r7=$?
[[ $r1 == 1 && $o2 == "fbin funeos-ctl leave b requested" && $o3 == "fdev funeos-ctl leave b requested" && $r4 == 0 &&
  $r5 == 1 && $r6 == 2 && $r7 == 127 ]] &&
  grep -qxF 'exec /usr/libexec/blockie/blockie-funeos check' "$sf/usr/libexec/blockie/blockie-funeos-check"
res $? "blockie-funeos: the dev dir wins for both tools, check needs funeos and a mounted data dir, a bad verb exits 2"
BLOCKIE_ROOT=$sf bs list | grep -qxF "$(printf 'funeos\tfuneOS\tno')"
res $? "the shipped funeos.conf is listed"

for n in g h k; do
  : > "$R/usr/lib/systemd/user/blockie-test-$n.service"
  echo "blockie-test-$n.service test.$n" >> "$t/apps"
done
session usr/lib/blockie/sessions.d g LABEL=Golf UNIT=blockie-test-g.service APP_ID=test.g BACKGROUND=run \
  'LEAVE=/usr/libexec/leave-g arg' SWITCHED=/usr/libexec/sw-g
session usr/lib/blockie/sessions.d h LABEL=Hotel UNIT=blockie-test-h.service APP_ID=test.h LEAVE=/usr/libexec/leave-h
session usr/lib/blockie/sessions.d k LABEL=Kilo UNIT=blockie-test-k.service APP_ID=test.k CHECK=/usr/libexec/check-k
session usr/lib/blockie/sessions.d lf UNIT=blockie-test-h.service APP_ID=test.h BACKGROUND=freeze LEAVE=/usr/libexec/leave-h
session usr/lib/blockie/sessions.d bad15 UNIT=blockie-test-g.service APP_ID=test.g LEAVE=/tmp/x
session usr/lib/blockie/sessions.d bad16 UNIT=blockie-test-g.service APP_ID=test.g LEAVE=/usr/../tmp/x
session usr/lib/blockie/sessions.d bad17 UNIT=blockie-test-g.service APP_ID=test.g 'LEAVE=/usr/libexec/leave-g $(x)'
session usr/lib/blockie/sessions.d bad18 UNIT=blockie-test-g.service APP_ID=test.g 'LEAVE=/usr/libexec/leave-g;x'
session usr/lib/blockie/sessions.d bad19 UNIT=blockie-test-g.service APP_ID=test.g BACKGROUND=freeze SWITCHED=/usr/libexec/sw-g
session usr/lib/blockie/sessions.d bad20 UNIT=blockie-test-g.service APP_ID=test.g SWITCHED=/usr/libexec/sw-g
for h in leave-g:1 leave-h:1 sw-g:0; do
  n=${h%:*}
  cat > "$R/usr/libexec/$n" << EOF
#!/bin/sh
echo "$n \$*" >> "\$FAKE/log"
[ ! -f "\$FAKE/$n.sleep" ] || sleep "\$(cat "\$FAKE/$n.sleep")"
[ ! -f "\$FAKE/$n.bg" ] || { sleep 30 > /dev/null 2>&1 & echo \$! > "\$FAKE/$n.pid"; }
exit "\$(cat "\$FAKE/$n.rc" 2> /dev/null || echo ${h#*:})"
EOF
  chmod +x "$R/usr/libexec/$n"
done
printf '#!/bin/sh\nsleep 30 > /dev/null 2>&1 &\necho $! > "$FAKE/check-k.pid"\nexit 0\n' > "$R/usr/libexec/check-k"
chmod +x "$R/usr/libexec/check-k"

gapp() {
  : > "$t/log"
  bs request "$1" app > "$t/out" 2>&1 && bs switcher >> "$t/out" 2>&1
}
nsw() { grep -c '^sw-g ' "$t/log"; }
line() { grep -nxF -- "$1" "$t/log" | head -1 | cut -d: -f1; }
until_log() {
  local i
  for ((i = 0; i < 200; i++)); do
    grep -q -- "$1" "$t/log" && return 0
    sleep 0.05
  done
  return 1
}

rm -f "${t:?}/run/session-pending" "${t:?}/run/session-starting"
go a
go g
l=$(bs list | cut -f1)
grep -qx g <<< "$l" && grep -qx h <<< "$l" && grep -qx lf <<< "$l" && ! grep -q '^bad1[5-9]$\|^bad20$' <<< "$l" &&
  [[ $(cur) == "g blockie-test-g.service" ]]
res $? "LEAVE and SWITCHED: /tmp, .., \$(x) or ; unlist; SWITCHED needs BACKGROUND=run (no BACKGROUND line is freeze), LEAVE does not"

echo 0 > "$t/leave-g.rc"
go b
r=$?
rm -f "${t:?}/leave-g.rc"
[[ $r == 0 && $(cur) == "g blockie-test-g.service" && ! -e $t/run/session-starting && ! -e $t/run/session-pending ]] &&
  logged "leave-g arg b requested" && grep -q 'leave taken by g' "$t/out" && ! grep -q 'test-b' "$t/log"
res $? "LEAVE gets <target> <reason>; its exit 0 drops the switch, nothing started, g stays current, rc $r"

go b
[[ $(cur) == "b blockie-test-b.service" ]] && logged "leave-g arg b requested" && grep -q 'leave of g exited 1, switching' "$t/out" &&
  ! grep -q '^sw-g' "$t/log"
res $? "a LEAVE that exits 1 lets the switch go ahead, no SWITCHED"
go g
echo 5 > "$t/leave-g.sleep"
s0=$(ms)
go b
s1=$(ms)
rm -f "${t:?}/leave-g.sleep"
[[ $(cur) == "b blockie-test-b.service" ]] && grep -q 'leave of g exited 124, switching' "$t/out" && (( s1 - s0 < 3500 ))
res $? "a LEAVE that hangs is cut at 2 s and the switch goes ahead, $(( s1 - s0 )) ms"

go g
gapp b
r=$?
[[ $r == 0 && $(cur) == "b blockie-test-b.service" ]] && ! grep -q '^leave-' "$t/log" && logged "sw-g b ok" && [[ $(nsw) == 1 ]]
res $? "an app request runs no LEAVE; the SWITCHED of the session in front gets <target> ok, once"
go g
go g
grep -q 'g is current' "$t/out" && ! grep -q '^leave-' "$t/log"
res $? "no LEAVE for a switch to the current session"
CHECK_RC=1 go d
[[ $(cur) == "g blockie-test-g.service" ]] && grep -q 'd is not-installed' "$t/out" && ! grep -q '^leave-' "$t/log"
res $? "no LEAVE when the target's CHECK refuses it"
go a
go b
! grep -q '^leave-' "$t/log"
res $? "no LEAVE from a session without one"

go g
fresh p
go p
lv=$(line "leave-g arg p requested")
mn=$(line "wlrctl toplevel minimize app_id:test.g")
[[ $(cur) == "p blockie-test-p.service" && -n $lv && -n $mn ]] && (( lv < mn ))
res $? "LEAVE runs before the PARK_FIRST park of the session in front"
go g
: > "$t/log"
bs request b revive > /dev/null 2>&1 && bs switcher > "$t/out" 2>&1
logged "leave-g arg b revive"
res $? "LEAVE gets the reason revive too"

go g
echo 1.5 > "$t/leave-g.sleep"
: > "$t/log"
bs request b > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
until_log '^leave-g arg b requested$'
kill -TERM "$pid"
wait "$pid"
r=$?
rm -f "${t:?}/leave-g.sleep"
[[ $r == 143 && $(cur) == "g blockie-test-g.service" && ! -e $t/run/session-starting ]] && ! grep -q 'test-b' "$t/log" &&
  ! grep -q '^sw-g' "$t/log"
res $? "TERM during LEAVE: rc $r, nothing started, no SWITCHED"

touch "$t/leave-g.bg"
go b
rm -f "${t:?}/leave-g.bg"
BLOCKIE_SESSION_LOCK_WAIT=1 go g
r=$?
kill "$(cat "$t/leave-g.pid" 2> /dev/null)" 2> /dev/null
[[ $r == 0 && $(cur) == "g blockie-test-g.service" ]]
res $? "a process a LEAVE leaves behind does not hold the session lock for the next run, rc $r"
go k
BLOCKIE_SESSION_LOCK_WAIT=1 go g
r=$?
kill "$(cat "$t/check-k.pid" 2> /dev/null)" 2> /dev/null
[[ $r == 0 && $(cur) == "g blockie-test-g.service" ]]
res $? "a process a CHECK leaves behind does not hold the session lock for the next run, rc $r"

: > "$t/log"
FAKE_UID=1000 bs switch b app > /dev/null 2>&1
logged "systemctl start --no-block blockie-session-appswitch@b.service"
res $? "switch <name> app as the session user starts blockie-session-appswitch@<name>.service"
bs switch b foo > /dev/null 2>&1
r1=$?
: > "$t/log"
FAKE_UID=1000 bs switch bad1 app > /dev/null 2>&1
r2=$?
[[ $r1 == 2 && $r2 == 1 ]] && ! grep -q 'appswitch@' "$t/log"
res $? "switch <name> foo is a usage error; an unlisted name with app exits 1 before any unit start"
bs switch b app > /dev/null 2>&1
[[ $(cat "$t/run/session-wanted") == "b app g" && -e $t/run/session-pending ]]
res $? "switch <name> app as root requests with reason app and the session in front as from"
rm -f "${t:?}/run/session-pending"

fresh c
touch "$t/fail-start"
gapp c
r=$?
rm -f "${t:?}/fail-start"
[[ $r != 0 && $(cur) == "g blockie-test-g.service" ]] && logged "sw-g c failed" && [[ $(nsw) == 1 ]]
res $? "SWITCHED gets failed when the target does not start"
fresh c
touch "$t/no-window"
gapp c
r=$?
rm -f "${t:?}/no-window"
[[ $r != 0 && $(cur) == "g blockie-test-g.service" ]] && logged "sw-g c failed"
res $? "SWITCHED gets failed when the target shows no window"

fresh f
echo '0 2' > "$t/slow"
( sleep 0.5; bs request b > /dev/null 2>&1 ) &
gapp f
r=$?
wait $!
rm -f "${t:?}/slow"
[[ $r == 0 && $(cur) == "g blockie-test-g.service" ]] && logged "sw-g f cancelled" && [[ $(nsw) == 1 ]]
res $? "SWITCHED gets cancelled when a request for another session stops the start"
bs switcher > /dev/null 2>&1
go g
fresh f
echo '0 2' > "$t/slow"
echo 1.5 > "$t/sw-g.sleep"
: > "$t/log"
bs request f app > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
( sleep 0.5; bs request b > /dev/null 2>&1 ) &
bg=$!
until_log '^sw-g f cancelled$'
kill -TERM "$pid"
wait "$pid"
r=$?
wait "$bg"
rm -f "${t:?}/slow" "${t:?}/sw-g.sleep" "${t:?}/run/session-pending"
[[ $r == 143 && $(nsw) == 1 && $(cur) == "g blockie-test-g.service" ]]
res $? "TERM during the SWITCHED hook of a cancelled switch: rc $r, one line"
gapp g
grep -q 'g is current' "$t/out" && logged "sw-g g ok"
res $? "SWITCHED gets ok for a switch to the session already in front"

fresh c
printf 'g blockie-test-x.service 40\n' > "$t/run/session-current"
touch "$t/no-window"
gapp c
r=$?
rm -f "${t:?}/no-window"
[[ $r == 0 && $(cur) == "c blockie-test-c.service" ]] && grep -q 'c kept without a window' "$t/out" && logged "sw-g c ok"
res $? "SWITCHED gets ok when the target is kept without a window"
go g

fresh p
touch "$t/no-window"
: > "$t/log"
bs request p app > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
sleep 1
kill -TERM "$pid"
wait "$pid"
r=$?
rm -f "${t:?}/no-window"
[[ $r == 143 && $(cur) == "g blockie-test-g.service" ]] && logged "sw-g p failed" && [[ $(nsw) == 1 ]]
res $? "TERM during the start: SWITCHED gets failed once, rc $r"

echo 1.5 > "$t/sw-g.sleep"
: > "$t/log"
bs request b app > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
until_log '^sw-g b ok$'
kill -TERM "$pid"
wait "$pid"
r=$?
rm -f "${t:?}/sw-g.sleep"
[[ $r == 143 && $(nsw) == 1 && $(cur) == "b blockie-test-b.service" ]]
res $? "TERM during the SWITCHED hook: rc $r, still one line"
go g
echo 5 > "$t/sw-g.sleep"
s0=$(ms)
gapp b
r=$?
s1=$(ms)
rm -f "${t:?}/sw-g.sleep"
[[ $r == 0 && $(cur) == "b blockie-test-b.service" ]] && grep -q 'switched hook of g exited 124' "$t/out" && (( s1 - s0 < 4500 ))
res $? "a SWITCHED hook that hangs is cut and leaves rc 0, $(( s1 - s0 )) ms"
go g

: > "$t/log"
bs request b app > /dev/null 2>&1 && bs request b > /dev/null 2>&1
w1=$(cat "$t/run/session-wanted")
bs switcher > "$t/out" 2>&1
[[ $w1 == "b app g" && ! -e $t/run/session-dropped ]] && ! grep -q '^leave-' "$t/log" && logged "sw-g b ok" && [[ $(nsw) == 1 ]]
res $? "a request over a pending app request for the same target keeps one app line: no LEAVE, no drop, one ok"
go g
bs request b > /dev/null 2>&1 && bs request b app > /dev/null 2>&1
w1=$(cat "$t/run/session-wanted")
rm -f "${t:?}/run/session-pending"
bs request b > /dev/null 2>&1 && bs request b revive > /dev/null 2>&1
w2=$(cat "$t/run/session-wanted")
rm -f "${t:?}/run/session-pending"
[[ $w1 == "b app g" && $w2 == "b revive" ]]
res $? "an app request merges into a pending request for the same target; two other reasons keep the newer"

fresh c
bs request b app > /dev/null 2>&1 && bs request c > /dev/null 2>&1
d1=$(cat "$t/run/session-dropped" 2> /dev/null)
: > "$t/log"
bs switcher > "$t/out" 2>&1
dl=$(line "sw-g b dropped")
lv=$(line "leave-g arg c requested")
[[ $d1 == "b g" && $(cur) == "c blockie-test-c.service" && ! -e $t/run/session-dropped && -n $dl && -n $lv ]] && (( dl < lv ))
res $? "a request for another target over a pending app request drops it, dropped is sent before the new switch"
go g

printf '%s\n' 'Bad line' 'b g' 'b' > "$t/run/session-dropped"
rm -f "${t:?}/run/session-pending"
: > "$t/log"
bs switcher > "$t/out" 2>&1
r=$?
[[ $r == 0 && $(cur) == "g blockie-test-g.service" && ! -e $t/run/session-dropped ]] && logged "sw-g b dropped" &&
  [[ $(nsw) == 1 && $(grep -c 'malformed line skipped' "$t/out") == 2 ]] && ! grep -q 'systemctl --user start' "$t/log"
res $? "drops are delivered with no pending request; malformed lines are skipped with a log"
printf '%s g\n' a b c d e f h k p > "$t/run/session-dropped"
: > "$t/log"
bs switcher > "$t/out" 2>&1
[[ $(nsw) == 8 ]] && grep -q 'over 8 drops' "$t/out" && ! logged "sw-g p dropped"
res $? "nine distinct drops in one run send 8 and log the cap"

fresh f
echo '0 1.5' > "$t/slow"
( sleep 0.5; bs request f app > /dev/null 2>&1 ) &
go f
wait $!
rm -f "${t:?}/slow"
[[ $(cur) == "f blockie-test-f.service" ]] && grep -q 'f requested again, still starting' "$t/out" && logged "sw-g f ok" &&
  [[ $(nsw) == 1 ]]
res $? "an app request consumed by a requested switch in flight gets that switch's result"
go g
fresh f
echo '0 1.5' > "$t/slow"
( sleep 0.5; bs request f app > /dev/null 2>&1 ) &
gapp f
wait $!
rm -f "${t:?}/slow"
[[ $(cur) == "f blockie-test-f.service" ]] && logged "sw-g f ok" && [[ $(nsw) == 1 ]]
res $? "the same session as from and as joined gets one line"
go g

bs request b app > /dev/null 2>&1
exec 8> "$t/run/lock/session.lock"
flock 8
: > "$t/log"
BLOCKIE_SESSION_LOCK_WAIT=1 bs switcher > "$t/out" 2>&1
r=$?
exec 8>&-
[[ $r == 75 && -e $t/run/session-pending ]] && ! grep -q '^sw-g' "$t/log"
res $? "a held session lock: exit 75, no SWITCHED, the request stays pending"
rm -f "${t:?}/run/session-pending"

fresh f
echo '0 2.5' > "$t/slow"
bs request f > /dev/null 2>&1
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
for ((i = 0; i < 200; i++)); do
  [[ -e $t/run/session-starting ]] && break
  sleep 0.05
done
exec 6>> "$t/run/lock/request.lock"
flock 6
echo 'b requested' > "$t/run/session-wanted"
: > "$t/run/session-pending"
sleep 1
grep -q cancelled "$t/out"
c1=$?
flock -u 6
exec 6>&-
wait "$pid"
r=$?
rm -f "${t:?}/slow" "${t:?}/run/session-pending"
[[ $r == 0 && $c1 != 0 && $(cur) == "g blockie-test-g.service" ]] && grep -q 'start of f cancelled, b wanted' "$t/out"
res $? "a held request lock skips the pending check without exit 75, the cancel comes after the release"
exec 6>> "$t/run/lock/request.lock"
flock 6
s0=$(ms)
bs request b > "$t/out" 2>&1
r=$?
s1=$(ms)
flock -u 6
exec 6>&-
[[ $r == 75 && ! -e $t/run/session-pending ]] && grep -q 'request lock busy' "$t/out" && (( s1 - s0 >= 4500 ))
res $? "request exits 75 when the request lock stays held past 5 s"

bs request b app > /dev/null 2>&1
exec 6>> "$t/run/lock/request.lock"
flock 6
: > "$t/log"
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
sleep 0.5
kill -TERM "$pid"
sleep 0.2
flock -u 6
exec 6>&-
wait "$pid"
r=$?
[[ $r == 143 && -e $t/run/session-pending && $(cat "$t/run/session-wanted") == "b app g" ]] && ! grep -q '^sw-g' "$t/log" &&
  ! grep -qi 'unbound\|syntax\|not found' "$t/out"
res $? "TERM between the session lock and the read: rc $r, the request stays pending, no shell error"
rm -f "${t:?}/run/session-pending"
printf '%s\n' 'a g' 'c g' > "$t/run/session-dropped"
bs request b app > /dev/null 2>&1
echo 1 > "$t/sw-g.sleep"
: > "$t/log"
"$bin" switcher > "$t/out" 2>&1 &
pid=$!
until_log '^sw-g a dropped$'
kill -TERM "$pid"
wait "$pid"
r=$?
rm -f "${t:?}/sw-g.sleep"
[[ $r == 143 && $(nsw) == 3 && $(cur) == "g blockie-test-g.service" ]] && logged "sw-g b failed" && logged "sw-g c dropped" &&
  ! grep -q 'test-b' "$t/log"
res $? "TERM during the first drop: the rest are delivered and the consumed app request gets failed, rc $r"
rm -f "${t:?}/run/session-pending" "${t:?}/run/session-dropped"
bs switcher > "$t/out" 2>&1
r=$?
[[ $r == 0 && ! -s $t/out ]]
res $? "a run with no pending request exits 0 with nothing logged"

rm -f "${t:?}/run/ready"
echo a > "$t/default"
I=0123456789abcdef0123456789abcdef
J=fedcba9876543210fedcba9876543210
touch "$t/units/blockie-test-a.service.active" "$t/win/test.a"
echo "$I" > "$t/units/blockie-test-a.service.inv"
bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 0 && $(cat "$t/run/ready") == "a blockie-test-a.service $I" && $(stat -c %a "$t/run/ready") == 644 ]]
res $? "mark-ready as root with the unit's own invocation: ready names the default session, its unit and the invocation id (0644)"
rm -f "${t:?}/run/ready"
echo "$J" > "$t/units/blockie-test-a.service.inv"
bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 1 && ! -e $t/run/ready ]] && grep -q "blockie-test-a.service runs invocation $J, not the reporting $I, not marked" "$t/out"
r1=$?
rm -f "${t:?}/units/blockie-test-a.service.inv"
bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 1 && ! -e $t/run/ready ]] && grep -q "runs invocation none, not the reporting $I" "$t/out"
res $((r1 || $?)) "mark-ready from a stale sender (the unit restarted on another invocation, or has none): exit 1, nothing marked"
r1=0
for w in "" x "${I:1}" "${I}0" "${I^^}" "$I $I"; do
  read -ra args <<< "$w"
  bs mark-ready "${args[@]}" > "$t/out" 2>&1
  r=$?
  [[ $r == 2 && ! -e $t/run/ready ]] || { r1=1; echo "  mark-ready '$w': rc $r"; }
done
res $r1 "mark-ready refuses an argument that is not one 32 hex invocation id: exit 2, nothing marked"
echo "$I" > "$t/units/blockie-test-a.service.inv"
rm -f "${t:?}/win/test.a"
bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 1 && ! -e $t/run/ready ]] && grep -q 'shows no window of test.a' "$t/out"
res $? "mark-ready with no window of the default session within its start wait: exit 1, nothing marked"
touch "$t/win/test.a"
echo b > "$t/default"
rm -f "$t/units/blockie-test-b.service.active" "$t/win/test.b"
bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 1 && ! -e $t/run/ready ]]
res $? "mark-ready counts only the default session: a's window while b is the default marks nothing"
echo a > "$t/default"
: > "$t/log"
INVOCATION_ID=$I FAKE_UID=1000 bs ready > "$t/out" 2>&1
r=$?
[[ $r == 0 && ! -e $t/run/ready && $(cat "$t/log") == "systemctl start blockie-session-ready@$I.service" ]]
r1=$?
echo 1 > "$t/start-rc"
INVOCATION_ID=$I FAKE_UID=1000 bs ready > "$t/out" 2>&1
r=$?
rm -f "${t:?}/start-rc"
[[ $r == 1 ]]
r1=$((r1 || $?))
FAKE_UID=1000 bs mark-ready "$I" > "$t/out" 2>&1
r=$?
[[ $r == 2 && ! -e $t/run/ready ]]
res $((r1 || $?)) "ready as the session user waits for blockie-session-ready@<its INVOCATION_ID>.service and exits with its result; mark-ready refuses a non root caller"
r1=0
for w in "" x "${I^^}" "$I$I"; do
  : > "$t/log"
  INVOCATION_ID=$w FAKE_UID=1000 bs ready > "$t/out" 2>&1
  r=$?
  [[ $r == 2 && ! -s $t/log && ! -e $t/run/ready ]] && grep -q 'INVOCATION_ID names no unit invocation' "$t/out" ||
    { r1=1; echo "  ready with INVOCATION_ID '$w': rc $r"; }
done
res $r1 "ready outside a unit, or with an INVOCATION_ID that is not 32 hex: exit 2, no unit started"
INVOCATION_ID=$I bs ready > "$t/out" 2>&1
r=$?
[[ $r == 0 && $(cat "$t/run/ready") == "a blockie-test-a.service $I" ]]
r1=$?
rm -f "${t:?}/run/ready"
INVOCATION_ID=$J bs ready > "$t/out" 2>&1
r=$?
[[ $r == 1 && ! -e $t/run/ready ]]
res $((r1 || $?)) "ready as root marks at once, only for the unit's own invocation"
rm -f "${t:?}/run/ready" "${t:?}/default" "${t:?}/units/blockie-test-a.service.inv"
ru=$sf/usr/lib/systemd/system/blockie-session-ready@.service
grep -qxF 'ExecStart=/usr/bin/blockie-session mark-ready %i' "$ru" && grep -qxF 'ReadWritePaths=/run/blockie-session' "$ru" &&
  grep -qxF 'CapabilityBoundingSet=CAP_SETUID CAP_SETGID' "$ru" && grep -qxF 'NoNewPrivileges=yes' "$ru" &&
  ! grep -q '^\[Install\]' "$ru" && [[ ! -e $sf/usr/lib/systemd/system/blockie-session-ready.service ]]
res $? "blockie-session-ready@.service runs mark-ready %i in the switcher's sandbox, with no [Install], and no plain ready unit is left"
sed -n '/^\[Unit\]/,/^\[/p' "$ru" | grep -qxF 'StartLimitIntervalSec=0'
res $? "blockie-session-ready@.service has no start rate limit, so the frontend's retries always start it"
done_
