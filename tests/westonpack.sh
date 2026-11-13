#!/usr/bin/env bash
set -u

sq=${1:?usage: westonpack.sh <weston_pkg_0.2.squashfs>}
want=0bccaeebc11296bb1fe4278c9677cb82965c5a04bcd63745fa09d78228bc1a93
mod=/usr/share/blockie/portmaster/mod_Blockie.txt
compat=/usr/lib64/blockie-ports/compat
ld=/usr/lib/ld-linux-aarch64.so.1
t=$(mktemp -d "${TMPDIR:-/tmp}/westonpack.XXXXXX")
trap 'rm -rf "${t:?}"' EXIT
fails=0

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

[[ $(sha256sum < "$sq" | cut -d' ' -f1) == "$want" ]] || { echo "westonpack: $sq is not sha256 $want" >&2; exit 1; }
unsquashfs -q -n -no-xattrs -d "$t/wp" "$sq" > /dev/null || { echo "westonpack: unsquashfs failed" >&2; exit 1; }
w=$t/wp
chmod u+w "$w/lib_aarch64" && mv "$w/lib_aarch64/libxkbcommon.so.0" "$w/lib_aarch64/libxkbcommon.so.0.blockie-hidden" ||
  { echo "westonpack: cannot hide the bundled libxkbcommon" >&2; exit 1; }
gpu=$t/gpu
mkdir -p "$gpu" "$t/empty"
for n in libEGL.so.1 libEGL.so libGLESv2.so.2 libGLESv2.so libgbm.so.1 libmali.so.1; do
  ln -s /usr/lib64/libz.so.1 "$gpu/$n"
done
chmod u+w "$w" || { echo "westonpack: cannot write the runtime dir" >&2; exit 1; }
cat > "$w/westonwrap-blockie.sh" << EOF
#!/bin/bash
CFW_NAME=Blockie
source "$mod"
printf '%s\n' "\$LD_LIBRARY_PATH" "\$WRAPPED_LIBRARY_PATH_MALI" "\${strace-}" "\${weston_preload-}"
EOF
mapfile -t paths < <(env -i PATH=/usr/bin BLOCKIE_GPULIB="$gpu" bash "$w/westonwrap-blockie.sh" cleanup 2> /dev/null)
outer=${paths[0]:-}
mali=${paths[1]:-}
[[ $outer == "$gpu:$compat" && $mali == "$gpu:$compat" ]]
res $? "the mod's westonwrap branch puts the GPU dir and $compat on both paths"
wlegl=$(cd "$w" && pwd -P)/lib_aarch64/extra_wayland/libwayland-egl.so.1
[[ -f $wlegl && -z ${paths[2]:-} && ${paths[3]:-} == "$wlegl" ]]
res $? "with no port prefix the mod puts the runtime's libwayland-egl.so.1 in weston_preload (westonwrap.sh:525)"
xskat="env LD_PRELOAD=$w/lib_aarch64/libwayland-client.so.0:$w/lib_aarch64/libwayland-server.so.0:$w/lib_aarch64/graphics/crusty_gbm/libcrusty.so"
mapfile -t pre < <(env -i PATH=/usr/bin BLOCKIE_GPULIB="$gpu" strace="$xskat" bash "$w/westonwrap-blockie.sh" cleanup 2> /dev/null)
[[ ${pre[2]:-} == "env LD_PRELOAD=$wlegl:$w/lib_aarch64/libwayland-client.so.0:$w/lib_aarch64/libwayland-server.so.0" &&
  -z ${pre[3]:-} ]]
res $? "with XSkat's env LD_PRELOAD prefix in strace the mod puts libwayland-egl.so.1 first and drops crusty_gbm's libcrusty.so"
mapfile -t tsc < <(env -i PATH=/usr/bin BLOCKIE_GPULIB="$gpu" BLOCKIE_XDIR="$t/empty" BLOCKIE_XWATCH_POLLS=1 strace="$xskat" \
  bash "$w/westonwrap-blockie.sh" headless noop kiosk crusty_glx_gl4es game 2> /dev/null)
