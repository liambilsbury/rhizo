#!/usr/bin/env python3
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_host_tty_policy", os.path.join(HERE, "..", "..", "policy", "rules", "host-tty-policy.py"))
tty = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(tty)

WRITERS = ("kernel", "rhizo_host")
PIPE_TYPES = ("kernel", "rhizo_host")
FIXTURE_CIL = tty.MINIMAL_CIL.replace("(class chr_file (ioctl read write))\n(classorder (chr_file))",
                                      "(class fifo_file (read write))\n(classorder (fifo_file))") \
    .replace("(type shell)", "(type kernel)").replace("(rhizo_host shell)", "(rhizo_host kernel)")


def problems(policy):
    """return writers with no pipe write grant"""
    bad = []
    for writer in WRITERS:
        for pipe in PIPE_TYPES:
            out = tty.sesearch(policy, "--allow", "-s", writer, "-t", pipe, "-c", "fifo_file", "-p", "write")
            if not out.strip():
                bad.append("%s may not write a pipe labeled %s" % (writer, pipe))
    return bad


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-log-pipe.")
    grants = {(w, p): "(allow %s %s (fifo_file (write)))\n" % (w, p) for w in WRITERS for p in PIPE_TYPES}

    def compile_rules(rules):
        """return a compiled fixture policy path"""
        src, out = os.path.join(tmp, "p.cil"), os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(FIXTURE_CIL + rules)
        r = subprocess.run(["secilc", "-m", "-M", "true", "-G", "-c", "30", src, "-o", out, "-f", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("the fixture does not compile: %s" % (r.stderr or r.stdout).strip())
        return out

    try:
        got = problems(compile_rules("".join(grants.values())))
        if got:
            fails.append("all four grants were flagged: %r" % got)
        for missing in grants:
            got = problems(compile_rules("".join(v for k, v in grants.items() if k != missing)))
            if got != ["%s may not write a pipe labeled %s" % missing]:
                fails.append("missing %s: got %r" % (missing, got))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    return 1 if fails else 0


def main():
    """run the selftest or judge the lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    lab_dir = tempfile.mkdtemp(prefix="check-log-pipe-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found = problems(policy)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: " + p)
    print("PASS" if not found else "FAIL")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
