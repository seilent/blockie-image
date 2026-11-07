#!/usr/bin/env bash
set -u

if [[ $(id -u) == 0 ]]; then
  echo "ci-host: refuses to run as root"
  exit 1
fi
here=$(cd "$(dirname "$0")/.." && pwd)
disk=$here/build/ci-disk.sh
need=$here/build/ci-need.sh
plan=$here/build/pkg-plan.sh
cache=$here/build/source-cache.sh
seal=$here/build/root-seal.sh
state=$here/build/repo-state.sh
builder=$here/build/pkg-builder.sh
top=$(mktemp -d "${TMPDIR:-/tmp}/ci-host.XXXXXX")
trap 'rm -rf "${top:?}"' EXIT
fails=0

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

fake() {
  rm -f "${bin:?}/$1"
  printf '#!%s\n%s\n' "$BASH" "$2" > "$bin/$1"
  chmod 755 "$bin/$1"
}

setup() {
  d=$top/$1
  bin=$d/bin
  mkdir -p "$bin"
  local t
  for t in tail tr grep; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  : > "$d/calls"
  fake sudo "echo \"\$*\" >> '$d/calls'"
}

run() {
  out=$(PATH=$bin BUSYBOX=$bin/busybox "$BASH" "$@" 2>&1)
  rc=$?
}

has() { grep -qF -- "$1" <<< "$out"; }

is() { [[ $1 == "$2" ]]; }

df_fake() {
  fake df "echo \"\$*\" >> '$d/df.args'; echo '   Avail'; echo '$1'"
}

if [[ -z ${CI_HOST_INNER:-} ]]; then
  setup h_root
  fake id 'echo 0'
  out=$(CI_HOST_INNER=1 PATH=$bin:$PATH "$BASH" "$here/tests/ci-host.sh" 2>&1)
  rc=$?
  is "$rc" 1 && is "$out" 'ci-host: refuses to run as root'; res $? "host test: refuses to run as root, before any fake is written"
fi

setup d_low
df_fake 39000000000
run "$disk" 40
[[ $rc == 1 ]] && has '::error::/ has 39 GB free, below 40 GB'; res $? "disk: 39 GB free fails the 40 GB guard"

setup d_high
df_fake 41000000000
run "$disk" 40
[[ $rc == 0 ]] && has 'ci-disk: / has 41000000000 bytes free (41 GB), minimum 40 GB'; res $? "disk: 41 GB free passes"

setup d_edge
df_fake 40000000000
run "$disk" 40
is "$rc" 0; res $? "disk: exactly 40 GB passes"

setup d_path
df_fake 41000000000
run "$disk" 40 /data
is "$rc" 0 && is "$(< "$d/df.args")" '-B1 --output=avail /data'; res $? "disk: df asked for the given path in bytes"

setup d_garbage
df_fake 'n/a'
run "$disk" 40
[[ $rc == 1 ]] && has "::error::ci-disk: no free space figure for /: 'n/a'"; res $? "disk: unparsable df output fails"

setup d_dffail
fake df 'exit 1'
run "$disk" 40
! is "$rc" 0; res $? "disk: a failing df fails"

setup d_badmin
df_fake 41000000000
run "$disk" 4x
[[ $rc == 1 ]] && has "::error::ci-disk: minimum '4x' is not a number of GB"; res $? "disk: a bad minimum fails"

setup d_nomin
run "$disk"
! is "$rc" 0; res $? "disk: no minimum fails"

need_setup() {
  setup "$1"
  : > "$d/provides"
  echo static > "$d/bbkind"
  local chmod_bin
  chmod_bin=$(command -v chmod)
  cat > "$bin/sudo" << EOF
#!$BASH
echo "\$*" >> '$d/calls'
[[ \$1 == apt-get && \$2 == install ]] || exit 0
shift 3
for p in "\$@"; do
  while read -r pk c; do
    [[ \$pk == "\$p" ]] || continue
    printf '#!%s\nexit 0\n' '$BASH' > '$bin'/"\$c"
    '$chmod_bin' 755 '$bin'/"\$c"
    [[ \$c != busybox ]] || echo static > '$d/bbkind'
  done < '$d/provides'
done
EOF
  cat > "$bin/file" << EOF
#!$BASH
echo "\$*" >> '$d/file.args'
case \$(< '$d/bbkind') in
  static) echo 'ELF 64-bit LSB executable, ARM aarch64, version 1 (GNU/Linux), statically linked, stripped' ;;
  pie) echo 'ELF 64-bit LSB pie executable, ARM aarch64, version 1 (GNU/Linux), static-pie linked, stripped' ;;
  *) echo 'ELF 64-bit LSB pie executable, ARM aarch64, version 1 (GNU/Linux), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1' ;;
