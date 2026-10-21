#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, "..", "..", "..", ".."))
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402

CONFFILE_SRC = "debian/apt.conf.d/50rhizo"
CONFFILE_DEST = "/etc/apt/apt.conf.d/50rhizo"
HOST_MODE_DEST = "/usr/lib/rhizo/host-mode" + CONFFILE_DEST
RULES = "debian/rules"
CONTROL = "debian/control"
SCRIPTS = ("debian/rhizo.preinst", "debian/rhizo.postinst",
           "debian/rhizo.prerm", "debian/rhizo.postrm.in")
BARE_DH_FILES = ("install", "links", "dirs", "conffiles", "maintscript", "triggers")
DH_GENERATED_SUFFIXES = (".debhelper", ".substvars", ".debhelper.log")
NAMES_CONFFILE = re.compile(r'50rhizo|apt\.conf\.d|etc/apt')
POSTINST = "debian/rhizo.postinst"
MAINTSCRIPT = "debian/rhizo.maintscript"
CHANGELOG = "debian/changelog"
LAST_CONFFILE_RELEASE = "0.1.3"
RM_CONFFILE = re.compile(r'^rm_conffile ' + re.escape(CONFFILE_DEST) + r' (\S+)~$')
OBSOLETE_CONFFILES = ("/etc/profile.d/rhizo-console-vt.sh",)
PKG_LIB = "src/install/lib/pkg-lib.sh"

WANT_STATEMENT = 'APT::Sandbox::User "root";'
INSTALL_LINE = re.compile(
    r'^\tinstall\b[^\n]*\s' + re.escape(CONFFILE_SRC) + r'\s[^\n]*$', re.M)
WANT_DEST = "$(PAYLOAD)/host-mode" + CONFFILE_DEST
INSTALL_LINE_TEXT = "\tinstall -D -m 0644 %s %s\n" % (CONFFILE_SRC, WANT_DEST)
PKG_LIB_NAMES = ("etc/apt/apt.conf.d/50rhizo\"",
                 'etc/apt/*) [ -d "${RHIZO_PKG_ROOT:-}/etc/apt" ] || continue ;;')
HOST_CONDITION = 'if [ "$PKG_MODE" = host ]; then'
INSTALL_TARGET = "override_dh_auto_install"
DH_HOOKED = ("dh_installdeb", "dh_builddeb", "dh_gencontrol", "dh_md5sums",
             "dh_link", "dh_fixperms", "dh_install", "dh_installdirs")
HOOKS = re.compile(r'^(?:override|execute_before|execute_after)_(?:%s):.*\n(?:\t.*\n?)*'
                   % "|".join(DH_HOOKED), re.M)

BUILD_TOOLS = ("dpkg-buildpackage", "dh", "fakeroot", "dpkg", "dpkg-deb")


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def statements(conf_text):
    """return the apt.conf statements"""
    body = re.sub(r'/\*.*?\*/', '', conf_text, flags=re.S)
    out = []
    for line in body.splitlines():
        line = re.sub(r'(^|\s)(//|#).*$', '', line).strip()
        if line:
            out.append(line)
    return out


def check_conffile(root):
    """return the problems with the apt configuration file source"""
    path = os.path.join(root, CONFFILE_SRC)
    if not os.path.isfile(path):
        return ["conffile-content: %s does not exist" % CONFFILE_SRC]
    got = statements(read(root, CONFFILE_SRC))
    if got != [WANT_STATEMENT]:
        return ["conffile-content: %s sets %r, want exactly [%r]" % (CONFFILE_SRC, got, WANT_STATEMENT)]
    return []


def install_lines(root):
    """return the install recipe lines of the rules"""
    return INSTALL_LINE.findall(read(root, RULES))


def rules_lines(text):
    """yield rules lines with target and depth"""
    target, depth = None, 0
    for n, line in enumerate(text.splitlines(), 1):
        if not line.startswith("\t"):
            word = line.strip()
            if re.match(r'(ifeq|ifneq|ifdef|ifndef)\b', word):
                depth += 1
            elif re.match(r'endif\b', word):
                depth -= 1
            elif word and not word.startswith("#") and not re.match(r'else\b', word):
                m = re.match(r'([A-Za-z0-9_.%-]+)\s*:(?!=)', line)
                target = m.group(1) if m else None
        yield n, line, target, depth


def check_rules(root):
    """check how the rules install the apt configuration file"""
    text = read(root, RULES)
    lines = install_lines(root)
    if not lines:
        return ["rules-install: %s has no recipe line installing %s" % (RULES, CONFFILE_SRC)]
    fails = []
    if not any(line.split()[-1] == WANT_DEST for line in lines):
        fails.append("rules-install: %s installs %s to %s, want %s" %
                     (RULES, CONFFILE_SRC, [line.split()[-1] for line in lines], WANT_DEST))
    for n, line, target, depth in rules_lines(text):
        if line in lines:
            if target != INSTALL_TARGET or depth != 0:
                fails.append("rules-install: %s:%d installs %s under target %r at make-conditional "
                             "depth %d, want %s at depth 0" % (RULES, n, CONFFILE_SRC, target, depth,
                                                              INSTALL_TARGET))
        elif NAMES_CONFFILE.search(line) and not line.lstrip().startswith("#"):
            fails.append("packaging-touches-apt-file: %s:%d names the apt file outside its install "
                         "line: %s" % (RULES, n, line.strip()))
    return fails


