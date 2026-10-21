#!/usr/bin/env python3

import io
import os
import re
import shlex
import subprocess
import sys
import tempfile
import tokenize

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
ALLOW = os.path.join(HERE, "..", "..", "data", "host-copy-ops-allow.tsv")

ARCH_FILES = "archlinux/files/"

ANDROID_OR_TEST = re.compile(r"^(src/android/hal/|src/android/apps/|src/androidd/guest/)|/tests?/|(^|/)test_[^/]*$")
EXCLUDE = re.compile(ANDROID_OR_TEST.pattern +
                     r"|\.(md|txt|tsv|json|xml|rules|desktop|png|svg|c|cpp|h|java|mk|bp)$")
SCRIPT_EXT = (".sh", ".py", ".service", ".path", ".socket")
CONFIG_EXT = (".conf", ".rules")
MAINTAINER_SCRIPTS = ("debian/rhizo.preinst", "debian/rhizo.postinst",
                      "debian/rhizo.prerm", "debian/rhizo.postrm.in")
DEBIAN_RULES = "debian/rules"
DROPINS = "debian/dropins/"
ANCHORS = ("src/install/prepare/fetch-gsi.sh", "src/install/cli/rhizo.sh",
           "src/androidd/boot.py", "src/services/appsync/appsync.py",
           "src/services/units/boot/update-begin.service",
           "debian/dropins/androidd-packaged-paths.conf", "src/services/udev/70-uinput.rules")
MIN_REASON = 20
SEP = re.compile(r"&&|\|\||[;|`]|\$\(")
CMD = re.compile(r"(?:^|[\s(\[,]|=[-@:+!]*)(?:[rRbBfFuU]{1,2}(?=[\"']))?[\"']?\\?(?:/[\w.+-]+)*/?"
                 r"(cp|rsync|tar|setfattr|setfacl|chcon)[\"']?(?=[\s,\"']|$)")
PY_OPS = re.compile(r"\bshutil\.(copy2|copytree|copystat|move)\(|\bdir_util\.copy_tree\("
                    r"|\bos\.l?(setxattr|removexattr)\(|(?<!def )\blabel_before_policy\(")
UDEV_EXEC = re.compile(r"\b(?:RUN(?:\{[^}]*\})?|PROGRAM|IMPORT\{program\})\s*\+?=\s*\"([^\"]*)\"")


def git_env():
    """filter GIT variables out of the environment"""
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def is_script(root, rel):
    """return whether a file is a script by extension or shebang"""
    if EXCLUDE.search(rel):
        return False
    if rel.endswith(SCRIPT_EXT):
        return True
    if "." in os.path.basename(rel):
        return False
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            head = fh.readline(200)
    except OSError:
        return False
    return head.startswith(b"#!") and (b"sh" in head or b"python" in head)


def is_config(rel):
    """return whether a file is a configuration file"""
    return rel.endswith(CONFIG_EXT) and not ANDROID_OR_TEST.search(rel)


def packaged_configs(root, tracked):
    """return the packaged config files"""
    try:
        with open(os.path.join(root, DEBIAN_RULES), encoding="utf-8") as fh:
            named = set(re.findall(r"[\w./@+-]+", fh.read()))
    except OSError:
        named = set()
    return {rel for rel in tracked
            if rel.startswith(DROPINS)
            or (rel in named and (is_config(rel) or rel.startswith("debian/apt.conf.d/")))}


def glob_to_re(pattern):
    """convert a glob pattern to a regex"""
    parts, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern.startswith("**", i):
                parts.append(".*")
                i += 2
                continue
            parts.append("[^/]*")
        elif c == "?":
            parts.append("[^/]")
        else:
            parts.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(parts) + "$")


