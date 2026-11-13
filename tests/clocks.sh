#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
bin=${CLOCKS_BIN:-/usr/libexec/blockie/blockie-clocks}
[[ -x $bin ]] || bin=$here/../system_files/usr/libexec/blockie/blockie-clocks
lib=/usr/lib/blockie
[[ -f $lib/clocks.conf ]] || lib=$here/../system_files/usr/lib/blockie
lib=$(readlink -f "$lib")
t=$(mktemp -d "${TMPDIR:-/tmp}/clocks.XXXXXX")
fails=0
holder=
w=
rflock=$(command -v flock)
rsleep=$(command -v sleep)
rchmod=$(command -v chmod)
av0="500000 774000 850000 900000 950000 999000 1050000 1100000 1175000 1275000 1325000 1375000 1450000 1500000 1625000 1800000 "
av6="850000 909000 998000 1087000 1176000 1295000 1354000 1443000 1532000 1621000 1710000 1800000 1850000 1900000 1950000 2000000 "

cleanup() {
  [[ -z $holder ]] || kill "$holder" 2> /dev/null
  wait 2> /dev/null
  rm -rf "${t:?}"
}
trap cleanup EXIT

res() {
  if [[ $1 == 0 ]]; then
    echo "ok   $2"
  else
    echo "FAIL $2"
    fails=$((fails + 1))
    [[ -z $w || ! -f $w/out ]] || tail -n 20 "$w/out" | sed 's/^/  | /'
  fi
}

cp "$bin" "$t/blockie-clocks"
chmod 755 "$t/blockie-clocks"
printf 'g 2 900000 1000\ng 3 875000 990\nd 0 1 2\nd 1 3 4\n' > "$t/gd"

fakes() {
  cat > "$w/kernel" << EOF
#!/usr/bin/env bash
w="$w"
r="$r"
lib="$lib"
th="$th"
z="$th/thermal_zone5"

link() {
  ln -s "../cooling_device\$2" "\$z/cdev\$1"
  echo "\$3" > "\$z/cdev\$1_trip_point"
  echo 0 > "\$z/cdev\$1_weight"
}

links() {
  case \$1 in
    observed | passive) link 0 0 0; link 1 1 2; link 2 2 1; link 3 3 3 ;;
    shuffled) link 0 3 3; link 1 0 0; link 2 1 2; link 3 2 1 ;;
    missing) link 0 0 0; link 1 1 2; link 3 3 3 ;;
    wrongtp) link 0 0 0; link 1 1 1; link 2 2 2; link 3 3 3 ;;
    extra) link 0 0 0; link 1 1 2; link 2 2 1; link 3 3 3; link 4 4 3 ;;
  esac
}

mkzone() {
  local i
  local -a tp=(117000 95000 85000 "\$1")
  rm -rf "\${z:?}"
  mkdir -p "\$z"
  echo mtktscpu > "\$z/type"
  cat "\$w/temp" > "\$z/temp"
  for i in 0 1 2 3; do
    echo "\${tp[i]}" > "\$z/trip_point_\${i}_temp"
    echo active > "\$z/trip_point_\${i}_type"
  done
  [[ \$2 != passive ]] || echo passive > "\$z/trip_point_3_type"
  links "\$2"
}

put() {
  printf '%s' "\$2" > "\$1"
}

zone0() {
  mkdir -p "\$th/thermal_zone0"
  echo mtktsAP > "\$th/thermal_zone0/type"
  echo 45000 > "\$th/thermal_zone0/temp"
}

lineid() {
  local x
  for x in 65000 72000 80000; do
    if [[ \$1 == "\$(cat "\$lib/clocks/trip-\$x.line")" ]]; then
      echo "\$x"
      return
    fi
  done
  echo bad
}

write() {
  local n k plan
  n=\$((\$(cat "\$w/ntz" 2> /dev/null || echo 0) + 1))
  echo "\$n" > "\$w/ntz"
  k=\$(cat "\$w/ticks" 2> /dev/null || echo 0)
  plan=\$(cat "\$w/zone.\$n" 2> /dev/null)
  if [[ \$plan == form ]]; then
    { sed 's/^trip_9=.*/trip_9=40000 0 x/' "\$lib/clocks/tzcpu-\$1.read"; cat "$t/gd"; } > "\$r/proc/driver/thermal/tzcpu"
  else
    cat "\$lib/clocks/tzcpu-\$1.read" "$t/gd" > "\$r/proc/driver/thermal/tzcpu"
  fi
  rm -rf "\${z:?}"
  case \$plan in
    '' | form) mkzone "\$1" observed ;;
    never) ;;
    lose0)
      rm -rf "\${th:?}/thermal_zone0"
      mkzone "\$1" observed
      ;;
    back0)
      zone0
      mkzone "\$1" observed
      ;;
    retype0)
      echo mtktsAP2 > "\$th/thermal_zone0/type"
      mkzone "\$1" observed
      ;;
    trip4)
      mkzone "\$1" observed
      echo 63000 > "\$z/trip_point_4_temp"
      ;;
    delay\ *) echo "\$((k + \${plan#delay })) mkzone \$1 observed" >> "\$w/sched" ;;
    links\ *)
      mkzone "\$1" none
      echo "\$((k + \${plan#links })) links observed" >> "\$w/sched"
      ;;
    *) mkzone "\$1" "\$plan" ;;
  esac
}

"\$@"
EOF
  cat > "$w/bin/dd" << EOF
