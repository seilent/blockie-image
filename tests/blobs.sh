#!/usr/bin/env bash
set -euo pipefail

fail() { echo "blobs: $*" >&2; exit 1; }

root=${1:-/}
root=${root%/}
mods=("$root"/usr/lib/modules/*)
kver=${mods[0]##*/}

bad=$(find "${root:-/}" -xdev \( -path "$root/proc" -o -path "$root/sys" -o -path "$root/dev" \) -prune -o -iname 'libmali*' -print)
[[ -z $bad ]] || fail "libmali files: $bad"

bad=$(find "${root:-/}" -xdev \( -path "$root/proc" -o -path "$root/sys" -o -path "$root/dev" \) -prune -o \
  \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) -print | grep -v "^$root/usr/lib/modules/$kver/extra/" || true)
[[ -z $bad ]] || fail "kernel modules outside extra/: $bad"

while IFS= read -r f; do
  [[ $(head -c 4 "$f" | od -An -tx1 | tr -d ' \n') != 7f454c46 ]] || fail "ELF naming libmali: $f"
done < <(grep -rlsa -- 'libmali\.so' "$root/usr" "$root/etc" || true)

[[ ! -e $root/vendor || -z $(ls -A "$root/vendor") ]] || fail "$root/vendor is not empty"

bad=$(find "$root/etc" "$root/usr" -xdev -name '*.nmconnection' -print)
[[ -z $bad ]] || fail "NetworkManager profiles: $bad"
[[ ! -e $root/var/lib/blockie/secrets ]] || fail "secrets dir present"

shopt -s nullglob
confs=("$root"/usr/share/blockie/blobs.d/*.conf)
for c in "${confs[@]}"; do
  grep -q '^SHA256=[0-9a-f]\{64\}$' "$c" || fail "${c##*/} has no SHA256= line"
done
for c in "$root"/usr/share/blockie/steam/runners.d/*.conf; do
  grep -q '^URL=' "$c" || continue
  grep -q '^SHA256=[0-9a-f]\{64\}$' "$c" || fail "runners.d/${c##*/} has a URL= line and no SHA256= line"
  confs+=("$c")
done
if (( ${#confs[@]} )); then
  sums=$(find "$root/usr" "$root/etc" -xdev -type f -size +0 -exec sha256sum {} +)
  while read -r value; do
    hits=$(awk -v h="$value" '$1 == h { print $2 }' <<< "$sums")
    [[ -z $hits ]] || fail "a pinned blob is in the image: $hits"
  done < <(sed -n 's/^SHA256=//p' "${confs[@]}")
fi

echo "blobs: ok"
