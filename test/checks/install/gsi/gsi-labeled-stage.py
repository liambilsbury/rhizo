#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
LAUNCHER_DIR = os.path.join(REPO, "src", "androidd")
FETCH = os.path.join(REPO, "src", "install", "prepare", "fetch-gsi.sh")
NS_SRC = os.path.join(LAUNCHER_DIR, "sandbox/selinux_ns.py")
ENV_SRC = os.path.join(LAUNCHER_DIR, "sandbox/core.py")
LAUNCHER_SRC = os.path.join(LAUNCHER_DIR, "boot.py")
sys.path.insert(0, LAUNCHER_DIR)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-gsi-labeled-stage")

STUBS = r'''
log() { :; }
failstop() { echo "failstop $1" >> "$CALLS"; exit 1; }
python3() { echo "python3 $*" >> "$CALLS"; case " $* " in *" loop-attach "*) echo /dev/loop9 ;; esac; }
mount() { echo "mount $*" >> "$CALLS"; }
umount() { echo "umount $*" >> "$CALLS"; }
cp() { echo "cp $*" >> "$CALLS"; }
mkdir() { :; }
'''


def shell_fn(text, name):
    """return the text of the shell function name, or empty"""
    m = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", text, re.M | re.S) or re.search(rf"^{name}\(\) \{{.*\}}\n", text, re.M)
    return m.group(0) if m else ""


def copy_calls(text, ctx):
    """return the commands copy_tree runs under a context"""
    with tempfile.TemporaryDirectory() as tmp:
        attr, calls = f"{tmp}/attr", f"{tmp}/calls"
        if ctx is not None:
            with open(attr, "w") as f:
                f.write(ctx + "\0")
        open(calls, "w").close()
        os.makedirs(f"{tmp}/t/mnt/system")
        script = (STUBS + shell_fn(text, "hostops") + shell_fn(text, "host_policy") +
                  shell_fn(text, "copy_tree") +
                  f'TMP={tmp}/t; TREE=/srv/rhizo/gsi_system; LAUNCHER=/usr/lib/rhizo/launcher3.py\ncopy_tree\n')
        subprocess.run(["bash", "-c", script], env=dict(os.environ, RHIZO_ATTR_CURRENT=attr, CALLS=calls),
                       capture_output=True, text=True, timeout=30)
        with open(calls) as f:
            return f.read().replace(f"{tmp}/t", "/t")


def fetch_findings(text):
    """return every finding for the fetch script's staging copy"""
    if not shell_fn(text, "copy_tree") or not shell_fn(text, "host_policy") or not shell_fn(text, "hostops"):
        return ["fetch-gsi.sh: no copy_tree(), host_policy() and hostops() to test"]
    out = []
    labeled = copy_calls(text, "system_u:system_r:initrc_t:s0")
    if "stage-gsi-labeled /t/system.img /srv/rhizo/gsi_system.part /t" not in labeled:
        out.append("fetch-gsi.sh: a host with its own policy does not stage through stage-gsi-labeled")
    if "cp -a" in labeled or "loop-attach" in labeled:
        out.append("fetch-gsi.sh: a host with its own policy copies with a plain mount and cp -a")
    for ctx, name in (("kernel", "a host with no policy"), (None, "a host with no attr/current")):
        plain = copy_calls(text, ctx)
        if "stage-gsi-labeled" in plain or not all(s in plain for s in (
                "loop-attach -r /t/system.img", "mount -r -t ext4 /dev/loop9 /t/mnt",
                "cp -a /t/mnt/system /srv/rhizo/gsi_system.part", "loop-detach /dev/loop9")):
            out.append(f"fetch-gsi.sh: {name} does not stage with the in-process mount and cp -a")
    outside = text.replace(shell_fn(text, "copy_tree"), "")
    if not re.search(r"^copy_tree$", outside, re.M):
        out.append("fetch-gsi.sh: the staging never calls copy_tree")
    if re.search(r"cp -a|mount -o ro,loop|loop-attach", outside):
        out.append("fetch-gsi.sh: a copy or loop mount outside copy_tree")
    return out


def load_module(path, name):
    """import the launcher module at path under name"""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