esac
EOF
  chmod 755 "$bin/sudo" "$bin/file"
}

calls() { [[ $(< "$d/calls") == "$1" ]]; }

need_setup n_all
fake podman 'exit 0'
fake skopeo 'exit 0'
run "$need" podman:podman skopeo:skopeo
[[ $rc == 0 && ! -s $d/calls ]] && has 'ci-need: present: podman skopeo'; res $? "need: all present, no apt call"

need_setup n_missing
fake podman 'exit 0'
echo 'skopeo skopeo' > "$d/provides"
run "$need" podman:podman skopeo:skopeo
[[ $rc == 0 ]] && calls $'apt-get update\napt-get install -y skopeo' && has 'ci-need: installed skopeo'; res $? "need: a missing tool is installed by its package"

need_setup n_two
printf 'e2fsprogs mkfs.ext4\npigz pigz\n' > "$d/provides"
run "$need" mkfs.ext4:e2fsprogs pigz:pigz
[[ $rc == 0 ]] && calls $'apt-get update\napt-get install -y e2fsprogs pigz'; res $? "need: two missing tools in one install"

need_setup n_still
run "$need" skopeo:skopeo
[[ $rc == 1 ]] && has '::error::ci-need: still missing after apt-get: skopeo:skopeo'; res $? "need: a tool still missing after apt-get fails the step"

need_setup n_static
fake busybox 'exit 0'
run "$need" busybox:busybox-static
[[ $rc == 0 && ! -s $d/calls ]] && is "$(< "$d/file.args")" "-b $bin/busybox"; res $? "need: a static busybox at \$BUSYBOX counts as present"

need_setup n_pie
fake busybox 'exit 0'
echo pie > "$d/bbkind"
echo 'busybox-static busybox' > "$d/provides"
run "$need" busybox:busybox-static
[[ $rc == 0 ]] && calls $'apt-get update\napt-get install -y busybox-static'; res $? "need: a static-pie busybox is not what ostree-root.sh takes, busybox-static is installed"

need_setup n_dynamic
fake busybox 'exit 0'
echo dynamic > "$d/bbkind"
echo 'busybox-static busybox' > "$d/provides"
run "$need" busybox:busybox-static file:file
[[ $rc == 0 ]] && calls $'apt-get update\napt-get install -y busybox-static'; res $? "need: a dynamic busybox installs busybox-static"

need_setup n_bbabsent
echo 'busybox-static busybox' > "$d/provides"
run "$need" busybox:busybox-static
[[ $rc == 0 ]] && calls $'apt-get update\napt-get install -y busybox-static'; res $? "need: no busybox installs busybox-static"

need_setup n_bbstill
fake busybox 'exit 0'
echo dynamic > "$d/bbkind"
run "$need" busybox:busybox-static
[[ $rc == 1 ]] && has '::error::ci-need: still missing after apt-get: busybox:busybox-static'; res $? "need: a busybox still dynamic after apt-get fails the step"

need_setup n_sudofail
fake sudo 'exit 100'
run "$need" skopeo:skopeo
is "$rc" 100; res $? "need: a failed apt-get fails the step"

need_setup n_pairs
for p in podman podman: :podman a:b:c; do
  run "$need" "$p"
  [[ $rc == 2 && ! -s $d/calls ]] && has "::error::ci-need: bad pair '$p'"; res $? "need: bad pair '$p' refused"
done
run "$need" skopeo:skopeo podman
is "$rc" 2 && is "$(< "$d/calls")" ''; res $? "need: a bad pair after a missing tool is refused before apt-get"

need_setup n_noargs
run "$need"
is "$rc" 2; res $? "need: no pairs refused"

