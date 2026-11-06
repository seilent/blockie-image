%global debug_package %{nil}
%global _build_id_links none

Name:           blk-bt
Version:        1
Release:        1%{?dist}
Summary:        Bluetooth bridge from /dev/stpbt to the kernel HCI for the MT6768 connsys
License:        GPL-2.0-only
Source0:        blk-bt-src.tar.gz
BuildRequires:  gcc
BuildRequires:  python3
Requires:       blk-wmt

%description
Bridges the MT6768 Bluetooth character device /dev/stpbt to a pty with the HCI UART line discipline on the KONKR
Pocket Block, sets the BD address from NVRAM and stops for the boot after any failure.

%prep
%setup -q -c -n blk-bt

%build
gcc %{build_cflags} -ffile-prefix-map=%{_topdir}=. -Wall -Wextra %{build_ldflags} -o blk-bt blk-bt.c
mkdir test
gcc -O2 -Wall -Wextra -Dioctl=fake_ioctl -Dwrite=fake_write -Dread=fake_read -Dclose=fake_close -Dflock=fake_flock -o test/blk-bt blk-bt.c test-fake.c

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.execv(sys.argv[2], sys.argv[2:])' "$t" "$PWD/test-bt" "$PWD/test/blk-bt"
rm -rf "${t:?}"

%install
install -Dm0755 blk-bt %{buildroot}%{_libexecdir}/blockie/blk-bt

%files
%{_libexecdir}/blockie/blk-bt
