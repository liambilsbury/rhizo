#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "appsync", "resync.sh")
QUEUE = "/run/rhizo-app-events/queue"
STATE = "/run/rhizo-resync/queue.offset"
PRUNE = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "appsync", "remove-entries.sh")
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402
REARM = unit_files.unit_path(ROOT, "rhizo-resync-rearm.service")
REDEPLOY = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
TRIGGER = "/run/rhizo-app-events/trigger"
DRAIN_LINE = re.compile(r"^.*--drain-queue.*\\\n.*\n", re.M)
EVENT_BOUND_S = 10

STUB_APPSYNC = r'''
import os, sys, time
calls, release, full_rc = os.environ["STUB_CALLS"], os.environ["STUB_RELEASE"], int(os.environ["STUB_FULL_RC"])
args = sys.argv[1:]
def rec(line):
    with open(calls, "a") as fh:
        fh.write(line + "\n")
def move_trigger(at):
    """appwatch's next touch, once, while the pass named `at` runs"""
    trig, content = os.environ.get("STUB_TRIGGER"), os.environ.get("STUB_MOVE_TRIGGER")
    if not content or os.environ.get("STUB_MOVE_AT", "full") != at or os.path.exists(calls + ".moved"):
        return
    open(calls + ".moved", "w").close()
    st = os.stat(trig)
    with open(trig, "w") as fh:
        fh.write(content + "\n")
    if os.environ.get("STUB_KEEP_MTIME"):
        os.utime(trig, ns=(st.st_atime_ns, st.st_mtime_ns))
def swap_init(at):
    """the sandbox restarted under this pass: its init 4242 gone, init 4343 up, once"""
    proc = os.environ.get("STUB_SWAP_PROC")
    if not proc or os.environ.get("STUB_SWAP_AT", "full") != at or os.path.exists(calls + ".swapped"):
        return
    open(calls + ".swapped", "w").close()
    os.rename(os.path.join(proc, "4242"), os.path.join(proc, "4343"))
def nth_rc(kind, prefix, default):
    """the Nth call's rc from STUB_<kind>_RCS when a case scripts several, else default"""
    rcs = os.environ.get("STUB_%s_RCS" % kind, "").split()
    n = sum(1 for l in open(calls).read().splitlines() if l.startswith(prefix))
    return int(rcs[min(n, len(rcs)) - 1]) if rcs else default
if "--reconcile-only" in args:
    rec("reconcile " + args[-1])
    move_trigger("reconcile")
    swap_init("reconcile")
    sys.exit(nth_rc("RECONCILE", "reconcile", 0))
elif "--drain-queue" in args:
    pid = int(args[args.index("--while-pid") + 1])
    try:
        argv = open("/proc/%d/cmdline" % pid, "rb").read().split(b"\0")
    except OSError:
        argv = []
    is_full = (any(a.endswith(b"appsync.py") for a in argv)
               and not {b"--drain-queue", b"--reconcile-only"} & set(argv))
    running = bool(argv) and "full-end" not in open(calls).read()
    rec("drain while-pid=%s is-full-pass=%s full-running=%s queue=%s state=%s" % (
        pid, is_full, running,
        args[args.index("--drain-queue") + 1], args[args.index("--queue-state") + 1]))
    rcs = os.environ.get("STUB_DRAIN_RCS", "").split()
    n = sum(1 for l in open(calls).read().splitlines() if l.startswith("drain "))
    sys.exit(int(rcs[min(n, len(rcs)) - 1]) if rcs else int(os.environ["STUB_DRAIN_RC"]))
else:
    rec("full-start %d init=%s" % (os.getpid(), args[-1]))
    move_trigger("full")
    swap_init("full")
    deadline = time.monotonic() + 30
    while not os.path.exists(release) and time.monotonic() < deadline:
        time.sleep(0.02)
    rec("full-end")
    sys.exit(nth_rc("FULL", "full-start", full_rc))
'''


