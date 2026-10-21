#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "..", "src"))
LAUNCHER = os.path.join(SRC, "androidd", "boot.py")
HOSTFS = os.path.join(SRC, "services", "hostfs", "hostfs.py")
VERB_ARGS = ["--init-pid", "42", "--name", "Download", "--path", "/data/media/0/Download"]
WANT_EVENTS = [["load"], ["parser"], ["enter", "label"], ["keep", [1, 2, 3, 6, 7, 18, 19, 21]],
               ["label-lower", 42, "Download", "/data/media/0/Download"]]
FIXTURE_HOSTFS = '''
import argparse
import builtins

builtins.EVENTS.append(["load"])


def build_parser():
    """return the parser of the label-lower verb"""
    builtins.EVENTS.append(["parser"])
    p = argparse.ArgumentParser(prog="hostfs.py")
    lab = p.add_subparsers(dest="verb", required=True).add_parser("label-lower")
    lab.add_argument("--init-pid", type=int, required=True)
    lab.add_argument("--name", required=True)
    lab.add_argument("--path", required=True)
    return p


def cmd_label_lower(args):
    """record the verb and return its exit code"""
    builtins.EVENTS.append(["label-lower", args.init_pid, args.name, args.path])
    return 7
'''
IMPORT_LAUNCHER = r'''
import importlib.util, json, sys
sys.path.insert(0, sys.argv[2])
spec = importlib.util.spec_from_file_location("launcher_under_check", sys.argv[1])
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
'''
RUN_VERB = IMPORT_LAUNCHER + r'''
import builtins, os, subprocess
events = builtins.EVENTS = []


def process_start(kind):
    """return a stand-in for a process start"""
    def record(*args, **kwargs):
        events.append([kind])
        raise SystemExit(99)
    return record


os.execv = os.execve = os.execvp = process_start("exec")
os.fork = process_start("fork")
subprocess.run = subprocess.Popen = process_start("spawn")
os.environ["RHIZO_UNIT_ENV_READ"] = "1"
launcher.compiled_policy_path = lambda: "/policy"
launcher._enter_compiled_policy_namespace = lambda policy, helper: events.append(["enter", helper])
launcher.selinux_ns.keep_only_caps = lambda keep, last_cap: (events.append(["keep", sorted(keep)]), "")[1]
try:
    rc = launcher.in_android_policy_verb(["hostfs-label-lower", sys.argv[3], "label-lower"] + sys.argv[4:])
except SystemExit as e:
    rc = e.code
print(json.dumps({"rc": rc, "events": events}))
'''
RUN_LOADER = IMPORT_LAUNCHER + r'''
import contextlib, io, runpy, types
script = sys.argv[3]
hostfs = runpy.run_path(script, run_name="hostfs_under_check")
seen = []
done = types.SimpleNamespace(returncode=0, stdout='{"ok": true}', stderr="")
hostfs["label_in_policy_namespace"](42, "Download", "/etc", run=lambda argv, **kw: (seen.append(argv), done)[1])
args = seen[0][seen[0].index("label-lower"):]
out = io.StringIO()
with contextlib.redirect_stdout(out):
    rc = launcher.load_hostfs_label_lower(script, args)()
print(json.dumps({"rc": rc, "out": out.getvalue()}))
'''


def run_child(code, launcher_path, *args):
    """return the JSON line a child python prints"""
    r = subprocess.run(["unshare", "-Ur", sys.executable, "-c", code, launcher_path, os.path.dirname(LAUNCHER), *args],
                       capture_output=True, text=True, timeout=120, env={**os.environ, "RHIZO_GSI": "/nonexistent-gsi"})
    lines = [l for l in r.stdout.splitlines() if l.startswith("{")]
    if r.returncode != 0 or not lines:
        raise RuntimeError(f"the run did not report: rc={r.returncode} {(r.stdout + r.stderr)[-400:]!r}")
    return json.loads(lines[-1])


