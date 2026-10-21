#!/usr/bin/env python3
import ast
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
DATA = os.path.join(HERE, "..", "..", "data", "nnp-transition-commands.tsv")
LAUNCHER_MODULES = ("boot.py", "sandbox/core.py", "sandbox/selinux_ns.py", "sandbox/rootfs.py", "sandbox/hals.py",
                    "sandbox/selinux_labels.py", "sandbox/guest_files.py", "sandbox/selinux_policy.py")
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
INSTALLED = {"launcher3.py": "src/androidd/boot.py", "rhizo-selinux-mode": "src/androidd/host/selinux-mode.py"}


def commands(path=DATA):
    """return the transitioning command names"""
    with open(path) as f:
        return {l.split("\t")[0] for l in f if l.strip() and not l.startswith("#")}


def sh_pattern(names):
    """return a regex matching a command name in command position"""
    alt = "|".join(sorted(map(re.escape, names), key=len, reverse=True))
    return re.compile(r"(?:(?:^|[;&|(`{!]|\$\(|\bthen\b|\bdo\b|\belse\b|\bif\b|\bwhile\b|\bexec\b|\btimeout\s+\S+|\benv\s+(?:\S+=\S*\s+)*)\s*|['\"])"
                      r"(?:/usr)?(?:/s?bin/)?(" + alt + r")(?=\s|$|[;)|&'\"])")


def find_source(name, repo):
    """return the repo file an installed name comes from, or None"""
    if name in INSTALLED:
        return os.path.join(repo, INSTALLED[name])
    for root, _dirs, files in os.walk(os.path.join(repo, "src")):
        if name in files:
            return os.path.join(root, name)
    return None


def plain_text(line):
    """return a shell line with double-quoted text that runs nothing removed"""
    return re.sub(r'"(?:[^"\\]|\\.)*"', lambda m: m.group(0) if "$(" in m.group(0) else '""', line)


def shell_split(text):
    """return a shell text's top-level lines and its functions' bodies by name"""
    top, funcs, name, body, depth = [], {}, None, [], 0
    for line in text.splitlines():
        m = re.match(r"^\s*([A-Za-z_][\w-]*)\(\)\s*\{(.*)$", line)
        if name is None and m:
            name, body, depth = m.group(1), [m.group(2)], 1 + m.group(2).count("{") - m.group(2).count("}")
            if depth <= 0:
                funcs[name], name = body, None
            continue
        if name is None:
            top.append(line)
            continue
        depth += line.count("{") - line.count("}")
        body.append(line)
        if depth <= 0 or re.match(r"^\}", line):
            funcs[name], name = body, None
    return top, funcs


def shell_deps(text):
    """return the scripts and modules a shell text sources or runs"""
    return re.findall(r"^\s*(?:\.|source)\s+\S*?([\w.-]+\.(?:sh|py))\b", text, re.M) + \
        re.findall(r"(?:\$\{?[A-Z_]+\}?|\$\(dirname[^)]*\))/([\w.-]+\.(?:sh|py))\b", text)


def launcher_verbs(text):
    """return the launcher3.py verbs a script runs"""
    return set(re.findall(r"launcher3\.py\"?\s+([a-z][a-z-]+)\b(?!\s*[=-])", text)) | set(
        re.findall(r"\$LAUNCHER\"?\s+([a-z][a-z-]+)", text))


def py_findings(path, tree, names, only=None):
    """return findings for transitioning commands in a python tree"""
    pat, out = sh_pattern(names), []
    scopes = [tree] if only is None else [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in only]
    for scope in scopes:
        for node in ast.walk(scope):
            if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) \
                    and isinstance(node.elts[0].value, str) and os.path.basename(node.elts[0].value) in names:
                out.append(f"{path}:{node.lineno}: argv execs {node.elts[0].value}")
            if "ldconfig" in names and isinstance(node, ast.Call) and (
                    isinstance(node.func, ast.Attribute) and node.func.attr == "find_library"
                    or isinstance(node.func, ast.Name) and node.func.id == "find_library"):
                out.append(f"{path}:{node.lineno}: find_library execs ldconfig")
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "system":
                for c in ast.walk(node):
                    if isinstance(c, ast.Constant) and isinstance(c.value, str) and pat.search(c.value):
                        out.append(f"{path}:{node.lineno}: shell string execs {pat.search(c.value).group(1)}")
                        break
    return out


