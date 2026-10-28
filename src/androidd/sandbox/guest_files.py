import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUEST_DIR = os.path.join(ROOT, "guest")
BUILT_DIR = os.path.join(ROOT, "..", "..", "var", "share")
BUILT = ("sys-kernel-readers.txt",)

INLINE_MARKER = re.compile(r"@RHIZO_SUBST:(\w+)@")


def path(name):
    """return the path of a guest file"""
    p = os.path.join(GUEST_DIR, name)
    if name in BUILT and not os.path.exists(p):
        built = os.path.normpath(os.path.join(BUILT_DIR, name))
        if os.path.exists(built):
            return built
    return p


def read(name):
    """return the contents of a guest file"""
    with open(path(name)) as f:
        return f.read()


def render(text, whole=None, inline=None, comment_prefix=";"):
    """replace the RHIZO_SUBST markers in the text"""
    whole = whole or {}
    inline = inline or {}
    whole_marker = re.compile(r"^" + re.escape(comment_prefix) + r" @RHIZO_SUBST (\w+)\s*$")
    out = []
    for line in text.splitlines(keepends=True):
        m = whole_marker.match(line.rstrip("\n"))
        if m:
            if m.group(1) not in whole:
                raise KeyError(f"unknown whole-line marker {m.group(1)}")
            out.append(whole[m.group(1)])
            continue
        out.append(INLINE_MARKER.sub(lambda g: _inline(inline, g.group(1)), line))
    rendered = "".join(out)
    if "@RHIZO_SUBST" in rendered:
        raise ValueError("a marker was left unsubstituted")
    return rendered


def _inline(table, name):
    """return the value of an inline marker"""
    if name not in table:
        raise KeyError(f"unknown inline marker {name}")
    return table[name]