def stage_events(ns):
    """run stage_gsi_labeled against fakes"""
    events = []
    with tempfile.TemporaryDirectory() as work:
        policy = f"{work}/precompiled_sepolicy.abc"
        with open(policy, "wb") as f:
            f.write(b"POLICY")

        def fake_mount(src, target, fstype, flags, data=None):
            """record a mount and give an image mount its system dir"""
            events.append(("mount", src, os.path.relpath(target, work) if target.startswith(work) else target, fstype))
            if fstype == "ext4":
                os.makedirs(f"{target}/system", exist_ok=True)
            return True

        def fake_attach(image, read_only=False, autoclear=False, ctl=None):
            """record a loop attach and hand back a real fd"""
            events.append(("loop", image, read_only, autoclear))
            return "/dev/loop9", os.open(os.devnull, os.O_RDONLY)

        def fake_run(argv, env=None, capture_output=False, text=False):
            """record a command"""
            if argv[-1] == "prepare-sepolicy":
                events.append(("compile", os.path.relpath(env["RHIZO_GSI"], work)))
                return subprocess.CompletedProcess(argv, 0, f"PREPARE_SEPOLICY_OK cache={policy}\n", "")
            events.append(("run", tuple(os.path.relpath(a, work) if a.startswith(work) else a for a in argv),
                           bool(loads)))
            return subprocess.CompletedProcess(argv, 0, "", "")

        def fake_load(path):
            """record the policy loaded into the namespace"""
            loads.append(open(path, "rb").read())
            events.append(("load",))

        def fake_enter(request, context):
            """record the helper domain entered and report success"""
            events.append(("setcon", context))
            return ""

        loads = []
        saved = (ns.os.unshare, ns.mount, ns.core.loop_attach, ns.unshare_namespace, ns.load_namespace_policy,
                 ns.enter_helper_domain)
        ns.os.unshare = lambda flags: events.append(("unshare-mounts", flags))
        ns.mount = fake_mount
        ns.core.loop_attach = fake_attach
        ns.unshare_namespace = lambda state_file=None: events.append(("selinuxns", state_file))
        ns.load_namespace_policy = fake_load
        ns.enter_helper_domain = fake_enter
        try:
            why = ns.stage_gsi_labeled(f"{work}/system.img", "/srv/rhizo/gsi_system.part", work, "/l/launcher3.py",
                                        python="/usr/bin/python3", run=fake_run)
        finally:
            (ns.os.unshare, ns.mount, ns.core.loop_attach, ns.unshare_namespace,
             ns.load_namespace_policy, ns.enter_helper_domain) = saved
        loaded = loads[0] if loads else None
    return why, events, loaded


def stage_findings(ns):
    """return every finding for stage_gsi_labeled's order of work"""
    if not hasattr(ns, "stage_gsi_labeled") or not hasattr(ns.core, "loop_attach"):
        return ["sandbox/selinux_ns.py: no stage_gsi_labeled() and core.loop_attach() to test"]
    why, ev, loaded = stage_events(ns)
    out = []
    if why is not None:
        return [f"stage_gsi_labeled: fails on the fakes: {why}"]
    kinds = [e[0] for e in ev]
    if kinds[:2] != ["unshare-mounts", "mount"] or ev[1][1:] != (None, "/", None):
        out.append("stage_gsi_labeled: the image mounts are not made in a private mount namespace first")
    image_mounts = [e[2] for e in ev if e[0] == "mount" and e[3] == "ext4"]
    loops = [e for e in ev if e[0] == "loop"]
    if len(image_mounts) != 2 or len(set(image_mounts)) != 2 or any(not (l[2] and l[3]) for l in loops):
        out.append("stage_gsi_labeled: the image is not mounted twice, read-only, through autoclear loops")
    compiles = [e for e in ev if e[0] == "compile"]
    cps = [e for e in ev if e[0] == "run" and e[1][:2] == ("cp", "-a")]
    if len(compiles) != 1 or len(cps) != 1:
        return out + ["stage_gsi_labeled: not one compile and one cp -a"]
    if cps[0][1][2] == compiles[0][1]:
        out.append("stage_gsi_labeled: the copy reads the mount the compile ran from")
    if cps[0][1][2] not in (f"{m}/system" for m in image_mounts) or cps[0][1][3] != "/srv/rhizo/gsi_system.part":
        out.append("stage_gsi_labeled: the copy is not image/system to dest")
    if "selinuxns" not in kinds or not kinds.index("compile") < kinds.index("selinuxns") < kinds.index("run"):
        return out + ["stage_gsi_labeled: the copy does not run in a child SELinux namespace made after the compile"]
    if not cps[0][2] or loaded != b"POLICY":
        out.append("stage_gsi_labeled: the copy runs before the compiled policy is loaded into the namespace")
    if "load" not in kinds or kinds.index("load") < kinds.index("selinuxns"):
        out.append("stage_gsi_labeled: the policy is not loaded after the unshare")
    setcons = [e for e in ev if e[0] == "setcon"]
    if [e[1] for e in setcons] != [b"u:r:rhizo_ns_stage:s0"]:
        out.append(f"stage_gsi_labeled: the copy's namespace is not entered as rhizo_ns_stage once: {setcons}")
    elif "load" in kinds and not kinds.index("load") < kinds.index("setcon") < kinds.index("run"):
        out.append("stage_gsi_labeled: the copy does not run after the load and the helper domain's setcon")
    if any(e[0] == "mount" and e[3] == "selinuxfs" for e in ev):
        out.append("stage_gsi_labeled: a selinuxfs is mounted where a kill could leave it behind")
    return out


