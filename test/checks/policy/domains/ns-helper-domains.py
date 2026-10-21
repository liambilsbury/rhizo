#!/usr/bin/env python3
"""check the namespace helper domains against the compiled policy"""

import argparse
import collections
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))

from sandbox import selinux_policy  # noqa: E402
from policy_lab_cache import release_cil_dir  # noqa: E402

CENSUS = os.path.join(ROOT, "test", "checks", "data", "ns-helper-census.tsv")
BASELINE = os.path.join(ROOT, "test", "checks", "data", "ns-helper-baseline.tsv")
ALL_HELPERS = "rhizo_ns_helper"
KERNEL = "kernel"
WALK_PERMS = {"getattr", "open", "read", "search"}
WALK_ATTRIBUTES = ("file_type", "dev_type")
SWEPT_ATTRIBUTES = ("file_type", "dev_type", "fs_type", "domain", "coredomain")
HELPER_RULE = re.compile(r"^\(allow (rhizo_ns_\w+) (\S+) \((\w+) \(([^()]*)\)\)\)", re.M)
POLICY_LAB = os.path.join(ROOT, "test", "checks", "lib", "policy-lab.sh")
AVC_LAB = os.path.join(ROOT, "test", "checks", "lib", "avc-lab.sh")
RELEASES = (("a15", "gsi_a15", ""), ("a16", "system", ""), ("a17", "gsi_a17", ""),
            ("a16 userdebug", "gsi_userdebug", "su"))
CIL_NAMES = ("plat_sepolicy.cil", "system_ext_sepolicy.cil", "product_sepolicy.cil")
HELPER_TYPES = ("rhizo_ns_stage", "rhizo_ns_relabel", "rhizo_ns_label")
DENIED_BY_DESIGN = (
    ("rhizo_ns_stage", "self", "capability", "dac_read_search"),
    ("rhizo_ns_stage", "self", "capability", "setfcap"),
    ("rhizo_ns_relabel", "self", "capability", "dac_read_search"),
    ("rhizo_ns_relabel", "kernel", "security", "setenforce"),
)
FORBIDDEN_ATTRIBUTES = ("domain", "coredomain")
NO_IOCTL = "-"
HELPER_TITLES = (
    (re.compile(r"^cp -a "), "rhizo_ns_stage"),
    (re.compile(r"stage-gsi-labeled"), "rhizo_ns_stage"),
    (re.compile(r"rhizo-host-primer\.py --relabel-flat"), "rhizo_ns_relabel"),
    (re.compile(r"launcher3\.py selinuxns-relabeller"), "rhizo_ns_relabel"),
    (re.compile(r"launcher3\.py selinux_setup"), "rhizo_ns_relabel"),
    (re.compile(r"launcher3\.py prepare-tree"), "rhizo_ns_relabel"),
    (re.compile(r"launcher3\.py in-android-policy materialize-data-template"), "rhizo_ns_relabel"),
    (re.compile(r"launcher3\.py in-android-policy (?:label|label-fd|hostfs-label-lower)\b"), "rhizo_ns_label"),
)
SELF_CLASSES = ("capability", "capability2", "process", "cap_userns")
RECORD_KEY = re.compile(r"audit\((\d+\.\d+:\d+)\)")
PROCTITLE = re.compile(r"proctitle=(\S+)")
KERNEL_AVC = re.compile(r'avc:\s+denied\s+\{ ([^}]*)\}.*? pid=(\d+) .*?scontext=u:r:kernel:s0 '
                        r'tcontext=(\S+) tclass=(\S+)')
IOCTL_COMMAND = re.compile(r"ioctlcmd=(0x[0-9a-fA-F]+)")


def decode_title(raw):
    """return a PROCTITLE value as text"""
    try:
        return bytes.fromhex(raw).replace(b"\0", b" ").decode(errors="replace")
    except ValueError:
        return raw.strip('"')


def helper_of(title):
    """return the helper domain whose process title this is, or None"""
    for pattern, domain in HELPER_TITLES:
        if pattern.search(title):
            return domain
    return None


def derive(policy_types, logs):
    """return the census rows and the denials no helper owns"""
    rows = set()
    unowned = collections.Counter()
    for path in logs:
        syscall_pid = {}
        titles = {}
        denials = []
        with open(path, errors="replace") as handle:
            for line in handle:
                key = RECORD_KEY.search(line)
                if not key:
                    continue
                if line.startswith("type=PROCTITLE"):
                    found = PROCTITLE.search(line)
                    if found:
                        titles[key.group(1)] = decode_title(found.group(1))
                elif line.startswith("type=SYSCALL"):
                    pid = re.search(r" pid=(\d+)", line)
                    if pid:
                        syscall_pid[key.group(1)] = pid.group(1)
                elif line.startswith("type=AVC") and "scontext=u:r:kernel:s0" in line:
                    denials.append(line)
        pid_domain = {}
        for key, title in titles.items():
            domain = helper_of(title)
            pid = syscall_pid.get(key)
            if pid and domain and pid_domain.setdefault(pid, domain) != domain:
                raise ValueError("pid %s in %s is two helpers: %s and %s" % (pid, path, pid_domain[pid], domain))
        for line in denials:
            found = KERNEL_AVC.search(line)
            if not found:
                raise ValueError("unreadable kernel denial in %s: %s" % (path, line.strip()[:200]))
            perms, pid, target_context, target_class = found.groups()
            domain = pid_domain.get(pid)
            if domain is None:
                unowned[pid] += 1
                continue
            target = target_context.split(":")[2]
            if target == "kernel" and target_class in SELF_CLASSES:
                target = "self"
            elif target not in policy_types:
                target = "unlabeled"
            command = IOCTL_COMMAND.search(line)
            for perm in perms.split():
                rows.add((domain, target, target_class, perm, NO_IOCTL))
                if perm == "ioctl" and command:
                    rows.add((domain, target, target_class, perm, command.group(1).lower()))
    return sorted(rows), unowned


