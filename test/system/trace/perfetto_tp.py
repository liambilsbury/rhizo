import contextlib
import csv
import io
import lzma
import os
import subprocess
import tempfile

TP_DEFAULT = os.environ.get("PERFETTO_TRACE_PROCESSOR",
                            os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "toolchain/perfetto/trace_processor_shell"))


class TraceError(Exception):
    pass


def tp_query(tp, trace, sql):
    """return the query rows"""
    if not os.path.isfile(tp):
        raise TraceError("trace_processor not found at %s (set PERFETTO_TRACE_PROCESSOR or --tp)" % tp)
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as f:
        f.write(sql)
        sql_path = f.name
    try:
        run = subprocess.run([tp, "-q", sql_path, trace], capture_output=True, text=True)
    finally:
        os.unlink(sql_path)
    if run.returncode != 0:
        raise TraceError("trace_processor failed on %s (rc=%d): %s" % (trace, run.returncode, run.stderr.strip()[-300:]))
    lines = run.stdout.splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith('"')), None)
    if start is None:
        raise TraceError("trace_processor printed no result header for: %s" % sql.strip()[:80])
    rows = csv.DictReader(io.StringIO("\n".join(l for l in lines[start:] if l.strip())))
    return [{k: (None if v == "[NULL]" else v) for k, v in r.items()} for r in rows]


@contextlib.contextmanager
def plain_trace(path):
    """yield the path of an uncompressed trace"""
    if not path.endswith(".xz"):
        yield path
        return
    work = tempfile.NamedTemporaryFile(suffix=".pftrace", delete=False)
    try:
        with lzma.open(path, "rb") as src:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                work.write(chunk)
        work.close()
        yield work.name
    finally:
        work.close()
        os.unlink(work.name)


def varint(n):
    """encode a number as a protobuf varint"""
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | 0x80 if n else b)
        if not n:
            return bytes(out)


def vi(field, n):
    """encode a varint field"""
    return varint(field << 3) + varint(n)


def ld(field, payload):
    """encode a length-delimited field"""
    return varint(field << 3 | 2) + varint(len(payload)) + payload


JANK_BITS = {"None": 1, "SurfaceFlinger Scheduling": 2, "Prediction Error": 4, "Display HAL": 8,
             "SurfaceFlinger CPU Deadline Missed": 16, "App Deadline Missed": 64, "Buffer Stuffing": 128}


def synth_pftrace(frames, boot_minus_mono, pkg, snapshot_error_ns=0, extra_packets=()):
    """encode synthetic frames of the app pkg into a perfetto trace"""
    packets = []
    for snap_mono in (frames[0][1] - 1_000_000_000, frames[-1][1] + 1_000_000_000):
        clocks = b"".join(ld(1, vi(1, cid) + vi(2, val)) for cid, val in
                          ((6, snap_mono + boot_minus_mono), (3, snap_mono + snapshot_error_ns)))
        packets.append(vi(8, snap_mono + boot_minus_mono) + vi(10, 1) + ld(6, clocks))
    for cookie, (token, mono, dur, label) in enumerate(frames, 100):
        bits = sum(JANK_BITS[t.strip()] for t in label.split(","))
        layer = b"TX - %s/%s.Main#1" % (pkg.encode(), pkg.encode())
        start = (vi(1, cookie) + vi(2, token) + vi(3, token + 6) + vi(4, 4242) + ld(5, layer)
                 + vi(6, 1) + vi(7, 1) + vi(8, 0) + vi(9, bits) + vi(10, 1))
        boot = mono + boot_minus_mono
        late = 300_000_000 if "App Deadline Missed" in label else 0
        packets.append(vi(8, boot + late) + vi(10, 1) + ld(76, ld(4, start)))
        packets.append(vi(8, boot + late + dur) + vi(10, 1) + ld(76, ld(5, vi(1, cookie))))
        expected = vi(1, cookie + 1000) + vi(2, token) + vi(3, token + 6) + vi(4, 4242) + ld(5, layer)
        packets.append(vi(8, boot) + vi(10, 1) + ld(76, ld(3, expected)))
        packets.append(vi(8, boot + dur) + vi(10, 1) + ld(76, ld(5, vi(1, cookie + 1000))))
    packets.extend(extra_packets)
    return b"".join(ld(1, p) for p in packets)
