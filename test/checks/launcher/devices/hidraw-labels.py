#!/usr/bin/env python3
"""Check the namespace-mode hidraw relabel through the input label service"""

import ast
import contextlib
import io
import os
import re
import select
import socket
import stat
import sys
import tempfile
import threading
import types

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-hidraw-labels")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs as rm
    from sandbox import selinux_ns as ns

HIDRAW = "u:object_r:hidraw_device:s0"
DEVICE = "u:object_r:device:s0"
INPUT = "u:object_r:input_device:s0"
UHID = "/devices/virtual/misc/uhid/0003:1234:5678.0001"
bad = []


def section(name, fn):
    """run a section and record its findings"""
    try:
        for f in fn() or []:
            bad.append((name,) + (f if isinstance(f, tuple) else (f,)))
    except Exception as e:
        bad.append((name, "raised", repr(e)))


def hidraw_add(name, minor):
    """return a hidraw add uevent below the uhid device"""
    fields = [f"add@{UHID}/hidraw/{name}", "ACTION=add", f"DEVPATH={UHID}/hidraw/{name}", "SUBSYSTEM=hidraw",
              "MAJOR=245", f"MINOR={minor}", f"DEVNAME={name}"]
    return "\0".join(fields).encode() + b"\0"


class SandboxDev:
    """Fake sandbox /dev and /proc"""

    def __init__(self):
        """start with no nodes, fds or calls"""
        self.nodes, self.calls, self.fds = {}, [], []
        self.swap_after_open = self.fail_set = self.proc = None
        self.proc_seen = 0

    def add(self, path, dev, ino, label, mode=stat.S_IFCHR | 0o660):
        """add a node and its identity"""
        self.nodes[path] = types.SimpleNamespace(st_mode=mode, st_rdev=dev, st_ino=ino, st_dev=7, label=label)

    def lstat(self, path):
        """return a node's stat"""
        if path not in self.nodes:
            raise FileNotFoundError(2, "No such file or directory", path)
        return self.nodes[path]

    def _resolve(self, path):
        """return the node a path names, following /proc/self/fd links"""
        m = re.fullmatch(r"/proc/self/fd/([0-9]+)", path)
        if m is None:
            return self.lstat(path)
        if self.proc in ("missing", "other-pid-ns") or int(m.group(1)) >= len(self.fds):
            raise FileNotFoundError(2, "No such file or directory", path)
        if self.proc == "denied":
            raise PermissionError(13, "Permission denied", path)
        self.proc_seen += 1
        if self.proc == "planted" or (self.proc == "swapped-during-write" and self.proc_seen > 1):
            return types.SimpleNamespace(st_mode=stat.S_IFCHR | 0o660, st_rdev=self.fds[0].st_rdev, st_ino=99,
                                         st_dev=7, label=DEVICE)
        return self.fds[int(m.group(1))]

    def open_path(self, path):
        """return a fake O_PATH fd on the node at path"""
        node = self.lstat(path)
        self.calls.append(("open_path", path))
        self.fds.append(node)
        if self.swap_after_open:
            self.nodes[path] = types.SimpleNamespace(st_mode=node.st_mode, st_rdev=node.st_rdev,
                                                     st_ino=node.st_ino + 1, st_dev=7, label=DEVICE)
        return len(self.fds) - 1

    def fstat(self, fd):
        """return the stat of an fd's node"""
        return self.fds[fd]

    def stat(self, path):
        """return the stat of the node a path names"""
        return self._resolve(path)

    def statfs_type(self, path):
        """return /proc's filesystem magic"""
        if self.proc == "missing":
            raise FileNotFoundError(2, "No such file or directory", path)
        return 0x01021994 if self.proc == "tmpfs" else ns.PROC_SUPER_MAGIC

    def setxattr(self, path, name, value):
        """set the label of the node a path names"""
        node = self._resolve(path)
        self.calls.append(("setxattr", path, name, value))
        if self.fail_set:
            raise OSError(self.fail_set, os.strerror(self.fail_set))
        node.label = value.decode().rstrip("\0")

    def getxattr(self, path, name, follow_symlinks=True):
        """return the label of the node a path names"""
        self.calls.append(("getxattr", path, name, follow_symlinks))
        return (self._resolve(path).label + "\0").encode()

    def fsetxattr(self, fd, name, value):
        """refuse an xattr write on an O_PATH fd"""
        self.calls.append(("fsetxattr", fd))
        raise OSError(9, os.strerror(9))

    def fgetxattr(self, fd, name):
        """refuse an xattr read on an O_PATH fd"""
        self.calls.append(("fgetxattr", fd))
        raise OSError(9, os.strerror(9))

    def close(self, fd):
        """record a close"""
        self.calls.append(("close", fd))

    def __getattr__(self, name):
        """record any other file operation"""
        return lambda *a, **k: self.calls.append((name,) + a)


