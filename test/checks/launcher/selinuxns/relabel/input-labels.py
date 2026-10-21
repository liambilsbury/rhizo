#!/usr/bin/env python3
import ast, contextlib, io, os, re, select, signal, socket, stat, sys, tempfile, threading, time, types
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-input-labels")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs as rm
    from sandbox import selinux_ns as ns

INPUT = "u:object_r:input_device:s0"
TMPFS = "u:object_r:tmpfs:s0"
VIRTUAL = "/devices/virtual/input"
UHID = "/devices/virtual/misc/uhid/0003:1234:5678.0001"
bad = []
not_run = []


def section(name, fn):
    """run a section and record its findings or what it raised"""
    try:
        for f in fn() or []:
            bad.append((name,) + (f if isinstance(f, tuple) else (f,)))
    except Exception as e:
        bad.append((name, "raised", repr(e)))


def uevent(action, devpath, **kv):
    """return a kernel uevent datagram"""
    fields = [f"{action}@{devpath}", f"ACTION={action}", f"DEVPATH={devpath}"] + [f"{k}={v}" for k, v in kv.items()]
    return "\0".join(fields).encode() + b"\0"


def evdev_add(devpath, event, minor):
    """return an evdev add uevent below devpath"""
    return uevent("add", f"{devpath}/{event}", SUBSYSTEM="input", MAJOR=13, MINOR=minor, DEVNAME=f"input/{event}")


def hidraw_add(hid, name, minor):
    """return a hidraw add uevent below a hid device"""
    return uevent("add", f"{hid}/hidraw/{name}", SUBSYSTEM="hidraw", MAJOR=245, MINOR=minor, DEVNAME=name)


class SandboxDev:
    """fake sandbox /dev for the label service"""

    def __init__(self):
        """start with no nodes and no writes"""
        self.nodes, self.writes = {}, []

    def add(self, path, dev, ino, label, mode=stat.S_IFCHR | 0o660):
        """add a node with its dev_t, inode and label"""
        self.nodes[path] = types.SimpleNamespace(st_mode=mode, st_rdev=dev, st_ino=ino, label=label)

    def lstat(self, path):
        """return a node's stat, or raise FileNotFoundError"""
        if path not in self.nodes:
            raise FileNotFoundError(2, "No such file or directory", path)
        return self.nodes[path]

    def getxattr(self, path, name, follow_symlinks=True):
        """return a node's label, recording a read that follows a link"""
        if follow_symlinks or name != "security.selinux":
            self.writes.append(("getxattr", path, name, follow_symlinks))
        return (self.lstat(path).label + "\0").encode()

    def __getattr__(self, name):
        """record any other file operation as a write"""
        return lambda *a, **k: self.writes.append((name,) + a)


def service_findings():
    """check answer_label_request against a fake sandbox /dev"""
    out = []
    dev = SandboxDev()
    dev.add("/dev/input/event4", os.makedev(13, 68), 11, INPUT)
    dev.add("/dev/input/event5", os.makedev(13, 69), 12, TMPFS)
    dev.add("/dev/input/event6", os.makedev(13, 70), 13, INPUT, mode=stat.S_IFLNK | 0o777)
    dev.add("/dev/hidraw1", os.makedev(245, 1), 14, "u:object_r:hidraw_device:s0")
    for msg, want, what in (
            (b"/dev/input/event4 13:68 11", b"label " + INPUT.encode(), "the composer's node"),
            (b"/dev/input/event5 13:69 12", b"label " + TMPFS.encode(), "a mislabeled node, read back as it is"),
            (b"/dev/hidraw1 245:1 14", b"refused:path", "a hidraw node outside /dev/input"),
            (b"/dev/input/../hidraw1 245:1 14", b"refused:path", "a path climbing out of /dev/input"),
            (b"/dev/input/event4/../../hidraw1 245:1 14", b"refused:path", "a path climbing out of an event node"),
            (b"/sys/class/input/event4 13:68 11", b"refused:path", "a sysfs path"),
            (b"/dev/input/event4 13:69 11", b"refused:not-the-node", "the node under another dev_t"),
            (b"/dev/input/event4 13:68 99", b"refused:not-the-node", "the node under another inode"),
            (b"/dev/input/event6 13:70 13", b"refused:not-the-node", "a symlink at an event name"),
            (b"/dev/input/event9 13:73 20", b"failed:2", "a missing node"),
            (b"/dev/input/event4", b"refused:request", "a request with no dev_t"),
            (b"/dev/input/event4 13:68 11 x", b"refused:request", "a request with an extra field"),
            (b"/dev/input/event4 x:68 11", b"refused:request", "a request with a bad major"),
            (b"\xff\xfe 13:68 11", b"refused:path", "a request that is not text")):
        got = ns.answer_label_request(msg, dev)
        if got != want:
            out.append((what, msg, want, got))
    if dev.writes:
        out.append(("the service wrote a node or read a label through a link", dev.writes))
    return out


