#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SYSTEM_DIR = os.path.join(REPO, "test", "system")
VM_DIR = os.path.join(REPO, "test", "vm")
sys.path.insert(0, os.path.join(SYSTEM_DIR, "run"))
import system_tests  # noqa: E402
MIN_SOURCES = 30

TAIL_BOUND_RE = re.compile(r"dmesg\b[^|]*\|\s*tail\s+-n\s*(?!\+)\d+")

BOOT_SMOKE = "boot-smoke.sh"
BYPASS_BOOT_TESTS = (BOOT_SMOKE, "certified-pair.sh", "installer.sh", "lsm-bootstrap.sh")
COLLECTOR_RE = re.compile(r"collect-boot-evidence\.sh")

COLLECTOR = "collect-boot-evidence.sh"
GUARD_COLLECTOR = "collect-layerstack-guard.sh"
REQUIRED_GUEST_PATHS = {
    COLLECTOR: ("/tmp/secilc.err", GUARD_COLLECTOR),
    GUARD_COLLECTOR: ("rhizo-layerstack-guard.log",),
}

TEST_LIB = "lib.sh"
ASSERT_ONLY_RE = re.compile(r"collect-boot-evidence\.sh.*--assert-only")
STAMP_DATE_RE = re.compile(r"date -u \+%Y%m%dT%H%M%SZ")
STAMP_NEST_RE = re.compile(r'DEST="\$DEST/')


def code_lines(text):
    """yield the numbered non-comment lines"""
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield n, line


def check_tail_bound(sources):
    """return failures for each dmesg tail count"""
    fails = []
    for rel, text in sorted(sources.items()):
        for n, line in code_lines(text):
            if TAIL_BOUND_RE.search(line):
                fails.append(
                    "%s:%d truncates a dmesg pull to a fixed tail count; read the "
                    "whole of dmesg: %s" % (rel, n, line.strip()))
    return fails


def check_bypass_tests_collect(sources):
    """return the bypass boot tests that do not collect boot evidence"""
    fails = []
    for name in BYPASS_BOOT_TESTS:
        text = sources.get(name)
        if text is None:
            continue
        if any(COLLECTOR_RE.search(line) for _, line in code_lines(text)):
            continue
        fails.append(
            "%s calls collect-boot-evidence.sh nowhere" % name)
    return fails


def check_collector_pulls_required_paths(sources):
    """return the required guest paths the collector does not pull"""
    fails = []
    for name, paths in REQUIRED_GUEST_PATHS.items():
        text = sources.get(name)
        if text is None:
            continue
        code = "\n".join(line for _, line in code_lines(text))
        for path in paths:
            if path not in code:
                fails.append(
                    "%s no longer collects %s" % (name, path))
    return fails


def extract_function(text, name):
    """return the named bash function's body"""
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(name + "() {")), None)
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("}"):
            return "\n".join(lines[start:j + 1])
    return None


def check_verdict_collects_guard_log(sources):
    """check the verdict collects the guard log"""
    text = sources.get(TEST_LIB)
    if text is None:
        return []
    body = extract_function(text, "test_record_verdict")
    if body is None:
        return ["%s: test_record_verdict() not found" % TEST_LIB]
    code = "\n".join(line for _, line in code_lines(body))
    if ASSERT_ONLY_RE.search(code):
        return []
    return ["%s: test_record_verdict() no longer collects the guard log and "
            "the rest of the assertion-failure evidence (logcat, guest "
            "state, this run's own $EV logs) on its own FAILED verdict via "
            "--assert-only" % TEST_LIB]


ASSERT_ONLY_FN = "run_assert_only"
ASSERT_ONLY_MARKERS = ("collect_guard_log", "logcat_vm", "guest-state.txt", "collect_test_ev_logs",
                       "collect_resync_journal")


def check_assert_only_collects_richer_evidence(sources):
    """check the assert-only mode collects richer evidence"""
    text = sources.get(COLLECTOR)
    if text is None:
        return []
    body = extract_function(text, ASSERT_ONLY_FN)
    if body is None:
        return ["%s: %s() not found"
                % (COLLECTOR, ASSERT_ONLY_FN)]
    code = "\n".join(line for _, line in code_lines(body))
    missing = [m for m in ASSERT_ONLY_MARKERS if m not in code]
    if not missing:
        return []
    return ["%s: %s() no longer collects %s" % (COLLECTOR, ASSERT_ONLY_FN, ", ".join(missing))]


