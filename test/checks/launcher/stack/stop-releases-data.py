#!/usr/bin/env python3
import argparse
import ast
import errno
import os
import pathlib
import shutil
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent
LAUNCHER = REPO / "src" / "androidd" / "boot.py"
RELEASE = "release_host_staging"
GUARD = "_cgroup_populated"


def _func(tree, name):
    """return the function definition with a name in a tree, or None"""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def _calls(node, name):
    """return the calls to a name within a node"""
    return [n for n in ast.walk(node)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == name]


def _is_empty_guard(test, guard=GUARD):
    """check for the guard call compared to False"""
    return (isinstance(test, ast.Compare) and len(test.ops) == 1
            and isinstance(test.ops[0], ast.Is)
            and isinstance(test.left, ast.Call) and isinstance(test.left.func, ast.Name)
            and test.left.func.id == guard
            and isinstance(test.comparators[0], ast.Constant)
            and test.comparators[0].value is False)


def _direct_release(stmts):
    """check stmts for a direct release_host_staging call"""
    return any(isinstance(st, ast.Expr) and isinstance(st.value, ast.Call)
               and isinstance(st.value.func, ast.Name) and st.value.func.id == RELEASE
               for st in stmts)


def _keeps_vbmeta(stmts):
    """return the lines of release calls with vbmeta_record"""
    return [c.lineno for st in stmts for c in _calls(st, RELEASE)
            if any(kw.arg in ("vbmeta_record", None) for kw in c.keywords)]


def _is_not_root_refusal(stmt):
    """check stmt for the not-root refusal"""
    if not (isinstance(stmt, ast.If) and not stmt.orelse and isinstance(stmt.test, ast.Compare)):
        return False
    t = stmt.test
    if not (len(t.ops) == 1 and isinstance(t.ops[0], ast.NotEq) and isinstance(t.left, ast.Call)
            and not t.left.args and isinstance(t.left.func, ast.Attribute) and t.left.func.attr == "geteuid"
            and isinstance(t.left.func.value, ast.Name) and t.left.func.value.id == "os"
            and isinstance(t.comparators[0], ast.Constant) and t.comparators[0].value == 0):
        return False
    rets = [n for n in ast.walk(stmt) if isinstance(n, ast.Return)]
    return (isinstance(stmt.body[-1], ast.Return) and bool(rets)
            and all(isinstance(r.value, ast.Constant) and r.value.value == 1 for r in rets))


def _cannot_raise(stmt):
    """check stmt for exception-free code"""
    if isinstance(stmt, (ast.FunctionDef, ast.Pass)):
        return True
    if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
        return True
    if isinstance(stmt, ast.Assign) and all(isinstance(t, ast.Name) for t in stmt.targets):
        return all(isinstance(n, (ast.Constant, ast.List, ast.Tuple, ast.Dict, ast.Set, ast.Load))
                   for n in ast.walk(stmt.value))
    return False


EXITS = {("os", "_exit"), ("os", "abort"), ("os", "execv"), ("os", "execve"), ("os", "execvp"),
         ("os", "execvpe"), ("os", "execl"), ("os", "execle"), ("os", "execlp"), ("os", "execlpe"),
         ("posix", "_exit"), ("signal", "raise_signal")}


def check_stop(src):
    """return findings for androidd_stop's release call"""
    tree = ast.parse(src)
    fn = _func(tree, "androidd_stop")
    if fn is None:
        return ["no-stop: androidd_stop() is not in this file"]
    guard_try = None
    anywhere = False
    for t in fn.body:
        if not isinstance(t, ast.Try) or not t.finalbody:
            continue
        for stmt in t.finalbody:
            if isinstance(stmt, ast.If) and _is_empty_guard(stmt.test) and _direct_release(stmt.body):
                guard_try = t
            if _calls(stmt, RELEASE):
                anywhere = True
    if guard_try is None:
        if anywhere:
            return [f"release-unguarded: androidd_stop()'s finally reaches {RELEASE}() only other than as "
                    f"a statement of `if {GUARD}() is False:`"]
        return [f"no-release-in-finally: androidd_stop() never calls {RELEASE}() from a finally"]
    nested = {id(n) for d in ast.walk(fn) if isinstance(d, ast.FunctionDef) and d is not fn
              for n in ast.walk(d)}
    inside = {id(n) for n in ast.walk(guard_try)}
    before = fn.body[:fn.body.index(guard_try)]
    refusal = {id(n) for st in before if _is_not_root_refusal(st) for n in ast.walk(st)}
    bad = [f"release-keeps-vbmeta: androidd_stop()'s release at line {ln} passes vbmeta_record"
           for ln in _keeps_vbmeta(guard_try.finalbody)]
    for node in ast.walk(fn):
        if isinstance(node, ast.Return) and id(node) not in nested | inside | refusal:
            bad.append(f"release-bypassed: androidd_stop() returns at line {node.lineno}, outside the try "
                       f"whose finally releases the host staging")
    for st in before:
        if _is_not_root_refusal(st) or _cannot_raise(st) or any(isinstance(n, ast.Return) for n in ast.walk(st)):
            continue
        bad.append(f"stop-runs-before-release: androidd_stop() runs line {st.lineno} "
                   f"({type(st).__name__}) before the try whose finally releases the host staging")
    for node in ast.walk(fn):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and isinstance(node.func.value, ast.Name) and (node.func.value.id, node.func.attr) in EXITS:
            bad.append(f"release-skipped-by-exit: androidd_stop() calls {node.func.value.id}.{node.func.attr}() "
                       f"at line {node.lineno}, outside the finally that releases the host staging")
    return bad


def check_release(src):
    """return findings for release_host_staging"""
    tree = ast.parse(src)
    fn = _func(tree, RELEASE)
    if fn is None:
        return [f"no-release: {RELEASE}() is not in this file"]
    names = {n.id for n in ast.walk(fn) if isinstance(n, ast.Name)}
    consts = {n.value for n in ast.walk(fn) if isinstance(n, ast.Constant)}
    bad = []
    for want in ("RUN_ROOT", "RHIZO_DATA_IMG", "RHIZO_VENDOR_DIR", "RHIZO_APEX_DIR"):
        if want not in names:
            bad.append(f"release-wrong-target: {RELEASE}() never falls back to {want}")
    if not _calls(fn, "umount2"):
        bad.append(f"release-hollow: {RELEASE}() never calls umount2")
    if "-d" not in consts:
        bad.append(f"release-hollow: {RELEASE}() never runs `losetup -d`")
    defaults = {n.id for d in fn.args.defaults + fn.args.kw_defaults if d is not None
                for n in ast.walk(d) if isinstance(n, ast.Name)}
    if not _calls(fn, "release_own_vbmeta_loop") or "VBMETA_LOOP_FILE" not in defaults:
        bad.append(f"release-keeps-vbmeta: {RELEASE}() does not release this instance's recorded "
                   f"vbmeta.img loop by default")
    return bad


