#!/usr/bin/env python3
"""read rhizo host-delay records out of an android perfetto trace"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import perfetto_tp as tpmod  # noqa: E402
from perfetto_tp import TraceError, ld, plain_trace, tp_query, vi  # noqa: E402

SLICE_NAME = "held off by the host"
WORK_PERIODS_TRACK = "rhizo work periods"
HOST_DELAYED_TRACK = "rhizo host-delayed work periods"
DELAYS_TRACK = "rhizo host delays"
HELD_US_TRACK = "rhizo held us"
COUNTER_KEYS = {WORK_PERIODS_TRACK: "work_periods", HOST_DELAYED_TRACK: "host_delayed",
                DELAYS_TRACK: "delays", HELD_US_TRACK: "held_us"}
DELAYED_WP_NS = 2_000_000
APP_DEFAULT = "com.android.settings"
BENIGN_STATS = {"config_write_into_file_no_flush"}
CLOCK_BOOTTIME = 6


def _sql_str(s):
    """return the string quoted for SQL"""
    return "'%s'" % s.replace("'", "''")


def _comm(name):
    """get a process name's last 15 bytes"""
    return name.encode()[-15:].decode(errors="replace")


def load(path, app=APP_DEFAULT, tp=tpmod.TP_DEFAULT):
    """load the records of a perfetto trace"""
    with plain_trace(path) as trace:
        stats = [s for s in tp_query(tp, trace, "select name, idx, value from stats "
                                                "where severity in ('error', 'data_loss') and value > 0;")
                 if s["name"] not in BENIGN_STATS]
        if stats:
            raise TraceError("%s: trace_processor reports import errors: %s"
                             % (path, ", ".join("%s[%s]=%s" % (s["name"], s["idx"], s["value"]) for s in stats)))
        recs = tp_query(tp, trace, (
            "select s.ts, s.dur, t.tid, t.name as thread, p.pid, p.name as process, "
            "extract_arg(s.arg_set_id, 'debug.held_us') as held_us, "
            "extract_arg(s.arg_set_id, 'debug.work_period') as work_period "
            "from slice s join thread_track tt on s.track_id = tt.id join thread t using (utid) "
            "left join process p using (upid) where s.name = %s order by s.ts, t.tid;" % _sql_str(SLICE_NAME)))
        ctrs = tp_query(tp, trace, (
            "select pct.name as track, p.pid, p.name as process, c.value "
            "from counter c join process_counter_track pct on c.track_id = pct.id join process p using (upid) "
            "where pct.name in (%s) order by c.ts, c.id;" % ", ".join(_sql_str(t) for t in COUNTER_KEYS)))
        thr = tp_query(tp, trace, ("select t.tid, t.name as thread, p.pid, p.name as process "
                                   "from thread t left join process p using (upid) where t.tid > 0 order by t.tid;"))
        procs = tp_query(tp, trace, "select pid, name from process where pid > 0 and name is not null;")
        sfs = sorted({int(p["pid"]) for p in procs if p["name"] in ("/system/bin/surfaceflinger", "surfaceflinger")})
        frames = tp_query(tp, trace, (
            "select a.surface_frame_token as token, a.ts, a.dur, a.jank_type, a.on_time_finish, p.pid as pid, "
            "(select min(e.ts) from expected_frame_timeline_slice e "
            "where e.surface_frame_token = a.surface_frame_token and e.upid = a.upid) as expected_ts "
            "from actual_frame_timeline_slice a left join process p using (upid) "
            "where (a.layer_name glob 'TX - ' || %s || '/*' or a.layer_name glob %s || '/*') "
            "and a.surface_frame_token is not null "
            "order by a.ts, a.surface_frame_token;" % (_sql_str(app), _sql_str(app))))

    def opt(v):
        """return the value as an int, or None"""
        return None if v is None else int(v)

    records = []
    for r in recs:
        if r["held_us"] is None or r["work_period"] is None:
            raise TraceError("%s: a %r slice at %s on tid %s lacks its held_us or work_period annotation"
                             % (path, SLICE_NAME, r["ts"], r["tid"]))
        if int(r["dur"]) < 0:
            raise TraceError("%s: a %r slice at %s on tid %s never ends" % (path, SLICE_NAME, r["ts"], r["tid"]))
        records.append({"pid": opt(r["pid"]), "tid": int(r["tid"]), "thread": r["thread"], "process": r["process"],
                        "ts": int(r["ts"]), "dur": int(r["dur"]), "held_us": int(r["held_us"]),
                        "work_period": int(r["work_period"])})
    counters, seen = {}, set()
    for r in ctrs:
        pid, key, value = str(int(r["pid"])), COUNTER_KEYS[r["track"]], int(float(r["value"]))
        c = counters.setdefault(pid, {"process": r["process"], **dict.fromkeys(COUNTER_KEYS.values()),
                                      "first": dict.fromkeys(COUNTER_KEYS.values())})
        if (pid, key) not in seen:
            seen.add((pid, key))
            c["first"][key] = value
        c[key] = value
    threads = [{"pid": opt(r["pid"]), "tid": int(r["tid"]), "thread": r["thread"], "process": r["process"]} for r in thr]
    names = {app, _comm(app)}
    pids = sorted({int(p["pid"]) for p in procs if p["name"] in names})
    if len(pids) > 1:
        raise TraceError("%s: %s names %d processes (pids %s)" % (path, app, len(pids), pids))
    frame_pids = sorted({int(r["pid"]) for r in frames if r["pid"] is not None})
    if len(frame_pids) > 1:
        raise TraceError("%s: FrameTimeline draws %s from %d pids (%s)" % (path, app, len(frame_pids), frame_pids))
    pid = (frame_pids or pids or [None])[0]
    ui = next((t["tid"] for t in threads if pid is not None and t["pid"] == pid and t["tid"] == pid), None)
    render = min((t["tid"] for t in threads if pid is not None and t["pid"] == pid and t["thread"] == "RenderThread"),
                 default=None)
    return {"records": records,
            "counters": counters,
            "threads": threads,
            "frames": [{"pid": opt(r["pid"]), "token": int(r["token"]), "ts": int(r["ts"]), "dur": int(r["dur"]),
                        "jank_type": r["jank_type"] or "", "expected_ts": opt(r["expected_ts"]),
                        "on_time": r["on_time_finish"] is not None and int(r["on_time_finish"]) == 1} for r in frames],
            "surfaceflinger": {"pid": sfs[0] if len(sfs) == 1 else None},
            "app": {"name": app, "pid": pid, "ui_tid": ui, "render_tid": render}}


