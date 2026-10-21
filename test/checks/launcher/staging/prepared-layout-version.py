#!/usr/bin/env python3
import ast
import copy
import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent.parent.parent
WATCHED = {
    "boot.py": ["stage_vendor_tree", "prepare_tree_verb"],
    "sandbox/core.py": ["prepared_key", "validate_prepared"],
}
EXPECT_VERSION = "10"
EXPECT_HASH = "675e0c6913aba59b"


def code_dump(node):
    """return the docstring-free ast dump of a function"""
    node = copy.deepcopy(node)
    for n in ast.walk(node):
        if (isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.body
                and isinstance(n.body[0], ast.Expr) and isinstance(n.body[0].value, ast.Constant)
                and isinstance(n.body[0].value.value, str)):
            n.body = n.body[1:]
    keep_empty = {"show_empty": True} if sys.version_info >= (3, 13) else {}
    return ast.dump(node, annotate_fields=False, **keep_empty)


def read_watched():
    """return the text of each watched module"""
    return {fname: (REPO / "src" / "androidd" / fname).read_text() for fname in WATCHED}


def watched_source(texts=None):
    """return the docstring-free ast dump of the watched functions"""
    texts = texts or read_watched()
    chunks = []
    for fname, funcs in sorted(WATCHED.items()):
        tree = ast.parse(texts[fname])
        found = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name in funcs:
                found[node.name] = code_dump(node)
        missing = set(funcs) - set(found)
        if missing:
            print("FAIL: %s no longer defines %s" % (fname, ", ".join(sorted(missing))))
            print("      rename it in WATCHED or restore the name")
            sys.exit(1)
        for name in sorted(found):
            chunks.append("%s:%s:%s" % (fname, name, found[name]))
    return "\n".join(chunks)


def live_version():
    """return the prepared layout version defined in the environment module"""
    text = (REPO / "src" / "androidd" / "sandbox" / "core.py").read_text()
    m = re.search(r'^PREPARED_LAYOUT_VERSION\s*=\s*"([^"]+)"', text, re.M)
    if not m:
        print("FAIL: sandbox/core.py defines no PREPARED_LAYOUT_VERSION")
        sys.exit(1)
    return m.group(1)


def digest_of(texts=None):
    """return the short hash of the watched functions' code"""
    return hashlib.sha256(watched_source(texts).encode()).hexdigest()[:16]


def selftest(digest):
    """return the hash cases that fail"""
    texts = read_watched()
    text = texts["sandbox/core.py"]
    fn = next(n for n in ast.walk(ast.parse(text))
              if isinstance(n, ast.FunctionDef) and n.name == "validate_prepared")
    doc = fn.body[0]
    if not (isinstance(doc, ast.Expr) and isinstance(doc.value, ast.Constant) and len(fn.body) > 1):
        return ["validate_prepared() has no docstring followed by code to edit"]
    lines = text.splitlines(keepends=True)
    pad = " " * doc.col_offset
    head, tail = lines[:doc.lineno - 1], lines[doc.end_lineno:]
    cases = [
        ("a reworded docstring", head + [pad + '"""a docstring the selftest wrote"""\n'] + tail, False),
        ("a multi-line docstring", head + [pad + '"""a docstring\n', "\n", pad + 'over three lines"""\n'] + tail, False),
        ("a removed docstring", head + tail, False),
        ("an added comment", lines[:doc.end_lineno] + [pad + "# a comment the selftest wrote\n"] + tail, False),
        ("an added statement", lines[:doc.end_lineno] + [pad + "_probe = 1\n"] + tail, True),
    ]
    bad = []
    for name, cut, moves in cases:
        moved = digest_of(dict(texts, **{"sandbox/core.py": "".join(cut)})) != digest
        print("selftest %s: %s in validate_prepared() %s the hash"
              % ("OK" if moved == moves else "FAILED", name, "moves" if moves else "leaves"))
        if moved != moves:
            bad.append(name)
    return bad


def main():
    """check or record the prepared layout version"""
    argv = sys.argv[1:]
    digest = digest_of()
    version = live_version()

    if "--update" in argv:
        text = Path(__file__).read_text()
        text = re.sub(r'^EXPECT_HASH = "[^"]*"', 'EXPECT_HASH = "%s"' % digest, text, count=1, flags=re.M)
        text = re.sub(r'^EXPECT_VERSION = "[^"]*"', 'EXPECT_VERSION = "%s"' % version, text, count=1, flags=re.M)
        Path(__file__).write_text(text)
        print("recorded layout %s hash %s" % (version, digest))
        return 0

    if "--selftest" in argv:
        if digest == "0" * 16:
            print("FAIL: selftest cannot run, the real hash collides with its probe")
            return 1
        bad = selftest(digest)
        if bad:
            print("FAIL: the hash does not track code alone: %s" % ", ".join(bad))
            return 1
        print("selftest: a changed hash against an unchanged version is what this rejects")
        return 0

    if digest == EXPECT_HASH and version == EXPECT_VERSION:
        print("check-prepared-layout-version: layout %s unchanged (%s)" % (version, digest))
        return 0
    if digest != EXPECT_HASH and version == EXPECT_VERSION:
        print("FAIL: the prepared-tree code changed but PREPARED_LAYOUT_VERSION is still %s" % version)
        print("      watched: %s" % ", ".join("%s:%s" % (f, n) for f, ns in sorted(WATCHED.items()) for n in ns))
        print("      existing prepared trees still validate against this version")
        print("      bump PREPARED_LAYOUT_VERSION in sandbox/core.py, then: %s --update" % Path(__file__).name)
        return 1
    if version != EXPECT_VERSION:
        print("check-prepared-layout-version: version moved %s -> %s, recording the new layout"
              % (EXPECT_VERSION, version))
        print("      run: %s --update" % Path(__file__).name)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
