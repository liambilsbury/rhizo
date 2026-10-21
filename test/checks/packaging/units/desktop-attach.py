#!/usr/bin/env python3
import base64
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SESSION = "/run/rhizo-desktop/session.env"
PATH_UNIT = "rhizo-desktop-attach.path"
SVC_UNIT = "rhizo-desktop-attach.service"
UNITS_DIR = os.path.join("src", "services", "units", "session")
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import unit_files  # noqa: E402
EMBEDDER = os.path.join("debian", "embed-teardown.py")


def read(root, rel):
    """return a file's text, or empty when absent"""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def keys(text, key):
    """return every value of a unit-file key"""
    return re.findall(r"^" + re.escape(key) + r"=(.*?)\s*$", text, re.M)


def embedded(text):
    """return the text with its base64 heredoc blocks decoded"""
    out = [text]
    for m in re.finditer(r"<<'(\w+_B64)'[^\n]*\n(.*?)\n\1\n", text, re.S):
        try:
            out.append(base64.b64decode(m.group(2)).decode("utf-8", "replace"))
        except ValueError:
            pass
    return "\n".join(out)


def postrm_text(root):
    """return the postrm debian/embed-teardown.py writes"""
    spec = importlib.util.spec_from_file_location("embed_teardown", os.path.join(root, EMBEDDER))
    try:
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.postrm_text(root)
    except (OSError, ValueError):
        return ""


def array(text, name):
    """return the words of a shell array, or None"""
    m = re.search(r"^\s*" + name + r"=\((.*?)\)", text, re.S | re.M)
    return set(m.group(1).split()) if m else None


def check(root):
    """return the attach wiring failures"""
    fails = []
    units = unit_files.unit_files(root)

    def rel(name):
        """return the unit's path in root, or where the attach units belong"""
        return units.get(name, os.path.join(UNITS_DIR, name))
    session_units = []
    for name in sorted(units):
        if not name.endswith(".service"):
            continue
        text = read(root, units[name])
        if any(v.lstrip("-") == SESSION for v in keys(text, "EnvironmentFile")):
            session_units.append(name)
            if SESSION not in keys(text, "ConditionPathExists"):
                fails.append("%s reads %s and has no ConditionPathExists= on it" % (name, SESSION))
    if not session_units:
        fails.append("no system unit has EnvironmentFile=%s" % SESSION)

    path = read(root, rel(PATH_UNIT))
    if keys(path, "PathChanged") != [SESSION]:
        fails.append("%s must have exactly PathChanged=%s" % (PATH_UNIT, SESSION))
    if keys(path, "Unit") != [SVC_UNIT]:
        fails.append("%s must have Unit=%s" % (PATH_UNIT, SVC_UNIT))
    if keys(path, "StartLimitIntervalSec") != ["0"]:
        fails.append("%s must have StartLimitIntervalSec=0" % PATH_UNIT)
    if keys(path, "WantedBy") != ["multi-user.target"]:
        fails.append("%s must be WantedBy=multi-user.target" % PATH_UNIT)

    svc = read(root, rel(SVC_UNIT))
    conds = keys(svc, "ExecCondition")
    if not any(SESSION in c and "test -e" in c for c in conds):
        fails.append("%s has no ExecCondition= gating on %s" % (SVC_UNIT, SESSION))
    if not any("is-active" in c and "androidd.service" in c for c in conds):
        fails.append("%s has no ExecCondition= gating on androidd.service being active" % SVC_UNIT)
    starts = keys(svc, "ExecStart")
    started = sorted(w for s in starts for w in s.split() if w.endswith(".service"))
    if len(starts) != 1 or "systemctl start" not in starts[0] or started != sorted(session_units):
        fails.append("%s must ExecStart exactly one systemctl start of %s, found %s"
                     % (SVC_UNIT, sorted(session_units), starts))
    if starts and "--no-block" not in starts[0].split():
        fails.append("%s waits on the daemons' start jobs: want --no-block"
                     % SVC_UNIT)
    if "reset-failed" in svc:
        fails.append("%s runs reset-failed" % SVC_UNIT)
    if keys(svc, "Type") != ["oneshot"]:
        fails.append("%s must be Type=oneshot" % SVC_UNIT)

    lib = read(root, os.path.join("src", "install", "lib", "pkg-lib.sh"))
    m = re.search(r"pkg_enable_core_units\(\)\s*\{(.*?)^\}", lib, re.S | re.M)
    if not m or PATH_UNIT not in m.group(1):
        fails.append("pkg_enable_core_units does not enable %s" % PATH_UNIT)
    elif "masked" not in m.group(1):
        fails.append("pkg_enable_core_units does not honor a server-profile mask")
    if m and not re.search(r"systemctl start \"?\$unit\"?|systemctl start %s" % re.escape(PATH_UNIT), m.group(1)):
        fails.append("pkg_enable_core_units enables %s but does not start it for the boot already running" % PATH_UNIT)

    masked = array(read(root, os.path.join("src", "install", "cli", "rhizo.sh")), "SERVER_MASKED_UNITS")
    teardown = array(read(root, os.path.join("src", "install", "teardown", "teardown.sh")), "UNITS")
    rules = read(root, os.path.join("debian", "rules"))
    postrm = embedded(postrm_text(root))
    for unit in (PATH_UNIT, SVC_UNIT):
        if masked is None or unit not in masked:
            fails.append("%s is not in rhizo.sh's SERVER_MASKED_UNITS" % unit)
        if teardown is None or unit not in teardown:
            fails.append("%s is not in teardown.sh's UNITS" % unit)
        if postrm.count(unit) < 1:
            fails.append("%s is not embedded in debian/rhizo.postrm" % unit)
        if rules.count(rel(unit)) < 2:
            fails.append("%s is not both listed and installed in debian/rules" % unit)
    return fails


