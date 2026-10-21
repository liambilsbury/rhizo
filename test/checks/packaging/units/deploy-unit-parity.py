#!/usr/bin/env python3
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402

UNIT_SUFFIXES = ("service", "socket", "path", "timer")

UNIT_RE = re.compile(
    r"(?<![\w@./-])(androidd|rhizo-[a-z0-9][a-z0-9-]*)"
    r"(@[A-Za-z0-9_%${}:.-]*)?"
    r"\.(" + "|".join(UNIT_SUFFIXES) + r")(?![\w@.-])")

OPERATIONAL_RE = re.compile(r"\b(systemctl|journalctl|systemd-run|systemd-analyze)\b")

UNIT_DEP_RE = re.compile(
    r"^\s*(Unit|Wants|Requires|Requisite|BindsTo|PartOf|Upholds|Conflicts|After|Before"
    r"|WantedBy|RequiredBy|UpheldBy|Also|OnFailure|OnSuccess"
    r"|PropagatesReloadTo|ReloadPropagatedFrom)\s*=(.*)$")

TRANSIENT_RE = re.compile(r"--unit=[\"']?([A-Za-z0-9_@%${}:.-]+)")

TRIGGER_OPTS = (
    (re.compile(r"--path-property\b"), ".path"),
    (re.compile(r"--socket-property\b"), ".socket"),
    (re.compile(r"--timer-property\b|--on-(active|boot|startup|unit-active|unit-inactive"
                r"|calendar|clock-change|timezone-change)\b"), ".timer"),
)

FMT_PERCENT_RE = re.compile(r"--unit=%s[\"']\s*%\s*([A-Za-z_][A-Za-z0-9_]*)\b")
FMT_FSTRING_RE = re.compile(r"--unit=\{([A-Za-z_][A-Za-z0-9_]*)\}")
FMT_FORMAT_RE = re.compile(r"--unit=\{\}[\"']\s*\.format\(\s*([A-Za-z_][A-Za-z0-9_]*)\b")

def _module_assignment_re(name):
    """return the regex for a module-level assignment of a name"""
    return re.compile(r"^" + re.escape(name) + r"\s*=\s*(.+)$", re.M)


LITERAL_RE = re.compile(r"""^["']([^"']*)["']""")
CALL_LITERAL_RE = re.compile(r"""^[A-Za-z_][A-Za-z0-9_.]*\(\s*["']([^"']*)["']""")


def _resolve_module_literal(name, text):
    """return the module-level literal for a name"""
    matches = _module_assignment_re(name).findall(text)
    if len(matches) != 1:
        return None
    rhs = matches[0].strip()
    m = LITERAL_RE.match(rhs)
    if m:
        return m.group(1)
    m = CALL_LITERAL_RE.match(rhs)
    if m:
        return m.group(1)
    return None


def _formatted_transient_units(text):
    """return unit names from formatted --unit= arguments"""
    out = set()
    for rx in (FMT_PERCENT_RE, FMT_FSTRING_RE, FMT_FORMAT_RE):
        for name in rx.findall(text):
            base = _resolve_module_literal(name, text)
            if base is None:
                continue
            unit = base if base.rpartition(".")[2] in UNIT_SUFFIXES else base + ".service"
            out.add(unit)
    return out


GENERATED_RE = re.compile(
    r"(?:cat|tee)\s*>+\s*\"?/(?:etc|usr/lib|run)/systemd/system/([A-Za-z0-9_@.-]+)")

SYNC_RE = re.compile(r"(?<![\w-])sync_one\s+(\S+)\s+var/share/(\S+?)\s*$", re.M)

INSTALL_RE = re.compile(
    r"(?<![\w.-])cp\s+(?:-\S+\s+)*/root/share/(\S+)\s+"
    r"(/(?:etc|usr/lib)/systemd/(?:system|user))/(\S+)")

DAEMON_RELOAD_RE = re.compile(r"(?<![\w-])systemctl daemon-reload(?![\w-])")

CONTINUATION_RE = re.compile(r"\\\n[ \t]*")
ENABLE_RE = re.compile(r"(?<![\w-])systemctl\s+(?:--\S+\s+)*(?:enable|start|restart)(?![\w-])([^\n;&|]*)")
UNMASK_RE = re.compile(r"(?<![\w-])systemctl\s+(?:--\S+\s+)*unmask(?![\w-])([^\n;&|]*)")

