#!/usr/bin/env python3
import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd")
FAKE_GSI = "/nonexistent-gsi-for-check-mount-plan"
os.environ.setdefault("RHIZO_GSI", FAKE_GSI)
sys.path.insert(0, LAUNCHER)
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs  # noqa: E402


def fail(msg):
    """print a failure message to stderr and return 1"""
    print("check-mount-plan: %s" % msg, file=sys.stderr)
    return 1


def build_fixture(root, extra_lower=0):
    """create the lower and upper fixture trees"""
    lower, upper = os.path.join(root, "lower"), os.path.join(root, "upper")
    for d in ("bin", "etc/init", "lib64/hw", "usr/share/deep"):
        os.makedirs(os.path.join(lower, d), exist_ok=True)
    for i in range(1, 6):
        open(os.path.join(lower, "bin", "tool%d" % i), "w").write("x")
    for i in range(1, 4):
        open(os.path.join(lower, "etc/init", "svc%d.rc" % i), "w").write("y")
    for i in range(1, 5):
        open(os.path.join(lower, "lib64/hw", "lib%d.so" % i), "w").write("z")
    for i in range(extra_lower):
        open(os.path.join(lower, "lib64/hw", "extra%d.so" % i), "w").write("z")
    open(os.path.join(lower, "usr/share/deep", "data"), "w").write("q")
    os.symlink("tool1", os.path.join(lower, "bin", "alias1"))
    for d in ("bin", "etc/init", "lib64/hw"):
        os.makedirs(os.path.join(upper, d), exist_ok=True)
    open(os.path.join(upper, "etc/init", "svc2.rc"), "w").write("Y")
    open(os.path.join(upper, "lib64/hw", "lib3.so"), "w").write("Z")
    open(os.path.join(upper, "bin", "newtool"), "w").write("N")
    return lower, upper, os.path.join(root, "flat")


def check_counts(root):
    """return the mount count mismatches"""
    lower, upper, flat = build_fixture(root)
    off_ops, off, off_err = rootfs.plan_flat_tree(lower, upper, flat)
    on_ops, on, on_err = rootfs.plan_flat_tree(lower, upper, flat, dir_binds=True)
    bad = []
    if off_err or on_err:
        bad.append("the fixture walk hit errors: %s %s" % (off_err[:1], on_err[:1]))
    want_off = {"files": 13, "subtrees": 1, "dirbinds": 0, "overmounts": 0,
                "links": 1, "mounts": 14}
    want_on = {"files": 6, "subtrees": 1, "dirbinds": 2, "overmounts": 2,
               "links": 1, "mounts": 11}
    for label, got, want in (("levers off", off, want_off), ("dir binds", on, want_on)):
        for k, v in want.items():
            if got.get(k) != v:
                bad.append("%s: %s is %s, want %s" % (label, k, got.get(k), v))
    bound = sorted(o["rel"] for o in on_ops
                   if o["op"] == "bind" and o["kind"] == "dir")
    if bound != ["etc", "lib64"]:
        bad.append("dir binds landed on %s, want ['etc', 'lib64']" % bound)
    over = [o for o in on_ops if o["op"] == "bind" and o["kind"] == "overmount"]
    if not all(o["dst"].startswith(flat + "/") for o in over):
        bad.append("an overmount target left the flat tree: %s" % [o["dst"] for o in over])
    if not any(o["op"] == "bind" and o["rel"] == "bin/newtool" for o in on_ops):
        bad.append("the NEW upper name lost its own bind under the lever")
    for o in over:
        d = next(i for i, x in enumerate(on_ops)
                 if x["op"] == "bind" and x["kind"] == "dir"
                 and o["rel"].startswith(x["rel"] + "/"))
        if d > on_ops.index(o):
            bad.append("overmount %s is planned before its directory bind" % o["rel"])
    return bad


def check_target_guard(root):
    """return the bad mount target findings"""
    lower, upper, flat = build_fixture(root)
    ops, _, _ = rootfs.plan_flat_tree(lower, upper, flat, dir_binds=True)
    bad = []
    if rootfs.plan_bad_targets(ops, flat):
        bad.append("a clean plan was reported as mounting outside the flat tree")
    for outside in (os.path.join(rootfs.GSI, "system_ext/etc/x.rc"),
                    os.path.join(rootfs.PREPARED_ROOT, "vendor/lib64/x.so"),
                    "/srv/elsewhere/x"):
        forged = ops + [{"op": "bind", "kind": "overmount", "src": "/dev/null",
                         "dst": outside, "rel": "x", "ro": False, "rec": False}]
        if not rootfs.plan_bad_targets(forged, flat):
            bad.append("a mount targeting %s was not refused" % outside)
    return bad