def tree(root, script_text):
    """build a fixture tree around the script and return its paths"""
    tools, bin_ = os.path.join(root, "tools"), os.path.join(root, "bin")
    for d in (tools, bin_):
        os.makedirs(d)
    with open(os.path.join(tools, "resync.sh"), "w") as f:
        f.write(script_text)
    with open(os.path.join(tools, "appsync.py"), "w") as f:
        f.write(STUB_APPSYNC)
    prepare = os.path.join(root, "install", "prepare")
    os.makedirs(prepare)
    with open(os.path.join(prepare, "await-boot-completed.py"), "w") as f:
        f.write("import sys\nsys.exit(0)\n")
    proc = os.path.join(root, "proc", "4242")
    os.makedirs(proc)
    open(os.path.join(proc, "cmdline"), "wb").write(b"/system/bin/init\0second_stage\0")
    open(os.path.join(proc, "cgroup"), "w").write("0::/rhizo/init\n")
    for name, body in (("systemctl", "exit 0\n"),):
        path = os.path.join(bin_, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
    return os.path.join(tools, "resync.sh"), bin_


def stamp_bad(label, synced_path, want):
    """return a failure for a mismatched stamp"""
    got = open(synced_path).read() if os.path.exists(synced_path) else None
    if got != want:
        return ["%s: synced stamp %r, want %r" % (label, got, want)]
    return []


def wait_for(pred):
    """wait until a predicate holds"""
    deadline = time.monotonic() + EVENT_BOUND_S
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(0.02)
    return pred()


def run_case(script_text, full_rc, drain_rc=0):
    """run the script and return failures"""
    bad = []
    root = tempfile.mkdtemp(prefix="resync-drain-")
    try:
        script, bin_ = tree(root, script_text)
        calls, release = os.path.join(root, "calls"), os.path.join(root, "release")
        open(calls, "w").close()
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                   RHIZO_PROC_ROOT=os.path.join(os.path.dirname(bin_), "proc"),
                   STUB_CALLS=calls, STUB_RELEASE=release, STUB_FULL_RC=str(full_rc),
                   STUB_DRAIN_RC=str(drain_rc), RHIZO_RESYNC_SYNCED=os.path.join(root, "synced"),
                   RHIZO_RESYNC_TRIGGER=os.path.join(root, "trigger"))
        proc = subprocess.Popen(["/bin/sh", script], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        read = lambda: open(calls).read()
        if not wait_for(lambda: "full-start" in read() and ("drain " in read() or proc.poll() is not None)):
            bad.append("neither a drain nor the script's exit within %ds of the full pass starting: %r"
                       % (EVENT_BOUND_S, read()))
        drains = [l for l in read().splitlines() if l.startswith("drain ")]
        if not drains:
            bad.append("no --drain-queue run while the full pass ran: %r" % read())
        else:
            want = "is-full-pass=True full-running=True queue=%s state=%s" % (QUEUE, STATE)
            if want not in drains[0]:
                bad.append("the drain was not bound to the running full pass (%r, want %r)" % (drains[0], want))
        open(release, "w").close()
        try:
            out, err = proc.communicate(timeout=EVENT_BOUND_S)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            bad.append("the script did not exit within %ds of the full pass ending" % EVENT_BOUND_S)
        want_rc = 0 if full_rc == 0 and drain_rc == 0 else 1
        if (proc.returncode == 0) != (want_rc == 0):
            bad.append("full pass rc=%d, drain rc=%d: script exited %d (stderr: %s)"
                       % (full_rc, drain_rc, proc.returncode, err.strip()[-200:]))
        if ("[rhizo-resync] synced init 4242" in out.splitlines()) != (want_rc == 0):
            bad.append("full pass rc=%d, drain rc=%d: 'synced init 4242' %s in stdout %r"
                       % (full_rc, drain_rc, "missing" if want_rc == 0 else "printed", out[-200:]))
        if "full-end" not in read():
            bad.append("the full pass never finished: %r" % read())
        bad += stamp_bad("full pass rc=%d, drain rc=%d" % (full_rc, drain_rc), os.path.join(root, "synced"),
                         "init=4242 trigger=none\n" if want_rc == 0 else None)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def run_passes(script_text, drain_rcs, keep_mtime=False):
    """run the script through two passes"""
    bad = []
    root = tempfile.mkdtemp(prefix="resync-drain-passes-")
    try:
        script, bin_ = tree(root, script_text)
        calls, release = os.path.join(root, "calls"), os.path.join(root, "release")
        open(calls, "w").close()
        open(release, "w").close()
        trigger = os.path.join(root, "trigger")
        with open(trigger, "w") as fh:
            fh.write("t1\n")
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                   RHIZO_PROC_ROOT=os.path.join(os.path.dirname(bin_), "proc"),
                   STUB_CALLS=calls, STUB_RELEASE=release, STUB_FULL_RC="0", STUB_DRAIN_RC="0",
                   STUB_DRAIN_RCS=" ".join(str(r) for r in drain_rcs),
                   RHIZO_RESYNC_SYNCED=os.path.join(root, "synced"),
                   RHIZO_RESYNC_TRIGGER=trigger, STUB_TRIGGER=trigger, STUB_MOVE_TRIGGER="t2",
                   **({"STUB_KEEP_MTIME": "1"} if keep_mtime else {}))
        r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True,
                           timeout=EVENT_BOUND_S * 3)
        drains = [l for l in open(calls).read().splitlines() if l.startswith("drain ")]
        label = "drain rc %s over two passes%s" % ("/".join(str(x) for x in drain_rcs),
                                                    ", the trigger's mtime kept" if keep_mtime else "")
        if len(drains) != 2:
            bad.append("%s: %d drain run(s), want one per pass (2): %r" % (label, len(drains), open(calls).read()))
        want_ok = drain_rcs[-1] == 0
        if (r.returncode == 0) != want_ok:
            bad.append("%s: script exited %d, want %s (stderr: %s)"
                       % (label, r.returncode, "0" if want_ok else "nonzero", r.stderr.strip()[-200:]))
        if ("[rhizo-resync] synced init 4242" in r.stdout.splitlines()) != want_ok:
            bad.append("%s: 'synced init 4242' %s" % (label, "missing" if want_ok else "printed"))
        bad += stamp_bad(label, os.path.join(root, "synced"), "init=4242 trigger=t2\n" if want_ok else None)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def run_init_swap(script_text, first_full_rc=0):
    """run the script with a replaced init"""
    bad = []
    root = tempfile.mkdtemp(prefix="resync-drain-swap-")
    try:
        script, bin_ = tree(root, script_text)
        calls, release = os.path.join(root, "calls"), os.path.join(root, "release")
        open(calls, "w").close()
        open(release, "w").close()
        trigger, synced = os.path.join(root, "trigger"), os.path.join(root, "synced")
        with open(trigger, "w") as fh:
            fh.write("t1\n")
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                   RHIZO_PROC_ROOT=os.path.join(root, "proc"), STUB_CALLS=calls, STUB_RELEASE=release,
                   STUB_FULL_RC="0", STUB_FULL_RCS="%d 0" % first_full_rc, STUB_DRAIN_RC="0",
                   RHIZO_RESYNC_SYNCED=synced, RHIZO_RESYNC_TRIGGER=trigger,
                   STUB_SWAP_PROC=os.path.join(root, "proc"))
        r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True, timeout=EVENT_BOUND_S * 3)
        label = "the sandbox restarted under the pass" + (
            ", which failed (rc=%d)" % first_full_rc if first_full_rc else "")
        if r.returncode != 0:
            bad.append("%s: script exited %d (stderr: %s)" % (label, r.returncode, r.stderr.strip()[-200:]))
        fulls = [l.split("init=")[1] for l in open(calls).read().splitlines() if l.startswith("full-start")]
        if fulls != ["4242", "4343"]:
            bad.append("%s: full passes ran against %r, want ['4242', '4343']" % (label, fulls))
        bad += stamp_bad(label, synced, "init=4343 trigger=t1\n")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def run_failed_pass_moved(script_text):
    """run the script with a failed pass"""
    bad = []
    root = tempfile.mkdtemp(prefix="resync-drain-failmove-")
    try:
        script, bin_ = tree(root, script_text)
        calls, release = os.path.join(root, "calls"), os.path.join(root, "release")
        open(calls, "w").close()
        open(release, "w").close()
        trigger, synced = os.path.join(root, "trigger"), os.path.join(root, "synced")
        with open(trigger, "w") as fh:
            fh.write("t1\n")
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                   RHIZO_PROC_ROOT=os.path.join(root, "proc"), STUB_CALLS=calls, STUB_RELEASE=release,
                   STUB_FULL_RC="0", STUB_FULL_RCS="1 0", STUB_DRAIN_RC="0", RHIZO_RESYNC_SYNCED=synced,
                   RHIZO_RESYNC_TRIGGER=trigger, STUB_TRIGGER=trigger, STUB_MOVE_TRIGGER="t2")
        r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True, timeout=EVENT_BOUND_S * 3)
        label = "a failed pass the trigger moved under"
        if r.returncode != 0:
            bad.append("%s: script exited %d (stderr: %s)" % (label, r.returncode, r.stderr.strip()[-200:]))
        n = sum(1 for l in open(calls).read().splitlines() if l.startswith("full-start"))
        if n != 2:
            bad.append("%s: %d full pass(es), want 2" % (label, n))
        bad += stamp_bad(label, synced, "init=4242 trigger=t2\n")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def run_unwritable_stamp(script_text):
    """run the script with an unwritable stamp"""
    root = tempfile.mkdtemp(prefix="resync-drain-stamp-")
    try:
        script, bin_ = tree(root, script_text)
        calls, release = os.path.join(root, "calls"), os.path.join(root, "release")
        open(calls, "w").close()
        open(release, "w").close()
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                   RHIZO_PROC_ROOT=os.path.join(root, "proc"), STUB_CALLS=calls, STUB_RELEASE=release,
                   STUB_FULL_RC="0", STUB_DRAIN_RC="0",
                   RHIZO_RESYNC_SYNCED=os.path.join(root, "no-such-dir", "synced"),
                   RHIZO_RESYNC_TRIGGER=os.path.join(root, "trigger"))
        r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True, timeout=EVENT_BOUND_S * 3)
        if r.returncode == 0 or "could not record" not in r.stderr:
            return ["an unwritable stamp: script exited %d (stderr: %s), want nonzero naming the stamp"
                    % (r.returncode, r.stderr.strip()[-200:])]
        return []
    finally:
        shutil.rmtree(root, ignore_errors=True)


