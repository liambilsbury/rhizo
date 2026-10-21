#!/usr/bin/env python3
"""read the rhizo-streamd TCP stream and measure its metrics"""
import argparse
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

USAGE = """Usage:
  stream-client.py capture --port P --frames N --out F.ivf [--times F.tsv]
  stream-client.py tap --port P --x X --y Y
  stream-client.py latency --port P --x X --y Y --out-prefix PFX
  stream-client.py export-latency --port P --frames N
  stream-client.py frame-to-png --i420 F --size WxH [--frame N] --out F.png
  stream-client.py raw-to-png --raw F --size WxH [--stride N] --out F.png
  stream-client.py --selftest
"""

HELLO_FMT = "<IIIii"
HELLO_LEN = struct.calcsize(HELLO_FMT)
HELLO_MAGIC = 0x52535731
INPUT_FMT = "<Iii"
FOURCC_CODEC = {0x30395056: "vp9", 0x31305641: "av1", 0x34363248: "h264"}
IVF_FOURCC = {"vp9": b"VP90", "av1": b"AV01"}
VPXDEC_CODEC = {"vp9": "vp9"}

IVF_HDR_LEN = 32
MAX_FRAME_BYTES = 64 * 1024 * 1024


def read_exactly(sock, n):
    """read n bytes from the socket"""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise IOError("stream closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return bytes(buf)


def read_hello(sock):
    """read the codec and size from the hello"""
    magic, version, fourcc, width, height = struct.unpack(HELLO_FMT, read_exactly(sock, HELLO_LEN))
    if magic != HELLO_MAGIC:
        raise IOError("stream hello magic is 0x%08x, not 0x%08x" % (magic, HELLO_MAGIC))
    codec = FOURCC_CODEC.get(fourcc)
    if codec is None:
        raise IOError("stream hello names codec fourcc 0x%08x, which this client cannot read"
                      % fourcc)
    if width <= 0 or height <= 0:
        raise IOError("stream hello names geometry %dx%d" % (width, height))
    return codec, width, height, version


def read_frame(sock):
    """read a frame and its presented_ns"""
    (presented_ns,) = struct.unpack("<q", read_exactly(sock, 8))
    (length,) = struct.unpack("<I", read_exactly(sock, 4))
    if length == 0 or length > MAX_FRAME_BYTES:
        raise IOError("frame length %d is outside anything this encoder emits" % length)
    return presented_ns, read_exactly(sock, length)


def write_ivf(path, codec, width, height, frames):
    """write the captured frames to an IVF file"""
    fourcc = IVF_FOURCC.get(codec)
    if fourcc is None:
        raise SystemExit("no IVF fourcc for codec %s" % codec)
    with open(path, "wb") as f:
        f.write(b"DKIF" + struct.pack("<HH", 0, IVF_HDR_LEN) + fourcc
                + struct.pack("<HH", width, height) + struct.pack("<III", 30, 1, len(frames))
                + b"\0\0\0\0")
        for i, data in enumerate(frames):
            f.write(struct.pack("<IQ", len(data), i))
            f.write(data)


def connect(host, port, timeout_s):
    """open a connected TCP socket with the timeout applied"""
    sock = socket.create_connection((host, port), timeout=timeout_s)
    sock.settimeout(timeout_s)
    return sock


def send_tap(sock, x, y):
    """send a pointer press and release at a point"""
    sock.sendall(struct.pack(INPUT_FMT, 0, x, y))
    sock.sendall(struct.pack(INPUT_FMT, 2, x, y))


def decode_ivf(ivf_path, codec, out_path):
    """decode an IVF file to i420 with vpxdec"""
    codec_arg = VPXDEC_CODEC.get(codec)
    if codec_arg is None:
        raise SystemExit("no decoder wired for codec %s" % codec)
    proc = subprocess.run(["vpxdec", "--codec=" + codec_arg, "--i420", "-o", out_path, ivf_path],
                          capture_output=True)
    if proc.returncode != 0:
        raise SystemExit("vpxdec failed on %s: %s"
                         % (ivf_path, proc.stderr.decode("utf-8", "replace").strip()))
    return out_path


def i420_frame(path, width, height, index):
    """read a frame from an i420 file"""
    frame_bytes = width * height * 3 // 2
    size = os.path.getsize(path)
    count = size // frame_bytes
    if count == 0:
        raise SystemExit("%s holds %d bytes, under one %dx%d i420 frame"
                         % (path, size, width, height))
    if index < 0:
        index = count + index
    if not 0 <= index < count:
        raise SystemExit("frame %d is outside the %d frame(s) in %s" % (index, count, path))
    with open(path, "rb") as f:
        f.seek(index * frame_bytes)
        return f.read(frame_bytes)


def luma_mean_abs_delta(a, b, width, height):
    """return the mean luma difference of two frames"""
    n = width * height
    total = sum(abs(x - y) for x, y in zip(a[:n], b[:n]))
    return total / float(n)


def write_rgb_png(rows, width, height, out_path):
    """write RGB scanlines to a PNG file"""
    def chunk(kind, body):
        """return a PNG chunk with its length and checksum"""
        return (struct.pack(">I", len(body)) + kind + body
                + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff))

    with open(out_path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(rows), 6)))
        f.write(chunk(b"IEND", b""))


