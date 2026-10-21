#!/usr/bin/env python3
import contextlib
import io
import os
import re
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
LAUNCHER = "src/androidd/boot.py"
MOUNTS = "src/androidd/sandbox/rootfs.py"
INSTALLER = "src/install/prepare/prepare.sh"

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-device-cgroup-filter")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher3       # noqa: E402
    from sandbox import capabilities  # noqa: E402
    from sandbox import rootfs     # noqa: E402


class _StubPolicy:
    """stub policy for capability checks"""
    def __init__(self, values):
        """keep the capability values"""
        self._values = values

    def allows(self, capability):
        """return whether a capability is allowed"""
        return self._values[capability]


def _decode(prog):
    """return the instructions of a BPF program as tuples"""
    return [struct.unpack("<BBhi", prog[i:i + 8]) for i in range(0, len(prog), 8)]


def _execute(prog, major, minor, access_type=0):
    """run the eBPF program on a device"""
    ctx = struct.pack("<III", access_type, major, minor)
    regs = [0] * 11
    insns = _decode(prog)
    pc = 0
    for _ in range(len(insns) + 1):
        code, regsb, off, imm = insns[pc]
        dst = regsb & 0xF
        if code == 0xb7:
            regs[dst] = imm
        elif code == 0x61:
            regs[dst] = struct.unpack_from("<I", ctx, off)[0]
        elif code == 0x55:
            if regs[dst] != imm:
                pc += off
        elif code == 0x95:
            return regs[0]
        else:
            raise ValueError("unknown opcode 0x%02x at insn %d" % (code, pc))
        pc += 1
    raise ValueError("program never reached exit within its own instruction count")


_PROBES = (
    (226, 0, "dri renderD128"),
    (226, 128, "dri card0"),
    (10, 223, "uinput"),
    (10, 200, "tun"),
    (10, 237, "misc loop-control (major 10, unrelated minor)"),
    (1, 9, "urandom"),
    (4, 1, "tty"),
)

_WITHHELD_SCENARIOS = (
    ("nothing withheld", []),
    ("dri only", [(226, None)]),
    ("uinput only", [(10, 223)]),
    ("tun only", [(10, 200)]),
    ("all three", [(226, None), (10, 223), (10, 200)]),
)


def _expected_deny(withheld, major, minor):
    """return whether a device is in the withheld set"""
    return any(m == major and (n is None or n == minor) for m, n in withheld)


def _program_semantics_findings(build_fn):
    """check the filter program's device verdicts"""
    findings = []
    for scenario_label, withheld in _WITHHELD_SCENARIOS:
        try:
            prog = build_fn(withheld)
        except Exception as e:
            findings.append("%s: build_device_filter_program raised %r" % (scenario_label, e))
            continue
        if not prog or len(prog) % 8:
            findings.append("%s: program is %r bytes, not a positive multiple of 8"
                            % (scenario_label, len(prog) if prog else 0))
            continue
        for major, minor, probe_label in _PROBES:
            want_deny = _expected_deny(withheld, major, minor)
            try:
                r0 = _execute(prog, major, minor)
            except ValueError as e:
                findings.append("%s / %s: %s" % (scenario_label, probe_label, e))
                continue
            got_deny = (r0 == 0)
            if got_deny != want_deny:
                findings.append("%s / %s: expected %s, program left r0=%d" % (
                    scenario_label, probe_label,
                    "DENY (r0=0)" if want_deny else "ALLOW (r0=1)", r0))
    return findings


def _always_allow_program(withheld):
    """return a program that allows every device"""
    return launcher3._mov64_imm(0, 1) + launcher3._bpf_exit()


_FIXTURE_PATHS = {
    "devices.dri": ("/fake/dri/renderD128", True),
    "devices.uinput": ("/fake/uinput", False),
    "devices.tun": ("/fake/net/tun", False),
}
_FIXTURE_STAT_TABLE = {
    "/fake/dri/renderD128": (226, 128),
    "/fake/uinput": (10, 223),
    "/fake/net/tun": (10, 200),
}


class _FakeStatResult:
    def __init__(self, major, minor):
        """keep a device number built from a major and minor"""
        self.st_rdev = os.makedev(major, minor)


def _fixture_stat_fn(table=_FIXTURE_STAT_TABLE):
    """return a stat function backed by a table of fixture devices"""
    def fn(path):
        """return the fixture stat of a path or raise FileNotFoundError"""
        if path not in table:
            raise FileNotFoundError(path)
        return _FakeStatResult(*table[path])
    return fn


