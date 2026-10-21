#!/usr/bin/env python3
import os
import re
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import unit_files  # noqa: E402
POLICY = "rhizo-policy.service"
EXEC = re.compile(r"^\s*Exec(?:Start|StartPre|StartPost|Stop|StopPost|Reload)\s*=\s*[-+!@:]*(\S+)", re.M)
AFTER = re.compile(r"^\s*After\s*=\s*(.*)$", re.M)


def problems(root):
    """return the services missing After=rhizo-policy.service"""
    bad = []
    for name, rel in sorted(unit_files.unit_files(root, (".service",)).items()):
        if name == POLICY:
            continue
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            text = f.read()
        if not any(os.path.basename(prog) == "systemctl" for prog in EXEC.findall(text)):
            continue
        after = " ".join(AFTER.findall(text)).split()
        if POLICY not in after:
            bad.append("%s runs systemctl but is not After=%s: a boot that mounts /run/rhizo during the policy "
                       "load starts it while the primer re-executes PID 1, and its systemctl loses the bus "
                       "(\"Transport endpoint is not connected\")" % (name, POLICY))
    return bad


def selftest():
    """test the ordering check on fixture units"""
    body = "[Unit]\nDescription=x\n%s\n[Service]\nType=oneshot\nExecStart=/usr/bin/systemctl restart a.path\n"
    rc = 0
    with tempfile.TemporaryDirectory() as root:
        d = os.path.join(root, "src", "services", "units")
        os.makedirs(d)
        with open(os.path.join(d, "rhizo-x.service"), "w") as f:
            f.write(body % "")
        if not problems(root):
            print("FAIL a systemctl unit with no After=%s was not flagged" % POLICY)
            rc = 1
        with open(os.path.join(d, "rhizo-x.service"), "w") as f:
            f.write(body % ("After=%s" % POLICY))
        if problems(root):
            print("FAIL a systemctl unit ordered after %s was flagged: %s" % (POLICY, problems(root)))
            rc = 1
        with open(os.path.join(d, "rhizo-x.service"), "w") as f:
            f.write((body % "").replace("/usr/bin/systemctl", "-/usr/bin/systemctl"))
        if not problems(root):
            print("FAIL a prefixed systemctl Exec line was not flagged")
            rc = 1
    if rc == 0:
        print("systemctl after policy selftest: ok (3 cases)")
    return rc


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:] and selftest():
        return 1
    bad = problems(REPO)
    for b in bad:
        print("FAIL %s" % b)
    if not bad:
        print("systemctl after policy: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
