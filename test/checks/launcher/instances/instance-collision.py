#!/usr/bin/env python3

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from unit_files import unit_paths  # noqa: E402

MANIFEST = "test/checks/launcher/instances/instances.tsv"
ENV_MODULE = "src/androidd/sandbox/core.py"
UNIT_DIR = "src/services/units"
SCAN_ROOTS = ("src", "test", "tools")

SCOPES = ("per-instance", "host-global")

FAMILY = re.compile(r'^/(run|var/lib|var/log|var/cache|tmp|etc|root|srv|sys/fs/cgroup)/')

UNIT_SUFFIXES = (".service", ".socket", ".path")

UNIT_DIRECTIVES = (
    "RuntimeDirectory", "StateDirectory", "CacheDirectory", "LogsDirectory",
    "ConfigurationDirectory", "ListenStream", "ListenDatagram", "ListenFIFO",
    "StandardOutput", "StandardError", "ConditionPathExists", "PIDFile",
    "PathExists", "PathExistsGlob", "PathChanged", "PathModified", "Unit",
    "EnvironmentFile",
)
EXEC_DIRECTIVES = ("ExecStart", "ExecStartPre", "ExecStartPost", "ExecCondition",
                   "ExecStop", "ExecStopPost", "ExecReload")
LOG_SINKS = ("append:", "file:", "truncate:")
ARG_PATH = re.compile(r"(?<![\w=])/(?:run|var|tmp|etc|root|srv|sys)/[A-Za-z0-9_@%.+/-]+")

UNIT_RUN = re.compile(r"--unit=([^\s\"'\],]+)")
UNIT_RUN_WINDOW = 12

MARKERS = ("%i", "%I", "$$", "BASHPID", "SANDBOX_ID", "_instanced")

