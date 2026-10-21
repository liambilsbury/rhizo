#!/usr/bin/env python3
import io
import os
import re
import sys
import tokenize

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

PY_FILES = ["boot.py", "sandbox/hals.py", "sandbox/rootfs.py",
            "sandbox/selinux_labels.py", "sandbox/guest_files.py", "sandbox/selinux_policy.py"]
SH_FILE = "src/install/cli/rhizo.sh"
UNIT_FILES = ["src/services/units/boot/androidd.service", "src/services/units/boot/androidd@.service"]
START_SCRIPTS = ["test/vm/start/start-audio.sh", "test/vm/start/start-deskd.sh",
                 "test/vm/start/start-unit.sh",
                 "test/vm/start/start-netbridge.sh"]

TARGETS = [
    (re.compile(r'/run/rhizo(?!-)'), "RUN_ROOT"),
    (re.compile(r'/sys/fs/cgroup/rhizo(?!-)'), "CGROUP_ROOT"),
    (re.compile(r'vethrhz0\b'), "VETH_HOST_IF"),
    (re.compile(r'192\.168\.100\b'), "NET_SUBNET/NET_HOST_ADDR/NET_POOL_START/NET_POOL_END"),
    (re.compile(r'--unit=rhizo-netbridged(?!-)'), "NETBRIDGED_UNIT"),
    (re.compile(r'RuntimeDirectory=rhizo-netbridged(?!-)'), "NETBRIDGED_RUNTIME_DIR"),
    (re.compile(r'\brhizo-netbridged\.service\b'), "NETBRIDGED_UNIT"),
    (re.compile(r'/tmp/rhizo-netbridged\.log\b'), "NETBRIDGED_LOG"),
    (re.compile(r'/var/lib/rhizo/device-state\b'), "RHIZO_DEVICE_STATE_DIR"),
    (re.compile(r'/run/rhizo-netbridged(?!-)'), "NETBRIDGED_RUNTIME_DIR"),
    (re.compile(r'RuntimeDirectory=rhizo-wayland(?!-)'), "the per-instance Wayland runtime dir"),
    (re.compile(r'/run/rhizo-wayland(?!-)'), "the per-instance Wayland runtime dir"),
    (re.compile(r'/run/rhizo-host-primer\.py\b'), "HOST_PRIMER_PATH"),
    (re.compile(r'/run/rhizo-launch(?!-)'), "the per-instance launch-log dir"),
    (re.compile(r'02:52:48:5a:00:01'), "NET_GUEST_MAC"),
]

ALLOWED_LINES = {
    SH_FILE: {"RUN_ROOT=/run/rhizo", "root=/run/rhizo"},
    "src/services/units/boot/androidd.service": {
        "RuntimeDirectory=rhizo-wayland",
    },
    "test/vm/start/start-deskd.sh": {
        "grep -q 'listening on 192.168.100.1:$PORT' $LOG && break",
        "grep -q 'listening on 192.168.100.1:$PORT' $LOG && echo DESKD_LISTENING",
        'log "FAIL: rhizo-deskd is not listening on 192.168.100.1:$PORT"',
    },
}


def read_sources():
    """return the text of the scanned sources"""
    texts = {fn: open(os.path.join(REPO, "src", "androidd", fn)).read() for fn in PY_FILES}
    texts[SH_FILE] = open(os.path.join(REPO, SH_FILE)).read()
    for fn in UNIT_FILES:
        texts[fn] = open(os.path.join(REPO, fn)).read()
    for fn in START_SCRIPTS:
        texts[fn] = open(os.path.join(REPO, fn)).read()
    return texts


def _py_findings(name, text):
    """list single-line strings with a TARGETS pattern"""
    bad = []
    toks = tokenize.generate_tokens(io.StringIO(text).readline)
    for t in toks:
        if t.type not in (tokenize.STRING, getattr(tokenize, "FSTRING_MIDDLE", -1)):
            continue
        if t.start[0] != t.end[0]:
            continue
        for pat, const in TARGETS:
            if pat.search(t.string):
                bad.append("%s:%d: literal reachable only through %s -- %s"
                           % (name, t.start[0], const, t.string.strip()[:80]))
    return bad


