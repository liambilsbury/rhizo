#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SCAN = ("test", "tools", "src/install", "src/androidd")
SCAN_FLAT = ("src/services",)
MIN_SCANNED = 367
SELF = os.path.abspath(__file__)
MAX_SOURCE = 2 * 1024 * 1024

ENDS = re.compile(r"""^\s*($|[|;)&>]|2>|<|\\\s*$|#)""")
CALL = re.compile(r"""(?:^|\$\(|[;|&]|\b(?:then|do|else)\s|\b[A-Z_][A-Z0-9_]*=\S*\s)\s*android_sh\s+""")


def read_word(s, pos):
    """return the next shell word and its end"""
    while pos < len(s) and s[pos] in " \t":
        pos += 1
    start, depth, quote = pos, 0, None
    while pos < len(s):
        c = s[pos]
        if c == "\\":
            pos += 2
            continue
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "$" and s[pos + 1:pos + 2] == "(":
            depth += 1
            pos += 2
            continue
        elif depth and c == ")":
            depth -= 1
        elif c == '"' and not depth:
            quote = None if quote == '"' else '"'
        elif c == "'" and not quote and not depth:
            quote = "'"
        elif not quote and not depth and c in " \t|;)&<>":
            break
        pos += 1
    return (s[start:pos], pos) if pos > start else (None, pos)


def join_continuations(lines):
    """yield logical lines and their line numbers"""
    buf, start = "", None
    for n, l in enumerate(lines, 1):
        if start is None:
            start = n
        if l.rstrip().endswith("\\"):
            buf += l.rstrip()[:-1] + " "
            continue
        yield start, buf + l
        buf, start = "", None
    if buf:
        yield start, buf


def call_problems(path, text):
    """return the problems for android_sh calls with the wrong arguments"""
    problems = []
    for n, line in join_continuations(text.split("\n")):
        if line.lstrip().startswith("#"):
            continue
        for m in CALL.finditer(line):
            rest = line[m.end():]
            words, pos = [], 0
            for _ in range(2):
                w, pos = read_word(rest, pos)
                if w is None:
                    break
                words.append(w)
            if len(words) < 2:
                continue
            tail = rest[pos:]
            if not ENDS.match(tail):
                extra, _ = read_word(tail, 0)
                problems.append("%s:%d: android_sh given a word after its body (%s): %s"
                                % (path, n, extra or tail.strip()[:20], line.strip()[:140]))
    return problems


def scan(root, floor=MIN_SCANNED):
    """scan shell scripts for android_sh call problems"""
    problems = []
    scanned = 0
    walks = [(d, True) for d in SCAN] + [(d, False) for d in SCAN_FLAT]
    for d, deep in walks:
        for dirpath, dirnames, files in os.walk(os.path.join(root, d)):
            if not deep:
                dirnames[:] = []
            dirnames[:] = [x for x in dirnames if not x.startswith(("share", "suites", "gsi", "aosp"))
                           and not os.path.islink(os.path.join(dirpath, x))]
            for f in files:
                p = os.path.join(dirpath, f)
                if not f.endswith(".sh") or os.path.islink(p) or os.path.abspath(p) == SELF \
                        or os.path.getsize(p) > MAX_SOURCE:
                    continue
                try:
                    text = open(p, encoding="utf-8").read()
                except (UnicodeDecodeError, OSError):
                    continue
                scanned += 1
                if "android_sh" in text and not re.search(r"^android_sh\(\)", text, re.M) \
                        or p.endswith("test/vm/common.sh"):
                    problems += call_problems(os.path.relpath(p, root), text)
    if scanned < floor:
        problems.append("scanned %d scripts under %s, expected at least %d" % (scanned, ", ".join(SCAN + SCAN_FLAT), floor))
    return problems


def refusal_problems(common):
    """check android_sh rejects a second body argument"""
    script = r'''
source "$1" >/dev/null 2>&1
ssh_vm() { echo "GUEST_ASKED"; }
probe_cmd() { echo "GUEST_ASKED"; }
_ssh_vm_out() { echo "GUEST_ASKED"; }
android_sh 4242 "settings get global x" 20
echo "RC=$?"
'''
    r = subprocess.run(["bash", "-c", script, "x", common], capture_output=True, text=True, timeout=60)
    out = r.stdout + r.stderr
    rc = re.search(r"RC=(\d+)", out)
    if not rc or rc.group(1) == "0" or "GUEST_ASKED" in out:
        return ["android_sh accepted a second body argument instead of refusing it (%s)" % out.strip()[-200:]]
    if "android_sh" not in r.stderr:
        return ["android_sh refused a second body argument without saying so on stderr"]
    return []


def check(root):
    """return the problems from the call scan and the refusal check"""
    return scan(root) + refusal_problems(os.path.join(root, "test", "vm", "common.sh"))


GOOD = r'''
v=$(android_sh "$INIT" "settings get global x" | tr -d '\r')
ANDROID_SH_TIMEOUT=90 android_sh "$INIT" "pm list packages" 2>&1
android_sh "$init_pid" getprop > "$DEST/getprop.txt" 2>/dev/null
dri=$(android_sh "$init_pid" \
    "test -e /dev/dri/card0 && echo present" 2>/dev/null)
android_sh "$1" 'ip -4 -o addr show eth0' 2>/dev/null
dens=$(android_sh "$INIT" "wm density -d $(field "$binfo" display)" 2>/dev/null)
android_sh "$p" "settings put system t $(cat "$saved")" >/dev/null
fail "x: android_sh could not reach the guest (rc=$rc)"
for _fn in wait_for_init ssh_vm android_sh rhizo_ctl; do
[[ -n "$(android_sh "$INIT" "pidof x" 2>/dev/null)" ]]
android_sh() {
# android_sh "$INIT" "commented" 20
'''

BAD = (
    'v=$(android_sh "$INIT" "settings get global x" 20 | tr -d "[:space:]")\n',
    'android_sh "$n1_init" "settings put global x $UUID" 20 >/dev/null 2>&1\n',
    'android_sh "$INIT" \\\n  "am start -n $p/$a" 30\n',
)


def selftest():
    """test the call scan and the refusal check"""
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "x.sh")
        open(p, "w").write(GOOD)
        got = call_problems("x.sh", GOOD)
        if got:
            print("SELFTEST FAILED: correct calls refused: %s" % got, file=sys.stderr)
            failed = True
    for b in BAD:
        if not call_problems("x.sh", b):
            print("SELFTEST FAILED: a trailing word was not caught: %r" % b, file=sys.stderr)
            failed = True
    with tempfile.TemporaryDirectory() as tmp:
        lib = os.path.join(tmp, "common.sh")
        open(lib, "w").write('android_sh() { local init_pid="$1"; shift; ssh_vm -t 30 "$*"; }\n')
        if not refusal_problems(lib):
            print("SELFTEST FAILED: an android_sh that joins its arguments passed", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("selftest ok: passes %d correct call shapes, refuses %d trailing-word calls, and catches an "
          "android_sh that joins a second argument" % (GOOD.count("android_sh") - 4, len(BAD)))
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    problems = check(REPO)
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        print("check-android-sh-args: android_sh takes one body argument; its timeout is ANDROID_SH_TIMEOUT")
        return 1
    print("check-android-sh-args: every android_sh call ends at its body, and android_sh refuses a second one")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
