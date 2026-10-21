#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))

from sandbox import selinux_policy  # noqa: E402
from policy_lab_cache import release_cil_dir  # noqa: E402

LIVE = re.compile(r"^[^;\n]*\budmabuf_device\b", re.M)
DECLARATION = re.compile(r"\((?:type|typeattribute|typealias)\s+([^\s()]+)\s*\)")
SEPOLICY_VERSION = re.compile(r"<sepolicy>\s*<version>([^<]+)</version>")
AV_RULES = frozenset(("allow", "auditallow", "dontaudit", "neverallow", "deny",
                      "allowx", "auditallowx", "dontauditx", "neverallowx"))
TRANSITIONS = frozenset(("typetransition", "typechange", "typemember"))
SET_OPERATORS = frozenset(("and", "or", "not", "xor", "all"))
MANIFEST = os.path.join("src", "androidd", "guest", "vendor", "manifest.xml")
CTS_JAR = os.path.join("var", "suites", "android-cts", "testcases",
                       "CtsSecurityHostTestCases", "CtsSecurityHostTestCases.jar")


MIRROR_BLOCKS = ("rhizo_mirror_", "rhizo_sysfs_uinput_rule_", "rhizo_ns_walk_")


def offenders(text):
    """return the live statements that name the missing device type"""
    return [ln.strip() for ln in LIVE.findall(text)]


def parse(text):
    """return the top-level CIL statements as nested lists"""
    stack = [[]]
    for token in selinux_policy._CIL_TOKEN.findall(text):
        if token == "(":
            stack.append([])
        elif token == ")":
            if len(stack) == 1:
                raise ValueError("a ) closes no statement")
            done = stack.pop()
            stack[-1].append(done)
        elif token[0] != ";":
            stack[-1].append(token)
    if len(stack) != 1:
        raise ValueError(f"{len(stack) - 1} statement(s) left open")
    return stack[0]


def set_members(expr):
    """return the names in a typeattributeset expression"""
    if isinstance(expr, str):
        return set() if expr in SET_OPERATORS else {expr}
    return set().union(*(set_members(e) for e in expr))


def constraint_types(expr):
    """return the type names a constraint expression compares"""
    if not isinstance(expr, list) or not expr:
        return set()
    if expr[0] in ("eq", "neq") and expr[1] in ("t1", "t2", "t3") and expr[2] not in ("t1", "t2", "t3"):
        return set_members(expr[2])
    return set().union(*(constraint_types(e) for e in expr[1:]))


def named_types(statement):
    """return the type names in a statement"""
    head = statement[0] if isinstance(statement, list) and statement else None
    if head == "optional":
        if statement[1].startswith(MIRROR_BLOCKS):
            return set()
        return set().union(*(named_types(s) for s in statement[2:]))
    if head in AV_RULES:
        return {n for n in statement[1:3] if n != "self"}
    if head == "typeattributeset":
        return {statement[1]} | set_members(statement[2])
    if head == "roletype":
        return {statement[2]}
    if head in TRANSITIONS:
        return {statement[1], statement[2], statement[-1]}
    if head == "genfscon" and isinstance(statement[3], list):
        return {statement[3][2]}
    if head in ("type", "typeattribute"):
        return {statement[1]}
    if head == "validatetrans":
        return constraint_types(statement[2])
    raise ValueError(f"no type positions known for the statement {statement}")


def unresolved(adapted, references):
    """return the adapted CIL's undeclared type names"""
    named = set().union(*(named_types(s) for s in parse(adapted)))
    declared = set(DECLARATION.findall(adapted)).union(
        *(DECLARATION.findall(r) for r in references))
    return sorted(named - declared)


def problems(adapted, references):
    """return the problems in the vendor-adapted policy"""
    bad = []
    live = offenders(adapted)
    if live:
        bad.append("the CTS-pull artifact still names udmabuf_device in a "
                   "statement, which no bundled snapshot declares: %s" % live[:2])
    if "rhizo_dev_ok" not in adapted:
        bad.append("rhizo_dev_ok vanished from the adapted artifact entirely")
    try:
        missing = unresolved(adapted, references)
    except ValueError as e:
        return bad + ["the CTS-pull artifact could not be read: %s" % e]
    if missing:
        bad.append("the CTS-pull artifact names %s, which neither it, "
                   "plat_pub_versioned.cil nor CTS's frozen snapshot declares" % missing)
    return bad