def call_names(node):
    """return the bare or attribute names a python node calls"""
    return {c.func.id if isinstance(c.func, ast.Name) else c.func.attr for c in ast.walk(node)
            if isinstance(c, ast.Call) and isinstance(c.func, (ast.Name, ast.Attribute))}


def launcher_calls(tree):
    """return the launcher-module functions a python tree calls"""
    mods = {m[:-3] for m in LAUNCHER_MODULES}
    imported = {a.asname or a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names if a.name in mods}
    names = {a.asname or a.name for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module in mods
             for a in n.names if a.name != "*"}
    return {c.func.attr for c in ast.walk(tree) if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute)
            and isinstance(c.func.value, ast.Name) and c.func.value.id in imported} | (call_names(tree) & names)


def launcher_reach(repo, verbs, roots):
    """return the launcher module trees and reached functions"""
    trees = {m: ast.parse(open(os.path.join(repo, "src", "androidd", m)).read()) for m in LAUNCHER_MODULES}
    defs = {n.name: n for t in trees.values() for n in ast.walk(t) if isinstance(n, ast.FunctionDef)}
    roots = set(roots)
    for node in ast.walk(trees["boot.py"]):
        if isinstance(node, ast.If) and any(isinstance(c, ast.Constant) and c.value in verbs for c in ast.walk(node.test)):
            roots |= {n for st in node.body for n in call_names(st)}
    seen, todo = set(), [r for r in roots if r in defs]
    while todo:
        name = todo.pop()
        if name not in seen:
            seen.add(name)
            todo += [c for c in call_names(defs[name]) if c in defs and c not in seen]
    return trees, seen


def unit_findings(unit_path, repo, names):
    """return the findings for a NoNewPrivileges unit"""
    text = open(unit_path).read()
    pat, out, files, verbs, py_roots = sh_pattern(names), [], set(), set(), set()
    for line in re.findall(r"^Exec\w*=(.*(?:\\\n.*)*)", text, re.M):
        if line.lstrip("-@:!").startswith("+"):
            continue
        for m in pat.finditer(line):
            out.append(f"{os.path.basename(unit_path)}: Exec line execs {m.group(1)}")
        for p in re.findall(r"(/usr/lib/rhizo/[\w/.-]+|/root/[\w.-]+)", line):
            src = find_source(os.path.basename(p), repo)
            if src:
                files.add(src)
    todo = list(files)
    while todo:
        f = todo.pop()
        body = open(f, errors="replace").read()
        deps = [m + ".py" for m in re.findall(r"^\s*(?:import|from)\s+(rhizo_\w+|nb_\w+)", body, re.M)] \
            if f.endswith(".py") else shell_deps(body)
        for dep in deps:
            src = find_source(dep, repo)
            if src and src not in files and os.path.basename(src) not in LAUNCHER_MODULES:
                files.add(src)
                todo.append(src)
        verbs |= launcher_verbs(body)
        if f.endswith(".py"):
            py_roots |= launcher_calls(ast.parse(body))
    funcs, tops = {}, []
    for f in files:
        if not f.endswith(".py"):
            top, fs = shell_split(open(f, errors="replace").read())
            tops.append((f, top))
            funcs.update({k: (f, v) for k, v in fs.items()})
    reached, todo = set(), [w for _f, top in tops for line in top for w in re.findall(r"[A-Za-z_][\w-]*", plain_text(line)) if w in funcs]
    while todo:
        name = todo.pop()
        if name not in reached:
            reached.add(name)
            todo += [w for line in funcs[name][1] for w in re.findall(r"[A-Za-z_][\w-]*", plain_text(line)) if w in funcs]
    shell_lines = [(f, line) for f, top in tops for line in top] + [(funcs[n][0], line) for n in reached for line in funcs[n][1]]
    for f, line in shell_lines:
        if line.strip().startswith("#"):
            continue
        for m in pat.finditer(plain_text(line)):
            if m.group(1) not in funcs:
                out.append(f"{os.path.relpath(f, repo)}: execs {m.group(1)}: {line.strip()[:80]}")
    for f in sorted(x for x in files if x.endswith(".py")):
        out += py_findings(os.path.relpath(f, repo), ast.parse(open(f).read()), names)
    if verbs or py_roots:
        trees, reach = launcher_reach(repo, verbs, py_roots)
        for mod, tree in trees.items():
            out += py_findings(f"src/androidd/{mod}", tree, names, only=reach)
    return out


