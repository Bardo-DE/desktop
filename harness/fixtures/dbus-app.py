#!/usr/bin/env python3
"""A DBusActivatable app for the scenarios: a GApplication on the session bus under APP_ID that opens one
foot window (with app id APP_ID) when it is activated, as org.freedesktop.Application.Activate asks.

usage: dbus-app.py APP_ID FOOT

It owns the bus name the way a real GTK app does, so the bus's activation succeeds, and it needs
WAYLAND_DISPLAY (and XDG_RUNTIME_DIR) from the bus's activation environment to open the window: the
bus hands it only that environment.
"""
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402


def main(app_id: str, foot: str) -> int:
    app = Gio.Application(application_id=app_id, flags=Gio.ApplicationFlags.FLAGS_NONE)
    window = []

    def on_activate(_app):
        if not window:
            window.append(Gio.Subprocess.new([foot, "--app-id", app_id, "sleep", "3600"], Gio.SubprocessFlags.NONE))

    app.connect("activate", on_activate)
    app.hold()
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
