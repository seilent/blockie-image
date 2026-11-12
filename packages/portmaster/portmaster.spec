%global debug_package %{nil}
%global _build_id_links none
%global commit 9efc198bae230eecb98d6e052cfb027c62fb69c6
%global tag 2026.11.12-1059
%global pmroot %{_datadir}/blockie/portmaster
%global __brp_mangle_shebangs_exclude_from ^%{pmroot}/

Name:           portmaster
Version:        2026.11.12.1059
Release:        1%{?dist}
Summary:        PortMaster scripts and harbourmaster for Blockie ports
License:        MIT AND GPL-2.0-only AND Apache-2.0 AND BSD-3-Clause AND PSF-2.0 AND OFL-1.1 AND Bitstream-Vera AND Arev AND Zlib AND LicenseRef-Fedora-Public-Domain
URL:            https://github.com/PortsMaster/PortMaster-GUI
Source0:        PortMaster-GUI-%{commit}.tar.gz
Source1:        patcher.txt
Source2:        charset_normalizer-LICENSE
Source3:        gamecontrollerdb-LICENSE
BuildRequires:  python3
BuildRequires:  tar
BuildRequires:  xz
Requires:       gptokeyb
Requires:       gptokeyb2
Requires:       love
Requires:       luajit
Requires:       7zip-standalone-all
Requires:       innoextract
Requires:       xdelta
Requires:       libtheora
Requires:       squashfs-tools
Requires:       python3

%description
The read only PortMaster tree port scripts source: control.txt, funcs.txt, device_info.txt and the
other script helpers, harbourmaster with the libraries it imports, and links to the system tools
and gptokeyb. utils/patcher.txt is Blockie's. The GUI, the per CFW files and the prebuilt binaries
are left out.

%prep
%setup -q -n PortMaster-GUI-%{commit}
sed -i 's|^from certifi import where$|def where():\n    return "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"|' PortMaster/exlibs/requests/certs.py
grep -qx '    return "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"' PortMaster/exlibs/requests/certs.py

%install
pm=%{buildroot}%{pmroot}/PortMaster
install -d "$pm"
(cd PortMaster && cp -pr --parents control.txt funcs.txt device_info.txt PortMasterDialog.txt tasksetter mod_.txt \
  libgl_*.txt gamecontrollerdb.txt .Backup runtimes/love_11.5/love.txt pylibs/harbourmaster pylibs/resources \
  exlibs/ansimarkup exlibs/colorama exlibs/loguru exlibs/requests exlibs/urllib3 exlibs/idna exlibs/charset_normalizer \
  exlibs/typing_extensions.py licenses/LICENSE-ansimarkup.txt licenses/LICENSE-colorama.txt licenses/LICENSE-dejavu.txt \
  licenses/LICENSE-idna.md licenses/LICENSE-loguru.txt licenses/LICENSE-noto.txt licenses/LICENSE-requests.txt \
  licenses/LICENSE-typing_extension.txt licenses/LICENSE-urllib3.txt "$pm/")
res=$pm/pylibs/resources
tar -C "$res" --no-same-owner --no-same-permissions -xJf "$res/NotoSans.tar.xz"
rm "$res/NotoSans.tar.xz" "$res/.gitignore"
install -Dm0644 %{SOURCE1} "$pm/utils/patcher.txt"
echo '%{tag}' > "$pm/version"
install -d "$pm/runtimes/love_11.5/libs.%{_target_cpu}" "$pm/libs.%{_target_cpu}"
ln -s %{_bindir}/love "$pm/runtimes/love_11.5/love.%{_target_cpu}"
ln -s %{_libdir}/blockie-ports/gptokeyb "$pm/gptokeyb"
ln -s %{_libdir}/blockie-ports/gptokeyb2 "$pm/gptokeyb2"
ln -s %{_libdir}/blockie-ports/libinterpose.%{_target_cpu}.so "$pm/libinterpose.%{_target_cpu}.so"
ln -s %{_bindir}/7zz "$pm/7zzs.%{_target_cpu}"
ln -s %{_bindir}/innoextract "$pm/innoextract.%{_target_cpu}"
ln -s %{_bindir}/xdelta3 "$pm/xdelta3"
ln -s %{_libdir}/libtheoradec.so.1 "$pm/libs.%{_target_cpu}/libtheoradec.so.1"
%{python3} -m compileall -q -s %{buildroot} -p / --invalidation-mode unchecked-hash "$pm/pylibs" "$pm/exlibs"
(cd "$pm" && find . -mindepth 1 -name __pycache__ -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -L "$p" ]; then
    printf '%%s\tl\t%%s\n' "${p#./}" "$(readlink "$p")"
  elif [ -d "$p" ]; then
    printf '%%s\td\n' "${p#./}"
  else
    printf '%%s\tf\t%%s\n' "${p#./}" "$(sha256sum < "$p" | cut -d' ' -f1)"
  fi
done) | sha256sum | cut -d' ' -f1 > %{buildroot}%{pmroot}/tree.sha256
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 LICENSE "$lic/LICENSE"
install -m0644 "$pm"/licenses/* "$lic/"
install -m0644 %{SOURCE2} "$lic/LICENSE-charset_normalizer.txt"
install -m0644 %{SOURCE3} "$lic/LICENSE-gamecontrollerdb.txt"

%files
%license %{_licensedir}/%{name}
%dir %{pmroot}
%{pmroot}/PortMaster
%{pmroot}/tree.sha256
