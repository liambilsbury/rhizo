#!/usr/bin/env python3
import json
import os
import pwd
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "hostfs", "hostfs.py")
NODAC = ("sudo", "-n", "setpriv", "--bounding-set", "-dac_override,-dac_read_search")
NOBODY = 65534
ANCESTOR_OWNER = ("        uid, gid = (int(x) for x in log[-1].split())\n        return uid, gid, None\n",
                  "        return ast.st_uid, ast.st_gid, None\n")

CHILD = r'''
import json, sys, types
tool, cases, no_walk, edit = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3] == "1", json.loads(sys.argv[4])
mod = types.ModuleType("rhizo_hostfs_under_test")
mod.__file__ = tool
with open(tool) as f:
    src = f.read()
if edit:
    if src.count(edit[0]) != 1:
        sys.exit("the planted regression no longer matches the source: %r" % edit[0])
    src = src.replace(edit[0], edit[1])
exec(compile(src, tool, "exec"), mod.__dict__)
if no_walk:
    mod.__dict__["_owner_through_ancestor"] = lambda host_dir: (
        None, None, "cannot stat %s as root" % host_dir)
out = {}
for name, host_dir, as_user in cases:
    uid, gid, err = mod.resolve_owner(host_dir, as_user)
    out[name] = [uid, gid, err]
print(json.dumps(out))
'''


def build(base, me):
    """create the fixture tree under base"""
    uid, gid = me.pw_uid, me.pw_gid
    os.chmod(base, 0o755)
    for d, mode in (("home", 0o755), ("home/u", 0o750), ("home/u/Downloads", 0o755),
                    ("home/u/sub", 0o750), ("home/u/sub/Deep", 0o755),
                    ("home/u/locked", 0o700), ("home/u/locked/Inner", 0o755),
                    ("home/u/Theirs", 0o755), ("open", 0o755), ("open/Shared", 0o755)):
        p = os.path.join(base, d)
        os.makedirs(p, exist_ok=True)
        os.chmod(p, mode)
    for d in ("home/u/locked", "home/u/Theirs"):
        r = subprocess.run(("sudo", "-n", "chown", "%d:%d" % (NOBODY, NOBODY), os.path.join(base, d)),
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise OSError("sudo chown: %s" % r.stderr.strip())
    home = os.path.join(base, "home/u")
    return [
        ("a share in a 0750 home resolves to its owner",
         os.path.join(home, "Downloads"), None, (uid, gid)),
        ("a share in a 0750 home owned by another account resolves to that account, not the home's",
         os.path.join(home, "Theirs"), None, (NOBODY, NOBODY)),
        ("a share two directories into the home resolves to its owner",
         os.path.join(home, "sub/Deep"), None, (uid, gid)),
        ("a share root can stat directly resolves to its owner",
         os.path.join(base, "open/Shared"), None, (uid, gid)),
        ("a share behind a directory the home's owner cannot enter is refused naming user=",
         os.path.join(home, "locked/Inner"), None, "user ="),
        ("a missing share is refused as missing",
         os.path.join(home, "Missing"), None, "No such file"),
        ("an explicit user= is taken as given",
         os.path.join(home, "Downloads"), me.pw_name, (uid, gid)),
    ]


def run(cases, no_walk, edit=None):
    """run the cases in a root process"""
    arg = json.dumps([[n, d, u] for n, d, u, _ in cases])
    r = subprocess.run(NODAC + (sys.executable, "-c", CHILD, TOOL, arg, "1" if no_walk else "0",
                                json.dumps(edit)), capture_output=True, text=True)
    if r.returncode != 0:
        return None, "the root-without-DAC probe exited %d: %s" % (r.returncode, r.stderr.strip()[-400:])
    try:
        return json.loads(r.stdout.strip().splitlines()[-1]), None
    except (ValueError, IndexError):
        return None, "the root-without-DAC probe printed no answer: %r" % r.stdout[-200:]


def judge(cases, answers):
    """return the wrongly resolved owners"""
    bad = []
    for name, _d, _u, want in cases:
        uid, gid, err = answers.get(name, [None, None, "no answer"])
        if isinstance(want, tuple):
            if err or (uid, gid) != want:
                bad.append("%s: wanted uid:gid %d:%d, got %r:%r (%s)" % (name, want[0], want[1], uid, gid, err))
        elif not err or want not in err:
            bad.append("%s: wanted a refusal carrying %r, got %r:%r (%s)" % (name, want, uid, gid, err))
    return bad


def main():
    """run the owner resolution cases or the selftest"""
    selftest = "--selftest" in sys.argv[1:]
    name = "check-hostfs-owner-resolution" + (" --selftest" if selftest else "")
    if subprocess.run(("sudo", "-n", "true"), capture_output=True).returncode != 0 or not shutil.which("setpriv"):
        print("%s: FAIL -- no root-without-DAC probe can run here (sudo -n and setpriv are needed)" % name)
        return 1
    me = pwd.getpwuid(os.getuid())
    if me.pw_uid == 0:
        print("%s: FAIL -- run as an ordinary account" % name)
        return 1
    base = tempfile.mkdtemp(prefix="hostfs-owner-", dir="/tmp")
    try:
        cases = build(base, me)
        answers, err = run(cases, no_walk=False)
        if err:
            print("%s: FAIL -- %s" % (name, err))
            return 1
        bad = judge(cases, answers)
        if not selftest:
            for b in bad:
                print("FAIL: %s: %s" % (name, b))
            if bad:
                return 1
            print("%s: OK (%d cases, as root without dac_override/dac_read_search)" % (name, len(cases)))
            return 0
        if bad:
            print("%s: FAIL -- the fix does not pass its own cases: %s"
                  % (name, "; ".join(bad)))
            return 1
        answers, err = run(cases, no_walk=True)
        if err:
            print("%s: FAIL -- replacing the walk should change an answer, not break the probe: %s" % (name, err))
            return 1
        bad = judge(cases, answers)
        caught = [b for b in bad if "0750 home" in b or "two directories" in b]
        if len(caught) != 3:
            print("%s: FAIL -- with the walk replaced by the pre-fix refusal the three home cases were not "
                  "all caught: %r" % (name, bad))
            return 1
        answers, err = run(cases, no_walk=False, edit=ANCESTOR_OWNER)
        if err:
            print("%s: FAIL -- the ancestor-owner regression should change an answer, not break the probe: %s"
                  % (name, err))
            return 1
        bad = judge(cases, answers)
        if not any("another account" in b for b in bad):
            print("%s: FAIL -- a walk that answers with the ancestor's owner instead of the share's passed "
                  "every case: %r" % (name, bad))
            return 1
        print("%s: OK (the pre-fix refusal fails all three home cases, answering with the ancestor's owner fails "
              "the share another account owns; the fix passes all %d)" % (name, len(cases)))
        return 0
    finally:
        subprocess.run(("sudo", "-n", "rm", "-rf", "--one-file-system", base), capture_output=True)


if __name__ == "__main__":
    sys.exit(main())
