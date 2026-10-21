#!/usr/bin/env python3
import ast
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
UNIT = os.path.join(ROOT, "src", "services", "units", "boot", "policy.service")
EXEC_CONDITION = "ExecCondition=/usr/lib/rhizo/rhizo-selinux-mode --is host"

SITES = {
    "compile_sepolicy": "gated",
    "stage_vendor_tree": "gated",
    "_stage_vendor_scaffold": "gated",
    "release_host_lock_permissive": "gated",
    "acquire_host_global_phase": "gated",
    "run_sandbox": "gated",
    "prepare_tree_verb": "gated",
    "policy_only_verb": "gated",
    "enter_sandbox_init": "gated",
    "_policy_only_load": "policy-only",
    "_write_policy_loaded_state": "policy-only",
    "_verify_earlier_load": "policy-only",
    "run_kernel_domain_supervisor": "policy-only-branch",
}
POLICY_ONLY_VERB = "policy_only_verb"
POLICY_ONLY_RELAYS = {"_verify_earlier_load"}
SUPERVISOR = "run_kernel_domain_supervisor"
ENFORCE_NODE = "/sys/fs/selinux/enforce"
ENFORCE_NODE_NAME = "SELINUX_ENFORCE_NODE"


def calls(node, name):
    """return whether node is a call of the bare function name"""
    return isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == name


def reads_host_enforce(node):
    """return whether node reads the host's enforce node"""
    return isinstance(node, ast.Call) and any(
        (isinstance(a, ast.Constant) and a.value == ENFORCE_NODE) or (isinstance(a, ast.Name) and a.id == ENFORCE_NODE_NAME)
        for a in node.args)


def site_name(node):
    """return how a finding names the read at node"""
    return "policy_is_loaded()" if calls(node, "policy_is_loaded") else "a host enforce-node read"


def parents_of(tree):
    """return a child-to-parent map"""
    return {c: p for p in ast.walk(tree) for c in ast.iter_child_nodes(p)}


def chain(node, parents):
    """return node and its ancestors, innermost first"""
    out = [node]
    while out[-1] in parents:
        out.append(parents[out[-1]])
    return out


def is_not_host(node):
    """return whether node is `not host_selinux_mode()`"""
    return isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not) and calls(node.operand, "host_selinux_mode")


def ends_leaving(body):
    """return whether a statement list ends in return or raise"""
    return bool(body) and isinstance(body[-1], (ast.Return, ast.Raise))


def in_branch(node, parents, test_ok, orelse):
    """return whether node sits in a matching If branch"""
    path = chain(node, parents)
    for child, parent in zip(path, path[1:]):
        if isinstance(parent, ast.If) and test_ok(parent.test):
            if (child in parent.orelse) == orelse and (child in parent.body or child in parent.orelse):
                return True
    return False


def positive_host(test):
    """return whether the test is host_selinux_mode() or an `and` holding it"""
    return calls(test, "host_selinux_mode") or (
        isinstance(test, ast.BoolOp) and isinstance(test.op, ast.And) and any(calls(v, "host_selinux_mode") for v in test.values))


def gated(call, func, parents):
    """return whether a policy_is_loaded() call is host-gated"""
    path = chain(call, parents)
    for child, parent in zip(path, path[1:]):
        if isinstance(parent, ast.BoolOp):
            before = parent.values[:parent.values.index(child)]
            if isinstance(parent.op, ast.And) and any(calls(v, "host_selinux_mode") for v in before):
                return True
            if isinstance(parent.op, ast.Or) and any(is_not_host(v) for v in before):
                return True
    if in_branch(call, parents, positive_host, False) or in_branch(call, parents, is_not_host, True):
        return True
    top = next(n for n in path if n in func.body)
    for stmt in func.body[:func.body.index(top)]:
        if isinstance(stmt, ast.If) and is_not_host(stmt.test) and ends_leaving(stmt.body):
            return True
    return False


def sandbox_argument(call, func):
    """return the build_sandbox argument of a call, or None"""
    for k in call.keywords:
        if k.arg == "build_sandbox":
            return k.value
    names = [a.arg for a in func.args.args]
    if "build_sandbox" in names and names.index("build_sandbox") < len(call.args):
        return call.args[names.index("build_sandbox")]
    return None


def in_policy_branch(node, parents):
    """return whether node sits in the else of `if build_sandbox`"""
    return in_branch(node, parents, lambda t: isinstance(t, ast.Name) and t.id == "build_sandbox", True)