def service_findings():
    """check the service's set request"""
    out = []
    one_set = [("setxattr", "/proc/self/fd/0", "security.selinux", (HIDRAW + "\0").encode())]
    for msg, want, what, setup in (
            (b"/dev/hidraw1 245:1 14", b"label " + HIDRAW.encode(), "a fresh hidraw node", "set"),
            (b"/dev/input/event4 13:68 11", b"refused:path", "an evdev node", None),
            (b"/dev/hidraw 245:1 14", b"refused:path", "a hidraw name with no number", None),
            (b"/dev/hidraw1x 245:1 14", b"refused:path", "a name past the number", None),
            (b"/dev/../dev/hidraw1 245:1 14", b"refused:path", "a path climbing through /dev", None),
            (b"/dev/input/../hidraw1 245:1 14", b"refused:path", "a path climbing out of /dev/input", None),
            (b"/sys/class/hidraw/hidraw1 245:1 14", b"refused:path", "a sysfs path", None),
            (b"/dev/hidraw1 245:2 14", b"refused:not-the-node", "the node under another dev_t", None),
            (b"/dev/hidraw1 245:1 99", b"refused:not-the-node", "the node under another inode", None),
            (b"/dev/hidraw2 245:2 15", b"refused:not-the-node", "a symlink at a hidraw name", None),
            (b"/dev/hidraw3 245:3 16", b"refused:not-the-node", "a block node at a hidraw name", None),
            (b"/dev/hidraw9 245:9 20", b"failed:2", "a missing node", None),
            (b"/dev/hidraw1 245:1 14", b"failed:1", "a refused setxattr", "fail"),
            (b"/dev/hidraw1 245:1 14", b"label " + HIDRAW.encode(), "a node swapped after the open", "swap"),
            (b"/dev/hidraw1 245:1 14", b"refused:no-proc:2", "no /proc in the sandbox", "missing"),
            (b"/dev/hidraw1 245:1 14", b"refused:no-proc", "a /proc that is not procfs", "tmpfs"),
            (b"/dev/hidraw1 245:1 14", b"failed:2", "a /proc of another pid namespace", "other-pid-ns"),
            (b"/dev/hidraw1 245:1 14", b"failed:13", "a permission denial on the node through its fd link", "denied"),
            (b"/dev/hidraw1 245:1 14", b"refused:not-the-node", "a /proc fd link naming another node", "planted"),
            (b"/dev/hidraw1 245:1 14", b"refused:not-the-node", "a /proc fd link that moved during the write",
             "swapped-during-write"),
            (b"/dev/hidraw1", b"refused:request", "a request with no dev_t", None),
            (b"/dev/hidraw1 245:1 14 x", b"refused:request", "a request with an extra field", None),
            (b"\xff\xfe 245:1 14", b"refused:path", "a request that is not text", None)):
        dev = SandboxDev()
        dev.add("/dev/hidraw1", os.makedev(245, 1), 14, DEVICE)
        dev.add("/dev/hidraw2", os.makedev(245, 2), 15, DEVICE, mode=stat.S_IFLNK | 0o777)
        dev.add("/dev/hidraw3", os.makedev(245, 3), 16, DEVICE, mode=stat.S_IFBLK | 0o660)
        dev.add("/dev/input/event4", os.makedev(13, 68), 11, INPUT)
        dev.fail_set = 1 if setup == "fail" else None
        dev.swap_after_open = setup == "swap"
        dev.proc = (setup if setup in ("missing", "tmpfs", "other-pid-ns", "denied", "planted", "swapped-during-write")
                    else None)
        got = ns.answer_set_request(msg, dev)
        if got != want:
            out.append((what, msg, want, got))
        sets = [c for c in dev.calls if c[0] in ("setxattr", "fsetxattr")]
        wrote = setup in ("set", "fail", "swap", "swapped-during-write")
        if sets != (one_set if wrote else []):
            out.append((what, "the label writes, wanted %s" % ("one setxattr of hidraw_device through "
                                                                 "/proc/self/fd/0" if wrote else "none"), sets))
        if any(c[0] in ("fsetxattr", "fgetxattr") for c in dev.calls):
            out.append((what, "the service used an xattr call on its O_PATH fd, which the kernel refuses", dev.calls))
        opens = sum(c[0] == "open_path" for c in dev.calls)
        if opens != sum(c[0] == "close" for c in dev.calls):
            out.append((what, "an opened fd was left open", dev.calls))
        if any(c[0] not in ("open_path", "setxattr", "getxattr", "close") for c in dev.calls):
            out.append((what, "the service made another file operation", dev.calls))
        if any(c[0] in ("setxattr", "getxattr") and not c[1].startswith("/proc/self/fd/") for c in dev.calls):
            out.append((what, "the service set or read a label by the node's own path", dev.calls))
        if setup == "swap" and (dev.nodes["/dev/hidraw1"].label != DEVICE or dev.fds[0].label != HIDRAW):
            out.append((what, "the write missed the opened node or reached the swapped-in one",
                        dev.fds[0].label, dev.nodes["/dev/hidraw1"].label))
    dev = SandboxDev()
    dev.add("/dev/hidraw1", os.makedev(245, 1), 14, HIDRAW)
    if ns.answer_label_request(b"/dev/hidraw1 245:1 14", dev) != b"refused:path":
        out.append(("the read-only verb now answers a hidraw path",))
    for msg, want in ((b"set /dev/hidraw1 245:1 14", b"label " + HIDRAW.encode()),
                      (b"set /dev/input/event4 13:68 11", b"refused:path"),
                      (b"/dev/input/event4 13:68 11", b"label " + INPUT.encode()),
                      (b"set", b"refused:path")):
        dev = SandboxDev()
        dev.add("/dev/hidraw1", os.makedev(245, 1), 14, DEVICE)
        dev.add("/dev/input/event4", os.makedev(13, 68), 11, INPUT)
        got = ns.answer_service_request(msg, dev, dev)
        if got != want:
            out.append(("the service's dispatch", msg, want, got))
    src = ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read())
    serve = next(n for n in src.body if isinstance(n, ast.FunctionDef) and n.name == "_serve_labels")
    called = {ast.unparse(c.func) for c in ast.walk(serve) if isinstance(c, ast.Call)}
    if "answer_service_request" not in called or "answer_label_request" in called:
        out.append(("_serve_labels answers through answer_service_request alone", sorted(called)))
    return out


