#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
RC = "src/androidd/guest/init/disable-unused.rc"
HALS = "src/androidd/sandbox/hals.py"
COMMAND = "/system/bin/sh /system/bin/device_config put privacy enable_immersive_indicator false"
OPTIONS = (
    ("disabled", "without it init starts the write at class start, before SettingsProvider exists"),
    ("oneshot", "without it init restarts the write forever"),
    ("user root", "a shell-uid put of privacy/ is refused"),
    ("seclabel u:r:shell:s0", "only the shell domain may find device_config_service and reach SettingsProvider"),
)


def services(rc):
    """return the services of an init rc with their commands"""
    found, name = {}, None
    for line in rc.split("\n"):
        m = re.match(r"^service (\S+) (.+?)\s*$", line)
        if m:
            name = m.group(1)
            found[name] = (m.group(2), [])
        elif name and line.startswith((" ", "\t")) and line.strip():
            found[name][1].append(line.strip())
        else:
            name = None
    return found


def started_on_boot_completed(rc):
    """return the services started on sys.boot_completed=1"""
    started, inside = set(), False
    for line in rc.split("\n"):
        if re.match(r"^on property:sys\.boot_completed=1\s*$", line):
            inside = True
        elif inside and line.startswith((" ", "\t")):
            m = re.match(r"^\s+start (\S+)\s*$", line)
            if m:
                started.add(m.group(1))
        else:
            inside = False
    return started


def check(files):
    """return the failures found in the staged files"""
    bad = []
    rc = files[RC]
    owners = [n for n, (cmd, _) in services(rc).items() if cmd == COMMAND]
    if not owners:
        return ["%s has no service running `%s`" % (RC, COMMAND)]
    name = owners[0]
    opts = services(rc)[name][1]
    for opt, why in OPTIONS:
        if opt not in opts:
            bad.append("service %s lacks `%s`: %s" % (name, opt, why))
    if name not in started_on_boot_completed(rc):
        bad.append("no `on property:sys.boot_completed=1` block starts %s" % name)
    if not re.search(r'open\(f"\{RUN_ROOT\}/system_ext_upper/etc/init/rhizo-disable-unused\.rc",\s*"w"\)\.write\(\s*'
                     r'guest_files\.read\("init/disable-unused\.rc"\)\)', files[HALS]):
        bad.append("%s no longer stages rhizo-disable-unused.rc for %s" % (HALS, name))
    return bad


def load(root):
    """return the text of the rc and hals files under a root"""
    out = {}
    for rel in (RC, HALS):
        with open(os.path.join(root, rel)) as f:
            out[rel] = f.read()
    return out


def selftest():
    """check the live tree and each planted-defect copy of it"""
    live = load(ROOT)
    problems = check(live)
    assert not problems, "the live tree must pass: %s" % problems
    name = [n for n, (cmd, _) in services(live[RC]).items() if cmd == COMMAND][0]

    def mutate(rel, old, new):
        """return a copy of the files with a text replaced"""
        files = dict(live)
        assert files[rel].count(old) >= 1, "fixture anchor missing from %s: %r" % (rel, old[:60])
        files[rel] = files[rel].replace(old, new, 1)
        return files

    stanza = re.search(r"^service %s .*?(?=^\S|\Z)" % re.escape(name), live[RC], re.S | re.M).group(0)
    cases = [
        ("the write removed", mutate(RC, stanza, ""), "has no service running"),
        ("the flag set true", mutate(RC, COMMAND, COMMAND[:-len("false")] + "true"), "has no service running"),
        ("shell uid", mutate(RC, stanza, stanza.replace("user root", "user shell")), "lacks `user root`"),
        ("no seclabel", mutate(RC, stanza, re.sub(r"\n\s+seclabel u:r:shell:s0", "", stanza)),
         "lacks `seclabel u:r:shell:s0`"),
        ("not oneshot", mutate(RC, stanza, re.sub(r"\n\s+oneshot", "", stanza)), "lacks `oneshot`"),
        ("never started", mutate(RC, "    start %s\n" % name, ""), "no `on property:sys.boot_completed=1` block starts"),
        ("rc not staged", mutate(HALS, 'guest_files.read("init/disable-unused.rc")', 'guest_files.read("rhizo-other.rc")'),
         "no longer stages rhizo-disable-unused.rc"),
    ]
    for label, files, want in cases:
        got = check(files)
        assert any(want in g for g in got), "%s: expected a problem naming %r, got %s" % (label, want, got)
    print("check-status-chip-off selftest: the live tree passes; %d single regressions each fail by name" % len(cases))


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    problems = check(load(root))
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-status-chip-off: every boot turns SystemUI's status-event chip off before a Rhizo window can crash it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
