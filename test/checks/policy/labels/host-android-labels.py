#!/usr/bin/env python3
import argparse
import ast
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
WANT = "u:object_r:rhizo_inbox_file:s0"
SHDEF = re.compile(r"^([A-Za-z_][\w-]*)\(\) \{")
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
PRIMER = ("the host primer runs in host mode, where the host's policy is Android's, and as the namespace relabeller's "
          "flat pass inside Android's namespace")
RELABELLER = "runs in the relabeller or the prelabel child, inside a namespace holding Android's policy"
SITES = {
    ("src/install/prepare/materialize-data-template.py", "materialize"): (
        "data-template.sh runs it under in-android-policy on a policy host",
        [("src/install/prepare/data-template.sh", "<top>",
          r"host_policy; then\s+materialize=\(python3 \"\$LAUNCHER\" in-android-policy materialize-data-template")]),
    ("src/install/prepare/materialize-data-template.py", "materialize_one"): (
        "data-template.sh runs it under in-android-policy on a policy host",
        [("src/install/prepare/data-template.sh", "<top>", r"in-android-policy")]),
    ("src/install/cli/rhizo.sh", "label_android_file"): (
        "writes host-side only without a host policy, through in-android-policy otherwise",
        [("src/install/cli/rhizo.sh", "label_android_file", r"host_policy_loaded\n\s+case \$\? in\n\s+0\)\n\s+got=.*in-android-policy label")]),
    ("src/androidd/boot.py", "_stage_tethering_apex"): (
        "labels only when the caller passes label, which a launch clears on a policy host and prepare-tree runs in a "
        "policy namespace", [("src/androidd/boot.py", "stage_apex_and_patches", r"host_refuses_android_labels\(\)"),
                             ("src/androidd/boot.py", "prepare_tree_verb", r"_in_policy_namespace\(")]),
    ("src/androidd/boot.py", "_stage_decompressed_apexes"): (
        "labels only when the caller passes label, as _stage_tethering_apex",
        [("src/androidd/boot.py", "stage_apex_and_patches", r"label=not _labels_refused"),
         ("src/androidd/boot.py", "prepare_tree_verb", r"_in_policy_namespace\(")]),
    ("src/androidd/boot.py", "_stage_vendor_scaffold"): (
        "labels the device-state link in host mode only, before a policy loads",
        [("src/androidd/boot.py", "_stage_vendor_scaffold", r"if host_selinux_mode\(\) and not policy_is_loaded\(\):")]),
    ("src/androidd/boot.py", "label_in_namespace"): (
        "in-android-policy's label verbs run it after the policy load, with every capability dropped",
        [("src/androidd/boot.py", "in_android_policy_verb",
          r"_enter_compiled_policy_namespace\(compiled_policy_path\(\), IN_ANDROID_POLICY_HELPER\[verb\]\)(.|\n)*_drop_privileges\(last_cap\)(.|\n)*label_in_namespace\(")]),
    ("src/androidd/boot.py", "_relabel_prepared_vendor"): (
        "prepare-tree runs it in a child namespace holding Android's policy on a policy host",
        [("src/androidd/boot.py", "prepare_tree_verb", r"in_policy_ns = host_has_own_policy\(\)")]),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:<module>"): (PRIMER, []),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:label_write"): (PRIMER, []),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:relabel_flat_trees"): (PRIMER, []),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:relabel_host_input_nodes"): (PRIMER, []),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:relabel_host_kmsg"): (PRIMER, []),
    ("src/androidd/boot.py", "HOST_PRIMER_SRC:relabel_staged_files"): (PRIMER, []),
    ("src/androidd/sandbox/rootfs.py", "apply_input_decision"): (
        "the namespace-mode fence labels through the label service's node fd inside Android's namespace", []),
    ("src/androidd/sandbox/rootfs.py", "label_before_policy"): (
        "returns before the write in an unshared namespace",
        [("src/androidd/sandbox/rootfs.py", "label_before_policy", r'if selinux_ns\.state\(\)\["unshared"\]:\s+return False')]),
    ("src/androidd/sandbox/rootfs.py", "label_device_state_dir"): (
        "the prelabel child calls it after entering the policy namespace, and host mode before the policy loads",
        [("src/androidd/sandbox/rootfs.py", "prelabel_vendor_tree", r"enter_policy_namespace\("),
         ("src/androidd/sandbox/rootfs.py", "_setup_cgroups_and_selinuxfs", r"device_state_bound and host_selinux_mode\(\)")]),
    ("src/androidd/sandbox/rootfs.py", "setup_net_core_sysctls"): (
        "labels in host mode only; the relabeller's label_net_core labels net.core in namespace mode",
        [("src/androidd/sandbox/rootfs.py", "setup_net_core_sysctls", r"_label_here = host_selinux_mode\(\)")]),
    ("src/androidd/sandbox/selinux_labels.py", "label_host_binaries"): (
        "host mode only", [("src/androidd/sandbox/selinux_labels.py", "label_host_binaries", r"if not host_selinux_mode\(\)")]),
    ("src/androidd/sandbox/selinux_labels.py", "label_host_modules"): (
        "called only from label_host_binaries, host mode only",
        [("src/androidd/sandbox/selinux_labels.py", "label_host_binaries", r"label_host_modules\(\)")]),
    ("src/androidd/sandbox/selinux_labels.py", "label_write"): ("the shared write each classified caller goes through", []),
    ("src/androidd/sandbox/selinux_labels.py", "relabel_root_objects_now"): (
        "returns before writing unless the caller's own namespace holds a policy",
        [("src/androidd/sandbox/selinux_labels.py", "relabel_root_objects_now", r'if ":" not in cur:')]),
    ("src/androidd/sandbox/selinux_ns.py", "_wait_dev_labelable"): (RELABELLER, []),
    ("src/androidd/sandbox/selinux_ns.py", "bind_decoy_enforce"): (
        "labels its own scratch tmpfs after the handoff's unshare, an in-memory label no ancestor reads", []),
    ("src/androidd/sandbox/selinux_ns.py", "label_host_devices"): (RELABELLER, []),
    ("src/androidd/sandbox/selinux_ns.py", "label_by_file_contexts"): (RELABELLER, []),
    ("src/androidd/sandbox/selinux_ns.py", "label_net_core"): (RELABELLER, []),
    ("src/androidd/sandbox/selinux_ns.py", "label_sysctl_shadows"): (RELABELLER, []),
    ("src/androidd/sandbox/selinux_ns.py", "setxattr"): (
        "NodeFd, the namespace-mode label service's node access, runs inside Android's namespace", []),
    ("src/androidd/sandbox/selinux_ns.py", "set_xattr_through_fd"): (
        "the namespace-mode label service writes a node's label through its fd inside Android's namespace", []),
    ("src/services/hostfs/hostfs.py", "label_android_file"): (
        "attach labels the mount point through label_in_policy_namespace on a policy host",
        [("src/services/hostfs/hostfs.py", "attach_one", r'prepared = mode == "namespace" and host_policy_loaded\(\)')]),
    ("src/services/broker/inbox_stage.py", "label_fd"): (
        "write_labeled runs it host-side only without a host policy, through in-android-policy otherwise",
        [("src/services/broker/inbox_stage.py", "write_labeled",
          r"label_in_android_policy\(out, label[^)]*\) if host_policy_loaded\(\) else label_fd\(out, label\)")]),
}

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

