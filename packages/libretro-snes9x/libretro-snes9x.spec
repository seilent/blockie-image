%global debug_package %{nil}
%global _build_id_links none
%global commit fae2fea08f74180759ef540ee94259213f503480
%global shortcommit fae2fea

Name:           libretro-snes9x
Version:        0
Release:        1.20260919git%{shortcommit}%{?dist}
Summary:        Snes9x Super Nintendo core for libretro
License:        LicenseRef-Snes9x AND LGPL-2.1-or-later AND MIT AND LicenseRef-Fedora-Public-Domain
URL:            https://github.com/libretro/snes9x
Source0:        snes9x-%{commit}.tar.gz
BuildRequires:  gcc-c++
BuildRequires:  make

%description
Snes9x built as a libretro core for RetroArch.

%prep
%setup -q -n snes9x-%{commit}

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=%{_builddir}=."
%make_build -C libretro platform=unix GIT_VERSION='" %{shortcommit}"'

%install
install -Dm0755 libretro/snes9x_libretro.so %{buildroot}%{_libdir}/libretro/snes9x_libretro.so
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/libretro/snes9x_libretro.so
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 LICENSE "$lic/LICENSE"
install -Dm0644 filter/snes_ntsc-license.txt "$lic/filter/snes_ntsc-license.txt"
install -d "$lic/libretro/libretro-common"
sed -n 1,21p libretro/libretro-common/file/file_path.c > "$lic/libretro/libretro-common/NOTICE"
grep -q 'Copyright  (C) 2010-2020 The RetroArch team' "$lic/libretro/libretro-common/NOTICE"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/libretro
%{_libdir}/libretro/snes9x_libretro.so
