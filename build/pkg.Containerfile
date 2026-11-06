FROM registry.fedoraproject.org/fedora:44@sha256:1ff9eb02e4e2d7fb1175becac7139b2960c4fdcccedce81c86ec25b98ef3124d

RUN find /etc/yum.repos.d -type f ! -name fedora.repo ! -name fedora-updates.repo -delete \
 && dnf -y --setopt=install_weak_deps=False install \
      rpm-build systemd-rpm-macros \
      gcc make python3 \
      git-core curl tar gzip xz zstd cpio findutils diffutils patch which kmod \
 && if [ "$(uname -m)" = x86_64 ]; then dnf -y --setopt=install_weak_deps=False install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu; fi \
 && dnf clean all
