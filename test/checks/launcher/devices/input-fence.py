#!/usr/bin/env python3
import ast
import contextlib
import io
import os
import re
import stat
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
AOSP = os.path.join(REPO, "aosp-android16-qpr2")
POLICY = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
UINPUT = os.path.join(REPO, "src", "android", "hal", "graphics-composer", "src", "input", "uinput.cpp")
CLAIMS = os.path.join(REPO, "test", "system", "cycle", "claims-server.sh")
COMPOSER_RC = os.path.join(REPO, "src", "androidd", "guest", "init", "composer.rc")

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-input-fence")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import core  # noqa: E402
    from sandbox import rootfs  # noqa: E402


def say(msg):
    """print a message prefixed with the check name to stderr"""
    print("check-input-fence: %s" % msg, file=sys.stderr)


PREMISE = (
    ("system/core/init/devices.cpp",
     r"if \(mknod\(path\.c_str\(\), mode, dev\) && \(errno == EEXIST\) && !secontext\.empty\(\)\) \{"
     r".*?\nout:\n\s*if \(chown\(path\.c_str\(\), uid, new_group\) < 0\) \{\s*"
     r"PLOG\(ERROR\) << \"Cannot chown \"",
     "MakeDevice no longer answers a refused mknod with one chown and a log line"),
    ("system/core/init/devices.cpp",
     r"if \(setegid\(AID_ROOT\)\) \{\s*PLOG\(FATAL\)",
     "MakeDevice's only abort is no longer the setegid back to root"),
    ("system/core/rootdir/ueventd.rc",
     r"subsystem input\s+devname uevent_devpath\s+dirname /dev/input\b",
     "ueventd.rc no longer puts input nodes in /dev/input"),
    ("system/core/rootdir/ueventd.rc",
     r"\n/dev/input/\*\s+0660\s+root\s+input\n",
     "ueventd.rc's /dev/input/* is no longer 0660 root input"),
    ("system/sepolicy/private/domain.te",
     r"neverallow \{\s*domain\s*-kernel\s*-init\s*-ueventd\s*-vold\s*\} self:global_capability_class_set mknod;",
     "domain.te no longer limits the mknod capability to kernel, init, ueventd and vold"),
    ("system/sepolicy/private/domain.te",
     r"neverallow ~dac_override_allowed self:global_capability_class_set dac_override;",
     "domain.te no longer neverallows dac_override outside its fixed list"),
)


def check_premise(aosp):
    """return the premise problems for the AOSP sources"""
    bad = []
    for rel, pat, why in PREMISE:
        try:
            text = open(os.path.join(aosp, rel)).read()
        except OSError as e:
            bad.append("premise: cannot read %s (%s)" % (rel, e.strerror))
            continue
        if not re.search(pat, text, re.S):
            bad.append("premise: %s -- %s" % (rel, why))
    return bad


def cil_forms(text):
    """parse a CIL file into nested lists"""
    text = re.sub(r";[^\n]*", "", text)
    stack, cur = [], []
    for tok in re.findall(r"\(|\)|[^\s()]+", text):
        if tok == "(":
            stack.append(cur)
            cur = []
        elif tok == ")":
            done, cur = cur, stack.pop()
            cur.append(done)
        else:
            cur.append(tok)
    return cur


def rules(forms, kind, src, tgt, cls):
    """return the permission sets of matching rules"""
    out = []
    for f in forms:
        if (isinstance(f, list) and len(f) == 4 and f[0] == kind and f[1] == src and f[2] == tgt
                and isinstance(f[3], list) and len(f[3]) == 2 and f[3][0] == cls):
            out.append(set(f[3][1]))
    return out


NEEDED = (("chr_file", {"create", "getattr", "setattr", "unlink"}),
          ("dir", {"search", "write", "add_name", "remove_name", "watch"}))


UINPUT_CREATORS = ("shell", "system_server", "rhizo_composer")
UHID_ONLY = ("bluetooth", "hal_bluetooth", "virtual_touchpad")


def check_policy(text):
    """check the CIL rules for the input fence"""
    forms = cil_forms(text)
    bad = []
    for label in ("hidraw_device", "usb_device"):
        if not any("create" in p for p in rules(forms, "deny", "ueventd", label, "chr_file")):
            bad.append("policy: no (deny ueventd %s (chr_file (create))) for the %s node"
                       % (label, "hidraw" if label == "hidraw_device" else "usbfs"))
    if not any("create" in p for p in rules(forms, "deny", "ueventd", "input_device", "chr_file")):
        bad.append("policy: no (deny ueventd input_device (chr_file (create)))")
    if any("create" in p for p in rules(forms, "allow", "ueventd", "input_device", "chr_file")):
        bad.append("policy: an allow names ueventd input_device chr_file create outright")
    for dom in ("kernel", "rhizo_host"):
        for cls, want in NEEDED:
            have = set().union(*rules(forms, "allow", dom, "input_device", cls))
            if not want <= have:
                bad.append("policy: %s lacks %s on input_device %s" % (dom, " ".join(sorted(want - have)), cls))
        if not any("create" in p for p in rules(forms, "allow", dom, "self", "netlink_kobject_uevent_socket")) \
                and dom == "kernel":
            bad.append("policy: kernel may not create its uevent socket")
    for dom in ("kernel", "rhizo_host"):
        for tgt, cls, want in (("hidraw_device", "chr_file", {"unlink"}), ("usb_device", "chr_file", {"unlink"}),
                               ("device", "dir", {"remove_name", "watch", "read"}),
                               ("usb_device", "dir", {"remove_name", "watch", "read"})):
            have = set().union(*rules(forms, "allow", dom, tgt, cls))
            if not want <= have:
                bad.append("policy: %s lacks %s on %s %s" % (dom, " ".join(sorted(want - have)), tgt, cls))
    for dom in UINPUT_CREATORS:
        for cls, perm in (("process", "ptrace"), ("fd", "use")):
            if not any(perm in p for p in rules(forms, "allow", "rhizo_inputd", dom, cls)):
                bad.append("policy: rhizo_inputd lacks %s %s over %s, a uinput creator (%s)" % (cls, perm, dom, dom))
    for dom in UHID_ONLY:
        if any("ptrace" in p for p in rules(forms, "allow", "rhizo_inputd", dom, "process")):
            bad.append("policy: rhizo_inputd may ptrace %s, which creates no uinput device" % dom)
    for dom in UINPUT_CREATORS + UHID_ONLY:
        if any("ptrace" in p for p in rules(forms, "allow", "rhizo_host", dom, "process")):
            bad.append("policy: rhizo_host, every host service, may ptrace %s" % dom)
    if not {"ioctl", "read", "write"} <= set().union(*rules(forms, "allow", "rhizo_inputd", "uhid_device", "chr_file")):
        bad.append("policy: rhizo_inputd may not ioctl a uinput fd it took")
    for dom, mine, other in (("rhizo_uhidd", "rhizo_uhid_host_device", "rhizo_cuse_host_device"),
                             ("rhizo_inputd", "rhizo_cuse_host_device", "rhizo_uhid_host_device")):
        if "open" not in set().union(*rules(forms, "allow", dom, mine, "chr_file")):
            bad.append("policy: %s may not open %s" % (dom, mine))
        if "open" in set().union(*rules(forms, "allow", dom, other, "chr_file")):
            bad.append("policy: %s may open %s too" % (dom, other))
        if rules(forms, "allow", dom, "rhizo_host_device", "chr_file"):
            bad.append("policy: %s holds rhizo_host_device, every host char node" % dom)
    comp_dir = set().union(*rules(forms, "allow", "rhizo_composer", "input_device", "dir"))
    comp_chr = set().union(*rules(forms, "allow", "rhizo_composer", "input_device", "chr_file"))
    if "watch" not in comp_dir:
        bad.append("policy: rhizo_composer has no watch on /dev/input")
    if comp_chr & {"create", "unlink"} or comp_dir & {"remove_name"}:
        bad.append("policy: rhizo_composer may still %s an input node" % " ".join(sorted(comp_chr & {"create", "unlink"}
                                                         | comp_dir & {"remove_name"})))
    if not any("chown" in p for p in rules(forms, "allow", "kernel", "self", "capability")):
        bad.append("policy: kernel lacks the chown capability")
    for dom in ("kernel", "rhizo_host"):
        birth = hidraw_birth_label(forms, dom)
        for tgt, cls, want in (("device", "dir", {"add_name"}),
                               (birth, "chr_file", {"create", "relabelfrom", "unlink"}),
                               ("hidraw_device", "chr_file", {"relabelto", "setattr"})):
            have = set().union(*rules(forms, "allow", dom, tgt, cls))
            if not want <= have:
                bad.append("policy: %s lacks %s on %s %s (hidraw birth label %s)"
                           % (dom, " ".join(sorted(want - have)), tgt, cls, birth))
    return bad


