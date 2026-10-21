#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
CLI = os.path.join(REPO, "src", "install", "cli", "rhizo.sh")
WANT = "u:object_r:rhizo_device_state_file:s0"

SITE = r'''
import errno, os
_set, _get = os.setxattr, os.getxattr
def _host(name, value):
    return (name == "security.selinux" and value.startswith(b"u:") and os.environ.get("FAKE_HOST_POLICY") == "1"
            and os.environ.get("FAKE_IN_POLICY") != "1")
def setxattr(path, name, value, *a, **k):
    if _host(name, value):
        raise OSError(errno.EINVAL, os.strerror(errno.EINVAL))
    return _set(path, name, value, *a, **k)
def getxattr(path, name, *a, **k):
    value = _get(path, name, *a, **k)
    return b"system_u:object_r:unlabeled_t:s0\0" if _host(name, value) else value
os.setxattr, os.getxattr = setxattr, getxattr
'''

LAUNCHER = r'''
import os, sys
if sys.argv[1] != "in-android-policy":
    sys.exit("fake launcher: unexpected verb %r" % sys.argv[1])
if os.environ.get("FAKE_POLICY_FAILS") == "1":
    print("IN_ANDROID_POLICY_FAILED reason=no-compiled-policy")
    sys.exit(1)
os.environ["FAKE_IN_POLICY"] = "1"
if sys.argv[2] not in ("label", "label-fd") or len(sys.argv) != 5:
    sys.exit("fake launcher: not a fixed label verb: %r" % sys.argv[2:])
target = sys.argv[3] if sys.argv[2] == "label" else int(sys.argv[3])
os.setxattr(target, "security.selinux", sys.argv[4].encode() + b"\0", follow_symlinks=sys.argv[2] == "label-fd")
print(os.getxattr(target, "security.selinux", follow_symlinks=sys.argv[2] == "label-fd").rstrip(b"\0").decode())
'''


def run(case, cli, tmp):
    """label a file on a fresh tmpfs"""
    mode, host_policy, fails = case
    attr = os.path.join(tmp, "attr")
    if os.path.isdir(attr):
        os.rmdir(attr)
    elif os.path.exists(attr):
        os.unlink(attr)
    if host_policy == "unreadable":
        os.makedirs(attr)
    else:
        with open(attr, "w") as fh:
            fh.write("system_u:system_r:unconfined_t:s0\0" if host_policy else "kernel\0")
    with open(os.path.join(tmp, "mode"), "w") as fh:
        fh.write(mode + "\n")
    script = (f"RHIZO_CLI_SOURCE_ONLY=1 source {cli} || exit 91\n"
              f"mount -t tmpfs tmpfs {tmp}/device || exit 90\n"
              f"f={tmp}/device/.device-state.test; : > \"$f\"\n"
              f"label_android_file \"$f\" {WANT}; rc=$?\n"
              f"echo \"RC $rc\"\n"
              f"/usr/bin/python3 -I -c 'import os,sys; print(\"STORED\", os.getxattr(sys.argv[1], \"security.selinux\")"
              f".rstrip(b\"\\0\").decode())' \"$f\" 2>/dev/null || echo 'STORED none'\n")
    env = dict(os.environ, RHIZO_SELINUX_MODE_FILE=os.path.join(tmp, "mode"), RHIZO_ATTR_CURRENT=attr,
               RHIZO_LAUNCHER=os.path.join(tmp, "launcher3.py"), PYTHONPATH=os.path.join(tmp, "site"),
               FAKE_HOST_POLICY="1" if host_policy is True else "0", FAKE_POLICY_FAILS="1" if fails else "0")
    path = os.path.join(tmp, "label.sh")
    with open(path, "w") as fh:
        fh.write(script)
    return subprocess.run(["unshare", "-Urm", "bash", path], capture_output=True, text=True, env=env, timeout=60)