plan_setup() {
  setup "$1"
  local tool
  for tool in git cut head cat realpath dirname sort sha256sum sed awk jq; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  ln -sf "$BASH" "$bin/bash"
  r=$d/repo
  mkdir -p "$r/build" "$r/system_files/usr/share/blockie/keys"
  cp "$plan" "$here/build/pkg-hash.sh" "$r/build/"
  echo key > "$r/system_files/usr/share/blockie/keys/blockie.pub"
  local p
  for p in a b c; do
    mkdir -p "$r/packages/$p"
    echo "echo $p" > "$r/packages/$p/build.sh"
  done
  echo 'built on the build PC' > "$r/packages/c/LOCAL"
  printf 'a signed\nb signed\nc signed\n' > "$d/cfg"
  cat > "$bin/skopeo" << EOF
#!$BASH
if [[ \$1 == login ]]; then echo login >> '$d/calls'; exit 0; fi
ref=\${*: -1}
name=\${ref##*/pkg/}
name=\${name%%:*}
st=\$(awk -v n="\$name" '\$1 == n { print \$2 }' '$d/cfg')
creds=1
[[ " \$* " != *" --no-creds "* ]] || creds=0
case \$st in
  missing) echo 'manifest unknown' >&2; exit 1 ;;
  private) (( creds )) && exit 0; echo 'unauthorized' >&2; exit 1 ;;
  error) echo 'connection refused' >&2; exit 1 ;;
esac
exit 0
EOF
  cat > "$bin/cosign" << EOF
#!$BASH
ref=\${*: -1}
name=\${ref##*/pkg/}
name=\${name%%:*}
echo "\$name" >> '$d/cosign.calls'
case \$(awk -v n="\$name" '\$1 == n { print \$2 }' '$d/cfg') in
  unsigned) echo 'Error: no signatures found' >&2; exit 1 ;;
  cosignerr) echo 'Error: network is unreachable' >&2; exit 1 ;;
esac
exit 0
EOF
  fake sleep "echo sleep >> '$d/calls'"
  chmod 755 "$bin/skopeo" "$bin/cosign"
  git -C "$r" init -q
  git -C "$r" add -A
}

plan_run() {
  out=$(cd "$d" && PATH=$bin GH_ACTOR=actor GH_TOKEN=token "$BASH" "$r/build/pkg-plan.sh" "$d/build.json" 2>&1)
  rc=$?
}

built() { [[ $(< "$d/build.json") == "$1" ]]; }

plan_setup p_signed
plan_run
[[ $rc == 0 ]] && built '[]' && ! grep -q login "$d/calls" && has 'pkg/a:' && has 'exists, signed'; res $? "plan: every package signed builds nothing"

plan_setup p_missing
printf 'a missing\nb signed\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 0 ]] && built '[{"package":"a","state":"missing"}]' && is "$(grep -c login "$d/calls")" 1; res $? "plan: a missing package is built, the login happens once"

plan_setup p_twomissing
printf 'a missing\nb missing\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 0 ]] && built '[{"package":"a","state":"missing"},{"package":"b","state":"missing"}]' && is "$(grep -c login "$d/calls")" 1; res $? "plan: two missing packages, one login"

plan_setup p_unsigned
printf 'a signed\nb unsigned\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 0 ]] && built '[{"package":"b","state":"unsigned"}]' && has '::warning::ghcr.io/seilent/blockie/pkg/b:' && has 'has no valid signature'; res $? "plan: an unsigned package is rebuilt"

plan_setup p_local
printf 'a signed\nb signed\nc missing\n' > "$d/cfg"
plan_run
[[ $rc == 0 ]] && built '[]' && has '::notice::ghcr.io/seilent/blockie/pkg/c:' && has 'built on the build PC'; res $? "plan: a missing LOCAL package is left to the build PC"

plan_setup p_localunsigned
printf 'a signed\nb signed\nc unsigned\n' > "$d/cfg"
plan_run
[[ $rc == 0 ]] && built '[]' && has '::notice::'; res $? "plan: an unsigned LOCAL package is left to the build PC"

plan_setup p_private
printf 'a private\nb signed\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 1 ]] && has 'exists but is not public'; res $? "plan: a package readable only with credentials fails"

