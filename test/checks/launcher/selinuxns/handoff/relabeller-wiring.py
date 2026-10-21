#!/usr/bin/env python3
import ast, contextlib, io, os, sys
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-relabeller-wiring")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher

bad = []
events = []

tree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/rootfs.py")).read())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_setup_cgroups_and_selinuxfs")
idx = [i for i, n in enumerate(fn.body) if isinstance(n, ast.If) and "start_relabeller" in ast.unparse(n)]
piv = [i for i, n in enumerate(fn.body) if isinstance(n, ast.If) and "pivot_root(" in ast.unparse(n.test)]
if len(idx) != 1 or len(piv) != 1 or idx[0] + 1 != piv[0]:
    bad.append(("guard placement", "one start_relabeller guard as the statement before pivot_root", idx, piv))
else:
    tail = ast.Module(body=fn.body[idx[0]:piv[0] + 1], type_ignores=[])
    code = compile(tail, "sandbox/rootfs.py", "exec")

    class FakeNs:
        """stand-in for selinux_ns"""
        unshared = False

        @staticmethod
        def state():
            """answer the case's unshared flag"""
            return {"unshared": FakeNs.unshared}

        @staticmethod
        def start_relabeller(*a):
            """record the relabeller start"""
            events.append(("start_relabeller",) + a)

        @staticmethod
        def start_view_keeper():
            """record the view keeper start"""
            events.append(("start_view_keeper",))

    class FakeEnv:
        """stand-in for core"""
        WRITE_PRIMER_SCRIPT = "writer"
        RELABELLER_DONE_FD = 42

    for unshared, holder, start in ((True, False, [("start_relabeller", "/rhizoroot", ["spec"], "writer", 42)]),
                                    (False, False, []), (False, True, [("start_view_keeper",)])):
        events.clear()
        FakeNs.unshared = unshared
        exec(code, {"selinux_ns": FakeNs, "core": FakeEnv, "NEWROOT": "/rhizoroot", "holder": holder,
                    "coldboot_primer_spec": lambda: ["spec"], "kmsg": events.append,
                    "pivot_root": lambda new, old: (events.append(("pivot_root", new, old)), True)[1], "os": os})
        want = start + [("pivot_root", "/rhizoroot", "/rhizoroot/oldroot")]
        if events != want:
            bad.append((f"unshared={unshared} holder={holder}", want, list(events)))

logs, writes = [], []
saved = (launcher.kmsg, launcher.write_primer_script, launcher.RHIZO_ENFORCING, os.environ.get("RHIZO_SELINUX_MODE"))
launcher.kmsg, launcher.write_primer_script = logs.append, lambda *a: writes.append(a)
try:
    os.environ["RHIZO_SELINUX_MODE"] = "namespace"
    got = launcher.spawn_host_primer()
    if got is not None or logs != ["RHIZO_MARKER selinuxns=host-primer-skipped"] or writes:
        bad.append(("namespace mode", "None, the skip marker only, nothing written", got, list(logs), writes))
    logs.clear()
    os.environ["RHIZO_SELINUX_MODE"] = "host"
    launcher.RHIZO_ENFORCING = False
    got = launcher.spawn_host_primer()
    if got is not None or any("host-primer-skipped" in l for l in logs) or writes:
        bad.append(("host mode, permissive", "past the namespace guard, returning at the permissive one", got, list(logs)))
finally:
    launcher.kmsg, launcher.write_primer_script, launcher.RHIZO_ENFORCING = saved[:3]
    if saved[3] is None:
        os.environ.pop("RHIZO_SELINUX_MODE", None)
    else:
        os.environ["RHIZO_SELINUX_MODE"] = saved[3]

src = open(os.path.join(LAUNCHER, "boot.py")).read()
ltree = ast.parse(src)
spawn = next(n for n in ltree.body if isinstance(n, ast.FunctionDef) and n.name == "spawn_host_primer")
if "write_primer_script(_so_ms)" not in ast.unparse(spawn) or "HOST_PRIMER_SRC" in ast.unparse(spawn):
    bad.append(("primer write reuse", "spawn_host_primer calls write_primer_script(_so_ms)", ""))
wps = next(n for n in ltree.body if isinstance(n, ast.FunctionDef) and n.name == "write_primer_script")
if "os.replace(tmp, HOST_PRIMER_PATH)" not in ast.unparse(wps):
    bad.append(("primer write", "tmp + os.replace", ""))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
