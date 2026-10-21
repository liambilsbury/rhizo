#!/usr/bin/env python3
import contextlib
import inspect
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
VAR_DIR = os.path.join(REPO, "var")
AOSP = os.path.join(REPO, "aosp-android16-qpr2")
POLICY = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
VENDOR_FC = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "vendor_file_contexts")

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-coldboot-host-uevents")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs  # noqa: E402
    from sandbox import selinux_labels  # noqa: E402

AID = {"root": 0, "system": 1000, "graphics": 1003, "vpn": 1016,
       "prng_seeder": 1092, "uhid": 3011}
PRIMER_OWN = ("/dev/dri/renderD128", "/dev/dri/card0", "/dev/tun", "/dev/uinput")


def say(msg):
    """print a message prefixed with the check name to stderr"""
    print("check-coldboot-host-uevents: %s" % msg, file=sys.stderr)


PREMISE = (
    ("ueventd.cpp",
     r"if \(!android::base::GetBoolProperty\(kColdBootDoneProp, false\)\) \{\s*"
     r"ColdBoot cold_boot\([^;]*;\s*cold_boot\.Run\(\);",
     "ColdBoot::Run is no longer gated on ro.cold_boot_done alone"),
    ("ueventd.cpp",
     r"uevent_listener\.RegenerateUevents\(\[&\]\(const Uevent& uevent\) -> ListenerAction \{\s*"
     r"bool uuid_check_done = device_handler->CheckUeventForBootPartUuid\(uevent\);\s*"
     r"return uuid_check_done \? ListenerAction::kStop : ListenerAction::kContinue;",
     "the boot-partition replay no longer stops where CheckUeventForBootPartUuid says"),
    ("devices.cpp",
     r"bool DeviceHandler::CheckUeventForBootPartUuid\(const Uevent& uevent\) \{\s*"
     r"(//[^\n]*\n\s*)*if \(boot_part_uuid_\.empty\(\)\) \{\s*return true;",
     "CheckUeventForBootPartUuid no longer stops at the first event without a boot_part_uuid"),
    ("uevent_listener.cpp",
     r"int fd = openat\(dfd, \"uevent\", O_WRONLY \| O_CLOEXEC\);\s*if \(fd >= 0\) \{\s*"
     r"write\(fd, \"add\\n\", 4\);.*?if \(callback\(uevent\) == ListenerAction::kStop\) "
     r"return ListenerAction::kStop;.*?while \(\(de = readdir\(d\)\) != nullptr\)",
     "RegenerateUeventsForDir no longer writes a directory's own uevent, and stops, before reading it"),
    ("uevent_listener.cpp",
     r"static const char\* kRegenerationPaths\[\] = \{\"/sys/devices\"\};",
     "the replay root is no longer /sys/devices alone"),
    ("util.h",
     r"kColdBootDoneProp\[\] = \"ro\.cold_boot_done\";",
     "kColdBootDoneProp is no longer ro.cold_boot_done"),
    ("property_service.cpp",
     r"LoadPropertiesFromSecondStageRes\(&properties\);",
     "PropertyLoadBootDefaults no longer loads the ramdisk prop"),
)
VOLD_PREMISE = (
    (r'coldboot\("/sys/block"\);',
     "vold no longer cold-boots /sys/block alone"),
    (r'static void do_coldboot\(DIR\* d, int lvl\) \{.*?'
     r'fd = openat\(dfd, "uevent", O_WRONLY \| O_CLOEXEC\);\s*if \(fd >= 0\) \{\s*'
     r'write\(fd, "add\\n", 4\);.*?'
     r"if \(de->d_name\[0\] == '\.'\) continue;\s*"
     r"if \(de->d_type != DT_DIR && lvl > 0\) continue;\s*"
     r"fd = openat\(dfd, de->d_name, O_RDONLY \| O_DIRECTORY \| O_CLOEXEC\);",
     "do_coldboot no longer writes each directory's uevent, following links only at the top"),
)
VENDOR_PREFIXES_RE = r"kVendorPathPrefixes\[\d+\] = \{([^}]*)\}"
SSR_RE = (r"kSecondStageRes\[\] = \"([^\"]+)\";\s*"
          r"constexpr const char kBootImageRamdiskProp\[\] = \"([^\"]+)\";")
GSI_VOLD_STRINGS = (b"/sys/block",)
GSI_INIT_STRINGS = (b"ro.cold_boot_done", b"found via partition UUID",
                    b"/second_stage_resources", b"/system/etc/ramdisk/build.prop")


def check_premise(aosp):
    """return findings for the AOSP init source"""
    init = os.path.join(aosp, "system", "core", "init")
    bad, text = [], {}
    for name in ("ueventd.cpp", "devices.cpp", "uevent_listener.cpp", "util.h",
                 "property_service.cpp", "second_stage_resources.h", "selinux.cpp"):
        try:
            text[name] = open(os.path.join(init, name)).read()
        except OSError as e:
            bad.append("premise: cannot read %s (%s)" % (name, e.strerror))
    if bad:
        return bad
    for name, pat, why in PREMISE:
        if not re.search(pat, text[name], re.S):
            bad.append("premise: %s -- %s" % (name, why))
    m = re.search(SSR_RE, text["second_stage_resources.h"])
    if not m or m.group(1) + m.group(2) != rootfs.RAMDISK_PROP:
        bad.append("premise: second_stage_resources.h no longer puts the ramdisk prop at %s"
                   % rootfs.RAMDISK_PROP)
    m = re.search(VENDOR_PREFIXES_RE, text["property_service.cpp"])
    prefixes = re.findall(r"\"([^\"]+)\"", m.group(1)) if m else None
    if not prefixes:
        bad.append("premise: property_service.cpp's kVendorPathPrefixes is gone")
    elif any(rootfs.RAMDISK_PROP.startswith(p) for p in prefixes):
        bad.append("premise: %s would load as vendor_init"
                   % rootfs.RAMDISK_PROP)
    try:
        vold = open(os.path.join(aosp, "system", "vold", "main.cpp")).read()
    except OSError as e:
        vold = ""
        bad.append("premise: cannot read system/vold/main.cpp (%s)" % e.strerror)
    for pat, why in VOLD_PREMISE if vold else ():
        if not re.search(pat, vold, re.S):
            bad.append("premise: vold main.cpp -- %s" % why)
    body = re.search(r"void SelinuxRestoreContext\(\) \{(.*?)\n\}", text["selinux.cpp"], re.S)
    body = body.group(1) if body else ""
    for path in rootfs.INIT_RESTORECON:
        if "*" in path:
            ok = 'selinux_android_restorecon("%s", SELINUX_ANDROID_RESTORECON_RECURSE)' \
                % os.path.dirname(path) in body
        else:
            ok = 'selinux_android_restorecon("%s", 0)' % path in body
        if not ok:
            bad.append("premise: selinux.cpp's SelinuxRestoreContext no longer relabels %s" % path)
    return bad


def check_gsi_init(name, init_bytes, vold_bytes=b"/sys/block"):
    """check the init and vold binaries for the modeled strings"""
    return ["premise: %s's %s has no %r"
            % (name, what, s.decode())
            for what, strings, blob in (("init", GSI_INIT_STRINGS, init_bytes),
                                        ("vold", GSI_VOLD_STRINGS, vold_bytes))
            for s in strings if s not in blob]


def node(uevent=None, **children):
    """return a fixture tree node with a uevent and children"""
    return {"uevent": uevent, "children": children}


def lookup(tree, rel):
    """return the uevent node for a relative path, or None"""
    n = tree
    for part in rel.split("/")[:-1]:
        n = n["children"].get(part)
        if n is None:
            return None
    return n if rel.endswith("/uevent") else None


def apply_shadow(real, ops):
    """return the /sys/devices view for the ops"""
    if not ops:
        return real
    view = None
    for op, src, dst in ops:
        if op == "tmpfs" and dst == "/sys/devices":
            view = node()
        elif op == "bind" and view is not None:
            rel = dst[len("/sys/devices/"):]
            if src.endswith("/uevent") or src == "uevent":
                owner = lookup(real, src)
                if rel == "uevent":
                    view["uevent"] = owner["uevent"] if owner else None
            else:
                view["children"][rel] = real["children"].get(src, node())
    return view


def regen(view, path, stop_on_event, writes):
    """record uevent writes under a directory"""
    if view["uevent"]:
        writes.append((path + "/uevent", view["uevent"]))
        if stop_on_event:
            return True
    for name in sorted(view["children"]):
        if regen(view["children"][name], path + "/" + name, stop_on_event, writes):
            return True
    return False


def parse_props(text):
    """return the key=value properties in a text, skipping comments"""
    props = {}
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            props[k.strip()] = v.strip()
    return props


def ueventd_host_writes(view, props):
    """return the host uevent paths ueventd writes"""
    writes = []
    regen(view, "/sys/devices", True, writes)
    host = [(p, "boot-partition replay") for p, o in writes if o == "host"]
    if props.get("ro.cold_boot_done") != "true":
        writes = []
        regen(view, "/sys/devices", False, writes)
        host += [(p, "ColdBoot::Run") for p, o in writes if o == "host"]
    return host


def fixture_sys_devices():
    """return a fixture /sys/devices tree"""
    return node(
        None,
        breakpoint=node("host"),
        **{"pci0000:00": node("host", **{
            "0000:00:02.0": node("host"),
            "0000:00:1f.2": node("host", block=node(None, sda=node(
                "host", sda1=node("host"), queue=node(None), holders=node(None))))})},
        platform=node("host", serial8250=node("host")),
        virtual=node(None,
                     net=node(None, lo=node("sandbox")),
                     block=node(None, loop0=node("host"), loop1=node("host")),
                     misc=node(None, fuse=node("host"), uinput=node("host")),
                     msr=node(None, msr0=node("host"))))


BLOCK_LINKS = {"sda": "../devices/pci0000:00/0000:00:1f.2/block/sda",
               "loop0": "../devices/virtual/block/loop0",
               "loop1": "../devices/virtual/block/loop1"}


def build_sys_tree(root):
    """create the fixture /sys tree under root"""
    build_tree(fixture_sys_devices(), os.path.join(root, "sys", "devices"))
    os.makedirs(os.path.join(root, "sys", "block"))
    for name, target in BLOCK_LINKS.items():
        os.symlink(target, os.path.join(root, "sys", "block", name))
    os.symlink("../..", os.path.join(root, "sys", "devices", "pci0000:00", "0000:00:1f.2",
                                     "block", "sda", "device"))


def vold_coldboot_writes(block_dir):
    """return the uevent files vold writes"""
    out = []

    def walk(d, lvl):
        """record every uevent file under a directory"""
        if os.path.isfile(os.path.join(d, "uevent")):
            out.append(os.path.realpath(os.path.join(d, "uevent")))
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        for de in entries:
            if de.name.startswith("."):
                continue
            if lvl > 0 and not de.is_dir(follow_symlinks=False):
                continue
            if os.path.isdir(de.path):
                walk(de.path, lvl + 1)
    walk(block_dir, 0)
    return out


def host_uevents(root):
    """return the fixture uevent files marked host"""
    out = set()
    for d, _dirs, files in os.walk(os.path.join(root, "sys")):
        if "uevent" in files and open(os.path.join(d, "uevent")).read() == "host":
            out.add(os.path.join(d, "uevent"))
    return out