def tracked_files(root):
    """return the files git tracks under a root"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, text=True,
                         timeout=120, env=git_env())
    if out.returncode != 0:
        raise SystemExit(f"git ls-files failed in {root}: {out.stderr.strip()}")
    return [p for p in out.stdout.split("\0") if p]


def installed_sources(root, tracked):
    """return the tracked files debian/rules installs"""
    with open(os.path.join(root, DEBIAN_RULES), encoding="utf-8") as fh:
        text = fh.read().replace("\\\n", " ")
    named = set()
    for line in text.split("\n"):
        words = line.split()
        if not words or words[0] not in ("install", "cp"):
            continue
        named.update(w.strip('"') for w in words[1:]
                     if "/" in w and not w.startswith("-") and "$(" not in w)
    globs = [glob_to_re(n) for n in named if re.search(r"[*?]", n)]
    plain = tuple(n for n in named if not re.search(r"[*?]", n))
    return {rel for rel in tracked
            if rel.startswith(ARCH_FILES) or rel in plain
            or any(rel.startswith(n.rstrip("/") + "/") for n in plain)
            or any(rx.match(rel) for rx in globs)}


def scan_set(root):
    """return the shipped scripts and configuration files to scan"""
    tracked = tracked_files(root)
    shipped = installed_sources(root, tracked)
    configs = packaged_configs(root, tracked)
    return sorted(rel for rel in tracked
                  if (rel in shipped and (is_script(root, rel) or is_config(rel)))
                  or rel in MAINTAINER_SCRIPTS or rel in configs)


def udev_commands(text):
    """reduce a .rules file to its command lines"""
    lines, out, i = text.split("\n"), [], 0
    while i < len(lines):
        start, line = i, lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + lines[i]
        cmds = [] if line.lstrip().startswith("#") else [m.group(1) for m in UDEV_EXEC.finditer(line)]
        out.append(" ; ".join(cmds))
        out.extend([""] * (i - start))
        i += 1
    return "\n".join(out)


def words(segment):
    """return the words of a shell segment with quotes and brackets stripped"""
    try:
        toks = shlex.split(segment, comments=False, posix=True)
    except ValueError:
        toks = segment.split()
    return [t.strip("\"',[]()") for t in toks]


TAR_META = ("--xattrs", "--selinux", "--acls", "--preserve-permissions",
            "--same-permissions", "--same-owner", "--preserve")
TAR_OLD_STYLE = re.compile(r"[AbBcCdfFgGhHiIjJkKlLmMnNoOpPrRsStTuUvVwWxXzZ]+")
TAR_FUNCTIONS = set("Acdrtux")


def tar_flag(args):
    """return the metadata option of a tar command"""
    extract, to_stdout, no_owner, no_perms = None, False, False, False
    for i, a in enumerate(args):
        if a in TAR_META or a.startswith("--xattrs-"):
            return a
        letters = None
        if re.fullmatch(r"-[A-Za-z]+", a):
            letters = a[1:]
        elif i == 0 and TAR_OLD_STYLE.fullmatch(a) and len(set(a) & TAR_FUNCTIONS) == 1:
            letters = a
        if letters:
            if "p" in letters:
                return a
            if "x" in letters and extract is None:
                extract = a
            to_stdout = to_stdout or "O" in letters
        elif a in ("--extract", "--get") and extract is None:
            extract = a
        elif a == "--to-stdout" or a.startswith("--to-command"):
            to_stdout = True
        elif a == "--no-same-owner":
            no_owner = True
        elif a == "--no-same-permissions":
            no_perms = True
    if extract and not to_stdout and not (no_owner and no_perms):
        return extract
    return None


def flag_of(cmd, args):
    """return the metadata option of a command"""
    if cmd == "tar":
        return tar_flag(args)
    for a in args:
        if a.startswith("--no-preserve"):
            continue
        if cmd == "cp":
            if a in ("--archive", "--preserve") or a.startswith("--preserve="):
                return a
            if re.fullmatch(r"-[A-Za-z]*[ap][A-Za-z]*", a):
                return a
        elif cmd == "rsync":
            if a in ("--archive", "--xattrs", "--acls", "--perms", "--owner", "--group"):
                return a
            if re.fullmatch(r"-[A-Za-z]*[aXAopg][A-Za-z]*", a):
                return a
    return None


def ops_on_line(line):
    """return the forbidden ops in a line"""
    found = [m.group(0).rstrip("(") for m in PY_OPS.finditer(line)]
    for seg in SEP.split(line):
        m = CMD.search(seg)
        if not m:
            continue
        cmd = m.group(1)
        if cmd in ("setfattr", "setfacl", "chcon"):
            found.append(cmd)
            continue
        flag = flag_of(cmd, words(seg[m.end():]))
        if flag:
            found.append(f"{cmd} {flag}")
    return found


def is_comment(line):
    """return whether a line is a comment"""
    s = line.lstrip()
    return s.startswith("#") or s.startswith(";")


def read_allow(path):
    """parse the allowlist file"""
    rows, fails = [], []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            f = line.split("\t")
            if len(f) not in (4, 5) or not all(x.strip() for x in f):
                fails.append(f"{os.path.basename(path)}:{n}: want 4 or 5 tab-separated fields "
                             f"(path, op, match, reason[, guard]), got {len(f)}")
                continue
            if len(f[3].strip()) < MIN_REASON:
                fails.append(f"{os.path.basename(path)}:{n}: '{f[3]}' is no reason -- say why "
                             f"{f[1]} is safe where it runs")
                continue
            rows.append((n, f[0], f[1], f[2], f[3], f[4] if len(f) == 5 else ""))
    return rows, fails


def py_open_breaks(lines):
    """return the rows inside open brackets"""
    depth, open_after, blanked = 0, {}, list(lines)
    try:
        for tok in tokenize.generate_tokens(io.StringIO("\n".join(lines) + "\n").readline):
            row = tok.start[0] - 1
            if tok.type == tokenize.OP and tok.string in "([{":
                depth += 1
            elif tok.type == tokenize.OP and tok.string in ")]}":
                depth = max(0, depth - 1)
            elif tok.type == tokenize.COMMENT and row < len(blanked):
                blanked[row] = blanked[row][:tok.start[1]]
            open_after[row] = depth
    except (tokenize.TokenError, SyntaxError):
        return None, lines
    breaks, depth = set(), 0
    for row in range(len(lines)):
        depth = open_after.get(row, depth)
        if depth > 0:
            breaks.add(row)
    return breaks, blanked


def joined(lines, python=False):
    """join continuation lines into single lines"""
    breaks = set()
    if python:
        found, blanked = py_open_breaks(lines)
        if found is not None:
            breaks, lines = found, blanked
    out, i = [], 0
    while i < len(lines):
        start, line = i, lines[i]
        while (line.endswith("\\") or i in breaks) and i + 1 < len(lines):
            if line.endswith("\\"):
                line = line[:-1]
            i += 1
            line = line + " " + lines[i].lstrip()
        out.append((start, line))
        i += 1
    return out


def is_python(rel, text):
    """return whether a file is a Python script"""
    return rel.endswith(".py") or (text.startswith("#!") and "python" in text.split("\n", 1)[0])


def check_text(rel, text, allow, used):
    """return the failures for host copy operations in a file's text"""
    fails = []
    if rel.endswith(".rules"):
        text = udev_commands(text)
    lines = text.splitlines()
    for i, line in joined(lines, python=is_python(rel, text)):
        if is_comment(line):
            continue
        for op in ops_on_line(line):
            hit = [r for r in allow if r[1] == rel and r[2] == op and r[3] in line]
            for r in hit:
                if r[5] and not any(r[5] in l for l in lines[:i] if not is_comment(l)):
                    fails.append(f"{rel}:{i + 1}: {op} is allowed only behind '{r[5]}', "
                                 f"and no code line above it carries that")
            if hit:
                used.update(r[0] for r in hit)
                continue
            fails.append(f"{rel}:{i + 1}: {op} carries labels/ACLs/xattrs or owners rhizo_host "
                         f"cannot write under enforcement -- copy content only (cp without -a/-p, "
                         f"shutil.copyfile, tar -x --no-same-owner --no-same-permissions) or allow "
                         f"it with a reason in host-copy-ops-allow.tsv: {line.strip()[:300]}")
    return fails


