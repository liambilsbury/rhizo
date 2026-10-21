#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
INSTALL_RE = re.compile(unit_files.PATH_RE + r"([A-Za-z0-9_.@-]+\.(?:service|path|socket|mount))(?![A-Za-z0-9_.@-])")
UNITS_ARRAY_RE = re.compile(r"^UNITS=\((.*?)\)", re.S | re.M)
USER_UNITS_ARRAY_RE = re.compile(r"^USER_UNITS=\((.*?)\)", re.S | re.M)

REMOVAL_EXEMPT = {"rhizo-prepare.service"}


def installed_units(rules_text, dest="$(UNITS)"):
    """return the units debian/rules installs"""
    out = set()
    for stanza in rules_text.split("install "):
        if dest not in stanza:
            continue
        out.update(unit_files.installed_name(n) for n in INSTALL_RE.findall(stanza))
    return out


def removed_units(teardown_text, array_re=UNITS_ARRAY_RE):
    """return the unit names the teardown removes, or None"""
    found = array_re.search(teardown_text)
    if not found:
        return None
    return set(found.group(1).split())


def drift(rules_text, teardown_text):
    """compare the installed and removed units"""
    problems = []
    for dest, array_re, array in (("$(UNITS)", UNITS_ARRAY_RE, "UNITS"),
                                  ("$(USER_UNITS)", USER_UNITS_ARRAY_RE, "USER_UNITS")):
        installed = installed_units(rules_text, dest)
        removed = removed_units(teardown_text, array_re)
        if removed is None:
            if installed or array == "UNITS":
                problems.append(f"teardown.sh has no {array}=( ... ) array to read")
            continue
        for u in sorted(installed - removed - REMOVAL_EXEMPT):
            problems.append(f"{u} is installed by debian/rules into {dest} and never removed "
                            f"by teardown.sh's {array}")
        for u in sorted(removed - installed):
            problems.append(f"{u} is removed by teardown.sh's {array} and never "
                            f"installed by debian/rules into {dest}")
    return problems


def _directive_targets(unit_text, directive):
    """return the targets of the matching directive lines"""
    targets = set()
    prefix = directive + "="
    for line in unit_text.splitlines():
        line = line.strip()
        if line.startswith(prefix):
            targets.update(line[len(prefix):].split())
    return targets


LOGIN_STARTERS = ("display-manager.service", "getty.target", "systemd-user-sessions.service",
                  "ssh.service", "sshd.service")


def policy_unit_ordering_problems(policy_text, androidd_text, prepare_text, androidd_at_text):
    """return the missing ordering lines of policy units"""
    problems = []
    after = _directive_targets(policy_text, "After")
    before = _directive_targets(policy_text, "Before")
    for want in LOGIN_STARTERS:
        if want not in before:
            problems.append(f"rhizo-policy.service has no Before={want} line")
    for want in ("rhizo-prepare.service", "rhizo-update-begin.service"):
        if want not in after:
            problems.append(f"rhizo-policy.service has no After={want} line")
    for name, text in (("androidd.service", androidd_text), ("androidd@.service", androidd_at_text)):
        targets = _directive_targets(text, "After")
        if "rhizo-policy.service" not in targets:
            problems.append(f"{name} has no After=rhizo-policy.service line")
        targets = _directive_targets(text, "Wants")
        if "rhizo-policy.service" not in targets:
            problems.append(f"{name} has no Wants=rhizo-policy.service line")
    prepare_before = _directive_targets(prepare_text, "Before")
    for want in LOGIN_STARTERS:
        if want not in prepare_before:
            problems.append(f"rhizo-prepare.service has no Before={want} line")
    return problems


SELINUXFS = "/sys/fs/selinux"
SELINUXFS_UNIT = "rhizo-selinuxfs.service"
MODE_UNIT = "rhizo-selinux-mode.service"
EXEC_PREFIXES = "-@:+!"


def selinuxfs_unit_name(rules_text):
    """return the selinux unit debian/rules installs"""
    shipped = sorted(u for u in installed_units(rules_text) if "selinux" in u and u != MODE_UNIT)
    return shipped[0] if shipped else SELINUXFS_UNIT


def _mounts_selinuxfs(argv):
    """check the argv for a selinuxfs mount"""
    return bool(argv and argv[0].startswith("/") and argv[0].endswith("/mount") and argv[-1] == SELINUXFS
                and "-t" in argv and argv[argv.index("-t") + 1:][:1] == ["selinuxfs"])


