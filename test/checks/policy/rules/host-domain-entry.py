#!/usr/bin/env python3
import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
ROOT = os.environ.get("RHIZO_DOMAIN_CHECK_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

SRC = os.path.join(ROOT, "src", "services", "inputd", "inputd.c")
FUSE_WIRE = os.path.join(ROOT, "src", "services", "fuse-wire", "fuse_wire.h")
POLICY = os.path.join(ROOT, "src", "androidd", "guest", "sepolicy", "policy.cil")
DEBIAN_RULES = os.path.join(ROOT, "debian", "rules")
DROPIN_DIR = os.path.join(ROOT, "debian", "dropins")
UDEV_RULE = os.path.join(ROOT, "src", "services", "udev", "70-uinput.rules")
BINARY = "/usr/lib/rhizo/rhizo-inputd"

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-host-domain-entry")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_labels  # noqa: E402

CONFINED = {"rhizo-inputd@.service": ("supervise", "u:r:rhizo_inputd:s0"),
            "rhizo-inputd-uhid@.service": ("uhid", "u:r:rhizo_uhidd:s0")}
SOCKET_TYPE = "rhizo_input_socket"
CONNECTORS = ("kernel", "rhizo_host", "rhizo_uhidd")

REQUIRED = [
    ("rhizo_host", "rhizo_inputd", "process", "transition", "enter_domain's execv from rhizo_host"),
    ("rhizo_host", "rhizo_inputd", "process2", "nnp_transition", "the unit's NoNewPrivileges=yes"),
    ("rhizo_host", "rhizo_inputd", "process", "siginh rlimitinh", "the unit's signal state and limits kept"),
    ("rhizo_inputd", "rhizo_host_exec", "file", "entrypoint read execute map open getattr",
     "the daemon's label (HOST_EXEC_PACKAGED) and the ELF loader"),
    ("rhizo_inputd", "unlabeled", "file", "read execute map open getattr", "libc, ld.so.cache"),
    ("rhizo_inputd", "selinuxfs", "dir", "search getattr", "enter_domain's stat of /sys/fs/selinux"),
    ("rhizo_inputd", "proc", "dir", "search", "/proc/self"),
    ("rhizo_inputd", "proc", "lnk_file", "read", "the /proc/self link"),
    ("rhizo_inputd", "self", "dir", "search", "/proc/self/attr, /proc/self/fdinfo"),
    ("rhizo_inputd", "self", "file", "open read getattr", "attr/current, fdinfo (pidfd_pid)"),
    ("rhizo_inputd", "device", "dir", "search", "the lookup of /dev/cuse"),
    ("rhizo_inputd", "rhizo_cuse_host_device", "chr_file", "open read write getattr", "cuse_open_init"),
    ("rhizo_inputd", "self", "capability", "sys_ptrace", "pidfd_getfd"),
    ("rhizo_inputd", "rhizo_composer", "process", "ptrace", "pidfd_getfd on the composer"),
    ("rhizo_inputd", "system_server", "process", "ptrace", "pidfd_getfd on system_server"),
    ("rhizo_inputd", "shell", "process", "ptrace", "pidfd_getfd on the uinput command"),
    ("rhizo_inputd", "rhizo_composer", "fd", "use", "the composer's /dev/uinput fd"),
    ("rhizo_inputd", "rhizo_composer", "dir", "search", "tgid_of's /proc/<tid> of the notified thread"),
    ("rhizo_inputd", "rhizo_composer", "file", "open read", "tgid_of's /proc/<tid>/status"),
    ("rhizo_inputd", "system_server", "dir", "search", "tgid_of's /proc/<tid> of the notified thread"),
    ("rhizo_inputd", "system_server", "file", "open read", "tgid_of's /proc/<tid>/status"),
    ("rhizo_inputd", "shell", "dir", "search", "tgid_of's /proc/<tid> of the notified thread"),
    ("rhizo_inputd", "shell", "file", "open read", "tgid_of's /proc/<tid>/status"),
    ("rhizo_inputd", "uhid_device", "chr_file", "read write ioctl getattr", "UI_DEV_CREATE, UI_GET_SYSNAME, fstat"),
    ("rhizo_inputd", "kernel", "fd", "use", "the launcher's seccomp listener"),
    ("rhizo_inputd", "self", "netlink_kobject_uevent_socket", "create bind read setopt", "uevent_socket"),
    ("rhizo_inputd", "self", "unix_stream_socket", "create bind listen accept connect read write getopt",
     "unix_listen, the fence connection, SO_PEERCRED/SO_PEERPIDFD"),
    ("rhizo_inputd", "self", "unix_dgram_socket", "create write", "sd_notify_fd"),
    ("rhizo_inputd", "kernel", "unix_dgram_socket", "sendto", "READY=1 and FDSTORE to pid 1"),
    ("rhizo_inputd", "kernel", "unix_stream_socket", "connectto", "the fence's registry bound by g"),
    ("rhizo_inputd", "tmpfs", "sock_file", "write getattr unlink", "the fence socket, notify, an old supervisor.sock"),
    ("rhizo_inputd", "tmpfs", "dir", "search write add_name remove_name", "its RuntimeDirectory and /run/udev"),
    ("rhizo_inputd", "tmpfs", "file", "create open read write rename unlink getattr", "save_state, load_state"),
    ("rhizo_inputd", SOCKET_TYPE, "sock_file", "create unlink setattr getattr", "unix_listen's unlink, bind, chmod"),
    ("rhizo_inputd", "sysfs", "dir", "search getattr", "load_state's stat of each owned device"),
    ("rhizo_inputd", "sysfs_uhid", "file", "open read", "owned_now's read of a hid device's uevent"),
    ("rhizo_inputd", "rhizo_uhidd", "file", "open read", "peer_is_broker's /proc/<pid>/cgroup"),
    ("rhizo_inputd", "rhizo_uhidd", "dir", "search", "/proc/<broker pid>"),
    ("rhizo_host", "rhizo_uhidd", "process", "transition", "enter_domain's execv from rhizo_host"),
    ("rhizo_host", "rhizo_uhidd", "process2", "nnp_transition", "the unit's NoNewPrivileges=yes"),
    ("rhizo_host", "rhizo_uhidd", "process", "siginh rlimitinh", "the unit's signal state and limits kept"),
    ("rhizo_uhidd", "rhizo_host_exec", "file", "entrypoint read execute map open getattr",
     "the daemon's label and the ELF loader"),
    ("rhizo_uhidd", "unlabeled", "file", "read execute map open getattr", "libc, ld.so.cache"),
    ("rhizo_uhidd", "sysfs", "dir", "search", "the lookup of /sys/fs/selinux"),
    ("rhizo_uhidd", "selinuxfs", "dir", "search getattr", "enter_domain's stat of /sys/fs/selinux"),
    ("rhizo_uhidd", "proc", "dir", "search", "/proc/self"),
    ("rhizo_uhidd", "proc", "lnk_file", "read", "the /proc/self link"),
    ("rhizo_uhidd", "self", "dir", "search", "/proc/self/attr"),
    ("rhizo_uhidd", "self", "file", "open read getattr", "attr/current"),
    ("rhizo_uhidd", "device", "dir", "search", "the lookup of /dev/uhid"),
    ("rhizo_uhidd", "rhizo_uhid_host_device", "chr_file", "open read write getattr", "open_uhid, stat"),
    ("rhizo_uhidd", "rhizo_cuse_host_device", "chr_file", "read write getattr", "the CUSE channel it takes"),
    ("rhizo_uhidd", "rhizo_inputd", "fd", "use", "the CUSE fd the supervisor passes"),
    ("rhizo_uhidd", "self", "unix_stream_socket", "create connect read write", "unix_connect to the supervisor"),
    ("rhizo_uhidd", "tmpfs", "dir", "search", "/run/rhizo-input-N"),
]
for _d in CONNECTORS:
    REQUIRED.append((_d, SOCKET_TYPE, "sock_file", "write getattr", "connect(supervisor.sock)"))
    REQUIRED.append((_d, "rhizo_inputd", "unix_stream_socket", "connectto", "connect(supervisor.sock)"))
REQUIRED += [
    ("rhizo_host", "unlabeled", "file", "execute execute_no_trans getattr open read map",
     "udev runs the rule's PROGRAM, which host mode leaves unlabeled"),
    ("rhizo_host", SOCKET_TYPE, "sock_file", "write getattr", "the udev helper's connect(/run/udev/rhizo-input-N.sock)"),
    ("rhizo_host", "rhizo_inputd", "unix_stream_socket", "connectto",
     "the udev helper's connect(/run/udev/rhizo-input-N.sock)"),
]
for _t in ("rhizo_inputd", "rhizo_uhidd"):
    REQUIRED += [
        ("rhizo_host", _t, "process", "noatsecure", "the transition's AT_SECURE check"),
        (_t, "null_device", "chr_file", "read write open", "a refused inherited fd swapped for selinuxfs null"),
    ]
INCOMING_SOURCES = ("rhizo_host", "kernel")
INCOMING = [
    ("process", "sigkill sigstop signull signal", "stop, kill and liveness probes, kill(2) or pidfd_send_signal"),
    ("process", "getattr getpgid getsession", "/proc/<pid>/attr, getpgid, getsid"),
    ("dir", "search getattr open read", "/proc/<pid> and its fd, task and attr directories"),
    ("file", "open read getattr ioctl", "/proc/<pid>/{stat,status,cgroup,comm,cmdline,environ,attr/*}"),
    ("lnk_file", "read getattr", "/proc/<pid>/{exe,cwd,fd/*}"),
    ("unix_stream_socket", "getattr", "fuser and ss stat each socket in /proc/<pid>/fd"),
    ("unix_dgram_socket", "getattr", "fuser and ss stat each socket in /proc/<pid>/fd"),
    ("netlink_kobject_uevent_socket", "getattr", "fuser stat of the supervisor's uevent socket"),
]
for _t in ("rhizo_inputd", "rhizo_uhidd"):
    for _src in INCOMING_SOURCES:
        for _cls, _perms, _why in INCOMING:
            REQUIRED.append((_src, _t, _cls, _perms, "incoming: " + _why))
        REQUIRED.append((_t, _src, "process", "sigchld", "incoming: its parent reaping it"))


def say(msg):
    """print a message prefixed with the check name to stderr"""
    print("check-host-domain-entry: %s" % msg, file=sys.stderr)


def setting(text, key):
    """return the last value for a unit key"""
    vals = re.findall(r"^\s*%s=(.*)$" % re.escape(key), text, re.M)
    return vals[-1].strip() if vals else None


def check_units(units, dropins):
    """check the rhizo-inputd unit files"""
    bad = []
    texts = sorted(units.items()) + [("%s (drop-in %s)" % (u, f), t)
                                     for u, ds in sorted(dropins.items()) for f, t in ds]
    for name, text in texts:
        if re.search(r"^\s*SELinuxContext=", text, re.M):
            bad.append("unit: %s sets SELinuxContext=" % name)
    for name, (mode, ctx) in CONFINED.items():
        if name not in units:
            bad.append("unit: %s is gone, so nothing runs %s" % (name, ctx))
            continue
        full = units[name] + "".join("\n" + t for _f, t in dropins.get(name, ()))
        m = re.search(r"^ExecStart=(\S+) (\S+)", units[name], re.M)
        if not m or (m.group(1), m.group(2)) != (BINARY, mode):
            bad.append("unit: %s's ExecStart is not %s %s, the mode that enters %s"
                       % (name, BINARY, mode, ctx))
        for f, t in dropins.get(name, ()):
            if re.search(r"^\s*ExecStart=", t, re.M):
                bad.append("unit: drop-in %s replaces %s's ExecStart" % (f, name))
        if setting(full, "Restart") != "on-failure" or setting(full, "StartLimitIntervalSec") != "0":
            bad.append("unit: %s does not restart without a limit (Restart=%s, StartLimitIntervalSec=%s)"
                       % (name, setting(full, "Restart"), setting(full, "StartLimitIntervalSec")))
    return bad


def read_units(root=ROOT):
    """map each .service name to its text"""
    return {n: open(os.path.join(root, rel)).read() for n, rel in unit_files.unit_files(root, (".service",)).items()}


DROPIN_INSTALL_RE = re.compile(r"install -D -m \d+ debian/dropins/(\S+)\s*\\?\s*\"?\$\(UNITS\)/([^/\"]+)\.d/")


def read_dropins(rules=DEBIAN_RULES, dropin_dir=DROPIN_DIR):
    """read the drop-ins debian/rules installs"""
    out = {}
    for f, unit in DROPIN_INSTALL_RE.findall(open(rules).read()):
        out.setdefault(re.sub(r"@[^.]+\.", "@.", unit), []).append((f, open(os.path.join(dropin_dir, f)).read()))
    return out


def build(src_text, tmp):
    """build rhizo-inputd from source text"""
    d = os.path.join(tmp, "host")
    os.makedirs(os.path.join(d, "rhizo-inputd"))
    os.makedirs(os.path.join(d, "fuse-wire"))
    src = os.path.join(d, "rhizo-inputd", "inputd.c")
    with open(src, "w") as f:
        f.write(src_text)
    with open(os.path.join(d, "fuse-wire", "fuse_wire.h"), "w") as f:
        f.write(open(FUSE_WIRE).read())
    out = os.path.join(tmp, "rhizo-inputd")
    r = subprocess.run(["gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-o", out, src],
                       capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError("build failed: %s" % r.stderr.strip()[:400])
    return out


TIMED_OUT = "<timed out>"
AFTER = {"supervise": "reason=uevent-socket:", "uhid": "reason=supervisor:"}


def mode_argv(binary, mode, tmp):
    """return the command line that runs a binary in a mode"""
    if mode == "supervise":
        return [binary, "supervise", "--instance", "0", "--socket", os.path.join(tmp, "no", "s.sock"),
                "--uevents", os.path.join(tmp, "no-uevents")]
    return [binary, "uhid", "--instance", "0", "--supervisor", os.path.join(tmp, "no", "s.sock")]


def entry_case(binary, mode, tmp, case):
    """run rhizo-inputd against a fixture attr directory"""
    attr = os.path.join(tmp, "attr-" + case)
    fs = os.path.join(tmp, "selinuxfs")
    os.makedirs(attr)
    os.makedirs(fs, exist_ok=True)
    shut = os.path.join(tmp, "shut")
    os.makedirs(os.path.join(shut, "selinux"), exist_ok=True)
    os.chmod(shut, 0o600)
    exec_path = os.path.join(attr, "exec")
    if case == "unwritable":
        os.makedirs(exec_path)
    else:
        open(exec_path, "w").close()
    cur = os.path.join(attr, "current")
    if case == "entered":
        os.symlink("exec", cur)
    else:
        with open(cur, "w") as f:
            f.write({"kernel": "kernel\0", "namespace": "kernel\0",
                     "kernel-labeled": "u:r:kernel:s0\0"}.get(case, "u:r:rhizo_host:s0\0"))
    mode_file = os.path.join(attr, "selinux-mode")
    mode_text = {"namespace": "namespace\n", "mode-missing": None, "mode-garbled": "permissive\n",
                 "mode-trailing": "namespace junk\n"}.get(case, "host\n")
    if mode_text is not None:
        with open(mode_file, "w") as f:
            f.write(mode_text)
    selinuxfs = {"no-selinux": os.path.join(tmp, "absent"),
                 "selinuxfs-refused": os.path.join(shut, "selinux")}.get(case, fs)
    argv = mode_argv(binary, mode, tmp) + ["--attr", attr, "--selinuxfs", selinuxfs]
    env = {k: v for k, v in os.environ.items() if k != "RHIZO_INPUTD_ENTERING"}
    env["RHIZO_SELINUX_MODE_FILE"] = mode_file
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=10, env=env)
        err, rc = r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        err, rc = TIMED_OUT, -1
    got = open(exec_path).read() if os.path.isfile(exec_path) else None
    os.chmod(shut, 0o700)
    return err, rc, got


def check_entry(binary, tmp):
    """check each mode enters its type"""
    bad = []
    for name, (mode, ctx) in sorted(CONFINED.items()):
        after = AFTER[mode]
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-host"), "host")
        if got != ctx:
            bad.append("entry: %s from rhizo_host wrote %r to attr/exec, not %s" % (mode, got, ctx))
        if err == TIMED_OUT:
            bad.append("entry: %s re-executed without end from rhizo_host, never refusing" % mode)
        elif after in err or rc == 0:
            bad.append("entry: %s ran on (rc %d) after its re-exec left it in rhizo_host" % (mode, rc))
        elif "reason=domain-refused" not in err:
            bad.append("entry: %s left in rhizo_host exited without RHIZO_MARKER ... reason=domain-refused: %s"
                       % (mode, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-entered"), "entered")
        if "input_owner=domain entered=%s" % ctx not in err or after not in err:
            bad.append("entry: %s whose re-exec entered %s did not say so and run on: %s"
                       % (mode, ctx, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-kernel"), "kernel")
        if "state=deferred" not in err or after not in err or got:
            bad.append("entry: %s as `kernel` did not defer to the primer's restart and run on "
                       "(attr/exec %r): %s" % (mode, got, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-namespace"), "namespace")
        if "state=no-selinux mode=namespace" not in err or after not in err or got:
            bad.append("entry: %s as `kernel` in SELinux namespace mode did not run on with no SELinux "
                       "(attr/exec %r): %s" % (mode, got, err.strip()[-300:]))
        for case, label in (("mode-missing", "a missing mode file"), ("mode-garbled", "a mode file holding neither mode"),
                            ("mode-trailing", "a mode file with text after the mode")):
            err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-" + case), case)
            if "reason=selinux-mode" not in err or after in err or rc != 78 or got:
                bad.append("entry: %s with %s did not refuse to start by name with exit 78 (rc %d, attr/exec %r): %s"
                           % (mode, label, rc, got, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-none"), "no-selinux")
        if "state=no-selinux" not in err or after not in err:
            bad.append("entry: %s with no SELinux did not say so and run on: %s" % (mode, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-shut"), "selinuxfs-refused")
        if "reason=domain-selinuxfs:13" not in err or after in err or rc == 0:
            bad.append("entry: %s whose stat of selinuxfs was refused EACCES did not exit loudly "
                       "(rc %d): %s" % (mode, rc, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-klabel"), "kernel-labeled")
        if "reason=domain-kernel" not in err or after in err or rc == 0:
            bad.append("entry: %s as u:r:kernel:s0 did not exit for Restart= "
                       "(rc %d): %s" % (mode, rc, err.strip()[-300:]))
        err, rc, got = entry_case(binary, mode, os.path.join(tmp, mode + "-unwritable"), "unwritable")
        if "reason=domain-setexec" not in err or after in err or rc == 0:
            bad.append("entry: %s whose attr/exec write failed did not exit loudly (rc %d): %s"
                       % (mode, rc, err.strip()[-300:]))
    if BINARY not in selinux_labels.HOST_EXEC_PACKAGED:
        bad.append("entry: %s is not in HOST_EXEC_PACKAGED" % BINARY)
    return bad


def check_udev_helper(rule_text):
    """check the udev helper keeps its packaged label"""
    m = re.search(r'^PROGRAM=="(\S+)', rule_text, re.M)
    if not m:
        return ["udev: 70-rhizo-uinput.rules names no PROGRAM"]
    if m.group(1) in selinux_labels.HOST_EXEC_PACKAGED:
        return ["udev: the helper %s is in HOST_EXEC_PACKAGED" % m.group(1)]
    return []


ALLOW_RE = re.compile(r"\(allow (\S+) (\S+) \((\S+) \(([^()]*)\)\)\)")
TT_RE = re.compile(r"\(typetransition (\S+) (\S+) (\S+) (?:\"[^\"]*\" )?(\S+)\)")


def strip_comments(text):
    """return the text without semicolon comments"""
    return "\n".join(line.split(";", 1)[0] for line in text.splitlines())


def granted(text):
    """return the allow rules in the policy text"""
    out = {}
    for m in ALLOW_RE.finditer(" ".join(strip_comments(text).split())):
        src, tgt, cls, perms = m.groups()
        tgt = src if tgt == "self" else tgt
        out.setdefault((src, tgt, cls), set()).update(perms.split())
    return out


def check_policy(text):
    """check the policy holds every REQUIRED rule"""
    bad = []
    g = granted(text)
    flat = " ".join(strip_comments(text).split())
    for src, tgt, cls, perms, why in REQUIRED:
        tgt = src if tgt == "self" else tgt
        missing = set(perms.split()) - g.get((src, tgt, cls), set())
        if missing:
            bad.append("policy: %s lacks %s on %s %s (%s)" % (src, " ".join(sorted(missing)), tgt, cls, why))
    tts = [m.groups() for m in TT_RE.finditer(flat)]
    if ("rhizo_inputd", "tmpfs", "sock_file", SOCKET_TYPE) not in tts:
        bad.append("policy: no (typetransition rhizo_inputd tmpfs sock_file %s)" % SOCKET_TYPE)
    if not re.search(r"\(typeattributeset file_type \([^)]*\b%s\b" % SOCKET_TYPE, flat):
        bad.append("policy: %s is no file_type" % SOCKET_TYPE)
    return bad


def run():
    """run the unit, policy and entry checks and print the problems"""
    bad = check_units(read_units(), read_dropins()) + check_policy(open(POLICY).read())
    bad += check_udev_helper(open(UDEV_RULE).read())
    with tempfile.TemporaryDirectory() as t:
        bad += check_entry(build(open(SRC).read(), os.path.join(t, "b")), t)
    for b in bad:
        say(b)
    if bad:
        return 1
    print("check-host-domain-entry: ok -- rhizo-inputd enters rhizo_inputd and rhizo_uhidd itself, no unit "
          "leans on SELinuxContext=, and the policy holds all %d rules the daemons' calls need" % len(REQUIRED))
    return 0


SRC_MUTATIONS = (
    ("no-entry-supervise", '\t\tenter_domain("u:r:rhizo_inputd:s0", argv);\n', "",
     "supervise from rhizo_host wrote"),
    ("no-entry-uhid", '\t\tenter_domain("u:r:rhizo_uhidd:s0", argv);\n', "",
     "uhid from rhizo_host wrote"),
    ("loops-on-refused", "\tif (getenv(ENTERING_ENV)) {\n", "\tif (0) {\n", "re-executed without end"),
    ("runs-on-refused", '\t\trz_log("RHIZO_MARKER input_owner=failed reason=domain-refused current=%s want=%s", cur, ctx);\n\t\texit(1);\n',
     '\t\treturn;\n', "ran on"),
    ("setexec-ignored", '\t\trz_log("RHIZO_MARKER input_owner=failed reason=domain-setexec:%d current=%s want=%s", errno, cur, ctx);\n\t\texit(1);\n',
     '\t\trz_log("RHIZO_MARKER input_owner=failed reason=domain-setexec:%d current=%s want=%s", errno, cur, ctx);\n\t\treturn;\n',
     "did not exit loudly"),
    ("kernel-refused", '\tif (!strcmp(cur, "kernel")) {\n', "\tif (0) {\n", "did not defer"),
    ("kernel-labeled-deferred", '\tif (!strcmp(cur, "kernel")) {\n',
     '\tif (!strcmp(cur, "kernel") || !strcmp(cur, "u:r:kernel:s0")) {\n', "as u:r:kernel:s0 did not exit"),
    ("stat-any-error", "\t\tif (errno != ENOENT) {\n", "\t\tif (0) {\n", "refused EACCES did not exit loudly"),
    ("namespace-read-as-host", "\tif (ns) {\n", "\tif (ns && 0) {\n", "in SELinux namespace mode did not run on"),
    ("unreadable-mode-read-as-host", "\tif (ns < 0)\n\t\texit(SELINUX_MODE_EXIT);\n", "\tif (ns < 0)\n\t\tns = 0;\n",
     "did not refuse to start by name"),
)


def selftest():
    """check each planted-defect input against its finding"""
    fails = []

    def expect(label, findings, needle):
        """check the findings contain the needle"""
        if needle is None:
            if findings:
                fails.append("%s: flagged a correct input: %s" % (label, findings[0]))
        elif not any(needle in f for f in findings):
            fails.append("%s: did not flag %r (got %s)" % (label, needle, findings or "nothing"))

    units, dropins = read_units(), read_dropins()
    if "inputd-instance0.conf" not in [f for f, _t in dropins.get("rhizo-inputd@.service", ())]:
        fails.append("units/dropins: debian/rules' inputd-instance0.conf drop-in was not read")
    expect("units/good", check_units(units, dropins), None)
    expect("units/selinuxcontext", check_units(dict(units, **{"rhizo-inputd@.service": units[
        "rhizo-inputd@.service"] + "SELinuxContext=-u:r:rhizo_inputd:s0\n"}), dropins), "sets SELinuxContext=")
    expect("units/wrong-mode", check_units(dict(units, **{"rhizo-inputd-uhid@.service": units[
        "rhizo-inputd-uhid@.service"].replace(" uhid --instance", " supervise --instance")}), dropins),
        "ExecStart is not /usr/lib/rhizo/rhizo-inputd uhid")
    bad_drop = dict(dropins, **{"rhizo-inputd@.service": dropins["rhizo-inputd@.service"] + [
        ("x.conf", "[Service]\nSELinuxContext=u:r:rhizo_inputd:s0\nExecStart=\nExecStart=/bin/true\n")]})
    expect("units/dropin-context", check_units(units, bad_drop), "(drop-in x.conf) sets SELinuxContext=")
    expect("units/dropin-execstart", check_units(units, bad_drop), "drop-in x.conf replaces")
    expect("units/start-limit", check_units(dict(units, **{"rhizo-inputd@.service": units[
        "rhizo-inputd@.service"].replace("StartLimitIntervalSec=0\n", "")}), dropins),
        "does not restart without a limit")
    expect("units/dropin-limit", check_units(units, dict(dropins, **{"rhizo-inputd-uhid@.service": dropins.get(
        "rhizo-inputd-uhid@.service", []) + [("y.conf", "[Unit]\nStartLimitIntervalSec=10\n")]})),
        "does not restart without a limit")

    policy = open(POLICY).read()
    expect("policy/good", check_policy(policy), None)
    expect("policy/no-type", check_policy(policy.replace("(typetransition rhizo_inputd tmpfs sock_file %s)"
                                                         % SOCKET_TYPE, "")), "no (typetransition")
    expect("policy/kernel-no-write", check_policy(policy.replace(
        "(allow kernel %s (sock_file (write getattr)))" % SOCKET_TYPE, "")),
        "kernel lacks getattr write on %s sock_file" % SOCKET_TYPE)
    expect("policy/commented", check_policy(policy.replace(
        "(allow kernel %s (sock_file (write getattr)))" % SOCKET_TYPE,
        "; (allow kernel %s (sock_file (write getattr)))" % SOCKET_TYPE)), "kernel lacks")
    expect("policy/no-device-search", check_policy(policy.replace(
        "(allow rhizo_uhidd device (dir (search getattr)))", "")), "rhizo_uhidd lacks search on device dir")
    expect("policy/udev-helper-exec", check_policy(policy.replace(
        "(allow rhizo_host unlabeled (file (execute execute_no_trans)))", "")),
        "rhizo_host lacks execute execute_no_trans on unlabeled file (udev runs")
    expect("policy/udev-socket-write", check_policy(policy.replace(
        "(allow rhizo_host %s (sock_file (write getattr unlink)))" % SOCKET_TYPE, "")),
        "rhizo_host lacks getattr write on %s sock_file (the udev helper's" % SOCKET_TYPE)
    expect("policy/udev-connectto", check_policy(policy.replace(
        "(allow rhizo_host rhizo_inputd (unix_stream_socket (connectto)))", "")),
        "rhizo_host lacks connectto on rhizo_inputd unix_stream_socket (the udev helper's")
    rule = open(UDEV_RULE).read()
    expect("udev/good", check_udev_helper(rule), None)
    expect("udev/packaged-helper", check_udev_helper(re.sub(r'PROGRAM=="\S+', 'PROGRAM=="%s' % BINARY, rule)),
           "is in HOST_EXEC_PACKAGED")
    expect("udev/no-program", check_udev_helper(re.sub(r"^PROGRAM==.*$", "", rule, flags=re.M)), "names no PROGRAM")
    expect("policy/incoming-kill", check_policy(policy.replace("sigkill sigstop signull signal", "signull signal")),
           "lacks sigkill sigstop on rhizo_inputd process (incoming:")

    src = open(SRC).read()
    with tempfile.TemporaryDirectory() as t:
        expect("entry/good", check_entry(build(src, os.path.join(t, "good")), t), None)
        for name, old, new, needle in SRC_MUTATIONS:
            if src.count(old) != 1:
                fails.append("entry/%s: the mutation no longer applies to inputd.c" % name)
                continue
            with tempfile.TemporaryDirectory() as m:
                expect("entry/%s" % name, check_entry(build(src.replace(old, new), os.path.join(m, "b")), m),
                       needle)
    for f in fails:
        say("selftest: " + f)
    if fails:
        return 1
    print("check-host-domain-entry: selftest ok")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    return run()


if __name__ == "__main__":
    sys.exit(main())