def check(source, unit_text):
    """return the findings for a launcher source and the policy unit's text"""
    tree = ast.parse(source)
    parents = parents_of(tree)
    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    bad = []

    def owner(node):
        return next((p for p in chain(node, parents) if isinstance(p, ast.FunctionDef)), None)

    for node in ast.walk(tree):
        if not (calls(node, "policy_is_loaded") or reads_host_enforce(node)):
            continue
        fn = owner(node)
        name = fn.name if fn else "<module>"
        kind = SITES.get(name)
        what = site_name(node)
        if kind is None:
            bad.append(f"line {node.lineno}: {what} in {name}(), which SITES does not list")
        elif kind == "gated" and not gated(node, fn, parents):
            bad.append(f"line {node.lineno}: {what} in {name}() is not gated on host_selinux_mode()")
        elif kind == "policy-only-branch" and not in_policy_branch(node, parents):
            bad.append(f"line {node.lineno}: {what} in {name}() is outside the `else` of `if build_sandbox`")

    only = {n for n, k in SITES.items() if k == "policy-only"}
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in only | POLICY_ONLY_RELAYS):
            continue
        fn = owner(node)
        caller = fn.name if fn else "<module>"
        if caller == POLICY_ONLY_VERB or (caller in only | POLICY_ONLY_RELAYS and node.func.id in only):
            continue
        if caller == SUPERVISOR and in_policy_branch(node, parents):
            continue
        bad.append(f"line {node.lineno}: {node.func.id}() is called from {caller}(), which --policy-only does not own")
    for node in ast.walk(tree):
        if not calls(node, SUPERVISOR):
            continue
        fn = owner(node)
        caller = fn.name if fn else "<module>"
        arg = sandbox_argument(node, funcs[SUPERVISOR]) if SUPERVISOR in funcs else None
        sandboxless = arg is not None and not (isinstance(arg, ast.Constant) and arg.value is True)
        if sandboxless and caller != POLICY_ONLY_VERB:
            bad.append(f"line {node.lineno}: {SUPERVISOR}() is called without a sandbox from {caller}(), not {POLICY_ONLY_VERB}()")
    for node in ast.walk(tree):
        if not calls(node, POLICY_ONLY_VERB):
            continue
        flagged = any(isinstance(p, ast.If) and any(isinstance(c, ast.Constant) and c.value == "--policy-only" for c in ast.walk(p.test))
                      and node in ast.walk(ast.Module(body=p.body, type_ignores=[])) for p in chain(node, parents))
        if not flagged:
            bad.append(f"line {node.lineno}: {POLICY_ONLY_VERB}() is called outside an `if` testing for --policy-only")
    for name in only | POLICY_ONLY_RELAYS | {POLICY_ONLY_VERB}:
        if name not in funcs:
            bad.append(f"{name}() is gone but SITES still lists it")
    verb = funcs.get(POLICY_ONLY_VERB)
    if verb is not None and not any(isinstance(s, ast.If) and is_not_host(s.test) and ends_leaving(s.body) for s in verb.body):
        bad.append(f"{POLICY_ONLY_VERB}() does not return first unless host_selinux_mode()")
    if EXEC_CONDITION not in unit_text.splitlines():
        bad.append(f"rhizo-policy.service lacks `{EXEC_CONDITION}`")
    return bad


FIXTURE = '''
def host_selinux_mode(): pass
def compile_sepolicy():
    if not (host_selinux_mode() and policy_is_loaded()):
        pass
def stage_vendor_tree():
    if not host_selinux_mode() or policy_is_loaded():
        pass
def release_host_lock_permissive():
    if host_selinux_mode():
        loaded = policy_is_loaded()
def acquire_host_global_phase():
    if not host_selinux_mode():
        return 1
    if policy_is_loaded():
        pass
def run_sandbox():
    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())
def _policy_only_load(slog):
    return policy_is_loaded()
def _write_policy_loaded_state(a):
    return policy_is_loaded()
def _verify_earlier_load():
    _write_policy_loaded_state(0)
    return _read_node(SELINUX_ENFORCE_NODE)
def policy_only_verb():
    if not host_selinux_mode():
        return 0
    os.path.exists(SELINUX_ENFORCE_NODE)
    _verify_earlier_load()
    _write_policy_loaded_state(1)
    run_kernel_domain_supervisor("x", build_sandbox=False)
def run_kernel_domain_supervisor(entry, build_sandbox=True):
    if build_sandbox:
        run_sandbox(entry)
    else:
        _policy_only_load(1)
        _write_policy_loaded_state(2)
        return policy_is_loaded()
def prepare_tree_verb(dest):
    enforcing = host_selinux_mode() and open("/sys/fs/selinux/enforce").read() == "1"
if len(argv) > 1 and "--policy-only" in argv:
    policy_only_verb()
'''
DISPATCH = 'if len(argv) > 1 and "--policy-only" in argv:\n    policy_only_verb()\n'
UNIT_OK = "[Service]\n" + EXEC_CONDITION + "\nExecStart=x\n"


