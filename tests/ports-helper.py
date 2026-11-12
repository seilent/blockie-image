#!/usr/bin/env python3
import contextlib
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import traceback
import zipfile

sys.dont_write_bytecode = True
BIN = os.environ["PORTS_BIN"]
FAKE = os.environ["FAKE_HM"]
T = os.environ["T"]
REAL_USR = os.environ.get("REAL_USR", "")
DATA = f"{T}/data"
PORTS = f"{DATA}/roms/ports"
FARM = f"{PORTS}/PortMaster"
LIBS = f"{FARM}/libs"
UNPACKED = f"{LIBS}/.unpacked"
STATE = f"{PORTS}/.blockie"
TMP = f"{DATA}/cache/ports-tmp/helper"
USR = f"{T}/usr"
TREE = f"{USR}/PortMaster"
RUN = f"{T}/run"
FIX = f"{T}/fix"
BINS = f"{T}/bin"
WORLD = f"{T}/world.json"
HMLOG = f"{T}/hm.log"
os.environ.update({
    "BLOCKIE_PORTS_DATA": DATA, "BLOCKIE_PORTS_MOUNT": "/", "BLOCKIE_PORTS_USR": USR,
    "BLOCKIE_PORTS_PYLIBS": FAKE, "BLOCKIE_PORTS_EXLIBS": FAKE, "BLOCKIE_PORTS_SYSTEMCTL": f"{BINS}/systemctl",
    "BLOCKIE_PORTS_NMCLI": f"{BINS}/nmcli", "BLOCKIE_PORTS_UNSQUASHFS": f"{BINS}/unsquashfs",
    "BLOCKIE_PORTS_FLOOR": "0", "BLOCKIE_PORTS_WAIT_S": "1", "FAKE_HM_WORLD": WORLD, "XDG_RUNTIME_DIR": RUN,
})
loader = importlib.machinery.SourceFileLoader("ports", BIN)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("ports", loader))
loader.exec_module(m)
LOG = []
m.log = LOG.append
FREE = m.free_bytes
WHY = "network|space|md5|runtime|unknown-runtime|nodata|busy|cancel|other"
LINE = re.compile(rf"progress\t[^\t]+\t[0-9]+\t(?:[0-9]+|-)|done\t[^\t]+|fail\t[^\t]+\t(?:{WHY})")
fails = 0


def res(ok, name, why=""):
    global fails
    if ok:
        print(f"ok   {name}", flush=True)
    else:
        fails += 1
        print(f"FAIL {name}", flush=True)
        for line in why.splitlines():
            print(f"  {line}", flush=True)


def case(name):
    def wrap(f):
        try:
            c = Check()
            f(c)
            ok, why = not c.bad, "\n".join(c.bad)
        except Exception:
            ok, why = False, traceback.format_exc(limit=6)
        m.FLOOR = 0
        m.MOUNT = "/"
        m.free_bytes = FREE
        res(ok, name, why)
        return f
    return wrap


class Check:
    def __init__(self):
        self.bad = []

    def __call__(self, cond, what):
        if not cond:
            self.bad.append(what)
        return cond


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


def rd(path):
    with open(path) as f:
        return f.read()


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def mkzip(path, members):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for n, data in members.items():
            mode = 0o644
            if isinstance(data, tuple):
                data, mode = data
            zi = zipfile.ZipInfo(n)
            zi.external_attr = (stat.S_IFREG | mode) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(zi, data)
    return os.path.getsize(path), md5(path)


def port(name, members, title, tag="v1", **attr):
    path = f"{FIX}/{tag}-{name}"
    size, digest = mkzip(path, members)
    a = {"title": title, "porter": ["Invented Porter"], "desc": "line one\nline two", "inst": "Copy the files in.",
         "genres": ["action"], "runtime": [], "reqs": [], "exp": False, "availability": "free", "image": {}}
    a.update(attr)
    return {"name": name, "items": sorted({k.split("/", 1)[0] for k in members}), "attr": a,
            "source": {"size": size, "md5": digest, "url": f"file:{path}"}}


def runtime(name, members, tag="v1"):
    path = f"{FIX}/{tag}-{name}"
    size, digest = mkzip(path, members)
    return {"name": name, "remote": {"aarch64": {"name": name, "md5": digest, "size": size, "url": f"file:{path}"}}}


def base_world():
    rts = {"frt_3.5.2.squashfs": runtime("frt_3.5.2.squashfs", {"bin/frt": ("#!/bin/sh\n", 0o755), "lib/x.so": "x"}),
           "weston_pkg_0.2.squashfs": runtime("weston_pkg_0.2.squashfs", {"westonwrap.sh": "#!/bin/sh\n"})}
    write(f"{FIX}/alpha.screenshot.png", b"png")
    write(f"{FIX}/Bad Name.cover.png", b"png")
    ports = {
        "alpha.zip": port("alpha.zip", {"Alpha.sh": '#!/bin/bash\nweston_runtime="weston_pkg_0.2"\n',
                                        "alpha/game.bin": "game", "alpha/data/level.dat": "x"},
                          "Alpha", runtime=["frt_3.5.2.squashfs"]),
        "beta.zip": port("beta.zip", {"Beta.sh": "#!/bin/bash\n", "beta/x": "x"}, "Beta", reqs=["invented_cap"]),
        "gamma.zip": port("gamma.zip", {"Gamma.sh": "#!/bin/bash\n", "gamma/x": "x"}, "Gamma", exp=True),
        "zero.zip": port("zero.zip", {"Zero.sh": "#!/bin/bash\n", "zero/big.bin": b"\0" * (4 << 20),
                                      "zero/noise.bin": os.urandom(8192)}, "Zero"),
        "unk.zip": port("unk.zip", {"Unk.sh": '#!/bin/bash\nruntime="mystery_1.0"\n', "unk/x": "x"}, "Unknown"),
        "love.zip": port("love.zip", {"Love.sh": "#!/bin/bash\n", "love/x": "x"}, "Love\x07ly",
                         runtime=["love_11.5.squashfs"]),
    }
    return {"log": HMLOG, "caps": ["power"], "ports": ports, "runtimes": rts,
            "utils": ["images.zip", "portmaster.zip"] + sorted(rts),
            "images": {"alpha.zip": {"screenshot": f"{FIX}/alpha.screenshot.png", "cover": f"{FIX}/Bad Name.cover.png"}}}