ZERO_CAPS = "0000000000000000"


def wait_exit(pid):
    """wait 10s for pid to exit"""
    pidfd = os.pidfd_open(pid)
    exited, _, _ = select.select([pidfd], [], [], 10)
    os.close(pidfd)
    if not exited:
        os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    return bool(exited), os.waitstatus_to_exitcode(status)


def recv_within(sock, seconds=10):
    """return the next message on sock, or a marker after seconds"""
    ready, _, _ = select.select([sock], [], [], seconds)
    return sock.recv(512) if ready else b"<nothing in %ds>" % seconds


def service_process_cases():
    """fork the label service for each case and inspect the child"""
    out = []
    last_cap = int(open("/proc/sys/kernel/cap_last_cap").read())
    caps = dict(l.split(":\t", 1) for l in open("/proc/self/status").read().splitlines() if ":\t" in l)
    if caps.get("CapBnd", ZERO_CAPS).strip() == ZERO_CAPS or caps.get("CapEff", ZERO_CAPS).strip() == ZERO_CAPS:
        return [("the user-namespace run holds no capability to drop", caps.get("CapEff"), caps.get("CapBnd"))]
    real, real_enter = ns.libc, ns.enter_label_domain
    for case in ("serves", "setns-fails", "drop-fails"):
        g_end, svc_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        mnt_r, mnt_w = os.pipe()
        held = os.open("/dev/null", os.O_RDONLY)
        os.set_inheritable(held, True)
        release = socket.socketpair()
        svc_fd, release_fd = svc_end.fileno(), release[1].fileno()

        class FakeLibc:
            """setns and capability-drop stand-ins over the real libc"""

            def setns(self, fd, flags):
                """join nothing, answering the case's result"""
                return 0 if case != "setns-fails" and (fd, flags) == (mnt_r, ns.CLONE_NEWNS) else -1

            def prctl(self, op, *args):
                """fail a bounding-set drop in the drop-fails case"""
                return -1 if case == "drop-fails" and op == ns.PR_CAPBSET_DROP else real.prctl(op, *args)

            def __getattr__(self, name):
                """return the real libc function"""
                return getattr(real, name)

        ns.libc = FakeLibc()
        ns.enter_label_domain = lambda: ""
        try:
            pid = ns.start_label_service(svc_end, mnt_r, last_cap, release)
        finally:
            ns.libc, ns.enter_label_domain = real, real_enter
        if case == "serves":
            early = recv_within(g_end, 2)
            if early != b"<nothing in 2s>":
                out.append(("the service spoke before the relabeller released it", early))
            release[0].send(b"1")
        first = recv_within(g_end)
        if case == "serves":
            status = dict(l.split(":\t", 1) for l in open(f"/proc/{pid}/status").read().splitlines() if ":\t" in l)
            fds = sorted(os.listdir(f"/proc/{pid}/fd"))
            if first != b"ready":
                out.append(("the service's first message", b"ready", first))
            got = {k: status.get(k, "").strip() for k in ("CapEff", "CapPrm", "CapInh", "CapBnd", "CapAmb", "NoNewPrivs")}
            want = dict.fromkeys(("CapEff", "CapPrm", "CapInh", "CapBnd", "CapAmb"), ZERO_CAPS)
            want["NoNewPrivs"] = "1"
            if got != want:
                out.append(("the serving label service kept privileges", want, got))
            if fds != sorted(str(fd) for fd in (svc_fd, release_fd)):
                out.append(("the service holds more than its socket and its release pair",
                            sorted(str(fd) for fd in (svc_fd, release_fd)), fds))
            g_end.send(b"/dev/hidraw1 245:1 14")
            got = recv_within(g_end)
            if got != b"refused:path":
                out.append(("the service's answer to a hidraw request", b"refused:path", got))
        elif not first.startswith({"setns-fails": b"error:setns:", "drop-fails": b"error:capbset-drop:"}[case]):
            out.append((case, "the service's first message", first))
        if svc_end.fileno() != -1:
            out.append(("start_label_service kept the relabeller's copy of the socket",))
        if release[1].fileno() != -1:
            out.append(("start_label_service kept the relabeller's copy of the service's release end",))
        g_end.close()
        exited, code = wait_exit(pid)
        if not exited:
            out.append((case, "the service did not exit within 10s of g closing its socket"))
        elif (code == 0) != (case == "serves"):
            out.append((case, "the service's exit code", code))
        release[0].close()
        for fd in (mnt_r, mnt_w, held):
            os.close(fd)
    return out