def verb_findings(launcher_path):
    """return where the verb starts a process or loads after the setcon"""
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "hostfs.py")
        with open(script, "w") as f:
            f.write(FIXTURE_HOSTFS)
        got = run_child(RUN_VERB, launcher_path, script, *VERB_ARGS)
    events, names = got["events"], [e[0] for e in got["events"]]
    bad = [f"hostfs-label-lower starts a process in the label domain: {e[0]}" for e in events
           if e[0] in ("exec", "fork", "spawn")]
    for step in ("load", "parser"):
        if step in names and "enter" in names and names.index(step) > names.index("enter"):
            bad.append(f"hostfs-label-lower runs {step} after the policy namespace: {names}")
    if events != WANT_EVENTS or got["rc"] != 7:
        bad.append(f"hostfs-label-lower ran {events} and returned {got['rc']}, want {WANT_EVENTS} and 7")
    return bad


def loader_findings(launcher_path, hostfs_path):
    """return where the loader cannot read the verb's argv"""
    try:
        got = run_child(RUN_LOADER, launcher_path, hostfs_path)
    except RuntimeError as e:
        return [f"the launcher's loader does not run hostfs.py's label-lower: {e}"]
    if got["rc"] != 2 or '"ok": false' not in got["out"] or "label-lower takes" not in got["out"]:
        return [f"the launcher's loader ran label-lower to rc={got['rc']} {got['out'].strip()!r}, want the lower root refusal, rc=2"]
    return []


def findings(launcher_path=LAUNCHER, hostfs_path=HOSTFS):
    """return every finding"""
    return verb_findings(launcher_path) + loader_findings(launcher_path, hostfs_path)


def mutate(text, old, new, name):
    """return text with its an occurrence of old replaced"""
    if text.count(old) != 1:
        raise SystemExit(f"helper-label-inprocess selftest: {old!r} appears {text.count(old)} times in {name}")
    return text.replace(old, new)


def selftest():
    """flag each mutant and pass the real files"""
    launcher_text, hostfs_text = open(LAUNCHER).read(), open(HOSTFS).read()
    real = findings()
    if real:
        print("FAIL selftest:", *real, sep="\n  ")
        return 1
    call = "    if hostfs_label_lower is not None:\n        return hostfs_label_lower()\n"
    cases = (
        ("an exec after the setcon", mutate(launcher_text, call, "", "boot.py"), hostfs_text,
         "starts a process in the label domain: exec"),
        ("a script loaded after the setcon",
         mutate(mutate(launcher_text, 'if verb == "hostfs-label-lower":\n        try:\n',
                       "if False:\n        try:\n", "boot.py"), call,
                '    if verb == "hostfs-label-lower":\n        return load_hostfs_label_lower(argv[1], argv[2:])()\n',
                "boot.py"), hostfs_text, "runs load after the policy namespace"),
        ("arguments parsed after the setcon",
         mutate(launcher_text, '    parsed = functions["build_parser"]().parse_args(args)\n'
                               '    return lambda: functions["cmd_label_lower"](parsed)\n',
                '    return lambda: functions["cmd_label_lower"](functions["build_parser"]().parse_args(args))\n',
                "boot.py"), hostfs_text, "runs parser after the policy namespace"),
        ("a script whose parser the verb cannot read", launcher_text,
         mutate(hostfs_text, "def build_parser():", "def make_parser():", "hostfs.py"),
         "does not run hostfs.py's label-lower"),
    )
    bad = []
    for label, launcher_mutant, hostfs_mutant, needle in cases:
        with tempfile.TemporaryDirectory() as tmp:
            launcher_path, hostfs_path = os.path.join(tmp, "boot.py"), os.path.join(tmp, "hostfs.py")
            for path, text in ((launcher_path, launcher_mutant), (hostfs_path, hostfs_mutant)):
                with open(path, "w") as f:
                    f.write(text)
            got = findings(launcher_path, hostfs_path)
        if not any(needle in g for g in got):
            bad.append(f"the {label} mutant was not flagged for {needle!r}: {got}")
    for line in bad:
        print("FAIL selftest:", line)
    if bad:
        return 1
    print(f"helper-label-inprocess selftest: {len(cases)} defects flagged, the real launcher and script clean")
    return 0


def main():
    """run the check or its selftest"""
    probe = subprocess.run(["unshare", "-Ur", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        print(f"FAIL unshare -Ur is refused here ({probe.stderr.strip() or probe.returncode})")
        return 1
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    found = findings()
    for line in found:
        print("FAIL", line)
    print("helper-label-inprocess:", "FAIL" if found else "ok")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
