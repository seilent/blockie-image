#!/usr/bin/env bash
set -euo pipefail

fail() { echo "source-artifact test: $*" >&2; exit 1; }

here=$(cd "$(dirname "$0")/.." && pwd)
script=$(realpath "${1:-$here/build/source-artifact.sh}")
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT

mkdir -p "$t/data/other" "$t/bin"
printf 'kernel source\n' > "$t/data/blockie-kernel-source.tar.gz"
printf 'foo source\n' > "$t/data/foo-1.tar.gz"
printf 'foo extra\n' > "$t/data/foo-extra-1.tar.gz"
printf 'other foo source\n' > "$t/data/other/foo-1.tar.gz"
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
case "$1 $2" in
"discover --artifact-type") r=${6%@*}; printf '{"referrers":[%s]}\n' "$(paste -sd, "$FAKE_STORE/${r##*/}.refs")" ;;
"manifest fetch") cat "$FAKE_STORE/${3#*@sha256:}.json" ;;
"blob fetch") cp "$FAKE_STORE/${5#*@sha256:}" "$4" ;;
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
export PATH=$t/bin:$PATH FAKE_URLS=$t/urls

attach() {
  local name=$1 layers="" f h m
  shift
  for f in "$@"; do
    h=$(sum "$f")
    cp "$f" "$FAKE_STORE/$h"
    layers+=${layers:+,}$(printf '{"digest":"sha256:%s","annotations":{"org.opencontainers.image.title":"%s"}}' "$h" "${f##*/}")
  done
  m=$(printf '{"layers":[%s]}' "$layers")
  h=$(printf '%s' "$m" | sha256sum | cut -d' ' -f1)
  printf '%s\n' "$m" > "$FAKE_STORE/$h.json"
  printf '{"digest":"sha256:%s"}\n' "$h" >> "$FAKE_STORE/$name.refs"
  echo "sha256:$h"
}

