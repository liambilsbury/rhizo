#!/usr/bin/env python3
import errno
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
ENV = os.path.join(ROOT, "src", "androidd", "sandbox", "core.py")
HOSTOPS = os.path.join(ROOT, "src", "install", "prepare", "hostops.py")
TEMPLATE = os.path.join(ROOT, "src", "install", "prepare", "data-template.sh")
FAKE_HOSTOPS = r'''
import os, sys
verb = sys.argv[1]
with open(os.environ["HOSTOPS_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if verb == os.environ.get("HOSTOPS_FAIL"):
    sys.exit(1)
if verb == "loop-find":
    print("/dev/loop7")
elif verb == "loop-attach":
    print("/dev/loop9")
'''
FAKE_MATERIALIZE = r'''
import sys
BUILDER_VERSION = "1"
print("MATERIALIZE_OK")
print("MODULE com.example.one " + "a" * 64)
'''


def load_env(path, name):
    """return core loaded from a file"""
    sys.path.insert(0, os.path.dirname(ENV))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def scan_findings(env):
    """return the loops_backed_by findings"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        target = os.path.join(tmp, "data.img")
        open(target, "w").close()
        st = os.stat(target)
        sysblock = os.path.join(tmp, "block")
        backing = {"loop0": target, "loop1": "/moved/data.img", "loop3": "/other/a.img", "loop5": "/other/b.img"}
        for name, value in backing.items():
            os.makedirs(os.path.join(sysblock, name, "loop"))
            with open(os.path.join(sysblock, name, "loop", "backing_file"), "w") as f:
                f.write(value + "\n")
        os.makedirs(os.path.join(sysblock, "loop2", "loop"))
        os.symlink(os.path.join(tmp, "gone"), os.path.join(sysblock, "loop2", "loop", "backing_file"))
        os.makedirs(os.path.join(sysblock, "sda"))

        def backing_id(dev):
            """return a fake device and inode per loop"""
            if dev == "/dev/loop1":
                return (st.st_dev, st.st_ino)
            if dev == "/dev/loop3":
                raise OSError(errno.ENXIO, "No such device or address")
            return (st.st_dev, st.st_ino + 1)

        try:
            got = env.loops_backed_by(target, sysblock, backing_id=backing_id)
        except TypeError as e:
            return [f"loops_backed_by takes no backing_id: {e}"]
        except OSError as e:
            return [f"loops_backed_by fails the listing on a loop that detached: {e}"]
        if got != ["/dev/loop0", "/dev/loop1"]:
            bad.append(f"loops_backed_by finds {got}, not ['/dev/loop0', '/dev/loop1'] (by name and by inode)")

        def denied(dev):
            """raise a permission error"""
            raise OSError(errno.EACCES, "Permission denied")

        try:
            env.loops_backed_by(target, sysblock, backing_id=denied)
            bad.append("loops_backed_by lists past a loop it may not read")
        except OSError:
            pass
    return bad


def hostops_findings(hostops):
    """return the findings for a bare loop-attach"""
    r = subprocess.run([sys.executable, hostops, "loop-attach"], capture_output=True, text=True, timeout=60)
    if r.returncode != 2 or "Traceback" in r.stderr:
        return [f"a bare loop-attach ends rc={r.returncode} with {r.stderr.strip()[-160:]!r}, not a usage refusal rc=2"]
    return []


def template_run(template, fail_verb, mounted):
    """run the data template with fake host tools"""
    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, "rhizo-data-template.sh")
        with open(template) as f:
            text = f.read().replace('MOUNTPOINT="/mnt/rhizo-template-build"', f'MOUNTPOINT="{tmp}/mnt"')
        with open(script, "w") as f:
            f.write(text)
        os.makedirs(os.path.join(tmp, "gsi", "apex"))
        with open(os.path.join(tmp, "gsi", "build.prop"), "w") as f:
            f.write("ro.system.build.fingerprint=check/fp\n")
        for name, body in (("hostops.py", FAKE_HOSTOPS), ("materialize.py", FAKE_MATERIALIZE)):
            with open(os.path.join(tmp, name), "w") as f:
                f.write(body)
        bindir = os.path.join(tmp, "bin")
        os.mkdir(bindir)
        stubs = {"systemctl": "echo inactive", "systemd-run": "exit 0", "mountpoint": f"exit {0 if mounted else 1}"}
        for name, body in stubs.items():
            with open(os.path.join(bindir, name), "w") as f:
                f.write(f"#!/bin/sh\n{body}\n")
            os.chmod(os.path.join(bindir, name), 0o755)
        with open(os.path.join(tmp, "attr"), "w") as f:
            f.write("kernel")
        log = os.path.join(tmp, "calls")
        env = {"PATH": f"{bindir}:/usr/bin:/bin", "RHIZO_HOSTOPS": os.path.join(tmp, "hostops.py"),
               "CHECK_TEMPLATE_MATERIALIZE": os.path.join(tmp, "materialize.py"), "HOSTOPS_LOG": log,
               "HOSTOPS_FAIL": fail_verb, "RHIZO_ATTR_CURRENT": os.path.join(tmp, "attr"), "HOME": tmp}
        r = subprocess.run(["bash", script, "--apex-dir", os.path.join(tmp, "gsi", "apex"), "--format", "plain",
                            "--size", "1M", "--templates-dir", os.path.join(tmp, "templates")],
                           env=env, capture_output=True, text=True, timeout=120)
        calls = open(log).read().splitlines() if os.path.exists(log) else []
        built = os.path.exists(os.path.join(tmp, "templates")) and any(
            n.endswith(".img") for n in os.listdir(os.path.join(tmp, "templates")))
    lines = r.stdout.strip().splitlines()
    return (lines[-1] if lines else ""), calls, built


def template_findings(template):
    """return the template loop and mount findings"""
    bad = []
    last, calls, built = template_run(template, "", False)
    if not last.startswith("TEMPLATE_OK") or not built:
        bad.append(f"a clean build ends '{last}' (built={built}), calls {calls}")
    for verb, mounted, want, attached in (("loop-find", False, "TEMPLATE_FAILED reason=loop-find-failed", False),
                                          ("loop-detach", False, "TEMPLATE_FAILED reason=loop-detach-failed", False),
                                          ("umount", True, "TEMPLATE_FAILED reason=umount-failed", False),
                                          ("umount", False, "TEMPLATE_FAILED reason=umount-failed", True)):
        last, calls, built = template_run(template, verb, mounted)
        where = "a leftover" if not attached else "the built image's"
        if last != want or built:
            bad.append(f"a failed {verb} of {where} {'mount' if verb == 'umount' else 'loop'} ends '{last}' "
                       f"(built={built}), not '{want}'")
        if not attached and any(c.startswith("loop-attach") for c in calls):
            bad.append(f"a failed {verb} of {where} still attaches a loop: {calls}")
    return bad


def check(env_path=ENV, hostops=HOSTOPS, template=TEMPLATE, name="_loop_helpers_env"):
    """return every finding"""
    return scan_findings(load_env(env_path, name)) + hostops_findings(hostops) + template_findings(template)


def selftest():
    """flag each mutant and pass the real sources"""
    env_src, hostops_src, template_src = (open(p).read() for p in (ENV, HOSTOPS, TEMPLATE))
    cases = (
        ("name-only match", "env", '''        if want is None:
            continue
''', '''        continue
''', "not ['/dev/loop0', '/dev/loop1']"),
        ("listing failing on a detached loop", "env", '''        except FileNotFoundError:
            continue
        if backing == path:
''', '''        except IsADirectoryError:
            continue
        if backing == path:
''', "fails the listing on a loop that detached"),
        ("bare loop-attach traceback", "hostops",
         '(len(args) == 1 or (len(args) == 2 and args[0] == "-r"))', 'args in ([args[-1]], ["-r", args[-1]])',
         "a bare loop-attach ends rc=1"),
        ("ignored loop-find failure", "template", '''if ! leftovers=$(hostops loop-find "$PART"); then''',
         '''if ! leftovers=$(hostops loop-find "$PART" || true); then''', "a failed loop-find of a leftover loop ends"),
    )
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "install", "prepare"))
        os.makedirs(os.path.join(tmp, "androidd", "sandbox"))
        for n, (label, which, old, new, needle) in enumerate(cases):
            srcs = {"env": env_src, "hostops": hostops_src, "template": template_src}
            if srcs[which].count(old) != 1:
                return [f"the {label} mutant found {srcs[which].count(old)} anchors"]
            srcs[which] = srcs[which].replace(old, new)
            paths = {"env": os.path.join(tmp, "androidd", "sandbox", "core.py"),
                     "hostops": os.path.join(tmp, "install", "prepare", "hostops.py"),
                     "template": os.path.join(tmp, "install", "prepare", "data-template.sh")}
            for key, path in paths.items():
                with open(path, "w") as f:
                    f.write(srcs[key])
            got = check(paths["env"], paths["hostops"], paths["template"], f"_loop_helpers_m{n}")
            if not any(needle in g for g in got):
                bad.append(f"the {label} mutant was not flagged: {got}")
            sys.modules.pop("sandbox.core", None)
        shutil.rmtree(os.path.join(tmp, "install"))
    real = check()
    if real:
        bad.append(f"the real sources have findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