FILES = {"mounts": "sandbox/rootfs.py", "env": "sandbox/core.py", "hals": "sandbox/hals.py",
         "launcher": "boot.py", "rc": "guest/init/bpfloader.rc",
         "policy": "guest/sepolicy/policy.cil", "selinuxns": "sandbox/selinux_ns.py"}
BIND_SITES = {
    ("boot.py", "prepare_host_and_data"): "host",
    ("boot.py", "setup_loop_and_netfilter"): "host",
    ("boot.py", "prepare_tree_verb"): "host-raw: binds the build.part vendor tree it writes, nothing mounted under it",
    ("sandbox/core.py", "bind_private"): "host: the private bind helper itself",
    ("sandbox/core.py", "share_run_dir"): "host-raw: binds the unit's runtime directory shared, the one bind that must propagate",
    ("sandbox/core.py", "bind_as_owner"): "sandbox: called from _bind_sockets_and_shadows",
    ("sandbox/rootfs.py", "mount_sandbox_selinuxfs"): "sandbox",
    ("sandbox/rootfs.py", "flatten_tree"): "sandbox",
    ("sandbox/rootfs.py", "_build_flat_trees"): "sandbox",
    ("sandbox/rootfs.py", "_mount_extra_partitions"): "sandbox",
    ("sandbox/rootfs.py", "_shadow_sys_devices"): "sandbox",
    ("sandbox/rootfs.py", "sink_block_uevents"): "sandbox: g's fence, in the sandbox's mount namespace",
    ("sandbox/rootfs.py", "_bind_sockets_and_shadows"): "sandbox",
    ("sandbox/rootfs.py", "_setup_cgroups_and_selinuxfs"): "sandbox",
    ("sandbox/rootfs.py", "_mask_sysrq_trigger"): "sandbox",
    ("sandbox/rootfs.py", "harden_proc_sys"): "sandbox",
    ("sandbox/selinux_ns.py", "bind_decoy_enforce"): "sandbox",
}
SOURCE_RULES = (
    ("launcher", 'core.bind_private(RHIZO_VENDOR_DIR, f"{RUN_ROOT}/vendor")',
     "the vendor staging bind is no longer private"),
    ("launcher", "core.bind_private(_src, _target)",
     "a prepared bin/lib/lib64 bind is no longer private"),
    ("launcher", 'core.bind_private(_apex_src, f"{RUN_ROOT}/apex_override")',
     "the prepared apex_override bind is no longer private"),
    ("launcher", 'core.bind_private(RHIZO_APEX_DIR, f"{RUN_ROOT}/apex_override")',
     "the apex_override staging bind is no longer private"),
    ("mounts", 'core.bind_private("/run/rhizo-delay",',
     "the host-delay socket dir bind is no longer private"),
    ("policy", "(allow rhizo_host rhizo_delay_socket (dir (relabelto mounton)))",
     "the host-delay socket dir bind lost its relabelto mounton grant"),
    ("mounts", 'core.bind_private("/run/rhizo-headroom",',
     "the headroom socket dir bind is no longer private"),
    ("policy", "(allow rhizo_host rhizo_headroom_socket (dir (relabelto mounton)))",
     "the headroom socket dir bind lost its relabelto mounton grant"),
    ("launcher", "core.unmount_under(RHIZO_VENDOR_DIR)",
     "the vendor staging dir is removed without unmounting what sits under it"),
    ("launcher", "core.unmount_under(RHIZO_APEX_DIR)",
     "the apex_override staging dir is removed without unmounting what sits under it"),
    ("mounts", "plan_bad_targets(ops, flat)",
     "flatten_tree stopped checking its own plan"),
    ("mounts", 'raise RuntimeError(f"flatten_tree({flat}): {len(bad)} mount target(s) "',
     "flatten_tree stopped refusing a plan that mounts outside the flat tree"),
    ("mounts", 'kmsg("RHIZO_MARKER mounts=%d per_file=%d subtree=%d apex=%d syskernel=%d"',
     "the mount marker lost a field"),
    ("mounts", "    mount_marker()",
     "build_root_and_pivot stopped emitting the mount marker"),
    ("mounts", "expected u:object_r:system_file:s0",
     "the apex dir bind stopped stating the label it expects on the bound directory"),
    ("mounts", "_apex_bad.append", "the apex post-bind size verification is gone"),
    ("mounts", 'guest_files.read("sys-kernel-readers.txt")',
     "the sys/kernel subset stopped reading the built scan"),
    ("env", 'RHIZO_FLAT_DIR_BINDS = os.environ.get("RHIZO_FLAT_DIR_BINDS", "1") == "1"',
     "the flat-tree lever is no longer a knob defaulting on"),
    ("env", 'RHIZO_APEX_DIR_BIND = os.environ.get("RHIZO_APEX_DIR_BIND", "1") == "1"',
     "the apex lever is no longer a knob defaulting on"),
    ("env", 'RHIZO_SYSKERNEL_SUBSET = os.environ.get("RHIZO_SYSKERNEL_SUBSET", "1") == "1"',
     "the sys/kernel lever is no longer a knob defaulting on"),
    ("env", "if RHIZO_FLAT_DIR_BINDS\n              else",
     "the netbpfload preload's path stopped following the flat-tree knob"),
    ("hals", "_shg2.copy(preload_src, NETBPFLOAD_PRELOAD_STAGE)",
     "the netbpfload preload is staged at a literal path again"),
    ("hals", 'f"{NETBPFLOAD_PRELOAD_PATH} u:object_r:bpfloader_exec:s0',
     "the wrapper's file_contexts entry no longer follows its path"),
    ("rc", "@RHIZO" + "_SUBST:NETBPFLOAD_PRELOAD_PATH@",
     "rhizo-bpfloader.rc names the wrapper by a literal path again"),
)