def selftest():
    """assert each finding on fixtures, both ways"""
    bad = []

    def expect(label, source, unit, needle):
        got = check(source, unit)
        hit = any(needle in g for g in got)
        if needle is None and got:
            bad.append((label, "clean", got))
        elif needle is not None and not hit:
            bad.append((label, needle, got))

    expect("every gated form, policy-only function and unit passes clean", FIXTURE, UNIT_OK, None)
    cases = (
        ("ungated call in a gated function", "def run_sandbox():\n    gpu_mode_or_exit(policy_is_loaded())\n", "not gated"),
        ("call before its and-guard", "def run_sandbox():\n    x = policy_is_loaded() and host_selinux_mode()\n", "not gated"),
        ("call in the wrong branch of the guard", "def run_sandbox():\n    if host_selinux_mode():\n        pass\n    else:\n        policy_is_loaded()\n", "not gated"),
        ("unlisted function", "def new_site():\n    policy_is_loaded()\n", "does not list"),
        ("ungated host enforce read by literal", "def prepare_tree_verb(d):\n    open(\"/sys/fs/selinux/enforce\").read()\n", "a host enforce-node read in prepare_tree_verb() is not gated"),
        ("host enforce read by name in an unlisted function", "def new_site():\n    _read_node(SELINUX_ENFORCE_NODE)\n", "a host enforce-node read in new_site(), which SITES does not list"),
        ("supervisor read outside the policy-only else", "def run_kernel_domain_supervisor(e, build_sandbox=True):\n    policy_is_loaded()\n", "outside the `else`"),
        ("relay called from a start path", "def run_sandbox():\n    _verify_earlier_load()\n", "does not own"),
        ("policy-only function called from a start path", "def run_sandbox():\n    _policy_only_load(1)\n", "does not own"),
    )
    base = FIXTURE.split("def run_kernel_domain_supervisor")[0]
    start = "def stage_vendor_tree():\n    if not host_selinux_mode() or policy_is_loaded():\n        pass\n"
    phase = "    if not host_selinux_mode():\n        return 1\n    if policy_is_loaded():\n        pass\n"
    for label, extra, needle in cases:
        expect(label, base + extra, UNIT_OK, needle)
    mutants = (
        ("or form with the call before the not-host operand", start, "def stage_vendor_tree():\n    if policy_is_loaded() or not host_selinux_mode():\n        pass\n", "not gated"),
        ("or form without the not-host operand", start, "def stage_vendor_tree():\n    if host_selinux_mode() or policy_is_loaded():\n        pass\n", "not gated"),
        ("early-return guard that does not return", phase, "    if not host_selinux_mode():\n        pass\n    if policy_is_loaded():\n        pass\n", "not gated"),
        ("call before the early-return guard", phase, "    if policy_is_loaded():\n        pass\n    if not host_selinux_mode():\n        return 1\n", "not gated"),
        ("supervisor started without a sandbox outside the verb", "def run_sandbox():\n    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())\n",
         "def run_sandbox():\n    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())\n    run_kernel_domain_supervisor(1, build_sandbox=False)\n", "without a sandbox"),
        ("supervisor started without a sandbox by position outside the verb", "def run_sandbox():\n    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())\n",
         "def run_sandbox():\n    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())\n    run_kernel_domain_supervisor(1, False)\n", "without a sandbox"),
        ("verb dispatched without the --policy-only test", DISPATCH, "policy_only_verb()\n", "outside an `if` testing"),
        ("verb dispatched under another flag", DISPATCH, DISPATCH.replace("--policy-only", "--other"), "outside an `if` testing"),
    )
    for label, old, new, needle in mutants:
        if old not in FIXTURE:
            bad.append((label, "fixture holds the text to mutate", old))
        expect(label, FIXTURE.replace(old, new, 1), UNIT_OK, needle)
    expect("unit without the ExecCondition", FIXTURE, "[Service]\nExecStart=x\n", "lacks")
    expect("policy_only_verb without its host-mode return", FIXTURE.replace("    if not host_selinux_mode():\n        return 0\n", ""),
           UNIT_OK, "does not return first")
    return bad


def main():
    """run the real check, or the selftest"""
    if "--selftest" in sys.argv[1:]:
        bad = selftest()
    else:
        bad = check(open(LAUNCHER).read(), open(UNIT).read())
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    sys.exit(1 if bad else 0)


main()