[[ ${tsc[2]:-} == "env LD_PRELOAD=$wlegl:$w/lib_aarch64/libwayland-client.so.0:$w/lib_aarch64/libwayland-server.so.0" ]]
res $? "with the same prefix and a crusty GL mode (The Secret Chronicles) the mod drops crusty_gbm's libcrusty.so too"

lib=$w/lib_aarch64
if [[ -e /usr/lib64/libGL.so.1 ]]; then
  xw=
else
  xw=$lib/graphics/mesa_x11_stub
fi
check() {
  local what=$1 path=$2 f=$3 out
  shift 3
  out=$(cd "$t/empty" && env -i LD_LIBRARY_PATH="$path" "$ld" --list "$f" 2>&1)
  if grep -qE 'not found' <<< "$out"; then
    grep -E 'not found' <<< "$out" | sed 's/^/  /'
    res 1 "$what"
    return
  fi
  local want
  for want in "$@"; do
    grep -qF -- "$want" <<< "$out" || { echo "  no '$want'"; res 1 "$what"; return; }
  done
  res 0 "$what"
}
game="$lib/graphics/crusty_x11egl/::$mali::$lib"
check "crusty_x11egl's libcrusty.so resolves on the game's path (westonwrap.sh:48)" "$game" \
  "$lib/graphics/crusty_x11egl/libcrusty.so" "libGLESv2.so => $gpu/libGLESv2.so"
game="$lib/graphics/gl4es_glxpass/:$lib/graphics/crusty_glx/::$mali::$lib"
check "crusty_glx's libcrusty.so resolves on the gl4es game's path" "$game" "$lib/graphics/crusty_glx/libcrusty.so" \
  "libGLESv2.so => $gpu/libGLESv2.so" "libGL.so.1 => $lib/graphics/gl4es_glxpass/libGL.so.1"
weston="$lib:$outer"
check "headless-backend.so resolves on weston's path (westonwrap.sh:150, :525)" "$weston" \
  "$lib/libweston-14/headless-backend.so" "libjpeg.so.8 => $compat/libjpeg.so.8" \
  "libxkbcommon.so.0 => " "lib64/libxkbcommon.so.0 ("
check "xwayland.so resolves on weston's path with LIBJPEG_8.0" "$weston" "$lib/libweston-14/xwayland.so" \
  "libjpeg.so.8 => $compat/libjpeg.so.8"
check "bin/Xwayland resolves on weston's path with libbz2.so.1.0" "${xw:+$xw:}$weston" "$w/bin/Xwayland" \
  "libbz2.so.1.0 => $compat/libbz2.so.1.0"
wb=$lib/libweston-14/wayland-backend.so
relocate() {
  (cd "$t/empty" && env -i LD_LIBRARY_PATH="$weston" LD_PRELOAD="$1" LD_TRACE_LOADED_OBJECTS=1 LD_BIND_NOW=yes \
    LD_WARN=yes LD_DEBUG=files,bindings "$ld" "$wb" 2>&1)
}
unbound() {
  grep -F "($wb)" <<< "$1" | grep -F 'undefined symbol'
}
why() {
  grep -E 'undefined symbol|not found|libmali\.so\.1|libwayland-egl|wl_egl_window' <<< "$1" | sed 's/^/  /'
}
out=$(relocate "")
[[ $(unbound "$out") == *wl_egl_window_destroy* ]]
r=$?
(( r == 0 )) || why "$out"
res $r "with no preload wayland-backend.so leaves wl_egl_window_destroy unbound (a libmali.so.1 without wl_egl)"
p=${pre[2]:-}
p=${p#*LD_PRELOAD=}
p=${p%% *}
out=$(relocate "$p")
[[ -z $(unbound "$out") ]] && grep -qF "binding file $wb [0] to $wlegl [0]: normal symbol \`wl_egl_window_destroy'" <<< "$out"
r=$?
(( r == 0 )) || why "$out"
res $r "wayland-backend.so binds every symbol on weston's path with the mod's XSkat preload, wl_egl_window_destroy to the runtime's libwayland-egl.so.1"

if (( fails )); then
  echo "westonpack: $fails failed"
  exit 1
fi
echo "westonpack: ok"