def check_source(vm_dir):
    """return the failed source rule messages"""
    bad = []
    text = {k: open(os.path.join(vm_dir, v)).read() for k, v in FILES.items()}
    for where, needle, why in SOURCE_RULES:
        if needle not in text[where]:
            bad.append(why)
    lever = text["mounts"].split("if RHIZO_APEX_DIR_BIND:")[-1].split("def ")[0]
    if "os.setxattr(apex_flat" in lever.split("else:")[0]:
        bad.append("the apex dir-bind branch setxattrs the GSI's own directory")
    if 'rstrip("\\x00") != "u:object_r:tmpfs:s0"' not in text["launcher"]:
        bad.append("relabel_flat_trees no longer skips objects that are not raw tmpfs")
    return bad


def calls_by_function(tree):
    """yield (innermost function name, call) for every call"""
    import ast

    def walk(node, owner):
        """yield the calls under node with their function"""
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                yield from walk(child, child.name)
                continue
            if isinstance(child, ast.Call):
                yield owner, child
            yield from walk(child, owner)
    yield from walk(tree, "<module>")


def flag_names(expr):
    """return a flags expression's MS_ names, or None"""
    import ast
    if isinstance(expr, ast.Name):
        return {expr.id} if expr.id.startswith("MS_") else None
    if isinstance(expr, ast.Constant) and isinstance(expr.value, int):
        return set()
    if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.BitOr):
        parts = (flag_names(expr.left), flag_names(expr.right))
    elif isinstance(expr, ast.IfExp):
        parts = (flag_names(expr.body), flag_names(expr.orelse))
    else:
        return None
    return None if None in parts else parts[0] | parts[1]


def check_bind_inventory(vm_dir):
    """return unclassified bind sites and raw host binds"""
    import ast
    import glob
    bad, raw, private = [], {}, set()
    for path in sorted(glob.glob(os.path.join(vm_dir, "*.py")) + glob.glob(os.path.join(vm_dir, "sandbox", "*.py"))):
        name = os.path.relpath(path, vm_dir)
        for owner, call in calls_by_function(ast.parse(open(path).read())):
            func = ast.unparse(call.func)
            if func.split(".")[-1] == "bind_private":
                private.add((name, owner))
            if func not in ("mount", "core.mount") and not func.endswith("libc.mount"):
                continue
            if (name, owner) == ("sandbox/core.py", "mount") and func.endswith("libc.mount"):
                continue
            flags = call.args[3] if len(call.args) > 3 and not any(isinstance(a, ast.Starred) for a in call.args[:4]) \
                else next((k.value for k in call.keywords if k.arg in ("fl", "flags", "mountflags")), None)
            names = flag_names(flags) if flags is not None else None
            if names is None:
                bad.append("%s:%d: a mount whose flags are not MS_ constants: %s" % (name, call.lineno, ast.unparse(call)))
            elif "MS_BIND" in names and "MS_REMOUNT" not in names:
                raw.setdefault((name, owner), call.lineno)
    for site in sorted(set(raw) | private):
        kind = BIND_SITES.get(site)
        if kind is None:
            bad.append("%s:%s bind-mounts and is not classified in BIND_SITES: a host-side bind must go "
                       "through core.bind_private" % site)
        elif kind == "host" and site in raw:
            bad.append("%s:%s is host-side and binds raw at line %d: use core.bind_private"
                       % (site + (raw[site],)))
    for site in sorted(set(BIND_SITES) - set(raw) - private):
        bad.append("BIND_SITES lists %s:%s, which binds nothing now" % site)
    return bad


