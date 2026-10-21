#!/usr/bin/env python3
import contextlib
import errno
import importlib.util
import inspect
import io
import os
import shutil
import sys
import tempfile

LAUNCHER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
                                         "src", "androidd", "boot.py"))


def load(path, name):
    """return the launcher module loaded from a file"""
    if os.path.dirname(LAUNCHER) not in sys.path:
        sys.path.insert(0, os.path.dirname(LAUNCHER))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ROOT_ROW = ("1", "0", "8:1", "/", "/")


class FakeLibc:
    """umount2 over a fake mount table"""

    def __init__(self, rows, stuck):
        """store the table rows and the stuck targets"""
        self.rows, self.stuck = rows, stuck

    def umount2(self, target, flags):
        """remove the top mount at target, refusing one with a mount below it"""
        target = target.decode()
        on = [r for r in self.rows if r[4] == target]
        if target in self.stuck or not on or any(r[1] == on[-1][0] for r in self.rows):
            return -1
        self.rows.remove(on[-1])
        return 0


def unmount_cases(mod):
    """return the _unmount_tree findings"""
    tmpfs = ("20", "1", "0:50", "/", "/r/root")
    stacked = [("%d" % (30 + n), "20", "0:%d" % (60 + n), "/", "/r/root") for n in range(8)]
    vendor = ("22", "20", "8:1", "/var/x/vendor", "/r/root/vendor")
    vendor_bin = ("24", "22", "0:53", "/", "/r/root/vendor/bin")
    bad = []
    saved = (mod.core.read_mountinfo, mod.libc, mod.kmsg)
    mod.kmsg = lambda m: None
    try:
        for label, path, table, stuck, want, left in (
                ("an unreadable mount table", "/r/root", None, (), False, None),
                ("a clear table", "/r/root", [ROOT_ROW], (), True, ["/"]),
                ("the path mounted twice", "/r/root", [ROOT_ROW, tmpfs, stacked[0]], (), True, ["/"]),
                ("the path held", "/r/root", [ROOT_ROW, tmpfs], ("/r/root",), False, None),
                ("a mount below the path held", "/r/root", [ROOT_ROW, tmpfs, vendor], ("/r/root/vendor",), False, None),
                ("a neighbor sharing the prefix", "/r/root", [ROOT_ROW, ("23", "1", "0:52", "/", "/r/rootfs")], (), True,
                 ["/", "/r/rootfs"]),
                ("a mount on a dentry inside the path, reached through a bind, held", "/var/x",
                 [ROOT_ROW, tmpfs, vendor, vendor_bin], ("/r/root/vendor/bin",), False, None),
                ("a bind of the path's filesystem elsewhere", "/var/x", [ROOT_ROW, tmpfs, vendor, vendor_bin], (), True,
                 ["/", "/r/root"]),
                ("the path cleared by its eighth unmount", "/r/root", [ROOT_ROW] + stacked, (), True, ["/"]),
                ("binds nested under a bind below the path", "/r/root", [ROOT_ROW, tmpfs, vendor, vendor_bin], (), True,
                 ["/"]),
                ("the path still mounted after eight unmounts", "/r/root", [ROOT_ROW, tmpfs] + stacked, (), False, None)):
            rows = None if table is None else list(table)
            mod.core.read_mountinfo = (lambda: None) if rows is None else (lambda r=rows: list(r))
            mod.libc = FakeLibc(rows if rows is not None else [], stuck)
            try:
                got = mod._unmount_tree(path)
            except Exception as e:
                bad.append(f"_unmount_tree raises on {label}: {e!r}")
                continue
            if got is not want:
                bad.append(f"_unmount_tree reads {label} as {'clear' if got else 'held'}: got {got!r}")
            if left is not None and [r[4] for r in rows] != left:
                bad.append(f"_unmount_tree leaves {[r[4] for r in rows]} for {label}, not {left}")
    finally:
        mod.core.read_mountinfo, mod.libc, mod.kmsg = saved
    return bad


