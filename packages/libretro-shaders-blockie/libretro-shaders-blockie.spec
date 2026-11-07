%global commit 1aaabbebdd88a8a89a82edfdc94e10580c99ffdd
%global raw https://raw.githubusercontent.com/libretro/glsl-shaders/%{commit}

Name:           libretro-shaders-blockie
Version:        1
Release:        1%{?dist}
Summary:        Blockie RetroArch shader presets and the GLSL shaders they use
License:        GPL-2.0-only AND GPL-2.0-or-later AND MIT AND LicenseRef-Fedora-Public-Domain
URL:            https://github.com/libretro/glsl-shaders
BuildArch:      noarch
Source0:        libretro-shaders-blockie-src.tar.gz
Source1:        %{raw}/crt/shaders/crt-gdv-mini.glsl
Source2:        %{raw}/handheld/shaders/lcd3x.glsl
Source3:        %{raw}/handheld/shaders/zfast_lcd.glsl
Source4:        %{raw}/handheld/shaders/lcd1x.glsl
Source5:        %{raw}/handheld/shaders/sameboy-lcd.glsl
Source6:        %{raw}/handheld/shaders/retro-v2.glsl

%description
Blockie's RetroArch presets for the gl driver in /usr/share/libretro/shaders/blockie, the
sp101-color GLSL port, and the GLSL shaders they use from libretro/glsl-shaders at %{commit}
at their upstream paths in /usr/share/libretro/shaders/glsl-shaders.

%prep
%setup -q -c -n libretro-shaders-blockie

%build

%install
gs=%{buildroot}%{_datadir}/libretro/shaders/glsl-shaders
install -Dm0644 %{SOURCE1} "$gs/crt/shaders/crt-gdv-mini.glsl"
install -Dm0644 %{SOURCE2} "$gs/handheld/shaders/lcd3x.glsl"
install -Dm0644 %{SOURCE3} "$gs/handheld/shaders/zfast_lcd.glsl"
install -Dm0644 %{SOURCE4} "$gs/handheld/shaders/lcd1x.glsl"
install -Dm0644 %{SOURCE5} "$gs/handheld/shaders/sameboy-lcd.glsl"
install -Dm0644 %{SOURCE6} "$gs/handheld/shaders/retro-v2.glsl"
install -d %{buildroot}%{_datadir}/libretro/shaders/blockie
install -m0644 blockie/*.glslp blockie/*.glsl %{buildroot}%{_datadir}/libretro/shaders/blockie/

%files
%license LICENSE
%dir %{_datadir}/libretro
%dir %{_datadir}/libretro/shaders
%{_datadir}/libretro/shaders/glsl-shaders
%{_datadir}/libretro/shaders/blockie
