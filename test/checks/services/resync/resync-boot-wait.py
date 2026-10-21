#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "appsync", "resync.sh")
PRE_FIX = '[ -n "$INIT" ] || exit 0\n'
WAIT_BLOCK = re.compile(r'^if \[ -z "\$INIT" \]; then\n.*?^fi\n', re.M | re.S)

DRAIN = ("appsync --local --drain-queue /run/rhizo-app-events/queue "
         "--queue-state /run/rhizo-resync/queue.offset --while-pid PID 4242")
CONCURRENT = 2

CASES = [
    ("the boot's own trigger waits for the boot, then syncs its init",
     True, False, 0, 0, ["await --instance 0", "appsync --local --reconcile-only 4242", "appsync --local 4242",
                         DRAIN]),
    ("no sandbox unit running: nothing to wait for and nothing synced",
     False, False, 0, 0, []),
    ("a boot that never completes is named, and nothing is synced",
     True, False, 1, 1, ["await --instance 0"]),
    ("init already running: still waits for the boot (user 0 unlocked), then syncs",
     True, True, 0, 0, ["await --instance 0", "appsync --local --reconcile-only 4242", "appsync --local 4242",
                        DRAIN]),
]


def tree(root, script_text, active, init_early, await_rc):
    """build a fixture tree around the script and return its paths"""
    tools, inst, bin_ = (os.path.join(root, d) for d in ("tools", "install", "bin"))
    for d in (tools, inst, bin_):
        os.makedirs(d)
    calls = os.path.join(root, "calls")
    open(calls, "w").close()
    booted = os.path.join(root, "proc", "4242")
    init_entry = ('import os\nos.makedirs(%r, exist_ok=True)\nopen(%r, "wb").write(b"/system/bin/init\\0second_stage\\0")\n'
                  'open(%r, "w").write("0::/rhizo/init\\n")\n'
                  % (booted, os.path.join(booted, "cmdline"), os.path.join(booted, "cgroup")))
    os.makedirs(os.path.join(root, "proc"))
    if init_early:
        exec(init_entry)
    with open(os.path.join(tools, "resync.sh"), "w") as f:
        f.write(script_text)

    def exe(path, body):
        """write an executable shell script"""
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    exe(os.path.join(bin_, "systemctl"),
        'case "$*" in *is-active*androidd.service*) exit %d ;; esac\nexit 0\n' % (0 if active else 3))
    with open(os.path.join(tools, "appsync.py"), "w") as f:
        f.write('import sys\nopen(%r, "a").write("appsync " + " ".join(sys.argv[1:]) + "\\n")\n' % calls)
    os.makedirs(os.path.join(inst, "prepare"), exist_ok=True)
    with open(os.path.join(inst, "prepare", "await-boot-completed.py"), "w") as f:
        f.write('import sys\nopen(%r, "a").write("await " + " ".join(sys.argv[1:3]) + "\\n")\n' % calls
                + (init_entry if await_rc == 0 else "") + 'sys.exit(%d)\n' % await_rc)
    return os.path.join(tools, "resync.sh"), bin_, calls


