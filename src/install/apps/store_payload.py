#!/usr/bin/env python3
# extract, check and verify Aurora Store and LiteGapps payloads
import argparse
import hashlib
import io
import lzma
import mmap
import os
import re
import shutil
import sqlite3
import stat
import struct
import sys
import tarfile
import tempfile
import warnings
import zipfile
import zlib
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

MAX_MEMBER = 1 << 30
MAX_NESTED = 64 << 20
MAX_XML = 1 << 20
MAX_MANIFEST = 8 << 20
MAX_TOTAL = 4 << 30
MAX_MEMBERS = 100000
CHUNK = 1 << 20
PAGE = 4096
MANIFEST = "manifest.tsv"
SHA = re.compile(r"[0-9a-f]{64}")
LIB = re.compile(r"lib/x86_64/([A-Za-z0-9_.+-]+\.so)")

DEST_PATTERNS = tuple(re.compile(p) for p in (
    r"(priv-app|app)/([A-Za-z0-9_]+)/\2\.apk",
    r"(priv-app|app)/[A-Za-z0-9_]+/lib/x86_64/[A-Za-z0-9_.+-]+\.so",
    r"etc/(permissions|sysconfig)/gapps-[A-Za-z0-9_.-]+\.xml",
))

XML_ROOTS = ("permissions", "config")
XML_KEEP = {
    "permissions": {
        "privapp-permissions": ("package",),
        "split-permission": ("name", "targetSdk"),
    },
    "privapp-permissions": {
        "permission": ("name",),
        "deny-permission": ("name",),
    },
    "split-permission": {
        "new-permission": ("name",),
    },
    "config": {
        "allow-in-power-save": ("package",),
        "allow-in-power-save-except-idle": ("package",),
        "allow-in-data-usage-save": ("package",),
        "allow-implicit-broadcast": ("action",),
        "allow-unthrottled-location": ("package",),
        "allow-association": ("target", "allowed"),
        "app-link": ("package",),
        "app-data-isolation-whitelisted-app": ("package",),
        "backup-transport-whitelisted-service": ("service",),
        "bg-restriction-exemption": ("package",),
        "rollback-whitelisted-app": ("package",),
        "automatic-rollback-denylisted-app": ("package",),
        "update-ownership": ("package", "installer"),
    },
}
PLAIN = re.compile(r"[A-Za-z0-9_.$/]{1,255}")

SIG_V2, SIG_V3, SIG_V31 = 0x7109871A, 0xF05368C0, 0x1B93AD61
VERSION_CODE_ATTR = 0x0101021B


class Refused(Exception):
    """a refused archive, member or payload"""

    def __init__(self, reason, detail):
        super().__init__(detail)
        self.reason = reason


def log(msg):
    """print a log line to stderr"""
    print("store_payload: %s" % msg, file=sys.stderr)


def safe_name(name, label):
    """return a member name without ./ or a trailing /"""
    if not name or "\0" in name or "\\" in name or name.startswith("/"):
        raise Refused("unsafe-name", "%s holds a member named %r" % (label, name))
    while name.startswith("./"):
        name = name[2:]
    name = name.rstrip("/")
    parts = name.split("/")
    if not name or any(p in ("", ".", "..") for p in parts):
        raise Refused("unsafe-name", "%s holds a member named %r" % (label, name))
    return name


def check_dest(dest):
    """refuse a destination no payload may hold"""
    if not any(p.fullmatch(dest) for p in DEST_PATTERNS):
        raise Refused("bad-dest", "%r is not a payload destination (an APK, an x86_64 library or a gapps-*.xml)" % dest)


def read_capped(src, cap, label):
    """read a whole stream of at most cap bytes"""
    data = src.read(cap + 1)
    if len(data) > cap:
        raise Refused("oversize-member", "%s is larger than %d bytes" % (label, cap))
    return data


def copy_hashed(src, dst, cap, label):
    """copy a capped stream into a file and hash it"""
    h, n = hashlib.sha256(), 0
    while True:
        b = src.read(CHUNK)
        if not b:
            return h.hexdigest(), n
        n += len(b)
        if n > cap:
            raise Refused("oversize-member", "%s is larger than %d bytes" % (label, cap))
        h.update(b)
        dst.write(b)


def sha256_file(path):
    """return a file's sha256"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""):
            h.update(b)
    return h.hexdigest()


def describe(elem):
    """return an element's start tag as text"""
    attrs = "".join(" %s=%s" % (k, quoteattr(v)) for k, v in elem.attrib.items())
    return ("<%s%s>" % (elem.tag, attrs))[:240]


def filter_xml(data, label):
    """filter an XML by the element allowlist"""
    if len(data) > MAX_XML:
        raise Refused("xml-too-large", "%s is larger than %d bytes" % (label, MAX_XML))
    if re.search(rb"<!\s*(DOCTYPE|ENTITY)", data, re.I):
        raise Refused("xml-doctype", "%s carries a DOCTYPE or ENTITY declaration" % label)
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise Refused("xml-unparsable", "%s does not parse: %s" % (label, e))
    if root.tag not in XML_ROOTS:
        raise Refused("xml-root", "%s has root <%s>, not <permissions> or <config>" % (label, root.tag))
    dropped = []

    def kept(elem, depth):
        """return the lines for elem's children that pass the allowlist"""
        allowed = XML_KEEP.get(elem.tag, {})
        lines = []
        for child in elem:
            if not isinstance(child.tag, str):
                continue
            attrs = allowed.get(child.tag)
            why = None
            if attrs is None:
                why = "not on the element allowlist"
            elif set(child.attrib) != set(attrs):
                why = "attributes %s, not %s" % (sorted(child.attrib), list(attrs))
            elif not all(PLAIN.fullmatch(child.attrib[a]) for a in attrs):
                why = "a value that is not a plain name"
            if why:
                dropped.append("%s from %s: %s" % (describe(child), label, why))
                continue
            pad = "    " * depth
            tag = child.tag + "".join(" %s=%s" % (a, quoteattr(child.attrib[a])) for a in attrs)
            inner = kept(child, depth + 1)
            if inner:
                lines += ["%s<%s>" % (pad, tag)] + inner + ["%s</%s>" % (pad, child.tag)]
            else:
                lines.append("%s<%s/>" % (pad, tag))
        return lines

    source = re.sub(r"[^A-Za-z0-9_./!+-]", "_", label).replace("--", "__")
    lines = ['<?xml version="1.0" encoding="utf-8"?>',
             "<!-- %s, re-emitted through Rhizo's element allowlist -->" % source,
             "<%s>" % root.tag] + kept(root, 1) + ["</%s>" % root.tag]
    return ("\n".join(lines) + "\n").encode(), dropped