def check_vold(rig, root, writes, hosts):
    """return findings for vold host uevent writes"""
    rdonly, sinks, host = set(), {}, []
    for c in rig.calls:
        if c[0] != "mount" or len(c) != 5:
            continue
        _, s, t, fs, fl = c
        if fs == "tmpfs":
            rdonly.discard(t)
        elif fl & rig.rm.MS_REMOUNT and fl & rig.rm.MS_RDONLY and not fl & rig.rm.MS_BIND:
            rdonly.add(t)
        elif fs is None and fl & rig.rm.MS_BIND and s:
            sinks[t] = any(s.startswith(d + "/") for d in rdonly)
    for w in writes:
        if sinks.get(w):
            continue
        if w in hosts:
            host.append(w[len(root):])
    if not host:
        return []
    return ["vold: its cold boot of /sys/block writes %d host uevent(s): %s"
            % (len(host), " ".join(host[:6]) + (" ..." if len(host) > 6 else ""))]


def exec_vold(rm, fail_mount=()):
    """run _shadow_block_uevents on a fixture tree"""
    with tempfile.TemporaryDirectory() as t:
        root = os.path.join(t, "root")
        build_sys_tree(root)
        rig = Rig(rm, root, {root + p for p in fail_mount})
        hosts = host_uevents(root)
        fn = getattr(rm, "_shadow_block_uevents", None)
        if fn is not None:
            with rig.patched():
                fn()
        writes = vold_coldboot_writes(os.path.join(root, "sys", "block"))
        bad = check_vold(rig, root, writes, hosts)
        if not writes:
            bad.append("vold: the model walked no uevent in the fixture's /sys/block")
        rig.calls = [c[:1] + tuple(x[len(root):] if isinstance(x, str) and x.startswith(root) else x
                                   for x in c[1:]) for c in rig.calls]
    return rig, bad


LATE_DISK = "pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host2/target2:0:0/2:0:0:0/block/sdb"


def plug_late_disk(root):
    """add LATE_DISK and return its uevent datagrams"""
    disk = os.path.join(root, "sys", "devices", LATE_DISK)
    os.makedirs(os.path.join(disk, "sdb1"))
    os.makedirs(os.path.join(disk, "queue"))
    for d in (disk, os.path.join(disk, "sdb1")):
        with open(os.path.join(d, "uevent"), "w") as f:
            f.write("host")
    os.symlink("../devices/" + LATE_DISK, os.path.join(root, "sys", "block", "sdb"))
    return [("add@/devices/%s%s\0ACTION=add\0DEVPATH=/devices/%s%s\0SUBSYSTEM=block\0"
             % (LATE_DISK, p, LATE_DISK, p)).encode() for p in ("", "/sdb1")]


class KernelShaped:
    """datagram socket with kernel address"""

    def __init__(self, sock):
        """keep the socket"""
        self.sock = sock

    def fileno(self):
        """return the socket's file descriptor"""
        return self.sock.fileno()

    def recvfrom(self, n):
        """return the received data with a fixed sender address"""
        return self.sock.recv(n), (0, 1)


def exec_vold_late(rm):
    """check vold block uevents with a late disk"""
    import socket
    with tempfile.TemporaryDirectory() as t:
        root = os.path.join(t, "root")
        build_sys_tree(root)
        rig = Rig(rm, root)
        hosts = host_uevents(root)
        plan, planned = rm.plan_block_uevents, []
        with rig.patched():
            rm._shadow_block_uevents()
            datagrams = plug_late_disk(root)
            rm.plan_block_uevents = lambda *a: planned.append(plan(*a)) or planned[-1]
            hosts |= host_uevents(root) - hosts
            a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
            for d in datagrams:
                b.send(d)
            b.send(b"")
            try:
                rm.run_input_fence(rm.InputFence(os.path.join(root, "sys")), KernelShaped(a), root, rig.kmsg)
            finally:
                rm.plan_block_uevents = plan
            a.close()
            b.close()
        strays = sorted({t for ts in planned for t in ts if "/sdb" not in t})
        if strays:
            bad_walk = ["vold-late: an add walked %d uevent(s) of devices it does not name: %s"
                        % (len(strays), " ".join(t[len(root):] for t in strays[:4]))]
        else:
            bad_walk = []
        writes = vold_coldboot_writes(os.path.join(root, "sys", "block"))
        bad = check_vold(rig, root, writes, hosts)
        late = [w for w in writes if "/sdb" in w]
        if len(late) != 2:
            bad.append("vold-late: the model walked %d of the plugged disk's 2 uevents" % len(late))
        binds = [c for c in rig.calls if c[0] == "mount" and c[3] is None and "/sdb" in c[2]]
        if len(binds) != 2:
            bad.append("vold-late: the fence made %d bind(s) over the plugged disk's 2 uevents, "
                       "one each is the whole job" % len(binds))
    return rig, [f.replace("vold:", "vold-late:", 1) for f in bad] + bad_walk


def check_walk_stats(rm):
    """return findings for /sys/block attribute file stats"""
    with tempfile.TemporaryDirectory() as t:
        root = os.path.join(t, "root")
        build_sys_tree(root)
        sda = os.path.join(root, "sys", "devices", "pci0000:00", "0000:00:1f.2", "block", "sda")
        for f in ("size", "ro", "sda1/start", "queue/rotational"):
            open(os.path.join(sda, f), "w").close()
        statted = []
        saved = os.stat, os.lstat
        os.stat = lambda p, *a, **k: statted.append(p) or saved[0](p, *a, **k)
        os.lstat = lambda p, *a, **k: statted.append(p) or saved[1](p, *a, **k)
        try:
            planned = rm.plan_block_uevents(os.path.join(root, "sys"))
        finally:
            os.stat, os.lstat = saved
        attrs = sorted({os.fspath(p)[len(root):] for p in statted
                        if os.path.basename(os.fspath(p)) != "uevent" and os.path.isfile(p)
                        and not os.path.islink(p)})
    bad = []
    if not any(p.endswith("/sda/sda1/uevent") for p in planned):
        bad.append("walk-stats: the walk planned no uevent for sda1")
    if attrs:
        bad.append("walk-stats: the /sys/block walk stats %d attribute file(s): %s"
                   % (len(attrs), " ".join(attrs)))
    return bad


def check_replay(ops, ramdisk_text):
    """replay the shadow plan and check init's writes"""
    real = fixture_sys_devices()
    view = apply_shadow(real, ops)
    if view is None:
        return ["replay: plan_sys_devices_shadow() puts no tmpfs over /sys/devices"]
    writes = ueventd_host_writes(view, parse_props(ramdisk_text))
    by_pass = {}
    for p, which in writes:
        by_pass.setdefault(which, []).append(p)
    return ["replay: ueventd's %s writes %d host uevent(s): %s"
            % (which, len(ps), " ".join(ps[:6]) + (" ..." if len(ps) > 6 else ""))
            for which, ps in by_pass.items()]


def call_site_sources():
    """return the sources of the launcher call sites that make the shadow"""
    return (inspect.getsource(rootfs._make_dev_nodes),
            inspect.getsource(rootfs._bind_sockets_and_shadows),
            open(LAUNCHER).read())


def check_call_sites(make, shadows, launcher_text):
    """return findings for launcher call sites"""
    bad = []
    if "_stage_coldboot()" not in make:
        bad.append("call site: _make_dev_nodes() no longer calls _stage_coldboot()")
    m = re.search(r'mount\("sysfs",f"\{NEWROOT\}/sys","sysfs",0\)\n((?:\s*#[^\n]*\n)*)\s*_shadow_sys_devices\(\)',
                  shadows)
    if not m:
        bad.append("call site: _shadow_sys_devices() does not follow the sandbox's sysfs mount")
    if not re.search(r'\n(\s*)_shadow_sys_devices\(\)\n\1_shadow_block_uevents\(\)\n', shadows):
        bad.append("call site: _shadow_block_uevents() does not follow _shadow_sys_devices()")
    bad += check_primer_substitution(launcher_text, rootfs.coldboot_primer_spec())
    bad += check_fence_sweep(inspect.getsource(rootfs.start_input_fence))
    return bad


START_SWEEP = 'sink_late_block_uevents("", kmsg)'


def check_fence_sweep(src):
    """check the order of bind and sweep"""
    bind, sweep = src.find("sock.bind((0, 1))"), src.find(START_SWEEP)
    if sweep < 0:
        return ["call site: start_input_fence() no longer calls %s" % START_SWEEP]
    if not 0 <= bind < sweep:
        return ["call site: start_input_fence() sweeps /sys/block before its uevent socket is "
                "bound"]
    return []


PRIMER_CONSUME_RE = (r'_RELABEL_SPEC \+= (\[tuple\(_e\.split\("=", 1\)\) for _e in '
                     r'"@RHIZO_COLDBOOT_RELABEL@"\.split\(","\)\s*if "=" in _e\])')
PRIMER_WRITE_RE = (r'\.replace\("@RHIZO_COLDBOOT_RELABEL@",\s*'
                   r'","\.join\(f"\{p\}=\{lbl\}" for p, lbl in coldboot_primer_spec\(\)\)\)')


def check_primer_substitution(launcher_text, spec):
    """return findings for the primer spec substitution"""
    m = re.search(PRIMER_CONSUME_RE, launcher_text)
    if not m:
        return ["call site: the host primer no longer adds @RHIZO_COLDBOOT_RELABEL@ to its relabel spec"]
    if not re.search(PRIMER_WRITE_RE, launcher_text):
        return ["call site: boot.py no longer writes coldboot_primer_spec() into the primer"]
    written = ",".join("%s=%s" % (p, lbl) for p, lbl in spec)
    got = eval(m.group(1).replace("@RHIZO_COLDBOOT_RELABEL@", written))
    if got != [tuple(e) for e in spec]:
        return ["call site: the primer reads back %s, not coldboot_primer_spec()" % got[:3]]
    return []


def parse_ueventd_rc(text):
    """parse the /dev lines of ueventd.rc"""
    rules = []
    for line in text.splitlines():
        f = line.split()
        if len(f) == 4 and f[0].startswith("/dev/"):
            rules.append((f[0], int(f[1], 8), f[2], f[3]))
    return rules


def ueventd_rule(rules, path):
    """return the last matching ueventd.rc rule"""
    for name, mode, uid, gid in reversed(rules):
        if rc_matches(name, path):
            return mode, uid, gid
    return 0o600, "root", "root"


def fnmatch_pathname(pat, path):
    """match a path against an fnmatch pattern"""
    rx = ""
    for ch in pat:
        rx += "[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch)
    return re.fullmatch(rx, path) is not None


def parse_file_contexts(text):
    """parse file_contexts text into specs"""
    specs = []
    for line in text.splitlines():
        f = line.split()
        if not f or f[0].startswith("#"):
            continue
        if len(f) == 2:
            specs.append((f[0], None, f[1]))
        elif len(f) == 3:
            specs.append((f[0], f[1], f[2]))
    return specs


def best_label(specs, path, kind):
    """return the file_contexts label of a path"""
    want = {"c": "-c", "b": "-b", "d": "-d"}[kind]
    hits = [(i, ctx) for i, (rx, flag, ctx) in enumerate(specs)
            if (flag is None or flag == want) and re.fullmatch(rx, path)]
    if not hits:
        return None
    exact = [h for h in hits if not re.search(r"[.^$?*+|\[\](){}\\]", specs[h[0]][0])]
    return (exact or hits)[-1][1]


