#!/usr/bin/env python3
import ast
import contextlib
import importlib
import inspect
import io
import os
import sys
import tempfile
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
VM = os.environ.get("RHIZO_REPO_DIR") or os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

import boot as launcher3  # noqa: E402

SAFE_CALLS = ("paths_for", "_instanced_for")

SUPERVISOR_FUNCS = (
    "_join_and_exec_init",
    "join_instance_init_cgroup",
    "instance_init_cgroup",
    "join_cgroup",
    "reclaim_cgroup_root",
    "drain_handoffs",
    "release_namespace_holder",
)

PARK_LOOP_HOST = "run_kernel_domain_supervisor"
PARK_LOOP_MARK = "drain_handoffs"


def instanced_constant_names(env_source):
    """return the names derived from SANDBOX_ID"""
    tree = ast.parse(env_source)
    tainted = {"SANDBOX_ID"}
    builders = {"_instanced", "_instanced_for"}
    changed = True
    while changed:
        changed = False
        for st in tree.body:
            if not isinstance(st, (ast.Assign, ast.AnnAssign)):
                continue
            targets = st.targets if isinstance(st, ast.Assign) else [st.target]
            names = [t.id for t in targets if isinstance(t, ast.Name)]
            if not names or st.value is None:
                continue
            used = {n.id for n in ast.walk(st.value) if isinstance(n, ast.Name)}
            if not used & (tainted | builders):
                continue
            for nm in names:
                if nm not in tainted:
                    tainted.add(nm)
                    changed = True
    return tainted


def _function_tree(fn):
    """return the syntax tree and file of fn"""
    lines, first = inspect.getsourcelines(fn)
    tree = ast.parse(textwrap.dedent("".join(lines)))
    ast.increment_lineno(tree, first - 1)
    return tree, inspect.getsourcefile(fn)


def find_park_loop(host_fn, mark=PARK_LOOP_MARK):
    """return the innermost drain_handoffs loop"""
    tree, _ = _function_tree(host_fn)
    cands = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.While):
            continue
        for sub in ast.walk(node):
            if isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name) \
                    and sub.func.id == mark:
                cands.append(node)
                break
    for c in cands:
        if not any(o is not c and o in ast.walk(c) for o in cands):
            return c
    return None


def _exempt_nodes(tree):
    """return ids of nodes under paths_for calls"""
    out = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        name = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", None)
        if name in SAFE_CALLS:
            for sub in ast.walk(node):
                out.add(id(sub))
    return out


def scan(label, filename, tree, tainted):
    """return findings for a supervisor-side region"""
    exempt = _exempt_nodes(tree)
    found = []
    for node in ast.walk(tree):
        if id(node) in exempt:
            continue
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            if node.id in tainted:
                found.append((filename, node.lineno, label, node.id,
                              "bare module constant"))
            elif node.id == "_instanced":
                found.append((filename, node.lineno, label, "_instanced()",
                              "re-derives from this process's own SANDBOX_ID"))
        elif isinstance(node, ast.Attribute):
            base = node.value
            if isinstance(base, ast.Name) and base.id == "core":
                if node.attr in tainted:
                    found.append((filename, node.lineno, label,
                                  "core." + node.attr, "module constant"))
                elif node.attr == "_instanced":
                    found.append((filename, node.lineno, label,
                                  "core._instanced()",
                                  "re-derives from this process's own SANDBOX_ID"))
    return found


def supervisor_regions(mod, funcs=SUPERVISOR_FUNCS, host=PARK_LOOP_HOST):
    """return the supervisor-side regions of mod"""
    regions = []
    for name in funcs:
        fn = getattr(mod, name, None)
        if fn is None:
            raise LookupError(
                "%s.%s is gone" % (mod.__name__, name))
        tree, filename = _function_tree(fn)
        regions.append((name + "()", filename, tree))
    host_fn = getattr(mod, host, None)
    if host_fn is None:
        raise LookupError("%s.%s() is gone" % (mod.__name__, host))
    loop = find_park_loop(host_fn)
    if loop is None:
        raise LookupError(
            "no `while` inside %s.%s() calls %s()"
            % (mod.__name__, host, PARK_LOOP_MARK))
    regions.append(("%s() park loop (line %d)" % (host, loop.lineno),
                    inspect.getsourcefile(host_fn), loop))
    return regions


