#!/usr/bin/env python3
import os
import re
import subprocess
import sys

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "install",
                   "cli", "rhizo.sh")


def status_line(func, verdict, unit_state):
    """run selinuxns_status with a stub verdict reader and return its line"""
    script = ('selinuxns_verdict() { printf "%s\\n" "$VERDICT"; }\n' + func
              + 'VERDICT="$1"; RHIZO_SANDBOX_ID=0; selinuxns_status "$2"\n')
    r = subprocess.run(["bash", "-c", script, "_", verdict, unit_state], capture_output=True, text=True, timeout=60)
    return r.stdout.strip() + (f" <rc={r.returncode} {r.stderr.strip()}>" if r.returncode else "")


def main():
    """return the failures"""
    text = open(CLI).read()
    m = re.search(r"^selinuxns_status\(\) \{.*?^\}\n", text, re.M | re.S)
    if not m:
        return ["rhizo.sh has no selinuxns_status()"]
    bad = []
    for verdict, unit_state, want in (
            ("pending", "activating", "Android starting"), ("handed-off", "active", "Android starting"),
            ("pending", "failed", "Android start ended with no verdict (recorded 'pending', unit failed)"),
            ("handed-off", "inactive", "Android start ended with no verdict (recorded 'handed-off', unit inactive)"),
            ("pending", "deactivating", "Android start ended with no verdict (recorded 'pending', unit deactivating)"),
            ("pending", "", "Android verdict 'pending' (unit state unknown)"),
            ("enforced", "active", "Android enforcing"),
            ("refused:handoff-signal-ESRCH", "failed", "Android refused: handoff-signal-ESRCH"),
            ("stopped", "inactive", "Android stopped")):
        got = status_line(m.group(0), verdict, unit_state)
        if got != want:
            bad.append(f"verdict {verdict!r} with the unit {unit_state or '<unknown>'}: want {want!r}, got {got!r}")
    status = re.search(r"^cmd_status\(\) \{\n(.*?)^\}\n", text, re.M | re.S)
    if not status or '$(selinuxns_status "$unit")' not in status.group(1):
        bad.append("cmd_status does not pass the unit's state to selinuxns_status")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("status-dead-start:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
