#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/steam-lib.XXXXXX")
trap 'rm -rf "${t:?}"' EXIT
sf=$here/../system_files
helper=/usr/libexec/blockie/blockie-ports
[[ -x $helper ]] || helper=$sf/usr/libexec/blockie/blockie-ports
shipped=/usr/share/blockie/steam
[[ -f $shipped/engines.tsv ]] || shipped=$sf/usr/share/blockie/steam

mkdir -p "$t/py"
PORTS_BIN=$helper SHIPPED=$shipped FIXTURES=$here/ports-steam T=$t/py timeout -k 10 300 python3 "$here/steam-lib.py" \
  > "$t/py.out" 2>&1
rc=$?
cat "$t/py.out"
n=$(grep -c '^FAIL ' "$t/py.out")
if (( n > 0 )); then
  echo "steam-lib: $n failed"
  exit 1
fi
if (( rc != 0 )); then
  echo "FAIL python cases ended with rc $rc"
  echo "steam-lib: 1 failed"
  exit 1
fi
echo "steam-lib: ok"
exit 0
