#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "hostfs", "hostfs.service")


def join_continuations(text):
    """join backslash-continued lines"""
    return text.replace("\\\n", " ")


def parse_unit(text):
    """parse the unit file into directive lists"""
    directives = {}
    for line in join_continuations(text).split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        directives.setdefault(key.strip(), []).append(val.strip())
    return directives


def exec_start_paths(directives):
    """return the ExecStart script and --config paths"""
    exec_start = directives.get("ExecStart", [""])[0]
    tokens = exec_start.split()
    script = tokens[1] if len(tokens) > 1 else ""
    config = ""
    if "--config" in tokens:
        i = tokens.index("--config")
        if i + 1 < len(tokens):
            config = tokens[i + 1]
    return script, config


def findings(text):
    """return the problems in the unit text"""
    out = []
    directives = parse_unit(text)
    conditions = directives.get("ConditionPathExists", [])
    script, config = exec_start_paths(directives)
    if not script:
        return ["could not parse ExecStart's script path"]
    if not config:
        return ["could not parse ExecStart's --config value"]
    if config not in conditions:
        out.append("ConditionPathExists=%s is missing -- the unit is not inert on an "
                    "unconfigured machine" % config)
    if script not in conditions:
        out.append("ConditionPathExists=%s is missing -- ExecStart can run before its "
                    "own 9p mount lands"
                    % script)
    return out


def condition_result(exists_flags):
    """evaluate ConditionPathExists= entries with systemd-analyze"""
    with tempfile.TemporaryDirectory() as d:
        args = []
        for i, exists in enumerate(exists_flags):
            p = os.path.join(d, "f%d" % i)
            if exists:
                open(p, "w").close()
            args.append("ConditionPathExists=%s" % p)
        r = subprocess.run(["systemd-analyze", "condition"] + args,
                            capture_output=True, text=True)
        return r.returncode == 0


def selftest():
    """run the assertions against modified unit texts"""
    assert shutil.which("systemd-analyze"), \
        "systemd-analyze is not on PATH"
    n = 0
    n += 1
    assert condition_result([True, True]) is True
    n += 1
    assert condition_result([True, False]) is False, \
        "systemd-analyze ORed two ConditionPathExists= instead of ANDing them"
    n += 1
    assert condition_result([False, True]) is False
    n += 1
    assert condition_result([False, False]) is False
    n += 1
    real_text = open(UNIT_PATH, encoding="utf-8").read()
    real = findings(real_text)
    assert real == [], "the real unit already has a gap: %s" % real
    n += 1
    no_script_cond = real_text.replace(
        "ConditionPathExists=/root/share/hostfs.py\n", "", 1)
    assert no_script_cond != real_text, "SELFTEST SETUP FAIL: script condition line not found"
    found = findings(no_script_cond)
    assert any("can run before its own 9p mount" in f for f in found), found
    n += 1
    no_config_cond = real_text.replace(
        "ConditionPathExists=/etc/rhizo/hostfs.conf\n", "", 1)
    assert no_config_cond != real_text, "SELFTEST SETUP FAIL: config condition line not found"
    found = findings(no_config_cond)
    assert any("not inert on an unconfigured machine" in f for f in found), found
    n += 1
    drifted = real_text.replace(
        "ExecStart=/usr/bin/python3 /root/share/hostfs.py attach",
        "ExecStart=/usr/bin/python3 /root/share/rhizo-hostfs-v2.py attach", 1)
    assert drifted != real_text, "SELFTEST SETUP FAIL: ExecStart line not found"
    found = findings(drifted)
    assert any("rhizo-hostfs-v2.py" in f for f in found), found
    n += 1
    print("check-hostfs-unit-ordering selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    if not os.path.isfile(UNIT_PATH):
        print("check-hostfs-unit-ordering: cannot read %s" % UNIT_PATH)
        sys.exit(1)
    problems = findings(open(UNIT_PATH, encoding="utf-8").read())
    for p in problems:
        print("check-hostfs-unit-ordering: " + p)
    sys.exit(1 if problems else 0)
