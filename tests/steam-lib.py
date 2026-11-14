#!/usr/bin/env python3
import contextlib
import fcntl
import gzip
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tarfile
import threading
import time
import traceback
import zlib

sys.dont_write_bytecode = True
BIN = os.environ["PORTS_BIN"]
SHIP = os.environ["SHIPPED"]
T = os.environ["T"]
DATA = f"{T}/data"
PORTS = f"{DATA}/roms/ports"
DL = f"{DATA}/steam-dl"
LIB = f"{DL}/lib"
GAMES = f"{DATA}/steam-games"
GS = f"{GAMES}/.blockie"
USR = f"{T}/usr"
RUN = f"{T}/run"
SRUN = f"{T}/srun"
SDIR = f"{DATA}/steam"
BINS = f"{T}/bin"
DDJSON = f"{T}/dd.json"
DDLOG = f"{T}/dd.log"
FIX = os.environ["FIXTURES"]
ME = pwd.getpwuid(os.getuid()).pw_name
NOW = 1800000000
os.makedirs(BINS, exist_ok=True)
for n in ("fake-dd", "fake-systemctl", "fake-inhibit", "fake-setpriv"):
    shutil.copyfile(f"{FIX}/{n}", f"{BINS}/{n}")
    os.chmod(f"{BINS}/{n}", 0o755)
with open(f"{BINS}/nmcli", "w") as f:
    f.write(f"#!/bin/sh\ncat {T}/nm\n")
with open(f"{BINS}/curl", "w") as f:
    f.write(f"""#!/usr/bin/env python3
import json
import os
import sys
import time
a = sys.argv[1:]
url = a[-1]
with open("{T}/curl.log", "a") as f:
    f.write(url + "\\n")
if "/apps/" not in url:
    r = json.load(open("{T}/runner.json"))
    if r.get("how") == "hang":
        with open("{T}/curl.pid", "w") as f:
            f.write(str(os.getpid()))
        time.sleep(30)
    if r.get("how") != "ok":
        sys.exit(22)
    with open(r["src"], "rb") as s, open(a[a.index("-o") + 1], "wb") as f:
        f.write(s.read())
    sys.exit(0)
app = url.split("/apps/", 1)[1].split("/", 1)[0]
how = json.load(open("{T}/curl.json")).get(app, "fail")
if how == "hang":
    with open("{T}/curl.pid", "w") as f:
        f.write(str(os.getpid()))
    time.sleep(30)
if how == "fail":
    sys.exit(22)
with open(a[a.index("-o") + 1], "wb") as f:
    f.write(b"\\xff\\xd8\\xff\\xe0invented" if how == "ok" else b"<html>invented</html>")
""")
for n in ("nmcli", "curl"):
    os.chmod(f"{BINS}/{n}", 0o755)
os.environ.update({
    "BLOCKIE_PORTS_DATA": DATA, "BLOCKIE_PORTS_MOUNT": "/", "BLOCKIE_PORTS_WAIT_S": "1", "XDG_RUNTIME_DIR": RUN,
    "BLOCKIE_PORTS_SYSTEMCTL": f"{BINS}/fake-systemctl", "BLOCKIE_PORTS_NMCLI": f"{BINS}/nmcli",
    "BLOCKIE_PORTS_STEAM_LIB": USR, "BLOCKIE_PORTS_STEAM_MAP": f"{USR}/steam-map.tsv",
    "BLOCKIE_PORTS_STEAM_LISTS": f"{USR}/steam-files", "BLOCKIE_PORTS_DD": f"{BINS}/fake-dd",
    "BLOCKIE_PORTS_STEAM_RUN": SRUN, "BLOCKIE_PORTS_STEAM_USER": ME, "BLOCKIE_PORTS_USER": ME,
    "BLOCKIE_PORTS_CURL": f"{BINS}/curl", "FAKE_T": T, "FAKE_DD": DDJSON, "FAKE_DD_LOG": DDLOG,
    "BLOCKIE_PORTS_FLOOR": "0", "BLOCKIE_PORTS_INHIBIT": f"{BINS}/fake-inhibit",
    "BLOCKIE_PORTS_SETPRIV": f"{BINS}/fake-setpriv",
    "BLOCKIE_DD_CONFIG": f"{SDIR}/account.config",
})
loader = importlib.machinery.SourceFileLoader("ports", BIN)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("ports", loader))
loader.exec_module(m)
LOG = []
m.log = LOG.append
fails = 0


def res(ok, name, why=""):
    global fails
    print(f"{'ok  ' if ok else 'FAIL'} {name}", flush=True)
    if not ok:
        fails += 1
        for line in why.splitlines():
            print(f"  {line}", flush=True)


class Check:
    def __init__(self):
        self.bad = []

    def __call__(self, cond, what):
        if not cond:
            self.bad.append(what)
        return cond


def case(name):
    def wrap(f):
        try:
            c = Check()
            f(c)
            ok, why = not c.bad, "\n".join(c.bad)
        except Exception:
            ok, why = False, traceback.format_exc(limit=8)
        subprocess.run([f"{BINS}/fake-systemctl", "stop", "blockie-steam-dd@*.service"], capture_output=True,
                       timeout=60)
        for n in ("BLOCKIE_PORTS_STEAM_SCAN_S", "BLOCKIE_PORTS_STEAM_LIBRARY_S"):
            os.environ.pop(n, None)
        m.STALL_S = 120
        m.LIBRARY_RUN_S = 300
        res(ok, name, why)
        return f
    return wrap


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


def rd(path):
    with open(path) as f:
        return f.read()


def setup(map_rows=()):
    os.chdir(T)
    for p in (DATA, USR, RUN):
        if os.path.lexists(p):
            shutil.rmtree(p)
    for d in (PORTS, DL, RUN, f"{USR}/runners.d", f"{USR}/steam-files"):
        os.makedirs(d)
    os.chmod(DL, 0o2750)
    write(f"{T}/scope-rc", "3\n")
    for n in ("engines.tsv", "corrections.tsv"):
        shutil.copyfile(f"{SHIP}/{n}", f"{USR}/{n}")
    write(f"{USR}/steam-map.tsv", "".join(r + "\n" for r in map_rows))
    LOG.clear()


def gid(d):
    return f"{d}00"


def dep(a, d, oslist="-", arch="-", lang="-", lv="0", frm="-", dlc="-", size=100, g=None):
    return f"depot\t{a}\t{d}\t{oslist}\t{arch}\t{lang}\t{lv}\t{frm}\t{dlc}\t{gid(d) if g is None else g}\t{size}"


def app(a, name, kind="game", langs="-"):
    return [f"app\t{a}\t{kind}\t{name}", f"owned\t{a}", f"lang\t{a}\t{langs}"]


def scan(d, names, g=None):
    m.unit_write_paths(d, gid(d) if g is None else g, [(n, 1) for n in names])


def call(*args):
    r, w = os.pipe()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = m.run(["blockie-ports", *args], m.Proto(w))
    finally:
        os.close(w)
    with os.fdopen(r) as f:
        return rc, f.read().splitlines()


def k(paths, os_name):
    hit = m.classify(paths, os_name, m.load_engines())
    return f"{hit[0]}:{os_name}" if hit else "none"


def root(paths, os_name):
    hit = m.classify(paths, os_name, m.load_engines())
    return hit[1] if hit else None


MZ = ["Game.exe", "package.json", "index.html", "js/rmmz_core.js", "js/main.js", "img/titles1/a.png"]
MV = ["Game.exe", "package.json", "www/index.html", "www/js/rpg_core.js"]
GM = ["Invented", "assets/game.unx", "assets/audiogroup1.dat"]


@case("the shipped engines.tsv loads whole after its header; *.node is firm on rmmz and rmmv, every Steamworks deny "
      "provisional; corrections.tsv is its header only; runners.d holds no conf or only nwjs.conf, rmmz:windows "
      "with a whole pin")
def _(c):
    setup()
    rows = m.load_engines()
    lines = rd(f"{SHIP}/engines.tsv").splitlines()
    c(lines[0] == "class\tos\tmatch\troot\tdeny\tdeny_status", f"header {lines[:1]}")
    c(len(rows) == len(lines) - 1 and not LOG, f"{len(rows)} rows of {len(lines) - 1}, log {LOG[:3]}")
    steamworks = {"libsteam_api.so", "steam_api.dll", "steam_api64.dll"}
    for line in lines[1:]:
        f = line.split("\t")
        deny = set() if f[4] == "-" else set(f[4].split(","))
        if f[0] in ("rmmz", "rmmv"):
            c(deny == {"*.node"} and f[5] == "firm", f"{f[0]}: {f[4]} {f[5]}")
        elif deny:
            c(deny <= steamworks and f[5] == "provisional", f"{f[0]}:{f[1]}: {f[4]} {f[5]}")
        else:
            c(f[5] == "-", f"{f[0]}:{f[1]}: no deny but {f[5]}")
    c(rd(f"{SHIP}/corrections.tsv") == "app\tgid\tclass\n" and m.load_corrections() == [] and not LOG,
      f"corrections {rd(f'{SHIP}/corrections.tsv')!r} {LOG[:3]}")
    shipped = sorted(os.listdir(f"{SHIP}/runners.d")) if os.path.isdir(f"{SHIP}/runners.d") else []
    c(shipped in ([], ["nwjs.conf"]), f"runner confs {shipped}")
    if shipped:
        nw = f"{SHIP}/runners.d/nwjs.conf"
        f = m.runner_fields(nw)
        pin = m.runner_pin(nw)
        c(f.get("CLASSES") == "rmmz:windows" and pin is not None and pin["url"].endswith(f"/{pin['file']}") and
          pin["size"] < pin["unpacked"], f"nwjs.conf {f}")


@case("engines.tsv loader: a bad os, root, deny status, an absolute or .. pattern and a % outside the first item "
      "are dropped and logged")
def _(c):
    setup()
    bad = ["x\tmacos\ta.dll\t1\t-\t-", "x\twindows\ta.dll\t3\t-\t-", "x\twindows\ta.dll\t1\ta.so\t-",
           "x\twindows\t/a.dll\t1\t-\t-", "x\twindows\ta/../b.dll\t1\t-\t-", "x\twindows\ta.dll,%.exe\t1\t-\t-",
           "x\twindows\ta.dll\t1\tsub/a.so\tfirm", "X\twindows\ta.dll\t1\t-\t-"]
    write(f"{USR}/engines.tsv", rd(f"{SHIP}/engines.tsv") + "".join(x + "\n" for x in bad))
    rows = m.load_engines()
    c(len(rows) == len(rd(f"{SHIP}/engines.tsv").splitlines()) - 1, f"{len(rows)} rows")
    c(sum("engines: line" in x for x in LOG) == len(bad), f"log {LOG}")


@case("classifier: rmmz, both rmmv layouts, rgss with the dll at the root and in System, gamemaker on linux and "
      "windows, fna, xna, monogame, renpy, love, unity three ways, godot with x86_64, x86, x86_32 and arm64, the "
      "catch alls, unknown")
def _(c):
    setup()
    cases = [
        ("rmmz:windows", "windows", MZ),
        ("rmmv:windows", "windows", MV),
        ("rmmv:windows", "windows", ["Game.exe", "package.json", "index.html", "js/rpg_core.js"]),
        ("rgss:windows", "windows", ["Game.exe", "Game.ini", "RGSS104E.dll", "Data/Scripts.rxdata"]),
        ("rgss:windows", "windows", ["Game.exe", "Game.ini", "System/RGSS301.dll", "Data/Scripts.rvdata2"]),
        ("gamemaker:linux", "linux", GM),
        ("gamemaker:linux", "linux", ["runner", "game.unx"]),
        ("gamemaker:windows", "windows", ["Invented.exe", "data.win", "options.ini"]),
        ("fna:linux", "linux", ["Invented.exe", "FNA.dll", "lib64/libFNA3D.so.0"]),
        ("fna:windows", "windows", ["Invented.exe", "FNA.dll"]),
        ("xna:windows", "windows", ["Invented.exe", "Microsoft.Xna.Framework.Game.dll"]),
        ("monogame:linux", "linux", ["Invented", "MonoGame.Framework.dll"]),
        ("renpy:windows", "windows", ["Invented.exe", "renpy/main.py", "game/script.rpyc"]),
        ("renpy:linux", "linux", ["Invented.sh", "renpy/main.py", "game/script.rpyc", "lib/py3-linux-x86_64/Invented"]),
        ("love:windows", "windows", ["Invented.exe", "love.dll", "lua51.dll"]),
        ("unity:linux", "linux", ["Invented.x86_64", "UnityPlayer.so", "Invented_Data/level0"]),
        ("unity:linux", "linux", ["Invented.x86_64", "Invented_Data/globalgamemanagers"]),
        ("unity:windows", "windows", ["Invented.exe", "Invented_Data/globalgamemanagers", "Invented_Data/level0"]),
        ("unity:windows", "windows", ["Invented.exe", "Invented_Data/Managed/Assembly-CSharp.dll"]),
        ("godot:windows", "windows", ["Invented.exe", "Invented.pck"]),
        ("godot:linux", "linux", ["Invented.x86_64", "Invented.pck"]),
        ("godot:linux", "linux", ["Invented.x86", "Invented.pck"]),
        ("godot:linux", "linux", ["Invented.x86_32", "Invented.pck"]),
        ("godot:linux", "linux", ["Invented.arm64", "Invented.pck"]),
        ("linux64:linux", "linux", ["Invented.x86_64", "data/a.dat"]),
        ("win32:windows", "windows", ["Invented.exe", "data/a.dat"]),
        ("none", "linux", ["Invented.bin", "data/a.dat"]),
        ("none", "windows", ["bin/Invented.dat", "readme.txt"]),
        ("none", "windows", []),
    ]
    for want, os_name, paths in cases:
        got = k(paths, os_name)
        c(got == want, f"{paths} on {os_name}: {got}, want {want}")


@case("classifier order: Unity before Godot, a .pck with no exe of its stem is not godot, first row in file order, "
      "the same files per OS")
def _(c):
    setup()
    for want, os_name, paths in (
            ("unity:windows", "windows", ["Invented.exe", "Invented.pck", "UnityPlayer.dll"]),
            ("win32:windows", "windows", ["Launcher.exe", "Sound.pck"]),
            ("gamemaker:windows", "windows", ["Invented.exe", "data.win", "UnityPlayer.dll"]),
            ("gamemaker:linux", "linux", ["Invented.x86_64", "assets/game.unx", "Invented.exe", "data.win"]),
            ("gamemaker:windows", "windows", ["Invented.x86_64", "assets/game.unx", "Invented.exe", "data.win"])):
        got = k(paths, os_name)
        c(got == want, f"{paths} on {os_name}: {got}, want {want}")


@case("classifier deny: *.node at depth 3 gives rmmz-native, at depth 4 in upper case rmmv-native, libsteam_api.so "
      "on gamemaker:linux and unity:linux gives -native, a steam_api.dll beside rmmz stays rmmz")
