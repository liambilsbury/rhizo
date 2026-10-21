#!/usr/bin/env python3
import ast, contextlib, io, os, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
SRC = os.path.join(LAUNCHER, "sandbox/rootfs.py")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-vendor-prelabel")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import selinux_ns as ns
PRELABEL = "prelabel_vendor_tree"
LABELLER = "label_by_file_contexts"
ROOT_BUILD = "build_root_and_pivot"


def calls(node):
    """return (name, call) for the calls under node in source order"""
    out = sorted((n for n in ast.walk(node) if isinstance(n, ast.Call)), key=lambda n: (n.lineno, n.col_offset))
    return [(getattr(n.func, "attr", getattr(n.func, "id", "")), n) for n in out]


def first(found, name):
    """return the line of the first call to name, or None"""
    return next((n.lineno for got, n in found if got == name), None)


def order_findings(src):
    """return what keeps the vendor labels from landing before init"""
    funcs = {f.name: f for f in ast.parse(src).body if isinstance(f, ast.FunctionDef)}
    out = []
    pre = funcs.get(PRELABEL)
    if pre is None:
        return [f"no {PRELABEL}()"]
    pc = calls(pre)
    enter, label = first(pc, "enter_policy_namespace"), first(pc, LABELLER)
    if first(pc, "fork") is None:
        out.append(f"{PRELABEL} does not fork")
    if enter is None:
        out.append(f"{PRELABEL} does not enter a child namespace holding a policy")
    elif not any(got == "enter_policy_namespace" and len(n.args) == 2 and ast.unparse(n.args[1]) == "'relabel'"
                 for got, n in pc):
        out.append(f"{PRELABEL} enters the policy namespace without naming the relabel helper domain")
    elif "/etc/selinux/precompiled_sepolicy" not in ast.unparse(pre) or "/vendor" not in ast.unparse(pre):
        out.append(f"{PRELABEL} loads a policy other than the precompiled_sepolicy init loads")
    if label is None or enter is None or label < enter:
        out.append(f"{PRELABEL} does not run {LABELLER} after entering the policy namespace")
    device_state = first(pc, "label_device_state_dir")
    if device_state is None or enter is None or device_state < enter:
        out.append(f"{PRELABEL} does not label the device-state directory after entering the policy namespace")
    copies = sorted(f.name for f in funcs.values() for c in ast.walk(f) if isinstance(c, ast.Call)
                    and ast.unparse(c.func) == "re.compile" and "\\Z" in ast.unparse(c))
    if copies:
        out.append(f"rootfs parses file_contexts itself in {copies}, a copy of selinux_ns.{LABELLER}")
    for name in ("relabel_flat_trees_now", "relabel_root_objects_now"):
        if first(pc, name) is not None:
            out.append(f"{PRELABEL} runs {name}, whose in-memory relabels a sibling namespace cannot see")
    build = funcs.get(ROOT_BUILD)
    use = first(calls(build), PRELABEL) if build else None
    if use is None:
        return out + [f"{ROOT_BUILD} never calls {PRELABEL}"]
    at = first(calls(build), "unshare_root_namespace")
    if at is None or at < use:
        out.append(f"{ROOT_BUILD} does not call {PRELABEL} before unshare_root_namespace")
    return out


