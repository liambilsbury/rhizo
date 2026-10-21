#!/usr/bin/env python3
import configparser
import glob
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402

RELAY_UNITS = ("rhizo-desk-notify.path", "rhizo-desk-notify.service")
SESSION_UNIT = "rhizo-desktop-session.path"
LISTS = (
    ("src/install/cli/rhizo.sh", re.compile(r"^SERVER_MASKED_USER_UNITS=\(([^)]*)\)", re.M | re.S)),
    ("src/install/teardown/teardown.sh", re.compile(r"^USER_UNITS=\(([^)]*)\)", re.M | re.S)),
)


def text(rel):
    """return a tree file's text"""
    with open(os.path.join(ROOT, rel)) as f:
        return f.read()


def unit(path):
    """return a unit file's sections"""
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read(path)
    return parser


def user_units(rules):
    """return the unit names debian/rules installs under the user unit directory"""
    return set(re.findall(r"\$\(USER_UNITS\)/([\w@.-]+)", rules))


def bus_programs():
    """return the basenames of the src programs that import dbus_min"""
    found = set()
    for path in glob.glob(os.path.join(ROOT, "src", "**", "*.py"), recursive=True):
        if os.path.basename(path) == "dbus_min.py":
            continue
        with open(path) as f:
            if re.search(r"^\s*import dbus_min\b|load_dbus_min\(", f.read(), re.M):
                found.add(os.path.basename(path))
    return found


def main():
    """return the failures"""
    bad = []
    rules = text("debian/rules")
    users = user_units(rules)
    programs = bus_programs()
    for path in unit_files.unit_paths(ROOT, (".service",)):
        name = unit_files.installed_name(os.path.basename(path))
        if name in users:
            continue
        execs = " ".join(v for k, v in unit(path)["Service"].items() if k.startswith("Exec")) \
            if unit(path).has_section("Service") else ""
        for prog in programs:
            if re.search(r"/%s\b" % re.escape(prog), execs):
                bad.append(f"system unit {name} runs {prog}, which imports dbus_min")
    for name in RELAY_UNITS:
        if name not in users:
            bad.append(f"debian/rules does not install {name} as a user unit")
        if not os.path.exists(unit_files.unit_path(ROOT, name)):
            bad.append(f"no {name} under src/services")
    if bad:
        return bad
    service, path_unit = unit(unit_files.unit_path(ROOT, RELAY_UNITS[1])), unit(unit_files.unit_path(ROOT, RELAY_UNITS[0]))
    deskd_exec = unit(unit_files.unit_path(ROOT, "rhizo-deskd.service"))["Service"]["ExecStart"]
    sock = re.search(r"--notify-socket\s+(\S+)", deskd_exec)
    if not sock or not sock.group(1).startswith("/run/rhizo-desk-notify/"):
        bad.append(f"rhizo-deskd.service passes no --notify-socket under /run/rhizo-desk-notify: {deskd_exec!r}")
        return bad
    sock = sock.group(1)
    if path_unit["Path"].get("PathExists") != sock:
        bad.append(f"{RELAY_UNITS[0]} PathExists={path_unit['Path'].get('PathExists')}, want {sock}")
    if f"desk-notify.py --socket {sock}" not in service["Service"].get("ExecStart", ""):
        bad.append(f"{RELAY_UNITS[1]} does not run desk-notify.py --socket {sock}")
    for u in (service, path_unit):
        if u["Unit"].get("ConditionUser") != "1000":
            bad.append("a rhizo-desk-notify user unit lacks ConditionUser=1000")
    if "desk-notify.py" not in programs:
        bad.append("desk-notify.py does not import dbus_min")
    for rel, rx in LISTS:
        m = rx.search(text(rel))
        names = m.group(1).split() if m else []
        for name in RELAY_UNITS:
            if SESSION_UNIT in names and name not in names:
                bad.append(f"{rel} lists {SESSION_UNIT} without {name}")
    lib = re.sub(r"\\\n\s*", " ", text("src/install/lib/pkg-lib.sh"))
    for line in lib.splitlines():
        if SESSION_UNIT in line and re.search(r"--global (enable|disable)|--user (start|stop)", line) \
                and RELAY_UNITS[0] not in line:
            bad.append(f"pkg-lib.sh enables, starts, stops or disables {SESSION_UNIT} without "
                       f"{RELAY_UNITS[0]}: {line.strip()}")
    for rel in ("test/vm/redeploy.sh", "test/vm/sync.sh", "test/vm/start/start-deskd.sh"):
        body = text(rel)
        for name in RELAY_UNITS + ("desk-notify.py",):
            if name not in body:
                bad.append(f"{rel} does not stage {name}")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-no-session-bus:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
