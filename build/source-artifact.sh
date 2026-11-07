#!/usr/bin/env bash
set -euo pipefail

fedora=registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d
koji=https://kojipkgs.fedoraproject.org/packages
key=6d9f90a6
repo=https://github.com/seilent/blockie-image

fail() { echo "source-artifact: $*" >&2; exit 1; }

(( $# >= 4 )) || { echo "usage: source-artifact.sh <srpms.tsv> <outdir> <full|base> <package repo@digest>..." >&2; exit 2; }
tsv=$1
out=$2
mode=$3
shift 3
source_type=application/vnd.blockie.source.v1
[[ $mode == full || $mode == base ]] || fail "mode is $mode, not full or base"
[[ -s $tsv ]] || fail "$tsv is empty"

declare -A refs
for ref in "$@"; do
  [[ $ref =~ ^[a-z0-9./-]+/pkg/([a-z0-9][a-z0-9-]*)@sha256:[0-9a-f]{64}$ ]] || fail "bad package ref $ref"
  [[ -z ${refs[${BASH_REMATCH[1]}]:-} ]] || fail "two refs for ${BASH_REMATCH[1]}"
  refs[${BASH_REMATCH[1]}]=$ref
done

root=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$out"
out=$(cd "$out" && pwd)
[[ -z $(ls -A "$out") ]] || fail "$out is not empty"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

awk '$1 == "Name:" { print $2 }' "$root"/packages/*/*.spec | sort -u > "$tmp/own"
[[ -s $tmp/own ]] || fail "no spec names under packages/"

sha=$(git -C "$root" rev-parse HEAD)
short=${sha::7}
git -C "$root" archive --format=tar.gz --prefix=blockie-image/ -o "$out/blockie-image-$short.tar.gz" HEAD
printf '%s %s\n' "blockie-image-$short.tar.gz" "$repo/tree/$sha" > "$tmp/origins"

nevra='^([A-Za-z0-9][A-Za-z0-9._+~^-]*)-([A-Za-z0-9._+~^]+)-([A-Za-z0-9._+~^]+)\.src\.rpm$'
: > "$tmp/upstream"
for env in "$root"/packages/*/SOURCE.env; do
  url=$(sed -n 's/^SRPM_URL=//p' "$env")
  [[ -n $url ]] || continue
  want=$(sed -n 's/^SRPM_SHA256=//p' "$env")
  f=${url##*/}
  [[ $want =~ ^[0-9a-f]{64}$ && $f != *..* && $f =~ $nevra ]] || fail "bad SRPM_URL or SRPM_SHA256 in $env"
  echo "${BASH_REMATCH[1]}" >> "$tmp/own"
  curl -fsSL --retry 5 --retry-all-errors -o "$out/$f" "$url" || fail "$f download failed"
  [[ $(sha256sum < "$out/$f" | cut -d' ' -f1) == "$want" ]] || fail "$f is not sha256 $want"
  printf '%s %s\n' "$f" "$url" >> "$tmp/origins"
  echo "$f" >> "$tmp/upstream"
done

for pins in "$root"/packages/*/SOURCE.sha256; do
  [[ -f $pins ]] || continue
  name=${pins%/SOURCE.sha256}
  name=${name##*/}
  ref=${refs[$name]:-}
  [[ -n $ref ]] || fail "$name pins a source and has no package ref"
  repo=${ref%@*}
  want=$(awk '{ print $2 " sha256:" $1 }' "$pins" | LC_ALL=C sort)
  [[ -n $want ]] || fail "$pins is empty"
  while read -r f _; do
    [[ $f =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && ! -e $out/$f ]] || fail "bad or repeated source file $f in $pins"
  done <<< "$want"
  art=$("$root/build/source-referrer.sh" "$ref" "$pins") ||
    fail "no $source_type referrer on $ref holds the files of packages/$name/SOURCE.sha256"
  while read -r f layer; do
    oras blob fetch --output "$out/$f" "$repo@$layer"
    [[ sha256:$(sha256sum < "$out/$f" | cut -d' ' -f1) == "$layer" ]] || fail "$f from $repo@$layer is not $layer"
    printf '%s %s\n' "$f" "$repo@$art" >> "$tmp/origins"
  done <<< "$want"
done

: > "$tmp/srpms"
if [[ $mode == full ]]; then
  awk -F'\t' 'NR == FNR { own[$1] = 1; next } { n = $2; sub(/-[^-]*-[^-]*\.src\.rpm$/, "", n) }
    !(n in own) && $2 != "(none)" { print $2 }' "$tmp/own" "$tsv" \
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
fi
n=$(cat "$tmp/upstream" "$tmp/srpms" | wc -l)
if (( n )); then
  podman run --rm -v "$out:/src:ro" "$fedora" sh -c 'cd /src && rpm -K -- *.src.rpm' > "$tmp/rpmk" \
    || { grep -v ': digests signatures OK$' "$tmp/rpmk" >&2; fail "rpm -K failed"; }
  [[ $(grep -c ': digests signatures OK$' "$tmp/rpmk") == "$n" ]] || fail "rpm -K did not pass every source rpm"
fi

sort "$tmp/origins" | while read -r f url; do
  printf '%s %s %s\n' "$f" "$(sha256sum < "$out/$f" | cut -d' ' -f1)" "$url"
done > "$tmp/SOURCES"
[[ $(find "$out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort) == "$(cut -d' ' -f1 "$tmp/SOURCES")" ]] || fail "files in $out differ from SOURCES"
mv "$tmp/SOURCES" "$out/SOURCES"

echo "source-artifact: $mode, $(wc -l < "$out/SOURCES") files, $(du -sb "$out" | cut -f1) bytes"
