#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
POSTINST = os.path.join(ROOT, "debian", "rhizo.postinst")
CLI = os.path.join(ROOT, "src", "install", "cli", "rhizo.sh")
DROPIN = os.path.join(ROOT, "debian", "dropins", "androidd-desktop-daemons.conf")

DESKTOP_UNITS = ("rhizo-deskd.service", "rhizo-audiod.service",
                 "rhizo-displayd.service", "rhizo-keymapd.service")
DESKTOP_USER_UNITS = ("rhizo-desktop-session.path", "rhizo-desktop-session.service")

WANTS_DAEMONS = ("rhizo-deskd.service", "rhizo-audiod.service",
                 "rhizo-displayd.service", "rhizo-keymapd.service")

USER_RE = re.compile(r"^User=ubuntu\s*$", re.M)


def units_with_bare_user(root):
    """return units with a bare User=ubuntu line"""
    out = {}
    for name, rel in unit_files.unit_files(root, (".service",)).items():
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        if USER_RE.search(text):
            out[name] = "ubuntu"
    return out


def postinst_dropin_units(postinst_text):
    """return units with a User= drop-in in postinst"""
    out = set()
    for block in re.split(r"\n[ \t]*\n", postinst_text):
        names = re.findall(r"/etc/systemd/system/([\w.@-]+\.service)\.d", block)
        if names and "User=" in block:
            out.update(names)
    for loop in re.findall(r"for unit in ([^;]+?);\s*do(.*?)done", postinst_text, re.S):
        names, body = loop
        if (".service.d" not in body and "$unit.d" not in body) or "User=" not in body:
            continue
        out.update(n for n in names.split() if n.endswith(".service"))
    return out


def server_masked_units(cli_text, name="SERVER_MASKED_UNITS"):
    """return the set of server-masked unit names in the cli text, or None"""
    m = re.search(r"^" + name + r"=\((.*?)\)", cli_text, re.S | re.M)
    if not m:
        return None
    return set(m.group(1).split())


def dropin_wants(dropin_text):
    """return the Wants= units from a drop-in"""
    lines = re.findall(r"^Wants=(.*)$", dropin_text, re.M)
    if not lines:
        return None
    out = []
    for line in lines:
        out.extend(line.split())
    return out


def check(root):
    """return the desktop unit wiring failures"""
    fails = []

    postinst_text = maint_inline.inlined(POSTINST)
    bare_user = units_with_bare_user(root)
    if not bare_user:
        fails.append("no tracked unit carries a bare User= line")
    dropin_units = postinst_dropin_units(postinst_text)
    for unit, owner in sorted(bare_user.items()):
        if unit not in dropin_units:
            fails.append("%s carries User=%s and debian/rhizo.postinst writes it no "
                         "drop-in to override that on a packaged install" % (unit, owner))

    with open(CLI, encoding="utf-8") as fh:
        cli_text = fh.read()
    masked = server_masked_units(cli_text)
    user_masked = server_masked_units(cli_text, "SERVER_MASKED_USER_UNITS")
    if masked is None:
        fails.append("src/install/cli/rhizo.sh has no SERVER_MASKED_UNITS=( ... ) array to read")
    else:
        for unit in DESKTOP_UNITS:
            if unit not in masked:
                fails.append("%s is a desktop-cluster unit and src/install/cli/rhizo.sh's "
                             "SERVER_MASKED_UNITS does not mask it" % unit)
        for unit in DESKTOP_USER_UNITS:
            if unit in masked:
                fails.append("%s is a user unit and src/install/cli/rhizo.sh's SERVER_MASKED_UNITS "
                             "masks it in the system manager, where it does not run" % unit)
    if user_masked is None:
        fails.append("src/install/cli/rhizo.sh has no SERVER_MASKED_USER_UNITS=( ... ) array to read")
    else:
        for unit in DESKTOP_USER_UNITS:
            if unit not in user_masked:
                fails.append("%s is a desktop-cluster user unit and src/install/cli/rhizo.sh's "
                             "SERVER_MASKED_USER_UNITS does not mask it" % unit)

    if not os.path.exists(DROPIN):
        fails.append("%s does not exist" % os.path.relpath(DROPIN, root))
    else:
        with open(DROPIN, encoding="utf-8") as fh:
            wants = dropin_wants(fh.read())
        if wants is None:
            fails.append("%s has no Wants= line to read" % os.path.relpath(DROPIN, root))
        else:
            want_set, expect_set = set(wants), set(WANTS_DAEMONS)
            for missing in sorted(expect_set - want_set):
                fails.append("%s Wants= is missing %s" % (os.path.relpath(DROPIN, root), missing))
            for extra in sorted(want_set - expect_set):
                fails.append("%s Wants= names %s, which is not one of the four daemons"
                             % (os.path.relpath(DROPIN, root), extra))

    return fails


