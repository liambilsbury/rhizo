#!/usr/bin/env python3
import contextlib
import io
import os
import signal
import subprocess
import sys
import tempfile

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-stop-sweeps-sandbox")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher


def sleeper():
    """fork a child that waits to be killed"""
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        while True:
            signal.pause()
    return pid


def alive(pid):
    """return whether pid runs and is not a zombie"""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False


def scenario(kill_refused, companions_stop=True, owns=True):
    """sweep a stand-in stack tree"""
    pids = {role: sleeper() for role in ("init", "app", "stray", "supervisor")}
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "rhizo-3")
        tree = {root: [], f"{root}/init": [pids["init"]], f"{root}/apps": [], f"{root}/apps/uid_10000": [pids["app"]],
                f"{root}/supervisor": [pids["supervisor"], pids["stray"]], f"{root}/launcher": []}
        for d in tree:
            os.makedirs(d, exist_ok=True)

        def tree_pids(top, skip=(), depth=None):
            """return the live pids under top from the stand-in tree"""
            under = [d for d in tree if d == top or (depth != 0 and d.startswith(top + "/"))]
            return [p for d in under for p in tree[d] if alive(p) and p not in skip]

        def write(path, value):
            """kill a cgroup's subtree on a cgroup.kill write"""
            if not path.endswith("/cgroup.kill"):
                raise AssertionError(f"unexpected cgroup write {path}")
            top = os.path.dirname(path)
            if kill_refused and top == f"{root}/init":
                raise PermissionError(13, "Permission denied", path)
            ORDER.append("sweep")
            for pid in tree_pids(top):
                os.kill(pid, signal.SIGKILL)

        released, logs, stops = [], [], []
        names = ("cgroup_tree_pids", "cgroup_write", "stack_cgroup", "recorded_pid", "stack_cgroup_populated",
                 "release_host_staging", "kmsg", "SANDBOX_SWEEP_WAIT_S", "stop_companion_units", "stop_owns_instance")
        saved = {n: getattr(launcher, n, None) for n in names}
        saved_euid = os.geteuid
        launcher.cgroup_tree_pids, launcher.cgroup_write = tree_pids, write
        launcher.stack_cgroup, launcher.recorded_pid = (lambda: root), (lambda: pids["supervisor"])
        launcher.stack_cgroup_populated = lambda: bool(tree_pids(root, skip=(pids["supervisor"], os.getpid())))
        launcher.release_host_staging = lambda who=None, **kw: released.append(who)
        launcher.kmsg, launcher.SANDBOX_SWEEP_WAIT_S = logs.append, 1
        launcher.stop_companion_units = lambda sandbox_id, log: (ORDER.append("companions"), stops.append(sandbox_id),
                                                                 companions_stop)[2]
        launcher.stop_owns_instance = lambda log: owns
        os.geteuid = lambda: 0
        try:
            code = launcher.release_staging_verb()
        except Exception as e:
            code = repr(e)
        finally:
            os.geteuid = saved_euid
            for n, v in saved.items():
                setattr(launcher, n, v)
        states = {role: alive(pid) for role, pid in pids.items()}
        for pid in pids.values():
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
    return code, released, states, logs, stops


def systemctl_stand_in(state, stop_rc=0, on_stop=None, jobs=()):
    """return a fake systemctl run over state"""
    calls = []

    def run(argv, **kw):
        """return a systemctl call's result from state"""
        calls.append(argv)
        TIMEOUTS.append(kw.get("timeout"))
        units = argv[argv.index("--") + 1:]
        if argv[1] == "list-jobs":
            return subprocess.CompletedProcess(argv, 0, "".join(f"{j}\n" for j in jobs), "")
        if argv[1] == "show":
            blocks = [f"Id={u}\nActiveState={state.get(u, ('inactive', ''))[0]}\nJob={state.get(u, ('', ''))[1]}"
                      for u in units]
            return subprocess.CompletedProcess(argv, 0, "\n\n".join(blocks) + "\n", "")
        if argv[1] in ("stop", "restart") and "--job-mode=fail" in argv:
            for u in units:
                state[u] = (state[u][0], "901")
            if on_stop:
                on_stop(state)
            return subprocess.CompletedProcess(argv, stop_rc, "", "conflicting job" if stop_rc else "")
        raise AssertionError(f"unexpected systemctl call {argv}")
    return run, calls