def _is_data_release(stmt):
    """check stmt for the data release call"""
    if not (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call)
            and isinstance(stmt.value.func, ast.Name) and stmt.value.func.id == RELEASE):
        return False
    for kw in stmt.value.keywords:
        if kw.arg == "run_root" and isinstance(kw.value, ast.JoinedStr) and kw.value.values:
            tail = kw.value.values[-1]
            return isinstance(tail, ast.Constant) and str(tail.value).endswith("/data")
    return False


def check_policy_only(src):
    """return findings for the --policy-only pass"""
    tree = ast.parse(src)
    fn = _func(tree, "_policy_only_load")
    if fn is None:
        return ["no-policy-only: _policy_only_load() is not in this file"]
    at = [i for i, st in enumerate(fn.body) if _is_data_release(st)]
    setup = [i for i, st in enumerate(fn.body) if _calls(st, "privileged_setup")]
    load = [i for i, st in enumerate(fn.body)
            if any(isinstance(n, ast.Constant) and n.value == "/sys/fs/selinux/load" for n in ast.walk(st))]
    if not at:
        return [f"policy-only-keeps-data: _policy_only_load() never runs {RELEASE}(run_root=f\"{{RUN_ROOT}}/data\") "
                f"as a statement of its own body"]
    if not setup or not load or not (setup[0] < at[0] < load[0]):
        return [f"policy-only-misordered: _policy_only_load()'s /data release (statement {at[0]}) is not "
                f"between privileged_setup() (statement {setup[0] if setup else None}) and the policy load "
                f"(statement {load[0] if load else None})"]
    reach = [kw.value for kw in fn.body[at[0]].value.keywords if kw.arg == "reach"]
    if not (reach and isinstance(reach[0], (ast.Tuple, ast.List)) and not reach[0].elts):
        return ["policy-only-takes-vendor: _policy_only_load()'s /data release does not pass reach=()"]
    return []


def _is_policy_only_test(test, op):
    """detect a RHIZO_POLICY_ONLY comparison with 1"""
    return (isinstance(test, ast.Compare) and len(test.ops) == 1 and isinstance(test.ops[0], op)
            and isinstance(test.left, ast.Call) and isinstance(test.left.func, ast.Attribute)
            and test.left.func.attr == "get" and ast.unparse(test.left.func.value) == "os.environ"
            and len(test.left.args) == 1 and isinstance(test.left.args[0], ast.Constant)
            and test.left.args[0].value == "RHIZO_POLICY_ONLY"
            and isinstance(test.comparators[0], ast.Constant) and test.comparators[0].value == "1")


def _policy_only_guard_lines(src):
    """return the line numbers of the RHIZO_POLICY_ONLY tests"""
    fn = _func(ast.parse(src), "setup_loop_and_netfilter")
    return [] if fn is None else [n.test.lineno for n in ast.walk(fn)
                                  if isinstance(n, ast.If) and _is_policy_only_test(n.test, ast.Eq)]


def check_vbmeta_attach(src):
    """return findings for the vbmeta.img attach"""
    tree = ast.parse(src)
    fn = _func(tree, "setup_loop_and_netfilter")
    if fn is None:
        return ["no-vbmeta-attach: setup_loop_and_netfilter() is not in this file"]
    parent = {id(c): n for n in ast.walk(fn) for c in ast.iter_child_nodes(n)}
    attaches = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
                and isinstance(n.func, ast.Attribute) and n.func.attr == "loop_attach"
                and any(isinstance(c, ast.Name) and c.id == "vbmeta_src" for c in ast.walk(n))]
    if not attaches:
        return ["no-vbmeta-attach: setup_loop_and_netfilter() never calls core.loop_attach on vbmeta_src"]
    bad = []
    for call in attaches:
        node, guarded = call, False
        while id(node) in parent:
            up = parent[id(node)]
            if isinstance(up, ast.If):
                in_else = any(node is st for st in up.orelse)
                in_body = any(node is st for st in up.body)
                if (in_else and _is_policy_only_test(up.test, ast.Eq)) or \
                        (in_body and _is_policy_only_test(up.test, ast.NotEq)):
                    guarded = True
                    break
            node = up
        if not guarded:
            bad.append(f"policy-only-attaches-vbmeta: setup_loop_and_netfilter() attaches vbmeta.img at line "
                       f"{call.lineno} outside the else of `if os.environ.get(\"RHIZO_POLICY_ONLY\") == \"1\":`")
    rec = [n for n in tree.body if isinstance(n, ast.Assign)
           and any(isinstance(t, ast.Name) and t.id == "VBMETA_LOOP_FILE" for t in n.targets)]
    heads = [c for n in rec for c in ast.walk(n.value) if isinstance(c, ast.Constant) and isinstance(c.value, str)
             and not any(c is v for j in ast.walk(n.value) if isinstance(j, ast.JoinedStr) for v in j.values[1:])]
    if len(rec) != 1 or not heads or not all(h.value.startswith("/run/") for h in heads):
        bad.append("vbmeta-record-survives-boot: VBMETA_LOOP_FILE is not one module-level path under /run/")
    writes = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
              and n.func.attr == "write"]
    if not _calls(fn, "vbmeta_loop_identity") or any(
            not any(isinstance(c, ast.Name) and c.id == "ident" for c in ast.walk(w)) for w in writes):
        bad.append("vbmeta-record-unkeyed: setup_loop_and_netfilter()'s vbmeta.img loop record is not the "
                   "`<dev> <diskseq>` vbmeta_loop_identity() returns")
    return bad


UNITS = (REPO / "src" / "services" / "units" / "boot" / "androidd.service", REPO / "src" / "services" / "units" / "boot" / "androidd@.service",
         REPO / "debian" / "dropins" / "androidd-packaged-paths.conf",
         REPO / "debian" / "dropins" / "androidd-at-packaged-paths.conf")
STOP_POST = "launcher3.py release-staging"


