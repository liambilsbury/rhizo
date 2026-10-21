#!/usr/bin/env python3
import argparse
import fnmatch
import os
import re
import sys


SENTINEL_LINE = "end\tsentinel\tok"


def parse_manifest_text(text):
    """parse manifest text into a dict"""
    nonempty = [l for l in text.splitlines() if l]
    if not nonempty or nonempty[-1] != SENTINEL_LINE:
        last = nonempty[-1] if nonempty else "<empty>"
        raise ValueError(
            f"manifest does not end with the completeness sentinel {SENTINEL_LINE!r} "
            f"(last line: {last!r})")
    manifest = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        fields = line.split("\t", 2)
        if len(fields) != 3:
            raise ValueError(f"manifest line {lineno}: expected section\\tkey\\tvalue, got {line!r}")
        section, key, value = fields
        manifest[(section, key)] = value
    return manifest


def parse_manifest(path):
    """parse a manifest file"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return parse_manifest_text(fh.read())


ALLOW_PHASE = re.compile(r"^(remove|purge|\*)(\?)?(?:@(installer|cycle))?$")
CALLERS = ("installer", "cycle")


def parse_allow_text(text):
    """parse allowlist text into a list of rows"""
    rows = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t", 3)
        if len(fields) not in (3, 4):
            raise ValueError(f"allowlist line {lineno}: expected phase\\tpattern\\treason[\\tvalue], got {line!r}")
        m = ALLOW_PHASE.match(fields[0].strip())
        pattern = fields[1]
        reason = fields[2]
        value = fields[3] if len(fields) == 4 else None
        if not m:
            raise ValueError(f"allowlist line {lineno}: phase must be remove, purge or *, then an optional ? "
                             f"and @installer or @cycle, got {fields[0].strip()!r}")
        rows.append({"line": lineno, "phase": m.group(1), "optional": bool(m.group(2)), "caller": m.group(3),
                     "pattern": pattern, "reason": reason, "value": value})
    return rows


def parse_allow(path):
    """parse an allowlist file"""
    with open(path, encoding="utf-8", errors="replace") as fh:
        return parse_allow_text(fh.read())


def diff_manifests(before, after):
    """return the sorted differences of two manifests"""
    diffs = []
    for k in sorted(set(before) | set(after)):
        section, key = k
        bv, av = before.get(k), after.get(k)
        if k not in before:
            diffs.append((section, key, "added", None, av))
        elif k not in after:
            diffs.append((section, key, "removed", bv, None))
        elif bv != av:
            diffs.append((section, key, "changed", bv, av))
    return diffs


PKGWIN_KINDS = ("rhizo-install", "ubuntu-update", "host-update", "test-staged")
PKGWIN_TAG = "# rhizo-pkgwin"
APTKEPT_TAG = "# rhizo-aptkept"
APT_REMV = re.compile(r"^Remv (\S+)")
APT_SIM_RC = re.compile(r"^SIM_RC=(\d+)$")
INSTALLED = "install ok installed"
CONFIG_FILES = "deinstall ok config-files"
INHERITED_LABELS = ("<none>", "u:object_r:unlabeled:s0")
OWNED_SECTIONS = ("etc", "listing", "selinux_xattr", "usr_src", "applications", "icons")
ABSENT_VALUES = ("absent", "dir-absent")
KERNEL_IMAGE = re.compile(r"^linux-image-(\d[\w.+~-]*)$")
HISTORY_ACTIONS = {"Install": "install", "Upgrade": "upgrade", "Downgrade": "upgrade",
                   "Reinstall": "upgrade", "Remove": "remove", "Purge": "purge"}
HISTORY_ENTRY = re.compile(r"([^\s,()]+) \(([^()]*)\)")
DPKG_EVENT = re.compile(r"^\S+ \S+ (install|upgrade|remove|purge) (\S+) (\S+) (\S+)$")
PACMAN_EVENT = re.compile(r"^\[[^]]+\] \[ALPM\] (installed|upgraded|downgraded|removed|reinstalled) "
                          r"(\S+) \(([^)]*)\)$")
RHIZO_PACKAGES = ("rhizo",)
ALTERNATIVES_DIR = "/etc/alternatives/"
SYMLINK_VALUE = re.compile(r"^symlink target=(/\S+)$")
LINK_VALUE = re.compile(r"^symlink target=(\S+)$")
UNIT_FILE_DIRS = ("/usr/lib/systemd/system/", "/lib/systemd/system/", "/usr/lib/systemd/user/", "/lib/systemd/user/")
ACCOUNT_SECTIONS = ("passwd", "group")
ACCOUNT_FILES = {"/etc/passwd": "passwd", "/etc/shadow": "passwd", "/etc/group": "group", "/etc/gshadow": "group"}
TRIGGER_OUTPUTS = {("applications", "/usr/share/applications/mimeinfo.cache"): "desktop-file-utils"}
RHIZO_UNIT = re.compile(r"^(rhizo-[\w.@-]+|androidd(@[\w.-]*)?)\.(service|socket|path|timer)$")
ENABLE_LINK = re.compile(r"^/etc/systemd/(system|user)/([^/]+\.(?:wants|requires))/([^/]+)$")


def dsh_unit(key):
    """return the unit name of a deb-systemd-helper key"""
    rel = key.partition(":")[2]
    if not rel:
        return None
    if "/" in rel:
        return rel.rsplit("/", 1)[1]
    return rel[:-len(".dsh-also")] if rel.endswith(".dsh-also") else rel

HARNESS_SCRATCH = {
    "/root/host-snapshot.sh": "installer-lib.sh's take_snapshot stages this census before every run of it",
    "/root/modules-extra.deb": "installer-lib.sh's desktop-resemblance staging copies the extra-modules package here",
    "/root/rhizo-artifact": "installer_transfer_artifact (installer-lib.sh) copies the .debs under test here",
    "/root/rhizo-artifact-prev": "installer.sh copies the N-1 .debs here for its upgrade leg",
    "/root/rhizo-artifact-up": "installer-cachyos-lib.sh copies the release-2 pacman packages here for its upgrade",
    "/root/rhizo-test-upgrade-adbkey": "installer.sh's upgrade leg copies its adb key here",
    "/root/rhizo-lifecycle-fixture.apk": "cycle.sh copies its fixture app here for `rhizo app install`",
    "/root/rhizo-deskapp.apk": "cycle.sh copies its desktop fixture app here for `rhizo app install`",
    "/root/rhizo-lifecycle-audiotest.apk": "claims-desktop.sh copies its audio fixture app here",
    "/root/rhizo-client-run.sh": "sway-lib.sh writes its client launcher here",
    "/root/rhizo-lifecycle-fetch-stub.sh": "gsi-update-lib.sh writes its fetch stub here",
    "/root/rhizo-lifecycle-tampered-gsi.zip": "gsi-update-lib.sh writes its tampered-image fixture here",
}


def harness_scratch(section, key):
    """return the HARNESS_SCRATCH entry for a /root row"""
    if section != "home_root":
        return None
    for path, writer in HARNESS_SCRATCH.items():
        if key == path or key.startswith(path + "/"):
            return writer
    return None


LOGIND_SESSION_SCOPE = re.compile(r"^session-c?[0-9]+\.scope$")


def logind_session_scope(section, key, bv, av):
    """match a logind session scope unit"""
    return (section == "unit" and LOGIND_SESSION_SCOPE.match(key) is not None
            and {bv, av} == {"transient", None})


FWUPD_CONF = "/etc/fwupd/fwupd.conf"
ETC_FILE_VALUE = re.compile(r"^file mode=([0-7]+) owner=(\S+) sha256=([0-9a-f]{64})$")


def fwupd_conf_secured(section, key, bv, av):
    """check for a fwupd.conf mode change to 640"""
    if section != "etc" or key != FWUPD_CONF or bv is None or av is None:
        return False
    b, a = ETC_FILE_VALUE.match(bv), ETC_FILE_VALUE.match(av)
    return (b is not None and a is not None and (b.group(1), a.group(1)) == ("644", "640")
            and b.group(2) == a.group(2) and b.group(3) == a.group(3))


def parse_pkgwin_text(text, kind):
    """parse lc_pkgwin text into windows"""
    windows, cur, part = [], None, None
    for lineno, line in enumerate(text.splitlines(keepends=True), 1):
        if not line.startswith(PKGWIN_TAG + " "):
            if cur is None:
                if line.strip():
                    raise ValueError(f"pkgwin line {lineno}: text outside any window: {line.rstrip()!r}")
                continue
            cur[part].append(line)
            continue
        fields = line.split()
        if len(fields) < 6:
            raise ValueError(f"pkgwin line {lineno}: malformed marker {line.rstrip()!r}")
        seq, wkind, label, what = fields[2], fields[3], fields[4], fields[5]
        if wkind != kind:
            raise ValueError(f"pkgwin line {lineno}: a {wkind} window in the {kind} input")
        if what == "incomplete":
            raise ValueError(f"pkgwin line {lineno}: window {label} was not captured whole: {' '.join(fields[6:])}")
        if what == "history":
            if cur is not None:
                raise ValueError(f"pkgwin line {lineno}: window {cur['label']} has no end marker")
            if not seq.isdigit():
                raise ValueError(f"pkgwin line {lineno}: sequence {seq!r} is not a number")
            cur = {"seq": int(seq), "label": label, "history": [], "dpkg": []}
            part = "history"
        elif what == "dpkg" and cur is not None and cur["label"] == label:
            part = "dpkg"
        elif what == "end" and cur is not None and cur["label"] == label:
            windows.append({"seq": cur["seq"], "label": label,
                            "history": "".join(cur["history"]), "dpkg": "".join(cur["dpkg"])})
            cur, part = None, None
        else:
            raise ValueError(f"pkgwin line {lineno}: marker {what!r} out of order")
    if cur is not None:
        raise ValueError(f"pkgwin: window {cur['label']} has no end marker")
    if not windows:
        raise ValueError(f"pkgwin: the {kind} input holds no window")
    return windows


def parse_apt_history(text):
    """parse apt history.log into events"""
    events = []
    for line in text.splitlines():
        head, sep, tail = line.partition(": ")
        action = HISTORY_ACTIONS.get(head) if sep else None
        if action is None:
            continue
        for name, fields in HISTORY_ENTRY.findall(tail):
            pkg = name.split(":", 1)[0]
            parts = [p.strip() for p in fields.split(",")]
            auto = "automatic" in parts[1:]
            parts = [p for p in parts if p != "automatic"]
            if action == "install":
                events.append((action, pkg, None, parts[0], auto))
            elif action == "upgrade":
                if len(parts) != 2:
                    raise ValueError(f"apt history: {head} entry {name} ({fields}) is not (old, new)")
                events.append((action, pkg, parts[0], parts[1], auto))
            else:
                events.append((action, pkg, parts[0], None, auto))
    return events


def parse_dpkg_log(text):
    """parse dpkg.log into events"""
    events = []
    for line in text.splitlines():
        m = DPKG_EVENT.match(line)
        if not m:
            continue
        action, name, old, new = m.groups()
        pkg = name.split(":", 1)[0]
        old = None if old == "<none>" else old
        new = None if new == "<none>" else new
        events.append((action, pkg, old, new, False))
    return events


def parse_pacman_log(text):
    """parse pacman.log into events"""
    events = []
    for line in text.splitlines():
        m = PACMAN_EVENT.match(line)
        if not m:
            continue
        verb, pkg, vers = m.groups()
        if verb == "reinstalled":
            continue
        if verb == "installed":
            events.append(("install", pkg, None, vers, pkg not in RHIZO_PACKAGES))
        elif verb == "removed":
            events.append(("purge", pkg, vers, None, False))
        else:
            old, arrow, new = vers.partition(" -> ")
            if not arrow:
                raise ValueError(f"pacman.log: {verb} {pkg} ({vers}) is not (old -> new)")
            events.append(("upgrade", pkg, old, new, False))
    return events


def window_events(kind, w):
    """parse the package events of a window"""
    if "[ALPM]" in w["history"] or "[ALPM]" in w["dpkg"]:
        return parse_pacman_log(w["history"])
    if kind == "test-staged":
        return parse_dpkg_log(w["dpkg"])
    return parse_apt_history(w["history"])


def pkg_state(manifest, pkg):
    """return the status and version of a package"""
    if ("pacman", pkg + ".version") in manifest:
        return INSTALLED, manifest[("pacman", pkg + ".version")]
    return manifest.get(("dpkg", pkg + ".status")), manifest.get(("dpkg", pkg + ".version"))


def expected_changes(inputs, phase):
    """return the expected package changes"""
    stream = []
    for kind, windows in inputs.items():
        for w in windows:
            events = window_events(kind, w)
            for i, ev in enumerate(events):
                stream.append((w["seq"], i, kind, ev))
    stream.sort(key=lambda s: (s[0], s[1]))
    exps = {}
    for _seq, _i, kind, (action, pkg, old, new, auto) in stream:
        exp = exps.get(pkg)
        if kind == "rhizo-install":
            if not (action == "install" and auto) and not (exp and exp["rhizo_auto"]):
                continue
        if exp is None:
            exp = exps[pkg] = {"kinds": set(), "first": (action, old), "final": None,
                               "rhizo_auto": False}
        exp["kinds"].add(kind)
        if kind == "rhizo-install" and action == "install" and auto:
            exp["rhizo_auto"] = True
        if action in ("install", "upgrade"):
            exp["final"] = ("present", new)
        elif action == "remove":
            exp["final"] = ("removed", None)
        else:
            exp["final"] = ("absent", None)
    for exp in exps.values():
        if exp["rhizo_auto"] and phase == "purge":
            exp["rhizo_version"] = exp["final"][1] if exp["final"][0] == "present" else None
            exp["final"] = ("absent", None)
    return exps


def dep_names(field):
    """return the package names in a Depends field"""
    names = set()
    for clause in field.split(","):
        for alt in clause.split("|"):
            name = alt.strip().split(" ", 1)[0].split("(", 1)[0].split(":", 1)[0]
            if name:
                names.add(name)
    return names


def parse_apt_kept_text(text):
    """parse the apt record into kept packages"""
    kept, sim, cur, part, ended, lists = {}, set(), None, None, False, {}
    auto, marked, sim_rc = set(), set(), None
    provides, deps = {}, {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.startswith(APTKEPT_TAG + " "):
            fields = line.split()
            what = fields[2] if len(fields) > 2 else ""
            if ended:
                raise ValueError(f"apt-kept line {lineno}: marker after the end marker")
            if what == "kept" and len(fields) == 4 and part != "sim":
                cur, part = fields[3], "kept"
                kept.setdefault(cur, [])
                lists[cur] = 0
            elif what == "autoremove-sim" and len(fields) == 3 and part != "sim":
                cur, part = None, "sim"
            elif what == "end" and len(fields) == 3 and part == "sim":
                ended, part = True, None
            else:
                raise ValueError(f"apt-kept line {lineno}: malformed or out-of-order marker {line!r}")
            continue
        if part is None:
            if line.strip():
                raise ValueError(f"apt-kept line {lineno}: text outside any section: {line!r}")
        elif part == "sim":
            m = APT_REMV.match(line)
            if m:
                sim.add(m.group(1).split(":", 1)[0])
            m = APT_SIM_RC.match(line)
            if m:
                sim_rc = m.group(1)
        elif line.startswith("AUTO"):
            marked.add(cur)
            if line[len("AUTO"):].strip() == cur:
                auto.add(cur)
        elif line == "PROVIDES" or line.startswith("PROVIDES "):
            provides[cur] = set(line.split()[1:])
        elif line.startswith("DEPS "):
            fields = line[len("DEPS "):].split("\t")
            if len(fields) != 3:
                raise ValueError(f"apt-kept line {lineno}: expected DEPS keeper\\tstatus\\tdepends, got {line!r}")
            deps.setdefault(cur, []).append((fields[0].split(":", 1)[0], fields[1], fields[2]))
        elif line == "Reverse Depends:":
            lists[cur] += 1
        elif line.startswith(" ") and line.strip():
            kept[cur].append(line.strip().lstrip("|").split(":", 1)[0])
    if not ended:
        raise ValueError("apt-kept: no end marker")
    if sim_rc != "0":
        raise ValueError(f"apt-kept: apt-get -s autoremove exited {sim_rc or '<unrecorded>'}")
    empty = sorted(p for p, n in lists.items() if n == 0)
    if empty:
        raise ValueError(f"apt-kept: apt-cache rdepends printed no reverse-dependency list for {', '.join(empty)}")
    unmarked = sorted(set(kept) - marked)
    if unmarked:
        raise ValueError(f"apt-kept: no apt-mark showauto answer for {', '.join(unmarked)}")
    unprovided = sorted(set(kept) - set(provides))
    if unprovided:
        raise ValueError(f"apt-kept: no PROVIDES line for {', '.join(unprovided)}")
    confirmed = {}
    for pkg, keepers in kept.items():
        answered = {k for k, _status, _field in deps.get(pkg, ())}
        unanswered = sorted(set(keepers) - answered)
        if unanswered:
            raise ValueError(f"apt-kept: no dpkg-query answer for {', '.join(unanswered)}, which apt-cache "
                             f"names as keeping {pkg}")
        wanted = {pkg} | provides[pkg]
        confirmed[pkg] = {k for k, status, field in deps.get(pkg, ())
                          if status == INSTALLED and dep_names(field) & wanted}
    return {"kept": kept, "confirmed": confirmed, "auto": auto, "sim_remove": sim}


def rhizo_named(inputs):
    """return the package names in the install windows"""
    names = set()
    for w in inputs.get("rhizo-install", []):
        names.update(pkg for _action, pkg, _old, _new, _auto in parse_apt_history(w["history"]))
    for w in inputs.get("test-staged", []):
        names.update(pkg for _action, pkg, _old, _new, _auto in parse_dpkg_log(w["dpkg"]))
    return names


def apt_kept_packages(exps, apt_kept, after, named):
    """return the apt-kept packages"""
    def installed(pkg):
        """return whether a package is installed after the change"""
        return after.get(("dpkg", pkg + ".status")) == INSTALLED
    candidates = [pkg for pkg, exp in exps.items()
                  if exp["rhizo_auto"] and installed(pkg) and pkg in apt_kept["kept"]
                  and pkg in apt_kept["auto"] and pkg not in apt_kept["sim_remove"]]
    accepted, grew = {}, True
    while grew:
        grew = False
        for pkg in candidates:
            if pkg in accepted:
                continue
            roots = sorted({k for k in apt_kept["kept"][pkg]
                            if k != pkg and installed(k) and k in apt_kept["confirmed"][pkg]
                            and (k not in named or k in accepted)})
            if roots:
                accepted[pkg] = roots
                grew = True
    return accepted


def check_expectations(exps, before, after, phase):
    """return failures for expected package states"""
    fails, held = [], set()
    for pkg in sorted(exps):
        exp = exps[pkg]
        kinds = ",".join(sorted(exp["kinds"]))
        action, old = exp["first"]
        bstatus, bver = pkg_state(before, pkg)
        if action == "install" and bstatus == INSTALLED:
            fails.append(f"expected change ({kinds}): {pkg} was installed by the window, but BEFORE "
                         f"already had it at {bver}")
            continue
        if action != "install" and (bstatus != INSTALLED or bver != old):
            fails.append(f"expected change ({kinds}): the window's first {action} of {pkg} starts from "
                         f"{old}, BEFORE has {bstatus or '<absent>'} {bver or ''}".rstrip())
            continue
        state, version = exp["final"]
        astatus, aver = pkg_state(after, pkg)
        if state == "present":
            ok = astatus == INSTALLED and aver == version
            want = f"installed at {version}"
        elif state == "removed":
            ok = astatus in (None, CONFIG_FILES)
            want = "removed"
        else:
            ok = astatus is None
            want = "gone" + (" (apt autoremove --purge)" if exp["rhizo_auto"] and phase == "purge" else "")
        if ok:
            held.add(pkg)
        else:
            fails.append(f"expected change ({kinds}): {pkg} should be {want} after {phase}, "
                         f"AFTER has {astatus or '<absent>'} {aver or ''}".rstrip() + exp.get("apt_why", ""))
    return fails, held


def parse_owned_text(text):
    """parse dpkg -L lines into a path map"""
    owners = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not fields[1].startswith("/"):
            raise ValueError(f"owned line {lineno}: expected pkg\\t/path, got {line!r}")
        owners.setdefault(fields[1], set()).add(fields[0])
    return owners


def installed_kernels(exps, held):
    """return the installed linux-image releases"""
    kvers = set()
    for pkg, exp in exps.items():
        m = KERNEL_IMAGE.match(pkg)
        if m and "ubuntu-update" in exp["kinds"] and pkg in held and exp["final"][0] == "present":
            kvers.add(m.group(1))
    return kvers


def expected_row(section, key, status, bv, av, exps, held, owners, kvers):
    """return the explanation for a diff row"""
    if section in ("dpkg", "pacman"):
        pkg = key.rsplit(".", 1)[0]
        if pkg in held and exps[pkg].get("kept_by"):
            return (f"{pkg} is kept by apt after purge: apt-cache rdepends --installed names "
                    f"{' '.join(exps[pkg]['kept_by'])}, whose installed versions dpkg-query shows depending on it "
                    f"and which Rhizo's install did not bring")
        if pkg in held:
            return f"{pkg} is in its expected state ({','.join(sorted(exps[pkg]['kinds']))})"
        return None
    for kver in sorted(kvers) if status == "changed" else ():
        if (section, key) == ("kernel", "uname_r") and av == kver:
            return f"Ubuntu's own update installed linux-image-{kver} and the host booted it"
        if (section, key) == ("grub", "cmdline") and \
                re.sub(r"BOOT_IMAGE=\S+", f"BOOT_IMAGE=/vmlinuz-{kver}", bv or "") == av:
            return f"only BOOT_IMAGE moved, to the linux-image-{kver} Ubuntu's own update installed"
        if (section, key) == ("grub", "cfg.sha256"):
            return f"the linux-image-{kver} install ran update-grub (/etc/kernel/postinst.d/zz-update-grub)"
    if section == "etc" and key.startswith(ALTERNATIVES_DIR):
        m = SYMLINK_VALUE.match(av or "")
        if status != "added" or "/" in key[len(ALTERNATIVES_DIR):] or not m:
            return None
        for pkg in sorted(owners.get(m.group(1), ())):
            if pkg in held and exps[pkg]["final"][0] == "present":
                return (f"update-alternatives' link to {m.group(1)}, a file of {pkg}, which the run's own "
                        f"record installed; its maintainer script made the link")
        return None

    def kept(pkgs):
        """return the first installed package of pkgs"""
        return next((p for p in sorted(pkgs) if p in held and exps[p]["final"][0] == "present"), None)
    if status == "added":
        m = LINK_VALUE.match(av or "") if section == "etc" else None
        if m:
            target = os.path.normpath(os.path.join(os.path.dirname(key), m.group(1)))
            pkg = kept(owners.get(target, ()))
            if pkg:
                return f"a link to {target}, a file of {pkg}, which the run's own record installed"
        unit = dsh_unit(key) if section == "dsh" else key if section == "unit" else None
        if unit:
            pkg = kept(p for d in UNIT_FILE_DIRS for p in owners.get(d + unit, ()))
            if pkg:
                return f"{unit} is a unit of {pkg}, which the run's own record installed"
        if section in ACCOUNT_SECTIONS and kept((key,)):
            return f"the account {key}, which the maintainer script of {key}, installed by the run's own record, adds"
        pkg = TRIGGER_OUTPUTS.get((section, key))
        if pkg and kept((pkg,)):
            return f"the file {pkg}'s trigger writes, {pkg} being installed by the run's own record"
    if section not in OWNED_SECTIONS or status == "removed":
        return None
    if section == "selinux_xattr" and av not in INHERITED_LABELS:
        return None
    new_path = status == "added" or bv in ABSENT_VALUES
    for pkg in sorted(owners.get(key, ())):
        if pkg not in held or exps[pkg]["final"][0] != "present":
            continue
        if new_path:
            return f"a file of {pkg}, which the run's own record installed or upgraded"
        if section == "selinux_xattr" and exps[pkg]["first"][0] != "install":
            return f"a file of {pkg}, which the run's own record upgraded"
    return None


def dsh_row(section, key, status, after, phase):
    """return the explanation of a deb-systemd-helper row"""
    if phase != "remove" or status != "added":
        return None
    if section == "dsh" and RHIZO_UNIT.match(dsh_unit(key) or ""):
        return (f"deb-systemd-helper's record that it enabled {dsh_unit(key)}: dpkg keeps it across a remove "
                f"so a reinstall re-enables the unit, and the purge deletes it")
    m = ENABLE_LINK.match(key) if section == "etc" else None
    if m and RHIZO_UNIT.match(m.group(3)) and after.get(("dsh", f"{m.group(1)}:{m.group(2)}/{m.group(3)}")) == "present":
        return (f"deb-systemd-helper's link enabling {m.group(3)}, which its record names: dpkg keeps it across "
                f"a remove and the purge deletes it")
    return None


def settle_dependents(unsuppressed, suppressed, after):
    """move explained dependent rows to suppressed"""
    done = {(s, k) for s, k, *_ in suppressed}
    left = {(s, k): row for row in unsuppressed for s, k in [row[:2]]}
    for s, k in sorted(left, key=lambda sk: -len(sk[1])):
        row = left[(s, k)]
        if s != "etc" or row[2] != "added" or not (row[4] or "").startswith("dir "):
            continue
        entries = [(es, ek) for es, ek in after if es == "etc" and ek.startswith(k + "/")]
        if entries and all(e in done for e in entries):
            done.add((s, k))
            suppressed.append(row + ({"reason": "expected: a new directory holding only explained entries"},))
            del left[(s, k)]
    for path, acct in ACCOUNT_FILES.items():
        if any(s == acct for s, _k in left):
            continue
        explained = any(s == acct for s, _k in done)
        for key, why in ((path, "every row of its account section is explained"),
                         (path + "-", f"shadow-utils' backup of {path}, whose own change is explained or absent")):
            row = left.get(("etc", key))
            if row is None or (key == path and not explained) or (key != path and ("etc", path) in left):
                continue
            done.add(("etc", key))
            suppressed.append(row + ({"reason": f"expected: {why}"},))
            del left[("etc", key)]
    return list(left.values()), suppressed


def classify(diffs, allow_rows, phase, explain=None, caller=None):
    """split diffs into suppressed and unsuppressed rows"""
    applicable = [r for r in allow_rows if r["phase"] in (phase, "*")
                  and r.get("caller") in (None, caller)]
    unsuppressed, suppressed, used_lines = [], [], set()
    for section, key, status, bv, av in diffs:
        subject = section + "\\t" + key
        writer = harness_scratch(section, key)
        if writer is not None:
            suppressed.append((section, key, status, bv, av, {"reason": "the harness's own scratch: " + writer}))
            continue
        if logind_session_scope(section, key, bv, av):
            suppressed.append((section, key, status, bv, av,
                               {"reason": "volatile: logind's transient scope for one login session of one boot"}))
            continue
        if fwupd_conf_secured(section, key, bv, av):
            suppressed.append((section, key, status, bv, av,
                               {"reason": "fwupd's own daemon: its first start (fwupd-refresh.timer, or any client "
                                          "activating it) sets this config to 0640; owner and content unchanged"}))
            continue
        hit = None
        for row in applicable:
            if not fnmatch.fnmatchcase(subject, row["pattern"]):
                continue
            if row["value"] is not None and av != row["value"]:
                continue
            hit = row
            break
        if hit is None and explain is not None:
            why = explain(section, key, status, bv, av)
            if why is not None:
                suppressed.append((section, key, status, bv, av, {"reason": "expected: " + why}))
                continue
        if hit is None:
            unsuppressed.append((section, key, status, bv, av))
        else:
            used_lines.add(hit["line"])
            suppressed.append((section, key, status, bv, av, hit))
    unused = [r for r in applicable if r["line"] not in used_lines and not r.get("optional")]
    return unsuppressed, suppressed, unused


def format_diff(section, key, status, bv, av):
    """format a difference as a line"""
    if status == "added":
        return f"+ {section}\t{key}\t{av}"
    if status == "removed":
        return f"- {section}\t{key}\t{bv}"
    return f"~ {section}\t{key}\t{bv} -> {av}"


def mark_apt_kept(exps, apt_kept, after, named):
    """set kept_by or apt_why on each package"""
    accepted = apt_kept_packages(exps, apt_kept, after, named)
    for pkg, exp in exps.items():
        if not exp["rhizo_auto"] or after.get(("dpkg", pkg + ".status")) != INSTALLED:
            continue
        if pkg in accepted:
            exp["final"] = ("present", exp["rhizo_version"])
            exp["kept_by"] = accepted[pkg]
        elif pkg not in apt_kept["kept"]:
            exp["apt_why"] = "; the apt record has no entry for it"
        elif pkg not in apt_kept["auto"]:
            exp["apt_why"] = "; apt-mark no longer counts it automatic, so apt keeps it for that mark alone"
        elif pkg in apt_kept["sim_remove"]:
            exp["apt_why"] = "; apt-get -s autoremove would still remove it"
        elif any(k != pkg and k not in named and k not in apt_kept["confirmed"][pkg]
                 and after.get(("dpkg", k + ".status")) == INSTALLED for k in apt_kept["kept"][pkg]):
            unconfirmed = sorted({k for k in apt_kept["kept"][pkg] if k != pkg and k not in named
                                  and k not in apt_kept["confirmed"][pkg]})
            exp["apt_why"] = (f"; apt-cache rdepends --installed names {' '.join(unconfirmed)}, but dpkg-query "
                              f"shows no installed version of them depending on, pre-depending on or "
                              f"recommending it or what it provides")
        else:
            exp["apt_why"] = (f"; apt-cache rdepends --installed names no installed package outside Rhizo's own "
                              f"install ({' '.join(sorted(set(apt_kept['kept'][pkg]))) or 'none'})")


def run(before, after, allow_rows, phase, verbose=True, inputs=None, owners=None, apt_kept=None, caller=None):
    """return the failure strings for two manifests"""
    diffs = diff_manifests(before, after)
    fails, package_row = [], None
    if inputs:
        exps = expected_changes(inputs, phase)
        if apt_kept is not None and phase == "purge":
            mark_apt_kept(exps, apt_kept, after, rhizo_named(inputs))
        exp_fails, held = check_expectations(exps, before, after, phase)
        fails.extend(exp_fails)
        kvers = installed_kernels(exps, held)
        owners = owners or {}

        def expected(section, key, status, bv, av):
            """return the expected-change row explaining a difference"""
            return expected_row(section, key, status, bv, av, exps, held, owners, kvers)
        package_row = expected

    def explain(section, key, status, bv, av):
        """return the row that explains a difference, or None"""
        return dsh_row(section, key, status, after, phase) or \
            (package_row(section, key, status, bv, av) if package_row else None)
    unsuppressed, suppressed, unused = classify(diffs, allow_rows, phase, explain, caller)
    unsuppressed, suppressed = settle_dependents(unsuppressed, suppressed, after)
    for section, key, status, bv, av in unsuppressed:
        fails.append(f"unallowlisted difference ({phase}): {format_diff(section, key, status, bv, av)}")
    for row in unused:
        fails.append(f"allowlist line {row['line']} matched nothing in this run "
                     f"(phase={row['phase']} pattern={row['pattern']!r}): {row['reason']}")
    if verbose:
        for section, key, status, bv, av, row in suppressed:
            print(f"suppressed: {format_diff(section, key, status, bv, av)} "
                  f"-- {row['reason']}", file=sys.stderr)
        for f in fails:
            print(f"FAIL: host-snapshot-diff: {f}", file=sys.stderr)
    return fails


def pkgwin_fixture(seq, kind, label, history="", dpkg=""):
    """build a package-window record for the selftest"""
    return (f"{PKGWIN_TAG} {seq} {kind} {label} history\n{history}"
            f"{PKGWIN_TAG} {seq} {kind} {label} dpkg\n{dpkg}"
            f"{PKGWIN_TAG} {seq} {kind} {label} end\n")


def selftest_expected_changes():
    """test the --expect and --owned inputs"""
    asserts = 0
    old_cmdline = "BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=LABEL=cloudimg-rootfs ro console=ttyS0"
    new_cmdline = "BOOT_IMAGE=/vmlinuz-6.8.0-142-generic root=LABEL=cloudimg-rootfs ro console=ttyS0"
    before = {
        ("dpkg", "systemd.status"): INSTALLED, ("dpkg", "systemd.version"): "255.4-1ubuntu8.16",
        ("dpkg", "libfoo.status"): INSTALLED, ("dpkg", "libfoo.version"): "1.0",
        ("etc", "/etc"): "dir mode=755 owner=root:root",
        ("etc", "/etc/systemd/journald.conf"): "file mode=644 owner=root:root sha256=aaa",
        ("selinux_xattr", "/usr/lib/systemd/systemd"): "<none>",
        ("selinux_xattr", "/usr/bin/systemctl"): "<none>",
        ("kernel", "uname_r"): "6.8.0-136-generic",
        ("grub", "cmdline"): old_cmdline,
        ("grub", "cfg.sha256"): "aaa",
    }
    rhizo_history = (
        "Start-Date: 2026-09-24  01:50:34\n"
        "Commandline: apt-get install -y ./rhizo_0.1.0_amd64.deb\n"
        "Install: xdg-utils:amd64 (1.1.3-4.1ubuntu3, automatic), rhizo:amd64 (0.1.0), "
        "libx11-protocol-perl:amd64 (0.56-9, automatic)\n"
        "End-Date: 2026-09-24  01:50:54\n\n")
    update_history = (
        "Start-Date: 2026-09-24  01:59:52\n"
        "Commandline: /usr/bin/unattended-upgrade\n"
        "Upgrade: systemd:amd64 (255.4-1ubuntu8.16, 255.4-1ubuntu8.17)\n"
        "End-Date: 2026-09-24  02:00:05\n\n"
        "Start-Date: 2026-09-24  02:01:00\n"
        "Commandline: apt-get -o Dir::Etc::sourceparts=- -y install linux-generic\n"
        "Install: linux-image-6.8.0-142-generic:amd64 (6.8.0-142.142, automatic), linux-generic:amd64 (6.8.0-142.142)\n"
        "End-Date: 2026-09-24  02:01:30\n\n")
    staged_dpkg = (
        "2026-09-24 01:40:00 install dkms:all <none> 3.0.11-1ubuntu13\n"
        "2026-09-24 01:40:01 status installed dkms:all 3.0.11-1ubuntu13\n"
        "2026-09-24 01:40:02 install gcc:amd64 <none> 4:13.2.0-7ubuntu1\n")

    def inputs_from(rhizo=rhizo_history, update=update_history, staged=staged_dpkg):
        """build the package-window inputs for the selftest"""
        return {
            "test-staged": parse_pkgwin_text(pkgwin_fixture(10, "test-staged", "step1-offline-pool", dpkg=staged), "test-staged"),
            "rhizo-install": parse_pkgwin_text(pkgwin_fixture(20, "rhizo-install", "step1-install", history=rhizo), "rhizo-install"),
            "ubuntu-update": parse_pkgwin_text(pkgwin_fixture(30, "ubuntu-update", "step5", history=update), "ubuntu-update"),
        }
    inputs = inputs_from()
    owners = parse_owned_text(
        "systemd\t/usr/lib/systemd/systemd\nsystemd\t/usr/bin/systemctl\nsystemd\t/etc\n"
        "systemd\t/etc/systemd/journald.conf\n"
        "xdg-utils\t/usr/bin/xdg-open\ndkms\t/var/lib/dkms\ndkms\t/etc/kernel/postinst.d/dkms\n"
        "linux-image-6.8.0-142-generic\t/etc/kernel/postinst.d/zz-image\n"
        "gcc\t/usr/bin/gcc\ngcc\t/usr/share/man/man1/gcc.1.gz\n")
    after_remove = dict(before)
    after_remove.update({
        ("dpkg", "systemd.version"): "255.4-1ubuntu8.17",
        ("dpkg", "xdg-utils.status"): INSTALLED, ("dpkg", "xdg-utils.version"): "1.1.3-4.1ubuntu3",
        ("dpkg", "libx11-protocol-perl.status"): INSTALLED, ("dpkg", "libx11-protocol-perl.version"): "0.56-9",
        ("dpkg", "dkms.status"): INSTALLED, ("dpkg", "dkms.version"): "3.0.11-1ubuntu13",
        ("dpkg", "gcc.status"): INSTALLED, ("dpkg", "gcc.version"): "4:13.2.0-7ubuntu1",
        ("etc", "/etc/alternatives/cc"): "symlink target=/usr/bin/gcc",
        ("etc", "/etc/alternatives/cc.1.gz"): "symlink target=/usr/share/man/man1/gcc.1.gz",
        ("etc", "/etc/alternatives/open"): "symlink target=/usr/bin/xdg-open",
        ("home_root", "/root/rhizo-artifact"): "listed",
        ("home_root", "/root/rhizo-artifact/rhizo_0.1.1_amd64.deb"): "listed",
        ("home_root", "/root/rhizo-lifecycle-fixture.apk"): "listed",
        ("dpkg", "linux-image-6.8.0-142-generic.status"): INSTALLED,
        ("dpkg", "linux-image-6.8.0-142-generic.version"): "6.8.0-142.142",
        ("dpkg", "linux-generic.status"): INSTALLED, ("dpkg", "linux-generic.version"): "6.8.0-142.142",
        ("selinux_xattr", "/usr/lib/systemd/systemd"): "u:object_r:unlabeled:s0",
        ("selinux_xattr", "/usr/bin/xdg-open"): "<none>",
        ("etc", "/etc/kernel/postinst.d/dkms"): "file mode=755 owner=root:root sha256=ccc",
        ("kernel", "uname_r"): "6.8.0-142-generic",
        ("grub", "cmdline"): new_cmdline,
        ("grub", "cfg.sha256"): "bbb",
    })
    after_purge = {k: v for k, v in after_remove.items()
                   if not k[1].startswith(("xdg-utils.", "libx11-protocol-perl."))
                   and k[1] not in ("/usr/bin/xdg-open", "/etc/alternatives/open")}

    def expect_fail(name, fails, needle):
        """require that a planted defect was caught by name"""
        assert any(needle in f for f in fails), (
            f"planted defect not caught by name ({name}): expected {needle!r}, got:\n" + "\n".join(fails))

    fails = run(before, after_remove, [], "remove", verbose=False, inputs=inputs, owners=owners)
    assert not fails, f"a remove whose every change the run's own record explains must diff clean, got: {fails}"
    fails = run(before, after_purge, [], "purge", verbose=False, inputs=inputs, owners=owners)
    assert not fails, f"a purge that took the automatic closure must diff clean, got: {fails}"
    asserts += 2

    fails = run(before, after_remove, [], "remove", verbose=False)
    expect_fail("the delta without its inputs", fails, "+ dpkg\txdg-utils.status")
    asserts += 1

    fails = run(before, after_remove, [], "purge", verbose=False, inputs=inputs, owners=owners)
    expect_fail("an automatic dependency left after purge", fails,
                "xdg-utils should be gone (apt autoremove --purge) after purge")
    asserts += 1

    planted = dict(after_purge)
    planted[("selinux_xattr", "/usr/bin/systemctl")] = "u:object_r:rhizo_host_exec:s0"
    planted[("rhizo_dirs", "/var/lib/rhizo/.upgrade-from")] = "listed"
    planted[("etc", "/etc/rhizo/policy.conf")] = "file mode=644 owner=root:root sha256=ddd"
    fails = run(before, planted, [], "purge", verbose=False, inputs=inputs, owners=owners)
    expect_fail("a Rhizo label on an upgraded package's file", fails, "~ selinux_xattr\t/usr/bin/systemctl")
    expect_fail("a leftover Rhizo file", fails, "+ rhizo_dirs\t/var/lib/rhizo/.upgrade-from")
    expect_fail("a leftover file no expected package owns", fails, "+ etc\t/etc/rhizo/policy.conf")
    asserts += 3

    alt = dict(after_purge)
    alt[("etc", "/etc/alternatives/open")] = "symlink target=/usr/bin/xdg-open"
    alt[("etc", "/etc/alternatives/rhizo-x")] = "symlink target=/usr/lib/rhizo/x"
    alt[("etc", "/etc/alternatives/c89")] = "file mode=644 owner=root:root sha256=abc"
    fails = run(before, alt, [], "purge", verbose=False, inputs=inputs, owners=owners)
    expect_fail("an alternative left after the autoremove took its package", fails, "+ etc\t/etc/alternatives/open")
    expect_fail("an alternative to a file no expected package owns", fails, "+ etc\t/etc/alternatives/rhizo-x")
    expect_fail("a plain file under /etc/alternatives", fails, "+ etc\t/etc/alternatives/c89")
    assert not any("/etc/alternatives/cc" in f for f in fails), \
        f"gcc's own cc link, gcc test-staged and still installed, must be explained, got: {fails}"
    moved_before = dict(before)
    moved_before[("etc", "/etc/alternatives/cc")] = "symlink target=/usr/bin/clang"
    fails = run(moved_before, after_remove, [], "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("an existing alternative repointed", fails, "~ etc\t/etc/alternatives/cc")
    asserts += 5

    _, suppressed, _ = classify(diff_manifests(before, after_remove), [], "remove")
    why = {k: row["reason"] for _s, k, _st, _b, _a, row in suppressed}
    assert "installer_transfer_artifact" in why.get("/root/rhizo-artifact/rhizo_0.1.1_amd64.deb", ""), \
        f"a .deb under the transfer dir must be suppressed naming its writer, got: {why}"
    stray = dict(after_remove)
    stray[("home_root", "/root/.rhizo_init_pid")] = "listed"
    stray[("home_root", "/root/rhizo-artifact-evil")] = "listed"
    fails = run(before, stray, [], "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("Rhizo's own state under /root", fails, "+ home_root\t/root/.rhizo_init_pid")
    expect_fail("a sibling that only shares a harness path's prefix", fails, "+ home_root\t/root/rhizo-artifact-evil")
    asserts += 3

    unused_rows = parse_allow_text("*\tdpkg\\tdkms.*\tDKMS stand-in\n*\tdpkg\\tnothing-here.*\tunused row\n")
    fails = run(before, after_remove, unused_rows, "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("an unused allow row beside the inputs", fails, "allowlist line 2 matched nothing")
    assert not any("allowlist line 1 " in f for f in fails), \
        f"an allow row that matched a diff the inputs also explain must count as used, got: {fails}"
    asserts += 2

    missing = {k: v for k, v in after_remove.items() if not k[1].startswith("linux-image-6.8.0-142-generic.")}
    missing[("etc", "/etc/kernel/postinst.d/zz-image")] = "file mode=755 owner=root:root sha256=eee"
    fails = run(before, missing, [], "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("an expected install that is not there", fails,
                "linux-image-6.8.0-142-generic should be installed at 6.8.0-142.142 after remove")
    expect_fail("a file of a package whose expectation failed", fails, "+ etc\t/etc/kernel/postinst.d/zz-image")
    older_before = dict(before)
    older_before[("dpkg", "systemd.version")] = "255.4-1ubuntu8.15"
    fails = run(older_before, after_remove, [], "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("a window whose upgrade starts from a version BEFORE lacks", fails,
                "first upgrade of systemd starts from 255.4-1ubuntu8.16, BEFORE has install ok installed 255.4-1ubuntu8.15")
    asserts += 2

    wrong_kernel = dict(after_remove)
    wrong_kernel[("kernel", "uname_r")] = "6.8.0-150-generic"
    wrong_kernel[("grub", "cmdline")] = new_cmdline + " security=selinux"
    fails = run(before, wrong_kernel, [], "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("a kernel the update never installed", fails, "~ kernel\tuname_r")
    expect_fail("a Rhizo token left on the cmdline", fails, "~ grub\tcmdline")
    asserts += 2

    upgrade_dep = rhizo_history + (
        "Start-Date: 2026-09-24  01:51:00\n"
        "Commandline: apt-get install -y ./rhizo_0.1.1_amd64.deb\n"
        "Upgrade: libfoo:amd64 (1.0, 1.1)\n"
        "End-Date: 2026-09-24  01:51:10\n")
    dep_after = dict(after_remove)
    dep_after[("dpkg", "libfoo.version")] = "1.1"
    dep_after[("etc", "/etc")] = "dir mode=700 owner=root:root"
    dep_after[("etc", "/etc/systemd/journald.conf")] = "file mode=644 owner=root:root sha256=fff"
    fails = run(before, dep_after, [], "remove", verbose=False, inputs=inputs_from(rhizo=upgrade_dep), owners=owners)
    expect_fail("a pre-existing package rhizo's install upgraded", fails, "~ dpkg\tlibfoo.version")
    expect_fail("an upgraded package's directory", fails, "~ etc\t/etc\t")
    expect_fail("an upgraded package's conffile, which Rhizo may have edited", fails, "~ etc\t/etc/systemd/journald.conf")
    asserts += 3

    for name, text, kind, why in (
            ("an incomplete window", f"{PKGWIN_TAG} 5 rhizo-install step1 incomplete dpkg.log rotated\n",
             "rhizo-install", "not captured whole: dpkg.log rotated"),
            ("a window of another kind", pkgwin_fixture(5, "test-staged", "x"), "rhizo-install",
             "a test-staged window in the rhizo-install input"),
            ("a window with no end", f"{PKGWIN_TAG} 5 rhizo-install step1 history\n", "rhizo-install",
             "window step1 has no end marker"),
            ("no window at all", "", "ubuntu-update", "the ubuntu-update input holds no window")):
        try:
            parse_pkgwin_text(text, kind)
            err = ""
        except ValueError as e:
            err = str(e)
        assert why in err, f"{name} must be refused naming {why!r}, got {err or 'no refusal'!r}"
        asserts += 1

    kept_history = rhizo_history.replace(
        "libx11-protocol-perl:amd64 (0.56-9, automatic)\n",
        "libx11-protocol-perl:amd64 (0.56-9, automatic), libwww-perl:amd64 (6.76-1, automatic), "
        "liburi-perl:amd64 (5.27-1, automatic)\n")
    assert kept_history != rhizo_history, "selftest cannot plant the kept packages: the fixture history moved"
    kept_inputs = inputs_from(rhizo=kept_history)
    kept_before = dict(before)
    kept_before.update({("dpkg", "ieee-data.status"): INSTALLED, ("dpkg", "ieee-data.version"): "20220827.1"})
    kept_after = dict(after_purge)
    kept_after.update({("dpkg", "ieee-data.status"): INSTALLED, ("dpkg", "ieee-data.version"): "20220827.1",
                       ("dpkg", "libwww-perl.status"): INSTALLED, ("dpkg", "libwww-perl.version"): "6.76-1",
                       ("dpkg", "liburi-perl.status"): INSTALLED, ("dpkg", "liburi-perl.version"): "5.27-1",
                       ("selinux_xattr", "/usr/bin/lwp-download"): "<none>"})
    kept_owners = dict(owners)
    kept_owners["/usr/bin/lwp-download"] = {"libwww-perl"}

    def deps_lines(keepers, pkg, override):
        """return a DEPS line per package name"""
        out = ""
        for k in sorted({l.strip().lstrip("|") for l in keepers}):
            out += f"DEPS {k}:amd64\t" + override.get(k, f"install ok installed\tperl, {pkg} (>= 1.0), ") + "\n"
        return out

    def apt_record(www=(" |ieee-data", "  libxml-parser-perl"), uri=("  libwww-perl",), sim="", www_auto="libwww-perl",
                   sim_rc="SIM_RC=0\n", www_deps=None, www_provides=""):
        """build an apt-kept record for the selftest"""
        return (f"{APTKEPT_TAG} kept libwww-perl\nAUTO {www_auto}\nPROVIDES {www_provides}\nlibwww-perl\n"
                f"Reverse Depends:\n" + "".join(l + "\n" for l in www) +
                deps_lines(www, "libwww-perl", www_deps or {}) +
                f"{APTKEPT_TAG} kept liburi-perl\nAUTO liburi-perl\nPROVIDES \nliburi-perl\nReverse Depends:\n" +
                "".join(l + "\n" for l in uri) + deps_lines(uri, "liburi-perl", {}) +
                f"{APTKEPT_TAG} autoremove-sim\nReading package lists...\n{sim}"
                f"0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n{sim_rc}"
                f"{APTKEPT_TAG} end\n")

    def kept_run(after=kept_after, record=None, before_=kept_before):
        """run the diff on the apt-kept fixtures"""
        return run(before_, after, [], "purge", verbose=False, inputs=kept_inputs, owners=kept_owners,
                   apt_kept=parse_apt_kept_text(record if record is not None else apt_record()))

    fails = kept_run()
    assert not fails, f"a package apt keeps for the host's own ieee-data, with its file, must diff clean, got: {fails}"
    asserts += 1
    fails = run(kept_before, kept_after, [], "purge", verbose=False, inputs=kept_inputs, owners=kept_owners)
    expect_fail("a kept package with no apt record", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge")
    asserts += 1
    fails = kept_run(record=apt_record(www=("  liburi-perl",)))
    expect_fail("a kept package whose only keeper is Rhizo's own closure", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge, AFTER has install ok installed "
                "6.76-1; apt-cache rdepends --installed names no installed package outside Rhizo's own install")
    expect_fail("a package kept only by a rejected one", fails, "liburi-perl should be gone")
    asserts += 2
    no_ieee = {k: v for k, v in kept_after.items() if not k[1].startswith("ieee-data.")}
    fails = kept_run(after=no_ieee, before_=before)
    expect_fail("a keeper apt names that is not installed", fails, "libwww-perl should be gone")
    asserts += 1
    fails = kept_run(record=apt_record(sim="Remv libwww-perl [6.76-1]\nRemv liburi-perl [5.27-1]\n"))
    expect_fail("a package apt's own simulation still removes", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge, AFTER has install ok installed "
                "6.76-1; apt-get -s autoremove would still remove it")
    asserts += 1
    rhizo_left = dict(kept_after)
    rhizo_left.update({("dpkg", "rhizo.status"): INSTALLED, ("dpkg", "rhizo.version"): "0.1.0"})
    fails = kept_run(after=rhizo_left, record=apt_record(www=("  rhizo",)))
    expect_fail("a package kept by rhizo itself", fails, "libwww-perl should be gone")
    asserts += 1
    fails = kept_run(record=apt_record(www=("  dkms",)))
    expect_fail("a package kept only by a test-staged stand-in for Rhizo's own dependency", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge, AFTER has install ok installed "
                "6.76-1; apt-cache rdepends --installed names no installed package outside Rhizo's own install")
    assert ("dpkg", "dkms.status") in kept_after, "selftest cannot plant the dkms keeper: it is not installed after purge"
    asserts += 1
    fails = kept_run(record=apt_record(www=(" |ieee-data",),
                                       www_deps={"ieee-data": "install ok installed\tperl, , libfoo"}))
    expect_fail("a keeper whose installed version does not name the package", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge, AFTER has install ok installed "
                "6.76-1; apt-cache rdepends --installed names ieee-data, but dpkg-query shows no installed version")
    fails = kept_run(record=apt_record(www=(" |ieee-data",),
                                       www_deps={"ieee-data": "deinstall ok config-files\tlibwww-perl, , "}))
    expect_fail("a keeper dpkg-query does not show installed", fails, "libwww-perl should be gone")
    fails = kept_run(record=apt_record(www=(" |ieee-data",), www_provides="libwww-perl-api",
                                       www_deps={"ieee-data": "install ok installed\t, , libfoo | libwww-perl-api:any (>= 2)"}))
    assert not fails, f"a keeper that recommends a name the package provides must confirm it, got: {fails}"
    fails = kept_run(record=apt_record(www=(" |ieee-data",),
                                       www_deps={"ieee-data": "install ok installed\tlibwww-perl-api, , "}))
    expect_fail("a keeper naming a provided name the package does not provide", fails, "libwww-perl should be gone")
    asserts += 4
    fails = kept_run(record=apt_record(www_auto=""))
    expect_fail("a package someone marked manual after Rhizo's install", fails,
                "libwww-perl should be gone (apt autoremove --purge) after purge, AFTER has install ok installed "
                "6.76-1; apt-mark no longer counts it automatic")
    asserts += 1
    moved = dict(kept_after)
    moved[("dpkg", "libwww-perl.version")] = "6.77-1"
    fails = kept_run(after=moved)
    expect_fail("a kept package at another version than Rhizo's install gave it", fails,
                "libwww-perl should be installed at 6.76-1 after purge")
    asserts += 1
    unowned = dict(kept_after)
    unowned[("etc", "/etc/rhizo/policy.conf")] = "file mode=644 owner=root:root sha256=ddd"
    fails = kept_run(after=unowned)
    expect_fail("a leftover file beside a kept package", fails, "+ etc\t/etc/rhizo/policy.conf")
    asserts += 1
    for name, text, why in (
            ("a record cut short", apt_record().replace(f"{APTKEPT_TAG} end\n", ""), "no end marker"),
            ("a kept section apt-cache printed no list for",
             apt_record().replace("liburi-perl\nReverse Depends:\n", "E: No packages found\n"),
             "printed no reverse-dependency list for liburi-perl"),
            ("a simulation apt refused to run", apt_record(sim="E: Unmet dependencies.\n", sim_rc="SIM_RC=100\n"),
             "apt-get -s autoremove exited 100"),
            ("a simulation with no exit status", apt_record(sim_rc=""), "apt-get -s autoremove exited <unrecorded>"),
            ("a kept section with no apt-mark answer", apt_record().replace("AUTO liburi-perl\n", ""),
             "no apt-mark showauto answer for liburi-perl"),
            ("a kept section with no PROVIDES line", apt_record().replace("PROVIDES \nliburi-perl\n", "liburi-perl\n"),
             "no PROVIDES line for liburi-perl"),
            ("a keeper with no dpkg-query answer",
             apt_record().replace("DEPS ieee-data:amd64\tinstall ok installed\tperl, libwww-perl (>= 1.0), \n", ""),
             "no dpkg-query answer for ieee-data, which apt-cache names as keeping libwww-perl"),
            ("a DEPS line cut short", apt_record().replace("\tperl, libwww-perl (>= 1.0), \n", "\n", 1),
             "expected DEPS keeper\\tstatus\\tdepends"),
            ("a record with no autoremove simulation",
             f"{APTKEPT_TAG} kept libwww-perl\nlibwww-perl\nReverse Depends:\n  ieee-data\n{APTKEPT_TAG} end\n",
             "out-of-order marker")):
        try:
            parse_apt_kept_text(text)
            err = ""
        except ValueError as e:
            err = str(e)
        assert why in err, f"{name} must be refused naming {why!r}, got {err or 'no refusal'!r}"
        asserts += 1
    return asserts


def selftest_pacman_changes():
    """test pacman.log windows and pacman -Ql output"""
    before = {
        ("pacman", "systemd.version"): "258-1",
        ("etc", "/etc"): "dir mode=755 owner=root:root",
    }
    install_log = (
        "[2026-10-05T05:57:18+0000] [PACMAN] Running 'pacman -U --noconfirm ./rhizo-0.1.3-1-any.pkg.tar.zst'\n"
        "[2026-10-05T05:57:20+0000] [ALPM] transaction started\n"
        "[2026-10-05T05:57:20+0000] [ALPM] installed dkms (3.4.3-1)\n"
        "[2026-10-05T05:57:21+0000] [ALPM] installed rhizo (0.1.3-1)\n"
        "[2026-10-05T05:57:21+0000] [ALPM] transaction completed\n")
    upgrade_log = (
        "[2026-10-05T06:10:00+0000] [ALPM] upgraded rhizo (0.1.3-1 -> 0.1.3-2)\n"
        "[2026-10-05T06:10:01+0000] [ALPM] reinstalled dkms (3.4.3-1)\n")
    both = pkgwin_fixture(20, "rhizo-install", "step7-install", history=install_log, dpkg=install_log) \
        + pkgwin_fixture(30, "rhizo-install", "step11-upgrade", history=upgrade_log, dpkg=upgrade_log)
    inputs = {"rhizo-install": parse_pkgwin_text(both, "rhizo-install")}
    owners = parse_owned_text("dkms\t/etc/dkms\ndkms\t/usr/bin/dkms\n")
    after_remove = dict(before)
    after_remove.update({("pacman", "dkms.version"): "3.4.3-1",
                         ("etc", "/etc/dkms"): "dir mode=755 owner=root:root"})
    after_purge = dict(before)
    asserts = 0
    events = parse_pacman_log(install_log + upgrade_log)
    assert events == [("install", "dkms", None, "3.4.3-1", True),
                      ("install", "rhizo", None, "0.1.3-1", False),
                      ("upgrade", "rhizo", "0.1.3-1", "0.1.3-2", False)], f"pacman.log parsed to {events}"
    asserts += 1
    fails = run(before, after_remove, [], "remove", verbose=False, inputs=inputs, owners=owners)
    assert not fails, f"a remove keeping pacman's dependency and its files must diff clean, got: {fails}"
    fails = run(before, after_purge, [], "purge", verbose=False, inputs=inputs, owners=owners)
    assert not fails, f"a purge that took pacman's dependency must diff clean, got: {fails}"
    asserts += 2
    fails = run(before, after_remove, [], "purge", verbose=False, inputs=inputs, owners=owners)
    assert any("dkms should be gone" in f for f in fails), \
        "a purge that left pacman's dependency installed was not caught: " + "\n".join(fails)
    fails = run(before, after_remove, [], "remove", verbose=False)
    assert any("+ pacman\tdkms.version" in f for f in fails), \
        "the dependency with no window to explain it was not caught: " + "\n".join(fails)
    asserts += 2
    lts_log = "[2026-10-05T06:20:00+0000] [ALPM] installed linux-cachyos-lts (6.18.55-1)\n"
    inputs_lts = dict(inputs)
    inputs_lts["host-update"] = parse_pkgwin_text(
        pkgwin_fixture(25, "host-update", "step5", history=lts_log, dpkg=lts_log), "host-update")
    with_lts = dict(after_purge)
    with_lts[("pacman", "linux-cachyos-lts.version")] = "6.18.55-1"
    fails = run(before, with_lts, [], "purge", verbose=False, inputs=inputs_lts, owners=owners)
    assert not fails, f"a purge keeping the host's own second kernel must diff clean, got: {fails}"
    fails = run(before, after_purge, [], "purge", verbose=False, inputs=inputs_lts, owners=owners)
    assert any("linux-cachyos-lts should be installed at 6.18.55-1" in f for f in fails), \
        "the host's own kernel gone after a purge was not caught: " + "\n".join(fails)
    asserts += 2
    try:
        parse_pacman_log("[2026-10-05T06:10:00+0000] [ALPM] upgraded rhizo (0.1.3-2)\n")
    except ValueError:
        asserts += 1
    else:
        raise AssertionError("an upgrade line with no old -> new was not refused")
    return asserts


def selftest_side_effects():
    """test recorded side effects of a remove"""
    asserts = 0
    history = ("Start-Date: 2026-09-24  01:50:34\n"
               "Commandline: apt-get install -y ./rhizo_0.1.0_amd64.deb\n"
               "Install: pipewire:amd64 (1.0.5, automatic), rtkit:amd64 (0.13, automatic), "
               "desktop-file-utils:amd64 (0.27, automatic), rhizo:amd64 (0.1.0)\n"
               "End-Date: 2026-09-24  01:50:54\n\n")
    inputs = {"rhizo-install": parse_pkgwin_text(
        pkgwin_fixture(20, "rhizo-install", "step1-install", history=history), "rhizo-install")}
    owners = parse_owned_text("pipewire\t/usr/lib/systemd/user/pipewire.service\n"
                              "rtkit\t/lib/systemd/system/rtkit-daemon.service\n"
                              "rtkit\t/etc/init.d/rtkit\n")
    before = {("etc", "/etc/passwd"): "file sha256=a", ("etc", "/etc/shadow"): "file sha256=a",
              ("etc", "/etc/group"): "file sha256=a", ("etc", "/etc/gshadow"): "file sha256=a",
              ("etc", "/etc/passwd-"): "file sha256=0"}
    after = dict(before)
    after.update({
        ("dpkg", "pipewire.status"): INSTALLED, ("dpkg", "pipewire.version"): "1.0.5",
        ("dpkg", "rtkit.status"): INSTALLED, ("dpkg", "rtkit.version"): "0.13",
        ("dpkg", "desktop-file-utils.status"): INSTALLED, ("dpkg", "desktop-file-utils.version"): "0.27",
        ("dpkg", "rhizo.status"): CONFIG_FILES, ("dpkg", "rhizo.version"): "0.1.0",
        ("etc", "/etc/systemd/user/default.target.wants"): "dir mode=755 owner=root:root",
        ("etc", "/etc/systemd/user/default.target.wants/pipewire.service"):
            "symlink target=/usr/lib/systemd/user/pipewire.service",
        ("etc", "/etc/systemd/user/default.target.wants/rhizo-desktop-session.path"):
            "symlink target=/usr/lib/systemd/user/rhizo-desktop-session.path",
        ("dsh", "user:default.target.wants/rhizo-desktop-session.path"): "present",
        ("dsh", "user:default.target.wants/pipewire.service"): "present",
        ("etc", "/etc/systemd/system/sockets.target.wants/rhizo-api.socket"):
            "symlink target=/usr/lib/systemd/system/rhizo-api.socket",
        ("dsh", "system:sockets.target.wants/rhizo-api.socket"): "present",
        ("dsh", "system:rhizo-api.socket.dsh-also"): "present",
        ("etc", "/etc/rc2.d/S01rtkit"): "symlink target=../init.d/rtkit",
        ("unit", "rtkit-daemon.service"): "disabled",
        ("passwd", "rtkit"): "uid=109 gid=112 home=/proc shell=/usr/sbin/nologin",
        ("group", "rtkit"): "gid=112 members=", ("group", "pipewire"): "gid=114 members=",
        ("etc", "/etc/passwd"): "file sha256=b", ("etc", "/etc/shadow"): "file sha256=b",
        ("etc", "/etc/group"): "file sha256=b", ("etc", "/etc/gshadow"): "file sha256=b",
        ("etc", "/etc/passwd-"): "file sha256=a", ("etc", "/etc/group-"): "file sha256=a",
        ("applications", "/usr/share/applications/mimeinfo.cache"): "listed",
    })
    allow = parse_allow_text("remove\tdpkg\\trhizo.*\tdpkg's remove-vs-purge contract\n")

    def expect_fail(name, fails, needle):
        """require that a planted defect was caught by name"""
        assert any(needle in f for f in fails), (
            f"planted defect not caught by name ({name}): expected {needle!r}, got:\n" + "\n".join(fails))

    fails = run(before, after, allow, "remove", verbose=False, inputs=inputs, owners=owners)
    assert not fails, f"a remove leaving only recorded side effects and dpkg's own links must diff clean: {fails}"
    asserts += 1

    unrecorded = {k: v for k, v in after.items() if k != ("dsh", "system:sockets.target.wants/rhizo-api.socket")}
    expect_fail("a Rhizo link no deb-systemd-helper record names",
                run(before, unrecorded, allow, "remove", verbose=False, inputs=inputs, owners=owners),
                "+ etc\t/etc/systemd/system/sockets.target.wants/rhizo-api.socket")
    expect_fail("a Rhizo link and record a purge left",
                run(before, after, [], "purge", verbose=False, inputs=inputs, owners=owners),
                "+ dsh\tsystem:sockets.target.wants/rhizo-api.socket")
    asserts += 2

    stranger = dict(after)
    stranger[("etc", "/etc/rc2.d/S01foreign")] = "symlink target=../init.d/foreign"
    stranger[("unit", "foreign.service")] = "enabled"
    stranger[("passwd", "foreign")] = "uid=110 gid=113 home=/ shell=/bin/sh"
    fails = run(before, stranger, allow, "remove", verbose=False, inputs=inputs, owners=owners)
    for needle in ("+ etc\t/etc/rc2.d/S01foreign", "+ unit\tforeign.service", "+ passwd\tforeign",
                   "~ etc\t/etc/passwd\t", "~ etc\t/etc/shadow\t", "~ etc\t/etc/passwd-\t"):
        expect_fail("a side effect no recorded package explains: " + needle.strip(), fails, needle)
    assert not any("/etc/group" in f for f in fails), f"the explained group file was flagged: {fails}"
    asserts += 7

    no_dfu = dict(after)
    no_dfu[("dpkg", "desktop-file-utils.status")] = CONFIG_FILES
    expect_fail("mimeinfo.cache with desktop-file-utils gone",
                run(before, no_dfu, allow, "remove", verbose=False, inputs=inputs, owners=owners),
                "+ applications\t/usr/share/applications/mimeinfo.cache")
    stray = dict(after)
    stray[("etc", "/etc/systemd/user/default.target.wants/stray.service")] = "symlink target=/opt/stray.service"
    fails = run(before, stray, allow, "remove", verbose=False, inputs=inputs, owners=owners)
    expect_fail("a new directory holding an unexplained entry", fails,
                "+ etc\t/etc/systemd/user/default.target.wants\tdir")
    asserts += 2

    scoped = parse_allow_text("remove@installer\tetc\\t/etc/rc2.d/S01foreign\tthe installer's own\n"
                              "remove?\trhizo_dirs\\t/var/lib/rhizo/pool*\tpresent only on some runs\n"
                              "remove\trhizo_dirs\\t/var/lib/rhizo/data.img\tkept on remove\n")
    base = {("etc", "/etc/rc2.d/S01foreign"): "symlink target=../init.d/foreign"}
    fails = run({}, base, scoped, "remove", verbose=False, caller="cycle")
    expect_fail("an @installer row read by the cycle", fails, "+ etc\t/etc/rc2.d/S01foreign")
    assert not any("line 1 " in f or "line 2 " in f for f in fails), f"a scoped or optional row was reported unused: {fails}"
    expect_fail("a required row that matched nothing", fails, "allowlist line 3 matched nothing")
    fails = run({}, base, scoped, "remove", verbose=False, caller="installer")
    assert not any("S01foreign" in f for f in fails), f"the installer's own row did not apply to it: {fails}"
    asserts += 4
    return asserts


def selftest():
    """run the host-snapshot-diff selftest assertions"""
    asserts = 0

    before = {
        ("dpkg", "sway.status"): "install ok installed",
        ("etc", "/etc/hosts"): "file mode=644 owner=root:root sha256=aaa",
        ("rhizo_dirs", "/var/lib/rhizo"): "absent",
    }
    after_clean = dict(before)
    allow_text = (
        "*\tdpkg\\tdkms.*\tRecommends left after remove, never autoremoved\n"
        "remove\trhizo_dirs\\t/etc/rhizo*\ta plain apt remove keeps your configuration on purpose\n"
    )
    allow_rows = parse_allow_text(allow_text)

    fails = run(before, after_clean, [], "remove", verbose=False)
    assert not fails, f"two identical manifests with no allowlist rows must diff clean, got: {fails}"
    asserts += 1

    after = dict(before)
    after[("dpkg", "libfoo.status")] = "install ok installed"
    after[("etc", "/etc/hosts")] = "file mode=644 owner=root:root sha256=bbb"
    del after[("rhizo_dirs", "/var/lib/rhizo")]
    after[("dpkg", "dkms.status")] = "install ok installed"
    after[("rhizo_dirs", "/etc/rhizo")] = "present"

    fails_remove = run(before, after, allow_rows, "remove", verbose=False)
    cases = [
        ("an unallowlisted new key", "+ dpkg\tlibfoo.status"),
        ("an unallowlisted changed value", "~ etc\t/etc/hosts"),
        ("an unallowlisted removed key", "- rhizo_dirs\t/var/lib/rhizo"),
    ]
    for name, expected in cases:
        assert any(expected in f for f in fails_remove), (
            f"planted defect not caught by name ({name}): expected {expected!r}, got:\n" +
            "\n".join(fails_remove))
        asserts += 1

    assert not any("dkms.status" in f for f in fails_remove), \
        "an allowlisted diff (phase=*) must not be reported as a failure"
    assert not any(f.startswith("unallowlisted difference") and "/etc/rhizo" in f for f in fails_remove), \
        "an allowlisted diff (phase=remove) must not be reported as a failure"
    asserts += 1

    scoped = dict(before)
    scoped[("unit", "session-1.scope")] = "transient"
    scoped_after = dict(before)
    scoped_after[("unit", "session-2.scope")] = "transient"
    scoped_after[("unit", "session-c1.scope")] = "transient"
    for phase in ("remove", "purge"):
        fails_scoped = run(scoped, scoped_after, [], phase, verbose=False)
        assert not fails_scoped, f"logind session scopes coming and going must diff clean ({phase}), got: {fails_scoped}"
        asserts += 1
    leftovers = dict(scoped_after)
    leftovers[("unit", "rhizo-lc-dacprobe.path")] = "transient"
    leftovers[("unit", "user@1000.service")] = "transient"
    leftovers[("unit", "session-3.scope")] = "static"
    leftovers[("unit", "session-4.service")] = "transient"
    fails_leftover = run(scoped, leftovers, [], "purge", verbose=False)
    for key in ("rhizo-lc-dacprobe.path", "user@1000.service", "session-3.scope", "session-4.service"):
        assert any(f.startswith("unallowlisted difference") and f"\t{key}\t" in f for f in fails_leftover), (
            f"a leftover transient {key} must still fail the purge, got:\n" + "\n".join(fails_leftover))
        asserts += 1
    assert not any("session-2.scope" in f or "session-c1.scope" in f for f in fails_leftover), \
        "the logind session scopes beside a leftover must stay suppressed"
    asserts += 1

    sha = "a25bd457c86be85a286cd175d94e30fa152eb119c95b2a7db8a495886cdd7654"
    fw = ("etc", "/etc/fwupd/fwupd.conf")
    fw_before = dict(before)
    fw_before[fw] = f"file mode=644 owner=root:root sha256={sha}"
    fw_after = dict(fw_before)
    fw_after[fw] = f"file mode=640 owner=root:root sha256={sha}"
    for phase in ("remove", "purge"):
        fails_fw = run(fw_before, fw_after, [], phase, verbose=False)
        assert not fails_fw, f"fwupd securing its own config must diff clean ({phase}), got: {fails_fw}"
        asserts += 1
    for label, bv, av in (
            ("a content change", f"file mode=644 owner=root:root sha256={sha}", f"file mode=640 owner=root:root sha256={'b' * 64}"),
            ("an owner change", f"file mode=644 owner=root:root sha256={sha}", f"file mode=640 owner=root:rhizo sha256={sha}"),
            ("a mode other than fwupd's 0640", f"file mode=644 owner=root:root sha256={sha}", f"file mode=600 owner=root:root sha256={sha}"),
            ("a loosening back to 0644", f"file mode=640 owner=root:root sha256={sha}", f"file mode=644 owner=root:root sha256={sha}"),
            ("a removal", f"file mode=644 owner=root:root sha256={sha}", None)):
        b_, a_ = dict(before), dict(before)
        b_[fw] = bv
        if av is not None:
            a_[fw] = av
        fails_fw = run(b_, a_, [], "remove", verbose=False)
        assert any(f.startswith("unallowlisted difference") and "/etc/fwupd/fwupd.conf" in f for f in fails_fw), (
            f"{label} of /etc/fwupd/fwupd.conf must still fail, got: {fails_fw}")
        asserts += 1
    other = ("etc", "/etc/fwupd/remotes.d/lvfs.conf")
    b_, a_ = dict(before), dict(before)
    b_[other] = f"file mode=644 owner=root:root sha256={sha}"
    a_[other] = f"file mode=640 owner=root:root sha256={sha}"
    fails_fw = run(b_, a_, [], "remove", verbose=False)
    assert any(f.startswith("unallowlisted difference") and "lvfs.conf" in f for f in fails_fw), \
        f"the same 0644 -> 0640 on another file must still fail, got: {fails_fw}"
    asserts += 1

    fails_purge = run(before, after, allow_rows, "purge", verbose=False)
    assert any(f.startswith("unallowlisted difference") and "/etc/rhizo" in f for f in fails_purge), \
        "a remove-only allow row must not suppress the same diff under --phase purge"
    asserts += 1

    after_no_dkms_diff = dict(before)
    fails_unused = run(before, after_no_dkms_diff, allow_rows, "remove", verbose=False)
    assert any(f.startswith("allowlist line 1 matched nothing") for f in fails_unused), (
        "an allow row that matched nothing must be reported by its own line number, got:\n" +
        "\n".join(fails_unused))
    asserts += 1

    value_allow_rows = parse_allow_text(
        "remove\tdpkg\\trhizo.status\treason\tdeinstall ok config-files\n")
    before_v = {("dpkg", "rhizo.status"): "install ok installed"}
    after_v_match = {("dpkg", "rhizo.status"): "deinstall ok config-files"}
    fails_v_match = run(before_v, after_v_match, value_allow_rows, "remove", verbose=False)
    assert not fails_v_match, (
        f"a diff whose AFTER value matches the allow row's own value column must be "
        f"suppressed, got: {fails_v_match}")
    asserts += 1

    after_v_mismatch = {("dpkg", "rhizo.status"): "purge ok not-installed"}
    fails_v_mismatch = run(before_v, after_v_mismatch, value_allow_rows, "remove", verbose=False)
    assert any("dpkg\trhizo.status" in f for f in fails_v_mismatch), (
        f"a diff whose AFTER value does NOT match the allow row's value column must "
        f"still be reported, not silently suppressed by the pattern alone, got: "
        f"{fails_v_mismatch}")
    asserts += 1

    try:
        parse_allow_text("bogus-phase\tfoo\treason\n")
        raised = False
    except ValueError:
        raised = True
    assert raised, "a phase other than remove/purge/* must be refused, not silently accepted"
    asserts += 1

    try:
        parse_manifest_text("dpkg\tsway.status\tinstall ok installed\n")
        raised = False
    except ValueError as e:
        raised = "sentinel" in str(e)
    assert raised, "a manifest with no completeness sentinel must be refused by name"
    asserts += 1

    try:
        parse_manifest_text(f"{SENTINEL_LINE}\ndpkg\tsway.status\tinstall ok installed\n")
        raised = False
    except ValueError as e:
        raised = "sentinel" in str(e)
    assert raised, "a sentinel that is not the last line must still be refused"
    asserts += 1

    good = parse_manifest_text(f"dpkg\tsway.status\tinstall ok installed\n{SENTINEL_LINE}\n")
    assert good[("dpkg", "sway.status")] == "install ok installed", \
        "a well-formed manifest (sentinel last) must parse its rows normally"
    asserts += 1

    asserts += selftest_expected_changes()
    asserts += selftest_pacman_changes()
    asserts += selftest_side_effects()
    print(f"host-snapshot-diff selftest: {asserts} assertions")
    return 0


def main():
    """parse arguments and run the manifest diff"""
    ap = argparse.ArgumentParser()
    ap.add_argument("before", nargs="?")
    ap.add_argument("after", nargs="?")
    ap.add_argument("--phase", choices=["remove", "purge"])
    ap.add_argument("--allow")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--check-allow", metavar="FILE",
                    help="parse FILE as an allowlist and exit -- no BEFORE/AFTER, no VM; "
                         "syntax check for make test and a "
                         "test's own preflight")
    ap.add_argument("--expect", action="append", default=[], metavar="KIND=FILE",
                    help="one run's lc_pkgwin record of a package operation, KIND one of "
                         + ", ".join(PKGWIN_KINDS))
    ap.add_argument("--owned", metavar="FILE",
                    help="pkg<TAB>path lines, dpkg -L of every --list-expected package on the guest")
    ap.add_argument("--list-expected", action="store_true",
                    help="print the packages the --expect inputs leave installed after --phase, one per line")
    ap.add_argument("--apt-kept", metavar="FILE",
                    help="the guest's apt-cache rdepends --installed and apt-get -s autoremove record, taken "
                         "after the purge's autoremove")
    ap.add_argument("--caller", choices=CALLERS,
                    help="the system test running the diff; allow rows scoped @<caller> apply only to its runs")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.check_allow:
        try:
            rows = parse_allow(args.check_allow)
        except ValueError as e:
            print(f"FAIL: host-snapshot-diff: {e}", file=sys.stderr)
            return 1
        print(f"{args.check_allow}: {len(rows)} allowlist row(s), all well-formed")
        return 0

    inputs = {}
    try:
        for spec in args.expect:
            kind, sep, path = spec.partition("=")
            if not sep or kind not in PKGWIN_KINDS:
                ap.error(f"--expect {spec!r}: want KIND=FILE, KIND one of {', '.join(PKGWIN_KINDS)}")
            with open(path, encoding="utf-8", errors="replace") as fh:
                inputs.setdefault(kind, []).extend(parse_pkgwin_text(fh.read(), kind))
        owners = None
        if args.owned:
            with open(args.owned, encoding="utf-8", errors="replace") as fh:
                owners = parse_owned_text(fh.read())
        apt_kept = None
        if args.apt_kept:
            with open(args.apt_kept, encoding="utf-8", errors="replace") as fh:
                apt_kept = parse_apt_kept_text(fh.read())
    except ValueError as e:
        print(f"FAIL: host-snapshot-diff: {e}", file=sys.stderr)
        return 1

    if args.list_expected:
        if not (args.phase and inputs):
            ap.error("--list-expected needs --phase and at least one --expect")
        for pkg, exp in sorted(expected_changes(inputs, args.phase).items()):
            if exp["final"][0] == "present" or (apt_kept and exp["rhizo_auto"] and pkg in apt_kept["kept"]
                                                and pkg not in apt_kept["sim_remove"]):
                print(pkg)
        return 0

    if not (args.before and args.after and args.phase and args.allow):
        ap.error("BEFORE, AFTER, --phase and --allow are all required outside --selftest/--check-allow")

    before = parse_manifest(args.before)
    after = parse_manifest(args.after)
    allow_rows = parse_allow(args.allow)
    fails = run(before, after, allow_rows, args.phase, verbose=True, inputs=inputs, owners=owners,
                apt_kept=apt_kept, caller=args.caller)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