plan_setup p_error
printf 'a error\nb signed\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 1 ]] && has '::error::connection refused'; res $? "plan: a registry error fails"

plan_setup p_cosignerr
printf 'a cosignerr\nb signed\nc signed\n' > "$d/cfg"
plan_run
[[ $rc == 1 && $(grep -c sleep "$d/calls") == 3 ]] && has '::error::cosign verify'; res $? "plan: cosign failing three times fails, it does not count as signed"

plan_setup p_deps
echo a > "$r/packages/b/DEPS"
git -C "$r" add -A
plan_run
[[ $rc == 1 ]] && has 'packages/b has DEPS'; res $? "plan: DEPS refused"

plan_setup p_relative
printf 'a missing\nb signed\nc signed\n' > "$d/cfg"
out=$(cd "$d" && PATH=$bin GH_ACTOR=actor GH_TOKEN=token "$BASH" "$r/build/pkg-plan.sh" rel.json 2>&1)
rc=$?
is "$rc" 0 && is "$(< "$d/rel.json")" '[{"package":"a","state":"missing"}]'; res $? "plan: a relative output path is taken from the caller's directory"

cache_setup() {
  setup "$1"
  local tool i
  for tool in git jq realpath dirname mktemp rm find wc mkdir cp cat; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  ln -sf "$BASH" "$bin/bash"
  r=$d/repo
  reg=$d/reg
  mkdir -p "$r/build" "$reg/tags" "$reg/man" "$reg/blobs"
  cp "$cache" "$r/build/"
  echo key > "$d/blockie.pub"
  : > "$reg/bad"
  : > "$d/discover.calls"
  git -C "$r" init -q
  for i in 0 1 2 3 4 5 6 7; do
    echo "$i" > "$r/f"
    git -C "$r" add -A
    git -C "$r" -c user.name=t -c user.email=t@invalid commit -q -m "c$i"
  done
  cat > "$bin/oras" << EOF
#!$BASH
case \$1 in
  discover)
    ref=\${*: -1}
    tag=\${ref##*:}
    echo "\$tag" >> '$d/discover.calls'
    [[ -f '$reg/tags/'\$tag ]] || { echo 'Error: not found' >&2; exit 1; }
    jq -nc --rawfile l '$reg/tags/'\$tag '{referrers: (\$l | split("\n") | map(select(length > 0)) | map({digest: .}))}'
    ;;
  manifest)
    cat '$reg/man/'\${3##*@sha256:}
    ;;
  blob)
    h=\${5##*@sha256:}
    [[ -f '$reg/blobs/'\$h ]] || { echo partial > "\$4"; exit 1; }
    cp '$reg/blobs/'\$h "\$4"
    ;;
esac
EOF
  cat > "$bin/cosign" << EOF
#!$BASH
ref=\${*: -1}
! grep -qxF "\${ref##*@}" '$reg/bad'
EOF
  chmod 755 "$bin/oras" "$bin/cosign"
}

blob() {
  local h
  h=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
  printf '%s' "$1" > "$reg/blobs/$h"
  echo "$h"
}

artifact() {
  local tag=$1 sources=$2 title=${3:-SOURCES} s m
  s=$(blob "$sources"$'\n')
  m=$(printf '%s' "manifest $tag $s $title" | sha256sum | cut -d' ' -f1)
  jq -nc --arg d "sha256:$s" --arg t "$title" '{layers: [{digest: $d, annotations: {"org.opencontainers.image.title": $t}}]}' > "$reg/man/$m"
  echo "sha256:$m" >> "$reg/tags/$tag"
  echo "sha256:$m"
}

srpms() {
  local a b
  a=$(blob alpha)
  b=$(blob beta)
  printf 'alpha-1.0-1.fc44.src.rpm %s https://koji/a\nbeta-2.0-3.fc44.src.rpm %s https://koji/b\n' "$a" "$b"
}

cache_run() {
  out=$(cd "$r" && PATH=$bin IMAGE=ghcr.io/seilent/blockie SOURCE_TYPE=application/vnd.blockie.source.v1 PUBKEY=$d/blockie.pub "$BASH" "$r/build/source-cache.sh" "$d/cache" 2>&1)
  rc=$?
}

