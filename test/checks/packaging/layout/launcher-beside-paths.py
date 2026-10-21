#!/usr/bin/env python3

import fcntl
import glob
import importlib.util
import itertools
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
PACKAGE_LIB = "/usr/lib/rhizo"
FETCH = os.path.join(REPO, "src", "install", "prepare", "fetch-gsi.sh")
PREPARE = os.path.join(REPO, "src", "install", "prepare", "prepare.sh")
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
PREPARE_UNIT = os.path.join(REPO, "src", "services", "units", "boot", "prepare.service")
DERIVE_PATCHES = os.path.join(REPO, "src", "install", "prepare", "derive-patches.sh")
GSI_PINS = os.path.join(REPO, "tools", "fetch", "gsi-pins.sh")


def write_rig_pins(path):
    """write the test rigs' extra releases from gsi-pins.sh as the tab-separated file fetch-gsi reads"""
    with open(GSI_PINS) as f:
        text = f.read()
    rows = []
    for rel in sorted(set(re.findall(r'^GSI_URL\[([\w-]+)\]=', text, re.M)) - {"a16"}):
        url, sha, desc = (re.search(r'^GSI_%s\[%s\]="([^"]*)"' % (k, re.escape(rel)), text, re.M).group(1)
                          for k in ("URL", "SHA", "DESC"))
        rows.append("\t".join((rel, url, sha, desc)))
    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")

PRODUCED = {
    "share/gsi_libs": ("gsi_libs", "src/install/prepare/fetch-gsi.sh"),
    "product-build.prop": ("patches", "src/install/prepare/fetch-gsi.sh"),
}
ABSENT = {
    "adbkey.pub": "the operator's own adb key; without one adb authorizes a key on first connect",
    "com.android.tethering.apex": "a patched GSI apex the product never derives; the GSI's own runs",
    "RhizoLockIconOverlay.apk": "rig-only, staged only under RHIZO_STAGE_ICON_OVERLAY=1",
}

_BESIDE = re.compile(r"\bbeside\(")


def _call_args(code, start):
    """return the text between the parentheses"""
    depth = 0
    for i in range(start, len(code)):
        depth += {"(": 1, ")": -1}.get(code[i], 0)
        if depth == 0:
            return code[start + 1:i]
    return None