def relabel_dest_types(policy_text):
    """return the destination types in the policy's relabel attribute set"""
    m = re.search(r"\(typeattributeset rhizo_relabel_dest_dev \(([^)]*)\)\)", policy_text)
    return set(m.group(1).split()) if m else set()


def sample_path(row):
    """return a sample path with the wildcards in a row filled in"""
    return row.replace("[0-9]*", "7").replace("?*", FIXTURE_BOOT_ID)


def launcher_labels():
    """return the /dev entries of PRE_INIT_RELABEL"""
    return {p: lbl for p, lbl in selinux_labels.PRE_INIT_RELABEL if p.startswith("/dev/")}


def check_parity(release, ueventd_text, fc_text, perms, heap_dir, relabel_types, owned=None):
    """check staged node permissions against ueventd.rc"""
    bad = []
    owned = owned or {}
    rules, specs = parse_ueventd_rc(ueventd_text), parse_file_contexts(fc_text)
    if not rules or not specs:
        return ["parity: %s: ueventd.rc or plat_file_contexts read empty" % release]
    for row, (mode, uid, gid, label) in perms.items():
        path = sample_path(row)
        kind = "b" if path.startswith("/dev/block/") else "c"
        rmode, ruid, rgid = ueventd_rule(rules, path)
        if ruid not in AID or rgid not in AID:
            bad.append("parity: %s: ueventd.rc owns %s by %s:%s, no AID this checker knows"
                       % (release, path, ruid, rgid))
        elif (mode, uid, gid) != (rmode, AID[ruid], AID[rgid]):
            bad.append("parity: %s: %s is staged %o %d:%d, ueventd.rc says %o %s:%s"
                       % (release, path, mode, uid, gid, rmode, ruid, rgid))
        want = owned.get(path) or best_label(specs, path, kind)
        if want != label:
            bad.append("parity: %s: %s is labeled %s, %s says %s"
                       % (release, path, label, "the launcher's PRE_INIT_RELABEL"
                          if path in owned else "plat_file_contexts", want))
    want = best_label(specs, heap_dir[0], "d")
    if want != heap_dir[2]:
        bad.append("parity: %s: %s is labeled %s, plat_file_contexts says %s"
                   % (release, heap_dir[0], heap_dir[2], want))
    for label in sorted({v[3] for v in perms.values()} | {heap_dir[2]}):
        t = label.split(":")[2]
        if t not in relabel_types:
            bad.append("parity: %s is not in rhizo_relabel_dest_dev" % t)
    return bad


def check_first_start_labels(perms, init_restorecon, primer_spec):
    """check the labels of staged nodes"""
    import fnmatch
    primed = {p for p, _ in primer_spec}
    bad = []
    for row, v in perms.items():
        if row in init_restorecon or row in primed or row in PRIMER_OWN:
            continue
        if row.endswith("?*") and any(fnmatch.fnmatchcase(p, row) for p in primed):
            continue
        bad.append("labels: %s is labeled by neither init's restorecon nor the primer "
                   "on a first start" % row)
    for p, label in primer_spec:
        if p in perms and perms[p][3] != label:
            bad.append("labels: the primer gives %s %s, STAGED_DEV_PERMS %s" % (p, label, perms[p][3]))
    return bad


FIXTURE_BOOT_ID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

HOST_DEVICES = (
    ("mem", "null", None), ("mem", "zero", None), ("mem", "full", None),
    ("mem", "random", None), ("mem", "urandom", None), ("mem", "kmsg", None),
    ("mem", "port", None),
    ("tty", "tty", None), ("tty", "console", None), ("tty", "ptmx", None), ("tty", "tty0", None),
    ("tty", "ttyS0", None), ("tty", "ttyUSB0", None), ("tty", "ttyACM0", None),
    ("misc", "ashmem", None), ("misc", "loop-control", None), ("misc", "device-mapper", None),
    ("misc", "fuse", None), ("misc", "hw_random", None), ("misc", "uinput", None),
    ("misc", "uhid", None), ("misc", "tun", "net/tun"), ("misc", "kvm", None),
    ("misc", "vhost-vsock", None), ("misc", "udmabuf", None), ("misc", "ppp", None),
    ("misc", "ublk-control", None), ("misc", "system_a", "dm-user/system_a"),
    ("misc", "keychord", None), ("misc", "xt_qtaguid", None), ("misc", "ion", None),
    ("misc", "pn544", None), ("misc", "rproc_user", None), ("misc", "pvrsrvkm", None),
    ("misc", "wrapfd", None), ("misc", "nvhdcp1", None), ("misc", "eac", None),
    ("misc", "rfkill", None), ("misc", "mtp_usb", None), ("misc", "usb_accessory", None),
    ("rpmsg", "rpmsg-omx0", None), ("modem", "modem0", None), ("sound", "controlC0", "snd/controlC0"),
    ("sound_oss", "audio", None), ("sound_oss", "spdif_out", None),
    ("watchdog", "watchdog", None), ("pmsg", "pmsg0", None), ("rtc", "rtc0", None),
    ("gnss", "gnss0", None), ("iio", "iio:device0", None), ("uio", "uio0", None),
    ("ublk-char", "ublkc0", None), ("video4linux", "video0", None),
    ("video4linux", "v4l-touch0", None), ("vfio", "7", "vfio/7"),
    ("graphics", "fb0", None), ("adf", "adf0", None), ("adf", "adf-interface0.0", None),
    ("adf", "adf-overlay-engine0.0", None),
    ("drm", "renderD128", "dri/renderD128"), ("drm", "card0", "dri/card0"),
    ("input", "event3", "input/event3"), ("hidraw", "hidraw0", None), ("usb", "1-1", None),
    ("dma_heap", "system", None), ("dma_heap", "system-uncached", None),
    ("dma_heap", "system-secure", None), ("dma_heap", "reserved", None),
    ("block", "loop0", None), ("block", "loop1", None), ("block", "loop2", None),
    ("block", "loop10", None), ("block", "loop0p1", None), ("block", "sda", None),
    ("block", "vda", None), ("block", "dm-0", None), ("block", "zram0", None),
    ("block", "ram0", None), ("block", "ublkb0", None),
)

NOT_UEVENT = {
    "/dev/binder": "a link init.rc makes into its own binderfs",
    "/dev/hwbinder": "a link init.rc makes into its own binderfs",
    "/dev/vndbinder": "a link init.rc makes into its own binderfs",
    "/dev/kmsg_debug": "first_stage_init's own mknod on a debuggable build",
    "/dev/block/mapper/*.apex": "a link ueventd makes for apexd's own dm device, from its add after the start",
    "/dev/block/mapper/.*\\.apex": "a link ueventd makes for apexd's own dm device, from its add after the start",
    "/dev/block/by-name/zoned_device": "a link init makes from the fstab",
    "/dev/block/vold/.+": "nodes vold makes itself",
    "/dev/boringssl/selftest(/.*)?": "a marker file boringssl writes",
    "/dev/event-log-tags": "a file logd writes",
    "/dev/cgroup_info(/.*)?": "files init writes",
    "/dev/fscklogs(/.*)?": "a directory init makes",
    "/dev/cpu_variant:.*": "files init writes",
    "/dev/sys/block/by-name/rootdisk(/.*)?": "links init makes",
    "/dev/sys/block/by-name/userdata(/.*)?": "links init makes",
    "/dev/sys/fs/by-name/userdata(/.*)?": "links init makes",
    "/dev/usb-ffs/aoa/ep1": "a functionfs endpoint of the USB gadget",
    "/dev/usb-ffs/aoa/ep2": "a functionfs endpoint of the USB gadget",
}
NOT_DEVICE_PREFIXES = ("/dev/socket", "/dev/__properties__")

GENERIC_LABELS = ("u:object_r:device:s0", "u:object_r:block_device:s0")

NODE_FATES = (
    (r"/dev/(loop-control|device-mapper|fuse|hw_random)", "coldboot",
     "apexd waits on loop-control, libdm opens device-mapper, vold's FUSE storage fuse, prng_seeder hw_random"),
    (r"/dev/dma_heap/(system|system-uncached)", "coldboot", "libdmabufheap and Codec2's allocator"),
    (r"/dev/block/loop[0-9]+", "coldboot", "apexd takes the idle loop devices"),
    (r"/dev/ashmem[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", "coldboot",
     "libcutils opens ashmem by ueventd's boot-id duplicate"),
    (r"/dev/(null|zero|full|random|urandom|tty|console|kmsg|ashmem)", "dev-node", None),
    (r"/dev/dri/(renderD128|card0)", "capability", None),
    (r"/dev/(uinput|tun)", "capability", None),
    (r"/dev/uhid", "launcher", ("_bind_sockets_and_shadows", 'f"{NEWROOT}/dev/uhid"')),
    (r"/dev/ptmx", "launcher", ("_mount_extra_partitions", 'os.symlink("pts/ptmx",f"{NEWROOT}/dev/ptmx")')),
    (r"/dev/input/event[0-9]+", "launcher", ("InputFence", "_EVENT_DEVNAME.fullmatch(name)")),
    (r"/dev/hidraw[0-9]+", "launcher", ("InputFence", "_HIDRAW_DEVNAME.fullmatch(name)")),
    (r"/dev/bus/usb/[0-9]{3}/[0-9]{3}", "withheld",
     "the host's USB devices"),
    (r"/dev/block/(dm-[0-9]+|vd[a-z][0-9]*|zram[0-9]+|ram[0-9]+|ublkb[0-9]+)", "withheld",
     "the host's own disks, device-mapper targets, zram swap and ram disks"),
    (r"/dev/dma_heap/.+", "withheld", "a heap nothing in the sandbox allocates from (system-secure is a TEE's)"),
    (r"/dev/(kvm|vhost-vsock)", "withheld",
     "AVF's: only crosvm is granted kvm_device, and Rhizo declares no virtualization_framework"),
    (r"/dev/rtc[0-9]", "withheld", "the host's hardware clock"),
    (r"/dev/udmabuf", "withheld", "only crosvm is granted udmabuf_device, and rhizo_dev_ok excludes it"),
    (r"/dev/(snd/.+|audio|spdif_out|eac)", "withheld", "the host's sound devices; audio goes through audiod"),
    (r"/dev/(graphics/.+|adf.*)", "withheld", "fbdev and ADF; the composer renders through /dev/dri"),
    (r"/dev/(video[0-9]+|v4l-touch[0-9]+|nvhdcp1)", "withheld", "V4L2 devices; Rhizo has no camera HAL"),
    (r"/dev/(tty[0-9]+|ttyS[0-9]+|ttyUSB[0-9]+|ttyACM[0-9]+|ppp|modem.*)", "withheld",
     "the host's consoles and serial lines; Rhizo has no radio"),
    (r"/dev/pmsg0", "withheld", "the host's pstore: Android's logs must not persist in it"),
    (r"/dev/watchdog", "withheld", "the host's watchdog: opening it arms it"),
    (r"/dev/port", "withheld", "raw I/O port access"),
    (r"/dev/(mtp_usb|usb_accessory)", "withheld", "the USB gadget side"),
    (r"/dev/vfio/.+", "withheld", "device passthrough"),
    (r"/dev/(ublk-control|ublkc[0-9]+|dm-user/.+)", "withheld", "userspace block devices, snapuserd's for an OTA"),
    (r"/dev/(ion|keychord|xt_qtaguid)", "withheld", "a driver Linux removed before the host kernels Rhizo runs on"),
    (r"/dev/(gnss[0-9]+|iio:device[0-9]+|uio[0-9]+|pn544|rpmsg-omx[0-9]|rproc_user|pvrsrvkm|wrapfd)",
     "withheld", "a phone SoC's device, whose vendor HAL Rhizo does not ship"),
    (r"/dev/.+", "unlabeled", None),
)


