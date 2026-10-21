#!/usr/bin/env python3
import fnmatch
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402
import deb_unit_lists  # noqa: E402
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
REDEPLOY = os.path.join(REPO, "test", "vm", "redeploy.sh")
RULES = os.path.join(REPO, "debian", "rules")
ARCH_PAYLOAD = os.path.join(REPO, "tools", "build", "packaging", "arch", "arch-payload.sh")
PACKAGE_LIB = "/usr/lib/rhizo"
CLI = os.path.join(REPO, "src", "install", "cli", "rhizo.sh")


def sandbox_modules():
    """return the sandbox package's module paths in src/androidd"""
    return {"sandbox/" + name for name in os.listdir(os.path.join(REPO, "src", "androidd", "sandbox"))
            if re.fullmatch(r"\w+\.py", name)}


def deb_payload_modules(rules_text):
    """return the sandbox module paths the deb installs"""
    if not re.search(r"install\b.*\bsrc/androidd/sandbox/\*\.py\b.*\$\(PAYLOAD\)/sandbox/", rules_text):
        return None
    return sandbox_modules()


def redeploy_usrlib_modules(redeploy_text):
    """return the sandbox module paths redeploy.sh installs"""
    mods = set()
    for line in redeploy_text.splitlines():
        s = line.strip()
        if not s.startswith("install "):
            continue
        dest = s.split()[-1]
        if dest.rstrip("/") != "/usr/lib/rhizo/sandbox":
            continue
        if "/root/share/sandbox/*.py " in s:
            mods |= sandbox_modules()
        for tok in re.findall(r"/root/share/(sandbox/\w+\.py)", s):
            mods.add(tok)
    return mods


IMAGE_ACCOUNTS = {"root", "ubuntu", "nobody", "deskuser"}


def unit_users(launcher_text, unit_texts):
    """collect the User= account names"""
    consts = dict(re.findall(r'^\s*([A-Z][A-Z0-9_]*USER[A-Z0-9_]*)\s*=\s*"([A-Za-z0-9_.-]+)"',
                             launcher_text, re.M))
    users = set()
    for ref in re.findall(r"User=\{([A-Za-z_][A-Za-z0-9_]*)\}", launcher_text):
        if ref in consts:
            users.add(consts[ref])
    users |= set(re.findall(r'User=([A-Za-z0-9][A-Za-z0-9_.-]*)"', launcher_text))
    for text in unit_texts:
        users |= set(re.findall(r"^User=([A-Za-z0-9_.-]+)", text, re.M))
    return users - IMAGE_ACCOUNTS


def creates_account(text, name):
    """return whether the text creates an account with a name"""
    return bool(re.search(r"adduser\b[^\n]*(\n[^\n]*)?\b%s\b" % re.escape(name), text))


def deb_install_scripts(rules_text):
    """return the install script basenames in debian/rules"""
    names = set()
    for line in rules_text.replace("\\\n", " ").splitlines():
        s = line.strip()
        if not s.startswith("install ") or not s.split()[-1].startswith("$(PAYLOAD)/install"):
            continue
        names |= set(re.findall(r"src/install/([\w.-]+\.(?:sh|py))", s))
    return names


def redeploy_install_scripts(redeploy_text):
    """return the install script basenames in redeploy.sh"""
    names = set()
    for line in redeploy_text.replace("\\\n", " ").splitlines():
        s = line.strip()
        if not s.startswith("install ") or not s.split()[-1].startswith("/usr/lib/rhizo/install"):
            continue
        names |= set(re.findall(r"/root/share/([\w.-]+\.(?:sh|py))", s))
    return names


PROGRAM_DEPLOYS = (("start-deskd.sh", os.path.join("src", "services", "deskbridge", "deskd.service")),)
PROGRAM_DIR = os.path.join(REPO, "test", "vm", "start")

MODULE_DIRS = (("src", "androidd"), ("src", "services", "deskbridge"))


def repo_local_modules():
    """return the repo module names and paths"""
    mods = {}
    for parts in MODULE_DIRS:
        d = os.path.join(REPO, *parts)
        for name in sorted(os.listdir(d)):
            stem = name[:-3]
            if name.endswith(".py") and re.fullmatch(r"\w+", stem) \
                    and stem not in sys.stdlib_module_names:
                mods.setdefault(stem, os.path.join(d, name))
        pkg = os.path.join(d, "sandbox")
        for name in sorted(os.listdir(pkg)) if os.path.isdir(pkg) else ():
            if name.endswith(".py") and re.fullmatch(r"\w+", name[:-3]):
                mods.setdefault("sandbox/" + name[:-3], os.path.join(pkg, name))
    return mods


