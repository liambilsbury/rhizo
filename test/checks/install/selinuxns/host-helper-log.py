#!/usr/bin/env python3
import ast
import errno
import glob
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import install_dirs  # noqa: E402
from unit_files import unit_paths  # noqa: E402
LAUNCHER = "src/androidd/boot.py"
ROUTER = "route_stdio_through_pipe"
HELPERS = ("modprobe", "depmod", "insmod", "rmmod", "mount", "umount", "udevadm", "ip", "nft", "iptables", "blkid",
           "e2fsck", "mke2fs", "mkswap", "swapon", "swapoff", "fstrim", "tune2fs", "dmesg", "hwclock")
HELPER_AT_COMMAND = r"(?<![\w./=-])(?:/usr/s?bin/|/s?bin/)?(?:%s)(?![\w.-])" % "|".join(HELPERS)
LOG_TARGET = re.compile(r"/var/log/rhizo|(?<![A-Za-z])log", re.I)
UNIT_LOG = re.compile(r"^Standard(?:Output|Error)=(?:append|file):(\S+)", re.M)
UNIT_EXEC = re.compile(r"^(Exec(?:Start|StartPre|StartPost|Stop|StopPost|Reload))=(.*)$", re.M)
SPAWNERS = {"run", "Popen", "call", "check_call", "check_output", "system", "popen"}


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def bash_sets_pipefail(command):
    """return whether bash sets pipefail first"""
    words = shlex.split(command.lstrip("-@+!:"))
    if len(words) < 3 or os.path.basename(words[0]) != "bash" or words[1] != "-c":
        return False
    lexer = shlex.shlex(words[2], posix=True, punctuation_chars=";")
    lexer.whitespace_split = True
    statements = [[]]
    for token in lexer:
        if token == ";":
            statements.append([])
        else:
            statements[-1].append(token)
    joined = [" ".join(st) for st in statements]
    helper = next((i for i, st in enumerate(joined) if re.search(HELPER_AT_COMMAND, st)), len(joined))
    return any(st == ["set", "-o", "pipefail"] for st in statements[:helper])


def unit_findings(rel, text):
    """return unit helpers writing the log"""
    bad = []
    if not UNIT_LOG.search(text):
        return bad
    for key, command in UNIT_EXEC.findall(text):
        if not re.search(HELPER_AT_COMMAND, command):
            continue
        if not re.search(r"\|\s*cat\b", command):
            bad.append("%s: %s runs a host helper with the unit's log as stdout and stderr: %s" % (rel, key, command))
        elif not bash_sets_pipefail(command):
            bad.append("%s: %s pipes a host helper into cat outside bash with set -o pipefail first: %s"
                       % (rel, key, command))
    return bad


def shell_findings(rel, text):
    """return shell lines redirecting helpers to a log"""
    bad = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if line.lstrip().startswith("#") else line
        if not code.strip():
            continue
        for target in re.findall(r"^\s*exec\s+(?:[12&]?>>?)\s*(\S+)", code):
            if LOG_TARGET.search(target):
                bad.append("%s:%d: exec redirects stdio to a log: %s"
                           % (rel, number, line.strip()))
        for segment in re.split(r"\||;|&&|\|\|", code):
            if not re.match(r"\s*(?:\w+=\S*\s+)*" + HELPER_AT_COMMAND, segment):
                continue
            for target in re.findall(r"(?:^|\s)(?:[12&]?>>?)\s*([^\s&|;)]+)", segment):
                if not target.startswith(("/dev/", "&")) and LOG_TARGET.search(target):
                    bad.append("%s:%d: a host helper writes to a log: %s" % (rel, number, line.strip()))
    return bad


