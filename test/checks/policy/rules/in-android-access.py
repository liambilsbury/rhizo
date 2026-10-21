#!/usr/bin/env python3
"""check the compiled policy against the in-Android access rows"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_host_tty_policy", os.path.join(HERE, "host-tty-policy.py"))
tty = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(tty)

GRANTED = (
    ("rhizo_audio_core", "audioserver", "fifo_file", "write",
     "audioserver passes an AIDL v3 stream's dump() the write end of its own pipe (StreamHalAidl::dumpImpl)"),
    ("rhizo_audio_core", "rhizo_audio_core_tmpfs", "file", "read write getattr map ioctl",
     "libcutils' memfd probe ftruncates and ioctls the test_android_memfd the HAL creates"),
    ("rhizo_audio_effect", "rhizo_audio_effect_tmpfs", "file", "read write getattr map ioctl",
     "libcutils' memfd probe ftruncates and ioctls the test_android_memfd the effect HAL creates for its FMQs"),
    ("system_suspend", "rhizo_sysfs_pci", "dir", "search read open getattr",
     "system_suspend opens each /sys/class/wakeup entry, and a PCI device's wakeup source carries Rhizo's "
     "genfs label"),
    ("system_suspend", "rhizo_sysfs_pci", "file", "read open getattr",
     "system_suspend reads each wakeup source's stat files for the kernel wakelock stats"),
    ("rhizo_gralloc_allocator", "rhizo_sysfs_pci", "dir", "search read open getattr",
     "Mesa's loader in the allocator reads the render node's PCI ids through sysfs"),
    ("rhizo_gralloc_allocator", "rhizo_sysfs_pci", "file", "read open getattr",
     "Mesa's loader in the allocator reads the render node's PCI ids through sysfs"),
    ("rhizo_gralloc_allocator", "rhizo_sysfs_pci", "lnk_file", "read getattr",
     "Mesa's loader in the allocator resolves the render node's device link through sysfs"),
    ("kernel", "kernel", "process", "setcurrent",
     "the input label service, forked by the kernel-domain relabeller, leaves kernel by setcon before it serves, so "
     "no userspace kernel-domain task outlives boot (CTS testKernelDomain)"),
    ("kernel", "rhizo_input_label", "process", "dyntransition",
     "that setcon enters the input label service's own domain"),
    ("rhizo_input_label", "kernel", "unix_stream_socket", "read write",
     "the service reads and writes the socket the relabeller connected while still kernel"),
    ("rhizo_input_label", "input_device", "chr_file", "getattr",
     "the service stats an evdev node and reads its label back"),
    ("rhizo_composer", "input_device", "chr_file", "getattr",
     "the composer's PublishNode lstat()s each /dev/input/eventN it made through uinput and matches the node's "
     "device number to sysfs's (uinput.cpp)"),
    ("rhizo_input_label", "rhizo_host_device", "chr_file", "getattr relabelfrom",
     "in namespace mode the input label service stats and relabels a /dev/hidrawN the host fence made, born "
     "rhizo_host_device by the name-less typetransition kernel device chr_file; the grant reaches every node the "
     "host makes in /dev that way, bounded by the pin to hidraw_device and the service's /dev/hidrawN path and "
     "dev/inode check"),
    ("rhizo_input_label", "hidraw_device", "chr_file", "getattr relabelto",
     "the input label service sets hidraw_device on that node from inside Android's namespace and reads it back"),
    ("kernel", "rhizo_ns_stage", "process", "dyntransition",
     "stage-gsi-labeled leaves kernel by setcon into its own domain right after its policy load"),
    ("kernel", "rhizo_ns_relabel", "process", "dyntransition",
     "the relabeller, its primer, the vendor prelabel, prepare-tree and the data template leave kernel by setcon"),
    ("kernel", "rhizo_ns_label", "process", "dyntransition",
     "the label, label-fd and hostfs-label-lower verbs leave kernel by setcon"),
    ("rhizo_ns_relabel", "rootfs", "lnk_file", "relabelto",
     "the relabeller sets the root symlinks' labels"),
    ("rhizo_ns_relabel", "tun_device", "chr_file", "relabelto",
     "rhizo_relabel_dest_dev reaches the relabeller, which labels /dev/tun"),
    ("rhizo_ns_relabel", "system_file", "file", "relabelto",
     "rhizo_relabel_dest_file reaches the relabeller, which labels the flat trees' files"),
    ("rhizo_ns_relabel", "device", "dir", "relabelfrom",
     "the relabeller relabels the root of /dev, which is device after the first start"),
    ("rhizo_ns_stage", "system_file", "file", "create write setattr getattr open read",
     "cp -a writes every file of the GSI copy with the label the image carries"),
    ("rhizo_ns_stage", "vendor_file", "file", "create write setattr getattr open read",
     "cp -a writes the vendor files of the GSI copy"),
)
REFUSED = (
    ("shell", "system_file", "file", "entrypoint",
     "AOSP's domain.te neverallows entrypoint on a type outside exec_type; the shell-domain services exec "
     "/system/bin/sh"),
    ("rhizo_gralloc_allocator", "default_prop", "file", "read open",
     "AOSP's property.te neverallows a vendor domain reading default_prop"),
    ("rhizo_composer", "rhizo_composer", "capability", "sys_admin",
     "the composer's CAP_SYS_ADMIN caller is unidentified and the capability is withheld because no Rhizo code "
     "needs it"),
    ("rhizo_audio_core", "tmpfs", "file", "write",
     "the HAL's memfds are labeled rhizo_audio_core_tmpfs"),
    ("rhizo_composer", "rhizo_composer", "capability", "dac_override",
     "AOSP's domain.te neverallows dac_override outside a fixed domain list, and the composer's rc asks for none"),
    ("rhizo_composer", "rhizo_composer", "capability", "mknod",
     "AOSP's domain.te neverallows mknod outside init, kernel, ueventd and vold; the host fence makes /dev/input"),
    ("kernel", "device", "chr_file", "relabelfrom",
     "the hidraw relabel belongs to the input label service's domain, and kernel holds no namespace-only relabel"),
    ("rhizo_input_label", "device", "chr_file", "relabelfrom",
     "no node the fence makes in namespace mode is born device, so the service relabels none"),
    ("rhizo_ns_relabel", "rhizo_input_label", "process", "dyntransition",
     "AOSP's domain.te neverallows a type outside domain a transition to a domain type, so the label service is "
     "forked before the relabeller leaves kernel"),
    ("rhizo_ns_stage", "rhizo_ns_stage", "capability", "dac_read_search",
     "AOSP's domain.te neverallows dac_read_search outside a fixed domain list"),
    ("rhizo_ns_relabel", "rhizo_ns_relabel", "capability", "dac_read_search",
     "AOSP's domain.te neverallows dac_read_search outside a fixed domain list"),
    ("rhizo_ns_label", "rhizo_ns_label", "capability", "dac_read_search",
     "AOSP's domain.te neverallows dac_read_search outside a fixed domain list"),
    ("rhizo_ns_relabel", "device", "chr_file", "relabelfrom",
     "the hidraw relabel belongs to the input label service's domain, and the relabeller holds no device relabelfrom"),
)
TRANSITIONS = (
    ("rhizo_audio_core", "tmpfs", "file", "rhizo_audio_core_tmpfs",
     "the memfds the audio HAL creates, test_android_memfd among them"),
    ("rhizo_audio_effect", "tmpfs", "file", "rhizo_audio_effect_tmpfs",
     "the memfds the audio effect HAL creates, test_android_memfd among them"),
)
DONTAUDITED = (
    ("rhizo_gralloc_allocator", "default_prop", "file", "read",
     "Mesa's os_get_android_option looks up an unset mesa.* name after debug.mesa.* and vendor.mesa.*, and "
     "the denied read is that lookup's unset answer"),
    ("rhizo_ns_relabel", "kernel", "security", "setenforce",
     "the relabeller's enforcing flip is a setenforce check that AOSP's domain.te neverallows for every domain, "
     "so the denial is left unlogged"),
    ("rhizo_ns_relabel", "rhizo_ns_relabel", "capability", "dac_read_search",
     "AOSP's domain.te neverallows the grant to the relabeller's domain, so the denial is left unlogged"),
)

PINNED = (
    ("chr_file",
     "validatetrans chr_file (not ( t3 == rhizo_input_label ) or t2 == hidraw_device);",
     "every character node relabel the input label service makes lands on hidraw_device"),
)
PIN_CIL = "(validatetrans chr_file (or (not (eq t3 rhizo_input_label)) (eq t2 hidraw_device)))\n"
OLD_PIN_CIL = ("(validatetrans chr_file (or (not (and (eq t3 rhizo_input_label) (eq t1 device))) "
               "(eq t2 hidraw_device)))\n")

_RULE = re.compile(r"^(allow|dontaudit) \S+ \S+:(\S+) (?:\{ ([^{}]*) \}|(\S+));$")
_TRANSITION = re.compile(r"^type_transition \S+ \S+:(\S+) (\S+);$")


def sesearch(policy, *args):
    """return the output of sesearch on a policy, or the error text"""
    r = subprocess.run(["sesearch", *args, policy], capture_output=True, text=True)
    if r.returncode != 0:
        return None, "sesearch %s: rc=%d %s" % (" ".join(args), r.returncode, r.stderr.strip())
    return r.stdout, None


def rule_perms(policy, kind, domain, label, cls):
    """return the allow or dontaudit perms from domain to label"""
    out, err = sesearch(policy, "--" + kind, "-s", domain, "-t", label, "-c", cls)
    if err:
        return None, err
    perms = set()
    for line in (l.strip() for l in out.splitlines()):
        m = _RULE.match(line)
        if m and m.group(2) == cls:
            perms.update((m.group(3) or m.group(4)).split())
    return perms, None


def new_types(policy, domain, parent, cls):
    """return the type_transition targets for a domain"""
    out, err = sesearch(policy, "--type_trans", "-s", domain, "-t", parent, "-c", cls)
    if err:
        return None, err
    return {m.group(2) for m in (_TRANSITION.match(l.strip()) for l in out.splitlines())
            if m and m.group(1) == cls}, None


def problems(policy):
    """return the problems of each row in the compiled policy"""
    bad = []
    for domain, label, cls, perms, why in GRANTED:
        have, err = rule_perms(policy, "allow", domain, label, cls)
        missing = sorted(set(perms.split()) - (have or set()))
        if err or missing:
            bad.append("%s lacks %s on %s:%s (%s)%s" % (domain, " ".join(missing), label, cls, why,
                                                        ": " + err if err else ""))
    for domain, label, cls, perms, why in REFUSED:
        have, err = rule_perms(policy, "allow", domain, label, cls)
        wider = sorted(set(perms.split()) & (have or set()))
        if err or wider:
            bad.append("%s holds %s on %s:%s (%s)%s" % (domain, " ".join(wider), label, cls, why,
                                                        ": " + err if err else ""))
    for domain, parent, cls, new, why in TRANSITIONS:
        have, err = new_types(policy, domain, parent, cls)
        if err or have != {new}:
            bad.append("%s's new %s under %s take %s, wanted %s (%s)%s" % (
                domain, cls, parent, sorted(have or ()), new, why, ": " + err if err else ""))
    for domain, label, cls, perm, why in DONTAUDITED:
        have, err = rule_perms(policy, "dontaudit", domain, label, cls)
        if err or perm not in (have or set()):
            bad.append("%s's %s on %s:%s is audited (%s)%s" % (domain, perm, label, cls, why,
                                                               ": " + err if err else ""))
    for cls, rule, why in PINNED:
        r = subprocess.run(["seinfo", policy, "--validatetrans", cls], capture_output=True, text=True)
        if r.returncode != 0 or rule not in r.stdout:
            bad.append("%s lacks %s (%s)%s" % (cls, rule, why, ": seinfo rc=%d %s" % (r.returncode, r.stderr.strip())
                                                               if r.returncode else ""))
    return bad


def fixture_cil(drop=(), extra=""):
    """return a minimal CIL of the rows' rules and the extra rules"""
    classes = {}
    for _domain, _label, cls, perms, _why in GRANTED + REFUSED + DONTAUDITED:
        classes.setdefault(cls, set()).update(perms.split())
    classes.setdefault("file", set())
    types = sorted({r[0] for r in GRANTED + REFUSED + TRANSITIONS + DONTAUDITED}
                   | {r[1] for r in GRANTED + REFUSED + TRANSITIONS + DONTAUDITED}
                   | {r[3] for r in TRANSITIONS})
    lines = ["(class %s (%s))" % (c, " ".join(sorted(p))) for c, p in sorted(classes.items())]
    lines.append("(classorder (%s))" % " ".join(sorted(classes)))
    lines += ["(sid kernel)", "(sidorder (kernel))", "(user u)", "(role r)", "(type fixture_kernel)",
              "(roletype r fixture_kernel)", "(category c0)", "(categoryorder (c0))", "(sensitivity s0)",
              "(sensitivityorder (s0))", "(sensitivitycategory s0 (c0))", "(userlevel u (s0))",
              "(userrange u ((s0) (s0 (c0))))", "(userrole u r)",
              "(sidcontext kernel (u r fixture_kernel ((s0) (s0))))"]
    lines += ["(type %s)" % t for t in types]
    for domain, label, cls, perms, _why in GRANTED:
        if (domain, label, cls) not in drop:
            lines.append("(allow %s %s (%s (%s)))" % (domain, label, cls, perms))
    for domain, parent, cls, new, _why in TRANSITIONS:
        if (domain, parent, cls) not in drop:
            lines.append("(typetransition %s %s %s %s)" % (domain, parent, cls, new))
    for domain, label, cls, perm, _why in DONTAUDITED:
        if (domain, label, cls) not in drop:
            lines.append("(dontaudit %s %s (%s (%s)))" % (domain, label, cls, perm))
    if "pin" not in drop:
        lines.append(PIN_CIL.strip())
    return "\n".join(lines) + "\n" + extra


