#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
KEPT = "/var/lib/rhizo/host-mode-kept.env"
ANDROIDD_ENV = "/etc/rhizo/androidd.env"
HELPER = os.path.join(REPO, "src", "androidd", "host", "selinux-mode.py")
UNITS = ("debian/dropins/androidd-packaged-paths.conf", "debian/dropins/androidd-at-packaged-paths.conf",
         "src/services/units/boot/policy.service")
ENV_READERS = ("src/install/update/gsi-update.sh", "src/install/prepare/fetch-gsi.sh",
               "src/install/prepare/prepare.sh")
ENV_WRITERS = ("src/install/cli/rhizo.sh", "src/install/lib/pkg-lib.sh", "debian/rhizo.postinst")


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def helper_findings():
    """return findings on the mode helper's reading of the kept file"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        env, kept = os.path.join(tmp, "androidd.env"), os.path.join(tmp, "kept.env")
        with open(env, "w") as fh:
            fh.write("RHIZO_SELINUX_MODE=namespace\n")
        base = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
        for kept_text, want in (("# kept for a reason\nRHIZO_SELINUX_MODE=host\n", "host"), (None, "namespace")):
            if kept_text is not None:
                with open(kept, "w") as fh:
                    fh.write(kept_text)
            elif os.path.exists(kept):
                os.unlink(kept)
            r = subprocess.run([sys.executable, HELPER, "--env-file", env, "--configured"], capture_output=True,
                               text=True, env=dict(base, RHIZO_HOST_MODE_KEPT_FILE=kept), timeout=60)
            if r.returncode != 0 or r.stdout.strip() != want:
                bad.append("rhizo-selinux-mode --configured with %s reads %r (rc=%d), want %s"
                           % ("a kept host mode" if kept_text else "no kept file", r.stdout.strip(), r.returncode,
                              want))
    if KEPT not in read("src/androidd/host/selinux-mode.py"):
        bad.append("rhizo-selinux-mode.py does not name %s as the kept file it reads" % KEPT)
    return bad


def unit_findings():
    """return findings on the units that pass androidd.env to the launcher"""
    bad = []
    for rel in UNITS:
        files = re.findall(r"^EnvironmentFile=-?(\S+)$", read(rel), re.M)
        if ANDROIDD_ENV not in files or KEPT not in files or files.index(KEPT) < files.index(ANDROIDD_ENV):
            bad.append("%s reads %s, want %s after %s" % (rel, files, KEPT, ANDROIDD_ENV))
    return bad


def reader_findings():
    """find readers that would take the kept file"""
    bad = []
    for rel in ENV_READERS:
        for n, line in enumerate(read(rel).splitlines(), 1):
            if "EnvironmentFile=" in line and "tail -1" in line and not re.search(r"grep -vxF (-e )?%s" % re.escape(KEPT), line):
                bad.append("%s:%d takes androidd's last EnvironmentFile without skipping %s" % (rel, n, KEPT))
    return bad


def writer_findings():
    """return each script that writes RHIZO_SELINUX_MODE into androidd.env"""
    bad = []
    for rel in ENV_WRITERS:
        text = read(rel)
        if re.search(r"RHIZO_SELINUX_MODE=[^\n]*>>\s*\"?\$(env|ETC_RHIZO)", text) or "write_env_selinux_mode" in text:
            bad.append("%s writes RHIZO_SELINUX_MODE into androidd.env, the package's conffile" % rel)
    return bad


def removal_findings():
    """check that the CLI and teardown remove the kept file"""
    bad = []
    lib = re.search(r"^RHIZO_TEARDOWN_LIB_HOST_MODE_KEPT=(\S+)$", read("src/install/teardown/teardown-lib.sh"), re.M)
    if not lib or lib.group(1) != KEPT:
        bad.append("teardown-lib.sh names the kept file %s, want %s" % (lib and lib.group(1), KEPT))
    if 'rm -f "$HOST_MODE_KEPT"' not in read("src/install/teardown/teardown.sh"):
        bad.append("teardown.sh removes no $HOST_MODE_KEPT on removal or purge")
    cli = read("src/install/cli/rhizo.sh")
    if 'HOST_MODE_KEPT="$STATE_DIR/%s"' % os.path.basename(KEPT) not in cli:
        bad.append("rhizo.sh does not name $STATE_DIR/%s as its kept file" % os.path.basename(KEPT))
    if cli.count('rm -f "$HOST_MODE_KEPT"') < 2:
        bad.append("rhizo.sh does not remove the kept file both when the switch runs and when the labels are gone")
    return bad


def main():
    """run every finding and print PASS or each one"""
    bad = helper_findings() + unit_findings() + reader_findings() + writer_findings() + removal_findings()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
