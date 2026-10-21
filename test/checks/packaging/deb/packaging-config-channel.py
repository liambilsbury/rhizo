#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))

POSTINST = os.path.join(ROOT, "debian", "rhizo.postinst")
RULES = os.path.join(ROOT, "debian", "rules")
ANDROIDD_ENV_SRC = os.path.join(ROOT, "debian", "androidd.env")
HOSTFS_SERVICE = os.path.join(ROOT, "src", "services", "hostfs", "hostfs.service")
HOSTFS_PY = os.path.join(ROOT, "src", "services", "hostfs", "hostfs.py")
PREPARE_SH = os.path.join(ROOT, "src", "install", "prepare", "prepare.sh")
MODE_HELPER = os.path.join(ROOT, "src", "androidd", "host", "selinux-mode.py")
BUILTIN_DEFAULT_KNOBS = {"RHIZO_SELINUX_MODE": "namespace"}


def builtin_selinux_mode():
    """return rhizo-selinux-mode's configured default"""
    env = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
    r = subprocess.run([sys.executable, MODE_HELPER, "--env-file", os.devnull, "--configured"],
                       capture_output=True, text=True, env=env)
    return r.stdout.strip() if r.returncode == 0 else "error: rc=%d %s" % (r.returncode, r.stderr.strip())


def env_template_problems(tpl):
    """return the androidd.env template's active lines that change a default"""
    builtin = {"RHIZO_SELINUX_MODE": builtin_selinux_mode()}
    changed = []
    for ln in tpl.splitlines():
        line = ln.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        if BUILTIN_DEFAULT_KNOBS.get(key) != value or builtin.get(key) != value:
            changed.append(line)
    return changed

HOSTFS_CONF_WRITE = re.compile(
    r'(>\s*/etc/rhizo/hostfs\.conf'
    r'|\btouch\b[^\n]*hostfs\.conf'
    r'|\binstall\b[^\n]*hostfs\.conf)'
)


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def postinst_problems(postinst_path):
    """return the hostfs.conf problems found in the postinst"""
    fails = []
    postinst = maint_inline.inlined(postinst_path)
    bad = HOSTFS_CONF_WRITE.findall(postinst)
    if bad:
        fails.append(
            "debian/rhizo.postinst still writes /etc/rhizo/hostfs.conf "
            f"unconditionally ({bad!r})")
    if "default-config" not in postinst:
        fails.append(
            "debian/rhizo.postinst no longer points the admin at "
            "hostfs.py default-config")
    return fails