def check(root, allow_path):
    """return the host copy operation failures and scanned files"""
    allow, fails = read_allow(allow_path)
    rels = scan_set(root)
    missing = [a for a in ANCHORS if a not in rels]
    if missing:
        return fails + [f"the ship-set scan reached none of {', '.join(missing)}"], rels
    used = set()
    for rel in rels:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            fails += check_text(rel, fh.read(), allow, used)
    for r in allow:
        if r[0] not in used:
            fails.append(f"{os.path.basename(allow_path)}:{r[0]}: no {r[2]!r} line in {r[1]} "
                         f"matches '{r[3]}' -- drop the unused row")
    return fails, rels


def selftest():
    """check the host-copy-ops scan on fixtures"""
    bad = {
        "cp -a": 'cp -a "$src" "$dst"\n',
        "cp --archive": "cp --archive src dst\n",
        "cp -dpR": "cp -dpR src dst\n",
        "cp --preserve=all": "cp --preserve=all src dst\n",
        "cp -p": 'cp -p "$src" "$GSI_LIBS/" && n=$((n + 1))\n',
        "rsync -aX": "rsync -aX src/ dst/\n",
        "rsync --xattrs": "rsync -r --xattrs src/ dst/\n",
        "tar --xattrs": "tar --xattrs -xf a.tar -C /\n",
        "tar -xpf": "tar -xpf a.tar\n",
        "tar xpf": "tar xpf a.tar\n",
        "tar -x as root": "tar -x -C / -f -\n",
        "tar xf": "tar xf a.tar\n",
        "tar --extract": "tar --extract -f a.tar\n",
        "tar -x with --no-same-owner alone": "tar -x --no-same-owner -f a.tar\n",
        "tar -x with --no-same-permissions alone": "tar -x --no-same-permissions -f a.tar\n",
        "setfattr": "setfattr -n security.selinux -v x f\n",
        "setfacl": "setfacl -m u:0:rw f\n",
        "chcon": "chcon u:object_r:x:s0 f\n",
        "shutil.copy2": "    shutil.copy2(a, b)\n",
        "shutil.copytree": "    shutil.copytree(a, b, copy_function=shutil.copyfile)\n",
        "shutil.copystat": "shutil.copystat(a, b)\n",
        "shutil.move": "shutil.move(a, b)\n",
        "os.setxattr": '    os.setxattr(p, "security.selinux", b"u:object_r:x:s0\\0")\n',
        "os.removexattr": '    os.removexattr(p, "security.selinux")\n',
        "a label_before_policy caller": '    label_before_policy(p, b"u:object_r:x:s0\\0")\n',
        "os.removexattr in a unit's python": (
            'ExecStart=/usr/bin/python3 -c "import os,sys;[os.removexattr(p,a) for p in sys.argv[1:]]" f\n'),
        "subprocess cp -a": '    subprocess.run(["cp", "-a", src, dst], check=True)\n',
        "cp -a after a pipe": "ls x | cp -a y z\n",
        "unit ExecStart setfattr": "ExecStart=/bin/sh -c 'setfattr -x security.selinux f'\n",
        "cp -a on a continuation line": 'cp \\\n  -a "$src" \\\n  "$dst"\n',
        "/bin/cp -a": '/bin/cp -a "$src" "$dst"\n',
        "/usr/bin/rsync -aX": "/usr/bin/rsync -aX src/ dst/\n",
        "ExecStartPre=/usr/bin/setfattr": "ExecStartPre=/usr/bin/setfattr -x security.selinux /f\n",
        "ExecStart=-/usr/bin/setfattr": "ExecStart=-/usr/bin/setfattr -x security.selinux /f\n",
        "\\cp -a": '\\cp -a "$src" "$dst"\n',
        "sudo /bin/cp -p": "sudo /bin/cp -p a b\n",
    }
    bad_py = {
        "f-string cp -a": '    subprocess.run(f"cp -a {s} {d}", shell=True, check=True)\n',
        "rb-string tar -xpf": '    cmd = rb"tar -xpf a.tar"\n',
        "argv split across lines": ('    subprocess.run(["cp",\n'
                                    '                    "-a", src, dst], check=True)\n'),
        "argv split after a comment": ('    subprocess.run(["rsync",  # mirror it\n'
                                       '                    "-aX", src, dst])\n'),
        "argv split across a nested call": ('    subprocess.run(\n'
                                            '        ["tar", "-x", "-C", root,\n'
                                            '         "-f", str(path)],\n'
                                            '        check=True)\n'),
    }
    good = {
        "label_before_policy's own definition": "def label_before_policy(path, value, follow_symlinks=True):\n",
        "cp --sparse": 'cp --sparse=always "$src" "$dst.part"\n',
        "cp --remove-destination": 'cp --remove-destination --reflink=auto "$img" "$out.part"\n',
        "cp -r": "cp -r src dst\n",
        "cp --no-preserve": "cp -r --no-preserve=all src dst\n",
        "mkdir -p after cp": "cp src dst && mkdir -p d\n",
        "chmod after cp": "cp src dst; chmod 0644 dst\n",
        "tar -x content only": "tar -x --no-same-owner --no-same-permissions -C / -f -\n",
        "tar -xO to stdout": "tar -xOf a.tar etc/x\n",
        "tar -tf lists": "tar -tf a.tar\n",
        "tar -cf creates": "tar -cf - dir\n",
        "tar named in a message": 'echo "tar exited $rc, output kept"\n',
        "rsync -r": "rsync -r src/ dst/\n",
        "/bin/cp content only": '/bin/cp --sparse=always "$a" "$b"\n',
        "ExecStart=/usr/bin/python3": "ExecStart=/usr/bin/python3 /usr/lib/rhizo/boot.py selinux_setup\n",
        "shutil.copyfile": "    shutil.copyfile(a, b)\n    shutil.copymode(a, b)\n",
        "comment only": "# cp -a is what first prepare runs\n",
        "cp named in a message": 'log "cp failed, retrying"\n',
        "copy2 named in a message": 'return False, f"shutil.copyfile({p!r}) failed"\n',
        "getxattr reads only": '    cur = os.getxattr(p, "security.selinux")\n',
    }
    good_py = {
        "argv split, content only": ('    subprocess.run(["cp",\n'
                                     '                    "--sparse=always", src, dst], check=True)\n'),
        "cp -a only in a comment inside brackets": ('    subprocess.run(["cp",  # not -a, it relabels\n'
                                                    '                    src, dst])\n'),
        "closed call, then a -a argument": ('    subprocess.run(["cp", src, dst])\n'
                                            '    log("done", "-a")\n'),
    }
    fails = []
    for name, text in bad.items():
        if not check_text(f"bad/{name}", text, [], set()):
            fails.append(f"'{name}' was not flagged")
    for name, text in bad_py.items():
        if not check_text(f"bad/{name}.py", text, [], set()):
            fails.append(f"'{name}' (python) was not flagged")
    for name, text in good.items():
        got = check_text(f"good/{name}", text, [], set())
        if got:
            fails.append(f"'{name}' was flagged: {got}")
    for name, text in good_py.items():
        got = check_text(f"good/{name}.py", text, [], set())
        if got:
            fails.append(f"'{name}' (python) was flagged: {got}")
    udev_bad = 'ACTION=="add", SUBSYSTEM=="input", RUN+="/bin/cp -a /a /b"\n'
    got = check_text("x/70-a.rules", udev_bad, [], set())
    if not any("x/70-a.rules:1: cp -a" in g for g in got):
        fails.append(f"a udev RUN+= cp -a was not flagged on its own line: {got}")
    for label, text in (("a content-only RUN+=", 'ACTION=="add", RUN+="/bin/cp /a /b"\n'),
                        ("cp -a in a match value", 'ATTRS{name}=="cp -a", ENV{X}="1"\n'),
                        ("a commented rule", '# ACTION=="add", RUN+="/bin/cp -a /a /b"\n')):
        got = check_text("x/70-a.rules", text, [], set())
        if got:
            fails.append(f"{label} in a udev rule was flagged: {got}")
    row = [(1, "a.sh", "cp -a", "\"$TMP/mnt/system\"", "runs only before any policy is loaded", "")]
    used = set()
    if check_text("a.sh", 'cp -a "$TMP/mnt/system" "$TREE.part"\n', row, used) or used != {1}:
        fails.append("an allow row did not cover its own line")
    guarded = [row[0][:5] + ('refuse "policy-loaded"',)]
    ok = 'policy_loaded && refuse "policy-loaded" "x"\ncp -a "$TMP/mnt/system" y\n'
    if check_text("a.sh", ok, guarded, set()):
        fails.append("a guarded row was refused with its guard above the op")
    for label, text in (("guard gone", 'cp -a "$TMP/mnt/system" y\n'),
                        ("guard below the op", 'cp -a "$TMP/mnt/system" y\nrefuse "policy-loaded" x\n'),
                        ("guard only in a comment", '# refuse "policy-loaded"\ncp -a "$TMP/mnt/system" y\n')):
        got = check_text("a.sh", text, guarded, set())
        if not any("allowed only behind" in g for g in got):
            fails.append(f"a guarded row with its {label} was accepted: {got}")
    if not check_text("a.sh", 'cp -a "$OTHER" "$TREE.part"\n', row, set()):
        fails.append("an allow row covered a line it does not match")
    if not check_text("b.sh", 'cp -a "$TMP/mnt/system" x\n', row, set()):
        fails.append("an allow row covered another file")
    if not check_text("a.sh", 'cp -p "$TMP/mnt/system" x\n', row, set()):
        fails.append("an allow row covered another op")
    with tempfile.TemporaryDirectory() as root:
        allow = os.path.join(root, "allow.tsv")
        with open(allow, "w") as fh:
            fh.write("# comment\na.sh\tcp -a\tx\tok\nb.sh\tcp -a\tx\n")
        _, got = read_allow(allow)
        if not any("is no reason" in g for g in got):
            fails.append(f"a row with a one-word reason was accepted: {got}")
        if not any("want 4" in g for g in got):
            fails.append(f"a row missing its reason was accepted: {got}")
        env = git_env()
        subprocess.run(["git", "init", "-q", root], check=True, env=env)
        os.makedirs(os.path.join(root, "src", "install", "prepare"))
        os.makedirs(os.path.join(root, "src/android/hal/x"))
        os.makedirs(os.path.join(root, "debian"))
        with open(os.path.join(root, "debian/rhizo.postinst"), "w") as fh:
            fh.write("#!/bin/sh\nset -e\nrsync -aX /a/ /b/\n")
        with open(os.path.join(root, "src", "install", "prepare", "fetch-gsi.sh"), "w") as fh:
            fh.write("#!/bin/bash\ncp -a a b\n")
        with open(os.path.join(root, "src/android/hal/x/stage.sh"), "w") as fh:
            fh.write("#!/bin/sh\ncp -a a b\n")
        for d in ("debian/dropins", "debian/conf", "src/install/udev", "docs"):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        with open(os.path.join(root, "debian/rules"), "w") as fh:
            fh.write("#!/usr/bin/make -f\n\tinstall -D -m 0644 debian/conf/modprobe-x.conf $(ETC)/x.conf\n"
                     "\tinstall -m 0755 src/install/prepare/fetch-gsi.sh \\\n\t\tsrc/install/udev/70-x.rules src/android/hal/x/stage.sh $(P)/\n")
        with open(os.path.join(root, "debian/conf/modprobe-x.conf"), "w") as fh:
            fh.write("install x /bin/sh -c 'tar -x -C / -f /x.tar; modprobe --ignore-install x'\n")
        with open(os.path.join(root, "debian/dropins/x.conf"), "w") as fh:
            fh.write("[Service]\nExecStartPre=/usr/bin/setfattr -x security.selinux /f\n")
        with open(os.path.join(root, "src", "install", "udev", "70-x.rules"), "w") as fh:
            fh.write('# a comment\nACTION=="add", RUN+="/usr/bin/rsync -aX /a/ /b/"\n')
        with open(os.path.join(root, "docs/example.conf"), "w") as fh:
            fh.write("ExecStart=/bin/cp -a /a /b\n")
        with open(allow, "w") as fh:
            fh.write("src/install/prepare/fetch-gsi.sh\tcp -a\tnot-there\tunused on purpose, matches nothing\n")
        subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=env)
        got, rels = check(root, allow)
        if "src/android/hal/x/stage.sh" in rels:
            fails.append("the scan reached an Android-side tree")
        if "docs/example.conf" in rels:
            fails.append("the scan reached a .conf nothing ships or installs")
        if not any("reached none of" in g for g in got):
            fails.append(f"a scan missing its anchors was not refused: {got}")
        global ANCHORS
        saved, ANCHORS = ANCHORS, ("src/install/prepare/fetch-gsi.sh",)
        try:
            got, rels = check(root, allow)
        finally:
            ANCHORS = saved
        if not any("src/install/prepare/fetch-gsi.sh:2" in g for g in got):
            fails.append(f"the shipped cp -a was not flagged through the scan: {got}")
        if not any("debian/rhizo.postinst:3" in g for g in got):
            fails.append(f"a maintainer script outside debian/rules was not scanned: {got}")
        for where, what in (("debian/conf/modprobe-x.conf:1: tar -x", "a .conf debian/rules installs"),
                            ("debian/dropins/x.conf:2: setfattr", "a debian/dropins drop-in"),
                            ("src/install/udev/70-x.rules:2: rsync -aX", "a shipped udev rule's RUN+=")):
            if not any(where in g for g in got):
                fails.append(f"{what} was not scanned ({where}): {got}")
        if not any("drop the unused row" in g for g in got):
            fails.append(f"an unused allow row was not flagged: {got}")
    return fails


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        fails = selftest()
        for f in fails:
            print(f"check-host-copy-ops: FAIL selftest: {f}", file=sys.stderr)
        if fails:
            return 1
        print("check-host-copy-ops selftest: every metadata-carrying copy and label writer flagged "
              "(os.setxattr/removexattr, a root tar extract, a /usr/bin/, \\ or Exec*=- prefixed command, "
              "a Python string prefix, an argv split over lines), continuation lines, maintainer "
              "scripts, installed .conf files, drop-ins and udev RUN+= included, content-only copies "
              "pass, an allow row covers only its own path/op/line, a reasonless or unused row fails, "
              "and the ship-set walk skips Android-side trees and refuses a scan missing its anchors")
        return 0
    if sys.argv[1:]:
        print("usage: host-copy-ops.py [--selftest]", file=sys.stderr)
        return 2
    fails, rels = check(REPO, ALLOW)
    for f in fails:
        print(f"check-host-copy-ops: FAIL {f}", file=sys.stderr)
    if fails:
        return 1
    print(f"no shipped host script ({len(rels)} scanned) copies labels, ACLs, xattrs or owners "
          f"outside a reasoned row in host-copy-ops-allow.tsv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