def hidraw_birth_label(forms, dom):
    """return the birth type of a hidraw node"""
    for f in forms:
        if isinstance(f, list) and len(f) == 5 and f[:4] == ["typetransition", dom, "device", "chr_file"]:
            return f[4]
    return "device"


def uevent(action, devpath, **kv):
    """build a kernel uevent datagram"""
    fields = ["%s@%s" % (action, devpath), "ACTION=" + action, "DEVPATH=" + devpath]
    fields += ["%s=%s" % (k, v) for k, v in kv.items()]
    return "\0".join(fields).encode() + b"\0"


def evdev_add(devpath, event, minor, action="add"):
    """build the uevent for an evdev node"""
    return uevent(action, "%s/%s" % (devpath, event), SUBSYSTEM="input", MAJOR=13, MINOR=minor,
                  DEVNAME="input/" + event)


def hidraw_add(hid, name, minor, action="add"):
    """return a hidraw uevent for a device"""
    return uevent(action, "%s/hidraw/%s" % (hid, name), SUBSYSTEM="hidraw", MAJOR=245, MINOR=minor,
                  DEVNAME=name)


class Dev:
    """fake /dev for fence tests"""

    def __init__(self, label=None, fail=(), relabel_fail=False, dirs=None, race=None):
        """set up the fake /dev state"""
        self.nodes, self.label, self.fail = {}, label, set(fail)
        self.race = dict(race or {})
        self.relabel_fail, self.calls = relabel_fail, []
        self.dirs = dirs or {}
        self.mask = 0o022
        self.births = {}

    def umask(self, mask):
        """set the mask and return the previous one"""
        old, self.mask = self.mask, mask
        return old

    def lstat(self, p):
        """return the mode and device of a fixture node, or raise FileNotFoundError"""
        if p not in self.nodes:
            raise FileNotFoundError(2, "No such file", p)
        n = self.nodes[p]
        return types.SimpleNamespace(st_mode=n["mode"], st_rdev=n["dev"])

    def mknod(self, p, mode, dev):
        """create a fixture node, failing for paths set to fail"""
        if p in self.fail:
            raise PermissionError(13, "Permission denied", p)
        if p in self.race:
            self.nodes[p] = self.race.pop(p)
        if p in self.nodes:
            raise FileExistsError(17, "File exists", p)
        dmode, dgid = self.dirs.get(os.path.dirname(p), (0o755, 0))
        gid = dgid if dmode & stat.S_ISGID else 0
        mode = stat.S_IFMT(mode) | (stat.S_IMODE(mode) & ~self.mask)
        self.nodes[p] = {"mode": mode, "dev": dev, "uid": 0, "gid": gid, "label": self.born(p)}
        self.births[p] = (stat.S_IMODE(mode), 0, gid)
        self.calls.append(("mknod", p))

    @staticmethod
    def born(p):
        """return the label a new node is born with"""
        return "u:object_r:input_device:s0" if p.startswith("/dev/input/") else "u:object_r:device:s0"

    def setxattr(self, p, name, value):
        """set a fixture node's label"""
        self.lstat(p)
        if self.relabel_fail:
            raise PermissionError(13, "Permission denied", p)
        self.nodes[p]["label"] = value.decode().rstrip("\0")
        self.calls.append(("setxattr", p))

    def unlink(self, p):
        """remove a fixture node"""
        self.lstat(p)
        del self.nodes[p]

    def chown(self, p, uid, gid):
        """set a fixture node's owner"""
        self.nodes[p].update(uid=uid, gid=gid)
        self.calls.append(("chown", p))

    def chmod(self, p, mode):
        """set a fixture node's permission bits"""
        self.nodes[p]["mode"] = stat.S_IFMT(self.nodes[p]["mode"]) | mode

    def getxattr(self, p, name):
        """return a fixture node's label"""
        self.lstat(p)
        label = self.label or self.nodes[p].get("label") or self.born(p)
        return (label + "\0").encode()

    def listdir(self, d):
        """return the names under a directory"""
        out = {p[len(d) + 1:].split("/", 1)[0] for p in self.nodes if p.startswith(d + "/")}
        if not out:
            raise FileNotFoundError(2, "No such file or directory", d)
        return sorted(out)


def feed(rm, steps, dev=None, fence=None):
    """run steps through InputFence"""
    dev = dev or Dev()
    fence = fence or rm.InputFence("/nonexistent-sys")
    log = []
    for step in steps:
        if isinstance(step, tuple):
            decisions = fence.register(step[1], step[2])
        else:
            ev = rm.parse_uevent(step)
            decisions = fence.decide(ev) if ev else []
        for d in decisions:
            rm.apply_input_decision(fence, d, "", log.append, dev)
    return dev, log, fence


VIRTUAL = "/devices/virtual/input"
UHID = "/devices/virtual/misc/uhid/0003:1234:5678.0001"
USB_KBD = "/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:046D:C31C.0001/input/input20"
USB_HID = "/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2:1.0/0003:046D:C31C.0001"


def node_is(dev, path, minor, mode, uid, gid, major=13):
    """return why a node does not match, or None"""
    n = dev.nodes.get(path)
    if n is None:
        return "was never published"
    got = (stat.S_IMODE(n["mode"]), n["uid"], n["gid"], n["dev"])
    want = (mode, uid, gid, os.makedev(major, minor))
    return None if got == want else "is %o %d:%d dev %d, not %o %d:%d dev %d:%d" % (got + (mode, uid, gid, major, minor))


def dev_input_dir(rm):
    """return the mode and gid of /dev/input"""
    src = getattr(rm, "__source__", None) or open(rm.__file__).read()
    m = DEV_INPUT_MOUNT.search(src)
    opts = dict(o.partition("=")[::2] for o in (m.group(1) if m else "").split(",") if o)
    return {"/dev/input": (int(opts.get("mode", "1777"), 8), int(opts.get("gid", "0")))}


