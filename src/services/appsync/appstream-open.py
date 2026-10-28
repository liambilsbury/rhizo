#!/usr/bin/env python3
import os
import re
import shlex
import shutil
import subprocess
import sys

KEY = "x-scheme-handler/appstream"
SETTINGS = "com.android.settings"
PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$")
URL_RE = re.compile(r"^appstream:(?://)?([^/?#]+)/?$")


def log(msg):
    """print a message to stderr"""
    print(f"[rhizo-appstream] {msg}", file=sys.stderr, flush=True)


def data_dirs(env):
    """return the XDG data directories, the user's first"""
    home = env.get("XDG_DATA_HOME") or os.path.join(env.get("HOME", "/"), ".local", "share")
    return [home] + [d for d in (env.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d]


def config_dirs(env):
    """return the XDG config directories, the user's first"""
    home = env.get("XDG_CONFIG_HOME") or os.path.join(env.get("HOME", "/"), ".config")
    return [home] + [d for d in (env.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":") if d]


def desktop_file(desktop_id, env):
    """return the path of a desktop id, or None"""
    for d in data_dirs(env):
        path = os.path.join(d, "applications", desktop_id)
        if os.path.isfile(path):
            return path
    return None


def android_package(component, env):
    """return an appsync component id's android package, or None"""
    pkg = component[len("rhizo-"):] if component.startswith("rhizo-") else ""
    path = desktop_file(f"rhizo-{pkg}.desktop", env) if PKG_RE.match(pkg) else None
    if path is None:
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        return pkg if f"X-Rhizo-Package={pkg}" in fh.read().splitlines() else None


def list_values(path, sections):
    """return each section's key handlers in a mimeapps-style list"""
    found = {s: [] for s in sections}
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return found
    section = None
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
        elif section in found and s.partition("=")[0].strip() == KEY:
            found[section] += [v.strip() for v in s.partition("=")[2].split(";") if v.strip()]
    return found


def other_handlers(env):
    """return the desktop's ordered appstream:// handlers other than rhizo's"""
    desktops = [d.lower() for d in env.get("XDG_CURRENT_DESKTOP", "").split(":") if d]
    lists = [os.path.join(d, f"{name}mimeapps.list") for d in config_dirs(env)
             for name in [f"{x}-" for x in desktops] + [""]]
    lists += [os.path.join(d, "applications", f"{name}mimeapps.list") for d in data_dirs(env)
              for name in [f"{x}-" for x in desktops] + [""]]
    ordered, removed = [], set()
    for path in lists:
        found = list_values(path, ("Default Applications", "Added Associations", "Removed Associations"))
        ordered += found["Default Applications"] + found["Added Associations"]
        removed.update(found["Removed Associations"])
    for d in data_dirs(env):
        ordered += list_values(os.path.join(d, "applications", "mimeinfo.cache"), ("MIME Cache",))["MIME Cache"]
    seen, out = set(), []
    for h in ordered:
        if h in seen or h in removed or h.startswith("rhizo-"):
            continue
        seen.add(h)
        path = desktop_file(h, env)
        if path:
            out.append(path)
    return out


def plan(url, env):
    """return the argv that opens the url, or the reason"""
    m = URL_RE.match(url)
    if not m:
        return None, f"{url!r} is not an appstream:// link"
    pkg = android_package(m.group(1), env)
    if pkg:
        return ["rhizo", "launch", SETTINGS, f"package:{pkg}"], f"{pkg} is an android app: its page in android's settings"
    handlers = other_handlers(env)
    if not handlers:
        return None, f"no software center handles appstream:// links, so {m.group(1)} has nowhere to open"
    if shutil.which("gio", path=env.get("PATH")):
        return ["gio", "launch", handlers[0], url], f"{m.group(1)} goes to {handlers[0]}"
    return exec_argv(handlers[0], url), f"{m.group(1)} goes to {handlers[0]}"


def exec_argv(path, url):
    """return a desktop file's Exec line with the url substituted"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        execs = [l.partition("=")[2] for l in fh.read().split("\n[")[0].splitlines() if l.startswith("Exec=")]
    argv = []
    for word in shlex.split(execs[0] if execs else ""):
        if word in ("%u", "%U", "%f", "%F"):
            argv.append(url)
        elif not re.fullmatch(r"%[a-zA-Z]", word):
            argv.append(word.replace("%%", "%"))
    return argv


def main(argv):
    """open an appstream:// link"""
    if len(argv) != 2:
        log("usage: appstream-open.py <appstream://component-id>")
        return 2
    cmd, why = plan(argv[1], os.environ)
    log(why)
    if cmd is None:
        return 1
    return subprocess.run(cmd).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))
