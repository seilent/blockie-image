#!/usr/bin/env bash
set -euo pipefail

out=${1:?usage: build.sh <outdir>}
src=$(cd "$(dirname "$0")" && pwd)
. "$src/SOURCE.env"
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || { echo "build.sh: SOURCE_DATE_EPOCH is not set to a number" >&2; exit 1; }
export SOURCE_DATE_EPOCH
srpm=/srpm/${SRPM_URL##*/}
echo "$SRPM_SHA256  $srpm" | sha256sum -c --quiet -
patch=gles-context.patch
echo "$PATCH_SHA256  $src/$patch" | sha256sum -c --quiet -
top=/var/tmp/retroarch-build
mkdir -p "$top"
rpm -i --define "_topdir $top" "$srpm"
cp "$src/$patch" "$top/SOURCES/"
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
awk -v p="Patch:          $patch" '{ l[NR] = $0 } /^Patch[0-9]*:/ { n = NR }
  END { for (i = 1; i <= NR; i++) { print l[i]; if (i == n) print p } }' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
[[ $(grep '^Patch[0-9]*:' "$spec" | tail -n 1) == "Patch:          $patch" && $(grep -cxF "Patch:          $patch" "$spec") == 1 ]] ||
  { echo "build.sh: $patch is not the last Patch line" >&2; exit 1; }
check=$(cat << 'EOF'
[ "$(grep -cxF '#if defined(HAVE_OPENGLES2) || defined(HAVE_OPENGLES3)' gfx/drivers_context/wayland_ctx.c)" = 2 ] ||
  { echo "gles-context.patch is not applied to wayland_ctx.c" >&2; exit 1; }
grep -qF '// passthrough version_major / version_minor unchanged' gfx/drivers/gl2.c ||
  { echo "gles-context.patch is not applied to gl2.c" >&2; exit 1; }
EOF
)
CHECK=$check awk '/^%build$/ && !d { print ENVIRON["CHECK"] "\n"; d = 1 } { print }' "$spec" > "$spec.new"
mv "$spec.new" "$spec"
[[ $(awk '/^%prep$/ { p = 1 } /^%build$/ { exit } p' "$spec" | grep -cF "$patch is not applied to") == 2 ]] ||
  { echo "build.sh: the $patch check is not in %prep" >&2; exit 1; }
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
