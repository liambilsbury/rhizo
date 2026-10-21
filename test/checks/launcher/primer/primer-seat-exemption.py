#!/usr/bin/env python3
import ast
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)
LIFTED = {"_units_still_kernel", "_restart_class", "_leftovers", "_display_manager_unit",
          "_SELF_UNITS", "_SELF_FAMILIES", "_SESSION_UNITS", "_SESSION_FAMILIES"}

DM = "xdm.service"
FIXTURE = {
    "cron.service": ("kernel", True, True),
    "systemd-udevd.service/udev": ("kernel", True, True),
    "rhizo-policyd.service": ("kernel", True, True),
    "androidd-helper.service": ("kernel", True, True),
    "rhizo-policy.service": ("kernel", False, False),
    "run-u42.service": ("kernel", False, False),
    "androidd.service": ("u:r:kernel:s0", False, False),
    "androidd@3.service": ("u:r:kernel:s0", False, False),
    "gdm.service": ("kernel", False, True),
    "plasmalogin.service": ("kernel", False, True),
    "xdm.service": ("kernel", False, True),
    "user@1000.service": ("kernel", False, True),
    "user-runtime-dir@1000.service": ("kernel", False, True),
    "ssh.service": ("u:r:rhizo_host:s0", None, False),
}


class _FakeSubprocess:
    """fake subprocess for systemctl show"""

    TimeoutExpired = TimeoutError

    def __init__(self, answer):
        """keep the answer to return"""
        self.answer = answer

    def run(self, argv, **_kw):
        """return the answer, or raise it when it is an exception"""
        if isinstance(self.answer, Exception):
            raise self.answer
        return type("R", (), {"stdout": self.answer + "\n", "returncode": 0})()


def lift(launcher_text):
    """load the primer functions from the launcher text"""
    m = PRIMER_RE.search(launcher_text)
    if not m:
        return None
    tree = ast.parse(m.group(1))
    parts = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in LIFTED)
             or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in LIFTED
                                                    for t in n.targets))]
    ns = {"os": os, "log": lambda _m: None}
    exec(compile(ast.unparse(ast.Module(body=parts, type_ignores=[])), "<primer>", "exec"), ns)
    problems = []
    loop = next((n for n in ast.walk(tree) if isinstance(n, ast.For)
                 and isinstance(n.target, ast.Name) and n.target.id == "u"
                 and "_stuck_units" in ast.unparse(n.iter)), None)
    guards = []
    if loop is None:
        problems.append("the primer has no `for u in ... _stuck_units` restart loop")
    else:
        restarts = [n.lineno for n in ast.walk(loop) if isinstance(n, ast.Call)
                    and ast.unparse(n.func) == "subprocess.run"]
        if not restarts:
            problems.append("the restart loop never calls subprocess.run")
        guards = [n.test for n in ast.walk(loop) if isinstance(n, ast.If)
                  and any(isinstance(s, ast.Continue) for s in n.body)
                  and restarts and n.lineno < min(restarts)]
    verdict = next((n for n in tree.body if isinstance(n, ast.Assign)
                    and any(isinstance(t, ast.Name) and t.id == "_post_restart_stuck" for t in n.targets)),
                   None)
    if verdict is None:
        problems.append("HOST_PRIMER_SRC no longer assigns _post_restart_stuck")
    dm_assign = next((n for n in tree.body if isinstance(n, ast.Assign)
                      and any(isinstance(t, ast.Name) and t.id == "_DM_UNIT" for t in n.targets)), None)
    if dm_assign is None or ast.unparse(dm_assign.value) != "_display_manager_unit()":
        problems.append("the primer no longer sets _DM_UNIT from _display_manager_unit()")
    return ns, guards, verdict, problems


def build_fixture(root):
    """build a fixture cgroup and proc tree under a root"""
    cg = os.path.join(root, "system.slice")
    proc = os.path.join(root, "proc")
    for i, (rel, (ctx, _r, _l)) in enumerate(sorted(FIXTURE.items()), start=100):
        d = os.path.join(cg, rel)
        os.makedirs(d, exist_ok=True)
        if "/" in rel:
            open(os.path.join(os.path.dirname(d), "cgroup.procs"), "w").close()
        with open(os.path.join(d, "cgroup.procs"), "w") as f:
            f.write("%d\n" % i)
        os.makedirs(os.path.join(proc, str(i), "attr"))
        with open(os.path.join(proc, str(i), "attr", "current"), "w") as f:
            f.write(ctx + "\0")
    return cg, proc


