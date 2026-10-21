#!/usr/bin/env python3
"""Check the host primer restart pass"""
import ast
import os
import re
import sys

USAGE = """Usage: primer-restart-jobs.py [--selftest]"""

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)
LIFTED = {"_restart_pass", "_restart_class", "_leftovers", "_restart_order", "_BUS_UNITS", "_restart_bus_dependents",
          "_SELF_UNITS", "_SELF_FAMILIES", "_SESSION_UNITS", "_SESSION_FAMILIES"}
CALLER = "rhizo-policy.service"
AFTER_CALLER = {"ssh.service", "systemd-user-sessions.service", "getty@tty1.service"}
STUCK = {"cron.service": "101", "ssh.service": "102", "systemd-user-sessions.service": "103",
         "polkit.service": "104", CALLER: "105", "gdm.service": "106", "dbus-broker.service": "107",
         "NetworkManager.service": "108"}
BOUND = {"dbus-broker.service": ["NetworkManager.service", "upower.service"]}


class _Timeout(Exception):
    def __init__(self, cmd, timeout, **_kw):
        """build a timeout error naming the command and the timeout"""
        super().__init__("%s timed out after %ss" % (cmd, timeout))


class _Clock:
    def __init__(self):
        """start the fake clock at 1000 seconds"""
        self.now = 1000.0

    def time(self):
        """return the fake clock's time"""
        return self.now

    def sleep(self, s):
        """advance the fake clock by the seconds slept"""
        self.now += s


class _Systemd:
    """fake systemctl for the restart pass"""

    TimeoutExpired = _Timeout

    def __init__(self, stuck):
        """set up the fake systemctl state"""
        self.stuck = dict(stuck)
        self.calls = []
        self.held = []
        self.down = set()
        self.unbound = set()

    def run(self, argv, timeout=None, **_kw):
        """return the fake systemctl output"""
        if argv[:2] == ["systemctl", "show"]:
            out = " ".join(BOUND.get(argv[2], [])) if "BoundBy" in argv else "ActiveState=active\nJob=\n"
            return type("R", (), {"returncode": 0, "stderr": "", "stdout": out + "\n"})()
        if argv[:2] != ["systemctl", "restart"]:
            raise AssertionError("unexpected command %r" % (argv,))
        unit = argv[-1] if argv[-1].endswith(".service") else argv[-1] + ".service"
        waited = "--no-block" not in argv
        self.calls.append((unit, waited))
        self.unbound.discard(unit)
        self.unbound.update(BOUND.get(unit, []))
        if waited and unit in AFTER_CALLER:
            self.held.append(unit)
            self.stuck.pop(unit, None)
            if timeout is None:
                raise AssertionError("a waited restart of %s with no timeout never returns" % unit)
            raise _Timeout(argv, timeout)
        self.stuck.pop(unit, None)
        if unit in AFTER_CALLER and "--job-mode=ignore-dependencies" not in argv:
            self.down.add(unit)
        return type("R", (), {"returncode": 0, "stderr": "", "stdout": ""})()


def lift(text):
    """return the primer namespace and problem"""
    m = PRIMER_RE.search(text)
    if not m:
        return None, "src/androidd/boot.py has no HOST_PRIMER_SRC string"
    tree = ast.parse(m.group(1))
    parts = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in LIFTED)
             or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in LIFTED
                                                    for t in n.targets))]
    ns = {"os": os}
    exec(compile(ast.unparse(ast.Module(body=parts, type_ignores=[])), "<primer>", "exec"), ns)
    missing = sorted(n for n in LIFTED if n not in ns)
    if missing:
        return None, "HOST_PRIMER_SRC no longer defines %s" % ", ".join(missing)
    return ns, None