GOOD = {
    "src/services/deskbridge/deskd.service":
        "[Unit]\nConditionPathExists=%s\n[Service]\nEnvironmentFile=%s\n" % (SESSION, SESSION),
    "src/services/audiod/audiod.service":
        "[Unit]\nConditionPathExists=%s\n[Service]\nEnvironmentFile=%s\n" % (SESSION, SESSION),
    "src/services/units/session/" + PATH_UNIT:
        "[Unit]\nStartLimitIntervalSec=0\n[Path]\nPathChanged=%s\nUnit=%s\n"
        "[Install]\nWantedBy=multi-user.target\n" % (SESSION, SVC_UNIT),
    "src/services/units/session/" + SVC_UNIT:
        "[Service]\nType=oneshot\nExecCondition=/usr/bin/test -e %s\n"
        "ExecCondition=/usr/bin/systemctl is-active --quiet androidd.service\n"
        "ExecStart=/usr/bin/systemctl start --no-block rhizo-deskd.service rhizo-audiod.service\n" % SESSION,
    "src/install/lib/pkg-lib.sh":
        "pkg_enable_core_units() {\n  for unit in a.path %s; do\n    case x in\n"
        "      masked|masked-runtime) continue ;;\n    esac\n    systemctl enable \"$unit\"\n"
        "    systemctl start \"$unit\"\n  done\n}\n" % PATH_UNIT,
    "src/install/cli/rhizo.sh": "SERVER_MASKED_UNITS=(a %s %s)\n" % (PATH_UNIT, SVC_UNIT),
    "src/install/teardown/teardown.sh": "UNITS=(a %s %s)\n" % (PATH_UNIT, SVC_UNIT),
    EMBEDDER: read(ROOT, EMBEDDER),
    "debian/rhizo.postrm.in": "#!/bin/sh\n# ---- BEGIN embedded teardown: debian/embed-teardown.py --write "
                              "----\n# ---- END embedded teardown ----\n",
    "src/install/teardown/teardown-lib.sh": "",
    "src/install/lib/host-flavor.sh": "",
    "src/install/bootstrap/bootloader.sh": "",
    "src/androidd/host/selinux-mode.py": "",
    "debian/rules":
        "\tsrc/services/units/session/%s src/services/units/session/%s\n"
        "\tinstall src/services/units/session/%s src/services/units/session/%s\n" % (PATH_UNIT, SVC_UNIT, PATH_UNIT, SVC_UNIT),
}

