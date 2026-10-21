#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(TOOLS, "..", "..", "..", "system", "install", "installer.sh")
CENSUS_LIB = os.path.join(TOOLS, "..", "..", "..", "system", "host", "host-census-lib.sh")

INSTALL_RE = re.compile(r"apt-get install -y (-o \S+ )?(\./rhizo|/root/rhizo-artifact/)|"
                        r"(^|\s)installer_install_reboot_prepare\s")


def code_lines(text):
    """return the numbered non-comment lines"""
    return [(i, l) for i, l in enumerate(text.split("\n"), 1) if not l.lstrip().startswith("#")]


def check_prepare_baselines(lines):
    """check prepare waits and baseline counts"""
    fails = []
    inline = [i for i, l in lines if "systemctl start --no-block rhizo-prepare.service" in l]
    if inline:
        fails.append("prepare-baseline: a prepare wait of the system test's own at line(s) %s, outside "
                     "installer_await_prepare" % " ".join(map(str, inline)))
    reboots = [i for i, l in lines if re.search(r"(^|\s)reboot_and_wait\s", l)]
    for i, l in lines:
        m = re.search(r'(^|\s)installer_await_prepare "\$leg" \S+ "\$([A-Za-z_][A-Za-z0-9_]*)"', l)
        if not m:
            continue
        var = m.group(2)
        assigned = [j for j, a in lines if j < i and re.match(r"\s*%s=\$\(" % re.escape(var), a)]
        if not assigned:
            fails.append("prepare-baseline: line %d skips $%s, which is never counted before it" % (i, var))
            continue
        last_reboot = max((r for r in reboots if r < i), default=0)
        if max(assigned) > last_reboot:
            fails.append("prepare-baseline: line %d skips $%s, counted at line %d, after the reboot at line %d" % (i, var, max(assigned), last_reboot))
    return fails


def check(text):
    """check the system test census inputs"""
    fails = []
    lines = code_lines(text)
    bare = [i for i, l in lines if "host-snapshot-diff.py" in l]
    if bare:
        fails.append("census-direct: host-snapshot-diff.py is called bare at line(s) %s, with none of the "
                     "run's package windows" % " ".join(map(str, bare)))
    censuses = [i for i, l in lines if re.search(r"(^|\s)host_census_snapshot_diff\s", l)]
    if not censuses:
        fails.append("census-direct: no host_census_snapshot_diff call")
        return fails
    last = max(censuses)
    prev = {}
    for n, (i, l) in enumerate(lines):
        prev[i] = lines[n - 1][1] if n else ""
    for i, l in lines:
        if i > last or not INSTALL_RE.search(l):
            continue
        if "test_pkgwin " not in l and "test_pkgwin " not in prev[i]:
            fails.append("install-unrecorded: line %d installs before the last census (line %d) with no "
                         "test_pkgwin window around it: %s" % (i, last, l.strip()[:100]))
    before = [i for i, l in lines if 'take_snapshot "[$leg] before"' in l]
    clears = [i for i, l in lines if re.search(r'rm -f "\$EV/\$leg"-pkgwin-\*\.log', l)]
    if not before:
        fails.append("earlier-windows: no BEFORE snapshot (take_snapshot \"[$leg] before\") to anchor on")
    elif not clears or min(clears) > before[0]:
        fails.append("earlier-windows: the vm's previous windows are not removed before the BEFORE snapshot "
                     "(line %d)" % before[0])
    fails.extend(check_prepare_baselines(lines))
    purge_census = [i for i, l in lines if re.search(r"host_census_snapshot_diff \"\$leg\" purge ", l)]
    autoremove = [i for i, l in lines if "apt-get autoremove --purge -y" in l]
    kept = [i for i, l in lines if re.search(r"(^|\s)host_census_apt_kept_record\s", l)]
    if purge_census:
        pc = purge_census[0]
        if not any(a < pc for a in autoremove):
            fails.append("purge-autoremove: the purge census (line %d) follows no apt-get autoremove --purge" % pc)
        if not any(k < pc for k in kept):
            fails.append("purge-autoremove: the purge census (line %d) has no host_census_apt_kept_record "
                         "before it" % pc)
    return fails