def held_in_window(record, t0, t1):
    """get the held ns inside a time window"""
    held = record["held_us"] * 1000
    span = record["dur"]
    if span <= 0:
        return held if t0 <= record["ts"] < t1 else 0
    overlap = min(record["ts"] + span, t1) - max(record["ts"], t0)
    return held * overlap // span if overlap > 0 else 0


def recount(records, delayed_wp_ns=DELAYED_WP_NS):
    """count delays and held time per pid"""
    out, per_wp = {}, {}
    for r in records:
        o = out.setdefault(r["pid"], {"delays": 0, "held_us": 0, "host_delayed": 0})
        o["delays"] += 1
        o["held_us"] += r["held_us"]
        per_wp[(r["pid"], r["tid"], r["work_period"])] = per_wp.get((r["pid"], r["tid"], r["work_period"]), 0) + r["held_us"] * 1000
    for (pid, _tid, _wp), held in per_wp.items():
        out[pid]["host_delayed"] += held >= delayed_wp_ns
    return out


SYNTH_SEQ = 7


def _uuid(*parts):
    """return a unique id built from the parts"""
    return 1 + sum(p << (16 * i) for i, p in enumerate(parts))


def synth_packets(processes, threads, records, counters):
    """build TracePacket payloads for a synthetic trace"""
    tree = b"".join(ld(1, vi(1, pid) + ld(3, cmd.encode())) for pid, cmd in processes)
    tree += b"".join(ld(2, vi(1, tid) + ld(2, comm.encode()) + vi(3, pid)) for pid, tid, comm in threads)
    packets = [vi(8, 1) + vi(10, 1) + ld(2, tree)]

    def pkt(ts, body):
        """return a packet with the timestamp and body"""
        return (vi(8, ts) if ts is not None else b"") + vi(58, CLOCK_BOOTTIME) + vi(10, SYNTH_SEQ) + body

    comms = {(pid, tid): comm for pid, tid, comm in threads}
    for pid, tid in sorted({(r[0], r[1]) for r in records}):
        packets.append(pkt(None, ld(60, vi(1, _uuid(pid, tid)) + ld(4, vi(1, pid) + vi(2, tid) + ld(5, comms[(pid, tid)].encode())))))
    for pid, tid, ts, dur, held_us, wp in records:
        ann = ld(4, ld(10, b"held_us") + vi(4, held_us)) + ld(4, ld(10, b"work_period") + vi(4, wp))
        packets.append(pkt(ts, ld(11, vi(9, 1) + vi(11, _uuid(pid, tid)) + ld(23, SLICE_NAME.encode()) + ann)))
        packets.append(pkt(ts + dur, ld(11, vi(9, 2) + vi(11, _uuid(pid, tid)))))
    for pid, samples in sorted(counters.items()):
        proc_uuid = _uuid(pid, 1, 1)
        names = dict(processes)
        packets.append(pkt(None, ld(60, vi(1, proc_uuid) + ld(3, vi(1, pid) + ld(6, names[pid].encode())))))
        tracks = ((1, WORK_PERIODS_TRACK), (2, HOST_DELAYED_TRACK), (3, DELAYS_TRACK), (4, HELD_US_TRACK))
        width = max(len(sm) for sm in samples) - 1
        for slot, track in tracks[:width]:
            packets.append(pkt(None, ld(60, vi(1, _uuid(pid, 1, 1, slot)) + vi(5, proc_uuid) + ld(2, track.encode()) + ld(8, b""))))
        for sample in samples:
            for (slot, _track), value in zip(tracks, sample[1:]):
                packets.append(pkt(sample[0], ld(11, vi(9, 4) + vi(11, _uuid(pid, 1, 1, slot)) + vi(30, value))))
    return packets


