#!/usr/bin/env python3
# list all of the folders of the tool, test and install trees

import os
import subprocess
import sys
import tempfile

TOOL_TREES = ("tools/build", "tools/fetch")
TEST_TREES = ("test/vm", "test/system", "test/checks")
TEST_SKIP = ("test/checks/data", "test/checks/data/keymint-boot-calls", "test/system/fixtures",
             "test/system/guest/gnome-harness-ext", "test/vm/guest-os/config")
INSTALL_TREE = "src/install"
INSTALL_SKIP = ("src/install/tests",)
GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def tree_dirs(repo, roots, skip=()):
    """return each root and its folders"""
    out = []
    for root in roots:
        found = []
        for d, subdirs, _ in os.walk(os.path.join(repo, root)):
            rel = os.path.relpath(d, repo)
            subdirs[:] = [s for s in subdirs if s != "__pycache__" and os.path.join(rel, s) not in skip]
            found.append(rel)
        out += sorted(found)
    return tuple(out)


def tool_dirs(repo):
    """return each tool tree and every folder under it"""
    return tree_dirs(repo, TOOL_TREES)


def test_dirs(repo):
    """return each test tree and every folder under it that holds scripts"""
    return tree_dirs(repo, TEST_TREES, TEST_SKIP)


def install_dirs(repo):
    """return src/install's script folders"""
    return tree_dirs(repo, (INSTALL_TREE,), INSTALL_SKIP)


def tracked_dirs(repo, roots, skip=()):
    """return the folders under the given trees that hold a tracked file, minus the skipped ones"""
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", *roots], check=True,
                         capture_output=True, env=GIT_CLEAN_ENV).stdout
    dirs = set()
    for p in out.decode().split("\0"):
        d = os.path.dirname(p)
        if any(d == s or d.startswith(s + "/") for s in skip):
            continue
        while d and d not in ("tools", "test", "src"):
            dirs.add(d)
            d = os.path.dirname(d)
    return dirs


def selftest():
    """check the lists on a fixture tree and on this repo"""
    fail = 0
    with tempfile.TemporaryDirectory() as tmp:
        for d in ("tools/build/hal", "tools/build/packaging/deb/__pycache__", "tools/fetch/images",
                  "tools/fetch/pools/deb", "tools/fetch/pools/arch",
                  "tools/patches/x", "test/vm/rig", "test/system/boot", "test/system/fixtures/gsi-update",
                  "test/checks/launcher/stack", "test/checks/data/audiod",
                  "test/apps/winapp", "test/apps/fpsapp", "src/install/cli", "src/install/tests",
                  "src/install/prepare/__pycache__"):
            os.makedirs(os.path.join(tmp, d))
        want = ("tools/build", "tools/build/hal", "tools/build/packaging", "tools/build/packaging/deb",
                "tools/fetch", "tools/fetch/images", "tools/fetch/pools", "tools/fetch/pools/arch",
                "tools/fetch/pools/deb")
        got = tool_dirs(tmp)
        if got == want:
            print("ok   selftest: a fixture tree lists each tool tree and every folder under it, never __pycache__, tools/patches or test/")
        else:
            print("SELFTEST FAIL: the fixture's tool folders gave %s, wanted %s" % (got, want))
            fail = 1
        want = ("test/vm", "test/vm/rig", "test/system", "test/system/boot", "test/checks", "test/checks/launcher",
                "test/checks/launcher/stack")
        got = test_dirs(tmp)
        if got == want:
            print("ok   selftest: a fixture tree lists each test tree and every script folder under it, never data, fixtures or test/apps")
        else:
            print("SELFTEST FAIL: the fixture's test folders gave %s, wanted %s" % (got, want))
            fail = 1
        want = ("src/install", "src/install/cli", "src/install/prepare")
        got = install_dirs(tmp)
        if got == want:
            print("ok   selftest: a fixture tree lists src/install and every folder under it, never tests or __pycache__")
        else:
            print("SELFTEST FAIL: the fixture's install folders gave %s, wanted %s" % (got, want))
            fail = 1
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    for label, listed, held in (("tool", set(tool_dirs(here)), tracked_dirs(here, TOOL_TREES)),
                                ("test", set(test_dirs(here)), tracked_dirs(here, TEST_TREES, TEST_SKIP)),
                                ("install", set(install_dirs(here)), tracked_dirs(here, (INSTALL_TREE,), INSTALL_SKIP))):
        if held and held <= listed:
            print("ok   selftest: every one of this repo's %d %s folders holding a tracked file is listed" % (len(held), label))
        else:
            print("SELFTEST FAIL: %s folders holding a tracked file are not listed: %s" % (label, sorted(held - listed)))
            fail = 1
    print("tree_dirs.py selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--selftest"]:
        sys.exit(selftest())
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if "--repo" in args:
        i = args.index("--repo")
        if i + 1 >= len(args):
            print("usage: tree_dirs.py [--tools] [--test] [--repo DIR] | --selftest", file=sys.stderr)
            sys.exit(2)
        repo = args[i + 1]
        del args[i:i + 2]
    if not set(args) <= {"--tools", "--test"}:
        print("usage: tree_dirs.py [--tools] [--test] [--repo DIR] | --selftest", file=sys.stderr)
        sys.exit(2)
    dirs = []
    if not args or "--tools" in args:
        dirs += tool_dirs(repo)
    if "--test" in args:
        dirs += test_dirs(repo)
    for d in dirs:
        print(d)
