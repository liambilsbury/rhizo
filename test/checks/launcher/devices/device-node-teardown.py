#!/usr/bin/env python3
import contextlib
import io
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
MOUNTS = "src/androidd/sandbox/rootfs.py"

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-device-node-teardown")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import capabilities  # noqa: E402
    from sandbox import rootfs  # noqa: E402


class _StubPolicy:
    """stub policy for capability checks"""
    def __init__(self, values):
        """keep the capability values"""
        self._values = values

    def allows(self, capability):
        """return whether a capability is allowed"""
        return self._values[capability]


TMPFS_GUARDS = (
    ("NEWROOT tmpfs mount",
     'mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755")'),
    ("NEWROOT/dev tmpfs mount",
     'mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755")'),
)
SWEEP_CALL = 'enforce_device_node_absence(f"{NEWROOT}/dev", policy'


def _static_findings(text):
    """return findings from the sandbox/rootfs.py text"""
    findings = []
    for label, call in TMPFS_GUARDS:
        if not re.search(r'if not ' + re.escape(call), text):
            findings.append('%s is not fatal on failure (no "if not %s")' % (label, call))
    if not re.search(r'^\s{4}' + re.escape(SWEEP_CALL), text, re.M):
        findings.append("_bind_sockets_and_shadows no longer sweeps withheld device "
                        "nodes for absence (enforce_device_node_absence call site is missing "
                        "or commented out)")
    findings += _dri_nodes_findings(text)
    return findings


def _dri_nodes_findings(text):
    """return the dri_nodes tuple mismatch findings"""
    match = re.search(r'dri_nodes = \(([^)]*)\) if policy\.allows\("devices\.dri"\)', text)
    if not match:
        return ['dri_nodes assignment not found in %s' % MOUNTS]
    literal = tuple(x.strip().strip('"').strip("'")
                     for x in match.group(1).split(",") if x.strip())
    expected = tuple(rel.split("/", 1)[1] for rel in rootfs.DEVICE_NODE_CAPABILITIES["devices.dri"])
    if literal != expected:
        return ['dri_nodes %r in _bind_sockets_and_shadows does not match '
                'DEVICE_NODE_CAPABILITIES["devices.dri"] %r' % (literal, expected)]
    return []


def _coverage_findings_for(declared, swept, without_node=None):
    """return the devices.* table mismatches"""
    without_node = without_node or {}
    findings = []
    for missing in sorted(declared - swept - set(without_node)):
        findings.append("%s is a devices.* capability with no row in "
                        "DEVICE_NODE_CAPABILITIES or DEVICE_CAPABILITIES_WITHOUT_NODE"
                        % missing)
    for extra in sorted(swept - declared):
        findings.append("DEVICE_NODE_CAPABILITIES names %s, which sandbox/capabilities.py "
                        "does not declare" % extra)
    for extra in sorted(set(without_node) - declared):
        findings.append("DEVICE_CAPABILITIES_WITHOUT_NODE names %s, which "
                        "sandbox/capabilities.py does not declare" % extra)
    for both in sorted(swept & set(without_node)):
        findings.append("%s is in DEVICE_NODE_CAPABILITIES and also in "
                        "DEVICE_CAPABILITIES_WITHOUT_NODE" % both)
    for name, reason in sorted(without_node.items()):
        if not str(reason).strip():
            findings.append("DEVICE_CAPABILITIES_WITHOUT_NODE gives %s no reason" % name)
    return findings


def _coverage_findings():
    """find devices capabilities with no node sweep"""
    declared = {name for name in capabilities.CAPABILITIES if name.startswith("devices.")}
    swept = set(rootfs.DEVICE_NODE_CAPABILITIES)
    return _coverage_findings_for(declared, swept, rootfs.DEVICE_CAPABILITIES_WITHOUT_NODE)


def _absence_findings(sweep):
    """return findings from a fixture sweep"""
    findings = []
    work = tempfile.mkdtemp(prefix="dev-node-teardown-")
    try:
        os.makedirs(os.path.join(work, "dri"))
        for rel in ("dri/renderD128", "dri/card0", "uinput", "tun"):
            open(os.path.join(work, rel), "w").close()
        policy = _StubPolicy({"devices.dri": False, "devices.uinput": True,
                              "devices.tun": False})
        sweep(work, policy, log=lambda m: None)
        for rel in ("dri/renderD128", "dri/card0", "tun"):
            if os.path.exists(os.path.join(work, rel)):
                findings.append("a leftover %s survived a sweep with its capability off" % rel)
        if not os.path.exists(os.path.join(work, "uinput")):
            findings.append("uinput (capability on) was removed by a sweep meant only "
                            "for withheld capabilities")
        sweep(work, policy, log=lambda m: None)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return findings


def check(root):
    """return the problems in the mounts file under a root"""
    mounts_path = os.path.join(root, MOUNTS)
    try:
        text = open(mounts_path).read()
    except OSError as e:
        return ["%s: cannot read: %s" % (MOUNTS, e)]
    findings = []
    findings += _static_findings(text)
    findings += _coverage_findings()
    findings += _absence_findings(rootfs.enforce_device_node_absence)
    return findings


