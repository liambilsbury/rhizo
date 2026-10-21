#!/usr/bin/env python3
import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

GUARD_RE = re.compile(
    r"# --- relabel scope guard,.*?# --- end relabel scope guard\n", re.S)
PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)

ALLOWED = {
    ("selinux", "label_host_binaries"):
        "labels the host's own ext4 entrypoint binaries, nothing under a flat tree",
    ("selinux", "label_host_modules"):
        "labels the host's own /lib/modules tree on its own disk, nothing under a "
        "flat tree; label_write's mountinfo read per file would cost a boot-time "
        "second across twenty thousand modules",
    ("launcher", "_stage_tethering_apex"):
        "labels the apex copy it just staged, by name, never through a tree walk",
    ("launcher", "_stage_decompressed_apexes"):
        "labels each payload it just extracted from a .capex, by name, never "
        "through a tree walk",
    ("launcher", "stage_apex_and_patches"):
        "labels the audioserver upper file it just staged, by name",
    ("launcher", "label_in_namespace"):
        "labels the one path or fd in-android-policy's caller names, by name, inside its child namespace holding "
        "Android's policy with every capability dropped -- the inbox APK or device-state file the caller just made",
    ("launcher", "_stage_vendor_scaffold"):
        "labels the device-state link it just made on the instance's own vendor staging tree, by name, in host mode "
        "before a policy loads",
    ("launcher", "_relabel_prepared_vendor"):
        "the prepared tree is ext4 the installer copied, so a tmpfs test would "
        "refuse every write it exists to make",
}

REQUIRED_WRITES = {
    ("primer", "relabel_staged_files"): 3,
    ("primer", "relabel_flat_trees"): 2,
    ("primer", None): 1,
    ("primer", "relabel_host_kmsg"): 1,
    ("primer", "relabel_host_input_nodes"): 1,
    ("selinux", "relabel_root_objects_now"): 2,
}


def read_sources():
    """return the launcher and selinux sources"""
    launcher = open(os.path.join(REPO, "src", "androidd", "boot.py")).read()
    selinux = open(os.path.join(REPO, "src", "androidd", "sandbox", "selinux_labels.py")).read()
    return {"launcher": launcher, "selinux": selinux}


def primer_body(launcher):
    """return the primer source from the launcher text, or None"""
    m = PRIMER_RE.search(launcher)
    return m.group(1) if m else None


def guard_source(text):
    """return the guard source from a text, or None"""
    m = GUARD_RE.search(text)
    return m.group(0) if m else None


def _calls(tree):
    """return each call with its enclosing def"""
    out = []

    def walk(node, scope):
        """record the relabel calls in a node with the function they occur in"""
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                walk(child, child.name)
                continue
            if isinstance(child, ast.Call):
                f = child.func
                name = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", None)
                out.append((scope, name, child.lineno))
            walk(child, scope)

    walk(tree, None)
    return out


def check_guard(src):
    """return the problems when the two copies of the relabel guard differ"""
    bad = []
    primer = primer_body(src["launcher"])
    if primer is None:
        return ["launcher3.py has no HOST_PRIMER_SRC string"]
    copies = {"selinux": guard_source(src["selinux"]), "primer": guard_source(primer)}
    for where, text in copies.items():
        if text is None:
            bad.append("%s carries no relabel scope guard" % where)
    if not bad and copies["selinux"] != copies["primer"]:
        bad.append("the relabel scope guard has DRIFTED between sandbox/selinux_labels.py "
                   "and the primer")
    return bad


def check_writes(src):
    """list the label_write check failures"""
    bad = []
    primer = primer_body(src["launcher"])
    if primer is None:
        return ["launcher3.py has no HOST_PRIMER_SRC string"]
    trees = {"launcher": ast.parse(src["launcher"]),
             "selinux": ast.parse(src["selinux"]),
             "primer": ast.parse(primer)}
    written = {}
    for where, tree in trees.items():
        for scope, name, lineno in _calls(tree):
            if name == "setxattr" and scope != "label_write":
                key = (where, scope)
                if key not in ALLOWED:
                    bad.append("%s: %s() line %d writes security.selinux with a "
                               "bare os.setxattr" % (where, scope or "<module>", lineno))
            if name == "label_write":
                written[(where, scope)] = written.get((where, scope), 0) + 1
    for key, want in REQUIRED_WRITES.items():
        got = written.get(key, 0)
        if got < want:
            bad.append("%s: %s makes %d guarded label_write call(s), want %d" % (key[0], key[1] or "<module>", got, want))
    return bad


