#!/usr/bin/env python3
"""Print a boot phase table from kmsg markers."""

import argparse
import inspect
import os
import re
import sys
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

TS = re.compile(r"^\[\s*(\d+\.\d+)\]")
PHASE = re.compile(r"RHIZO_PHASE\s+([ABC]):(\S+)")
ACTION = re.compile(r"init: processing action \(([^)]+)\) from \(([^)]+)\)")
START = "RHIZO_MARKER launch_start"
END = "RHIZO_MARKER sys.boot_completed=1"


class NoAnchor(Exception):
    """exception for an unmeasurable capture"""


def parse(lines):
    """return the phase window of the last boot"""
    seen = []
    for line in lines:
        m = TS.match(line)
        if not m:
            continue
        ts = float(m.group(1))
        p = PHASE.search(line)
        a = ACTION.search(line)
        if p:
            seen.append((ts, "phase", (p.group(1), p.group(2))))
        elif a:
            seen.append((ts, "action", ("C", a.group(1))))
        elif START in line:
            seen.append((ts, "start", None))
        elif END in line:
            seen.append((ts, "end", None))

    ends = [i for i, e in enumerate(seen) if e[1] == "end"]
    starts = [i for i, e in enumerate(seen) if e[1] == "start"]
    if not starts:
        raise NoAnchor("no `%s` in this capture -- nothing to measure" % START)
    last_start = starts[-1]
    after = [i for i in ends if i > last_start]
    if not after:
        raise NoAnchor("found `%s` at %.3f but no `%s` after it -- this boot "
                       "never completed" % (START, seen[last_start][0], END))
    last_end = after[0]

    prior = [i for i in ends + starts if i < last_start]
    floor = max(prior) if prior else -1
    phases_in = []
    last_name = None
    for i, e in enumerate(seen):
        if e[1] not in ("phase", "action") or not (floor < i < last_end):
            continue
        if e[1] == "action" and e[2][1] == last_name:
            continue
        last_name = e[2][1] if e[1] == "action" else None
        phases_in.append(i)
    window_start = min(seen[phases_in[0]][0], seen[last_start][0]) \
        if phases_in else seen[last_start][0]

    events = [(seen[i][0], seen[i][2][0], seen[i][2][1]) for i in phases_in]
    return window_start, seen[last_end][0], events, seen[last_start][0]


def phases(start_ts, end_ts, events):
    """return the phase rows between markers"""
    out = []
    if not events:
        out.append(("?", "unattributed", start_ts, end_ts))
        return out
    if events[0][0] > start_ts:
        out.append(("?", "before-first-marker", start_ts, events[0][0]))
    for i, (ts, layer, name) in enumerate(events):
        close = events[i + 1][0] if i + 1 < len(events) else end_ts
        out.append((layer, name, ts, close))
    return out


def render(rows, start_ts, end_ts, tsv=False, launch_ts=None):
    """render the phase table"""
    total = end_ts - start_ts
    lines = []
    if tsv:
        for layer, name, a, b in rows:
            lines.append("%s\t%s\t%.3f\t%.3f\t%.3f" % (layer, name, a, b, b - a))
        return "\n".join(lines)

    width = max((len(r[1]) for r in rows), default=10)
    lines.append("%-5s %-*s %10s %8s" % ("layer", width, "phase", "seconds", "share"))
    for layer, name, a, b in rows:
        d = b - a
        lines.append("%-5s %-*s %10.3f %7.1f%%"
                     % (layer, width, name, d, 100.0 * d / total if total else 0.0))

    by_layer = {}
    for layer, _name, a, b in rows:
        by_layer[layer] = by_layer.get(layer, 0.0) + (b - a)
    lines.append("")
    for layer in sorted(by_layer):
        lines.append("layer %s: %.3fs (%.1f%%)"
                     % (layer, by_layer[layer],
                        100.0 * by_layer[layer] / total if total else 0.0))
    lines.append("total:   %.3fs" % total)
    if launch_ts is not None:
        lines.append("of which launch_start -> boot_completed: %.3fs "
                     "(the startup.cold-boot denominator)" % (end_ts - launch_ts))

    covered = sum(b - a for _l, _n, a, b in rows)
    if abs(covered - total) > 0.001:
        lines.append("UNATTRIBUTED: %.3fs of %.3fs is in no phase"
                     % (total - covered, total))
    if "?" in by_layer:
        lines.append("NOTE: %.3fs carries no layer" % by_layer["?"])
    return "\n".join(lines)


