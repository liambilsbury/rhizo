#!/usr/bin/env python3
import ast, contextlib, glob, io, os, re, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-device-state-restorecon")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import core
LINK = "/vendor/etc/rhizo-device-state"
OLD_TARGET_TYPES = ("rhizo_device_state_file", "vendor_configs_file")
STOCK_RECURSIVE = ("/mnt", "/cache", "/metadata", "/metadata/apex", "/data", "/sys/kernel/debug",
                   "/sys/kernel/tracing/instances/bootreceiver", "/data/system/shutdown-checkpoints")
RECURSIVE = re.compile(r"^\s*restorecon(?:_recursive|\s+--recursive)(?:\s+--[\w-]+)*\s+(/\S+)", re.M)


def read(name):
    """return a launcher source's text"""
    return open(os.path.join(LAUNCHER, name)).read()


def bind_target(mounts_src):
    """return the sandbox path the device-state bind mounts on"""
    for fn in ast.parse(mounts_src).body:
        if not isinstance(fn, ast.FunctionDef):
            continue
        for node in ast.walk(fn):
            if (isinstance(node, ast.Assign) and [ast.unparse(t) for t in node.targets] == ["device_state_dst"]):
                return eval(compile(ast.Expression(node.value), "sandbox/rootfs.py", "eval"),
                            dict(vars(core), NEWROOT=""))
    return None


def scaffold(launcher_src, root, host=False, loaded=False):
    """run the launcher's vendor scaffold staging into root"""
    fn = next(f for f in ast.parse(launcher_src).body if isinstance(f, ast.FunctionDef)
              and f.name == "_stage_vendor_scaffold")
    policy = type("Policy", (), {"vendor_property_contexts": staticmethod(lambda ns: "")})
    writes = []

    class Os:
        """os with its label writes recorded"""
        def __getattr__(self, name):
            """return the real os attribute"""
            return getattr(os, name)

        @staticmethod
        def setxattr(path, name, value, follow_symlinks=True):
            """record a label write"""
            writes.append((os.path.relpath(path, root), name, value, follow_symlinks))

    scope = dict(vars(core), RUN_ROOT=root, selinux_policy=policy, host_selinux_mode=lambda: host,
                 policy_is_loaded=lambda: loaded, os=Os(), DEVICE_STATE_POINT=(LINK, "u:object_r:rhizo_device_state_file:s0"))
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "boot.py", "exec"), scope)
    scope["_stage_vendor_scaffold"]()
    return writes


def policy_findings(cil, access):
    """return the old bind target's mount grants and an unjustified rmdir"""
    out = []
    grants = re.findall(r"\(allow rhizo_host (\w+)\s*\((\w+) \(([^()]*)\)\)\)", cil)
    for target, cls, perms in grants:
        if target in OLD_TARGET_TYPES and cls == "dir" and "mounton" in perms.split():
            out.append(f"the staged policy grants rhizo_host mounton on {target} dirs, the old bind target's type")
    rmdir = any(t == "rhizo_device_state_file" and c == "dir" and "rmdir" in p.split() for t, c, p in grants)
    row = any(f[0] == "rhizo_host" and f[2] == "rhizo_device_state_file" and "rmdir" in f[4].split()
              for f in (line.split("\t") for line in access.splitlines()) if len(f) > 4)
    if rmdir != row:
        out.append(f"rhizo_host rmdir on rhizo_device_state_file is {'granted' if rmdir else 'not granted'} but "
                   f"restart-access.tsv {'names no' if rmdir else 'names a'} use of it")
    return out