SHELL_REF = re.compile(r"^\$?\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
SHELL_VARS = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
SHELL_RESOLVE_DEPTH = 3


def _shell_bindings(text, name):
    """return the lines binding a shell name"""
    pat = re.compile(r"(?:^|[;&|(`]\s*|//)\s*%s(?:\+?=|/)" % re.escape(name), re.M)
    return [line for line in text.splitlines() if pat.search(line)]


def shell_ref_is_instanced(text, name, depth=SHELL_RESOLVE_DEPTH, seen=None):
    """check a shell name for instance markers"""
    seen = set() if seen is None else seen
    if name in seen or depth <= 0:
        return False
    seen.add(name)
    bindings = _shell_bindings(text, name)
    if not bindings:
        return False
    if any(marker in "\n".join(bindings) for marker in MARKERS):
        return True
    return any(shell_ref_is_instanced(text, ref, depth - 1, seen)
               for binding in bindings for ref in SHELL_VARS.findall(binding))


PY_PLACEHOLDERS = ("%s", "%d", "{}")
PY_FORMAT_OPERAND = re.compile(r"%\s*\(?\s*([A-Za-z_][A-Za-z0-9_]*)")
PY_CONSTS = re.compile(r"\b([A-Z][A-Z0-9_]{2,})\b")


def _py_bindings(text, name):
    """return the lines assigning a module-level name"""
    pat = re.compile(r"\s*%s\s*=[^=]" % re.escape(name))
    return [line for line in text.splitlines() if pat.match(line)]


def py_ref_is_instanced(text, name, depth=SHELL_RESOLVE_DEPTH, seen=None):
    """check a python name for instance markers"""
    seen = set() if seen is None else seen
    if name in seen or depth <= 0:
        return False
    seen.add(name)
    bindings = _py_bindings(text, name)
    if not bindings:
        return False
    if any(marker in "\n".join(bindings) for marker in MARKERS):
        return True
    return any(py_ref_is_instanced(text, ref, depth - 1, seen)
               for binding in bindings for ref in PY_CONSTS.findall(binding))

LANDMARKS = (
    ("src/androidd/boot.py:setup_veth_and_nat", "net.ipv4.ip_forward=1",
     "net.ipv4.ip_forward=1"),
    ("src/androidd/boot.py:DNAT_ARGS", "DNAT_ARGS = [",
     "iptables PREROUTING DNAT uplink:5555"),
    ("src/install/bootstrap/bootstrap.sh:LOOP_TOKENS", 'LOOP_TOKENS="loop.max_loop=',
     "loop.max_loop= on the host kernel cmdline"),
    ("src/install/prepare/prepare.sh:require_rhizo_kernel", "require_rhizo_kernel() {",
     "the kernel's built-in binder devices"),
    ("src/androidd/sandbox/rootfs.py:binderfs", "binderfs", "/dev/binderfs"),
    ("src/androidd/guest/init/adbd.rc:service.adb.tcp.port", "service.adb.tcp.port",
     "adbd tcp port 5555"),
    ("src/androidd/boot.py:NET_ULA_PREFIX", "NET_ULA_PREFIX = os.environ.get(",
     "the guest-facing IPv6 ULA /64"),
    ("src/androidd/boot.py:VBMETA_LOOP_FILE", "VBMETA_LOOP_FILE = (",
     "the loop device this instance attached vbmeta.img on"),
)

CHECKS_DIR = "test/checks/"
CHECKS_HELPERS = frozenset(CHECKS_DIR + f for f in (
    "lib/avc-lab.sh", "lib/policy-lab.sh", "services/deskbridge/desk_hello.py",
    "system/desktop/layout-expect.py", "lib/parse-avc.py", "data/audiod/daemon_tests.py"))
SKIP_DIR_PREFIX = "share"
SKIP_DIR_NAMES = ("__pycache__", ".git")

GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

ENV_PROBE = r"""
import json, sys
sys.path.insert(0, sys.argv[1])
from sandbox import core
out = {}
for k, v in vars(core).items():
    if k.isupper() and isinstance(v, (str, int)) and not isinstance(v, bool):
        out[k] = v
print("RHIZO_ENV_JSON:" + json.dumps(out))
"""


class Resource:
    __slots__ = ("where", "value", "file", "line", "instanced", "nested", "judged")

    def __init__(self, where, value, file, line, instanced=None, nested="",
                 judged=None):
        """store the fields of a resource"""
        self.where = where
        self.value = value
        self.file = file
        self.line = line
        self.instanced = instanced
        self.nested = nested
        self.judged = judged


class Row:
    __slots__ = ("resource", "scope", "where", "line")

    def __init__(self, resource, scope, where, line):
        """keep the resource, scope, location and line"""
        self.resource = resource
        self.scope = scope
        self.where = where
        self.line = line


def read_manifest(root):
    """return the parsed manifest rows, or None with the reason"""
    path = os.path.join(root, MANIFEST)
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        return None, "%s: cannot read: %s" % (MANIFEST, exc)
    rows = []
    for lineno, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            return None, "%s:%d: expected 3 tab-separated fields, got %d" % (
                MANIFEST, lineno, len(fields))
        rows.append(Row(fields[0].strip(), fields[1].strip(), fields[2].strip(), lineno))
    return rows, None


def _env_line(text, name):
    """return the line number of a constant in the text"""
    match = re.search(r'^%s\s*=' % re.escape(name), text, re.M)
    return text.count("\n", 0, match.start()) + 1 if match else 0


def _import_env(root, sandbox_id):
    """import core and return its constants"""
    env = dict(os.environ)
    env.pop("RHIZO_SANDBOX_ID", None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if sandbox_id is not None:
        env["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    env_dir = os.path.join(root, os.path.dirname(os.path.dirname(ENV_MODULE)))
    result = subprocess.run([sys.executable, "-c", ENV_PROBE, env_dir],
                            capture_output=True, text=True, env=env, cwd=root)
    for line in result.stdout.splitlines():
        if line.startswith("RHIZO_ENV_JSON:"):
            return json.loads(line[len("RHIZO_ENV_JSON:"):]), None
    return None, "%s: cannot import at RHIZO_SANDBOX_ID=%s: %s" % (
        ENV_MODULE, sandbox_id, (result.stderr.strip() or "no output")[:400])


def nests(value, other):
    """check a value nesting inside another"""
    if not (isinstance(value, str) and isinstance(other, str)):
        return False
    low, high = value.rstrip("/"), other.rstrip("/")
    return low != high and (high.startswith(low + "/") or low.startswith(high + "/"))


def derive_env(root):
    """return the core constants that name host resources"""
    at_zero, err = _import_env(root, None)
    if err:
        return [], err
    at_three, err = _import_env(root, 3)
    if err:
        return [], err
    with open(os.path.join(root, ENV_MODULE)) as handle:
        text = handle.read()
    found = []
    for name in sorted(at_zero):
        if name == "SANDBOX_ID":
            continue
        value, other = at_zero[name], at_three.get(name)
        nested = str(other) if nests(str(value), str(other)) else ""
        instanced = value != other and not nested
        if not instanced and not (isinstance(value, str) and FAMILY.match(value)):
            continue
        found.append(Resource("%s:%s" % (ENV_MODULE, name), str(value),
                              ENV_MODULE, _env_line(text, name), instanced,
                              nested))
    return found, None


def _unit_values(path):
    """return the values set in a unit file with their line numbers"""
    values = []
    for lineno, line in enumerate(open(path, errors="replace").read().splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        if key in UNIT_DIRECTIVES:
            if key in ("StandardOutput", "StandardError") and not value.startswith(LOG_SINKS):
                continue
            values.append((key, value, lineno))
        elif key in EXEC_DIRECTIVES:
            for match in ARG_PATH.finditer(stripped):
                values.append((key, match.group(0), lineno))
    return values


def derive_units(root):
    """return the host objects the unit files name"""
    found = []
    for path in unit_paths(root, UNIT_SUFFIXES):
        rel = os.path.relpath(path, root)
        seen = {}
        for key, value, lineno in _unit_values(path):
            seen.setdefault(key, {}).setdefault(value, lineno)
        for key, values in seen.items():
            for value, lineno in values.items():
                where = "%s:%s" % (rel, key)
                if len(values) > 1:
                    where += "=" + value
                found.append(Resource(where, value, rel, lineno))
    return found


def ignored_rels(root, rels):
    """return the git-ignored paths"""
    if not rels:
        return frozenset()
    try:
        proc = subprocess.run(["git", "-C", root, "check-ignore", "--"] + list(rels),
                              capture_output=True, text=True, env=GIT_ENV)
    except OSError:
        return frozenset()
    if proc.returncode not in (0, 1):
        return frozenset()
    return frozenset(line for line in proc.stdout.splitlines() if line)


RUN_SOCKET = re.compile(r"--socket[= ]([^\s\\\"']+)")
RUN_ENV = re.compile(r"(?:-p\s+|--property=)Environment=(\S+)|--setenv=(\S+)")
NO_ENV = "<no -p Environment=>"
PATH_REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"
                      r"|(?<![A-Za-z0-9_])([A-Z][A-Z0-9_]{2,})(?![A-Za-z0-9_])")


def _statement_lines(lines, index, cap=UNIT_RUN_WINDOW):
    """return the lines of a statement"""
    out = []
    depth = 0
    for offset in range(cap):
        if index + offset >= len(lines):
            break
        line = lines[index + offset]
        out.append((index + offset + 1, line))
        stripped = line.rstrip()
        depth += sum(line.count(c) for c in "([{") - sum(line.count(c) for c in ")]}")
        if not stripped.endswith("\\") and depth <= 0:
            break
    return out


def _run_site_objects(lines, index, text, rel, is_shell, unit_where):
    """return the host objects systemd-run names"""
    found = []
    env = []
    for lineno, line in _statement_lines(lines, index):
        if line.strip().startswith("#"):
            continue
        for match in RUN_ENV.finditer(line):
            env.append(match.group(1) or match.group(2))
        for match in RUN_SOCKET.finditer(line):
            found.append(_run_site_value(
                "%s:systemd-run --socket=%s" % (rel, match.group(1)),
                match.group(1), rel, lineno, text, is_shell))
        for match in ARG_PATH.finditer(line):
            found.append(_run_site_value(
                "%s:systemd-run %s" % (rel, match.group(0)),
                match.group(0), rel, lineno, text, is_shell))
    found.append(Resource("%s environment" % unit_where, " ".join(env) or NO_ENV,
                          rel, index + 1))
    return found


def _run_site_value(where, value, rel, lineno, text, is_shell):
    """return a Resource for a systemd-run value"""
    instanced = None
    if is_shell:
        for match in PATH_REF.finditer(value):
            if shell_ref_is_instanced(text, match.group(1) or match.group(2)):
                instanced = True
                break
    return Resource(where, value, rel, lineno, instanced)


def derive_systemd_run(root, ignored=None):
    """return the systemd-run unit names found in the scanned sources"""
    found = {}
    scanned = []
    for base in SCAN_ROOTS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, base)):
            dirnames[:] = [d for d in dirnames
                           if not d.startswith(SKIP_DIR_PREFIX) and d not in SKIP_DIR_NAMES]
            for name in sorted(filenames):
                if not name.endswith((".py", ".sh")):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, root)
                if rel.startswith(CHECKS_DIR) and rel not in CHECKS_HELPERS:
                    continue
                scanned.append((path, name, rel))
    if ignored is None:
        ignored = ignored_rels(root, sorted(rel for _, _, rel in scanned))
    for path, name, rel in scanned:
        if rel in ignored:
            continue
        lines = open(path, errors="replace").read().splitlines()
        for index, line in enumerate(lines):
            if line.strip().startswith("#") or "systemd-run" not in line:
                continue
            for offset in range(UNIT_RUN_WINDOW):
                if index + offset >= len(lines):
                    break
                candidate = lines[index + offset]
                if candidate.strip().startswith("#"):
                    continue
                match = UNIT_RUN.search(candidate)
                if match:
                    text = "\n".join(lines)
                    value = match.group(1)
                    instanced = None
                    ref = SHELL_REF.match(value)
                    if ref and name.endswith(".sh"):
                        instanced = shell_ref_is_instanced(text, ref.group(1))
                    elif name.endswith(".py") and value in PY_PLACEHOLDERS:
                        operand = PY_FORMAT_OPERAND.search(candidate[match.end():])
                        if operand:
                            value = operand.group(1)
                            instanced = py_ref_is_instanced(text, value)
                    where = "%s:systemd-run --unit=%s" % (rel, value)
                    found.setdefault(where, Resource(
                        where, value, rel, index + offset + 1, instanced))
                    for extra in _run_site_objects(lines, index, text, rel,
                                                   name.endswith(".sh"), where):
                        found.setdefault(extra.where, extra)
                    break
    return list(found.values())


