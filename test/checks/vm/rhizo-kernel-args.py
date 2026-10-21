#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def make_tree(top):
    """copy run-vm.sh and its libraries into a fixture tree"""
    os.makedirs(os.path.join(top, "test", "vm", "guest-os"))
    os.makedirs(os.path.join(top, "test", "vm", "rig"))
    os.makedirs(os.path.join(top, "var", "share"))
    os.makedirs(os.path.join(top, "var", "cachyos-dl"))
    with open(os.path.join(top, "var", "cachyos-dl", "cachyos-dev.root-uuid"), "w") as f:
        f.write("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0\n")
    shutil.copy(os.path.join(ROOT, "test", "vm", "run-vm.sh"), os.path.join(top, "test", "vm"))
    shutil.copy(os.path.join(ROOT, "test", "vm", "rig", "hooks.sh"), os.path.join(top, "test", "vm", "rig"))
    shutil.copy(os.path.join(ROOT, "test", "vm", "guest-os", "guest-os-lib.sh"),
                os.path.join(top, "test", "vm", "guest-os"))
    return os.path.join(top, "test", "vm", "run-vm.sh")


def print_argv(script, guest_os, kernel):
    """run run-vm.sh for vm 2 in print-argv mode"""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"),
           "RHIZO_PRINT_ARGV": "1", "RHIZO_VM": "2", "RHIZO_GUEST_OS": guest_os, "RHIZO_BOOT": "direct",
           "RHIZO_VM_GPU": "off"}
    if kernel is not None:
        env["RHIZO_KERNEL"] = kernel
    p = subprocess.run(["bash", script], env=env, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout.splitlines(), p.stderr


def after(argv, flag):
    """return the argument that follows flag in argv, or none"""
    return argv[argv.index(flag) + 1] if flag in argv[:-1] else "none"


def main():
    """print each failed expectation and exit 1 on any"""
    failures = []
    top = tempfile.mkdtemp(prefix="rhizo-kernel-args.")
    try:
        script = make_tree(top)
        var = os.path.realpath(os.path.join(top, "var"))
        boots = (("ubuntu", None, var + "/vm-2.rhizo-kernel/vmlinuz", var + "/vm-2.rhizo-kernel/initrd.img"),
                 ("ubuntu", "distro", "vmlinuz", "initrd.img"),
                 ("cachyos", None, var + "/vm-cachyos-2.rhizo-kernel/vmlinuz",
                  var + "/vm-cachyos-2.rhizo-kernel/initrd.img"),
                 ("cachyos", "distro", "share/vmlinuz-linux-cachyos", "share/initramfs-linux-cachyos.img"))
        for guest_os, kernel, want_kernel, want_initrd in boots:
            name = "%s RHIZO_KERNEL=%s" % (guest_os, kernel or "<unset>")
            rc, argv, err = print_argv(script, guest_os, kernel)
            if rc != 0:
                failures.append("%s: run-vm.sh exited %d: %s" % (name, rc, err.strip()))
            if after(argv, "-kernel") != want_kernel:
                failures.append("%s: -kernel is %s, not %s" % (name, after(argv, "-kernel"), want_kernel))
            if after(argv, "-initrd") != want_initrd:
                failures.append("%s: -initrd is %s, not %s" % (name, after(argv, "-initrd"), want_initrd))
        refusals = (("ubuntu", "rhizo-selinuxns", "RHIZO_KERNEL=rhizo-selinuxns is retired"),
                    ("ubuntu", "stock", "RHIZO_KERNEL=stock names no kernel"),
                    ("cachyos", "mainline", "RHIZO_KERNEL=mainline names no cachyos vm kernel"))
        for guest_os, kernel, want in refusals:
            rc, argv, err = print_argv(script, guest_os, kernel)
            if rc == 0:
                failures.append("%s: run-vm.sh accepted RHIZO_KERNEL=%s" % (guest_os, kernel))
            if want not in err:
                failures.append("%s: RHIZO_KERNEL=%s is not refused by name (got: %s)" % (guest_os, kernel, err.strip()))
    finally:
        shutil.rmtree(top, ignore_errors=True)
    for f in failures:
        print("FAIL: " + f)
    if failures:
        return 1
    print("rhizo-kernel-args: an unset RHIZO_KERNEL boots the Rhizo kernel beside the vm's disk on ubuntu and cachyos, "
          "distro boots the guest's own, and rhizo-selinuxns, an unknown name and mainline on cachyos are refused by name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
