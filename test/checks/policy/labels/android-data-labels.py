#!/usr/bin/env python3
import ast
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

LABEL_CALL = "label_android_file"
SH_ANDROID = re.compile(r"\$\{?(?:INBOX_HOST_DIR|INBOX_FILE|DEVICE_DIR|LIVE_ADB_KEYS)\b|\$\{?RUN_ROOT\}?/data\b"
                        r"|/run/rhizo[^\s\"'/]*/data\b|\$\(\s*instance_run_root\b[^)]*\)/data\b")
PY_ANDROID = re.compile(r"\b(?:inbox\w*|HOST_DATA|DATA_GUEST|LOWER_ROOT|lower)\b|/run/rhizo[^\s\"'/]*/data\b"
                        r"|(?:\bRUN_ROOT\b|\brun_root\b|\{RUN_ROOT\}|\{run_root\})\s*(?:\+\s*)?[\"']?/data\b")
SH_SCAN = re.compile(r"^src/(services|launcher)/[^/]+\.sh$|^src/install/(?!tests/)[^/]+/[^/]+\.sh$|^src/services/.+/[^/]+\.sh$")
PY_SCAN = re.compile(r"^src/install/(?!tests/)[^/]+/[^/]+\.py$|^src/services/.+\.py$|^src/androidd/[^/]+\.py$")
TESTS = re.compile(r"(^|/)tests?/|(^|/)test_[^/]*$")
SH_FUNC = re.compile(r"^([A-Za-z_][\w-]*)\(\)\s*\{")
SH_ASSIGN = re.compile(r"(?:^|[\s;])(?:local\s+)?([A-Za-z_]\w*)=(\S.*)$")
SH_MKTEMP = re.compile(r"([A-Za-z_]\w*)=\$\(\s*mktemp\b([^)]*)\)")
SH_REDIRECT = re.compile(r"(?<![0-9&<>])>>?\s*(\"[^\"]*\"|'[^']*'|[^\s;|&)]+)")
SH_SEP = re.compile(r"\|\||&&|;|\|")
SH_LAST_TARGET = ("cp", "ln", "install", "mv")
SH_EACH_TARGET = ("mkdir", "touch", "mknod", "mkfifo", "tee")

DEVICE_DIR_REASON = ("the device-state directory exists while Android runs: the launcher makes it and the relabeller "
                   "labels it rhizo_device_state_file at each start, so this mkdir acts only before the first start")
EXEMPT = {
    ("src/install/cli/rhizo.sh", "set_device_state", "mkdir", "$DEVICE_DIR"): DEVICE_DIR_REASON,
    ("src/install/cli/rhizo.sh", "device_bridge_write", "mkdir", "$DEVICE_DIR"): DEVICE_DIR_REASON,
    ("src/install/cli/rhizo.sh", "cmd_device_set_camera", "mkdir", "$DEVICE_DIR"): DEVICE_DIR_REASON,
    ("src/androidd/boot.py", "prepare_host_and_data", "os.makedirs", 'f"{RUN_ROOT}/data"'):
        "makes only the mountpoint on the run-root tmpfs before data.img mounts over it: the image's root label "
        "comes from the data template or mkfs, and the first-boot restorecon (rhizo-enforcing-restorecon.rc) "
        "labels the tree after Android's policy loads",
    ("src/androidd/boot.py", "stage_selinux_contexts", "open",
     'f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-inbox.rc"'):
        "writes an init rc into system_ext_upper, not Android's data: the rule matched the file's name, and the "
        "system_ext_upper folds into system_ext_flat, which the relabeller's flat pass labels",
    ("src/install/cli/rhizo.sh", "revoke_live_adb_key", ">", "$LIVE_ADB_KEYS"):
        "rewrites the adb_keys file the function first finds with -f, in place: the inode and its label stay",
}


