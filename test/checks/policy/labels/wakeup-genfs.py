#!/usr/bin/env python3
"""check the policy build's mode and host wakeup inputs"""

import ast
import contextlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
LAUNCHER = os.path.join(REPO, "src", "androidd")
PREPARE = os.path.join(REPO, "src", "install", "prepare", "prepare.sh")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-wakeup-genfs")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_policy  # noqa: E402

PLAT_GENFS = ('(genfscon sysfs "/" (u object_r sysfs ((s0) (s0))))\n'
              '(genfscon sysfs "/class/wakeup" (u object_r sysfs_wakeup ((s0) (s0))))\n'
              '(genfscon sysfs "/devices/virtual/wakeup" (u object_r sysfs_wakeup ((s0) (s0))))\n')
RHIZO_GENFS = '(genfscon sysfs "/devices/pci0000:00" (u object_r rhizo_sysfs_pci ((s0) (s0))))\n'
SOURCES = (
    ("wakeup0", "devices/platform/PNP0C0A:00/wakeup/wakeup0"),
    ("wakeup1", "devices/platform/PNP0C0A:00/wakeup/wakeup1"),
    ("wakeup2", "devices/platform/ACPI0003:00/power_supply/AC/wakeup2"),
    ("wakeup3", "devices/pci0000:00/0000:00:14.0/wakeup/wakeup3"),
    ("wakeup4", "devices/virtual/wakeup/wakeup4"),
    ("wakeup5", "devices/pnp0/00:00/rtc/rtc0/alarmtimer.0.auto/wakeup/wakeup5"),
)
ODD = ("wakeup6", 'devices/platform/odd"name/wakeup/wakeup6')
MISNAMED = ("wakeup8", "devices/platform/PNP0C0E:00/power_supply/LID/notwakeup")
WANT = ('(genfscon sysfs "/devices/platform/ACPI0003:00/power_supply/AC/wakeup" (u object_r sysfs_wakeup ((s0) (s0))))\n'
        '(genfscon sysfs "/devices/platform/PNP0C0A:00/wakeup" (u object_r sysfs_wakeup ((s0) (s0))))\n'
        '(genfscon sysfs "/devices/pnp0/00:00/rtc/rtc0/alarmtimer.0.auto/wakeup" (u object_r sysfs_wakeup ((s0) (s0))))\n')
HIDRAW_RELABEL = "(allow rhizo_input_label rhizo_host_device (chr_file (getattr relabelfrom)))"
HIDRAW_PIN = "(validatetrans chr_file (or (not (eq t3 rhizo_input_label)) (eq t2 hidraw_device)))"


def fixture_sysfs(tmp, sources):
    """return a fixture sysfs's wakeup class dir"""
    class_dir = os.path.join(tmp, "sys", "class", "wakeup")
    os.makedirs(class_dir, exist_ok=True)
    for name, rel in sources:
        os.makedirs(os.path.join(tmp, "sys", rel), exist_ok=True)
        with open(os.path.join(tmp, "sys", rel, "name"), "w") as f:
            f.write(name + "\n")
        os.symlink(os.path.join("..", "..", rel), os.path.join(class_dir, name))
    return class_dir


