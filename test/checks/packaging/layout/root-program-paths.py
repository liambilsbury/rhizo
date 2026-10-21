#!/usr/bin/env python3

import ast
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SYSTEM_UNITS = "/usr/lib/systemd/system/"
MAINTAINER_SCRIPTS = lambda repo: [os.path.join(repo, "debian", "rhizo." + s)
                                   for s in ("preinst", "postinst", "prerm", "postrm.in")]

USER_DIR = re.compile(r"^(?:/run/user(?:/(?!0(?:/|$))[^/]|/?$)|/home(?:/|$))")
PAYLOAD_PATH = re.compile(r"/usr/(?:lib/rhizo/[\w.@/-]+|bin/rhizo)(?![\w./-])")
EXEC_KEY = re.compile(r"^Exec(?:Start|StartPre|StartPost|Condition|Stop|StopPost|Reload)$")
PY_READS = {"glob.glob", "glob.iglob", "os.listdir", "os.scandir", "os.walk", "os.stat", "os.lstat",
            "os.access", "os.path.exists", "os.path.lexists", "os.path.isfile", "os.path.isdir",
            "os.path.islink", "os.path.getsize", "os.path.getmtime", "open", "io.open"}
SH_USER_DIR = r"""["']?(?:/run/user/(?!0/)|/home/)"""
SH_READS = [
    re.compile(r"(?:\[\[?|\btest)\s+!?\s*-[a-zA-Z]\s+" + SH_USER_DIR),
    re.compile(r"\b(?:ls|cat|stat|find|head|tail|readlink|realpath|du|cp|mv|rm|touch|mkdir|chmod|chown)\b"
               r"[^;|&#]*?\s" + SH_USER_DIR),
    re.compile(r"\bfor\s+\w+\s+in\s+" + SH_USER_DIR),
    re.compile(r"[<>]\s*" + SH_USER_DIR),
]


def _load(name, filename):
    """return a module loaded from a file next to this check"""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def unit_texts(repo, rules_text):
    """return the unit texts debian/rules installs"""
    cpt = _load("check_package_tree", "../../lib/package-tree.py")
    out = {}
    for sources, dest in cpt.copy_commands(rules_text):
        if SYSTEM_UNITS not in dest:
            continue
        for src in sources:
            path = os.path.join(repo, src)
            if not os.path.isfile(path):
                continue
            parent = os.path.basename(os.path.dirname(dest))
            unit = parent[:-2] if dest.endswith(".conf") and parent.endswith(".d") else os.path.basename(src)
            out.setdefault(unit, []).append(open(path).read())
    return out


def directives(text):
    """return the key and value of each directive"""
    out, buf = [], ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if not buf and line.lstrip().startswith(("#", ";")):
            continue
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        line, buf = buf + line, ""
        if "=" in line and not line.lstrip().startswith("["):
            key, value = line.split("=", 1)
            out.append((key.strip(), value.strip()))
    return out


def root_exec_paths(units):
    """return the root-run payload paths"""
    out = {}
    for unit, texts in sorted(units.items()):
        pairs = [kv for t in texts for kv in directives(t)]
        user = ""
        for key, value in pairs:
            if key == "User":
                user = value
        for key, value in pairs:
            if not EXEC_KEY.match(key):
                continue
            prefix = re.match(r"^[-@:+!|]*", value).group(0)
            if user in ("", "root", "0") or "+" in prefix or "!" in prefix:
                for path in PAYLOAD_PATH.findall(value):
                    out.setdefault(path, unit)
    return out


def installed_to_repo(repo, rules_text):
    """return the installed paths mapped to their repo files"""
    cpt = _load("check_package_tree", "../../lib/package-tree.py")
    tracked = set(subprocess.run(["git", "ls-files"], cwd=repo, capture_output=True, text=True,
                                 check=True).stdout.split())
    return {"/" + pkg: rel for rel, pkg in cpt.packaged_pairs(rules_text, tracked, repo,
                                                              os.path.join(repo, "no-such-package-root"))}


def is_program(path):
    """return whether a file is a script or starts with a shebang"""
    if path.endswith((".py", ".sh")):
        return True
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


def root_programs(repo, rules_text):
    """return the root-run programs and reasons"""
    dlp = _load("check_deploy_layout_parity", "deploy-layout-parity.py")
    mods = dlp.repo_local_modules()
    to_repo = installed_to_repo(repo, rules_text)
    by_base = {}
    for installed, rel in to_repo.items():
        by_base.setdefault(os.path.basename(installed), set()).add(rel)
    todo = [(to_repo[p], "%s runs it" % u) for p, u in root_exec_paths(unit_texts(repo, rules_text)).items()
            if p in to_repo]
    todo += [(os.path.relpath(m, repo), "dpkg runs it as root")
             for m in MAINTAINER_SCRIPTS(repo) if os.path.isfile(m)]
    out = {}
    while todo:
        rel, why = todo.pop()
        path = os.path.join(repo, rel)
        if rel in out or not os.path.isfile(path) or not is_program(path):
            continue
        out[rel] = why
        text = open(path, errors="replace").read()
        if rel.endswith(".py"):
            for name in dlp.imported_closure(path, mods):
                todo.append((os.path.relpath(mods[name], repo), "%s imports it" % rel))
        for p in PAYLOAD_PATH.findall(text):
            if p in to_repo:
                todo.append((to_repo[p], "%s runs it" % rel))
        for base in re.findall(r"\$\{?\w+\}?/([\w.-]+\.(?:sh|py))\b", text):
            if len(by_base.get(base, ())) == 1:
                todo.append((next(iter(by_base[base])), "%s runs it" % rel))
    return out


