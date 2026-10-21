#!/usr/bin/env python3
import gzip
import json
import os
import sqlite3
import sys
import re
import tempfile

GPL_TEXT = re.compile(r"GNU (LESSER |LIBRARY |AFFERO )?GENERAL PUBLIC LICENSE|GNU (Lesser |Library |Affero )?General Public"
                      r" License|SPDX-License-Identifier:\s*\(?\s*(A|L)?GPL", re.I)
GPL_KIND = re.compile(r"SPDX-license-identifier-(A|L)?GPL|legacy_restricted")
PREBUILT_TYPES = re.compile(r"prebuilt|_import$")

USAGE = """Usage: gsi-share-list.py <aosp dir> <product out, relative to it> <compliance-metadata.db> <apex listing> <image listing>
       gsi-share-list.py --selftest
The apex listing has one "<apex file name><TAB><path inside it>" line per file; the image listing one path under
/system per line, as the target-files SYSTEM/ entries name them."""


def notice_gpl_files(notice_gz):
    """return {installed path: lib} for every file whose notice text is GPL-family"""
    text = gzip.open(notice_gz).read().decode("utf-8", "replace")
    contents = dict(re.findall(r'<file-content contentId="([0-9a-f]+)"><!\[CDATA\[(.*?)\]\]></file-content>', text, re.S))
    hits = {}
    for cid, lib, path in re.findall(r'<file-name contentId="([0-9a-f]+)" lib="([^"]*)">([^<]*)</file-name>', text):
        if GPL_TEXT.search(contents.get(cid, "")):
            hits.setdefault(path, lib)
    return hits


def prebuilts_only(project):
    """tell whether a project holds prebuilt binaries rather than their source"""
    return project.startswith("prebuilts/") or project.split("/")[-1].endswith("prebuilts")


def nearest(package, by_package):
    """return the value for a package or its nearest ancestor directory, or None"""
    p = package
    while p:
        if p in by_package:
            return by_package[p]
        p = os.path.dirname(p)
    return None


def share_list(aosp, product_out, db, apex_listing, image_listing, prebuilt_table):
    """return (sorted project,reason rows, sorted problems: notice GPL files no project accounts for, unreviewed prebuilts)"""
    with open(os.path.join(aosp, ".repo/project.list")) as f:
        projects = sorted((p.strip() for p in f if p.strip()), key=len, reverse=True)

    def project_of(path):
        return next((p for p in projects if path == p or path.startswith(p + "/")), None)

    con = sqlite3.connect(db)
    mods = con.execute("select name, package, module_type, variant, installed_files, built_files, static_deps,"
                       " whole_static_deps, lic_license_kinds from modules").fetchall()
    con.close()
    kinds_by_package = {}
    by_name = {}
    for name, package, mtype, variant, installed, built, sdeps, wsdeps, kinds in mods:
        if mtype == "license":
            kinds_by_package.setdefault(package, set()).update((kinds or "").split())
        else:
            by_name.setdefault(name, []).append((name, package, mtype, variant, installed, built, sdeps, wsdeps))

    apex_files = {}
    apex_paths = set()
    with open(apex_listing) as f:
        for line in f:
            apex, _, inner = line.rstrip("\n").partition("\t")
            if inner and not inner.endswith("/"):
                apex_files.setdefault(os.path.basename(inner), apex)
                apex_paths.add("apex:%s/%s" % (apex, inner))
    table = {}
    with open(prebuilt_table) as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                match, verdict, note = (line.rstrip("\n").split("\t") + ["", ""])[:3]
                table[match] = (verdict, note)

    with open(image_listing) as f:
        image = {line.strip() for line in f if line.strip()}
    system = product_out + "/system/"
    picked = {}
    in_apex = {}
    for rows in by_name.values():
        for r in rows:
            name, variant, installed, built = r[0], r[3], r[4] or "", r[5] or ""
            if not variant.startswith("android"):
                continue
            if any(f.startswith(system) and f[len(system):] in image for f in installed.split()):
                picked.setdefault((name, r[1]), (r, "system"))
            elif "apex" in variant:
                for f in built.split():
                    if "/unstripped/" not in f and os.path.basename(f) in apex_files:
                        in_apex.setdefault(os.path.basename(f), []).append(r)
    for base, cands in in_apex.items():
        built_here = [r for r in cands if not PREBUILT_TYPES.search(r[2])]
        for r in built_here or cands:
            picked.setdefault((r[0], r[1]), (r, "apex " + apex_files[base]))
    queue = list(picked.values())
    while queue:
        r, why = queue.pop()
        for dep in ((r[6] or "") + " " + (r[7] or "")).split():
            for d in by_name.get(dep, []):
                if d[3].startswith("android") and (dep, d[1]) not in picked:
                    picked[(dep, d[1])] = (d, "static dep of %s (%s)" % (r[0], why))
                    queue.append(picked[(dep, d[1])])

    out = set()
    problems = []
    for (name, package), (r, why) in picked.items():
        kinds = nearest(package, kinds_by_package) or set()
        if not any(GPL_KIND.search(k) for k in kinds):
            continue
        project = project_of(package)
        if project is None:
            continue
        if prebuilts_only(project):
            verdict = table.get(project, ("", ""))[0]
            if verdict == "gpl":
                out.add("%s,PREBUILT:%s %s" % (project, name, table[project][1]))
            elif verdict != "not-gpl":
                problems.append("unreviewed prebuilt: %s %s" % (project, name))
        else:
            out.add("%s,module:%s %s" % (project, name, why))
    for match, (verdict, note) in table.items():
        if verdict == "gpl" and match in apex_paths:
            out.add("UPSTREAM,%s %s" % (match, note))

    with open(os.path.join(aosp, product_out, "module-info.json")) as f:
        info = json.load(f)
    source_of = {}
    for mod in info.values():
        for inst in mod.get("installed") or []:
            for src in mod.get("path") or []:
                source_of.setdefault(inst, src)
    unmapped = problems
    for path, lib in notice_gpl_files(os.path.join(aosp, product_out, "system/etc/NOTICE.xml.gz")).items():
        src = source_of.get(product_out + path)
        project = project_of(src) if src else None
        if project is None:
            unmapped.append("no AOSP project installs " + path)
        else:
            out.add("%s,notice:%s %s" % (project, path, lib))
    return sorted(out), sorted(unmapped)


