#!/usr/bin/env bash
set -u

[[ -e /run/.containerenv ]] || { echo "ports: runs only in a container, it rewrites files under /usr" >&2; exit 2; }
game=/usr/bin/blockie-game
gcmd=/usr/libexec/blockie/blockie-game-cmd
shims=/usr/libexec/blockie/ports/bin
dl1=/usr/libexec/blockie/dl1
helper=/usr/libexec/blockie/blockie-ports
data=/var/lib/blockie/data
pdir=$data/roms/ports
libs=$pdir/PortMaster/libs
unp=$libs/.unpacked
t=$(mktemp -d "${TMPDIR:-/tmp}/ports.XXXXXX")
fails=0
for f in "$dl1" "$helper"; do
  [[ ! -e $f ]] || cp -p "$f" "$t/${f##*/}.orig"
done
restore() {
  local f
  for f in "$dl1" "$helper"; do
    if [[ -e $t/${f##*/}.orig ]]; then cp -p "$t/${f##*/}.orig" "$f"; else rm -f "$f"; fi
  done
  rm -f /etc/blockie/sessions.d/ports-test.conf
  rm -rf /run/blockie-gpu "${t:?}"
}
trap restore EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

export FAKE=$t/fake
mkdir -p "$FAKE/bin" "$t/run" "$pdir/sub" "$pdir/dir.sh" "$data/ports-home" "$data/cache/ports-tmp/run" \
  /etc/blockie/sessions.d /run/blockie-gpu
printf 'APP_ID=invented.session\n' > /etc/blockie/sessions.d/ports-test.conf
printf '%s\n' LD_LIBRARY_PATH=/invented/farm VK_DRIVER_FILES=/invented/icd.json > /run/blockie-gpu/gpu.env

cat > "$dl1" << EOF
#!/bin/sh
echo "\$1 \${ALSA_CONFIG_PATH-unset}" >> "$t/dl1.log"
EOF
cat > "$FAKE/bin/systemd-run" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/systemd-run.log"
while (( $# )) && [[ $1 != -- ]]; do
  shift
done
shift
[[ -z ${FAKE_DELAY:-} ]] || sleep "$FAKE_DELAY"
echo "$$" > "$FAKE/scope"
exec setsid "$@"
EOF
cat > "$FAKE/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/systemctl.log"
g=$(cat "$FAKE/scope" 2> /dev/null)
case "$*" in
  "--user show -P ActiveState blockie-game.scope")
    [[ -z $g ]] || ! kill -0 -- "-$g" 2> /dev/null || echo active
    ;;
  "--user stop --no-block blockie-game.scope" | "--user stop blockie-game.scope")
    [[ -n $g ]] || exit 5
    rm -f "$FAKE/scope"
    kill -TERM -- "-$g" 2> /dev/null
    [[ $3 != --no-block ]] || exit 0
    for _ in $(seq 40); do
      kill -0 -- "-$g" 2> /dev/null || exit 0
      sleep 0.05
    done
    kill -KILL -- "-$g" 2> /dev/null
    ;;
esac
exit 0
EOF
cat > "$FAKE/bin/wlrctl" << 'EOF'
#!/usr/bin/env bash
[[ "$*" == "toplevel list" ]] && cat "$FAKE/toplevels" 2> /dev/null
EOF
cat > "$FAKE/bin/mount" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/mount.log"
EOF
chmod 755 "$dl1" "$FAKE/bin/"*

cat > "$pdir/Probe.sh" << 'EOF'
echo "$$" > "$FAKE/port.pid"
find "/proc/$$/fd" -mindepth 1 -printf '%f %l\n' > "$FAKE/port.fds"
env > "$FAKE/port.env"
umask > "$FAKE/port.umask"
pwd > "$FAKE/port.cwd"
ls -A "$TMPDIR" > "$FAKE/port.tmp"
read -r -t 2 line
echo "rc $? line ${line:-}" > "$FAKE/port.stdin"
echo invented out
echo invented err >&2
case ${FAKE_PORT:-} in
  loop)
    while :; do
      sleep 0.1
    done
    ;;
  killquit)
    trap 'kill -KILL $$' TERM
    while :; do
      sleep 0.1
    done
    ;;
  bg)
    sleep 600 &
    echo "$!" > "$FAKE/port.bg"
    ;;
  rc1) exit 1 ;;
  kill) kill -KILL $$ ;;
esac
EOF
cp "$pdir/Probe.sh" "$pdir/Two Words.sh"
cp "$pdir/Probe.sh" "$pdir/sub/a.sh"
cp "$pdir/Probe.sh" "$pdir/a.txt"
ln -sfn "$pdir/Probe.sh" "$pdir/link.sh"
probe=$pdir/Probe.sh

