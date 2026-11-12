#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-blockie.conf

own=(blk-wmt/blk-wmt blk-bt/blk-bt blockie-tools/blockie-tools blockie-gpu/blockie-gpu blockie-compositor/blockie-compositor blockie-frontend/blockie-frontend bootc/bootc ostree/ostree ostree/ostree-libs)
for c in snes9x genesis-plus-gx mupen64plus-next ppsspp flycast; do
  own+=("libretro-$c/libretro-$c")
done
own+=(retroarch/retroarch libretro-shaders-blockie/libretro-shaders-blockie waydroid/waydroid)
own+=(gptokeyb/gptokeyb gptokeyb2/gptokeyb2 libjpeg8/libjpeg8 portmaster/portmaster depotdownloader/depotdownloader)

own_rpm() {
  local dir=/pkgs/${1%%/*} name=${1#*/} f found=()
  for f in "$dir"/*.rpm; do
    if [[ -f $f && $f != *.src.rpm && $(rpm -qp --qf '%{NAME}' "$f") == "$name" ]]; then
      found+=("$f")
    fi
  done
  (( ${#found[@]} == 1 )) || { echo "30-packages: expected one $name RPM in $dir, found ${#found[@]}" >&2; exit 1; }
  echo "${found[0]}"
}

rpms=()
for p in "${own[@]}"; do
  rpms+=("$(own_rpm "$p")")
done

read -ra opts <<< "${BLOCKIE_DNF_OPTS:-}"
dnf -y "${opts[@]}" install \
  "${rpms[@]}" \
  e2fsprogs \
  tzdata \
  erofs-utils \
  vulkan-tools \
  egl-utils \
  drm-utils \
  strace \
  file \
  procps-ng \
  jq \
  libwayland-client \
  libwayland-server \
  pipewire \
  pipewire-alsa \
  pipewire-pulseaudio \
  pipewire-utils \
  wireplumber \
  NetworkManager-wifi \
  wpa_supplicant \
  iw \
  wireless-regdb \
  iperf3 \
  bluez \
  alsa-ucm \
  alsa-ucm-utils \
  alsa-utils \
  polkit \
  python3-gobject-base \
  python3-evdev \
  wlrctl \
  kmscube \
  glmark2 \
  labwc \
  wlopm \
  lxc \
  dnsmasq \
  iptables-legacy \
  libretro-mgba \
  libretro-pcsx-rearmed \
  libretro-gambatte \
  libretro-nestopia \
  SDL2_mixer \
  SDL2_ttf \
  SDL2_image \
  love \
  luajit \
  innoextract \
  xdelta \
  turbojpeg \
  sdl2-compat \
  openal-soft \
  libtheora \
  libvorbis