def run_prune(prune_text, label, init=True, move=False, stamp_dir_ok=True, want_rc=0,
              want_stamp=None, want_reconciles=1, swap=False, reconcile_rcs=""):
    """run remove-entries.sh with a stub appsync.py"""
    bad = []
    root = tempfile.mkdtemp(prefix="prune-stamp-")
    try:
        script = os.path.join(root, "remove-entries.sh")
        with open(script, "w") as f:
            f.write(prune_text)
        appsync = os.path.join(root, "appsync.py")
        with open(appsync, "w") as f:
            f.write(STUB_APPSYNC)
        proc = os.path.join(root, "proc", "4242")
        os.makedirs(proc)
        if init:
            open(os.path.join(proc, "cmdline"), "wb").write(b"/system/bin/init\0second_stage\0")
            open(os.path.join(proc, "cgroup"), "w").write("0::/rhizo/init\n")
        calls, trigger = os.path.join(root, "calls"), os.path.join(root, "trigger")
        open(calls, "w").close()
        with open(trigger, "w") as fh:
            fh.write("t1\n")
        synced = os.path.join(root, "synced") if stamp_dir_ok else os.path.join(root, "no-such-dir", "synced")
        env = dict(os.environ, RHIZO_PROC_ROOT=os.path.join(root, "proc"), RHIZO_PRUNE_APPSYNC=appsync,
                   RHIZO_PRUNE_SYNCED=synced, RHIZO_RESYNC_TRIGGER=trigger, STUB_CALLS=calls,
                   STUB_RELEASE=os.path.join(root, "release"), STUB_FULL_RC="0", STUB_DRAIN_RC="0",
                   STUB_TRIGGER=trigger, STUB_MOVE_AT="reconcile", STUB_KEEP_MTIME="1",
                   STUB_RECONCILE_RCS=reconcile_rcs,
                   **({"STUB_MOVE_TRIGGER": "t2"} if move else {}),
                   **({"STUB_SWAP_PROC": os.path.join(root, "proc"), "STUB_SWAP_AT": "reconcile"} if swap else {}))
        r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True, timeout=EVENT_BOUND_S * 3)
        if (r.returncode == 0) != (want_rc == 0):
            bad.append("prune, %s: exited %d, want %s (stderr: %s)"
                       % (label, r.returncode, "0" if want_rc == 0 else "nonzero", r.stderr.strip()[-200:]))
        n = sum(1 for l in open(calls).read().splitlines() if l.startswith("reconcile"))
        if n != want_reconciles:
            bad.append("prune, %s: %d reconcile(s), want %d" % (label, n, want_reconciles))
        if stamp_dir_ok:
            bad += stamp_bad("prune, " + label, synced, want_stamp)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    return bad