def check():
    """check the packaged configuration channel files"""
    fails = []
    looked_at = 0

    if not os.path.exists(POSTINST):
        print(f"no {POSTINST}", file=sys.stderr)
        return 1
    looked_at += 1
    fails += postinst_problems(POSTINST)

    looked_at += 1
    if not os.path.exists(HOSTFS_SERVICE):
        fails.append(f"no {HOSTFS_SERVICE} -- cannot confirm the unit still condition-skips")
    else:
        unit = read(HOSTFS_SERVICE)
        if "ConditionPathExists=/etc/rhizo/hostfs.conf" not in unit:
            fails.append(
                "rhizo-hostfs.service no longer names "
                "ConditionPathExists=/etc/rhizo/hostfs.conf")

    looked_at += 1
    if not os.path.exists(ANDROIDD_ENV_SRC):
        fails.append(
            "no debian/androidd.env")
    else:
        tpl = read(ANDROIDD_ENV_SRC)
        active = env_template_problems(tpl)
        if active:
            fails.append(
                "debian/androidd.env ships with active (uncommented) knob "
                f"line(s) {active!r}")
        if "RHIZO_" not in tpl:
            fails.append(
                "debian/androidd.env names no RHIZO_* knob at all")

    if not os.path.exists(RULES):
        fails.append(f"no {RULES} -- cannot confirm androidd.env is installed under /etc")
    else:
        rules = read(RULES)
        m = re.search(
            r'install\s+-D\s+-m\s*0644\s+debian/androidd\.env\s+'
            r'debian/rhizo/(etc/rhizo/androidd\.env)', rules)
        if not m:
            fails.append(
                "debian/rules does not install debian/androidd.env to "
                "debian/rhizo/etc/rhizo/androidd.env")
        else:
            with tempfile.TemporaryDirectory() as tmp:
                dest = os.path.join(tmp, "etc", "rhizo", "androidd.env")
                os.makedirs(os.path.dirname(dest))
                open(dest, "w").close()
                out = subprocess.run(
                    ["bash", "-c",
                     f'find {tmp}/etc -type f -printf "/etc/%P\\n" | LC_ALL=C sort'],
                    capture_output=True, text=True).stdout
                if "/etc/rhizo/androidd.env" not in out.split():
                    fails.append(
                        "dh_installdeb's own conffile auto-detection "
                        "(find $tmp/etc -type f) would not register "
                        "/etc/rhizo/androidd.env as a conffile from this "
                        "install destination")

    looked_at += 1
    if not os.path.exists(PREPARE_SH):
        fails.append(f"no {PREPARE_SH} -- cannot confirm the setup boot preserves androidd.env")
    else:
        prep = read(PREPARE_SH)
        clobber = re.search(
            r'printf [^\n]*RHIZO_WIPE_DATA=0[^\n]*>\s*"\$env_file"(?!\.)', prep)
        if clobber:
            fails.append(
                "src/install/prepare/prepare.sh still truncates $env_file "
                "with a single `>`")
        if not re.search(r'RHIZO_WIPE_DATA\|RHIZO_RESIDENT_G\|RHIZO_RESIDENT_DISPATCH', prep):
            fails.append(
                "src/install/prepare/prepare.sh no longer filters out its own "
                "three keys before re-adding them")
        with tempfile.TemporaryDirectory() as tmp:
            env_file = os.path.join(tmp, "androidd.env")
            with open(env_file, "w") as f:
                f.write("RHIZO_PERMISSIVE=1\nRHIZO_WIPE_DATA=1\n")
            script = f'''
set -euo pipefail
env_file="{env_file}"
if [[ -f "$env_file" ]]; then
  grep -Ev '^(RHIZO_WIPE_DATA|RHIZO_RESIDENT_G|RHIZO_RESIDENT_DISPATCH)=' \
    "$env_file" > "$env_file.rhizo-prepare.tmp" || true
else
  : > "$env_file.rhizo-prepare.tmp"
fi
printf 'RHIZO_WIPE_DATA=0\\nRHIZO_RESIDENT_G=1\\nRHIZO_RESIDENT_DISPATCH=1\\n' \
  >> "$env_file.rhizo-prepare.tmp"
mv "$env_file.rhizo-prepare.tmp" "$env_file"
'''
            subprocess.run(["bash", "-c", script], check=True)
            merged = read(env_file)
            if "RHIZO_PERMISSIVE=1" not in merged:
                fails.append(
                    "the merge shape itself drops an admin's unrelated knob "
                    "(RHIZO_PERMISSIVE=1 did not survive) -- fixture proof failed")
            if "RHIZO_WIPE_DATA=1" in merged or "RHIZO_WIPE_DATA=0" not in merged:
                fails.append(
                    "the merge shape does not override RHIZO_WIPE_DATA to 0 "
                    "for the setup boot -- fixture proof failed")

    looked_at += 1
    if not os.path.exists(HOSTFS_PY):
        fails.append(f"no {HOSTFS_PY} -- cannot confirm DEFAULT_DAEMON")
    else:
        src = read(HOSTFS_PY)
        if re.search(r'DEFAULT_DAEMON\s*=\s*"/root/share/rhizo-hostfsd"', src):
            fails.append(
                'hostfs.py hardcodes DEFAULT_DAEMON = '
                '"/root/share/rhizo-hostfsd"')
        else:
            for layout, sibling in (("rig", "share"), ("packaged", "host")):
                with tempfile.TemporaryDirectory() as tmp:
                    tools_dir = os.path.join(tmp, "tools")
                    sib_dir = os.path.join(tmp, sibling)
                    os.makedirs(tools_dir)
                    os.makedirs(sib_dir)
                    script_copy = os.path.join(tools_dir, "hostfs.py")
                    with open(script_copy, "w") as f:
                        f.write(src)
                    daemon_stub = os.path.join(sib_dir, "rhizo-hostfsd")
                    open(daemon_stub, "w").close()
                    out = subprocess.run(
                        ["python3", "-c",
                         "import importlib.util as u; "
                         f"s = u.spec_from_file_location('m', {script_copy!r}); "
                         "m = u.module_from_spec(s); s.loader.exec_module(m); "
                         "print(m.DEFAULT_DAEMON)"],
                        capture_output=True, text=True)
                    resolved = out.stdout.strip()
                    if resolved != daemon_stub and os.path.realpath(resolved) != os.path.realpath(daemon_stub):
                        fails.append(
                            f"DEFAULT_DAEMON resolved to {resolved!r} on a "
                            f"{layout} layout ({tools_dir} + {sib_dir}), "
                            f"not {daemon_stub!r} -- {out.stderr.strip()}")

    if not looked_at:
        print("no packaging-config-channel artifact was found under this tree", file=sys.stderr)
        return 1

    for line in fails:
        print(f"FAIL: {line}", file=sys.stderr)
    if fails:
        return 1
    print(f"packaging configuration channel is real and self-consistent "
          f"({looked_at} artifact group(s) checked)")
    return 0


