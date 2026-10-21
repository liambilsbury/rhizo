#!/usr/bin/env python3
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")


def primer_src(module_src):
    """return the HOST_PRIMER_SRC string and its starting line"""
    for node in ast.parse(module_src).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "HOST_PRIMER_SRC"
                                                for t in node.targets):
            if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                return node.value.value, node.value.lineno
    return None, None


def undefined_names(module_src):
    """return the undefined names in HOST_PRIMER_SRC"""
    import pyflakes.checker
    import pyflakes.messages
    src, start = primer_src(module_src)
    if src is None:
        return None
    found = []
    for msg in pyflakes.checker.Checker(ast.parse(src), filename="HOST_PRIMER_SRC").messages:
        if isinstance(msg, pyflakes.messages.UndefinedName):
            found.append("launcher3.py:%d: %s" % (start + msg.lineno - 1, msg.message % msg.message_args))
    return sorted(found)


QUOTES = '"' * 3
BODY = """
import errno, os
try:
    os.stat("/nonexistent")
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno))
"""
GOOD = "import sys\n\nHOST_PRIMER_SRC = r" + QUOTES + BODY + QUOTES + "\n"


def selftest():
    """check a complete primer and a missing an import"""
    if undefined_names(GOOD) != []:
        print("SELFTEST FAILED: a primer binding every name it uses was flagged: %s" % undefined_names(GOOD),
              file=sys.stderr)
        return 1
    print("selftest ok: a primer that imports what its refusal handler formats with passes")
    bad = undefined_names(GOOD.replace("import errno, os", "import os"))
    if bad != ["launcher3.py:8: undefined name 'errno'"]:
        print("SELFTEST FAILED: a refusal handler using errno with no import read as %s" % bad, file=sys.stderr)
        return 1
    print("selftest ok: catches errno used only inside an except branch, at its launcher3.py line")
    if undefined_names("HOST_PRIMER_SRC = None\n") is not None:
        print("SELFTEST FAILED: a module with no primer string literal was read as a primer", file=sys.stderr)
        return 1
    print("selftest ok: a module with no primer string literal reads as missing, not as clean")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else LAUNCHER
    try:
        found = undefined_names(open(path, encoding="utf-8").read())
    except ImportError as e:
        print("check-host-primer-names: pyflakes is not importable (%s)" % e)
        return 1
    if found is None:
        print("check-host-primer-names: %s assigns no HOST_PRIMER_SRC string literal" % path)
        return 1
    if found:
        print("check-host-primer-names: the host primer uses names it never binds, and dies silently on "
              "the path that reaches one:")
        for line in found:
            print("  " + line)
        return 1
    print("check-host-primer-names: every name the host primer uses is bound")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
