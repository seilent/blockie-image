#!/usr/bin/env bash
set -euo pipefail

fail() { echo "audio: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "${tmp:?}"' EXIT

ucm=/usr/share/alsa/ucm2
card=$ucm/MediaTek/mt6768-mt6358/PocketBlock.conf
hifi=$ucm/MediaTek/mt6768-mt6358/PocketBlock-HiFi.conf
dl1=/usr/libexec/blockie/dl1
unit=/usr/lib/systemd/system/blockie-dl1.service

for t in alsaucm amixer; do
  command -v "$t" > /dev/null || fail "$t missing"
done
[[ -f $ucm/ucm.conf ]] || fail "alsa-ucm ucm.conf missing"
[[ -f $card && -f $hifi ]] || fail "PocketBlock ucm files missing"
[[ $(readlink "$ucm/conf.d/mt6768-mt6358/mt6768-mt6358.conf") == ../../MediaTek/mt6768-mt6358/PocketBlock.conf ]] ||
  fail "conf.d/mt6768-mt6358/mt6768-mt6358.conf is not the relative link to PocketBlock.conf"

first=$(awk '/SectionVerb/ { v = 1 } v && /EnableSequence/ { e = 1 } e && /cset/ { print; exit }' "$hifi")
[[ $first == *"cset \"name='primary_play_scenario' 1\""* ]] ||
  fail "the HiFi EnableSequence does not start with primary_play_scenario 1: $first"

for jack in no yes; do
  u=$tmp/ucm2-$jack
  cp -a "$ucm" "$u"
  e=x
  [[ $jack == no ]] || e=
  sed -i -e 's/[$]{CardId}/0/g' -e 's/Type ControlExists/Type String/' \
    -e "s/Control \"iface=CARD,name='Headphone Jack'\"/Empty \"$e\"/" "$u/MediaTek/mt6768-mt6358/PocketBlock-HiFi.conf"
  mkdir -p "$u/conf.virt.d"
  ln -s ../conf.d/mt6768-mt6358/mt6768-mt6358.conf "$u/conf.virt.d/mt6768-mt6358.conf"
  ALSA_CONFIG_UCM2=$u alsaucm -c mt6768-mt6358 dump text > "$tmp/dump-$jack" 2> "$tmp/err-$jack" ||
    fail "alsaucm cannot parse the ucm (jack control $jack): $(cat "$tmp/err-$jack")"
  for want in 'Verb.HiFi {' 'Device.Speaker {' 'Device.Headphones {' 'PlaybackPriority 100' 'PlaybackPriority 200'; do
    grep -qF "$want" "$tmp/dump-$jack" || fail "ucm dump lacks $want"
  done
  [[ $(grep -c 'PlaybackPCM ".*hw:0,0"' "$tmp/dump-$jack") == 2 ]] || fail "ucm dump: both devices should play on hw:0,0"
done
grep -qF 'JackControl "Headphone Jack"' "$tmp/dump-yes" || fail "no JackControl when the Headphone Jack control exists"
! grep -qF JackControl "$tmp/dump-no" || fail "JackControl set without a Headphone Jack control"

hits=$(grep -rlF fast_play_scenario /usr /etc 2> /dev/null || true)
[[ -z $hits ]] || fail "files name fast_play_scenario: $hits"

[[ -x $dl1 ]] || fail "$dl1 is not executable"
sh -n "$dl1" || fail "$dl1 does not parse"
for l in DefaultDependencies=no After=systemd-udev-trigger.service Before=sysinit.target Type=oneshot \
  RemainAfterExit=yes "ExecStart=$dl1 set" WantedBy=sysinit.target; do
  grep -qxF "$l" "$unit" || fail "blockie-dl1.service lacks $l"
done
[[ $(readlink -f /etc/systemd/system/sysinit.target.wants/blockie-dl1.service) == "$unit" ]] ||
  fail "blockie-dl1.service is not wanted by sysinit.target"
drop=/usr/lib/systemd/system/user@.service.d/50-blockie-dl1.conf
grep -qxF After=blockie-dl1.service "$drop" || fail "user@.service is not ordered after blockie-dl1"
grep -qxF "ExecStartPre=+$dl1 check" "$drop" || fail "user@.service does not run dl1 check"
grep -qxF "ACTION==\"add\", SUBSYSTEM==\"sound\", KERNEL==\"controlC*\", ATTRS{id}==\"mt6768mt6358\", RUN+=\"$dl1 set\"" \
  /usr/lib/udev/rules.d/60-blockie-dl1.rules || fail "the dl1 udev rule"

while IFS= read -r f; do
  case $f in
  /usr/lib/systemd/system/* | /usr/lib/systemd/user/*)
    rel=${f#/usr/lib/systemd/}
    rest=${rel#*/}
    u=${rest%%/*}
    u=${u%.d}
    [[ $(readlink "/etc/systemd/${rel%%/*}/$u") == /dev/null ]] || fail "$f calls alsactl and $u is not masked"
    ;;
  /usr/lib/udev/rules.d/*)
    [[ $(readlink "/etc/udev/rules.d/${f##*/}") == /dev/null ]] || fail "$f calls alsactl and is not masked"
    ;;
  *)
    fail "$f calls alsactl"
    ;;
  esac
