#!/usr/bin/env python3
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

REAL = (
    "\nDma-buf Objects:\n"
    "size\tflags\tmode\tcount\texp_name\tino\tname\n"
    "00589824\t00000002\t00080007\t00000002\tvirtio_gpu\t00000060\t<none>\n"
    "\twrite fence:virtio_gpu controlq seq 968 signaled\n"
    "\tAttached Devices:\n"
    "Total 0 devices attached\n"
    "04096000\t00000002\t00080007\t00000003\tvirtio_gpu\t00000061\t<none>\n"
    "\tAttached Devices:\n"
    "Total 0 devices attached\n"
)


def load():
    """return the footprint meter module loaded from its file"""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "rhizo_meter", os.path.join(HERE, "..", "..", "..", "system", "tools", "stack-meter.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    """test the bufinfo parser against a kernel capture"""
    m = load()
    if not hasattr(m, "parse_bufinfo"):
        print("FAIL: stack-meter.py has no parse_bufinfo()",
              file=sys.stderr)
        return 1

    r = m.parse_bufinfo(REAL)
    problems = []
    if not r.get("available"):
        problems.append("real bufinfo format reported unavailable: %r" % r.get("error"))
    if r.get("buffer_count") != 2:
        problems.append("expected 2 buffers from the real capture, got %r"
                        % r.get("buffer_count"))
    if r.get("total_bytes") != 589824 + 4096000:
        problems.append("total_bytes %r != 4685824" % r.get("total_bytes"))
    if list(r.get("by_exporter", {})) != ["virtio_gpu"]:
        problems.append("exporter not read from its column: %r" % r.get("by_exporter"))
    bufs = r.get("buffers") or []
    if not any(b.get("count") == 3 and b.get("ino") == 61 for b in bufs):
        problems.append("refcount/ino columns not parsed: %r" % bufs)

    bad = m.parse_bufinfo("some other kernel's output\nwith no header at all\n")
    if bad.get("available"):
        problems.append("an unrecognized format reported available=%r" % bad.get("available"))

    if problems:
        for p in problems:
            print("FAIL: " + p, file=sys.stderr)
        return 1
    print("bufinfo parse: ok (2 buffers, 4685824 bytes, refcount+ino read, "
          "unknown format degrades to unavailable)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(main())
    sys.exit(main())
