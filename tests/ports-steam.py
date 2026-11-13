#!/usr/bin/env python3
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import traceback

sys.dont_write_bytecode = True
BIN = os.environ["PORTS_BIN"]
FAKE = os.environ["FAKE_HM"]
FIX = os.environ["FIXTURES"]
T = os.environ["T"]
ME = pwd.getpwuid(os.getuid()).pw_name
DATA = f"{T}/data"
PORTS = f"{DATA}/roms/ports"
STATE = f"{PORTS}/.blockie"
SSTATE = f"{STATE}/steam"
DL = f"{DATA}/steam-dl"
SDIR = f"{DATA}/steam"
SRUN = f"{T}/srun"
RUN = f"{T}/run"
USR = f"{T}/usr"
BINS = f"{T}/bin"
DDJSON = f"{T}/dd.json"
DDLOG = f"{T}/dd.log"
TOKEN = "tok-invented-0000"
URL = "https://s.team/q/1/1111111111111111111"
os.makedirs(BINS, exist_ok=True)
for n in ("fake-dd", "fake-systemctl", "fake-inhibit", "fake-setpriv"):
    shutil.copyfile(f"{FIX}/{n}", f"{BINS}/{n}")
    os.chmod(f"{BINS}/{n}", 0o755)
with open(f"{BINS}/nmcli", "w") as f:
    f.write(f"#!/bin/sh\ncat {T}/nm\n")
os.chmod(f"{BINS}/nmcli", 0o755)
os.environ.update({
    "BLOCKIE_PORTS_DATA": DATA, "BLOCKIE_PORTS_MOUNT": "/", "BLOCKIE_PORTS_USR": USR,
    "BLOCKIE_PORTS_PYLIBS": FAKE, "BLOCKIE_PORTS_EXLIBS": FAKE, "BLOCKIE_PORTS_SYSTEMCTL": f"{BINS}/fake-systemctl",
    "BLOCKIE_PORTS_NMCLI": f"{BINS}/nmcli", "BLOCKIE_PORTS_FLOOR": "0", "BLOCKIE_PORTS_WAIT_S": "1",
    "XDG_RUNTIME_DIR": RUN, "BLOCKIE_PORTS_STEAM_MAP": f"{USR}/steam-map.tsv",
    "BLOCKIE_PORTS_STEAM_LISTS": f"{USR}/steam-files", "BLOCKIE_PORTS_DD": f"{BINS}/fake-dd",
    "BLOCKIE_PORTS_STEAM_RUN": SRUN, "BLOCKIE_PORTS_STEAM_USER": ME, "BLOCKIE_PORTS_USER": ME,
    "BLOCKIE_PORTS_INHIBIT": f"{BINS}/fake-inhibit", "BLOCKIE_PORTS_SETPRIV": f"{BINS}/fake-setpriv",
    "FAKE_T": T, "FAKE_DD": DDJSON, "FAKE_DD_LOG": DDLOG, "FAKE_HM_WORLD": f"{T}/world.json",
    "BLOCKIE_DD_CONFIG": f"{SDIR}/account.config",
})
loader = importlib.machinery.SourceFileLoader("ports", BIN)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("ports", loader))
loader.exec_module(m)
LOG = []
m.log = LOG.append
FREE = m.free_bytes
SYNC = os.sync
fails = 0
GAME = {"gamedata/game.exe": {"data": "invented exe", "exec": True}, "gamedata/data.win": {"data": "invented data"},
        "gamedata/music/a.ogg": {"data": "invented music"}}


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
        subprocess.run([f"{BINS}/fake-systemctl", "stop", "blockie-steam-dd@*.service"], capture_output=True, timeout=60)
        m.FLOOR = 0
        m.free_bytes = FREE
        m.LOGIN_S = 300
        m.STALL_S = 120
        m.BATCH = 256 << 20
        os.sync = SYNC
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


def sha1(s):
    return hashlib.sha1(s.encode()).hexdigest()


ROW = "alpha.zip\t-\t900001\twindows\t900011\t-\t-\talpha\t-\t-\t-\t-"


def setup(world=None, rows=(ROW,), apps=("alpha.zip\t900001\t" + "a" * 32,), lists=None, signed=False):
    os.chdir(T)
    for p in (DATA, SRUN, RUN, USR, f"{T}/units"):
        if os.path.lexists(p):
            shutil.rmtree(p)
    for p in (DDLOG, f"{T}/systemctl.log", f"{T}/inhibit.log", f"{T}/unit.log", f"{T}/dd-pass.count",
              f"{T}/dd-get.count", f"{T}/inhibit-refused", f"{T}/start-fails", f"{T}/start-noexec"):
        if os.path.lexists(p):
            os.unlink(p)
    for d in (SSTATE, SDIR, DL, f"{SRUN}/req", RUN, f"{USR}/steam-files", f"{DATA}/cache/ports-tmp"):
        os.makedirs(d)
    os.chmod(DL, 0o2750)
    write(f"{T}/nm", "wifi:connected\n")
    write(f"{T}/scope-rc", "3\n")
    write(f"{USR}/steam-map.tsv", "".join(r + "\n" for r in rows))
    for n, lines in (lists or {}).items():
        write(f"{USR}/steam-files/{n}", "".join(x + "\n" for x in lines))
    write(f"{SSTATE}/apps.tsv", "".join(a + "\n" for a in apps))
    write(f"{PORTS}/alpha/port.json", json.dumps({"name": "alpha.zip", "items": ["Alpha.sh", "alpha"]}))
    write(f"{PORTS}/Alpha.sh", "#!/bin/bash\n", 0o755)
    w = {"files": GAME, "pass": [{}], "get": [{}], "token": TOKEN}
    w.update(world or {})
    with open(DDJSON, "w") as f:
        json.dump(w, f)
    if signed:
        save_token()
    LOG.clear()
    return w


def save_token():
    key, val = b"invented-account", TOKEN.encode()
    entry = b"\x0a" + bytes([len(key)]) + key + b"\x12" + bytes([len(val)]) + val
    c = __import__("zlib").compressobj(wbits=-15)
    write(f"{SDIR}/account.config", c.compress(b"\x22" + bytes([len(entry)]) + entry) + c.flush(), 0o600)
    unit("status")


def unit(op, inst="account", **kw):
    req = dict(op=op, port=None if inst == "account" else inst, **kw)
    write(f"{SRUN}/req/{inst}", json.dumps(req), 0o640)
    return subprocess.run([BIN, "steam-unit", inst], capture_output=True, text=True, timeout=60)


def call(*args):
    r, w = os.pipe()
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            rc = m.run(["blockie-ports", *args], m.Proto(w))
    finally:
        os.close(w)
    with os.fdopen(r) as f:
        return rc, f.read().splitlines()