def _deploy_parity():
    """return the deploy layout parity module loaded from its file"""
    spec = importlib.util.spec_from_file_location("check_deploy_layout_parity",
                                                  os.path.join(HERE, "deploy-layout-parity.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def launcher_texts(repo=REPO):
    """return the text of the launcher sources keyed by path"""
    paths = [os.path.join(repo, "src", "androidd", "boot.py")] + sorted(glob.glob(os.path.join(repo, "src", "androidd", "sandbox", "*.py")))
    return {os.path.relpath(p, repo): open(p).read() for p in paths}


def _accessor_defaults(name, env_text):
    """return the literal defaults a core accessor can return"""
    m = re.search(r"^def %s\(\):\n((?:[ \t].*\n|\n)*)" % re.escape(name), env_text, re.M)
    if not m:
        return None
    one = re.search(r'return\s+os\.environ\.get\(\s*[\"\']\w+[\"\']\s*,\s*(["\'])([\w./-]+)\1\s*\)\s*$',
                    m.group(1), re.M)
    if one:
        return [one.group(2)]
    two = re.search(r'return\s+os\.environ\.get\(\s*["\']\w+["\']\s*\)\s+or\s+\(\s*(["\'])([\w./-]+)\1\s+if\s+\w+\(\)'
                    r'\s+else\s+(["\'])([\w./-]+)\3\s*\)\s*$', m.group(1), re.M)
    return [two.group(2), two.group(4)] if two else None


def _resolve(arg, text, seen=(), env_text=None):
    """return the literal paths a beside() argument can name"""
    arg = arg.strip()
    m = re.fullmatch(r"""(["'])([\w./-]+)\1""", arg)
    if m:
        return [m.group(2)]
    if not re.fullmatch(r"[A-Za-z_]\w*", arg) or arg in seen:
        return None
    m = re.search(r"^\s*%s\s*=\s*os\.environ\.get\(\s*[\"']\w+[\"']\s*,\s*([^)]+?)\s*\)\s*$" % arg, text, re.M)
    if m:
        return _resolve(m.group(1), text, seen + (arg,), env_text)
    m = re.search(r"^\s*%s\s*=\s*core\.(\w+)\(\)\s*$" % arg, text, re.M)
    if m and env_text is not None:
        return _accessor_defaults(m.group(1), env_text)
    return None


def beside_refs(texts):
    """return the beside() paths and findings"""
    env_text = texts.get("src/androidd/sandbox/core.py")
    refs, bad = {}, []
    for rel, text in texts.items():
        for n, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            if code.lstrip().startswith("def "):
                continue
            for m in _BESIDE.finditer(code):
                inner = _call_args(code, m.end() - 1)
                if inner is None:
                    bad.append("%s:%d: a beside( call runs past its line"
                               % (rel, n))
                    continue
                args = [a for a in inner.split(",") if a.strip()]
                if not args:
                    continue
                parts = [_resolve(a, text, env_text=env_text) for a in args]
                if None in parts:
                    bad.append("%s:%d: beside(%s) names nothing this check can resolve to a literal path"
                               % (rel, n, inner.strip()))
                    continue
                for path in itertools.product(*parts):
                    refs.setdefault("/".join(path), []).append("%s:%d" % (rel, n))
    return refs, bad


def derived_defaults(env_text, teardown_text, fetch_text):
    """return the derived dir each site uses"""
    grab = lambda pat, text: (re.search(pat, text, re.M) or [None, None])[1]
    return {
        "src/androidd/sandbox/core.py RHIZO_DERIVED_DIR": grab(r'^RHIZO_DERIVED_DIR = os\.environ\.get\("RHIZO_DERIVED_DIR", "([^"]+)"\)', env_text),
        "src/install/teardown/teardown-lib.sh DERIVED_ROOT": grab(r"^RHIZO_TEARDOWN_LIB_DERIVED_ROOT=(\S+)$", teardown_text),
        "src/install/prepare/fetch-gsi.sh GSI_LIBS": grab(r"\$\{RHIZO_DERIVED_DIR:-([^}]+)\}/gsi_libs", fetch_text),
        "src/install/prepare/fetch-gsi.sh PATCHES": grab(r"\$\{RHIZO_DERIVED_DIR:-([^}]+)\}/patches", fetch_text),
    }


def installed_path_of(repo_rel, installed):
    """return the installed path of a repo script"""
    base = os.path.basename(repo_rel)
    hits = sorted(p for p in installed if p.startswith(PACKAGE_LIB + "/") and os.path.basename(p) == base)
    return hits[0] if len(hits) == 1 else None


def check_static(texts, installed, unit_text, defaults, produced=PRODUCED, absent=ABSENT):
    """return the beside references to files not shipped or produced"""
    refs, bad = beside_refs(texts)
    is_shipped = _deploy_parity()._is_shipped
    joined = "\n".join(texts.values())
    pre = [l[len("ExecStartPre="):] for l in unit_text.splitlines() if l.startswith("ExecStartPre=")]
    for rel, where in sorted(refs.items()):
        shipped = is_shipped(PACKAGE_LIB + "/" + rel, installed)
        if rel in absent:
            if shipped:
                bad.append("%s is shipped by debian/rules now -- drop its ABSENT row" % rel)
            continue
        if shipped:
            if rel in produced:
                bad.append("%s is shipped by debian/rules and also a PRODUCED row -- drop the row" % rel)
            continue
        if rel not in produced:
            bad.append("%s names %s/%s beside itself, which debian/rules never ships and nothing "
                       "produces before the setup boot" % (", ".join(where), PACKAGE_LIB, rel))
            continue
        name, producer = produced[rel]
        if not re.search(r"os\.path\.join\(\s*RHIZO_DERIVED_DIR\s*,\s*[\"']%s[\"']\s*\)" % re.escape(name), joined):
            bad.append("%s: the launcher never reads RHIZO_DERIVED_DIR/%s, so %s produces it for nothing"
                       % (rel, name, producer))
        at = installed_path_of(producer, installed)
        if at is None:
            bad.append("%s: its producer %s is not installed at exactly one payload path" % (rel, producer))
        elif not any(p.split()[0] == at for p in pre if p.split()):
            bad.append("%s: rhizo-prepare.service runs no ExecStartPre=%s" % (rel, at))
    for row in sorted(set(produced) | set(absent)):
        if row not in refs:
            bad.append("%s is a table row no beside() call names -- drop the unused row" % row)
    values = {v for v in defaults.values()}
    if None in values or len(values) != 1:
        bad.append("the derived dir differs between its sites: %s"
                   % ", ".join("%s=%s" % kv for kv in sorted(defaults.items())))
    return bad


def as_root():
    """return an euid 0 command prefix"""
    try:
        if subprocess.run(["unshare", "-r", "true"], capture_output=True).returncode == 0:
            return ["unshare", "-r"]
    except OSError:
        pass
    return ["fakeroot"] if shutil.which("fakeroot") else None


def fetch_lib_names(fetch_text):
    """return the library names listed in the fetch script"""
    m = re.search(r"^GSI_LIB_NAMES=\(\n(.*?)\n\)", fetch_text, re.M | re.S)
    return m.group(1).split() if m else []


STOCK_FILES = {
    "etc/init/netd.rc": "service netd /system/bin/netd\n    capabilities NET_ADMIN\n    onrestart restart zygote\n",
    "etc/init/surfaceflinger.rc": "service surfaceflinger /system/bin/surfaceflinger\n    onrestart restart zygote\n",
    "etc/init/vold.rc": "service vold /system/bin/vold\n    reboot_on_failure reboot,vold-failed\n",
    "system_ext/etc/gsi/init.vndk-nodef.rc": "on early-init\n    exec - root -- /system/bin/reboot bootloader\n",
    "product/etc/build.prop": "ro.product.product.name=scratch\n",
    "etc/init/hw/init.zygote64.rc": "service zygote /system/bin/app_process64\n    class main\n",
    "etc/init/hw/init.zygote64_32.rc": "service zygote /system/bin/app_process64\n    onrestart restart zygote\n",
    "etc/init/audioserver.rc": "service audioserver /system/bin/audioserver\n    class core\n"
                               "    group audio camera drmrpc media mediadrm net_bt net_bt_admin net_bw_acct wakelock\n"
                               "    onrestart restart audio_proxy_service\n"
                               "on property:init.svc.audioserver=stopped\n    stop audio_proxy_service\n"
                               "    start audio_proxy_service\n"
                               "on property:init.svc.audioserver=running\n    start audio_proxy_service\n"
                               "on property:sys.audio.restart.hal=1\n    stop audio_proxy_service\n"
                               "    start audio_proxy_service\n",
    "etc/init/mediametrics.rc": "service mediametrics /system/bin/mediametrics\n    class main\n",
}


def scratch_tree(srv, name, fingerprint, names):
    """create a scratch GSI tree under srv"""
    tree = os.path.join(srv, name)
    os.makedirs(os.path.join(tree, "bin"))
    os.makedirs(os.path.join(tree, "lib64"))
    with open(os.path.join(tree, "bin", "init"), "w") as f:
        f.write("init\n")
    with open(os.path.join(tree, "build.prop"), "w") as f:
        f.write("# scratch\n" + ("ro.system.build.fingerprint=%s\n" % fingerprint if fingerprint else ""))
    for n in names:
        with open(os.path.join(tree, "lib64", n), "w") as f:
            f.write("%s %s\n" % (fingerprint, n))
    for rel, body in STOCK_FILES.items():
        os.makedirs(os.path.dirname(os.path.join(tree, rel)), exist_ok=True)
        with open(os.path.join(tree, rel), "w") as f:
            f.write("# tree %s\n%s" % (name, body))
    return tree


class Scratch:
    """temporary host for fetch-gsi"""

    def __init__(self, tmp, prefix, fetch_path, launcher_path):
        """set up a fake server tree for the fetch script"""
        self.srv = os.path.join(tmp, "srv")
        self.derived = os.path.join(tmp, "derived")
        self.prefix, self.fetch_path, self.launcher_path = prefix, fetch_path, launcher_path
        with open(os.path.join(tmp, "attr"), "w") as f:
            f.write("kernel")
        self.env = dict(os.environ, RHIZO_GSI_ROOT=self.srv, RHIZO_DERIVED_DIR=self.derived,
                        RHIZO_CACHE_DIR=os.path.join(tmp, "cache"),
                        RHIZO_ATTR_CURRENT=os.path.join(tmp, "attr"),
                        RHIZO_DERIVE_PATCHES=DERIVE_PATCHES,
                        RHIZO_GSI_PINS=os.path.join(tmp, "gsi-pins.tsv"))
        write_rig_pins(self.env["RHIZO_GSI_PINS"])

    def fetch(self, *args):
        """run the fetch script"""
        done = subprocess.run(self.prefix + ["bash", self.fetch_path] + list(args), env=self.env,
                              capture_output=True, text=True)
        lines = done.stdout.strip().splitlines()
        return done.returncode, (lines[-1] if lines else ""), done.stderr

    def patches(self, tree):
        """return the stock patch dir for a tree"""
        code = ("import sys; sys.path.insert(0, %r); from sandbox import core; print(core.stock_patches_dir())"
                % os.path.dirname(self.launcher_path))
        done = subprocess.run([sys.executable, "-c", code], env=dict(self.env, RHIZO_GSI=tree),
                              capture_output=True, text=True)
        lines = done.stdout.strip().splitlines()
        return lines[-1] if done.returncode == 0 and lines else "rc=%d %s" % (done.returncode, done.stderr[-200:])

    def verdict(self, tree):
        """return the launcher result for a tree"""
        done = subprocess.run([sys.executable, self.launcher_path, "gsi-derived-check"],
                              env=dict(self.env, RHIZO_GSI=tree), capture_output=True, text=True)
        lines = [l for l in done.stdout.splitlines() if l.startswith("GSI_DERIVED_")]
        return done.returncode, (lines[-1] if lines else "no GSI_DERIVED_ line, rc=%d" % done.returncode)


def verdict_dir(verdict):
    """return the directory named in a verdict, or None"""
    m = re.search(r"\bdir=(\S+)", verdict)
    return m.group(1) if m else None


def check_reinstall(fetch_path, launcher_path=LAUNCHER):
    """run fetch-gsi on a kept tree"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        tree = scratch_tree(host.srv, "gsi_system", "rhizo/a16:user", names)
        derived = host.derived

        want = "GSI_DERIVED_OK dir=%s " % os.path.join(derived, "gsi_libs", "gsi_system")
        for leg in ("install", "reinstall after remove"):
            rc, last, err = host.fetch()
            if rc != 0 or last != "RHIZO_GSI_ALREADY_STAGED=1":
                bad.append("%s on a staged tree (%s) ended rc=%d %r: %s" % (fetch_path, leg, rc, last, err.strip()[-300:]))
            vrc, verdict = host.verdict(tree)
            if vrc != 0 or not verdict.startswith(want):
                bad.append("%s leaves what the launcher links missing from %s: %s"
                           % (leg, os.path.join(derived, "gsi_libs", "gsi_system"), verdict))
            shutil.rmtree(derived, ignore_errors=True)

        os.unlink(os.path.join(tree, "lib64", names[0]))
        rc, last, err = host.fetch()
        if rc == 0 or last != "RHIZO_GSI_FAILED reason=gsi-libs-missing" or names[0] not in err:
            bad.append("%s on a tree missing %s ended rc=%d %r, not a gsi-libs-missing failure naming it"
                       % (fetch_path, names[0], rc, last))
    return bad


def _foreign_libs(set_dir, tree, names):
    """return the libraries differing from the tree"""
    out = []
    for n in names:
        try:
            with open(os.path.join(set_dir, n), "rb") as a, open(os.path.join(tree, "lib64", n), "rb") as b:
                if a.read() != b.read():
                    out.append(n)
        except OSError:
            out.append(n)
    return out


def check_release_switch(fetch_path, launcher_path=LAUNCHER):
    """check per-tree library sets across releases"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        trees = {"a16": scratch_tree(host.srv, "gsi_system", "rhizo/a16:user", names),
                 "a17": scratch_tree(host.srv, "gsi_system_a17", "rhizo/a17:user", names)}
        os.makedirs(os.path.join(host.derived, "gsi_libs"))
        legacy = os.path.join(host.derived, "gsi_libs", names[0])
        with open(legacy, "w") as f:
            f.write("legacy\n")
        for rel in ("a16", "a17", "a16"):
            rc, last, err = host.fetch("--release", rel)
            if rc != 0 or last != "RHIZO_GSI_ALREADY_STAGED=1":
                bad.append("%s --release %s on a staged tree ended rc=%d %r: %s"
                           % (fetch_path, rel, rc, last, err.strip()[-300:]))
        if os.path.exists(legacy):
            bad.append("%s left the shared pre-per-tree set's %s in place" % (fetch_path, names[0]))
        for rel, tree in trees.items():
            vrc, verdict = host.verdict(tree)
            set_dir = verdict_dir(verdict)
            if vrc != 0 or not verdict.startswith("GSI_DERIVED_OK ") or not set_dir:
                bad.append("after a16, a17 and a16 again, a boot of the %s tree does not get a set: %s"
                           % (rel, verdict))
                continue
            foreign = _foreign_libs(set_dir, tree, names)
            if foreign:
                bad.append("after a16, a17 and a16 again, a boot of the %s tree links %d librar(ies) "
                           "copied from another release's tree, e.g. %s (%s)"
                           % (rel, len(foreign), foreign[0], verdict))

        a16_set = os.path.join(host.derived, "gsi_libs", "gsi_system")
        a17_set = os.path.join(host.derived, "gsi_libs", "gsi_system_a17")
        if os.path.isdir(a16_set) and os.path.isdir(a17_set):
            for n in os.listdir(a16_set):
                shutil.copyfile(os.path.join(a16_set, n), os.path.join(a17_set, n))
            vrc, verdict = host.verdict(trees["a17"])
            if vrc == 0 or not verdict.startswith("GSI_DERIVED_MISMATCH "):
                bad.append("a boot of the a17 tree accepts a set copied from the a16 tree: %s" % verdict)
            rc, last, err = host.fetch("--release", "a17", "--derive-only")
            if rc != 0 or last != "RHIZO_GSI_DERIVED release=a17 dir=%s" % a17_set:
                bad.append("%s --release a17 --derive-only ended rc=%d %r: %s"
                           % (fetch_path, rc, last, err.strip()[-300:]))
            vrc, verdict = host.verdict(trees["a17"])
            foreign = _foreign_libs(a17_set, trees["a17"], names)
            if vrc != 0 or foreign:
                bad.append("--derive-only did not give the a17 tree its own set back: %s, %d foreign"
                           % (verdict, len(foreign)))
        shutil.rmtree(trees["a17"])
        rc, last, err = host.fetch("--release", "a17", "--derive-only")
        if rc == 0 or last != "RHIZO_GSI_FAILED reason=not-staged":
            bad.append("%s --release a17 --derive-only with no a17 tree ended rc=%d %r, not a "
                       "not-staged failure" % (fetch_path, rc, last))
    return bad


def _first_line(path):
    """return the first line of a file, or the error in angle brackets"""
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError as e:
        return "<%s>" % e


def check_patches_per_tree(fetch_path, launcher_path=LAUNCHER):
    """check per-tree stock patches across releases"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        trees = {"a16": scratch_tree(host.srv, "gsi_system", "rhizo/a16:user", names),
                 "a15": scratch_tree(host.srv, "gsi_system_a15", "rhizo/a15:user", names)}
        os.makedirs(host.derived)
        legacy = os.path.join(host.derived, "netd.rc")
        with open(legacy, "w") as f:
            f.write("# tree legacy\n")
        for rel in ("a16", "a15", "a16"):
            rc, last, err = host.fetch("--release", rel, "--derive-only")
            if rc != 0 or not last.startswith("RHIZO_GSI_DERIVED release=%s " % rel):
                bad.append("%s --release %s --derive-only ended rc=%d %r: %s"
                           % (fetch_path, rel, rc, last, err.strip()[-300:]))
        if os.path.exists(legacy):
            bad.append("%s left the flat stock patch set every release shared in place" % fetch_path)
        for rel, tree in sorted(trees.items()):
            d = host.patches(tree)
            if not d or not os.path.isdir(d):
                bad.append("after a16, a15 and a16 again, a boot of the %s tree finds no stock patches "
                           "of its own: %s" % (rel, d))
                continue
            netd = os.path.join(d, "netd.rc")
            got = _first_line(netd)
            if got != "# tree %s" % os.path.basename(tree):
                bad.append("after a16, a15 and a16 again, a boot of the %s tree overlays %s, whose "
                           "first line is %r -- another tree's stock file" % (rel, netd, got))
                continue
            body = open(netd).read()
            if "BPF" not in body or "DISABLED by rhizo" not in body:
                bad.append("the %s tree's %s is its stock file unpatched" % (rel, netd))
        os.unlink(os.path.join(trees["a15"], "etc", "init", "vold.rc"))
        rc, last, err = host.fetch("--release", "a15", "--derive-only")
        if rc == 0 or last != "RHIZO_GSI_FAILED reason=stock-patches":
            bad.append("%s --release a15 --derive-only on a tree with no vold.rc ended rc=%d %r, not a "
                       "stock-patches failure" % (fetch_path, rc, last))
    return bad


def check_fingerprintless(fetch_path, launcher_path=LAUNCHER):
    """check fetch-gsi on a fingerprintless tree"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        tree = scratch_tree(host.srv, "gsi_system", None, names)
        set_dir = os.path.join(host.derived, "gsi_libs", "gsi_system")
        rc, last, err = host.fetch()
        if rc == 0 or last != "RHIZO_GSI_FAILED reason=gsi-libs-fingerprint":
            bad.append("%s derived a set from a tree with no fingerprint: rc=%d %r" % (fetch_path, rc, last))
        if os.path.exists(os.path.join(set_dir, "source")):
            bad.append("%s stamped a set from a tree with no fingerprint" % fetch_path)
        os.makedirs(set_dir, exist_ok=True)
        for n in names:
            shutil.copyfile(os.path.join(tree, "lib64", n), os.path.join(set_dir, n))
        with open(os.path.join(set_dir, "source"), "w") as f:
            f.write("tree=%s\nfingerprint=\n" % tree)
        vrc, verdict = host.verdict(tree)
        if vrc == 0 or not verdict.startswith("GSI_DERIVED_MISMATCH "):
            bad.append("a boot of a tree with no fingerprint accepts a set stamped with an empty one: %s" % verdict)
    return bad


def check_current_release(fetch_path, unit_text, launcher_path=LAUNCHER):
    """check the derived library sets for both trees"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    lines = [l[len("ExecStartPre="):].lstrip("-").split() for l in unit_text.splitlines()
             if l.startswith("ExecStartPre=")]
    lines = [argv[1:] for argv in lines if argv and argv[0].endswith("/fetch-gsi.sh")]
    if not lines:
        return ["rhizo-prepare.service runs no fetch-gsi.sh ExecStartPre"]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        envf = os.path.join(tmp, "androidd.env")
        with open(envf, "w") as f:
            f.write("# written by gsi-update.sh\nRHIZO_GSI=%s\nRHIZO_RELEASE=a17\n"
                    % os.path.join(host.srv, "gsi_system_a17"))
        host.env["RHIZO_ANDROIDD_ENV"] = envf
        trees = {"a16": scratch_tree(host.srv, "gsi_system", "rhizo/a16:user", names),
                 "a17": scratch_tree(host.srv, "gsi_system_a17", "rhizo/a17:user", names)}
        for argv in lines:
            host.fetch(*argv)
        for rel, tree in sorted(trees.items()):
            vrc, verdict = host.verdict(tree)
            want = "GSI_DERIVED_OK dir=%s " % os.path.join(host.derived, "gsi_libs", os.path.basename(tree))
            if vrc != 0 or not verdict.startswith(want):
                bad.append("a reinstall while a17 is the current release leaves the %s tree without its own "
                           "set after rhizo-prepare.service's fetch-gsi lines (%s): %s"
                           % (rel, "; ".join(" ".join(a) or "<no args>" for a in lines), verdict))
    return bad


def check_sha_refusal(fetch_path, launcher_path=LAUNCHER):
    """check the sha256 refusal of a tampered zip"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        scratch_tree(host.srv, "gsi_system_a17", "rhizo/a17:user", names[1:])
        tampered = os.path.join(tmp, "tampered.zip")
        with open(tampered, "wb") as f:
            f.write(os.urandom(4096))
        set_dir = os.path.join(host.derived, "gsi_libs", "gsi_system_a17")
        for mode in ([], ["--fetch-only"]):
            rc, last, err = host.fetch("--release", "a17", "--from-zip", tampered, *mode)
            leg = " ".join(["--release a17 --from-zip <tampered>"] + mode)
            if rc == 0 or last != "RHIZO_GSI_FAILED reason=sha256-mismatch":
                bad.append("%s %s on a staged tree ended rc=%d %r, not a sha256-mismatch refusal: %s"
                           % (fetch_path, leg, rc, last, err.strip()[-300:]))
            if os.path.exists(set_dir):
                bad.append("%s %s derived a set before refusing the zip" % (fetch_path, leg))
            if not os.path.isfile(tampered):
                bad.append("%s %s removed the caller's zip" % (fetch_path, leg))
    return bad


def _descendants(pid):
    """return the pids descended from pid"""
    parents = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as f:
                st = f.read()
            parents[int(d)] = int(st[st.rindex(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            continue
    out, frontier = set(), {pid}
    while frontier:
        frontier = {c for c, p in parents.items() if p in frontier and c not in out}
        out |= frontier
    return out


def _comm(pid):
    """return the command name of a process, or an empty string"""
    try:
        with open("/proc/%d/comm" % pid) as f:
            return f.read().strip()
    except OSError:
        return ""


def check_derive_lock(fetch_path, launcher_path=LAUNCHER):
    """check the --derive-only lock wait"""
    prefix = as_root()
    if prefix is None:
        return ["cannot run %s as root here: neither `unshare -r` nor fakeroot works" % fetch_path]
    names = fetch_lib_names(open(fetch_path).read())
    if not names:
        return ["%s has no GSI_LIB_NAMES=( ... ) array to build a scratch tree from" % fetch_path]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        host = Scratch(tmp, prefix, fetch_path, launcher_path)
        scratch_tree(host.srv, "gsi_system", "rhizo/a16:user", names)
        rc, last, err = host.fetch("--derive-only")
        stamp = os.path.join(host.derived, "gsi_libs", "gsi_system", "source")
        if rc != 0 or not os.path.isfile(stamp):
            return ["%s --derive-only on a staged tree ended rc=%d %r: %s" % (fetch_path, rc, last, err.strip()[-300:])]
        lock = os.open(os.path.join(host.derived, "gsi_libs", ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        proc = subprocess.Popen(host.prefix + ["bash", fetch_path, "--derive-only"], env=host.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        waiting = False
        for _ in range(3000):
            if proc.poll() is not None:
                break
            if any(_comm(p) == "flock" for p in _descendants(proc.pid)):
                waiting = True
                break
            time.sleep(0.02)
        if not waiting:
            bad.append("%s --derive-only ran on while another derive held %s/gsi_libs/.lock (%s)"
                       % (fetch_path, host.derived, "exited rc=%s" % proc.returncode
                          if proc.returncode is not None else "no flock seen in 60s"))
        elif not os.path.isfile(stamp):
            bad.append("%s --derive-only cleared the set's stamp before it held the lock" % fetch_path)
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        out, err = proc.communicate(timeout=120)
        lines = out.strip().splitlines()
        if proc.returncode != 0 or not lines or not lines[-1].startswith("RHIZO_GSI_DERIVED release=a16 "):
            bad.append("%s --derive-only after the lock was released ended rc=%d %r: %s"
                       % (fetch_path, proc.returncode, lines[-1] if lines else "", err.strip()[-300:]))
    return bad


def _top_level_line(text, pattern):
    """return the first line number matching a pattern, or None"""
    for n, line in enumerate(text.splitlines(), 1):
        if re.fullmatch(pattern, line):
            return n
    return None


def _lift(text, fn):
    """return the text of a shell function in a script, or None"""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(fn), text, re.M | re.S)
    return m.group(0) if m else None


def check_prepare(prepare_text, launcher_text):
    """check require_gsi_derived in the prepare script"""
    bad = []
    verb = re.search(r"launcher3\.py\" (gsi-derived-check)\b", prepare_text)
    if not verb or 'sys.argv[1] == "gsi-derived-check"' not in launcher_text:
        bad.append("prepare.sh never asks launcher3.py gsi-derived-check, or the launcher "
                   "dispatches no such verb")
    body = re.search(r'sys\.argv\[1\] == "prepare-tree":\n(.*?)sys\.exit\(prepare_tree_verb\(', launcher_text, re.S)
    if not body or "core.gsi_derived_missing()" not in body.group(1):
        bad.append("launcher3.py's prepare-tree verb builds a tree without asking gsi_derived_missing()")
    call = _top_level_line(prepare_text, r"(\(\( RESUME \)\) \|\| )?require_gsi_derived")
    tree = _top_level_line(prepare_text, r"(\(\( RESUME \)\) \|\| )?prepare_tree")
    boot = _top_level_line(prepare_text, r'\s*mark_change "setup boot run"')
    if call is None:
        bad.append("prepare.sh never calls require_gsi_derived at top level")
    elif tree is None or boot is None or not call < tree < boot:
        bad.append("prepare.sh calls require_gsi_derived at line %s, not before prepare_tree "
                   "(%s) and the setup boot (%s)" % (call, tree, boot))
    fn = _lift(prepare_text, "require_gsi_derived")
    if fn is None:
        return bad + ["prepare.sh defines no require_gsi_derived()"]
    for verdict, rc, want in (("GSI_DERIVED_MISSING dir=/d missing=libcppbor.so", 1, "failstop gsi-derived-missing"),
                              ("GSI_DERIVED_MISMATCH dir=/d why=copied from libcppbor.so's other tree", 1,
                               "failstop gsi-derived-mismatch"),
                              ("GSI_DERIVED_OK dir=/d n=12", 0, "returned")):
        script = ('failstop() { echo "failstop $1 $2"; exit 1; }\n'
                  'python3() { echo "L3: noise"; echo "%s"; return %d; }\n'
                  'PAYLOAD=/p GSI=/g\n%s\nrequire_gsi_derived; echo returned\n' % (verdict, rc, fn))
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout
        if want not in out or (rc and "libcppbor.so" not in out):
            bad.append("require_gsi_derived given %r printed %r, not %r naming the file"
                       % (verdict, out.strip(), want))
    return bad


def check(repo=REPO, fetch_path=FETCH):
    """return the problems with the launcher's beside paths in the repo"""
    rules = open(os.path.join(repo, "debian", "rules")).read()
    installed = _deploy_parity().deb_installed_paths(rules)
    unit_text = open(os.path.join(repo, "src", "services", "units", "boot", "prepare.service")).read()
    defaults = derived_defaults(open(os.path.join(repo, "src", "androidd", "sandbox", "core.py")).read(),
                                open(os.path.join(repo, "src", "install", "teardown", "teardown-lib.sh")).read(),
                                open(fetch_path).read())
    texts = launcher_texts(repo)
    bad = check_static(texts, installed, unit_text, defaults)
    bad += check_reinstall(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_release_switch(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_patches_per_tree(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_fingerprintless(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_current_release(fetch_path, unit_text, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_sha_refusal(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_derive_lock(fetch_path, os.path.join(repo, "src", "androidd", "boot.py"))
    bad += check_prepare(open(os.path.join(repo, "src", "install", "prepare", "prepare.sh")).read(),
                         texts["src/androidd/boot.py"])
    return bad


def selftest():
    """run the checks against good and bad fixtures"""
    fails = []

    def expect(name, findings, needle):
        """check the findings name the needle"""
        hit = any(needle in f for f in findings)
        if needle and not hit:
            fails.append("%s: no finding naming %r in %r" % (name, needle, findings))
        if not needle and findings:
            fails.append("%s: flagged %r" % (name, findings))

    unit = ("ExecStartPre=/usr/lib/rhizo/install/prepare/fetch-gsi.sh\n"
            "ExecStartPre=/usr/lib/rhizo/tools/derive-patches.sh --from-tree /t --out /d\n")
    installed = {"/usr/lib/rhizo/RhizoHome.apk", "/usr/lib/rhizo/gpu_driver",
                 "/usr/lib/rhizo/install/prepare/fetch-gsi.sh", "/usr/lib/rhizo/tools/derive-patches.sh"}
    same = {"a": "/d", "b": "/d", "c": "/d", "d": "/d"}
    produced = {"share/gsi_libs": ("gsi_libs", "src/install/prepare/fetch-gsi.sh")}
    good = ('GPU = os.environ.get("RHIZO_GPU", "gpu_driver")\n'
            'a = beside("RhizoHome.apk")\nb = beside(GPU)\n'
            'c = os.path.join(RHIZO_DERIVED_DIR, "gsi_libs")\nd = beside("share", "gsi_libs")\n'
            'e = beside("adbkey.pub")\n# beside("comment.bin")\ndef beside(*parts):\n')
    absent = {"adbkey.pub": "why"}
    expect("shipped, produced and absent paths", check_static({"m.py": good}, installed, unit, same, produced, absent), "")
    expect("an unshipped, unproduced path",
           check_static({"m.py": good + 'f = beside("rig-only.bin")\n'}, installed, unit, same, produced, absent),
           "rig-only.bin beside itself, which debian/rules never ships")
    expect("an unresolvable argument",
           check_static({"m.py": good + "f = beside(somewhere())\n"}, installed, unit, same, produced, absent),
           "names nothing this check can resolve")

    accessor_good = good + "GPU_DRIVER_DIR = core.gpu_driver_dir()\ng = beside(GPU_DRIVER_DIR)\n"
    env_good = 'def gpu_driver_dir():\n    return os.environ.get("RHIZO_GPU_DRIVER_DIR", "gpu_driver")\n'
    expect("an accessor call resolved from src/androidd/sandbox/core.py's own default",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_good},
                       installed, unit, same, produced, absent),
           "")
    env_changed = 'def gpu_driver_dir():\n    return os.environ.get("RHIZO_GPU_DRIVER_DIR", "gpu_driver_lavapipe")\n'
    expect("an accessor whose fixture default changed",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_changed},
                       installed, unit, same, produced, absent),
           "gpu_driver_lavapipe beside itself, which debian/rules never ships")
    env_computed = 'def gpu_driver_dir():\n    return os.environ.get("RHIZO_GPU_DRIVER_DIR", "gpu_driver") + ""\n'
    expect("an accessor whose default is computed, not a plain os.environ.get literal",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_computed},
                       installed, unit, same, produced, absent),
           "names nothing this check can resolve")
    env_switch = ('def gpu_driver_dir():\n    return os.environ.get("RHIZO_GPU_DRIVER_DIR") or '
                  '("gpu_driver_software" if software_rendering() else "gpu_driver")\n')
    expect("an accessor choosing between two shipped sets",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_switch},
                        installed | {"/usr/lib/rhizo/gpu_driver_software"}, unit, same, produced, absent),
           "")
    expect("an accessor choosing a set the package never ships",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_switch},
                        installed, unit, same, produced, absent),
           "gpu_driver_software beside itself, which debian/rules never ships")
    env_missing = "# this fixture's sandbox/core.py defines no gpu_driver_dir()\n"
    expect("an accessor the fixture sandbox/core.py never defines",
           check_static({"m.py": accessor_good, "src/androidd/sandbox/core.py": env_missing},
                       installed, unit, same, produced, absent),
           "names nothing this check can resolve")

    expect("an ABSENT row the package ships",
           check_static({"m.py": good}, installed | {"/usr/lib/rhizo/adbkey.pub"}, unit, same, produced, absent),
           "adbkey.pub is shipped by debian/rules now")
    expect("an unused row", check_static({"m.py": good}, installed, unit, same, produced,
                                       dict(absent, gone="why")), "gone is a table row")
    expect("a producer the prepare unit never runs",
           check_static({"m.py": good}, installed, unit.splitlines()[1] + "\n", same, produced, absent),
           "runs no ExecStartPre=/usr/lib/rhizo/install/prepare/fetch-gsi.sh")
    expect("a launcher that never reads the derived dir",
           check_static({"m.py": good.replace("RHIZO_DERIVED_DIR", "OTHER_DIR")}, installed, unit, same,
                        produced, absent), "never reads RHIZO_DERIVED_DIR/gsi_libs")
    expect("a derived dir teardown removes elsewhere",
           check_static({"m.py": good}, installed, unit, dict(same, b="/elsewhere"), produced, absent),
           "the derived dir differs between its sites")

    real_fetch = open(FETCH).read()
    with tempfile.TemporaryDirectory() as tmp:
        expect("the real fetch-gsi", check_reinstall(FETCH), "")
        prepare = os.path.join(tmp, "prepare")
        os.makedirs(prepare)
        os.makedirs(os.path.join(tmp, "lib"))
        shutil.copy(os.path.join(REPO, "src", "install", "lib", "host-flavor.sh"), os.path.join(tmp, "lib"))
        mutant = os.path.join(prepare, "fetch-staged-short-circuit.sh")
        body = real_fetch.replace('log "$TREE is already staged"; derive_gsi_libs; ',
                                  'log "$TREE is already staged"; ')
        if body == real_fetch:
            fails.append("the already-staged mutant changed nothing -- the anchor moved")
        open(mutant, "w").write(body)
        expect("a fetch-gsi whose already-staged exit skips the libraries", check_reinstall(mutant),
               "reinstall after remove leaves what the launcher links missing")
        lax = os.path.join(prepare, "fetch-lax.sh")
        body = real_fetch.replace('failstop "gsi-libs-missing"', 'log "gsi-libs-missing"')
        open(lax, "w").write(body)
        expect("a fetch-gsi that carries on past a missing library", check_reinstall(lax),
               "not a gsi-libs-missing failure")

        expect("the real fetch-gsi and launcher across a16, a17 and a16 again", check_release_switch(FETCH), "")
        per_tree = 'GSI_LIBS="$GSI_LIBS_ROOT/${TREE##*/}"\n'
        legacy_rm = '  for name in "${GSI_LIB_NAMES[@]}"; do rm -f "$GSI_LIBS_ROOT/$name"; done\n'
        env_per_tree = "    derived = os.path.join(root, os.path.basename(os.path.normpath(GSI)))\n"
        env_stamp = ('    d = gsi_libs_dir()\n'
                     '    if os.path.dirname(d) != os.path.join(RHIZO_DERIVED_DIR, "gsi_libs"):\n'
                     '        return None\n')
        derive_only = '  derive_gsi_libs\n  echo "RHIZO_GSI_DERIVED'

        def edited(text, name, pairs):
            """return the text with each old string replaced"""
            for old, new in pairs:
                if old not in text:
                    fails.append("%s: the anchor %r moved" % (name, old.strip()[:60]))
                text = text.replace(old, new)
            return text

        def write_mutant(name, src, pairs):
            """write an edited copy of a source"""
            path = os.path.join(prepare, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(edited(open(src).read(), name, pairs))
            return path

        def mutant_launcher(name, pairs):
            """copy the launcher beside an edited sandbox/core.py"""
            d = os.path.join(prepare, name)
            os.makedirs(os.path.join(d, "sandbox"))
            shutil.copy(LAUNCHER, d)
            for p in glob.glob(os.path.join(REPO, "src", "androidd", "sandbox", "*.py")):
                shutil.copy(p, os.path.join(d, "sandbox"))
            write_mutant(os.path.join(name, "sandbox/core.py"), os.path.join(REPO, "src", "androidd", "sandbox", "core.py"), pairs)
            return os.path.join(d, "boot.py")

        shared_fetch = write_mutant("fetch-shared-set.sh", FETCH,
                                    ((per_tree, 'GSI_LIBS="$GSI_LIBS_ROOT"\n'), (legacy_rm, "")))
        shared_launcher = mutant_launcher("shared-set", ((env_per_tree, "    derived = root\n"),
                                                         (env_stamp, "    return None\n")))
        expect("one set shared by every release, as before",
               check_release_switch(shared_fetch, shared_launcher), "copied from another release's tree")
        unstamped = mutant_launcher("unstamped", ((env_stamp, "    return None\n"),))
        expect("a launcher that never reads the set's stamp", check_release_switch(FETCH, unstamped),
               "accepts a set copied from the a16 tree")
        idle = write_mutant("fetch-derive-idle.sh", FETCH, ((derive_only, '  echo "RHIZO_GSI_DERIVED'),))
        expect("a --derive-only that derives nothing", check_release_switch(idle, LAUNCHER),
               "--derive-only did not give the a17 tree its own set back")

        expect("the real fetch-gsi and launcher across a16, a15 and a16 again", check_patches_per_tree(FETCH), "")
        no_patches = write_mutant("fetch-no-patches.sh", FETCH, (("  derive_stock_patches\n", ""),))
        expect("a fetch-gsi that derives only the libraries", check_patches_per_tree(no_patches, LAUNCHER),
               "finds no stock patches of its own")
        flat = write_mutant("fetch-flat-patches.sh", FETCH, (('PATCHES="$PATCHES_ROOT/${TREE##*/}"\n',
                                                              'PATCHES="$PATCHES_ROOT/flat"\n'),))
        flat_launcher = mutant_launcher("flat-patches", ((
            '    d = os.path.join(root, os.path.basename(os.path.normpath(GSI)))\n    return d if os.path.isdir(d) else None\n',
            '    d = os.path.join(root, "flat")\n    return d if os.path.isdir(d) else None\n'),))
        expect("one stock patch set shared by every release", check_patches_per_tree(flat, flat_launcher),
               "another tree's stock file")
        lax_patches = write_mutant("fetch-lax-patches.sh", FETCH, (
            ('    || failstop "stock-patches" "$DERIVE_PATCHES could not derive',
             '    || log "$DERIVE_PATCHES could not derive'),))
        expect("a fetch-gsi that carries on past an underivable stock file",
               check_patches_per_tree(lax_patches, LAUNCHER), "not a stock-patches failure")

        expect("the real fetch-gsi and launcher on a fingerprintless tree", check_fingerprintless(FETCH), "")
        fp_fetch = write_mutant("fetch-empty-fp.sh", FETCH, (('  [[ -n "$fp" ]] \\\n    || failstop "gsi-libs-fingerprint"',
                                                               '  true \\\n    || failstop "gsi-libs-fingerprint"'),))
        expect("a fetch-gsi that stamps an empty fingerprint", check_fingerprintless(fp_fetch, LAUNCHER),
               "derived a set from a tree with no fingerprint")
        fp_launcher = mutant_launcher("empty-fp", (("    if not GSI_FINGERPRINT:\n", "    if False:\n"),))
        expect("a launcher that matches an empty stamp to an empty fingerprint",
               check_fingerprintless(FETCH, fp_launcher),
               "accepts a set stamped with an empty one: GSI_DERIVED_OK")

        real_unit = open(PREPARE_UNIT).read()
        expect("the real prepare unit and fetch-gsi with a17 current", check_current_release(FETCH, real_unit), "")
        current_line = "ExecStartPre=-/usr/lib/rhizo/install/prepare/fetch-gsi.sh --release current --derive-only\n"
        if current_line not in real_unit:
            fails.append("the prepare unit's current-release line moved")
        expect("a prepare unit that derives only the default release",
               check_current_release(FETCH, real_unit.replace(current_line, "")),
               "leaves the a17 tree without its own set")
        blind_fetch = write_mutant("fetch-current-blind.sh", FETCH,
                                   (('  (( ${#files[@]} )) && r=$(sed -n \'s/^RHIZO_RELEASE=//p\' "${files[@]}" | tail -1)\n',
                                     '  r=""\n'),))
        expect("a fetch-gsi whose current release ignores androidd.env and the runtime file",
               check_current_release(blind_fetch, real_unit), "leaves the a17 tree without its own set")

        expect("the real fetch-gsi given a tampered zip for a staged tree", check_sha_refusal(FETCH), "")
        early = ('if [[ -n "$FROM_ZIP" ]]; then\n'
                 '  [[ -f "$FROM_ZIP" ]] || refuse "no-such-zip" "--from-zip \'$FROM_ZIP\' does not exist"\n'
                 '  have=$(sha256sum "$FROM_ZIP" | cut -d\' \' -f1)\n'
                 '  [[ "$have" == "$WANT" ]] || failstop "sha256-mismatch" "$FROM_ZIP is $have, the pin is $WANT"\n'
                 'fi\n')
        late_check = write_mutant("fetch-sha-late.sh", FETCH, ((early, ""),))
        expect("a fetch-gsi that proves a caller's zip only after the staged exit",
               check_sha_refusal(late_check), "not a sha256-mismatch refusal")

        expect("the real fetch-gsi while another derive holds the lock", check_derive_lock(FETCH), "")
        unlocked = write_mutant("fetch-unlocked.sh", FETCH,
                                (('  flock 8 || failstop "gsi-libs-lock" "cannot lock $GSI_LIBS_ROOT/.lock"\n', ""),))
        expect("a fetch-gsi whose derive takes no lock", check_derive_lock(unlocked),
               "ran on while another derive held")

    prepare, launcher = open(PREPARE).read(), open(LAUNCHER).read()
    expect("the real prepare", check_prepare(prepare, launcher), "")
    expect("a prepare that never calls the check",
           check_prepare(prepare.replace("\n(( RESUME )) || require_gsi_derived\n", "\n"), launcher),
           "never calls require_gsi_derived")
    moved = prepare.replace("\n(( RESUME )) || require_gsi_derived\n", "\n").replace(
        "\n(( RESUME )) || prepare_tree\n", "\n(( RESUME )) || prepare_tree\n(( RESUME )) || require_gsi_derived\n")
    expect("a prepare that checks after building the tree", check_prepare(moved, launcher),
           "not before prepare_tree")
    expect("a check that ignores the verdict",
           check_prepare(prepare.replace("(( rc == 0 )) && [[ \"$verdict\" == GSI_DERIVED_OK* ]] && return 0",
                                         "return 0"), launcher), "require_gsi_derived given")
    unasked = launcher.replace("        missing = core.gsi_derived_missing()\n", "        missing = []\n")
    if unasked == launcher:
        fails.append("the prepare-tree mutant changed nothing -- the anchor moved")
    expect("a prepare-tree verb that never asks", check_prepare(prepare, unasked),
           "prepare-tree verb builds a tree without asking")
    return fails


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        fails = selftest()
        for f in fails:
            print("check-launcher-beside-paths: FAIL selftest: %s" % f, file=sys.stderr)
        if fails:
            return 1
        print("check-launcher-beside-paths selftest: an unshipped unproduced beside() path, an unresolvable "
              "argument, a shipped ABSENT row, an unused row, a producer the prepare unit never runs, a launcher "
              "that skips the derived dir, a teardown/launcher derived-dir split, a fetch-gsi whose "
              "already-staged exit skips the libraries or tolerates a missing one, one set shared by every "
              "release, a launcher that links a set copied from another tree, a --derive-only that derives "
              "nothing, stock patches not derived, shared by every release or skipped past a missing stock "
              "file, a fetch-gsi or launcher that takes an empty fingerprint as a match, a reinstall that "
              "derives no set for the release androidd.env boots, a fetch-gsi that derives from a staged tree before "
              "refusing a tampered zip, a derive that takes no lock, and a prepare that checks late, never, or ignores the verdict each flagged; the real "
              "files pass")
        return 0
    if sys.argv[1:]:
        print("usage: launcher-beside-paths.py [--selftest]", file=sys.stderr)
        return 2
    bad = check()
    for f in bad:
        print("check-launcher-beside-paths: FAIL %s" % f, file=sys.stderr)
    if bad:
        return 1
    print("every path the launcher resolves beside itself ships in the .deb, is a reasoned ABSENT row, or is "
          "produced by an ExecStartPre of rhizo-prepare.service that rebuilds it from a kept tree after "
          "`apt remove`; prepare refuses a setup boot without the GSI libraries, by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