#!/usr/bin/env bash
w="$w"
r="$r"
of=
in=
for a in "\$@"; do
  case \$a in
    of=*) of=\${a#of=} ;;
    if=*) in=\${a#if=} ;;
  esac
done
if [[ -n \$in ]]; then
  data=\$(cat "\$in"; printf x)
else
  data=\$(cat; printf x)
fi
data=\${data%x}
n=\$((\$(cat "\$w/nw" 2> /dev/null || echo 0) + 1))
echo "\$n" > "\$w/nw"
case \$of in
  */policy0/scaling_max_freq) k=policy0 ;;
  */policy6/scaling_max_freq) k=policy6 ;;
  */custom_upbound_gpu_freq) k=upbound ;;
  */tzcpu) k=tzcpu ;;
  *) k=\${of#"\$r"} ;;
esac
v=\$data
[[ \$k != tzcpu ]] || v=\$("\$w/kernel" lineid "\$data")
echo "\$k=\$v" >> "\$w/writes"
echo "dd \$k=\$v failed=\$([[ -e \$r/run/blockie-clocks/failed ]] && echo yes || echo no) writing=\$([[ -e \$r/run/blockie-clocks/writing ]] && echo yes || echo no)" >> "\$w/calls"
[[ ! -x \$w/hook.\$n ]] || "\$w/hook.\$n"
fail=\$(cat "\$w/fail.\$n" 2> /dev/null)
if [[ ! -e \$of ]]; then
  echo "dd: failed to open '\$of': No such file or directory" >&2
  exit 1
fi
if [[ \$fail == einval || ( \$k == tzcpu && ( \$v == bad || -e \$w/refuse ) ) ]]; then
  echo "dd: error writing '\$of': Invalid argument" >&2
  echo "0+0 records out" >&2
  echo "0 bytes copied, 0 s, 0 B/s" >&2
  exit 1
fi
[[ \$fail != short ]] || data=\${data:0:\$((\${#data} - 1))}
if [[ \$k == tzcpu ]]; then
  "\$w/kernel" write "\$v"
elif [[ -e \$w/under.\$k ]]; then
  printf '%s' "\$((data - 1000))" > "\$of"
elif [[ -e \$w/late.\$k ]]; then
  echo "\$((\$(cat "\$w/ticks" 2> /dev/null || echo 0) + 1)) put \$of \$data" >> "\$w/sched"
elif [[ -e \$w/stuck.\$k ]]; then
  :
else
  printf '%s' "\$data" > "\$of"
fi
echo "0+1 records in" >&2
echo "0+1 records out" >&2
echo "\${#data} bytes copied, 0 s, 0 B/s" >&2
EOF
  cat > "$w/bin/sleep" << EOF
#!/usr/bin/env bash
w="$w"
k=\$((\$(cat "\$w/ticks" 2> /dev/null || echo 0) + 1))
echo "\$k" > "\$w/ticks"
echo "sleep \$*" >> "\$w/calls"
if [[ -f \$w/sched ]]; then
  while read -r at act; do
    [[ \$at != "\$k" ]] || "\$w/kernel" \$act
  done < "\$w/sched"
fi
EOF
  cat > "$w/bin/flock" << EOF
#!/usr/bin/env bash
w="$w"
echo "flock \$*" >> "\$w/calls"
[[ ! -x \$w/onlock ]] || "\$w/onlock"
a=()
while (( \$# )); do
  if [[ \$1 == -w ]]; then
    a+=(-w 0.2)
    shift 2
  else
    a+=("\$1")
    shift
  fi
done
exec "$rflock" "\${a[@]}"
EOF
  cat > "$w/bin/systemctl" << EOF
#!/usr/bin/env bash
r="$r"
echo "systemctl \$* failed=\$([[ -e \$r/run/blockie-clocks/failed ]] && echo yes || echo no) writing=\$([[ -e \$r/run/blockie-clocks/writing ]] && echo yes || echo no)" >> "$w/calls"
EOF
  cat > "$w/bin/chmod" << EOF
#!/usr/bin/env bash
r="$r"
echo "chmod \$* writing=\$([[ -e \$r/run/blockie-clocks/writing ]] && echo yes || echo no)" >> "$w/calls"
exec "$rchmod" "\$@"
EOF
  chmod 755 "$w/kernel" "$w/bin/dd" "$w/bin/sleep" "$w/bin/flock" "$w/bin/systemctl" "$w/bin/chmod"
}

morder() {
  printf 'blockie-modorder 1 second %s %s 3\nmtk_wdt.ko nowayout=1\nthermal_monitor.ko\nged.ko\n' "$1" \
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$r/blockie/lib/modules.second"
}

wmap() {
  printf 'version 1\nbuttons.home.hold switcher\npower.clocks %s\n' "$1" > "$r/run/blockie-set/settings"
}

world() {
  local i=0 c
  w=$t/$1
  r=$w/root
  cf=$r/sys/devices/system/cpu/cpufreq
  th=$r/sys/class/thermal
  rb=$r/run/blockie-clocks
  mkdir -p "$w/bin" "$r/run/blockie-set" "$r/proc/driver/thermal" "$r/sys/kernel/ged/hal" "$r/blockie/lib" \
    "$cf/policy0" "$cf/policy6" "$th/thermal_zone0" "$r/usr/lib/blockie"
  echo 1800000 > "$cf/policy0/cpuinfo_max_freq"
  echo "$av0" > "$cf/policy0/scaling_available_frequencies"
  echo 1800000 > "$cf/policy0/scaling_max_freq"
  echo 2000000 > "$cf/policy6/cpuinfo_max_freq"
  echo "$av6" > "$cf/policy6/scaling_available_frequencies"
  echo 2000000 > "$cf/policy6/scaling_max_freq"
  echo 0 > "$r/sys/kernel/ged/hal/custom_upbound_gpu_freq"
  morder v01
  cp "$lib/clocks.conf" "$r/usr/lib/blockie/clocks.conf"
  ln -s "$lib/clocks" "$r/usr/lib/blockie/clocks"
  echo mtktsAP > "$th/thermal_zone0/type"
  echo 45000 > "$th/thermal_zone0/temp"
  for c in mtktscpu-sysrst cpu03 cpu00 cpu_adaptive_0 cpu_adaptive_1 mtktsAP-sysrst; do
    mkdir -p "$th/cooling_device$i"
    echo "$c" > "$th/cooling_device$i/type"
    echo 0 > "$th/cooling_device$i/cur_state"
    i=$((i + 1))
  done
  echo 50000 > "$w/temp"
  cat "$lib/clocks/tzcpu-boot.read" "$t/gd" > "$r/proc/driver/thermal/tzcpu"
  wmap "${2:-trip72-big1443}"
  fakes
  "$w/kernel" mkzone 65000 observed
}

run() {
  rm -f "${w:?}/writes" "${w:?}/calls" "${w:?}/nw" "${w:?}/ntz" "${w:?}/ticks" "${w:?}/sched"
  : > "$w/writes"
  : > "$w/calls"
  PATH="$w/bin:$PATH" BLOCKIE_CLOCKS_ROOT=$r timeout -k 2 "${TO:-60}" "$t/blockie-clocks" "$@" < /dev/null > "$w/out" 2>&1
  rc=$?
  rm -f "${w:?}"/fail.* "${w:?}"/hook.* "${w:?}"/zone.* "${w:?}"/under.* "${w:?}"/late.* "${w:?}"/stuck.* "${w:?}/refuse" \
    "${w:?}/onlock"
}

reach() {
  world "$1" "$2"
  run apply
  [[ $rc == 0 && $(st) == "applied $2|caps $2" ]] || echo "  the setup of $1 at $2: rc $rc, state $(st)"
}

wl() {
  paste -sd' ' "$w/writes"
}

st() {
  paste -sd'|' "$rb/state" 2> /dev/null
}

kn() {
  echo "$(cat "$cf/policy0/scaling_max_freq") $(cat "$cf/policy6/scaling_max_freq") $(cat "$r/sys/kernel/ged/hal/custom_upbound_gpu_freq")"
}

locks() {
  grep -c '^flock' "$w/calls"
}

sleeps() {
  grep -c '^sleep' "$w/calls"
}

form() {
  head -n 12 "$r/proc/driver/thermal/tzcpu" | cmp -s - "$lib/clocks/tzcpu-$1.read"
}

cur() {
  echo "$1" > "$th/cooling_device3/cur_state"
}

temp() {
  echo "$1" > "$w/temp"
  echo "$1" > "$th/thermal_zone5/temp"
}

unknown() {
  sed -i 's/^trip_9=40000 0 $/trip_9=40000 0 x/' "$r/proc/driver/thermal/tzcpu"
}

hold() {
  ( exec 8>> "$r/run/blockie-perf.lock"; "$rflock" 8; : > "$w/held"; exec "$rsleep" 60 ) &
  holder=$!
  while [[ ! -e $w/held ]]; do "$rsleep" 0.05; done
}

unhold() {
  kill "$holder" 2> /dev/null
  wait "$holder" 2> /dev/null
  holder=
}

savez() {
  local d
  mkdir -p "$rb"
  for d in "$th"/thermal_zone*; do
    cat "$d/type"
  done | LC_ALL=C sort > "$rb/zones"
}

script() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$w/$1"
  chmod 755 "$w/$1"
}

world a-order
run apply
[[ $rc == 0 && $(wl) == "policy6=1443000 tzcpu=72000" && $(st) == "applied trip72-big1443|caps trip72-big1443" &&
  $(kn) == "1800000 1443000 0" && ! -e $rb/writing && $(stat -c %a "$rb") == 755 && $(stat -c %a "$rb/state") == 644 &&
  $(cat "$th/thermal_zone5/trip_point_3_temp") == 72000 && $(locks) == 1 ]] && form 72000 &&
  grep -qx 'blockie-clocks: applied trip72-big1443 p0max=1800000 p6max=1443000 upbound=0 trip3=72000' "$w/out" &&
  grep -qx 'dd tzcpu=72000 failed=no writing=yes' "$w/calls"
res $? "apply: B1 at boot: policy6 1443000, then the 72000 line under the marker, applied, the journal line"
[[ $(grep -A 1 '^dd tzcpu=72000' "$w/calls" | tail -n 1) == "sleep 1" && $(sleeps) == 1 ]] &&
  grep -qx 'blockie-clocks: trip 72000 accepted on try 1' "$w/out"
res $? "apply: the first acceptance try comes 1 s after the write(2)"
run status
[[ $rc == 0 && $(cat "$w/out") == $'applied trip72-big1443\ncaps trip72-big1443' ]]
res $? "status prints the state file"

world a-einval1
echo einval > "$w/fail.1"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 policy6=2000000" && $(kn) == "1800000 2000000 0" && $(st) == "pending trip72-big1443" ]]
res $? "apply: EINVAL at write 1: the node put back, no trip, exit 2"

world a-einval2
printf '\n[both]\ntrip=72000\npolicy6=1443000\npolicy0=1500000\n' >> "$r/usr/lib/blockie/clocks.conf"
wmap both
echo einval > "$w/fail.2"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 policy0=1500000 policy0=1800000 policy6=2000000" && $(kn) == "1800000 2000000 0" &&
  $(st) == "pending both" ]] && grep -q 'policy0 1500000: write failed (rc 1 bytes 0 of 7: dd: error writing' "$w/out"
res $? "apply: EINVAL at write 2: the caps written put back in reverse order, no trip, exit 2"

world a-short
echo short > "$w/fail.1"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 policy6=2000000" && $(kn) == "1800000 2000000 0" ]] &&
  grep -q 'policy6 1443000: write failed (rc 0 bytes 6 of 7)' "$w/out"
res $? "apply: a short write fails the write: the node put back, exit 2"

world a-under
: > "$w/under.policy6"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" && $(kn) == "1800000 1442000 0" ]] &&
  grep -qx 'blockie-clocks: policy6 1443000 written, reads 1442000' "$w/out"
res $? "apply: a read below the write passes"

world a-node
rm -f "${cf:?}/policy6/scaling_max_freq"
run apply
[[ $rc == 2 && -z $(wl) && $(sleeps) == 10 && ! -e $rb/state ]] &&
  grep -q 'policy6/scaling_max_freq missing after 10 s, nothing written' "$w/out"
res $? "apply: a cap node missing for 10 s: nothing written, exit 2"

world a-notz
rm -f "${r:?}/proc/driver/thermal/tzcpu"
run apply
[[ $rc == 2 && $(wl) == policy6=1443000 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] &&
  grep -q 'trip unknown: no .*tzcpu' "$w/out"
res $? "apply: tzcpu missing: the lowering cap, no trip, exit 2"

world a-lock
hold
run apply
unhold
[[ $rc == 2 && -z $(wl) && ! -e $rb/state ]] && grep -q 'blockie-perf.lock is held, nothing written' "$w/out"
res $? "apply: the perf lock held: nothing written, exit 2"

world a-dir
sed -i 's/^policy6=1443000$/policy6=2100000/' "$r/usr/lib/blockie/clocks.conf"
run apply
[[ $rc == 2 && -d $rb && -z $(wl) && ! -e $rb/state ]]
res $? "apply: /run/blockie-clocks is made before the conf check"

world a-mod-v02
morder v02
run apply
[[ $rc == 0 && $(wl) == "policy6=1443000 tzcpu=72000" && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "apply: module order: a good header for set v02 proves F"

modmiss() {
  world "a-mod-$1"
  case $1 in
    v03) morder v03 ;;
    first) sed -i '1s/ second / first /' "$r/blockie/lib/modules.second" ;;
    magic) sed -i '1s/^blockie-modorder /blockie-modlist /' "$r/blockie/lib/modules.second" ;;
    version) sed -i '1s/^blockie-modorder 1 /blockie-modorder 2 /' "$r/blockie/lib/modules.second" ;;
    noline) sed -i '/^thermal_monitor\.ko$/d' "$r/blockie/lib/modules.second" ;;
    absent) rm -f "${r:?}/blockie/lib/modules.second" ;;
  esac
  run apply
  [[ $rc == 2 && $(wl) == policy6=1443000 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] && form boot &&
    grep -q "trip 72000 waits: module order: $2" "$w/out"
  res $? "apply: module order $3: no trip write, no raise, the lowering cap only, exit 2"
}
modmiss v03 "set 'v03'" "with set v03"
modmiss first "stage 'first'" "with stage first"
modmiss magic "magic 'blockie-modlist'" "with another magic"
modmiss version "version '2'" "with version 2"
modmiss noline "no thermal_monitor.ko line" "naming no thermal_monitor.ko"
modmiss absent "no .*modules.second" "absent (an old ramdisk)"

world a-mod-raise trip65
echo 1443000 > "$cf/policy6/scaling_max_freq"
morder v03
run apply
[[ $rc == 2 && -z $(wl) && $(st) == "pending trip65" && $(kn) == "1800000 1443000 0" ]]
res $? "apply: module order with set v03: no raise"

world a-read
unknown
run apply
[[ $rc == 2 && $(wl) == policy6=1443000 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] &&
  grep -q 'trip unknown: tzcpu matches no pinned read' "$w/out"
res $? "apply: a read matching no pinned form: the lowering cap only, no trip, exit 2"

world a-read-raise trip65
echo 1443000 > "$cf/policy6/scaling_max_freq"
unknown
run apply
[[ $rc == 2 && -z $(wl) && $(st) == "pending trip65" && $(kn) == "1800000 1443000 0" ]]
res $? "apply: a read matching no pinned form: no raise"

world a-gd
{ cat "$lib/clocks/tzcpu-boot.read"; printf 'g 2 1 1\nd 9 9 9\nd 8 8\n'; } > "$r/proc/driver/thermal/tzcpu"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "apply: g and d rows differing from the record: no miss"

world a-hot
cur 1
run apply
[[ $rc == 2 && $(sleeps) == 0 && $(wl) == "policy6=1443000 policy0=1800000 upbound=0" &&
  $(st) == "deferred trip72-big1443|caps trip72-big1443" ]] && form boot
res $? "apply: a hot boot (a cur_state at 1): the caps at once, no wait, no trip, deferred, exit 2"

world a-vanish
echo never > "$w/zone.1"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" && ! -e $rb/writing && ! -e $rb/failed &&
  $(st) == "pending trip72-big1443|caps trip72-big1443" && $(sleeps) == 8 &&
  $(sed -n '/^dd tzcpu=72000/,/^dd tzcpu=65000/p' "$w/calls" | grep -c '^sleep 1$') == 7 ]] && form 65000 &&
  grep -q 'trip 72000 not accepted after 7 tries' "$w/out" && grep -qx 'blockie-clocks: trip 65000 accepted on try 1' "$w/out"