def check_fence(rm):
    """check InputFence against fake uevents"""
    bad = []
    steps = [evdev_add(VIRTUAL + "/input10", "event4", 68),
             ("reg", "add", VIRTUAL + "/input10"),
             evdev_add(UHID + "/0003:1234:5678.0001:input/input11", "event5", 69),
             hidraw_add(UHID, "hidraw1", 1),
             ("reg", "add", UHID),
             evdev_add(USB_KBD, "event6", 70),
             hidraw_add(USB_HID, "hidraw0", 0),
             evdev_add(VIRTUAL + "/input12", "event7", 71),
             uevent("add", VIRTUAL + "/input10/event99", SUBSYSTEM="input", MAJOR=116, MINOR=24,
                    DEVNAME="input/event99"),
             b"libudev\0\xfe\xed\xca\xfe" + evdev_add(VIRTUAL + "/input10", "event10", 74)]
    dev, log, fence = feed(rm, steps, Dev(dirs=dev_input_dir(rm)))
    for path, what in (("/dev/input/event4", "the composer's own device"),
                       ("/dev/input/event5", "Android's own uhid device")):
        born = dev.births.get(path)
        if born is not None and born != (0o660, 0, AID_INPUT):
            bad.append("fence: %s (%s) is born %o %d:%d, not 660 0:%d"
                       % ((path, what) + born + (AID_INPUT,)))
    for path, minor, mode, uid, gid, major, what in (
            ("/dev/input/event4", 68, 0o660, 0, 1004, 13, "the composer's own device"),
            ("/dev/input/event5", 69, 0o660, 0, 1004, 13, "Android's own uhid device"),
            ("/dev/hidraw1", 1, 0o660, 1000, 1000, 245, "Android's own uhid device's hidraw")):
        why = node_is(dev, path, minor, mode, uid, gid, major)
        if why:
            bad.append("fence: %s (%s) %s" % (path, what, why))
        want = "u:object_r:%s_device:s0" % ("hidraw" if "hidraw" in path else "input")
        if path in dev.nodes and dev.nodes[path].get("label") != want:
            bad.append("fence: %s (%s) is labeled %s, not %s" % (path, what, dev.nodes[path].get("label"), want))
        if path in dev.nodes and path not in fence.published:
            bad.append("fence: %s (%s) was made but never published" % (path, what))
    ops = [op for op, p in dev.calls if p == "/dev/hidraw1" and op in ("setxattr", "chown")]
    if ops[:1] != ["setxattr"]:
        bad.append("fence: /dev/hidraw1 was %s before any relabel" % (ops[0] if ops else "never relabeled or chowned"))
    for node, what in (("/dev/input/event6", "the host's USB keyboard"),
                       ("/dev/hidraw0", "the host's USB keyboard's hidraw"),
                       ("/dev/input/event7", "a host uinput device registered by nobody"),
                       ("/dev/input/event99", "an evdev name on major 116 under a registered device"),
                       ("/dev/input/event10", "udevd's rebroadcast")):
        if node in dev.nodes:
            bad.append("fence: %s (%s) was published" % (node, what))
    dev, log, fence = feed(rm, [evdev_add(VIRTUAL + "/input10", "event4", 68, "remove"),
                                uevent("remove", VIRTUAL + "/input10", SUBSYSTEM="input"),
                                evdev_add(VIRTUAL + "/input10", "event4", 68)], dev, fence)
    if "/dev/input/event4" in dev.nodes:
        bad.append("fence: a removed device's reused name kept its registration and was republished")
    dev, log, fence = feed(rm, [("reg", "del", UHID)], dev, fence)
    if "/dev/input/event5" in dev.nodes or "/dev/hidraw1" in dev.nodes:
        bad.append("fence: a withdrawn registration left its nodes published")
    dev = Dev()
    dev.nodes["/dev/input/event6"] = {"mode": stat.S_IFCHR | 0o660, "dev": os.makedev(13, 70), "uid": 0, "gid": 1004}
    dev, log, _ = feed(rm, [evdev_add(USB_KBD, "event6", 70)], dev)
    if "/dev/input/event6" in dev.nodes:
        bad.append("fence: a host node made in the permissive window outlived the fence's withhold")
    _, log, _ = feed(rm, [evdev_add(VIRTUAL + "/input10", "event4", 68), ("reg", "add", VIRTUAL + "/input10")],
                     Dev(label="u:object_r:tmpfs:s0"))
    if not any("input_fence=failed reason=label:u:object_r:tmpfs:s0" in m for m in log):
        bad.append("fence: a published node labeled tmpfs drew no input_fence=failed marker: %s" % log)
    _, log, _ = feed(rm, [evdev_add(VIRTUAL + "/input10", "event4", 68), ("reg", "add", VIRTUAL + "/input10")],
                     Dev(fail={"/dev/input/event4"}))
    if not any("input_fence=failed reason=mknod:13" in m for m in log):
        bad.append("fence: a refused mknod drew no input_fence=failed marker: %s" % log)
    uhid = [hidraw_add(UHID, "hidraw1", 1), ("reg", "add", UHID)]
    _, log, fence = feed(rm, uhid, Dev(relabel_fail=True))
    if not any("input_fence=failed reason=relabel:13 node=/dev/hidraw1" in m for m in log) \
            or "/dev/hidraw1" in fence.published:
        bad.append("fence: a refused hidraw relabel drew no reason=relabel marker, or was published: %s" % log)
    dev, log, fence = feed(rm, uhid, Dev(relabel_fail=True))
    if "/dev/hidraw1" in dev.nodes:
        bad.append("fence: a refused hidraw relabel left /dev/hidraw1 behind")
    dev.relabel_fail = False
    dev, log, fence = feed(rm, [hidraw_add(UHID, "hidraw1", 1)], dev, fence)
    if dev.nodes.get("/dev/hidraw1", {}).get("label") != "u:object_r:hidraw_device:s0":
        bad.append("fence: after a refused relabel, the next publish of /dev/hidraw1 did not land: %s" % log)
    dev, _, _ = feed(rm, [("reg", "add", VIRTUAL + "/input9"), evdev_add(VIRTUAL + "/input90", "event3", 67)])
    if "/dev/input/event3" in dev.nodes:
        bad.append("fence: input90's node was published")
    bad += check_mknod_race(rm)
    return bad


def check_mknod_race(rm):
    """check a node ueventd makes between the fence's lstat and mknod"""
    bad = []
    reg = [evdev_add(VIRTUAL + "/input10", "event4", 68), ("reg", "add", VIRTUAL + "/input10")]
    for what, dt in (("the same device", os.makedev(13, 68)), ("another device", os.makedev(13, 99))):
        planted = {"mode": stat.S_IFCHR | 0o600, "dev": dt, "uid": 0, "gid": 0, "label": "u:object_r:input_device:s0"}
        dev, log, fence = feed(rm, reg, Dev(race={"/dev/input/event4": planted}))
        why = node_is(dev, "/dev/input/event4", 68, 0o660, 0, 1004)
        if why or "/dev/input/event4" not in fence.published \
                or not any("input_fence=published node=/dev/input/event4" in m for m in log):
            bad.append("fence: a node ueventd made for %s between lstat and mknod was not published as the "
                       "registered device (%s): %s" % (what, why or "not published", log))
    return bad


def check_reconcile(rm):
    """check reconcile_input removes unpublished nodes"""
    bad = []
    fence = rm.InputFence("/nonexistent-sys")
    fence.published = {"/dev/input/event4": os.makedev(13, 68), "/dev/input/event5": os.makedev(13, 69)}
    dev = Dev()
    for path, dt in (("/dev/input/event4", os.makedev(13, 68)), ("/dev/input/event5", os.makedev(13, 70)),
                     ("/dev/input/event6", os.makedev(13, 71)), ("/dev/hidraw0", os.makedev(245, 0)),
                     ("/dev/bus/usb/001/002", os.makedev(189, 1))):
        dev.nodes[path] = {"mode": stat.S_IFCHR | 0o660, "dev": dt, "uid": 0, "gid": 0}
    rm.reconcile_input(fence, "", [].append, dev)
    if "/dev/input/event4" not in dev.nodes:
        bad.append("reconcile: the node the fence published was removed")
    for path, what in (("/dev/input/event5", "a published name now carrying another device (13:70)"),
                       ("/dev/input/event6", "a node the fence never published"),
                       ("/dev/hidraw0", "a host keyboard's hidraw"),
                       ("/dev/bus/usb/001/002", "a host keyboard's usbfs node")):
        if path in dev.nodes:
            bad.append("reconcile: %s, %s, was kept" % (path, what))
    src = getattr(rm, "__source__", None) or open(rm.__file__).read()
    m = re.search(r"\ndef start_input_fence\(.*?(?=\ndef )", src, re.S)
    start = m.group(0) if m else ""
    at = [start.find(x) for x in ("sock.bind(", "inotify_add_watch(", "reconcile_input(fence)",
                                  "return FenceLoop(")]
    if -1 in at or not at[0] < at[1] < at[2] < at[3] or "watch_fd=watch" not in start \
            or "registry=registry" not in start:
        bad.append("reconcile: start_input_fence does not reconcile between binding its socket and "
                   "watching /dev/input and starting the reader with that watch and the registry")
    return bad


