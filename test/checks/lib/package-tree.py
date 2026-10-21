#!/usr/bin/env python3
"""compare a rhizo .deb with the files in this tree"""
import glob
import gzip
import os
import re
import shlex
import subprocess
import sys
import tempfile

USAGE = """Usage: package-tree.py <rhizo_*.deb> [repo root]
       package-tree.py --selftest"""

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
STAGE = "debian/rhizo/"
PKG = "rhizo"
MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm", "config")


_MAKE_DIRECTIVES = ("ifeq", "ifneq", "ifdef", "ifndef", "else", "endif")


def install_recipe(rules_text):
    """return the override_dh_auto_install recipe lines"""
    body, inside = [], False
    for line in rules_text.split("\n"):
        if line.startswith("override_dh_auto_install:"):
            inside = True
        elif inside and line.startswith("\t"):
            body.append(line[1:])
        elif inside and line.strip().split()[0:1] and line.strip().split()[0] in _MAKE_DIRECTIVES:
            continue
        elif inside and line.strip() and not line.startswith("#"):
            break
    joined, cur = [], ""
    for line in body:
        if line.rstrip().endswith("\\"):
            cur += line.rstrip()[:-1] + " "
        else:
            joined.append(cur + line)
            cur = ""
    return joined + ([cur] if cur else [])


def copy_commands(rules_text):
    """return (sources, destination) of each install or cp line"""
    assigned = dict(re.findall(r"^([A-Z_][A-Z0-9_]*)\s*:=\s*(.*?)\s*$", rules_text, re.M))
    expand = lambda w: re.sub(r"\$\((\w+)\)", lambda m: assigned.get(m.group(1), m.group(0)), w)
    commands = []
    for line in install_recipe(rules_text):
        if "$$" in line:
            continue
        words = shlex.split(line)
        if not words or words[0] not in ("install", "cp"):
            continue
        args, dirs_only, i = [], False, 1
        while i < len(words):
            if words[i] == "-m":
                i += 2
                continue
            if words[i] == "-d":
                dirs_only = True
            if not words[i].startswith("-"):
                args.append(expand(words[i]))
            i += 1
        if not dirs_only and len(args) >= 2:
            commands.append((args[:-1], args[-1]))
    return commands


def packaged_pairs(rules_text, tracked, root, pkg_root):
    """return (tree path, package path) for each packaged tracked file"""
    pairs = []
    for sources, dest in copy_commands(rules_text):
        if not dest.startswith(STAGE):
            continue
        dest = dest[len(STAGE):]
        matches = [os.path.relpath(p, root) for s in sources if "$(" not in s
                   for p in sorted(glob.glob(os.path.join(root, s)))]
        many = dest.endswith("/") or len(matches) > 1
        dest = dest.rstrip("/")
        for rel in matches:
            if rel in tracked:
                into = many or os.path.isdir(os.path.join(pkg_root, dest))
                pairs.append((rel, dest + "/" + os.path.basename(rel) if into else dest))
                continue
            top = dest + "/" + os.path.basename(rel) if many else dest
            pairs.extend((t, top + "/" + t[len(rel) + 1:]) for t in sorted(tracked) if t.startswith(rel + "/"))
    return pairs


def split_debhelper_token(text):
    """split the text at its #DEBHELPER# line"""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.strip() == "#DEBHELPER#":
            return "\n".join(lines[:i]), "\n".join(lines[i + 1:])
    return text, None


AUTO_BLOCK = re.compile(r"(?ms)^# Automatically added by dh_[^\n]*\n.*?^# End automatically added section\n")
NO_SOURCE_ALLOWED = "#!/bin/sh\nset -e\n"