def stops_of(calls, verb="stop"):
    """return the units each stop or restart call named"""
    return [c[c.index("--") + 1:] for c in calls if c[1] == verb]


TIMEOUTS = []
ORDER = []


def companion_failures():
    """return the failed companion-stop cases"""
    bad = []
    zero = launcher.companion_stop_units(0)
    for label, state, want_stop, want in (
            ("a self-stopped sandbox", {u: ("active", "") for u in zero}, zero, True),
            ("a restart whose jobs are queued", {u: ("active", "77") for u in zero}, None, True),
            ("a mix", {"rhizo-hostfs.service": ("active", ""), "rhizo-rtd.service": ("active", "12"),
                       "rhizo-audiod.service": ("failed", ""), "rhizo-deskd.service": ("activating", "0")},
             ["rhizo-hostfs.service", "rhizo-deskd.service"], True)):
        run, calls = systemctl_stand_in(dict(state))
        logs = []
        got = launcher.stop_companion_units(0, logs.append, run=run, unit="androidd.service")
        if got is not want or (stops_of(calls) != ([want_stop] if want_stop else [])):
            bad.append(f"{label}: want {want} and a stop of {want_stop}; got {got}, {stops_of(calls)}, {logs}")
    for label, jobs, want_verb in (
            ("a start queued on androidd", ["91 androidd.service start waiting"], "restart"),
            ("a stop job on androidd", ["92 androidd.service stop running"], "stop"),
            ("a start queued on another unit", ["93 androidd@2.service start waiting"], "stop"),
            ("the unit's own failing start", ["94 androidd.service start running"], "stop")):
        run, calls = systemctl_stand_in({u: ("active", "") for u in zero}, jobs=jobs)
        logs = []
        got = launcher.stop_companion_units(0, logs.append, run=run, unit="androidd.service")
        other = "stop" if want_verb == "restart" else "restart"
        if got is not True or stops_of(calls, want_verb) != [zero] or stops_of(calls, other):
            bad.append(f"{label}: want a {want_verb} of every companion; got {got}, {calls}, {logs}")
    TIMEOUTS.clear()
    run, calls = systemctl_stand_in({u: ("active", "") for u in zero})
    logs = []
    got = launcher.stop_companion_units(0, logs.append, run=run, unit="androidd.service", budget_s=3)
    if got is not True or not TIMEOUTS or any(t is None or t > 3 for t in TIMEOUTS):
        bad.append(f"a 3s budget: want every systemctl call bounded by it; got {got}, {TIMEOUTS}")
    run, calls = systemctl_stand_in({u: ("active", "") for u in zero})
    logs = []
    got = launcher.stop_companion_units(0, logs.append, run=run, unit="androidd.service", budget_s=0)
    if got is not False or calls or not any("within 0s" in m for m in logs):
        bad.append(f"a spent budget: want False, no systemctl call and the budget named; got {got}, {calls}, {logs}")
    state = {"rhizo-hostfs.service": ("active", "")}
    run, calls = systemctl_stand_in(state, stop_rc=1, on_stop=lambda st: st.update({"rhizo-hostfs.service":
                                                                                     ("inactive", "33")}))
    if launcher.stop_companion_units(0, [].append, run=run, unit="androidd.service") is not True:
        bad.append("a stop refused because a start of the next sandbox queued a job first: want True")
    state = {"rhizo-hostfs.service": ("active", "")}
    run, calls = systemctl_stand_in(state, stop_rc=1, on_stop=lambda st: st.update({"rhizo-hostfs.service":
                                                                                     ("active", "")}))
    logs = []
    if launcher.stop_companion_units(0, logs.append, run=run, unit="androidd.service") is not False \
            or not any("refused:companions-left" in m and "rhizo-hostfs.service" in m for m in logs):
        bad.append(f"a companion still running after a refused stop: want False and refused:companions-left; got {logs}")
    want7 = ["rhizo-inputd@7.service", "rhizo-inputd-uhid@7.service", "rhizo-server-idle@7.service"]
    if launcher.companion_stop_units(7) != want7:
        bad.append(f"instance 7's companions: want {want7}; got {launcher.companion_stop_units(7)}")
    return bad


