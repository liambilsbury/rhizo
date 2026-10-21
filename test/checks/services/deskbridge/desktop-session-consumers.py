#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

DESKD_UNIT = "src/services/deskbridge/deskd.service"
SESSION_UNIT = "rhizo-desktop-session.service"
ASSERT_LIB = "test/system/lib/desktop-assert-lib.sh"
REDEPLOY = "test/vm/redeploy.sh"
SINK_STARTER = "notify_sink_start"

DEF_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
SINK_RE = re.compile(r"notify-sink\S*\.py")
LAUNCH_RE = re.compile(r"systemctl start androidd\.service|python3 /root/launcher3?\.py selinux_setup(?! --policy-only)")


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def unit_values(text):
    """return the unit environment file and runtime directory"""
    joined = re.sub(r"\\\n", " ", text)
    env = re.search(r"^EnvironmentFile=-?(\S+)", joined, re.M)
    rundir = re.search(r"^RuntimeDirectory=(\S+)", joined, re.M)
    if not (env and rundir):
        return None
    return env.group(1), "/run/" + rundir.group(1)


def functions(lines):
    """map each line to its function"""
    owner, spans, cur, start = [], {}, None, 0
    for i, line in enumerate(lines):
        m = DEF_RE.match(line)
        if cur is None and m:
            if line.rstrip().endswith("}"):
                owner.append(m.group(1))
                spans[m.group(1)] = (i, i)
                continue
            cur, start = m.group(1), i
        owner.append(cur)
        if cur is not None and re.match(r"^\}\s*$", line):
            spans[cur] = (start, i)
            cur = None
    return owner, spans


def code(line):
    """return whether a line is code rather than a comment"""
    return not line.lstrip().startswith("#")


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
import unit_files  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
TEST_DIRS = test_dirs(REPO)
SHELL_DIRS = (*TEST_DIRS, *TOOL_DIRS, "src/androidd", "src/services")
SHELL_FILES = ("src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
               "src/install/prepare/data-template.sh")


def shell_files(root, suffixes=(".sh",)):
    """return the shell files under the shell directories and files"""
    found = [d + "/" + n for d in SHELL_DIRS if os.path.isdir(os.path.join(root, d))
             for n in os.listdir(os.path.join(root, d)) if n.endswith(suffixes)]
    found += [rel for rel in unit_files.unit_files(root, suffixes).values() if os.path.dirname(rel) not in SHELL_DIRS]
    found += [f for f in SHELL_FILES if f.endswith(suffixes) and os.path.isfile(os.path.join(root, f))]
    return sorted(found)


SELF_BIND_RE = re.compile(r"mount --bind\s+(/run/rhizo-wayland[^\s;'\"]*)\s+\1(?=[\s;'\"]|$)")


def check_self_binds(root):
    """return plain --bind mounts onto /run/rhizo-wayland directories"""
    problems = []
    for rel in shell_files(root, (".sh", ".service")):
        for i, line in enumerate(read(root, rel).splitlines()):
            if code(line) and SELF_BIND_RE.search(line):
                problems.append("%s:%d binds %s onto itself with a plain --bind; use --rbind"
                                % (rel, i + 1, SELF_BIND_RE.search(line).group(1)))
    return problems


def dbus_min_dirs(root, files):
    """return the dbus_min.py install directories"""
    dirs = set()
    for rel in files:
        for line in read(root, rel).splitlines():
            if not code(line) or "dbus_min.py" not in line:
                continue
            for seg in re.split(r"&&|;|\|\|", line):
                words = seg.replace('"', " ").split()
                if not words or words[0] != "install" or not any("dbus_min.py" in w for w in words[:-1]):
                    continue
                dest = words[-1]
                dirs.add(os.path.dirname(dest) if dest.endswith("dbus_min.py") else dest.rstrip("/"))
    return dirs