def selftest():
    """compile fixtures and check each finding both ways"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-in-android-access.")

    def expect(label, cil, want):
        """compile the fixture and compare the findings with want"""
        src, out = os.path.join(tmp, "p.cil"), os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(cil)
        r = subprocess.run(["secilc", "-m", "-M", "true", "-G", "-c", "30", src, "-o", out, "-f", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("%s: the fixture does not compile: %s" % (label, (r.stderr or r.stdout).strip()))
            return
        got = problems(out)
        for w in want:
            if not any(w in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, w, got))
        if not want and got:
            fails.append("%s: wanted no finding, got %r" % (label, got))

    try:
        expect("the full set", fixture_cil(), [])
        expect("no audio fifo grant", fixture_cil(drop={("rhizo_audio_core", "audioserver", "fifo_file")}),
               ["rhizo_audio_core lacks write on audioserver:fifo_file"])
        expect("no wakeup file grant", fixture_cil(drop={("system_suspend", "rhizo_sysfs_pci", "file")}),
               ["system_suspend lacks getattr open read on rhizo_sysfs_pci:file"])
        expect("a shell entrypoint on system_file",
               fixture_cil(extra="(allow shell system_file (file (entrypoint)))\n"),
               ["shell holds entrypoint on system_file:file"])
        for cap in ("sys_admin", "dac_override", "mknod"):
            expect("the composer's %s" % cap,
                   fixture_cil(extra="(allow rhizo_composer self (capability (%s)))\n" % cap),
                   ["rhizo_composer holds %s on rhizo_composer:capability" % cap])
        expect("no hidraw relabelfrom", fixture_cil(drop={("rhizo_input_label", "rhizo_host_device", "chr_file")}),
               ["rhizo_input_label lacks getattr relabelfrom on rhizo_host_device:chr_file"])
        expect("the service's dead device relabel",
               fixture_cil(extra="(allow rhizo_input_label device (chr_file (relabelfrom)))\n"),
               ["rhizo_input_label holds relabelfrom on device:chr_file"])
        expect("no composer evdev getattr", fixture_cil(drop={("rhizo_composer", "input_device", "chr_file")}),
               ["rhizo_composer lacks getattr on input_device:chr_file"])
        expect("no setcon", fixture_cil(drop={("kernel", "kernel", "process")}),
               ["kernel lacks setcurrent on kernel:process"])
        expect("kernel's hidraw relabelfrom", fixture_cil(extra="(allow kernel device (chr_file (relabelfrom)))\n"),
               ["kernel holds relabelfrom on device:chr_file"])
        expect("no hidraw relabel pin", fixture_cil(drop={"pin"}),
               ["chr_file lacks validatetrans chr_file (not ( t3 == rhizo_input_label ) or t2 == hidraw_device)"])
        expect("the old device-only pin", fixture_cil(drop={"pin"}, extra=OLD_PIN_CIL),
               ["chr_file lacks validatetrans chr_file (not ( t3 == rhizo_input_label ) or t2 == hidraw_device)"])
        expect("no memfd transition", fixture_cil(drop={("rhizo_audio_core", "tmpfs", "file")}),
               ["rhizo_audio_core's new file under tmpfs take [], wanted rhizo_audio_core_tmpfs"])
        expect("no mesa property dontaudit", fixture_cil(drop={("rhizo_gralloc_allocator", "default_prop", "file")}),
               ["rhizo_gralloc_allocator's read on default_prop:file is audited"])
        expect("no helper setcon", fixture_cil(drop={("kernel", "rhizo_ns_relabel", "process")}),
               ["kernel lacks dyntransition on rhizo_ns_relabel:process"])
        expect("no relabel of the device root", fixture_cil(drop={("rhizo_ns_relabel", "device", "dir")}),
               ["rhizo_ns_relabel lacks relabelfrom on device:dir"])
        expect("no stage write grant", fixture_cil(drop={("rhizo_ns_stage", "system_file", "file")}),
               ["rhizo_ns_stage lacks"])
        expect("the relabeller's transition to the label service",
               fixture_cil(extra="(allow rhizo_ns_relabel rhizo_input_label (process (dyntransition)))\n"),
               ["rhizo_ns_relabel holds dyntransition on rhizo_input_label:process"])
        for helper in ("rhizo_ns_stage", "rhizo_ns_relabel", "rhizo_ns_label"):
            expect("%s's dac_read_search" % helper,
                   fixture_cil(extra="(allow %s self (capability (dac_read_search)))\n" % helper),
                   ["%s holds dac_read_search on %s:capability" % (helper, helper)])
        expect("no setenforce dontaudit", fixture_cil(drop={("rhizo_ns_relabel", "kernel", "security")}),
               ["rhizo_ns_relabel's setenforce on kernel:security is audited"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-in-android-access selftest: ok (a missing grant, a granted refusal, a missing transition, a "
          "missing dontaudit and a missing pin caught; the full set passes)")
    return 0


def main():
    """run the selftest or judge the compiled lab policy"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    lab_dir = tempfile.mkdtemp(prefix="check-in-android-access-lab.")
    try:
        policy, _ = tty.build_lab(lab_dir)
        found = problems(policy)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: in-android access: " + p)
    if found:
        return 1
    print("ok: %d grants held, %d refusals kept, %d memfd transition, %d dontaudit and %d validatetrans pin in place"
          % (len(GRANTED), len(REFUSED), len(TRANSITIONS), len(DONTAUDITED), len(PINNED)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
