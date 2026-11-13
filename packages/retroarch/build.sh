#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
srpm=/srpm/${SRPM_URL##*/}
echo "$SRPM_SHA256  $srpm" | sha256sum -c --quiet -
(cd "$src" && sha256sum -c --quiet - <<< "$PATCH_SHA256")
read -ra patches <<< "$(awk '{ printf "%s ", $2 }' <<< "$PATCH_SHA256")"
top=/var/tmp/retroarch-build
mkdir -p "$top"
rpm -i --define "_topdir $top" "$srpm"
for p in "${patches[@]}"; do
  cp "$src/$p" "$top/SOURCES/"
done
spec=$top/SPECS/retroarch.spec
flags=(--enable-opengles --enable-opengles3 --enable-opengles3_1 --enable-opengles3_2 --enable-egl --enable-pipewire
  --enable-udev --disable-qt)
for r in 'perl(Net::DBus)' 'perl(X11::Protocol)'; do
  grep -qxF "Requires:       $r" "$spec" || { echo "build.sh: no Requires: $r to drop" >&2; exit 1; }
done
sed -i -e '/^Requires: *perl(Net::DBus)$/d' -e '/^Requires: *perl(X11::Protocol)$/d' \
  -e 's/^Release:\( *\)%autorelease$/Release:\1%{autorelease}.blockie/' \
  -e '/^BuildRequires:  mesa-libEGL-devel$/a BuildRequires:  pkgconfig(glesv2)' "$spec"
ADD=$(printf '    %s \\\n' "${flags[@]}") awk '{ print } /^    --enable-wayland +\\$/ { print ENVIRON["ADD"] }' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
lines=$(printf 'Patch:          %s\n' "${patches[@]}")
LINES=$lines awk '{ l[NR] = $0 } /^Patch[0-9]*:/ { n = NR }
  END { for (i = 1; i <= NR; i++) { print l[i]; if (i == n) print ENVIRON["LINES"] } }' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
[[ $(grep '^Patch[0-9]*:' "$spec" | tail -n "${#patches[@]}") == "$lines" ]] ||
  { echo "build.sh: ${patches[*]} are not the last Patch lines in that order" >&2; exit 1; }
for p in "${patches[@]}"; do
  [[ $(grep -cxF "Patch:          $p" "$spec") == 1 ]] || { echo "build.sh: $p is not one Patch line" >&2; exit 1; }
done
check=$(cat << 'EOF'
[ "$(grep -cxF '#if defined(HAVE_OPENGLES2) || defined(HAVE_OPENGLES3)' gfx/drivers_context/wayland_ctx.c)" = 2 ] ||
  { echo "gles-context.patch is not applied to wayland_ctx.c" >&2; exit 1; }
grep -qF '// passthrough version_major / version_minor unchanged' gfx/drivers/gl2.c ||
  { echo "gles-context.patch is not applied to gl2.c" >&2; exit 1; }
[ "$(grep -cF 'DB_TO_GAIN(MIN(val, 0.0f));' audio/audio_driver.c)" = 2 ] ||
  { echo "volume-cap.patch is not applied to audio_driver.c" >&2; exit 1; }
[ "$(grep -cF 'audio_mixer_voice_set_volume(voice, DB_TO_GAIN(MIN(vol, 0.0f)));' audio/audio_driver.c)" = 1 ] ||
  { echo "volume-cap.patch is not applied to the mixer streams in audio_driver.c" >&2; exit 1; }
[ "$(grep -cxF '   new_volume       = MIN(new_volume, 0.0f);' command.c)" = 2 ] ||
  { echo "volume-cap.patch is not applied to command.c" >&2; exit 1; }
[ "$(grep -cF 'list_info, -80, 0, 1.0, true, true);' menu/menu_setting.c)" = 2 ] ||
  { echo "volume-cap.patch is not applied to menu_setting.c" >&2; exit 1; }
EOF
)
CHECK=$check awk '/^%build$/ && !d { print ENVIRON["CHECK"] "\n"; d = 1 } { print }' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
for p in "${patches[@]}"; do
  n=$(grep -cF "$p is not applied to" <<< "$check")
  [[ $n -gt 0 && $(awk '/^%prep$/ { p = 1 } /^%build$/ { exit } p' "$spec" | grep -cF "$p is not applied to") == "$n" ]] ||
    { echo "build.sh: the $p check is not in %prep" >&2; exit 1; }
done
grep -qx 'Release: *%{autorelease}\.blockie' "$spec" || { echo "build.sh: Release not rewritten" >&2; exit 1; }
grep -qx 'BuildRequires:  pkgconfig(glesv2)' "$spec" || { echo "build.sh: BuildRequires not added" >&2; exit 1; }
! grep -q '^Requires: *perl(' "$spec" || { echo "build.sh: a perl Requires is left" >&2; exit 1; }
conf=$(awk '/^\.\/configure/ { f = 1 } f { print } f && /%\{nil\}/ { exit }' "$spec")
for f in "${flags[@]}"; do
  [[ $(grep -cxF "    $f \\" <<< "$conf") == 1 ]] || { echo "build.sh: $f is not once in the configure call" >&2; exit 1; }
done
rpmbuild -bb \
  --define "_topdir $top" \
  --define "_buildhost blockie" \
  --define "_smp_ncpus_max 6" \
  --define "use_source_date_epoch_as_buildtime 1" \
  --define "clamp_mtime_to_source_date_epoch 1" \
  --define "debug_package %{nil}" \
  "$spec"
f=$(find "$top/RPMS" -name 'retroarch-[0-9]*.rpm')
[[ -n $f && $f != *$'\n'* ]] || { echo "build.sh: expected one retroarch RPM, found: $f" >&2; exit 1; }
cp "$f" "$out/"