def tracked(root):
    """return the files git tracks under root"""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "src"], capture_output=True, text=True,
                         timeout=120, env=env)
    if out.returncode != 0:
        raise SystemExit("git ls-files failed in %s: %s" % (root, out.stderr.strip()))
    return [p for p in out.stdout.split("\0") if p]


def sh_lines(text):
    """return the joined code lines of a shell text"""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        start, line = i, lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].lstrip()
        if not line.lstrip().startswith("#"):
            out.append((start + 1, line))
        i += 1
    return out


def sh_functions(text):
    """return the numbered lines of each shell function"""
    funcs, name = {"<top>": []}, "<top>"
    for n, line in sh_lines(text):
        m = SH_FUNC.match(line)
        if m and name == "<top>":
            name = m.group(1)
            funcs[name] = [(n, line[m.end():])]
            if re.search(r";\s*\}\s*$", line):
                name = "<top>"
            continue
        if line.rstrip() == "}" and name != "<top>":
            name = "<top>"
            continue
        funcs[name].append((n, line))
    return funcs


def words(segment):
    """return the shell words of a segment"""
    try:
        return shlex.split(segment, posix=True)
    except ValueError:
        return segment.split()


def sh_refs(target, tainted):
    """return whether a shell word names Android's data"""
    if SH_ANDROID.search(target):
        return True
    return any(re.search(r"\$\{?%s\b" % re.escape(v), target) for v in tainted)


def sh_locals(lines):
    """return the names a shell function declares local"""
    names = set()
    for _, line in lines:
        for seg in SH_SEP.split(line):
            w = words(seg)
            if w and w[0] == "local":
                names.update(x.split("=")[0] for x in w[1:])
    return names


def sh_global_taint(funcs):
    """return the non-local names any shell function sets to Android's data"""
    taint, grew = set(), True
    while grew:
        grew = False
        for lines in funcs.values():
            hidden = sh_locals(lines)
            for _, line in lines:
                found = [(m.group(1), m.group(2)) for m in SH_MKTEMP.finditer(line)]
                for seg in SH_SEP.split(line):
                    a = SH_ASSIGN.search(seg)
                    if a and "mktemp" not in a.group(2):
                        found.append((a.group(1), a.group(2)))
                for name, value in found:
                    if name not in hidden | taint and sh_refs(value, taint):
                        taint.add(name)
                        grew = True
    return taint


def sh_sed_files(args):
    """return the files an in-place sed rewrites"""
    files, skip, script = [], False, False
    for x in args:
        if skip:
            skip, script = False, True
        elif x in ("-e", "-f", "--expression", "--file"):
            skip = True
        elif not x.startswith("-"):
            files.append(x)
    return files if script else files[1:]


def sh_targets(w, args, tainted):
    """return the files a shell command creates or rewrites"""
    if w[0] == "dd":
        return [x[3:] for x in args if x.startswith("of=")]
    if w[0] == "sed" and any(x == "--in-place" or re.match(r"-[a-zA-Z]*i", x) for x in w[1:] if x.startswith("-")):
        return sh_sed_files(w[1:])
    if w[0] == "mv" and any(sh_refs(x, tainted) for x in args[:-1]):
        return []
    return args[-1:] if w[0] in SH_LAST_TARGET else args if w[0] in SH_EACH_TARGET else []