res $? "apply: the zone absent for all 7 tries 1 s apart: the 65000 line again, accepted, exit 2"

world a-vanish2
echo never > "$w/zone.1"
echo never > "$w/zone.2"
run apply
[[ $rc == 1 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000 policy0=500000 policy6=850000" && $(kn) == "500000 850000 0" &&
  -e $rb/failed && $(stat -c %a "$rb/failed") == 644 && ! -e $rb/writing && $(st) == "failed|caps trip72-big1443" ]] &&
  grep -qx 'dd policy0=500000 failed=no writing=yes' "$w/calls" && grep -qx 'dd policy6=850000 failed=no writing=yes' "$w/calls" &&
  grep -qx "chmod 0644 $rb/failed writing=yes" "$w/calls" &&
  grep -qx 'systemctl --no-block stop blockie-clocks-change.timer blockie-clocks.path failed=yes writing=no' "$w/calls"
r1=$?
run change
[[ $r1 == 0 && $rc == 1 && -z $(wl) && $(kn) == "500000 850000 0" ]]
res $? "apply: the rewrite failing too: the lowest steps under the marker, then failed, then the marker gone, the timer and path stopped, exit 1; nothing after"

world a-try3
echo "delay 3" > "$w/zone.1"
run apply
[[ $rc == 0 && $(wl) == "policy6=1443000 tzcpu=72000" && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] &&
  grep -qx 'blockie-clocks: trip 72000 accepted on try 3' "$w/out"
res $? "apply: the zone back on the third of 7 tries: accepted there"

world a-links2
echo "links 2" > "$w/zone.1"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] &&
  grep -qx 'blockie-clocks: trip 72000 accepted on try 2' "$w/out"
