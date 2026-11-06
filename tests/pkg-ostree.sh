#!/usr/bin/env bash
set -euo pipefail

fail() { echo "pkg-ostree: $*" >&2; exit 1; }

out=${1:?usage: pkg-ostree.sh <outdir>}
shopt -s nullglob
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
mkdir -p "$t/files"
rpms=()
for n in ostree ostree-libs; do
  f=("$out/$n"-[0-9]*.rpm)
  (( ${#f[@]} == 1 )) || fail "expected one $n RPM, found ${#f[@]}"
  rpm2cpio "${f[0]}" | (cd "$t/files" && cpio -idm --quiet)
  rpms+=("${f[0]}")
done
bin=$t/files/usr/bin/ostree
[[ -x $bin ]] || fail "no usr/bin/ostree in ${rpms[0]##*/}"
ostree() { LD_LIBRARY_PATH=$t/files/usr/lib64 OSTREE_SYSROOT_DEBUG=mutable-deployments "$bin" "$@"; }
ostree --version > /dev/null || fail "ostree --version fails"

deploy_twice() {
  local name=$1 config=$2 tree=$t/$1/tree sys=$t/$1/sysroot
  mkdir -p "$tree/usr/lib/modules/0.0.0" "$tree/usr/etc/selinux" "$sys"
  printf 'kernel\n' > "$tree/usr/lib/modules/0.0.0/vmlinuz"
  printf 'initramfs\n' > "$tree/usr/lib/modules/0.0.0/initramfs.img"
  printf '%s' "$config" > "$tree/usr/etc/selinux/config"
  printf 'ID=blockie\n' > "$tree/usr/etc/os-release"
  ostree admin init-fs --modern "$sys" &&
    ostree admin stateroot-init --sysroot="$sys" blockie &&
    ostree commit --repo="$sys/ostree/repo" --no-xattrs -b "$name" --tree=dir="$tree" > /dev/null &&
    ostree admin deploy --sysroot="$sys" --os=blockie "$name" &&
    ostree admin deploy --sysroot="$sys" --os=blockie "$name" &&
    [[ $(find "$sys/ostree/deploy/blockie/deploy" -mindepth 1 -maxdepth 1 -type d | wc -l) == 2 ]]
}

err=$(deploy_twice untyped $'SELINUXTYPE=targeted\n' 2>&1) &&
  fail "test harness: the second deploy with SELinux not disabled passed, so the policy refresh was never reached: $err"
[[ $err == *"Finalizing SELinux policy"* ]] ||
  fail "test harness: the second deploy with SELinux not disabled failed before the policy refresh: $err"
err=$(deploy_twice first $'SELINUX=bogus\nSELINUX=disabled\nSELINUXTYPE=targeted\n' 2>&1) &&
  fail "the second deploy skips the policy refresh although the first SELINUX= line is not disabled: $err"
[[ $err == *"Finalizing SELinux policy"* ]] ||
  fail "the second deploy with a first SELINUX= line that is not disabled failed before the policy refresh: $err"
err=$(deploy_twice disabled $'# SELinux is off\nSELINUX=disabled\nSELINUXTYPE=targeted\n' 2>&1) ||
  fail "the second deploy with SELINUX=disabled fails: $err"

for f in "${rpms[@]}"; do
  n=$(rpm -qp --qf '%{NAME}' "$f")
  [[ $(rpm -qp --qf '%{VERSION}' "$f") == 2026.4 ]] || fail "$n version"
  release=$(rpm -qp --qf '%{RELEASE}' "$f")
  [[ $release == *.blockie ]] || fail "$n release $release has no .blockie suffix"
  [[ $(rpm --eval "%{lua: print(rpm.vercmp('2026.4-$release', '2026.4-1.fc44'))}") == 1 ]] ||
    fail "$n 2026.4-$release does not sort above 2026.4-1.fc44"
done
echo "pkg-ostree: ${rpms[*]##*/} ok"
