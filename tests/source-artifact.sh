#!/usr/bin/env bash
set -euo pipefail

fail() { echo "source-artifact test: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
script=$(realpath "${1:-$here/build/source-artifact.sh}")
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT

mkdir -p "$t/data" "$t/bin"
printf 'kernel source\n' > "$t/data/kernel"
printf 'bootc upstream srpm\n' > "$t/data/bootc"
printf 'setup srpm\n' > "$t/data/setup"
sum() { sha256sum < "$1" | cut -d' ' -f1; }
srpm_url=https://kojipkgs.example/packages/bootc/1.17.1/1.fc44/src/bootc-1.17.1-1.fc44.src.rpm
koji_setup=https://kojipkgs.fedoraproject.org/packages/setup/2.15.0/28.fc44/data/signed/6d9f90a6/src/setup-2.15.0-28.fc44.src.rpm
printf '%s %s\n' "$srpm_url" "$t/data/bootc" "$koji_setup" "$t/data/setup" > "$t/urls"

cat > "$t/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (( $# )); do
  case $1 in
  -o) out=$2; shift 2 ;;
  --retry | --parallel-max) shift 2 ;;
  -*) shift ;;
  *)
    f=$(awk -v u="$1" '$1 == u { print $2 }' "$FAKE_URLS")
    [[ -n $f ]] || { echo "curl: (22) The requested URL returned error: 404 $1" >&2; exit 22; }
    cp "$f" "$out"
    shift ;;
  esac
done
EOF
cat > "$t/bin/oras" <<'EOF'
#!/usr/bin/env bash
ref=sha256:$(printf r | sha256sum | cut -d' ' -f1)
layer=sha256:$(printf l | sha256sum | cut -d' ' -f1)
case "$1 $2" in
"discover --artifact-type") printf '{"referrers":[{"digest":"%s"}]}\n' "$ref" ;;
"manifest fetch") printf '{"layers":[{"digest":"%s","annotations":{"org.opencontainers.image.title":"blockie-kernel-source.tar.gz"}}]}\n' "$layer" ;;
"blob fetch") cp "$FAKE_KERNEL" "$4" ;;
*) echo "fake oras: $*" >&2; exit 2 ;;
esac
EOF
cat > "$t/bin/podman" <<'EOF'
#!/usr/bin/env bash
dir=
while (( $# )); do
  [[ $1 == -v ]] && dir=${2%%:*}
  shift
done
for f in "$dir"/*.src.rpm; do
  echo "${f##*/}: digests signatures OK"
done
EOF
chmod 755 "$t/bin/curl" "$t/bin/oras" "$t/bin/podman"
export PATH=$t/bin:$PATH FAKE_URLS=$t/urls FAKE_KERNEL=$t/data/kernel

fixture() {
  local r=$1 sha=$2
  rm -rf "${r:?}"
  mkdir -p "$r/build" "$r/packages/kernel" "$r/packages/bootc" "$r/packages/foo"
  cp "$script" "$r/build/source-artifact.sh"
  printf '%s  blockie-kernel-source.tar.gz\n' "$(sum "$t/data/kernel")" > "$r/packages/kernel/SOURCE.sha256"
  printf 'SRPM_URL=%s\nSRPM_SHA256=%s\n' "$srpm_url" "$sha" > "$r/packages/bootc/SOURCE.env"
  printf 'Name: foo\n' > "$r/packages/foo/foo.spec"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

printf '%s\t%s\n' bootc bootc-1.17.1-1.fc44.blockie.src.rpm system-reinstall-bootc bootc-1.17.1-1.fc44.blockie.src.rpm \
  setup setup-2.15.0-28.fc44.src.rpm foo foo-1-1.fc44.src.rpm foo-libs foo-1-1.fc44.src.rpm > "$t/srpms.tsv"
kref=ghcr.io/seilent/blockie/pkg/kernel@sha256:$(printf k | sha256sum | cut -d' ' -f1)

fixture "$t/repo" "$(sum "$t/data/bootc")"
for mode in full base; do
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-$mode" "$mode" "$kref" > "$t/$mode.log" 2>&1 ||
    fail "$mode: $(tail -1 "$t/$mode.log")"
done
want="bootc-1.17.1-1.fc44.src.rpm $(sum "$t/data/bootc") $srpm_url"
grep -qxF "$want" "$t/out-full/SOURCES" || fail "full: no upstream bootc SRPM line from SRPM_URL"
grep -qxF "$want" "$t/out-base/SOURCES" || fail "base: no upstream bootc SRPM line from SRPM_URL"
grep -qxF "setup-2.15.0-28.fc44.src.rpm $(sum "$t/data/setup") $koji_setup" "$t/out-full/SOURCES" ||
  fail "full: setup is not from koji"
! grep -q 'blockie\.src\.rpm\|^foo-' "$t/out-full/SOURCES" || fail "full: an own package was fetched"
[[ $(wc -l < "$t/out-full/SOURCES") == 4 && $(wc -l < "$t/out-base/SOURCES") == 3 ]] || fail "SOURCES line counts"

fixture "$t/bad" "$(sum "$t/data/setup")"
if "$t/bad/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-bad" base "$kref" > "$t/bad.log" 2>&1; then
  fail "a wrong SRPM_SHA256 passed"
fi
grep -q 'is not sha256' "$t/bad.log" || fail "a wrong SRPM_SHA256 failed for another reason: $(tail -1 "$t/bad.log")"

echo "source-artifact test: ok"