class NetlinkShaped:
    """socketpair end with netlink recvfrom"""

    def __init__(self, sock):
        """keep the socket"""
        self.sock = sock

    def fileno(self):
        """return the socket's file descriptor"""
        return self.sock.fileno()

    def recvfrom(self, n):
        """return the received data with the sender pid parsed from a FROM prefix"""
        data = self.sock.recv(n)
        if data.startswith(b"FROM "):
            pid, _, data = data[5:].partition(b" ")
            return data, (int(pid), 1)
        return data, (0, 1)


def check_loop(rm):
    """run the fence loop against fake sockets"""
    import socket
    import threading
    import tempfile
    bad = []
    if "registry" not in rm.run_input_fence.__code__.co_varnames:
        return ["loop: run_input_fence takes no registry"]
    tmp = tempfile.mkdtemp()
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    wr, ww = os.pipe()
    registry = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    registry.bind(os.path.join(tmp, "fence.sock"))
    registry.listen(4)
    dev, log = Dev(), []
    fence = rm.InputFence("/nonexistent-sys")
    stop = threading.Event()
    t = threading.Thread(target=rm.run_input_fence,
                         args=(fence, NetlinkShaped(a), "", log.append,
                               stop.is_set, dev, wr, registry, os.getuid()), daemon=True)
    t.start()

    def wait_for(pred, what):
        """wait up to five seconds for a condition"""
        for _ in range(500):
            if pred():
                return True
            threading.Event().wait(0.01)
        bad.append("loop: %s within 5s" % what)
        return False

    b.send(evdev_add(VIRTUAL + "/input10", "event4", 68))
    wait_for(lambda: any("node=/dev/input/event4 " in m for m in log), "the fence never withheld event4")
    reg = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    reg.connect(os.path.join(tmp, "fence.sock"))
    reg.send(("add %s/input10" % VIRTUAL).encode())
    wait_for(lambda: "/dev/input/event4" in dev.nodes, "the registered device never got its node")
    b.send(b"FROM 4242 " + evdev_add(VIRTUAL + "/input10", "event7", 71))
    wait_for(lambda: any("reason=sender:(4242" in m for m in log), "the forged datagram was never dropped")
    if "/dev/input/event7" in dev.nodes:
        bad.append("loop: event7, forged by a userspace sender (port id 4242) under a registered device, was published")
    b.send(evdev_add(USB_KBD, "event6", 70))
    wait_for(lambda: any("node=/dev/input/event6 " in m for m in log), "the fence never withheld event6")
    dev.nodes["/dev/input/event6"] = {"mode": stat.S_IFCHR | 0o660, "dev": os.makedev(13, 70), "uid": 0, "gid": 1004}
    os.write(ww, b"x")
    wait_for(lambda: "/dev/input/event6" not in dev.nodes,
             "a host node made in /dev/input after the fence withheld it stayed")
    stop.set()
    b.send(b"")
    os.write(ww, b"x")
    t.join(2)
    for fd in (wr, ww):
        os.close(fd)
    for s in (a, b, reg, registry):
        s.close()
    if "/dev/input/event4" not in dev.nodes:
        bad.append("loop: the registered device's node is gone")
    return bad


def check_registrar(rm):
    """check registration from a different uid fails"""
    import socket
    import threading
    import tempfile
    tmp = tempfile.mkdtemp()
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    registry = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    registry.bind(os.path.join(tmp, "fence.sock"))
    registry.listen(4)
    dev, log = Dev(), []
    stop = threading.Event()
    t = threading.Thread(target=rm.run_input_fence,
                         args=(rm.InputFence("/nonexistent-sys"), NetlinkShaped(a), "", log.append, stop.is_set,
                               dev, None, registry, os.getuid() + 1), daemon=True)
    t.start()
    b.send(evdev_add(VIRTUAL + "/input10", "event4", 68))
    reg = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    reg.connect(os.path.join(tmp, "fence.sock"))
    try:
        reg.send(("add %s/input10" % VIRTUAL).encode())
    except (BrokenPipeError, ConnectionResetError):
        pass
    for _ in range(500):
        if any("reason=registrar-uid" in m for m in log):
            break
        threading.Event().wait(0.01)
    stop.set()
    b.send(b"")
    t.join(2)
    for x in (a, b, reg, registry):
        x.close()
    bad = []
    if not any("reason=registrar-uid" in m for m in log):
        bad.append("registry: a registrar of another uid was not turned away")
    if "/dev/input/event4" in dev.nodes:
        bad.append("registry: a registrar of another uid got its device published")
    return bad


START_CALL = "start_fence_or_kill(_input_registry"


class FakeLoop:
    """fake fence loop for tests"""

    def __init__(self, fds, done=False):
        """keep the descriptors to watch"""
        self._fds, self.done, self.handled = fds, done, []

    def fds(self):
        """return the descriptors to watch"""
        return list(self._fds)

    def handle(self, ready):
        """record the ready descriptors"""
        self.handled.append(list(ready))

    def wait_s(self):
        """return no label deadline"""
        return None


class RaisingSock:
    """fake fence socket with raising read"""

    def __init__(self, fd):
        """keep the descriptor"""
        self.fd = fd

    def fileno(self):
        """return the descriptor"""
        return self.fd

    def recvfrom(self, n):
        """raise an error as for a uevent the parser cannot read"""
        raise ValueError("fixture: a uevent the parser chokes on")


def check_wait_step(rm):
    """check fence_wait_step over pipe descriptors"""
    bad = []
    step = getattr(rm, "fence_wait_step", None)
    if step is None:
        return ["wait: rootfs has no fence_wait_step"]
    holder_r, holder_w = os.pipe()
    fence_r, fence_w = os.pipe()
    os.write(fence_w, b"x")
    kills = []
    try:
        loop = FakeLoop([fence_r])
        if step(holder_r, loop, 0, lambda: kills.append(1)):
            bad.append("wait: the step reported the holder gone while it runs")
        if not any(fence_r in r for r in loop.handled):
            bad.append("wait: a fence socket ready in the select never reached handle() (got %s)" % loop.handled)
        done = FakeLoop([fence_r], done=True)
        step(holder_r, done, 0, lambda: kills.append(1))
        if done.handled:
            bad.append("wait: a stopped fence's handle() still ran")
        if step(holder_r, None, 0, lambda: kills.append(1)):
            bad.append("wait: with no fence, the step reported the holder gone while it runs")
        os.write(holder_w, b"x")
        if not step(holder_r, FakeLoop([fence_r]), 0, lambda: kills.append(1)):
            bad.append("wait: the holder's exit, ready in the select, did not end the wait")
        if kills:
            bad.append("wait: the holder was killed with no fence failure")
        dev, log, fence = feed(rm, [evdev_add(VIRTUAL + "/input10", "event4", 68),
                                    ("reg", "add", VIRTUAL + "/input10")])
        if "/dev/input/event4" not in dev.nodes:
            return bad + ["wait: the fixture's composer node was never published"]
        hr, hw = os.pipe()
        failing = rm.FenceLoop(fence, RaisingSock(fence_r), "", log.append, dev)
        try:
            gone = step(hr, failing, 0, lambda: kills.append(1))
        except Exception as e:
            gone = None
            bad.append("wait: a fence that raised %s took g's wait down with it: g exits 0"
                       % e.__class__.__name__)
        if gone:
            bad.append("wait: a fence that raised read as the holder's exit")
        if gone is not None:
            if not kills:
                bad.append("wait: a fence that raised never killed the sandbox")
            if "/dev/input/event4" in dev.nodes:
                bad.append("wait: a fence that raised left /dev/input/event4 published")
            if not failing.done:
                bad.append("wait: a fence that raised is still running")
            if not any("input_fence=failed reason=raised:ValueError" in m for m in log):
                bad.append("wait: a fence that raised drew no input_fence=failed marker: %s" % log)
        os.close(hr)
        os.close(hw)
        bad += _stopped_fence_findings(rm, step)
        bad += _fail_raises_findings(rm, step, fence_r)
        bad += _no_fence_findings(rm)
    finally:
        for fd in (holder_r, holder_w, fence_r, fence_w):
            os.close(fd)
    return bad


class FailRaises(FakeLoop):
    """fake fence with raising methods"""

    def handle(self, ready):
        """raise an error"""
        raise ValueError("fixture: handle")

    def fail(self, why):
        """raise an error"""
        raise RuntimeError("fixture: fail")