class Writer:
    """write payload files under a directory once per destination"""

    def __init__(self, out):
        self.out = out
        self.written = {}
        self.dropped = []

    def open_dest(self, dest, label):
        """create and open the file for a destination"""
        check_dest(dest)
        if dest in self.written:
            raise Refused("bad-take-list", "%s and %s both land on %s" % (self.written[dest], label, dest))
        self.written[dest] = label
        full = os.path.join(self.out, dest)
        d = self.out
        for part in os.path.dirname(dest).split("/"):
            d = os.path.join(d, part)
            if not os.path.isdir(d):
                os.mkdir(d)
                os.chmod(d, 0o755)
        f = open(full, "xb")
        os.fchmod(f.fileno(), 0o644)
        return f

    def put(self, src, dest, want, label):
        """write a member, checked against its sha256 when given"""
        if dest.endswith(".xml"):
            data = read_capped(src, MAX_XML, label)
            have = hashlib.sha256(data).hexdigest()
            if want and have != want:
                raise Refused("member-sha256-mismatch", "%s is %s, the take list says %s" % (label, have, want))
            body, dropped = filter_xml(data, label)
            for d in dropped:
                log("dropped %s" % d)
            self.dropped += dropped
            with self.open_dest(dest, label) as f:
                f.write(body)
            return
        with self.open_dest(dest, label) as f:
            have, _ = copy_hashed(src, f, MAX_MEMBER, label)
        if want and have != want:
            raise Refused("member-sha256-mismatch", "%s is %s, the take list says %s" % (label, have, want))


def zip_members(zf, label):
    """return a safe archive's members by name"""
    infos = zf.infolist()
    if len(infos) > MAX_MEMBERS:
        raise Refused("too-many-members", "%s holds %d members" % (label, len(infos)))
    members, total = {}, 0
    for info in infos:
        name = safe_name(info.filename, label)
        kind = stat.S_IFMT(info.external_attr >> 16)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise Refused("unsafe-member", "%s!%s is a link or device (mode %o)" % (label, name, info.external_attr >> 16))
        if info.flag_bits & 0x1:
            raise Refused("encrypted-member", "%s!%s is encrypted" % (label, name))
        if name in members:
            raise Refused("duplicate-member", "%s holds %s twice" % (label, name))
        if info.file_size > MAX_MEMBER:
            raise Refused("oversize-member", "%s!%s declares %d bytes" % (label, name, info.file_size))
        total += info.file_size
        if total > MAX_TOTAL:
            raise Refused("oversize-archive", "%s declares more than %d bytes" % (label, MAX_TOTAL))
        members[name] = info
    return members


def group(entries, label):
    """return entries grouped by their first path segment"""
    out = {}
    for segs, dest, want in entries:
        out.setdefault(segs[0], []).append((segs[1:], dest, want))
    for name, subs in out.items():
        whole = [s for s in subs if not s[0]]
        if whole and (len(whole) > 1 or len(subs) > 1):
            raise Refused("bad-take-list", "%s!%s is both taken and opened, or taken twice" % (label, name))
    return out


def take_member(name, src, subs, writer, label):
    """write a member or take entries from it"""
    if not subs[0][0]:
        writer.put(src, subs[0][1], subs[0][2], label)
    elif name.endswith(".zip"):
        data = read_capped(src, MAX_NESTED, label)
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                take_from_zip(zf, subs, writer, label)
        except zipfile.BadZipFile as e:
            raise Refused("bad-archive", "%s: %s" % (label, e))
    elif name.endswith(".tar.xz"):
        take_from_tar(src, "r|xz", subs, writer, label)
    elif name.endswith(".tar"):
        take_from_tar(src, "r|", subs, writer, label)
    else:
        raise Refused("bad-take-list", "%s is not a .zip, .tar or .tar.xz to open" % label)


def take_from_zip(zf, entries, writer, label):
    """take the listed entries out of an open zip"""
    members = zip_members(zf, label)
    for name, subs in group(entries, label).items():
        info = members.get(name)
        if info is None or info.is_dir():
            raise Refused("missing-member", "%s holds no file %s" % (label, name))
        try:
            with zf.open(info) as src:
                take_member(name, src, subs, writer, "%s!%s" % (label, name))
        except (zipfile.BadZipFile, zlib.error, EOFError) as e:
            raise Refused("bad-archive", "%s!%s: %s" % (label, name, e))


