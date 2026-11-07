%global debug_package %{nil}
%global _build_id_links none
%global commit f27655b592ef43f317272d79883bcaa10d3ac8ad
%global shortcommit f27655b

Name:           libretro-genesis-plus-gx
Version:        0
Release:        1.20261030git%{shortcommit}%{?dist}
Summary:        Genesis Plus GX Sega Mega Drive, Master System and Game Gear core for libretro
License:        LicenseRef-Genesis-Plus-GX AND LGPL-2.1-or-later AND BSD-3-Clause AND Zlib AND MIT AND MIT-0 AND CC0-1.0 AND LicenseRef-Fedora-Public-Domain AND (BSD-3-Clause OR GPL-2.0-only)
URL:            https://github.com/libretro/Genesis-Plus-GX
Source0:        Genesis-Plus-GX-%{commit}.tar.gz
BuildRequires:  gcc
BuildRequires:  make

%description
Genesis Plus GX built as a libretro core for RetroArch.

%prep
%setup -q -n Genesis-Plus-GX-%{commit}

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
%make_build -f Makefile.libretro platform=unix GIT_VERSION='" %{shortcommit}"'

%install
install -Dm0755 genesis_plus_gx_libretro.so %{buildroot}%{_libdir}/libretro/genesis_plus_gx_libretro.so
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/libretro/genesis_plus_gx_libretro.so
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 LICENSE.txt "$lic/LICENSE.txt"
install -Dm0644 core/ntsc/license.txt "$lic/core/ntsc/license.txt"
install -d "$lic/libretro/libretro-common"
sed -n 1,21p libretro/libretro-common/file/file_path.c > "$lic/libretro/libretro-common/NOTICE"
grep -q 'Copyright  (C) 2010-2019 The RetroArch team' "$lic/libretro/libretro-common/NOTICE"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/libretro
%{_libdir}/libretro/genesis_plus_gx_libretro.so