def _absent_stat_fn(path):
    """raise FileNotFoundError for any path"""
    raise FileNotFoundError(path)


def _eacces_stat_fn(path):
    """raise PermissionError for any path"""
    raise PermissionError(13, "Permission denied")


def _withheld_majors_findings(fn):
    """return the withheld_device_majors case failures"""
    findings = []
    all_on = _StubPolicy({"devices.dri": True, "devices.uinput": True, "devices.tun": True})
    got = fn(all_on, paths=_FIXTURE_PATHS, stat_fn=_fixture_stat_fn())
    if got != []:
        findings.append("every capability on: expected [], got %r" % (got,))

    dri_off = _StubPolicy({"devices.dri": False, "devices.uinput": True, "devices.tun": True})
    got = fn(dri_off, paths=_FIXTURE_PATHS, stat_fn=_fixture_stat_fn())
    if got != [(226, None)]:
        findings.append("devices.dri off only: expected [(226, None)], got %r" % (got,))

    all_off = _StubPolicy({"devices.dri": False, "devices.uinput": False, "devices.tun": False})
    got = fn(all_off, paths=_FIXTURE_PATHS, stat_fn=_fixture_stat_fn())
    if got != [(226, None), (10, 200), (10, 223)]:
        findings.append("every capability off: expected the whole set in alphabetical-"
                        "by-capability order, got %r" % (got,))

    got = fn(dri_off, paths=_FIXTURE_PATHS, stat_fn=_absent_stat_fn)
    if got != []:
        findings.append("withheld capability with no host device at all: expected [], "
                        "got %r" % (got,))

    got = fn(dri_off, paths=_FIXTURE_PATHS, stat_fn=_eacces_stat_fn)
    if got is not None:
        findings.append("withheld capability that cannot be stat'd (EACCES): expected "
                        "None (fail closed), got %r" % (got,))
    return findings


def _noop_withheld_majors(policy, log=lambda m: None, paths=None, stat_fn=os.stat):
    """return an empty list"""
    return []


def _make_bpf_ok():
    """return a bpf stub and its call list"""
    calls = []

    def bpf_ok(cmd, attr):
        """record the BPF command and return a program descriptor for a load"""
        calls.append(cmd)
        if cmd == launcher3._BPF_PROG_LOAD:
            return os.open(os.devnull, os.O_RDONLY)
        return 0
    return bpf_ok, calls


def _bpf_load_fails(cmd, attr):
    """fail the program load and refuse any later command"""
    if cmd == launcher3._BPF_PROG_LOAD:
        return -1
    raise AssertionError("BPF_PROG_ATTACH/DETACH must never run after a failed PROG_LOAD")


def _bpf_attach_fails(cmd, attr):
    """load the program and fail the attach"""
    if cmd == launcher3._BPF_PROG_LOAD:
        return os.open(os.devnull, os.O_RDONLY)
    if cmd == launcher3._BPF_PROG_ATTACH:
        return -1
    return 0


def _install_findings(install_fn):
    """check the filter install in each scenario"""
    findings = []
    dri_off = _StubPolicy({"devices.dri": False, "devices.uinput": True, "devices.tun": True})
    common = dict(paths=_FIXTURE_PATHS, stat_fn=_fixture_stat_fn())

    bpf_ok, calls = _make_bpf_ok()
    with tempfile.TemporaryDirectory() as cg:
        ok = install_fn(cg, dri_off, log=lambda m: None, bpf_fn=bpf_ok, **common)
    if ok is not True:
        findings.append("a fully-working bpf_fn: expected True, got %r" % (ok,))
    if launcher3._BPF_PROG_LOAD not in calls or launcher3._BPF_PROG_ATTACH not in calls:
        findings.append("a fully-working bpf_fn: expected PROG_LOAD and PROG_ATTACH both "
                        "called, got %r" % (calls,))

    with tempfile.TemporaryDirectory() as cg:
        ok = install_fn(cg, dri_off, log=lambda m: None, bpf_fn=_bpf_load_fails, **common)
    if ok is not False:
        findings.append("BPF_PROG_LOAD failing: expected False, got %r" % (ok,))

    with tempfile.TemporaryDirectory() as cg:
        ok = install_fn(cg, dri_off, log=lambda m: None, bpf_fn=_bpf_attach_fails, **common)
    if ok is not False:
        findings.append("BPF_PROG_ATTACH failing: expected False, got %r" % (ok,))

    bpf_ok2, _ = _make_bpf_ok()
    ok = install_fn("/nonexistent/cgroup/dir-for-check", dri_off, log=lambda m: None,
                    bpf_fn=bpf_ok2, **common)
    if ok is not False:
        findings.append("a cgroup directory that does not exist: expected False, got %r"
                        % (ok,))

    bpf_recorder, recorder_calls = _make_bpf_ok()
    with tempfile.TemporaryDirectory() as cg:
        ok = install_fn(cg, dri_off, log=lambda m: None, bpf_fn=bpf_recorder,
                        paths=_FIXTURE_PATHS, stat_fn=_eacces_stat_fn)
    if ok is not False:
        findings.append("an unresolvable withheld major: expected False, got %r" % (ok,))
    if recorder_calls:
        findings.append("an unresolvable withheld major: expected NO bpf(2) call at all "
                        "(nothing to install), got %r" % (recorder_calls,))
    return findings


