#!/usr/bin/env python3
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rhizo_hostfs", os.path.join(HERE, "..", "hostfs.py"))
hostfs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hostfs)

failures = []


def check(name, got, want):
    """print ok or FAIL for a comparison"""
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s: got %r, want %r" % (name, got, want))
        failures.append(name)


def labeled(mode, existing, refuse=None, current=None):
    """run the mount point step"""
    calls = []

    def stub(path, label, got_mode):
        """record a label call and return the refusal, if any"""
        calls.append((path, label, got_mode))
        return refuse

    saved, saved_read = hostfs.label_android_file, hostfs.read_label
    hostfs.label_android_file = stub
    hostfs.read_label = lambda path: current
    try:
        with tempfile.TemporaryDirectory() as tmp:
            lower = os.path.join(tmp, "Download")
            if existing:
                os.mkdir(lower)
            lines = []
            ok = hostfs.prepare_mount_point("Download", lower, mode, lines)
            return ok, [(os.path.basename(p), lb, m) for p, lb, m in calls], lines, os.path.isdir(lower)
    finally:
        hostfs.label_android_file, hostfs.read_label = saved, saved_read


want = [("Download", b"u:object_r:media_rw_data_file:s0", "namespace")]
ok, calls, lines, kept = labeled("namespace", False)
check("a new mount point is created and labeled", (ok, calls, kept), (True, want, True))
ok, calls, lines, kept = labeled("namespace", True)
check("a mount point an earlier attach left is labeled too", (ok, calls, kept), (True, want, True))
ok, calls, lines, kept = labeled("namespace", True, refuse="not owner",
                                 current=b"u:object_r:media_rw_data_file:s0:c104,c256,c512,c768")
check("a left one carrying android's media_rw_data_file is not relabeled", (ok, calls, kept), (True, [], True))
ok, calls, lines, kept = labeled("namespace", True, current=b"system_u:object_r:unlabeled_t:s0")
check("a left one with another label is labeled", (ok, calls), (True, want))
ok, calls, lines, kept = labeled("namespace", True, refuse="no xattr")
check("a refused label on a left one fails the step and keeps the directory", (ok, kept), (False, True))
check("and the log names the label", any("cannot label" in x and "no xattr" in x for x in lines), True)
ok, calls, lines, kept = labeled("namespace", False, refuse="no xattr")
check("a refused label on a new one removes it", (ok, kept), (False, False))
with tempfile.TemporaryDirectory() as tmp:
    attr = os.path.join(tmp, "current")
    for ctx, want in (("system_u:system_r:initrc_t:s0\0", True), ("kernel\0", False)):
        with open(attr, "w") as f:
            f.write(ctx)
        check("host_policy_loaded reads %r as %s" % (ctx.strip(chr(0)), want), hostfs.host_policy_loaded(attr), want)
    check("host_policy_loaded reads no attr file as no policy", hostfs.host_policy_loaded(os.path.join(tmp, "none")), False)


class Ran:
    """Result of a fake subprocess run"""

    def __init__(self, rc, out, err=""):
        """store the exit status and output"""
        self.returncode, self.stdout, self.stderr = rc, out, err


seen = []
ok, log = hostfs.label_in_policy_namespace(42, "Download", "/data/media/0/Download",
                                           run=lambda argv, **kw: seen.append(argv) or Ran(0, '{"ok": true, "log": ["kept"]}\n'))
check("the policy-namespace label runs launcher3 in-android-policy with label-lower",
      (ok, log, seen[0][1:3], seen[0][-7:]),
      (True, ["kept"], [hostfs.LAUNCHER3, "in-android-policy"],
       ["label-lower", "--init-pid", "42", "--name", "Download", "--path", "/data/media/0/Download"]))
ok, log = hostfs.label_in_policy_namespace(42, "Download", "/data/media/0/Download",
                                           run=lambda argv, **kw: Ran(1, "IN_ANDROID_POLICY_FAILED reason=no-compiled-policy\n"))
check("a failed policy namespace fails the label by name", (ok, "no-compiled-policy" in log[0]), (False, True))


def hang(argv, **kw):
    """raise the timeout a hung label run raises"""
    raise subprocess.TimeoutExpired(argv, kw.get("timeout"))


for label, fake in (("a hung label run", hang), ("a missing launcher3", lambda argv, **kw: open("/nonexistent/launcher3.py"))):
    try:
        ok, log = hostfs.label_in_policy_namespace(42, "Download", "/data/media/0/Download", run=fake)
        got = (ok, "Download" in log[0])
    except Exception as e:
        got = ("raised", type(e).__name__)
    check("%s fails the label by name" % label, got, (False, True))

