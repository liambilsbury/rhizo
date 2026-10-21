#!/usr/bin/env python3
import importlib.util, os, re, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..")
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
from policy_lab_cache import release_cil_dir  # noqa: E402
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-composer-input-sysfs")
from sandbox import selinux_policy  # noqa: E402
LAB_CACHE = os.path.join(ROOT, "var", "share", "policy-lab")
RELEASE_IMAGES = (("a15", "gsi_a15"), ("a16", "system"), ("a17", "gsi_a17"))
CIL = os.path.join(ROOT, "src", "androidd", "guest", "sepolicy", "policy.cil")
UINPUT = os.path.join(ROOT, "src", "android", "hal", "graphics-composer", "src", "input", "uinput.cpp")
NEED = {"dir": {"search", "open", "read"}, "file": {"open", "read"}}
UINPUT_SYSFS = "/devices/virtual/input"


def granted(cil, tclass_type):
    """return rhizo_composer's permissions per class on a type"""
    out = {}
    pattern = r"^\(allow rhizo_composer " + re.escape(tclass_type) + r" \((\w+) \(([^)]*)\)\)\)"
    for cls, perms in re.findall(pattern, cil, re.M):
        out.setdefault(cls, set()).update(perms.split())
    return out


def findings(cil, src):
    """return the broken rules for PublishNode's sysfs reads"""
    if '"/sys/class/input/%s"' not in src:
        return []
    out = []
    m = re.search(r'^\(genfscon sysfs "' + re.escape(UINPUT_SYSFS) + r'" \(u object_r (\w+) ', cil, re.M)
    if not m:
        return [f"no genfscon labels sysfs {UINPUT_SYSFS}"]
    t = m.group(1)
    for attr in ("sysfs_type", "fs_type"):
        if not re.search(r"^\(typeattributeset " + attr + r" \(" + re.escape(t) + r"\)\)", cil, re.M):
            out.append(f"{t} is not in {attr}")
    got = granted(cil, t)
    out += [f"rhizo_composer lacks {t} {cls} {sorted(perms - got.get(cls, set()))}"
            for cls, perms in NEED.items() if perms - got.get(cls, set())]
    wide = granted(cil, "sysfs")
    if wide.get("dir", set()) & {"open", "read"} or wide.get("file", set()) & {"open", "read"}:
        out.append(f"rhizo_composer holds generic sysfs reads: {wide}")
    if not re.search(r"^; @RHIZO_SUBST sysfs_uinput_mirror$", cil, re.M):
        out.append(f"{t}'s sysfs mirror is not rendered per release: no sysfs_uinput_mirror marker")
    return out


MIRROR_FIXTURE = """(type sysfs)
(type sysfs_other)
(typeattribute sysfs_type)
(typeattributeset sysfs_type (sysfs sysfs_other))
(typeattribute base_typeattr_1)
(typeattributeset base_typeattr_1 (sysfs sysfs_other))
(typeattribute base_typeattr_2)
(typeattributeset base_typeattr_2 (and (sysfs_type) (not (sysfs))))
(allow netd sysfs (dir (search open)))
(allow netd sysfs (dir (read)))
(allow kernel sysfs (filesystem (mount)))
(allow vold base_typeattr_1 (file (getattr)))
(allow init sysfs_type (dir (search)))
(allow ueventd base_typeattr_2 (file (write)))
(allowx hal_x sysfs (ioctl file ((range 0x5401 0x5402))))
(allowx domain sysfs_type (ioctl file ((range 0x5450 0x5451))))
(typeattribute base_typeattr_3)
(typeattributeset base_typeattr_3 (and (hal_drm) (not (base_typeattr_4))))
(typeattribute base_typeattr_4)
(typeattributeset base_typeattr_4 (hal_widevine_system))
(allow base_typeattr_3 sysfs (file (read)))
"""
MIRROR_ATTRS = ("(optional rhizo_mirror_base_typeattr_3_block\n(typeattribute rhizo_mirror_base_typeattr_3)\n"
                "(typeattributeset rhizo_mirror_base_typeattr_3 (and (hal_drm) (not (rhizo_mirror_base_typeattr_4))))\n"
                ")\n(optional rhizo_mirror_base_typeattr_4_block\n(typeattribute rhizo_mirror_base_typeattr_4)\n"
                "(typeattributeset rhizo_mirror_base_typeattr_4 (hal_widevine_system))\n)\n")