def check(root):
    """return the shell files that hard-code the desktop session paths"""
    problems = []
    vals = unit_values(read(root, DESKD_UNIT))
    if vals is None:
        return ["%s: no EnvironmentFile= or RuntimeDirectory= to derive from" % DESKD_UNIT]
    env_file, run_dir = vals
    files = shell_files(root)
    installs = dbus_min_dirs(root, files)

    for rel in files:
        lines = read(root, rel).splitlines()
        for i, line in enumerate(lines):
            if not code(line):
                continue
            where = "%s:%d" % (rel, i + 1)
            if "unix:path=" + run_dir + "/" in line:
                problems.append("%s names a bus inside %s, rhizo-deskd.service's RuntimeDirectory="
                                % (where, run_dir))
            if SINK_RE.search(line):
                m = re.search(r"DBUS_SESSION_BUS_ADDRESS=['\"]?unix:", line)
                if m:
                    problems.append("%s starts the notification sink on a literal bus, not the one %s names" % (where, env_file))
                for pp in re.findall(r"PYTHONPATH=['\"]?([^'\"\s]+)", line):
                    for entry in pp.split(":"):
                        if entry not in installs:
                            problems.append("%s starts the notification sink with PYTHONPATH entry %s, where no deploy script installs dbus_min.py (it does: %s)"
                                            % (where, entry, ", ".join(sorted(installs)) or "nowhere"))

    lib = read(root, ASSERT_LIB).splitlines()
    _, spans = functions(lib)
    if SINK_STARTER not in spans:
        problems.append("%s defines no %s" % (ASSERT_LIB, SINK_STARTER))
    else:
        a, b = spans[SINK_STARTER]
        body = "\n".join(lib[a:b + 1])
        if env_file not in body:
            problems.append("%s's %s never reads %s, the EnvironmentFile= that gives rhizo-deskd its bus"
                            % (ASSERT_LIB, SINK_STARTER, env_file))

    problems += check_launch_order(read(root, REDEPLOY).splitlines())
    problems += check_self_binds(root)
    return problems


def check_launch_order(lines):
    """return the redeploy.sh launch order problems"""
    enables = [i for i, l in enumerate(lines) if code(l) and re.search(r"systemctl (?:--global )?enable (?!--now)\S*.*rhizo-desktop-session\.path", l)]
    if not enables:
        return []
    owner, spans = functions(lines)
    launch = next((i for i, l in enumerate(lines) if code(l) and owner[i] is None and LAUNCH_RE.search(l)), None)
    if launch is None:
        return ["%s: no launch site (%s) to order the session resolution against" % (REDEPLOY, LAUNCH_RE.pattern)]
    restarts = [i for i, l in enumerate(lines) if code(l) and re.search(r"systemctl --user (re)?start " + re.escape(SESSION_UNIT), l)]
    for i in restarts:
        fn = owner[i]
        if fn is None and i < launch:
            return []
        if fn is not None:
            a, b = spans[fn]
            calls = [j for j, l in enumerate(lines) if code(l) and not (a <= j <= b) and owner[j] is None
                     and re.search(r"(^|[\s$(]|\$\()" + re.escape(fn) + r"(\s|\)|$)", l)]
            if calls and calls[0] < launch:
                return []
    return ["%s:%d enables rhizo-desktop-session.path but never restarts %s in that manager (systemctl --user) before its first launch at line %d"
            % (REDEPLOY, enables[0] + 1, SESSION_UNIT, launch + 1)]


GOOD_UNIT = """[Service]
User=ubuntu
EnvironmentFile=/run/rhizo-desktop/session.env
RuntimeDirectory=rhizo-desk
ExecStart=/usr/bin/python3 /usr/lib/rhizo/deskbridge/deskd.py \\
    --port 47100 --token-file /run/rhizo-desk/token
"""

GOOD_LIB = """#!/bin/bash
notify_sink_start() {
  bus=$(ssh_vm -t 10 "sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' /run/rhizo-desktop/session.env")
  gcmd_user "setsid env DBUS_SESSION_BUS_ADDRESS='$bus' PYTHONPATH=/usr/lib/rhizo sh -c '/tmp/notify-sink.py --record x'"
}
"""

GOOD_REDEPLOY = """#!/bin/bash
stage_cmd="set -e
install -m 0644 /root/share/dbus_min.py /usr/lib/rhizo/dbus_min.py
systemctl --global enable rhizo-desktop-session.path"
resolve_desktop_session() {
  ssh_vm -t 30 "runuser -u ubuntu -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart rhizo-desktop-session.service"
}
desk_session=$(resolve_desktop_session)
ssh_vm "systemctl start androidd.service"
"""

GOOD_TEST = """#!/bin/bash
desk_token_redeliver >"$EV/desktop-token-delivery.log" 2>&1 || fail "no delivery"
"""


