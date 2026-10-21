#!/usr/bin/env python3
import ast
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
VAR_DIR = os.path.join(REPO, "var")
VM = os.environ.get("RHIZO_CHECK_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
ENV_PATH = os.path.join(REPO, "src", "androidd", "sandbox", "core.py")
MOUNTS_PATH = os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")
LAUNCHER_PATH = os.path.join(REPO, "src", "androidd", "boot.py")

MS_NOSUID, MS_NODEV, MS_NOEXEC = "MS_NOSUID", "MS_NODEV", "MS_NOEXEC"

MOUNT_SPECS = (
    ("NEWROOT root tmpfs",
     r'mount\(\s*"tmpfs"\s*,\s*NEWROOT\s*,\s*"tmpfs"\s*,\s*([^,]+),',
     {MS_NOSUID, MS_NODEV}, {MS_NOEXEC}),
    ("/dev tmpfs",
     r'mount\(\s*"tmpfs"\s*,\s*f"\{NEWROOT\}/dev"\s*,\s*"tmpfs"\s*,\s*([^,]+),',
     {MS_NOSUID, MS_NOEXEC}, {MS_NODEV}),
    ("/dev/shm tmpfs",
     r'mount\(\s*"tmpfs"\s*,\s*f"\{NEWROOT\}/dev/shm"\s*,\s*"tmpfs"\s*,\s*([^,]+),',
     {MS_NOSUID, MS_NODEV, MS_NOEXEC}, set()),
    ("/dev/input tmpfs",
     r'mount\(\s*"tmpfs"\s*,\s*f"\{NEWROOT\}/dev/input"\s*,\s*"tmpfs"\s*,\s*([^,]+),',
     {MS_NOSUID, MS_NOEXEC}, {MS_NODEV}),
    ("/proc/sys/net/core sysctl shadow",
     r'mount\(\s*"tmpfs"\s*,\s*"/proc/sys/net/core"\s*,\s*"tmpfs"\s*,\s*([^,]+),',
     {MS_NOSUID, MS_NODEV, MS_NOEXEC}, set()),
)


def check_mounts(mounts_text, launcher_text=""):
    """return the mount flag problems and whether any mount call was found"""
    fails = []
    found_any = False
    for label, pattern, required, forbidden in MOUNT_SPECS:
        m = re.search(pattern, mounts_text)
        if not m:
            fails.append(f"{label}: no mount() call matches")
            continue
        found_any = True
        flags_expr = m.group(1)
        tokens = {t.strip() for t in flags_expr.split("|")}
        missing = required - tokens
        extra = forbidden & tokens
        if missing:
            fails.append(f"{label}: missing {sorted(missing)} in flags "
                         f"{flags_expr!r}")
        if extra:
            fails.append(f"{label}: carries {sorted(extra)}, which is "
                         f"forbidden on this mount ({flags_expr!r})")
    return fails, found_any


def check_cgroups(env_text, mounts_text, launcher_text=""):
    """check the cgroup ceiling writes"""
    fails = []
    found_any = False
    if "RHIZO_MEM_MAX_BYTES" in env_text:
        found_any = True
        if "/proc/meminfo" not in env_text or "MemTotal" not in env_text:
            fails.append("RHIZO_MEM_MAX_BYTES is defined but does not read "
                         "/proc/meminfo's MemTotal")
        if 'os.environ.get("RHIZO_MEM_MAX_BYTES"' not in env_text:
            fails.append("RHIZO_MEM_MAX_BYTES is no longer overridable via "
                         "the RHIZO_MEM_MAX_BYTES environment variable")
    else:
        fails.append("RHIZO_MEM_MAX_BYTES no longer defined in sandbox/core.py")
    if "RHIZO_PIDS_MAX" in env_text:
        found_any = True
        if "threads-max" not in env_text:
            fails.append("RHIZO_PIDS_MAX is defined but does not read "
                         "/proc/sys/kernel/threads-max")
        if 'os.environ.get("RHIZO_PIDS_MAX"' not in env_text:
            fails.append("RHIZO_PIDS_MAX is no longer overridable via the "
                         "RHIZO_PIDS_MAX environment variable")
    else:
        fails.append("RHIZO_PIDS_MAX no longer defined in sandbox/core.py")

    fn_def = "def write_cgroup_ceilings(ceiling_root, mem_max, pids_max, cpu_max=None, log=kmsg):"
    fn_body = _window(launcher_text, fn_def, "\n\n\ndef ", max_len=2000)
    if not fn_body:
        fails.append("write_cgroup_ceilings() no longer defined (or restructured) in "
                     "launcher3.py")
    else:
        found_any = True
        if ("cgroup.controllers" not in fn_body or 'required = {"memory", "pids"}' not in fn_body
                or "missing = required - available" not in fn_body):
            fails.append("write_cgroup_ceilings() no longer checks cgroup.controllers "
                         "for memory/pids before writing")
        if 'cgroup_write(f"{ceiling_root}/{_cg_f}"' not in fn_body:
            fails.append("write_cgroup_ceilings() no longer writes memory.max/pids.max "
                         "on ceiling_root")
        if ('("memory.max", mem_max)' not in fn_body
                or '("pids.max", pids_max)' not in fn_body):
            fails.append("write_cgroup_ceilings() no longer caps both memory.max and "
                         "pids.max by name")
        if "ok = False" not in fn_body or fn_body.strip().splitlines()[-1].strip() != "return ok":
            fails.append("write_cgroup_ceilings() no longer returns False on a failed "
                         "write")
    call_site = _window(launcher_text, "ceiling_root = raw_unit_cgroup or cgroup_root",
                         "\n    if not install_device_cgroup_filter(", max_len=600)
    if not call_site:
        fails.append("launcher3.py no longer resolves ceiling_root as raw_unit_cgroup "
                     "or cgroup_root")
    else:
        found_any = True
        if "write_cgroup_ceilings(ceiling_root, _mem_max, RHIZO_PIDS_MAX" not in call_site:
            fails.append("launcher3.py no longer calls write_cgroup_ceilings() with "
                         "the policy-derived _mem_max/host-derived RHIZO_PIDS_MAX ceilings")
        if "if not write_cgroup_ceilings(" not in call_site or "os._exit(1)" not in call_site:
            fails.append("launcher3.py no longer aborts the boot when "
                         "write_cgroup_ceilings() fails")
        if '_ceiling_policy.scope("instance.memory_max") or RHIZO_MEM_MAX_BYTES' not in launcher_text:
            fails.append("launcher3.py no longer falls back to the host-derived "
                         "RHIZO_MEM_MAX_BYTES when the overlay sets no "
                         "instance.memory_max")
    if re.search(r'cgroup_write\(f"\{NEWROOT\}/sys/fs/cgroup/(memory|pids)\.max"',
                 mounts_text):
        fails.append("a ceiling write is back inside the sandbox's cgroup "
                     "namespace ({NEWROOT}/sys/fs/cgroup)")
    return fails, found_any


def _window(text, start_needle, end_needle, max_len=3000):
    """return the text between two needles"""
    i = text.find(start_needle)
    if i < 0:
        return ""
    j = text.find(end_needle, i)
    if j < 0:
        return ""
    return text[i:min(j, i + max_len)]


def check_devices(mounts_text):
    """return the device node problems and whether any device block was found"""
    fails = []
    found_any = False
    uinput = _window(mounts_text, 'st = os.stat("/dev/uinput")', '/dev/uinput {_op}: {e}')
    if not uinput:
        fails.append("uinput: could not isolate the /dev/uinput setup block")
    else:
        found_any = True
        if "0o660" not in uinput:
            fails.append("uinput: mknod/chmod no longer requests 0o660")
        if "0o666" in uinput:
            fails.append("uinput: still carries 0o666 somewhere in its own "
                         "setup block")
        if "os.chown(f\"{NEWROOT}/dev/uinput\", AID_UHID, AID_UHID)" not in uinput:
            fails.append("uinput: no longer chowned to uhid:uhid")

    dri = _window(mounts_text, 'dri_nodes = ("renderD128", "card0")', 'except OSError as e:\n            kmsg(f"/dev/dri/{n} mknod')
    if not dri:
        fails.append("dri: could not isolate the /dev/dri setup block")
    else:
        found_any = True
        if "0o666" not in dri:
            fails.append("dri: no longer 0o666")
    return fails, found_any


UHID_GRANTEES = {"bluetooth", "hal_bluetooth", "shell", "system_server", "virtual_touchpad",
                 "rhizo_composer", "rhizo_inputd"}
PLAT_CILS = os.path.join(VAR_DIR, "share", "policy-lab")
RHIZO_CIL = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")


def uhid_grantees(*cil_texts):
    """return the domains granted uhid_device"""
    out = set()
    for text in cil_texts:
        out |= set(re.findall(r"^\(allow (\S+) uhid_device \(chr_file ", text, re.M))
    return out


def check_uhid(plat_text, rhizo_text):
    """check the domains granted uhid_device"""
    got = uhid_grantees(plat_text, rhizo_text)
    if not got:
        return ["uhid: no uhid_device grant found"], False
    fails = []
    if got != UHID_GRANTEES:
        fails.append("uhid: the domains granted uhid_device are %s, not %s" % (sorted(got), sorted(UHID_GRANTEES)))
    return fails, True


def read_plat_cil():
    """return the newest compiled plat policy, or None"""
    import glob
    paths = sorted(glob.glob(os.path.join(PLAT_CILS, "cils-system-*", "plat_sepolicy.cil")))
    if not paths:
        return None
    return open(paths[-1]).read()


def check_caps(env_text):
    """return the dropped capability problems and whether DROP_CAPS was found"""
    fails = []
    found_any = False
    m = re.search(r'DROP_CAPS\s*=\s*\[([^\]]*)\]', env_text)
    if not m:
        return ["DROP_CAPS assignment not found in sandbox/core.py"], False
    found_any = True
    try:
        caps = ast.literal_eval(f"[{m.group(1)}]")
    except (ValueError, SyntaxError) as e:
        return [f"DROP_CAPS does not parse as a literal list of ints: {e}"], True
    if 32 not in caps:
        fails.append("DROP_CAPS no longer drops MAC_OVERRIDE(32)")
    if 33 in caps:
        fails.append("DROP_CAPS drops MAC_ADMIN(33)")
    if 27 in caps:
        fails.append("DROP_CAPS drops MKNOD(27)")
    return fails, found_any


CHECKS = {
    "mounts": lambda env_text, mounts_text, launcher_text: check_mounts(mounts_text),
    "cgroups": lambda env_text, mounts_text, launcher_text: check_cgroups(env_text, mounts_text, launcher_text),
    "devices": lambda env_text, mounts_text, launcher_text: check_devices(mounts_text),
    "caps": lambda env_text, mounts_text, launcher_text: check_caps(env_text),
}


def run_checks(env_path=ENV_PATH, mounts_path=MOUNTS_PATH, only=None,
               launcher_path=LAUNCHER_PATH):
    """run each named check over the sources"""
    try:
        env_text = open(env_path).read()
        mounts_text = open(mounts_path).read()
    except OSError as e:
        return [f"cannot read source: {e}"], False
    try:
        launcher_text = open(launcher_path).read()
    except OSError:
        launcher_text = ""
    fails = []
    examined = False
    for name, fn in CHECKS.items():
        if only and name != only:
            continue
        f, found = fn(env_text, mounts_text, launcher_text)
        fails += f
        examined = examined or found
    return fails, examined


def main():
    """run the checks, or the selftest, and print the result"""
    argv = sys.argv[1:]
    if "--selftest" in argv:
        return selftest()
    only = None
    if "--only" in argv:
        only = argv[argv.index("--only") + 1]
    fails, examined = run_checks(only=only)
    if only in (None, "uhid"):
        plat = read_plat_cil()
        if plat is None:
            fails.append("uhid: no plat_sepolicy.cil under %s -- run test/checks/lib/policy-lab.sh compile" % PLAT_CILS)
        else:
            f, found = check_uhid(plat, open(RHIZO_CIL).read())
            fails += f
            examined = examined or found
    if not examined:
        print("check-sandbox-interior: none of the mount/cgroup/device/cap "
              "patterns this check looks for were found", file=sys.stderr)
        return 1
    for f in fails:
        print(f"FAIL: {f}", file=sys.stderr)
    if fails:
        return 1
    print("check-sandbox-interior: mount flags, cgroup ceilings, device "
          "modes and the capability bounding set all match the policy")
    return 0


MUTATIONS = (
    ("mounts", 'mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755")',
     'mount("tmpfs",NEWROOT,"tmpfs",0,"mode=0755")'),
    ("mounts", 'mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755")',
     'mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC|MS_NODEV,"mode=0755")'),
    ("mounts", 'mount("tmpfs",f"{NEWROOT}/dev/shm","tmpfs",MS_NOSUID|MS_NODEV|MS_NOEXEC,"mode=1777")',
     'mount("tmpfs",f"{NEWROOT}/dev/shm","tmpfs",0,"mode=1777")'),
    ("mounts", 'mount("tmpfs", f"{NEWROOT}/dev/input", "tmpfs", MS_NOSUID|MS_NOEXEC, "mode=02755,uid=0,gid=1004")',
     'mount("tmpfs", f"{NEWROOT}/dev/input", "tmpfs", MS_NOSUID|MS_NOEXEC|MS_NODEV, "mode=02755,uid=0,gid=1004")'),
    ("mounts", 'mount("tmpfs", "/proc/sys/net/core", "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755")',
     'mount("tmpfs", "/proc/sys/net/core", "tmpfs", 0, "mode=0755")'),
    ("env", "RHIZO_MEM_MAX_BYTES = int(os.environ.get(\"RHIZO_MEM_MAX_BYTES\", str(_MEM_MAX_DEFAULT)))",
     "RHIZO_MEM_MAX_BYTES = 2147483648"),
    ("env", "RHIZO_PIDS_MAX = int(os.environ.get(\"RHIZO_PIDS_MAX\", str(_PIDS_MAX_DEFAULT)))",
     "RHIZO_PIDS_MAX = 4096"),
    ("launcher", 'ceilings = [("memory.max", mem_max), ("pids.max", pids_max)]',
     'ceilings = [("nope.max", mem_max), ("pids.max", pids_max)]'),
    ("launcher", 'cgroup_write(f"{ceiling_root}/{_cg_f}", str(_cg_v))',
     'pass  # ceiling write removed'),
    ("launcher", 'missing = required - available',
     'missing = set()  # availability check removed'),
    ("launcher", '            ok = False\n    return ok',
     '            pass  # regression: warn and continue\n    return True'),
    ("launcher", '    if not write_cgroup_ceilings(ceiling_root, _mem_max, RHIZO_PIDS_MAX,\n'
                 '                                  cpu_max=_cpu_max, log=kmsg):\n'
                 '        kmsg(f"FATAL: cgroup ceilings not in force on {ceiling_root} -- refusing to run the sandbox uncapped")\n'
                 '        os._exit(1)',
     '    write_cgroup_ceilings(ceiling_root, _mem_max, RHIZO_PIDS_MAX,\n'
     '                                  cpu_max=_cpu_max, log=kmsg)  # regression: return value ignored'),
    ("launcher", 'ceiling_root = raw_unit_cgroup or cgroup_root',
     'ceiling_root = cgroup_root  # regression: always "android", ENOENTs under a unit'),
    ("launcher", '_ceiling_policy.scope("instance.memory_max") or RHIZO_MEM_MAX_BYTES',
     'RHIZO_MEM_MAX_BYTES  # regression: overlay ignored'),
    ("mounts", 'os.mknod(f"{NEWROOT}/dev/uinput", _stdri.S_IFCHR | 0o660,',
     'os.mknod(f"{NEWROOT}/dev/uinput", _stdri.S_IFCHR | 0o666,'),
    ("mounts", 'os.chown(f"{NEWROOT}/dev/uinput", AID_UHID, AID_UHID)',
     'pass  # chown removed'),
    ("mounts", ('os.mknod(f"{NEWROOT}/dev/dri/{n}", _stdri.S_IFCHR | 0o666, os.makedev(major, minor))\n',
                'os.chmod(f"{NEWROOT}/dev/dri/{n}", 0o666)'),
     ('os.mknod(f"{NEWROOT}/dev/dri/{n}", _stdri.S_IFCHR | 0o644, os.makedev(major, minor))\n',
      'os.chmod(f"{NEWROOT}/dev/dri/{n}", 0o644)')),
    ("env", "DROP_CAPS=[16,17,25,20,31,22,32]",
     "DROP_CAPS=[16,17,25,20,31,22]"),
    ("env", "DROP_CAPS=[16,17,25,20,31,22,32]",
     "DROP_CAPS=[16,17,25,20,31,22,32,33]"),
    ("env", "DROP_CAPS=[16,17,25,20,31,22,32]",
     "DROP_CAPS=[16,17,25,20,31,22,32,27]"),
)


def selftest():
    """run the checks on mutated sources"""
    bad = []
    if run_checks()[0]:
        bad.append("the check fails on the CURRENT (fixed) source: %r" % run_checks()[0])
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "sandbox"))
        env_copy, mounts_copy = os.path.join(tmp, "sandbox/core.py"), os.path.join(tmp, "sandbox/rootfs.py")
        launcher_copy = os.path.join(tmp, "launcher3.py")
        for where, needles, replacements in MUTATIONS:
            shutil.copy(ENV_PATH, env_copy)
            shutil.copy(MOUNTS_PATH, mounts_copy)
            shutil.copy(LAUNCHER_PATH, launcher_copy)
            target = {"env": env_copy, "mounts": mounts_copy,
                      "launcher": launcher_copy}[where]
            text = open(target).read()
            if isinstance(needles, str):
                needles, replacements = (needles,), (replacements,)
            missing = [n for n in needles if n not in text]
            if missing:
                bad.append("selftest fixture: needle not found in %s: %r" % (where, missing[0][:60]))
                continue
            for needle, replacement in zip(needles, replacements):
                text = text.replace(needle, replacement, 1)
            open(target, "w").write(text)
            fails, examined = run_checks(env_path=env_copy, mounts_path=mounts_copy,
                                         launcher_path=launcher_copy)
            if not fails:
                bad.append("mutating %r in %s did not fail the check" % (needles[0][:60], where))
        empty = os.path.join(tmp, "empty")
        os.makedirs(os.path.join(empty, "sandbox"), exist_ok=True)
        open(os.path.join(empty, "sandbox/core.py"), "w").write("")
        open(os.path.join(empty, "sandbox/rootfs.py"), "w").write("")
        open(os.path.join(empty, "launcher3.py"), "w").write("")
        fails, examined = run_checks(env_path=os.path.join(empty, "sandbox/core.py"),
                                      mounts_path=os.path.join(empty, "sandbox/rootfs.py"),
                                      launcher_path=os.path.join(empty, "launcher3.py"))
        if examined:
            bad.append("an empty source tree was reported as examined")
    plat_fx = ("(allow shell uhid_device (chr_file (ioctl read write open)))\n"
               "(allow system_server uhid_device (chr_file (read write open)))\n"
               "(allow bluetooth uhid_device (chr_file (read write open)))\n"
               "(allow hal_bluetooth uhid_device (chr_file (read write open)))\n"
               "(allow virtual_touchpad uhid_device (chr_file (write open)))\n")
    rhizo_fx = ("(allow rhizo_composer uhid_device (chr_file (read write open)))\n"
                "(allow rhizo_inputd uhid_device (chr_file (read write ioctl)))\n")
    if check_uhid(plat_fx, rhizo_fx)[0]:
        bad.append("uhid: the expected grantees were flagged: %r" % check_uhid(plat_fx, rhizo_fx)[0])
    if not check_uhid(plat_fx + "(allow untrusted_app uhid_device (chr_file (open)))\n", rhizo_fx)[0]:
        bad.append("uhid: a new grantee (untrusted_app) was not flagged")
    if not check_uhid(rhizo_fx, "")[0]:
        bad.append("uhid: the composer alone was not flagged")
    if check_uhid("", "")[1]:
        bad.append("uhid: no grant at all was reported as examined")
    if bad:
        for b in bad:
            print("check-sandbox-interior --selftest: %s" % b, file=sys.stderr)
        return 1
    print("check-sandbox-interior: selftest ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
