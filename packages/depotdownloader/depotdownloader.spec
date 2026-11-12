%global debug_package %{nil}
%global _build_id_links none
%global commit c553ef4d60c00a4f5fd16c9fe017f569001589ff
%global tag DepotDownloader_3.4.0
%global skcommit c31ce16a766c35a0a3a94a6802f13e9bbd2a1281
%global sktag 3.2.0
%global ddroot %{_prefix}/lib/blockie/depotdownloader
%global __requires_exclude_from ^%{ddroot}/
%global __provides_exclude_from ^%{ddroot}/

Name:           depotdownloader
Version:        3.4.0
Release:        1%{?dist}
Summary:        DepotDownloader and SteamKit2 for Blockie's Steam game files
License:        GPL-1.0-or-later AND LGPL-2.1-only AND Apache-2.0 AND MIT
URL:            https://github.com/SteamRE/DepotDownloader
BuildArch:      noarch
Source0:        DepotDownloader-%{commit}.tar.gz
Source1:        SteamKit-%{skcommit}.tar.gz
Source2:        depotdownloader-nuget-%{nugetid}.tar
Source3:        nuget.config
Source4:        DepotDownloader.packages.lock.json
Source5:        SteamKit2.packages.lock.json
Source6:        Apache-2.0.txt
Source7:        protobuf-net-Licence.txt
Source8:        QRCoder-LICENSE.txt
Source9:        ZstdSharp-LICENSE.txt
Source10:       dotnet-runtime-LICENSE.TXT
Source11:       CsWin32-LICENSE.txt
Patch0:         depotdownloader-blockie.patch
BuildRequires:  dotnet-sdk-10.0
BuildRequires:  tar
BuildRequires:  patch
Requires:       dotnet-runtime-10.0

%description
DepotDownloader %{version} built from source against SteamKit2 %{sktag} from source, framework dependent on .NET 10,
with Blockie's patch: a machine channel on a passed fd, the account file at a set path, no LogOff on exit and no
console prompts while the channel is set. The leaf NuGet assemblies (protobuf-net, QRCoder, ZstdSharp.Port,
System.IO.Hashing, Microsoft.Win32.Registry) come from nuget.org, pinned by content hash in the lock files.

%prep
%setup -q -c -n %{name}-%{version} -a 1
mv DepotDownloader-%{commit} dd
mv SteamKit-%{skcommit} sk
rm dd/global.json sk/global.json
%patch -P 0 -p1
install -m0644 %{SOURCE4} dd/DepotDownloader/packages.lock.json
install -m0644 %{SOURCE5} sk/SteamKit2/SteamKit2/packages.lock.json
mkdir feed
tar -C feed --no-same-owner -xf %{SOURCE2}
install -m0644 %{SOURCE3} nuget.config

%build
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_CLI_HOME=$PWD/home
export HOME=$PWD/home NUGET_HTTP_CACHE_PATH=$PWD/home/http-cache NUGET_PLUGINS_CACHE_PATH=$PWD/home/plugins-cache
dotnet restore dd/DepotDownloader/DepotDownloader.csproj --configfile nuget.config --locked-mode --packages $PWD/packages \
  -p:NuGetAudit=false
dotnet publish dd/DepotDownloader/DepotDownloader.csproj --no-restore -c Release -o $PWD/out -maxcpucount:%{_smp_build_ncpus} \
  -p:ContinuousIntegrationBuild=true -p:TreatWarningsAsErrors=false -p:EnforceCodeStyleInBuild=false \
  -p:DeterministicSourcePaths=false -p:EnableSourceLink=false -p:EnableSourceControlManagerQueries=false \
  -p:PathMap=$PWD=/build -p:DebugType=none -p:DocumentationFile= -p:UseSharedCompilation=false -p:NuGetAudit=false
dotnet build-server shutdown

%install
d=%{buildroot}%{ddroot}
install -d "$d"
install -m0644 out/*.dll out/DepotDownloader.runtimeconfig.json out/DepotDownloader.deps.json "$d/"
install -d %{buildroot}%{_libexecdir}/blockie
printf '#!/usr/bin/sh\nexec /usr/bin/dotnet %s/DepotDownloader.dll "$@"\n' %{ddroot} > %{buildroot}%{_libexecdir}/blockie/depotdownloader
chmod 0755 %{buildroot}%{_libexecdir}/blockie/depotdownloader
lic=%{buildroot}%{_licensedir}/%{name}
install -Dm0644 dd/LICENSE "$lic/LICENSE"
install -m0644 sk/LICENSE "$lic/SteamKit2-LICENSE"
install -m0644 sk/SteamKit2/SteamKit2/license.txt "$lic/SteamKit2-license.txt"
install -m0644 "sk/SteamKit2/SteamKit2/3rd party.txt" "$lic/SteamKit2-3rd-party.txt"
install -m0644 %{SOURCE6} %{SOURCE7} %{SOURCE8} %{SOURCE9} %{SOURCE10} %{SOURCE11} "$lic/"

%files
%license %{_licensedir}/%{name}
%dir %{_prefix}/lib/blockie
%{ddroot}
%dir %{_libexecdir}/blockie
%{_libexecdir}/blockie/depotdownloader
