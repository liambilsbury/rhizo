#!/usr/bin/env python3
# check all of the tracked shell and python scripts parse

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def unparsed(repo):
    """return each tracked script that does not parse"""
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "*.sh", "*.py"], check=True, capture_output=True,
                         env=GIT_ENV).stdout.decode()
    bad = []
    for rel in sorted(p for p in out.split("\0") if p):
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            continue
        if rel.endswith(".sh"):
            r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
            if r.returncode != 0:
                bad.append((rel, r.stderr.strip().split("\n")[0]))
        else:
            try:
                with open(path, "rb") as f:
                    compile(f.read(), rel, "exec", dont_inherit=True)
            except (SyntaxError, ValueError) as e:
                bad.append((rel, str(e)))
    return bad


def selftest():
    """check broken and good scripts in a fixture"""
    work = tempfile.mkdtemp(prefix="scripts-parse-")
    try:
        files = {"good.sh": "#!/bin/bash\nif true; then echo ok; fi\n", "bad.sh": "#!/bin/bash\nif true; then\n",
                 "good.py": "x = 1\n", "sub/bad.py": "def f(:\n", "notes.txt": "if (\n"}
        for rel, body in files.items():
            os.makedirs(os.path.dirname(os.path.join(work, rel)) or work, exist_ok=True)
            with open(os.path.join(work, rel), "w") as f:
                f.write(body)
        subprocess.run(["git", "init", "-q", work], check=True, env=GIT_ENV)
        subprocess.run(["git", "-C", work, "add", "-A"], check=True, env=GIT_ENV)
        got = sorted(p for p, _ in unparsed(work))
        ok = got == ["bad.sh", "sub/bad.py"]
        print("%s selftest: a broken shell script and a broken python file are named, nothing else%s"
              % ("ok  " if ok else "FAIL", "" if ok else " -- got %s" % got))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("scripts-parse.py selftest: %s" % ("ok" if ok else "FAILED"))
    return 0 if ok else 1


def main(argv):
    """name every tracked script that does not parse, or run the selftest"""
    if argv == ["--selftest"]:
        return selftest()
    bad = unparsed(REPO)
    for path, why in bad:
        print("FAIL: %s does not parse: %s" % (path, why))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
