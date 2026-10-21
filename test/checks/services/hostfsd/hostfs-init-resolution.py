#!/usr/bin/env python3

import os
import shutil
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "hostfs", "hostfs.py")
INIT_ARGV = b"/system/bin/init\0second_stage\0"
STACK = "/rhizo/init"

NO_FILE = "<no file at all>"


def load_tool(path):
    """compile hostfs.py into a new module"""
    with open(path, "rb") as f:
        src = f.read()
    mod = types.ModuleType("rhizo_hostfs_under_test")
    mod.__file__ = path
    exec(compile(src, path, "exec"), mod.__dict__)
    return mod


def make_proc(root, procs):
    """build a /proc tree from process specs"""
    for name, spec in procs.items():
        argv, nspid = spec[0], spec[1]
        cgroup = spec[2] if len(spec) > 2 else STACK
        d = os.path.join(root, str(name))
        os.makedirs(d, exist_ok=True)
        if argv is not NO_FILE:
            with open(os.path.join(d, "cmdline"), "wb") as f:
                f.write(argv)
        if nspid is not NO_FILE:
            status = "Name:\tinit\nPPid:\t1\n"
            if nspid is not None:
                status += "NSpid:\t" + "\t".join(str(n) for n in nspid) + "\n"
            status += "Threads:\t1\n"
            with open(os.path.join(d, "status"), "w") as f:
                f.write(status)
        if cgroup is not NO_FILE:
            with open(os.path.join(d, "cgroup"), "w") as f:
                f.write("0::%s\n" % cgroup)


CASES = [
    ("init alone resolves",
     {1796: (INIT_ARGV, [1796, 1])},
     1796, None),

    ("forked children, caught before execve, are not sandboxes",
     {1796: (INIT_ARGV, [1796, 1]),
      6517: (INIT_ARGV, [6517, 42]),
      6518: (INIT_ARGV, [6518, 43]),
      6519: (INIT_ARGV, [6519, 44])},
     1796, None),

    ("a genuine second sandbox is still refused, not silently picked",
     {1796: (INIT_ARGV, [1796, 1]),
      9001: (INIT_ARGV, [9001, 1], "/rhizo-2/init")},
     None, "more than one sandbox"),

    ("a second sandbox under androidd@2's delegated cgroup is still refused",
     {1796: (INIT_ARGV, [1796, 1]),
      9001: (INIT_ARGV, [9001, 1], "/system.slice/system-androidd.slice/androidd@2.service/android/init")},
     None, "more than one sandbox"),

    ("a stand-in with init's argv outside any Rhizo stack is not a sandbox",
     {1200: (INIT_ARGV, [1200, 1], "/user.slice/user-1000.slice/session-3.scope"),
      1300: (INIT_ARGV, [1300, 1], "/rhizo-host"),
      1796: (INIT_ARGV, [1796, 1])},
     1796, None),

    ("only stand-ins outside any Rhizo stack is no sandbox",
     {1200: (INIT_ARGV, [1200, 1], "/user.slice/user-1000.slice/session-3.scope"),
      1400: (INIT_ARGV, [1400, 1], "/rhizophone/init")},
     None, "no `/system/bin/init second_stage` process is running"),

    ("the init under androidd.service's delegated cgroup resolves",
     {1796: (INIT_ARGV, [1796, 1], "/system.slice/androidd.service/android/init")},
     1796, None),

    ("a candidate whose cgroup cannot be read is not a sandbox",
     {1200: (INIT_ARGV, [1200, 1], NO_FILE),
      1796: (INIT_ARGV, [1796, 1])},
     1796, None),

    ("no sandbox at all is refused by name",
     {4242: (b"/usr/bin/python3\0-c\0pass\0", [4242])},
     None, "no `/system/bin/init second_stage` process is running"),

    ("a candidate whose NSpid the kernel does not report is kept",
     {1796: (INIT_ARGV, None)},
     1796, None),

    ("a candidate outside any pid namespace is kept",
     {1796: (INIT_ARGV, [1796])},
     1796, None),

    ("a candidate whose status cannot be read at all is kept",
     {1796: (INIT_ARGV, NO_FILE)},
     1796, None),

    ("an entry whose cmdline cannot be read is skipped, not fatal",
     {1795: (NO_FILE, [1795, 1]),
      1796: (INIT_ARGV, [1796, 1])},
     1796, None),

    ("a non-numeric /proc entry is never a pid, whatever its cmdline says",
     {"self": (INIT_ARGV, [1796, 1]),
      1796: (INIT_ARGV, [1796, 1])},
     1796, None),
]


def run_cases(find_init_pid):
    """run each case against find_init_pid"""
    bad, errs = [], []
    for name, procs, want_pid, want_why in CASES:
        root = tempfile.mkdtemp(prefix="hostfs-proc-")
        try:
            make_proc(root, procs)
            got_pid, got_why = find_init_pid(proc_root=root)
        except Exception as e:
            errs.append(f"{name}: find_init_pid raised {type(e).__name__}: {e}")
            continue
        finally:
            shutil.rmtree(root, ignore_errors=True)
        if want_pid is not None:
            if got_pid != want_pid:
                bad.append(f"{name}: wanted pid {want_pid}, got {got_pid!r} ({got_why})")
        else:
            if got_pid is not None:
                bad.append(f"{name}: wanted a refusal, got pid {got_pid}")
            elif want_why not in (got_why or ""):
                bad.append(f"{name}: refusal did not say {want_why!r}: {got_why!r}")
    return bad, errs


def report(prefix, bad, errs):
    """print each error and problem with the prefix"""
    for e in errs:
        print(f"{prefix}: FAIL -- {e}", file=sys.stderr)
    for b in bad:
        print(f"{prefix}: FAIL -- {b}", file=sys.stderr)


def main():
    """run the cases and the selftest"""
    selftest = "--selftest" in sys.argv[1:]
    name = "check-hostfs-init-resolution" + (" --selftest" if selftest else "")
    mod = load_tool(TOOL)

    bad, errs = run_cases(mod.find_init_pid)

    if not selftest:
        if bad or errs:
            report(name, bad, errs)
            return 1
        print(f"{name}: OK ({len(CASES)} cases)")
        return 0

    if bad or errs:
        print(f"{name}: FAIL -- the fix itself does not pass its own cases", file=sys.stderr)
        report(name, bad, errs)
        return 1

    for disabled, stub, want_case in (
            ("_is_foreign_namespace_member", lambda proc_root, d: False, "forked children"),
            ("_in_rhizo_stack", lambda proc_root, d: True, "a stand-in with init's argv")):
        mod = load_tool(TOOL)
        mod.__dict__[disabled] = stub
        bad, errs = run_cases(mod.find_init_pid)
        if errs:
            print(f"{name}: FAIL -- disabling {disabled} should change an ANSWER, "
                  f"not crash the scan: " + "; ".join(errs), file=sys.stderr)
            return 1
        if not any(b.startswith(want_case) for b in bad):
            print(f"{name}: FAIL -- the scan with {disabled} disabled was not caught by the "
                  f"'{want_case}' case: " + ("; ".join(bad) or "reported clean"), file=sys.stderr)
            return 1
    print(f"{name}: OK (the fix passes {len(CASES)} cases; without either discriminator "
          f"its own case fails)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
