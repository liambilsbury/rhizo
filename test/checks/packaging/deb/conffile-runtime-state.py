#!/usr/bin/env python3
import hashlib
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
PRISTINES = ("androidd.env.0.1.2", "androidd.env.0.1.3")
PRISTINE = os.path.join(HERE, PRISTINES[0])
PREINST = "debian/rhizo.preinst"
ARCH_INSTALL = "archlinux/rhizo/rhizo.install"
RUNTIME_PATH = "/var/lib/rhizo/androidd-runtime.env"
RUNTIME_KEYS = ("RHIZO_RELEASE=a16\nRHIZO_GSI=/srv/rhizo/gsi_system\nRHIZO_WIPE_DATA=0\nRHIZO_RESIDENT_G=1\n"
                "RHIZO_RESIDENT_DISPATCH=1\nRHIZO_DATA_IMG=/var/lib/rhizo/update/trial-data.img\n")
USER_EDIT = "RHIZO_PERMISSIVE=1\n"
WRITERS = ("src/install/update/gsi-update.sh", "src/install/prepare/prepare.sh")


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def md5(data):
    """return the md5 hex of bytes"""
    return hashlib.md5(data).hexdigest()


def dpkg_decision(old, cur, new):
    """return dpkg's conffile action from three md5s"""
    if cur == new or new == old:
        return "silent"
    return "silent" if cur == old else "prompt"


def pacman_decision(old, cur, new):
    """return pacman's backup action from three md5s"""
    if cur == new or new == old:
        return "keep"
    return "replace" if cur == old else "pacnew"


def function_text(text, name):
    """return a shell function's text from its name"""
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
    return m.group(0) if m else ""


def migrate(func, env_bytes, runtime_text):
    """run the migration function on fixture files"""
    with tempfile.TemporaryDirectory() as tmp:
        env, rt = os.path.join(tmp, "androidd.env"), os.path.join(tmp, "androidd-runtime.env")
        if env_bytes is not None:
            with open(env, "wb") as fh:
                fh.write(env_bytes)
        if runtime_text is not None:
            with open(rt, "w") as fh:
                fh.write(runtime_text)
        r = subprocess.run(["sh", "-ec", func + '\nrhizo_migrate_env_keys "$1" "$2"\n', "sh", env, rt],
                           capture_output=True, text=True, timeout=30)
        got_env = open(env, "rb").read() if os.path.exists(env) else None
        got_rt = open(rt).read() if os.path.exists(rt) else None
        return r.returncode, got_env, got_rt, r.stderr


def migration_findings(label, func, pristine):
    """return findings on a migration function"""
    bad = []
    if not func:
        return [f"{label} has no rhizo_migrate_env_keys function"]
    old, new = md5(pristine), md5(open(os.path.join(ROOT, "debian", "androidd.env"), "rb").read())
    cases = (
        ("0.1.2 conffile with the runtime keys", pristine + RUNTIME_KEYS.encode(), None, "pristine", RUNTIME_KEYS),
        ("a conffile that is already pristine", pristine, None, "pristine", None),
        ("a user's edit with the runtime keys", pristine + USER_EDIT.encode() + RUNTIME_KEYS.encode(), None,
         "edited", RUNTIME_KEYS),
        ("a user's edit and no runtime keys", pristine + USER_EDIT.encode(), None, "edited", None),
        ("an existing state file", pristine + RUNTIME_KEYS.encode(), "RHIZO_RELEASE=a15\n", "pristine",
         RUNTIME_KEYS + "RHIZO_RELEASE=a15\n"),
    )
    for name, env, rt_in, want_env, want_rt in cases:
        rc, got_env, got_rt, err = migrate(func, env, rt_in)
        if rc != 0:
            bad.append(f"{label}: {name}: the migration exited {rc}: {err.strip()[:160]}")
            continue
        want_bytes = pristine if want_env == "pristine" else pristine + USER_EDIT.encode()
        if got_env != want_bytes:
            bad.append(f"{label}: {name}: the conffile is not {'the pristine 0.1.2 bytes' if want_env == 'pristine' else 'the user edit alone'}")
        if (want_rt or rt_in) != got_rt:
            bad.append(f"{label}: {name}: the state file is {got_rt!r}, want {(want_rt or rt_in)!r}")
        if got_env is not None:
            for fn, decide, quiet in ((dpkg_decision, "dpkg", "silent"), (pacman_decision, "pacman", "replace")):
                act = fn(old, md5(got_env), new)
                if want_env == "pristine" and act != quiet:
                    bad.append(f"{label}: {name}: {decide} still answers {act}")
                if want_env == "edited" and act == quiet:
                    bad.append(f"{label}: {name}: {decide} would overwrite a user's edit")
    rc, got_env, got_rt, _ = migrate(func, None, None)
    if rc != 0 or got_env is not None or got_rt is not None:
        bad.append(f"{label}: no conffile at all: the migration is not a no-op (rc={rc})")
    rc, got_env, got_rt, _ = migrate(func, pristine + RUNTIME_KEYS.encode(), None)
    rc2, env2, rt2, _ = migrate(func, got_env, got_rt)
    if (env2, rt2) != (got_env, got_rt):
        bad.append(f"{label}: a second run changes the files")
    return bad