def rc_matches(pat, path):
    """match a path against a ueventd.rc rule name"""
    star = pat.find("*")
    if star < 0:
        return path == pat
    if star == len(pat) - 1:
        return path.startswith(pat[:-1])
    return fnmatch_pathname(pat, path)


def parse_subsystems(text):
    """parse the subsystem sections of ueventd.rc"""
    subs, cur = {}, None
    for line in text.splitlines():
        f = line.split()
        if not f or f[0].startswith("#"):
            continue
        if f[0] == "subsystem" and len(f) == 2:
            cur = f[1]
            subs.setdefault(cur, ["uevent_devname", "/dev"])
        elif cur is not None and f[0] == "devname" and len(f) == 2:
            subs[cur][0] = f[1]
        elif cur is not None and f[0] == "dirname" and len(f) == 2:
            subs[cur][1] = f[1]
        else:
            cur = None
    return {k: tuple(v) for k, v in subs.items()}


def ueventd_node_paths(cls, name, devname, minor, subs, dup_names, boot_id):
    """return the /dev paths for a device"""
    devname = devname or name
    if cls == "block":
        path = "/dev/block/" + name
    elif cls in subs:
        source, dirname = subs[cls]
        path = dirname + "/" + (name if source == "uevent_devpath" else devname)
    elif cls == "usb":
        path = "/dev/bus/usb/%03d/%03d" % (minor // 128 + 1, minor % 128 + 1)
    elif cls.startswith("usb"):
        return []
    elif cls == "misc" and (devname.startswith("dm-user/") or devname == "vfio/vfio"
                            or devname.startswith("ublk")):
        path = "/dev/" + devname
    else:
        path = "/dev/" + name
    return [path] + ([path + boot_id] if devname in dup_names else [])


def host_device_numbers():
    """return the host devices with their numbers"""
    out = []
    for i, (cls, name, devname) in enumerate(HOST_DEVICES):
        if cls == "block" and re.fullmatch(r"loop[0-9]+", name):
            major, minor = 7, int(name[4:])
        elif cls == "usb":
            major, minor = 189, 0
        else:
            major, minor = 240, i
        out.append((cls, name, devname, "b" if cls == "block" else "c", major, minor))
    return out


def build_sysfs(root):
    """write the HOST_DEVICES /sys/class tree"""
    for cls, name, _devname, _kind, major, minor in host_device_numbers():
        d = os.path.join(root, "class", cls, name)
        os.makedirs(d)
        with open(os.path.join(d, "dev"), "w") as f:
            f.write("%d:%d\n" % (major, minor))


def build_proc(root):
    """write the fixture boot_id file"""
    os.makedirs(os.path.join(root, "sys", "kernel", "random"))
    with open(os.path.join(root, "sys", "kernel", "random", "boot_id"), "w") as f:
        f.write(FIXTURE_BOOT_ID + "\n")


def ueventd_made(ueventd_text, dup_names):
    """return the device nodes for HOST_DEVICES"""
    subs = parse_subsystems(ueventd_text)
    made = {}
    for cls, name, devname, kind, major, minor in host_device_numbers():
        for p in ueventd_node_paths(cls, name, devname, minor, subs, dup_names, FIXTURE_BOOT_ID):
            made[p] = (kind, major, minor)
    return made


def node_fate(path):
    """return the fate and detail of a device node path, or None"""
    for rx, fate, detail in NODE_FATES:
        if re.fullmatch(rx, path):
            return fate, detail
    return None, None


def fixture_coldboot_nodes(ueventd_text, dup_names):
    """return the coldboot fixture nodes"""
    return {p: v for p, v in ueventd_made(ueventd_text, dup_names).items() if node_fate(p)[0] == "coldboot"}


def authority_paths(ueventd_text, fc_text):
    """list the /dev rules of ueventd.rc and file_contexts"""
    out = [("ueventd.rc", name, lambda p, n=name: rc_matches(n, p))
           for name, _mode, _uid, _gid in parse_ueventd_rc(ueventd_text)]
    for rx, _flag, _ctx in parse_file_contexts(fc_text):
        if rx.startswith("/dev") and not rx.startswith(NOT_DEVICE_PREFIXES):
            out.append(("file_contexts", rx, lambda p, r=rx: re.fullmatch(r, p) is not None))
    return out


DUP_RE = (r'void DeviceHandler::HandleAshmemUevent\(const Uevent& uevent\) \{\s*'
          r'if \(uevent\.device_name == "(\w+)"\).*?dup_\w+\.device_name \+= boot_id;')
LIBCUTILS_ASHMEM_RE = r'return "/dev/ashmem" \+ boot_id;'


def dup_names_of(devices_cpp, ashmem_dev_cpp):
    """return the duplicated device names"""
    m = re.search(DUP_RE, devices_cpp, re.S)
    if not m:
        return set(), ["model: devices.cpp's HandleAshmemUevent no longer duplicates a device under the boot id"]
    if not re.search(LIBCUTILS_ASHMEM_RE, ashmem_dev_cpp):
        return set(), ["model: libcutils no longer opens ashmem as /dev/ashmem<boot_id>"]
    return {m.group(1)}, []


def aosp_dup_names(aosp):
    """return the duplicate device names in the AOSP sources"""
    try:
        devices = open(os.path.join(aosp, "system", "core", "init", "devices.cpp")).read()
        ashmem = open(os.path.join(aosp, "system", "core", "libcutils", "ashmem-dev.cpp")).read()
    except OSError as e:
        return set(), ["model: cannot read the AOSP source it models (%s)" % e]
    return dup_names_of(devices, ashmem)


def launcher_sources(names):
    """return the source of each rootfs name"""
    return {n: inspect.getsource(getattr(rootfs, n)) for n in names}


def check_node_set(release, ueventd_text, fc_text, plan_fn, perms_fn, dup_names,
                   dev_nodes, cap_nodes, sources):
    """check the staged nodes against ueventd.rc and file_contexts"""
    bad = []
    made = ueventd_made(ueventd_text, dup_names)
    specs = parse_file_contexts(fc_text)
    with tempfile.TemporaryDirectory() as t:
        build_sysfs(t)
        build_proc(os.path.join(t, "proc"))
        plan = plan_fn(t, os.path.join(t, "proc"))
    staged = {rel: (kind, major, minor) for rel, kind, major, minor in plan}
    for src, pat, match in authority_paths(ueventd_text, fc_text):
        if pat not in NOT_UEVENT and not any(match(p) for p in made):
            bad.append("authority: %s: %s names %s, which ueventd makes for no host device the "
                       "fixture holds and NOT_UEVENT does not explain" % (release, src, pat))
    for p in sorted(made):
        fate, detail = node_fate(p)
        if fate is None:
            bad.append("fate: %s: ueventd's cold boot makes %s, and NODE_FATES gives it no fate" % (release, p))
        elif fate == "coldboot":
            if p not in staged:
                bad.append("coldboot: %s: ueventd's cold boot made %s, which Android opens (%s), and "
                           "plan_coldboot_nodes stages none" % (release, p, detail))
            elif staged[p] != made[p]:
                bad.append("coldboot: %s: %s is staged as %s, ueventd made it %s" % (release, p, staged[p], made[p]))
        elif fate == "dev-node" and p[len("/dev/"):] not in dev_nodes:
            bad.append("fate: %s: %s is a DEV_NODES alias by its fate, and DEV_NODES has no %s"
                       % (release, p, p[len("/dev/"):]))
        elif fate == "capability" and p[len("/dev/"):] not in cap_nodes:
            bad.append("fate: %s: %s is a capability's node by its fate, and no DEVICE_NODE_CAPABILITIES "
                       "row governs it" % (release, p))
        elif fate == "launcher" and detail[1] not in sources.get(detail[0], ""):
            bad.append("fate: %s: %s is made by %s by its fate, and its source no longer holds %s"
                       % (release, p, detail[0], detail[1]))
        if fate in ("withheld", "unlabeled") and (p[len("/dev/"):] in dev_nodes or p[len("/dev/"):] in cap_nodes):
            bad.append("fate: %s: %s is %s by its fate, and the launcher stages it anyway (%s)"
                       % (release, p, fate, "DEV_NODES" if p[len("/dev/"):] in dev_nodes else "a capability"))
        if fate == "unlabeled":
            label = best_label(specs, p, made[p][0])
            if label not in GENERIC_LABELS:
                bad.append("fate: %s: %s is labeled %s by file_contexts" % (release, p, label))
    for rel in sorted(staged):
        if node_fate(rel)[0] != "coldboot" or rel not in made:
            bad.append("coverage: %s: %s is staged from the cold boot's set, which nothing opens" % (release, rel))
        try:
            perms_fn(rel)
        except KeyError:
            bad.append("coverage: %s: %s is staged with no STAGED_DEV_PERMS row" % (release, rel))
    return bad


def run_node_set(release, ueventd_text, fc_text, aosp=None, rm=None):
    """run check_node_set on a launcher module"""
    rm = rm or rootfs
    dups, bad = aosp_dup_names(aosp or AOSP)
    if bad:
        return bad
    sources = launcher_sources({d[0] for _rx, f, d in NODE_FATES if f == "launcher"})
    caps = {n for nodes in rm.DEVICE_NODE_CAPABILITIES.values() for n in nodes}
    return check_node_set(release, ueventd_text, fc_text, rm.plan_coldboot_nodes, rm.staged_dev_perms,
                          dups, rm.DEV_NODES, caps, sources)




class Rig:
    """fake system calls for rootfs"""

    def __init__(self, rm, root, fail_mount=(), fail_mknod=()):
        """set the fields from the arguments"""
        self.rm, self.root = rm, root
        self.fail_mount, self.fail_mknod = set(fail_mount), set(fail_mknod)
        self.calls = []
        self.new_tmpfs = set()

    def mount(self, s, t, fs, fl, d=None):
        """record a mount call and return whether it succeeded"""
        self.calls.append(("mount", s, t, fs, fl))
        if t in self.fail_mount or not os.path.lexists(t):
            self.calls[-1] += (False,)
            return False
        if fs == "tmpfs" and os.path.isdir(t) and not os.listdir(t):
            self.new_tmpfs.add(t)
        if fs is None and fl & self.rm.MS_BIND and not fl & self.rm.MS_REMOUNT \
                and s and os.path.isdir(s) and os.path.isdir(t) and not os.listdir(t):
            os.rmdir(t)
            os.symlink(s, t)
        elif fs is None and fl & self.rm.MS_BIND and not fl & self.rm.MS_REMOUNT \
                and s and os.path.isfile(s) and os.path.isfile(t) and not os.path.islink(t):
            os.unlink(t)
            os.link(s, t)
        return True

    def umount2(self, t, flags):
        """record an unmount call and undo the mount in the fixture"""
        t = t.decode() if isinstance(t, bytes) else t
        self.calls.append(("umount", t))
        if os.path.islink(t):
            os.unlink(t)
            os.mkdir(t)
        elif t in self.new_tmpfs:
            self.new_tmpfs.discard(t)
            shutil.rmtree(t)
            os.mkdir(t)
        return 0

    def mknod(self, path, mode, dev=0):
        """record a node creation, failing for paths set to fail"""
        self.calls.append(("mknod", path, mode, dev))
        if path in self.fail_mknod:
            raise PermissionError(1, "Operation not permitted", path)
        open(path, "x").close()

    def chown(self, path, uid, gid, **kw):
        """record an ownership change"""
        self.calls.append(("chown", path, uid, gid))

    def kmsg(self, m):
        """record a kernel log message"""
        self.calls.append(("kmsg", m))

    def markers(self):
        """return the marker messages written to the kernel log"""
        return [c[1] for c in self.calls if c[0] == "kmsg" and "RHIZO_MARKER" in c[1]]

    @contextlib.contextmanager
    def patched(self):
        """patch the rootfs functions with the fixture's own"""
        saved = {k: getattr(self.rm, k) for k in ("NEWROOT", "mount", "kmsg", "libc")}
        saved_os = {k: getattr(os, k) for k in ("mknod", "chown", "setxattr")}
        self.rm.NEWROOT, self.rm.mount, self.rm.kmsg = self.root, self.mount, self.kmsg
        self.rm.libc = self
        os.mknod, os.chown = self.mknod, self.chown
        os.setxattr = lambda *a, **k: None
        try:
            yield self
        finally:
            for k, v in saved.items():
                setattr(self.rm, k, v)
            for k, v in saved_os.items():
                setattr(os, k, v)


def build_tree(tree, path):
    """write a sys devices tree to disk"""
    os.makedirs(path, exist_ok=True)
    if tree["uevent"]:
        with open(os.path.join(path, "uevent"), "w") as f:
            f.write(tree["uevent"])
    for name, child in tree["children"].items():
        build_tree(child, os.path.join(path, name))


def exec_stage(rm, fail_mount=(), fail_mknod=()):
    """run _stage_coldboot on a fixture root"""
    with tempfile.TemporaryDirectory() as t:
        root, sys_root = os.path.join(t, "root"), os.path.join(t, "sys")
        os.makedirs(os.path.join(root, "dev"))
        build_sysfs(sys_root)
        build_proc(os.path.join(t, "proc"))
        rig = Rig(rm, root, {root + p for p in fail_mount}, {root + p for p in fail_mknod})
        with rig.patched():
            rm._stage_coldboot(sys_root, os.path.join(t, "proc"))
        prop = os.path.join(root + rm.RAMDISK_PROP)
        text = open(prop).read() if os.path.exists(prop) else None
        rig.calls = [c[:1] + tuple(x[len(root):] if isinstance(x, str) and x.startswith(root) else x
                                   for x in c[1:]) for c in rig.calls]
    return rig, text


def exec_shadow(rm, fail_mount=()):
    """run _shadow_sys_devices on a fixture root"""
    with tempfile.TemporaryDirectory() as t:
        root = os.path.join(t, "root")
        build_tree(fixture_sys_devices(), os.path.join(root, "sys", "devices"))
        rig = Rig(rm, root, {root + p for p in fail_mount})
        with rig.patched():
            rm._shadow_sys_devices()
        rig.calls = [c[:1] + tuple(x[len(root):] if isinstance(x, str) and x.startswith(root) else x
                                   for x in c[1:]) for c in rig.calls]
    return rig, mounts_to_ops(rig.calls)


def mounts_to_ops(calls):
    """convert recorded mounts to shadow ops"""
    ops, side = [], None
    for c in calls:
        if c[0] == "mount" and len(c) == 5:
            _, s, t, fs, _fl = c
            if fs is None and t != "/sys/devices" and s == "/sys/devices":
                side = t
            elif fs == "tmpfs" and t == "/sys/devices":
                ops = [("tmpfs", None, "/sys/devices")]
            elif fs is None and side and s and s.startswith(side + "/") and t.startswith("/sys/devices/"):
                ops.append(("bind", s[len(side) + 1:], t))
        elif c[0] == "umount" and c[1] == "/sys/devices":
            ops = []
    return ops


def check_exec_stage(rm):
    """check the output of _stage_coldboot"""
    dups, bad = aosp_dup_names(AOSP)
    rig, prop = exec_stage(rm)
    made = {c[1]: c for c in rig.calls if c[0] == "mknod"}
    owned = {c[1]: c[2:] for c in rig.calls if c[0] == "chown"}
    for rel, (kind, major, minor) in fixture_coldboot_nodes(FIXTURE_UEVENTD, dups).items():
        mode, uid, gid, _ = rm.staged_dev_perms(rel)
        want = (stat.S_IFBLK if kind == "b" else stat.S_IFCHR) | mode
        if rel not in made:
            bad.append("exec: _stage_coldboot made no node at %s" % rel)
        elif made[rel][2:] != (want, os.makedev(major, minor)):
            bad.append("exec: _stage_coldboot made %s mode %o dev %s, its row says %o dev %d:%d"
                       % (rel, made[rel][2], made[rel][3], want, major, minor))
        elif owned.get(rel) != (uid, gid):
            bad.append("exec: _stage_coldboot left %s owned %s, its row says %d:%d"
                       % (rel, owned.get(rel), uid, gid))
    ssr = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(rm.RAMDISK_PROP))))
    mounted = any(c[0] == "mount" and c[2] == ssr and c[3] == "tmpfs" and c[-1] is not False
                  for c in rig.calls)
    if prop is not None and not mounted:
        bad.append("exec: _stage_coldboot wrote the ramdisk prop with no tmpfs mounted at %s" % ssr)
    if prop is None or parse_props(prop).get("ro.cold_boot_done") != "true":
        bad.append("exec: _stage_coldboot wrote no ro.cold_boot_done=true to %s" % rm.RAMDISK_PROP)
    if not any("RHIZO_MARKER coldboot=first-stage" in m for m in rig.markers()):
        bad.append("exec: _stage_coldboot staged the cold boot without RHIZO_MARKER coldboot=first-stage")
    return bad, prop