def sh_findings(rel, text):
    """return the unlabeled creations in a shell text"""
    out, funcs = [], sh_functions(text)
    shared = sh_global_taint(funcs)
    for func, lines in funcs.items():
        tainted, creations, labels = shared - sh_locals(lines), [], []
        for n, line in lines:
            for m in SH_MKTEMP.finditer(line):
                if sh_refs(m.group(2), tainted):
                    tainted.add(m.group(1))
                    creations.append((n, "mktemp", "$" + m.group(1)))
            for seg in SH_SEP.split(line):
                a = SH_ASSIGN.search(seg)
                if a and "mktemp" not in a.group(2) and sh_refs(a.group(2), tainted):
                    tainted.add(a.group(1))
                for r in SH_REDIRECT.finditer(seg):
                    target = (words(r.group(1)) or [r.group(1)])[0]
                    if sh_refs(target, tainted):
                        creations.append((n, ">", target))
                w = words(SH_REDIRECT.sub(" ", seg))
                if not w:
                    continue
                if w[0] == LABEL_CALL and len(w) > 1:
                    labels.append((n, w[1]))
                    continue
                args = [x for x in w[1:] if not x.startswith("-")]
                creations += [(n, w[0], t) for t in sh_targets(w, args, tainted) if sh_refs(t, tainted)]
        for n, op, target in creations:
            if any(ln >= n and arg == target for ln, arg in labels):
                continue
            out.append((func, n, op, target))
    return out


def py_scopes(tree):
    """return each Python scope with its nodes"""
    out = []

    def walk(node, name, chain):
        """collect the nodes of a scope"""
        own = []
        stack = list(ast.iter_child_nodes(node))
        while stack:
            child = stack.pop()
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                walk(child, child.name, chain + [name])
                continue
            if isinstance(child, (ast.Lambda, ast.ClassDef)):
                stack.extend(ast.iter_child_nodes(child))
                continue
            own.append(child)
            stack.extend(ast.iter_child_nodes(child))
        out.append((name, own, chain))

    walk(tree, "<module>", [])
    return out


def call_name(call):
    """return the dotted name of a call"""
    f = call.func
    if isinstance(f, ast.Name):
        return f.id
    if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name):
        return f.value.id + "." + f.attr
    return f.attr if isinstance(f, ast.Attribute) else ""


def py_created(call, src):
    """return the path expression a call creates"""
    name = call_name(call)
    args = call.args
    if name in ("os.mkdir", "os.makedirs", "os.mknod", "os.mkfifo") and args:
        return args[0]
    if name in ("shutil.copyfile", "shutil.copy", "shutil.copy2", "os.symlink", "os.link") and len(args) > 1:
        return args[1]
    if name == "os.open" and len(args) > 1 and "O_CREAT" in (ast.get_source_segment(src, args[1]) or ""):
        return args[0]
    if name in ("open", "io.open") and args:
        mode = args[1] if len(args) > 1 else next((k.value for k in call.keywords if k.arg == "mode"), None)
        if isinstance(mode, ast.Constant) and isinstance(mode.value, str) and set(mode.value) & set("wax"):
            return args[0]
    return None


PY_JOINERS = ("os.path.join", "path.join", "posixpath.join", "Path", "PurePath", "PurePosixPath", "pathlib.Path")


def py_flat(expr):
    """return the text a path expression builds"""
    if isinstance(expr, ast.Constant):
        return str(expr.value)
    if isinstance(expr, ast.Name):
        return "{%s}" % expr.id
    if isinstance(expr, ast.Attribute):
        return "{%s}" % expr.attr
    if isinstance(expr, ast.JoinedStr):
        return "".join(py_flat(v.value) if isinstance(v, ast.FormattedValue) else py_flat(v) for v in expr.values)
    if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Add):
        return py_flat(expr.left) + py_flat(expr.right)
    if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Div):
        return py_flat(expr.left) + "/" + py_flat(expr.right)
    if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Mod):
        args = expr.right.elts if isinstance(expr.right, ast.Tuple) else [expr.right]
        fmt = py_flat(expr.left)
        for a in args:
            fmt = re.sub(r"%[sdr]", lambda m, a=a: py_flat(a), fmt, count=1)
        return fmt
    if isinstance(expr, ast.Call) and ast.unparse(expr.func) in PY_JOINERS:
        return "/".join(py_flat(a) for a in expr.args)
    return ""


