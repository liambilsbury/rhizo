#!/usr/bin/env python3
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_host_tty_policy", os.path.join(HERE, "host-tty-policy.py"))
tty = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(tty)

MINIMAL_CIL = tty.MINIMAL_CIL.replace("(class chr_file (ioctl read write))", "(class chr_file (ioctl read write setattr))")


def problems(policy):
    """return the host pty ownership problems"""
    bad = []
    if not tty.sesearch(policy, "--allow", "-s", "rhizo_host", "-t", "devpts", "-c", "chr_file", "-p", "setattr").strip():
        bad.append("rhizo_host may not setattr devpts: sshd-session and login chown a user's pty and stop")
    trans = tty.sesearch(policy, "--type_trans", "-s", "rhizo_host", "-t", "devpts", "-c", "chr_file").strip()
    if trans:
        bad.append("a type_transition retypes the devpts nodes rhizo_host creates (%s): the ptmx of a devpts "
                   "instance it mounts, the sandbox's own, takes that type and Android's init is refused it"
                   % trans.replace("\n", " | "))
    return bad


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-host-pty-owner.")

    def expect(label, rules, want):
        """compile the rules and compare the findings with want"""
        src, out = os.path.join(tmp, "p.cil"), os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(MINIMAL_CIL + "(type rhizo_host_devpts)\n(typeattributeset fs_type (rhizo_host_devpts))\n"
                    "(allow rhizo_host devpts (chr_file (read)))\n" + rules)
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

    grant = "(allow rhizo_host devpts (chr_file (setattr)))\n"
    try:
        expect("the plain grant", grant, [])
        expect("no setattr", "", ["may not setattr devpts"])
        expect("a transition to the host's own type",
               grant + "(typetransition rhizo_host devpts chr_file rhizo_host_devpts)\n", ["retypes the devpts nodes"])
        expect("a transition with a ptmx exception",
               grant + "(typetransition rhizo_host devpts chr_file rhizo_host_devpts)\n"
               "(typetransition rhizo_host devpts chr_file \"ptmx\" devpts)\n", ["retypes the devpts nodes"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-host-pty-owner selftest: ok (no setattr and both transitions caught; the plain grant passes)")
    return 0


def main():
    """run the selftest or judge the compiled lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    lab_dir = tempfile.mkdtemp(prefix="check-host-pty-owner-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found = problems(policy)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: host pty owner: " + p)
    if found:
        return 1
    print("ok: rhizo_host may chown devpts, and the ptys and devpts instances it makes keep devpts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
