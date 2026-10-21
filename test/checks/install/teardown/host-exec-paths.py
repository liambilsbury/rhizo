#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

PRODUCT_FILE = os.path.join(REPO, "src", "androidd", "sandbox", "selinux_labels.py")
TEARDOWN_FILE = os.path.join(REPO, "src", "install", "teardown", "teardown.sh")
RIG_FILE = os.path.join(REPO, "test", "vm", "image", "label-host.sh")

RIG_DERIVES = ("/usr/lib/systemd/systemd",)

LDSO_MARKERS = ("/proc/self/maps", "ld-")
CORE_MARKER = "/proc/sys/kernel/core_pattern"


def product_paths(text):
    """return the paths in HOST_EXEC_PATHS"""
    m = re.search(r"^HOST_EXEC_PATHS\s*=\s*\((.*?)\)\s*$", text, re.M | re.S)
    if not m:
        raise LookupError("no HOST_EXEC_PATHS tuple in sandbox/selinux_labels.py")
    return re.findall(r'"([^"]+)"', m.group(1))


def shell_array_paths(text, name):
    """return the paths in a bash array"""
    m = re.search(r"^%s=\((.*?)^\s*\)\s*$" % re.escape(name), text, re.M | re.S)
    if not m:
        m = re.search(r"^%s=\((.*?)\)\s*$" % re.escape(name), text, re.M | re.S)
    if not m:
        raise LookupError("no %s array in this file" % name)
    out = []
    for line in m.group(1).splitlines():
        line = line.split("#", 1)[0]
        out.extend(w for w in line.split() if w.startswith("/"))
    return out


def derives_ldso(text):
    """check a file derives the ELF interpreter"""
    return all(m in text for m in LDSO_MARKERS)


def findings(product, teardown, rig, texts=None):
    """return the failure strings"""
    out = []
    for text, name in zip(texts or (), ("src/androidd/sandbox/selinux_labels.py",
                                        "src/install/teardown/teardown.sh",
                                        "test/vm/image/label-host.sh")):
        if not derives_ldso(text):
            out.append("%s no longer derives the host's ELF interpreter from /proc/self/maps" % name)
        if CORE_MARKER not in text:
            out.append("%s no longer derives the core dump helper from %s" % (name, CORE_MARKER))
    for p in product:
        if p not in teardown:
            out.append("%s is stamped by sandbox/selinux_labels.py but never cleared by "
                       "src/install/teardown/teardown.sh" % p)
        if p not in rig and p not in RIG_DERIVES:
            out.append("%s is stamped by sandbox/selinux_labels.py but missing from label-host.sh's "
                       "HOST_EXEC_PATHS_EXTRA" % p)
    return out


def selftest():
    """check the path list functions on fixtures"""
    n = 0
    prod = 'HOST_EXEC_PATHS = ("/usr/bin/bash", "/usr/bin/python3",\n                   "/lib64/ld.so")\n'
    tear = 'HOST_EXEC_PATHS=(/usr/bin/bash /usr/bin/python3\n                  /lib64/ld.so)\n'
    rig = "HOST_EXEC_PATHS_EXTRA=(\n  /usr/bin/bash\n  # a comment naming /usr/bin/never\n  /usr/bin/python3\n  /lib64/ld.so\n)\n"

    p, t, r = product_paths(prod), shell_array_paths(tear, "HOST_EXEC_PATHS"), \
        shell_array_paths(rig, "HOST_EXEC_PATHS_EXTRA")
    assert p == ["/usr/bin/bash", "/usr/bin/python3", "/lib64/ld.so"], p
    n += 1
    assert t == p, t
    n += 1
    assert r == p, "a path named only inside a comment was read as an entry: %r" % (r,)
    n += 1
    assert findings(p, t, r) == [], findings(p, t, r)
    n += 1

    derived = ('for _l in open("/proc/self/maps"):\n  if base.startswith("ld-"): pass\n'
               '_w = open("/proc/sys/kernel/core_pattern").read().split()\n')
    assert derives_ldso(derived)
    n += 1
    assert findings(p, t, r, (derived, derived, derived)) == []
    n += 1
    got = findings(p, t, r, (derived, "_w = " + derived.split("_w = ")[1], derived))
    assert len(got) == 1 and "teardown.sh" in got[0] and "ELF interpreter" in got[0], got
    n += 1
    got = findings(p, t, r, (derived, derived, derived.split("_w = ")[0]))
    assert len(got) == 1 and "label-host.sh" in got[0] and "core dump helper" in got[0], got
    n += 1

    dropped_t = [x for x in t if x != "/lib64/ld.so"]
    got = findings(p, dropped_t, r)
    assert any("never cleared" in f and "/lib64/ld.so" in f for f in got), got
    n += 1

    dropped_r = [x for x in r if x != "/usr/bin/python3"]
    got = findings(p, t, dropped_r)
    assert any("label-host.sh" in f and "/usr/bin/python3" in f for f in got), got
    n += 1

    assert findings(["/usr/lib/systemd/systemd"], ["/usr/lib/systemd/systemd"], []) == []
    n += 1

    for bad, name in ((prod.replace("HOST_EXEC_PATHS", "OTHER"), "product"),
                      (tear.replace("HOST_EXEC_PATHS", "OTHER"), "teardown")):
        try:
            product_paths(bad) if name == "product" else shell_array_paths(bad, "HOST_EXEC_PATHS")
            raise AssertionError("a file with no list did not raise (%s)" % name)
        except LookupError:
            pass
        n += 1

    print("check-host-exec-paths selftest: %d assertions passed -- a path the teardown would "
          "not clear, a path the rig tool would not stamp, a commented path, and a missing "
          "list are all caught" % n)
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        product = product_paths(open(PRODUCT_FILE).read())
        teardown = shell_array_paths(open(TEARDOWN_FILE).read(), "HOST_EXEC_PATHS")
        rig = shell_array_paths(open(RIG_FILE).read(), "HOST_EXEC_PATHS_EXTRA")
    except (LookupError, OSError) as e:
        print("check-host-exec-paths: could not read a list: %s" % e)
        return 1
    bad = findings(product, teardown, rig,
                   (open(PRODUCT_FILE).read(), open(TEARDOWN_FILE).read(), open(RIG_FILE).read()))
    if bad:
        print("check-host-exec-paths: the three host-exec path lists disagree:")
        for f in bad:
            print("  " + f)
        return 1
    print("check-host-exec-paths: all %d stamped host binaries are cleared by the teardown and "
          "named by label-host.sh, and all three derive the ELF interpreter and the core dump helper" % len(product))
    return 0


if __name__ == "__main__":
    sys.exit(main())
