%global debug_package %{nil}
%global _build_id_links none
%global commit 647b46f4c49ea7d379fc67126bbfe2910d83e2d9
%global shortcommit 647b46f

Name:           gptokeyb2
Version:        0
Release:        1.20261005git%{shortcommit}%{?dist}
Summary:        Gamepad to keyboard, mouse and controller mapper for PortMaster ports
License:        GPL-2.0-or-later AND BSD-3-Clause
URL:            https://github.com/PortsMaster/gptokeyb2
Source0:        gptokeyb2-%{commit}.tar.gz
Patch0:         no-kill-mode.patch
BuildRequires:  gcc
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  patchelf
BuildRequires:  cmake(SDL2)
BuildRequires:  pkgconfig(libevdev)

%description
gptokeyb2 and its libinterpose for PortMaster ports, built without kill mode: the hotkey plus
START quits nothing.

%prep
%autosetup -p1 -n gptokeyb2-%{commit}
sed -i 's/^add_compile_options(-Wall -Wextra -pedantic -Werror)$/add_compile_options(-Wall -Wextra -pedantic)/' CMakeLists.txt
grep -qx 'add_compile_options(-Wall -Wextra -pedantic)' CMakeLists.txt

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON
ninja -C build %{?_smp_mflags}

%install
dir=%{buildroot}%{_libdir}/blockie-ports
install -Dm0755 build/gptokeyb2 "$dir/gptokeyb2"
install -Dm0755 build/lib/libinterpose.so "$dir/libinterpose.%{_target_cpu}.so"
%{__strip} --strip-unneeded "$dir/gptokeyb2" "$dir/libinterpose.%{_target_cpu}.so"
patchelf --set-soname libinterpose.%{_target_cpu}.so "$dir/libinterpose.%{_target_cpu}.so"
patchelf --replace-needed libinterpose.so libinterpose.%{_target_cpu}.so "$dir/gptokeyb2"
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 LICENSE.txt "$lic/LICENSE.txt"
install -Dm0644 LICENSE-inih.txt "$lic/LICENSE-inih.txt"
src=%{buildroot}%{_datadir}/blockie/sources/portmaster/%{name}
install -Dm0644 %{SOURCE0} "$src/gptokeyb2-%{commit}.tar.gz"
install -Dm0644 %{PATCH0} "$src/no-kill-mode.patch"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/blockie-ports
%{_libdir}/blockie-ports/gptokeyb2
%{_libdir}/blockie-ports/libinterpose.%{_target_cpu}.so
%dir %{_datadir}/blockie/sources
%dir %{_datadir}/blockie/sources/portmaster
%{_datadir}/blockie/sources/portmaster/%{name}