def _fail_raises_findings(rm, step, fence_r):
    """run fence_wait_step with a failing fence"""
    hr, hw = os.pipe()
    kills = []
    try:
        step(hr, FailRaises([fence_r]), 0, lambda: kills.append(1))
    except Exception:
        pass
    finally:
        os.close(hr)
        os.close(hw)
    if not kills:
        return ["wait: a fence whose withdraw raised left the sandbox running: the kill never ran"]
    return []


def _no_fence_findings(rm):
    """run start_fence_or_kill with a failing start"""
    start = getattr(rm, "start_fence_or_kill", None)
    if start is None:
        return ["start: rootfs has no start_fence_or_kill"]
    bad, kills, log = [], [], []
    got = start("registry", lambda: kills.append(1), start=lambda reg: None, log=log.append)
    if got is not None or not kills:
        bad.append("start: a fence that could not listen did not kill the sandbox (killed %d time(s))" % len(kills))
    if not any("RHIZO_MARKER input_fence=failed reason=start" in m for m in log):
        bad.append("start: a fence that could not listen drew no input_fence=failed reason=start: %s" % log)
    kills, log, loop = [], [], FakeLoop([])
    got = start("registry", lambda: kills.append(1), start=lambda reg: loop if reg == "registry" else None,
                log=log.append)
    if got is not loop or kills:
        bad.append("start: a fence that started was not handed back, or the sandbox was killed anyway")
    return bad


def _stopped_fence_findings(rm, step):
    """run the wait step with a stopped fence"""
    import socket
    dev, log, fence = feed(rm, [evdev_add(VIRTUAL + "/input10", "event4", 68),
                                ("reg", "add", VIRTUAL + "/input10")])
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    hr, hw = os.pipe()
    kills, bad = [], []
    try:
        b.send(b"")
        stopping = rm.FenceLoop(fence, NetlinkShaped(a), "", log.append, dev)
        if step(hr, stopping, 0, lambda: kills.append(1)):
            bad.append("wait: a fence that stopped read as the holder's exit")
        if not stopping.done:
            bad.append("wait: the fixture's fence never stopped on EOF")
        elif not kills or "/dev/input/event4" in dev.nodes:
            bad.append("wait: a fence that stopped left the sandbox running (killed %d time(s), "
                       "event4 %s)" % (len(kills), "still published" if "/dev/input/event4" in dev.nodes
                                       else "withdrawn"))
        elif not any("input_fence=failed reason=stopped" in m for m in log):
            bad.append("wait: a fence that stopped drew no input_fence=failed marker: %s" % log)
    finally:
        for x in (a, b):
            x.close()
        for fd in (hr, hw):
            os.close(fd)
    return bad


def _is_name(node, name):
    """return whether a node is a name"""
    return isinstance(node, ast.Name) and node.id == name


def g_wait_loop_findings(launcher):
    """check launcher3.py wiring of fence_wait_step"""
    try:
        tree = ast.parse(launcher)
    except SyntaxError as e:
        return ["wiring: launcher3.py does not parse: %s" % e]
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.If) and isinstance(n.test, ast.Call)
             and _is_name(n.test.func, "fence_wait_step")]
    if len(calls) != 1:
        return ["wiring: launcher3.py calls fence_wait_step as an if test %d times, not once in g's wait "
                "loop" % len(calls)]
    node = calls[0]
    args = node.test.args
    bad = []
    if len(args) != 4 or not _is_name(args[0], "_gg_fd") or not _is_name(args[1], "_fence"):
        bad.append("wiring: g's wait loop calls fence_wait_step(%s), not on _gg_fd and _fence" % ", ".join(ast.unparse(a) for a in args))
    kill = args[3] if len(args) == 4 else None
    kill_defs = [d for d in ast.walk(tree) if isinstance(d, ast.FunctionDef) and kill is not None
                 and _is_name(kill, d.name)]
    sends = [c for d in kill_defs for c in ast.walk(d) if isinstance(c, ast.Call)
             and ast.unparse(c.func).endswith("pidfd_send_signal") and len(c.args) == 2
             and _is_name(c.args[0], "_gg_fd") and ast.unparse(c.args[1]).endswith("SIGKILL")]
    records = [c for d in kill_defs for c in ast.walk(d) if isinstance(c, ast.Call)
               and ast.unparse(c.func).endswith("record_start_end") and "refused:input-fence" in ast.unparse(c)]
    if len(kill_defs) != 1 or not sends:
        bad.append("wiring: g's kill_holder is %s, not a SIGKILL to gg's pidfd" % (ast.unparse(kill) if kill is not None else "missing"))
    elif not records or records[0].lineno > sends[0].lineno:
        bad.append("wiring: g's kill_holder does not record refused:input-fence before its SIGKILL to gg")
    body = ast.unparse(ast.Module(body=node.body, type_ignores=[]))
    if "os.waitpid(gg" not in body or not any(isinstance(b, ast.Break) for b in ast.walk(node)):
        bad.append("wiring: g does not reap gg and leave its loop when fence_wait_step says gg exited")
    loops = [w for w in ast.walk(tree) if isinstance(w, ast.While) and node in ast.walk(w)]
    if not loops:
        bad.append("wiring: fence_wait_step is not called inside g's wait loop")
    starts = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and _is_name(n.func, "start_fence_or_kill")]
    if len(starts) != 1 or len(starts[0].args) != 2 or not _is_name(starts[0].args[0], "_input_registry") \
            or ast.unparse(starts[0].args[1]) != ast.unparse(kill if kill is not None else ast.Constant(None)):
        bad.append("wiring: g does not start the fence with start_fence_or_kill(_input_registry, <the SIGKILL to "
                   "gg's pidfd>)")
    if [n for n in ast.walk(tree) if isinstance(n, ast.Call) and _is_name(n.func, "start_input_fence")]:
        bad.append("wiring: launcher3.py still calls start_input_fence directly")
    pidfd = [a for a in ast.walk(tree) if isinstance(a, ast.Assign) and any(_is_name(t, "_gg_fd") for t in a.targets)]
    if [ast.unparse(a.value) for a in pidfd] != ["os.pidfd_open(gg)"]:
        bad.append("wiring: _gg_fd is %s, not gg's pidfd" % [ast.unparse(a.value) for a in pidfd])
    return bad

PIDNS_CHILD = r'''
import contextlib, io, os, sys
os.environ.setdefault("RHIZO_GSI", "/nonexistent")
sys.path.insert(0, sys.argv[1])
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs
rootfs.kmsg = lambda m: None
os.unshare(os.CLONE_NEWPID)
try:
    loop = rootfs.start_input_fence(None)
except RuntimeError as e:
    print("RAISED", e)
    sys.exit(0)
print("STARTED" if loop is not None and hasattr(loop, "handle") else "NOTHING %r" % (loop,))
'''


