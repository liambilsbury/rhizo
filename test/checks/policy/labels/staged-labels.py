#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

CONTEXT_FILES = ("plat_file_contexts", "system_ext_file_contexts",
                 "product_file_contexts", "vendor_file_contexts")

STAGED_ROOTS = (("/run/rhizo/vendor", "/vendor"),
                ("/run/rhizo/system_apex_flat", "/system/apex"),
                ("/run/rhizo/system_flat", "/system"),
                ("/run/rhizo/system_ext_flat", "/system_ext"),
                ("/run/rhizo/product_flat", "/product"))


def load_contexts(path):
    """return the file_contexts entries parsed from a file"""
    out = []
    for ln in open(path, errors="replace"):
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split()
        if len(parts) < 2:
            continue
        pat, lbl = parts[0], parts[-1]
        m = re.search(r"[.\[\](){}*+?|^$\\]", pat)
        stem = len(pat) if m is None else m.start()
        try:
            rx = re.compile(pat + r"\Z")
        except re.error:
            continue
        out.append((rx, stem, lbl))
    return out


def expected(entries, path):
    """return the label for a path from the best matching entry"""
    best = None
    for i, (rx, stem, lbl) in enumerate(entries):
        if rx.match(path):
            if best is None or (stem, i) > best[0]:
                best = ((stem, i), lbl)
    return best[1] if best else None


def type_of(label):
    """return the type part of a label"""
    return label.split(":")[2] if label.count(":") >= 3 else label


def diff(entries, snapshot_lines):
    """compare file label types against expected labels"""
    groups = {}
    checked = 0
    for ln in snapshot_lines:
        cols = ln.rstrip("\n").split("\t")
        if len(cols) < 4:
            continue
        p, kind, sz, cur = cols[0], cols[1], cols[2], cols[3]
        if kind == "f" and sz == "0":
            continue
        want = expected(entries, p)
        if want is None:
            continue
        checked += 1
        if type_of(want) != type_of(cur):
            groups.setdefault((type_of(cur), type_of(want)), []).append(p)
    return checked, groups


def fetch():
    """fetch the labels of the staged nodes from the running vm"""
    env = dict(os.environ)
    inst = env.get("RHIZO_VM")
    if not inst:
        sys.exit("--fetch needs RHIZO_VM")
    walker = (
        "import os\n"
        "roots = %r\n"
        "for host, sb in roots:\n"
        "    for dp, dn, fn in os.walk(host):\n"
        "        for n in dn + fn:\n"
        "            p = os.path.join(dp, n)\n"
        "            try:\n"
        "                lbl = os.getxattr(p, 'security.selinux', follow_symlinks=False).decode().rstrip('\\x00')\n"
        "            except OSError:\n"
        "                lbl = '<none>'\n"
        "            kind = 'l' if os.path.islink(p) else ('d' if os.path.isdir(p) else 'f')\n"
        "            try:\n"
        "                sz = os.lstat(p).st_size\n"
        "            except OSError:\n"
        "                sz = -1\n"
        "            print('%%s\\t%%s\\t%%d\\t%%s' %% (sb + p[len(host):], kind, sz, lbl))\n"
        % (list(STAGED_ROOTS),))
    d = tempfile.mkdtemp(prefix="staged-labels.")
    snap = os.path.join(d, "snapshot.tsv")
    common = os.path.join(HERE, "..", "..", "..", "vm", "common.sh")
    r = subprocess.run(["bash", "-c",
                        "source %s && ssh_vm -t 90 'python3 -' <<'PYEOF'\n%sPYEOF"
                        % (common, walker)],
                       capture_output=True, text=True, timeout=180)
    body = r.stdout.replace("\r", "")
    if r.returncode != 0 or "\t" not in body:
        sys.exit("snapshot fetch failed rc=%d: %s" % (r.returncode, r.stderr.strip()[:200]))
    open(snap, "w").write(body)
    for name, guest in (("plat_file_contexts", "/srv/rhizo/gsi_system/etc/selinux/plat_file_contexts"),
                        ("system_ext_file_contexts", "/srv/rhizo/gsi_system/system_ext/etc/selinux/system_ext_file_contexts"),
                        ("product_file_contexts", "/srv/rhizo/gsi_system/product/etc/selinux/product_file_contexts"),
                        ("vendor_file_contexts", "/run/rhizo/vendor/etc/selinux/vendor_file_contexts")):
        r = subprocess.run(["bash", "-c", "source %s && ssh_vm -t 30 'cat %s'" % (common, guest)],
                           capture_output=True, text=True, timeout=60)
        open(os.path.join(d, name), "w").write(r.stdout.replace("\r", ""))
    print("fetched into %s" % d)
    return snap, d


def run(snapshot, ctxdir):
    """return the mismatches between a snapshot and the file contexts"""
    entries = []
    loaded = 0
    for name in CONTEXT_FILES:
        p = os.path.join(ctxdir, name)
        if os.path.exists(p) and os.path.getsize(p) > 0:
            entries += load_contexts(p)
            loaded += 1
    if loaded == 0:
        sys.exit("no contexts loaded from %s" % ctxdir)
    checked, groups = diff(entries, open(snapshot, errors="replace"))
    print("checked %d rule-covered objects, %d mismatch group(s)" % (checked, len(groups)))
    for (c, w), paths in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print("%4d x current=%s expected=%s  e.g. %s" % (len(paths), c, w, paths[0]))
    return 1 if groups else 0


def selftest():
    """run the staged-labels checks on fixtures"""
    ctx = [("/vendor(/.*)?", "u:object_r:vendor_file:s0"),
           ("/vendor/lib64/egl(/.*)?", "u:object_r:same_process_hal_file:s0"),
           ("/vendor/lib64/libc\\+\\+\\.so", "u:object_r:same_process_hal_file:s0")]
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "plat_file_contexts"), "w").write(
            "\n".join("%s %s" % e for e in ctx) + "\n")
        entries = load_contexts(os.path.join(d, "plat_file_contexts"))
    n = 0
    assert type_of(expected(entries, "/vendor/bin/foo")) == "vendor_file"; n += 1
    assert type_of(expected(entries, "/vendor/lib64/egl/libEGL_rhizo.so")) == "same_process_hal_file"; n += 1
    assert type_of(expected(entries, "/vendor/lib64/libc++.so")) == "same_process_hal_file"; n += 1
    assert expected(entries, "/data/x") is None; n += 1
    snap = ["/vendor/bin/foo\tf\t100\tu:object_r:tmpfs:s0",
            "/vendor/lib64/egl/libEGL_rhizo.so\tf\t100\tu:object_r:vendor_file:s0",
            "/vendor/bin/placeholder\tf\t0\tu:object_r:tmpfs:s0",
            "/vendor/bin/ok\tf\t50\tu:object_r:vendor_file:s0"]
    checked, groups = diff(entries, snap)
    assert checked == 3, "the 0-byte placeholder must be excluded, got %d" % checked; n += 1
    assert ("tmpfs", "vendor_file") in groups; n += 1
    assert ("vendor_file", "same_process_hal_file") in groups; n += 1
    assert not any("ok" in p for ps in groups.values() for p in ps), \
        "a correct label must not be reported"; n += 1
    print("check-staged-labels selftest: %d assertions passed" % n)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot")
    ap.add_argument("--contexts")
    ap.add_argument("--fetch", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        sys.exit(0)
    if a.fetch:
        snap, d = fetch()
        sys.exit(run(snap, d))
    if not a.snapshot or not a.contexts:
        ap.error("need --snapshot and --contexts, or --fetch, or --selftest")
    sys.exit(run(a.snapshot, a.contexts))