def sub(*args, **kw):
    return subprocess.Popen([BIN, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, **kw)


def dd_runs(op=None):
    try:
        rows = [json.loads(x) for x in rd(DDLOG).splitlines()]
    except FileNotFoundError:
        return []
    return [r for r in rows if op is None or r["op"] == op]


def last(lines):
    return lines[-1] if lines else ""


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def tsv():
    return rd(f"{STATE}/steam.tsv").splitlines()


def everything():
    out = []
    for root, dirs, files in os.walk(T):
        for f in files:
            p = os.path.join(root, f)
            if p == DDJSON or p.startswith((f"{SDIR}/", f"{BINS}/")) or not os.path.isfile(p):
                continue
            try:
                out.append((p, open(p, "rb").read()))
            except OSError:
                pass
    return out


LINE = re.compile(r"progress\t(?:login|check|download|copy)\t[0-9]+\t(?:[0-9]+|-)|qr\thttps://[\x21-\x7e]+|"
                  r"done\t[^\t]+|fail\t[^\t]+\t(?:login|owned|expired|exists|network|space|busy|nodata|cancel|other)")


@case("map loader: a good row is kept, rows with .., an absolute path, bad digits, an unknown os or depots - are dropped")
def _(c):
    setup(rows=(ROW, "beta.zip\t-\t900002\twindows\t900021\t-\t-\tbeta/../x\t-\t-\t-\t-",
                "gamma.zip\t-\t900003\twindows\t900031\t-\t-\t/abs\t-\t-\t-\t-",
                "delta.zip\t-\t9000x4\twindows\t900041\t-\t-\tdelta\t-\t-\t-\t-",
                "eps.zip\t-\t900005\tbeos\t900051\t-\t-\teps\t-\t-\t-\t-",
                "zeta.zip\t-\t900006\twindows\t-\t-\t-\tzeta\t-\t-\t-\t-",
                "eta.zip\t-\t900007\twindows\t900071\t1,2\t-\teta\t-\t-\t-\t-",
                "theta.zip\t-\t900008\twindows\t900081\t-\t-\ttheta\t-\t-\t-\ttheta/../../x"))
    rows = m.load_map()
    c(set(rows) == {"alpha.zip"}, f"rows {sorted(rows)}")
    c(sum("steam map: line" in x for x in LOG) == 7, f"log {LOG}")


@case("steam.tsv: signed from the flag only, get for an offered row, nothing for an app id or V md5 mismatch")
def _(c):
    setup(rows=(ROW, "beta.zip\t" + "b" * 32 + "\t900002\twindows\t900021\t-\t-\tbeta\t-\t-\t-\t-",
                "gamma.zip\t-\t900003\twindows\t900031\t-\t-\tgamma\t-\t-\t-\t-",
                "delta.zip\t" + "d" * 32 + "\t900004\twindows\t900041\t-\t-\tdelta\t-\t-\t-\t-"),
          apps=("alpha.zip\t900001\t" + "a" * 32, "beta.zip\t900002\t" + "c" * 32, "gamma.zip\t900099\t" + "e" * 32,
                "delta.zip\t900004\t" + "d" * 32))
    for n in ("beta", "gamma", "delta"):
        write(f"{PORTS}/{n}/port.json", json.dumps({"name": f"{n}.zip", "items": [n]}))
    rc, lines = call("index")
    c(tsv() == ["signed\t0", "port\talpha.zip\tget", "port\tdelta.zip\tget"], f"tsv {tsv()}")
    write(f"{DL}/signed", "signed 1\n")
    call("index")
    c(tsv()[0] == "signed\t1", f"flag {tsv()[:1]}")
    write(f"{SSTATE}/alpha.zip.owned", "")
    call("index")
    c("port\talpha.zip\tget" not in tsv(), ".owned did not hide the row")
    write(f"{SDIR}/account.config", "invented garbage")
    unit("status")
    c(rd(f"{DL}/signed") == "signed 0\n", f"a corrupt account file read as signed: {rd(f'{DL}/signed')!r}")


def first_get(c, world=None):
    w = setup(world)
    write(f"{SSTATE}/beta.zip.owned", "")
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and last(lines) == "done\talpha.zip", f"rc {rc} {lines[-3:]} {LOG[-6:]}")
    return w, lines


@case("first get with no token: login 0 -, the code, seconds, check, download, copy, the files placed, got")
def _(c):
    w, lines = first_get(c, {"pass": [{"qr": [URL, URL[:-1] + "2"], "qr_gap": 1.3}]})
    c(all(LINE.fullmatch(x) for x in lines), f"lines {[x for x in lines if not LINE.fullmatch(x)]}")
    kinds = [x.split("\t")[1] if x.startswith("progress") else x.split("\t")[0] for x in lines]
    c(lines[0] == "progress\tlogin\t0\t-", f"first {lines[:1]}")
    c("progress\tlogin\t0\t300" in lines and "progress\tlogin\t1\t300" in lines, "no login seconds")
    c(lines.count(f"qr\t{URL}") == 1 and f"qr\t{URL[:-1]}2" in lines, "qr lines")
    order = [k for i, k in enumerate(kinds) if i == 0 or kinds[i - 1] != k]
    c(order[-4:] == ["check", "download", "copy", "done"], f"order {order}")
    for p, v in GAME.items():
        f = f"{PORTS}/alpha/{p}"
        c(os.path.isfile(f) and rd(f) == v["data"] and os.stat(f).st_uid == os.getuid(), f"{p} not placed")
    c(os.stat(f"{PORTS}/alpha/gamedata/game.exe").st_mode & 0o111 == 0o111, "exec bit lost")
    c(stat.S_IMODE(os.stat(f"{PORTS}/alpha/gamedata/data.win").st_mode) == 0o644, "data mode")
    got = json.loads(rd(f"{SSTATE}/alpha.zip.got"))
    c(got["digest"] == m.load_map()["alpha.zip"]["digest"] and sorted(got["placed"]) == sorted(f"alpha/{p}" for p in GAME),
      f"got {got}")
    c(tsv() == ["signed\t1", "port\talpha.zip\tgot"], f"tsv {tsv()}")
    c(not [x for x in os.listdir(DL) if x.startswith("alpha.zip.")], f"steam-dl left {os.listdir(DL)}")
    c(not os.listdir(f"{STATE}/txn"), "journal left")
    c(not os.path.exists(f"{SSTATE}/beta.zip.owned"), "the sign in left an owned mark")
    runs = dd_runs()
    c([r["op"] for r in runs] == ["pass", "get"], f"runs {[r['op'] for r in runs]}")
    c("-qr" in runs[0]["args"] and "-username" not in runs[0]["args"] and "-manifest-only" in runs[0]["args"],
      f"pass args {runs[0]['args']}")
    blob = b"".join(d for p, d in everything())
    c(TOKEN.encode() not in blob, "the token is outside the account file")
    c(URL.encode() not in b"".join(d for p, d in everything() if not p.endswith("dd.log")) and
      not any(URL in x for x in LOG), "the URL is in a log, mark or file")


@case("second get with the token: no code, no -username, -remember-password without -qr")
def _(c):
    setup(signed=True)
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and not [x for x in lines if x.startswith(("qr\t", "progress\tlogin"))], f"{lines}")
    a = dd_runs("pass")[0]["args"]
    c("-qr" not in a and "-username" not in a and "-remember-password" in a, f"args {a}")


