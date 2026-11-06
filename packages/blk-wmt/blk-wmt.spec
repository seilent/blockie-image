%global debug_package %{nil}
%global _build_id_links none

Name:           blk-wmt
Version:        1
Release:        1%{?dist}
Summary:        WMT loader, launcher, NVRAM push and Wi-Fi power on for the MT6768 connsys
License:        GPL-2.0-only
Source0:        blk-wmt-src.tar.gz
BuildRequires:  gcc
BuildRequires:  python3

%description
Replaces Android's wmt_loader, wmt_launcher and the NVRAM part of wlan_assistant on the KONKR Pocket Block, with a
once per boot guard on the connsys and Wi-Fi power on.

%prep
%setup -q -c -n blk-wmt

%build
gcc %{build_cflags} -ffile-prefix-map=%{_topdir}=. -Wall -Wextra -pthread %{build_ldflags} -o blk-wmt blk-wmt.c
mkdir test
gcc -O2 -Wall -Wextra -pthread -Dioctl=fake_ioctl -Dwrite=fake_write -o test/blk-wmt blk-wmt.c test-fake.c

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.execv(sys.argv[2], sys.argv[2:])' "$t" "$PWD/test-wmt" "$PWD/test/blk-wmt"
rm -rf "${t:?}"

%install
install -Dm0755 blk-wmt %{buildroot}%{_libexecdir}/blockie/blk-wmt

%files
%{_libexecdir}/blockie/blk-wmt
