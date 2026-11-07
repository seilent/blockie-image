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
      esac
      ;;
    start)
      [[ ! -f $FAKE/fail-start ]] || exit 1
      touch "$st.active"
      app=$(sed -n "s/^$u //p" "$FAKE/apps")
      [[ -f $FAKE/no-window ]] || touch "$FAKE/win/$app"
      ;;
    stop) rm -f "$st.active" "$st.frozen" "$FAKE/win/$(sed -n "s/^$u //p" "$FAKE/apps")" ;;
    freeze) touch "$st.frozen" ;;
    thaw) rm -f "$st.frozen" ;;
  esac
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
  BLOCKIE_SESSION_STOP_WAIT=1 BLOCKIE_SESSION_LOCK_WAIT=2

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

mkdir -p "$t/run/lock"
exec 8> "$t/run/lock/session.lock"
flock 8
bs request a > /dev/null 2>&1
BLOCKIE_SESSION_LOCK_WAIT=1 bs switcher > "$t/out" 2>&1
r=$?
exec 8>&-
[[ $r == 75 ]] && grep -q 'session lock busy' "$t/out"
res $? "a held session lock: switcher exits 75"

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

if (( fails )); then
  echo "session: $fails failed"
  exit 1
fi
echo "session: ok"