def writer_findings():
    """return findings on scripts that write a conffile"""
    bad = []
    for rel in WRITERS:
        for n, line in enumerate(read(rel).splitlines(), 1):
            code = line
            if not code.strip() or code.lstrip().startswith("#"):
                continue
            if re.search(r'(^|[^\w>])>>?\s*"?\$\{?(env_file|RHIZO_ANDROIDD_ENV)|\bmv\s+\S+\s+"?\$\{?(env_file|RHIZO_ANDROIDD_ENV)'
                         r'|\$\{?(env_file|RHIZO_ANDROIDD_ENV)\}?\.rhizo-[\w-]+\.tmp', code):
                bad.append(f"{rel}:{n} writes the conffile: {line.strip()}")
    with tempfile.TemporaryDirectory() as tmp:
        env, rt = os.path.join(tmp, "androidd.env"), os.path.join(tmp, "runtime.env")
        with open(PRISTINE, "rb") as src, open(env, "wb") as dst:
            dst.write(src.read())
        script = 'RHIZO_GSI_UPDATE_SOURCE_ONLY=1 source "$1"; write_launch_env a16 "" ""'
        r = subprocess.run(["bash", "-c", script, "bash", os.path.join(ROOT, WRITERS[0])], capture_output=True, text=True,
                           timeout=60, env=dict(os.environ, RHIZO_ANDROIDD_ENV=env, RHIZO_RUNTIME_ENV=rt,
                                                RHIZO_STATE_DIR=os.path.join(tmp, "state"), RHIZO_GSI_ROOT=os.path.join(tmp, "srv")))
        if open(env, "rb").read() != open(PRISTINE, "rb").read():
            bad.append("gsi-update.sh write_launch_env changed the conffile")
        if not os.path.exists(rt) or "RHIZO_RELEASE=a16\n" not in open(rt).read():
            bad.append(f"gsi-update.sh write_launch_env wrote no RHIZO_RELEASE to the state file (rc={r.returncode}): {r.stderr.strip()[-160:]}")
    return bad


def helper_findings(helper=None):
    """return findings on the mode helper's runtime read"""
    helper = helper or os.path.join(ROOT, "src", "androidd", "host", "selinux-mode.py")
    with tempfile.TemporaryDirectory() as tmp:
        env, rt = os.path.join(tmp, "androidd.env"), os.path.join(tmp, "runtime.env")
        open(env, "w").write("RHIZO_SELINUX_MODE=namespace\n")
        open(rt, "w").write("RHIZO_SELINUX_MODE=host\n")
        base = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
        r = subprocess.run([sys.executable, "-I", helper, "--env-file", env,
                            "--configured"], capture_output=True, text=True, timeout=60,
                           env=dict(base, RHIZO_RUNTIME_ENV=rt, RHIZO_HOST_MODE_KEPT_FILE=os.path.join(tmp, "none")))
        if r.stdout.strip() != "host":
            return [f"rhizo-selinux-mode.py ignores the runtime state file (answered {r.stdout.strip()!r})"]
    return []


