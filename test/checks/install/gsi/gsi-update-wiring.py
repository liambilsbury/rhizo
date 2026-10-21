#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
ANDROIDD = os.path.join(REPO, "src", "services", "units", "boot", "androidd.service")
BEGIN = os.path.join(REPO, "src", "services", "units", "boot", "update-begin.service")
CONFIRM = os.path.join(REPO, "src", "services", "units", "boot", "update-confirm.service")
RULES = os.path.join(REPO, "debian", "rules")
REDEPLOY = os.path.join(REPO, "test", "vm", "redeploy.sh")
SYNC = os.path.join(REPO, "test", "vm", "sync.sh")
UPDATE_SH = os.path.join(REPO, "src", "install", "update", "gsi-update.sh")
RELEASE_MAP = os.path.join(REPO, "test", "vm", "image", "release-map.sh")
STATE_PATH = "/var/lib/rhizo/update/state"
OWNED = ("RHIZO_GSI", "RHIZO_RELEASE", "RHIZO_DATA_IMG", "RHIZO_DATA_RELEASE_CHANGE",
         "RHIZO_WIPE_DATA")


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def directive(text, key):
    """return the values of every line setting a key in a unit file"""
    return re.findall(r"^%s=(.*)$" % re.escape(key), text, re.M)


def release_trees_agree(update_sh, release_map):
    """check that the update script and release map agree"""
    fails = []
    block = re.search(r"declare -A GSI_DIR=\((.*?)\)", release_map, re.S)
    if not block:
        return ["release-map.sh no longer declares GSI_DIR"]
    mapped = dict(re.findall(r'\[(a\d+)\]="([^"]+)"', block.group(1)))
    case = re.search(r'release_tree\(\) \{.*?case "\$1" in(.*?)esac', update_sh, re.S)
    if not case:
        return ["gsi-update.sh no longer has a release_tree() case block"]
    ours = {}
    for labels, path in re.findall(r'([a-z0-9|]+)\)\s*echo "([^"]+)"', case.group(1)):
        for label in labels.split("|"):
            ours[label] = path.replace("$GSI_ROOT", "/srv/rhizo").replace("$1", label)
    for label, path in mapped.items():
        if label not in ours:
            fails.append("release-map.sh knows %s but gsi-update.sh does not" % label)
        elif ours[label] != path:
            fails.append("release %s is %s in release-map.sh and %s in gsi-update.sh"
                         % (label, path, ours[label]))
    for label in ours:
        if label not in mapped:
            fails.append("gsi-update.sh knows %s but release-map.sh does not" % label)
    return fails


def check(androidd, begin, confirm, rules, redeploy, update_sh, release_map):
    """check the update wiring"""
    fails = []

    wants = " ".join(directive(androidd, "Wants"))
    for unit in ("rhizo-update-begin.service", "rhizo-update-confirm.service"):
        if unit not in wants:
            fails.append("androidd.service does not Want %s" % unit)
    if "rhizo-update-begin.service" not in " ".join(directive(androidd, "After")):
        fails.append("androidd.service is not ordered After=rhizo-update-begin.service")

    if "androidd.service" not in " ".join(directive(begin, "Before")):
        fails.append("rhizo-update-begin.service is not Before=androidd.service")
    if directive(begin, "Type") != ["oneshot"]:
        fails.append("rhizo-update-begin.service is not Type=oneshot")

    if directive(confirm, "Type") == ["oneshot"]:
        fails.append("rhizo-update-confirm.service is Type=oneshot")
    if "androidd.service" not in " ".join(directive(confirm, "BindsTo")):
        fails.append("rhizo-update-confirm.service is not BindsTo=androidd.service")

    for name, text in (("begin", begin), ("confirm", confirm)):
        if STATE_PATH not in " ".join(directive(text, "ConditionPathExists")):
            fails.append("the %s unit does not condition on %s" % (name, STATE_PATH))

    execs = directive(begin, "ExecStart") + directive(confirm, "ExecStart")
    paths = set()
    for line in execs:
        m = re.search(r"(/\S*/gsi-update\.sh)", line)
        if m:
            paths.add(m.group(1))
        else:
            fails.append("a unit's ExecStart does not name gsi-update.sh: %s" % line)
    if len(paths) > 1:
        fails.append("the two units exec different paths: %s" % ", ".join(sorted(paths)))
    for path in paths:
        installed_dir = os.path.dirname(path)
        if "src/install/update/gsi-update.sh" not in rules:
            fails.append("debian/rules does not install src/install/update/gsi-update.sh")
        group = os.path.basename(installed_dir)
        loop = re.search(r"^for _group in ([^;]+);", redeploy, re.M)
        if (os.path.dirname(installed_dir) != "/usr/lib/rhizo/install" or not loop
                or group not in loop.group(1).split() or "install/%s/gsi-update.sh" % group not in redeploy):
            fails.append("redeploy.sh and sync.sh do not install gsi-update.sh into %s" % installed_dir)
        if "await-boot-completed.py" not in redeploy:
            fails.append("sync.sh does not stage await-boot-completed.py, which the "
                         "confirm command execs")

    written = set(re.findall(r"printf '(RHIZO_[A-Z_]+)=[^']*\\n'", update_sh))
    owned = re.search(r"^OWNED_KEYS='([^']*)'", update_sh, re.M)
    if not owned:
        fails.append("gsi-update.sh no longer declares OWNED_KEYS")
    else:
        declared = set(owned.group(1).split("|"))
        if declared != set(OWNED):
            fails.append("OWNED_KEYS is %s, want %s"
                         % (sorted(declared), sorted(OWNED)))
        unowned = written - declared
        if unowned:
            fails.append("gsi-update.sh writes %s into androidd.env without owning "
                         "them" % sorted(unowned))
    fails += release_trees_agree(update_sh, release_map)
    return fails