def lock_holder(records):
    """fork a process holding records' start lock"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        fd = launcher.take_start_lock(records)
        os.write(w, b"1" if fd is not None else b"0")
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        while True:
            signal.pause()
    os.close(w)
    ready = os.read(r, 1)
    os.close(r)
    if ready != b"1":
        raise AssertionError("the stand-in launcher could not take the start lock")
    return pid


def owner_failures():
    """return the stop-ownership cases that went wrong"""
    bad = []
    saved_mode = os.environ.get("RHIZO_SELINUX_MODE")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            for label, mode, held, records, want, needle in (
                    ("a free start lock", "namespace", False, "free", True, None),
                    ("a start lock another launcher holds", "namespace", True, "held", False, "another launcher holds"),
                    ("an unopenable records dir", "namespace", False, "file/records", None, "refused:stop-owner-unknown"),
                    ("host mode", "host", False, "host", True, None)):
                os.environ["RHIZO_SELINUX_MODE"] = mode
                path = os.path.join(tmp, records)
                if records.startswith("file/"):
                    open(os.path.join(tmp, "file"), "w").close()
                holder = lock_holder(path) if held else None
                logs = []
                try:
                    got = launcher.stop_owns_instance(logs.append, records_dir=path)
                finally:
                    if holder:
                        os.kill(holder, signal.SIGKILL)
                        os.waitpid(holder, 0)
                    for fd in launcher._STOP_START_LOCK:
                        os.close(fd)
                    del launcher._STOP_START_LOCK[:]
                if got is not want or (needle and not any(needle in m for m in logs)) \
                        or (mode == "host" and os.path.exists(path)):
                    bad.append(f"stop ownership with {label}: want {want} and {needle!r} logged; got {got}, {logs}")
    finally:
        if saved_mode is None:
            os.environ.pop("RHIZO_SELINUX_MODE", None)
        else:
            os.environ["RHIZO_SELINUX_MODE"] = saved_mode
    for owns, want_code in ((False, 0), (None, 1)):
        code, released, states, logs, stops = scenario(kill_refused=False, owns=owns)
        if code != want_code or released or stops or not all(states.values()):
            bad.append(f"a stop owning {owns}: want exit {want_code} and nothing killed, released or stopped; got "
                       f"{code}, {released}, {states}, {stops}")
    return bad


def main():
    """return the failures"""
    bad = companion_failures() + owner_failures()
    ORDER.clear()
    code, released, states, logs, stops = scenario(kill_refused=False)
    if ORDER[:1] != ["sweep"] or "companions" not in ORDER:
        bad.append(f"the stop's order: want the cgroup sweep before the companion stop; got {ORDER}")
    want = {"init": False, "app": False, "stray": False, "supervisor": True}
    if code != 0 or released != ["androidd-stop-post"] or states != want or stops != [launcher.SANDBOX_ID]:
        bad.append(f"a joiner-less sandbox left in its cgroup: want exit 0, the staging released, {want} and the "
                   f"instance's companions stopped; got {code}, {released}, {states}, {stops}, {logs[-3:]}")
    code, released, states, logs, stops = scenario(kill_refused=False, companions_stop=False)
    if code != 1 or released != ["androidd-stop-post"]:
        bad.append(f"companions that would not stop: want exit 1 after the release; got {code}, {released}")
    code, released, states, logs, stops = scenario(kill_refused=True)
    if code != 1 or released or states["init"] is not True or not any("still holds" in m for m in logs):
        bad.append(f"a sandbox cgroup that will not die: want exit 1, no release and the survivor named; got "
                   f"{code}, {released}, {states}, {logs[-3:]}")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("stop-sweeps-sandbox:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
