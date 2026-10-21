#!/usr/bin/env python3
"""Write the decompressed seed set for a directory of capex files"""
import argparse
import hashlib
import os
import sys
import zipfile

MANIFEST_ENTRY = "apex_manifest.pb"
ORIGINAL_APEX_ENTRY = "original_apex"
PAYLOAD_SUFFIX = ".decompressed.apex"
PAYLOAD_MODE = 0o644
DIR_LABEL = b"u:object_r:apex_data_file:s0"
PAYLOAD_LABEL = b"u:object_r:staging_data_file:s0"
DEFAULT_MTIME = 0
BUILDER_VERSION = "2"


class ManifestError(ValueError):
    """exception for an unusable capex"""


def _read_varint(buf, i):
    """read a protobuf varint at an offset"""
    result = 0
    shift = 0
    n = len(buf)
    while True:
        if i >= n:
            raise ManifestError("truncated varint at offset %d" % i)
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7
        if shift > 63:
            raise ManifestError("varint at offset %d exceeds 64 bits" % i)


def parse_protobuf_fields(buf):
    """parse protobuf wire-format fields into a dict"""
    fields = {}
    i, n = 0, len(buf)
    while i < n:
        tag, i = _read_varint(buf, i)
        field_no, wire_type = tag >> 3, tag & 0x7
        if wire_type == 0:
            val, i = _read_varint(buf, i)
        elif wire_type == 1:
            val, i = buf[i:i + 8], i + 8
        elif wire_type == 2:
            length, i = _read_varint(buf, i)
            if i + length > n:
                raise ManifestError("length-delimited field %d overruns buffer" % field_no)
            val, i = buf[i:i + length], i + length
        elif wire_type == 5:
            val, i = buf[i:i + 4], i + 4
        else:
            raise ManifestError("unsupported wire type %d (field %d) at offset %d" % (wire_type, field_no, i))
        fields.setdefault(field_no, []).append(val)
    return fields


def parse_apex_manifest(buf):
    """return the name and version from the manifest"""
    fields = parse_protobuf_fields(buf)
    if 1 not in fields:
        raise ManifestError("no field 1 (name) in apex_manifest.pb")
    if 2 not in fields:
        raise ManifestError("no field 2 (version) in apex_manifest.pb")
    name_raw = fields[1][-1]
    version_raw = fields[2][-1]
    if not isinstance(name_raw, (bytes, bytearray)):
        raise ManifestError("field 1 (name) is not length-delimited")
    if not isinstance(version_raw, int):
        raise ManifestError("field 2 (version) is not a varint")
    try:
        name = name_raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ManifestError("field 1 (name) is not valid UTF-8: %s" % e)
    if not name:
        raise ManifestError("field 1 (name) is empty")
    if version_raw <= 0:
        raise ManifestError("field 2 (version) is not positive (%d)" % version_raw)
    return name, version_raw


def read_capex(path):
    """read the manifest and payload from a capex"""
    try:
        zf = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError) as e:
        raise ManifestError("%s: not a readable zip: %s" % (path, e))
    with zf:
        names = set(zf.namelist())
        if MANIFEST_ENTRY not in names:
            raise ManifestError("%s: no %s entry" % (path, MANIFEST_ENTRY))
        if ORIGINAL_APEX_ENTRY not in names:
            raise ManifestError("%s: no %s entry -- not a compressed APEX" % (path, ORIGINAL_APEX_ENTRY))
        try:
            manifest_bytes = zf.read(MANIFEST_ENTRY)
        except (zipfile.BadZipFile, OSError, RuntimeError) as e:
            raise ManifestError("%s: could not read %s: %s" % (path, MANIFEST_ENTRY, e))
        try:
            name, version = parse_apex_manifest(manifest_bytes)
        except ManifestError as e:
            raise ManifestError("%s: %s" % (path, e))
        try:
            payload = zf.read(ORIGINAL_APEX_ENTRY)
        except (zipfile.BadZipFile, OSError, RuntimeError) as e:
            raise ManifestError("%s: could not read %s: %s" % (path, ORIGINAL_APEX_ENTRY, e))
    return name, version, payload


def package_id(name, version):
    """return the name@version package id"""
    return "%s@%d" % (name, version)