MIRROR_RULES = ("(allow rhizo_mirror_base_typeattr_3 rhizo_sysfs_uinput (file (read)))",
                "(allow netd rhizo_sysfs_uinput (dir (open read search)))",
                "(allow rhizo_inputd rhizo_sysfs_uinput (dir (search)))",
                "(allow vold rhizo_sysfs_uinput (file (getattr write)))",
                "(deny vold rhizo_sysfs_uinput (file (append write)))",
                "(dontaudit vold rhizo_sysfs_uinput (dir (write)))",
                "(allowx hal_x rhizo_sysfs_uinput (ioctl file ((range 0x5401 0x5402))))")
MIRROR_WANT = MIRROR_ATTRS + "".join(f"(optional rhizo_sysfs_uinput_rule_{i}\n{r}\n)\n"
                                     for i, r in enumerate(MIRROR_RULES))


def mirror_findings(policy=selinux_policy):
    """return the mirror's findings on a fixture"""
    rhizo_policy_mod = policy
    ours = ("(typeattributeset sysfs_type (rhizo_sysfs_uinput))\n"
            "(allow rhizo_inputd sysfs (dir (search)))\n; (allow commented sysfs (dir (search)))\n"
            "(allow vold sysfs (file (write)))\n(deny vold sysfs (file (write append)))\n"
            "(dontaudit vold sysfs (dir (write)))\n")
    with tempfile.TemporaryDirectory() as tmp:
        plat = os.path.join(tmp, "plat_sepolicy.cil")
        with open(plat, "w") as f:
            f.write(MIRROR_FIXTURE)
        got = rhizo_policy_mod.sysfs_mirror([plat], ours)
        out = [] if got == MIRROR_WANT else [f"the sysfs mirror of the fixture is {got!r}, not {MIRROR_WANT!r}"]
        with open(plat, "a") as f:
            f.write("(classpermission sysfs_rw)\n(allow hal_x sysfs sysfs_rw)\n")
        try:
            got = rhizo_policy_mod.sysfs_mirror([plat], ours)
        except ValueError as e:
            got = str(e)
        if "(allow hal_x sysfs sysfs_rw)" not in got:
            out.append(f"an allow form the mirror cannot read passes unnamed: {got!r}")
        with open(plat, "w") as f:
            f.write(MIRROR_FIXTURE + "(permissionx sysfs_ioctls (ioctl file (0x1)))\n"
                    "(allowx hal_y sysfs sysfs_ioctls)\n")
        try:
            got = rhizo_policy_mod.sysfs_mirror([plat], ours)
        except ValueError as e:
            got = str(e)
        if "(allowx hal_y sysfs sysfs_ioctls)" not in got:
            out.append(f"an allowx form the mirror cannot read passes unnamed: {got!r}")
    render = getattr(rhizo_policy_mod, "render_sysfs_mirror", None)
    for label, text in (("no marker", "(type x)\n"),
                        ("two markers", selinux_policy.SYSFS_MIRROR_ANCHOR * 2)):
        try:
            got = render([], text) if render else "no selinux_policy.render_sysfs_mirror"
        except ValueError as e:
            got = str(e)
        if "sysfs_uinput_mirror" not in got:
            out.append(f"a rendered policy with {label} passes unnamed: {got!r}")
    return out


RULE_KINDS = ("allow", "dontaudit", "allowxperm", "dontauditxperm", "auditallowxperm")
RULE_LINE = re.compile(r"(%s) (\S+) \S+:(\S+) (?:(ioctl|nlmsg) )?(?:\{ ([^}]*) \}|([^ ;]+));" % "|".join(RULE_KINDS))
DENY_RULE = re.compile(r"^\(deny (\S+) (\S+) \((\w+) \(([^()]*)\)\)\)", re.M)


def rules(sesearch_text):
    """return each sesearch rule's (kind, source, class, permission)"""
    out = set()
    for line in sesearch_text.splitlines():
        m = RULE_LINE.match(line.strip())
        if not m and line.strip().split(" ", 1)[0] in RULE_KINDS:
            raise ValueError(f"a sesearch rule this check cannot read: {line.strip()}")
        if m:
            kind, source, cls, op, many, one = m.groups()
            out.update((kind, source, cls, (op + " " if op else "") + p) for p in (many or one).split())
    return out


def compare(release, on_sysfs, on_uinput, composer):
    """return the rules the two types disagree on"""
    out = [f"{release}: {s} holds sysfs {k} {c} {p} but not on rhizo_sysfs_uinput"
           for k, s, c, p in sorted(rules(on_sysfs) - rules(on_uinput))]
    out += [f"{release}: {s} holds rhizo_sysfs_uinput {k} {c} {p} but not on sysfs"
            for k, s, c, p in sorted(rules(on_uinput) - rules(on_sysfs) - composer)]
    return out