def _(c):
    setup()
    for want, os_name, paths in (
            ("rmmz-native:windows", "windows", MZ + ["js/libs/greenworks/greenworks-win64.node"]),
            ("rmmv-native:windows", "windows", MV + ["www/js/libs/a/b/GREENWORKS.NODE"]),
            ("gamemaker-native:linux", "linux", GM + ["lib/libsteam_api.so"]),
            ("unity-native:linux", "linux", ["Invented.x86_64", "UnityPlayer.so",
                                             "Invented_Data/Plugins/libsteam_api.so"]),
            ("rmmz:windows", "windows", MZ + ["steam_api.dll", "steam_api64.dll"])):
        got = k(paths, os_name)
        c(got == want, f"{paths[-1]} on {os_name}: {got}, want {want}")


@case("deny_status: the classifier reports the matched row's status; a provisional deny gives -native as a firm "
      "one does")
def _(c):
    setup()
    t = m.load_engines()
    for want, os_name, paths in (
            (("gamemaker-native", "", "provisional"), "linux", GM + ["lib/libsteam_api.so"]),
            (("gamemaker", "", "provisional"), "linux", GM),
            (("rmmz-native", "", "firm"), "windows", MZ + ["js/libs/a/x.node"]),
            (("rgss", "", "-"), "windows", ["Game.exe", "Game.ini", "RGSS104E.dll"])):
        got = m.classify(paths, os_name, t)
        c(tuple(got or ()) == want, f"{paths[-1]}: {got}, want {want}")


@case("classifier paths: case mismatched Windows paths with backslashes match, root 1 recorded in its own case, "
      "depth 2 and a catch all below the root are not matched")
def _(c):
    setup()
    odd = ["GAME.EXE", "Package.JSON", "Index.Html", "JS\\RMMZ_Core.JS"]
    c(k(odd, "windows") == "rmmz:windows" and root(odd, "windows") == "",
      f"{k(odd, 'windows')} {root(odd, 'windows')!r}")
    sub = ["TheGame/Game.exe", "TheGame/Package.json", "TheGame/index.html", "TheGame/JS/RMMZ_CORE.JS", "Redist/a.exe"]
    c(k(sub, "windows") == "rmmz:windows" and root(sub, "windows") == "TheGame",
      f"{k(sub, 'windows')} {root(sub, 'windows')!r}")
    deep = ["a/TheGame/package.json", "a/TheGame/index.html", "a/TheGame/js/rmmz_core.js"]
    c(k(deep, "windows") == "none", f"depth 2: {k(deep, 'windows')}")
    c(k(["bin/Invented.x86_64"], "linux") == "none", "linux64 below the root")


@case("corrections: a row with no gid overrides the table on its OS with the table's root, a gid row only the build "
      "holding that gid, bad rows dropped")
def _(c):
    setup()
    write(f"{USR}/corrections.tsv", "app\tgid\tclass\n9000003\t-\trmmz:windows\n9000004\t900004100\tnone\n"
          "9000005\t-\trmmz:macos\n9000x\t-\tnone\n9000006\tg1\tnone\n")
    fixes = m.load_corrections()
    c(len(fixes) == 2 and sum("corrections: line" in x for x in LOG) == 3, f"{fixes} {LOG}")
    table = m.load_engines()
    sub = [f"Sub/{p}" for p in MZ] + ["Sub/js/plugins/x.node"]
    views = {"windows": m.lib_view(sub), "linux": m.lib_view(GM)}
    builds = {"windows": [("9000031", "900003100", 1)], "linux": [("9000032", "900003200", 1)]}
    got = m.app_classes("9000002", views, builds, table, fixes)
    c(got == {"windows": ["rmmz-native", "Sub", "firm"], "linux": ["gamemaker", "", "provisional"]},
      f"no row for the app changed the table result {got}")
    got = m.app_classes("9000003", views, builds, table, fixes)
    c(got == {"windows": ["rmmz", "Sub", "firm"], "linux": ["gamemaker", "", "provisional"]}, f"{got}")
    builds = {"windows": [("9000041", "900004100", 1)], "linux": [("9000042", "900004200", 1)]}
    got = m.app_classes("9000004", views, builds, table, fixes)
    c(got == {"windows": ["none", "", "-"], "linux": ["gamemaker", "", "provisional"]}, f"{got}")
    builds = {"windows": [("9000041", "900004199", 1)], "linux": [("9000042", "900004200", 1)]}
    c(m.app_classes("9000004", views, builds, table, fixes)["windows"] == ["rmmz-native", "Sub", "firm"],
      "a gid row applied to a later build")


@case("corrections: a gid row wins over a row with no gid for its build, whichever comes first in the file")
def _(c):
    setup()
    table = m.load_engines()
    views = {"windows": m.lib_view(MZ)}
    for body in ("9000007\t900007100\tnone\n9000007\t-\trmmv:windows\n",
                 "9000007\t-\trmmv:windows\n9000007\t900007100\tnone\n"):
        write(f"{USR}/corrections.tsv", "app\tgid\tclass\n" + body)
        fixes = m.load_corrections()
        got = m.app_classes("9000007", views, {"windows": [("9000071", "900007100", 1)]}, table, fixes)
        c(got == {"windows": ["none", "", "-"]}, f"{body!r}: {got}")
        got = m.app_classes("9000007", views, {"windows": [("9000071", "900007199", 1)]}, table, fixes)
        c(got == {"windows": ["rmmv", "", "firm"]}, f"{body!r} on another build: {got}")


@case("the app's class: the first offered in table order, gamemaker:windows never takes a gamemaker:linux conf, "
      "with none offered the first matched, none for unknown")
def _(c):
    setup()
    table = m.load_engines()
    both = {"windows": ["gamemaker", ""], "linux": ["gamemaker", ""]}
    c(m.lib_pick(both, table, ["gamemaker:windows"]) == "windows", "offered windows")
    c(m.lib_pick(both, table, ["gamemaker:linux"]) == "linux", "offered linux")
    c(m.lib_pick(both, table, []) == "linux", "none offered: the linux row is first in the table")
    c(m.lib_pick({"windows": ["gamemaker", ""]}, table, ["gamemaker:linux"]) == "windows", "matched, not offered")
    c(m.lib_pick({"windows": ["rmmz", ""], "linux": ["gamemaker", ""]}, table, ["gamemaker:linux", "rmmz:windows"]) ==
      "windows", "table order, not conf order")
    c(m.lib_pick({"windows": ["rmmz-native", ""], "linux": ["unity", ""]}, table, ["rmmz:windows"]) == "windows",
      "a -native class ranks as its base and is never offered")
    c(m.lib_pick({"windows": ["unknown", ""], "linux": ["none", ""]}, table, ["rmmz:windows"]) is None, "unknown")
    write(f"{USR}/runners.d/a.conf", "CLASSES=rmmz:windows rmmv:windows\nURL=https://example.invalid/a\n")
    write(f"{USR}/runners.d/b.conf", "CLASSES=\"gamemaker:linux rmmz:windows rmmz:macos\"\n")
    write(f"{USR}/runners.d/c.txt", "CLASSES=unity:linux\n")
    c(m.load_offered() == ["rmmz:windows", "rmmv:windows", "gamemaker:linux"], f"offered {m.load_offered()}")


def builds_lib():
    lines = (app("9000010", "Four Tongues", langs="japanese,schinese,koreana,tchinese")
             + [dep("9000010", "9000011"), dep("9000010", "9000012", lang="japanese"),
                dep("9000010", "9000013", lang="schinese"), dep("9000010", "9000014", lang="koreana"),
                dep("9000010", "9000015", lang="tchinese")]
             + app("9000020", "One Tongue", langs="english") + [dep("9000020", "9000021", oslist="windows")]
             + app("9000030", "Twelve Tongues",
                   langs="english,french,german,italian,spanish,polish,russian,brazilian,turkish,dutch,czech")
             + [dep("9000030", "9000031"), dep("9000030", "9000032", lang="japanese")]
             + app("9000040", "With DLC", langs="english")
             + [dep("9000040", "9000041"), dep("9000040", "9000049", arch="64"), dep("9000040", "9000043", arch="32"),
                dep("9000040", "9000048", lang="english"), dep("9000040", "9000042", dlc="9000401"),
                dep("9000040", "9000044", dlc="9000402"), dep("9000040", "9000045", frm="228980"),
                dep("9000040", "9000047", lv="1"), "owned\t9000401"]
             + app("9000050", "Only 32") + [dep("9000050", "9000051"), dep("9000050", "9000052", arch="32")]
             + app("9000060", "Two OSes")
             + [dep("9000060", "9000061", oslist="windows"), dep("9000060", "9000062", oslist="linux", arch="64"),
                dep("9000060", "9000063", oslist="linux", arch="32"), dep("9000060", "9000064")]
             + app("9000070", "A DLC", kind="dlc") + [dep("9000070", "9000071")]
             + app("9000080", "A Demo", kind="Demo") + [dep("9000080", "9000081")]
             + app("9000090", "A Tool", kind="tool") + [dep("9000090", "9000091")]
             + app("9000100", "Mac Only") + [dep("9000100", "9000101", oslist="macos")])
    m.unit_library_done(lines, NOW)
    return m.read_library()


@case("builds: neutral, then the picked osarch, then the language, then owned DLC; 64 over 32; borrowed, low violence "
      "and unowned DLC depots dropped; per OS; kept types")
def _(c):
    setup()
    lib = builds_lib()
    c(lib is not None, f"library not read {LOG}")

    def ids(a, os_name):
        return [d for d, _, _ in m.lib_builds(a, lib["apps"][a], lib)[2].get(os_name, [])]
    c(ids("9000040", "windows") == ["9000041", "9000049", "9000048", "9000042"], f"{ids('9000040', 'windows')}")
    c(ids("9000050", "windows") == ["9000051", "9000052"], f"{ids('9000050', 'windows')}")
    c(m.lib_oses(lib["apps"]["9000060"]) == ["windows", "linux"], f"{m.lib_oses(lib['apps']['9000060'])}")
    c(ids("9000060", "windows") == ["9000061", "9000064"] and ids("9000060", "linux") == ["9000064", "9000062"],
      f"{ids('9000060', 'windows')} {ids('9000060', 'linux')}")
    c(m.lib_oses(lib["apps"]["9000040"]) == ["windows"], "no named OS is windows")
    kept = sorted(a for a, info in lib["apps"].items() if m.lib_kept(info))
    c(kept == ["9000010", "9000020", "9000030", "9000040", "9000050", "9000060", "9000080"], f"kept {kept}")
    c(m.lib_builds("9000040", lib["apps"]["9000040"], lib, {"9000042"})[2]["windows"][-1][0] == "9000048",
      "a dropped DLC depot stayed in the build")


@case("builds: the osarch comes from the picked base depots only; empty oslist depots also make the windows build "
      "beside a linux tagged one; an unknown osarch or OS drops that depot and the refresh still writes")
def _(c):
    setup()
    lines = (app("9000110", "Arch Pick", langs="english,japanese")
             + [dep("9000110", "9000111"), dep("9000110", "9000112", arch="32"),
                dep("9000110", "9000113", arch="64", lang="japanese"),
                dep("9000110", "9000114", arch="64", dlc="9000411"), "owned\t9000411"]
             + app("9000120", "Linux Tagged") + [dep("9000120", "9000121"), dep("9000120", "9000122", oslist="linux")]
             + app("9000130", "Odd Values")
             + [dep("9000130", "9000131"), dep("9000130", "9000132", arch="arm64"),
                dep("9000130", "9000133", oslist="android"), dep("9000130", "9000134", oslist="Windows", arch="64")])
    m.unit_library_done(lines, NOW)
    lib = m.read_library()

    def ids(a, os_name):
        return [d for d, _, _ in m.lib_builds(a, lib["apps"][a], lib)[2].get(os_name, [])]
    c(ids("9000110", "windows") == ["9000111", "9000112"],
      f"english over a 64 bit japanese {ids('9000110', 'windows')}")
    c(m.lib_oses(lib["apps"]["9000120"]) == ["windows", "linux"], f"{m.lib_oses(lib['apps']['9000120'])}")
    c(ids("9000120", "windows") == ["9000121"] and ids("9000120", "linux") == ["9000121", "9000122"],
      f"{ids('9000120', 'windows')} {ids('9000120', 'linux')}")
    c(ids("9000130", "windows") == ["9000131", "9000134"], f"odd values {ids('9000130', 'windows')}")


@case("builds: an unknown oslist token is dropped, not the depot: windows,steamos stays in the windows build, a "
      "depot with only unknown tokens is dropped")
def _(c):
    setup()
    lines = app("9000140", "Invented Tags") + [dep("9000140", "9000141", oslist="windows,steamos"),
                                                dep("9000140", "9000142", oslist="steamos"), dep("9000140", "9000143")]
    m.unit_library_done(lines, NOW)
    lib = m.read_library()
    b = m.lib_builds("9000140", lib["apps"]["9000140"], lib)[2]
    c([d for d, _, _ in b.get("windows", [])] == ["9000141", "9000143"] and "linux" not in b, f"{b}")


@case("choices: four language depots and no english default to the lowest depot's language; baselanguages english "
      "and one depot is one choice; 12 languages in two sets are two choices; a .lang pick holds, a bad one does not")
def _(c):
    setup()
    lib = builds_lib()
    ch, choices, builds = m.lib_builds("9000010", lib["apps"]["9000010"], lib)
    c(sorted(choices) == ["japanese", "koreana", "schinese", "tchinese"] and ch == "japanese" and
      [d for d, _, _ in builds["windows"]] == ["9000011", "9000012"], f"{ch} {sorted(choices)} {builds}")
    ch, choices, builds = m.lib_builds("9000020", lib["apps"]["9000020"], lib)
    c(list(choices) == ["english"] and ch == "english", f"{ch} {choices}")
    ch, choices, builds = m.lib_builds("9000030", lib["apps"]["9000030"], lib)
    eleven = "brazilian+czech+dutch+english+french+german+italian+polish+russian+spanish+turkish"
    c(sorted(choices) == [eleven, "japanese"] and ch == eleven and
      [d for d, _, _ in builds["windows"]] == ["9000031"], f"{ch} {sorted(choices)}")
    ch, choices, builds = m.lib_builds("9000050", lib["apps"]["9000050"], lib)
    c(list(choices) == ["-"] and ch == "-", f"no languages: {ch} {choices}")
    write(f"{GS}/9000010.lang", "koreana\n")
    ch, _, builds = m.lib_builds("9000010", lib["apps"]["9000010"], lib)
    c(ch == "koreana" and [d for d, _, _ in builds["windows"]] == ["9000011", "9000014"], f"pick {ch} {builds}")
    write(f"{GS}/9000010.lang", "klingon\n")
    c(m.lib_builds("9000010", lib["apps"]["9000010"], lib)[0] == "japanese", "a pick not among the choices held")