def compat_level(root):
    """return the debhelper compat level, or None"""
    m = re.search(r'debhelper-compat\s*\(=\s*(\d+)\)', read(root, CONTROL))
    return m.group(1) if m else None


def build_minideb(root, work):
    """build a .deb from the debian/rules install line"""
    lines = install_lines(root)
    if not lines:
        return None, "no install line for %s in %s to build from" % (CONFFILE_SRC, RULES)
    compat = compat_level(root)
    if not compat:
        return None, "no debhelper-compat level in %s" % CONTROL
    src = os.path.join(work, "src")
    os.makedirs(os.path.join(src, "debian", "apt.conf.d"))
    shutil.copy(os.path.join(root, CONFFILE_SRC), os.path.join(src, CONFFILE_SRC))
    with open(os.path.join(src, "debian", "control"), "w") as fh:
        fh.write("Source: rhizo\nSection: misc\nPriority: optional\n"
                 "Maintainer: fixture <fixture@example.invalid>\n"
                 "Build-Depends: debhelper-compat (= %s)\nStandards-Version: 4.6.2\n"
                 "Rules-Requires-Root: no\n\nPackage: rhizo\nArchitecture: all\n"
                 "Description: conffile fixture\n fixture\n" % compat)
    with open(os.path.join(src, "debian", "changelog"), "w") as fh:
        fh.write("rhizo (0.0.1) unstable; urgency=medium\n\n  * fixture\n\n"
                 " -- fixture <fixture@example.invalid>  Thu, 01 Jan 2026 00:00:00 +0000\n")
    rules = os.path.join(src, "debian", "rules")
    with open(rules, "w") as fh:
        fh.write("#!/usr/bin/make -f\nPAYLOAD := debian/rhizo/usr/lib/rhizo\n%:\n\tdh $@\noverride_dh_auto_install:\n")
        fh.write("\n".join(lines) + "\n")
        fh.write(re.sub(r'^\tpython3 debian/embed-teardown\.py[^\n]*\n', "",
                        "".join(HOOKS.findall(read(root, RULES))), flags=re.M))
    os.chmod(rules, 0o755)
    res = subprocess.run(["dpkg-buildpackage", "-b", "-us", "-uc", "-d"], cwd=src,
                         capture_output=True, text=True)
    deb = os.path.join(work, "rhizo_0.0.1_all.deb")
    if res.returncode != 0 or not os.path.isfile(deb):
        tail = (res.stdout + res.stderr).strip().splitlines()[-5:]
        return None, "dpkg-buildpackage rc=%d: %s" % (res.returncode, " | ".join(tail))
    return deb, None


def dpkg_root(rootdir, *args):
    """run dpkg under fakeroot against a root directory"""
    env = dict(os.environ, PATH="/usr/sbin:/usr/bin:/sbin:/bin")
    return subprocess.run(["fakeroot", "dpkg", "--root=" + rootdir,
                           "--log=" + os.path.join(rootdir, "dpkg.log"),
                           "--force-script-chrootless"] + list(args),
                          capture_output=True, text=True, env=env)


def assert_host_mode_package(deb, src_bytes, work):
    """check the package ships the apt file for host mode"""
    fails = []
    ctrl = os.path.join(work, "ctrl")
    subprocess.run(["dpkg-deb", "-e", deb, ctrl], check=True)
    conffiles = []
    if os.path.isfile(os.path.join(ctrl, "conffiles")):
        with open(os.path.join(ctrl, "conffiles")) as fh:
            conffiles = fh.read().split()
    if CONFFILE_DEST in conffiles or HOST_MODE_DEST in conffiles:
        fails.append("host-mode-only: the built package's DEBIAN/conffiles is %r" % conffiles)
    tree = os.path.join(work, "tree")
    subprocess.run(["dpkg-deb", "-x", deb, tree], check=True)
    shipped = os.path.join(tree, HOST_MODE_DEST.lstrip("/"))
    if os.path.lexists(os.path.join(tree, CONFFILE_DEST.lstrip("/"))):
        fails.append("host-mode-only: the built package ships %s" % CONFFILE_DEST)
    if not os.path.isfile(shipped):
        fails.append("host-mode-payload: the built package carries no %s for host mode to link" % HOST_MODE_DEST)
    elif src_bytes is not None:
        with open(shipped, "rb") as fh:
            if fh.read() != src_bytes:
                fails.append("host-mode-payload: the built package's %s differs from %s" %
                             (HOST_MODE_DEST, CONFFILE_SRC))
    rootdir = os.path.join(work, "root")
    for d in ("var/lib/dpkg/info", "var/lib/dpkg/updates", "var/lib/dpkg/triggers"):
        os.makedirs(os.path.join(rootdir, d))
    for f in ("var/lib/dpkg/status", "var/lib/dpkg/available"):
        open(os.path.join(rootdir, f), "w").close()
    res = dpkg_root(rootdir, "-i", deb)
    if res.returncode != 0:
        return fails + ["host-mode-payload: dpkg -i on a scratch root failed rc=%d: %s" %
                        (res.returncode, res.stderr.strip()[-300:])]
    if os.path.lexists(os.path.join(rootdir, CONFFILE_DEST.lstrip("/"))):
        fails.append("host-mode-only: dpkg -i put %s in place" % CONFFILE_DEST)
    res = dpkg_root(rootdir, "-r", "rhizo")
    if res.returncode != 0:
        fails.append("remove-deletes: dpkg -r failed rc=%d: %s" % (res.returncode, res.stderr.strip()[-300:]))
    elif os.path.lexists(os.path.join(rootdir, HOST_MODE_DEST.lstrip("/"))):
        fails.append("remove-deletes: dpkg -r kept %s" % HOST_MODE_DEST)
    return fails