def check_pidns_start():
    """run start_input_fence in an unshared pid namespace"""
    import subprocess
    r = subprocess.run(["unshare", "-r", sys.executable, "-c", PIDNS_CHILD, os.path.join(REPO, "src", "androidd")],
                       capture_output=True, text=True, timeout=60)
    out = r.stdout.strip()
    if r.returncode != 0 or not out:
        return ["pidns: the fixture did not run (rc %d): %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:])]
    if out.startswith("RAISED"):
        return ["pidns: start_input_fence raised %r in a process that unshared its pid namespace, as g "
                "has" % out[len("RAISED "):]]
    if out != "STARTED":
        return ["pidns: start_input_fence handed back %s, not a loop for g's select" % out]
    return []


DEV_INPUT_MOUNT = re.compile(r'mount\("tmpfs", f"\{NEWROOT\}/dev/input", "tmpfs", [^,]+, "([^"]*)"\)')
FENCE_UID = 0
AID_SYSTEM = 1000
AID_INPUT = 1004
AID_BY_NAME = {"root": 0, "system": 1000, "graphics": 1003, "input": 1004, "uhid": 3011}


def rc_ids(rc):
    """return the uid and groups of vendor.rhizo-composer"""
    blocks = re.findall(r"(?ms)^service vendor\.rhizo-composer .*?(?=^(?:service|on|import) |\Z)", rc)
    if len(blocks) != 1:
        return None
    user = re.search(r"^[ \t]*user (\S+)", blocks[0], re.M)
    group = re.search(r"^[ \t]*group ([^\n]+)", blocks[0], re.M)
    names = [user.group(1) if user else "root"] + (group.group(1).split() if group else [])
    ids = [AID_BY_NAME.get(n) for n in names]
    return (ids[0], set(ids[1:])) if None not in ids else None


def _dac_bits(mode, uid, gid, who, groups):
    """return the rwx bits of mode"""
    if who == uid:
        return (mode >> 6) & 7
    if gid in groups:
        return (mode >> 3) & 7
    return mode & 7


def check_dev_input_mount(mounts_src, policy, composer_rc):
    """check the /dev/input tmpfs mode and uid"""
    bad = []
    mounts = DEV_INPUT_MOUNT.findall(mounts_src)
    if len(mounts) != 1:
        return ["mounts: sandbox/rootfs.py mounts the /dev/input tmpfs %d times, not once" % len(mounts)]
    opts = dict(o.partition("=")[::2] for o in mounts[0].split(",") if o)
    mode = int(opts.get("mode", "1777"), 8)
    uid, gid = int(opts.get("uid", "0")), int(opts.get("gid", "0"))
    forms = cil_forms(policy)
    for dom in ("kernel", "rhizo_host"):
        if any("dac_override" in p for p in rules(forms, "allow", dom, "self", "capability")):
            continue
        if _dac_bits(mode, uid, gid, FENCE_UID, {0}) & 3 != 3:
            bad.append("mounts: /dev/input is a tmpfs of uid=%d gid=%d mode=%o, and the fence writes it as "
                       "root in %s, which lacks dac_override"
                       % (uid, gid, mode, dom))
            break
    if _dac_bits(mode, uid, gid, AID_SYSTEM, {AID_SYSTEM, AID_INPUT}) & 5 != 5:
        bad.append("mounts: /dev/input (uid=%d gid=%d mode=%o) is not readable and searchable by "
                   "system_server" % (uid, gid, mode))
    composer = rc_ids(composer_rc)
    if composer is None:
        bad.append("mounts: rhizo-composer.rc's user or group names an id this checker cannot resolve")
    elif _dac_bits(mode, uid, gid, composer[0], composer[1]) & 5 != 5:
        bad.append("mounts: /dev/input (uid=%d gid=%d mode=%o) is not searchable and readable by the composer "
                   "(uid %d groups %s)"
                   % (uid, gid, mode, composer[0], sorted(composer[1])))
    return bad


def check_wiring(launcher, uinput, claims):
    """return the fence wiring problems"""
    bad = []
    at = launcher.find(START_CALL)
    piv = launcher.find('_piv_signal = os.read(piv_r, 1) if _piv_ready else b""')
    loop = launcher.find('watched = "the namespace holder" if _handoff_to else "init(pid1)"')
    if at < 0:
        bad.append("wiring: launcher3.py never calls %s" % START_CALL)
    elif not (0 <= piv < at < loop):
        bad.append("wiring: %s is not between g's pivot signal and its wait loop" % START_CALL)
    elif launcher.find("fence_wait_step(", loop) < 0:
        bad.append("wiring: g's wait loop never runs the fence (fence_wait_step)")
    bad += g_wait_loop_findings(launcher)
    if not re.search(r"return prefix \+ std::to_string\(port\);", uinput) \
            or 'getenv("RHIZO_INPUT_PHYS_PREFIX")' not in uinput \
            or 'v && *v ? v : "rhizo-port-"' not in uinput:
        bad.append("wiring: uinput.cpp's PortPhys is no longer RHIZO_INPUT_PHYS_PREFIX "
                   "(rhizo-port- unset) and a port number")
    body = re.search(r"std::string PublishNode\(int fd\) \{(.*?)\n\}", uinput, re.S)
    code = re.sub(r"//[^\n]*", "", body.group(1)) if body else ""
    if not body:
        bad.append("wiring: uinput.cpp has no PublishNode")
    elif re.search(r"\b(unlink|mknod)\(", code):
        bad.append("wiring: PublishNode still unlinks or mknods /dev/input itself")
    if core.input_phys_prefix(0) != "rhizo-port-":
        bad.append("wiring: instance 0's phys prefix is %r, the composer's unset default is 'rhizo-port-'"
                   % core.input_phys_prefix(0))
    m = re.search(r"^LC_INPUT_PHYS_PREFIX='([^']*)'$", claims, re.M)
    if not m or m.group(1) != core.input_phys_prefix(0):
        bad.append("wiring: claims-server.sh's LC_INPUT_PHYS_PREFIX is %s, not instance 0's %r"
                   % (repr(m.group(1)) if m else "missing", core.input_phys_prefix(0)))
    return bad


def run():
    """run every fence check and return the problems"""
    bad = check_premise(AOSP) + check_policy(open(POLICY).read())
    bad += check_dev_input_mount(open(rootfs.__file__).read(), open(POLICY).read(),
                                 open(COMPOSER_RC).read())
    bad += check_fence(rootfs) + check_reconcile(rootfs) + check_loop(rootfs)
    bad += check_registrar(rootfs) + check_wait_step(rootfs)
    bad += check_wiring(open(LAUNCHER).read(), open(UINPUT).read(), open(CLAIMS).read())
    bad += check_pidns_start()
    for b in bad:
        say(b)
    if bad:
        return 1
    print("check-input-fence: ok -- ueventd may not create an input, hidraw or usbfs node, and the fence "
          "publishes exactly the devices rhizo-inputd registered")
    return 0


def mutant(old, new):
    """return rootfs with a string replaced"""
    src = open(rootfs.__file__).read()
    if src.count(old) != 1:
        return None
    mod = types.ModuleType("rhizo_mounts_mutant")
    mod.__file__ = rootfs.__file__
    mod.__source__ = src.replace(old, new)
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(src.replace(old, new), rootfs.__file__, "exec"), mod.__dict__)
    return mod