@case("the merged view: the last depot wins a path, backslashes become slashes")
def _(c):
    got = m.lib_merged([[("data.win", 1), ("A\\b.txt", 3)], [("data.win", 2)]])
    c(got == {"data.win": 2, "A/b.txt": 3}, f"{got}")


def index_lib(signed=False):
    lines = (app("9000001", "Invented MZ") + [dep("9000001", "9000011", size=300)]
             + app("9000002", "Invented GM") + [dep("9000002", "9000021", oslist="linux", size=50),
                                                 dep("9000002", "9000022", oslist="linux", arch="64", size=20)]
             + app("9000003", "Invented Port") + [dep("9000003", "9000031")]
             + app("9000004", "Invented Pending") + [dep("9000004", "9000041")]
             + app("9000005", "Invented Failed") + [dep("9000005", "9000051")]
             + app("9000006", "Invented GM Win") + [dep("9000006", "9000061", oslist="windows")])
    m.unit_library_done(lines, NOW)
    scan("9000011", MZ)
    scan("9000021", ["assets/game.unx", "assets/audiogroup1.dat"])
    scan("9000022", ["Invented", "assets/game.unx"])
    scan("9000031", ["Invented.exe", "Invented.dat"])
    scan("9000061", ["Invented.exe", "data.win"])
    lib = m.read_library()
    m.unit_scan_result("9000051", gid("9000051"), "network", m.licence_hash(lib), NOW)
    write(f"{USR}/runners.d/test.conf", "CLASSES=rmmz:windows gamemaker:linux\n")
    if signed:
        write(f"{DL}/signed", "signed 1\n")
    return lines


def classes():
    return rd(f"{GS}/classes.tsv").splitlines()


def games():
    return rd(f"{GS}/library.tsv").splitlines()


@case("steam-lib index: classes.tsv per app and OS with the deny status under the table hash, the merged view "
      "classes the neutral plus 64 bit build, the frontend list holds offered and port owned apps, a pending scan and "
      "a reopened failed pair are not done")
def _(c):
    setup(("gamma.zip\t-\t9000003\twindows\t9000031\t-\t-\tgamma\t-\t-\t-\t-",))
    lib_lines = index_lib(signed=True)
    rc, lines = call("steam-lib", "index")
    c(rc == 0 and lines == ["done\tindex"], f"{rc} {lines} {LOG[-3:]}")
    want = [f"hash\t{m.table_hash()}",
            "9000001\twindows\trmmz\t.\tfirm\t9000011:900001100",
            "9000002\tlinux\tgamemaker\t.\tprovisional\t9000021:900002100,9000022:900002200",
            "9000003\twindows\twin32\t.\tprovisional\t9000031:900003100",
            "9000006\twindows\tgamemaker\t.\tprovisional\t9000061:900006100"]
    c(classes() == want, f"classes {classes()}")
    want = ["signed\t1", "scan\t5\t6",
            "app\t9000001\tInvented MZ\trmmz\t-\t-\t300\tget\t-",
            "app\t9000002\tInvented GM\tgamemaker\t-\t-\t70\tget\t-",
            "app\t9000003\tInvented Port\twin32\t-\t-\t100\tget\tgamma.zip"]
    c(games() == want, f"library {games()}")
    c(stat.S_IMODE(os.stat(f"{GS}/library.tsv").st_mode) == 0o644, "the frontend list is not 0644")
    m.unit_library_done(lib_lines, NOW + 600)
    c(not m.scanfail_skip(m.read_scanfail(), "9000051", gid("9000051")), "the failed pair did not reopen")
    call("steam-lib", "index")
    c(games()[1] == "scan\t4\t6", f"a reopened pair counted done {games()[:2]}")


@case("steam-lib index recomputes: a table change reclasses with a new hash, a correction change too, a cut "
      ".paths.gz counts absent")
