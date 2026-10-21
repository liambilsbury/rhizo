#!/usr/bin/env python3
"""check the sandbox's dri nodes match the gpu resolver's choice"""
import contextlib
import io
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
RESOLVER = os.path.join(REPO, "src", "install", "prepare", "detect-gpu-driver.sh")
MOUNTS = os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-render-node-choice")
sys.path.insert(0, os.path.join(REPO, "src", "androidd"))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs  # noqa: E402

TWO_AMDGPU = [("renderD128", "amdgpu", 2147483648, "card0"), ("renderD129", "amdgpu", 17095983104, "card1")]
SWAPPED = [("renderD128", "amdgpu", 17095983104, "card1"), ("renderD129", "amdgpu", 2147483648, "card0")]


def fixture_sys(root, nodes):
    """make fixture render nodes from (name, driver, vram, card) rows"""
    for name, drv, vram, card in nodes:
        os.makedirs(os.path.join(root, name, "device", "drm", card))
        with open(os.path.join(root, name, "device", "uevent"), "w") as f:
            f.write(f"DRIVER={drv}\n")
        with open(os.path.join(root, name, "device", "mem_info_vram_total"), "w") as f:
            f.write(f"{vram}\n")


def sources_on(nodes, resolver, logged):
    """return host_dri_sources run against a fixture sysfs of these nodes"""
    work = tempfile.mkdtemp(prefix="render-node-choice-")
    try:
        fixture_sys(work, nodes)
        env = {k: v for k, v in os.environ.items() if k != "RHIZO_RENDER_NODE"}
        env.update(RHIZO_SYS_CLASS_DRM=work, RHIZO_DEV_DRI="/dev/dri")
        return rootfs.host_dri_sources(env=env, resolver=resolver, log=logged.append)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def mapping_findings(resolver=RESOLVER):
    """return findings from driving host_dri_sources against fixtures"""
    findings = []
    for label, nodes, want in (
            ("two amdgpu, the larger on renderD129", TWO_AMDGPU,
             {"renderD128": "/dev/dri/renderD129", "renderD129": "/dev/dri/renderD129",
              "card0": "/dev/dri/card1", "card1": "/dev/dri/card1"}),
            ("two amdgpu swapped, the larger on renderD128", SWAPPED,
             {"renderD128": "/dev/dri/renderD128", "card0": "/dev/dri/card1", "card1": "/dev/dri/card1"})):
        got = sources_on(nodes, resolver, [])
        if got != want:
            findings.append(f"{label}: the sandbox's nodes alias {got}, want {want}")
    logged = []
    got = sources_on([], resolver, logged)
    if got or not any("dri_source=failed" in m for m in logged):
        findings.append(f"a host with no render node gave {got} and logged {logged}, "
                        "want no node and a dri_source=failed marker")
    return findings


class _Rdev:
    """a stat result carrying only a device number"""
    def __init__(self, major, minor):
        """keep a device number built from a major and minor"""
        self.st_rdev = os.makedev(major, minor)


def plan_findings(plan_fn=None):
    """return findings for the dri node plan"""
    plan_fn = plan_fn or rootfs.dri_node_plan
    rdevs = {"/dev/dri/renderD129": _Rdev(226, 129), "/dev/dri/card1": _Rdev(226, 1)}
    sources = {"renderD128": "/dev/dri/renderD129", "renderD129": "/dev/dri/renderD129",
               "card0": "/dev/dri/card1", "card1": "/dev/dri/card1"}
    got = sorted(plan_fn(sources, stat_fn=lambda p: rdevs[p], log=lambda m: None))
    want = [("card0", 226, 1), ("card1", 226, 1), ("renderD128", 226, 129), ("renderD129", 226, 129)]
    if got != want:
        return [f"a host renderD129 and card1 give the sandbox nodes {got}, want {want}"]
    return []


def loop_findings(text):
    """return findings for the dri mknod loop"""
    body = text.split("def _bind_sockets_and_shadows", 1)[-1].split("\ndef ", 1)[0]
    findings = []
    if "host_dri_sources(" not in body or "dri_node_plan(" not in body:
        findings.append("_bind_sockets_and_shadows does not mknod from dri_node_plan(host_dri_sources())")
    if re.search(r'os\.stat\(f"/dev/dri/\{n\}"\)', body):
        findings.append("_bind_sockets_and_shadows still stats /dev/dri/{n}, the fixed host name")
    return findings


