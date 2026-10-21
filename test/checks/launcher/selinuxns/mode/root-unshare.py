#!/usr/bin/env python3
import contextlib, importlib.util, io, os, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-root-unshare")
PHASES = ("_build_flat_trees", "_mount_extra_partitions", "_make_dev_nodes", "_bind_sockets_and_shadows",
          "_setup_cgroups_and_selinuxfs", "_pivot_and_harden")


def load(path):
    """import rootfs from path"""
    spec = importlib.util.spec_from_file_location("rhizo_mounts_under_check", path)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


def events_of(m, mode, handoff):
    """return build_root_and_pivot's calls"""
    events = []
    ns = m.selinux_ns
    saved = {p: getattr(m, p) for p in PHASES}
    saved_ns = (ns.unshare_namespace, ns.selinux_mode)
    saved_misc = (m.phase, m.mount_marker, m.prelabel_vendor_tree)
    try:
        for p in PHASES:
            setattr(m, p, (lambda name: lambda *a, **k: events.append((name,)))(p))
        ns.unshare_namespace = lambda state_file=ns.ANDROID_ENFORCE_FILE: events.append(("unshare", state_file))
        ns.selinux_mode = lambda: mode
        m.phase = lambda *a: None
        m.mount_marker = lambda: None
        m.prelabel_vendor_tree = lambda root: events.append(("prelabel",))
        m.build_root_and_pivot(mount_proc=not handoff, handoff=handoff)
    finally:
        for p, f in saved.items():
            setattr(m, p, f)
        ns.unshare_namespace, ns.selinux_mode = saved_ns
        m.phase, m.mount_marker, m.prelabel_vendor_tree = saved_misc
    return events


def findings(m):
    """return the broken rules of build_root_and_pivot"""
    out = []
    phases = [(p,) for p in PHASES]
    enforce_file = m.selinux_ns.ANDROID_ENFORCE_FILE
    got = events_of(m, "namespace", False)
    if got != [("prelabel",), ("unshare", enforce_file)] + phases:
        out.append(f"cold start: the unshare does not follow only the vendor prelabel, with the enforce state file: {got}")
    got = events_of(m, "namespace", True)
    if got != [("prelabel",), ("unshare", None)] + phases:
        out.append(f"handoff hold: the unshare does not follow only the vendor prelabel, without a state file: {got}")
    got = events_of(m, "host", False)
    if got != phases:
        out.append(f"host mode: something besides the phases ran: {got}")
    got = events_of(m, "refuse:kernel-has-no-landlock", False)
    if got != phases:
        out.append(f"refused mode: something besides the phases ran: {got}")
    return out


SRC = os.path.join(LAUNCHER, "sandbox/rootfs.py")


def mutant(old, new, tmp, name):
    """import a copy of sandbox/rootfs.py with an edit"""
    text = open(SRC).read()
    if old not in text:
        raise SystemExit(f"root-unshare selftest: cannot build the {name} mutant, {old!r} is gone")
    path = os.path.join(tmp, f"{name}.py")
    with open(path, "w") as f:
        f.write(text.replace(old, new, 1))
    return load(path)


def selftest():
    """check each mutant fails by name"""
    call = "    unshare_root_namespace(selinux_ns.selinux_mode(), handoff)\n"
    first = "    net_core_snapshot = _build_flat_trees()\n"
    gate = '    if mode == "namespace":\n        selinux_ns.unshare_namespace('
    with tempfile.TemporaryDirectory() as tmp:
        cases = [
            ("no-unshare", call, "", "cold start: the unshare does not follow only the vendor prelabel"),
            ("late-unshare", call + first, first + call, "cold start: the unshare does not follow only the vendor prelabel"),
            ("host-unshare", gate, '    if True:\n        selinux_ns.unshare_namespace(', "host mode: something"),
            ("handoff-state", "None if handoff else selinux_ns.ANDROID_ENFORCE_FILE",
             "selinux_ns.ANDROID_ENFORCE_FILE", "handoff hold: the unshare does not follow only the vendor prelabel"),
        ]
        for name, old, new, want in cases:
            got = findings(mutant(old, new, tmp, name))
            if not any(want in g for g in got):
                print(f"FAIL selftest: the {name} mutant was not flagged ({want}): {got}")
                return 1
        got = findings(load(SRC))
        if got:
            print(f"FAIL selftest: the real source is flagged: {got}")
            return 1
    print("root-unshare selftest: 4 mutants flagged, the real source clean")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    bad = findings(load(SRC))
    for b in bad:
        print("FAIL", b)
    if bad:
        sys.exit(1)
    print("ok")