def check(mod=launcher3, env_source=None):
    """return the findings for supervisor code that reads instanced constants"""
    if env_source is None:
        with open(os.path.join(REPO, "src", "androidd", "sandbox", "core.py")) as f:
            env_source = f.read()
    tainted = instanced_constant_names(env_source)
    findings = []
    for label, filename, tree in supervisor_regions(mod):
        findings.extend(scan(label, filename, tree, tainted))
    return findings, tainted


def _report(findings):
    """print each finding with its location"""
    for filename, lineno, label, what, why in sorted(findings, key=lambda f: (f[0], f[1])):
        print("%s:%d: %s reads %s (%s); use core.paths_for(instance_id)" % (filename, lineno, label, what, why))


_DEFECT_MODULE = '''\
"""a mutated copy of launcher3's supervisor side, for the checker's selftest"""
import os
from sandbox import core


def join_instance_init_cgroup(instance_id, pid, log, root_file=None, cgroup_fs=None):
    """the mutation: the joiner reads its OWN ambient record, not instance_id's"""
    path = root_file or CGROUP_ROOT_FILE
    root = open(path).read()
    target = instance_init_cgroup(root, cgroup_fs)
    return join_cgroup(target, pid, log)


def instance_init_cgroup(cgroup_root, cgroup_fs=None):
    return cgroup_root.rstrip("/") + "/init"


def join_cgroup(path, pid, log):
    return True


def reclaim_cgroup_root(path, log):
    return True


def drain_handoffs(handoff_dir, active_ids, pid_is_live=None, log=None):
    return []


def release_namespace_holder(pid, log):
    """the second mutation: a bare SANDBOX_ID on the supervisor's side"""
    log("releasing %s for instance %d" % (pid, SANDBOX_ID))


def _join_and_exec_init(pid, entry, instance_id):
    """the third mutation: core.-qualified, same defect"""
    open(core.INIT_PID_FILE, "w").write(str(pid))
    return 0


def run_kernel_domain_supervisor():
    while True:
        claimed = drain_handoffs(HANDOFF_DIR, set())
        for instance_id, pid1, hentry in claimed:
            if os.fork() == 0:
                os._exit(_join_and_exec_init(pid1, hentry, instance_id))
            os.makedirs(CGROUP_ROOT, exist_ok=True)
'''

_CLEAN_MODULE = '''\
"""the same functions, correct: every per-instance object through paths_for"""
import os
from sandbox import core


def join_instance_init_cgroup(instance_id, pid, log, root_file=None, cgroup_fs=None):
    path = root_file or core.paths_for(instance_id).cgroup_root_file
    root = open(path).read()
    target = instance_init_cgroup(root, cgroup_fs)
    return join_cgroup(target, pid, log)


def instance_init_cgroup(cgroup_root, cgroup_fs=None):
    return cgroup_root.rstrip("/") + "/init"


def join_cgroup(path, pid, log):
    return True


def reclaim_cgroup_root(path, log):
    return True


def drain_handoffs(handoff_dir, active_ids, pid_is_live=None, log=None):
    return []


def release_namespace_holder(pid, log):
    log("releasing %s" % pid)


def _join_and_exec_init(pid, entry, instance_id):
    open(core.paths_for(instance_id).init_pid_file, "w").write(str(pid))
    return 0


def run_kernel_domain_supervisor():
    while True:
        claimed = drain_handoffs(HANDOFF_DIR, set())
        for instance_id, pid1, hentry in claimed:
            if os.fork() == 0:
                os._exit(_join_and_exec_init(pid1, hentry, instance_id))
            os.makedirs(core.paths_for(instance_id).cgroup_root, exist_ok=True)
'''

