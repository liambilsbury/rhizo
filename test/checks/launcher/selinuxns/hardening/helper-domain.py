#!/usr/bin/env python3
import ast
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "..", "src", "androidd"))
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-helper-domain")
MODULES = ("sandbox/selinux_ns.py", "sandbox/rootfs.py", "boot.py")
HELPERS = {"stage", "relabel", "label"}
PASSING = {"_enter_compiled_policy_namespace", "_in_policy_namespace"}
NS = "sandbox/selinux_ns.py"


def read_sources():
    """return the text of each launcher module"""
    return {name: open(os.path.join(LAUNCHER, name)).read() for name in MODULES}


def called(node):
    """return the dotted name a call node calls"""
    return ast.unparse(node.func)


def calls_in(node):
    """return the call nodes under node in source order"""
    return sorted((c for c in ast.walk(node) if isinstance(c, ast.Call)), key=lambda c: (c.lineno, c.col_offset))


def function(tree, name):
    """return the top-level function called name, or None"""
    return next((f for f in tree.body if isinstance(f, ast.FunctionDef) and f.name == name), None)


def nested(fn, name):
    """return the function called name defined inside fn, or None"""
    return next((f for f in ast.walk(fn) if isinstance(f, ast.FunctionDef) and f.name == name), None) if fn else None


def line_of(fn, wanted):
    """return the line of the first call whose name ends with wanted, or None"""
    return next((c.lineno for c in calls_in(fn) if called(c).split(".")[-1] == wanted), None) if fn else None


def naming_findings(srcs):
    """return the calls that enter a policy namespace without naming a helper"""
    out = []
    for module, text in srcs.items():
        tree = ast.parse(text)
        for fn in [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)]:
            for call in calls_in(fn):
                name = called(call).split(".")[-1]
                if name not in PASSING | {"enter_policy_namespace"} or fn.name == name:
                    continue
                helper = call.args[-1] if call.args else None
                params = {a.arg for a in fn.args.args}
                if name == "enter_policy_namespace" and len(call.args) != 2:
                    out.append(f"{module} {fn.name}: enter_policy_namespace is called with {len(call.args)} arguments")
                elif helper is None:
                    out.append(f"{module} {fn.name}: {name} names no helper")
                elif isinstance(helper, ast.Constant):
                    if helper.value not in HELPERS:
                        out.append(f"{module} {fn.name}: {name} names the helper {helper.value!r}")
                elif ast.unparse(helper) == "IN_ANDROID_POLICY_HELPER[verb]":
                    continue
                elif not (isinstance(helper, ast.Name) and helper.id in params):
                    out.append(f"{module} {fn.name}: {name} takes its helper from {ast.unparse(helper)}")
    return out