def check_package(root):
    """return the problems with the built package"""
    missing = [t for t in BUILD_TOOLS if shutil.which(t) is None]
    if missing:
        return ["tool-missing: %s not on PATH (apt install debhelper fakeroot dpkg-dev)" % ", ".join(missing)]
    with tempfile.TemporaryDirectory() as work:
        deb, err = build_minideb(root, work)
        if err:
            return ["host-mode-payload: " + err]
        src_bytes = None
        if os.path.isfile(os.path.join(root, CONFFILE_SRC)):
            with open(os.path.join(root, CONFFILE_SRC), "rb") as fh:
                src_bytes = fh.read()
        return assert_host_mode_package(deb, src_bytes, work)


def packaging_files(root):
    """return the debian/ files of the rhizo package"""
    names = sorted(os.listdir(os.path.join(root, "debian")))
    return ["debian/" + n for n in names
            if (n.startswith("rhizo.") or n in BARE_DH_FILES)
            and not n.endswith(DH_GENERATED_SUFFIXES)
            and not os.path.isfile(os.path.join(root, "debian", n + ".in"))
            and os.path.isfile(os.path.join(root, "debian", n))]


def check_packaging_files(root):
    """return the problems in the packaging files and the scripts they source"""
    fails = []
    rels = packaging_files(root)
    for rel in [r for r in rels if r in SCRIPTS]:
        rels += [os.path.relpath(lib, root) for lib in maint_inline.sourced(os.path.join(root, rel))
                 if os.path.relpath(lib, root) not in rels]
    for rel in rels:
        for n, line in enumerate(read(root, rel).splitlines(), 1):
            if line.strip().startswith("#"):
                continue
            if rel == PKG_LIB and line.strip() in PKG_LIB_NAMES:
                continue
            if rel == MAINTSCRIPT and RM_CONFFILE.match(line.strip()):
                continue
            if NAMES_CONFFILE.search(line):
                fails.append("packaging-touches-apt-file: %s:%d names the apt file outside the host-mode "
                             "list pkg-lib.sh links it from: %s" % (rel, n, line.strip()))
    return fails


def postinst_block(text):
    """return the postinst apt-config loop lines"""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if "apt-config shell" in line and not line.strip().startswith("#"):
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == "done":
                    return "\n".join(lines[i:j + 1]) + "\n"
            return None
    return None


def indent(line):
    """return the number of leading spaces of a line"""
    return len(line) - len(line.lstrip(" "))


SUCCESS_EXIT = re.compile(r'(?:^|[;&|{]|\bthen\b|\belse\b|\bdo\b)\s*exit(?:\s+0)?\s*(?:$|[;}&|#])')


def postinst_context(text):
    """return the apt-config placement error text"""
    lines = text.splitlines()
    starts = [i for i, l in enumerate(lines) if re.match(r'\s*configure\)\s*$', l)]
    block = [i for i, l in enumerate(lines)
             if "apt-config shell" in l and not l.strip().startswith("#")]
    if len(starts) != 1 or not block:
        return "found %d `configure)` branches and %d apt-config calls" % (len(starts), len(block))
    ci, bi = starts[0], block[0]
    body = [l for l in lines[ci + 1:] if l.strip() and not l.strip().startswith("#")]
    width = indent(body[0]) if body else -1
    ends = [i for i in range(ci + 1, len(lines))
            if lines[i].strip() == ";;" and indent(lines[i]) == width]
    if not ends or not ci < bi < ends[0]:
        return "the apt-config call (line %d) is not inside the `configure)` branch (line %d)" % (bi + 1, ci + 1)
    above = [i for i in range(ci + 1, bi) if lines[i].strip() and indent(lines[i]) < indent(lines[bi])]
    guard = lines[above[-1]] if above else ""
    if indent(lines[bi]) != width + 2 or guard.strip() != HOST_CONDITION or indent(guard) != width:
        return ("the apt-config call (line %d) runs under %r, want under %r alone at the `configure)` body's "
                "indent %d" % (bi + 1, guard.strip(), HOST_CONDITION, width))
    for i in range(ci + 1, bi):
        if indent(lines[i]) == width and re.match(r'(exit|return)\b', lines[i].strip()):
            return "line %d leaves the `configure)` branch before the block: %s" % (i + 1, lines[i].strip())
        if not lines[i].lstrip().startswith("#") and SUCCESS_EXIT.search(lines[i]):
            return "line %d can leave the `configure)` branch before the block: %s" % (i + 1, lines[i].strip())
    return None


APT_CONFIG_SHIM = r'''#!/bin/sh
echo "$*" >> "$SHIM_LOG.apt-config"
[ -n "$SHIM_EMPTY" ] && exit 0
base=$SHIM_FX
[ -n "$APT_CONFIG" ] && base=$SHIM_FX/invoker
while [ $# -gt 0 ]; do
  case "$1" in shell) shift; continue ;; esac
  var=$1 key=$2; shift 2
  case "$key" in
    Dir::State::lists/d) echo "$var='$base/lists/'" ;;
    Dir::Cache::archives/d) echo "$var='$base/archives/'" ;;
  esac
done
'''
CHOWN_SHIM = r'''#!/bin/sh
echo "$*" >> "$SHIM_LOG"
[ -n "$SHIM_CHOWN_FAIL" ] && exit 1
exit 0
'''