def derive_landmarks(root):
    """return the resources found at the landmark sites"""
    found = []
    for where, needle, value in LANDMARKS:
        rel = where.rsplit(":", 1)[0]
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        text = open(path, errors="replace").read()
        if needle not in text:
            continue
        line = text.count("\n", 0, text.index(needle)) + 1
        lines = text.splitlines()
        found.append(Resource(where, value, rel, line, judged="\n".join(
            body for _, body in _statement_lines(lines, line - 1))))
    return found


def derive(root, ignored=None):
    """return every derived resource"""
    env, err = derive_env(root)
    if err:
        return None, err
    return (env + derive_units(root) + derive_systemd_run(root, ignored)
            + derive_landmarks(root)), None


def value_is_instanced(value, instanced_names):
    """return whether a value carries an instance marker or instanced name"""
    plain = value.replace("\\", "")
    if any(marker in plain for marker in MARKERS):
        return True
    return any(name in plain for name in instanced_names)


def check(root, ignored=None):
    """return the failures found in a tree"""
    fails = []
    rows, err = read_manifest(root)
    if err:
        return [err]
    resources, err = derive(root, ignored)
    if err:
        return [err]

    if not rows:
        return ["%s declares no resources" % MANIFEST]
    if not resources:
        return ["derived no resources from the tree"]
    for label, subset in (("core constants", [r for r in resources if r.file == ENV_MODULE]),
                          ("unit directives", [r for r in resources
                                               if r.file.endswith(UNIT_SUFFIXES)])):
        if not subset:
            fails.append("derived no %s" % label)

    by_where = {}
    for row in rows:
        if row.where in by_where:
            fails.append("%s:%d: %s is declared twice (first at line %d)" % (
                MANIFEST, row.line, row.where, by_where[row.where].line))
            continue
        by_where[row.where] = row
        if row.scope not in SCOPES:
            fails.append("%s:%d: %s has scope %r, expected %s" % (
                MANIFEST, row.line, row.where, row.scope, " or ".join(SCOPES)))
        for field, text in (("resource", row.resource), ("where", row.where)):
            if "TODO" in text:
                fails.append("%s:%d: %s has TODO in %s" % (
                    MANIFEST, row.line, row.where, field))
        if not row.resource:
            fails.append("%s:%d: %s has no resource name" % (MANIFEST, row.line, row.where))

    instanced_names = {row.where.rsplit(":", 1)[1] for row in rows
                       if row.scope == "per-instance" and row.where.startswith(ENV_MODULE + ":")}

    derived_wheres = set()
    for resource in resources:
        derived_wheres.add(resource.where)
        row = by_where.get(resource.where)
        if row is None:
            fails.append("%s:%d: %s is a host resource and %s does not declare it" % (
                resource.file, resource.line, resource.where, MANIFEST))
            continue
        if row.scope != "per-instance":
            continue
        instanced = resource.instanced
        if instanced is None:
            instanced = value_is_instanced(resource.judged or resource.value,
                                           instanced_names)
        if resource.nested:
            fails.append("%s:%d: %s is declared per-instance and another instance's value "
                         "%r nests INSIDE this one's %r" % (
                             resource.file, resource.line, resource.where,
                             resource.nested, resource.value))
        elif not instanced:
            fails.append("%s:%d: %s is declared per-instance and its value %r is the same "
                         "for every instance" % (
                             resource.file, resource.line, resource.where, resource.value))

    for row in rows:
        if row.where not in derived_wheres:
            fails.append("%s:%d: %s names a resource the tree no longer has" % (
                MANIFEST, row.line, row.where))

    return fails


