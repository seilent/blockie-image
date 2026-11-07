%global debug_package %{nil}
%global _build_id_links none
%global _lto_cflags %{nil}
%global commit 5aa091fde632fb332c8d8c34e280d62dc951954c
%global shortcommit 5aa091f

Name:           libretro-flycast
Version:        0
Release:        1.20260814git%{shortcommit}%{?dist}
Summary:        Flycast Sega Dreamcast core for libretro
License:        GPL-2.0-or-later AND GPL-3.0-only AND GPL-3.0-or-later WITH Bison-exception-2.2 AND BSD-2-Clause AND BSD-3-Clause AND MIT AND Apache-2.0 AND BSL-1.0 AND Zlib AND LicenseRef-Fedora-Public-Domain AND (Apache-2.0 OR MIT) AND (MIT OR Unlicense) AND (BSD-3-Clause OR GPL-2.0-only) AND (GPL-2.0-only OR GPL-3.0-only)
URL:            https://github.com/flyinghead/flycast
Source0:        flycast-%{commit}.tar.gz
Source1:        md5-LICENSE
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  libglvnd-devel
BuildRequires:  mesa-libEGL-devel

%description
Flycast built as a libretro core for RetroArch, with Vulkan and GLES 3.

%prep
%setup -q -n flycast-%{commit}
sed -i -e 's/set(GIT_VERSION "v0.0.0-0-g000000000")/set(GIT_VERSION "v2.7")/' \
  -e 's/set(GIT_HASH "000000000")/set(GIT_HASH "%{shortcommit}")/' CMakeLists.txt
grep -q 'set(GIT_VERSION "v2.7")' CMakeLists.txt
grep -q 'set(GIT_HASH "%{shortcommit}")' CMakeLists.txt

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=%{_builddir}=."
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLIBRETRO=ON \
  -DUSE_GLES=ON -DUSE_VULKAN=ON -DUSE_HOST_LIBZIP=OFF
ninja -C build %{?_smp_mflags}

%install
install -Dm0755 build/flycast_libretro.so %{buildroot}%{_libdir}/libretro/flycast_libretro.so
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/libretro/flycast_libretro.so
for f in LICENSE core/deps/libchdr/LICENSE.txt core/deps/libchdr/deps/lzma-24.05/LICENSE \
  core/deps/libchdr/deps/zlib-1.3.1/LICENSE core/deps/libchdr/deps/zstd-1.5.6/LICENSE \
  core/deps/libchdr/deps/zstd-1.5.6/COPYING core/deps/glslang/LICENSE.txt core/deps/Vulkan-Headers/LICENSE.md \
  core/deps/Vulkan-Headers/LICENSES/Apache-2.0.txt core/deps/Vulkan-Headers/LICENSES/MIT.txt \
  core/deps/VulkanMemoryAllocator/LICENSE.txt core/deps/libzip/LICENSE core/deps/miniupnpc/LICENSE \
  core/deps/nowide/LICENSE core/deps/picotcp/COPYING core/deps/picotcp/LICENSE.GPLv2 core/deps/picotcp/LICENSE.GPLv3 \
  core/deps/tinygettext/LICENSE.md core/deps/xbrz/License.txt core/deps/xxHash/LICENSE core/deps/glm/copying.txt \
  core/deps/asio/asio/COPYING core/deps/asio/asio/LICENSE_1_0.txt; do
  install -Dm0644 "$f" "%{buildroot}%{_licensedir}/%{name}/$f"
done
%ifarch x86_64
install -Dm0644 core/deps/xbyak/COPYRIGHT %{buildroot}%{_licensedir}/%{name}/core/deps/xbyak/COPYRIGHT
%endif
lic=%{buildroot}%{_licensedir}/%{name}
notice() {
  install -d "$lic/$1"
  sed -n "$3" "$2" > "$lic/$1/NOTICE"
  grep -qF "$4" "$lic/$1/NOTICE"
}
notice core/deps/libelf core/deps/libelf/src/elf.c 1,5p 'University of New South Wales'
sed -n 7,26p core/deps/xxHash/LICENSE >> "$lic/core/deps/libelf/NOTICE"
grep -q 'Redistribution and use' "$lic/core/deps/libelf/NOTICE"
notice core/deps/json core/deps/json/json.hpp '1,28p;16179p;18144p' 'Niels Lohmann'
notice core/deps/libretro-common core/deps/libretro-common/file/file_path.c 1,21p 'The RetroArch team'
notice core/hw/bba core/hw/bba/rtl8139c.cpp 1,48p 'Igor Kovalenko'
notice core/network core/network/ifaddrs.c 1,24p 'Kenneth MacKay'
install -Dm0644 %{SOURCE1} "$lic/core/deps/md5/LICENSE"
%ifarch aarch64
notice core/deps/vixl core/deps/vixl/globals-vixl.h 1,25p 'VIXL authors'
%endif

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/libretro
%{_libdir}/libretro/flycast_libretro.so