_NO_LOOP_MODULE = '''\
"""the dispatch renamed out of existence -- discovery must fail, not pass"""


def join_instance_init_cgroup(instance_id, pid, log, root_file=None, cgroup_fs=None):
    return True


def instance_init_cgroup(cgroup_root, cgroup_fs=None):
    return None


def join_cgroup(path, pid, log):
    return True


def reclaim_cgroup_root(path, log):
    return True


def drain_handoffs(handoff_dir, active_ids, pid_is_live=None, log=None):
    return []


def release_namespace_holder(pid, log):
    pass


def _join_and_exec_init(pid, entry, instance_id):
    return 0


def run_kernel_domain_supervisor():
    while True:
        pass
'''


def _scratch_module(tmp, name, text):
    """write a module under a temporary directory and return it imported"""
    path = os.path.join(tmp, name + ".py")
    with open(path, "w") as f:
        f.write(text)
    if tmp not in sys.path:
        sys.path.insert(0, tmp)
    return importlib.import_module(name)


def selftest():
    """run the supervisor-instance-scope selftest cases"""
    bad = []

    def case(name, fn):
        """run a case and record its error as a failure"""
        try:
            fn()
        except Exception as e:
            bad.append("%s: %s" % (name, e))

    with open(os.path.join(REPO, "src", "androidd", "sandbox", "core.py")) as f:
        env_source = f.read()

    def t_names_are_derived_not_listed():
        """test the constant names come from sandbox/core.py"""
        got = instanced_constant_names(env_source)
        for must in ("SANDBOX_ID", "RUN_ROOT", "CGROUP_ROOT", "INIT_PID_FILE",
                     "CGROUP_ROOT_FILE", "NETBRIDGED_UNIT", "RHIZO_DEVICE_STATE_DIR"):
            assert must in got, "%s missing from %s" % (must, sorted(got))
        for never in ("G_PID_FILE", "SUPERVISOR_STATE", "SUPERVISOR_LOG",
                      "HANDOFF_DIR", "HOST_PRIMER_PATH", "RHIZO_LOG_DIR"):
            assert never not in got, "%s is host-global and must not be tainted" % never
        mutated = env_source + (
            '\nFUTURE_PER_INSTANCE = _instanced("/run/rhizo-future")\n'
            'FUTURE_CHILD = FUTURE_PER_INSTANCE + "/sock"\n')
        got2 = instanced_constant_names(mutated)
        assert "FUTURE_PER_INSTANCE" in got2 and "FUTURE_CHILD" in got2, sorted(got2 - got)
        mutated2 = env_source + '\nFUTURE_HOST_GLOBAL = "/root/.rhizo_future"\n'
        assert "FUTURE_HOST_GLOBAL" not in instanced_constant_names(mutated2)

    def t_defect_copy_is_flagged():
        """test check flags the mutated supervisor module"""
        with tempfile.TemporaryDirectory() as tmp:
            mod = _scratch_module(tmp, "sup_scope_defect", _DEFECT_MODULE)
            findings, _ = check(mod, env_source)
            by_what = {}
            for filename, lineno, label, what, _why in findings:
                by_what.setdefault(what, []).append((label, lineno))
            for what, in_label in (("CGROUP_ROOT_FILE", "join_instance_init_cgroup()"),
                                   ("SANDBOX_ID", "release_namespace_holder()"),
                                   ("core.INIT_PID_FILE", "_join_and_exec_init()"),
                                   ("CGROUP_ROOT", "run_kernel_domain_supervisor() park loop")):
                assert what in by_what, \
                    "%s was not flagged; flagged: %s" % (what, sorted(by_what))
                assert any(in_label in lbl for lbl, _ in by_what[what]), \
                    "%s flagged, but not in %s: %s" % (what, in_label, by_what[what])
            for filename, lineno, _l, _w, _y in findings:
                assert filename.endswith("sup_scope_defect.py"), filename
                assert lineno > 0, lineno

    def t_correct_copy_is_not_flagged():
        """test check passes the corrected supervisor module"""
        with tempfile.TemporaryDirectory() as tmp:
            mod = _scratch_module(tmp, "sup_scope_clean", _CLEAN_MODULE)
            findings, _ = check(mod, env_source)
            assert findings == [], findings

    def t_lost_dispatch_is_an_error_not_a_pass():
        """test check errors on a missing park loop"""
        with tempfile.TemporaryDirectory() as tmp:
            mod = _scratch_module(tmp, "sup_scope_noloop", _NO_LOOP_MODULE)
            try:
                check(mod, env_source)
            except LookupError as e:
                assert "park loop" in str(e) or "drain_handoffs" in str(e), e
            else:
                assert False, "a module with no dispatch loop passed"

    def t_real_park_loop_is_found():
        """test find_park_loop locates the launcher3 loop"""
        loop = find_park_loop(launcher3.run_kernel_domain_supervisor)
        assert loop is not None, "the real park loop was not found"
        with open(inspect.getsourcefile(launcher3.run_kernel_domain_supervisor)) as f:
            src = ast.get_source_segment(f.read(), loop) or ""
        body = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
        for must in ("drain_handoffs(", "os.fork()", "_join_and_exec_init("):
            assert must in body, "the located loop does not contain %s" % must

    def t_real_tree_passes():
        """check that the real tree has no findings"""
        findings, _ = check()
        assert findings == [], "\n".join(
            "%s:%d: %s reads %s" % (f[0], f[1], f[2], f[3]) for f in findings)

    def t_the_real_file_mutated_back_to_the_defect_is_flagged():
        """test check flags the mutated launcher3.py"""
        real = inspect.getsourcefile(launcher3)
        with open(real) as f:
            src = f.read()
        anchor = "path = root_file or core.paths_for(instance_id).cgroup_root_file"
        assert src.count(anchor) == 1, (
            "the mutation anchor occurs %d times, not once" % src.count(anchor))
        mutated = src.replace(anchor, "path = root_file or CGROUP_ROOT_FILE")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "launcher3_mutated.py")
            with open(path, "w") as f:
                f.write(mutated)
            if tmp not in sys.path:
                sys.path.insert(0, tmp)
            with contextlib.redirect_stdout(io.StringIO()):
                mod = importlib.import_module("launcher3_mutated")
            findings, _ = check(mod, env_source)
            hit = [f for f in findings
                   if f[3] == "CGROUP_ROOT_FILE"
                   and "join_instance_init_cgroup" in f[2]]
            assert hit, "the mutated real file was not flagged: %s" % (findings,)
            assert len(findings) == 1, \
                "the one-line mutation gave %d findings, want 1: %s" % (len(findings), findings)
            anchor_line = src[:src.index(anchor)].count("\n") + 1
            assert hit[0][1] == anchor_line, "the reported line is not the real one (%d): %s" % (anchor_line, hit)

    case("names are derived from sandbox/core.py, not listed here", t_names_are_derived_not_listed)
    case("a mutated supervisor-side copy is flagged", t_defect_copy_is_flagged)
    case("the correct paths_for() form is not flagged", t_correct_copy_is_not_flagged)
    case("a vanished dispatch fails rather than passing", t_lost_dispatch_is_an_error_not_a_pass)
    case("the real park loop is located structurally", t_real_park_loop_is_found)
    case("the real tree is clean", t_real_tree_passes)
    case("the real file mutated back to the defect is flagged",
         t_the_real_file_mutated_back_to_the_defect_is_flagged)

    for b in bad:
        print("selftest FAIL: " + b)
    if bad:
        return False
    print("check-supervisor-instance-scope selftest: 7 cases passed")
    return True


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    try:
        findings, tainted = check()
    except LookupError as e:
        print("check-supervisor-instance-scope: FAIL -- %s" % e)
        sys.exit(1)
    if findings:
        _report(findings)
        print("check-supervisor-instance-scope: FAIL -- %d supervisor-side "
              "reference(s) to an instance-scoped constant" % len(findings))
        sys.exit(1)
    regions = supervisor_regions(launcher3)
    print("check-supervisor-instance-scope: OK -- %d supervisor-side regions, "
          "0 references to any of the %d instance-scoped core constants"
          % (len(regions), len(tainted)))