def _(c):
    setup()
    index_lib()
    call("steam-lib", "index")
    h0 = classes()[0]
    write(f"{USR}/engines.tsv", "".join(x + "\n" for x in rd(f"{SHIP}/engines.tsv").splitlines()
                                        if not x.startswith("rmmz\t")))
    rc, lines = call("steam-lib", "index")
    h1 = classes()[0]
    c(rc == 0 and h1 != h0 and h1 == f"hash\t{m.table_hash()}", f"hash {h0} {h1}")
    c("9000001\twindows\twin32\t.\tprovisional\t9000011:900001100" in classes(), f"classes {classes()}")
    c(not any(x.startswith("app\t9000001\t") for x in games()), f"an unoffered class listed {games()}")
    write(f"{USR}/corrections.tsv", "app\tgid\tclass\n9000001\t-\trmmz:windows\n")
    call("steam-lib", "index")
    c(classes()[0] not in (h0, h1) and "9000001\twindows\trmmz\t.\t-\t9000011:900001100" in classes(),
      f"classes {classes()}")
    c("app\t9000001\tInvented MZ\trmmz\t-\t-\t300\tget\t-" in games(), f"library {games()}")
    p = f"{LIB}/scan/9000061_900006100.paths.gz"
    with open(p, "rb") as f:
        data = f.read()
    with open(p, "wb") as f:
        f.write(data[:len(data) // 2])
    rc, lines = call("steam-lib", "index")
    c(rc == 0 and not any(x.startswith("9000006\t") for x in classes()), f"{lines} {classes()}")
    c(games()[1] == "scan\t4\t6", f"scan line {games()[:2]}")


@case("steam-lib index keeps classes.tsv and the frontend list byte equal when library.tsv is out of form, "
      "unreadable or over its size")
def _(c):
    setup()
    index_lib()
    call("steam-lib", "index")
    before = (rd(f"{GS}/classes.tsv"), rd(f"{GS}/library.tsv"))
    lib_tsv = f"{LIB}/library.tsv"
    good = rd(lib_tsv)
    for how in ("form", "dir", "size"):
        if how == "form":
            write(lib_tsv, good + "depot\tx\n", 0o640)
        elif how == "dir":
            os.unlink(lib_tsv)
            os.mkdir(lib_tsv)
        else:
            os.rmdir(lib_tsv)
            write(lib_tsv, good, 0o640)
            m.LIBRARY_MAX = 10
        LOG.clear()
        try:
            rc, out = call("steam-lib", "index")
        finally:
            m.LIBRARY_MAX = 64 << 20
        c(rc == 1 and out == ["fail\tindex\tother"], f"{how}: {rc} {out}")
        c((rd(f"{GS}/classes.tsv"), rd(f"{GS}/library.tsv")) == before, f"{how}: an output changed")
        c(any("classes.tsv and library.tsv kept" in x for x in LOG), f"{how}: {LOG[-2:]}")


@case("steam-lib index with no library yet writes the hash, signed 0 and scan 0 0; an unknown word fails other")
def _(c):
    setup()
    rc, lines = call("steam-lib", "index")
    c(rc == 0 and classes() == [f"hash\t{m.table_hash()}"] and games() == ["signed\t0", "scan\t0\t0"],
      f"{lines} {classes()} {games()}")
    rc, lines = call("steam-lib", "nonesuch")
    c(rc == 1 and lines == ["fail\tnonesuch\tother"], f"{rc} {lines}")
    with contextlib.redirect_stdout(io.StringIO()):
        c(m.run(["blockie-ports", "steam-lib"], m.Proto(os.open(os.devnull, os.O_WRONLY))) == 64, "no word")


@case("library.tsv: the unit writes it 0640 by rename, refuses a line out of form or an oversize file before the "
      "rename and keeps the old file; a reader refuses the whole file on a bad line; names over 256 bytes or with a "
      "control character are out of form")
def _(c):
    setup()
    lines = app("9000001", "Invented") + [dep("9000001", "9000011")]
    m.unit_library_done(lines, NOW)
    old = rd(f"{LIB}/library.tsv")
    c(stat.S_IMODE(os.stat(f"{LIB}/library.tsv").st_mode) == 0o640, "mode")
    c(not [n for n in os.listdir(LIB) if ".tmp-" in n], f"tmp left {os.listdir(LIB)}")
    for bad in ("depot\t9000001\t9000012\t-\t6 4\t-\t0\t-\t-\t900001200\t1", "app\t9000002\tgame\tBad\x01Name",
                "app\t9000002\tgame\t" + "あ" * 86, "owned\tx", "end"):
        try:
            m.unit_library_done(lines + [bad], NOW)
            c(False, f"{bad!r} written")
        except ValueError:
            pass
    c(rd(f"{LIB}/library.tsv") == old, "the old file changed")
    m.LIBRARY_MAX = 10
    try:
        m.unit_library_done(lines, NOW)
        c(False, "an oversize library written")
    except ValueError:
        pass
    finally:
        m.LIBRARY_MAX = 64 << 20
    c(rd(f"{LIB}/library.tsv") == old and not [n for n in os.listdir(LIB) if ".tmp-" in n],
      "the old file changed or a tmp is left after a refusal")
    c(m.lib_line(("app\t9000002\tgame\t" + "あ" * 85 + "a").split("\t")), "a 256 byte name refused")
    write(f"{LIB}/library.tsv", old + "depot\t9000001\t9000012\t-\t-\t-\t2\t-\t-\t900001200\t1\n", 0o640)
    try:
        m.read_library()
        c(False, "a library with a line out of form read")
    except ValueError as err:
        c("out of form" in str(err), f"{err}")


@case("scanfail: owned, network and rate kept with 0, 600, 600; reopened only at a refresh: owned on a licence change, "
      "network and rate after the backoff; doubling to 24 h; a gid change prunes the entry and its .paths.gz, a temp "
      "only once it is older than the run bound")
def _(c):
    setup()
    lines = app("9000001", "Invented") + [dep("9000001", d) for d in ("9000011", "9000012", "9000013")]
    m.unit_library_done(lines, NOW)
    lic = m.licence_hash(m.read_library())
    for d, kind in (("9000011", "owned"), ("9000012", "network"), ("9000013", "rate")):
        m.unit_scan_result(d, gid(d), kind, lic, NOW)

    def state():
        return {d: (e["kind"], e["backoff"], e["open"]) for (d, g), e in m.read_scanfail().items()}
    c(state() == {"9000011": ("owned", 0, False), "9000012": ("network", 600, False), "9000013": ("rate", 600, False)},
      f"{state()}")
    c(stat.S_IMODE(os.stat(f"{LIB}/scanfail.tsv").st_mode) == 0o640, "mode")
    rows = m.read_scanfail()
    c(all(m.scanfail_skip(rows, d, gid(d)) for d in ("9000011", "9000012", "9000013")), "a recorded pair not skipped")
    c(not m.scanfail_skip(rows, "9000011", "900001199"), "another gid skipped")
    m.unit_library_done(lines, NOW + 599)
    c(all(not v[2] for v in state().values()), f"opened inside the backoff {state()}")
    m.unit_library_done(lines, NOW + 600)
    c(state() == {"9000011": ("owned", 0, False), "9000012": ("network", 600, True), "9000013": ("rate", 600, True)},
      f"{state()}")
    m.unit_scan_result("9000012", gid("9000012"), "network", lic, NOW + 700)
    c(state()["9000012"] == ("network", 1200, False), f"{state()}")
    for i in range(9):
        m.unit_scan_result("9000012", gid("9000012"), "network", lic, NOW + 800 + i)
    c(state()["9000012"] == ("network", 86400, False), f"cap {state()}")
    m.unit_scan_result("9000013", gid("9000013"), "network", lic, NOW + 900)
    c(state()["9000013"] == ("network", 600, False), f"a new kind starts at 600 {state()}")
    m.unit_library_done(lines + ["owned\t9000099"], NOW + 900)
    c(state()["9000011"] == ("owned", 0, True), f"a licence change did not reopen owned {state()}")
    m.unit_scan_result("9000011", gid("9000011"), None, lic, NOW + 901)
    c("9000011" not in state(), "a scanned pair kept its entry")
    m.unit_scan_result("9000011", gid("9000011"), "rate", lic, NOW + 902)
    scan("9000011", ["a"])
    scan("9000012", ["b"])
    write(f"{LIB}/scan/9000012_900001200.paths.gz.tmp-1", b"x", 0o640)
    os.utime(f"{LIB}/scan/9000012_900001200.paths.gz.tmp-1", (NOW + 903 - 7 * 3600,) * 2)
    write(f"{LIB}/scan/9000012_900001200.paths.gz.tmp-2", b"x", 0o640)
    os.utime(f"{LIB}/scan/9000012_900001200.paths.gz.tmp-2", (NOW + 903 - 60,) * 2)
    moved = [dep("9000001", "9000011", g="900001199")] + [dep("9000001", d) for d in ("9000012", "9000013")]
    m.unit_library_done(app("9000001", "Invented") + moved, NOW + 903)
    c("9000011" not in state() and "9000012" in state(), f"{state()}")
    c(sorted(os.listdir(f"{LIB}/scan")) == ["9000012_900001200.paths.gz", "9000012_900001200.paths.gz.tmp-2"],
      f"scan dir {os.listdir(f'{LIB}/scan')}")
    m.unit_scan_result("9000013", gid("9000013"), "rate", lic, NOW + 5000)
    m.unit_library_done(app("9000001", "Invented") + moved, NOW)
    c(state()["9000013"][2], "a clock set back left the pair closed")


@case("scan cache: a cut .paths.gz, a bad line and a missing file read as absent; a written one reads back")
def _(c):
    setup()
    scan("9000011", ["Game.exe", "js/rmmz_core.js"])
    c(m.read_paths("9000011", gid("9000011")) == [("Game.exe", 1), ("js/rmmz_core.js", 1)], "read back")
    c(stat.S_IMODE(os.stat(m.paths_file("9000011", gid("9000011"))).st_mode) == 0o640, "mode")
    p = m.paths_file("9000011", gid("9000011"))
    data = open(p, "rb").read()
    write(p, data[:-4], 0o640)
    c(m.read_paths("9000011", gid("9000011")) is None, "a cut file read")
    write(p, gzip.compress(b"1\t../x\n"), 0o640)
    c(m.read_paths("9000011", gid("9000011")) is None, "a .. name read")
    c(m.read_paths("9000012", gid("9000012")) is None, "a missing file read")


def bound(op, now):
    return m.login_bound(m.read_logins(), op, now)


@case("logins: library refused within 10 min of the last library start, counted from the start, a stopped one "
      "included; other operations not bound by it; the refusal is fail bound before any row is written")
def _(c):
    setup()
    c(m.unit_login("library", NOW) == NOW, "start")
    m.unit_login_end("library", NOW, "ok", NOW + 590)
    c(bound("library", NOW + 599) and not bound("library", NOW + 600), "not counted from the start")
    c(not bound("scan", NOW + 1) and not bound("pass", NOW + 1) and not bound("get", NOW + 1), "others bound")
    n = len(m.read_logins())
    try:
        m.unit_login("library", NOW + 10)
        c(False, "a library login inside the bound")
    except m.Fail as err:
        c(err.why == "bound" and len(m.read_logins()) == n, f"{err.why} rows {len(m.read_logins())}")
    m.unit_login("library", NOW + 600)
    c(bound("library", NOW + 1199) and not bound("library", NOW + 1200), "a stopped library run did not count")
    c(stat.S_IMODE(os.stat(f"{LIB}/logins.tsv").st_mode) == 0o640 and
      stat.S_IMODE(os.stat(f"{LIB}/lock").st_mode) == 0o600, "modes")
    for i in range(70):
        m.unit_login("get", NOW + 2000 + i)
    c(len(m.read_logins()) == 64, f"rows kept {len(m.read_logins())}")


@case("logins: a rate result refuses every operation for its backoff, a network result refuses library and scan "
      "only, both doubling from 10 min to 24 h, a success resets")
def _(c):
    setup()
    s = m.unit_login("pass", NOW)
    m.unit_login_end("pass", s, "rate", NOW)
    r = m.read_logins()[-1]
    c((r["result"], r["backoff"]) == ("rate", 600), f"{r}")
    c(all(bound(op, NOW + 599) for op in ("library", "scan", "pass", "get")), "rate did not bind every operation")
    c(not any(bound(op, NOW + 600) for op in ("library", "scan", "pass", "get")), "rate bound past its backoff")
    t = NOW + 600
    for want in (1200, 2400, 4800, 9600, 19200, 38400, 76800, 86400, 86400):
        s = m.unit_login("get", t)
        m.unit_login_end("get", s, "rate", t)
        r = m.read_logins()[-1]
        c(r["backoff"] == want, f"backoff {r['backoff']}, want {want}")
        t += r["backoff"]
    s = m.unit_login("pass", t)
    m.unit_login_end("pass", s, "ok", t)
    s = m.unit_login("scan", t + 1)
    m.unit_login_end("scan", s, "network", t + 1)
    r = m.read_logins()[-1]
    c((r["result"], r["backoff"]) == ("network", 600), f"after a success {r}")
    c(bound("library", t + 100) and bound("scan", t + 100) and not bound("pass", t + 100) and not bound("get", t + 100),
      "network bounds")
    s = m.unit_login("scan", t + 601)
    m.unit_login_end("scan", s, "network", t + 601)
    c(m.read_logins()[-1]["backoff"] == 1200, f"{m.read_logins()[-1]}")


@case("logins: a backoff runs from the failure, not the login's start; a failure more than 24 h after the last "
      "backoff ended restarts at 10 min, one at 24 h still doubles")
def _(c):
    setup()
    s = m.unit_login("get", NOW)
    m.unit_login_end("get", s, "rate", NOW + 1000)
    c(bound("pass", NOW + 1599) and not bound("pass", NOW + 1600), "the rate backoff did not start at the failure")
    s = m.unit_login("scan", NOW + 2000)
    m.unit_login_end("scan", s, "network", NOW + 3000)
    c(bound("library", NOW + 3599) and not bound("library", NOW + 3600), "the network backoff did not start at the end")
    setup()
    s = m.unit_login("get", NOW)
    m.unit_login_end("get", s, "rate", NOW)
    t = NOW + 600 + 86400
    s = m.unit_login("get", t)
    m.unit_login_end("get", s, "rate", t)
    c(m.read_logins()[-1]["backoff"] == 1200, f"24 h after the end {m.read_logins()[-1]}")
    t += 1200 + 86400 + 1
    s = m.unit_login("get", t)
    m.unit_login_end("get", s, "rate", t)
    c(m.read_logins()[-1]["backoff"] == 600, f"past 24 h after the end {m.read_logins()[-1]}")


@case("dlcdrop.tsv: a dropped depot is active while the licence set is the same, gone after it changes")
def _(c):
    setup()
    la, lb = "a" * 64, "b" * 64
    m.dlcdrop_add("9000040", "9000042", la)
    c(m.dlcdrop_active("9000040", la) == {"9000042"} and m.dlcdrop_active("9000040", lb) == set(),
      f"{m.read_dlcdrop()}")
    c(m.dlcdrop_active("9000041", la) == set(), "another app")
    m.dlcdrop_add("9000040", "9000044", lb)
    c(m.read_dlcdrop() == [("9000040", "9000044", lb)], f"{m.read_dlcdrop()}")
    c(stat.S_IMODE(os.stat(f"{GS}/dlcdrop.tsv").st_mode) == 0o644, "mode")


def e2e(world=None, signed=True):
    for p in (SRUN, f"{T}/units"):
        if os.path.lexists(p):
            shutil.rmtree(p)
    for p in (DDLOG, f"{T}/dd-library.count", f"{T}/dd-scan.count", f"{T}/dd-pass.count", f"{T}/dd-get.count",
              f"{T}/curl.log", f"{T}/unit.log", f"{T}/systemctl.log", f"{T}/inhibit.log"):
        if os.path.lexists(p):
            os.unlink(p)
    for d in (f"{SRUN}/req", SDIR, f"{DATA}/cache/ports-tmp", f"{T}/units"):
        os.makedirs(d, exist_ok=True)
    write(f"{T}/nm", "wifi:connected\n")
    write(f"{T}/curl.json", "{}")
    write(DDJSON, json.dumps(world or {}))
    if signed:
        key, val = b"invented-account", b"tok-invented-0000"
        entry = b"\x0a" + bytes([len(key)]) + key + b"\x12" + bytes([len(val)]) + val
        z = zlib.compressobj(wbits=-15)
        write(f"{SDIR}/account.config", z.compress(b"\x22" + bytes([len(entry)]) + entry) + z.flush(), 0o600)


def dd_runs(op=None):
    try:
        rows = [json.loads(x) for x in rd(DDLOG).splitlines()]
    except FileNotFoundError:
        return []
    return [r for r in rows if op is None or r["op"] == op]


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


@contextlib.contextmanager
def wire():
    got = []
    real = os.read

    def rec(fd, n):
        data = real(fd, n)
        with contextlib.suppress(OSError):
            if os.readlink(f"/proc/self/fd/{fd}").endswith(".fifo"):
                got.append(data)
        return data
    os.read = rec
    try:
        yield got
    finally:
        os.read = real


def kinds(got):
    return {x.split("\t")[0] for x in b"".join(got).decode("utf-8", "replace").splitlines() if x}


def unit_run(req, before=None):
    with contextlib.suppress(FileNotFoundError):
        os.unlink(f"{SRUN}/lib.fifo")
    write(f"{SRUN}/req/lib", json.dumps(req), 0o640)
    p = subprocess.Popen([BIN, "steam-unit", "lib"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    end = time.monotonic() + 10
    while True:
        try:
            fd = os.open(f"{SRUN}/lib.fifo", os.O_RDONLY | os.O_NONBLOCK)
            break
        except FileNotFoundError:
            if time.monotonic() > end or p.poll() is not None:
                return p.wait(timeout=30), []
            time.sleep(0.02)
    if before is not None:
        before(fd, p)
    data, connected = b"", False
    while True:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            connected = True
            time.sleep(0.02)
            continue
        if chunk:
            connected = True
            data += chunk
        elif connected or p.poll() is not None:
            break
        else:
            time.sleep(0.02)
    os.close(fd)
    return p.wait(timeout=30), data.decode().splitlines()


def lib_world():
    return (app("9000001", "Invented MZ") + [dep("9000001", "9000011"), "art\t9000001\tinvented/library_600x900.jpg"]
            + app("9000002", "Invented Two") + [dep("9000002", "9000021", oslist="windows"),
                                                 dep("9000002", "9000022", oslist="linux")]
            + app("9000003", "Invented Cached") + [dep("9000003", "9000031")]
            + app("9000004", "Invented Failed") + [dep("9000004", "9000041")]
            + app("9000005", "Invented Unowned") + [dep("9000005", "9000051")]
            + app("9000006", "Invented Bad Name") + [dep("9000006", "9000061")]
            + app("9000007", "Invented DLC", kind="dlc") + [dep("9000007", "9000071")])


@case("steam-lib refresh: the unit keeps app, owned, lang, depot and art lines, forwards only end and rc, writes "
      "library.tsv 0640 on end; no -qr; a library login row ok; the index runs after")
def _(c):
    setup()
    lines = lib_world()
    e2e({"lines": lines})
    with wire() as got:
        rc, out = call("steam-lib", "refresh")
    c(rc == 0 and out == ["done\trefresh"], f"{rc} {out} {LOG[-4:]}")
    c(kinds(got) <= {"end", "rc"} and "end" in kinds(got), f"forwarded {kinds(got)}")
    c(rd(f"{LIB}/library.tsv").splitlines() == lines, "library.tsv is not the kept lines")
    c(stat.S_IMODE(os.stat(f"{LIB}/library.tsv").st_mode) == 0o640, "mode")
    runs = dd_runs()
    c(len(runs) == 1 and runs[0]["args"] == ["-blockie-library", "-remember-password"], f"runs {runs}")
    r = m.read_logins()[-1]
    c((r["op"], r["result"], r["backoff"]) == ("library", "ok", 0), f"{r}")
    c(m.read_library()["apps"]["9000001"]["art"] == "invented/library_600x900.jpg", "art path")
    c(games()[:2] == ["signed\t1", "scan\t0\t6"], f"index {games()[:2]}")


@case("steam-lib refresh: no end, a line out of form and a qr line keep library.tsv whole and end other; fail network "
      "is network with a 10 min backoff; inside 10 min of a library start it is fail bound with no run")
def _(c):
    setup()
    lines = lib_world()
    e2e({"lines": lines})
    call("steam-lib", "refresh")
    old = rd(f"{LIB}/library.tsv")
    for step in ({"noend": True}, {"extra": ["depot\tx"]}, {"extra": ["qr\thttps://s.team/q/1/1"]}):
        os.unlink(f"{LIB}/logins.tsv")
        write(DDJSON, json.dumps({"lines": lines + [dep("9000001", "9000012")], "library": [step]}))
        rc, out = call("steam-lib", "refresh")
        c(out == ["fail\trefresh\tother"] and rd(f"{LIB}/library.tsv") == old, f"{step}: {out}")
    os.unlink(f"{LIB}/logins.tsv")
    write(DDJSON, json.dumps({"library": [{"fail": "network"}]}))
    rc, out = call("steam-lib", "refresh")
    r = m.read_logins()[-1]
    c(out == ["fail\trefresh\tnetwork"] and (r["result"], r["backoff"]) == ("network", 600), f"{out} {r}")
    os.unlink(f"{LIB}/logins.tsv")
    write(DDJSON, json.dumps({"lines": lines}))
    call("steam-lib", "refresh")
    n = len(dd_runs("library"))
    rc, out = call("steam-lib", "refresh")
    c(out == ["fail\trefresh\tbound"] and len(dd_runs("library")) == n, f"{out} runs {len(dd_runs('library'))}")


@case("background commands: refresh, scan and art fail busy with an active scope and network offline, start no unit; "
      "with no token refresh ends fail login, signed 0, no qr, no -qr")
def _(c):
    setup()
    e2e({"lines": lib_world()})
    write(f"{T}/scope-rc", "0\n")
    for w in ("refresh", "scan", "art"):
        rc, out = call("steam-lib", w)
        c(out == [f"fail\t{w}\tbusy"], f"{w}: {out}")
    write(f"{T}/scope-rc", "3\n")
    write(f"{T}/nm", "wifi:disconnected\n")
    for w in ("refresh", "scan", "art"):
        rc, out = call("steam-lib", w)
        c(out == [f"fail\t{w}\tnetwork"], f"{w}: {out}")
    c(not dd_runs() and not os.path.exists(f"{T}/systemctl.log"), "a unit was started")
    setup()
    e2e({"lines": lib_world()}, signed=False)
    rc, out = call("steam-lib", "refresh")
    c(out == ["fail\trefresh\tlogin"] and not any(x.startswith("qr") for x in out), f"{out}")
    c("-qr" not in dd_runs()[0]["args"] and games()[0] == "signed\t0", f"{dd_runs()} {games()[:1]}")


def scan_ready(c, scans):
    setup()
    e2e({"lines": lib_world(), "scans": scans})
    call("steam-lib", "refresh")
    lib = m.read_library()
    scan("9000031", ["Invented.exe"])
    m.unit_scan_result("9000041", gid("9000041"), "owned", m.licence_hash(lib), NOW)
    call("steam-lib", "index")
    c(games()[1] == "scan\t2\t6", f"before {games()[:2]}")


@case("steam-lib scan: the request names apps only, the unit derives pairs per OS from library.tsv, skips cached and "
      "recorded pairs, caches after scanned, records owned and other, forwards scan, scanned and scanfail but no "
      "path line; progress scan per app; a second scan has nothing to run")
def _(c):
    scan_ready(c, {"9000011": {"paths": MZ}, "9000021": {"paths": ["Invented.exe", "data.win"]},
                   "9000022": {"paths": ["Invented", "assets/game.unx"]}, "9000051": {"fail": "owned"},
                   "9000061": {"fail": "other"}})
    with wire() as got:
        rc, out = call("steam-lib", "scan")
    c(rc == 0 and out == [f"progress\tscan\t{n}\t6" for n in range(2, 7)] + ["done\tscan"], f"{out} {LOG[-3:]}")
    c(kinds(got) <= {"scan", "scanned", "scanfail", "end", "rc"} and "path" not in kinds(got), f"{kinds(got)}")
    runs = dd_runs("scan")
    want = [f"9000001\t9000011\t{gid('9000011')}", f"9000002\t9000021\t{gid('9000021')}",
            f"9000002\t9000022\t{gid('9000022')}", f"9000005\t9000051\t{gid('9000051')}",
            f"9000006\t9000061\t{gid('9000061')}"]
    c(len(runs) == 1 and runs[0]["filelist"] == want and runs[0]["args"][0] == "-blockie-scan"
      and runs[0]["args"][-1] == "-remember-password", f"{runs}")
    c(m.read_paths("9000011", gid("9000011")) == [(x, 1) for x in MZ], "9000011 not cached")
    c(m.read_paths("9000022", gid("9000022")) == [("Invented", 1), ("assets/game.unx", 1)], "9000022 not cached")
    failed = {d: e["kind"] for (d, g), e in m.read_scanfail().items()}
    c(failed == {"9000041": "owned", "9000051": "owned", "9000061": "other"}, f"{failed}")
    r = m.read_logins()[-1]
    c((r["op"], r["result"]) == ("scan", "ok"), f"{r}")
    c(games()[1] == "scan\t6\t6", f"after {games()[:2]}")
    rc, out = call("steam-lib", "scan")
    c(out == ["done\tscan"] and len(dd_runs("scan")) == 1, f"{out} {len(dd_runs('scan'))}")


@case("steam-lib scan: a rate scanfail stops the batch and writes a rate login row; login_bound with that row refuses "
      "the operations pass and get; the next scan is fail bound")
def _(c):
    scan_ready(c, {"9000011": {"fail": "rate"}})
    rc, out = call("steam-lib", "scan")
    c(out[-1] == "done\tscan", f"{out}")
    failed = {d: e["kind"] for (d, g), e in m.read_scanfail().items()}
    c(failed == {"9000041": "owned", "9000011": "rate"}, f"{failed}")
    r = m.read_logins()[-1]
    now = int(time.time())
    c(r["result"] == "rate" and m.login_bound(m.read_logins(), "pass", now) and
      m.login_bound(m.read_logins(), "get", now), f"{r}")
    rc, out = call("steam-lib", "scan")
    c(out[-1:] == ["fail\tscan\tbound"] and len(dd_runs("scan")) == 1, f"{out}")


@case("steam-lib scan: a 2 or 4 field path line, a path outside a scan block and a pair not asked for end other "
      "with nothing cached")
def _(c):
    for step, scans in (({}, {"9000011": {"paths": ["path\t1"]}}), ({}, {"9000011": {"paths": ["path\t1\ta\tb"]}}),
                        ({"extra": ["path\t1\ta"]}, {}), ({"extra": [f"scanned\t9009999\t{gid('9009999')}"]}, {})):
        scan_ready(c, scans)
        write(DDJSON, json.dumps({"lines": lib_world(), "scans": scans, "scan": [step]}))
        rc, out = call("steam-lib", "scan")
        c(out[-1] == "fail\tscan\tother", f"{step} {scans}: {out[-2:]}")
        c(m.read_paths("9000011", gid("9000011")) is None, f"{step} {scans}: cached")


@case("the unit's lib requests: no or bad app ids are fail other, an unknown operation is refused, apps not in the "
      "library end with no login")
def _(c):
    setup()
    e2e({"lines": lib_world()})
    call("steam-lib", "refresh")
    n = len(m.read_logins())
    for req in ({"op": "scan", "port": "lib"}, {"op": "scan", "port": "lib", "apps": ["x"]}):
        rc, lines = unit_run(req)
        c(rc == 1 and lines == ["fail\tother", "rc\t1"], f"{req}: {rc} {lines}")
    rc, lines = unit_run({"op": "nonesuch", "port": "lib"})
    c(rc == 1 and lines == [], f"unknown op {rc} {lines}")
    rc, lines = unit_run({"op": "scan", "port": "lib", "apps": ["9000099"]})
    c(rc == 0 and lines == ["end", "rc\t0"] and not dd_runs("scan") and len(m.read_logins()) == n, f"{rc} {lines}")


@case("the batch timer: with the channel not read, the unit stops DepotDownloader at the bound, then ends the batch "
      "with end and an ok login row")
def _(c):
    setup()
    lines = []
    for i in range(1, 41):
        a = str(9000000 + i)
        lines += app(a, f"Invented {i}") + [dep(a, f"{a}{k}") for k in range(1, 4)]
    e2e({"lines": lines, "scan": [{"delay": 0.5, "hang": 60}]})
    call("steam-lib", "refresh")
    os.environ["BLOCKIE_PORTS_STEAM_SCAN_S"] = "2"
    seen = {}

    def frozen(fd, p):
        fcntl.fcntl(fd, fcntl.F_SETPIPE_SZ, 4096)
        time.sleep(4)
        runs = dd_runs("scan")
        seen["dd"] = runs[0]["pid"] if runs else None
        seen["dd_alive"] = seen["dd"] is not None and alive(seen["dd"])
        seen["unit_alive"] = p.poll() is None
    t0 = time.monotonic()
    rc, out = unit_run({"op": "scan", "port": "lib", "apps": [str(9000000 + i) for i in range(1, 41)]}, frozen)
    c(seen.get("dd") is not None and not seen["dd_alive"] and seen["unit_alive"], f"{seen}")
    c(rc == 0 and out[-2:] == ["end", "rc\t0"] and time.monotonic() - t0 < 30, f"{rc} {out[-2:]}")
    r = m.read_logins()[-1]
    c((r["op"], r["result"]) == ("scan", "ok"), f"{r}")


def art_lib(n, path="invented/library_600x900.jpg"):
    lines = []
    for i in range(1, n + 1):
        a = str(9000000 + i)
        lines += app(a, f"Invented {i}") + [dep(a, f"{a}1"), f"art\t{a}\t{path}"]
    return lines


@case("steam-lib art: one try per listed app with no art, at most 50 a run, the URL from the art path, a failure or "
      "a non JPEG kept in art.tsv and tried again only after its library row changes, none with an active scope")
def _(c):
    setup()
    e2e()
    lines = art_lib(52)
    m.unit_library_done(lines, NOW)
    write(f"{GS}/library.tsv", "signed\t1\nscan\t52\t52\n" + "".join(
        f"app\t{9000000 + i}\tInvented {i}\trmmz\t-\t-\t100\tget\t-\n" for i in range(1, 53)))
    write(f"{T}/curl.json", json.dumps({"9000001": "ok", "9000002": "html"}))
    rc, out = call("steam-lib", "art")
    urls = rd(f"{T}/curl.log").splitlines()
    c(rc == 0 and out == ["done\tart"] and len(urls) == 50, f"{out} {len(urls)}")
    c(urls[0] == "https://shared.steamstatic.com/store_item_assets/steam/apps/9000001/invented/library_600x900.jpg",
      f"{urls[:1]}")
    jpg = f"{GS}/art/9000001.jpg"
    c(os.path.isfile(jpg) and open(jpg, "rb").read(3) == b"\xff\xd8\xff" and
      stat.S_IMODE(os.stat(jpg).st_mode) == 0o644, "art not placed")
    c(not os.path.exists(f"{GS}/art/9000002.jpg") and len(rd(f"{GS}/art.tsv").splitlines()) == 49, "failures")
    c(not [n for n in os.listdir(f"{GS}/art") if ".tmp-" in n], "a temp left")
    call("steam-lib", "art")
    c(len(rd(f"{T}/curl.log").splitlines()) == 52 and len(rd(f"{GS}/art.tsv").splitlines()) == 51, "second run")
    call("steam-lib", "art")
    c(len(rd(f"{T}/curl.log").splitlines()) == 52, "a failure tried again with the same row")
    moved = [x.replace("invented/", "moved/") if x.startswith("art\t9000002\t") else x for x in lines]
    m.unit_library_done(moved, NOW)
    call("steam-lib", "art")
    urls = rd(f"{T}/curl.log").splitlines()
    c(len(urls) == 53 and urls[-1].endswith("/9000002/moved/library_600x900.jpg"), f"{urls[-1:]}")
    c(not any("steamstatic" in x for x in LOG), "a URL in the log")
    write(f"{T}/scope-rc", "0\n")
    rc, out = call("steam-lib", "art")
    c(out == ["fail\tart\tbusy"], f"{out}")


@case("steam-lib scan: a name the unit's rel_ok refuses (..\\x) makes that pair scanfail other with nothing cached and "
      "no path line forwarded; the batch goes on")
def _(c):
    scan_ready(c, {"9000011": {"paths": ["path\t1\t..\\x", "path\t1\tok.bin"]}})
    with wire() as got:
        rc, out = call("steam-lib", "scan")
    c(out[-1] == "done\tscan" and "path" not in kinds(got), f"{out[-2:]} {kinds(got)}")
    failed = {d: e["kind"] for (d, g), e in m.read_scanfail().items()}
    c(failed.get("9000011") == "other" and m.read_paths("9000011", gid("9000011")) is None, f"{failed}")
    c(m.read_paths("9000021", gid("9000021")) is not None, "the batch stopped at the refused name")


@case("the batch timer with a pair in flight: the first unreported pair is recorded network, the login row is network "
      "when no pair was reported, and the next batch starts at the second pair")
def _(c):
    scan_ready(c, {})
    write(DDJSON, json.dumps({"lines": lib_world(), "scan": [{"stall_first": 30}]}))
    os.environ["BLOCKIE_PORTS_STEAM_SCAN_S"] = "2"
    t0 = time.monotonic()
    rc, out = call("steam-lib", "scan")
    c(out[-1] == "done\tscan" and time.monotonic() - t0 < 20, f"{out[-2:]}")
    failed = {d: e["kind"] for (d, g), e in m.read_scanfail().items()}
    c(failed.get("9000011") == "network" and m.read_logins()[-1]["result"] == "network",
      f"{failed} {m.read_logins()[-1:]}")
    os.unlink(f"{LIB}/logins.tsv")
    call("steam-lib", "scan")
    runs = dd_runs("scan")
    c(len(runs) == 2 and runs[1]["filelist"][0] == f"9000002\t9000021\t{gid('9000021')}", f"{runs[-1:]}")


@case("steam-lib scan picks apps by list existence, then a full read when the index still counts apps pending: the "
      "unit deletes a cut list and scans it again")
def _(c):
    setup()
    e2e({"lines": lib_world()})
    call("steam-lib", "refresh")
    for d in ("9000011", "9000021", "9000022", "9000031", "9000041", "9000051", "9000061"):
        scan(d, ["Invented.exe"])
    p = m.paths_file("9000011", gid("9000011"))
    data = open(p, "rb").read()
    write(p, data[:len(data) // 2], 0o640)
    call("steam-lib", "index")
    c(games()[1] == "scan\t5\t6", f"{games()[:2]}")
    rc, out = call("steam-lib", "scan")
    runs = dd_runs("scan")
    c(rc == 0 and len(runs) == 1 and runs[0]["filelist"] == [f"9000001\t9000011\t{gid('9000011')}"], f"{out} {runs}")
    c(m.read_paths("9000011", gid("9000011")) == [("invented.bin", 1)] and games()[1] == "scan\t6\t6",
      f"{games()[:2]}")


@case("scan cache: names holding U+0085, U+2028 and U+2029 read back as one line each")
def _(c):
    setup()
    names = ["a\u0085b.exe", "c\u2028d.dat", "e\u2029f.txt"]
    scan("9000011", names)
    c(m.read_paths("9000011", gid("9000011")) == [(n, 1) for n in names], f"{m.read_paths('9000011', gid('9000011'))}")


@case("steam-lib refresh: a library silent past the helper's stall bound still ends; the unit's library bound stops a "
      "hung one as fail refresh network with a network login row and library.tsv kept")
def _(c):
    setup()
    lines = lib_world()
    e2e({"lines": lines, "library": [{"loop": 2}]})
    m.STALL_S = 1
    m.LIBRARY_RUN_S = 4
    os.environ["BLOCKIE_PORTS_STEAM_LIBRARY_S"] = "4"
    rc, out = call("steam-lib", "refresh")
    c(out == ["done\trefresh"] and rd(f"{LIB}/library.tsv").splitlines() == lines, f"{out}")
    old = rd(f"{LIB}/library.tsv")
    os.unlink(f"{LIB}/logins.tsv")
    write(DDJSON, json.dumps({"lines": lines + [dep("9000001", "9000012")], "library": [{"loop": 30}]}))
    os.environ["BLOCKIE_PORTS_STEAM_LIBRARY_S"] = "2"
    t0 = time.monotonic()
    rc, out = call("steam-lib", "refresh")
    r = m.read_logins()[-1]
    c(out == ["fail\trefresh\tnetwork"] and time.monotonic() - t0 < 20, f"{out}")
    c(r["result"] == "network" and rd(f"{LIB}/library.tsv") == old, f"{r}")


@case("steam-lib art: a stop during a fetch kills curl and ends fail art cancel with no temp left")
def _(c):
    setup()
    e2e()
    m.unit_library_done(art_lib(2), NOW)
    write(f"{GS}/library.tsv", "signed\t1\nscan\t2\t2\n" + "".join(
        f"app\t{9000000 + i}\tInvented {i}\trmmz\t-\t-\t100\tget\t-\n" for i in (1, 2)))
    write(f"{T}/curl.json", json.dumps({"9000001": "hang"}))
    stop = threading.Timer(0.5, lambda: m.CANCEL.__setitem__(0, True))
    t0 = time.monotonic()
    stop.start()
    rc, out = call("steam-lib", "art")
    c(out == ["fail\tart\tcancel"] and time.monotonic() - t0 < 10, f"{out}")
    pid = int(rd(f"{T}/curl.pid")) if os.path.exists(f"{T}/curl.pid") else None
    c(pid is not None and not alive(pid), f"curl {pid} alive")
    c(not [n for n in os.listdir(f"{GS}/art") if ".tmp-" in n], "a temp left")


@case("logins: network rows of port gets leave library and scan free, a rate get row binds every operation")
def _(c):
    setup()
    t = NOW
    for _ in range(3):
        s = m.unit_login("get", t)
        m.unit_login_end("get", s, "network", t)
        t += 1
    c(not any(bound(op, t) for op in ("library", "scan", "pass", "get")), "a get network row bound an operation")
    s = m.unit_login("get", t)
    m.unit_login_end("get", s, "rate", t)
    c(all(bound(op, t + 1) for op in ("library", "scan", "pass", "get")), "a get rate row left an operation free")


@case("steam-lib refresh: a fail rate from DepotDownloader ends at once as fail refresh network with a rate login row")
def _(c):
    setup()
    e2e({"lines": lib_world(), "library": [{"fail": "rate"}]})
    t0 = time.monotonic()
    rc, out = call("steam-lib", "refresh")
    r = m.read_logins()[-1]
    c(out == ["fail\trefresh\tnetwork"] and time.monotonic() - t0 < 10, f"{out}")
    c((r["op"], r["result"], r["backoff"]) == ("library", "rate", 600), f"{r}")


@case("the library run: an end with rc 0 is written even when the bound fires after DepotDownloader exited")
def _(c):
    setup()
    lines = lib_world()
    e2e({"lines": lines})
    os.makedirs(f"{SDIR}/home", exist_ok=True)

    class Late:
        def __init__(self, interval, fn):
            self.fn = fn

        def start(self):
            pass

        def cancel(self):
            self.fn()
    real = m.threading
    m.threading = type("Threading", (), {"Timer": Late})
    r, w = os.pipe()
    try:
        rc, result = m.unit_lib_run(w, "library", None, None)
    finally:
        m.threading = real
        os.close(w)
    with os.fdopen(r) as f:
        sent = f.read().splitlines()
    c((rc, result) == (0, "ok") and sent == ["end"], f"{rc} {result} {sent}")
    c(rd(f"{LIB}/library.tsv").splitlines() == lines, "library.tsv not written")


@case("a scan killed as bad records the first unreported pair network, so the next batch starts at the second pair")
def _(c):
    scan_ready(c, {"9000011": {"paths": ["path\t1"]}})
    rc, out = call("steam-lib", "scan")
    failed = {d: e["kind"] for (d, g), e in m.read_scanfail().items()}
    c(out[-1] == "fail\tscan\tother" and failed.get("9000011") == "network", f"{out[-2:]} {failed}")
    call("steam-lib", "scan")
    runs = dd_runs("scan")
    c(len(runs) == 2 and runs[1]["filelist"][0] == f"9000002\t9000021\t{gid('9000021')}", f"{runs[-1:]}")


@case("library lines: art is three fields with a relative path; a .. path, an absolute one or a fourth field is out "
      "of form")
def _(c):
    c(m.lib_line(["art", "9000001", "a1b2/library_600x900.jpg"]) and m.lib_line(["art", "9000001", "x.jpg"]), "good")
    for bad in (["art", "9000001", "../x.jpg"], ["art", "9000001", "/x.jpg"], ["art", "9000001", "a/./x.jpg"],
                ["art", "9000001", "x.jpg", "y"], ["art", "x", "x.jpg"], ["art", "9000001", "a b.jpg"]):
        c(not m.lib_line(bad), f"{bad} accepted")


GET = {"Game.exe": "invented exe", "package.json": "{}", "index.html": "<html></html>", "js/rmmz_core.js": "core",
       "js/main.js": "main", "img/titles1/a.png": "png", "lang/en.json": "en", "lang/en2.json": "en two",
       "dlc/a.png": "dlc a", "dlc/b.png": "dlc b"}
GET_DEPOTS = ("9002011", "9002012", "9002013", "9002014", "9002015", "9002016")
ENGLISH = ["9002011", "9002012", "9002014", "9002015"]


def sha1(text):
    return hashlib.sha1(text.encode()).hexdigest()


def get_lib(extra=(), g11=None):
    return (app("9000201", "Invented Get", langs="english,japanese")
            + [dep("9000201", "9002011", oslist="windows", g=g11), dep("9000201", "9002012", oslist="windows",
                                                                      lang="english"),
               dep("9000201", "9002013", oslist="windows", lang="japanese"), dep("9000201", "9002014", dlc="9002019"),
               dep("9000201", "9002015", dlc="9002018"), "owned\t9002019", "owned\t9002018"] + list(extra))


def get_ready(files=None, world=None):
    setup()
    lines = get_lib()
    w = {"lines": lines, "files": {p: {"data": v} for p, v in (files or GET).items()},
         "public": {d: [gid(d)] for d in GET_DEPOTS}}
    w.update(world or {})
    e2e(w)
    write(f"{DL}/signed", "signed 1\n")
    m.unit_library_done(lines, NOW)
    scan("9002011", list(MZ))
    for d in GET_DEPOTS[1:]:
        scan(d, [f"x{d}.dat"])
    write(f"{USR}/runners.d/test.conf", "CLASSES=rmmz:windows\n")
    call("steam-lib", "index")


def dargs(r):
    a = r["args"]
    i = a.index("-depot") + 1
    out = []
    while i < len(a) and not a[i].startswith("-"):
        out.append(a[i])
        i += 1
    return out


def state():
    rows = [x.split("\t") for x in games() if x.startswith("app\t9000201\t")]
    return rows[0][7] if rows else None


def digest(choice):
    return hashlib.sha256(f"9000201\twindows\t-\t{choice}\tsteam-games/9000201".encode()).hexdigest()


@case("steam-lib get: the app row from library.tsv, depots neutral, language, DLC in that order, no -qr; the files "
      "under steam-games/<app>; .got with the digest, each depot's gid, the class, root and size and SHA1 per path; "
      "pass and get login rows; the list reads got; a missing or bad app id")
def _(c):
    get_ready()
    c(games()[2:] == ["app\t9000201\tInvented Get\trmmz\tenglish\tenglish,japanese\t400\tget\t-"], f"{games()}")
    rc, out = call("steam-lib", "get", "9000201")
    c(rc == 0 and out[-1] == "done\t9000201", f"{rc} {out[-3:]} {LOG[-4:]}")
    runs = dd_runs()
    c([r["op"] for r in runs] == ["pass", "get"], f"{[r['op'] for r in runs]}")
    c(runs[0]["args"][:4] == ["-app", "9000201", "-os", "windows"] and dargs(runs[0]) == ENGLISH and
      "-qr" not in runs[0]["args"] and "-manifest" not in runs[0]["args"], f"{runs[0]['args']}")
    for p, v in GET.items():
        f = f"{GAMES}/9000201/{p}"
        c(os.path.isfile(f) and rd(f) == v and stat.S_IMODE(os.stat(f).st_mode) == 0o644, f"{p} not placed")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(got["digest"] == digest("english") and got["class"] == "rmmz" and got["os"] == "windows" and got["root"] == "",
      f"{got['digest']} {got['class']} {got['os']} {got['root']!r}")
    c(sorted(map(tuple, got["depots"])) == sorted((d, gid(d)) for d in ENGLISH), f"{got['depots']}")
    c(got["files"]["9000201/js/main.js"] == [4, sha1("main")] and len(got["files"]) == len(GET) and
      sorted(got["placed"]) == sorted(f"9000201/{p}" for p in GET), f"{got['files']}")
    c([(r["op"], r["result"]) for r in m.read_logins()][-2:] == [("pass", "ok"), ("get", "ok")], f"{m.read_logins()}")
    c(state() == "got", f"{games()}")
    c(not os.listdir(f"{GS}/txn") and not [n for n in os.listdir(DL) if n.startswith("app-9000201.")],
      f"{os.listdir(DL)}")
    rc, out = call("steam-lib", "get", "x9000201")
    c(out == ["fail\tx9000201\tother"], f"{out}")
    rc, out = call("steam-lib", "get", "9000299")
    c(out == ["fail\t9000299\tother"], f"{out}")
    with contextlib.redirect_stdout(io.StringIO()):
        c(m.run(["blockie-ports", "steam-lib", "get"], m.Proto(os.open(os.devnull, os.O_WRONLY))) == 64, "no app")


@case("DLC: a DLC depot's fail owned depot reruns the pass once without it, recorded in dlcdrop.tsv and left out of "
      "the next get until the licence set changes")
def _(c):
    get_ready(world={"pass": [{"fail": "owned depot 9002014"}, {}]})
    rc, out = call("steam-lib", "get", "9000201")
    passes = dd_runs("pass")
    c(out[-1] == "done\t9000201" and len(passes) == 2, f"{out[-2:]} {len(passes)} {LOG[-4:]}")
    c(dargs(passes[0]) == ENGLISH and dargs(passes[1]) == ["9002011", "9002012", "9002015"],
      f"{[dargs(r) for r in passes]}")
    lic = m.licence_hash(m.read_library())
    c(m.read_dlcdrop() == [("9000201", "9002014", lic)], f"{m.read_dlcdrop()}")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(sorted(x[0] for x in got["depots"]) == ["9002011", "9002012", "9002015"], f"{got['depots']}")
    c([(r["op"], r["result"]) for r in m.read_logins()][-3:] == [("pass", "owned"), ("pass", "ok"), ("get", "ok")],
      f"{m.read_logins()}")
    c(games()[2].split("\t")[6] == "300" and state() == "got", f"{games()}")
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "done\t9000201" and dargs(dd_runs("pass")[-1]) == ["9002011", "9002012", "9002015"],
      f"{out[-1:]} {dargs(dd_runs('pass')[-1])}")
    m.unit_library_done(get_lib(["owned\t9002017"]), NOW)
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "done\t9000201" and dargs(dd_runs("pass")[-1]) == ENGLISH, f"{dargs(dd_runs('pass')[-1])}")


@case("DLC: a base depot's owned depot, a second owned depot in the rerun and app level owned end owned with no mark; "
      "the rerun inside a rate backoff ends bound with no second DepotDownloader run")
def _(c):
    get_ready(world={"pass": [{"fail": "owned depot 9002011"}]})
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\towned" and len(dd_runs("pass")) == 1 and m.read_dlcdrop() == [],
      f"{out[-1:]} {len(dd_runs('pass'))} {m.read_dlcdrop()}")
    get_ready(world={"pass": [{"fail": "owned depot 9002014"}, {"fail": "owned depot 9002015"}]})
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\towned" and len(dd_runs("pass")) == 2 and
      [r[1] for r in m.read_dlcdrop()] == ["9002014"], f"{out[-1:]} {len(dd_runs('pass'))} {m.read_dlcdrop()}")
    get_ready(world={"pass": [{"fail": "owned"}]})
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\towned" and not os.path.exists(f"{GS}/9000201.owned") and
      not os.path.exists(f"{PORTS}/.blockie/steam/app-9000201.owned"), f"{out[-1:]}")
    get_ready(world={"pass": [{"fail": "owned depot 9002014"}, {}]})
    real = m.steam_dd
    planted = []

    def dd(proto, op, *a, **kw):
        run = real(proto, op, *a, **kw)
        if op == "pass" and not planted:
            now = int(time.time())
            m.unit_login_end("get", m.unit_login("get", now), "rate", now)
            planted.append(now)
        return run
    m.steam_dd = dd
    try:
        rc, out = call("steam-lib", "get", "9000201")
    finally:
        m.steam_dd = real
    c(out[-1] == "fail\t9000201\tbound" and len(dd_runs("pass")) == 1, f"{out[-1:]} {len(dd_runs('pass'))}")


@case("the pass reclass: a pass whose files class an unoffered class ends fail class with no download; an app not "
      "offered from the scan cache ends fail class with no unit started")
def _(c):
    get_ready(files={"Game.exe": "x", "data/a.dat": "y"})
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\tclass" and len(dd_runs("pass")) == 1 and not dd_runs("get") and
      not os.path.exists(f"{GAMES}/9000201/Game.exe"), f"{out[-2:]} {LOG[-3:]}")
    get_ready()
    os.unlink(f"{USR}/runners.d/test.conf")
    rc, out = call("steam-lib", "get", "9000201")
    c(out == ["fail\t9000201\tclass"] and not dd_runs() and not os.path.exists(f"{T}/systemctl.log"), f"{out}")


