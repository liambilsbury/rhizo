#!/usr/bin/env python3
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
MANIFEST = "src/android/apps/home/AndroidManifest.xml"
LAUNCHER = "src/androidd/boot.py"
ANDROID = "{http://schemas.android.com/apk/res/android}"
HOME = "android.intent.category.HOME"


def home_priority(manifest):
    """return the priority of the manifest's HOME intent filter, or None"""
    root = ET.fromstring(manifest)
    for flt in root.iter("intent-filter"):
        cats = [c.get(ANDROID + "name") for c in flt.findall("category")]
        if HOME in cats:
            return int(flt.get(ANDROID + "priority", "0"))
    return None


def check(files):
    """check the HOME priority and the launcher's apk staging"""
    bad = []
    prio = home_priority(files[MANIFEST])
    if prio is None:
        return ["%s declares no HOME filter" % MANIFEST]
    if prio <= 0:
        bad.append("%s's HOME filter has priority %d" % (MANIFEST, prio))
    src = files[LAUNCHER]
    copies = set(re.findall(r'system_ext_upper/([\w-]+)/RhizoHome/RhizoHome\.apk', src))
    labels = set(re.findall(r'"/system_ext/([\w-]+)/RhizoHome/RhizoHome\\\\\.apk u:object_r:system_file:s0', src))
    if not copies:
        bad.append("%s no longer stages RhizoHome.apk onto /system_ext" % LAUNCHER)
    for part in sorted(copies - {"priv-app"}):
        bad.append("%s stages RhizoHome.apk under /system_ext/%s, where it is not privileged" % (LAUNCHER, part))
    if not labels:
        bad.append("%s gives the staged RhizoHome.apk no file_contexts label" % LAUNCHER)
    for part in sorted(labels - copies):
        bad.append("%s labels /system_ext/%s/RhizoHome/RhizoHome.apk, a path it does not stage the apk "
                   "at" % (LAUNCHER, part))
    return bad


def load(root):
    """return the text of the manifest and launcher files under a root"""
    out = {}
    for rel in (MANIFEST, LAUNCHER):
        with open(os.path.join(root, rel)) as f:
            out[rel] = f.read()
    return out


def selftest():
    """check the live tree and each planted-defect copy of it"""
    live = load(ROOT)
    problems = check(live)
    assert not problems, "the live tree must pass: %s" % problems

    def mutate(rel, old, new):
        """return a copy of the files with a text replaced"""
        files = dict(live)
        assert files[rel].count(old) >= 1, "fixture anchor missing from %s: %r" % (rel, old[:60])
        files[rel] = files[rel].replace(old, new)
        return files

    cases = [
        ("staged as a plain system app",
         mutate(LAUNCHER, "system_ext_upper/priv-app/RhizoHome", "system_ext_upper/app/RhizoHome"),
         "not privileged"),
        ("labeled at the old path",
         mutate(LAUNCHER, '"/system_ext/priv-app/RhizoHome/', '"/system_ext/app/RhizoHome/'),
         "a path it does not stage the apk at"),
        ("label dropped",
         mutate(LAUNCHER, '"/system_ext/priv-app/RhizoHome/RhizoHome\\\\.apk u:object_r:system_file:s0',
                '"/system_ext/priv-app/RhizoHome/RhizoHome\\\\.apk u:object_r:other_file:s0'),
         "no file_contexts label"),
        ("never staged", mutate(LAUNCHER, "/RhizoHome/RhizoHome.apk", "/RhizoHome/Other.apk"),
         "no longer stages RhizoHome.apk"),
        ("priority dropped", mutate(MANIFEST, 'android:priority="1"', ""), "priority 0"),
        ("no HOME filter", mutate(MANIFEST, HOME, "android.intent.category.LAUNCHER"), "declares no HOME filter"),
    ]
    for label, files, want in cases:
        got = check(files)
        assert any(want in g for g in got), "%s: expected a problem naming %r, got %s" % (label, want, got)
    print("check-home-privileged selftest: the live tree passes; %d single regressions each fail by name"
          % len(cases))


def main():
    """run the check or its selftest and print the result"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    problems = check(load(root))
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-home-privileged: RhizoHome is a priv-app")
    return 0


if __name__ == "__main__":
    sys.exit(main())
