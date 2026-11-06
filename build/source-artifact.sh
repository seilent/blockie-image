#!/usr/bin/env bash
set -euo pipefail

fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
koji=https://kojipkgs.fedoraproject.org/packages
key=6d9f90a6
repo=https://github.com/seilent/blockie-image

fail() { echo "source-artifact: $*" >&2; exit 1; }

(( $# == 4 )) || { echo "usage: source-artifact.sh <srpms.tsv> <outdir> <full|base> <kernel package repo@digest>" >&2; exit 2; }
tsv=$1
out=$2
mode=$3
kref=$4
source_type=application/vnd.blockie.source.v1
kname=blockie-kernel-source.tar.gz
[[ $mode == full || $mode == base ]] || fail "mode is $mode, not full or base"
[[ -s $tsv ]] || fail "$tsv is empty"

[[ $kref =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] || fail "bad kernel package ref $kref"

root=$(cd "$(dirname "$0")/.." && pwd)
ksha=$(awk -v n="$kname" '$2 == n { print $1 }' "$root/packages/kernel/SOURCE.sha256")
[[ $ksha =~ ^[0-9a-f]{64}$ ]] || fail "no $kname line in packages/kernel/SOURCE.sha256"

mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

awk '$1 == "Name:" { n = $2; print n } $1 == "%package" { print ($2 == "-n" ? $3 : n "-" $2) }' "$root"/packages/*/*.spec \
  | sort -u > "$tmp/own"
[[ -s $tmp/own ]] || fail "no spec names under packages/"

sha=$(git -C "$root" rev-parse HEAD)
short=${sha::7}
git -C "$root" archive --format=tar.gz --prefix=blockie-image/ -o "$out/blockie-image-$short.tar.gz" HEAD
printf '%s %s\n' "blockie-image-$short.tar.gz" "$repo/tree/$sha" > "$tmp/origins"

krepo=${kref%@*}
art=""
while read -r d; do
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || continue
  layer=$(oras manifest fetch "$krepo@$d" | jq -r --arg n "$kname" '[.layers[] | select(.annotations["org.opencontainers.image.title"] == $n)] | if length == 1 then .[0].digest else empty end')
  [[ $layer == sha256:* ]] || continue
  oras blob fetch --output "$out/$kname" "$krepo@$layer"
  if [[ $(sha256sum < "$out/$kname" | cut -d' ' -f1) == "$ksha" ]]; then
    art=$d
    break
  fi
  rm -f "${out:?}/$kname"
done < <(oras discover --artifact-type "$source_type" --format json "$kref" | jq -r '.referrers[]?.digest')
[[ -n $art ]] || fail "no $source_type referrer on $kref holds $kname with sha256 $ksha"
printf '%s %s\n' "$kname" "$krepo@$art" >> "$tmp/origins"

if [[ $mode == full ]]; then
  nevra='^([A-Za-z0-9][A-Za-z0-9._+~^-]*)-([A-Za-z0-9._+~^]+)-([A-Za-z0-9._+~^]+)\.src\.rpm$'
  awk -F'\t' 'NR == FNR { own[$1] = 1; next } !($1 in own) && $2 != "(none)" { print $2 }' "$tmp/own" "$tsv" \
    | sort -u > "$tmp/srpms"
  [[ -s $tmp/srpms ]] || fail "no source rpms in $tsv"
  get=()
  while read -r f; do
    [[ $f =~ $nevra && $f != *..* ]] || fail "bad source rpm name $f"
    url=$koji/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/data/signed/$key/src/$f
    if [[ -n ${BLOCKIE_SOURCE_CACHE:-} && -s $BLOCKIE_SOURCE_CACHE/$f ]]; then
      ln "$BLOCKIE_SOURCE_CACHE/$f" "$out/$f" 2> /dev/null || cp "$BLOCKIE_SOURCE_CACHE/$f" "$out/$f"
    else
      get+=(-o "$out/$f" "$url")
    fi
    printf '%s %s\n' "$f" "$url" >> "$tmp/origins"
  done < "$tmp/srpms"
  echo "source-artifact: $(( $(wc -l < "$tmp/srpms") - ${#get[@]} / 3 )) source rpms from the cache, $(( ${#get[@]} / 3 )) from koji"
  if (( ${#get[@]} )); then
    curl -fsSLg --retry 5 --retry-all-errors --parallel --parallel-max 8 "${get[@]}" || fail "source rpm download failed"
  fi
  while read -r f; do
    [[ -s $out/$f ]] || fail "$f missing"
  done < "$tmp/srpms"
  podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && rpm -K -- *.src.rpm' > "$tmp/rpmk" \
    || { grep -v ': digests signatures OK$' "$tmp/rpmk" >&2; fail "rpm -K failed"; }
  [[ $(grep -c ': digests signatures OK$' "$tmp/rpmk") == "$(wc -l < "$tmp/srpms")" ]] || fail "rpm -K did not pass every source rpm"
fi

sort "$tmp/origins" | while read -r f url; do
  printf '%s %s %s\n' "$f" "$(sha256sum < "$out/$f" | cut -d' ' -f1)" "$url"
done > "$tmp/SOURCES"
[[ $(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) == "$(cut -d' ' -f1 "$tmp/SOURCES")" ]] || fail "files in $out differ from SOURCES"
mv "$tmp/SOURCES" "$out/SOURCES"

echo "source-artifact: $mode, $(wc -l < "$out/SOURCES") files, $(du -sb "$out" | cut -f1) bytes"
