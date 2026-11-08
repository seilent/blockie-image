%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           blockie-kernel
Version:        %{kversion}
Release:        1%{?dist}.blockie
Summary:        Android common kernel 5.10 for the KONKR Pocket Block
License:        GPL-2.0-only WITH Linux-syscall-note
URL:            https://github.com/seilent/blockie-image
Vendor:         Blockie
ExclusiveArch:  aarch64
AutoReqProv:    no
Provides:       kernel = %{version}-%{release}
Provides:       kernel-core = %{version}-%{release}
Provides:       kernel-modules = %{version}-%{release}
Provides:       kernel-modules-core = %{version}-%{release}

%description
Linux %{kver}: vmlinuz, config, System.map, the built in module lists and
the out of tree modules in extra/, with blockie_kbase_pidns loaded at boot
through modules-load.d. Vendor modules come from the device.

%install
cp -a %{stage}/. %{buildroot}/

%files
%license /usr/share/licenses/blockie-kernel/LICENSE.kernel
/usr/lib/modules/%{kver}
/usr/lib/modules-load.d/blockie-kbase-pidns.conf
