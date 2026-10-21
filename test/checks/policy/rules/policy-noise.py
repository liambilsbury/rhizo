#!/usr/bin/env python3
"""check the in-Android policy noise fixes"""

import ast
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
LAB = os.path.join(REPO, "test", "checks", "lib", "policy-lab.sh")
sys.path.insert(0, os.path.join(REPO, "src", "androidd"))
_SPEC = importlib.util.spec_from_file_location("check_host_tty_policy", os.path.join(HERE, "host-tty-policy.py"))
tty = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(tty)

from sandbox import selinux_policy  # noqa: E402

MESA_TYPE = "vendor_rhizo_mesa_prop"
READ = "read open getattr map"
READERS = ("system_server", "surfaceflinger", "virtual_camera", "bootanim", "untrusted_app", "platform_app",
           "priv_app", "rhizo_gralloc_allocator", "rhizo_composer")
ATTRS_HELD = ("property_type", "vendor_property_type", "vendor_restricted_property_type")
ATTRS_REFUSED = ("vendor_internal_property_type", "vendor_public_property_type", "system_property_type")
PCI_READS = (("dir", "search read open getattr"), ("file", "read open getattr"), ("lnk_file", "read getattr"))
PCI_RULES = tuple("(allow virtual_camera rhizo_sysfs_pci (%s (%s)))" % (c, p) for c, p in PCI_READS)
NAMES = (("vendor.mesa.glsl.validate", MESA_TYPE), ("vendor.mesa.loader.driver.override", MESA_TYPE),
         ("vendor.rhizo.unrelated", "vendor_default_prop"))
_RULE = re.compile(r"^allow \S+ \S+:(\S+) (?:\{ ([^{}]*) \}|(\S+));$")