def dynamic_loads(text):
    """return basenames of spec_from_file_location paths"""
    out = set()
    for var in re.findall(r"spec_from_file_location\(\s*[^,]+,\s*([A-Za-z_]\w*)", text):
        m = re.search(r"^\s*%s\s*=\s*(.*?)(?=\n\S|\Z)" % re.escape(var), text, re.S | re.M)
        if m:
            out |= {os.path.basename(x) for x in re.findall(r'["\']([^"\']+\.py)["\']', m.group(1))}
    for lit in re.findall(r'spec_from_file_location\(\s*[^,]+,\s*["\']([^"\']+\.py)["\']', text):
        out.add(os.path.basename(lit))
    return out


def imported_closure(entry_path, mods):
    """return the transitive imports of entry_path"""
    need, seen, todo = set(), set(), [entry_path]
    while todo:
        cur = todo.pop()
        if cur in seen or not os.path.exists(cur):
            continue
        seen.add(cur)
        text = open(cur).read()
        found = re.findall(r"^\s*import\s+(\w+)", text, re.M)
        found += re.findall(r"^\s*from\s+(\w+)\s+import", text, re.M)
        for names in re.findall(r"^\s*from\s+sandbox\s+import\s+([\w ,]+)", text, re.M):
            found += ["sandbox/" + n.split()[0] for n in names.split(",") if n.strip()]
        found += ["sandbox/" + n for n in re.findall(r"^\s*(?:from|import)\s+sandbox\.(\w+)", text, re.M)]
        for name in found:
            if name in mods and name not in need:
                need.add(name)
                todo.append(mods[name])
    return need


def _scp_sources(text):
    """return the .py paths in a deploy script"""
    out = {}
    for m in re.finditer(r"(\.\.(?:/[\w.-]+)+\.py)\b", text):
        rel = m.group(1)
        out[os.path.basename(rel)] = os.path.normpath(os.path.join(PROGRAM_DIR, rel))
    return out


def _install_map(text):
    """parse the install commands in a script"""
    out = []
    for part in re.split(r"&&|\n", text.replace("\\\n", " ")):
        m = re.search(r"install\s+(?:-D\s+)?-m\s*(\d+)\s+((?:\S+\s+)+\S+)", part)
        if not m:
            continue
        mode = m.group(1)
        raw_tokens = m.group(2).split()
        tokens = []
        for t in raw_tokens:
            if '"' in t:
                tokens.append(t.split('"', 1)[0])
                break
            tokens.append(t)
        tokens = [t for t in tokens if t]
        if len(tokens) < 2:
            continue
        if len(tokens) == 2:
            out.append((mode, os.path.basename(tokens[0]), tokens[1]))
            continue
        *sources, dest_dir = tokens
        for src in sources:
            out.append((mode, os.path.basename(src), os.path.join(dest_dir, os.path.basename(src))))
    return out


def check_program_deploy(script_text, mods, unit_text=""):
    """return the failures for a deploy script"""
    search = set()
    for m in re.finditer(r"PYTHONPATH=([^\s\\]+)", script_text + "\n" + unit_text):
        search |= {d for d in m.group(1).split(":") if d.startswith("/")}
    installs = _install_map(script_text)
    sources = _scp_sources(script_text)
    programs = [(src, dest) for mode, src, dest in installs
                if mode.startswith("07") and src in sources]
    if not programs:
        return ["no python program is installed by this script -- its row in "
                "PROGRAM_DEPLOYS no longer describes it"]
    out = []
    for src, dest in programs:
        here = search | {os.path.dirname(dest)}
        have = {os.path.splitext(s)[0] for _, s, d in installs
                if os.path.dirname(d) in here}
        have |= {"sandbox/" + os.path.splitext(s)[0] for _, s, d in installs
                 if os.path.basename(os.path.dirname(d)) == "sandbox"
                 and os.path.dirname(os.path.dirname(d)) in here}
        for name in sorted(imported_closure(sources[src], mods) - have):
            out.append("%s installs %s but not %s.py, which it imports"
                       % (os.path.basename(dest), src, name))
        staged = {os.path.basename(x) for x in re.findall(r"[\w./-]+\.py", script_text)}
        for name in sorted(dynamic_loads(open(sources[src]).read()) - staged):
            out.append("%s loads %s by path (spec_from_file_location) and this "
                       "script never stages it"
                       % (os.path.basename(dest), name))
    return out


def deb_server_idle_scripts(rules_text):
    """return the server-idle script basenames in debian/rules"""
    names = set()
    for line in rules_text.replace("\\\n", " ").splitlines():
        s = line.strip()
        if not s.startswith("install ") or not s.split()[-1].startswith("$(PAYLOAD)/server-idle"):
            continue
        names |= set(re.findall(r"src/services/server-idle/([\w.-]+\.py)", s))
    return names


