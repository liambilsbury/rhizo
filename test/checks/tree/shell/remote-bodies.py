#!/usr/bin/env python3
import os
import re
import shlex
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
CALL = re.compile(r"\b(ssh_vm|ssh|scp)\b")
DOLLAR_PAREN = re.compile(r"(?<!\\)\$\(")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
TEST_DIRS = test_dirs(REPO)
SCAN_DIRS = (*TEST_DIRS, *TOOL_DIRS,
             "src/androidd", "src/services")
SCAN_FILES = ("src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
              "src/install/prepare/data-template.sh")
MIN_SCANNED = 330
UNBALANCED = re.compile(r"'")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")


def unclosed_quote(line, q=None):
    """return the quote character left open"""
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and q != "'":
            i += 2
            continue
        if q is None and c == "#" and (i == 0 or line[i - 1].isspace()):
            break
        if q is None and c in "\"'":
            q = c
        elif q == c:
            q = None
        i += 1
    return q


STOP = re.compile(r"^\d*[<>]|^[<>]")
OPT_WITH_VALUE = {"-t", "-o", "-p", "-i", "-l", "-F", "-b", "-c", "-w", "-J"}


def split_body(line):
    """check a call for two command bodies"""
    mo = CALL.search(line)
    if not mo:
        return False
    try:
        words = shlex.split(line[mo.start():], comments=True)
    except ValueError:
        return False
    if not words:
        return False
    args, i = [], 1
    while i < len(words):
        w = words[i]
        if w in ("||", "&&", "|", ";", "&", ")", "{", "}") or STOP.match(w):
            break
        if w in OPT_WITH_VALUE:
            i += 2
            continue
        if w.startswith("-"):
            i += 1
            continue
        args.append(w)
        i += 1
    if words[0] in ("ssh", "scp") and args:
        args = args[1:]
    return sum(1 for a in args if " " in a) > 1


def scan(path):
    """return the flagged lines in a file"""
    out = []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return out
    in_body = None
    start = 0
    carry = None
    heredoc = None
    for n, line in enumerate(lines, 1):
        if in_body is None:
            if heredoc is not None:
                if (line.lstrip("\t") if heredoc[0] else line) == heredoc[1]:
                    heredoc = None
                continue
            if carry is None and line.lstrip().startswith("#"):
                continue
            q = unclosed_quote(line, carry)
            carry = q if line.endswith("\\") else None
            mo = HEREDOC.search(line)
            if mo and q is None and "((" not in line[:mo.start()]:
                heredoc, carry = (bool(mo.group(1)), mo.group(3)), None
            if CALL.search(line):
                if q:
                    in_body, start, carry = q, n, None
                elif split_body(line):
                    out.append((n, n, "split body", line.strip()[:70]))
            continue
        if line.lstrip().startswith("#") and "'" in line:
            out.append((n, start, "comment", line.strip()[:70]))
        if in_body == '"':
            for mo in DOLLAR_PAREN.finditer(line):
                out.append((n, start, "host-side $(", line.strip()[:70]))
        if unclosed_quote(line, in_body) is None:
            in_body = None
    return out


SELFTEST_FIXTURE = """#!/bin/bash
out=$(ssh_vm -t 20 "x='y'; "'
  # a comment with an apostrophe: the GSI's libc
  echo hello
')
res=$(ssh_vm -t 20 "
  err=$(some-guest-only-binary --check)
  echo done
")
ip=$(ssh_vm -t 10 'pgrep -f 'init [s]econd_stage' | head -1')
ok=$(ssh_vm -t 10 "pgrep -f 'init [s]econd_stage' | head -1")
g=$(ssh_vm -t 20 "x='$gsi'; "'echo one body')
eval "$(claim --vm "$v" \\
  --purpose "guest on ssh $port")" || return 1
# the host's comment after a closed continuation
h=$(date +%s)
x="a \\
b"; r=$(ssh_vm -t 20 "
  late=$(host-only-binary)
")
cat <<'EOT'
the guest's own log, \
ssh_vm reads it
EOT
# the host's comment after a heredoc body ending in a backslash
hd=$(date +%s)
# the host's note, which does not continue \
hc=$(date +%s)
"""


def selftest():
    """run the scanner on its fixture file"""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "fixture.sh")
        open(f, "w").write(SELFTEST_FIXTURE)
        hits = scan(f)
    kinds = {k for _, _, k, _ in hits}
    for want in ("comment", "host-side $(", "split body"):
        if want not in kinds:
            print("SELFTEST FAILED: the '%s' rule did not fire on its own fixture "
                  "(fired: %s)"
                  % (want, sorted(kinds) or "nothing"), file=sys.stderr)
            return 1
    split_lines = [t for _, _, k, t in hits if k == "split body"]
    if len(split_lines) != 1 or "ip=" not in split_lines[0]:
        print("SELFTEST FAILED: the 'split body' rule matched %d lines, expected exactly "
              "the nested-quote one (matched: %s)" % (len(split_lines), split_lines), file=sys.stderr)
        return 1
    host_side = [t for _, _, _, t in hits if t.startswith(("# the host's", "h=$(date", "hd=$(date", "hc=$(date"))]
    if host_side:
        print("SELFTEST FAILED: a continuation line that closes its quote was read as opening a "
              "remote body, flagging host lines after it: %s" % host_side, file=sys.stderr)
        return 1
    if not any(k == "host-side $(" and t.startswith("late=$(") for _, _, k, t in hits):
        print("SELFTEST FAILED: a remote body opened on the line after a continuation that "
              "carries an open quote was not scanned: %s" % hits, file=sys.stderr)
        return 1
    print("selftest ok: detects a comment in a remote body, host-side $( ) in one, and a "
          "body split in two by nested quotes; passes correct quoting")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    paths = []
    for sub in SCAN_DIRS:
        d = os.path.join(REPO, sub)
        if not os.path.isdir(d):
            bad.append("%s: scan directory missing" % sub)
            continue
        paths += [os.path.join(d, f) for f in sorted(os.listdir(d)) if f.endswith(".sh")]
    paths += [os.path.join(REPO, f) for f in SCAN_FILES]
    if len(paths) < MIN_SCANNED:
        bad.append("scanned %d scripts, expected at least %d" % (len(paths), MIN_SCANNED))
    for p in paths:
        rel = os.path.relpath(p, REPO)
        for n, start, kind, text in scan(p):
            what = {
                "comment": "comment inside the remote body",
                "host-side $(": "$( ) that runs on the HOST, inside the remote body",
                "split body": "the body splits into TWO arguments -- nested quotes",
            }[kind]
            bad.append("%s:%d: %s opened at line %d\n    %s"
                       % (rel, n, what, start, text))
    if bad:
        print("a remote command body is not what it looks like:", file=sys.stderr)
        for b in bad:
            print("  " + b, file=sys.stderr)
        print("  comments: move the comment above the call.\n"
              "  $( ): escape it as \\$( so it runs on the guest, or lift it out of the body.\n"
              "  split body: double-quote the outside, single-quote inside:\n"
              "    ssh_vm -t 10 \"pgrep -f 'init [s]econd_stage'\".",
              file=sys.stderr)
        return 1
    print("no remote body carries a comment, a host-side $( ), or a split body")
    return 0


if __name__ == "__main__":
    sys.exit(main())