FIXTURE_ENV = '''import os

SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
RUN_ROOT = "/run/rhizo" if SANDBOX_ID == 0 else "/run/rhizo-%d" % SANDBOX_ID
HOST_LOCK_FILE = "/run/rhizo-host.lock"
'''

FIXTURE_SCRIPT_DIR = "test/vm"

FIXTURE_UNIT = """[Service]
RuntimeDirectory=rhizo-fixture-%i
ListenStream=/run/rhizo-fixture/x.sock
"""

FIXTURE_ENV_NESTED = (
    'CGROUP_ROOT = "/sys/fs/cgroup/rhizo" if SANDBOX_ID == 0 '
    'else "/sys/fs/cgroup/rhizo/%d" % SANDBOX_ID\n')
FIXTURE_ENV_SIBLING = (
    'CGROUP_ROOT = "/sys/fs/cgroup/rhizo" if SANDBOX_ID == 0 '
    'else "/sys/fs/cgroup/rhizo-%d" % SANDBOX_ID\n')
FIXTURE_ROW_CGROUP = ("stack cgroup root\tper-instance"
                      "\tsrc/androidd/sandbox/core.py:CGROUP_ROOT\n")

FIXTURE_UNIT_ENV_INSTANCED = FIXTURE_UNIT + "EnvironmentFile=-/etc/rhizo/instances/%i.env\n"
FIXTURE_UNIT_ENV_SHARED = FIXTURE_UNIT + "EnvironmentFile=-/root/rhizo-fixture.env\n"
FIXTURE_ROW_ENVFILE = ("instance env file\tper-instance"
                       "\tsrc/services/units/fixture@.service:EnvironmentFile\n")

