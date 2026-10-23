#!/usr/bin/env python3
import ast, contextlib, importlib.util, io, os, re, shutil, subprocess, sys, tempfile, time
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..")
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
MUTANTS = (
    ("ash_inline nsenter in namespace mode", "src/androidd/host/launch-app.sh",
     'if [ "$_mode" != namespace ]', 'if [ "$_mode" != nonamespace ]', "ash_inline under sh, mode file namespace"),
    ("ash_inline's missing mode file read as host", "src/androidd/host/launch-app.sh",
     '    _m=$("${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"', '    _m=host; : $("${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"',
     "ash_inline under sh, mode file missing, namespace configured"),
    ("appsync's missing mode file read as host", "src/services/appsync/appsync.py",
     '    except FileNotFoundError:\n        mode = ""\n', '    except FileNotFoundError:\n        return "host"\n',
     "appsync android_sh, missing, namespace configured"),
    ("ash_inline's comment above selinux_mode", "src/androidd/host/launch-app.sh",
     "# print the recorded or configured SELinux mode\nselinux_mode() {",
     "# run a command in android's shell\n"
     "# print the recorded or configured SELinux mode\nselinux_mode() {", "rhizo-launch.sh's selinux_mode() comment"),
    ("a namespace-mode stop through nsenter", "src/androidd/boot.py",
     "        if not host_selinux_mode():\n            deadline = time.time() + timeout\n",
     "        if False:\n            deadline = time.time() + timeout\n",
     "androidd-stop powerctl, namespace mode"),
    ("after-flip jobs armed in host mode", "src/androidd/boot.py",
     "    if not host_selinux_mode():\n        hold_start_lock_or_refuse()\n",
     "    if host_selinux_mode():\n        hold_start_lock_or_refuse()\n", "main arms the after-flip jobs"),
)


def run_check(root):
    """run this check over a source tree"""
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--root", root], capture_output=True, text=True,
                       timeout=600)
    return r.returncode, r.stdout + r.stderr


