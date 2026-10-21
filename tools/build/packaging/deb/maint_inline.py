#!/usr/bin/env python3
"""print a maintainer script with library calls inlined"""
import os
import re
import sys

USAGE = """Usage: maint_inline.py <debian/<package>.<script>>
       maint_inline.py --selftest"""

SOURCE_RE = re.compile(r"^([ \t]*)(?:\.|source)[ \t]+/usr/lib/rhizo/install/([\w./-]+)[ \t]*$", re.M)
FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{$")
CALL_RE = re.compile(r"^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)((?:[ \t]+[^|&;<>()\\]*)?)$")
CONT_RE = re.compile(r"^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)((?:[ \t]+[^|&;<>()\\]*?)?)[ \t]*\\$")
COMMAND_POS = r"(?:^|[;&|({!`]|\$\(|\b(?:then|do|else|elif|if|while|until)\b)[ \t]*"
PLAIN_WORD = re.compile(r"^[A-Za-z0-9_.@%+:=/-]+$")
MAX_DEPTH = 8


def read(path):
    """return the text of a file"""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def sourced(script):
    """get the library files a script sources"""
    root = os.path.dirname(os.path.dirname(os.path.abspath(script)))
    out = []
    for _, name in SOURCE_RE.findall(read(script)):
        path = os.path.join(root, "src", "install", name)
        if not os.path.isfile(path):
            raise FileNotFoundError("%s sources /usr/lib/rhizo/install/%s, and %s does not exist"
                                    % (script, name, path))
        if path not in out:
            out.append(path)
    return out


def functions(text):
    """get the function bodies in a script text"""
    out, name, body = {}, None, []
    for line in text.split("\n"):
        if name is None:
            m = FUNC_RE.match(line)
            if m:
                name, body = m.group(1), []
        elif line == "}":
            out[name] = body
            name = None
        else:
            body.append(line)
    return out


def body(fns, name, indent, args):
    """get a function body with arguments substituted"""
    out = []
    for line in fns[name]:
        if not line.strip():
            out.append("")
            continue
        line = indent + (line[2:] if line.startswith("  ") else line)
        for n, word in enumerate(args, 1):
            if PLAIN_WORD.match(word):
                line = re.sub(r'"\$\{%d(?::-)?\}"|"\$%d"(?![0-9])|\$\{%d(?::-)?\}|\$%d(?![0-9])' % (n, n, n, n),
                              lambda _: word, line)
        out.append(line)
    return out


def inline(text, fns, depth=0, where="the script"):
    """replace each function call with its body"""
    names = "|".join(re.escape(fn) for fn in sorted(fns))
    lines = text.split("\n")
    out = []
    for i, line in enumerate(lines):
        m = CALL_RE.match(line)
        cont = CONT_RE.match(line)
        follows = lines[i + 1].lstrip().startswith(("||", "&&")) if i + 1 < len(lines) else False
        if m and m.group(2) in fns or cont and cont.group(2) in fns and follows:
            call = m if m and m.group(2) in fns else cont
            if depth >= MAX_DEPTH:
                raise RecursionError("%s calls itself through %d levels" % (call.group(2), MAX_DEPTH))
            indent = call.group(1)
            group = call is not m
            inner = body(fns, call.group(2), indent + "  " * group, call.group(3).split())
            inner = inline("\n".join(inner), fns, depth + 1, call.group(2))
            out += [indent + "{", inner, indent + "} \\"] if group else [inner]
            continue
        if not line.lstrip().startswith("#"):
            found = re.search(COMMAND_POS + r"(%s)\b(?![ \t]*\(\))" % names, line)
            if found:
                raise ValueError("%s calls %s where it cannot be inlined: %s" % (where, found.group(1), line.strip()))
        out.append(line)
    return "\n".join(out)


def inlined(script):
    """get a script text with its libraries inlined"""
    fns = {}
    for lib in sourced(script):
        fns.update(functions(read(lib)))
    if not fns:
        return read(script)
    text = SOURCE_RE.sub(lambda m: "%s# src/install/%s, inlined at its calls" % m.groups(), read(script))
    return inline(text, fns, where=script)


SELFTEST_LIB = """#!/bin/sh
pkg_make() {
  mkdir -p "$1"
  echo "made $1"
}
pkg_outer() {
  pkg_make /a
  echo outer
}
"""
SELFTEST_CASES = (
    ("a bare call", "    pkg_outer\n", "    mkdir -p /a\n    echo \"made /a\"\n    echo outer\n"),
    ("a continued call", "    pkg_make /b \\\n      || { echo no; exit 1; }\n",
     "    {\n      mkdir -p /b\n      echo \"made /b\"\n    } \\\n      || { echo no; exit 1; }\n"),
    ("a quoted argument stays a parameter", '    pkg_make "${2:-}"\n',
     '    mkdir -p "$1"\n    echo "made $1"\n'),
    ("a name in a comment or a message", '    # pkg_make is not called here\n    echo "run pkg_make"\n',
     '    # pkg_make is not called here\n    echo "run pkg_make"\n'),
    ("a call in a command substitution", "    x=$(pkg_make /c)\n", None),
    ("a call as an if condition", "    if pkg_make /c; then :; fi\n", None),
    ("a call after a list operator", "    true && pkg_make /c\n", None),
    ("a continued call with no list operator after it", "    pkg_make /c \\\n      /d\n", None),
)


def selftest():
    """check the inlining against sample scripts"""
    import tempfile
    bad = 0
    for name, body, want in SELFTEST_CASES:
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "debian"))
            os.makedirs(os.path.join(tmp, "src", "install"))
            with open(os.path.join(tmp, "src", "install", "lib.sh"), "w") as fh:
                fh.write(SELFTEST_LIB)
            head = "#!/bin/sh\ncase \"$1\" in\n  configure)\n    . /usr/lib/rhizo/install/lib.sh\n"
            with open(os.path.join(tmp, "debian", "rhizo.postinst"), "w") as fh:
                fh.write(head + body + "    ;;\nesac\n")
            try:
                got = inlined(os.path.join(tmp, "debian", "rhizo.postinst"))
                got = got.split("inlined at its calls\n", 1)[1].rsplit("    ;;\n", 1)[0]
            except ValueError as e:
                got = None
                err = str(e)
        if got != want:
            print("FAIL %s: want %r, got %r" % (name, want, got if got is not None else "refused: " + err))
            bad = 1
        elif want is None and "pkg_make" not in err:
            print("FAIL %s: the refusal does not name the function: %s" % (name, err))
            bad = 1
    print("maint_inline selftest: %s" % ("FAILED" if bad else "%d cases pass" % len(SELFTEST_CASES)))
    return bad


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if len(sys.argv) != 2:
        sys.exit(USAGE.strip().split("\n")[-1])
    sys.stdout.write(inlined(sys.argv[1]))
