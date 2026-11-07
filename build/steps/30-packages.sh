#!/usr/bin/env bash
set -euo pipefail

install -d /etc/dnf/libdnf5.conf.d
printf '[main]\ninstall_weak_deps=False\n' > /etc/dnf/libdnf5.conf.d/10-blockie.conf

own=(blk-wmt/blk-wmt blk-bt/blk-bt blockie-tools/blockie-tools bootc/bootc ostree/ostree ostree/ostree-libs)

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
  retroarch \
  libretro-mgba \
  libretro-pcsx-rearmed