def _install_ignores_failure(cgroup_dir, policy, log=lambda m: None, bpf_fn=None,
                             paths=None, stat_fn=os.stat):
    """return True"""
    return True


_CALL_SITE = ('if not install_device_cgroup_filter(cgroup_root, _ceiling_policy, '
              'log=kmsg):')
_FATAL_LOG = 'FATAL: device cgroup filter not in force'
_FATAL_EXIT = 'os._exit(1)'
_G_FORK = 'g=os.fork()'
_G_UNSHARE = 'unshare(CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWCGROUP'


def _static_findings(text):
    """return the problems in the launcher text around the install call"""
    findings = []
    if _CALL_SITE not in text:
        findings.append("prepare_host_and_data no longer calls install_device_cgroup_filter "
                        "the expected way")
        return findings
    call_at = text.index(_CALL_SITE)
    log_at = text.find(_FATAL_LOG, call_at)
    if log_at == -1:
        findings.append("install_device_cgroup_filter's failure path no longer logs "
                        "\"%s\"" % _FATAL_LOG)
        return findings
    exit_at = text.find(_FATAL_EXIT, log_at)
    if exit_at == -1 or exit_at - log_at > 400:
        findings.append("install_device_cgroup_filter's failure path no longer os._exit(1)s "
                        "right after logging FATAL")
        return findings
    fork_at = text.find(_G_FORK)
    unshare_at = text.find(_G_UNSHARE)
    if fork_at == -1 or unshare_at == -1:
        findings.append("could not locate g's own fork()/unshare(CLONE_NEWCGROUP) call "
                        "sites")
    elif not (call_at < exit_at < fork_at < unshare_at):
        findings.append("install_device_cgroup_filter is not called (and fatally exited on "
                        "failure) strictly BEFORE g's own fork() and its "
                        "unshare(CLONE_NEWCGROUP)")
    return findings


def _coverage_findings(declared=None, filtered=None, swept=None, without_node=None):
    """find devices capabilities with no filter row or node sweep"""
    if declared is None:
        declared = {n for n in capabilities.CAPABILITIES if n.startswith("devices.")}
    if filtered is None:
        filtered = set(rootfs.DEVICE_FILTER_HOST_PATHS)
    if swept is None:
        swept = set(rootfs.DEVICE_NODE_CAPABILITIES)
    if without_node is None:
        without_node = rootfs.DEVICE_CAPABILITIES_WITHOUT_NODE
    no_node = set(without_node)
    findings = []
    for missing in sorted(declared - filtered - no_node):
        findings.append("%s is a devices.* capability with no row in "
                        "DEVICE_FILTER_HOST_PATHS or DEVICE_CAPABILITIES_WITHOUT_NODE"
                        % missing)
    for extra in sorted(filtered - declared):
        findings.append("DEVICE_FILTER_HOST_PATHS names %s, which sandbox/capabilities.py "
                        "does not declare" % extra)
    for extra in sorted(no_node - declared):
        findings.append("DEVICE_CAPABILITIES_WITHOUT_NODE names %s, which "
                        "sandbox/capabilities.py does not declare" % extra)
    for both in sorted(filtered & no_node):
        findings.append("%s has a DEVICE_FILTER_HOST_PATHS row and is also in "
                        "DEVICE_CAPABILITIES_WITHOUT_NODE" % both)
    for name, reason in sorted(without_node.items()):
        if not str(reason).strip():
            findings.append("DEVICE_CAPABILITIES_WITHOUT_NODE gives %s no reason" % name)
    for missing in sorted(swept - filtered):
        findings.append("%s is swept by DEVICE_NODE_CAPABILITIES but has no "
                        "DEVICE_FILTER_HOST_PATHS row" % missing)
    return findings