def save(w):
    with open(WORLD, "w") as f:
        json.dump(w, f)


def tool(name, body):
    write(f"{BINS}/{name}", body, 0o755)


def reset(w=None):
    os.chdir(T)
    for p in (DATA, USR, RUN):
        m.remove(p)
    os.makedirs(PORTS)
    os.makedirs(f"{DATA}/cache/ports-tmp", 0o700)
    os.makedirs(RUN, 0o700)
    for rel, data in (("control.txt", "c"), ("funcs.txt", "f"), ("device_info.txt", "d"), ("pylibs/x.py", "x"),
                      ("resources/background.png", "png")):
        write(f"{TREE}/{rel}", data)
    write(f"{USR}/tree.sha256", "stamp-a\n")
    os.makedirs(f"{TREE}/libs")
    write(f"{USR}/mod_Blockie.txt", "mod")
    write(f"{USR}/harbourmaster", "shim", 0o755)
    open(HMLOG, "w").close()
    write(f"{T}/scope-rc", "3\n")
    write(f"{T}/nm", "wifi:connected\nloopback:connected (externally)\n")
    w = w or base_world()
    save(w)
    LOG.clear()
    return w


def call(*args):
    r, w = os.pipe()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = m.run(["blockie-ports", *args], m.Proto(w))
    finally:
        os.close(w)
    with os.fdopen(r) as f:
        return rc, f.read().splitlines()


def sub(*args, env=None):
    return subprocess.run([BIN, *args], capture_output=True, text=True, env=env, timeout=120)


def hmlog(what=None):
    with open(HMLOG) as f:
        rows = [json.loads(line) for line in f]
    return [r for r in rows if what is None or r["what"] == what]


def downloads():
    return [r["url"] for r in hmlog("download")]


def catalog():
    db = sqlite3.connect(f"{STATE}/catalog.db")
    db.row_factory = sqlite3.Row
    try:
        return {r["name"]: dict(r) for r in db.execute("SELECT * FROM ports")}
    finally:
        db.close()


def index():
    return rd(f"{STATE}/index.tsv").splitlines()