def materialize_one(capex_path, out_dir, mtime, write=True, set_labels=True):
    """write the payload of a capex to out_dir"""
    name, version, payload = read_capex(capex_path)
    pkg_id = package_id(name, version)
    sha = hashlib.sha256(payload).hexdigest()
    if write:
        dest_path = os.path.join(out_dir, pkg_id + PAYLOAD_SUFFIX)
        with open(dest_path, "wb") as f:
            f.write(payload)
        os.chmod(dest_path, PAYLOAD_MODE)
        os.utime(dest_path, (mtime, mtime))
        if set_labels:
            os.setxattr(dest_path, "security.selinux", PAYLOAD_LABEL)
    return pkg_id, sha, len(payload)


def materialize(apex_dir, out_dir, exclude, mtime=DEFAULT_MTIME, active_dir=None,
                write=True, set_labels=True, apex_root_dir=None, seed="decompressed"):
    """write the payloads of the capex files"""
    capex_files = sorted(f for f in os.listdir(apex_dir) if f.endswith(".capex"))
    if not capex_files:
        raise ManifestError("no *.capex files under %s" % apex_dir)
    if write:
        if apex_root_dir:
            os.makedirs(apex_root_dir, exist_ok=True)
        os.makedirs(out_dir, exist_ok=True)
        if active_dir:
            os.makedirs(active_dir, exist_ok=True)
    results = []
    skipped = []
    for fname in capex_files:
        if fname in exclude:
            skipped.append(fname)
            continue
        pkg_id, sha, size = materialize_one(os.path.join(apex_dir, fname), out_dir, mtime,
                                            write=write and seed != "none",
                                            set_labels=set_labels)
        results.append((pkg_id, sha, size, fname))
    results.sort()
    if write:
        if set_labels:
            os.setxattr(out_dir, "security.selinux", DIR_LABEL)
        if active_dir:
            os.makedirs(active_dir, exist_ok=True)
            if set_labels:
                os.setxattr(active_dir, "security.selinux", DIR_LABEL)
        if apex_root_dir and set_labels:
            os.setxattr(apex_root_dir, "security.selinux", DIR_LABEL)
    return results, skipped


def write_manifest(path, results, skipped):
    """write the manifest file"""
    with open(path, "w") as f:
        f.write("builder_version=%s\n" % BUILDER_VERSION)
        for pkg_id, sha, size, fname in results:
            f.write("%s\t%s\t%d\t%s\n" % (pkg_id, sha, size, fname))
        for fname in skipped:
            f.write("excluded\t-\t-\t%s\n" % fname)


def _varint_bytes(n):
    """encode an integer as a protobuf varint"""
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _pb_string_field(field_no, s):
    """encode a length-delimited protobuf string field"""
    b = s.encode("utf-8")
    return _varint_bytes((field_no << 3) | 2) + _varint_bytes(len(b)) + b


def _pb_varint_field(field_no, n):
    """encode a protobuf varint field"""
    return _varint_bytes((field_no << 3) | 0) + _varint_bytes(n)


def _fixture_manifest(name, version):
    """encode a manifest from a module name and version"""
    return _pb_string_field(1, name) + _pb_varint_field(2, version)


