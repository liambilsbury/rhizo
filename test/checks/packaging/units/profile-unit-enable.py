#!/usr/bin/env python3
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
CLI = "src/install/cli/rhizo.sh"
RULES = "debian/rules"
UNIT_HANDLING = (("postinst", "deb-systemd-invoke $_dh_action", "start"),
                 ("prerm", "deb-systemd-invoke stop", "stop"),
                 ("postrm", "deb-systemd-helper purge", "purge"))
UNRECORDED_UNIT_STUB = """#!/bin/sh
echo "${0##*/} $*" >> "$STUB_LOG"
case " $* " in *" debian-installed "*) exit 1 ;; esac
exit 0
"""


def load_setup_check():
    """return the dpkg-no-policy-start check module"""
    path = os.path.join(ROOT, "test", "checks", "install", "setup", "dpkg-no-policy-start.py")
    spec = importlib.util.spec_from_file_location("check_dpkg_no_policy_start", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DPKG_NO_POLICY_START = load_setup_check()
CheckError = DPKG_NO_POLICY_START.CheckError


def function_body(text, name):
    """return the lines of a shell function"""
    m = re.search(r"^%s\(\) \{(?:[ \t]*#[^\n]*)?\n(.*?)^\}$" % re.escape(name), text, re.M | re.S)
    if not m:
        raise CheckError("%s defines no %s()" % (CLI, name))
    return m.group(1)


def desktop_masked_units(cli_text):
    """return the units the desktop profile masks"""
    branches = function_body(cli_text, "apply_profile").split("\n  else\n", 1)
    if len(branches) != 2:
        raise CheckError("%s: apply_profile has no else branch for the desktop profile" % CLI)
    units = []
    for operand in re.findall(r"^[ \t]*systemctl mask (\S+)", branches[1], re.M):
        variable = re.fullmatch(r'"\$(\w+)"', operand)
        value = variable and re.search(r"^%s=(\S+)$" % variable.group(1), cli_text, re.M)
        if not value:
            raise CheckError("%s: the desktop branch of apply_profile masks %s, which is not one unit "
                             "named by a plain variable" % (CLI, operand))
        units.append(value.group(1))
    if not units:
        raise CheckError("%s: the desktop branch of apply_profile masks no unit" % CLI)
    return units


def first_install_enables(postinst):
    """return the units a first install enables"""
    with tempfile.TemporaryDirectory(prefix="check-profile-unit-enable.") as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        for tool in ("deb-systemd-helper", "deb-systemd-invoke", "systemctl"):
            path = os.path.join(bin_dir, tool)
            with open(path, "w") as fh:
                fh.write(UNRECORDED_UNIT_STUB)
            os.chmod(path, 0o755)
        script = os.path.join(tmp, "postinst")
        with open(script, "w") as fh:
            fh.write(postinst)
        log = os.path.join(tmp, "calls")
        r = subprocess.run(["/bin/sh", "-e", script, "configure"], capture_output=True, text=True, timeout=60,
                           env={"PATH": bin_dir, "STUB_LOG": log})
        if r.returncode != 0:
            raise CheckError("the generated postinst exits %d under sh -e configure: %s"
                             % (r.returncode, (r.stderr or r.stdout).strip()[-300:]))
        calls = []
        if os.path.exists(log):
            with open(log) as fh:
                calls = fh.read().splitlines()
    enabled = set()
    for call in calls:
        words = call.split()
        args = [w for w in words[1:] if not w.startswith("-")]
        if words[0] == "deb-systemd-helper" and args and args[0] == "enable":
            enabled.update(args[1:])
    return enabled


def script_runs_call_on(script_text, call, unit):
    """return whether the script runs call on unit"""
    return any(call in line and "'%s'" % unit in line for line in script_text.splitlines())


def check(root):
    """return the masked units and findings"""
    try:
        masked = desktop_masked_units(DPKG_NO_POLICY_START.read(os.path.join(root, CLI)))
        rules = DPKG_NO_POLICY_START.read(os.path.join(root, RULES))
        layout = DPKG_NO_POLICY_START.unit_layout(rules)
        generated = DPKG_NO_POLICY_START.dh_generated(root, rules, layout)
        enabled = first_install_enables(generated["postinst"])
    except CheckError as e:
        return [], [str(e)]
    findings = []
    for unit in masked:
        if unit not in layout:
            findings.append("%s installs no unit named %s, which rhizo install masks under the desktop profile"
                            % (RULES, unit))
            continue
        if unit in enabled:
            findings.append("dh_installsystemd enables %s on a first install, after rhizo install masked it under "
                            "the desktop profile: pass the unit to dh_installsystemd --no-enable in %s" % (unit, RULES))
        missing = [verb for script, call, verb in UNIT_HANDLING
                   if not script_runs_call_on(generated[script], call, unit)]
        if missing:
            findings.append("dh_installsystemd generates no %s handling for %s: "
                            "pass the unit to dh_installsystemd --no-enable in %s and leave out -X and --no-start"
                            % (", ".join(missing), unit, RULES))
    return masked, findings


def main():
    """print the findings and return an exit status"""
    masked, findings = check(ROOT)
    for finding in findings:
        print(finding, file=sys.stderr)
    if findings:
        return 1
    print("rhizo install masks %s under the desktop profile; dh_installsystemd leaves it unenabled on a first "
          "install and keeps its start, stop and purge handling" % ", ".join(masked))
    return 0


FX_RULES = """#!/usr/bin/make -f
UNITS := debian/rhizo/usr/lib/systemd/system

override_dh_auto_install:
\tinstall -m 0644 @INSTALLED@ $(UNITS)/

override_dh_installsystemd:
@RECIPE@"""
FX_INSTALLED = "src/services/units/idle.service src/services/units/other.service"
FX_UNIT = "[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n"
FX_CLI = """#!/bin/bash
SERVER_IDLE_UNIT=idle.service
IDLE_UNITS=(idle.service)
apply_profile() {  # apply_profile <desktop|server>
  local profile="$1"
  if [[ "$profile" == server ]]; then
    systemctl unmask "$SERVER_IDLE_UNIT"
    systemctl enable "$SERVER_IDLE_UNIT"
  else
    systemctl disable "$SERVER_IDLE_UNIT" >/dev/null 2>&1
    systemctl mask "$SERVER_IDLE_UNIT" \\
      || die "systemctl mask $SERVER_IDLE_UNIT failed"
  fi
}
"""
FX_MASK = 'systemctl mask "$SERVER_IDLE_UNIT" \\\n      || die "systemctl mask $SERVER_IDLE_UNIT failed"'
RECIPE_BARE = "\tdh_installsystemd\n"
RECIPE_NO_ENABLE = "\tdh_installsystemd --no-enable idle.service\n\tdh_installsystemd -Xidle.service\n"
RECIPE_EXCLUDED = "\tdh_installsystemd -Xidle.service\n"
RECIPE_NO_START = "\tdh_installsystemd --no-enable --no-start idle.service\n\tdh_installsystemd -Xidle.service\n"
RECIPE_FAILING_POSTINST = (RECIPE_NO_ENABLE
                           + "\techo 'echo cannot configure >&2; exit 7' >> debian/rhizo.postinst.debhelper\n")


def selftest():
    """check the findings for each fixture package"""
    fails, names = [], []
    with tempfile.TemporaryDirectory(prefix="check-profile-unit-enable.") as tmp:
        def case(name, want, recipe=RECIPE_NO_ENABLE, cli=FX_CLI, installed=FX_INSTALLED):
            """record a failure unless the findings match"""
            names.append(name)
            root = os.path.join(tmp, "t%d" % len(os.listdir(tmp)))
            files = {"debian/rules": FX_RULES.replace("@INSTALLED@", installed).replace("@RECIPE@", recipe),
                     CLI: cli, "src/services/units/idle.service": FX_UNIT, "src/services/units/other.service": FX_UNIT}
            for rel, text in files.items():
                os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
                with open(os.path.join(root, rel), "w") as fh:
                    fh.write(text)
            for debian_file in ("control", "changelog"):
                shutil.copy(os.path.join(ROOT, "debian", debian_file), os.path.join(root, "debian", debian_file))
            _, got = check(root)
            for text in want:
                if not any(text in g for g in got):
                    fails.append("%s: no finding carries %r; got %s" % (name, text, got or "none"))
            if len(got) != len(want):
                fails.append("%s: want %d finding(s), got %s" % (name, len(want), got or "none"))

        case("the unit in a --no-enable call", [])
        case("the unit left to the generic call", ["enables idle.service on a first install"], recipe=RECIPE_BARE)
        case("the unit excluded from dh_installsystemd", ["generates no start, stop, purge handling for idle.service"],
             recipe=RECIPE_EXCLUDED)
        case("the unit given --no-start", ["generates no start, stop handling for idle.service"],
             recipe=RECIPE_NO_START)
        case("the unit not installed", ["installs no unit named idle.service"], recipe=RECIPE_BARE,
             installed="src/services/units/other.service")
        case("a desktop branch masking nothing", ["masks no unit"], cli=FX_CLI.replace(FX_MASK, "true"))
        case("a desktop branch masking an array", ["not one unit named by a plain variable"],
             cli=FX_CLI.replace(FX_MASK, 'systemctl mask "${IDLE_UNITS[@]}"'))
        case("a cli without apply_profile", ["defines no apply_profile()"], cli="#!/bin/bash\n")
        case("a generated postinst that exits non-zero",
             ["the generated postinst exits 7 under sh -e configure: cannot configure"], recipe=RECIPE_FAILING_POSTINST)
    if fails:
        for f in fails:
            print(f, file=sys.stderr)
        return 1
    print("%d fixture packages give the wanted findings: %s" % (len(names), "; ".join(names)))
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else main())
