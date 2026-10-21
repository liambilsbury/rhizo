#!/usr/bin/env python3

import ast
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
ENV_FILE = os.path.join(REPO, "debian", "androidd.env")
ENV_MODULE = os.path.join(REPO, "src", "androidd", "sandbox", "core.py")
TEST = os.path.join(REPO, "test", "system", "lib", "gsi-update-lib.sh")
KNOB = "RHIZO_FAULT_NO_READY"
GUARD = re.compile(r'if os\.environ\.get\("%s"\)\s*==\s*"([^"]*)":' % KNOB)

BOOT_AND_START_RE = re.compile(r'\nboot_and_start\(\) \{[^\n]*\n(.*?)\n\}\n', re.S)
STAGE_CALL_RE = re.compile(r'^[ \t]*(?:stage_release\b|"\$stage_fn")', re.M)
ANDROIDD_START_RE = re.compile(r'systemctl start androidd\.service')
NEAR_RE = re.compile(
    r'%s.{0,200}?androidd\.env|androidd\.env.{0,200}?%s' % (KNOB, KNOB), re.S)


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def strip_comments(text):
    """remove the comment lines from the text"""
    return "\n".join(line for line in text.splitlines() if not re.match(r'^\s*#', line))


def check_test_arming_order(test_text):
    """return the problems in the test's fault knob arming order"""
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

    safe_window = body[stage_m.start():start_m.start()]
    outside_func = code[:m.start()] + "\n" + code[m.end():]
    inside_func_unsafe = body[:stage_m.start()] + "\n" + body[start_m.start():]

    if NEAR_RE.search(outside_func):
        fails.append(
            "%s is written into androidd.env OUTSIDE boot_and_start()" % KNOB)

    if NEAR_RE.search(inside_func_unsafe):
        fails.append(
            "%s is written into androidd.env inside boot_and_start(), but outside the window "
            "between its own stage_release call and its androidd start" % KNOB)

    direct_in_window = bool(NEAR_RE.search(safe_window))
    passthrough_call = re.search(r'boot_and_start\b[^\n]*\b%s\b' % KNOB, code) is not None
    window_writes_env = "androidd.env" in safe_window
    if not direct_in_window and not (passthrough_call and window_writes_env):
        fails.append(
            "no reachable place arms %s into androidd.env inside boot_and_start()'s own safe "
            "window (after its stage_release call, before it starts androidd.service)" % KNOB)

    return fails


class _Exited(Exception):
    pass


def guard_exit(launcher_text, env):
    """return the knob guard exit code and error"""
    try:
        tree = ast.parse(launcher_text)
    except SyntaxError as e:
        return None, "launcher3.py does not parse: %s" % e
    ifs = [n for n in ast.walk(tree) if isinstance(n, ast.If) and KNOB in ast.unparse(n.test)]
    if len(ifs) != 1:
        return None, "launcher3.py has %d if-statements testing %s -- want exactly one" % (len(ifs), KNOB)

    def exit_(code):
        """raise an error carrying the exit code"""
        raise _Exited(code)
    scope = {"os": types.SimpleNamespace(environ=dict(env), _exit=exit_), "kmsg": lambda *a, **k: None}
    try:
        exec(compile(ast.Module(body=ifs, type_ignores=[]), LAUNCHER, "exec"), scope)
    except _Exited as e:
        return e.args[0], None
    except Exception as e:
        return None, "the %s guard cannot be run on its own: %r" % (KNOB, e)
    return None, None


