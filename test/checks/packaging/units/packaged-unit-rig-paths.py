#!/usr/bin/env python3
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402

UNIT_NAME_RE = re.compile(unit_files.PATH_RE + r"([A-Za-z0-9_.@-]+\.(?:service|path|socket|timer))"
                          r"(?![A-Za-z0-9_.@-])")
DROPIN_INSTALL_RE = re.compile(
    r'install\s[^\n]*?(\S+\.conf)\s*\\\s*\n\s*"?([^"\s]+)"?\s*$', re.M)
CHECKED_KEY_RE = re.compile(
    r"^(?:Condition\w+|Assert\w+|Exec\w+|EnvironmentFile|Environment|WorkingDirectory|"
    r"StandardOutput|StandardError|StandardInput|PathExists|PathExistsGlob|PathChanged|"
    r"PathModified|DirectoryNotEmpty|Listen\w+)$")
LIST_KEY_RE = re.compile(
    r"^(?:Condition\w+|Assert\w+|Exec\w+|EnvironmentFile|Environment|ReadWritePaths|"
    r"ReadOnlyPaths|InaccessiblePaths|BindPaths|BindReadOnlyPaths|Wants|Requires|After|"
    r"Before|PartOf|BindsTo|WantedBy|RequiredBy|PathExists|PathExistsGlob|PathChanged|"
    r"PathModified|DirectoryNotEmpty|Listen\w+)$")
RIG_PATH_RE = re.compile(r"(?<![\w.])/root/\S*")


def directives(text):
    """get the directives of a unit file"""
    out, section, buf = [], "", ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if not buf and (not line.strip() or line.lstrip().startswith(("#", ";"))):
            continue
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        line, buf = buf + line, ""
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
            continue
        if "=" in s:
            key, _, value = s.partition("=")
            out.append((section, key.strip(), value.strip()))
    return out


def effective(unit_text, dropin_texts):
    """merge the unit and drop-in directives"""
    eff = {}
    for text in [unit_text] + list(dropin_texts):
        for section, key, value in directives(text):
            slot = (section, key)
            if LIST_KEY_RE.match(key):
                if value == "":
                    eff[slot] = []
                else:
                    eff.setdefault(slot, []).append(value)
            else:
                eff[slot] = [value] if value != "" else []
    return eff


def rig_path_problems(unit, unit_text, dropin_texts):
    """return the problems for checked unit settings that name a rig path"""
    problems = []
    for (section, key), values in sorted(effective(unit_text, dropin_texts).items()):
        if not CHECKED_KEY_RE.match(key):
            continue
        for value in values:
            hit = RIG_PATH_RE.search(value)
            if hit:
                problems.append(f"{unit} [{section}] {key}={value} names {hit.group(0)}, "
                                f"a path only the rig stages, after the packaged drop-ins")
    return problems


def shipped(rules_text):
    """return the drop-in sources for each packaged unit"""
    units = {unit_files.installed_name(name): [] for name in UNIT_NAME_RE.findall(rules_text)}
    dropins = []
    for src, dest in DROPIN_INSTALL_RE.findall(rules_text):
        d = os.path.dirname(dest)
        if d.endswith(".d"):
            dropins.append((os.path.basename(d)[:-2], os.path.basename(dest), src))
    for unit, dest_name, src in sorted(dropins, key=lambda t: (t[0], t[1])):
        if unit in units:
            units[unit].append(src)
    return units


def check(root):
    """return the problems for every shipped unit"""
    with open(os.path.join(root, "debian", "rules")) as f:
        rules_text = f.read()
    problems = []
    for unit, dropin_srcs in sorted(shipped(rules_text).items()):
        path = unit_files.unit_path(root, unit)
        if not os.path.exists(path):
            problems.append(f"{unit}: debian/rules installs {unit}, which the tree does not "
                            f"have")
            continue
        with open(path) as f:
            unit_text = f.read()
        texts = []
        for src in dropin_srcs:
            with open(os.path.join(root, src)) as f:
                texts.append(f.read())
        problems += rig_path_problems(unit, unit_text, texts)
    return problems