def take_from_tar(raw, mode, entries, writer, label):
    """take the listed entries out of a tar stream"""
    wanted = group(entries, label)
    seen, total = set(), 0
    data_filter = getattr(tarfile, "data_filter", None)
    try:
        with tarfile.open(fileobj=raw, mode=mode) as tf:
            for m in tf:
                name = safe_name(m.name, label)
                if name in seen:
                    raise Refused("duplicate-member", "%s holds %s twice" % (label, name))
                seen.add(name)
                if len(seen) > MAX_MEMBERS:
                    raise Refused("too-many-members", "%s holds more than %d members" % (label, MAX_MEMBERS))
                if not (m.isreg() or m.isdir()) or m.issparse():
                    raise Refused("unsafe-member", "%s!%s is a link, device or sparse file" % (label, name))
                if data_filter:
                    try:
                        data_filter(m, writer.out)
                    except tarfile.FilterError as e:
                        raise Refused("unsafe-member", "%s!%s: %s" % (label, name, e))
                if m.isdir():
                    continue
                if m.size > MAX_MEMBER:
                    raise Refused("oversize-member", "%s!%s declares %d bytes" % (label, name, m.size))
                total += m.size
                if total > MAX_TOTAL:
                    raise Refused("oversize-archive", "%s declares more than %d bytes" % (label, MAX_TOTAL))
                if name in wanted:
                    take_member(name, tf.extractfile(m), wanted[name], writer, "%s!%s" % (label, name))
    except (tarfile.TarError, lzma.LZMAError, EOFError) as e:
        raise Refused("bad-archive", "%s: %s" % (label, e))
    missing = sorted(set(wanted) - seen)
    if missing:
        raise Refused("missing-member", "%s holds no %s" % (label, ", ".join(missing)))


def read_take_list(path):
    """return a take list's member segments, destinations and sha256s"""
    entries = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 3 or not SHA.fullmatch(fields[2]):
                raise Refused("bad-take-list", "%s:%d is not <member> <dest> <sha256>" % (path, n))
            segs = tuple(safe_name(s, "%s:%d" % (path, n)) for s in fields[0].split("!"))
            check_dest(fields[1])
            entries.append((segs, fields[1], fields[2]))
    if not entries:
        raise Refused("bad-take-list", "%s lists nothing" % path)
    return entries


def data_offset(fp, info):
    """return where a zip member's data starts in the file"""
    fp.seek(info.header_offset)
    head = fp.read(30)
    if len(head) != 30 or head[:4] != b"PK\x03\x04":
        raise Refused("bad-apk", "%s has no local header" % info.filename)
    n, e = struct.unpack("<HH", head[26:30])
    return info.header_offset + 30 + n + e


def native_libs(path):
    """return the APK's x86_64 libraries and whether any need extracting"""
    with open(path, "rb") as fp, zipfile.ZipFile(fp) as zf:
        members = zip_members(zf, os.path.basename(path))
        libs = [(LIB.fullmatch(n).group(1), i) for n, i in sorted(members.items()) if LIB.fullmatch(n)]
        extract = any(i.compress_type != zipfile.ZIP_STORED or data_offset(fp, i) % PAGE for _, i in libs)
    return libs, extract


def preextract_libs(writer):
    """extract the x86_64 libraries staged APKs need"""
    for dest in sorted(d for d in writer.written if d.endswith(".apk")):
        path = os.path.join(writer.out, dest)
        try:
            libs, extract = native_libs(path)
            if not extract:
                continue
            with zipfile.ZipFile(path) as zf:
                for name, info in libs:
                    with zf.open(info) as src:
                        writer.put(src, "%s/lib/x86_64/%s" % (os.path.dirname(dest), name), None,
                                   "%s!%s" % (dest, info.filename))
        except (zipfile.BadZipFile, zlib.error, EOFError) as e:
            raise Refused("bad-apk", "%s: %s" % (dest, e))
        log("pre-extracted %d x86_64 librar(ies) out of %s: compressed or not page-aligned" % (len(libs), dest))


def payload_files(d):
    """return the files below a payload directory"""
    out = []
    for top, dirs, files in os.walk(d):
        for name in dirs + files:
            full = os.path.join(top, name)
            st = os.lstat(full)
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
                raise Refused("unsafe-payload", "%s is not a plain file or directory" % os.path.relpath(full, d))
        out += [os.path.relpath(os.path.join(top, f), d) for f in files]
    return sorted(p for p in out if p != MANIFEST)


def write_manifest(d):
    """write a payload directory's manifest.tsv"""
    rows = []
    for rel in payload_files(d):
        full = os.path.join(d, rel)
        rows.append((rel, os.path.getsize(full), sha256_file(full)))
    with open(os.path.join(d, MANIFEST), "x") as f:
        os.fchmod(f.fileno(), 0o644)
        f.writelines("%s\t%d\t%s\n" % r for r in rows)
    return len(rows), sum(r[1] for r in rows)


def new_payload(out):
    """create an empty payload directory"""
    os.makedirs(out)
    os.chmod(out, 0o755)
    if os.listdir(out):
        raise Refused("bad-out", "%s is not empty" % out)
    return Writer(out)


def extract_zip(archive, take, out, adds=()):
    """extract a take list's members into a new payload directory"""
    entries = read_take_list(take)
    writer = new_payload(out)
    label = os.path.basename(archive)
    try:
        with zipfile.ZipFile(archive) as zf:
            take_from_zip(zf, entries, writer, label)
    except zipfile.BadZipFile as e:
        raise Refused("bad-archive", "%s: %s" % (label, e))
    for src, dest in adds:
        with open(src, "rb") as f:
            writer.put(f, dest, None, os.path.basename(src))
    preextract_libs(writer)
    return writer


def extract_file(path, dest, want, out):
    """copy a checked APK into a new payload directory"""
    writer = new_payload(out)
    with open(path, "rb") as f:
        writer.put(f, dest, want, os.path.basename(path))
    preextract_libs(writer)
    return writer


