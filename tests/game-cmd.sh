#!/usr/bin/env bash
set -u

gcmd=/usr/libexec/blockie/blockie-game-cmd
hooks=/usr/lib/blockie/hooks.d
t=$(mktemp -d "${TMPDIR:-/tmp}/game-cmd.XXXXXX")
fails=0
made=
trap 'exec 4>&- 5>&-; rm -rf "${t:?}"; [[ -z $made ]] || rm -rf "${made:?}"' EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

mkdir -p "$t/run" "$t/bin"
p=$t/run/blockie-game.cmd
stamp=$t/run/blockie-game.quit
cat > "$t/bin/systemctl" << EOF
#!/bin/sh
echo "\$*" >> "$t/systemctl.log"
EOF
chmod 755 "$t/bin/systemctl"

send() {
  XDG_RUNTIME_DIR=$t/run PATH=$t/bin:$PATH timeout 2 "$@" > "$t/out" 2> "$t/err"
  rc=$?
}
quiet() { [[ $rc == 0 && ! -s $t/out && ! -s $t/err ]]; }
oneline() { [[ $rc == 0 && ! -s $t/out && $(wc -l < "$t/err") == 1 ]]; }
got() {
  line=
  read -r -t "${2:-2}" line <&4
  [[ $line == "$1" ]]
}
uptime_s() {
  local up _
  read -r up _ < /proc/uptime
  echo "${up%.*}"
}

ok=0
[[ -x $gcmd && $(head -n 1 "$gcmd") == '#!/usr/bin/python3 -IS' ]] || { ok=1; echo "  $gcmd"; }
for h in game-menu:MENU_TOGGLE game-quit:QUIT; do
  f=$hooks/${h%%:*}
  [[ -x $f && $(head -n 1 "$f") == '#!/bin/sh' && $(tail -n 1 "$f") == "exec $gcmd ${h#*:}" ]] && sh -n "$f" ||
    { ok=1; echo "  $f"; }
done
[[ $(< "$hooks/game-menu") == $'#!/bin/sh\nexec '"$gcmd MENU_TOGGLE" ]] || { ok=1; echo "  game-menu has more than its exec line"; }
res $ok "the helper and both hooks are executable, each hook ends in exec of the helper with its command"

send "$gcmd" QUIT
quiet
res $? "no FIFO: exit 0 at once, nothing logged"

mkfifo -m 600 "$p"
send "$gcmd" QUIT
quiet
res $? "a FIFO with no reader: exit 0 at once, nothing logged"

exec 4<> "$p"
send "$gcmd" QUIT
quiet && got QUIT
r1=$?
send "$hooks/game-menu"
quiet && got MENU_TOGGLE
res $((r1 || $?)) "a reader gets QUIT from the helper and MENU_TOGGLE from game-menu, one line each"

n=$(python3 - "$p" << 'EOF'
import os
import sys

fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
n = 0
for size in (4096, 1):
    try:
        while True:
            n += os.write(fd, b"x" * size)
    except BlockingIOError:
        pass
print(n)
EOF
)
send "$gcmd" QUIT
oneline && [[ $(< "$t/err") == *"Resource temporarily unavailable"* ]]
res $? "a full pipe ($n bytes until EAGAIN): exit 0 at once, one log line"
exec 4>&-
rm -f "$p"

printf 'invented\n' > "$p"
send "$gcmd" QUIT
oneline && [[ $(< "$p") == invented && $(< "$t/err") == *"is not a FIFO"* ]]
res $? "a regular file at the path: exit 0, one log line, the file unchanged"
rm -f "$p"

mkfifo -m 600 "$t/target"
exec 5<> "$t/target"
printf 'invented\n' > "$t/file"
ln -s "$t/target" "$p"
send "$gcmd" QUIT
oneline
r1=$?
line=
read -r -t 1 line <&5
ln -sfn "$t/file" "$p"
send "$gcmd" QUIT
oneline && [[ $r1 == 0 && -z $line && $(< "$t/file") == invented ]]
res $? "a symlink at the path, to a FIFO with a reader or to a file: exit 0, one log line each, nothing written"
exec 5>&-
rm -f "$p"