def read_census(path=CENSUS):
    """return the census rows"""
    rows = []
    with open(path) as handle:
        for number, line in enumerate(handle, 1):
            if line.startswith("#") or not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 5:
                raise ValueError("%s:%d has %d fields, wanted 5" % (path, number, len(fields)))
            rows.append(tuple(fields))
    return rows


def read_baseline(path=BASELINE):
    """return the baseline rows"""
    rows = []
    with open(path) as handle:
        for number, line in enumerate(handle, 1):
            if line.startswith("#") or not line.strip():
                continue
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 6:
                raise ValueError("%s:%d has %d fields, wanted 6" % (path, number, len(fields)))
            domain, target, cls, perms, command, basis = fields
            if basis not in (KERNEL, "code"):
                raise ValueError("%s:%d has the basis %r, wanted kernel or code" % (path, number, basis))
            for holder in (HELPER_TYPES if domain == ALL_HELPERS else (domain,)):
                for perm in perms.split():
                    rows.append((holder, target, cls, perm, NO_IOCTL, basis))
                if command != NO_IOCTL:
                    rows.append((holder, target, cls, "ioctl", command, basis))
    return rows


def cil_paths(image):
    """return a release's cached CIL paths, or None"""
    directory = release_cil_dir(ROOT, image)
    if not directory:
        return None
    paths = [os.path.join(directory, name) for name in CIL_NAMES]
    return paths if all(os.path.exists(p) for p in paths) else None


RENDER_LOCK = threading.Lock()


def render_policy(cils, fragment):
    """return the namespace policy rendered with the fragment"""
    with RENDER_LOCK:
        saved = selinux_policy.NAMESPACE_HELPER_DOMAINS
        selinux_policy.NAMESPACE_HELPER_DOMAINS = fragment
        try:
            return selinux_policy.build(cils, namespace=True)
        finally:
            selinux_policy.NAMESPACE_HELPER_DOMAINS = saved


def tool(args, env=None):
    """return (rc, output) of a command"""
    result = subprocess.run(args, capture_output=True, text=True, timeout=1200, env=env, cwd=ROOT)
    return result.returncode, result.stdout + result.stderr


def first_lines(text, needle, count=3):
    """return the first lines of text that contain needle"""
    return " | ".join([l.strip() for l in text.splitlines() if needle in l][:count])


def compile_release(name, image, fragment, workdir):
    """compile a release's rendered policy"""
    cils = cil_paths(image)
    if cils is None:
        return None, None, ["%s: no cached CILs for %s.img, run test/checks/lib/policy-lab.sh once" % (name, image)]
    rendered = render_policy(cils, fragment)
    directory = os.path.join(workdir, image)
    os.makedirs(directory)
    render = os.path.join(directory, "rendered.cil")
    with open(render, "w") as handle:
        handle.write(rendered)
    env = dict(os.environ, RHIZO_POLICY_LAB_CIL_DIR=os.path.dirname(cils[0]))
    out = os.path.join(directory, "out")
    rc, text = tool(["bash", AVC_LAB, "build", "--render", render, "--out", out], env)
    if rc != 0:
        detail = first_lines(text, "neverallow") or first_lines(text, "rror") or text.strip()[-300:]
        return None, out, ["%s: secilc does not compile the policy (rc=%d): %s" % (name, rc, detail)]
    return os.path.join(out, "policy.lab"), out, []


def permissive_problems(name, image, out, expected):
    """return the problems of the compiled policy's permissive types"""
    cils = cil_paths(image)
    env = dict(os.environ, RHIZO_POLICY_LAB_CIL_DIR=os.path.dirname(cils[0]))
    rc, text = tool(["bash", POLICY_LAB, "permissive", os.path.join(out, "precompiled_sepolicy"), "--expect", expected], env)
    if rc != 0:
        return ["%s: the policy holds permissive types other than %r: %s" % (name, expected, text.strip()[-200:])]
    return []


def expand(policy, name, source):
    """return the type names a rule target stands for"""
    if name == "self":
        return {source}
    if name in policy["attributes"]:
        return {str(t) for t in policy["attributes"][name].expand()}
    return {name}


def sesearch_text(policy_path, source, flag):
    """return sesearch's rules for a source type"""
    code, text = tool(["sesearch", flag, "-s", source, policy_path])
    if code != 0:
        raise RuntimeError("sesearch %s -s %s: %s" % (flag, source, text.strip()[-200:]))
    return text