def run_verb(mod, held, stuck_binds=(), host_mode=False, enforce=None, rmtree_fail=(), env=None):
    """run prepare_tree_verb with held mounts"""
    work = tempfile.mkdtemp()
    run_root, dest = f"{work}/run", f"{work}/dest"
    removed = []
    held = [h.format(run=run_root, dest=dest) for h in held]
    stuck_binds = [b.format(run=run_root, dest=dest) for b in stuck_binds]
    rmtree_fail = [r.format(run=run_root, dest=dest) for r in rmtree_fail]
    first_only = [r[:-len("#first")] for r in rmtree_fail if r.endswith("#first")]
    os.makedirs(run_root)
    with open(f"{run_root}/old-staging", "w"):
        pass
    kept_ino = os.lstat(run_root).st_ino
    real_remove, real_rmtree = (os.rmdir, os.unlink), shutil.rmtree
    staged = []
    node = f"{work}/selinuxfs/enforce"
    if enforce == "stat-refused":
        node = f"{work}/shut/selinuxfs/enforce"
        os.makedirs(os.path.dirname(node))
        os.chmod(f"{work}/shut", 0)
    elif enforce == "unreadable":
        os.makedirs(node)
    elif enforce is not None:
        os.makedirs(os.path.dirname(node))
        with open(node, "w") as f:
            f.write(enforce + "\n")

    def fake_mount(source, target, *args, **kwargs):
        """hold a stuck bind target"""
        if target in stuck_binds:
            held.append(target)
        return True

    def fake_unmount(path):
        """check path for a held mount"""
        return not any(h == path or h.startswith(path.rstrip("/") + "/") for h in held)

    def fake_system(cmd):
        """record a removal and the mounts held then"""
        removed.append((cmd.split()[-1], list(held)))
        return 0

    def fake_rmtree(path, ignore_errors=False):
        """record a removal and the mounts held then"""
        removed.append((path, list(held)))
        if (path in rmtree_fail or path in first_only) and not ignore_errors:
            if path in first_only:
                first_only.remove(path)
            raise PermissionError(13, "Permission denied", path)
        if not os.path.exists(path) and not ignore_errors:
            raise FileNotFoundError(2, "No such file or directory", path)
        real_rmtree(path, ignore_errors=ignore_errors)

    def fake_remove(real):
        """wrap a remover to record and fail removals"""
        def remove(path, *args, **kwargs):
            """record a removal and fail it as the case says"""
            if kwargs.get("dir_fd") is not None:
                full = os.path.join(os.readlink(f"/proc/self/fd/{kwargs['dir_fd']}"), path)
            else:
                full = path
            removed.append((full, list(held)))
            for r in first_only + [r for r in rmtree_fail if not r.endswith("#first")]:
                if full.startswith(r.rstrip("/") + "/"):
                    if r in first_only:
                        first_only.remove(r)
                    raise PermissionError(13, "Permission denied", path)
            return real(path, *args, **kwargs)
        return remove

    names = ("RUN_ROOT", "_unmount_tree", "_sandbox_is_live", "host_has_own_policy", "host_selinux_mode", "mount",
             "_stage_prepared_tree", "_build_prepared_manifest", "SELINUX_ENFORCE_NODE", "kmsg")
    saved = {n: getattr(mod, n) for n in names}
    saved_os = (os.geteuid, os.system, os.sync, shutil.rmtree, dict(os.environ))
    mod.RUN_ROOT = run_root
    mod._unmount_tree = fake_unmount
    mod._sandbox_is_live = lambda: False
    mod.host_has_own_policy = lambda: False
    mod.host_selinux_mode = lambda: host_mode
    mod.SELINUX_ENFORCE_NODE = node
    mod.kmsg = lambda m: None
    mod.mount = fake_mount
    mod._stage_prepared_tree = lambda part: staged.append((part, {k: v for k, v in os.environ.items()
                                                                  if k.startswith("RHIZO_")})) or ([], None)
    mod._build_prepared_manifest = lambda part, recorded: {"key": "k1", "inputs": [], "outputs": []}
    os.geteuid, os.system, os.sync, shutil.rmtree = (lambda: 0), fake_system, (lambda: None), fake_rmtree
    os.rmdir, os.unlink = fake_remove(real_remove[0]), fake_remove(real_remove[1])
    os.environ.update(env or {})
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = mod.prepare_tree_verb(dest)
    finally:
        for n, v in saved.items():
            setattr(mod, n, v)
        os.geteuid, os.system, os.sync, shutil.rmtree = saved_os[:4]
        os.rmdir, os.unlink = real_remove
        run_verb.kept = os.path.isdir(run_root) and os.lstat(run_root).st_ino == kept_ino
        os.environ.clear()
        os.environ.update(saved_os[4])
        if os.path.isdir(f"{work}/shut"):
            os.chmod(f"{work}/shut", 0o700)
        shutil.rmtree(work, ignore_errors=True)
    lines = out.getvalue().splitlines()
    run_verb.staged = staged
    return rc, (lines[-1] if lines else ""), lines, removed, run_root, dest