FIXTURE_HOST_REL = "src/services/fixture/fixture-hostd.sh"

FIXTURE_SOCKET_DERIVED = ('SOCKET=/run/fixture-audio/sock; [[ "$SANDBOX_ID" == 0 ]] '
                          '|| SOCKET="/run/fixture-audio-$SANDBOX_ID/sock"\n')
FIXTURE_SOCKET_CONSTANT = "SOCKET=/run/fixture-audio/sock\n"
FIXTURE_ENV_ARG = "  -p Environment=RHIZO_SANDBOX_ID=$SANDBOX_ID \\\n"
FIXTURE_LOG_DERIVED = "/tmp/UNITNAME.log"
FIXTURE_LOG_CONSTANT = "/tmp/fixture-daemon.log"


def fixture_site(env_arg="", log=FIXTURE_LOG_DERIVED,
                 socket=FIXTURE_SOCKET_DERIVED):
    """return a script with a systemd-run call"""
    return (FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_DERIVED + socket +
            "systemd-run --unit=$UNIT --collect \\\n" + env_arg +
            "  -p StandardOutput=file:%s \\\n" % log +
            "  /usr/local/bin/fixture-daemon --socket $SOCKET --map /run/fixture-map\n"
            "install -d /run/fixture-unrelated\n"
            'run_it "${start_cmd//UNITNAME/$UNIT}"\n')


def fixture_site_rows(log=FIXTURE_LOG_DERIVED):
    """return fixture manifest rows for the fixture sites"""
    site = "test/vm/fixture-daemon.sh:systemd-run"
    return (
        "fixture daemon unit\tper-instance\t%s --unit=$UNIT\n"
        "fixture daemon socket\tper-instance\t%s --socket=$SOCKET\n"
        "fixture daemon log\tper-instance\t%s %s\n"
        "fixture daemon map\thost-global\t%s /run/fixture-map\n"
        "fixture daemon environment\tper-instance\t%s --unit=$UNIT environment\n"
    ) % (site, site, site, log, site, site)


FIXTURE_PY_HEAD = ("import os\n"
                   "SANDBOX_ID = int(os.environ.get('RHIZO_SANDBOX_ID', '0'))\n")
FIXTURE_PY_UNIT_DERIVED = ("TIMER_UNIT = 'fixture-timer' if SANDBOX_ID == 0 "
                           "else 'fixture-timer-%d' % SANDBOX_ID\n")
FIXTURE_PY_UNIT_CONSTANT = "TIMER_UNIT = 'fixture-timer'\n"
FIXTURE_PY_RUN = ("def arm():\n"
                  "    run(['systemd-run', '--collect',\n"
                  "         '--unit=%s' % TIMER_UNIT, 'systemctl', 'stop', 'fixture'])\n")
FIXTURE_PY_ROWS = (
    "fixture timer unit\tper-instance"
    "\ttest/vm/fixture-daemon.py:systemd-run --unit=TIMER_UNIT\n"
    "fixture timer environment\thost-global"
    "\ttest/vm/fixture-daemon.py:systemd-run --unit=TIMER_UNIT environment\n")

FIXTURE_LANDMARK_REL = "src/androidd/fixture_landmark.py"
FIXTURE_LANDMARK = ("src/androidd/fixture_landmark.py:FIXTURE_LOOP_FILE",
                    "FIXTURE_LOOP_FILE = ", "the fixture's own loop record")
FIXTURE_LANDMARK_DERIVED = ("SANDBOX_ID = 0\n"
                            "FIXTURE_LOOP_FILE = (\n"
                            '    "/root/.fixture_loop" if SANDBOX_ID == 0\n'
                            '    else f"/root/.fixture_loop-{SANDBOX_ID}")\n')
FIXTURE_LANDMARK_CONSTANT = ("SANDBOX_ID = 0\n"
                             'FIXTURE_LOOP_FILE = "/root/.fixture_loop"\n')
FIXTURE_ROW_LANDMARK = ("fixture loop record\tper-instance"
                        "\tsrc/androidd/fixture_landmark.py:FIXTURE_LOOP_FILE\n")