saved = hostfs.enter_sandbox_ns, hostfs.read_label, hostfs.label_android_file, hostfs.LOWER_ROOT
calls = []
hostfs.enter_sandbox_ns = lambda pid: None
hostfs.read_label = lambda path: b"u:object_r:media_rw_data_file:s0:c104,c256,c512,c768"
hostfs.label_android_file = lambda *a: calls.append(a)
try:
    import contextlib, io, types
    with tempfile.TemporaryDirectory() as tmp:
        hostfs.LOWER_ROOT = tmp
        lower = os.path.join(tmp, "Download")
        os.mkdir(lower)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = hostfs.cmd_label_lower(types.SimpleNamespace(init_pid=42, name="Download", path=lower))
        check("label-lower keeps android's own media_rw_data_file label", (rc, calls, '"ok": true' in out.getvalue()), (0, [], True))
        for label, name, path in (("a path outside the lower root", "Download", "/etc"),
                                  ("a path naming another share", "Download", os.path.join(tmp, "Music")),
                                  ("a share name with a slash", "a/b", os.path.join(tmp, "a/b")),
                                  ("a share name starting with a dot", "..", os.path.join(tmp, ".."))):
            joined = []
            hostfs.enter_sandbox_ns = lambda pid: joined.append(pid)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = hostfs.cmd_label_lower(types.SimpleNamespace(init_pid=42, name=name, path=path))
            check("label-lower refuses %s before joining the sandbox" % label, (rc, joined, '"ok": false' in out.getvalue()),
                  (2, [], True))
        hostfs.enter_sandbox_ns = lambda pid: "setns(CLONE_NEWNS): EPERM"
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = hostfs.cmd_label_lower(types.SimpleNamespace(init_pid=42, name="Download", path=lower))
        check("label-lower fails by name when it cannot join the sandbox", (rc, "EPERM" in out.getvalue()), (1, True))
finally:
    hostfs.enter_sandbox_ns, hostfs.read_label, hostfs.label_android_file, hostfs.LOWER_ROOT = saved


def unreadable_attr(path):
    """raise the error an unreadable attr file raises"""
    raise PermissionError(13, "Permission denied", path)


with tempfile.TemporaryDirectory() as tmp:
    blocked = os.path.join(tmp, "blocked")
    os.mkdir(blocked)
    try:
        got = hostfs.host_policy_loaded(blocked)
    except OSError as e:
        got = type(e).__name__
    check("host_policy_loaded fails by name on an attr file it cannot read", got in ("IsADirectoryError", "PermissionError"), True)


class FakeLibc:
    """Mount calls recorded in place of libc"""

    def __init__(self):
        """start with no calls"""
        self.calls = []

    def mount(self, *a):
        """record a mount"""
        self.calls.append(("mount",) + a)
        return 0

    def umount2(self, *a):
        """record an unmount"""
        self.calls.append(("umount2",) + a)
        return 0


def attach_with(policy_loaded):
    """run attach_one with fakes"""
    names = ("resolve_owner", "_as_user", "read_selinux_mode", "sandbox_mount_line", "open_fuse", "host_policy_loaded",
             "label_in_policy_namespace", "_in_sandbox", "prepare_mount_point", "start_daemon", "libc", "LOWER_ROOT",
             "OVER_ROOT")
    saved = {n: getattr(hostfs, n, None) for n in names}
    seen = []
    with tempfile.TemporaryDirectory() as tmp:
        os.mkdir(os.path.join(tmp, "Download"))
        fake = {
            "resolve_owner": lambda d, u: (1000, 1000, None),
            "_as_user": lambda uid, gid, fn: {"ok": fn([]), "log": []},
            "read_selinux_mode": lambda: "namespace",
            "sandbox_mount_line": lambda pid, target: None,
            "open_fuse": lambda: os.open(os.devnull, os.O_RDWR),
            "host_policy_loaded": lambda: policy_loaded,
            "label_in_policy_namespace": lambda pid, name, lower: (seen.append(("policy-label", name, lower)), (True, []))[1],
            "_in_sandbox": lambda pid, fn, keep_fds=(): (lambda lines: {"ok": fn(lines), "log": lines})([]),
            "prepare_mount_point": lambda name, lower, mode, lines: (seen.append(("prepare", name, mode)), True)[1],
            "start_daemon": lambda *a: 4242,
            "libc": FakeLibc(),
            "LOWER_ROOT": tmp,
            "OVER_ROOT": tmp,
        }
        for n, v in fake.items():
            setattr(hostfs, n, v)
        try:
            share = hostfs.Share("Download", tmp)
            ok, log = hostfs.attach_one(42, share, sys.executable, os.devnull, 1023, 1023)
        finally:
            for n, v in saved.items():
                setattr(hostfs, n, v)
    return ok, [s[0] for s in seen]


check("attach_one on a policy host labels in android's policy and skips the host-side prepare",
      attach_with(True), (True, ["policy-label"]))
check("attach_one without a host policy prepares the mount point in the sandbox", attach_with(False), (True, ["prepare"]))
print("%d checks failed" % len(failures))
sys.exit(1 if failures else 0)
