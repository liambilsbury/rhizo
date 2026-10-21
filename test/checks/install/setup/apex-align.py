#!/usr/bin/env python3

import importlib.util
import os
import shutil
import struct
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load_aligner():
    """return the apex aligner module loaded from its file"""
    spec = importlib.util.spec_from_file_location(
        "align_apex", os.path.join(HERE, "..", "..", "..", "..", "src", "install", "prepare", "align-apex.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_apex(path, payload=b"PAYLOAD" * 900, extra_entries=3):
    """write a zip with a misaligned APEX payload"""
    with zipfile.ZipFile(path, "w") as z:
        info = zipfile.ZipInfo("apex_payload.img")
        info.extra = b"\x00\x00"
        z.writestr(info, payload, compress_type=zipfile.ZIP_STORED)
        for i in range(extra_entries):
            z.writestr("entry_%d" % i, b"x" * (100 + i))
        z.writestr("apex_pubkey", b"not-a-real-key")


def fail(msg):
    """print a failure message and return 1"""
    print("check-apex-align: %s" % msg, file=sys.stderr)
    return 1


def main(argv):
    """run the check and report an exception as a failure"""
    try:
        return run()
    except Exception as e:
        return fail("%s: %s" % (type(e).__name__, e))


def run():
    """test align-apex.py on synthetic APEX zips"""
    aligner = load_aligner()
    tmp = tempfile.mkdtemp(prefix="apex-align-")
    try:
        src = os.path.join(tmp, "src.apex")
        dst = os.path.join(tmp, "dst.apex")
        make_apex(src)
        _, before = aligner.payload_data_offset(src)
        if before % aligner.ALIGN == 0:
            return fail("fixture payload is already aligned at %d" % before)
        aligner.align(src, dst)
        after = aligner.verify(src, dst)
        if after % aligner.ALIGN:
            return fail("aligned output puts the payload at %d" % after)

        second = os.path.join(tmp, "second.apex")
        aligner.align(dst, second)
        if aligner.verify(dst, second) % aligner.ALIGN:
            return fail("re-aligning an aligned APEX misaligned it")

        broken = os.path.join(tmp, "broken.apex")
        shutil.copy(dst, broken)
        with open(broken, "r+b") as f:
            f.seek(aligner.ALIGN + 16)
            f.write(b"\xff\xff\xff\xff")
        try:
            aligner.verify(src, broken)
        except Exception:
            pass
        else:
            return fail("verify() accepted an APEX whose payload was corrupted")

        try:
            aligner.verify(src, src)
        except ValueError:
            pass
        else:
            return fail("verify() accepted a misaligned payload at %d" % before)

        bad = os.path.join(tmp, "bad-extra.apex")
        shutil.copy(dst, bad)
        with open(bad, "r+b") as f:
            head = f.read(30)
            name_len = struct.unpack("<H", head[26:28])[0]
            f.seek(30 + name_len)
            f.write(struct.pack("<HH", 0x0000, 0xD935))
        try:
            aligner.check_extra_field(bad)
        except ValueError:
            pass
        else:
            return fail("check_extra_field() accepted a malformed extra field")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("align-apex.py aligns a payload to %d and rejects a corrupt or "
          "misaligned copy" % aligner.ALIGN)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
