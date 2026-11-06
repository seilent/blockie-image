Name:           blockie-tools
Version:        1
Release:        1%{?dist}
Summary:        Blockie device tools
License:        GPL-2.0-only
BuildArch:      noarch
Source0:        blockie-tools-src.tar.gz
BuildRequires:  python3
BuildRequires:  coreutils
Requires:       blk-wmt
Requires:       kmod
Requires:       util-linux-core
Requires:       coreutils
Requires:       systemd

%description
blockie-wifi loads the MT6768 Wi-Fi modules, runs blk-wmt and waits for wlan0.
blockie-boot-ok confirms the booted deployment; blockie-blobs checks the pinned blobs
and links them for the GPU.

%prep
%setup -q -c -n blockie-tools

%build

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["WIFI_SCRIPT"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files/usr/libexec/blockie/blockie-wifi" "$PWD/tests/test-blockie-wifi"
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["BLOBS_SCRIPT"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files/usr/libexec/blockie/blockie-blobs" "$PWD/tests/test-blockie-blobs"
rm -rf "${t:?}"

%install
install -Dm0755 files/usr/libexec/blockie/blockie-wifi %{buildroot}%{_libexecdir}/blockie/blockie-wifi
install -Dm0755 files/usr/libexec/blockie/blockie-boot-ok %{buildroot}%{_libexecdir}/blockie/blockie-boot-ok
install -Dm0755 files/usr/libexec/blockie/blockie-blobs %{buildroot}%{_libexecdir}/blockie/blockie-blobs
install -dm0755 %{buildroot}%{_datadir}/blockie/blobs.d

%files
%{_libexecdir}/blockie/blockie-wifi
%{_libexecdir}/blockie/blockie-boot-ok
%{_libexecdir}/blockie/blockie-blobs
%dir %{_datadir}/blockie
%dir %{_datadir}/blockie/blobs.d
