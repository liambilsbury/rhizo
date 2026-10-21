#!/usr/bin/env python3
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "label-domain.py")
bad = []


def run(path):
    """run label-domain.py with path in front of PATH"""
    env = dict(os.environ, PATH=path + os.pathsep + os.environ["PATH"] if path else os.environ["PATH"])
    r = subprocess.run([sys.executable, CHECK], capture_output=True, text=True, timeout=250, env=env)
    return r.returncode, r.stdout.splitlines()


with tempfile.TemporaryDirectory() as tmp:
    stub = os.path.join(tmp, "unshare")
    open(stub, "w").write("#!/bin/sh\necho 'unshare: unshare failed: Operation not permitted' >&2\nexit 1\n")
    os.chmod(stub, 0o755)
    rc, out = run(tmp)
    if rc != 0:
        bad.append(("a refused unshare -r is not a failure of the check", 0, rc))
    if not any(l.startswith("NOT RUN: the forked-service cases -- unshare -r refused: ") and "Operation not permitted" in l for l in out):
        bad.append(("the NOT RUN line names the group and the refusal", out[-3:]))
    if not out or out[-1] != "ok (forked-service group NOT RUN)":
        bad.append(("the closing line says the pass is partial", out[-1:]))

probe = subprocess.run(["unshare", "-r", "true"], capture_output=True, timeout=30)
rc, out = run("")
if probe.returncode == 0:
    if rc != 0 or out[-1:] != ["ok"] or any(l.startswith("NOT RUN") for l in out):
        bad.append(("with a working unshare -r the output is a plain ok", rc, out[-3:]))
elif not any(l.startswith("NOT RUN") for l in out):
    bad.append(("a host that refuses unshare -r reports NOT RUN", out[-3:]))

if bad:
    for b in bad:
        print("FAIL: label-domain-skip:", *b)
    sys.exit(1)
print("ok: label-domain-skip: a refused unshare is reported NOT RUN and partial, a working one is a plain ok")
