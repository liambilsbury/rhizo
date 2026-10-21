#!/usr/bin/env python3
import ast
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
CIL = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")
SELINUX_PY = os.path.join(REPO, "src", "androidd", "sandbox", "selinux_labels.py")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
ACCESS_TSV = os.path.join(REPO, "test", "checks", "policy", "access", "hotplug-access.tsv")

LOADABLE_ATTRS = ("system_file_type", "vendor_file_type", "system_dlkm_file_type")
MODPROBE_PATHS = ("/usr/sbin/modprobe", "/sbin/modprobe")
MODULE_REQUESTERS = {"kernel", "rhizo_host"}
KMOD_DPKG_TT = '(typetransition rhizo_host unlabeled file "kmod.dpkg-new" rhizo_host_exec)'
HELPER_TT = "(typetransition kernel rhizo_host_exec process rhizo_host)"
KDEVTMPFS_MKNOD = "(allow kernel self (capability (mknod)))"
PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)

PRIVATE_USERS_SET = (
    ("user_namespace", "create",
     "exec-invoke.c:2251 unshare(CLONE_NEWUSER) in the unit's pre-exec child"),
    ("cap_userns", "sys_admin",
     "exec-invoke.c:2218,2231 (sd-userns) writes gid_map and uid_map; "
     "kernel/user_namespace.c:977 map_write asks CAP_SYS_ADMIN in the new namespace"),
    ("capability", "setuid",
     "exec-invoke.c:2140 a User= unit's two-line uid_map; "
     "kernel/user_namespace.c:1198 new_idmap_permitted asks CAP_SETUID in the parent"),
    ("capability", "setgid",
     "exec-invoke.c:2154 a Group= unit's two-line gid_map; "
     "kernel/user_namespace.c:1198 new_idmap_permitted asks CAP_SETGID in the parent"),
    ("cap_userns", "setpcap",
     "exec-invoke.c:4872 capability_bounding_set_drop; capability-util.c:226 PR_CAPBSET_DROP; "
     "security/commoncap.c:1239 asks CAP_SETPCAP in the unit's own namespace"),
    ("cap_userns", "setuid",
     "exec-invoke.c:1082 enforce_user's setresuid inside the namespace; "
     "kernel/sys.c:705 ns_capable_setid(CAP_SETUID)"),
    ("cap_userns", "sys_ptrace",
     "PID 1 and journald reading the unit's /proc; "
     "security/commoncap.c:151 cap_ptrace_access_check in the unit's namespace"),
    ("process", "setcap",
     "capability-util.c:211 capability_gain_cap_setpcap's cap_set_proc before the drop"),
    ("file", "open",
     "exec-invoke.c:2199,2218,2231 (sd-userns) opens /proc/<pid>/{setgroups,gid_map,uid_map}, "
     "labeled with the unit's own rhizo_host"),
    ("file", "write", "exec-invoke.c:2209,2224,2237 the three writes to those files"),
)
PRIVATE_USERS_BARRED = (
    ("capability", "setfcap",
     "exec-invoke.c:2231 (sd-userns) writes a uid_map that maps uid 0; "
     "kernel/user_namespace.c:916 verify_root_map asks CAP_SETFCAP in the parent namespace",
     "system/sepolicy/private/domain.te:1552 (neverallow * self (capability (setfcap)))"),
)
PRIVATE_USERS_DROPIN = "debian/dropins/private-users-off.conf"
PRIVATE_USERS_DEST = "/usr/lib/systemd/system/service.d/50-rhizo-private-users.conf"
PRIVATE_USERS_INSTALL = ("install -D -m 0644 debian/dropins/private-users-off.conf \\\n"
                         "\t                   $(PAYLOAD)/host-mode" + PRIVATE_USERS_DEST)
DROPIN_WANTS = ((PRIVATE_USERS_DROPIN, [("Service", "PrivateUsers", "no")], "private-users-dropin"),)
PRIVATE_USERS_NAMERS = ("test/system/cycle/claims-install.sh",)
_SELF_ALLOW_RE = re.compile(
    r"\(allow\s+rhizo_host\s+(?:self|rhizo_host)\s+\((\w+)\s+\(([^()]*)\)\)\)")


def _sexprs(text, head):
    """return each one-line CIL statement for head"""
    out = []
    for line in text.splitlines():
        line = line.split(";", 1)[0].strip()
        if line.startswith("(" + head + " ") or line.startswith("(" + head + "("):
            out.append(line.replace("(", " ( ").replace(")", " ) ").split())
    return out


def _attr_members(text, attr):
    """return the types added to attr"""
    members = set()
    for toks in _sexprs(text, "typeattributeset"):
        if len(toks) > 3 and toks[2] == attr and toks[3] == "(":
            members.update(t for t in toks[4:] if t not in ("(", ")"))
    return members


def _statements(text):
    """return the normalized CIL statements"""
    return {" ".join(line.split(";", 1)[0].split()) for line in text.splitlines()}


def check_private_users(text):
    """check rhizo_host's self permissions in the CIL"""
    body = " ".join(line.split(";", 1)[0] for line in text.splitlines())
    held = set()
    for cls, perms in _SELF_ALLOW_RE.findall(body):
        held.update((cls, p) for p in perms.split())
    bad = ["no (allow rhizo_host self (%s (%s))): %s"
           % (cls, perm, site) for cls, perm, site in PRIVATE_USERS_SET
           if (cls, perm) not in held]
    bad += ["(allow rhizo_host self (%s (%s))) is granted, which %s forbids" % (cls, perm, rule) for cls, perm, _, rule in PRIVATE_USERS_BARRED
            if (cls, perm) in held]
    return bad