@case("steam-lib lang: a pick among the choices is kept and the list reads it with get; the next get fetches the "
      "japanese build, deletes the english files it placed that are unchanged and keeps one the game changed; no "
      "unchanged orphan is left")
def _(c):
    get_ready()
    call("steam-lib", "get", "9000201")
    rc, out = call("steam-lib", "lang", "9000201", "klingon")
    c(out == ["fail\t9000201\tother"] and not os.path.exists(f"{GS}/9000201.lang"), f"{out}")
    rc, out = call("steam-lib", "lang", "9000201", "japanese")
    c(rc == 0 and out == ["done\t9000201"] and rd(f"{GS}/9000201.lang") == "japanese\n", f"{out}")
    line = games()[2].split("\t")
    c(line[4] == "japanese" and line[7] == "get", f"{line}")
    write(f"{GAMES}/9000201/lang/en2.json", "changed by the game")
    files = {k: v for k, v in GET.items() if not k.startswith("lang/")}
    files["lang/ja.json"] = "ja"
    w = json.loads(rd(DDJSON))
    w["files"] = {p: {"data": v} for p, v in files.items()}
    write(DDJSON, json.dumps(w))
    old = json.loads(rd(f"{GS}/9000201.got"))
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "done\t9000201" and dargs(dd_runs("pass")[-1]) == ["9002011", "9002013", "9002014", "9002015"],
      f"{out[-1:]} {dargs(dd_runs('pass')[-1])} {LOG[-3:]}")
    c(not os.path.exists(f"{GAMES}/9000201/lang/en.json") and rd(f"{GAMES}/9000201/lang/ja.json") == "ja" and
      rd(f"{GAMES}/9000201/lang/en2.json") == "changed by the game", f"{os.listdir(f'{GAMES}/9000201/lang')}")
    for dst, (size, h) in old["files"].items():
        f = f"{GAMES}/{dst}"
        c(dst.split("/", 1)[1] in files or not os.path.exists(f) or sha1(rd(f)) != h, f"an unchanged orphan {dst}")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(got["digest"] == digest("japanese") and "9000201/lang/en2.json" in got["placed"] and
      "9000201/lang/en.json" not in got["placed"] and "9000201/lang/en.json" not in got["files"], f"{got['placed']}")
    c(state() == "got", f"{games()}")


