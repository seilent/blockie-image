%global debug_package %{nil}
%global _build_id_links none
%global compat %{_libdir}/blockie-ports/compat
%global __provides_exclude_from ^%{compat}/

Name:           libjpeg8
Version:        3.1.3
Release:        1%{?dist}
Summary:        libjpeg-turbo with the libjpeg 8 ABI for Westonpack ports
License:        IJG AND BSD-3-Clause AND Zlib
URL:            https://github.com/libjpeg-turbo/libjpeg-turbo
Source0:        libjpeg-turbo-%{version}.tar.gz
BuildRequires:  gcc
BuildRequires:  cmake
BuildRequires:  ninja-build

%description
libjpeg.so.8 with the LIBJPEG_8.0 symbol versions, which Westonpack's weston modules need. It lives in
%{compat}, off the system library path, and provides nothing to dnf.

%prep
%autosetup -n libjpeg-turbo-%{version}

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_INSTALL_LIBDIR=%{compat} -DCMAKE_SKIP_RPATH=ON -DWITH_JPEG8=1 -DWITH_TURBOJPEG=0 -DENABLE_STATIC=0 \
  -DWITH_TOOLS=0
ninja -C build %{?_smp_mflags}

%install
stage=$PWD/stage
DESTDIR="$stage" cmake --install build
dir=%{buildroot}%{compat}
install -d "$dir"
cp -P "$stage%{compat}"/libjpeg.so.8 "$stage%{compat}"/libjpeg.so.8.* "$dir/"
%{__strip} --strip-unneeded "$dir"/libjpeg.so.8.*
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 LICENSE.md "$lic/LICENSE.md"
install -Dm0644 README.ijg "$lic/README.ijg"

%files
%license %{_licensedir}/%{name}
%dir %{_libdir}/blockie-ports
%dir %{compat}
%{compat}/libjpeg.so.8
%{compat}/libjpeg.so.8.*