def label_findings(src):
    """return the shared labeller's errors on a vendor tree"""
    fn = getattr(ns, LABELLER, None)
    if fn is None:
        return [f"no selinux_ns.{LABELLER}()"]
    wrote = []
    saved = ns.selinux_labels.label_write
    ns.selinux_labels.label_write = lambda p, want, follow_symlinks=True, skipped=None: wrote.append((p, want)) or True
    out = []
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "vendor")
        for d in ("etc/selinux", "lib64/hw", "bin"):
            os.makedirs(os.path.join(root, d))
        open(os.path.join(root, "etc", "linker.config.pb"), "w").close()
        fc = os.path.join(tmp, "fc")
        open(fc, "w").write("/(vendor|system/vendor)(/.*)?  u:object_r:vendor_file:s0\n"
                            "/(vendor|system/vendor)/etc(/.*)?  u:object_r:vendor_configs_file:s0\n"
                            "/vendor/etc/linker\\.config\\.pb  u:object_r:vendor_linker_cfg:s0\n"
                            "/(vendor|system/vendor)/lib64/hw  -d  u:object_r:vendor_hw_dir:s0\n")
        os.makedirs(os.path.join(root, "etc", "fixed"))
        try:
            fn(root, "/vendor", [fc], fixed=[("/vendor/etc/fixed", "u:object_r:fixed_point:s0")],
               prune=lambda p: p == os.path.join(root, "bin"))
        except TypeError as e:
            return [f"{LABELLER} takes no fixed labels or prune: {e}"]
        finally:
            ns.selinux_labels.label_write = saved
        got = {os.path.relpath(p, root): w.rstrip(b"\0").decode() for p, w in wrote}
    want = {".": "u:object_r:vendor_file:s0", "etc": "u:object_r:vendor_configs_file:s0",
            "etc/selinux": "u:object_r:vendor_configs_file:s0",
            "etc/linker.config.pb": "u:object_r:vendor_linker_cfg:s0", "lib64": "u:object_r:vendor_file:s0",
            "lib64/hw": "u:object_r:vendor_hw_dir:s0", "etc/fixed": "u:object_r:fixed_point:s0"}
    for rel, lbl in want.items():
        if got.get(rel) != lbl:
            out.append(f"{LABELLER} gave {rel} {got.get(rel)!r}, file_contexts says {lbl}")
    if "bin" in got:
        out.append(f"{LABELLER} labeled a mount point inside the tree (bin), a prepared bind or another filesystem")
    return out


class Exited(Exception):
    """raised in place of os._exit"""


def run_prelabel(src, fork_pid, status=0, enter=None, rows=(), counts=None, caps="", device_state=None, report=b"ok",
                 tmpfs=False):
    """run prelabel_vendor_tree from src with host effects stubbed"""
    funcs = {f.name: f for f in ast.parse(src).body if isinstance(f, ast.FunctionDef)}
    if PRELABEL not in funcs:
        return None, [], None, b""
    logs, seen, sent = [], {}, []

    class FakeOs:
        """os stand-in for the fork, the wait and the exit"""
        path = os.path
        makedirs = staticmethod(lambda p, exist_ok=False: None)
        fork = staticmethod(lambda: fork_pid)
        waitpid = staticmethod(lambda p, f: (p, status))
        waitstatus_to_exitcode = staticmethod(os.waitstatus_to_exitcode)
        WIFEXITED, WEXITSTATUS = staticmethod(os.WIFEXITED), staticmethod(os.WEXITSTATUS)
        pipe = staticmethod(lambda: (70, 71))
        close = staticmethod(lambda fd: None)
        write = staticmethod(lambda fd, data: sent.append(data) or len(data))
        fdopen = staticmethod(lambda fd, mode="r": io.BytesIO(report))

        @staticmethod
        def _exit(code):
            """stop the child with its code"""
            raise Exited(code)

    def labeller(host_root, under, fcs, fixed=(), prune=lambda p: False):
        """record the prune answers and return the case's counts"""
        seen["pruned"] = sorted(p for p in (host_root + "/bin", host_root + "/etc", host_root + "/lib 64") if prune(p))
        return dict(counts or {}, errors=[])

    fake_ns = type("Ns", (), {"fs_type": staticmethod(lambda p: 1 if tmpfs else 0),
                              "drop_to_init_caps": staticmethod(lambda: caps),
                              "enter_policy_namespace": staticmethod(lambda p, helper: (seen.__setitem__("helper", helper), enter)[1]),
                              "label_by_file_contexts": staticmethod(labeller)})
    fake_env = type("Env", (), {"stdio_to_null": staticmethod(lambda: None)})
    scope = {"os": FakeOs, "selinux_ns": fake_ns, "core": fake_env, "kmsg": logs.append, "GSI": "/gsi", "TMPFS_MAGIC": 1,
             "RHIZO_DEVICE_STATE_DIR": "/device",
             "label_device_state_dir": lambda path: device_state,
             "read_mountinfo": lambda table="/proc/self/mountinfo": None if rows is None else list(rows)}
    names = [n for n in funcs if n in (PRELABEL, "mount_points_below", "refuse_device_state_label")]
    consts = [a for a in ast.parse(src).body if isinstance(a, ast.Assign)
              and [ast.unparse(t) for t in a.targets] == ["HELPER_CAPS_EXIT"]]
    exec(compile(ast.Module(body=consts + [funcs[n] for n in names], type_ignores=[]), SRC, "exec"), scope)
    try:
        scope[PRELABEL]("/run/rhizo")
        code = None
    except Exited as e:
        code = e.args[0]
    return code, logs, seen.get("pruned"), b"".join(sent), seen.get("helper")