def check_prune(prune_text):
    """run the prune script in each reconcile case"""
    return (run_prune(prune_text, "a clean reconcile", want_stamp="init=4242 trigger=t1\n")
            + run_prune(prune_text, "the sandbox restarted under the reconcile", swap=True,
                        want_stamp="init=4343 trigger=t1\n", want_reconciles=2)
            + run_prune(prune_text, "the trigger's content moved in one mtime during the reconcile", move=True,
                        want_stamp="init=4242 trigger=t2\n", want_reconciles=2)
            + run_prune(prune_text, "no sandbox", init=False, want_stamp="nosandbox trigger=t1\n",
                        want_reconciles=0)
            + run_prune(prune_text, "an unwritable stamp", stamp_dir_ok=False, want_rc=1)
            + run_prune(prune_text, "a failed reconcile", reconcile_rcs="1", want_rc=1)
            + run_prune(prune_text, "the sandbox restarted under a reconcile that failed", swap=True,
                        reconcile_rcs="1 0", want_stamp="init=4343 trigger=t1\n", want_reconciles=2)
            + run_prune(prune_text, "the trigger moved under a reconcile that failed", move=True,
                        reconcile_rcs="1 0", want_stamp="init=4242 trigger=t2\n", want_reconciles=2))


def trigger_path_units():
    """return the .path units on the trigger"""
    units = []
    for name, rel in sorted(unit_files.unit_files(ROOT, (".path",)).items()):
        with open(os.path.join(ROOT, rel)) as fh:
            if any(re.match(r"^Path(Modified|Changed)=%s$" % re.escape(TRIGGER), line.strip()) for line in fh):
                units.append(name)
    return units


