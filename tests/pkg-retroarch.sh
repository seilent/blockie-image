#!/usr/bin/env bash
set -euo pipefail

name=retroarch
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-retroarch.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name $(uname -m)" ]] || fail "name or arch"
[[ $(rpm -qp --qf '%{RELEASE}' "$rpm") == *.blockie ]] || fail "release is not the blockie build"
! grep -q '^perl(' <<< "$(rpm -qp --requires "$rpm")" || fail "requires perl modules"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
bin=$t/usr/bin/retroarch
[[ -f $bin ]] || fail "no /usr/bin/retroarch"
case $(uname -m) in
  x86_64) machine="Advanced Micro Devices X86-64" ;;
  aarch64) machine=AArch64 ;;
  *) fail "no machine name for $(uname -m)" ;;
esac
[[ $(readelf -hW "$bin" | sed -n 's/^ *Machine: *//p') == "$machine" ]] || fail "the binary is not for $(uname -m)"
needed=$(readelf -dW "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
for l in libEGL.so.1 libGLESv2.so.2 libwayland-egl.so.1; do
  grep -qxF "$l" <<< "$needed" || fail "retroarch does not link $l"
done
while IFS= read -r -d '' f; do
  [[ $(od -An -N4 -tx1 "$f" | tr -d ' \n') == 7f454c46 ]] || continue
  bad=$(readelf -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -E '^(libQt6|libGL\.so|libGLX\.so|libOpenGL\.so)' || true)
  [[ -z $bad ]] || fail "${f#"$t"} links $bad"
done < <(find "$t" -type f -print0)
features=$("$bin" --features)
for l in "OpenGLES        - Video driver: yes" "EGL             - Video context driver: yes" \
  "Wayland         - Wayland input/video drivers: yes" "UDEV            - UDEV/EVDEV input driver: yes" \
  "Vulkan          - Video driver: yes" "PipeWire        - Audio driver: yes" "ALSA            - Audio driver: yes" \
  "glslang         - Fragment/vertex shader driver: yes"; do
  grep -qxF "  $l" <<< "$features" || fail "--features lacks '$l'"
done
! grep -q '^  Qt  ' <<< "$features" || fail "built with the Qt companion"
echo "pkg-$name: ok"