def verb_cases(mod):
    """return the findings for prepare_tree_verb's teardown"""
    bad = []
    for label, held, binds, want_reason in (
            ("the staging root held at start", ["{run}"], [], "unmount:{run}"),
            ("the old build.part's vendor held", ["{dest}/build.part/vendor"], [], "unmount:{dest}/build.part"),
            ("the staging vendor bind held", [], ["{run}/vendor"], "unmount:{run}/vendor")):
        rc, last, lines, removed, run_root, dest = run_verb(mod, held, binds)
        want = f"PREPARE_TREE_FAILED reason={want_reason.format(run=run_root, dest=dest)}"
        if rc != 1 or last != want:
            bad.append(f"with {label}, prepare-tree ends rc={rc} '{last}', not rc=1 '{want}'")
        through = [path for path, held_then in removed
                   if any(h == path or h.startswith(path.rstrip("/") + "/") or path.startswith(h.rstrip("/") + "/")
                          for h in held_then)]
        if through:
            bad.append(f"with {label}, prepare-tree removes through the held mount: {through}")
        if any(line.startswith("PREPARE_TREE_OK") for line in lines):
            bad.append(f"with {label}, prepare-tree prints a success line: {lines}")
    rc, last, lines, removed, run_root, dest = run_verb(mod, [])
    if rc != 0 or not last.startswith("PREPARE_TREE_OK key=k1"):
        bad.append(f"with nothing held, prepare-tree ends rc={rc} '{last}'")
    if not run_verb.kept:
        bad.append("prepare-tree removes the staging root's directory, not only its contents")
    for label, kwargs, want in (
            ("an unreadable enforce node in host mode", {"host_mode": True, "enforce": "unreadable"},
             "PREPARE_TREE_FAILED reason=enforce-unreadable"),
            ("an enforcing host policy in host mode", {"host_mode": True, "enforce": "1"}, "PREPARE_TREE_REFUSED reason=enforcing"),
            ("a permissive host policy in host mode", {"host_mode": True, "enforce": "0"}, "PREPARE_TREE_OK key=k1"),
            ("no selinuxfs in host mode", {"host_mode": True}, "PREPARE_TREE_OK key=k1"),
            ("an unreadable enforce node in namespace mode", {"enforce": "unreadable"}, "PREPARE_TREE_OK key=k1"),
            ("an old build.part that will not go", {"rmtree_fail": ["{dest}/build.part"]},
             "PREPARE_TREE_FAILED reason=remove:{dest}/build.part"),
            ("an old tree of the same key that will not go", {"rmtree_fail": ["{dest}/k1"]},
             "PREPARE_TREE_FAILED reason=remove:{dest}/k1"),
            ("a staging root that will not go", {"rmtree_fail": ["{run}"]}, "PREPARE_TREE_FAILED reason=remove:{run}"),
            ("an old staging root that will not go", {"rmtree_fail": ["{run}#first"]},
             "PREPARE_TREE_FAILED reason=remove:{run}"),
            ("a refused stat of selinuxfs in host mode", {"host_mode": True, "enforce": "stat-refused"},
             "PREPARE_TREE_FAILED reason=enforce-unreadable")):
        rc, last, lines, removed, run_root, dest = run_verb(mod, [], **kwargs)
        want = want.format(dest=dest, run=run_root)
        if not last.startswith(want) or (rc == 0) != want.startswith("PREPARE_TREE_OK"):
            bad.append(f"with {label}, prepare-tree ends rc={rc} '{last}', not '{want}'")
        if label == "an old staging root that will not go" and run_verb.staged:
            bad.append(f"with {label}, prepare-tree staged into it anyway")
    for mode in ("host", "namespace"):
        rc, last, lines, removed, run_root, dest = run_verb(
            mod, [], env={"RHIZO_SELINUX_MODE": mode, "RHIZO_PERMISSIVE": "1", "RHIZO_SCRUB_PROBE": "1"})
        seen = [e for _part, e in run_verb.staged]
        if rc != 0 or seen != [{"RHIZO_SELINUX_MODE": mode}]:
            bad.append(f"prepare-tree stages {mode} mode under the environment {seen}, not the mode alone")
    return bad