def unit_order_findings(rel, text):
    """return findings on a unit's file order"""
    lines = [x.strip() for x in text.splitlines() if x.startswith("EnvironmentFile=-")]
    want = ["EnvironmentFile=-/etc/rhizo/androidd.env", f"EnvironmentFile=-{RUNTIME_PATH}",
            "EnvironmentFile=-/var/lib/rhizo/host-mode-kept.env"]
    if [x for x in lines if x in want] != want:
        return [f"{rel} does not load androidd.env, the runtime file, then the kept mode, in that order"]
    return []


def teardown_findings(text):
    """return findings on the teardown's state file"""
    if re.search(r'rm -f? ?"\$RUNTIME_ENV"', text):
        return ["teardown.sh removes the runtime state file on remove, not on purge alone"]
    return []


def packaging_findings(rules, pkgbuild):
    """return findings on a packaged state file"""
    if "androidd-runtime" in rules or "androidd-runtime" in pkgbuild:
        return ["the runtime state file is packaged"]
    return []


def dev_unit_findings(rel, text):
    """return findings on a dev unit's file order"""
    lines = [x.strip() for x in text.splitlines() if x.startswith("EnvironmentFile=-")]
    want = ["EnvironmentFile=-/root/androidd.env", f"EnvironmentFile=-{RUNTIME_PATH}"]
    if [x for x in lines if x in want] != want:
        return [f"{rel} does not load /root/androidd.env then the runtime file"]
    return []


def wiring_findings():
    """return findings on units, packaging and teardown"""
    bad = []
    units = ("debian/dropins/androidd-packaged-paths.conf", "debian/dropins/androidd-at-packaged-paths.conf",
             "src/services/units/boot/policy.service")
    for rel in units:
        bad += unit_order_findings(rel, read(rel))
    for rel in ("src/services/units/boot/androidd.service", "src/services/units/boot/androidd@.service"):
        bad += dev_unit_findings(rel, read(rel))
    bad += teardown_findings(read("src/install/teardown/teardown.sh"))
    bad += packaging_findings(read("debian/rules"), read("archlinux/rhizo/PKGBUILD.in"))
    return bad + helper_findings()


