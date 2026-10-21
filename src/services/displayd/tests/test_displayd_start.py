#!/usr/bin/env python3
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DISPLAYD = os.path.normpath(os.path.join(HERE, "..", "displayd.py"))

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load():
    """load displayd as a module"""
    spec = importlib.util.spec_from_file_location("displayd_under_test", DISPLAYD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_wait_for_init():
    """check that wait_for_init polls until init has a pid"""
    d = load()
    check("wait_for_init exists", hasattr(d, "wait_for_init"), "displayd.py defines no wait_for_init")
    if not hasattr(d, "wait_for_init"):
        return
    answers = [None, None, "4242"]
    slept = []
    d.init_pid = lambda: answers.pop(0)
    d.log = lambda msg: None
    got = d.wait_for_init(sleep=slept.append)
    check("returns the init once it appears", got == "4242", "got %r" % (got,))
    check("sleeps between reads, once per miss", len(slept) == 2 and all(s > 0 for s in slept),
          "slept %r" % (slept,))


def test_main_waits():
    """check that main waits for init before doing anything else"""
    d = load()

    class Reached(Exception):
        pass

    def stop_at_wait(*_a, **_k):
        """raise to mark that the wait was reached"""
        raise Reached()

    d.init_pid = lambda: None
    d.log = lambda msg: None
    if hasattr(d, "wait_for_init"):
        d.wait_for_init = stop_at_wait
    exited = None
    try:
        d.main()
    except Reached:
        pass
    except SystemExit as e:
        exited = e
    check("main() waits for the init rather than exiting without one", exited is None,
          "main() exited: %s" % (exited,))


def test_init_by_stack_cgroup():
    """test init_pid with fake /proc entries"""
    import shutil
    import tempfile
    d = load()
    base = tempfile.mkdtemp(prefix="displayd-initscan-")
    try:
        def proc(pid, cg):
            """write a fake process directory"""
            os.makedirs(os.path.join(base, str(pid)))
            with open(os.path.join(base, str(pid), "cmdline"), "w") as f:
                f.write("/system/bin/init\0second_stage\0")
            with open(os.path.join(base, str(pid), "cgroup"), "w") as f:
                f.write("0::%s\n" % cg)
        for pid, cg in ((1200, "/user.slice/user-1000.slice/session-3.scope"), (1300, "/rhizo-host"),
                        (1500, "/rhizo-2/init")):
            proc(pid, cg)
        d.PROC_ROOT = base
        d.SANDBOX_ID = 0
        d.INIT_PID_FILE = os.path.join(base, "no-pid-file")
        got = d.init_pid()
        check("only stand-ins outside the stack: no init", got is None, "got %r" % (got,))
        proc(4242, "/rhizo/init")
        proc(10001, "/rhizo/init")
        got = d.init_pid()
        check("the init in rhizo/init, past stand-ins and its fork child", got == "4242", "got %r" % (got,))
        shutil.rmtree(os.path.join(base, "4242"))
        shutil.rmtree(os.path.join(base, "10001"))
        proc(4343, "/system.slice/androidd.service/android/init")
        got = d.init_pid()
        check("the init under androidd.service's android/", got == "4343", "got %r" % (got,))
    finally:
        shutil.rmtree(base)


def main():
    """run every check"""
    test_wait_for_init()
    test_main_waits()
    test_init_by_stack_cgroup()
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("rhizo-displayd waits for the sandbox's init at start and never exits for want of one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