def redeploy_server_idle_scripts(redeploy_text):
    """return the server-idle script basenames in redeploy.sh"""
    names = set()
    for line in redeploy_text.replace("\\\n", " ").splitlines():
        s = line.strip()
        if not s.startswith("install ") or not s.split()[-1].startswith("/usr/lib/rhizo/server-idle"):
            continue
        names |= set(re.findall(r"/root/share/([\w.-]+\.py)", s))
    return names


def server_idle_unit_text(unit_texts):
    """return the rhizo-server-idle.service text"""
    for text in unit_texts:
        if "ExecStart=" in text and "server-idle.py" in text:
            return text
    return None


def check(redeploy_text, rules_text, launcher_text="", postinst_text="",
          unit_texts=()):
    """return the list of parity failures"""
    deb = deb_payload_modules(rules_text)
    if deb is None:
        return ["debian/rules no longer installs src/androidd/sandbox/*.py into $(PAYLOAD)"]
    red = redeploy_usrlib_modules(redeploy_text)
    missing = sorted(deb - red)
    out = ["redeploy.sh does not install %s into /usr/lib/rhizo/sandbox, but the deb "
           "does" % m for m in missing]
    deb_scripts = deb_install_scripts(rules_text)
    red_scripts = redeploy_install_scripts(redeploy_text)
    for name in sorted(deb_scripts - red_scripts):
        out.append("redeploy.sh does not install %s into /usr/lib/rhizo/install, "
                   "but the deb does" % name)
    deb_idle = deb_server_idle_scripts(rules_text)
    red_idle = redeploy_server_idle_scripts(redeploy_text)
    for name in sorted(deb_idle - red_idle):
        out.append("redeploy.sh does not install %s into /usr/lib/rhizo/server-idle, "
                   "but the deb does" % name)
    if deb_idle:
        idle_unit = server_idle_unit_text(unit_texts)
        if idle_unit is None:
            out.append("debian/rules installs server-idle.py, but no unit "
                       "among src/services/**/*.service execs it")
        elif "PYTHONPATH=/usr/lib/rhizo" not in idle_unit:
            out.append("rhizo-server-idle.service does not set "
                       "Environment=PYTHONPATH=/usr/lib/rhizo")
    for user in sorted(unit_users(launcher_text, unit_texts)):
        if not creates_account(postinst_text, user):
            out.append("debian/rhizo.postinst does not create account %r, but a "
                       "unit or systemd-run names it" % user)
        if not creates_account(redeploy_text, user):
            out.append("redeploy.sh does not create account %r, but a unit or "
                       "systemd-run names it" % user)
    if launcher_text and '"/usr/lib/rhizo/netbridged/netbridged.py"' not in launcher_text:
        out.append("launcher3.py no longer prefers the payload copy of "
                   "netbridged.py")
    if launcher_text and "/usr/lib/rhizo/netbridged" not in redeploy_text:
        out.append("redeploy.sh does not stage netbridged into /usr/lib/rhizo")
    mods = repo_local_modules()
    for name, unit in PROGRAM_DEPLOYS:
        path = os.path.join(PROGRAM_DIR, name)
        if not os.path.exists(path) or not os.path.exists(os.path.join(REPO, unit)):
            out.append("%s or %s is named in PROGRAM_DEPLOYS and does not exist" % (name, unit))
            continue
        unit_text = open(os.path.join(REPO, unit)).read()
        out.extend("%s: %s" % (name, m) for m in check_program_deploy(open(path).read(), mods, unit_text))
    return out


