#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
MANIFEST = os.path.join(REPO, "var", "pristine-dl", "ubuntu-24.04-server-cloudimg-amd64.manifest")
CONTROL = "debian/control"
CHANGELOG = "debian/changelog"
ROUND_TRIP = ("sudo apt install ./rhizo_*_amd64.deb\n"
              "```\nsudo rhizo uninstall --purge\n"
              "sudo apt purge linux-image-rhizo linux-headers-rhizo linux-image-7.1.0-rc1-rhizo linux-headers-7.1.0-rc1-rhizo\n"
              "sudo apt purge <the packages rhizo uninstall named>\nsudo reboot\n```\n")
APT_AUTOREMOVE = "/etc/apt/apt.conf.d/01autoremove"
ARCHIVE_ONLY = re.compile(r"^(Filename|Size|MD5sum|SHA1|SHA256|SHA512|Description-md5|Task|Supported):.*\n?", re.M)
KERNEL_ABI = re.compile(r"^linux-(image|modules|modules-extra|headers|tools)-\d")
SHIM = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/utsname.h>

int uname(struct utsname *u)
{
	int (*real)(struct utsname *) = (int (*)(struct utsname *))dlsym(RTLD_NEXT, "uname");
	int r = real(u);
	const char *rel = getenv("FAKE_UNAME_R");

	if (r == 0 && rel)
		snprintf(u->release, sizeof(u->release), "%s", rel);
	return r;
}
'''


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def run(cmd, **kw):
    """run a command and return its result"""
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600, **kw)


def stanzas(text):
    """map each Package to its stanza"""
    out = {}
    for st in text.strip().split("\n\n"):
        m = re.search(r"^Package: (\S+)", st, re.M)
        if m:
            out[m.group(1)] = st.strip()
    return out


def candidates(names):
    """return the archive stanzas apt holds for names"""
    return stanzas(run(["apt-cache", "show", "--no-all-versions"] + sorted(names)).stdout) if names else {}


class NoPackageLists(Exception):
    """apt lists lacking the image's packages"""


class Host:
    """a simulated dpkg state that apt-get -s reads"""

    def __init__(self, work, shim):
        """start from apt's configuration only"""
        self.work, self.shim, self.pkgs, self.auto, self.rc = work, shim, {}, set(), {}
        self.history, self.dpkglog, self.clock = os.path.join(work, "apt-log"), os.path.join(work, "dpkg-log"), 0
        parts = os.path.join(work, "apt.conf.d")
        os.makedirs(parts, exist_ok=True)
        with open(APT_AUTOREMOVE) as src, open(os.path.join(parts, "01autoremove"), "w") as dst:
            dst.write(src.read())
        self.conf = os.path.join(work, "apt.conf")
        with open(self.conf, "w") as f:
            f.write('Dir::Etc::Main "/dev/null";\nDir::Etc::Parts "%s";\n' % parts)

    def write(self):
        """write the status and extended_states files"""
        with open(os.path.join(self.work, "status"), "w") as f:
            for st in self.pkgs.values():
                head, _, rest = ARCHIVE_ONLY.sub("", st).partition("\n")
                f.write(head + "\nStatus: install ok installed\n" + rest + "\n\n")
            for name, st in self.rc.items():
                if name not in self.pkgs:
                    head, _, rest = ARCHIVE_ONLY.sub("", st).partition("\n")
                    f.write(head + "\nStatus: deinstall ok config-files\n" + rest + "\n\n")
        with open(os.path.join(self.work, "ext"), "w") as f:
            for name in sorted(self.auto & set(self.pkgs)):
                arch = re.search(r"^Architecture: (\S+)", self.pkgs[name], re.M).group(1)
                f.write("Package: %s\nArchitecture: %s\nAuto-Installed: 1\n\n" % (name, arch))

    def apt(self, args, kernel):
        """run apt-get -s on this state as if kernel were booted"""
        self.write()
        d = self.work
        env = dict(os.environ, FAKE_UNAME_R=kernel, LD_PRELOAD=self.shim, APT_CONFIG=self.conf)
        return run(["apt-get", "-s", "-o", "Dir::State::status=%s/status" % d,
                    "-o", "Dir::State::extended_states=%s/ext" % d, "-o", "Debug::NoLocking=1",
                    "-o", "Dir::Cache=%s" % d, "-o", "Dir::Cache::pkgcache=", "-o", "Dir::Cache::srcpkgcache="]
                   + args, env=env)


def baseline(host, names):
    """install the image's packages, closing a full upgrade's new kernel"""
    want, missing = set(names), set()
    for _ in range(6):
        host.pkgs = candidates(want)
        missing |= want - set(host.pkgs)
        r = host.apt(["install"], "0")
        need = set(re.findall(r"Depends: (\S+) but it is not installed", r.stdout + r.stderr))
        if not need:
            break
        want |= need
    host.auto = {n for n in host.pkgs if KERNEL_ABI.match(n)}
    return missing


def control_stanza(control, changelog):
    """build rhizo's binary control from debian/control"""
    para = next(p for p in control.split("\n\n") if re.search(r"^Package: rhizo$", p, re.M))
    fields = {}
    for m in re.finditer(r"^(Pre-Depends|Depends|Recommends|Suggests|Conflicts|Breaks|Replaces):((?:.*\n?)(?:[ \t].*\n?)*)",
                         para, re.M):
        items = [re.sub(r"\s*\[[^]]*\]", "", i.strip()) for i in " ".join(m.group(2).split()).split(",")]
        fields[m.group(1)] = ", ".join(i for i in items if i and not i.startswith("${"))
    version = re.match(r"rhizo \(([^)]+)\)", changelog).group(1)
    out = "Package: rhizo\nVersion: %s\nArchitecture: amd64\nMaintainer: x <x@x>\n" % version
    for k in ("Pre-Depends", "Depends", "Recommends", "Suggests", "Conflicts", "Breaks", "Replaces"):
        if fields.get(k):
            out += "%s: %s\n" % (k, fields[k])
    return out + "Description: x\n"


def kernel_stanzas(control):
    """return the Rhizo kernel packages debian/control names"""
    ver = re.search(r"linux-image-rhizo \(>= (\S+)\)", control).group(1)
    abi = ver.rsplit("-", 1)[0]
    head = "Version: %s\nArchitecture: amd64\nMaintainer: x <x@x>\n" % ver
    return abi, {
        "linux-image-%s" % abi: "Package: linux-image-%s\n%sDescription: x\n" % (abi, head),
        "linux-headers-%s" % abi: "Package: linux-headers-%s\n%sDescription: x\n" % (abi, head),
        "linux-image-rhizo": "Package: linux-image-rhizo\n%sDepends: linux-image-%s (= %s)\nDescription: x\n"
                             % (head, abi, ver),
        "linux-headers-rhizo": "Package: linux-headers-rhizo\n%sDepends: linux-headers-%s (= %s)\nDescription: x\n"
                               % (head, abi, ver)}


def deb(work, stanza):
    """build a control-only .deb for a stanza"""
    name = re.search(r"^Package: (\S+)", stanza, re.M).group(1)
    root = tempfile.mkdtemp(dir=work)
    os.makedirs(os.path.join(root, "DEBIAN"))
    with open(os.path.join(root, "DEBIAN", "control"), "w") as f:
        f.write(stanza)
    out = os.path.join(root, name + ".deb")
    r = run(["dpkg-deb", "-b", root, out])
    if r.returncode:
        raise RuntimeError("dpkg-deb could not build %s: %s" % (name, r.stderr.strip()))
    return out


def install_flags(install_doc):
    """return the documented apt install line's options"""
    m = re.search(r"^sudo apt install (.*\./rhizo_\*_amd64\.deb.*)$", install_doc, re.M)
    if not m:
        raise LookupError("the round trip has no 'sudo apt install ... ./rhizo_*_amd64.deb' line")
    return [w for w in m.group(1).split() if w.startswith("-")]


def removal_steps(install_doc):
    """return the documented purge block's commands"""
    m = re.search(r"```\n(sudo (?:rhizo uninstall --purge|apt purge rhizo)\n(?:sudo .*\n)*)```",
                  install_doc)
    if not m:
        raise LookupError("the round trip has no purge block starting 'sudo rhizo uninstall --purge'")
    return [c.split()[1:] for c in m.group(1).splitlines() if c.startswith("sudo ") and c != "sudo reboot"]


def transact(host, stanzas_local, flags, stock, work):
    """apt-install local packages"""
    local = [deb(work, st) for st in stanzas_local]
    r = host.apt(["install"] + flags + local, stock)
    if r.returncode:
        raise RuntimeError("the documented install does not resolve on the image: %s"
                           % (r.stdout + r.stderr).strip()[-400:])
    ours = {re.search(r"^Package: (\S+)", st, re.M).group(1): st.strip() for st in stanzas_local}
    inst = re.findall(r"^Inst (\S+)(?: \[([^]]+)\])? \((\S+)", r.stdout, re.M)
    gone = set(re.findall(r"^(?:Purg|Remv) (\S+)", r.stdout, re.M))
    new = [n for n, old, _ in inst if not old and n not in ours]
    host.pkgs.update(candidates(new))
    host.pkgs.update(ours)
    host.pkgs = {n: st for n, st in host.pkgs.items() if n not in gone}
    host.auto |= set(new)
    host.clock += 1
    when = "2026-10-%02d 10:00:00" % host.clock
    entries = {"Install": [], "Upgrade": []}
    dlog = []
    for n, old, ver in inst:
        arch = re.search(r"^Architecture: (\S+)", host.pkgs[n], re.M).group(1)
        rcold = re.search(r"^Version: (\S+)", host.rc[n], re.M).group(1) if n in host.rc else "<none>"
        if old:
            entries["Upgrade"].append("%s:%s (%s, %s)" % (n, "amd64" if arch == "all" else arch, old, ver))
            dlog.append("%s upgrade %s:%s %s %s" % (when, n, arch, old, ver))
        else:
            entries["Install"].append("%s:%s (%s%s)" % (n, "amd64" if arch == "all" else arch, ver,
                                                       "" if n in ours else ", automatic"))
            dlog.append("%s install %s:%s %s %s" % (when, n, arch, rcold, ver))
        host.rc.pop(n, None)
    os.makedirs(host.history, exist_ok=True)
    os.makedirs(host.dpkglog, exist_ok=True)
    with open(os.path.join(host.history, "history.log"), "a") as f:
        f.write("\nStart-Date: %s\nCommandline: apt install\n" % when.replace(" ", "  "))
        for key in ("Install", "Upgrade"):
            if entries[key]:
                f.write("%s: %s\n" % (key, ", ".join(entries[key])))
        f.write("End-Date: %s\n" % when.replace(" ", "  "))
    with open(os.path.join(host.dpkglog, "dpkg.log"), "a") as f:
        f.write("".join(l + "\n" for l in dlog))
    return gone


def installed(host, control, changelog, install_doc, work, stock, upgrade=False):
    """apply the documented install"""
    abi, kernels = kernel_stanzas(control)
    host.pkgs.update(kernels)
    gone = set()
    if upgrade:
        n1 = control_stanza(control, changelog).replace("Version: ", "Version: 0~n1~", 1)
        gone |= transact(host, [n1], install_flags(install_doc), stock, work)
    gone |= transact(host, [control_stanza(control, changelog)], install_flags(install_doc), stock, work)
    return abi, gone


def wrappers(host, booted):
    """make apt and dpkg-query commands that act on the fixture"""
    d = host.work
    bindir = os.path.join(d, "bin")
    os.makedirs(bindir, exist_ok=True)
    opts = ("-o Dir::State::status=%s/status -o Dir::State::extended_states=%s/ext -o Debug::NoLocking=1 -o Dir::Cache=%s "
            "-o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=" % (d, d, d))
    env = "APT_CONFIG=%s FAKE_UNAME_R=%s LD_PRELOAD=%s" % (host.conf, booted, host.shim)
    tools = {"apt-get": "%s exec /usr/bin/apt-get -s %s \"$@\"" % (env, opts),
             "apt-cache": "%s exec /usr/bin/apt-cache %s \"$@\"" % (env, opts),
             "apt-mark": "%s exec /usr/bin/apt-mark %s \"$@\"" % (env, opts),
             "dpkg-query": "exec /usr/bin/dpkg-query --admindir=%s \"$@\"" % d}
    for name, line in tools.items():
        with open(os.path.join(bindir, name), "w") as f:
            f.write("#!/bin/sh\n%s\n" % line)
        os.chmod(os.path.join(bindir, name), 0o755)
    return bindir


def uninstall(host, booted, cli_dir):
    """run rhizo uninstall --purge on the fixture"""
    host.write()
    bindir = wrappers(host, booted)
    osrel = os.path.join(host.work, "os-release")
    with open(osrel, "w") as f:
        f.write('ID=ubuntu\nVERSION_ID="24.04"\n')
    env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], RHIZO_LIB_DIR=os.path.dirname(cli_dir),
               RHIZO_OS_RELEASE=osrel, RHIZO_ASSUME_YES="1", RHIZO_APT_HISTORY_DIR=host.history,
               RHIZO_DPKG_LOG_DIR=host.dpkglog)
    r = run(["bash", "-c", 'RHIZO_CLI_SOURCE_ONLY=1 . "$1"; cmd_uninstall --purge', "_",
             os.path.join(cli_dir, "cli", "rhizo.sh")], env=env)
    return r.stderr, r.stdout


def removal(host, steps, booted, cli_dir):
    """follow the documented removal"""
    named = {}
    for step in steps:
        if step == ["rhizo", "uninstall", "--purge"]:
            log, out = uninstall(host, booted, cli_dir)
            for how in ("purge", "remove"):
                m = re.search(r"^\[rhizo\]\s+sudo apt %s ([^(\n]+)" % how, log, re.M)
                if m:
                    named[how] = m.group(1).split()
            if not re.search(r"^Purg rhizo ", out, re.M):
                raise RuntimeError("rhizo uninstall --purge did not purge rhizo: %s" % (log + out).strip()[-400:])
        elif step[:1] == ["apt"] and any(w.startswith("<") for w in step):
            if not named:
                raise RuntimeError("the block's purge of what rhizo uninstall named has nothing to purge: rhizo "
                                   "uninstall printed %s" % (log.strip()[-300:] or "nothing"))
            out = "".join(host.apt([how] + names, booted).stdout for how, names in named.items())
        elif step[:1] == ["apt"]:
            r = host.apt(step[1:], booted)
            if r.returncode:
                raise RuntimeError("apt-get %s fails: %s" % (" ".join(step[1:]), (r.stdout + r.stderr).strip()[-300:]))
            out = r.stdout
        else:
            raise RuntimeError("the documented removal runs %r, which this check cannot follow" % " ".join(step))
        gone = set(re.findall(r"^(?:Purg|Remv) (\S+)", out, re.M))
        host.pkgs = {n: s for n, s in host.pkgs.items() if n not in gone}
    return named


def findings(control, changelog, install_doc, work, cli_dir=None, after_install=None, upgrade=False, before=None):
    """return each package the round trip leaves or removes"""
    cli_dir = cli_dir or os.path.join(REPO, "src", "install")
    shim = os.path.join(work, "uname.so")
    with open(shim + ".c", "w") as f:
        f.write(SHIM)
    r = run(["gcc", "-shared", "-fPIC", "-O2", "-o", shim, shim + ".c", "-ldl"])
    if r.returncode:
        return ["gcc could not build the uname shim: %s" % r.stderr.strip()[-300:]]
    names = [l.split("\t")[0].split(":")[0] for l in open(MANIFEST).read().splitlines()
             if l.strip() and not l.startswith("snap:")]
    base = Host(os.path.join(work, "base"), shim)
    missing = baseline(base, names)
    if missing:
        raise NoPackageLists("apt holds no candidate for %d of the image's packages (%s) -- this check needs "
                             "Ubuntu 24.04's package lists" % (len(missing), " ".join(sorted(missing)[:6])))
    image = set(base.pkgs)
    stock = sorted(re.sub(r"^linux-image-", "", n) for n in image if re.match(r"^linux-image-\d", n))[-1]
    bad = []
    steps = removal_steps(install_doc)
    for booted in ("rhizo", stock):
        host = Host(os.path.join(work, "booted-" + booted), shim)
        host.pkgs, host.auto = dict(base.pkgs), set(base.auto)
        on = "on the Rhizo kernel" if booted == "rhizo" else "on %s" % booted
        on += " after an upgrade from N-1" if upgrade else ""
        if before:
            before(host)
        try:
            abi, dropped = installed(host, control, changelog, install_doc, work, stock, upgrade)
            kept = after_install(host, stock) if after_install else set()
            named = removal(host, steps, abi if booted == "rhizo" else booted, cli_dir)
        except RuntimeError as e:
            return bad + ["%s: %s" % (on, e)]
        if before:
            bad += ["%s: %s" % (on, b) for b in before(host, named)]
        if dropped & image:
            bad.append("%s the documented install removes %d packages the image had: %s"
                       % (on, len(dropped & image), " ".join(sorted(dropped & image))))
        left = sorted(set(host.pkgs) - image - kept)
        if left:
            bad.append("%s the documented install then removal leaves %d packages the install added: %s"
                       % (on, len(left), " ".join(left)))
        lost = sorted(image - set(host.pkgs))
        if lost:
            bad.append("%s the documented removal removes %d packages the image had: %s" % (on, len(lost), " ".join(lost)))
        if after_install:
            broken = host.apt(["check"], booted)
            if broken.returncode or "libtool" not in host.pkgs:
                bad.append("%s the documented removal broke libtool, installed by hand since: %s"
                           % (on, (broken.stdout + broken.stderr).strip()[-300:]))
    return bad


def user_installs(host, stock):
    """install libtool by hand"""
    r = host.apt(["install", "libtool"], stock)
    new = re.findall(r"^Inst (\S+)", r.stdout, re.M)
    host.pkgs.update(candidates(new))
    host.auto |= set(new) - {"libtool"}
    host.write()
    bindir = wrappers(host, stock)
    deps = run([os.path.join(bindir, "apt-cache"), "depends", "--installed", "--recurse", "--no-recommends",
                "--no-suggests", "--no-conflicts", "--no-breaks", "--no-replaces", "--no-enhances", "libtool"]).stdout
    return set(new) | {l for l in deps.splitlines() if l and not l.startswith(" ") and l in host.pkgs}


def selftest():
    """check the tree passes and planted defects fail"""
    control, changelog, doc = read(CONTROL), read(CHANGELOG), ROUND_TRIP
    bad = []
    with tempfile.TemporaryDirectory() as w:
        got = findings(control, changelog, doc, w)
    if got:
        bad.append("the tree's own files have findings: %r" % got)
    autoremove = re.sub(r"^sudo apt purge <[^\n]*$", "sudo apt autoremove --purge", doc, count=1, flags=re.M)
    with tempfile.TemporaryDirectory() as w:
        got = findings(control, changelog, autoremove, w)
    if not any("leaves" in g and " gcc " in g + " " for g in got):
        bad.append("a plain autoremove in place of the named purge left no compiler behind: %r" % got)
    with tempfile.TemporaryDirectory() as w:
        got = findings(control, changelog, doc, w, after_install=user_installs)
    if got:
        bad.append("the named purge removed what libtool, installed by hand since, needs: %r" % got)
    with tempfile.TemporaryDirectory() as w:
        got = findings(control, changelog, doc, w, before=make_was_removed)
    if got:
        bad.append("make, removed with its configuration kept before Rhizo, was not named for remove alone: %r" % got)
    conflicting = re.sub(r"^(Package: rhizo\n)", r"\1Conflicts: ieee-data\n", control, count=1, flags=re.M)
    with tempfile.TemporaryDirectory() as w:
        got = findings(conflicting, changelog, doc, w)
    if not any("install removes" in g and "ieee-data" in g for g in got):
        bad.append("an install that removes the image's ieee-data was not named: %r" % got)
    return bad


def make_was_removed(host, named=None):
    """leave make removed with its configuration, or check its naming"""
    if named is None:
        host.rc["make"] = re.sub(r"^Version: .*$", "Version: 4.2-0", candidates(["make"])["make"], count=1,
                                 flags=re.M)
        return []
    if "make" in named.get("purge", []) or "make" not in named.get("remove", []):
        return ["rhizo uninstall named make for %r, not for remove alone" % named]
    return []


def main():
    """run the check or its selftest"""
    if not os.path.exists(MANIFEST):
        print("FAIL %s is missing (tools/fetch/images/ubuntu-base-manifest.sh fetches it)" % MANIFEST)
        return 1
    try:
        if "--selftest" in sys.argv[1:]:
            bad = selftest()
        else:
            bad = []
            for upgrade in (False, True):
                with tempfile.TemporaryDirectory() as w:
                    bad += findings(read(CONTROL), read(CHANGELOG), ROUND_TRIP, w, upgrade=upgrade)
    except NoPackageLists as e:
        print("NOT RUN: %s" % e)
        return 77
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
