#!/usr/bin/env python3.12
"""Stub org.freedesktop.Notifications server for zpui's D-Bus notification test.

Answers Notify (logging the call to stdout), then emits ActionInvoked(id, "default")
after 200 ms — a simulated banner click. Run on a private bus:
  dbus-daemon --session --print-address --fork  ->  DBUS_SESSION_BUS_ADDRESS=... notify-stub.py
"""
import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib

class Stub(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, "/org/freedesktop/Notifications")
        self.next_id = 7

    @dbus.service.method("org.freedesktop.Notifications", in_signature="susssasa{sv}i", out_signature="u")
    def Notify(self, app, replaces, icon, summary, body, actions, hints, timeout):
        nid = self.next_id
        self.next_id += 1
        print(f"Notify app={app!s} summary={summary!s} body={body!s} actions={list(map(str, actions))} timeout={int(timeout)} -> {nid}", flush=True)
        if "default" in actions:
            GLib.timeout_add(200, lambda: (self.ActionInvoked(nid, "default"), False)[1])
        return nid

    @dbus.service.signal("org.freedesktop.Notifications", signature="us")
    def ActionInvoked(self, nid, key):
        print(f"ActionInvoked {nid} {key}", flush=True)

    @dbus.service.method("org.freedesktop.Notifications", out_signature="as")
    def GetCapabilities(self):
        return ["body", "actions"]

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
name = dbus.service.BusName("org.freedesktop.Notifications", bus)
Stub(bus)
print("stub ready", flush=True)
GLib.MainLoop().run()
