#!/usr/bin/env python3
import argparse
import os
import re
import shutil
import sys
import tempfile

VERSION_RE = re.compile(r"\d+\.\d+\.\d+")

EXEMPT_LINE_PREFIXES = ("Standards-Version:",)
EXEMPT_LITERALS = {"7.1.0"}
ARCH_PKGBUILD = "archlinux/rhizo/PKGBUILD.in"
KERNEL_FLOOR_RE = re.compile(r"linux-(image|headers)-rhizo\s*\(>=\s*([^)\s]+)\s*\)")
ARCH_KERNEL_FLOOR_RE = re.compile(r"'linux-rhizo(-headers)?>=([^']+)'")
KERNEL_FLOOR_FIRST_REVISION = 40
KERNEL_VERSION = os.path.join("kernel", "VERSION")
KERNEL_META = os.path.join("kernel", "packaging", "deb-meta.sh")

CHANGELOG = "debian/changelog"

RHIZO_SITES = [
    CHANGELOG,
    "debian/control",
    "debian/rules",
    "README.md",
    "src/install/cli/rhizo.sh",
    ARCH_PKGBUILD,
]


def scan_literals(repo_root, rel_path):
    """return stray version literals in a file"""
    if rel_path == CHANGELOG:
        return []
    path = os.path.join(repo_root, rel_path)
    if not os.path.isfile(path):
        return ["%s: missing (a known version site is not there)" % rel_path]
    findings = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            stripped = line.strip()
            if any(stripped.startswith(p) for p in EXEMPT_LINE_PREFIXES):
                continue
            for m in VERSION_RE.finditer(line):
                if m.group(0) in EXEMPT_LITERALS:
                    continue
                findings.append(
                    "%s:%d: stray version literal '%s' -- %s is the only place "
                    "a version is written" % (rel_path, lineno, m.group(0), CHANGELOG))
    return findings


def kernel_floors(rhizo_root):
    """return the debian and pacman Rhizo kernel floors"""
    deb, arch = {}, {}
    with open(os.path.join(rhizo_root, "debian/control"), encoding="utf-8") as fh:
        for kind, ver in KERNEL_FLOOR_RE.findall(fh.read()):
            deb[kind] = ver
    path = os.path.join(rhizo_root, ARCH_PKGBUILD)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for headers, ver in ARCH_KERNEL_FLOOR_RE.findall(fh.read()):
                arch["headers" if headers else "image"] = ver
    return deb, arch


def kernel_revision(rhizo_root):
    """return the kernel's revision from kernel/VERSION, or an error text"""
    path = os.path.join(rhizo_root, KERNEL_VERSION)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read().strip()
    except OSError as exc:
        return "%s: %s" % (path, exc.strerror)
    if not text.isdigit():
        return "%s holds '%s', not one revision number" % (path, text)
    return int(text)


def kernel_floor_findings(rhizo_root):
    """return findings on the Rhizo kernel floors of both packages"""
    deb, arch = kernel_floors(rhizo_root)
    findings = []
    for kind, name in (("image", "linux-image-rhizo"), ("headers", "linux-headers-rhizo")):
        if kind not in deb:
            findings.append("debian/control: no '%s (>= <version>-<revision>)' depends" % name)
    for kind, name in (("image", "linux-rhizo"), ("headers", "linux-rhizo-headers")):
        if kind not in arch:
            findings.append("%s: no '%s>=<version>-<revision>' depends" % (ARCH_PKGBUILD, name))
    if findings:
        return findings
    if deb["image"] != deb["headers"] or arch["image"] != arch["headers"]:
        return ["the image and headers kernel floors differ: debian/control %s, %s %s" % (deb, ARCH_PKGBUILD, arch)]
    upstream, _, revision = deb["image"].rpartition("-")
    arch_upstream, _, arch_revision = arch["image"].rpartition("-")
    if upstream.replace("-", "_") != arch_upstream or revision != arch_revision:
        return ["%s's kernel floor (%s) is not debian/control's (%s)"
                % (ARCH_PKGBUILD, arch["image"], deb["image"])]
    if not revision.isdigit() or int(revision) < KERNEL_FLOOR_FIRST_REVISION:
        return ["debian/control: the kernel floor's revision '%s' is below %d, the first build carrying binder, "
                "ashmem and /proc/config.gz built in" % (revision, KERNEL_FLOOR_FIRST_REVISION)]
    meta = os.path.join(rhizo_root, KERNEL_META)
    try:
        with open(meta, encoding="utf-8") as fh:
            built = set(re.findall(r"Architecture: (\S+?)\\n", fh.read()))
    except OSError as exc:
        return ["cannot read %s: %s" % (KERNEL_META, exc.strerror)]
    with open(os.path.join(rhizo_root, "debian/control"), encoding="utf-8") as fh:
        m = re.search(r"^Package: rhizo\n(?:.*\n)*?Architecture: (.+)$", fh.read(), re.M)
    archs = set(m.group(1).split()) if m else set()
    if not built or not archs or archs - built:
        return ["debian/control: rhizo is Architecture %s, and the Rhizo kernel's meta packages are built for %s"
                " alone" % (" ".join(sorted(archs)) or "<none>",
                                                                   " ".join(sorted(built)) or "<none read>")]
    current = kernel_revision(rhizo_root)
    if isinstance(current, str):
        return ["cannot read the kernel's revision: %s" % current]
    if int(revision) > current:
        return ["debian/control: the kernel floor's revision %s is above kernel/VERSION's %d" % (revision, current)]
    return []


