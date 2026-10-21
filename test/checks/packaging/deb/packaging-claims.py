#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))

CONTROL = os.path.join(ROOT, "debian", "control")
RULES = os.path.join(ROOT, "debian", "rules")
CLI = os.path.join(ROOT, "src", "install", "cli", "rhizo.sh")

UNSHIPPED_DISCLOSURES = (
    "per-app audio routing is not shipped",
    "audio output does not work",
    "the desktop-bridge extras are not shipped",
)
DAEMON_NAMES = ("rhizo-audiod", "rhizo-deskd", "rhizo-wlbridge",
                "rhizo-displayd", "rhizo-keymapd")


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def check():
    """check the packaging files for outdated text"""
    fails = []
    looked_at = 0

    looked_at += 1
    if not (os.path.exists(CONTROL) and os.path.exists(RULES) and os.path.exists(CLI)):
        print("no debian/control, debian/rules or src/install/cli/rhizo.sh", file=sys.stderr)
        return 1
    control = read(CONTROL)
    rules = read(RULES)
    cli = read(CLI)
    still_unshipped = [d for d in DAEMON_NAMES if not re.search(re.escape(d), rules)]
    if still_unshipped:
        fails.append(
            f"{', '.join(still_unshipped)} is not installed anywhere in "
            "debian/rules")
    for text, label in ((control, "debian/control"), (cli, "src/install/cli/rhizo.sh")):
        for phrase in UNSHIPPED_DISCLOSURES:
            if phrase in text:
                fails.append(
                    f'{label} still carries the outdated line "{phrase}"')

    if not looked_at:
        print("no packaging-claims artifact was found under this tree", file=sys.stderr)
        return 1

    for line in fails:
        print(f"FAIL: {line}", file=sys.stderr)
    if fails:
        return 1
    print(f"debian/control's claim and rhizo doctor's disclosure are "
          f"consistent ({looked_at} group(s) checked)")
    return 0


GOOD_CONTROL = (
    "Description: Android on Linux\n"
    " Apps get real windows, real audio and the desktop-bridge daemons.\n"
)
GOOD_RULES = "".join(f"install -m 0755 src/services/x/{d}.py $(PAYLOAD)/x/\n" for d in DAEMON_NAMES)
GOOD_CLI = 'cmd_doctor() {\n  report audiod ok "rhizo-audiod.service is active"\n}\n'


def selftest():
    """test the packaging claims check on sample trees"""
    import tempfile

    problems = []
    with tempfile.TemporaryDirectory() as work:
        def write(rel, text):
            """write a fixture file under the work directory"""
            path = os.path.join(work, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

        write("debian/control", GOOD_CONTROL)
        write("debian/rules", GOOD_RULES)
        write("src/install/cli/rhizo.sh", GOOD_CLI)

        global CONTROL, RULES, CLI
        save = (CONTROL, RULES, CLI)
        CONTROL = os.path.join(work, "debian", "control")
        RULES = os.path.join(work, "debian", "rules")
        CLI = os.path.join(work, "src", "install", "cli", "rhizo.sh")
        try:
            if check() != 0:
                problems.append("a correctly-wired fixture (all five daemons in "
                                "debian/rules, no outdated disclosure text) was flagged")

            write("debian/rules", GOOD_RULES.replace("rhizo-audiod", "something-else"))
            if check() == 0:
                problems.append("a daemon missing from debian/rules was not flagged")
            write("debian/rules", GOOD_RULES)

            for rel, good in (("src/install/cli/rhizo.sh", GOOD_CLI), ("debian/control", GOOD_CONTROL)):
                write(rel, good + "\n# per-app audio routing is not shipped\n")
                if check() == 0:
                    problems.append(f"an outdated disclosure line surviving in {rel} was not flagged")
                write(rel, good)

            if check() != 0:
                problems.append("the fixture was not restored to clean after the negative cases")
        finally:
            CONTROL, RULES, CLI = save

    if problems:
        for p in problems:
            print(f"SELFTEST FAIL: {p}", file=sys.stderr)
        return 1
    print("selftest ok: a missing daemon and an outdated disclosure are both caught; "
         "a correctly-wired tree passes")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else check())
