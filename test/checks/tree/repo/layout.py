#!/usr/bin/env python3

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

APPROVED = {
    "src": {"androidd", "services", "android", "install"},
    "tools": {"build", "fetch", "patches", "mesa", "maint"},
    "test": {"vm", "system", "checks", "apps"},
    "docs": {"design"},
    "kernel": {"fixes", "packaging", "tests", "tools"},
}
OPEN_TOPS = {"debian", "archlinux"}
DIRECT_FILES = {"docs", "LICENSES", "kernel"}


CAPPED = ("test/",)
CAP = 15

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))


from layout_paths import in_layout, outside_layout  # noqa: E402,F401


def top_level_rule(c):
    """return the rule a top-level path breaks, or None"""
    if c[0] in OPEN_TOPS:
        return None
    if c[0] in DIRECT_FILES and len(c) == 2:
        return None
    if c[0] in APPROVED and len(c) >= 3 and c[1] in APPROVED[c[0]]:
        return None
    return "outside the approved layout"


def violations(paths):
    """return the path violations with their rules"""
    found = []
    for p in sorted(paths):
        c = p.split("/")
        if outside_layout(p):
            continue
        rule = top_level_rule(c)
        if rule:
            found.append((p, rule))
    return found + crowded(paths)


def crowded(paths):
    """return the capped folders over their file cap"""
    held = {}
    for p in paths:
        d = os.path.dirname(p)
        if (d + "/").startswith(CAPPED):
            held[d] = held.get(d, 0) + 1
    return [(d, "holds %d tracked files, more than %d -- split it by what its files check" % (n, CAP))
            for d, n in sorted(held.items()) if n > CAP]


GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def tracked(root):
    """return the files git tracks under a root"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True,
                         capture_output=True, env=GIT_CLEAN_ENV).stdout
    return [p for p in out.decode().split("\0") if p]


def excluded(root):
    """return the tracked paths the exclude file matches"""
    common = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            check=True, capture_output=True, text=True, env=GIT_CLEAN_ENV).stdout.strip()
    exclude = os.path.join(common, "info", "exclude")
    if not os.path.isfile(exclude):
        return []
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "-ci", "--exclude-from=" + exclude],
                         check=True, capture_output=True, env=GIT_CLEAN_ENV).stdout
    return [p for p in out.decode().split("\0") if p]


def cli(root):
    """print each violation and return 1 when there are any"""
    paths = tracked(root)
    bad = violations(paths) + [(p, "tracked path matches the shared exclude file") for p in excluded(root)]
    for p, rule in bad:
        print("FAIL: %s: %s" % (p, rule))
    if bad:
        return 1
    print("check-layout: %d tracked path(s), %d in the layout, none outside it"
          % (len(paths), sum(1 for p in paths if in_layout(p))))
    return 0


def run_fixture(paths, excludes=()):
    """run the check in a temporary git repo"""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True, env=GIT_CLEAN_ENV)
        if excludes:
            with open(os.path.join(tmp, ".git", "info", "exclude"), "a") as f:
                f.write("\n".join(excludes) + "\n")
        for p in paths:
            os.makedirs(os.path.dirname(os.path.join(tmp, p)) or tmp, exist_ok=True)
            open(os.path.join(tmp, p), "w").close()
        subprocess.run(["git", "-C", tmp, "add", "-Af"], check=True, env=GIT_CLEAN_ENV)
        r = subprocess.run([sys.executable, os.path.abspath(__file__), "--root", tmp],
                           capture_output=True, text=True, env=GIT_CLEAN_ENV)
        return r.returncode, r.stdout


def selftest():
    """check the layout rules on fixture paths"""
    planted = [
        ("foo/x", "outside the approved layout"),
        ("src/launchr/x", "outside the approved layout"),
        ("src/x.md", "outside the approved layout"),
        ("tools/x.sh", "outside the approved layout"),
        ("kernel/series/0001-x.patch", "outside the approved layout"),
    ]
    hidden_patterns = [".hidden-dir", "HIDDEN-DOC.md", "HIDDEN_*.md"]
    hidden = [".hidden-dir/rules/x.md", "test/vm/.hidden-dir/x", "HIDDEN-DOC.md", "docs/design/HIDDEN-DOC.md",
              "HIDDEN_x.md", "docs/HIDDEN_x.statement.md"]
    clean = [
        "src/android/hal/gatekeeper/x.cpp",
        "test/checks/plane.py", "docs/design/delegate.md", "README.md",
        "docs/design/x-evidence.txt", "debian/rules", "debian/dropins/a.conf",
        "archlinux/PKGBUILD", ".private/x", ".private/checks/x.sh", "NOTES.md", "TODO.md",
        "docs/design/HIDDEN-DOC-code.md", "docs/design/HIDDENS.md", "test/vm/.hidden-dir-sessions.py",
        ".github/y", "LICENSE", "test/checks/tree/repo/layout.py",
        "kernel/VERSION", "kernel/fixes/0001-x.patch", "kernel/packaging/build.sh",
    ]
    bad = 0
    for p, why in planted:
        rules = " | ".join(r for q, r in violations([p]) if q == p)
        if not rules:
            print("SELFTEST FAIL: planted %s was not caught" % p)
            bad += 1
        elif why not in rules:
            print("SELFTEST FAIL: planted %s was caught as '%s', wanted '%s'" % (p, rules, why))
            bad += 1
        else:
            print("ok   selftest: %s is caught (%s)" % (p, why))
    sixteen = ["test/checks/x/c%02d.py" % i for i in range(16)]
    if not any(q == "test/checks/x" and "holds 16 tracked files" in r for q, r in violations(sixteen)):
        print("SELFTEST FAIL: a test/checks folder of 16 files was not caught: %s" % violations(sixteen))
        bad += 1
    else:
        print("ok   selftest: a test/checks folder of 16 files is caught")
    crowded_system = ["test/system/x/s%02d.sh" % i for i in range(16)]
    if not any(q == "test/system/x" and "holds 16 tracked files" in r for q, r in violations(crowded_system)):
        print("SELFTEST FAIL: a test/system folder of 16 files was not caught: %s" % violations(crowded_system))
        bad += 1
    else:
        print("ok   selftest: a test/system folder of 16 files is caught")
    if violations(sixteen[:15]) or violations(["tools/build/x/s%02d.sh" % i for i in range(16)]):
        print("SELFTEST FAIL: 15 files, or 16 outside test/, were flagged")
        bad += 1
    else:
        print("ok   selftest: 15 files in a test/checks folder pass, and the cap leaves folders outside test/ alone")
    for p in clean:
        if violations([p]):
            print("SELFTEST FAIL: clean path %s was flagged: %s" % (p, violations([p])))
            bad += 1
        else:
            print("ok   selftest: %s passes" % p)
    rc, out = run_fixture([p for p, _ in planted])
    missed = [p for p, _ in planted if "FAIL: %s: " % p not in out]
    if rc != 1 or missed:
        print("SELFTEST FAIL: a git repo of planted paths gave exit %d and no FAIL line for %s" % (rc, missed))
        bad += 1
    else:
        print("ok   selftest: the CLI exits 1 on a git repo of planted paths, a FAIL line for each")
    rc, out = run_fixture(clean)
    if rc != 0:
        print("SELFTEST FAIL: a git repo of clean paths exited %d: %s" % (rc, out))
        bad += 1
    else:
        print("ok   selftest: the CLI exits 0 on a git repo of clean paths")
    for p in hidden:
        rc, out = run_fixture(["src/androidd/ok.py", p], hidden_patterns)
        if rc != 1 or "FAIL: %s: " % p not in out:
            print("SELFTEST FAIL: tracked %s under the exclude file gave exit %d: %s" % (p, rc, out))
            bad += 1
        else:
            print("ok   selftest: tracked %s is caught by the exclude file" % p)
    rc, out = run_fixture(clean, hidden_patterns)
    if rc != 0:
        print("SELFTEST FAIL: clean paths with an exclude file present exited %d: %s" % (rc, out))
        bad += 1
    else:
        print("ok   selftest: clean paths pass with an exclude file present")
    if bad:
        return 1
    print("check-layout selftest: every fixture behaved as it should")
    return 0


def main():
    """run the check on a repo or run the selftest"""
    ap = argparse.ArgumentParser(description="fail on tracked paths outside the approved layout")
    ap.add_argument("--root", default=REPO, help="git repo to check (default: this repo)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    return selftest() if a.selftest else cli(a.root)


if __name__ == "__main__":
    sys.exit(main())