res $? "apply: the zone back with no links on the first try and its links on the second: accepted on try 2"

world a-shuffled
echo shuffled > "$w/zone.1"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "acceptance: the four links in another K order pass"

for v in missing wrongtp extra passive; do
  world "a-$v"
  echo "$v" > "$w/zone.1"
  run apply
  [[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] &&
    form 65000 && grep -q 'trip 72000 not accepted after 7 tries' "$w/out"
  res $? "acceptance: $v fails all 7 tries, the 65000 line again"
done

world a-mark
cat "$lib/clocks/tzcpu-72000.read" "$t/gd" > "$r/proc/driver/thermal/tzcpu"
"$w/kernel" mkzone 72000 observed
savez
printf '72000 65000\n' > "$rb/writing"
run apply
fl=$(grep -m 1 -n '^flock' "$w/calls" | cut -d: -f1)
sl=$(grep -m 1 -n '^sleep 1$' "$w/calls" | cut -d: -f1)
dl=$(grep -m 1 -n '^dd ' "$w/calls" | cut -d: -f1)
[[ $rc == 0 && $(wl) == policy6=1443000 && ! -e $rb/writing && $(st) == "applied trip72-big1443|caps trip72-big1443" &&
  -n $fl && -n $sl && -n $dl ]] && (( fl < sl && sl < dl )) &&
  grep -q "found .*writing reading '72000 65000'" "$w/out" && grep -qx 'blockie-clocks: trip 72000 accepted on try 1' "$w/out"
res $? "apply: a writing marker found by apply is acted on under its lock before the sequence"

world a-lost
echo lose0 > "$w/zone.1"
echo back0 > "$w/zone.2"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" && $(st) == "pending trip72-big1443|caps trip72-big1443" &&
  -f $rb/zones ]] && form 65000 &&
  grep -q 'trip 72000 not accepted after 7 tries: the zone types differ from before the write' "$w/out"
