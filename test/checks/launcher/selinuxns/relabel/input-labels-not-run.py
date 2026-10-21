#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    """return the failures"""
    with tempfile.TemporaryDirectory() as stub:
        path = os.path.join(stub, "unshare")
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\necho 'unshare: write failed /proc/self/uid_map: Operation not permitted' >&2\nexit 1\n")
        os.chmod(path, 0o755)
        r = subprocess.run([sys.executable, os.path.join(HERE, "input-labels.py")], capture_output=True, text=True,
                           timeout=300, env=dict(os.environ, PATH=stub + os.pathsep + os.environ["PATH"]))
    lines = r.stdout.strip().splitlines()
    want_last = "input-labels: 9 of 10 sections ok; NOT RUN: service process -- not a full pass"
    if not any(l.startswith("NOT RUN: service process -- unshare -r is refused here") for l in lines) \
            or not lines or lines[-1] != want_last or any(l.startswith(("ok", "FAIL")) for l in lines) \
            or r.returncode != 77:
        return [f"input-labels with unshare -r refused: want the service-process section named NOT RUN, every other "
                f"section ok and {want_last!r} last; got rc={r.returncode} {lines[-4:]!r}"]
    return []


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("input-labels-not-run:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