def unindex():
    try:
        return [line.split("\t") for line in rd(f"{UNPACKED}/index.tsv").splitlines()]
    except FileNotFoundError:
        return []


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def lock(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def last(lines):
    return lines[-1] if lines else ""


os.makedirs(FIX, exist_ok=True)
tool("systemctl", f'#!/bin/sh\nexit "$(cat {T}/scope-rc)"\n')
tool("nmcli", f"#!/bin/sh\ncat {T}/nm\n")
tool("unsquashfs", """#!/usr/bin/env python3
import os
import sys
import zipfile

a = sys.argv[1:]
d = a[a.index("-d") + 1]
print("Parallel unsquashfs: invented", flush=True)
with zipfile.ZipFile(a[-1]) as zf:
    for i in zf.infolist():
        p = zf.extract(i, d)
        if (i.external_attr >> 16) & 0o111:
            os.chmod(p, 0o755)
print("50")
print("100")
""")


@case("protocol lines go only to the private fd, harbourmaster's own stdout goes to stderr")
def _(c):
    w = reset()
    w["refresh"] = [w["ports"]["beta.zip"]["source"]["url"]]
    save(w)
    r = sub("refresh")
    lines = r.stdout.splitlines()
    c(r.returncode == 0, f"rc {r.returncode}: {r.stderr[-400:]}")
    c(lines and all(LINE.fullmatch(x) for x in lines), f"stdout {lines}")
    c(last(lines) == "done\trefresh", f"last {last(lines)!r}")
    c(any(x.startswith("progress\trefresh\t") for x in lines), "no refresh progress")
    c("fake harbourmaster writes to stdout" in r.stderr, "harbourmaster's print is not on stderr")
    r = sub("index")
    c(r.stdout == "done\tindex\n", f"index stdout {r.stdout!r}")


@case("usage errors exit 64 and write no protocol line")
def _(c):
    reset()
    for args in ((), ("install",), ("install", "a.zip", "b.zip"), ("reinstall", "a.zip"), ("install", "a\t.zip"),
                 ("sync", "x")):
        rc, lines = call(*args)
        c(rc == 64 and lines == [], f"{args}: rc {rc} {lines}")


@case("the data partition not mounted: fail nodata before anything else")
def _(c):
    reset()
    m.MOUNT = T
    for args, name in ((("install", "alpha.zip"), "alpha.zip"), (("sync",), "sync"), (("runtime", "frt_3.5.2"), "frt_3.5.2")):
        rc, lines = call(*args)
        c(rc == 1 and lines == [f"fail\t{name}\tnodata"], f"{args}: {rc} {lines}")
    c(hmlog() == [], "harbourmaster was opened")
    c(not os.path.exists(STATE), "state dir created")


@case("refresh opens harbourmaster with checks, the other commands with no-check; offline when no device is connected")
def _(c):
    reset()
    call("refresh")
    call("install", "zero.zip")
    call("runtime", "frt_3.5.2")
    call("index")
    cfgs = [r["config"] for r in hmlog("open")]
    c([(x["no-check"], x["offline"]) for x in cfgs] == [(False, False), (True, False), (True, False)], f"{cfgs}")
    open(HMLOG, "w").close()
    write(f"{T}/nm", "wifi:disconnected\nwifi-p2p:unavailable\nloopback:connected (externally)\n"
                     "ethernet:connecting (getting IP configuration)\n")
    rc, lines = call("refresh")
    c(rc == 0, f"offline refresh {lines}")
    rc, lines = call("install", "alpha.zip")
    c(lines[-1:] == ["fail\talpha.zip\tnetwork"], f"offline install {lines}")
    cfgs = [r["config"] for r in hmlog("open")]
    c(all(x["no-check"] and x["offline"] for x in cfgs) and len(cfgs) == 2, f"offline {cfgs}")
    c(downloads() == [], f"downloads {downloads()}")
    write(f"{T}/nm", "wifi:connected (externally)\nloopback:connected (externally)\n")
    open(HMLOG, "w").close()
    call("refresh")
    c(not hmlog("open")[0]["config"]["offline"], "a wifi connected (externally) read as offline")


@case("catalog.db holds the ports passing the requirements, hidden counts by reason in the log")
def _(c):
    w = reset()
    rc, lines = call("refresh")
    c(rc == 0, f"{lines}")
    cat = catalog()
    c(set(cat) == {"alpha.zip", "love.zip", "unk.zip", "zero.zip"}, f"names {sorted(cat)}")
    db = sqlite3.connect(f"{STATE}/catalog.db")
    try:
        c(db.execute("PRAGMA user_version").fetchone()[0] == 1 and
          db.execute("PRAGMA journal_mode").fetchone()[0] == "delete", "catalog.db user_version or journal mode")
    finally:
        db.close()
    c(any("hidden: 1 by requirements, 1 experimental" in x for x in LOG), f"log {LOG}")
    a = cat.get("alpha.zip", {})
    want = {"title": "Alpha", "genres": "action", "porter": "Invented Porter", "description": "line one\nline two",
            "inst": "Copy the files in.", "availability": "free", "runtimes": "frt_3.5.2.squashfs", "installed": 0,
            "update_available": 0, "screenshot": f"{FIX}/alpha.screenshot.png", "cover": None}
    c(all(a.get(k) == v for k, v in want.items()), f"alpha {a}")
    c(a.get("size") == w["ports"]["alpha.zip"]["source"]["size"], f"size {a.get('size')}")
    c(cat.get("love.zip", {}).get("title") == "Love ly", f"love title {cat.get('love.zip', {}).get('title')!r}")
    c(not [p for p in os.listdir(STATE) if ".tmp-" in p], f"tmp left {os.listdir(STATE)}")


@case("install: the port, its runtimes from port.json and the script scan, unpacked read only, the index")
def _(c):
    w = reset()
    rc, lines = call("install", "alpha.zip")
    c(rc == 0 and last(lines) == "done\talpha.zip", f"{lines[-3:]} {LOG[-5:]}")
    whats = {x.split("\t")[1] for x in lines if x.startswith("progress\t")}
    c({"download", "install", "runtime", "unpack"} <= whats, f"progress kinds {whats}")
    c(all(LINE.fullmatch(x) for x in lines), f"lines {lines}")
    c(os.path.isfile(f"{PORTS}/Alpha.sh") and os.path.isfile(f"{PORTS}/alpha/game.bin"), "port files missing")
    c(mode(f"{PORTS}/alpha") == 0o755 and mode(f"{PORTS}/alpha/game.bin") == 0o755 and mode(f"{PORTS}/Alpha.sh") == 0o755,
      f"port modes {oct(mode(f'{PORTS}/alpha'))} {oct(mode(f'{PORTS}/alpha/game.bin'))}")
    rows = {r[0]: r for r in unindex()}
    for rt in ("frt_3.5.2.squashfs", "weston_pkg_0.2.squashfs"):
        digest = w["runtimes"][rt]["remote"]["aarch64"]["md5"]
        f = f"{LIBS}/{rt}"
        c(os.path.isfile(f) and md5(f) == digest, f"{rt} missing or wrong")
        st = os.stat(f) if os.path.exists(f) else None
        c(st is not None and rows.get(rt) == [rt, str(st.st_size), str(st.st_mtime_ns), str(st.st_ino), digest],
          f"unpacked index row {rows.get(rt)}")
        tree = f"{UNPACKED}/{digest}"
        c(os.path.isdir(tree) and mode(tree) == 0o555, f"{rt} tree missing or mode")
    frt = f"{UNPACKED}/{w['runtimes']['frt_3.5.2.squashfs']['remote']['aarch64']['md5']}"
    if os.path.isdir(frt):
        c(mode(f"{frt}/bin") == 0o555 and mode(f"{frt}/bin/frt") == 0o555 and mode(f"{frt}/lib/x.so") == 0o444,
          f"tree modes {oct(mode(f'{frt}/bin/frt'))} {oct(mode(f'{frt}/lib/x.so'))}")
    c(not os.listdir(f"{STATE}/txn"), f"journal left {os.listdir(f'{STATE}/txn')}")
    c(not os.listdir(TMP), f"tmp left {os.listdir(TMP)}")
    c(not os.listdir(f"{LIBS}/.part"), "part files left")
    c(index() == [f"Alpha\tAlpha\t{PORTS}/alpha\t-"], f"index {index()}")
    c(catalog().get("alpha.zip", {}).get("installed") == 1, "catalog installed flag")
    open(HMLOG, "w").close()
    rc, lines = call("install", "alpha.zip")
    c(rc == 0 and downloads() == [w["ports"]["alpha.zip"]["source"]["url"]], f"reinstall downloads {downloads()}")


@case("a runtime name not in the catalogue leaves the port installed with unknown-runtime; love_11.5 is never fetched")
def _(c):
    w = reset()
    rc, lines = call("install", "unk.zip")
    c(rc == 1 and last(lines) == "fail\tunk.zip\tunknown-runtime", f"{lines[-2:]}")
    c(os.path.isfile(f"{PORTS}/Unk.sh") and "Unk\tUnknown\t" + f"{PORTS}/unk\t-" in index(), f"index {index()}")
    open(HMLOG, "w").close()
    rc, lines = call("install", "love.zip")
    c(rc == 0 and downloads() == [w["ports"]["love.zip"]["source"]["url"]], f"love {lines[-1:]} {downloads()}")
    rc, lines = call("runtime", "love_11.5")
    c(rc == 0 and lines == ["done\tlove_11.5"], f"runtime love {lines}")


@case("refused: portmaster.zip, utils keys, names not in the catalogue, bad names, update or uninstall of a port not installed")
def _(c):
    reset()
    for args in (("install", "portmaster.zip"), ("install", "images.zip"), ("install", "frt_3.5.2.squashfs"),
                 ("install", "nothere.zip"), ("install", "../x.zip"), ("install", "Alpha.zip"),
                 ("update", "zero.zip"), ("uninstall", "zero.zip")):
        rc, lines = call(*args)
        c(rc == 1 and lines == [f"fail\t{args[1]}\tother"], f"{args}: {lines}")
    rc, lines = call("runtime", "images.zip")
    c(lines == ["fail\timages.zip\tunknown-runtime"], f"runtime images.zip {lines}")
    rc, lines = call("runtime", "../frt")
    c(lines == ["fail\t../frt\tother"], f"runtime ../frt {lines}")
    c(downloads() == [], f"downloads {downloads()}")


@case("the space floor is checked before the download and again with the zip's real sizes before extraction")
def _(c):
    w = reset()
    m.free_bytes = lambda: 1000
    rc, lines = call("install", "zero.zip")
    c(lines == ["fail\tzero.zip\tspace"] and downloads() == [], f"before download {lines} {downloads()}")
    m.free_bytes = lambda: 4096 + 2 * w["ports"]["zero.zip"]["source"]["size"]
    rc, lines = call("install", "zero.zip")
    c(last(lines) == "fail\tzero.zip\tspace" and len(downloads()) == 1 and not hmlog("install"),
      f"before extraction {lines[-1:]} {downloads()} {hmlog('install')}")
    c(not os.path.exists(f"{PORTS}/Zero.sh") and not os.path.exists(f"{PORTS}/zero"), "port files after refusal")
    c(not os.listdir(f"{STATE}/txn") and not os.listdir(TMP), "journal or zip left")
    m.free_bytes = lambda: 1 << 40
    m.FLOOR = (1 << 40) - 100
    rc, lines = call("install", "zero.zip")
    c(lines == ["fail\tzero.zip\tspace"], f"the floor itself {lines}")


@case("a cancel during the download removes the partial zip and installs nothing")
def _(c):
    w = reset()
    w["term_at"] = {w["ports"]["zero.zip"]["source"]["url"]: 1}
    save(w)
    rc, lines = call("install", "zero.zip")
    c(rc == 1 and last(lines) == "fail\tzero.zip\tcancel", f"{lines[-2:]}")
    c(not hmlog("install") and not os.path.exists(f"{PORTS}/Zero.sh"), "installed after cancel")
    c(not os.listdir(TMP) and not os.listdir(f"{STATE}/txn"), f"left {os.listdir(TMP)}")


@case("a cancel during extraction waits for it, then removes only the paths that did not exist before")
def _(c):
    w = reset()
    w["term_in_install"] = ["zero.zip"]
    save(w)
    write(f"{PORTS}/zero/user.txt", "mine")
    rc, lines = call("install", "zero.zip")
    c(rc == 1 and last(lines) == "fail\tzero.zip\tcancel" and len(hmlog("install")) == 1, f"{lines[-1:]}")
    c(not os.path.exists(f"{PORTS}/Zero.sh") and not os.path.exists(f"{PORTS}/zero/port.json"), "new paths left")
    c(rd(f"{PORTS}/zero/user.txt") == "mine", "the existing port dir lost user data")
    m.remove(f"{PORTS}/zero")
    rc, lines = call("install", "zero.zip")
    c(last(lines) == "fail\tzero.zip\tcancel" and not os.path.exists(f"{PORTS}/zero"), f"fresh dir {lines[-1:]}")
    c(not os.listdir(f"{STATE}/txn") and "Zero" not in rd(f"{STATE}/index.tsv"), "journal or index left")


def installed_alpha(c):
    w = reset()
    rc, lines = call("install", "alpha.zip")
    c(rc == 0, f"first install {lines[-1:]}")
    write(f"{PORTS}/alpha/conf/save.txt", "progress")
    w2 = json.loads(json.dumps(w))
    w2["ports"]["alpha.zip"] = port("alpha.zip", {"Alpha.sh": '#!/bin/bash\nweston_runtime="weston_pkg_0.2"\n',
                                                  "alpha/game.bin": "game v2", "alpha/data/level.dat": "x"},
                                    "Alpha", tag="v2", runtime=["frt_3.5.2.squashfs"])
    return w, w2


@case("an update with a runtime failure keeps the port, $GAMEDIR/conf and the old runtime, and marks the port update")
def _(c):
    w, w2 = installed_alpha(c)
    rt = "weston_pkg_0.2.squashfs"
    old = w["runtimes"][rt]["remote"]["aarch64"]["md5"]
    st = os.stat(f"{LIBS}/{rt}")
    row = [r for r in unindex() if r[0] == rt]
    w2["runtimes"][rt] = runtime(rt, {"westonwrap.sh": "#!/bin/sh\necho v2\n"}, tag="v2")
    w2["runtimes"][rt]["remote"]["aarch64"]["url"] = "https://invalid.example/weston.squashfs"
    save(w2)
    rc, lines = call("update", "alpha.zip")
    c(rc == 1 and last(lines) == "fail\talpha.zip\truntime", f"{lines[-1:]} {LOG[-3:]}")
    c(rd(f"{PORTS}/alpha/conf/save.txt") == "progress", "conf lost")
    c(rd(f"{PORTS}/alpha/game.bin") == "game v2" and os.path.isfile(f"{PORTS}/Alpha.sh"), "port not kept")
    c(os.path.exists(f"{STATE}/updates/alpha.zip"), "no update mark")
    c(catalog().get("alpha.zip", {}).get("update_available") == 1, "catalog update flag not set")
    st2 = os.stat(f"{LIBS}/{rt}")
    c((st2.st_ino, st2.st_mtime_ns) == (st.st_ino, st.st_mtime_ns) and md5(f"{LIBS}/{rt}") == old, "old runtime replaced")
    c(os.path.isdir(f"{UNPACKED}/{old}") and [r for r in unindex() if r[0] == rt] == row, "old tree or its row gone")
    c(not os.listdir(f"{LIBS}/.part") and not os.listdir(f"{STATE}/txn"), "part or journal left")


@case("a cancelled update keeps the port and $GAMEDIR/conf, marks it, and the next good update clears the mark")
def _(c):
    w, w2 = installed_alpha(c)
    w2["term_at"] = {w2["ports"]["alpha.zip"]["source"]["url"]: 0}
    save(w2)
    rc, lines = call("update", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tcancel", f"{lines[-1:]}")
    c(rd(f"{PORTS}/alpha/game.bin") == "game" and rd(f"{PORTS}/alpha/conf/save.txt") == "progress", "port changed")
    c(os.path.exists(f"{STATE}/updates/alpha.zip"), "no update mark")
    del w2["term_at"]
    save(w2)
    rc, lines = call("update", "alpha.zip")
    c(rc == 0 and rd(f"{PORTS}/alpha/game.bin") == "game v2", f"good update {lines[-1:]}")
    c(rd(f"{PORTS}/alpha/conf/save.txt") == "progress", "conf lost on the good update")
    c(not os.path.exists(f"{STATE}/updates/alpha.zip") and catalog()["alpha.zip"]["update_available"] == 0,
      "mark not cleared")


@case("a KILL during a runtime fetch leaves no final file, and the next run fetches it again")
def _(c):
    w = reset()
    rt = "frt_3.5.2.squashfs"
    remote = w["runtimes"][rt]["remote"]["aarch64"]
    w["kill_at"] = {remote["url"]: 0}
    save(w)
    r = sub("runtime", "frt_3.5.2")
    c(r.returncode == -9, f"rc {r.returncode} {r.stderr[-300:]}")
    c(not os.path.exists(f"{LIBS}/{rt}"), "final name written by a killed fetch")
    c(os.path.exists(f"{STATE}/txn/{rt}"), "no journal for the killed fetch")
    del w["kill_at"]
    save(w)
    r = sub("runtime", "frt_3.5.2")
    c(r.returncode == 0 and r.stdout.splitlines()[-1:] == ["done\tfrt_3.5.2"], f"{r.stdout[-200:]} {r.stderr[-300:]}")
    c(os.path.isfile(f"{LIBS}/{rt}") and md5(f"{LIBS}/{rt}") == remote["md5"], "not fetched again")
    c(os.path.isdir(f"{UNPACKED}/{remote['md5']}"), "not unpacked")


@case("unpack: a file whose md5 matches the catalogue is unpacked, a mismatch is refused")
def _(c):
    w = reset()
    rt = "frt_3.5.2.squashfs"
    remote = w["runtimes"][rt]["remote"]["aarch64"]
    os.makedirs(LIBS)
    write(f"{FARM}/config/runtimes.json", json.dumps({rt: {"remote": {os.uname().machine: remote}}}))
    with open(remote["url"][5:], "rb") as f:
        write(f"{LIBS}/{rt}", f.read())
    rc, lines = call("unpack", f"/roms-invented/../{LIBS}/{rt}")
    c(rc == 0 and last(lines) == f"done\t{rt}", f"{lines}")
    c(os.path.isdir(f"{UNPACKED}/{remote['md5']}") and [r[0] for r in unindex()] == [rt], "not unpacked")
    c(downloads() == [], "unpack downloaded")
    write(f"{LIBS}/weston_pkg_0.2.squashfs", b"truncated")
    data = json.loads(rd(f"{FARM}/config/runtimes.json"))
    data["weston_pkg_0.2.squashfs"] = w["runtimes"]["weston_pkg_0.2.squashfs"]
    data["weston_pkg_0.2.squashfs"]["remote"] = {os.uname().machine: data["weston_pkg_0.2.squashfs"]["remote"]["aarch64"]}
    write(f"{FARM}/config/runtimes.json", json.dumps(data))
    rc, lines = call("unpack", f"{LIBS}/weston_pkg_0.2.squashfs")
    c(lines == ["fail\tweston_pkg_0.2.squashfs\tmd5"], f"mismatch {lines}")
    rc, lines = call("unpack", f"{PORTS}/{rt}")
    c(lines == [f"fail\t{rt}\tother"], f"outside libs {lines}")


@case("an unfinished journal is replayed only by commands that hold the game lock")
def _(c):
    reset()
    call("sync")
    write(f"{PORTS}/Zero.sh", "x")
    write(f"{PORTS}/zero/big.bin", "x")
    write(f"{PORTS}/alpha-new.sh", "x")
    write(f"{PORTS}/beta-new.sh", "x")
    write(f"{T}/outside", "keep")
    m.journal("zero.zip", {"op": "install", "name": "zero.zip",
                           "new": [f"{PORTS}/Zero.sh", f"{PORTS}/zero", FARM, STATE, f"{T}/outside"]})
    m.journal("alpha.zip", {"op": "update", "name": "alpha.zip", "new": [f"{PORTS}/alpha-new.sh"]})
    m.journal("beta.zip", {"op": "update", "name": "beta.zip", "extracted": True, "new": [f"{PORTS}/beta-new.sh"]})
    write(f"{STATE}/txn/broken.zip", "not json")
    for args in (("runtime", "frt_3.5.2"), ("sync",), ("index",), ("refresh",)):
        rc, lines = call(*args)
        c(rc == 0 and len(os.listdir(f"{STATE}/txn")) == 4, f"{args} replayed or failed {lines[-1:]}")
    c(os.path.exists(f"{PORTS}/Zero.sh"), "replayed early")
    rc, lines = call("install", "love.zip")
    c(rc == 0 and not os.listdir(f"{STATE}/txn"), f"install did not replay {lines[-1:]}")
    c(not os.path.exists(f"{PORTS}/Zero.sh") and not os.path.exists(f"{PORTS}/zero"), "new paths left")
    c(not os.path.exists(f"{PORTS}/alpha-new.sh") and os.path.exists(f"{STATE}/updates/alpha.zip"), "update not marked")
    c(os.path.exists(f"{PORTS}/beta-new.sh") and os.path.exists(f"{STATE}/updates/beta.zip"),
      "an extracted update lost its files or its mark")
    c(os.path.isdir(FARM) and os.path.isdir(STATE) and rd(f"{T}/outside") == "keep", "replay removed outside paths")


@case("locks: the helper lock refuses at once, runtime waits for it, the game lock and an active scope refuse port changes")
def _(c):
    reset()
    call("install", "alpha.zip")
    fd = lock(f"{STATE}/lock")
    try:
        for args, name in ((("install", "zero.zip"), "zero.zip"), (("sync",), "sync"), (("uninstall", "alpha.zip"), "alpha.zip")):
            t0 = time.monotonic()
            rc, lines = call(*args)
            c(lines == [f"fail\t{name}\tbusy"] and time.monotonic() - t0 < 0.5, f"{args} {lines}")
        t0 = time.monotonic()
        rc, lines = call("runtime", "frt_3.5.2")
        c(last(lines) == "fail\tfrt_3.5.2\tbusy" and time.monotonic() - t0 >= 0.9, f"runtime wait {lines}")
        c(any(x.startswith("progress\twait\t") for x in lines), "no wait progress")
        threading.Timer(0.3, os.close, (fd,)).start()
        rc, lines = call("runtime", "frt_3.5.2")
        fd = None
        c(last(lines) == "done\tfrt_3.5.2", f"runtime after release {lines}")
    finally:
        if fd is not None:
            os.close(fd)
    time.sleep(0.4)
    open(HMLOG, "w").close()
    fd = lock(f"{RUN}/blockie-game.lock")
    try:
        rc, lines = call("install", "zero.zip")
        c(lines[-1:] == ["fail\tzero.zip\tbusy"] and downloads() == [], f"game lock install {lines}")
        rc, lines = call("uninstall", "alpha.zip")
        c(lines[-1:] == ["fail\talpha.zip\tbusy"] and os.path.exists(f"{PORTS}/Alpha.sh"), f"game lock uninstall {lines}")
        rc, lines = call("runtime", "frt_3.5.2")
        c(lines[-1:] == ["done\tfrt_3.5.2"], f"runtime under the game lock {lines}")
    finally:
        os.close(fd)
    write(f"{T}/scope-rc", "0\n")
    for args, name in ((("install", "zero.zip"), "zero.zip"), (("update", "alpha.zip"), "alpha.zip"),
                       (("uninstall", "alpha.zip"), "alpha.zip")):
        rc, lines = call(*args)
        c(lines == [f"fail\t{name}\tbusy"], f"scope active {args} {lines}")
    rc, lines = call("runtime", "frt_3.5.2")
    c(lines[-1:] == ["done\tfrt_3.5.2"], f"runtime with the scope active {lines}")


@case("uninstall removes the port; runtime trees go only when no installed port names them and unused for 30 days")
def _(c):
    w = reset()
    call("install", "alpha.zip")
    trees = [f"{UNPACKED}/{r['remote']['aarch64']['md5']}" for r in w["runtimes"].values()]
    old = time.time() - 31 * 86400
    for t in trees:
        os.utime(t, (old, old))
    call("install", "love.zip")
    c(all(os.path.isdir(t) for t in trees), "trees of an installed port removed")
    rc, lines = call("uninstall", "alpha.zip")
    c(rc == 0 and not os.path.exists(f"{PORTS}/Alpha.sh") and not os.path.exists(f"{PORTS}/alpha"), f"{lines[-1:]}")
    c(not any(x.startswith("Alpha\t") for x in index()), "index still lists Alpha")
    c(not any(os.path.isdir(t) for t in trees) and unindex() == [], "old unused trees kept")
    c(all(os.path.isfile(f"{LIBS}/{rt}") for rt in w["runtimes"]), "squashfs files removed")
    call("install", "alpha.zip")
    write(trees[0] + ".used", "")
    for t in trees:
        os.utime(t, (old, old))
    call("uninstall", "alpha.zip")
    c(os.path.isdir(trees[0]) and not os.path.isdir(trees[1]), "the .used stamp was not honoured")


@case("index.tsv: scripts inverted from port.json items, hand installed scripts, sanitized titles, covers")
def _(c):
    reset()
    for f in ("Delta.sh", "Delta Extra.sh", "Tabbed.sh", "Hand.sh", ".hidden.sh", "notes.txt"):
        write(f"{PORTS}/{f}", "#!/bin/bash\n")
    os.symlink("Hand.sh", f"{PORTS}/Link.sh")
    write(f"{PORTS}/delta/port.json", json.dumps({"name": "delta.zip", "items": ["Delta.sh", "Delta Extra.sh", "delta"],
                                                  "attr": {"title": "Delta"}}))
    write(f"{PORTS}/tabbed/port.json", json.dumps({"name": "tabbed.zip", "items": ["Tabbed.sh", "tabbed"],
                                                   "attr": {"title": "Tab\there\nnow\x1b\ud83d", "image": {"covers": ["../x.png"]}}}))
    write(f"{PORTS}/tabbed/cover.png", b"png")
    write(f"{PORTS}/broken/port.json", "not json")
    write(os.path.join(os.fsencode(PORTS), b"Bad\xff.sh"), "#!/bin/bash\n")
    rc, lines = call("index")
    want = [f"Delta Extra\tDelta Extra\t{PORTS}/delta\t-", f"Delta\tDelta\t{PORTS}/delta\t-", "Hand\tHand\t-\t-",
            f"Tabbed\tTab here now ?\t{PORTS}/tabbed\t{PORTS}/tabbed/cover.png"]
    c(rc == 0 and index() == want, f"index {index()}")
    c(mode(f"{STATE}/index.tsv") == 0o644, "index mode")


@case("sync: links into /usr, real dirs, stale moves keeping the last 3, the stamp by equality")
def _(c):
    reset()
    rc, lines = call("sync")
    c(rc == 0 and lines == ["done\tsync"], f"{lines}")
    c(not os.path.lexists(f"{FARM}/tree.sha256"), "stamp linked into the farm")
    for e, target in (("control.txt", f"{TREE}/control.txt"), ("pylibs", f"{TREE}/pylibs"),
                      ("mod_Blockie.txt", f"{USR}/mod_Blockie.txt"),
                      ("harbourmaster", f"{USR}/harbourmaster")):
        c(os.path.islink(f"{FARM}/{e}") and os.readlink(f"{FARM}/{e}") == target, f"link {e}")
    for d in ("libs", "config", "resources", "themes"):
        c(os.path.isdir(f"{FARM}/{d}") and not os.path.islink(f"{FARM}/{d}"), f"real dir {d}")
    c(rd(f"{FARM}/resources/background.png") == "png", "resources not seeded")
    c(rd(f"{FARM}/config/020_portmaster.source.json") == '{"prefix": "pm", "name": "Invented One"}\n', "sources")
    c(rd(f"{STATE}/tree.sha256") == "stamp-a\n" and os.path.isfile(f"{STATE}/index.tsv"), "stamp or index")
    write(f"{FARM}/stray.txt", "x")
    os.symlink(f"{TREE}/gone", f"{FARM}/gone")
    os.unlink(f"{FARM}/control.txt")
    os.symlink(f"{T}/elsewhere", f"{FARM}/control.txt")
    os.unlink(f"{FARM}/pylibs")
    write(f"{FARM}/pylibs/mine.py", "x")
    write(f"{FARM}/device_info_blockie_invented.env", "X=1\n")
    write(f"{FARM}/config/020_portmaster.source.json", "edited")
    write(f"{FARM}/libs/keep.squashfs", "k")
    os.rename(f"{FARM}/themes", f"{T}/themes-elsewhere")
    os.symlink(f"{T}/themes-elsewhere", f"{FARM}/themes")
    call("sync")
    c(os.path.isdir(f"{FARM}/themes") and not os.path.islink(f"{FARM}/themes"), "a linked real dir kept as a link")
    stale = sorted(os.listdir(f"{STATE}/stale"))
    c(len(stale) == 1 and sorted(os.listdir(f"{STATE}/stale/{stale[0]}")) == ["pylibs", "stray.txt"], f"stale {stale}")
    c(not os.path.lexists(f"{FARM}/gone") and os.readlink(f"{FARM}/control.txt") == f"{TREE}/control.txt", "links")
    c(os.path.islink(f"{FARM}/pylibs"), "pylibs link")
    c(os.path.exists(f"{FARM}/device_info_blockie_invented.env") and rd(f"{FARM}/config/020_portmaster.source.json") == "edited",
      "same stamp dropped files")
    write(f"{USR}/tree.sha256", "stamp-b\n")
    call("sync")
    c(not os.path.exists(f"{FARM}/device_info_blockie_invented.env"), "device_info kept over a stamp change")
    c(rd(f"{FARM}/config/020_portmaster.source.json") == '{"prefix": "pm", "name": "Invented One"}\n', "sources kept")
    c(rd(f"{FARM}/libs/keep.squashfs") == "k" and rd(f"{STATE}/tree.sha256") == "stamp-b\n", "libs or stamp")
    write(f"{FARM}/device_info_blockie_invented.env", "X=1\n")
    write(f"{FARM}/config/021_portmaster.multiverse.source.json", "edited")
    write(f"{USR}/tree.sha256", "stamp-a\n")
    call("sync")
    c(not os.path.exists(f"{FARM}/device_info_blockie_invented.env") and rd(f"{STATE}/tree.sha256") == "stamp-a\n"
      and rd(f"{FARM}/config/021_portmaster.multiverse.source.json").startswith('{"prefix": "pmmv"'),
      "a rollback to the older stamp did not resync")
    for i in range(5):
        write(f"{FARM}/stray{i}", "x")
        call("sync")
    stale = sorted(os.listdir(f"{STATE}/stale"))
    c(len(stale) == 3 and os.listdir(f"{STATE}/stale/{stale[-1]}") == ["stray4"], f"stale kept {stale}")
    c(len(hmlog("open")) == 0, "sync opened harbourmaster")


WP = "0a761c28877625861d9c9c4326664428"
XKB = "lib_aarch64/libxkbcommon.so.0"


def wp_unpack(digest, hide=True):
    f = f"{LIBS}/weston_pkg_0.2.squashfs"
    if not os.path.exists(f):
        mkzip(f, {"westonwrap.sh": ("#!/bin/sh\n", 0o755), XKB: "invented xkb",
                  "lib_aarch64/libxkbcommon-x11.so.0": "invented xkb x11", "lib_aarch64/libweston-14.so.0": "invented"})
    saved = m.HIDE
    if not hide:
        m.HIDE = {}
    r, w = os.pipe()
    try:
        m.unpack_tree(f, digest, m.Proto(w))
    finally:
        m.HIDE = saved
        os.close(w)
        os.close(r)
    return f"{UNPACKED}/{digest}"


def xkb_state(tree):
    p = f"{tree}/{XKB}"
    return os.path.lexists(p), os.path.lexists(p + ".blockie-hidden"), mode(f"{tree}/lib_aarch64")


@case("the xkbcommon hide at unpack: under the listed md5 libxkbcommon.so.0 is renamed before the seal, "
      "libxkbcommon-x11.so.0 stays, another md5 keeps its libxkbcommon.so.0")
def _(c):
    reset()
    tree = wp_unpack(WP)
    c(xkb_state(tree) == (False, True, 0o555), f"listed {xkb_state(tree)}")
    c(mode(f"{tree}/{XKB}.blockie-hidden") == 0o444, "the hidden file is not sealed")
    c(os.path.isfile(f"{tree}/lib_aarch64/libxkbcommon-x11.so.0"), "libxkbcommon-x11.so.0 hidden")
    c([r[0] for r in unindex()] == ["weston_pkg_0.2.squashfs"] and unindex()[0][4] == WP, f"index {unindex()}")
    other = wp_unpack(md5(f"{LIBS}/weston_pkg_0.2.squashfs"))
    c(xkb_state(other) == (True, False, 0o555), f"another md5 {xkb_state(other)}")


@case("the xkbcommon hide at sync, with no XDG_RUNTIME_DIR and no /run/user/<uid>: a tree unpacked before it is "
      "hidden, another md5 is left, the unpack index is byte identical, idempotent")
def _(c):
    reset()
    call("sync")
    tree = wp_unpack(WP, hide=False)
    other = wp_unpack(md5(f"{LIBS}/weston_pkg_0.2.squashfs"))
    before = open(f"{UNPACKED}/index.tsv", "rb").read()
    c(xkb_state(tree) == (True, False, 0o555), f"before {xkb_state(tree)}")
    c(not os.path.exists(f"/run/user/{os.getuid()}"), f"/run/user/{os.getuid()} exists, the case does not hold")
    env = {k: v for k, v in os.environ.items() if k != "XDG_RUNTIME_DIR"}
    for i in range(2):
        os.remove(f"{STATE}/index.tsv")
        r = sub("sync", env=env)
        c(r.returncode == 0 and r.stdout == "done\tsync\n", f"sync {i} {r.stdout!r} {r.stderr[-400:]}")
        c(("hid lib_aarch64/libxkbcommon.so.0" in r.stderr) == (i == 0), f"sync {i} log {r.stderr[-400:]}")
        c(xkb_state(tree) == (False, True, 0o555), f"sync {i} {xkb_state(tree)}")
        c(xkb_state(other) == (True, False, 0o555), f"sync {i} another md5 {xkb_state(other)}")
        c(os.path.isfile(f"{tree}/lib_aarch64/libxkbcommon-x11.so.0"), f"sync {i} hid libxkbcommon-x11.so.0")
        c(open(f"{UNPACKED}/index.tsv", "rb").read() == before, f"sync {i} changed the unpack index")
        c(os.path.isfile(f"{STATE}/index.tsv"), f"sync {i} wrote no index")


@case("the xkbcommon hide: a sync stopped with the dir 0755 or after the rename is finished by the next sync; "
      "a refused rename is logged, the sync still writes the index and the next one hides")
def _(c):
    reset()
    call("sync")
    tree = wp_unpack(WP, hide=False)
    d = f"{tree}/lib_aarch64"
    os.chmod(d, 0o755)
    rc, lines = call("sync")
    c(rc == 0 and xkb_state(tree) == (False, True, 0o555), f"dir 0755 with the name {lines} {xkb_state(tree)}")
    os.chmod(d, 0o755)
    rc, lines = call("sync")
    c(rc == 0 and xkb_state(tree) == (False, True, 0o555), f"hidden with the dir 0755 {lines} {xkb_state(tree)}")
    os.chmod(d, 0o755)
    os.rename(f"{tree}/{XKB}.blockie-hidden", f"{tree}/{XKB}")
    os.chmod(d, 0o555)
    os.remove(f"{STATE}/index.tsv")
    real = os.rename

    def deny(a, b, *args, **kw):
        if str(a).endswith(XKB):
            raise PermissionError(13, "invented denial", a)
        return real(a, b, *args, **kw)

    LOG.clear()
    os.rename = deny
    try:
        rc, lines = call("sync")
    finally:
        os.rename = real
    c(rc == 0 and lines == ["done\tsync"] and os.path.isfile(f"{STATE}/index.tsv"), f"refused {lines}")
    c(any("cannot hide lib_aarch64/libxkbcommon.so.0" in x for x in LOG), f"log {LOG}")
    c(xkb_state(tree)[:2] == (True, False), f"refused {xkb_state(tree)}")
    rc, lines = call("sync")
    c(rc == 0 and xkb_state(tree) == (False, True, 0o555), f"after the refusal {lines} {xkb_state(tree)}")


@case("the real harbourmaster: after a stamp change, an offline open still loads both sources")
def _(c):
    tree = f"{REAL_USR}/PortMaster"
    if not c(REAL_USR and os.path.isdir(f"{tree}/pylibs/harbourmaster"), f"no PortMaster tree at {tree}"):
        return
    real = f"{T}/real"
    m.remove(real)
    ports = f"{real}/roms/ports"
    farm = f"{ports}/PortMaster"
    write(f"{farm}/config/config.json", json.dumps({"version": 2, "first-run": False, "theme": "default_theme",
                                                   "show_experimental": False}))
    write(f"{ports}/.blockie/tree.sha256", "invented old stamp\n")
    os.makedirs(f"{real}/cache/ports-tmp", 0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BLOCKIE_PORTS_", "PYTHON"))}
    env.update(BLOCKIE_PORTS_DATA=real, BLOCKIE_PORTS_MOUNT="/", HOME=f"{T}/home", CFW_NAME="Blockie",
               DEVICE_CAPABILITIES="aarch64 power 960x720")
    r = sub("sync", env=env)
    c(r.returncode == 0 and r.stdout == "done\tsync\n", f"sync {r.stdout!r} {r.stderr[-600:]}")
    names = sorted(n for n in os.listdir(f"{farm}/config") if n.endswith(".source.json"))
    c(names == ["020_portmaster.source.json", "021_portmaster.multiverse.source.json"], f"sources {names}")
    code = ("import sys, tempfile\n"
            f"sys.path[:0] = [{tree + '/pylibs'!r}, {tree + '/exlibs'!r}]\n"
            "from pathlib import Path\n"
            "import harbourmaster\n"
            "hm = harbourmaster.HarbourMaster({'offline': True, 'no-check': True, 'quiet': True, 'debug': False},\n"
            "    temp_dir=Path(tempfile.mkdtemp()), callback=harbourmaster.Callback())\n"
            "print(' '.join(sorted(hm.sources)))\n")
    env.update(HM_TOOLS_DIR=ports, HM_PORTS_DIR=ports, HM_SCRIPTS_DIR=ports, controlfolder=farm)
    r = subprocess.run([sys.executable, "-I", "-S", "-c", code], capture_output=True, text=True, env=env, cwd=ports,
                       timeout=120)
    c(r.returncode == 0 and r.stdout.splitlines()[-1:] == ["pm pmmv"], f"open {r.stdout[-200:]!r} {r.stderr[-600:]}")


print(f"ports-helper: {fails} failed" if fails else "ports-helper: python cases ok", flush=True)
sys.exit(1 if fails else 0)