def selftest():
    """check the module selection, license lookup and project mapping on a fixture product"""
    fails = []
    with tempfile.TemporaryDirectory() as aosp:
        out = "out-x/target/product/p"
        os.makedirs(os.path.join(aosp, out, "system/etc"))
        os.makedirs(os.path.join(aosp, ".repo"))
        with open(os.path.join(aosp, ".repo/project.list"), "w") as f:
            f.write("external/iptables\nexternal/selinux\nexternal/toybox\nexternal/ethtool\ndevice/x/prebuilts\n"
                    "external/erofs-utils\nprebuilts/vndk\nexternal/qemu\nprebuilts/vndk/v1\nprebuilts/foo\n")
        notice = ('<?xml version="1.0"?>\n<licenses>\n'
                  '<file-name contentId="a1" lib="erofs">/system/bin/mkfs.erofs</file-name>\n'
                  '<file-content contentId="a1"><![CDATA[SPDX-License-Identifier: GPL-2.0+]]></file-content>\n'
                  '</licenses>\n')
        with gzip.open(os.path.join(aosp, out, "system/etc/NOTICE.xml.gz"), "wt") as f:
            f.write(notice)
        with open(os.path.join(aosp, out, "module-info.json"), "w") as f:
            json.dump({"mkfs.erofs": {"installed": [out + "/system/bin/mkfs.erofs"], "path": ["external/erofs-utils"]}}, f)
        db = os.path.join(aosp, "c.db")
        con = sqlite3.connect(db)
        con.execute("create table modules (name, package, module_type, variant, installed_files, built_files,"
                    " static_deps, whole_static_deps, lic_license_kinds)")
        si = out + "/system/"
        rows = [
            ("external_iptables_license", "external/iptables", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("external_selinux_libsepol_license", "external/selinux/libsepol", "license", "", "", "", "", "",
             "SPDX-license-identifier-LGPL-2.1"),
            ("external_toybox_license", "external/toybox", "license", "", "", "", "", "", "SPDX-license-identifier-0BSD"),
            ("external_ethtool_license", "external/ethtool", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("uboot_license", "device/x/prebuilts", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0-only"),
            ("iptables", "external/iptables/iptables", "cc_binary", "android_x86_64", si + "bin/iptables", "", "", "", ""),
            ("toybox", "external/toybox", "cc_binary", "android_x86_64", si + "bin/toybox", "", "", "", ""),
            ("secilc", "external/selinux/secilc", "cc_binary", "android_x86_64", si + "bin/secilc", "", "libsepol", "", ""),
            ("libsepol", "external/selinux/libsepol", "cc_library", "android_x86_64_static", "",
             "o/libsepol.a", "", "", ""),
            ("ethtool", "external/ethtool", "cc_binary", "android_x86_64_apex31", "",
             "o/ethtool/android_x86_64_apex31/ethtool o/ethtool/android_x86_64_apex31/unstripped/ethtool", "", "", ""),
            ("u-boot.rom", "device/x/prebuilts", "prebuilt_etc", "android_x86_64_apex31", "", "o/u/u-boot.rom", "", "", ""),
            ("prebuilts_vndk_license", "prebuilts/vndk", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("ethtool", "prebuilts/vndk", "cc_prebuilt_binary", "android_x86_64_apex31", "", "o/v/ethtool", "", "", ""),
            ("hyph-ru", "external/iptables", "prebuilt_etc", "android_x86_64", si + "usr/hyph-ru.hyb", "", "", "", ""),
            ("external_qemu_license", "external/qemu", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("qemu", "external/qemu", "cc_binary", "android_x86_64", si + "bin/qemu", "", "", "", ""),
        ]
        con.executemany("insert into modules values (?,?,?,?,?,?,?,?,?)", rows)
        con.commit()
        con.close()
        listing = os.path.join(aosp, "apex.txt")
        with open(listing, "w") as f:
            f.write("com.x.apex\tbin/ethtool\ncom.x.apex\tetc/u-boot.rom\ncom.x.apex\tetc/unknown.pb\n")
        con = sqlite3.connect(db)
        con.executemany("insert into modules values (?,?,?,?,?,?,?,?,?)", [
            ("prebuilts_vndk_v1_license", "prebuilts/vndk/v1", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("libvx", "prebuilts/vndk/v1", "vndk_prebuilt_shared", "android_x86_64_apex31", "", "o/vx/libvx.so", "", "", ""),
            ("prebuilts_foo_license", "prebuilts/foo", "license", "", "", "", "", "", "SPDX-license-identifier-GPL-2.0"),
            ("libfoo", "prebuilts/foo", "cc_prebuilt_library_shared", "android_x86_64_apex31", "", "o/f/libfoo.so", "", "", "")])
        con.commit()
        con.close()
        with open(listing, "a") as f:
            f.write("com.x.apex\tlib64/libvx.so\ncom.x.apex\tlib64/libfoo.so\ncom.x.apex\tetc/fs/kernel\n")
        table = os.path.join(aosp, "table.tsv")
        with open(table, "w") as f:
            f.write("# match\tverdict\tnote\nprebuilts/vndk/v1\tnot-gpl\tsnapshot of AOSP libraries\n"
                    "apex:com.x.apex/etc/fs/kernel\tgpl\tLinux, kernel build 1\n"
                    "apex:com.x.apex/etc/absent\tgpl\tnot in this image\n"
                    "device/x/prebuilts\tgpl\tU-Boot, upstream source\n")
        image = os.path.join(aosp, "image.txt")
        with open(image, "w") as f:
            f.write("bin/iptables\nbin/toybox\nbin/secilc\nbin/mkfs.erofs\nusr/hyph-ru.hyb\napex/com.x.apex\n")
        rows, unmapped = share_list(aosp, out, db, listing, image, table)
        projects = sorted({r.split(",")[0] for r in rows})
        want = ["UPSTREAM", "device/x/prebuilts", "external/erofs-utils", "external/ethtool", "external/iptables",
                "external/selinux"]
        if projects != want:
            fails.append("system, APEX and static-dep modules under GPL-family licenses, and the notice's GPL files,"
                         " map to their projects and BSD ones do not: %r" % projects)
        if "device/x/prebuilts,PREBUILT:u-boot.rom U-Boot, upstream source" not in rows:
            fails.append("a GPL prebuilt from a prebuilts-only project is marked PREBUILT: %r" % rows)
        if any("prebuilts/vndk" in r for r in rows):
            fails.append("a prebuilt sharing a file name with a source-built APEX module is not picked: %r" % rows)
        if any("PREBUILT:hyph-ru" in r for r in rows):
            fails.append("a data file from a source project is not marked PREBUILT: %r" % rows)
        if not any(r.startswith("external/selinux,") and "libsepol" in r for r in rows):
            fails.append("a static dependency is named as the reason: %r" % rows)
        if any(r.startswith("external/qemu") for r in rows):
            fails.append("a module built but not in the image is not picked: %r" % rows)
        if any("prebuilts/vndk/v1" in r for r in rows):
            fails.append("a prebuilt the table rules not-gpl is dropped: %r" % rows)
        if "UPSTREAM,apex:com.x.apex/etc/fs/kernel Linux, kernel build 1" not in rows:
            fails.append("a table gpl row for a file in the image is listed as UPSTREAM: %r" % rows)
        if any("etc/absent" in r for r in rows):
            fails.append("a table row for a file not in the image adds nothing: %r" % rows)
        if unmapped != ["unreviewed prebuilt: prebuilts/foo libfoo"]:
            fails.append("a GPL-flagged prebuilt with no table row is reported: %r" % unmapped)
    for f in fails:
        print("FAIL " + f)
    print("gsi-share-list.py selftest: " + ("FAILED" if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) != 6:
        print(USAGE, file=sys.stderr)
        return 2
    rows, unmapped = share_list(*argv[1:], os.path.join(os.path.dirname(os.path.abspath(__file__)), "gsi-prebuilt-licenses.tsv"))
    for r in rows:
        print(r)
    for u in unmapped:
        print("gsi-share-list: %s" % u, file=sys.stderr)
    return 1 if unmapped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
