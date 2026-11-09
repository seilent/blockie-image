#!/usr/bin/env bash
set -u

[[ -e /run/.containerenv ]] || { echo "game: runs only in a container, it rewrites files under /usr" >&2; exit 2; }
game=/usr/bin/blockie-game
gcmd=/usr/libexec/blockie/blockie-game-cmd
share=/usr/share/blockie/retroarch
data=/var/lib/blockie/data
t=$(mktemp -d "${TMPDIR:-/tmp}/game.XXXXXX")
fails=0
cp -p "$share/shader-defaults" "$t/shader-defaults"
trap 'cp -p "$t/shader-defaults" "$share/shader-defaults"; rm -rf "${t:?}"' EXIT
: > "$share/shader-defaults"

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

export FAKE=$t/fake
export BLOCKIE_GAME_BUTTONS=$t/buttons BLOCKIE_GAME_INPUT=$t/input.cfg
bmap() {
  local a b
  declare -A x=([home.tap]=none [home.hold]=switcher [extra1.tap]=none [extra1.hold]=none [extra2.tap]=none
    [extra2.hold]=none [extra3.tap]=game-menu [extra3.hold]=game-quit)
  for a in "$@"; do
    x[${a%%=*}]=${a#*=}
  done
  {
    echo 'version 1'
    for b in home extra1 extra2 extra3; do
      echo "$b tap ${x[$b.tap]}"
      echo "$b hold ${x[$b.hold]}"
      if [[ ${x[$b.tap]} == none && ${x[$b.hold]} == none ]]; then echo "$b free yes"; else echo "$b free no"; fi
    done
  } > "$BLOCKIE_GAME_BUTTONS"
}
bmap
mkdir -p "$FAKE/bin" "$t/run" "$t/r\"un" "$data/roms/gba" "$data/roms/psp" "$data/roms/n64" "$data/roms/dir" \
  /usr/share/libretro/shaders/crt /var/lib/blockie/shaders
printf 'invented rom\n' > "$data/roms/gba/test.gba"
printf 'invented iso\n' > "$data/roms/psp/test.iso"
printf 'invented rom\n' > "$data/roms/n64/test.z64"
for f in crt/test.glslp crt/test.slangp crt/game.glslp crt/test.glsl; do
  printf 'invented shader\n' > "/usr/share/libretro/shaders/$f"
done
printf 'invented shader\n' > /var/lib/blockie/shaders/test.slangp
printf 'invented shader\n' > /var/lib/blockie/shaders/test.glslp
printf 'invented shader\n' > "$t/outside.glslp"
ln -sfn "$t/outside.glslp" /usr/share/libretro/shaders/crt/out.glslp
ln -sfn /etc/passwd "$data/roms/gba/out.gba"
ln -sfn "$data/roms/gba/test.gba" "$data/roms/gba/in.gba"
rom=$data/roms/gba/test.gba
: > "$t/nocard"

cat > "$FAKE/bin/systemd-run" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/systemd-run.log"
while (( $# )) && [[ $1 != -- ]]; do
  shift
done
shift
exec "$@"
EOF
cat > "$FAKE/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/systemctl.log"
if [[ "$*" == "--user show -P ActiveState blockie-game.scope" ]]; then
  read -ra s <<< "${FAKE_STATE:-}"
  n=$(grep -cxF -- "$*" "$FAKE/systemctl.log")
  (( n <= ${#s[@]} )) || n=${#s[@]}
  (( ! n )) || printf '%s\n' "${s[n - 1]}"
fi
[[ "$*" != "--user is-active --quiet blockie-frontend.service" || -z ${FAKE_NOFRONTEND:-} ]] || exit 3
[[ "$*" != "--user reset-failed blockie-game.scope" || -z ${FAKE_NORESET:-} ]] || exit 1
exit 0
EOF
cat > "$FAKE/bin/retroarch" << 'EOF'
#!/usr/bin/env bash
main=
a=("$@")
for ((i = 0; i + 1 < ${#a[@]}; i++)); do
  [[ ${a[i]} != --config ]] || main=${a[i + 1]}
done
printf '%s\n' "$*" | sed -E 's#--config [^ ]*/blockie-game\.[A-Za-z0-9]{6}\.main\.cfg( |$)#--config MAIN\1#' > "$FAKE/retroarch.argv"
printf '%s\n' "$main" > "$FAKE/main.path"
cp -- "$main" "$FAKE/main.cfg"
printf '%s\n' "LD_LIBRARY_PATH=${LD_LIBRARY_PATH-unset}" "VK_DRIVER_FILES=${VK_DRIVER_FILES-unset}" \
  "FAKE_GPU_EXTRA=${FAKE_GPU_EXTRA-unset}" > "$FAKE/retroarch.env"
: > "$FAKE/append.cfg"
while (( $# )); do
  if [[ $1 == --appendconfig ]]; then
    IFS='|' read -ra files <<< "$2"
    cat "${files[@]}" > "$FAKE/append.cfg"
  fi
  shift
done
o=$(sed -n 's/^core_options_path = "\(.*\)"$/\1/p' "$FAKE/append.cfg")
[[ -z $o ]] || cp "$o" "$FAKE/core.opt"
if [[ -n ${FAKE_CMD:-} ]]; then
  { stat -L -c '%F %a' /dev/stdin; readlink "/proc/$$/fd/0"; [[ ! -e /proc/$$/fd/3 ]] || echo fd3; } > "$FAKE/stdin"
  stat -L -c %i /dev/stdin > "$FAKE/ino"
  echo "$$" > "$FAKE/pid"
  read -r -t 10 line && printf '%s\n' "$line" > "$FAKE/line"
fi
if [[ -n ${FAKE_SLEEP:-} ]]; then
  trap 'echo term > "$FAKE/term"; [[ -z ${FAKE_SAVE:-} ]] || cat "$FAKE_SAVE" > "$main"; kill "$s"; exit 143' TERM
  sleep 30 &
  s=$!
  echo "$$" > "$FAKE/pid"
  wait
fi
[[ -z ${FAKE_SAVE:-} ]] || cat "$FAKE_SAVE" > "$main"
exit "${FAKE_RC:-0}"
EOF
chmod 755 "$FAKE/bin/systemd-run" "$FAKE/bin/systemctl" "$FAKE/bin/retroarch"

play() {
  rm -f "$FAKE"/*.log "$FAKE/retroarch.argv" "$FAKE/retroarch.env" "$FAKE/append.cfg" "$FAKE/term" "$FAKE/pid" "$FAKE/core.opt"
  rm -f "$FAKE/main.path" "$FAKE/main.cfg"
  rm -f "$FAKE/stdin" "$FAKE/ino" "$FAKE/line"
  PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=${RUN-$t/run} DL1_CARDS=${CARDS:-$t/nocard} "$game" "$@" > "$t/out" 2>&1
  rc=$?
}
ran() { [[ -s $FAKE/systemd-run.log ]]; }
argv() { [[ $(cat "$FAKE/retroarch.argv" 2> /dev/null) == "$1" ]]; }
refused() {
  play "$@"
  [[ $rc == 64 ]] && ! ran
}

scope="--user --scope --quiet --unit=blockie-game --collect --slice=blockie-emulation.slice -p BindsTo=blockie-frontend.service"
scope+=" -p After=blockie-frontend.service -p MemoryHigh=80% -p MemoryMax=90% -p TasksMax=512 -p OOMPolicy=kill"
scope+=" -p TimeoutStopSec=5s --"
base="--config MAIN"
fifo=$t/run/blockie-game.cmd
norm() { sed -E 's#--config [^ ]*/blockie-game\.[A-Za-z0-9]{6}\.main\.cfg #--config MAIN #' "$1"; }
mainis() {
  [[ $(cat "$FAKE/main.cfg") == "$(grep -v '^config_save_on_exit[[:space:]]*=' "$share/blockie.cfg")"$'\nconfig_save_on_exit = "true"\ncore_options_path = "'"$share"'/retroarch-core-options.cfg"'"$1" ]]
}
gone() { local p; p=$(cat "$FAKE/main.path" 2> /dev/null) && [[ $p == "$t/run/blockie-game."??????".main.cfg" && ! -e $p ]]; }

play ps1 "$rom"
[[ $rc == 0 && $(norm "$FAKE/systemd-run.log") == "$scope retroarch $base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom" ]] &&
  [[ ! -e $fifo ]] && mainis '' && gone && [[ ! -s $t/out && ! -e $t/input.cfg ]]
res $? "ps1: one scope in blockie-emulation.slice bound to the frontend, with the limits, RetroArch on pcsx_rearmed, --config a removed copy of blockie.cfg that saves on exit"

cmdplay() {
  rm -f "$FAKE"/*.log "$FAKE/pid" "$FAKE/stdin" "$FAKE/ino" "$FAKE/line"
  FAKE_CMD=1 PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run DL1_CARDS=$t/nocard "$game" gba "$rom" > "$t/out" 2>&1 &
  local w=$!
  for _ in $(seq 50); do
    [[ -s $FAKE/pid ]] && break
    sleep 0.1
  done
  for _ in $(seq 20); do
    [[ -e /proc/$w/fd/3 ]] || break
    sleep 0.1
  done
  [[ ! -e /proc/$w/fd/3 ]]
  wfd=$?
  XDG_RUNTIME_DIR=$t/run timeout 5 "$gcmd" MENU_TOGGLE > "$t/cmd.out" 2>&1
  crc=$?
  wait "$w"
  rc=$?
}
echo 1 > "$t/run/blockie-game.quit"
cmdplay
[[ $rc == 0 && $crc == 0 && $wfd == 0 && ! -s $t/cmd.out && $(cat "$FAKE/stdin") == "fifo 600"$'\n'"$fifo" ]] &&
  [[ $(cat "$FAKE/line" 2> /dev/null) == MENU_TOGGLE && ! -e $fifo && ! -e $t/run/blockie-game.quit ]]
res $? "commands: RetroArch's stdin is the 600 FIFO, fd 3 closed in it and the wrapper, a line arrives, FIFO and quit stamp removed"

mkfifo -m 644 "$fifo"
exec 4<> "$fifo"
planted=$(stat -c %i "$fifo")
cmdplay
line=
read -r -t 1 line <&4
exec 4>&-
[[ $rc == 0 && $(head -n 1 "$FAKE/stdin") == "fifo 600" && $(cat "$FAKE/ino") != "$planted" && -z $line ]] &&
  [[ $(cat "$FAKE/line" 2> /dev/null) == MENU_TOGGLE && ! -e $fifo ]]
res $? "commands: a stale 644 FIFO at the path is replaced by a new 600 one"

declare -A want=([gb]=gambatte [gbc]=gambatte [nes]=nestopia [snes]=snes9x [genesis]=genesis_plus_gx [gba]=mgba
  [ps1]=pcsx_rearmed [n64]=mupen64plus_next [psp]=ppsspp [dc]=flycast)
ok=0
for s in "${!want[@]}"; do
  play "$s" "$rom"
  [[ $rc == 0 && $(cat "$FAKE/retroarch.argv") == *" -L /usr/lib64/libretro/${want[$s]}_libretro.so $rom" ]] ||
    { ok=1; echo "  $s: rc $rc $(cat "$FAKE/retroarch.argv" 2> /dev/null)"; }
done
res $ok "every system starts its default core"

play snes "$rom" --core pcsx_rearmed
[[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom"
res $? "--core overrides the system default"

play ps1 "$data/roms/gba/in.gba"
[[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom"
res $? "a symlink inside the data dir is passed resolved"

play psp "$data/roms/psp/test.iso"
[[ $rc == 0 ]] && argv "$base --appendconfig $share/core/ppsspp.cfg -L /usr/lib64/libretro/ppsspp_libretro.so $data/roms/psp/test.iso" &&
  [[ $(cat "$FAKE/append.cfg") == 'system_directory = "/usr/share/libretro/ppsspp"' ]]
res $? "psp: the ppsspp core config points system_directory at the PPSSPP assets"

[[ -f /usr/share/libretro/ppsspp/PPSSPP/compat.ini ]]
res $? "the ppsspp system directory holds PPSSPP/compat.ini"

n64cfg=$share/core/mupen64plus_next.cfg
here_schema=/usr/share/blockie/schema.d/30-buttons.json
play n64 "$data/roms/n64/test.z64"
[[ $rc == 0 ]] &&
  argv "$base --appendconfig $n64cfg -L /usr/lib64/libretro/mupen64plus_next_libretro.so $data/roms/n64/test.z64" &&
  [[ $(cat "$FAKE/append.cfg") == "$(printf '%s\n' 'input_player1_l_x_plus_btn = "h0right"' \
    'input_player1_l_x_minus_btn = "h0left"' 'input_player1_l_y_plus_btn = "h0down"' 'input_player1_l_y_minus_btn = "h0up"' \
    'input_analog_deadzone = "0.1"' 'system_directory = "/var/lib/blockie/data/mupen64plus_next"')" ]]
res $? "n64: the mupen core config binds the hat to the left stick, a deadzone over the rest value, its own system_directory"

ok=0
auto="$share/autoconfig/udev/AYANEO Controller.cfg"
for d in up:l_y_minus down:l_y_plus left:l_x_minus right:l_x_plus; do
  hat=$(sed -n "s/^input_${d%%:*}_btn = \"\(h0[a-z]*\)\"$/\1/p" "$auto")
  [[ -n $hat ]] && grep -qxF "input_player1_${d#*:}_btn = \"$hat\"" "$n64cfg" || { ok=1; echo "  ${d%%:*}: '$hat'"; }
done
res $ok "n64: each stick direction is bound to the hat direction the autoconfig binds to that D-pad direction"

sd=$(sed -n 's/^system_directory = "\(.*\)"$/\1/p' "$n64cfg")
[[ $sd == "$data"/* ]] && grep -qxF "d $sd 0755 blockie blockie -" /usr/lib/blockie/data-tmpfiles.conf
res $? "n64: the data tmpfiles make the mupen system_directory, owned by blockie"

ok=0
for c in 0 1 139; do
  FAKE_RC=$c play gba "$rom"
  [[ $rc == "$c" ]] || { ok=1; echo "  retroarch $c: wrapper $rc"; }
done
for c in 64 69 71 75; do
  FAKE_RC=$c play gba "$rom"
  [[ $rc == 70 ]] || { ok=1; echo "  retroarch $c: wrapper $rc"; }
done
res $ok "RetroArch's exit passes through, 64, 69, 71 and 75 become 70"

ok=0
refused || ok=1
refused gba || ok=1
refused gba "$rom" extra || ok=1
refused gba "$rom" --core || ok=1
refused gba "$rom" --core mgba --core mgba || ok=1
refused gba "$rom" --config || ok=1
refused nds "$rom" || ok=1
refused 'gba;x' "$rom" || ok=1
refused gba "$rom" --core desmume || ok=1
refused gba "$rom" --core '../mgba' || ok=1
refused gba "$rom" --core '' || ok=1
res $ok "bad arguments, systems and cores exit 64 before anything starts"

ok=0
refused gba roms/gba/test.gba || ok=1
refused gba "$data/roms/gba/none.gba" || ok=1
refused gba /etc/passwd || ok=1
refused gba "$data/roms/gba/out.gba" || ok=1
refused gba "$data/../../../../etc/passwd" || ok=1
refused gba "$data/roms/dir" || ok=1
refused gba "$data" || ok=1
refused gba "$data/roms/gba/te"$'\n'"st.gba" || ok=1
res $ok "rompaths: relative, missing, outside, a symlink out, a .. escape, a directory, control characters exit 64"

cfg() {
  printf '%s\n' "$@" > "$t/game.cfg"
  play ps1 "$rom" --config "$t/game.cfg"
}
cfg 'aspect_ratio_index = "22"' '' 'video_scale_integer = "true"' 'video_shader_enable = "true"' \
  'video_shader = "/usr/share/libretro/shaders/crt/../crt/test.glslp"' 'video_smooth="false"' 'rewind_enable = "true"' \
  'savestate_auto_save = "false"' 'savestate_auto_load = "true"' $'fastforward_ratio = "4.0"\r'
exp=$(printf '%s\n' 'aspect_ratio_index = "22"' 'video_scale_integer = "true"' 'video_shader_enable = "true"' \
  'video_smooth = "false"' 'rewind_enable = "true"' \
  'savestate_auto_save = "false"' 'savestate_auto_load = "true"' 'fastforward_ratio = "4.0"')
app=$(sed -n 's/.* --appendconfig \([^ ]*\) .*/\1/p' "$FAKE/retroarch.argv")
[[ $rc == 0 && $(cat "$FAKE/append.cfg") == "$exp" && $app == "$t/run/blockie-game."*.cfg && ! -e $app ]] &&
  [[ $(cat "$FAKE/retroarch.argv") == *" --set-shader /usr/share/libretro/shaders/crt/test.glslp -L "* ]]
res $? "config: allowed keys pass as a checked copy removed after the game, the shader resolved as --set-shader"

ok=0
for v in 0 9 10 22 24; do
  cfg "aspect_ratio_index = \"$v\""
  [[ $rc == 0 && $(cat "$FAKE/append.cfg") == "aspect_ratio_index = \"$v\"" ]] || { ok=1; echo "  aspect $v: rc $rc"; }
done
res $ok "config: aspect_ratio_index 0 to 22 and 24 pass"

cfg '' '   '
[[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom"
res $? "config: blank lines only, no --appendconfig"

printf 'rewind_enable = "true"\n' > "$t/game.cfg"
play psp "$data/roms/psp/test.iso" --config "$t/game.cfg"
[[ $rc == 0 && $(cat "$FAKE/retroarch.argv") == "$base --appendconfig $share/core/ppsspp.cfg|$t/run/blockie-game."*".cfg -L "* ]]
res $? "config with psp: the core config first, then the game config"

ok=0
for bad in 'savefile_directory = "/tmp"' 'system_directory = "/tmp"' 'video_driver = "gl"' 'libretro_directory = "/tmp"' \
  '# comment' 'rewind_enable = true' 'rewind_enable = "yes"' 'aspect_ratio_index = "-1"' 'aspect_ratio_index = "123"' \
  'aspect_ratio_index = "23"' 'aspect_ratio_index = "25"' 'aspect_ratio_index = "99"' 'aspect_ratio_index = "08"' \
  'video_shader = "/usr/share/libretro/shaders/crt/test.slangp"' \
  "video_shader = \"$t/outside.glslp\"" 'video_shader = "/usr/share/libretro/shaders/crt/out.glslp"' \
  'fastforward_ratio = "fast"' 'fastforward_ratio = "1e9"' 'video_shader = "/etc/passwd"' \
  'video_shader = "/usr/share/libretro/shaders/none.slangp"' 'video_shader = "/usr/share/libretro/shaders/crt"' \
  'video_shader = "/usr/share/libretro/shaders/../../../../etc/passwd"' 'rewind_enable = "true" x' \
  'Rewind_enable = "true"' 'video_smooth = "a"b"'; do
  cfg "$bad"
  [[ $rc == 64 ]] && ! ran || { ok=1; echo "  accepted: $bad (rc $rc)"; }
done
cfg 'rewind_enable = "true"' 'rewind_enable = "false"'
[[ $rc == 64 ]] && ! ran || { ok=1; echo "  accepted a key twice"; }
refused gba "$rom" --config "$t/none.cfg" || ok=1
refused gba "$rom" --config "$t" || ok=1
head -c 70000 /dev/zero | tr '\0' '\n' > "$t/big.cfg"
refused gba "$rom" --config "$t/big.cfg" || ok=1
res $ok "config: other keys, comments, bad values, shaders outside the dir, a key twice, missing or huge files exit 64"

D=/usr/share/libretro/shaders/crt/test.glslp
G=/usr/share/libretro/shaders/crt/game.glslp
S=/var/lib/blockie/shaders/test.slangp
defs() {
  : > "$share/shader-defaults"
  (( ! $# )) || printf '%s\n' "$@" > "$share/shader-defaults"
}
sets() { [[ $(cat "$FAKE/retroarch.argv") == *" --set-shader $1 -L "* ]]; }
noset() { [[ $(cat "$FAKE/retroarch.argv") != *--set-shader* ]]; }
appended() { [[ $(cat "$FAKE/append.cfg") == "$(printf '%s\n' "$@")" ]]; }
noappend() { [[ $(cat "$FAKE/retroarch.argv") != *--appendconfig* ]]; }
logged() { [[ $(wc -l < "$t/out") == "$1" ]] && grep -q -- "$2" "$t/out"; }
cell() {
  local sys=$1 sh=$2 en=$3 conf=$4 shader=$5 l=() e=()
  if [[ $conf == 1 ]]; then
    l=('rewind_enable = "true"')
    [[ -z $sh ]] || l+=("video_shader = \"$sh\"")
    [[ -z $en ]] || l+=("video_shader_enable = \"$en\"")
    printf '%s\n' "${l[@]}" > "$t/game.cfg"
    play "$sys" "$rom" --config "$t/game.cfg"
    e=('rewind_enable = "true"')
    [[ -z $en ]] || e+=("video_shader_enable = \"$en\"")
  else
    play "$sys" "$rom"
  fi
  [[ -z $shader || $en == true ]] || e+=('video_shader_enable = "true"')
  [[ $rc == 0 && ! -s $t/out ]] && appended "${e[@]}" || return 1
  (( ${#e[@]} )) || noappend || return 1
  if [[ -n $shader ]]; then sets "$shader"; else noset; fi
}

defs "nes $D"
ok=0
cell nes '' '' 0 "$D" || { ok=1; echo "  nes: no config"; }
for en in '' true false; do
  w=$D
  [[ $en != false ]] || w=
  cell nes '' "$en" 1 "$w" || { ok=1; echo "  nes: no video_shader, video_shader_enable '$en'"; }
  w=$G
  [[ $en != false ]] || w=
  cell nes "$G" "$en" 1 "$w" || { ok=1; echo "  nes: video_shader, video_shader_enable '$en'"; }
done
play nes "$rom" --core snes9x
[[ $rc == 0 ]] && sets "$D" || { ok=1; echo "  nes --core snes9x: no default"; }
res $ok "shader, nes with a default: the game's video_shader, else the default, video_shader_enable true once, none on false"

ok=0
cell snes '' '' 0 '' || { ok=1; echo "  snes: no config"; }
for en in '' true false; do
  cell snes '' "$en" 1 '' || { ok=1; echo "  snes: no video_shader, video_shader_enable '$en'"; }
  w=$G
  [[ $en != false ]] || w=
  cell snes "$G" "$en" 1 "$w" || { ok=1; echo "  snes: video_shader, video_shader_enable '$en'"; }
done
res $ok "shader, snes without a default: only the game's video_shader, no run append file without lines"

defs "nes /usr/share/libretro/shaders/crt/none.glslp"
play nes "$rom"
[[ $rc == 0 ]] && noset && noappend && logged 1 'shader-defaults line 1: /usr/share/libretro/shaders/crt/none.glslp is not'
res $? "shader: a missing default is skipped with one log line, the game starts"

ok=0
for p in /usr/share/libretro/shaders/crt/test.slangp /usr/share/libretro/shaders/crt/out.glslp /usr/share/libretro/shaders/crt \
  /usr/share/libretro/shaders/crt/test.glsl /var/lib/blockie/shaders/test.glslp /var/lib/blockie/shaders/../shaders \
  /etc/passwd "$t/outside.glslp"; do
  defs "nes $p"
  play nes "$rom"
  [[ $rc == 0 ]] && noset && noappend && logged 1 'shader-defaults line 1: .* skipped' || { ok=1; echo "  default $p: rc $rc"; }
done
res $ok "shader: a default that is not a .glslp under the shaders dir or a .slangp under the slang dir is skipped"

defs 'nes' "nes $D extra" "nds $D" 'nes crt/test.glslp' "Nes $D" '' "snes $D"
play snes "$rom"
[[ $rc == 0 ]] && sets "$D" && [[ $(grep -c 'is not <system> <absolute path>, skipped' "$t/out") == 5 && $(wc -l < "$t/out") == 5 ]]
r1=$?
play nes "$rom"
[[ $r1 == 0 && $rc == 0 ]] && noset && noappend && logged 5 'shader-defaults line 4 is not'
res $? "shader: malformed lines (fields, unknown system, relative path) are skipped with a log line each"

defs "nes $D" "nes $G"
play nes "$rom"
[[ $rc == 0 ]] && sets "$D" && logged 1 'shader-defaults line 2 sets nes again, skipped'
res $? "shader: the first line for a system wins"

defs "nes $S"
ok=0
play nes "$rom"
[[ $rc == 0 ]] && sets "$S" && appended 'video_shader_enable = "true"' 'video_driver = "glcore"' || { ok=1; echo "  slangp default"; }
printf '%s\n' 'video_shader_enable = "false"' > "$t/game.cfg"
play nes "$rom" --config "$t/game.cfg"
[[ $rc == 0 ]] && noset && appended 'video_shader_enable = "false"' || { ok=1; echo "  slangp default, game false"; }
printf '%s\n' "video_shader = \"$G\"" > "$t/game.cfg"
play nes "$rom" --config "$t/game.cfg"
[[ $rc == 0 ]] && sets "$G" && appended 'video_shader_enable = "true"' || { ok=1; echo "  slangp default, game shader"; }
res $ok "shader: a .slangp default under /var/lib/blockie/shaders runs on glcore, only when it is the shader"

defs
ok=0
for sc in gb:gambatte gbc:gambatte gba:mgba snes:gambatte; do
  s=${sc%%:*}
  c=${sc#*:}
  if [[ $s == snes ]]; then play snes "$rom" --core gambatte; else play "$s" "$rom"; fi
  app=$(sed -n 's/.* --appendconfig \([^ ]*\) .*/\1/p' "$FAKE/retroarch.argv")
  o=$(sed -n 's/^core_options_path = "\(.*\)"$/\1/p' "$FAKE/append.cfg")
  [[ $rc == 0 && $o == "$t/run/blockie-game."*.opt && $app == "$t/run/blockie-game."*.cfg && ! -e $o && ! -e $app ]] &&
    appended 'global_core_options = "true"' "core_options_path = \"$o\"" && cmp -s "$FAKE/core.opt" "$share/core/$c.opt" ||
    { ok=1; echo "  $s on $c: rc $rc"; }
done
for sc in gb:pcsx_rearmed gba:snes9x; do
  play "${sc%%:*}" "$rom" --core "${sc#*:}"
  [[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/${sc#*:}_libretro.so $rom" || { ok=1; echo "  ${sc%%:*} on ${sc#*:}: options"; }
done
[[ -z $(find "$t/run" -name 'blockie-game.*.opt') ]] || ok=1
play ps1 "$rom"
[[ $rc == 0 ]] && mainis '' || { ok=1; echo "  ps1: the --config does not pin core_options_path"; }
res $ok "core options: a shipped <core>.opt is copied for the run as global core options and removed, none for other cores, whose fallback stays pinned to $share/retroarch-core-options.cfg in the --config"

defs "gb $D"
play gb "$rom"
o=$(sed -n 's/^core_options_path = "\(.*\)"$/\1/p' "$FAKE/append.cfg")
[[ $rc == 0 && -n $o ]] && sets "$D" &&
  appended 'video_shader_enable = "true"' 'global_core_options = "true"' "core_options_path = \"$o\""
res $? "shader and core options: the shader line, then the two option lines"
defs

ok=0
for v in dark light; do
  play ps1 "$rom" --theme "$v"
  [[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom" || { ok=1; echo "  theme $v: rc $rc"; }
done
res $ok "theme: --theme dark and light start the game, no run append file without a preset"

ok=0
refused ps1 "$rom" --theme || ok=1
refused ps1 "$rom" --theme dark --theme dark || ok=1
for v in '' blue Dark 'dark;x' ../dark; do
  refused ps1 "$rom" --theme "$v" || { ok=1; echo "  theme '$v': rc $rc"; }
done
refused ps1 "$rom" --theme blue && grep -qxF 'blockie-game: unknown theme blue' "$t/out" || { ok=1; echo "  no unknown theme line"; }
play ps1
[[ $rc == 64 ]] && grep -qxF 'usage: blockie-game <system> <rompath> [--core <id>] [--config <file>] [--theme dark|light]' "$t/out" ||
  { ok=1; echo "  usage: $(cat "$t/out")"; }
res $ok "theme: a missing, repeated or unknown --theme exits 64 before anything starts, usage lists --theme"

preset() { appended "rgui_menu_theme_preset = \"$share/rgui/$1.cfg\""; }
mkdir "$share/rgui"
printf 'invented preset\n' > "$share/rgui/dark.cfg"
ok=0
play ps1 "$rom"
[[ $rc == 0 ]] && preset dark || { ok=1; echo "  no --theme: rc $rc"; }
play ps1 "$rom" --theme dark
[[ $rc == 0 ]] && preset dark || { ok=1; echo "  dark: rc $rc"; }
play ps1 "$rom" --theme light
[[ $rc == 0 ]] && noappend || { ok=1; echo "  light without light.cfg: rc $rc"; }
printf 'invented preset\n' > "$share/rgui/light.cfg"
play ps1 "$rom" --theme light
[[ $rc == 0 ]] && preset light || { ok=1; echo "  light: rc $rc"; }
rm -rf "${share:?}/rgui"
res $ok "theme: the run append file names rgui/<theme>.cfg only when it exists, dark without --theme"

placed() {
  play ps1 "$rom" "$@"
  [[ $rc == 0 && $(cat "$FAKE/retroarch.argv") == *" -L /usr/lib64/libretro/snes9x_libretro.so $rom" ]] &&
    appended 'rewind_enable = "true"' "rgui_menu_theme_preset = \"$share/rgui/light.cfg\""
}
mkdir "$share/rgui"
printf 'invented preset\n' > "$share/rgui/light.cfg"
printf 'rewind_enable = "true"\n' > "$t/game.cfg"
ok=0
placed --theme light --core snes9x --config "$t/game.cfg" || { ok=1; echo "  --theme first: rc $rc"; }
placed --core snes9x --theme light --config "$t/game.cfg" || { ok=1; echo "  --theme between: rc $rc"; }
placed --core snes9x --config "$t/game.cfg" --theme light || { ok=1; echo "  --theme last: rc $rc"; }
refused ps1 "$rom" --theme light --core snes9x --theme light || ok=1
refused --theme light ps1 "$rom" || ok=1
rm -rf "${share:?}/rgui"
res $ok "theme: --theme before, between or after --core and --config takes effect, a second one or one before the positionals exits 64"

mv /usr/lib64/libretro/mgba_libretro.so "$t/mgba.so"
play gba "$rom"
[[ $rc == 69 ]] && ! ran
res $? "a core that is not installed exits 69 before anything starts"
mv "$t/mgba.so" /usr/lib64/libretro/mgba_libretro.so

mkfifo -m 600 "$fifo"
exec 4<> "$fifo"
planted=$(stat -c %i "$fifo")
echo 1 > "$t/run/blockie-game.quit"
flock -o "$t/run/blockie-game.lock" sleep 5 &
holder=$!
sleep 0.5
play gba "$rom"
[[ $rc == 75 ]] && ! ran && [[ -p $fifo && $(stat -c %i "$fifo") == "$planted" && -e $t/run/blockie-game.quit ]]
res $? "a held lock exits 75, starts nothing and leaves the running game's FIFO and quit stamp"
exec 4>&-
rm -f "$fifo" "$t/run/blockie-game.quit"
kill "$holder" 2> /dev/null
wait "$holder" 2> /dev/null

queries() { grep -cxF -- '--user show -P ActiveState blockie-game.scope' "$FAKE/systemctl.log"; }
shows() { [[ $(queries) == "$1" ]]; }
ok=0
for s in active activating reloading; do
  FAKE_STATE=$s play gba "$rom"
  [[ $rc == 75 ]] && ! ran && shows 1 || { ok=1; echo "  $s: rc $rc"; }
done
res $ok "a scope still active, starting or reloading exits 75 at once"

ok=0
FAKE_STATE='deactivating deactivating inactive' play gba "$rom"
[[ $rc == 0 ]] && ran && shows 3 || { ok=1; echo "  deactivating, inactive: rc $rc"; }
FAKE_STATE='deactivating failed' play gba "$rom"
[[ $rc == 0 ]] && ran && shows 2 && grep -qx -- '--user reset-failed blockie-game.scope' "$FAKE/systemctl.log" ||
  { ok=1; echo "  deactivating, failed: rc $rc"; }
FAKE_STATE='deactivating active' play gba "$rom"
[[ $rc == 75 ]] && ! ran && shows 2 && grep -q 'blockie-game.scope is active' "$t/out" ||
  { ok=1; echo "  deactivating, active: rc $rc"; }
t0=$(date +%s%N)
FAKE_STATE=deactivating play gba "$rom"
ms=$((($(date +%s%N) - t0) / 1000000))
n=$(queries)
[[ $rc == 75 ]] && ! ran && (( n >= 3 && n <= 11 && ms >= 400 && ms <= 5000 )) &&
  grep -q 'blockie-game.scope is deactivating' "$t/out" || { ok=1; echo "  deactivating: rc $rc, $n queries in $ms ms"; }
res $ok "a stopping scope is polled every 50 ms for 500 ms: inactive or failed starts the game, active or still stopping exits 75"

FAKE_NOFRONTEND=1 play gba "$rom"
[[ $rc == 75 ]] && ! ran && grep -q 'frontend not active' "$t/out"
res $? "frontend not active exits 75 and starts nothing"

FAKE_STATE=failed play gba "$rom"
[[ $rc == 0 ]] && ran && grep -qx -- '--user reset-failed blockie-game.scope' "$FAKE/systemctl.log"
res $? "a failed scope is reset, then the game starts"

FAKE_NORESET=1 FAKE_STATE=failed play gba "$rom"
[[ $rc == 75 ]] && ! ran && shows 2 && grep -q 'cannot reset blockie-game.scope' "$t/out"
r1=$?
FAKE_NORESET=1 FAKE_STATE='failed inactive' play gba "$rom"
[[ $r1 == 0 && $rc == 0 ]] && ran && shows 2
res $? "a failed reset reads the scope again: still failed exits 75 and starts nothing, collected meanwhile starts the game"

printf ' 0 [mt6768mt6358   ]: mt6768mt6358 - mt6768-mt6358\n' > "$t/card"
CARDS=$t/card play gba "$rom"
[[ $rc == 71 ]] && ! ran
res $? "a failed DL1 check exits 71 before RetroArch starts"

ok=0
RUN='' play gba "$rom"
[[ $rc == 70 ]] && ! ran || ok=1
RUN="$t/r\"un" play gba "$rom"
[[ $rc == 70 ]] && ! ran || ok=1
res $ok "no XDG_RUNTIME_DIR, or one with a quote, exits 70"

mkdir -p /run/blockie-gpu
printf '%s\n' LD_LIBRARY_PATH=/invented/farm VK_DRIVER_FILES=/invented/icd.json FAKE_GPU_EXTRA=x > /run/blockie-gpu/gpu.env
LD_LIBRARY_PATH=/stale play gba "$rom"
[[ $rc == 0 && $(cat "$FAKE/retroarch.env") == $'LD_LIBRARY_PATH=/invented/farm\nVK_DRIVER_FILES=/invented/icd.json\nFAKE_GPU_EXTRA=unset' ]]
res $? "gpu.env: LD_LIBRARY_PATH and VK_DRIVER_FILES exported, other keys ignored"
rm -rf /run/blockie-gpu

rm -f "$FAKE"/*.log "$FAKE/term" "$FAKE/pid"
FAKE_SLEEP=1 PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run DL1_CARDS=$t/nocard "$game" gba "$rom" > "$t/out" 2>&1 &
w=$!
for _ in $(seq 50); do
  [[ -s $FAKE/pid ]] && break
  sleep 0.1
done
[[ -p $fifo ]]
during=$?
kill -TERM "$w"
wait "$w"
rc=$?
[[ $rc == 143 && -e $FAKE/term && $during == 0 && ! -e $fifo ]] && grep -qx -- '--user stop blockie-game.scope' "$FAKE/systemctl.log"
res $? "TERM on the wrapper stops RetroArch and the scope, removes the FIFO, then exits 143"

rm -f "$FAKE"/*.log "$FAKE/term" "$FAKE/pid"
FAKE_SLEEP=1 PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run DL1_CARDS=$t/nocard "$game" gba "$rom" > "$t/out" 2>&1 &
w=$!
for _ in $(seq 50); do
  [[ -s $FAKE/pid ]] && break
  sleep 0.1
done
gp=$(cat "$FAKE/pid" 2> /dev/null)
kill -STOP "$gp"
sleep 1
[[ $(sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$gp/status" 2> /dev/null) == T ]] && kill -0 "$w" 2> /dev/null
during=$?
kill -CONT "$gp"
sleep 0.5
kill -0 "$w" 2> /dev/null
cont=$?
kill -TERM "$gp"
wait "$w"
rc=$?
[[ $during == 0 && $cont == 0 && $rc == 143 && -e $FAKE/term ]]
res $? "a RetroArch stopped by SIGSTOP (as blank-on sends) keeps the wrapper waiting; after SIGCONT it runs on and its exit is the wrapper's"

rm -f "$FAKE"/*.log "$FAKE/term" "$FAKE/pid" "$FAKE/append.cfg" "$FAKE/core.opt"
FAKE_SLEEP=1 PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run DL1_CARDS=$t/nocard "$game" gb "$rom" > "$t/out" 2>&1 &
w=$!
for _ in $(seq 50); do
  [[ -s $FAKE/pid ]] && break
  sleep 0.1
done
o=$(sed -n 's/^core_options_path = "\(.*\)"$/\1/p' "$FAKE/append.cfg")
app=$(sed -n 's/.* --appendconfig \([^ ]*\) .*/\1/p' "$FAKE/retroarch.argv")
[[ -n $o && -f $o && -f $app ]]
during=$?
kill -TERM "$w"
wait "$w"
rc=$?
[[ $rc == 143 && $during == 0 && ! -e $o && ! -e $app ]] && cmp -s "$FAKE/core.opt" "$share/core/gambatte.opt"
res $? "TERM: the core options copy and the run append file are removed"

inp() { printf '%s\n' "$@" > "$t/input.cfg"; }
saved() { printf '%s\n' "$@" > "$t/saved.cfg"; }
inis() { [[ $(cat "$t/input.cfg") == "$(printf '%s\n' "$@")" ]]; }

bmap
inp 'input_screenshot = "f14"' 'input_player1_l3_btn = "10"'
cp "$t/input.cfg" "$t/input.before"
play ps1 "$rom"
[[ $rc == 0 && ! -s $t/out ]] && argv "$base -L /usr/lib64/libretro/pcsx_rearmed_libretro.so $rom" && gone &&
  mainis $'\ninput_player1_l3_btn = "10"\ninput_screenshot = "f14"' && cmp -s "$t/input.cfg" "$t/input.before"
res $? "binds: the input.cfg binds of free buttons go at the end of the throwaway --config, input.cfg byte equal when RetroArch saved nothing"

ok=0
inp 'input_screenshot = "f13"' 'input_rewind = "f14"' 'input_reset = "f15"' 'input_pause_toggle_btn = "10"'
cp "$t/input.cfg" "$t/input.before"
play gba "$rom"
[[ $rc == 0 ]] && mainis $'\ninput_pause_toggle_btn = "10"\ninput_rewind = "f14"' && cmp -s "$t/input.cfg" "$t/input.before" &&
  grep -q 'masked while their button has a Blockie action: .*input_reset' "$t/out" &&
  grep -q 'masked while their button has a Blockie action: .*input_screenshot' "$t/out" || { ok=1; echo "  shipped map"; }
bmap home.hold=none extra1.hold=switcher extra3.tap=none extra2.hold=game-quit extra3.hold=none
play gba "$rom"
[[ $rc == 0 ]] && mainis $'\ninput_reset = "f15"\ninput_screenshot = "f13"' && cmp -s "$t/input.cfg" "$t/input.before" ||
  { ok=1; echo "  moved map"; }
expect=$(python3 - "$here_schema" << 'EOF'
import json
import sys

keys = json.load(open(sys.argv[1]))["keys"]
free = {b: keys[f"buttons.{b}.tap"]["default"] == keys[f"buttons.{b}.hold"]["default"] == "none"
        for b in ("home", "extra1", "extra2", "extra3")}
lines = {"extra1": 'input_pause_toggle_btn = "10"', "extra2": 'input_rewind = "f14"', "extra3": 'input_reset = "f15"',
         "home": 'input_screenshot = "f13"'}
print("".join("\n" + lines[b] for b in sorted(lines, key=lambda b: lines[b]) if free[b]), end="")
EOF
)
for c in none short; do
  if [[ $c == none ]]; then rm -f "$t/buttons"; else bmap; sed -i '$d' "$t/buttons"; fi
  play gba "$rom"
  [[ $rc == 0 && -n $expect ]] && mainis "$expect" &&
    grep -qE "(no $t/buttons|$t/buttons is not the 13 line button map), the built in button defaults apply" "$t/out" ||
    { ok=1; echo "  $c map: $(paste -sd '|' "$t/out")"; }
done
w=$(sed -n "s/^ *w='(\(.*\))'\$/\1/p" "$game")
[[ -n $w && $w == "$(python3 -c 'import json, sys; print("|".join(json.load(open(sys.argv[1]))["keys"]["buttons.home.tap"]["enum"]))' "$here_schema")" ]] &&
  python3 -c 'import json, sys; k = json.load(open(sys.argv[1]))["keys"]; sys.exit(len({tuple(v["enum"]) for v in k.values()}) != 1)' "$here_schema" ||
  { ok=1; echo "  the map words '$w' differ from 30-buttons.json's enum"; }
bmap
res $ok "masking: a bind on a button with a Blockie action stays in input.cfg and out of the launch; no map or a short one gives the built in defaults, which equal 30-buttons.json, and the map words equal its enum"

ok=0
inp 'input_screenshot = "f14"' 'input_rewind = "f13"'
saved 'video_driver = "gl"' 'input_hold_fast_forward = "f14"' 'input_screenshot = "nul"' 'input_rewind = "r"' \
  'input_player1_l3_btn = "10"' "video_shader = \"$D\"" "rgui_menu_theme_preset = \"$share/rgui/dark.cfg\"" \
  "core_options_path = \"$t/run/blockie-game.abcdef.opt\"" 'input_exit_emulator = "f15"'
FAKE_SAVE=$t/saved.cfg play gba "$rom"
[[ $rc == 0 ]] && gone && inis 'input_exit_emulator = "f15"' 'input_hold_fast_forward = "f14"' 'input_player1_l3_btn = "10"' \
  'input_rewind = "f13"' && [[ $(stat -c %a "$t/input.cfg") == 644 ]] && grep -q "$t/input.cfg: 4 binds kept" "$t/out" &&
  [[ -z $(find "$t" -maxdepth 1 -name '.input.cfg.*') ]] || { ok=1; echo "  harvest: $(paste -sd '|' "$t/input.cfg")"; }
cp "$t/input.cfg" "$t/input.before"
saved 'video_driver = "gl"' 'input_hold_fast_forward = "f14"'
FAKE_SAVE=$t/saved.cfg play gba "$rom"
[[ $rc == 0 ]] && cmp -s "$t/input.cfg" "$t/input.before" && ! grep -q 'binds kept' "$t/out" ||
  { ok=1; echo "  a save that changes no bind rewrote input.cfg"; }
rm -f "$t/input.cfg"
saved 'video_driver = "gl"' 'input_hold_fast_forward = "r"'
FAKE_SAVE=$t/saved.cfg play gba "$rom"
[[ $rc == 0 && ! -e $t/input.cfg ]] || { ok=1; echo "  a save with no bind made input.cfg"; }
res $ok "harvest: a saved button code is stored, a saved other value drops an applied entry, a masked entry stays, nothing else reaches input.cfg (0644, atomic, unchanged when equal)"

ok=0
inp 'input_driver = "udev"' 'input_player1_nope = "f13"' 'input_screenshot = "f12"' '' 'input_player1_a_btn = "9"' \
  'input_screenshot_btn = "10"' 'input_rewind = f14' 'input_reset  =  "f14"'
cp "$t/input.cfg" "$t/input.before"
play gba "$rom"
[[ $rc == 0 ]] && mainis $'\ninput_screenshot_btn = "10"' && cmp -s "$t/input.cfg" "$t/input.before" &&
  [[ $(grep -c 'is not a bind on a Blockie button, skipped' "$t/out") == 6 ]] && grep -q 'input.cfg line 5 is not' "$t/out" ||
  { ok=1; echo "  launch: $(paste -sd '|' "$t/out")"; }
saved 'input_screenshot_btn = "10"' 'input_player1_a_btn = "9"' 'input_driver = "udev"' 'input_player1_nope = "f13"'
FAKE_SAVE=$t/saved.cfg play gba "$rom"
[[ $rc == 0 ]] && inis 'input_screenshot_btn = "10"' || { ok=1; echo "  harvest: $(paste -sd '|' "$t/input.cfg")"; }
head -c 70000 /dev/zero | tr '\0' '\n' > "$t/input.cfg"
cp "$t/input.cfg" "$t/input.before"
saved 'input_screenshot = "f14"'
FAKE_SAVE=$t/saved.cfg play gba "$rom"
[[ $rc == 0 ]] && cmp -s "$t/input.cfg" "$t/input.before" && grep -q 'not used and not written' "$t/out" ||
  { ok=1; echo "  huge input.cfg"; }
res $ok "grammar: lines that are not a bind key, name an unknown bind or hold another value are skipped at launch, logged, and dropped at harvest; an input.cfg over 64 KiB is neither used nor written"

ok=0
inp 'input_player1_l_x_plus_btn = "10"' 'input_screenshot = "f14"'
play n64 "$data/roms/n64/test.z64"
[[ $rc == 0 ]] && argv "$base --appendconfig $n64cfg -L /usr/lib64/libretro/mupen64plus_next_libretro.so $data/roms/n64/test.z64" &&
  mainis $'\ninput_player1_l_x_plus_btn = "10"\ninput_screenshot = "f14"' &&
  grep -qxF 'input_player1_l_x_plus_btn = "h0right"' "$FAKE/append.cfg" || { ok=1; echo "  n64 launch"; }
saved 'input_player1_l_x_plus_btn = "h0right"' 'input_screenshot = "nul"'
FAKE_SAVE=$t/saved.cfg play n64 "$data/roms/n64/test.z64"
[[ $rc == 0 ]] && inis 'input_player1_l_x_plus_btn = "10"' || { ok=1; echo "  n64 harvest: $(paste -sd '|' "$t/input.cfg")"; }
res $ok "n64: a stored stick bind sits in the --config under the appended core config, whose D-pad stick line wins; a save showing the core's value keeps it"

ok=0
for c in term truncated plain; do
  inp 'input_screenshot = "f14"' 'input_player1_l3_btn = "10"'
  cp "$t/input.cfg" "$t/input.before"
  case $c in
    term) saved 'input_hold_fast_forward = "f14"' 'input_screenshot = "nul"' ;;
    truncated) { printf '%s\n' 'video_driver = "gl"' 'input_hold_fast_forward = "f14"'; printf 'input_player1_l3_btn = "nu'; } > "$t/saved.cfg" ;;
  esac
  rm -f "$FAKE"/*.log "$FAKE/term" "$FAKE/pid" "$FAKE/main.path"
  if [[ $c == plain ]]; then unset FAKE_SAVE; else export FAKE_SAVE=$t/saved.cfg; fi
  FAKE_SLEEP=1 PATH=$FAKE/bin:$PATH XDG_RUNTIME_DIR=$t/run DL1_CARDS=$t/nocard "$game" gba "$rom" > "$t/out" 2>&1 &
  w=$!
  for _ in $(seq 50); do
    [[ -s $FAKE/pid ]] && break
    sleep 0.1
  done
  kill -TERM "$w"
  wait "$w"
  rc=$?
  unset FAKE_SAVE
  [[ $rc == 143 && -e $FAKE/term ]] && gone || { ok=1; echo "  $c: rc $rc"; }
  case $c in
    term) inis 'input_hold_fast_forward = "f14"' 'input_player1_l3_btn = "10"' || { ok=1; echo "  term: $(paste -sd '|' "$t/input.cfg")"; } ;;
    truncated) inis 'input_hold_fast_forward = "f14"' 'input_player1_l3_btn = "10"' 'input_screenshot = "f14"' ||
      { ok=1; echo "  truncated: $(paste -sd '|' "$t/input.cfg")"; } ;;
    plain) cmp -s "$t/input.cfg" "$t/input.before" || { ok=1; echo "  plain TERM changed input.cfg"; } ;;
  esac
done
cfg 'input_screenshot = "f13"'
[[ $rc == 64 ]] && ! ran || { ok=1; echo "  a game config with an input_ key was accepted"; }
rm -f "$t/input.cfg"
[[ -z $(find "$t/run" -name 'blockie-game.*.main.cfg') ]] || { ok=1; echo "  a throwaway --config is left"; }
res $ok "stops: after TERM the harvest runs on what RetroArch saved, a truncated save drops nothing, no save leaves input.cfg byte equal, the throwaway is removed; a game --config still refuses input_ keys"

cfgv() { sed -n "s/^$1 = \"\(.*\)\"$/\1/p" "$share/blockie.cfg"; }
ok=0
for kv in video_driver=gl video_context_driver=wayland input_driver=udev input_joypad_driver=udev stdin_cmd_enable=true \
  quit_press_twice=false quit_on_close_content=2 load_dummy_on_core_shutdown=false auto_overrides_enable=false \
  auto_remaps_enable=false remap_save_on_exit=false auto_shaders_enable=false game_specific_options=false \
  savefile_directory=$data/saves autosave_interval=60 savestate_directory=$data/states system_directory=$data/bios \
  libretro_directory=/usr/lib64/libretro libretro_info_path=/usr/share/libretro/info audio_driver=pipewire \
  config_save_on_exit=false joypad_autoconfig_dir=$share/autoconfig input_autodetect_enable=true midi_driver=null \
  core_info_cache_enable=false gamemode_enable=false menu_swap_ok_cancel_buttons=true; do
  [[ $(cfgv "${kv%%=*}") == "${kv#*=}" ]] || { ok=1; echo "  ${kv%%=*} is '$(cfgv "${kv%%=*}")'"; }
done
pad="$share/autoconfig/udev/AYANEO Controller.cfg"
for l in 'input_b_btn = "1"' 'input_a_btn = "0"' 'input_x_btn = "2"' 'input_y_btn = "3"' 'input_b_btn_label = "A"' \
  'input_a_btn_label = "B"' 'input_x_btn_label = "Y"' 'input_y_btn_label = "X"'; do
  grep -qxF "$l" "$pad" || { ok=1; echo "  no '$l' in the autoconfig"; }
done
cmp -s <(printf '%s\n' 'nes /usr/share/libretro/shaders/blockie/crt-gdv-mini.glslp' \
  'snes /usr/share/libretro/shaders/blockie/crt-gdv-mini.glslp' 'genesis /usr/share/libretro/shaders/blockie/crt-gdv-mini.glslp' \
  'gb /usr/share/libretro/shaders/blockie/lcd3x.glslp' 'gbc /usr/share/libretro/shaders/blockie/lcd3x.glslp' \
  'gba /usr/share/libretro/shaders/blockie/lcd3x.glslp' 'ps1 /usr/share/libretro/shaders/blockie/lcd3x.glslp') \
  "$t/shader-defaults" || { ok=1; echo "  shipped shader-defaults"; }
! grep -q 'audio_volume' "$share/blockie.cfg" || ok=1
! grep -q '^core_options_path' "$share/blockie.cfg" || { ok=1; echo "  blockie.cfg sets core_options_path"; }
for l in 'menu_show_online_updater = "false"' 'menu_show_core_updater = "false"' 'core_updater_buildbot_cores_url = ""' \
  'core_updater_buildbot_assets_url = ""' 'netplay_public_announce = "false"' 'network_cmd_enable = "false"'; do
  grep -qxF "$l" "$share/blockie.cfg" || { ok=1; echo "  no '$l'"; }
done
! grep -Eq '^input_(enable_hotkey|menu_toggle|exit_emulator)_btn' "$share/blockie.cfg" || { ok=1; echo "  a pad hotkey in blockie.cfg"; }
! grep -q 'input_menu_toggle_btn' "$pad" || { ok=1; echo "  a pad menu toggle in the autoconfig"; }
res $ok "base config: dirs, sram autosave every 60 s, cores, pipewire, midi, info cache, gamemode, no save on exit, menu ok on south, positional face buttons with physical labels, shader defaults, volume, stdin commands, no pad hotkeys"

if [[ $fails == 0 ]]; then
  echo "game: all ok"
  exit 0
fi
echo "game: $fails failed"
exit 1