@case("a rejected token: one QR retry in the same command, then a second rejection is login")
def _(c):
    setup({"pass": [{"reject": True}, {}]}, signed=True)
    m.LOGIN_S = 10
    rc, lines = call("steam-get", "alpha.zip")
    runs = dd_runs("pass")
    c(rc == 0 and len(runs) == 2 and "-qr" not in runs[0]["args"] and "-qr" in runs[1]["args"], f"{lines[-2:]} {runs}")
    setup({"pass": [{"reject": True}, {"fail": "login"}]}, signed=True)
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tlogin" and len(dd_runs("pass")) == 2, f"{lines[-2:]}")


@case("qr lines: a tab, a space, 0x7f, 513 bytes and http:// are refused and logged as qr refused <len> only")
def _(c):
    bad = ["https://s.team/q/1/1\t1", "https://s.team/q/1/1 1", "https://s.team/q/1/1\x7f1",
           "https://" + "a" * 505, "http://s.team/q/1/1111"]
    setup({"pass": [{"qr": bad + [URL]}]})
    rc, lines = call("steam-get", "alpha.zip")
    qrs = [x for x in lines if x.startswith("qr\t")]
    c(qrs == [f"qr\t{URL}"], f"qr {qrs}")
    refused = [x for x in LOG if x.startswith("qr refused")]
    c(len(refused) == 5 and all(re.fullmatch(r"qr refused [0-9]+", x) for x in refused), f"log {refused}")
    hosts = [x for x in LOG if "s.team" in x]
    c(hosts == [f"qr host s.team len {len(URL)}"], f"a URL in the log {hosts}")


def outcome_case(c, world, want, mark=None, **kw):
    setup(world, signed=kw.get("signed", True))
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == f"fail\talpha.zip\t{want}", f"{world}: {lines[-2:]} {LOG[-4:]}")
    if mark is not None:
        c(os.path.exists(f"{SSTATE}/alpha.zip.owned") == mark, f"{world}: owned mark {not mark}")
    return lines


@case("child outcomes: owned (marked), owned depot with or without its id (no mark, the helper's line three fields), a "
      "five field or non digits owned depot line as other, depot and branch as other, expired, network, rate as "
      "network, space, other")
def _(c):
    outcome_case(c, {"pass": [{"fail": "owned"}]}, "owned", True)
    outcome_case(c, {"pass": [{"fail": "owned depot"}]}, "owned", False)
    lines = outcome_case(c, {"pass": [{"fail": "owned depot 9000101"}]}, "owned", False)
    c(len(last(lines).split("\t")) == 3, f"the helper's line {last(lines)!r}")
    outcome_case(c, {"pass": [{"fail": "owned depot 9000101 9"}]}, "other", False)
    outcome_case(c, {"pass": [{"fail": "owned depot x9000101"}]}, "other", False)
    outcome_case(c, {"pass": [{"fail": "network depot 9000101"}]}, "other", False)
    outcome_case(c, {"pass": [{"fail": "depot"}]}, "other")
    c(any("map row does not match" in x for x in LOG), "depot not logged as a map row bug")
    outcome_case(c, {"pass": [{"fail": "branch"}]}, "other")
    outcome_case(c, {"pass": [{"approve": False}]}, "expired", signed=False)
    outcome_case(c, {"pass": [{"fail": "network"}]}, "network")
    outcome_case(c, {"get": [{"fail": "rate"}]}, "network")
    outcome_case(c, {"get": [{"fail": "space"}]}, "space")
    outcome_case(c, {"pass": [{"fail": "other"}]}, "other")
    outcome_case(c, {"pass": [{"noend": True}]}, "other")
    outcome_case(c, {"get": [{"noend": True}]}, "other")
    outcome_case(c, {"get": [{"rc": 1}]}, "other")


@case("a fail rate from DepotDownloader in a pass ends the run at once; the unit relays it as rate, the helper as "
      "network")
def _(c):
    setup({"pass": [{"fail": "rate"}]}, signed=True)
    r, w = os.pipe()
    t0 = time.monotonic()
    try:
        run = m.steam_dd(m.Proto(w), "pass", "alpha.zip", "token")
    finally:
        os.close(w)
        os.close(r)
    c(run.fail == "rate" and run.rc == 1 and time.monotonic() - t0 < 10, f"{run.fail} {run.rc} {LOG[-3:]}")
    c(m.outcome(run, "alpha.zip", "pass") == "network", "rate not mapped to network")


@case("library scan through the unit: the 3 field path line is cached and kept to the unit, scan, scanned and "
      "scanfail forwarded; a 2 field path line ends other with nothing cached")
def _(c):
    lib = ["app\t9000001\tgame\tInvented", "owned\t9000001", "lang\t9000001\t-",
           "depot\t9000001\t9000011\t-\t-\t-\t0\t-\t-\t900001100\t1",
           "depot\t9000001\t9000012\t-\t64\t-\t0\t-\t-\t900001200\t1"]
    for paths, want in ((["a.bin", "b/c.bin"], "done\tscan"), (["path\t1"], "fail\tscan\tother")):
        setup({"lines": lib, "scans": {"9000011": {"paths": paths}, "9000012": {"fail": "owned"}}}, signed=True)
        m.unit_library_done(lib, int(time.time()))
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
            rc, lines = call("steam-lib", "scan")
        finally:
            os.read = real
        sent = {x.split("\t")[0] for x in b"".join(got).decode("utf-8", "replace").splitlines() if x}
        c(last(lines) == want, f"{paths}: {lines[-2:]} {LOG[-3:]}")
        if want == "done\tscan":
            c(m.read_paths("9000011", "900001100") == [("a.bin", 1), ("b/c.bin", 1)], "not cached")
            c(sent == {"scan", "scanned", "scanfail", "end", "rc"}, f"forwarded {sent}")
            c({d: e["kind"] for (d, g), e in m.read_scanfail().items()} == {"9000012": "owned"}, "scanfail")
        else:
            c(m.read_paths("9000011", "900001100") is None and "path" not in sent, f"cached or forwarded {sent}")


@case("a crash with no fail line: other, or space under the floor; .DepotDownloader dropped once, then the get runs")
def _(c):
    setup({"get": [{}]}, signed=True)
    os.makedirs(f"{DL}/alpha.zip.part/.DepotDownloader")
    write(f"{DL}/alpha.zip.part/.DepotDownloader/depot.config", "bad")
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tother", f"{lines[-1:]}")
    c(not os.path.exists(f"{DL}/alpha.zip.part/.DepotDownloader") and os.path.exists(f"{SSTATE}/alpha.zip.dropped"),
      "not dropped")
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and not os.path.exists(f"{SSTATE}/alpha.zip.dropped"), f"next get {lines[-1:]}")
    setup({"get": [{"crash": True}]}, signed=True)
    seq = [1 << 51, 1 << 51, 0, 0, 0, 0]
    m.free_bytes = lambda: seq.pop(0) if seq else 0
    m.FLOOR = 1 << 40
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tspace", f"crash under the floor {lines[-1:]}")