DEFECTS = {
    "deskd without the condition": ("src/services/deskbridge/deskd.service",
        "ConditionPathExists=%s\n" % SESSION, "", "rhizo-deskd.service reads"),
    "path watching the wrong file": ("src/services/units/session/" + PATH_UNIT,
        "PathChanged=%s" % SESSION, "PathChanged=/run/x", "exactly PathChanged="),
    "path naming the wrong unit": ("src/services/units/session/" + PATH_UNIT,
        "Unit=" + SVC_UNIT, "Unit=other.service", "must have Unit="),
    "path with a start limit": ("src/services/units/session/" + PATH_UNIT,
        "StartLimitIntervalSec=0\n", "", "StartLimitIntervalSec=0"),
    "service not gated on the file": ("src/services/units/session/" + SVC_UNIT,
        "ExecCondition=/usr/bin/test -e %s\n" % SESSION, "", "gating on " + SESSION),
    "service not gated on androidd": ("src/services/units/session/" + SVC_UNIT,
        "ExecCondition=/usr/bin/systemctl is-active --quiet androidd.service\n", "", "androidd.service being active"),
    "service starting too few units": ("src/services/units/session/" + SVC_UNIT,
        " rhizo-audiod.service", "", "exactly one systemctl start"),
    "service resetting failures": ("src/services/units/session/" + SVC_UNIT,
        "[Service]\n", "[Service]\nExecStopPost=/usr/bin/systemctl reset-failed\n", "reset-failed"),
    "service waiting on the daemons": ("src/services/units/session/" + SVC_UNIT,
        "start --no-block ", "start ", "want --no-block"),
    "path not started at install": ("src/install/lib/pkg-lib.sh",
        "    systemctl start \"$unit\"\n", "", "does not start it"),
    "path not enabled at install": ("src/install/lib/pkg-lib.sh",
        "a.path %s;" % PATH_UNIT, "a.path;", "does not enable"),
    "enable ignoring the mask": ("src/install/lib/pkg-lib.sh",
        "masked|masked-runtime", "x", "does not honor"),
    "path not server-masked": ("src/install/cli/rhizo.sh",
        "a %s %s" % (PATH_UNIT, SVC_UNIT), "a " + SVC_UNIT, PATH_UNIT + " is not in rhizo.sh"),
    "service not in teardown": ("src/install/teardown/teardown.sh",
        " " + SVC_UNIT, "", SVC_UNIT + " is not in teardown.sh"),
    "teardown not embedded in the postrm": (EMBEDDER,
        '("src/install/teardown/teardown.sh", "install/teardown/teardown.sh", "RHIZO_HOST_TEARDOWN_B64"),', "",
        SVC_UNIT + " is not embedded"),
    "service not installed by the deb": ("debian/rules",
        "\tinstall src/services/units/session/%s src/services/units/session/%s" % (PATH_UNIT, SVC_UNIT),
        "\tinstall src/services/units/" + PATH_UNIT, SVC_UNIT + " is not both listed"),
}


def selftest():
    """plant each defect and assert it by name"""
    import tempfile
    bad = 0
    with tempfile.TemporaryDirectory() as work:
        def build(mutate=None):
            """write the fixture tree with a mutation"""
            for rel, text in GOOD.items():
                if mutate and mutate[0] == rel:
                    if mutate[1] not in text:
                        raise SystemExit("selftest bug: %r not in %s" % (mutate[1], rel))
                    text = text.replace(mutate[1], mutate[2], 1)
                path = os.path.join(work, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
        build()
        got = check(work)
        if got:
            print("SELFTEST FAILED: the correct fixture was flagged: %s" % got)
            bad += 1
        for name, (rel, old, new, phrase) in DEFECTS.items():
            build((rel, old, new))
            got = check(work)
            if not any(phrase in f for f in got):
                print("SELFTEST FAILED: '%s' was not flagged with '%s': %s" % (name, phrase, got))
                bad += 1
    if bad:
        return 1
    print("desktop-attach selftest: the correct fixture passes and %d defects are each flagged" % len(DEFECTS))
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: desktop-attach.py [--selftest]", file=sys.stderr)
        return 2
    fails = check(ROOT)
    for f in fails:
        print("desktop-attach: " + f, file=sys.stderr)
    if fails:
        return 1
    print("desktop-attach: every session.env unit is conditioned on it, the attach pair watches "
          "and starts them, enabled at install, masked, torn down and shipped")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
