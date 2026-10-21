#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
APPSYNC = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "appsync", "appsync.py")

MUTANTS = [
    ("        fcntl.flock(fd, fcntl.LOCK_EX)\n", "        pass\n", "concurrent-writers-both-kept"),
    ("        live_now = installed_packages(be)[0] if every_pkg is not None else None\n",
     "        live_now = every_pkg\n", "mid-pass-install-keeps-its-entry"),
    ('        newer = {k: c["desktop"] for k, c in claims.items()\n',
     '        newer = {} if True else {k: c["desktop"] for k, c in claims.items()\n',
     "newer-drain-default-kept"),
]


def run(text):
    """run --selftest on the given appsync.py text"""
    root = tempfile.mkdtemp(prefix="appsync-overlap-")
    try:
        services = os.path.join(root, "src", "services")
        os.makedirs(services)
        os.makedirs(os.path.join(root, "tools", "build", "packaging", "deb"))
        os.makedirs(os.path.join(root, "src", "androidd", "sandbox"))
        shutil.copy(os.path.join(REPO, "tools", "build", "packaging", "deb", "gen-rhizo-icon.py"), os.path.join(root, "tools", "build", "packaging", "deb"))
        os.makedirs(os.path.join(services, "units", "applications"))
        shutil.copy(os.path.join(REPO, "src", "services", "units", "applications", "apk-installer.desktop"),
                    os.path.join(services, "units", "applications"))
        shutil.copy(os.path.join(REPO, "src", "androidd", "sandbox", "capabilities.py"), os.path.join(root, "src", "androidd", "sandbox"))
        os.makedirs(os.path.join(root, "src", "install", "cli"))
        for name in ("rhizo.sh", "print-share-row.py"):
            shutil.copy(os.path.join(REPO, "src", "install", "cli", name), os.path.join(root, "src", "install", "cli"))
        os.makedirs(os.path.join(services, "appsync"))
        with open(os.path.join(services, "appsync", "appsync.py"), "w") as fh:
            fh.write(text)
        r = subprocess.run([sys.executable, os.path.join(services, "appsync", "appsync.py"), "--selftest"],
                           capture_output=True, text=True, timeout=300)
        return r.returncode, r.stdout + r.stderr
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    """run the appsync selftest and each mutant"""
    text = open(APPSYNC).read()
    rc, out = run(text)
    if rc != 0:
        print("FAIL: check-appsync-overlap: the unmutated appsync.py fails its own selftest:\n" + out[-800:])
        return 1
    bad = []
    for old, new, want in MUTANTS:
        if text.count(old) != 1:
            bad.append("%r is not in appsync.py exactly once" % old.strip())
            continue
        rc, out = run(text.replace(old, new))
        if rc == 0 or ("  %s:" % want) not in out:
            bad.append("with %r cut to %r, %s did not fail (rc=%d): %s"
                       % (old.strip(), new.strip(), want, rc, out.strip()[-300:]))
    if bad:
        for b in bad:
            print("FAIL: check-appsync-overlap: " + b)
        return 1
    print("check-appsync-overlap: OK (the flock, the new pm read and the newer-claims record "
          "each fail their own assertion when cut out)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
