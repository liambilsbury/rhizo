#!/usr/bin/env python3
import sys


def launched_line(data, want_token=True):
    """return the output line for a launch"""
    token = data.get("activation-token") or data.get("startup-notification-id")
    if not want_token:
        if token:
            return "launch-failed a control launch carried token %s" % token
        return "launched token=none pid=%s" % data.get("pid")
    if not token:
        return "launch-failed the launch context gave the entry no activation token (pid %s)" % data.get("pid")
    return "launched token=%s pid=%s" % (token, data.get("pid"))


def launch_entry(info, ctx, out, want_token=True, nonce=None):
    """launch the entry and send the result"""
    from gi.repository import GLib
    lines = []
    ids = [ctx.connect("launched", lambda _c, _i, data: lines.append(launched_line(data.unpack(), want_token))),
           ctx.connect("launch-failed", lambda _c, sid: lines.append(
               "launch-failed glib could not start the entry (startup id %s)" % sid))]
    try:
        if not info.launch([], ctx) and not lines:
            lines.append("launch-failed glib refused to launch %s" % info.get_filename())
    except GLib.Error as e:
        lines.append("launch-failed %s" % e.message)
    finally:
        for i in ids:
            ctx.disconnect(i)
    line = lines[0] if lines else "launch-failed the launch reported neither launched nor failed"
    if nonce:
        word, _, rest = line.partition(" ")
        line = "%s nonce=%s %s" % (word, nonce, rest)
    out(line)


def main(argv):
    """parse the arguments and run the launcher window"""
    want_token = True
    nonce = None
    if argv[:1] == ["--nonce"] and len(argv) > 1:
        nonce, argv = argv[1], argv[2:]
    if argv[:1] == ["--no-token"]:
        want_token, argv = False, argv[1:]
    if len(argv) != 1:
        print("usage: gnome-launcher.py [--nonce N] [--no-token] <entry.desktop>", file=sys.stderr)
        return 2
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gio, Gtk
    info = Gio.DesktopAppInfo.new_from_filename(argv[0])
    if info is None:
        print("launch-failed %s is not a readable desktop entry" % argv[0], flush=True)
        return 1

    def say(line):
        """print a line and flush it"""
        print(line, flush=True)

    def on_click(button):
        """launch the entry when the button is clicked"""
        if want_token:
            launch_entry(info, button.get_display().get_app_launch_context(), say, nonce=nonce)
            return
        ctx = Gio.AppLaunchContext()
        ctx.unsetenv("XDG_ACTIVATION_TOKEN")
        ctx.unsetenv("DESKTOP_STARTUP_ID")
        launch_entry(info, ctx, say, want_token=False, nonce=nonce)

    def on_activate(app):
        """show the window with a button that launches the entry"""
        win = Gtk.ApplicationWindow(application=app, title="rhizo-harness-launcher" + ("-" + nonce if nonce else ""))
        win.set_default_size(320, 240)
        button = Gtk.Button(label="launch %s" % info.get_display_name())
        button.connect("clicked", on_click)
        win.set_child(button)
        win.present()
        say("ready nonce=%s" % nonce if nonce else "ready")

    app = Gtk.Application(application_id="org.rhizo.VmLauncher",
                          flags=Gio.ApplicationFlags.NON_UNIQUE)
    app.connect("activate", on_activate)
    return app.run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
