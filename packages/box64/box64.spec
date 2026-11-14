%global debug_package %{nil}
%global _build_id_links none
%global commit 2f130fab1d6e1a4ee8a71dc60cfdfcc839ad192a
%global shortcommit 2f130fa

Name:           box64
Version:        0.4.4
Release:        1.20260802git%{shortcommit}%{?dist}
Summary:        x86_64 Linux userspace emulator for the Box64 runners
License:        MIT AND HPND-sell-variant AND Zlib AND Unlicense
URL:            https://github.com/ptitSeb/box64
Source0:        box64-%{commit}.tar.gz
ExclusiveArch:  aarch64
BuildRequires:  gcc
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  python3

%description
Box64 with the ARM64 dynarec: the generic build as box64 and the Snapdragon 845 build (tuned for Cortex-A75 and
Cortex-A55) as box64-sd845, with upstream's box64.box64rc in /etc.

%prep
%autosetup -n box64-%{commit}
rm -r x64lib

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
common="-G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_SKIP_RPATH=ON -DNOGIT=ON -DARM_DYNAREC=ON"
common="$common -DNO_LIB_INSTALL=ON -DNO_CONF_INSTALL=ON"
cmake -S . -B build $common -DARM64=ON
ninja -C build %{?_smp_mflags} box64
cmake -S . -B build-sd845 $common -DSD845=ON
ninja -C build-sd845 %{?_smp_mflags} box64

%install
install -Dm0755 build/box64 %{buildroot}%{_bindir}/box64
install -Dm0755 build-sd845/box64 %{buildroot}%{_bindir}/box64-sd845
%{__strip} --strip-unneeded %{buildroot}%{_bindir}/box64 %{buildroot}%{_bindir}/box64-sd845
install -Dm0644 system/box64.box64rc %{buildroot}%{_sysconfdir}/box64.box64rc
install -Dm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
{
  sed -n '8,30p' src/include/elfhacks.h
  echo
  sed -n '4,29p' src/emu/x64primop.c
  echo
  sed -n '1,24p' src/include/khash.h
  echo
  sed -n '1,31p' src/include/json.h
  echo
  sed -n '1,20p' src/wrapped/SDL_dynapi_procs.h
  echo
  sed -n '4,24p' src/wrapped/wrappedd3dadapter9_vtable.h
} > %{buildroot}%{_licensedir}/%{name}/THIRD-PARTY

%files
%license %{_licensedir}/%{name}
%{_bindir}/box64
%{_bindir}/box64-sd845
%config(noreplace) %{_sysconfdir}/box64.box64rc
