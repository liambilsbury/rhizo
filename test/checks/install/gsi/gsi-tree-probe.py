#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SCANNED = [
    "src/install/prepare/fetch-gsi.sh",
    "src/install/prepare/prepare.sh",
    "src/install/teardown/teardown.sh",
    "src/install/update/gsi-update.sh",
    "src/install/cli/rhizo.sh",
    "test/system/install/gsi-update.sh",
]
BAD = re.compile(r"-x\s+[\"']?\$?[{(]?[^\s\"';)]*(?:srv/rhizo|GSI_DIR|\$GSI\b|\$TREE\b|\btree\b)[^\s\"';)]*/bin/init")


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def check(sources):
    """return failures for -x tests on bin/init"""
    fails = []
    for rel, text in sources.items():
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if BAD.search(line):
                fails.append("%s:%d asks -x on a GSI tree's bin/init; ask -s instead: %s"
                             % (rel, n, line.strip()))
    return fails


def selftest():
    """run check over the fixtures"""
    good = {rel: read(os.path.join(REPO, rel)) for rel in SCANNED if
            os.path.exists(os.path.join(REPO, rel))}
    if check(good):
        print("SELFTEST FAIL: the real tree does not pass its own check")
        return 1
    cases = [
        ("staged() goes back to -x",
         'staged() { [[ -x "$TREE/bin/init" ]]; }'),
        ("a prepare-style guard goes back to -x",
         '[[ -x "$GSI/bin/init" ]] || refuse "no-gsi-tree" "no tree"'),
        ("a system test asserts a tree with -x",
         'ssh_vm -t 15 "[ -x \'${GSI_DIR[a16]}/bin/init\' ]" && pass "staged"'),
        ("a literal /srv/rhizo path with -x",
         'if [ -x /srv/rhizo/gsi_system_a17/bin/init ]; then echo ok; fi'),
    ]
    bad = 0
    for name, line in cases:
        if not check({"fixture.sh": line}):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if check({"fixture.sh": '# measured: `[ -x $tree/bin/init ]` reads false under enforcement'}):
        print("SELFTEST FAIL: a comment describing the trap was flagged as the trap")
        bad += 1
    else:
        print("ok   selftest: a comment about the trap is not the trap")
    if check({"fixture.sh": 'staged() { [[ -s "$TREE/bin/init" ]]; }'}):
        print("SELFTEST FAIL: the -s form was flagged")
        bad += 1
    else:
        print("ok   selftest: the -s form passes")
    if bad:
        return 1
    print("check-gsi-tree-probe selftest: every fixture failed as it should")
    return 0


def main():
    """run the probe on the scanned sources or run the selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    sources = {}
    for rel in SCANNED:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            print("FAIL: no %s" % rel)
            return 1
        sources[rel] = read(path)
    fails = check(sources)
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-gsi-tree-probe: %d host-side script(s) ask whether a GSI tree is "
          "staged with a test the host domain can answer" % len(sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