def entry_findings(srcs):
    """return what lets a helper run as kernel"""
    out = []
    tree = ast.parse(srcs[NS])
    enter = function(tree, "enter_policy_namespace")
    if enter is None:
        return ["sandbox/selinux_ns.py has no enter_policy_namespace"]
    order = [called(c).split(".")[-1] for c in calls_in(enter)]
    steps = [n for n in order if n in ("setcon_request", "unshare_namespace", "load_namespace_policy",
                                       "enter_helper_domain")]
    if steps != ["setcon_request", "unshare_namespace", "load_namespace_policy", "enter_helper_domain"]:
        out.append(f"enter_policy_namespace runs {steps}, want the request built, the unshare, the load, then the setcon")
    start, stop = order.index("load_namespace_policy") if "load_namespace_policy" in order else None, None
    if start is not None and "enter_helper_domain" in order:
        stop = order.index("enter_helper_domain")
        between = order[start + 1:stop]
        if between:
            out.append(f"enter_policy_namespace runs {between} between the load and the setcon")
    returns = [n for n in ast.walk(enter) if isinstance(n, ast.Return)]
    if not any("helper-domain:" in ast.unparse(r) for r in returns):
        out.append("enter_policy_namespace returns no helper-domain reason for a refused setcon")
    after_load = function(tree, "_relabel_after_load")
    run = function(tree, "run_relabeller")
    hook = nested(run, "on_load")
    if after_load is None or hook is None:
        out.append("sandbox/selinux_ns.py has no _relabel_after_load and run_relabeller.on_load to test")
        return out
    loop_end = max((n.end_lineno for n in ast.walk(after_load) if isinstance(n, ast.While)), default=0)
    hook_line = next((c.lineno for c in calls_in(after_load) if called(c) == "on_load" and c.lineno > loop_end), None)
    first_log = next((c.lineno for c in calls_in(after_load) if called(c) == "kmsg" and c.lineno > loop_end), None)
    if hook_line is None or first_log is None or not hook_line < first_log:
        out.append("_relabel_after_load does not call on_load before its first log line after the load")
    polls = [c for c in calls_in(after_load) if called(c) == "attr_reader"]
    params = {a.arg: ast.unparse(d) for a, d in zip(after_load.args.args[-len(after_load.args.defaults):],
                                                    after_load.args.defaults)}
    if params.get("attr_reader") != "current_context" or not polls:
        out.append(f"_relabel_after_load polls with {params.get('attr_reader')}, want current_context")
    if any(called(c).split(".")[-1] in ("open", "host_context") for c in calls_in(after_load)
           if c.lineno > loop_end and c.lineno < (first_log or 0)):
        out.append("_relabel_after_load opens a file between the load and the setcon")
    fork_line, setcon_line = line_of(hook, "start_label_service"), line_of(hook, "enter_helper_domain")
    if fork_line is None or setcon_line is None or not fork_line < setcon_line:
        out.append("run_relabeller forks the label service after its own setcon, or not in its load hook")
    after_hook = [called(c) for c in calls_in(run) if c.lineno > hook.end_lineno]
    if "_release_label_service" not in " ".join(after_hook):
        out.append("run_relabeller does not release the label service after the done byte")
    if "_write_done" not in after_hook or after_hook.index("_write_done") > after_hook.index("_release_label_service"):
        out.append("run_relabeller releases the label service before it writes the done byte")
    serve = function(tree, "_serve_labels")
    order = [called(c).split(".")[-1] for c in calls_in(serve)] if serve else []
    want = ["setns", "_drop_privileges", "enter_label_domain", "recv", "send"]
    if [n for n in order if n in want][:5] != want:
        out.append(f"_serve_labels runs {[n for n in order if n in want]}, want {want}")
    if any(isinstance(n, (ast.Import, ast.ImportFrom)) and any(a.name.split(".")[0] == "threading" for a in n.names)
           for n in ast.walk(tree)):
        out.append("sandbox/selinux_ns.py imports threading, whose helpers a setcon cannot enter")
    return out


def compile_findings(srcs):
    """return the policy builds missing the helper domains"""
    out = []
    builds = [c for c in calls_in(ast.parse(srcs["boot.py"])) if called(c) == "selinux_policy.build"]
    if not builds:
        return ["boot.py builds no policy"]
    for call in builds:
        keywords = {k.arg: ast.unparse(k.value) for k in call.keywords}
        if keywords.get("namespace") != "not host_selinux_mode()":
            out.append(f"boot.py:{call.lineno} builds a policy with namespace={keywords.get('namespace')}")
    sys.path.insert(0, LAUNCHER)
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        from sandbox import selinux_policy
    template = open(os.path.join(LAUNCHER, "guest", "sepolicy", "policy.cil")).read()
    for namespace in (True, False):
        text = selinux_policy.render(template, "", lambda *wanted: "", namespace=namespace)
        has = all(f"(type {t})" in text for t in ("rhizo_ns_stage", "rhizo_ns_relabel", "rhizo_ns_label"))
        if has != namespace:
            out.append(f"the {'namespace' if namespace else 'host'} render {'lacks' if namespace else 'carries'} "
                       "the helper domains")
    return out


