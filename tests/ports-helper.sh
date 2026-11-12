#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
[[ -e /run/.containerenv ]] ||
  { echo "ports-helper: runs only in a container, it puts fakes at the blockie-portmsg and blockie-ports paths" >&2; exit 2; }
lx=/usr/libexec/blockie
helper=$lx/blockie-ports
[[ -x $helper ]] || helper=$here/../system_files/usr/libexec/blockie/blockie-ports
gen=$lx/ports/alsa-gen
[[ -x $gen ]] || gen=$here/../system_files/usr/libexec/blockie/ports/alsa-gen
pm=/usr/share/blockie/portmaster
[[ -f $pm/mod_Blockie.txt ]] || pm=$here/../system_files/usr/share/blockie/portmaster
mod=$pm/mod_Blockie.txt
shim=$pm/harbourmaster
unit=/usr/lib/systemd/system/blockie-ports-sync.service
[[ -f $unit ]] || unit=$here/../system_files/usr/lib/systemd/system/blockie-ports-sync.service
portmsg=$lx/blockie-portmsg
fixtures=$here/ports-helper
t=$(mktemp -d "${TMPDIR:-/tmp}/ports-helper.XXXXXX")
fails=0
swapped=()

restore() {
  local p
  for p in "${swapped[@]}"; do
    rm -f "${p:?}"
    if [[ -e $t/saved.${p##*/} ]]; then
      mv "$t/saved.${p##*/}" "$p"
    fi
  done
  swapped=()
}
trap 'restore; rm -rf "${t:?}"' EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

swap() {
  if [[ -e $1 ]]; then
    mv "$1" "$t/saved.${1##*/}"
  fi
  swapped+=("$1")
  mkdir -p "${1%/*}"
  cat > "$1"
  chmod 755 "$1"
}

prog=$lx/ports/run-progress
[[ -x $prog ]] || prog=$here/../system_files/usr/libexec/blockie/ports/run-progress
[[ -x $helper && $(head -n 1 "$helper") == '#!/usr/bin/python3 -IS' && -x $shim && -x $gen && -x $prog && -f $mod ]]
res $? "the helper, the harbourmaster shim, run-progress and alsa-gen are installed executable, the helper runs python3 -IS"

ok=0
want=('After=blockie-data.service blockie-dl1.service' 'Before=blockie-seat.service' 'ConditionPathIsMountPoint=/var/lib/blockie/data'
  'Type=oneshot' 'User=blockie' 'TimeoutStartSec=60' 'ExecStartPre=+/usr/libexec/blockie/dl1 check' 'ExecStart=/usr/libexec/blockie/blockie-ports sync' 'WantedBy=multi-user.target')
for l in "${want[@]}"; do
  grep -qxF "$l" "$unit" || { ok=1; echo "  no '$l'"; }
done
if [[ $unit == /usr/* ]]; then
  [[ -L /etc/systemd/system/multi-user.target.wants/blockie-ports-sync.service ]] || { ok=1; echo "  not enabled"; }
fi
res $ok "sync unit: a oneshot as blockie after the data mount and before the seat, only on a mounted data partition, enabled"

mkdir -p "$t/py"
PORTS_BIN=$helper FAKE_HM=$fixtures/fakehm T=$t/py REAL_USR=/usr/share/blockie/portmaster \
  timeout -k 10 600 python3 "$here/ports-helper.py" > "$t/py.out" 2>&1
rc=$?
cat "$t/py.out"
n=$(grep -c '^FAIL ' "$t/py.out")
fails=$((fails + n))
(( rc == 0 || n > 0 )) || { echo "FAIL python cases ended with rc $rc"; fails=$((fails + 1)); }

mkdir -p "$t/run" "$t/cf" "$t/home" "$t/ww"
msgenv="WAYLAND_DISPLAY=wayland-invented XDG_RUNTIME_DIR=$t/run BLOCKIE_THEME=dark"
swap "$portmsg" << 'EOF'
#!/bin/bash
{
  printf 'args'
  printf ' [%s]' "$@"
  printf '\n'
  /usr/bin/env | /usr/bin/sort | /usr/bin/sed 's/^/env /'
  if [[ ${1-} == --progress ]]; then
    /usr/bin/sed 's/^/stdin /'
  fi
} >> "$XDG_RUNTIME_DIR/portmsg.log"
EOF

cat > "$t/fns.sh" << 'EOF'
show() {
  get_controls
  printf '%s\n' "$ANALOGSTICKS" "$LOWRES" "$DEVICE" "$param_device" "$SDL_GAMECONTROLLERCONFIG_FILE" \
    "$sdl_controllerconfig" "$SDL_VIDEODRIVER" "$SDL_VIDEO_WAYLAND_WMCLASS" "$SDL_APP_ID" "$CUR_TTY" "$GODOT_OPTS" \
    "$GODOT2_OPTS"
}
dialog() {
  PortMasterDialogInit
  PortMasterDialog progress "Preparing game data" 5 100
  PortMasterDialog progress "Preparing game data" 50 100
  PortMasterDialog progress_clear
}
EOF

modrun() {
  : > "$t/run/portmsg.log"
  env -i PATH=/usr/bin:/usr/sbin XDG_RUNTIME_DIR="$t/run" BLOCKIE_PORTMSG_ENV="$msgenv" DISPLAY_WIDTH=960 \
    DISPLAY_HEIGHT=720 ANALOG_STICKS=0 CFW_NAME=Blockie controlfolder="$t/cf" PORT_CANARY=invented \
    LD_PRELOAD=/nonexistent.so bash -c 'source "$1"; source "$2"; shift 2; "$@"; wait' _ "$mod" "$t/fns.sh" "$@" 2> /dev/null
}
calls() { grep '^args' "$t/run/portmsg.log"; }

le() { printf '%02x%02x' $(($1 & 255)) $(($1 >> 8)); }
keys=(304 305 307 308 310 311 312 313 314 315 316)
b() {
  local i
  for i in "${!keys[@]}"; do
    [[ ${keys[i]} != "$1" ]] || echo "b$i"
  done
}
guid=$(le 0x0019)0000$(le 0x4001)0000$(le 0x0428)0000$(le 0x0100)0000
map="$guid,AYANEO Controller,a:$(b 305),b:$(b 304),x:$(b 308),y:$(b 307),back:$(b 314),start:$(b 315),guide:$(b 316)"
map+=",leftshoulder:$(b 310),rightshoulder:$(b 311),lefttrigger:$(b 312),righttrigger:$(b 313)"
map+=",dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8,platform:Linux,"
out=$(modrun show)
db=$t/run/blockie-ports/gamecontrollerdb.txt
expect=$(printf '%s\n' 0 N blockie blockie "$db" "$map" wayland net.seilent.Blockie.Port net.seilent.Blockie.Port \
  /dev/null "--resolution 960x720 -f" "-r 960x720 -f")
[[ $out == "$expect" && $(< "$db") == "$map" ]] && ! grep -qE 'left[xy]|right[xy]' "$db"
res $? "get_controls: no sticks, the AYANEO pad by position (bottom a, right b) from the P0 key list, no stick axes, Wayland app id"
[[ $out == "$expect" ]] || diff <(printf '%s\n' "$expect") <(printf '%s\n' "$out") | sed 's/^/  /'

ok=0
for s in "This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info." \
  "This port requires the latest version of PortMaster." \
  "THIS PORT REQUIRES A NEWER VERSION OF PORTMASTER (patcher.txt support). Please update PortMaster and try again." \
  "Blockie Test One: This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info."; do
  modrun pm_message "$s" > /dev/null
  [[ $(calls) == 'args [--text] [this port needs a newer blockie] [--wait]' ]] || { ok=1; echo "  '$s': $(calls)"; }
done
modrun PortMasterDialog message "This port requires the latest PortMaster."
[[ $(calls) == 'args [--progress]' ]] && grep -qx 'stdin this port needs a newer blockie' "$t/run/portmsg.log" ||
  { ok=1; echo "  dialog message: $(calls)"; }
res $ok "the requires a newer PortMaster messages show in Blockie words, whatever their case"

modrun pm_message "Extracting game data, this can take a few minutes..." --title "Please wait" --type info > /dev/null
grep -q '^env LD_PRELOAD=' "$t/run/portmsg.log" || grep -q '^env PORT_CANARY=' "$t/run/portmsg.log"
leaked=$?
[[ $leaked == 1 && $(calls) == 'args [--text] [Extracting game data, this can take a few minutes...] [--title] [Please wait] [--wait]' ]] &&
  grep -qx 'env WAYLAND_DISPLAY=wayland-invented' "$t/run/portmsg.log" && grep -qx 'env BLOCKIE_THEME=dark' "$t/run/portmsg.log"
res $? "pm_message under LD_PRELOAD=/nonexistent.so runs blockie-portmsg with only BLOCKIE_PORTMSG_ENV, in the background with --wait"

ok=0
check() {
  local want=$1
  shift
  modrun "$@" > /dev/null
  [[ $(calls) == "$want" ]] || { ok=1; echo "  $*: $(calls)"; }
}
check 'args [--text] [Done] [--timeout] [5]' pm_message "Done" --timeout 5
check '' pm_message "Patching process already completed. Skipping."
check 'args [--text] [Game files missing] [--title] [Missing] [--timeout] [10] [--wait]' \
  pm_show_error "Game files missing" --title "Missing" --type warning
check 'args [--close]' pm_message_close
check 'args [--close]' PortMasterDialogExit
check $'args [--text] [Unable to download] [--timeout] [10] [--wait]' PortMasterDialogMessageBox "Unable to download"
check $'args [--progress]\nargs [--progress-set] [5] [100]\nargs [--progress-set] [50] [100]' dialog
[[ $(grep -c '^stdin ' "$t/run/portmsg.log") == 1 ]] || { ok=1; echo "  the progress text was sent more than once"; }
res $ok "pm_message --timeout, pm_show_error and the message box wait with a timeout, close, and dialog progress"

printf '#!/bin/sh\necho "$@" >> %s/cf.args\nexit "$(cat %s/cf.rc)"\n' "$t" "$t" > "$t/cf/harbourmaster"
chmod 755 "$t/cf/harbourmaster"
echo 0 > "$t/cf.rc"
a=$(modrun PortMasterDialogCheckRuntime frt_3.5.2.squashfs)
echo 1 > "$t/cf.rc"
r=$(modrun PortMasterDialogCheckRuntime frt_3.5.2.squashfs)
[[ $a == OKAY && $r == FAIL && $(< "$t/cf.args") == $'--quiet --no-check runtime_check frt_3.5.2.squashfs\n--quiet --no-check runtime_check frt_3.5.2.squashfs' ]]
res $? "PortMasterDialogCheckRuntime runs the harbourmaster shim and answers OKAY or FAIL"

ok=0
for n in westonwrap.sh westonwrap_x11.sh other.sh; do
  printf '#!/bin/bash\nCFW_NAME=Blockie\nsource "%s"\necho "$CFW_NAME"\n' "$mod" > "$t/ww/$n"
  printf 'declare -F glxinfo > /dev/null && echo fn || echo nofn\n' >> "$t/ww/$n"
  printf 'glxinfo 2> /dev/null | grep -q "OpenGL version string" && echo gl || echo nogl\n' >> "$t/ww/$n"
  out=$(env -i PATH=/usr/bin bash "$t/ww/$n" | tr '\n' ' ')
  case $n in
    westonwrap*) [[ $out == "ROCKNIX fn nogl " ]] || { ok=1; echo "  $n: $out"; } ;;
    *) [[ $out == "Blockie nofn nogl " ]] || { ok=1; echo "  $n: $out"; } ;;
  esac
done
res $ok "inside westonwrap*.sh the mod sets CFW_NAME=ROCKNIX and a glxinfo with no GL version, elsewhere it does not"

echo 0 > "$t/helper.rc"
swap "$helper" << EOF
#!/bin/bash
{
  printf 'args'
  printf ' [%s]' "\$@"
  printf '\n'
  /usr/bin/env | /usr/bin/sort | /usr/bin/sed 's/^/env /'
} >> "$t/helper.log"
printf 'progress\truntime\t10\t100\nprogress\truntime\t100\t100\nprogress\tunpack\t0\t100\ndone\t%s\n' "\$2"
exit "\$(cat "$t/helper.rc")"
EOF
shimrun() {
  : > "$t/run/portmsg.log"
  env -i PATH=/usr/bin:/usr/sbin HOME="$t/home" XDG_RUNTIME_DIR="$t/run" BLOCKIE_PORTMSG_ENV="$msgenv" \
    PORT_CANARY=invented LD_PRELOAD=/nonexistent.so "$shim" "$@" 2> /dev/null
}
: > "$t/helper.log"
shimrun --quiet --no-check runtime_check frt_3.5.2.squashfs
r1=$?
log=$(< "$t/helper.log")
want=$'args [--progress] [--title] [frt_3.5.2]\nargs [--progress-set] [10] [100]\nargs [--progress-set] [100] [100]\nargs [--progress-set] [0] [100]'
[[ $r1 == 0 && $log == "args [runtime] [frt_3.5.2]"* && $log == *$'\nenv PATH=/usr/bin:/usr/sbin\n'* ]] &&
  [[ $log == *$'\nenv LANG=C.UTF-8\n'* && $log == *"env XDG_RUNTIME_DIR=$t/run"* && $log != *LD_PRELOAD* && $log != *PORT_CANARY* ]] &&
  [[ $(calls | sort) == "$(sort <<< "$want")" ]] &&
  [[ $(grep '^stdin ' "$t/run/portmsg.log") == $'stdin runtime\nstdin unpack' ]]
res $? "the harbourmaster shim runs blockie-ports runtime <name> under a clean env and shows its progress"
echo 1 > "$t/helper.rc"
: > "$t/helper.log"
shimrun --no-check --quiet runtime_check frt_3.5.2.squashfs
[[ $? == 1 && $(grep -c '^args' "$t/helper.log") == 1 ]]
res $? "the shim takes the flags in either order and passes the helper's exit status"

ok=0
: > "$t/helper.log"
for a in '' 'runtime_check frt_3.5.2.squashfs' '--quiet runtime_check frt_3.5.2.squashfs' \
  '--quiet --no-check install frt_3.5.2.zip' '--quiet --no-check runtime_check frt_3.5.2' \
  '--quiet --no-check runtime_check ../frt_3.5.2.squashfs' '--quiet --no-check --offline runtime_check frt_3.5.2.squashfs' \
  '--quiet --no-check runtime_check a.squashfs b.squashfs' '--quiet --quiet --no-check runtime_check a.squashfs' \
  '--quiet --no-check runtime_list' '--quiet --no-check runtime_check .hidden.squashfs'; do
  read -ra args <<< "$a"
  shimrun "${args[@]}"
  [[ $? == 1 ]] || { ok=1; echo "  '$a' was not refused"; }
done
[[ ! -s $t/helper.log ]] || { ok=1; echo "  the helper ran for a refused form"; }
res $ok "the shim refuses every other form with exit 1 and never runs the helper"
restore

printf '%b\n' '# invented top file' '' '@hooks [' '\t{' '\t\tfunc load' '\t\tfiles [' '\t\t\t"/etc/alsa/conf.d"' \
  '\t\t\t"~/.asoundrc"' '\t\t]' '\t\terrors false' '\t}' ']' '' 'cards.@hooks [' '\t{' '\t\tfunc load' '\t\tfiles [' \
  '\t\t\t"/invented/cards"' '\t\t]' '\t}' ']' 'pcm.invented { type null }' > "$t/top.conf"
printf '%b\n' '# invented top file' '' '@hooks [' '\t{' '\t\tfunc load' '\t\tfiles [' '\t\t\t"/etc/alsa/conf.d"' \
  '\t\t\t"/usr/share/blockie/ports/alsa-redirect.conf"' '\t\t]' '\t\terrors false' '\t}' ']' '' 'cards.@hooks [' '\t{' \
  '\t\tfunc load' '\t\tfiles [' '\t\t\t"/invented/cards"' '\t\t]' '\t}' ']' 'pcm.invented { type null }' > "$t/top.want"
"$gen" "$t/top.conf" "$t/alsa.conf" && cmp -s "$t/alsa.conf" "$t/top.want" && [[ $(stat -c %a "$t/alsa.conf") == 644 ]]
res $? "alsa-gen replaces only the top hook file list with /etc/alsa/conf.d and the redirect"

ok=0
printf 'pcm.!default { type hw }\n' > "$t/nohooks.conf"
printf '@hooks [\n\t{\n\t\tfunc load\n\t\terrors false\n\t}\n]\n' > "$t/nofiles.conf"
for f in nohooks nofiles; do
  "$gen" "$t/$f.conf" "$t/$f.out" 2> "$t/gen.err"
  [[ $? == 1 && ! -e $t/$f.out && -s $t/gen.err ]] || { ok=1; echo "  $f"; }
done
[[ -z $(find "$t" -maxdepth 1 -name '*.out.*') ]] || { ok=1; echo "  temp files left"; }
res $ok "alsa-gen fails loudly and writes nothing when the hook file list is not found"

if [[ $gen == /usr/* ]]; then
  "$gen" /usr/share/alsa/alsa.conf "$t/image.conf" && cmp -s "$t/image.conf" /usr/share/blockie/ports/alsa.conf &&
    grep -qxF $'\t\t\t"/usr/share/blockie/ports/alsa-redirect.conf"' /usr/share/blockie/ports/alsa.conf &&
    grep -q '^pcm.!hw {' /usr/share/blockie/ports/alsa-redirect.conf
  res $? "the image's alsa.conf is alsa-gen's output for its own alsa-lib file and loads the redirect"
fi

if (( fails )); then
  echo "ports-helper: $fails failed"
  exit 1
fi
echo "ports-helper: ok"
