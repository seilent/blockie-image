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
  blockie-data.service)

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

echo "audio: ok, $clients audio client units"