def service_process_findings():
    """run the forked-service cases in a user namespace holding every capability"""
    import subprocess
    probe = subprocess.run(["unshare", "-r", "true"], capture_output=True, text=True, timeout=20)
    if probe.returncode != 0:
        why = probe.stderr.strip()[-200:] or probe.returncode
        not_run.append(("service process", f"unshare -r is refused here ({why})"))
        return []
    r = subprocess.run(["unshare", "-r", sys.executable, os.path.abspath(__file__), "--service-process"],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0 or "SERVICE-PROCESS-DONE" not in r.stdout:
        return [("the user-namespace run did not finish", r.returncode, (r.stdout + r.stderr)[-600:])]
    return [tuple(l.split("\t")[1:]) for l in r.stdout.splitlines() if l.startswith("FINDING\t")]


def relabeller_findings():
    """check run_relabeller's service fork, release and setcon"""
    out = []
    relabel_context = b"u:r:rhizo_ns_relabel:s0"
    for label, result, connected, setcon, want_release in (
            ("enforced", ns.DONE_ENFORCED, True, "", b"1"), ("permissive", ns.DONE_PERMISSIVE, True, "", b"1"),
            ("failed", ns.DONE_FAILED, True, "", b""), ("no socket", ns.DONE_ENFORCED, False, "", None),
            ("setcon refused", ns.DONE_ENFORCED, True, "setcon:13", b"")):
        events = []
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        dr, dw = os.pipe()
        pairs = []

        def start(sock, mntns_fd, last_cap, release):
            """record the start and keep the service's end of the pair"""
            ready, _, _ = select.select([dr], [], [], 0)
            events.append(("start", sock is a, mntns_fd, last_cap, os.read(dr, 1) if ready else b""))
            release[1].setblocking(False)
            pairs.append(release[1])
            return 4242

        def relabel(*x, on_load=None, **k):
            """stand in for the passes"""
            events.append("relabel")
            why = on_load() if on_load else None
            return ns.failed(why) if why else result

        saved = (ns.connect_label_service, ns._relabel_after_load, ns.start_label_service, ns.kmsg,
                 ns.enter_helper_domain)
        ns.connect_label_service = lambda: (events.append("connect"), (a, 40) if connected else None)[1]
        ns._relabel_after_load = relabel
        ns.start_label_service, ns.kmsg = start, lambda m: None
        ns.enter_helper_domain = lambda request, context: (events.append(("setcon", context)), setcon)[1]
        try:
            code = ns.run_relabeller("/nonexistent-newroot", [], 7, lambda: None, dw)
        finally:
            (ns.connect_label_service, ns._relabel_after_load, ns.start_label_service, ns.kmsg,
             ns.enter_helper_domain) = saved
        want = ["connect", "relabel"] + ([("start", True, 7, 40, b"")] if connected else []) + [("setcon", relabel_context)]
        if events != want:
            out.append((label, want, events))
        if want_release is not None:
            got = b""
            try:
                got = pairs[0].recv(8) if pairs else b"<no start>"
            except BlockingIOError:
                got = b"<open, nothing sent>"
            if got != want_release:
                out.append((label, "the release byte the service gets after the done byte", want_release, got))
        done = os.read(dr, 64) if select.select([dr], [], [], 0)[0] else b""
        if done[:1] != bytes(result if not setcon else ns.DONE_FAILED)[:1] or code != (1 if setcon or result == ns.DONE_FAILED else 0):
            out.append((label, "the done byte and exit code", result, done, code))
        if setcon and b"helper-domain:setcon:13" not in done:
            out.append((label, "a refused setcon is named in the done reason", done))
        if connected and a.fileno() != -1:
            out.append((label, "the relabeller kept its copy of the service socket"))
        for s_ in (a, b):
            s_.close()
        for fd in (dr, dw):
            os.close(fd)
    return out


def connect_findings():
    """check connect_label_service against a listener at label_socket_path"""
    out = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "label.sock")
    saved = (rm.label_socket_path, ns.kmsg)
    rm.label_socket_path = lambda sandbox_id: path
    ns.kmsg = lambda m: None
    try:
        got = ns.connect_label_service()
        if got is not None:
            out.append(("an absent socket", None, got))
            got.close()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        listener.bind(path)
        listener.listen(1)
        got = ns.connect_label_service()
        last_cap = int(open("/proc/sys/kernel/cap_last_cap").read())
        if got is None or got[1] != last_cap:
            out.append(("a listening socket", f"a connection and cap_last_cap {last_cap}", got))
        else:
            conn, _ = listener.accept()
            got[0].send(b"ready")
            if conn.recv(16) != b"ready":
                out.append(("a listening socket", "a working connection"))
            for s in (conn, got[0]):
                s.close()

        class NoSockets:
            """socket module stand-in whose socket() fails"""
            AF_UNIX, SOCK_SEQPACKET = socket.AF_UNIX, socket.SOCK_SEQPACKET

            @staticmethod
            def socket(*a):
                """fail EMFILE"""
                raise OSError(24, "Too many open files")

        ns.socket = NoSockets
        try:
            got = ns.connect_label_service()
        finally:
            ns.socket = socket
        if got is not None:
            out.append(("a socket() that failed EMFILE", None, got))
        listener.close()
    finally:
        rm.label_socket_path, ns.kmsg = saved
        if os.path.exists(path):
            os.unlink(path)
        os.rmdir(tmp)
    return out