BLOCK_UEVENTS = (
    "/devices/pci0000:00/0000:00:1f.0/virtio5/block/vdb/uevent",
    "/devices/pci0000:00/0000:00:1f.0/virtio5/block/vdb/vdb1/uevent",
    "/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda/uevent",
    "/devices/pci0000:00/0000:00:0e.0/nvme/nvme0/nvme0n1/uevent",
    "/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host2/target2:0:0/2:0:0:0/block/sdb/uevent",
    "/devices/pci0000:00/0000:00:14.0/usb1/1-1/1-1:1.0/host2/target2:0:0/2:0:0:0/block/sdb/sdb1/uevent",
    "/devices/platform/soc/mmc0/mmc_host/mmc0/mmc0:0001/block/mmcblk0/uevent",
    "/devices/virtual/block/loop7/uevent",
    "/devices/virtual/block/dm-3/uevent",
    "/devices/virtual/block/zram0/uevent",
    "/devices/virtual/block/zram1/uevent",
    "/devices/virtual/block/ublkb0/uevent",
    "/devices/virtual/block/nbd0/uevent",
    "/devices/virtual/block/md0/uevent",
)
BDI_FILES = ("/devices/virtual/bdi/0:52/read_ahead_kb", "/devices/virtual/bdi/0:52/max_ratio")
GENFS_RE = re.compile(r'\(genfscon sysfs "([^"]*)" \(\S+ \S+ (\S+) ')


def genfs_sysfs(*texts):
    """return the sysfs genfscon prefixes and types"""
    return [(m.group(1), m.group(2)) for t in texts for m in GENFS_RE.finditer(t)]


def sysfs_label(genfs, path):
    """return the genfscon type of a sysfs path"""
    best = max((p for p, _ in genfs if path.startswith(p)), key=len, default=None)
    return None if best is None else [t for p, t in genfs if p == best][-1]


class QueryFailed(Exception):
    """exception for a failed policy query"""


def vold_uevent_findings(rel, genfs, held):
    """return the vold uevent policy findings"""
    try:
        return _vold_uevent_findings(rel, genfs, held)
    except QueryFailed as e:
        return ["policy: %s: a query did not run: %s" % (rel, e)]


def _vold_uevent_findings(rel, genfs, held):
    """check that vold can read block uevents under the policy"""
    bad = []
    labels = {}
    for path in BLOCK_UEVENTS:
        labels.setdefault(sysfs_label(genfs, path), []).append(path)
    if None in labels:
        return ["policy: %s: no genfscon labels %s" % (rel, labels[None][0])]
    rule = "neverallow vold { %s }:file { write append };" % " ".join(sorted(labels))
    ok, out = held(rule)
    if not ok:
        bad.append("policy: %s: vold may write a block device's uevent (%s)" % (rel, out.strip().splitlines()[0] if out.strip() else rule))
    for path in BDI_FILES:
        t = sysfs_label(genfs, path)
        if t in labels:
            bad.append("policy: %s: %s carries %s, a block uevent's type" % (rel, path, t))
        elif held("neverallow vold %s:file write;" % t)[0]:
            bad.append("policy: %s: vold may not write %s (%s)" % (rel, path, t))
    return bad


def policy_lab(args, img):
    """run the policy lab with arguments against an image"""
    return subprocess.run([os.path.join(HERE, "..", "..", "lib", "policy-lab.sh")] + args, capture_output=True, text=True,
                          env=dict(os.environ, RHIZO_GSI_IMG=img), timeout=600)


def check_vold_policy(rel, img):
    """check the vold uevent rules in a policy"""
    r = policy_lab(["compile"], img)
    compiled = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    if not compiled.endswith("precompiled_sepolicy"):
        return ["policy: %s: policy-lab could not compile (rc %d): %s" % (rel, r.returncode,
                                                                     (r.stderr or r.stdout).strip()[-300:])]
    scratch = os.path.dirname(compiled)
    st = os.stat(img)
    cils = os.path.join(VAR_DIR, "share", "policy-lab", "cils-%s-%d-%d" % (
        os.path.basename(img)[:-len(".img")], st.st_size, int(st.st_mtime)))
    try:
        texts = [open(os.path.join(cils, "plat_sepolicy.cil")).read(),
                 open(os.path.join(scratch, "rhizo_vendor_sepolicy.cil")).read()]
    except OSError as e:
        return ["policy: %s: cannot read the compiled CILs: %s" % (rel, e)]

    def held(rule):
        """return whether a neverallow rule holds, with the query output"""
        q = policy_lab(["query", "neverallow", "-n", rule, "--policy", compiled], img)
        out = q.stdout + q.stderr
        if "neverallow violated" in out:
            return False, out
        if q.returncode == 0:
            return True, out
        raise QueryFailed("%s -> rc %d: %s" % (rule, q.returncode, out.strip()[-200:]))
    try:
        return vold_uevent_findings(rel, genfs_sysfs(*texts), held)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


