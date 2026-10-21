#!/usr/bin/env python3
import argparse
import base64
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
POSTRM = os.path.join("debian", "rhizo.postrm")
TEMPLATE = os.path.join("debian", "rhizo.postrm.in")
BEGIN = "# ---- BEGIN embedded teardown: debian/embed-teardown.py --write ----"
END = "# ---- END embedded teardown ----"
SOURCES = (
    ("src/install/teardown/teardown-lib.sh", "install/teardown/teardown-lib.sh", "RHIZO_TEARDOWN_LIB_B64"),
    ("src/install/lib/host-flavor.sh", "install/lib/host-flavor.sh", "RHIZO_HOST_FLAVOR_B64"),
    ("src/install/bootstrap/bootloader.sh", "install/bootstrap/bootloader.sh", "RHIZO_BOOTLOADER_B64"),
    ("src/install/lib/pkg-lib.sh", "install/lib/pkg-lib.sh", "RHIZO_PKG_LIB_B64"),
    ("src/install/teardown/teardown.sh", "install/teardown/teardown.sh", "RHIZO_HOST_TEARDOWN_B64"),
    ("src/androidd/host/selinux-mode.py", "rhizo-selinux-mode", "RHIZO_SELINUX_MODE_B64"),
)
EXECUTABLE = ("rhizo-selinux-mode",)


def read_sources(root):
    """return the bytes of each teardown source file"""
    out = {}
    for src, _, _ in SOURCES:
        with open(os.path.join(root, src), "rb") as fh:
            out[src] = fh.read()
    return out


def render(sources):
    """return the postrm block for the sources"""
    lines = [BEGIN]
    for src, _, _ in SOURCES:
        lines.append("# %s sha256=%s" % (src, hashlib.sha256(sources[src]).hexdigest()))
    lines.append("rhizo_teardown_write() {  # rhizo_teardown_write <dir>")
    for src, name, delim in SOURCES:
        encoded = base64.encodebytes(sources[src]).decode("ascii").rstrip("\n")
        if delim in encoded:
            raise ValueError("%s's base64 contains its own delimiter %s" % (src, delim))
        if "/" in name:
            lines.append("  mkdir -p \"$1/%s\" || return 1" % os.path.dirname(name))
        lines.append("  base64 -d > \"$1/%s\" <<'%s' || return 1" % (name, delim))
        lines.extend(encoded.split("\n"))
        lines.append(delim)
        if name in EXECUTABLE:
            lines.append("  chmod 0755 \"$1/%s\" || return 1" % name)
    lines.append("}")
    lines.append(END)
    return "\n".join(lines) + "\n"


def splice(postrm_text, block):
    """replace the block between the two marker lines"""
    lines = postrm_text.split("\n")
    begins = [i for i, l in enumerate(lines) if l == BEGIN]
    ends = [i for i, l in enumerate(lines) if l == END]
    if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
        raise ValueError("%s needs exactly one %r line and one %r line after it" % (TEMPLATE, BEGIN, END))
    head = "\n".join(lines[:begins[0]])
    tail = "\n".join(lines[ends[0] + 1:])
    return (head + "\n" if head else "") + block + tail


def postrm_text(root=ROOT):
    """return the postrm with the teardown block"""
    with open(os.path.join(root, TEMPLATE), encoding="utf-8") as fh:
        template = fh.read()
    return splice(template, render(read_sources(root)))


def main():
    """write debian/rhizo.postrm from its template"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true", required=True)
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--out", help="where to write the postrm (default: debian/rhizo.postrm under --root)")
    args = ap.parse_args()
    out = args.out or os.path.join(args.root, POSTRM)
    try:
        text = postrm_text(args.root)
    except (OSError, ValueError) as e:
        print("FAIL: embed-teardown: %s" % e, file=sys.stderr)
        return 1
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(out, 0o755)
    print("embed-teardown: wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
