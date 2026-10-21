#!/usr/bin/env python3
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SCRIPT = os.path.join(ROOT, "test", "vm", "rhizo-kernel-vm.sh")


def print_argv(distro):
    """run the driver's start verb in print-argv mode"""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.environ.get("HOME", "/tmp"),
           "RHIZO_KERNEL_VM_PRINT_ARGV": "1", "RHIZO_VM": "2", "RHIZO_KERNEL_VM_RENDER_NODE": "/dev/dri/renderD128"}
    p = subprocess.run(["bash", SCRIPT, distro, "start"], env=env, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout.splitlines(), p.stderr


def main():
    """print each failed expectation and exit 1 on any"""
    failures = []
    for distro in ("cachyos", "ubuntu"):
        rc, argv, err = print_argv(distro)
        if rc != 0:
            failures.append("%s: print-argv exited %d: %s" % (distro, rc, err.strip()))
            continue
        want = "local,path=%s/var/share,mount_tag=share9p,security_model=none" % ROOT
        if not any(argv[i] == "-virtfs" and argv[i + 1] == want for i in range(len(argv) - 1)):
            failures.append("%s: argv has no '-virtfs %s'" % (distro, want))
        if not any(argv[i] == "-device" and argv[i + 1] == "virtio-gpu-gl-pci" for i in range(len(argv) - 1)):
            failures.append("%s: argv has no '-device virtio-gpu-gl-pci'" % distro)
        if not any(argv[i] == "-display" and argv[i + 1].startswith("egl-headless,rendernode=")
                   for i in range(len(argv) - 1)):
            failures.append("%s: argv has no '-display egl-headless,rendernode=...'" % distro)
    for f in failures:
        print("FAIL: " + f)
    if failures:
        return 1
    print("rhizo-kernel-vm-argv: both guests get -virtfs var/share with mount_tag=share9p and egl-headless with virtio-gpu-gl-pci")
    return 0


if __name__ == "__main__":
    sys.exit(main())
