#!/usr/bin/env python3
"""check the staged init services"""

import ast
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
STAGED_GLOB = "src/androidd/guest/*.rc"
PYTHON_SOURCES = ("src/androidd/sandbox/hals.py",)

SHELL_SECLABEL = "u:r:shell:s0"
SHELL_ENTRYPOINT = "/system/bin/sh"
SHELL_SCRIPT_HEAD = b"#!/system/bin/sh"
GSI_SHELL_SCRIPTS = ("/system/bin/pm", "/system/bin/locksettings", "/system/bin/device_config")
LOGCAT = "/system/bin/logcat"
ALL_LOG_USERS = ("root", "system", "log")
REFUSED_CAPABILITIES = {
    "vendor.rhizo-composer": {
        "SYS_ADMIN": "the policy grants rhizo_composer no sys_admin; the composer's CAP_SYS_ADMIN caller is "
                     "unidentified and the capability is withheld because no Rhizo code needs it",
        "DAC_OVERRIDE": "AOSP's domain.te neverallows dac_override outside a fixed domain list; the composer opens "
                        "only nodes its system uid and uhid group reach, and the one call that fails DAC, the uinput "
                        "teardown's unlink in /dev/input, the policy refuses anyway (no remove_name on input_device)",
        "MKNOD": "AOSP's domain.te neverallows mknod outside init, kernel, ueventd and vold, and the composer "
                 "makes no device node: the host input fence publishes /dev/input, and its control fifo needs "
                 "no CAP_MKNOD",
    },
}


def services(rc_text):
    """return each service in an rc text with its argv and option lines"""
    found, name = {}, None
    for line in rc_text.split("\n"):
        m = re.match(r"^\s*service (\S+) (.+?)\s*$", line)
        if m:
            name = m.group(1)
            found[name] = (shlex.split(m.group(2)), [])
        elif name and line.startswith((" ", "\t")) and line.strip() and not line.strip().startswith("#"):
            found[name][1].append(line.strip())
        elif not line.strip().startswith("#"):
            name = None
    return found


def python_rc_texts(source):
    """return the init service texts in a python source's string literals"""
    texts = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and "service " in node.value:
            texts.append(node.value)
    return texts


def option_words(options, keyword):
    """return the words after keyword on a service's option lines"""
    return [w for o in options for w in o.split()[1:] if o.split()[0] == keyword]


def problems(rc_texts):
    """return the problems of the rc texts"""
    bad = []
    for where, text in rc_texts:
        for name, (argv, options) in services(text).items():
            if "seclabel %s" % SHELL_SECLABEL in options:
                if argv[0] != SHELL_ENTRYPOINT:
                    bad.append("%s: service %s execs %s in the shell domain, whose GSI entrypoint is %s "
                               "(shell_exec)" %
                               (where, name, argv[0], SHELL_ENTRYPOINT))
                elif len(argv) < 2 or (argv[1] != "-c" and argv[1] not in GSI_SHELL_SCRIPTS):
                    bad.append("%s: service %s runs %s on %s, which is neither -c nor a GSI shell script "
                               "in %s" % (where, name, SHELL_ENTRYPOINT, argv[1:2] or "nothing",
                                          ", ".join(GSI_SHELL_SCRIPTS)))
            words = " ".join(argv).split()
            user = (option_words(options, "user") or ["root"])[0]
            if (LOGCAT in words or "logcat" in words) and user not in ALL_LOG_USERS \
                    and "log" not in option_words(options, "group"):
                bad.append("%s: service %s runs logcat as user %s without the log group" % (where, name, user))
            refused = REFUSED_CAPABILITIES.get(name, {})
            for cap in option_words(options, "capabilities"):
                if cap in refused:
                    bad.append("%s: service %s asks init for %s: %s" % (where, name, cap, refused[cap]))
    return bad


def tree_rc_texts(root):
    """return the rc texts under a root"""
    texts = []
    for path in sorted(glob.glob(os.path.join(root, STAGED_GLOB))):
        with open(path) as f:
            texts.append((os.path.relpath(path, root), f.read()))
    for rel in PYTHON_SOURCES:
        with open(os.path.join(root, rel)) as f:
            texts.extend((rel, t) for t in python_rc_texts(f.read()))
    return texts


def debugfs_reader(image):
    """return a function reading a file's first bytes out of an ext4 image"""
    def read_head(path):
        """return the first bytes of path in the image, or the debugfs error"""
        r = subprocess.run(["debugfs", "-R", "cat %s" % path, image], capture_output=True)
        errors = [l for l in r.stderr.decode(errors="replace").splitlines() if not l.startswith("debugfs ")]
        if r.returncode != 0 or errors:
            return None, "debugfs rc=%d %s" % (r.returncode, "; ".join(errors))
        return r.stdout[:64], None
    return read_head


def gsi_script_problems(read_head):
    """return the GSI_SHELL_SCRIPTS paths that are not shell scripts"""
    bad = []
    for path in GSI_SHELL_SCRIPTS:
        head, err = read_head(path)
        if err:
            bad.append("%s: cannot read it from the GSI: %s" % (path, err))
        elif not head.startswith(SHELL_SCRIPT_HEAD):
            bad.append("%s: not a shell script in the GSI, it starts %r" % (path, head[:16]))
    return bad


GOOD_RC = """service fixture-pm /system/bin/sh /system/bin/pm disable-user --user 0 com.example
    disabled
    oneshot
    user shell
    seclabel u:r:shell:s0

service fixture-adbd /apex/com.android.adbd/bin/adbd
    seclabel u:r:adbd:s0

service vendor.rhizo-composer /vendor/bin/hw/rhizo-composer
    class core
    user system
    capabilities SYS_NICE
"""