def teardown_cases(mod):
    """return the findings for the start's RUN_ROOT teardown"""
    bad = []
    run_root = "/run/rhizo-7"
    tmpfs = ("20", "1", "0:50", "/", run_root)
    vendor = ("22", "20", "8:1", "/var/lib/rhizo/instances/7/vendor", f"{run_root}/vendor")
    subs = [(str(23 + n), "22", "8:1", f"/var/lib/rhizo/prepared/k/vendor/{d}", f"{run_root}/vendor/{d}")
            for n, d in enumerate(("bin", "lib", "lib64"))]
    data = ("30", "20", "7:0", "/", f"{run_root}/data")
    apex = ("31", "20", "8:1", "/var/lib/rhizo/instances/7/apex", f"{run_root}/apex_override")
    crashed = [ROOT_ROW, tmpfs, vendor] + subs + [data, apex]
    names = ("RUN_ROOT", "RHIZO_DATA_IMG", "_loops_backing", "libc", "kmsg")
    saved = {n: getattr(mod, n) for n in names}
    saved_read, saved_rmtree = mod.core.read_mountinfo, shutil.rmtree
    try:
        for label, table, stuck, loops, rmtree_fails, want, want_log in (
                ("a clear run root", [ROOT_ROW], (), {}, False, None, None),
                ("a crashed start's mounts and an unused data.img loop", crashed, (),
                 {"/dev/loop0": (None, "clears")}, False, None, "data_img_loop_detached dev=/dev/loop0"),
                ("a held data mount", crashed, (f"{run_root}/data",), {}, False, f"unmount:{run_root}", None),
                ("an unlisted data.img loop", [ROOT_ROW, tmpfs], (), None, False, "data-img-loops-unknown",
                 "could not tell which loop devices back /var/lib/rhizo/instances/7/data.img"),
                ("a data.img loop mounted elsewhere", [ROOT_ROW], (), {"/dev/loop3": ("mounted at /mnt/x", "clears")},
                 False, "data-img-busy:/dev/loop3", "still attached at /dev/loop3, mounted at /mnt/x"),
                ("a data.img loop a lazily detached filesystem claims", [ROOT_ROW], (),
                 {"/dev/loop3": ("claimed by a filesystem", "clears")}, False, "data-img-busy:/dev/loop3",
                 "still attached at /dev/loop3, claimed by a filesystem"),
                ("a data.img loop whose detach is deferred", [ROOT_ROW], (), {"/dev/loop3": (None, "stays")}, False,
                 "data-img-busy:/dev/loop3", "still attached at /dev/loop3 after losetup -d"),
                ("a data.img loop that will not detach", [ROOT_ROW], (), {"/dev/loop3": (None, "fails")}, False,
                 "data-img-busy:/dev/loop3", "data.img loop /dev/loop3 left by an earlier start: busy")):
            rows, logs, removed, detached = list(table), [], [], []
            attached = None if loops is None else dict(loops)
            mod.RUN_ROOT, mod.RHIZO_DATA_IMG = run_root, "/var/lib/rhizo/instances/7/data.img"
            mod.core.read_mountinfo = lambda r=rows: list(r)
            mod.libc = FakeLibc(rows, stuck)
            mod.kmsg = logs.append
            mod._loops_backing = lambda img, losetup, a=attached: None if a is None else sorted(a)

            def losetup(args, a=attached):
                """record a detach and clear, keep or fail it as the case says"""
                detached.append(args)
                how = a[args[1]][1]
                if how == "clears":
                    del a[args[1]]
                return (1, "", "busy") if how == "fails" else (0, "", "")

            def in_use(dev, a=attached):
                """answer the case's use of dev"""
                return a[dev][0]

            def fake_rmtree(path, ignore_errors=False, rows=rows, fails=rmtree_fails):
                """record a removal and the mounts held then"""
                removed.append((path, [r[4] for r in rows if r[4] == path or r[4].startswith(path + "/")]))
                if fails:
                    raise PermissionError(13, "Permission denied", path)

            shutil.rmtree = fake_rmtree
            try:
                clear = getattr(mod, "clear_run_root", None)
                takes_use = clear is not None and "in_use" in inspect.signature(clear).parameters
                got = ("no clear_run_root" if clear is None
                       else clear(losetup, in_use=in_use, wait_s=0) if takes_use else clear(losetup))
            except Exception as e:
                got = repr(e)
            if got != want:
                bad.append(f"the start's teardown with {label} returns {got!r}, not {want!r}")
            through = [(p, held) for p, held in removed if held]
            if through:
                bad.append(f"the start's teardown with {label} removes through a held mount: {through}")
            if want and not want.startswith("remove:") and removed:
                bad.append(f"the start's teardown with {label} removes after its refusal: {removed}")
            if want_log and not any(want_log in m for m in logs):
                bad.append(f"the start's teardown with {label} does not name {want_log!r}: {logs}")
            busy = {d for d, (use, _how) in (loops or {}).items() if use}
            if [a for a in detached if a[1] in busy]:
                bad.append(f"the start's teardown with {label} detaches a busy data.img loop: {detached}")
            if want is None and attached:
                bad.append(f"the start's teardown with {label} goes on with data.img attached at {attached}")
        mod.core.read_mountinfo = saved_read
        with tempfile.TemporaryDirectory() as tmp:
            sysblock, table = os.path.join(tmp, "block"), os.path.join(tmp, "mountinfo")
            os.makedirs(os.path.join(sysblock, "loop3"))
            with open(os.path.join(sysblock, "loop3", "dev"), "w") as f:
                f.write("7:3\n")
            mounted_line = "40 1 7:3 / /mnt/old\\040data rw - ext4 /dev/loop3 rw\n"
            for label, lines, opener_err, dev, want in (
                    ("mounted in this namespace", mounted_line, None, "/dev/loop3", "mounted at /mnt/old data"),
                    ("claimed by a lazily detached filesystem", "", errno.EBUSY, "/dev/loop3", "claimed"),
                    ("attached and unused", "", None, "/dev/loop3", None),
                    ("a loop gone before the read", "", None, "/dev/loop9", None),
                    ("a loop that cannot be opened", "", errno.ENOENT, "/dev/loop3", "cannot be opened"),
                    ("an unreadable mount table", None, None, "/dev/loop3", "is unreadable")):
                if lines is None:
                    path = os.path.join(tmp, "absent")
                else:
                    path = table
                    with open(table, "w") as f:
                        f.write(lines)

                def opener(dev_path, flags, err=opener_err):
                    """open a stand-in fd, or fail with the case's errno"""
                    if not flags & os.O_EXCL:
                        return -1
                    if err:
                        raise OSError(err, os.strerror(err), dev_path)
                    return os.open(os.devnull, os.O_RDONLY)

                saved_holders = getattr(mod, "_loop_holders", None)
                mod._loop_holders = lambda d, sysblock=None: []
                try:
                    in_use_fn = getattr(mod, "_loop_in_use", None)
                    got = ("no _loop_in_use" if in_use_fn is None
                           else in_use_fn(dev, table=path, sysblock=sysblock, opener=opener))
                except Exception as e:
                    got = repr(e)
                finally:
                    mod._loop_holders = saved_holders
                if (want is None and got is not None) or (want is not None and (not got or want not in got)):
                    bad.append(f"_loop_in_use for a loop {label} answers {got!r}, not {want!r}")
    finally:
        for n, v in saved.items():
            setattr(mod, n, v)
        mod.core.read_mountinfo, shutil.rmtree = saved_read, saved_rmtree
    src = open(mod.__file__).read()
    if ("    _run_root_why = clear_run_root()\n    if _run_root_why:\n        refuse_start_by_name(_run_root_why)\n"
            not in src):
        bad.append("the start does not refuse by name when clear_run_root fails")
    for shell in ("rm -rf {RUN_ROOT}", "umount {RUN_ROOT}/binderfs 2>/dev/null",
                  "_loops_backing(RHIZO_DATA_IMG, _losetup) or []"):
        if shell in src:
            bad.append(f"the start's teardown still runs {shell!r}")
    for mode, want_records in (("namespace", [("refused-reason", f"unmount:{run_root}")]), ("host", [])):
        records, refused = [], []
        saved_fns = (mod.record_refusal_unless_final, mod.refuse_start, mod.host_selinux_mode, mod.kmsg)
        mod.record_refusal_unless_final = lambda reason, *a: records.append(("refused-reason", reason))
        mod.refuse_start = lambda: refused.append(True)
        mod.host_selinux_mode = lambda mode=mode: mode == "host"
        mod.kmsg = lambda m: None
        try:
            mod.refuse_start_by_name(f"unmount:{run_root}") if hasattr(mod, "refuse_start_by_name") else None
        finally:
            mod.record_refusal_unless_final, mod.refuse_start, mod.host_selinux_mode, mod.kmsg = saved_fns
        if records != want_records or refused != [True]:
            bad.append(f"the start does not refuse by name in {mode} mode: records {records}, refused {refused}")
    return bad