MUTATIONS = (
    ("no-prop-write", "            f.write(RAMDISK_PROP_TEXT)\n", "            pass\n",
     "wrote no ro.cold_boot_done=true"),
    ("no-node-staging", "        plan = plan_coldboot_nodes(sys_root, proc_root)\n", "        plan = []\n",
     "made no node at /dev/fuse"),
    ("shadow-disabled", "    os.makedirs(side, exist_ok=True)\n", "    return False\n",
     "left the plain /sys/devices view"),
    ("vold-nothing-bound", '    targets = plan_block_uevents(f"{NEWROOT}/sys")\n', "    targets = []\n",
     "cold boot of /sys/block writes 4 host uevent(s)"),
    ("vold-sink-writable", "        if not why and not mount(None, sink_dir, None,\n",
     "        if False and not mount(None, sink_dir, None,\n",
     "cold boot of /sys/block writes 4 host uevent(s)"),
    ("vold-top-links-unfollowed", "(lvl > 0 and not e.is_dir(follow_symlinks=False))",
     "(not e.is_dir(follow_symlinks=False))", "cold boot of /sys/block writes 4 host uevent(s)"),
    ("walk-stats-attributes", "(lvl > 0 and not e.is_dir(follow_symlinks=False))",
     "(lvl > 0 and (os.path.islink(e.path) or not os.path.isdir(e.path)))",
     "the /sys/block walk stats 4 attribute file(s)"),
    ("ssr-dir-uncreated", "        os.makedirs(ssr, exist_ok=True)\n", "        pass\n",
     "wrote no ro.cold_boot_done=true"),
    ("ssr-never-mounted", 'if not mount("tmpfs", ssr, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755"):',
     "if False:", "no tmpfs mounted at /second_stage_resources"),
    ("ssr-mount-unchecked", 'if not mount("tmpfs", ssr, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755"):',
     'if not mount("tmpfs", ssr, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755") and False:',
     "fault stage/ssr-mount: _stage_coldboot still wrote the ramdisk prop"),
    ("shadow-marker-dropped", 'kmsg(f"RHIZO_MARKER coldboot_shadow=failed reason={why}"',
     'kmsg(f"sys/devices shadow failed reason={why}"', "no RHIZO_MARKER coldboot_shadow=failed reason=tmpfs"),
    ("vold-marker-dropped", 'kmsg(f"RHIZO_MARKER coldboot_vold=failed reason={why} bound={bound}/{len(targets)}"',
     'kmsg(f"vold shadow failed reason={why} bound={bound}/{len(targets)}"',
     "no RHIZO_MARKER coldboot_vold=failed reason=sink-tmpfs"),
    ("late-add-unread", '        if ev and ev.get("SUBSYSTEM") == "block" and ev.get("ACTION") in ("add", "move"):\n',
     '        if False:\n', "vold-late: its cold boot of /sys/block writes 2 host uevent(s)"),
    ("late-add-walks-all", 'sink_late_block_uevents(root, log, ev.get("DEVPATH"))',
     "sink_late_block_uevents(root, log)", "an add walked 4 uevent(s) of devices it does not name"),
    ("late-rebinds-sunk", "        if (ts.st_dev, ts.st_ino) == (st.st_dev, st.st_ino):\n            continue\n", "",
     "one each is the whole job"),
    ("late-sink-detached", "    if why and mounted:\n", "    if mounted:\n",
     "vold-late: its cold boot of /sys/block writes 2 host uevent(s)"),
    ("ashmem-dup-missed", '    for name in COLDBOOT_BOOT_ID_DUPS:\n', '    for name in ():\n',
     "made no node at /dev/ashmem0f1e2d3c"),
    ("vold-partition-missed", "                walk(e.path, lvl + 1)\n", "                out.append(os.path.realpath(os.path.join(e.path, 'uevent')))\n",
     "block/sda/sda1/uevent"),
)


def mutant(old, new):
    """rebuild rootfs from edited source"""
    src = open(rootfs.__file__).read()
    if src.count(old) != 1:
        return None
    mod = types.ModuleType("rhizo_mounts_mutant")
    mod.__file__ = rootfs.__file__
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(src.replace(old, new), rootfs.__file__, "exec"), mod.__dict__)
    return mod


def run_exec(rm):
    """run the exec checks"""
    staged, prop = check_exec_stage(rm)
    return staged + check_exec_shadow(rm, prop) + exec_vold(rm)[1] + exec_vold_late(rm)[1] + check_faults(rm) \
        + check_walk_stats(rm)


FAULTS = (
    ("stage/mknod", "stage", {"fail_mknod": ("/dev/fuse",)}, "coldboot=failed", "reason=nodes"),
    ("stage/ssr-mount", "stage", {"fail_mount": ("/second_stage_resources",)},
     "coldboot=failed", "reason=ssr-tmpfs"),
    ("shadow/tmpfs", "shadow", {"fail_mount": ("/sys/devices",)}, "coldboot_shadow=failed",
     "reason=tmpfs"),
    ("shadow/side", "shadow", {"fail_mount": ("/real_sys_devices",)}, "coldboot_shadow=failed",
     "reason=side-bind"),
    ("vold/sink", "vold", {"fail_mount": ("/dev/.rhizo_uevent_sink",)}, "coldboot_vold=failed",
     "reason=sink-tmpfs"),
)
OK_MARKERS = ("coldboot=first-stage", "coldboot_shadow=ok", "coldboot_vold=ok")


def check_faults(rm):
    """check the markers of each fault"""
    bad = []
    for label, which, fault, marker, reason in FAULTS:
        if which == "stage":
            rig, prop = exec_stage(rm, **fault)
            if prop is not None:
                bad.append("fault %s: _stage_coldboot still wrote the ramdisk prop" % label)
        elif which == "shadow":
            rig, _ = exec_shadow(rm, **fault)
        else:
            rig, _ = exec_vold(rm, **fault)
        got = rig.markers()
        if not any("RHIZO_MARKER %s %s" % (marker, reason) in m for m in got):
            bad.append("fault %s: no RHIZO_MARKER %s %s (markers: %s)" % (label, marker, reason, got or "none"))
        if any(ok in m for m in got for ok in OK_MARKERS):
            bad.append("fault %s: a success marker still printed: %s" % (label, got))
    for which, marker in (("stage", OK_MARKERS[0]), ("shadow", OK_MARKERS[1]), ("vold", OK_MARKERS[2])):
        rig = {"stage": exec_stage, "shadow": exec_shadow, "vold": exec_vold}[which](rm)[0]
        if not any("RHIZO_MARKER " + marker in m for m in rig.markers()):
            bad.append("marker: a clean %s prints no RHIZO_MARKER %s" % (which, marker))
    return bad


def check_exec_shadow(rm, prop):
    """check the mount operations of _shadow_sys_devices"""
    rig, ops = exec_shadow(rm)
    if not ops:
        return ["exec: _shadow_sys_devices left the plain /sys/devices view"]
    return check_replay(ops, prop or "")



