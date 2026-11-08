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
        Job) [[ ! -f $st.job ]] || echo 1 ;;
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
  grep -qF 'blockie-session-(switch|revive)@' "$sf/usr/share/polkit-1/rules.d/50-blockie-session.rules"
res $? "every blockie user unit reports its stop, revive@ runs as root, polkit lets blockie start it"

if (( fails )); then
  echo "session: $fails failed"
  exit 1
fi
echo "session: ok"