def cts_snapshot(jar, version):
    """return the CTS jar's frozen snapshot CIL texts"""
    with zipfile.ZipFile(jar) as z:
        return [z.read(f"{version}_{name}.cil").decode()
                for name in ("plat_sepolicy", "mapping")]


def inputs(root):
    """return the CILs and CTS jar, or why not"""
    cils_dir = release_cil_dir(root, "system")
    names = ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil")
    if cils_dir is None:
        return None, None, ("no var/gsi/system.img and no single cached cils-system-* directory under "
                            "var/share/policy-lab: stage the GSI and run test/checks/lib/policy-lab.sh once")
    cils = [os.path.join(cils_dir, n) for n in names]
    absent = [c for c in cils if not os.path.exists(c)]
    if absent:
        return None, None, ("policy-lab.sh has not cached this GSI's CILs (%s absent): run "
                            "test/checks/lib/policy-lab.sh once" % ", ".join(os.path.relpath(a, root) for a in absent))
    jar = os.path.join(root, CTS_JAR)
    if not os.path.exists(jar):
        return None, None, "no CTS package to read the frozen snapshot from (%s)" % CTS_JAR
    return cils, jar, None


def selftest():
    """test each finding on fixture CILs"""
    public_lacking = (
        "(type kernel)\n(type vold)\n(type sysfs)\n(type init)\n(type port_device)\n"
        "(typeattribute dev_type)\n(typeattribute domain)\n(typeattribute halserverdomain)\n"
        "(typeattribute hal_keymint)\n(typeattribute hal_keymint_server)\n")
    public_declaring = public_lacking + "(type sysfs_ublk)\n"
    snapshot = "(type audioserver_exec)\n"
    head = (
        "; A17's own device.te adds a neverallow on udmabuf_device write\n"
        "(type rhizo_keymint_exec)\n"
        "(typeattribute rhizo_dev_ok)\n"
        "(typeattributeset rhizo_dev_ok (and (dev_type) "
        "(not (port_device udmabuf_device))))\n"
        + selinux_policy.LIVE_KEYMINT_TT
        + "(allow kernel sysfs (file (getattr mounton)))\n")
    optional = ("(allow kernel sysfs_ublk (file (getattr mounton)))\n"
                "(deny vold sysfs_ublk\n    (file (write append)))\n")
    tail = "(allow kernel audioserver_exec (file (read)))\n"
    sample = head + optional + tail
    set_line = "(typeattributeset sysfs_type (sysfs_ublk))"
    with tempfile.TemporaryDirectory() as d:
        lacking_path = os.path.join(d, "lacking.cil")
        declaring_path = os.path.join(d, "declaring.cil")
        open(lacking_path, "w").write(public_lacking)
        open(declaring_path, "w").write(public_declaring)
        adapted = selinux_policy.cts_vendor_adapt(sample, [lacking_path])
        kept = selinux_policy.cts_vendor_adapt(sample, [declaring_path])
        try:
            selinux_policy.cts_vendor_adapt(sample + set_line + "\n", [lacking_path])
            refused = ""
        except ValueError as e:
            refused = str(e)
    expected_dropped, expected_kept = (
        text.replace(selinux_policy.LIVE_KEYMINT_TT, selinux_policy.CTS_KEYMINT_BLOCK)
        .replace("(not (port_device udmabuf_device))", "(not (port_device))")
        for text in (head + tail, sample))
    refs = [public_lacking, snapshot]
    clean = problems(adapted, refs)
    no_snapshot = problems(adapted, [public_lacking])
    leaked = problems(kept, refs)
    udmabuf = problems(adapted.replace("(not (port_device))",
                                       "(not (port_device udmabuf_device))"), refs)
    cases = (
        (clean == [], "a well-formed adapted sample was flagged: %s" % clean),
        (adapted == expected_dropped,
         "the adapted CIL is not the input minus exactly the sysfs_ublk rules: %r" % adapted),
        (kept == expected_kept,
         "cts_vendor_adapt changed sysfs_ublk rules the public policy declares: %r" % kept),
        (set_line in refused,
         "a typeattributeset naming sysfs_ublk was not refused by statement: %r" % refused),
        (problems(kept, [public_declaring, snapshot]) == [],
         "sysfs_ublk was flagged with a public policy that declares it"),
        (any("['sysfs_ublk']" in b for b in leaked),
         "an artifact naming sysfs_ublk the public policy lacks was not caught: %s" % leaked),
        (any("['audioserver_exec']" in b for b in no_snapshot),
         "a type only the frozen snapshot declares resolved with no snapshot: %s" % no_snapshot),
        (any("udmabuf_device in a statement" in b for b in udmabuf),
         "the unadapted udmabuf_device artifact was not caught: %s" % udmabuf),
        (any("vanished" in b for b in problems(adapted.replace("rhizo_dev_ok", "rhizo_dev_x"), refs)),
         "rhizo_dev_ok disappearing was not caught"),
        (any("could not be read" in b for b in problems(adapted + "(typebounds kernel vold)\n", refs)),
         "a statement with no known type positions was not reported"),
        (problems(adapted + "(validatetrans chr_file (or (not (eq t3 kernel)) (eq t2 vold)))\n", refs) == [],
         "a validatetrans comparing declared types was flagged"),
        (any("['rhizo_lacking']" in b for b in problems(
            adapted + "(optional rhizo_x\n(allow rhizo_lacking kernel (file (read)))\n)\n", refs)),
         "an undeclared type inside a hand-written optional block was not caught"),
        (problems(adapted + "(optional rhizo_sysfs_uinput_rule_9\n(allow rhizo_lacking kernel (file (read)))\n)\n",
                  refs) == [],
         "a mirror block naming a type the snapshot lacks was flagged, though CTS's compile skips it"),
        (problems(adapted + "(optional rhizo_ns_walk_rhizo_lacking\n(allow rhizo_ns_relabel rhizo_lacking (dir (search)))\n)\n",
                  refs) == [],
         "a dir walk block naming a type the snapshot lacks was flagged, though CTS's compile skips it"),
        (any("['rhizo_lacking']" in b for b in problems(
            adapted + "(validatetrans chr_file (or (not (eq t3 kernel)) (eq t2 rhizo_lacking)))\n", refs)),
         "a validatetrans naming an undeclared type was not caught"),
    )
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "var", "gsi"))
        img = os.path.join(root, "var", "gsi", "system.img")
        open(img, "wb").write(b"x")
        stale = os.path.join(root, "var", "share", "policy-lab", "cils-system-2050646016-1230796800")
        os.makedirs(stale)
        for n in ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil"):
            open(os.path.join(stale, n), "w").write("")
        _, _, stale_why = inputs(root)
        current = release_cil_dir(root, "system")
        os.makedirs(current)
        for n in ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil"):
            open(os.path.join(current, n), "w").write("")
        _, _, jar_why = inputs(root)
        os.makedirs(os.path.dirname(os.path.join(root, CTS_JAR)))
        open(os.path.join(root, CTS_JAR), "w").write("")
        found_cils, found_jar, none_why = inputs(root)
    cases += (
        (stale_why is not None and "has not cached this GSI's CILs" in stale_why,
         "another image's cached CILs were read as this image's: %r" % stale_why),
        (jar_why is not None and "no CTS package" in jar_why, "an absent CTS jar was not named: %r" % jar_why),
        (none_why is None and found_jar and all(c.startswith(current) for c in found_cils),
         "present inputs were not found under the image's own key: %r" % none_why),
    )
    failed = [msg for ok, msg in cases if not ok]
    if failed:
        for msg in failed:
            print("SELFTEST FAILED: %s" % msg, file=sys.stderr)
        return 1
    print("selftest ok: drops exactly the AV rules naming an optional type the public policy lacks, "
          "keeps them where it declares one, refuses any other statement naming it, and catches "
          "an unresolved type, a type only "
          "the snapshot declares, a live udmabuf_device statement, a missing rhizo_dev_ok, "
          "a validatetrans naming an undeclared type and an unreadable statement")
    return 0


