#!/usr/bin/env python3
import errno
import fcntl
import importlib.machinery
import importlib.util
import json
import os
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import traceback

sys.dont_write_bytecode = True
BIN = os.environ["SCHED_BIN"]
RESTORE = os.environ["RESTORE_BIN"]
T = os.environ["T"]
NOSR = os.path.join(T, "no-systemd-run")
os.makedirs(NOSR, exist_ok=True)
with open(NOSR + "/systemd-run", "w") as _fh:
    _fh.write("#!/bin/sh\nexit 1\n")
with open(NOSR + "/systemctl", "w") as _fh:
    _fh.write("#!/bin/sh\necho inactive\nexit 3\n")
os.chmod(NOSR + "/systemd-run", 0o755)
os.chmod(NOSR + "/systemctl", 0o755)
os.environ["PATH"] = NOSR + ":" + os.environ["PATH"]
loader = importlib.machinery.SourceFileLoader("sched", BIN)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("sched", loader))
loader.exec_module(m)
LOG = []
m.log = LOG.append
os.environ.pop("NOTIFY_SOCKET", None)
fails = 0
PAY = "/sys/fs/cgroup/lxc.payload.waydroid"
CPU = "/sys/devices/system/cpu/cpufreq"
GED = "/sys/kernel/ged/hal/custom_boost_gpu_freq"
DDR = "/sys/devices/platform/10012000.dvfsrc/helio-dvfsrc/dvfsrc_req_ddr_opp"
STATE = "/run/blockie-android-sched"
LOCK = "/run/blockie-perf.lock"
STORE = "/var/lib/blockie/settings/settings.json"
FREQ0 = [1800000, 1625000, 1500000, 1450000, 1375000, 1325000, 1275000, 1175000, 1100000, 1050000, 999000, 950000,
         900000, 850000, 774000, 500000]
FREQ6 = [2000000, 1950000, 1900000, 1850000, 1800000, 1710000, 1621000, 1532000, 1443000, 1354000, 1295000, 1176000,
         1087000, 998000, 909000, 850000]
BOOST = {"policy0": 1800000, "policy6": 2000000, "gpu": 15, "ddr": 0, "payload": 100, "top": 100}
TOUCH = {"policy0": 1500000, "policy6": 1710000, "gpu": 15, "payload": 80, "top": 80}
IDLE = {"policy0": 500000, "policy6": 850000, "gpu": 29, "payload": 0, "top": 0, "fg": 0}
FIX = [
    dict(pid=200, comm="main", cmd="zygote64", ppid=1, nice=-20, uid=0, adj=-1000),
    dict(pid=201, comm="webview_zygote", ppid=200, nice=0, uid=1053, adj=-1000),
    dict(pid=300, comm="launcher", nice=-10, uid=10050, adj=0),
    dict(pid=301, comm="renderer", ppid=201, nice=-10, uid=99002, adj=0),
    dict(pid=302, comm="receiver", nice=0, uid=10060, adj=0),
    dict(pid=303, comm="settings", nice=-10, uid=1000, adj=0),
    dict(pid=304, comm="system_server", nice=-2, uid=1000, adj=-900),
    dict(pid=305, comm="cached", nice=0, uid=10070, adj=905),
    dict(pid=306, comm="service", nice=0, uid=10080, adj=300),
    dict(pid=307, comm="boosted", nice=-4, uid=10081, adj=300),
    dict(pid=308, comm="native", ppid=1, nice=0, uid=0, adj=-1000),
    dict(pid=309, comm="appzygote", nice=-10, uid=90001, adj=0),
    dict(pid=310, comm="forked", ppid=1, nice=-10, uid=10090, adj=0),
]
WANT = {200: "fg", 201: "fg", 300: "top", 301: "top", 302: "fg", 303: "top", 304: "fg", 305: "bg", 306: "bg",
        307: "fg", 308: "fg", 309: "top", 310: "top"}


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
        LOG.clear()
        try:
            c = Check()
            f(c)
            ok, why = not c.bad, "\n".join(c.bad)
        except Exception:
            ok, why = False, traceback.format_exc(limit=4)
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


class World:
    n = 0

    def __init__(self, perf=None):
        World.n += 1
        self.r = os.path.join(T, f"w{World.n}")
        self.clock = 1000.0
        self.lxc = "RUNNING"
        self.props = {"sys.boot_completed": "1", "sys.use_fifo_ui": ""}
        self.writes = []
        self.mkdirs = []
        self.calls = []
        self.busy = 0
        self.sticky = set()
        self.esrch = set()
        self.fail = {}
        self.attach_fail = False
        self.on_move = None
        self.ps = {}
        self.uptime = 500.0
        self.last = 100
        self.payload()
        for pol, fr in (("policy0", FREQ0), ("policy6", FREQ6)):
            d = f"{CPU}/{pol}"
            self.f(d + "/scaling_min_freq", f"{fr[-1]}\n")
            self.f(d + "/cpuinfo_min_freq", f"{fr[-1]}\n")
            self.f(d + "/cpuinfo_max_freq", f"{fr[0]}\n")
            self.f(d + "/scaling_available_frequencies", " ".join(map(str, fr)) + " \n")
        self.f(GED, "29\n")
        self.f(DDR, "")
        self.f("/run/blockie-session/session-current", "android blockie-android.service 1\n")
        self.f("/sys/class/leds/lcd-backlight/brightness", "120\n")
        self.f("/proc/uptime", f"{self.uptime:.2f} 400.00\n")
        self.loadavg()
        os.makedirs(self.r + "/dev/input")
        os.makedirs(self.r + STATE)
        os.makedirs(os.path.dirname(self.r + STORE))
        if perf:
            self.setting(perf)

    def f(self, rel, text):
        p = self.r + rel
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as fh:
            fh.write(text)

    def rd(self, rel):
        with open(self.r + rel) as fh:
            return fh.read().strip()

    def payload(self):
        self.f(PAY + "/cgroup.procs", "")
        self.f(PAY + "/cgroup.events", "populated 1\nfrozen 0\n")
        self.f(PAY + "/cgroup.subtree_control", "")
        self.f(PAY + "/cpu.uclamp.min", "0.00\n")

    def events(self, populated=1, frozen=0):
        self.f(PAY + "/cgroup.events", f"populated {populated}\nfrozen {frozen}\n")

    def setting(self, v):
        p = self.r + STORE
        with open(p + ".tmp", "w") as fh:
            json.dump({"android.perf": v}, fh)
        os.replace(p + ".tmp", p)

    def loadavg(self):
        self.f("/proc/loadavg", f"0.10 0.10 0.10 1/100 {self.last}\n")

    def proc(self, pid, comm="app", ppid=200, nice=0, age=100.0, uid=10000, adj=0, group="", cmd=None):
        self.ps[pid] = {"comm": comm, "ppid": ppid, "nice": nice, "start": int((self.uptime - age) * m.CLK_TCK),
                        "uid": uid, "adj": adj, "group": group}
        if cmd is not None:
            self.ps[pid]["cmd"] = cmd
        self.render(pid)
        self.add(pid, group)
        self.last = max(self.last, pid) + 1
        self.loadavg()

    def render(self, pid):
        p = self.ps[pid]
        fields = ["S", str(p["ppid"])] + ["0"] * 14 + [str(p["nice"]), "1", "0", str(p["start"])] + ["0"] * 10
        d = f"/proc/{pid}"
        self.f(d + "/stat", f"{pid} ({p['comm']}) {' '.join(fields)}\n")
        self.f(d + "/status", f"Name:\t{p['comm']}\nUid:\t{p['uid']}\t{p['uid']}\t{p['uid']}\t{p['uid']}\n")
        self.f(d + "/oom_score_adj", f"{p['adj']}\n")
        self.f(d + "/cmdline", p.get("cmd", p["comm"]) + "\0")
        cg = p.get("cg", f"/lxc.payload.waydroid{'/' + p['group'] if p['group'] else ''}")
        self.f(d + "/cgroup", f"1:name=elogind:/\n0::{cg}\n")

    def set(self, pid, **kw):
        self.ps[pid].update(kw)
        self.render(pid)

    def gfile(self, group):
        return f"{self.r}{PAY}{'/' + group if group else ''}/cgroup.procs"

    def pids(self, group):
        try:
            with open(self.gfile(group)) as fh:
                return [int(x) for x in fh.read().split()]
        except FileNotFoundError:
            return []

    def add(self, pid, group):
        with open(self.gfile(group), "a") as fh:
            fh.write(f"{pid}\n")

    def remove(self, pid):
        for d, _, files in os.walk(self.r + PAY):
            if "cgroup.procs" in files:
                p = os.path.join(d, "cgroup.procs")
                with open(p) as fh:
                    keep = [x for x in fh.read().split() if x != str(pid)]
                with open(p, "w") as fh:
                    fh.write("".join(f"{x}\n" for x in keep))

    def group(self, pid):
        return self.ps[pid]["group"]

    def write(self, path, text):
        rel = path[len(self.r):]
        self.writes.append((rel, text))
        if rel in self.fail:
            raise OSError(self.fail[rel], os.strerror(self.fail[rel]), path)
        if not os.path.exists(path):
            raise FileNotFoundError(errno.ENOENT, "No such file or directory", path)
        if os.path.basename(path) == "cgroup.procs":
            pid = int(text)
            if pid in self.esrch or pid not in self.ps:
                raise ProcessLookupError(errno.ESRCH, "No such process")
            if pid in self.sticky:
                return
            g = rel[len(PAY):-len("/cgroup.procs")].strip("/")
            self.remove(pid)
            self.add(pid, g)
            self.set(pid, group=g)
            if self.on_move:
                self.on_move(pid)
            return
        if rel == PAY + "/cgroup.subtree_control":
            if self.busy:
                self.busy -= 1
                raise OSError(errno.EBUSY, "Device or resource busy")
            text = "cpuset cpu"
        with open(path, "w") as fh:
            fh.write(text)

    def mkdir(self, path):
        if os.path.isdir(path):
            return
        os.mkdir(path)
        self.mkdirs.append(path[len(self.r):])
        for name, v in (("cgroup.procs", ""), ("cpu.uclamp.min", "0.00\n"), ("cpuset.cpus", "\n"),
                        ("cpu.weight", "100\n")):
            with open(os.path.join(path, name), "w") as fh:
                fh.write(v)

    def sleep(self, s):
        self.clock += s

    def run(self, argv, timeout):
        self.calls.append(argv[0])
        if argv[0] == "lxc-info":
            return 0, f"State:          {self.lxc}\n"
        if argv[0] == "lxc-attach":
            if self.attach_fail:
                return None
            self.calls.append(argv[-1])
            return 0, self.props.get(argv[-1], "") + "\n"
        return None

    def wrote(self, rel):
        return [v for r, v in self.writes if r == rel]

    def state(self):
        out = {}
        for k, rel in (("policy0", CPU + "/policy0/scaling_min_freq"), ("policy6", CPU + "/policy6/scaling_min_freq"),
                       ("gpu", GED), ("ddr", DDR), ("payload", PAY + "/cpu.uclamp.min"),
                       ("top", PAY + "/top/cpu.uclamp.min"), ("fg", PAY + "/fg/cpu.uclamp.min"),
                       ("bg", PAY + "/bg/cpu.uclamp.min")):
            try:
                v = self.rd(rel)
            except FileNotFoundError:
                v = ""
            out[k] = int(float(v)) if v else None
        return out

    def dirty(self):
        try:
            return self.rd(STATE + "/dirty").split()
        except FileNotFoundError:
            return []