UNAVAILABLE = (38, 95)
REAL_XATTR = "user.rhizo-check"


def real_fd_findings(where=None, name=REAL_XATTR):
    """run the O_PATH calls on a real file"""
    out = []
    tmp = tempfile.mkdtemp(dir=where)
    try:
        path, link = os.path.join(tmp, "node"), os.path.join(tmp, "link")
        open(path, "w").close()
        os.symlink(path, link)
        fd = ns.NODE_FD.open_path(link)
        if not stat.S_ISLNK(ns.NODE_FD.fstat(fd).st_mode):
            out.append(("open_path followed a link",))
        ns.NODE_FD.close(fd)
        fd = ns.NODE_FD.open_path(path)
        try:
            try:
                os.setxattr(fd, name, b"fd")
                out.append(("the kernel took an xattr write on an O_PATH fd, which the fake refuses",))
            except OSError as e:
                if e.errno != 9:
                    out.append(("an xattr write on an O_PATH fd failed with errno %d, not EBADF" % e.errno,))
            try:
                got = ns.set_xattr_through_fd(ns.NODE_FD, fd, ns.NODE_FD.fstat(fd), name, b"set")
            except OSError as e:
                if e.errno in UNAVAILABLE:
                    print("NOT RUN: %s xattrs unsupported on %s (errno %d)" % (name, tmp, e.errno))
                else:
                    out.append(("the /proc/self/fd set failed", e))
                    print("RAN, FAILED: %s set through /proc/self/fd on an O_PATH fd (errno %d)" % (name, e.errno))
            else:
                if got != b"set" or os.getxattr(path, name) != b"set":
                    out.append(("the /proc/self/fd set did not round-trip on the opened inode", got))
                    print("RAN, FAILED: %s set through /proc/self/fd read back %r" % (name, got))
                else:
                    print("RAN: %s set and read back through /proc/self/fd on an O_PATH fd" % name)
        finally:
            ns.NODE_FD.close(fd)
        fd = ns.NODE_FD.open_path(path)
        try:
            ns.NODE_FD.fchown(fd, os.getuid(), os.getgid())
            try:
                ns.NODE_FD.fchmod(fd, 0o640)
            except OSError as e:
                if e.errno in UNAVAILABLE:
                    print("NOT RUN: fchmodat2 unavailable here (errno %d); the fence answers reason=chown:%d there"
                          % (e.errno, e.errno))
                else:
                    out.append(("fchmodat2 failed", e))
                    print("RAN, FAILED: fchmodat2 on an O_PATH fd (errno %d)" % e.errno)
            else:
                if stat.S_IMODE(os.stat(path).st_mode) != 0o640:
                    out.append(("fchmodat2 did not set the opened inode's mode",))
                    print("RAN, FAILED: fchmodat2 on an O_PATH fd left mode %o" % stat.S_IMODE(os.stat(path).st_mode))
                else:
                    print("RAN: fchownat and fchmodat2 on an O_PATH fd")
        finally:
            ns.NODE_FD.close(fd)
    finally:
        for f in ("node", "link"):
            if os.path.lexists(os.path.join(tmp, f)):
                os.unlink(os.path.join(tmp, f))
        os.rmdir(tmp)
    return out


