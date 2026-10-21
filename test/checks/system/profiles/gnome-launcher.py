#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "gnome-shell/rhizo-com.x/2301-7-vm_TIME4051"


def load():
    """return the gnome launcher module loaded from its file"""
    spec = importlib.util.spec_from_file_location("gnome_launcher", os.path.join(HERE, "..", "..", "..", "system", "guest", "gnome-launcher.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FixedTokenContext(Gio.AppLaunchContext):
    """launch context with a preset token"""

    def __init__(self, token):
        """keep the startup notify token"""
        super().__init__()
        self.token = token

    def do_get_startup_notify_id(self, info, files):
        """return the startup notify token"""
        return self.token


def entry(tmp, exec_line, notify=True):
    """write a desktop entry file with an Exec line"""
    path = os.path.join(tmp, "rhizo-com.x.desktop")
    with open(path, "w") as f:
        f.write("[Desktop Entry]\nType=Application\nName=X\nExec=%s\nStartupNotify=%s\n"
                % (exec_line, "true" if notify else "false"))
    return path


def run(mod, path, ctx):
    """launch an entry and return the printed lines"""
    lines = []
    mod.launch_entry(Gio.DesktopAppInfo.new_from_filename(path), ctx, lines.append)
    return lines


def run_control(mod, path, ctx):
    """launch an entry without a token and return the recorded lines"""
    lines = []
    mod.launch_entry(Gio.DesktopAppInfo.new_from_filename(path), ctx, lines.append, want_token=False)
    return lines


def wait_file(path, loops=200):
    """wait for a file to hold text and return it"""
    ctx = GLib.MainContext.default()
    for _ in range(loops):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path).read()
        GLib.usleep(25000)
        ctx.iteration(False)
    return None


def main():
    """run the launcher checks and print failures"""
    bad = []
    try:
        mod = load()
    except FileNotFoundError as e:
        print("FAIL: %s" % e)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        rec = os.path.join(tmp, "env")
        script = os.path.join(tmp, "record.sh")
        with open(script, "w") as f:
            f.write('#!/bin/sh\nprintf "%%s" "${XDG_ACTIVATION_TOKEN:-<unset>}" > %s\n' % rec)
        os.chmod(script, 0o755)

        lines = run(mod, entry(tmp, script), FixedTokenContext(TOKEN))
        seen = wait_file(rec)
        if seen != TOKEN:
            bad.append("the entry's child saw XDG_ACTIVATION_TOKEN=%r, want the context's %r" % (seen, TOKEN))
        if len(lines) != 1 or not lines[0].startswith("launched token=%s pid=" % TOKEN):
            bad.append("a launch with a token printed %r, want one `launched token=%s pid=N`" % (lines, TOKEN))

        os.unlink(rec)
        lines = run(mod, entry(tmp, script), FixedTokenContext(None))
        if len(lines) != 1 or not lines[0].startswith("launch-failed ") or "no activation token" not in lines[0]:
            bad.append("a context with no token printed %r, want a launch-failed naming the missing token" % (lines,))

        wait_file(rec)
        os.unlink(rec)
        lines = []
        plain = Gio.AppLaunchContext()
        plain.unsetenv("XDG_ACTIVATION_TOKEN")
        mod.launch_entry(Gio.DesktopAppInfo.new_from_filename(entry(tmp, script)), plain, lines.append, want_token=False)
        seen = wait_file(rec)
        if seen != "<unset>" or len(lines) != 1 or not lines[0].startswith("launched token=none pid="):
            bad.append("a control launch printed %r and its child saw %r, want `launched token=none` and no token" % (lines, seen))
        lines = run_control(mod, entry(tmp, script), FixedTokenContext(TOKEN))
        if len(lines) != 1 or "control launch carried token" not in lines[0]:
            bad.append("a control launch whose context gave a token printed %r, want a launch-failed naming it" % (lines,))

        lines = []
        mod.launch_entry(Gio.DesktopAppInfo.new_from_filename(entry(tmp, script)), FixedTokenContext(TOKEN),
                         lines.append, nonce="n42")
        wait_file(rec)
        if len(lines) != 1 or not lines[0].startswith("launched nonce=n42 token=%s pid=" % TOKEN):
            bad.append("a launch with a nonce printed %r, want `launched nonce=n42 token=...`" % (lines,))

        broken = entry(tmp, script)
        with open(broken, "a") as f:
            f.write("Path=%s\n" % os.path.join(tmp, "gone"))
        lines = run(mod, broken, FixedTokenContext(TOKEN))
        if len(lines) != 1 or not lines[0].startswith("launch-failed "):
            bad.append("an entry that cannot start printed %r, want one launch-failed" % (lines,))
    for b in bad:
        print("FAIL: %s" % b)
    if not bad:
        print("check-gnome-launcher: the launch context's token reaches the entry's child and the launcher's line, and a missing token or a failed start is named")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
