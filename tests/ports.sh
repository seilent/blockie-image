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

ok=0
python3 -I -B - "$helper" << 'EOF' || ok=1
import ast, os, sys

sys.path[:0] = ["/usr/share/blockie/portmaster/PortMaster/pylibs", "/usr/share/blockie/portmaster/PortMaster/exlibs"]
import requests.certs

ca = next(n.value.value for n in ast.parse(open(sys.argv[1]).read()).body
          if isinstance(n, ast.Assign) and [t.id for t in n.targets if isinstance(t, ast.Name)] == ["CA"])
assert requests.certs.where() == ca, (requests.certs.where(), ca)
assert os.path.isfile(ca) and b"BEGIN CERTIFICATE" in open(ca, "rb").read(), ca
EOF
res $ok "the CA bundle requests and the helper name is a file in the image"

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
scope+=" BLOCKIE_THEME=light BLOCKIE_GPULIB=/invented/farm bash $probe"
[[ $rc == 0 && $(< "$FAKE/systemd-run.log") == "$scope" ]] &&
  [[ $(sed -n 's/^PATH=//p' "$FAKE/port.env") == "$shims:$FAKE/bin:"* ]] && envis "HOME=$data/ports-home" &&
  envis "TMPDIR=$data/cache/ports-tmp/run" && envis PM_CAN_MOUNT=N && envis ALSA_CONFIG_PATH=/usr/share/blockie/ports/alsa.conf &&
  envis "BLOCKIE_PORTMSG_ENV=WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR=$t/run LD_LIBRARY_PATH=/invented/farm BLOCKIE_THEME=light" &&
  envis LD_LIBRARY_PATH=/invented/farm && envis VK_DRIVER_FILES=/invented/icd.json && envis BLOCKIE_GPULIB=/invented/farm &&
  ! grep -qE '^(XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|SDL_AUDIODRIVER)=' "$FAKE/port.env" &&
  [[ $(< "$FAKE/port.umask") == 0022 && $(< "$FAKE/port.cwd") == "$pdir" && ! -s $FAKE/port.tmp ]]
res $? "a port runs bash <script> in one scope with a 10 s stop, from roms/ports, with the shims first, the ports HOME and TMPDIR (emptied), XDG and SDL_AUDIODRIVER unset, PM_CAN_MOUNT=N, the ALSA redirect, the portmsg env, gpu.env, BLOCKIE_GPULIB and umask 022"
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

mod=/usr/share/blockie/portmaster/mod_Blockie.txt
compat=/usr/lib64/blockie-ports/compat
ww=$t/ww
x=$ww/x
mkdir -p "$ww/gpu1" "$ww/gpu2" "$ww/crusty" "$ww/app" "$x/.X11-unix"
for f in gpu1/libEGL.so gpu1/libGLESv2.so gpu2/libGLESv2.so crusty/libEGL.so app/libEGL.so app/libGLESv2.so; do
  : > "$ww/$f"
done
cat > "$ww/westonwrap.sh" << EOF
#!/bin/bash
CFW_NAME=Blockie
source "$mod"
[[ -z \${WW_TWICE:-} ]] || source "$mod"
printf '%s\n' "\$LD_LIBRARY_PATH" "\$WRAPPED_LIBRARY_PATH_MALI" "\${SEATD_VTBOUND-unset}" "\${WP_32BIT-unset}"
EOF
cp "$ww/westonwrap.sh" "$ww/other.sh"
wwenv() {
  local n=$1
  shift
  env -i PATH=/usr/bin:/usr/sbin "$@" bash "$ww/$n" cleanup > "$ww/out" 2> /dev/null
  mapfile -t got < "$ww/out"
  got+=("" "" "" "")
}
resolve() {
  local d
  local -a dirs
  IFS=: read -ra dirs <<< "$1"
  for d in "${dirs[@]}"; do
    [[ -n $d && -e $d/$2 ]] && { printf '%s' "${d%/}"; return 0; }
  done
  return 1
}
penv=(BLOCKIE_GPULIB="$ww/gpu1:$ww/gpu2" WRAPPED_LIBRARY_PATH_MALI="$ww/portmali" LD_LIBRARY_PATH="$ww/inherited")
wwenv westonwrap.sh "${penv[@]}"
p="$ww/crusty/::${got[1]}::$ww/app"
[[ ${got[0]} == "$ww/inherited:$ww/gpu1:$ww/gpu2:$compat" && ${got[1]} == "$ww/portmali:$ww/gpu1:$ww/gpu2:$compat" &&
  $(resolve "$p" libGLESv2.so) == "$ww/gpu1" && $(resolve "$p" libEGL.so) == "$ww/crusty" && ${got[2]} == 0 &&
  ${got[3]} == 0 ]]
res $? "westonwrap*.sh: the game's path as westonwrap.sh:48 builds it finds libGLESv2.so in the first BLOCKIE_GPULIB dir and libEGL.so in the crusty dir, a port's _MALI value first, the compat dir last on both paths, SEATD_VTBOUND=0, WP_32BIT=0"

ok=0
for e in "BLOCKIE_GPULIB=" "BLOCKIE_INVENTED=1"; do
  wwenv westonwrap.sh "$e"
  [[ ${got[0]} == "$compat" && ${got[1]} == "$compat" ]] || { ok=1; echo "  $e: ${got[*]}"; }