def check_collector_stamps_repeat_runs(sources):
    """check the collector stamps repeat runs"""
    text = sources.get(COLLECTOR)
    if text is None:
        return []
    code = "\n".join(line for _, line in code_lines(text))
    fails = []
    if not STAMP_DATE_RE.search(code):
        fails.append("%s no longer stamps its destination with a UTC timestamp"
                      % COLLECTOR)
    if not STAMP_NEST_RE.search(code):
        fails.append("%s no longer nests its destination under that stamp" % COLLECTOR)
    return fails


def check(sources):
    """return the problems from every evidence coverage check"""
    return (check_tail_bound(sources) + check_bypass_tests_collect(sources)
            + check_collector_pulls_required_paths(sources)
            + check_verdict_collects_guard_log(sources)
            + check_assert_only_collects_richer_evidence(sources)
            + check_collector_stamps_repeat_runs(sources))


SOURCE_RE = re.compile(r'^\s*source\s+(\./[\w.-]+\.sh|\.\./[\w-]+/[\w.-]+\.sh)', re.MULTILINE)


def scan_repo():
    """read the system test and collector sources"""
    sources = {}
    for path in system_tests.system_test_paths(SYSTEM_DIR):
        base = os.path.basename(path)
        if base == "lib.sh":
            continue
        with open(path) as f:
            text = f.read()
        if base in BYPASS_BOOT_TESTS:
            for lib in SOURCE_RE.findall(text):
                lib_path = os.path.join(os.path.dirname(path), lib)
                if os.path.exists(lib_path):
                    with open(lib_path) as lf:
                        text += "\n" + lf.read()
        sources[base] = text
    for extra, directory in ((COLLECTOR, os.path.join(VM_DIR, "boot")), (GUARD_COLLECTOR, os.path.join(VM_DIR, "boot")),
                             (TEST_LIB, os.path.join(SYSTEM_DIR, "lib"))):
        path = os.path.join(directory, extra)
        if os.path.exists(path):
            with open(path) as f:
                sources[extra] = f.read()
    if len(sources) < MIN_SOURCES:
        raise SystemExit("scanned %d sources under test/system and test/vm, expected at least %d"
                         % (len(sources), MIN_SOURCES))
    return sources