res $? "acceptance: a zone lost after the write fails all 7 tries (the zone types saved before the write), the 65000 line again"

world a-form
echo form > "$w/zone.1"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" ]] &&
  grep -q 'trip 72000 not accepted after 7 tries: tzcpu does not read the 72000 form' "$w/out"
res $? "acceptance: tzcpu reading no pinned form after the write fails all 7 tries, the 65000 line again"

world a-retype
echo retype0 > "$w/zone.1"
echo back0 > "$w/zone.2"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" && $(cat "$th/thermal_zone0/type") == mtktsAP ]] && form 65000 &&
  grep -q 'trip 72000 not accepted after 7 tries: the zone types differ from before the write' "$w/out"
res $? "acceptance: a zone type changed after the write fails all 7 tries, the 65000 line again"

world a-trip4
echo trip4 > "$w/zone.1"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" ]] &&
  grep -q 'trip 72000 not accepted after 7 tries: a trip_point_4 on the zone' "$w/out"
res $? "acceptance: a trip_point_4 after the write fails all 7 tries, the 65000 line again"

world a-two
cp -a "$th/thermal_zone5" "$th/thermal_zone6"
run apply
[[ $rc == 2 && $(wl) == policy6=1443000 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] &&
  grep -q 'trip 72000 waits: 2 mtktscpu zones' "$w/out"
res $? "apply: two mtktscpu zones leave F unproven: no trip write"

world a-refuse
: > "$w/refuse"
run apply
[[ $rc == 2 && $(wl) == "policy6=1443000 tzcpu=72000 tzcpu=65000" && $(sleeps) == 1 && $(cat "$rb/refused") == trip72-big1443 ]] &&
  form boot && grep -q 'trip 72000 write refused' "$w/out" && grep -qx 'blockie-clocks: trip 65000 accepted on try 1' "$w/out"
res $? "apply: a refused write of W's line goes to F's line with no 7 try wait; the zone kept, F's acceptance passes, exit 2"

ok=0
world a-refused
echo never > "$w/zone.1"
run apply
[[ $rc == 2 && $(cat "$rb/refused" 2> /dev/null) == trip72-big1443 ]] || ok=1
for i in 1 2; do
  run change
  [[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] || ok=1
done
echo 2000000 > "$cf/policy6/scaling_max_freq"
run change
[[ $rc == 2 && $(wl) == policy6=1443000 && $(locks) == 1 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]] &&
  form 65000 || ok=1
wmap trip72
run change
[[ $rc == 0 && $(wl) == "policy6=2000000 tzcpu=72000" && $(st) == "applied trip72|caps trip72" && ! -e $rb/refused ]] &&
  form 72000 || ok=1
res $ok "refused: a W line failing its acceptance is not written again while power.clocks keeps its id, its caps still applied; a new id tries it again"

world a-late
: > "$w/late.policy6"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" && $(kn) == "1800000 1443000 0" ]] &&
  grep -qx 'blockie-clocks: policy6 1443000 written, reads 1443000 after 100 ms' "$w/out"
res $? "apply: a cap whose read shows the old max right after the write and the new one 0.1 s later passes"

world a-above
printf '\n[both]\ntrip=72000\npolicy6=1443000\npolicy0=1500000\n' >> "$r/usr/lib/blockie/clocks.conf"
wmap both
echo 1621000 > "$cf/policy6/scaling_max_freq"
: > "$w/stuck.policy0"
run apply
[[ $rc == 2 && $(st) == "pending both" && $(grep -c '^sleep 0.1$' "$w/calls") == 10 &&
  $(wl) == "policy6=1443000 policy0=1500000 policy0=1800000 policy6=2000000" && $(kn) == "1800000 2000000 0" ]] &&
  grep -q 'policy0 1500000 written, reads 1800000 after 1 s' "$w/out"
res $? "apply: a cap still reading over its write after 1 s fails the write, every attempted cap put back at cpuinfo_max_freq, not the throttled read"

ok=0
world a-kit
script onlock ": > '$r/run/blockie-thermal-failed'"
run apply
[[ $rc == 1 && -z $(wl) && $(locks) == 1 ]] && grep -q 'a failure file appeared while the pass waited' "$w/out" || ok=1
rm -f "${r:?}/run/blockie-thermal-failed"
reach a-kit2 trip65
wmap trip72-big1443
script onlock ": > '$r/run/blockie-thermal-failed'"
run change
[[ $rc == 1 && -z $(wl) && $(locks) == 1 ]] && grep -q 'a failure file appeared while the pass waited' "$w/out" || ok=1
res $ok "apply and change: a failure file made while the pass waits for the perf lock stops it under the lock, exit 1"

world a-nofail
echo never > "$w/zone.1"
echo never > "$w/zone.2"
mkdir -p "$rb"
ln -s /nonexistent/blockie-clocks-failed "$rb/failed"
run apply
[[ $rc == 1 && -e $rb/writing && ! -f $rb/failed && $(kn) == "500000 850000 0" ]] &&
  grep -qx 'systemctl --no-block stop blockie-clocks-change.timer blockie-clocks.path failed=no writing=yes' "$w/calls" &&
  grep -q 'could not be made' "$w/out"
res $? "apply: a failed file that cannot be made keeps the marker, the timer and path stopped all the same"

world a-65 trip65
run apply
[[ $rc == 0 && -z $(wl) && $(st) == "applied trip65|caps trip65" ]] && form boot
res $? "apply: trip65 on the boot read: no write, applied"

for f in run/blockie-clocks/failed run/blockie-thermal-failed; do
  for v in apply change; do
    world "f-$v-${f##*/}"
    mkdir -p "$rb"
    : > "$r/$f"
    run "$v"
    [[ $rc == 1 && -z $(wl) && $(locks) == 0 ]] && grep -q "$f exists, nothing written until the reboot" "$w/out"
    res $? "$v: $f present: nothing written, no lock, exit 1"
  done
done

conf() {
  world "k-$1"
  [[ $1 != over ]] || echo 1950000 > "$cf/policy6/cpuinfo_max_freq"
  sed -i "$3" "$r/usr/lib/blockie/clocks.conf"
  run apply
  [[ $rc == 2 && -z $(wl) && ! -e $rb/state ]] && grep -qF "$4" "$w/out"
  res $? "conf: $2: exit 2, nothing written"
}
conf over "a cap over cpuinfo_max_freq" 's/^policy6=1443000$/policy6=2000000/' 'policy6=2000000 is not a step of policy6 at or under 1950000'
conf step "a cap off the available steps" 's/^policy6=1443000$/policy6=1440000/' 'policy6=1440000 is not a step of policy6'
conf line "an unknown line" 's/^trip=80000$/trip=70000/' "[trip80] trip '70000' is not one of"
conf default "no default" '/^default=/d' "the default '' names no profile"
conf up "an upbound over 29" 's/^trip=65000$/trip=65000\nupbound=30/' '[trip65] upbound=30 is not a GED index 0 to 29'
conf dup "a section twice" 's/^\[trip80\]$/[trip65]/' '[trip65] twice'
conf key "an unknown key" 's/^trip=80000$/trip=80000\nfoo=1/' 'foo is not a key here'

world m-none
rm -f "${r:?}/run/blockie-set/settings"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] &&
  grep -q 'no settings map at .*, trip72-big1443 applies' "$w/out"
r1=$?
run change
[[ $r1 == 0 && $rc == 0 ]] && ! grep -q 'applies' "$w/out"
r1=$?
wmap trip99
run change
[[ $r1 == 0 && $rc == 0 ]] && grep -q 'power.clocks trip99 is not in .*, trip72-big1443 applies' "$w/out"
res $? "W: no settings map gives the default, logged once per reason"

world m-line
printf 'version 1\nbuttons.home.hold switcher\n' > "$r/run/blockie-set/settings"
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] && grep -q 'no power.clocks line in' "$w/out"
res $? "W: no power.clocks line gives the default"

