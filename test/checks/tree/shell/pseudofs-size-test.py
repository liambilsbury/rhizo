#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import layout_paths as layout

PSEUDO_DIRS = ("/proc/", "/sys/")
CGROUP_FILES = re.compile(
    r"/(cgroup\.[a-z_.]+|memory\.[a-z_.]+|cpu\.[a-z_.]+|io\.[a-z_.]+|pids\.[a-z_.]+"
    r"|freezer\.[a-z_.]+|cpuset\.[a-z_.]+)(\"|'|\}|\)|\s|$)")

SHELL_TEST = re.compile(r"\[\[?\s+(?:!\s+)?-s\s+(\"[^\"]+\"|'[^']+'|\S+)")
PY_SIZE = re.compile(r"(?:os\.path\.getsize|\.st_size)\s*\(?\s*(\"[^\"]+\"|'[^']+'|[A-Za-z_][\w.\[\]\"']*)")


def is_pseudo(operand):
    """return whether an operand names a pseudo filesystem file"""
    bare = operand.strip("\"'")
    if any(d in bare for d in PSEUDO_DIRS):
        return True
    return bool(CGROUP_FILES.search(bare + " "))


def scan(text):
    """list the pseudo-filesystem size tests"""
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        for pattern in (SHELL_TEST, PY_SIZE):
            for m in pattern.finditer(line):
                if is_pseudo(m.group(1)):
                    hits.append((n, m.group(1)))
    return hits


GIT_ENV = ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_COMMON_DIR",
           "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")


def clean_env():
    """return the environment without git variables"""
    env = dict(os.environ)
    for k in GIT_ENV:
        env.pop(k, None)
    return env


def tracked_sources(root):
    """return the tracked shell and python sources inside the layout"""
    out = subprocess.run(["git", "ls-files", "-z"], cwd=root, env=clean_env(),
                         capture_output=True, text=True)
    if out.returncode != 0:
        return []
    names = [f for f in out.stdout.split("\0") if f]
    return [f for f in names if f.endswith((".sh", ".py", ".bash")) and not layout.outside_layout(f)]


def selftest():
    """test scan on fixture files"""
    with tempfile.TemporaryDirectory() as d:
        bad = os.path.join(d, "bad.sh")
        with open(bad, "w") as fh:
            fh.write('if [[ -s /proc/swaps ]]; then swap_up=1; fi\n')
        if not scan(open(bad).read()):
            print("selftest FAIL: a literal /proc size test was not caught", file=sys.stderr)
            return 1

        cg = os.path.join(d, "cg.sh")
        with open(cg, "w") as fh:
            fh.write('[ -s "$d/cgroup.procs" ] || continue\n')
        if not scan(open(cg).read()):
            print("selftest FAIL: a cgroup control file through a variable was not caught",
                  file=sys.stderr)
            return 1

        ok = os.path.join(d, "ok.sh")
        with open(ok, "w") as fh:
            fh.write('[[ -s "$LOGCOPY" ]] || die "empty log"\n')
        if scan(open(ok).read()):
            print("selftest FAIL: an ordinary file size test was flagged", file=sys.stderr)
            return 1
    return 0


def main():
    """scan tracked files for pseudo-filesystem size tests"""
    if "--selftest" in sys.argv:
        return selftest()

    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

    failed = 0
    me = os.path.relpath(os.path.abspath(__file__), root)
    for rel in tracked_sources(root):
        if rel == me:
            continue
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            continue
        try:
            with open(path, errors="replace") as fh:
                text = fh.read()
        except OSError as exc:
            print("could not read %s: %s" % (rel, exc), file=sys.stderr)
            failed = 1
            continue
        for lineno, operand in scan(text):
            print("FAIL: %s:%d size test on %s is always false -- read the content instead"
                  % (rel, lineno, operand), file=sys.stderr)
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