done
wwenv westonwrap.sh BLOCKIE_GPULIB=":$ww/gpu1::" LD_LIBRARY_PATH="$ww/inherited:"
[[ ${got[0]} == "$ww/inherited:$ww/gpu1:$compat" && ${got[1]} == "$ww/gpu1:$compat" ]] || { ok=1; echo "  empty parts: ${got[*]}"; }
wwenv westonwrap.sh WW_TWICE=1 "${penv[@]}"
[[ ${got[0]} == "$ww/inherited:$ww/gpu1:$ww/gpu2:$compat" && ${got[1]} == "$ww/portmali:$ww/gpu1:$ww/gpu2:$compat" ]] ||
  { ok=1; echo "  sourced twice: ${got[*]}"; }
wwenv other.sh "${penv[@]}"
[[ ${got[0]} == "$ww/inherited" && ${got[1]} == "$ww/portmali" && ${got[2]} == unset ]] || { ok=1; echo "  other.sh: ${got[*]}"; }
res $ok "westonwrap*.sh: no empty element with an empty or missing BLOCKIE_GPULIB or empty parts, no dir twice when sourced twice; another script name keeps LD_LIBRARY_PATH, WRAPPED_LIBRARY_PATH_MALI and SEATD_VTBOUND"

cat > "$ww/westonwrap_wait.sh" << EOF
#!/bin/bash
CFW_NAME=Blockie
source "$mod"
for ((i = 0; i < \${WW_WAIT:-0}; i++)); do
  [[ -e \$BLOCKIE_XDIR/.X11-unix/X0 || -e \$BLOCKIE_XDIR/.X11-unix/X1 ]] && break
  sleep 0.1
done
sleep "\${WW_LINGER:-0}"
echo ended
EOF
wwrun() {
  local log=$1
  shift
  env -i PATH=/usr/bin:/usr/sbin BLOCKIE_XDIR="$x" "${@}" > "$log" 2>&1
}
wargs=(headless noop kiosk crusty_x11egl true)
dead() { bash -c 'echo $$'; }
lockx() {
  printf '%10d\n' "$2" > "$x/.X$1-lock"
  : > "$x/.X11-unix/X$1"
}
mkfifo "$ww/fifo"
cp /usr/bin/bash "$ww/Xwayland"
cp /usr/bin/bash "$ww/wp_weston"
cp /usr/bin/bash "$ww/notx"
held=()
for n in Xwayland wp_weston notx; do
  "$ww/$n" -c 'read -r -t 60 <> "$1"' _ "$ww/fifo" &
  held+=("$!")
done
lockx 0 "$(dead)"
lockx 1 "${held[2]}"
lockx 2 "${held[0]}"
lockx 3 "${held[1]}"
lockx 4 "$(dead)"
chown 1000 "$x/.X4-lock"
lockx 5 1
printf 'invented\n' > "$x/.X5-lock"
ok=0
wwrun "$ww/log" BLOCKIE_XWATCH_POLLS=1 bash "$ww/westonwrap_wait.sh" "${wargs[@]}"
for n in 0 1 5; do
  [[ ! -e $x/.X$n-lock && ! -e $x/.X11-unix/X$n ]] || { ok=1; echo "  :$n kept"; }
done
for n in 2 3 4; do
  [[ -f $x/.X$n-lock && -e $x/.X11-unix/X$n ]] || { ok=1; echo "  :$n removed"; }
done
lockx 6 "$(dead)"
for a in cleanup "headless noop kiosk crusty_x11egl"; do
  read -ra args <<< "$a"
  wwrun "$ww/log" BLOCKIE_XWATCH_POLLS=2 WW_LINGER=1.6 bash "$ww/westonwrap_wait.sh" "${args[@]}"
  [[ $? == 0 && $(< "$ww/log") == ended && -f $x/.X6-lock ]] || { ok=1; echo "  $a: $(< "$ww/log")"; }
done
kill "${held[@]}" 2> /dev/null
wait "${held[@]}" 2> /dev/null
res $ok "the X lock step removes the port user's locks whose pid is dead, not a number or a live process other than Xwayland or wp_weston, each with its socket, and keeps those of a live Xwayland or wp_weston and another user's; with cleanup or 4 arguments neither it nor the watcher runs"

ok=0
rm -f "$x"/.X*-lock "$x"/.X11-unix/X*
wwrun "$ww/log" BLOCKIE_XWATCH_POLLS=2 WW_WAIT=100 timeout 20 bash "$ww/westonwrap_wait.sh" "${wargs[@]}"
r=$?
[[ $r == 143 && $(< "$ww/log") == 'blockie: westonpack display not up' ]] || { ok=1; echo "  no socket: rc $r $(< "$ww/log")"; }
(sleep 0.3; : > "$x/.X11-unix/X1") &
wwrun "$ww/log" BLOCKIE_XWATCH_POLLS=3 WW_WAIT=100 WW_LINGER=2.5 timeout 20 bash "$ww/westonwrap_wait.sh" "${wargs[@]}"
r=$?
[[ $r == 0 && $(< "$ww/log") == ended ]] || { ok=1; echo "  socket in time: rc $r $(< "$ww/log")"; }
rm -f "$x"/.X11-unix/X*
wwrun "$ww/log" BLOCKIE_XWATCH_POLLS=3 bash "$ww/westonwrap_wait.sh" "${wargs[@]}"
sleep 2.2
[[ $(< "$ww/log") == ended ]] || { ok=1; echo "  westonwrap gone: $(< "$ww/log")"; }
res $ok "the watcher TERMs a westonwrap whose X socket never comes and logs its line, leaves one alone whose socket comes in time, and stops when westonwrap exits"

if [[ $fails == 0 ]]; then
  echo "ports: all ok"
  exit 0
fi
echo "ports: $fails failed"
exit 1
