#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
HALS = "src/androidd/sandbox/hals.py"
LAUNCHER = "src/androidd/boot.py"
BOOTCTL = "src/androidd/guest/init/bootcontrol.rc"

PY_SERVICES = (
    (HALS, "vendor.rhizo-gatekeeper", "/vendor/bin/hw/rhizo-gatekeeper-service"),
    (LAUNCHER, "vendor.rhizo-keymint", "/vendor/bin/hw/rhizo-keymint-service"),
)


def py_service(text, name, binary):
    """return the class and restorecon of a service"""
    line = '"service %s %s\\n"' % (name, binary)
    at = text.find(line)
    if at < 0:
        return None
    m = re.search(r'"    class (\w+)\\n"', text[at:at + 400])
    before = text[max(0, at - 300):at]
    return (m.group(1) if m else None,
            'core.early_init_restorecon("%s")' % binary in before)


def check(files):
    """check that services start in the early_hal class"""
    bad = []
    for rel, name, binary in PY_SERVICES:
        got = py_service(files[rel], name, binary)
        if got is None:
            bad.append("%s stages no %s service for %s" % (rel, name, binary))
            continue
        klass, restorecon = got
        if klass != "early_hal":
            bad.append("%s starts in class %s, want early_hal" % (name, klass))
        if not restorecon:
            bad.append("%s's rc does not relabel %s at early-init"
                       % (name, binary))
    rc = files[BOOTCTL]
    m = re.search(r"^service vendor\.rhizo-bootcontrol .*?^\s+class (\w+)", rc, re.S | re.M)
    if not m:
        bad.append("rhizo-bootcontrol.rc has no class line for vendor.rhizo-bootcontrol")
    elif m.group(1) != "early_hal":
        bad.append("vendor.rhizo-bootcontrol starts in class %s, want early_hal" % m.group(1))
    render = files[HALS].find('guest_files.read("init/bootcontrol.rc")')
    bound = files[HALS][render:render + 300] if render >= 0 else ""
    if not re.search(r'"early_init_restorecon": core\.early_init_restorecon\(\s*"/vendor/bin/hw/rhizo-bootcontrol-service"\)',
                     bound):
        bad.append("sandbox/hals.py does not render rhizo-bootcontrol.rc with its binary's early-init relabel")
    return bad


def load(root):
    """return the text of the checked files under a root"""
    return {rel: open(os.path.join(root, rel)).read() for rel in (HALS, LAUNCHER, BOOTCTL)}


def selftest():
    """check the live tree and each planted-defect copy of it"""
    live = load(ROOT)
    problems = check(live)
    assert not problems, "the live tree must pass: %s" % problems

    def mutate(rel, old, new):
        """return a copy of the files with a text replaced"""
        files = dict(live)
        assert files[rel].count(old) == 1, "fixture anchor must occur once in %s: %r" % (rel, old[:60])
        files[rel] = files[rel].replace(old, new, 1)
        return files

    cases = [
        ("gatekeeper back in core",
         mutate(HALS, '"service vendor.rhizo-gatekeeper /vendor/bin/hw/rhizo-gatekeeper-service\\n"\n'
                      '            "    class early_hal\\n"',
                '"service vendor.rhizo-gatekeeper /vendor/bin/hw/rhizo-gatekeeper-service\\n"\n'
                '            "    class core\\n"'),
         "vendor.rhizo-gatekeeper starts in class core"),
        ("gatekeeper restorecon dropped",
         mutate(HALS, 'core.early_init_restorecon("/vendor/bin/hw/rhizo-gatekeeper-service") +', '""  +'),
         "does not relabel /vendor/bin/hw/rhizo-gatekeeper-service"),
        ("keymint in core",
         mutate(LAUNCHER, '"service vendor.rhizo-keymint /vendor/bin/hw/rhizo-keymint-service\\n"\n'
                          '            "    class early_hal\\n"',
                '"service vendor.rhizo-keymint /vendor/bin/hw/rhizo-keymint-service\\n"\n'
                '            "    class core\\n"'),
         "vendor.rhizo-keymint starts in class core"),
        ("bootcontrol in core",
         mutate(BOOTCTL, "    class early_hal\n", "    class core\n"),
         "vendor.rhizo-bootcontrol starts in class core"),
        ("bootcontrol relabel unbound",
         mutate(HALS, '"/vendor/bin/hw/rhizo-bootcontrol-service")},', '"/vendor/bin/hw/some-other-service")},'),
         "does not render rhizo-bootcontrol.rc with its binary's early-init relabel"),
    ]
    for name, files, want in cases:
        got = check(files)
        assert any(want in g for g in got), "%s: expected a problem naming %r, got %s" % (name, want, got)
    print("check-hal-start-class selftest: the live tree passes; %d single regressions each fail by name" % len(cases))


def main():
    """run the check or its selftest and print the result"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    problems = check(load(root))
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-hal-start-class: gatekeeper, keymint and bootcontrol start in early_hal and relabel their binaries at early-init")
    return 0


if __name__ == "__main__":
    sys.exit(main())