def selftest():
    """test the rig path check on sample units"""
    base = ("[Unit]\nConditionPathExists=/etc/rhizo/hostfs.conf\n"
            "ConditionPathExists=/root/share/hostfs.py\n"
            "[Service]\nExecStart=/usr/bin/python3 /root/share/hostfs.py attach \\\n"
            "    --config /etc/rhizo/hostfs.conf\nReadWritePaths=/var/lib/rhizo /root\n")
    exec_only = ("[Service]\nExecStart=\nExecStart=/usr/bin/python3 /usr/lib/rhizo/tools/hostfs.py attach\n")
    whole = ("[Unit]\nConditionPathExists=\nConditionPathExists=/etc/rhizo/hostfs.conf\n"
             "ConditionPathExists=/usr/lib/rhizo/tools/hostfs.py\n" + exec_only)
    bad = 0

    def expect(label, got, want_substrings):
        """check the problems contain the wanted text"""
        nonlocal bad
        joined = "\n".join(got)
        if not want_substrings:
            if got:
                print(f"selftest FAIL: {label}: flagged a clean unit: {joined}")
                bad = 1
            return
        for w in want_substrings:
            if w not in joined:
                print(f"selftest FAIL: {label}: want a finding naming {w!r}, got: {joined or '<none>'}")
                bad = 1

    expect("an exec-only drop-in", rig_path_problems("u.service", base, [exec_only]),
           ["ConditionPathExists=/root/share/hostfs.py"])
    got = rig_path_problems("u.service", base, [exec_only])
    if any("ExecStart" in p for p in got):
        print("selftest FAIL: an ExecStart= the drop-in reset was still read from the base unit")
        bad = 1
    expect("no drop-in at all", rig_path_problems("u.service", base, []),
           ["ConditionPathExists=/root/share", "ExecStart=/usr/bin/python3 /root/share"])
    expect("a drop-in that resets every rig path", rig_path_problems("u.service", base, [whole]), [])
    expect("a later drop-in re-adding the rig path",
           rig_path_problems("u.service", base, [whole, "[Unit]\nConditionPathExists=/root/share/x\n"]),
           ["ConditionPathExists=/root/share/x"])
    expect("a replaced single value",
           rig_path_problems("u.service", "[Service]\nStandardOutput=append:/root/boot.log\n",
                             ["[Service]\nStandardOutput=append:/var/log/rhizo/boot.log\n"]), [])
    expect("a single value left on the rig", rig_path_problems(
        "u.service", "[Service]\nStandardOutput=append:/root/boot.log\n", []), ["StandardOutput=append:/root/boot.log"])
    expect("a .path watch on the rig", rig_path_problems(
        "u.path", "[Path]\nPathChanged=/root/share/x\n", []), ["PathChanged=/root/share/x"])
    expect("a socket on the rig", rig_path_problems(
        "u.socket", "[Socket]\nListenStream=/root/rhizo.sock\n", []), ["ListenStream=/root/rhizo.sock"])
    expect("an environment naming the rig", rig_path_problems(
        "u.service", "[Service]\nEnvironment=PYTHONPATH=/root/share\n", []), ["Environment=PYTHONPATH=/root/share"])
    for key, value in (("EnvironmentFile", "-/root/e"), ("ExecStop", "-/root/x"), ("ExecStart", "+@/root/x x"),
                       ("ExecStartPre", "!!/root/x"), ("ConditionPathExists", "|!/root/x")):
        expect(f"a prefixed {key}={value}",
               rig_path_problems("u.service", f"[Service]\n{key}={value}\n", []), [f"{key}={value} names /root/"])
    expect("an optional EnvironmentFile off the rig",
           rig_path_problems("u.service", "[Service]\nEnvironmentFile=-/etc/rhizo/androidd.env\n", []), [])
    expect("an optional EnvironmentFile whose drop-in left the rig value standing",
           rig_path_problems("u.service", "[Service]\nEnvironmentFile=-/root/androidd.env\n",
                             ["[Service]\nExecStart=\nExecStart=/usr/bin/python3 /usr/lib/rhizo/launcher3.py\n"]),
           ["EnvironmentFile=-/root/androidd.env names /root/androidd.env"])
    expect("an optional EnvironmentFile its drop-in reset",
           rig_path_problems("u.service", "[Service]\nEnvironmentFile=-/root/androidd.env\n",
                             ["[Service]\nEnvironmentFile=\nEnvironmentFile=-/etc/rhizo/androidd.env\n"]), [])
    expect("ReadWritePaths=/root", rig_path_problems("u.service", "[Service]\nReadWritePaths=/root\n", []), [])
    rules = ("\tinstall -m 0644 src/services/units/a.service src/services/units/b.service $(UNITS)/\n"
             "\tinstall -D -m 0644 debian/dropins/z.conf \\\n\t    $(UNITS)/rhizo-a.service.d/20-z.conf\n"
             "\tinstall -D -m 0644 debian/dropins/y.conf \\\n\t    $(UNITS)/rhizo-a.service.d/10-y.conf\n")
    got_ship = shipped(rules)
    if got_ship != {"rhizo-a.service": ["debian/dropins/y.conf", "debian/dropins/z.conf"],
                    "rhizo-b.service": []}:
        print(f"selftest FAIL: debian/rules read as {got_ship}")
        bad = 1
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "debian"))
        with open(os.path.join(tmp, "debian", "rules"), "w") as f:
            f.write("\tinstall -m 0644 src/services/units/gone.service $(UNITS)/\n")
        got_missing = check(tmp)
        if not any("gone.service" in p and "does not have" in p for p in got_missing):
            print(f"selftest FAIL: a unit debian/rules installs but the tree lacks was not named: {got_missing}")
            bad = 1
    if bad:
        return 1
    print("check-packaged-unit-rig-paths selftest: an exec-only drop-in, no drop-in, a re-added rig path and a "
          "rig log path, .path watch, socket, environment, a `-`/`@+!`/`|!`-prefixed rig path and a missing unit file "
          "are each caught; a full reset, a replaced value, an optional path off the rig and ReadWritePaths=/root "
          "are not")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    problems = check(ROOT)
    for p in problems:
        print("packaged-unit-rig-paths: " + p)
    if problems:
        return 1
    print("every unit the deb ships names no /root path in a condition, exec, environment, path watch, "
          "socket or log once its packaged drop-ins apply")
    return 0


if __name__ == "__main__":
    sys.exit(main())