def check_private_users_rows(rows):
    """check hotplug-access.tsv rows for PrivateUsers= permissions"""
    listed = set()
    for r in rows:
        if r["domain"] == "rhizo_host" and r["label"] == "rhizo_host":
            listed.update((r["class"], p) for p in r["perms"].split())
    want = [(cls, perm, site) for cls, perm, site in PRIVATE_USERS_SET]
    want += [(cls, "!" + perm, site) for cls, perm, site, _ in PRIVATE_USERS_BARRED]
    return ["hotplug-access.tsv has no rhizo_host row for %s { %s } (%s)" % (cls, perm, site) for cls, perm, site in want
            if (cls, perm) not in listed]


def unit_directives(text):
    """return the directives of a unit file"""
    out, sect = [], None
    for line in text.splitlines():
        t = line.strip()
        if not t or t[0] in "#;":
            continue
        m = re.fullmatch(r"\[(.+)\]", t)
        if m:
            sect = m.group(1)
            continue
        key, sep, value = t.partition("=")
        out.append((sect, key.strip(), value.strip() if sep else None))
    return out


def check_private_users_dropin(read):
    """check the PrivateUsers= drop-in and its references"""
    bad = []
    for rel, want, name in DROPIN_WANTS:
        try:
            text = read(rel)
        except FileNotFoundError:
            bad.append("%s: %s is missing" % (name, rel))
            continue
        got = unit_directives(text)
        if got != want:
            bad.append("%s: %s holds %r, want exactly %r" % (name, rel, got, want))
        if "domain.te:1552" not in text:
            bad.append("%s: %s does not name the neverallow it answers (domain.te:1552)" % (name, rel))
    if PRIVATE_USERS_INSTALL not in read("debian/rules"):
        bad.append("debian/rules does not install %s as %s, so the package ships no opt-out"
                   % (PRIVATE_USERS_DROPIN, PRIVATE_USERS_DEST))
    for rel in PRIVATE_USERS_NAMERS:
        if PRIVATE_USERS_DEST not in read(rel):
            bad.append("%s never names %s, the path the package installs" % (rel, PRIVATE_USERS_DEST))
    return bad


def _read_repo(rel):
    """return the text of a file in the repo"""
    with open(os.path.join(REPO, rel)) as f:
        return f.read()


def check_cil(text):
    """check module and device rules in the CIL"""
    bad = []
    stmts = _statements(text)
    declared = {t[2] for t in _sexprs(text, "type") if len(t) > 2}
    trans = {}
    for toks in _sexprs(text, "typetransition"):
        if len(toks) == 7 and toks[2:4] == ["kernel", "device"]:
            trans[toks[4]] = toks[5]
    dev_types = _attr_members(text, "dev_type")
    for cls in ("chr_file", "blk_file"):
        target = trans.get(cls)
        if target is None:
            bad.append("no (typetransition kernel device %s ...): a node kdevtmpfs makes "
                       "after the load is `device`, and a %s one is refused outright by "
                       "coredomain.te:142" % (cls, cls))
            continue
        if target == "device":
            bad.append("(typetransition kernel device %s device) names `device` itself" % cls)
            continue
        if target not in declared:
            bad.append("typetransition target %s for %s is not declared here" % (target, cls))
        if target not in dev_types:
            bad.append("%s is not in dev_type" % target)
        if "(allow %s device (filesystem (associate)))" % target not in stmts:
            bad.append("no (allow %s device (filesystem (associate)))" % target)
    if KDEVTMPFS_MKNOD not in stmts:
        bad.append("no %s: kdevtmpfs makes no node" % KDEVTMPFS_MKNOD)
    if len(set(trans.get(c) for c in ("chr_file", "blk_file"))) != 1:
        bad.append("chr and blk nodes transition to different types: %s" % trans)
    mod_types = sorted(t for t in declared
                       if any(t in _attr_members(text, a) for a in LOADABLE_ATTRS)
                       and "(allow rhizo_host %s (system (module_load)))" % t in stmts)
    mod_type = mod_types[0] if len(mod_types) == 1 else None
    if not mod_types:
        bad.append("no declared type both joins one of %s and carries "
                   "(allow rhizo_host <type> (system (module_load)))" % (LOADABLE_ATTRS,))
    elif len(mod_types) > 1:
        bad.append("%d loadable module types (%s); label_host_modules stamps one"
                   % (len(mod_types), ", ".join(mod_types)))
    for src in sorted(MODULE_REQUESTERS):
        if "(allow %s kernel (system (module_request)))" % src not in stmts:
            bad.append("no (allow %s kernel (system (module_request))): the request is "
                       "refused before the helper ever runs" % src)
    if HELPER_TT not in stmts:
        bad.append("no %s: the kernel's modprobe helper stays `kernel`, whose exec "
                   "kernel.te:209 refuses" % HELPER_TT)
    if KMOD_DPKG_TT not in stmts:
        bad.append("no %s: a kmod update leaves the helper unlabeled and refused until "
                   "the next boot's label pass" % KMOD_DPKG_TT)
    return bad, mod_type, trans.get("chr_file")


