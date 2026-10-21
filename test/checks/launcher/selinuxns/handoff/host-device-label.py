#!/usr/bin/env python3
import ast, contextlib, errno, io, os, re, shutil, subprocess, sys, tempfile
NAME = "host-device-label"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..")
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
LAUNCHER = os.path.join(ROOT, "src", "androidd")
NS = "src/androidd/sandbox/selinux_ns.py"
MUTANTS = (
    ("a relabel of any label", NS, '            if os.getxattr(path, "security.selinux").rstrip(b"\\0") != HOST_DEVICE_LABEL:\n',
     '            if os.getxattr(path, "security.selinux") is None:\n', "label_host_devices from rhizo_host_device"),
    ("a relabel to another type", NS, 'b"u:object_r:rhizo_host_kmsg_device:s0"', 'b"u:object_r:rhizo_host_device:s0"',
     "label_host_devices to rhizo_host_kmsg_device and null_device"),
    ("no null node", NS, ',\n                        ("/dev/null", b"u:object_r:null_device:s0"))', ',)',
     "label_host_devices to rhizo_host_kmsg_device and null_device"),
    ("a refusal answered as done", NS, '                failures.append(f"{path}:refused")\n', "                pass\n",
     "label_host_devices refusal"),
    ("an error answered as done", NS, '            failures.append(f"{path}:errno-{e.errno}")\n', "            pass\n",
     "label_host_devices error"),
    ("a failure not logged", NS, '        kmsg(f"RHIZO_MARKER selinuxns=host-device-label-failed why={failures}")\n', "        pass\n",
     "label_host_devices failure marker"),
    ("a kmsg open after the load", NS, "    core._kmsg_fd()\n    labels = connect_label_service()\n",
     "    labels = connect_label_service()\n",
     "run_relabeller opens kmsg before"),
    ("a relabel before the setcon", NS,
     '        why = enter_helper_domain(request, HELPER_CONTEXTS["relabel"])\n        if why:\n'
     '            return f"helper-domain:{why}"\n        label_host_devices()\n',
     '        label_host_devices()\n        why = enter_helper_domain(request, HELPER_CONTEXTS["relabel"])\n        if why:\n'
     '            return f"helper-domain:{why}"\n', "on_load relabels the nodes after the setcon"),
    ("no relabel in the policy namespace entry", NS, '    if not why and helper == "relabel":\n        label_host_devices()\n',
     "", "enter_policy_namespace relabels the nodes for the relabel helper"),
    ("a relabel for every helper in the policy namespace entry", NS, '    if not why and helper == "relabel":\n        label_host_devices()\n',
     "    if not why:\n        label_host_devices()\n", "enter_policy_namespace relabels the nodes for the relabel helper"),
    ("a helper grant on rhizo_host_device", "src/androidd/sandbox/selinux_policy.py",
     "(allow rhizo_ns_relabel null_device (chr_file (ioctl)))\n",
     "(allow rhizo_ns_relabel null_device (chr_file (ioctl)))\n(allow rhizo_ns_relabel rhizo_host_device (chr_file (open write ioctl)))\n",
     "grants open, write or ioctl on rhizo_host_device"),
    ("no write on rhizo_host_kmsg_device", "src/androidd/sandbox/selinux_policy.py",
     "(chr_file (relabelto open write ioctl))", "(chr_file (relabelto open ioctl))", "rhizo_host_kmsg_device rights"),
    ("no associate for null_device", "src/androidd/sandbox/selinux_policy.py",
     "(allow null_device device (filesystem (associate)))\n", "", "null_device associate"),
)


def run_check(root):
    """run this check over a source tree"""
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--root", root], capture_output=True, text=True,
                       timeout=600)
    return r.returncode, r.stdout + r.stderr


