%global debug_package %{nil}
%global _build_id_links none
%global commit 8b1a3da5d2331d0f88b70be25963182d46eed857
%global shortcommit 8b1a3da
%global gl4esdir %{_libdir}/gl4es
%global __provides_exclude_from ^%{gl4esdir}/
%global __requires_exclude ^libGL\\.so\\.1

Name:           gl4es
Version:        1.1.7
Release:        1.20261111git%{shortcommit}%{?dist}
Summary:        OpenGL 2.1 over GLES2 for Box64 runners
License:        MIT AND LicenseRef-Fedora-Public-Domain
URL:            https://github.com/ptitSeb/gl4es
Source0:        gl4es-%{commit}.tar.gz
Patch0:         egl-attrib-ptr.patch
BuildRequires:  gcc
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  pkgconfig(x11)

%description
gl4es for X11, with GLX over EGL and the GLES2 backend: libGL.so.1 in %{gl4esdir} and its EGL wrapper libEGL.so.1 in
%{gl4esdir}/egl, both off the system library path and provided to nothing by dnf. A GLX runner adds %{gl4esdir} to
LD_LIBRARY_PATH; only an EGL desktop GL runner adds the egl dir too, with LIBGL_EGL and LIBGL_GLES set to the GPU
blob's absolute paths.

%prep
%autosetup -p1 -n gl4es-%{commit}

%build
%set_build_flags
export CFLAGS="$CFLAGS -ffile-prefix-map=%{_builddir}=."
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=ON -DDEFAULT_ES=2 -DEGL_WRAPPER=ON
ninja -C build -k 0 %{?_smp_mflags}

%install
dir=%{buildroot}%{gl4esdir}
install -Dm0755 lib/libGL.so.1 "$dir/libGL.so.1"
install -Dm0755 lib/libEGL.so.1 "$dir/egl/libEGL.so.1"
%{__strip} --strip-unneeded "$dir/libGL.so.1" "$dir/egl/libEGL.so.1"
install -Dm0644 LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
{
  sed -n '14,54p' src/gl/decompress.c
  echo
  sed -n '1,24p' include/khash.h
  echo
  sed -n '3,23p' src/gl/math/matheval.c
} > %{buildroot}%{_licensedir}/%{name}/THIRD-PARTY

%files
%license %{_licensedir}/%{name}
%dir %{gl4esdir}
%{gl4esdir}/libGL.so.1
%dir %{gl4esdir}/egl
%{gl4esdir}/egl/libEGL.so.1