def status_findings(src):
    """return what lets a failure pass unnamed"""
    out = []
    pre = next((f for f in ast.parse(src).body if isinstance(f, ast.FunctionDef) and f.name == PRELABEL), None)
    if pre is not None and "ismount" in ast.unparse(pre):
        out.append(f"{PRELABEL} prunes by os.path.ismount")
    vendor = "/run/rhizo/vendor"
    rows = [("1", "0", "8:1", "/", "/"), ("2", "1", "8:1", "/var/lib/rhizo/prepared/k/bin", vendor + "/bin"),
            ("3", "1", "8:1", "/x", vendor + "/lib 64"), ("4", "1", "8:1", "/y", "/run/rhizo/vendorish")]
    clean = {"labeled": 3, "kept": 1, "unmatched": 0, "refused": 0, "failed": 0, "unusable": 0}
    for label, rows_, enter, counts, want_code, want_mark in (
            ("a clean pass", rows, None, clean, 0, "vendor-prelabel result="),
            ("a refused write", rows, None, dict(clean, refused=1), 2, "vendor-prelabel result="),
            ("a failed write", rows, None, dict(clean, failed=1), 2, "vendor-prelabel result="),
            ("no policy namespace", rows, "load-failed", clean, 1, "vendor-prelabel skipped=load-failed"),
            ("an unreadable mountinfo", None, None, clean, 1, "vendor-prelabel skipped=mountinfo-unreadable")):
        got = run_prelabel(src, 0, enter=enter, rows=rows_, counts=counts)
        if got[0] != want_code or not any(want_mark in l for l in got[1]):
            out.append(f"the prelabel child on {label} exits {got[0]} with {got[1]}, want {want_code} and {want_mark}")
        if got[4] != "relabel":
            out.append(f"the prelabel child on {label} enters the policy namespace as {got[4]!r}, want 'relabel'")
        if label == "a clean pass" and got[2] != [vendor + "/bin", vendor + "/lib 64"]:
            out.append(f"the prelabel prunes {got[2]}, want the mountinfo mount points under the tree")
        want_report = b"policy-namespace:load-failed" if enter else b"ok"
        if got[3] != want_report:
            out.append(f"the prelabel child on {label} reports {got[3]!r} for the device-state directory, want {want_report!r}")
    got = run_prelabel(src, 0, rows=None, tmpfs=True, device_state="unwritable:Read-only file system")
    if got[0] != 0 or got[3] != b"unwritable:Read-only file system":
        out.append(f"the prelabel child on a tmpfs vendor tree exits {got[0]} reporting {got[3]!r}, want 0 and the "
                   "device-state directory's label error")
    for status, report, want, refused in ((0, b"ok", None, False), (2 << 8, b"ok", "status=2", False),
                                          (9, b"", "status=-9", True), (0, b"unwritable:Invalid argument", None, True),
                                          (1 << 8, b"policy-namespace:load-failed", "status=1", True)):
        got = run_prelabel(src, 4242, status=status, report=report)
        named = [l for l in got[1] if "vendor-prelabel-failed" in l]
        if (want is None and named) or (want is not None and not any(want in l for l in named)):
            out.append(f"the parent on wait status {status} logs {got[1]}, want {want or 'no failure'}")
        refusal = [l for l in got[1] if "reason=device-state-label-failed" in l]
        if refused != (got[0] == 1 and bool(refusal)) or (refused and (report or b"no-report").decode() not in refusal[0]):
            out.append(f"the parent on wait status {status} with report {report!r} exits {got[0]} with {got[1]}, want "
                       f"{'the start refused naming the report' if refused else 'no refusal'}")
    got = run_prelabel(src, 0, rows=rows, counts=clean, caps="capbset-drop:16:1")
    if got[0] != 3 or not any("vendor-prelabel skipped=caps-failed:capbset-drop:16:1" in l for l in got[1]):
        out.append(f"the prelabel child whose capabilities will not drop exits {got[0]} with {got[1]}, want 3 and "
                   "the step named")
    got = run_prelabel(src, 4242, status=3 << 8)
    if got[0] != 1 or not any("selinuxns=refused reason=vendor-prelabel-caps-failed" in l for l in got[1]):
        out.append(f"the parent of a child whose capabilities would not drop exits {got[0]} with {got[1]}, want the "
                   "start refused by name")
    return out


