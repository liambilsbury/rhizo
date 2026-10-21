#!/usr/bin/env python3
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
from sandbox import selinux_policy  # noqa: E402
from sandbox import guest_files  # noqa: E402

OWNER_FILES = {"src/androidd/sandbox/selinux_policy.py", "src/androidd/sandbox/guest_files.py",
               "test/checks/policy/rules/policy-template.py"}
OWNER_PREFIX = "src/androidd/guest/"

DEBUG_PROC_CIL = "sepolicy/policy-debug-proc.cil"
DEBUG_PROC_GRANTS = (
    "(allow rhizo_host domain (dir (search open read getattr)))",
    "(allow rhizo_host domain (file (open read getattr)))",
    "(allow rhizo_host domain (lnk_file (read getattr)))",
    "(typeattributeset mlstrustedobject (appdomain))",
)


SOFTWARE_CIL = "sepolicy/policy-software.cil"
SOFTWARE_GRANTS = ("(allow surfaceflinger self (process (execmem)))",)
EXECMEM_NEVERALLOWED = ("system_server", "perfetto", "traced", "traced_probes")
_EXECMEM_GRANT = re.compile(r"^\(allow (\S+) self \(process \(execmem\)\)\)$", re.M)


def markers_in(text):
    """return the whole-line and inline substitution markers in a text"""
    whole = set(re.findall(r"^; @RHIZO_SUBST (\w+)\s*$", text, re.M))
    inline = set(re.findall(r"@RHIZO_SUBST:(\w+)@", text))
    return whole, inline


def _check_debug_proc_texts(default_composition, debug_text):
    """check the debug-proc grants in two texts"""
    bad = []
    for grant in DEBUG_PROC_GRANTS:
        if grant in default_composition:
            bad.append(f"{selinux_policy.CIL_FILENAME}: carries the debug-proc "
                       f"grant {grant!r} -- it must live only in "
                       f"{DEBUG_PROC_CIL}, composed under RHIZO_DEBUG_PROC_READ=1")
    debug_composition = default_composition + debug_text
    for grant in DEBUG_PROC_GRANTS:
        if grant not in debug_composition:
            bad.append(f"the debug composition is missing grant {grant!r}")
    return bad


def check_debug_proc_composition():
    """check the debug-proc grants in each composition"""
    bad = []
    debug_path = guest_files.path(DEBUG_PROC_CIL)
    if not os.path.exists(debug_path):
        return [f"{DEBUG_PROC_CIL} is missing"]
    debug_text = open(debug_path).read()
    template = open(selinux_policy.template_path()).read()
    for declared in (set(selinux_policy.CAP2_ALL), set()):
        for dev in ("port_device udmabuf_device", ""):
            cap2 = lambda *w: " ".join(p for p in w if p in declared)  # noqa: E731
            default_composition = selinux_policy.render(template, dev, cap2)
            bad.extend(_check_debug_proc_texts(default_composition, debug_text))
    return bad


def _check_software_texts(default_composition, software_text):
    """check the execmem grants in the software fragment"""
    bad = []
    for grant in SOFTWARE_GRANTS:
        if grant in default_composition:
            bad.append(f"{selinux_policy.CIL_FILENAME}: carries {grant!r}, which must reach "
                       f"only a devices.dri = off policy through {SOFTWARE_CIL}")
        if grant not in software_text:
            bad.append(f"{SOFTWARE_CIL} is missing {grant!r}")
    for domain in _EXECMEM_GRANT.findall(software_text):
        if domain in EXECMEM_NEVERALLOWED:
            bad.append(f"{SOFTWARE_CIL} grants {domain} execmem, which the gsi's own policy "
                       f"neverallows")
    return bad


