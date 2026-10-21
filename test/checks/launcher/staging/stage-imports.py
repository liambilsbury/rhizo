#!/usr/bin/env python3
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
REDEPLOY = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
COMMON = os.path.join(HERE, "..", "..", "..", "vm", "common.sh")


def local_rhizo_imports(src):
    """return the imported sandbox/*.py filenames"""
    names = set()
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("sandbox."):
                    names.add(alias.name.replace(".", "/") + ".py")
        elif isinstance(node, ast.ImportFrom):
            if node.module == "sandbox":
                names |= {"sandbox/%s.py" % a.name for a in node.names}
            elif node.module and node.module.startswith("sandbox."):
                names.add(node.module.replace(".", "/") + ".py")
    return names


def transitive_rhizo_imports(start_path):
    """return the transitive rhizo_*.py imports"""
    seen = set()
    queued = {start_path}
    queue = [start_path]
    while queue:
        path = queue.pop()
        for mod in local_rhizo_imports(open(path).read()):
            seen.add(mod)
            mod_path = os.path.join(REPO, "src", "androidd", mod)
            if mod_path not in queued and os.path.exists(mod_path):
                queued.add(mod_path)
                queue.append(mod_path)
    return seen


def staged_files(redeploy_src):
    """return the STAGE_FILES entries from redeploy.sh text"""
    m = re.search(r'STAGE_FILES=\(\n(.*?)\n\)', redeploy_src, re.S)
    if not m:
        return None
    out = set()
    for line in m.group(1).split("\n"):
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


def stage_dirs(common_src):
    """return the STAGE_DIR_NAMES entries from common.sh text"""
    m = re.search(r'^STAGE_DIR_NAMES="([^"]*)"', common_src, re.M)
    return {d + "/" for d in m.group(1).split()} if m else set()


def check(imports, staged):
    """return the imports missing from the staged files and directories"""
    return sorted(
        "%s is imported (directly or transitively) by launcher3.py but "
        "missing from redeploy.sh STAGE_FILES and common.sh STAGE_DIR_NAMES" % m
        for m in imports if m not in staged and m.split("/")[0] + "/" not in staged)


def selftest():
    """run the stage-imports checks on redeploy.sh"""
    n = 0
    imports = transitive_rhizo_imports(LAUNCHER)
    assert imports, "launcher3.py imports no sandbox modules"
    n += 1
    redeploy_src = open(REDEPLOY).read()
    staged = staged_files(redeploy_src)
    assert staged, "STAGE_FILES not found in the real redeploy.sh"
    dirs = stage_dirs(open(COMMON).read())
    assert "sandbox/" in dirs, "STAGE_DIR_NAMES does not stage the sandbox package"
    n += 1
    assert check(imports, staged | dirs) == [], (
        "the real tree should agree with itself: %s" % check(imports, staged | dirs))
    n += 1
    findings = check(imports, staged | (dirs - {"sandbox/"}))
    expect = sorted("%s is imported (directly or transitively) by launcher3.py but "
                    "missing from redeploy.sh STAGE_FILES and common.sh STAGE_DIR_NAMES" % m
                    for m in imports if m.startswith("sandbox/"))
    assert findings and findings == expect, (
        "dropping the sandbox stage dir should flag every sandbox import, and only those: %s" % findings)
    n += 1
    print("check-stage-imports selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    launcher_imports = transitive_rhizo_imports(LAUNCHER)
    staged = staged_files(open(REDEPLOY).read())
    if staged is None:
        print("check-stage-imports: STAGE_FILES not found in redeploy.sh")
        sys.exit(1)
    findings = check(launcher_imports, staged | stage_dirs(open(COMMON).read()))
    for f in findings:
        print("check-stage-imports: " + f)
    sys.exit(1 if findings else 0)
