#!/usr/bin/env python3
import argparse
import ast
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent
LAUNCHER = REPO / "src" / "androidd" / "boot.py"
RESET_NAME = "_reset_delegated_controllers"
CLEAR_NAME = "clear_delegated_controllers"


def _func(tree, name):
    """return the function definition with a name in a tree, or None"""
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def _calls(node, name):
    """return the calls to a name"""
    out = []
    for sub in ast.walk(node):
        if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name) and sub.func.id == name:
            out.append(sub)
    return out


def check_stop_resets_on_every_path(src):
    """check androidd_stop resets controllers on every return"""
    bad = []
    tree = ast.parse(src)
    fn = _func(tree, "androidd_stop")
    if fn is None:
        return ["androidd_stop() is not in this file at all"]
    guard = None
    for stmt in fn.body:
        if isinstance(stmt, ast.Try) and any(_calls(h, RESET_NAME) for h in stmt.finalbody):
            guard = stmt
            break
    if guard is None:
        bad.append(f"androidd_stop() has no try/finally calling {RESET_NAME}()")
        return bad
    reset_fn = _func(fn, RESET_NAME)
    if reset_fn is None:
        bad.append(f"androidd_stop()'s finally calls {RESET_NAME}(), which is not defined in it")
    elif not _calls(reset_fn, CLEAR_NAME):
        bad.append(f"{RESET_NAME}() never calls {CLEAR_NAME}()")
    nested = {id(n) for d in ast.walk(fn)
              if isinstance(d, ast.FunctionDef) and d is not fn
              for n in ast.walk(d)}
    inside = {id(n) for n in ast.walk(guard)}
    for node in ast.walk(fn):
        if not isinstance(node, ast.Return) or id(node) in nested:
            continue
        if id(node) in inside:
            continue
        euid_guarded = any(
            isinstance(anc, ast.If) and "geteuid" in ast.dump(anc.test)
            and id(node) in {id(n) for n in ast.walk(anc)}
            for anc in ast.walk(fn) if isinstance(anc, ast.If))
        if euid_guarded:
            continue
        bad.append(f"androidd_stop() returns at line {node.lineno}, outside the try whose "
                   f"finally clears the controllers")
    return bad


def check_start_clears_before_join(src):
    """check join_cgroup calls follow a clear call"""
    bad = []
    tree = ast.parse(src)
    stop = _func(tree, "androidd_stop")
    stop_ids = {id(n) for n in ast.walk(stop)} if stop else set()
    start_side = [c for c in _calls(tree, CLEAR_NAME) if id(c) not in stop_ids]
    if not start_side:
        bad.append(f"nothing outside androidd_stop() calls {CLEAR_NAME}()")

    lines = src.splitlines()
    owner = {}
    for f in ast.walk(tree):
        if isinstance(f, ast.FunctionDef):
            for n in ast.walk(f):
                owner.setdefault(id(n), f)

    def _exempt(lineno):
        """return whether a comment above a line marks it exempt from the clear"""
        i = lineno - 2
        while i >= 0 and (lines[i].strip().startswith("#") or not lines[i].strip()):
            if "cgroup-clear-exempt:" in lines[i]:
                return True
            i -= 1
        return False

    def _blocks_of(stmt):
        """yield each statement list nested in a statement"""
        for _f, value in ast.iter_fields(stmt):
            if isinstance(value, list) and value and isinstance(value[0], ast.stmt):
                yield value

    def _own_calls(stmt, name):
        """return calls outside the statement's nested blocks"""
        nested = set()
        for block in _blocks_of(stmt):
            for s in block:
                nested |= {id(n) for n in ast.walk(s)}
        return [c for c in _calls(stmt, name) if id(c) not in nested]

    def _scan(block, seen_clear):
        """record a finding for each join not preceded by a clear in a block"""
        for stmt in block:
            for call in _own_calls(stmt, "join_cgroup"):
                if seen_clear or _exempt(call.lineno):
                    continue
                fn_of = owner.get(id(call))
                where = f" (in {fn_of.name}())" if fn_of else ""
                bad.append(f"join_cgroup() at line {call.lineno}{where} has no {CLEAR_NAME}() "
                           "before it on this path and no `cgroup-clear-exempt:` reason")
            for nested_block in _blocks_of(stmt):
                _scan(nested_block, seen_clear)
            if _own_calls(stmt, CLEAR_NAME):
                seen_clear = True

    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            _scan(node.body, False)
    return bad


def check_source(path=LAUNCHER):
    """return the findings for the launcher source's stop and start paths"""
    src = path.read_text()
    return check_stop_resets_on_every_path(src) + check_start_clears_before_join(src)



