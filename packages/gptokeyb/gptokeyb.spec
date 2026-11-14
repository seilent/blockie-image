%global debug_package %{nil}
%global _build_id_links none
%global commit 5b1284e1502548d476aa38e5979b0a8f48cb7b94
%global shortcommit 5b1284e

Name:           gptokeyb
Version:        0
Release:        2.20260228git%{shortcommit}%{?dist}
Summary:        Gamepad to keyboard and mouse mapper for PortMaster ports
License:        GPL-2.0-or-later
URL:            https://github.com/PortsMaster/gptokeyb
Source0:        gptokeyb-%{commit}.tar.gz
Patch0:         no-kill-mode.patch
Patch1:         read-only-config.patch
BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  cmake(SDL2)
BuildRequires:  pkgconfig(libevdev)

%description
gptokeyb for PortMaster ports, built without kill mode: the hotkey plus START quits nothing. It opens its
config file read only.

%prep
%autosetup -p1 -n gptokeyb-%{commit}

%build
%set_build_flags
export CXXFLAGS="$CXXFLAGS -ffile-prefix-map=%{_builddir}=."
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
ninja -C build %{?_smp_mflags}

%install
install -Dm0755 build/gptokeyb %{buildroot}%{_libdir}/blockie-ports/gptokeyb
%{__strip} --strip-unneeded %{buildroot}%{_libdir}/blockie-ports/gptokeyb
install -Dm0644 LICENSE.md %{buildroot}%{_licensedir}/%{name}/LICENSE.md
src=%{buildroot}%{_datadir}/blockie/sources/portmaster/%{name}
install -Dm0644 %{SOURCE0} "$src/gptokeyb-%{commit}.tar.gz"
install -Dm0644 %{PATCH0} "$src/no-kill-mode.patch"
install -Dm0644 %{PATCH1} "$src/read-only-config.patch"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/blockie-ports
%{_libdir}/blockie-ports/gptokeyb
%dir %{_datadir}/blockie/sources
%dir %{_datadir}/blockie/sources/portmaster
%{_datadir}/blockie/sources/portmaster/%{name}
