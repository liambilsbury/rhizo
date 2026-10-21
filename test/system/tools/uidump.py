#!/usr/bin/env python3
import argparse
import re
import sys

TEXT_RE = re.compile(r'text="([^"]*)"')

UNITS = {
    "byte": 1, "bytes": 1, "b": 1,
    "kb": 1000, "mb": 1000 ** 2, "gb": 1000 ** 3, "tb": 1000 ** 4,
    "kib": 1024, "mib": 1024 ** 2, "gib": 1024 ** 3, "tib": 1024 ** 4,
}
VALUE_RE = re.compile(r"^\s*([0-9]+(?:[.,][0-9]+)?)\s*([A-Za-z]+)\s*$")


def texts(xml):
    """return the non-blank text values in the dump"""
    return [t for t in TEXT_RE.findall(xml) if t.strip()]


def value_after(xml, label):
    """return the text value that follows the given label"""
    seq = texts(xml)
    for i, t in enumerate(seq[:-1]):
        if t.strip() == label:
            return seq[i + 1]
    return None


def to_bytes(value):
    """convert a size string with a unit to a byte count"""
    if value is None:
        return None
    v = value.replace(" ", " ").replace(" ", " ").replace(",", ".")
    m = VALUE_RE.match(v)
    if not m:
        return None
    mult = UNITS.get(m.group(2).lower())
    if mult is None:
        return None
    return int(float(m.group(1)) * mult)


def selftest():
    """run the parser checks on inline fixtures"""
    fixture = ('<node text="Rhizo NetTest"/><node text="Total"/><node text="32.00 MB"/>'
               '<node text="Foreground"/><node text="31.90 MB"/>'
               '<node text="Background"/><node text="0 byte"/>')
    empty = ('<node text="Files"/><node text="Total"/><node text="0 byte"/>')
    fails = []

    if value_after(fixture, "Total") != "32.00 MB":
        fails.append("value_after did not read the populated total")
    if to_bytes(value_after(fixture, "Total")) != 32000000:
        fails.append("32.00 MB did not parse to 32000000")
    if to_bytes(value_after(empty, "Total")) != 0:
        fails.append("'0 byte' must parse to 0, not to None")
    if to_bytes(value_after(fixture, "Total")) <= to_bytes(value_after(empty, "Total")):
        fails.append("a populated total must exceed an empty one")
    if value_after(fixture, "Nonexistent") is not None:
        fails.append("a missing label must be None")
    if to_bytes("about a gigabyte") is not None:
        fails.append("an unparseable value must be None, never 0")
    if to_bytes(value_after('<node text="Total"/><node text="8.00 MB"/>', "Total")) != 8000000:
        fails.append("8.00 MB did not parse")

    for f in fails:
        print("FAIL: %s" % f, file=sys.stderr)
    print("uidump selftest: %s" % ("FAILED" if fails else "ok"), file=sys.stderr)
    return 1 if fails else 0


def main():
    """print the requested values from the dump"""
    ap = argparse.ArgumentParser()
    ap.add_argument("xml", nargs="?", help="uiautomator dump file ('-' for stdin)")
    ap.add_argument("--label")
    ap.add_argument("--texts", action="store_true")
    ap.add_argument("--bytes", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.xml:
        ap.error("need a dump file, or --selftest")
    xml = sys.stdin.read() if a.xml == "-" else open(a.xml, encoding="utf-8", errors="replace").read()
    if a.texts:
        for t in texts(xml):
            print(t)
        return 0
    if not a.label:
        ap.error("need --label or --texts")
    val = value_after(xml, a.label)
    if val is None:
        return 2
    if a.bytes:
        n = to_bytes(val)
        if n is None:
            return 3
        print(n)
        return 0
    print(val)
    return 0


if __name__ == "__main__":
    sys.exit(main())