def run_cases(script_text):
    """run each case against the script and return the problems"""
    bad = []
    for name, active, init_early, await_rc, want_rc, want_calls in CASES:
        root = tempfile.mkdtemp(prefix="resync-boot-")
        try:
            script, bin_, calls = tree(root, script_text, active, init_early, await_rc)
            synced, trigger = os.path.join(root, "synced"), os.path.join(root, "trigger")
            with open(trigger, "w") as fh:
                fh.write("t1\n")
            env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                       RHIZO_PROC_ROOT=os.path.join(root, "proc"),
                       RHIZO_RESYNC_SYNCED=synced, RHIZO_RESYNC_TRIGGER=trigger)
            r = subprocess.run(["/bin/sh", script], env=env, capture_output=True, text=True, timeout=60)
            got = [re.sub(r"--while-pid [0-9]+", "--while-pid PID", l)
                   for l in open(calls).read().splitlines() if l]
            if DRAIN in want_calls:
                same = (got[:-CONCURRENT] == want_calls[:-CONCURRENT]
                        and sorted(got[-CONCURRENT:]) == sorted(want_calls[-CONCURRENT:]))
            else:
                same = got == want_calls
            if r.returncode != want_rc or not same:
                bad.append("%s: wanted rc=%d calls=%r, got rc=%d calls=%r (stderr: %s)"
                           % (name, want_rc, want_calls, r.returncode, got, r.stderr.strip()[-200:]))
            elif want_rc and "boot" not in r.stderr:
                bad.append("%s: exited %d without naming the boot on stderr (%r)" % (name, want_rc, r.stderr))
            if not active:
                got_stamp = open(synced).read() if os.path.exists(synced) else None
                if got_stamp != "nosandbox trigger=t1\n":
                    bad.append("%s: stamp %r, want 'nosandbox trigger=t1'" % (name, got_stamp))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    return bad


SERVICES = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE)))), "src", "services")
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
SCRIPT_DIRS = (("src", "services"), ("src", "androidd"))
UNBOUNDED_WAIT = "await-boot-completed.py"
SANDBOX_WAITS = (UNBOUNDED_WAIT, "--wait-for-storage")
BOOT_TARGETS = {"multi-user.target", "graphical.target", "default.target", "basic.target", "sysinit.target"}


def unit_keys(text):
    """return the Key=value pairs of a unit file"""
    keys, section = {}, None
    for line in text.replace("\\\n", " ").splitlines():
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            keys.setdefault((section, k.strip()), []).append(v.strip())
    return keys


def exec_script(repo, exec_start):
    """return the script an ExecStart runs"""
    for word in exec_start.split():
        base = os.path.basename(word)
        if word.startswith("/usr/bin/"):
            continue
        for d in SCRIPT_DIRS:
            for top, _, names in os.walk(os.path.join(repo, *d)):
                if base in names and "tests" not in top.split(os.sep):
                    return os.path.join(top, base)
    return None


REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
DROPIN_INSTALL = re.compile(r"debian/dropins/(\S+)\s*\\?\s*\n?\s*\S*?/([^/\s]+)\.d/\S+\.conf")


def installed_dropins(repo):
    """return the drop-in paths debian/rules installs"""
    rules = os.path.join(repo, "debian", "rules")
    out = {}
    if not os.path.isfile(rules):
        return out
    for f, unit in DROPIN_INSTALL.findall(open(rules).read()):
        out.setdefault(unit.strip('"'), []).append(os.path.join(repo, "debian", "dropins", f))
    return out


def merged_unit(path, dropins):
    """merge drop-in keys into the unit keys"""
    keys = unit_keys(open(path).read())
    for d in dropins:
        if not os.path.isfile(d):
            continue
        with open(d) as fh:
            text = fh.read().replace("\\\n", " ")
        section = None
        for line in text.splitlines():
            line = line.strip()
            if not line or line[0] in "#;":
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if v == "":
                    keys[(section, k)] = []
                else:
                    keys.setdefault((section, k), []).append(v)
    return keys


