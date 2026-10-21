#!/usr/bin/env python3
# check that build and fetch tree paths resolve

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

SKIPPED = ("debian/changelog", "test/checks/build/build-paths.py", "tools/build/rules.py")
UNTRACKED_TOPS = {"var", "toolchain", "aosp-android16-qpr2", "mesa-src", ".rhizo-inputs.tsv", ".worktrees"}
SCRIPT_EXTS = (".sh", ".py", ".tsv")
SIBLING_DIRS = ("tools/build/", "tools/fetch/")
FIXTURES = {
    "test/checks/tree/repo/arch-neutral.py": {"tools/build/a.sh", "tools/build/b.sh", "tools/build/ndk.sh"},
    "test/checks/packaging/deb/deb-routes.py": {"tools/build/elsewhere.sh", "tools/build/routed.sh"},
    "test/checks/build/libcxx-boundary.py": {"tools/build/rowless.sh"},
    "test/checks/build/payload-producers.py": {"tools/build/x.sh", "tools/build/y.sh"},
    "test/checks/vm/image/stage-sync.py": {"test/vm/rhizo-launch.sh", "test/vm/rhizo-release-idle-display.sh",
                                  "test/vm/rhizo-display-pool-release.service", "test/vm/rhizo-cgroup-unfreeze.sh"},
    "test/checks/lib/tree_dirs.py": {"tools/build/packaging/deb/__pycache__", "tools/fetch/images", "tools/fetch/pools",
                                 "tools/fetch/pools/arch", "tools/fetch/pools/deb"},
}

TOOLS_PATH = re.compile(r"(?<![\w.-])tools/(?:build|fetch|results|maint)(?:/[\w.+-]+)*/?")
TEST_PATH = re.compile(r"(?<![\w.-])test/(?:vm|system|checks|benchmarks|apps)(?:/[\w.+-]+)*/?")
CHAIN = re.compile(r"(?<![\w.])\.\.(?:/\.\.)*(?:/[\w.+-]+)*")
OWN_DIR = (r"(?:\$\{?(?:T|TOOLS|TOOLS_DIR|tools|DIR|HERE|DEB_POOL_TOOLS|DEB_POOL_FETCH_ENV_TOOLS|RRD_TOOLS|_dp_here"
           r"|DEB_PREFLIGHT_BUILD_DIR)\}?|\$\(dirname \"\$\{BASH_SOURCE\[0\]\}\"\)|(?<![\w.$}/-])\.)")
SIBLING = re.compile(OWN_DIR + r"/([\w.+-]+\.(?:sh|py))(?![\w.-])")
MAKE_TARGET = re.compile(r"^((?:tools|test|src|debian|docs)/[\w./+-]+)\s*:(?!=)", re.M)


def tracked(root):
    """return the tracked paths of a repo"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True,
                         capture_output=True, env=GIT_CLEAN_ENV).stdout
    return [p for p in out.decode().split("\0") if p]


def tracked_dirs(paths):
    """return the directories that hold tracked files"""
    dirs = {"."}
    for p in paths:
        while "/" in p:
            p = p.rsplit("/", 1)[0]
            dirs.add(p)
    return dirs


def read_text(root, rel):
    """return a file's text, or None when it cannot be read as UTF-8"""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def resolves(p, files, dirs):
    """check a path a relative literal resolves to"""
    if p in files or p in dirs or p.split("/")[0] in UNTRACKED_TOPS:
        return True
    if p.endswith(SCRIPT_EXTS):
        return False
    return "/".join(p.split("/")[:2]) in dirs


def make_targets(root):
    """return the paths the top-level Makefile has a rule to make"""
    text = read_text(root, "Makefile") or ""
    return set(MAKE_TARGET.findall(text))


