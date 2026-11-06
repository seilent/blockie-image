#!/usr/bin/env bash
set -euo pipefail

fail() { echo "verify-sig: $*" >&2; exit 1; }
usage() { echo "usage: verify-sig.sh unsigned <src> | signed <src> <dest>" >&2; exit 2; }

mode=${1:-}
src=${2:-}
case $mode in
  unsigned) (( $# == 2 )) || usage ;;
  signed) (( $# == 3 )) || usage ;;
  *) usage ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

skopeo inspect --raw "$src" > "$tmp/manifest" || fail "cannot read the manifest of $src"
type=$(jq -r .mediaType "$tmp/manifest")
[[ $type == application/vnd.oci.image.manifest.v1+json ]] || fail "$src is $type, not a single OCI image manifest"
digest=sha256:$(sha256sum < "$tmp/manifest" | cut -d' ' -f1)

if [[ $mode == unsigned ]]; then
  if skopeo copy "$src" "dir:$tmp/img" > "$tmp/log" 2>&1; then
    fail "$src was accepted, expected a refusal for no signature"
  fi
  if ! grep -q 'A signature was required, but no signature exists' "$tmp/log"; then
    cat "$tmp/log" >&2
    fail "$src refused for another reason"
  fi
  echo "verify-sig: $src $digest refused, no signature"
  exit 0
fi

dest=$3
start=$SECONDS
skopeo copy --preserve-digests --remove-signatures "$src" "$dest" || fail "copy of $src refused"
got=sha256:$(skopeo inspect --raw "$dest" | sha256sum | cut -d' ' -f1)
[[ $got == "$digest" ]] || fail "$dest resolves to $got, not $digest"
echo "verify-sig: $src $digest copied to $dest in $((SECONDS - start)) s"