def primer_findings(text):
    """return findings for the primer's dri relabel"""
    primer = text.split('HOST_PRIMER_SRC = r"""', 1)[-1].split('\n"""', 1)[0]
    if not re.search(r'_RELABEL_SPEC \+= \[\("/dev/dri/" \+ \w+, "u:object_r:gpu_device:s0"\)', primer):
        return ["the primer's relabel spec does not add every node under the sandbox's /dev/dri as gpu_device"]
    return []


def filter_findings(table=None, majors_fn=None):
    """return findings for the device filter's DRM major"""
    table = table or rootfs.DEVICE_FILTER_HOST_PATHS
    majors_fn = majors_fn or rootfs.withheld_device_majors
    path, whole = table["devices.dri"]
    findings = []
    if os.path.basename(path) == "renderD128":
        findings.append(f"the device filter stats {path}, one fixed render node, for the DRM major")
    off = type("Off", (), {"allows": lambda self, cap: False})()
    with tempfile.TemporaryDirectory() as tmp:
        open(os.path.join(tmp, "renderD129"), "w").close()
        pattern = os.path.join(tmp, os.path.basename(path))
        stat_fn = lambda p: _Rdev(226, 129) if p == os.path.join(tmp, "renderD129") else os.stat(p)
        got = majors_fn(off, paths={"devices.dri": (pattern, whole)}, stat_fn=stat_fn)
        if got != [(226, None)]:
            findings.append(f"a host whose only render node is renderD129 gives the filter {got}, want [(226, None)]")
    return findings


def check():
    """return every finding over the tree"""
    with open(MOUNTS) as f:
        mounts = f.read()
    with open(LAUNCHER) as f:
        launcher = f.read()
    return (mapping_findings() + plan_findings() + loop_findings(mounts) + primer_findings(launcher)
            + filter_findings())


def selftest():
    """assert each finding both ways on fixtures"""
    cases = []
    with tempfile.TemporaryDirectory() as tmp:
        first = os.path.join(tmp, "first.sh")
        with open(first, "w") as f:
            f.write("#!/bin/bash\necho /dev/dri/renderD128 /dev/dri/card0 amd\n")
        cases.append(("a resolver that always answers renderD128 is caught",
                      any("renderD129" in f for f in mapping_findings(first))))
    cases.append(("the real resolver passes", not mapping_findings()))
    cases.append(("a loop on the fixed host name is caught",
                  len(loop_findings('def _bind_sockets_and_shadows(m):\n'
                                    '    st = os.stat(f"/dev/dri/{n}")\n')) == 2))
    cases.append(("a loop on the resolver's nodes passes",
                  not loop_findings("def _bind_sockets_and_shadows(m):\n"
                                    "    for n, major, minor in dri_node_plan(host_dri_sources()):\n")))
    cases.append(("a plan that drops the device's own name is caught",
                  plan_findings(lambda src, stat_fn, log: [(n, 226, 129) for n in ("renderD128",)]) != []))
    cases.append(("the real plan passes", not plan_findings()))
    cases.append(("a primer with only the fixed names is caught",
                  primer_findings('HOST_PRIMER_SRC = r"""\n_RELABEL_SPEC = [("/dev/dri/renderD128", "x")]\n"""') != []))
    cases.append(("the real primer passes", not primer_findings(open(LAUNCHER).read())))
    fixed = {"devices.dri": ("/dev/dri/renderD128", True)}
    cases.append(("a filter on the fixed renderD128 is caught", len(filter_findings(table=fixed)) == 2))
    cases.append(("the real filter passes", not filter_findings()))
    bad = [label for label, ok in cases if not ok]
    for label in bad:
        print(f"SELFTEST FAILED: {label}", file=sys.stderr)
    if not bad:
        print(f"render-node-choice selftest: ok ({len(cases)} cases)")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    found = check()
    for line in found:
        print(f"FAIL: {line}", file=sys.stderr)
    if not found:
        print("render-node-choice: the sandbox gets the resolver's device under its own names and as renderD128 and "
              "card0, the primer relabels every /dev/dri node, and the filter finds the DRM major on any render node")
    sys.exit(1 if found else 0)