def load_policy(policy_path):
    """return the policy's type and attribute tables"""
    import setools
    loaded = setools.SELinuxPolicy(policy_path)
    return {"types": {str(t) for t in loaded.types()},
            "attributes": {str(a): a for a in loaded.typeattributes()},
            "typeobjs": {str(t): t for t in loaded.types()}}


def grants(policy, policy_path, source, flag):
    """return the perms and ioctl ranges a domain holds"""
    text = sesearch_text(policy_path, source, flag)
    perms = collections.defaultdict(set)
    ranges = collections.defaultdict(list)
    for line in text.splitlines():
        found = re.match(r"\s*(allow|dontaudit) (\S+) (\S+):(\S+) (\{[^}]*\}|\S+);", line)
        if found:
            _kind, _src, target, cls, perm_text = found.groups()
            for t in expand(policy, target, source):
                perms[(t, cls)].update(perm_text.strip("{} ").split())
            continue
        found = re.match(r"\s*allowxperm (\S+) (\S+):(\S+) ioctl (\{[^}]*\}|\S+);", line)
        if found:
            _src, target, cls, cmds = found.groups()
            span = []
            for token in cmds.strip("{} ").split():
                low, _, high = token.partition("-")
                span.append((int(low, 16), int(high or low, 16)))
            for t in expand(policy, target, source):
                ranges[(t, cls)] += span
    return perms, ranges


def held_rights(policy, policy_path):
    """return the rights each helper type and kernel hold"""
    held = {}
    for domain in HELPER_TYPES + (KERNEL,):
        if domain not in policy["types"]:
            return None, "the policy declares no type %s" % domain
        allowed, ranges = grants(policy, policy_path, domain, "-A")
        audited, _ = grants(policy, policy_path, domain, "--dontaudit")
        held[domain] = (allowed, audited, ranges)
    return held, None


def uncovered(policy, held, rows, holder_of):
    """return the rows no allow or allowx of the holder covers, by domain"""
    missing = collections.defaultdict(list)
    for domain, target, cls, perm, command in rows:
        holder = holder_of(domain)
        allowed, _audited, ranges = held[holder]
        members = sorted(t for t in expand(policy, target, holder) if t in policy["types"])
        lacking = [t for t in members if perm not in allowed.get((t, cls), ())]
        if not lacking and command != NO_IOCTL:
            value = int(command, 16)
            lacking = [t for t in members if not any(low <= value <= high for low, high in ranges.get((t, cls), ()))]
            perm = "ioctl " + command
        if lacking:
            of_members = "" if len(members) == 1 else " on %d of %d members" % (len(lacking), len(members))
            missing[domain].append("%s %s:%s %s%s" % (domain, target, cls, perm, of_members))
    return missing


def census_problems(name, policy_path, rows, baseline=()):
    """return the census and baseline rows no rule covers"""
    policy = load_policy(policy_path)
    held, why = held_rights(policy, policy_path)
    if why:
        return ["%s: %s" % (name, why)]
    found = []
    answered = [r for r in rows if r[:4] not in DENIED_BY_DESIGN]
    for domain, items in uncovered(policy, held, answered, lambda d: d).items():
        found.append("%s: %d census rows of %s are uncovered, first: %s" % (name, len(items), domain, "; ".join(items[:4])))
    kernel_rows = [r[:5] for r in baseline if r[5] == KERNEL]
    for domain, items in uncovered(policy, held, kernel_rows, lambda d: KERNEL).items():
        found.append("%s: %d baseline rows of %s are not held by kernel, first: %s" % (name, len(items), domain, "; ".join(items[:4])))
    for domain, items in uncovered(policy, held, [r[:5] for r in baseline], lambda d: d).items():
        found.append("%s: %d baseline rows of %s are uncovered, first: %s" % (name, len(items), domain, "; ".join(items[:4])))
    return found + denied_problems(name, held, rows) + walk_problems(name, policy, held) + excess_problems(
        name, policy, held, answered, baseline)


def backed_rights(policy, rows, baseline):
    """return the perms and ioctl commands the rows back"""
    perms = collections.defaultdict(set)
    commands = collections.defaultdict(set)
    for holder, target, cls, perm, command in [r[:5] for r in rows] + [r[:5] for r in baseline]:
        for actual in expand(policy, target, holder):
            perms[(holder, actual, cls)].add(perm)
            if command != NO_IOCTL:
                perms[(holder, actual, cls)].add("ioctl")
                commands[(holder, actual, cls)].add(int(command, 16))
    return perms, commands


def subtract_spans(spans, covered):
    """return the parts of spans no covered span reaches"""
    left = []
    for low, high in spans:
        cursor = low
        for covered_low, covered_high in sorted(covered):
            if covered_high < cursor or covered_low > high:
                continue
            if covered_low > cursor:
                left.append((cursor, covered_low - 1))
            cursor = max(cursor, covered_high + 1)
        if cursor <= high:
            left.append((cursor, high))
    return left