class Fake(m.Sched):
    def __init__(self, w):
        self.w = w
        self.kinds = {}
        self.scans = []
        super().__init__(root=w.r, clock=lambda: w.clock, sleep=w.sleep, run=w.run)

    def write(self, path, text):
        self.w.write(path, text)

    def mkdir(self, path):
        self.w.mkdir(path)

    def caps(self, path, fd):
        return self.kinds.get(os.path.basename(path))

    def ping(self):
        self.w.calls.append("ping")
        super().ping()

    def scan(self, now, slow):
        if self.ready and not self.frozen:
            self.scans.append((now, slow))
        return super().scan(now, slow)

    def wait(self, fds, timeout):
        p = select.poll()
        for fd, ev in fds:
            p.register(fd, ev)
        r = p.poll(0)
        if not r:
            self.w.clock += timeout
        return r


def run_for(s, secs, limit=20000):
    end = s.w.clock + secs
    n = 0
    while s.w.clock < end:
        s.step()
        n += 1
        if n > limit:
            raise RuntimeError("the step loop does not advance the clock")


def run_until(s, cond, secs=5.0):
    end = s.w.clock + secs
    while not cond():
        if s.w.clock >= end:
            return False
        s.step()
    return True


def up(perf=None, fixture=FIX):
    w = World(perf)
    for p in fixture:
        w.proc(**p)
    s = Fake(w)
    s.start()
    s.step()
    return w, s


def match(st, want):
    return all(st[k] == v for k, v in want.items())


def newpid(w, pid, age, uid=10100, nice=-10, adj=0, ppid=200, comm="app", group="fg"):
    w.proc(pid=pid, comm=comm, ppid=ppid, nice=nice, age=age, uid=uid, adj=adj, group=group)


def req(s, kind):
    return next((r for r in s.requests if r.kind == kind), None)


def held(w):
    fh = open(w.r + LOCK, "a")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fh.close()
        return True
    fh.close()
    return False


def until_end(s, kind):
    r = req(s, kind)
    if r is not None:
        run_for(s, r.until - s.w.clock + 0.01)


@case("classify: nice -10 main thread plus adj 0 is top (launcher, renderer, Settings uid 1000, app zygote and "
      "non zygote children), adj >= 300 with nice >= 0 is bg, an adj 0 receiver at nice 0, adj 300 at nice -4, "
      "system_server and natives stay fg; the first scan of an instance starts no window")
def _(c):
    w, s = up()
    c(s.ready, "not set up")
    for pid, g in WANT.items():
        c(w.group(pid) == g, f"pid {pid} in '{w.group(pid)}', want {g}")
    c(not s.requests, f"requests {[r.kind for r in s.requests]}")
    c(w.pids("") == [], f"payload holds {w.pids('')}")
    c(not [x for x in LOG if "window" in x], f"log {LOG}")


@case("zygotes: a process is a zygote when its comm is main, zygote or zygote64, its cmdline names zygote or "
      "zygote64 and its parent is no zygote; a fresh child of zygote64 still named main is not one")
def _(c):
    w, s = up()
    w.proc(pid=210, comm="main", cmd="zygote", ppid=1, nice=-20, uid=0, adj=-1000, group="fg")
    w.proc(pid=420, comm="main", cmd="zygote64", ppid=200, group="fg")
    w.proc(pid=421, comm="main", cmd="/system/bin/app_process64", ppid=1, uid=0, adj=-1000, group="fg")
    w.proc(pid=422, comm="zygote64", cmd="zygote64", ppid=1, uid=0, adj=-1000, group="fg")
    run_for(s, 1.6)
    z = s.zygotes()
    c(z == {200, 210, 422}, f"zygotes {sorted(z)}")


@case("report: once a minute the journal gets the windows started and the pids moved per group since the last report")
def _(c):
    w, s = up()
    run_for(s, m.REPORT_EVERY + 2)
    LOG.clear()
    newpid(w, 404, 0.5)
    c(run_until(s, lambda: req(s, "launch") is not None), "no launch window")
    run_for(s, m.REPORT_EVERY + 2)
    lines = [x for x in LOG if x.startswith("last ")]
    c(len(lines) == 1 and lines[0].endswith(": launch 1 to_top 1"), f"report {lines}")
    LOG.clear()
    run_for(s, m.REPORT_EVERY + 2)
    c(not [x for x in LOG if x.startswith("last ")], f"quiet minute {LOG}")


@case("classify: a renderer, an app zygote child or a pid whose parent is no zygote joins top with no window; an old "
      "zygote child starts a switch window (500 ms), one under 2 s old a launch window (6 s)")
