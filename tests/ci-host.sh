#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
disk=$here/build/ci-disk.sh
need=$here/build/ci-need.sh
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

df_fake() {
  fake df "echo \"\$*\" >> '$d/df.args'; echo '   Avail'; echo '$1'"
}

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
[[ $rc == 0 ]]; res $? "disk: exactly 40 GB passes"

setup d_path
df_fake 41000000000
run "$disk" 40 /data
[[ $rc == 0 && $(cat "$d/df.args") == '-B1 --output=avail /data' ]]; res $? "disk: df asked for the given path in bytes"

setup d_garbage
df_fake 'n/a'
run "$disk" 40
[[ $rc == 1 ]] && has "::error::ci-disk: no free space figure for /: 'n/a'"; res $? "disk: unparsable df output fails"

setup d_dffail
fake df 'exit 1'
run "$disk" 40
[[ $rc != 0 ]]; res $? "disk: a failing df fails"

setup d_badmin
df_fake 41000000000
run "$disk" 4x
[[ $rc == 1 ]] && has "::error::ci-disk: minimum '4x' is not a number of GB"; res $? "disk: a bad minimum fails"

setup d_nomin
run "$disk"
[[ $rc != 0 ]]; res $? "disk: no minimum fails"

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
[[ $rc == 0 && ! -s $d/calls && $(< "$d/file.args") == "-b $bin/busybox" ]]; res $? "need: a static busybox at \$BUSYBOX counts as present"

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
[[ $rc == 100 ]]; res $? "need: a failed apt-get fails the step"

need_setup n_pairs
for p in podman podman: :podman a:b:c; do
  run "$need" "$p"
  [[ $rc == 2 && ! -s $d/calls ]] && has "::error::ci-need: bad pair '$p'"; res $? "need: bad pair '$p' refused"
done
run "$need" skopeo:skopeo podman
[[ $rc == 2 && ! -s $d/calls ]]; res $? "need: a bad pair after a missing tool is refused before apt-get"

need_setup n_noargs
run "$need"
[[ $rc == 2 ]]; res $? "need: no pairs refused"

if (( fails )); then
  echo "ci-host: $fails failed"
  exit 1
fi
echo "ci-host: ok"