def excess_rights(policy, held, rows, baseline):
    """return each helper's rights no row or kernel right backs"""
    perms, commands = backed_rights(policy, rows, baseline)
    kernel_allowed, _audited, kernel_ranges = held[KERNEL]
    found = {}
    for holder in HELPER_TYPES:
        allowed, _audited, ranges = held[holder]
        extra, extra_commands, unbounded = [], [], []
        for (target, cls), granted in sorted(allowed.items()):
            kernel_key = (KERNEL, cls) if target in (holder, KERNEL) else (target, cls)
            shown = "self" if target == holder else target
            lacking = sorted(p for p in granted
                             if p not in perms.get((holder, target, cls), ()) and p not in kernel_allowed.get(kernel_key, ()))
            if lacking:
                extra.append("%s:%s %s" % (shown, cls, " ".join(lacking)))
            kernel_unbounded = "ioctl" in kernel_allowed.get(kernel_key, ()) and kernel_key not in kernel_ranges
            if "ioctl" in granted and (target, cls) not in ranges and not kernel_unbounded:
                unbounded.append("%s:%s" % (shown, cls))
        for (target, cls), spans in sorted(ranges.items()):
            kernel_key = (KERNEL, cls) if target in (holder, KERNEL) else (target, cls)
            covered = [(c, c) for c in commands.get((holder, target, cls), ())] + list(kernel_ranges.get(kernel_key, ()))
            for low, high in subtract_spans(spans, covered):
                extra_commands.append("%s:%s %s" % ("self" if target == holder else target, cls,
                                                    hex(low) if low == high else "%s-%s" % (hex(low), hex(high))))
        found[holder] = (extra, extra_commands, unbounded)
    return found


def excess_problems(name, policy, held, rows, baseline):
    """return the rights no row or kernel right backs"""
    found = []
    for holder, (extra, extra_commands, unbounded) in excess_rights(policy, held, rows, baseline).items():
        if extra:
            found.append("%s: %d rights of %s are backed by no census row, baseline row or right of kernel, first: %s" % (
                name, len(extra), holder, "; ".join(extra[:4])))
        if extra_commands:
            found.append("%s: %d ioctl commands of %s are backed by no census row, baseline row or range of kernel, first: %s" % (
                name, len(extra_commands), holder, "; ".join(extra_commands[:4])))
        for key in unbounded:
            found.append("%s: %s allows every ioctl command on %s" % (name, holder, key))
    return found


def denied_problems(name, held, rows):
    """return the mishandled by-design denials and the other dontaudits"""
    found = []
    drawn = {r[:4] for r in rows}
    for holder, target, cls, perm in DENIED_BY_DESIGN:
        allowed, audited, _ranges = held[holder]
        key = (holder if target == "self" else target, cls)
        if (holder, target, cls, perm) not in drawn:
            found.append("%s: DENIED_BY_DESIGN names %s %s:%s %s, which no census row records" % (name, holder, target, cls, perm))
        if perm in allowed.get(key, ()):
            found.append("%s: %s is allowed %s on %s:%s, which the policy keeps denied" % (name, holder, perm, target, cls))
        if perm not in audited.get(key, ()):
            found.append("%s: %s's denied %s on %s:%s is not dontaudited" % (name, holder, perm, target, cls))
    for holder in HELPER_TYPES:
        for (actual, cls), perms in sorted(held[holder][1].items()):
            target = "self" if actual == holder else actual
            for perm in sorted(perms):
                if (holder, target, cls, perm) not in DENIED_BY_DESIGN:
                    found.append("%s: %s dontaudits %s on %s:%s" % (
                        name, holder, perm, target, cls))
    return found


def walk_problems(name, policy, held):
    """return the dir types kernel could walk that the relabeller cannot"""
    swept = set()
    for attribute in WALK_ATTRIBUTES:
        swept |= {str(t) for t in policy["attributes"][attribute].expand()}
    kernel_allowed = held[KERNEL][0]
    relabel_allowed = held["rhizo_ns_relabel"][0]
    lacking = ["%s %s" % (target, "/".join(sorted(wanted)))
               for (target, cls), perms in sorted(kernel_allowed.items())
               if cls == "dir" and target in swept
               for wanted in [(perms & WALK_PERMS) - relabel_allowed.get((target, cls), set())] if wanted]
    if not lacking:
        return []
    return ["%s: kernel could walk %d dir types that rhizo_ns_relabel cannot, first: %s" % (name, len(lacking), "; ".join(lacking[:4]))]


def breadth_problems(fragment):
    """return the helper rules that reach an attribute with more than getattr"""
    found = []
    for source, target, cls, perms in HELPER_RULE.findall(fragment):
        wide = sorted(set(perms.split()) - {"getattr"})
        if target in SWEPT_ATTRIBUTES and wide:
            found.append("%s holds %s %s on the attribute %s, wider than the types the census names" % (
                source, cls, " ".join(wide), target))
    return found


def parity_lines(policy_path, source, targets):
    """return the perms kernel holds on each target:class that source lacks"""
    policy = load_policy(policy_path)
    kernel, _ = grants(policy, policy_path, KERNEL, "-A")
    own, _ = grants(policy, policy_path, source, "-A")
    lines = []
    for spec in targets:
        target, _, cls = spec.partition(":")
        lacking = sorted(kernel.get((target, cls), set()) - own.get((target, cls), set()))
        lines.append("%s %s:%s lacks %s" % (source, target, cls, " ".join(lacking) or "nothing kernel holds"))
    return lines