def _(c):
    w, s = up()
    newpid(w, 400, 50, uid=99010, ppid=201)
    newpid(w, 401, 50, uid=90020)
    newpid(w, 402, 50, ppid=1)
    run_for(s, 1.6)
    for pid in (400, 401, 402):
        c(w.group(pid) == "top", f"pid {pid} in {w.group(pid)}")
    c(not s.requests, f"requests {[r.kind for r in s.requests]}")
    c(w.state()["policy0"] == 500000, f"policy0 {w.state()['policy0']}")
    newpid(w, 403, 50, uid=1000)
    c(run_until(s, lambda: req(s, "switch") is not None), "no switch window for a new Settings top pid")
    c(match(w.state(), BOOST), f"switch state {w.state()}")
    until_end(s, "switch")
    c(match(w.state(), IDLE), f"after switch {w.state()}")
    newpid(w, 404, 0.5)
    c(run_until(s, lambda: req(s, "launch") is not None), "no launch window")
    r = req(s, "launch")
    c(match(w.state(), BOOST), f"launch {w.state()}")
    if r is not None:
        start = r.until - m.HOLD["launch"]
        c(abs(start - s.w.clock) < 1e-6, f"launch hold {r.until - s.w.clock:.2f} s")
        held, seen = True, 0.0
        while s.w.clock < r.until - 1e-6:
            s.step()
            if s.w.clock < r.until - 1e-6:
                seen = s.w.clock - start
                held = held and req(s, "launch") is r and match(w.state(), BOOST)
        c(held and seen >= m.HOLD["launch"] - 2, f"launch held until +{seen:.2f}: {w.state()}")
        run_for(s, r.until - s.w.clock + 0.01)
        c(match(w.state(), IDLE), f"after launch {w.state()}")


@case("classify: Settings (uid 1000) leaves top when its nice is no longer -10 and moves to bg once its adj reaches "
      "the cached range; a broadcast at adj 0 and nice 0 never joins top")
def _(c):
    w, s = up()
    w.set(303, nice=0, adj=700)
    run_for(s, 1.6)
    c(w.group(303) == "bg", f"303 in {w.group(303)}")
    w.set(302, adj=0, nice=0)
    run_for(s, 1.6)
    c(w.group(302) == "fg", f"302 in {w.group(302)}")


@case("classify: a listed pid with no /proc entry, ESRCH on a move and a reused pid are handled quietly; the reused "
      "pid is read as the new process")
def _(c):
    w, s = up()
    w.add(500, "fg")
    w.last += 1
    w.loadavg()
    newpid(w, 501, 50, uid=10200)
    w.esrch.add(501)
    run_for(s, 1.6)
    c(500 not in s.pids, "500 tracked")
    c(w.group(501) == "fg", f"501 in {w.group(501)}")
    c(not [x for x in LOG if "cannot move" in x], f"log {LOG}")
    newpid(w, 502, 50, uid=10201, nice=0)
    run_for(s, 1.6)
    c(w.group(502) == "fg", f"502 in {w.group(502)}")
    old = s.pids[502].start if 502 in s.pids else None
    shutil.rmtree(f"{w.r}/proc/502")
    w.ps[502].update(nice=-10, start=int((w.uptime - 50) * m.CLK_TCK) + 7)
    w.render(502)
    w.last += 1
    w.loadavg()
    run_for(s, 3.1)
    c(w.group(502) == "top", f"reused 502 in {w.group(502)}")
    c(502 in s.pids and s.pids[502].start == w.ps[502]["start"] != old, "502 not read as the new process")


@case("evacuation: every pid in the payload and one forked into it during the moves end in fg; +cpuset +cpu is "
      "written after the last move; EBUSY on that write is retried")