class HostDev:
    """fake host view of the sandbox's /dev for the fence"""

    def __init__(self):
        """start with no nodes and no calls"""
        self.nodes, self.calls, self.mask, self.next_ino = {}, [], 0o022, 100

    def umask(self, mask):
        """set the mask and return the previous one"""
        old, self.mask = self.mask, mask
        return old

    def lstat(self, p):
        """return a node's stat, or raise FileNotFoundError"""
        if p not in self.nodes:
            raise FileNotFoundError(2, "No such file or directory", p)
        n = self.nodes[p]
        return types.SimpleNamespace(st_mode=n["mode"], st_rdev=n["dev"], st_ino=n["ino"])

    def mknod(self, p, mode, dev):
        """create a node"""
        self.next_ino += 1
        self.nodes[p] = {"mode": stat.S_IFMT(mode) | (stat.S_IMODE(mode) & ~self.mask), "dev": dev, "uid": 0,
                         "gid": 0, "ino": self.next_ino, "label": INPUT if p.startswith("/dev/input/") else "u:object_r:device:s0"}
        self.calls.append(("mknod", p))

    def chown(self, p, uid, gid):
        """set a node's owner"""
        self.nodes[p].update(uid=uid, gid=gid)

    def open_path(self, p):
        """return a fake O_PATH fd on a node"""
        self.lstat(p)
        self.fds = getattr(self, "fds", []) + [(p, self.nodes[p])]
        return len(self.fds) - 1

    def fstat(self, fd):
        """return the stat of an fd's node"""
        n = self.fds[fd][1]
        return types.SimpleNamespace(st_mode=n["mode"], st_rdev=n["dev"], st_ino=n["ino"])

    def fchown(self, fd, uid, gid):
        """set an fd's node's owner, swapping the path's node when asked"""
        p, n = self.fds[fd]
        n.update(uid=uid, gid=gid)
        if p in getattr(self, "swap_after_chown", ()):
            self.chowned_ino = n["ino"]
            self.nodes[p] = dict(n, ino=n["ino"] + 500)

    def fchmod(self, fd, mode):
        """set an fd's node's permission bits"""
        n = self.fds[fd][1]
        n["mode"] = stat.S_IFMT(n["mode"]) | mode

    def close(self, fd):
        """close a fake fd"""

    def chmod(self, p, mode):
        """set a node's permission bits"""
        self.nodes[p]["mode"] = stat.S_IFMT(self.nodes[p]["mode"]) | mode

    def unlink(self, p):
        """remove a node"""
        self.lstat(p)
        del self.nodes[p]
        self.calls.append(("unlink", p))

    def setxattr(self, p, name, value):
        """set a node's label"""
        self.nodes[p]["label"] = value.decode().rstrip("\0")
        self.calls.append(("setxattr", p))

    def getxattr(self, p, name):
        """return a node's label"""
        self.calls.append(("getxattr", p))
        return (self.lstat(p) and self.nodes[p]["label"] + "\0").encode()

    def listdir(self, d):
        """return the names under a directory"""
        return sorted({p[len(d) + 1:].split("/", 1)[0] for p in self.nodes if p.startswith(d + "/")})