def selftest(tp):
    """run the host-delay-trace self tests"""
    fail = []

    def check(name, cond):
        """print ok or FAIL for a case and record failures"""
        print(("ok" if cond else "FAIL") + ": " + name)
        if not cond:
            fail.append(name)

    def rec(held_us, ts, dur, pid=1, tid=1, wp=0):
        """return a test record"""
        return {"pid": pid, "tid": tid, "thread": "t", "process": "p", "ts": ts, "dur": dur, "held_us": held_us, "work_period": wp}

    T = 1_000_000_000
    r = rec(2000, T, 2_000_000)
    check("held == span, window covers it: the held time exactly, 2000000", held_in_window(r, T - 5, T + 3_000_000) == 2_000_000)
    check("held == span, window takes the middle 1 ms: exactly 1000000", held_in_window(r, T + 500_000, T + 1_500_000) == 1_000_000)
    p = rec(2000, T, 4_000_000)
    check("held 2 ms over a 4 ms span, window on the second half: proportional, 1000000", held_in_window(p, T + 2_000_000, T + 9_000_000) == 1_000_000)
    check("held 2 ms over a 4 ms span, window across the whole span: 2000000", held_in_window(p, T, T + 4_000_000) == 2_000_000)
    check("a window before the record is zero", held_in_window(r, T - 9_000_000, T - 1) == 0)
    check("a window after the record is zero", held_in_window(r, T + 2_000_001, T + 9_000_000) == 0)
    check("a window that only touches the record's end or start is zero",
          held_in_window(r, T + 2_000_000, T + 3_000_000) == 0 and held_in_window(r, T - 1_000_000, T) == 0)
    check("a record shorter than its held time is not scaled up (window inside, held 3 ms over 1 ms: 3 x overlap)",
          held_in_window(rec(3000, T, 1_000_000), T, T + 1_000_000) == 3_000_000)

    rc = recount([rec(1000, 1, 1, pid=5, tid=9, wp=3), rec(1000, 2, 1, pid=5, tid=9, wp=3),
                  rec(1900, 3, 1, pid=5, tid=9, wp=4), rec(2500, 4, 1, pid=5, tid=8, wp=3),
                  rec(2000, 5, 1, pid=6, tid=9, wp=3)])
    check("recount: pid 5 has 4 records, 6400 us held, and host-delayed work periods (9,3)=2000 and (8,3)=2500 but not (9,4)=1900",
          rc[5] == {"delays": 4, "held_us": 6400, "host_delayed": 2})
    check("recount: a work period of exactly 2000 us is host-delayed, and pids are counted apart",
          rc[6] == {"delays": 1, "held_us": 2000, "host_delayed": 1})
    check("recount: 1.9 ms alone is not host-delayed; the same index on another tid is another work period",
          recount([rec(1900, 1, 1, tid=1, wp=1)])[1]["host_delayed"] == 0
          and recount([rec(1100, 1, 1, tid=1, wp=1), rec(1100, 2, 1, tid=2, wp=1)])[1]["host_delayed"] == 0)
    check("recount: the threshold is an argument (1.9 ms counts at 1.5 ms)",
          recount([rec(1900, 1, 1)], delayed_wp_ns=1_500_000)[1]["host_delayed"] == 1)

    if not os.path.isfile(tp):
        check("trace_processor present at %s for the trace cases" % tp, False)
        return fail
    APP, OTHER = "com.android.settings", "com.example.other"
    boot_minus_mono = 5_000_000_000
    frames = [(7001, 100_000_000_000, 20_000_000, "App Deadline Missed"), (7002, 100_200_000_000, 20_000_000, "None")]
    processes = [(4242, APP), (900, OTHER)]
    threads = [(4242, 4242, "ndroid.settings"), (4242, 4260, "RenderThread"), (4242, 4261, "hwuiTask0"),
               (900, 900, "example.other"), (900, 905, "RenderThread")]
    B = 105_000_000_000
    records = [(4242, 4260, B + 50_000_000, 1_000_000, 900, 8), (4242, 4242, B + 10_000_000, 3_000_000, 2500, 7),
               (4242, 4242, B + 20_000_000, 1_000_000, 1000, 9), (4242, 4242, B + 21_000_000, 1_000_000, 1000, 9),
               (900, 905, B + 30_000_000, 2_000_000, 2000, 1)]
    counters = {4242: [(B + 5_000_000, 0, 0, 0, 0), (B + 60_000_000, 5, 1, 4, 3000), (B + 90_000_000, 9, 3, 7, 6100)],
                900: [(B + 70_000_000, 2, 0)]}
    with tempfile.TemporaryDirectory() as td:
        path = os.path.join(td, "t.pftrace")
        with open(path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=synth_packets(processes, threads, records, counters)))
        doc = load(path, APP, tp)
        want_recs = [{"pid": 4242, "tid": 4242, "thread": "ndroid.settings", "process": APP, "ts": B + 10_000_000, "dur": 3_000_000, "held_us": 2500, "work_period": 7},
                     {"pid": 4242, "tid": 4242, "thread": "ndroid.settings", "process": APP, "ts": B + 20_000_000, "dur": 1_000_000, "held_us": 1000, "work_period": 9},
                     {"pid": 4242, "tid": 4242, "thread": "ndroid.settings", "process": APP, "ts": B + 21_000_000, "dur": 1_000_000, "held_us": 1000, "work_period": 9},
                     {"pid": 900, "tid": 905, "thread": "RenderThread", "process": OTHER, "ts": B + 30_000_000, "dur": 2_000_000, "held_us": 2000, "work_period": 1},
                     {"pid": 4242, "tid": 4260, "thread": "RenderThread", "process": APP, "ts": B + 50_000_000, "dur": 1_000_000, "held_us": 900, "work_period": 8}]
        check("records: five slices, every field, ordered by ts, the held_us and work_period annotations read back", doc["records"] == want_recs)
        zero4 = {"work_periods": 0, "host_delayed": 0, "delays": 0, "held_us": 0}
        check("counters: the last value of all four tracks per process (4242: 9 work periods, 3 host-delayed, 7 delays, 6100 us held)",
              doc["counters"].get("4242", {}).get("work_periods") == 9 and doc["counters"]["4242"].get("host_delayed") == 3
              and doc["counters"]["4242"].get("delays") == 7 and doc["counters"]["4242"].get("held_us") == 6100
              and doc["counters"]["4242"].get("process") == APP)
        check("counters: first is the first sample per track in trace order, the baseline before any record (4242: all zero), not the last",
              doc["counters"]["4242"].get("first") == zero4)
        check("counters: a track the process has none of reads null, first and last, never 0 (900 has two tracks: 2 work periods, 0 host-delayed)",
              doc["counters"]["900"] == {"process": OTHER, "work_periods": 2, "host_delayed": 0, "delays": None, "held_us": None,
                                         "first": {"work_periods": 2, "host_delayed": 0, "delays": None, "held_us": None}})
        check("counters: a track that exists and reads 0 stays 0 (4242's baseline delays and held_us), distinct from a track that is absent",
              doc["counters"]["4242"]["first"]["delays"] == 0 and doc["counters"]["4242"]["first"]["held_us"] == 0
              and doc["counters"]["900"]["delays"] is None)
        check("counters: first differs from last when a track moved (4242 first work_periods 0, last 9)",
              doc["counters"]["4242"].get("first", {}).get("work_periods") == 0 and doc["counters"]["4242"].get("work_periods") == 9)
        want_thr = sorted(({"pid": pid, "tid": tid, "thread": comm, "process": dict(processes)[pid]} for pid, tid, comm in threads),
                          key=lambda t: t["tid"])
        check("threads: Android's own table, with each thread's process", sorted(doc["threads"], key=lambda t: t["tid"]) == want_thr)
        check("frames: the app's two FrameTimeline frames with token, ts (BOOTTIME), dur, jank type and pid",
              doc["frames"] == [{"pid": 4242, "token": 7002, "ts": 100_200_000_000 + boot_minus_mono, "dur": 20_000_000, "jank_type": "None",
                                 "expected_ts": 100_200_000_000 + boot_minus_mono, "on_time": True},
                                {"pid": 4242, "token": 7001, "ts": 100_000_000_000 + boot_minus_mono + 300_000_000, "dur": 20_000_000, "jank_type": "App Deadline Missed",
                                 "expected_ts": 100_000_000_000 + boot_minus_mono, "on_time": True}])
        check("surfaceflinger: null when no process of that name is in the trace", doc["surfaceflinger"] == {"pid": None})
        check("app: found by name, UI thread tid == pid, RenderThread by name, in the app's own process",
              doc["app"] == {"name": APP, "pid": 4242, "ui_tid": 4242, "render_tid": 4260})
        comm_path = os.path.join(td, "comm.pftrace")
        with open(comm_path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=synth_packets(
                [(4242, "ndroid.settings"), (900, OTHER)], threads, records, counters)))
        check("app: a process the trace names by its 15-byte comm is found by the package name",
              load(comm_path, APP, tp)["app"] == {"name": APP, "pid": 4242, "ui_tid": 4242, "render_tid": 4260})
        usap_path = os.path.join(td, "usap.pftrace")
        with open(usap_path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=synth_packets(
                [(4242, "usap64"), (900, OTHER)], threads, records, counters)))
        check("app: a pool process the trace still names usap64 is found by the pid of the app's own frames",
              load(usap_path, APP, tp)["app"] == {"name": APP, "pid": 4242, "ui_tid": 4242, "render_tid": 4260})
        others = []
        for cookie, (pid, layer) in enumerate(((532, "TX - Splash Screen %s#137" % APP),
                                               (227, "TX - Surface(name=6c3e877 %s/%s.Main#141)/@0xb9 - animation-leash" % (APP, APP))), 500):
            boot = 100_100_000_000 + boot_minus_mono
            start = (vi(1, cookie) + vi(2, 8000 + cookie) + vi(3, 8006 + cookie) + vi(4, pid)
                     + ld(5, layer.encode()) + vi(6, 1) + vi(7, 1) + vi(8, 0) + vi(9, 1) + vi(10, 1))
            others.append(vi(8, boot) + vi(10, 1) + ld(76, ld(4, start)))
            others.append(vi(8, boot + 5_000_000) + vi(10, 1) + ld(76, ld(5, vi(1, cookie))))
        splash_path = os.path.join(td, "splash.pftrace")
        with open(splash_path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=others + synth_packets(
                [(4242, "usap64"), (900, OTHER)], threads, records, counters)))
        splash = load(splash_path, APP, tp)
        late_pkts = []
        boot = 100_400_000_000 + boot_minus_mono
        layer = ("TX - %s/%s.Main#1" % (APP, APP)).encode()
        start = (vi(1, 600) + vi(2, 7100) + vi(3, 7106) + vi(4, 4242) + ld(5, layer)
                 + vi(6, 1) + vi(7, 0) + vi(8, 0) + vi(9, 64) + vi(10, 1))
        late_pkts.append(vi(8, boot + 40_000_000) + vi(10, 1) + ld(76, ld(4, start)))
        late_pkts.append(vi(8, boot + 70_000_000) + vi(10, 1) + ld(76, ld(5, vi(1, 600))))
        exp = vi(1, 1600) + vi(2, 7100) + vi(3, 7106) + vi(4, 4242) + ld(5, layer)
        late_pkts.append(vi(8, boot) + vi(10, 1) + ld(76, ld(3, exp)))
        late_pkts.append(vi(8, boot + 16_000_000) + vi(10, 1) + ld(76, ld(5, vi(1, 1600))))
        late_path = os.path.join(td, "late.pftrace")
        with open(late_path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=late_pkts + synth_packets(
                processes + [(77, "/system/bin/surfaceflinger")], threads + [(77, 77, "surfaceflinger")], records, counters)))
        late = load(late_path, APP, tp)
        lf = [f for f in late["frames"] if f["token"] == 7100]
        check("frames: a late frame reads on_time false, its expected start 40 ms before its actual start",
              lf == [{"pid": 4242, "token": 7100, "ts": boot + 40_000_000, "dur": 30_000_000, "jank_type": "App Deadline Missed",
                      "expected_ts": boot, "on_time": False}])
        check("surfaceflinger: the pid of the process Android names /system/bin/surfaceflinger", late["surfaceflinger"] == {"pid": 77})
        check("frames: another process's layer that names the package (a splash screen, an animation leash) is not the app's",
              splash["app"]["pid"] == 4242 and [f["token"] for f in splash["frames"]] == [7002, 7001])
        clash_path = os.path.join(td, "clash.pftrace")
        with open(clash_path, "wb") as f:
            f.write(tpmod.synth_pftrace(frames, boot_minus_mono, APP, extra_packets=synth_packets(
                [(4242, "usap64"), (900, APP)], threads, records, counters)))
        check("app: the pid drawing the app's frames wins over an earlier, exited process that carries its name",
              load(clash_path, APP, tp)["app"] == {"name": APP, "pid": 4242, "ui_tid": 4242, "render_tid": 4260})
        none = load(path, "com.not.there", tp)
        check("app: an absent app gives null pid, tids and no frames",
              none["app"] == {"name": "com.not.there", "pid": None, "ui_tid": None, "render_tid": None} and none["frames"] == [])
        other = load(path, OTHER, tp)
        check("app: another app's records stay in records, its own tids come from its own process",
              other["app"] == {"name": OTHER, "pid": 900, "ui_tid": 900, "render_tid": 905} and len(other["records"]) == 5)
        recs_app = [r for r in doc["records"] if r["pid"] == 4242]
        check("recount over the trace's own records: 4 records, 5400 us held, host-delayed (4242,4242,9)=2000 and (4242,4242,7)=2500",
              recount(recs_app)[4242] == {"delays": 4, "held_us": 5400, "host_delayed": 2})
        cli = subprocess.run([sys.executable, os.path.abspath(__file__), path, "--app", APP, "--json", "--tp", tp],
                             capture_output=True, text=True)
        check("--json prints the same document load() returns", cli.returncode == 0 and json.loads(cli.stdout) == json.loads(json.dumps(doc)))
        import lzma
        with open(path, "rb") as f, lzma.open(path + ".xz", "wb") as g:
            g.write(f.read())
        check("a .pftrace.xz reads to the same document", load(path + ".xz", APP, tp) == doc)

        bad = os.path.join(td, "bad.pftrace")
        with open(bad, "wb") as f:
            f.write(b"".join(ld(1, p) for p in synth_packets(processes, threads, records, counters))
                    + ld(1, vi(8, B + 99_000_000) + vi(58, CLOCK_BOOTTIME) + vi(10, SYNTH_SEQ) + ld(11, vi(9, 4) + vi(11, 777) + vi(30, 1))))
        try:
            load(bad, APP, tp)
            check("a trace with trace_processor import errors (a counter on an undeclared track) is refused", False)
        except TraceError as e:
            check("a trace with trace_processor import errors (a counter on an undeclared track) is refused", "import errors" in str(e))
        noann = os.path.join(td, "noann.pftrace")
        with open(noann, "wb") as f:
            pk = synth_packets(processes, threads, [(4242, 4242, B, 1_000_000, 1000, 1)], {})
            pk[2] = pk[2].replace(b"held_us", b"held_xx")
            f.write(b"".join(ld(1, p) for p in pk))
        try:
            load(noann, APP, tp)
            check("a record without its held_us annotation is refused", False)
        except TraceError as e:
            check("a record without its held_us annotation is refused", "held_us" in str(e))
    print()
    print("host-delay-trace selftest: %s" % ("FAILED (%d)" % len(fail) if fail else "ok"))
    return fail


