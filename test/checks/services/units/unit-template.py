#!/usr/bin/env python3
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

PAIRS = [
    {
        "base": os.path.join(HERE, "..", "..", "..", "..", "src", "services", "units", "boot", "androidd.service"),
        "template": os.path.join(HERE, "..", "..", "..", "..", "src", "services", "units", "boot", "androidd@.service"),
        "id": "7",
        "added": [("Service", "EnvironmentFile", "-/etc/rhizo/instances/7.env"),
                  ("Service", "Environment", "RHIZO_SANDBOX_ID=7"),
                  ("Unit", "Wants", "rhizo-update-begin.service"),
                  ("Unit", "After", "rhizo-selinux-mode.service rhizo-host-labels.service")],
        "removed": [("Unit", "Wants", "rhizo-hostfs.service"),
                    ("Unit", "Wants", "rhizo-update-begin.service rhizo-update-confirm.service"),
                    ("Unit", "After", "rhizo-selinux-mode.service")],
        "value_may_differ": {"Description"},
        "value_transform": {
            "RuntimeDirectory": lambda v: v + "-7",
            "ExecStartPre": lambda v: v.replace("/run/rhizo-wayland", "/run/rhizo-wayland-7"),
            "StandardOutput": lambda v: v.replace("/root/boot.log", "/root/boot-7.log"),
            "StandardError": lambda v: v.replace("/root/boot.log", "/root/boot-7.log"),
        },
    },
    {
        "base": os.path.join(HERE, "..", "..", "..", "..", "src", "services", "server-idle", "server-idle.service"),
        "template": os.path.join(HERE, "..", "..", "..", "..", "src", "services", "server-idle", "server-idle@.service"),
        "id": "7",
        "added": [("Service", "EnvironmentFile", "-/etc/rhizo/instances/7.env"),
                  ("Service", "Environment", "RHIZO_SANDBOX_ID=7")],
        "value_may_differ": {"Description"},
        "value_transform": {
            "After": lambda v: v.replace("androidd.service", "androidd@7.service rhizo-host-labels.service"),
            "PartOf": lambda v: v.replace("androidd.service", "androidd@7.service"),
            "WantedBy": lambda v: v.replace("androidd.service", "androidd@7.service"),
        },
    },
]

_LINE_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*)\s*=(.*)$")

TEMPLATE_INSTANCE_KEYS = {
    "RuntimeDirectory", "PIDFile", "ListenStream", "ConditionPathExists",
    "ExecStartPre", "ExecStart", "ExecStop", "ExecStopPost", "EnvironmentFile",
    "StandardOutput", "StandardError",
}
_PATHLIKE_TESTD_KEYS = {"StandardOutput", "StandardError", "EnvironmentFile"}
_ALLOWLIST_RE = re.compile(r"^#\s*rhizo-template-allowlist:\s*([A-Za-z][A-Za-z0-9]*)\s*--\s*(\S.*)$")


def parse_template_allowlist(text):
    """return allowlist entries from the unit text"""
    allowlist = {}
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        m = _ALLOWLIST_RE.match(line)
        if m and section is not None:
            allowlist[(section, m.group(1))] = m.group(2)
    return allowlist


def check_template_instancing(template_path):
    """return template directives missing an instance specifier"""
    with open(template_path) as f:
        text = f.read()
    allowlist = parse_template_allowlist(text)
    violations = []
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        m = _LINE_RE.match(line)
        if not m or section is None:
            continue
        key, value = m.group(1), m.group(2)
        if key not in TEMPLATE_INSTANCE_KEYS:
            continue
        if key in _PATHLIKE_TESTD_KEYS and "/" not in value:
            continue
        if "%i" in value:
            continue
        if (section, key) in allowlist:
            continue
        violations.append((section, key, value))
    return violations


def parse_unit(text, sub_id=None):
    """parse unit text into directive tuples"""
    directives = []
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        m = _LINE_RE.match(line)
        if not m:
            raise ValueError("unparseable line (not Key=Value, not a comment, not a section): %r" % raw)
        if section is None:
            raise ValueError("directive %r appears before any [section] header" % raw)
        key, value = m.group(1), m.group(2)
        if sub_id is not None:
            value = value.replace("%i", sub_id)
        directives.append((section, key, value))
    return directives