def selftest():
    """check wakeup_genfscons on fixture sysfs trees"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-wakeup-genfs.")
    try:
        log = []
        got = selinux_policy.wakeup_genfscons([PLAT_GENFS, RHIZO_GENFS], fixture_sysfs(tmp, SOURCES), log.append)
        if got != WANT:
            fails.append("the fixture's genfscons:\n%s\nwanted:\n%s" % (got, WANT))
        if log:
            fails.append("a clean fixture logged %r" % log)
        got = selinux_policy.wakeup_genfscons([PLAT_GENFS], os.path.join(tmp, "sys", "class", "wakeup"), log.append)
        if '"/devices/pci0000:00/0000:00:14.0/wakeup"' not in got:
            fails.append("a PCI source the policy leaves plain sysfs was not labeled: %r" % got)
        renumbered = tempfile.mkdtemp(dir=tmp)
        got = selinux_policy.wakeup_genfscons([PLAT_GENFS, RHIZO_GENFS], fixture_sysfs(renumbered, [
            ("wakeup9", "devices/platform/ACPI0003:00/power_supply/AC/wakeup9")]), log.append)
        if '"/devices/platform/ACPI0003:00/power_supply/AC/wakeup"' not in got:
            fails.append("a renumbered power-supply source changed its genfscon: %r" % got)
        odd = tempfile.mkdtemp(dir=tmp)
        log = []
        got = selinux_policy.wakeup_genfscons([PLAT_GENFS, RHIZO_GENFS], fixture_sysfs(odd, SOURCES[:1] + (ODD, MISNAMED)),
                                            log.append)
        if "odd" in got or "LID" in got or '"/devices/platform/PNP0C0A:00/wakeup"' not in got:
            fails.append("an odd-named or misnamed source was rendered, or the good one dropped: %r" % got)
        for word in ("odd", "notwakeup"):
            if not any(word in m and "not labeled" in m for m in log):
                fails.append("the %s source drew no log line: %r" % (word, log))
        if selinux_policy.sysfs_label([("/devices/virtual/wakeup", "sysfs_wakeup"), ("/", "sysfs")],
                                    "/devices/virtual/wakeup/wakeup4/name") != "sysfs_wakeup":
            fails.append("a shorter genfscon listed after a longer one decided a source's label")
        log = []
        if selinux_policy.wakeup_genfscons([PLAT_GENFS], os.path.join(tmp, "no-such"), log.append) or log:
            fails.append("a missing class dir rendered or logged: %r" % log)
        not_dir = os.path.join(tmp, "not-a-dir")
        open(not_dir, "w").close()
        if selinux_policy.wakeup_genfscons([PLAT_GENFS], not_dir, log.append) or \
                not any("cannot list" in m for m in log):
            fails.append("an unreadable class dir drew no log line: %r" % log)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-wakeup-genfs selftest: ok (glue-dir, power-supply and alarmtimer sources labeled under a "
          "number-free prefix, PCI and virtual ones left to their labels, odd and misnamed sources logged, a missing "
          "class dir silent)")
    return 0


def purity_findings(tmp):
    """check selinux_policy reads nothing of the host and renders each mode"""
    bad = []
    imports = set()
    for n in ast.walk(ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_policy.py")).read())):
        if isinstance(n, ast.Import):
            imports |= {a.name for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            imports |= {n.module + "." + a.name for a in n.names} if n.module == "sandbox" else {n.module}
    if imports != {"os", "re", "sandbox.guest_files"}:
        bad.append("selinux_policy imports %s, not os, re and guest_files alone" % sorted(imports))
    plat = os.path.join(tmp, "plat.cil")
    with open(plat, "w") as f:
        f.write(PLAT_GENFS)
    saved = selinux_policy.WAKEUP_CLASS
    selinux_policy.WAKEUP_CLASS = fixture_sysfs(tmp, SOURCES)
    try:
        ns, host = selinux_policy.build([plat]), selinux_policy.build([plat], namespace=False, wakeup_genfs=WANT)
        live = selinux_policy.host_wakeup_genfs([plat], [].append)
    finally:
        selinux_policy.WAKEUP_CLASS = saved
    if "sysfs_wakeup ((s0)" in ns.replace('"/devices/virtual/wakeup"', ""):
        bad.append("build() with no wakeup_genfs read the host's wakeup sources")
    if HIDRAW_RELABEL not in ns or HIDRAW_PIN not in ns:
        bad.append("namespace mode's render lacks the label service's hidraw relabel or its validatetrans pin")
    if HIDRAW_RELABEL in host or HIDRAW_PIN in host or any(line in host for line in WANT.splitlines()):
        bad.append("host mode's render carries the hidraw relabel, its pin or wakeup genfscons")
    if live != WANT:
        bad.append("host_wakeup_genfs read %r from WAKEUP_CLASS, wanted %r" % (live, WANT))
    if "wakeup_genfs" in open(os.path.join(REPO, "test", "checks", "lib", "policy-lab.sh")).read():
        bad.append("policy-lab.sh passes wakeup genfscons")
    return bad


def launcher_findings(tmp):
    """run the launcher's compile and prepare-sepolicy on fixtures"""
    bad = []
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        import boot as launcher
    gsi, cache, out = (os.path.join(tmp, d) for d in ("gsi", "cache", "out"))
    for rel in ("etc/selinux/plat_sepolicy.cil",):
        os.makedirs(os.path.dirname(os.path.join(gsi, rel)), exist_ok=True)
        with open(os.path.join(gsi, rel), "w") as f:
            f.write(PLAT_GENFS)
    os.makedirs(out, exist_ok=True)
    sysfs = os.path.join(tmp, "host")
    class_dir = fixture_sysfs(sysfs, SOURCES)

    def secilc(binary, args=""):
        """return a command writing a fixture policy to secilc's -o path"""
        return "printf fixture > %s" % re.search(r"-o (\S+)", args).group(1)

    saved = (launcher.GSI, launcher.RHIZO_CACHE_DIR, launcher.gsi_bootstrap_cmd, os.geteuid,
             selinux_policy.WAKEUP_CLASS, os.environ.get("RHIZO_SELINUX_MODE"), launcher.SELINUXNS_RECORDS_DIR)
    launcher.GSI, launcher.RHIZO_CACHE_DIR, launcher.gsi_bootstrap_cmd = gsi, cache, secilc
    os.geteuid, selinux_policy.WAKEUP_CLASS = (lambda: 0), class_dir

    def verb(check_only):
        """run prepare-sepolicy and return its rc and printed lines"""
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(io.StringIO()):
            rc = launcher.prepare_sepolicy_verb(check_only)
        return rc, printed.getvalue().strip().splitlines()[-1]

    def compile_render():
        """return the launch compile's rendered fragment"""
        pc, rhizo_cil = os.path.join(out, "precompiled_sepolicy"), os.path.join(out, "rhizo_vendor_sepolicy.cil")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            launcher.compile_precompiled_sepolicy(pc, rhizo_cil)
        return open(rhizo_cil).read()

    try:
        os.environ["RHIZO_SELINUX_MODE"] = "namespace"
        rc, line = verb(False)
        record = open(launcher.prepared_wakeup_path()).read() if os.path.exists(launcher.prepared_wakeup_path()) else None
        if rc != 0 or not line.startswith("PREPARE_SEPOLICY_OK cache=") or record != WANT:
            bad.append(("namespace prepare-sepolicy", rc, line, record))
        rc, line = verb(True)
        if rc != 0 or not line.endswith(" hit=1"):
            bad.append(("namespace prepare-sepolicy --check after prepare", rc, line))
        rendered = compile_render()
        if any(l not in rendered for l in WANT.splitlines()) or HIDRAW_PIN not in rendered:
            bad.append("the launch compile lacks the host wakeup genfscons or the hidraw pin")
        fixture_sysfs(sysfs, [("wakeup7", "devices/platform/PNP0C0C:00/wakeup/wakeup7")])
        rc, line = verb(True)
        if rc != 0 or not line.endswith(" hit=1 wakeup=changed"):
            bad.append(("--check after a wakeup source appeared", rc, line))
        if '"/devices/platform/PNP0C0C:00/wakeup"' not in compile_render():
            bad.append("the launch compile after a wakeup source appeared lacks its genfscon")
        rc, line = verb(True)
        if rc != 0 or not line.endswith(" hit=1"):
            bad.append(("--check once the launch cached the new set", rc, line))
        os.unlink(launcher.prepared_wakeup_path())
        fixture_sysfs(sysfs, [("wakeup10", "devices/platform/PNP0C0D:00/wakeup/wakeup10")])
        rc, line = verb(True)
        if rc != 1 or not line.endswith(" hit=0"):
            bad.append(("--check with no cache for the live or a recorded set", rc, line))
        compile_fn = next(n for n in ast.parse(open(launcher.__file__).read()).body
                          if isinstance(n, ast.FunctionDef) and n.name == "compile_sepolicy")
        compile_text = ast.unparse(compile_fn)
        if ("compile_precompiled_sepolicy(pc, rhizo_cil, wakeup_genfs=wakeup_genfs)" not in compile_text
                or "record_launched_wakeup(wakeup_genfs)" not in compile_text):
            bad.append(("the launch records the wakeup set it compiles with", "record_launched_wakeup(wakeup_genfs)"))
        record = getattr(launcher, "record_launched_wakeup", None)
        if record is None:
            bad.append(("the launch's wakeup record", "record_launched_wakeup", "absent"))
        else:
            launcher.SELINUXNS_RECORDS_DIR = os.path.join(tmp, "records")
            cils = launcher._gsi_policy_cils()
            launched = launcher.policy_wakeup_genfs(cils)
            compile_render()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                record(launched)
                fixture_sysfs(sysfs, [("wakeup11", "devices/platform/PNP0C0E:00/wakeup/wakeup11")])
                launch_cache = launcher._sepolicy_cache_for(cils, os.path.join(out, "launched.cil"), launched)
                got = launcher.compiled_policy_path()
            if not launch_cache[1] or got != launch_cache[0]:
                bad.append(("in-android-policy after a hotplug", "the launch's cached policy", launch_cache, got))
            os.unlink(launcher.launched_wakeup_path())
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                got = launcher.compiled_policy_path()
            if got is not None:
                bad.append(("in-android-policy with no launch record and no cache for the live set", None, got))
        os.environ["RHIZO_SELINUX_MODE"] = "host"
        rc, line = verb(False)
        record = open(launcher.prepared_wakeup_path()).read()
        rendered = compile_render()
        if rc != 0 or record != "" or HIDRAW_PIN in rendered or "sysfs_wakeup ((s0)" in rendered:
            bad.append(("host mode's prepare and compile", rc, line, record))
    finally:
        (launcher.GSI, launcher.RHIZO_CACHE_DIR, launcher.gsi_bootstrap_cmd, os.geteuid,
         selinux_policy.WAKEUP_CLASS, mode, launcher.SELINUXNS_RECORDS_DIR) = saved
        if mode is None:
            os.environ.pop("RHIZO_SELINUX_MODE", None)
        else:
            os.environ["RHIZO_SELINUX_MODE"] = mode
    return bad


