#!/usr/bin/env python3
import os
import re
import shutil
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from unit_files import unit_files  # noqa: E402

TEARDOWN = os.path.join(REPO, "src", "install", "teardown", "teardown.sh")
LABELS = "rhizo-host-labels.service"
KINDS = (".service", ".socket", ".path")
EARLY_TARGETS = {"local-fs.target", "local-fs-pre.target"}


def parse(path):
    """return {section: {key: [words]}} for a unit file"""
    out, section = {}, None
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("["):
            section = out.setdefault(line.strip("[]"), {})
        elif "=" in line and section is not None:
            key, value = line.split("=", 1)
            section.setdefault(key.strip(), []).extend(value.split())
    return out


def user_units(teardown_text):
    """return the user units the teardown names"""
    m = re.search(r"^USER_UNITS=\(([^)]*)\)", teardown_text, re.M)
    return set(m.group(1).split()) if m else set()


def findings(root, teardown_text):
    """find units that can start before the label removal ends"""
    paths = unit_files(root, KINDS)
    names = sorted(paths)
    if LABELS not in names:
        return ["%s is not in %s" % (LABELS, os.path.join(root, "src", "services"))]
    users = user_units(teardown_text)
    if not users:
        return ["no USER_UNITS=( list in the teardown to tell user units apart"]
    units = {n: parse(os.path.join(root, paths[n])) for n in names}
    labels = units[LABELS].get("Unit", {})
    bad = []
    if labels.get("DefaultDependencies") != ["no"]:
        bad.append("%s keeps its default dependencies" % LABELS)
    before = set(labels.get("Before", []))
    if "sysinit.target" not in before:
        bad.append("%s is not Before=sysinit.target" % LABELS)
    after = set(labels.get("After", []))
    if after - EARLY_TARGETS:
        bad.append("%s is After= %s"
                   % (LABELS, " ".join(sorted(after - EARLY_TARGETS))))
    if "shutdown.target" not in labels.get("Conflicts", []):
        bad.append("%s does not conflict with shutdown.target" % LABELS)
    for name in names:
        if name == LABELS or name in users:
            continue
        unit = units[name].get("Unit", {})
        if "@." in name:
            if LABELS not in unit.get("After", []) and unit.get("DefaultDependencies") == ["no"]:
                bad.append("template %s has no default dependencies and is not After=%s" % (name, LABELS))
        elif name not in before:
            bad.append("%s does not name %s in Before=" % (LABELS, name))
        if LABELS in unit.get("Before", []):
            bad.append("%s is Before=%s" % (name, LABELS))
        early = EARLY_TARGETS & set(unit.get("Before", []))
        if early:
            bad.append("%s is Before=%s, which %s waits for" % (name, " ".join(sorted(early)), LABELS))
    return bad


def selftest():
    """check that each planted ordering defect is named"""
    teardown = open(TEARDOWN, encoding="utf-8").read()
    bad = []
    if findings(REPO, teardown):
        bad.append("the real units have findings: %r" % findings(REPO, teardown))
    cases = (
        ("default dependencies", LABELS, "DefaultDependencies=no\n", "", "keeps its default dependencies"),
        ("no sysinit ordering", LABELS, "Before=sysinit.target", "Before=", "is not Before=sysinit.target"),
        ("a plain unit left out", LABELS, " rhizo-prepare.service", "", "does not name rhizo-prepare.service"),
        ("ordered after a Rhizo unit", LABELS, "After=local-fs.target", "After=local-fs.target rhizo-selinux-mode.service",
         "After= rhizo-selinux-mode.service"),
        ("no shutdown conflict", LABELS, "Conflicts=shutdown.target\n", "", "does not conflict with shutdown.target"),
        ("an early template not after it", "rhizo-session-vt@.service", "After=" + LABELS + "\n", "",
         "template rhizo-session-vt@.service has no default dependencies"),
    )
    for name, unit, old, new, want in cases:
        with tempfile.TemporaryDirectory() as tmp:
            for rel in unit_files(REPO, KINDS).values():
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                shutil.copy(os.path.join(REPO, rel), os.path.join(tmp, rel))
            path = os.path.join(tmp, unit_files(tmp, KINDS)[unit])
            text = open(path, encoding="utf-8").read()
            if old not in text:
                bad.append("%s: the fixture text %r is not in %s" % (name, old, unit))
                continue
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text.replace(old, new, 1))
            got = findings(tmp, teardown)
            if not any(want in g for g in got):
                bad.append("%s was not named: %r" % (name, got))
    return bad


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        bad = selftest()
    else:
        bad = findings(REPO, open(TEARDOWN, encoding="utf-8").read())
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
