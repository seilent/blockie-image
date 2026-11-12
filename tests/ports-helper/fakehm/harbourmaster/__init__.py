import contextlib
import copy
import hashlib
import json
import os
import re
import shutil
import signal
import zipfile
from pathlib import Path

from . import config

HM_SOURCE_DEFAULTS = config.HM_SOURCE_DEFAULTS


class HarbourException(Exception):
    pass


class CancelEvent(HarbourException):
    pass


class Callback:
    def __init__(self):
        self.was_cancelled = False

    def progress(self, message, amount, total=None, fmt=None):
        pass

    def message(self, message):
        pass

    def message_box(self, message):
        pass

    @contextlib.contextmanager
    def enable_messages(self):
        yield

    @contextlib.contextmanager
    def enable_cancellable(self, cancellable=False):
        yield


def world():
    with open(os.environ["FAKE_HM_WORLD"]) as f:
        return json.load(f)


def note(what, **kw):
    with open(world()["log"], "a") as f:
        f.write(json.dumps(dict(what=what, **kw)) + "\n")


def name_cleaner(text):
    temp = re.sub(r'[^a-zA-Z0-9 _\-\.]+', '', text.strip().lower())
    return re.sub(r'[ \.]+', '.', temp)


def download(file_name, file_url, md5_source=None, md5_result=None, callback=None, no_check=False):
    w = world()
    note("download", url=file_url, file=str(file_name))
    if not file_url.startswith("file:"):
        return None
    data = Path(file_url[5:]).read_bytes()
    md5 = hashlib.md5(data).hexdigest()
    term = w.get("term_at", {}).get(file_url)
    kill = w.get("kill_at", {}).get(file_url)
    try:
        with open(file_name, "wb") as f:
            for n, i in enumerate(range(0, len(data), 1024)):
                f.write(data[i:i + 1024])
                f.flush()
                if n == term:
                    os.kill(os.getpid(), signal.SIGTERM)
                if n == kill:
                    os.kill(os.getpid(), signal.SIGKILL)
                if callback is not None:
                    callback.progress("Downloading file.", min(i + 1024, len(data)), len(data), "data")
    except CancelEvent:
        if file_name.is_file():
            file_name.unlink()
        raise
    if not no_check and md5_source is not None and md5 != md5_source:
        file_name.unlink()
        return None
    if md5_result is not None:
        md5_result[0] = md5
    return file_name


class Source:
    def __init__(self, hm, w):
        self.hm = hm
        self._w = w
        self.ports = sorted(w["ports"])
        self.utils = list(w.get("utils", []))

    def clean_name(self, text):
        return name_cleaner(text)

    def port_info(self, name):
        return copy.deepcopy(self._w["ports"].get(name, {}))

    def download(self, name):
        info = self.port_info(name)
        src = info["source"]
        d = self.hm.ports_dir if src["size"] > config.HM_MAX_TEMP_SIZE else Path(self.hm.temp_dir)
        res = [None]
        z = download(d / name, src["url"], src["md5"], res, callback=self.hm.callback)
        if z is None:
            return None
        info.update(name=name, zip_file=z, status={"source": "Invented", "md5": res[0], "status": "downloaded"})
        return info


class HarbourMaster:
    def __init__(self, config, *, tools_dir=None, ports_dir=None, scripts_dir=None, temp_dir=None, callback=None):
        w = world()
        print("fake harbourmaster writes to stdout")
        note("open", config=config)
        self.config = dict(config)
        self.callback = callback or Callback()
        self.temp_dir = temp_dir
        self.tools_dir = Path(os.environ["HM_TOOLS_DIR"])
        self.ports_dir = Path(os.environ["HM_PORTS_DIR"])
        self.scripts_dir = Path(os.environ["HM_SCRIPTS_DIR"])
        self.libs_dir = self.tools_dir / "PortMaster" / "libs"
        self.libs_dir.mkdir(parents=True, exist_ok=True)
        self.device = {"primary_arch": "aarch64", "capabilities": w.get("caps", [])}
        self.cfg_data = {"show_experimental": False}
        self.runtimes_info = copy.deepcopy(w.get("runtimes", {}))
        self.sources = {"pm": Source(self, w)}
        self._images = w.get("images", {})
        self.load_ports()
        if not self.config["no-check"]:
            for url in w.get("refresh", []):
                download(Path(self.temp_dir) / "images.zip", url, callback=self.callback)

    def load_ports(self):
        self.installed_ports = {}
        self.broken_ports = {}
        for pj in sorted(self.ports_dir.glob("*/port.json")):
            info = json.loads(pj.read_text())
            self.installed_ports[info["name"]] = info

    def port_info(self, name, installed=False):
        info = self.sources["pm"].port_info(name)
        if name in self.installed_ports:
            inst = copy.deepcopy(self.installed_ports[name])
            if info:
                info["status"] = inst.get("status", {})
            else:
                info = inst
        return info or None

    def port_info_attrs(self, info):
        attrs = []
        if info.get("attr", {}).get("exp"):
            attrs.append("exp")
        if info.get("name") in self.installed_ports:
            attrs.append("installed")
        if "status" in info and "source" in info and info["status"].get("md5") not in (None, info["source"].get("md5")):
            attrs.append("update available")
        return attrs

    def match_requirements(self, info):
        return all(r in self.device["capabilities"] for r in info.get("attr", {}).get("reqs", []))

    def port_images(self, name):
        return {k: Path(v) for k, v in self._images.get(name, {}).items()} or None

    def check_runtime(self, runtime, port_name=None, in_install=False):
        raise AssertionError("harbourmaster's own check_runtime ran")

    def _fix_permissions(self, path_check=None):
        raise AssertionError("harbourmaster's own _fix_permissions ran")

    def _install_port(self, download_info, do_delete=False):
        w = world()
        name = download_info["name"]
        note("install", name=name)
        try:
            if name in w.get("fail_install", []):
                return 255
            with zipfile.ZipFile(download_info["zip_file"]) as zf:
                infos = zf.infolist()
                for n, i in enumerate(infos):
                    self.callback.progress("Installing", n + 1, len(infos), "%")
                    if n == 0 and name in w.get("term_in_install", []):
                        os.kill(os.getpid(), signal.SIGTERM)
                    script = "/" not in i.filename and i.filename.lower().endswith(".sh")
                    dest = zf.extract(i, self.scripts_dir if script else self.ports_dir)
                    os.chmod(dest, 0o777 if i.is_dir() else 0o666)
            items = download_info["items"]
            port_dir = self.ports_dir / next(i.rstrip("/") for i in items if not i.lower().endswith(".sh"))
            os.chmod(port_dir, 0o777)
            info = {"name": name, "items": items, "attr": download_info["attr"],
                    "status": dict(download_info["status"], status="Installed")}
            (port_dir / "port.json").write_text(json.dumps(info))
            for runtime in info["attr"].get("runtime", []):
                self.check_runtime(runtime, in_install=True)
            for item in items:
                self._fix_permissions(self.ports_dir / item)
            return 0
        finally:
            if do_delete:
                Path(download_info["zip_file"]).unlink()

    def uninstall_port(self, name):
        info = self.installed_ports.get(name)
        if info is None:
            return 255
        note("uninstall", name=name)
        for item in info["items"]:
            p = self.ports_dir / item
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p)
            elif p.exists():
                p.unlink()
        return 0