def empty_dir_cases(mod):
    """return the findings for emptying a real RUN_ROOT"""
    import stat as stat_mod
    bad = []
    names = ("RUN_ROOT", "_loops_backing", "libc", "kmsg", "fd_mount_id")
    saved = {n: getattr(mod, n, None) for n in names}
    saved_read, real_stat, real_unlink = mod.core.read_mountinfo, os.stat, os.unlink
    real_mount_id = getattr(mod, "fd_mount_id", None)
    with tempfile.TemporaryDirectory() as tmp:
        run, outside = f"{tmp}/run", f"{tmp}/outside"
        os.makedirs(outside)
        with open(f"{outside}/keep", "w"):
            pass
        planted = f"{run}/vendor/bin"

        def populate():
            """write a crashed start's leftovers"""
            os.makedirs(f"{planted}/hw", exist_ok=True)
            for path in (f"{run}/adb_keys", f"{planted}/keep", f"{run}/vendor/lib"):
                with open(path, "w"):
                    pass
            if not os.path.lexists(f"{run}/link"):
                os.symlink(outside, f"{run}/link")

        def planted_mount_id(fd):
            """answer another mount for the planted directory"""
            mount = real_mount_id(fd)
            return mount + 1 if os.readlink(f"/proc/self/fd/{fd}") == planted else mount

        def failing_unlink(path, *args, **kwargs):
            """refuse to unlink the leftover key file"""
            if path in ("adb_keys", f"{run}/adb_keys"):
                raise PermissionError(13, "Permission denied", path)
            return real_unlink(path, *args, **kwargs)

        def swapped_stat(path, *args, **kwargs):
            """answer a directory for the symlink, as if swapped after the read"""
            st = real_stat(path, *args, **kwargs)
            if path == "link":
                return os.stat_result((stat_mod.S_IFDIR | 0o755,) + tuple(st)[1:])
            return st

        os.makedirs(run)
        os.symlink(outside, f"{tmp}/run-link")
        ino = os.lstat(run).st_ino
        mod.libc, mod.kmsg = FakeLibc([ROOT_ROW], ()), lambda m: None
        mod.core.read_mountinfo = lambda: [ROOT_ROW]
        mod._loops_backing = lambda img, losetup: []
        clear = mod.clear_run_root
        takes_use = "in_use" in inspect.signature(clear).parameters
        try:
            for label, root, mount_fn, stat_fn, unlink_fn, want, survivors in (
                    ("a crashed start's leftovers", run, real_mount_id, real_stat, real_unlink, None,
                     [f"{outside}/keep"]),
                    ("a mount planted under a child", run, planted_mount_id, real_stat, real_unlink,
                     f"mounted:{planted}", [f"{planted}/keep", f"{outside}/keep"]),
                    ("a leftover that will not go", run, real_mount_id, real_stat, failing_unlink, f"remove:{run}",
                     [f"{run}/adb_keys"]),
                    ("a RUN_ROOT symlink to a directory on its device", f"{tmp}/run-link", real_mount_id, real_stat,
                     real_unlink, f"not-a-directory:{tmp}/run-link", [f"{outside}/keep"]),
                    ("a directory swapped for a symlink after its read", run, real_mount_id, swapped_stat, real_unlink,
                     f"remove:{run}", [f"{outside}/keep"])):
                populate()
                mod.RUN_ROOT, mod.fd_mount_id = root, mount_fn
                os.stat, os.unlink = stat_fn, unlink_fn
                try:
                    got = clear(lambda args: (0, "", ""), in_use=lambda dev: None, wait_s=0) if takes_use \
                        else clear(lambda args: (0, "", ""))
                except Exception as e:
                    got = repr(e)
                finally:
                    os.stat, os.unlink = real_stat, real_unlink
                if got != want:
                    bad.append(f"the start's teardown of {label} returns {got!r}, not {want!r}")
                if not os.path.isdir(run) or os.lstat(run).st_ino != ino:
                    bad.append(f"the start's teardown of {label} removes RUN_ROOT's directory inode, not only its "
                               f"contents")
                    os.makedirs(run, exist_ok=True)
                    ino = os.lstat(run).st_ino
                gone = [p for p in survivors if not os.path.lexists(p)]
                if gone:
                    bad.append(f"the start's teardown of {label} removes through to {gone}")
                if want is None and os.listdir(run):
                    bad.append(f"the start's teardown of {label} leaves {sorted(os.listdir(run))}")
        finally:
            for n, v in saved.items():
                setattr(mod, n, v)
            mod.core.read_mountinfo = saved_read
    return bad