def read_inputs():
    """return check()'s arguments read from the tree"""
    return [read(ANDROIDD), read(BEGIN), read(CONFIRM), read(RULES), read(REDEPLOY) + read(SYNC),
            read(UPDATE_SH), read(RELEASE_MAP)]


def selftest():
    """check the real files and each planted-defect copy of them"""
    good = read_inputs()
    if check(*good):
        print("SELFTEST FAIL: the real tree does not pass its own check")
        return 1
    cases = [
        ("androidd stops wanting the begin unit",
         0, lambda t: t.replace("rhizo-update-begin.service rhizo-update-confirm.service",
                                "rhizo-update-confirm.service")),
        ("androidd loses its After ordering",
         0, lambda t: t.replace("After=rhizo-update-begin.service", "# gone")),
        ("the begin unit becomes Type=simple",
         1, lambda t: t.replace("Type=oneshot", "Type=simple")),
        ("the begin unit loses Before=",
         1, lambda t: t.replace("Before=androidd.service", "# gone")),
        ("the confirm unit becomes Type=oneshot",
         2, lambda t: t.replace("Type=simple", "Type=oneshot")),
        ("the confirm unit loses BindsTo=",
         2, lambda t: t.replace("BindsTo=androidd.service", "# gone")),
        ("a unit loses its state-file condition",
         1, lambda t: t.replace("ConditionPathExists=%s" % STATE_PATH, "# gone")),
        ("the deb stops installing the script",
         3, lambda t: t.replace("src/install/update/gsi-update.sh", "src/install/gone.sh")),
        ("redeploy stops staging the script",
         4, lambda t: t.replace("gsi-update.sh", "gone.sh")),
        ("a written key drops off OWNED_KEYS",
         5, lambda t: t.replace("OWNED_KEYS='RHIZO_GSI|RHIZO_DATA_IMG|RHIZO_RELEASE|RHIZO_DATA_RELEASE_CHANGE|RHIZO_WIPE_DATA'",
                                "OWNED_KEYS='RHIZO_GSI|RHIZO_RELEASE|RHIZO_DATA_RELEASE_CHANGE|RHIZO_WIPE_DATA'")),
        ("the release-to-tree mapping drifts from release-map.sh",
         5, lambda t: t.replace('a16) echo "$GSI_ROOT/gsi_system" ;;',
                                'a16) echo "$GSI_ROOT/gsi_system_a16" ;;')),
    ]
    bad = 0
    for name, idx, mangle in cases:
        args = list(good)
        args[idx] = mangle(args[idx])
        if args[idx] == good[idx]:
            print("SELFTEST FAIL: fixture '%s' changed nothing" % name)
            bad += 1
            continue
        if not check(*args):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if bad:
        return 1
    print("check-gsi-update-wiring selftest: every fixture failed as it should")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    for path in (ANDROIDD, BEGIN, CONFIRM, RULES, REDEPLOY, SYNC, UPDATE_SH, RELEASE_MAP):
        if not os.path.exists(path):
            print("FAIL: no %s" % path)
            return 1
    fails = check(*read_inputs())
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-gsi-update-wiring: the trial units are ordered, inert without state, "
          "and exec a path both the deb and redeploy install")
    return 0


if __name__ == "__main__":
    sys.exit(main())
