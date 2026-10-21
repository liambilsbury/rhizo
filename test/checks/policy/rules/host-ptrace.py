#!/usr/bin/env python3
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_host_tty_policy", os.path.join(HERE, "host-tty-policy.py"))
tty = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(tty)

_RULE = re.compile(r"^allow rhizo_host (\S+):process (?:\{ ([^{}]*) \}|(\S+));$")
MINIMAL_CIL = tty.MINIMAL_CIL.replace("(class chr_file (ioctl read write))\n(classorder (chr_file))",
                                      "(class chr_file (ioctl read write))\n(class process (ptrace signal))\n"
                                      "(classorder (chr_file process))")


def targets(policy):
    """return the types and attributes rhizo_host may ptrace"""
    out = tty.sesearch(policy, "--allow", "-s", "rhizo_host", "-c", "process", "-p", "ptrace")
    found, bad = [], []
    for line in (l.strip() for l in out.splitlines()):
        if not line:
            continue
        m = _RULE.match(line)
        if m is None:
            bad.append(line)
        else:
            found.append(m.group(1))
    return found, bad


def problems(policy):
    """return what keeps strace from the host or reaches an Android type"""
    found, bad = targets(policy)
    out = ["a process rule this check cannot read: %s" % b for b in bad]
    if "rhizo_host" not in found and "self" not in found:
        out.append("rhizo_host may not ptrace rhizo_host: strace and gdb on the host fail "
                   "PTRACE_TRACEME and PTRACE_SEIZE with Permission denied")
    for t in found:
        if t not in ("rhizo_host", "self"):
            out.append("rhizo_host may ptrace %s" % t)
    return out


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-host-ptrace.")

    def expect(label, rules, want):
        """compile the rules and compare the findings with want"""
        src, out = os.path.join(tmp, "p.cil"), os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(MINIMAL_CIL + "(allow rhizo_host devpts (chr_file (read)))\n" + rules)
        r = subprocess.run(["secilc", "-m", "-M", "true", "-G", "-c", "30", src, "-o", out, "-f", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("%s: the fixture does not compile: %s" % (label, (r.stderr or r.stdout).strip()))
            return
        got = problems(out)
        for w in want:
            if not any(w in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, w, got))
        if not want and got:
            fails.append("%s: wanted no finding, got %r" % (label, got))

    good = "(allow rhizo_host self (process (ptrace)))\n"
    try:
        expect("the self grant", good, [])
        expect("no grant", "", ["may not ptrace rhizo_host"])
        expect("a grant on an Android domain", good + "(allow rhizo_host shell (process (ptrace)))\n",
               ["may ptrace shell"])
        expect("a grant through an attribute", good + "(allow rhizo_host domain (process (ptrace)))\n",
               ["may ptrace domain"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-host-ptrace selftest: ok (no grant, an Android domain and an attribute caught; the self grant passes)")
    return 0


def main():
    """run the selftest or judge the compiled lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    lab_dir = tempfile.mkdtemp(prefix="check-host-ptrace-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found = problems(policy)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: host ptrace: " + p)
    if found:
        return 1
    print("ok: rhizo_host may ptrace its own processes and no other type")
    return 0


if __name__ == "__main__":
    sys.exit(main())