def selftest():
    """run the checks against fixture trees"""
    import tempfile

    fail = 0
    with tempfile.TemporaryDirectory() as work:
        os.makedirs(os.path.join(work, "src", "install"))
        os.makedirs(os.path.join(work, "debian", "dropins"))

        def write(rel, text):
            """write a fixture file under the work directory"""
            path = os.path.join(work, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

        good_postinst = (
            "mkdir -p /etc/systemd/system/rhizo-app-events.service.d\n"
            "printf '[Service]\\nUser=%s\\n' \"$owner\" > /etc/systemd/system/rhizo-app-events.service.d/10.conf\n"
            "\n"
            "for unit in rhizo-deskd.service; do\n"
            "  mkdir -p \"/etc/systemd/system/$unit.d\"\n"
            "  printf '[Service]\\nUser=%s\\n' \"$owner\" > \"/etc/systemd/system/$unit.d/10.conf\"\n"
            "done\n"
            "mkdir -p /etc/systemd/system/rhizo-audiod.service.d\n"
            "printf '[Service]\\nUser=%s\\n' \"$owner\" > /etc/systemd/system/rhizo-audiod.service.d/10.conf\n"
        )
        write("debian/rhizo.postinst", good_postinst)
        write("src/services/appsync/app-events.service", "[Service]\nUser=ubuntu\n")
        write("src/services/deskbridge/deskd.service", "[Service]\nUser=ubuntu\n")
        write("src/services/audiod/audiod.service", "[Service]\nUser=ubuntu\nGroup=rhizo\n")
        write("src/services/units/session/desktop-session.service", "[Service]\nType=oneshot\n")
        write("src/services/displayd/displayd.service", "[Service]\nType=simple\n")
        good_masked = ("SERVER_MASKED_UNITS=(rhizo-display-pool.path rhizo-app-events.service\n"
                       "                      rhizo-deskd.service rhizo-audiod.service\n"
                       "                      rhizo-displayd.service rhizo-keymapd.service)\n"
                       "SERVER_MASKED_USER_UNITS=(rhizo-desktop-session.path rhizo-desktop-session.service)\n")
        write("src/install/cli/rhizo.sh", good_masked)
        good_dropin = "[Unit]\nWants=rhizo-deskd.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service\n"
        write("debian/dropins/androidd-desktop-daemons.conf", good_dropin)

        global POSTINST, CLI, DROPIN
        save = (POSTINST, CLI, DROPIN)
        POSTINST = os.path.join(work, "debian", "rhizo.postinst")
        CLI = os.path.join(work, "src", "install", "cli", "rhizo.sh")
        DROPIN = os.path.join(work, "debian", "dropins", "androidd-desktop-daemons.conf")
        try:
            if check(work):
                print("SELFTEST FAILED: a correctly-wired fixture was flagged: %s" % check(work))
                fail = 1

            write("src/services/keymapd/keymapd.service", "[Service]\nUser=ubuntu\n")
            problems = check(work)
            if not any("rhizo-keymapd.service carries User=ubuntu" in p for p in problems):
                print("SELFTEST FAILED: a User=-bearing unit with no drop-in was not flagged: %s" % problems)
                fail = 1
            write("src/services/keymapd/keymapd.service", "[Service]\nType=simple\n")

            bad_masked = ("SERVER_MASKED_UNITS=(rhizo-display-pool.path rhizo-app-events.service\n"
                         "                      rhizo-deskd.service rhizo-audiod.service\n"
                         "                      rhizo-displayd.service)\n"
                         "SERVER_MASKED_USER_UNITS=(rhizo-desktop-session.path rhizo-desktop-session.service)\n")
            write("src/install/cli/rhizo.sh", bad_masked)
            problems = check(work)
            if not any("rhizo-keymapd.service is a desktop-cluster unit" in p for p in problems):
                print("SELFTEST FAILED: a desktop unit missing from SERVER_MASKED_UNITS was not flagged: %s" % problems)
                fail = 1
            write("src/install/cli/rhizo.sh", good_masked)

            write("src/install/cli/rhizo.sh", good_masked.replace(
                "SERVER_MASKED_USER_UNITS=(rhizo-desktop-session.path rhizo-desktop-session.service)",
                "SERVER_MASKED_USER_UNITS=(rhizo-desktop-session.service)"))
            problems = check(work)
            if not any("rhizo-desktop-session.path is a desktop-cluster user unit" in p for p in problems):
                print("SELFTEST FAILED: a user unit missing from SERVER_MASKED_USER_UNITS was not flagged: %s" % problems)
                fail = 1

            write("src/install/cli/rhizo.sh", good_masked.replace(
                "rhizo-displayd.service rhizo-keymapd.service)",
                "rhizo-displayd.service rhizo-keymapd.service rhizo-desktop-session.path)", 1))
            problems = check(work)
            if not any("rhizo-desktop-session.path is a user unit and src/install/cli/rhizo.sh's "
                       "SERVER_MASKED_UNITS masks it" in p for p in problems):
                print("SELFTEST FAILED: a user unit in SERVER_MASKED_UNITS was not flagged: %s" % problems)
                fail = 1
            write("src/install/cli/rhizo.sh", good_masked)

            write("debian/dropins/androidd-desktop-daemons.conf",
                  "[Unit]\nWants=rhizo-deskd.service rhizo-audiod.service rhizo-displayd.service\n")
            problems = check(work)
            if not any("Wants= is missing rhizo-keymapd.service" in p for p in problems):
                print("SELFTEST FAILED: a drop-in missing a daemon was not flagged: %s" % problems)
                fail = 1

            write("debian/dropins/androidd-desktop-daemons.conf",
                  good_dropin.rstrip("\n") + " rhizo-desktop-session.service\n")
            problems = check(work)
            if not any("names rhizo-desktop-session.service" in p for p in problems):
                print("SELFTEST FAILED: a drop-in over-naming desktop-session.service was not flagged: %s" % problems)
                fail = 1
            write("debian/dropins/androidd-desktop-daemons.conf", good_dropin)

            write("debian/dropins/androidd-desktop-daemons.conf",
                  "[Unit]\nWants=rhizo-deskd.service rhizo-audiod.service\n"
                  "Wants=rhizo-displayd.service rhizo-keymapd.service\n")
            if check(work):
                print("SELFTEST FAILED: a Wants= list correctly split across two lines "
                     "was flagged: %s" % check(work))
                fail = 1
            write("debian/dropins/androidd-desktop-daemons.conf",
                  "[Unit]\nWants=rhizo-deskd.service rhizo-audiod.service\n"
                  "Wants=rhizo-displayd.service\n")
            problems = check(work)
            if not any("Wants= is missing rhizo-keymapd.service" in p for p in problems):
                print("SELFTEST FAILED: a daemon missing from a Wants= line's SECOND "
                     "occurrence was not flagged: %s" % problems)
                fail = 1
            write("debian/dropins/androidd-desktop-daemons.conf", good_dropin)

            write("debian/rhizo.postinst",
                  good_postinst + "\nmkdir -p /etc/systemd/system/rhizo-keymapd.service.d\n"
                  "printf '[Service]\\nGroup=rhizo\\n' > /etc/systemd/system/rhizo-keymapd.service.d/10.conf\n")
            write("src/services/keymapd/keymapd.service", "[Service]\nUser=ubuntu\n")
            problems = check(work)
            if not any("rhizo-keymapd.service carries User=ubuntu" in p for p in problems):
                print("SELFTEST FAILED: a .service.d path with no User= line in its own "
                     "block was wrongly accepted as an override: %s" % problems)
                fail = 1
            write("debian/rhizo.postinst", good_postinst)
            write("src/services/keymapd/keymapd.service", "[Service]\nType=simple\n")

            if check(work):
                print("SELFTEST FAILED: the fixture was not restored to clean after the negative cases: %s" % check(work))
                fail = 1
        finally:
            POSTINST, CLI, DROPIN = save

    if fail:
        print("desktop-units.py selftest: FAILED")
        return 1
    print("desktop-units.py selftest: ok")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: desktop-units.py [--selftest]", file=sys.stderr)
        return 2
    fails = check(ROOT)
    for f in fails:
        print("desktop-units: " + f, file=sys.stderr)
    if fails:
        return 1
    print("desktop-units: every User=-bearing unit has a postinst drop-in, every desktop "
         "unit is server-masked in the manager it runs in, the androidd drop-in Wants= "
         "exactly the four daemons")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
