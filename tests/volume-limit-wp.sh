#!/usr/bin/env bash
set -u

items=" ${*:-1 2 3 4 5 6 7} "
pwconf=/usr/share/pipewire/pipewire.conf.d/60-blockie-volume-limit.conf
wpconf=/usr/share/wireplumber/wireplumber.conf.d/60-blockie-volume-limit.conf
script=/usr/share/wireplumber/scripts/blockie/volume-limit.lua
vol=${BLOCKIE_VOLUME_BIN:-/usr/libexec/blockie/blockie-volume}
t=$(mktemp -d "${TMPDIR:-/tmp}/vlwp.XXXXXX")
fails=0
pw_pid=
wp_pid=
play_pid=
rec_pid=
mon_pid=
mkdir -p "$t/orig" "$t/run" "$t/config/wireplumber/wireplumber.conf.d" "$t/state"
chmod 700 "$t/run"
cp -p "$pwconf" "$wpconf" "$script" "$t/orig/"
export XDG_RUNTIME_DIR=$t/run XDG_CONFIG_HOME=$t/config XDG_STATE_HOME=$t/state
state=$t/state/wireplumber/sm-settings

cleanup() {
  local p
  for p in $mon_pid $rec_pid $play_pid $wp_pid $pw_pid; do
    kill "$p" 2> /dev/null
  done
  wait 2> /dev/null
  cp -p "$t/orig/${pwconf##*/}" "$pwconf"
  cp -p "$t/orig/${script##*/}" "$script"
  rm -rf "${t:?}"
}
trap cleanup EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "PASS $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
  fi
}

want() { [[ $items == *" $1 "* ]]; }

tw() { timeout -k 1 5 "$@"; }

cat > "$t/config/wireplumber/wireplumber.conf.d/90-blockie-test.conf" << 'EOF'
wireplumber.profiles = {
  blockie-test = {
    inherits = [ main ]
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
  }
}
EOF

cat > "$t/lv.py" << 'EOF'
import math
import struct
import sys
import wave


def db(x):
    return 20 * math.log10(x) if x > 0 else -200.0