done < <(grep -rlF alsactl /usr/lib/systemd/system /usr/lib/systemd/user /usr/lib/udev/rules.d /etc/systemd /etc/udev \
  2> /dev/null || true)

declare -A in_audio=() uid_name=()
IFS=: read -r _ _ agid members < <(getent group audio) || true
IFS=, read -ra m <<< "${members:-}"
for u in "${m[@]}"; do
  in_audio[$u]=1
done
while IFS=: read -r name _ uid gid _; do
  uid_name[$uid]=$name
  [[ -n ${agid:-} && $gid == "$agid" ]] && in_audio[$name]=1
done < <(getent passwd)
while read -r t name id _; do
  case $t in
  u) uid_name[${id%%:*}]=$name ;;
  m) [[ $id == audio ]] && in_audio[$name]=1 ;;
  esac
done < <(cat /usr/lib/sysusers.d/*.conf 2> /dev/null || true)

noalsa=(blockie-wifi.service blockie-regdom.service blockie-bt.service blockie-blobs.service blockie-boot-ok.service
  blockie-data.service blockie-session-switch@.service blockie-session-switcher.service blockie-setd.service)

clients=0
for f in /usr/lib/systemd/system/*.service /etc/systemd/system/*.service; do
  [[ -f $f && ! -L $f ]] || continue
  n=${f##*/}
  all=$(cat "$f" /usr/lib/systemd/system/"$n".d/*.conf /etc/systemd/system/"$n".d/*.conf 2> /dev/null || true)
  client=0
  case $n in
  blockie-dl1.service) ;;
  pipewire* | wireplumber* | bluealsa* | retroarch* | funeos* | blockie-*) client=1 ;;
  esac
  for x in "${noalsa[@]}"; do
    [[ $n == "$x" ]] && client=0
  done
  grep -Eq '^(Group|SupplementaryGroups)=(.*[[:space:]])?audio([[:space:]]|$)' <<< "$all" && client=1
  grep -q '^PAMName=' <<< "$all" && client=1
  user=$(sed -n 's/^User=//p' <<< "$all" | tail -n 1)
  [[ -n $user && -n ${uid_name[$user]:-} ]] && user=${uid_name[$user]}
  [[ -n $user && -n ${in_audio[$user]:-} ]] && client=1
  (( client )) || continue
  clients=$((clients + 1))
  grep -Eq '^After=(.*[[:space:]])?blockie-dl1\.service([[:space:]]|$)' <<< "$all" || fail "$n opens ALSA without After=blockie-dl1.service"
  grep -qxF "ExecStartPre=+$dl1 check" <<< "$all" || fail "$n opens ALSA without ExecStartPre=+$dl1 check"
  ! grep -Eq '^(Requires|BindsTo|Requisite)=.*blockie-dl1' <<< "$all" || fail "$n requires blockie-dl1"
done

"$dl1" check || fail "dl1 check fails without the card"
printf ' 0 [mt6768mt6358   ]: mt6768-mt6358 - mt6768-mt6358\n                      mt6768-mt6358\n' > "$tmp/cards"
rc=0
DL1_CARDS=$tmp/cards "$dl1" check 2> /dev/null || rc=$?
[[ $rc == 1 ]] || fail "dl1 check on a listed card it cannot read gave rc $rc, want 1"
rc=0
DL1_CARDS=/dev/null "$dl1" set 2> /dev/null || rc=$?
[[ $rc == 2 ]] || fail "dl1 set without the card gave rc $rc, want 2"

session_user=blockie
grep -Eq "^u $session_user [0-9]+" /usr/lib/sysusers.d/blockie.conf || fail "session user $session_user not in sysusers"
[[ -n ${in_audio[$session_user]:-} ]] || fail "session user $session_user is not in the audio group"

for p in pipewire pipewire-libs pipewire-alsa pipewire-pulseaudio pipewire-utils wireplumber; do
  rpm -q "$p" > /dev/null || fail "$p not installed"
done
for t in python3 wpctl pw-cat spa-json-dump spa-acp-tool; do
  command -v "$t" > /dev/null || fail "$t missing"
done
for l in sockets.target.wants/pipewire.socket sockets.target.wants/pipewire-pulse.socket \
  pipewire.service.wants/wireplumber.service; do
  [[ -L /etc/systemd/user/$l ]] || fail "user unit $l is not enabled"
done
for f in /usr/lib/spa-0.2/bluez5/libspa-bluez5.so /usr/lib64/spa-0.2/bluez5/libspa-bluez5.so; do
  [[ -f $f ]] && bluez=$f
done
[[ -n ${bluez:-} && -f ${bluez%/*}/libspa-codec-bluez5-sbc.so ]] || fail "no PipeWire bluez5 plugin with SBC"

cmp -s <(printf '[Service]\nExecStart=-udevadm trigger --type=devices --action=add --subsystem-match=sound\n') \
  /usr/lib/systemd/system/systemd-udev-trigger.service.d/52-blockie-sound.conf || fail "sound coldplug drop-in"

wp=/usr/share/wireplumber/wireplumber.conf.d
spa-json-dump "$wp/50-blockie-alsa.conf" > "$tmp/alsa.json" || fail "50-blockie-alsa.conf does not parse"
jq -e '.["monitor.alsa.rules"] == [{
  "matches": [{"api.alsa.card.name": "mt6768-mt6358"}],
  "actions": {"update-props": {"api.alsa.use-acp": true, "api.alsa.use-ucm": true, "api.alsa.soft-mixer": true,
    "api.acp.disable-pro-audio": true, "device.profile-set": "blockie-ucm-only.conf"}}}]' "$tmp/alsa.json" > /dev/null ||
  fail "50-blockie-alsa.conf is not the planned card rule: $(cat "$tmp/alsa.json")"
spa-json-dump "$wp/51-blockie-bluez.conf" > "$tmp/bluez.json" || fail "51-blockie-bluez.conf does not parse"
jq -e '.["monitor.bluez.properties"]["bluez5.roles"] == ["a2dp_source"]
  and .["wireplumber.profiles"].main == {"monitor.bluez.seat-monitoring": "disabled", "monitor.bluez-midi": "disabled"}' \
  "$tmp/bluez.json" > /dev/null ||
  fail "51-blockie-bluez.conf: $(cat "$tmp/bluez.json")"
hits=$(grep -rlE '"?api\.alsa\.use-(acp|ucm)"? *[=:] *"?false|"?api\.acp\.disable-pro-audio"? *[=:] *"?false' \
  /usr/share/wireplumber /etc/wireplumber /usr/share/pipewire /etc/pipewire 2> /dev/null || true)
[[ -z $hits ]] || fail "files turn ACP, UCM or the pro audio guard back: $hits"
for f in /usr/share/wireplumber/wireplumber.conf /etc/wireplumber/wireplumber.conf \
  /usr/share/wireplumber/wireplumber.conf.d/*.conf /etc/wireplumber/wireplumber.conf.d/*.conf; do
  [[ -f $f && $f != "$wp/50-blockie-alsa.conf" ]] || continue
  spa-json-dump "$f" > "$tmp/frag.json" || fail "$f does not parse"
  keys=$(jq -r '[.["monitor.alsa.rules"][]?.actions["update-props"] // {} | keys[] | select(IN("api.alsa.use-acp",
    "api.alsa.use-ucm", "api.alsa.soft-mixer", "api.acp.disable-pro-audio", "device.profile-set"))] | join(" ")' \
    "$tmp/frag.json") || fail "$f: jq failed"
  [[ -z $keys ]] || fail "$f sets $keys in monitor.alsa.rules"
done

ps=/usr/share/alsa-card-profile/mixer/profile-sets
[[ -f $ps/default.conf ]] || fail "no ACP profile sets in $ps"
cmp -s <(printf '[General]\nauto-profiles = no\n') "$ps/blockie-ucm-only.conf" || fail "blockie-ucm-only.conf"
! grep -q CapturePCM "$tmp/dump-yes" || fail "the ucm has a capture device, capture memifs have no DRAM switch"

jack=/usr/libexec/blockie/blockie-jack
[[ -x $jack ]] || fail "$jack is not executable"
python3 -m py_compile "$jack" 2> "$tmp/pyc" || fail "$jack does not compile: $(cat "$tmp/pyc")"
for l in Type=notify "ExecStart=$jack" Restart=on-failure StartLimitIntervalSec=60 StartLimitBurst=5 \
  WantedBy=multi-user.target; do
  grep -qxF "$l" /usr/lib/systemd/system/blockie-jack.service || fail "blockie-jack.service lacks $l"
done
grep -qxF After=blockie-jack.service /usr/lib/systemd/system/user@.service.d/51-blockie-jack.conf ||
  fail "user@.service is not ordered after blockie-jack"
[[ -L /etc/systemd/system/multi-user.target.wants/blockie-jack.service ]] || fail "blockie-jack.service is not enabled"
grep -qxF 'ACTION!="remove", SUBSYSTEM=="sound", KERNEL=="controlC*", ATTRS{id}=="mt6768mt6358", TAG+="systemd", ENV{SYSTEMD_WANTS}+="blockie-jack.service"' \
  /usr/lib/udev/rules.d/61-blockie-jack.rules || fail "the card does not pull in blockie-jack.service"
python3 - "$jack" "$tmp" << 'EOF' || fail "blockie-jack functions"
import importlib.machinery
import importlib.util
import os
import struct
import sys

path, tmp = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("blockie_jack", path)
j = importlib.util.module_from_spec(importlib.util.spec_from_loader("blockie_jack", loader))
loader.exec_module(j)
cards = " 1 [Dummy          ]: Dummy - Dummy\n 0 [mt6768mt6358   ]: mt6768-mt6358 - mt6768-mt6358\n"
assert j.find_card(cards) == 0
assert j.find_card(" 0 [HDMI           ]: HDA-Intel - HDA ATI HDMI\n") is None
for e, name in (("event3", "AYANEO Controller"), ("event4", "mt6768-mt6358 Headset Jack"), ("mouse0", "x")):
    os.makedirs(f"{tmp}/sys/{e}/device")
    with open(f"{tmp}/sys/{e}/device/name", "w") as f:
        f.write(name + "\n")
assert j.find_jack(f"{tmp}/sys") == "event4"
assert j.find_jack(f"{tmp}/none") is None
assert j.eviocgsw(3) == 0x8003451B
assert j.plugged(bytes([0x04, 0, 0])) and j.plugged(bytes([0x40, 0, 0]))
assert not j.plugged(bytes([0x10, 0, 0])) and not j.plugged(bytes([0x80, 0, 0]))
assert j.EVENT.size == 24
ev = struct.pack("@llHHi", 1, 2, 5, 2, 1) + struct.pack("@llHHi", 1, 2, 0, 0, 0)
assert j.decode(ev) == [(5, 2, 1), (0, 0, 0)]
EOF
rc=0
BLOCKIE_JACK_CARDS=/dev/null "$jack" 2> /dev/null || rc=$?
[[ $rc == 0 ]] || fail "blockie-jack without the card gave rc $rc, want 0"

vol=/usr/libexec/blockie/blockie-volume
[[ -x $vol ]] || fail "$vol is not executable"
sh -n "$vol" || fail "$vol does not parse"
rc=0
"$vol" 2> /dev/null || rc=$?
[[ $rc == 2 ]] || fail "blockie-volume without a command gave rc $rc, want 2"
mkdir "$tmp/bin"
cat > "$tmp/bin/wpctl" << 'EOF'
#!/bin/sh
echo "$XDG_RUNTIME_DIR $*"
EOF
chmod 755 "$tmp/bin/wpctl"
for k in up down; do
  h=/usr/lib/blockie/hooks.d/volume-$k
  [[ -x $h ]] || fail "$h is not executable"
  [[ $(< "$h") == $'#!/bin/sh\nexec '"$vol $k" ]] || fail "$h does not run blockie-volume $k"
done
want="/run/user/$(id -u) set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"
got=$(env -u XDG_RUNTIME_DIR PATH="$tmp/bin:$PATH" /usr/lib/blockie/hooks.d/volume-up)
[[ $got == "$want" ]] || fail "volume-up ran '$got', want '$want'"
want="/x set-volume @DEFAULT_AUDIO_SINK@ 2%-"
got=$(XDG_RUNTIME_DIR=/x BLOCKIE_VOLUME_STEP=2% PATH="$tmp/bin:$PATH" /usr/lib/blockie/hooks.d/volume-down)
[[ $got == "$want" ]] || fail "volume-down ran '$got', want '$want'"

echo "audio: ok, $clients audio client units, PipeWire $(rpm -q --qf '%{VERSION}' pipewire), WirePlumber $(rpm -q --qf '%{VERSION}' wireplumber)"