def abort_findings(pristine, preinst, postrm):
    """return findings on undoing a migration after an abort"""
    fn = function_text(postrm, "rhizo_restore_env_keys")
    if not fn:
        return ["debian/rhizo.postrm.in has no rhizo_restore_env_keys"]
    bad = []
    if not re.search(r"abort-upgrade\|abort-install\)\n\s+rhizo_restore_env_keys", postrm):
        bad.append("debian/rhizo.postrm.in never calls rhizo_restore_env_keys on abort-upgrade and abort-install")
    original = pristine + RUNTIME_KEYS.encode()
    with tempfile.TemporaryDirectory() as tmp:
        etc, lib = os.path.join(tmp, "etc"), os.path.join(tmp, "lib")
        os.makedirs(etc)
        os.makedirs(lib)

        def sub(text):
            return text.replace("/etc/rhizo", etc).replace("/var/lib/rhizo", lib)
        script = os.path.join(tmp, "preinst")
        open(script, "w").write(sub(preinst))
        restore = os.path.join(tmp, "restore.sh")
        open(restore, "w").write(sub(fn) + "\nrhizo_restore_env_keys\n")
        conffile = os.path.join(etc, "androidd.env")
        with open(os.path.join(lib, "data.img.meta"), "w") as fh:
            fh.write("release=a16\n")
        open(conffile, "wb").write(original)
        subprocess.run(["sh", script, "upgrade", "0.1.2"], capture_output=True, timeout=60, check=False)
        r = subprocess.run(["sh", restore], capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or open(conffile, "rb").read() != original:
            bad.append(f"the restore after a migrated upgrade does not bring the conffile back (rc={r.returncode})")
        if os.path.exists(os.path.join(lib, "androidd-runtime.env.migrated")):
            bad.append("the restore leaves its record behind")
        runtime = os.path.join(lib, "androidd-runtime.env")
        left = open(runtime).read() if os.path.exists(runtime) else ""
        if any(line in left.splitlines() for line in RUNTIME_KEYS.splitlines()):
            bad.append("the restore copies the keys back and leaves them in the state file too")
        text = open(conffile, "rb").read().replace(b"RHIZO_RELEASE=a16", b"RHIZO_RELEASE=a17")
        open(conffile, "wb").write(text)
        subprocess.run(["sh", script, "upgrade", "0.1.2"], capture_output=True, timeout=60, check=False)
        now = open(runtime).read().splitlines() if os.path.exists(runtime) else []
        if [x for x in now if x.startswith("RHIZO_RELEASE=")] != ["RHIZO_RELEASE=a17"]:
            bad.append(f"a retried upgrade after the restore reads {[x for x in now if x.startswith('RHIZO_RELEASE=')]}, not the a17 the old version set")
        os.unlink(os.path.join(lib, "androidd-runtime.env.migrated"))
        open(conffile, "wb").write(pristine)
        r = subprocess.run(["sh", restore], capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or open(conffile, "rb").read() != pristine:
            bad.append("the restore changes a conffile the preinst never migrated")
    return bad


def fetch_current_findings():
    """return findings on fetch-gsi with no env file"""
    text = read("src/install/prepare/fetch-gsi.sh")
    fn = function_text(text, "current_release")
    with tempfile.TemporaryDirectory() as tmp:
        script = "set -uo pipefail\ndeclare -A GSI_URL=([a16]=x [a17]=y)\n" + fn + "current_release\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, RHIZO_ANDROIDD_ENV=os.path.join(tmp, "none.env"),
                                    RHIZO_RUNTIME_ENV=os.path.join(tmp, "none-runtime.env")))
    if r.returncode != 0 or r.stdout != "a16":
        return [f"fetch-gsi current_release with neither env file answers {r.stdout!r} rc={r.returncode}, not a16: {r.stderr.strip()[:120]}"]
    return []


def preinst_findings(pristine, text=None):
    """return findings on the preinst's refusal order"""
    bad = []
    text = text or read(PREINST)
    with tempfile.TemporaryDirectory() as tmp:
        etc, lib = os.path.join(tmp, "etc"), os.path.join(tmp, "lib")
        os.makedirs(etc)
        os.makedirs(lib)
        script = os.path.join(tmp, "preinst")
        with open(script, "w") as fh:
            fh.write(text.replace("/etc/rhizo", etc).replace("/var/lib/rhizo", lib))
        for release, refused in (("a15", True), ("a16", False)):
            with open(os.path.join(etc, "androidd.env"), "wb") as fh:
                fh.write(pristine + RUNTIME_KEYS.encode())
            with open(os.path.join(lib, "data.img.meta"), "w") as fh:
                fh.write(f"release={release}\n")
            if os.path.exists(os.path.join(lib, "androidd-runtime.env")):
                os.unlink(os.path.join(lib, "androidd-runtime.env"))
            r = subprocess.run(["sh", script, "upgrade", "0.1.2"], capture_output=True, text=True, timeout=60,
                               env=dict(os.environ, RHIZO_WIPE_DATA="0"))
            untouched = open(os.path.join(etc, "androidd.env"), "rb").read() == pristine + RUNTIME_KEYS.encode() \
                and not os.path.exists(os.path.join(lib, "androidd-runtime.env"))
            if refused and (r.returncode == 0 or not untouched):
                bad.append(f"a refused upgrade (rc={r.returncode}) leaves the conffile or state file changed")
            if not refused and (r.returncode != 0 or untouched):
                bad.append(f"an accepted upgrade (rc={r.returncode}) does not migrate: {r.stderr.strip()[:160]}")
    return bad


