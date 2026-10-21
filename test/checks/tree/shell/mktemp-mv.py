#!/usr/bin/env python3
import os
import re
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
BARE = re.compile(r"\b(\w+)=\$\(mktemp(?:\s+-t)?\s*\)")
MOVE = r"\bmv\s+(?:-\S+\s+)*\"?\$\{?%s\}?\"?\s"


def problems_in(text, name):
    """return each bare mktemp variable the text later moves with mv"""
    out = []
    for m in BARE.finditer(text):
        var = m.group(1)
        if re.search(MOVE % re.escape(var), text[m.end():]):
            line = text.count("\n", 0, m.start()) + 1
            out.append("%s:%d: $%s comes from a bare mktemp in /tmp and is then moved with mv: make it beside "
                       "its target (mktemp \"$TARGET.XXXXXX\"), or mv copies it across filesystems and fails "
                       "to set its security.selinux label under the policy" % (name, line, var))
    return out


def problems(root):
    """return the findings for every shell script under src/"""
    out = []
    for d, _, files in os.walk(os.path.join(root, "src")):
        for f in sorted(files):
            path = os.path.join(d, f)
            if not f.endswith(".sh"):
                continue
            with open(path, encoding="utf-8", errors="replace") as fh:
                out += problems_in(fh.read(), os.path.relpath(path, root))
    return out


def selftest():
    """check the flagged and clean mktemp forms"""
    cases = {
        "a bare mktemp moved onto a /run file": ('tmp=$(mktemp)\necho x > "$tmp"\nmv "$tmp" "$MAP"\n', 1),
        "mv with a flag": ("t=$(mktemp)\nmv -f $t /run/x\n", 1),
        "a temp file made beside its target": ('tmp=$(mktemp "$MAP.XXXXXX")\nmv "$tmp" "$MAP"\n', 0),
        "a bare mktemp copied back with cat": ('tmp=$(mktemp)\ncat "$tmp" > "$F"\n', 0),
    }
    rc = 0
    for label, (text, want) in cases.items():
        got = len(problems_in(text, "fixture.sh"))
        if got != want:
            print("FAIL %s: %d findings, want %d" % (label, got, want))
            rc = 1
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "src", "androidd"))
        with open(os.path.join(d, "src", "androidd", "x.sh"), "w") as f:
            f.write(cases["a bare mktemp moved onto a /run file"][0])
        if len(problems(d)) != 1:
            print("FAIL a tree with the bare mktemp move was not flagged once")
            rc = 1
    if rc == 0:
        print("mktemp mv selftest: ok (%d cases and a tree)" % len(cases))
    return rc


def main():
    """run the selftest when asked, then check src/"""
    if "--selftest" in sys.argv[1:] and selftest():
        return 1
    bad = problems(REPO)
    for b in bad:
        print("FAIL %s" % b)
    if not bad:
        print("mktemp mv: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