def _module_level(tree, names):
    """return the named top-level assignments and defs"""
    parts = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id in names for t in node.targets):
            parts.append(node)
        elif isinstance(node, ast.FunctionDef) and node.name in names:
            parts.append(node)
    return ast.unparse(ast.Module(body=parts, type_ignores=[]))


class _XattrOs:
    """fake os module with in-memory xattrs"""

    def __init__(self, labels=None, deny=()):
        """set up fake labels, denied paths and recorded writes"""
        self.labels = dict(labels or {})
        self.writes = []
        self.deny = set(deny)
        self.path = os.path

    def __getattr__(self, name):
        """return the attribute from the os module"""
        return getattr(os, name)

    def getxattr(self, path, name, follow_symlinks=True):
        """return the label of a path"""
        if path not in self.labels:
            raise OSError(61, "No data available", path)
        return self.labels[path]

    def setxattr(self, path, name, value, follow_symlinks=True):
        """record a label write unless the path is denied"""
        if path in self.deny:
            raise OSError(13, "Permission denied", path)
        self.writes.append(path)
        self.labels[path] = value


def load_label_host_modules(selinux_text, shim):
    """load label_host_modules from the selinux text"""
    ns = {"os": shim}
    src = _module_level(ast.parse(selinux_text),
                        {"HOST_MODULE_ROOT", "HOST_MODULE_CONTEXT", "label_host_modules"})
    exec(compile(src, "<label_host_modules>", "exec"), ns)
    return ns.get("label_host_modules"), ns.get("HOST_MODULE_CONTEXT")


def _module_fixture():
    """create a fake /lib/modules tree"""
    root = tempfile.mkdtemp(prefix="check-hotplug-modules.")
    k = os.path.join(root, "6.8.0-1-generic")
    os.makedirs(os.path.join(k, "kernel", "drivers", "net"))
    os.makedirs(os.path.join(k, "updates", "dkms"))
    os.makedirs(os.path.join(root, "6.8.0-2-generic", "kernel"))
    for f in ("kernel/drivers/net/dummy.ko.zst", "modules.dep", "modules.alias.bin",
              "updates/dkms/v4l2loopback.ko"):
        open(os.path.join(k, f), "w").close()
    open(os.path.join(root, "6.8.0-2-generic", "kernel", "overlay.ko.zst"), "w").close()
    os.symlink("/usr/src/linux-headers-6.8.0-1-generic", os.path.join(k, "build"))
    return root


def check_labeling(selinux_text, mod_type):
    """check label_host_binaries labels modprobe and modules"""
    bad = []
    tree = ast.parse(selinux_text)
    assign = next((n for n in tree.body if isinstance(n, ast.Assign) and any(
        isinstance(t, ast.Name) and t.id == "HOST_EXEC_PATHS" for t in n.targets)), None)
    paths = ast.literal_eval(assign.value) if assign else ()
    if not any(p in paths for p in MODPROBE_PATHS):
        bad.append("HOST_EXEC_PATHS names no modprobe path (%s): the kernel's usermode "
                   "helper stays unlabeled and kernel.te:209 refuses its exec"
                   % " or ".join(MODPROBE_PATHS))
    lhb = next((n for n in tree.body if isinstance(n, ast.FunctionDef)
                and n.name == "label_host_binaries"), None)
    calls = {c.func.id for c in ast.walk(lhb) if isinstance(c, ast.Call)
             and isinstance(c.func, ast.Name)} if lhb else set()
    if "label_host_modules" not in calls:
        bad.append("label_host_binaries() never calls label_host_modules(): nothing "
                   "stamps /lib/modules on a boot")
    shim = _XattrOs()
    fn, ctx = load_label_host_modules(selinux_text, shim)
    if fn is None or ctx is None:
        bad.append("sandbox/selinux_labels.py has no label_host_modules() or HOST_MODULE_CONTEXT")
        return bad
    if mod_type and ctx != "u:object_r:%s:s0" % mod_type:
        bad.append("HOST_MODULE_CONTEXT is %r but the CIL's loadable module type is %s"
                   % (ctx, mod_type))
    bad += check_label_walk(fn, ctx, shim)
    return bad