@case("the floor by blocks: a sparse part dir counts its blocks, the batch peak is added, statvfs stops a download")
def _(c):
    setup(signed=True)
    os.makedirs(f"{DL}/alpha.zip.part/gamedata")
    with open(f"{DL}/alpha.zip.part/gamedata/data.win", "wb") as f:
        f.truncate(1 << 30)
    need = sum(len(v["data"]) for v in GAME.values())
    m.BATCH = 1000
    m.free_bytes = lambda: need + 1010
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tspace" and not dd_runs("get"), f"sparse size or batch peak not counted {lines[-1:]}")
    m.free_bytes = lambda: need + 1020
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0, f"the floor refused with room for the batch {lines[-1:]}")
    setup({"get": [{"got_for": 5}]}, signed=True)
    calls = [0]

    def free():
        calls[0] += 1
        return (1 << 40) if calls[0] < 3 else 10
    m.FLOOR = 1000
    m.free_bytes = free
    t0 = time.monotonic()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tspace" and time.monotonic() - t0 < 5, f"statvfs stop {lines[-1:]}")


@case("merge: equal sha1 skipped, keep kept or placed, a foreign file refuses with nothing moved, a re-get replaces ours")
def _(c):
    keep_row = "alpha.zip\t-\t900001\twindows\t900011\t-\t-\talpha\t-\t-\talpha-keep\t-"
    setup(rows=(keep_row,), lists={"alpha-keep": ["gamedata/data.win", "gamedata/music/a.ogg"]}, signed=True)
    write(f"{PORTS}/alpha/gamedata/game.exe", GAME["gamedata/game.exe"]["data"])
    write(f"{PORTS}/alpha/gamedata/data.win", "the port's own data.win")
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0, f"{lines[-1:]} {LOG[-3:]}")
    a = dd_runs("get")[0]["args"]
    fl = a[a.index("-filelist") + 1] if "-filelist" in a else None
    c(fl is not None, f"no -filelist {a}")
    c(rd(f"{PORTS}/alpha/gamedata/data.win") == "the port's own data.win", "keep path replaced")
    c(rd(f"{PORTS}/alpha/gamedata/music/a.ogg") == "invented music", "absent keep path not placed")
    setup(signed=True)
    write(f"{PORTS}/alpha/gamedata/data.win", "a user file")
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\texists" and not dd_runs("get"), f"foreign file {lines[-1:]}")
    c(rd(f"{PORTS}/alpha/gamedata/data.win") == "a user file" and not os.path.exists(f"{PORTS}/alpha/gamedata/game.exe"),
      "something moved")
    setup(signed=True)
    rc, lines = call("steam-get", "alpha.zip")
    write(f"{PORTS}/alpha/gamedata/user.txt", "mine")
    w = json.loads(rd(DDJSON))
    w["files"]["gamedata/data.win"] = {"data": "invented data v2"}
    write(DDJSON, json.dumps(w))
    write(f"{USR}/steam-map.tsv", ROW.replace("\t-\t-\talpha\t", "\t900111\t-\talpha\t") + "\n")
    write(f"{T}/dd-get.count", "0")
    os.unlink(DDLOG)
    rc, lines = call("steam-get", "alpha.zip")
    if not c(dd_runs("get"), f"re-get ran no get {lines[-2:]} {LOG[-4:]}"):
        return
    a = dd_runs("get")[0]["args"]
    fl = a[a.index("-filelist") + 1] if "-filelist" in a else None
    c(rc == 0 and rd(f"{PORTS}/alpha/gamedata/data.win") == "invented data v2", f"re-get {lines[-1:]} {LOG[-3:]}")
    c(rd(f"{PORTS}/alpha/gamedata/user.txt") == "mine", "user file beside lost")
    c(fl is not None and not os.path.exists(f"{SSTATE}/alpha.zip.replaced"), f"re-get args {a}")
    c(dd_runs("get")[0]["filelist"] == ["gamedata/data.win"], f"re-get filelist {dd_runs('get')[0]['filelist']}")


@case("the download gets the pass's -manifest ids while the public manifest moves")
def _(c):
    setup({"public": {"900011": ["5551", "5552"]}}, signed=True)
    rc, lines = call("steam-get", "alpha.zip")
    a = dd_runs("get")[0]["args"]
    c(rc == 0 and a[a.index("-manifest") + 1] == "5551", f"get args {a}")
    shutil.rmtree(f"{PORTS}/alpha/gamedata")
    rc, lines = call("steam-get", "alpha.zip")
    a = dd_runs("get")[-1]["args"]
    c(rc == 0 and a[a.index("-manifest") + 1] == "5552", f"second get args {a}")


@case("prune and drift: a dropped path is pruned before the get, an entry outside the list is never copied")
def _(c):
    setup({"get": [{"extra": ["gamedata/stray.bin"]}]}, signed=True)
    write(f"{DL}/alpha.zip.part/gamedata/old.bin", "dropped by Steam")
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and not os.path.exists(f"{PORTS}/alpha/gamedata/old.bin") and
      not os.path.exists(f"{PORTS}/alpha/gamedata/stray.bin"), f"{lines[-1:]}")
    c(not os.path.exists(f"{DL}/alpha.zip.part"), "part dir left")


@case("copying: one os.sync per batch before its drop, progress copy 0 n before the sync, the sync before the journal")
def _(c):
    setup(signed=True)
    order = []
    m.BATCH = 1
    os.sync = lambda: order.append(("sync", sorted(os.listdir(f"{STATE}/txn")) if os.path.isdir(f"{STATE}/txn") else []))
    real = m.steam_op

    def op(inst, o, **kw):
        order.append((o, len(kw.get("paths") or [])))
        return real(inst, o, **kw)
    progress = m.Proto.progress

    def prog(self, what, done, total):
        order.append(("progress", what, done))
        return progress(self, what, done, total)
    m.steam_op = op
    m.Proto.progress = prog
    try:
        rc, lines = call("steam-get", "alpha.zip")
    finally:
        m.steam_op = real
        m.Proto.progress = progress
    c(rc == 0, f"{lines[-1:]}")
    first_sync = next(i for i, x in enumerate(order) if x[0] == "sync")
    c(order.index(("progress", "copy", 0)) < first_sync, f"progress copy 0 after the sync {order}")
    order = [x for x in order if x[0] != "progress"]
    seq = [x[0] for x in order]
    c(seq[:2] == ["clean", "sync"] and order[1][1] == [], f"first sync before the journal {order[:3]}")
    c(seq[2:] == ["sync", "drop", "sync", "drop", "sync", "drop", "clean"], f"batches {seq}")
    i = lines.index("progress\tcopy\t0\t3")
    c(i > 0 and lines[i + 1:i + 4] == ["progress\tcopy\t1\t3", "progress\tcopy\t2\t3", "progress\tcopy\t3\t3"], f"{lines[i:]}")