def attribute_problems(name, policy_path):
    """return the helper types that sit in domain or coredomain"""
    policy = load_policy(policy_path)
    found = []
    for helper in HELPER_TYPES:
        obj = policy["typeobjs"].get(helper)
        if obj is None:
            found.append("%s: the policy declares no type %s" % (name, helper))
            continue
        attributes = {str(a) for a in obj.attributes()}
        for forbidden in FORBIDDEN_ATTRIBUTES:
            if forbidden in attributes:
                found.append("%s: %s is in %s" % (name, helper, forbidden))
    return found


def cts_problems(release_names, fragment):
    """return the problems of compiling each release against CTS"""
    spec = importlib.util.spec_from_file_location("cts_vendor_cil", os.path.join(HERE, "..", "rules", "cts-vendor-cil-resolves.py"))
    cts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cts)
    _cils, jar, why = cts.inputs(ROOT)
    if not jar or not os.access(cts.SECILC, os.X_OK):
        return ["no CTS package or secilc: %s" % why]
    version = cts.SEPOLICY_VERSION.search(open(os.path.join(ROOT, cts.MANIFEST)).read()).group(1).strip()
    found = []
    with tempfile.TemporaryDirectory() as snapshot:
        plat, mapping = cts.cts_snapshot(jar, version)
        for filename, text in (("plat_sepolicy.cil", plat), ("mapping.cil", mapping)):
            with open(os.path.join(snapshot, filename), "w") as handle:
                handle.write(text)
        for name, image, _expected in release_names:
            cils = cil_paths(image)
            if cils is None:
                found.append("%s: no cached CILs for %s.img" % (name, image))
                continue
            vendor = cts.selinux_policy.cts_vendor_adapt(render_policy(cils, fragment))
            errors = cts.compile_errors(snapshot, vendor)
            if errors:
                found.append("%s: CTS's frozen vendor snapshot does not compile the policy: %s" % (name, errors[:300]))
    return found


def judge(fragment, releases, census_rows, baseline_rows=()):
    """return the problems of the fragment on each release"""
    problems = breadth_problems(fragment)
    with tempfile.TemporaryDirectory() as workdir:
        def one(release):
            name, image, expected = release
            policy, out, bad = compile_release(name, image, fragment, workdir)
            if bad:
                return bad
            bad = permissive_problems(name, image, out, expected) + attribute_problems(name, policy)
            return bad + census_problems(name, policy, census_rows, baseline_rows)

        with ThreadPoolExecutor(len(releases)) as pool:
            cts_future = pool.submit(cts_problems, releases, fragment)
            for bad in pool.map(one, releases):
                problems += bad
            problems += cts_future.result()
    return problems


def mutate_remove(fragment, needles):
    """return the fragment without the lines that contain each needle"""
    kept = [l for l in fragment.splitlines(keepends=True) if not any(n in l for n in needles)]
    if len(kept) == len(fragment.splitlines()):
        raise ValueError("no fragment line contains any of %s" % (needles,))
    return "".join(kept)


def mutate_replace(fragment, old, new):
    """return the fragment with its an occurrence of old replaced by new"""
    if fragment.count(old) != 1:
        raise ValueError("%d places in the fragment contain %r, wanted one" % (fragment.count(old), old))
    return fragment.replace(old, new)