def check_label_walk(fn, ctx, shim):
    """run label_host_modules on a fixture tree"""
    bad = []
    root = _module_fixture()
    try:
        want = set()
        links = set()
        for d, _dirs, files in os.walk(root):
            want.add(d)
            for f in files + _dirs:
                p = os.path.join(d, f)
                if os.path.islink(p):
                    links.add(p)
                elif os.path.isfile(p):
                    want.add(p)
        already = os.path.join(root, "6.8.0-2-generic", "kernel", "overlay.ko.zst")
        shim.labels = {already: ctx.encode() + b"\0"}
        shim.writes = []
        labeled, have, failed = fn(root, ctx)
        written = set(shim.writes)
        missed = sorted(want - written - {already})
        if missed:
            bad.append("label_host_modules left %d path(s) unstamped, e.g. %s"
                       % (len(missed), missed[0]))
        if written & links:
            bad.append("label_host_modules stamped a symlink: %s" % sorted(written & links)[0])
        if already in written:
            bad.append("label_host_modules rewrote a path already carrying %s" % ctx)
        if (labeled, have) != (len(want) - 1, 1) or failed:
            bad.append("label_host_modules reported (%d set, %d already, %d failed), "
                       "the fixture holds %d to set and 1 already"
                       % (labeled, have, len(failed), len(want) - 1))
        shim.labels, shim.writes = {}, []
        shim.deny = {os.path.join(root, "6.8.0-1-generic", "modules.dep")}
        _l, _h, failed = fn(root, ctx)
        shim.deny = set()
        if not any(p.endswith("modules.dep") for p, _e in failed):
            bad.append("label_host_modules did not report a refused write")
        _l, _h, failed = fn(os.path.join(root, "absent"), ctx)
        if not failed:
            bad.append("label_host_modules on a missing module root reported nothing")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def load_units_still_kernel(launcher_text):
    """load the units-still-kernel function from the launcher text"""
    m = PRIMER_RE.search(launcher_text)
    if not m:
        return None
    src = _module_level(ast.parse(m.group(1)), {"_units_still_kernel"})
    ns = {"os": os}
    exec(compile(src, "<_units_still_kernel>", "exec"), ns)
    return ns.get("_units_still_kernel")


def _cgroup_fixture():
    """create a fake cgroup and proc tree"""
    root = tempfile.mkdtemp(prefix="check-hotplug-cgroup.")
    cg = os.path.join(root, "system.slice")
    proc = os.path.join(root, "proc")
    layout = {
        "systemd-udevd.service": [],
        "systemd-udevd.service/udev": ["101", "102"],
        "androidd.service": [],
        "androidd.service/android": ["201"],
        "cron.service": ["301"],
        "ssh.service": ["401"],
        "system-getty.slice/getty@tty1.service": ["501"],
        "delegating.service": ["601"],
        "delegating.service/payload": ["602"],
    }
    ctx = {"101": "kernel", "102": "kernel", "201": "u:r:kernel:s0", "301": "kernel",
           "401": "u:r:rhizo_host:s0", "501": "kernel", "601": "u:r:rhizo_host:s0",
           "602": "kernel"}
    for rel, pids in layout.items():
        d = os.path.join(cg, rel)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cgroup.procs"), "w") as f:
            f.write("".join(p + "\n" for p in pids))
    for pid, c in ctx.items():
        os.makedirs(os.path.join(proc, pid, "attr"))
        with open(os.path.join(proc, pid, "attr", "current"), "w") as f:
            f.write(c + "\0")
    return root, cg, proc


def check_udevd_walk(fn):
    """check _units_still_kernel() on the fake cgroup tree"""
    if fn is None:
        return ["launcher3.py's HOST_PRIMER_SRC has no _units_still_kernel()"]
    bad = []
    root, cg, proc = _cgroup_fixture()
    try:
        try:
            stuck = fn(cg, proc)
        except TypeError:
            return ["_units_still_kernel() takes no (cgroup root, proc root) arguments"]
        if "systemd-udevd.service" not in stuck:
            bad.append("_units_still_kernel() misses systemd-udevd.service")
        if "androidd.service" in stuck:
            bad.append("_units_still_kernel() read androidd.service's children")
        for unit in ("cron.service", "getty@tty1.service"):
            if unit not in stuck:
                bad.append("_units_still_kernel() misses %s, a plain unit still `kernel`" % unit)
        if "ssh.service" in stuck:
            bad.append("_units_still_kernel() reports ssh.service, already rhizo_host")
        if "delegating.service" in stuck:
            bad.append("_units_still_kernel() read the delegated child of a unit that has "
                       "members of its own")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def check_restart_reaches(launcher_text, unit="systemd-udevd.service"):
    """check each restart loop guard against the unit"""
    m = PRIMER_RE.search(launcher_text)
    if not m:
        return ["launcher3.py has no HOST_PRIMER_SRC string"]
    scope = {"u": unit, "_CALLER_UNIT": "", "_DM_UNIT": ""}
    exec(compile(_module_level(ast.parse(m.group(1)), {
        "_restart_class", "_SELF_UNITS", "_SELF_FAMILIES", "_SESSION_UNITS", "_SESSION_FAMILIES"}),
        "<_restart_class>", "exec"), scope)
    loop = next((n for n in ast.walk(ast.parse(m.group(1))) if isinstance(n, ast.For)
                 and isinstance(n.target, ast.Name) and n.target.id == "u"
                 and "_stuck_units" in ast.unparse(n.iter)), None)
    if loop is None:
        return ["the primer has no `for u in ... _stuck_units` restart loop"]
    bad = []
    guards = [n for n in ast.walk(loop) if isinstance(n, ast.If)
              and any(isinstance(s, ast.Continue) for s in n.body)]
    for g in guards:
        try:
            skipped = eval(compile(ast.Expression(g.test), "<guard>", "eval"),
                           {"__builtins__": {}}, scope)
        except Exception as e:
            bad.append("restart-loop guard `%s` cannot be evaluated for %s: %s"
                       % (ast.unparse(g.test), unit, e))
            continue
        if skipped:
            bad.append("the restart loop's guard `%s` skips %s" % (ast.unparse(g.test), unit))
    if not guards:
        bad.append("the restart loop has no skip guard at all")
    return bad