def granted(policy, domain, label, cls):
    """return the perms allowed from domain to label"""
    r = subprocess.run(["sesearch", "--allow", "-s", domain, "-t", label, "-c", cls, policy],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, "sesearch rc=%d %s" % (r.returncode, r.stderr.strip())
    perms = set()
    for m in (_RULE.match(l.strip()) for l in r.stdout.splitlines()):
        if m and m.group(1) == cls:
            perms.update((m.group(2) or m.group(3)).split())
    return perms, None


def attributes(policy, type_name):
    """return the attributes seinfo lists for type_name"""
    r = subprocess.run(["seinfo", policy, "-t", type_name, "-x"], capture_output=True, text=True)
    if r.returncode != 0:
        return None, "seinfo rc=%d %s" % (r.returncode, r.stderr.strip())
    m = re.search(r"type %s((?:, \S+?)*);" % re.escape(type_name), r.stdout)
    return (set(a.strip() for a in m.group(1).split(",") if a.strip()) if m else None), None


def init_transitions(policy, kind, perm):
    """return the targets of init's process rules"""
    r = subprocess.run(["sesearch", "--" + kind, "-s", "init", "-c", "process", "-p", perm, policy],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, "sesearch rc=%d %s" % (r.returncode, r.stderr.strip())
    return {l.split()[2].split(":")[0] for l in r.stdout.splitlines()
            if l.startswith(kind + " init ") and perm in re.sub(r"[{};]", " ", l).split()}, None


def noatsecure_problems(policy):
    """return init's Rhizo transitions lacking AOSP's noatsecure dontaudit"""
    entered, err = init_transitions(policy, "allow", "transition")
    quiet, err2 = init_transitions(policy, "dontaudit", "noatsecure")
    if err or err2:
        return ["init's process rules unread: %s" % (err or err2)]
    return ["init's transition into %s lacks dontaudit init %s:process noatsecure" % (t, t)
            for t in sorted(t for t in entered - quiet if t.startswith("rhizo_"))]


def policy_problems(policy):
    """return the compiled namespace-mode policy's problems"""
    bad = noatsecure_problems(policy)
    for domain in READERS:
        have, err = granted(policy, domain, MESA_TYPE, "file")
        missing = sorted(set(READ.split()) - (have or set()))
        if err or missing:
            bad.append("%s lacks %s on %s:file%s" % (domain, " ".join(missing), MESA_TYPE, ": " + err if err else ""))
    attrs, err = attributes(policy, MESA_TYPE)
    if err:
        bad.append("%s attributes unread: %s" % (MESA_TYPE, err))
    elif attrs is None:
        bad.append("%s is not declared" % MESA_TYPE)
    else:
        for a in ATTRS_HELD:
            if a not in attrs:
                bad.append("%s lacks attribute %s" % (MESA_TYPE, a))
        for a in ATTRS_REFUSED:
            if a in attrs:
                bad.append("%s carries attribute %s" % (MESA_TYPE, a))
    for cls, perms in PCI_READS:
        have, err = granted(policy, "virtual_camera", "rhizo_sysfs_pci", cls)
        missing = sorted(set(perms.split()) - (have or set()))
        if err or missing:
            bad.append("virtual_camera lacks %s on rhizo_sysfs_pci:%s%s" % (" ".join(missing), cls,
                                                                            ": " + err if err else ""))
    have, err = granted(policy, "netd", "kernel", "system")
    if err or "module_request" in (have or set()):
        bad.append("netd holds module_request on kernel:system%s" % (": " + err if err else ""))
    return bad


def resolve(name, files):
    """return the property type policy-lab's resolver gives name across files"""
    r = subprocess.run(["bash", "-c", 'lab=$0; args=("$@"); set -- -h; source "$lab" >/dev/null 2>&1; '
                        'property_resolve "${args[@]}"', LAB, name] + list(files),
                       capture_output=True, text=True)
    return r.stdout.split("\t")[0].strip() if r.returncode == 0 else "<rc=%d %s>" % (r.returncode, r.stderr.strip())


def context_problems(files):
    """return the property names resolving to a wrong type"""
    bad = []
    for name, want in NAMES:
        got = resolve(name, files)
        if got != want:
            bad.append("%s resolves to %s, wanted %s" % (name, got, want))
    return bad


def host_problems(host_cil, host_contexts):
    """return host mode's render and property contexts problems"""
    bad = []
    if MESA_TYPE in host_cil:
        bad.append("host mode's policy renders %s" % MESA_TYPE)
    if "vendor.mesa." in host_contexts:
        bad.append("host mode stages a vendor.mesa. property context")
    for rule in PCI_RULES:
        if rule not in host_cil:
            bad.append("host mode's policy lacks %s" % rule)
    return bad


def staging_problems():
    """return the launcher's vendor property contexts staging problems"""
    tree = ast.parse(open(os.path.join(REPO, "src", "androidd", "boot.py")).read())
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_stage_vendor_scaffold"), None)
    text = ast.unparse(fn) if fn else ""
    if "selinux_policy.vendor_property_contexts(not host_selinux_mode())" not in text:
        return ["_stage_vendor_scaffold does not write selinux_policy.vendor_property_contexts(not host_selinux_mode())"]
    return []


def lab_paths():
    """return the GSI's CIL and property_contexts paths from policy-lab"""
    r = subprocess.run(["bash", "-c", 'lab=$0; set -- -h; source "$lab" >/dev/null 2>&1; ensure_gsi_cils >/dev/null || '
                        'exit 9; printf "%s\\n" "$PLAT_CIL" "$SYSTEM_EXT_CIL" "$PRODUCT_CIL" "$PLAT_PROP" '
                        '"$SYSTEM_EXT_PROP" "$PRODUCT_PROP"', LAB], capture_output=True, text=True)
    paths = r.stdout.split()
    if r.returncode != 0 or len(paths) != 6:
        sys.exit("check-policy-noise: policy-lab could not extract the GSI CILs (rc=%d) %s" % (r.returncode,
                                                                                            r.stderr.strip()))
    return paths[:3], paths[3:]


def fixture_cil(drop=(), extra=""):
    """return a fixture CIL"""
    lines = ["(class file (read open getattr map))", "(class dir (search read open getattr))",
             "(class lnk_file (read getattr))", "(class system (module_request))",
             "(class process (transition noatsecure siginh rlimitinh))",
             "(classorder (file dir lnk_file system process))", "(sid kernel)", "(sidorder (kernel))", "(user u)",
             "(role r)",
             "(type fixture_kernel)", "(roletype r fixture_kernel)", "(category c0)", "(categoryorder (c0))",
             "(sensitivity s0)", "(sensitivityorder (s0))", "(sensitivitycategory s0 (c0))", "(userlevel u (s0))",
             "(userrange u ((s0) (s0 (c0))))", "(userrole u r)",
             "(sidcontext kernel (u r fixture_kernel ((s0) (s0))))"]
    lines += ["(type %s)" % t for t in sorted(set(READERS) | {"netd", "kernel", MESA_TYPE, "rhizo_sysfs_pci", "init",
                                                              "rhizo_fixture_hal"})]
    lines.append("(allow init rhizo_fixture_hal (process (transition siginh rlimitinh)))")
    if ("noatsecure", "rhizo_fixture_hal") not in drop:
        lines.append("(dontaudit init rhizo_fixture_hal (process (noatsecure)))")
    lines += ["(typeattribute %s)" % a for a in ATTRS_HELD + ATTRS_REFUSED]
    lines.append("(expandtypeattribute (%s) false)" % " ".join(ATTRS_HELD + ATTRS_REFUSED))
    for a in ATTRS_HELD:
        if ("attr", a) not in drop:
            lines.append("(typeattributeset %s (%s))" % (a, MESA_TYPE))
    for d in READERS:
        if ("read", d) not in drop:
            lines.append("(allow %s %s (file (%s)))" % (d, MESA_TYPE, READ))
    for cls, perms in PCI_READS:
        if ("pci", cls) not in drop:
            lines.append("(allow virtual_camera rhizo_sysfs_pci (%s (%s)))" % (cls, perms))
    return "\n".join(lines) + "\n" + extra


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-policy-noise.")

    def expect(label, got, want):
        """compare findings with the wanted texts"""
        for w in want:
            if not any(w in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, w, got))
        if not want and got:
            fails.append("%s: wanted no finding, got %r" % (label, got))

    def compiled(label, cil):
        """compile a fixture and return its problems"""
        src, out = os.path.join(tmp, "p.cil"), os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(cil)
        r = subprocess.run(["secilc", "-m", "-M", "true", "-G", "-c", "30", src, "-o", out, "-f", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("%s: the fixture does not compile: %s" % (label, (r.stderr or r.stdout).strip()))
            return None
        return policy_problems(out)

    try:
        for label, cil, want in (
                ("the full set", fixture_cil(), []),
                ("system_server's read missing", fixture_cil(drop={("read", "system_server")}),
                 ["system_server lacks getattr map open read on %s:file" % MESA_TYPE]),
                ("the restricted attribute missing", fixture_cil(drop={("attr", "vendor_restricted_property_type")}),
                 ["%s lacks attribute vendor_restricted_property_type" % MESA_TYPE]),
                ("an internal Mesa type",
                 fixture_cil(extra="(typeattributeset vendor_internal_property_type (%s))\n" % MESA_TYPE),
                 ["%s carries attribute vendor_internal_property_type" % MESA_TYPE]),
                ("virtual_camera's lnk_file read missing", fixture_cil(drop={("pci", "lnk_file")}),
                 ["virtual_camera lacks getattr read on rhizo_sysfs_pci:lnk_file"]),
                ("netd granted module_request", fixture_cil(extra="(allow netd kernel (system (module_request)))\n"),
                 ["netd holds module_request on kernel:system"]),
                ("init's noatsecure audited", fixture_cil(drop={("noatsecure", "rhizo_fixture_hal")}),
                 ["init's transition into rhizo_fixture_hal lacks dontaudit init rhizo_fixture_hal:process "
                  "noatsecure"])):
            got = compiled(label, cil)
            if got is not None:
                expect(label, got, want)
        plat = os.path.join(tmp, "plat_property_contexts")
        with open(plat, "w") as f:
            f.write("vendor.                 u:object_r:vendor_default_prop:s0\n")
        good, empty = os.path.join(tmp, "vendor_good"), os.path.join(tmp, "vendor_empty")
        with open(good, "w") as f:
            f.write("vendor.mesa. u:object_r:%s:s0 prefix\n" % MESA_TYPE)
        open(empty, "w").close()
        expect("seinfo fails", policy_problems(os.path.join(tmp, "absent.bin")),
               ["%s attributes unread: seinfo rc=" % MESA_TYPE])
        expect("the vendor.mesa. entry", context_problems([plat, good]), [])
        expect("no vendor.mesa. entry", context_problems([plat, empty]),
               ["vendor.mesa.glsl.validate resolves to vendor_default_prop, wanted %s" % MESA_TYPE])
        host_ok = "\n".join(PCI_RULES) + "\n"
        expect("host mode clean", host_problems(host_ok, ""), [])
        expect("host mode with the Mesa type", host_problems(host_ok + "(type %s)\n" % MESA_TYPE,
                                                             "vendor.mesa. u:object_r:%s:s0 prefix\n" % MESA_TYPE),
               ["host mode's policy renders %s" % MESA_TYPE, "host mode stages a vendor.mesa. property context"])
        expect("host mode without the virtual_camera grant", host_problems("", ""),
               ["host mode's policy lacks %s" % PCI_RULES[0]])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-policy-noise selftest: ok (a missing reader grant, a wrong attribute, a missing virtual_camera grant, a "
          "netd module_request, a missing vendor.mesa. entry and host-mode leaks caught; the full set passes)")
    return 0


def main():
    """run the selftest or judge the lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    cils, props = lab_paths()
    found = staging_problems()
    vendor_ctx = getattr(selinux_policy, "vendor_property_contexts", None)
    if vendor_ctx is None:
        found.append("selinux_policy has no vendor_property_contexts")
    lab_dir = tempfile.mkdtemp(prefix="check-policy-noise-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found += policy_problems(policy)
        if vendor_ctx is not None:
            vendor = os.path.join(lab_dir, "vendor_property_contexts")
            with open(vendor, "w") as f:
                f.write(vendor_ctx(True))
            found += context_problems([props[0], props[1], vendor, props[2]])
            found += host_problems(selinux_policy.build(cils, namespace=False), vendor_ctx(False))
        else:
            found += host_problems(selinux_policy.build(cils, namespace=False), "")
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: policy noise: " + p)
    if found:
        return 1
    print("ok: %d readers hold %s, it is vendor-restricted, vendor.mesa.* resolves to it in namespace mode alone, "
          "virtual_camera reads rhizo_sysfs_pci in both modes and netd holds no module_request" % (len(READERS),
                                                                                                MESA_TYPE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