DEVICE_FILTER_MODULE_OWNERS = {
    "devices.uinput": "uinput",
    "devices.tun": "tun",
}
_INSTALLER_MODS_RE = re.compile(r'mods\+=\(loop dm-mod dm-verity[^)]*\)')


def _installer_modules_from_text(text):
    """return the module names the installer text lists, or None"""
    match = _INSTALLER_MODS_RE.search(text)
    if not match:
        return None
    return set(match.group(0)[len("mods+=("):-1].split())


def _module_coverage_findings(installer_text):
    """return the module coverage failures"""
    findings = []
    mods = _installer_modules_from_text(installer_text)
    if mods is None:
        findings.append("%s: could not find the mods+=(loop dm-mod dm-verity ...) module-"
                        "load list" % INSTALLER)
        return findings
    for capability, module in sorted(DEVICE_FILTER_MODULE_OWNERS.items()):
        if capability not in rootfs.DEVICE_FILTER_HOST_PATHS:
            continue
        if module not in mods:
            findings.append("%s enforces %s by stat'ing its real host node, but %s's "
                            "module-load set does not include %r; without %s loaded, "
                            "%s gets no deny rule"
                            % (MOUNTS, capability, INSTALLER, module, module,
                               capability))
    return findings


def check(root=REPO):
    """return the problems in the launcher and installer under a root"""
    findings = []
    launcher_path = os.path.join(root, LAUNCHER)
    try:
        with open(launcher_path) as handle:
            launcher_text = handle.read()
    except OSError as e:
        return ["%s: cannot read: %s" % (LAUNCHER, e)]
    installer_path = os.path.join(root, INSTALLER)
    try:
        with open(installer_path) as handle:
            installer_text = handle.read()
    except OSError as e:
        return ["%s: cannot read: %s" % (INSTALLER, e)]
    findings += _static_findings(launcher_text)
    findings += _coverage_findings()
    findings += _module_coverage_findings(installer_text)
    findings += _program_semantics_findings(launcher3.build_device_filter_program)
    findings += _withheld_majors_findings(rootfs.withheld_device_majors)
    findings += _install_findings(launcher3.install_device_cgroup_filter)
    return findings


