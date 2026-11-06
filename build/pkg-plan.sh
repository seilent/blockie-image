#!/usr/bin/env bash
set -euo pipefail

dest=$(realpath -m "${1:?usage: pkg-plan.sh <build list json out>}")
cd "$(dirname "$0")/.."
pubkey=system_files/usr/share/blockie/keys/blockie.pub

sig() {
  local out
  for _ in 1 2 3; do
    if out=$(cosign verify --key "$pubkey" "$1" 2>&1 > /dev/null); then echo signed; return; fi
    if grep -qE 'no signatures found|no matching signatures: (.*invalid signature|signature not found in transparency log)' <<< "$out"; then
      echo unsigned
      return
    fi
    echo "::warning::cosign verify $1: $out" >&2
    sleep 10
  done
  echo "::error::cosign verify $1: $out" >&2
  return 1
}

names=()
build=()
logged=0
for name in $(git ls-files -- 'packages/*/build.sh' | cut -d/ -f2); do
  [[ -z $(git ls-files -- "packages/$name/DEPS") ]] || { echo "::error::packages/$name has DEPS, which this workflow and the Justfile do not build yet"; exit 1; }
  names+=("$name")
  hash=$(build/pkg-hash.sh "$name")
  repo=ghcr.io/seilent/blockie/pkg/$name
  if err=$(skopeo inspect --no-creds --raw "docker://$repo:$hash" 2>&1 > /dev/null); then
    state=$(sig "$repo:$hash")
    if [[ $state == signed ]]; then
      echo "$repo:$hash exists, signed"
      continue
    fi
    echo "::warning::$repo:$hash has no valid signature, building and pushing a new one"
  else
    grep -qiE 'manifest unknown|404|403|denied|unauthorized' <<< "$err" || { echo "::error::$err"; exit 1; }
    if (( ! logged )); then
      skopeo login ghcr.io -u "$GH_ACTOR" --password-stdin <<< "$GH_TOKEN"
      logged=1
    fi
    if err=$(skopeo inspect --raw "docker://$repo:$hash" 2>&1 > /dev/null); then
      echo "::error::$repo:$hash exists but is not public"
      exit 1
    fi
    grep -qiE 'manifest unknown|404|403' <<< "$err" || { echo "::error::$err"; exit 1; }
    state=missing
    echo "$repo:$hash missing"
  fi
  if [[ -n $(git ls-files -- "packages/$name/LOCAL") ]]; then
    echo "::notice::$repo:$hash comes from the build PC (just pkg-push $name): $(head -n 1 "packages/$name/LOCAL")"
    continue
  fi
  build+=("$(jq -nc --arg p "$name" --arg s "$state" '{package: $p, state: $s}')")
done
(( ${#names[@]} )) || { echo "::error::no packages"; exit 1; }
if (( ${#build[@]} )); then
  printf '%s\n' "${build[@]}" | jq -sc . > "$dest"
else
  echo '[]' > "$dest"
fi
echo "build $(cat "$dest")"
