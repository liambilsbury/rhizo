#!/usr/bin/env python3
import contextlib
import io
import os
import re
import subprocess
import sys
import tempfile
import types

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-needed-modules")
sys.path.insert(0, os.path.join(REPO, "src", "androidd"))

WANT = {
    "char-major-10-223": "uinput",
    "net-pf-16-proto-4-type-2": "inet_diag",
    "net-pf-16-proto-4-type-10": "inet_diag",
    "inet_diag tcp": "tcp_diag",
    "inet_diag udp": "udp_diag",
    "net-pf-40": "vsock",
    "vsock virtio transport": "vmw_vsock_virtio_transport",
    "vsock loopback transport": "vsock_loopback",
    "net-sch-clsact": "sch_ingress",
    "nfnetlink-subsys-4 (netd's NFULNL config and NFLOG listener)": "nfnetlink_log",
}
NOT_WANTED = {
    "dummy": "netdev-dummy0 is a device-name lookup no module alias answers, and dummy's own dummy0 lands in the "
             "host's netns",
}


def read(rel):
    """return a repo file's text"""
    with open(os.path.join(REPO, rel)) as f:
        return f.read()


def lift(src, name):
    """return the text of a top-level shell function"""
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, src, re.S | re.M)
    return m.group(0) if m else ""


def run_prepare_fn(verb_body, fn):
    """run a lifted prepare function against a stub launcher3.py"""
    prep = read("src/install/prepare/prepare.sh")
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, "launcher3.py"), "w") as f:
            f.write(verb_body)
        script = "\n".join([
            f"PAYLOAD={d}", "log() { :; }", 'failstop() { echo "FAILSTOP $1"; exit 1; }',
            lift(prep, "needed_modules"), lift(prep, "write_modules_load_conf"), lift(prep, "verify_modules_load"),
            fn])
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        return r.returncode, r.stdout


def main():
    """return the failures"""
    fails = []
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from sandbox import core
    have = getattr(core, "ANDROID_NEEDED_MODULES", None)
    if have is None:
        return ["core has no ANDROID_NEEDED_MODULES"]
    for alias, mod in WANT.items():
        if mod not in have:
            fails.append(f"{mod} ({alias}) missing from ANDROID_NEEDED_MODULES")
    for mod, why in NOT_WANTED.items():
        if mod in have:
            fails.append(f"{mod} is in ANDROID_NEEDED_MODULES: {why}")
    if re.search(r"setup_loop_and_netfilter\(\):.*?load_needed_modules\(\)", read("src/androidd/boot.py"), re.S) is None:
        fails.append("setup_loop_and_netfilter does not call load_needed_modules (runs in both SELinux modes)")
    if '"needed-modules"' not in read("src/androidd/boot.py"):
        fails.append("launcher has no needed-modules verb for prepare to read")
    prep = read("src/install/prepare/prepare.sh")
    if not re.search(r"write_modules_load_conf\(\) \{.*?needed-modules.*?\n\}", prep, re.S):
        fails.append("write_modules_load_conf does not take its list from the launcher's needed-modules verb")
    env = dict(os.environ, RHIZO_GSI="/nonexistent-gsi-for-check-needed-modules")
    r = subprocess.run([sys.executable, os.path.join(REPO, "src", "androidd", "boot.py"), "needed-modules"],
                       capture_output=True, text=True, env=env, cwd=os.path.join(REPO, "src", "androidd"))
    if r.returncode or r.stdout.split("\n") != list(have) + [""]:
        fails.append(f"needed-modules verb stdout is not exactly the module names (rc={r.returncode}): {r.stdout!r}")
    if "cannot read" not in r.stderr:
        fails.append("the unreadable-build.prop warning did not go to stderr")
    for label, body in (("exits non-zero", "import sys; sys.exit(3)"), ("prints nothing", "pass")):
        rc, out = run_prepare_fn(body, "write_modules_load_conf")
        if rc == 0 or "FAILSTOP" not in out:
            fails.append(f"write_modules_load_conf does not fail when the verb {label}: rc={rc} {out!r}")
        rc, out = run_prepare_fn(body, "verify_modules_load")
        if rc == 0:
            fails.append(f"verify_modules_load does not fail when the verb {label}")
    rc, out = run_prepare_fn("print('uinput')", "needed_modules")
    if rc or out != "uinput\n":
        fails.append(f"needed_modules does not pass a good verb's stdout through: rc={rc} {out!r}")
    logged = []
    rhizo_env_kmsg, core.kmsg = core.kmsg, logged.append
    try:
        def fake_run(cmd, **kw):
            """fail only the one module"""
            return types.SimpleNamespace(returncode=1 if cmd[-1] == "vsock" else 0, stderr="not found")
        core.load_needed_modules(run=fake_run)
    except Exception as e:
        fails.append(f"load_needed_modules raised on a missing module: {e}")
    finally:
        core.kmsg = rhizo_env_kmsg
    if not any("vsock" in m and "WARNING" in m for m in logged):
        fails.append(f"a missing module was not logged by name: {logged}")
    return fails


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("needed-modules:", "FAIL" if out else "OK")
    sys.exit(1 if out else 0)