def selinuxfs_unit_problems(policy_text, prepare_text, rules_text, read_unit):
    """return the problems found in the selinuxfs unit"""
    unit_name = selinuxfs_unit_name(rules_text)
    problems = []
    if unit_name not in installed_units(rules_text):
        problems.append(f"{unit_name} is not installed by debian/rules")
    for name, text in (("rhizo-policy.service", policy_text), ("rhizo-prepare.service", prepare_text)):
        for directive in ("Wants", "After"):
            if unit_name not in _directive_targets(text, directive):
                problems.append(f"{name} has no {directive}={unit_name} line")
    if not unit_name.endswith(".service"):
        problems.append(f"{unit_name} is not a service: systemd refuses a .mount unit for {SELINUXFS}, "
                        f"an API file system (LoadState=bad-setting)")
    unit_text = read_unit(unit_name)
    if unit_text is None:
        problems.append(f"src/services/**/{unit_name} does not exist")
        return problems
    lines = [line.strip() for line in unit_text.splitlines()]
    for directive, want in (("ConditionPathIsDirectory", SELINUXFS), ("ConditionPathIsMountPoint", "!" + SELINUXFS),
                            ("DefaultDependencies", "no"), ("Type", "oneshot"), ("RemainAfterExit", "yes")):
        if want not in _directive_targets(unit_text, directive):
            problems.append(f"{unit_name} has no {directive}={want} line")
    if not any(_mounts_selinuxfs(line[len("ExecStart="):].split()) for line in lines
               if line.startswith("ExecStart=")):
        problems.append(f"{unit_name} has no ExecStart= that mounts selinuxfs at {SELINUXFS}")
    for line in lines:
        key, _, value = line.partition("=")
        if key.startswith("Exec") and value[:1] in tuple(EXEC_PREFIXES):
            problems.append(f"{unit_name} has {key}={value[:1]}..., a prefix that changes how systemd runs "
                            f"the command or reads its exit status")
    if any(line.startswith("ExecStop") for line in lines):
        problems.append(f"{unit_name} has an ExecStop line")
    return problems