def diff_units(base_text, template_text, sub_id, added, value_may_differ, value_transform=None, removed=None):
    """return the directive differences"""
    value_transform = value_transform or {}
    removed = removed or []
    base = parse_unit(base_text)
    template = parse_unit(template_text, sub_id=sub_id)

    def split(directives):
        """split the directives that may differ from those that must match"""
        free, fixed = [], []
        for d in directives:
            (free if d[1] in value_may_differ or d[1] in value_transform else fixed).append(d)
        return free, fixed

    base_free, base_fixed = split(base)
    tmpl_free, tmpl_fixed = split(template)

    removal_defects = []
    for item in removed:
        if item in base_fixed:
            base_fixed.remove(item)
        if item in tmpl_fixed:
            tmpl_fixed.remove(item)
            removal_defects.append(item)

    changed = []
    missing_extra_from_transform = []
    for section, key, value in base_free:
        matches = [d for d in tmpl_free if d[0] == section and d[1] == key]
        if key in value_transform:
            want = value_transform[key](value)
            got = matches[0][2] if matches else None
            if got != want:
                missing_extra_from_transform.append(
                    ("value_transform: [%s] %s expected %r (from base %r), got %r"
                     % (section, key, want, value, got)))
            continue
        if not matches:
            changed.append((section, key, value, None))
        elif matches[0][2] != value:
            changed.append((section, key, value, matches[0][2]))

    remaining_tmpl = list(tmpl_fixed)
    for item in added:
        if item in remaining_tmpl:
            remaining_tmpl.remove(item)
        else:
            changed.append((item[0], item[1], "<declared addition, not found>", item[2]))

    missing = list(base_fixed)
    extra = []
    for d in remaining_tmpl:
        if d in missing:
            missing.remove(d)
        else:
            extra.append(d)

    for msg in missing_extra_from_transform:
        extra.append(("value_transform", "mismatch", msg))
    for section, key, value in removal_defects:
        extra.append((section, key, "<declared removed, still present: %s>" % value))

    return missing, extra, changed


def _fmt(directives):
    """return the directives formatted as section, key and value strings"""
    return ["[%s] %s=%s" % d for d in directives]


def check_pair(pair):
    """return the problems when a template differs from its base unit"""
    with open(pair["base"]) as f:
        base_text = f.read()
    with open(pair["template"]) as f:
        template_text = f.read()
    missing, extra, changed = diff_units(
        base_text, template_text, pair["id"], pair["added"], pair["value_may_differ"],
        pair.get("value_transform"), pair.get("removed"))
    ok = not missing and not extra
    return ok, missing, extra, changed


def main():
    """check every base and template pair or run the selftest"""
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())

    failed = 0
    for pair in PAIRS:
        name = "%s vs %s" % (os.path.basename(pair["base"]), os.path.basename(pair["template"]))
        try:
            ok, missing, extra, changed = check_pair(pair)
            instancing = check_template_instancing(pair["template"])
        except (OSError, ValueError) as e:
            print("FAIL %s: %s" % (name, e))
            failed += 1
            continue
        if ok and not instancing:
            print("ok   %s (%d directive(s) declared as intentional differences)"
                  % (name, len(pair["added"])))
            for section, key, base_v, tmpl_v in changed:
                print("       note: [%s] %s differs (base=%r template=%r)" % (section, key, base_v, tmpl_v))
        else:
            print("FAIL %s" % name)
            for d in missing:
                print("       missing from the template (present in the base, dropped): [%s] %s=%s" % d)
            for d in extra:
                print("       extra in the template (not in the base, not declared as an intentional addition): [%s] %s=%s" % d)
            for section, key, value in instancing:
                print("       not %%i-scoped and not in %s's own rhizo-template-allowlist: [%s] %s=%s"
                      % (os.path.basename(pair["template"]), section, key, value))
            failed += 1

    if failed:
        print("%d unit pair(s) failed" % failed)
        sys.exit(1)
    print("all %d unit pair(s) match" % len(PAIRS))
    sys.exit(0)