FENCE_MUTATIONS = (
    ("fence-open", '        if _under(devpath, self.owned):\n', "        if True:\n",
     "event6 (the host's USB keyboard) was published"),
    ("under-no-slash-guard", 'return any(devpath == p or devpath.startswith(p + "/") for p in owned)',
     "return any(devpath.startswith(p) for p in owned)", "its name starts with the registered input9"),
    ("no-late-publish", "            return [(\"publish\", k, p, d, \"registered\") for dp, (k, p, d) in self.seen.items()\n",
     "            return [(\"publish\", k, p, d, \"registered\") for dp, (k, p, d) in {}.items()\n",
     "/dev/input/event4 (the composer's own device) was never published"),
    ("born-umasked", "old = ops.umask(0)", "old = ops.umask(0o022)",
     "/dev/input/event4 (the composer's own device) is born 640 0:1004"),
    ("dev-input-not-setgid", '"mode=02755,uid=0,gid=1004"', '"mode=0755,uid=0,gid=0"',
     "/dev/input/event4 (the composer's own device) is born 660 0:0"),
    ("remove-keeps-registration", "        if action == \"remove\":\n            self.owned.discard(devpath)\n",
     "", "a removed device's reused name kept its registration"),
    ("del-keeps-nodes", "            return [(\"withhold\", k, p, d, \"unregistered\") for dp, (k, p, d) in self.seen.items()\n",
     "            return [(\"withhold\", k, p, d, \"unregistered\") for dp, (k, p, d) in {}.items()\n",
     "a withdrawn registration left its nodes published"),
    ("no-chown", "        ops.chown(path, uid, gid)\n", "", "is 660 0:0 dev"),
    ("hidraw-as-input", '"hidraw": (AID_SYSTEM, AID_SYSTEM, HIDRAW_NODE_LABEL, True)}',
     '"hidraw": (AID_ROOT, AID_INPUT, HIDRAW_NODE_LABEL, True)}',
     "/dev/hidraw1 (Android's own uhid device's hidraw) is 660 0:1004"),
    ("hidraw-no-relabel", '"hidraw": (AID_SYSTEM, AID_SYSTEM, HIDRAW_NODE_LABEL, True)}',
     '"hidraw": (AID_SYSTEM, AID_SYSTEM, HIDRAW_NODE_LABEL, False)}',
     "/dev/hidraw1 (Android's own uhid device's hidraw) is labeled u:object_r:device:s0"),
    ("chown-before-relabel", "        _make_input_node(path, dev, st, ops)\n",
     "        _make_input_node(path, dev, st, ops)\n        ops.chown(path, uid, gid)\n",
     "/dev/hidraw1 was chown before any relabel"),
    ("relabel-leaves-node", "        try:\n            ops.unlink(path)\n            gone = \"\"\n",
     "        try:\n            gone = \"\"\n", "a refused hidraw relabel left /dev/hidraw1 behind"),
    ("relabel-unreported", "reason=relabel:{why} node={node}{gone}\")",
     "reason=mknod:{why} node={node}{gone}\")",
     "a refused hidraw relabel drew no reason=relabel marker"),
    ("rebroadcast-read", ' or b"@" not in buf.split(b"\\0", 1)[0]', "",
     "event10 (udevd's rebroadcast) was published"),
    ("no-permissive-sweep", "            try:\n                ops.unlink(path)\n                gone = ",
     "            try:\n                gone = ", "outlived the fence's withhold"),
    ("reconcile-keeps-all", "        if not stat.S_ISCHR(st.st_mode) or fence.published.get(node) == st.st_rdev:",
     "        if True:", "/dev/input/event6, a node the fence never published, was kept"),
    ("reconcile-name-only", "        if not stat.S_ISCHR(st.st_mode) or fence.published.get(node) == st.st_rdev:",
     "        if not stat.S_ISCHR(st.st_mode) or node in fence.published:",
     "now carrying another device (13:70), was kept"),
    ("no-usb-sweep", "    for bus in buses:\n", "    for bus in ():\n", "a host keyboard's usbfs node, was kept"),
    ("loop-ignores-watch", "            reconcile_input(fence, root, log, ops)\n        if self.registry is not None",
     "            pass\n        if self.registry is not None", "a host node made in /dev/input after the fence withheld it stayed"),
    ("loop-ignores-registry", "            self._apply(fence.register(verb, devpath))\n", "            pass\n",
     "the registered device never got its node"),
    ("any-registrar", "            if _peer_uid(conn) != self.registrar_uid:", "            if False:",
     "a registrar of another uid got its device published"),
    ("reconcile-not-called", "    reconcile_input(fence)\n    if registry is None:", "    if registry is None:",
     "does not reconcile between binding"),
    ("any-major", "        if kind == \"evdev\" and os.major(dev) != INPUT_MAJOR:", "        if False:",
     "event99 (an evdev name on major 116 under a registered device) was published"),
    ("any-sender", "        if not (isinstance(addr, tuple) and addr and addr[0] == 0):",
     "        if False:", "event7, forged by a userspace sender"),
    ("label-unread", "    if got != label:\n", "    if False:\n", "labeled tmpfs drew no input_fence=failed"),
    ("mknod-race-fails", "        except FileExistsError:\n            if retry:\n                raise\n",
     "        except FileExistsError:\n            raise\n", "made for the same device between lstat and mknod"),
    ("mknod-race-adopts-any", "        if st is not None and stat.S_ISCHR(st.st_mode) and st.st_rdev == dev:\n            return\n",
     "        if st is not None:\n            return\n", "made for another device between lstat and mknod"),
)


WAIT_MUTATIONS = (
    ("select-drops-fence", "        fds = [holder_fd] + (loop.fds() if live else [])\n",
     "        fds = [holder_fd]\n", "never reached handle()"),
    ("handle-guard-false", "        if live and ready:\n            loop.handle(ready)\n",
     "        if False:\n            loop.handle(ready)\n", "never reached handle()"),
    ("holder-exit-ignored", "        if holder_fd in ready:\n            return True\n",
     "        if False:\n            return True\n", "did not end the wait"),
    ("raise-through", "    except Exception as e:\n        if not live:\n",
     "    except ZeroDivisionError as e:\n        if not live:\n", "took g's wait down with it"),
    ("no-kill", "    try:\n        loop.fail(why)\n    finally:\n        kill_holder()\n", "    loop.fail(why)\n",
     "never killed the sandbox"),
    ("kill-after-fail", "    try:\n        loop.fail(why)\n    finally:\n        kill_holder()\n",
     "    loop.fail(why)\n    kill_holder()\n", "withdraw raised left the sandbox running"),
    ("start-none-ignored", "    if loop is None:\n", "    if False:\n", "could not listen did not kill"),
    ("stop-left-running", "        if not (live and loop.done):\n            return False\n        why = \"stopped\"\n",
     "        return False\n", "a fence that stopped left the sandbox running"),
    ("no-withdraw", "        for node, dev in list(self.fence.published.items()):\n",
     "        for node, dev in []:\n", "left /dev/input/event4 published"),
)