def check_software_composition():
    """check the software fragment against each default composition"""
    path = guest_files.path(SOFTWARE_CIL)
    if not os.path.exists(path):
        return [f"{SOFTWARE_CIL} is missing"]
    software_text = open(path).read()
    template = open(selinux_policy.template_path()).read()
    bad = []
    for declared in (set(selinux_policy.CAP2_ALL), set()):
        for dev in ("port_device udmabuf_device", ""):
            cap2 = lambda *w: " ".join(p for p in w if p in declared)  # noqa: E731
            bad.extend(_check_software_texts(selinux_policy.render(template, dev, cap2), software_text))
    return bad


def check(root):
    """return the policy check failures"""
    bad = []
    cil = selinux_policy.template_path()
    if not os.path.exists(cil):
        return [f"{selinux_policy.CIL_FILENAME} is missing"]
    template = open(cil).read()
    whole, inline = markers_in(template)
    if not whole or not inline:
        bad.append(f"{selinux_policy.CIL_FILENAME}: expected both whole-line and "
                   f"inline markers, found {len(whole)} and {len(inline)}")

    for declared in (set(selinux_policy.CAP2_ALL), set()):
        for dev in ("port_device udmabuf_device", ""):
            cap2 = lambda *w: " ".join(p for p in w if p in declared)  # noqa: E731
            try:
                out = selinux_policy.render(template, dev, cap2)
            except (KeyError, ValueError) as e:
                bad.append(f"{selinux_policy.CIL_FILENAME}: render failed with "
                           f"dev={dev!r} caps={sorted(declared)}: {e}")
                continue
            if "@RHIZO_SUBST" in out:
                bad.append(f"{selinux_policy.CIL_FILENAME}: a marker survived rendering")
            if not out.strip():
                bad.append(f"{selinux_policy.CIL_FILENAME}: rendered to nothing")
            try:
                selinux_policy.cts_vendor_adapt(out)
            except ValueError as e:
                bad.append(f"{selinux_policy.CIL_FILENAME}: {e}")

    for f in ("test/checks/lib/policy-lab.sh", "src/androidd/boot.py"):
        full = os.path.join(root, f)
        if not os.path.exists(full):
            bad.append(f"{f} is missing")
            continue
        text = open(full, encoding="utf-8", errors="replace").read()
        if "CIL_FILENAME" in text:
            bad.append(f"{f} names CIL_FILENAME -- call build(cils) and let it "
                       f"resolve the path")

    try:
        files = subprocess.run(
            ["git", "-C", root, "grep", "-lE",
             r"^; @RHIZO_SUBST \w+\s*$|@RHIZO_SUBST:\w+@"],
            capture_output=True, text=True, timeout=60).stdout.split()
    except (OSError, subprocess.SubprocessError):
        files = []
    for f in files:
        if f not in OWNER_FILES and not f.startswith(OWNER_PREFIX):
            bad.append(f"{f} carries a real CIL @RHIZO_SUBST marker -- the substitution "
                       f"belongs to src/androidd/sandbox/selinux_policy.py alone")

    bad.extend(check_debug_proc_composition())
    bad.extend(check_software_composition())
    return bad