def check(repo=REPO, names=None):
    """return every finding over the NoNewPrivileges units"""
    names = commands() if names is None else names
    out = []
    for path in unit_files.unit_paths(repo, (".service",)):
        if re.search(r"^NoNewPrivileges=(yes|true)$", open(path).read(), re.M):
            out += unit_findings(path, repo, names)
    return sorted(set(out))


def selftest():
    """assert each finding on a fixture tree, both ways"""
    bad = []
    with tempfile.TemporaryDirectory() as root:
        def put(rel, text):
            """write a fixture file"""
            os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
            with open(os.path.join(root, rel), "w") as f:
                f.write(text)
        for m in LAUNCHER_MODULES:
            put(f"src/androidd/{m}", "")
        put("src/androidd/boot.py", 'import os\ndef build():\n    os.system("umount -R /x")\n'
            'def unrelated():\n    os.system("mount -t tmpfs t /y")\n'
            'if sys.argv[1] == "build-it":\n    build()\n')
        put("src/install/lib.sh", "load() { modprobe x; }\n")
        put("src/install/job.sh", ". \"$(dirname \"$0\")/lib.sh\"\ndmesg() { echo shadow; }\ndmesg | tail\nload\n"
            "systemd-run --wait --unit \"u-$$\" /usr/sbin/mke2fs -q /dev/loop0\npython3 \"$PAYLOAD/launcher3.py\" build-it\n")
        put("src/services/tool.py", 'import subprocess\nsubprocess.run(["losetup", "-d", "/dev/loop0"])\n'
            'import ctypes, ctypes.util\nlibc = ctypes.CDLL(ctypes.util.find_library("c"))\n')
        put("src/services/units/a.service", "[Service]\nNoNewPrivileges=yes\nExecStart=/usr/bin/dash /usr/lib/rhizo/install/job.sh\n"
            "ExecStartPost=/bin/sh -c 'journalctl -n 1'\n")
        put("src/services/units/b.service", "[Service]\nNoNewPrivileges=yes\nExecStart=/usr/bin/python3 /usr/lib/rhizo/tool.py\n"
            "ExecStartPre=+/usr/sbin/modprobe y\n")
        put("src/services/units/c.service", "[Service]\nExecStart=/usr/bin/mount -a\n")
        got = check(root, {"modprobe", "dmesg", "mke2fs", "umount", "mount", "losetup", "journalctl", "ldconfig"})
        want = {"a.service: Exec line execs journalctl", "src/install/lib.sh: execs modprobe: modprobe x; }",
                "src/androidd/boot.py:3: shell string execs umount", "src/services/tool.py:2: argv execs losetup",
                "src/services/tool.py:4: find_library execs ldconfig"}
        for w in want - set(got):
            bad.append(f"not flagged: {w} (got {got})")
        for g in set(got) - want:
            bad.append(f"flagged wrongly: {g}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
