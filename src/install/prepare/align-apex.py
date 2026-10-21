#!/usr/bin/env python3
"""Copy an APEX with apex_payload.img aligned to 4096 bytes"""

import struct
import sys
import zipfile

USAGE = """Usage: align-apex.py <src.apex> <dst.apex>"""

ALIGN = 4096
PAYLOAD = "apex_payload.img"
PAD_HEADER_ID = 0xD935


def find_eocd(data):
    """return the offset of the end-of-central-directory record"""
    at = data.rfind(b"PK\x05\x06")
    if at < 0:
        raise ValueError("no end-of-central-directory record: not a zip")
    return at


def payload_data_offset(path):
    """return the payload entry's header and data offsets"""
    with open(path, "rb") as f:
        with zipfile.ZipFile(path) as z:
            try:
                info = z.getinfo(PAYLOAD)
            except KeyError:
                raise ValueError("%s has no %s entry" % (path, PAYLOAD))
        f.seek(info.header_offset)
        head = f.read(30)
        if head[:4] != b"PK\x03\x04":
            raise ValueError("entry %s has no local file header" % PAYLOAD)
        name_len, extra_len = struct.unpack("<HH", head[26:30])
        return info.header_offset, info.header_offset + 30 + name_len + extra_len


def align(src, dst):
    """write the aligned APEX to dst"""
    header_offset, data_offset = payload_data_offset(src)
    if data_offset % ALIGN == 0:
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            while True:
                chunk = fi.read(1 << 20)
                if not chunk:
                    break
                fo.write(chunk)
        return 0
    if header_offset != 0:
        raise ValueError("%s is not the first entry (header at %d); this tool "
                         "shifts everything after it and only handles the "
                         "first-entry case" % (PAYLOAD, header_offset))
    data = open(src, "rb").read()
    eocd = find_eocd(data)
    entries, cd_size, cd_offset = struct.unpack("<HII", data[eocd + 10:eocd + 20])
    if len(data) - eocd > 22 + 65535:
        raise ValueError("end-of-central-directory record is not where it should be")

    head = bytearray(data[:30])
    name_len, extra_len = struct.unpack("<HH", head[26:30])
    name = data[30:30 + name_len]
    new_extra_len = (-(30 + name_len)) % ALIGN
    while new_extra_len < 4:
        new_extra_len += ALIGN
    pad = new_extra_len - extra_len
    new_extra = (struct.pack("<HH", PAD_HEADER_ID, new_extra_len - 4)
                 + b"\0" * (new_extra_len - 4))
    struct.pack_into("<H", head, 28, len(new_extra))

    out = bytearray()
    out += head + name + new_extra
    out += data[data_offset:cd_offset]

    at = cd_offset
    for _ in range(entries):
        if data[at:at + 4] != b"PK\x01\x02":
            raise ValueError("central directory entry expected at %d" % at)
        rec = bytearray(data[at:at + 46])
        n, e, c = struct.unpack("<HHH", rec[28:34])
        local = struct.unpack("<I", rec[42:46])[0]
        if local != 0:
            struct.pack_into("<I", rec, 42, local + pad)
        size = 46 + n + e + c
        out += rec + data[at + 46:at + size]
        at += size
    if at != cd_offset + cd_size:
        raise ValueError("central directory is %d bytes, expected %d"
                         % (at - cd_offset, cd_size))
    tail = bytearray(data[at:])
    struct.pack_into("<I", tail, find_eocd(tail) + 16, cd_offset + pad)
    out += tail
    with open(dst, "wb") as f:
        f.write(out)
    return pad


def check_extra_field(path):
    """check the extra field record sizes"""
    with open(path, "rb") as f:
        head = f.read(30)
        name_len, extra_len = struct.unpack("<HH", head[26:30])
        f.seek(30 + name_len)
        extra = f.read(extra_len)
    at = 0
    while at < len(extra):
        if len(extra) - at < 4:
            raise ValueError("%s: extra field has %d trailing byte(s), too few "
                             "for a record header" % (path, len(extra) - at))
        _, size = struct.unpack("<HH", extra[at:at + 4])
        if at + 4 + size > len(extra):
            raise ValueError("%s: extra field record claims %d bytes with %d "
                             "remaining" % (path, size, len(extra) - at - 4))
        at += 4 + size


def verify(src, dst):
    """check dst holds the entries of src"""
    _, offset = payload_data_offset(dst)
    if offset % ALIGN:
        raise ValueError("%s: payload lands at %d, not a multiple of %d"
                         % (dst, offset, ALIGN))
    check_extra_field(dst)
    with zipfile.ZipFile(src) as a, zipfile.ZipFile(dst) as b:
        want = [i.filename for i in a.infolist()]
        got = [i.filename for i in b.infolist()]
        if want != got:
            raise ValueError("%s holds %s, %s holds %s" % (src, want, dst, got))
        for name in want:
            if a.read(name) != b.read(name):
                raise ValueError("%s: entry %s differs from the source" % (dst, name))
    return offset


def main(argv):
    """align the apex payload"""
    if len(argv) != 3:
        print(USAGE, file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    pad = align(src, dst)
    offset = verify(src, dst)
    print("%s -> %s: payload at %d (padded %d bytes), %d entries verified identical"
          % (src, dst, offset, pad, len(zipfile.ZipFile(dst).infolist())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
