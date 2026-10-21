#!/usr/bin/env python3
import concurrent.futures
import contextlib
import io
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
SRC = os.path.join(REPO, "src", "services", "inputd", "inputd.c")
MOCK = os.path.join(REPO, "test", "system", "inject", "inputd-mock-uinput.c")
RULE = os.path.join(REPO, "src", "services", "udev", "70-uinput.rules")
OWNED_LINE = ('PROGRAM=="/usr/lib/udev/rhizo-input-owned owned %p", ENV{ID_INPUT}="", '
              'ENV{LIBINPUT_IGNORE_DEVICE}="1"')

CUSE_INIT, FUSE_OPEN, FUSE_READ, FUSE_WRITE, FUSE_RELEASE = 4096, 14, 15, 16, 18
FUSE_INTERRUPT, FUSE_IOCTL, FUSE_POLL, FUSE_GETATTR = 36, 39, 40, 3
FUSE_NOTIFY_POLL, FUSE_POLL_SCHEDULE_NOTIFY = 1, 1
UHID_CREATE2, UHID_INPUT2, UHID_DESTROY, UHID_START = 11, 12, 1, 2
UHID_EVENT_SIZE = 4380
WAIT = 10


def say(msg):
    """print a message prefixed with the check name to stderr"""
    print("check-inputd: %s" % msg, file=sys.stderr)