def run_block(block, work, empty=False, chown_fail=False, apt_config=None, real_apt_config=False):
    """run the postinst block with shim commands"""
    fx = os.path.join(work, "fx")
    for d in ("lists/partial", "lists/auxfiles", "archives/partial"):
        os.makedirs(os.path.join(fx, d), exist_ok=True)
        os.makedirs(os.path.join(fx, "invoker", d), exist_ok=True)
    shims = os.path.join(work, "shims")
    os.makedirs(shims, exist_ok=True)
    shimmed = [("chown", CHOWN_SHIM)]
    if not real_apt_config:
        shimmed.append(("apt-config", APT_CONFIG_SHIM))
    for name, body in shimmed:
        p = os.path.join(shims, name)
        with open(p, "w") as fh:
            fh.write(body)
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
    log = os.path.join(work, "chown.log")
    for p in (log, log + ".apt-config"):
        if os.path.exists(p):
            os.remove(p)
    script = os.path.join(work, "block.sh")
    with open(script, "w") as fh:
        fh.write("PROG=rhizo\n" + block)
    env = dict(os.environ, PATH=shims + ":/usr/bin:/bin", SHIM_LOG=log, SHIM_FX=fx)
    env.pop("APT_CONFIG", None)
    if apt_config:
        env["APT_CONFIG"] = apt_config
    if empty:
        env["SHIM_EMPTY"] = "1"
    if chown_fail:
        env["SHIM_CHOWN_FAIL"] = "1"
    res = subprocess.run(["sh", "-e", script], capture_output=True, text=True, env=env, cwd=work)
    calls = open(log).read().splitlines() if os.path.exists(log) else []
    asked = open(log + ".apt-config").read().split() if os.path.exists(log + ".apt-config") else []
    return res.returncode, res.stdout + res.stderr, calls, asked, fx


def apt_config_dirs(env):
    """return apt-config's lists and archives directories"""
    res = subprocess.run(["apt-config", "shell", "L", "Dir::State::lists/d",
                          "A", "Dir::Cache::archives/d"], capture_output=True, text=True, env=env)
    got = dict(re.findall(r"^(L|A)='([^']*)'$", res.stdout, re.M))
    return (got["L"], got["A"]) if res.returncode == 0 and len(got) == 2 else None


def check_postinst_real_apt_config(block):
    """check the chown calls from the apt-config block"""
    if shutil.which("apt-config") is None:
        return ["postinst-apt-config-real: no apt-config on PATH to run the block against"]
    base = dict(os.environ)
    base.pop("APT_CONFIG", None)
    system = apt_config_dirs(base)
    with tempfile.TemporaryDirectory() as work:
        conf = os.path.join(work, "invoker.conf")
        inv = os.path.join(work, "fx", "invoker")
        with open(conf, "w") as fh:
            fh.write('Dir::State::Lists "%s/lists/";\nDir::Cache::Archives "%s/archives/";\n' % (inv, inv))
        invoked = apt_config_dirs(dict(base, APT_CONFIG=conf))
        if system is None or invoked != (inv + "/lists/", inv + "/archives/"):
            return ["postinst-apt-config-real: apt-config answered %r plain and %r under an APT_CONFIG "
                    "naming %s" % (system, invoked, inv)]
        rc, out, calls, _, _ = run_block(block, work, apt_config=conf, real_apt_config=True)
    want = []
    for d in (system[0] + "partial", system[0] + "auxfiles", system[1] + "partial"):
        if os.path.isdir(d):
            want += ["root:root " + d, "-R root:root " + d]
    if rc != 0 or calls != want:
        return ["postinst-apt-config-real: with the real apt-config and APT_CONFIG=%s the block exits "
                "%d after chown %r, want %r" % (conf, rc, calls, want)]
    return []


def check_postinst(root):
    """check the postinst partial-directory block"""
    block = postinst_block(maint_inline.inlined(os.path.join(root, POSTINST)))
    if block is None:
        return ["postinst-partial-block: %s has no apt-config call ending in a `done` loop "
                "that hands apt's partial dirs to root" % POSTINST]
    fails = []
    why = postinst_context(maint_inline.inlined(os.path.join(root, POSTINST)))
    if why:
        fails.append("postinst-partial-context: %s: %s" % (POSTINST, why))
    with tempfile.TemporaryDirectory() as work:
        rc, out, calls, asked, fx = run_block(block, work)
        want = []
        for d in ("lists/partial", "lists/auxfiles", "archives/partial"):
            p = os.path.join(fx, d)
            want += ["root:root " + p, "-R root:root " + p]
        if "Dir::State::lists/d" not in asked or "Dir::Cache::archives/d" not in asked:
            fails.append("postinst-partial-block: the block asks apt-config for %r, want "
                         "Dir::State::lists/d and Dir::Cache::archives/d" % asked)
        if rc != 0:
            fails.append("postinst-partial-block: the block exits %d on a clean run: %s" % (rc, out.strip()))
        elif calls != want:
            fails.append("postinst-partial-order: the block ran chown %r, want each of "
                         "lists/partial, lists/auxfiles, archives/partial handed to "
                         "root:root before its contents: %r" % (calls, want))
    with tempfile.TemporaryDirectory() as work:
        rc, out, calls, _, fx = run_block(block, work, apt_config=os.path.join(work, "invoker.conf"))
        want = []
        for d in ("lists/partial", "lists/auxfiles", "archives/partial"):
            p = os.path.join(fx, d)
            want += ["root:root " + p, "-R root:root " + p]
        if rc != 0 or calls != want:
            fails.append("postinst-apt-config-invoker: run by an apt whose APT_CONFIG names its own "
                         "lists and archives, the block exits %d after chown %r, want the system "
                         "config's dirs %r" % (rc, calls, want))
    fails += check_postinst_real_apt_config(block)
    with tempfile.TemporaryDirectory() as work:
        rc, out, calls, _, _ = run_block(block, work, chown_fail=True)
        if rc == 0:
            fails.append("postinst-partial-failure: the block exits 0 when chown fails")
    with tempfile.TemporaryDirectory() as work:
        rc, out, calls, _, _ = run_block(block, work, empty=True)
        if rc == 0 or calls:
            fails.append("postinst-apt-config-empty: with apt-config naming no directory the "
                         "block exits %d after chown %r, want a non-zero exit before any chown"
                         % (rc, calls))
    return fails


