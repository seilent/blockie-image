#!/usr/bin/env bash
set -euo pipefail

name=libretro-shaders-blockie
fail() { echo "pkg-$name: $*" >&2; exit 1; }

out=${1:?usage: pkg-libretro-shaders-blockie.sh <outdir>}
shopt -s nullglob
rpms=("$out"/"$name"-[0-9]*.rpm)
(( ${#rpms[@]} == 1 )) || fail "expected one $name RPM, found ${#rpms[@]}"
rpm=${rpms[0]}
[[ $(rpm -qp --qf '%{NAME} %{ARCH}' "$rpm") == "$name noarch" ]] || fail "name or arch"
[[ $(rpm -qp --qf '%{LICENSE}' "$rpm") == "GPL-2.0-only AND GPL-2.0-or-later AND MIT AND LicenseRef-Fedora-Public-Domain" ]] ||
  fail "licence tag"
sh=/usr/share/libretro/shaders
gs=$sh/glsl-shaders
lic=/usr/share/licenses/$name
upstream=(
  "crt/shaders/crt-gdv-mini.glsl 3df4e21e703ddf49355586df995eaba4ec977962867741c6dfcb887f714cd839"
  "handheld/shaders/lcd3x.glsl 1ca0fb49b35fe3415b0eeb78518e5042a87f8b26f0ae76bf7b99fd56a5c7762e"
  "handheld/shaders/zfast_lcd.glsl d565dd0a410b57228010f9493a8405d3886a17641e5cfed9d85fef31de1f274e"
  "handheld/shaders/lcd1x.glsl 29c7a8444e5a22e4300c0f43d49a446c4788b0da21b316fd396eacfff1ec8043"
  "handheld/shaders/sameboy-lcd.glsl dc2bfa2adfea7346f1d3249b5b146da28b3c92498e548af743d7dcfaae0b892d"
  "handheld/shaders/retro-v2.glsl 07d6a9ab474eab74bdedcbde3126c4cbe729f038e9de358da7a90b486b2cd3cf"
)
presets=(crt-gdv-mini lcd3x gb-zfast-lcd gba-zfast-lcd lcd1x sameboy-lcd retro-v2 sp101-color gba-zfast-lcd-sp101)
want=$(
  printf '%s\n' /usr/share/libretro "$sh" "$sh/blockie" "$sh/blockie/sp101-color.glsl" "$gs" "$gs/crt" "$gs/crt/shaders" \
    "$gs/handheld" "$gs/handheld/shaders" "$lic" "$lic/LICENSE"
  for p in "${presets[@]}"; do echo "$sh/blockie/$p.glslp"; done
  for u in "${upstream[@]}"; do echo "$gs/${u% *}"; done
)
files=$(rpm -qpl "$rpm")
[[ $(LC_ALL=C sort <<< "$files") == "$(LC_ALL=C sort <<< "$want")" ]] || fail "file list"
! grep -qE '\.slangp?$' <<< "$files" || fail "a slang file"
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
(cd "$t" && rpm2cpio "$rpm" | cpio -idm --quiet)
for u in "${upstream[@]}"; do
  [[ $(sha256sum < "$t$gs/${u% *}" | cut -d' ' -f1) == "${u#* }" ]] || fail "$gs/${u% *} is not the pinned upstream file"
done
[[ $(sha256sum < "$t$lic/LICENSE" | cut -d' ' -f1) == 8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643 ]] ||
  fail "LICENSE is not the repo's GPL-2.0 LICENSE"
grep -q 'Permission is hereby granted' "$t$gs/handheld/shaders/sameboy-lcd.glsl" || fail "sameboy-lcd.glsl lacks its MIT text"
python3 - "$t" "$sh" "${presets[@]}" <<'EOF' || fail "presets"
import os, re, sys

root, sh, names = sys.argv[1], sys.argv[2], sys.argv[3:]
base = root + sh
line_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*) = ("?)([^"]*)\2$')
indexed = re.compile(r"^(shader|alias|filter_linear|wrap_mode|mipmap_input|float_framebuffer|srgb_framebuffer|"
                     r"frame_count_mod|scale_type|scale_type_x|scale_type_y|scale|scale_x|scale_y)([0-9]+)$")
pragma = re.compile(r'^#pragma parameter\s+([A-Za-z_][A-Za-z0-9_]*)\s+"[^"]*"\s+(\S+)\s+(\S+)\s+(\S+)')
bools = {"filter_linear", "mipmap_input", "float_framebuffer", "srgb_framebuffer"}
bad = []


def number(v):
    try:
        return float(v)
    except ValueError:
        return None


for n in names:
    path = os.path.join(base, "blockie", n + ".glslp")
    keys = {}
    for raw in open(path, encoding="ascii").read().split("\n"):
        if not raw:
            continue
        m = line_re.match(raw)
        if not m:
            bad.append(f"{n}: line {raw!r}")
            continue
        if m.group(1) in keys:
            bad.append(f"{n}: {m.group(1)} twice")
        keys[m.group(1)] = m.group(3)
    count = keys.get("shaders", "")
    if not count.isdigit() or int(count) < 1:
        bad.append(f"{n}: shaders = {count!r}")
        continue
    count = int(count)
    shaders = sorted(int(m.group(2)) for k in keys for m in [indexed.match(k)] if m and m.group(1) == "shader")
    if shaders != list(range(count)):
        bad.append(f"{n}: shaders = {count} with shader lines {shaders}")
    params = {}
    for i in range(count):
        rel = keys.get(f"shader{i}", "")
        target = os.path.normpath(os.path.join(os.path.dirname(path), rel))
        real = os.path.realpath(target)
        if not rel or not real.startswith(base + "/") or not real.endswith(".glsl") or not os.path.isfile(real):
            bad.append(f"{n}: shader{i} = {rel!r} does not resolve to a .glsl in the package")
            continue
        for src in open(real, encoding="ascii").read().splitlines():
            m = pragma.match(src.strip())
            if m:
                params[m.group(1)] = tuple(number(v) for v in m.group(2, 3, 4))
    for k, v in keys.items():
        m = indexed.match(k)
        if k == "shaders":
            continue
        if k == "feedback_pass":
            if not v.isdigit() or int(v) >= count:
                bad.append(f"{n}: {k} = {v!r}")
            continue
        if m:
            kind, i = m.group(1), int(m.group(2))
            ok = i < count
            if kind in bools:
                ok = ok and v in ("true", "false")
            elif kind.startswith("scale_type"):
                ok = ok and v in ("source", "viewport", "absolute")
            elif kind.startswith("scale"):
                ok = ok and number(v) is not None
            elif kind == "wrap_mode":
                ok = ok and v in ("clamp_to_border", "clamp_to_edge", "repeat", "mirrored_repeat")
            elif kind == "frame_count_mod":
                ok = ok and v.isdigit()
            if not ok:
                bad.append(f"{n}: {k} = {v!r}")
            continue
        if k not in params:
            bad.append(f"{n}: {k} is not a #pragma parameter of its passes")
            continue
        x, (_, lo, hi) = number(v), params[k]
        if x is None or lo is None or hi is None or not lo <= x <= hi:
            bad.append(f"{n}: {k} = {v!r} is outside {lo} to {hi}")
for b in bad:
    print(b, file=sys.stderr)
sys.exit(1 if bad else 0)
EOF
n=0
while IFS= read -r -d '' f; do
  ! grep -q '#version' "$f" || fail "${f#"$t"} has a #version line"
  for st in vert frag; do
    d=VERTEX
    [[ $st == vert ]] || d=FRAGMENT
    { printf '#version 100\n#define %s\n#define PARAMETER_UNIFORM\n#define _HAS_ORIGINALASPECT_UNIFORMS\n#define _HAS_FRAMETIME_UNIFORMS\n' "$d"
      cat "$f"; } > "$t/pass.$st"
    glslangValidator -S "$st" "$t/pass.$st" > "$t/glslang.log" 2>&1 || { cat "$t/glslang.log" >&2; fail "${f#"$t"} does not compile as GLSL ES 100 $st"; }
  done
  n=$((n + 1))
done < <(find "$t$sh" -type f -name '*.glsl' -print0)
(( n == 7 )) || fail "compiled $n .glsl files, expected 7"
echo "pkg-$name: ok"
