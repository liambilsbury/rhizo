#!/usr/bin/env python3
import contextlib, io, os, subprocess, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
HELPER = os.path.join(LAUNCHER, "host", "selinux-mode.py")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-selinux-mode")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

bad = []
real_supported = ns.namespace_supported
real_landlock_abi = ns.landlock_abi
real_host_context = ns.host_context
real_host_policy_state = ns.host_policy_state

try:
    got = real_supported()
    if not isinstance(got, bool):
        bad.append(("real namespace_supported type", bool, type(got)))
    try:
        lsms = open("/sys/kernel/security/lsm").read().split(",")
    except OSError:
        lsms = None
    if lsms is not None and "selinux" not in [x.strip() for x in lsms] and got is not False:
        bad.append(("real namespace_supported without selinux", False, got))
except Exception as e:
    bad.append(("real namespace_supported raised", "no exception", repr(e)))


def run(supported, host_ctx, mode, abi=6):
    """return selinux_mode under stubbed kernel answers"""
    ns.namespace_supported = lambda: supported
    ns.landlock_abi = lambda: abi
    ns.host_context = lambda: host_ctx
    return ns.selinux_mode({"RHIZO_SELINUX_MODE": mode} if mode is not None else {})


def helper(env_text, args, env_extra=None):
    """return the helper's exit code and stdout for an env file with env_text"""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "androidd.env")
        open(path, "w").write(env_text)
        env = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
        env.update(env_extra or {})
        r = subprocess.run([sys.executable, HELPER, "--env-file", path] + args, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return r.returncode, r.stdout


cases = [
    ((True, "kernel", "namespace"), "namespace"),
    ((True, "kernel", None), "namespace"),
    ((False, "kernel", "namespace"), "refuse:kernel-has-no-selinux-namespaces"),
    ((True, "u:r:rhizo_host:s0", "namespace"), "namespace"),
    ((True, "kernel", "host"), "host"),
    ((False, "kernel", "bogus"), "refuse:unknown-mode-bogus"),
    ((True, "kernel", "namespace", 0), "refuse:kernel-has-no-landlock"),
    ((True, "kernel", "namespace", 5), "refuse:kernel-has-no-landlock"),
]
bad += [(a, want, run(*a)) for a, want in cases if run(*a) != want]

texts = {
    "kernel-has-no-selinux-namespaces": "boot the Rhizo kernel (uname -r ends in -rhizo) to start Android",
    "unknown-mode-bogus": "RHIZO_SELINUX_MODE=bogus is not namespace or host",
    "kernel-has-no-landlock": "the Rhizo kernel runs without Landlock ABI 6; remove lsm= from its boot line or add landlock to it",
}
bad += [("refusal_text " + r, t, ns.refusal_text(r)) for r, t in texts.items() if ns.refusal_text(r) != t]

with tempfile.TemporaryDirectory() as d:
    node = os.path.join(d, "enforce")
    for ctx, val, want in (("kernel", None, "none"), ("u:r:init_t:s0", "0\n", "permissive"),
                           ("u:r:init_t:s0", "1\n", "enforcing"), ("u:r:init_t:s0", None, "unknown")):
        if os.path.exists(node):
            os.unlink(node)
        if val is not None:
            open(node, "w").write(val)
        ns.host_context = lambda c=ctx: c
        got = ns.host_policy_state(node)
        if got != want:
            bad.append(("host_policy_state " + want, want, got))
    for val, want in (("0\n", "permissive"), ("1\n", "enforcing")):
        open(node, "w").write(val)
        got = run(True, "u:r:init_t:s0", None), ns.host_policy_state(node)
        if got != ("namespace", want):
            bad.append(("selinux_mode never refuses a host policy state " + want, ("namespace", want), got))

expect = [
    ("host env, --is host", "RHIZO_SELINUX_MODE=host\n", ["--is", "host"], None, (0, "")),
    ("host env, --is namespace", "RHIZO_SELINUX_MODE=host\n", ["--is", "namespace"], None, (1, "")),
    ("host env, plain run prints one line", "RHIZO_SELINUX_MODE=host\n", [], None, (0, "host\n")),
    ("process env overrides file, plain", "RHIZO_SELINUX_MODE=host\n", [], {"RHIZO_SELINUX_MODE": "bogus"},
     (0, "refuse:unknown-mode-bogus\n")),
    ("process env overrides file, --is host", "RHIZO_SELINUX_MODE=host\n", ["--is", "host"],
     {"RHIZO_SELINUX_MODE": "bogus"}, (1, "")),
    ("refused mode, --is namespace", "RHIZO_SELINUX_MODE=bogus\n", ["--is", "namespace"], None, (1, "")),
    ("refused mode, --is host", "RHIZO_SELINUX_MODE=bogus\n", ["--is", "host"], None, (1, "")),
    ("refused mode, --is-startable", "RHIZO_SELINUX_MODE=bogus\n", ["--is-startable"], None, (1, "")),
    ("double-quoted value", 'RHIZO_SELINUX_MODE="host"\n', [], None, (0, "host\n")),
    ("single-quoted value", "RHIZO_SELINUX_MODE='host'\n", [], None, (0, "host\n")),
]
for name, text, args, extra, want in expect:
    got = helper(text, args, extra)
    if got != want:
        bad.append((name, want, got))

got = real_landlock_abi()
if not isinstance(got, int) or got < 0:
    bad.append(("real landlock_abi", "an int >= 0", got))
r = subprocess.run([sys.executable, HELPER, "--landlock-abi"], capture_output=True, text=True)
if (r.returncode, r.stdout) != (0, "%d\n" % got):
    bad.append(("helper --landlock-abi", (0, "%d\n" % got), (r.returncode, r.stdout, r.stderr[-200:])))

r = subprocess.run([sys.executable, HELPER, "--bogus"], capture_output=True)
if r.returncode != 255:
    bad.append(("helper usage error exits 255", 255, r.returncode))
with tempfile.TemporaryDirectory() as d:
    env_ns = os.path.join(d, "ns.env")
    open(env_ns, "w").write("RHIZO_SELINUX_MODE=bogus\n")
    r = subprocess.run([sys.executable, HELPER, "--env-file", env_ns, "--why"], capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"})
    if r.stdout.strip() != "RHIZO_SELINUX_MODE=bogus is not namespace or host":
        bad.append(("helper --why", "the refusal text", r.stdout))
    open(env_ns, "w").write("RHIZO_SELINUX_MODE=host\n")
    r = subprocess.run([sys.executable, HELPER, "--env-file", env_ns, "--why"], capture_output=True, text=True,
                       env={k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"})
    if r.stdout != "":
        bad.append(("helper --why prints nothing without a refusal", "", r.stdout))
    clean = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
    for text, want in (("RHIZO_SELINUX_MODE=bogus\n", "\tRHIZO_SELINUX_MODE=bogus is not namespace or host\n"),
                       ("RHIZO_SELINUX_MODE=host\n", "\n")):
        open(env_ns, "w").write(text)
        mode = subprocess.run([sys.executable, HELPER, "--env-file", env_ns], capture_output=True, text=True,
                              env=clean).stdout.strip()
        r = subprocess.run([sys.executable, HELPER, "--env-file", env_ns, "--mode-and-why"], capture_output=True,
                           text=True, env=clean)
        if (r.returncode, r.stdout) != (0, mode + want):
            bad.append(("helper --mode-and-why for " + text.strip(), (0, mode + want), (r.returncode, r.stdout)))
    for text, want in (("RHIZO_SELINUX_MODE=host\n", "host"), ("", "namespace")):
        open(env_ns, "w").write(text)
        r = subprocess.run([sys.executable, HELPER, "--env-file", env_ns, "--configured"], capture_output=True,
                           text=True, env={k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"})
        if r.stdout.strip() != want:
            bad.append(("helper --configured", want, r.stdout))
    for label, env_path, want in (("a missing env file", os.path.join(d, "absent.env"), (0, "namespace", False)),
                                  ("an unreadable env file", d, (1, "", True))):
        r = subprocess.run([sys.executable, HELPER, "--env-file", env_path, "--configured"], capture_output=True,
                           text=True, env={k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"})
        got = (r.returncode, r.stdout.strip(), env_path in r.stderr)
        if got != want:
            bad.append(("helper --configured with " + label, want, got))

import importlib.util
spec = importlib.util.spec_from_file_location("rhizo_selinux_mode_helper", HELPER)
helper_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper_mod)


for state in ("none", "permissive", "enforcing", "unknown"):
    ns.host_policy_state = lambda node=None, s=state: s
    out, saved = io.StringIO(), sys.argv
    sys.argv = [HELPER, "--host-state"]
    try:
        with contextlib.redirect_stdout(out):
            helper_mod.main()
    finally:
        sys.argv = saved
    if out.getvalue() != state + "\n":
        bad.append(("helper --host-state " + state, state + "\n", out.getvalue()))
ns.host_policy_state = real_host_policy_state


def write_mode(env_text, supported, host_ctx, stale):
    """run the helper's --write-mode-file under stubbed kernel answers"""
    run(supported, host_ctx, None)
    with tempfile.TemporaryDirectory() as d:
        env_path, mode_path = os.path.join(d, "androidd.env"), os.path.join(d, "run", "rhizo-selinux-mode")
        open(env_path, "w").write(env_text)
        if stale:
            os.makedirs(os.path.dirname(mode_path))
            open(mode_path, "w").write("namespace\n")
        saved = sys.argv, os.environ.pop("RHIZO_SELINUX_MODE", None), os.environ.get("RHIZO_SELINUX_MODE_FILE")
        sys.argv = [HELPER, "--env-file", env_path, "--write-mode-file"]
        os.environ["RHIZO_SELINUX_MODE_FILE"] = mode_path
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                helper_mod.main()
        except SystemExit as e:
            return "exit %s" % e.code, err.getvalue()
        finally:
            sys.argv = saved[0]
            if saved[1] is not None:
                os.environ["RHIZO_SELINUX_MODE"] = saved[1]
            if saved[2] is None:
                os.environ.pop("RHIZO_SELINUX_MODE_FILE", None)
            else:
                os.environ["RHIZO_SELINUX_MODE_FILE"] = saved[2]
        return (open(mode_path).read() if os.path.exists(mode_path) else None), err.getvalue()


def is_startable(env_text, supported, node_present):
    """return --is-startable's exit code and stderr under stubs"""
    run(supported, "kernel", None)
    saved_node = ns.HOST_ENFORCE_NODE
    with tempfile.TemporaryDirectory() as d:
        env_path, node = os.path.join(d, "androidd.env"), os.path.join(d, "enforce")
        open(env_path, "w").write(env_text)
        if node_present:
            open(node, "w").write("0\n")
        ns.HOST_ENFORCE_NODE = node
        saved = sys.argv, os.environ.pop("RHIZO_SELINUX_MODE", None)
        sys.argv = [HELPER, "--env-file", env_path, "--is-startable"]
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                helper_mod.main()
        except SystemExit as e:
            return e.code, err.getvalue().replace(node, "<node>")
        finally:
            sys.argv = saved[0]
            ns.HOST_ENFORCE_NODE = saved_node
            if saved[1] is not None:
                os.environ["RHIZO_SELINUX_MODE"] = saved[1]
        return "returned", err.getvalue()


for name, args, want in (
        ("host mode with the host enforce node", ("RHIZO_SELINUX_MODE=host\n", False, True), (0, "")),
        ("host mode on a boot with no host enforce node", ("RHIZO_SELINUX_MODE=host\n", False, False),
         (1, "host mode cannot start Android: no <node> on this boot\n")),
        ("namespace mode on a Rhizo kernel with no host enforce node", ("", True, False), (0, "")),
        ("namespace mode on a kernel without SELinux namespaces", ("", False, True), (1, ""))):
    got = is_startable(*args)
    if got != want:
        bad.append(("--is-startable, " + name, want, got))

got = write_mode("", True, "kernel", False)
if got[0] != "namespace\n":
    bad.append(("--write-mode-file on a namespace-capable kernel", "namespace\n", got))
got = write_mode("RHIZO_SELINUX_MODE=host\n", False, "kernel", True)
if got[0] != "host\n":
    bad.append(("--write-mode-file in host mode", "host\n", got))
got = write_mode("", False, "kernel", True)
if got[0] is not None or "kernel-has-no-selinux-namespaces" not in got[1]:
    bad.append(("--write-mode-file on a refusal removes the stale file and names the reason", (None, "the reason"), got))
with tempfile.TemporaryDirectory() as d:
    env_host, mode_path = os.path.join(d, "host.env"), os.path.join(d, "mode")
    open(env_host, "w").write("RHIZO_SELINUX_MODE=host\n")
    r = subprocess.run([sys.executable, HELPER, "--env-file", env_host, "--write-mode-file"], capture_output=True,
                       text=True, env=dict({k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"},
                                           RHIZO_SELINUX_MODE_FILE=mode_path))
    if r.returncode != 0 or not os.path.exists(mode_path) or open(mode_path).read() != "host\n":
        bad.append(("helper --write-mode-file exits 0 and writes the file", (0, "host\n"), (r.returncode, r.stderr[-200:])))

if ns.MODE_FILE != "/run/rhizo-selinux-mode":
    bad.append(("MODE_FILE", "/run/rhizo-selinux-mode", ns.MODE_FILE))
with tempfile.TemporaryDirectory() as d:
    ns.write_mode_file("namespace", path=os.path.join(d, "run", "rhizo-selinux-mode"))
    got = open(os.path.join(d, "run", "rhizo-selinux-mode")).read()
    if got != "namespace\n":
        bad.append(("write_mode_file", "namespace\n", got))

for b in bad:
    print("FAIL", b)
print("PASS" if not bad else "FAIL")
sys.exit(1 if bad else 0)