def selftest():
    """check the template comparison against good and planted-defect units"""
    n = 0

    good_base = "[Unit]\nDescription=base\n[Service]\nExecStart=/bin/x\nKillMode=mixed\n"
    good_template = ("[Unit]\nDescription=base, instance %i\n[Service]\nExecStart=/bin/x\n"
                      "KillMode=mixed\nEnvironmentFile=-/etc/rhizo/instances/%i.env\n")
    pair = {"id": "0", "added": [("Service", "EnvironmentFile", "-/etc/rhizo/instances/0.env")],
            "value_may_differ": {"Description"}}

    missing, extra, changed = diff_units(good_base, good_template, pair["id"], pair["added"], pair["value_may_differ"])
    assert not missing and not extra, "a correctly-templated pair was flagged: missing=%r extra=%r" % (missing, extra); n += 1
    assert any(c[1] == "Description" for c in changed), "the declared Description difference was not even noted"; n += 1

    dropped_template = good_template.replace("KillMode=mixed\n", "")
    missing, extra, changed = diff_units(good_base, dropped_template, pair["id"], pair["added"], pair["value_may_differ"])
    assert ("Service", "KillMode", "mixed") in missing, "a dropped directive was not flagged as missing: %r" % missing; n += 1

    extra_template = good_template + "Restart=on-failure\n"
    missing, extra, changed = diff_units(good_base, extra_template, pair["id"], pair["added"], pair["value_may_differ"])
    assert ("Service", "Restart", "on-failure") in extra, "an undeclared extra directive was not flagged: %r" % extra; n += 1

    no_env_template = good_template.replace("EnvironmentFile=-/etc/rhizo/instances/%i.env\n", "")
    missing, extra, changed = diff_units(good_base, no_env_template, pair["id"], pair["added"], pair["value_may_differ"])
    assert any(c[0] == "Service" and c[1] == "EnvironmentFile" and "not found" in str(c[2]) for c in changed), \
        "a missing DECLARED addition was not flagged: %r" % changed; n += 1

    unsub_base = "[Unit]\n[Service]\nExecStart=/bin/x --id 3\n"
    unsub_template = "[Unit]\n[Service]\nExecStart=/bin/x --id %i\n"
    missing, extra, changed = diff_units(unsub_base, unsub_template, "3", [], set())
    assert not missing and not extra, "a correct %%i substitution was flagged: missing=%r extra=%r" % (missing, extra); n += 1

    unsub_template_wrong = "[Unit]\n[Service]\nExecStart=/bin/x --id %i-typo\n"
    missing, extra, changed = diff_units(unsub_base, unsub_template_wrong, "3", [], set())
    assert missing and extra, "a broken %%i substitution (still a distinct value after substitution) was not flagged"; n += 1

    vt_base = "[Unit]\nAfter=androidd.service\n"
    vt_good_template = "[Unit]\nAfter=androidd@9.service\n"
    vt_transform = {"After": lambda v: v.replace("androidd.service", "androidd@9.service")}
    missing, extra, changed = diff_units(vt_base, vt_good_template, "9", [], set(), vt_transform)
    assert not missing and not extra, "a correct value_transform substitution was flagged: %r/%r" % (missing, extra); n += 1

    vt_bad_template = "[Unit]\nAfter=androidd@WRONG.service\n"
    missing, extra, changed = diff_units(vt_base, vt_bad_template, "9", [], set(), vt_transform)
    assert any(d[0] == "value_transform" for d in extra), \
        "a WRONG value_transform substitution was not flagged: %r" % extra; n += 1

    rm_base = "[Unit]\nWants=rhizo-hostfs.service\n"
    rm_declared = [("Unit", "Wants", "rhizo-hostfs.service")]
    rm_good_template = "[Unit]\n"
    missing, extra, changed = diff_units(rm_base, rm_good_template, "9", [], set(), removed=rm_declared)
    assert not missing and not extra, \
        "a genuinely-removed declared directive was flagged: missing=%r extra=%r" % (missing, extra); n += 1

    rm_bad_template = "[Unit]\nWants=rhizo-hostfs.service\n"
    missing, extra, changed = diff_units(rm_base, rm_bad_template, "9", [], set(), removed=rm_declared)
    assert any(d[0] == "Unit" and d[1] == "Wants" and "still present" in str(d[2]) for d in extra), \
        "a declared removal that did not happen was not flagged: %r" % extra; n += 1

    with tempfile.TemporaryDirectory() as td:
        bare_path = os.path.join(td, "bare@.service")
        with open(bare_path, "w") as f:
            f.write("[Service]\nRuntimeDirectory=rhizo-wayland\n")
        violations = check_template_instancing(bare_path)
        assert any(v[0] == "Service" and v[1] == "RuntimeDirectory" for v in violations), \
            "a bare (non-%%i) RuntimeDirectory= was not flagged: %r" % (violations,); n += 1

        scoped_path = os.path.join(td, "scoped@.service")
        with open(scoped_path, "w") as f:
            f.write("[Service]\nRuntimeDirectory=rhizo-wayland-%i\n")
        violations = check_template_instancing(scoped_path)
        assert not violations, "a correctly %%i-scoped RuntimeDirectory= was flagged: %r" % (violations,); n += 1

        allowlisted_path = os.path.join(td, "allowlisted@.service")
        with open(allowlisted_path, "w") as f:
            f.write("[Service]\n# rhizo-template-allowlist: RuntimeDirectory -- shared on purpose, desk fixture\n"
                     "RuntimeDirectory=rhizo-wayland\n")
        violations = check_template_instancing(allowlisted_path)
        assert not violations, "an allowlisted bare directive was still flagged: %r" % (violations,); n += 1

        journal_path = os.path.join(td, "journal@.service")
        with open(journal_path, "w") as f:
            f.write("[Service]\nStandardOutput=journal\nStandardError=journal\n")
        violations = check_template_instancing(journal_path)
        assert not violations, "a symbolic StandardOutput=journal target was flagged: %r" % (violations,); n += 1

        envfile_bare = os.path.join(td, "envfile-bare@.service")
        with open(envfile_bare, "w") as f:
            f.write("[Service]\nEnvironmentFile=-/etc/rhizo/instances/3.env\n")
        violations = check_template_instancing(envfile_bare)
        assert any(v[0] == "Service" and v[1] == "EnvironmentFile" for v in violations), \
            "a bare (non-%%i, hand-typed) EnvironmentFile= was not flagged: %r" % (violations,); n += 1

        envfile_scoped = os.path.join(td, "envfile-scoped@.service")
        with open(envfile_scoped, "w") as f:
            f.write("[Service]\nEnvironmentFile=-/etc/rhizo/instances/%i.env\n")
        violations = check_template_instancing(envfile_scoped)
        assert not violations, "a correctly %%i-scoped EnvironmentFile= was flagged: %r" % (violations,); n += 1

        envfile_reset = os.path.join(td, "envfile-reset@.service")
        with open(envfile_reset, "w") as f:
            f.write("[Service]\nEnvironmentFile=\n")
        violations = check_template_instancing(envfile_reset)
        assert not violations, "a bare EnvironmentFile= reset (no value, no resource) was flagged: %r" % (violations,); n += 1

        envfile_allowlisted = os.path.join(td, "envfile-allowlisted@.service")
        with open(envfile_allowlisted, "w") as f:
            f.write("[Service]\n# rhizo-template-allowlist: EnvironmentFile -- shared on purpose, desk fixture\n"
                     "EnvironmentFile=-/root/androidd.env\n")
        violations = check_template_instancing(envfile_allowlisted)
        assert not violations, "an allowlisted, deliberately shared EnvironmentFile= was still flagged: %r" % (violations,); n += 1

    real_missing = real_extra = None
    real_failures = []
    real_instancing_failures = []
    checked = 0
    for real_pair in PAIRS:
        if not (os.path.exists(real_pair["base"]) and os.path.exists(real_pair["template"])):
            continue
        checked += 1
        ok, real_missing, real_extra, _ = check_pair(real_pair)
        if not ok:
            real_failures.append((real_pair["base"], real_missing, real_extra))
        instancing = check_template_instancing(real_pair["template"])
        if instancing:
            real_instancing_failures.append((real_pair["template"], instancing))
    assert not real_failures, "the real, committed unit pairs do not match: %r" % real_failures; n += 1
    assert not real_instancing_failures, \
        "the real, committed templates are not fully %%i-scoped or allowlisted: %r" % real_instancing_failures; n += 1
    assert checked == len(PAIRS), \
        "only %d of %d declared PAIRS were found on disk and actually checked" \
        % (checked, len(PAIRS)); n += 1

    print("check-unit-template selftest: %d assertions passed" % n)
    return 0


if __name__ == "__main__":
    main()