def selftest():
    """run the input-fence checks against planted defects"""
    fails = []

    def expect(label, findings, needle):
        """record a failure unless the findings match what the case expects"""
        if needle is None:
            if findings:
                fails.append("%s: flagged a correct input: %s" % (label, findings[0]))
        elif not any(needle in f for f in findings):
            fails.append("%s: did not flag %r (got %s)" % (label, needle, findings or "nothing"))

    policy = open(POLICY).read()
    expect("policy/good", check_policy(policy), None)
    expect("policy/no-deny", check_policy(policy.replace(
        "(deny ueventd input_device (chr_file (create)))", "")), "no (deny ueventd input_device")
    expect("policy/deny-in-comment", check_policy(policy.replace(
        "(deny ueventd input_device (chr_file (create)))", "; (deny ueventd input_device (chr_file (create)))")),
        "no (deny ueventd input_device")
    expect("policy/regrant", check_policy(policy + "\n(allow ueventd input_device (chr_file (create)))\n"),
           "an allow names ueventd input_device chr_file create")
    expect("policy/kernel-no-create", check_policy(policy.replace(
        "(allow kernel input_device (chr_file (create getattr setattr unlink)))",
        "(allow kernel input_device (chr_file (getattr setattr unlink)))")), "kernel lacks create")
    expect("policy/host-no-remove", check_policy(policy.replace(
        "(allow rhizo_host input_device (dir (search getattr open read write add_name remove_name watch)))",
        "(allow rhizo_host input_device (dir (search getattr open read write add_name watch)))")),
        "rhizo_host lacks remove_name")
    expect("policy/composer-no-watch", check_policy(policy.replace(
        "(allow rhizo_composer input_device (dir (search open read getattr watch)))",
        "(allow rhizo_composer input_device (dir (search open read getattr)))")),
        "rhizo_composer has no watch on /dev/input")
    expect("policy/composer-unlink", check_policy(
        policy + "\n(allow rhizo_composer input_device (chr_file (unlink)))\n"),
        "rhizo_composer may still unlink an input node")
    expect("policy/no-hidraw-deny", check_policy(policy.replace(
        "(deny ueventd hidraw_device (chr_file (create)))", "")), "no (deny ueventd hidraw_device")
    expect("policy/no-usb-deny", check_policy(policy.replace(
        "(deny ueventd usb_device (chr_file (create)))", "")), "no (deny ueventd usb_device")
    for name, rule, needle in (
            ("host-no-create", "(allow rhizo_host device (chr_file (create relabelfrom unlink)))",
             "rhizo_host lacks create relabelfrom unlink on device chr_file"),
            ("kernel-no-unlink", "(allow kernel rhizo_host_device (chr_file (create getattr setattr unlink)))",
             "kernel lacks create unlink on rhizo_host_device chr_file"),
            ("host-no-relabelto", "(allow rhizo_host hidraw_device (chr_file (setattr relabelto)))",
             "rhizo_host lacks relabelto setattr on hidraw_device chr_file"),
            ("kernel-no-relabelfrom", "(allow kernel rhizo_host_device (chr_file (relabelfrom)))",
             "kernel lacks relabelfrom on rhizo_host_device chr_file"),
            ("kernel-no-relabelto", "(allow kernel hidraw_device (chr_file (setattr relabelto)))",
             "kernel lacks relabelto setattr on hidraw_device chr_file")):
        expect("policy/hidraw-" + name, check_policy(policy.replace(rule, "")), needle)
    expect("policy/hidraw-host-no-add-name", check_policy(policy.replace(
        "(allow rhizo_host device (dir (search getattr open read write add_name remove_name watch)))",
        "(allow rhizo_host device (dir (search getattr open read write remove_name watch)))")),
        "rhizo_host lacks add_name on device dir")
    expect("policy/hidraw-kernel-born-device", check_policy(policy.replace(
        "(typetransition kernel device chr_file rhizo_host_device)", "")),
        "kernel lacks create relabelfrom unlink on device chr_file")
    expect("policy/no-hidraw-unlink", check_policy(policy.replace(
        "(allow kernel hidraw_device (chr_file (getattr unlink)))", "")), "kernel lacks unlink on hidraw_device")
    expect("policy/no-ptrace-shell", check_policy(policy.replace(
        "(allow rhizo_inputd shell (process (ptrace)))", "")), "rhizo_inputd lacks process ptrace over shell")
    expect("policy/ptrace-bluetooth", check_policy(policy + "(allow rhizo_inputd bluetooth (process (ptrace)))\n"),
           "rhizo_inputd may ptrace bluetooth")
    expect("policy/host-ptrace", check_policy(policy + "(allow rhizo_host shell (process (ptrace)))\n"),
           "rhizo_host, every host service, may ptrace shell")
    expect("policy/broker-every-node", check_policy(policy + "(allow rhizo_uhidd rhizo_host_device (chr_file (open)))\n"),
           "rhizo_uhidd holds rhizo_host_device")
    expect("policy/broker-opens-cuse", check_policy(policy + "(allow rhizo_uhidd rhizo_cuse_host_device (chr_file (open)))\n"),
           "rhizo_uhidd may open rhizo_cuse_host_device too")
    expect("policy/no-uhid-ioctl", check_policy(policy.replace(
        "(allow rhizo_inputd uhid_device (chr_file (getattr read write ioctl)))", "")),
        "rhizo_inputd may not ioctl a uinput fd")
    expect("policy/no-chown", check_policy(policy.replace("(allow kernel self (capability (chown)))", "")),
           "kernel lacks the chown capability")

    mounts_src = open(rootfs.__file__).read()
    composer_rc = open(COMPOSER_RC).read()
    dev_input = DEV_INPUT_MOUNT.search(mounts_src)
    expect("mounts/good", check_dev_input_mount(mounts_src, policy, composer_rc), None)
    if dev_input is None:
        fails.append("mounts: the /dev/input tmpfs mount is gone from sandbox/rootfs.py")
    else:
        def with_opts(opts):
            """return the mounts source with the input mount options replaced"""
            return mounts_src.replace(dev_input.group(0), dev_input.group(0).replace(dev_input.group(1), opts))
        expect("mounts/system-owned",
               check_dev_input_mount(with_opts("mode=0755,uid=1000,gid=1000"), policy, composer_rc),
               "is a tmpfs of uid=1000 gid=1000 mode=755")
        expect("mounts/owner-only", check_dev_input_mount(with_opts("mode=0700"), policy, composer_rc),
               "not readable and searchable by system_server")
        shut = with_opts("mode=0750,uid=0,gid=1004")
        expect("mounts/composer-shut-out", check_dev_input_mount(shut, policy, composer_rc),
               "not searchable and readable by the composer")
        expect("mounts/composer-in-input", check_dev_input_mount(
            shut, policy, re.sub(r"(?m)^(\s+group [^\n]+)", r"\1 input", composer_rc)), None)
        expect("mounts/composer-unknown-group", check_dev_input_mount(
            mounts_src, policy, re.sub(r"(?m)^(\s+group [^\n]+)", r"\1 nosuchgroup", composer_rc)),
            "names an id this checker cannot resolve")
        expect("mounts/other-service-first", check_dev_input_mount(
            shut, policy, "service vendor.rhizo-helper /x\n    user root\n\n" + composer_rc),
            "not searchable and readable by the composer")
        expect("mounts/tmpfs-default", check_dev_input_mount(with_opts(""), policy, composer_rc), None)
        expect("mounts/twice", check_dev_input_mount(mounts_src + "\n" + dev_input.group(0), policy, composer_rc),
               "mounts the /dev/input tmpfs 2 times")

    expect("fence/good", check_fence(rootfs), None)
    expect("reconcile/good", check_reconcile(rootfs), None)
    expect("loop/good", check_loop(rootfs), None)
    expect("registry/good", check_registrar(rootfs), None)
    for name, old, new, needle in FENCE_MUTATIONS:
        mod = mutant(old, new)
        if mod is None:
            fails.append("fence/%s: the mutation no longer applies to sandbox/rootfs.py" % name)
            continue
        got = check_fence(mod) + check_reconcile(mod)
        if not any(needle in g for g in got):
            got += check_loop(mod) + check_registrar(mod)
        expect("fence/%s" % name, got, needle)

    launcher, uinput, claims = open(LAUNCHER).read(), open(UINPUT).read(), open(CLAIMS).read()
    expect("wiring/good", check_wiring(launcher, uinput, claims), None)
    expect("wiring/loop-skips-fence", check_wiring(launcher.replace("fence_wait_step(_gg_fd, _fence,",
                                                                    "fence_wait_step(_gg_fd, None,"), uinput, claims),
           "not on _gg_fd and _fence")
    expect("wiring/no-kill", check_wiring(launcher.replace(
        "                _signal.pidfd_send_signal(_gg_fd, _signal.SIGKILL)\n", "                pass\n"),
        uinput, claims),
        "not a SIGKILL to gg's pidfd")
    expect("wiring/no-fence-record", check_wiring(launcher.replace(
        '                    selinux_ns.record_start_end("refused:input-fence", _verdict_dir)\n',
        "                    pass\n"), uinput, claims), "does not record refused:input-fence")
    expect("wiring/no-reap", check_wiring(launcher.replace(
        "_kill_for_fence):\n                    d=os.waitpid(gg,0)", "_kill_for_fence):\n                    d=(0, 0)"),
        uinput, claims), "does not reap gg")
    expect("wiring/no-start", check_wiring(launcher.replace(START_CALL, "pass"), uinput, claims),
           "never calls start_fence_or_kill")
    expect("wait/good", check_wait_step(rootfs), None)
    for name, old, new, needle in WAIT_MUTATIONS:
        mod = mutant(old, new)
        if mod is None:
            fails.append("wait/%s: the mutation no longer applies to sandbox/rootfs.py" % name)
            continue
        expect("wait/%s" % name, check_wait_step(mod), needle)
    expect("wiring/phys-fixed", check_wiring(launcher, uinput.replace(
        "return prefix + std::to_string(port);", 'return "rhizo-port-" + std::to_string(port);'), claims),
        "PortPhys is no longer")
    expect("wiring/composer-unlinks", check_wiring(launcher, uinput.replace(
        "  return node;\n}", "  unlink(node.c_str());\n  return node;\n}", 1), claims),
        "PublishNode still unlinks or mknods")
    expect("wiring/claim-prefix", check_wiring(launcher, uinput, claims.replace(
        "LC_INPUT_PHYS_PREFIX='rhizo-port-'", "LC_INPUT_PHYS_PREFIX='rhizo-'")),
        "LC_INPUT_PHYS_PREFIX is 'rhizo-'")

    import tempfile
    with tempfile.TemporaryDirectory() as t:
        expect("premise/missing", check_premise(t), "premise: cannot read system/core/init/devices.cpp")
    expect("premise/good", check_premise(AOSP), None)

    for f in fails:
        say("selftest: " + f)
    if fails:
        return 1
    print("check-input-fence: selftest ok")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    return run()


if __name__ == "__main__":
    sys.exit(main())