def load_module(text, name):
    """load selinux_ns from text"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, f"{name}.py")
        with open(path, "w") as f:
            f.write(text)
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(module)
    return module


def behavior_findings(srcs):
    """return the enter_policy_namespace behavior findings"""
    ns = load_module(srcs[NS], "rhizo_selinuxns_under_check")
    out = []

    def run(setcon, load=None, host=False, helper="relabel"):
        """call enter_policy_namespace on fakes"""
        events = []
        saved = (ns.unshare_namespace, ns.load_namespace_policy, ns.enter_helper_domain, os.environ.get("RHIZO_SELINUX_MODE"))
        ns.unshare_namespace = lambda state_file=None: events.append("unshare")
        ns.load_namespace_policy = lambda policy: (events.append("load"), load)[1]
        ns.enter_helper_domain = lambda request, context: (events.append(("setcon", context)), setcon)[1]
        os.environ["RHIZO_SELINUX_MODE"] = "host" if host else "namespace"
        try:
            return ns.enter_policy_namespace("/policy", helper), events
        finally:
            ns.unshare_namespace, ns.load_namespace_policy, ns.enter_helper_domain = saved[:3]
            if saved[3] is None:
                os.environ.pop("RHIZO_SELINUX_MODE", None)
            else:
                os.environ["RHIZO_SELINUX_MODE"] = saved[3]

    for helper, context in (("stage", b"u:r:rhizo_ns_stage:s0"), ("relabel", b"u:r:rhizo_ns_relabel:s0"),
                            ("label", b"u:r:rhizo_ns_label:s0")):
        got = run("", helper=helper)
        if got != (None, ["unshare", "load", ("setcon", context)]):
            out.append(f"the {helper} helper enters {got}, want the unshare, the load, then {context!r}")
    got = run("setcon:13")
    if got[0] != "helper-domain:setcon:13":
        out.append(f"a refused setcon returns {got[0]!r}, want 'helper-domain:setcon:13'")
    got = run("setcon:22")
    if got[0] != "helper-domain:setcon:22":
        out.append(f"an undefined helper type returns {got[0]!r}, want 'helper-domain:setcon:22'")
    got = run("", load="policy-load:22")
    if got != ("policy-load:22", ["unshare", "load"]):
        out.append(f"a failed load gives {got}, want the load's reason and no setcon")
    got = run("setcon:13", host=True)
    if got != (None, ["unshare", "load"]):
        out.append(f"host mode gives {got}, want the load alone and no setcon")
    try:
        ns.enter_policy_namespace("/policy", "kernel")
        out.append("an unknown helper name entered a namespace")
    except KeyError:
        pass
    events = []
    saved = (ns.os.unshare, ns.mount, ns.core.loop_attach, ns.enter_policy_namespace)
    ns.os.unshare = lambda flags: None
    ns.mount = lambda *a, **k: True
    ns.core.loop_attach = lambda *a, **k: ("/dev/loop9", os.open(os.devnull, os.O_RDONLY))
    ns.enter_policy_namespace = lambda policy, helper: "helper-domain:setcon:13"
    with tempfile.TemporaryDirectory() as work:
        os.makedirs(f"{work}/compile/system")

        def fake_run(argv, **kw):
            """answer the compile and record any other command"""
            if argv[-1] == "prepare-sepolicy":
                return subprocess.CompletedProcess(argv, 0, f"PREPARE_SEPOLICY_OK cache={work}/p\n", "")
            events.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        try:
            why = ns.stage_gsi_labeled(f"{work}/system.img", f"{work}/dest", work, "/l/launcher3.py", run=fake_run)
        finally:
            ns.os.unshare, ns.mount, ns.core.loop_attach, ns.enter_policy_namespace = saved
    if why != "helper-domain:setcon:13" or events:
        out.append(f"stage-gsi-labeled returned {why!r} after a refused setcon and ran {events}, want the reason "
                   "and no cp")
    return out


def findings(srcs):
    """return every finding"""
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        behavior = behavior_findings(srcs)
    return naming_findings(srcs) + entry_findings(srcs) + compile_findings(srcs) + behavior


def mutate(srcs, name, old, new, first_only=False):
    """return srcs with old replaced by new in a module"""
    text = srcs[name]
    if text.count(old) != 1 and not (first_only and text.count(old) > 1):
        raise SystemExit(f"helper-domain selftest: {old!r} appears {text.count(old)} times in {name}")
    return dict(srcs, **{name: text.replace(old, new, 1)})


def selftest():
    """flag each mutant and pass the real modules"""
    srcs = read_sources()
    real = findings(srcs)
    if real:
        print("FAIL selftest: the real modules have findings:", *real, sep="\n  ")
        return 1
    cases = (
        ("a caller with no helper", mutate(srcs, "sandbox/rootfs.py", 'precompiled_sepolicy", "relabel")',
                                    'precompiled_sepolicy")'), "is called with 1 arguments"),
        ("a caller with an unknown helper", mutate(srcs, "boot.py", 'ns_policy, lambda: _stage_prepared_tree(tree_part), "relabel")',
                                            'ns_policy, lambda: _stage_prepared_tree(tree_part), "kernel")'),
         "names the helper 'kernel'"),
        ("a swallowed setcon error", mutate(srcs, NS, '    return f"helper-domain:{why}" if why else None\n',
                                            "    return None\n", first_only=True), "refused setcon returns"),
        ("a log write before the setcon", mutate(srcs, NS, "    why = enter_helper_domain(request, context)\n",
                                                 '    kmsg("entering")\n    why = enter_helper_domain(request, context)\n'),
         "between the load and the setcon"),
        ("a request built after the load", mutate(
            mutate(srcs, NS, "    request = setcon_request(context)\n", ""), NS,
            "    why = enter_helper_domain(request, context)\n",
            "    request = setcon_request(context)\n    why = enter_helper_domain(request, context)\n"),
         "want the request built"),
        ("a setcon in host mode", mutate(srcs, NS, "    if why or not in_domain:\n", "    if why:\n"),
         "host mode gives"),
        ("a poll that opens a file", mutate(srcs, NS, "attr_reader=current_context, sleep", "attr_reader=host_context, sleep"),
         "want current_context"),
        ("a service forked after the relabeller's setcon", mutate(
            srcs, NS, """        nonlocal release
        if labels is not None:
            try:
                start_label_service(labels[0], mntns_fd, labels[1], release)
            except OSError as e:
                _send_label_error(labels[0], f"fork:{e.errno}")
                release[0].close()
                release[1].close()
                release = None
        why = enter_helper_domain(request, HELPER_CONTEXTS["relabel"])