DEPLOYS_RE = re.compile(r"(redeploy\.sh|dpkg -i|check-package-tree\.py)")
SOURCES_LIB_RE = re.compile(r"^\s*(?:\.|source)\s+[^\n]*(?<![\w-])lib\.sh", re.M)
SYSTEM_TEST_HEADER_RE = re.compile(r"^# test-boot-mode:", re.M)
TEST_BOOT_RE = re.compile(r"(?<![\w-])test_boot(?![\w-])")

PROFILE_ARRAY_RE = re.compile(r"^SERVER_MASKED_UNITS=\((.*?)\)", re.S | re.M)
PROFILE_USER_ARRAY_RE = re.compile(r"^SERVER_MASKED_USER_UNITS=\((.*?)\)", re.S | re.M)
PROFILE_SCALAR_RE = re.compile(r"^SERVER_(?:IDLE|API)_UNIT=(\S+)\s*$", re.M)

PACKAGED_RE = re.compile(
    unit_files.PATH_RE + r"([A-Za-z0-9_.@-]+\.(?:" + "|".join(UNIT_SUFFIXES) + r"))"
    r"(?![A-Za-z0-9_.@-])")

ETC_DIR = "/etc/systemd/system"
LIB_DIR = "/usr/lib/systemd/system"
USER_ETC_DIR = "/etc/systemd/user"
USER_LIB_DIR = "/usr/lib/systemd/user"


def _code(text):
    """return the text with comment lines blanked"""
    return "\n".join(" " * len(ln) if ln.lstrip().startswith("#") else ln
                     for ln in text.split("\n"))


def _canonical(name):
    """return the template file name for a unit"""
    base, _, suffix = name.rpartition(".")
    head, at, _inst = base.partition("@")
    return (head + "@." + suffix) if at else name


def tree_units(root):
    """return the unit file basenames in the tree"""
    return set(unit_files.unit_files(root, tuple("." + s for s in UNIT_SUFFIXES)))


def staged_units(sync_text):
    """map unit basenames to sync.sh sources"""
    out = {}
    for src, dst in SYNC_RE.findall(sync_text):
        if dst.rpartition(".")[2] in UNIT_SUFFIXES:
            out[dst] = src
    return out


def installed_units(redeploy_text):
    """map unit names to redeploy.sh install targets"""
    out = {}
    for src, dest_dir, dest_name in INSTALL_RE.findall(redeploy_text):
        if dest_name.rpartition(".")[2] not in UNIT_SUFFIXES:
            continue
        entry = out.setdefault(dest_name, [src, set()])
        entry[1].add(dest_dir)
    return out


def systemctl_named(text, verb_re):
    """map unit names to first offset in text"""
    out = {}
    for m in verb_re.finditer(text):
        for um in UNIT_RE.finditer(m.group(1)):
            out.setdefault(_canonical(um.group(0)), m.start())
    return out


MIN_TRANSIENT_LITERAL = 3


def _wildcard(pattern):
    """convert a shell unit name to a regex"""
    head = pattern.split("$", 1)[0]
    if len(head) < MIN_TRANSIENT_LITERAL:
        return None
    out, i = "", 0
    while i < len(pattern):
        if pattern[i] == "$":
            j = i + 1
            if j < len(pattern) and pattern[j] == "{":
                j = pattern.find("}", j)
                j = len(pattern) if j < 0 else j + 1
            else:
                while j < len(pattern) and (pattern[j].isalnum() or pattern[j] == "_"):
                    j += 1
            out += ".*"
            i = j
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(r"\A" + out + r"\Z")


def undeclared_allowed(texts):
    """return systemd-run unit patterns and generated names"""
    patterns, generated = [], set()
    for text in texts.values():
        for line in text.split("\n"):
            for raw in TRANSIENT_RE.findall(line):
                stem, _, suffix = raw.rpartition(".")
                if suffix not in UNIT_SUFFIXES:
                    stem = raw
                names = [raw if suffix in UNIT_SUFFIXES else raw + ".service"]
                names += [stem + trig for rx_opt, trig in TRIGGER_OPTS if rx_opt.search(line)]
                for name in names:
                    rx = _wildcard(name)
                    if rx is not None:
                        patterns.append(rx)
        for unit in _formatted_transient_units(text):
            patterns.append(re.compile(r"\A" + re.escape(unit) + r"\Z"))
        generated.update(GENERATED_RE.findall(text))
    return patterns, generated