def python_findings(rel, text):
    """return python helper spawns writing a log"""
    bad = []
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
        segment = ast.get_source_segment(text, node) or ""
        if name == "dup2" and len(node.args) == 2 and isinstance(node.args[1], ast.Constant) \
                and node.args[1].value in (1, 2):
            bad.append("%s:%d: dup2 onto fd %d gives every child that descriptor" % (rel, node.lineno, node.args[1].value))
        if name not in SPAWNERS or not re.search(HELPER_AT_COMMAND, segment):
            continue
        for keyword in node.keywords:
            if keyword.arg in ("stdout", "stderr"):
                value = ast.get_source_segment(text, keyword.value) or ""
                if LOG_TARGET.search(value):
                    bad.append("%s:%d: a host helper writes to %s=%s" % (rel, node.lineno, keyword.arg, value))
        for const in ast.walk(node):
            if name in ("system", "popen") and isinstance(const, ast.Constant) and isinstance(const.value, str) \
                    and re.search(HELPER_AT_COMMAND, const.value) and re.search(r">>?\s*\S*log", const.value, re.I):
                bad.append("%s:%d: a host helper writes to a log: %s" % (rel, node.lineno, const.value))
    return bad


MOUNT_WORD = re.compile(r"(?<![\w./=-])(?:/usr/bin/|/bin/)?u?mount(?![\w.-])")


MOUNT_FAMILY = re.compile(r"(?<![\w.$-])(?:/(?:usr/)?s?bin/)?(?:mountpoint|umount|mount)"
                          r"\s+(?:-\S+|[\"$/])")
MOUNT_TOOL_SCRIPTS = ("src/install/prepare/derive-patches.sh",)


def mount_exec_findings(rel, text):
    """return lines running the mount binary"""
    bad = []
    if rel.endswith(".service") or (rel.startswith("src/install/") and rel.endswith(".sh")
                                    and rel not in MOUNT_TOOL_SCRIPTS):
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#") or re.match(r"(log|echo|die|failstop|refuse|printf)\b", stripped):
                continue
            hits = [m for m in MOUNT_FAMILY.finditer(line) if not re.search(r"hostops(\.py)?[}\"']* $", line[:m.start()])]
            if hits and "-t selinuxfs" not in line:
                bad.append("%s:%d: runs the mount binary: %s"
                           % (rel, number, stripped))
    elif rel.startswith("src/androidd/") and rel.endswith(".py"):
        for node in ast.walk(ast.parse(text)):
            if isinstance(node, ast.Call) and (getattr(node.func, "attr", None) in SPAWNERS
                                               or getattr(node.func, "id", None) in SPAWNERS):
                for const in ast.walk(node):
                    if isinstance(const, ast.Constant) and isinstance(const.value, str) \
                            and MOUNT_WORD.match(const.value.strip()):
                        bad.append("%s:%d: runs the mount binary: %s"
                                   % (rel, node.lineno, const.value))
    return bad


def mount_state_findings(rel, text):
    """return mount-state tests that miss a bind on a filesystem"""
    bad = []
    if not (rel.startswith("src/androidd/") and rel.endswith(".py")):
        return bad
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "ismount":
            bad.append("%s:%d: os.path.ismount is false for a bind on one filesystem; use core.is_mount_point"
                       % (rel, node.lineno))
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) \
                and getattr(node.value.func, "attr", None) == "umount_tree":
            bad.append("%s:%d: the failures umount_tree returns are discarded" % (rel, node.lineno))
    return bad


def entry_findings(rel, text):
    """return a main block without the router"""
    tree = ast.parse(text)
    for node in tree.body:
        if isinstance(node, ast.If) and "__main__" in ast.dump(node.test):
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Call) \
                    and getattr(first.value.func, "id", "") == ROUTER:
                return []
            return ["%s: the main block does not start with %s()" % (rel, ROUTER)]
    return ["%s has no main block" % rel]


def call_lines(function, name):
    """return call lines of name"""
    return [n.lineno for n in ast.walk(function) if isinstance(n, ast.Call)
            and (getattr(n.func, "attr", None) == name or getattr(n.func, "id", None) == name)]