def main():
    """parse the arguments and report the host delay of the trace"""
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="--json prints one object, times in ns on the trace's clock:\n"
               "  records   [{pid, tid, thread, process, ts, dur, held_us, work_period}], one per slice, by ts\n"
               "  counters  {pid: {process, work_periods, host_delayed, delays, held_us, first: {...}}}\n"
               "  threads   [{pid, tid, thread, process}]\n"
               "  frames    [{pid, token, ts, dur, jank_type, expected_ts, on_time}] of the app's window\n"
               "  surfaceflinger {pid}; app {name, pid, ui_tid, render_tid}\n"
               "exit status: 0 read, 1 selftest failed, 2 usage error or trace refused (trace_processor\n"
               "import errors, or a record missing held_us, work_period or an end)")
    ap.add_argument("trace", nargs="?", help="the perfetto trace, .pftrace or .pftrace.xz")
    ap.add_argument("--app", default=APP_DEFAULT,
                    help="the app to read, by package name or its last 15 bytes (default %(default)s)")
    ap.add_argument("--json", action="store_true", help="print everything read as JSON instead of a summary")
    ap.add_argument("--tp", default=tpmod.TP_DEFAULT, metavar="PATH",
                    help="the trace_processor binary (default: $PERFETTO_TRACE_PROCESSOR, else toolchain/perfetto)")
    ap.add_argument("--selftest", action="store_true", help="run the built-in tests")
    args = ap.parse_args()
    if args.selftest:
        return 1 if selftest(args.tp) else 0
    if not args.trace:
        ap.error("a trace or --selftest")
    try:
        doc = load(args.trace, args.app, args.tp)
    except TraceError as e:
        print("host-delay-trace: %s" % e, file=sys.stderr)
        return 2
    if args.json:
        json.dump(doc, sys.stdout, indent=1)
        print()
        return 0
    rc = recount(doc["records"])
    print("%s: %d records, %d frames of %s (pid %s, UI tid %s, RenderThread %s)"
          % (args.trace, len(doc["records"]), len(doc["frames"]), args.app, doc["app"]["pid"], doc["app"]["ui_tid"], doc["app"]["render_tid"]))
    for pid, c in sorted(doc["counters"].items(), key=lambda kv: int(kv[0])):
        print("  %s %s: %s work periods, %s host-delayed, %s delays, %s us held (records alone: %s)"
              % (pid, c["process"], c["work_periods"], c["host_delayed"], c["delays"], c["held_us"], rc.get(int(pid))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