def findings(root):
    """return the paths that do not resolve"""
    paths = tracked(root)
    files, dirs = set(paths) | make_targets(root), tracked_dirs(paths)
    by_name = {}
    for p in paths:
        by_name.setdefault(os.path.basename(p), []).append(p)
    out = []
    for rel in paths:
        if rel.startswith(SKIPPED):
            continue
        text = read_text(root, rel)
        if text is None:
            continue
        allowed = FIXTURES.get(rel, set())
        for m in TOOLS_PATH.finditer(text):
            nxt = text[m.end():m.end() + 1]
            lit = m.group(0).rstrip("/").rstrip(".")
            if (nxt and nxt in "*{$%[<") or lit in allowed:
                continue
            if lit not in files and lit not in dirs:
                out.append("%s: names %s, which does not exist" % (rel, lit))
        for m in TEST_PATH.finditer(text):
            nxt = text[m.end():m.end() + 1]
            lit = m.group(0).rstrip("/").rstrip(".")
            if (nxt and nxt in "*{$%[<") or lit in allowed or lit in files or lit in dirs:
                continue
            elsewhere = [p for p in by_name.get(os.path.basename(lit), ()) if p.startswith("test/") or p.startswith("src/")]
            if elsewhere:
                out.append("%s: names %s, which does not exist (%s is a file of that name)" % (rel, lit, elsewhere[0]))
        if not rel.startswith("tools/") or not rel.endswith((".sh", ".py")):
            continue
        here = os.path.dirname(rel)
        for m in CHAIN.finditer(text):
            lit = m.group(0)
            if "/" not in lit:
                continue
            p = os.path.normpath(os.path.join(here, lit))
            if p.startswith(".."):
                out.append("%s: %s climbs above the repo" % (rel, lit))
            elif set(lit.split("/")) == {".."} and p != ".":
                out.append("%s: %s is meant to reach the repo root but reaches %s" % (rel, lit, p))
            elif p != "." and not resolves(p, files, dirs):
                out.append("%s: %s resolves to %s, which does not exist" % (rel, lit, p))
        if not rel.startswith(SIBLING_DIRS):
            continue
        for m in SIBLING.finditer(text):
            p = os.path.normpath(os.path.join(here, m.group(1)))
            if p not in files:
                out.append("%s: %s names %s, which does not exist" % (rel, m.group(0), p))
    return out


def run_fixture(files):
    """run the check on a fixture repo"""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True, env=GIT_CLEAN_ENV)
        for rel, body in files.items():
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(body)
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        return findings(tmp)