def maintscript_version(root):
    """return the version of the one rm_conffile line for the apt file, or None"""
    if not os.path.isfile(os.path.join(root, MAINTSCRIPT)):
        return None
    hits = [m.group(1) for m in (RM_CONFFILE.match(l.strip()) for l in read(root, MAINTSCRIPT).splitlines()) if m]
    return hits[0] if len(hits) == 1 else None


def changelog_version(root):
    """return the changelog's top version"""
    return subprocess.run(["dpkg-parsechangelog", "-l", os.path.join(root, CHANGELOG), "-SVersion"],
                          capture_output=True, text=True, check=True).stdout.strip()


def version_lt(a, b):
    """return whether dpkg sorts a below b"""
    return subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0


def build_maintscript_deb(root, work, version, maintscript):
    """build an empty rhizo package with a given maintscript"""
    src = os.path.join(work, "src-" + version)
    os.makedirs(os.path.join(src, "debian"))
    with open(os.path.join(src, MAINTSCRIPT), "w") as fh:
        fh.write(maintscript)
    with open(os.path.join(src, "debian", "control"), "w") as fh:
        fh.write("Source: rhizo\nSection: misc\nPriority: optional\n"
                 "Maintainer: fixture <fixture@example.invalid>\n"
                 "Build-Depends: debhelper-compat (= %s)\nStandards-Version: 4.6.2\n"
                 "Rules-Requires-Root: no\n\nPackage: rhizo\nArchitecture: all\n"
                 "Description: maintscript fixture\n fixture\n" % compat_level(root))
    with open(os.path.join(src, "debian", "changelog"), "w") as fh:
        fh.write("rhizo (%s) unstable; urgency=medium\n\n  * fixture\n\n"
                 " -- fixture <fixture@example.invalid>  Thu, 01 Jan 2026 00:00:00 +0000\n" % version)
    rules = os.path.join(src, "debian", "rules")
    with open(rules, "w") as fh:
        fh.write("#!/usr/bin/make -f\n%:\n\tdh $@\n")
    os.chmod(rules, 0o755)
    res = subprocess.run(["dpkg-buildpackage", "-b", "-us", "-uc", "-d"], cwd=src, capture_output=True, text=True)
    deb = os.path.join(work, "rhizo_%s_all.deb" % version)
    if res.returncode != 0 or not os.path.isfile(deb):
        tail = (res.stdout + res.stderr).strip().splitlines()[-5:]
        return None, "dpkg-buildpackage rc=%d: %s" % (res.returncode, " | ".join(tail))
    return deb, None


def scratch_root(work, name):
    """make an empty dpkg root"""
    rootdir = os.path.join(work, name)
    for d in ("var/lib/dpkg/info", "var/lib/dpkg/updates", "var/lib/dpkg/triggers"):
        os.makedirs(os.path.join(rootdir, d))
    for f in ("var/lib/dpkg/status", "var/lib/dpkg/available"):
        open(os.path.join(rootdir, f), "w").close()
    return rootdir


def upgrade_findings(root, work, top, maintscript):
    """return the problems of an upgrade with the maintscript"""
    prev = build_handmade_deb(work, CONFFILE_DEST, True, LAST_CONFFILE_RELEASE)
    new, err = build_maintscript_deb(root, work, top, maintscript)
    later, err_later = build_maintscript_deb(root, work, top + "+later", maintscript)
    if err or err_later:
        return ["maintscript-upgrade: the fixture package did not build: %s" % (err or err_later)]
    fails = []
    dest = CONFFILE_DEST.lstrip("/")
    for case in ("kept as shipped", "edited"):
        rootdir = scratch_root(work, "root-" + case.replace(" ", "-"))
        steps = [dpkg_root(rootdir, "-i", prev)]
        if case == "edited":
            with open(os.path.join(rootdir, dest), "a") as fh:
                fh.write('Acquire::Retries "3";\n')
        steps.append(dpkg_root(rootdir, "-i", new))
        if any(r.returncode != 0 for r in steps):
            fails.append("maintscript-upgrade: dpkg on a scratch root failed: %s" %
                         " | ".join(r.stderr.strip()[-300:] for r in steps if r.returncode != 0))
            continue
        left = sorted(n for n in os.listdir(os.path.join(rootdir, os.path.dirname(dest))))
        want = ["50rhizo.dpkg-bak"] if case == "edited" else []
        if left != want:
            fails.append("maintscript-upgrade: an upgrade from %s with the apt file %s leaves %r in %s, want %r" %
                         (LAST_CONFFILE_RELEASE, case, left, os.path.dirname(CONFFILE_DEST), want))
        if case == "kept as shipped" and left == want:
            os.symlink(HOST_MODE_DEST, os.path.join(rootdir, dest))
            res = dpkg_root(rootdir, "-i", later)
            if res.returncode != 0 or not os.path.islink(os.path.join(rootdir, dest)):
                fails.append("maintscript-later-upgrade: an upgrade from %s to %s took host mode's link at %s "
                             "(rc=%d %s)" % (top, top + "+later", CONFFILE_DEST, res.returncode,
                                             res.stderr.strip()[-300:]))
    return fails