FIXTURE_SH_HEAD = '#!/bin/bash\nSANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"\n'
FIXTURE_SH_UNIT_DERIVED = ('UNIT=rhizo-fixture; [[ "$SANDBOX_ID" == 0 ]] '
                           '|| UNIT="rhizo-fixture-$SANDBOX_ID"\n')
FIXTURE_SH_UNIT_CONSTANT = "UNIT=rhizo-fixture\n"
FIXTURE_SH_DIRECT = "systemd-run --unit=$UNIT --collect /bin/true\n"
FIXTURE_SH_PLACEHOLDER = ("start_cmd='systemd-run --unit=UNITNAME --collect /bin/true'\n"
                          'run_it "${start_cmd//UNITNAME/$UNIT}"\n')

FIXTURE_ROW_DIRECT = ("fixture daemon unit\tper-instance"
                      "\ttest/vm/fixture-daemon.sh:systemd-run --unit=$UNIT\n")
FIXTURE_ROW_PLACEHOLDER = ("fixture daemon unit\tper-instance"
                           "\ttest/vm/fixture-daemon.sh:systemd-run --unit=UNITNAME\n")

SCRATCH_SHAPE = "test/vm/start/__pycache__/start.cpython-313.pyc"
SCRATCH_SUBJECT = "test/vm/start/start-audio.sh"

FIXTURE_TSV = "\n".join((
    "run root\tper-instance\tsrc/androidd/sandbox/core.py:RUN_ROOT",
    "host lock\thost-global\tsrc/androidd/sandbox/core.py:HOST_LOCK_FILE",
    "wayland dir\tper-instance\tsrc/services/units/fixture@.service:RuntimeDirectory",
    "api socket\thost-global\tsrc/services/units/fixture@.service:ListenStream",
)) + "\n"