def check_overmount_grant(vm_dir):
    """return the missing mounton policy grant"""
    bad = []
    policy = open(os.path.join(vm_dir, FILES["policy"])).read()
    env = open(os.path.join(vm_dir, FILES["env"])).read()
    lever_on = 'os.environ.get("RHIZO_FLAT_DIR_BINDS", "1") == "1"' in env
    rule = "(allow rhizo_host system_file (file (mounton)))"
    if rule not in policy:
        bad.append("the policy does not grant %s" % rule)
    if bad and not lever_on:
        bad = [b + " (the lever defaults off)" for b in bad]
    return bad


def check_wrap_path():
    """return the rendered .rc path mismatches"""
    bad = []
    seen = {}
    for knob in ("0", "1"):
        env = dict(os.environ, RHIZO_FLAT_DIR_BINDS=knob)
        r = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r)\n"
             "import contextlib, io\n"
             "with contextlib.redirect_stdout(io.StringIO()):\n"
             "    from sandbox import core, guest_files\n"
             "print(core.NETBPFLOAD_PRELOAD_PATH)\n"
             "print(core.NETBPFLOAD_PRELOAD_STAGE)\n"
             "print(guest_files.render(guest_files.read('init/bpfloader.rc'),"
             " inline={'NETBPFLOAD_PRELOAD_PATH': core.NETBPFLOAD_PRELOAD_PATH},"
             " comment_prefix='#').count(core.NETBPFLOAD_PRELOAD_PATH))" % LAUNCHER],
            capture_output=True, text=True, env=env, timeout=120)
        if r.returncode != 0:
            bad.append("rendering rhizo-bpfloader.rc with the knob %r failed: %s"
                       % (knob, r.stderr.strip()[-200:]))
            continue
        path, stage, hits = r.stdout.split("\n")[:3]
        seen[knob] = path
        if int(hits) != 2:
            bad.append("the rendered .rc names %s %s times, want 2" % (path, hits))
        if not stage.startswith("/run/rhizo/") or os.path.basename(stage) != os.path.basename(path):
            bad.append("the staging path %s does not stage %s" % (stage, path))
    if seen.get("0") != "/system/bin/rhizo_netbpfload_preload":
        bad.append("with the lever off the wrapper moved off /system/bin")
    if not seen.get("1", "").startswith("/system_ext/"):
        bad.append("with the lever on the wrapper still forces a new name in /system/bin")
    return bad