@case("copying refuses a symlink source and an existing dst outside the .got rule")
def _(c):
    setup(signed=True)
    write(f"{DL}/alpha.zip.list", "")
    os.makedirs(f"{DL}/alpha.zip.part/gamedata")
    os.symlink("/etc/passwd", f"{DL}/alpha.zip.part/gamedata/data.win")
    try:
        m.place("alpha.zip", "gamedata/data.win", "alpha/gamedata/data.win", 0)
        c(False, "a symlink source was copied")
    except OSError:
        pass
    write(f"{DL}/alpha.zip.part/gamedata/game.exe", "x")
    write(f"{PORTS}/alpha/gamedata/game.exe", "there")
    try:
        m.place("alpha.zip", "gamedata/game.exe", "alpha/gamedata/game.exe", 1)
        c(False, "EEXIST did not refuse")
    except m.Fail as err:
        c(err.why == "exists", f"why {err.why}")
    c(rd(f"{PORTS}/alpha/gamedata/game.exe") == "there" and not [x for x in os.listdir(f"{PORTS}/alpha/gamedata")
                                                               if x.startswith(".blockie-tmp-")], "dst or temp")


@case("unit operations: clean, drop, planted dirs and FIFOs, request symlinks, instance names, a blocking writer")
def _(c):
    setup()
    os.makedirs(f"{DL}/alpha.zip.part/gamedata")
    os.makedirs(f"{DL}/alpha.zip.check")
    os.makedirs(f"{DL}/beta.zip.del-1")
    write(f"{DL}/alpha.zip.list", f"file\t{sha1('x')}\t1\tgamedata/x\ntotal\t1\n")
    write(f"{DL}/alpha.zip.part/gamedata/x", "x")
    write(f"{DL}/alpha.zip.part/gamedata/y", "y")
    r = unit("drop", "alpha.zip", paths=["gamedata/y"])
    c(r.returncode == 1 and os.path.exists(f"{DL}/alpha.zip.part/gamedata/y"), "drop of an unlisted path")
    r = unit("drop", "alpha.zip", paths=["../alpha.zip.list"])
    c(r.returncode == 1 and os.path.exists(f"{DL}/alpha.zip.list"), "drop outside the part dir")
    r = unit("drop", "alpha.zip", paths=["gamedata/x"])
    c(r.returncode == 0 and not os.path.exists(f"{DL}/alpha.zip.part/gamedata/x"), "drop of a listed path")
    r = unit("clean", "alpha.zip")
    left = sorted(os.listdir(DL))
    c(r.returncode == 0 and left == ["beta.zip.del-1", "signed"], f"clean {left}")
    r = unit("clean")
    c(r.returncode == 0 and sorted(os.listdir(DL)) == ["signed"], f"portless clean {os.listdir(DL)}")
    write(f"{DL}/alpha.zip.part", "planted")
    write(f"{DL}/alpha.zip.list", f"manifest\t900011\t1000\nfile\t{sha1('x')}\t1\tgamedata/x\ntotal\t1\n")
    os.mkfifo(f"{SRUN}/alpha.zip.fifo")
    os.link(f"{SRUN}/alpha.zip.fifo", f"{T}/planted.fifo")
    planted = os.stat(f"{SRUN}/alpha.zip.fifo").st_ino
    write(f"{SRUN}/req/alpha.zip", json.dumps({"op": "get", "port": "alpha.zip", "login": "token"}), 0o640)
    p = subprocess.Popen([BIN, "steam-unit", "alpha.zip"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    fd = None
    end = time.monotonic() + 10
    while fd is None and time.monotonic() < end:
        try:
            if os.stat(f"{SRUN}/alpha.zip.fifo").st_ino != planted:
                fd = os.open(f"{SRUN}/alpha.zip.fifo", os.O_RDONLY | os.O_NONBLOCK)
        except FileNotFoundError:
            pass
        time.sleep(0.02)
    p.wait(timeout=20)
    got = b""
    if c(fd is not None, "the planted FIFO was not replaced"):
        time.sleep(0.1)
        got = os.read(fd, 4096)
        os.close(fd)
    c(p.returncode == 1 and got == b"fail\tother\n" and not dd_runs(), f"get over a planted file rc {p.returncode} {got!r}")
    os.unlink(f"{T}/planted.fifo")
    os.unlink(f"{SRUN}/alpha.zip.fifo")
    os.unlink(f"{DL}/alpha.zip.part")
    os.symlink(f"{T}/elsewhere", f"{SRUN}/req/alpha.zip.lnk")
    os.replace(f"{SRUN}/req/alpha.zip.lnk", f"{SRUN}/req/alpha.zip")
    write(f"{T}/elsewhere", json.dumps({"op": "clean", "port": "alpha.zip"}))
    os.makedirs(f"{DL}/alpha.zip.part")
    r = subprocess.run([BIN, "steam-unit", "alpha.zip"], capture_output=True, timeout=20)
    c(r.returncode == 1 and os.path.isdir(f"{DL}/alpha.zip.part"), "a symlinked request was read")
    for inst, why in (("Alpha.zip", "usage:"), ("../x.zip", "usage:"), ("alpha", "usage:"), ("beta.zip", "no Steam row")):
        write(f"{SRUN}/req/{inst.replace('/', '_')}", json.dumps({"op": "pass", "port": inst}), 0o640)
        t0 = time.monotonic()
        r = subprocess.run([BIN, "steam-unit", inst], capture_output=True, text=True, timeout=20)
        took = time.monotonic() - t0
        c(r.returncode != 0 and why in r.stderr and not dd_runs() and took < 2 and
          not [x for x in os.listdir(SRUN) if x.endswith(".fifo")], f"instance {inst}: rc {r.returncode} {took:.1f} s {r.stderr[-200:]!r}")
    setup({"get": [{"flood": 20000}]})
    write(f"{DL}/alpha.zip.list", f"manifest\t900011\t1000\nfile\t{sha1('x')}\t1\tgamedata/x\ntotal\t1\n")
    write(f"{SRUN}/req/alpha.zip", json.dumps({"op": "get", "port": "alpha.zip", "login": "token"}), 0o640)
    save_token()
    p = subprocess.Popen([BIN, "steam-unit", "alpha.zip"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.monotonic() + 10
    while not os.path.exists(f"{SRUN}/alpha.zip.fifo") and time.monotonic() < end:
        time.sleep(0.05)
    fd = os.open(f"{SRUN}/alpha.zip.fifo", os.O_RDONLY | os.O_NONBLOCK)
    time.sleep(3)
    c(p.poll() is None, "the writer exited while the reader stalled")
    p.kill()
    p.wait()
    os.close(fd)


@case("the helper refuses a FIFO not owned by the steam user and stops a running instance at start")
def _(c):
    setup(signed=True)
    m.STEAM_USER = "nobody" if ME != "nobody" else "root"
    try:
        rc, lines = call("steam-get", "alpha.zip")
    finally:
        m.STEAM_USER = ME
    c(last(lines) == "fail\talpha.zip\tother" and any("not a FIFO of" in x for x in LOG), f"{lines[-1:]} {LOG[-3:]}")
    log = [json.loads(x) for x in rd(f"{T}/systemctl.log").splitlines()]
    c(log[0] == ["stop", "blockie-steam-dd@*.service"], f"first systemctl {log[:2]}")


@case("no group write on the part dir after a run, a kill or a stop")
def _(c):
    setup({"get": [{"crash": True}]}, signed=True)
    call("steam-get", "alpha.zip")
    bad = [r for r, d, f in os.walk(DL) if os.stat(r).st_mode & 0o020]
    c(not bad, f"g+w {bad}")


def journal_case(c, cut):
    setup(signed=True)
    real = m.steam_op
    hits = [0]

    def op(inst, o, **kw):
        if o == "drop":
            hits[0] += 1
            if cut == "before-drop" or (cut == "after-drop" and hits[0] > 1):
                raise KeyboardInterrupt
        return real(inst, o, **kw)
    m.steam_op = op
    m.BATCH = 1
    try:
        call("steam-get", "alpha.zip")
    except KeyboardInterrupt:
        pass
    finally:
        m.steam_op = real
    return os.listdir(f"{STATE}/txn")


@case("replay: a cut before or after the drop finishes the copy, nothing moves aside, the next get is offered")
def _(c):
    for cut in ("before-drop", "after-drop"):
        left = journal_case(c, cut)
        c(left == ["steam-alpha.zip"], f"{cut}: journal {left}")
        ino = os.stat(f"{PORTS}/alpha/gamedata/data.win").st_ino
        with m.game_lock():
            m.replay()
        c(os.stat(f"{PORTS}/alpha/gamedata/data.win").st_ino == ino, f"{cut}: a placed dst was moved or copied again")
        c(not os.listdir(f"{STATE}/txn") and all(rd(f"{PORTS}/alpha/{p}") == v["data"] for p, v in GAME.items()),
          f"{cut}: replay did not finish")
        c(not os.path.exists(f"{SSTATE}/alpha.zip.replaced") and os.path.exists(f"{SSTATE}/alpha.zip.got"), f"{cut}: marks")
    journal_case(c, "before-drop")
    write(f"{PORTS}/alpha/gamedata/game.exe", "patched by the port")
    for p in ("gamedata/data.win",):
        os.unlink(f"{DL}/alpha.zip.part/{p}")
    write(f"{PORTS}/alpha/gamedata/data.win", "patched too")
    dead = subprocess.Popen(["true"])
    dead.wait()
    write(f"{PORTS}/alpha/gamedata/.blockie-tmp-{dead.pid}-9", "temp")
    write(f"{PORTS}/alpha/gamedata/.blockie-tmp-{os.getpid()}-9", "own")
    write(f"{PORTS}/alpha/gamedata/.blockie-tmp-{os.getppid()}-9", "live")
    with m.game_lock():
        m.replay()
    c(rd(f"{PORTS}/alpha/gamedata/data.win") == "patched too", "a dst whose source is gone was touched")
    c(rd(f"{PORTS}/alpha/gamedata/game.exe") == GAME["gamedata/game.exe"]["data"], "a differing dst was not copied again")
    c(not os.path.exists(f"{PORTS}/alpha/gamedata/.blockie-tmp-{dead.pid}-9") and
      not os.path.exists(f"{PORTS}/alpha/gamedata/.blockie-tmp-{os.getpid()}-9") and
      os.path.exists(f"{PORTS}/alpha/gamedata/.blockie-tmp-{os.getppid()}-9"),
      "temps: a dead or own pid's left, or another live pid's removed")
    os.unlink(f"{PORTS}/alpha/gamedata/.blockie-tmp-{os.getppid()}-9")
    m.journal("steam-alpha.zip", {"op": "steam", "name": "alpha.zip", "digest": "x", "placed": [], "replaced": [],
                                  "copies": [["a", "../../etc/x", 1, "0" * 40]]})
    with m.game_lock():
        m.replay()
    c(not os.listdir(f"{STATE}/txn") and any("dropped the unreadable journal" in x for x in LOG), "a raising replay kept")
    m.journal("steam-alpha.zip", {"op": "steam", "name": "alpha.zip", "digest": "x", "placed": [], "replaced": [],
                                  "copies": [["a", "gone/a", 1, "0" * 40]]})
    with m.game_lock():
        m.replay()
    c(not os.listdir(f"{STATE}/txn") and not os.path.exists(f"{PORTS}/gone"), "a journal for a port dir that is gone made it")


@case("a validation longer than the stall bound with got rising is not stalled; a silent token run is")
def _(c):
    setup({"get": [{"got_for": 3, "validate": True}]}, signed=True)
    m.STALL_S = 1
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0, f"rising got stalled {lines[-1:]}")
    setup({"pass": [{"loop": 10}]}, signed=True)
    m.STALL_S = 1
    t0 = time.monotonic()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tnetwork" and time.monotonic() - t0 < 8, f"loop {lines[-1:]}")


@case("the sign in: only the window bounds it, exp ends it with progress check at once, then the stall bound applies")
def _(c):
    setup({"pass": [{"qr": [URL, URL[:-1] + "2"], "qr_gap": 2}]})
    m.STALL_S = 1
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0, f"a slow refresh was stalled {lines[-2:]}")
    i = next(i for i, x in enumerate(lines) if x.startswith("progress\tcheck"))
    c(lines[i - 1].startswith(("qr\t", "progress\tlogin")) and lines[i] == "progress\tcheck\t0\t-", f"{lines[i - 2:i + 1]}")
    setup({"pass": [{"hold": 10}]})
    m.LOGIN_S = 2
    t0 = time.monotonic()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\texpired" and time.monotonic() - t0 < 8, f"window {lines[-1:]}")
    c(not os.path.exists(f"{SDIR}/account.config"), "a token from an expired sign in")
    setup({"pass": [{"loop": 10}]})
    m.STALL_S = 1
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tnetwork", f"stall from exp {lines[-1:]}")


@case("SIGTERM during the sign in, the download and copying")
def _(c):
    setup({"pass": [{"hold": 10}]})
    threading.Timer(1, os.kill, (os.getpid(), signal.SIGTERM)).start()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tcancel" and not os.path.exists(f"{SDIR}/account.config"), f"sign in {lines[-1:]}")
    setup({"get": [{"got_for": 10}]}, signed=True)
    threading.Timer(1.5, os.kill, (os.getpid(), signal.SIGTERM)).start()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tcancel" and not os.path.exists(f"{DL}/alpha.zip.part"), f"download {lines[-1:]}")
    gets = dd_runs("get")
    c(gets and not alive(gets[-1]["pid"]), "the fake DepotDownloader outlived the stop")
    setup(signed=True)
    real = m.place

    def slow(*a):
        os.kill(os.getpid(), signal.SIGTERM)
        return real(*a)
    m.place = slow
    try:
        rc, lines = call("steam-get", "alpha.zip")
    finally:
        m.place = real
    c(last(lines) == "fail\talpha.zip\tcancel" and os.listdir(f"{STATE}/txn") == ["steam-alpha.zip"], f"copy {lines[-1:]}")
    m.CANCEL[0] = False
    with m.game_lock():
        m.replay()
    c(all(rd(f"{PORTS}/alpha/{p}") == v["data"] for p, v in GAME.items()), "replay did not finish the copy")


@case("the idle sibling: held for the get, gone at exit and after a SIGKILL, refused goes on, the pid check")
def _(c):
    setup(signed=True)
    rc, lines = call("steam-get", "alpha.zip")
    inh = [json.loads(x) for x in rd(f"{T}/inhibit.log").splitlines()]
    c(rc == 0 and len(inh) == 1 and inh[0]["args"][:4] == ["--what=idle", "--mode=block", "--who=blockie-ports",
                                                           "--why=get files"], f"{inh}")
    c(inh[0]["stdout"] == "/dev/null", f"sibling stdout {inh[0]['stdout']}")
    time.sleep(0.3)
    c(not alive(inh[0]["pid"]) and not os.path.exists(f"{SSTATE}/inhibit.pid"), "sibling left")
    setup({"get": [{"got_for": 20}]}, signed=True)
    p = sub("steam-get", "alpha.zip")
    end = time.monotonic() + 15
    while not os.path.exists(f"{SSTATE}/inhibit.pid") and time.monotonic() < end:
        time.sleep(0.05)
    pid = int(rd(f"{SSTATE}/inhibit.pid"))
    time.sleep(1)
    c(alive(pid), "the sibling was not there during the get")
    p.kill()
    p.wait()
    time.sleep(0.5)
    c(not alive(pid), "the sibling outlived a SIGKILL of the helper")
    setup(signed=True)
    write(f"{T}/inhibit-refused", "")
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and any("went on without it" in x for x in LOG), f"refused {lines[-1:]}")
    shutil.copyfile("/bin/bash", f"{BINS}/inhibit-bash")
    os.chmod(f"{BINS}/inhibit-bash", 0o755)
    m.INHIBIT = f"{BINS}/inhibit-bash"
    m.SETPRIV = shutil.which("true")
    try:
        for who, killed in (("--who=blockie-ports", True), ("--who=other", False)):
            q = subprocess.Popen([m.INHIBIT, "-c", "sleep 30; :", who])
            write(f"{SSTATE}/inhibit.pid", str(q.pid))
            hold = m.idle_hold()
            m.idle_release(hold)
            time.sleep(0.2)
            c((q.poll() is not None) == killed, f"{who}: killed {q.poll() is not None}")
            q.kill()
            q.wait()
    finally:
        m.INHIBIT = f"{BINS}/fake-inhibit"
        m.SETPRIV = f"{BINS}/fake-setpriv"


@case("marks: a new digest, a missing check path or every placed path gone offers the row again")
def _(c):
    setup(signed=True)
    call("steam-get", "alpha.zip")
    c(tsv()[1:] == ["port\talpha.zip\tgot"], f"{tsv()}")
    write(f"{USR}/steam-map.tsv", ROW.replace("\t-\t-\t-\t-", "\t-\t-\t-\talpha/game.port") + "\n")
    call("index")
    c(tsv()[1:] == ["port\talpha.zip\tget"], f"check path {tsv()}")
    write(f"{PORTS}/alpha/game.port", "patched")
    shutil.rmtree(f"{PORTS}/alpha/gamedata")
    call("index")
    c(tsv()[1:] == ["port\talpha.zip\tgot"], f"a port that consumed its placed files with the check path {tsv()}")
    os.unlink(f"{PORTS}/alpha/game.port")
    call("steam-get", "alpha.zip")
    write(f"{PORTS}/alpha/game.port", "patched")
    write(f"{USR}/steam-map.tsv", ROW.replace("\t-\t-\talpha\t", "\t900222\t-\talpha\t") + "\n")
    call("index")
    c(tsv()[1:] == ["port\talpha.zip\tget"], f"digest {tsv()}")
    write(f"{USR}/steam-map.tsv", ROW + "\n")
    shutil.rmtree(f"{PORTS}/alpha/gamedata")
    call("index")
    c(tsv()[1:] == ["port\talpha.zip\tget"], f"placed gone {tsv()}")


@case("steam-logout: the unit's logout, signed 0, the owned marks cleared, done steam-logout")
def _(c):
    setup(signed=True)
    write(f"{SSTATE}/alpha.zip.owned", "")
    os.makedirs(f"{SDIR}/home/.config")
    rc, lines = call("steam-logout")
    c(rc == 0 and lines == ["done\tsteam-logout"], f"{lines}")
    c(not os.path.exists(f"{SDIR}/account.config") and not os.path.exists(f"{SDIR}/home"), "token or home left")
    c(rd(f"{DL}/signed") == "signed 0\n" and tsv()[0] == "signed\t0", "signed")
    c(not os.path.exists(f"{SSTATE}/alpha.zip.owned"), "owned mark left")
    write(f"{T}/start-fails", "")
    rc, lines = call("steam-logout")
    c(lines == ["fail\tsteam-logout\tother"], f"failure {lines}")


@case("no argv in any log after a forced TimeoutExpired and a CalledProcessError in a Steam command")
def _(c):
    setup(signed=True)
    real = m.steam_get
    for err in (subprocess.TimeoutExpired(["invented-argv", "--secret-arg"], 1),
                subprocess.CalledProcessError(1, ["invented-argv", "--secret-arg"])):
        def boom(*a, e=err):
            raise e
        m.steam_get = boom
        try:
            rc, lines = call("steam-get", "alpha.zip")
        finally:
            m.steam_get = real
        c(last(lines) == "fail\talpha.zip\tother", f"{lines[-1:]}")
    c(not any("invented-argv" in x or "secret-arg" in x for x in LOG), f"argv logged {LOG[-4:]}")


@case("the shipped map: every row loads, none dropped, each list file it names is there")
def _(c):
    shipped = os.environ.get("SHIPPED", "")
    if not c(os.path.isfile(f"{shipped}/steam-map.tsv"), f"no map at {shipped}"):
        return
    m.STEAM_MAP, m.STEAM_LISTS = f"{shipped}/steam-map.tsv", f"{shipped}/steam-files"
    try:
        LOG.clear()
        rows = m.load_map()
    finally:
        m.STEAM_MAP, m.STEAM_LISTS = f"{USR}/steam-map.tsv", f"{USR}/steam-files"
    n = len([x for x in rd(f"{shipped}/steam-map.tsv").splitlines() if x])
    c(len(rows) == n and not LOG, f"{len(rows)} of {n} rows, log {LOG[:3]}")
    named = {r["port"].removesuffix(".zip") + ".keep" for r in rows.values() if r["keep"]}
    c(named == set(os.listdir(f"{shipped}/steam-files")), "list files and rows differ")

@case("unit guards: a get path outside the list, a drop through a symlinked dir, a target through a symlinked dir")
def _(c):
    setup(signed=True)
    write(f"{DL}/alpha.zip.list", f"manifest\t900011\t1000\nfile\t{sha1('x')}\t1\tgamedata/x\ntotal\t1\n")
    write(f"{SRUN}/req/alpha.zip", json.dumps({"op": "get", "port": "alpha.zip", "login": "token",
                                               "paths": ["gamedata/y"]}), 0o640)
    p = subprocess.Popen([BIN, "steam-unit", "alpha.zip"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    end = time.monotonic() + 10
    while not os.path.exists(f"{SRUN}/alpha.zip.fifo") and time.monotonic() < end:
        time.sleep(0.02)
    fd = os.open(f"{SRUN}/alpha.zip.fifo", os.O_RDONLY | os.O_NONBLOCK)
    p.wait(timeout=20)
    time.sleep(0.1)
    got = os.read(fd, 4096)
    os.close(fd)
    c(p.returncode == 1 and got == b"fail\tother\n" and not dd_runs() and "not in the list" in p.stderr.read(),
      f"get path outside the list: rc {p.returncode} {got!r}")
    os.makedirs(f"{DL}/alpha.zip.part")
    os.makedirs(f"{T}/outside")
    write(f"{T}/outside/x", "outside")
    os.symlink(f"{T}/outside", f"{DL}/alpha.zip.part/gamedata")
    r = unit("drop", "alpha.zip", paths=["gamedata/x"])
    c(r.returncode == 1 and os.path.exists(f"{T}/outside/x"), "a drop followed a symlinked dir")
    shutil.rmtree(f"{T}/outside")
    setup(signed=True)
    os.makedirs(f"{T}/elsewhere-dir")
    os.symlink(f"{T}/elsewhere-dir", f"{PORTS}/alpha/gamedata")
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tother" and not os.listdir(f"{T}/elsewhere-dir"), f"into via a symlink {lines[-1:]}")
    shutil.rmtree(f"{T}/elsewhere-dir")


@case("the token and the account name the fake prints never reach a log, the protocol, a mark or a file")
def _(c):
    setup()
    rc, lines = call("steam-get", "alpha.zip")
    texts = LOG + lines + [d.decode("utf-8", "replace") for p, d in everything() if not p.endswith("dd.json")]
    c(rc == 0 and not [x for x in texts if TOKEN in x or "invented-account" in x], "token or account name leaked")


@case("more outcomes: end with no total, a unit that never opens the FIFO, an outside stop, a second crash")
def _(c):
    outcome_case(c, {"pass": [{"nototal": True}]}, "other")
    setup(signed=True)
    write(f"{T}/start-noexec", "")
    t0 = time.monotonic()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tother" and time.monotonic() - t0 < 15, f"no FIFO {lines[-1:]}")
    setup({"get": [{"got_for": 10}]}, signed=True)
    threading.Timer(1.5, subprocess.run, ([f"{BINS}/fake-systemctl", "stop", "blockie-steam-dd@alpha.zip.service"],),
                    {"timeout": 30}).start()
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tother" and not os.path.exists(f"{SSTATE}/alpha.zip.dropped"),
      f"outside stop {lines[-1:]}")
    setup({"get": [{}]}, signed=True)
    os.makedirs(f"{DL}/alpha.zip.part/.DepotDownloader")
    write(f"{DL}/alpha.zip.part/.DepotDownloader/depot.config", "bad")
    call("steam-get", "alpha.zip")
    write(f"{DL}/alpha.zip.part/.DepotDownloader/depot.config", "bad")
    rc, lines = call("steam-get", "alpha.zip")
    c(last(lines) == "fail\talpha.zip\tother" and os.path.exists(f"{DL}/alpha.zip.part/.DepotDownloader/depot.config"),
      f"a second crash dropped again {lines[-1:]}")


@case("the app id gate: an app id - in apps.tsv is no gate, a port missing from apps.tsv shows only without an md5")
def _(c):
    setup(rows=(ROW, "beta.zip\t" + "b" * 32 + "\t900002\twindows\t900021\t-\t-\tbeta\t-\t-\t-\t-",
                "gamma.zip\t-\t900003\twindows\t900031\t-\t-\tgamma\t-\t-\t-\t-"), apps=("alpha.zip\t-\t-",))
    for n in ("beta", "gamma"):
        write(f"{PORTS}/{n}/port.json", json.dumps({"name": f"{n}.zip", "items": [n]}))
    call("index")
    c(tsv()[1:] == ["port\talpha.zip\tget", "port\tgamma.zip\tget"], f"tsv {tsv()}")


@case("a 512 byte https code is shown")
def _(c):
    url = "https://" + "a" * 504
    setup({"pass": [{"qr": [url]}]})
    rc, lines = call("steam-get", "alpha.zip")
    c(rc == 0 and f"qr\t{url}" in lines and any(x == "qr host " + "a" * 64 + " len 512" or x.startswith("qr host - len 512")
                                                for x in LOG), f"{lines[:3]} {LOG[:4]}")


@case("the whole get with the unit as a second invented user: modes, owners, the FIFO owner check")
def _(c):
    user = "blockie-test-steam"
    if not c(os.getuid() == 0, "needs root to switch to the unit user"):
        return
    if subprocess.run(["id", user], capture_output=True).returncode != 0:
        r = subprocess.run(["useradd", "-r", "-M", "-s", "/sbin/nologin", user], capture_output=True, text=True)
        if not c(r.returncode == 0, f"useradd {r.stderr[-200:]}"):
            return
    pw = pwd.getpwnam(user)
    setup()
    p = T
    while p != "/":
        os.chmod(p, os.stat(p).st_mode | 0o011)
        p = os.path.dirname(p)
    os.makedirs(f"{T}/ddlog", exist_ok=True)
    os.chmod(f"{T}/ddlog", 0o1777)
    for d in (SDIR, DL, SRUN):
        os.chown(d, pw.pw_uid, 0)
    os.chmod(SDIR, 0o700)
    os.chmod(DL, 0o2750)
    os.chmod(SRUN, 0o2750)
    os.chown(f"{SRUN}/req", 0, pw.pw_gid)
    os.chmod(f"{SRUN}/req", 0o2750)
    env = {"FAKE_UNIT_USER": user, "FAKE_DD_LOG": f"{T}/ddlog/dd.log", "BLOCKIE_PORTS_STEAM_USER": user}
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    m.STEAM_USER = user
    try:
        rc, lines = call("steam-get", "alpha.zip")
    finally:
        m.STEAM_USER = ME
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    c(rc == 0 and last(lines) == "done\talpha.zip", f"{lines[-2:]} {LOG[-4:]}")
    st = os.stat(f"{SDIR}/account.config") if os.path.exists(f"{SDIR}/account.config") else None
    c(st is not None and st.st_uid == pw.pw_uid and stat.S_IMODE(st.st_mode) & 0o077 == 0, "token owner or mode")
    c(os.stat(f"{PORTS}/alpha/gamedata/data.win").st_uid == 0, "a placed file is not the helper's")
    c(rd(f"{DL}/signed") == "signed 1\n" and os.stat(f"{DL}/signed").st_uid == pw.pw_uid, "signed flag")


print(f"ports-steam: {fails} failed" if fails else "ports-steam: python cases ok", flush=True)
sys.exit(1 if fails else 0)