def py_names_android(expr, text, assigned, scopes, seen):
    """return whether a path expression holds Android's data"""
    if PY_ANDROID.search(ast.get_source_segment(text, expr) or "") or PY_ANDROID.search(py_flat(expr)):
        return True
    for n in ast.walk(expr):
        if isinstance(n, ast.Name):
            for scope in scopes:
                for value in assigned.get((scope, n.id), []):
                    if id(value) not in seen:
                        seen.add(id(value))
                        if py_names_android(value, text, assigned, scopes, seen):
                            return True
    return False


def py_findings(rel, text):
    """return the unlabeled creations in a Python text"""
    tree, out = ast.parse(text), []
    scopes = py_scopes(tree)
    assigned = {}
    for name, nodes, _ in scopes:
        for node in nodes:
            if isinstance(node, ast.Assign):
                value = node.value
                for t in node.targets:
                    for n in ast.walk(t):
                        if isinstance(n, ast.Name):
                            assigned.setdefault((name, n.id), []).append(value)
    for name, nodes, chain in scopes:
        creations, labels, fds = [], [], {}
        for node in nodes:
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Call) and len(node.targets) == 1 \
                    and isinstance(node.targets[0], ast.Name):
                fds[id(node.value)] = node.targets[0].id
            if not isinstance(node, ast.Call):
                continue
            if call_name(node).split(".")[-1] == LABEL_CALL and node.args:
                labels.append((node.lineno, ast.get_source_segment(text, node.args[0])))
                continue
            target = py_created(node, text)
            if target is None:
                continue
            seg = ast.get_source_segment(text, target) or ""
            if py_names_android(target, text, assigned, [name] + chain[::-1] + ["<module>"], set()):
                creations.append((node.lineno, call_name(node), seg, fds.get(id(node))))
        for n, op, seg, fd in creations:
            if any(ln >= n and arg in (seg, fd) for ln, arg in labels):
                continue
            out.append((name, n, op, seg))
    return out


def check(root, files=None):
    """return the failures and the exemptions used"""
    rels = files if files is not None else [r for r in tracked(root)
                                            if (SH_SCAN.match(r) or PY_SCAN.match(r)) and not TESTS.search(r)]
    fails, used = [], set()
    for rel in sorted(rels):
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        found = py_findings(rel, text) if rel.endswith(".py") else sh_findings(rel, text)
        for func, n, op, target in found:
            key = (rel, func, op, target)
            if key in EXEMPT:
                used.add(key)
                continue
            fails.append("%s:%d: %s() creates %s with %s in Android's data and writes no label -- call %s on it "
                         "after the create"
                         % (rel, n, func, target, op, LABEL_CALL))
    return fails, used


def run():
    """check the tree for unlabeled creations"""
    fails, used = check(REPO)
    for key in sorted(set(EXEMPT) - used):
        fails.append("android-data-labels.py EXEMPT %r matches no creation -- drop the row" % (key,))
    for f in fails:
        print("FAIL", f)
    if fails:
        return 1
    print("ok")
    return 0