OLD_POSTINST = '''#!/bin/sh
set -e
case "$1" in
  configure)
    mkdir -p /etc/rhizo
    if [ ! -e /etc/rhizo/hostfs.conf ]; then
      : > /etc/rhizo/hostfs.conf
    fi
    ;;
esac
exit 0
'''

OLD_PREPARE_SNIPPET = '''
    env_file=/tmp/x
    printf 'RHIZO_WIPE_DATA=0\\nRHIZO_RESIDENT_G=1\\nRHIZO_RESIDENT_DISPATCH=1\\n' > "$env_file"
'''

OLD_HOSTFS_PY_HEAD = '''
DEFAULT_MODE = "over"
DEFAULT_DAEMON = "/root/share/rhizo-hostfsd"
DEFAULT_DAEMON_LOG = "/tmp/rhizo-hostfsd.log"
'''


def selftest():
    """test the configuration channel check on fixtures"""
    problems = []

    if not HOSTFS_CONF_WRITE.search(OLD_POSTINST):
        problems.append("the postinst regex does not even catch the fixture's own bug")
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "debian"))
        os.makedirs(os.path.join(tmp, "src", "install", "lib"))
        shutil.copy(POSTINST, os.path.join(tmp, "debian", "rhizo.postinst"))
        lib = read(os.path.join(ROOT, "src", "install", "lib", "pkg-lib.sh"))
        anchor = "pkg_sys_account() {\n"
        if lib.count(anchor) != 1:
            problems.append("src/install/lib/pkg-lib.sh has no single 'pkg_sys_account() {' to plant the write in")
        with open(os.path.join(tmp, "src", "install", "lib", "pkg-lib.sh"), "w") as fh:
            fh.write(lib.replace(anchor, anchor + "  : > /etc/rhizo/hostfs.conf\n"))
        try:
            found = postinst_problems(os.path.join(tmp, "debian", "rhizo.postinst"))
        except ValueError as e:
            found = ["inliner refused: %s" % e]
        if not any("still writes /etc/rhizo/hostfs.conf" in f for f in found):
            problems.append("a hostfs.conf write inside pkg_sys_account was not caught (got %r)" % found)

    if "ConditionPathExists=/etc/rhizo/hostfs.conf" in "[Unit]\nDescription=x\n":
        problems.append("condition-check fixture is malformed")

    if not re.search(r'printf [^\n]*RHIZO_WIPE_DATA=0[^\n]*>\s*"\$env_file"(?!\.)',
                      OLD_PREPARE_SNIPPET):
        problems.append("the prepare.sh clobber regex does not catch the fixture's own bug")

    if not re.search(r'DEFAULT_DAEMON\s*=\s*"/root/share/rhizo-hostfsd"', OLD_HOSTFS_PY_HEAD):
        problems.append("the DEFAULT_DAEMON regex does not catch the fixture's own bug")

    for tpl, want in (("RHIZO_SELINUX_MODE=namespace\n#RHIZO_PERMISSIVE=1\n", []),
                      ("RHIZO_SELINUX_MODE=host\n", ["RHIZO_SELINUX_MODE=host"]),
                      ("RHIZO_PERMISSIVE=1\n", ["RHIZO_PERMISSIVE=1"])):
        got = env_template_problems(tpl)
        if got != want:
            problems.append("androidd.env template %r: want %r flagged, got %r" % (tpl, want, got))

    rc = check()
    if rc != 0:
        problems.append("the real, fixed tree does not pass")

    if problems:
        for p in problems:
            print(f"SELFTEST FAIL: {p}", file=sys.stderr)
        return 1
    print("selftest ok: every fixture is caught, the fixed tree passes")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else check())
