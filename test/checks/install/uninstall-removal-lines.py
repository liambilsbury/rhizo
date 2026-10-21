#!/usr/bin/env python3
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def findings(root_read=read):
    """return findings on the printed removal lines"""
    bad = []
    cli, teardown = root_read("src/install/cli/rhizo.sh"), root_read("src/install/teardown/teardown.sh")
    for name, text in (("rhizo.sh", cli), ("teardown.sh", teardown)):
        for m in re.finditer(r"pacman -R\w*s\b|pm=\(-R\w*s\)", text):
            line = text[:m.start()].count("\n") + 1
            if "would also take" not in text[text.rfind("\n", 0, m.start()):m.end() + 80]:
                bad.append("%s:%d runs or prints %s" % (name, line, m.group(0)))
    if "pm=(-R)" not in cli or "pm=(-Rn)" not in cli:
        bad.append("rhizo uninstall does not run pacman -R, or -Rn for --purge")
    if not re.search(r"log \"apt-get remove rhizo[^\n]*then the packages Rhizo's install added", cli):
        bad.append("rhizo uninstall on Debian names no removal of the packages Rhizo's install added after apt remove")
    if "pacman -R \\$(pacman -Qq" not in teardown:
        bad.append("the teardown's printed kernel removal is not pacman -R")
    return bad


def main():
    """run the check"""
    bad = findings()
    for line in bad:
        print("FAIL:", line)
    print("uninstall-removal-lines: %s" % ("%d findings" % len(bad) if bad else "pass"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
