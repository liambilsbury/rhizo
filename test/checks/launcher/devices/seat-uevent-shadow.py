#!/usr/bin/env python3
import contextlib
import io
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
MOUNTS = os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")

os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-seat-uevent-shadow")
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs  # noqa: E402
    from sandbox.core import MS_BIND, MS_REMOUNT, MS_RDONLY  # noqa: E402


def _fixture(root):
    """build a fixture sysfs tree"""
    pci = "devices/pci0000:00/0000:00:02.0"
    for dev in ("drm/card0", "drm/card0-Virtual-1", "drm/renderD128", "graphics/fb0"):
        os.makedirs(f"{root}/sys/{pci}/{dev}")
        with open(f"{root}/sys/{pci}/{dev}/uevent", "w") as f:
            f.write("MAJOR=226\n")
    for cls, name in (("drm", "card0"), ("drm", "card0-Virtual-1"), ("drm", "renderD128"),
                      ("graphics", "fb0")):
        os.makedirs(f"{root}/sys/class/{cls}", exist_ok=True)
        os.symlink(f"../../{pci}/{cls}/{name}", f"{root}/sys/class/{cls}/{name}")
    with open(f"{root}/sys/class/drm/version", "w") as f:
        f.write("drm 1.1.0 20060810\n")
    return f"{root}/sys/{pci}"


def check_function(fail_on=None):
    """return findings for shadow_host_seat_uevents()"""
    bad = []
    with tempfile.TemporaryDirectory() as root:
        pci = _fixture(root)
        calls = []

        def mount_fn(src, dst, fstype, flags, data=None):
            """record a mount call and return whether it succeeded"""
            calls.append((src, dst, flags))
            return not (fail_on and dst == f"{pci}/drm/{fail_on}/uevent" and src is not None)

        logs = []
        ok, shadowed, failed = rootfs.shadow_host_seat_uevents(
            root, log=logs.append, mount_fn=mount_fn)
        for dev in ("drm/card0", "drm/card0-Virtual-1", "drm/renderD128", "graphics/fb0"):
            ue = f"{pci}/{dev}/uevent"
            if dev.split("/")[1] == fail_on:
                continue
            want = [(ue, ue, MS_BIND), (None, ue, MS_BIND | MS_REMOUNT | MS_RDONLY)]
            got = [c for c in calls if c[1] == ue]
            if got != want:
                bad.append(f"{dev}: mounts {got}, want a bind over itself then a read-only remount")
        if any("version" in (c[1] or "") for c in calls):
            bad.append("drm's plain `version` file was mounted over")
        if fail_on:
            if ok or failed != [fail_on]:
                bad.append(f"a refused bind on {fail_on}: ok={ok} failed={failed}, want it named and ok False")
            if not any(fail_on in line for line in logs):
                bad.append(f"a refused bind on {fail_on} is not in the log: {logs}")
        elif not ok or sorted(shadowed) != ["card0", "card0-Virtual-1", "fb0", "renderD128"]:
            bad.append(f"ok={ok} shadowed={shadowed} failed={failed}, want all four shadowed")
    return bad


def check_call_site(src):
    """check the call order of shadow_host_seat_uevents()"""
    m_sys = re.search(r'mount\("sysfs",f"\{NEWROOT\}/sys","sysfs",0\)', src)
    m_call = re.search(r"^\s+(?:\w+\s*=\s*)?shadow_host_seat_uevents\(NEWROOT\b", src, re.M)
    m_pivot = re.search(r"if not pivot_root\(NEWROOT,", src)
    if not m_call:
        return ["sandbox/rootfs.py never calls shadow_host_seat_uevents(NEWROOT...)"]
    if not m_sys or not m_pivot or not (m_sys.start() < m_call.start() < m_pivot.start()):
        return ["shadow_host_seat_uevents(NEWROOT...) is not between the sandbox's sysfs mount and pivot_root"]
    return []


def run():
    """run the function and call site checks and print the failures"""
    with open(MOUNTS) as f:
        src = f.read()
    bad = check_function() + check_function(fail_on="card0") + check_call_site(src)
    for b in bad:
        print(f"FAIL: {b}")
    return 1 if bad else 0


def selftest():
    """check the real source and each planted-defect copy of it"""
    bad = []
    with open(MOUNTS) as f:
        src = f.read()
    if check_call_site(src):
        bad.append(f"the real source fails the call-site check: {check_call_site(src)}")
    cut = re.sub(r"^\s+(?:\w+\s*=\s*)?shadow_host_seat_uevents\(NEWROOT.*$", "", src, flags=re.M)
    if not check_call_site(cut):
        bad.append("a source with the call removed passes the call-site check")
    moved = cut.replace("if not pivot_root(NEWROOT,",
                        "if not pivot_root(NEWROOT,", 1) + "\n    shadow_host_seat_uevents(NEWROOT)\n"
    if not check_call_site(moved):
        bad.append("a call placed after pivot_root passes the call-site check")
    real = rootfs.shadow_host_seat_uevents

    def no_remount(newroot, log=print, mount_fn=None):
        """call the real shadow function with a fake mount"""
        return real(newroot, log=log, mount_fn=lambda s, d, t, fl, data=None: fl == MS_BIND)
    rootfs.shadow_host_seat_uevents = no_remount
    try:
        if not check_function():
            bad.append("a shadow whose read-only remount fails passes the function check")
    finally:
        rootfs.shadow_host_seat_uevents = real
    if check_function() or check_function(fail_on="card0"):
        bad.append(f"the real function fails its own check: {check_function() + check_function(fail_on='card0')}")
    for b in bad:
        print(f"SELFTEST FAIL: {b}")
    if not bad:
        print("check-seat-uevent-shadow --selftest: the call-site and function checks catch each mutation")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else run())
