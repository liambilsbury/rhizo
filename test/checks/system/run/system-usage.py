#!/usr/bin/env python3
# check usage.sh prints a section for all of the system tests
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
SECTION = re.compile(r"^=== (\S+)$")
BOOT_MODE = re.compile(r"^  boot mode: \S")


def problems(names, out, err):
    """return what usage.sh's output lacks"""
    found = [] if names else ["no system test found"]
    if err.strip():
        found.append("usage.sh wrote to stderr: %s" % err.strip().split("\n")[0][:160])
    sections, current = {}, None
    for line in out.split("\n"):
        m = SECTION.match(line)
        if m:
            current = m.group(1)
            sections[current] = []
        elif current is not None:
            sections[current].append(line)
    for name in names:
        if name not in sections:
            found.append("%s: usage.sh prints no section for it" % name)
        elif not any(BOOT_MODE.match(l) for l in sections[name]):
            found.append("%s: usage.sh prints no boot mode for it" % name)
    return found


def run(root):
    """return the problems of usage.sh over the tree at root"""
    run_dir = os.path.join(root, "test", "system", "run")
    names = subprocess.run(["python3", os.path.join(run_dir, "system_tests.py")],
                           capture_output=True, text=True, check=True).stdout.split()
    r = subprocess.run(["bash", os.path.join(run_dir, "usage.sh")], capture_output=True, text=True, cwd=root)
    found = problems(names, r.stdout, r.stderr)
    if r.returncode != 0:
        found.append("usage.sh exited %d" % r.returncode)
    return names, found


def main(root):
    """check usage.sh over the tree at root"""
    names, found = run(root)
    for line in found:
        print("FAIL: " + line)
    if found:
        return 1
    print("system usage: usage.sh prints a section with a boot mode for each of the %d system tests" % len(names))
    return 0


def selftest():
    """test problems() and run the real check"""
    good = "=== a.sh\n  boot mode: shared\n  flags: --skip-boot\n\n=== b.sh\n  boot mode: cold-required\n"
    bad = []
    if problems(["a.sh", "b.sh"], good, ""):
        bad.append("well-formed output was flagged: %s" % problems(["a.sh", "b.sh"], good, ""))
    for label, out, err, want in (
            ("a test with no boot mode", good.replace("  boot mode: cold-required\n", ""), "", "b.sh: usage.sh prints no boot mode"),
            ("a test with no section", good.split("\n\n")[0] + "\n", "", "b.sh: usage.sh prints no section"),
            ("an error on stderr", good, "sed: can't read missing.sh\n", "wrote to stderr"),
            ("an empty system test list", good, "", "no system test")):
        got = problems([] if want == "no system test" else ["a.sh", "b.sh"], out, err)
        if not any(want in g for g in got):
            bad.append("%s was not flagged: %s" % (label, got))
    for line in bad:
        print("FAIL selftest: " + line)
    if bad:
        return 1
    print("system usage selftest: a missing boot mode, a missing section, stderr output and an empty test list each fail")
    return main(REPO)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--selftest" in args:
        sys.exit(selftest())
    sys.exit(main(args[args.index("--root") + 1] if "--root" in args else REPO))
