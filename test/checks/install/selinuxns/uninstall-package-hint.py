#!/usr/bin/env python3
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
OVERRIDE = re.compile(r"APT::AutoRemove::|NeverAutoRemove|-o APT::")
CLAUSES = ("Rhizo kernel's packages;", "then the packages Rhizo's install added")


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def findings(cli_text):
    """return hints that widen or misorder autoremove"""
    bad = []
    hints = re.findall(r'^\s*log "apt-get (?:purge|remove) rhizo;[^"]*"', cli_text, re.M)
    if len(hints) != 2:
        bad.append("rhizo.sh has %d apt remove or purge hints, not 2" % len(hints))
    for hint in hints:
        if OVERRIDE.search(hint) or "autoremove" in hint:
            bad.append("the hint names apt autoremove or an option that widens it: %s" % hint.strip())
        for clause in CLAUSES:
            if clause not in hint:
                bad.append("the hint lacks %r: %s" % (clause, hint.strip()))
    return bad


def selftest():
    """check the tree passes and planted defects fail"""
    bad = []
    cli = read("src/install/cli/rhizo.sh")
    got = findings(cli)
    if got:
        bad.append("the tree has findings: %r" % got)
    widened = cli.replace("then the packages Rhizo's install added", "then the packages Rhizo's install added, or "
                          "apt autoremove -o APT::AutoRemove::SuggestsImportant=false", 1)
    if not any("widens" in g for g in findings(widened)):
        bad.append("a hint with autoremove and the Suggests override was not named")
    for clause in CLAUSES:
        got = findings(cli.replace(clause, "x"))
        if not any("the hint lacks %r" % clause in g for g in got):
            bad.append("a hint without %r was not named: %r" % (clause, got))
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else findings(read("src/install/cli/rhizo.sh"))
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