world m-unknown trip99
run apply
[[ $rc == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] && grep -q 'power.clocks trip99 is not in' "$w/out"
res $? "W: an id not in clocks.conf gives the default"

declare -A tripof=([trip72-big1443]=72000 [trip65]=65000 [trip72]=72000 [trip80]=80000)
pairs='trip72-big1443 trip65 tzcpu=65000 policy6=2000000
trip72-big1443 trip72 policy6=2000000
trip72-big1443 trip80 policy6=2000000 tzcpu=80000
trip65 trip72-big1443 policy6=1443000 tzcpu=72000
trip65 trip72 tzcpu=72000
trip65 trip80 tzcpu=80000
trip72 trip72-big1443 policy6=1443000
trip72 trip65 tzcpu=65000
trip72 trip80 tzcpu=80000
trip80 trip72-big1443 policy6=1443000 tzcpu=72000
trip80 trip65 tzcpu=65000
trip80 trip72 tzcpu=72000'
while read -r f g e; do
  p6=2000000
  [[ $g != trip72-big1443 ]] || p6=1443000
  reach "p-$f-$g" "$f"
  wmap "$g"
  run change
  [[ $rc == 0 && $(wl) == "$e" && $(st) == "applied $g|caps $g" && $(locks) == 1 && $(kn) == "1800000 $p6 0" &&
    $(cat "$th/thermal_zone5/trip_point_3_temp") == "${tripof[$g]}" ]] && form "${tripof[$g]}" && ! grep -q 'once more' "$w/out"
  res $? "change: $f to $g: $e, applied"
done <<< "$pairs"

while read -r f g e; do
  reach "q-$f-$g" "$f"
  wmap "$g"
  : > "$w/under.policy6"
  run change
  [[ $rc == 0 && $(wl) == "$e" && $(st) == "applied $g|caps $g" && $(locks) == 1 ]]
  r1=$?
  run change
  [[ $r1 == 0 && $rc == 0 && -z $(wl) && $(locks) == 0 && $(st) == "applied $g|caps $g" ]]
  res $? "change: $f to $g with policy6 reading under its write at cur_state 0: one pass, applied, the next pass writes nothing and takes no lock"
done <<< "$pairs"

reach c-t2b1 trip72
echo 1354000 > "$cf/policy6/scaling_max_freq"
cur 1
wmap trip72-big1443
run change
[[ $rc == 0 && $(wl) == "policy6=1443000 policy0=1800000 upbound=0" && $(st) == "applied trip72-big1443|caps trip72-big1443" ]] &&
  form 72000
res $? "change: T2 to B1 with a cooler holding policy6 at 1354000: 1443000 written at once, no trip step, applied"

reach c-t1b1 trip80
cur 1
wmap trip72-big1443
run change
[[ $rc == 2 && $(wl) == "policy6=1443000 policy0=1800000 upbound=0" && $(locks) == 1 &&
  $(st) == "pending trip72-big1443|caps trip72-big1443" ]] && form 80000 && ! grep -q 'once more' "$w/out"
r1=$?
run change
[[ $r1 == 0 && $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip72-big1443|caps trip72-big1443" ]]
res $? "change: T1 to B1 hot: 1443000 at once, the trip pending, no second turn, the next pass takes no lock while the gate misses"

ok=0
reach c-b1a1 trip72-big1443
temp 64000
wmap trip65
run change
[[ $rc == 2 && $(wl) == policy6=2000000 && $(st) == "pending trip65|caps trip65" && $(kn) == "1800000 2000000 0" ]] &&
  form 72000 || ok=1
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip65|caps trip65" ]] && form 72000 || ok=1
temp 58000
run change
[[ $rc == 0 && $(wl) == tzcpu=65000 && $(locks) == 1 && $(st) == "applied trip65|caps trip65" ]] && form 65000 || ok=1
res $ok "change: B1 to A1 under load at 64 C: 1443 lifted, the trip stays 72, pending with caps trip65, no lock on the next pass; at 58 C trip 65 and applied"

reach c-lag trip72-big1443
echo 1295000 > "$cf/policy6/scaling_max_freq"
run change
[[ $rc == 0 && -z $(wl) && $(locks) == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "change: policy6 reading under its cap after a cooler's release: one pass, no write, no lock"

reach c-above trip72-big1443
echo 2000000 > "$cf/policy6/scaling_max_freq"
run change
[[ $rc == 0 && $(wl) == policy6=1443000 && $(locks) == 1 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "change: policy6 reading over its cap with caps trip72-big1443: rewritten under the lock"

reach c-idle trip72-big1443
for f in "$th"/cooling_device*/cur_state "$th"/thermal_zone*/temp "$th"/thermal_zone*/type "$r/blockie/lib/modules.second"; do
  rm -f "${f:?}"
  mkfifo "$f"
done
TO=10 run change
[[ $rc == 0 && -z $(wl) && $(locks) == 0 && $(st) == "applied trip72-big1443|caps trip72-big1443" ]]
res $? "change: nothing needed: no write, no lock, no cur_state, zone or module order read"

ok=0
reach c-gate trip65
wmap trip72
cur 1
run change
[[ $rc == 2 && $(st) == "pending trip72|caps trip72" && $(wl) == "policy6=2000000 policy0=1800000 upbound=0" &&
  $(locks) == 1 ]] && form boot || ok=1
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 ]] || ok=1
cur 0
run change
[[ $rc == 0 && $(wl) == tzcpu=72000 && $(locks) == 1 && $(st) == "applied trip72|caps trip72" ]] && form 72000 || ok=1
res $ok "change: the gate missing on the unlocked read takes no lock; a later pass where it holds writes the trip"

ok=0
reach c-margin trip65
wmap trip72
temp 62000
run change
[[ $rc == 2 && $(st) == "pending trip72|caps trip72" && $(wl) != *tzcpu* ]] && form boot &&
  grep -q 'trip 72000 waits: mtktscpu 62000, the trip write wants 60000 or under' "$w/out" || ok=1
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 ]] || ok=1
res $ok "change: mtktscpu at 62.0 C holds a 65 to 72 write (5 C under the lower trip), no lock on the next pass"

reach c-w trip65
wmap trip72-big1443
script hook.1 "printf 'version 1\\npower.clocks trip80\\n' > '$r/run/blockie-set/settings'"
run change
[[ $rc == 0 && $(wl) == "policy6=1443000 tzcpu=72000 policy6=2000000 tzcpu=80000" && $(locks) == 2 &&
  $(st) == "applied trip80|caps trip80" ]] && form 80000 &&
  grep -q 'power.clocks reads trip80 after the pass for trip72-big1443, once more' "$w/out"
res $? "change: power.clocks changed during a pass: the pass runs again for the new id"

reach c-fbad trip72-big1443
"$w/kernel" mkzone 72000 wrongtp
wmap trip65
ok=0
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip65|caps trip72-big1443" ]] && form 72000 &&
  grep -q 'pending trip65: a raise waits, F unproven: links' "$w/out" || ok=1
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip65|caps trip72-big1443" ]] || ok=1
res $ok "change: a raise with F unproven (a wrong cdevK_trip_point) and no lowering due: no raise, no trip, no lock on any pass"

ok=0
world c-unprov trip65
unknown
run change
[[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip65|caps trip65" ]] || ok=1
for i in 1 2 3; do
  run change
  [[ $rc == 2 && -z $(wl) && $(locks) == 0 && $(st) == "pending trip65|caps trip65" ]] || ok=1
done
res $ok "change: F unprovable with every raise at cpuinfo_max_freq and every cur_state 0: caps trip65 completes, the timer passes after it take no lock"

reach c-fchg trip65
wmap trip72
script onlock "cat '$lib/clocks/tzcpu-72000.read' '$t/gd' > '$r/proc/driver/thermal/tzcpu'; '$w/kernel' mkzone 72000 observed"
run change
[[ $rc == 0 && -z $(wl) && $(locks) == 1 && $(st) == "applied trip72|caps trip72" ]]
res $? "change: F read again under the lock: a trip found at W's line there is not written"

reach c-mark-ok trip72
savez
printf '72000 65000\n' > "$rb/writing"
run change
[[ $rc == 0 && -z $(wl) && $(locks) == 1 && ! -e $rb/writing && $(st) == "applied trip72|caps trip72" ]] &&
  grep -q "found .*writing reading '72000 65000'" "$w/out" && grep -qx 'blockie-clocks: trip 72000 accepted on try 1' "$w/out"
res $? "change: a writing marker with nothing else to write takes the lock; its first line accepted, the marker removed"

reach c-mark-miss trip65
savez
printf '72000 65000\n' > "$rb/writing"
run change
[[ $rc == 2 && $(wl) == tzcpu=65000 && ! -e $rb/writing && ! -e $rb/failed && $(st) == "pending trip65|caps trip65" &&
  ! -e $rb/refused ]] &&
  form 65000 && grep -q 'trip 72000 not accepted after 7 tries' "$w/out"
res $? "change: a marker whose first line is not in force: its second line written again and accepted, exit 2"

reach c-mark-fail trip65
savez
printf '72000 65000\n' > "$rb/writing"
echo never > "$w/zone.1"
run change
[[ $rc == 1 && $(wl) == "tzcpu=65000 policy0=500000 policy6=850000" && -e $rb/failed && ! -e $rb/writing &&
  $(st) == "failed|caps trip65" ]]
res $? "change: a marker missing and its second line failing: the lowest steps, failed, exit 1"

world c-kill
mkdir -p "$rb"
printf 'applied trip72-big1443\ncaps trip72-big1443\n' > "$rb/state"
echo 500000 > "$cf/policy0/scaling_max_freq"
echo 850000 > "$cf/policy6/scaling_max_freq"
printf '65000 65000\n' > "$rb/writing"
savez
rm -rf "${th:?}/thermal_zone5"
echo never > "$w/zone.1"
run change
[[ $rc == 1 && $(wl) == "tzcpu=65000 policy0=500000 policy6=850000" && -e $rb/failed && ! -e $rb/writing ]] &&
  grep -qx 'systemctl --no-block stop blockie-clocks-change.timer blockie-clocks.path failed=yes writing=no' "$w/calls"
res $? "change: a kill between the lowest steps and failed: the next run completes the failure path"

reach c-held trip65
wmap trip72
hold
run change
unhold
[[ $rc == 2 && -z $(wl) && $(st) == "pending trip72|caps trip72" ]] && grep -q 'blockie-perf.lock is held' "$w/out"
res $? "change: the perf lock held for 10 s: pending, nothing written, exit 2"

world c-undo trip72
printf '\n[both]\ntrip=72000\npolicy6=1443000\npolicy0=1500000\n' >> "$r/usr/lib/blockie/clocks.conf"
run apply
echo 1621000 > "$cf/policy6/scaling_max_freq"
wmap both
echo einval > "$w/fail.2"
run change
[[ $rc == 2 && $(wl) == "policy6=1443000 policy0=1500000 policy0=1800000 policy6=2000000" && $(kn) == "1800000 2000000 0" &&
  $(st) == "pending both|caps trip72" ]]
res $? "undo: a failed pass puts each cap back to the value of the profile its caps line names, not a throttled read"

reach r-caps trip72-big1443
run restore
[[ $rc == 0 && $(wl) == "policy6=2000000 policy0=1800000 upbound=0" && $(locks) == 0 && $(kn) == "1800000 2000000 0" ]] &&
  form 72000
res $? "restore: the caps only, no lock, the trip stays"

for f in run/blockie-clocks/failed run/blockie-thermal-failed; do
  reach "r-${f##*/}" trip72-big1443
  : > "$r/$f"
  run restore
  [[ $rc == 0 && -z $(wl) && $(kn) == "1800000 1443000 0" ]]
  res $? "restore: nothing while $f exists"
done

world u
run other
[[ $rc == 2 && -z $(wl) ]] && grep -q usage "$w/out"
res $? "an unknown verb is a usage error"

if (( fails )); then
  echo "clocks: $fails failed"
  exit 1
fi
echo "clocks: ok"
