#!/usr/bin/env bash
set -euo pipefail

name=waydroid
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-waydroid.sh <outdir>}
shopt -s nullglob
rpms=("$out"/*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{VERSION} %{ARCH}' "$rpm") == "$name 1.6.3 noarch" ]] || fail "name, version or arch"
[[ $(rpm -qp --qf '%{RELEASE}' "$rpm") == *.blockie ]] || fail "release is not the blockie build"
req=$(rpm -qp --requires "$rpm")
for r in lxc dnsmasq iproute iptables-legacy python3-gobject; do
  grep -qx "$r" <<< "$req" || fail "does not require $r"
done
! grep -qE '^(gtk3|nftables)$|waydroid-selinux' <<< "$req" || fail "still requires gtk3, nftables or waydroid-selinux"
scripts=$(rpm -qp --scripts "$rpm")
! grep -q 'waydroid upgrade' <<< "$scripts" || fail "%post runs waydroid upgrade"
files=$(rpm -qpl "$rpm")
! grep -q '^/usr/share/dbus-1/system-services/' <<< "$files" || fail "ships a D-Bus activation file"
grep -qx /usr/share/dbus-1/system.d/id.waydro.Container.conf <<< "$files" || fail "no D-Bus policy"
grep -qx /usr/lib/systemd/system/waydroid-container.service <<< "$files" || fail "no waydroid-container.service"

t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
lib=$t/usr/lib/waydroid
base=$lib/data/configs/config_base
grep -qx 'lxc.namespace.clone = mnt uts pid net cgroup' "$base" || fail "config_base does not clone mnt uts pid net cgroup"
! grep -q '^lxc\.namespace\.\(keep\|share\)' "$base" || fail "config_base keeps or shares a namespace"
want=$'lxc.include = /var/lib/waydroid/lxc/waydroid/config_nodes\nlxc.include = /var/lib/waydroid/lxc/waydroid/config_session\nlxc.include = /run/blockie-android/lxc.d/devices.conf\nlxc.include = /run/blockie-android/lxc.d/pad.conf\nlxc.include = /run/blockie-android/lxc.d/memory.conf'
[[ $(grep '^lxc\.include' "$base") == "$want" ]] || fail "config_base includes: $(grep '^lxc\.include' "$base" | tr '\n' ' ')"
for c in block_suspend sys_time; do
  grep -qE "^lxc\.cap\.keep = (.* )?$c( |\$)" "$base" || fail "cap.keep lost $c"
done
! grep -q '/sys/kernel/debug' "$lib/tools/helpers/lxc.py" || fail "lxc.py still binds debugfs"
grep -q '"/dev/dma_heap/\*"' "$lib/tools/helpers/lxc.py" || fail "lxc.py no longer binds the dma_heap nodes"
! grep -q 'context=' "$lib/tools/helpers/mount.py" || fail "mount.py sets an SELinux context"
! grep -qE '/vendor/lib(64)?/egl|odm_extra' "$lib/tools/helpers/images.py" || fail "images.py binds the host vendor egl or odm dirs into the guest"
grep -q '^lxc.seccomp.profile' "$lib/data/configs/config_3" && ! grep -q apparmor "$lib/data/configs/config_3" || fail "config_3 is not Fedora's"
net=$lib/data/scripts/waydroid-net.sh
sh -n "$net" || fail "waydroid-net.sh does not parse"
grep -q -- '-j CHECKSUM --checksum-fill || true$' "$net" || fail "the CHECKSUM rule is still fatal"
[[ $(grep -B2 -x '    echo 1 > /proc/sys/net/ipv4/ip_forward' "$net") == '    mkdir -p "${varrun}"'$'\n''    [ -f "${varrun}/ip_forward" ] || cat /proc/sys/net/ipv4/ip_forward > "${varrun}/ip_forward"'$'\n''    echo 1 > /proc/sys/net/ipv4/ip_forward' ]] ||
  fail "ip_forward is not saved before it is set"
for r in '-I INPUT -i ${LXC_BRIDGE} -p icmp --icmp-type echo-request -j ACCEPT' \
  '-I INPUT -i ${LXC_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' '-A INPUT -i ${LXC_BRIDGE} -j DROP' \
  '-I FORWARD -i ${LXC_BRIDGE} -j ACCEPT' '-I FORWARD -o ${LXC_BRIDGE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
  '-A FORWARD -o ${LXC_BRIDGE} -j DROP'; do
  grep -qxF -- "    \$IPTABLES_BIN \$use_iptables_lock $r" "$net" || fail "no rule $r"
  grep -qxF -- "    \$IPTABLES_BIN \$use_iptables_lock -D ${r#-? }" "$net" || fail "stop does not delete $r"
done
! grep -q -- '-o ${LXC_BRIDGE} -j ACCEPT$' "$net" || fail "FORWARD still accepts everything to the bridge"
[[ $(grep -A1 -xF '    [ ! -d /sys/class/net/${LXC_BRIDGE} ] && ip link add dev ${LXC_BRIDGE} type bridge' "$net" | tail -n 1) == \
  '    echo 1 > /proc/sys/net/ipv6/conf/${LXC_BRIDGE}/disable_ipv6 || true' ]] || fail "IPv6 is not off on the bridge right after it is made"
grep -qx '        cat "${varrun}/ip_forward" > /proc/sys/net/ipv4/ip_forward' "$net" || fail "ip_forward is not restored"
grep -q 'IPTABLES_BIN="$(command -v iptables-legacy)"' "$net" || fail "iptables-legacy is not the first choice"
grep -q 'BLOCKIE_ANDROID_LXCLOG") == "1"' "$lib/tools/helpers/lxc.py" &&
  grep -qF '"-o", "/run/blockie-android/lxc.log"' "$lib/tools/helpers/lxc.py" || fail "lxc.py has no opt-in lxc-start log in /run"
cm=$lib/tools/actions/container_manager.py
grep -qx 'BLOCKIE_GUEST_DATA = "/var/lib/blockie/data2/android/guest/data"' "$cm" &&
  grep -qx '        session\["waydroid_data"\] = BLOCKIE_GUEST_DATA' "$cm" &&
  grep -qx '        pw = pwd.getpwuid(int(session\["user_id"\]))' "$cm" &&
  grep -qx '        session\["group_id"\] = str(pw.pw_gid)' "$cm" ||
  fail "the container manager trusts the session's data path, user or group"
grep -qxF '            if any(ord(c) < 32 or ord(c) == 127 or c in " \\" for c in str(k) + str(v)):' "$cm" ||
  fail "the container manager takes session values with control characters, spaces or backslashes"
grep -qxF '        session["xdg_runtime_dir"] = "/run/user/" + str(pw.pw_uid)' "$cm" &&
  grep -qxF '        if not re.fullmatch(r"wayland-[0-9]+", str(session.get("wayland_display", ""))):' "$cm" &&
  grep -qxF '        session["pulse_runtime_path"] = session["xdg_runtime_dir"] + "/pulse"' "$cm" ||
  fail "the session's runtime dir, wayland display or pulse path are not pinned"
grep -qxF '    pulse_host_socket = os.path.realpath(os.path.join(session["pulse_runtime_path"], "native"))' "$lib/tools/helpers/lxc.py" &&
  grep -qxF '    if os.path.exists(pulse_host_socket) and str(os.stat(pulse_host_socket).st_uid) == session["user_id"]:' "$lib/tools/helpers/lxc.py" ||
  fail "the pulse socket is bound without its real path and owner check"
grep -qx '        perm_list = \["/dev/ashmem"\]' "$cm" && ! grep -qE 'dma_heap|renderD|/dev/fb|/dev/video' "$cm" ||
  fail "set_permissions still opens device nodes"
python3 -m py_compile "$cm" || fail "container_manager.py does not compile"
pol=$t/usr/share/dbus-1/system.d/id.waydro.Container.conf
python3 - "$pol" << 'PY' || fail "the D-Bus policy lets others than root and blockie call id.waydro.Container"
import sys
import xml.etree.ElementTree as ET
send = {}
for p in ET.parse(sys.argv[1]).getroot().findall("policy"):
    who = p.get("user") or p.get("context")
    send[who] = any(a.get("send_destination") == "id.waydro.Container" for a in p.findall("allow"))
sys.exit(0 if send == {"root": True, "blockie": True, "default": False} else 1)
PY
python3 -m py_compile "$lib/tools/helpers/lxc.py" || fail "lxc.py does not compile"
unit=$t/usr/lib/systemd/system/waydroid-container.service
grep -qx 'Wants=dev-binderfs.mount' "$unit" || fail "the unit lost the binderfs mount"
grep -qx 'ExecStart=/usr/bin/waydroid container start' "$unit" || fail "the unit does not run the container manager"
echo "pkg-$name: ${rpm##*/} ok"