def rules_writes_version(rhizo_root):
    """return whether debian/rules writes the VERSION file from the changelog"""
    path = os.path.join(rhizo_root, "debian/rules")
    if not os.path.isfile(path):
        return False
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return "PAYLOAD)/VERSION" in text and "dpkg-parsechangelog" in text


def check(rhizo_root):
    """return findings for the rhizo tree and its kernel floor"""
    findings = []
    for site in RHIZO_SITES:
        findings.extend(scan_literals(rhizo_root, site))
    findings.extend(kernel_floor_findings(rhizo_root))
    if not rules_writes_version(rhizo_root):
        findings.append(
            "debian/rules: no line writes $(PAYLOAD)/VERSION from dpkg-parsechangelog")
    return findings


def run(rhizo_root):
    """print the version site findings"""
    findings = check(rhizo_root)
    if findings:
        for f in findings:
            print("FAIL: version-sites: %s" % f, file=sys.stderr)
        return 1
    print("version-sites: %d rhizo site(s), the kernel floor and the VERSION line all clean" % len(RHIZO_SITES))
    return 0


GOOD_CHANGELOG = """%(pkg)s (%(ver)s) noble; urgency=medium

  * fixture entry.

 -- Fixture <fixture@example.com>  Tue, 22 Sep 2026 12:00:00 +0000
"""


def write_good_rhizo(root, kernel_floor="7.1.0-rc1-rhizo-40", arch_kernel_floor="7.1.0_rc1_rhizo-40"):
    """write a fixture rhizo tree whose version sites agree"""
    os.makedirs(os.path.join(root, "debian"), exist_ok=True)
    os.makedirs(os.path.join(root, "src", "install", "cli"), exist_ok=True)
    with open(os.path.join(root, "debian", "changelog"), "w", encoding="utf-8") as fh:
        fh.write(GOOD_CHANGELOG % {"pkg": "rhizo", "ver": "0.1.1"})
    with open(os.path.join(root, "debian", "control"), "w", encoding="utf-8") as fh:
        fh.write(
            "Source: rhizo\n"
            "Standards-Version: 4.6.2\n"
            "\n"
            "Package: rhizo\n"
            "Architecture: amd64\n"
            "Depends: linux-image-rhizo%s,\n"
            "         linux-headers-rhizo%s\n"
            % (kernel_floor and " (>= %s)" % kernel_floor, kernel_floor and " (>= %s)" % kernel_floor))
    with open(os.path.join(root, "debian", "rules"), "w", encoding="utf-8") as fh:
        fh.write(
            "#!/usr/bin/make -f\n"
            "override_dh_auto_install:\n"
            "\techo '$(shell dpkg-parsechangelog -SVersion)' > $(PAYLOAD)/VERSION\n")
    with open(os.path.join(root, "README.md"), "w", encoding="utf-8") as fh:
        fh.write("# rhizo\nkernel 7.1.0\n")
    with open(os.path.join(root, "src", "install", "cli", "rhizo.sh"), "w", encoding="utf-8") as fh:
        fh.write("#!/bin/bash\nVERSION_FILE=\"$LIB_DIR/VERSION\"\n")
    write_pkgbuild(root, "archlinux/rhizo/PKGBUILD.in", "rhizo",
                   "depends=('linux-rhizo>=%s' 'linux-rhizo-headers>=%s' 'python>=3.12')\n"
                   % (arch_kernel_floor, arch_kernel_floor))


def write_pkgbuild(root, rel, name, extra="", pkgver="@VERSION@"):
    """write a fixture PKGBUILD"""
    os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
    with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
        fh.write("pkgname=%s\npkgver=%s\npkgrel=1\n%ssource=(\"%s-$pkgver.tar.zst\")\n"
                 % (name, pkgver, extra, name))