fixture() {
  local r=$1 sha=$2
  rm -rf "${r:?}"
  mkdir -p "$r/build" "$r/packages/kernel" "$r/packages/bootc" "$r/packages/foo"
  cp "$script" "$r/build/source-artifact.sh"
  cp "$here/build/source-referrer.sh" "$r/build/"
  printf '%s  blockie-kernel-source.tar.gz\n' "$(sum "$t/data/blockie-kernel-source.tar.gz")" > "$r/packages/kernel/SOURCE.sha256"
  printf '%s  %s\n' "$(sum "$t/data/foo-1.tar.gz")" foo-1.tar.gz "$(sum "$t/data/foo-extra-1.tar.gz")" foo-extra-1.tar.gz \
    > "$r/packages/foo/SOURCE.sha256"
  printf 'SRPM_URL=%s\nSRPM_SHA256=%s\n' "$srpm_url" "$sha" > "$r/packages/bootc/SOURCE.env"
  printf 'Name: foo\n' > "$r/packages/foo/foo.spec"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

printf '%s\t%s\n' bootc bootc-1.17.1-1.fc44.blockie.src.rpm system-reinstall-bootc bootc-1.17.1-1.fc44.blockie.src.rpm \
  setup setup-2.15.0-28.fc44.src.rpm foo foo-1-1.fc44.src.rpm foo-libs foo-1-1.fc44.src.rpm > "$t/srpms.tsv"
kref=ghcr.io/seilent/blockie/pkg/kernel@sha256:$(printf k | sha256sum | cut -d' ' -f1)
fref=ghcr.io/seilent/blockie/pkg/foo@sha256:$(printf f | sha256sum | cut -d' ' -f1)
store() {
  export FAKE_STORE=$t/store-$1
  rm -rf "${FAKE_STORE:?}"
  mkdir -p "$FAKE_STORE"
  : > "$FAKE_STORE/kernel.refs"
  : > "$FAKE_STORE/foo.refs"
  attach kernel "$t/data/blockie-kernel-source.tar.gz" > /dev/null
}
must_fail() {
  local name=$1 want=$2
  shift 2
  if "$@" > "$t/$name.log" 2>&1; then
    fail "$name passed"
  fi
  grep -qF -- "$want" "$t/$name.log" || fail "$name failed for another reason: $(tail -1 "$t/$name.log")"
}

store good
attach foo "$t/data/other/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz" > /dev/null
fart=$(attach foo "$t/data/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz")
fixture "$t/repo" "$(sum "$t/data/bootc")"
for mode in full base; do
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-$mode" "$mode" "$kref" "$fref" > "$t/$mode.log" 2>&1 ||
    fail "$mode: $(tail -1 "$t/$mode.log")"
done
want="bootc-1.17.1-1.fc44.src.rpm $(sum "$t/data/bootc") $srpm_url"
grep -qxF "$want" "$t/out-full/SOURCES" || fail "full: no upstream bootc SRPM line from SRPM_URL"
grep -qxF "$want" "$t/out-base/SOURCES" || fail "base: no upstream bootc SRPM line from SRPM_URL"
grep -qxF "setup-2.15.0-28.fc44.src.rpm $(sum "$t/data/setup") $koji_setup" "$t/out-full/SOURCES" ||
  fail "full: setup is not from koji"
! grep -q 'blockie\.src\.rpm\|^foo-1-' "$t/out-full/SOURCES" || fail "full: an own package was fetched"
for mode in full base; do
  for f in foo-1.tar.gz foo-extra-1.tar.gz; do
    grep -qxF "$f $(sum "$t/data/$f") ${fref%@*}@$fart" "$t/out-$mode/SOURCES" || fail "$mode: no $f line from the foo referrer"
    cmp -s "$t/data/$f" "$t/out-$mode/$f" || fail "$mode: $f differs"
  done
  grep -q '^blockie-kernel-source\.tar\.gz .* ghcr\.io/seilent/blockie/pkg/kernel@sha256:' "$t/out-$mode/SOURCES" ||
    fail "$mode: no kernel source line"
done
[[ $(wc -l < "$t/out-full/SOURCES") == 6 && $(wc -l < "$t/out-base/SOURCES") == 5 ]] || fail "SOURCES line counts"

must_fail noref "foo pins a source and has no package ref" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-noref" base "$kref"
must_fail twice "two refs for foo" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-twice" base "$kref" "$fref" "$fref"
must_fail badref "bad package ref" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-badref" base "$kref" "ghcr.io/seilent/blockie/foo@${fref#*@}"

store partial
attach foo "$t/data/foo-1.tar.gz" > /dev/null
attach foo "$t/data/other/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz" > /dev/null
must_fail partial "no application/vnd.blockie.source.v1 referrer on $fref holds the files of packages/foo/SOURCE.sha256" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-partial" base "$kref" "$fref"

store swapped
attach foo "$t/data/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz" > /dev/null
cp "$t/data/other/foo-1.tar.gz" "$FAKE_STORE/$(sum "$t/data/foo-1.tar.gz")"
must_fail swapped "foo-1.tar.gz from ${fref%@*}@sha256:$(sum "$t/data/foo-1.tar.gz") is not" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-swapped" base "$kref" "$fref"

store nokernel
: > "$FAKE_STORE/kernel.refs"
attach foo "$t/data/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz" > /dev/null
must_fail nokernel "no application/vnd.blockie.source.v1 referrer on $kref holds" \
  "$t/repo/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-nokernel" base "$kref" "$fref"

store good2
attach foo "$t/data/foo-1.tar.gz" "$t/data/foo-extra-1.tar.gz" > /dev/null
fixture "$t/bad" "$(sum "$t/data/setup")"
must_fail badsrpm "is not sha256" "$t/bad/build/source-artifact.sh" "$t/srpms.tsv" "$t/out-bad" base "$kref" "$fref"

echo "source-artifact test: ok"
