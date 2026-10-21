#!/usr/bin/env python3
import ast, contextlib, importlib.util, io, os, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-prepolicy-labels")
SRC = os.path.join(LAUNCHER, "sandbox/rootfs.py")
ANDROID_PROC = {"/dev/.shadow_vm_mmap_rnd_bits": "u:object_r:proc_security:s0",
                "/dev/.shadow_vm_mmap_rnd_compat_bits": "u:object_r:proc_security:s0",
                "/dev/.shadow_kernel_kptr_restrict": "u:object_r:proc_security:s0",
                "/dev/.shadow_kernel_unprivileged_bpf_disabled": "u:object_r:proc_bpf:s0",
                "/dev/.rhizo_sysrq_sink": "u:object_r:proc_sysrq:s0"}
PRELOAD = ("flatten_tree", "_build_flat_trees", "_stage_node", "_stage_coldboot", "_bind_sockets_and_shadows",
           "_setup_cgroups_and_selinuxfs", "stage_sysctl_shadows", "_mask_sysrq_trigger", "harden_proc_sys")


def load(path):
    """import rootfs from path"""
    spec = importlib.util.spec_from_file_location("rhizo_mounts_under_check", path)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


@contextlib.contextmanager
def patched(m, unshared):
    """yield the label and file writes under replaced host effects"""
    writes = []
    ns = m.selinux_ns
    real_exists, real_stat, real_setxattr = os.path.exists, os.stat, os.setxattr
    saved = {k: getattr(m, k) for k in ("mount", "_detach_if_mounted", "_label_of", "_sysctl_shadow_label", "kmsg",
                                        "host_boot_id")}
    saved_state = ns.state

    def fake_open(path, mode="r", *a, **k):
        """read a sysctl as 1, note a write"""
        if "r" in mode and path.startswith("/proc/sys/"):
            return io.StringIO("1\n")
        writes.append((path, mode))
        return io.StringIO()

    def no_stat(*a, **k):
        """fail every stat"""
        raise OSError("stat replaced by the check")

    def no_boot_id():
        """fail the boot id read"""
        raise OSError("boot id replaced by the check")

    try:
        ns.state = lambda: {"unshared": unshared}
        os.setxattr = lambda p, n, v, *a, **k: writes.append((p, n, v))
        os.path.exists = lambda p: p.startswith("/dev/.") or real_exists(p)
        os.stat = no_stat
        m.open = fake_open
        m.mount = lambda *a, **k: True
        m._detach_if_mounted = lambda p: None
        m._label_of = lambda p: None
        m._sysctl_shadow_label = lambda p: b"u:object_r:proc_security:s0\0"
        m.kmsg = lambda *a, **k: None
        m.host_boot_id = no_boot_id
        yield writes
    finally:
        os.path.exists, os.stat, os.setxattr = real_exists, real_stat, real_setxattr
        ns.state = saved_state
        for k, v in saved.items():
            setattr(m, k, v)
        del m.open


def relabeled_shadows(m, present):
    """return the after-load sysctl-shadows pass's label writes"""
    from sandbox import selinux_ns as ns
    writes = []
    real_exists, saved = os.path.exists, (ns.selinux_labels.label_write, sys.modules.get("sandbox.rootfs"))
    with tempfile.TemporaryDirectory() as root:
        try:
            sys.modules["sandbox.rootfs"] = m
            ns.selinux_labels.label_write = lambda p, v, *a, **k: (writes.append((p[len(root):], v)), True)[1]
            os.path.exists = lambda p: p[len(root):] in present if p.startswith(root) else real_exists(p)
            ns.label_sysctl_shadows(root)
        except OSError as e:
            writes.append(("raised", repr(e)))
        finally:
            os.path.exists = real_exists
            ns.selinux_labels.label_write = saved[0]
            if saved[1] is None:
                sys.modules.pop("sandbox.rootfs", None)
            else:
                sys.modules["sandbox.rootfs"] = saved[1]
    return writes


