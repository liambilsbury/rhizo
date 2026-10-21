#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(HERE, "..", "..", "..", "system", "lib", "gsi-update-lib.sh")
REDEPLOY = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
KNOB = "RHIZO_RELEASE_SWITCH"

BOOT_AND_START_RE = re.compile(r'\nboot_and_start\(\) \{[^\n]*\n(.*?)\n\}\n', re.S)
STAGE_CALL_RE = re.compile(r'^[ \t]*(?:stage_release\b|"\$stage_fn")', re.M)
ANDROIDD_START_RE = re.compile(r'systemctl start androidd\.service')
NEAR_RE = re.compile(
    r'%s.{0,200}?androidd\.env|androidd\.env.{0,200}?%s' % (KNOB, KNOB), re.S)
TRUNCATE_RE = re.compile(r'cmd="\s*:\s*>\s*/root/androidd\.env\s*"')

CALLSITES = [
    ("leg 2 (a17 trial boot)",
     re.compile(r'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"[^\n]*\bRHIZO_RELEASE_SWITCH=1\b')),
    ("leg 3 (manual rollback boot)",
     re.compile(r'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"[^\n]*\bRHIZO_RELEASE_SWITCH=1\b')),
    ("leg 4 (each exhaustion try)",
     re.compile(r'boot_and_start "\$\{label_prefix\}-try-\$try" "\$to_rel"[^\n]*\bRHIZO_RELEASE_SWITCH=1\b')),
    ("leg 4 (try-exhaustion rollback)",
     re.compile(r'boot_and_start "\$\{label_prefix\}-final" "\$from_rel"[^\n]*\bRHIZO_RELEASE_SWITCH=1\b')),
]


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def strip_comments(text):
    """remove comment lines from the text"""
    return "\n".join(line for line in text.splitlines() if not re.match(r'^\s*#', line))


def check_test_arming_order(test_text):
    """return the problems in the test's release switch arming order"""
    fails = []
    code = strip_comments(test_text)

    m = BOOT_AND_START_RE.search(code)
    if not m:
        fails.append("gsi-update.sh's boot_and_start() could not be found; the %s arming order cannot "
                     "be verified" % KNOB)
        return fails
    body = m.group(1)

    stage_m = STAGE_CALL_RE.search(body)
    start_m = ANDROIDD_START_RE.search(body)
    if not stage_m or not start_m:
        fails.append("boot_and_start() no longer calls stage_release and/or starts "
                     "androidd.service the expected way; the %s arming order cannot be "
                     "verified" % KNOB)
        return fails
    if stage_m.start() >= start_m.start():
        fails.append("boot_and_start() starts androidd.service BEFORE its own stage_release "
                     "call")
        return fails

    outside_func = code[:m.start()] + "\n" + code[m.end():]
    inside_func_unsafe = body[:stage_m.start()] + "\n" + body[start_m.start():]

    if NEAR_RE.search(outside_func):
        fails.append(
            "%s is written into androidd.env OUTSIDE boot_and_start()" % KNOB)

    if NEAR_RE.search(inside_func_unsafe):
        fails.append(
            "%s is written into androidd.env inside boot_and_start(), but outside the window "
            "between its own stage_release call and its androidd start" % KNOB)

    return fails


def check_callsite_coverage(test_text):
    """return the problems for boot_and_start calls that do not arm the release switch"""
    fails = []
    code = strip_comments(test_text)
    for name, rx in CALLSITES:
        if not rx.search(code):
            fails.append(
                "%s's own boot_and_start call no longer arms %s=1" % (name, KNOB))
    return fails


def check_redeploy_truncate(redeploy_text):
    """return the problems in the redeploy script's truncation"""
    if not TRUNCATE_RE.search(redeploy_text):
        return ["redeploy.sh's _androidd_env_cmd no longer truncates /root/androidd.env "
                "(want `cmd=\": > /root/androidd.env\"`)"]
    return []


def check(test_text, redeploy_text):
    """return the problems from every release switch check"""
    fails = []
    fails.extend(check_test_arming_order(test_text))
    fails.extend(check_callsite_coverage(test_text))
    fails.extend(check_redeploy_truncate(redeploy_text))
    return fails