clean() { rm -f "$FAKE"/*.log "$FAKE"/port.* "$FAKE/scope" "$t/dl1.log"; }
play() {
  clean
  PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run WAYLAND_DISPLAY=wayland-test "$game" ports "$@" > "$t/out" 2>&1
  rc=$?
}
launch() {
  clean
  PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run "$game" ports "$probe" > "$t/out" 2>&1 &
  w=$!
}
until_file() {
  local i
  for ((i = 0; i < ${2:-50}; i++)); do
    [[ -s $1 ]] && return 0
    sleep 0.1
  done
  return 1
}
quit() { XDG_RUNTIME_DIR=$t/run timeout 5 "$gcmd" QUIT > /dev/null 2>&1; }
finish() {
  wait "$w"
  rc=$?
}
ran() { [[ -s $FAKE/systemd-run.log ]]; }
refused() {
  play "$@"
  [[ $rc == 64 ]] && ! ran
}
envis() { grep -qxF -- "$1" "$FAKE/port.env"; }

ok=0
refused rel/Probe.sh || ok=1
refused "$pdir/none.sh" || ok=1
refused "$pdir/sub/a.sh" || ok=1
refused "$pdir/link.sh" || ok=1
refused "$pdir/a.txt" || ok=1
refused "$pdir/dir.sh" || ok=1
refused "$pdir/../ports/Probe.sh" || ok=1
refused "$pdir/te"$'\n'"st.sh" || ok=1
refused "$data/roms/Probe.sh" || ok=1
refused "$probe" --core mgba || ok=1
printf 'rewind_enable = "true"\n' > "$t/game.cfg"
refused "$probe" --config "$t/game.cfg" || ok=1
refused "$probe" --theme blue || ok=1
res $ok "ports: relative, missing, in a subdir, a symlink, not .sh, a directory, a .. path, control characters, outside roms/ports, --core or --config exit 64 before anything starts"

echo invented > "$data/cache/ports-tmp/run/stale"
FAKE_PORT=rc1 XDG_CONFIG_HOME=/invented XDG_DATA_HOME=/invented XDG_CACHE_HOME=/invented SDL_AUDIODRIVER=alsa \
  LD_LIBRARY_PATH=/stale play "$probe" --theme light
scope="--user --scope --quiet --unit=blockie-game --collect --slice=blockie-emulation.slice -p BindsTo=blockie-frontend.service"
scope+=" -p After=blockie-frontend.service -p MemoryHigh=80% -p MemoryMax=90% -p TasksMax=512 -p OOMPolicy=kill"
scope+=" -p TimeoutStopSec=10s --"
scope+=" env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u SDL_AUDIODRIVER PATH=$shims:$FAKE/bin:$PATH"
scope+=" HOME=$data/ports-home TMPDIR=$data/cache/ports-tmp/run PM_CAN_MOUNT=N ALSA_CONFIG_PATH=/usr/share/blockie/ports/alsa.conf"
scope+=" BLOCKIE_PORTMSG_ENV=WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR=$t/run LD_LIBRARY_PATH=/invented/farm"
scope+=" BLOCKIE_THEME=light bash $probe"
[[ $rc == 0 && $(< "$FAKE/systemd-run.log") == "$scope" ]] &&
  [[ $(sed -n 's/^PATH=//p' "$FAKE/port.env") == "$shims:$FAKE/bin:"* ]] && envis "HOME=$data/ports-home" &&
  envis "TMPDIR=$data/cache/ports-tmp/run" && envis PM_CAN_MOUNT=N && envis ALSA_CONFIG_PATH=/usr/share/blockie/ports/alsa.conf &&
  envis "BLOCKIE_PORTMSG_ENV=WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR=$t/run LD_LIBRARY_PATH=/invented/farm BLOCKIE_THEME=light" &&
  envis LD_LIBRARY_PATH=/invented/farm && envis VK_DRIVER_FILES=/invented/icd.json &&
  ! grep -qE '^(XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|SDL_AUDIODRIVER)=' "$FAKE/port.env" &&
  [[ $(< "$FAKE/port.umask") == 0022 && $(< "$FAKE/port.cwd") == "$pdir" && ! -s $FAKE/port.tmp ]]
res $? "a port runs bash <script> in one scope with a 10 s stop, from roms/ports, with the shims first, the ports HOME and TMPDIR (emptied), XDG and SDL_AUDIODRIVER unset, PM_CAN_MOUNT=N, the ALSA redirect, the portmsg env, gpu.env and umask 022"
FAKE_PORT=rc1 play "$probe"
[[ $rc == 0 && $(sed -n 's/^BLOCKIE_PORTMSG_ENV=//p' "$FAKE/port.env") == *" BLOCKIE_THEME=dark" ]]
res $? "the portmsg env carries the --theme, dark when none is given"

[[ $(sed -n 's/^0 //p' "$FAKE/port.fds") == /dev/null && $(sed -n 's/^1 //p' "$FAKE/port.fds") == "$t/run/blockie-ports/last.log" ]] &&
  ! grep -qE 'blockie-game\.(lock|cmd)' "$FAKE/port.fds" && ! grep -q '^3 ' "$FAKE/port.fds" &&
  [[ $(< "$FAKE/port.stdin") == "rc 1 line " ]] &&
  grep -qx 'invented out' "$t/run/blockie-ports/last.log" && grep -qx 'invented err' "$t/run/blockie-ports/last.log"
res $? "the port's stdin is /dev/null, its output goes to blockie-ports/last.log, it holds neither the game lock nor the command FIFO"

[[ $(< "$t/dl1.log") == $'check unset\nset unset' ]] && grep -qx -- '--user stop blockie-game.scope' "$FAKE/systemctl.log" &&
  [[ ! -e $t/run/blockie-game.cmd ]]
res $? "dl1 check before and dl1 set after run without ALSA_CONFIG_PATH; the scope is stopped and waited for after the script; the FIFO is removed"
ok=0
for w in 'wayland test' 'wayland-*' 'wayland-[0]'; do
  clean
  PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run WAYLAND_DISPLAY=$w "$game" ports "$probe" > "$t/out" 2>&1
  r=$?
  [[ $r == 70 && ! -e $FAKE/port.env ]] || { ok=1; echo "  '$w': rc $r"; }
done
res $ok "a WAYLAND_DISPLAY with a space or a glob character refuses with 70 before any port runs"

ok=0
FAKE_PORT=rc1 play "$pdir/Two Words.sh"
[[ $rc == 0 && -s $FAKE/port.pid ]] || { ok=1; echo "  exit 1: rc $rc"; }
FAKE_PORT=kill play "$probe"
[[ $rc == 1 ]] || { ok=1; echo "  killed: rc $rc"; }
res $ok "a script exiting 1 gives 0, a script killed (137) with no QUIT gives 1"

ok=0
FAKE_PORT=loop launch
until_file "$FAKE/port.pid" || ok=1
p=$(cat "$FAKE/port.pid" 2> /dev/null)
sleep 0.5
kill -0 "$w" 2> /dev/null || ok=1
quit
finish
[[ $ok == 0 && $rc == 0 && $(< "$FAKE/port.stdin") == "rc 1 line " ]] && ! kill -0 "$p" 2> /dev/null &&
  grep -qx -- '--user stop --no-block blockie-game.scope' "$FAKE/systemctl.log" && [[ ! -e $FAKE/scope ]]
res $? "QUIT on the FIFO reaches the wrapper, never the port's stdin: a port looping before any window is stopped, exit 0"

FAKE_PORT=killquit launch
until_file "$FAKE/port.pid"
quit
finish
[[ $rc == 0 ]]
res $? "a port killed (137) after a handled QUIT gives 0"

FAKE_DELAY=3 FAKE_PORT=loop launch
until_file "$FAKE/systemd-run.log"
sleep 0.3
quit
t0=$SECONDS
finish
[[ $rc == 0 && ! -e $FAKE/port.pid ]] && (( SECONDS - t0 <= 2 )) &&
  grep -qx -- '--user stop --no-block blockie-game.scope' "$FAKE/systemctl.log"
res $? "QUIT before the scope registers: the captured PID gets TERM, no port runs, exit 0"

FAKE_PORT=bg play "$probe"
r1=$rc
b=$(cat "$FAKE/port.bg" 2> /dev/null)
[[ $r1 == 0 && -n $b ]] && ! kill -0 "$b" 2> /dev/null && [[ ! -e $FAKE/scope ]]
r1=$?
FAKE_PORT=rc1 play "$probe"
[[ $r1 == 0 && $rc == 0 ]] && ran
res $? "a port that backgrounds sleep 600 and exits leaves no active scope, and the next launch runs"

printf '%s\n' 'net.seilent.Blockie.Frontend: Blockie' 'pre.existing: invented' > "$FAKE/toplevels"
FAKE_PORT=loop launch
until_file "$FAKE/port.pid"
printf '%s\n' 'net.seilent.Blockie.Frontend: Blockie' 'pre.existing: invented' 'invented.port: Invented' \
  'net.seilent.funeos: funeOS' 'Waydroid: Android' 'invented.session: x' 'com.libretro.RetroArch: RetroArch' \
  'net.seilent.Blockie.Port: x' 'blockie-invented: x' 'bad id: x' 'invented.two: x' 'invented.three: x' \
  'invented.four: x' 'invented.five: x' > "$FAKE/toplevels.new"
mv "$FAKE/toplevels.new" "$FAKE/toplevels"
until_file "$t/run/blockie-game.appids" 30
a=$(cat "$t/run/blockie-game.appids" 2> /dev/null)
quit
finish
[[ $rc == 0 && $a == $'invented.port\ninvented.two\ninvented.three\ninvented.four' && ! -e $t/run/blockie-game.appids ]]
res $? "app ids: only new ids, never a sessions.d APP_ID or FOCUS value, net.seilent.*, blockie-* or a bad id, at most 4, removed when the scope ends"
rm -f "$FAKE/toplevels"

FAKE_PORT=loop launch
until_file "$FAKE/port.pid"
p=$(cat "$FAKE/port.pid")
kill -STOP "$p"
printf 'invented.late: x\n' > "$FAKE/toplevels"
sleep 2.5
[[ ! -e $t/run/blockie-game.appids ]]
r1=$?
kill -CONT "$p"
until_file "$t/run/blockie-game.appids" 30
a=$(cat "$t/run/blockie-game.appids" 2> /dev/null)
quit
finish
[[ $r1 == 0 && $rc == 0 && $a == invented.late ]]
res $? "app ids: no poll while the scope is stopped, the id lands after SIGCONT"

ok=0
sudo=$(PATH=$shims:$PATH sudo echo invented 2>&1)
[[ $? == 1 && -z $sudo ]] || ok=1
res $ok "the sudo shim exits 1 and runs nothing"

rm -rf "${unp:?}"
mkdir -p "$unp" "$t/home"
idx() {
  python3 - "$1" "$2" >> "$unp/index.tsv" << 'EOF'
import os
import sys

s = os.stat(sys.argv[1])
print(f"{os.path.basename(sys.argv[1])[:-9]}\t{s.st_size}\t{s.st_mtime_ns}\t{s.st_ino}\t{sys.argv[2]}")
EOF
}
cat > "$helper" << EOF
#!/bin/sh
echo "\$* \${FAKE_LEAK-unset} \${WAYLAND_DISPLAY-unset}" >> "$t/helper.log"
[ "\$(cat "$t/helper.\$1" 2> /dev/null)" = ok ] || exit 1
f=\$2
if [ "\$1" = runtime ]; then
  f=$libs/\$2.squashfs
  printf 'invented refetch\n' > "\$f.part"
  mv -f "\$f.part" "\$f"
fi
h=\$(md5sum < "\$f" | cut -c1-32)
mkdir -p "$unp/\$h"
python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print(f"x\t{s.st_size}\t{s.st_mtime_ns}\t{s.st_ino}\t{sys.argv[2]}")' "\$f" "\$h" >> "$unp/index.tsv"
EOF
chmod 755 "$helper"
mnt() {
  rm -f "$t/helper.log"
  PATH=$shims:$FAKE/bin:$PATH FAKE_LEAK=1 BLOCKIE_PORTMSG_ENV="WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR=$t/run" \
    mount "$@" > "$t/out" 2>&1
  rc=$?
}
hlog() { [[ $(cat "$t/helper.log" 2> /dev/null) == "$1" ]]; }

printf 'invented runtime one\n' > "$libs/frt_9.9.squashfs"
h1=0123456789abcdef0123456789abcdef
mkdir -p "$unp/$h1"
idx "$libs/frt_9.9.squashfs" "$h1"
mkdir -p "$t/home/godot"
mnt /roms/ports/PortMaster/libs/frt_9.9.squashfs "$t/home/godot/"
[[ $rc == 0 && $(readlink "$t/home/godot") == "$unp/$h1" && -e $unp/$h1.used ]] && hlog ''
r1=$?
mnt /roms/ports/PortMaster/libs/frt_9.9.squashfs "$t/home/godot"
[[ $r1 == 0 && $rc == 0 && $(readlink "$t/home/godot") == "$unp/$h1" ]] && hlog ''
res $? "mount: an indexed runtime turns the empty dir (trailing slash dropped) into a link to its tree, marks it used, and replaces its own link again"

printf 'invented runtime two\n' > "$libs/love_9.9.squashfs"
echo ok > "$t/helper.unpack"
mkdir -p "$t/home/love"
mnt "$libs/love_9.9.squashfs" "$t/home/love"
h2=$(md5sum < "$libs/love_9.9.squashfs" | cut -c1-32)
[[ $rc == 0 && $(readlink "$t/home/love") == "$unp/$h2" ]] && hlog "unpack $libs/love_9.9.squashfs unset wayland-test"
r1=$?
rm -rf "${unp:?}/$h2"
rm -f "$t/home/love"
mkdir "$t/home/love"
mnt "$libs/love_9.9.squashfs" "$t/home/love"
[[ $r1 == 0 && $rc == 0 && -d $unp/$h2 && $(readlink "$t/home/love") == "$unp/$h2" ]] &&
  hlog "unpack $libs/love_9.9.squashfs unset wayland-test"
res $? "mount: a file not in the index, or a missing tree, is unpacked by blockie-ports in the clean env"

printf 'invented truncated\n' > "$libs/mono_9.9.squashfs"
echo fail > "$t/helper.unpack"
echo ok > "$t/helper.runtime"
mkdir -p "$t/home/mono"
mnt "$libs/mono_9.9.squashfs" "$t/home/mono"
h3=$(md5sum < "$libs/mono_9.9.squashfs" | cut -c1-32)
[[ $rc == 0 && $(< "$libs/mono_9.9.squashfs") == 'invented refetch' && $(readlink "$t/home/mono") == "$unp/$h3" ]] &&
  hlog "unpack $libs/mono_9.9.squashfs unset wayland-test"$'\n'"runtime mono_9.9 unset wayland-test"
r1=$?
printf 'invented truncated\n' > "$libs/java_9.9.squashfs"
echo fail > "$t/helper.runtime"
mkdir -p "$t/home/java"
mnt "$libs/java_9.9.squashfs" "$t/home/java"
[[ $r1 == 0 && $rc == 32 && -d $t/home/java && ! -L $t/home/java ]] &&
  hlog "unpack $libs/java_9.9.squashfs unset wayland-test"$'\n'"runtime java_9.9 unset wayland-test"
res $? "mount: an unpack that fails fetches the runtime again; when that fails too it exits 32 and leaves the dir"

ok=0
mkdir -p "$t/home/full"
echo invented > "$t/home/full/file"
echo invented > "$t/home/plain"
ln -sfn "$t/home/full" "$t/home/other"
for a in "$libs/frt_9.9.squashfs $t/home/full" "$libs/frt_9.9.squashfs $t/home/plain" \
  "$libs/frt_9.9.squashfs $t/home/other" "$libs/frt_9.9.squashfs $t/home/none" "--bind $t/home/full $t/home/new" \
  "$libs/frt_9.9.squashfs" "-t squashfs $libs/frt_9.9.squashfs $t/home/new" "$t/home/plain $t/home/new" \
  "$libs/none.squashfs $t/home/new"; do
  read -ra args <<< "$a"
  rm -f "$FAKE/mount.log"
  mnt "${args[@]}"
  [[ $rc == 32 && ! -e $FAKE/mount.log && ! -e $t/home/new ]] || { ok=1; echo "  mount $a: rc $rc"; }
done
[[ -f $t/home/full/file && -f $t/home/plain && $(readlink "$t/home/other") == "$t/home/full" ]] || ok=1
res $ok "mount: a full dir, a file, a foreign link, a missing dir, --bind, other argument forms and missing files exit 32 without /usr/bin/mount and change nothing"

ok=0
PATH=$shims:$PATH umount "$libs/frt_9.9.squashfs" || ok=1
[[ -f $libs/frt_9.9.squashfs ]] || ok=1
PATH=$shims:$PATH umount "$t/home/other" "$t/home/full" || ok=1
[[ -L $t/home/other && -f $t/home/full/file ]] || ok=1
PATH=$shims:$PATH umount -l "$t/home/godot/" || ok=1
[[ ! -e $t/home/godot && ! -L $t/home/godot && -d $unp/$h1 ]] || ok=1
res $ok "umount: a squashfs file, a foreign link and a dir stay (exit 0), our own link goes and its tree stays"

ok=0
for f in sudo mount umount; do
  [[ $(stat -c %a "$shims/$f") == 755 ]] || { ok=1; echo "  $f"; }
done
res $ok "the shims are 755"

if [[ $fails == 0 ]]; then
  echo "ports: all ok"
  exit 0
fi
echo "ports: $fails failed"
exit 1