def selftest():
    """run the checker against the tree and fixtures"""
    if check(scan_repo()):
        print("SELFTEST FAIL: the real tree does not pass its own check")
        return 1
    bad = 0

    def want(name, sources, should_fail):
        """record a failure unless the check fails exactly when it should"""
        nonlocal bad
        hits = check(sources)
        got_fail = bool(hits)
        if got_fail != should_fail:
            print("SELFTEST FAIL: %s -- expected %s, got %r"
                  % (name, "a FAIL" if should_fail else "no FAIL", hits))
            bad += 1
        else:
            print("ok   selftest: %s" % name)

    want("a count-scoped dmesg tail in boot-smoke.sh",
         {BOOT_SMOKE: 'dm=$(ssh_vm -t 8 \'dmesg 2>/dev/null | tail -n 500\' 2>/dev/null)\n'
                       'collect-boot-evidence.sh call still present below\n'},
         True)
    want("boot-smoke.sh loses its collect-boot-evidence.sh call",
         {BOOT_SMOKE: 'dm=$(ssh_vm -t 8 \'dmesg 2>/dev/null\' 2>/dev/null)\n'
                       'echo "no evidence collection call in this fixture"\n'},
         True)
    want("a comment mentioning the call is not the call",
         {BOOT_SMOKE: 'dm=$(ssh_vm -t 8 \'dmesg 2>/dev/null\' 2>/dev/null)\n'
                       '# used to call collect-boot-evidence.sh here, no longer does\n'},
         True)
    want("the real fixed shape: unbounded dmesg, and a real collector call",
         {BOOT_SMOKE: 'dm=$(ssh_vm -t 8 \'dmesg 2>/dev/null\' 2>/dev/null)\n'
                       '"$REPO/tools/collect-boot-evidence.sh" "$EV" "label"\n'},
         False)
    want("an offset-based tail (dmesg-window.py's own case) is not this defect",
         {"gsi-update.sh": 'd0=$(ssh_vm -t 15 \'dmesg | wc -l\')\n'
                                 'ssh_vm -t 15 "dmesg | tail -n +$((d0 + 1))"\n'},
         False)
    want("a fixed tail on something other than dmesg is out of scope",
         {"network.sh": 'logcat_vm "$INIT" -d -t 8000 | tail -n 500 > "$EV/x.txt"\n'},
         False)
    want("a comment describing the trap is not the trap",
         {BOOT_SMOKE: 'dm=$(ssh_vm -t 8 \'dmesg 2>/dev/null\' 2>/dev/null)\n'
                       "# this used to be dmesg 2>/dev/null | tail -n 500\n"
                       '"$REPO/tools/collect-boot-evidence.sh" "$EV" "label"\n'},
         False)

    for name in ("certified-pair.sh", "installer.sh", "lsm-bootstrap.sh"):
        want("%s never calls the collector on its own boot-failure path" % name,
             {name: 'wait_for_ssh 240 || { fail "SSH never came up"; return 1; }\n'},
             True)
        want("a comment naming the collector is not %s calling it" % name,
             {name: 'wait_for_ssh 240 || { fail "SSH never came up"; return 1; }\n'
                    '# used to call collect-boot-evidence.sh here\n'},
             True)
        want("%s calls the collector on its own boot-failure path" % name,
             {name: 'wait_for_ssh 240 || {\n'
                    '  fail "SSH never came up"\n'
                    '  "$REPO/tools/collect-boot-evidence.sh" "$EV" "label"\n'
                    '  return 1\n'
                    '}\n'},
             False)

    want("collect-boot-evidence.sh drops its secilc.err pull",
         {COLLECTOR: 'pull "launcher boot.log" /root/boot.log launcher-boot.txt\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'},
         True)
    want("collect-boot-evidence.sh drops its guard-log collection call",
         {COLLECTOR: 'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'},
         True)
    want("a comment mentioning secilc.err is not the pull",
         {COLLECTOR: '# used to pull /tmp/secilc.err here, no longer does\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'},
         True)
    want("collect-boot-evidence.sh keeps both pulls",
         {COLLECTOR: 'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'
                      'STAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
                      'DEST="$DEST/$STAMP"\n'
                     'ssh_vm -t 45 \'journalctl -u rhizo-host-primer -b --no-pager\' > "$DEST/primer-journal.txt"\n'
                     'run_assert_only() {\n'
                     '  collect_guard_log\n'
                     '  logcat_vm "$p" -d -v threadtime > "$DEST/logcat.txt"\n'
                     '  ssh_vm -t 60 "..." > "$DEST/guest-state.txt"\n'
                     '  [[ -n "$RHIZO_TEST_EV_DIR" ]] && collect_test_ev_logs\n'
                     '  collect_resync_journal\n'
                     '}\n'},
         False)
    want("collect-layerstack-guard.sh loses its own guest path",
         {GUARD_COLLECTOR: 'FILE="${1:-/data/local/tmp/rhizo-different-file.log}"\n'},
         True)
    want("collect-layerstack-guard.sh keeps its own guest path",
         {GUARD_COLLECTOR: 'FILE="${1:-/data/local/tmp/rhizo-layerstack-guard.log}"\n'},
         False)

    want("test_record_verdict loses its own guard-log collection call",
         {TEST_LIB: 'test_record_verdict() {  # test_record_verdict PASSED|FAILED\n'
                    '  rig_verdict_write "$EV/verdict.txt" "h" "h" ""\n'
                    '  if (( TEST_NESTED )); then\n'
                    '    return 0\n'
                    '  fi\n'
                    '}\n'},
         True)
    want("a comment mentioning the assert-only call is not the call",
         {TEST_LIB: 'test_record_verdict() {  # test_record_verdict PASSED|FAILED\n'
                    '  rig_verdict_write "$EV/verdict.txt" "h" "h" ""\n'
                    '  # used to call collect-boot-evidence.sh --assert-only here\n'
                    '  if (( TEST_NESTED )); then\n'
                    '    return 0\n'
                    '  fi\n'
                    '}\n'},
         True)
    want("test_record_verdict makes only the guard-only call",
         {TEST_LIB: 'test_record_verdict() {  # test_record_verdict PASSED|FAILED\n'
                    '  rig_verdict_write "$EV/verdict.txt" "h" "h" ""\n'
                    '  [[ "$1" == FAILED ]] && "$REPO/tools/collect-boot-evidence.sh" --guard-only "$EV/test-failure" "${TEST_NAME:-unknown}"\n'
                    '  if (( TEST_NESTED )); then\n'
                    '    return 0\n'
                    '  fi\n'
                    '}\n'},
         True)
    want("test_record_verdict keeps its own assert-only collection call",
         {TEST_LIB: 'test_record_verdict() {  # test_record_verdict PASSED|FAILED\n'
                    '  rig_verdict_write "$EV/verdict.txt" "h" "h" ""\n'
                    '  [[ "$1" == FAILED ]] && RHIZO_TEST_EV_DIR="$EV" "$REPO/tools/collect-boot-evidence.sh" --assert-only "$EV/test-failure" "${TEST_NAME:-unknown}"\n'
                    '  if (( TEST_NESTED )); then\n'
                    '    return 0\n'
                    '  fi\n'
                    '}\n'},
         False)

    want("run_assert_only exists but is gutted back down to only the guard log",
         {COLLECTOR: 'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'
                      'STAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
                      'DEST="$DEST/$STAMP"\n'
                      'run_assert_only() {\n'
                      '  collect_guard_log\n'
                      '}\n'},
         True)
    want("run_assert_only keeps the guard log plus the rest of the richer evidence",
         {COLLECTOR: 'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'
                      'STAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
                      'DEST="$DEST/$STAMP"\n'
                      'run_assert_only() {\n'
                      '  collect_guard_log\n'
                      '  logcat_vm "$p" -d -v threadtime > "$DEST/logcat.txt"\n'
                      '  ssh_vm -t 60 "..." > "$DEST/guest-state.txt"\n'
                      '  [[ -n "$RHIZO_TEST_EV_DIR" ]] && collect_test_ev_logs\n'
                      '  collect_resync_journal\n'
                      '}\n'},
         False)
    want("run_assert_only keeps everything else but drops the entry sync's journal",
         {COLLECTOR: 'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                      'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'
                      'STAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
                      'DEST="$DEST/$STAMP"\n'
                      'run_assert_only() {\n'
                      '  collect_guard_log\n'
                      '  logcat_vm "$p" -d -v threadtime > "$DEST/logcat.txt"\n'
                      '  ssh_vm -t 60 "..." > "$DEST/guest-state.txt"\n'
                      '  [[ -n "$RHIZO_TEST_EV_DIR" ]] && collect_test_ev_logs\n'
                      '  # collect_resync_journal used to run here\n'
                      '}\n'},
         True)

    want("collect-boot-evidence.sh loses its per-run stamp",
         {COLLECTOR: 'DEST="${1:-}"\n'
                     'LABEL="${2:-}"\n'
                     '[[ "$DEST" == /* ]] || DEST="$PWD/$DEST"\n'
                     'mkdir -p "$DEST"\n'
                     'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                     'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'},
         True)
    want("a comment mentioning the stamp is not the stamp",
         {COLLECTOR: 'DEST="${1:-}"\n'
                     'LABEL="${2:-}"\n'
                     '[[ "$DEST" == /* ]] || DEST="$PWD/$DEST"\n'
                     '# used to stamp DEST with date -u +%Y%m%dT%H%M%SZ here\n'
                     'mkdir -p "$DEST"\n'
                     'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                     'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'},
         True)
    want("collect-boot-evidence.sh keeps its per-run stamp",
         {COLLECTOR: 'DEST="${1:-}"\n'
                     'LABEL="${2:-}"\n'
                     '[[ "$DEST" == /* ]] || DEST="$PWD/$DEST"\n'
                     'STAMP="$(date -u +%Y%m%dT%H%M%SZ)"\n'
                     'DEST="$DEST/$STAMP"\n'
                     'mkdir -p "$DEST"\n'
                     'pull "secilc stderr" /tmp/secilc.err secilc-err.txt\n'
                     'guard_raw=$(ssh_vm -t 45 \'bash -s\' -- < "$REPO/tools/collect-layerstack-guard.sh")\n'
                     'run_assert_only() {\n'
                     '  collect_guard_log\n'
                     '  logcat_vm "$p" -d -v threadtime > "$DEST/logcat.txt"\n'
                     '  ssh_vm -t 60 "..." > "$DEST/guest-state.txt"\n'
                     '  [[ -n "$RHIZO_TEST_EV_DIR" ]] && collect_test_ev_logs\n'
                     '  collect_resync_journal\n'
                     '}\n'
},
         False)

    if bad:
        return 1
    print("check-boot-evidence-coverage selftest: every fixture answered as it should")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    fails = check(scan_repo())
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-boot-evidence-coverage: no system test truncates dmesg by a fixed tail, "
          "every system test that bypasses test_boot() still calls "
          "collect-boot-evidence.sh on its own boot-failure path, the "
          "collector still pulls secilc.err and the layerstack guard log, "
          "test_record_verdict still collects the guard log and the rest of "
          "the assertion-failure evidence on its own FAILED verdict, and the "
          "collector still stamps its destination per run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