MERGE_BLOCK = '''  local env_file="${GSI_LEG_ENV_FILE:-/root/androidd.env}"
  if [[ -n "$extra_env" ]]; then
    for kv in $extra_env; do
      if [[ " ${GSI_LEG_SKIP_KNOBS:-} " == *" ${kv%%=*} "* ]]; then
        log "  $label: not arming ${kv%%=*}, a knob GSI_LEG_SKIP_KNOBS keeps off this caller's host"
        continue
      fi
      log "  $label: arming $kv in $env_file, after staging so redeploy.sh's own truncate-and-rewrite cannot silently wipe it before this boot's own start -- test/checks/system/gsi-update/fault-knob.py and test/checks/system/gsi-update/release-switch-marker.sh both own pieces of this contract"
      ssh_vm -t 20 "grep -q '^${kv%%=*}=' '$env_file' 2>/dev/null \\
        && sed -i 's/^${kv%%=*}=.*/${kv}/' '$env_file' \\
        || echo '$kv' >> '$env_file'"
    done
  fi
'''
LOCAL_LINE = '  local label="$1" rel="$2" preceding="${3:-}" extra_env="${4:-}" stage_fn="${5:-stage_release}" refusal kv'
LEG3_CALLSITE = ('if boot_and_start "${label_prefix}-rollback" "$from_rel" "$rollback_out" '
                  'RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then')
LITERAL_ARM_OUTSIDE = ("ssh_vm -t 20 \"echo 'RHIZO_RELEASE_SWITCH=1' >> /root/androidd.env\"\n")
TRUNCATE_LINE = 'cmd=": > /root/androidd.env"'
MERGE_TRUNCATE_LINE = ('cmd=$(cat /root/androidd.env 2>/dev/null || true)  # merge, not truncate')


def selftest():
    """check the real tree and each planted-defect copy"""
    good_test = read(TEST)
    good_redeploy = read(REDEPLOY)
    fails = check(good_test, good_redeploy)
    if fails:
        print("SELFTEST FAIL: the real tree does not pass its own check:")
        for f in fails:
            print("  " + f)
        return 1

    for anchor, path in ((MERGE_BLOCK, TEST), (LOCAL_LINE, TEST), (LEG3_CALLSITE, TEST),
                         (TRUNCATE_LINE, REDEPLOY)):
        text = good_test if path == TEST else good_redeploy
        if text.count(anchor) != 1:
            print("SELFTEST SETUP FAIL: anchor not found exactly once in %s: %r"
                  % (path, anchor[:60]))
            return 1

    test_armed_outside = good_test.replace(MERGE_BLOCK, "", 1)
    test_armed_outside = test_armed_outside.replace(
        LOCAL_LINE, LOCAL_LINE + "\n" + LITERAL_ARM_OUTSIDE, 1)

    test_leg3_stripped = good_test.replace(
        LEG3_CALLSITE,
        'if boot_and_start "${label_prefix}-rollback" "$from_rel" "$rollback_out"; then', 1)

    redeploy_merge = good_redeploy.replace(TRUNCATE_LINE, MERGE_TRUNCATE_LINE, 1)

    cases = [
        ("RHIZO_RELEASE_SWITCH armed outside boot_and_start (the f307d850/ef8a78c8 shape)",
         test_armed_outside, good_redeploy),
        ("leg 3's own call site stops arming RHIZO_RELEASE_SWITCH",
         test_leg3_stripped, good_redeploy),
        ("redeploy.sh's _androidd_env_cmd stops truncating androidd.env (merge instead)",
         good_test, redeploy_merge),
    ]
    bad = 0
    for name, test_text, redeploy_text in cases:
        if not check(test_text, redeploy_text):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if bad:
        return 1
    print("check-release-switch-ordering selftest: every fixture failed as it should")
    return 0


EXHAUSTION_CALLERS = (
    os.path.join(HERE, "..", "..", "..", "system", "install", "gsi-update.sh"),
    os.path.join(HERE, "..", "..", "..", "system", "cycle", "cycle.sh"),
)
EXHAUSTION_CALL_RE = re.compile(r'\bgsi_leg_exhaustion\b')


def check_exhaustion_callers():
    """return the problems in gsi_leg_exhaustion's callers"""
    fails = []
    for path in EXHAUSTION_CALLERS:
        try:
            text = read(path)
        except OSError:
            text = None
        if text is None:
            fails.append("cannot read %s to confirm it calls gsi_leg_exhaustion" % path)
            continue
        code = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
        if not EXHAUSTION_CALL_RE.search(code):
            fails.append("%s never calls gsi_leg_exhaustion" % path)
    return fails


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    for path in (TEST, REDEPLOY):
        if not os.path.exists(path):
            print("FAIL: no %s" % path)
            return 1
    fails = check(read(TEST), read(REDEPLOY))
    fails += check_exhaustion_callers()
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-release-switch-ordering: %s reaches androidd.env only from inside "
          "boot_and_start()'s own safe window, is armed by name at every call site still part "
          "of the switch, and redeploy.sh's own _androidd_env_cmd still truncates before "
          "rewriting" % KNOB)
    return 0


if __name__ == "__main__":
    sys.exit(main())