def check_rearm(rearm_text, path_units):
    """check the restart order in the rearm unit"""
    order = []
    for m in re.finditer(r"^ExecStart=-?\S*systemctl\s+(?:--\S+\s+)*(?:re)?start\s+(.+?)\s*$",
                         rearm_text, re.M):
        order += [u for u in m.group(1).split() if not u.startswith("-")]
    if "rhizo-app-events.service" not in order:
        return ["rearm: no `systemctl restart rhizo-app-events.service` ExecStart= in %s" % REARM]
    last_appwatch = len(order) - 1 - order[::-1].index("rhizo-app-events.service")
    return (["rearm: %s never restarts %s"
             % (os.path.basename(REARM), u) for u in path_units if u not in order]
            + ["rearm: %s restarts %s after rhizo-app-events.service" % (os.path.basename(REARM), u)
               for u in path_units if u in order[last_appwatch:]])


def check_rearm_stops(rearm_text, path_units):
    """check the rearm unit stops each triggered service first"""
    stopped, bad = set(), []
    for verb, units in re.findall(r"^ExecStart=-?\S*systemctl\s+(?:--\S+\s+)*(stop|restart|start)\s+(.+?)\s*$",
                                  rearm_text, re.M):
        if verb != "stop":
            break
        stopped.update(units.split())
    for path_unit in path_units:
        text = read_tools_unit(path_unit)
        m = re.search(r"^Unit=(\S+)$", text, re.M)
        service = m.group(1) if m else path_unit[:-len(".path")] + ".service"
        if service not in stopped:
            bad.append("rearm: %s does not stop %s before it re-arms %s"
                       % (os.path.basename(REARM), service, path_unit))
    return bad


def rearmed_units(rearm_text):
    """return the units the rearm unit restarts"""
    order = []
    for m in re.finditer(r"^ExecStart=-?\S*systemctl\s+(?:--\S+\s+)*(?:re)?start\s+(.+?)\s*$",
                         rearm_text, re.M):
        order += [u for u in m.group(1).split() if not u.startswith("-")]
    return order