BROKEN_STOP = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    def _reset_delegated_controllers():
        pass
    if not stack_up:
        _reset_delegated_controllers()
        return 0
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        return 1
    return 1
'''

STRAY_RETURN_STOP = '''
def androidd_stop():
    try:
        if not stack_up:
            return 0
        return 1
    finally:
        _reset_delegated_controllers()
    return 2
'''

FIXED_STOP = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    def _reset_delegated_controllers():
        return clear_delegated_controllers(cg, kmsg)
    try:
        if not stack_up:
            return 0
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            return 1
        return 1
    finally:
        _reset_delegated_controllers()
'''

HOLLOW_RESET_STOP = '''
def androidd_stop():
    def _reset_delegated_controllers():
        kmsg("pretending")
    try:
        return 0
    finally:
        _reset_delegated_controllers()
'''

EARLY_RETURN_STOP = '''
def androidd_stop():
    if os.geteuid() != 0:
        return 1
    def _reset_delegated_controllers():
        return clear_delegated_controllers(cg, kmsg)
    reclaim_cgroup_root(CGROUP_ROOT, kmsg)
    if os.environ.get("RHIZO_SKIP"):
        return 0
    try:
        return 0
    finally:
        _reset_delegated_controllers()
'''

BROKEN_START = '''
def prepare_host_and_data():
    os.makedirs(CGROUP_ROOT, exist_ok=True)
    join_cgroup(CGROUP_ROOT, os.getpid(), kmsg)
'''

BROKEN_START_CONDITIONAL = '''
def run_sandbox():
    if not join_cgroup(_CGROUP_ROOT, os.getpid(), kmsg):
        os._exit(1)
'''

EXEMPT_START_CONDITIONAL = '''
def run_sandbox():
    # cgroup-clear-exempt: prepare_host_and_data() cleared this root before g forked
    if not join_cgroup(_CGROUP_ROOT, os.getpid(), kmsg):
        os._exit(1)
'''

SIBLING_BRANCH_START = '''
def prepare_host_and_data():
    if under_unit:
        os.makedirs(cgroup_root, exist_ok=True)
        clear_delegated_controllers(cgroup_root, kmsg)
        join_cgroup(cgroup_root, os.getpid(), kmsg)
    else:
        os.makedirs(CGROUP_ROOT, exist_ok=True)
        join_cgroup(CGROUP_ROOT, os.getpid(), kmsg)
'''

FIXED_START = '''
def prepare_host_and_data():
    os.makedirs(CGROUP_ROOT, exist_ok=True)
    clear_delegated_controllers(CGROUP_ROOT, kmsg)
    join_cgroup(CGROUP_ROOT, os.getpid(), kmsg)
'''


def _fixture(tmp, controllers="memory cpu", procs=""):
    """create the android cgroup fixture tree"""
    root = pathlib.Path(tmp) / "android"
    for sub in (root, root / "apps", root / "system"):
        sub.mkdir(parents=True, exist_ok=True)
        (sub / "cgroup.subtree_control").write_text(controllers)
        (sub / "cgroup.procs").write_text(procs)
    return root