_DRI_NODES_LINE = '    dri_nodes = ("renderD128", "card0") if policy.allows("devices.dri") else ()'

_GOOD_SNIPPET = """
    if not mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    if not mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    enforce_device_node_absence(f"{NEWROOT}/dev", policy, log=kmsg)
""" + _DRI_NODES_LINE + "\n"
_BAD_SNIPPET = """
    mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755")
    mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755")
""" + _DRI_NODES_LINE + "\n"
_COMMENTED_SWEEP_SNIPPET = """
    if not mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    if not mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    # was: enforce_device_node_absence(f"{NEWROOT}/dev", policy, log=kmsg)
""" + _DRI_NODES_LINE + "\n"
_DRIFTED_DRI_NODES_SNIPPET = """
    if not mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    if not mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755"):
        kmsg("cannot mount")
        os._exit(1)
    enforce_device_node_absence(f"{NEWROOT}/dev", policy, log=kmsg)
    dri_nodes = ("renderD128", "card0", "card1") if policy.allows("devices.dri") else ()
"""


def _noop_sweep(dev_dir, policy, log):
    """skip the sweep"""
    pass


def selftest(root=REPO):
    """check each planted-defect snippet"""
    cases = []

    fails = _static_findings(_GOOD_SNIPPET)
    cases.append(("a correctly guarded snippet with the sweep wired in passes clean",
                 not fails, fails))

    fails = _static_findings(_BAD_SNIPPET)
    cases.append(("two unguarded mounts and a missing sweep call are all three flagged",
                 len(fails) == 3
                 and any("NEWROOT tmpfs mount" in f for f in fails)
                 and any("NEWROOT/dev tmpfs mount" in f for f in fails)
                 and any("sweep" in f for f in fails),
                 fails))

    fails = _static_findings(_COMMENTED_SWEEP_SNIPPET)
    cases.append(("a commented-out sweep call is flagged, not treated as still wired in",
                 len(fails) == 1 and any("sweep" in f for f in fails), fails))

    fails = _static_findings(_DRIFTED_DRI_NODES_SNIPPET)
    cases.append(("dri_nodes drifted from DEVICE_NODE_CAPABILITIES[\"devices.dri\"] is flagged",
                 len(fails) == 1 and any("does not match" in f for f in fails), fails))

    fails = _coverage_findings_for({"devices.dri", "devices.uinput", "devices.tun"},
                                   {"devices.dri", "devices.uinput", "devices.tun"})
    cases.append(("matching declared/swept capability sets pass clean", not fails, fails))

    fails = _coverage_findings_for(
        {"devices.dri", "devices.uinput", "devices.tun", "devices.new"},
        {"devices.dri", "devices.uinput", "devices.tun"})
    cases.append(("a devices.* capability missing from the sweep table is flagged",
                 any("devices.new" in f for f in fails), fails))

    three = {"devices.dri", "devices.uinput", "devices.tun"}
    fails = _coverage_findings_for(three | {"devices.sock"}, three,
                                   {"devices.sock": "a socket, bound only while on"})
    cases.append(("a devices.* capability named as having no node, with a reason, passes clean",
                 not fails, fails))

    fails = _coverage_findings_for(three | {"devices.sock"}, three, {"devices.sock": " "})
    cases.append(("a no-node devices.* capability with no reason is flagged",
                 len(fails) == 1 and "no reason" in fails[0], fails))

    fails = _coverage_findings_for(three, three, {"devices.tun": "a socket"})
    cases.append(("a capability both swept and named as having no node is flagged",
                 len(fails) == 1 and "also in" in fails[0], fails))

    fails = _coverage_findings_for(three, three, {"devices.gone": "a socket"})
    cases.append(("a no-node row naming an undeclared capability is flagged",
                 len(fails) == 1 and "devices.gone" in fails[0], fails))

    fails = _absence_findings(rootfs.enforce_device_node_absence)
    cases.append(("the real sweep removes only withheld capabilities' leftover nodes",
                 not fails, fails))

    fails = _absence_findings(_noop_sweep)
    cases.append(("a sweep that does nothing (the pre-fix behavior) is caught",
                 len(fails) == 3 and all("survived" in f for f in fails), fails))

    fails = check(root)
    cases.append(("the real, fixed tree passes end to end", not fails, fails))

    bad = 0
    for label, ok, fails in cases:
        print("SELFTEST %s: %s" % ("OK" if ok else "FAIL", label))
        if not ok:
            bad += 1
            for line in fails:
                print("    saw: %s" % line)
    return 1 if bad else 0


def main():
    """run the check or its selftest"""
    args = sys.argv[1:]
    root = REPO
    if "--root" in args:
        root = args[args.index("--root") + 1]
    if "--selftest" in args:
        return selftest(root)
    fails = check(root)
    for line in fails:
        print("FAIL: device-node capability teardown: %s" % line)
    if not fails:
        print("device-node capability teardown: %d devices.* capabilities swept for a "
              "withheld node's absence, %d named as having no node"
              % (len(rootfs.DEVICE_NODE_CAPABILITIES),
                 len(rootfs.DEVICE_CAPABILITIES_WITHOUT_NODE)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