def verify_dir(d):
    """return the problems with a payload directory against its manifest.tsv"""
    d = os.path.realpath(d)
    mpath = os.path.join(d, MANIFEST)
    if not os.path.isfile(mpath) or os.path.islink(mpath):
        return ["no %s in %s" % (MANIFEST, d)]
    try:
        files = set(payload_files(d))
    except Refused as e:
        return [str(e)]
    problems, listed = [], set()
    with open(mpath, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 3 or not fields[1].isdigit() or not SHA.fullmatch(fields[2]):
                problems.append("%s:%d is not <relpath> <size> <sha256>" % (MANIFEST, n))
                continue
            rel, size, want = fields[0], int(fields[1]), fields[2]
            try:
                if safe_name(rel, MANIFEST) != rel:
                    raise Refused("unsafe-name", "%r is not a plain relative path" % rel)
                check_dest(rel)
            except Refused as e:
                problems.append("%s:%d: %s" % (MANIFEST, n, e))
                continue
            if rel in listed:
                problems.append("%s lists %s twice" % (MANIFEST, rel))
            listed.add(rel)
            if rel not in files:
                problems.append("%s is missing" % rel)
            elif os.path.getsize(os.path.join(d, rel)) != size:
                problems.append("%s is %d bytes, the manifest says %d" % (rel, os.path.getsize(os.path.join(d, rel)), size))
            elif sha256_file(os.path.join(d, rel)) != want:
                problems.append("%s does not match its sha256" % rel)
    problems += ["%s is not in the manifest" % rel for rel in sorted(files - listed)]
    if not listed and not problems:
        problems.append("%s lists nothing" % MANIFEST)
    return problems


def lp(buf, p):
    """return a u32-length-prefixed field of buf and the next offset"""
    n = struct.unpack_from("<I", buf, p)[0]
    if p + 4 + n > len(buf):
        raise ValueError("a length runs past its block")
    return buf[p + 4:p + 4 + n], p + 4 + n


def signer_certs(value):
    """return a v2 or v3 signature block's signer certificate sha256s"""
    signers, _ = lp(value, 0)
    certs, p = [], 0
    while p < len(signers):
        signer, p = lp(signers, p)
        signed, _ = lp(signer, 0)
        _, q = lp(signed, 0)
        certseq, _ = lp(signed, q)
        cert, _ = lp(certseq, 0)
        certs.append(hashlib.sha256(cert).hexdigest())
    return certs


def apk_signers(path):
    """return an APK's signer certificate sha256s by scheme"""
    if os.path.getsize(path) < 22:
        raise Refused("bad-apk", "%s is too short to be an APK" % path)
    with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
        eocd = m.rfind(b"PK\x05\x06", max(0, len(m) - 65557))
        if eocd < 0 or eocd + 22 > len(m):
            raise Refused("bad-apk", "%s has no zip end record" % path)
        cd = struct.unpack_from("<I", m, eocd + 16)[0]
        if cd < 32 or cd > eocd or m[cd - 16:cd] != b"APK Sig Block 42":
            return {}
        size = struct.unpack_from("<Q", m, cd - 24)[0]
        start = cd - size - 8
        if start < 0 or struct.unpack_from("<Q", m, start)[0] != size:
            raise Refused("bad-apk", "%s has a malformed signing block" % path)
        out, p, end = {}, start + 8, cd - 24
        try:
            while p + 12 <= end:
                n, pid = struct.unpack_from("<QI", m, p)
                if n < 4 or p + 8 + n > end:
                    raise ValueError("a pair runs past the signing block")
                if pid in (SIG_V2, SIG_V3, SIG_V31):
                    out[pid] = signer_certs(bytes(m[p + 12:p + 8 + n]))
                p += 8 + n
        except (ValueError, struct.error) as e:
            raise Refused("bad-apk", "%s: %s" % (path, e))
    return out


def axml_manifest(data):
    """return the package name and versionCode from a binary AndroidManifest.xml"""
    try:
        if struct.unpack_from("<H", data, 0)[0] != 0x0003:
            raise ValueError("not a binary XML document")
        strings, resids = [], []
        off, end = struct.unpack_from("<H", data, 2)[0], min(len(data), struct.unpack_from("<I", data, 4)[0])
        while off + 8 <= end:
            ctype, hsize, csize = struct.unpack_from("<HHI", data, off)
            if csize < 8 or off + csize > end:
                raise ValueError("a chunk runs past the document")
            if ctype == 0x0001:
                strings = string_pool(data, off, csize)
            elif ctype == 0x0180:
                resids = list(struct.unpack_from("<%dI" % ((csize - hsize) // 4), data, off + hsize))
            elif ctype == 0x0102 and strings[struct.unpack_from("<I", data, off + 20)[0]] == "manifest":
                start, size, count = struct.unpack_from("<HHH", data, off + 24)
                package = version = None
                for i in range(count):
                    _, name, raw, _, _, dtype, val = struct.unpack_from("<IIIHBBI", data, off + hsize + start + i * size)
                    rid = resids[name] if name < len(resids) else 0
                    if rid == VERSION_CODE_ATTR and dtype in (0x10, 0x11):
                        version = val
                    elif rid == 0 and strings[name] == "package" and raw < len(strings):
                        package = strings[raw]
                return package, version
            off += csize
    except (ValueError, IndexError, struct.error) as e:
        raise Refused("bad-apk", "AndroidManifest.xml: %s" % e)
    raise Refused("bad-apk", "AndroidManifest.xml has no <manifest> element")


def string_pool(data, off, csize):
    """return the strings of a binary XML string pool chunk"""
    hsize = struct.unpack_from("<H", data, off + 2)[0]
    count, _, flags, sstart, _ = struct.unpack_from("<IIIII", data, off + 8)
    if count * 4 > csize:
        raise ValueError("a string pool counts more strings than it holds")
    base, out = off + sstart, []
    for so in struct.unpack_from("<%dI" % count, data, off + hsize):
        p = base + so
        if flags & 0x100:
            for _ in range(2):
                n = data[p]
                p += 1
                if n & 0x80:
                    n = ((n & 0x7F) << 8) | data[p]
                    p += 1
            out.append(data[p:p + n].decode("utf-8", "replace"))
        else:
            n = struct.unpack_from("<H", data, p)[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7FFF) << 16) | struct.unpack_from("<H", data, p)[0]
                p += 2
            out.append(data[p:p + 2 * n].decode("utf-16-le", "replace"))
    return out


def apk_info(path):
    """return an APK's package, versionCode, signers and native library state"""
    try:
        with zipfile.ZipFile(path) as zf:
            members = zip_members(zf, os.path.basename(path))
            if "AndroidManifest.xml" not in members:
                raise Refused("bad-apk", "%s has no AndroidManifest.xml" % path)
            with zf.open(members["AndroidManifest.xml"]) as src:
                package, version = axml_manifest(read_capped(src, MAX_MANIFEST, "AndroidManifest.xml"))
    except (zipfile.BadZipFile, zlib.error, EOFError) as e:
        raise Refused("bad-apk", "%s: %s" % (path, e))
    signers = apk_signers(path)
    libs, extract = native_libs(path)
    return {
        "package": package or "",
        "version_code": "" if version is None else str(version),
        "signer_sha256": ",".join(sorted({c for certs in signers.values() for c in certs})),
        "libs": "none" if not libs else "extract" if extract else "stored",
    }


def gsf_id(d):
    """return the android_id in a gservices.db copy, or None"""
    db = os.path.join(d, "gservices.db")
    if not os.path.isfile(db):
        return None
    con = sqlite3.connect(db)
    try:
        con.execute("PRAGMA query_only = ON")
        row = con.execute("SELECT value FROM main WHERE name = 'android_id'").fetchone()
    except sqlite3.OperationalError:
        return None
    finally:
        con.close()
    if not row or not re.fullmatch(r"-?[0-9]{1,20}", str(row[0]).strip()):
        return None
    return int(str(row[0]).strip())


COMMON = "modules/core/Common/Common-LiteGapps-Addon-x86_64-16.0.zip"
FX_PERM_XML = (b'<?xml version="1.0" encoding="utf-8"?>\n<!-- a comment -->\n<permissions>\n'
               b'  <feature name="org.example.feature.EXPERIENCE"/>\n'
               b'  <permission name="android.permission.X"><group gid="net_admin"/></permission>\n'
               b'  <privapp-permissions package="org.example.gms">\n'
               b'    <permission name="android.permission.READ_LOGS"/>\n'
               b'    <deny-permission name="android.permission.Y"/>\n'
               b'    <permission name="android.permission.Z" extra="1"/>\n'
               b'  </privapp-permissions>\n</permissions>\n')
FX_CONF_XML = (b'<config><allow-in-power-save package="org.example.gms"/>'
               b'<allow-ignore-location-settings package="org.example.gms" attributionTag="*"/>'
               b'<unavailable-feature name="x"/><app-link package="org.ex ample"/></config>')


def sha256_bytes(b):
    """return the sha256 of bytes"""
    return hashlib.sha256(b).hexdigest()


def fx_zip(members, align=False):
    """return a synthetic zip of members"""
    buf = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(buf, "w") as zf:
            for m in members:
                i = zipfile.ZipInfo(m[0], (2026, 1, 1, 0, 0, 0))
                i.create_system = 3
                i.external_attr = (m[2] if len(m) > 2 else 0o100644) << 16
                i.compress_type = m[3] if len(m) > 3 else zipfile.ZIP_DEFLATED
                if align and i.compress_type == zipfile.ZIP_STORED:
                    pad = -(buf.tell() + 30 + len(m[0].encode()) + 4) % PAGE
                    i.extra = struct.pack("<HH", 0xD935, pad) + b"\0" * pad
                zf.writestr(i, m[1])
    return buf.getvalue()


def fx_txz(members):
    """return a synthetic tar.xz of files, specials and dirs"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:xz") as tf:
        for kind, body in members:
            t = tarfile.TarInfo(body if kind in ("link", "chr") else kind)
            if kind in ("link", "chr"):
                t.type = tarfile.SYMTYPE if kind == "link" else tarfile.CHRTYPE
                t.linkname = "/etc/passwd" if kind == "link" else ""
                tf.addfile(t)
            elif body is None:
                t.type = tarfile.DIRTYPE
                tf.addfile(t)
            else:
                t.size = len(body)
                tf.addfile(t, io.BytesIO(body))
    return buf.getvalue()


def fx_axml(package, version):
    """return a minimal binary AndroidManifest.xml naming a package and versionCode"""
    strs = ["versionCode", "package", "manifest", package]
    enc = b"".join(struct.pack("<H", len(s)) + s.encode("utf-16-le") + b"\0\0" for s in strs)
    enc += b"\0" * (-len(enc) % 4)
    offs, o = [], 0
    for s in strs:
        offs.append(o)
        o += 2 + 2 * len(s) + 2
    pool_h = 28 + 4 * len(strs)
    pool = struct.pack("<HHIIIIII", 1, 28, pool_h + len(enc), len(strs), 0, 0, pool_h, 0)
    pool += struct.pack("<%dI" % len(strs), *offs) + enc
    rmap = struct.pack("<HHI", 0x180, 8, 12) + struct.pack("<I", VERSION_CODE_ATTR)
    attrs = struct.pack("<IIIHBBI", 0xFFFFFFFF, 0, 0xFFFFFFFF, 8, 0, 0x10, version)
    attrs += struct.pack("<IIIHBBI", 0xFFFFFFFF, 1, 3, 8, 0, 0x03, 3)
    elem = struct.pack("<HHIII", 0x102, 16, 36 + len(attrs), 1, 0xFFFFFFFF)
    elem += struct.pack("<IIHHHHHH", 0xFFFFFFFF, 2, 20, 20, 2, 0, 0, 0) + attrs
    body = pool + rmap + elem
    return struct.pack("<HHI", 3, 8, 8 + len(body)) + body


def fx_signed(apk, cert):
    """return an APK whose v2 and v3 blocks name cert"""
    eocd = apk.rfind(b"PK\x05\x06")
    cd = struct.unpack_from("<I", apk, eocd + 16)[0]

    def p(b):
        """length-prefix b"""
        return struct.pack("<I", len(b)) + b
    value = p(p(p(p(b"") + p(p(cert)) + p(b"")) + p(b"") + p(b"")))
    pairs = b"".join(struct.pack("<QI", 4 + len(value), pid) + value for pid in (SIG_V2, SIG_V3))
    size = len(pairs) + 24
    block = struct.pack("<Q", size) + pairs + struct.pack("<Q", size) + b"APK Sig Block 42"
    out = bytearray(apk[:cd] + block + apk[cd:])
    struct.pack_into("<I", out, eocd + len(block) + 16, cd + len(block))
    return bytes(out)


def fx_apk(package="org.example.app", version=7, lib=None, compress=False, cert=b"synthetic-cert"):
    """return a synthetic signed APK, with an optional x86_64 library"""
    members = [("AndroidManifest.xml", fx_axml(package, version)), ("classes.dex", b"dex\n035\0" + package.encode())]
    if lib:
        members.append(("lib/x86_64/" + lib, b"\x7fELF" + b"\0" * 5000, 0o100644,
                        zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED))
    return fx_signed(fx_zip(members, align=True), cert)


def fx_litegapps(readme=b"synthetic\n"):
    """return a synthetic LiteGapps archive's members and take list rows"""
    gms, gsf = fx_apk("org.example.gms", 1), fx_apk("org.example.gsf", 2)
    vending = fx_apk("org.example.vending", 3, lib="libv.so", compress=True)
    root = "x86_64/36/system/"
    tar = fx_txz([("x86_64", None), ("x86_64/36", None),
                  (root + "product/priv-app/GmsCore/GmsCore.apk", gms),
                  (root + "system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk", gsf),
                  (root + "product/priv-app/Phonesky/Phonesky.apk", vending),
                  (root + "product/app/Extra/Extra.apk", b"not taken")])
    common = fx_zip([("customize.sh", b"#!/bin/sh\nexit 1\n", 0o100755),
                     ("system/product/etc/permissions/perm.xml", FX_PERM_XML),
                     ("system/product/etc/sysconfig/google.xml", FX_CONF_XML)])
    members = [("META-INF/com/google/android/update-binary", b"#!/sbin/sh\nexit 1\n", 0o100755),
               ("META-INF/", b"", 0o40755), ("files/files.tar.xz", tar), (COMMON, common), ("README.md", readme)]
    t = "files/files.tar.xz!" + root
    rows = [(t + "product/priv-app/GmsCore/GmsCore.apk", "priv-app/GmsCore/GmsCore.apk", sha256_bytes(gms)),
            (t + "system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
             "priv-app/GoogleServicesFramework/GoogleServicesFramework.apk", sha256_bytes(gsf)),
            (t + "product/priv-app/Phonesky/Phonesky.apk", "priv-app/Phonesky/Phonesky.apk", sha256_bytes(vending)),
            (COMMON + "!system/product/etc/permissions/perm.xml", "etc/permissions/gapps-perm.xml",
             sha256_bytes(FX_PERM_XML)),
            (COMMON + "!system/product/etc/sysconfig/google.xml", "etc/sysconfig/gapps-google.xml",
             sha256_bytes(FX_CONF_XML))]
    return members, rows


def write_take_list(path, rows):
    """write take list rows to a file"""
    with open(path, "w") as f:
        f.write("# member\tdest\tsha256\n" + "".join("%s\t%s\t%s\n" % r for r in rows))


def write_fixtures(d):
    """write the fetch tests' fixtures and print their pins"""
    os.makedirs(d, exist_ok=True)
    files = {"aurora.apk": fx_apk("com.aurora.store", 76, lib="libaurora.so", compress=True)}
    members, rows = fx_litegapps()
    files["litegapps.zip"] = fx_zip(members)
    files["litegapps-b.zip"] = fx_zip(fx_litegapps(b"another synthetic build\n")[0])
    write_take_list(os.path.join(d, "litegapps-a16.tsv"), rows)
    for name, body in files.items():
        with open(os.path.join(d, name), "wb") as f:
            f.write(body)
        signer = sha256_bytes(b"synthetic-cert") if name.endswith(".apk") else "-"
        print("%s %s %d %s" % (name, sha256_bytes(body), len(body), signer))


def selftest():
    """run the checks on synthetic fixtures in a scratch directory"""
    global MAX_MEMBER
    failed = []

    def check(name, cond):
        """print ok or FAIL for a check"""
        print("%s %s" % ("ok  " if cond else "FAIL", name))
        if not cond:
            failed.append(name)

    def refusal(fn, *args):
        """return the reason fn refuses with, or None"""
        try:
            fn(*args)
        except Refused as e:
            return e.reason
        return None

    good, take_rows = fx_litegapps()
    gms = fx_apk("org.example.gms", 1)
    work = tempfile.mkdtemp(prefix="store-payload-selftest-")
    count = [0]

    def run(members, rows=take_rows, adds=()):
        """extract a synthetic archive, returning its writer or refusal"""
        count[0] += 1
        d = os.path.join(work, str(count[0]))
        os.makedirs(d)
        with open(os.path.join(d, "a.zip"), "wb") as f:
            f.write(fx_zip(members))
        write_take_list(os.path.join(d, "take.tsv"), rows)
        try:
            return extract_zip(os.path.join(d, "a.zip"), os.path.join(d, "take.tsv"), os.path.join(d, "out"), adds)
        except Refused as e:
            return e.reason

    try:
        own = os.path.join(work, "own.xml")
        with open(own, "wb") as f:
            f.write(b'<permissions><privapp-permissions package="org.example.gms">'
                    b'<deny-permission name="android.permission.Q"/></privapp-permissions></permissions>')
        w = run(good, adds=[(own, "etc/permissions/gapps-own.xml")])
        ok = isinstance(w, Writer)
        check("a good archive extracts", ok)
        if ok:
            files = payload_files(w.out)
            check("only the listed members, the added file and compressed libraries are taken",
                  files == ["etc/permissions/gapps-own.xml", "etc/permissions/gapps-perm.xml",
                            "etc/sysconfig/gapps-google.xml", "priv-app/GmsCore/GmsCore.apk",
                            "priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
                            "priv-app/Phonesky/Phonesky.apk", "priv-app/Phonesky/lib/x86_64/libv.so"])
            body = open(os.path.join(w.out, "etc/permissions/gapps-perm.xml")).read()
            check("the allowlist keeps privapp permission and deny-permission",
                  '<permission name="android.permission.READ_LOGS"/>' in body
                  and '<deny-permission name="android.permission.Y"/>' in body)
            check("the allowlist drops <feature>, a gid <permission> and an unknown attribute",
                  "feature" not in body and "gid" not in body and "android.permission.Z" not in body)
            drops = "\n".join(w.dropped)
            check("every dropped element is reported",
                  all(t in drops for t in ("<feature", "<permission name=\"android.permission.X\"",
                                           "android.permission.Z", "<allow-ignore-location-settings",
                                           "<unavailable-feature", "org.ex ample")))
            conf = open(os.path.join(w.out, "etc/sysconfig/gapps-google.xml")).read()
            check("a sysconfig allowlist entry survives", '<allow-in-power-save package="org.example.gms"/>' in conf)
            check("the added file passes the allowlist", "android.permission.Q" in
                  open(os.path.join(w.out, "etc/permissions/gapps-own.xml")).read())
            n, _ = write_manifest(w.out)
            check("manifest lists every file", n == 7)
            check("verify passes a fresh payload", verify_dir(w.out) == [])
            with open(os.path.join(w.out, "priv-app/GmsCore/GmsCore.apk"), "r+b") as f:
                f.seek(100)
                f.write(b"X")
            check("verify fails a changed file", any("sha256" in p for p in verify_dir(w.out)))
            with open(os.path.join(w.out, "priv-app/GmsCore/extra.apk"), "w") as f:
                f.write("x")
            check("verify fails a file not in the manifest", any("not in the manifest" in p for p in verify_dir(w.out)))
            os.unlink(os.path.join(w.out, "priv-app/GmsCore/extra.apk"))
            os.symlink("/etc/passwd", os.path.join(w.out, "etc/permissions/gapps-link.xml"))
            check("verify fails a symlink in the payload", any("not a plain file" in p for p in verify_dir(w.out)))
        check("a member that does not match its sha256 is refused",
              run(good, [(take_rows[0][0], take_rows[0][1], "0" * 64)]) == "member-sha256-mismatch")
        check("a symlink member is refused",
              run(good + [("bin/sh", b"/system/bin/sh", 0o120777)]) == "unsafe-member")
        check("a member named ../x is refused", run(good + [("../x", b"x")]) == "unsafe-name")
        check("an absolute member is refused", run(good + [("/etc/x", b"x")]) == "unsafe-name")
        check("a duplicate member is refused", run(good + [("files/files.tar.xz", b"x")]) == "duplicate-member")
        saved, MAX_MEMBER = MAX_MEMBER, 1 << 16
        try:
            check("an oversize member is refused", run(good + [("big.bin", b"\0" * (1 << 17))]) == "oversize-member")
        finally:
            MAX_MEMBER = saved
        bad_nested = fx_zip([("system/product/etc/permissions/perm.xml", FX_PERM_XML), ("system/x", b"/", 0o120777)])
        check("a symlink inside a nested zip is refused",
              run([m for m in good if m[0] != COMMON] + [(COMMON, bad_nested)]) == "unsafe-member")
        for kind in ("link", "chr"):
            t = fx_txz([("x86_64/36/system/product/priv-app/GmsCore/GmsCore.apk", gms), (kind, "x86_64/36/odd")])
            check("a %s member in the tar is refused" % kind, run([("files/files.tar.xz", t)]) == "unsafe-member")
        t = fx_txz([("x86_64/36/system/product/priv-app/GmsCore/GmsCore.apk", gms), ("../../escape", b"x")])
        check("a tar member named ../ is refused", run([("files/files.tar.xz", t)]) == "unsafe-name")
        check("a member the archive lacks is refused",
              run(good, [("files/files.tar.xz!x86_64/36/nope.apk", "priv-app/Nope/Nope.apk", "0" * 64)])
              == "missing-member")
        for dest in ("bin/sh", "etc/permissions/privapp.xml", "build.prop", "priv-app/Foo/../../x.apk"):
            check("destination %s is refused" % dest, run(good, [(take_rows[0][0], dest, take_rows[0][2])]) == "bad-dest")
        doc = b'<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><permissions/>'
        bad_doc = fx_zip([("system/product/etc/permissions/perm.xml", doc)])
        check("an XML with a DOCTYPE is refused",
              run([(COMMON, bad_doc)], [take_rows[3][:2] + (sha256_bytes(doc),)]) == "xml-doctype")
        info = None
        with open(os.path.join(work, "app.apk"), "wb") as f:
            f.write(fx_apk(version=76, lib="libz.so", cert=b"pinned"))
        try:
            info = apk_info(os.path.join(work, "app.apk"))
        except Refused as e:
            print("       %s" % e)
        check("apk-info reads package, versionCode, signer and stored libraries",
              info == {"package": "org.example.app", "version_code": "76", "signer_sha256": sha256_bytes(b"pinned"),
                       "libs": "stored"})
        w = extract_file(os.path.join(work, "app.apk"), "app/App/App.apk", sha256_file(os.path.join(work, "app.apk")),
                         os.path.join(work, "single"))
        check("a page-aligned stored library stays in the APK", payload_files(w.out) == ["app/App/App.apk"])
        with open(os.path.join(work, "zapp.apk"), "wb") as f:
            f.write(fx_apk(lib="libz.so", compress=True))
        check("apk-info sees a compressed library", apk_info(os.path.join(work, "zapp.apk"))["libs"] == "extract")
        w = extract_file(os.path.join(work, "zapp.apk"), "app/App/App.apk", None, os.path.join(work, "zsingle"))
        check("a compressed library is pre-extracted beside the APK",
              payload_files(w.out) == ["app/App/App.apk", "app/App/lib/x86_64/libz.so"])
        check("a single file that does not match its sha256 is refused",
              refusal(extract_file, os.path.join(work, "app.apk"), "app/App/App.apk", "0" * 64,
                      os.path.join(work, "bad-single")) == "member-sha256-mismatch")
        check("verify fails a directory with no manifest", verify_dir(work) != [])
        gdir = os.path.join(work, "gsf")
        os.makedirs(gdir)
        check("gsf-id is absent with no gservices.db", gsf_id(gdir) is None)
        con = sqlite3.connect(os.path.join(gdir, "gservices.db"))
        con.execute("CREATE TABLE main (name TEXT PRIMARY KEY, value TEXT)")
        con.execute("INSERT INTO main VALUES ('digest', 'x')")
        con.commit()
        check("gsf-id is absent with no android_id row", gsf_id(gdir) is None)
        con.execute("INSERT INTO main VALUES ('android_id', '4012345678901234567')")
        con.commit()
        con.close()
        check("gsf-id reads the android_id", gsf_id(gdir) == 4012345678901234567)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("%d failed" % len(failed) if failed else "all passed")
    return 1 if failed else 0


def main(argv):
    """run a subcommand"""
    if argv == ["--selftest"]:
        return selftest()
    ap = argparse.ArgumentParser(prog="store_payload.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("extract", help="take a payload out of an archive (--zip) or copy one APK (--file)")
    ex.add_argument("--zip")
    ex.add_argument("--take")
    ex.add_argument("--add", action="append", default=[], metavar="SRC=DEST")
    ex.add_argument("--file")
    ex.add_argument("--dest")
    ex.add_argument("--sha256")
    ex.add_argument("--out", required=True)
    sub.add_parser("verify").add_argument("dir")
    sub.add_parser("gsf-id").add_argument("dir")
    sub.add_parser("apk-info").add_argument("apk")
    sub.add_parser("fixtures", help="write synthetic test fixtures").add_argument("dir")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "extract":
            if a.zip and a.take and not a.file:
                adds = [tuple(x.split("=", 1)) for x in a.add]
                if any(len(x) != 2 for x in adds):
                    ap.error("--add takes SRC=DEST")
                w = extract_zip(a.zip, a.take, a.out, adds)
            elif a.file and a.dest and a.sha256 and not (a.zip or a.take or a.add):
                w = extract_file(a.file, a.dest, a.sha256, a.out)
            else:
                ap.error("extract takes --zip and --take, or --file, --dest and --sha256")
            n, size = write_manifest(a.out)
            if any(d.endswith(".xml") for d in w.written):
                log("%d element(s) dropped by the XML allowlist" % len(w.dropped))
            print("RHIZO_PAYLOAD_OK files=%d bytes=%d" % (n, size))
            return 0
        if a.cmd == "verify":
            problems = verify_dir(a.dir)
            for p in problems:
                print("BAD: %s" % p)
            if not problems:
                print("ok %s" % os.path.realpath(a.dir))
            return 1 if problems else 0
        if a.cmd == "gsf-id":
            n = gsf_id(a.dir)
            if n is None:
                log("no android_id in %s/gservices.db" % a.dir)
                return 2
            print("%d %x" % (n, n & 0xFFFFFFFFFFFFFFFF))
            return 0
        if a.cmd == "apk-info":
            info = apk_info(a.apk)
            print(" ".join("%s=%s" % kv for kv in info.items()))
            return 0
        if a.cmd == "fixtures":
            write_fixtures(a.dir)
            return 0
    except Refused as e:
        log("REFUSED: %s" % e)
        print("RHIZO_PAYLOAD_REFUSED reason=%s" % e.reason)
        return 3
    except (OSError, sqlite3.Error) as e:
        log("FAILED: %s" % e)
        print("RHIZO_PAYLOAD_FAILED reason=io")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
