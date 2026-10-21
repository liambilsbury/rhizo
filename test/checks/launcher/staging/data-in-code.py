#!/usr/bin/env python3
import ast
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

MAX_LINES = 14


def offenders(src, label, limit=MAX_LINES):
    """return the large literal writes in a source"""
    bad = []
    for n in ast.walk(ast.parse(src)):
        if not (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                and n.func.attr == "write"):
            continue
        inner = n.func.value
        if not (isinstance(inner, ast.Call) and getattr(inner.func, "id", "") == "open"):
            continue
        if not n.args:
            continue
        span = n.end_lineno - n.lineno + 1
        if span <= limit:
            continue
        def literal_parts(x):
            """return the operands of a string addition"""
            if isinstance(x, ast.BinOp) and isinstance(x.op, ast.Add):
                return literal_parts(x.left) + literal_parts(x.right)
            return [x]
        parts = literal_parts(n.args[0])
        if not any(isinstance(p, ast.Constant) and isinstance(p.value, (str, bytes))
                   for p in parts):
            continue
        target = ast.unparse(inner.args[0])[:60]
        bad.append(f"{label}:{n.lineno}: {span} lines of literal text written to "
                   f"{target} -- put it in src/androidd/guest/ and read it with "
                   f"guest_files.read()")
    return bad


def selftest():
    """test offenders on literal writes"""
    big = 'open("/x/y.rc", "w").write(\n' + "".join(
        '    "line %d\\n"\n' % i for i in range(30)) + ")\n"
    if not offenders(big, "t.py"):
        print("selftest FAIL: a 30-line literal write was not reported", file=sys.stderr)
        return 1
    small = 'open("/x/y", "a").write("one line\\n")\n'
    if offenders(small, "t.py"):
        print("selftest FAIL: a short write was reported", file=sys.stderr)
        return 1
    computed = ('open("/x/y", "w").write("\\n".join(\n'
                + "".join("    str(%d) +\n" % i for i in range(30)) + '    "end"))\n')
    if offenders(computed, "t.py"):
        print("selftest FAIL: a computed write was reported as data", file=sys.stderr)
        return 1
    return 0


def main():
    """run the check on the launcher modules or run the selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    files = [os.path.join(REPO, "src", "androidd", "boot.py")] + sorted(glob.glob(os.path.join(REPO, "src", "androidd", "sandbox", "*.py")))
    if len(files) < 2:
        print("found no launcher modules to check", file=sys.stderr)
        return 1
    for f in files:
        if not os.path.exists(f):
            continue
        bad += offenders(open(f).read(), os.path.basename(f))
    for b in bad:
        print(b, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