MUTANTS = (
    ("a helper type in domain", lambda f: f + "(typeattributeset domain (rhizo_ns_relabel))\n",
     ("secilc does not compile", "CTS's frozen vendor snapshot does not compile")),
    ("a transition to rhizo_input_label", lambda f: f + "(allow rhizo_ns_relabel rhizo_input_label (process (dyntransition)))\n",
     ("domain.te:1408",)),
    ("a dac_read_search grant", lambda f: f + "(allow rhizo_ns_relabel self (capability (dac_read_search)))\n",
     ("neverallow check failed", "(capability (dac_read_search))")),
    ("no FICLONE allowx", lambda f: mutate_remove(f, ("0x9409",)),
     ("neverallowx check failed", "domain.te:644")),
    ("no relabel destination device rule", lambda f: mutate_remove(f, ("rhizo_relabel_dest_dev",)),
     ("census rows of rhizo_ns_relabel are uncovered",)),
    ("no setenforce dontaudit", lambda f: mutate_remove(f, ("(security (setenforce))",)),
     ("setenforce on kernel:security is not dontaudited",)),
    ("no stage capability dontaudit", lambda f: mutate_remove(f, ("(dontaudit rhizo_ns_stage self (capability",)),
     ("rhizo_ns_stage's denied dac_read_search on self:capability is not dontaudited",
      "rhizo_ns_stage's denied setfcap on self:capability is not dontaudited")),
    ("no relabel capability dontaudit", lambda f: mutate_remove(f, ("(dontaudit rhizo_ns_relabel self (capability",)),
     ("rhizo_ns_relabel's denied dac_read_search on self:capability is not dontaudited",)),
    ("a dontaudit hiding a missing right", lambda f: f + "(dontaudit rhizo_ns_label self (capability (sys_nice)))\n",
     ("rhizo_ns_label dontaudits sys_nice on self:capability",)),
    ("a setenforce grant", lambda f: f + "(allow rhizo_ns_relabel kernel (security (setenforce)))\n",
     ("neverallow check failed", "(security (setenforce))")),
    ("no label right on the hostfs mount point", lambda f: mutate_remove(f, ("rhizo_ns_label media_rw_data_file",)),
     ("baseline rows of rhizo_ns_label are uncovered",)),
    ("no search of the device-state directory",
     lambda f: mutate_remove(f, ("rhizo_ns_label rhizo_device_state_file (dir",)),
     ("census rows of rhizo_ns_label are uncovered", "rhizo_device_state_file:dir search")),
    ("no label right on a device-state file",
     lambda f: mutate_remove(f, ("rhizo_ns_label rhizo_device_state_file (file",)),
     ("census rows of rhizo_ns_label are uncovered", "rhizo_device_state_file:file relabelto",
      "rhizo_device_state_file:file getattr")),
    ("no proc search for the helpers", lambda f: mutate_remove(f, ("proc (dir (search))",)),
     ("baseline rows of rhizo_ns_stage are uncovered", "baseline rows of rhizo_ns_relabel are uncovered")),
    ("no dir walk of the device root", lambda f: mutate_remove(f, ("rhizo_ns_relabel device (dir (getattr open read search))",)),
     ("kernel could walk 1 dir types that rhizo_ns_relabel cannot",)),
    ("a dir sweep over file_type", lambda f: f + "(allow rhizo_ns_relabel file_type (dir (getattr open read search)))\n",
     ("on the attribute file_type",)),
    ("no stage copy right on vendor links", lambda f: mutate_remove(f, ("rhizo_ns_stage vendor_file_type (lnk_file",)),
     ("baseline rows of rhizo_ns_stage are uncovered", "rhizo_ns_stage vendor_file_type:lnk_file")),
    ("an unbacked right on a type the census names",
     lambda f: f + "(allow rhizo_ns_label rhizo_inbox_file (file (write)))\n",
     ("rights of rhizo_ns_label are backed by no census row, baseline row or right of kernel", "rhizo_inbox_file:file write")),
    ("an unbacked right on a type the baseline names",
     lambda f: f + "(allow rhizo_ns_label media_rw_data_file (dir (mounton)))\n",
     ("rights of rhizo_ns_label are backed by no census row, baseline row or right of kernel", "media_rw_data_file:dir mounton")),
    ("an unbacked right on a type kernel holds rights on",
     lambda f: f + "(allow rhizo_ns_label kernel (fifo_file (setattr)))\n",
     ("rights of rhizo_ns_label are backed by no census row, baseline row or right of kernel", "kernel:fifo_file setattr")),
    ("a write grant over system_file_type", lambda f: f + "(allow rhizo_ns_label system_file_type (file (write unlink)))\n",
     ("rights of rhizo_ns_label are backed by no census row, baseline row or right of kernel",)),
    ("a dir walk of a type kernel cannot walk",
     lambda f: f + "(allow rhizo_ns_relabel coredump_file (dir (getattr open read search)))\n",
     ("rights of rhizo_ns_relabel are backed by no census row, baseline row or right of kernel",
      "coredump_file:dir getattr open read search")),
    ("an ioctl command no row backs", lambda f: f + "(allowx rhizo_ns_label unlabeled (ioctl file (0x5460)))\n",
     ("ioctl commands of rhizo_ns_label are backed by no census row, baseline row or range of kernel", "unlabeled:file 0x5460")),
    ("an allow turned into a dontaudit",
     lambda f: mutate_replace(f, "(allow rhizo_ns_label rhizo_inbox_file (file (getattr relabelto)))",
                              "(dontaudit rhizo_ns_label rhizo_inbox_file (file (getattr relabelto)))"),
     ("census rows of rhizo_ns_label are uncovered",)),
)


MINIMAL_CIL = (
    "(class file (read))\n(classorder (file))\n(sid kernel)\n(sidorder (kernel))\n(user u)\n(role r)\n"
    "(type fixture_kernel)\n(roletype r fixture_kernel)\n(category c0)\n(categoryorder (c0))\n"
    "(sensitivity s0)\n(sensitivityorder (s0))\n(sensitivitycategory s0 (c0))\n(userlevel u (s0))\n"
    "(userrange u ((s0) (s0 (c0))))\n(userrole u r)\n(sidcontext kernel (u r fixture_kernel ((s0) (s0))))\n"
    "(typeattribute domain)\n(typeattribute coredomain)\n(expandtypeattribute (domain coredomain) false)\n"
    "(type rhizo_ns_stage)\n(type rhizo_ns_relabel)\n(type rhizo_ns_label)\n"
    "(allow fixture_kernel self (file (read)))\n(allow domain self (file (read)))\n(allow coredomain self (file (read)))\n")


