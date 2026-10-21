#!/usr/bin/env python3
import ast
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
SHELL_LOSETUP = re.compile(r"(^|[\s;&|(`$])losetup(\s|$)")


def strings_of(node):
    """return the literal text pieces of a str constant or f-string node"""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [node.value]
    if isinstance(node, ast.JoinedStr):
        return [v.value for v in node.values if isinstance(v, ast.Constant) and isinstance(v.value, str)]
    return []


def check(source):
    """return a finding for every exec of the losetup binary in source"""
    bad = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.List) and node.elts and strings_of(node.elts[0]) == ["losetup"]:
            bad.append(f"line {node.lineno}: an argv list execs losetup")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "system":
            for arg in node.args:
                for piece in (p for a in ast.walk(arg) for p in strings_of(a)):
                    if SHELL_LOSETUP.search(piece):
                        bad.append(f"line {node.lineno}: a shell string runs losetup")
                        break
    return bad


def selftest():
    """assert each finding on fixtures, both ways"""
    cases = (
        ("argv list", 'loop = subprocess.check_output(["losetup", "-f", "--show", img], text=True)\n', "an argv list execs losetup"),
        ("helper argv", 'r = subprocess.run(["losetup", *args], capture_output=True)\n', "an argv list execs losetup"),
        ("shell detach", 'os.system(f"losetup -d {loop} 2>/dev/null")\n', "a shell string runs losetup"),
        ("shell find in a chain", 'os.system(f"umount x; L=$(losetup -j {img} | cut -d: -f1); true")\n', "a shell string runs losetup"),
    )
    bad = []
    for label, src, needle in cases:
        got = check(src)
        if not any(needle in g for g in got):
            bad.append(f"{label} was not flagged: {got}")
    clean = ('dev, fd = core.loop_attach(img)\nos.close(fd)\nkmsg(f"vbmeta.img losetup FAILED: {e}")\n'
             'log("losetup -d failed")\nrc, out, err = losetup(["-d", dev])\n')
    if check(clean):
        bad.append(f"an in-process attach and log text were flagged: {check(clean)}")
    return bad


def main():
    """run the real check, or the selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check(open(LAUNCHER).read())
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