def namespace_findings(files):
    """return namespace helpers holding the log pipe"""
    bad = []
    for rel in sorted(f for f in files if f.startswith("src/androidd/") and f.endswith(".py")):
        for function in ast.walk(ast.parse(files[rel])):
            if not isinstance(function, ast.FunctionDef):
                continue
            entering = call_lines(function, "drop_to_init_caps")
            if call_lines(function, "fork"):
                entering += [n.lineno for n in ast.walk(function) if isinstance(n, ast.Name) and n.id == "VIEW_KEEPER_COMM"]
            if not entering:
                continue
            silenced = call_lines(function, "stdio_to_null")
            if not silenced or min(silenced) > min(entering):
                bad.append("%s:%d: %s enters Android's namespace without stdio_to_null() first"
                           % (rel, min(entering), function.name))
    if LAUNCHER in files:
        for function in ast.walk(ast.parse(files[LAUNCHER])):
            if isinstance(function, ast.FunctionDef) and function.name == "enter_sandbox_init":
                silenced, execs = call_lines(function, "stdio_to_null"), call_lines(function, "execv")
                if not execs or not silenced or min(silenced) > min(execs):
                    bad.append("%s: enter_sandbox_init execs init without stdio_to_null() first" % LAUNCHER)
                reported = [t for t in ast.walk(function) if isinstance(t, ast.Try) and any(
                    getattr(c.func, "attr", None) == "execv" or getattr(c.func, "id", None) == "execv"
                    for b in t.body for c in ast.walk(b) if isinstance(c, ast.Call))
                    and any(call_lines(h, "kmsg") for h in t.handlers)]
                if not reported:
                    bad.append("%s: a failed exec of init is not reported with kmsg after stdout goes to /dev/null" % LAUNCHER)
    return bad


def scan(files):
    """return every finding for path to text"""
    bad = []
    for rel, text in sorted(files.items()):
        if rel.endswith((".service", ".conf")):
            bad += unit_findings(rel, text)
        elif rel.endswith(".sh"):
            bad += shell_findings(rel, text)
        elif rel.endswith(".py"):
            bad += python_findings(rel, text)
        bad += mount_exec_findings(rel, text) + mount_state_findings(rel, text)
        if rel == LAUNCHER:
            bad += entry_findings(rel, text)
    return bad + namespace_findings(files)


UNSCANNED = {"src/services/hostfs/hostfs.py"}


def tree_files():
    """return the checked files by path"""
    patterns = ["debian/dropins/*.conf", "src/androidd/*.py", "src/services/*/*.py", "src/services/*/*.sh"]
    patterns += [os.path.join(d, ext) for d in install_dirs(REPO) for ext in ("*.sh", "*.py")]
    paths = unit_paths(REPO, (".service",)) + [p for pattern in patterns for p in glob.glob(os.path.join(REPO, pattern))]
    return {os.path.relpath(p, REPO): read(os.path.relpath(p, REPO))
            for p in paths if os.path.relpath(p, REPO) not in UNSCANNED}