def selftest(root=REPO):
    """run each check case and print results"""
    cases = []

    launcher_path = os.path.join(root, LAUNCHER)
    with open(launcher_path) as handle:
        real_text = handle.read()

    fails = _static_findings(real_text)
    cases.append(("the real tree's call site, fail-closed and ordering all hold", not fails, fails))

    missing_call = real_text.replace(_CALL_SITE, "pass  # call site removed")
    fails = _static_findings(missing_call)
    cases.append(("a missing call site is flagged", len(fails) == 1, fails))

    swallowed = real_text.replace(
        _FATAL_LOG, "device cgroup filter degraded -- continuing anyway  # ")
    fails = _static_findings(swallowed)
    cases.append(("a failure path that no longer logs FATAL is flagged", len(fails) == 1, fails))

    reordered = (
        "def run_sandbox(entry):\n"
        "    privileged_setup()\n"
        "    " + _G_FORK + "\n"
        "    if g==0:\n"
        "        " + _G_UNSHARE + "|CLONE_NEWIPC|CLONE_NEWUTS|CLONE_NEWNET)\n"
        "        " + _CALL_SITE + "\n"
        "            kmsg(f\"" + _FATAL_LOG + " on {cgroup_root} -- ...\")\n"
        "            " + _FATAL_EXIT + "\n"
    )
    fails = _static_findings(reordered)
    cases.append(("a filter installed AFTER g's fork/unshare is flagged",
                 len(fails) == 1 and "BEFORE" in fails[0], fails))

    fails = _coverage_findings()
    cases.append(("the three devices.* tables agree on the real tree", not fails, fails))

    bad_filtered = dict(rootfs.DEVICE_FILTER_HOST_PATHS)
    del bad_filtered["devices.dri"]
    real_filtered = rootfs.DEVICE_FILTER_HOST_PATHS
    rootfs.DEVICE_FILTER_HOST_PATHS = bad_filtered
    try:
        fails = _coverage_findings()
    finally:
        rootfs.DEVICE_FILTER_HOST_PATHS = real_filtered
    cases.append(("a devices.* capability dropped from DEVICE_FILTER_HOST_PATHS is flagged",
                 any("devices.dri" in f for f in fails), fails))

    three = {"devices.dri", "devices.uinput", "devices.tun"}
    fails = _coverage_findings(three | {"devices.sock"}, three, three,
                               {"devices.sock": "a socket, bound only while on"})
    cases.append(("a devices.* capability named as having no node, with a reason, passes clean",
                 not fails, fails))

    fails = _coverage_findings(three | {"devices.sock"}, three, three, {})
    cases.append(("a devices.* capability with neither a filter row nor a no-node row is flagged",
                 len(fails) == 1 and "devices.sock" in fails[0], fails))

    fails = _coverage_findings(three | {"devices.sock"}, three, three, {"devices.sock": ""})
    cases.append(("a no-node devices.* capability with no reason is flagged",
                 len(fails) == 1 and "no reason" in fails[0], fails))

    fails = _coverage_findings(three, three, three, {"devices.tun": "a socket"})
    cases.append(("a capability both filtered and named as having no node is flagged",
                 len(fails) == 1 and "also in" in fails[0], fails))

    fails = _coverage_findings(three, three, three, {"devices.gone": "a socket"})
    cases.append(("a no-node row naming an undeclared capability is flagged",
                 len(fails) == 1 and "devices.gone" in fails[0], fails))

    installer_path = os.path.join(root, INSTALLER)
    with open(installer_path) as handle:
        real_installer_text = handle.read()

    fails = _module_coverage_findings(real_installer_text)
    cases.append(("the installer's module-load set covers every module-backed devices.* "
                 "capability", not fails, fails))

    mods_match = _INSTALLER_MODS_RE.search(real_installer_text)
    cases.append(("the installer's fixed module-load list is still found by its anchor",
                 mods_match is not None, [] if mods_match else ["_INSTALLER_MODS_RE found nothing"]))

    dropped_tun = real_installer_text.replace(mods_match.group(0),
                                              mods_match.group(0).replace(" tun", "", 1), 1)
    fails = _module_coverage_findings(dropped_tun)
    cases.append(("dropping tun from the installer's module-load set is caught by name",
                 any("devices.tun" in f and "'tun'" in f for f in fails), fails))

    dropped_uinput = real_installer_text.replace(mods_match.group(0),
                                                  mods_match.group(0).replace(" uinput", "", 1), 1)
    fails = _module_coverage_findings(dropped_uinput)
    cases.append(("dropping uinput from the installer's module-load set is caught by name",
                 any("devices.uinput" in f and "'uinput'" in f for f in fails), fails))

    fails = _module_coverage_findings("mods=() # no fixed list here at all")
    cases.append(("an installer with no fixed module-load list to check fails by name",
                 any(INSTALLER in f for f in fails), fails))

    fails = _program_semantics_findings(launcher3.build_device_filter_program)
    cases.append(("the real build_device_filter_program denies exactly what it is told to",
                 not fails, fails))

    fails = _program_semantics_findings(_always_allow_program)
    cases.append(("an always-allow program (the pre-fix shape) is caught",
                 len(fails) > 0 and all("expected DENY" in f for f in fails), fails))

    fails = _withheld_majors_findings(rootfs.withheld_device_majors)
    cases.append(("the real withheld_device_majors matches every case", not fails, fails))

    fails = _withheld_majors_findings(_noop_withheld_majors)
    cases.append(("a resolver that never withholds anything is caught",
                 len(fails) == 3, fails))

    fails = _install_findings(launcher3.install_device_cgroup_filter)
    cases.append(("the real install_device_cgroup_filter matches every case", not fails, fails))

    fails = _install_findings(_install_ignores_failure)
    cases.append(("an install that swallows every bpf(2) failure is caught",
                 len(fails) == 5, fails))

    fails = check(root)
    cases.append(("the real, fixed tree passes end to end", not fails, fails))

    bad = 0
    for label, ok, fails in cases:
        print("SELFTEST %s: %s" % ("OK" if ok else "FAIL", label))
        if not ok:
            bad += 1
            for line in fails:
                print("    saw: %s" % line)
    return 1 if bad else 0


def main():
    """run the check or its selftest"""
    args = sys.argv[1:]
    root = REPO
    if "--root" in args:
        root = args[args.index("--root") + 1]
    if "--selftest" in args:
        return selftest(root)
    findings = check(root)
    for line in findings:
        print("FAIL: device cgroup filter: %s" % line)
    if not findings:
        print("device cgroup filter: every devices.* capability the policy withholds is "
              "denied mknod/read/write at the cgroup device filter, not just left uncreated")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