class FakeService:
    """a label service stand-in connected to a listener path"""

    def __init__(self, path, replies, send_ready=True):
        """connect to path and answer requests from the replies table in a thread"""
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        self.sock.connect(path)
        self.requests, self.replies = [], replies
        if send_ready:
            self.sock.send(b"ready")
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        """answer each request with its node's reply, closing on a None reply"""
        while True:
            try:
                msg = self.sock.recv(512)
            except OSError:
                return
            if not msg:
                return
            self.requests.append(msg)
            reply = self.replies.get(msg.split(b" ")[0], b"label " + INPUT.encode())
            if reply is None:
                self.sock.close()
                return
            self.sock.send(reply)


class Netlink:
    """socketpair end shaped like the kernel's uevent socket"""

    def __init__(self, sock):
        """keep the socket"""
        self.sock = sock

    def fileno(self):
        """return the socket's fd"""
        return self.sock.fileno()

    def recvfrom(self, n):
        """return the next datagram from the kernel's port"""
        return self.sock.recv(n), (0, 1)


def pump(loop, until, seconds=5):
    """run the fence loop's select and handle until a condition holds"""
    for _ in range(int(seconds * 20)):
        if until():
            return True
        ready, _, _ = select.select(loop.fds(), [], [], 0.05)
        if ready:
            loop.handle(ready)
    return until()


def fence_findings():
    """run the namespace-mode fence against a fake label service"""
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
        if len(loop.fds()) != 2:
            out.append(("the fence selects on its uevent socket and the label listener", 2, loop.fds()))
        for d in fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event4", 68))):
            loop._apply([d])
        loop._apply(fence.register("add", VIRTUAL + "/input10"))
        if dev.calls:
            out.append(("a publish before the label service is ready made nodes", dev.calls))
        if not any("input_fence=deferred node=/dev/input/event4" in m for m in log):
            out.append(("a publish before the label service is ready drew no deferred marker", log))
        svc = FakeService(path, {b"/dev/input/event5": b"label " + TMPFS.encode(),
                                 b"/dev/input/event6": b"refused:not-the-node", b"/dev/input/event8": None,
                                 b"/dev/input/event10": b"label u:object_r:" + b"x" * 90 + b"\n injected s0"})
        if not pump(loop, lambda: "/dev/input/event4" in fence.published):
            out.append(("the deferred publish never landed once the service was ready", log))
        ino = dev.nodes.get("/dev/input/event4", {}).get("ino")
        if svc.requests[:1] != [f"/dev/input/event4 13:68 {ino}".encode()]:
            out.append(("the label request for event4", f"/dev/input/event4 13:68 {ino}", svc.requests))
        if any(op in ("getxattr", "setxattr") for op, _ in dev.calls):
            out.append(("the fence read or set a label from the host in namespace mode", dev.calls))
        for event, minor, want in (("event5", 69, f"reason=label:{TMPFS} node=/dev/input/event5"),
                                   ("event6", 70, "reason=label:<refused:not-the-node> node=/dev/input/event6")):
            loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", event, minor))))
            if f"/dev/input/{event}" in fence.published:
                out.append((f"{event}, read back {want}, was published",))
            if not any(want in m for m in log):
                out.append((f"{event} drew no input_fence=failed {want}", log))
        loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event10", 74))))
        dev.swap_after_chown = {"/dev/input/event11"}
        loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event11", 75))))
        want = f"/dev/input/event11 13:75 {getattr(dev, 'chowned_ino', None)}".encode()
        if want not in svc.requests:
            out.append(("the read-back after a swap names the chowned inode", want, svc.requests[-2:]))
        long = [re.search(r"reason=label:(.*) node=/dev/input/event10$", m) for m in log]
        long = [m.group(1) for m in long if m]
        if len(long) != 1 or len(long[0]) > 64 or re.search(r"\s", long[0]):
            out.append(("a long multi-line read-back reached the marker uncut", long))
        loop._apply(fence.register("add", UHID))
        loop._apply(fence.decide(rm.parse_uevent(hidraw_add(UHID, "hidraw1", 1))))
        if "/dev/hidraw1" in fence.published or "/dev/hidraw1" in dev.nodes:
            out.append(("a hidraw node whose set read back input_device was kept", dev.calls))
        if ("setxattr", "/dev/hidraw1") in dev.calls:
            out.append(("the fence relabeled a hidraw node from the host in namespace mode", dev.calls))
        if not any(r.startswith(b"set /dev/hidraw1 245:1 ") for r in svc.requests):
            out.append(("the fence asked the label service for no hidraw set", svc.requests))
        if not any(f"input_fence=failed reason=relabel:{INPUT} node=/dev/hidraw1" in m for m in log):
            out.append(("a hidraw set read back input_device drew no failed marker", log))
        loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event8", 72))))
        if "/dev/input/event8" in fence.published:
            out.append(("event8, whose label service closed, was published",))
        before = len(dev.calls)
        loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event9", 73))))
        if "/dev/input/event9" in fence.published or len(dev.calls) != before:
            out.append(("a publish after the label service closed made a node", dev.calls[before:]))
        if not any("reason=label:<label-service-" in m and "node=/dev/input/event9" in m for m in log):
            out.append(("a publish after the label service closed drew no failed marker", log))
    finally:
        rm._peer_uid = saved
        for s in (a, b):
            s.close()
        if os.path.exists(path):
            os.unlink(path)
        os.rmdir(tmp)
    return out