def attribute_selftest():
    """return the problems of the domain membership check on fixture policies"""
    problems = []
    with tempfile.TemporaryDirectory() as directory:
        for label, extra, wanted in (
                ("helpers outside domain", "", []),
                ("a helper in domain", "(typeattributeset domain (rhizo_ns_label))\n",
                 ["a16: rhizo_ns_label is in domain"]),
                ("a helper in coredomain", "(typeattributeset coredomain (rhizo_ns_stage))\n",
                 ["a16: rhizo_ns_stage is in coredomain"])):
            source = os.path.join(directory, "fixture.cil")
            policy = os.path.join(directory, "fixture.bin")
            with open(source, "w") as handle:
                handle.write(MINIMAL_CIL + extra)
            code, text = tool(["secilc", "-m", "-M", "true", "-G", "-c", "30", source, "-o", policy, "-f", "/dev/null"])
            if code != 0:
                problems.append("%s: the fixture does not compile: %s" % (label, text.strip()))
                continue
            got = attribute_problems("a16", policy)
            if got != wanted:
                problems.append("%s: attribute_problems gave %s, wanted %s" % (label, got, wanted))
    return problems


def denied_selftest():
    """return the problems of denied_problems on fixture rights"""
    problems = []
    rows = [(h, t, c, p, NO_IOCTL) for h, t, c, p in DENIED_BY_DESIGN]
    clean = {h: ({}, {}, {}) for h in HELPER_TYPES}
    for holder, target, cls, perm in DENIED_BY_DESIGN:
        clean[holder][1].setdefault((holder if target == "self" else target, cls), set()).add(perm)
    if denied_problems("a16", clean, rows):
        problems.append("denied_problems flagged the by-design denials: %s" % denied_problems("a16", clean, rows))
    allowing = {h: ({k: set(v) for k, v in a.items()}, au, r) for h, (a, au, r) in clean.items()}
    allowing["rhizo_ns_relabel"][0][("kernel", "security")] = {"setenforce"}
    got = denied_problems("a16", allowing, rows)
    if got != ["a16: rhizo_ns_relabel is allowed setenforce on kernel:security, which the policy keeps denied"]:
        problems.append("an allowed by-design denial gave %s" % got)
    got = denied_problems("a16", clean, rows[1:])
    if got != ["a16: DENIED_BY_DESIGN names rhizo_ns_stage self:capability dac_read_search, which no census row records"]:
        problems.append("a by-design denial with no census row gave %s" % got)
    return problems


def excess_selftest():
    """return the problems of the excess functions on fixture rights"""
    problems = []
    spans = subtract_spans([(0x5400, 0x5410)], [(0x5401, 0x5401), (0x5405, 0x5408)])
    if spans != [(0x5400, 0x5400), (0x5402, 0x5404), (0x5409, 0x5410)]:
        problems.append("subtract_spans left %s" % spans)
    spans = subtract_spans([(0x10, 0x20)], [(0x15, 0x15), (0x14, 0x16), (0x0, 0x5)])
    if spans != [(0x10, 0x13), (0x17, 0x20)]:
        problems.append("subtract_spans over overlapping spans left %s" % spans)
    if subtract_spans([(0x10, 0x20)], [(0x0, 0x30)]):
        problems.append("subtract_spans left a span a wider span covers")
    policy = {"types": {"t", KERNEL, "rhizo_ns_stage", "rhizo_ns_relabel", "rhizo_ns_label"}, "attributes": {}}
    for label, kernel_ranges, want in (("a command list kernel restricts", {("t", "file"): [(0x5401, 0x5401)]}, ["t:file"]),
                                       ("a command list kernel does not restrict", {}, [])):
        held = {h: ({}, {}, {}) for h in HELPER_TYPES + (KERNEL,)}
        held["rhizo_ns_stage"][0][("t", "file")] = {"ioctl", "read"}
        held[KERNEL][0][("t", "file")] = {"ioctl", "read"}
        held[KERNEL][2].update(kernel_ranges)
        got = excess_rights(policy, held, [], [])["rhizo_ns_stage"][2]
        if got != want:
            problems.append("an ioctl with no command list against %s gave %s, wanted %s" % (label, got, want))
    return problems


def walks_selftest():
    """return the problems of the per-release domain walks on the cached CILs"""
    problems = []
    for name, image, want in (("a15", "gsi_a15", []), ("a16", "system", ["aconfig_storage_metadata_file"]),
                              ("a17", "gsi_a17", ["aconfig_storage_metadata_file"]),
                              ("a16 userdebug", "gsi_userdebug", ["aconfig_storage_metadata_file", "coredump_file"])):
        cils = cil_paths(image)
        if cils is None:
            problems.append("%s: no cached CILs for %s.img" % (name, image))
            continue
        got = re.findall(r"rhizo_ns_walk_(\w+)", selinux_policy.domain_walked_dir_rules(cils))
        if got != want:
            problems.append("%s: domain_walked_dir_rules names %s, wanted %s" % (name, got, want))
    return problems