def check_stop_post(src, units=UNITS):
    """return findings for the ExecStopPost release"""
    tree = ast.parse(src)
    bad = []
    fn = _func(tree, "release_staging_verb")
    if fn is None:
        bad.append("no-stop-post: release_staging_verb() is not in this file")
    elif not any(isinstance(st, ast.If) and _is_empty_guard(st.test, "stack_cgroup_populated")
                 and _direct_release(st.body) for st in fn.body):
        bad.append(f"stop-post-unguarded: release_staging_verb() does not run {RELEASE}() as a statement "
                   f"of `if stack_cgroup_populated() is False:`")
    else:
        bad += [f"release-keeps-vbmeta: release_staging_verb()'s release at line {ln} passes vbmeta_record"
                for ln in _keeps_vbmeta(fn.body)]
    main_ifs = [n for top in tree.body if isinstance(top, ast.If) for n in ast.walk(top)
                if isinstance(n, ast.If)]
    if not any("release-staging" in ast.dump(n.test) and _calls(n, "release_staging_verb") for n in main_ifs):
        bad.append("stop-post-undispatched: nothing in __main__ sends `release-staging` to release_staging_verb()")
    for unit in units:
        try:
            lines = [line.strip() for line in unit.read_text().splitlines()]
        except OSError as e:
            bad.append(f"stop-post-unit-missing: {unit.name}: {e}")
            continue
        posts = [line for line in lines if line.startswith("ExecStopPost=")]
        if not posts or not posts[-1].endswith(STOP_POST):
            bad.append(f"stop-post-unit-missing: {unit.name}'s last ExecStopPost= is not `{STOP_POST}` "
                       f"({posts[-1] if posts else 'none'})")
    return bad


def check_source(path=LAUNCHER):
    """return the findings for the launcher source"""
    src = path.read_text()
    return (check_stop(src) + check_release(src) + check_policy_only(src) + check_stop_post(src)
            + check_vbmeta_attach(src))


STOP_UNGUARDED = '''
def androidd_stop():
    try:
        return 0
    finally:
        release_host_staging()
        _reset_delegated_controllers()
'''

STOP_NONE = '''
def androidd_stop():
    try:
        return 0
    finally:
        _reset_delegated_controllers()
'''

STOP_WRONG_GUARD = '''
def androidd_stop():
    try:
        return 0
    finally:
        if _cgroup_populated() is not True:
            release_host_staging()
'''

STOP_ONLY_ON_SUCCESS = '''
def androidd_stop():
    try:
        if _cgroup_populated() is False:
            release_host_staging()
        return 0
    finally:
        _reset_delegated_controllers()
'''

STOP_FIXED = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    try:
        if not stack_up:
            return 0
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
        _reset_delegated_controllers()
'''

STOP_EARLY_RETURN = '''
def androidd_stop():
    if pid is None:
        return 0
    try:
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_EUID_OR = '''
def androidd_stop():
    if os.geteuid() != 0 or pid is None:
        return 0
    try:
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_EUID_RETURNS_0 = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 0
    try:
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_RAISES_BEFORE_TRY = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    pid = int(open(INIT_PID_FILE).read().strip())
    try:
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_OS_EXIT = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    try:
        if not stack_up:
            os._exit(0)
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_FIXED_DEFS = '''
def androidd_stop():
    """the stop"""
    if os.geteuid() != 0:
        kmsg("not root")
        return 1

    def _cgroup_populated():
        return stack_cgroup_populated()
    _outcome = []
    try:
        kmsg("stopping")
        return 0
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
'''

STOP_DEAD_GUARD = '''
def androidd_stop():
    try:
        return 0
    finally:
        if False:
            if _cgroup_populated() is False:
                release_host_staging()
'''

POLICY_ONLY_NONE = '''
def _policy_only_load(slog):
    privileged_setup()
    pc = f"{RUN_ROOT}/vendor/etc/selinux/precompiled_sepolicy"
'''

POLICY_ONLY_WHOLE = '''
def _policy_only_load(slog):
    privileged_setup()
    release_host_staging(run_root=f"{RUN_ROOT}", who="--policy-only")
'''

POLICY_ONLY_FIXED = '''
def _policy_only_load(slog):
    privileged_setup()
    release_host_staging(run_root=f"{RUN_ROOT}/data", reach=(), who="--policy-only")
    _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
'''

POLICY_ONLY_REACHES = '''
def _policy_only_load(slog):
    privileged_setup()
    release_host_staging(run_root=f"{RUN_ROOT}/data", who="--policy-only")
    _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
'''

STOP_POST_FIXED = '''
def release_staging_verb():
    if stack_cgroup_populated() is False:
        release_host_staging(who="androidd-stop-post")
    return 0

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "release-staging":
        sys.exit(release_staging_verb())
'''

STOP_POST_UNGUARDED = '''
def release_staging_verb():
    release_host_staging(who="androidd-stop-post")
    return 0

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "release-staging":
        sys.exit(release_staging_verb())
'''

STOP_POST_UNDISPATCHED = '''
def release_staging_verb():
    if stack_cgroup_populated() is False:
        release_host_staging(who="androidd-stop-post")
    return 0
'''

POLICY_ONLY_AFTER_LOAD = '''
def _policy_only_load(slog):
    privileged_setup()
    _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
    release_host_staging(run_root=f"{RUN_ROOT}/data", who="--policy-only")
'''

POLICY_ONLY_BEFORE_SETUP = '''
def _policy_only_load(slog):
    release_host_staging(run_root=f"{RUN_ROOT}/data", who="--policy-only")
    privileged_setup()
    _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
'''

POLICY_ONLY_NESTED = '''
def _policy_only_load(slog):
    privileged_setup()
    if False:
        release_host_staging(run_root=f"{RUN_ROOT}/data", who="--policy-only")
    _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
'''

RELEASE_HOLLOW = '''
def release_host_staging(run_root=None, data_img=None, umount2=None, losetup=None):
    run_root = run_root or RUN_ROOT
    data_img = data_img or RHIZO_DATA_IMG
    return losetup(["-j", data_img])