GOOD_PY = '''
def stage():
    open("x.rc", "w").write(
        "service fixture-logcat /system/bin/sh -c \\"/system/bin/logcat -d\\"\\n"
        "    oneshot\\n"
        "    user shell\\n"
        "    group shell log\\n"
        "    seclabel u:r:shell:s0\\n")
'''


def selftest():
    """check the good fixtures and each planted defect"""
    fails = []

    def expect(label, rc_texts, want):
        """compare the findings for the texts with the wanted fragments"""
        got = problems(rc_texts)
        for w in want:
            if not any(w in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, w, got))
        if not want and got:
            fails.append("%s: wanted no finding, got %r" % (label, got))

    good = [("good.rc", GOOD_RC)] + [("good.py", t) for t in python_rc_texts(GOOD_PY)]
    expect("the good fixtures", good, [])
    expect("a script exec'd in the shell domain",
           [("bad.rc", GOOD_RC.replace("/system/bin/sh /system/bin/pm", "/system/bin/pm"))],
           ["service fixture-pm execs /system/bin/pm in the shell domain"])
    expect("cmd exec'd in the shell domain",
           [("bad.rc", GOOD_RC.replace("/system/bin/sh /system/bin/pm disable-user --user 0 com.example",
                                       "/system/bin/cmd device_config put privacy x false"))],
           ["service fixture-pm execs /system/bin/cmd"])
    expect("an ELF after sh",
           [("bad.rc", GOOD_RC.replace("/system/bin/sh /system/bin/pm", "/system/bin/sh /system/bin/cmd"))],
           ["service fixture-pm runs /system/bin/sh on ['/system/bin/cmd'], which is neither -c nor"])
    expect("logcat exec'd in the shell domain from a python literal",
           [("bad.py", t) for t in python_rc_texts(GOOD_PY.replace('/system/bin/sh -c \\"/system/bin/logcat -d\\"',
                                                                   "/system/bin/logcat -d"))],
           ["bad.py: service fixture-logcat execs /system/bin/logcat"])
    expect("logcat without the log group",
           [("bad.py", t) for t in python_rc_texts(GOOD_PY.replace("group shell log", "group shell"))],
           ["service fixture-logcat runs logcat as user shell without the log group"])
    for cap in ("SYS_ADMIN", "DAC_OVERRIDE", "MKNOD"):
        expect("the composer asking for %s" % cap,
               [("bad.rc", GOOD_RC.replace("capabilities SYS_NICE", "capabilities %s SYS_NICE" % cap))],
               ["service vendor.rhizo-composer asks init for %s" % cap])
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-in-android-rc selftest: ok (a script, cmd and logcat exec'd in the shell domain, an ELF after sh, "
          "logcat without the log group and the composer's SYS_ADMIN, DAC_OVERRIDE and MKNOD caught; sh on a GSI "
          "script or -c, another domain's seclabel and the composer with SYS_NICE alone pass)")
    return 0


def selftest_gsi():
    """check the GSI script reader on an ext4 fixture image"""
    tmp = tempfile.mkdtemp(prefix="check-in-android-rc-gsi.")
    try:
        bin_dir = os.path.join(tmp, "root", "system", "bin")
        os.makedirs(bin_dir)
        with open(os.path.join(bin_dir, "pm"), "wb") as f:
            f.write(SHELL_SCRIPT_HEAD + b"\ncmd package \"$@\"\n")
        with open(os.path.join(bin_dir, "locksettings"), "wb") as f:
            f.write(b"\x7fELF\x02\x01\x01" + bytes(57))
        image = os.path.join(tmp, "fixture.img")
        with open(image, "wb") as f:
            f.truncate(8 << 20)
        r = subprocess.run(["mke2fs", "-F", "-q", "-t", "ext4", "-d", os.path.join(tmp, "root"), image],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("SELFTEST FAIL: mke2fs rc=%d %s" % (r.returncode, r.stderr.strip()))
            return 1
        got = gsi_script_problems(debugfs_reader(image))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    fails = []
    for want in ("/system/bin/locksettings: not a shell script in the GSI",
                 "/system/bin/device_config: cannot read it from the GSI"):
        if not any(g.startswith(want) for g in got):
            fails.append("wanted a finding starting %r, got %r" % (want, got))
    if any(g.startswith("/system/bin/pm:") for g in got):
        fails.append("the shell script /system/bin/pm was flagged: %r" % got)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-in-android-rc GSI selftest: ok (an ELF and a missing file flagged, a shell script passes)")
    return 0


def main():
    """run the checks or a selftest"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    if sys.argv[1:] == ["--selftest-gsi"]:
        return selftest_gsi()
    if len(sys.argv) == 3 and sys.argv[1] == "--gsi":
        if not os.path.isfile(sys.argv[2]):
            print("FAIL: in-android rc: no GSI image at %s" % sys.argv[2])
            return 1
        found = gsi_script_problems(debugfs_reader(sys.argv[2]))
        for p in found:
            print("FAIL: in-android rc: " + p)
        if found:
            return 1
        print("ok: %s are shell scripts in %s" % (", ".join(GSI_SHELL_SCRIPTS), sys.argv[2]))
        return 0
    found = problems(tree_rc_texts(REPO))
    for p in found:
        print("FAIL: in-android rc: " + p)
    if found:
        return 1
    print("ok: every shell-domain service runs %s on -c or a GSI shell script, logcat holds the log group and "
          "the composer asks init for no SYS_ADMIN, DAC_OVERRIDE or MKNOD" % SHELL_ENTRYPOINT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