def selftest():
    """run each assertion against a fixture"""
    cap2_all = lambda *w: " ".join(w)  # noqa: E731
    cap2_none = lambda *w: ""  # noqa: E731

    try:
        selinux_policy.render("; @RHIZO_SUBST not_a_real_marker\n", "d", cap2_all)
        print("selftest FAIL: an unknown whole-line marker was accepted", file=sys.stderr)
        return 1
    except KeyError:
        pass

    try:
        selinux_policy.render("(allow a b (c (@RHIZO_SUBST:nope@)))\n", "d", cap2_all)
        print("selftest FAIL: an unknown inline marker was accepted", file=sys.stderr)
        return 1
    except KeyError:
        pass

    got = selinux_policy.render("; @RHIZO_SUBST cap2_bpf_perfmon\n", "d", cap2_all)
    if "@RHIZO_SUBST" in got or "capability2" not in got:
        print(f"selftest FAIL: a known marker did not render: {got!r}", file=sys.stderr)
        return 1
    if selinux_policy.render("; @RHIZO_SUBST cap2_bpf_perfmon\n", "d", cap2_none) != "":
        print("selftest FAIL: an undeclared capability still emitted a rule", file=sys.stderr)
        return 1

    with_dev = selinux_policy.render("; @RHIZO_SUBST dev_ok_rule\n", "port_device", cap2_all)
    without = selinux_policy.render("; @RHIZO_SUBST dev_ok_rule\n", "", cap2_all)
    if "not (" not in with_dev or "not (" in without:
        print("selftest FAIL: dev_ok_rule did not switch form", file=sys.stderr)
        return 1

    for marker in ("late_block_ublk", "vold_uevent_ublk"):
        ublk = "; @RHIZO_SUBST %s\n" % marker
        if "sysfs_ublk" not in selinux_policy.render(ublk, "d", cap2_all, frozenset({"sysfs_ublk"})) \
                or selinux_policy.render(ublk, "d", cap2_all) != "":
            print("selftest FAIL: %s did not follow the declared sysfs_ublk" % marker, file=sys.stderr)
            return 1

    import tempfile
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, "x.cil")
        open(c, "w").write("(type port_device)\n(common cap2 (syslog bpf))\n")
        dev, cap2 = selinux_policy.derive([c])
        if dev != "port_device":
            print(f"selftest FAIL: derive() dev_carveout {dev!r}", file=sys.stderr)
            return 1
        if cap2("syslog", "wake_alarm") != "syslog":
            print("selftest FAIL: derive() did not filter an undeclared permission",
                  file=sys.stderr)
            return 1

    for text, n in (("(allow a b (c (d)))\n", 0),
                    (selinux_policy.LIVE_KEYMINT_TT * 2, 2)):
        try:
            selinux_policy.cts_vendor_adapt(text)
            print(f"selftest FAIL: cts_vendor_adapt accepted anchor count {n}",
                  file=sys.stderr)
            return 1
        except ValueError:
            pass
    adapted = selinux_policy.cts_vendor_adapt("x\n" + selinux_policy.LIVE_KEYMINT_TT + "y\n")
    if selinux_policy.LIVE_KEYMINT_TT in adapted or "process rhizo_keymint)" not in adapted:
        print("selftest FAIL: cts_vendor_adapt did not rewrite the transition",
              file=sys.stderr)
        return 1

    grant = DEBUG_PROC_GRANTS[0]
    if _check_debug_proc_texts("(allow a b (c (d)))\n", "\n".join(DEBUG_PROC_GRANTS) + "\n"):
        print("selftest FAIL: a clean default + full fragment was rejected",
              file=sys.stderr)
        return 1
    if not _check_debug_proc_texts(grant + "\n", "\n".join(DEBUG_PROC_GRANTS) + "\n"):
        print("selftest FAIL: the grant leaking into the default composition "
              "was not caught", file=sys.stderr)
        return 1
    if not _check_debug_proc_texts("(allow a b (c (d)))\n", ""):
        print("selftest FAIL: a fragment missing every grant was not caught",
              file=sys.stderr)
        return 1
    software = "\n".join(SOFTWARE_GRANTS) + "\n"
    if _check_software_texts("(allow a b (c (d)))\n", software):
        print("selftest FAIL: a clean default + the software fragment was rejected", file=sys.stderr)
        return 1
    if not any("must reach only" in b for b in _check_software_texts(SOFTWARE_GRANTS[0] + "\n", software)):
        print("selftest FAIL: surfaceflinger's execmem in the default composition was not caught", file=sys.stderr)
        return 1
    if not any("is missing" in b for b in _check_software_texts("(allow a b (c (d)))\n", "")):
        print("selftest FAIL: a software fragment without surfaceflinger's execmem was not caught", file=sys.stderr)
        return 1
    leaked = software + "(allow system_server self (process (execmem)))\n"
    if not any("grants system_server execmem" in b for b in _check_software_texts("(allow a b (c (d)))\n", leaked)):
        print("selftest FAIL: system_server's execmem in the software fragment was not caught", file=sys.stderr)
        return 1
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = check(REPO)
    for b in bad:
        print(b, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