def findings(m, text):
    """return the broken rules"""
    out = []
    with patched(m, True) as writes:
        got = m.label_before_policy("/x", b"u:object_r:x:s0\0")
    if got is not False or writes:
        out.append(f"unshared: label_before_policy wrote a label before the policy load: {got} {writes}")
    with patched(m, False) as writes:
        got = m.label_before_policy("/x", b"u:object_r:x:s0\0")
    if got is not True or writes != [("/x", "security.selinux", b"u:object_r:x:s0\0")]:
        out.append(f"host mode: label_before_policy did not write the label: {got} {writes}")
    funcs = {n.name: n for n in ast.walk(ast.parse(text)) if isinstance(n, ast.FunctionDef)}
    for name in PRELOAD:
        for c in ast.walk(funcs.get(name, ast.Module(body=[], type_ignores=[]))):
            if (isinstance(c, ast.Call) and ast.unparse(c.func) == "os.setxattr"
                    and len(c.args) > 1 and ast.unparse(c.args[1]) == "'security.selinux'"):
                out.append(f"{name}: a direct os.setxattr of security.selinux skips label_before_policy")
    want = list(ANDROID_PROC.items())
    got = relabeled_shadows(m, [p for p, _ in want])
    if got != [(p, (lbl + "\0").encode()) for p, lbl in want]:
        out.append(f"the after-load relabel does not give the sysctl shadows Android's labels: {got}")
    with patched(m, True) as writes:
        ok = m.harden_proc_sys()
    if ok is not True or writes:
        out.append(f"unshared: /proc/sys hardening fails or rewrites a staged shadow while its label is Android's: "
                   f"{ok} {writes}")
    reads, real_chmod = [], os.chmod
    with patched(m, False) as writes:
        m._sysctl_shadow_label = lambda p: reads.append(p) or b"u:object_r:proc_security:s0\0"
        os.chmod = lambda *a, **k: None
        try:
            m.harden_proc_sys()
        finally:
            os.chmod = real_chmod
    if not reads or len(reads) != len(set(reads)):
        out.append(f"host mode: harden_proc_sys reads a shadow's real-node label more than once: {sorted(reads)}")
    logs, saved_kmsg = [], m.kmsg
    m.kmsg = logs.append
    try:
        got = m._sysctl_shadow_label("/proc/sys/kernel/rhizo-check-absent")
    finally:
        m.kmsg = saved_kmsg
    if got != b"u:object_r:proc_security:s0\0" or not any("real-node label unreadable" in l for l in logs):
        out.append(f"an unreadable real node's fallback label is not logged: {got} {logs}")
    return out


def selftest():
    """check each mutant fails by name"""
    text = open(SRC).read()
    cases = [("helper-writes", '    if selinux_ns.state()["unshared"]:\n        return False\n', "",
              "unshared: label_before_policy wrote"),
             ("direct-site", 'label_before_policy(f"{NEWROOT}/dev/tun", ',
              'os.setxattr(f"{NEWROOT}/dev/tun", "security.selinux", ',
              "_bind_sockets_and_shadows: a direct os.setxattr"),
             ("host-labels", '"kernel/kptr_restrict": "u:object_r:proc_security:s0"',
              '"kernel/kptr_restrict": "system_u:object_r:sysctl_kernel_t:s0"',
              "the after-load relabel does not give the sysctl shadows Android's labels"),
             ("harden-counts-labels", '    if selinux_ns.state()["unshared"]:\n        return os.path.exists(path)\n',
              "", "unshared: /proc/sys hardening fails")]
    with tempfile.TemporaryDirectory() as tmp:
        for name, old, new, want in cases:
            if old not in text:
                print(f"FAIL selftest: cannot build the {name} mutant")
                return 1
            path = os.path.join(tmp, f"{name}.py")
            mutated = text.replace(old, new, 1)
            with open(path, "w") as f:
                f.write(mutated)
            got = findings(load(path), mutated)
            if not any(want in g for g in got):
                print(f"FAIL selftest: the {name} mutant was not flagged ({want}): {got}")
                return 1
    got = findings(load(SRC), text)
    if got:
        print(f"FAIL selftest: the real source is flagged: {got}")
        return 1
    print(f"prepolicy-labels selftest: {len(cases)} mutants flagged, the real source clean")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    bad = findings(load(SRC), open(SRC).read())
    for b in bad:
        print("FAIL", b)
    if bad:
        sys.exit(1)
    print("ok")
