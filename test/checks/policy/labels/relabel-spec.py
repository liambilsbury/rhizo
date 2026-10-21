#!/usr/bin/env python3
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SOURCES = [os.path.join(REPO, "src", "androidd", n)
           for n in ("sandbox/selinux_labels.py", "boot.py")]


def read_sources():
    """return the text of every source"""
    return "\n".join(open(f).read() for f in SOURCES)

PRIMER_ONLY = {
    "/vendor/manifest.xml",
    "/vendor/compatibility_matrix.xml",
}


def pre_init_entries(src):
    """return the PRE_INIT_RELABEL entries"""
    found = None
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) in ("PRE_INIT_RELABEL", "PRE_INIT_RELABEL_IF_PRESENT")
                for t in node.targets):
            found = dict(found or {}, **dict(ast.literal_eval(node.value)))
    return found


def primer_entries(src):
    """return the pairs from _RELABEL_SPEC in the primer source"""
    m = re.search(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', src, re.S)
    if not m:
        return None
    body = m.group(1)
    start = body.find("_RELABEL_SPEC")
    if start < 0:
        return None
    out = {}
    for line in body[start:].split("\n"):
        if line.strip() == "]":
            break
        hit = re.match(r'\s*\("([^"]+)",\s*"([^"]+)"\),', line)
        if hit:
            out[hit.group(1)] = hit.group(2)
    return out


def check(src):
    """return the disagreements between the two relabel lists"""
    pre = pre_init_entries(src)
    if pre is None:
        return ["no PRE_INIT_RELABEL list in %s" % ", ".join(os.path.basename(f) for f in SOURCES)]
    prim = primer_entries(src)
    if prim is None:
        return ["HOST_PRIMER_SRC has no _RELABEL_SPEC list"]
    bad = []
    for path, label in sorted(pre.items()):
        if path not in prim:
            bad.append("%s is relabeled before init but absent from the primer's "
                       "_RELABEL_SPEC" % path)
        elif prim[path] != label:
            bad.append("%s disagrees: pre-init says %s, the primer says %s"
                       % (path, label, prim[path]))
    for path in sorted(prim):
        if path not in pre and path not in PRIMER_ONLY:
            bad.append("%s is in the primer's _RELABEL_SPEC only" % path)
    for path in sorted(PRIMER_ONLY):
        if path in pre:
            bad.append("%s is in PRIMER_ONLY yet also in PRE_INIT_RELABEL -- "
                       "drop it from the allowlist" % path)
    return bad


CIL = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")


def read_cil():
    """return the text of the policy file"""
    return open(CIL).read()


def parse_cil(text):
    """return the CIL text as nested lists"""
    text = re.sub(r";[^\n]*", "", text)
    stack, cur = [], []
    for tok in re.findall(r"\(|\)|[^\s()]+", text):
        if tok == "(":
            stack.append(cur)
            cur = []
        elif tok == ")":
            done, cur = cur, stack.pop()
            cur.append(done)
        else:
            cur.append(tok)
    return cur


def relabel_targets(cil, domain="rhizo_host"):
    """return the types a domain may relabel to"""
    attrs, targets = {}, set()
    for form in parse_cil(cil):
        if not isinstance(form, list) or not form:
            continue
        if form[0] == "typeattributeset" and len(form) == 3 and isinstance(form[2], list):
            attrs.setdefault(form[1], set()).update(t for t in form[2] if isinstance(t, str))
        elif (form[0] == "allow" and len(form) == 4 and form[1] == domain
              and isinstance(form[3], list) and len(form[3]) == 2
              and isinstance(form[3][1], list) and "relabelto" in form[3][1]):
            targets.add(form[2])
    seen, todo = set(), list(targets)
    while todo:
        t = todo.pop()
        if t not in seen:
            seen.add(t)
            todo.extend(attrs.get(t, ()))
    return seen


def helper_fragment():
    """return the namespace helper domains' CIL"""
    sys.path.insert(0, os.path.join(REPO, "src", "androidd"))
    from sandbox import selinux_policy
    return selinux_policy.NAMESPACE_HELPER_DOMAINS


def relabellers(cil, fragment):
    """return each relabeling domain with the types it may relabel to"""
    return (("rhizo_host", relabel_targets(cil)),
            ("rhizo_ns_relabel", relabel_targets(cil + "\n" + fragment, "rhizo_ns_relabel")))


def grant_findings(src, cil, fragment):
    """return the relabels that lack a policy grant"""
    wanted = dict(primer_entries(src) or {})
    wanted.update(pre_init_entries(src) or {})
    bad = []
    for domain, granted in relabellers(cil, fragment):
        for path, label in sorted(wanted.items()):
            typ = label.split(":")[2]
            if typ not in granted:
                bad.append("%s is relabeled to %s, but the policy grants %s no relabelto "
                           "on it -- add it to rhizo_relabel_dest_file or rhizo_relabel_dest_dev" % (path, typ, domain))
    return bad


MOUNTS = os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")
STAGED_PRIMER = '"@RHIZO_COLDBOOT_RELABEL@"'
STAGED_PRE_INIT = "relabel_root_objects_now(NEWROOT, staged=coldboot_primer_spec())"


def coldboot_spec():
    """return the cold boot relabel spec from the mounts module"""
    os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-relabel-spec")
    sys.path.insert(0, os.path.join(REPO, "src", "androidd"))
    import contextlib
    import io
    with contextlib.redirect_stdout(io.StringIO()):
        from sandbox import rootfs
    return rootfs.coldboot_primer_spec()


def staged_findings(src, mounts_src, cil, spec, fragment):
    """return the problems with the staged node relabel"""
    bad = []
    if STAGED_PRIMER not in src:
        bad.append("the primer no longer reads the staged nodes' labels (%s)" % STAGED_PRIMER)
    if STAGED_PRE_INIT not in mounts_src:
        bad.append("sandbox/rootfs.py no longer passes coldboot_primer_spec() to the restart's pre-init "
                   "relabel (%s)" % STAGED_PRE_INIT)
    for domain, granted in relabellers(cil, fragment):
        for path, label in spec:
            if label.split(":")[2] not in granted:
                bad.append("staged %s is relabeled to %s, which %s may not relabel to"
                           % (path, label.split(":")[2], domain))
    return bad


def selftest():
    """test the checks on mutated sources"""
    src = read_sources()
    n = 0
    assert pre_init_entries(src), "PRE_INIT_RELABEL not found in the real tree"
    n += 1
    assert primer_entries(src), "_RELABEL_SPEC not found in the real tree"
    n += 1
    assert check(src) == [], "the real tree should agree with itself: %s" % check(src)
    n += 1
    etc_line = '    ("/etc",                             "u:object_r:rootfs:s0"),'
    broken = src.replace(etc_line + "\n", "", 1)
    assert broken != src, "fixture did not apply: the primer's /etc line moved"
    assert any("/etc" in f and "absent" in f for f in check(broken)), \
        "a pre-init entry missing from the primer's spec must be reported"
    n += 1
    skewed = src.replace(etc_line,
                         '    ("/etc",                             "u:object_r:tmpfs:s0"),', 1)
    assert skewed != src, "fixture did not apply"
    assert any("/etc" in f and "disagrees" in f for f in check(skewed)), \
        "a label disagreement must be reported"
    n += 1
    spec_line = '        ("/vendor/manifest.xml",             "u:object_r:vendor_configs_file:s0"),'
    orphan = src.replace(
        spec_line,
        spec_line + '\n        ("/only/in/the/primer", "u:object_r:system_file:s0"),', 1)
    assert orphan != src, "fixture did not apply: the spec's manifest line moved"
    assert any("/only/in/the/primer" in f and "primer" in f for f in check(orphan)), \
        "a primer-only entry outside the allowlist must be reported"
    n += 1
    manifest_twin = src.replace(
        'PRE_INIT_RELABEL = [',
        'PRE_INIT_RELABEL = [\n    ("/vendor/manifest.xml", "u:object_r:vendor_configs_file:s0"),', 1)
    assert manifest_twin != src, "fixture did not apply"
    assert any("PRIMER_ONLY" in f and "/vendor/manifest.xml" in f
               for f in check(manifest_twin)), \
        "an allowlisted entry duplicated into PRE_INIT_RELABEL must be reported"
    n += 1
    cil = read_cil()
    fragment = helper_fragment()
    assert grant_findings(src, cil, fragment) == [], \
        "every relabel destination in the real tree should carry a relabelto: %s" % grant_findings(src, cil, fragment)
    n += 1
    no_tun = re.sub(r"(\(typeattributeset rhizo_relabel_dest_dev \([^)]*?)\btun_device\b", r"\1", cil, count=1, flags=re.S)
    assert no_tun != cil, "fixture did not apply: tun_device is not in rhizo_relabel_dest_dev"
    found = grant_findings(src, no_tun, fragment)
    assert any("/dev/tun" in f and "tun_device" in f and "rhizo_host" in f for f in found), \
        "a relabel destination with no relabelto grant must be reported"
    n += 1
    assert any("/dev/tun" in f and "tun_device" in f and "rhizo_ns_relabel" in f for f in found), \
        "a relabel destination the namespace relabeller may not relabel to must be reported"
    n += 1
    no_root = "".join(l for l in fragment.splitlines(keepends=True)
                      if not l.startswith(("(allow rhizo_ns_relabel rootfs (dir (relabelto)))",
                                           "(allow rhizo_ns_relabel rootfs (lnk_file (relabelto)))")))
    assert no_root != fragment, "fixture did not apply: the fragment has no rootfs relabelto"
    found = grant_findings(src, cil, no_root)
    assert found and all("rhizo_ns_relabel" in f and "rootfs" in f for f in found), \
        "a rootfs relabelto only rhizo_host holds must be reported for rhizo_ns_relabel alone: %s" % found
    n += 1
    new_node = src.replace(
        'PRE_INIT_RELABEL = [',
        'PRE_INIT_RELABEL = [\n    ("/dev/made_up", "u:object_r:made_up_device:s0"),', 1)
    assert any("/dev/made_up" in f for f in grant_findings(new_node, cil, fragment)), \
        "a new pre-init entry whose type the policy never grants must be reported"
    n += 1
    commented = cil + "\n; (allow rhizo_host made_up_device (chr_file (relabelto)))\n"
    assert any("/dev/made_up" in f for f in grant_findings(new_node, commented, fragment)), \
        "a relabelto that exists only in a comment must not count"
    n += 1
    mounts_src, spec = open(MOUNTS).read(), coldboot_spec()
    assert spec, "coldboot_primer_spec() is empty in the real tree"
    n += 1
    assert staged_findings(src, mounts_src, cil, spec, fragment) == [], \
        "the real tree's staged nodes should reach both passes: %s" % staged_findings(src, mounts_src, cil, spec, fragment)
    n += 1
    assert any("pre-init" in f for f in staged_findings(
        src, mounts_src.replace(STAGED_PRE_INIT, "relabel_root_objects_now(NEWROOT)"), cil, spec, fragment)), \
        "a restart pass that drops the staged nodes must be reported"
    n += 1
    assert any("primer" in f for f in staged_findings(src.replace(STAGED_PRIMER, '""'), mounts_src, cil, spec, fragment)), \
        "a primer that drops the staged nodes must be reported"
    n += 1
    no_fuse = re.sub(r"(\(typeattributeset rhizo_relabel_dest_dev \([^)]*?)\bfuse_device\b", r"\1", cil,
                     count=1, flags=re.S)
    assert no_fuse != cil, "fixture did not apply: fuse_device is not in rhizo_relabel_dest_dev"
    assert any("/dev/fuse" in f for f in staged_findings(src, mounts_src, no_fuse, spec, fragment)), \
        "a staged label with no relabelto grant must be reported"
    n += 1
    print("check-relabel-spec selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    src = read_sources()
    fragment = helper_fragment()
    findings = (check(src) + grant_findings(src, read_cil(), fragment)
                + staged_findings(src, open(MOUNTS).read(), read_cil(), coldboot_spec(), fragment))
    for f in findings:
        print("check-relabel-spec: " + f)
    sys.exit(1 if findings else 0)