class HostDev:
    """Host view of the sandbox's /dev"""

    def __init__(self):
        """start with no nodes and no calls"""
        self.nodes, self.calls, self.mask, self.next_ino = {}, [], 0o022, 100

    def umask(self, mask):
        """set the mask and return the previous one"""
        old, self.mask = self.mask, mask
        return old

    def lstat(self, p):
        """return a node's stat"""
        if p not in self.nodes:
            raise FileNotFoundError(2, "No such file or directory", p)
        n = self.nodes[p]
        return types.SimpleNamespace(st_mode=n["mode"], st_rdev=n["dev"], st_ino=n["ino"])

    def mknod(self, p, mode, dev):
        """create a node born with /dev's label"""
        self.next_ino += 1
        self.nodes[p] = {"mode": stat.S_IFMT(mode) | (stat.S_IMODE(mode) & ~self.mask), "dev": dev, "uid": 0,
                         "gid": 0, "ino": self.next_ino, "label": DEVICE}
        self.calls.append(("mknod", p))

    def chown(self, p, uid, gid):
        """set a node's owner"""
        self.nodes[p].update(uid=uid, gid=gid)
        self.calls.append(("chown", p))

    def chmod(self, p, mode):
        """set a node's permission bits"""
        self.nodes[p]["mode"] = stat.S_IFMT(self.nodes[p]["mode"]) | mode
        self.calls.append(("chmod", p))

    def unlink(self, p):
        """remove a node"""
        self.lstat(p)
        del self.nodes[p]
        self.calls.append(("unlink", p))

    def setxattr(self, p, name, value):
        """set a node's label from the host"""
        self.nodes[p]["label"] = value.decode().rstrip("\0")
        self.calls.append(("setxattr", p))

    def getxattr(self, p, name):
        """return a node's label from the host"""
        self.calls.append(("getxattr", p))
        return (self.nodes[p]["label"] + "\0").encode()

    def open_path(self, p):
        """return a fake O_PATH fd on the node at p"""
        self.lstat(p)
        self.fds = getattr(self, "fds", []) + [(p, self.nodes[p])]
        return len(self.fds) - 1

    def fstat(self, fd):
        """return the stat of an fd's node"""
        n = self.fds[fd][1]
        return types.SimpleNamespace(st_mode=n["mode"], st_rdev=n["dev"], st_ino=n["ino"])

    def fchown(self, fd, uid, gid):
        """set an fd's node's owner"""
        self.fds[fd][1].update(uid=uid, gid=gid)
        self.calls.append(("chown", self.fds[fd][0]))

    def fchmod(self, fd, mode):
        """set an fd's node's permission bits"""
        n = self.fds[fd][1]
        n["mode"] = stat.S_IFMT(n["mode"]) | mode
        self.calls.append(("chmod", self.fds[fd][0]))

    def close(self, fd):
        """record a fake fd's close"""
        self.closed = getattr(self, "closed", set()) | {fd}


