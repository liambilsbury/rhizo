#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = [
    os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "add-pool-display.sh"),
    os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "launch-app.sh"),
]

BASELINE_RE = re.compile(r"^\s*powered_before=", re.MULTILINE)
ANCHOR_CAPTURE_RE = re.compile(r"^\s*reply_lineno=\$\{reply%%:\*\}", re.MULTILINE)
NUMBERED_REPLY_RE = re.compile(
    r"^\s*reply=\$\(toybox grep -n 'display (?:added|pooled) id=' ", re.MULTILINE)
ENABLE_RE = re.compile(r"^\s*cmd display enable-display ", re.MULTILINE)
CONFIRM_START_RE = re.compile(r"^([ \t]*)powered_now=\$\(", re.MULTILINE)


def strip_comments(text):
    """return the text without comment lines"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("#"))


def extract_confirm_expr(text):
    """return the one-line powered_now assignment"""
    m = CONFIRM_START_RE.search(text)
    if not m:
        return None
    rest = text[m.start():]
    depth = 0
    out = []
    for ch in rest:
        out.append(ch)
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
    else:
        return None
    return "".join(out).replace("\\\n", " ")


FIXTURE_HEAD = [
    "display list 1(960x1080,p=40,v=1) 2(960x1080,p=3,v=1) ",
    "display powered id=2 port=1",
    "display remove id=2 ok",
]
CREATION_LINE = "display pooled id=2 port=1 960x1080"


def run_confirm_expr(expr, ctlout_lines, anchor):
    """run the confirm expression and return its value"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "control.out")
        with open(path, "w") as f:
            f.write("\n".join(ctlout_lines) + "\n")
        shim = os.path.join(tmp, "bin")
        os.mkdir(shim)
        with open(os.path.join(shim, "toybox"), "w") as f:
            f.write('#!/bin/sh\nexec "$@"\n')
        os.chmod(os.path.join(shim, "toybox"), 0o755)
        script = (
            'newid=2\nnewport=1\nreply_lineno=%d\nCTLOUT=%s\n%s\nprintf "%%s" "$powered_now"\n'
            % (anchor, path, expr))
        env = dict(os.environ, PATH=shim + os.pathsep + os.environ.get("PATH", ""))
        p = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env)
        if p.returncode != 0:
            return "rc=%d %s" % (p.returncode, p.stderr.strip())
        return p.stdout.strip()


def check_one(name, text):
    """return the failures found in a script"""
    failures = []
    code = strip_comments(text)

    if BASELINE_RE.search(code):
        failures.append((name, "power-confirm keeps a powered_before baseline count"))
    if not NUMBERED_REPLY_RE.search(code):
        failures.append((name, "the creation reply is not read with `grep -n`"))
    if not ANCHOR_CAPTURE_RE.search(code):
        failures.append((name, "reply_lineno is not captured off the creation reply itself"))
    else:
        anchor_at = ANCHOR_CAPTURE_RE.search(code).start()
        enable = ENABLE_RE.search(code)
        if enable and enable.start() < anchor_at:
            failures.append((name, "reply_lineno is captured after `cmd display enable-display`"))

    expr = extract_confirm_expr(code)
    if expr is None:
        failures.append((name, "no `powered_now=$( ... )` assignment found"))
        return failures

    creation_at = len(FIXTURE_HEAD) + 1
    early = FIXTURE_HEAD + [CREATION_LINE, "display powered id=2 port=1"]
    got = run_confirm_expr(expr, early, creation_at)
    if got != "1":
        failures.append((name, "fixture 'announcement lands 0.1s after creation': expression "
                               "answered %r, expected '1'" % got))
    earlier = FIXTURE_HEAD + [CREATION_LINE, "display list 1(960x1080,p=40,v=1) 2(960x1080,pool,p=0,v=0) "]
    got = run_confirm_expr(expr, earlier, creation_at)
    if got != "0":
        failures.append((name, "fixture 'previous boot's line only': expression answered %r, "
                               "expected '0'"
                               % got))
    return failures


def check(texts):
    """return the failures for each named text"""
    failures = []
    for name, text in texts:
        failures.extend(check_one(name, text))
    return failures


SELFTEST_GOOD = """
    reply=$(toybox grep -n 'display pooled id=' "$CTLOUT" | tail -1)
    reply_lineno=${reply%%:*}
    reply=${reply#*:}
cmd display enable-display "$logid"
  powered_now=$(awk -v want="display powered id=$newid port=$newport" -v from="$reply_lineno" \\
    'NR > from && index($0, want) { n = 1; exit } END { print n + 0 }' "$CTLOUT" 2>/dev/null)
"""

SELFTEST_REVERTED = """
    reply=$(toybox grep 'display pooled id=' "$CTLOUT" | tail -1)
cmd display enable-display "$logid"
powered_before=$(toybox grep -c "display powered id=$newid port=$newport" "$CTLOUT" 2>/dev/null); powered_before=${powered_before:-0}
  powered_now=$(toybox grep -c "display powered id=$newid port=$newport" "$CTLOUT" 2>/dev/null)
"""

SELFTEST_LATE_ANCHOR = """
    reply=$(toybox grep -n 'display pooled id=' "$CTLOUT" | tail -1)
cmd display enable-display "$logid"
    reply_lineno=${reply%%:*}
  powered_now=$(awk -v want="display powered id=$newid port=$newport" -v from="$reply_lineno" \\
    'NR > from && index($0, want) { n = 1; exit } END { print n + 0 }' "$CTLOUT" 2>/dev/null)
"""

SELFTEST_ANCHOR_IGNORED = """
    reply=$(toybox grep -n 'display pooled id=' "$CTLOUT" | tail -1)
    reply_lineno=${reply%%:*}
    reply=${reply#*:}
cmd display enable-display "$logid"
  powered_now=$(awk -v want="display powered id=$newid port=$newport" -v from="$reply_lineno" \\
    'index($0, want) { n = 1; exit } END { print n + 0 }' "$CTLOUT" 2>/dev/null)
"""


def selftest():
    """check the anchored sample and each planted-defect sample"""
    good = check([("fixture", SELFTEST_GOOD)])
    if good:
        print("SELFTEST FAILED: the anchored form was rejected: %s" % good)
        return 1

    for label, text, want in [
        ("the reverted defect (baseline count after the enable)", SELFTEST_REVERTED,
         "powered_before"),
        ("an anchor captured after the enable", SELFTEST_LATE_ANCHOR, "after `cmd display"),
        ("an anchor taken and never compared against", SELFTEST_ANCHOR_IGNORED,
         "previous boot's line only"),
    ]:
        got = check([("fixture", text)])
        if not got:
            print("SELFTEST FAILED: %s was accepted" % label)
            return 1
        if not any(want in detail for _, detail in got):
            print("SELFTEST FAILED: %s was rejected, but for the wrong reason: %s"
                  % (label, got))
            return 1

    print("SELFTEST OK: the anchored form passes; a baseline count, a late anchor and an "
          "ignored anchor are each rejected by name")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    texts = []
    for path in TARGETS:
        if not os.path.exists(path):
            print("FAIL: %s does not exist" % path)
            return 1
        with open(path) as f:
            texts.append((os.path.basename(path), f.read()))
    failures = check(texts)
    for name, detail in failures:
        print("FAIL: %s: %s" % (name, detail))
    if failures:
        return 1
    print("ok: both guest scripts anchor power-confirm at the creation reply's own line, and "
          "each script's own expression reads powered on an announcement 0.1s after creation "
          "and refuses a previous boot's")
    return 0


if __name__ == "__main__":
    sys.exit(main())