def build(tmp, src_text):
    """build rhizo-inputd and the uinput mock"""
    src = os.path.join(tmp, "host", "rhizo-inputd", "inputd.c")
    os.makedirs(os.path.dirname(src))
    os.makedirs(os.path.join(tmp, "host", "fuse-wire"))
    with open(src, "w") as f:
        f.write(src_text)
    with open(os.path.join(REPO, "src", "services", "fuse-wire", "fuse_wire.h")) as f:
        header = f.read()
    with open(os.path.join(tmp, "host", "fuse-wire", "fuse_wire.h"), "w") as f:
        f.write(header)
    daemon, mock = os.path.join(tmp, "rhizo-inputd"), os.path.join(tmp, "mock.so")
    for cmd in (["gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-o", daemon, src],
                ["gcc", "-shared", "-fPIC", "-O2", "-o", mock, MOCK, "-ldl"]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError("build failed: %s" % (r.stderr.strip()[:400]))
    return daemon, mock


def listen(path):
    """return a listening seqpacket socket bound to a path"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    s.bind(path)
    s.listen(8)
    s.settimeout(WAIT)
    return s


def accept(s):
    """return a connection accepted from a listening socket"""
    c, _ = s.accept()
    c.settimeout(WAIT)
    return c


def recv_or_none(s, timeout=0.3):
    """receive a message within the timeout"""
    s.settimeout(timeout)
    try:
        return s.recv(65536)
    except (socket.timeout, BlockingIOError):
        return None
    finally:
        s.settimeout(WAIT)


class Missing(Exception):
    """exception for a missing message"""


def rx(sock, what, size=65536):
    """receive a message or raise Missing"""
    try:
        data = sock.recv(size)
    except (socket.timeout, OSError):
        raise Missing(what)
    if not data:
        raise Missing(what)
    return data


def uevent(action, devpath, subsystem, **kv):
    """return the bytes of a uevent message"""
    fields = ["%s@%s" % (action, devpath), "ACTION=" + action, "DEVPATH=" + devpath, "SUBSYSTEM=" + subsystem]
    fields += ["%s=%s" % (k, v) for k, v in kv.items()]
    return "\0".join(fields).encode() + b"\0"


CHILD = r'''
import contextlib, ctypes, fcntl, io, os, sys
os.environ.setdefault("RHIZO_GSI", "/nonexistent")
sys.path.insert(0, sys.argv[1])
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs
libc = ctypes.CDLL(None, use_errno=True)
libc.prctl(38, 1, 0, 0, 0)  # set PR_SET_NO_NEW_PRIVS
# set PR_SET_PTRACER_ANY
libc.prctl(0x59616d61, ctypes.c_ulong(-1), 0, 0, 0)
say = lambda m: print("LOG", m, flush=True)
sup = rootfs.connect_input_supervisor(0, log=say, path=sys.argv[2], wait_s=float(sys.argv[3]))
print("FILTER", rootfs.install_uinput_filter(sup, log=say) or "none", flush=True)
fds = {}
def create(name):
    try:
        fcntl.ioctl(fds[name], 0x5501)
        print("CREATE", name, 0, flush=True)
    except OSError as e:
        print("CREATE", name, e.errno, flush=True)
for line in sys.stdin:
    w = line.split()
    if w[0] == "open":
        fds[w[1]] = os.open(w[2], os.O_PATH if w[3:] == ["path"] else os.O_RDWR)
        print("OPEN", w[1], 0, flush=True)
    elif w[0] == "thread":
        import threading
        t = threading.Thread(target=create, args=(w[1],))
        t.start()
        t.join()
    elif w[0] == "spawn":
        pid = os.fork()
        if pid == 0:
            libc.prctl(0x59616d61, ctypes.c_ulong(-1), 0, 0, 0)
            create(w[1])
            os._exit(0)
        print("PID", w[1], pid, flush=True)
    else:
        create(w[1])
'''


LISTEN_WRAP = (
    "import os, sys\n"
    "os.dup2(50, 3); os.dup2(51, 4); os.close(50); os.close(51)\n"
    "os.environ['LISTEN_PID'] = str(os.getpid())\n"
    "os.execv(sys.argv[1], sys.argv[1:])\n")


def my_cgroup():
    """return the cgroup v2 path of this process"""
    for line in open("/proc/self/cgroup"):
        if line.startswith("0::"):
            return line[3:].strip()
    raise RuntimeError("no cgroup v2 line in /proc/self/cgroup")


class Child:
    """launcher child process for tests"""

    def __init__(self, sup_path, wait_s=10, env=None):
        """start the child process that holds the supervisor client"""
        self.p = subprocess.Popen([sys.executable, "-c", CHILD, os.path.join(REPO, "src", "androidd"), sup_path, str(wait_s)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

    def line(self):
        """read a result line from the child"""
        while True:
            got = self.p.stdout.readline()
            if not got:
                raise Missing("a line from the launcher's child")
            if not got.startswith("LOG "):
                return got.split()

    def do(self, cmd):
        """send a command line to the child"""
        self.p.stdin.write(cmd + "\n")
        self.p.stdin.flush()

    def result(self, cmd):
        """send a command and return the line the child answers"""
        self.do(cmd)
        return self.line()

    def kill(self):
        """kill the child process and wait for it"""
        self.p.kill()
        self.p.wait()


class Notes:
    """listening socket for mock kernel announcements"""

    def __init__(self, path):
        """listen on a socket path"""
        self.l = listen(path)

    def take(self, what, timeout=WAIT):
        """accept an announcement or raise Missing"""
        self.l.settimeout(timeout)
        try:
            c, _ = self.l.accept()
        except (socket.timeout, OSError):
            raise Missing(what)
        finally:
            self.l.settimeout(WAIT)
        c.settimeout(WAIT)
        return c.recv(64).decode(), c

    def none(self, timeout=0.5):
        """return any announcement within the timeout"""
        try:
            line, c = self.take("nothing", timeout)
        except Missing:
            return None
        with contextlib.suppress(OSError):
            c.send(b"go")
        return line


def cuse_pair():
    """create a socketpair for /dev/cuse"""
    kernel, served = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    kernel.settimeout(WAIT)
    kernel.send(fuse_req(CUSE_INIT, 1, struct.pack("<IIII", 7, 39, 0, 0)))
    return kernel, served


def notify_socket(path):
    """return a datagram socket bound to a notify path"""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(path)
    s.settimeout(WAIT)
    return s


NOTIFIED = []


def stored(notify, name, what):
    """return the fd from the FDSTORE message"""
    while True:
        try:
            msg, fds, _, _ = socket.recv_fds(notify, 256, 4)
        except (socket.timeout, OSError):
            raise Missing(what)
        if msg.decode() == "FDSTORE=1\nFDNAME=%s" % name and fds:
            return fds[0]
        NOTIFIED.append(msg.decode())
        for fd in fds:
            os.close(fd)


def supervisor(daemon, tmp, name, extra=(), env=None, pass_fds=(), wrap=None, stderr=None, owned_default=False):
    """start the supervisor"""
    args = [daemon, "supervise", "--instance", "7", "--socket", os.path.join(tmp, name + ".sock"),
            "--fence", os.path.join(tmp, "fence.sock"), "--state", os.path.join(tmp, "owned"),
            "--uinput-rdev", "1:3", "--sys", os.path.join(tmp, "sys"), "--broker-cgroup", my_cgroup()]
    if not owned_default and "--owned-socket" not in extra:
        args += ["--owned-socket", os.path.join(tmp, name + "-udev.sock")]
    if not owned_default and "--owned-uid" not in extra:
        args += ["--owned-uid", str(os.getuid())]
    return subprocess.Popen((wrap or []) + args + list(extra), env=env, pass_fds=pass_fds, stderr=stderr)


def wait_socket(path):
    """wait for a socket path to exist"""
    for _ in range(WAIT * 20):
        if os.path.exists(path):
            return
        time.sleep(0.05)
    raise Missing("the supervisor's socket at %s" % path)


def ask(path, msg, what):
    """send a message and return the reply"""
    q = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    q.connect(path)
    q.settimeout(WAIT)
    q.send(msg.encode())
    try:
        return rx(q, what)
    finally:
        q.close()


def owned(daemon, sup_path, devpath):
    """return whether the daemon reports a device as owned"""
    return subprocess.run([daemon, "owned", devpath, "--sockets", sup_path]).returncode == 0


def mkdev(tmp, devpath, uevent_text=None):
    """create a device directory with an optional uevent file"""
    d = os.path.join(tmp, "sys") + devpath
    os.makedirs(d, exist_ok=True)
    if uevent_text is not None:
        with open(d + "/uevent", "w") as f:
            f.write(uevent_text)


def check_supervise(daemon, mock, tmp):
    """run rhizo-inputd supervise against a mock kernel"""
    bad = []
    sup_path, fence_path = os.path.join(tmp, "sup.sock"), os.path.join(tmp, "fence.sock")
    uev_l, fence_l = listen(os.path.join(tmp, "uev.sock")), listen(fence_path)
    notes = Notes(os.path.join(tmp, "note.sock"))
    notify = notify_socket(os.path.join(tmp, "notify.sock"))
    hid = "/devices/virtual/misc/uhid/0003:1234:5678.0001"
    kernel, served = cuse_pair()
    env = dict(os.environ, LD_PRELOAD=mock, RHIZO_MOCK_UINPUT_RDEV="1:3", RHIZO_MOCK_NOTE=os.path.join(tmp, "note.sock"),
               RHIZO_MOCK_SYSNAME_FAIL="901", RHIZO_MOCK_GETFD_PAUSE="6", RHIZO_MOCK_KILL_EPERM="1",
               NOTIFY_SOCKET=os.path.join(tmp, "notify.sock"))
    log = open(os.path.join(tmp, "sup.log"), "w")
    udev_path = os.path.join(tmp, "udev-owned.sock")
    sup = supervisor(daemon, tmp, "sup", ["--uevents", os.path.join(tmp, "uev.sock"), "--cuse-fd", str(served.fileno()),
                                          "--owned-socket", udev_path],
                     env=env, pass_fds=[served.fileno()], stderr=log)
    served.close()
    child = restarted = None
    try:
        uev = accept(uev_l)
        err, uniq, body = fuse_reply(rx(kernel, "the supervisor's CUSE_INIT reply"))
        if err or uniq != 1 or b"DEVNAME=rhizo-7-uhid\0" not in body:
            bad.append("supervise: CUSE_INIT answered error %d body %r" % (err, body[64:]))
        stored_cuse = stored(notify, "cuse", "the CUSE channel in the fd store")
        wait_socket(sup_path)
        child = Child(sup_path)
        mode = child.line()
        if mode != ["FILTER", "listening"]:
            return bad + ["supervise: the launcher's install_uinput_filter did not hand its listener over: %r" % mode]
        NOTIFIED.clear()
        stored_listener = stored(notify, "listener", "the seccomp listener in the fd store")
        if "READY=1" not in NOTIFIED:
            bad.append("supervise: it never told systemd it was ready")
        child.result("open a /dev/null")
        child.do("create a")
        created, note = notes.take("the mock kernel's create")
        mkdev(tmp, "/devices/virtual/input/" + created.split()[-1])
        q = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        q.connect(sup_path)
        q.settimeout(WAIT)
        q.send(("owned /devices/virtual/input/%s/event5" % created.split()[-1]).encode())
        q2 = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        q2.connect(udev_path)
        q2.settimeout(WAIT)
        q2.send(("owned /devices/virtual/input/%s/event5" % created.split()[-1]).encode())
        note.send(b"go")
        if rx(q, "an answer to udev's question during the create") != b"yes":
            bad.append("supervise: udev asking about %s while it was being created was told no" % created)
        if rx(q2, "an answer on udev's owned socket during the create") != b"yes":
            bad.append("supervise: udev's owned socket asking about %s while it was being created was told no" % created)
        if child.line() != ["CREATE", "a", "0"]:
            bad.append("supervise: UI_DEV_CREATE on the uinput fd did not come back 0")
        try:
            fence = accept(fence_l)
        except (socket.timeout, OSError):
            raise Missing("a connection to the fence")
        msg = rx(fence, "the fence's add for the created uinput device")
        if msg != b"add /devices/virtual/input/input900":
            bad.append("supervise: the fence got %r, not the created device" % msg)
        child.result("open z /dev/zero path")
        got = child.result("create z")
        if got != ["CREATE", "z", "25"]:
            bad.append("supervise: UI_DEV_CREATE's number on an O_PATH fd of another device came back %s, not "
                       "ENOTTY" % got[2:])
        child.result("open r /dev/zero")
        got = child.result("create r")
        if got != ["CREATE", "r", "25"]:
            bad.append("supervise: UI_DEV_CREATE's number on another device came back %s, not ENOTTY" % got[2:])
        got = child.result("create a")
        if got != ["CREATE", "a", "22"]:
            bad.append("supervise: a second create on one open file came back %s, not the kernel's EINVAL" % got[2:])
        child.result("open b /dev/null")
        child.do("create b")
        created, note = notes.take("the mock kernel's second create")
        note.send(b"go")
        try:
            destroyed, _ = notes.take("the destroy of the device whose sysname could not be read")
        except Missing:
            destroyed = ""
        if destroyed != "destroyed input901":
            bad.append("supervise: a device whose sysname could not be read was not destroyed (%r)" % destroyed)
        got = child.line()
        if got != ["CREATE", "b", "5"]:
            bad.append("supervise: a create whose sysname could not be read came back %s, not EIO" % got[2:])
        extra = recv_or_none(fence)
        if extra:
            bad.append("supervise: the fence also got %r for a device nobody created here" % extra)
        if not owned(daemon, sup_path, "/devices/virtual/input/input900/event5"):
            bad.append("supervise: the udev helper says input900 is not owned")
        if owned(daemon, sup_path, "/devices/virtual/input/input901/event6"):
            bad.append("supervise: the udev helper claims input901, which the supervisor destroyed")
        if owned(daemon, sup_path, "/devices/virtual/input/input9000/event7"):
            bad.append("supervise: the udev helper claims input9000 because its name starts with the registered input900")
        if not owned(daemon, udev_path, "/devices/virtual/input/input900/event5"):
            bad.append("supervise: udev's owned socket says input900 is not owned")
        if owned(daemon, udev_path, "/devices/virtual/input/input901/event6"):
            bad.append("supervise: udev's owned socket claims input901, which the supervisor destroyed")
        if os.stat(udev_path).st_mode & 0o777 != 0o600:
            bad.append("supervise: udev's owned socket is mode %o, not 0600" % (os.stat(udev_path).st_mode & 0o777))
        for msg in ("cuse", "pending rhizo-x", "done rhizo-x", "listener"):
            if ask(udev_path, msg, "udev's owned socket's answer to %s" % msg) != b"refused":
                bad.append("supervise: udev's owned socket answered %r, not refused" % msg)
        child.result("open c /dev/null")
        dying = int(child.result("spawn c")[2])
        paused, note = notes.take("the supervisor's pidfd_getfd for the dying caller")
        os.kill(dying, 9)
        for _ in range(WAIT * 20):
            if not os.path.exists("/proc/%d" % dying) or open("/proc/%d/stat" % dying).read().split()[2] == "Z":
                break
            time.sleep(0.05)
        note.send(b"go")
        late = notes.none()
        if late:
            bad.append("supervise: the supervisor created a device for a caller that was gone (%s)" % late)
        u = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        u.connect(sup_path)
        u.settimeout(WAIT)
        u.send(b"pending uhid7:1:1")
        ack = rx(u, "an acknowledgment of the pending uhid create").decode()
        token = ack[3:]
        if not ack.startswith("ok rhizo-uhid-7-") or len(token) != len("rhizo-uhid-7-") + 16:
            bad.append("supervise: a pending uhid create was answered %r, not ok and a token" % ack)
        ident = "HID_ID=0003:00001234:00005678\nHID_NAME=rhizo-lc-own\nHID_UNIQ=u1\n"
        other = "/devices/virtual/misc/uhid/0003:1234:5678.0002"
        mkdev(tmp, other, ident + "HID_PHYS=usb-0000:00:14.0-1/input0\n")
        if owned(daemon, sup_path, other + "/input/input51/event10"):
            bad.append("supervise: a hid device carrying another phys was claimed for this instance's create")
        mkdev(tmp, hid, "DRIVER=hid-generic\n" + ident + "HID_PHYS=%s\n" % token)
        if not owned(daemon, sup_path, hid + "/0003:1234:5678.0001:input/input50/event9"):
            bad.append("supervise: the reported uhid create's input device is not owned before its hid add")
        uev.send(uevent("add", hid, "hid", HID_ID="0003:00001234:00005678", HID_NAME="rhizo-lc-own",
                        HID_PHYS=token, HID_UNIQ="u1"))
        msg = rx(fence, "the fence's add for the uhid create's hid device")
        if msg != ("add " + hid).encode():
            bad.append("supervise: the fence got %r for the uhid create, not its hid device" % msg)
        again = "/devices/virtual/misc/uhid/0003:1234:5678.0003"
        mkdev(tmp, again, ident + "HID_PHYS=%s\n" % token)
        if owned(daemon, sup_path, again + "/input/input52/event11"):
            bad.append("supervise: a second hid device carrying the token was claimed for one create")
        uev.send(uevent("remove", hid, "hid"))
        if recv_or_none(fence, WAIT) != ("del " + hid).encode():
            bad.append("supervise: removing the uhid create's hid device sent the fence no del")
        replay = "/devices/virtual/misc/uhid/0003:1234:5678.0004"
        mkdev(tmp, replay, ident + "HID_PHYS=%s\n" % token)
        uev.send(uevent("add", replay, "hid", HID_PHYS=token))
        if owned(daemon, sup_path, replay + "/input/input53/event12"):
            bad.append("supervise: a hid device replaying a removed device's token was claimed")
        replayed = recv_or_none(fence)
        if replayed:
            bad.append("supervise: a hid device replaying a removed device's token reached the fence: %r" % replayed)
        gone = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        gone.connect(sup_path)
        gone.settimeout(WAIT)
        gone.send(b"pending uhid7:2:1")
        orphan = rx(gone, "the gone broker's token").decode()[3:]
        gone.close()
        owned(daemon, sup_path, "/devices/virtual/input/input999/event1")
        late_hid = "/devices/virtual/misc/uhid/0003:1234:5678.0005"
        mkdev(tmp, late_hid, ident + "HID_PHYS=%s\n" % orphan)
        uev.send(uevent("add", late_hid, "hid", HID_PHYS=orphan))
        if owned(daemon, sup_path, late_hid + "/input/input54/event14"):
            bad.append("supervise: a hid device carrying a token of a broker that closed its connection was claimed")
        orphaned = recv_or_none(fence)
        if orphaned:
            bad.append("supervise: a gone broker's token reached the fence: %r" % orphaned)
        u.send(b"cuse")
        a, fds, _, _ = socket.recv_fds(u, 64, 1)
        if a != b"ok" or not fds:
            bad.append("supervise: the broker asking for the CUSE channel got %r" % a)
        else:
            kernel.send(b"ping")
            if os.read(fds[0], 64) != b"ping":
                bad.append("supervise: the fd handed to the broker is not the CUSE channel")
            os.close(fds[0])
        uev.send(uevent("remove", "/devices/virtual/input/input900", "input"))
        if recv_or_none(fence, WAIT) != b"del /devices/virtual/input/input900":
            bad.append("supervise: removing input900 sent the fence no del")
        child.result("open t /dev/null")
        child.do("thread t")
        try:
            created, note = notes.take("the create from a thread of the caller", timeout=3)
            mkdev(tmp, "/devices/virtual/input/" + created.split()[-1])
            note.send(b"go")
            got = child.line()
            if got != ["CREATE", "t", "0"]:
                bad.append("supervise: a create from a caller's thread came back %s" % got[2:])
        except Missing:
            got = child.line()
            bad.append("supervise: a create from a thread that leads no thread group came back %s, never made: "
                       "the notification names the thread, and pidfd_open takes only a process" % got[2:])
        recv_or_none(fence, 0.5)
        child.result("open d /dev/null")
        child.do("create d")
        created, note = notes.take("the create before the restart")
        mkdev(tmp, "/devices/virtual/input/" + created.split()[-1])
        note.send(b"go")
        child.line()
        before = created.split()[-1]
        recv_or_none(fence, WAIT)
        u.send(b"done uhid7:1:1")
        if sup.poll() is not None:
            bad.append("supervise: the supervisor exited (%s)" % sup.returncode)
        sup.kill()
        sup.wait()
        fence.close()
        os.dup2(stored_listener, 50)
        os.dup2(stored_cuse, 51)
        renv = dict(env, RHIZO_MOCK_FIRST="950", LISTEN_FDS="2", LISTEN_FDNAMES="listener:cuse")
        renv.pop("RHIZO_MOCK_GETFD_PAUSE")
        restarted = supervisor(daemon, tmp, "sup", ["--uevents", os.path.join(tmp, "uev.sock")], env=renv,
                               pass_fds=[50, 51], stderr=log,
                               wrap=[sys.executable, "-c", LISTEN_WRAP])
        os.close(50)
        os.close(51)
        uev = accept(uev_l)
        wait_socket(sup_path)
        for _ in range(WAIT * 20):
            if owned(daemon, sup_path, "/devices/virtual/input/%s/event1" % before):
                break
            time.sleep(0.05)
        else:
            bad.append("supervise: the restarted supervisor has not restored %s from its state file" % before)
        child.result("open e /dev/null")
        child.do("create e")
        try:
            created, note = notes.take("the restarted supervisor's create")
            note.send(b"go")
            got = child.line()
            if got != ["CREATE", "e", "0"]:
                bad.append("supervise: a create after the restart came back %s" % got[2:])
        except Missing:
            bad.append("supervise: the restarted supervisor never took the stored listener")
        u2 = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        u2.connect(sup_path)
        u2.settimeout(WAIT)
        u2.send(b"cuse")
        a, fds, _, _ = socket.recv_fds(u2, 64, 1)
        if a != b"ok" or not fds:
            bad.append("supervise: the restarted supervisor has no CUSE channel for the broker (%r)" % a)
        else:
            kernel.send(b"again")
            if os.read(fds[0], 64) != b"again":
                bad.append("supervise: the restarted supervisor's CUSE channel is not the one it named")
            os.close(fds[0])
    except Missing as e:
        bad.append("supervise: %s never came (supervisor %s)" % (e, sup.poll()))
    except (socket.timeout, OSError) as e:
        bad.append("supervise: the fixture stalled: %s" % e)
    finally:
        if child:
            child.kill()
        for p in (sup, restarted):
            if p:
                p.kill()
                p.wait()
        log.close()
    return bad


def check_supervise_after_load(daemon, mock, tmp):
    """test supervise mode across a policy load"""
    bad = []
    attr, fs = os.path.join(tmp, "attr"), os.path.join(tmp, "selinuxfs")
    os.makedirs(attr)
    os.makedirs(fs)
    cur = os.path.join(attr, "current")

    def set_ctx(ctx):
        """write the current security context"""
        with open(cur, "w") as f:
            f.write(ctx + "\0")
    set_ctx("kernel")
    open(os.path.join(attr, "exec"), "w").close()
    sup_path = os.path.join(tmp, "sup.sock")
    uev_l, fence_l = listen(os.path.join(tmp, "uev.sock")), listen(os.path.join(tmp, "fence.sock"))
    notes = Notes(os.path.join(tmp, "note.sock"))
    notify = notify_socket(os.path.join(tmp, "notify.sock"))
    kernel, served = cuse_pair()
    env = dict(os.environ, LD_PRELOAD=mock, RHIZO_MOCK_UINPUT_RDEV="1:3", RHIZO_MOCK_NOTE=os.path.join(tmp, "note.sock"),
               NOTIFY_SOCKET=os.path.join(tmp, "notify.sock"))
    env.pop("RHIZO_INPUTD_ENTERING", None)
    domain = ["--attr", attr, "--selinuxfs", fs]
    log_path = os.path.join(tmp, "sup.log")
    log = open(log_path, "w")
    sup = supervisor(daemon, tmp, "sup", ["--uevents", os.path.join(tmp, "uev.sock"),
                                         "--cuse-fd", str(served.fileno())] + domain,
                     env=env, pass_fds=[served.fileno()], stderr=log)
    served.close()
    child = restarted = None
    kept = []
    try:
        accept(uev_l)
        rx(kernel, "the supervisor's CUSE_INIT reply")
        stored_cuse = stored(notify, "cuse", "the CUSE channel in the fd store")
        kept.append(stored_cuse)
        wait_socket(sup_path)
        child = Child(sup_path)
        if child.line() != ["FILTER", "listening"]:
            return bad + ["after-load: the deferred supervisor did not take the launcher's listener"]
        stored_listener = stored(notify, "listener", "the seccomp listener in the fd store")
        kept.append(stored_listener)
        set_ctx("u:r:kernel:s0")
        child.result("open a /dev/null")
        child.do("create a")
        try:
            rc = sup.wait(WAIT)
        except subprocess.TimeoutExpired:
            rc = None
        early = notes.none()
        if early is not None:
            bad.append("after-load: a supervisor still u:r:kernel:s0 after the policy load performed a create "
                       "(%s), where pidfd_getfd of the creator is refused and the create answers EPERM" % early)
            return bad
        if rc != 1 or "reason=domain-kernel-after-load" not in open(log_path).read():
            bad.append("after-load: a supervisor still u:r:kernel:s0 after the policy load did not exit for "
                       "Restart= (rc %s): %s" % (rc, open(log_path).read().strip()[-300:]))
            return bad
        set_ctx("u:r:rhizo_inputd:s0")
        os.dup2(stored_listener, 250)
        os.dup2(stored_cuse, 251)
        renv = dict(env, LISTEN_FDS="2", LISTEN_FDNAMES="listener:cuse")
        restarted = supervisor(daemon, tmp, "sup", ["--uevents", os.path.join(tmp, "uev.sock")] + domain,
                               env=renv, pass_fds=[250, 251], stderr=log,
                               wrap=[sys.executable, "-c", LISTEN_WRAP.replace("50", "250").replace("51", "251")])
        os.close(250)
        os.close(251)
        accept(uev_l)
        try:
            _created, note = notes.take("the restarted supervisor's answer to the create left queued")
            note.send(b"go")
            got = child.line()
            if got != ["CREATE", "a", "0"]:
                bad.append("after-load: the queued create came back %s after the restart" % got[2:])
        except Missing:
            bad.append("after-load: the create the exited supervisor left queued was never answered")
    except Missing as e:
        bad.append("after-load: %s never came (supervisor %s)" % (e, sup.poll()))
    except (socket.timeout, OSError) as e:
        bad.append("after-load: the fixture stalled: %s" % e)
    finally:
        if child:
            child.kill()
        for p in (sup, restarted):
            if p and p.poll() is None:
                p.kill()
                p.wait()
        for fd in kept:
            os.close(fd)
        log.close()
        fence_l.close()
    return bad


def fuse_req(opcode, unique, body):
    """return a FUSE request with an opcode, unique id and body"""
    return struct.pack("<IIQQIIIHH", 40 + len(body), opcode, unique, 0, 0, 0, 0, 0, 0) + body


def fuse_reply(data):
    """split a FUSE reply into (error, unique, payload)"""
    length, error, unique = struct.unpack("<IiQ", data[:16])
    return error, unique, data[16:length]


def create2_event(name, uniq):
    """return a UHID create event for a name and unique id"""
    body = struct.pack("<I", UHID_CREATE2)
    body += name.encode().ljust(128, b"\0") + b"".ljust(64, b"\0") + uniq.encode().ljust(64, b"\0")
    body += struct.pack("<HHIIII", 1, 3, 0x1234, 0x5678, 1, 0) + b"\x05"
    return body.ljust(UHID_EVENT_SIZE, b"\0")


def fake_supervisor(sup_l, served):
    """accept a connection and send the CUSE fd"""
    sup = accept(sup_l)
    if rx(sup, "the broker's request for the CUSE channel") != b"cuse":
        raise Missing("a request for the CUSE channel")
    socket.send_fds(sup, [b"ok"], [served.fileno()])
    served.close()
    return sup


TOKEN = b"rhizo-uhid-7-00000000000000ab"
PHYS_AT = 4 + 128


def check_uhid(daemon, tmp, seccomp=True):
    """run rhizo-inputd uhid against a fake kernel"""
    bad = []
    sup_l, uhid_l = listen(os.path.join(tmp, "fsup.sock")), listen(os.path.join(tmp, "uhid.sock"))
    kernel, served = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    kernel.settimeout(WAIT)
    log = open(os.path.join(tmp, "uhid.log"), "w")
    args = [daemon, "uhid", "--instance", "7", "--supervisor", os.path.join(tmp, "fsup.sock"),
            "--uhid", os.path.join(tmp, "uhid.sock")]
    proc = subprocess.Popen(args + ([] if seccomp else ["--no-seccomp"]), stderr=log)
    try:
        sup = fake_supervisor(sup_l, served)
        kernel.send(fuse_req(FUSE_OPEN, 2, struct.pack("<II", 2, 0)))
        err, _, body = fuse_reply(rx(kernel, "the OPEN reply"))
        fh = struct.unpack("<Q", body[:8])[0] if not err else 0
        dev = accept(uhid_l)
        ev = create2_event("rhizo-lc-own", "u1")
        kernel.send(fuse_req(FUSE_WRITE, 3, struct.pack("<QQIIQII", fh, 0, len(ev), 0, 0, 0, 0) + ev))
        pending = rx(sup, "the create's record at the supervisor")
        if not re.fullmatch(rb"pending uhid7:%d:%d" % (proc.pid, fh), pending):
            bad.append("uhid: the supervisor got %r for a UHID_CREATE2, not its tag" % pending)
        early = recv_or_none(dev)
        if early is not None:
            bad.append("uhid: the create reached the kernel before the supervisor acknowledged its identity")
        sup.send(b"ok " + TOKEN)
        got = rx(dev, "the create at the kernel") if early is None else early
        want = ev[:PHYS_AT] + TOKEN.ljust(64, b"\0") + ev[PHYS_AT + 64:]
        if got[PHYS_AT:PHYS_AT + 64] != TOKEN.ljust(64, b"\0"):
            bad.append("uhid: the create reached the kernel with phys %r, not the supervisor's token"
                       % got[PHYS_AT:PHYS_AT + 64].rstrip(b"\0"))
        elif got != want:
            bad.append("uhid: the kernel got %d bytes, not the %d-byte create with only its phys changed"
                       % (len(got), len(ev)))
        err, uniq, body = fuse_reply(rx(kernel, "the create's WRITE reply"))
        if err or struct.unpack("<I", body[:4])[0] != len(ev):
            bad.append("uhid: the create's write answered error %d" % err)
        legacy = struct.pack("<I", 0).ljust(UHID_EVENT_SIZE, b"\0")
        kernel.send(fuse_req(FUSE_WRITE, 4, struct.pack("<QQIIQII", fh, 0, len(legacy), 0, 0, 0, 0) + legacy))
        err, _, _ = fuse_reply(rx(kernel, "the legacy create's WRITE reply"))
        if err != -22:
            bad.append("uhid: a legacy UHID_CREATE answered %d, not EINVAL" % err)
        if recv_or_none(dev) is not None:
            bad.append("uhid: a refused event reached the kernel")
        kernel.send(fuse_req(FUSE_READ, 5, struct.pack("<QQIIQII", fh, 0, UHID_EVENT_SIZE, 0, 0, 0, 0)))
        if recv_or_none(kernel) is not None:
            bad.append("uhid: a blocking read was answered with nothing to read")
        start = struct.pack("<IQ", UHID_START, 0).ljust(UHID_EVENT_SIZE, b"\0")
        dev.send(start)
        got = recv_or_none(kernel, WAIT)
        err, uniq, body = fuse_reply(got) if got else (0, 0, b"")
        if err or uniq != 5 or body != start:
            bad.append("uhid: the waiting read got error %d unique %d, not the kernel's event" % (err, uniq))
        kernel.send(fuse_req(FUSE_POLL, 6, struct.pack("<QQII", fh, 77, FUSE_POLL_SCHEDULE_NOTIFY, 1)))
        err, _, body = fuse_reply(rx(kernel, "the POLL reply"))
        if err or struct.unpack("<I", body[:4])[0] & 1:
            bad.append("uhid: an empty device polled readable")
        dev.send(start)
        got = recv_or_none(kernel, 2)
        err, uniq, body = fuse_reply(got) if got else (0, -1, b"\0" * 8)
        if uniq != 0 or err != FUSE_NOTIFY_POLL or struct.unpack("<Q", body[:8])[0] != 77:
            bad.append("uhid: the kernel's event raised no poll wakeup for kh 77 (got %d/%d)" % (uniq, err))
        kernel.send(fuse_req(FUSE_READ, 7, struct.pack("<QQIIQII", fh, 0, UHID_EVENT_SIZE, 0, 0, 0, 0)))
        rx(kernel, "the READ of the polled event")
        kernel.send(fuse_req(FUSE_READ, 8, struct.pack("<QQIIQII", fh, 0, UHID_EVENT_SIZE, 0, 0, 0, 0)))
        kernel.send(fuse_req(FUSE_INTERRUPT, 9, struct.pack("<Q", 8)))
        got = recv_or_none(kernel, 2)
        err, uniq, _ = fuse_reply(got) if got else (0, -1, b"")
        if uniq != 8 or err != -4:
            bad.append("uhid: an interrupted read answered unique %d error %d, not EINTR" % (uniq, err))
        kernel.send(fuse_req(FUSE_IOCTL, 10, struct.pack("<QIIQII", fh, 0, 0, 0, 0, 0)))
        if fuse_reply(rx(kernel, "the IOCTL reply"))[0] != -25:
            bad.append("uhid: an ioctl was not ENOTTY")
        kernel.send(fuse_req(FUSE_GETATTR, 11, b"\0" * 16))
        if fuse_reply(rx(kernel, "the GETATTR reply"))[0] != -38:
            bad.append("uhid: an opcode it does not serve was not ENOSYS")
        kernel.send(fuse_req(FUSE_RELEASE, 12, struct.pack("<QIIQ", fh, 0, 0, 0)))
        if fuse_reply(rx(kernel, "the RELEASE reply"))[0] != 0:
            bad.append("uhid: RELEASE failed")
        done = rx(sup, "the finished create's done at the supervisor")
        if not done.startswith(b"done uhid7:"):
            bad.append("uhid: releasing a created device sent the supervisor %r, not done" % done)
        if proc.poll() is not None:
            bad.append("uhid: the daemon died (status %s)%s" % (proc.returncode, " under its seccomp filter"
                                                              if seccomp else ""))
    except Missing as e:
        bad.append("uhid: %s never came (daemon %s)" % (e, proc.poll()))
    except (socket.timeout, OSError, struct.error) as e:
        bad.append("uhid: the fixture stalled: %s (daemon %s)" % (e, proc.poll()))
    finally:
        proc.kill()
        proc.wait()
        log.close()
    return bad


def check_uhid_refused(daemon, tmp):
    """run the uhid create refusal case"""
    bad = []
    sup_l, uhid_l = listen(os.path.join(tmp, "rsup.sock")), listen(os.path.join(tmp, "ruhid.sock"))
    kernel, served = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    kernel.settimeout(WAIT)
    proc = subprocess.Popen([daemon, "uhid", "--instance", "7", "--supervisor", os.path.join(tmp, "rsup.sock"),
                             "--uhid", os.path.join(tmp, "ruhid.sock")], stderr=subprocess.DEVNULL)
    try:
        sup = fake_supervisor(sup_l, served)
        kernel.send(fuse_req(FUSE_OPEN, 2, struct.pack("<II", 2, 0)))
        err, _, body = fuse_reply(rx(kernel, "the OPEN reply"))
        fh = struct.unpack("<Q", body[:8])[0] if not err else 0
        dev = accept(uhid_l)
        ev = create2_event("rhizo-lc-own", "u1")
        kernel.send(fuse_req(FUSE_WRITE, 3, struct.pack("<QQIIQII", fh, 0, len(ev), 0, 0, 0, 0) + ev))
        rx(sup, "the create's identity at the supervisor")
        sup.send(b"refused")
        err, _, _ = fuse_reply(rx(kernel, "the refused create's WRITE reply"))
        if err == 0:
            bad.append("uhid: a create the supervisor refused to record was written, not refused")
        if recv_or_none(dev) is not None:
            bad.append("uhid: a create the supervisor refused to record reached the kernel unregistered")
    except Missing as e:
        bad.append("uhid: %s never came in the refused-create case (daemon %s)" % (e, proc.poll()))
    except (socket.timeout, OSError, struct.error) as e:
        bad.append("uhid: the refused-create fixture stalled: %s (daemon %s)" % (e, proc.poll()))
    finally:
        proc.kill()
        proc.wait()
    return bad


def check_uhid_device_open(daemon, tmp):
    """run OPEN on /dev/null under the seccomp filter"""
    sup_l = listen(os.path.join(tmp, "dsup.sock"))
    kernel, served = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    kernel.settimeout(WAIT)
    proc = subprocess.Popen([daemon, "uhid", "--instance", "7", "--supervisor", os.path.join(tmp, "dsup.sock"),
                             "--uhid", "/dev/null"], stderr=subprocess.DEVNULL)
    try:
        sup = fake_supervisor(sup_l, served)
        kernel.send(fuse_req(FUSE_OPEN, 2, struct.pack("<II", 2, 0)))
        err = fuse_reply(rx(kernel, "the OPEN reply"))[0]
        sup.close()
        return [] if err == 0 else ["uhid: opening a real device answered %d" % err]
    except Missing as e:
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(WAIT)
        return ["uhid: %s never came when it opened a real device (daemon %s)" % (e, proc.poll())]
    except (socket.timeout, OSError) as e:
        return ["uhid: the real-device fixture stalled: %s (daemon %s)" % (e, proc.poll())]
    finally:
        proc.kill()
        proc.wait()


def check_broker_refused(daemon, tmp):
    """send the refusal reply and wait for exit"""
    sup_l = listen(os.path.join(tmp, "nsup.sock"))
    proc = subprocess.Popen([daemon, "uhid", "--instance", "7", "--supervisor", os.path.join(tmp, "nsup.sock"),
                             "--uhid", "/dev/null"], stderr=subprocess.DEVNULL)
    try:
        sup = accept(sup_l)
        rx(sup, "the broker's request for the CUSE channel")
        sup.send(b"refused")
        rc = proc.wait(WAIT)
        return [] if rc == 1 else ["uhid: a broker refused its CUSE channel exited %s, not 1" % rc]
    except (Missing, socket.timeout, OSError) as e:
        return ["uhid: %s never came from a broker to be refused" % e]
    except subprocess.TimeoutExpired:
        return ["uhid: a broker refused its CUSE channel kept running"]
    finally:
        proc.kill()
        proc.wait()


def check_broker_supervisor_gone(daemon, tmp):
    """close the supervisor socket and wait for exit"""
    sup_l = listen(os.path.join(tmp, "gsup.sock"))
    kernel, served = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    proc = subprocess.Popen([daemon, "uhid", "--instance", "7", "--supervisor", os.path.join(tmp, "gsup.sock"),
                             "--uhid", "/dev/null"], stderr=subprocess.DEVNULL)
    try:
        sup = fake_supervisor(sup_l, served)
        sup.close()
        rc = proc.wait(WAIT)
        return [] if rc == 1 else ["uhid: a broker whose supervisor went away exited %s, not 1" % rc]
    except (Missing, socket.timeout, OSError) as e:
        return ["uhid: %s never came from a broker whose supervisor goes away" % e]
    except subprocess.TimeoutExpired:
        return ["uhid: a broker whose supervisor went away kept serving"]
    finally:
        proc.kill()
        proc.wait()


def check_supervise_refusals(daemon, tmp):
    """check supervise refusals from other uids"""
    bad = []
    path = os.path.join(tmp, "rsup.sock")
    kernel, served = cuse_pair()
    log = open(os.path.join(tmp, "rsup.log"), "w")
    sup = supervisor(daemon, tmp, "rsup", ["--cuse-fd", str(served.fileno()),
                                           "--broker-cgroup", "/rhizo-inputd-uhid@7.service",
                                           "--listener-uid", str(os.getuid() + 1)],
                     pass_fds=[served.fileno()], stderr=log)
    served.close()
    child = lone = None
    try:
        rx(kernel, "the refusing supervisor's CUSE_INIT reply")
        wait_socket(path)
        if ask(path, "pending uhid9:1:1", "an answer to a pending from outside the broker's cgroup") != b"refused":
            bad.append("supervise: it answered pending from a client that is not this instance's broker")
        if ask(path, "cuse", "an answer to cuse from outside the broker's cgroup") != b"refused":
            bad.append("supervise: it handed the CUSE channel to a client that is not this instance's broker")
        child = Child(path)
        mode = child.line()
        if mode != ["FILTER", "refusing"]:
            bad.append("supervise: it took a listener from uid %d, not the launcher's (%r)" % (os.getuid(), mode))
        child.result("open a /dev/null")
        got = child.result("create a")
        if got != ["CREATE", "a", "38"]:
            bad.append("supervise: a create after a refused handover came back %s, not ENOSYS" % got[2:])
        lone = Child(os.path.join(tmp, "nobody.sock"), wait_s=0)
        mode = lone.line()
        if mode != ["FILTER", "refusing"]:
            bad.append("launcher: with no supervisor the filter was %r, not refusing" % mode)
        lone.result("open a /dev/null")
        got = lone.result("create a")
        if got != ["CREATE", "a", "38"]:
            bad.append("launcher: a create with no supervisor came back %s, not ENOSYS" % got[2:])
    except Missing as e:
        bad.append("supervise: %s never came in the refusal case (supervisor %s)" % (e, sup.poll()))
    except (socket.timeout, OSError) as e:
        bad.append("supervise: the refusal fixture stalled: %s" % e)
    finally:
        for c in (child, lone):
            if c:
                c.kill()
        sup.kill()
        sup.wait()
        log.close()
    return bad


FORGED_OWNED = "x\nRHIZO_MARKER input_owner=y"
FORGED_UNKNOWN = "x RHIZO_MARKER input_owner=registered devpath=/forged"


def forged_lines(log_path):
    """return log lines carrying a marker the supervisor did not write"""
    out = []
    for line in open(log_path):
        own = line.startswith("rhizo-inputd supervise: RHIZO_MARKER input_owner=")
        if line.count("input_owner=") > (1 if own else 0) or line.startswith("RHIZO_MARKER"):
            out.append(line.strip())
    return out


def check_owned_socket(daemon, tmp):
    """check the owned socket's uid, exits and logged text"""
    bad = []
    own = ["--owned-uid", str(os.getuid())]
    for case, flags in (("other-uid", ["--owned-uid", str(os.getuid() + 1)]), ("own-uid", own),
                        ("no-udev", own), ("not-root", [])):
        d = os.path.join(tmp, case)
        os.makedirs(d)
        kernel, served = cuse_pair()
        udev, log_path = os.path.join(d, "udev.sock"), os.path.join(d, "osup.log")
        if case == "no-udev":
            udev = os.path.join(d, "no-udev", "udev.sock")
        log = open(log_path, "w")
        sup = supervisor(daemon, d, "osup", ["--cuse-fd", str(served.fileno()), "--owned-socket", udev] + flags,
                         pass_fds=[served.fileno()], stderr=log, owned_default=True)
        served.close()
        try:
            rx(kernel, "the %s supervisor's CUSE_INIT reply" % case)
            if case in ("no-udev", "not-root"):
                reason = {"no-udev": "reason=no-udev:2", "not-root": "reason=owned-uid-unserved"}[case]
                try:
                    rc = sup.wait(WAIT)
                except subprocess.TimeoutExpired:
                    rc = None
                log.flush()
                text = open(log_path).read()
                if rc != 78 or reason not in text:
                    bad.append("supervise: the %s supervisor did not refuse to start with exit 78 and %s "
                               "(exit %s): %s" % (case, reason, rc, text.strip()[-200:]))
                continue
            wait_socket(udev)
            got = ask(udev, "owned /devices/virtual/input/input1/event1", "the %s answer to owned" % case)
            if case == "other-uid" and got != b"refused":
                bad.append("supervise: udev's owned socket answered uid %d with %r, not refused, under %s"
                           % (os.getuid(), got, " ".join(flags)))
            if case == "own-uid":
                if got != b"no":
                    bad.append("supervise: udev's owned socket answered its own uid %r, not no" % got)
                if ask(udev, FORGED_OWNED, "an answer to a message carrying a log line") != b"refused":
                    bad.append("supervise: udev's owned socket did not refuse a message carrying a log line")
                q = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
                q.connect(os.path.join(d, "osup.sock"))
                q.settimeout(WAIT)
                q.send(FORGED_UNKNOWN.encode())
                q.send(b"owned /devices/virtual/input/input1/event1")
                if rx(q, "the answer after an unknown message") != b"no":
                    bad.append("supervise: the supervisor's socket did not answer owned after an unknown message")
                q.close()
        except Missing as e:
            bad.append("supervise: %s never came in the owned-socket %s case (supervisor %s)" % (e, case, sup.poll()))
        except (socket.timeout, OSError) as e:
            bad.append("supervise: the owned-socket %s fixture stalled: %s" % (case, e))
        finally:
            sup.kill()
            sup.wait()
            log.close()
        for line in forged_lines(log_path):
            bad.append("supervise: a client's message wrote a marker into the log: %r" % line)
    return bad


def wait_ready(notify):
    """wait for the supervisor's READY=1"""
    while "READY=1" not in NOTIFIED:
        try:
            msg, fds, _, _ = socket.recv_fds(notify, 256, 4)
        except (socket.timeout, OSError):
            raise Missing("READY=1")
        NOTIFIED.append(msg.decode())
        for fd in fds:
            os.close(fd)


def default_paths_leg(daemon, tmp):
    """ask a flagless supervisor in a private /run"""
    subprocess.run(["mount", "-t", "tmpfs", "tmpfs", "/run"], check=True, timeout=30)
    os.mkdir("/run/udev")
    mkdev(tmp, "/devices/virtual/input/input77")
    with open(os.path.join(tmp, "owned"), "w") as f:
        f.write("/devices/virtual/input/input77\n")
    kernel, served = cuse_pair()
    notify = notify_socket(os.path.join(tmp, "notify.sock"))
    log = open(os.path.join(tmp, "dsup.log"), "w")
    sup = supervisor(daemon, tmp, "dsup", ["--cuse-fd", str(served.fileno())], pass_fds=[served.fileno()],
                     env=dict(os.environ, NOTIFY_SOCKET=os.path.join(tmp, "notify.sock")), stderr=log,
                     owned_default=True)
    served.close()
    out = {}
    try:
        rx(kernel, "the flagless supervisor's CUSE_INIT reply")
        wait_ready(notify)
        out["sockets"] = sorted(os.listdir("/run/udev"))
        for key, devpath in (("owned", "/devices/virtual/input/input77/event3"),
                             ("other", "/devices/virtual/input/input78/event4")):
            out[key] = subprocess.run([daemon, "owned", devpath], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, timeout=30).returncode
    except (Missing, socket.timeout, OSError) as e:
        out["error"] = str(e)
    finally:
        sup.kill()
        sup.wait()
        log.close()
    print(json.dumps(out))
    return 0


def check_default_paths(daemon, tmp):
    """check the default glob reaches a flagless supervisor"""
    r = subprocess.run(["unshare", "-rm", sys.executable, os.path.abspath(__file__), "--default-paths-leg", daemon, tmp],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0 or not r.stdout.strip():
        return ["default paths: the private /run leg did not run (rc %d): %s" % (r.returncode, r.stderr.strip()[-300:])]
    out = json.loads(r.stdout.strip().splitlines()[-1])
    bad = []
    if "error" in out:
        return ["default paths: %s never came from a supervisor started without --owned-socket" % out["error"]]
    if out["sockets"] != ["rhizo-input-7.sock"]:
        bad.append("supervise: a supervisor started without --owned-socket left %r in /run/udev, not "
                   "rhizo-input-7.sock" % out["sockets"])
    if out["owned"] != 0:
        bad.append("owned: the helper's default glob did not find the supervisor that owns input77")
    if out["other"] != 1:
        bad.append("owned: the helper's default glob claimed input78, which no supervisor owns")
    return bad


SENDER = r'''
import ctypes, socket, subprocess, sys
p = subprocess.Popen(sys.argv[1:], pass_fds=[int(sys.argv[sys.argv.index("--cuse-fd") + 1])],
                     preexec_fn=lambda: ctypes.CDLL(None, use_errno=True).prctl(1, 9))
s = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 15)
s.bind((0, 0))
for line in sys.stdin:
    s.sendto(b"remove@/devices/virtual/input/input77\0ACTION=remove\0DEVPATH=/devices/virtual/input/input77\0"
             b"SUBSYSTEM=input\0", (0, 1))
    print("SENT", flush=True)
p.kill()
p.wait()
'''


def check_uevent_sender(daemon, tmp):
    """send a forged uevent to rhizo-inputd"""
    path = os.path.join(tmp, "nsup.sock")
    kernel, served = cuse_pair()
    mkdev(tmp, "/devices/virtual/input/input77")
    with open(os.path.join(tmp, "owned"), "w") as f:
        f.write("/devices/virtual/input/input77\n")
    args = [daemon, "supervise", "--instance", "7", "--socket", path, "--fence", os.path.join(tmp, "nofence.sock"),
            "--state", os.path.join(tmp, "owned"), "--sys", os.path.join(tmp, "sys"), "--cuse-fd", str(served.fileno()),
            "--owned-socket", os.path.join(tmp, "nsup-udev.sock")]
    proc = subprocess.Popen(["unshare", "-rn", sys.executable, "-c", SENDER] + args, pass_fds=[served.fileno()],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    served.close()
    try:
        rx(kernel, "the namespaced supervisor's CUSE_INIT reply")
        wait_socket(path)
        if not owned(daemon, path, "/devices/virtual/input/input77/event1"):
            return ["netlink: the namespaced supervisor did not restore input77 to start from"]
        proc.stdin.write("send\n")
        proc.stdin.flush()
        if proc.stdout.readline().strip() != "SENT":
            return ["netlink: the forged uevent was never sent (unshare -rn %s)" % proc.poll()]
        if not owned(daemon, path, "/devices/virtual/input/input77/event1"):
            return ["netlink: a forged uevent from a userspace sender released input77"]
        return []
    except Missing as e:
        return ["netlink: %s never came (unshare -rn %s)" % (e, proc.poll())]
    finally:
        try:
            proc.stdin.close()
            proc.wait(WAIT)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()
            proc.wait()


AUDIT = {"x86_64": 0xc000003e, "i386": 0x40000003, "aarch64": 0xc00000b7, "arm": 0x40000028}
NOTIFY, ALLOW = 0x7fc00000, 0x7fff0000
PROGRAM_CASES = (
    ("x86_64", 16, 0x5501, NOTIFY), ("x86_64", 0x40000202, 0x5501, NOTIFY), ("i386", 54, 0x5501, NOTIFY),
    ("aarch64", 29, 0x5501, NOTIFY), ("arm", 54, 0x5501, NOTIFY),
    ("x86_64", 16, 0x1_0000_5501, NOTIFY),
    ("x86_64", 16, 0x5502, ALLOW), ("x86_64", 1, 0x5501, ALLOW), ("aarch64", 16, 0x5501, ALLOW),
    ("x86_64", 16, 0x80045501, ALLOW),
)


def run_program(prog, arch, nr, cmd):
    """run a BPF seccomp program on an ioctl"""
    data = struct.pack("<iIQ6Q", nr, arch, 0, 3, cmd, 0, 0, 0, 0)
    a, pc = 0, 0
    for _ in range(len(prog) // 8 + 1):
        code, jt, jf, k = struct.unpack("<HBBI", prog[pc * 8:pc * 8 + 8])
        if code == 0x20:
            a = struct.unpack("<I", data[k:k + 4])[0]
            pc += 1
        elif code == 0x15:
            pc += 1 + (jt if a == k else jf)
        elif code == 0x06:
            return k
        else:
            return "bad opcode %#x" % code
    return "no return"


def check_program(prog):
    """check the launcher filter against PROGRAM_CASES"""
    bad = []
    for arch, nr, cmd, want in PROGRAM_CASES:
        got = run_program(prog, AUDIT[arch], nr, cmd)
        if got != want:
            bad.append("filter: %s nr %#x cmd %#x returns %s, not %s" % (
                arch, nr, cmd, got if isinstance(got, str) else hex(got), "NOTIFY" if want == NOTIFY else "ALLOW"))
    return bad


def check_udev_rule(text):
    """check the input-add block of the udev rule"""
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    bad = []
    try:
        start = lines.index('ACTION!="add|change", GOTO="rhizo_uinput_end"')
        end = lines.index('LABEL="rhizo_uinput_end"')
    except ValueError:
        return ["udev: 70-rhizo-uinput.rules lost its input-add block"]
    block = lines[start:end]
    if 'SUBSYSTEM!="input", GOTO="rhizo_uinput_end"' not in block:
        bad.append("udev: the block is no longer limited to the input subsystem")
    if OWNED_LINE not in block:
        bad.append("udev: no rule asks rhizo-inputd whether it created a device and hides it from libinput")
    if 'KERNEL=="uhid", GROUP="rhizo-uhid", MODE="0660"' not in lines:
        bad.append("udev: /dev/uhid is not group rhizo-uhid")
    if any(l.startswith('KERNEL=="cuse"') and "GROUP" in l for l in lines):
        bad.append("udev: /dev/cuse is reachable by a group")
    return bad


FILTER_TEST = ("    if core.uinput_filtered():\n        _filter = install_uinput_filter(_sup)\n")
FILTER_FATAL = ("        if not _filter:\n            kmsg(\"FATAL: no uinput filter could be installed -- refusing to exec init "
                "with /dev/uinput unfiltered\")\n            os._exit(1)\n")


def check_launcher_filter(text):
    """check the launcher installs the uinput filter"""
    bad = []
    if FILTER_TEST not in text:
        bad.append("launcher: the uinput filter is not installed whenever devices.uinput is allowed")
    if FILTER_FATAL not in text:
        bad.append("launcher: init is exec'd even when no uinput filter could be installed")
    if text.count("core.set_uinput_filtered(True)") != 2:
        bad.append("launcher: not both starts (the first one and the joiner) require the uinput filter")
    return bad


def launcher_module():
    """return the rootfs module imported with its output silenced"""
    os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-inputd")
    sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
    with contextlib.redirect_stdout(io.StringIO()):
        from sandbox import rootfs
    return rootfs


def run_all(src_text):
    """build the daemon and run every check against it"""
    with tempfile.TemporaryDirectory() as tmp:
        try:
            daemon, mock = build(tmp, src_text)
        except RuntimeError as e:
            return [str(e)]
        mode_file = os.path.join(tmp, "selinux-mode")
        with open(mode_file, "w") as f:
            f.write("host\n")
        os.environ["RHIZO_SELINUX_MODE_FILE"] = mode_file
        s = os.path.join(tmp, "s")
        u = os.path.join(tmp, "u")
        os.makedirs(s)
        os.makedirs(u)
        r, n, k = os.path.join(tmp, "r"), os.path.join(tmp, "n"), os.path.join(tmp, "k")
        os.makedirs(r)
        os.makedirs(n)
        os.makedirs(k)
        o, d = os.path.join(tmp, "o"), os.path.join(tmp, "d")
        os.makedirs(o)
        os.makedirs(d)
        return (check_supervise(daemon, mock, s) + check_supervise_after_load(daemon, mock, k)
                + check_supervise_refusals(daemon, r) + check_owned_socket(daemon, o) + check_default_paths(daemon, d)
                + check_uevent_sender(daemon, n)
                + check_uhid(daemon, u) + check_uhid_refused(daemon, u) + check_uhid_device_open(daemon, u)
                + check_broker_refused(daemon, u) + check_broker_supervisor_gone(daemon, u))


MUTATIONS = (
    ("unregistered-create", "\t\t\tif (own(devpath, by) < 0)\n\t\t\t\te = ENOSPC;\n", "", "was told no"),
    ("prefix-match", "(devpath[n] == 0 || devpath[n] == '/')", "1", "its name starts with the registered"),
    ("refused-create-written", "if (type == UHID_CREATE2 && report_create(wi->fh, data, wi->size) < 0) {",
     "if (type == UHID_CREATE2 && (report_create(wi->fh, data, wi->size), 0)) {",
     "refused to record reached the kernel"),
    ("create-any-device", "!S_ISCHR(st.st_mode) || st.st_rdev != g_uinput_rdev", "0",
     "not ENOTTY"),
    ("identity-after-write",
     "\tif (type == UHID_CREATE2 && report_create(wi->fh, data, wi->size) < 0) {\n\t\treport_done(wi->fh);\n"
     "\t\treply(unique, -EIO, NULL, 0);\n\t\treturn;\n\t}\n\tssize_t n = write(h->fd, data, wi->size);\n",
     "\tssize_t n = write(h->fd, data, wi->size);\n\tif (type == UHID_CREATE2)\n\t\treport_create(wi->fh, data, wi->size);\n",
     "reached the kernel before the supervisor acknowledged"),
    ("any-event-type", "return t == UHID_CREATE2 ||", "return 1 ||", "a legacy UHID_CREATE answered"),
    ("read-never-waits", "\tif (g_h[ri->fh].nonblock) {", "\tif (1) {", "a blocking read was answered"),
    ("interrupt-ignored", "\t\t\treply(ii->unique, -EINTR, NULL, 0);\n", "", "an interrupted read"),
    ("no-poll-wakeup", "\t\t\t\tnotify_poll(g_h[i].kh);\n", "\t\t\t\tif (0) notify_poll(g_h[i].kh);\n",
     "raised no poll wakeup"),
    ("seccomp-misses-openat", "__NR_openat, ", "", "when it opened a real device (daemon -31)"),
    ("seccomp-misses-sendmsg", "__NR_sendmsg, ", "", "(daemon -31)"),
    ("remove-ignored", "\t\tdisown(devpath);\n\t\tfor (int i = 0; i < MAX_PENDING; i++)", "\t\tfor (int i = 0; i < MAX_PENDING; i++)",
     "removing input900 sent the fence no del"),
    ("uhid-one-to-many", "p->used && !p->devpath[0] && !strcmp(p->token, phys)", "p->used && !strcmp(p->token, phys)",
     "a second hid device carrying the token"),
    ("token-ignored", "!strcmp(p->token, phys)", "1", "carrying another phys was claimed"),
    ("phys-kept", "\tmemcpy(ev + at, token, strlen(token));\n", "", "not the supervisor's token"),
    ("no-id-valid", "} else if (ioctl(listener, SECCOMP_IOCTL_NOTIF_ID_VALID, &req->id) < 0) {", "} else if (0) {",
     "created a device for a caller that was gone"),
    ("create-failure-registers", "} else if (ioctl(target, UI_DEV_CREATE) < 0) {",
     "} else if ((ioctl(target, UI_DEV_CREATE), 0)) {", "a second create on one open file"),
    ("sysname-failure-kept", "\t\t\te = EIO;\n", "", "sysname could not be read was not destroyed"),
    ("continue-other", "\t\tresp->error = -ENOTTY;\n\t\tresp->val = -1;\n",
     "\t\tresp->flags = SECCOMP_USER_NOTIF_FLAG_CONTINUE;\n", "on an O_PATH fd of another device"),
    ("listener-any-uid", "&& peer_uid(c) != g_listener_uid", "&& 0", "it took a listener from uid"),
    ("broker-unchecked", "\tif (!cl->broker) {", "\tif (0) {", "from a client that is not this instance's broker"),
    ("listener-not-stored", 'if (fdstore("listener", fd) < 0 && errno != ENOENT)', "if (0 && errno != ENOENT)",
     "the seccomp listener in the fd store never came"),
    ("stored-not-adopted", "strtol(pid, NULL, 10) != (long)getpid())\n", "strtol(pid, NULL, 10) != (long)getpid() || 1)\n",
     "restarted supervisor"),
    ("state-not-loaded", 'FILE *f = g_state_path ? fopen(g_state_path, "re") : NULL;', "FILE *f = NULL;",
     "has not restored"),
    ("never-ready", 'if (sd_notify_fd("READY=1", -1) < 0 && errno != ENOENT)', "if (0)",
     "never told systemd it was ready"),
    ("liveness-by-signal", "pidfd_pid(pidfd) != (int)cr.pid",
     "(pidfd_pid(pidfd) != (int)cr.pid || syscall(424, pidfd, 0, NULL, 0) < 0)",
     "a pending uhid create was answered"),
    ("token-rearmed", "\t\t\t\tg_pending[i].used = 0;\n\t\treturn;\n", "\t\t\t\tg_pending[i].devpath[0] = 0;\n\t\treturn;\n",
     "replaying a removed device's token"),
    ("broker-close-kept", "\t\t\t\t\tif (g_pending[k].used && g_pending[k].client == clients[i].fd)\n",
     "\t\t\t\t\tif (0)\n", "a broker that closed its connection"),
    ("supervisor-gone-ignored", "\t\tif (pf[1 + MAX_HANDLES].revents) {", "\t\tif (0) {",
     "a broker whose supervisor went away kept serving"),
    ("cuse-init-short-read", "uint8_t buf[FUSE_MIN_READ_BUFFER];", "uint8_t buf[4096];",
     "a CUSE read buffer below FUSE_MIN_READ_BUFFER"),
    ("kernel-after-load-answers", "\t\t\trz_log(\"poll failed: errno=%d\", errno);\n\t\t\treturn 1;\n\t\t}\n\t\texit_if_kernel_after_load();\n",
     "\t\t\trz_log(\"poll failed: errno=%d\", errno);\n\t\t\treturn 1;\n\t\t}\n",
     "performed a create (created input900)"),
    ("kernel-after-load-deferred-forgotten", "\t\tg_deferred_ctx = ctx;\n", "",
     "performed a create (created input900)"),
    ("tid-as-pid", "pidfd = (int)syscall(__NR_pidfd_open, tgid, 0);",
     "pidfd = (int)syscall(__NR_pidfd_open, req->pid, 0);", "leads no thread group"),
    ("uevent-any-sender", "(g_uevent_netlink && from.nl_pid != 0)", "0", "a forged uevent from a userspace sender"),
    ("owned-socket-not-default", "snprintf(owned_default, sizeof(owned_default), OWNED_SOCKET_FMT, g_instance);",
     'snprintf(owned_default, sizeof(owned_default), "/run/rhizo-input-%u.sock", g_instance);',
     "started without --owned-socket left [] in /run/udev"),
    ("default-glob-elsewhere", '"/run/udev/rhizo-input-*.sock", *owned_sock', '"/run/rhizo-input-*/supervisor.sock", *owned_sock',
     "the helper's default glob did not find"),
    ("owned-any-uid", "peer_uid(c) != g_owned_uid || ", "", "not refused, under --owned-uid"),
    ("owned-any-verb", ' || strncmp(msg, "owned ", 6))) {', ")) {", "owned socket answered 'cuse', not refused"),
    ("log-unescaped", "out[i] = isalnum((unsigned char)in[i]) || strchr(\"/._:-@+,\", in[i]) ? in[i] : '?';",
     "out[i] = in[i];", "wrote a marker into the log"),
    ("log-keeps-key-value", 'strchr(\"/._:-@+,\", in[i])', 'strchr(\"/._:-@+, =\", in[i])', "wrote a marker into the log"),
    ("owned-uid-own", "\t\t\tg_owned_uid = 0;", "\t\t\tg_owned_uid = (int)getuid();", "reason=owned-uid-unserved"),
    ("non-root-serves", "if (g_owned_uid == 0 && geteuid() != 0) {", "if (0) {", "reason=owned-uid-unserved"),
    ("no-udev-restarts", "return e == ENOENT ? NO_UDEV_EXIT : 1;", "return 1;", "reason=no-udev:2"),
    ("broker-ignores-refusal", "\tg_cuse = take_cuse();\n\tif (g_cuse < 0)\n\t\treturn 1;\n", "\tg_cuse = take_cuse();\n",
     "a broker refused its CUSE channel"),
)


LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")


def run():
    """run every check and print the problems"""
    bad = check_program(launcher_module().uinput_notify_program()) + check_udev_rule(open(RULE).read())
    bad += check_launcher_filter(open(LAUNCHER).read())
    bad += run_all(open(SRC).read())
    for b in bad:
        say(b)
    if bad:
        return 1
    print("check-inputd: ok -- a uinput create through the seccomp notification and a uhid create through "
          "CUSE are each registered with the fence, exactly once, before udev can ask")
    return 0


def selftest():
    """run the inputd checks against mutated sources"""
    fails = []
    src = open(SRC).read()
    good = run_all(src)
    if good:
        fails.append("the real source fails: %s" % good[0])
    applies = [m for m in MUTATIONS if src.count(m[1]) == 1]
    fails += ["%s: the mutation no longer applies to inputd.c" % m[0] for m in MUTATIONS if m not in applies]
    with concurrent.futures.ProcessPoolExecutor(max_workers=8) as pool:
        gots = list(pool.map(run_all, [src.replace(old, new) for _, old, new, _ in applies]))
    for (name, _old, _new, needle), got in zip(applies, gots):
        if not any(needle in g for g in got):
            fails.append("%s: did not flag %r (got %s)" % (name, needle, got[:2] or "nothing"))
    rule = open(RULE).read()
    if check_udev_rule(rule):
        fails.append("the udev rule fails: %s" % check_udev_rule(rule)[0])
    for label, text, needle in (
            ("no-owned-line", rule.replace(OWNED_LINE, ""), "no rule asks rhizo-inputd"),
            ("owned-outside-block", rule.replace(OWNED_LINE, "").replace('LABEL="rhizo_uinput_end"',
                                                                         'LABEL="rhizo_uinput_end"\n' + OWNED_LINE),
             "no rule asks rhizo-inputd"),
            ("cuse-to-group", rule + '\nKERNEL=="cuse", GROUP="rhizo-uhid", MODE="0660"\n', "/dev/cuse is reachable"),
            ("uhid-root-only", rule.replace('KERNEL=="uhid", GROUP="rhizo-uhid", MODE="0660"', ""), "/dev/uhid is not")):
        if not any(needle in f for f in check_udev_rule(text)):
            fails.append("udev %s: did not flag %r" % (label, needle))
    launcher = open(LAUNCHER).read()
    if check_launcher_filter(launcher):
        fails.append("the launcher fails: %s" % check_launcher_filter(launcher)[0])
    for label, text, needle in (
            ("test-on-supervisor", launcher.replace(FILTER_TEST, FILTER_TEST.replace(
                "core.uinput_filtered()", "_sup is not None")), "whenever devices.uinput is allowed"),
            ("exec-unfiltered", launcher.replace(FILTER_FATAL, ""), "exec'd even when no uinput filter"),
            ("joiner-unfiltered", launcher.replace("core.set_uinput_filtered(True)", "pass", 1), "not both starts")):
        if not any(needle in f for f in check_launcher_filter(text)):
            fails.append("launcher %s: did not flag %r" % (label, needle))
    rm = launcher_module()
    if check_program(rm.uinput_notify_program()):
        fails.append("the launcher's filter fails: %s" % check_program(rm.uinput_notify_program())[0])
    saved = dict(rm._IOCTL_NR)
    for label, change, needle in (
            ("no-aarch64", lambda d: d.pop(0xc00000b7), "aarch64 nr 0x1d cmd 0x5501 returns 0x7fff0000"),
            ("no-x32", lambda d: d.__setitem__(0xc000003e, (16,)), "x86_64 nr 0x40000202"),
            ("wrong-nr", lambda d: d.__setitem__(0xc000003e, (17, 0x40000000 | 514)), "x86_64 nr 0x10")):
        try:
            change(rm._IOCTL_NR)
            got = check_program(rm.uinput_notify_program())
        finally:
            rm._IOCTL_NR.clear()
            rm._IOCTL_NR.update(saved)
        if not any(needle in g for g in got):
            fails.append("filter %s: did not flag %r (got %s)" % (label, needle, got[:1] or "nothing"))
    for f in fails:
        say("selftest: " + f)
    if fails:
        return 1
    print("check-inputd: selftest ok (%d mutations)" % len(MUTATIONS))
    return 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--default-paths-leg"]:
        sys.exit(default_paths_leg(sys.argv[2], sys.argv[3]))
    with contextlib.suppress(KeyboardInterrupt):
        sys.exit(selftest() if "--selftest" in sys.argv[1:] else run())
