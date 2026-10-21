#!/usr/bin/env python3
# find policy-lab.sh's CIL cache for a staged image
import glob
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL_KEY = ("st=$(stat -c '%s-%Y' \"$GSI_IMG\" 2>/dev/null) || st=\"absent\"",
             'echo "$(basename "$GSI_IMG" .img)-$st"',
             'CIL_DIR="${RHIZO_POLICY_LAB_CIL_DIR:-$CACHE_DIR/cils-$(_gsi_img_key)}"',
             'CACHE_DIR="$VAR_DIR/share/policy-lab"')


def release_cil_dir(root, image):
    """return an image's cached CIL directory, or None"""
    path = os.path.join(root, "var", "gsi", image + ".img")
    cache = os.path.join(root, "var", "share", "policy-lab")
    if os.path.exists(path):
        st = os.stat(path)
        return os.path.join(cache, f"cils-{image}-{st.st_size}-{int(st.st_mtime)}")
    found = sorted(glob.glob(os.path.join(cache, f"cils-{image}-*")))
    return found[0] if len(found) == 1 else None


def selftest():
    """check the key against stat and policy-lab.sh"""
    bad = []
    lab = open(os.path.join(HERE, "policy-lab.sh")).read()
    bad += ["policy-lab.sh no longer reads %r" % line
            for line in SHELL_KEY if line not in lab]
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "var", "gsi"))
        cache = os.path.join(root, "var", "share", "policy-lab")
        os.makedirs(cache)
        img = os.path.join(root, "var", "gsi", "system.img")
        open(img, "wb").write(b"x" * 4096)
        os.utime(img, (1230796800, 1230796800.75))
        st = subprocess.run(["stat", "-c", "%s-%Y", img], capture_output=True, text=True, check=True,
                            timeout=30).stdout.strip()
        want = os.path.join(cache, "cils-system-" + st)
        if release_cil_dir(root, "system") != want:
            bad.append("a staged image keyed %r, not stat's %r" % (release_cil_dir(root, "system"), want))
        os.makedirs(os.path.join(cache, "cils-system-1-2"))
        if release_cil_dir(root, "system") != want:
            bad.append("a staged image's key gave way to another cached directory")
        os.remove(img)
        if release_cil_dir(root, "system") != os.path.join(cache, "cils-system-1-2"):
            bad.append("an unstaged image did not take its one cached directory")
        os.makedirs(os.path.join(cache, "cils-system-3-4"))
        if release_cil_dir(root, "system") is not None:
            bad.append("an unstaged image with two cached directories picked one")
        if release_cil_dir(root, "gsi_a15") is not None:
            bad.append("an image with nothing staged or cached named a directory")
    if bad:
        for b in bad:
            print("FAIL: %s" % b, file=sys.stderr)
        return 1
    print("policy_lab_cache selftest: a staged image is keyed as policy-lab.sh keys it; "
          "an unstaged one takes its one cached directory, never a pick of two")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv else 2)