def referenced_units(texts):
    """map unit names to file labels"""
    refs = {}
    for label, text in texts.items():
        is_unit_file = label.rpartition(".")[2] in UNIT_SUFFIXES
        for line in text.split("\n"):
            values = None
            if OPERATIONAL_RE.search(line):
                values = line
            elif is_unit_file:
                m = UNIT_DEP_RE.match(line)
                if m:
                    values = m.group(2)
            if values is None:
                continue
            for m in UNIT_RE.finditer(values):
                refs.setdefault(_canonical(m.group(0)), set()).add(label)
    return refs


def profile_managed_units(cli_text):
    """return the SERVER_MASKED_UNITS and SERVER_*_UNIT names"""
    out = set()
    m = PROFILE_ARRAY_RE.search(cli_text)
    if m:
        out.update(t for t in m.group(1).split() if t.rpartition(".")[2] in UNIT_SUFFIXES)
    out.update(PROFILE_SCALAR_RE.findall(cli_text))
    return out


def profile_managed_user_units(cli_text):
    """return the SERVER_MASKED_USER_UNITS names"""
    m = PROFILE_USER_ARRAY_RE.search(cli_text)
    if not m:
        return set()
    return {t for t in m.group(1).split() if t.rpartition(".")[2] in UNIT_SUFFIXES}


def packaged_units(rules_text):
    """return the unit names in debian/rules"""
    out = set()
    for stanza in rules_text.split("install "):
        if "$(UNITS)" in stanza or "$(USER_UNITS)" in stanza:
            out.update(unit_files.installed_name(n) for n in PACKAGED_RE.findall(stanza))
    return out


def audit(units, sync_text, redeploy_text, cli_text, rules_text, sources):
    """return the unit parity findings"""
    bad = []
    sync_text, redeploy_text = _code(sync_text), _code(redeploy_text)
    staged = staged_units(sync_text)
    installed = installed_units(redeploy_text)
    refs = referenced_units(sources)
    transient, generated = undeclared_allowed(dict(sources, redeploy=redeploy_text))

    for name in sorted(refs):
        if name in generated:
            continue
        if any(p.match(name) for p in transient):
            continue
        where = ", ".join(sorted(refs[name]))
        if name not in units:
            bad.append("unit-referenced-but-undeclared: %s is asked of systemd by %s "
                       "and no file in src/services/units declares it, nor does anything mint "
                       "it with systemd-run or write it on the target" % (name, where))
            continue
        if name not in staged:
            bad.append("unit-referenced-but-not-staged: %s is asked of systemd by %s, "
                       "and sync.sh stages no share/%s"
                       % (name, where, name))
        if name not in installed:
            bad.append("unit-referenced-but-not-installed: %s is asked of systemd by %s, "
                       "and redeploy.sh copies it into no systemd directory -- systemd "
                       "answers 'Unit %s not found'" % (name, where, name))

    for label in sorted(sources):
        if not (label.startswith("test/system/") and label.endswith(".sh")
                and not set(os.path.dirname(label).split("/")[2:]) & system_test_support()
                and SYSTEM_TEST_HEADER_RE.search(sources[label])):
            continue
        code = _code(sources[label])
        if not (SOURCES_LIB_RE.search(code) and TEST_BOOT_RE.search(code)):
            continue
        if DEPLOYS_RE.search(code):
            continue
        named = sorted({_canonical(mm.group(0))
                        for line in code.split("\n")
                        if OPERATIONAL_RE.search(line)
                        for mm in UNIT_RE.finditer(line)} & units)
        if named:
            bad.append("test-boots-units-it-never-deploys: %s boots a guest and asks "
                       "systemd for %s, and never runs redeploy.sh or installs the "
                       "package"
                       % (label, ", ".join(named)))

    for name in sorted(packaged_units(rules_text)):
        if name in generated:
            continue
        if any(p.match(name) for p in transient):
            continue
        if name not in staged:
            bad.append("packaged-unit-not-staged: debian/rules ships %s and sync.sh "
                       "stages no share/%s" % (name, name))
        if name not in installed:
            bad.append("packaged-unit-not-installed: debian/rules ships %s and "
                       "redeploy.sh copies it into no systemd directory" % name)

    for name in sorted(installed):
        src, dirs = installed[name]
        if src not in staged:
            bad.append("unit-installed-but-not-staged: redeploy.sh copies "
                       "/root/share/%s, and sync.sh puts no such file in share/" % src)
        if name not in units:
            bad.append("unit-installed-but-absent-from-tree: redeploy.sh installs %s, "
                       "which no file in src/services/units declares" % name)

    for names, etc_dir, lib_dir in ((profile_managed_units(cli_text), ETC_DIR, LIB_DIR),
                                    (profile_managed_user_units(cli_text), USER_ETC_DIR,
                                     USER_LIB_DIR)):
        for name in sorted(names):
            if name not in installed:
                continue
            dirs = installed[name][1]
            if etc_dir in dirs:
                bad.append("profile-managed-unit-installed-into-etc: redeploy.sh puts %s in "
                           "%s, and src/install/cli/rhizo.sh's apply_profile() masks or unmasks "
                           "it -- it belongs in %s, where the deb ships it"
                           % (name, etc_dir, lib_dir))

    joined = CONTINUATION_RE.sub(" ", redeploy_text)
    enabled = systemctl_named(joined, ENABLE_RE)
    unmasked = systemctl_named(joined, UNMASK_RE)
    for name in sorted(profile_managed_units(cli_text) | profile_managed_user_units(cli_text)):
        if name not in enabled:
            continue
        if name in unmasked and unmasked[name] < enabled[name]:
            continue
        bad.append("profile-managed-unit-enabled-without-unmask: redeploy.sh runs "
                   "`systemctl enable/start/restart %s`, and src/install/cli/rhizo.sh's apply_profile() "
                   "masks that unit under the server profile -- unmask %s earlier in the same script" % (name, name))

    if installed:
        last_install = max(m.end() for m in INSTALL_RE.finditer(redeploy_text))
        reloads = [m.start() for m in DAEMON_RELOAD_RE.finditer(redeploy_text)]
        if not any(pos > last_install for pos in reloads):
            bad.append("unit-installed-after-the-last-daemon-reload: redeploy.sh copies a "
                       "unit file with no `systemctl daemon-reload` after it")
    return bad


