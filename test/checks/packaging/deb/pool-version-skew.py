#!/usr/bin/env python3
"""Fail when a package has two versions across the var/share debs pools"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

USAGE = """Usage:
  test/checks/packaging/deb/pool-version-skew.py [--share DIR]
  test/checks/packaging/deb/pool-version-skew.py --test SYSTEM TEST [--share DIR]
      check the vm-dir: pools of one system test
  test/checks/packaging/deb/pool-version-skew.py --selftest"""

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SYSTEM_DIR = os.path.join(REPO, "test", "system")
VAR_DIR = os.path.join(REPO, "var")
sys.path.insert(0, os.path.join(SYSTEM_DIR, "run"))
import system_tests  # noqa: E402

TEST_REQUIRES_RE = re.compile(r"^# test-requires:\s*(.*)$")

EXCLUDE_POOLS = {"ubuntu-update-debs"}


def _test_requires_pools(path):
    """return the vm-dir pools a test requires"""
    pools = []
    with open(path) as f:
        for line in f:
            m = TEST_REQUIRES_RE.match(line.rstrip("\n"))
            if not m:
                continue
            for tok in m.group(1).split():
                if tok.startswith("vm-dir:"):
                    pool = tok[len("vm-dir:"):]
                    if pool not in EXCLUDE_POOLS:
                        pools.append(pool)
            break
    return pools


def test_pool_groups(tools_dir=SYSTEM_DIR):
    """map multi-pool system tests to their pool names"""
    groups = {}
    for path in system_tests.system_test_paths(tools_dir):
        pools = _test_requires_pools(path)
        if len(pools) >= 2:
            groups[os.path.basename(path)] = pools
    return groups


def pool_package_versions(pool_dir):
    """return the package versions in a pool directory"""
    versions = {}
    if not os.path.isdir(pool_dir):
        return versions
    for entry in sorted(os.listdir(pool_dir)):
        if not entry.endswith(".deb"):
            continue
        out = subprocess.run(
            ["dpkg-deb", "-f", os.path.join(pool_dir, entry), "Package", "Version"],
            capture_output=True, text=True, check=True,
        ).stdout
        pkg = ver = None
        for line in out.splitlines():
            if line.startswith("Package:"):
                pkg = line.split(":", 1)[1].strip()
            elif line.startswith("Version:"):
                ver = line.split(":", 1)[1].strip()
        if pkg:
            versions[pkg] = ver
    return versions


def find_skew(group_label, pools, share_dir):
    """return a problem line per skewed package"""
    per_pool = {pool: pool_package_versions(os.path.join(share_dir, pool)) for pool in pools}
    all_pkgs = set()
    for versions in per_pool.values():
        all_pkgs |= versions.keys()
    problems = []
    for pkg in sorted(all_pkgs):
        by_version = {}
        for pool in pools:
            ver = per_pool[pool].get(pkg)
            if ver is not None:
                by_version.setdefault(ver, []).append(pool)
        if len(by_version) > 1:
            detail = "; ".join(f"{ver} in {','.join(ps)}" for ver, ps in sorted(by_version.items()))
            prefix = f"{group_label}: " if group_label else ""
            problems.append(f"{prefix}{pkg} is not the same version across the pools it stages with: {detail}")
    return problems


def check_one_test(test_name, share_dir, tools_dir=SYSTEM_DIR):
    """return version skew problems for a system test"""
    path = system_tests.test_path(test_name, tools_dir) or os.path.join(tools_dir, test_name)
    pools = _test_requires_pools(path) if os.path.isfile(path) else []
    if len(pools) < 2:
        return []
    return find_skew(None, pools, share_dir)


def main(argv):
    """run the check on the package pools or run the selftest"""
    ap = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE)
    ap.add_argument("--share", default=os.path.join(VAR_DIR, "share"),
                     help="var/share directory holding the *-debs pools (default: this tree's own)")
    ap.add_argument("--test", help="check only this one system test's own vm-dir: pools, never the whole tree")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return 0 if _selftest() else 1

    if args.test:
        problems = check_one_test(args.test, args.share)
        if problems:
            for p in problems:
                print(f"[check-pool-version-skew] {p}")
            return 1
        print(f"[check-pool-version-skew] {args.test}: agrees on every package its own pools share (or names fewer than two vm-dir: pools)")
        return 0

    groups = test_pool_groups()
    if not groups:
        print("[check-pool-version-skew] no system test names two or more vm-dir: pools", file=sys.stderr)
        return 2

    problems = []
    for test, pools in sorted(groups.items()):
        problems += find_skew(test, pools, args.share)

    if problems:
        for p in problems:
            print(f"[check-pool-version-skew] {p}")
        return 1
    print(f"[check-pool-version-skew] every pool a system test stages together agrees on every package the others also hold ({', '.join(sorted(groups))})")
    return 0


def _mkdeb(pool_dir, name, version, arch="all"):
    """build a fixture package in a pool"""
    src = os.path.join(pool_dir, f".src-{name}-{version}-{arch}")
    os.makedirs(os.path.join(src, "DEBIAN"), exist_ok=True)
    with open(os.path.join(src, "DEBIAN", "control"), "w") as f:
        f.write(f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\n"
                "Maintainer: selftest <selftest@invalid>\nDescription: fixture\n")
    out = os.path.join(pool_dir, f"{name}_{version}_{arch}.deb")
    subprocess.run(["dpkg-deb", "-Znone", "--build", src, out],
                   capture_output=True, text=True, check=True)
    return out


def _selftest():
    """run find_skew and check_one_test on fixture pools"""
    bad = 0

    def ok(msg):
        """print a selftest pass line"""
        print(f"SELFTEST OK: {msg}")

    def fail(msg):
        """print a selftest failure line and count it"""
        nonlocal bad
        print(f"SELFTEST FAIL: {msg}")
        bad += 1

    with tempfile.TemporaryDirectory() as t:
        share = os.path.join(t, "share")
        pool_a = os.path.join(share, "pool-a")
        pool_b = os.path.join(share, "pool-b")
        os.makedirs(pool_a)
        os.makedirs(pool_b)
        _mkdeb(pool_a, "libshared", "1.0")
        _mkdeb(pool_a, "libonly-a", "1.0")
        _mkdeb(pool_b, "libshared", "1.0")
        _mkdeb(pool_b, "libonly-b", "1.0")

        problems = find_skew("fixture-clean", ["pool-a", "pool-b"], share)
        if not problems:
            ok("find_skew is clean (green) when every pool agrees on the one package they share, and never compares a pool-only package against nothing")
        else:
            fail(f"find_skew refused two pools that agree: {problems}")

        os.remove(os.path.join(pool_b, "libshared_1.0_all.deb"))
        _mkdeb(pool_b, "libshared", "1.1")
        problems = find_skew("fixture-skew", ["pool-a", "pool-b"], share)
        if (len(problems) == 1 and "libshared" in problems[0]
                and "1.0 in pool-a" in problems[0] and "1.1 in pool-b" in problems[0]):
            ok("find_skew is red when two pools hold the same package at different versions, naming the package and which pool holds which version")
        else:
            fail(f"find_skew missed the planted skew: {problems}")

        problems = find_skew("fixture-missing", ["pool-a", "pool-nonexistent"], share)
        if not problems:
            ok("find_skew reads a pool that has not been fetched yet as holding nothing, never as agreeing or disagreeing")
        else:
            fail(f"find_skew invented a skew against a missing pool: {problems}")

        test_dir = os.path.join(t, "tests")
        os.makedirs(test_dir)
        with open(os.path.join(test_dir, "fixture-a.sh"), "w") as f:
            f.write("#!/bin/bash\n# test-boot-mode: shared\n"
                    "# test-requires: deb:rhizo vm-dir:pool-a vm-dir:pool-b vm-dir:ubuntu-update-debs\n")
        with open(os.path.join(test_dir, "fixture-b.sh"), "w") as f:
            f.write("#!/bin/bash\n# test-boot-mode: shared\n# test-requires: vm-dir:pool-a\n")
        with open(os.path.join(test_dir, "fixture-c.sh"), "w") as f:
            f.write("#!/bin/bash\n# test-boot-mode: shared\n# test-requires: none\n")
        groups = test_pool_groups(test_dir)
        if groups == {"fixture-a.sh": ["pool-a", "pool-b"]}:
            ok("test_pool_groups reads vm-dir: pools off each system test's own test-requires line, drops ubuntu-update-debs by name, and skips a system test naming fewer than two pools")
        else:
            fail(f"test_pool_groups: {groups}")

        problems = check_one_test("fixture-a.sh", share, tools_dir=test_dir)
        if (len(problems) == 1 and problems[0].startswith("libshared is not the same version")
                and "1.0 in pool-a" in problems[0] and "1.1 in pool-b" in problems[0]):
            ok("check_one_test refuses a named system test whose own pools disagree, naming the package and both versions, with no test-name prefix to duplicate what the caller already knows")
        else:
            fail(f"check_one_test on a skewed test: {problems}")
        if check_one_test("fixture-b.sh", share, tools_dir=test_dir) == []:
            ok("check_one_test never checks a system test naming fewer than two vm-dir: pools")
        else:
            fail("check_one_test checked a system test with only one vm-dir: pool")
        if check_one_test("fixture-c.sh", share, tools_dir=test_dir) == []:
            ok("check_one_test passes a system test declaring no test-requires tokens at all")
        else:
            fail("check_one_test flagged a system test declaring none")
        if check_one_test("does-not-exist.sh", share, tools_dir=test_dir) == []:
            ok("check_one_test passes a system test name that does not exist on disk, rather than crashing the preflight that calls it")
        else:
            fail("check_one_test did not pass a nonexistent system test file cleanly")

    print(f"check-pool-version-skew selftest: {'FAIL' if bad else 'OK'} ({bad} failed)")
    return bad == 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