CHILD = """
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
from sandbox import core
mode, mark, kmsg = sys.argv[2:5]
if kmsg != "-":
    core.KMSG_PATH = kmsg
pumps = []
if mode == "early":
    def refuse():
        raise OSError(1, "capset refused")
    core._drop_all_capabilities = refuse
try:
    if mode in ("route", "caps"):
        pumps = core.route_stdio_through_pipe()
    elif mode == "full":
        pumps = core.route_stdio_through_pipe("/dev/full")
    elif mode == "early":
        pumps = core.route_stdio_through_pipe("/dev/null")
except OSError as e:
    with open(mark, "a") as fh:
        fh.write("route-failed %d\\n" % e.errno)
    try:
        os.waitpid(-1, os.WNOHANG)
        verdict = "zombie-or-child"
    except ChildProcessError:
        verdict = "reaped"
    with open(mark, "a") as fh:
        fh.write("%s\\n" % verdict)
    sys.exit(0)
with open(mark, "a") as fh:
    fh.write("%d\\n" % os.getpid())
if mode == "caps":
    def caps(pid):
        return [l.split()[1] for l in open("/proc/%d/status" % pid) if l.split()[0] in ("CapInh:", "CapPrm:", "CapEff:", "CapAmb:")]
    with open(mark, "a") as fh:
        fh.write("caps-self %s\\n" % " ".join(caps(os.getpid())))
        fh.write("caps-pump %s\\n" % " ".join(caps(pumps[0])))
        targets = [os.readlink("/proc/%d/fd/%s" % (pumps[0], n)) for n in os.listdir("/proc/%d/fd" % pumps[0])]
        fh.write("fds-pump %s\\n" % " ".join(sorted(targets)))
subprocess.run(["sh", "-c", "readlink /proc/self/fd/1; readlink /proc/self/fd/2; echo from-helper; echo helper-error >&2"], check=True)
print("from-parent-end", flush=True)
"""


def run_child(mode, kmsg="-", userns=False):
    """run a child and return its outputs"""
    with tempfile.TemporaryDirectory() as work:
        log, mark = os.path.join(work, "log"), os.path.join(work, "mark")
        if kmsg != "-":
            kmsg = os.path.join(work, kmsg)
            os.makedirs(os.path.dirname(kmsg), exist_ok=True)
            if not kmsg.endswith("missing/kmsg"):
                open(kmsg, "w").close()
        command = [sys.executable, "-I", "-c", CHILD, os.path.join(REPO, "src", "androidd"), mode, mark, kmsg]
        if userns:
            command = ["unshare", "-Ur"] + command
        with open(log, "ab") as out:
            subprocess.run(command, stdout=out, stderr=out, check=True, timeout=60)
        if mode in ("full", "early"):
            time.sleep(1)
        else:
            deadline = time.monotonic() + 30
            while "from-parent-end" not in open(log).read() and time.monotonic() < deadline:
                time.sleep(0.05)
        reported = open(kmsg).read() if kmsg != "-" and os.path.exists(kmsg) else ""
        return open(log).read(), open(mark).read().splitlines(), reported


def pump_findings(route):
    """return a child's log"""
    return run_child(route)[0]


def failing_pump_findings():
    """return findings for failing pumps"""
    bad = []
    try:
        for label, kmsg in (("a missing kmsg", "missing/kmsg"), ("a writable kmsg", "kmsg")):
            _, marks, reported = run_child("full", kmsg)
            if len(marks) != 1:
                bad.append("%s: the log pump ran the caller's code, markers %r" % (label, marks))
            if kmsg == "kmsg" and ("write to fd" not in reported or "dropped" not in reported):
                bad.append("a failed write was not reported with its dropped bytes: %r" % reported)
        _, marks, _ = run_child("early")
        if marks != ["route-failed %d" % errno.EPIPE, "reaped"]:
            bad.append("a pump that died at start was not reported and reaped: %r" % marks)
        bad += capability_findings()
    except subprocess.CalledProcessError as e:
        bad.append("a child using the log pump exited %d" % e.returncode)
    return bad


def capability_findings():
    """return findings for the pump's capabilities and descriptors"""
    _, marks, _ = run_child("caps", "kmsg", userns=True)
    got = {m.split()[0]: m.split()[1:] for m in marks if m.split()[0] in ("caps-self", "caps-pump", "fds-pump")}
    if set(got) != {"caps-self", "caps-pump", "fds-pump"}:
        return ["the capability child printed %r" % marks]
    bad = []
    if all(int(v, 16) == 0 for v in got["caps-self"]):
        bad.append("the launcher holds no capability here: %r" % got["caps-self"])
    if any(int(v, 16) != 0 for v in got["caps-pump"]):
        bad.append("the log pump keeps capabilities %r" % got["caps-pump"])
    if not any(t.endswith("/kmsg") for t in got["fds-pump"]):
        bad.append("the log pump holds no kmsg descriptor from before its start: %r" % got["fds-pump"])
    return bad


