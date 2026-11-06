#!/usr/bin/env bash
set -euo pipefail

ref=${1:?usage: pkg-check.sh <repo@digest> <work dir> [rpms out dir]}
work=${2:?usage: pkg-check.sh <repo@digest> <work dir> [rpms out dir]}
dest=${3:-}
oci=$work/oci
tree=$work/tree
mkdir -p "$work"
rm -rf "${oci:?}" "${tree:?}"
skopeo copy --quiet --src-no-creds "docker://$ref" "oci:$oci"
manifest=$(jq -r '.manifests[0].digest' "$oci/index.json")
mapfile -t layers < <(jq -r '.layers[].digest' "$oci/blobs/sha256/${manifest#sha256:}")
[[ ${#layers[@]} == 1 && ${layers[0]} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::$ref has ${#layers[@]} layers"; exit 1; }
config=$(jq -r '.config.digest' "$oci/blobs/sha256/${manifest#sha256:}")
dirty=$(jq -r '.config.Labels["blockie.dirty"] // "none"' "$oci/blobs/sha256/${config#sha256:}")
if [[ $dirty == 1 && ${GITHUB_REF:-} == refs/heads/main ]]; then
  echo "::error::$ref was built from uncommitted inputs (blockie.dirty=1); main takes only clean packages"
  exit 1
fi
[[ $dirty == 0 ]] || echo "::warning::$ref has blockie.dirty=$dirty"
blob=$oci/blobs/sha256/${layers[0]#sha256:}
bad=$(tar -tvf "$blob" | awk '$1 !~ /^[-d]/ { print; next } { p = $NF; sub(/^\.\//, "", p) } p != "rpms/" && p !~ /^rpms\/[^\/]+$/ { print }')
[[ -z $bad ]] || { echo "::error::$ref has entries other than files in rpms/: $bad"; exit 1; }
if [[ -n $dest ]]; then
  mkdir -p "$tree"
  tar -xf "$blob" -C "$tree" --no-same-owner --no-same-permissions
  [[ -d $tree/rpms ]] || { echo "::error::$ref has no /rpms"; exit 1; }
  mv "$tree/rpms" "$dest"
fi
rm -rf "${oci:?}" "${tree:?}"
