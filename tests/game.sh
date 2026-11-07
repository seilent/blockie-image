#!/usr/bin/env bash
set -u

game=/usr/bin/blockie-game
share=/usr/share/blockie/retroarch
data=/var/lib/blockie/data
t=$(mktemp -d "${TMPDIR:-/tmp}/game.XXXXXX")
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

export FAKE=$t/fake
mkdir -p "$FAKE/bin" "$t/run" "$data/roms/gba" "$data/roms/psp" "$data/roms/dir" /usr/share/libretro/shaders/crt
printf 'invented rom\n' > "$data/roms/gba/test.gba"
printf 'invented iso\n' > "$data/roms/psp/test.iso"
printf 'invented shader\n' > /usr/share/libretro/shaders/crt/test.glslp
printf 'invented shader\n' > /usr/share/libretro/shaders/crt/test.slangp
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
[[ "$*" != "--user show -P ActiveState blockie-game.scope" ]] || printf '%s\n' "${FAKE_STATE:-}"
[[ "$*" != "--user is-active --quiet blockie-frontend.service" || -z ${FAKE_NOFRONTEND:-} ]] || exit 3
exit 0
EOF
cat > "$FAKE/bin/retroarch" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE/retroarch.argv"
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
if [[ -n ${FAKE_SLEEP:-} ]]; then
  trap 'echo term > "$FAKE/term"; exit 143' TERM
  echo "$$" > "$FAKE/pid"
  sleep 30 &
  wait
fi
exit "${FAKE_RC:-0}"
EOF
chmod 755 "$FAKE/bin/systemd-run" "$FAKE/bin/systemctl" "$FAKE/bin/retroarch"