@case("steam-lib remove: unchanged placed files and their empty dirs go; a planted save, a changed file and the runner "
      "profile dir stay; the list offers get again; a re-get places the files and keeps the save; busy with a scope")
def _(c):
    get_ready()
    call("steam-lib", "get", "9000201")
    base = f"{GAMES}/9000201"
    write(f"{base}/save/file1.rmmzsave", "invented save")
    write(f"{base}/js/main.js", "changed by the game")
    write(f"{base}/.blockie/nw/Local Storage/x", "invented profile")
    rc, out = call("steam-lib", "remove", "9000201")
    c(rc == 0 and out == ["done\t9000201"], f"{out} {LOG[-3:]}")
    c(rd(f"{base}/save/file1.rmmzsave") == "invented save" and rd(f"{base}/js/main.js") == "changed by the game" and
      os.path.isfile(f"{base}/.blockie/nw/Local Storage/x"), "a save, a changed file or the profile went")
    c(not any(os.path.exists(f"{base}/{p}") for p in ("Game.exe", "js/rmmz_core.js", "img", "lang", "dlc")),
      f"{sorted(os.listdir(base))}")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(got == {"digest": "-", "placed": ["9000201/js/main.js"], "files": {"9000201/js/main.js": [4, sha1("main")]}},
      f"{got}")
    c(state() == "get", f"{games()}")
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "done\t9000201" and rd(f"{base}/Game.exe") == GET["Game.exe"] and
      rd(f"{base}/js/main.js") == GET["js/main.js"] and rd(f"{base}/save/file1.rmmzsave") == "invented save",
      f"{out[-1:]} {LOG[-3:]}")
    c(state() == "got", f"{games()}")
    write(f"{T}/scope-rc", "0\n")
    rc, out = call("steam-lib", "remove", "9000201")
    c(out == ["fail\t9000201\tbusy"] and os.path.exists(f"{base}/Game.exe"), f"{out}")


@case("update: a new public gid or a new depot keeps the digest; the list reads got until the new build is scanned and "
      "offered, then update, never get; with no runner conf it stays got; the update get leaves got")
def _(c):
    get_ready()
    call("steam-lib", "get", "9000201")
    m.unit_library_done(get_lib(g11="900201199"), NOW)
    call("steam-lib", "index")
    c(state() == "got", f"an unscanned new gid {games()}")
    scan("9002011", list(MZ), g="900201199")
    call("steam-lib", "index")
    c(state() == "update", f"a scanned new gid {games()}")
    os.unlink(f"{USR}/runners.d/test.conf")
    call("steam-lib", "index")
    c(state() == "got", f"no runner conf {games()}")
    write(f"{USR}/runners.d/test.conf", "CLASSES=rmmz:windows\n")
    m.unit_library_done(get_lib([dep("9000201", "9002016", oslist="windows")]), NOW)
    scan("9002011", list(MZ))
    scan("9002016", ["x9002016.dat"])
    call("steam-lib", "index")
    c(state() == "update", f"a new depot {games()}")
    c(json.loads(rd(f"{GS}/9000201.got"))["digest"] == digest("english"), "digest")
    rc, out = call("steam-lib", "get", "9000201")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(out[-1] == "done\t9000201" and "9002016" in dargs(dd_runs("pass")[-1]) and
      ["9002016", gid("9002016")] in got["depots"] and state() == "got", f"{out[-1:]} {got['depots']} {games()}")


