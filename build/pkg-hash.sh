#!/usr/bin/env bash
set -euo pipefail

mode='hash'
if [[ ${1:-} == --inputs || ${1:-} == --deps ]]; then
  mode=${1#--}
  shift
fi
name=${1:?usage: pkg-hash.sh [--inputs|--deps] <name>}
[[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "pkg-hash: bad name $name" >&2; exit 1; }
cd "$(dirname "$0")/.."
self=$PWD/build/pkg-hash.sh
dir=packages/$name
[[ -n $(git ls-files -- "$dir") ]] || { echo "pkg-hash: no tracked files in $dir" >&2; exit 1; }

deps=()
if [[ -n $(git ls-files -- "$dir/DEPS") ]]; then
  mapfile -t deps < <(git cat-file blob ":$dir/DEPS" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u)
  for dep in "${deps[@]}"; do
    [[ $dep =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "pkg-hash: bad dep '$dep' in $dir/DEPS" >&2; exit 1; }
    [[ $dep != "$name" ]] || { echo "pkg-hash: $name lists itself in DEPS" >&2; exit 1; }
    [[ -z $(git ls-files -- "packages/$dep/DEPS") ]] || { echo "pkg-hash: dep $dep of $name has DEPS" >&2; exit 1; }
  done
fi

inputs=("$dir" build/pkg.Containerfile build/pkg-wrap.Containerfile "tests/pkg-$name.sh" "tests/pkg-$name")
case $mode in
  deps)
    (( ${#deps[@]} == 0 )) || printf '%s\n' "${deps[@]}"
    ;;
  inputs)
    printf '%s\n' "${inputs[@]}"
    for dep in "${deps[@]}"; do
      "$self" --inputs "$dep"
    done
    ;;
  hash)
    lines=()
    for dep in "${deps[@]}"; do
      h=$("$self" "$dep")
      lines+=("dep $dep $h")
    done
    {
      git ls-files -s -- "${inputs[@]}" | LC_ALL=C sort -k4
      (( ${#lines[@]} == 0 )) || printf '%s\n' "${lines[@]}"
    } | sha256sum | cut -c1-16
    ;;
esac