SH_FIXTURE = {
    "cp into the inbox, no label": ('stage() {\n  INBOX_FILE="$INBOX_HOST_DIR/x.apk"\n'
                                    '  cp -- "$src" "$INBOX_FILE" || fail\n}\n', ["$INBOX_FILE"]),
    "cp into the inbox, labeled": ('stage() {\n  cp -- "$src" "$INBOX_FILE" || fail\n'
                                    '  label_android_file "$INBOX_FILE" "$INBOX_LABEL" || fail\n}\n', []),
    "label before the cp": ('stage() {\n  label_android_file "$INBOX_FILE" "$L"\n  cp "$src" "$INBOX_FILE"\n}\n',
                            ["$INBOX_FILE"]),
    "label on another file": ('stage() {\n  cp "$src" "$INBOX_FILE"\n  label_android_file "$other" "$L"\n}\n',
                              ["$INBOX_FILE"]),
    "mktemp under the device-state dir, no label": ('w() {\n  local tmp; tmp=$(mktemp "$DEVICE_DIR/.x.XXXXXX") || die\n'
                                            '  printf x > "$tmp"\n  mv -f "$tmp" "$DEVICE_DIR/x"\n}\n',
                                            ["$tmp", "$tmp"]),
    "mktemp under the device-state dir, labeled": ('w() {\n  tmp=$(mktemp "$DEVICE_DIR/.x.XXXXXX")\n  printf x > "$tmp"\n'
                                            '  label_android_file "$tmp" "$DEVICE_STATE_LABEL"\n'
                                            '  mv -f "$tmp" "$DEVICE_DIR/x"\n}\n', []),
    "redirect into run root data": ('w() {\n  echo x > "$RUN_ROOT/data/local/tmp/f"\n}\n',
                                    ["$RUN_ROOT/data/local/tmp/f"]),
    "tainted path variable": ('w() {\n  local state="$DEVICE_DIR/device-state.conf"\n  touch "$state"\n}\n',
                              ["$state"]),
    "host-only files": ('w() {\n  tmp=$(mktemp)\n  cp a "$ETC_RHIZO/x"\n  echo x > "$tmp" 2>/dev/null\n}\n', []),
    "one-line function then a creation": ('f() { echo hi; }\ng() {\n  mkdir "$INBOX_HOST_DIR/d"\n}\n',
                                          ["$INBOX_HOST_DIR/d"]),
}
PY_FIXTURE = {
    "O_CREAT into the inbox, no label": ('def m(fd, inbox):\n    host_path = os.path.join(inbox, "a")\n'
                                         '    dst = os.open(host_path, os.O_WRONLY | os.O_CREAT, 0o644)\n',
                                         ["host_path"]),
    "O_CREAT into the inbox, label on the fd": ('def m(fd, inbox):\n    host_path = os.path.join(inbox, "a")\n'
                                                '    dst = os.open(host_path, os.O_WRONLY | os.O_CREAT, 0o644)\n'
                                                '    label_android_file(dst, INBOX_LABEL)\n', []),
    "open for reading": ('def m(inbox):\n    open(inbox + "/a").read()\n', []),
    "open for writing under HOST_DATA": ('def m():\n    with open(HOST_DATA + "x", "w") as f:\n        f.write("")\n',
                                         ['HOST_DATA + "x"']),
    "closure mkdir of lower, labeled": ('def a(share):\n    lower = share.lower\n    def do(lines):\n'
                                         '        os.mkdir(lower, 0o770)\n'
                                         '        why = label_android_file(lower, LABEL, mode)\n', []),
    "closure mkdir of lower, no label": ('def a(share):\n    lower = share.lower\n    def do(lines):\n'
                                         '        os.mkdir(lower, 0o770)\n', ["lower"]),
    "label in another function": ('def a(lower):\n    os.mkdir(lower)\n\ndef b(lower):\n'
                                  '    label_android_file(lower, L, m)\n', ["lower"]),
    "host log file": ('def s(log_path):\n    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT, 0o644)\n', []),
}