def deadline_findings():
    """check a label service that never connects turns gone at its deadline"""
    out = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "label.sock")
    log = []
    labels = rm.open_label_service(0, log.append, path=path)
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    dev = HostDev()
    fence = rm.InputFence("/nonexistent-sys")
    loop = rm.FenceLoop(fence, Netlink(a), "", log.append, dev, labels=labels, fd_ops=dev)
    try:
        left = (labels.deadline or 0) - time.monotonic()
        if not ns.RELABELLER_DEADLINE_S - 5 < left <= ns.RELABELLER_DEADLINE_S:
            out.append(("the label service's connect deadline from the fence start", ns.RELABELLER_DEADLINE_S, left))
        loop._apply(fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event4", 68))))
        loop._apply(fence.register("add", VIRTUAL + "/input10"))
        labels.deadline = time.monotonic() - 1
        if loop.fds() != [loop.sock]:
            out.append(("the fence still selects on the label listener past the deadline", loop.fds()))
        if not any("input_fence=label-service state=gone reason=never-connected" in m for m in log):
            out.append(("a label service that never connected drew no gone marker", log))
        loop._apply(fence.register("add", VIRTUAL + "/input10"))
        if dev.calls or "/dev/input/event4" in fence.published:
            out.append(("a publish past the connect deadline made a node", dev.calls))
        if not any("reason=label:<label-service-never-connected> node=/dev/input/event4" in m for m in log):
            out.append(("a publish past the connect deadline drew no failed marker", log))
    finally:
        for s in (a, b):
            s.close()
        os.unlink(path)
        os.rmdir(tmp)
    return out


def ready_deadline_findings():
    """check the label deadline bounds g's wait and drops an unready service"""
    out = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "label.sock")
    log = []
    labels = rm.open_label_service(0, log.append, path=path)
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    dev = HostDev()
    loop = rm.FenceLoop(rm.InputFence("/nonexistent-sys"), Netlink(a), "", log.append, dev, labels=labels,
                        fd_ops=dev)
    holder_r, holder_w = os.pipe()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    saved = rm._peer_uid
    rm._peer_uid = lambda conn: 0
    timeouts = []

    def recorded_select(r, w, x, timeout):
        """record the timeout and report nothing ready"""
        timeouts.append(timeout)
        return [], [], []

    try:
        labels.deadline = time.monotonic() + 0.5
        rm.fence_wait_step(holder_r, loop, None, lambda: None, select_fn=recorded_select)
        if not (timeouts and timeouts[-1] is not None and 0 < timeouts[-1] <= 0.5):
            out.append(("g's wait before the label service connects", "at most 0.5 s", timeouts))
        client.connect(path)
        ready, _, _ = select.select(labels.fds(), [], [], 5)
        if ready:
            labels.handle()
        left = (labels.deadline or 0) - time.monotonic()
        if labels.conn is None or not ns.RELABELLER_DEADLINE_S - 5 < left <= ns.RELABELLER_DEADLINE_S:
            out.append(("the ready deadline from the connect", ns.RELABELLER_DEADLINE_S, labels.conn, left))
        rm.fence_wait_step(holder_r, loop, None, lambda: None, select_fn=recorded_select)
        if not (timeouts[-1] is not None and ns.RELABELLER_DEADLINE_S - 5 < timeouts[-1] <= ns.RELABELLER_DEADLINE_S):
            out.append(("g's wait while the label service is not ready", ns.RELABELLER_DEADLINE_S, timeouts))
        labels.deadline = time.monotonic() - 1
        if loop.fds() != [loop.sock]:
            out.append(("the fence still selects on a label service never ready past the deadline", loop.fds()))
        if not any("input_fence=label-service state=gone reason=never-ready" in m for m in log):
            out.append(("a label service never ready drew no gone marker", log))
        rm.fence_wait_step(holder_r, loop, None, lambda: None, select_fn=recorded_select)
        if timeouts[-1] is not None:
            out.append(("g's wait after the label service is gone", None, timeouts[-1]))
    finally:
        rm._peer_uid = saved
        for s in (a, b, client):
            s.close()
        labels.close()
        for fd in (holder_r, holder_w):
            os.close(fd)
        if os.path.exists(path):
            os.unlink(path)
        os.rmdir(tmp)
    return out