'''


PREPARED = "/var/lib/rhizo/prepared/k1/vendor"


class FakeHost:
    """fake mount table and loop driver"""

    def __init__(self, tmp, img, other_ns=(), busy=(), stuck=(), unreadable=(), extra=(), twin=False,
                 backing=None, sibling=False):
        """set up the fake mount table and loops"""
        self.path = os.path.join(tmp, "mountinfo")
        self.sys = os.path.join(tmp, "sys")
        self.img = img
        self.table = [
            (1, 0, "252:1", "/", "/"),
            (20, 1, "0:25", "/", "/run"),
            (30, 20, "0:40", "/", "/run/rhizo-wayland"),
            (40, 20, "0:50", "/", "/run/rhizo"),
            (41, 40, "7:0", "/", "/run/rhizo/data"),
            (42, 40, "252:1", "/var/lib/rhizo/vendor", "/run/rhizo/vendor"),
            (43, 42, "252:1", PREPARED + "/bin", "/run/rhizo/vendor/bin"),
            (44, 42, "252:1", PREPARED + "/lib", "/run/rhizo/vendor/lib"),
            (45, 42, "252:1", PREPARED + "/lib64", "/run/rhizo/vendor/lib64"),
            (46, 40, "252:1", "/var/lib/rhizo/apex_override", "/run/rhizo/apex_override"),
            (47, 46, "252:1", "/var/lib/rhizo/prepared/k1/apex", "/run/rhizo/apex_override"),
            (50, 20, "0:60", "/", "/run/rhizo-2"),
            (51, 50, "7:2", "/", "/run/rhizo-2/data"),
            (52, 50, "252:1", "/var/lib/rhizo/instances/2/vendor", "/run/rhizo-2/vendor"),
            (53, 52, "252:1", PREPARED + "/bin", "/run/rhizo-2/vendor/bin"),
        ] + list(extra)
        backing = backing or img
        self.loops = {"/dev/loop0": ("7:0", backing),
                      "/dev/loop1": ("7:1", os.path.join(tmp, "vbmeta.img")),
                      "/dev/loop2": ("7:2", os.path.join(tmp, "instances-2-data.img"))}
        if twin:
            self.loops["/dev/loop3"] = ("7:3", backing)
        if sibling:
            self.loops["/dev/loop4"] = ("7:4", os.path.join(tmp, "vbmeta.img"))
        self.diskseq = {dev: str(100 + int(dev[len("/dev/loop"):])) for dev in self.loops}
        self.other_ns = set(other_ns)
        self.busy = set(busy)
        self.stuck = set(stuck)
        self.unreadable = set(unreadable)
        self.held = set()
        self.autoclear = set()
        self.umount_calls = []
        self.write()

    def write(self):
        """write the mount table and the block device tree to disk"""
        with open(self.path, "w") as f:
            for mid, parent, mm, root, mp in self.table:
                f.write(f"{mid} {parent} {mm} {root} {mp} rw,relatime shared:{mid} - fs src rw\n")
        shutil.rmtree(self.sys, ignore_errors=True)
        os.makedirs(os.path.join(self.sys, "vda"))
        for dev, (mm, backing) in self.loops.items():
            d = os.path.join(self.sys, os.path.basename(dev))
            os.makedirs(os.path.join(d, "loop"))
            pathlib.Path(d, "dev").write_text(mm + "\n")
            if self.diskseq.get(dev) is not None:
                pathlib.Path(d, "diskseq").write_text(self.diskseq[dev] + "\n")
            gone = "" if os.path.exists(backing) else " (deleted)"
            if dev in self.unreadable:
                os.makedirs(os.path.join(d, "loop", "backing_file"))
            else:
                pathlib.Path(d, "loop", "backing_file").write_text(backing + gone + "\n")

    def _subtree(self, mid):
        """return the mount ids of a mount and everything mounted below it"""
        ids = {mid}
        grew = True
        while grew:
            grew = False
            for m, p, _mm, _root, _mp in self.table:
                if p in ids and m not in ids:
                    ids.add(m)
                    grew = True
        return ids

    def _in_use(self, mm):
        """return whether a device number is in use"""
        return (any(e[2] == mm for e in self.table) or mm in self.held or mm in self.other_ns)

    def umount2(self, path, flags):
        """unmount a path and return an errno"""
        self.umount_calls.append((path, flags))
        tops = [e for e in self.table if e[4] == path]
        if not tops:
            return errno.EINVAL
        mid = tops[-1][0]
        if path in self.stuck:
            return errno.EPERM
        children = [e for e in self.table if e[1] == mid]
        if flags == 0 and (children or mid in self.busy):
            return errno.EBUSY
        gone = self._subtree(mid) if flags else {mid}
        for m in gone:
            if m in self.busy:
                self.held.add(next(e[2] for e in self.table if e[0] == m))
        self.table = [e for e in self.table if e[0] not in gone]
        self._settle()
        self.write()
        return 0

    def _settle(self):
        """free the auto-clear loop devices that are no longer in use"""
        for dev in list(self.autoclear):
            if not self._in_use(self.loops[dev][0]):
                del self.loops[dev]
                self.autoclear.discard(dev)

    def losetup(self, args):
        """run a fake losetup for the find and detach arguments"""
        if args[0] == "-j":
            out = "".join(f"{d}: [64769]:12 ({b})\n" for d, (_mm, b) in sorted(self.loops.items())
                          if b == args[1])
            return 0, out, ""
        if args[0] == "-d":
            dev = args[1]
            if dev not in self.loops:
                return 1, "", f"losetup: {dev}: detach failed: No such device or address"
            if self._in_use(self.loops[dev][0]):
                self.autoclear.add(dev)
            else:
                del self.loops[dev]
            self.write()
            return 0, "", ""
        return 1, "", f"unexpected losetup {args}"

    def mounted(self, prefix):
        """return the mount points at or under a prefix"""
        return [e[4] for e in self.table if e[4] == prefix or e[4].startswith(prefix + "/")]


def _selftest():
    """run the release checks against a fake host"""
    import importlib.util
    failures = []

    def check(label, cond):
        """print a selftest line and record the label when the condition is false"""
        print(f"  selftest {'OK' if cond else 'FAILED'}: {label}")
        if not cond:
            failures.append(label)

    def names(findings):
        """return the finding codes before the first colon"""
        return {f.split(":", 1)[0] for f in findings}

    check("a stop with no release at all is caught as no-release-in-finally",
          names(check_stop(STOP_NONE)) == {"no-release-in-finally"})
    check("a release outside any cgroup-empty guard is caught as release-unguarded",
          names(check_stop(STOP_UNGUARDED)) == {"release-unguarded"})
    check("a guard that also admits the unreadable answer is caught",
          names(check_stop(STOP_WRONG_GUARD)) == {"release-unguarded"})
    check("a release on the success path only, not in the finally, is caught",
          names(check_stop(STOP_ONLY_ON_SUCCESS)) == {"no-release-in-finally"})
    check("a guarded release in the finally is accepted", check_stop(STOP_FIXED) == [])
    check("a return added before the try is caught as release-bypassed",
          names(check_stop(STOP_EARLY_RETURN)) == {"release-bypassed"})
    check("a guarded release nested where it never runs is caught",
          names(check_stop(STOP_DEAD_GUARD)) == {"release-unguarded"})
    check("a not-root refusal widened with `or pid is None` is caught as release-bypassed",
          names(check_stop(STOP_EUID_OR)) == {"release-bypassed"})
    check("a not-root refusal that returns 0 is caught as release-bypassed",
          names(check_stop(STOP_EUID_RETURNS_0)) == {"release-bypassed"})
    check("a statement before the try that can raise is caught as stop-runs-before-release",
          names(check_stop(STOP_RAISES_BEFORE_TRY)) == {"stop-runs-before-release"})
    check("an os._exit inside the try is caught as release-skipped-by-exit",
          names(check_stop(STOP_OS_EXIT)) == {"release-skipped-by-exit"})
    check("nested definitions and a literal before the try are accepted", check_stop(STOP_FIXED_DEFS) == [])
    hollow = check_release(RELEASE_HOLLOW)
    check("a release that unmounts nothing and detaches nothing is caught as release-hollow",
          sum(f.startswith("release-hollow") for f in hollow) == 2)
    check("a policy-only pass that leaves /data mounted is caught as policy-only-keeps-data",
          names(check_policy_only(POLICY_ONLY_NONE)) == {"policy-only-keeps-data"})
    check("a policy-only pass that releases the whole staging, vendor included, is caught",
          names(check_policy_only(POLICY_ONLY_WHOLE)) == {"policy-only-keeps-data"})
    check("a policy-only pass that releases /data alone is accepted",
          check_policy_only(POLICY_ONLY_FIXED) == [])
    check("a /data release after the policy load is caught as policy-only-misordered",
          names(check_policy_only(POLICY_ONLY_AFTER_LOAD)) == {"policy-only-misordered"})
    check("a /data release before privileged_setup() is caught as policy-only-misordered",
          names(check_policy_only(POLICY_ONLY_BEFORE_SETUP)) == {"policy-only-misordered"})
    check("a /data release nested where it never runs is caught as policy-only-keeps-data",
          names(check_policy_only(POLICY_ONLY_NESTED)) == {"policy-only-keeps-data"})
    check("a /data release on the default reach, vendor binds included, is caught as policy-only-takes-vendor",
          names(check_policy_only(POLICY_ONLY_REACHES)) == {"policy-only-takes-vendor"})
    unit_tmp = tempfile.mkdtemp()
    try:
        good = pathlib.Path(unit_tmp, "good.service")
        good.write_text("[Service]\nExecStop=/usr/bin/python3 /root/launcher3.py androidd-stop\n"
                        "ExecStopPost=/usr/bin/python3 /root/launcher3.py release-staging\n")
        reset = pathlib.Path(unit_tmp, "reset.conf")
        reset.write_text("[Service]\nExecStopPost=/usr/bin/python3 /root/launcher3.py release-staging\n"
                         "ExecStopPost=\n")
        bare = pathlib.Path(unit_tmp, "bare.service")
        bare.write_text("[Service]\nExecStop=/usr/bin/python3 /root/launcher3.py androidd-stop\n")
        check("a verb guarded, dispatched and named by every unit is accepted",
              check_stop_post(STOP_POST_FIXED, (good,)) == [])
        check("an unguarded ExecStopPost release is caught as stop-post-unguarded",
              names(check_stop_post(STOP_POST_UNGUARDED, (good,))) == {"stop-post-unguarded"})
        check("a verb nothing dispatches is caught as stop-post-undispatched",
              names(check_stop_post(STOP_POST_UNDISPATCHED, (good,))) == {"stop-post-undispatched"})
        check("a unit with no ExecStopPost, or one a drop-in resets to nothing, is caught",
              [f.split(":")[0] for f in check_stop_post(STOP_POST_FIXED, (bare, reset))]
              == ["stop-post-unit-missing", "stop-post-unit-missing"])
    finally:
        shutil.rmtree(unit_tmp, ignore_errors=True)
    check("a release that falls back to the wrong target is caught as release-wrong-target",
          names(check_release(RELEASE_HOLLOW.replace("RUN_ROOT", "RUN_DIR")))
          == {"release-hollow", "release-wrong-target", "release-keeps-vbmeta"})
    real_release = check_release(LAUNCHER.read_text())
    check("the real release names no finding, release-keeps-vbmeta included", real_release == [])
    no_default = LAUNCHER.read_text().replace("vbmeta_record=VBMETA_LOOP_FILE,", "vbmeta_record=None,", 1)
    check("a release whose vbmeta record defaults to None is caught as release-keeps-vbmeta",
          names(check_release(no_default)) == {"release-keeps-vbmeta"})
    no_call = LAUNCHER.read_text().replace("vbmeta_ok = vbmeta_record is None or release_own_vbmeta_loop(",
                                           "vbmeta_ok = vbmeta_record is None or bool(", 1)
    check("a release that never calls release_own_vbmeta_loop is caught as release-keeps-vbmeta",
          names(check_release(no_call)) == {"release-keeps-vbmeta"})

    real_src = LAUNCHER.read_text()
    stop_call = """        if _cgroup_populated() is False:
            release_host_staging()"""
    post_call = 'release_host_staging(who="androidd-stop-post")'
    check("the mutants below find their target in the real launcher",
          real_src.count(stop_call) == 1 and real_src.count(post_call) == 1)
    m2 = real_src.replace(post_call, 'release_host_staging(who="androidd-stop-post", vbmeta_record=None)', 1)
    check("M2: an ExecStopPost release passing vbmeta_record=None is caught as release-keeps-vbmeta",
          names(check_stop_post(m2)) == {"release-keeps-vbmeta"})
    m3 = real_src.replace(stop_call, stop_call.replace("staging()", "staging(vbmeta_record=None)"), 1)
    check("M3: an ExecStop release passing vbmeta_record=None is caught as release-keeps-vbmeta",
          names(check_stop(m3)) == {"release-keeps-vbmeta"})
    m3k = real_src.replace(stop_call, stop_call.replace("staging()", "staging(**_kw)"), 1)
    check("an ExecStop release passing ** is caught as release-keeps-vbmeta",
          names(check_stop(m3k)) == {"release-keeps-vbmeta"})
    check("the real vbmeta attach names no finding", check_vbmeta_attach(real_src) == [])
    guard = 'if os.environ.get("RHIZO_POLICY_ONLY") == "1":'
    guard_lines = _policy_only_guard_lines(real_src)
    src_lines = real_src.splitlines(keepends=True)
    check("the attach mutants below find their target",
          len(guard_lines) == 1 and src_lines[guard_lines[0] - 1].strip() == guard)

    def on_guard(old, new):
        """return the real launcher with the vbmeta attach guard edited"""
        if len(guard_lines) != 1:
            return real_src
        cut = list(src_lines)
        cut[guard_lines[0] - 1] = cut[guard_lines[0] - 1].replace(old, new, 1)
        return "".join(cut)
    unguarded = on_guard(guard, "if False:")
    check("an attach the --policy-only pass also runs is caught as policy-only-attaches-vbmeta",
          names(check_vbmeta_attach(unguarded)) == {"policy-only-attaches-vbmeta"})
    inverted = on_guard('== "1"', '!= "1"')
    check("an attach only the --policy-only pass runs is caught as policy-only-attaches-vbmeta",
          names(check_vbmeta_attach(inverted)) == {"policy-only-attaches-vbmeta"})
    wrong_var = on_guard("RHIZO_POLICY_ONLY", "RHIZO_NO_SANDBOX")
    check("a guard on some other variable is caught as policy-only-attaches-vbmeta",
          names(check_vbmeta_attach(wrong_var)) == {"policy-only-attaches-vbmeta"})
    for label, old_path in (("id 0", '("/run/rhizo-vbmeta-loop" if'),
                            ("id N", 'else f"/run/rhizo-vbmeta-loop-{')):
        check(f"the record-path mutant ({label}) finds its target", real_src.count(old_path) == 1)
        persisted = real_src.replace(old_path, old_path.replace("/run/rhizo-vbmeta-loop", "/root/.rhizo_vbmeta_loop"), 1)
        check(f"a record for {label} on /root is caught as vbmeta-record-survives-boot",
              names(check_vbmeta_attach(persisted)) == {"vbmeta-record-survives-boot"})
    check("the real record path passes vbmeta-record-survives-boot",
          "vbmeta-record-survives-boot" not in names(check_vbmeta_attach(real_src)))
    bare_dev = real_src.replace("f.write(ident)", "f.write(core.VBMETA_LOOP_DEV)", 1)
    check("a record of the bare /dev/loopN is caught as vbmeta-record-unkeyed",
          names(check_vbmeta_attach(bare_dev)) == {"vbmeta-record-unkeyed"})

    if str(LAUNCHER.parent) not in sys.path:
        sys.path.insert(0, str(LAUNCHER.parent))
    spec = importlib.util.spec_from_file_location("_l3_under_test", LAUNCHER)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:                                  # noqa: BLE001
        check(f"launcher3.py imports for the fixture half ({e})", False)
        return failures
    check("the real launcher3.py passes its own source checks", check_source() == [])
    check("the loaded launcher's record is on /run",
          mod.VBMETA_LOOP_FILE.startswith("/run/rhizo-vbmeta-loop"))

    tmp = tempfile.mkdtemp()
    try:
        img = os.path.join(tmp, "data.img")
        pathlib.Path(img).write_bytes(b"\0" * 4096)

        reach0 = ("/var/lib/rhizo/vendor", "/var/lib/rhizo/apex_override")

        vbmeta = os.path.join(tmp, "vbmeta.img")
        record = os.path.join(tmp, "vbmeta-loop-record")

        def run(host, **kw):
            """release the host staging against a fake host with default arguments"""
            logs = []
            kw.setdefault("losetup", host.losetup)
            kw.setdefault("reach", reach0)
            kw.setdefault("domain", "u:r:rhizo_host:s0")
            kw.setdefault("data_img", img)
            kw.setdefault("vbmeta_record", record)
            kw.setdefault("vbmeta_img", vbmeta)
            ok = mod.release_host_staging(run_root="/run/rhizo", log=logs.append,
                                          table=host.path, umount2=host.umount2,
                                          sysblock=host.sys, wait_s=0, **kw)
            return ok, " | ".join(logs)

        host = FakeHost(tmp, img)
        check("the fixture starts with the leak itself: /run/rhizo/data mounted and loop0 on data.img",
              "/run/rhizo/data" in host.mounted("/run/rhizo") and "/dev/loop0" in host.loops)
        ok, log = run(host)
        check("the host's real staging shape is released", ok is True)
        check("nothing is left at or under /run/rhizo", host.mounted("/run/rhizo") == [])
        check("with nothing busy, nothing is detached lazily",
              all(fl == 0 for _p, fl in host.umount_calls) and "detached lazily" not in log)
        check("the stacked apex_override bind needed, and got, two unmounts",
              sum(1 for p, fl in host.umount_calls if p == "/run/rhizo/apex_override" and fl == 0) == 2)
        check("data.img's loop is detached", "/dev/loop0" not in host.loops)
        check("a sibling instance's staging, its binds of the shared prepared tree included, and its loop "
              "are untouched",
              host.mounted("/run/rhizo-2") == ["/run/rhizo-2", "/run/rhizo-2/data", "/run/rhizo-2/vendor",
                                               "/run/rhizo-2/vendor/bin"]
              and "/dev/loop2" in host.loops)
        check("/run/rhizo-wayland, which shares the prefix string, is untouched",
              host.mounted("/run/rhizo-wayland") == ["/run/rhizo-wayland"])
        check("vbmeta.img's loop is not this function's to take", "/dev/loop1" in host.loops)
        check("the release says so", "host staging released" in log and "loop /dev/loop0 detached" in log)

        host = FakeHost(tmp, img)
        check("the record names the attach: `<dev> <diskseq>`",
              mod.vbmeta_loop_identity("/dev/loop1", sysblock=host.sys) == "/dev/loop1 101"
              and mod.vbmeta_loop_identity("/dev/loop9", sysblock=host.sys) is None)
        for gone in (False, True):
            if not gone:
                pathlib.Path(vbmeta).write_bytes(b"\0" * 4096)
            for mine, theirs in (("/dev/loop1", "/dev/loop4"), ("/dev/loop4", "/dev/loop1")):
                host = FakeHost(tmp, img, sibling=True)
                pathlib.Path(record).write_text(mod.vbmeta_loop_identity(mine, sysblock=host.sys) + "\n")
                ok, log = run(host)
                check("the loop this instance recorded on %svbmeta.img (%s) is detached, its record dropped, "
                      "and the sibling's %s on the same file survives" % ("a deleted " if gone else "", mine, theirs),
                      ok is True and mine not in host.loops and theirs in host.loops
                      and not os.path.exists(record) and f"vbmeta.img loop {mine} detached" in log)
            if not gone:
                os.unlink(vbmeta)
        pathlib.Path(record).write_text("/dev/loop2 102\n")
        host = FakeHost(tmp, img, sibling=True)
        ok, log = run(host)
        check("a recorded loop that no longer backs vbmeta.img is left alone and its record dropped",
              ok is True and "/dev/loop2" in host.loops and "/dev/loop1" in host.loops
              and "/dev/loop4" in host.loops and not os.path.exists(record))
        pathlib.Path(record).write_text("/dev/loop1 99\n")
        host = FakeHost(tmp, img, sibling=True)
        ok, log = run(host)
        check("a recorded slot reused on vbmeta.img under another diskseq is not ours: left alone, "
              "record dropped", ok is True and "/dev/loop1" in host.loops and "/dev/loop4" in host.loops
              and not os.path.exists(record) and "not the recorded 99" in log)
        for legacy in ("/dev/loop1\n", "", "/dev/loop1 x\n"):
            pathlib.Path(record).write_text(legacy)
            host = FakeHost(tmp, img)
            ok, log = run(host)
            check(f"a record with no diskseq ({legacy.strip() or '<empty>'}) detaches nothing and is dropped",
                  ok is True and "/dev/loop1" in host.loops and not os.path.exists(record))
        pathlib.Path(record).write_text("/dev/loop1 101\n")
        host = FakeHost(tmp, img, other_ns={"7:1"})
        ok, log = run(host)
        check("a recorded vbmeta loop something still holds fails the release, naming it, and the record is dropped",
              ok is False and "vbmeta.img is still attached at /dev/loop1" in log and not os.path.exists(record))
        pathlib.Path(record).write_text("/dev/loop1 101\n")
        host = FakeHost(tmp, img)
        ok, log = run(host, losetup=lambda a: (1, "", "busy") if a[0] == "-d" and a[1] == "/dev/loop1"
                      else host.losetup(a))
        check("a losetup -d that fails keeps the record and fails the release",
              ok is False and "/dev/loop1" in host.loops and os.path.exists(record) and "failed (busy)" in log)
        host = FakeHost(tmp, img)
        ok, log = run(host, vbmeta_record=None)
        check("vbmeta_record=None leaves even a recorded vbmeta loop attached", ok is True
              and "/dev/loop1" in host.loops and os.path.exists(record))
        os.unlink(record)

        ok, log = run(host)
        check("a second stop finds nothing and still reports released", ok is True
              and "0 mount(s)" in log)

        host = FakeHost(tmp, img)
        losetup_calls = []
        ok, log = run(host, domain="u:r:kernel:s0",
                      losetup=lambda a: losetup_calls.append(a) or host.losetup(a))
        check("a kernel-domain stop under a loaded policy runs no losetup, unmounts nothing and "
              "names ExecStopPost as the release",
              ok is False and losetup_calls == [] and host.umount_calls == []
              and "/run/rhizo/data" in host.mounted("/run/rhizo") and "/dev/loop0" in host.loops
              and "left to ExecStopPost release-staging" in log)
        host = FakeHost(tmp, img)
        ok, log = run(host, domain="kernel")
        check("the bare pre-load `kernel` SID, the --policy-only pass's, still releases",
              ok is True and "/dev/loop0" not in host.loops and host.mounted("/run/rhizo") == [])

        host = FakeHost(tmp, img)
        logs = []
        ok = mod.release_host_staging(run_root="/run/rhizo/data", data_img=img, log=logs.append,
                                      table=host.path, umount2=host.umount2, losetup=host.losetup,
                                      sysblock=host.sys, wait_s=0, who="--policy-only", reach=(),
                                      vbmeta_record=None)
        check("the policy-only release takes /data and its loop and leaves the vendor staging up",
              ok is True and host.mounted("/run/rhizo/data") == [] and "/dev/loop0" not in host.loops
              and "/run/rhizo/vendor/bin" in host.mounted("/run/rhizo")
              and "/run/rhizo/apex_override" in host.mounted("/run/rhizo"))
        check("the policy-only release speaks as itself", any(m.startswith("--policy-only: ") for m in logs))
        host = FakeHost(tmp, img)
        mod.release_host_staging(run_root="/run/rhizo/data", data_img=img, log=lambda *_: None,
                                 table=host.path, umount2=host.umount2, losetup=host.losetup,
                                 sysblock=host.sys, wait_s=0, reach=reach0, vbmeta_record=None)
        check("without reach=() the same release would take the vendor staging the policy load reads",
              "/run/rhizo/vendor" not in host.mounted("/run/rhizo"))

        leftover = ((60, 20, "252:1", "/var/lib/rhizo/vendor", "/run/rhizo-leftover/vendor"),
                 (61, 60, "252:1", PREPARED + "/lib", "/run/rhizo-leftover/vendor/lib"))
        host = FakeHost(tmp, img, extra=leftover)
        ok, log = run(host)
        check("a leftover bind of the vendor tree outside RUN_ROOT, and what sits on it, is released", ok is True
              and host.mounted("/run/rhizo-leftover") == [])
        host = FakeHost(tmp, img, extra=leftover)
        run(host, reach=())
        check("a path-prefix release alone leaves the leftover vendor bind mounted",
              host.mounted("/run/rhizo-leftover") == ["/run/rhizo-leftover/vendor", "/run/rhizo-leftover/vendor/lib"])
        check("instance 2's binds of the shared prepared tree survive a reach over instance 0's own trees",
              host.mounted("/run/rhizo-2") == ["/run/rhizo-2", "/run/rhizo-2/data", "/run/rhizo-2/vendor",
                                               "/run/rhizo-2/vendor/bin"])
        host = FakeHost(tmp, img, extra=leftover + ((62, 61, "0:99", "/", "/run/rhizo-leftover/vendor/lib/x"),))
        ok, log = run(host)
        check("a staging bind carrying a mount that is not staging is refused, never taken lazily with it",
              ok is False and "not this instance's staging" in log
              and host.mounted("/run/rhizo-leftover") == ["/run/rhizo-leftover/vendor", "/run/rhizo-leftover/vendor/lib",
                                                       "/run/rhizo-leftover/vendor/lib/x"]
              and all(fl == 0 for _p, fl in host.umount_calls))

        host = FakeHost(tmp, img, busy={41})
        ok, log = run(host)
        check("a busy /data mount is not reported released", ok is False)
        check("it is detached lazily and named", "detached lazily" in log and "/run/rhizo/data" in log)
        check("only the busy mount goes lazily; its parent still unmounts for real",
              [p for p, fl in host.umount_calls if fl] == ["/run/rhizo/data"]
              and ("/run/rhizo", 0) in host.umount_calls and host.mounted("/run/rhizo") == [])
        check("its loop stays attached, and that is named", "/dev/loop0" in host.loops
              and "still attached at /dev/loop0" in log)

        host = FakeHost(tmp, img, other_ns={"7:0"})
        ok, log = run(host)
        check("an ext4 another namespace still mounts is not reported released", ok is False
              and "still attached at /dev/loop0" in log)

        host = FakeHost(tmp, img, stuck={"/run/rhizo/vendor/lib"})
        ok, log = run(host)
        check("a mount that will not go at all fails the release, naming it", ok is False
              and "NOT released" in log and "/run/rhizo/vendor/lib" in log)

        host = FakeHost(tmp, img)
        logs = []
        ok = mod.release_host_staging(run_root="/run/rhizo", data_img=img, log=logs.append,
                                      table=os.path.join(tmp, "absent"), umount2=host.umount2,
                                      losetup=host.losetup, sysblock=host.sys, wait_s=0, vbmeta_record=record)
        check("an unreadable mount table is a failure, not an empty one", ok is False
              and host.umount_calls == [] and any("could not be read" in m for m in logs))

        host = FakeHost(tmp, img)
        logs = []
        ok = mod.release_host_staging(run_root="/run/rhizo", data_img=img, log=logs.append,
                                      table=host.path, umount2=host.umount2,
                                      losetup=lambda a: (1, "", "losetup: cannot") if a[0] == "-j"
                                      else host.losetup(a), sysblock=host.sys, wait_s=0,
                                      vbmeta_record=record)
        check("losetup unable to answer is a failure, named", ok is False
              and any("could not tell which loop devices back" in m for m in logs))

        os.unlink(img)
        host = FakeHost(tmp, img)
        ok, log = run(host)
        check("a loop on a deleted data.img is found through sysfs and detached", ok is True
              and "/dev/loop0" not in host.loops and "loop /dev/loop0 detached" in log)
        pathlib.Path(img).write_bytes(b"\0" * 4096)
        host = FakeHost(tmp, img)
        ok, log = run(host, losetup=lambda a: (0, "", "") if a[0] == "-j" else host.losetup(a))
        check("a loop losetup -j stays silent about is found through sysfs and detached", ok is True
              and "/dev/loop0" not in host.loops)
        host = FakeHost(tmp, img, other_ns={"7:0"})
        ok, log = run(host, losetup=lambda a: (0, "", "") if a[0] == "-j" else host.losetup(a))
        check("a still-held loop losetup -j stays silent about is not reported released", ok is False
              and "still attached at /dev/loop0" in log)
        host = FakeHost(tmp, img, unreadable={"/dev/loop1"})
        ok, log = run(host)
        check("a backing_file that cannot be read is a failure, not a loop that is not there", ok is False
              and "could not tell which loop devices back" in log)

        host = FakeHost(tmp, img, twin=True)
        ok, log = run(host)
        check("both loops on data.img are detached", ok is True and "/dev/loop0" not in host.loops
              and "/dev/loop3" not in host.loops and "loop /dev/loop0 /dev/loop3 detached" in log)
        os.unlink(img)
        host = FakeHost(tmp, img, twin=True)
        ok, log = run(host)
        check("both loops on a deleted data.img are found through sysfs and detached", ok is True
              and "/dev/loop0" not in host.loops and "/dev/loop3" not in host.loops)
        pathlib.Path(img).write_bytes(b"\0" * 4096)
        host = FakeHost(tmp, img, twin=True, other_ns={"7:0"})
        ok, log = run(host)
        check("one of two loops still held fails the release, naming it, and the other is still detached",
              ok is False and "still attached at /dev/loop0 after" in log and "/dev/loop3" not in host.loops)

        os.symlink(tmp, os.path.join(tmp, "alias"))
        alias = os.path.join(tmp, "alias", "data.img")
        for gone in (False, True):
            if gone:
                os.unlink(img)
            host = FakeHost(tmp, img)
            ok, log = run(host, data_img=alias)
            check("a loop on %sdata.img named through a symlinked directory is found and detached"
                  % ("a deleted " if gone else ""), ok is True and "/dev/loop0" not in host.loops)
        pathlib.Path(img).write_bytes(b"\0" * 4096)

        def run_stop(host, populated=False, first_log_raises=False, verb="androidd_stop"):
            """run the stop function against the fake host"""
            logs, released = [], []
            real_release = mod.release_host_staging

            def release(**kw):
                """record the release and run it against the fake host"""
                released.append(True)
                return real_release(**{**dict(run_root="/run/rhizo", data_img=img, log=logs.append,
                                              table=host.path, umount2=host.umount2, losetup=host.losetup,
                                              sysblock=host.sys, wait_s=0, reach=reach0, vbmeta_record=record,
                                              vbmeta_img=vbmeta, domain="u:r:rhizo_host:s0"), **kw})

            def kmsg(msg):
                """append a kernel log message, optionally failing on the first one"""
                if first_log_raises and not logs:
                    logs.append("<raised>")
                    raise OSError(errno.EIO, "the log write failed")
                logs.append(msg)

            class Root:
                """fake os module for euid 0"""
                def __getattr__(self, name):
                    """return the attribute from the os module"""
                    return getattr(os, name)

                @staticmethod
                def geteuid():
                    """return root as the effective user"""
                    return 0
            patch = {"os": Root(), "kmsg": kmsg, "release_host_staging": release,
                     "stop_companion_units": lambda *_a, **_k: True,
                     "stop_owns_instance": lambda *_a, **_k: True,
                     "stack_cgroup_populated": lambda: populated, "stack_cgroup": lambda: tmp,
                     "clear_delegated_controllers": lambda *_a, **_k: True,
                     "INIT_PID_FILE": os.path.join(tmp, "no-init.pid"),
                     "G_PID_FILE": os.path.join(tmp, "no-g.pid"),
                     "RHIZO_RESIDENT_G": False, "RHIZO_RESIDENT_DISPATCH": False}
            saved = {k: getattr(mod, k) for k in patch}
            try:
                for k, v in patch.items():
                    setattr(mod, k, v)
                try:
                    rc = getattr(mod, verb)()
                except OSError as e:
                    rc = e
            finally:
                for k, v in saved.items():
                    setattr(mod, k, v)
            return rc, released, " | ".join(logs)

        host = FakeHost(tmp, img, sibling=True)
        pathlib.Path(record).write_text("/dev/loop1 101\n")
        rc, released, log = run_stop(host)
        check("the real androidd_stop() runs the release on its no-stack return and the staging comes down, "
              "this instance's vbmeta loop with it and the sibling's left",
              rc == 0 and released == [True] and host.mounted("/run/rhizo") == []
              and "/dev/loop0" not in host.loops and "/dev/loop1" not in host.loops
              and "/dev/loop4" in host.loops and not os.path.exists(record))
        host = FakeHost(tmp, img, sibling=True)
        pathlib.Path(record).write_text("/dev/loop1 101\n")
        rc, released, log = run_stop(host, verb="release_staging_verb")
        check("the real release_staging_verb() releases the staging and this instance's vbmeta loop, "
              "and leaves the sibling's",
              rc == 0 and released == [True] and host.mounted("/run/rhizo") == []
              and "/dev/loop0" not in host.loops and "/dev/loop1" not in host.loops
              and "/dev/loop4" in host.loops and not os.path.exists(record))
        host = FakeHost(tmp, img)
        pathlib.Path(record).write_text("/dev/loop1 101\n")
        rc, released, log = run_stop(host, verb="release_staging_verb", populated=True)
        check("the real release_staging_verb() keeps a populated stack's staging and vbmeta loop and fails the stop",
              rc == 1 and released == [] and "/dev/loop1" in host.loops and os.path.exists(record))
        os.unlink(record)
        host = FakeHost(tmp, img)
        rc, released, log = run_stop(host, first_log_raises=True)
        check("an exception at the real stop's first step still runs the release in its finally",
              isinstance(rc, OSError) and released == [True] and host.mounted("/run/rhizo") == []
              and "/dev/loop0" not in host.loops)
        host = FakeHost(tmp, img)
        rc, released, log = run_stop(host, populated=True)
        check("the real stop keeps the staging of a stack its cgroup still reads populated",
              released == [] and "/run/rhizo/data" in host.mounted("/run/rhizo") and "/dev/loop0" in host.loops
              and "not confirmed empty" in log)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return failures


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        print("check-stop-releases-data --selftest")
        failures = _selftest()
        if failures:
            print(f"check-stop-releases-data --selftest: FAILED ({len(failures)})")
            return 1
        print("check-stop-releases-data --selftest: PASSED")
        return 0
    bad = check_source()
    for b in bad:
        print(f"check-stop-releases-data: {b}")
    if bad:
        print(f"check-stop-releases-data: FAILED ({len(bad)})")
        return 1
    print("check-stop-releases-data: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
