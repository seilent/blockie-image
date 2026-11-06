#!/usr/bin/env bash
set -euo pipefail

fail() { echo "root: $*" >&2; exit 1; }

t=${1:?usage: root.sh <installed sysroot> <image digest>}
t=${t%/}
digest=${2:?usage: root.sh <installed sysroot> <image digest>}

[[ $(readlink "$t/boot/loader") == loader.[01] ]] || fail "/boot/loader is $(readlink "$t/boot/loader"), not loader.0 or loader.1"
shopt -s nullglob
entries=("$t"/boot/loader/entries/*.conf)
(( ${#entries[@]} == 1 )) || fail "expected one BLS entry, found ${#entries[@]}"
link=$(sed -n 's/^options[[:space:]]\+//p' "${entries[0]}" | tr ' ' '\n' | sed -n 's/^ostree=//p')
[[ $link =~ ^/ostree/boot\.[01]/default/[0-9a-f]{64}/0$ ]] || fail "bootlink '$link'"
d=$(readlink -f "$t$link")
[[ $d =~ ^$t/ostree/deploy/default/deploy/[0-9a-f]{64}\.0$ ]] || fail "$link resolves to $d"
for f in usr/lib/systemd/systemd usr/lib/ostree/ostree-prepare-root; do
  [[ -x $d/$f ]] || fail "$f missing in the deployment"
done
[[ -f $d/usr/lib/ld-linux-aarch64.so.1 ]] || fail "the loader is missing in the deployment"
grep -qx 'container-image-reference=ostree-unverified-image:oci:/var/lib/blockie/oci:testing' "$d.origin" \
  || fail "origin: $(grep container-image-reference "$d.origin" || echo none)"
cmp -s /etc/containers/policy.json "$d/etc/containers/policy.json" || fail "the deployment's policy.json is not the image's"

[[ $(ostree config --repo "$t/ostree/repo" get sysroot.bootloader) == none ]] || fail "sysroot.bootloader is not none"
csum=${d##*/}
csum=${csum%.0}
got=$(ostree show --repo "$t/ostree/repo" --print-metadata-key=ostree.manifest-digest "$csum" | tr -d "'")
[[ $got == "$digest" ]] || fail "the deployment's manifest digest is $got, not $digest"

for p in boot/efi boot/grub2 boot/loader/grub.cfg; do
  [[ ! -e $t/$p ]] || fail "$p exists"
done

/tests/blobs.sh "$d"
[[ ! -e $t/ostree/deploy/default/var/lib/blockie/secrets ]] || fail "the stateroot /var holds a secrets dir"
echo "root: ok ${csum::12}"
