#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
CALLEE = os.path.join(ROOT, "src", "androidd", "guest", "bin", "launch-app.sh")
CALLER = os.path.join(ROOT, "src", "androidd", "host", "launch-app.sh")
CALLEE_NAME = "rhizo-launch-app.sh"

READ = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=.*"\$\{?(\d+)\}?"')
CALL = re.compile(r"/system_ext/bin/" + re.escape(CALLEE_NAME) + r"([^\"]*)")


def read_params(src):
    """return (variable name, base64) for each position the script reads at top level"""
    out = {}
    for line in src.split("\n"):
        m = READ.match(line)
        if m:
            out.setdefault(int(m.group(2)), (m.group(1), "base64 -d" in line))
    return out


def call_args(src):
    """return the arguments passed to the callee"""
    m = CALL.search(src)
    if not m:
        return None
    return m.group(1).split()


def is_b64(token):
    """return whether a token names a base64 argument"""
    return token.lower().rstrip("'\"").endswith("_b64") or "_b64" in token.lower()


def check(callee_src, caller_src):
    """compare the call arguments with the parameters the callee reads"""
    findings = []
    reads = read_params(callee_src)
    if not reads:
        return ["%s reads no positional parameters" % CALLEE_NAME]
    gaps = [pos for pos in range(1, max(reads) + 1) if pos not in reads]
    if gaps:
        findings.append("%s never reads parameter %s" % (CALLEE_NAME, " ".join("$%d" % g for g in gaps)))
    header = [reads.get(pos, ("?", False)) for pos in range(1, max(reads) + 1)]
    args = call_args(caller_src)
    if args is None:
        return findings + ["rhizo-launch.sh does not invoke %s" % CALLEE_NAME]
    if len(args) != len(header):
        findings.append("rhizo-launch.sh passes %d arguments to %s, which takes %d (%s)"
                        % (len(args), CALLEE_NAME, len(header), " ".join(name for name, _ in header)))
    for i, (got, (name, decoded)) in enumerate(zip(args, header), start=1):
        want = decoded or is_b64(name)
        if want != is_b64(got):
            findings.append("argument %d is %s to %s and %s at the call site (%s vs %s)"
                            % (i, "base64" if want else "plain", CALLEE_NAME,
                               "base64" if is_b64(got) else "plain", name, got))
    return findings


def selftest():
    """run check on modified file copies"""
    n = 0
    callee = open(CALLEE).read()
    caller = open(CALLER).read()
    assert len(read_params(callee)) == 16, "the positional reads parsed to %s" % read_params(callee)
    n += 1
    assert call_args(caller), "the call site parsed to nothing"
    n += 1
    assert check(callee, caller) == [], "the real tree disagrees: %s" % check(callee, caller)
    n += 1
    args = call_args(caller)
    broken_call = caller.replace(" ".join(args),
                                 " ".join(args[:9] + ["'$VIEW_URI'", args[9], args[10]]), 1)
    out = check(callee, broken_call)
    assert any("passes 12 arguments" in f for f in out), out
    assert any("argument 10 is base64" in f for f in out), out
    n += 1
    short = callee.replace('REUSE_CID="${16}"\n', "", 1)
    out = check(short, caller)
    assert any("passes 16 arguments" in f and "which takes 15" in f for f in out), out
    n += 1
    gap = callee.replace('VIEW_MIME=$(echo "${13}" | toybox base64 -d)\n', "", 1)
    out = check(gap, caller)
    assert any("never reads parameter $13" in f for f in out), out
    n += 1
    plain = callee.replace('VIEW_URI=$(echo "${12}" | toybox base64 -d)', 'VIEW_URI="${12}"', 1)
    out = check(plain, caller)
    assert any("argument 12 is plain" in f for f in out), out
    n += 1
    dropped = caller.replace(" '$view_mime_b64'", "", 1)
    out = check(callee, dropped)
    assert any("passes 15 arguments" in f for f in out), out
    n += 1
    no_deadline = caller.replace(" '$on_top_deadline'", "", 1)
    out = check(callee, no_deadline)
    assert any("passes 15 arguments" in f for f in out), out
    n += 1
    no_cid = caller.replace(" '$own_cid'", "", 1)
    out = check(callee, no_cid)
    assert any("passes 15 arguments" in f for f in out), out
    n += 1
    print("check-launch-arg-contract selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = check(open(CALLEE).read(), open(CALLER).read())
    for f in findings:
        print("check-launch-arg-contract: " + f)
    sys.exit(1 if findings else 0)