BROKER = r'''
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("brokerd", sys.argv[1])
brokerd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brokerd)
fd = os.open(sys.argv[3], os.O_RDONLY)
try:
    print("SANDBOX", brokerd.materialize_apk(fd, sys.argv[2], sys.argv[4]))
except Exception as e:
    print("REFUSED", e)
'''

STAGE = r'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("inbox_stage", sys.argv[1])
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
try:
    stage.stage(sys.argv[2], "s.apk", sys.argv[3], sys.argv[4])
    print("STAGED")
except OSError as e:
    print("REFUSED", e)
'''


def function_text(root, rel, name):
    """return a function's source text"""
    path = os.path.join(root, rel)
    text = open(path, errors="replace").read()
    if name == "<top>":
        return text
    if rel.endswith(".sh"):
        m = re.search(r"^%s\(\) \{.*?^\}$" % re.escape(name), text, re.S | re.M)
        return m.group(0) if m else None
    for node in ast.walk(ast.parse(text)):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return ast.get_source_segment(text, node)
    return None


def xattr_name(call, consts):
    """return a setxattr call's attribute name, or <variable>"""
    arg = call.args[1] if len(call.args) > 1 else next((k.value for k in call.keywords if k.arg in ("name", "attribute")),
                                                        None)
    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
        return arg.value
    if isinstance(arg, ast.Name) and arg.id in consts:
        return consts[arg.id]
    return "<variable>"


def module_consts(tree):
    """return the module's names bound to a string constant"""
    return {t.id: n.value.value for n in tree.body if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant)
            and isinstance(n.value.value, str) for t in n.targets if isinstance(t, ast.Name)}


def write_sites(root):
    """return every possible label write under src"""
    found, unreadable = set(), []

    def visit(node, fn, rel, prefix, consts):
        """collect the label calls below node"""
        for c in ast.iter_child_nodes(node):
            if isinstance(c, (ast.FunctionDef, ast.AsyncFunctionDef)):
                visit(c, c.name, rel, prefix, consts)
                continue
            if isinstance(c, ast.Call):
                name = getattr(c.func, "attr", getattr(c.func, "id", ""))
                if name == "label_write" or (name == "setxattr" and
                                             xattr_name(c, consts) in ("security.selinux", "<variable>")):
                    found.add((rel, prefix + fn))
            visit(c, fn, rel, prefix, consts)

    files = subprocess.run(["git", "-C", root, "ls-files", "src"], capture_output=True, text=True, timeout=120,
                           env=GIT_ENV).stdout.split()
    for rel in files:
        if "/tests/" in rel or not os.path.isfile(os.path.join(root, rel)):
            continue
        text = open(os.path.join(root, rel), errors="replace").read()
        if rel.endswith(".py"):
            tree = ast.parse(text)
            visit(tree, "<module>", rel, "", module_consts(tree))
            for n in tree.body:
                if (isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)
                        and ast.unparse(n.targets[0]).endswith("_SRC")):
                    try:
                        sub = ast.parse(n.value.value)
                    except SyntaxError as e:
                        unreadable.append(f"{rel} {ast.unparse(n.targets[0])}: {e}")
                        continue
                    visit(sub, "<module>", rel, ast.unparse(n.targets[0]) + ":", module_consts(sub))
        elif rel.endswith(".sh"):
            fn = "<top>"
            for line in text.splitlines():
                m = SHDEF.match(line)
                if m:
                    fn = m.group(1)
                if re.search(r"setxattr\(.*security\.selinux|\bsetfattr |\bchcon ", line):
                    found.add((rel, fn))
    return found, unreadable


def inventory_findings(root):
    """return each unclassified write, stale row and missing guard"""
    found, unreadable = write_sites(root)
    out = [f"cannot parse {u}" for u in unreadable]
    for key in sorted(found - set(SITES)):
        out.append(f"{key[0]} {key[1]}() writes security.selinux and is not classified here: a host-side Android label "
                   "fails with EINVAL on a host with its own policy")
    for key in sorted(set(SITES) - found):
        out.append(f"{key[0]} {key[1]}() is classified here but writes no label")
    for key, (reason, guards) in sorted(SITES.items()):
        for rel, fn, pattern in guards:
            text = function_text(root, rel, fn)
            if text is None or not re.search(pattern, text):
                out.append(f"{key[0]} {key[1]}() is classified as '{reason}', but {rel} {fn}() no longer holds /{pattern}/")
    return out


def run_case(root, tmp, kind, host_policy, fails):
    """stage an apk through an install path"""
    lib = os.path.join(tmp, "lib")
    run = os.path.join(tmp, "run")
    inbox = os.path.join(run, "data", "rhizo_inbox")
    attr, mode, apk = os.path.join(tmp, "attr"), os.path.join(tmp, "mode"), os.path.join(tmp, "a.apk")
    with open(attr, "w") as fh:
        fh.write("system_u:system_r:unconfined_t:s0\0" if host_policy else "kernel\0")
    script = os.path.join(tmp, "case.sh")
    py = "/usr/bin/python3"
    if kind == "cli":
        body = (f'RHIZO_CLI_SOURCE_ONLY=1 source {root}/src/install/cli/rhizo.sh || exit 91\n'
                f'RUN_ROOT={run}; INBOX_HOST_DIR={inbox}; INBOX_SANDBOX_DIR=/data/rhizo_inbox\n'
                f'( stage_into_inbox {apk} ) && echo STAGED || echo REFUSED\n')
    elif kind == "broker":
        body = f'{py} -c \'{BROKER}\' {lib}/broker/brokerd.py {run} {apk} {mode}\n'
    else:
        body = f"{py} -c '{STAGE}' {lib}/inbox_stage.py {run} {apk} {WANT}\n"
    with open(script, "w") as fh:
        fh.write(f"mount -t tmpfs tmpfs {run} || exit 90\nmkdir -p {inbox}\n{body}"
                 f"for f in {inbox}/*; do [ -e \"$f\" ] || continue; echo ENTRY $(basename $f); "
                 f"{py} -I -c 'import os,sys; print(\"STORED\", os.getxattr(sys.argv[1], \"security.selinux\")"
                 f".rstrip(b\"\\0\").decode())' \"$f\" 2>/dev/null || echo 'STORED none'; done\n")
    env = dict(os.environ, RHIZO_SELINUX_MODE_FILE=mode, RHIZO_ATTR_CURRENT=attr, RHIZO_LIB_DIR=lib,
               PYTHONPATH=os.path.join(tmp, "site"),
               FAKE_HOST_POLICY="1" if host_policy else "0", FAKE_POLICY_FAILS="1" if fails else "0")
    env.pop("RHIZO_LAUNCHER", None)
    r = subprocess.run(["unshare", "-Urm", "bash", script], capture_output=True, text=True, env=env, timeout=120)
    stored = re.findall(r"^STORED (\S+)$", r.stdout, re.M)
    entries = re.findall(r"^ENTRY (\S+)$", r.stdout, re.M)
    return r, stored, entries


def stage_findings(root):
    """return the install paths that mislabel the inbox file"""
    out = []
    for kind in ("stage", "cli", "broker"):
        for host_policy, fails in ((False, False), (True, False), (True, True)):
            with tempfile.TemporaryDirectory() as tmp:
                for d in ("site", "lib", "run"):
                    os.makedirs(os.path.join(tmp, d))
                with open(os.path.join(tmp, "site", "sitecustomize.py"), "w") as fh:
                    fh.write(SITE)
                with open(os.path.join(tmp, "lib", "launcher3.py"), "w") as fh:
                    fh.write(LAUNCHER)
                shutil.copy(os.path.join(root, "src", "services", "broker", "inbox_stage.py"), os.path.join(tmp, "lib"))
                os.makedirs(os.path.join(tmp, "lib", "broker"))
                shutil.copy(os.path.join(root, "src", "services", "broker", "brokerd.py"),
                            os.path.join(tmp, "lib", "broker"))
                with open(os.path.join(tmp, "mode"), "w") as fh:
                    fh.write("namespace\n")
                with open(os.path.join(tmp, "a.apk"), "wb") as fh:
                    fh.write(b"apk bytes")
                r, stored, entries = run_case(root, tmp, kind, host_policy, fails)
            where = (f"the {kind} install on a host {'with' if host_policy else 'without'} its own policy"
                     f"{', in-android-policy failing' if fails else ''}")
            if fails:
                if "STAGED" in r.stdout or "SANDBOX" in r.stdout or entries:
                    out.append(f"{where} succeeds or leaves {entries} in the inbox: {r.stdout.strip()[-200:]!r}")
            elif stored != [WANT]:
                out.append(f"{where} stores {stored}, want [{WANT}] ({r.stdout.strip()[-200:]!r} "
                           f"{r.stderr.strip()[-200:]!r})")
    return out


def selftest(root):
    """check each defect is flagged and the real tree is clean"""
    bad = inventory_findings(root) + stage_findings(root)
    if bad:
        print(f"FAIL selftest: the real tree is flagged: {bad}")
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(f"git ls-files -z src | xargs -0 cp --parents -t {tmp}", shell=True, check=True, cwd=root,
                       capture_output=True, timeout=120, env=GIT_ENV)
        subprocess.run(["git", "init", "-q", tmp], check=True, timeout=60, env=GIT_ENV)
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, timeout=120, env=GIT_ENV)
        path = os.path.join(tmp, "src", "services", "broker", "inbox_stage.py")
        text = open(path).read()
        mutant = re.sub(r"label_in_android_policy\(out, label[^)]*\) if host_policy_loaded\(\) else ", "", text, count=1)
        if mutant == text:
            print("FAIL selftest: the host-side mutant changed nothing")
            return 1
        with open(path, "w") as fh:
            fh.write(mutant)
        got = stage_findings(tmp)
        if not any("with its own policy:" in f or "with its own policy stores" in f for f in got):
            print(f"FAIL selftest: a host-side inbox label was not flagged: {got}")
            return 1
        mounts = os.path.join(tmp, "src", "androidd", "sandbox", "rootfs.py")
        launcher = os.path.join(tmp, "src", "androidd", "boot.py")
        text = open(launcher).read()
        for name, edit, want in (
                ("an unclassified write", (mounts, open(mounts).read() + '\n\ndef stray(path):\n'
                                           '    os.setxattr(path, "security.selinux", b"u:object_r:x:s0\\0")\n'),
                 "stray() writes security.selinux and is not classified"),
                ("a write through a variable name", (mounts, open(mounts).read() + '\n\ndef named(path, attr):\n'
                                                     '    os.setxattr(path, attr, b"u:object_r:x:s0\\0")\n'),
                 "named() writes security.selinux and is not classified"),
                ("an unparseable primer", (launcher, text.replace('HOST_PRIMER_SRC = r"""', 'HOST_PRIMER_SRC = r"""\n)(', 1)),
                 "cannot parse src/androidd/boot.py HOST_PRIMER_SRC")):
            path, body = edit
            saved = open(path).read()
            with open(path, "w") as fh:
                fh.write(body)
            got = inventory_findings(tmp)
            with open(path, "w") as fh:
                fh.write(saved)
            if not any(want in f for f in got):
                print(f"FAIL selftest: {name} was not flagged: {got}")
                return 1
    print("host-android-labels selftest: a host-side inbox label, an unclassified write, a write through a variable "
          "name and an unparseable primer are flagged, the real tree clean")
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()
    probe = subprocess.run(["unshare", "-Urm", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        print(f"FAIL unshare -Urm is refused here ({probe.stderr.strip() or probe.returncode})")
        return 1
    if args.selftest:
        return selftest(args.root)
    bad = inventory_findings(args.root) + stage_findings(args.root)
    for line in bad:
        print("FAIL", line)
    print("host-android-labels:", "FAIL" if bad else "ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