def selftest():
    """run the boot-phases fixture tests"""
    log = ["[  1.000] boot",
           "[  8.000] RHIZO_PHASE B:stage_files",
           "[ 10.000] RHIZO_MARKER launch_start",
           "[ 12.000] RHIZO_PHASE B:flatten_tree",
           "[ 20.000] RHIZO_PHASE C:init_start",
           "[ 40.000] RHIZO_MARKER sys.boot_completed=1"]
    a, b, ev, launch = parse(log)
    assert (a, b, launch) == (8.0, 40.0, 10.0), (a, b, launch)
    rows = phases(a, b, ev)
    assert abs(sum(y - x for _l, _n, x, y in rows) - 32.0) < 1e-9, rows
    out = render(rows, a, b, launch_ts=launch)
    assert "UNATTRIBUTED" not in out, out
    assert "carries no layer" not in out, "a fully marked boot reported a gap: %s" % out
    assert "30.000s (the startup.cold-boot denominator)" in out, out

    two = log + ["[ 50.000] RHIZO_MARKER launch_start",
                 "[ 55.000] RHIZO_PHASE C:init_start",
                 "[ 60.000] RHIZO_MARKER sys.boot_completed=1"]
    a2, b2, ev2, _ = parse(two)
    assert (a2, b2) == (50.0, 60.0), (a2, b2)
    assert len(ev2) == 1, ev2

    three = log + ["[ 48.000] RHIZO_PHASE B:stage_files",
                   "[ 50.000] RHIZO_MARKER launch_start",
                   "[ 60.000] RHIZO_MARKER sys.boot_completed=1"]
    a3, _b3, ev3, _ = parse(three)
    assert a3 == 48.0 and len(ev3) == 1, (a3, ev3)

    env = os.path.join(REPO, "src", "androidd", "sandbox", "core.py")
    emitted = re.search(r'kmsg\(f"(RHIZO_PHASE [^"]*)"\)', open(env).read())
    assert emitted, "sandbox/core.py emits no RHIZO_PHASE line"
    sample = emitted.group(1).replace("{layer}", "B").replace("{name}", "some_phase")
    assert PHASE.search(sample), \
        "the emitter's format %r does not match this reader's regex" % sample

    for bad, want in ((["[ 1.000] nothing here"], "nothing to measure"),
                      (["[ 10.000] RHIZO_MARKER launch_start"], "never completed")):
        try:
            parse(bad)
        except NoAnchor as e:
            assert want in str(e), e
        else:
            raise AssertionError("a capture with no %s was accepted" % want)

    ran = sum(1 for line in inspect.getsource(selftest).splitlines()
              if line.strip().startswith("assert "))
    print("boot-phases selftest: %d assertions passed" % ran)


def main():
    """parse the arguments and print the boot phases of a log"""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", nargs="?", help="a dmesg capture; omit to read stdin")
    ap.add_argument("--tsv", action="store_true", help="one row per phase")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    lines = open(args.log) if args.log else sys.stdin
    try:
        start_ts, end_ts, events, launch_ts = parse(lines)
    except NoAnchor as e:
        print("boot-phases: %s" % e, file=sys.stderr)
        return 1
    print(render(phases(start_ts, end_ts, events), start_ts, end_ts,
                 args.tsv, launch_ts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