def derive_selftest():
    """return the problems of deriving rows from a fixture log"""
    problems = []
    title_hex = lambda text: text.replace(" ", "\0").encode().hex()
    lines = []
    serial = 0
    for pid, title in ((10, "cp -a /a /b"), (11, "python3 /usr/lib/rhizo/launcher3.py selinuxns-relabeller 10 11 22"),
                       (12, "python3 /usr/lib/rhizo/launcher3.py in-android-policy label-fd 4 u:object_r:x:s0"),
                       (13, "python3 /usr/lib/rhizo/launcher3.py something-else")):
        serial += 1
        key = "1.000:%d" % serial
        lines.append("type=SYSCALL msg=audit(%s): arch=c000003e pid=%d comm=\"x\" subj=u:r:kernel:s0" % (key, pid))
        lines.append("type=PROCTITLE msg=audit(%s): proctitle=%s" % (key, title_hex(title)))

    def avc(pid, perms, target, cls, extra=""):
        nonlocal serial
        serial += 1
        return ("type=AVC msg=audit(2.000:%d): avc:  denied  { %s } for  pid=%d comm=\"x\" scontext=u:r:kernel:s0 "
                "tcontext=%s tclass=%s%s permissive=1" % (serial, perms, pid, target, cls, extra))

    lines += [avc(10, "ioctl", "u:object_r:system_file:s0", "file", " ioctlcmd=0x9409"),
              avc(11, "relabelto", "u:object_r:ntp_drift_t:s0", "dir"),
              avc(11, "chown", "u:r:kernel:s0", "capability"),
              avc(12, "getattr", "u:object_r:rhizo_inbox_file:s0", "file"),
              avc(13, "read", "u:object_r:system_file:s0", "file")]
    with tempfile.TemporaryDirectory() as directory:
        log = os.path.join(directory, "audit.log")
        with open(log, "w") as handle:
            handle.write("\n".join(lines) + "\n")
        rows, unowned = derive({"system_file", "rhizo_inbox_file"}, [log])
    want = [("rhizo_ns_label", "rhizo_inbox_file", "file", "getattr", NO_IOCTL),
            ("rhizo_ns_relabel", "self", "capability", "chown", NO_IOCTL),
            ("rhizo_ns_relabel", "unlabeled", "dir", "relabelto", NO_IOCTL),
            ("rhizo_ns_stage", "system_file", "file", "ioctl", "0x9409"),
            ("rhizo_ns_stage", "system_file", "file", "ioctl", NO_IOCTL)]
    if rows != sorted(want):
        problems.append("derive gave %s, wanted %s" % (rows, sorted(want)))
    if dict(unowned) != {"13": 1}:
        problems.append("derive reported the unowned denials %s, wanted pid 13 once" % dict(unowned))
    return problems


def selftest():
    """plant each defect in the fragment and require its finding"""
    failed = derive_selftest() + attribute_selftest() + denied_selftest() + excess_selftest() + walks_selftest()
    census_rows = read_census()
    baseline_rows = read_baseline()
    releases = (("a16", "system", ""),)
    shipped = selinux_policy.NAMESPACE_HELPER_DOMAINS
    clean = judge(shipped, releases, census_rows, baseline_rows)
    if clean:
        failed.append("the shipped fragment has findings: %s" % clean)
    for claimed in (("rhizo_ns_label", "media_rw_data_file", "dir", "relabelto", NO_IOCTL),
                    ("rhizo_ns_label", "self", "capability", "setgid", NO_IOCTL)):
        for basis, wanted in ((KERNEL, ["rhizo_ns_label are not held by kernel"]), ("code", [])):
            found = [f for f in judge(shipped, releases, census_rows, [claimed + (basis,)]) if "held by kernel" in f]
            if [w for w in wanted if not any(w in f for f in found)] or (not wanted and found):
                failed.append("a %s-based baseline row kernel lacks gave %s, wanted %s for %s" % (
                    basis, found, wanted or "no finding", claimed))

    def run(mutant):
        label, change, wanted = mutant
        found = judge(change(shipped), releases, census_rows, baseline_rows)
        return [("%s: no finding naming %r in %s" % (label, w, found)) for w in wanted
                if not any(w in f for f in found)]

    with ThreadPoolExecutor(3) as pool:
        for bad in pool.map(run, MUTANTS):
            failed += bad
    if failed:
        for line in failed:
            print("SELFTEST FAIL: " + line)
        return 1
    print("ns-helper-domains selftest: ok (%d defects caught, the shipped fragment passes)" % len(MUTANTS))
    return 0


def main():
    """run the check, the derivation or the selftest"""
    parser = argparse.ArgumentParser(description="check the namespace helper domains")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--derive", nargs="+", metavar="ARG", help="POLICY LOG...")
    parser.add_argument("--parity", nargs="+", metavar="ARG", help="POLICY SOURCE TARGET:CLASS...")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.derive:
        policy = load_policy(args.derive[0])
        rows, unowned = derive(policy["types"], args.derive[1:])
        for row in rows:
            print("\t".join(row))
        for pid, count in sorted(unowned.items()):
            print("# unowned: pid %s drew %d kernel denials" % (pid, count), file=sys.stderr)
        return 1 if unowned else 0
    if args.parity:
        print("\n".join(parity_lines(args.parity[0], args.parity[1], args.parity[2:])))
        return 0
    rows = read_census()
    baseline = read_baseline()
    found = judge(selinux_policy.NAMESPACE_HELPER_DOMAINS, RELEASES, rows, baseline)
    for line in found:
        print("FAIL: ns-helper-domains: " + line)
    if found:
        return 1
    print("ok: %d census rows and %d baseline rows covered, every right of the %d helper types backed by a row or by kernel, "
          "outside domain and coredomain, no permissive type, compiled on %s and in CTS's frozen snapshot" % (
              len(rows), len(baseline), len(HELPER_TYPES), ", ".join(r[0] for r in RELEASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