def pump_verdicts(routed, unrouted):
    """return findings for a routed and unrouted log"""
    bad = []
    if routed.count("pipe:[") != 2 or "from-helper" not in routed or "helper-error" not in routed \
            or "from-parent-end" not in routed:
        bad.append("a routed launcher's helper did not get two pipes and reach the log: %r" % routed)
    if "pipe:[" in unrouted:
        bad.append("an unrouted launcher's helper got a pipe: %r" % unrouted)
    return bad


MOUNT_CHILD = """
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
from sandbox import core
with tempfile.TemporaryDirectory() as work:
    run_dir = os.path.join(work, "run")
    os.mkdir(run_dir)
    core.share_run_dir(run_dir)
    core.share_run_dir(run_dir)
    rows = [l.split() for l in open("/proc/self/mountinfo")]
    at_path = [r for r in rows if r[4] == run_dir]
    shared = [r for r in at_path if any(f.startswith("shared:") for f in r[6:])]
    inner = os.path.join(run_dir, "inner")
    os.mkdir(inner)
    core.mount("tmpfs", inner, "tmpfs", 0)
    failed = core.umount_tree(run_dir)
    left = [l for l in open("/proc/self/mountinfo") if run_dir in l]
    print("mounts=%d shared=%d failed=%r left=%d" % (len(at_path), len(shared), failed, len(left)))
"""


def mount_behavior_findings(launcher_dir=None):
    """return findings for the syscall mount helpers"""
    launcher_dir = launcher_dir or os.path.join(REPO, "src", "androidd")
    command = ["unshare", "-Urm", sys.executable, "-I", "-c", MOUNT_CHILD, launcher_dir]
    done = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if done.returncode != 0:
        return ["the mount helpers child exited %d: %s" % (done.returncode, done.stderr.strip()[-200:])]
    if done.stdout.strip().splitlines()[-1] != "mounts=1 shared=1 failed=[] left=0":
        return ["share_run_dir and umount_tree gave %r" % done.stdout.strip()]
    return []


def stacked_bind_findings():
    """return findings when a bind test that stacks mounts is planted"""
    with open(os.path.join(REPO, "src", "androidd", "sandbox", "core.py")) as fh:
        text = fh.read()
    old = "if not is_mount_point(path) and not mount("
    if old not in text:
        return ["sandbox/core.py no longer tests is_mount_point before binding"]
    with tempfile.TemporaryDirectory() as work:
        os.makedirs(os.path.join(work, "sandbox"))
        with open(os.path.join(work, "sandbox/core.py"), "w") as fh:
            fh.write(text.replace(old, "if not os.path.ismount(path) and not mount(", 1))
        got = mount_behavior_findings(work)
    if not any("mounts=2" in g or "mounts=4" in g for g in got):
        return ["a share_run_dir that tests os.path.ismount was not named: %r" % got]
    return []


HOSTOPS_SCRIPT = """
d=$(mktemp -d); mount -t tmpfs t "$d"; cd "$d"
python3 -I "$1" umount "$d" 2>&1; echo "plain=$?"
python3 -I "$1" umount -b "$d" 2>&1; echo "busy=$?"
cd /
python3 -I "$1" umount -b /nonexistent-hostops 2>&1; echo "missing=$?"
"""