def selftest():
    """run each planted-defect case against a copy of the tree"""
    bad = 0

    def run(name, overrides, want):
        """run the check on a temporary tree with replaced files"""
        nonlocal bad
        tmp = tempfile.mkdtemp(prefix="check-desktop-session-consumers.")
        try:
            files = {DESKD_UNIT: GOOD_UNIT, ASSERT_LIB: GOOD_LIB, REDEPLOY: GOOD_REDEPLOY,
                     "test/system/x.sh": GOOD_TEST}
            files.update(overrides)
            for rel, text in files.items():
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                with open(os.path.join(tmp, rel), "w", encoding="utf-8") as fh:
                    fh.write(text)
            got = check(tmp)
        finally:
            shutil.rmtree(tmp)
        hit = [p for p in got if want and want in p]
        if want is None and got:
            print("SELFTEST FAIL: %s: flagged %s" % (name, got))
            bad += 1
        elif want is not None and not hit:
            print("SELFTEST FAIL: %s: wanted a finding with %r, got %s" % (name, want, got))
            bad += 1
        else:
            print("SELFTEST OK: %s" % name)

    run("the correct shape passes", {}, None)
    run("the retired /run/rhizo-desk/bus is flagged",
        {ASSERT_LIB: GOOD_LIB.replace("DBUS_SESSION_BUS_ADDRESS='$bus'", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/rhizo-desk/bus")},
        "names a bus inside /run/rhizo-desk")
    run("a literal sink bus is flagged",
        {ASSERT_LIB: GOOD_LIB.replace("DBUS_SESSION_BUS_ADDRESS='$bus'", "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus")},
        "on a literal bus")
    run("a sink starter that never reads session.env is flagged",
        {ASSERT_LIB: GOOD_LIB.replace("/run/rhizo-desktop/session.env", "/tmp/elsewhere")}, "never reads /run/rhizo-desktop/session.env")
    run("a sink PYTHONPATH no deploy script installs dbus_min.py into is flagged",
        {ASSERT_LIB: GOOD_LIB.replace("PYTHONPATH=/usr/lib/rhizo", "PYTHONPATH=/usr/local/lib/rhizo")}, "PYTHONPATH entry /usr/local/lib/rhizo")
    run("an enable with no resolution before the launch is flagged",
        {REDEPLOY: GOOD_REDEPLOY.replace("desk_session=$(resolve_desktop_session)\n", "")}, "never restarts rhizo-desktop-session.service")
    run("a resolution called only after the launch is flagged",
        {REDEPLOY: GOOD_REDEPLOY.replace("desk_session=$(resolve_desktop_session)\n", "") + "resolve_desktop_session\n"},
        "never restarts rhizo-desktop-session.service")
    run("a restart in the system manager, where the user unit does not run, is flagged",
        {REDEPLOY: GOOD_REDEPLOY.replace("systemctl --user restart", "systemctl restart")},
        "never restarts rhizo-desktop-session.service")
    run("an enable --now needs no resolution",
        {REDEPLOY: GOOD_REDEPLOY.replace("enable rhizo", "enable --now rhizo").replace("desk_session=$(resolve_desktop_session)\n", "")}, None)
    run("a plain self-bind of a per-instance rendezvous is flagged",
        {"src/services/units/boot/androidd@.service": "ExecStartPre=/bin/sh -c 'mountpoint -q /run/rhizo-wayland-%i || mount --bind /run/rhizo-wayland-%i /run/rhizo-wayland-%i'\n"},
        "binds /run/rhizo-wayland-%i onto itself")
    run("a plain self-bind of instance 0's rendezvous is flagged",
        {REDEPLOY: GOOD_REDEPLOY + "mountpoint -q /run/rhizo-wayland || mount --bind /run/rhizo-wayland /run/rhizo-wayland\n"},
        "binds /run/rhizo-wayland onto itself")
    run("an --rbind self-bind and a socket file bind pass",
        {"src/services/units/boot/androidd@.service": "ExecStartPre=/bin/sh -c 'mount --rbind /run/rhizo-wayland-%i /run/rhizo-wayland-%i'\n",
         "test/vm/start-x.sh": "mount --bind /run/user/1000/wayland-1 /run/rhizo-wayland/wayland-0\n"}, None)
    run("a unit with no RuntimeDirectory= is refused",
        {DESKD_UNIT: GOOD_UNIT.replace("RuntimeDirectory=rhizo-desk\n", "")}, "no EnvironmentFile= or RuntimeDirectory=")
    return 1 if bad else 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    problems = check(args.root)
    for p in problems:
        print("FAIL: " + p)
    if problems:
        return 1
    print("check-desktop-session-consumers: the sink's bus and imports and redeploy's session resolution agree with the units")
    return 0


if __name__ == "__main__":
    sys.exit(main())
