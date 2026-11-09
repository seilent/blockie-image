%global debug_package %{nil}
%global _build_id_links none
%global commit f66e45bf171d55ea0a4ceb64ab58bcf48f2b7997
%global shortcommit f66e45b
%global qrdir qrcodegen-720f62bd

Name:           blockie-frontend
Version:        0
Release:        1.git%{shortcommit}%{?dist}
Summary:        Blockie frontend, the Wayland launcher built on funeOS's UI layers
License:        GPL-3.0-or-later AND BSD-2-Clause AND Zlib AND MIT AND LGPL-2.1-or-later AND MIT-Modern-Variant AND blessing AND OFL-1.1
URL:            https://github.com/seilent/blockie-frontend
Source0:        https://github.com/seilent/blockie-frontend/archive/%{commit}.tar.gz#/blockie-frontend-%{commit}.tar.gz
Source1:        https://raw.githubusercontent.com/nothings/stb/6e9f34d5429cf16790ec43c9bac3f1ee4ad1f760/stb_truetype.h
Source2:        https://github.com/randy408/libspng/archive/refs/tags/v0.7.4.tar.gz#/libspng-0.7.4.tar.gz
Source3:        https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
Source4:        https://raw.githubusercontent.com/nayuki/QR-Code-generator/720f62bddb7226106071d4728c292cb1df519ceb/c/qrcodegen.c
Source5:        https://raw.githubusercontent.com/nayuki/QR-Code-generator/720f62bddb7226106071d4728c292cb1df519ceb/c/qrcodegen.h
Source6:        https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
Source7:        https://github.com/harfbuzz/harfbuzz/releases/download/14.3.0/harfbuzz-14.3.0.tar.xz
Source8:        https://gitlab.freedesktop.org/wayland/wayland-protocols/-/raw/1.41/stable/xdg-shell/xdg-shell.xml#/xdg-shell-1.41.xml
Source9:        https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip
Source10:       https://github.com/microsoft/Selawik/releases/download/1.01/Selawik_Release.zip
Source11:       https://raw.githubusercontent.com/microsoft/Selawik/b65ff9ce7c4673e75ec5c622924a6b6f61f2f876/LICENSE.txt#/Selawik-LICENSE.txt
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  wayland-devel
BuildRequires:  pkgconf-pkg-config
BuildRequires:  libxkbcommon-devel
BuildRequires:  libcurl-devel
BuildRequires:  pkgconfig(dbus-1)
BuildRequires:  unzip

%description
The Blockie frontend: a Wayland client on funeOS's carved UI layers that lists the systems
and games and launches them. Built from seilent/blockie-frontend at %{commit} with its
pinned third party sources linked in statically.

%prep
%setup -q -n blockie-frontend-%{commit}
cache=$PWD/.fe-cache
mkdir -p "$cache/inc" "$cache/src/%{qrdir}"
cp %{SOURCE1} "$cache/inc/stb_truetype.h"
cp %{SOURCE2} "$cache/libspng-0.7.4.tar.gz"
cp %{SOURCE3} "$cache/zlib-1.3.1.tar.gz"
cp %{SOURCE4} %{SOURCE5} "$cache/src/%{qrdir}/"
cp %{SOURCE6} "$cache/fribidi-1.0.16.tar.xz"
cp %{SOURCE7} "$cache/harfbuzz-14.3.0.tar.xz"
cp %{SOURCE8} "$cache/xdg-shell-1.41.xml"
cp %{SOURCE9} "$cache/sqlite-amalgamation-3540100.zip"
cp %{SOURCE10} "$cache/Selawik_Release.zip"

%build
BLOCKIE_FE_CACHE=$PWD/.fe-cache BLOCKIE_FE_OUT=$PWD/.fe-out BLOCKIE_FE_JOBS=%{_smp_build_ncpus} CC=gcc CXX=g++ \
  BLOCKIE_FE_CFLAGS="%{build_cflags}" BLOCKIE_FE_LDFLAGS="%{build_ldflags}" ./build.sh app
mkdir -p third-party
cp .fe-cache/src/libspng-0.7.4/LICENSE third-party/libspng-LICENSE
cp .fe-cache/src/zlib-1.3.1/LICENSE third-party/zlib-LICENSE
cp .fe-cache/src/fribidi-1.0.16/COPYING third-party/fribidi-COPYING
cp .fe-cache/src/harfbuzz-14.3.0/COPYING third-party/harfbuzz-COPYING
cp .fe-cache/src/%{qrdir}/qrcodegen.h third-party/qrcodegen.h
cp .fe-cache/inc/stb_truetype.h third-party/stb_truetype.h
sed -n '1,/^\*\*\*\*/p' .fe-cache/src/sqlite-amalgamation-3540100/sqlite3.h > third-party/sqlite-NOTICE
cp %{SOURCE11} third-party/Selawik-LICENSE.txt

%install
BLOCKIE_FE_CACHE=$PWD/.fe-cache BLOCKIE_FE_OUT=$PWD/.fe-out ./build.sh install DESTDIR=%{buildroot} PREFIX=%{_prefix}

%check
BLOCKIE_FE_CACHE=$PWD/.fe-cache BLOCKIE_FE_OUT=$PWD/.fe-out BLOCKIE_FE_JOBS=%{_smp_build_ncpus} CC=gcc CXX=g++ \
  BLOCKIE_FE_CFLAGS="%{build_cflags}" BLOCKIE_FE_LDFLAGS="%{build_ldflags}" ./build.sh test

%files
%license LICENSE third-party/*
%{_libexecdir}/blockie/blockie-frontend
%{_userunitdir}/blockie-frontend.service
%{_datadir}/blockie/fonts/
%{_datadir}/blockie/schema.d/20-frontend.json