def check(launcher_text, env_text, env_module_text, test_text):
    """return the findings for the knob wiring"""
    fails = []

    guards = GUARD.findall(launcher_text)
    if len(guards) != 1:
        fails.append("launcher3.py has %d %s guards of the form "
                     'if os.environ.get("%s") == "...": -- want exactly one'
                     % (len(guards), KNOB, KNOB))
        return fails
    armed_value = guards[0]

    def fires(env):
        """return whether the knob in the environment equals the armed value"""
        return env.get(KNOB) == armed_value
    if not fires({KNOB: armed_value}):
        fails.append("the guard does not fire with %s=%s" % (KNOB, armed_value))
    if fires({}):
        fails.append("the guard fires with %s unset" % KNOB)
    if fires({KNOB: "0"}):
        fails.append("the guard fires with %s=0" % KNOB)
    if fires({KNOB: ""}):
        fails.append("the guard fires with %s set empty" % KNOB)

    start = GUARD.search(launcher_text).end()
    block = launcher_text[start:start + 400]
    if "RHIZO_MARKER fault_no_ready=armed" not in block:
        fails.append("the guarded block writes no RHIZO_MARKER fault_no_ready=armed")
    for env, want, why in (
            ({KNOB: armed_value}, 1, "the guarded block does not os._exit(1) with %s=%s" % (KNOB, armed_value)),
            ({KNOB: armed_value, "RHIZO_POLICY_ONLY": "1"}, None, "the guarded block exits in the "
             "--policy-only pass too"),
            ({}, None, "the guarded block exits with %s unset" % KNOB)):
        code, err = guard_exit(launcher_text, env)
        if err:
            fails.append(err)
            break
        if code != want:
            fails.append("%s (exit %s under %r)" % (why, code, env))

    if KNOB in env_module_text:
        fails.append("%s is read in src/androidd/sandbox/core.py" % KNOB)

    if KNOB not in env_text:
        fails.append("%s is not documented in debian/androidd.env" % KNOB)

    fails.extend(check_test_arming_order(test_text))

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
FOR_LOOP_LINE = 'for try in $(seq 1 "$tries"); do'
LOCAL_LINE = '  local label="$1" rel="$2" preceding="${3:-}" extra_env="${4:-}" stage_fn="${5:-stage_release}" refusal kv'
CALLSITE_LINE = 'if boot_and_start "${label_prefix}-try-$try" "$to_rel" "" "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" "$stage_fn"; then'
LITERAL_ARM = '''ssh_vm -t 20 "grep -q '^RHIZO_FAULT_NO_READY=' /root/androidd.env 2>/dev/null \\
  && sed -i 's/^RHIZO_FAULT_NO_READY=.*/RHIZO_FAULT_NO_READY=1/' /root/androidd.env \\
  || echo RHIZO_FAULT_NO_READY=1 >> /root/androidd.env"
'''


POLICY_ONLY_GUARD = 'if os.environ.get("RHIZO_POLICY_ONLY") != "1":'