def allowlist_problems(lib=CENSUS_LIB):
    """name each guest OS whose census allowlist is missing"""
    out = []
    for guest in ("ubuntu", "cachyos"):
        p = subprocess.run(["bash", "-c", 'unset HOST_CENSUS_ALLOW_DIR; source "$1" >/dev/null 2>&1; '
                            'RHIZO_GUEST_OS="$2" host_census_allowlist', "_", lib, guest], capture_output=True, text=True)
        path = p.stdout.strip()
        if p.returncode != 0 or not path or not os.path.isfile(path):
            out.append("census-allowlist: host-census-lib.sh names %r for a %s guest, which is no file" % (path, guest))
    return out


def selftest():
    """run check against planted defects"""
    text = open(TEST).read()
    real = check(text)
    assert not real, "the real system test must pass, got:\n" + "\n".join(real)
    caught = 0

    def plant(name, old, new, needle, count=1):
        """plant a defect in the system test"""
        nonlocal caught
        assert text.count(old) >= 1, "selftest cannot plant %s: %r is gone from the system test" % (name, old[:80])
        fails = check(text.replace(old, new, count))
        assert any(needle in f for f in fails), (
            "planted defect not caught (%s): want %r, got:\n%s" % (name, needle, "\n".join(fails) or "(clean)"))
        caught += 1

    plant("the remove census back to a bare diff with no windows",
          'host_census_snapshot_diff "$leg" remove installer',
          'python3 "$REPO/tools/host-snapshot-diff.py" "$EV/$leg-snapshot-before.tsv" x --phase remove',
          "census-direct")
    plant("the first install unrecorded",
          'test_pkgwin rhizo-install step7-install installer_install_reboot_prepare "$leg"',
          'installer_install_reboot_prepare "$leg"', "install-unrecorded")
    plant("the N upgrade unrecorded",
          'test_pkgwin rhizo-install step11b-upgrade ssh_vm', 'upgrade_out=$(ssh_vm', "install-unrecorded")
    plant("the previous run's windows kept",
          'rm -f "$EV/$leg"-pkgwin-*.log', ': "$EV/$leg"-kept-pkgwin', "earlier-windows")
    plant("the purge without its autoremove",
          "apt-get autoremove --purge -y >> /var/tmp/purge.log", "true >> /var/tmp/purge.log", "purge-autoremove")
    plant("the purge census with no apt-kept record",
          'host_census_apt_kept_record "$leg"', ': "$leg"', "purge-autoremove")
    lines = text.split("\n")
    count = next(n for n, l in enumerate(lines) if "prep2_before_lines=$(installer_prepare_log_lines)" in l)
    reboot = next(n for n, l in enumerate(lines) if 'reboot_and_wait "[$leg] reinstall-after-remove"' in l)
    moved = lines[:]
    moved.insert(reboot + 1, moved.pop(count))
    fails = check("\n".join(moved))
    assert any("prepare-baseline" in f and "prep2_before_lines" in f for f in fails), (
        "12g's baseline moved after its reboot not caught:\n" + "\n".join(fails))
    caught += 1
    plant("a prepare wait of the system test's own",
          'installer_await_prepare "$leg" "$EV/$leg-n-prepare.log"',
          "ssh_vm -t 60 'systemctl start --no-block rhizo-prepare.service'\n  installer_await_prepare \"$leg\" "
          "\"$EV/$leg-n-prepare.log\"", "prepare-baseline")
    assert any("census-direct" in f for f in check("")), "an empty system test must fail"
    caught += 1
    real_allow = allowlist_problems()
    assert not real_allow, "the real census allowlists must exist, got:\n" + "\n".join(real_allow)
    with tempfile.TemporaryDirectory() as tmp:
        lib = os.path.join(tmp, "host-census-lib.sh")
        with open(lib, "w") as fh:
            fh.write(open(CENSUS_LIB).read().replace("HOST_CENSUS_DIR/../checks/data}", "HOST_CENSUS_DIR/../checks/gone}"))
        assert any("census-allowlist" in f for f in allowlist_problems(lib)), "an allowlist in no folder was not caught"
    caught += 1
    print("check-installer-census-inputs selftest: the real system test passes, %d planted defects each named" % caught)
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--test", default=TEST)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    fails = check(open(args.test).read()) + allowlist_problems()
    for f in fails:
        print("FAIL: installer-census-inputs: %s" % f, file=sys.stderr)
    if not fails:
        print("check-installer-census-inputs: every census reads the run's package windows, every install before "
              "it is recorded, earlier windows are cleared first, the purge autoremoves and records what apt kept, and "
              "every prepare wait counts its baseline before its reboot")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