REGRESSIONS = {
    "py-join-parts": ("src/services/fx.py", 'open(os.path.join(RUN_ROOT, "data", "rhizo_inbox", "a"), "w")\n'),
    "py-percent": ("src/services/fx.py", 'open("%s/data/a" % RUN_ROOT, "w")\n'),
    "py-fstring-plus": ("src/services/fx.py", 'open(f"{RUN_ROOT}" + "/data/a", "w")\n'),
    "py-pathlib": ("src/services/fx.py", 'open(Path(RUN_ROOT) / "data" / "a", "w")\n'),
    "py-module-name-in-function": ("src/services/fx.py",
                                   'DATA = RUN_ROOT + "/data"\n\ndef g():\n    open(DATA + "/x", "w")\n'),
    "py-module-join-in-function": ("src/services/fx.py",
                                   'DATA = os.path.join(RUN_ROOT, "data")\n\ndef g():\n    open(os.path.join(DATA, "x"), "w")\n'),
    "py-run-root-plus": ("src/services/fx.py", 'open(RUN_ROOT + "/data/rhizo_inbox/a", "w")\n'),
    "py-run-root-fstring": ("src/services/fx.py", 'open(f"{run_root}/data/rhizo_inbox/a", "w")\n'),
    "py-name-plus": ("src/services/fx.py",
                     'CONTROL_DIR = RUN_ROOT + "/data/rhizo_control"\nopen(CONTROL_DIR + "/x", "w")\n'),
    "py-join": ("src/services/fx.py",
                'CONTROL_DIR = f"{RUN_ROOT}/data/rhizo_control"\nopen(os.path.join(CONTROL_DIR, "x"), "w")\n'),
    "sh-instance-run-root": ("src/install/cli/fx.sh", 'f() {\n  touch "$(instance_run_root 2)/data/x"\n}\n'),
    "sh-global-taint": ("src/install/cli/fx.sh", 'set_d() {\n  D="$RUN_ROOT/data/x"\n}\nuse_d() {\n  touch "$D/y"\n}\n'),
    "sh-mv": ("src/install/cli/fx.sh", 'f() {\n  mv /tmp/a "$RUN_ROOT/data/a"\n}\n'),
    "sh-dd": ("src/install/cli/fx.sh", 'f() {\n  dd if=/tmp/a of="$RUN_ROOT/data/a"\n}\n'),
    "sh-sed-i": ("src/install/cli/fx.sh", 'f() {\n  sed -i s/a/b/ "$RUN_ROOT/data/a"\n}\n'),
    "launcher-py": ("src/androidd/fx.py", 'def g():\n    open(RUN_ROOT + "/data/x", "w")\n'),
}


def with_label(rel, text, found):
    """return text with a label call after each finding"""
    lines = text.split("\n")
    for _, n, _, target in sorted(found, key=lambda f: -f[1]):
        indent = lines[n - 1][:len(lines[n - 1]) - len(lines[n - 1].lstrip())]
        call = "%s(%s, L)" % (LABEL_CALL, target) if rel.endswith(".py") else '%s "%s" L' % (LABEL_CALL, target)
        lines.insert(n, indent + call)
    return "\n".join(lines)


def regression_fixtures():
    """return the failures of the planted regressions and their labeled twins"""
    bad = []
    for name, (rel, text) in REGRESSIONS.items():
        if not (SH_SCAN.match(rel) or PY_SCAN.match(rel)):
            bad.append("%s: %s is outside the scanned paths" % (name, rel))
            continue
        found = py_findings(rel, text) if rel.endswith(".py") else sh_findings(rel, text)
        if not found:
            bad.append("%s: planted creation not flagged" % name)
            continue
        twin = with_label(rel, text, found)
        left = py_findings(rel, twin) if rel.endswith(".py") else sh_findings(rel, twin)
        if left:
            bad.append("%s: labeled twin still flagged: %s" % (name, left))
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, os.path.dirname(rel)))
            with open(os.path.join(root, rel), "w") as fh:
                fh.write(text)
            if not check(root, [rel])[0]:
                bad.append("%s: check() on a fake repo reports nothing" % name)
    return bad


def selftest():
    """check the scanners on fixtures"""
    bad = regression_fixtures()
    for name, (text, want) in SH_FIXTURE.items():
        got = [t for _, _, _, t in sh_findings("f.sh", text)]
        if got != want:
            bad.append("shell %s: want %s, got %s" % (name, want, got))
    for name, (text, want) in PY_FIXTURE.items():
        got = [t for _, _, _, t in py_findings("f.py", text)]
        if got != want:
            bad.append("python %s: want %s, got %s" % (name, want, got))
    for b in bad:
        print("FAIL", b)
    if bad:
        return 1
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else run())