def debugfs_cat(img, path):
    """read a file from an image"""
    try:
        r = subprocess.run(["debugfs", "-R", "cat " + path, img], capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if "File not found" in r.stderr.decode(errors="replace") or r.returncode:
        return None, r.stderr.decode(errors="replace").strip()[-160:] or "rc %d" % r.returncode
    return r.stdout, None


GSI_FILE_CONTEXTS = ("/system/etc/selinux/plat_file_contexts",
                     "/system/system_ext/etc/selinux/system_ext_file_contexts",
                     "/system/product/etc/selinux/product_file_contexts")


def gsi_file_contexts(read, vendor_text):
    """join the GSI file_contexts files"""
    parts, bad = [], []
    for path in GSI_FILE_CONTEXTS:
        data, why = read(path)
        if data is None:
            bad.append("cannot read %s (%s)" % (path, why))
        else:
            parts.append(data.decode(errors="replace"))
    return (None if bad else "\n".join(parts + [vendor_text])), bad


RELEASE_MAP = os.path.join(REPO, "test", "vm", "image", "release-map.sh")
NOT_CHECKED = {"a16-arm64": "the arm64 host's GSI; abi.sh a16-arm64 checks it"}


def releases(map_text):
    """list the GSI releases and image paths"""
    m = re.search(r"declare -A GSI_IMG=\((.*?)\n\)", map_text, re.S)
    imgs = dict(re.findall(r'\[([\w-]+)\]="([^"]+)"', m.group(1))) if m else {}
    if not imgs:
        return [], ["releases: release-map.sh declares no GSI_IMG"]
    bad = ["releases: NOT_CHECKED names %s, which release-map.sh no longer declares" % r
           for r in sorted(set(NOT_CHECKED) - set(imgs))]
    out = []
    for rel, img in sorted(imgs.items()):
        if rel in NOT_CHECKED:
            continue
        if rel == "a16":
            out.append((rel, os.environ.get("RHIZO_COLDBOOT_CHECK_GSI", os.path.join(VAR_DIR, "gsi", "system.img"))))
        else:
            out.append((rel, os.path.join(VAR_DIR, "share", img)))
    return out, bad


def run(aosp=AOSP):
    """run every check against the AOSP tree and return the problems"""
    bad = check_premise(aosp)
    bad += run_exec(rootfs)
    bad += check_call_sites(*call_site_sources())
    relabel = relabel_dest_types(open(POLICY).read())
    checked = []
    if shutil.which("debugfs") is None:
        bad.append("parity: debugfs is not installed")
    else:
        rels, why_rel = releases(open(RELEASE_MAP).read())
        bad += why_rel
        for rel, img in rels:
            if not os.path.exists(img):
                bad.append("parity: no %s GSI image at %s"
                           % (rel, img))
                continue
            files = {}
            for key, path in (("ueventd", "/system/etc/ueventd.rc"),
                              ("init", "/system/bin/init"),
                              ("vold", "/system/bin/vold")):
                files[key], why = debugfs_cat(img, path)
                if not files[key]:
                    files[key] = None
                    bad.append("parity: %s: cannot read %s (%s)" % (rel, path, why or "empty"))
            fc, why_fc = gsi_file_contexts(lambda path: debugfs_cat(img, path), open(VENDOR_FC).read())
            bad += ["parity: %s: %s" % (rel, w) for w in why_fc]
            if None in files.values() or fc is None:
                continue
            bad += check_gsi_init(rel, files["init"], files["vold"])
            ueventd = files["ueventd"].decode(errors="replace")
            bad += check_parity(rel, ueventd, fc,
                                rootfs.STAGED_DEV_PERMS, rootfs.DMA_HEAP_DIR, relabel,
                                launcher_labels())
            bad += run_node_set(rel, ueventd, fc, aosp)
            checked.append(rel)
            bad += check_vold_policy(rel, img)
    bad += check_first_start_labels(rootfs.STAGED_DEV_PERMS, rootfs.INIT_RESTORECON,
                                    rootfs.coldboot_primer_spec())
    for b in bad:
        say(b)
    if bad:
        return 1
    print("check-coldboot-host-uevents: ok -- neither ueventd's replays nor vold's cold boot, at the start or after a disk plugged later, writes "
          "a host uevent, vold's policy refuses every block uevent write, %d staged "
          "node rows match ueventd.rc and plat_file_contexts, and every node either names "
          "is staged or withheld by NODE_FATES, in %s"
          % (len(rootfs.STAGED_DEV_PERMS), ", ".join(checked)))
    return 0


FIXTURE_UEVENTD = """\
subsystem drm
    devname uevent_devpath
    dirname /dev/dri

subsystem input
    devname uevent_devpath
    dirname /dev/input

subsystem dma_heap
   devname uevent_devpath
   dirname /dev/dma_heap

/dev/null                 0666   root       root
/dev/zero                 0666   root       root
/dev/full                 0666   root       root
/dev/tty                  0666   root       root
/dev/random               0666   root       root
/dev/urandom              0666   root       root
/dev/hw_random            0400   prng_seeder prng_seeder
/dev/ashmem*              0666   root       root
/dev/dma_heap/system      0444   system     system
/dev/dma_heap/system-uncached      0444   system     system
/dev/dri/*                0666   root       graphics
/dev/uinput               0660   uhid       uhid
/dev/tun                  0660   system     vpn
/dev/block/dm-*           0640   root       system
/sys/devices/system/cpu/cpu*   cpufreq/scaling_max_freq   0664  system system
"""
FIXTURE_FC = """\
/dev(/.*)?		u:object_r:device:s0
/dev/ashmem		u:object_r:ashmem_device:s0
/dev/ashmem(.*)?		u:object_r:ashmem_libcutils_device:s0
/dev/block(/.*)?		u:object_r:block_device:s0
/dev/block/loop[0-9]*	u:object_r:loop_device:s0
/dev/console		u:object_r:console_device:s0
/dev/dma_heap(/.*)?	u:object_r:dmabuf_heap_device:s0
/dev/dma_heap/system	u:object_r:dmabuf_system_heap_device:s0
/dev/dma_heap/system-uncached	u:object_r:dmabuf_system_heap_device:s0
/dev/device-mapper	u:object_r:dm_device:s0
/dev/fuse		u:object_r:fuse_device:s0
/dev/hw_random		u:object_r:hw_random_device:s0
/dev/kmsg		u:object_r:kmsg_device:s0
/dev/loop-control	u:object_r:loop_control_device:s0
/dev/null		u:object_r:null_device:s0
/dev/random		u:object_r:random_device:s0
/dev/tty		u:object_r:owntty_device:s0
/dev/tun		u:object_r:tun_device:s0
/dev/uinput		u:object_r:uhid_device:s0
/dev/urandom		u:object_r:random_device:s0
/dev/zero		u:object_r:zero_device:s0
"""
FIXTURE_AOSP = {
    "ueventd.cpp": """
    uevent_listener.RegenerateUevents([&](const Uevent& uevent) -> ListenerAction {
        bool uuid_check_done = device_handler->CheckUeventForBootPartUuid(uevent);
        return uuid_check_done ? ListenerAction::kStop : ListenerAction::kContinue;
    });
    if (!android::base::GetBoolProperty(kColdBootDoneProp, false)) {
        ColdBoot cold_boot(uevent_listener, uevent_handlers,
                           ueventd_configuration.enable_parallel_restorecon);
        cold_boot.Run();
    }
""",
    "devices.cpp": """
bool DeviceHandler::CheckUeventForBootPartUuid(const Uevent& uevent) {
    // If we aren't using boot_part_uuid then we're done.
    if (boot_part_uuid_.empty()) {
        return true;
    }
""",
    "uevent_listener.cpp": r"""
    int fd = openat(dfd, "uevent", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        write(fd, "add\n", 4);
        close(fd);
        while ((result = ReadUevent(&uevent)) != ReadUeventResult::kFailed) {
            if (callback(uevent) == ListenerAction::kStop) return ListenerAction::kStop;
        }
    }
    dirent* de;
    while ((de = readdir(d)) != nullptr) {
static const char* kRegenerationPaths[] = {"/sys/devices"};
""",
    "util.h": 'static const char kColdBootDoneProp[] = "ro.cold_boot_done";\n',
    "property_service.cpp": """
    static constexpr const char* const kVendorPathPrefixes[4] = {
            "/vendor",
            "/odm",
            "/vendor_dlkm",
            "/odm_dlkm",
    };
    LoadPropertiesFromSecondStageRes(&properties);
""",
    "second_stage_resources.h": """
constexpr const char kSecondStageRes[] = "/second_stage_resources";
constexpr const char kBootImageRamdiskProp[] = "/system/etc/ramdisk/build.prop";
""",
    "selinux.cpp": """
void SelinuxRestoreContext() {
    selinux_android_restorecon("/dev/console", 0);
    selinux_android_restorecon("/dev/kmsg", 0);
    selinux_android_restorecon("/dev/null", 0);
    selinux_android_restorecon("/dev/random", 0);
    selinux_android_restorecon("/dev/urandom", 0);
    selinux_android_restorecon("/dev/block", SELINUX_ANDROID_RESTORECON_RECURSE);
    selinux_android_restorecon("/dev/device-mapper", 0);
}
""",
}


FIXTURE_VOLD = r"""
    coldboot("/sys/block");
static void do_coldboot(DIR* d, int lvl) {
    struct dirent* de;
    int dfd, fd;

    dfd = dirfd(d);

    fd = openat(dfd, "uevent", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        write(fd, "add\n", 4);
        close(fd);
    }

    while ((de = readdir(d))) {
        DIR* d2;

        if (de->d_name[0] == '.') continue;

        if (de->d_type != DT_DIR && lvl > 0) continue;

        fd = openat(dfd, de->d_name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
"""


def write_aosp(root, overrides=None):
    """write the fixture AOSP init and vold sources under a root"""
    d = os.path.join(root, "system", "core", "init")
    os.makedirs(d, exist_ok=True)
    for name, text in FIXTURE_AOSP.items():
        open(os.path.join(d, name), "w").write((overrides or {}).get(name, text))
    os.makedirs(os.path.join(root, "system", "vold"), exist_ok=True)
    open(os.path.join(root, "system", "vold", "main.cpp"), "w").write(
        (overrides or {}).get("vold", FIXTURE_VOLD))


def selftest():
    """run the checks against fixture inputs"""
    fails = []

    def expect(label, findings, needle):
        """check findings against a needle"""
        if needle is None:
            if findings:
                fails.append("%s: flagged a correct input: %s" % (label, findings[0]))
        elif not any(needle in f for f in findings):
            fails.append("%s: did not flag %r (got %s)" % (label, needle, findings or "nothing"))

    perms = rootfs.STAGED_DEV_PERMS
    heap = rootfs.DMA_HEAP_DIR
    relabel = relabel_dest_types(open(POLICY).read())
    children = ["breakpoint", "pci0000:00", "platform", "virtual"]
    shadow = rootfs.plan_sys_devices_shadow(children)
    prop = rootfs.RAMDISK_PROP_TEXT

    expect("replay/fix", check_replay(shadow, prop), None)
    expect("replay/no-prop", check_replay(shadow, "# nothing\n"),
           "ColdBoot::Run writes 13 host uevent(s)")
    expect("replay/prop-false", check_replay(shadow, "ro.cold_boot_done=false\n"),
           "ColdBoot::Run writes")
    expect("replay/no-shadow", check_replay([], prop),
           "boot-partition replay writes 1 host uevent(s): /sys/devices/breakpoint/uevent")
    host_decoy = [op if op[2] != "/sys/devices/uevent" else ("bind", "virtual/block/loop0/uevent", op[2])
                  for op in shadow]
    expect("replay/host-decoy", check_replay(host_decoy, prop),
           "boot-partition replay writes 1 host uevent(s): /sys/devices/uevent")
    expect("replay/no-decoy", check_replay([op for op in shadow if op[2] != "/sys/devices/uevent"], prop),
           "boot-partition replay writes 1 host uevent(s)")
    expect("replay/pre-fix", check_replay([], "# nothing\n"), "ColdBoot::Run writes 13 host uevent(s)")

    with tempfile.TemporaryDirectory() as t:
        write_aosp(t)
        expect("premise/good", check_premise(t), None)
    for name, old, new, needle in (
            ("ueventd.cpp", "if (!android::base::GetBoolProperty(kColdBootDoneProp, false)) {",
             "if (true) {", "ColdBoot::Run is no longer gated"),
            ("devices.cpp", "return true;", "return false;", "first event without a boot_part_uuid"),
            ("uevent_listener.cpp", "dirent* de;\n    while ((de = readdir(d)) != nullptr) {", "",
             "writes a directory's own uevent"),
            ("uevent_listener.cpp", '{"/sys/devices"}', '{"/sys/class", "/sys/devices"}',
             "replay root is no longer /sys/devices"),
            ("property_service.cpp", '"/odm_dlkm",', '"/odm_dlkm", "/second_stage_resources",',
             "would load as vendor_init"),
            ("second_stage_resources.h", "/system/etc/ramdisk/build.prop", "/etc/ramdisk.prop",
             "no longer puts the ramdisk prop"),
            ("selinux.cpp", 'selinux_android_restorecon("/dev/block", SELINUX_ANDROID_RESTORECON_RECURSE);',
             "", "no longer relabels /dev/block/loop[0-9]*"),
            ("vold", 'coldboot("/sys/block");', 'coldboot("/sys/class/block");',
             "no longer cold-boots /sys/block alone"),
            ("vold", "if (de->d_type != DT_DIR && lvl > 0) continue;", "",
             "following links only at the top")):
        with tempfile.TemporaryDirectory() as t:
            text = FIXTURE_VOLD if name == "vold" else FIXTURE_AOSP[name]
            write_aosp(t, {name: text.replace(old, new)})
            expect("premise/%s" % needle, check_premise(t), needle)
    expect("gsi-init/good", check_gsi_init("a16", b"\0".join(GSI_INIT_STRINGS)), None)
    expect("gsi-init/vold", check_gsi_init("a16", b"\0".join(GSI_INIT_STRINGS), b"/sys/class"),
           "vold has no '/sys/block'")
    expect("gsi-init/no-uuid-pass", check_gsi_init("a16", b"ro.cold_boot_done /second_stage_resources"),
           "found via partition UUID")

    owned = launcher_labels()
    expect("parity/good", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, perms, heap, relabel, owned), None)
    expect("parity/dri-unowned", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, perms, heap, relabel),
           "/dev/dri/card0 is labeled u:object_r:gpu_device:s0, plat_file_contexts says u:object_r:device:s0")
    bad_perms = dict(perms)
    bad_perms["/dev/console"] = (0o666,) + perms["/dev/console"][1:]
    expect("parity/console-0666", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, bad_perms, heap, relabel, owned),
           "/dev/console is staged 666 0:0, ueventd.rc says 600 root:root")
    bad_perms = dict(perms)
    bad_perms["/dev/uinput"] = (0o660, 1000, 1000, perms["/dev/uinput"][3])
    expect("parity/uinput-system", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, bad_perms, heap, relabel, owned),
           "/dev/uinput is staged 660 1000:1000, ueventd.rc says 660 uhid:uhid")
    bad_perms = dict(perms)
    bad_perms["/dev/fuse"] = perms["/dev/fuse"][:3] + ("u:object_r:device:s0",)
    expect("parity/fuse-label", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, bad_perms, heap, relabel, owned),
           "/dev/fuse is labeled u:object_r:device:s0, plat_file_contexts says u:object_r:fuse_device:s0")
    expect("parity/no-relabel", check_parity("fx", FIXTURE_UEVENTD, FIXTURE_FC, perms, heap,
                                             relabel - {"loop_device"}, owned),
           "loop_device is not in rhizo_relabel_dest_dev")
    expect("parity/unknown-aid", check_parity("fx", FIXTURE_UEVENTD.replace("prng_seeder prng_seeder",
                                                                            "nobody nobody"),
                                              FIXTURE_FC, perms, heap, relabel, owned),
           "no AID this checker knows")
    expect("parity/exact-wins", [] if best_label(parse_file_contexts(FIXTURE_FC), "/dev/ashmem", "c")
           == "u:object_r:ashmem_device:s0" else ["exact"], None)
    expect("parity/prefix-rule", [] if ueventd_rule(parse_ueventd_rc(FIXTURE_UEVENTD), "/dev/dri/card0")
           == (0o666, "root", "graphics") else ["prefix"], None)

    spec = rootfs.coldboot_primer_spec()
    expect("labels/good", check_first_start_labels(perms, rootfs.INIT_RESTORECON, spec), None)
    expect("labels/fuse-unlabeled",
           check_first_start_labels(perms, rootfs.INIT_RESTORECON,
                                    [s for s in spec if s[0] != "/dev/fuse"]),
           "/dev/fuse is labeled by neither")

    devices = open(os.path.join(AOSP, "system", "core", "init", "devices.cpp")).read()
    ashmem = open(os.path.join(AOSP, "system", "core", "libcutils", "ashmem-dev.cpp")).read()
    dups, _ = dup_names_of(devices, ashmem)
    plan, row = rootfs.plan_coldboot_nodes, rootfs.staged_dev_perms
    caps = {n for nodes in rootfs.DEVICE_NODE_CAPABILITIES.values() for n in nodes}
    sources = launcher_sources({d[0] for _rx, f, d in NODE_FATES if f == "launcher"})

    def nodes(plan_fn=plan, perms_fn=row, rc=FIXTURE_UEVENTD, fc=FIXTURE_FC, dup=None,
              dev_nodes=rootfs.DEV_NODES, cap_nodes=caps, src=sources):
        """run the node set check with fixture defaults"""
        return check_node_set("fx", rc, fc, plan_fn, perms_fn, dups if dup is None else dup,
                              dev_nodes, cap_nodes, src)
    expect("nodes/good", nodes(), None)
    for rm_name, old, new_ in (
            ("heap-dropped", 'COLDBOOT_DMA_HEAPS = ("system", "system-uncached")', 'COLDBOOT_DMA_HEAPS = ("system",)'),
            ("fuse-dropped", 'COLDBOOT_MISC = ("loop-control", "device-mapper", "fuse", "hw_random")',
             'COLDBOOT_MISC = ("loop-control", "device-mapper", "hw_random")')):
        mod = mutant(old, new_)
        if mod is None:
            fails.append("nodes/%s: the mutation no longer applies to sandbox/rootfs.py" % rm_name)
            continue
        expect("nodes/%s" % rm_name, nodes(plan_fn=mod.plan_coldboot_nodes),
               "made %s, which Android opens" % ("/dev/dma_heap/system-uncached" if rm_name == "heap-dropped"
                                                 else "/dev/fuse"))
    expect("nodes/heap-dropped-real-fc", run_node_set("fx", FIXTURE_UEVENTD, FIXTURE_FC, AOSP, mutant(
        'COLDBOOT_DMA_HEAPS = ("system", "system-uncached")', 'COLDBOOT_DMA_HEAPS = ("system",)')),
        "made /dev/dma_heap/system-uncached, which Android opens")
    with_sda = lambda root, proc: plan(root, proc) + [("/dev/block/sda", "b", 240, 0)]
    expect("nodes/extra", nodes(plan_fn=with_sda), "/dev/block/sda is staged from the cold boot's set")

    def no_row(rel):
        """return a permissions row, failing for the hw_random node"""
        if rel == "/dev/hw_random":
            raise KeyError(rel)
        return row(rel)
    expect("nodes/no-row", nodes(perms_fn=no_row), "/dev/hw_random is staged with no STAGED_DEV_PERMS row")
    no_dup = lambda root, proc: [p for p in plan(root, proc) if not p[0].startswith("/dev/ashmem")]
    expect("nodes/no-dup", nodes(plan_fn=no_dup),
           "made /dev/ashmem%s, which Android opens" % FIXTURE_BOOT_ID)
    wrong = lambda root, proc: [(r, k, ma, 1 if r.startswith("/dev/ashmem") else mi) for r, k, ma, mi in plan(root, proc)]
    expect("nodes/wrong-number", nodes(plan_fn=wrong), "/dev/ashmem%s is staged as ('c', 240, 1)" % FIXTURE_BOOT_ID)
    expect("nodes/dup-unmodeled", nodes(dup=set()), "/dev/ashmem%s is staged from the cold boot's set" % FIXTURE_BOOT_ID)
    expect("nodes/premise", dup_names_of(devices.replace("+= boot_id", "+= suffix"), ashmem)[1],
           "no longer duplicates")
    expect("nodes/unclassified", nodes(rc=FIXTURE_UEVENTD + "/dev/newthing 0666 root root\n"),
           "ueventd.rc names /dev/newthing, which ueventd makes for no host device")
    expect("nodes/no-heap-subsystem", nodes(rc=FIXTURE_UEVENTD.replace("subsystem dma_heap", "subsystem dma_heaps")),
           "ueventd.rc names /dev/dma_heap/system,")
    expect("nodes/labeled-unfated", nodes(fc=FIXTURE_FC + "/dev/rfkill\t\tu:object_r:rfkill_device:s0\n"),
           "/dev/rfkill is labeled u:object_r:rfkill_device:s0 by file_contexts")
    expect("nodes/no-dev-node", nodes(dev_nodes=tuple(n for n in rootfs.DEV_NODES if n != "kmsg")),
           "/dev/kmsg is a DEV_NODES alias by its fate, and DEV_NODES has no kmsg")
    expect("nodes/no-capability", nodes(cap_nodes=caps - {"tun"}),
           "/dev/tun is a capability's node by its fate")
    expect("nodes/launcher-gone", nodes(src=dict(sources, _mount_extra_partitions="")),
           "/dev/ptmx is made by _mount_extra_partitions by its fate")

    rmap = open(RELEASE_MAP).read()
    rels, why = releases(rmap)
    expect("releases/good", why, None)
    if sorted(r for r, _ in rels) != sorted(set(re.findall(r'\[([\w-]+)\]="[^"]+\.img"', rmap)) - set(NOT_CHECKED)):
        fails.append("releases/all: releases() read %s from release-map.sh" % [r for r, _ in rels])
    extra = rmap.replace('[a15]="gsi_a15.img"', '[a15]="gsi_a15.img"\n  [a18]="gsi_a18.img"')
    if "a18" not in [r for r, _ in releases(extra)[0]]:
        fails.append("releases/new: a release added to release-map.sh is not checked")
    expect("releases/unused-exemption", releases(rmap.replace("[a16-arm64]", "[a16-riscv]"))[1],
           "NOT_CHECKED names a16-arm64")

    fcs = {GSI_FILE_CONTEXTS[0]: b"/dev/x u:object_r:plat_x:s0\n", GSI_FILE_CONTEXTS[1]: b"",
           GSI_FILE_CONTEXTS[2]: b"/dev/x u:object_r:product_x:s0\n"}
    text, why = gsi_file_contexts(lambda path: (fcs[path], None), "/dev/y u:object_r:vendor_y:s0\n")
    specs = parse_file_contexts(text or "")
    expect("fc/good", why, None)
    if best_label(specs, "/dev/x", "c") != "u:object_r:product_x:s0" or best_label(specs, "/dev/y", "c") != \
            "u:object_r:vendor_y:s0":
        fails.append("fc/order: product's line did not win over plat's, or the vendor's was not read: %s" % specs)
    expect("fc/missing", gsi_file_contexts(lambda path: (None, "File not found") if "product" in path
                                           else (fcs[path], None), "")[1], "cannot read /system/product")
    expect("nodes/withheld-staged", nodes(dev_nodes=rootfs.DEV_NODES + ("kvm",)),
           "/dev/kvm is withheld by its fate, and the launcher stages it anyway (DEV_NODES)")

    expect("exec/good", run_exec(rootfs), None)
    for name, old, new, needle in MUTATIONS:
        mod = mutant(old, new)
        if mod is None:
            fails.append("exec/%s: the mutation no longer applies to sandbox/rootfs.py" % name)
            continue
        expect("exec/%s" % name, run_exec(mod), needle)

    make, shadows, launcher = call_site_sources()
    expect("calls/good", check_call_sites(make, shadows, launcher), None)
    expect("calls/no-stage", check_call_sites(make.replace("_stage_coldboot()", ""), shadows, launcher),
           "no longer calls _stage_coldboot()")
    expect("calls/shadow-moved", check_call_sites(
        make, shadows.replace("_shadow_sys_devices()", "pass").replace(
            'mount("sysfs",f"{NEWROOT}/sys","sysfs",0)\n',
            'mount("sysfs",f"{NEWROOT}/sys","sysfs",0)\n    other()\n    _shadow_sys_devices()\n'),
        launcher), "does not follow the sandbox's sysfs mount")
    expect("calls/no-vold-shadow", check_call_sites(
        make, shadows.replace("_shadow_block_uevents()", "pass"), launcher),
        "_shadow_block_uevents() does not follow _shadow_sys_devices()")
    expect("calls/no-primer-read", check_call_sites(make, shadows, launcher.replace(
        '"@RHIZO_COLDBOOT_RELABEL@".split', '"".split')), "no longer adds @RHIZO_COLDBOOT_RELABEL@")
    expect("calls/no-primer-write", check_call_sites(make, shadows, re.sub(
        PRIMER_WRITE_RE, "", launcher)), "no longer writes coldboot_primer_spec()")
    fence_src = inspect.getsource(rootfs.start_input_fence)
    expect("calls/fence-sweep", check_fence_sweep(fence_src), None)
    expect("calls/no-fence-sweep", check_fence_sweep(fence_src.replace(START_SWEEP, "pass")),
           "no longer calls")
    expect("calls/fence-sweep-early", check_fence_sweep(
        START_SWEEP + "\n" + fence_src.replace(START_SWEEP, "pass")), "before its uevent socket is bound")
    expect("calls/primer-comma-label", check_primer_substitution(
        launcher, rootfs.coldboot_primer_spec() + [("/dev/x", "u:object_r:a,b:s0")]),
        "the primer reads back")

    genfs = [("/", "sysfs"), ("/devices/virtual/block/", "sysfs_devices_block"),
             ("/devices/virtual/block/loop", "sysfs_loop"), ("/devices/virtual/bdi", "rhizo_sysfs_bdi")]
    asked = []

    def held_good(rule):
        """record the asked rule and hold every rule except the bdi one"""
        asked.append(rule)
        return "rhizo_sysfs_bdi" not in rule, ""
    expect("policy/good", vold_uevent_findings("fx", genfs, held_good), None)
    if not any("sysfs_devices_block" in r and "sysfs_loop" in r and " sysfs " in r for r in asked):
        fails.append("policy/good: the uevent question did not name every block uevent type: %s" % asked)
    expect("policy/uevent-writable", vold_uevent_findings("fx", genfs, lambda r: (False, "violated")),
           "vold may write a block device's uevent")
    expect("policy/bdi-unlabeled", vold_uevent_findings("fx", genfs[:3], held_good),
           "/devices/virtual/bdi/0:52/read_ahead_kb carries sysfs, a block uevent's type")
    expect("policy/bdi-unwritable", vold_uevent_findings("fx", genfs, lambda r: (True, "")),
           "vold may not write /devices/virtual/bdi/0:52/read_ahead_kb")
    expect("policy/unlabeled", vold_uevent_findings("fx", genfs[1:], held_good), "no genfscon labels")

    def held_broken(rule):
        """fail the query"""
        raise QueryFailed("rc 2: sepolicy-analyze: no such file")
    expect("policy/query-failed", vold_uevent_findings("fx", genfs, held_broken), "a query did not run")
    if sysfs_label(genfs, "/devices/virtual/block/loop7/uevent") != "sysfs_loop":
        fails.append("policy: the longest genfscon prefix does not win")

    for f in fails:
        say("selftest: " + f)
    if fails:
        return 1
    print("check-coldboot-host-uevents: selftest ok")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    return run()


if __name__ == "__main__":
    sys.exit(main())