mkdir "$p"
send "$gcmd" QUIT
oneline
res $? "a directory at the path: exit 0, one log line"
rmdir "$p"

ok=0
for a in RESET '' 'QUIT QUIT' quit; do
  read -ra args <<< "$a"
  send "$gcmd" "${args[@]}"
  [[ $rc == 64 && ! -s $t/out && $(wc -l < "$t/err") == 1 ]] || { ok=1; echo "  '$a': rc $rc"; }
done
res $ok "RESET, no argument, two arguments or a lower case command exit 64"

env -u XDG_RUNTIME_DIR timeout 2 "$gcmd" QUIT > "$t/out" 2> "$t/err"
rc=$?
[[ $rc == 0 && ! -s $t/out ]]
res $? "no XDG_RUNTIME_DIR: exit 0"

if [[ -e /run/.containerenv ]]; then
  u=/run/user/$(id -u)
  if [[ ! -e $u ]]; then
    mkdir -p -m 700 "$u"
    made=$u
  fi
  if [[ ! -e $u/blockie-game.cmd ]]; then
    mkfifo -m 600 "$u/blockie-game.cmd"
    exec 4<> "$u/blockie-game.cmd"
    env -u XDG_RUNTIME_DIR timeout 2 "$gcmd" QUIT > "$t/out" 2> "$t/err"
    rc=$?
    quiet && got QUIT
    r1=$?
    XDG_RUNTIME_DIR='' timeout 2 "$gcmd" MENU_TOGGLE > "$t/out" 2> "$t/err"
    rc=$?
    quiet && got MENU_TOGGLE
    res $((r1 || $?)) "XDG_RUNTIME_DIR unset or empty: the helper writes to $u/blockie-game.cmd"
    exec 4>&-
    rm -f "$u/blockie-game.cmd"
  fi
fi

rm -f "$t/systemctl.log"
uptime_s > "$stamp"
send "$hooks/game-quit"
quiet && [[ ! -e $t/systemctl.log ]]
res $? "game-quit without a game: exit 0, nothing logged, no stop"
rm -f "$stamp"

mkfifo -m 600 "$p"
exec 4<> "$p"
send "$hooks/game-quit"
quiet && got QUIT && [[ ! -e $t/systemctl.log && $(< "$stamp") =~ ^[0-9]+$ ]]
r1=$?
send "$hooks/game-quit"
quiet && ! got QUIT 1 && [[ $(cat "$t/systemctl.log" 2> /dev/null) == '--user stop --no-block blockie-game.scope' && ! -e $stamp ]]
r2=$?
rm -f "$t/systemctl.log"
send "$hooks/game-quit"
quiet && got QUIT && [[ ! -e $t/systemctl.log ]]
res $((r1 || r2 || $?)) "game-quit: QUIT, a second hold while the FIFO stays stops the scope, the next hold sends QUIT again"

ok=0
for s in "$(($(uptime_s) - 8)):stop" "$(($(uptime_s) - 11)):quit" "$(uptime_s) 1:quit" "x:quit" ":quit"; do
  rm -f "$t/systemctl.log"
  printf '%s\n' "${s%:*}" > "$stamp"
  send "$hooks/game-quit"
  if [[ ${s##*:} == stop ]]; then
    quiet && ! got QUIT 1 && [[ -s $t/systemctl.log ]] || { ok=1; echo "  stamp '${s%:*}': no stop"; }
  else
    quiet && got QUIT && [[ ! -e $t/systemctl.log ]] || { ok=1; echo "  stamp '${s%:*}': no QUIT"; }
  fi
done
res $ok "game-quit stops only within 10 s of the last QUIT, an older or bad stamp sends QUIT"
exec 4>&-
rm -f "$p" "$stamp"

if (( fails )); then
  echo "game-cmd: $fails failed"
  exit 1
fi
echo "game-cmd: ok"