def png_from_i420(data, width, height, out_path):
    """convert an i420 frame to a PNG file"""
    n = width * height
    y, u, v = data[:n], data[n:n + n // 4], data[n + n // 4:]
    half = width // 2
    rows = bytearray()
    for row in range(height):
        rows.append(0)
        crow = (row // 2) * half
        for col in range(width):
            yy = y[row * width + col] - 16
            uu = u[crow + (col // 2)] - 128
            vv = v[crow + (col // 2)] - 128
            r = (298 * yy + 409 * vv + 128) >> 8
            g = (298 * yy - 100 * uu - 208 * vv + 128) >> 8
            b = (298 * yy + 516 * uu + 128) >> 8
            rows.append(0 if r < 0 else 255 if r > 255 else r)
            rows.append(0 if g < 0 else 255 if g > 255 else g)
            rows.append(0 if b < 0 else 255 if b > 255 else b)
    write_rgb_png(rows, width, height, out_path)


def png_from_rgba(data, width, height, stride, out_path):
    """convert an RGBA buffer to a PNG file"""
    rows = bytearray()
    for row in range(height):
        rows.append(0)
        off = row * stride
        for col in range(width):
            px = off + col * 4
            rows += data[px:px + 3]
    write_rgb_png(rows, width, height, out_path)


def cmd_capture(args):
    """capture stream frames into an IVF file"""
    sock = connect(args.host, args.port, args.timeout)
    codec, width, height, version = read_hello(sock)
    print("RHIZO_STREAM_HELLO codec=%s version=%d size=%dx%d" % (codec, version, width, height),
          flush=True)
    frames, presented, times = [], [], []
    while len(frames) < args.frames:
        p, data = read_frame(sock)
        frames.append(data)
        presented.append(p)
        times.append(time.clock_gettime_ns(time.CLOCK_MONOTONIC))
    sock.close()
    write_ivf(args.out, codec, width, height, frames)
    if args.times:
        with open(args.times, "w") as f:
            for i, (p, t, data) in enumerate(zip(presented, times, frames)):
                f.write("%d\t%d\t%d\t%d\n" % (i, t, len(data), p))
    print("RHIZO_STREAM_CAPTURE codec=%s version=%d size=%dx%d frames=%d out=%s"
          % (codec, version, width, height, len(frames), args.out))
    return 0


def cmd_export_latency(args):
    """print the export latency of each frame"""
    sock = connect(args.host, args.port, args.timeout)
    read_hello(sock)
    for _ in range(args.frames):
        presented_ns, _ = read_frame(sock)
        received_ns = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        print("%.3f" % ((received_ns - presented_ns) / 1e6))
    sock.close()
    return 0


def cmd_tap(args):
    """send a tap to the stream"""
    sock = connect(args.host, args.port, args.timeout)
    codec, width, height, _ = read_hello(sock)
    send_tap(sock, args.x, args.y)
    sock.close()
    print("RHIZO_STREAM_TAP codec=%s size=%dx%d x=%d y=%d" % (codec, width, height, args.x, args.y))
    return 0


def cmd_latency(args):
    """print the milliseconds to the changed frame"""
    sock = connect(args.host, args.port, args.timeout)
    codec, width, height, _ = read_hello(sock)
    frames, times = [], []
    for _ in range(args.baseline_frames):
        _, data = read_frame(sock)
        frames.append(data)
        times.append(time.clock_gettime_ns(time.CLOCK_MONOTONIC))
    if len(frames) < args.baseline_frames:
        raise SystemExit("only %d of %d baseline frames arrived"
                         % (len(frames), args.baseline_frames))
    send_tap(sock, args.x, args.y)
    tap_ns = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    deadline = tap_ns + int(args.window_s * 1e9)
    while time.clock_gettime_ns(time.CLOCK_MONOTONIC) < deadline:
        _, data = read_frame(sock)
        frames.append(data)
        times.append(time.clock_gettime_ns(time.CLOCK_MONOTONIC))
    sock.close()

    ivf, raw = args.out_prefix + ".ivf", args.out_prefix + ".i420"
    write_ivf(ivf, codec, width, height, frames)
    decode_ivf(ivf, codec, raw)
    baseline = i420_frame(raw, width, height, args.baseline_frames - 1)
    for i in range(args.baseline_frames, len(frames)):
        if luma_mean_abs_delta(baseline, i420_frame(raw, width, height, i), width,
                               height) >= args.threshold:
            print("%.3f" % ((times[i] - tap_ns) / 1e6))
            return 0
    raise SystemExit("no frame in the %ss after the tap differed by %s or more"
                     % (args.window_s, args.threshold))


def cmd_frame_to_png(args):
    """write an i420 frame as a PNG"""
    width, height = (int(v) for v in args.size.split("x"))
    png_from_i420(i420_frame(args.i420, width, height, args.frame), width, height, args.out)
    print("RHIZO_STREAM_PNG out=%s size=%dx%d frame=%d" % (args.out, width, height, args.frame))
    return 0


def cmd_raw_to_png(args):
    """write a raw RGBA capture as a PNG"""
    width, height = (int(v) for v in args.size.split("x"))
    stride = args.stride if args.stride else width * 4
    data = open(args.raw, "rb").read()
    need = stride * height
    if len(data) < need:
        raise SystemExit("%s holds %d bytes, under one %dx%d frame at stride=%d (%d bytes)"
                         % (args.raw, len(data), width, height, stride, need))
    png_from_rgba(data, width, height, stride, args.out)
    print("RHIZO_CLIENT_TARGET_PNG out=%s size=%dx%d stride=%d" % (args.out, width, height, stride))
    return 0


class FakeSock:
    """fake socket for the selftest"""

    def __init__(self, data):
        """hold the bytes the selftest feeds to the reader"""
        self.data = data

    def recv(self, n):
        """return the next n bytes of the held data"""
        head, self.data = self.data[:n], self.data[n:]
        return head


def selftest():
    """run the selftest checks"""
    problems = []

    good = struct.pack(HELLO_FMT, HELLO_MAGIC, 1, 0x30395056, 1280, 800)
    if read_hello(FakeSock(good)) != ("vp9", 1280, 800, 1):
        problems.append("a good hello parsed as %r" % (read_hello(FakeSock(good)),))
    for what, blob in (
            ("a wrong magic", struct.pack(HELLO_FMT, 0xdeadbeef, 1, 0x30395056, 1280, 800)),
            ("an unknown codec", struct.pack(HELLO_FMT, HELLO_MAGIC, 1, 0x11111111, 1280, 800)),
            ("a zero geometry", struct.pack(HELLO_FMT, HELLO_MAGIC, 1, 0x30395056, 0, 800)),
            ("a short hello", good[:HELLO_LEN - 3])):
        try:
            read_hello(FakeSock(blob))
            problems.append("%s was accepted as a hello" % what)
        except (IOError, struct.error):
            pass

    body = b"\x01\x02\x03\x04"
    presented, got = read_frame(FakeSock(struct.pack("<q", 12345) + struct.pack("<I", len(body)) + body))
    if got != body or presented != 12345:
        problems.append("a good frame did not read back")
    for what, blob in (("a zero-length frame", struct.pack("<q", 0) + struct.pack("<I", 0)),
                       ("a frame longer than any encoder emits",
                        struct.pack("<q", 0) + struct.pack("<I", 1 << 30)),
                       ("a truncated frame body", struct.pack("<q", 0) + struct.pack("<I", 8) + b"123")):
        try:
            read_frame(FakeSock(blob))
            problems.append("%s was accepted" % what)
        except IOError:
            pass

    with tempfile.TemporaryDirectory() as d:
        ivf = os.path.join(d, "t.ivf")
        write_ivf(ivf, "vp9", 64, 48, [b"a" * 10, b"b" * 20])
        blob = open(ivf, "rb").read()
        if blob[:4] != b"DKIF" or blob[8:12] != b"VP90":
            problems.append("the IVF header does not name DKIF/VP90")
        if struct.unpack("<HH", blob[12:16]) != (64, 48):
            problems.append("the IVF header does not name 64x48")
        if struct.unpack("<I", blob[24:28])[0] != 2:
            problems.append("the IVF header does not count the two frames written")
        if len(blob) != IVF_HDR_LEN + 12 + 10 + 12 + 20:
            problems.append("the IVF file is %d bytes, not a header plus two framed payloads"
                            % len(blob))

        raw = os.path.join(d, "t.i420")
        flat = bytes([40] * 256) + bytes([128] * 128)
        moved = bytes([200] * 256) + bytes([128] * 128)
        open(raw, "wb").write(flat + moved)
        a = i420_frame(raw, 16, 16, 0)
        b = i420_frame(raw, 16, 16, 1)
        if luma_mean_abs_delta(a, a, 16, 16) != 0.0:
            problems.append("two identical frames read as changed")
        if abs(luma_mean_abs_delta(a, b, 16, 16) - 160.0) > 0.001:
            problems.append("a 160-level luma step read as %.3f"
                            % luma_mean_abs_delta(a, b, 16, 16))
        try:
            i420_frame(raw, 16, 16, 7)
            problems.append("a frame index past the end was accepted")
        except SystemExit:
            pass

        png = os.path.join(d, "t.png")
        png_from_i420(b, 16, 16, png)
        head = open(png, "rb").read(24)
        if head[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", head[16:24]) != (16, 16):
            problems.append("the PNG written is not a 16x16 PNG")

        rgba = bytes([10, 20, 30, 255, 40, 50, 60, 255]) + bytes(8)
        rgba_png = os.path.join(d, "rgba.png")
        png_from_rgba(rgba, 2, 1, 16, rgba_png)
        rhead = open(rgba_png, "rb").read()
        if rhead[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", rhead[16:24]) != (2, 1):
            problems.append("the RGBA PNG written is not a 2x1 PNG")
        idat_start = rhead.index(b"IDAT") + 4
        idat_len = struct.unpack(">I", rhead[idat_start - 8:idat_start - 4])[0]
        pixels = zlib.decompress(rhead[idat_start:idat_start + idat_len])
        if pixels != bytes([0, 10, 20, 30, 40, 50, 60]):
            problems.append("a padded-stride RGBA buffer did not decode to its two RGB pixels: "
                            "got %r" % (list(pixels),))

    if problems:
        for p in problems:
            print("SELFTEST FAILED: " + p, file=sys.stderr)
        return 1
    print("stream-client selftest: the hello, the frame framing, the IVF writer, the change "
          "detector and the PNG writer each take a good input and refuse a bad one")
    return 0


def main():
    """parse the command line and run the chosen subcommand"""
    ap = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE)
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="cmd")

    def net(p):
        """add the host, port and timeout options to a subcommand"""
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, required=True)
        p.add_argument("--timeout", type=float, default=30.0)

    cap = sub.add_parser("capture")
    net(cap)
    cap.add_argument("--frames", type=int, default=1)
    cap.add_argument("--out", required=True)
    cap.add_argument("--times")

    tap = sub.add_parser("tap")
    net(tap)
    tap.add_argument("--x", type=int, required=True)
    tap.add_argument("--y", type=int, required=True)

    lat = sub.add_parser("latency")
    net(lat)
    lat.add_argument("--x", type=int, required=True)
    lat.add_argument("--y", type=int, required=True)
    lat.add_argument("--baseline-frames", type=int, default=5)
    lat.add_argument("--window-s", type=float, default=3.0)
    lat.add_argument("--threshold", type=float, default=2.0)
    lat.add_argument("--out-prefix", required=True)

    exlat = sub.add_parser("export-latency")
    net(exlat)
    exlat.add_argument("--frames", type=int, default=20)

    png = sub.add_parser("frame-to-png")
    png.add_argument("--i420", required=True)
    png.add_argument("--size", required=True)
    png.add_argument("--frame", type=int, default=-1)
    png.add_argument("--out", required=True)

    raw = sub.add_parser("raw-to-png")
    raw.add_argument("--raw", required=True)
    raw.add_argument("--size", required=True)
    raw.add_argument("--stride", type=int, default=0)
    raw.add_argument("--out", required=True)

    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.cmd == "capture":
        return cmd_capture(args)
    if args.cmd == "tap":
        return cmd_tap(args)
    if args.cmd == "latency":
        return cmd_latency(args)
    if args.cmd == "export-latency":
        return cmd_export_latency(args)
    if args.cmd == "frame-to-png":
        return cmd_frame_to_png(args)
    if args.cmd == "raw-to-png":
        return cmd_raw_to_png(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
