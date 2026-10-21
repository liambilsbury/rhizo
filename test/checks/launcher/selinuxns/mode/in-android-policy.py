#!/usr/bin/env python3
import ast
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
SERVICES = os.path.join(REPO, "src", "services")


def verb(tmp, env_files, caller=None, sandbox_id=None):
    """run the verb under a user namespace with the given env files"""
    paths = {}
    for name, text in env_files.items():
        paths[name] = os.path.join(tmp, name)
        with open(paths[name], "w") as fh:
            fh.write(text)
    os.makedirs(os.path.join(tmp, "instances"), exist_ok=True)
    if "instance" in paths:
        os.replace(paths["instance"], os.path.join(tmp, "instances", f"{sandbox_id}.env"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("RHIZO_")}
    env.update(RHIZO_ANDROIDD_ENV=paths.get("androidd", os.path.join(tmp, "absent")),
               RHIZO_RUNTIME_ENV=paths.get("runtime", os.path.join(tmp, "absent")),
               RHIZO_HOST_MODE_KEPT_FILE=os.path.join(tmp, "absent"), RHIZO_INSTANCE_ENV_DIR=os.path.join(tmp, "instances"),
               RHIZO_CACHE_DIR=os.path.join(tmp, "cache"))
    env.update(caller or {})
    if sandbox_id is not None:
        env["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    target = os.path.join(tmp, "f")
    open(target, "w").close()
    r = subprocess.run(["unshare", "-Ur", sys.executable, LAUNCHER, "in-android-policy", "label", target,
                        "u:object_r:rhizo_inbox_file:s0"], capture_output=True, text=True, env=env, timeout=120)
    return r.stdout + r.stderr


def release_findings():
    """return where the verb keys the policy on another tree than the unit's"""
    bad = []
    for name, files, caller, sandbox_id, want in (
            ("a17 named only in androidd-runtime.env", {"androidd": "RHIZO_SELINUX_MODE=namespace\n",
                                                        "runtime": "RHIZO_GSI={tmp}/gsi_system_a17\nRHIZO_RELEASE=a17\n"},
             None, None, "gsi_system_a17"),
            ("a15 named in instance 2's env file", {"androidd": "RHIZO_SELINUX_MODE=namespace\n",
                                                    "runtime": "RHIZO_GSI={tmp}/gsi_system_a17\n",
                                                    "instance": "RHIZO_GSI={tmp}/gsi_system_a15\n"},
             None, 2, "gsi_system_a15"),
            ("a caller's own RHIZO_GSI", {"runtime": "RHIZO_GSI={tmp}/gsi_system_a17\n"},
             {"RHIZO_GSI": "{tmp}/gsi_system_own"}, None, "gsi_system_own")):
        with tempfile.TemporaryDirectory() as tmp:
            out = verb(tmp, {k: v.format(tmp=tmp) for k, v in files.items()},
                       {k: v.format(tmp=tmp) for k, v in (caller or {}).items()}, sandbox_id)
            line = next((l for l in out.splitlines() if l.startswith("IN_ANDROID_POLICY_FAILED")), "")
            if f"gsi={tmp}/{want}" not in line:
                bad.append(f"with {name}, in-android-policy reports {line or out.strip()[-300:]!r}, want the policy "
                           f"looked up for {want}")
    return bad


def load(name, path):
    """import a module from a path"""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def broker_findings():
    """return where the broker or the stager drops the request's instance"""
    bad = []
    sys.path.insert(0, SERVICES)
    stage = load("inbox_stage", os.path.join(SERVICES, "broker", "inbox_stage.py"))
    brokerd = load("brokerd", os.path.join(SERVICES, "broker", "brokerd.py"))
    seen = {}

    def run(argv, **kw):
        """record the child's environment and print a label"""
        seen["env"] = kw.get("env") or {}
        return subprocess.CompletedProcess(argv, 0, stdout="u:object_r:rhizo_inbox_file:s0\n", stderr="")

    with tempfile.TemporaryDirectory() as tmp:
        fd = os.open(os.path.join(tmp, "x"), os.O_RDWR | os.O_CREAT)
        try:
            stage.label_in_android_policy(fd, "u:object_r:rhizo_inbox_file:s0", run=run, sandbox_id=3)
        except TypeError as e:
            bad.append(f"label_in_android_policy takes no instance: {e}")
        finally:
            os.close(fd)
    if seen.get("env", {}).get("RHIZO_SANDBOX_ID") != "3":
        bad.append(f"the stager's in-android-policy child runs with RHIZO_SANDBOX_ID={seen.get('env', {}).get('RHIZO_SANDBOX_ID')!r}, "
                   "want the instance it labels for, 3")
    staged = {}
    brokerd.materialize_apk = lambda fd, root, mode_file=None, inst_id=0: staged.update(root=root, inst_id=inst_id) or "/x"
    try:
        brokerd.build_argv({"v": 1, "verb": "install", "args": [], "id": 4}, [0], 4)
    except Exception as e:  # noqa: BLE001
        staged.setdefault("error", repr(e))
    if staged.get("inst_id") != 4:
        bad.append(f"the broker stages instance 4's apk as {staged}, want the instance passed to the stager")
    return bad


CAP_KEEP = {"label": set(), "label-fd": set(), "materialize-data-template": {0, 1, 2, 3},
            "hostfs-label-lower": {1, 2, 3, 6, 7, 18, 19, 21}}


def refusal_findings():
    """return a caller or argv the verb runs that it should refuse"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "f")
        open(target, "w").close()
        evil = os.path.join(tmp, "rhizo-hostfs-evil.py")
        with open(evil, "w") as fh:
            fh.write("print('RAN')\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("RHIZO_")}
        env["RHIZO_CACHE_DIR"] = os.path.join(tmp, "cache")
        for name, prefix, argv, want in (
                ("a non-root caller", [], ["label", target, "u:object_r:x:s0"], "reason=not-root"),
                ("an arbitrary command", ["unshare", "-Ur"], ["/bin/sh", "-c", "echo RAN"], "reason=unknown-verb"),
                ("a script that is not the payload's hostfs", ["unshare", "-Ur"],
                 ["hostfs-label-lower", evil, "label-lower"], "reason=unknown-verb"),
                ("hostfs's attach", ["unshare", "-Ur"],
                 ["hostfs-label-lower", os.path.join(SERVICES, "hostfs.py"), "attach"], "reason=unknown-verb"),
                ("a label with a missing context", ["unshare", "-Ur"], ["label", target], "reason=unknown-verb")):
            r = subprocess.run(prefix + [sys.executable, LAUNCHER, "in-android-policy", *argv], capture_output=True,
                               text=True, env=env, timeout=120)
            out = r.stdout + r.stderr
            if want not in out or re.search(r"^RAN$", r.stdout, re.M) or r.returncode == 0:
                bad.append(f"in-android-policy run by {name} answers rc={r.returncode} {out.strip()[-200:]!r}, want {want}")
    return bad


def caps_findings():
    """return where the verb keeps a capability its verb does not need"""
    bad = []
    src = open(LAUNCHER).read()
    tree = ast.parse(src)
    table = next((n for n in tree.body if isinstance(n, ast.Assign)
                  and [ast.unparse(t) for t in n.targets] == ["IN_ANDROID_POLICY_CAPS"]), None)
    caps = ast.literal_eval(table.value) if table is not None else None
    if caps is None or {k: set(v) for k, v in caps.items()} != CAP_KEEP:
        bad.append(f"boot.py's IN_ANDROID_POLICY_CAPS is {caps}, want {CAP_KEEP}")
    verb = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "in_android_policy_verb"), None)
    order = [] if verb is None else [getattr(c.func, "attr", getattr(c.func, "id", "")) for c in sorted(
        (c for c in ast.walk(verb) if isinstance(c, ast.Call)), key=lambda c: (c.lineno, c.col_offset))]
    steps = [s for s in order if s in ("_enter_compiled_policy_namespace", "keep_only_caps", "_drop_privileges",
                                       "execv", "execvp", "label_in_namespace")]
    want = ["_enter_compiled_policy_namespace", "_drop_privileges", "label_in_namespace", "keep_only_caps", "execv"]
    if steps != want:
        bad.append(f"in_android_policy_verb runs {steps}, want the policy load, then the capability drop, before each "
                   f"label or exec: {want}")
    probe = ("import sys; sys.path.insert(0, sys.argv[1]); from sandbox import selinux_ns as ns; "
             "last = int(open('/proc/sys/kernel/cap_last_cap').read()); "
             "why = ns.keep_only_caps({0, 21}, last) if sys.argv[2] == 'keep' else ns._drop_privileges(last); "
             "st = dict(l.split(':\t') for l in open('/proc/self/status').read().splitlines() if ':\t' in l); "
             "print(why or 'ok', st['CapEff'].strip(), st['CapPrm'].strip(), st['CapBnd'].strip())")
    for mode, want_caps in (("keep", "0000000000200001"), ("drop", "0000000000000000")):
        r = subprocess.run(["unshare", "-Ur", sys.executable, "-c", probe, os.path.dirname(LAUNCHER), mode],
                           capture_output=True, text=True, timeout=60, env=dict(os.environ, RHIZO_GSI="/nonexistent"))
        if r.stdout.split() != ["ok", want_caps, want_caps, want_caps]:
            bad.append(f"the {mode} capability step leaves {r.stdout.strip() or r.stderr.strip()[-200:]!r}, want "
                       f"effective, permitted and bounding {want_caps}")
    return bad


HELPER_WANT = {"label": "label", "label-fd": "label", "hostfs-label-lower": "label",
               "materialize-data-template": "relabel"}


def helper_findings():
    """return where a verb enters the wrong helper domain"""
    bad = []
    tree = ast.parse(open(LAUNCHER).read())
    table = next((n for n in tree.body if isinstance(n, ast.Assign)
                  and [ast.unparse(t) for t in n.targets] == ["IN_ANDROID_POLICY_HELPER"]), None)
    helpers = ast.literal_eval(table.value) if table is not None else None
    if helpers != HELPER_WANT:
        bad.append(f"boot.py's IN_ANDROID_POLICY_HELPER is {helpers}, want {HELPER_WANT}")
    verb = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "in_android_policy_verb"), None)
    enters = [] if verb is None else [c for c in ast.walk(verb) if isinstance(c, ast.Call)
                                      and getattr(c.func, "id", "") == "_enter_compiled_policy_namespace"]
    if len(enters) != 1 or len(enters[0].args) != 2 or ast.unparse(enters[0].args[1]) != "IN_ANDROID_POLICY_HELPER[verb]":
        bad.append("in_android_policy_verb does not enter the policy namespace as IN_ANDROID_POLICY_HELPER[verb]: "
                   f"{[ast.unparse(c) for c in enters]}")
    return bad


def main():
    """return the failures"""
    probe = subprocess.run(["unshare", "-Ur", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        print(f"FAIL unshare -Ur is refused here ({probe.stderr.strip() or probe.returncode})")
        return 1
    bad = release_findings() + broker_findings() + refusal_findings() + caps_findings() + helper_findings()
    for line in bad:
        print("FAIL", line)
    print("in-android-policy:", "FAIL" if bad else "ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