def system_test_support():
    """return the test/system folders the resolver never searches"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("system_tests", os.path.join(REPO, "test/system/run/system_tests.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.SUPPORT


def load_sources():
    """read the glob-matched source files"""
    sys.path.insert(0, HERE)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
    from tree_dirs import test_dirs, tool_dirs
    globs = [
        *(os.path.join(d, ext) for d in (*tool_dirs(REPO), "tools/mesa", "tools/patches", *test_dirs(REPO))
          for ext in ("*.sh", "*.py")),
        "src/androidd/*.py", "src/androidd/*.sh",
        "src/install/*/*.sh", "src/install/tests/*/*.sh",
        "src/install/prepare/align-apex.py", "src/install/prepare/materialize-data-template.py",
        "src/services/*/*.sh", "src/androidd/host/kernel-check.sh", "src/androidd/sandbox/capability-allowed.sh",
        "src/services/*/*.py", "src/services/*/*/*.py",
    ]
    me = os.path.abspath(__file__)
    out = {}
    unit_sources = unit_files.unit_paths(REPO, (".service", ".socket", ".path")) + unit_files.dropin_paths(REPO)
    for path in [p for pattern in globs for p in glob.glob(os.path.join(REPO, pattern))] + unit_sources:
        if os.path.abspath(path) == me:
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            out[os.path.relpath(path, REPO)] = fh.read()
    return out


def _read(path):
    """return the text of a file"""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


GOOD_SYNC = """\
sync_one src/services/units/boot/androidd.service var/share/androidd.service
sync_one src/services/units/boot/androidd@.service var/share/androidd@.service
sync_one src/services/appsync/remove-entries.path var/share/rhizo-remove-entries.path
"""

GOOD_REDEPLOY = """\
stage_cmd+=$'\\n''cp /root/share/rhizo-remove-entries.path /usr/lib/systemd/system/rhizo-remove-entries.path
cp /root/share/androidd.service /etc/systemd/system/androidd.service
cp /root/share/androidd@.service /etc/systemd/system/androidd@.service
systemctl daemon-reload'
"""

GOOD_CLI = """\
SERVER_MASKED_UNITS=(rhizo-remove-entries.path)
SERVER_IDLE_UNIT=rhizo-server-idle.service
"""

GOOD_SOURCES = {
    "fixture.sh": """\