def findings(mounts_src, launcher_src, rc_texts, cil=None, access=None):
    """return the device-state bridge restorecon findings"""
    out = policy_findings(cil if cil is not None else read(os.path.join("guest", "sepolicy", "policy.cil")),
                          access if access is not None else
                          open(os.path.join(LAUNCHER, "..", "..", "test", "checks", "policy", "access", "restart-access.tsv")).read())
    target = bind_target(mounts_src)
    if target is None:
        return ["sandbox/rootfs.py assigns no device_state_dst"]
    walked = set(STOCK_RECURSIVE) | {p for text in rc_texts for p in RECURSIVE.findall(text)}
    under = sorted(p for p in walked if target == p or target.startswith(p.rstrip("/") + "/"))
    if under:
        out.append(f"the device-state bridge mounts on {target}, inside the recursive restorecon of {under}")
    with tempfile.TemporaryDirectory() as root:
        try:
            scaffold(launcher_src, root)
        except Exception as e:  # noqa: BLE001
            return out + [f"_stage_vendor_scaffold fails on a fresh tree: {type(e).__name__}: {e}"]
        fc = open(os.path.join(root, "vendor/etc/selinux/vendor_file_contexts")).read()
        named = [l for l in fc.splitlines() if "device-state" in l or "device_state" in l]
        if named:
            out.append(f"the staged vendor_file_contexts names the device-state path, a TestVendorTypeViolations entry: {named}")
        link = root + LINK
        got = os.readlink(link) if os.path.islink(link) else None
        if got != target:
            out.append(f"{LINK} links to {got!r}, want a symlink to the bridge's mount point {target}")
    want = (LINK.lstrip("/"), "security.selinux", b"u:object_r:vendor_configs_file:s0\0", False)
    for host, loaded, labeled in ((True, False, True), (True, True, False), (False, False, False)):
        with tempfile.TemporaryDirectory() as root:
            try:
                writes = scaffold(launcher_src, root, host, loaded)
            except Exception as e:  # noqa: BLE001
                out.append(f"_stage_vendor_scaffold fails in {'host' if host else 'namespace'} mode: {e!r}")
                continue
        if (want in writes) != labeled:
            mode = ("host mode with no policy loaded" if host and not loaded else
                    "host mode with a policy loaded" if host else "namespace mode")
            out.append(f"in {mode} the scaffold writes {writes}, want "
                       f"{'the link labeled vendor_configs_file' if labeled else 'no label on the link'}")
    staged = open(os.path.join(LAUNCHER, "guest", "sepolicy", "vendor_file_contexts")).read()
    if "device-state" in staged:
        out.append("src/androidd/guest/sepolicy/vendor_file_contexts names the device-state path")
    return out


def sources():
    """return the real sources"""
    return read("sandbox/rootfs.py"), read("boot.py"), [open(p).read() for p in
                                                           sorted(glob.glob(os.path.join(LAUNCHER, "guest", "init", "*.rc")))]


def selftest():
    """check each defect is flagged and the real source is clean"""
    mounts, launcher, rcs = sources()
    if findings(mounts, launcher, rcs):
        print(f"FAIL selftest: the real source is flagged: {findings(mounts, launcher, rcs)}")
        return 1
    assign = next(l for l in mounts.splitlines() if l.strip().startswith("device_state_dst ="))
    cases = (("a bridge under /vendor", (mounts.replace(assign, '    device_state_dst = f"{NEWROOT}/vendor/etc/rhizo-device-state"'),
                                         launcher, rcs), "inside the recursive restorecon"),
             ("a restorecon of the bridge", (mounts, launcher, rcs + ["on init\n    restorecon_recursive /rhizo-device-state\n"]),
              "inside the recursive restorecon"),
             ("a vendor_file_contexts entry", (mounts, launcher.replace(
                 "    if not os.path.lexists(RUN_ROOT + DEVICE_STATE_LINK):\n",
                 '    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a").write('
                 '"/vendor/etc/rhizo-device-state(/.*)? u:object_r:rhizo_device_state_file:s0\\n")\n'
                 "    if not os.path.lexists(RUN_ROOT + DEVICE_STATE_LINK):\n", 1), rcs),
              "TestVendorTypeViolations"),
             ("no vendor link", (mounts, re.sub(r"os\.symlink\(DEVICE_STATE_MOUNT[^\n]*", "pass", launcher, 1),
                                 rcs), "want a symlink"),
             ("an unlabeled host-mode link", (mounts, launcher.replace("host_selinux_mode() and not policy_is_loaded()",
                                                                        "False", 1), rcs),
              "want the link labeled"),
             ("a mount grant on the old target", (mounts, launcher, rcs, read(os.path.join("guest", "sepolicy", "policy.cil"))
                                                  + "\n(allow rhizo_host vendor_configs_file (dir (mounton)))\n"),
              "grants rhizo_host mounton on vendor_configs_file"))
    for name, args, want in cases:
        if args[:3] == (mounts, launcher, rcs) and len(args) == 3:
            print(f"FAIL selftest: the {name} mutant changed nothing")
            return 1
        got = findings(*args)
        if not any(want in f for f in got):
            print(f"FAIL selftest: the {name} mutant was not flagged ({want}): {got}")
            return 1
    print("device-state-restorecon selftest: a bridge under /vendor, a restorecon of the bridge, a vendor_file_contexts "
          "entry, a missing vendor link, an unlabeled host-mode link and a mount grant on the old target are flagged, "
          "the real source clean")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    bad = findings(*sources())
    for b in bad:
        print("FAIL", b)
    print("device-state-restorecon:", "FAIL" if bad else "ok")
    sys.exit(1 if bad else 0)
