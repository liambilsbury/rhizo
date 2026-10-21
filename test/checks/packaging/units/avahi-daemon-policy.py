#!/usr/bin/env python3
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
DROPIN = "debian/dropins/avahi-daemon-policy.conf"
TARGET = "$(PAYLOAD)/host-mode/usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf"
PIDFILE_CLEANUP = "-/usr/bin/setpriv --reuid=avahi --regid=avahi --clear-groups /usr/bin/rm -f /run/avahi-daemon/pid"
WANT = ["[Unit]", "After=rhizo-policy.service", "[Service]", "ExecStartPre=" + PIDFILE_CLEANUP]
DROPIN_WANTS = ((DROPIN, [("Unit", "After", "rhizo-policy.service"), ("Service", "ExecStartPre", PIDFILE_CLEANUP)],
                 "avahi-dropin"),)
INSTALL = re.compile(r"install\s+-D\s+-m\s+0644\s+(\S+)\s*\\?\s*\n?\s*(\S+)")


def problems(rules, dropin):
    """return the problems with the avahi drop-in"""
    bad = []
    if (DROPIN, TARGET) not in INSTALL.findall(rules):
        bad.append("debian/rules does not install %s as %s" % (DROPIN, TARGET))
    if dropin is None:
        return bad + ["%s is missing" % DROPIN]
    lines = [l.strip() for l in dropin.splitlines() if l.strip() and not l.strip().startswith("#")]
    if "After=rhizo-policy.service" not in lines:
        bad.append("%s does not order avahi-daemon After=rhizo-policy.service" % DROPIN)
    if "ExecStartPre=" + PIDFILE_CLEANUP not in lines:
        bad.append("%s does not remove the PID file a stopped avahi leaves, as avahi, before a start" % DROPIN)
    if lines != WANT:
        bad.append("%s holds %r, not exactly %r: avahi must start the same with or without Rhizo" % (DROPIN, lines, WANT))
    return bad


def selftest():
    """test the avahi drop-in check on fixtures"""
    rules = "\tinstall -D -m 0644 %s \\\n\t                   %s\n" % (DROPIN, TARGET)
    good = "[Unit]\nAfter=rhizo-policy.service\n[Service]\nExecStartPre=%s\n" % PIDFILE_CLEANUP
    cases = [("the packaged drop-in", rules, good, None),
             ("no install line", "", good, "does not install"),
             ("no ordering", rules, good.replace("After=rhizo-policy.service\n", ""), "does not order"),
             ("no PID file removal", rules, "[Unit]\nAfter=rhizo-policy.service\n", "PID file a stopped avahi leaves"),
             ("a pulled-in dependency", rules, good + "Wants=rhizo-policy.service\n", "not exactly"),
             ("no drop-in file", rules, None, "is missing")]
    rc = 0
    for label, r, d, want in cases:
        got = problems(r, d)
        if want is None and got:
            print("FAIL %s was flagged: %s" % (label, got))
            rc = 1
        if want is not None and not any(want in g for g in got):
            print("FAIL %s was not flagged (%r): %s" % (label, want, got))
            rc = 1
    if rc == 0:
        print("avahi daemon policy selftest: ok (%d cases)" % len(cases))
    return rc


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:] and selftest():
        return 1
    with open(os.path.join(REPO, "debian/rules")) as f:
        rules = f.read()
    path = os.path.join(REPO, DROPIN)
    dropin = open(path).read() if os.path.exists(path) else None
    bad = problems(rules, dropin)
    for b in bad:
        print("FAIL %s" % b)
    if not bad:
        print("avahi daemon policy: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
