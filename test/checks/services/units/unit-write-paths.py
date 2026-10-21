#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402

JOINED = {"rhizo-resync.service": "appsync.py",
          "rhizo-remove-entries.service": "appsync.py"}


def dest_paths(src):
    """return the absolute paths Dest writes"""
    body = re.search(r"class Dest:\n(.*?)(?=\nclass |\Z)", src, re.S)
    if not body:
        return None
    prefix = re.search(r"Dest\(os\.path\.join\((\w+),\s*(.*?)\)\)", src)
    if not prefix:
        return None
    parts = [p.strip().strip('"\'') for p in prefix.group(2).split(",")]
    base = "/" + "/".join(p for p in parts if p)
    out = []
    for m in re.finditer(r"os\.path\.join\(prefix,\s*([^)]*)\)", body.group(1)):
        segs = [s.strip().strip('"\'') for s in m.group(1).split(",")]
        segs = [s for s in segs if s and not s.startswith("f")]
        if segs:
            out.append(os.path.join(base, *segs))
    return sorted(set(out))


def covered(path, allowed):
    """test a path against ReadWritePaths entries"""
    for a in allowed:
        a = a.lstrip("-")
        if path == a or path.startswith(a.rstrip("/") + "/"):
            return True
    return False


def check_unit(unit_text, writes):
    """return the writes missing from ReadWritePaths"""
    if not re.search(r"^ProtectSystem\s*=\s*strict\s*$", unit_text, re.M):
        return []
    allowed = []
    for m in re.finditer(r"^ReadWritePaths\s*=\s*(.+)$", unit_text, re.M):
        allowed.extend(m.group(1).split())
    return [w for w in writes if not covered(w, allowed)]


def main(argv):
    """run the check or its selftest"""
    if "--selftest" in argv:
        return selftest()
    src_path = os.path.join(ROOT, "src", "services", "appsync", "appsync.py")
    writes = dest_paths(open(src_path).read())
    if not writes:
        print("FAIL: could not read Dest's destinations out of appsync.py")
        return 1
    bad = 0
    for unit, _ in sorted(JOINED.items()):
        path = unit_files.unit_path(ROOT, unit)
        if not os.path.exists(path):
            print("FAIL: %s is named in this check and does not exist" % unit)
            bad = 1
            continue
        missing = check_unit(open(path).read(), writes)
        if missing:
            bad = 1
            print("FAIL: %s sets ProtectSystem=strict and does not declare "
                  "ReadWritePaths for: %s"
                  % (unit, ", ".join(missing)))
        else:
            print("ok: %s covers %s" % (unit, ", ".join(writes)))
    return bad


STRICT_NO_RWP = """[Service]
Type=oneshot
ProtectSystem=strict
ProtectHome=yes
"""

STRICT_WITH_RWP = """[Service]
Type=oneshot
ProtectSystem=strict
ReadWritePaths=-/usr/share/applications -/usr/share/icons
ProtectHome=yes
"""

STRICT_PARTIAL = """[Service]
ProtectSystem=strict
ReadWritePaths=/usr/share/applications
"""

NOT_STRICT = """[Service]
Type=oneshot
ProtectHome=yes
"""


def selftest():
    """test the unit write path checks"""
    writes = ["/usr/share/applications", "/usr/share/icons/hicolor"]
    cases = (
        ("strict with no ReadWritePaths is caught", STRICT_NO_RWP, 2),
        ("strict covering both parents passes", STRICT_WITH_RWP, 0),
        ("strict covering only one is caught for the other", STRICT_PARTIAL, 1),
        ("a unit that is not strict is not this check's business", NOT_STRICT, 0),
    )
    failures = []
    for name, text, want in cases:
        got = len(check_unit(text, writes))
        if got != want:
            failures.append("  FAIL %s: %d uncovered, expected %d" % (name, got, want))
        else:
            print("  ok: %s" % name)

    got = dest_paths(open(os.path.join(ROOT, "src", "services", "appsync", "appsync.py")).read())
    if not got or "/usr/share/applications" not in got:
        failures.append("  FAIL: Dest's destinations no longer resolve from "
                        "appsync.py (read: %s)" % got)
    else:
        print("  ok: Dest resolves to %s" % ", ".join(got))

    if failures:
        print("\n".join(failures))
        return 1
    print("check-unit-write-paths selftest: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
