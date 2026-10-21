#!/usr/bin/env python3
"""Write the generic Rhizo app icon, the Android robot's head, as a PNG

The Android robot is reproduced or modified from work created and shared by Google and used according
to terms described in the Creative Commons 3.0 Attribution License."""
import functools
import math
import struct
import sys
import zlib

SIZE = 256
GREEN = (61, 220, 132)

USAGE = """Usage: gen-rhizo-icon.py <out.png>"""
HEAD_CX, HEAD_CY, HEAD_R = 128.0, 190.0, 100.0
EYE_R = 10.0
EYES = ((88.0, 150.0), (168.0, 150.0))
ANTENNA_R = 5.0
ANTENNAE = ((84.0, 108.0, 62.0, 70.0), (172.0, 108.0, 194.0, 70.0))


def encode_png(width, height, rows):
    """return the PNG bytes of RGBA rows"""
    def chunk(tag, data):
        """build a PNG chunk from a tag and data"""
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def solid_png(size, rgba):
    """return the PNG bytes of a solid square"""
    return encode_png(size, size, [bytes(rgba) * size for _ in range(size)])


def _coverage(d):
    """return the edge coverage for a signed distance"""
    return 1.0 if d <= -0.5 else (0.0 if d >= 0.5 else 0.5 - d)


def _segment_d(px, py, ax, ay, bx, by):
    """return the distance from a point to a line segment"""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    length2 = vx * vx + vy * vy
    t = max(0.0, min(1.0, (wx * vx + wy * vy) / length2))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


@functools.lru_cache(maxsize=1)
def mark_png():
    """render the Android robot's head to a PNG"""
    rows = []
    for y in range(SIZE):
        py = y + 0.5
        row = bytearray()
        for x in range(SIZE):
            px = x + 0.5
            head = max(math.hypot(px - HEAD_CX, py - HEAD_CY) - HEAD_R, py - HEAD_CY)
            alpha = _coverage(head)
            for ex, ey in EYES:
                alpha = min(alpha, 1.0 - _coverage(math.hypot(px - ex, py - ey) - EYE_R))
            for ax, ay, bx, by in ANTENNAE:
                alpha = max(alpha, _coverage(_segment_d(px, py, ax, ay, bx, by) - ANTENNA_R))
            row += bytes((*GREEN, round(255 * alpha))) if alpha > 0.0 else b"\x00\x00\x00\x00"
        rows.append(row)
    return encode_png(SIZE, SIZE, rows)


def main(argv):
    """write the icon PNG to the path given"""
    if len(argv) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    with open(argv[1], "wb") as fh:
        fh.write(mark_png())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