def check(launcher_text):
    """check the primer guards and verdict"""
    lifted = lift(launcher_text)
    if lifted is None:
        return ["src/androidd/boot.py has no HOST_PRIMER_SRC string"]
    ns, guards, verdict, problems = lifted
    missing = sorted(n for n in LIFTED if n not in ns)
    if missing:
        return ["HOST_PRIMER_SRC no longer defines %s" % ", ".join(missing)]
    if problems:
        return problems
    fails = [] if guards else ["the restart loop has no skip guard ahead of its restart call"]
    for answer, want in (("gdm.service", "gdm.service"), (DM, DM),
                         ("display-manager.service", ""), (OSError("no systemctl"), "")):
        ns["subprocess"] = _FakeSubprocess(answer)
        got = ns["_display_manager_unit"]()
        if got != want:
            fails.append("_display_manager_unit() read systemctl's %r as %r, want %r" % (answer, got, want))
    ns["subprocess"] = _FakeSubprocess(DM)
    dm = ns["_display_manager_unit"]()
    root = tempfile.mkdtemp(prefix="check-primer-seat.")
    try:
        cg, proc = build_fixture(root)
        vns = dict(ns, _CALLER_UNIT="run-u42.service", _DM_UNIT=dm,
                   _units_still_kernel=lambda: ns["_units_still_kernel"](cg, proc))
        exec(compile(ast.unparse(ast.Module(body=[verdict], type_ignores=[])), "<verdict>", "exec"), vns)
        left = set(vns["_post_restart_stuck"])
        for rel, (_ctx, restarted, leftover) in sorted(FIXTURE.items()):
            unit = rel.split("/")[0]
            if restarted is not None:
                scope = {"u": unit, "_CALLER_UNIT": "run-u42.service", "_DM_UNIT": dm,
                         "_restart_class": ns["_restart_class"]}
                skipped = any(eval(compile(ast.Expression(g), "<guard>", "eval"),
                                   {"__builtins__": {}}, scope) for g in guards)
                if restarted and skipped:
                    fails.append("the restart loop skips %s"
                                 % unit)
                if not restarted and not skipped:
                    fails.append("the restart loop restarts %s%s" % (unit, (
                        " -- a live login session" if ns["_restart_class"](unit, "", dm) == "session"
                        else " -- `kernel` by construction")))
            if leftover and unit not in left:
                fails.append("the verdict misses %s, still `kernel` after the pass" % unit)
            if not leftover and unit in left:
                fails.append("the verdict counts %s, which is `kernel` by construction or never was"
                             % unit)
    finally:
        shutil.rmtree(root, ignore_errors=True)
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
    cases = [
        ("gdm.service dropped from the session units",
         '_SESSION_UNITS = ("gdm.service", ', '_SESSION_UNITS = (', "restarts gdm.service"),
        ("plasmalogin.service dropped from the session units",
         '"greetd.service", "plasmalogin.service")', '"greetd.service")', "restarts plasmalogin.service"),
        ("user@ dropped from the session families",
         '_SESSION_FAMILIES = ("user@", ', '_SESSION_FAMILIES = (', "restarts user@1000.service"),
        ("the display-manager alias ignored",
         "unit == dm_unit or unit in _SESSION_UNITS", "unit in _SESSION_UNITS",
         "restarts xdm.service"),
        ("the caller counted by the verdict",
         'return sorted(u for u in stuck if _restart_class(u, caller_unit, dm_unit) != "self")',
         "return sorted(stuck)", "counts run-u42.service"),
        ("the caller restarted",
         "if unit == caller_unit or unit in _SELF_UNITS", "if unit in _SELF_UNITS",
         "restarts run-u42.service"),
        ("rhizo-policy.service dropped from the self units",
         '_SELF_UNITS = ("androidd.service", "rhizo-policy.service")',
         '_SELF_UNITS = ("androidd.service",)', "restarts rhizo-policy.service"),
        ("a session holder dropped from the verdict",
         'return sorted(u for u in stuck if _restart_class(u, caller_unit, dm_unit) != "self")',
         'return sorted(u for u in stuck if _restart_class(u, caller_unit, dm_unit) == "restart")',
         "misses gdm.service"),
        ("a bare prefix hiding a lookalike",
         '_SELF_FAMILIES = ("androidd@", "rhizo-host-primer.")',
         '_SELF_FAMILIES = ("androidd@", "rhizo-host-primer.", "rhizo-policy")',
         "skips rhizo-policyd.service"),
        ("the seat guard moved below a restart call",
         '            if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue',
         '            subprocess.run(["systemctl", "restart", "--no-block", u])\n'
         '            if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue',
         "restarts gdm.service"),
        ("the verdict back to every unit still kernel",
         "_post_restart_stuck = _leftovers(_units_still_kernel(), _CALLER_UNIT, _DM_UNIT)",
         "_post_restart_stuck = sorted(_units_still_kernel())", "counts run-u42.service"),
        ("an empty verdict",
         "_post_restart_stuck = _leftovers(_units_still_kernel(), _CALLER_UNIT, _DM_UNIT)",
         "_post_restart_stuck = []", "misses cron.service"),
        ("the display-manager lookup answering nothing",
         '    return dm if dm.endswith(".service") and dm != "display-manager.service" else ""',
         '    return ""', "restarts xdm.service"),
        ("the seat guard removed from the loop",
         'if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue', "pass",
         "restarts gdm.service"),
    ]
    for name, old, new, needle in cases:
        if old not in real:
            print("SELFTEST FAILED: %s: the planted defect no longer matches its source -- %r is gone"
                  % (name, old[:60]))
            fail = 1
            continue
        problems = check(real.replace(old, new, 1))
        if not any(needle in p for p in problems):
            print("SELFTEST FAILED: %s was not flagged with %r (got %s)" % (name, needle, problems))
            fail = 1
    if not check("nothing relevant here at all\n"):
        print("SELFTEST FAILED: a file with no primer was not flagged")
        fail = 1
    print("primer-seat-exemption.py selftest: %s (%d planted defects)"
          % ("FAILED" if fail else "ok", len(cases)))
    return fail


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: primer-seat-exemption.py [--selftest]", file=sys.stderr)
        return 2
    with open(LAUNCHER, encoding="utf-8") as fh:
        fails = check(fh.read())
    for f in fails:
        print("primer-seat-exemption: " + f, file=sys.stderr)
    if fails:
        return 1
    print("primer-seat-exemption: across %d fixture units the restart pass never restarts a login "
          "seat or its own caller, and its verdict counts every other unit still `kernel`"
          % len(FIXTURE))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
