Name:           blockie-gpu
Version:        1
Release:        1%{?dist}
Summary:        Blockie GPU userspace configuration
License:        GPL-2.0-only
BuildArch:      noarch
Source0:        blockie-gpu-src.tar.gz
BuildRequires:  python3
BuildRequires:  coreutils
BuildRequires:  util-linux-core
Requires:       blockie-tools
Requires:       systemd-udev
Requires:       bash
Requires:       coreutils
Requires:       grep
Requires:       util-linux-core

%description
The pinned list entry and Vulkan ICD for the Mali-G52 userspace blob, which is never
in the image and is linked at boot by blockie-blobs; udev modes for the GPU nodes;
blockie-gpufreq pins the GPU operating point for timed runs.

%prep
%setup -q -c -n blockie-gpu

%build

%check
t=$(mktemp -d)
chmod 0777 "$t"
chmod -R a+rX .
python3 -c 'import os, sys; os.setgroups([]); os.setgid(65534); os.setuid(65534); os.environ["TMPDIR"] = sys.argv[1]; os.environ["GPU_FILES"] = sys.argv[2]; os.execv(sys.argv[3], sys.argv[3:])' \
  "$t" "$PWD/files" "$PWD/tests/test-blockie-gpu"
rm -rf "${t:?}"

%install
install -Dm0644 files/usr/share/blockie/blobs.d/rk-g29p1.conf %{buildroot}%{_datadir}/blockie/blobs.d/rk-g29p1.conf
install -Dm0644 files/usr/share/blockie/vulkan/rk-g29p1.json %{buildroot}%{_datadir}/blockie/vulkan/rk-g29p1.json
install -Dm0644 files/usr/lib/udev/rules.d/60-blockie-gpu.rules %{buildroot}%{_prefix}/lib/udev/rules.d/60-blockie-gpu.rules
install -Dm0755 files/usr/libexec/blockie/blockie-gpufreq %{buildroot}%{_libexecdir}/blockie/blockie-gpufreq

%files
%{_datadir}/blockie/blobs.d/rk-g29p1.conf
%dir %{_datadir}/blockie/vulkan
%{_datadir}/blockie/vulkan/rk-g29p1.json
%{_prefix}/lib/udev/rules.d/60-blockie-gpu.rules
%{_libexecdir}/blockie/blockie-gpufreq