def check_start_limits(rearm_text, read_unit):
    """check StartLimitIntervalSec in the restarted units"""
    bad = []
    for unit in dict.fromkeys(rearmed_units(rearm_text)):
        section, limited = None, True
        for line in read_unit(unit).splitlines():
            line = line.strip()
            if line.startswith("["):
                section = line
            elif section == "[Unit]" and line == "StartLimitIntervalSec=0":
                limited = False
        if limited:
            bad.append("start limit: %s is restarted by every re-arm site but keeps systemd's 5-in-10s "
                       "start limit ([Unit] StartLimitIntervalSec=0 missing)" % unit)
    return bad


def read_tools_unit(unit):
    """return the text of a unit file"""
    with open(unit_files.unit_path(ROOT, unit)) as fh:
        return fh.read()


def check_redeploy(redeploy_text, path_units):
    """check the appwatch restart in redeploy.sh"""
    bad = []
    for n, line in enumerate(redeploy_text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        order = []
        for m in re.finditer(r"systemctl\s+(?:re)?start\s+((?:--no-block\s+)?(?:[\w@.-]+\.(?:service|path)\s*)+)",
                             line):
            order += [u for u in m.group(1).split() if not u.startswith("-")]
        restarted = [u for u in path_units if u in order]
        if not restarted:
            continue
        tail_from = max(len(order) - 1 - order[::-1].index(u) for u in restarted)
        if "rhizo-app-events.service" not in order[tail_from:]:
            bad.append("redeploy.sh:%d restarts %s with no rhizo-app-events.service restart after it"
                       % (n, " and ".join(restarted)))
    return bad


def check(script_text):
    """return the problems from every drain case of the script"""
    return (run_case(script_text, 0) + ["failing full pass: " + b for b in run_case(script_text, 3)]
            + ["failing drain: " + b for b in run_case(script_text, 0, 1)]
            + run_passes(script_text, [1, 0]) + run_passes(script_text, [1, 1])
            + run_passes(script_text, [0, 0], keep_mtime=True) + run_unwritable_stamp(script_text)
            + run_init_swap(script_text) + run_init_swap(script_text, 1)
            + run_failed_pass_moved(script_text))


def main():
    """run the drain checks and mutant cases"""
    selftest = "--selftest" in sys.argv[1:]
    name = "check-resync-drain" + (" --selftest" if selftest else "")
    text = open(SCRIPT).read()
    rearm_text = open(REARM).read()
    path_units = trigger_path_units()
    if sorted(path_units) != ["rhizo-remove-entries.path", "rhizo-resync.path"]:
        print("FAIL: %s: expected rhizo-remove-entries.path and rhizo-resync.path on %s, found %s"
              % (name, TRIGGER, path_units))
        return 1
    redeploy_text = open(REDEPLOY).read()
    bad = (check(text) + check_prune(open(PRUNE).read()) + check_rearm(rearm_text, path_units)
           + check_rearm_stops(rearm_text, path_units)
           + check_redeploy(redeploy_text, path_units) + check_start_limits(rearm_text, read_tools_unit))
    if bad:
        print("FAIL: %s: %s" % (name, "; ".join(bad)))
        return 1
    if not selftest:
        print("%s: OK (the queue drains beside the running full pass, bound to its pid, and a clean run "
              "stamps the trigger it synced)" % name)
        return 0
    mutant, n = DRAIN_LINE.subn("", text)
    if n == 0:
        print("%s: FAIL -- no --drain-queue line in %s to remove" % (name, SCRIPT))
        return 1
    parsed = subprocess.run(["/bin/sh", "-n"], input=mutant, text=True, capture_output=True)
    if parsed.returncode != 0:
        print("%s: FAIL -- the script with its drain removed does not parse: %s"
              % (name, parsed.stderr.strip()))
        return 1
    if not any("no --drain-queue run" in b for b in run_case(mutant, 0)):
        print("%s: FAIL -- the script with its drain removed was not caught" % name)
        return 1
    no_reset, n = re.subn(r"^  drain_rc=0\n", "", text, count=1, flags=re.M)
    if n != 1:
        print("%s: FAIL -- no per-pass `  drain_rc=0` in %s to remove" % (name, SCRIPT))
        return 1
    if not any(b.startswith("drain rc 1/0 over two passes: script exited") for b in run_passes(no_reset, [1, 0])):
        print("%s: FAIL -- the script with no per-pass drain_rc reset was not caught" % name)
        return 1
    unstamped, n = re.subn(r'^    stamp "init=\$INIT trigger=\$after"\n', "", text, count=1, flags=re.M)
    if n != 1:
        print("%s: FAIL -- no synced-stamp write in %s to remove" % (name, SCRIPT))
        return 1
    if not any("synced stamp None, want 'init=4242" in b for b in run_case(unstamped, 0)):
        print("%s: FAIL -- the script with no synced-stamp write was not caught" % name)
        return 1
    by_mtime, n = re.subn(r'^  \{ IFS= read -r _tn < "\$TRIGGER"; \} 2>/dev/null \|\| true\n',
                          '  _tn=$(stat -c %y "$TRIGGER" 2>/dev/null) || true\n', text, count=1, flags=re.M)
    if n != 1:
        print("%s: FAIL -- no content read of the trigger in %s to swap for its mtime" % (name, SCRIPT))
        return 1
    if not any("the trigger's mtime kept" in b for b in run_passes(by_mtime, [0, 0], keep_mtime=True)):
        print("%s: FAIL -- the script reading the trigger's mtime was not caught" % name)
        return 1
    lenient, n = re.subn(r'^  echo "\[rhizo-resync\] could not record .*\n  exit 1\n',
                         '  return 0\n', text, count=1, flags=re.M)
    if n != 1 or not run_unwritable_stamp(lenient):
        print("%s: FAIL -- the script whose failed stamp write exits 0 was not caught" % name)
        return 1
    unchecked, n = re.subn(r'^  now_init=\$\(stack_init_pid\)\n.*?^  fi\n', "", text, count=1, flags=re.M | re.S)
    if n != 1 or not any("the sandbox restarted under the pass" in b for b in run_init_swap(unchecked)):
        print("%s: FAIL -- the script that never re-reads its init after a pass was not caught" % name)
        return 1
    aborting, n = re.subn(r'^  wait "\$full" \|\| full_rc=\$\?\n', '  wait "$full"\n', text, count=1, flags=re.M)
    if n != 1:
        print("%s: FAIL -- no `wait \"$full\" || full_rc=$?` in %s to revert" % (name, SCRIPT))
        return 1
    if not (any("the sandbox restarted under the pass, which failed" in b for b in run_init_swap(aborting, 1))
            and run_failed_pass_moved(aborting)):
        print("%s: FAIL -- the script exiting on its failed pass before the re-reads was not caught" % name)
        return 1
    prune_text = open(PRUNE).read()
    prune_aborting, n = re.subn(r'--reconcile-only "\$INIT" \|\| rc=\$\?$', '--reconcile-only "$INIT" || exit 1',
                                prune_text, count=1, flags=re.M)
    if n != 1 or not any("under a reconcile that failed" in b for b in check_prune(prune_aborting)):
        print("%s: FAIL -- remove-entries.sh exiting on a failed reconcile before its re-reads was not caught" % name)
        return 1
    unstamped_prune, n = re.subn(r'^    stamp "init=\$INIT trigger=\$before"\n', "", prune_text, count=1, flags=re.M)
    if n != 1 or not any("prune, a clean reconcile: synced stamp None" in b for b in check_prune(unstamped_prune)):
        print("%s: FAIL -- remove-entries.sh with no stamp was not caught" % name)
        return 1
    appwatch_line = "ExecStart=/usr/bin/systemctl restart rhizo-app-events.service\n"
    if rearm_text.count(appwatch_line) != 1:
        print("%s: FAIL -- no single `%s` in %s to move" % (name, appwatch_line.strip(), REARM))
        return 1
    first = re.search(r"^ExecStart=", rearm_text, re.M).start()
    without = rearm_text.replace(appwatch_line, "")
    appwatch_first = without[:first] + appwatch_line + without[first:]
    caught = check_rearm(appwatch_first, path_units)
    if not all(any(u in b for b in caught) for u in path_units):
        print("%s: FAIL -- a rearm restarting appwatch before %s was not caught (%s)"
              % (name, " and ".join(path_units), caught))
        return 1
    path_lines = [l for l in rearm_text.splitlines(True)
                  if re.match(r"^ExecStart=\S*systemctl restart \S+\.path$", l.strip())]
    bare = rearm_text
    for l in path_lines:
        bare = bare.replace(l, "")
    at = bare.index(appwatch_line) + len(appwatch_line)
    one_line = bare[:at] + "ExecStart=/usr/bin/systemctl restart %s\n" % " ".join(path_units) + bare[at:]
    no_block = bare[:at] + "".join("ExecStart=-/usr/bin/systemctl --no-block restart %s\n" % u
                                   for u in path_units) + bare[at:]
    for label, mutant in (("one two-unit line", one_line), ("--no-block lines", no_block)):
        caught = check_rearm(mutant, path_units)
        if not all(any(u in b and "after rhizo-app-events" in b for b in caught) for u in path_units):
            print("%s: FAIL -- a rearm restarting %s after appwatch as %s was not caught (%s)"
                  % (name, " and ".join(path_units), label, caught))
            return 1
    if len(path_lines) != len(path_units):
        print("%s: FAIL -- %d .path restart lines in %s for %d trigger units"
              % (name, len(path_lines), REARM, len(path_units)))
        return 1
    dropped = rearm_text.replace(path_lines[0], "")
    caught = check_rearm(dropped, path_units)
    if not any("never restarts" in b for b in caught):
        print("%s: FAIL -- a rearm that never restarts %s was not caught (%s)"
              % (name, path_lines[0].split()[-1], caught))
        return 1
    no_replay, n = re.subn(r"; systemctl restart rhizo-app-events\.service(?=; systemctl start --no-block)",
                           "", redeploy_text)
    if n < 1:
        print("%s: FAIL -- no post-flip `systemctl restart rhizo-app-events.service` in %s to remove"
              % (name, REDEPLOY))
        return 1
    caught = check_redeploy(no_replay, path_units)
    if len(caught) != n:
        print("%s: FAIL -- %d post-flip arming line(s) with no appwatch restart after them, %d caught (%s)"
              % (name, n, len(caught), caught))
        return 1
    for unit in ("rhizo-app-events.service", "rhizo-resync.path"):
        limited, n = re.subn(r"^StartLimitIntervalSec=0\n", "", read_tools_unit(unit), flags=re.M)
        if n != 1:
            print("%s: FAIL -- no single `StartLimitIntervalSec=0` in %s to remove" % (name, unit))
            return 1
        caught = check_start_limits(rearm_text, lambda u, unit=unit, limited=limited:
                                    limited if u == unit else read_tools_unit(u))
        if not any(b.startswith("start limit: %s " % unit) for b in caught):
            print("%s: FAIL -- %s with its default start limit back was not caught (%s)" % (name, unit, caught))
            return 1
    unstopped, n = re.subn(r"^ExecStart=\S*systemctl stop .*\n", "", rearm_text, flags=re.M)
    late_stop = re.sub(r"^(ExecStart=\S*systemctl stop .*\n)((?:ExecStart=.*\n)+)", r"\2\1", rearm_text, flags=re.M)
    for label, mutant_rearm in (("with no stop", unstopped), ("stopping after it re-arms", late_stop)):
        caught = check_rearm_stops(mutant_rearm, path_units)
        if n != 1 or mutant_rearm == rearm_text or len(caught) != len(path_units):
            print("%s: FAIL -- a rearm %s was not caught for every triggered service (%s)" % (name, label, caught))
            return 1
    print("%s: OK (a script with no drain beside its full pass, one carrying a pass's failed drain "
          "into the next pass, one recording no synced stamp, one reading the trigger's mtime, one "
          "surviving a failed stamp write, one stamping a replaced init, one exiting on a failed "
          "pass before re-reading its init and trigger, a prune recording no stamp or doing the same "
          "on a failed reconcile, a rearm restarting a trigger .path unit after appwatch (one per line, two on one line, "
          "or --no-block) or never, a redeploy arming "
          "one with no appwatch restart after it, a re-armed unit keeping systemd's start limit, "
          "or a rearm leaving a sync from the last start running, is caught)" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