def override_findings(cli):
    """return directories a setter writes outside its own"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "mode"), "w") as fh:
            fh.write("host\n")
        for case, device_state, want_ok in (("the default", "$STATE_DIR/device-state", True),
                                    ("an instance's default", "$STATE_DIR/device-state-2", True),
                                    ("a directory outside the state root", f"{tmp}/home/device-state", False),
                                    ("another state directory's name", "$STATE_DIR/vendor", False),
                                    ("a symlink to a host directory", "$STATE_DIR/device-state-3", False)):
            script = (f"RHIZO_CLI_SOURCE_ONLY=1 source {cli} || exit 91\n"
                      f"mount -t tmpfs tmpfs {tmp} || exit 90\n"
                      f"echo host > {tmp}/mode; mkdir -p {tmp}/state {tmp}/home {tmp}/target\n"
                      f"STATE_DIR={tmp}/state; DEVICE_DIR={device_state}\n"
                      f"ln -s {tmp}/target {tmp}/state/device-state-3\n"
                      f"( set_device_state gnss_lat 1 ) && echo WROTE || echo REFUSED\n"
                      f"( device_bridge_write sensor-light.conf lux=1 ) && echo WROTE || echo REFUSED\n"
                      f"echo STRAY $(find {tmp}/home {tmp}/target {tmp}/state/vendor -mindepth 1 2>/dev/null | wc -l)\n")
            path = os.path.join(tmp + ".sh")
            with open(path, "w") as fh:
                fh.write(script)
            env = dict(os.environ, RHIZO_SELINUX_MODE_FILE=os.path.join(tmp, "mode"))
            r = subprocess.run(["unshare", "-Urm", "bash", path], capture_output=True, text=True, env=env, timeout=60)
            os.unlink(path)
            wrote, refused = r.stdout.count("WROTE"), r.stdout.count("REFUSED")
            named = "RHIZO_DEVICE_STATE_DIR" in r.stderr
            stray = re.search(r"^STRAY (\d+)$", r.stdout, re.M)
            if want_ok and wrote != 2:
                bad.append(f"the device-state setters refuse {case} ({device_state}): {r.stdout.strip()!r} {r.stderr.strip()[-300:]!r}")
            if not want_ok and (refused != 2 or not named or stray is None or stray.group(1) != "0"):
                bad.append(f"the device-state setters write {case} ({device_state}), want both refused naming "
                           f"RHIZO_DEVICE_STATE_DIR and nothing written: {r.stdout.strip()!r} {r.stderr.strip()[-300:]!r}")
    return bad


def findings(cli):
    """return the label failures per host"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "site"))
        os.makedirs(os.path.join(tmp, "device"))
        with open(os.path.join(tmp, "site", "sitecustomize.py"), "w") as fh:
            fh.write(SITE)
        with open(os.path.join(tmp, "launcher3.py"), "w") as fh:
            fh.write(LAUNCHER)
        for case, want_rc, want_stored in ((("namespace", False, False), 0, WANT),
                                           (("namespace", True, False), 0, WANT),
                                           (("namespace", True, True), "nonzero", "none"),
                                           (("namespace", "unreadable", False), "nonzero", "none"),
                                           (("host", True, False), 0, "none")):
            r = run(case, cli, tmp)
            rc = re.search(r"^RC (\d+)$", r.stdout, re.M)
            stored = re.search(r"^STORED (\S+)$", r.stdout, re.M)
            got_rc = int(rc.group(1)) if rc else None
            ok_rc = got_rc == 0 if want_rc == 0 else bool(got_rc)
            if not ok_rc or stored is None or stored.group(1) != want_stored:
                mode, host_policy, fails = case
                host = {"unreadable": "whose SELinux attribute cannot be read", True: "with its own policy"}.get(
                    host_policy, "without its own policy")
                bad.append(f"label_android_file in {mode} mode on a host {host}"
                           f"{', in-android-policy failing' if fails else ''}: rc={got_rc}, stored "
                           f"{stored.group(1) if stored else None}, want rc {want_rc} and {want_stored} "
                           f"({r.stdout.strip()[-200:]!r} {r.stderr.strip()[-300:]!r})")
    return bad + override_findings(cli)


def selftest():
    """check that the host-side-only label is flagged"""
    if findings(CLI):
        print(f"FAIL selftest: the real CLI is flagged: {findings(CLI)}")
        return 1
    text = open(CLI).read()
    mutant = re.sub(r"(^label_android_file\(\) \{.*?)host_policy_loaded\n", r"\1false\n", text, count=1,
                    flags=re.S | re.M)
    if mutant == text:
        print("FAIL selftest: the host-side-only mutant changed nothing")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "rhizo.sh")
        with open(path, "w") as fh:
            fh.write(mutant)
        got = findings(path)
    if not any("with its own policy:" in f for f in got):
        print(f"FAIL selftest: a host-side-only label was not flagged: {got}")
        return 1
    print("device-state-cli-label selftest: a host-side-only label is flagged, the real CLI clean")
    return 0


if __name__ == "__main__":
    probe = subprocess.run(["unshare", "-Urm", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        print(f"FAIL unshare -Urm is refused here ({probe.stderr.strip() or probe.returncode})")
        sys.exit(1)
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    out = findings(CLI)
    for line in out:
        print("FAIL", line)
    print("device-state-cli-label:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