def selftest(root):
    """run the checker against fixture trees"""
    bad = []
    work = tempfile.mkdtemp(prefix="instcoll-")
    try:
        os.makedirs(os.path.join(work, UNIT_DIR))
        os.makedirs(os.path.join(work, FIXTURE_SCRIPT_DIR))
        os.makedirs(os.path.join(work, os.path.dirname(MANIFEST)))
        os.makedirs(os.path.join(work, os.path.dirname(FIXTURE_LANDMARK_REL)))
        os.makedirs(os.path.join(work, os.path.dirname(FIXTURE_HOST_REL)))
        unit_path = os.path.join(work, UNIT_DIR, "fixture@.service")
        script_path = os.path.join(work, FIXTURE_SCRIPT_DIR, "fixture-daemon.sh")
        py_path = os.path.join(work, FIXTURE_SCRIPT_DIR, "fixture-daemon.py")
        host_path = os.path.join(work, FIXTURE_HOST_REL)
        landmark_path = os.path.join(work, FIXTURE_LANDMARK_REL)

        def write_unit(text):
            """write the fixture unit file"""
            with open(unit_path, "w") as handle:
                handle.write(text)

        def write_tsv(text):
            """write the fixture manifest table"""
            with open(os.path.join(work, MANIFEST), "w") as handle:
                handle.write(text)

        def write_at(path, text):
            """write a fixture file, or remove it when the text is None"""
            if text is None:
                if os.path.exists(path):
                    os.remove(path)
                return
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(text)

        def lay_out(unit, script, env, py, host, landmark):
            """write the fixture files"""
            write_unit(unit)
            write_at(script_path, script)
            write_at(py_path, py)
            write_at(host_path, host)
            write_at(landmark_path, landmark)
            write_at(os.path.join(work, ENV_MODULE), FIXTURE_ENV + (env or ""))

        def expect(label, needle, text, unit=FIXTURE_UNIT, script=None, env=None,
                   py=None, host=None, landmark=None):
            """record a failure unless a finding contains the needle"""
            lay_out(unit, script, env, py, host, landmark)
            write_tsv(text)
            fails = check(work)
            if not any(needle in f for f in fails):
                bad.append("%s -- saw %s" % (label, fails or ["no findings"]))

        def expect_none(label, needle, text, unit=FIXTURE_UNIT, script=None, env=None,
                        py=None, host=None, landmark=None):
            """record a failure if a finding contains the needle"""
            lay_out(unit, script, env, py, host, landmark)
            write_tsv(text)
            fails = check(work)
            hits = [f for f in fails if needle in f]
            if hits:
                bad.append("%s -- saw %s" % (label, hits))

        undeclared = FIXTURE_TSV.replace(
            "api socket\thost-global\tsrc/services/units/fixture@.service:ListenStream\n", "")
        expect("an undeclared resource is flagged", "does not declare it", undeclared)
        expect_none("a declared resource is not flagged", "does not declare it", FIXTURE_TSV)

        fixed_env = FIXTURE_TSV.replace(
            "host lock\thost-global\tsrc/androidd/sandbox/core.py:HOST_LOCK_FILE",
            "host lock\tper-instance\tsrc/androidd/sandbox/core.py:HOST_LOCK_FILE")
        expect("a per-instance constant with one value for every id is flagged",
               "same for every instance", fixed_env)
        expect_none("a per-instance constant the id changes is not flagged",
                    "same for every instance", FIXTURE_TSV)

        expect("a per-instance directive with no %i is flagged", "same for every instance",
               FIXTURE_TSV, FIXTURE_UNIT.replace("rhizo-fixture-%i", "rhizo-fixture"))
        expect_none("a per-instance directive carrying %i is not flagged",
                    "same for every instance", FIXTURE_TSV)

        expect("a --unit= variable holding a constant is flagged", "same for every instance",
               FIXTURE_TSV + FIXTURE_ROW_DIRECT,
               script=FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_CONSTANT + FIXTURE_SH_DIRECT)
        expect_none("a --unit= variable the id derives is not flagged", "same for every instance",
                    FIXTURE_TSV + FIXTURE_ROW_DIRECT,
                    script=FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_DERIVED + FIXTURE_SH_DIRECT)
        expect("a placeholder standing for a constant is flagged", "same for every instance",
               FIXTURE_TSV + FIXTURE_ROW_PLACEHOLDER,
               script=FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_CONSTANT + FIXTURE_SH_PLACEHOLDER)
        expect_none("a placeholder standing for a derived name is not flagged",
                    "same for every instance", FIXTURE_TSV + FIXTURE_ROW_PLACEHOLDER,
                    script=FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_DERIVED + FIXTURE_SH_PLACEHOLDER)

        unused = FIXTURE_TSV + "gone\thost-global\tsrc/services/units/fixture@.service:PIDFile\n"
        expect("an unused row is flagged", "no longer has", unused)
        expect_none("a live row is not flagged", "no longer has", FIXTURE_TSV)

        duplicate = FIXTURE_TSV + "again\tper-instance\tsrc/androidd/sandbox/core.py:RUN_ROOT\n"
        expect("a duplicated where is flagged", "declared twice", duplicate)

        wrong_scope = FIXTURE_TSV.replace("run root\tper-instance", "run root\tper-host")
        expect("an unknown scope is flagged", "expected per-instance or host-global", wrong_scope)

        todo = FIXTURE_TSV.replace("api socket", "TODO")
        expect("a TODO cell is flagged", "has TODO in resource", todo)

        empty = "\n"
        expect("an empty manifest is flagged", "declares no resources", empty)

        cgroup_tsv = FIXTURE_TSV + FIXTURE_ROW_CGROUP
        expect("a per-instance constant another id nests inside is flagged",
               "nests INSIDE", cgroup_tsv, env=FIXTURE_ENV_NESTED)
        expect_none("a per-instance constant derived beside id 0's is not flagged",
                    "nests INSIDE", cgroup_tsv, env=FIXTURE_ENV_SIBLING)

        envfile_tsv = FIXTURE_TSV + FIXTURE_ROW_ENVFILE
        envfile_needle = "fixture@.service:EnvironmentFile is declared per-instance"
        expect("a per-instance EnvironmentFile naming one host-wide file is flagged",
               envfile_needle, envfile_tsv, unit=FIXTURE_UNIT_ENV_SHARED)
        expect_none("a per-instance EnvironmentFile carrying %i is not flagged",
                    envfile_needle, envfile_tsv, unit=FIXTURE_UNIT_ENV_INSTANCED)

        expect("a systemd-run call site under src/services/ is scanned", FIXTURE_HOST_REL,
               FIXTURE_TSV,
               host=FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_CONSTANT + FIXTURE_SH_DIRECT)
        expect_none("no src/services/ finding is invented when the tree has no such site",
                    FIXTURE_HOST_REL, FIXTURE_TSV)

        log_needle = "systemd-run /tmp/fixture-daemon.log is declared per-instance"
        expect("a per-instance argv path with one value for every id is flagged",
               log_needle, FIXTURE_TSV + fixture_site_rows(FIXTURE_LOG_CONSTANT),
               script=fixture_site(log=FIXTURE_LOG_CONSTANT))
        expect_none("a per-instance argv path the id derives is not flagged",
                    "systemd-run /tmp/UNITNAME.log is declared per-instance",
                    FIXTURE_TSV + fixture_site_rows(), script=fixture_site())

        socket_needle = "--socket=$SOCKET is declared per-instance"
        expect("a --socket holding one path for every id is flagged", socket_needle,
               FIXTURE_TSV + fixture_site_rows(),
               script=fixture_site(socket=FIXTURE_SOCKET_CONSTANT))
        expect_none("a --socket the id derives is not flagged", socket_needle,
                    FIXTURE_TSV + fixture_site_rows(), script=fixture_site())

        env_needle = "--unit=$UNIT environment is declared per-instance"
        expect("a per-instance call site handing its daemon no instance id is flagged",
               env_needle, FIXTURE_TSV + fixture_site_rows(), script=fixture_site())
        expect_none("a call site passing the id in the environment is not flagged",
                    env_needle, FIXTURE_TSV + fixture_site_rows(),
                    script=fixture_site(env_arg=FIXTURE_ENV_ARG))

        expect_none("a path belonging to the NEXT command is not read as this site's",
                    "/run/fixture-unrelated", FIXTURE_TSV + fixture_site_rows(),
                    script=fixture_site())

        py_needle = "fixture-daemon.py:systemd-run --unit=TIMER_UNIT is declared per-instance"
        expect("a python --unit= placeholder standing for a constant is flagged",
               py_needle, FIXTURE_TSV + FIXTURE_PY_ROWS,
               py=FIXTURE_PY_HEAD + FIXTURE_PY_UNIT_CONSTANT + FIXTURE_PY_RUN)
        expect_none("a python --unit= placeholder standing for a derivation is not flagged",
                    py_needle, FIXTURE_TSV + FIXTURE_PY_ROWS,
                    py=FIXTURE_PY_HEAD + FIXTURE_PY_UNIT_DERIVED + FIXTURE_PY_RUN)

        landmark_needle = "fixture_landmark.py:FIXTURE_LOOP_FILE is declared per-instance"
        landmarks = LANDMARKS
        globals()["LANDMARKS"] = landmarks + (FIXTURE_LANDMARK,)
        try:
            expect("a per-instance landmark spelling one value for every id is flagged",
                   landmark_needle, FIXTURE_TSV + FIXTURE_ROW_LANDMARK,
                   landmark=FIXTURE_LANDMARK_CONSTANT)
            expect_none("a per-instance landmark whose statement derives the id is not flagged",
                        landmark_needle, FIXTURE_TSV + FIXTURE_ROW_LANDMARK,
                        landmark=FIXTURE_LANDMARK_DERIVED)
        finally:
            globals()["LANDMARKS"] = landmarks

        scratch_rel = os.path.join(FIXTURE_SCRIPT_DIR, ".scratch-copy.sh")
        lay_out(FIXTURE_UNIT, None, None, None, None, None)
        write_tsv(FIXTURE_TSV)
        with open(os.path.join(work, scratch_rel), "w") as handle:
            handle.write(FIXTURE_SH_HEAD + FIXTURE_SH_UNIT_CONSTANT + FIXTURE_SH_DIRECT)
        seen = [f for f in check(work, ignored=frozenset()) if ".scratch-copy.sh" in f]
        if not seen:
            bad.append("a scanned script's undeclared call site is flagged -- saw no finding")
        hidden = [f for f in check(work, ignored=frozenset([scratch_rel]))
                  if ".scratch-copy.sh" in f]
        if hidden:
            bad.append("a gitignored copy is left out of the scan -- saw %s" % hidden)
        os.remove(os.path.join(work, scratch_rel))

        real = ignored_rels(root, [SCRATCH_SHAPE, SCRATCH_SUBJECT])
        if SCRATCH_SHAPE not in real:
            bad.append("a path .gitignore lists under the scanned tree is not reported ignored -- saw %s"
                       % sorted(real))
        if SCRATCH_SUBJECT in real:
            bad.append("a tracked product script is reported ignored -- saw %s" % sorted(real))

        lay_out(FIXTURE_UNIT, None, None, None, None, None)
        write_tsv(FIXTURE_TSV)
        clean = check(work)
        if clean:
            bad.append("a correctly declared pair produces no findings -- saw %s" % clean)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for line in bad:
        print("selftest FAIL: %s" % line)
    if not bad:
        print("selftest OK: every finding fires on its defect and on nothing else")
    return 1 if bad else 0


def listing(root):
    """print each derived resource with its location"""
    resources, err = derive(root)
    if err:
        print("FAIL: instance collision: %s" % err)
        return 1
    for resource in sorted(resources, key=lambda r: r.where):
        print("%s\t%s\t%s:%d\t%s" % (
            resource.where, resource.value, resource.file, resource.line,
            "" if resource.instanced is None else resource.instanced))
    return 0


def main():
    """run the check, the listing or the selftest"""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
    args = sys.argv[1:]
    if "--root" in args:
        root = args[args.index("--root") + 1]
    if "--selftest" in args:
        return selftest(root)
    if "--list" in args:
        return listing(root)
    fails = check(root)
    for line in fails:
        print("FAIL: instance collision: %s" % line)
    if not fails:
        rows, _ = read_manifest(root)
        resources, _ = derive(root)
        print("instance collision: %d resources declared, %d derived from the tree, "
              "every per-instance one separated" % (len(rows), len(resources)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
