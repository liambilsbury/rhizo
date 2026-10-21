#!/usr/bin/env python3
import contextlib
import io
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-permissive-compiled")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import selinux_policy  # noqa: E402
    from sandbox import guest_files  # noqa: E402
from policy_lab_cache import release_cil_dir  # noqa: E402

LAB = os.path.join(ROOT, "test", "checks", "lib", "policy-lab.sh")
RELEASES = (("a15", "gsi_a15", ""), ("a16", "system", ""), ("a17", "gsi_a17", ""), ("userdebug", "gsi_userdebug", "su"))
CIL_NAMES = ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil")


class NotRun(Exception):
    """an input the compile needs is absent"""


def rendered_case(image, namespace, template=None, software=None):
    """render a release's policy and its inputs"""
    cil_dir = release_cil_dir(ROOT, image)
    if not cil_dir or not all(os.path.exists(os.path.join(cil_dir, n)) for n in CIL_NAMES):
        raise NotRun("no cached CILs for %s.img under var/share/policy-lab: run test/checks/lib/policy-lab.sh "
                     "once with that image staged" % image)
    cils = [os.path.join(cil_dir, n) for n in CIL_NAMES]
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        rendered = selinux_policy.build(cils, path=template, namespace=namespace)
    return cil_dir, rendered, software or selinux_policy.software_cils(True)[0]


def compile_finding(cil_dir, rendered, software, want):
    """return a compile's permissive finding, or None"""
    env = dict(os.environ, RHIZO_POLICY_LAB_CIL_DIR=cil_dir)
    with tempfile.TemporaryDirectory() as tmp:
        render = os.path.join(tmp, "rhizo.cil")
        with open(render, "w") as f:
            f.write(rendered)
        out = os.path.join(tmp, "out")
        r = subprocess.run([LAB, "compile", "--render", render, "--cil", software, "--out", out], env=env,
                           capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            return "did not compile: " + (r.stdout + r.stderr).strip()[-300:]
        r = subprocess.run([LAB, "permissive", os.path.join(out, "precompiled_sepolicy"), "--expect", want],
                           env=env, capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            return (r.stdout + r.stderr).strip()[-300:]
    return None


def findings():
    """compile every release in both modes"""
    cases = [(name, image, want, ns) for name, image, want in RELEASES for ns in (True, False)]
    renders = [rendered_case(c[1], c[3]) for c in cases]
    with ThreadPoolExecutor(4) as pool:
        got = list(pool.map(lambda c, r: (c, compile_finding(*r, c[2])), cases, renders))
    return ["%s %s mode: %s" % (c[0], "namespace" if c[3] else "host", why) for c, why in got if why]


def selftest():
    """plant three hidden typepermissive forms"""
    bad = []
    template = guest_files.read(selinux_policy.CIL_FILENAME)
    software = open(selinux_policy.software_cils(True)[0]).read()
    with tempfile.TemporaryDirectory() as tmp:
        plants = []
        for name, text in (("optional", template + "(optional rhizo_mut (typepermissive vold))\n"),
                           ("macro", template + "(macro rhizo_mut () (typepermissive vold))\n(call rhizo_mut)\n")):
            path = os.path.join(tmp, name + ".cil")
            with open(path, "w") as f:
                f.write(text)
            plants.append((name, "vold", path, None))
        path = os.path.join(tmp, "software.cil")
        with open(path, "w") as f:
            f.write(software + "(typepermissive surfaceflinger)\n")
        plants.append(("software fragment", "surfaceflinger", None, path))
        cases = [("shipped", None, None, None)] + plants
        renders = [rendered_case("system", True, c[2], c[3]) for c in cases]
        with ThreadPoolExecutor(4) as pool:
            got = list(pool.map(lambda c, r: (c, compile_finding(*r, "")), cases, renders))
    for (name, permissive, _, _), why in got:
        if permissive is None and why:
            bad.append("the shipped a16 namespace policy was flagged: %s" % why)
        elif permissive and (why is None or "'%s'" % permissive not in why):
            bad.append("a typepermissive %s in the %s passed: %s" % (permissive, name, why))
    return bad


def main():
    """run the check or its selftest"""
    try:
        bad = selftest() if "--selftest" in sys.argv[1:] else findings()
    except NotRun as e:
        print("NOT RUN: permissive-compiled: %s" % e, file=sys.stderr)
        return 2
    for b in bad:
        print("FAIL: %s" % b, file=sys.stderr)
    if bad:
        return 1
    print("permissive-compiled: %s" % ("selftest ok: an optional, a macro call and the software fragment each "
                                       "show their planted type" if "--selftest" in sys.argv[1:] else
                                       "a15, a16 and a17 compile with no permissive type and userdebug with su alone, "
                                       "in both modes with the software fragment"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