def pre_upgrade_findings(text):
    """return findings on pacman's migration order"""
    if text.index("pkg_pre_replace upgrade") > text.index("rhizo_migrate_env_keys /etc"):
        return ["pacman's pre_upgrade migrates before the steps that can abort it"]
    return []


def findings():
    """return every finding"""
    pristine = open(PRISTINE, "rb").read()
    bad = writer_findings() + wiring_findings() + preinst_findings(pristine) + fetch_current_findings()
    bad += abort_findings(pristine, read(PREINST), read("debian/rhizo.postrm.in"))
    if "androidd-runtime.env.migrated" not in read("src/install/lib/pkg-lib.sh"):
        bad.append("the postinst never drops the migration record once configure begins")
    deb = function_text(read(PREINST), "rhizo_migrate_env_keys")
    arch = function_text(read(ARCH_INSTALL), "rhizo_migrate_env_keys")
    for name in PRISTINES:
        data = open(os.path.join(HERE, name), "rb").read()
        bad += migration_findings(f"debian/rhizo.preinst on {name}", deb, data)
        bad += migration_findings(f"{ARCH_INSTALL} on {name}", arch, data)
    bad += pre_upgrade_findings(read(ARCH_INSTALL))
    if deb and arch and deb != arch:
        bad.append("the preinst and the pacman install script carry different migration functions")
    call = re.search(r'rhizo_migrate_env_keys /etc/rhizo/androidd\.env /var/lib/rhizo/androidd-runtime\.env', read(PREINST))
    if deb and not call:
        bad.append("the preinst never calls the migration on the real paths")
    return bad


def wiring_selftest(base):
    """check the wiring findings both ways"""
    bad = []
    unit = "[Service]\nEnvironmentFile=-/etc/rhizo/androidd.env\nEnvironmentFile=-%s\nEnvironmentFile=-/var/lib/rhizo/host-mode-kept.env\n"
    if unit_order_findings("u", unit % RUNTIME_PATH):
        bad.append("a unit in the right order is flagged")
    if not unit_order_findings("u", unit.replace("EnvironmentFile=-%s\n", "")):
        bad.append("a unit with no runtime file passed")
    if not unit_order_findings("u", "[Service]\nEnvironmentFile=-%s\nEnvironmentFile=-/etc/rhizo/androidd.env\nEnvironmentFile=-/var/lib/rhizo/host-mode-kept.env\n" % RUNTIME_PATH):
        bad.append("a unit loading the runtime file first passed")
    dev = "[Service]\nEnvironmentFile=-/root/androidd.env\nEnvironmentFile=-%s\n"
    if dev_unit_findings("d", dev % RUNTIME_PATH):
        bad.append("a dev unit in the right order is flagged")
    if not dev_unit_findings("d", "[Service]\nEnvironmentFile=-/root/androidd.env\n"):
        bad.append("a dev unit with no runtime file passed")
    with tempfile.TemporaryDirectory() as tmp:
        stub = os.path.join(tmp, "stub.py")
        open(stub, "w").write("print('namespace')\n")
        if not helper_findings(stub):
            bad.append("a mode helper that ignores the runtime file passed")
    if helper_findings():
        bad.append("the shipped mode helper is flagged")
    if teardown_findings(read("src/install/teardown/teardown.sh")):
        bad.append("the shipped teardown is flagged")
    if not teardown_findings('rm -f "$RUNTIME_ENV" || exit 1\n'):
        bad.append("a teardown that removes the state file on remove passed")
    if packaging_findings("install debian/androidd.env", "backup=()"):
        bad.append("an unpackaged state file is flagged")
    if not packaging_findings("install /var/lib/rhizo/androidd-runtime.env", "") or not packaging_findings("", "x androidd-runtime"):
        bad.append("a packaged state file passed")
    real = read(PREINST)
    call = "    if [ -n \"${2:-}\" ]; then\n      rhizo_migrate_env_keys /etc/rhizo/androidd.env /var/lib/rhizo/androidd-runtime.env\n    fi\n"
    early = real.replace(call, "", 1).replace("    RECORD=/var/lib/rhizo/.created-by-install\n", "    rhizo_migrate_env_keys /etc/rhizo/androidd.env /var/lib/rhizo/androidd-runtime.env\n    RECORD=/var/lib/rhizo/.created-by-install\n", 1)
    if early == real or not preinst_findings(base, early):
        bad.append("a preinst that migrates before its refusal passed")
    if preinst_findings(base, real):
        bad.append("the shipped preinst is flagged")
    arch = read(ARCH_INSTALL)
    swapped = arch.replace("  _source_lib || return 1\n  pkg_pre_replace upgrade || rc=1\n", "  _source_lib || return 1\n", 1)
    swapped = swapped.replace("  mkdir -p \"$_state\" || rc=1\n", "  mkdir -p \"$_state\" || rc=1\n  rhizo_migrate_env_keys /etc/rhizo/androidd.env x || rc=1\n  pkg_pre_replace upgrade || rc=1\n", 1)
    if not pre_upgrade_findings(swapped):
        bad.append("a pre_upgrade that migrates first passed")
    if pre_upgrade_findings(arch):
        bad.append("the shipped pre_upgrade is flagged")
    return bad


