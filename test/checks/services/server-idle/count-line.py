#!/usr/bin/env python3
import importlib.util
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
DETECTOR = os.path.join(REPO, "src", "services", "server-idle", "server-idle.py")
LIB = os.path.join(REPO, "test", "system", "lib", "server-assert-lib.sh")
SERVER = os.path.join(REPO, "test", "system", "boot", "server.sh")
CYCLE = os.path.join(REPO, "test", "system", "cycle", "cycle-selftest.sh")
CLAIMS = os.path.join(REPO, "test", "system", "cycle", "claims-server.sh")
PACKAGING = (os.path.join(REPO, "debian", "control"),
             os.path.join(REPO, "archlinux", "rhizo", "PKGBUILD.in"),
             os.path.join(REPO, "tools", "fetch", "pools", "arch", "arch-pool-lib.sh"))


def load_detector(sandbox_id):
    """import the detector at a sandbox id"""
    os.environ["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    sys.path[:0] = [os.path.join(REPO, "src", "androidd")]
    spec = importlib.util.spec_from_file_location(f"idle{sandbox_id}", DETECTOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def session_regex(lib_text):
    """return the regex session_counted greps the journal with"""
    m = re.search(r"^session_counted\(\) \{\n\s*grep -qE '([^']*)'", lib_text, re.M)
    return m.group(1) if m else None


def verdict_findings(detector_text, claims_text, packaging):
    """return stale verdict and conntrack CLI findings"""
    m = re.search(r'^LC_IDLE_VERDICT_RE="([^"]*)"', claims_text, re.M)
    if not m:
        return ["claims-server.sh: no LC_IDLE_VERDICT_RE to test"]
    bad = [f"claims-server.sh accepts the verdict '{alt}', which server-idle.py never prints"
           for alt in m.group(1).split("|") if alt.replace("\\", "") not in detector_text]
    for name, text in packaging.items():
        if "conntrack-tools" in text or "conntrack -E" in text:
            bad.append(f"{name} names the conntrack CLI, which server-idle.py never runs")
    return bad


def check(detector, lib_text, server_text, cycle_text):
    """return every finding"""
    if not hasattr(detector, "count_line") or not hasattr(detector, "start_line"):
        return ["server-idle.py: no count_line() or start_line() to take the logged lines from"]
    rx = session_regex(lib_text)
    if rx is None:
        return ["server-assert-lib.sh: no session_counted grep to test"]
    bad = []
    new, zero, gone = detector.count_line(1, "NEW"), detector.count_line(0, "NEW"), detector.count_line(1, "DESTROY")
    if not re.search(rx, new):
        bad.append(f"session_counted's '{rx}' misses the detector's own counted line '{new}'")
    for line in (zero, gone):
        if re.search(rx, line):
            bad.append(f"session_counted's '{rx}' counts '{line}'")
    m = re.search(r"^\s*IDLE_NEW_LINE='([^']*)'", server_text, re.M)
    if not m or m.group(1) != new:
        bad.append(f"server.sh's IDLE_NEW_LINE is {m.group(1) if m else '<absent>'!r}, not the detector's '{new}'")
    if f'echo "{new}"' not in cycle_text:
        bad.append(f"cycle-selftest.sh's counted-session fixture does not echo the detector's '{new}'")
    start = detector.start_line(0)
    m = re.search(r'^\s*IDLE_SEED_LINE="([^"]*)"', server_text, re.M)
    if not m or m.group(1) != start:
        bad.append(f"server.sh's IDLE_SEED_LINE is {m.group(1) if m else '<absent>'!r}, not the detector's '{start}'")
    stale = [line.strip() for line in cycle_text.splitlines()
             if "started this run's own session count" in line and "echo" in line and start not in line]
    if stale:
        bad.append(f"cycle-selftest.sh's start fixtures do not echo the detector's '{start}': {stale[0][:120]}")
    return bad


def read(path):
    """return a file's text"""
    with open(path) as f:
        return f.read()


def selftest(detector, lib_text, server_text, cycle_text):
    """flag each defect and pass the real files"""
    rx = session_regex(lib_text)
    cases = (
        ("a regex for conntrack's bracketed line", lib_text.replace(rx, r"count=[1-9][0-9]* .*\[NEW\]"), server_text, cycle_text, "misses the detector's own"),
        ("a regex that counts a zero", lib_text.replace(rx, r"count=[0-9]+ NEW"), server_text, cycle_text, "counts 'count=0"),
        ("a regex that counts a destroy", lib_text.replace(rx, r"count=[1-9][0-9]* "), server_text, cycle_text, "DESTROY"),
        ("a stale server.sh fixture", lib_text, re.sub(r"(?m)^(\s*IDLE_NEW_LINE=)'[^']*'", r"\1'count=1 [NEW] tcp 6'", server_text), cycle_text, "IDLE_NEW_LINE"),
        ("a stale cycle-selftest.sh fixture", lib_text, server_text, cycle_text.replace(detector.count_line(1, "NEW"), "count=1 [NEW] tcp"), "cycle-selftest.sh"),
        ("a stale server.sh start fixture", lib_text, server_text.replace(detector.start_line(0), "started this run's own session count at 0"),
         cycle_text, "IDLE_SEED_LINE"),
        ("a stale cycle.sh start fixture", lib_text, server_text,
         cycle_text.replace(detector.start_line(0), "started this run's own session count at 0 -- is never read", 1), "start fixtures"),
    )
    bad = []
    for label, lt, st, ct, needle in cases:
        got = check(detector, lt, st, ct)
        if not any(needle in g for g in got):
            bad.append(f"{label} was not flagged: {got}")
    if check(detector, lib_text, server_text, cycle_text):
        bad.append(f"the real files have findings: {check(detector, lib_text, server_text, cycle_text)}")
    return bad


def verdict_selftest(detector_text, claims_text, packaging):
    """flag a stale verdict and a conntrack-tools dependency"""
    bad = []
    stale = claims_text.replace('LC_IDLE_VERDICT_RE="', 'LC_IDLE_VERDICT_RE="no conntrack in PATH|', 1)
    if not any("never prints" in g for g in verdict_findings(detector_text, stale, packaging)):
        bad.append("a verdict the detector never prints was not flagged")
    pkgbuild = dict(packaging)
    key = next(k for k in pkgbuild if k.endswith("PKGBUILD.in"))
    pkgbuild[key] += "\noptdepends=('conntrack-tools: server profile idle stop')\n"
    if not any("conntrack CLI" in g for g in verdict_findings(detector_text, claims_text, pkgbuild)):
        bad.append("a conntrack-tools dependency was not flagged")
    return bad


def main():
    """run the check or its selftest"""
    args = (load_detector(0), read(LIB), read(SERVER), read(CYCLE))
    verdict_args = (read(DETECTOR), read(CLAIMS), {os.path.relpath(p, REPO): read(p) for p in PACKAGING})
    if "--selftest" in sys.argv[1:]:
        bad = selftest(*args) + verdict_selftest(*verdict_args)
        real = verdict_findings(*verdict_args)
        if real:
            bad.append(f"the real files have findings: {real}")
    else:
        bad = check(*args) + verdict_findings(*verdict_args)
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