def median(v):
    v = sorted(v)
    return v[len(v) // 2]


if sys.argv[1] == "tone":
    a = 10 ** (float(sys.argv[4]) / 20) * 2147483647
    w = wave.open(sys.argv[2], "wb")
    w.setnchannels(2)
    w.setsampwidth(4)
    w.setframerate(48000)
    period = b"".join(struct.pack("<ii", v, v) for v in (int(a * math.sin(2 * math.pi * i / 48)) for i in range(48)))
    w.writeframes(period * int(float(sys.argv[3]) * 1000))
    w.close()
    sys.exit(0)
w = wave.open(sys.argv[2])
data = w.readframes(w.getnframes())
x = struct.unpack("<%di" % (len(data) // 4), data)[0::w.getnchannels()]
peaks = [db(max(abs(v) for v in x[i:i + 48]) / 2147483648.0) for i in range(0, len(x) - 47, 48)]
if len(peaks) < 300:
    print("short")
    sys.exit(1)
if sys.argv[1] == "span":
    print("%.2f %.2f" % (max(peaks), median(peaks[-120:-20])))
    sys.exit(0)
if sys.argv[1] == "level":
    print("%.2f" % median(peaks[len(peaks) // 4:3 * len(peaks) // 4]))
    sys.exit(0)
heard = [i for i, p in enumerate(peaks) if p > -150]
if not heard or heard[-1] - heard[0] < 300:
    print("silent")
    sys.exit(1)
body = peaks[heard[0] + 20:heard[-1] - 20]
start = median(body[:100])
end = median(body[-100:])
groups = []
for p in body:
    if groups and abs(p - groups[-1][0]) <= 0.15:
        groups[-1][1] += 1
    else:
        groups.append([p, 1])
levels = [g[0] for g in groups if g[1] >= 2]
jumps = [b - a for a, b in zip(levels, levels[1:])]
print("%.2f %.2f %.2f %.2f %d" % (start, end, max(body) - start, max([abs(j) for j in jumps] or [0]), len(jumps)))
EOF
python3 "$t/lv.py" tone "$t/tone.wav" 30 -60 || { echo "volume-limit-wp: cannot write the tone" >&2; exit 2; }

start_pw() {
  pipewire > "$t/pw.log" 2>&1 &
  pw_pid=$!
  for _ in $(seq 50); do tw pw-cli info 0 > /dev/null 2>&1 && return 0; sleep 0.1; done
  echo "FAIL wait: pipewire did not answer within 5 s" >&2
  return 1
}

stop_pw() {
  [[ -z $pw_pid ]] || { kill "$pw_pid" 2> /dev/null; wait "$pw_pid" 2> /dev/null; }
  pw_pid=
}

start_wp() {
  WIREPLUMBER_DEBUG=W,s-blockie-volume:I wireplumber -p blockie-test >> "$t/wp.log" 2>&1 &
  wp_pid=$!
  for _ in $(seq 50); do
    [[ $(tw wpctl settings blockie.volume-limit 2> /dev/null) == Value:* ]] && { sleep 0.5; return 0; }
    sleep 0.1
  done
  echo "FAIL wait: wireplumber did not show blockie.volume-limit within 5 s" >&2
  return 1
}

stop_wp() {
  [[ -z $wp_pid ]] || { kill "$wp_pid" 2> /dev/null; wait "$wp_pid" 2> /dev/null; }
  wp_pid=
}

dump() { tw pw-dump > "$t/dump.json" 2> /dev/null || echo '[]' > "$t/dump.json"; }

nid() {
  dump
  jq -r --arg n "$1" '[.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == $n) | .id][0] // empty' \
    "$t/dump.json"
}

props() {
  dump
  jq -c --arg n "$1" '[.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == $n)
    | (.info.params.Props // []) | add][0] // {}' "$t/dump.json"
}

mult() { props blockie.volume-limit | jq -r '(.params // []) as $p | [range(0; $p | length; 2) | select($p[.] == "gain:Mult") | $p[. + 1]][0] // empty'; }

cvol() { props "$1" | jq -r '(.channelVolumes // []) | map(. * 10000 | round / 10000 | tostring) | join(" ")'; }

links() {
  dump
  jq -r '([.[] | select(.type == "PipeWire:Interface:Node") | {(.id | tostring): .info.props["node.name"]}] | add) as $n
    | .[] | select(.type == "PipeWire:Interface:Link")
    | "\($n[.info["output-node-id"] | tostring]) \($n[.info["input-node-id"] | tostring])"' "$t/dump.json" | sort -u
}

linked() { links | grep -qxF "$1 $2"; }

number() { tw wpctl get-volume "$(nid "$1")" 2> /dev/null | awk '{ printf "%d", $2 * 100 + 0.5 }'; }

applied() { tw pw-metadata -n blockie-volume-limit 0 applied 2> /dev/null | sed -n "s/.* value:'\([^']*\)'.*/\1/p" | tail -n 1; }

near() { awk -v a="$1" -v b="$2" -v d="$3" 'BEGIN { exit !(a != "" && a - b <= d && b - a <= d) }'; }

scriptlog() { tail -n +"$(($1 + 1))" "$t/wp.log" | grep 's-blockie-volume' | sed 's/^[^ ]* [^ ]* *//' | tr '\n' '|'; }

settle() {
  for _ in $(seq 30); do near "$(applied)" "$1" 0.001 && { sleep 0.5; return 0; }; sleep 0.1; done
  echo "FAIL wait: applied did not read $1 within 3 s (reads '$(applied)'), the script's last lines: $(grep 's-blockie-volume' "$t/wp.log" | tail -n 12 | tr '\n' '|')" >&2
  return 1
}

lim() {
  local v out n0 rc
  v=$(printf '%.2f' "$1")
  n0=$(wc -l < "$t/wp.log")
  out=$(tw wpctl settings --save blockie.volume-limit "$v" 2>&1)
  tw pw-metadata -n blockie-volume-limit 0 push "$(date +%s%N)" > /dev/null 2>&1
  settle "$1"
  rc=$?
  echo "LOG lim $v, wpctl said '$out', the script: $(scriptlog "$n0")" >&2
  return "$rc"
}

flushed() { sleep 1.5; }

standin() {
  local extra=
  [[ ${3:-} != card ]] || extra='api.alsa.card.name = "mt6768-mt6358"'
  tw pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = $1 media.class = Audio/Sink
    audio.position = [ FL FR ] monitor.channel-volumes = true priority.session = $2 object.linger = true $extra }" > /dev/null
  for _ in $(seq 50); do [[ -n $(nid "$1") ]] && { sleep 0.3; return 0; }; sleep 0.1; done
  echo "FAIL wait: stand-in $1 did not appear within 5 s" >&2
  return 1
}

standins() {
  standin test.card 1000 card && standin test.headset 900 || return 1
  tw wpctl set-volume "$(nid test.card)" 1.0
  tw wpctl set-volume "$(nid test.headset)" 1.0
}

play() {
  stop_play
  pw-play -P "{ node.name = ${2:-test.play} }" ${1:+--volume "$1"} "$t/tone.wav" > /dev/null 2>&1 &
  play_pid=$!
  for _ in $(seq 50); do [[ -n $(nid "${2:-test.play}") ]] && { sleep 0.5; return 0; }; sleep 0.1; done
  echo "FAIL wait: stream ${2:-test.play} did not appear within 5 s" >&2
  return 1
}

stop_play() {
  [[ -z $play_pid ]] || { kill "$play_pid" 2> /dev/null; wait "$play_pid" 2> /dev/null; }
  play_pid=
}

rec_open() {
  pw-record -P '{ node.autoconnect = false node.name = test.rec }' --format s32 --rate 48000 --channels 2 \
    --channel-map FL,FR "$1" > "$t/rec.log" 2>&1 &
  rec_pid=$!
}

rec_link() {
  local i
  for i in $(seq 100); do
    tw pw-link "$1:${2}_FL" test.rec:input_FL > /dev/null 2>&1 && tw pw-link "$1:${2}_FR" test.rec:input_FR > /dev/null 2>&1 &&
      { tw pw-link -l > "$t/rec-links.txt" 2>&1; return 0; }
    sleep 0.05
  done
  echo "FAIL wait: the recorder could not link to $1 ${2} within 5 s" >&2
  return 1
}

rec_stop() {
  [[ -z $rec_pid ]] || { kill -INT "$rec_pid" 2> /dev/null; timeout 5 tail --pid="$rec_pid" -f /dev/null; kill -9 "$rec_pid" 2> /dev/null; }
  rec_pid=
}

level() {
  rec_open "$t/l.wav"
  rec_link "$1" "$2" || { rec_stop; echo unlinked; return; }
  sleep 1.3
  rec_stop
  python3 "$t/lv.py" level "$t/l.wav"
}

change() {
  rec_open "$t/c.wav"
  rec_link "$1" "$2" || { rec_stop; echo unlinked; return; }
  sleep 0.3
  shift 2
  "$@" > /dev/null
  sleep 0.5
  rec_stop
  python3 "$t/lv.py" change "$t/c.wav"
}

echo "INFO $(pipewire --version | grep -m 1 -o 'libpipewire [0-9.]*'), $(wireplumber --version | grep -m 1 -o 'libwireplumber [0-9.]*')"
start_pw || { echo "volume-limit-wp: pipewire does not start: $(tail -n 5 "$t/pw.log")" >&2; exit 2; }
start_wp || { echo "volume-limit-wp: wireplumber does not start: $(tail -n 5 "$t/wp.log")" >&2; exit 2; }
standins || { echo "volume-limit-wp: no stand-ins" >&2; exit 2; }

if want 1; then
  got=$(tw wpctl settings blockie.volume-limit)
  m=$(mult)
  [[ $got != *Saved* && -z $(applied) ]] && near "$(awk '$1 == "Value:" { print $2 }' <<< "$got")" 1.0 0.001 &&
    near "$m" 0 0.000001 && ! grep -q 'volume-limit.lua.*\(error\|failed\)' "$t/wp.log"
  res $? "1 with no saved limit the filter stays silent until the first push: '$got', gain '$m', applied '$(applied)'"
  lim 0.6
  a=$(tw wpctl settings blockie.volume-limit)
  m=$(mult)
  flushed
  echo "READ 1 the state file after --save: $state: $(grep -h 'volume-limit' "$state" 2> /dev/null || echo missing)"
  stop_wp
  start_wp
  b=$(tw wpctl settings blockie.volume-limit)
  [[ $a == "Value: 0.60 (Saved: 0.60)" && $b == "Value: 0.60 (Saved: 0.60)" ]] && near "$m" 0.216 0.001 &&
    near "$(mult)" 0.216 0.001 && near "$(applied)" 0.6 0.001
  res $? "1 the first push opens the filter and --save survives a WirePlumber restart: '$a', gain $m, then '$b', gain $(mult), applied $(applied)"
  play
  tw wpctl settings --save blockie.volume-limit 0.50 > /dev/null
  sleep 0.5
  stop_wp
  rec_open "$t/warm.wav"
  rec_link blockie.volume-limit.output output > /dev/null 2>&1 &
  lk=$!
  start_wp
  wait "$lk"
  echo "READ 1 the recorder's links after the restart: $(tw pw-link -l | grep -A2 '^test.rec' | tr '\n' ' ')"
  sleep 1
  m=$(mult)
  ap=$(applied)
  echo "READ 1 a restart right after --save 0.50 (the state is written 1 s after the save): $(tw wpctl settings blockie.volume-limit)"
  rec_stop
  stop_play
  read -r top end <<< "$(python3 "$t/lv.py" span "$t/warm.wav")"
  near "$m" 0.125 0.001 && near "$ap" 0.5 0.001 && awk -v t="$top" 'BEGIN { exit !(t <= -78.06 + 0.2) }'
  res $? "1 a restart right after --save 0.50 opens warm at the gain PipeWire holds, never above the newer limit: gain $m, applied '$ap', highest peak $top dBFS, end $end dBFS"
  lim 0.6
  flushed
  before=$(tw wpctl settings blockie.volume-limit)
  out=$(tw wpctl settings blockie.volume-limit 1.5)
  rc=$?
  [[ $rc == 0 && $out == Failed* && $(tw wpctl settings blockie.volume-limit) == "$before" ]]
  res $? "1 1.5 is refused with exit 0 and the value stays: rc $rc '$out', '$before'"
  stop_wp
  tw wpctl settings blockie.volume-limit > /dev/null 2>&1
  rc=$?
  start_wp
  [[ $rc == 3 ]]
  res $? "1 with WirePlumber stopped wpctl settings exits $rc, want 3"
fi
lim 1.0
flushed

if want 2; then
  play
  linked test.play blockie.volume-limit && linked blockie.volume-limit.output test.card &&
    ! linked test.play test.card
  res $? "2 a stream to the default links stream, filter, card stand-in: $(links | tr '\n' ',')"
  d=$(tw wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n 's/.*node.name = "\(.*\)"/\1/p')
  [[ $d == test.card ]]
  res $? "2 the default sink is the card stand-in: $d"
  tw wpctl set-default "$(nid test.headset)"
  sleep 1
  linked test.play test.headset && ! linked test.play blockie.volume-limit
  r=$?
  off=$(links | tr '\n' ',')
  tw wpctl set-default "$(nid test.card)"
  sleep 1
  [[ $r == 0 ]] && linked test.play blockie.volume-limit
  res $? "2 the headset as default moves the stream off the filter and back: $off then $(links | tr '\n' ',')"
  stop_play
  tw pw-cli destroy "$(nid test.card)" > /dev/null
  sleep 1
  play
  linked test.play test.headset && ! linked test.play blockie.volume-limit
  res $? "2 a stand-in without the card's name gets no filter: $(links | tr '\n' ',')"
  stop_play
  tw pw-cli destroy "$(nid test.headset)" > /dev/null
  sleep 1
  standins
  n0=$(grep -c 'left out of the default node candidates' "$t/wp.log")
  tw wpctl set-default "$(nid blockie.volume-limit)"
  sleep 1
  d=$(tw wpctl inspect @DEFAULT_AUDIO_SINK@ 2> /dev/null | sed -n 's/.*node.name = "\(.*\)"/\1/p')
  n1=$(grep -c 'left out of the default node candidates' "$t/wp.log")
  tw wpctl set-default "$(nid test.card)"
  sleep 1
  [[ $d == test.card && $n1 -gt $n0 ]]
  res $? "2 the filter set as the configured default is left out by the hook and the card stand-in stays the default: '${d:-none}', the hook acted $((n1 - n0)) times"
  f=$(nid blockie.volume-limit)
  tw wpctl set-volume "$f" 0.5
  sleep 0.5
  a=$(cvol blockie.volume-limit)
  tw wpctl set-volume "$f" 1.5
  sleep 0.5
  b=$(cvol blockie.volume-limit)
  [[ $a == "1 1" && $b == "1 1" ]]
  res $? "2 the filter's own volume set to 0.5 and 1.5 reads 1.0 again: '$a', '$b'"
  dump
  echo "READ 2 the filter's Props objects, in order: $(jq -c '[.[] | select(.info.props["node.name"]? == "blockie.volume-limit")
    | .info.params.Props[] | keys][0]' "$t/dump.json")"
  echo "READ 2 the filter's latency: $(jq -c '[.[] | select(.info.props["node.name"]? == "blockie.volume-limit")
    | .info.params | {Latency, ProcessLatency}][0]' "$t/dump.json")"
fi

if want 3; then
  echo "READ 3 clock.max-quantum $(tw pw-metadata -n settings 0 clock.max-quantum | sed -n "s/.* value:'\([^']*\)'.*/\1/p"), clock.rate $(tw pw-metadata -n settings 0 clock.rate | sed -n "s/.* value:'\([^']*\)'.*/\1/p"), clock.force-rate $(tw pw-metadata -n settings 0 clock.force-rate | sed -n "s/.* value:'\([^']*\)'.*/\1/p")"
  play
  a=$(level blockie.volume-limit.output output)
  lim 0.6
  b=$(level blockie.volume-limit.output output)
  near "$(awk -v a="$a" -v b="$b" 'BEGIN { print a - b }')" 13.31 0.1
  res $? "3 limit 0.6 reads 13.3 dB lower within 0.1 dB: $a then $b dBFS, gain $(mult)"
  lim 0.3
  for to in 1.0 0.3; do
    read -r s e r j n <<< "$(change blockie.volume-limit.output output lim "$to")"
    want_d=$(awk -v to="$to" 'BEGIN { print (to == 1.0 ? 1 : -1) * 31.37 }')
    near "$(awk -v s="$s" -v e="$e" 'BEGIN { print e - s }')" "$want_d" 0.3 && [[ $n == 5 ]] &&
      awk -v j="$j" 'BEGIN { exit !(j <= 31.37 / 5 + 0.3) }'
    res $? "3 a change to $to moves in 5 steps none over a fifth: start $s, end $e, largest step $j dB, $n steps"
  done
  stop_play
  lim 1.0
  play
  a=$(level blockie.volume-limit.output output)
  stop_play
  lim 0.6
  play
  b=$(level blockie.volume-limit.output output)
  near "$(awk -v a="$a" -v b="$b" 'BEGIN { print a - b }')" 13.31 0.1
  res $? "3 a change with the filter idle holds once a stream starts: $a then $b dBFS"
  stop_play
  sleep 7
  susp=$(dump; jq -r '[.[] | select(.info.props["node.name"]? == "test.card") | .info.state][0]' "$t/dump.json")
  play
  c=$(level blockie.volume-limit.output output)
  near "$c" "$b" 0.1 && near "$(mult)" 0.216 0.001
  res $? "3 the stand-in $susp and resumed: the gain holds, $c dBFS, gain $(mult)"
  stop_play
  lim 1.0
fi

if want 4; then
  play 1.5 test.loud
  a=$(props test.loud | jq -c '{volume, channelVolumes}')
  stop_play
  tw wpctl set-default "$(nid test.headset)"
  sleep 1
  play 1.5 test.loud
  b=$(props test.loud | jq -c '{volume, channelVolumes}')
  stop_play
  tw wpctl set-default "$(nid test.card)"
  sleep 1
  [[ $(jq -r '[.volume, (.channelVolumes // [])[]] | all(. <= 1.0)' <<< "$a") == true &&
    $(jq -r '[.volume, (.channelVolumes // [])[]] | any(. > 1.0)' <<< "$b") == true ]]
  res $? "4 a --volume 1.5 stream reads 1.0 on the filter and keeps 1.5 on the headset: $a, $b"
fi

if want 5; then
  stop_wp
  stop_pw
  printf 'error ("blockie volume-limit test")\n' | cat - "$t/orig/${script##*/}" > "$script"
  start_pw && standins && start_wp
  tw wpctl settings --save blockie.volume-limit 1.00 > /dev/null
  play
  a=$(level blockie.volume-limit.output output)
  stop_play
  cp -p "$t/orig/${script##*/}" "$script"
  [[ $a == -200.00 || $(awk -v a="$a" 'BEGIN { print (a < -120) }') == 1 ]]
  res $? "5 a script with a Lua error leaves the filter silent: $a dBFS"
  stop_wp
  stop_pw
  printf 'context.modules = [ { name = libpipewire-module-filter-chain args = { filter.graph = { nodes = [\n  { type = builtin name = gain label = nosuch } ] } } } ]\n' \
    > "$pwconf"
  pipewire > "$t/pwbad.log" 2>&1 &
  bad=$!
  for _ in $(seq 50); do kill -0 "$bad" 2> /dev/null || break; sleep 0.1; done
  if kill -0 "$bad" 2> /dev/null; then
    kill "$bad"
    r=1
  else
    r=0
  fi
  wait "$bad" 2> /dev/null
  cp -p "$t/orig/${pwconf##*/}" "$pwconf"
  [[ $r == 0 ]]
  res $? "5 a broken PipeWire fragment stops PipeWire's start: $(tail -n 2 "$t/pwbad.log" | tr '\n' ' ')"
  start_pw && standins && start_wp
  lim 0.6
  flushed
  stop_wp
  a=$(mult)
  start_wp
  b=$(mult)
  near "$a" 0.216 0.001 && near "$b" 0.216 0.001 && near "$(applied)" 0.6 0.001
  res $? "5 a WirePlumber restart keeps the gain and applied reads it: $a, then $b, applied $(applied)"
  tw wpctl settings --delete blockie.volume-limit > /dev/null
  flushed
  stop_wp
  stop_pw
  start_pw && standins && start_wp
  play
  a=$(mult)
  sleep 11
  b=$(level blockie.volume-limit.output output)
  printf 'version 1\nsound.max_volume 50\n' > "$t/map"
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit
  r=$?
  c=$(level blockie.volume-limit.output output)
  stop_play
  near "$a" 0 0.000001 && awk -v b="$b" 'BEGIN { exit !(b < -120) }' && [[ $r == 0 ]] && near "$c" -78.06 0.2
  res $? "5 with nothing saved after a PipeWire start the filter stays silent past 10 s until blockie-volume limit: gain '$a', $b dBFS, rc $r, then $c dBFS"
  flushed
  stop_wp
  stop_pw
  start_pw && standins && start_wp
  play
  a=$(mult)
  sleep 11
  b=$(mult)
  c=$(level blockie.volume-limit.output output)
  stop_play
  near "$a" 0 0.000001 && near "$b" 0.125 0.001 && near "$(applied)" 0.5 0.001 && near "$c" -78.06 0.2
  res $? "5 with no push within 10 s after a PipeWire start the filter opens at the saved limit: gain '$a', then $b, applied $(applied), $c dBFS"
  stop_wp
  stop_pw
  start_pw && standins
  play
  rec_open "$t/nonce.wav"
  rec_link blockie.volume-limit.output output > /dev/null 2>&1 &
  lk=$!
  start_wp
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit
  r=$?
  sleep 1
  wait "$lk" 2> /dev/null
  rec_stop
  stop_play
  read -r top end <<< "$(python3 "$t/lv.py" span "$t/nonce.wav")"
  [[ $r == 0 ]] && awk -v t="$top" 'BEGIN { exit !(t <= -78.06 + 0.2) }' && near "$end" -78.06 0.2
  res $? "5 a push of the unchanged saved value opens a cold filter through the push nonce, recorded from WirePlumber's start: rc $r, highest peak $top dBFS, end $end dBFS"
  tw wpctl settings --save blockie.volume-limit 0.30 > /dev/null
  stop_wp
  stop_pw
  printf 'version 1\nsound.max_volume 30\n' > "$t/map"
  start_pw && standins
  play
  rec_open "$t/lost.wav"
  rec_link blockie.volume-limit.output output > /dev/null 2>&1 &
  lk=$!
  start_wp
  echo "READ 5 after a stop right after --save 0.30: $(tw wpctl settings blockie.volume-limit)"
  tw wpctl set-volume "$(nid test.card)" 0.4
  sleep 0.3
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit
  r=$?
  sleep 1
  wait "$lk" 2> /dev/null
  rec_stop
  n=$(number test.card)
  stop_play
  read -r top end <<< "$(python3 "$t/lv.py" span "$t/lost.wav")"
  [[ $r == 0 && $n == 67 ]] && awk -v t="$top" 'BEGIN { exit !(t <= -91.37 + 0.2) }' && near "$end" -91.37 0.2
  res $? "5 a lowering lost by a stop opens cold at the push, its number first from the saved limit, never above the newer limit, recorded from WirePlumber's start: rc $r, number $n, highest peak $top dBFS, end $end dBFS"
  printf 'version 1\nsound.max_volume 50\n' > "$t/map"
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit > /dev/null 2>&1
  flushed
  stop_wp
  stop_pw
  start_pw && standins
  play
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit > /dev/null 2>&1 &
  bv=$!
  start_wp
  wait "$bv"
  r=$?
  sleep 0.5
  a=$(level blockie.volume-limit.output output)
  stop_play
  [[ $r == 0 ]] && near "$a" -78.06 0.2
  res $? "5 blockie-volume limit started together with WirePlumber waits for the script and opens it: rc $r, $a dBFS"
  lim 1.0
  flushed
fi

if want 6; then
  card=test.card
  play
  lim 1.0
  tw wpctl set-volume "$(nid $card)" 1.0
  read -r s e r j n <<< "$(change $card monitor lim 0.3)"
  a=$(number $card)
  near "$(awk -v s="$s" -v e="$e" 'BEGIN { print e - s }')" -31.37 0.5 && [[ $a == 100 ]] &&
    awk -v r="$r" 'BEGIN { exit !(r <= 0.2) }'
  res $? "6 number 100 from 1.0 to 0.3: the number reads $a, $s to $e dBFS, highest peak $r dB over the start"
  near "$(applied)" 0.3 0.001
  res $? "6 applied reads 0.3 after the change: $(applied)"
  read -r s e r j n <<< "$(change $card monitor lim 1.0)"
  a=$(number $card)
  near "$e" "$s" 0.5 && [[ $a == 30 ]] && awk -v r="$r" 'BEGIN { exit !(r <= 0.2) }'
  res $? "6 back to 1.0: the number reads $a, $s to $e dBFS, highest peak $r dB over the start"
  tw wpctl set-volume "$(nid $card)" 0.2
  sleep 0.3
  read -r s e r j n <<< "$(change $card monitor lim 0.3)"
  a=$(number $card)
  near "$e" "$s" 0.5 && [[ $a == 67 ]]
  res $? "6 number 20 from 1.0 to 0.3: the number reads $a, $s to $e dBFS"
  lim 1.0
  tw wpctl set-volume "$(nid $card)" 0.2
  sleep 0.3
  printf 'version 1\nsound.max_volume 30\n' > "$t/map"
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 30 "$vol" limit
  r=$?
  a=$(applied)
  b=$(number $card)
  printf 'version 1\nsound.max_volume 40\n' > "$t/map"
  tw wpctl settings --save blockie.volume-limit 0.4 > /dev/null
  BLOCKIE_VOLUME_SETTINGS=$t/map timeout 10 "$vol" limit wait
  c=$(applied)
  [[ $r == 0 && $b == 67 ]] && near "$a" 0.3 0.001 && near "$c" 0.4 0.001
  res $? "6 blockie-volume limit and limit wait return after applied, the number already moved: $a with number $b, then $c"
  lim 1.0
  tw wpctl set-volume "$(nid $card)" 0.5
  sleep 0.3
  tw wpctl settings --save blockie.volume-limit 0.3 > /dev/null
  sleep 0.02
  tw wpctl set-volume "$(nid $card)" 0.4
  settle 0.3
  a=$(number $card)
  [[ $a == 40 ]]
  res $? "6 a wpctl set-volume landing between the two writes stays: $a"
  lim 0.3
  tw wpctl set-volume "$(nid $card)" 1.0
  sleep 0.3
  tw wpctl settings --save blockie.volume-limit 1.0 > /dev/null
  tw wpctl settings --save blockie.volume-limit 1.0 > /dev/null
  settle 1.0
  a=$(number $card)
  tw wpctl settings --save blockie.volume-limit 0.3 > /dev/null
  tw wpctl settings --save blockie.volume-limit 0.3 > /dev/null
  settle 0.3
  b=$(number $card)
  [[ $a == 30 && $b == 100 ]]
  res $? "6 two pushes of one value during a raise and a lowering: the number reads $a, then $b"
  timeout 4 pw-metadata -m -n blockie-volume-limit 0 applied > "$t/mon" 2>&1 &
  mon_pid=$!
  sleep 0.3
  tw wpctl settings --save blockie.volume-limit 1.0 > /dev/null
  sleep 0.05
  tw wpctl settings --save blockie.volume-limit 0.3 > /dev/null
  sleep 1.5
  settle 0.3
  a=$(number $card)
  wait "$mon_pid" 2> /dev/null
  mon_pid=
  seen=$(sed -n "s/.* value:'\([^']*\)'.*/\1/p" "$t/mon" | tail -n +2 | paste -sd ,)
  near "$(mult)" 0.027 0.0005 && [[ $a == 100 && $seen == 1.00,0.30 ]]
  res $? "6 a lowering inside a raise runs after it and ends at the lower gain and its number: gain $(mult), number $a, applied went $seen"
  lim 1.0
  tw wpctl set-volume "$(nid test.headset)" 0.5
  tw wpctl set-volume "$(nid $card)" 0.5
  sleep 0.3
  tw wpctl settings --save blockie.volume-limit 0.3 > /dev/null
  tw wpctl set-default "$(nid test.headset)"
  settle 0.3
  a=$(number test.headset)
  b=$(number $card)
  tw wpctl set-default "$(nid $card)"
  [[ $a == 50 ]]
  res $? "6 a headset stand-in made default mid sequence takes no write: headset $a, card $b"
  stop_play
  lim 1.0
fi

if want 7; then
  play
  lim 1.0
  tw wpctl settings --save blockie.volume-limit 0.30 > /dev/null
  tw pw-metadata -n blockie-volume-limit 0 push "$(date +%s%N)" > /dev/null 2>&1
  n0=$(wc -l < "$t/wp.log")
  sleep 6.5
  m=$(mult)
  ap=$(applied)
  echo "LOG 7 the script: $(scriptlog "$n0")" >&2
  stop_play
  near "$m" 0.027 0.0005 && near "$ap" 0.3 0.001
  res $? "7 a lowering to 0.30 ends at its gain within the 5 s deadline, a stuck one written down: gain $m, applied '$ap'"
  lim 1.0
fi

if (( fails )); then
  echo "volume-limit-wp: $fails failed"
  exit 1
fi
echo "volume-limit-wp: ok"