def config_findings(env):
    """return every finding for the loop_config layout"""
    if not hasattr(env, "loop_config"):
        return ["sandbox/core.py: no loop_config() to test"]
    cfg = env.loop_config(7, env.LO_FLAGS_READ_ONLY | env.LO_FLAGS_AUTOCLEAR)
    out = []
    if len(cfg) != 304:
        out.append(f"loop_config: {len(cfg)} bytes, struct loop_config is 304")
    elif struct.unpack_from("=I", cfg, 0)[0] != 7 or struct.unpack_from("=I", cfg, 60)[0] != 5:
        out.append("loop_config: the backing fd is not at offset 0 or lo_flags not at offset 60")
    return out


def verb_findings(text):
    """return a finding when boot.py has no stage-gsi-labeled verb"""
    if not re.search(r'sys\.argv\[1\] == "stage-gsi-labeled".*\n.*selinux_ns\.stage_gsi_labeled\(', text):
        return ["boot.py: no stage-gsi-labeled verb calling selinux_ns.stage_gsi_labeled"]
    return []


def all_findings(fetch_text, ns, env, launcher_text):
    """return every finding"""
    return fetch_findings(fetch_text) + stage_findings(ns) + config_findings(env) + verb_findings(launcher_text)


def read(path):
    """return a file's text"""
    with open(path) as f:
        return f.read()


def mutant(src, old, new, name, tmp):
    """load a copy of the module at src with old replaced by new"""
    text = read(src)
    assert old in text, f"selftest mutation anchor missing in {src}: {old}"
    path = os.path.join(tmp, f"{name}.py")
    with open(path, "w") as f:
        f.write(text.replace(old, new, 1))
    return load_module(path, name)


def selftest(fetch_text, ns, env, launcher_text):
    """flag each mutant by name and the current code not at all"""
    def expect(what, finding, found):
        """exit 1 unless finding is among found"""
        if not any(finding in f for f in found):
            sys.exit(f"check-gsi-labeled-stage: FAIL selftest: {what} was not flagged: {found or '<no finding>'}")
    plain = fetch_text.replace("  if host_policy; then", "  if false; then", 1)
    expect("a copy that ignores the host's policy", "a host with its own policy copies with a plain mount and cp -a",
           fetch_findings(plain))
    with tempfile.TemporaryDirectory() as tmp:
        same = mutant(NS_SRC, 'run(["cp", "-a", f"{copy_mnt}/system", dest])',
                      'run(["cp", "-a", f"{compile_mnt}/system", dest])', "ns_same_mount", tmp)
        expect("a copy of the compile's mount", "the copy reads the mount the compile ran from", stage_findings(same))
        no_ns = mutant(NS_SRC, "    unshare_namespace(state_file=None)\n", "", "ns_no_child", tmp)
        expect("a copy in the host's namespace", "does not run in a child SELinux namespace", stage_findings(no_ns))
        no_load = mutant(NS_SRC, "    why = load_namespace_policy(policy)\n", "    why = None\n", "ns_no_load", tmp)
        expect("a copy before the load", "the copy runs before the compiled policy is loaded", stage_findings(no_load))
        no_setcon = mutant(NS_SRC, "    why = enter_helper_domain(request, context)\n", '    why = ""\n', "ns_no_setcon", tmp)
        expect("a copy that stays kernel", "is not entered as rhizo_ns_stage", stage_findings(no_setcon))
        wrong_helper = mutant(NS_SRC, 'enter_policy_namespace(m.group(1), "stage")',
                              'enter_policy_namespace(m.group(1), "label")', "ns_wrong_helper", tmp)
        expect("a copy in the label domain", "is not entered as rhizo_ns_stage", stage_findings(wrong_helper))
        bad_cfg = mutant(ENV_SRC, "0, 0, 0, 0, 0, 0, 0, 0, flags,", "0, 0, 0, 0, 0, 0, 0, flags, 0,", "env_bad_cfg", tmp)
        expect("lo_flags at the wrong offset", "lo_flags not at offset 60", config_findings(bad_cfg))
    expect("a launcher without the verb", "no stage-gsi-labeled verb",
           verb_findings(launcher_text.replace('"stage-gsi-labeled"', '"stage-gsi"')))
    found = all_findings(fetch_text, ns, env, launcher_text)
    if found:
        sys.exit(f"check-gsi-labeled-stage: FAIL selftest: the current code has findings: {found}")
    print("check-gsi-labeled-stage: selftest ok")


def main():
    """run the check or its selftest"""
    ns = load_module(NS_SRC, "sandbox.selinux_ns")
    env = sys.modules["sandbox.core"]
    args = (read(FETCH), ns, env, read(LAUNCHER_SRC))
    if sys.argv[1:] == ["--selftest"]:
        selftest(*args)
        return 0
    found = all_findings(*args)
    if found:
        print("check-gsi-labeled-stage: FAIL")
        for f in found:
            print(f"  {f}")
        return 1
    print("check-gsi-labeled-stage: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
