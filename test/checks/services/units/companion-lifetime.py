#!/usr/bin/env python3
import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import unit_files  # noqa: E402
ANDROIDD = ("androidd.service", "androidd@%i.service")


def section_values(text, want_section, key):
    """return a key's values in a section"""
    values, section = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        m = re.match(r"^([A-Za-z]+)\s*=(.*)$", line)
        if section == want_section and m and m.group(1) == key:
            values += m.group(2).split()
    return values


def instance0_dropins():
    """return each template's instance-0 drop-in text"""
    rules = open(os.path.join(ROOT, "debian", "rules")).read()
    found = {}
    for src, unit in re.findall(r"install -D -m 0644 (debian/dropins/\S+)\s*\\?\s*\n?\s*\$\(UNITS\)/(\S+@)0\.service\.d/",
                                rules):
        found[unit + ".service"] = open(os.path.join(ROOT, src)).read()
    return found


def explicit_stops():
    """return companion_stop_units for instances 0 and 7"""
    tree = ast.parse(open(os.path.join(ROOT, "src", "androidd", "boot.py")).read())
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "companion_stop_units"]
    if len(fns) != 1:
        return None
    scope = {}
    exec(compile(ast.Module(body=fns, type_ignores=[]), "boot.py", "exec"), scope)
    return list(scope["companion_stop_units"](0)), list(scope["companion_stop_units"](7))


def findings():
    """return the findings for each companion unit"""
    bad = []
    stops = explicit_stops()
    if stops is None:
        bad.append("src/androidd/boot.py has no companion_stop_units")
        stops = ([], [])
    stop0, stop7 = stops
    for name in ("androidd.service", "androidd@.service"):
        text = open(unit_files.unit_path(ROOT, name)).read()
        if not any(v.endswith("release-staging") for v in
                   [" ".join(section_values(text, "Service", "ExecStopPost"))]):
            bad.append(f"{name}: no ExecStopPost runs release-staging")
    units = unit_files.unit_files(ROOT)
    names = set(units)
    for unit in stop0 + stop7:
        file = re.sub(r"@\d+\.service$", "@.service", unit)
        if file not in names:
            bad.append(f"companion_stop_units names {unit}, but src/services has no {file}")
    dropins = instance0_dropins()
    for name in sorted(names):
        if not name.endswith(".service") or name in ("androidd.service", "androidd@.service"):
            continue
        text = open(os.path.join(ROOT, units[name])).read()
        template = name.endswith("@.service")
        binds_to = section_values(text, "Unit", "BindsTo")
        bound = [u for u in ANDROIDD if u in section_values(text, "Unit", "PartOf") + binds_to]
        if bound:
            unit = bound[0]
            stopped = name.replace("@.service", "@7.service") in stop7 if template else name in stop0
            if unit in binds_to and unit not in section_values(text, "Unit", "After"):
                bad.append(f"{name}: BindsTo={unit} with no After={unit}")
            elif unit not in binds_to and not stopped:
                bad.append(f"{name}: PartOf={unit} only")
        if template and "androidd@%i.service" in binds_to:
            bad.append(f"{name}: binds androidd@%i.service, which for instance 0 is androidd@0.service")
        if template and name in dropins:
            drop = dropins[name]
            zero = name.replace("@.service", "@0.service")
            if "androidd.service" in section_values(drop, "Unit", "PartOf") and zero not in stop0 \
                    and "androidd.service" not in section_values(drop, "Unit", "BindsTo"):
                bad.append(f"{zero}: PartOf=androidd.service only")
    return bad


def run_check(root):
    """run this check over a source tree"""
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--root", root], capture_output=True, text=True,
                       timeout=120)
    return r.returncode, r.stdout + r.stderr


MUTANTS = (
    ("a PartOf-only companion", "src/androidd/boot.py", '"rhizo-hostfs.service", ', "",
     "rhizo-hostfs.service: PartOf=androidd.service only"),
    ("a binding without After=", "src/services/rtd/rtd.service", "PartOf=androidd.service\n",
     "PartOf=androidd.service\nBindsTo=androidd.service\n", "rhizo-rtd.service: BindsTo=androidd.service with no After="),
    ("a template bound to androidd@%i", "src/services/inputd/inputd@.service",
     "PartOf=androidd@%i.service\n", "PartOf=androidd@%i.service\nBindsTo=androidd@%i.service\nAfter=androidd@%i.service\n",
     "rhizo-inputd@.service: binds androidd@%i.service"),
    ("a template dropped from the stop list", "src/androidd/boot.py",
     ',\n                f"rhizo-server-idle@{sandbox_id}.service"]', "]",
     "rhizo-server-idle@.service: PartOf=androidd@%i.service only"),
    ("a sandbox unit without the release-staging stop", "src/services/units/boot/androidd@.service",
     "ExecStopPost=/usr/bin/python3 /root/launcher3.py release-staging\n", "",
     "androidd@.service: no ExecStopPost runs release-staging"),
    ("a stop list naming no unit", "src/androidd/boot.py", '"rhizo-deskd.service"', '"rhizo-desk.service"',
     "companion_stop_units names rhizo-desk.service"),
)


def selftest():
    """flag each mutant and pass the real tree"""
    failed = []
    for label, rel, old, new, needle in MUTANTS:
        with tempfile.TemporaryDirectory() as tmp:
            for part in ("src/services", "debian/dropins"):
                shutil.copytree(os.path.join(ROOT, part), os.path.join(tmp, part), symlinks=True,
                                ignore=shutil.ignore_patterns("__pycache__"))
            os.makedirs(os.path.join(tmp, "src", "androidd"))
            shutil.copy(os.path.join(ROOT, "src", "androidd", "boot.py"), os.path.join(tmp, "src", "androidd"))
            shutil.copy(os.path.join(ROOT, "debian", "rules"), os.path.join(tmp, "debian", "rules"))
            path = os.path.join(tmp, rel)
            text = open(path).read()
            if text.count(old) != 1:
                failed.append(f"the {label} mutant found {text.count(old)} anchors")
                continue
            with open(path, "w") as f:
                f.write(text.replace(old, new))
            rc, out = run_check(tmp)
        if rc == 0 or needle not in out:
            failed.append(f"the {label} mutant was not flagged: rc={rc} {out[-300:]!r}")
    rc, out = run_check(ROOT)
    if rc != 0:
        failed.append(f"the real tree has findings: {out[-600:]!r}")
    for f in failed:
        print("FAIL", f)
    print("companion-lifetime: selftest ok" if not failed else "companion-lifetime: selftest FAIL")
    return 1 if failed else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    out = findings()
    for line in out:
        print("FAIL:", line)
    print("companion-lifetime:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