def _user_dir_literal(node):
    """return whether a node is a string matching the user directory pattern"""
    return isinstance(node, ast.Constant) and isinstance(node.value, str) and bool(USER_DIR.match(node.value))


def _call_name(func):
    """return the dotted name of a called function"""
    parts = []
    while isinstance(func, ast.Attribute):
        parts.append(func.attr)
        func = func.value
    if isinstance(func, ast.Name):
        parts.append(func.id)
    return ".".join(reversed(parts))


def python_findings(rel, text):
    """return the findings for Python user-directory reads"""
    try:
        tree = ast.parse(text)
    except SyntaxError as e:
        return ["%s: does not parse: %s" % (rel, e)]
    bound = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and _user_dir_literal(node.value):
            bound |= {t.id for t in node.targets if isinstance(t, ast.Name)}
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = node.args.posonlyargs + node.args.args
            for arg, default in zip(args[len(args) - len(node.args.defaults):], node.args.defaults):
                if _user_dir_literal(default):
                    bound.add(arg.arg)
            for arg, default in zip(node.args.kwonlyargs, node.args.kw_defaults):
                if default is not None and _user_dir_literal(default):
                    bound.add(arg.arg)
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or _call_name(node.func) not in PY_READS:
            continue
        for sub in (n for a in list(node.args) + [k.value for k in node.keywords] for n in ast.walk(a)):
            if _user_dir_literal(sub) or (isinstance(sub, ast.Name) and sub.id in bound):
                out.append("%s:%d: %s() reaches %s, inside a user's own directory, as root"
                           % (rel, node.lineno, _call_name(node.func),
                              repr(sub.value) if isinstance(sub, ast.Constant) else sub.id))
                break
    return out


def shell_findings(rel, text):
    """return the findings for shell lines that read from a user directory"""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        code = line.split(" #", 1)[0]
        if code.lstrip().startswith("#"):
            continue
        if any(r.search(code) for r in SH_READS):
            out.append("%s:%d: reads inside a user's own directory as root: %s" % (rel, n, line.strip()))
    return out


def findings(repo, programs):
    """return the findings for each program in the repo"""
    out = []
    for rel in sorted(programs):
        text = open(os.path.join(repo, rel), errors="replace").read()
        if rel.endswith(".py") or text.startswith("#!/usr/bin/env python") or text.startswith("#!/usr/bin/python"):
            out += python_findings(rel, text)
        else:
            out += shell_findings(rel, text)
    return out


def check(repo=REPO):
    """return the findings and root programs"""
    rules = open(os.path.join(repo, "debian", "rules")).read()
    programs = root_programs(repo, rules)
    bad = []
    for anchor in ("src/services/api/apid.py", "src/androidd/boot.py", "src/androidd/sandbox/rootfs.py",
                   "src/install/cli/rhizo.sh", "src/install/prepare/prepare.sh"):
        if anchor not in programs:
            bad.append("%s is not among the root-run programs found" % anchor)
    return bad + findings(repo, programs), programs