UPGRADE_FINDINGS = {}


def check_maintscript(root):
    """return the problems with removing the old apt conffile"""
    version = maintscript_version(root)
    if version is None:
        return ["maintscript-rm-conffile: %s has no one `rm_conffile %s <version>~` line, so an upgrade from %s "
                "keeps the conffile in every mode" % (MAINTSCRIPT, CONFFILE_DEST, LAST_CONFFILE_RELEASE)]
    top = changelog_version(root)
    if version != top or not version_lt(LAST_CONFFILE_RELEASE, version + "~"):
        return ["maintscript-version: rm_conffile names %s~, want the changelog's %s~, the first release without "
                "the conffile, above %s" % (version, top, LAST_CONFFILE_RELEASE)]
    lines = [l.strip() for l in read(root, MAINTSCRIPT).splitlines()]
    for path in OBSOLETE_CONFFILES:
        if lines.count("rm_conffile %s %s~" % (path, top)) != 1:
            return ["maintscript-rm-conffile: %s has no one `rm_conffile %s %s~` line, so an upgrade from %s keeps "
                    "that conffile in every mode" % (MAINTSCRIPT, path, top, LAST_CONFFILE_RELEASE)]
    missing = [t for t in BUILD_TOOLS if shutil.which(t) is None]
    if missing:
        return ["tool-missing: %s not on PATH (apt install debhelper fakeroot dpkg-dev)" % ", ".join(missing)]
    key = (read(root, MAINTSCRIPT), top, compat_level(root))
    if key not in UPGRADE_FINDINGS:
        with tempfile.TemporaryDirectory() as work:
            UPGRADE_FINDINGS[key] = upgrade_findings(root, work, top, key[0])
    return list(UPGRADE_FINDINGS[key])


def check(root, verbose=True):
    """return the problems from every check and print them"""
    fails = (check_conffile(root) + check_rules(root) + check_package(root) +
             check_packaging_files(root) + check_maintscript(root) + check_postinst(root))
    if verbose:
        for f in fails:
            print("FAIL: " + f)
        if not fails:
            print("apt sandbox: %s is a host-mode payload file only host mode links to %s, no conffile, an upgrade "
                  "from %s removes the conffile, and its partial dirs handed to root in host mode"
                  % (HOST_MODE_DEST, CONFFILE_DEST, LAST_CONFFILE_RELEASE))
    return fails


FIXTURE_FILES = (CONFFILE_SRC, RULES, CONTROL, CHANGELOG, MAINTSCRIPT, PKG_LIB) + SCRIPTS


def make_fixture(tmp):
    """copy the checked files into a fixture tree"""
    for rel in FIXTURE_FILES:
        dst = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), dst)


def edit(tmp, rel, old, new, count=1):
    """replace a text in a fixture file"""
    path = os.path.join(tmp, rel)
    text = open(path).read()
    assert text.count(old) >= 1, "selftest fixture edit found no %r in %s" % (old, rel)
    with open(path, "w") as fh:
        fh.write(text.replace(old, new, count))


def build_handmade_deb(work, dest, conffile, version="0.0.1"):
    """write a .deb that ships 50rhizo at dest"""
    pkg = os.path.join(work, "pkg-" + version)
    os.makedirs(os.path.join(pkg, "DEBIAN"))
    path = os.path.join(pkg, dest.lstrip("/"))
    os.makedirs(os.path.dirname(path))
    with open(path, "w") as fh:
        fh.write(WANT_STATEMENT + "\n")
    with open(os.path.join(pkg, "DEBIAN", "control"), "w") as fh:
        fh.write("Package: rhizo\nVersion: %s\nArchitecture: all\n"
                 "Maintainer: fixture <fixture@example.invalid>\nDescription: fixture\n" % version)
    if conffile:
        with open(os.path.join(pkg, "DEBIAN", "conffiles"), "w") as fh:
            fh.write(dest + "\n")
    deb = os.path.join(work, "handmade-%s.deb" % version)
    subprocess.run(["fakeroot", "dpkg-deb", "-b", pkg, deb], check=True, capture_output=True)
    return deb


