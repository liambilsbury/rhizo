#!/usr/bin/env python3
"""check rhizo-streamd runs on the resolver's render node"""
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
UNIT = os.path.join(REPO, "src", "services", "streamd", "streamd.service")
RESOLVER = os.path.join(REPO, "src", "install", "prepare", "detect-gpu-driver.sh")
PACKAGED_RESOLVER = "/usr/lib/rhizo/detect-gpu-driver.sh"
PACKAGED_DAEMON = "/usr/lib/rhizo/streamd/rhizo-streamd"
PACKAGED_ENV = "/etc/rhizo/androidd.env"


def exec_start(unit_text):
    """return the unit's ExecStart value, or None"""
    m = re.search(r"^ExecStart=(.*)$", unit_text, re.M)
    return m.group(1) if m else None


def fixture_sys(root):
    """make two amdgpu render nodes"""
    for name, vram, card in (("renderD128", 2147483648, "card0"), ("renderD129", 17095983104, "card1")):
        os.makedirs(os.path.join(root, name, "device", "drm", card))
        with open(os.path.join(root, name, "device", "uevent"), "w") as f:
            f.write("DRIVER=amdgpu\n")
        with open(os.path.join(root, name, "device", "mem_info_vram_total"), "w") as f:
            f.write(f"{vram}\n")


def run_exec_start(value, tmp, sys_dir, env_file):
    """run the ExecStart as systemd would"""
    argv_out = os.path.join(tmp, "daemon-argv")
    stub = os.path.join(tmp, "rhizo-streamd")
    with open(stub, "w") as f:
        f.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > {argv_out}\n')
    os.chmod(stub, 0o755)
    text = (value.replace("$$", "$").replace("%%", "%").replace(PACKAGED_RESOLVER, RESOLVER)
            .replace(PACKAGED_DAEMON, stub).replace(PACKAGED_ENV, env_file))
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "RHIZO_SYS_CLASS_DRM": sys_dir,
           "RHIZO_DEV_DRI": "/dev/dri"}
    r = subprocess.run(shlex.split(text), env=env, capture_output=True, text=True, timeout=60)
    daemon = open(argv_out).read().split() if os.path.exists(argv_out) else None
    if daemon is not None:
        os.remove(argv_out)
    return r.returncode, daemon


def unit_findings(unit_text):
    """return the unit's render node findings"""
    value = exec_start(unit_text)
    if value is None:
        return ["the unit has no ExecStart"]
    findings = []
    if "$" in value.replace("$$", ""):
        findings.append("ExecStart has a single $, which systemd expands itself before the shell sees it")
    if "%" in value.replace("%%", ""):
        findings.append("ExecStart has a single %, which systemd reads as a specifier")
    if findings:
        return findings
    with tempfile.TemporaryDirectory() as tmp:
        sys_dir = os.path.join(tmp, "sys")
        os.makedirs(sys_dir)
        fixture_sys(sys_dir)
        env_file = os.path.join(tmp, "androidd.env")
        open(env_file, "w").close()
        rc, daemon = run_exec_start(value, tmp, sys_dir, env_file)
        want = ["--port", "8555", "--render-node", "/dev/dri/renderD129"]
        if rc != 0 or daemon is None or not _has(daemon, want):
            findings.append(f"two GPUs, the larger on renderD129: the daemon ran with {daemon} (rc={rc}), "
                            f"want {' '.join(want)}")
        with open(env_file, "w") as f:
            f.write("RHIZO_RENDER_NODE=/dev/dri/renderD128\n")
        rc, daemon = run_exec_start(value, tmp, sys_dir, env_file)
        if rc != 0 or daemon is None or not _has(daemon, ["--render-node", "/dev/dri/renderD128"]):
            findings.append(f"androidd.env naming renderD128: the daemon ran with {daemon} (rc={rc})")
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty)
        open(env_file, "w").close()
        rc, daemon = run_exec_start(value, tmp, empty, env_file)
        if rc == 0 or daemon is not None:
            findings.append(f"a host with no render node still started the daemon with {daemon} (rc={rc})")
    return findings


def _has(argv, seq):
    """say whether argv holds seq as consecutive words"""
    return any(argv[i:i + len(seq)] == seq for i in range(len(argv) - len(seq) + 1))


def selftest():
    """assert each finding both ways on fixture units"""
    with open(UNIT) as f:
        real = f.read()
    old = re.sub(r"^ExecStart=.*$", "ExecStart=/usr/lib/rhizo/streamd/rhizo-streamd --port 8555", real, flags=re.M)
    single = real.replace("$$", "$")
    cases = [
        ("a unit that starts the daemon on its built-in node is caught", any("renderD129" in f for f in unit_findings(old))),
        ("a single $ systemd would expand is caught", any("single $" in f for f in unit_findings(single))),
        ("the real unit passes", not unit_findings(real)),
    ]
    bad = [label for label, ok in cases if not ok]
    for label in bad:
        print(f"SELFTEST FAILED: {label}", file=sys.stderr)
    if not bad:
        print(f"streamd-render-node selftest: ok ({len(cases)} cases)")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    with open(UNIT) as f:
        found = unit_findings(f.read())
    for line in found:
        print(f"FAIL: {line}", file=sys.stderr)
    if not found:
        print("streamd-render-node: rhizo-streamd.service runs the daemon on the resolver's node, follows "
              "androidd.env, and does not start without a render node")
    sys.exit(1 if found else 0)