def peer_findings():
    """check the fence turns away a label service of another uid"""
    out = []
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "label.sock")
    log = []
    labels = rm.open_label_service(0, log.append, path=path)
    saved = rm._peer_uid
    rm._peer_uid = lambda conn: 1000
    try:
        svc = FakeService(path, {})
        for _ in range(3):
            ready, _, _ = select.select(labels.fds(), [], [], 1)
            if ready:
                labels.handle()
        if labels.ready:
            out.append(("a label service of uid 1000 was trusted",))
        if not any("reason=label-peer-uid:1000" in m for m in log):
            out.append(("a label service of uid 1000 drew no dropped marker", log))
        svc.sock.close()
    finally:
        rm._peer_uid = saved
        os.unlink(path)
        os.rmdir(tmp)
    return out


def host_findings():
    """check host mode reads the label with getxattr"""
    out = []
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        fence = rm.InputFence("/nonexistent-sys")
        loop = rm.FenceLoop(fence, Netlink(a), "", [].append, HostDev())
        if loop.fds() != [loop.sock]:
            out.append(("a host-mode fence selects on more than its uevent socket", loop.fds()))
    finally:
        for s in (a, b):
            s.close()
    dev, log = HostDev(), []
    fence = rm.InputFence("/nonexistent-sys")
    for d in fence.decide(rm.parse_uevent(evdev_add(VIRTUAL + "/input10", "event4", 68))) + \
            fence.register("add", VIRTUAL + "/input10"):
        rm.apply_input_decision(fence, d, "", log.append, dev)
    if "/dev/input/event4" not in fence.published or ("getxattr", "/dev/input/event4") not in dev.calls:
        out.append(("host mode did not publish event4 on a getxattr read-back", dev.calls, log))
    return out


def service_callers(source):
    """return the scopes in source that call start_label_service"""
    is_call = lambda n: isinstance(n, ast.Call) and ast.unparse(n.func).endswith("start_label_service")
    found = set()

    def visit(node, scope):
        """collect the callers below node"""
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if any(is_call(n) for n in ast.walk(child)):
                    found.add(".".join(scope + [child.name]))
            elif isinstance(child, ast.ClassDef):
                visit(child, scope + [child.name])
            elif is_call(child):
                found.add(".".join(scope + ["<body>"]) if scope else "<module>")
            else:
                visit(child, scope)

    visit(ast.parse(source), [])
    return found