def findings(src):
    """return every defect"""
    return order_findings(src) + label_findings(src) + status_findings(src)


def selftest():
    """check each defect is flagged and the real source is clean"""
    src = open(SRC).read()
    if findings(src):
        print(f"FAIL selftest: the real source is flagged: {findings(src)}")
        return 1
    waited = "    _, status = os.waitpid(pid, 0)\n"
    cases = (("no policy namespace",
              src.replace("selinux_ns.enter_policy_namespace(", "selinux_ns.state(", 1),
              "does not enter a child namespace"),
             ("another helper domain",
              src.replace('precompiled_sepolicy", "relabel")', 'precompiled_sepolicy", "label")', 1),
              "enters the policy namespace as 'label'"),
             ("no helper domain",
              src.replace('precompiled_sepolicy", "relabel")', 'precompiled_sepolicy")', 1),
              "without naming the relabel helper domain"),
             ("no call", src.replace(f"        {PRELABEL}(RUN_ROOT)", "        pass", 1), f"never calls {PRELABEL}"),
             ("a file_contexts copy", src + "\n\ndef copied(pat):\n    return re.compile(pat + r\"\\Z\")\n",
              "parses file_contexts itself"),
             ("an ignored child status", src.replace(waited, "    os.waitpid(pid, 0)\n    status = 0\n", 1),
              "want status=2"),
             ("a refusal passing as success", src.replace('result["refused"] or ', "", 1), "a refused write"),
             ("an ignored device-state report", src.replace('    if device_state != "ok":\n', '    if False:\n', 1),
              "the start refused naming the report"),
             ("a device-state label outside the namespace",
              src.replace("label_device_state_dir(RHIZO_DEVICE_STATE_DIR)", '"ok"', 1),
              "does not label the device-state directory"))
    for name, text, want in cases:
        if text == src:
            print(f"FAIL selftest: the {name} mutant changed nothing")
            return 1
        got = findings(text)
        if not any(want in f for f in got):
            print(f"FAIL selftest: the {name} mutant was not flagged ({want}): {got}")
            return 1
    print("vendor-prelabel selftest: no policy namespace, another or no helper domain, a missing call, a file_contexts "
          "copy, an ignored child status, a passed refusal, an ignored device-state report and a device-state label "
          "outside the namespace are flagged, the real source clean")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    bad = findings(open(SRC).read())
    for b in bad:
        print("FAIL", b)
    if bad:
        sys.exit(1)
    print("vendor-prelabel: the vendor tree carries init's labels before init starts")
