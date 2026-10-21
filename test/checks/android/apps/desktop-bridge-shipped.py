#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

APK = "RhizoDesktop.apk"
MANIFEST = "tools/build/artifacts.tsv"
RULES = "debian/rules"
REDEPLOY = "test/vm/redeploy.sh"
TEST_LIB = "test/system/lib/lib.sh"
LAUNCHER = "src/androidd/boot.py"
HALS = "src/androidd/sandbox/hals.py"

INSTALL_RE = re.compile(r"\bpm install\b|\bapp install\b|\binstall-(create|write)\b|\binstall_apk_via_broker\b"
                        r"|\bpush\b|\bscp\b")
BRIDGE_RE = re.compile(r"com\.rhizo\.desktop|\$\{?BRIDGE_PKG\b|NotifListener|RhizoIme")
LISTENER_RE = re.compile(r"\bnotification allow_listener\b")
OVERLAY_RE = re.compile(r"\bappops set\b.*\bSYSTEM_ALERT_WINDOW\b|\bpm grant\b")
IME_ON_RE = re.compile(r"\bime (enable|set)\b")
IME_OFF_RE = re.compile(r"\bime disable\b")
DEF_RE = re.compile(r"^([A-Za-z_][\w.:-]*)\s*\(\)\s*\{")
FOR_RE = re.compile(r"^\s*for\s+(\w+)\s+in\s+(.*)$")
ASSIGN_RE = re.compile(r"(?:^|[\s;])(?:local\s+|export\s+)?(\w+)=[^\s;]*%s" % re.escape(APK))


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def code(line):
    """return whether a line is code rather than a comment"""
    return not line.lstrip().startswith("#")


RIG_SRC_FILES = (
    "src/install/prepare/align-apex.py", "src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
    "src/install/prepare/materialize-data-template.py", "src/install/prepare/data-template.sh",
    "src/androidd/host/capture-kernel-log.sh", "src/androidd/host/parse-display-list.sh",
    "src/androidd/host/launch-app.sh", "src/androidd/host/release-idle-display.sh",
    "src/androidd/host/fill-display-pool.sh", "src/androidd/host/unfreeze-cgroup.sh",
    "src/services/appsync/appsync.py", "src/services/appsync/app-events.py",
    "src/androidd/sandbox/capability-allowed.sh", "src/androidd/host/kernel-check.sh",
    "src/services/hostfs/hostfs.py", "src/services/appsync/remove-entries.sh", "src/services/appsync/resync.sh",
    "src/services/probe-client/probe-client.py")
CHECK_HELPERS_PY = ("desk_hello.py", "layout-expect.py", "parse-avc.py")