def _selftest():
    """run the cgroup teardown checks on fixtures"""
    import importlib.util
    failures = []

    def check(label, cond):
        """print a selftest line and record the label when the condition is false"""
        print(f"  selftest {'OK' if cond else 'FAILED'}: {label}")
        if not cond:
            failures.append(label)

    check("a stop that resets per-branch with no finally is caught",
          any("no try/finally" in b for b in check_stop_resets_on_every_path(BROKEN_STOP)))
    check("a stray return outside the finally is caught",
          any("outside the try" in b for b in check_stop_resets_on_every_path(STRAY_RETURN_STOP)))
    check("a stop whose every return is inside the try is accepted",
          check_stop_resets_on_every_path(FIXED_STOP) == [])
    check("a start joining without clearing first is caught",
          any("has no clear_delegated_controllers" in b for b in check_start_clears_before_join(BROKEN_START)))
    check("a start that clears before joining is accepted",
          check_start_clears_before_join(FIXED_START) == [])
    check("a reset that calls nothing is caught, however right its name looks",
          any("never calls clear_delegated_controllers" in b
              for b in check_stop_resets_on_every_path(HOLLOW_RESET_STOP)))
    check("a return added above the try, where cgroup work already happened, is caught",
          any("outside the try" in b for b in check_stop_resets_on_every_path(EARLY_RETURN_STOP)))
    check("a join written as a condition is caught too",
          any("has no clear_delegated_controllers" in b
              for b in check_start_clears_before_join(BROKEN_START_CONDITIONAL)))
    check("a clear on the OTHER branch does not cover this one",
          any("on this path" in b for b in check_start_clears_before_join(SIBLING_BRANCH_START)))
    check("a join carrying an exemption reason is accepted",
          not any("has no clear_delegated_controllers" in b
                  for b in check_start_clears_before_join(EXEMPT_START_CONDITIONAL)))
    check("a stop with no try/finally at all is caught",
          any("no try/finally" in b for b in
              check_stop_resets_on_every_path("def androidd_stop():\n    return 0\n")))

    if str(LAUNCHER.parent) not in sys.path:
        sys.path.insert(0, str(LAUNCHER.parent))
    spec = importlib.util.spec_from_file_location("_l3_under_test", LAUNCHER)
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception as e:                                  # noqa: BLE001
        check(f"launcher3.py imports for the fixture half ({e})", False)
        return failures

    written = []

    def fake_cgroup_write(path, value):
        """record a cgroup write and fail for paths that name a failure"""
        written.append((path, value))
        if "FAILS" in path:
            raise OSError(16, "Device or resource busy")
        pathlib.Path(path).write_text("")

    mod.cgroup_write = fake_cgroup_write
    logs = []
    tmp = tempfile.mkdtemp()
    try:
        root = _fixture(tmp)
        ok = mod.clear_delegated_controllers(str(root), logs.append)
        check("a quiet tree is cleared", ok)
        check("every cgroup was cleared, root included",
              {pathlib.Path(p).parent.name for p, _ in written} == {"android", "apps", "system"})
        check("children are cleared before the root they hang off",
              [pathlib.Path(p).parent.name for p, _ in written][-1] == "android")
        check("the file really is empty afterwards",
              (root / "cgroup.subtree_control").read_text() == "")
        check("the write disables the controllers, never enables them",
              written and all(v == "-memory -cpu" for _, v in written))

        written.clear(); logs.clear()
        root = _fixture(tmp + "/live", procs="4242\n")
        ok = mod.clear_delegated_controllers(str(root), logs.append)
        check("a live stack is refused", ok is False)
        check("nothing was written under a live stack", written == [])
        check("the refusal says a process is still there",
              any("still here" in m for m in logs))

        written.clear(); logs.clear()
        ok = mod.clear_delegated_controllers(tmp + "/does-not-exist", logs.append)
        check("a tree that cannot be read is refused, not treated as empty", ok is False)
        check("the refusal distinguishes unreadable from empty",
              any("not an empty stack" in m or "cannot walk" in m for m in logs))

        written.clear(); logs.clear()
        root = _fixture(tmp + "/FAILS")
        ok = mod.clear_delegated_controllers(str(root), logs.append)
        check("a failing write fails the whole reset", ok is False)
        check("the walk continues past a failing write instead of stopping at it",
              len(written) == 3)

        written.clear(); logs.clear()
        root = _fixture(tmp + "/skipme", procs="777\n")
        ok = mod.clear_delegated_controllers(str(root), logs.append, skip=(777,))
        check("a skipped pid does not count as a live stack", ok is True)

        written.clear(); logs.clear()
        sup_proc = subprocess.Popen(["sleep", "60"])
        sup_file = pathlib.Path(tmp) / "g_pid"
        sup_file.write_text(mod.supervisor_record(sup_proc.pid))
        mod.G_PID_FILE = str(sup_file)
        root = _fixture(tmp + "/withsup", procs="%d\n" % sup_proc.pid)
        ok = mod.clear_delegated_controllers(str(root), logs.append)
        check("the parked supervisor does not block the clear", ok is True)
        mod.G_PID_FILE = str(sup_file.parent / "absent")
        root = _fixture(tmp + "/nosup", procs="%d\n" % sup_proc.pid)
        ok = mod.clear_delegated_controllers(str(root), logs.append)
        check("any other process still blocks it", ok is False)
        sup_proc.kill()
        sup_proc.wait()

        check("cgroup_tree_pids tells unreadable (None) from empty ([])",
              mod.cgroup_tree_pids(tmp + "/nope") is None
              and mod.cgroup_tree_pids(str(_fixture(tmp + "/empty"))) == [])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return failures


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        print("check-cgroup-teardown --selftest")
        failures = _selftest()
        if failures:
            print(f"check-cgroup-teardown --selftest: FAILED ({len(failures)})")
            return 1
        print("check-cgroup-teardown --selftest: PASSED")
        return 0
    bad = check_source()
    for b in bad:
        print(f"check-cgroup-teardown: {b}")
    if bad:
        print(f"check-cgroup-teardown: FAILED ({len(bad)})")
        return 1
    print("check-cgroup-teardown: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