""", """        nonlocal release
        why = enter_helper_domain(request, HELPER_CONTEXTS["relabel"])
        if labels is not None:
            start_label_service(labels[0], mntns_fd, labels[1], release)
"""), "forks the label service after its setcon"),
        ("a hook after the first log line", mutate(
            srcs, NS, """    if on_load is not None:
        why = on_load()
        if why:
            return failed(why)
    kmsg(f"RHIZO_MARKER selinuxns=wait-load ctx={ctx!r} t={time.time() - t0:.2f}s")
""", """    kmsg(f"RHIZO_MARKER selinuxns=wait-load ctx={ctx!r} t={time.time() - t0:.2f}s")
    if on_load is not None:
        why = on_load()
        if why:
            return failed(why)
"""), "before its first log line"),
        ("no wait for the release byte", mutate(srcs, NS, "    if not release.recv(1):\n        return 1\n", ""),
         "_serve_labels runs"),
        ("a policy built without the helper domains", mutate(
            srcs, "boot.py", "namespace=not host_selinux_mode(), wakeup_genfs=wakeup_genfs)",
            "namespace=False, wakeup_genfs=wakeup_genfs)", first_only=True),
         "builds a policy with namespace=False"),
    )
    bad = []
    for label, mutated, needle in cases:
        got = findings(mutated)
        if not any(needle in g for g in got):
            bad.append(f"the {label} mutant was not flagged for {needle!r}: {got}")
    for line in bad:
        print("FAIL selftest:", line)
    if bad:
        return 1
    print(f"helper-domain selftest: {len(cases)} defects flagged, the real modules clean")
    return 0


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    found = findings(read_sources())
    for line in found:
        print("FAIL", line)
    print("helper-domain:", "FAIL" if found else "ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
