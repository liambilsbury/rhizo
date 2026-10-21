#!/usr/bin/env python3
"""Attribute Android boot time to init commands, execs, apexd and netbpfload."""

import argparse
import importlib.util
import inspect
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EPS = 1e-4
TILING_TOLERANCE_S = 0.001


def _load_boot_phases():
    """load the boot-phases.py module"""
    spec = importlib.util.spec_from_file_location(
        "boot_phases", os.path.join(HERE, "boot-phases.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


boot_phases = _load_boot_phases()


class CalibrationRefused(Exception):
    """exception for an untrusted events clock"""


class Node:
    """interval in the boot attribution tree"""

    def __init__(self, name, start, end, kind="owner"):
        """set the interval's fields"""
        self.name = name
        self.start = start
        self.end = end
        self.kind = kind
        self.children = []
        self.residual_label = None

    @property
    def duration(self):
        """return the interval's length"""
        return self.end - self.start


CMD_TOOK_RE = re.compile(
    r"Command '(?P<cmd>.+)' action=(?P<action>.+) \((?P<file>[^()]*):(?P<line>\d+)\) "
    r"took (?P<ms>\d+)ms and (?P<result>succeeded|failed:.*)")

EXEC_OPEN_RE = re.compile(r"SVC_EXEC service '(?P<svc>[^']+)' pid (?P<pid>\d+) ")
EXEC_WAIT_CLOSE_RE = re.compile(
    r"Service '(?P<svc>[^']+)' \(pid (?P<pid>\d+)\) exited with status (?P<status>-?\d+) "
    r"waiting took (?P<f>[\d.]+) seconds")
EXEC_BG_CLOSE_RE = re.compile(
    r"Service '(?P<svc>[^']+)' \(pid (?P<pid>\d+)\) exited with status (?P<status>-?\d+) "
    r"oneshot service took (?P<f>[\d.]+) seconds in background")

PROPWAIT_RE = re.compile(r"Wait for property '(?P<name>[^=']+)=(?P<val>[^']*)' took (?P<ms>\d+)ms")

PARSE_FILE_RE = re.compile(r"Parsing file (?P<path>\S+)\.\.\.")

NETBPF_PIN_RE = re.compile(r"\b(?:map|prog) (?P<pin>/\S+) id \d+")
NETBPF_FAMILY_RE = re.compile(r"/(?:map|prog)_([A-Za-z]+)_")
NETBPF_SUCCESS_RE = re.compile(r"\bsuccess\.")
NETBPF_FAMILIES = ("offload", "test", "clatd", "dscpPolicy", "netd")

APEXD_PREALLOC_RE = re.compile(r"Need to pre-allocate \d+ loop devices")
APEXD_ACTIVATED_RE = re.compile(r"Activated \d+ packages\.")
APEXD_BOOTSTRAP_DONE_RE = re.compile(r"OnBootstrap done, duration=\d+")
APEXD_PROCESSING_RE = re.compile(r"Processing compressed APEX \S+")
APEXD_SKIPPING_RE = re.compile(r"Skipping decompression for \S+")
APEXD_START_DONE_RE = re.compile(r"OnStart done, duration=\d+")

ZYGOTE_START_RE = re.compile(r"starting service 'zygote'\.\.\.")
READY_TRIGGER_RE = re.compile(r"processing action \([^)]*ro\.persistent_properties\.ready=true[^)]*\)")
EVENTS_TAG_RE = re.compile(
    r"^\s*(\d+\.\d+)\s.*?boot_progress_(preload_start|preload_end|system_run|pms_start|"
    r"pms_system_scan_start|pms_scan_end|ams_ready|enable_screen):\s*(\d+)", re.M)


def extract_commands(scoped):
    """return the init command intervals from kmsg"""
    out = []
    for ts, line in scoped:
        m = CMD_TOOK_RE.search(line)
        if not m:
            continue
        start = ts - int(m.group("ms")) / 1000.0
        out.append((start, ts, "cmd:%s" % m.group("cmd")))
    return out


def extract_exec(scoped):
    """return exec intervals and background execs"""
    open_q = {}
    owners = []
    annotations = []
    for ts, line in scoped:
        m = EXEC_OPEN_RE.search(line)
        if m:
            open_q.setdefault(m.group("svc"), []).append(ts)
            continue
        m = EXEC_WAIT_CLOSE_RE.search(line)
        if m:
            svc = m.group("svc")
            q = open_q.get(svc)
            start = q.pop(0) if q else ts - float(m.group("f"))
            owners.append((start, ts, "exec:%s" % svc))
            continue
        m = EXEC_BG_CLOSE_RE.search(line)
        if m:
            svc = m.group("svc")
            annotations.append((ts - float(m.group("f")), ts, "bg:%s" % svc))
    return owners, annotations


def extract_propwait(scoped):
    """return the property wait intervals"""
    out = []
    for ts, line in scoped:
        m = PROPWAIT_RE.search(line)
        if not m:
            continue
        start = ts - int(m.group("ms")) / 1000.0
        out.append((start, ts, "propwait:%s=%s" % (m.group("name"), m.group("val"))))
    return out


def extract_rc_parse(scoped):
    """return the rc file parse intervals"""
    out = []
    pending = None
    for ts, line in scoped:
        m = PARSE_FILE_RE.search(line)
        if m:
            if pending is not None:
                out.append((pending[0], ts, "rc-parse:%s" % pending[1]))
            pending = (ts, m.group("path"))
            continue
        if pending is not None and boot_phases.ACTION.search(line):
            pending = None
    return out


def extract_netbpfload(scoped):
    """return the netbpfload object intervals"""
    out = []
    current = None
    for ts, line in scoped:
        m = NETBPF_PIN_RE.search(line)
        if m:
            fm = NETBPF_FAMILY_RE.search(m.group("pin"))
            family = fm.group(1) if fm else None
            if family in NETBPF_FAMILIES and family != (current[0] if current else None):
                if current is not None:
                    out.append((current[1], ts, "netbpfload:%s.o" % current[0]))
                current = (family, ts)
            continue
        if current is not None and NETBPF_SUCCESS_RE.search(line):
            out.append((current[1], ts, "netbpfload:%s.o" % current[0]))
            current = None
    return out


def extract_apexd(scoped):
    """return the apexd phase intervals"""
    out = []
    state = None
    bs = {}
    st = {}
    for ts, line in scoped:
        if "Started. subcommand = --bootstrap" in line:
            state = "bootstrap"
            bs = {}
            continue
        if "Started. subcommand = (null)" in line:
            state = "start"
            st = {"vold_start": ts}
            continue

        if state == "bootstrap":
            if "Scanning /system/apex for pre-installed ApexFiles" in line and "scan_start" not in bs:
                bs["scan_start"] = ts
            elif APEXD_PREALLOC_RE.search(line):
                if "scan_start" in bs:
                    out.append((bs["scan_start"], ts, "apexd:bootstrap:scan"))
                bs["prealloc_start"] = ts
            elif APEXD_ACTIVATED_RE.search(line):
                if "prealloc_start" in bs:
                    out.append((bs["prealloc_start"], ts, "apexd:bootstrap:prealloc"))
                bs["activate_start"] = ts
            elif APEXD_BOOTSTRAP_DONE_RE.search(line):
                if "activate_start" in bs:
                    out.append((bs["activate_start"], ts, "apexd:bootstrap:activate"))
                state = None

        elif state == "start":
            if "Marking APEXd as starting" in line:
                if "vold_start" in st:
                    out.append((st["vold_start"], ts, "apexd:start:vold-binder"))
                st["scan_start"] = ts
            elif APEXD_PROCESSING_RE.search(line):
                if "first_processing" not in st:
                    st["first_processing"] = ts
                    if "scan_start" in st:
                        out.append((st["scan_start"], ts, "apexd:start:scan"))
            elif APEXD_SKIPPING_RE.search(line):
                st["last_skipping"] = ts
            elif APEXD_ACTIVATED_RE.search(line):
                if "first_processing" in st and "last_skipping" in st:
                    out.append((st["first_processing"], st["last_skipping"], "apexd:start:validate-compressed"))
                    out.append((st["last_skipping"], ts, "apexd:start:activate(parallel)"))
                elif "first_processing" in st:
                    out.append((st["first_processing"], ts, "apexd:start:validate-compressed"))
                elif "scan_start" in st:
                    out.append((st["scan_start"], ts, "apexd:start:scan"))
            elif APEXD_START_DONE_RE.search(line):
                st["done"] = ts
            elif "Marking APEXd as activated" in line:
                if "done" in st:
                    out.append((st["done"], ts, "apexd:start:done->activated"))
            elif "Marking APEXd as ready" in line:
                state = None
    return out


def parse_events(text):
    """return the last payload of each tag"""
    vals = {}
    for m in EVENTS_TAG_RE.finditer(text):
        vals[m.group(2)] = (int(m.group(3)), float(m.group(1)))
    return vals


def extract_idle(scoped, window_end, events_text, boot_epoch):
    """return the idle init span and children"""
    ready_ts = zygote_ts = None
    for ts, line in scoped:
        if ready_ts is None and READY_TRIGGER_RE.search(line):
            ready_ts = ts
        if zygote_ts is None and ZYGOTE_START_RE.search(line):
            zygote_ts = ts
    if ready_ts is None:
        return None

    if events_text is None:
        return ready_ts, window_end, [], "idle:no-events-capture"

    if boot_epoch is None:
        return ready_ts, window_end, [], "idle:no-calibration"
    if zygote_ts is None:
        raise CalibrationRefused("no \"starting service 'zygote'...\" line in this capture")

    vals = parse_events(events_text)
    for tag, (payload_ms, stamp) in vals.items():
        offset = abs((stamp - boot_epoch) - payload_ms / 1000.0)
        if offset > 0.020:
            raise CalibrationRefused(
                "boot_progress_%s's realtime stamp is %.3fs off its own uptime payload (over the "
                "20ms budget)" % (tag, offset))

    def at(tag):
        """return a tag's time in seconds, or None"""
        return vals[tag][0] / 1000.0 if tag in vals else None

    bounds = [
        ("zygote:pre-preload", zygote_ts, at("preload_start")),
        ("zygote:preload", at("preload_start"), at("preload_end")),
        ("system_server:to-system_run", at("preload_end"), at("system_run")),
        ("system_server:pms-scan", at("pms_start"), at("pms_system_scan_start")),
        ("system_server:pms-ready", at("pms_system_scan_start"), at("pms_scan_end")),
        ("system_server:ams-ready", at("pms_scan_end"), at("ams_ready")),
        ("system_server:enable-screen", at("ams_ready"), at("enable_screen")),
        ("system_server:to-boot_completed", at("enable_screen"), window_end),
    ]
    children = [(a, b, name) for name, a, b in bounds if a is not None and b is not None and b > a]
    return ready_ts, window_end, children, None


def build_forest(row_defs, owner_intervals):
    """nest the intervals inside the rows"""
    rows = [Node(n, a, b, kind="row") for n, a, b in row_defs]
    combined = [(r.start, r.end, r) for r in rows]
    combined += [(s, e, Node(n, s, e)) for s, e, n in owner_intervals]
    combined.sort(key=lambda t: (t[0], -(t[1] - t[0])))
    stack = []
    for start, end, node in combined:
        while stack and (stack[-1][0] <= start + EPS or stack[-1][0] < end - EPS):
            stack.pop()
        if stack:
            stack[-1][1].children.append(node)
        stack.append((end, node))
    return rows


def add_residuals(node, is_row):
    """add residual leaves for gaps"""
    if not node.children:
        if is_row:
            label = node.residual_label or (node.name + ":residual")
            node.children.append(Node(label, node.start, node.end, kind="residual"))
        return
    for c in node.children:
        c.start = max(c.start, node.start)
        c.end = min(c.end, node.end)
    node.children.sort(key=lambda c: c.start)
    for i in range(len(node.children) - 1):
        nxt_start = node.children[i + 1].start
        if node.children[i].end > nxt_start + EPS:
            node.children[i].end = nxt_start
    cursor = node.start
    gap = 0.0
    for c in node.children:
        if c.start > cursor + EPS:
            gap += c.start - cursor
        cursor = max(cursor, c.end)
    if node.end > cursor + EPS:
        gap += node.end - cursor
    if gap > EPS:
        label = node.residual_label or (node.name + ":residual")
        node.children.append(Node(label, node.end - gap, node.end, kind="residual"))
    for c in list(node.children):
        if c.kind != "residual":
            add_residuals(c, is_row=False)


def collect_leaves(node, row_name):
    """yield each leaf's row, name, duration and start"""
    if not node.children:
        yield (row_name, node.name, node.duration, node.start)
        return
    for c in node.children:
        yield from collect_leaves(c, row_name)


def leaf_durations(node):
    """yield the duration of each leaf"""
    if not node.children:
        yield node.duration
        return
    for c in node.children:
        yield from leaf_durations(c)


def assert_tiling(rows):
    """compare each row's leaf sum with its span"""
    for row in rows:
        leaves = list(leaf_durations(row))
        total = sum(leaves)
        if abs(total - row.duration) > TILING_TOLERANCE_S + 0.0005 * len(leaves):
            return False, "%s: leaves sum to %.3fs, row spans %.3fs" % (row.name, total, row.duration)
    return True, ""


def build(lines, events_text=None, boot_epoch=None):
    """build the attribution forest from dmesg"""
    lines = list(lines)
    window_start, end_ts, events, _launch_ts = boot_phases.parse(lines)
    rows = boot_phases.phases(window_start, end_ts, events)
    c_rows = [(name, a, b) for layer, name, a, b in rows if layer == "C"]

    scoped = []
    for line in lines:
        m = boot_phases.TS.match(line)
        if not m:
            continue
        ts = float(m.group(1))
        if window_start - EPS <= ts <= end_ts + EPS:
            scoped.append((ts, line))

    owners = []
    owners += extract_commands(scoped)
    exec_owners, annotations = extract_exec(scoped)
    owners += exec_owners
    owners += extract_propwait(scoped)
    owners += extract_rc_parse(scoped)
    owners += extract_netbpfload(scoped)
    owners += extract_apexd(scoped)

    idle = extract_idle(scoped, end_ts, events_text, boot_epoch)
    idle_residual_label = None
    if idle is not None:
        ready_ts, idle_end, idle_children, idle_residual_label = idle
        c_rows = [r for r in c_rows if r[1] < ready_ts - EPS]
        c_rows.append(("idle", ready_ts, idle_end))
        owners += idle_children

    forest = build_forest(c_rows, owners)
    if idle_residual_label:
        for row in forest:
            if row.name == "idle":
                row.residual_label = idle_residual_label
    for row in forest:
        add_residuals(row, is_row=True)

    total = sum(row.duration for row in forest)
    return forest, annotations, total


def _row_for(forest, ts_start):
    """return the row name for a start time"""
    for row in forest:
        if row.start - EPS <= ts_start <= row.end + EPS:
            return row.name
    return "?"


def render(forest, annotations, total, as_json=False):
    """print the attribution rows"""
    leaves = []
    for row in forest:
        leaves.extend(collect_leaves(row, row.name))
    ann_rows = [(_row_for(forest, s), name, e - s, s) for s, e, name in annotations]
    all_rows = sorted(leaves + ann_rows, key=lambda r: r[3])
    residual = [(r, o, s) for r, o, s, _t in leaves if o.endswith(":residual")]
    residual_total = sum(s for _r, _o, s in residual)

    if as_json:
        return json.dumps({
            "rows": [{"row": r, "owner": o, "seconds": s} for r, o, s, _t in all_rows],
            "residual_total_seconds": residual_total,
            "residual_nodes": len(residual),
        }, indent=2)

    out = []
    row_w = max((len(r) for r, _o, _s, _t in all_rows), default=3)
    owner_w = max((len(o) for _r, o, _s, _t in all_rows), default=5)
    out.append("%-*s %-*s %10s %8s" % (row_w, "row", owner_w, "owner", "seconds", "share"))
    for r, o, s, _t in all_rows:
        out.append("%-*s %-*s %10.3f %7.1f%%" % (row_w, r, owner_w, o, s, 100.0 * s / total if total else 0.0))
    out.append("")
    out.append("RESIDUAL total: %.3fs across %d nodes" % (residual_total, len(residual)))
    out.append("apexd:start:activate(parallel) is one window: apexd logs no per-APEX "
                "timing at INFO")
    return "\n".join(out)


def selftest():
    """run the boot-owners fixture tests"""

    def L(ts, msg):
        """return a dmesg line with a timestamp"""
        return "[%14.6f] %s" % (ts, msg)

    core = [
        L(0.000, "L3: RHIZO_MARKER launch_start"),
        L(1.000, "init: processing action (boot-cmd-row) from (a.rc:1)"),
        L(1.500, "init: Command 'write /x 1' action=boot-cmd-row (a.rc:2) took 200ms and succeeded"),
        L(2.000, "init: processing action (exec-row) from (a.rc:3)"),
        L(2.100, "init: SVC_EXEC service 'myexec' pid 50 (uid 0 gid 0+0 context default) started; waiting..."),
        L(2.900, "init: Service 'myexec' (pid 50) exited with status 0 waiting took 0.800000 seconds"),
        L(3.000, "init: processing action (propwait-row) from (a.rc:5)"),
        L(3.350, "apexd: Started. subcommand = (null)"),
        L(3.400, "apexd: Marking APEXd as starting"),
        L(3.700, "init: Wait for property 'apexd.status=activated' took 400ms"),
        L(3.750, "apexd: Marking APEXd as ready"),
        L(4.000, "init: processing action (netbpf-row) from (a.rc:7)"),
        L(4.100, "NetBpfLoad: map /sys/fs/bpf/tethering/map_offload_foo id 1"),
        L(4.200, "NetBpfLoad: map /sys/fs/bpf/net_shared/map_clatd_bar id 2"),
        L(4.300, "NetBpfLoad: success."),
        L(4.500, "L3: RHIZO_MARKER sys.boot_completed=1"),
    ]
    forest, annotations, total = build(core)
    assert annotations == [], annotations
    assert abs(total - 3.5) < 1e-9, total

    leaves = {(r, o): s for r, o, s, _t in
              (leaf for row in forest for leaf in collect_leaves(row, row.name))}
    assert abs(leaves[("boot-cmd-row", "cmd:write /x 1")] - 0.200) < 1e-9, leaves
    assert abs(leaves[("boot-cmd-row", "boot-cmd-row:residual")] - 0.800) < 1e-9, leaves
    assert abs(leaves[("exec-row", "exec:myexec")] - 0.800) < 1e-9, leaves
    assert abs(leaves[("propwait-row", "apexd:start:vold-binder")] - 0.050) < 1e-9, leaves
    assert abs(leaves[("propwait-row", "propwait:apexd.status=activated:residual")] - 0.350) < 1e-9, leaves
    assert abs(leaves[("netbpf-row", "netbpfload:offload.o")] - 0.100) < 1e-9, leaves
    assert abs(leaves[("netbpf-row", "netbpfload:clatd.o")] - 0.100) < 1e-9, leaves
    ok, msg = assert_tiling(forest)
    assert ok, msg
    out = render(forest, annotations, total)
    assert "RESIDUAL total: 2.250s across 5 nodes" in out, out

    forest[0].children[0].end -= 0.010
    ok, msg = assert_tiling(forest)
    assert not ok and "boot-cmd-row" in msg, (ok, msg)

    idle_log = [
        L(0.000, "L3: RHIZO_MARKER launch_start"),
        L(1.000, "init: processing action (some-row) from (a.rc:1)"),
        L(4.600, "init: processing action (ro.persistent_properties.ready=true) from (a.rc:9)"),
        L(4.700, "init: starting service 'zygote'..."),
        L(9.000, "L3: RHIZO_MARKER sys.boot_completed=1"),
    ]
    good_events = "\n".join([
        "----- beginning of events",
        "    1004.750000  1000  1000 I boot_progress_preload_start: 4750",
        "    1004.900000  1000  1000 I boot_progress_preload_end: 4900",
        "    1005.000000  1000  1000 I boot_progress_system_run: 5000",
        "    1005.100000  1000  1000 I boot_progress_pms_start: 5100",
        "    1005.200000  1000  1000 I boot_progress_pms_system_scan_start: 5200",
        "    1005.400000  1000  1000 I boot_progress_pms_scan_end: 5400",
        "    1005.600000  1000  1000 I boot_progress_ams_ready: 5600",
        "    1005.700000  1000  1000 I boot_progress_enable_screen: 5700",
    ])

    f2, _a2, _t2 = build(idle_log, events_text=good_events, boot_epoch=1000.005)
    idle_row = next(r for r in f2 if r.name == "idle")
    idle_leaves = {o: s for _r, o, s, _t in collect_leaves(idle_row, "idle")}
    assert abs(idle_leaves["zygote:preload"] - 0.150) < 1e-9, idle_leaves
    assert abs(idle_leaves["system_server:to-boot_completed"] - 3.300) < 1e-9, idle_leaves
    assert "idle:no-events-capture" not in idle_leaves, idle_leaves
    ok, msg = assert_tiling(f2)
    assert ok, msg

    f3, _a3, _t3 = build(idle_log)
    idle_row3 = next(r for r in f3 if r.name == "idle")
    idle_leaves3 = {o: s for _r, o, s, _t in collect_leaves(idle_row3, "idle")}
    assert abs(idle_leaves3["idle:no-events-capture"] - 4.400) < 1e-9, idle_leaves3

    try:
        build(idle_log, events_text=good_events, boot_epoch=1000.050)
    except CalibrationRefused as e:
        assert "0.050" in str(e) and "20ms" in str(e), e
    else:
        raise AssertionError("a 50ms calibration offset was accepted")

    ran = sum(1 for line in inspect.getsource(selftest).splitlines()
              if line.strip().startswith("assert "))
    print("boot-owners selftest: %d assertions passed" % ran)


def main():
    """parse the arguments and print the boot owners of a log"""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", nargs="?", help="a dmesg capture; omit to read stdin")
    ap.add_argument("--events", help="logcat -d -b events -v epoch text, captured after boot_completed")
    ap.add_argument("--calib-boot-epoch", type=float, dest="boot_epoch",
                     help="the guest's CLOCK_REALTIME minus CLOCK_MONOTONIC (seconds), sampled after boot")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0

    lines = (open(args.log) if args.log else sys.stdin).readlines()
    events_text = open(args.events).read() if args.events else None

    try:
        forest, annotations, total = build(lines, events_text, args.boot_epoch)
    except boot_phases.NoAnchor as e:
        print("boot-owners: %s" % e, file=sys.stderr)
        return 1
    except CalibrationRefused as e:
        print("boot-owners: %s" % e, file=sys.stderr)
        return 3

    ok, msg = assert_tiling(forest)
    if not ok:
        print("boot-owners: tiling check failed: %s" % msg, file=sys.stderr)
        return 2

    print(render(forest, annotations, total, args.json))
    return 0


if __name__ == "__main__":
    sys.exit(main())