def write_good_kernel(root, revision="40"):
    """write a fixture kernel folder"""
    os.makedirs(os.path.join(root, "kernel", "packaging"), exist_ok=True)
    with open(os.path.join(root, KERNEL_VERSION), "w", encoding="utf-8") as fh:
        fh.write("%s\n" % revision)
    with open(os.path.join(root, KERNEL_META), "w", encoding="utf-8") as fh:
        fh.write("printf 'Package: linux-%s-rhizo\\nVersion: %s\\nArchitecture: amd64\\nDepends: x\\n'\n")


def selftest():
    """test the version site checks"""
    tmp = tempfile.mkdtemp(prefix="check-version-sites-")
    cases = 0
    try:
        rhizo_root = os.path.join(tmp, "rhizo")

        def rebuild(**kwargs):
            """write the fixture tree again from scratch"""
            shutil.rmtree(rhizo_root, ignore_errors=True)
            write_good_rhizo(rhizo_root, **kwargs)
            write_good_kernel(rhizo_root)

        def expect(name, want):
            """check the findings against want"""
            nonlocal cases
            cases += 1
            findings = check(rhizo_root)
            if want is None and findings:
                print("SELFTEST FAILED: %s was reported: %s" % (name, findings), file=sys.stderr)
                return False
            if want is not None and not any(want in f for f in findings):
                print("SELFTEST FAILED: %s was not caught: %s" % (name, findings), file=sys.stderr)
                return False
            return True

        rebuild()
        if not expect("a clean fixture", None):
            return 1
        rebuild()
        with open(os.path.join(rhizo_root, "README.md"), "a", encoding="utf-8") as fh:
            fh.write("get rhizo_1.2.3_amd64.deb\n")
        if not expect("a stray literal in README.md", "README.md:3: stray version literal '1.2.3'"):
            return 1
        rebuild()
        with open(os.path.join(rhizo_root, "debian", "rules"), "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/make -f\noverride_dh_auto_install:\n\ttrue\n")
        if not expect("a debian/rules with no VERSION line", "$(PAYLOAD)/VERSION"):
            return 1
        rebuild()
        os.unlink(os.path.join(rhizo_root, KERNEL_META))
        if not expect("a missing kernel/packaging/deb-meta.sh", "cannot read kernel/packaging/deb-meta.sh"):
            return 1
        rebuild()
        write_pkgbuild(rhizo_root, ARCH_PKGBUILD, "rhizo", pkgver="0.1.3")
        if not expect("a literal pkgver=0.1.3 in the PKGBUILD", "PKGBUILD.in:2: stray version literal '0.1.3'"):
            return 1
        rebuild()
        write_pkgbuild(rhizo_root, ARCH_PKGBUILD, "rhizo",
                       "depends=('linux-rhizo>=7.1.0_rc1_rhizo-40' 'linux-rhizo-headers>=7.1.0_rc1_rhizo-40' "
                       "'python>=3.12.4')\n")
        if not expect("a second literal beside the PKGBUILD kernel floor", "'3.12.4'"):
            return 1
        for name, kwargs, want in (
                ("an unversioned kernel depends", {"kernel_floor": ""}, "no 'linux-image-rhizo (>= "),
                ("a PKGBUILD kernel floor apart from debian/control's",
                 {"arch_kernel_floor": "7.1.0_rc1_rhizo-41"}, "is not debian/control's"),
                ("a kernel floor below the first built-in build",
                 {"kernel_floor": "7.1.0-rc1-rhizo-39", "arch_kernel_floor": "7.1.0_rc1_rhizo-39"}, "below 40"),
                ("a kernel floor above kernel/VERSION",
                 {"kernel_floor": "7.1.0-rc1-rhizo-41", "arch_kernel_floor": "7.1.0_rc1_rhizo-41"},
                 "above kernel/VERSION's 40")):
            rebuild(**kwargs)
            if not expect(name, want):
                return 1
        for name, body, want in (("a kernel/VERSION that is not a number", "forty\n", "not one revision number"),
                                 ("a missing kernel/VERSION", None, "cannot read the kernel's revision")):
            rebuild()
            path = os.path.join(rhizo_root, KERNEL_VERSION)
            if body is None:
                os.unlink(path)
            else:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(body)
            if not expect(name, want):
                return 1
        rebuild()
        write_good_kernel(rhizo_root, revision="45")
        if not expect("a kernel floor below kernel/VERSION", None):
            return 1
        rebuild()
        control = os.path.join(rhizo_root, "debian", "control")
        with open(control, encoding="utf-8") as fh:
            text = fh.read()
        with open(control, "w", encoding="utf-8") as fh:
            fh.write(text.replace("Architecture: amd64\n", "Architecture: amd64 arm64\n"))
        if not expect("an architecture the kernel is not built for", "meta packages are built for"):
            return 1
        print("check-version-sites --selftest: ok (%d cases)" % cases)
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--rhizo-root", default=os.path.normpath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")))
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    return run(args.rhizo_root)


if __name__ == "__main__":
    sys.exit(main())