def hostops_umount_findings():
    """return findings for the busy-mount unmount"""
    path = os.path.join(REPO, "src", "install", "prepare", "hostops.py")
    done = subprocess.run(["unshare", "-Urm", "bash", "-c", HOSTOPS_SCRIPT, "x", path],
                          capture_output=True, text=True, timeout=60)
    lines = [l for l in done.stdout.splitlines() if "WARNING" not in l]
    if done.returncode != 0 or [l for l in lines if "=" in l and l.split("=")[0] in ("plain", "busy", "missing")] \
            != ["plain=1", "busy=0", "missing=1"]:
        return ["hostops umount gave %r (rc %d)" % (lines, done.returncode)]
    quiet = lines[lines.index("plain=1") + 1:lines.index("busy=0")]
    bad = []
    if quiet:
        bad.append("hostops umount -b printed %r on a busy mount" % quiet)
    if not any("Device or resource busy" in l for l in lines[:lines.index("plain=1")]):
        bad.append("a plain hostops umount did not report the busy mount: %r" % lines)
    if not any("No such file" in l for l in lines[lines.index("busy=0"):]):
        bad.append("hostops umount -b did not report a missing directory: %r" % lines)
    return bad


def pump_checks():
    """return every finding from the child processes"""
    try:
        return (pump_verdicts(pump_findings("route"), pump_findings("none")) + failing_pump_findings()
                + mount_behavior_findings() + hostops_umount_findings())
    except subprocess.CalledProcessError as e:
        return ["a child using the launcher router exited %d" % e.returncode]


