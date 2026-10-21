#!/usr/bin/env python3
"""Generate the reference image for a pixel assertion."""
import struct
import sys
import zlib

USAGE = """Usage: mkpattern.py --checker W H OUT.png
  The checkerboard phase matches the test app: (x + y) even is black."""


def write_png(path, width, height, rows):
    """write RGB scanlines to a PNG file"""
    def chunk(tag, data):
        """return a PNG chunk with its length and checksum"""
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    """write a checkerboard PNG of the requested size"""
    args = sys.argv[1:]
    if len(args) != 4 or args[0] != "--checker":
        print(__doc__ + "\n\n" + USAGE, file=sys.stderr)
        sys.exit(2)
    w, h, out = int(args[1]), int(args[2]), args[3]
    if w <= 0 or h <= 0:
        print(f"mkpattern.py: refusing a {w}x{h} image", file=sys.stderr)
        sys.exit(2)
    black, white = bytes((0, 0, 0)), bytes((255, 255, 255))
    rows = [b"".join(black if (x + y) % 2 == 0 else white for x in range(w)) for y in range(h)]
    write_png(out, w, h, rows)


if __name__ == "__main__":
    main()
