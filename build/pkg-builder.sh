#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: pkg-builder.sh key | build <name>" >&2; exit 2; }
mode=${1:-}
cd "$(dirname "$0")/.."
read -ra podman <<< "${PODMAN:-podman}"
base=localhost/blockie-pkg-builder
limits=(--memory=14g --cpu-period=100000 --cpu-quota=600000)
st=${BLOCKIE_REPO_STATE:-}
if [[ -z $st ]]; then
  st=$(mktemp -d)
  trap 'rm -rf "${st:?}"' EXIT
fi

state() { [[ -s $st/state && -s $st/blockie.repo ]] || build/repo-state.sh "$st" >&2; }
key() { { sha256sum < build/pkg.Containerfile; cut -d' ' -f1,2 "$st/state"; } | sha256sum | cut -c1-16; }

case $mode in
  key)
    state
    key
    ;;
  build)
    name=${2:-}
    [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage
    k=-
    if state; then
      k=$(key)
    fi
    if [[ $k != - ]] && "${podman[@]}" image exists "$base:$k"; then
      "${podman[@]}" tag "$base:$k" "$base"
      echo "pkg-builder: $base:$k reused" >&2
    elif [[ $k != - ]]; then
      "${podman[@]}" build --no-cache "${limits[@]}" -v "$st:/etc/dnf/repos.override.d:ro,Z" \
        -t "$base:$k" -t "$base" -f build/pkg.Containerfile build >&2
    else
      echo "::warning::pkg-builder: no repo state, $base built without a key" >&2
      "${podman[@]}" build --no-cache "${limits[@]}" -t "$base" -f build/pkg.Containerfile build >&2
    fi
    echo "pkg-builder: $base rpms $("${podman[@]}" run --rm --network=none "$base" rpm -qa | LC_ALL=C sort | sha256sum | cut -c1-16)" >&2
    img=$base
    if [[ -f packages/$name/Containerfile ]]; then
      img=$base-$name
      from=()
      [[ $k == - ]] || from=(--from "$base:$k")
      "${podman[@]}" build "${from[@]}" "${limits[@]}" -t "$img" -f "packages/$name/Containerfile" "packages/$name" >&2
    fi
    echo "$img $k"
    ;;
  *)
    usage
    ;;
esac
