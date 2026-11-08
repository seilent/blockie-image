%global debug_package %{nil}
%global _build_id_links none

Name:           blockie-compositor
Version:        1
Release:        1%{?dist}
Summary:        labwc setup for the Blockie session on the MT6768 display
License:        GPL-2.0-only
Source0:        blockie-compositor-src.tar.gz
BuildRequires:  gcc
BuildRequires:  python3
Requires:       labwc
Requires:       bash

%description
labwc on the KONKR Pocket Block display: GLES on the GPU link farm or pixman, no cursor
ioctls or cursor planes on the MediaTek display driver, a glFinish before each page flip,
undecorated maximized windows, power and volume keys held back from clients, no tearing, no
cursor image. Every blockie user unit loads the GPU environment and the cursor shim.

%prep
%setup -q -c -n blockie-compositor

%build
gcc %{build_cflags} -fPIC -shared -Wall -Wextra %{build_ldflags} -o libblockie-nocursor.so src/nocursor.c
gcc %{build_cflags} -fPIC -shared -Wall -Wextra %{build_ldflags} -o libblockie-glfinish.so src/glfinish.c
mkdir test
gcc -O2 -Wall -Wextra -fPIC -shared -o test/libfakedrm.so tests/fakedrm.c
gcc -O2 -Wall -Wextra -o test/test-nocursor tests/test-nocursor.c -Ltest -lfakedrm -Wl,-rpath,'$ORIGIN'
gcc -O2 -Wall -Wextra -fPIC -shared -o test/libfakegl.so tests/fakegl.c
gcc -O2 -Wall -Wextra -o test/test-glfinish tests/test-glfinish.c -Ltest -lfakegl -Wl,-rpath,'$ORIGIN'
mkdir test/nofinish
gcc -O2 -Wall -Wextra -DNO_FINISH -fPIC -shared -o test/nofinish/libfakegl.so tests/fakegl.c
gcc -O2 -Wall -Wextra -DNO_FINISH -o test/nofinish/test-glfinish tests/test-glfinish.c -Ltest/nofinish -lfakegl -Wl,-rpath,'$ORIGIN'
python3 src/mkcursor blockie-none

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["COMP_FILES"] = sys.argv[2]; os.environ["COMP_BUILD"] = sys.argv[3]; os.execv(sys.argv[4], sys.argv[4:])' \
  "$t" "$PWD/files" "$PWD" "$PWD/tests/test-blockie-compositor"
rm -rf "${t:?}"

%install
install -Dm0755 libblockie-nocursor.so %{buildroot}%{_libdir}/blockie/libblockie-nocursor.so
install -Dm0755 libblockie-glfinish.so %{buildroot}%{_libdir}/blockie/libblockie-glfinish.so
install -Dm0755 files/usr/libexec/blockie/blockie-compositor %{buildroot}%{_libexecdir}/blockie/blockie-compositor
install -Dm0644 files/usr/share/blockie/labwc/rc.xml %{buildroot}%{_datadir}/blockie/labwc/rc.xml
install -Dm0644 files/usr/share/blockie/labwc/autostart %{buildroot}%{_datadir}/blockie/labwc/autostart
install -Dm0644 blockie-none %{buildroot}%{_datadir}/icons/blockie-none/cursors/blockie-none
install -Dm0644 files/usr/lib/systemd/user/blockie-.service.d/50-blockie-gpu.conf \
  %{buildroot}%{_userunitdir}/blockie-.service.d/50-blockie-gpu.conf

%files
%dir %{_libdir}/blockie
%{_libdir}/blockie/libblockie-nocursor.so
%{_libdir}/blockie/libblockie-glfinish.so
%{_libexecdir}/blockie/blockie-compositor
%dir %{_datadir}/blockie/labwc
%{_datadir}/blockie/labwc/rc.xml
%{_datadir}/blockie/labwc/autostart
%dir %{_datadir}/icons/blockie-none
%dir %{_datadir}/icons/blockie-none/cursors
%{_datadir}/icons/blockie-none/cursors/blockie-none
%dir %{_userunitdir}/blockie-.service.d
%{_userunitdir}/blockie-.service.d/50-blockie-gpu.conf