def selftest():
    """run the check on seeded defects"""
    good_launcher = read(LAUNCHER)
    good_env = read(ENV_FILE)
    good_module = read(ENV_MODULE)
    good_test = read(TEST)
    if check(good_launcher, good_env, good_module, good_test):
        print("SELFTEST FAIL: the real tree does not pass its own check")
        return 1

    for anchor in (MERGE_BLOCK, FOR_LOOP_LINE, LOCAL_LINE, CALLSITE_LINE):
        if good_test.count(anchor) != 1:
            print("SELFTEST SETUP FAIL: anchor not found exactly once in %s: %r"
                  % (TEST, anchor[:60]))
            return 1
    if good_launcher.count(POLICY_ONLY_GUARD) != 1:
        print("SELFTEST SETUP FAIL: anchor not found exactly once in %s: %r" % (LAUNCHER, POLICY_ONLY_GUARD))
        return 1

    test_armed_outside = good_test.replace(MERGE_BLOCK, "", 1)
    test_armed_outside = test_armed_outside.replace(
        FOR_LOOP_LINE, LITERAL_ARM + FOR_LOOP_LINE, 1)

    test_armed_too_early = good_test.replace(MERGE_BLOCK, "", 1)
    test_armed_too_early = test_armed_too_early.replace(
        LOCAL_LINE, LOCAL_LINE + "\n" + LITERAL_ARM, 1)

    test_armed_nowhere = good_test.replace(MERGE_BLOCK, "", 1)
    test_armed_nowhere = test_armed_nowhere.replace(
        CALLSITE_LINE, 'if boot_and_start "${label_prefix}-try-$try" "$to_rel"; then', 1)

    cases = [
        ("guard inverted to fire when unset",
         good_launcher.replace('if os.environ.get("%s") == "1":' % KNOB,
                               'if os.environ.get("%s") != "1":' % KNOB),
         good_env, good_module, good_test),
        ("marker removed",
         good_launcher.replace('kmsg("RHIZO_MARKER fault_no_ready=armed")', "pass"),
         good_env, good_module, good_test),
        ("knob fires in the --policy-only pass",
         good_launcher.replace(POLICY_ONLY_GUARD, "if True:"),
         good_env, good_module, good_test),
        ("policy-only guard inverted to fire only in the --policy-only pass",
         good_launcher.replace(POLICY_ONLY_GUARD, POLICY_ONLY_GUARD.replace("!=", "==")),
         good_env, good_module, good_test),
        ("knob undocumented",
         good_launcher, good_env.replace(KNOB, "RHIZO_SOMETHING_ELSE"), good_module, good_test),
        ("read moved into sandbox/core.py",
         good_launcher, good_env, good_module + '\n%s = os.environ.get("%s")\n' % (KNOB.lower(), KNOB), good_test),
        ("system test arms the knob outside boot_and_start, before its own stage_release call",
         good_launcher, good_env, good_module, test_armed_outside),
        ("system test arms the knob inside boot_and_start but before its own stage_release call",
         good_launcher, good_env, good_module, test_armed_too_early),
        ("system test never arms the knob anywhere reachable by boot_and_start",
         good_launcher, good_env, good_module, test_armed_nowhere),
    ]
    bad = 0
    for name, launcher, env, module, test in cases:
        if not check(launcher, env, module, test):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if bad:
        return 1

    if check_exhaustion_callers():
        print("SELFTEST FAIL: the real tree's gsi-update.sh/cycle.sh "
              "do not pass check_exhaustion_callers")
        return 1
    print("ok   selftest: gsi-update.sh and cycle.sh both call gsi_leg_exhaustion")
    if not EXHAUSTION_CALL_RE.search(strip_comments("# gsi_leg_exhaustion mentioned only in a comment\n")):
        print("ok   selftest: a comment-only mention is not a call (strip_comments drops it)")
    else:
        print("SELFTEST FAIL: strip_comments did not drop a comment-only mention")
        return 1

    if bad:
        return 1
    print("check-fault-knob selftest: every fixture failed as it should")
    return 0


EXHAUSTION_CALLERS = (
    os.path.join(REPO, "test", "system", "install", "gsi-update.sh"),
    os.path.join(REPO, "test", "system", "cycle", "cycle.sh"),
)
EXHAUSTION_CALL_RE = re.compile(r'\bgsi_leg_exhaustion\b')


def check_exhaustion_callers():
    """return the problems in gsi_leg_exhaustion's callers"""
    fails = []
    for path in EXHAUSTION_CALLERS:
        text = read(path)
        if text is None:
            fails.append("cannot read %s to confirm it calls gsi_leg_exhaustion" % path)
            continue
        if not EXHAUSTION_CALL_RE.search(strip_comments(text)):
            fails.append("%s never calls gsi_leg_exhaustion for %s" % (path, KNOB))
    return fails


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    for path in (LAUNCHER, ENV_FILE, ENV_MODULE, TEST):
        if not os.path.exists(path):
            print("FAIL: no %s" % path)
            return 1
    fails = check(read(LAUNCHER), read(ENV_FILE), read(ENV_MODULE), read(TEST))
    fails += check_exhaustion_callers()
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-fault-knob: %s fires only when armed, stays where redeploy "
          "can see it, and gsi-update.sh only ever arms it where "
          "redeploy cannot silently wipe it" % KNOB)
    return 0


if __name__ == "__main__":
    sys.exit(main())
