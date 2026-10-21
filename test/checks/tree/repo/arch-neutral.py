#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LITERAL = re.compile(r"\bx86_64\b|\bgeneric_x86_64\b|\bx86-64\b")

ALLOW_FILE = "data/arch-specific.tsv"
BASELINE_FILE = "data/arch-neutral.json"

INCLUDE = ("test/checks/", "test/system/", "test/vm/",  "tools/", "src/services/", "src/install/prepare/align-apex.py", "src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh", "src/install/prepare/materialize-data-template.py", "src/install/prepare/data-template.sh", "src/androidd/host/capture-kernel-log.sh", "src/androidd/host/parse-display-list.sh", "src/androidd/host/launch-app.sh", "src/androidd/host/release-idle-display.sh", "src/androidd/host/fill-display-pool.sh", "src/androidd/host/unfreeze-cgroup.sh", "src/androidd/guest/audioserver.rc", "src/androidd/guest/mediametrics.rc", "src/androidd/sandbox/", "src/androidd/boot.py", "src/install/",
           "src/services/", "src/android/apps/", "src/android/hal/")
EXCLUDE_SUFFIX = (".md", ".json", ".tsv", ".txt", ".xml", ".log", ".png")
EXCLUDE_DIR = ("docs/",
               "test/vm/run-vm.sh", "tools/mesa/mesa-")


def git_env():
    """return the environment without GIT_ variables"""
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def tracked(root):
    """return the tracked paths of a repo"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, text=True, timeout=120, env=git_env())
    return [p for p in out.stdout.split("\0") if p]


def allowed(root):
    """return the allowlisted paths and their reasons"""
    path = os.path.join(root, "test", "checks", ALLOW_FILE)
    out = {}
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            out[parts[0].strip()] = (parts[1].strip() if len(parts) > 1 else "")
    return out


def in_scope(rel):
    """return whether a path is inside the scanned tree and not excluded"""
    if not rel.startswith(INCLUDE):
        return False
    if rel.endswith(EXCLUDE_SUFFIX) or rel.startswith(EXCLUDE_DIR):
        return False
    return True


def counts(root):
    """return the architecture literal count of each scanned file"""
    allow = allowed(root)
    found = {}
    for rel in tracked(root):
        if not in_scope(rel) or rel in allow:
            continue
        full = os.path.join(root, rel)
        try:
            with open(full, encoding="utf-8", errors="ignore") as fh:
                n = sum(len(LITERAL.findall(line)) for line in fh)
        except OSError:
            continue
        if n:
            found[rel] = n
    return found


def load_baseline(root):
    """return the saved baseline, or None"""
    p = os.path.join(root, "test", "checks", BASELINE_FILE)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def save_baseline(root, data):
    """write the baseline as sorted JSON"""
    p = os.path.join(root, "test", "checks", BASELINE_FILE)
    with open(p, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")


def check(root, update=False, verbose=True):
    """compare architecture literal counts to the baseline"""
    found = counts(root)
    base = load_baseline(root)
    if base is None:
        if not update:
            return [f"FAIL: arch-neutral: no baseline at test/checks/{BASELINE_FILE}; run --update"]
        save_baseline(root, found)
        if verbose:
            print(f"arch-neutral: baseline written, {len(found)} files, {sum(found.values())} literals")
        return []
    fails = []
    if update:
        merged = {k: min(v, base[k]) if k in base else v for k, v in found.items()}
        for k in base:
            if k not in merged:
                continue
        save_baseline(root, {k: v for k, v in merged.items() if k in found})
        if verbose:
            print("arch-neutral: baseline lowered where the tree improved")
        return []
    for rel, n in sorted(found.items()):
        want = base.get(rel)
        if want is None:
            fails.append(f"FAIL: arch-neutral: {rel} names an architecture ({n}x) and has no baseline -- "
                         f"read it from uname, or list it in test/checks/{ALLOW_FILE} with the reason")
        elif n > want:
            fails.append(f"FAIL: arch-neutral: {rel} names an architecture {n}x, baseline {want} -- "
                         f"the count may fall and never rise")
    if verbose and not fails:
        print(f"arch-neutral: {len(found)} files name an architecture, none above its baseline "
              f"({sum(found.values())} literals, {len(allowed(root))} listed as legitimately specific)")
    return fails


def selftest():
    """test the baseline check on a scratch repo"""
    import tempfile
    asserts = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(root, "test", "checks"))
        subprocess.run(["git", "init", "-q", "-b", "main", root], check=True, env=git_env())

        def write(rel, text):
            """write a file under the fixture root"""
            full = os.path.join(root, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(text)

        write("tools/build/a.sh", "ABI=x86_64\n")
        write("tools/build/ndk.sh", "CC=x86_64-linux-android35-clang\n")
        write("test/checks/" + ALLOW_FILE,
              "tools/build/ndk.sh\tan NDK host triple, which names a target and always will\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())

        assert check(root, update=True, verbose=False) == []
        base = load_baseline(root)
        assert base == {"tools/build/a.sh": 1}, base
        asserts += 1

        assert check(root, verbose=False) == [], "the baselined tree must pass"
        asserts += 1

        write("tools/build/a.sh", "ABI=x86_64\nOTHER=x86_64\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("a.sh names an architecture 2x, baseline 1" in f for f in fails), fails
        asserts += 1

        write("tools/build/b.sh", "ARCH=x86_64\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert any("b.sh names an architecture (1x) and has no baseline" in f for f in fails), fails
        asserts += 1

        write("tools/build/ndk.sh", "CC=x86_64-linux-android35-clang\nCXX=x86_64-linux-android35-clang++\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=git_env())
        fails = check(root, verbose=False)
        assert not any("ndk.sh" in f for f in fails), fails
        asserts += 1

        check(root, update=True, verbose=False)
        assert load_baseline(root)["tools/build/a.sh"] == 1, "update raised a baseline"
        asserts += 1
    print(f"check-arch-neutral selftest: {asserts} assertions, every planted defect named")
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    fails = check(args.root, update=args.update)
    for line in fails:
        print(line, file=sys.stderr)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
