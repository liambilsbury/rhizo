#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import layout_paths as layout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
ROTATOR = "rhizo-avc-capture.sh"
SELF = os.path.basename(__file__)

BARE = re.compile(r"^[^#\n]*\bdmesg\s+-w\b[^\n]*rhizo-avc\.log", re.M)
BARE_VAR = re.compile(r"^[^#\n]*exec\s+dmesg\s+-w[^\n]*$", re.M)


def offenders(text, name):
    """return the unbounded capture commands in a text"""
    hits = []
    for m in BARE.finditer(text):
        hits.append(m.group(0).strip()[:100])
    if name.endswith(".sh"):
        for m in BARE_VAR.finditer(text):
            if ROTATOR not in m.group(0):
                hits.append(m.group(0).strip()[:100])
    return hits


def tracked():
    """return the tracked script paths inside the layout"""
    out = subprocess.run(["git", "-C", ROOT, "ls-files"],
                         capture_output=True, text=True).stdout
    return [p for p in out.splitlines()
            if p.endswith((".sh", ".py")) and not layout.outside_layout(p) and os.path.basename(p) not in
            (ROTATOR, SELF)]


def old_generation_survives():
    """run the capture and return the lines left from an old generation"""
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "rhizo-avc.log")
        with open(log + ".1", "w") as f:
            f.write("OLD previous boot denial\n")
        with open(log, "w") as f:
            f.write("OLD previous boot live line\n")
        fake = os.path.join(d, "dmesg")
        with open(fake, "w") as f:
            f.write("#!/bin/sh\necho 'THIS boot line'\n")
        os.chmod(fake, 0o755)
        env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])
        subprocess.run(["/bin/sh", os.path.join(ROOT, "src", "androidd", "host", "capture-kernel-log.sh"), log],
                       env=env, check=True, timeout=30)
        left = []
        for p in (log + ".1", log):
            if os.path.exists(p):
                with open(p) as f:
                    left += [ln for ln in f.read().splitlines()
                             if ln.startswith("OLD")]
        return left


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        old = old_generation_survives()
        if old:
            print("SELFTEST FAILED: a previous boot's capture survives a "
                  "restart of it: %s" % old, file=sys.stderr)
            return 1
        bad = offenders(
            "setsid sh -c 'exec dmesg -w' > '$GUEST_LOG' 2>&1 & disown\n",
            "x.sh")
        if not bad:
            print("SELFTEST FAILED: a bare exec dmesg -w was not caught",
                  file=sys.stderr)
            return 1
        good = offenders(
            "exec /bin/sh /root/share/%s $GUEST_LOG\n" % ROTATOR, "x.sh")
        if good:
            print("SELFTEST FAILED: the rotating form was flagged: %s" % good,
                  file=sys.stderr)
            return 1
        commented = offenders("# exec dmesg -w > /root/rhizo-avc.log\n", "x.sh")
        if commented:
            print("SELFTEST FAILED: a commented line was counted: %s"
                  % commented, file=sys.stderr)
            return 1
        print("selftest ok: catches a bare dmesg -w, passes the rotating form, "
              "ignores a commented one, and a restarted capture keeps nothing "
              "of the previous boot")
        return 0

    found = []
    for rel in tracked():
        path = os.path.join(ROOT, rel)
        try:
            with open(path, errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for hit in offenders(text, rel):
            found.append("%s: %s" % (rel, hit))
    if found:
        print("FAIL: an unbounded dmesg -w writes the AVC log:", file=sys.stderr)
        for f in found:
            print("    %s" % f, file=sys.stderr)
        return 1
    print("avc capture: every writer of rhizo-avc.log goes through the "
          "rotating capture")
    return 0


if __name__ == "__main__":
    sys.exit(main())