def selftest():
    """test the apt host-mode file checks on fixtures"""
    asserts = 0
    missing = [t for t in BUILD_TOOLS if shutil.which(t) is None]
    if missing:
        print("check-apt-sandbox selftest: FAILED, %s not on PATH" % ", ".join(missing))
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        make_fixture(tmp)
        fails = check(tmp, verbose=False)
        assert not fails, "the tree's own files must pass clean, got:\n" + "\n".join(fails)
        asserts += 1
        for name in ("rhizo.postinst.debhelper", "rhizo.substvars", "rhizo.debhelper.log"):
            with open(os.path.join(tmp, "debian", name), "w") as fh:
                fh.write("dpkg-maintscript-helper rm_conffile /etc/apt/apt.conf.d/50rhizo 0.1.4~ -- \"$@\"\n")
        listed = packaging_files(tmp)
        assert not any(r.endswith(DH_GENERATED_SUFFIXES) for r in listed), \
            "dh's generated outputs must not count as packaging files, got %s" % listed
        assert "debian/rhizo.postinst" in listed, "the real maintainer script must stay listed, got %s" % listed
        asserts += 1

    postinst_chown = 'chown root:root "$d" && chown -R root:root "$d"'
    cases = [
        ("the conffile drops back to _apt", CONFFILE_SRC,
         'APT::Sandbox::User "root";', 'APT::Sandbox::User "_apt";', "conffile-content"),
        ("the conffile grows a second statement", CONFFILE_SRC,
         'APT::Sandbox::User "root";', 'APT::Sandbox::User "root";\nAcquire::Retries "3";',
         "conffile-content"),
        ("debian/rules stops installing it", RULES,
         INSTALL_LINE_TEXT, "\t: debian/apt.conf.d/50rhizo\n",
         "rules-install"),
        ("debian/rules installs it straight into /etc/apt again", RULES,
         WANT_DEST, "debian/rhizo" + CONFFILE_DEST, "rules-install"),
        ("debian/rules installs it straight into /etc/apt again, so the package ships it in every mode", RULES,
         WANT_DEST, "debian/rhizo" + CONFFILE_DEST, "host-mode-only"),
        ("a later hook copies the host-mode file into /etc/apt", RULES,
         "override_dh_strip:\n",
         "execute_after_dh_install:\n\tinstall -D -m 0644 " + CONFFILE_SRC + " debian/rhizo" + CONFFILE_DEST +
         "\noverride_dh_strip:\n", "host-mode-only"),
        ("the maintscript names the release that last shipped the conffile", MAINTSCRIPT,
         "50rhizo 0.1.4~", "50rhizo 0.1.3~", "maintscript-version"),
        ("the maintscript names a release after this one", MAINTSCRIPT,
         "50rhizo 0.1.4~", "50rhizo 9.9.9~", "maintscript-version"),
        ("the maintscript keeps profile.d's console file", MAINTSCRIPT,
         "rm_conffile /etc/profile.d/rhizo-console-vt.sh 0.1.4~\n", "", "maintscript-rm-conffile"),
        ("the maintscript names a release before this one that still shipped the conffile", MAINTSCRIPT,
         "50rhizo 0.1.4~", "50rhizo 0.1.3.1~", "maintscript-version"),
        ("a second maintscript line removes the apt file on every upgrade", MAINTSCRIPT,
         "50rhizo 0.1.4~\n", "50rhizo 0.1.4~\nrm_conffile /etc/apt/apt.conf.d/50rhizo\n",
         "packaging-touches-apt-file"),
        ("the postrm deletes the apt file itself", "debian/rhizo.postrm.in",
         "set -e\n", "set -e\nrm -f /etc/apt/apt.conf.d/50rhizo\n", "packaging-touches-apt-file"),
        ("the postinst walks partial/ before owning it", PKG_LIB,
         postinst_chown, 'chown -R root:root "$d" && chown root:root "$d"', "postinst-partial-order"),
        ("the postinst forgets lists/auxfiles", PKG_LIB,
         '"${APT_LISTS}auxfiles" ', "", "postinst-partial-order"),
        ("the postinst swallows a failed chown", PKG_LIB,
         "apt cannot download under Rhizo's policy until it is\" >&2\n      return 1",
         "apt cannot download under Rhizo's policy until it is\" >&2\n      true",
         "postinst-partial-failure"),
        ("the postinst trusts an empty apt-config answer", PKG_LIB,
         '  if [ -z "$APT_LISTS" ] || [ -z "$APT_ARCHIVES" ]; then',
         '  if false; then', "postinst-apt-config-empty"),
        ("the postinst block is gone", PKG_LIB,
         'eval "$(APT_CONFIG=\'\' apt-config shell', '# eval "$(APT_CONFIG= apt-config shell',
         "postinst-partial-block"),
        ("the postinst asks the invoking apt's APT_CONFIG for the dirs", PKG_LIB,
         'eval "$(APT_CONFIG=\'\' apt-config shell', 'eval "$(apt-config shell',
         "postinst-apt-config-invoker"),
        ("a later rules line deletes the installed host-mode file", RULES,
         INSTALL_LINE_TEXT, INSTALL_LINE_TEXT + "\trm -f $(PAYLOAD)/host-mode/etc/apt/apt.conf.d/50rhizo\n",
         "packaging-touches-apt-file"),
        ("the install line sits in an arm64-only conditional", RULES,
         INSTALL_LINE_TEXT, "ifeq ($(DEB_HOST_ARCH),arm64)\n" + INSTALL_LINE_TEXT + "endif\n",
         "rules-install"),
        ("an execute_after_dh_installdeb hook registers the apt file as a conffile", RULES,
         "override_dh_strip:\n",
         "execute_after_dh_installdeb:\n\techo /usr/lib/rhizo/host-mode/etc/apt/apt.conf.d/50rhizo"
         " >> debian/rhizo/DEBIAN/conffiles\noverride_dh_strip:\n", "host-mode-only"),
        ("the postinst runs the block in both modes", POSTINST,
         '    if [ "$PKG_MODE" = host ]; then\n      pkg_apt_partial_root',
         '    if true; then\n      pkg_apt_partial_root', "postinst-partial-context"),
        ("the postinst leaves configure before the block", POSTINST,
         '      pkg_apt_partial_root\n', '      exit 0\n      pkg_apt_partial_root\n',
         "postinst-partial-context"),
        ("a library step the postinst calls leaves before the block", PKG_LIB,
         "  systemctl daemon-reload\n", "  systemctl daemon-reload\n  exit 0\n", "postinst-partial-context"),
        ("a library step reached through a continued call leaves before the block", PKG_LIB,
         '--shell /usr/bin/nologin "$1"\n  fi\n', '--shell /usr/bin/nologin "$1"\n  fi\n  exit 0\n',
         "postinst-partial-context"),
        ("a library step the maintainer scripts run names the apt file", PKG_LIB,
         "  systemctl daemon-reload\n", "  systemctl daemon-reload\n  rm -f /etc/apt/apt.conf.d/50rhizo\n",
         "packaging-touches-apt-file"),
    ]
    for name, rel, old, new, finding in cases:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(tmp)
            edit(tmp, rel, old, new)
            fails = check(tmp, verbose=False)
            assert any(f.startswith(finding + ":") for f in fails), (
                "planted defect not caught by name (%s): expected %s, got:\n%s" %
                (name, finding, "\n".join(fails) if fails else "(clean)"))
            asserts += 1

    def move_install_line(tmp):
        """move the install line out of the install target"""
        edit(tmp, RULES, INSTALL_LINE_TEXT, "")
        edit(tmp, RULES, "print-ship-set:\n", "print-ship-set:\n" + INSTALL_LINE_TEXT)

    def links_to_dev_null(tmp):
        """link the apt configuration file to /dev/null"""
        with open(os.path.join(tmp, "debian", "rhizo.links"), "w") as fh:
            fh.write("dev/null etc/apt/apt.conf.d/50rhizo\n")

    def first_install_only(tmp):
        """wrap the postinst's partial-dir call in a first-install-only guard"""
        call = "      pkg_apt_partial_root\n"
        edit(tmp, POSTINST, call, '      if [ -z "$2" ]; then\n  ' + call + "      fi\n")

    def no_maintscript(tmp):
        """delete the maintscript"""
        os.remove(os.path.join(tmp, MAINTSCRIPT))

    planted = [
        ("the maintscript is gone", no_maintscript, "maintscript-rm-conffile"),
        ("the install line moves to a target the build never runs", move_install_line, "rules-install"),
        ("a links file points the apt file at /dev/null", links_to_dev_null, "packaging-touches-apt-file"),
        ("the postinst block runs on first install only", first_install_only, "postinst-partial-context"),
    ]
    for name, plant, finding in planted:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(tmp)
            plant(tmp)
            fails = check(tmp, verbose=False)
            assert any(f.startswith(finding + ":") for f in fails), (
                "planted defect not caught by name (%s): expected %s, got:\n%s" %
                (name, finding, "\n".join(fails) if fails else "(clean)"))
            asserts += 1

    with tempfile.TemporaryDirectory() as tmp:
        make_fixture(tmp)
        edit(tmp, "debian/rhizo.postrm.in", "set -e\n", "set -e\n# 50rhizo goes with the host-mode links\n")
        fails = check_packaging_files(tmp)
        assert not fails, "a comment was read as a script touching the apt file: %r" % fails
        asserts += 1

    with tempfile.TemporaryDirectory() as work:
        deb = build_handmade_deb(work, dest=HOST_MODE_DEST, conffile=False)
        fails = assert_host_mode_package(deb, None, work)
        assert not fails, "a hand-built host-mode package must pass clean: %r" % fails
        asserts += 1
    with tempfile.TemporaryDirectory() as work:
        deb = build_handmade_deb(work, dest=CONFFILE_DEST, conffile=True)
        fails = assert_host_mode_package(deb, None, work)
        assert any(f.startswith("host-mode-only:") for f in fails), (
            "a package shipping %s as a conffile was not caught: %r" % (CONFFILE_DEST, fails))
        assert any(f.startswith("host-mode-payload:") for f in fails), (
            "a package with no host-mode copy was not caught: %r" % fails)
        asserts += 2
    with tempfile.TemporaryDirectory() as work:
        deb = build_handmade_deb(work, dest=HOST_MODE_DEST, conffile=True)
        fails = assert_host_mode_package(deb, None, work)
        assert any(f.startswith("host-mode-only:") for f in fails), (
            "a package registering its host-mode copy as a conffile was not caught: %r" % fails)
        asserts += 1

    with tempfile.TemporaryDirectory() as work:
        fails = upgrade_findings(ROOT, work, changelog_version(ROOT), "")
        assert sum(f.startswith("maintscript-upgrade:") for f in fails) == 2, (
            "an upgrade with no rm_conffile kept the apt file unflagged: %r" % fails)
        asserts += 1

    print("check-apt-sandbox selftest: %d assertions, %d planted defects each named" %
          (asserts, len(cases) + len(planted) + 4))
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=ROOT)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return 1 if check(args.root) else 0


if __name__ == "__main__":
    sys.exit(main())
