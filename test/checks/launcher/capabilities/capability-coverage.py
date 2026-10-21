#!/usr/bin/env python3

import os
import re
import subprocess
import sys

GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

TSV = "test/checks/launcher/capabilities/capabilities.tsv"
MODULE = "src/androidd/sandbox/capabilities.py"
CHECKS = "test/checks"
MOUNTS = "src/androidd/sandbox/rootfs.py"
NETBRIDGED = "src/services/netbridged/netbridged.py"
HOST_DIR = "src/services"
NOT_DAEMON_DIRS = {"units", "__pycache__"}
TEST_TOOLS_DIR = "test/system"
TEST_CONTRACT = "test/system/run/contract.tsv"


class Registry:
    def __init__(self):
        """start with empty row tables"""
        self.rows = {}
        self.not_capability = {}
        self.not_daemon = {}
        self.daemon_owner = {}


def _load_capabilities_spec(root):
    """return the CAPABILITIES table loaded from sandbox/capabilities.py"""
    import importlib.util
    path = os.path.join(root, MODULE)
    spec = importlib.util.spec_from_file_location("rhizo_capabilities_check", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.CAPABILITIES


def _default_field_ok(name, default, capspec):
    """check a row's default against the capability's default"""
    spec = capspec.get(name)
    kindless = spec is None or spec["kind"] in ("bool", "set")
    if default in ("on", "off"):
        if kindless:
            return True, None
        return False, ("default=%r, expected the literal default %r (a %s capability "
                        "has no on/off state)" % (default, str(spec["default"]), spec["kind"]))
    if kindless:
        return False, "default=%r, expected on or off" % default
    want = str(spec["default"])
    if default != want:
        return False, "default=%r, does not match the code's own default %r" % (default, want)
    return True, None


def _system_tests():
    """return the system_tests module"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "system", "run"))
    import system_tests
    return system_tests


def system_test_file(tools, name):
    """return the file of the named system test"""
    return _system_tests().test_path(name, tools) or os.path.join(tools, name)


def read_registry(root):
    """return the registry parsed from the capability table file"""
    path = os.path.join(root, TSV)
    reg = Registry()
    section = "rows"
    try:
        with open(path) as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        return None, "%s: cannot read: %s" % (TSV, exc)

    try:
        capspec = _load_capabilities_spec(root)
    except Exception as exc:
        return None, "%s: cannot load %s to validate defaults: %s" % (TSV, MODULE, exc)

    for lineno, line in enumerate(lines, 1):
        if line.startswith("#not-a-capability"):
            section = "not_capability"
            continue
        if line.startswith("#not-a-daemon-capability"):
            section = "not_daemon"
            continue
        if line.startswith("#daemon-owner"):
            section = "daemon_owner"
            continue
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if section == "rows":
            if len(fields) != 4:
                return None, "%s:%d: expected 4 tab-separated fields, got %d" % (
                    TSV, lineno, len(fields))
            name, default, enforcement, proof = fields
            ok, field_err = _default_field_ok(name, default, capspec)
            if not ok:
                return None, "%s:%d: %s" % (TSV, lineno, field_err)
            reg.rows[name] = {
                "default": default, "enforcement": enforcement,
                "proof": proof, "line": lineno,
            }
        else:
            want = 2 if section == "daemon_owner" else 1
            if len(fields) != want:
                return None, "%s:%d: expected %d tab-separated field(s), got %d" % (
                    TSV, lineno, want, len(fields))
            getattr(reg, section)[fields[0]] = fields[-1]
    return reg, None


def module_capabilities(root):
    """return the capability names in sandbox/capabilities.py"""
    path = os.path.join(root, MODULE)
    with open(path) as handle:
        text = handle.read()
    return set(re.findall(r'^\s*"([a-z_]+\.[a-z_]+)":\s*\{', text, re.M))


def mknod_devices(root):
    """return the device names in sandbox/rootfs.py"""
    path = os.path.join(root, MOUNTS)
    with open(path) as handle:
        text = handle.read()
    names = set()
    for match in re.finditer(r'DEV_NODES\s*=\s*\[(.*?)\]', text, re.S):
        names |= set(re.findall(r'["\']([A-Za-z0-9_/.-]+)["\']', match.group(1)))
    for match in re.finditer(r'/dev/([A-Za-z0-9_]+)', text):
        candidate = match.group(1)
        if candidate in ("dri", "tun", "uinput", "block", "shm", "input"):
            names.add(candidate)
    return names


def system_test_names(root):
    """return the names of the system tests under test/system"""
    return set(_system_tests().tests(os.path.join(root, TEST_TOOLS_DIR)))


def test_contract_tests(root):
    """return the test names listed in the contract table"""
    path = os.path.join(root, TEST_CONTRACT)
    tests = set()
    with open(path) as handle:
        for line in handle:
            if not line.strip() or line.startswith("#"):
                continue
            tests.add(line.split("\t", 1)[0])
    return tests


def netbridged_services(root):
    """return the service names in ALL_SERVICES"""
    path = os.path.join(root, NETBRIDGED)
    with open(path) as handle:
        text = handle.read()
    match = re.search(r'ALL_SERVICES\s*=\s*\((.*?)\)', text, re.S)
    if not match:
        return set()
    return set(re.findall(r'["\']([a-z]+)["\']', match.group(1)))


def policy_service_choices(root):
    """return the choices of network.services"""
    path = os.path.join(root, MODULE)
    with open(path) as handle:
        text = handle.read()
    match = re.search(r'"network\.services".*?"choices":\s*\((.*?)\)', text, re.S)
    if not match:
        return set()
    return set(re.findall(r'["\']([a-z]+)["\']', match.group(1)))


def _one_enforcement_resolves(root, enforcement):
    """return the problem with a file:symbol enforcement point, or None"""
    if ":" in enforcement:
        rel, symbol = enforcement.rsplit(":", 1)
    else:
        rel, symbol = enforcement, None
    path = os.path.join(root, rel)
    if not os.path.exists(path):
        return "names %s, which does not exist" % rel
    if symbol is None:
        return None
    with open(path, errors="replace") as handle:
        text = handle.read()
    if not re.search(r'\b%s\b' % re.escape(symbol), text):
        return "names %s in %s, which does not define it" % (symbol, rel)
    return None


def enforcement_resolves(root, enforcement):
    """return the problem with any enforcement point in a cell, or None"""
    points = enforcement.split(";")
    for i, point in enumerate(points):
        problem = _one_enforcement_resolves(root, point)
        if problem:
            if len(points) > 1:
                return "enforcement point %d/%d (%r) %s" % (i + 1, len(points), point, problem)
            return problem
    return None


def registered_checks(root):
    """return the checks make test runs"""
    checks = os.path.join(root, CHECKS)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
    import check_entries
    found = set()
    for e in check_entries.entries(checks):
        script = e["file"]
        if script == "outside.tsv":
            script = next((a for a in e["argv"] if a.endswith((".py", ".sh"))), script)
        found.add((e["kind"], os.path.basename(script)))
    return found


def check(root):
    """compare the registry with the code"""
    fails = []
    reg, err = read_registry(root)
    if err:
        return [err]

    if not reg.rows:
        return ["%s declares no capabilities" % TSV]
    if not reg.not_capability or not reg.not_daemon:
        fails.append("%s lost an exclusion list" % TSV)

    for name, row in sorted(reg.rows.items()):
        for field in ("enforcement", "proof"):
            if "TODO" in row[field]:
                fails.append("%s:%d: %s has TODO in %s" % (TSV, row["line"], name, field))

    declared = module_capabilities(root)
    if not declared:
        fails.append("%s declares no capabilities" % MODULE)
    tabled = {n for n in reg.rows if not n.startswith("config=")}
    for name in sorted(declared - tabled):
        fails.append("%s declares %s and %s does not name it" % (MODULE, name, TSV))
    for name in sorted(tabled - declared):
        fails.append("%s names %s and %s does not declare it" % (TSV, name, MODULE))

    for name, row in sorted(reg.rows.items()):
        problem = enforcement_resolves(root, row["enforcement"])
        if problem:
            fails.append("%s:%d: %s %s" % (TSV, row["line"], name, problem))

    try:
        registered = registered_checks(root)
    except Exception as exc:  # noqa: BLE001
        fails.append("cannot read the runner's checks in %s: %s" % (CHECKS, exc))
        registered = set()
    if not registered:
        fails.append("%s registers no check" % CHECKS)
    names = None
    contract_tests = None
    for name, row in sorted(reg.rows.items()):
        proof = row["proof"]
        if "TODO" in proof:
            continue
        if proof.startswith("test:"):
            label = proof[len("test:"):]
            if names is None:
                names = system_test_names(root)
            if label not in names:
                fails.append("%s:%d: %s names proof %r, which is no system test under %s (no file of that name "
                             "carries a '# test-boot-mode:' header)" % (TSV, row["line"], name, proof, TEST_TOOLS_DIR))
            if contract_tests is None:
                contract_tests = test_contract_tests(root)
            if label not in contract_tests:
                fails.append("%s:%d: %s names proof %r, which has no row in contract.tsv" % (
                    TSV, row["line"], name, proof))
            test_path = system_test_file(os.path.join(root, TEST_TOOLS_DIR), label)
            try:
                with open(test_path, errors="replace") as handle:
                    test_text = handle.read()
            except OSError:
                fails.append("%s:%d: %s names proof %r, whose system test script %s does not exist" % (
                    TSV, row["line"], name, proof, test_path))
            else:
                if name not in test_text:
                    fails.append("%s:%d: %s names proof %r, but %s's own source never "
                                 "mentions %s" % (TSV, row["line"], name, proof, label, name))
            continue
        kind, label = proof.split(":", 1) if ":" in proof else ("run", proof)
        if (kind, label) not in registered:
            fails.append("%s:%d: %s names proof %r, which the runner in %s does not run as a %s" % (
                TSV, row["line"], name, label, CHECKS, kind))

    services = netbridged_services(root)
    if not services:
        fails.append("found no ALL_SERVICES in %s"
                     % NETBRIDGED)
    choices = policy_service_choices(root)
    for service in sorted(services - choices):
        fails.append("%s can run service %r and %s network.services cannot express it"
                     % (NETBRIDGED, service, MODULE))

    devices = mknod_devices(root)
    if not devices:
        fails.append("found no device nodes in %s" % MOUNTS)
    device_rows = {n.split(".", 1)[1] for n in reg.rows if n.startswith("devices.")}
    for device in sorted(devices):
        if device in device_rows or device in reg.not_capability:
            continue
        fails.append("%s creates /dev/%s and %s neither gives it a devices.* row nor "
                     "lists it as not-a-capability" % (MOUNTS, device, TSV))

    host_root = os.path.join(root, HOST_DIR)
    daemons = sorted(d for d in os.listdir(host_root)
                     if d not in NOT_DAEMON_DIRS and os.path.isdir(os.path.join(host_root, d)))
    if not daemons:
        fails.append("found no daemons under %s/" % HOST_DIR)
    enforced_files = " ".join(row["enforcement"] for row in reg.rows.values())
    for daemon in daemons:
        if "%s/%s/" % (HOST_DIR, daemon) in enforced_files or daemon in reg.not_daemon:
            continue
        owner = reg.daemon_owner.get(daemon)
        if owner is not None:
            if owner not in reg.rows:
                fails.append("%s: daemon-owner maps %s to %s, which is not a capability here"
                             % (TSV, daemon, owner))
            continue
        fails.append("%s/%s/ is a host-side daemon and %s gives it no capability, no "
                     "daemon-owner and no not-a-daemon-capability row"
                     % (HOST_DIR, daemon, TSV))

    return fails


FIXTURE_TSV = """network.enabled\ton\tsrc/androidd/sandbox/capabilities.py:CAPABILITIES\trun:x.sh

#not-a-capability
null

#not-a-daemon-capability
broker
"""


def selftest(root):
    """run check against fixture trees"""
    import shutil
    import tempfile

    cases = []
    work = tempfile.mkdtemp(prefix="capcov-")
    try:
        for rel in (MODULE, MOUNTS, NETBRIDGED):
            dst = os.path.join(work, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(os.path.join(root, rel), dst)
        os.makedirs(os.path.join(work, CHECKS), exist_ok=True)
        for rel, body in (("run-tests.py", "#!/usr/bin/env python3\n"), ("x.sh", "#!/bin/bash\n"),
                          ("checks.tsv", "x.sh\trun\t-\tx\t-\t-\n")):
            with open(os.path.join(work, CHECKS, rel), "w") as handle:
                handle.write(body)
        subprocess.run(["git", "init", "-q", work], check=True, env=GIT_CLEAN_ENV)
        subprocess.run(["git", "-C", work, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        os.makedirs(os.path.join(work, HOST_DIR, "broker"), exist_ok=True)
        test_tools_dir = os.path.join(work, TEST_TOOLS_DIR)
        os.makedirs(test_tools_dir, exist_ok=True)
        os.makedirs(os.path.dirname(os.path.join(work, TEST_CONTRACT)), exist_ok=True)
        with open(os.path.join(work, TEST_CONTRACT), "w") as handle:
            handle.write("real.sh\tcold-required\tna\t-\tno\t-\tnone\n"
                         "contract-only.sh\tcold-required\tna\t-\tno\t-\tnone\n"
                         "nomatch.sh\tcold-required\tna\t-\tno\t-\tnone\n")
        with open(os.path.join(test_tools_dir, "real.sh"), "w") as handle:
            handle.write("#!/bin/bash\n# test-boot-mode: shared\n# proves network.enabled unreachable when withheld\n")
        with open(os.path.join(test_tools_dir, "nomatch.sh"), "w") as handle:
            handle.write("#!/bin/bash\n# test-boot-mode: shared\n# proves an unrelated capability\n")

        def write_tsv(text):
            """write the fixture capability table"""
            os.makedirs(os.path.dirname(os.path.join(work, TSV)), exist_ok=True)
            with open(os.path.join(work, TSV), "w") as handle:
                handle.write(text)

        def run_expect(label, needle):
            """run the check and record whether a failure names the needle"""
            fails = check(work)
            hit = any(needle in f for f in fails)
            cases.append((label, hit, fails))

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "TODO"))
        run_expect("a TODO cell fails", "has TODO in proof")

        write_tsv(FIXTURE_TSV.replace(
            "src/androidd/sandbox/capabilities.py:CAPABILITIES", "var/nope.py:gone"))
        run_expect("an enforcement point that does not exist fails", "does not exist")

        write_tsv(FIXTURE_TSV.replace(
            "src/androidd/sandbox/capabilities.py:CAPABILITIES",
            "src/androidd/sandbox/capabilities.py:CAPABILITIES;src/androidd/sandbox/capabilities.py:CAPABILITIES"))
        fails = check(work)
        cases.append(("a two-point enforcement cell where both points resolve passes clean",
                      not any("network.enabled" in f for f in fails), fails))

        write_tsv(FIXTURE_TSV.replace(
            "src/androidd/sandbox/capabilities.py:CAPABILITIES",
            "src/androidd/sandbox/capabilities.py:CAPABILITIES;var/nope.py:gone"))
        run_expect("a two-point enforcement cell whose second point does not exist fails, "
                  "named by its own position",
                  "enforcement point 2/2")

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "run:never-registered-anywhere"))
        run_expect("a proof make test does not run fails", "does not run")

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "selftest:x.sh"))
        run_expect("a proof naming a registered check under the wrong kind fails", "does not run as a selftest")

        write_tsv(FIXTURE_TSV)
        subprocess.run(["git", "-C", work, "rm", "-q", "-f", os.path.join(CHECKS, "x.sh")], check=True, env=GIT_CLEAN_ENV)
        with open(os.path.join(work, CHECKS, "checks.tsv"), "w") as handle:
            handle.write("")
        run_expect("a runner that registers no check fails", "registers no check")
        with open(os.path.join(work, CHECKS, "x.sh"), "w") as handle:
            handle.write("#!/bin/bash\n")
        with open(os.path.join(work, CHECKS, "checks.tsv"), "w") as handle:
            handle.write("x.sh\trun\t-\tx\t-\t-\n")
        subprocess.run(["git", "-C", work, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        with open(os.path.join(work, CHECKS, "y.sh"), "w") as handle:
            handle.write("#!/bin/bash\n")
        subprocess.run(["git", "-C", work, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        run_expect("a registry the runner cannot read fails by name", "cannot read the runner's checks")
        subprocess.run(["git", "-C", work, "rm", "-q", "-f", os.path.join(CHECKS, "y.sh")], check=True, env=GIT_CLEAN_ENV)

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "test:real.sh"))
        fails = check(work)
        cases.append(("a test: proof naming a real registered system test whose source names "
                      "the capability passes clean",
                      not any("network.enabled" in f for f in fails), fails))

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "test:nomatch.sh"))
        run_expect("a test: proof naming a real, registered system test whose source never "
                  "mentions the capability fails by name",
                  "nomatch.sh's own source never mentions network.enabled")

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "test:contract-only.sh"))
        run_expect("a test: proof naming no system test under test/system fails by name",
                   "contract-only.sh', which is no system test under test/system")

        write_tsv(FIXTURE_TSV.replace("run:x.sh", "test:other.sh"))
        run_expect("a test: proof naming a system test with no contract.tsv row fails by name",
                   "other.sh', which has no row in contract.tsv")

        write_tsv(FIXTURE_TSV.replace("\nnull\n", "\n"))
        run_expect("losing an exclusion list fails", "lost an exclusion list")

        write_tsv("")
        run_expect("an empty registry fails", "declares no capabilities")

        os.makedirs(os.path.join(work, HOST_DIR, "audiod"), exist_ok=True)
        write_tsv(FIXTURE_TSV + "\n#daemon-owner\naudiod\taudio.gone\n")
        run_expect("a daemon-owner naming a dropped capability fails",
                   "which is not a capability here")

        write_tsv(FIXTURE_TSV)
        run_expect("a daemon with no row, owner or exclusion fails",
                   "no daemon-owner and no not-a-daemon-capability")

        def with_profile_row(default):
            """return the fixture table with an rhizo.profile row of a default"""
            row = "rhizo.profile\t%s\tsrc/androidd/sandbox/capabilities.py:read_policy\trun:x.sh\n" % default
            return FIXTURE_TSV.replace("\n#not-a-capability", "\n" + row + "\n#not-a-capability")

        write_tsv(with_profile_row("on"))
        run_expect("an enum capability given on/off instead of its real default fails",
                   "expected the literal default")

        write_tsv(with_profile_row("server"))
        run_expect("an enum capability given the wrong literal default fails",
                   "does not match the code's own default")

        write_tsv(with_profile_row("desktop"))
        fails = check(work)
        cases.append(("an enum capability given its real default parses clean",
                      not any("default=" in f for f in fails), fails))

        write_tsv(FIXTURE_TSV)
        fails = check(work)
        cases.append(("a registry missing a declared capability fails",
                      any("does not name it" in f for f in fails), fails))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    bad = 0
    for label, hit, fails in cases:
        print("SELFTEST %s: %s" % ("OK" if hit else "FAIL", label))
        if not hit:
            bad += 1
            for line in fails:
                print("    saw: %s" % line)
    return 1 if bad else 0


def main():
    """run the check or its selftest"""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
    args = sys.argv[1:]
    if "--root" in args:
        root = args[args.index("--root") + 1]
    if "--selftest" in args:
        return selftest(root)
    fails = check(root)
    for line in fails:
        print("FAIL: capability coverage: %s" % line)
    if not fails:
        print("capability coverage: %d capabilities, every one enforced and proven"
              % len([n for n in read_registry(root)[0].rows]))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