def selftest():
    """check the decisions and extractor both ways"""
    bad = []
    if dpkg_decision("a", "b", "c") != "prompt" or dpkg_decision("a", "a", "c") != "silent" or dpkg_decision("a", "b", "a") != "silent":
        bad.append("dpkg_decision is wrong")
    if pacman_decision("a", "b", "c") != "pacnew" or pacman_decision("a", "a", "c") != "replace":
        bad.append("pacman_decision is wrong")
    if function_text("x\nf() {\n  :\n}\ny\n", "f") != "f() {\n  :\n}\n" or function_text("x", "f"):
        bad.append("function_text is wrong")
    moves_nothing = 'rhizo_migrate_env_keys() {\n  cp "$1" "$2"\n}\n'
    eats_edits = 'rhizo_migrate_env_keys() {\n  cp "$1" "$2"\n  : > "$1"\n}\n'
    real = function_text(read(PREINST), "rhizo_migrate_env_keys")
    base = open(PRISTINE, "rb").read()
    if not migration_findings("moves nothing", moves_nothing, base):
        bad.append("a migration that moves nothing passed")
    if not [f for f in migration_findings("eats edits", eats_edits, base) if "edit" in f or "pristine" in f]:
        bad.append("a migration that empties the conffile passed")
    if fetch_current_findings():
        bad.append("the shipped fetch-gsi is flagged on an empty host")
    if not abort_findings(base, read(PREINST), "rhizo_x() {\n:\n}\n"):
        bad.append("a postrm with no restore passed")
    noop = 'rhizo_restore_env_keys() {\n  :\n}\nabort-upgrade|abort-install)\n  rhizo_restore_env_keys\n'
    if not abort_findings(base, read(PREINST), noop):
        bad.append("a restore that restores nothing passed")
    if migration_findings("real", real, base):
        bad.append("the shipped migration is flagged on the pristine bytes")
    bad += wiring_selftest(base)
    print("conffile-runtime-state selftest: %s" % ("FAILED " + "; ".join(bad) if bad else "pass"))
    return 1 if bad else 0


def main():
    """run the check"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = findings()
    for line in bad:
        print("FAIL:", line)
    print("conffile-runtime-state: %s" % ("%d findings" % len(bad) if bad else "pass"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