def check(text):
    """return the restart pass problems"""
    ns, problem = lift(text)
    if problem:
        return [problem]
    fake, clock, logs = _Systemd(STUCK), _Clock(), []
    ns.update(subprocess=fake, time=clock, log=logs.append, _pid1_ctx=lambda: "u:r:rhizo_host:s0",
              _stuck_units=dict(STUCK), _CALLER_UNIT=CALLER, _DM_UNIT="gdm.service",
              _units_still_kernel=lambda: dict(fake.stuck))
    fails = []
    try:
        ns["_restart_pass"]()
    except Exception as e:
        fails.append("pass-died: the restart pass raised %s: %s" % (type(e).__name__, e))
    waited = [u for u, w in fake.calls if w]
    if waited:
        fails.append("waited: the pass waited on the restart of %s" % ", ".join(waited))
    want = sorted(u for u in STUCK if ns["_restart_class"](u, CALLER, "gdm.service") == "restart")
    asked = [u for u, _ in fake.calls]
    if sorted(u for u in asked if u in STUCK) != want:
        fails.append("asked: the pass restarted %s, want each stuck unit it may restart once: %s"
                     % (asked, want))
    if fake.unbound:
        fails.append("unbound: %s stopped by the bus's restart and never restarted after it" % ", ".join(sorted(fake.unbound)))
    if asked and "ssh.service" in asked and asked[-1] != "ssh.service":
        fails.append("ssh-not-last: sshd was restarted before %s"
                     % ", ".join(asked[asked.index("ssh.service") + 1:]))
    if fake.down:
        fails.append("held: %s stopped with the start queued behind %s's own job" % (", ".join(sorted(fake.down)), CALLER))
    left = sorted(u for u in want if u in fake.stuck)
    if left:
        fails.append("left: %s still `kernel` after the pass" % ", ".join(left))
    return fails


def selftest():
    """check the real primer and each planted-defect copy of it"""
    fail = 0
    with open(LAUNCHER, encoding="utf-8") as fh:
        real = fh.read()
    got = check(real)
    if got:
        print("SELFTEST FAILED: the real primer was flagged: %s" % got)
        fail = 1
    ns, _ = lift(real)
    src = PRIMER_RE.search(real).group(1)
    body = ast.get_source_segment(src, next(n for n in ast.parse(src).body
                                            if isinstance(n, ast.FunctionDef) and n.name == "_restart_pass"))
    cases = [
        ("the sshd restart waited on", '"--no-block", "--job-mode=ignore-dependencies", u]', 'u]', "waited:"),
        ("the restart queued behind the caller", '"--no-block", "--job-mode=ignore-dependencies", u]',
         '"--no-block", u]', "held:"),
        ("sshd restarted first", "sorted(_stuck_units, key=_restart_order)", "sorted(_stuck_units)", "ssh-not-last:"),
        ("the bus restarted after a unit bound to it", "sorted(_stuck_units, key=_restart_order)",
         'sorted(_stuck_units, key=lambda u: (u.startswith("ssh"), u))', "unbound:"),
        ("a unit bound to the bus left stopped", "_restart_bus_dependents(u)", "pass", "unbound:"),
        ("a stuck unit skipped", 'if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue',
         'if u == "cron.service" or _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue', "asked:"),
    ]
    for name, old, new, needle in cases:
        if old not in body:
            print("SELFTEST FAILED: %s: the planted defect no longer matches _restart_pass -- %r is gone" % (name, old))
            fail = 1
            continue
        problems = check(real.replace(body, body.replace(old, new), 1))
        if not any(p.startswith(needle) for p in problems):
            print("SELFTEST FAILED: %s was not flagged %r (got %s)" % (name, needle, problems))
            fail = 1
    if not check("no primer here\n"):
        print("SELFTEST FAILED: a file with no primer was not flagged")
        fail = 1
    print("primer-restart-jobs.py selftest: %s (%d planted defects)" % ("FAILED" if fail else "ok", len(cases)))
    return fail


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(USAGE, file=sys.stderr)
        return 2
    with open(LAUNCHER, encoding="utf-8") as fh:
        fails = check(fh.read())
    for f in fails:
        print("FAIL: primer-restart-jobs: %s" % f)
    if not fails:
        print("primer-restart-jobs: the restart pass asks every stuck unit without waiting on its job, "
              "sshd last, ends with none of them left in `kernel`, holds none stopped behind its caller's job, "
              "and leaves no unit bound to the bus stopped by the bus's restart")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