ssh_vm -t 300 "systemctl start androidd.service"
ssh_vm -t 300 "systemctl start androidd@1.service"
ssh_vm -t 10 "systemctl enable rhizo-remove-entries.path"
systemd-run --quiet --unit="rhizo-pool-replace-$id" --collect true
ssh_vm -t 10 "journalctl -u rhizo-pool-replace-3.service"
echo "rhizo-never-existed.service loaded active running"
""",
}

GOOD_RULES = """\
\tinstall -m 0644 src/services/units/boot/androidd.service src/services/units/boot/androidd@.service \\
\t                src/services/appsync/remove-entries.path $(UNITS)/
"""

GOOD_UNITS = {"androidd.service", "androidd@.service", "rhizo-remove-entries.path"}


def _named(bad, finding, subject):
    """return the findings of a kind that mention a subject"""
    return [m for m in bad if m.startswith(finding + ":") and subject in m]


def selftest():
    """run the unit parity checks on altered inputs"""
    bad = []

    def run(units, sync, redeploy, cli, sources, rules=GOOD_RULES):
        """run the audit with default rules"""
        return audit(units, sync, redeploy, cli, rules, sources)

    clean = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, GOOD_SOURCES)
    if clean:
        bad.append("a correct deploy path was flagged: %r" % clean)

    dropped_sync = GOOD_SYNC.replace(
        "sync_one src/services/units/boot/androidd@.service var/share/androidd@.service\n", "")
    dropped_both = GOOD_REDEPLOY.replace(
        "cp /root/share/androidd@.service /etc/systemd/system/androidd@.service\n", "")
    got = run(GOOD_UNITS, dropped_sync, dropped_both, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "unit-referenced-but-not-staged", "androidd@.service"):
        bad.append("androidd@.service staged by nothing, while a system test starts "
                   "androidd@1.service, was not flagged: %r" % got)
    if not _named(got, "unit-referenced-but-not-installed", "androidd@.service"):
        bad.append("androidd@.service installed by nothing, while a system test starts "
                   "androidd@1.service, was not flagged: %r" % got)

    unstaged = GOOD_SYNC.replace(
        "sync_one src/services/units/boot/androidd@.service var/share/androidd@.service\n", "")
    got = run(GOOD_UNITS, unstaged, GOOD_REDEPLOY, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "unit-installed-but-not-staged", "androidd@.service"):
        bad.append("a unit installed from a share/ path nothing stages was not "
                   "flagged: %r" % got)

    got = run(GOOD_UNITS - {"androidd@.service"},
                GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "unit-installed-but-absent-from-tree", "androidd@.service"):
        bad.append("a unit installed with no file in the tree was not flagged: %r" % got)

    invented = dict(GOOD_SOURCES)
    invented["fixture.sh"] += 'ssh_vm -t 10 "systemctl start rhizo-ghost.service"\n'
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, invented)
    if not _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a system test starting a unit nothing declares was not flagged: %r" % got)
    minted = dict(invented)
    minted["fixture.sh"] += "systemd-run --unit=rhizo-ghost --collect true\n"
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, minted)
    if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a transient unit the caller mints with systemd-run was flagged "
                   "as undeclared: %r" % got)
    trig = dict(GOOD_SOURCES)
    trig["fixture.sh"] += 'ssh_vm -t 10 "systemctl stop rhizo-ghost.path rhizo-ghost.timer"\n'
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, trig)
    if not (_named(got, "unit-referenced-but-undeclared", "rhizo-ghost.path")
            and _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.timer")):
        bad.append("stopping a .path and a .timer nothing declares or mints was not flagged: %r" % got)
    trig["fixture.sh"] += "systemd-run --unit=rhizo-ghost --path-property=PathExists=/x true\n"
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, trig)
    if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.path"):
        bad.append("the .path a systemd-run --path-property mints was flagged as undeclared: %r" % got)
    if not _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.timer"):
        bad.append("a --path-property transient also exempted a .timer it never mints: %r" % got)
    written = dict(invented)
    written["fixture.sh"] += (
        "cat > /etc/systemd/system/rhizo-ghost.service <<'UNIT'\nUNIT\n")
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, written)
    if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a unit generated onto the target was flagged as undeclared: %r" % got)

    formatted = dict(invented)
    formatted["src/services/fixture/rhizo_fixture.py"] = (
        'GHOST_UNIT = "rhizo-ghost"\n'
        'subprocess.run(["systemd-run", "--unit=%s" % GHOST_UNIT, "true"])\n')
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, formatted)
    if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a %%-formatted --unit= resolved through a same-file "
                   "module-level literal was flagged as undeclared: %r" % got)

    formatted_call = dict(invented)
    formatted_call["src/services/fixture/rhizo_fixture2.py"] = (
        'GHOST_UNIT = _instanced("rhizo-ghost", 0)\n'
        'subprocess.run(["systemd-run", "--unit=%s" % GHOST_UNIT, "true"])\n')
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, formatted_call)
    if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a %%-formatted --unit= resolved through an _instanced(base, "
                   "id)-shaped call was flagged as undeclared: %r" % got)

    for label, line in (
        ("fstring", 'subprocess.run(["systemd-run", f"--unit={GHOST_UNIT}", "true"])\n'),
        ("dotformat", 'subprocess.run(["systemd-run", "--unit={}".format(GHOST_UNIT), "true"])\n'),
    ):
        variant = dict(invented)
        variant["src/services/fixture/rhizo_%s.py" % label] = 'GHOST_UNIT = "rhizo-ghost"\n' + line
        got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, variant)
        if _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
            bad.append("a %s --unit= resolved through a same-file module-level "
                       "literal was flagged as undeclared: %r" % (label, got))

    unresolvable = dict(invented)
    unresolvable["src/services/fixture/rhizo_fixture3.py"] = (
        'import os\n'
        'GHOST_UNIT = os.environ.get("GHOST_UNIT_NAME")\n'
        'subprocess.run(["systemd-run", "--unit=%s" % GHOST_UNIT, "true"])\n')
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, unresolvable)
    if not _named(got, "unit-referenced-but-undeclared", "rhizo-ghost.service"):
        bad.append("a %%-formatted --unit= with an unresolvable NAME was not "
                   "flagged as undeclared: %r" % got)

    in_etc = GOOD_REDEPLOY.replace(
        "cp /root/share/rhizo-remove-entries.path /usr/lib/systemd/system/rhizo-remove-entries.path",
        "cp /root/share/rhizo-remove-entries.path /etc/systemd/system/rhizo-remove-entries.path")
    got = run(GOOD_UNITS, GOOD_SYNC, in_etc, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "profile-managed-unit-installed-into-etc", "rhizo-remove-entries.path"):
        bad.append("a unit apply_profile() masks, staged into /etc, was not "
                   "flagged: %r" % got)
    user_cli = GOOD_CLI + "SERVER_MASKED_USER_UNITS=(rhizo-watch.path)\n"
    user_units = GOOD_UNITS | {"rhizo-watch.path"}
    user_sync = GOOD_SYNC + "sync_one src/services/units/display-pool/rhizo-watch.path var/share/rhizo-watch.path\n"
    user_lib = GOOD_REDEPLOY.replace(
        "systemctl daemon-reload'",
        "cp /root/share/rhizo-watch.path /usr/lib/systemd/user/rhizo-watch.path\n"
        "systemctl daemon-reload'")
    user_sources = dict(GOOD_SOURCES)
    user_sources["fixture.sh"] += 'ssh_vm -t 10 "systemctl --global enable rhizo-watch.path"\n'
    got = run(user_units, user_sync, user_lib, user_cli, user_sources)
    if got:
        bad.append("a user unit apply_profile() masks with --global, staged into "
                   "/usr/lib/systemd/user, was flagged: %r" % got)
    user_etc = user_lib.replace("/usr/lib/systemd/user/rhizo-watch.path",
                                "/etc/systemd/user/rhizo-watch.path")
    got = run(user_units, user_sync, user_etc, user_cli, user_sources)
    if not _named(got, "profile-managed-unit-installed-into-etc", "rhizo-watch.path"):
        bad.append("a user unit apply_profile() masks, staged into /etc/systemd/user, "
                   "was not flagged: %r" % got)
    user_enabled = user_lib.replace(
        "systemctl daemon-reload'",
        "systemctl daemon-reload\nsystemctl --global enable rhizo-watch.path'")
    got = run(user_units, user_sync, user_enabled, user_cli, user_sources)
    if not _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-watch.path"):
        bad.append("a user unit enabled with --global before any unmask was not "
                   "flagged: %r" % got)
    user_unmasked = user_enabled.replace(
        "systemctl --global enable rhizo-watch.path'",
        "systemctl --global unmask rhizo-watch.path\nsystemctl --global enable rhizo-watch.path'")
    got = run(user_units, user_sync, user_unmasked, user_cli, user_sources)
    if got:
        bad.append("a user unit unmasked with --global before its --global enable "
                   "was flagged: %r" % got)

    got = run(GOOD_UNITS, GOOD_SYNC, in_etc, "SERVER_MASKED_UNITS=()\n", GOOD_SOURCES)
    if _named(got, "profile-managed-unit-installed-into-etc", "rhizo-remove-entries.path"):
        bad.append("a unit in /etc that no profile touches was flagged: %r" % got)

    enabled_only = GOOD_REDEPLOY.replace(
        "systemctl daemon-reload'",
        "systemctl daemon-reload\nsystemctl enable rhizo-remove-entries.path >/dev/null'")
    got = run(GOOD_UNITS, GOOD_SYNC, enabled_only, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-remove-entries.path"):
        bad.append("a profile-managed unit enabled with no unmask before it was not "
                   "flagged: %r" % got)
    unmasked_first = GOOD_REDEPLOY.replace(
        "systemctl daemon-reload'",
        "systemctl unmask rhizo-remove-entries.path \\\n"
        "                 rhizo-remove-entries.service >/dev/null\n"
        "systemctl daemon-reload\nsystemctl enable rhizo-remove-entries.path >/dev/null'")
    got = run(GOOD_UNITS, GOOD_SYNC, unmasked_first, GOOD_CLI, GOOD_SOURCES)
    if _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-remove-entries.path"):
        bad.append("a profile-managed unit unmasked before it is enabled was "
                   "flagged: %r" % got)
    unmasked_after = GOOD_REDEPLOY.replace(
        "systemctl daemon-reload'",
        "systemctl daemon-reload\nsystemctl enable rhizo-remove-entries.path >/dev/null\n"
        "systemctl unmask rhizo-remove-entries.path >/dev/null'")
    got = run(GOOD_UNITS, GOOD_SYNC, unmasked_after, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-remove-entries.path"):
        bad.append("an unmask that comes after the enable it should protect was not "
                   "flagged: %r" % got)
    restarted_only = GOOD_REDEPLOY.replace(
        "systemctl daemon-reload'",
        "systemctl daemon-reload'\nssh_vm \"systemctl restart rhizo-remove-entries.path\"")
    got = run(GOOD_UNITS, GOOD_SYNC, restarted_only, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-remove-entries.path"):
        bad.append("a profile-managed unit restarted with no unmask before it was not "
                   "flagged: %r" % got)
    got = run(GOOD_UNITS, GOOD_SYNC, enabled_only, "SERVER_MASKED_UNITS=()\n", GOOD_SOURCES)
    if _named(got, "profile-managed-unit-enabled-without-unmask", "rhizo-remove-entries.path"):
        bad.append("a unit no profile masks, enabled without an unmask, was "
                   "flagged: %r" % got)

    no_reload = GOOD_REDEPLOY.replace("systemctl daemon-reload'", "true'")
    got = run(GOOD_UNITS, GOOD_SYNC, no_reload, GOOD_CLI, GOOD_SOURCES)
    if not _named(got, "unit-installed-after-the-last-daemon-reload", "redeploy.sh"):
        bad.append("units copied with no daemon-reload after them were not "
                   "flagged: %r" % got)

    swallow = dict(GOOD_SOURCES)
    swallow["fixture.sh"] += 'systemd-run --unit="$unit" --collect true\n'
    got = run(GOOD_UNITS, dropped_sync, dropped_both, GOOD_CLI, swallow)
    if not _named(got, "unit-referenced-but-not-staged", "androidd@.service"):
        bad.append("a bare `--unit=$var` transient exempted every unit in the "
                   "tree from staging: %r" % got)
    if _wildcard("$unit.service") is not None:
        bad.append("_wildcard built a pattern out of a value that is only a variable")

    for name, want in (("androidd@1.service", "androidd@.service"),
                       ("androidd@%i.service", "androidd@.service"),
                       ("androidd@.service", "androidd@.service"),
                       ("androidd.service", "androidd.service"),
                       ("rhizo-api.socket", "rhizo-api.socket")):
        if _canonical(name) != want:
            bad.append("_canonical(%r) is %r, not %r" % (name, _canonical(name), want))

    prose = dict(GOOD_SOURCES)
    prose["fixture.sh"] += 'assert_x "rhizo-absent.service loaded active running"\n'
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, prose)
    if got:
        bad.append("a unit named only in a fixture string was treated as a "
                   "reference: %r" % got)

    test_body = ('# test-boot-mode: shared\n'
                 'source ./lib.sh\n'
                 'test_boot --release a16 || exit 1\n'
                 'ssh_vm -t 300 "systemctl start androidd@1.service"\n')
    no_deploy = dict(GOOD_SOURCES, **{"test/system/x.sh": test_body})
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, no_deploy)
    if not _named(got, "test-boots-units-it-never-deploys", "test/system/x.sh"):
        bad.append("a system test that boots and starts a unit without deploying was not "
                   "flagged: %r" % got)
    nested = dict(GOOD_SOURCES, **{"test/system/boot/x.sh": test_body.replace("./lib.sh", "../lib.sh")})
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, nested)
    if not _named(got, "test-boots-units-it-never-deploys", "test/system/boot/x.sh"):
        bad.append("a system test in a subfolder that boots and starts a unit without deploying "
                   "was not flagged: %r" % got)
    deploying = dict(GOOD_SOURCES,
                     **{"test/system/x.sh": test_body + "./redeploy.sh --skip-kill\n"})
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, deploying)
    if _named(got, "test-boots-units-it-never-deploys", "test/system/x.sh"):
        bad.append("a system test that does call redeploy.sh was flagged: %r" % got)
    library = dict(GOOD_SOURCES, **{"test/system/lib/lib.sh":
                                    "# test-boot-mode: shared\n# Usage: source ./lib.sh\n"
                                    + test_body.split("\n", 2)[2]})
    got = run(GOOD_UNITS, GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, library)
    if _named(got, "test-boots-units-it-never-deploys", "lib.sh"):
        bad.append("lib.sh was read as one of its own callers: %r" % got)

    ships_more = GOOD_RULES.replace("src/services/appsync/remove-entries.path",
                                    "src/services/appsync/remove-entries.path "
                                    "src/services/server-idle/server-idle@.service")
    got = run(GOOD_UNITS | {"rhizo-server-idle@.service"},
              GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, GOOD_SOURCES, rules=ships_more)
    if not _named(got, "packaged-unit-not-staged", "rhizo-server-idle@.service"):
        bad.append("a unit the deb ships and the rig stages nowhere was not "
                   "flagged: %r" % got)
    if not _named(got, "packaged-unit-not-installed", "rhizo-server-idle@.service"):
        bad.append("a unit the deb ships and redeploy.sh installs nowhere was not "
                   "flagged: %r" % got)
    transient_pkg = GOOD_RULES.replace("src/services/appsync/remove-entries.path",
                                       "src/services/appsync/remove-entries.path "
                                       "src/services/units/boot/prepare.service")
    minted_pkg = dict(GOOD_SOURCES)
    minted_pkg["prepare-fixture.sh"] = "systemd-run --quiet --unit=rhizo-prepare true\n"
    got = run(GOOD_UNITS | {"rhizo-prepare.service"},
              GOOD_SYNC, GOOD_REDEPLOY, GOOD_CLI, minted_pkg, rules=transient_pkg)
    if _named(got, "packaged-unit-not-staged", "rhizo-prepare.service"):
        bad.append("a packaged unit the rig mints transiently instead was "
                   "flagged: %r" % got)

    for m in bad:
        print("check-deploy-unit-parity selftest FAIL: " + m, file=sys.stderr)
    if bad:
        return 1
    print("check-deploy-unit-parity selftest: ok (a referenced unit staged by "
          "nothing, installed by nothing, installed from an unstaged share path, "
          "installed with no file behind it, referenced but declared nowhere, "
          "a trigger no --*-property mints, "
          "packaged but staged or installed by neither half, profile-managed but "
          "landed in /etc, profile-managed and enabled with no unmask before it, "
          "copied after the last daemon-reload, and started by a "
          "system test that deploys nothing are each flagged by name; a correct path, a "
          "bare --unit=$var, a transient unit, the .path its --path-property mints, "
          "a generated unit, lib.sh "
          "itself, a unit unmasked before it is enabled, a unit no profile masks "
          "and a unit named only in prose are not)")
    return 0


def main():
    """run the unit parity check"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    units = tree_units(REPO)
    sources = load_sources()
    rules_text = _read(os.path.join(REPO, "debian", "rules"))
    cli_text = _read(os.path.join(REPO, "src", "install", "cli", "rhizo.sh"))
    for what, got in (("unit files under src/services", units),
                      ("source files that could name one", sources),
                      ("units in debian/rules' $(UNITS) install", packaged_units(rules_text)),
                      ("units in src/install/cli/rhizo.sh's profile lists",
                       profile_managed_units(cli_text))):
        if not got:
            print("check-deploy-unit-parity: found no %s"
                  % what, file=sys.stderr)
            return 1
    bad = audit(units, _read(os.path.join(REPO, "test", "vm", "sync.sh")),
                _read(os.path.join(REPO, "test", "vm", "redeploy.sh")),
                cli_text, rules_text, sources)
    for m in bad:
        print("check-deploy-unit-parity: " + m, file=sys.stderr)
    if bad:
        return 1
    print("check-deploy-unit-parity: every unit the product asks systemd for is "
          "staged by sync.sh and installed by redeploy.sh; every unit the deploy "
          "path installs is staged and declared in the tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
