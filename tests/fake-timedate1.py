#!/usr/bin/env python3
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

NAME = "org.freedesktop.timedate1"
PATH = "/org/freedesktop/timedate1"
XML = f"""
<node>
  <interface name="{NAME}">
    <method name="SetTimezone">
      <arg name="timezone" type="s" direction="in"/>
      <arg name="interactive" type="b" direction="in"/>
    </method>
  </interface>
</node>
"""


def read_link(localtime):
    try:
        target = os.readlink(localtime)
    except FileNotFoundError:
        return "UTC"
    except OSError:
        return None
    return target.partition("/zoneinfo/")[2] or None


class Fake:
    def __init__(self, conn, localtime, state):
        self.localtime = localtime
        self.state = state
        self.zone = read_link(localtime)
        self.held = []
        info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
        conn.register_object(PATH, info, self.call, None, None)

    def mode(self):
        try:
            with open(os.path.join(self.state, "mode")) as f:
                words = f.read().split()
        except OSError:
            words = []
        return (words[0] if words else "ok"), (int(words[1]) if len(words) > 1 else 0)

    def write(self, zone, inv):
        tmp = os.path.join(os.path.dirname(self.localtime), f".#localtime{os.getpid()}")
        os.symlink(f"../usr/share/zoneinfo/{zone}", tmp)
        os.replace(tmp, self.localtime)
        self.zone = zone
        if inv is not None:
            inv.return_value(None)
        return GLib.SOURCE_REMOVE

    def done(self, inv):
        inv.return_value(None)
        return GLib.SOURCE_REMOVE

    def call(self, conn, sender, path, iface, method, params, inv):
        zone, interactive = params.unpack()
        with open(os.path.join(self.state, "calls"), "a") as f:
            f.write(f"{zone} {'true' if interactive else 'false'}\n")
        mode, ms = self.mode()
        if mode == "invalid":
            inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs",
                                  f"Invalid or not installed time zone '{zone}'")
        elif zone == self.zone:
            inv.return_value(None)
        elif mode == "deny":
            inv.return_dbus_error("org.freedesktop.DBus.Error.InteractiveAuthorizationRequired",
                                  "Interactive authentication required.")
        elif mode == "stale-all":
            GLib.timeout_add(ms, self.done, inv)
        elif mode == "hang":
            self.held.append(inv)
            if ms:
                GLib.timeout_add(ms, self.write, zone, None)
        elif mode == "delay":
            GLib.timeout_add(ms, self.write, zone, inv)
        else:
            self.write(zone, inv)


def main():
    address, localtime, state = sys.argv[1:4]
    conn = Gio.DBusConnection.new_for_address_sync(
        address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
        None, None)
    Fake(conn, localtime, state)
    loop = GLib.MainLoop()

    def owned(conn, name):
        open(os.path.join(state, "ready"), "w").close()

    def lost(conn, name):
        print(f"fake-timedate1: lost or could not own {name}", file=sys.stderr, flush=True)
        loop.quit()

    Gio.bus_own_name_on_connection(conn, NAME, Gio.BusNameOwnerFlags.NONE, owned, lost)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, loop.quit)
    loop.run()


if __name__ == "__main__":
    main()