def check_readonly_lower(text=None):
    """check each flatten_tree call for readonly_lower"""
    bad = []
    if text is None:
        text = open(os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")).read()
    seen = 0
    for node in ast.walk(ast.parse(text)):
        if not (isinstance(node, ast.Call) and getattr(node.func, "id", "") == "flatten_tree"):
            continue
        seen += 1
        ro = [k for k in node.keywords if k.arg == "readonly_lower"]
        if not ro or not (isinstance(ro[0].value, ast.Constant) and ro[0].value.value is True):
            bad.append("sandbox/rootfs.py line %d: flatten_tree without "
                       "readonly_lower=True" % node.lineno)
    if seen < 3:
        bad.append("sandbox/rootfs.py has %d flatten_tree call(s), want the three "
                   "GSI trees" % seen)
    return bad


class _OsShim:
    """fake os module for setxattr"""

    def __init__(self):
        """start with no recorded writes"""
        self.writes = []

    def __getattr__(self, name):
        """return the attribute from the os module"""
        return getattr(os, name)

    def setxattr(self, path, name, value, follow_symlinks=True):
        """record the path of an attribute write"""
        self.writes.append(path)


def _load_guard(text):
    """return the guard namespace and the os shim it runs against"""
    shim = _OsShim()
    ns = {"os": shim}
    exec(compile(text, "<relabel-guard>", "exec"), ns)
    return ns, shim


def _fs_magic(path):
    """return the filesystem magic number of a path, or None"""
    import ctypes
    buf = ctypes.create_string_buffer(256)
    if ctypes.CDLL("libc.so.6", use_errno=True).statfs(os.fsencode(path), buf) != 0:
        return None
    return ctypes.cast(buf, ctypes.POINTER(ctypes.c_long))[0]


TMPFS_MAGIC = 0x01021994
RO_ENV = "RHIZO_RELABEL_RO_FIXTURE"


def _fixture_roots():
    """return a writable directory and a read-only mount"""
    writable = ro = None
    mounts = [line.split()[4] for line in open("/proc/self/mountinfo") if len(line.split()) >= 5]
    for cand in [tempfile.gettempdir(), REPO, os.path.expanduser("~"), "/var/tmp"] + mounts:
        if cand and os.path.isdir(cand) and os.access(cand, os.W_OK) \
                and _fs_magic(cand) != TMPFS_MAGIC \
                and not (os.statvfs(cand).f_flag & os.ST_RDONLY):
            writable = cand
            break
    for line in open("/proc/self/mountinfo"):
        f = line.split()
        if len(f) >= 6 and "ro" in f[5].split(",") and os.access(f[4], os.R_OK) \
                and (os.statvfs(f[4]).f_flag & os.ST_RDONLY):
            ro = f[4]
            break
    fixture = os.environ.get(RO_ENV)
    if fixture and os.path.isdir(fixture) and os.statvfs(fixture).f_flag & os.ST_RDONLY:
        ro = fixture
    return writable, ro


def _rerun_with_ro_mount():
    """rerun this check over a read-only fixture mount"""
    unshare = shutil.which("unshare")
    if _fixture_roots()[1] is not None or os.environ.get(RO_ENV) or not unshare:
        return None
    d = tempfile.mkdtemp(prefix="relabel-ro-")
    try:
        for name in ("a", "b", "c"):
            with open(os.path.join(d, name), "w") as f:
                f.write("x")
        bind = 'mount --bind "$1" "$1" && mount -o remount,bind,ro "$1" && shift && exec "$@"'
        argv = [unshare, "-rm", "sh", "-c", bind, "sh", d, sys.executable, os.path.abspath(__file__)] + sys.argv[1:]
        return subprocess.run(argv, env=dict(os.environ, **{RO_ENV: d})).returncode
    finally:
        shutil.rmtree(d, ignore_errors=True)


def _build_fixture(writable_dir):
    """build a fixture tree under writable_dir"""
    ours = tempfile.mkdtemp(prefix="relabel-ours-", dir=writable_dir)
    os.makedirs(os.path.join(ours, "bin"), exist_ok=True)
    open(os.path.join(ours, "bin", "toybox"), "w").write("x")
    os.symlink("toybox", os.path.join(ours, "bin", "sh"))
    os.symlink("/apex/com.android.art/bin/dex2oat",
               os.path.join(ours, "bin", "dex2oat"))
    return ours


GSI = "/srv/rhizo/gsi_system"
TABLES = {
    "gsi inside the root fs": ("""\
22 1 253:1 / / rw,relatime - ext4 /dev/vda1 rw
46 22 0:45 / /run/rhizo rw,relatime - tmpfs tmpfs rw
60 46 253:1 /var/lib/rhizo/vendor /run/rhizo/vendor rw,relatime - ext4 /dev/vda1 rw
70 46 253:1 /srv/rhizo/gsi_system/lib64 /run/rhizo/system_flat/lib64 ro,relatime - ext4 /dev/vda1 ro
71 46 253:1 /srv/rhizo/gsi_system/system_ext/etc /run/rhizo/system_ext_flat/etc rw,relatime - ext4 /dev/vda1 rw
""", [("/run/rhizo/vendor/etc/selinux/vendor_file_contexts", False),
      ("/var/lib/rhizo/vendor/bin/hw/rhizo-composer", False),
      ("/run/rhizo/system_flat/etc", False),
      ("/run/rhizo/system_flat/lib64/libc.so", True),
      ("/run/rhizo/system_ext_flat/etc/init/x.rc", True),
      ("/srv/rhizo/gsi_system/bin/init", True)]),
    "gsi on its own filesystem": ("""\
22 1 253:1 / / rw,relatime - ext4 /dev/vda1 rw
30 22 7:3 / /srv/rhizo/gsi_system ro,relatime - ext4 /dev/loop3 ro
46 22 0:45 / /run/rhizo rw,relatime - tmpfs tmpfs rw
60 46 253:1 /var/lib/rhizo/vendor /run/rhizo/vendor rw,relatime - ext4 /dev/vda1 rw
70 46 7:3 /lib64 /run/rhizo/system_flat/lib64 ro,relatime - ext4 /dev/loop3 ro
""", [("/run/rhizo/vendor/etc", False),
      ("/run/rhizo/system_flat/etc", False),
      ("/run/rhizo/system_flat/lib64/libc.so", True),
      ("/srv/rhizo/gsi_system/bin/init", True)]),
    "the pivoted sandbox": ("""\
90 80 0:50 / / rw,relatime - tmpfs tmpfs rw
91 90 253:1 /var/lib/rhizo/vendor /vendor rw,relatime - ext4 /dev/vda1 rw
92 90 253:1 /srv/rhizo/gsi_system/lib64 /system/lib64 ro,relatime - ext4 /dev/vda1 ro
""", [("/", False), ("/vendor/etc", False), ("/etc", False),
      ("/system/lib64/libc.so", True)]),
}


def check_fixture(guard_text):
    """test the guard on fixture inodes and tables"""
    ns, shim = _load_guard(guard_text)
    bad = []
    for shape, (table, cases) in TABLES.items():
        for path, want in cases:
            got = ns["_gsi_backed"](path, table, GSI)
            if got != want:
                bad.append("%s: the guard reads %s as %s" % (
                    shape, path, "GSI-backed" if got else "ours"))
    writable_dir, ro_mount = _fixture_roots()
    if writable_dir is None:
        return bad + ["no writable non-tmpfs directory to build the fixture on"]
    if ro_mount is None:
        return bad + ["no read-only mount to stand in for a GSI bind"]
    ours = _build_fixture(writable_dir)
    try:
        label = b"u:object_r:system_file:s0\x00"
        for name in ("bin", "bin/toybox", "bin/sh", "bin/dex2oat"):
            skipped = []
            p = os.path.join(ours, name)
            if not ns["label_write"](p, label, follow_symlinks=False, skipped=skipped):
                bad.append("the guard refused %s, a writable inode off tmpfs" % name)
            if skipped:
                bad.append("%s was counted as GSI-backed" % name)
        theirs = [ro_mount] + [os.path.join(ro_mount, e)
                               for e in sorted(os.listdir(ro_mount))[:3]]
        gsi_skipped = []
        for p in theirs:
            if ns["label_write"](p, label, follow_symlinks=False, skipped=gsi_skipped):
                bad.append("the guard WROTE %s, an inode on a read-only mount" % p)
        if len(gsi_skipped) != len(theirs):
            bad.append("the guard counted %d of %d read-only objects as skipped" % (len(gsi_skipped), len(theirs)))
        for w in shim.writes:
            if w.startswith(ro_mount):
                bad.append("setxattr reached %s" % w)
    finally:
        shutil.rmtree(ours, ignore_errors=True)
    return bad


def check(src):
    """return the problems from every relabel scope check"""
    bad = check_guard(src)
    if bad:
        return bad
    bad += check_writes(src)
    bad += check_readonly_lower()
    bad += check_fixture(guard_source(src["selinux"]))
    return bad


def selftest():
    """test the checks on mutated sources"""
    src = read_sources()
    n = 0
    assert check(src) == [], "the real tree must pass: %s" % check(src)
    n += 1

    gone = dict(src, launcher=GUARD_RE.sub("", src["launcher"], count=1))
    assert gone["launcher"] != src["launcher"], "fixture did not apply"
    assert any("carries no relabel scope guard" in f for f in check(gone)), \
        "a missing guard must be reported"
    n += 1

    drifted = dict(src, selinux=src["selinux"].replace(
        "return not _gsi_backed(inner, mountinfo, gsi)",
        "return _gsi_backed(inner, mountinfo, gsi)", 1))
    assert drifted["selinux"] != src["selinux"], "fixture did not apply"
    assert any("DRIFTED" in f for f in check(drifted)), \
        "a guard that differs between its two copies must be reported"
    n += 1

    reverted = dict(src, launcher=src["launcher"].replace(
        '''            if label_write(_p, _want.encode() + b"\\x00",
                           follow_symlinks=False, skipped=_foreign):
                _applied += 1''',
        '''            os.setxattr(_p, "security.selinux", _want.encode() + b"\\x00",
                        follow_symlinks=False)
            _applied += 1''', 1))
    assert reverted["launcher"] != src["launcher"], "fixture did not apply"
    found = check(reverted)
    assert any("relabel_staged_files" in f and "bare os.setxattr" in f
               for f in found), \
        "a bare os.setxattr in relabel_staged_files must be named: %s" % found
    n += 1

    dropped = dict(src, launcher=src["launcher"].replace(
        "label_write(_fdir", "_write_removed(_fdir", 1))
    assert dropped["launcher"] != src["launcher"], "fixture did not apply"
    assert any("relabel_flat_trees" in f and "guarded label_write" in f
               for f in check(dropped)), \
        "a pass that lost a guarded write must be named"
    n += 1

    original = open(os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")).read()
    weakened = original.replace(
        '''                     f"{RUN_ROOT}/system_ext_flat", readonly_lower=True)''',
        '''                     f"{RUN_ROOT}/system_ext_flat")''', 1)
    assert weakened != original, "fixture did not apply: the system_ext call moved"
    assert any("readonly_lower=True" in f for f in check_readonly_lower(weakened)), \
        "a flat tree staged with a writable GSI lower must be reported"
    assert check_readonly_lower(original) == [], "the tree's own flatten_tree calls must pass"
    n += 1

    blind = guard_source(src["selinux"]).replace(
        "    if not inode_is_ours(path):", "    if False:", 1)
    assert blind != guard_source(src["selinux"]), "fixture did not apply"
    found = check_fixture(blind)
    assert any("the guard WROTE" in f for f in found), \
        "a guard that no longer tests the inode must be caught on the fixture: %s" % found
    n += 1

    narrow = guard_source(src["selinux"]).replace(
        "    probe = (os.path.dirname(path)",
        "    return False\n    probe = (os.path.dirname(path)", 1)
    assert narrow != guard_source(src["selinux"]), "fixture did not apply"
    found = check_fixture(narrow)
    assert any("the guard refused" in f and "off tmpfs" in f for f in found), \
        "a guard that refuses the launcher's own writable tree must be caught: %s" % found
    n += 1

    lax = guard_source(src["selinux"]).replace(
        '    under = served[1] == gsi_root or served[1].startswith(gsi_root + "/")',
        "    under = False", 1)
    assert lax != guard_source(src["selinux"]), "fixture did not apply"
    found = check_fixture(lax)
    assert any("reads /run/rhizo/system_ext_flat/etc/init/x.rc as ours" in f for f in found), \
        "a guard blind to a writable GSI bind must be caught on the tables: %s" % found
    n += 1

    raising = guard_source(src["selinux"]).replace(
        "    if not inode_is_ours(path):",
        "    raise OSError(\"fixture: a label write that fails mid-pass\")\n    if not inode_is_ours(path):", 1)
    assert raising != guard_source(src["selinux"]), "fixture did not apply"
    built = []
    real_build = globals()["_build_fixture"]
    globals()["_build_fixture"] = lambda d: built.append(real_build(d)) or built[-1]
    try:
        check_fixture(raising)
    except OSError:
        pass
    finally:
        globals()["_build_fixture"] = real_build
    assert built, "check_fixture built no fixture tree to clean up"
    assert not os.path.exists(built[0]), \
        "a guard that raises mid-pass left the fixture tree %s behind" % built[0]
    n += 1

    print("check-relabel-scope selftest: %d assertions passed" % n)


if __name__ == "__main__":
    rerun = _rerun_with_ro_mount()
    if rerun is not None:
        sys.exit(rerun)
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = check(read_sources())
    for f in findings:
        print("check-relabel-scope: " + f)
    sys.exit(1 if findings else 0)