def compare_denies(release, rendered):
    """return the denies the two types disagree on"""
    got = {t: {(s, c, p) for s, tt, c, ps in DENY_RULE.findall(rendered) if tt == t for p in ps.split()}
           for t in ("sysfs", "rhizo_sysfs_uinput")}
    return ([f"{release}: the render denies {s} sysfs {c} {p} but not rhizo_sysfs_uinput"
             for s, c, p in sorted(got["sysfs"] - got["rhizo_sysfs_uinput"])]
            + [f"{release}: the render denies {s} rhizo_sysfs_uinput {c} {p} but not sysfs"
               for s, c, p in sorted(got["rhizo_sysfs_uinput"] - got["sysfs"])])


def composer_grant(cil):
    """return the composer's dedicated grant as rules"""
    return {("allow", "rhizo_composer", cls, perm)
            for cls, perms in granted(cil, "rhizo_sysfs_uinput").items() for perm in perms}


SECILC = os.path.join(ROOT, "var", "share", "policy-lab", "secilc")
CIL_NAMES = ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil")
DISABLED = re.compile(r"Disabling optional '((?:rhizo_mirror_|rhizo_sysfs_uinput_rule_)[^']*)'")


def disabled_mirror_blocks(cil_dir, rendered):
    """return the mirror blocks the device compile disables"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "rhizo.cil")
        with open(path, "w") as f:
            f.write(rendered)
        r = subprocess.run([SECILC, "-vvv", "-m", "-M", "true", "-G", "-c", "30",
                            *[os.path.join(cil_dir, n) for n in CIL_NAMES], path, "-o", os.path.join(tmp, "policy"),
                            "-f", os.devnull], capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        return ["<the device compile failed: %s>" % (r.stdout + r.stderr).strip()[-200:]]
    return sorted(set(DISABLED.findall(r.stdout + r.stderr)))


def plat_case(release, cil_dir, rendered, composer):
    """compile a render and compare the two types"""
    lab = os.path.join(ROOT, "test", "checks", "lib", "avc-lab.sh")
    with tempfile.TemporaryDirectory() as tmp:
        render = os.path.join(tmp, "rhizo.cil")
        with open(render, "w") as f:
            f.write(rendered)
        out_dir = os.path.join(tmp, "out")
        r = subprocess.run([lab, "build", "--keep-deny", "--render", render, "--out", out_dir], capture_output=True,
                           text=True, timeout=900, env={**os.environ, "RHIZO_POLICY_LAB_CIL_DIR": cil_dir})
        if r.returncode != 0:
            return [f"{release}: the lab policy did not build: {r.stderr.strip()[-300:]}"]
        pol = os.path.join(out_dir, "policy.lab")
        kinds = ["--" + k for k in RULE_KINDS]
        texts = [subprocess.run(["sesearch", *kinds, "-t", t, "-c", "dir,file,lnk_file", pol], capture_output=True,
                                text=True, timeout=300, check=True).stdout for t in ("sysfs", "rhizo_sysfs_uinput")]
    out = [f"{release}: the device compile disables mirror block {b}"
           for b in disabled_mirror_blocks(cil_dir, rendered)]
    if ("allow", "vold", "file", "write") in rules(texts[0]):
        out.append(f"{release}: the compiled sysfs gives vold file write")
    return out + compare(release, texts[0], texts[1], composer) + compare_denies(release, rendered)


def plat_findings():
    """return each rule sysfs and rhizo_sysfs_uinput disagree on"""
    composer = composer_grant(open(CIL).read())
    out, cases = [], []
    for release, image in RELEASE_IMAGES:
        cil_dir = release_cil_dir(ROOT, image)
        if not cil_dir or not os.path.isdir(cil_dir):
            out.append(f"{release}: no single cached CIL directory for {image}.img under {LAB_CACHE}; stage the image "
                       f"and run test/checks/lib/policy-lab.sh once with RHIZO_RELEASE={release}")
            continue
        cils = [os.path.join(cil_dir, n) for n in ("plat_sepolicy.cil", "system_ext_sepolicy.cil",
                                                   "product_sepolicy.cil")]
        for namespace in (True, False):
            rendered = selinux_policy.build(cils, namespace=namespace)
            cases.append((f"{release} {'namespace' if namespace else 'host'} render", cil_dir, rendered))
    with ThreadPoolExecutor(3) as pool:
        for found in pool.map(lambda c: plat_case(*c, composer), cases):
            out += found
    by_name = {name: (cil_dir, rendered) for name, cil_dir, rendered in cases}
    if "a16 namespace render" in by_name:
        cil_dir, rendered = by_name["a16 namespace render"]
        planted, n = re.subn(r"\(typeattributeset (rhizo_mirror_\S+) .*\)\n",
                             r"(typeattributeset \1 (rhizo_no_such_type))\n", rendered, count=1)
        if n != 1 or not disabled_mirror_blocks(cil_dir, planted):
            out.append("a mirror attribute made unresolvable on a16 was not caught as a disabled block")
    return out


def selftest():
    """check a missing and a generic grant are each flagged"""
    cil, src = open(CIL).read(), open(UINPUT).read()
    no_grant = re.sub(r"^\(allow rhizo_composer rhizo_sysfs_uinput .*\n", "", cil, flags=re.M)
    wide = cil + "(allow rhizo_composer sysfs (dir (search open read getattr)))\n"
    static = cil.replace("; @RHIZO_SUBST sysfs_uinput_mirror\n", "(allow netd rhizo_sysfs_uinput (dir (search)))\n")
    cases = (("no grant", no_grant, "rhizo_composer lacks"), ("generic grant", wide, "holds generic sysfs reads"),
             ("a fixed-text mirror", static, "not rendered per release"))
    for name, text, want in cases:
        if not any(want in f for f in findings(text, src)):
            print(f"FAIL selftest: the {name} policy was not flagged ({want}): {findings(text, src)}")
            return 1
    if findings(cil, src) or mirror_findings():
        print(f"FAIL selftest: the real policy is flagged: {findings(cil, src) + mirror_findings()}")
        return 1
    source = open(selinux_policy.__file__).read()
    dropped = source.replace("(allow|deny|dontaudit)", "(allow)")
    if dropped == source:
        print("FAIL selftest: the dropped-deny mutant changed nothing")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "rhizo_policy_dropped_deny.py")
        with open(path, "w") as f:
            f.write(dropped)
        spec = importlib.util.spec_from_file_location("rhizo_policy_dropped_deny", path)
        mutant = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mutant)
        if not any("the sysfs mirror of the fixture" in f for f in mirror_findings(mutant)):
            print(f"FAIL selftest: a mirror that drops Rhizo's deny was not flagged: {mirror_findings(mutant)}")
            return 1
    on_sysfs = ("allow netd sysfs:dir { open read search };\nallow domain sysfs_type:file getattr;\n"
                "dontaudit vold sysfs:file write;\nallowxperm hal_x sysfs:file ioctl { 0x5401-0x5402 };\n")
    on_uinput = ("allow netd rhizo_sysfs_uinput:dir { open search };\nallow domain sysfs_type:file getattr;\n"
                 "allow simpleperf rhizo_sysfs_uinput:dir read;\nallow rhizo_composer rhizo_sysfs_uinput:dir read;\n")
    got = compare("a15", on_sysfs, on_uinput, {("allow", "rhizo_composer", "dir", "read")})
    want = ["a15: netd holds sysfs allow dir read but not on rhizo_sysfs_uinput",
            "a15: hal_x holds sysfs allowxperm file ioctl 0x5401-0x5402 but not on rhizo_sysfs_uinput",
            "a15: vold holds sysfs dontaudit file write but not on rhizo_sysfs_uinput",
            "a15: simpleperf holds rhizo_sysfs_uinput allow dir read but not on sysfs"]
    if got != want:
        print(f"FAIL selftest: the plat comparison found {got}, not a missing allow, dontaudit and ioctl rule and an "
              f"extra rule {want}")
        return 1
    rendered = "(deny vold sysfs (file (write append)))\n(deny vold rhizo_sysfs_uinput (file (write)))\n"
    got = compare_denies("a15 host render", rendered)
    if got != ["a15 host render: the render denies vold sysfs file append but not rhizo_sysfs_uinput"]:
        print(f"FAIL selftest: the deny comparison found {got}, not the missing append deny")
        return 1
    print("composer-input-sysfs selftest: a missing grant, a generic grant, a fixed-text mirror, a dropped deny, a "
          "missing allow, dontaudit, ioctl or deny rule and an extra compiled rule are flagged")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    bad = (plat_findings() if sys.argv[1:] == ["--plat"]
           else findings(open(CIL).read(), open(UINPUT).read()) + mirror_findings())
    for b in bad:
        print("FAIL", b)
    if bad:
        sys.exit(1)
    print("ok")