def wiring_findings():
    """check the launcher's label socket wiring"""
    out = []
    tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
    parent = {c: p for p in ast.walk(fn) for c in ast.iter_child_nodes(p)}
    opens = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func).endswith("open_label_service")]
    if len(opens) != 1:
        return [("run_sandbox opens the label socket", 1, len(opens))]
    chain, n = [], opens[0]
    while n in parent:
        n = parent[n]
        if isinstance(n, ast.If):
            chain.append(ast.unparse(n.test))
    if "not host_selinux_mode()" not in chain or not any("devices.uinput" in t for t in chain):
        out.append(("the label socket is opened outside namespace mode or without devices.uinput", chain))
    assign = parent[opens[0]]
    target = ast.unparse(assign.targets[0]) if isinstance(assign, ast.Assign) else None
    inits = [n for n in fn.body if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == target
             and ast.unparse(n.value) == "None"]
    if not inits:
        out.append(("the label client is None until namespace mode opens it", target))
    gg = next((n for n in ast.walk(fn) if isinstance(n, ast.If) and ast.unparse(n.test) == "gg == 0"), None)
    body = gg.body if gg else []
    closes = [i for i, n in enumerate(body) if isinstance(n, ast.If) and ast.unparse(n.test) == "not host_selinux_mode()"
              and {"_input_registry.close()", "_input_labels.close()"} <= {ast.unparse(c) for c in ast.walk(n)
                                                                          if isinstance(c, ast.Call)}]
    builds = [i for i, n in enumerate(body) if "build_root_and_pivot(" in ast.unparse(n)]
    if len(closes) != 1 or not builds or closes[0] > builds[0]:
        out.append(("gg closes the registry and label sockets in namespace mode before it builds the root",
                    closes, builds))
    starts = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and ast.unparse(n.func) == "start_fence_or_kill"]
    kw = {k.arg: ast.unparse(k.value) for k in starts[0].keywords} if len(starts) == 1 else {}
    if kw.get("labels") != target:
        out.append(("g starts the fence with labels=", target, kw))
    seen = []
    saved = rm.start_input_fence
    rm.start_input_fence = lambda registry, labels=None: (seen.append((registry, labels)), "loop")[1]
    try:
        rm.start_fence_or_kill("registry", lambda: None, labels="client")
    finally:
        rm.start_input_fence = saved
    if seen != [("registry", "client")]:
        out.append(("start_fence_or_kill hands its labels to start_input_fence", seen))
    src = ast.parse(open(os.path.join(LAUNCHER, "sandbox/rootfs.py")).read())
    start = next(n for n in src.body if isinstance(n, ast.FunctionDef) and n.name == "start_input_fence")
    ret = [n for n in ast.walk(start) if isinstance(n, ast.Call) and ast.unparse(n.func) == "FenceLoop"]
    if not ret or "labels" not in {k.arg: ast.unparse(k.value) for k in ret[0].keywords}:
        out.append(("start_input_fence builds its FenceLoop with the labels it was given",))
    callers = set()
    for mod in ("boot.py", "sandbox/rootfs.py", "sandbox/selinux_ns.py"):
        callers |= service_callers(open(os.path.join(LAUNCHER, mod)).read())
    if callers != {"run_relabeller"}:
        out.append(("the label service is forked by the relabeller outside Android's Landlock domain",
                    {"run_relabeller"}, callers))
    return out


def callers_selftest():
    """return the problems of service_callers on fixture sources"""
    call = "start_label_service(sock, mntns, cap, release)"
    cases = (
        ("a top-level caller", "def run_relabeller():\n    %s\n" % call, {"run_relabeller"}),
        ("a caller nested in the relabeller", "def run_relabeller():\n    def on_load():\n        %s\n    on_load()\n" % call,
         {"run_relabeller"}),
        ("a method caller", "class Fence:\n    def start(self):\n        %s\n" % call, {"Fence.start"}),
        ("a method caller named like the relabeller", "class Fence:\n    def run_relabeller(self):\n        %s\n" % call,
         {"Fence.run_relabeller"}),
        ("a caller nested in a method", "class Fence:\n    def start(self):\n        def later():\n            %s\n" % call,
         {"Fence.start"}),
        ("a class body caller", "class Fence:\n    %s\n" % call, {"Fence.<body>"}),
        ("a module level caller", "if True:\n    %s\n" % call, {"<module>"}),
        ("no caller", "def run_relabeller():\n    pass\n", set()),
    )
    return ["%s: service_callers gave %s, wanted %s" % (label, got, want) for label, source, want in cases
            for got in [service_callers(source)] if got != want]


if "--selftest" in sys.argv[1:]:
    problems = callers_selftest()
    for p in problems:
        print("FAIL", p)
    print("input-labels selftest: " + ("FAIL" if problems else "ok"))
    sys.exit(1 if problems else 0)
if "--service-process" in sys.argv[1:]:
    for f in service_process_cases():
        print("FINDING\t" + "\t".join(map(str, f)))
    print("SERVICE-PROCESS-DONE")
    sys.exit(0)
SECTIONS = (("service", service_findings), ("service process", service_process_findings),
            ("relabeller", relabeller_findings), ("connect", connect_findings), ("fence", fence_findings),
            ("deadline", deadline_findings), ("ready deadline", ready_deadline_findings),
            ("peer", peer_findings), ("host mode", host_findings),
            ("wiring", wiring_findings))
for name, fn in SECTIONS:
    section(name, fn)
for name, why in not_run:
    print(f"NOT RUN: {name} -- {why}")
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
if not_run:
    print(f"input-labels: {len(SECTIONS) - len(not_run)} of {len(SECTIONS)} sections ok; NOT RUN: "
          f"{', '.join(name for name, _ in not_run)} -- not a full pass")
    sys.exit(77)
print("ok")