def loop_scan_cases(mod):
    """return the findings for _loops_backing over a fixture sysfs"""
    import socket
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        img = os.path.join(tmp, "absent-data.img")
        block = os.path.join(tmp, "block")

        def loop_dir(name):
            """return a fixture loop's loop directory"""
            d = os.path.join(block, name, "loop")
            os.makedirs(d)
            return os.path.join(d, "backing_file")

        os.symlink(os.path.join(tmp, "gone"), loop_dir("loop0"))
        with open(loop_dir("loop1"), "w") as f:
            f.write(img + "\n")
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(loop_dir("loop2"))
        try:
            got = mod._loops_backing(img, lambda args: (1, "", "unused"), sysblock=block)
        except Exception as e:
            got = repr(e)
        if got != ["/dev/loop1"]:
            bad.append(f"_loops_backing over a loop unbound mid-scan (ENOENT) and one answering ENXIO reads {got!r}, "
                       "not ['/dev/loop1']")
        os.makedirs(loop_dir("loop3"))
        try:
            got = mod._loops_backing(img, lambda args: (1, "", "unused"), sysblock=block)
        except Exception as e:
            got = repr(e)
        if got is not None:
            bad.append(f"_loops_backing over a backing_file that cannot be read reads {got!r}, not None")
        sock.close()
    return bad


