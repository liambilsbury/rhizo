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

NEEDED = {
    "sys_chroot": "Vivaldi's and Firefox's sandboxes chroot inside their own user namespace, and both browsers "
                  "crash at start when that is refused",
    "sys_nice": "ananicy-cpp renices processes that run in a user namespace, such as browser sandboxes, and is "
                "refused hundreds of times a minute",
}
_RULE = re.compile(r"^allow rhizo_host (\S+):cap_userns (?:\{ ([^{}]*) \}|(\S+));$")
MINIMAL_CIL = tty.MINIMAL_CIL.replace("(class chr_file (ioctl read write))\n(classorder (chr_file))",
                                      "(class chr_file (ioctl read write))\n(class cap_userns (sys_chroot sys_nice))\n"
                                      "(classorder (chr_file cap_userns))")


def grants(policy, perm):
    """return the user namespaces where rhizo_host holds perm"""
    out = tty.sesearch(policy, "--allow", "-s", "rhizo_host", "-c", "cap_userns", "-p", perm)
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
    """return the userns permission problems of rhizo_host"""
    out = []
    for perm, why in sorted(NEEDED.items()):
        found, bad = grants(policy, perm)
        out.extend("a cap_userns rule this check cannot read: %s" % b for b in bad)
        if "rhizo_host" not in found and "self" not in found:
            out.append("rhizo_host lacks cap_userns %s on itself: %s" % (perm, why))
        for t in found:
            if t not in ("rhizo_host", "self"):
                out.append("rhizo_host holds cap_userns %s on %s"
                           % (perm, t))
    return out


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-host-userns-caps.")

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

    good = "(allow rhizo_host self (cap_userns (sys_chroot sys_nice)))\n"
    try:
        expect("the self grant", good, [])
        expect("no grant", "", ["lacks cap_userns sys_chroot", "lacks cap_userns sys_nice"])
        expect("sys_chroot alone", "(allow rhizo_host self (cap_userns (sys_chroot)))\n",
               ["lacks cap_userns sys_nice"])
        expect("a grant on an Android domain", good + "(allow rhizo_host shell (cap_userns (sys_chroot)))\n",
               ["sys_chroot on shell"])
        expect("a grant through an attribute", good + "(allow rhizo_host domain (cap_userns (sys_nice)))\n",
               ["sys_nice on domain"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-host-userns-caps selftest: ok (no grant, a partial grant, an Android domain and an attribute caught; "
          "the self grant passes)")
    return 0


def main():
    """run the selftest or judge the compiled lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    lab_dir = tempfile.mkdtemp(prefix="check-host-userns-caps-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found = problems(policy)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: host user namespace caps: " + p)
    if found:
        return 1
    print("ok: rhizo_host holds sys_chroot and sys_nice in its own user namespaces and on no other type")
    return 0


if __name__ == "__main__":
    sys.exit(main())