def rig_files(root):
    """return the rig shell and python files"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
    from tree_dirs import test_dirs, tool_dirs
    out = []
    for d in [os.path.join(root, t) for t in (*tool_dirs(root), "tools/mesa", "tools/patches", *test_dirs(root))]:
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if n.endswith(".sh") or (n.endswith(".py") and (
                    not os.path.relpath(d, root).startswith("test/checks") or n in CHECK_HELPERS_PY)):
                out.append(os.path.relpath(os.path.join(d, n), root))
    out += [f for f in RIG_SRC_FILES if os.path.isfile(os.path.join(root, f))]
    return out


def check_rig(root):
    """check rig files for RhizoDesktop installs and grants"""
    problems = []
    for rel in rig_files(root):
        if rel == "tools/build/apps/desktop-bridge.sh":
            continue
        scope, apk_vars, loop_var, disabled = None, {}, None, set()
        for i, line in enumerate(read(root, rel).splitlines()):
            m = DEF_RE.match(line)
            if m and not re.search(r"\}\s*$", line):
                scope, apk_vars, disabled = m.group(1), {}, set()
            elif re.match(r"^\}\s*$", line):
                scope, apk_vars, disabled = None, {}, set()
            if not code(line):
                continue
            where = "%s:%d" % (rel, i + 1)
            m = FOR_RE.match(line)
            if m and APK in m.group(2):
                loop_var = m.group(1)
            elif loop_var and re.match(r"^\s*done\b", line):
                loop_var = None
            for var in ASSIGN_RE.findall(line):
                apk_vars[var] = True
            names = [loop_var] if loop_var else []
            names += list(apk_vars)
            names_apk = APK in line or any(re.search(r"\$\{?%s\b" % re.escape(v), line) for v in names)
            if names_apk and INSTALL_RE.search(line):
                problems.append("%s installs com.rhizo.desktop itself (%s)"
                                % (where, INSTALL_RE.search(line).group(0)))
            if LISTENER_RE.search(line) and BRIDGE_RE.search(line):
                problems.append("%s grants the android app's notification listener itself"
                                % where)
            if OVERLAY_RE.search(line) and BRIDGE_RE.search(line):
                problems.append("%s grants the android app a permission or appop itself"
                                % where)
            if IME_OFF_RE.search(line):
                disabled.add(scope)
            elif IME_ON_RE.search(line) and scope not in disabled:
                problems.append("%s enables or selects an IME it never disabled in %s"
                                % (where, scope or "the top level"))
    return problems


def continued(text, start_re):
    """return the backslash-continued make assignment block"""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if re.match(start_re, line):
            out = [line]
            while out[-1].rstrip().endswith("\\") and i + len(out) < len(lines):
                out.append(lines[i + len(out)])
            return "\n".join(out)
    return ""


def shell_array(text, name):
    """return the body of a shell array"""
    m = re.search(r"^%s=\(\n(.*?)^\)" % re.escape(name), text, re.M | re.S)
    return m.group(1) if m else ""


def check_ship(root):
    """check each shipping step includes RhizoDesktop"""
    problems = []
    if not re.search(r'^%s\ttools/build/apps/desktop-bridge\.sh\t[^\t\n]*\tpayload\t' % re.escape(APK),
                     read(root, MANIFEST), re.M):
        problems.append("%s has no payload row building %s with desktop-bridge.sh" % (MANIFEST, APK))
    rules = read(root, RULES)
    if ("var/share/" + APK) not in continued(rules, r"^REQUIRED_FILES\s*:="):
        problems.append("%s does not require var/share/%s" % (RULES, APK))
    if not re.search(r"^\tinstall -m 0644 var/share/%s \$\(PAYLOAD\)/\s*$" % re.escape(APK), rules, re.M):
        problems.append("%s never installs var/share/%s into $(PAYLOAD)/, where the launcher resolves it" % (RULES, APK))
    stage = shell_array(read(root, REDEPLOY), "STAGE_FILES")
    if not re.search(r"^\s*%s\s*$" % re.escape(APK), stage, re.M):
        problems.append("%s's STAGE_FILES does not stage %s beside the rig's launcher" % (REDEPLOY, APK))
    if not re.search(r"^\s*test_require_staged\b[^\n#]*\b%s\b" % re.escape(APK), read(root, TEST_LIB), re.M):
        problems.append("%s's test_boot does not require a newly staged %s" % (TEST_LIB, APK))
    if not re.search(r"^\s*stage_desktop_bridge\(\)\s*$", read(root, LAUNCHER), re.M):
        problems.append("%s never calls stage_desktop_bridge()" % LAUNCHER)
    if ('beside("%s")' % APK) not in read(root, HALS):
        problems.append("%s does not stage beside(\"%s\"), the name the package installs" % (HALS, APK))
    return problems


def check(root):
    """return the problems from the shipping and rig checks"""
    try:
        return check_ship(root) + check_rig(root)
    except FileNotFoundError as exc:
        return ["%s is missing" % exc.filename]


def selftest():
    """run each planted-defect case"""
    bad = 0

    def run(name, plant, want):
        """run the check on a copy of the tree with a planted change"""
        nonlocal bad
        tmp = tempfile.mkdtemp(prefix="check-desktop-bridge-shipped.self.")
        try:
            for rel in ("tools", "test/vm", "test/system", "test/checks"):
                shutil.copytree(os.path.join(REPO, rel), os.path.join(tmp, rel), symlinks=True,
                                ignore=shutil.ignore_patterns("__pycache__"))
            for rel in (RULES, LAUNCHER, HALS):
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                shutil.copy(os.path.join(REPO, rel), os.path.join(tmp, rel))
            for rel, (old, new) in plant.items():
                path = os.path.join(tmp, rel)
                text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
                if old is not None and old not in text:
                    print("SELFTEST FAIL: %s: the plant anchor %r is not in %s" % (name, old, rel))
                    bad += 1
                    return
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text.replace(old, new, 1) if old is not None else text + new)
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

    test = "test/system/desktop/desktop.sh"
    cycle = "test/system/cycle/cycle.sh"
    run("the tree as committed passes", {}, None)
    run("the retired system test install loop is flagged",
        {test: (None, 'for apk in RhizoDesktop.apk rhizo-deskapp.apk; do\n'
                      '  out=$(android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/$apk")\n'
                      'done\n')}, "installs com.rhizo.desktop itself (pm install)")
    run("an adb push of the android app is flagged",
        {test: (None, 'timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$REPO/var/share/RhizoDesktop.apk" /data/local/tmp/x.apk\n')},
        "installs com.rhizo.desktop itself")
    run("a cycle installing the android app through a variable is flagged",
        {cycle: (None, '_lc_plant_bridge() {\n  local android_apk="$REPO/var/share/RhizoDesktop.apk"\n'
                       '  lc_rhizo 90 app install "$android_apk" >/dev/null 2>&1\n}\n')},
        "installs com.rhizo.desktop itself (app install)")
    run("a variable naming the android app does not leak into the next function",
        {cycle: (None, '_lc_a() {\n  local apk="$REPO/var/share/RhizoDesktop.apk"\n  [[ -f "$apk" ]]\n}\n'
                       '_lc_b() {\n  local apk=/root/rhizo-deskapp.apk\n  lc_rhizo 90 app install "$apk"\n}\n')}, None)
    run("a system test granting the android app's listener is flagged",
        {test: (None, 'android_sh "$INIT" "cmd notification allow_listener $BRIDGE_PKG/$BRIDGE_PKG.NotifListener"\n')},
        "grants the android app's notification listener itself")
    run("a system test withdrawing the listener is not flagged",
        {test: (None, 'android_sh "$INIT" "cmd notification disallow_listener $BRIDGE_PKG/$BRIDGE_PKG.NotifListener"\n')}, None)
    run("a system test granting the android app's overlay appop is flagged",
        {test: (None, 'android_sh "$INIT" "appops set com.rhizo.desktop SYSTEM_ALERT_WINDOW allow"\n')},
        "grants the android app a permission or appop itself")
    run("a system test selecting an IME it never disabled is flagged",
        {cycle: (None, '_lc_ime() {\n  android_sh "$INIT" "ime enable $ime_id"\n  android_sh "$INIT" "ime set $ime_id"\n}\n')},
        "enables or selects an IME it never disabled in _lc_ime")
    run("a claim restoring the IME it disabled itself is not flagged",
        {cycle: (None, 'lc_assert_x.ctrl() {\n  android_sh "$INIT" "ime disable $ime_id"\n'
                       '  android_sh "$INIT" "ime enable $ime_id"\n  android_sh "$INIT" "ime set $ime_id"\n}\n')}, None)
    run("a disable in another function does not excuse an enable",
        {cycle: (None, '_lc_off() {\n  android_sh "$INIT" "ime disable $ime_id"\n}\n'
                       '_lc_on() {\n  android_sh "$INIT" "ime set $ime_id"\n}\n')}, "never disabled in _lc_on")
    run("a one-line function leaves the next line at the top level",
        {test: (None, 'x_of() { echo; }\nandroid_sh "$INIT" "ime set $ime_id"\n')}, "never disabled in the top level")
    run("a comment naming the retired install is not flagged",
        {test: (None, '# the system test used to pm install RhizoDesktop.apk and allow_listener com.rhizo.desktop\n')}, None)
    run("a payload build without the android app step is flagged",
        {MANIFEST: ("RhizoDesktop.apk\ttools/build/apps/desktop-bridge.sh\tsrc/android/apps/desktop-bridge "
                    "tools/build/apps/desktop-bridge.sh\tpayload\taapt2\n", "")},
        "has no payload row")
    run("a package that does not require the android app is flagged",
        {RULES: ("                  var/share/RhizoDesktop.apk \\\n", "")}, "does not require var/share/RhizoDesktop.apk")
    run("a package that does not install the android app is flagged",
        {RULES: ("\tinstall -m 0644 var/share/RhizoDesktop.apk $(PAYLOAD)/\n", "")}, "never installs var/share/RhizoDesktop.apk")
    run("a rig deploy that does not stage the android app is flagged",
        {REDEPLOY: ("  RhizoDesktop.apk\n", "")}, "does not stage RhizoDesktop.apk")
    run("a test_boot that does not require a newly staged android app is flagged",
        {TEST_LIB: (" RhizoDesktop.apk || return 1", " || return 1")}, "does not require a newly staged RhizoDesktop.apk")
    run("a launcher that never stages the android app is flagged",
        {LAUNCHER: ("    stage_desktop_bridge()\n", "")}, "never calls stage_desktop_bridge()")
    run("a launcher staging another file name is flagged",
        {HALS: ('beside("RhizoDesktop.apk")', 'beside("RhizoDesk.apk")')}, "does not stage beside")
    return 1 if bad else 0


def main():
    """run the check or its selftest and print the result"""
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
    print("check-desktop-bridge-shipped: the payload builds, the package installs and the launcher stages com.rhizo.desktop, "
          "and no rig code installs or grants it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
