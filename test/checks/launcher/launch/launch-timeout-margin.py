#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUEST = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "launch-app.sh")
OUTER = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "launch-app.sh")

MIN_MARGIN_S = 10

ITER_CEILING_PAIRS = [
    ("AUDIO_CONFIRM_FAST_ITERS", "AUDIO_CONFIRM_ITERS", "AUDIO_CONFIRM_CEILING_S"),
    ("DISPLAY_ADD_FAST_ITERS", "DISPLAY_ADD_ITERS", "DISPLAY_ADD_CEILING_S"),
    ("ID_RESOLVE_FAST_ITERS", "ID_RESOLVE_ITERS", "ID_RESOLVE_CEILING_S"),
    ("POWER_CONFIRM_FAST_ITERS", "POWER_CONFIRM_ITERS", "POWER_CONFIRM_CEILING_S"),
    ("CLAIM_FAST_ITERS", "CLAIM_ITERS", "CLAIM_CEILING_S"),
]

DEADLINE_RE = re.compile(r"^on_top_deadline=\$\(\( \$\(date \+%s\) \+ GUEST_CALL_TIMEOUT_S "
                         r"- ON_TOP_CHANNEL_MARGIN_S \)\)$", re.M)

ASSIGN_RE = r"^%s=([0-9.]+)\s*(?:#.*)?$"


def extract(text, name):
    """return the number assigned to a name in the text, or None"""
    m = re.search(ASSIGN_RE % re.escape(name), text, re.MULTILINE)
    if not m:
        return None
    v = m.group(1)
    return float(v) if "." in v else int(v)


def check(inner_text, outer_text):
    """return the failures for both scripts"""
    failures = []
    tick = extract(inner_text, "POLL_TICK_S")
    fast_tick = extract(inner_text, "POLL_FAST_TICK_S")
    if tick is None:
        return [("MISSING", "POLL_TICK_S not found in rhizo-launch-app.sh")]
    if fast_tick is None:
        return [("MISSING", "POLL_FAST_TICK_S not found in rhizo-launch-app.sh")]

    ceiling_sum = 0.0
    for fast_name, iters_name, ceiling_name in ITER_CEILING_PAIRS:
        fast_iters = extract(inner_text, fast_name)
        iters = extract(inner_text, iters_name)
        ceiling = extract(inner_text, ceiling_name)
        if fast_iters is None or iters is None or ceiling is None:
            failures.append(("MISSING", "%s, %s or %s not found"
                             % (fast_name, iters_name, ceiling_name)))
            continue
        real = fast_iters * fast_tick + iters * tick
        if abs(real - ceiling) > 1e-9:
            failures.append(("CEILING-MISMATCH",
                              "%s(%s) * POLL_FAST_TICK_S(%s) + %s(%s) * POLL_TICK_S(%s) = %s, "
                              "but %s = %s"
                              % (fast_name, fast_iters, fast_tick, iters_name, iters, tick,
                                 real, ceiling_name, ceiling)))
        ceiling_sum += ceiling

    timeout = extract(outer_text, "GUEST_CALL_TIMEOUT_S")
    margin = extract(outer_text, "ON_TOP_CHANNEL_MARGIN_S")
    if timeout is None:
        failures.append(("MISSING", "GUEST_CALL_TIMEOUT_S not found in rhizo-launch.sh"))
    elif timeout - ceiling_sum < MIN_MARGIN_S:
        failures.append(("MARGIN",
                          "GUEST_CALL_TIMEOUT_S(%s) - worst case(%s) = %s, "
                          "need at least MIN_MARGIN_S(%s)"
                          % (timeout, ceiling_sum, timeout - ceiling_sum, MIN_MARGIN_S)))
    if margin is None:
        failures.append(("MISSING", "ON_TOP_CHANNEL_MARGIN_S not found in rhizo-launch.sh"))
    elif margin < MIN_MARGIN_S:
        failures.append(("ONTOP-MARGIN", "ON_TOP_CHANNEL_MARGIN_S(%s) is under MIN_MARGIN_S(%s)"
                         % (margin, MIN_MARGIN_S)))
    elif timeout is not None and timeout - margin - ceiling_sum < MIN_MARGIN_S:
        failures.append(("ONTOP-ROOM", "GUEST_CALL_TIMEOUT_S(%s) - ON_TOP_CHANNEL_MARGIN_S(%s) - worst case(%s) "
                                        "= %s left for the on-top wait, need at least MIN_MARGIN_S(%s)"
                         % (timeout, margin, ceiling_sum, timeout - margin - ceiling_sum, MIN_MARGIN_S)))
    if not DEADLINE_RE.search(outer_text):
        failures.append(("ONTOP-DEADLINE", "rhizo-launch.sh does not compute on_top_deadline from "
                                            "GUEST_CALL_TIMEOUT_S - ON_TOP_CHANNEL_MARGIN_S"))
    if re.search(r"^ON_TOP_CEILING_S=", inner_text, re.M):
        failures.append(("ONTOP-CEILING", "rhizo-launch-app.sh declares ON_TOP_CEILING_S: the on-top wait "
                                           "runs to the call's own deadline, not a ceiling of its own"))
    return failures