def shell_function(text, name):
    """return a shell function's definition out of a script"""
    m = re.search(r"^%s\(\) *\{[^\n]*\}\n" % re.escape(name), text, re.M)
    if m is None:
        m = re.search(r"^%s\(\) *\{ *(#[^\n]*)?\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
    return m.group(0) if m else None


PREPARE_FUNCTIONS = ("log", "failstop", "mark_change", "configured_selinux_mode", "verify_sepolicy", "prepare_sepolicy")
STUB_LAUNCHER = r'''import os, sys
with open(os.environ["STUB_LOG"], "a") as f:
    f.write("%s %s\n" % (os.environ.get("RHIZO_SELINUX_MODE", "<unset>"), " ".join(sys.argv[1:])))
print(os.environ["STUB_CHECK" if "--check" in sys.argv else "STUB_COMPILE"])
'''


def prepare_findings(tmp):
    """run prepare's sepolicy functions against stubs"""
    bad = []
    text = open(PREPARE).read()
    defs = [shell_function(text, n) for n in PREPARE_FUNCTIONS]
    if None in defs:
        return ["prepare.sh lacks %s" % [n for n, d in zip(PREPARE_FUNCTIONS, defs) if d is None]]
    for line in text.splitlines():
        if "launcher3.py\" prepare-sepolicy" in line and "RHIZO_SELINUX_MODE=\"$" not in line:
            bad.append("a prepare-sepolicy call runs without the configured mode: %s" % line.strip())
    payload = os.path.join(tmp, "payload")
    os.makedirs(payload)
    with open(os.path.join(payload, "launcher3.py"), "w") as f:
        f.write(STUB_LAUNCHER)
    helper = os.path.join(tmp, "mode-helper")
    cached = os.path.join(tmp, "precompiled_sepolicy.cached")
    with open(cached, "w") as f:
        f.write("cached")

    def run(body, mode="host", check="", compile_line=""):
        """run body after prepare's functions"""
        with open(helper, "w") as f:
            f.write("#!/bin/sh\n%s\n" % ("exit 1" if mode is None else "echo %s" % mode))
        os.chmod(helper, 0o755)
        stub_log = os.path.join(tmp, "stub.log")
        if os.path.exists(stub_log):
            os.unlink(stub_log)
        env = dict(os.environ, PAYLOAD=payload, PROG="prepare", RHIZO_SELINUX_MODE_HELPER=helper,
                   RESUME_FILE=os.path.join(tmp, "resume"),
                   RHIZO_ANDROIDD_ENV=os.path.join(tmp, "androidd.env"), STUB_LOG=stub_log, STUB_CHECK=check,
                   STUB_COMPILE=compile_line)
        env.pop("RHIZO_SELINUX_MODE", None)
        r = subprocess.run(["bash", "-c", "set -u\n" + "".join(defs) + body], env=env, capture_output=True,
                           text=True, timeout=60)
        calls = open(stub_log).read().splitlines() if os.path.exists(stub_log) else []
        return r.returncode, r.stdout + r.stderr, calls

    rc, out, calls = run("verify_sepolicy", check=f"PREPARE_SEPOLICY_CHECK cache={cached} hit=1")
    if rc != 0 or "current policy inputs is present" not in out or calls != ["host prepare-sepolicy --check"]:
        bad.append(("verify on a hit", rc, out, calls))
    rc, out, calls = run("verify_sepolicy", check=f"PREPARE_SEPOLICY_CHECK cache={cached} hit=1 wakeup=changed")
    if rc != 0 or "prepared policy inputs is present" not in out or "wakeup sources" not in out:
        bad.append(("verify after the host's wakeup sources changed", rc, out))
    rc, out, calls = run("verify_sepolicy", check=f"PREPARE_SEPOLICY_CHECK cache={tmp}/missing hit=0")
    if rc != 1:
        bad.append(("verify on a miss", rc, out))
    rc, out, calls = run("verify_sepolicy", mode=None, check=f"PREPARE_SEPOLICY_CHECK cache={cached} hit=1")
    if rc != 1 or calls:
        bad.append(("verify with an unreadable mode", rc, out, calls))
    rc, out, calls = run('prepare_sepolicy; echo "cache=$SEPOLICY_CACHE"', mode="namespace",
                         check=f"PREPARE_SEPOLICY_CHECK cache={cached} hit=1 wakeup=changed",
                         compile_line=f"PREPARE_SEPOLICY_OK cache={cached}")
    if rc != 0 or "compiled sepolicy cache" not in out or \
            calls != ["namespace prepare-sepolicy --check", "namespace prepare-sepolicy"]:
        bad.append(("prepare after the host's wakeup sources changed", rc, out, calls))
    rc, out, calls = run("prepare_sepolicy", mode=None)
    if rc == 0 or "RHIZO_PREPARE_FAILED reason=selinux-mode" not in out or calls:
        bad.append(("prepare with an unreadable mode", rc, out, calls))
    return bad


def run():
    """run the checks"""
    bad = []
    for name, fn in (("purity", purity_findings), ("launcher", launcher_findings), ("prepare", prepare_findings)):
        tmp = tempfile.mkdtemp(prefix="check-wakeup-genfs-%s." % name)
        try:
            bad += ["%s: %s" % (name, b) for b in fn(tmp)]
        except Exception as e:
            bad.append("%s raised %r" % (name, e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    for b in bad:
        print("FAIL: wakeup genfs: %s" % (b,))
    if bad:
        return 1
    print("ok: selinux_policy reads no host state; namespace mode's launch and prepare label the host's plain-sysfs "
          "wakeup sources and pin the label service's hidraw relabel, host mode renders neither; prepare passes the "
          "configured mode and its verify accepts the prepared cache after the wakeup sources change")
    return 0


def main():
    """run the selftest or the run checks"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    return run()


if __name__ == "__main__":
    sys.exit(main())