def selftest():
    """flag each mutant and pass the real tree"""
    failed = []
    for label, rel, old, new, needle in MUTANTS:
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(os.path.join(ROOT, "src"), os.path.join(tmp, "src"), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__"))
            path = os.path.join(tmp, rel)
            text = open(path).read()
            if text.count(old) != 1:
                failed.append(f"the {label} mutant found {text.count(old)} anchors")
                continue
            with open(path, "w") as f:
                f.write(text.replace(old, new))
            rc, out = run_check(tmp)
        if rc == 0 or needle not in out:
            failed.append(f"the {label} mutant was not flagged: rc={rc} {out[-300:]!r}")
    rc, out = run_check(ROOT)
    if rc != 0:
        failed.append(f"the real tree has findings: {out[-500:]!r}")
    for f in failed:
        print("FAIL", f)
    print("command-path: selftest ok" if not failed else "command-path: selftest FAIL")
    return 1 if failed else 0


if __name__ == "__main__" and "--selftest" in sys.argv[1:]:
    sys.exit(selftest())
LAUNCHER = os.path.join(ROOT, "src", "androidd")
APPSYNC = os.path.join(ROOT, "src", "services", "appsync", "appsync.py")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-command-path")
os.environ.pop("RHIZO_SELINUX_MODE", None)
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
from sandbox import selinux_ns as ns

bad = []
PATH_EXPORT = "export PATH=/system/bin:/system/xbin:/vendor/bin; "
SOCK7 = "/run/rhizo-7/data/local/tmp/rhizo-probe.sock"


def ash_inline_run(shell, mode, configured):
    """run rhizo-launch.sh's ash_inline with fake host tools"""
    text = open(os.path.join(LAUNCHER, "host", "launch-app.sh")).read()
    funcs = [m.group(0) for m in (re.search(r"^%s\(\) \{.*?^\}$" % name, text, re.M | re.S)
                                  for name in ("selinux_mode", "ash_inline")) if m]
    with tempfile.TemporaryDirectory() as tmp:
        bindir = os.path.join(tmp, "bin")
        os.mkdir(bindir)
        fakes = {"nsenter": 'echo "nsenter $*" >> "$CMD_LOG"\nexit 1\n',
                 "probe": 'echo "probe $*" >> "$CMD_LOG"\necho hello\necho RHIZO_ASH_DONE=0\n',
                 "rhizo-selinux-mode": (f"echo {configured}\n" if configured else "exit 1\n")}
        for name, body in fakes.items():
            with open(os.path.join(bindir, name), "w") as f:
                f.write("#!/bin/sh\n" + body)
            os.chmod(os.path.join(bindir, name), 0o755)
        mode_file = os.path.join(tmp, "selinux-mode")
        if mode is not None:
            with open(mode_file, "w") as f:
                f.write(mode + "\n")
        log = os.path.join(tmp, "commands")
        env = {"PATH": bindir + ":/usr/bin:/bin", "RUN_ROOT": "/run/rhizo-7", "INIT": "4242",
               "PROBE_CLIENT": os.path.join(bindir, "probe"), "PROBE_SOCK": SOCK7,
               "RHIZO_SELINUX_MODE_FILE": mode_file, "RHIZO_SELINUX_MODE_HELPER": os.path.join(bindir, "rhizo-selinux-mode"),
               "TMPDIR": tmp, "CMD_LOG": log}
        r = subprocess.run([shell, "-c", "set -eu\n" + "\n".join(funcs) + '\nout=$(ash_inline "echo hi" 7)\nprintf %s "$out"\n'],
                           env=env, capture_output=True, text=True, timeout=60)
        lines = open(log).read().splitlines() if os.path.exists(log) else []
    return r.returncode, r.stdout, r.stderr, lines


for shell in ("sh", "bash"):
    for label, mode, configured, want in (("namespace", "namespace", "host", "probe"), ("host", "host", "namespace", "nsenter"),
                                          ("missing, namespace configured", None, "namespace", "probe"),
                                          ("missing, host configured", None, "host", "nsenter"),
                                          ("missing, helper failing", None, None, "fail")):
        rc, out, err, lines = ash_inline_run(shell, mode, configured)
        nsenter = [l for l in lines if l.startswith("nsenter ")]
        probes = [l for l in lines if l.startswith("probe ")]
        if want == "probe":
            ok = rc == 0 and out == "hello" and not nsenter and len(probes) == 1 and probes[0].startswith(f"probe {SOCK7} 7 {PATH_EXPORT}echo hi")
        elif want == "nsenter":
            ok = (rc == 0 and out == "hello" and len(lines) == 2
                  and lines[0].startswith("nsenter -a -t 4242 -- /system/bin/toybox runcon u:r:shell:s0")
                  and lines[1].startswith(f"probe {SOCK7} 7 "))
        else:
            ok = rc != 0 and not lines and "cannot read the SELinux mode" in err
        if not ok:
            bad.append((f"ash_inline under {shell}, mode file {label}", rc, out, err[-200:], lines))


LAUNCH_LINES = open(os.path.join(LAUNCHER, "host", "launch-app.sh")).read().splitlines()
for _name in ("selinux_mode", "ash_inline"):
    _at = next((i for i, l in enumerate(LAUNCH_LINES) if l.startswith(_name + "() {")), None)
    if _at is None or _at < 2 or not LAUNCH_LINES[_at - 1].startswith("# ") or LAUNCH_LINES[_at - 2].startswith("# "):
        bad.append((f"rhizo-launch.sh's {_name}() comment", "one comment line directly above it",
                    LAUNCH_LINES[max(0, (_at or 0) - 2):(_at or 0)]))


def load_appsync(runtime_dir):
    """import appsync.py with its ssh control dir under runtime_dir"""
    saved = os.environ.get("XDG_RUNTIME_DIR")
    os.environ["XDG_RUNTIME_DIR"] = runtime_dir
    try:
        spec = importlib.util.spec_from_file_location("rhizo_appsync_under_check", APPSYNC)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        if saved is None:
            os.environ.pop("XDG_RUNTIME_DIR", None)
        else:
            os.environ["XDG_RUNTIME_DIR"] = saved


with tempfile.TemporaryDirectory() as tmp:
    appsync = load_appsync(tmp)
    probe = (f"/fake/rhizo-probe-client {appsync.PROBE_SOCK} 9 '{PATH_EXPORT}pm list packages'", 14)
    mode_file = os.path.join(tmp, "selinux-mode")
    os.mkdir(os.path.join(tmp, "a-directory"))
    helper = os.path.join(tmp, "rhizo-selinux-mode")
    try:
        for label, path, mode, configured, want in (
                ("namespace", mode_file, "namespace", "host", "probe"),
                ("host", mode_file, "host", "namespace", "nsenter"),
                ("missing, namespace configured", os.path.join(tmp, "absent"), None, "namespace", "probe"),
                ("missing, host configured", os.path.join(tmp, "absent"), None, "host", "nsenter"),
                ("missing, helper failing", os.path.join(tmp, "absent"), None, None, "raise"),
                ("unreadable", os.path.join(tmp, "a-directory"), None, "namespace", "raise")):
            if mode is not None:
                with open(path, "w") as f:
                    f.write(mode + "\n")
            with open(helper, "w") as f:
                f.write("#!/bin/sh\n" + (f"echo {configured}\n" if configured else "exit 1\n"))
            os.chmod(helper, 0o755)
            os.environ["RHIZO_SELINUX_MODE_FILE"] = path
            os.environ["RHIZO_SELINUX_MODE_HELPER"] = helper
            be = appsync.HostBackend(local=True, init_pid="4242")
            be._probe_client = "/fake/rhizo-probe-client"
            calls = []
            be.host_sh = lambda cmd, timeout=30, calls=calls: (calls.append((cmd, timeout)), "")[1]
            err = io.StringIO()
            raised = None
            with contextlib.redirect_stderr(err):
                try:
                    be.android_sh("pm list packages", 9)
                except RuntimeError as e:
                    raised = str(e)
            if want == "probe":
                ok = raised is None and calls == [probe]
            elif want == "raise":
                ok = calls == [] and raised is not None and (path in raised or helper in raised)
            else:
                ok = (raised is None and len(calls) == 2 and calls[0][0].startswith("nsenter -a -t 4242 -- ")
                      and calls[1] == probe)
            if not ok:
                bad.append((f"appsync android_sh, {label}", calls, raised, err.getvalue()))
    finally:
        os.environ.pop("RHIZO_SELINUX_MODE_FILE", None)
        os.environ.pop("RHIZO_SELINUX_MODE_HELPER", None)

ltree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
FUNCS = {n.name: n for n in ltree.body if isinstance(n, ast.FunctionDef)}
stop_try = next(n for n in FUNCS["androidd_stop"].body if isinstance(n, ast.Try))
sites = [i for i, s in enumerate(stop_try.body) if "subprocess.run" in ast.unparse(s) and "sys.powerctl" in ast.unparse(s)]
PROBE_CLIENT = launcher.beside("probe-client.py")


class FakeClock:
    """time stand-in whose sleep advances its clock"""
    def __init__(self):
        """start the clock at 1000 s"""
        self.now = 1000.0

    def time(self):
        """return the clock"""
        return self.now

    def sleep(self, s):
        """advance the clock by s"""
        self.now += s


if len(sites) != 1:
    bad.append(("androidd-stop powerctl", "one statement sending sys.powerctl", len(sites)))
elif not ast.unparse(stop_try.body[sites[0] - 1]).startswith("timeout = float("):
    bad.append(("androidd-stop timeout", "parsed in the statement before the powerctl send", sites))
    sites = []
else:
    site = compile(ast.Module(body=stop_try.body[sites[0] - 1:sites[0] + 1], type_ignores=[]), "boot.py", "exec")
    for mode, stack_up in (("namespace", True), ("host", True), ("namespace", False), ("host", False)):
        runs, logs, stops = [], [], []

        class FakeSelinuxns:
            """selinux_ns stand-in recording the probe runs before each stop request"""
            record_stop_request = staticmethod(lambda *a: stops.append(len(runs)))

        class FakeSubprocess:
            """subprocess stand-in recording each argv and its timeout"""
            DEVNULL, PIPE, TimeoutExpired = subprocess.DEVNULL, subprocess.PIPE, subprocess.TimeoutExpired

            @staticmethod
            def run(argv, **kw):
                """record argv and its timeout and answer rc 0"""
                runs.append((list(argv), kw.get("timeout")))
                return subprocess.CompletedProcess(argv, 0, "", "")

        scope = {"subprocess": FakeSubprocess, "host_selinux_mode": lambda: mode == "host", "stack_up": stack_up,
                 "pid": 4242, "orig_sig": ("init", "77"), "beside": launcher.beside, "RUN_ROOT": "/run/rhizo-7",
                 "kmsg": logs.append, "time": FakeClock(), "os": os, "selinux_ns": FakeSelinuxns}
        exec(site, scope)
        if stops != ([0] if mode == "namespace" and stack_up else []):
            bad.append((f"androidd-stop stop request, {mode} mode, stack_up={stack_up}",
                        "one before the probe" if mode == "namespace" and stack_up else "none", stops))
        if not stack_up:
            ok = runs == [] and scope.get("r") is None
        elif mode == "namespace":
            ok = (len(runs) == 1 and runs[0][0][:4] == ["/usr/bin/python3", PROBE_CLIENT, SOCK7, "10"]
                  and runs[0][1] == 15 and "setprop sys.powerctl shutdown" in runs[0][0][-1]
                  and "nsenter" not in " ".join(runs[0][0])
                  and any("probe" in l and "sys.powerctl" in l and "rc=0" in l for l in logs))
        else:
            ok = runs == [(["nsenter", "-a", "-t", "4242", "--", "/system/bin/setprop", "sys.powerctl", "shutdown"], None)]
        if not ok:
            bad.append((f"androidd-stop powerctl, {mode} mode, stack_up={stack_up}", runs, logs))

    tail = ast.parse("def stop_tail():\n    pass\n")
    tail.body[0].body = stop_try.body[sites[0] - 1:]
    tail_code = compile(ast.fix_missing_locations(tail), "boot.py", "exec")


def stop_on_clock(mode, probe):
    """run the stop's tail on a fake clock"""
    clock, runs, kills = FakeClock(), [], []
    start = clock.now

    class FakeSubprocess:
        """subprocess stand-in whose run takes 15 s on the clock"""
        DEVNULL, PIPE, TimeoutExpired = subprocess.DEVNULL, subprocess.PIPE, subprocess.TimeoutExpired

        @staticmethod
        def run(argv, **kw):
            """advance the clock past the probe timeout"""
            runs.append(list(argv))
            clock.sleep(15)
            if probe == "hangs":
                raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
            return subprocess.CompletedProcess(argv, 98, "", "RHIZO_PROBE_TIMEOUT")

    class FakeOs:
        """os stand-in with the stop timeout and a recorded kill"""
        environ = {"RHIZO_STOP_TIMEOUT": "30"}

        @staticmethod
        def kill(p, s):
            """record when the kill was sent"""
            kills.append(clock.now - start)

    scope = {"subprocess": FakeSubprocess, "host_selinux_mode": lambda: mode == "host", "stack_up": True,
             "pid": 4242, "orig_sig": ("init", "77"), "beside": launcher.beside, "RUN_ROOT": "/run/rhizo-7",
             "kmsg": lambda m: None, "time": clock, "os": FakeOs, "signal": __import__("signal"),
             "sig": lambda p: None if kills else ("init", "77"), "_settle": lambda: None,
             "_cgroup_pid_count": lambda: 3, "_wait_cgroup_empty": lambda budget: True, "_confirmed_empty": [True],
             "selinux_ns": type("StopRecord", (), {"record_stop_request": staticmethod(lambda *a: None)})}
    exec(tail_code, scope)
    return scope["stop_tail"](), kills, runs


if len(sites) == 1:
    for mode, probe, latest in (("namespace", "answers-98", 31), ("namespace", "hangs", 31), ("host", "answers-98", 46)):
        try:
            code, kills, runs = stop_on_clock(mode, probe)
        except Exception as e:
            code, kills, runs = repr(e), [], []
        if code != 0 or len(kills) != 1 or not (latest - 2 <= kills[0] <= latest) or len(runs) != 1:
            bad.append((f"androidd-stop deadline, {mode} mode, probe {probe}", f"SIGKILL by {latest}s, exit 0",
                        code, kills, runs))

ptree = ast.parse(launcher.HOST_PRIMER_SRC)
defs = [n for n in ast.walk(ptree) if isinstance(n, ast.FunctionDef) and n.name == "after_flip_jobs"]
calls = [n for n in ast.walk(ptree) if isinstance(n, ast.Call) and ast.unparse(n) == "after_flip_jobs()"]
branches = [i for i, n in enumerate(ptree.body) if isinstance(n, ast.If)
            and ast.unparse(n.body[0]) == "after_flip_jobs()"]
host_steps = [i for i, n in enumerate(ptree.body)
              if "rhizo-host/cgroup.procs" in ast.unparse(n) or ast.unparse(n).startswith("_first_boot =")]
if len(defs) != 1 or len(calls) != 2 or len(branches) != 1:
    bad.append(("primer after_flip_jobs", "one definition, two calls, one branch", len(defs), len(calls), len(branches)))
else:
    branch = ptree.body[branches[0]]
    flag = [n for n in ptree.body if isinstance(n, ast.Assign) and ast.unparse(n) == "_AFTER_FLIP = '--after-flip' in sys.argv"]
    if (ast.unparse(branch.test) != "_AFTER_FLIP" or not flag or ast.unparse(branch).splitlines()[1:] !=
            ["    after_flip_jobs()", "    sys.exit(0)"] or not host_steps or branches[0] > min(host_steps)):
        bad.append(("primer --after-flip branch", "if _AFTER_FLIP: after_flip_jobs(); sys.exit(0) before the cgroup escape",
                    ast.unparse(branch), host_steps))
    if ast.unparse(ptree.body[-1]) != "after_flip_jobs()":
        bad.append(("primer host flow", "after_flip_jobs() last", ast.unparse(ptree.body[-1])))


def render_primer(tmp, screen_off_ms, desktop=False):
    """write the primer through write_primer_script into tmp"""
    saved = (launcher.HOST_PRIMER_PATH, launcher.RHIZO_LOG_DIR, launcher.beside, launcher.desktop_profile)
    launcher.HOST_PRIMER_PATH = os.path.join(tmp, "rhizo-host-primer.py")
    launcher.RHIZO_LOG_DIR = os.path.join(tmp, "log")
    launcher.beside = lambda *parts: os.path.join(tmp, *parts)
    launcher.desktop_profile = lambda: desktop
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            if screen_off_ms is None:
                launcher.write_primer_script()
            else:
                launcher.write_primer_script(screen_off_ms)
    finally:
        launcher.HOST_PRIMER_PATH, launcher.RHIZO_LOG_DIR, launcher.beside, launcher.desktop_profile = saved
    return os.path.join(tmp, "rhizo-host-primer.py")


with tempfile.TemporaryDirectory() as tmp:
    primer = render_primer(tmp, "60000")
    env = {k: v for k, v in os.environ.items() if k not in ("RHIZO_FLIP_EARLY",)}
    env["RHIZO_POLICY_ONLY"] = "1"
    r = subprocess.run([sys.executable, primer, "--after-flip", "--sandbox-id", "0", "--run-root", tmp], env=env,
                       capture_output=True, text=True, timeout=120)
    log_path = os.path.join(tmp, "log", "rhizo-primer.log")
    plog = open(log_path).read() if os.path.exists(log_path) else ""
    want = ("display pool prime wait SKIPPED", "display pool prime SKIPPED: sys.boot_completed marker not seen",
            "screen_off_timeout NOT reapplied: boot_completed marker never seen")
    unwanted = ("refusing to run", "primer cgroup", "waiting for policy load", "running as")
    if r.returncode != 0 or not all(w in plog for w in want) or any(u in plog for u in unwanted):
        bad.append(("primer --after-flip run", r.returncode, plog, r.stderr[-500:]))

with tempfile.TemporaryDirectory() as tmp:
    open(os.path.join(tmp, "probe-client.py"), "w").close()
    probe_client = os.path.join(tmp, "probe-client.py")
    sock = "/run/rhizo/data/local/tmp/rhizo-probe.sock"
    put = ["/usr/bin/python3", probe_client, sock, "30", PATH_EXPORT + "settings put system screen_off_timeout 60000"]
    get = ["/usr/bin/python3", probe_client, sock, "30", PATH_EXPORT + "settings get system screen_off_timeout"]
    freeform = ["/usr/bin/python3", probe_client, sock, "30",
                "export PATH=/system/bin; settings put global force_resizable_activities 1; "
                "settings put global enable_freeform_support 1"]
    rename = ["/usr/bin/python3", probe_client, sock, "30",
              PATH_EXPORT + "[ \"$(settings get global device_name)\" = 'AOSP on x86_64' ] "
              "&& settings put global device_name \"$(getprop ro.product.model)\" && echo renamed"]
    pool = [["systemctl", "reset-failed", "rhizo-display-pool.service", "rhizo-display-pool.path"],
               ["systemctl", "restart", "rhizo-display-pool.path"],
               ["systemctl", "start", "--no-block", "rhizo-display-pool.service"]]
    for sandbox_id, desktop, want_runs in ((0, True, pool + [put, get, freeform, rename]),
                                           (1, False, [put, get, rename])):
        rtree = ast.parse(open(render_primer(tmp, "60000", desktop)).read())
        afj = [n for n in rtree.body if isinstance(n, ast.FunctionDef) and n.name == "after_flip_jobs"]
        runs, logs = [], []

        class FakeSubprocess:
            """subprocess stand-in recording each argv and reading back the timeout put"""
            @staticmethod
            def run(argv, **kw):
                """record argv and answer the screen-off value"""
                runs.append(list(argv))
                return subprocess.CompletedProcess(argv, 0, "60000\n", "")

        scope = {"_boot_marker_seen": lambda: True, "_SANDBOX_ID": sandbox_id, "_RUN_ROOT": "/run/rhizo",
                 "log": logs.append, "subprocess": FakeSubprocess, "os": os, "time": time}
        if afj:
            exec(compile(ast.Module(body=afj, type_ignores=[]), "HOST_PRIMER_SRC", "exec"), scope)
            scope["after_flip_jobs"]()
        if runs != want_runs or not any("screen_off_timeout reapplied: 60000ms" in l for l in logs):
            bad.append((f"after_flip_jobs, sandbox {sandbox_id}", want_runs, runs, logs))


class FakePolicy:
    """a capability policy answering a profile and a screen-off seconds value"""
    def __init__(self, profile, screen_off_s):
        """store the two scopes"""
        self.scopes = {"rhizo.profile": profile, "server.screen_off_s": screen_off_s}

    def scope(self, key):
        """return the scope's value"""
        return self.scopes[key]

    def allows(self, capability):
        """return false: all optional capabilities are off"""
        return False


saved_policy = launcher.capabilities.policy_or_deny
try:
    for profile, seconds, arg, want in (("server", 60, None, "60000"), ("server", 0, None, "2147483647"),
                                        ("desktop", 60, None, "2147483647"), ("server", 60, "5", "5")):
        launcher.capabilities.policy_or_deny = lambda log=None, p=profile, s=seconds: FakePolicy(p, s)
        with tempfile.TemporaryDirectory() as tmp:
            text = open(render_primer(tmp, arg)).read()
        got = re.search(r'^    _so_ms = "([^"]*)"$', text, re.M) or re.search(r'^_so_ms = "([^"]*)"$', text, re.M)
        if not got or got.group(1) != want:
            bad.append((f"primer screen-off value, {profile} {seconds}s, argument {arg!r}", want,
                        got.group(1) if got else None))
finally:
    launcher.capabilities.policy_or_deny = saved_policy

main_fn = FUNCS["main"]
arms = [n for n in main_fn.body if isinstance(n, ast.If) and "arm_after_flip_jobs()" in ast.unparse(n)]
lock_at = next((i for i, n in enumerate(main_fn.body) if "acquire_host_global_phase()" in ast.unparse(n)), None)
if (len(arms) != 1 or ast.unparse(arms[0].test) != "not host_selinux_mode()"
        or [ast.unparse(n) for n in arms[0].body] != ["hold_start_lock_or_refuse()", "reset_namespace_start_records()",
                                                      "arm_after_flip_jobs()"]
        or lock_at is None or main_fn.body.index(arms[0]) > lock_at):
    bad.append(("main arms the after-flip jobs", "lock, reset, arm under not host_selinux_mode(), before the host lock",
                [ast.unparse(a) for a in arms]))
if "after_flip" in ast.unparse(FUNCS["run_sandbox"]) or hasattr(ns, "start_host_job"):
    bad.append(("run_sandbox and g", "no after-flip helper", "after_flip" in ast.unparse(FUNCS["run_sandbox"])))


def after_flip_run(states, verdicts):
    """run run_after_flip_jobs on a fake clock and readers"""
    from sandbox import hostlock
    clock, runs, logs = FakeClock(), [], []
    start = clock.now
    states, verdicts = list(states), list(verdicts)

    class FakeSubprocess:
        """subprocess stand-in recording argv and the timeout"""
        @staticmethod
        def run(argv, **kw):
            """record argv and its timeout and answer rc 0"""
            runs.append((list(argv), kw.get("timeout")))
            return subprocess.CompletedProcess(argv, 0, "", "")

    saved = (hostlock.android_enforce_state, hostlock.selinuxns_verdict, hostlock.time,
             launcher.subprocess, launcher.kmsg)
    hostlock.android_enforce_state = lambda: states.pop(0) if states else "0"
    hostlock.selinuxns_verdict = lambda: verdicts.pop(0) if verdicts else "pending"
    hostlock.time, launcher.subprocess, launcher.kmsg = clock, FakeSubprocess, logs.append
    try:
        code = launcher.run_after_flip_jobs()
    finally:
        (hostlock.android_enforce_state, hostlock.selinuxns_verdict, hostlock.time,
         launcher.subprocess, launcher.kmsg) = saved
    return code, runs, logs, clock.now - start


ARGV = [sys.executable, launcher.HOST_PRIMER_PATH, "--after-flip", "--sandbox-id", str(launcher.SANDBOX_ID),
        "--run-root", launcher.RUN_ROOT]
DEADLINE = 240 + ns.RELABELLER_DEADLINE_S + 120
for label, states, verdicts, want_runs, want_log in (
        ("enforce reads 1", ["0", "0", "1"], ["pending", "handed-off"], [(ARGV, 600)], "after_flip=ran rc=0"),
        ("refused", [], ["pending", "refused:init-outside-namespace"], [],
         "after_flip=skipped reason=refused:init-outside-namespace"),
        ("permissive", [], ["permissive"], [], "after_flip=skipped reason=permissive"),
        ("stopped", [], ["stopped"], [], "after_flip=skipped reason=stopped"),
        ("deadline", [], [], [], f"after_flip=skipped reason=deadline-{DEADLINE}s")):
    code, runs, logs, waited = after_flip_run(states, verdicts)
    if (runs != want_runs or code != (0 if want_runs else 1) or not any(want_log in l for l in logs)
            or (label == "deadline" and not DEADLINE <= waited < DEADLINE + 1)):
        bad.append((f"run_after_flip_jobs, {label}", want_runs, want_log, (code, runs, logs, waited)))


def arm_run(no_prime):
    """call arm_after_flip_jobs with a stubbed job"""
    logs = []
    with tempfile.TemporaryDirectory() as tmp:
        seen = os.path.join(tmp, "job")

        def job():
            """record this process's session, pid and parent and return 0"""
            with open(seen + ".tmp", "w") as f:
                f.write(f"{os.getsid(0)} {os.getpid()} {os.getppid()}")
            os.rename(seen + ".tmp", seen)
            return 0

        saved = (launcher.run_after_flip_jobs, launcher.kmsg, os.environ.get("RHIZO_NO_HOST_PRIME"))
        launcher.run_after_flip_jobs, launcher.kmsg = job, logs.append
        if no_prime:
            os.environ["RHIZO_NO_HOST_PRIME"] = "1"
        else:
            os.environ.pop("RHIZO_NO_HOST_PRIME", None)
        try:
            if hasattr(launcher, "arm_after_flip_jobs"):
                launcher.arm_after_flip_jobs()
        finally:
            launcher.run_after_flip_jobs, launcher.kmsg = saved[:2]
            if saved[2] is None:
                os.environ.pop("RHIZO_NO_HOST_PRIME", None)
            else:
                os.environ["RHIZO_NO_HOST_PRIME"] = saved[2]
        try:
            left = os.waitpid(-1, os.WNOHANG) != (0, 0)
        except ChildProcessError:
            left = False
        for _ in range(600):
            if no_prime or os.path.exists(seen):
                break
            time.sleep(0.05)
        record = open(seen).read().split() if os.path.exists(seen) else None
    return record, logs, left


record, logs, left = arm_run(False)
if record is None or record[0] != record[1] or record[2] == str(os.getpid()) or left:
    bad.append(("arm_after_flip_jobs", "the job in a new session of a detached grandchild, no zombie", record, left))
record, logs, left = arm_run(True)
if record is not None or left or not any("RHIZO_NO_HOST_PRIME" in l for l in logs):
    bad.append(("arm_after_flip_jobs under RHIZO_NO_HOST_PRIME=1", "nothing armed, a log line", record, logs))


if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
