#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-source: $*" >&2; exit 1; }

(( $# == 2 )) || { echo "usage: pkg-source.sh <name> <outdir>" >&2; exit 2; }
name=$1
out=$2
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "bad package name $name"
root=$(cd "$(dirname "$0")/.." && pwd)
read -ra podman <<< "${PODMAN:-podman}"
pins=$root/packages/$name/SOURCE.sha256
if [[ ! -f $pins ]]; then
  echo "pkg-source: $name pins no source"
  exit 0
fi
[[ ! -e $root/packages/$name/LOCAL ]] || fail "$name is built on the build PC, its source goes up with just pkg-push"
[[ -f $root/packages/$name/Containerfile ]] || fail "$name pins a source but has no Containerfile"
mapfile -t files < <(awk '{ print $2 }' "$pins")
(( ${#files[@]} )) || fail "$pins is empty"
for f in "${files[@]}"; do
  [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "bad file name $f in $pins"
done
mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
ctr=$("${podman[@]}" create "localhost/blockie-pkg-builder-$name" none)
trap '"${podman[@]}" rm "$ctr" > /dev/null' EXIT
for f in "${files[@]}"; do
  "${podman[@]}" cp "$ctr:/srcpkg/$f" "$out/$f"
done
(cd "$out" && sha256sum --quiet -c "$pins") || fail "the builder's /srcpkg differs from $pins"
[[ $(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort) == "$(printf '%s\n' "${files[@]}" | LC_ALL=C sort)" ]] ||
  fail "files in $out differ from $pins"
echo "pkg-source: $name, ${#files[@]} files, $(du -sb "$out" | cut -f1) bytes"