def selftest():
    """flag each mutant and pass the real tree"""
    failed = []
    for label, rel, old, new, needle in MUTANTS:
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(os.path.join(ROOT, "src", "androidd"), os.path.join(tmp, "src", "androidd"), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__"))
            path = os.path.join(tmp, rel)
            text = open(path).read()
            if text.count(old) != 1:
                failed.append(f"the {label} mutant found {text.count(old)} anchors")
                continue
            with open(path, "w") as f:
                f.write(text.replace(old, new))
            rc, out = run_check(tmp)
        if rc == 0 or needle not in out:
            failed.append(f"the {label} mutant was not flagged: rc={rc} {out[-300:]!r}")
    rc, out = run_check(ROOT)
    if rc != 0:
        failed.append(f"the real tree has findings: {out[-500:]!r}")
    for f in failed:
        print("FAIL", f)
    print("%s: selftest ok" % NAME if not failed else "%s: selftest FAIL" % NAME)
    return 1 if failed else 0


if __name__ == "__main__" and "--selftest" in sys.argv[1:]:
    sys.exit(selftest())

sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-host-device-label")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns
    from sandbox import selinux_policy

bad = []
KMSG = "/dev/kmsg-fixture"
NULL = "/dev/null-fixture"
FROM = b"u:object_r:rhizo_host_device:s0\0"
NODES = ((KMSG, b"u:object_r:rhizo_host_kmsg_device:s0"), (NULL, b"u:object_r:null_device:s0"))


def label_host_devices_with(current, guard_answer=True, getxattr_error=None):
    """call label_host_devices over nodes reading current"""
    writes, marks = [], []
    saved = (os.getxattr, ns.selinux_labels.label_write, ns.kmsg)

    def getxattr(path, name):
        """answer the node's label or raise"""
        if getxattr_error is not None:
            raise OSError(getxattr_error, os.strerror(getxattr_error))
        return current

    def label_write(path, want, **kw):
        """record a write unless the scope guard refuses"""
        if guard_answer:
            writes.append((path, want))
        return guard_answer

    os.getxattr, ns.selinux_labels.label_write, ns.kmsg = getxattr, label_write, marks.append
    try:
        return ns.label_host_devices(NODES), writes, marks
    finally:
        os.getxattr, ns.selinux_labels.label_write, ns.kmsg = saved


got = label_host_devices_with(FROM)
if got != ([], [(KMSG, NODES[0][1] + b"\0"), (NULL, NODES[1][1] + b"\0")], []):
    bad.append(("label_host_devices to rhizo_host_kmsg_device and null_device", got))
for current in (NODES[0][1] + b"\0", NODES[1][1] + b"\0", b"u:object_r:unlabeled:s0\0", b"u:object_r:kmsg_device:s0\0"):
    got = label_host_devices_with(current)
    if got != ([], [], []):
        bad.append(("label_host_devices from rhizo_host_device", current, got))
got = label_host_devices_with(FROM, guard_answer=False)
if got[0] != [KMSG + ":refused", NULL + ":refused"] or got[1]:
    bad.append(("label_host_devices refusal", got))
got = label_host_devices_with(FROM, getxattr_error=errno.ENODATA)
if got[0] != [KMSG + ":errno-%d" % errno.ENODATA, NULL + ":errno-%d" % errno.ENODATA] or got[1]:
    bad.append(("label_host_devices error", got))
if len(got[2]) != 1 or "selinuxns=host-device-label-failed" not in got[2][0]:
    bad.append(("label_host_devices failure marker", got[2]))
if ns.HOST_DEVICE_CONTEXTS != (("/dev/kmsg", NODES[0][1]), ("/dev/null", NODES[1][1])):
    bad.append(("label_host_devices to rhizo_host_kmsg_device and null_device", ns.HOST_DEVICE_CONTEXTS))

tree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read())
functions = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
run = ast.unparse(functions["run_relabeller"])
if not 0 <= run.find("core._kmsg_fd()") < run.find("connect_label_service()") < run.find("_relabel_after_load("):
    bad.append(("run_relabeller opens kmsg before the load", "core._kmsg_fd() before _relabel_after_load("))
on_load = next((n for n in ast.walk(functions["run_relabeller"]) if isinstance(n, ast.FunctionDef) and n.name == "on_load"), None)
body = ast.unparse(on_load) if on_load is not None else ""
if not 0 <= body.find("enter_helper_domain(") < body.find("label_host_devices()"):
    bad.append(("on_load relabels the nodes after the setcon", "enter_helper_domain( before label_host_devices()"))
entry = ast.unparse(functions["enter_policy_namespace"])
if not re.search(r"enter_helper_domain\(.*\n\s+if not why and helper == 'relabel':\n\s+label_host_devices\(\)", entry):
    bad.append(("enter_policy_namespace relabels the nodes for the relabel helper", entry[-200:]))
if entry.count("label_host_devices()") != 1:
    bad.append(("enter_policy_namespace relabels the nodes for the relabel helper", "one call"))

fragment = selinux_policy.NAMESPACE_HELPER_DOMAINS
host_rules = [l for l in fragment.splitlines()
              if re.match(r"\(allowx? rhizo_ns_\w+ rhizo_host_device ", l) and re.search(r"\b(open|write|ioctl)\b", l)]
if host_rules:
    bad.append(("grants open, write or ioctl on rhizo_host_device", host_rules))
kmsg_rules = [l for l in fragment.splitlines() if l.startswith("(allow rhizo_ns_relabel rhizo_host_kmsg_device (chr_file")]
if len(kmsg_rules) != 1 or not all(re.search(r"\b%s\b" % p, kmsg_rules[0]) for p in ("relabelto", "open", "write", "ioctl")):
    bad.append(("rhizo_host_kmsg_device rights", kmsg_rules))
if "(allow null_device device (filesystem (associate)))" not in fragment.splitlines():
    bad.append(("null_device associate", "no associate rule between null_device and device"))

if bad:
    for item in bad:
        print("FAIL", item)
    print("FAIL")
    sys.exit(1)
print("ok")