class FakeService:
    """Fake input label service"""

    def __init__(self, path, dev, replies):
        """start the fake service on path"""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.sock.connect(path)
        self.dev, self.replies, self.requests = dev, replies, []
        self.sock.send(b"ready")
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        """answer each request from the table"""
        while True:
            try:
                msg = self.sock.recv(512)
            except OSError:
                return
            if not msg:
                return
            self.requests.append(msg)
            verb, node = msg.split(b" ")[:2]
            reply = self.replies.get(node, "set")
            if reply is None:
                self.sock.close()
                return
            if reply == "set" and verb == b"set":
                self.dev.nodes[node.decode()]["label"] = HIDRAW
                self.dev.calls.append(("service-set", node.decode()))
                reply = b"label " + HIDRAW.encode()
            elif reply == "swap":
                n = self.dev.nodes[node.decode()]
                self.dev.nodes[node.decode()] = dict(n, label=HIDRAW, ino=n["ino"] + 1000)
                reply = b"label " + HIDRAW.encode()
            elif reply == "link":
                n = self.dev.nodes[node.decode()]
                self.dev.nodes[node.decode()] = dict(n, mode=stat.S_IFLNK | 0o777)
                reply = b"label " + HIDRAW.encode()
            self.sock.send(reply)


def pump(loop, until, seconds=5):
    """run the fence loop for a condition"""
    for _ in range(int(seconds * 20)):
        if until():
            return True
        ready, _, _ = select.select(loop.fds(), [], [], 0.05)
        if ready:
            loop.handle(ready)
    return until()


class Netlink:
    """Fake kernel uevent socket"""

    def __init__(self, sock):
        """keep the socket"""
        self.sock = sock

    def fileno(self):
        """return the socket's fd"""
        return self.sock.fileno()

    def recvfrom(self, n):
        """return the next datagram from the kernel's port"""
        return self.sock.recv(n), (0, 1)


