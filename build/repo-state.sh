#!/usr/bin/env bash
set -euo pipefail

dir=$(realpath -m "${1:?usage: repo-state.sh <dir>}")
arch=${REPO_ARCH:-$(uname -m)}
mkdir -p "$dir"
: > "$dir/state.new"
: > "$dir/blockie.repo.new"
for r in fedora:fedora-44 updates:updates-released-f44; do
  id=${r%%:*}
  meta=$(curl -fsS --retry 3 "https://mirrors.fedoraproject.org/metalink?repo=${r#*:}&arch=$arch") ||
    { echo "repo-state: no metalink for $id" >&2; exit 1; }
  want=$(sed -n '/<hash type="sha256">/{s|.*<hash type="sha256">\([0-9a-f]\{64\}\)</hash>.*|\1|p;q}' <<< "$meta")
  [[ $want =~ ^[0-9a-f]{64}$ ]] || { echo "repo-state: no repomd sha256 for $id" >&2; exit 1; }
  mapfile -t urls < <(sed -n 's|.*<url protocol="https"[^>]*>\(https://[^<]*/repodata/repomd\.xml\)</url>.*|\1|p' <<< "$meta")
  base=
  for url in "${urls[@]:0:10}"; do
    got=$(curl -fsS --max-time 20 "$url" | sha256sum | cut -d' ' -f1) || continue
    if [[ $got == "$want" ]]; then
      base=${url%repodata/repomd.xml}
      break
    fi
  done
  [[ -n $base ]] || { echo "repo-state: no mirror serves the $id repomd $want" >&2; exit 1; }
  printf '%s %s %s\n' "$id" "$want" "$base" >> "$dir/state.new"
  printf '[%s]\nbaseurl=%s\nmetalink=\nmirrorlist=\n' "$id" "$base" >> "$dir/blockie.repo.new"
done
mv "$dir/blockie.repo.new" "$dir/blockie.repo"
mv "$dir/state.new" "$dir/state"
cat "$dir/state"