@case("replay of an app journal left mid copy in steam-games/.blockie/txn: the copy done, the unchanged orphan gone, "
      "the changed one kept and listed, the .got keys from the journal, the journal gone; a journal in the wrong root, "
      "an app journal of another op or with an extra install key is dropped untouched")
def _(c):
    setup()
    e2e()
    base = f"{GAMES}/9000201"
    write(f"{base}/lang/en.json", "en")
    write(f"{base}/lang/en2.json", "changed by the game")
    write(f"{DL}/app-9000201.part/lang/ja.json", "ja")
    write(f"{DL}/app-9000201.list",
          f"manifest\t9002013\t{gid('9002013')}\nfile\t{sha1('ja')}\t2\tlang/ja.json\ntotal\t2\n", 0o640)
    keys = {"depots": [["9002013", gid("9002013")]], "class": "rmmz", "os": "windows", "root": ""}
    entry = ["lang/ja.json", "9000201/lang/ja.json", 2, sha1("ja")]
    data = {"op": "steam", "name": "app-9000201", "digest": digest("japanese"), "placed": [entry[1:]],
            "replaced": [], "copies": [entry], "got": keys,
            "orphans": [["9000201/lang/en.json", 2, sha1("en")], ["9000201/lang/en2.json", 6, sha1("en two")]]}
    m.journal("steam-app-9000201", data, m.GAMES_TXN)
    with m.game_lock():
        m.replay()
    c(rd(f"{base}/lang/ja.json") == "ja" and not os.path.exists(f"{base}/lang/en.json") and
      rd(f"{base}/lang/en2.json") == "changed by the game", f"{sorted(os.listdir(f'{base}/lang'))} {LOG[-3:]}")
    got = json.loads(rd(f"{GS}/9000201.got"))
    want = dict(keys, digest=digest("japanese"), placed=["9000201/lang/ja.json", "9000201/lang/en2.json"],
                files={"9000201/lang/ja.json": [2, sha1("ja")], "9000201/lang/en2.json": [6, sha1("en two")]})
    c(got == want, f"{got}")
    c(not os.listdir(m.GAMES_TXN) and not os.path.exists(f"{DL}/app-9000201.part"), f"{os.listdir(m.GAMES_TXN)}")
    before = rd(f"{GS}/9000201.got")
    port = {"op": "steam", "name": "alpha.zip", "digest": "x", "placed": [], "replaced": [], "copies": []}
    for txn, n, d in ((m.GAMES_TXN, "steam-alpha.zip", port),
                      (m.GAMES_TXN, "steam-app-9000202", {"op": "install", "name": "app-9000202",
                                                          "new": [f"{base}/lang/ja.json"]}),
                      (m.GAMES_TXN, "steam-app-9000201", dict(data, got=dict(keys, digest="x"))),
                      (m.TXN, "steam-app-9000201", data)):
        m.journal(n, d, txn)
    LOG.clear()
    with m.game_lock():
        m.replay()
    c(sum("dropped the unreadable journal" in x for x in LOG) == 4 and rd(f"{GS}/9000201.got") == before and
      rd(f"{base}/lang/ja.json") == "ja" and not os.listdir(m.GAMES_TXN) and not os.listdir(m.TXN), f"{LOG}")


@case("the pass note: a pass whose build classes unoffered stops the list offering get after that one pass and the "
      "next get ends class with no unit; a scan of the same gids written after the note replaces it")
def _(c):
    get_ready(files={"Game.exe": "x", "data/a.dat": "y"})
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\tclass" and state() is None, f"{out[-1:]} {games()}")
    note = json.loads(rd(f"{GS}/9000201.pass"))
    pairs = sorted([d, gid(d)] for d in ENGLISH)
    c(note["class"] == "win32" and note["os"] == "windows" and note["pairs"] == pairs and note["lib"] == pairs,
      f"{note}")
    rc, out = call("steam-lib", "get", "9000201")
    c(out == ["fail\t9000201\tclass"] and len(dd_runs("pass")) == 1, f"{out} {len(dd_runs('pass'))}")
    time.sleep(0.05)
    scan("9002011", list(MZ))
    for d in ENGLISH[1:]:
        scan(d, [f"x{d}.dat"])
    call("steam-lib", "index")
    c(state() == "get" and not os.path.exists(f"{GS}/9000201.pass"), f"{games()}")


@case("logins: a network result doubles only from a row of its own class, so an app get's network leaves the next "
      "library network at 600 s and the reverse; a rate result still doubles across classes")
def _(c):
    t = NOW
    for first, then, kind, want in (("get", "library", "network", 600), ("library", "get", "network", 600),
                                    ("get", "library", "rate", 1200), ("scan", "library", "network", 1200)):
        setup()
        m.unit_login_end(first, m.unit_login(first, t), kind, t)
        m.unit_login_end(then, m.unit_login(then, t + 1000), kind, t + 1000)
        r = m.read_logins()[-1]
        c((r["op"], r["result"], r["backoff"]) == (then, kind, want), f"{first} then {then} {kind}: {r}")


@case("the unit floor on an app get: a got line under the floor ends fail space with no game file placed and a space "
      "login row")
def _(c):
    get_ready()
    os.environ["BLOCKIE_PORTS_FLOOR"] = str(1 << 62)
    try:
        rc, out = call("steam-lib", "get", "9000201")
    finally:
        os.environ["BLOCKIE_PORTS_FLOOR"] = "0"
    r = m.read_logins()[-1]
    c(out[-1] == "fail\t9000201\tspace" and not os.path.exists(f"{GAMES}/9000201/Game.exe") and
      (r["op"], r["result"]) == ("get", "space"), f"{out[-1:]} {r}")


@case("steam-lib remove: a unit clean that fails after the files went still runs the index, so the list reads get")
def _(c):
    get_ready()
    call("steam-lib", "get", "9000201")
    write(f"{T}/start-fails", "")
    try:
        rc, out = call("steam-lib", "remove", "9000201")
    finally:
        os.unlink(f"{T}/start-fails")
    c(out == ["fail\t9000201\tother"] and not os.path.exists(f"{GAMES}/9000201/Game.exe") and state() == "get",
      f"{out} {games()}")


@case("the pass note gives way to a correction row and to an engines.tsv change, so the app is offered again; a note "
      "with a class or status out of form, or for an app no longer in the library, is dropped at index")
def _(c):
    for how in ("correction", "engines"):
        get_ready(files={"Game.exe": "x", "data/a.dat": "y"})
        call("steam-lib", "get", "9000201")
        c(state() is None and os.path.exists(f"{GS}/9000201.pass"), f"{how}: before {games()}")
        if how == "correction":
            write(f"{USR}/corrections.tsv", "app\tgid\tclass\n9000201\t-\trmmz:windows\n")
        else:
            write(f"{USR}/engines.tsv", "".join(x + "\n" for x in rd(f"{SHIP}/engines.tsv").splitlines()
                                                if not x.startswith("win32\t")))
        call("steam-lib", "index")
        c(state() == "get" and not os.path.exists(f"{GS}/9000201.pass"), f"{how}: {games()}")
    get_ready()
    note = {"os": "windows", "pairs": sorted([d, gid(d)] for d in ENGLISH), "lib": sorted([d, gid(d)] for d in ENGLISH),
            "class": "win32", "root": "", "status": "-", "table": m.table_hash()}
    for bad in ({"class": "win32\tx"}, {"status": "invented"}, {"root": "../x"}):
        write(f"{GS}/9000201.pass", json.dumps(dict(note, **bad)))
        call("steam-lib", "index")
        c(state() == "get" and not os.path.exists(f"{GS}/9000201.pass"), f"{bad}: {games()}")
    write(f"{GS}/9000999.pass", json.dumps(dict(note)))
    call("steam-lib", "index")
    c(not os.path.exists(f"{GS}/9000999.pass"), "a note for an app outside the library kept")


@case("an app journal whose install keys are out of form is dropped before any copy or source drop")
def _(c):
    setup()
    e2e()
    write(f"{DL}/app-9000201.part/lang/ja.json", "ja")
    write(f"{DL}/app-9000201.list", f"file\t{sha1('ja')}\t2\tlang/ja.json\ntotal\t2\n", 0o640)
    entry = ["lang/ja.json", "9000201/lang/ja.json", 2, sha1("ja")]
    for keys in ({"depots": [], "class": "rmmz", "os": "windows"}, {"depots": [], "class": "rmmz", "os": "windows",
                                                                   "root": "", "digest": "x"}, None):
        m.journal("steam-app-9000201", {"op": "steam", "name": "app-9000201", "digest": "x", "placed": [entry[1:]],
                                        "replaced": [], "copies": [entry], "got": keys, "orphans": []}, m.GAMES_TXN)
        LOG.clear()
        with m.game_lock():
            m.replay()
        c(not os.path.exists(f"{GAMES}/9000201/lang/ja.json") and rd(f"{DL}/app-9000201.part/lang/ja.json") == "ja" and
          not os.path.exists(f"{GS}/9000201.got") and not os.listdir(m.GAMES_TXN) and
          any("dropped the unreadable journal" in x for x in LOG), f"{keys}: {LOG}")


@case("steam-lib commands end by writing steam.tsv with its bound line")
def _(c):
    setup()
    now = int(time.time())
    m.unit_login_end("scan", m.unit_login("scan", now), "rate", now)
    rc, out = call("steam-lib", "index")
    c(rc == 0 and rd(f"{PORTS}/.blockie/steam.tsv").splitlines() == ["signed\t0", f"bound\t{now + 600}"],
      f"{rc} {out} {rd(f'{PORTS}/.blockie/steam.tsv')!r}")


def cancel_at_curl():
    with contextlib.suppress(FileNotFoundError):
        os.unlink(f"{T}/curl.pid")

    def stop():
        end = time.monotonic() + 20
        while not os.path.exists(f"{T}/curl.pid") and time.monotonic() < end:
            time.sleep(0.05)
        m.CANCEL[0] = True
    threading.Thread(target=stop, daemon=True).start()


NWT = [("nwjs-invented", None, 0o755), ("nwjs-invented/nw", b"invented nw\n", 0o755),
       ("nwjs-invented/lib", None, 0o755), ("nwjs-invented/lib/libinvented.so", b"invented lib\n", 0o644),
       ("nwjs-invented/lib/libalias.so", ("sym", "libinvented.so"), 0o777)]
NW_URL = "https://example.invalid/nwjs-invented.tar.gz"


def runner_tar(entries, name="runner.tar.gz"):
    path = f"{T}/{name}"
    with tarfile.open(path, "w:gz") as tf:
        for n, data, mode in entries:
            ti = tarfile.TarInfo(n)
            ti.mode = mode
            if data is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            elif isinstance(data, tuple):
                ti.type = {"sym": tarfile.SYMTYPE, "hard": tarfile.LNKTYPE, "fifo": tarfile.FIFOTYPE,
                           "chr": tarfile.CHRTYPE}[data[0]]
                ti.linkname = data[1] if len(data) > 1 else ""
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    with open(path, "rb") as f:
        raw = f.read()
    return path, hashlib.sha256(raw).hexdigest(), len(raw)


def runner_conf(sha, size, name="nwjs", classes="rmmz:windows", unpacked=25):
    write(f"{USR}/runners.d/{name}.conf", f"CLASSES={classes}\nFILE=nwjs-invented.tar.gz\nURL={NW_URL}\n"
                                          f"SHA256={sha}\nSIZE={size}\nUNPACKED={unpacked}\n")


def serve(how="ok", src=None):
    write(f"{T}/runner.json", json.dumps({"how": how, "src": src}))


def runners():
    try:
        return sorted(os.listdir(f"{DATA}/steam-runners"))
    except FileNotFoundError:
        return []


def curls():
    try:
        return [x for x in rd(f"{T}/curl.log").splitlines() if "/apps/" not in x]
    except FileNotFoundError:
        return []


def nw_ready(files=None):
    get_ready(files=files)
    os.unlink(f"{USR}/runners.d/test.conf")
    path, sha, size = runner_tar(NWT)
    runner_conf(sha, size)
    serve(src=path)
    return sha


@case("steam-lib runner: curl after the floor into steam-runners/.tmp-<pid>, size and sha256 checked, unpacked, "
      "renamed to the sha256's first 16 with its size marker; progress runner from 0 to the size; a second call "
      "fetches nothing; a temp of a gone pid is removed")
def _(c):
    setup()
    e2e()
    path, sha, size = runner_tar(NWT)
    runner_conf(sha, size)
    serve(src=path)
    os.makedirs(f"{DATA}/steam-runners/.tmp-999999999/x")
    rc, out = call("steam-lib", "runner", "nwjs")
    dst = f"{DATA}/steam-runners/{sha[:16]}"
    c(rc == 0 and out[-1] == "done\tnwjs", f"{rc} {out[-3:]} {LOG[-3:]}")
    c(out[0] == f"progress\trunner\t0\t{size}" and f"progress\trunner\t{size}\t{size}" in out, f"{out}")
    c(rd(f"{dst}/nw") == "invented nw\n" and stat.S_IMODE(os.stat(f"{dst}/nw").st_mode) == 0o755 and
      os.readlink(f"{dst}/lib/libalias.so") == "libinvented.so", f"{sorted(os.listdir(dst))}")
    c(rd(f"{dst}/.blockie-size") == "25 2\n" and runners() == [sha[:16]] and curls() == [NW_URL],
      f"{runners()} {curls()}")
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out == ["done\tnwjs"] and curls() == [NW_URL], f"{out} {curls()}")


@case("steam-lib runner: a wrong sha256, a wrong size or a curl failure is fail runner with no temp and no runner dir, "
      "and the next call fetches; two top dirs, a .. member or an absolute one is fail runner with nothing outside")
def _(c):
    setup()
    e2e()
    path, sha, size = runner_tar(NWT)
    serve(src=path)
    for bad in (("0" * 64, size), (sha, size + 1)):
        runner_conf(*bad)
        rc, out = call("steam-lib", "runner", "nwjs")
        c(out[-1] == "fail\tnwjs\trunner" and runners() == [], f"{bad}: {out[-1:]} {runners()}")
    runner_conf(sha, size)
    serve("fail")
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out[-1] == "fail\tnwjs\trunner" and runners() == [], f"curl fail: {out[-1:]} {runners()}")
    serve(src=path)
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out[-1] == "done\tnwjs" and runners() == [sha[:16]], f"retry: {out[-1:]} {runners()}")
    for entries in (NWT + [("other/x", b"x", 0o644)], NWT + [("nwjs-invented/../x", b"x", 0o644)],
                    [("/abs", b"x", 0o644)] + NWT):
        p2, s2, z2 = runner_tar(entries, "bad.tar.gz")
        runner_conf(s2, z2)
        serve(src=p2)
        rc, out = call("steam-lib", "runner", "nwjs")
        c(out[-1] == "fail\tnwjs\trunner" and runners() == [sha[:16]] and not os.path.exists(f"{DATA}/x") and
          not os.path.exists(f"{DATA}/other"), f"{[e[0] for e in entries[-1:]]}: {out[-1:]} {runners()}")


