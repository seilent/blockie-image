%global debug_package %{nil}
%global _build_id_links none
%global _lto_cflags %{nil}
%global commit fa50bb1976065c4f8b1b47af227d367fe9771555
%global shortcommit fa50bb1
%global ffcommit 3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587

Name:           libretro-ppsspp
Version:        0
Release:        1.20260516git%{shortcommit}%{?dist}
Summary:        PPSSPP PlayStation Portable core for libretro
License:        GPL-2.0-or-later AND GPL-3.0-or-later AND GPL-3.0-only AND GPL-3.0-or-later WITH Bison-exception-2.2 AND LGPL-2.1-or-later AND Apache-2.0 AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Zlib AND CC0-1.0 AND LicenseRef-Fedora-Public-Domain AND LicenseRef-disarm AND (FTL OR GPL-2.0-or-later)
URL:            https://github.com/hrydgard/ppsspp
Source0:        ppsspp-%{commit}.tar.gz
Source1:        FFmpeg-%{ffcommit}.tar.gz
Source2:        SFMT-LICENSE.txt
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  pkgconf-pkg-config
BuildRequires:  libglvnd-devel
BuildRequires:  mesa-libEGL-devel
BuildRequires:  vulkan-headers
BuildRequires:  wayland-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  libX11-devel
BuildRequires:  zlib-devel
BuildRequires:  libpng-devel
%ifarch x86_64
BuildRequires:  nasm
%endif

%description
PPSSPP built as a libretro core for RetroArch, with Vulkan and GLES, linked against a static FFmpeg that holds only
the decoders, demuxers and parsers PSP media needs, and the PPSSPP assets the core reads from its system directory.

%prep
%setup -q -n ppsspp-%{commit}
%setup -q -T -D -a 1 -n ppsspp-%{commit}
mkdir -p build
printf 'const char *PPSSPP_GIT_VERSION = "v1.20.4";\n\n#define PPSSPP_GIT_VERSION_NO_UPDATE 1\n' > build/git-version.cpp

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=%{_builddir}=."
ff=$PWD/ffprefix
mkdir -p ffbuild
cd ffbuild
../FFmpeg-%{ffcommit}/configure --prefix="$ff" --cc=gcc --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
  --disable-shared --enable-static --enable-pic --disable-programs --disable-doc --disable-indevs --disable-outdevs \
  --disable-filters --disable-postproc --disable-network --disable-everything --disable-encoders --disable-hwaccels \
  --disable-autodetect --enable-swresample --enable-swscale \
  --enable-decoder=h264,mpeg4,mpeg2video,mjpeg,mjpegb,aac,aac_latm,atrac3,atrac3p,mp3,pcm_s16le,pcm_s8 \
  --enable-demuxer=h264,m4v,mpegvideo,mpegps,mp3,avi,aac,pmp,oma,pcm_s16le,pcm_s8,wav \
  --enable-parser=h264,mpeg4video,mpegaudio,mpegvideo,aac,aac_latm --enable-protocol=file
%make_build
%{__make} install
cd ..
PKG_CONFIG_PATH="$ff/lib/pkgconfig" cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLIBRETRO=ON -DUSING_GLES2=ON -DUSING_EGL=OFF -DUSE_SYSTEM_FFMPEG=ON
ninja -C build %{?_smp_mflags}

%install
install -Dm0755 build/lib/ppsspp_libretro.so %{buildroot}%{_libdir}/libretro/ppsspp_libretro.so
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/libretro/ppsspp_libretro.so
install -d %{buildroot}%{_datadir}/libretro/ppsspp/PPSSPP
cp -a assets/. %{buildroot}%{_datadir}/libretro/ppsspp/PPSSPP/
rm -rf %{buildroot}%{_datadir}/libretro/ppsspp/PPSSPP/debugger
for f in LICENSE.TXT ext/armips/LICENSE.txt ext/glslang/LICENSE.txt ext/SPIRV-Cross/LICENSE ext/rapidjson/license.txt \
  ext/miniupnp/LICENSE ext/zstd/LICENSE ext/zstd/COPYING ext/cpu_features/LICENSE ext/rcheevos/LICENSE \
  ext/naett/LICENSE ext/libchdr/LICENSE.txt ext/freetype/LICENSE.TXT ext/nanosvg/LICENSE.txt ext/OpenXR-SDK/LICENSE \
  ext/cityhash/COPYING ext/gason/LICENSE ext/udis86/LICENSE ext/snappy/COPYING ext/aemu_postoffice/gpl-3.0.txt \
  FFmpeg-%{ffcommit}/COPYING.LGPLv2.1 FFmpeg-%{ffcommit}/LICENSE.md; do
  install -Dm0644 "$f" "%{buildroot}%{_licensedir}/%{name}/${f#FFmpeg-%{ffcommit}/}"
done
lic=%{buildroot}%{_licensedir}/%{name}
notice() {
  install -d "$lic/$1"
  sed -n "$3" "$2" > "$lic/$1/NOTICE"
  grep -qF "$4" "$lic/$1/NOTICE"
}
notice ext/libzip ext/libzip/zip.h 4,35p 'Dieter Baron and Thomas Klausner'
notice ext/sfmt19937 ext/sfmt19937/SFMT.c 1,18p 'Mutsuo Saito'
install -Dm0644 %{SOURCE2} "$lic/ext/sfmt19937/LICENSE.txt"
notice ext/pugixml ext/pugixml/pugixml.hpp 1562,1585p 'Arseny Kapoulkine'
notice ext/lua ext/lua/lua.h 499,520p 'Lua.org, PUC-Rio'
notice ext/vma ext/vma/vk_mem_alloc.h 1,21p 'Advanced Micro Devices'
notice ext/basis_universal ext/basis_universal/basisu_transcoder.h 1,15p 'Binomial LLC'
notice ext/libkirk ext/libkirk/kirk_engine.c 1,25p 'General Public License'
notice ext/xbrz ext/xbrz/xbrz.h 1,14p 'Zenju'
notice ext/xxhash ext/xxhash.c 1,33p 'Yann Collet'
notice ext/riscv-disas ext/riscv-disas.cpp 1,24p 'Michael Clark'
notice ext/loongarch-disasm ext/loongarch-disasm.cpp 1,23p 'Loongson Technology'
notice ext/disarm ext/disarm.cpp 1,22p 'Gareth McCaughan'
notice Common/GPU/OpenGL Common/GPU/OpenGL/gl3stub.c 1,15p 'The Android Open Source Project'
notice libretro/libretro-common libretro/libretro-common/file/file_path.c 1,21p 'The RetroArch team'

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/libretro
%{_libdir}/libretro/ppsspp_libretro.so
%dir %{_datadir}/libretro
%{_datadir}/libretro/ppsspp