def selftest():
    """test the unit checks on sample inputs"""
    good_rules = ("\tinstall -m 0644 src/services/units/boot/androidd.service "
                  "src/services/units/display-pool/display-pool.path $(UNITS)/\n")
    good_teardown = "UNITS=(androidd.service rhizo-display-pool.path)\n"
    broker_rules = ("\tinstall -m 0644 src/services/broker/brokerd.socket "
                    "src/services/broker/brokerd@.service $(UNITS)/\n")
    if drift(broker_rules, "UNITS=(rhizo-brokerd.socket rhizo-brokerd@.service)\n"):
        print("selftest FAIL: a socket unit and a template unit, both installed\n"
              "              and both removed, were read as drift")
        return 1
    if not drift(broker_rules, "UNITS=(rhizo-brokerd.socket)\n"):
        print("selftest FAIL: a template unit installed but never removed was not flagged")
        return 1
    dropin_rules = ("\tinstall -D -m 0644 src/services/appsync/run-rhizo.mount.d/"
                    "rhizo-resync-rearm.conf $(UNITS)/run-rhizo.mount.d/rhizo-resync-rearm.conf\n")
    if drift(dropin_rules, "UNITS=()\n"):
        print("selftest FAIL: a .mount.d drop-in was read as an installed unit")
        return 1
    mount_rules = good_rules + "\tinstall -m 0644 src/services/units/sys-fs-selinux.mount $(UNITS)/\n"
    mount_teardown = "UNITS=(androidd.service rhizo-display-pool.path sys-fs-selinux.mount)\n"
    if drift(mount_rules, mount_teardown):
        print("selftest FAIL: a .mount unit installed and removed was read as drift")
        return 1
    if not any("sys-fs-selinux.mount is installed by debian/rules" in d
               for d in drift(mount_rules, good_teardown)):
        print("selftest FAIL: a .mount unit installed but never removed was not flagged")
        return 1
    if drift(good_rules, good_teardown):
        print("selftest FAIL: a matching pair was flagged")
        return 1
    short_rules = "\tinstall -m 0644 src/services/units/boot/androidd.service $(UNITS)/\n"
    if not drift(short_rules, good_teardown):
        print("selftest FAIL: an unshipped unit was not flagged")
        return 1
    if not drift(good_rules, "UNITS=(androidd.service)\n"):
        print("selftest FAIL: an unremoved unit was not flagged")
        return 1
    if not drift(good_rules, "no array here\n"):
        print("selftest FAIL: a missing UNITS array read as agreement")
        return 1
    user_rules = good_rules + ("\tinstall -D -m 0644 src/services/units/watch.path \\\n"
                               "\t                   $(USER_UNITS)/rhizo-watch.path\n")
    if drift(user_rules, good_teardown + "USER_UNITS=(rhizo-watch.path)\n"):
        print("selftest FAIL: a user unit installed and removed was read as drift")
        return 1
    if not any("rhizo-watch.path is installed by debian/rules into $(USER_UNITS)" in d
               for d in drift(user_rules, good_teardown + "USER_UNITS=()\n")):
        print("selftest FAIL: a user unit installed but never removed was not flagged")
        return 1
    if not any("no USER_UNITS" in d for d in drift(user_rules, good_teardown)):
        print("selftest FAIL: a user unit installed with no USER_UNITS array was not flagged")
        return 1
    if not any("rhizo-watch.path is removed by teardown.sh's USER_UNITS" in d
               for d in drift(good_rules, good_teardown + "USER_UNITS=(rhizo-watch.path)\n")):
        print("selftest FAIL: a user unit removed but never installed was not flagged")
        return 1
    if not any("rhizo-watch.path is removed by teardown.sh's USER_UNITS" in d
               for d in drift(good_rules.replace("$(UNITS)/", "src/services/units/watch.path $(UNITS)/"),
                              "UNITS=(androidd.service rhizo-display-pool.path rhizo-watch.path)\n"
                              "USER_UNITS=(rhizo-watch.path)\n")):
        print("selftest FAIL: a user unit shipped into the system unit directory was not flagged")
        return 1

    good_policy = ("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                   "Before=display-manager.service getty.target systemd-user-sessions.service\n"
                   "Before=ssh.service sshd.service\n")
    good_androidd = "[Unit]\nAfter=rhizo-policy.service\nWants=rhizo-policy.service\n"
    good_androidd_at = "[Unit]\nAfter=rhizo-policy.service\nWants=rhizo-policy.service\n"
    good_prepare = ("[Unit]\nBefore=display-manager.service getty.target "
                    "systemd-user-sessions.service ssh.service sshd.service\n")

    def probs(policy=good_policy, androidd=good_androidd, prepare=good_prepare,
              androidd_at=good_androidd_at):
        """return the unit ordering problems for the given units"""
        return policy_unit_ordering_problems(policy, androidd, prepare, androidd_at)

    if probs():
        print("selftest FAIL: a correctly-ordered set was flagged")
        return 1
    if not any("Before=display-manager.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                              "Before=getty.target systemd-user-sessions.service ssh.service\n"))):
        print("selftest FAIL: a dropped Before=display-manager.service was not flagged")
        return 1
    if not any("Before=getty.target" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                              "Before=display-manager.service systemd-user-sessions.service\n"))):
        print("selftest FAIL: a dropped Before=getty.target was not flagged")
        return 1
    if not any("Before=systemd-user-sessions.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                              "Before=display-manager.service getty.target\n"))):
        print("selftest FAIL: a dropped Before=systemd-user-sessions.service was not flagged")
        return 1
    if not any("rhizo-policy.service has no Before=ssh.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                              "Before=display-manager.service getty.target systemd-user-sessions.service\n"))):
        print("selftest FAIL: a dropped Before=ssh.service was not flagged")
        return 1
    if not any("rhizo-policy.service has no Before=sshd.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service rhizo-update-begin.service\n"
                              "Before=display-manager.service getty.target systemd-user-sessions.service ssh.service\n"))):
        print("selftest FAIL: a dropped Before=sshd.service was not flagged")
        return 1
    if not any("After=rhizo-prepare.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-update-begin.service\n"
                              "Before=display-manager.service getty.target systemd-user-sessions.service\n"))):
        print("selftest FAIL: a dropped After=rhizo-prepare.service was not flagged")
        return 1
    if not any("After=rhizo-update-begin.service" in p for p in
               probs(policy=("[Unit]\nAfter=rhizo-prepare.service\n"
                              "Before=display-manager.service getty.target systemd-user-sessions.service\n"))):
        print("selftest FAIL: a dropped After=rhizo-update-begin.service was not flagged")
        return 1
    if not any("androidd.service has no After=rhizo-policy.service" in p for p in
               probs(androidd="[Unit]\nAfter=systemd-modules-load.service\nWants=rhizo-policy.service\n")):
        print("selftest FAIL: androidd.service missing After=rhizo-policy.service was not flagged")
        return 1
    if not any("androidd.service has no Wants=rhizo-policy.service" in p for p in
               probs(androidd="[Unit]\nAfter=rhizo-policy.service\n")):
        print("selftest FAIL: androidd.service missing Wants=rhizo-policy.service was not flagged")
        return 1
    if not any("androidd@.service has no After=rhizo-policy.service" in p for p in
               probs(androidd_at="[Unit]\nWants=rhizo-policy.service\n")):
        print("selftest FAIL: androidd@.service missing After=rhizo-policy.service was not flagged")
        return 1
    if not any("androidd@.service has no Wants=rhizo-policy.service" in p for p in
               probs(androidd_at="[Unit]\nAfter=rhizo-policy.service\n")):
        print("selftest FAIL: androidd@.service missing Wants=rhizo-policy.service was not flagged")
        return 1
    for want in LOGIN_STARTERS:
        remaining = " ".join(t for t in LOGIN_STARTERS if t != want)
        if not any(f"rhizo-prepare.service has no Before={want}" in p for p in
                   probs(prepare=f"[Unit]\nBefore={remaining}\n")):
            print(f"selftest FAIL: rhizo-prepare.service missing Before={want} was not flagged")
            return 1
    if probs(policy=("[Unit]\nAfter=rhizo-prepare.service\nAfter=rhizo-update-begin.service\n"
                      "Before=display-manager.service\nBefore=getty.target\n"
                      "Before=systemd-user-sessions.service\nBefore=ssh.service\nBefore=sshd.service\n")):
        print("selftest FAIL: repeated After=/Before= lines were not unioned")
        return 1

    good_unit = ("[Unit]\nDescription=Rhizo: mount selinuxfs where systemd does not\nDefaultDependencies=no\n"
                 "ConditionPathIsDirectory=/sys/fs/selinux\nConditionPathIsMountPoint=!/sys/fs/selinux\n\n"
                 "[Service]\nType=oneshot\nRemainAfterExit=yes\n"
                 "ExecStart=/usr/bin/mount -t selinuxfs -o nosuid,noexec selinuxfs /sys/fs/selinux\n")

    def fs_unit(wants=True, after=True):
        """return a fixture unit text"""
        return ("[Unit]\n" + ("Wants=rhizo-selinuxfs.service\n" if wants else "")
                + "After=local-fs.target" + (" rhizo-selinuxfs.service" if after else "") + "\n")

    fs_rules = good_rules + "\tinstall -m 0644 src/services/units/boot/selinuxfs.service $(UNITS)/\n"

    def fs_probs(policy=fs_unit(), prepare=fs_unit(), unit=good_unit, rules=fs_rules):
        """return the selinuxfs unit problems for the given units"""
        name = selinuxfs_unit_name(rules)
        return selinuxfs_unit_problems(policy, prepare, rules, lambda n: unit if n == name else None)

    if fs_probs():
        print("selftest FAIL: a correct selinuxfs set was flagged: %s" % fs_probs())
        return 1
    for unit, kw in (("rhizo-policy.service", "policy"), ("rhizo-prepare.service", "prepare")):
        for directive, unwired in (("Wants", fs_unit(wants=False)), ("After", fs_unit(after=False))):
            if not any(f"{unit} has no {directive}=rhizo-selinuxfs.service" in p
                       for p in fs_probs(**{kw: unwired})):
                print(f"selftest FAIL: {unit} without {directive}=rhizo-selinuxfs.service was not flagged")
                return 1
    if not any("rhizo-selinuxfs.service is not installed by debian/rules" in p for p in fs_probs(rules=good_rules)):
        print("selftest FAIL: a selinuxfs unit debian/rules does not install was not flagged")
        return 1
    if not any("does not exist" in p for p in selinuxfs_unit_problems(fs_unit(), fs_unit(), fs_rules, lambda n: None)):
        print("selftest FAIL: an installed selinuxfs unit with no file was not flagged")
        return 1
    for drop, needle in (
            ("ConditionPathIsDirectory=/sys/fs/selinux\n", "no ConditionPathIsDirectory=/sys/fs/selinux"),
            ("ConditionPathIsMountPoint=!/sys/fs/selinux\n", "no ConditionPathIsMountPoint=!/sys/fs/selinux"),
            ("DefaultDependencies=no\n", "no DefaultDependencies=no"),
            ("Type=oneshot\n", "no Type=oneshot"),
            ("RemainAfterExit=yes\n", "no RemainAfterExit=yes"),
            ("ExecStart=/usr/bin/mount -t selinuxfs -o nosuid,noexec selinuxfs /sys/fs/selinux\n",
             "no ExecStart= that mounts selinuxfs")):
        if not any(needle in p for p in fs_probs(unit=good_unit.replace(drop, ""))):
            print(f"selftest FAIL: a selinuxfs unit missing `{drop.strip()}` was not flagged")
            return 1
    if not any("no ConditionPathIsMountPoint=!/sys/fs/selinux" in p for p in
               fs_probs(unit=good_unit.replace("IsMountPoint=!", "IsMountPoint="))):
        print("selftest FAIL: a ConditionPathIsMountPoint with its ! dropped was not flagged")
        return 1
    for wrong in ("-t tmpfs -o nosuid,noexec selinuxfs /sys/fs/selinux", "-t selinuxfs selinuxfs /sys/fs/selinux/x",
                  "-o nosuid,noexec selinuxfs /sys/fs/selinux"):
        if not any("no ExecStart= that mounts selinuxfs" in p for p in fs_probs(
                unit=good_unit.replace("-t selinuxfs -o nosuid,noexec selinuxfs /sys/fs/selinux", wrong))):
            print(f"selftest FAIL: ExecStart=/usr/bin/mount {wrong} was not flagged")
            return 1
    for prefix in EXEC_PREFIXES:
        for key in ("ExecStart", "ExecStartPre"):
            planted = (good_unit.replace("ExecStart=/usr/bin/mount", f"ExecStart={prefix}/usr/bin/mount")
                       if key == "ExecStart" else good_unit + f"ExecStartPre={prefix}/usr/bin/true\n")
            if not any("a prefix that changes" in p for p in fs_probs(unit=planted)):
                print(f"selftest FAIL: {key}={prefix}/usr/bin/... was not flagged")
                return 1
    if not any("ExecStop" in p for p in fs_probs(unit=good_unit + "ExecStop=/usr/bin/umount /sys/fs/selinux\n")):
        print("selftest FAIL: an ExecStop that unmounts selinuxfs was not flagged")
        return 1
    mount_fs_rules = good_rules + "\tinstall -m 0644 src/services/units/sys-fs-selinux.mount $(UNITS)/\n"
    if selinuxfs_unit_name(mount_fs_rules) != "sys-fs-selinux.mount" or not any(
            "not a service" in p for p in fs_probs(rules=mount_fs_rules)):
        print("selftest FAIL: a .mount unit for /sys/fs/selinux was not flagged")
        return 1

    print("selftest ok")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(os.path.join(ROOT, "debian", "rules")) as f:
        rules_text = f.read()
    with open(os.path.join(ROOT, "src", "install", "teardown", "teardown.sh")) as f:
        teardown_text = f.read()
    problems = drift(rules_text, teardown_text)
    with open(unit_files.unit_path(ROOT, "rhizo-policy.service")) as f:
        policy_text = f.read()
    with open(unit_files.unit_path(ROOT, "androidd.service")) as f:
        androidd_text = f.read()
    with open(unit_files.unit_path(ROOT, "rhizo-prepare.service")) as f:
        prepare_text = f.read()
    with open(unit_files.unit_path(ROOT, "androidd@.service")) as f:
        androidd_at_text = f.read()
    problems += policy_unit_ordering_problems(policy_text, androidd_text, prepare_text, androidd_at_text)

    def read_unit(name):
        """return the text of a unit file, or None"""
        path = unit_files.unit_path(ROOT, name)
        if not os.path.exists(path):
            return None
        with open(path) as f:
            return f.read()

    problems += selinuxfs_unit_problems(policy_text, prepare_text, rules_text, read_unit)
    for p in problems:
        print("packaged-units: " + p)
    if not problems:
        print("every packaged unit is removed, every removed unit is packaged, "
              "rhizo-policy.service's own ordering lines are intact, and the two boot units "
              "want and follow the selinuxfs mount")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