@case("steam-lib runner: the tar data filter: a symlink to an absolute path or out by ../.. with a file written "
      "through it, a hardlink out of the dir, a FIFO and a character device are each fail runner with nothing "
      "written outside steam-runners and no runner dir")
def _(c):
    setup()
    e2e()
    out_dir = f"{T}/outside"
    if os.path.lexists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    write(f"{T}/victim", "invented victim")
    base = NWT[:2]
    for label, extra in (
            ("absolute symlink", [("nwjs-invented/l", ("sym", out_dir), 0o777), ("nwjs-invented/l/x", b"x", 0o644)]),
            ("../.. symlink", [("nwjs-invented/l", ("sym", "../../../../../../../../../../.." + out_dir), 0o777),
                               ("nwjs-invented/l/x", b"x", 0o644)]),
            ("outside hardlink", [("nwjs-invented/h", ("hard", "../../../../victim"), 0o644)]),
            ("fifo", [("nwjs-invented/f", ("fifo",), 0o644)]),
            ("character device", [("nwjs-invented/d", ("chr",), 0o644)])):
        p2, s2, z2 = runner_tar(base + extra, "bad.tar.gz")
        runner_conf(s2, z2)
        serve(src=p2)
        rc, out = call("steam-lib", "runner", "nwjs")
        c(out[-1] == "fail\tnwjs\trunner" and runners() == [] and os.listdir(out_dir) == [] and
          rd(f"{T}/victim") == "invented victim" and os.stat(f"{T}/victim").st_nlink == 1,
          f"{label}: {out[-1:]} {runners()} {os.listdir(out_dir)} {LOG[-2:]}")


@case("steam-lib runner: a stop during the download kills curl and ends fail nwjs cancel with no temp and no runner "
      "dir; a stop in a get's runner fetch ends fail <app> cancel through the get's cancel clean")
def _(c):
    setup()
    e2e()
    path, sha, size = runner_tar(NWT)
    runner_conf(sha, size)
    serve("hang")
    cancel_at_curl()
    t0 = time.monotonic()
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out[-1] == "fail\tnwjs\tcancel" and time.monotonic() - t0 < 10 and runners() == [], f"{out[-1:]} {runners()}")
    pid = int(rd(f"{T}/curl.pid")) if os.path.exists(f"{T}/curl.pid") else None
    c(pid is not None and not alive(pid), f"curl {pid} alive")
    nw_ready()
    serve("hang")
    cancel_at_curl()
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\tcancel" and not dd_runs("get") and runners() == [] and
      not os.path.exists(f"{GAMES}/9000201/Game.exe"), f"{out[-2:]} {LOG[-3:]}")
    c(not [n for n in os.listdir(DL) if n.startswith("app-9000201.")], f"the get's clean: {os.listdir(DL)}")


@case("steam-lib runner: a damaged runner is fetched again; an unknown name, a name out of form and a conf with no "
      "URL fail other with no fetch; a pin out of form fails runner; busy with a scope, network offline; under the "
      "floor fail space with no fetch")
def _(c):
    setup()
    e2e()
    path, sha, size = runner_tar(NWT)
    runner_conf(sha, size)
    serve(src=path)
    call("steam-lib", "runner", "nwjs")
    dst = f"{DATA}/steam-runners/{sha[:16]}"
    os.unlink(f"{dst}/lib/libinvented.so")
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out[-1] == "done\tnwjs" and rd(f"{dst}/lib/libinvented.so") == "invented lib\n" and len(curls()) == 2,
      f"{out[-1:]} {curls()}")
    os.chmod(f"{dst}/nw", 0o644)
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out[-1] == "done\tnwjs" and stat.S_IMODE(os.stat(f"{dst}/nw").st_mode) == 0o755 and len(curls()) == 3,
      f"nw not executable: {out[-1:]} {curls()}")
    write(f"{USR}/runners.d/built.conf", "CLASSES=rgss:windows\n")
    for name in ("none", "../nwjs", "built"):
        rc, out = call("steam-lib", "runner", name)
        c(out == [f"fail\t{name}\tother"], f"{name}: {out}")
    write(f"{USR}/runners.d/odd.conf", f"CLASSES=rmmv:windows\nURL=http://example.invalid/x\nSHA256={sha}\n")
    rc, out = call("steam-lib", "runner", "odd")
    c(out == ["fail\todd\trunner"], f"odd: {out}")
    write(f"{T}/scope-rc", "0\n")
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out == ["fail\tnwjs\tbusy"], f"busy: {out}")
    write(f"{T}/scope-rc", "3\n")
    write(f"{T}/nm", "wifi:disconnected\n")
    rc, out = call("steam-lib", "runner", "nwjs")
    c(out == ["fail\tnwjs\tnetwork"], f"offline: {out}")
    write(f"{T}/nm", "wifi:connected\n")
    m.remove(dst)
    m.FLOOR = 1 << 62
    try:
        rc, out = call("steam-lib", "runner", "nwjs")
    finally:
        m.FLOOR = 0
    c(out[-1] == "fail\tnwjs\tspace" and len(curls()) == 3 and runners() == [], f"floor: {out[-1:]} {curls()}")


@case("steam-lib get with a fetched runner: after the pass the runner (progress runner) before the download; a "
      "runner failure ends fail <app> runner with no game file, the next get fetches the runner and places the game")
def _(c):
    sha = nw_ready()
    serve("fail")
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "fail\t9000201\trunner" and len(dd_runs("pass")) == 1 and not dd_runs("get") and
      not os.path.exists(f"{GAMES}/9000201/Game.exe") and runners() == [], f"{out[-3:]} {LOG[-3:]}")
    serve(src=f"{T}/runner.tar.gz")
    rc, out = call("steam-lib", "get", "9000201")
    words = [x.split("\t")[1] for x in out if x.startswith("progress\t")]
    c(out[-1] == "done\t9000201" and runners() == [sha[:16]] and os.path.isfile(f"{GAMES}/9000201/Game.exe"),
      f"{out[-3:]} {LOG[-3:]}")
    c("runner" in words and "download" in words and words.index("runner") < words.index("download") and
      words.index("check") < words.index("runner"), f"{words}")
    rc, out = call("steam-lib", "get", "9000201")
    c(out[-1] == "done\t9000201" and len(curls()) == 2, f"{out[-1:]} {curls()}")


PKG = json.dumps({"name": "rmmz-game", "main": "index.html", "chromium-args": "--force-color-profile=srgb",
                  "node-remote": "*", "window": {"title": "", "width": 816, "height": 624, "position": "center"}})
NWJS = 'for (const k of ["resizeBy", "resizeTo", "moveBy", "moveTo"]) window[k] = function () {};\n'
WIN = {"fullscreen": True, "frame": False}


def blockie(**keys):
    return {"name": "steam-nwjs", "main": "index.html", "inject_js_start": ".blockie-nw.js", **keys}


@case("the Blockie package.json: the get's last step writes name steam-nwjs, the depot's main, chromium-args and "
      "window keys with fullscreen true and frame false, inject_js_start naming .blockie-nw.js, no other key; "
      ".blockie-nw.js beside it holds the line that stubs the window move and resize calls; .got records both with "
      "their size and SHA1; the next get rewrites both with no exists failure; remove deletes both; a runner conf "
      "not named nwjs writes neither")
def _(c):
    nw_ready(dict(GET, **{"package.json": PKG}))
    rc, out = call("steam-lib", "get", "9000201")
    pj = f"{GAMES}/9000201/package.json"
    js = f"{GAMES}/9000201/.blockie-nw.js"
    want = blockie(**{"chromium-args": "--force-color-profile=srgb",
                      "window": {"title": "", "width": 816, "height": 624, "position": "center", **WIN}})
    c(out[-1] == "done\t9000201" and json.loads(rd(pj)) == want and rd(js) == NWJS,
      f"{out[-1:]} {rd(pj)} {LOG[-3:]}")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(got["files"]["9000201/package.json"] == [len(rd(pj).encode()), sha1(rd(pj))] and
      got["files"]["9000201/.blockie-nw.js"] == [len(NWJS), sha1(NWJS)] and
      got["placed"].count("9000201/package.json") == 1 and got["placed"].count("9000201/.blockie-nw.js") == 1,
      f"{got['files'].get('9000201/package.json')} {got['files'].get('9000201/.blockie-nw.js')}")
    os.unlink(js)
    rc, out = call("steam-lib", "get", "9000201")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(out[-1] == "done\t9000201" and json.loads(rd(pj)) == want and rd(js) == NWJS and
      got["placed"].count("9000201/.blockie-nw.js") == 1, f"second get: {out[-1:]} {LOG[-3:]}")
    rc, out = call("steam-lib", "remove", "9000201")
    c(out == ["done\t9000201"] and not os.path.exists(pj) and not os.path.exists(js) and
      not os.path.exists(f"{GS}/9000201.got"), f"remove: {out} {os.path.exists(pj)} {os.path.exists(js)}")
    get_ready(dict(GET, **{"package.json": PKG}))
    call("steam-lib", "get", "9000201")
    c(rd(pj) == PKG and not os.path.exists(js), f"test.conf: {rd(pj)}")


@case("a depot file named .blockie-nw.js, in any case, is replaced by Blockie's under that exact name and recorded "
      "with Blockie's size and SHA1, with one log line")
def _(c):
    nw_ready(dict(GET, **{".Blockie-NW.js": "invented depot script"}))
    rc, out = call("steam-lib", "get", "9000201")
    files = os.listdir(f"{GAMES}/9000201")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(out[-1] == "done\t9000201" and ".blockie-nw.js" in files and ".Blockie-NW.js" not in files and
      rd(f"{GAMES}/9000201/.blockie-nw.js") == NWJS and "9000201/.Blockie-NW.js" not in got["files"] and
      got["files"]["9000201/.blockie-nw.js"] == [len(NWJS), sha1(NWJS)] and
      sum("is replaced by Blockie's" in x for x in LOG) == 1, f"{out[-1:]} {sorted(files)} {LOG[-3:]}")


@case("the Blockie package.json from depot files out of form: a Package.json is replaced by package.json and "
      "recorded so; chromium-args keeps only --force-color-profile=<token> (-host-rules=, a quoted --host-rules, "
      "--class=, --remote-debugging-port= dropped, with one log line of the count) and js-flags is kept; a window "
      "that is no dict, a main that is a URL, a file over 64 KiB or no JSON give name, index.html and window "
      "fullscreen only")
def _(c):
    base = {k: v for k, v in GET.items() if k != "package.json"}
    nw_ready(dict(base, **{"Package.json": PKG}))
    rc, out = call("steam-lib", "get", "9000201")
    files = sorted(os.listdir(f"{GAMES}/9000201"))
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(out[-1] == "done\t9000201" and "package.json" in files and "Package.json" not in files and
      json.loads(rd(f"{GAMES}/9000201/package.json"))["name"] == "steam-nwjs" and
      "9000201/package.json" in got["files"] and "9000201/Package.json" not in got["files"] and
      "9000201/package.json" in got["placed"], f"{out[-1:]} {files} {LOG[-3:]}")
    rc, out = call("steam-lib", "get", "9000201")
    files = sorted(os.listdir(f"{GAMES}/9000201"))
    c(out[-1] == "done\t9000201" and "package.json" in files and "Package.json" not in files, f"again: {files}")
    rc, out = call("steam-lib", "remove", "9000201")
    c(out == ["done\t9000201"] and not os.path.exists(f"{GAMES}/9000201/package.json"), f"remove: {out}")
    plain = blockie(window=WIN)
    args = ('-host-rules=MAP * 203.0.113.9 "--host-rules=MAP * x" --class=x --remote-debugging-port=9222 '
            '--force-color-profile=srgb')
    for label, body, want in (
            ("allowlist", json.dumps({"main": "index.html", "chromium-args": args}),
             blockie(**{"chromium-args": "--force-color-profile=srgb"}, window=WIN)),
            ("conflicting args", json.dumps({"main": "index.html", "chromium-args": "--disable-gpu --x",
                                             "js-flags": "--expose-gc"}),
             blockie(**{"js-flags": "--expose-gc"}, window=WIN)),
            ("window no dict", json.dumps({"main": "index.html", "window": [1]}), plain),
            ("main a URL", json.dumps({"main": "https://example.invalid/x.html"}), plain),
            ("over 64 KiB", json.dumps({"main": "game.html", "pad": "x" * 70000}), plain),
            ("no JSON", "invented, not JSON", plain)):
        nw_ready(dict(GET, **{"package.json": body}))
        rc, out = call("steam-lib", "get", "9000201")
        c(out[-1] == "done\t9000201" and json.loads(rd(f"{GAMES}/9000201/package.json")) == want,
          f"{label}: {out[-1:]} {rd(f'{GAMES}/9000201/package.json')[:200]}")
        if label == "allowlist":
            c(sum("chromium-args: 8 dropped" in x for x in LOG) == 1, f"allowlist log: {LOG[-4:]}")


@case("the Blockie package.json from a Package.json depot: a replay after the depot file is gone reads the Blockie "
      "file and keeps its window keys; a package.json the game changed is replaced and recorded with Blockie's own "
      "size and SHA1, so remove deletes it")
def _(c):
    base = {k: v for k, v in GET.items() if k != "package.json"}
    nw_ready(dict(base, **{"Package.json": PKG}))
    call("steam-lib", "get", "9000201")
    pj = f"{GAMES}/9000201/package.json"
    before = json.loads(rd(pj))
    data = {"placed": [["9000201/Package.json", len(PKG), sha1(PKG)]],
            "got": {"depots": [], "class": "rmmz", "os": "windows", "root": ""}}
    LOG.clear()
    placed = m.nw_package("app-9000201", data)
    c(placed == [["9000201/package.json", len(rd(pj).encode()), sha1(rd(pj))],
                 ["9000201/.blockie-nw.js", len(NWJS), sha1(NWJS)]] and json.loads(rd(pj)) == before and
      before["window"]["width"] == 816 and not os.path.exists(f"{GAMES}/9000201/Package.json"),
      f"replay: {placed} {rd(pj)} {LOG}")
    write(pj, "changed by the game")
    rc, out = call("steam-lib", "get", "9000201")
    got = json.loads(rd(f"{GS}/9000201.got"))
    c(out[-1] == "done\t9000201" and json.loads(rd(pj)) == before and
      got["files"]["9000201/package.json"] == [len(rd(pj).encode()), sha1(rd(pj))] and
      got["placed"].count("9000201/package.json") == 1, f"{out[-1:]} {got['files'].get('9000201/package.json')}")
    rc, out = call("steam-lib", "remove", "9000201")
    c(out == ["done\t9000201"] and not os.path.exists(pj), f"remove: {out} {os.path.exists(pj)}")


print(f"steam-lib: {fails} failed" if fails else "steam-lib: python cases ok", flush=True)
sys.exit(1 if fails else 0)