def rendered_postrm(root):
    """return the rendered postrm, or None without a template"""
    if not os.path.isfile(os.path.join(root, "debian", PKG + ".postrm.in")):
        return None
    import importlib.util
    spec = importlib.util.spec_from_file_location("embed_teardown", os.path.join(root, "debian", "embed-teardown.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.postrm_text(root)


def maintainer_script_findings(root, pkg_root):
    """compare each maintainer script with the package's DEBIAN copy"""
    findings, compared = [], 0
    for kind in MAINTAINER_SCRIPTS:
        src_path = os.path.join(root, "debian", "%s.%s" % (PKG, kind))
        pkg_path = os.path.join(pkg_root, "DEBIAN", kind)
        label = "debian/%s.%s" % (PKG, kind)
        rendered = rendered_postrm(root) if kind == "postrm" else None
        if rendered is None and not os.path.isfile(src_path):
            if os.path.isfile(pkg_path):
                with open(pkg_path) as f:
                    built = f.read()
                if AUTO_BLOCK.sub("", built) != NO_SOURCE_ALLOWED:
                    findings.append("%s: no source, but the package's DEBIAN/%s carries more than debhelper's own boilerplate" % (label, kind))
            continue
        compared += 1
        if not os.path.isfile(pkg_path):
            findings.append("%s: tracked but missing from the package's DEBIAN/%s" % (label, kind))
            continue
        if rendered is None:
            with open(src_path) as f:
                src = f.read()
        else:
            src = rendered
        with open(pkg_path) as f:
            built = f.read()
        stripped = AUTO_BLOCK.sub("", built)
        want = src if "#DEBHELPER#\n" not in src else src.replace("#DEBHELPER#\n", "\n", 1)
        if stripped == want:
            continue
        prefix, suffix = split_debhelper_token(src)
        if suffix is None:
            findings.append("%s: bytes differ from the package's DEBIAN/%s" % (label, kind))
        elif not stripped.startswith(prefix):
            findings.append("%s: the part before #DEBHELPER# differs from the package's DEBIAN/%s" % (label, kind))
        elif not stripped.endswith(suffix):
            findings.append("%s: the part after #DEBHELPER# differs from the package's DEBIAN/%s" % (label, kind))
        else:
            findings.append("%s: carries an outdated or extra line beside #DEBHELPER#, differing from the package's DEBIAN/%s" % (label, kind))
    return findings, compared


def bytecode_findings(pkg_root):
    """name each __pycache__ directory and .pyc file in the package"""
    findings = []
    for d, dirs, files in os.walk(pkg_root):
        rel = os.path.relpath(d, pkg_root)
        for n in sorted(dirs):
            if n == "__pycache__":
                findings.append("%s: the package holds Python bytecode" % os.path.join(rel, n))
        dirs[:] = sorted(n for n in dirs if n != "__pycache__")
        findings.extend("%s: the package holds Python bytecode" % os.path.join(rel, n)
                        for n in sorted(files) if n.endswith(".pyc"))
    return findings


def check(rules_text, tracked, root, pkg_root):
    """compare the package with the tree"""
    pairs = packaged_pairs(rules_text, tracked, root, pkg_root)
    if not pairs:
        return ["found no tracked file that debian/rules copies into the package"], 0
    findings = bytecode_findings(pkg_root)
    for tree_rel, pkg_rel in pairs:
        tree_path, pkg_path = os.path.join(root, tree_rel), os.path.join(pkg_root, pkg_rel)
        if not os.path.isfile(tree_path):
            findings.append("%s: tracked but missing from the tree" % tree_rel)
        elif os.path.isfile(pkg_path):
            with open(tree_path, "rb") as a, open(pkg_path, "rb") as b:
                if a.read() != b.read():
                    findings.append("%s: bytes differ from the package's %s" % (tree_rel, pkg_rel))
        elif os.path.isfile(pkg_path + ".gz"):
            with open(tree_path, "rb") as a, gzip.open(pkg_path + ".gz") as b:
                if a.read() != b.read():
                    findings.append("%s: bytes differ from the package's %s.gz" % (tree_rel, pkg_rel))
        else:
            findings.append("%s: the package has no %s" % (tree_rel, pkg_rel))
    maint_findings, maint_compared = maintainer_script_findings(root, pkg_root)
    findings.extend(maint_findings)
    return findings, len(pairs) + maint_compared


RULES_FIXTURE = """\
PAYLOAD  := debian/rhizo/usr/lib/rhizo
UNITS    := debian/rhizo/usr/lib/systemd/system
HAL_FILES := composer

%:
\tdh $@

override_dh_auto_install:
\tinstall -d $(PAYLOAD) $(UNITS)
\tinstall -m 0644 src/androidd/boot.py $(PAYLOAD)/launcher3.py\n\tinstall -m 0644 src/androidd/sandbox/*.py $(PAYLOAD)/sandbox/
\tfor f in $(HAL_FILES); do cp -p var/share/gfx_hal/$$f $(PAYLOAD)/gfx_hal/; done
# the files the launcher writes into the sandbox
\tcp -a src/androidd/guest $(PAYLOAD)/guest
\tinstall -m 0755 src/install/prepare.sh \\
\t                src/install/update.sh $(PAYLOAD)/install/
\tinstall -D -m 0755 src/install/cli.sh debian/rhizo/usr/bin/rhizo
\tinstall -D -m 0644 LICENSE debian/rhizo/usr/share/doc/rhizo/LICENSE
\tinstall -m 0644 src/services/units/boot/androidd.service $(UNITS)/

override_dh_fixperms:
\tdh_fixperms
\tchmod 0755 vm/tools/not-a-copy.sh
"""

FIXTURE_FILES = {
    "src/androidd/boot.py": ("usr/lib/rhizo/launcher3.py", b"launcher\n"),
    "src/androidd/sandbox/core.py": ("usr/lib/rhizo/sandbox/core.py", b"env\n"),
    "src/androidd/sandbox/hals.py": ("usr/lib/rhizo/sandbox/hals.py", b"hals\n"),
    "src/androidd/guest/sepolicy/policy.cil": ("usr/lib/rhizo/guest/sepolicy/policy.cil", b"(allow a b (c (d)))\n"),
    "src/androidd/guest/init/adbd.rc": ("usr/lib/rhizo/guest/init/adbd.rc", b"service adbd\n"),
    "src/install/prepare.sh": ("usr/lib/rhizo/install/prepare.sh", b"#!/bin/sh\nprepare\n"),
    "src/install/update.sh": ("usr/lib/rhizo/install/update.sh", b"#!/bin/sh\nupdate\n"),
    "src/install/cli.sh": ("usr/bin/rhizo", b"#!/bin/sh\ncli\n"),
    "src/services/units/boot/androidd.service": ("usr/lib/systemd/system/androidd.service", b"[Unit]\n"),
    "LICENSE": ("usr/share/doc/rhizo/LICENSE", b"Business Source License 1.1\n"),
}
COMPRESSED = {"LICENSE"}
UNTRACKED = {"var/share/gfx_hal/composer": ("usr/lib/rhizo/gfx_hal/composer", b"\x7fELF new")}
POSTINST_SRC = b"#!/bin/sh\nset -e\necho hi\n\n#DEBHELPER#\nexit 0\n"
POSTINST_BUILT = (b"#!/bin/sh\nset -e\necho hi\n\n# Automatically added by dh_installsystemd\n"
                   b"some generated stuff\n# End automatically added section\n\nexit 0\n")


def write(path, data):
    """write bytes to a path, making its parent directories"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def fixture(tmp, edit=None, rules=RULES_FIXTURE):
    """write a fixture tree and its edited package"""
    root, pkg = os.path.join(tmp, "tree"), os.path.join(tmp, "pkg")
    for tree_rel, (pkg_rel, data) in list(FIXTURE_FILES.items()) + list(UNTRACKED.items()):
        write(os.path.join(root, tree_rel), data)
        if tree_rel in COMPRESSED:
            write(os.path.join(pkg, pkg_rel + ".gz"), gzip.compress(data))
        else:
            write(os.path.join(pkg, pkg_rel), data)
    write(os.path.join(root, "debian", "rules"), rules.encode())
    write(os.path.join(root, "vm", "tools", "not-a-copy.sh"), b"#!/bin/sh\n")
    write(os.path.join(root, "debian", "rhizo.postinst"), POSTINST_SRC)
    write(os.path.join(pkg, "DEBIAN", "postinst"), POSTINST_BUILT)
    if edit:
        edit(pkg)
    return rules, set(FIXTURE_FILES) | {"debian/rules", "vm/tools/not-a-copy.sh"}, root, pkg


def selftest():
    """run the package checks on edited fixtures"""
    problems = []
    WANT_COMPARED = len(FIXTURE_FILES) + 1

    def expect(name, edit, want, rules=RULES_FIXTURE):
        """check a fixture with edit applied against want"""
        with tempfile.TemporaryDirectory() as tmp:
            findings, compared = check(*fixture(tmp, edit, rules))
        if want is None:
            if findings or compared != WANT_COMPARED:
                problems.append("%s: wanted no finding over %d files, got %s over %d"
                                % (name, WANT_COMPARED, findings, compared))
        elif not any(all(w in f for w in want) for f in findings):
            problems.append("%s: no finding names %s (got %s)" % (name, want, findings))

    expect("a package built from this tree", None, None)
    expect("a globbed file carries older bytes",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/sandbox/hals.py"), b"hals, older\n"),
           ("src/androidd/sandbox/hals.py", "usr/lib/rhizo/sandbox/hals.py", "differ"))
    expect("a file under a copied directory carries older bytes",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/guest/init/adbd.rc"), b"service adbd old\n"),
           ("src/androidd/guest/init/adbd.rc", "differ"))
    expect("the continued install line's second file carries older bytes",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/install/update.sh"), b"#!/bin/sh\nold\n"),
           ("src/install/update.sh", "differ"))
    expect("a renamed install -D target carries older bytes",
           lambda p: write(os.path.join(p, "usr/bin/rhizo"), b"#!/bin/sh\nold cli\n"),
           ("src/install/cli.sh", "usr/bin/rhizo", "differ"))
    expect("a copied file is missing from the package",
           lambda p: os.remove(os.path.join(p, "usr/lib/systemd/system/androidd.service")),
           ("src/services/units/boot/androidd.service", "no usr/lib/systemd/system/androidd.service"))
    expect("a compressed doc file carries older bytes",
           lambda p: write(os.path.join(p, "usr/share/doc/rhizo/LICENSE.gz"), gzip.compress(b"older license\n")),
           ("LICENSE", "differ"))
    expect("an old untracked build output is not judged",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/gfx_hal/composer"), b"\x7fELF old"), None)
    expect("rules whose install recipe the reader cannot find", None, ("no tracked file",),
           rules=RULES_FIXTURE.replace("override_dh_auto_install:", "override_dh_install:"))
    expect("a maintainer script's part before #DEBHELPER# carries older bytes",
           lambda p: write(os.path.join(p, "DEBIAN/postinst"),
                            POSTINST_BUILT.replace(b"echo hi", b"echo old")),
           ("debian/rhizo.postinst", "before #DEBHELPER#", "DEBIAN/postinst"))
    expect("a maintainer script's part after #DEBHELPER# carries older bytes",
           lambda p: write(os.path.join(p, "DEBIAN/postinst"),
                            POSTINST_BUILT.replace(b"exit 0\n", b"exit 1\n")),
           ("debian/rhizo.postinst", "after #DEBHELPER#", "DEBIAN/postinst"))
    expect("a maintainer script is missing from the package",
           lambda p: os.remove(os.path.join(p, "DEBIAN/postinst")),
           ("debian/rhizo.postinst", "missing from the package's DEBIAN/postinst"))
    expect("an old build left a line before the auto-added block",
           lambda p: write(os.path.join(p, "DEBIAN/postinst"),
                            POSTINST_BUILT.replace(b"# Automatically added",
                                                    b"rm -rf /var/lib/rhizo  # removed since\n# Automatically added", 1)),
           ("debian/rhizo.postinst", "DEBIAN/postinst"))
    expect("an old build left a line after the auto-added block",
           lambda p: write(os.path.join(p, "DEBIAN/postinst"),
                            POSTINST_BUILT.replace(b"# End automatically added section\n",
                                                    b"# End automatically added section\nsystemctl disable androidd.service\n", 1)),
           ("debian/rhizo.postinst", "DEBIAN/postinst"))
    expect("an old build's exit line is prefixed but still ends with the source's own text",
           lambda p: write(os.path.join(p, "DEBIAN/postinst"),
                            POSTINST_BUILT.replace(b"exit 0\n", b"false; exit 0\n")),
           ("debian/rhizo.postinst", "DEBIAN/postinst"))
    expect("a built preinst with no source carries a real command",
           lambda p: write(os.path.join(p, "DEBIAN/preinst"), b"#!/bin/sh\nset -e\necho evil\n"),
           ("debian/rhizo.preinst", "no source", "DEBIAN/preinst"))
    expect("a copied directory carries a __pycache__",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/guest/__pycache__/nb_dns.cpython-312.pyc"), b"\x00"),
           ("usr/lib/rhizo/guest/__pycache__", "Python bytecode"))
    expect("a .pyc sits beside its source",
           lambda p: write(os.path.join(p, "usr/lib/rhizo/sandbox/core.pyc"), b"\x00"),
           ("usr/lib/rhizo/sandbox/core.pyc", "Python bytecode"))
    if problems:
        for p in problems:
            print("SELFTEST FAILED: %s" % p, file=sys.stderr)
        return 1
    print("check-package-tree selftest: a correct package passes; older bytes, a missing copy, an unreadable "
          "recipe, a maintainer script edited on or beside either side of #DEBHELPER#, a sourceless "
          "script carrying a real command, and a __pycache__ or .pyc in the package each fail by name")
    return 0


def main(argv):
    """check a .deb against the tree, or run the selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) < 2:
        print(__doc__ + "\n\n" + USAGE, file=sys.stderr)
        return 2
    deb = argv[1]
    root = argv[2] if len(argv) > 2 else ROOT
    tracked = set(subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True)
                  .stdout.decode().split("\0")) - {""}
    with open(os.path.join(root, "debian", "rules")) as f:
        rules = f.read()
    with tempfile.TemporaryDirectory() as pkg:
        subprocess.run(["dpkg-deb", "-x", deb, pkg], check=True)
        subprocess.run(["dpkg-deb", "-e", deb, os.path.join(pkg, "DEBIAN")], check=True)
        findings, compared = check(rules, tracked, root, pkg)
    for line in findings[:20]:
        print("FAIL: %s" % line)
    if len(findings) > 20:
        print("FAIL: ... and %d more" % (len(findings) - 20))
    if findings:
        return 1
    print("check-package-tree: %s carries this tree's bytes for all %d tracked files debian/rules copies"
          % (os.path.basename(deb), compared))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