def boot_job_waits(repo=REPO):
    """return failure messages for boot-waiting oneshot units"""
    bad = []
    units = unit_files.unit_files(repo)
    dropins = installed_dropins(repo)
    for name in sorted(units):
        if not name.endswith(".path"):
            continue
        pk = unit_keys(open(os.path.join(repo, units[name])).read())
        wanted = " ".join(pk.get(("Install", "WantedBy"), []))
        if "multi-user.target" not in wanted.split():
            continue
        svc = (pk.get(("Path", "Unit")) or [name[:-5] + ".service"])[-1]
        if svc not in units:
            continue
        svc_path = os.path.join(repo, units[svc])
        if not os.path.isfile(svc_path):
            continue
        sk = merged_unit(svc_path, dropins.get(svc, []))
        stype = (sk.get(("Service", "Type")) or ["simple"])[-1]
        if stype != "oneshot":
            continue
        for ex in sk.get(("Service", "ExecStart"), []):
            script = exec_script(repo, ex)
            if UNBOUNDED_WAIT in ex or (script and UNBOUNDED_WAIT in open(script).read()):
                bad.append("%s (triggered by boot-enabled %s) is Type=oneshot and its ExecStart waits on %s: "
                           "the boot's start job stays open for the whole wait and pass"
                           % (svc, name, UNBOUNDED_WAIT))
    for name in sorted(units):
        if not name.endswith(".service"):
            continue
        sk = merged_unit(os.path.join(repo, units[name]), dropins.get(name, []))
        wanted = set(" ".join(sk.get(("Install", "WantedBy"), [])).split())
        if not wanted & BOOT_TARGETS:
            continue
        if (sk.get(("Service", "Type")) or ["simple"])[-1] != "oneshot":
            continue
        for ex in sk.get(("Service", "ExecStart"), []):
            script = exec_script(repo, ex)
            waits = [w for w in SANDBOX_WAITS
                     if w in ex or (script and w in open(script).read())]
            if waits:
                bad.append("%s is Type=oneshot, WantedBy=%s, and its ExecStart waits on the sandbox (%s) "
                           "-- want it from androidd.service's "
                           "own start instead" % (name, " ".join(sorted(wanted & BOOT_TARGETS)),
                                                  ", ".join(waits)))
    return bad


def boot_job_selftest():
    """run boot_job_waits on fixture units"""
    bad = []
    src = open(unit_files.unit_path(REPO, "rhizo-resync.service")).read()
    for want_flag, stype in ((True, "oneshot"), (False, "exec")):
        root = tempfile.mkdtemp(prefix="resync-boot-job-")
        try:
            units = os.path.join(root, "src", "services", "units")
            os.makedirs(units)
            shutil.copy(unit_files.unit_path(REPO, "rhizo-resync.path"), units)
            os.makedirs(os.path.join(root, "src", "services", "appsync"))
            shutil.copy(os.path.join(SERVICES, "appsync", "resync.sh"), os.path.join(root, "src", "services", "appsync"))
            with open(os.path.join(units, "resync.service"), "w") as f:
                f.write(re.sub(r"^Type=.*$", "Type=" + stype, src, count=1, flags=re.M))
            got = boot_job_waits(root)
            if bool(got) != want_flag:
                bad.append("Type=%s: wanted %s, got %r" % (stype, "flagged" if want_flag else "clean", got))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    exec_src = re.sub(r"^Type=.*$", "Type=exec", src, count=1, flags=re.M)
    oneshot = "[Service]\nType=oneshot\n"
    waiting_exec = ("[Service]\nExecStart=\nExecStart=/usr/bin/dash /usr/lib/rhizo/tools/waits.sh\n")
    install = ("\tinstall -D -m 0644 debian/dropins/%s \\\n"
               "\t                   $(UNITS)/rhizo-resync.service.d/10-x.conf\n")
    cases = [
        ("an installed drop-in making the unit oneshot", oneshot, True, True),
        ("the same drop-in, shipped by nothing", oneshot, False, False),
        ("an installed drop-in resetting ExecStart to another boot wait, on a oneshot",
         oneshot + waiting_exec[len("[Service]\n"):], True, True),
        ("an installed drop-in resetting ExecStart to a script with no boot wait",
         "[Service]\nType=oneshot\nExecStart=\nExecStart=/usr/bin/dash /usr/lib/rhizo/tools/quick.sh\n",
         True, False),
    ]
    for name, dropin, installed, want_flag in cases:
        root = tempfile.mkdtemp(prefix="resync-boot-job-dropin-")
        try:
            scripts = os.path.join(root, "src", "services")
            tools = os.path.join(scripts, "units")
            os.makedirs(tools)
            os.makedirs(os.path.join(root, "debian", "dropins"))
            shutil.copy(unit_files.unit_path(REPO, "rhizo-resync.path"), tools)
            shutil.copy(os.path.join(SERVICES, "appsync", "resync.sh"), scripts)
            with open(os.path.join(tools, "resync.service"), "w") as f:
                f.write(exec_src)
            with open(os.path.join(scripts, "waits.sh"), "w") as f:
                f.write("python3 /usr/lib/rhizo/install/%s --timeout 900\n" % UNBOUNDED_WAIT)
            with open(os.path.join(scripts, "quick.sh"), "w") as f:
                f.write("exit 0\n")
            with open(os.path.join(root, "debian", "dropins", "x.conf"), "w") as f:
                f.write(dropin)
            with open(os.path.join(root, "debian", "rules"), "w") as f:
                f.write("override_dh_install:\n" + (install % "x.conf" if installed else ""))
            got = boot_job_waits(root)
            if bool(got) != want_flag:
                bad.append("%s: wanted %s, got %r" % (name, "flagged" if want_flag else "clean", got))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    hostfs_like = ("[Unit]\nAfter=androidd.service\nPartOf=androidd.service\n[Service]\nType=oneshot\n"
                   "RemainAfterExit=yes\nExecStart=/usr/bin/python3 /usr/lib/rhizo/tools/attach.py attach \\\n"
                   "    --config /etc/x.conf --wait-for-storage 180\n")
    for name, text, want_flag in (
            ("a oneshot multi-user.target wants, waiting on the sandbox's storage",
             hostfs_like + "[Install]\nWantedBy=multi-user.target\n", True),
            ("the same oneshot, wanted only by androidd.service's own start",
             hostfs_like, False),
            ("a oneshot graphical.target wants, waiting on the sandbox's boot",
             "[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/lib/rhizo/install/prepare/await-boot-completed.py"
             " --timeout 900\n[Install]\nWantedBy=graphical.target\n", True),
            ("a boot-wanted oneshot with no sandbox wait",
             "[Service]\nType=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n", False)):
        root = tempfile.mkdtemp(prefix="boot-wanted-")
        try:
            os.makedirs(os.path.join(root, "src", "services", "units"))
            with open(os.path.join(root, "src", "services", "units", "x.service"), "w") as f:
                f.write(text)
            got = boot_job_waits(root)
            if bool(got) != want_flag:
                bad.append("%s: wanted %s, got %r" % (name, "flagged" if want_flag else "clean", got))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    return bad