def _sh_findings(name, text):
    """return the shell lines naming the run root literally"""
    bad = []
    allowed = ALLOWED_LINES.get(name, set())
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#") or stripped in allowed:
            continue
        for pat, const in TARGETS:
            if pat.search(line):
                bad.append("%s:%d: literal reachable only through %s -- %s"
                           % (name, i, const, stripped[:80]))
    return bad


def check(texts):
    """return the findings in every source text"""
    bad = []
    for fn in PY_FILES:
        bad += _py_findings(fn, texts[fn])
    bad += _sh_findings(SH_FILE, texts[SH_FILE])
    for fn in UNIT_FILES:
        bad += _sh_findings(fn, texts[fn])
    for fn in START_SCRIPTS:
        bad += _sh_findings(fn, texts[fn])
    return bad


def selftest():
    """check the scan on injected sources"""
    texts = read_sources()
    n = 0

    found = check(texts)
    py_found = [f for f in found if any(f.startswith(fn + ":") for fn in PY_FILES)]
    assert py_found == [], "the six launcher modules must pass: %s" % py_found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_x = "/run/rhizo/leftover"\n'})
    found = check(injected)
    assert any("boot.py" in f and "RUN_ROOT" in f for f in found), found
    n += 1

    injected = dict(texts, **{"sandbox/hals.py": texts["sandbox/hals.py"] + '\n_y = "/sys/fs/cgroup/rhizo/x"\n'})
    found = check(injected)
    assert any("CGROUP_ROOT" in f for f in found), found
    n += 1

    injected = dict(texts, **{"sandbox/rootfs.py": texts["sandbox/rootfs.py"] + '\n_z = "vethrhz0"\n'})
    found = check(injected)
    assert any("VETH_HOST_IF" in f for f in found), found
    n += 1

    injected = dict(texts, **{"sandbox/rootfs.py": texts["sandbox/rootfs.py"] + '\n_s = "192.168.100.5"\n'})
    found = check(injected)
    assert any("NET_SUBNET" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_u = "--unit=rhizo-netbridged"\n'})
    found = check(injected)
    assert any("NETBRIDGED_UNIT" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_r = "RuntimeDirectory=rhizo-netbridged"\n'})
    found = check(injected)
    assert any("NETBRIDGED_RUNTIME_DIR" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_svc = "rhizo-netbridged.service"\n'})
    found = check(injected)
    assert any("NETBRIDGED_UNIT" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_log = "/tmp/rhizo-netbridged.log"\n'})
    found = check(injected)
    assert any("NETBRIDGED_LOG" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_bare = "rhizo-netbridged"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert found == [], "the bare word alone must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{
        "boot.py": texts["boot.py"] + '\n_ok = "--unit=rhizo-netbridged-3"\n'
                                                 '\n_ok2 = "RuntimeDirectory=rhizo-netbridged-3"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert found == [], "the correctly-instanced id>=1 form must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n# see /run/rhizo for details\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert found == [], "a comment must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{
        "sandbox/hals.py": texts["sandbox/hals.py"] + '\ndef _f():\n    """lands under\n    /run/rhizo eventually"""\n'})
    found = [f for f in check(injected) if f.startswith("sandbox/hals.py:")]
    assert found == [], "a multi-line docstring must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{SH_FILE: texts[SH_FILE] + '\nPROBE_SOCK=/run/rhizo/data/x\n'})
    found = check(injected)
    assert any(SH_FILE in f and "RUN_ROOT" in f for f in found), found
    n += 1

    injected = dict(texts, **{"sandbox/rootfs.py": texts["sandbox/rootfs.py"] + '\n_fs = "/var/lib/rhizo/device-state"\n'})
    found = [f for f in check(injected) if f.startswith("sandbox/rootfs.py:")]
    assert any("RHIZO_DEVICE_STATE_DIR" in f for f in found), found
    n += 1

    injected = dict(texts, **{
        "sandbox/rootfs.py": texts["sandbox/rootfs.py"] + '\n_fs_ok = f"{RHIZO_DEVICE_STATE_DIR}/battery.conf"\n'})
    found = [f for f in check(injected) if f.startswith("sandbox/rootfs.py:")]
    assert found == [], "referencing RHIZO_DEVICE_STATE_DIR by name must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_nbstate = "/run/rhizo-netbridged"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert any("NETBRIDGED_RUNTIME_DIR" in f for f in found), found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_nbstate_ok = "/run/rhizo-netbridged-3"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert found == [], "the correctly-instanced netbridged state dir must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{
        "src/services/units/boot/androidd.service": texts["src/services/units/boot/androidd.service"]
        + "\nExecStartPost=/bin/echo /run/rhizo-wayland ready\n"})
    found = [f for f in check(injected) if f.startswith("src/services/units/boot/androidd.service:")]
    assert any("Wayland" in f for f in found), found
    n += 1

    injected = dict(texts, **{
        "src/services/units/boot/androidd.service": texts["src/services/units/boot/androidd.service"] + "\nRuntimeDirectory=rhizo-wayland-3\n"})
    found = check(injected)
    assert not any("rhizo-wayland-3" in f for f in found), \
        "the correctly-instanced Wayland runtime dir must not be flagged: %s" % found
    n += 1

    found = [f for f in check(texts) if f.startswith("src/services/units/boot/androidd.service:")]
    assert found == [], "androidd.service's own id-0 Wayland lines must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{"sandbox/selinux_labels.py": texts["sandbox/selinux_labels.py"] + '\n_hp = "/run/rhizo-host-primer.py"\n'})
    found = [f for f in check(injected) if f.startswith("sandbox/selinux_labels.py:")]
    assert any("HOST_PRIMER_PATH" in f for f in found), found
    n += 1

    injected = dict(texts, **{
        "sandbox/selinux_labels.py": texts["sandbox/selinux_labels.py"] + '\n_hp_ok = f"running {HOST_PRIMER_PATH} now"\n'})
    found = [f for f in check(injected) if f.startswith("sandbox/selinux_labels.py:")]
    assert found == [], "referencing HOST_PRIMER_PATH by name must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{SH_FILE: texts[SH_FILE] + "\nEXTRA_LOG=/run/rhizo-launch/extra.log\n"})
    found = check(injected)
    assert any("extra.log" in f for f in found), found
    n += 1

    injected = dict(texts, **{SH_FILE: texts[SH_FILE] + "\nEXTRA_LOG=/run/rhizo-launch-3/extra.log\n"})
    found = check(injected)
    assert not any("rhizo-launch-3" in f for f in found), \
        "the correctly-instanced launch-log dir must not be flagged: %s" % found
    n += 1

    injected = dict(texts, **{"boot.py": texts["boot.py"] + '\n_mac = "02:52:48:5a:00:01"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert any("NET_GUEST_MAC" in f for f in found), found
    n += 1

    injected = dict(texts, **{
        "boot.py": texts["boot.py"] + '\n_mac_ok = f"guest mac is {NET_GUEST_MAC}"\n'})
    found = [f for f in check(injected) if f.startswith("boot.py:")]
    assert found == [], "referencing NET_GUEST_MAC by name must not be flagged: %s" % found
    n += 1

    found = [f for f in check(texts) if any(f.startswith(fn + ":") for fn in START_SCRIPTS)]
    assert found == [], "the four start-*.sh scripts must pass clean: %s" % found
    n += 1

    injected = dict(texts, **{
        "test/vm/start/start-audio.sh": texts["test/vm/start/start-audio.sh"] + "\nEXTRA=/run/rhizo/leftover\n"})
    found = check(injected)
    assert any("test/vm/start/start-audio.sh" in f and "RUN_ROOT" in f for f in found), found
    n += 1

    injected = dict(texts, **{
        "test/vm/start/start-netbridge.sh": texts["test/vm/start/start-netbridge.sh"] + "\nEXTRA_MAC=02:52:48:5a:00:01\n"})
    found = check(injected)
    assert any("test/vm/start/start-netbridge.sh" in f and "NET_GUEST_MAC" in f for f in found), found
    n += 1

    print("check-run-root-literal selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = check(read_sources())
    for f in findings:
        print("check-run-root-literal: " + f)
    sys.exit(1 if findings else 0)