def _package_tree_module():
    """return the package tree checker module loaded from its file"""
    spec = importlib.util.spec_from_file_location("check_package_tree", os.path.join(HERE, "..", "..", "lib", "package-tree.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def deb_installed_paths(rules_text):
    """return the debian/rules install paths"""
    cpt = _package_tree_module()
    assigned = dict(re.findall(r"^([A-Z_][A-Z0-9_]*)\s*:=\s*(.*?)\s*$", rules_text, re.M))
    payload = "/" + assigned.get("PAYLOAD", "")[len(cpt.STAGE):]
    out = set()
    for sources, dest in cpt.copy_commands(rules_text):
        if not dest.startswith(cpt.STAGE):
            continue
        d = "/" + dest[len(cpt.STAGE):]
        many = dest.endswith("/") or len(sources) > 1
        out |= {d.rstrip("/") + "/" + os.path.basename(s) if many else d for s in sources}
    for line in cpt.install_recipe(rules_text):
        if "$$" in line or ">" in line:
            out |= {payload + "/" + rel.rstrip("/") for rel in re.findall(r"\$\(PAYLOAD\)/([\w.*/-]+)", line)}
    return out


def arch_payload_paths(script_text):
    """return the arch-payload.sh /usr/lib/rhizo paths"""
    m = re.search(r'^\s*inst="\$stage(/usr/lib/rhizo[\w./-]*)"', script_text, re.M)
    if not m:
        return set()
    out = {m.group(1) + "/" + name for name in re.findall(r'"\$inst/([\w.-]+)"', script_text)}
    if re.search(r'deb_unit_lists\.py" "\$out/control/postinst" "\$inst"', script_text):
        out |= {m.group(1) + "/" + os.path.basename(p) for p in deb_unit_lists.LIST_PATHS.values()}
    return out


def _is_shipped(path, installed):
    """return whether a path is shipped"""
    return any(fnmatch.fnmatchcase(path, p) or path.startswith(p + "/") or p.startswith(path + "/") for p in installed)


def shipped_texts(rules_text):
    """return path and text pairs for payload files"""
    cpt = _package_tree_module()
    tracked = set(subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True,
                                 text=True, check=True).stdout.split())
    out = []
    for rel, pkg in cpt.packaged_pairs(rules_text, tracked, REPO, os.path.join(REPO, "no-such-package-root")):
        path = os.path.join(REPO, rel)
        with open(path, "rb") as f:
            head = f.read(2)
        if head != b"#!" and not rel.endswith((".sh", ".py", ".service", ".path", ".socket", ".timer", ".conf")):
            continue
        with open(path, errors="replace") as f:
            out.append(("/" + pkg, f.read()))
    return out


_SELF_DIR = re.compile(r'^\$\(.*\bdirname\b.*\$(?:0\b|\{BASH_SOURCE\[0\]\})')
_SELF_REF = re.compile(r'\$\(dirname\s+(?:--\s+)?"?\$(?:0|\{BASH_SOURCE\[0\]\})"?\)/([\w.-]+(?:/[\w.-]+)*\.(?:sh|py))(?![\w.$/{-])')
_VAR_REF = re.compile(r'\$\{?([A-Za-z_]\w*)\}?/([\w.-]+(?:/[\w.-]+)*\.(?:sh|py))(?![\w.$/{-])')
_LIT_REF = re.compile(r'(?<![\w.$/-])(/usr/lib/rhizo/[\w.-]+(?:/[\w.-]+)*)(?![\w$/{*-])')
_BESIDE_REF = re.compile(r'\bbeside\(\s*["\']([\w.-]+\.(?:sh|py))["\']\s*\)')


def _eval_dir(val, script_dir, dirs):
    """return the directories a script variable value can name"""
    v = val.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    if _SELF_DIR.search(v):
        return {script_dir}
    m = re.fullmatch(r"\$\{\w+:-(/[\w./-]*)\}", v)
    if m:
        return {m.group(1)}
    m = re.fullmatch(r"\$\{?([A-Za-z_]\w*)\}?(/[\w./-]*)?", v)
    if m:
        return {os.path.normpath(d + (m.group(2) or "")) for d in dirs.get(m.group(1), ())}
    if re.fullmatch(r"/[\w./-]*", v):
        return {os.path.normpath(v)}
    return set()


def _flag_dirs(text, basename, all_texts):
    """map script variables to directory arguments"""
    out = {}
    for flag, var in re.findall(r"--([\w-]+)\)\s*([A-Za-z_]\w*)=\"?\$\{?2", text):
        for _, other in all_texts:
            for line in other.splitlines():
                if basename in line:
                    for d in re.findall(r"--%s[= ]\"?(/[\w./-]+)" % re.escape(flag), line):
                        out.setdefault(var, set()).add(os.path.normpath(d))
    return out


def script_payload_refs(installed_path, text, all_texts):
    """map basenames to candidate payload paths"""
    script_dir = os.path.dirname(installed_path)
    refs = {}

    def add(path):
        """record a referenced path by its base name"""
        refs.setdefault(os.path.basename(path), set()).add(os.path.normpath(path))

    live = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    for lit in _LIT_REF.findall(live):
        add(lit.rstrip("."))
    for name in _BESIDE_REF.findall(live):
        add(PACKAGE_LIB + "/" + name)
    if not installed_path.endswith((".py", ".service", ".path", ".socket", ".timer", ".conf")):
        dirs = _flag_dirs(text, os.path.basename(installed_path), all_texts)
        assigns = re.findall(r"^\s*(?:local\s+|readonly\s+|export\s+)?([A-Za-z_]\w*)=(\S.*?)\s*$", live, re.M)
        for _ in range(3):
            for var, val in assigns:
                dirs.setdefault(var, set()).update(_eval_dir(val, script_dir, dirs))
        for rel in _SELF_REF.findall(live):
            add(script_dir + "/" + rel)
        for var, rel in _VAR_REF.findall(live):
            for d in dirs.get(var, ()):
                add(d + "/" + rel)
    return refs


def payload_reference_gaps(installed, texts):
    """return the named paths missing from debian/rules"""
    out = []
    for path, text in texts:
        for name, cands in sorted(script_payload_refs(path, text, texts).items()):
            pkg = sorted(c for c in cands if c.startswith(PACKAGE_LIB + "/"))
            if pkg and not any(_is_shipped(c, installed) for c in pkg):
                out.append("%s names %s, which debian/rules never ships" % (path, " or ".join(pkg)))
    return out


_ROOT_ONLY = re.compile(r"^\s*(?:local\s+|readonly\s+|export\s+)?([A-Za-z_]\w*)=([\"']?)(/root/share/[\w./-]+)\2\s*$")


def rig_only_paths(texts):
    """return the assignments to /root/share paths"""
    out = []
    for path, text in texts:
        if path.endswith((".py", ".service", ".path", ".socket", ".timer", ".conf")):
            continue
        for line in text.splitlines():
            m = _ROOT_ONLY.match(line)
            if m:
                out.append("%s sets %s=%s, a path only the rig stages" % (path, m.group(1), m.group(3)))
    return out


def renamed_payload_scripts(rules_text):
    """return payload names installed from a script source"""
    return set(re.findall(r"(?m)^\s*install\b[^\n]*\s\S+/[\w-]+\.(?:py|sh)\s+\$\(PAYLOAD\)/([\w-]+)\s*$", rules_text))


def cli_payload_gaps(cli_text, redeploy_text, installed, rules_text):
    """return the CLI payload files redeploy.sh never installs"""
    out = []
    names = set(re.findall(r"\$LIB_DIR/([\w.-]+\.(?:sh|py))\b", cli_text))
    run_direct = set(re.findall(r"\$LIB_DIR/([\w-]+)(?![\w./-])", cli_text)) & renamed_payload_scripts(rules_text)
    names |= run_direct
    for name in sorted(names):
        if PACKAGE_LIB + "/" + name not in installed:
            continue
        if name.endswith((".sh", ".py")):
            pat = r"^\s*install\b[^\n]*/root/share/%s\s[^\n]*/usr/lib/rhizo/?(?:%s)?\s*$" % (re.escape(name), re.escape(name))
        else:
            pat = r"^\s*install\b[^\n]*/root/share/%s\.(?:py|sh)\s[^\n]*/usr/lib/rhizo/%s\s*$" % (re.escape(name), re.escape(name))
        line = re.search(pat, redeploy_text, re.M)
        if not line:
            out.append("rhizo.sh reads $LIB_DIR/%s, which the deb installs at %s/%s, but redeploy.sh "
                       "never installs it there"
                       % (name, PACKAGE_LIB, name))
        elif name in run_direct and not re.search(r"\s-m\s+0?755\s", line.group(0)):
            out.append("rhizo.sh runs $LIB_DIR/%s directly, and redeploy.sh installs it at %s/%s without "
                       "-m 0755 (%s)"
                       % (name, PACKAGE_LIB, name, line.group(0).strip()))
    return out


def load_inputs():
    """read the check input files"""
    with open(REDEPLOY) as f:
        redeploy_text = f.read()
    with open(RULES) as f:
        rules_text = f.read()
    with open(os.path.join(REPO, "src", "androidd", "boot.py")) as f:
        launcher_text = f.read()
    postinst_text = maint_inline.inlined(os.path.join(REPO, "debian", "rhizo.postinst"))
    unit_texts = []
    for path in unit_files.unit_paths(REPO, (".service",)):
        with open(path) as f:
            unit_texts.append(f.read())
    return redeploy_text, rules_text, launcher_text, postinst_text, unit_texts


def selftest():
    """run the parity checks on altered inputs"""
    redeploy_text, rules_text, launcher_text, postinst_text, unit_texts = load_inputs()

    fail = 0
    if check(redeploy_text, rules_text, launcher_text, postinst_text, unit_texts):
        print("check-deploy-layout-parity selftest: FAILED -- the real tree does not pass")
        fail = 1

    fake_launcher = launcher_text + '\n_x = ["-p", "User=rhizo-testdaemon"]\n'
    got = check(redeploy_text, rules_text, fake_launcher, postinst_text, unit_texts)
    if len([m for m in got if "rhizo-testdaemon" in m]) != 2:
        print("check-deploy-layout-parity selftest: FAILED -- an account no path "
              "creates was not flagged on both paths: %r" % got)
        fail = 1
    fake_launcher = launcher_text + '\n_x = ["-p", "User=root"]\n'
    if check(redeploy_text, rules_text, fake_launcher, postinst_text, unit_texts):
        print("check-deploy-layout-parity selftest: FAILED -- an image-native "
              "account was flagged")
        fail = 1
    no_create = re.sub(r"adduser", "addnope", redeploy_text)
    got = check(no_create, rules_text, launcher_text, postinst_text, unit_texts)
    if not any("redeploy.sh does not create account" in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- removing redeploy's "
              "account creation was not caught")
        fail = 1
    no_payload = launcher_text.replace("/usr/lib/rhizo/netbridged/netbridged.py", "/root/nope.py")
    got = check(redeploy_text, rules_text, no_payload, postinst_text, unit_texts)
    if not any("no longer prefers the payload copy" in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a launcher without "
              "the payload-first candidate was not caught")
        fail = 1
    no_stage = redeploy_text.replace("/usr/lib/rhizo/netbridged", "/usr/lib/NOPE/netbridged")
    got = check(no_stage, rules_text, launcher_text, postinst_text, unit_texts)
    if not any("does not stage netbridged" in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy that "
              "stops staging netbridged into the payload was not caught")
        fail = 1

    with open(CLI) as f:
        cli_text = f.read()
    installed = deb_installed_paths(rules_text)
    if cli_payload_gaps(cli_text, redeploy_text, installed, rules_text):
        print("check-deploy-layout-parity selftest: FAILED -- the real tree leaves a CLI payload file uninstalled: %r"
              % cli_payload_gaps(cli_text, redeploy_text, installed, rules_text))
        fail = 1
    no_probe = re.sub(r"(?m)^install -m 0755 /root/share/probe-client\.py /usr/lib/rhizo/probe-client\.py\n", "", redeploy_text)
    got = cli_payload_gaps(cli_text, no_probe, installed, rules_text)
    if no_probe == redeploy_text or not any("probe-client.py" in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy that stops installing a payload file "
              "the CLI reads by $LIB_DIR was not caught: %r" % got)
        fail = 1
    no_mode = re.sub(r"(?m)^install -m 0755 /root/share/rhizo-selinux-mode\.py /usr/lib/rhizo/rhizo-selinux-mode\n", "", redeploy_text)
    got = cli_payload_gaps(cli_text, no_mode, installed, rules_text)
    if no_mode == redeploy_text or not any("$LIB_DIR/rhizo-selinux-mode," in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy that stops installing the mode helper the deb "
              "installs from a .py source under its bare name was not caught: %r" % got)
        fail = 1
    no_exec = redeploy_text.replace("install -m 0755 /root/share/rhizo-selinux-mode.py /usr/lib/rhizo/rhizo-selinux-mode\n",
                                    "install -m 0644 /root/share/rhizo-selinux-mode.py /usr/lib/rhizo/rhizo-selinux-mode\n", 1)
    got = cli_payload_gaps(cli_text, no_exec, installed, rules_text)
    if no_exec == redeploy_text or not any("without -m 0755" in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy that installs the mode helper 0644, which the "
              "CLI and units run directly, was not caught: %r" % got)
        fail = 1
    to_dir = no_mode.replace("install -m 0755 /root/share/probe-client.py /usr/lib/rhizo/probe-client.py\n",
                             "install -m 0755 /root/share/probe-client.py /usr/lib/rhizo/probe-client.py\n"
                             "install -m 0755 /root/share/rhizo-selinux-mode.py /usr/lib/rhizo/\n", 1)
    got = cli_payload_gaps(cli_text, to_dir, installed, rules_text)
    if to_dir == no_mode or not any("$LIB_DIR/rhizo-selinux-mode," in m for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy that installs the mode helper under its .py "
              "name, which the CLI never runs, was not caught: %r" % got)
        fail = 1

    deb = deb_payload_modules(rules_text)
    victim = "sandbox/*.py"
    broken = redeploy_text.replace("/root/share/%s " % victim, "/root/share/sandbox/core.py ")
    if broken == redeploy_text:
        print("check-deploy-layout-parity selftest: FAILED -- could not remove %s to test" % victim)
        fail = 1
    elif not check(broken, rules_text, launcher_text, postinst_text, unit_texts):
        print("check-deploy-layout-parity selftest: FAILED -- dropping %s from "
              "redeploy's /usr/lib/rhizo install was not caught" % victim)
        fail = 1

    no_idle_stage = re.sub(r"/root/share/server-idle\.py ", "", redeploy_text)
    if no_idle_stage == redeploy_text:
        print("check-deploy-layout-parity selftest: FAILED -- could not remove "
              "server-idle.py's own redeploy line to test")
        fail = 1
    else:
        got = check(no_idle_stage, rules_text, launcher_text, postinst_text, unit_texts)
        if not any("into /usr/lib/rhizo/server-idle" in m for m in got):
            print("check-deploy-layout-parity selftest: FAILED -- dropping "
                  "server-idle.py from redeploy's server-idle install was "
                  "not caught: %r" % got)
            fail = 1

    unit_list = list(unit_texts)
    idle_idx = next((i for i, t in enumerate(unit_list)
                     if "ExecStart=" in t and "server-idle.py" in t), None)
    if idle_idx is None:
        print("check-deploy-layout-parity selftest: FAILED -- no unit among "
              "src/services/**/*.service execs server-idle.py to test against")
        fail = 1
    else:
        broken_units = list(unit_list)
        broken_units[idle_idx] = broken_units[idle_idx].replace(
            "Environment=PYTHONPATH=/usr/lib/rhizo", "")
        got = check(redeploy_text, rules_text, launcher_text, postinst_text, broken_units)
        if not any("does not set" in m and "PYTHONPATH" in m for m in got):
            print("check-deploy-layout-parity selftest: FAILED -- a "
                  "rhizo-server-idle.service missing PYTHONPATH was not caught: %r" % got)
            fail = 1

    none_text = redeploy_text.replace("/usr/lib/rhizo/", "/usr/lib/NOPE/")
    if len(check(none_text, rules_text, launcher_text, postinst_text, unit_texts)) < len(deb):
        print("check-deploy-layout-parity selftest: FAILED -- a redeploy with no "
              "/usr/lib/rhizo install did not flag every module")
        fail = 1

    mods = repo_local_modules()
    deskd = open(os.path.join(REPO, "test", "vm", "start", "start-deskd.sh")).read()
    unit = open(os.path.join(REPO, PROGRAM_DEPLOYS[0][1])).read()
    got = check_program_deploy(deskd, mods, unit)
    if got:
        print("check-deploy-layout-parity selftest: FAILED -- start-deskd.sh does "
              "not install what rhizo-deskd imports: %r" % got)
        fail = 1
    for victim in sorted(imported_closure(os.path.join(REPO, "src", "services", "deskbridge", "deskd.py"), mods)):
        broken = re.sub(r"&&\s*install (?:-D )?-m 0644 \S*%s\.py \S+" % re.escape(victim), "", deskd)
        if broken == deskd:
            print("check-deploy-layout-parity selftest: FAILED -- could not remove "
                  "%s's install to test it" % victim)
            fail = 1
        elif not any(victim in msg for msg in check_program_deploy(broken, mods, unit)):
            print("check-deploy-layout-parity selftest: FAILED -- dropping %s from "
                  "start-deskd.sh's install was not caught" % victim)
            fail = 1
    unit_broken = unit.replace("PYTHONPATH=/usr/lib/rhizo", "PYTHONPATH=/nowhere")
    if unit_broken == unit:
        print("check-deploy-layout-parity selftest: FAILED -- could not find "
              "deskd.service's own PYTHONPATH=/usr/lib/rhizo to test")
        fail = 1
    elif check_program_deploy(deskd, mods, unit_broken):
        print("check-deploy-layout-parity selftest: FAILED -- breaking only the "
              "unit's PYTHONPATH (the co-located copies still resolve every "
              "import) was wrongly flagged")
        fail = 1
    colocated_broken = deskd.replace("/usr/lib/rhizo/deskbridge/dbus_min.py",
                                     "/usr/lib/rhizo/deskbridge-nowhere/dbus_min.py")
    if colocated_broken == deskd:
        print("check-deploy-layout-parity selftest: FAILED -- could not find "
              "dbus_min.py's own co-located install to test")
        fail = 1
    elif check_program_deploy(colocated_broken, mods, unit):
        print("check-deploy-layout-parity selftest: FAILED -- breaking only the "
              "co-located copy (the unit's PYTHONPATH still resolves it) was "
              "wrongly flagged")
        fail = 1
    if colocated_broken == deskd or not any("dbus_min" in m for m in check_program_deploy(colocated_broken, mods, unit_broken)):
        print("check-deploy-layout-parity selftest: FAILED -- breaking BOTH of "
              "dbus_min.py's resolution paths at once was not caught: %r"
              % check_program_deploy(colocated_broken, mods, unit_broken))
        fail = 1
    novel = re.sub(r"install -m 0755 /root/[\w.-]+\.py \S+\.py( && )?", "", deskd)
    if novel == deskd or not check_program_deploy(novel, mods, unit):
        print("check-deploy-layout-parity selftest: FAILED -- a script that "
              "installs no program passed vacuously")
        fail = 1

    multi = _install_map("install -m 0644 /root/a.py /root/b.py /usr/local/lib/rhizo/")
    if multi != [("0644", "a.py", "/usr/local/lib/rhizo/a.py"),
                 ("0644", "b.py", "/usr/local/lib/rhizo/b.py")]:
        print("check-deploy-layout-parity selftest: FAILED -- a multi-source "
              "install line was not split one destination per source: %r" % multi)
        fail = 1

    with open(ARCH_PAYLOAD) as f:
        arch_text = f.read()
    installed = deb_installed_paths(rules_text) | arch_payload_paths(arch_text)
    texts = shipped_texts(rules_text)
    got = payload_reference_gaps(installed, texts)
    if got:
        print("check-deploy-layout-parity selftest: FAILED -- the real package "
              "names paths it does not ship: %r" % got)
        fail = 1
    no_list = arch_text.replace('"$out/control/postinst" "$inst"', '"$out/control/postinst" "$out"')
    got = payload_reference_gaps(deb_installed_paths(rules_text) | arch_payload_paths(no_list), texts)
    if no_list == arch_text or not any(
            m.startswith("/usr/lib/rhizo/install/lib/pkg-lib.sh names /usr/lib/rhizo/install/units.start,")
            for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a pacman payload that writes its unit lists "
              "outside the tree was not caught at the library that reads them: %r" % got)
        fail = 1
    unshipped = rules_text.replace(" src/install/prepare/detect-gpu-driver.sh $(PAYLOAD)/", " $(PAYLOAD)/")
    got = payload_reference_gaps(deb_installed_paths(unshipped), texts)
    if unshipped == rules_text or not any(
            m.startswith("/usr/lib/rhizo/install/prepare/prepare.sh names /usr/lib/rhizo/detect-gpu-driver.sh")
            for m in got):
        print("check-deploy-layout-parity selftest: FAILED -- a deb that stops "
              "shipping detect-gpu-driver.sh was not caught at prepare's "
              "--payload /usr/lib/rhizo: %r" % got)
        fail = 1
    fixture = (
        "#!/bin/sh\n"
        'HERE=$(cd "$(dirname "$0")" && pwd)\n'
        "LIB=\"${RHIZO_LIB:-/usr/lib/rhizo}\"\n"
        'for f in /root/x-only.sh "$HERE/../data-template.sh" "$HERE/data-template.sh"; do :; done\n'
        '. "$LIB/tools/$name-dyn.sh"\n'
        '. "$(dirname "$0")/absent-beside.sh"\n'
        '"$LIB/absent-flat.py"\n'
        "# $LIB/absent-in-a-comment.sh\n")
    got = payload_reference_gaps(installed, [("/usr/lib/rhizo/tools/fixture.sh", fixture)])
    want = {"/usr/lib/rhizo/tools/absent-beside.sh", "/usr/lib/rhizo/absent-flat.py"}
    named = {w for w in want for m in got if (" names %s," % w) in m}
    if named != want or len(got) != len(want):
        print("check-deploy-layout-parity selftest: FAILED -- the fixture should "
              "flag exactly %s, got %r" % (sorted(want), got))
        fail = 1

    got = rig_only_paths(texts)
    if got:
        print("check-deploy-layout-parity selftest: FAILED -- the real package sets rig-only paths: %r" % got)
        fail = 1
    rig = "#!/bin/sh\nPROBE_CLIENT=/root/share/rhizo-probe-client\nfor x in /root/a \"$(dirname \"$0\")/a\"; do :; done\n"
    got = rig_only_paths([("/usr/lib/rhizo/fixture.sh", rig)])
    if len(got) != 1 or "PROBE_CLIENT=/root/share/rhizo-probe-client" not in got[0]:
        print("check-deploy-layout-parity selftest: FAILED -- a variable set to a /root path alone should be "
              "flagged once, and a candidate list never: %r" % got)
        fail = 1

    if fail:
        return 1
    print("check-deploy-layout-parity selftest: ok "
          "(the real tree mirrors the deb; a dropped module, a missing install "
          "dir, an uncreated service account, a program deployed without its "
          "own imports, a server-idle staging/PYTHONPATH gap, a payload "
          "path a shipped script names but no package ships, and a CLI-run payload script "
          "installed under another name or not executable are all caught)")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    redeploy_text, rules_text, launcher_text, postinst_text, unit_texts = load_inputs()
    fails = check(redeploy_text, rules_text, launcher_text, postinst_text, unit_texts)
    texts = shipped_texts(rules_text)
    with open(ARCH_PAYLOAD) as f:
        arch_paths = arch_payload_paths(f.read())
    fails += payload_reference_gaps(deb_installed_paths(rules_text) | arch_paths, texts)
    fails += rig_only_paths(texts)
    with open(CLI) as f:
        fails += cli_payload_gaps(f.read(), redeploy_text, deb_installed_paths(rules_text), rules_text)
    for m in fails:
        print("check-deploy-layout-parity: " + m, file=sys.stderr)
    if fails:
        return 1
    print("check-deploy-layout-parity: redeploy.sh mirrors the deb's payload modules "
          "and service accounts; every deployed program's imports ship with it; "
          "every /usr/lib/rhizo path a shipped file names is shipped, none sets a variable to a /root/share path alone, "
          "and every payload file the CLI reads by $LIB_DIR is installed there, executable where the CLI runs it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