def _(c):
    w = World()
    for i in range(60):
        w.proc(pid=1000 + i, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    forked = []

    def fork(pid):
        if not forked:
            forked.append(2000)
            w.proc(pid=2000, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.on_move = fork
    s = Fake(w)
    s.start()
    s.step()
    c(s.ready, "not set up")
    c(w.pids("") == [], f"payload {w.pids('')}")
    c(sorted(w.pids("fg")) == sorted(list(range(1000, 1060)) + [2000]), f"fg {w.pids('fg')}")
    c(w.rd(PAY + "/cgroup.subtree_control") == "cpuset cpu", "subtree_control")
    i = [n for n, (r, _) in enumerate(w.writes) if r == PAY + "/cgroup.subtree_control"]
    last = max(n for n, (r, _) in enumerate(w.writes) if r.endswith("/fg/cgroup.procs"))
    c(i and i[0] > last, "subtree_control written before the last move")
    c(w.rd(PAY + "/bg/cpuset.cpus") == "0-3" and w.rd(PAY + "/fg/cpuset.cpus") == "0-7"
      and w.rd(PAY + "/top/cpuset.cpus") == "0-7", "cpuset.cpus")
    c(all(w.rd(f"{PAY}/{g}/cpu.weight") == "100" for g in ("top", "fg", "bg")), "weights")
    w2 = World()
    w2.proc(pid=1000, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w2.busy = 2
    s2 = Fake(w2)
    s2.start()
    s2.step()
    c(s2.ready and w2.rd(PAY + "/cgroup.subtree_control") == "cpuset cpu", "EBUSY not retried")


@case("gate: no setup while lxc-info is not RUNNING or the payload is not populated; no directory is made and "
      "lxc-info is not asked while populated 0; RUNNING plus populated 1 sets up")
def _(c):
    w = World()
    w.proc(pid=1000, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.lxc = "STARTING"
    s = Fake(w)
    s.start()
    run_for(s, 3.1)
    c(not w.mkdirs and not s.ready, f"made {w.mkdirs}")
    c(not w.wrote(PAY + "/cgroup.subtree_control"), "subtree written")
    w.lxc = "RUNNING"
    w.events(populated=0)
    w.calls.clear()
    run_for(s, 3.1)
    c(not w.mkdirs and not s.ready and "lxc-info" not in w.calls, f"populated 0: {w.mkdirs} {w.calls}")
    w.events(populated=1)
    run_for(s, 1.6)
    c(s.ready and sorted(w.mkdirs) == sorted(f"{PAY}/{g}" for g in ("top", "fg", "bg")), f"made {w.mkdirs}")
    c(w.pids("") == [] and w.group(1000) == "fg", "not evacuated")


@case("setup crash: a crash after any setup step leaves the payload min at 0 with no knob written, and the next "
      "start completes the setup from there")
def _(c):
    for step in ("make_groups", "evacuate", "enable", "set_values"):
        w = World()
        for p in FIX:
            w.proc(**p)
        s = Fake(w)
        real = getattr(s, step)

        def boom(*a, real=real):
            real(*a)
            raise RuntimeError("crash")
        setattr(s, step, boom)
        s.start()
        try:
            s.step()
            c(False, f"{step}: no crash")
        except RuntimeError:
            pass
        st = w.state()
        c(st["payload"] == 0 and all(v == "0" for v in w.wrote(PAY + "/cpu.uclamp.min")),
          f"{step}: payload min {w.wrote(PAY + '/cpu.uclamp.min')}")
        c(st["policy0"] == 500000 and st["gpu"] == 29 and not w.wrote(DDR), f"{step}: knobs {st}")
        if s.lock_fd is not None:
            os.close(s.lock_fd)
        s2 = Fake(w)
        s2.start()
        s2.step()
        c(s2.ready and w.pids("") == [] and w.rd(PAY + "/cgroup.subtree_control") == "cpuset cpu",
          f"{step}: restart did not set up")
        for pid, g in WANT.items():
            c(w.group(pid) == g, f"{step}: pid {pid} in '{w.group(pid)}'")


@case("evacuation bound: a pid that never leaves the payload stops the setup after the pass bound with the payload "
      "min at 0 and no subtree_control write; the next slow scan tries again and succeeds once it moves")
def _(c):
    w = World()
    w.proc(pid=1000, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.proc(pid=1001, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.sticky.add(1001)
    s = Fake(w)
    s.start()
    s.step()
    c(not s.ready, "set up with a pid left")
    c(len(w.wrote(PAY + "/fg/cgroup.procs")) >= m.EVAC_PASSES, "fewer passes than the bound")
    c(w.state()["payload"] == 0 and not w.wrote(PAY + "/cgroup.subtree_control"), "payload min or subtree")
    c([x for x in LOG if "evacuation stopped" in x], f"log {LOG}")
    w.sticky.clear()
    run_for(s, 1.6)
    c(s.ready and w.pids("") == [], "no setup after the pid moved")


@case("payload_tasks: a task found in the payload on a slow scan drops the payload min to 0 at once during a window, "
      "is evacuated, and the payload min returns to the window value")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(w.state()["payload"] == 100, f"window {w.state()}")
    w.proc(pid=600, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    n = len(w.writes)
    run_for(s, 1.6)
    pw = [v for r, v in w.writes[n:] if r == PAY + "/cpu.uclamp.min"]
    c(pw[:1] == ["0"], f"payload writes {pw}")
    c(w.group(600) == "fg" and w.state()["payload"] == 100, f"after {w.state()} {w.group(600)}")
    c([x for x in LOG if x.startswith("payload_tasks")], f"log {LOG}")


@case("arbitration: a touch window inside a launch hold keeps the launch values and ends at its own deadline; the "
      "knobs return at the launch deadline; a touch alone writes the touch row (OPP 2 and 5, uclamp 80, GED 15) "
      "and no DRAM floor")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    launch = req(s, "launch")
    c(launch is not None and match(w.state(), BOOST), f"launch {w.state()}")
    c(stat.S_IMODE(os.stat(w.r + LOCK).st_mode) == 0o600, "the service did not create the perf lock 0600")
    if launch is None:
        return
    run_for(s, 1.0)
    t = s.boost("touch", s.w.clock)
    c(t is not None and match(w.state(), BOOST), f"touch in launch {w.state()}")
    run_for(s, 0.3)
    c(req(s, "touch") is None and match(w.state(), BOOST), f"touch ended {w.state()}")
    run_for(s, launch.until - s.w.clock + 0.01)
    c(match(w.state(), IDLE) and w.state()["ddr"] == 255, f"launch ended {w.state()}")
    n = len(w.writes)
    s.boost("touch", s.w.clock)
    c(match(w.state(), TOUCH), f"touch {w.state()}")
    c(not [v for r, v in w.writes[n:] if r == DDR], "touch wrote the DRAM floor")
    c(sorted(w.dirty()) == ["gpu", "policy0", "policy6"], f"dirty {w.dirty()}")
    run_for(s, 0.25)
    c(match(w.state(), IDLE) and w.dirty() == [], f"touch ended {w.state()} {w.dirty()}")
    tw = [r for r, v in w.writes[n:] if r in (PAY + "/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min")]
    c(tw == [PAY + "/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min",
             PAY + "/cpu.uclamp.min"], f"raise payload then top, lower top then payload: {tw}")


@case("boot: a container not yet at sys.boot_completed gets both mins at max, top and fg uclamp 100, the DRAM floor "
      "and the boot GPU floor until boot completes; then fifo_ui is read once")
def _(c):
    w = World()
    for p in FIX:
        w.proc(**p)
    w.props["sys.boot_completed"] = ""
    s = Fake(w)
    s.start()
    s.step()
    c(req(s, "boot") is not None and match(w.state(), dict(BOOST, fg=100)), f"boot {w.state()}")
    run_for(s, 3.1)
    c(req(s, "boot") is not None, "boot ended early")
    w.props["sys.boot_completed"] = "1"
    w.props["sys.use_fifo_ui"] = "1"
    run_for(s, 1.6)
    c(req(s, "boot") is None and match(w.state(), IDLE), f"after boot {w.state()}")
    c(s.fifo_ui is True and [x for x in LOG if x.startswith("fifo_ui")], "fifo_ui not read")
    run_for(s, 1.6)
    c(w.pids("top") == [], f"top with fifo_ui {w.pids('top')}")
    w2 = World()
    for p in FIX:
        w2.proc(**p)
    w2.props["sys.boot_completed"] = ""
    s2 = Fake(w2)
    s2.start()
    s2.step()
    run_for(s2, m.HOLD["boot"] + 2)
    c(req(s2, "boot") is None and match(w2.state(), IDLE), f"boot cap {w2.state()}")


@case("restore order: android.perf off during a window writes payload min 0, then top min 0, then the dirty knobs to "
      "orig, releases the lock, moves top and bg pids to fg and boosts nothing until policy again (adopted, no mkdir)")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(match(w.state(), BOOST) and held(w), "no window")
    n = len(w.writes)
    w.setting("off")
    run_for(s, 0.1)
    ws = [r for r, _ in w.writes[n:]]
    order = [ws.index(x) if x in ws else -1 for x in (PAY + "/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min",
                                                       CPU + "/policy0/scaling_min_freq")]
    c(-1 not in order and order == sorted(order), f"order {ws[:8]}")
    c(match(w.state(), IDLE) and w.state()["ddr"] == 255 and w.dirty() == [] and not held(w), f"off {w.state()}")
    c(w.pids("top") == [] and w.pids("bg") == [], f"top {w.pids('top')} bg {w.pids('bg')}")
    newpid(w, 405, 0.5)
    run_for(s, 3.1)
    c(w.group(405) == "fg" and not s.requests and s.boost("touch", s.w.clock) is None and s.lock_fd is None,
      "boosted while off")
    made = list(w.mkdirs)
    w.setting("policy")
    run_for(s, 1.6)
    c(s.ready and w.mkdirs == made and w.group(300) == "top", f"policy again {w.mkdirs}")
    c(s.boost("touch", s.w.clock) is not None and match(w.state(), TOUCH), f"touch after policy {w.state()}")


@case("off at container start: no group is made, nothing is moved and lxc-info is never asked")
def _(c):
    w, s = up(perf="off")
    run_for(s, 3.1)
    c(not w.mkdirs and not s.ready and "lxc-info" not in w.calls, f"{w.mkdirs} {w.calls}")
    c(w.pids("") != [] and not w.wrote(PAY + "/cgroup.subtree_control"), "moved or enabled")


@case("freeze: frozen 1 restores the knobs and uclamp in order and keeps every pid in its group; no scan while "
      "frozen; after the thaw the pre freeze top set starts no window, a new top pid does")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(match(w.state(), BOOST), "no window")
    groups = {pid: w.group(pid) for pid in w.ps}
    n = len(w.writes)
    w.events(frozen=1)
    run_for(s, 1.6)
    ws = [r for r, _ in w.writes[n:]]
    order = [ws.index(x) if x in ws else -1 for x in (PAY + "/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min",
                                                       CPU + "/policy0/scaling_min_freq")]
    c(-1 not in order and order == sorted(order), f"order {ws[:8]}")
    c(match(w.state(), IDLE) and not held(w), f"frozen {w.state()}")
    c(groups == {pid: w.group(pid) for pid in w.ps}, "pids moved on freeze")
    k = len(s.scans)
    m_ = len(w.writes)
    newpid(w, 406, 50)
    run_for(s, 5)
    c(len(s.scans) == k and not [r for r, _ in w.writes[m_:] if r.endswith("cgroup.procs")], "scanned while frozen")
    c(s.boost("touch", s.w.clock) is None, "touch boost while frozen")
    w.set(406, nice=0)
    w.events(frozen=0)
    run_for(s, 1.6)
    c(not s.requests and match(w.state(), IDLE), f"thaw started {[r.kind for r in s.requests]}")
    LOG.clear()
    newpid(w, 407, 50)
    c(run_until(s, lambda: req(s, "switch") is not None) and w.group(407) == "top" and LOG.count("window switch") == 1,
      f"new top pid after thaw: {LOG}")


@case("container stop: populated 0 restores and waits without asking lxc-info; a new payload (new inode) is set up "
      "again from scratch")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    w.events(populated=0)
    run_for(s, 1.6)
    c(not s.ready and s.instance is None and match(w.state(), IDLE) and not held(w), f"stop {w.state()}")
    w.calls.clear()
    run_for(s, 3.1)
    c("lxc-info" not in w.calls, f"calls {w.calls}")
    os.rename(w.r + PAY, w.r + PAY + ".old")
    w.payload()
    shutil.rmtree(w.r + PAY + ".old")
    for pid in list(w.ps):
        w.ps[pid]["group"] = ""
        w.render(pid)
        w.add(pid, "")
    w.mkdirs.clear()
    run_for(s, 1.6)
    c(s.ready and len(w.mkdirs) == 3 and w.pids("") == [], f"new instance {w.mkdirs}")


@case("service stop: SIGTERM during a window restores payload min, top min, then the knobs, and serve returns 0")
def _(c):
    w = World()
    for p in FIX:
        w.proc(**p)
    s = Fake(w)
    s.k = 0
    s.sent = False
    plain = s.wait
    marks = {}

    def wait(fds, timeout):
        s.k += 1
        if s.k == 3:
            newpid(w, 404, 0.5)
        if (s.k > 3 and s.dirty and not s.sent) or s.k > 400:
            s.sent = True
            marks["n"] = len(w.writes)
            os.kill(os.getpid(), signal.SIGTERM)
        return plain(fds, timeout)
    s.wait = wait
    try:
        rc = s.serve()
    finally:
        signal.set_wakeup_fd(-1)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.signal(signal.SIGINT, signal.default_int_handler)
    c(rc == 0 and s.k <= 400, f"rc {rc} after {s.k} waits")
    ws = [r for r, _ in w.writes[marks.get("n", 0):]]
    order = [ws.index(x) if x in ws else -1 for x in (PAY + "/cpu.uclamp.min", PAY + "/top/cpu.uclamp.min",
                                                       CPU + "/policy0/scaling_min_freq")]
    c(-1 not in order and order == sorted(order), f"order {ws[:8]}")
    c(match(w.state(), IDLE) and w.dirty() == [] and not held(w), f"stopped {w.state()}")


@case("orig: written once per boot from cpuinfo_min_freq with the GED and DRAM release values, never rewritten; a "
      "bad orig falls back to the built in values; dirty lists the raised knobs during a window and is empty after")
def _(c):
    w = World()
    w.f(CPU + "/policy0/cpuinfo_min_freq", "774000\n")
    p = m.Paths(w.r)
    m.write_orig(p)
    c(w.rd(STATE + "/orig") == "policy0 774000\npolicy6 850000\ngpu 29\nddr 255", f"orig {w.rd(STATE + '/orig')}")
    w.f(CPU + "/policy0/cpuinfo_min_freq", "900000\n")
    m.write_orig(p)
    c(w.rd(STATE + "/orig").startswith("policy0 774000\n"), "orig rewritten")
    for p_ in FIX:
        w.proc(**p_)
    s = Fake(w)
    s.start()
    s.step()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(w.dirty() == ["policy0", "policy6", "gpu", "ddr"], f"dirty {w.dirty()}")
    until_end(s, "launch")
    c(w.dirty() == [] and w.state()["policy0"] == 774000, f"after {w.dirty()} {w.state()}")
    for bad in ("policy0 abc\npolicy6 850000\ngpu 29\nddr 255\n", "policy0 774000\npolicy6 850000\ngpu 0\nddr 255\n",
                "policy0 774000\n", "policy0 774000\npolicy0 774000\npolicy6 850000\ngpu 29\nddr 255\n"):
        w.f(STATE + "/orig", bad)
        LOG.clear()
        s2 = Fake(w)
        c(s2.orig == m.ORIG and [x for x in LOG if "missing or bad" in x], f"bad orig {bad!r}: {s2.orig}")


@case("lock: a held /run/blockie-perf.lock skips the window's knob writes (uclamp still applies) and logs perf_busy; "
      "a free lock is held from the window start to after the restore; off never takes it")
def _(c):
    w, s = up()
    fh = open(w.r + LOCK, "a")
    fcntl.flock(fh, fcntl.LOCK_EX)
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    st = w.state()
    c(req(s, "launch") is not None and st["top"] == 100 and st["policy0"] == 500000 and st["gpu"] == 29
      and not w.wrote(DDR) and w.dirty() == [], f"busy {st}")
    c([x for x in LOG if x.startswith("perf_busy")], f"log {LOG}")
    fh.close()
    until_end(s, "launch")
    newpid(w, 405, 0.5)
    run_for(s, 1.6)
    c(match(w.state(), BOOST) and held(w), f"free {w.state()}")
    until_end(s, "launch")
    c(match(w.state(), IDLE) and not held(w) and s.lock_fd is None, "lock kept after the restore")
    w.setting("off")
    run_for(s, 0.1)
    newpid(w, 406, 0.5)
    run_for(s, 3.1)
    c(s.lock_fd is None and s.boost("touch", s.w.clock) is None and s.lock_fd is None, "off took the lock")


@case("restart: a new service on a set up instance adopts top, fg and bg (no mkdir, no subtree_control write), "
      "writes the uclamp mins to 0 first, restores a stale dirty set and starts no window for the existing top set")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(match(w.state(), BOOST), "no window")
    os.close(s.lock_fd)
    s.lock_fd = None
    made = list(w.mkdirs)
    n = len(w.writes)
    s2 = Fake(w)
    s2.start()
    s2.step()
    ws = w.writes[n:]
    c(s2.ready and w.mkdirs == made and not [r for r, _ in ws if r.endswith("subtree_control")], "re-created")
    c(ws[:1] == [(PAY + "/cpu.uclamp.min", "0")], f"first write {ws[:1]}")
    c(match(w.state(), IDLE) and w.dirty() == [] and not s2.requests, f"after restart {w.state()}")
    for pid, g in WANT.items():
        c(w.group(pid) == g, f"pid {pid} in {w.group(pid)}")


@case("touch nodes: event nodes found by inotify on /dev/input, opened only when the capability test says touch or "
      "key; a touch down starts the touch window with one write per knob, moves only move the deadline, the node "
      "leaves the poll set for 100 ms after a read in a window; a key event gives fast scans and no window")
def _(c):
    w, s = up()
    s.kinds = {"event3": "touch", "event4": "key"}
    for n in ("event3", "event4", "event5"):
        os.mkfifo(f"{w.r}/dev/input/{n}")
    s.step()
    c(sorted(os.path.basename(p) for p in s.devices) == ["event3", "event4"], f"devices {list(s.devices)}")
    tfd = os.open(f"{w.r}/dev/input/event3", os.O_WRONLY | os.O_NONBLOCK)
    kfd = os.open(f"{w.r}/dev/input/event4", os.O_WRONLY | os.O_NONBLOCK)
    ev = m.EVENT

    def emit(fd, *evs):
        os.write(fd, b"".join(ev.pack(0, 0, t, code, v) for t, code, v in evs + ((0, 0, 0),)))
    n = len(w.writes)
    emit(tfd, (m.EV_ABS, m.ABS_MT_TRACKING_ID, 4), (m.EV_KEY, m.BTN_TOUCH, 1), (m.EV_ABS, m.ABS_MT_POSITION_X, 10))
    s.step()
    t = req(s, "touch")
    c(t is not None and match(w.state(), TOUCH), f"down {w.state()}")
    knobw = [r for r, _ in w.writes[n:] if r in (CPU + "/policy0/scaling_min_freq", GED, PAY + "/top/cpu.uclamp.min")]
    dev = s.devices[f"{w.r}/dev/input/event3"]
    c(dev.fd not in [fd for fd, _ in s.fds(s.w.clock)], "touch node not parked")
    first = t.until if t else 0
    emit(tfd, (m.EV_ABS, m.ABS_MT_POSITION_X, 20))
    for _ in range(5):
        s.step()
    t2 = req(s, "touch")
    c(t2 is t and t2.until > first, "a move did not move the deadline")
    knobw2 = [r for r, _ in w.writes[n:] if r in (CPU + "/policy0/scaling_min_freq", GED, PAY + "/top/cpu.uclamp.min")]
    c(knobw == knobw2 and len(knobw) == 3, f"knob writes {knobw2}")
    run_for(s, 0.5)
    c(req(s, "touch") is None and match(w.state(), IDLE), f"after touch {w.state()}")
    run_for(s, 3)
    emit(kfd, (m.EV_KEY, 0x130, 1))
    s.step()
    c(not s.requests and s.fast_until > s.w.clock, "key event")
    kd = s.devices[f"{w.r}/dev/input/event4"]
    c(kd.park > s.w.clock and kd.fd not in [fd for fd, _ in s.fds(s.w.clock)], "key node not parked after a read")
    os.close(tfd)
    os.close(kfd)


@case("scan rates: a touch down gives scans at +50, +150, +300 and +600 ms and every 250 ms for 2 s, then one per "
      "1500 ms; none while frozen")
def _(c):
    w, s = up()
    run_for(s, 2)
    t0 = s.w.clock
    s.scans.clear()
    s.fast(t0, True)
    run_for(s, 6)
    at = [round(x - t0, 3) for x, _ in s.scans]
    for want in (0.05, 0.15, 0.3, 0.6):
        c(any(abs(a - want) < 0.011 for a in at), f"no scan at +{want}: {at}")
    early = [a for a in at if a <= 2.0]
    gaps = [b - a for a, b in zip([0.0] + early, early)]
    c(gaps and max(gaps) <= 0.251, f"gaps in the first 2 s {gaps}")
    late = [a for a in at if a > 2.3]
    lg = [b - a for a, b in zip(late, late[1:])]
    c(lg and min(lg) >= 1.49, f"gaps after 2 s {lg}")
    w.events(frozen=1)
    run_for(s, 2)
    s.scans.clear()
    s.fast(s.w.clock, True)
    run_for(s, 4)
    c(not s.scans, f"scans while frozen {s.scans}")


@case("ExecStopPost script: payload, top and fg mins to 0, the dirty knobs to orig under the lock and dirty emptied; "
      "a bad orig uses the built in values; nothing dirty takes no lock; in the deferred run a held lock is waited for "
      "up to the bound, then the knobs are left as they are")
def _(c):
    w = World()
    for g in ("top", "fg", "bg"):
        w.mkdir(w.r + PAY + "/" + g)
    w.f(PAY + "/cpu.uclamp.min", "100\n")
    w.f(PAY + "/top/cpu.uclamp.min", "100\n")
    w.f(PAY + "/fg/cpu.uclamp.min", "100\n")
    w.f(CPU + "/policy0/scaling_min_freq", "1800000\n")
    w.f(GED, "15\n")
    w.f(STATE + "/orig", "policy0 774000\npolicy6 850000\ngpu 29\nddr 255\n")
    w.f(STATE + "/dirty", "policy0\ngpu\nddr\n")
    env = dict(os.environ, BLOCKIE_SCHED_ROOT=w.r)

    def restore(**kw):
        e = dict(env, **kw)
        t0 = time.monotonic()
        r = subprocess.run(["bash", RESTORE], env=e, capture_output=True, text=True)
        return r, time.monotonic() - t0
    r, _ = restore()
    st = w.state()
    c(r.returncode == 0 and st["payload"] == 0 and st["top"] == 0 and st["fg"] == 0, f"mins {st} {r.stderr}")
    c(stat.S_IMODE(os.stat(w.r + LOCK).st_mode) == 0o600, "the script did not create the perf lock 0600")
    c(st["policy0"] == 774000 and st["gpu"] == 29 and st["ddr"] == 255 and w.dirty() == [], f"knobs {st}")
    w.f(CPU + "/policy0/scaling_min_freq", "1800000\n")
    w.f(STATE + "/dirty", "policy0\n")
    w.f(STATE + "/orig", "policy0 nonsense\n")
    r, _ = restore()
    c(r.returncode == 0 and w.state()["policy0"] == 500000 and "missing or bad" in r.stdout, f"bad orig {r.stdout}")
    fh = open(w.r + LOCK, "a")
    fcntl.flock(fh, fcntl.LOCK_EX)
    w.f(PAY + "/cpu.uclamp.min", "100\n")
    r, dt = restore()
    c(r.returncode == 0 and dt < 1 and w.state()["payload"] == 0, f"nothing dirty: {dt:.2f} s")
    w.f(CPU + "/policy0/scaling_min_freq", "1800000\n")
    w.f(STATE + "/dirty", "policy0\n")
    r, dt = restore(BLOCKIE_SCHED_LOCK_WAIT="1", BLOCKIE_SCHED_DEFERRED="1")
    c(r.returncode == 0 and 0.9 <= dt < 3 and w.state()["policy0"] == 1800000 and w.dirty() == ["policy0"]
      and "still held" in r.stdout, f"held: {dt:.2f} s {r.stdout}")
    threading.Timer(0.5, fh.close).start()
    r, dt = restore()
    c(r.returncode == 0 and 0.4 <= dt < 4.5 and w.state()["policy0"] == 500000 and w.dirty() == [],
      f"released: {dt:.2f} s {w.state()}")
    c(m.Paths("").lock == LOCK, "lock path")
    w.f(STATE + "/orig", "policy0 774000\npolicy6 850000\ngpu 29\nddr 255")
    w.f(STATE + "/dirty", "policy6\ngpu")
    w.f(GED, "15\n")
    knob = w.r + CPU + "/policy6/scaling_min_freq"
    os.remove(knob)
    os.mkdir(knob)
    r, _ = restore()
    c(r.returncode == 1 and w.rd(GED) == "29" and w.dirty() == ["policy6"] and "left policy6" in r.stdout
      and "missing or bad" not in r.stdout, f"failed write: rc {r.returncode} {r.stdout} {w.dirty()}")


@case("ExecStopPost script on a busy lock: after its 2 s wait it hands the restore to a transient unit (systemd-run "
      "--no-block --collect, the deferred flag, a longer wait) and returns 0 at once; the deferred run restores the "
      "knobs once the lock is free and, still busy at its bound, hands off nothing again; with "
      "blockie-android-sched.service active or activating again it writes nothing; it never writes the uclamp mins")
def _(c):
    w = World()
    w.f(STATE + "/orig", "policy0 774000\npolicy6 850000\ngpu 29\nddr 255\n")
    bindir = w.r + "/fakebin"
    os.makedirs(bindir)
    calls = w.r + "/systemd-run.calls"
    with open(bindir + "/systemd-run", "w") as fh:
        fh.write("#!/usr/bin/env python3\n"
                 "import os, subprocess, sys\n"
                 f"with open({calls!r}, 'a') as f:\n"
                 "    f.write(' '.join(sys.argv[1:]) + '\\n')\n"
                 "env = dict(os.environ)\n"
                 "args = sys.argv[1:]\n"
                 "while args and args[0].startswith('-'):\n"
                 "    a = args.pop(0)\n"
                 "    if a.startswith('--setenv='):\n"
                 "        k, _, v = a[len('--setenv='):].partition('=')\n"
                 "        env[k] = v\n"
                 "subprocess.Popen(['bash'] + args, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,\n"
                 "                 stderr=subprocess.DEVNULL, start_new_session=True)\n")
    os.chmod(bindir + "/systemd-run", 0o755)

    def ncalls():
        try:
            with open(calls) as fh:
                return fh.read().splitlines()
        except FileNotFoundError:
            return []

    def wait_for(cond, s):
        t0 = time.monotonic()
        while time.monotonic() - t0 < s:
            if cond():
                return True
            time.sleep(0.05)
        return cond()

    env = dict(os.environ, BLOCKIE_SCHED_ROOT=w.r, PATH=bindir + ":" + os.environ["PATH"])
    env.pop("BLOCKIE_SCHED_LOCK_WAIT", None)
    env.pop("BLOCKIE_SCHED_DEFERRED", None)
    for leg, later in (("release", "5"), ("busy", "1")):
        w.f(CPU + "/policy0/scaling_min_freq", "1800000\n")
        w.f(STATE + "/dirty", "policy0\n")
        before = len(ncalls())
        fh = open(w.r + LOCK, "a")
        fcntl.flock(fh, fcntl.LOCK_EX)
        t0 = time.monotonic()
        r = subprocess.run(["bash", RESTORE], env=dict(env, BLOCKIE_SCHED_DEFERRED_WAIT=later), capture_output=True,
                           text=True)
        dt = time.monotonic() - t0
        got = ncalls()[before:]
        c(r.returncode == 0 and 1.8 <= dt < 4 and "goes to blockie-android-sched-deferred" in r.stdout and len(got) == 1
          and all(x in got[0].split() for x in ("--no-block", "--collect", "--unit=blockie-android-sched-deferred",
                                                 "--setenv=BLOCKIE_SCHED_DEFERRED=1",
                                                 f"--setenv=BLOCKIE_SCHED_LOCK_WAIT={later}"))
          and w.state()["policy0"] == 1800000, f"{leg}: hand-off rc {r.returncode} {dt:.2f} s {r.stdout} {got}")
        if leg == "release":
            time.sleep(0.5)
            fh.close()
            c(wait_for(lambda: w.state()["policy0"] == 774000 and w.dirty() == [], 10),
              f"release: the deferred run restored nothing {w.state()} {w.dirty()}")
        else:
            time.sleep(3)
            c(len(ncalls()) == before + 1 and w.state()["policy0"] == 1800000 and w.dirty() == ["policy0"],
              f"busy: the deferred run handed off again or wrote {ncalls()} {w.state()}")
            fh.close()
        c(len(ncalls()) == before + 1, f"{leg}: a second hand-off {ncalls()}")
    with open(bindir + "/systemctl", "w") as fh:
        fh.write("#!/bin/sh\n"
                 "[ \"$1 $2\" = \"is-active blockie-android-sched.service\" ] || exit 9\n"
                 "cat \"$BLOCKIE_SCHED_ROOT/unit-state\"\n")
    os.chmod(bindir + "/systemctl", 0o755)
    for g in ("top", "fg"):
        w.mkdir(w.r + PAY + "/" + g)
    for st in ("active", "activating", "inactive"):
        w.f("/unit-state", st + "\n")
        w.f(PAY + "/cpu.uclamp.min", "100\n")
        w.f(PAY + "/top/cpu.uclamp.min", "100\n")
        w.f(CPU + "/policy0/scaling_min_freq", "1800000\n")
        w.f(STATE + "/dirty", "policy0\n")
        r = subprocess.run(["bash", RESTORE], env=dict(env, BLOCKIE_SCHED_DEFERRED="1", BLOCKIE_SCHED_LOCK_WAIT="1"),
                           capture_output=True, text=True)
        c(w.state()["payload"] == 100 and w.state()["top"] == 100, f"deferred, service {st}: uclamp written {w.state()}")
        if st == "inactive":
            c(r.returncode == 0 and w.state()["policy0"] == 774000 and w.dirty() == [],
              f"deferred, service {st}: not restored {r.stdout} {w.state()}")
        else:
            c(r.returncode == 0 and w.state()["policy0"] == 1800000 and w.dirty() == ["policy0"]
              and "took the dirty list over" in r.stdout, f"deferred, service {st}: wrote {r.stdout} {w.state()}")


@case("daemon: READY and WATCHDOG over NOTIFY_SOCKET; a launch window writes the knobs and dirty; after kill -9 the "
      "ExecStopPost script restores the knobs, the mins and dirty")
def _(c):
    w = World()
    for g in ("top", "fg", "bg"):
        w.mkdir(w.r + PAY + "/" + g)
    for g, cpus in (("top", "0-7"), ("fg", "0-7"), ("bg", "0-3")):
        w.f(f"{PAY}/{g}/cpuset.cpus", cpus + "\n")
    w.f(PAY + "/cgroup.subtree_control", "cpuset cpu\n")
    w.proc(pid=200, comm="main", cmd="zygote64", ppid=1, nice=-20, uid=0, adj=-1000, group="fg")
    bindir = w.r + "/bin"
    os.makedirs(bindir)
    with open(bindir + "/lxc-info", "w") as fh:
        fh.write("#!/bin/sh\necho 'State:          RUNNING'\n")
    alog = w.r + "/attach.log"
    with open(bindir + "/lxc-attach", "w") as fh:
        fh.write(f'#!/bin/sh\nfor a; do p=$a; done\necho "$p" >> {alog}\n'
                 '[ "$p" = sys.boot_completed ] && echo 1 || echo\n')
    os.chmod(bindir + "/lxc-info", 0o755)
    os.chmod(bindir + "/lxc-attach", 0o755)
    sock = w.r + "/notify"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    srv.bind(sock)
    srv.settimeout(10)
    env = dict(os.environ, BLOCKIE_SCHED_ROOT=w.r, PATH=bindir + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
               NOTIFY_SOCKET=sock)
    r = subprocess.run([sys.executable, BIN, "orig"], env=env, capture_output=True, text=True)
    c(r.returncode == 0 and w.rd(STATE + "/orig").startswith("policy0 500000"), f"orig {r.stderr}")
    err = open(w.r + "/err", "w")
    p = subprocess.Popen([sys.executable, BIN], env=env, stdout=subprocess.DEVNULL, stderr=err)
    try:
        got = []
        try:
            got.append(srv.recv(64).decode())
        except socket.timeout:
            pass
        c(got == ["READY=1"], f"notify {got}")
        end = time.monotonic() + 10
        srv.settimeout(0.2)
        while time.monotonic() < end:
            try:
                got.append(srv.recv(64).decode())
            except socket.timeout:
                pass
            if "WATCHDOG=1" in got and os.path.exists(alog) and "sys.use_fifo_ui" in open(alog).read().split():
                break
        c("WATCHDOG=1" in got and got[0] == "READY=1", f"no WATCHDOG=1 after READY: {got}")
        newpid(w, 600, 0.2, uid=10050)
        end = time.monotonic() + 10
        while time.monotonic() < end and not ("policy0" in w.dirty() and w.state()["policy0"] == 1800000):
            time.sleep(0.05)
        c(match(w.state(), BOOST) and "policy0" in w.dirty(), f"window {w.state()} {w.dirty()}")
        n = len(got)
        srv.settimeout(4)
        try:
            got.append(srv.recv(64).decode())
        except socket.timeout:
            pass
        c(got[n:] == ["WATCHDOG=1"], f"no periodic WATCHDOG=1: {got}")
    finally:
        p.kill()
        p.wait()
        srv.close()
        err.close()
    r = subprocess.run(["bash", RESTORE], env=env, capture_output=True, text=True)
    st = w.state()
    c(r.returncode == 0 and match(st, IDLE) and st["ddr"] == 255 and w.dirty() == [], f"restored {st} {r.stdout}")
    if c.bad:
        c.bad.append(open(w.r + "/err").read())


@case("caps: the capability test asks EVIOCGPROP, EVIOCGBIT(EV_ABS) and EVIOCGBIT(0) with their buffer sizes and "
      "reads INPUT_PROP_DIRECT, ABS_MT_POSITION_X and EV_KEY from the returned bits; an ioctl error is no node")
def _(c):
    seen = []

    def stub(bits):
        def ioctl(fd, req, buf):
            seen.append(req)
            c(req >> 30 == 2 and (req >> 8) & 0xFF == ord("E") and (req >> 16) & 0x3FFF == len(buf),
              f"request {req:#x} for {len(buf)} bytes")
            for n in bits.get(req & 0xFF, ()):
                buf[n // 8] |= 1 << (n % 8)
            return 0
        return ioctl

    def boom(fd, req, buf):
        raise OSError(errno.ENOTTY, "Inappropriate ioctl for device")
    real = m.fcntl.ioctl
    try:
        for bits, want in (({0x09: [m.INPUT_PROP_DIRECT], 0x23: [m.ABS_MT_POSITION_X], 0x20: [m.EV_KEY, m.EV_ABS]},
                            "touch"),
                           ({0x23: [m.ABS_MT_POSITION_X], 0x20: [m.EV_KEY, m.EV_ABS]}, "key"),
                           ({0x09: [m.INPUT_PROP_DIRECT], 0x23: [0], 0x20: [m.EV_KEY, m.EV_ABS]}, "key"),
                           ({0x20: [m.EV_ABS]}, None)):
            seen.clear()
            m.fcntl.ioctl = stub(bits)
            got = m.Sched.caps(None, "event0", 3)
            c(got == want, f"bits {bits}: {got}, want {want}")
            c(seen == [0x80044509, 0x80084523, 0x80044520], f"requests {[hex(x) for x in seen]}")
        m.fcntl.ioctl = boom
        c(m.Sched.caps(None, "event0", 3) is None, "an ioctl error gave a node")
    finally:
        m.fcntl.ioctl = real


@case("knob restore failure: a restore write that fails keeps the knob in dirty with the lock held and is tried again "
      "on the next step until it lands, then the lock is released; the off path does the same")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    c(match(w.state(), BOOST), "no window")
    k0 = CPU + "/policy0/scaling_min_freq"
    w.fail[k0] = errno.EIO
    until_end(s, "launch")
    st = w.state()
    c(st["policy0"] == 1800000 and st["gpu"] == 29 and w.dirty() == ["policy0"] and held(w)
      and s.applied["policy0"] == m.STALE, f"failed restore {st} {w.dirty()}")
    c([x for x in LOG if x.startswith("cannot restore")], f"log {LOG}")
    n = len(w.wrote(k0))
    s.step()
    c(len(w.wrote(k0)) > n, "no new try on the next step")
    del w.fail[k0]
    s.step()
    c(w.state()["policy0"] == 500000 and w.dirty() == [] and not held(w), f"after the retry {w.state()} {w.dirty()}")
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    k6 = CPU + "/policy6/scaling_min_freq"
    w.fail[k6] = errno.EIO
    w.setting("off")
    run_for(s, 0.1)
    c(w.dirty() == ["policy6"] and held(w) and w.state()["policy0"] == 500000, f"off {w.dirty()}")
    del w.fail[k6]
    s.step()
    c(w.dirty() == [] and w.state()["policy6"] == 850000 and not held(w), f"off retry {w.state()}")


@case("uclamp restore failure: a min 0 write that fails on the off path is tried again on the next step")
def _(c):
    w, s = up()
    newpid(w, 404, 0.5)
    run_for(s, 1.6)
    t = PAY + "/top/cpu.uclamp.min"
    w.fail[t] = errno.EIO
    w.setting("off")
    run_for(s, 0.1)
    c(w.state()["top"] == 100 and s.mins_failed and w.state()["payload"] == 0, f"off {w.state()}")
    n = len(w.wrote(t))
    s.step()
    c(len(w.wrote(t)) > n, "no new try")
    del w.fail[t]
    s.step()
    c(w.state()["top"] == 0 and not s.mins_failed, f"retried {w.state()}")


@case("skip: a window started while the perf lock was held writes its knobs once it is extended with the lock free")
def _(c):
    w, s = up()
    fh = open(w.r + LOCK, "a")
    fcntl.flock(fh, fcntl.LOCK_EX)
    t = s.boost("touch", s.w.clock)
    st = w.state()
    c(t is not None and t.skip and st["policy0"] == 500000 and st["top"] == 80, f"busy {st}")
    fh.close()
    s.boost("touch", s.w.clock)
    c(t is not None and not t.skip and match(w.state(), TOUCH) and held(w), f"extended {w.state()}")


@case("boot: a getprop that fails starts no boot window and is asked again on the next slow scan")
def _(c):
    w = World()
    for p in FIX:
        w.proc(**p)
    w.props["sys.boot_completed"] = ""
    w.attach_fail = True
    s = Fake(w)
    s.start()
    s.step()
    c(s.ready and req(s, "boot") is None and w.state()["policy0"] == 500000, f"failed getprop {w.state()}")
    w.attach_fail = False
    run_for(s, 1.6)
    c(req(s, "boot") is not None and match(w.state(), dict(BOOST, fg=100)), f"retried {w.state()}")


@case("watchdog: WATCHDOG=1 goes out before every lxc-info and lxc-attach; the setup step scans once and asks "
      "sys.boot_completed and sys.use_fifo_ui once each")
def _(c):
    w, s = up()
    calls = w.calls
    bad = [i for i, x in enumerate(calls) if x in ("lxc-info", "lxc-attach") and (i == 0 or calls[i - 1] != "ping")]
    c(not bad and "lxc-info" in calls, f"calls {calls}")
    c(len(s.scans) == 1 and calls.count("sys.boot_completed") == 1 and calls.count("sys.use_fifo_ui") == 1,
      f"scans {len(s.scans)} calls {calls}")
    os.environ["NOTIFY_SOCKET"] = os.path.join(T, "no-such-socket")
    try:
        m.notify("WATCHDOG=1")
        c([x for x in LOG if x.startswith("cannot send WATCHDOG=1")], f"log {LOG}")
    finally:
        os.environ.pop("NOTIFY_SOCKET", None)


@case("off at start: an adoptable structure is flattened into fg once without lxc-info; a listed pid whose 0:: line "
      "names another cgroup is not moved, and the evacuation skips one too; comm is read again on every scan")
def _(c):
    w = World(perf="off")
    for g in ("top", "fg", "bg"):
        w.mkdir(w.r + PAY + "/" + g)
    w.f(PAY + "/cgroup.subtree_control", "cpuset cpu\n")
    w.proc(pid=200, comm="main", cmd="zygote64", ppid=1, nice=-20, uid=0, adj=-1000, group="fg")
    w.proc(pid=300, comm="launcher", nice=-10, uid=10050, adj=0, group="top")
    w.proc(pid=305, comm="cached", nice=0, uid=10070, adj=905, group="bg")
    w.proc(pid=306, comm="other", nice=0, uid=10071, adj=905, group="bg")
    w.ps[306]["cg"] = "/user.slice"
    w.render(306)
    s = Fake(w)
    s.start()
    s.step()
    c(sorted(w.pids("fg")) == [200, 300, 305] and w.pids("top") == [] and w.pids("bg") == [306], "not flattened")
    c(not s.ready and "lxc-info" not in w.calls and [x for x in LOG if "off with top" in x], f"calls {w.calls}")
    n = len(w.writes)
    run_for(s, 3.1)
    c(not [r for r, _ in w.writes[n:] if r.endswith("cgroup.procs")], "flattened again")
    w = World()
    w.proc(pid=1000, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.proc(pid=1500, comm="p", ppid=1, nice=0, uid=0, adj=-1000)
    w.ps[1500]["cg"] = "/system.slice/other.service"
    w.render(1500)
    s = Fake(w)
    s.start()
    s.step()
    c(w.group(1000) == "fg" and "1500" not in w.wrote(PAY + "/fg/cgroup.procs"), "evacuation moved a foreign pid")
    w, s = up()
    w.set(302, comm="renamed")
    run_for(s, 1.6)
    c(s.pids[302].comm == "renamed", f"comm {s.pids[302].comm}")


@case("input rescan: a node whose inotify event was lost is opened on the next slow step; IN_Q_OVERFLOW rescans the "
      "input nodes at once")
def _(c):
    w, s = up()
    s.kinds = {"event7": "touch", "event8": "touch"}

    def drain():
        while True:
            try:
                os.read(s.ino, 4096)
            except BlockingIOError:
                return
    os.mkfifo(f"{w.r}/dev/input/event7")
    drain()
    s.step()
    run_for(s, 1.6)
    c(f"{w.r}/dev/input/event7" in s.devices, f"devices {list(s.devices)}")
    os.mkfifo(f"{w.r}/dev/input/event8")
    drain()
    r, wfd = os.pipe()
    os.set_blocking(r, False)
    real = s.ino
    s.ino = r
    try:
        os.write(wfd, struct.pack("iIII", -1, m.IN_Q_OVERFLOW, 0, 0))
        s.read_ino(s.w.clock)
    finally:
        s.ino = real
        os.close(r)
        os.close(wfd)
    c(f"{w.r}/dev/input/event8" in s.devices, f"overflow devices {list(s.devices)}")


print(f"android-sched: {fails} failed" if fails else "android-sched: python cases ok", flush=True)
sys.exit(1 if fails else 0)