def selftest():
    """run the checks on fixture trees"""
    bad = []
    with tempfile.TemporaryDirectory() as root:
        if check_counts(os.path.join(root, "good")):
            bad.append("the count check failed on a correct fixture")
        if check_target_guard(os.path.join(root, "guard")):
            bad.append("the target guard failed on a correct fixture")
        lower, upper, flat = build_fixture(os.path.join(root, "broken"), extra_lower=2)
        _, counts, _ = rootfs.plan_flat_tree(lower, upper, flat)
        if counts["mounts"] == 14:
            bad.append("the planner counted a two-file-larger tree the same")
        src = os.path.join(root, "src")
        for sub in ("sandbox", "guest/init", "guest/sepolicy"):
            os.makedirs(os.path.join(src, sub))

        def restore():
            """copy the launcher files back over the planted copies"""
            for name in FILES.values():
                shutil.copy(os.path.join(LAUNCHER, name), os.path.join(src, name))
        for where, needle, why in SOURCE_RULES:
            restore()
            target = os.path.join(src, FILES[where])
            t = open(target).read()
            open(target, "w").write(t.replace(needle, "# removed"))
            if why not in check_source(src):
                bad.append("removing %r did not fail the source check" % needle[:40])
        restore()
        target = os.path.join(src, FILES["mounts"])
        t = open(target).read()
        open(target, "w").write(t.replace(
            '        kmsg(f"/system/apex dir bind: directory label',
            '        os.setxattr(apex_flat, "security.selinux", b"x")\n'
            '        kmsg(f"/system/apex dir bind: directory label'))
        if "the apex dir-bind branch setxattrs the GSI's own directory" not in check_source(src):
            bad.append("a setxattr on the bound GSI apex directory passed the check")
        restore()
        target = os.path.join(src, FILES["launcher"])
        t = open(target).read()
        open(target, "w").write(t.replace(
            'rstrip("\\x00") != "u:object_r:tmpfs:s0"',
            'rstrip("\\x00") != "u:object_r:system_file:s0"'))
        if not check_source(src):
            bad.append("a relabel pass that no longer skips non-tmpfs objects passed")
        restore()
        target = os.path.join(src, FILES["policy"])
        t = open(target).read()
        open(target, "w").write(
            t.replace("(allow rhizo_host system_file (file (mounton)))", "", 1))
        if not check_overmount_grant(src):
            bad.append("a policy with no file mounton grant passed the check")
        restore()
        if check_bind_inventory(src):
            bad.append("the bind inventory failed on the real launcher: %s" % check_bind_inventory(src))
        target = os.path.join(src, FILES["launcher"])
        t = open(target).read()
        open(target, "w").write(t + "\n\ndef new_host_bind():\n    mount('/a', '/b', None, MS_BIND)\n")
        if not any("new_host_bind bind-mounts and is not classified" in b for b in check_bind_inventory(src)):
            bad.append("an unclassified new bind passed the inventory")
        restore()
        anchor = "    _prepared_key, _prepared_reason = core.validate_prepared()\n"
        if anchor not in t:
            bad.append("the host-raw-bind mutant found no anchor")
        open(target, "w").write(t.replace(anchor, "    mount('/a', '/b', None, MS_BIND)\n" + anchor, 1))
        if not any("prepare_host_and_data is host-side and binds raw" in b for b in check_bind_inventory(src)):
            bad.append("a raw bind in a host-side function passed the inventory")
        restore()
        open(target, "w").write(t + "\n\ndef hidden_bind():\n    flags = MS_BIND\n    mount('/a', '/b', None, flags)\n")
        if not any("flags are not MS_ constants" in b for b in check_bind_inventory(src)):
            bad.append("a bind through a flags variable passed the inventory")
        restore()
        open(target, "w").write(t + "\n\ndef outer():\n    def inner():\n        mount('/a', '/b', None, MS_BIND)\n")
        if not any("boot.py:inner bind-mounts" in b for b in check_bind_inventory(src)):
            bad.append("a bind in a nested function was not named by its own function")
        for form, finding in (("libc.mount(b'/a', b'/b', None, MS_BIND, None)", "boot.py:via_libc bind-mounts"),
                              ("core.libc.mount(b'/a', b'/b', None, MS_BIND, None)",
                               "boot.py:via_libc bind-mounts"),
                              ("mount('/a', '/b', None, fl=MS_BIND)", "boot.py:via_libc bind-mounts"),
                              ("mount(*args)", "flags are not MS_ constants")):
            restore()
            open(target, "w").write(t + "\n\ndef via_libc():\n    %s\n" % form)
            if not any(finding in b for b in check_bind_inventory(src)):
                bad.append("a bind as %s passed the inventory" % form)
    if bad:
        for b in bad:
            print("check-mount-plan --selftest: %s" % b, file=sys.stderr)
        return 1
    print("check-mount-plan: selftest ok")
    return 0


def main():
    """run the mount plan checks"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    with tempfile.TemporaryDirectory() as root:
        bad += check_counts(os.path.join(root, "counts"))
        bad += check_target_guard(os.path.join(root, "guard"))
    bad += check_source(LAUNCHER)
    bad += check_overmount_grant(LAUNCHER)
    bad += check_bind_inventory(LAUNCHER)
    bad += check_wrap_path()
    with tempfile.TemporaryDirectory() as root:
        lower, upper, flat = build_fixture(root)
        r = subprocess.run([sys.executable, "-m", "sandbox.rootfs",
                            "--plan-mounts", lower, upper, "--flat", flat],
                           capture_output=True, text=True, timeout=120, cwd=LAUNCHER)
        if r.returncode != 0 or "lever 1 flat trees per directory" not in r.stdout:
            bad.append("sandbox/rootfs.py --plan-mounts did not report the lever arithmetic")
    if bad:
        for b in bad:
            print("check-mount-plan: %s" % b, file=sys.stderr)
        return 1
    print("check-mount-plan: the plan is predicted, ordered and sandbox-side")
    return 0


if __name__ == "__main__":
    sys.exit(main())