anc() { git -C "$r" rev-parse --short=7 "HEAD~$1"; }

cached() { [[ $(cd "$d/cache" 2> /dev/null && find . -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ') == "$1" ]]; }

cache_setup s_testing
artifact testing "$(srpms)" > /dev/null
cache_run
is "$rc" 0 && cached 'alpha-1.0-1.fc44.src.rpm beta-2.0-3.fc44.src.rpm ' && is "$(tail -n 1 "$d/discover.calls")" testing && is "$(wc -l < "$d/discover.calls")" 6 && has '2 source rpms from ghcr.io/seilent/blockie:testing'; res $? "cache: testing, tried last, fills the cache when no ancestor has SOURCES"

cache_setup s_ancestor
artifact "testing-$(anc 2)" "$(srpms)" > /dev/null
cache_run
is "$rc" 0 && cached 'alpha-1.0-1.fc44.src.rpm beta-2.0-3.fc44.src.rpm ' && is "$(< "$d/discover.calls")" "$(printf 'testing-%s\ntesting-%s' "$(anc 1)" "$(anc 2)")" && has "from ghcr.io/seilent/blockie:testing-$(anc 2)"; res $? "cache: missing tags move on to the next main ancestor"

cache_setup s_unsigned
artifact "testing-$(anc 1)" "$(srpms)" >> "$reg/bad"
artifact "testing-$(anc 2)" "$(srpms)" > /dev/null
cache_run
is "$rc" 0 && has '::warning::' && has 'fails cosign verify, not used' && has "from ghcr.io/seilent/blockie:testing-$(anc 2)"; res $? "cache: a referrer failing cosign verify is not used"

cache_setup s_newest
artifact testing "$(srpms)" > /dev/null
artifact "testing-$(anc 1)" "$(srpms)" > /dev/null
cache_run
is "$rc" 0 && is "$(< "$d/discover.calls")" "testing-$(anc 1)" && has "from ghcr.io/seilent/blockie:testing-$(anc 1)"; res $? "cache: the newest main parent is used before testing"

cache_setup s_none
cache_run
is "$rc" 0 && cached '' && has '::notice::no signed source artifact' && is "$(< "$d/discover.calls")" "$(printf 'testing-%s\n' "$(anc 1)" "$(anc 2)" "$(anc 3)" "$(anc 4)" "$(anc 5)"; echo testing)"; res $? "cache: five ancestors newest first, then testing, not HEAD, none found"

cache_setup s_notitle
artifact "testing-$(anc 1)" "$(srpms)" OTHER > /dev/null
artifact "testing-$(anc 2)" "$(srpms)" > /dev/null
cache_run
is "$rc" 0 && has "from ghcr.io/seilent/blockie:testing-$(anc 2)"; res $? "cache: a referrer without a SOURCES layer is skipped"

cache_setup s_badlines
good=$(blob gamma)
artifact testing "$(printf '../evil-1-1.src.rpm %s u\ndir/a-1-1.src.rpm %s u\nb-1-1.src.rpm nothex u\nc.rpm %s u\ngamma-1-1.fc44.src.rpm %s u\n' "$good" "$good" "$good" "$good")" > /dev/null
cache_run
is "$rc" 0 && cached 'gamma-1-1.fc44.src.rpm ' && [[ ! -e $d/evil-1-1.src.rpm ]]; res $? "cache: names outside the NEVRA pattern, paths and bad sums are not fetched"

cache_setup s_lostblob
a=$(blob alpha)
artifact testing "$(printf 'alpha-1.0-1.fc44.src.rpm %s u\nlost-1-1.fc44.src.rpm %s u\n' "$a" "$(printf 'f%.0s' {1..64})")" > /dev/null
cache_run
is "$rc" 0 && cached 'alpha-1.0-1.fc44.src.rpm '; res $? "cache: a blob that cannot be fetched leaves no file"

seal_setup() {
  setup "$1"
  local tool
  for tool in head sha256sum tee cut mktemp rm cat date; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  zip=$(command -v pigz || command -v gzip)
  fake pigz "exec '$zip' \"\$@\""
  img=$d/root.ext4
  head -c 1048576 /dev/urandom > "$img"
  head -c 2097152 /dev/zero >> "$img"
  head -c 70000 /dev/urandom >> "$img"
}

seal_run() {
  out=$(PATH=$bin "$BASH" "$seal" "$img" "$d/root.ext4.gz" 2> "$d/err")
  rc=$?
}

seal_setup r_ok
seal_run
want=$(printf 'ROOT_GZ_SHA=%s\nROOT_SHA=%s\nROOT_HEAD_SHA=%s\nROOT_BODY_SHA=%s' \
  "$(sha256sum < "$d/root.ext4.gz" | cut -d' ' -f1)" "$(sha256sum < "$img" | cut -d' ' -f1)" \
  "$(head -c 1048576 "$img" | sha256sum | cut -d' ' -f1)" "$(tail -c +1048577 "$img" | sha256sum | cut -d' ' -f1)")
is "$rc" 0 && is "$out" "$want" && cmp -s <("$zip" -dc "$d/root.ext4.gz") "$img" && grep -qE '^root-seal: ms from start: head [0-9]+, whole [0-9]+, body [0-9]+, compress [0-9]+, unpack [0-9]+, gz sha256 [0-9]+$' "$d/err"; res $? "seal: the four sha256s equal separate passes, the gz unpacks to the image, the part times are printed"

seal_setup r_badunpack
fake pigz "if [[ \$1 == -dc ]]; then '$zip' -dc | tr '\\0' x; else exec '$zip' \"\$@\"; fi"
seal_run
is "$rc" 1 && grep -qF 'root.ext4.gz does not unpack to the image' "$d/err"; res $? "seal: a gz that does not unpack to the image fails"

seal_setup r_tailfail
fake tail 'exit 1'
seal_run
is "$rc" 1 && grep -qF '::error::root-seal: hashing or compressing' "$d/err"; res $? "seal: a failed body hash fails"

seal_setup r_pigzfail
fake pigz 'exit 1'
seal_run
is "$rc" 1 && grep -qF '::error::root-seal: hashing or compressing' "$d/err"; res $? "seal: a failed compression fails"

seal_setup r_nosum
fake sha256sum "cat > /dev/null; echo 'garbage  -'"
seal_run
is "$rc" 1 && grep -qF '::error::root-seal: no ' "$d/err"; res $? "seal: an unparsable sha256 fails"

state_setup() {
  setup "$1"
  local tool
  for tool in realpath mkdir sed sha256sum cut mv cat; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  mkdir -p "$d/mirror"
  cat > "$bin/curl" << EOF
#!$BASH
url=\${*: -1}
case \$url in
  *'metalink?repo=fedora-44&arch=aarch64') exec cat '$d/meta.fedora' ;;
  *'metalink?repo=updates-released-f44&arch=aarch64') exec cat '$d/meta.updates' ;;
esac
f='$d/mirror/'\$(printf '%s' "\$url" | sha256sum | cut -c1-16)
[[ -f \$f ]] || exit 22
cat "\$f"
EOF
  chmod 755 "$bin/curl"
}

serve() { printf '%s' "$2" > "$d/mirror/$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

meta() {
  local out=$1 want=$2 old=$3 u
  shift 3
  {
    echo '<metalink><files><file name="repomd.xml"><verification>'
    echo "<hash type=\"md5\">0123</hash><hash type=\"sha256\">$want</hash></verification>"
    echo "<mm0:alternates><mm0:alternate><verification><hash type=\"sha256\">$old</hash></verification></mm0:alternate></mm0:alternates>"
    echo '<resources maxconnections="1">'
    for u in "$@"; do
      echo "<url protocol=\"${u%%:*}\" type=\"${u%%:*}\" location=\"US\" preference=\"100\">$u/repodata/repomd.xml</url>"
    done
    echo '</resources></file></files></metalink>'
  } > "$out"
}

hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

state_run() {
  out=$(PATH=$bin REPO_ARCH=aarch64 "$BASH" "$state" "$d/st" 2> "$d/err")
  rc=$?
}

state_setup q_pick
meta "$d/meta.fedora" "$(hex fnew)" "$(hex fold)" https://m1/f https://m2/f
meta "$d/meta.updates" "$(hex unew)" "$(hex uold)" https://m1/u
serve https://m1/f/repodata/repomd.xml fold
serve https://m2/f/repodata/repomd.xml fnew
serve https://m1/u/repodata/repomd.xml unew
state_run
is "$rc" 0 && is "$(< "$d/st/state")" "$(printf 'fedora %s https://m2/f/\nupdates %s https://m1/u/' "$(hex fnew)" "$(hex unew)")" \
  && is "$(< "$d/st/blockie.repo")" "$(printf '[fedora]\nbaseurl=https://m2/f/\nmetalink=\nmirrorlist=\n[updates]\nbaseurl=https://m1/u/\nmetalink=\nmirrorlist=')"; res $? "repo state: only mirrors serving the current repomd are pinned"

dlf=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/os
dlu=https://dl.fedoraproject.org/pub/fedora/linux/updates/44/Everything/aarch64

state_setup q_dl
meta "$d/meta.fedora" "$(hex fnew)" "$(hex fold)" https://m1/f https://m2/f https://m3/f https://m4/f
meta "$d/meta.updates" "$(hex unew)" "$(hex uold)" https://m1/u "$dlu"
serve "$dlf/repodata/repomd.xml" fnew
serve https://m1/f/repodata/repomd.xml fnew
serve https://m2/f/repodata/repomd.xml fold
serve https://m3/f/repodata/repomd.xml fnew
serve https://m4/f/repodata/repomd.xml fnew
serve "$dlu/repodata/repomd.xml" unew
serve https://m1/u/repodata/repomd.xml unew
state_run
is "$rc" 0 && is "$(< "$d/st/state")" "$(printf 'fedora %s %s/ https://m1/f/ https://m3/f/\nupdates %s %s/ https://m1/u/' "$(hex fnew)" "$dlf" "$(hex unew)" "$dlu")" \
  && is "$(< "$d/st/blockie.repo")" "$(printf '[fedora]\nbaseurl=%s/ https://m1/f/ https://m3/f/\nmetalink=\nmirrorlist=\n[updates]\nbaseurl=%s/ https://m1/u/\nmetalink=\nmirrorlist=' "$dlf" "$dlu")"; res $? "repo state: dl.fedoraproject.org first, then up to two more current mirrors, each once"

state_setup q_dlold
meta "$d/meta.fedora" "$(hex fnew)" "$(hex fold)" https://m1/f
meta "$d/meta.updates" "$(hex unew)" "$(hex uold)" https://m1/u
serve "$dlf/repodata/repomd.xml" fold
serve https://m1/f/repodata/repomd.xml fnew
serve "$dlu/repodata/repomd.xml" unew
serve https://m1/u/repodata/repomd.xml uold
state_run
is "$rc" 0 && is "$(< "$d/st/state")" "$(printf 'fedora %s https://m1/f/\nupdates %s %s/' "$(hex fnew)" "$(hex unew)" "$dlu")"; res $? "repo state: dl.fedoraproject.org serving another repomd is skipped"

state_setup q_nomirror
meta "$d/meta.fedora" "$(hex fnew)" "$(hex fold)" https://m1/f
meta "$d/meta.updates" "$(hex unew)" "$(hex uold)" https://m1/u http://m2/u
serve https://m1/f/repodata/repomd.xml fnew
serve https://m1/u/repodata/repomd.xml uold
serve http://m2/u/repodata/repomd.xml unew
state_run
is "$rc" 1 && grep -qF 'no mirror serves the updates repomd' "$d/err" && [[ ! -e $d/st/state && ! -e $d/st/blockie.repo ]]; res $? "repo state: an alternate or a plain http mirror is not taken, nothing is written"

state_setup q_nometa
meta "$d/meta.fedora" "$(hex fnew)" "$(hex fold)" https://m1/f
serve https://m1/f/repodata/repomd.xml fnew
state_run
is "$rc" 1 && grep -qF 'no metalink for updates' "$d/err"; res $? "repo state: a missing metalink fails"

builder_setup() {
  setup "$1"
  local tool
  for tool in cut sha256sum sort mktemp rm realpath dirname cat; do
    ln -sf "$(command -v "$tool")" "$bin/$tool"
  done
  ln -sf "$BASH" "$bin/bash"
  r=$d/repo
  mkdir -p "$r/build" "$r/packages/x" "$d/st"
  cp "$builder" "$r/build/"
  echo 'FROM fedora' > "$r/build/pkg.Containerfile"
  echo 'FROM localhost/blockie-pkg-builder' > "$r/packages/x/Containerfile"
  printf '#!%s\nexit 1\n' "$BASH" > "$r/build/repo-state.sh"
  chmod 755 "$r/build/repo-state.sh"
  printf 'fedora %s https://m1/f/\nupdates %s https://m1/u/\n' "$(hex f)" "$(hex u)" > "$d/st/state"
  echo '[fedora]' > "$d/st/blockie.repo"
  echo 1 > "$d/exists"
  cat > "$bin/podman" << EOF
#!$BASH
echo "\$*" >> '$d/calls'
case \$1 in
  image) exit \$(< '$d/exists') ;;
  run) printf 'b\na\n' ;;
esac
EOF
  chmod 755 "$bin/podman"
}

builder_run() {
  out=$(cd "$r" && PATH=$bin BLOCKIE_REPO_STATE=${st_env-$d/st} "$BASH" "$r/build/pkg-builder.sh" "$@" 2> "$d/err")
  rc=$?
}

bkey() { (cd "$r" && PATH=$bin BLOCKIE_REPO_STATE=$d/st "$BASH" "$r/build/pkg-builder.sh" key); }

base=localhost/blockie-pkg-builder
lim='--memory=14g --cpu-period=100000 --cpu-quota=600000'

builder_setup b_build
k=$(bkey)
builder_run build y
is "$rc" 0 && is "$out" "$base $k" && grep -qxF "build --no-cache $lim -v $d/st:/etc/dnf/repos.override.d:ro,Z -t $base:$k -t $base -f build/pkg.Containerfile build" "$d/calls" \
  && grep -qE "^pkg-builder: $base rpms [0-9a-f]{16}$" "$d/err" && [[ $k =~ ^[0-9a-f]{16}$ ]]; res $? "builder: a new repo state builds the keyed builder without the layer cache, with the pinned repos"

builder_setup b_reuse
echo 0 > "$d/exists"
k=$(bkey)
builder_run build y
is "$rc" 0 && is "$out" "$base $k" && grep -qxF "tag $base:$k $base" "$d/calls" && ! grep -q '^build' "$d/calls"; res $? "builder: a keyed builder that exists is reused, nothing is built"

builder_setup b_pkg
k=$(bkey)
builder_run build x
is "$rc" 0 && is "$out" "$base-x $k" && grep -qxF "build --from $base:$k -v $d/st:/etc/dnf/repos.override.d:ro,Z $lim -t $base-x -f packages/x/Containerfile packages/x" "$d/calls"; res $? "builder: a package builder is built from the keyed base with the pinned repos"

builder_setup b_nostate
rm -f "$d/st/state"
st_env='' builder_run build x
is "$rc" 0 && is "$out" "$base-x -" && grep -qxF "build --no-cache $lim -t $base -f build/pkg.Containerfile build" "$d/calls" \
  && grep -qxF "build $lim -t $base-x -f packages/x/Containerfile packages/x" "$d/calls" && grep -qF '::warning::pkg-builder: no repo state' "$d/err"; res $? "builder: no repo state builds without a key, a cache or the pinned repos"

builder_setup b_key
k1=$(bkey)
printf 'fedora %s https://m9/f/ https://m8/f/\nupdates %s https://m9/u/\n' "$(hex f)" "$(hex u)" > "$d/st/state"
k2=$(bkey)
printf 'fedora %s https://m9/f/\nupdates %s https://m9/u/\n' "$(hex f)" "$(hex u2)" > "$d/st/state"
k3=$(bkey)
echo 'FROM fedora2' > "$r/build/pkg.Containerfile"
k4=$(bkey)
is "$k1" "$k2" && ! is "$k2" "$k3" && ! is "$k3" "$k4"; res $? "builder: the key follows the repomd sums and the Containerfile, not the mirror"

builder_setup b_name
builder_run build ../x
is "$rc" 2 && is "$(< "$d/calls")" ''; res $? "builder: a bad package name is refused before podman"

if (( fails )); then
  echo "ci-host: $fails failed"
  exit 1
fi
echo "ci-host: ok"
