%global debug_package %{nil}
%global _build_id_links none

Name:           blockie-tools
Version:        1
Release:        1%{?dist}
Summary:        Blockie device tools
License:        GPL-2.0-only
Source0:        blockie-tools-src.tar.gz
BuildRequires:  gcc
BuildRequires:  python3
BuildRequires:  coreutils
BuildRequires:  strace
Requires:       blk-wmt
Requires:       blk-bt
Requires:       kmod
Requires:       util-linux-core
Requires:       util-linux
Requires:       coreutils
Requires:       systemd

%description
blockie-wifi loads the MT6768 Wi-Fi modules, runs blk-wmt and waits for wlan0.
blockie-bt loads the MT6768 Bluetooth module and waits for /dev/stpbt.
blockie-boot-ok confirms the booted deployment; blockie-blobs checks the pinned blobs
and links them for the GPU. abctl reads and writes the slot table and the bootloader
message in misc; blockie-bootctl re-arms slot a at the healthy point and writes the
reboot targets and their gates.

%prep
%setup -q -c -n blockie-tools

%build
gcc %{build_cflags} -ffile-prefix-map=%{_topdir}=. -Wall -Wextra %{build_ldflags} -o abctl src/abctl.c

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["WIFI_SCRIPT"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files/usr/libexec/blockie/blockie-wifi" "$PWD/tests/test-blockie-wifi"
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["BLOBS_SCRIPT"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files/usr/libexec/blockie/blockie-blobs" "$PWD/tests/test-blockie-blobs"
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["BT_SCRIPT"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files/usr/libexec/blockie/blockie-bt" "$PWD/tests/test-blockie-bt"
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.execv(sys.argv[2], sys.argv[2:])' \
  "$t" "$PWD/tests/test-abctl" --abctl "$PWD/abctl" --tmp "$t"
rm -rf "${t:?}"

%install
install -Dm0755 files/usr/libexec/blockie/blockie-wifi %{buildroot}%{_libexecdir}/blockie/blockie-wifi
install -Dm0755 files/usr/libexec/blockie/blockie-bt %{buildroot}%{_libexecdir}/blockie/blockie-bt
install -Dm0755 files/usr/libexec/blockie/blockie-boot-ok %{buildroot}%{_libexecdir}/blockie/blockie-boot-ok
install -Dm0755 files/usr/libexec/blockie/blockie-blobs %{buildroot}%{_libexecdir}/blockie/blockie-blobs
install -Dm0755 abctl %{buildroot}%{_bindir}/abctl
install -Dm0755 files/usr/bin/blockie-bootctl %{buildroot}%{_bindir}/blockie-bootctl
install -dm0755 %{buildroot}%{_datadir}/blockie/blobs.d

%files
%{_libexecdir}/blockie/blockie-wifi
%{_libexecdir}/blockie/blockie-bt
%{_libexecdir}/blockie/blockie-boot-ok
%{_libexecdir}/blockie/blockie-blobs
%{_bindir}/abctl
%{_bindir}/blockie-bootctl
%dir %{_datadir}/blockie
%dir %{_datadir}/blockie/blobs.d