def fence_findings():
    """check the namespace-mode fence's hidraw publishes"""
    out = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "label.sock")
    log = []
    labels = rm.open_label_service(0, log.append, path=path)
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    dev = HostDev()
    fence = rm.InputFence("/nonexistent-sys")
    loop = rm.FenceLoop(fence, Netlink(a), "", log.append, dev, labels=labels, fd_ops=dev)
    saved = rm._peer_uid
    rm._peer_uid = lambda conn: 0
    try:
        svc = FakeService(path, dev, {b"/dev/hidraw2": b"failed:1", b"/dev/hidraw3": b"label " + DEVICE.encode(),
                                      b"/dev/hidraw4": "swap", b"/dev/hidraw7": "link", b"/dev/hidraw5": None})
        if not pump(loop, lambda: labels.ready):
            return [("the fake label service never became ready", log)]
        loop._apply(fence.register("add", UHID))
        loop._apply(fence.decide(rm.parse_uevent(hidraw_add("hidraw1", 1))))
        if "/dev/hidraw1" not in fence.published:
            out.append(("hidraw1, set and read back hidraw_device, was not published", log, dev.calls))
        ino = dev.nodes.get("/dev/hidraw1", {}).get("ino")
        if svc.requests[:1] != [f"set /dev/hidraw1 245:1 {ino}".encode()]:
            out.append(("the set request for hidraw1", f"set /dev/hidraw1 245:1 {ino}", svc.requests))
        order = [op for op, p in dev.calls if p == "/dev/hidraw1"]
        if order != ["mknod", "service-set", "chown", "chmod"]:
            out.append(("hidraw1 was not made, set by the service while root's, then chowned", order))
        n = dev.nodes.get("/dev/hidraw1", {})
        if (n.get("uid"), n.get("gid"), stat.S_IMODE(n.get("mode", 0))) != (1000, 1000, 0o660):
            out.append(("hidraw1's owner and mode", (1000, 1000, 0o660), n))
        if any(op in ("setxattr", "getxattr") for op, _ in dev.calls):
            out.append(("the fence set or read a label from the host in namespace mode", dev.calls))
        if not any("input_fence=published node=/dev/hidraw1" in m for m in log):
            out.append(("hidraw1 drew no published marker", log))
        for name, minor, want in (("hidraw2", 2, "reason=relabel:<failed:1> node=/dev/hidraw2"),
                                  ("hidraw3", 3, f"reason=relabel:{DEVICE} node=/dev/hidraw3"),
                                  ("hidraw4", 4, "reason=label:<not-the-node> node=/dev/hidraw4"),
                                  ("hidraw7", 7, "reason=label:<not-the-node> node=/dev/hidraw7")):
            loop._apply(fence.decide(rm.parse_uevent(hidraw_add(name, minor))))
            if f"/dev/{name}" in fence.published:
                out.append((f"{name} was published", log))
            if name in ("hidraw2", "hidraw3") and f"/dev/{name}" in dev.nodes:
                out.append((f"{name}, refused before its chown, was left in /dev", dev.calls))
            if name in ("hidraw4", "hidraw7") and any(p == f"/dev/{name}" and op in ("chown", "chmod")
                                                      for op, p in dev.calls):
                out.append((f"{name}, swapped after the set, was chowned", dev.calls))
            if not any(want in m for m in log):
                out.append((f"{name} drew no input_fence=failed {want}", log))
        loop._apply(fence.decide(rm.parse_uevent(hidraw_add("hidraw5", 5))))
        before = len(dev.calls)
        loop._apply(fence.decide(rm.parse_uevent(hidraw_add("hidraw6", 6))))
        if "/dev/hidraw5" in fence.published or "/dev/hidraw6" in fence.published:
            out.append(("a hidraw node was published with the label service closed", log))
        if len(dev.calls) != before:
            out.append(("a hidraw publish after the label service closed made a node", dev.calls[before:]))
        if not any("reason=label:<label-service-" in m and "node=/dev/hidraw6" in m for m in log):
            out.append(("a hidraw publish after the label service closed drew no failed marker", log))
        if getattr(dev, "closed", set()) != set(range(len(getattr(dev, "fds", [])))):
            out.append(("the fence left an O_PATH fd open", len(dev.fds), sorted(getattr(dev, "closed", ()))))
    finally:
        rm._peer_uid = saved
        for s in (a, b):
            s.close()
        if os.path.exists(path):
            os.unlink(path)
        os.rmdir(tmp)
    return out


def host_findings():
    """check host mode's hidraw relabel order"""
    out = []
    dev, log = HostDev(), []
    fence = rm.InputFence("/nonexistent-sys")
    fence.register("add", UHID)
    for d in fence.decide(rm.parse_uevent(hidraw_add("hidraw1", 1))):
        rm.apply_input_decision(fence, d, "", log.append, dev)
    order = [op for op, p in dev.calls if p == "/dev/hidraw1"]
    if "/dev/hidraw1" not in fence.published or order != ["mknod", "setxattr", "chown", "chmod", "getxattr"]:
        out.append(("host mode's hidraw publish", ["mknod", "setxattr", "chown", "chmod", "getxattr"], order, log))
    return out


if sys.argv[1:2] == ["--real-fd"]:
    section("real fds", lambda: real_fd_findings(sys.argv[2], sys.argv[3]))
else:
    for name, fn in (("service", service_findings), ("real fds", real_fd_findings), ("fence", fence_findings),
                     ("host mode", host_findings)):
        section(name, fn)
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
