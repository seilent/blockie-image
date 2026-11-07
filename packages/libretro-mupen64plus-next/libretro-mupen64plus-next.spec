%global debug_package %{nil}
%global _build_id_links none
%global _lto_cflags %{nil}
%global commit 15bada85906593376e8fd697f1b0b3af3a20f512
%global shortcommit 15bada8

Name:           libretro-mupen64plus-next
Version:        0
Release:        1.20261022git%{shortcommit}%{?dist}
Summary:        Mupen64Plus-Next Nintendo 64 core for libretro
License:        GPL-2.0-only AND GPL-2.0-or-later AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Zlib AND Libpng AND LicenseRef-Fedora-Public-Domain
URL:            https://github.com/libretro/mupen64plus-libretro-nx
Source0:        mupen64plus-libretro-nx-%{commit}.tar.gz
Patch0:         no-graphicbuffer.patch
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  libglvnd-devel
BuildRequires:  mesa-libEGL-devel
BuildRequires:  zlib-devel
BuildRequires:  libpng-devel
%ifarch x86_64
BuildRequires:  nasm
%endif

%description
Mupen64Plus-Next built as a libretro core for RetroArch, with GLideN64 on GLES 3 and the HLE RSP.

%prep
%autosetup -p1 -n mupen64plus-libretro-nx-%{commit}

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=%{_builddir}=."
%make_build platform=unix WITH_DYNAREC=%{_target_cpu} FORCE_GLES3=1 GIT_VERSION='" %{shortcommit}"'
test ! -e GLideN64/src/Graphics/OpenGLContext/GraphicBuffer/PrivateApi/GraphicBuffer.o

%install
install -Dm0755 mupen64plus_next_libretro.so %{buildroot}%{_libdir}/libretro/mupen64plus_next_libretro.so
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/libretro/mupen64plus_next_libretro.so
lic=%{buildroot}%{_licensedir}/%{name}
for f in LICENSE GLideN64/LICENSE GLideN64/licenses/GLSL-FXAA/LICENSE.md GLideN64/licenses/Glow/LICENSE \
  GLideN64/licenses/gles2n64/LICENSE GLideN64/licenses/readerwriterqueue/LICENSE.md mupen64plus-core/LICENSES \
  mupen64plus-rsp-hle/LICENSES; do
  install -Dm0644 "$f" "$lic/$f"
done
install -d "$lic/libretro-common" "$lic/mupen64plus-core/src/device/pif"
sed -n 1,21p libretro-common/file/config_file.c > "$lic/libretro-common/NOTICE"
grep -q 'Copyright  (C) 2010-2020 The RetroArch team' "$lic/libretro-common/NOTICE"
sed -n 1,89p mupen64plus-core/src/device/pif/n64_cic_nus_6105.c > "$lic/mupen64plus-core/src/device/pif/NOTICE"
grep -q 'Copyright 2011 X-Scale' "$lic/mupen64plus-core/src/device/pif/NOTICE"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/libretro
%{_libdir}/libretro/mupen64plus_next_libretro.so