def selftest():
    """check each finding on fixtures, flagged and clean"""
    good = {
        "test/vm/fixture-lib.sh": "",
        "tools/build/payload.sh": 'cd "$(dirname "${BASH_SOURCE[0]}")/../.."\n',
        "tools/build/g/helper.sh": "",
        "tools/build/g/widget.sh": ('cd "$(dirname "${BASH_SOURCE[0]}")/../../.."\n'
                                     "source ../../../test/vm/fixture-lib.sh\n"
                                     "./helper.sh x\n"
                                     '"$HERE/../../../tools/fetch/get.sh"\n'
                                     "out=../../../var/share/x\n"
                                     "../../../test/vm/new-output-dir\n"),
        "tools/fetch/get.sh": "source ../build/g/helper.sh\n",
        "tools/fetch/g/fetcher-lib.sh": "",
        "tools/fetch/g/fetcher.sh": ('cd "$(dirname "${BASH_SOURCE[0]}")/../../.."\n'
                                     "source ./fetcher-lib.sh\n"
                                     'source "$RRD_TOOLS/fetcher-lib.sh"\n'
                                     "pool=../../../var/share/x\n"),
        "docs/design/x.md": ("run `tools/build/g/widget.sh`, see tools/build/*.sh and tools/build/\n"
                             "fetch with `tools/fetch/g/fetcher.sh`\n"
                             "boot with `test/vm/sub/gone.sh`, see test/system/*.sh and test/system/run/lib.sh\n"),
        "test/vm/sub/gone.sh": "",
        "test/system/run/lib.sh": "",
        "test/checks/f.py": 'FIXTURE = "test/system/tok-p.sh"\n',
    }
    bad_cases = [
        ("tools/build/g/widget.sh", 'cd "$(dirname "${BASH_SOURCE[0]}")/../.."\n', "is meant to reach the repo root"),
        ("tools/build/g/widget.sh", "source ../../test/vm/fixture-lib.sh\n", "which does not exist"),
        ("tools/build/g/widget.sh", "x=../../../../y\n", "climbs above the repo"),
        ("tools/build/g/widget.sh", "./missing.sh\n", "names tools/build/g/missing.sh"),
        ("tools/build/g/widget.sh", '"$TOOLS/gone.py"\n', "names tools/build/g/gone.py"),
        ("tools/fetch/get.sh", "source ../build/helper.sh\n", "tools/build/helper.sh, which does not exist"),
        ("docs/design/x.md", "see `tools/build/widget.sh`\n", "names tools/build/widget.sh"),
        ("test/checks/c.py", 'P = "../../tools/build/gone.sh"\n', "names tools/build/gone.sh"),
        ("docs/design/x.md", "see `tools/fetch/fetcher.sh`\n", "names tools/fetch/fetcher.sh"),
        ("test/checks/c.py", 'P = "../../tools/fetch/gone.sh"\n', "names tools/fetch/gone.sh"),
        ("tools/fetch/g/fetcher.sh", "source ./gone-lib.sh\n", "names tools/fetch/g/gone-lib.sh"),
        ("tools/fetch/g/fetcher.sh", 'source "$RRD_TOOLS/gone-lib.sh"\n', "names tools/fetch/g/gone-lib.sh"),
        ("tools/fetch/g/fetcher.sh", 'cd "$(dirname "${BASH_SOURCE[0]}")/../.."\n', "is meant to reach the repo root"),
        ("docs/design/x.md", "boot with `test/vm/gone.sh`\n", "names test/vm/gone.sh, which does not exist (test/vm/sub/gone.sh is a file of that name)"),
        ("test/checks/c.py", 'LIB = "test/system/lib/lib.sh"\n', "names test/system/lib/lib.sh, which does not exist (test/system/run/lib.sh is a file of that name)"),
    ]
    fail = 0
    got = run_fixture(good)
    if got:
        print("SELFTEST FAIL: a clean fixture was flagged: %s" % got)
        fail = 1
    else:
        print("ok   selftest: a rebased script, its sibling call and a doc path all pass")
    for rel, body, want in bad_cases:
        files = dict(good)
        files[rel] = body
        got = run_fixture(files)
        if not any(g.startswith(rel + ":") and want in g for g in got):
            print("SELFTEST FAIL: %s with %r gave %s, wanted '%s'" % (rel, body.strip(), got, want))
            fail = 1
        else:
            print("ok   selftest: %s %r is caught (%s)" % (rel, body.strip(), want))
    files = dict(good)
    files["Makefile"] = "tools/build/made.mk: tools/build/g/helper.sh\n\tpython3 x\n"
    files["docs/design/x.md"] = "include `tools/build/made.mk`\n"
    if run_fixture(files):
        print("SELFTEST FAIL: a file the Makefile has a rule to make was flagged as missing")
        fail = 1
    else:
        print("ok   selftest: a file the Makefile has a rule to make passes untracked")
    files["Makefile"] = "other: tools/build/g/helper.sh\n\tpython3 x\n"
    if not any("names tools/build/made.mk, which does not exist" in g for g in run_fixture(files)):
        print("SELFTEST FAIL: a file no Makefile rule makes and git does not track was not flagged")
        fail = 1
    else:
        print("ok   selftest: a file only a Makefile prerequisite names, untracked, is still caught")
    files = dict(good)
    files["test/checks/build/payload-producers.py"] = "'tools/build/x.sh'\n"
    if run_fixture(files):
        print("SELFTEST FAIL: a declared fixture path was flagged")
        fail = 1
    else:
        print("ok   selftest: a declared fixture path passes")
    files = dict(good)
    files["debian/changelog"] = "rhizo (0.1.1) noble; urgency=medium\n\n  * Upgrade: a real leg (test/vm/gone.sh step 11)\n"
    if run_fixture(files):
        print("SELFTEST FAIL: a released changelog entry naming a moved test was flagged")
        fail = 1
    else:
        print("ok   selftest: a released changelog entry keeps the path it was released with")
    print("build-paths.py selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    root = argv[2] if argv[1:2] == ["--root"] else REPO
    bad = findings(root)
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("check-build-paths: every tools/ path a tracked file names exists, every relative path a tools/ script uses resolves, "
          "and no test/ path names a file that moved")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