play() {
  rm -f "$FAKE"/*.log "$FAKE/retroarch.argv" "$FAKE/retroarch.env" "$FAKE/append.cfg" "$FAKE/term" "$FAKE/pid"
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
scope+=" -p After=blockie-frontend.service -p MemoryHigh=80% -p MemoryMax=90% -p TasksMax=512 -p OOMPolicy=kill --"
base="--config $share/blockie.cfg"

play gba "$rom"
[[ $rc == 0 && $(cat "$FAKE/systemd-run.log") == "$scope retroarch $base -L /usr/lib64/libretro/mgba_libretro.so $rom" ]]
res $? "gba: one scope in blockie-emulation.slice bound to the frontend, with the limits, RetroArch on mgba"

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

play gba "$data/roms/gba/in.gba"
[[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/mgba_libretro.so $rom"
res $? "a symlink inside the data dir is passed resolved"

play psp "$data/roms/psp/test.iso"
[[ $rc == 0 ]] && argv "$base --appendconfig $share/core/ppsspp.cfg -L /usr/lib64/libretro/ppsspp_libretro.so $data/roms/psp/test.iso" &&
  [[ $(cat "$FAKE/append.cfg") == 'system_directory = "/usr/share/libretro/ppsspp"' ]]
res $? "psp: the ppsspp core config points system_directory at the PPSSPP assets"

[[ -f /usr/share/libretro/ppsspp/PPSSPP/compat.ini ]]
res $? "the ppsspp system directory holds PPSSPP/compat.ini"

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
  play gba "$rom" --config "$t/game.cfg"
}
cfg 'aspect_ratio_index = "22"' '' 'video_scale_integer = "true"' 'video_shader_enable = "false"' \
  'video_shader = "/usr/share/libretro/shaders/crt/../crt/test.glslp"' 'video_smooth="false"' 'rewind_enable = "true"' \
  'savestate_auto_save = "false"' 'savestate_auto_load = "true"' $'fastforward_ratio = "4.0"\r'
exp=$(printf '%s\n' 'aspect_ratio_index = "22"' 'video_scale_integer = "true"' 'video_shader_enable = "false"' \
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
[[ $rc == 0 ]] && argv "$base -L /usr/lib64/libretro/mgba_libretro.so $rom"
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

mv /usr/lib64/libretro/mgba_libretro.so "$t/mgba.so"
play gba "$rom"
[[ $rc == 69 ]] && ! ran
res $? "a core that is not installed exits 69 before anything starts"
mv "$t/mgba.so" /usr/lib64/libretro/mgba_libretro.so

flock -o "$t/run/blockie-game.lock" sleep 5 &
holder=$!
sleep 0.5
play gba "$rom"
[[ $rc == 75 ]] && ! ran
res $? "a held lock exits 75 and starts nothing"
kill "$holder" 2> /dev/null
wait "$holder" 2> /dev/null

ok=0
for s in active activating deactivating reloading; do
  FAKE_STATE=$s play gba "$rom"
  [[ $rc == 75 ]] && ! ran || { ok=1; echo "  $s: rc $rc"; }
done
res $ok "a scope still active, starting or stopping exits 75"

FAKE_NOFRONTEND=1 play gba "$rom"
[[ $rc == 75 ]] && ! ran && grep -q 'frontend not active' "$t/out"
res $? "frontend not active exits 75 and starts nothing"

FAKE_STATE=failed play gba "$rom"
[[ $rc == 0 ]] && ran && grep -qx -- '--user reset-failed blockie-game.scope' "$FAKE/systemctl.log"
res $? "a failed scope is reset, then the game starts"

printf ' 0 [mt6768mt6358   ]: mt6768mt6358 - mt6768-mt6358\n' > "$t/card"
CARDS=$t/card play gba "$rom"
[[ $rc == 71 ]] && ! ran
res $? "a failed DL1 check exits 71 before RetroArch starts"

RUN='' play gba "$rom"
[[ $rc == 70 ]] && ! ran
res $? "no XDG_RUNTIME_DIR exits 70"

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
kill -TERM "$w"
wait "$w"
rc=$?
[[ $rc == 143 && -e $FAKE/term ]] && grep -qx -- '--user stop blockie-game.scope' "$FAKE/systemctl.log"
res $? "TERM on the wrapper stops RetroArch and the scope, then exits 143"

cfgv() { sed -n "s/^$1 = \"\(.*\)\"$/\1/p" "$share/blockie.cfg"; }
ok=0
for kv in video_driver=gl video_context_driver=wayland input_driver=udev input_joypad_driver=udev input_enable_hotkey_btn=10 \
  input_menu_toggle_btn=10 input_exit_emulator_btn=9 quit_press_twice=false auto_overrides_enable=false \
  auto_remaps_enable=false remap_save_on_exit=false auto_shaders_enable=false game_specific_options=false \
  savefile_directory=$data/saves savestate_directory=$data/states system_directory=$data/bios \
  libretro_directory=/usr/lib64/libretro libretro_info_path=/usr/share/libretro/info audio_driver=pipewire \
  config_save_on_exit=false joypad_autoconfig_dir=$share/autoconfig input_autodetect_enable=true midi_driver=null \
  core_info_cache_enable=false gamemode_enable=false; do
  [[ $(cfgv "${kv%%=*}") == "${kv#*=}" ]] || { ok=1; echo "  ${kv%%=*} is '$(cfgv "${kv%%=*}")'"; }
done
! grep -q 'audio_volume' "$share/blockie.cfg" || ok=1
for l in 'menu_show_online_updater = "false"' 'menu_show_core_updater = "false"' 'core_updater_buildbot_cores_url = ""' \
  'core_updater_buildbot_assets_url = ""' 'netplay_public_announce = "false"' 'network_cmd_enable = "false"'; do
  grep -qxF "$l" "$share/blockie.cfg" || { ok=1; echo "  no '$l'"; }
done
[[ -f "$share/autoconfig/udev/AYANEO Controller.cfg" ]] || ok=1
res $ok "base config: dirs, cores, pipewire, midi, info cache and gamemode off, no save on exit, pad autoconfig, default volume"

if [[ $fails == 0 ]]; then
  echo "game: all ok"
  exit 0
fi
echo "game: $fails failed"
exit 1