SELFTEST_GUEST_GOOD = """
POLL_TICK_S=0.05
POLL_FAST_TICK_S=0.01
AUDIO_CONFIRM_FAST_ITERS=50
AUDIO_CONFIRM_ITERS=30
DISPLAY_ADD_FAST_ITERS=100
DISPLAY_ADD_ITERS=580
ID_RESOLVE_FAST_ITERS=100
ID_RESOLVE_ITERS=180
POWER_CONFIRM_FAST_ITERS=100
POWER_CONFIRM_ITERS=100
AUDIO_CONFIRM_CEILING_S=2
DISPLAY_ADD_CEILING_S=30
ID_RESOLVE_CEILING_S=10
POWER_CONFIRM_CEILING_S=6
CLAIM_FAST_ITERS=50
CLAIM_ITERS=30
CLAIM_CEILING_S=2
"""
_DEADLINE = "on_top_deadline=$(( $(date +%s) + GUEST_CALL_TIMEOUT_S - ON_TOP_CHANNEL_MARGIN_S ))\n"
SELFTEST_OUTER_GOOD = "GUEST_CALL_TIMEOUT_S=80\nON_TOP_CHANNEL_MARGIN_S=10\n" + _DEADLINE
SELFTEST_OUTER_PRE_ON_TOP = "GUEST_CALL_TIMEOUT_S=65\nON_TOP_CHANNEL_MARGIN_S=10\n" + _DEADLINE
SELFTEST_OUTER_THIN_MARGIN = "GUEST_CALL_TIMEOUT_S=80\nON_TOP_CHANNEL_MARGIN_S=2\n" + _DEADLINE
SELFTEST_OUTER_NO_DEADLINE = "GUEST_CALL_TIMEOUT_S=80\nON_TOP_CHANNEL_MARGIN_S=10\non_top_deadline=$(( $(date +%s) + 15 ))\n"

SELFTEST_GUEST_MISMATCH = SELFTEST_GUEST_GOOD.replace(
    "DISPLAY_ADD_ITERS=580", "DISPLAY_ADD_ITERS=480"
)

SELFTEST_GUEST_FAST_TICK_CUT = SELFTEST_GUEST_GOOD.replace(
    "POLL_FAST_TICK_S=0.01", "POLL_FAST_TICK_S=0.005"
)

SELFTEST_OUTER_TIGHT = "GUEST_CALL_TIMEOUT_S=45\nON_TOP_CHANNEL_MARGIN_S=10\n" + _DEADLINE


def selftest():
    """check the well-formed numbers and each planted-defect set"""
    good = check(SELFTEST_GUEST_GOOD, SELFTEST_OUTER_GOOD)
    if good:
        print("SELFTEST FAILED: the real numbers (50s sum, 80s timeout, 10s on-top margin) were "
              "flagged: %s" % good, file=sys.stderr)
        return 1

    mismatch = check(SELFTEST_GUEST_MISMATCH, SELFTEST_OUTER_GOOD)
    kinds = {rule for rule, _d in mismatch}
    if "CEILING-MISMATCH" not in kinds:
        print("SELFTEST FAILED: an edited iters/tick pair did not fire "
              "CEILING-MISMATCH (fired: %s)" % sorted(kinds), file=sys.stderr)
        return 1

    cut = check(SELFTEST_GUEST_FAST_TICK_CUT, SELFTEST_OUTER_GOOD)
    kinds_cut = {rule for rule, _d in cut}
    if "CEILING-MISMATCH" not in kinds_cut:
        print("SELFTEST FAILED: halving POLL_FAST_TICK_S with every iteration "
              "count left alone shortens every ceiling and did not fire "
              "CEILING-MISMATCH (fired: %s)" % sorted(kinds_cut), file=sys.stderr)
        return 1

    tight = check(SELFTEST_GUEST_GOOD, SELFTEST_OUTER_TIGHT)
    kinds2 = {rule for rule, _d in tight}
    if "MARGIN" not in kinds2:
        print("SELFTEST FAILED: GUEST_CALL_TIMEOUT_S=45 against a 50s sum "
              "(-5 margin, need 10) did not fire MARGIN (fired: %s)"
              % sorted(kinds2), file=sys.stderr)
        return 1

    for outer, guest, rule, what in (
            (SELFTEST_OUTER_PRE_ON_TOP, SELFTEST_GUEST_GOOD, "ONTOP-ROOM",
             "a 65s timeout leaving the on-top wait 5s after the 50s of fixed ceilings"),
            (SELFTEST_OUTER_THIN_MARGIN, SELFTEST_GUEST_GOOD, "ONTOP-MARGIN",
             "a 2s on-top channel margin"),
            (SELFTEST_OUTER_NO_DEADLINE, SELFTEST_GUEST_GOOD, "ONTOP-DEADLINE",
             "a deadline of its own 15s instead of the call's budget"),
            (SELFTEST_OUTER_GOOD, SELFTEST_GUEST_GOOD + "ON_TOP_CEILING_S=15\n", "ONTOP-CEILING",
             "a guest ON_TOP_CEILING_S")):
        fired = {r for r, _d in check(guest, outer)}
        if rule not in fired:
            print("SELFTEST FAILED: %s did not fire %s (fired: %s)" % (what, rule, sorted(fired)),
                  file=sys.stderr)
            return 1

    print("selftest ok: passes the real 50s/80s/10s numbers, catches an on-top wait left too little room, "
          "too thin a margin, its own deadline or a ceiling, catches an edited "
          "iters/tick pair by name, and catches a timeout with no real "
          "margin by name")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(GUEST) as f:
        inner_text = f.read()
    with open(OUTER) as f:
        outer_text = f.read()
    failures = check(inner_text, outer_text)
    if failures:
        print("launch timeout margin is not sound:", file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("guest poll ceilings agree with their tick, and the channel "
          "timeout keeps at least %ss of margin above their sum" % MIN_MARGIN_S)
    return 0


if __name__ == "__main__":
    sys.exit(main())