SECILC = os.path.join(ROOT, "var", "share", "policy-lab", "secilc")
RELEASES = (("a15", "gsi_a15"), ("a16", "system"), ("a17", "gsi_a17"))
PLANT = "(allow isolated_app rhizo_sysfs_uinput (file (read open)))\n"


def compile_errors(snapshot_dir, vendor):
    """return CTS secilc's errors compiling the artifact"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "vendor_sepolicy.cil")
        with open(path, "w") as f:
            f.write(vendor)
        r = subprocess.run([SECILC, "-m", "-M", "true", "-G", "-c", "30",
                            os.path.join(snapshot_dir, "plat_sepolicy.cil"), os.path.join(snapshot_dir, "mapping.cil"),
                            path, "-o", os.path.join(tmp, "policy"), "-f", os.devnull],
                           capture_output=True, text=True, timeout=600)
    if r.returncode == 0:
        return ""
    lines = [l.strip() for l in (r.stdout + r.stderr).splitlines()
             if l.startswith(("neverallow", "Failed to resolve")) or "allow " in l]
    return " | ".join(lines[:8]) or (r.stdout + r.stderr).strip()[-300:]


def neverallow_findings():
    """compile every release's artifact against the snapshot"""
    _cils, jar, why = inputs(ROOT)
    found = SEPOLICY_VERSION.search(open(os.path.join(ROOT, MANIFEST)).read())
    if not found or not os.path.exists(jar or "") or not os.access(SECILC, os.X_OK):
        return None, why or "no CTS jar, sepolicy version or CTS secilc"
    version = found.group(1).strip()
    cases = []
    with tempfile.TemporaryDirectory() as snap:
        plat, mapping = cts_snapshot(jar, version)
        for name, text in (("plat_sepolicy.cil", plat), ("mapping.cil", mapping)):
            with open(os.path.join(snap, name), "w") as f:
                f.write(text)
        for release, image in RELEASES:
            cil_dir = release_cil_dir(ROOT, image)
            if not cil_dir or not os.path.isdir(cil_dir):
                return None, "no cached CILs for %s.img: run test/checks/lib/policy-lab.sh once" % image
            cils = [os.path.join(cil_dir, n) for n in ("plat_sepolicy.cil", "system_ext_sepolicy.cil",
                                                       "product_sepolicy.cil")]
            for namespace in (True, False):
                vendor = selinux_policy.cts_vendor_adapt(selinux_policy.build(cils, namespace=namespace))
                cases.append(("%s %s render" % (release, "namespace" if namespace else "host"), vendor))
        cases.append(("planted", dict(cases)["a16 namespace render"] + PLANT))
        with ThreadPoolExecutor(4) as pool:
            got = list(pool.map(lambda c: (c[0], compile_errors(snap, c[1])), cases))
    bad = ["%s: CTS's vendor compile fails: %s" % (name, err) for name, err in got if err and name != "planted"]
    planted = dict(got)["planted"]
    if "neverallow" not in planted or "isolated_app" not in planted:
        bad.append("a planted isolated_app read of rhizo_sysfs_uinput compiled: %r" % planted)
    return bad, None


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    if "--neverallow" in sys.argv:
        bad, why = neverallow_findings()
        if why:
            print("NOT RUN: cts vendor neverallow: %s" % why, file=sys.stderr)
            return 2
        for b in bad:
            print("FAIL: %s" % b, file=sys.stderr)
        if bad:
            return 1
        print("cts vendor neverallow: a15, a16 and a17's artifacts compile in both modes against the frozen "
              "snapshot with its neverallows on, and a planted isolated_app read fails")
        return 0
    cils, jar, why = inputs(ROOT)
    if why:
        print("NOT RUN: cts vendor cil: %s" % why, file=sys.stderr)
        return 2
    found = SEPOLICY_VERSION.search(open(os.path.join(ROOT, MANIFEST)).read())
    if not found:
        print("FAIL: %s declares no <sepolicy><version>" % MANIFEST, file=sys.stderr)
        return 1
    version = found.group(1).strip()
    try:
        snapshot = cts_snapshot(jar, version)
    except KeyError as e:
        print("FAIL: %s bundles no frozen snapshot for sepolicy version %s: %s"
              % (jar, version, e), file=sys.stderr)
        return 1
    public = open(selinux_policy.public_cil_path()).read()
    adapted = selinux_policy.cts_vendor_adapt(selinux_policy.build(cils))
    bad = problems(adapted, [public] + snapshot)
    if bad:
        for b in bad:
            print("FAIL: %s" % b, file=sys.stderr)
        return 1
    print("cts vendor cil: every type the CTS-pull artifact names resolves "
          "against plat_pub_versioned.cil and CTS's %s snapshot" % version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