def selftest():
    """run the checker against fixture inputs"""
    fails = []

    def expect(name, got, needle):
        """check the findings name the needle"""
        hit = any(needle in f for f in got)
        if needle and not hit:
            fails.append("%s: no finding naming %r in %r" % (name, needle, got))
        if not needle and got:
            fails.append("%s: flagged %r" % (name, got))

    glob_session = ('import glob, os\n'
                    'def find(run_user_root="/run/user"):\n'
                    '    return glob.glob(os.path.join(run_user_root, "*", "wayland-*"))\n')
    expect("a glob over the /run/user root bound to a parameter default",
           python_findings("a.py", glob_session), "glob.glob() reaches run_user_root")
    expect("an exists() on a literal inside a user's runtime dir",
           python_findings("a.py", 'import os\nos.path.exists("/run/user/1000/pipewire-0")\n'),
           "os.path.exists() reaches '/run/user/1000/pipewire-0'")
    expect("an open() of a home file", python_findings("a.py", 'open("/home/ubuntu/.config/x")\n'),
           "open() reaches '/home/ubuntu/.config/x'")
    expect("a module-level name bound to /home",
           python_findings("a.py", 'import os\nHOMES = "/home"\nos.listdir(HOMES)\n'), "os.listdir() reaches HOMES")
    expect("root's own runtime dir", python_findings("a.py", 'import os\nos.stat("/run/user/0/x")\n'), "")
    expect("the kernel's socket table and a message naming the path",
           python_findings("a.py", 'def f(run_user_root="/run/user"):\n'
                                   '    """lists /run/user/1000 never"""\n'
                                   '    open("/proc/net/unix").read()\n'
                                   '    print("no socket under /run/user/1000")\n'
                                   '    return run_user_root + "/1000"\n'), "")
    expect("a file test inside a user's runtime dir",
           shell_findings("a.sh", 'if [[ -S "/run/user/$uid/pipewire-0" ]]; then\n'), "a.sh:1")
    expect("an ls of every runtime dir", shell_findings("a.sh", "ls /run/user/*/wayland-*\n"), "a.sh:1")
    expect("a loop over homes", shell_findings("a.sh", "for h in /home/*; do :; done\n"), "a.sh:1")
    expect("a redirect into a home", shell_findings("a.sh", 'echo x > "/home/$u/.x"\n'), "a.sh:1")
    expect("a message, the socket table, a comment and root's own dir",
           shell_findings("a.sh", 'report pipewire ok "/run/user/$uid/pipewire-0 present"\n'
                                  'unix_socket_listening "/run/user/$uid/pipewire-0"\n'
                                  '# [[ -S /run/user/1000/x ]]\n'
                                  '[[ -d /run/user/0/x ]]\n'), "")

    units = {"a.service": ["[Service]\nExecStart=/usr/bin/python3 /usr/lib/rhizo/api/a.py\n"],
             "b.service": ["[Service]\nUser=ubuntu\nExecStart=/usr/lib/rhizo/b.sh\n"],
             "c.service": ["[Service]\nUser=ubuntu\nExecStartPre=+/usr/lib/rhizo/c.sh\n"],
             "d.service": ["[Service]\nExecStart=/root/d.sh\n",
                           "[Service]\nExecStart=\nExecStart=/bin/sh -c '/usr/bin/rhizo doctor'\n"]}
    got = root_exec_paths(units)
    for path, want in (("/usr/lib/rhizo/api/a.py", True), ("/usr/lib/rhizo/b.sh", False),
                       ("/usr/lib/rhizo/c.sh", True), ("/usr/bin/rhizo", True)):
        if (path in got) != want:
            fails.append("root_exec_paths: %s %s root-run, want %s" % (path, "is" if path in got else "is not",
                                                                       "root" if want else "not root"))

    with tempfile.TemporaryDirectory() as tmp:
        old = os.path.join(tmp, "old-apid.py")
        with open(old, "w") as f:
            f.write('import glob, os\n'
                    'def find_compositor(env=None, run_user_root="/run/user", inst_id=None):\n'
                    '    for session in sorted(glob.glob(os.path.join(run_user_root, "*"))):\n'
                    '        names = glob.glob(os.path.join(session, "wayland-*"))\n')
        expect("rhizo-apid's pre-fix session glob", findings(tmp, {"old-apid.py": "fixture"}),
               "old-apid.py:3: glob.glob() reaches run_user_root")
    real_bad, programs = check()
    expect("the real tree", real_bad, "")
    cli = open(os.path.join(REPO, "src", "install", "cli", "rhizo.sh")).read()
    reverted = cli.replace('if unix_socket_listening "/run/user/$uid/pipewire-0"; then',
                           'if [[ -S "/run/user/$uid/pipewire-0" ]]; then')
    if reverted == cli:
        fails.append("the doctor mutant changed nothing -- its anchor moved")
    expect("rhizo doctor's pre-fix [[ -S ]] on the PipeWire socket",
           shell_findings("src/install/cli/rhizo.sh", reverted), "src/install/cli/rhizo.sh:")
    return fails


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        fails = selftest()
        for f in fails:
            print("check-root-program-paths: FAIL selftest: %s" % f, file=sys.stderr)
        if fails:
            return 1
        print("check-root-program-paths selftest: a glob, exists(), open() or listdir() reaching a user's "
              "runtime dir or home through a literal, a default or a bound name, and a shell file test, ls, "
              "loop or redirect into one, each flagged; root's own /run/user/0, docstrings, messages and "
              "/proc/net/unix not; root-run discovery follows User=, the + prefix and drop-ins; rhizo-apid's "
              "old glob and rhizo doctor's old [[ -S ]] flagged; the real tree passes")
        return 0
    if sys.argv[1:]:
        print("usage: root-program-paths.py [--selftest]", file=sys.stderr)
        return 2
    bad, programs = check()
    for f in bad:
        print("check-root-program-paths: FAIL %s" % f, file=sys.stderr)
    if bad:
        return 1
    print("no program the package runs as root (%d found) reads inside a user's runtime dir or home"
          % len(programs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