def _write_capex(path, name, version, payload, manifest_bytes=None):
    """write a capex zip"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(MANIFEST_ENTRY, manifest_bytes if manifest_bytes is not None
                    else _fixture_manifest(name, version))
        zf.writestr(ORIGINAL_APEX_ENTRY, payload)


def selftest():
    """run the self test against fixture capex files"""
    import tempfile
    n = 0
    with tempfile.TemporaryDirectory() as d:
        apex_dir = os.path.join(d, "apex")
        apex_root_dir = os.path.join(d, "data-apex")
        out_dir = os.path.join(apex_root_dir, "decompressed")
        os.makedirs(apex_dir)
        os.makedirs(out_dir)

        payload_a = b"FAKE-ORIGINAL-APEX-BYTES-selftest-a" * 100
        payload_b = b"different-fake-payload-selftest-b" * 50
        _write_capex(os.path.join(apex_dir, "zzz.capex"), "com.android.selftesta", 7, payload_a)
        _write_capex(os.path.join(apex_dir, "aaa.capex"), "com.android.selftestb", 42, payload_b)
        _write_capex(os.path.join(apex_dir, "excluded.capex"), "com.android.excluded", 1, b"unused")

        have_xattr = os.geteuid() == 0 or os.environ.get("SUDO_UID") is not None

        results, skipped = materialize(apex_dir, out_dir, exclude={"excluded.capex"},
                                       set_labels=have_xattr, apex_root_dir=apex_root_dir)
        assert skipped == ["excluded.capex"], "exclude list not honored: %r" % skipped; n += 1
        assert [r[0] for r in results] == ["com.android.selftesta@7", "com.android.selftestb@42"], \
            "wrong package ids or wrong order: %r" % ([r[0] for r in results],); n += 1

        dest_a = os.path.join(out_dir, "com.android.selftesta@7.decompressed.apex")
        dest_b = os.path.join(out_dir, "com.android.selftestb@42.decompressed.apex")
        assert os.path.exists(dest_a) and os.path.exists(dest_b), "expected output files missing"; n += 1
        assert open(dest_a, "rb").read() == payload_a, "payload a not byte-exact"; n += 1
        assert open(dest_b, "rb").read() == payload_b, "payload b not byte-exact"; n += 1
        assert not os.path.exists(os.path.join(out_dir, "com.android.excluded@1.decompressed.apex")), \
            "excluded module was written anyway"; n += 1
        assert oct(os.stat(dest_a).st_mode & 0o777) == "0o644", "wrong mode on payload"; n += 1
        assert os.stat(dest_a).st_mtime == DEFAULT_MTIME, "mtime is not the deterministic sentinel"; n += 1
        assert hashlib.sha256(payload_a).hexdigest() == \
            [r[1] for r in results if r[0] == "com.android.selftesta@7"][0], \
            "manifest sha does not match the written payload"; n += 1

        if have_xattr:
            assert os.getxattr(dest_a, "security.selinux") == PAYLOAD_LABEL, "wrong payload label"; n += 1
            assert os.getxattr(out_dir, "security.selinux") == DIR_LABEL, "wrong dir label"; n += 1
            assert os.getxattr(apex_root_dir, "security.selinux") == DIR_LABEL, \
                "wrong (or missing) apex_root_dir label"; n += 1

        manifest_path = os.path.join(d, "manifest.tsv")
        write_manifest(manifest_path, results, skipped)
        manifest_text = open(manifest_path).read()
        assert "com.android.selftesta@7" in manifest_text, "manifest missing a real module"; n += 1
        assert "excluded.capex" in manifest_text, "manifest does not record the exclusion"; n += 1

        out_dir2 = os.path.join(d, "out2")
        os.makedirs(out_dir2)
        results2, _ = materialize(apex_dir, out_dir2, exclude={"excluded.capex"}, write=False,
                                  set_labels=have_xattr)
        assert results2 == results, "manifest-only pass disagrees with the write pass: %r vs %r" % (results2, results); n += 1
        assert os.listdir(out_dir2) == [], "manifest-only pass wrote a file anyway"; n += 1

        root3 = os.path.join(d, "data-apex-noseed")
        out_dir3 = os.path.join(root3, "decompressed")
        active3 = os.path.join(root3, "active")
        results3, skipped3 = materialize(apex_dir, out_dir3, exclude=set(), active_dir=active3,
                                         set_labels=have_xattr, apex_root_dir=root3, seed="none")
        assert os.listdir(out_dir3) == [], "--seed none wrote a payload: %r" % os.listdir(out_dir3); n += 1
        assert os.path.isdir(active3), "--seed none did not create active/"; n += 1
        assert skipped3 == [], "--seed none skipped something: %r" % skipped3; n += 1
        assert [r[0] for r in results3] == ["com.android.excluded@1", "com.android.selftesta@7",
                                            "com.android.selftestb@42"], \
            "--seed none does not enumerate every module: %r" % ([r[0] for r in results3],); n += 1
        if have_xattr:
            for _p in (root3, out_dir3, active3):
                assert os.getxattr(_p, "security.selinux") == DIR_LABEL, \
                    "--seed none left %s unlabeled or mislabeled" % _p
            n += 1

        bad_dir = os.path.join(d, "bad")
        os.makedirs(bad_dir)

        with zipfile.ZipFile(os.path.join(bad_dir, "truncated.capex"), "w") as zf:
            zf.writestr(MANIFEST_ENTRY, b"\x08\xff")
            zf.writestr(ORIGINAL_APEX_ENTRY, b"irrelevant")
        try:
            materialize_one(os.path.join(bad_dir, "truncated.capex"), out_dir, DEFAULT_MTIME,
                            set_labels=have_xattr)
            raise AssertionError("truncated apex_manifest.pb did not raise")
        except ManifestError:
            pass
        n += 1

        with zipfile.ZipFile(os.path.join(bad_dir, "uncompressed.capex"), "w") as zf:
            zf.writestr(MANIFEST_ENTRY, _fixture_manifest("com.android.notcompressed", 1))
        try:
            materialize_one(os.path.join(bad_dir, "uncompressed.capex"), out_dir, DEFAULT_MTIME,
                            set_labels=have_xattr)
            raise AssertionError("missing original_apex entry did not raise")
        except ManifestError:
            pass
        n += 1

        try:
            materialize(bad_dir, os.path.join(d, "bad_out"), exclude=set(), set_labels=have_xattr)
            raise AssertionError("materialize() over an all-bad directory did not raise")
        except ManifestError:
            pass
        n += 1

    print("materialize-data-template selftest: %d assertions passed%s"
          % (n, "" if have_xattr else " (label assertions skipped -- not privileged)"))
    return 0


def main():
    """materialize the modules"""
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apex-dir", metavar="DIR", help="the directory of *.capex files to read")
    ap.add_argument("--out-dir", metavar="DIR",
                    help="where each decompressed payload goes; must already exist and be writable")
    ap.add_argument("--active-dir", metavar="DIR", help="also create and label this directory (/data/apex/active)")
    ap.add_argument("--apex-root-dir", metavar="DIR",
                    help="also create and label this parent directory (/data/apex)")
    ap.add_argument("--exclude", metavar="NAME", action="append", default=[],
                    help="a .capex file name to leave out; repeatable")
    ap.add_argument("--manifest-out", metavar="FILE",
                    help="write each module's name, version, sha256 and size to FILE")
    ap.add_argument("--manifest-only", action="store_true",
                    help="read the modules and print the manifest only; write and label nothing")
    ap.add_argument("--mtime", metavar="EPOCH", type=int, default=DEFAULT_MTIME,
                    help="the mtime every written payload gets (default %(default)s)")
    ap.add_argument("--seed", choices=("decompressed", "none"), default="decompressed",
                    help="decompressed writes every payload; none writes only the labeled directories, "
                         "which is what Rhizo builds (default %(default)s)")
    ap.add_argument("--selftest", action="store_true", help="run the built-in tests")
    a = ap.parse_args()

    if a.selftest:
        sys.exit(selftest())

    if not a.apex_dir or (not a.manifest_only and not a.out_dir):
        ap.error("need --apex-dir and --out-dir (or --manifest-only), or --selftest")

    try:
        results, skipped = materialize(a.apex_dir, a.out_dir or "", set(a.exclude),
                                       mtime=a.mtime, active_dir=a.active_dir,
                                       write=not a.manifest_only,
                                       apex_root_dir=a.apex_root_dir, seed=a.seed)
    except ManifestError as e:
        print("MATERIALIZE_FAILED: %s" % e, file=sys.stderr)
        sys.exit(1)

    if a.manifest_out:
        write_manifest(a.manifest_out, results, skipped)
    for pkg_id, sha, size, fname in results:
        print("MODULE %s\t%s\t%d\t%s" % (pkg_id, sha, size, fname))
    for fname in skipped:
        print("EXCLUDED\t%s" % fname)
    seeded = 0 if (a.manifest_only or a.seed == "none") else len(results)
    print("MATERIALIZE_OK modules=%d skipped=%d seed=%s seeded=%d builder_version=%s"
          % (len(results), len(skipped), a.seed, seeded, BUILDER_VERSION))
    sys.exit(0)


if __name__ == "__main__":
    main()