def check(mod):
    """return every finding"""
    return unmount_cases(mod) + verb_cases(mod) + teardown_cases(mod) + empty_dir_cases(mod) + loop_scan_cases(mod)


def mutant(src, pairs, label):
    """return boot.py with each replacement"""
    for old, new in pairs:
        if src.count(old) != 1:
            raise SystemExit(f"FAIL selftest: the {label} mutant found {src.count(old)} anchors for {old!r}")
        src = src.replace(old, new)
    return src


def selftest():
    """flag each mutant and pass the real launcher"""
    src = open(LAUNCHER).read()
    cases = (
        ("unreadable table read as clear",
         [("        rows = core.read_mountinfo()\n", "        rows = core.read_mountinfo() or []\n")],
         "reads an unreadable mount table as clear"),
        ("held mounts found by target path",
         [("        reaching = set(core.mounts_reaching(real, rows))\n",
           '        reaching = {r[0] for r in rows if r[4].startswith(real.rstrip("/") + "/")}\n')],
         "reached through a bind, held as clear"),
        ("an unreadable enforce node read as permissive",
         [("            except OSError as e:\n                kmsg(f\"prepare-tree: {SELINUX_ENFORCE_NODE}: {e}\")\n"
           "                print(\"PREPARE_TREE_FAILED reason=enforce-unreadable\")\n                return 1\n",
           "            except OSError as e:\n                enforce = \"0\"\n")],
         "unreadable enforce node in host mode"),
        ("any selinuxfs stat error read as no selinuxfs",
         [("        except FileNotFoundError:\n            selinuxfs = False\n", "        except OSError:\n            selinuxfs = False\n")],
         "a refused stat of selinuxfs"),
        ("a staging root removal unchecked",
         [("    why = _empty_dir(RUN_ROOT)\n    if why:\n        print(f\"PREPARE_TREE_FAILED reason={why}\")\n        return 1\n    os.makedirs(RUN_ROOT",
           "    _empty_dir(RUN_ROOT)\n    os.makedirs(RUN_ROOT")],
         "an old staging root that will not go"),
        ("a removal error swallowed", [("        shutil.rmtree(path)\n", "        shutil.rmtree(path, ignore_errors=True)\n")],
         "will not go"),
        ("no read after the last unmount", [("    for unmounted in range(tries + 1):\n",
                                              "    for unmounted in range(tries):\n")],
         "eighth unmount as held"),
        ("nested mounts found by filesystem alone",
         [(" or row[4] == real or row[4].startswith(below)]\n", " or row[4] == real]\n")],
         "binds nested under a bind below the path as held"),
        ("the start's teardown going on past a held RUN_ROOT",
         [("    _run_root_why = clear_run_root()\n    if _run_root_why:\n        refuse_start_by_name(_run_root_why)\n",
           "    clear_run_root()\n")],
         "the start does not refuse"),
        ("a failed loop listing passed over",
         [("    if stale is None:\n        kmsg(", "    if stale is None and False:\n        kmsg(")],
         "an unlisted data.img loop returns"),
        ("a busy data.img loop detached anyway", [("        if use:\n", "        if use and False:\n")],
         "detaches a busy data.img loop"),
        ("a deferred detach taken as done", [("    if left:\n        kmsg(", "    if left and False:\n        kmsg(")],
         "whose detach is deferred returns None"),
        ("removal past a held staging root",
         [('    if not _unmount_tree(RUN_ROOT):\n        print(f"PREPARE_TREE_FAILED reason=unmount:{RUN_ROOT}")\n'
           '        return 1\n    why = _empty_dir(RUN_ROOT)\n    if why:\n        print(f"PREPARE_TREE_FAILED reason={why}")\n'
           '        return 1\n    os.makedirs(RUN_ROOT', "    _unmount_tree(RUN_ROOT)\n    _empty_dir(RUN_ROOT)\n    os.makedirs(RUN_ROOT")],
         "removes through the held mount"),
        ("the start removing RUN_ROOT itself",
         [("        return why\n    return _empty_dir(RUN_ROOT)\n", "        return why\n    return _remove_tree(RUN_ROOT)\n")],
         "removes RUN_ROOT's directory inode"),
        ("prepare-tree removing the staging root itself",
         [("        why = _empty_dir(RUN_ROOT)\n        if why:\n", "        why = _remove_tree(RUN_ROOT)\n        if why:\n")],
         "removes the staging root's directory"),
        ("a mount under RUN_ROOT removed through",
         [("                    if child_mount != mount_id:\n", "                    if False:\n")],
         "a mount planted under a child returns"),
        ("a symlink followed",
         [("DIR_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC\n",
           "DIR_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC\n")],
         "a RUN_ROOT symlink to a directory on its device returns"),
        ("a failed leftover removal passed over",
         [('            kmsg(f"removing {child}: {e}")\n            return f"remove:{top}"\n',
           '            kmsg(f"removing {child}: {e}")\n            continue\n')],
         "a leftover that will not go returns"),
        ("success over a held staging root",
         [('        if not _unmount_tree(f"{RUN_ROOT}/vendor"):\n', '        if not _unmount_tree(f"{RUN_ROOT}/vendor") and False:\n'),
          ('        if not _unmount_tree(RUN_ROOT):\n            print', '        if not _unmount_tree(RUN_ROOT) and False:\n            print')],
         "prints a success line"),
    )
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, (label, pairs, needle) in enumerate(cases):
            path = f"{tmp}/launcher_m{n}.py"
            with open(path, "w") as f:
                f.write(mutant(src, pairs, label))
            got = check(load(path, f"_prepare_unmount_m{n}"))
            if not any(needle in g for g in got):
                bad.append(f"the {label} mutant was not flagged: {got}")
    real = check(load(LAUNCHER, "_prepare_unmount_real"))
    if real:
        bad.append(f"the real launcher has findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check(load(LAUNCHER, "_prepare_unmount"))
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
