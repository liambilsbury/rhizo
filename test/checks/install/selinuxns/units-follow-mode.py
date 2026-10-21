#!/usr/bin/env python3
import os, shutil, subprocess, sys, tempfile
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "test", "checks", "lib"))
from unit_files import unit_path  # noqa: E402
MODE = "/usr/lib/rhizo/rhizo-selinux-mode"


def parse(name):
    """return {section: {key: [values]}} for a unit file"""
    out, section = {}, None
    for line in open(unit_path(REPO, name + ".service")):
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("["):
            section = out.setdefault(line.strip("[]"), {})
        elif "=" in line and section is not None:
            k, v = line.split("=", 1)
            section.setdefault(k.strip(), []).append(v.strip())
    return out


def service_values(unit, key):
    """return the values of a [Service] key"""
    return unit.get("Service", {}).get(key, [])


bad = []
units = {n: parse(n) for n in ("rhizo-policy", "rhizo-selinuxfs", "rhizo-prepare", "androidd")}
for n in ("rhizo-policy", "rhizo-selinuxfs"):
    got = service_values(units[n], "ExecCondition")
    if got != [MODE + " --is host"]:
        bad.append((n + " ExecCondition", [MODE + " --is host"], got))
got = service_values(units["rhizo-prepare"], "ExecCondition")
if got != [MODE + " --is-startable"]:
    bad.append(("rhizo-prepare ExecCondition", [MODE + " --is-startable"], got))
if "/sys/fs/selinux/enforce" in units["rhizo-prepare"].get("Unit", {}).get("ConditionPathExists", []):
    bad.append(("rhizo-prepare still conditions on selinux enforce", "absent", "present"))
if service_values(units["androidd"], "ExecCondition"):
    bad.append(("androidd ExecCondition", [], service_values(units["androidd"], "ExecCondition")))

if not os.path.exists(unit_path(REPO, "rhizo-selinux-mode.service")):
    bad.append(("rhizo-selinux-mode.service", "present", "absent"))
else:
    unit = parse("rhizo-selinux-mode")
    for section, key, want in (("Service", "Type", ["oneshot"]), ("Service", "RemainAfterExit", ["yes"]),
                               ("Service", "ExecStart", [MODE + " --write-mode-file"]),
                               ("Install", "WantedBy", ["multi-user.target"])):
        if unit.get(section, {}).get(key) != want:
            bad.append(("rhizo-selinux-mode " + key, want, unit.get(section, {}).get(key)))
    before = " ".join(unit.get("Unit", {}).get("Before", [])).split()
    for name in ("rhizo-headroomd.service", "rhizo-delayd.service", "rhizo-rtd.service"):
        if name not in before:
            bad.append(("rhizo-selinux-mode Before=", name, before))
for name in ("androidd", "androidd@", "rhizo-inputd@", "rhizo-inputd-uhid@"):
    after = " ".join(parse(name).get("Unit", {}).get("After", [])).split()
    if "rhizo-selinux-mode.service" not in after:
        bad.append((name + ".service After=", "rhizo-selinux-mode.service", after))
for name in ("rhizo-inputd@", "rhizo-inputd-uhid@", "rhizo-rtd", "rhizo-delayd", "rhizo-headroomd"):
    prevent = " ".join(service_values(parse(name), "RestartPreventExitStatus")).split()
    if "78" not in prevent:
        bad.append((name + ".service RestartPreventExitStatus=", "78, the mode refusal's exit status", prevent))
rules = open(os.path.join(REPO, "debian", "rules")).read()
boot_only = rules.split("BOOT_ONLY_UNITS :=", 1)[1].split("\noverride_", 1)[0]
if "src/services/units/boot/selinux-mode.service" not in rules or "rhizo-selinux-mode.service" not in boot_only:
    bad.append(("debian/rules installs rhizo-selinux-mode.service as a boot-only unit", "both", "missing"))
teardown = open(os.path.join(REPO, "src", "install", "teardown", "teardown.sh")).read()
if "rhizo-selinux-mode.service" not in teardown.split("UNITS=(", 1)[1].split(")", 1)[0]:
    bad.append(("teardown.sh UNITS", "rhizo-selinux-mode.service", "missing"))

with tempfile.TemporaryDirectory() as d:
    shutil.copy(os.path.join(REPO, "src", "androidd", "host", "selinux-mode.py"), os.path.join(d, "rhizo-selinux-mode.py"))
    r = subprocess.run([sys.executable, os.path.join(d, "rhizo-selinux-mode.py"), "--env-file", os.devnull],
                       capture_output=True)
    if r.returncode != 255:
        bad.append(("helper with a failing import exits 255", 255, r.returncode))

for b in bad:
    print("FAIL", b)
print("PASS" if not bad else "FAIL")
sys.exit(1 if bad else 0)