def check_label_order(launcher_text):
    """check label_host_binaries() precedes spawn_host_primer()"""
    fn = next((n for n in ast.walk(ast.parse(launcher_text)) if isinstance(n, ast.FunctionDef)
               and n.name == "compile_sepolicy"), None)
    if fn is None:
        return ["launcher3.py has no compile_sepolicy()"]
    calls = {}
    for c in ast.walk(fn):
        if isinstance(c, ast.Call) and isinstance(c.func, ast.Name):
            calls.setdefault(c.func.id, c.lineno)
    if "label_host_binaries" not in calls or "spawn_host_primer" not in calls:
        return ["compile_sepolicy() no longer calls both label_host_binaries() and "
                "spawn_host_primer()"]
    if calls["label_host_binaries"] > calls["spawn_host_primer"]:
        return ["compile_sepolicy() spawns the primer before label_host_binaries(): the "
                "labels land after the flip, as checked relabels"]
    return []


def _load_access_checker():
    """return the restart access checker module loaded from its file"""
    spec = importlib.util.spec_from_file_location(
        "check_restart_access", os.path.join(HERE, "restart-access.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sesearch(policy, *args):
    """return the output of sesearch on a policy"""
    r = subprocess.run(["sesearch", *args, policy], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("sesearch %s: rc=%d %s" % (" ".join(args), r.returncode,
                                                         r.stderr.strip()))
    return r.stdout


def judge_type_trans(out, want):
    """return problems in sesearch type_trans output"""
    bad = []
    got = {}
    for line in out.splitlines():
        m = re.match(r"^type_transition (\S+) (\S+) (\S+)(?: (\S+?))?;$", line.strip())
        if m:
            key = "%s %s" % (m.group(1), m.group(2)) + (" " + m.group(4) if m.group(4) else "")
            got[key] = m.group(3)
    for key, target in want.items():
        if key not in got:
            bad.append("the compiled policy has no type_transition %s" % key)
        elif got[key] != target:
            bad.append("the compiled policy's type_transition %s lands on %s, not %s"
                       % (key, got[key], target))
    return bad


def judge_holders(out, perm, allowed, required):
    """return problems in sesearch allow output"""
    bad = []
    holders = set()
    for line in out.splitlines():
        m = re.match(r"^allow (\S+) \S+:system ", line)
        if m:
            holders.add(m.group(1))
    extra = sorted(holders - allowed)
    if extra:
        bad.append("%s is held by %s -- only %s may" % (perm, ", ".join(extra),
                                                         ", ".join(sorted(allowed))))
    missing = sorted(required - holders)
    if missing:
        bad.append("%s is not held by %s" % (perm, ", ".join(missing)))
    return bad


def judge_weakened(weakened, types):
    """return an error per weakened target type"""
    return ["policy.lab is weakened on %s (a deny rule avc-lab drops) "
            "-- ask the source CIL" % t for t in sorted(set(types) & weakened)]


def check_lab(mod_type, dev_type):
    """check the policy.lab build"""
    access = _load_access_checker()
    lab_dir = tempfile.mkdtemp(prefix="check-hotplug-lab.")
    try:
        policy, weakened = access.build_lab(REPO, lab_dir)
        bad = judge_weakened(weakened, ["kernel", "device", "rhizo_host", "rhizo_host_exec",
                                        "unlabeled", mod_type or "", dev_type or ""])
        tt = sesearch(policy, "--type_trans", "-s", "kernel", "-t", "device") \
            + sesearch(policy, "--type_trans", "-s", "kernel", "-t", "rhizo_host_exec") \
            + sesearch(policy, "--type_trans", "-s", "rhizo_host", "-t", "unlabeled", "-c", "file")
        bad += judge_type_trans(tt, {
            "kernel device:chr_file": dev_type,
            "kernel device:blk_file": dev_type,
            "kernel rhizo_host_exec:process": "rhizo_host",
            "rhizo_host unlabeled:file kmod.dpkg-new": "rhizo_host_exec",
            "rhizo_host unlabeled:file kmod": "rhizo_host_exec"})
        bad += judge_holders(sesearch(policy, "--allow", "-t", "kernel", "-c", "system",
                                      "-p", "module_request"),
                             "module_request on kernel", MODULE_REQUESTERS, MODULE_REQUESTERS)
        if mod_type:
            bad += judge_holders(sesearch(policy, "--allow", "-t", mod_type, "-c", "system",
                                          "-p", "module_load"),
                                 "module_load on %s" % mod_type, {"rhizo_host"}, {"rhizo_host"})
        rows, errors = access.read_rows(ACCESS_TSV)
        bad += errors
        bad += check_private_users_rows(rows)
        if not rows:
            bad.append("hotplug-access.tsv holds no rows")
        import io
        buf = io.StringIO()
        n = access.check(REPO, policy, weakened, rows, out=buf)
        if n:
            bad += ["hotplug-access.tsv: " + l for l in buf.getvalue().splitlines()
                    if not l.startswith("ok\t")]
        return bad, len(rows)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)


def _expect(name, problems, needle, fails):
    """record a failure unless a problem contains the needle"""
    hit = [p for p in problems if needle in p]
    if not hit:
        fails.append("%s: not flagged (want %r, got %s)" % (name, needle, problems))


def _mut(text, old, new, name, fails):
    """replace old with new in text"""
    if old not in text:
        fails.append("%s: the planted defect no longer matches its source -- %r is gone"
                     % (name, old[:60]))
    return text.replace(old, new)


def selftest():
    """check each planted-defect copy against its finding"""
    fails = []
    cil = open(CIL).read()
    selinux_text = open(SELINUX_PY).read()
    launcher = open(LAUNCHER).read()

    good, mod_type, dev_type = check_cil(cil)
    if good:
        fails.append("the real CIL was flagged: %s" % good)
    tt_chr = "(typetransition kernel device chr_file rhizo_host_device)"
    tt_blk = "(typetransition kernel device blk_file rhizo_host_device)"
    cil_cases = [
        ("chr transition dropped", tt_chr, "", "no (typetransition kernel device chr_file"),
        ("chr transition commented out", tt_chr, "; " + tt_chr,
         "no (typetransition kernel device chr_file"),
        ("blk transition onto device", tt_blk, "(typetransition kernel device blk_file device)",
         "names `device` itself"),
        ("device type out of dev_type", "(typeattributeset dev_type (rhizo_host_device))", "",
         "is not in dev_type"),
        ("associate commented out", "(allow rhizo_host_device device (filesystem (associate)))",
         "; (allow rhizo_host_device device (filesystem (associate)))", "filesystem (associate)"),
        ("module type in no loadable attribute",
         "(typeattributeset system_dlkm_file_type (rhizo_host_module_file))", "",
         "carries (allow rhizo_host <type> (system (module_load)))"),
        ("module_load dropped", "(allow rhizo_host rhizo_host_module_file (system (module_load)))",
         "", "carries (allow rhizo_host <type> (system (module_load)))"),
        ("module_request dropped", "(allow rhizo_host kernel (system (module_request)))", "",
         "no (allow rhizo_host kernel (system (module_request)))"),
        ("kdevtmpfs's mknod dropped", KDEVTMPFS_MKNOD, "", "kdevtmpfs makes no node"),
        ("kdevtmpfs's mknod commented out", KDEVTMPFS_MKNOD, "; " + KDEVTMPFS_MKNOD,
         "kdevtmpfs makes no node"),
        ("helper transition dropped", HELPER_TT, "", "the kernel's modprobe helper stays"),
        ("kmod update transition commented out", KMOD_DPKG_TT, "; " + KMOD_DPKG_TT,
         "a kmod update leaves the helper unlabeled"),
        ("a second loadable module type",
         "(typeattributeset system_dlkm_file_type (rhizo_host_module_file))",
         "(typeattributeset system_dlkm_file_type (rhizo_host_module_file))\n"
         "(type rhizo_other_module_file)\n"
         "(typeattributeset vendor_file_type (rhizo_other_module_file))\n"
         "(allow rhizo_host rhizo_other_module_file (system (module_load)))",
         "2 loadable module types"),
    ]
    for name, old, new, needle in cil_cases:
        _expect(name, check_cil(_mut(cil, old, new, name, fails))[0], needle, fails)

    pu = check_private_users(cil)
    if pu:
        fails.append("the real CIL's PrivateUsers= grants were flagged: %s" % pu)
    pu_cases = [
        ("setfcap granted", "(allow rhizo_host self (user_namespace (create)))",
         "(allow rhizo_host self (user_namespace (create)))\n"
         "(allow rhizo_host self (capability (setfcap)))", "domain.te:1552"),
        ("setuid missing from capability", "kill setgid setuid setpcap",
         "kill setgid setpcap", "(capability (setuid))"),
        ("cap_userns setpcap dropped", "(cap_userns (sys_ptrace sys_admin setpcap setuid net_admin))",
         "(cap_userns (sys_ptrace sys_admin setuid net_admin))", "(cap_userns (setpcap))"),
        ("cap_userns grant commented out", "(allow rhizo_host self (cap_userns (",
         "; (allow rhizo_host self (cap_userns (", "(cap_userns (sys_admin))"),
        ("user_namespace create dropped", "(allow rhizo_host self (user_namespace (create)))", "",
         "(user_namespace (create))"),
    ]
    for name, old, new, needle in pu_cases:
        _expect(name, check_private_users(_mut(cil, old, new, name, fails)), needle, fails)
    pu_row = {"domain": "rhizo_host", "label": "rhizo_host"}
    pu_rows = [dict(pu_row, **{"class": c, "perms": p}) for c, p, _ in PRIVATE_USERS_SET]
    pu_rows += [dict(pu_row, **{"class": c, "perms": "!" + p}) for c, p, _, _ in PRIVATE_USERS_BARRED]
    if check_private_users_rows(pu_rows):
        fails.append("a full PrivateUsers= row set was flagged: %s"
                     % check_private_users_rows(pu_rows))
    _expect("cap_userns setpcap row missing", check_private_users_rows(
        [r for r in pu_rows if r["perms"] != "setpcap"]), "cap_userns { setpcap }", fails)
    _expect("setpcap row on another label", check_private_users_rows(
        [dict(r, label="kernel") if r["perms"] == "setpcap" else r for r in pu_rows]),
            "cap_userns { setpcap }", fails)
    _expect("setfcap row asking a grant", check_private_users_rows(
        [dict(r, perms="setfcap") if r["perms"] == "!setfcap" else r for r in pu_rows]),
            "capability { !setfcap }", fails)

    real = {rel: _read_repo(rel) for rel in
            (PRIVATE_USERS_DROPIN, "debian/rules") + PRIVATE_USERS_NAMERS}
    if check_private_users_dropin(real.__getitem__):
        fails.append("the real opt-out drop-in was flagged: %s"
                     % check_private_users_dropin(real.__getitem__))
    dropin_text = real[PRIVATE_USERS_DROPIN]
    dropin_cases = [
        ("drop-in missing", PRIVATE_USERS_DROPIN, None, "is missing"),
        ("drop-in turning it on", PRIVATE_USERS_DROPIN,
         dropin_text.replace("PrivateUsers=no", "PrivateUsers=yes"), "want exactly"),
        ("drop-in with a second directive", PRIVATE_USERS_DROPIN,
         dropin_text + "ProtectSystem=no\n", "want exactly"),
        ("drop-in in [Unit]", PRIVATE_USERS_DROPIN,
         dropin_text.replace("[Service]", "[Unit]"), "want exactly"),
        ("drop-in naming no neverallow", PRIVATE_USERS_DROPIN,
         dropin_text.replace("domain.te:1552", "domain.te"), "does not name the neverallow"),
        ("install line dropped", "debian/rules",
         real["debian/rules"].replace(PRIVATE_USERS_INSTALL, ""), "ships no opt-out"),
        ("installed under another name", "debian/rules",
         real["debian/rules"].replace("50-rhizo-private-users.conf", "60-rhizo.conf"),
         "ships no opt-out"),
        ("claim reading another path", "test/system/cycle/claims-install.sh",
         real["test/system/cycle/claims-install.sh"].replace(PRIVATE_USERS_DEST, "/etc/x.conf"),
         "claims-install.sh never names"),
    ]
    for name, rel, text, needle in dropin_cases:
        planted = dict(real)
        if text is None:
            del planted[rel]
        else:
            planted[rel] = text

        def read(r, planted=planted):
            """read a planted file, or raise as for a missing one"""
            if r not in planted:
                raise FileNotFoundError(r)
            return planted[r]
        _expect(name, check_private_users_dropin(read), needle, fails)

    lab = check_labeling(selinux_text, mod_type)
    if lab:
        fails.append("the real labeling was flagged: %s" % lab)
    label_cases = [
        ("modprobe dropped from HOST_EXEC_PATHS", ',\n                   "/usr/sbin/modprobe")',
         ")", "names no modprobe path"),
        ("label_host_modules never called", "= label_host_modules()", "= (0, 0, [])",
         "never calls label_host_modules"),
        ("context names another type",
         'HOST_MODULE_CONTEXT = "u:object_r:rhizo_host_module_file:s0"',
         'HOST_MODULE_CONTEXT = "u:object_r:vendor_file:s0"', "HOST_MODULE_CONTEXT is"),
        ("walk that follows a symlink", "        if os.path.islink(p):\n            continue\n",
         "", "stamped a symlink"),
        ("walk that skips directories", "        targets.append(dirpath)\n", "", "unstamped"),
        ("walk that rewrites a correct label", "            already += 1\n            continue\n",
         "            already += 1\n", "rewrote a path already carrying"),
        ("walk that swallows a refused write", "            failed.append((p, str(e)))",
         "            pass", "did not report a refused write"),
    ]
    for name, old, new, needle in label_cases:
        _expect(name, check_labeling(_mut(selinux_text, old, new, name, fails), mod_type),
                needle, fails)

    walk = check_udevd_walk(load_units_still_kernel(launcher))
    if walk:
        fails.append("the real primer walk was flagged: %s" % walk)
    subgroup = ("        if not pids and not unit.startswith(\"androidd\"):\n"
                "            for c in children:\n"
                "                pids += _members(os.path.join(dirpath, c))\n")
    walk_cases = [
        ("walk without the subgroup read", subgroup, "", "misses systemd-udevd"),
        ("walk into androidd's sandbox", ' and not unit.startswith("androidd")', "",
         "read androidd.service's children"),
        ("walk into every delegated child", "if not pids and not unit", "if not unit",
         "read the delegated child of a unit that has members"),
    ]
    for name, old, new, needle in walk_cases:
        _expect(name, check_udevd_walk(load_units_still_kernel(
            _mut(launcher, old, new, name, fails))), needle, fails)
    reach = check_restart_reaches(launcher) + check_label_order(launcher)
    if reach:
        fails.append("the real restart loop or setup order was flagged: %s" % reach)
    _expect("restart loop skipping udevd", check_restart_reaches(_mut(
        launcher, 'if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue',
        'if u.startswith("systemd-udevd") or _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue',
        "restart loop skipping udevd", fails)), "skips systemd-udevd.service", fails)
    _expect("classifier exempting udevd", check_restart_reaches(_mut(
        launcher, '_SELF_UNITS = ("androidd.service", "rhizo-policy.service")',
        '_SELF_UNITS = ("androidd.service", "rhizo-policy.service", "systemd-udevd.service")',
        "classifier exempting udevd", fails)), "skips systemd-udevd.service", fails)
    _expect("primer spawned before the labels", check_label_order(_mut(
        launcher, "        label_host_binaries()\n", "", "primer spawned before the labels",
        fails).replace("        spawn_host_primer()\n",
                       "        spawn_host_primer()\n        label_host_binaries()\n", 1)),
            "spawns the primer before label_host_binaries", fails)

    want = {"kernel device:chr_file": "rhizo_host_device",
            "kernel device:blk_file": "rhizo_host_device",
            "kernel rhizo_host_exec:process": "rhizo_host",
            "rhizo_host unlabeled:file kmod.dpkg-new": "rhizo_host_exec",
            "rhizo_host unlabeled:file kmod": "rhizo_host_exec"}
    good_tt = ("type_transition kernel device:blk_file rhizo_host_device;\n"
               "type_transition kernel device:chr_file rhizo_host_device;\n"
               "type_transition kernel rhizo_host_exec:process rhizo_host;\n"
               "type_transition rhizo_host unlabeled:file rhizo_host_exec kmod.dpkg-new;\n"
               "type_transition rhizo_host unlabeled:file rhizo_host_exec kmod;\n")
    if judge_type_trans(good_tt, want):
        fails.append("a correct type_trans answer was flagged: %s" % judge_type_trans(good_tt, want))
    _expect("transition onto device", judge_type_trans(good_tt.replace(
        "device:blk_file rhizo_host_device", "device:blk_file device"), want),
            "lands on device", fails)
    _expect("transition onto another dev type", judge_type_trans(good_tt.replace(
        "device:chr_file rhizo_host_device", "device:chr_file null_device"), want),
            "lands on null_device", fails)
    _expect("helper transition missing", judge_type_trans(good_tt.replace(
        "type_transition kernel rhizo_host_exec:process rhizo_host;\n", ""), want),
            "no type_transition kernel rhizo_host_exec:process", fails)
    _expect("kmod name transition missing", judge_type_trans(good_tt.replace(
        " kmod.dpkg-new;", " kmod.new;"), want), "no type_transition rhizo_host unlabeled:file "
            "kmod.dpkg-new", fails)
    _expect("pacman's kmod name transition missing", judge_type_trans(good_tt.replace(
        "type_transition rhizo_host unlabeled:file rhizo_host_exec kmod;\n", ""), want),
            "no type_transition rhizo_host unlabeled:file kmod", fails)
    _expect("an empty sesearch answer", judge_type_trans("", want), "no type_transition", fails)
    req = ("allow kernel kernel:system { firmware_load module_request syslog_read };\n"
           "allow rhizo_host kernel:system { module_request syslog_read };\n")
    if judge_holders(req, "module_request", MODULE_REQUESTERS, MODULE_REQUESTERS):
        fails.append("a correct module_request holder set was flagged")
    _expect("an Android domain holding module_request", judge_holders(
        req + "allow netd kernel:system module_request;\n", "module_request",
        MODULE_REQUESTERS, MODULE_REQUESTERS), "held by netd", fails)
    _expect("rhizo_host losing module_request", judge_holders(
        "allow kernel kernel:system module_request;\n", "module_request",
        MODULE_REQUESTERS, MODULE_REQUESTERS), "not held by rhizo_host", fails)
    _expect("a weakened target", judge_weakened({"binfmt_miscfs", "device"}, ["kernel", "device"]),
            "weakened on device", fails)
    if judge_weakened({"binfmt_miscfs"}, ["kernel", "device"]):
        fails.append("an unrelated weakened target was flagged")

    for f in fails:
        print("SELFTEST FAILED: " + f)
    if fails:
        print("check-hotplug-policy selftest: FAILED (%d)" % len(fails))
        return 1
    print("check-hotplug-policy selftest: ok -- %d CIL, %d PrivateUsers=, %d opt-out, %d labeling, "
          "%d walk, 2 ordering and 11 policy-answer defects flagged; the real sources pass"
          % (len(cil_cases), len(pu_cases), len(dropin_cases), len(label_cases), len(walk_cases)))
    return 0


def main(argv):
    """run the check or its selftest"""
    args = argv[1:]
    if args == ["--selftest"]:
        return selftest()
    if args not in ([], ["--no-lab"]):
        print("usage: hotplug-policy.py [--selftest] [--no-lab]", file=sys.stderr)
        return 2
    launcher = open(LAUNCHER).read()
    cil = open(CIL).read()
    bad, mod_type, dev_type = check_cil(cil)
    bad += check_private_users(cil)
    bad += check_private_users_dropin(_read_repo)
    bad += check_labeling(open(SELINUX_PY).read(), mod_type)
    bad += check_udevd_walk(load_units_still_kernel(launcher))
    bad += check_restart_reaches(launcher)
    bad += check_label_order(launcher)
    rows = 0
    if args != ["--no-lab"]:
        lab_bad, rows = check_lab(mod_type, dev_type)
        bad += lab_bad
    for b in bad:
        print("hotplug-policy: " + b, file=sys.stderr)
    if bad:
        return 1
    if args:
        print("hotplug-policy: modprobe and /lib/modules are stamped every boot as %s, the "
              "CIL transitions kdevtmpfs's nodes to %s, the primer reaches and restarts "
              "udevd (policy.lab not asked)" % (mod_type, dev_type))
        return 0
    print("hotplug-policy: modprobe and /lib/modules are stamped every boot, %s is "
          "loadable by rhizo_host alone, only kernel and rhizo_host may request a module, "
          "kdevtmpfs's nodes land on %s, the helper and a kmod update keep rhizo_host_exec, "
          "the primer reaches and restarts udevd, and all %d HOTPLUG-ACCESS rows are granted"
          % (mod_type, dev_type, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