def selftest():
    """check the tree passes and planted defects fail"""
    bad = []
    got = scan(tree_files())
    if got:
        bad.append("the tree has findings: %r" % got)
    log_unit = "[Service]\nStandardOutput=append:/var/log/rhizo/x.log\nExecStartPre=%s\n"
    plants = (
        ("a unit helper with a log", "u.service", log_unit % "/bin/sh -c 'mount --rbind /a /a'", "runs a host helper"),
        ("a shell helper redirected to a log", "s.sh", 'modprobe loop >> "$LOG" 2>&1\n', "writes to a log"),
        ("a shell exec redirect to a log", "s.sh", 'exec >> /var/log/rhizo/x.log 2>&1\n', "exec redirects stdio to a log"),
        ("a python helper with a log handle", "p.py",
         "import subprocess\nsubprocess.run(['udevadm', 'settle'], stdout=log_file)\n", "writes to stdout="),
        ("a python system call to a log", "p.py", "import os\nos.system('umount -R /x >> /root/boot.log')\n",
         "writes to a log"),
        ("a dup2 onto stdout", "p.py", "import os\nos.dup2(log_fd, 1)\n", "dup2 onto fd 1"),
        ("a pipe into cat without pipefail", "u.service", log_unit % "/bin/sh -c 'mount --rbind /a /a 2>&1 | cat'",
         "outside bash with set -o pipefail"),
        ("pipefail named by echo", "u.service", log_unit % "/bin/bash -c 'echo pipefail; mount --rbind /a /a 2>&1 | cat'",
         "outside bash with set -o pipefail"),
        ("pipefail under sh", "u.service", log_unit % "/bin/sh -c 'set -o pipefail; mount --rbind /a /a 2>&1 | cat'",
         "outside bash with set -o pipefail"),
        ("pipefail after the helper", "u.service",
         log_unit % "/bin/bash -c 'mount --rbind /a /a 2>&1 | cat; set -o pipefail'", "outside bash with set -o pipefail"),
        ("a helper in the namespace with the pipe", "src/androidd/sandbox/rootfs.py",
         "def child():\n    selinux_ns.drop_to_init_caps()\n", "enters Android's namespace without"),
        ("an init exec with the pipe", LAUNCHER,
         "def enter_sandbox_init():\n    os.execv('/x', [])\nif __name__ == '__main__':\n    route_stdio_through_pipe()\n",
         "execs init without stdio_to_null"),
        ("an unreported init exec failure", LAUNCHER,
         "def enter_sandbox_init():\n    core.stdio_to_null()\n    os.execv('/x', [])\n"
         "if __name__ == '__main__':\n    route_stdio_through_pipe()\n", "is not reported with kmsg"),
        ("a namespace helper in a new module", "src/androidd/sandbox/new.py",
         "def child():\n    selinux_ns.drop_to_init_caps()\n", "enters Android's namespace without"),
        ("a unit mount line", "androidd.service", "[Service]\nExecStartPre=/bin/sh -c 'mount --make-shared /run/x'\n",
         "runs the mount binary"),
        ("a unit mountpoint line", "x.service", "[Service]\nExecStartPre=/usr/bin/mountpoint -q /run/x\n",
         "runs the mount binary"),
        ("an install script umount -l", "src/install/teardown/teardown.sh", "umount -l \"$m\" 2>/dev/null\n",
         "runs the mount binary"),
        ("an install script mount of an image", "src/install/rhizo-new.sh", "mount -o ro,loop \"$IMG\" \"$M\"\n",
         "runs the mount binary"),
        ("an install script mountpoint test", "src/install/rhizo-new.sh", "if mountpoint -q \"$M\"; then :; fi\n",
         "runs the mount binary"),
        ("a launcher umount shell string", "src/androidd/boot.py", "import os\nos.system('umount -R /x')\n",
         "runs the mount binary"),
        ("a launcher mount list", "src/androidd/sandbox/new.py", "import subprocess\nsubprocess.run(['mount', '-a'])\n",
         "runs the mount binary"),
        ("an ismount test", "src/androidd/sandbox/core.py", "import os\nif not os.path.ismount('/x'):\n    pass\n",
         "os.path.ismount is false"),
        ("a discarded rollback", LAUNCHER, "core.umount_tree('/x')\n", "failures umount_tree returns are discarded"),
        ("a main block that does not route", LAUNCHER, "if __name__ == '__main__':\n    main()\n", "does not start with"),
    )
    for name, rel, text, want in plants:
        got = scan({rel: text})
        if not any(want in g for g in got):
            bad.append("%s was not named: %r" % (name, got))
    clean = (
        ("a piped unit helper", "u.service",
         log_unit % "/bin/bash -c 'set -o pipefail; { udevadm settle; } 2>&1 | cat'"),
        ("a shell helper to null", "s.sh", "modprobe loop 2>/dev/null\n"),
        ("a message naming a helper", "s.sh", 'echo "mount failed" >> "$LOG"\n'),
        ("a python helper with captured output", "p.py",
         "import subprocess\nsubprocess.run(['modprobe', 'x'], capture_output=True)\n"),
        ("a reported init exec", LAUNCHER,
         "def enter_sandbox_init():\n    core.stdio_to_null()\n    try:\n        os.execv('/x', [])\n"
         "    except OSError as e:\n        kmsg(str(e))\nif __name__ == '__main__':\n    route_stdio_through_pipe()\n"),
        ("a silenced namespace helper", "src/androidd/sandbox/rootfs.py",
         "def child():\n    core.stdio_to_null()\n    selinux_ns.drop_to_init_caps()\n"),
        ("a mountpoint word in a message", "src/install/rhizo-new.sh", "log \"mount -r failed\"\n"),
        ("a hostops mount", "src/install/rhizo-new.sh", "hostops mount -r -t ext4 \"$L\" \"$M\"\nhostops is-mount \"$M\"\n"),
        ("the selinuxfs mount", "src/install/bootstrap/bootstrap.sh", "mount -t selinuxfs selinuxfs \"$D\"\n"),
        ("a development script", "src/install/prepare/derive-patches.sh", "sudo mount -o ro,loop \"$IMG\" \"$M\"\n"),
        ("a branched rollback", LAUNCHER,
         "left = core.umount_tree('/x')\nif __name__ == '__main__':\n    route_stdio_through_pipe()\n"),
        ("a routed main block", LAUNCHER, "if __name__ == '__main__':\n    route_stdio_through_pipe()\n    main()\n"),
    )
    for name, rel, text in clean:
        got = scan({rel: text})
        if got:
            bad.append("%s was flagged: %r" % (name, got))
    bad += pump_checks()
    bad += stacked_bind_findings()
    return bad


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        bad = selftest()
    else:
        bad = scan(tree_files()) + pump_checks()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