def main():
    """run the cases and the boot job check, or the selftest"""
    selftest = "--selftest" in sys.argv[1:]
    name = "check-resync-boot-wait" + (" --selftest" if selftest else "")
    text = open(SCRIPT).read()
    bad = run_cases(text) + boot_job_waits()
    if not selftest:
        for b in bad:
            print("FAIL: %s: %s" % (name, b))
        if bad:
            return 1
        print("%s: OK (%d cases)" % (name, len(CASES)))
        return 0
    if bad:
        print("%s: FAIL -- the script does not pass its own cases: %s" % (name, "; ".join(bad)))
        return 1
    job_bad = boot_job_selftest()
    if job_bad:
        print("%s: FAIL -- the boot-job rule is wrong on its own fixtures: %s" % (name, "; ".join(job_bad)))
        return 1
    mutant, n = WAIT_BLOCK.subn(PRE_FIX, text, count=1)
    if n != 1:
        print("%s: FAIL -- no `if [ -z \"$INIT\" ]; then ... fi` wait block in %s to cut back" % (name, SCRIPT))
        return 1
    bad = run_cases(mutant)
    if not any(b.startswith(CASES[0][0]) for b in bad):
        print("%s: FAIL -- the pre-fix exit on a missing init passed the boot's own trigger case: %r"
              % (name, bad))
        return 1
    print("%s: OK (the pre-fix exit drops the boot's sync and is caught; a oneshot boot-job wait is "
          "caught; the script passes all %d)" % (name, len(CASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
