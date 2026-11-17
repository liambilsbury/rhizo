#!/usr/bin/env python3
import collections
import fnmatch
import glob
import hashlib
import importlib.util
import os
import subprocess
import sys

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "test", "system", "run")))

HERE = os.path.dirname(os.path.abspath(__file__))

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VAR_DIR = os.path.join(ROOT, "var")
TABLE = os.path.join(HERE, "artifacts.tsv")
SHARE = os.path.join(VAR_DIR, "share")
AFFECTS = os.path.join(ROOT, "test", "system", "run", "affects.tsv")
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
DEB_DEFAULT_DIR = os.path.join(VAR_DIR, "debs")
DEB_TEST = "installer.sh"


class InputsChangedError(Exception):
    """exception for a deb whose routed inputs changed during dpkg-buildpackage"""


Entry = collections.namedtuple("Entry", "name build sources set after")


def test_table(path):
    """return the path of the test artifact table"""
    return os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(path))), "test", "artifacts.tsv")


def entries(path=TABLE, text=None):
    """return the rows of the artifact and test tables"""
    if text is None:
        with open(path) as f:
            text = f.read()
        tests = test_table(path)
        if os.path.exists(tests):
            with open(tests) as f:
                text += "\n" + f.read()
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) != 5:
            raise ValueError("artifacts.tsv row has %d tab-separated "
                             "columns, expected 5 (%r)" % (len(parts), line))
        name, build, sources, kind, after = parts
        if kind not in ("payload", "test"):
            raise ValueError("artifacts.tsv row %s has set %r, expected payload or test" % (name, kind))
        out.append(Entry(name, build, sources.split(), kind, [] if after == "-" else after.split()))
    return out


def rows(path=TABLE):
    """return each row as a name, build command and sources tuple"""
    return [(e.name, e.build, e.sources) for e in entries(path)]


def as_entries(table=None):
    """return a table's rows as entries"""
    if table is None:
        return entries()
    return [r if isinstance(r, Entry) else Entry(r[0], r[1], list(r[2]), "payload", []) for r in table]


def source_files(sources, root=ROOT):
    """return the sorted files under the paths"""
    found = []
    for rel in sources:
        path = os.path.join(root, rel)
        if os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames[:] = sorted(d for d in dirnames
                                     if d not in (".git", "__pycache__", "build", "out"))
                for fn in sorted(filenames):
                    found.append(os.path.join(dirpath, fn))
        elif os.path.exists(path):
            found.append(path)
        else:
            found.append(path)
    return sorted(set(found))


def source_hash(sources, root=ROOT):
    """return the sha256 of the relative paths and contents of the source files"""
    h = hashlib.sha256()
    for path in source_files(sources, root):
        h.update(os.path.relpath(path, root).encode("utf-8"))
        h.update(b"\0")
        try:
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 16), b""):
                    h.update(chunk)
        except OSError:
            h.update(b"<absent>")
        h.update(b"\0")
    return h.hexdigest()


def artifact_path(name, share=SHARE, root=ROOT):
    """return the artifact path of a row"""
    if name.startswith("toolchain/"):
        return os.path.join(root, name)
    return os.path.join(share, name)


def product_path(name):
    """return a row's artifact path from the repo root"""
    return name if name.startswith("toolchain/") else "var/share/" + name


def stamp_path(name, share=SHARE, root=ROOT):
    """return the stamp file path for an artifact"""
    return artifact_path(name, share, root) + ".srchash"


def hashed_after(table):
    """return a map of each row to the after-rows another build command builds"""
    build = {e.name: e.build for e in table}
    return {e.name: [a for a in e.after if a in build and build[a] != e.build] for e in table}


def manifest_after(name, root=ROOT):
    """return hashed_after() of tools/build/artifacts.tsv for row name"""
    path = os.path.join(root, "tools", "build", "artifacts.tsv")
    if not os.path.exists(path):
        return []
    return hashed_after(entries(path)).get(name, [])


def row_hash(sources, after=(), share=SHARE, root=ROOT):
    """return a row's stamp value"""
    own = source_hash(sources, root)
    if not after:
        return own
    h = hashlib.sha256(own.encode())
    for a in sorted(after):
        h.update(b"\0" + a.encode("utf-8") + b"\0")
        try:
            with open(stamp_path(a, share, root)) as f:
                h.update(f.read().strip().encode())
        except OSError:
            h.update(b"<absent>")
    return h.hexdigest()


def verdict(name, build, sources, require, share=SHARE, root=ROOT, after=None):
    """return the stamp finding for an artifact, else None"""
    artifact = artifact_path(name, share, root)
    if not os.path.exists(artifact):
        if not require:
            return None
        return ("%s is not staged by %s" % (name, build))
    stamp = stamp_path(name, share, root)
    if not os.path.exists(stamp):
        return ("%s has no source stamp from "
                "%s" % (name, build))
    with open(stamp) as f:
        recorded = f.read().strip()
    current = row_hash(sources, manifest_after(name, root) if after is None else after, share, root)
    if recorded != current:
        return ("%s was built from different sources or after-rows "
                "(stamped %s, current %s) by %s"
                % (name, recorded[:12], current[:12], build))
    return None


def check(require_names=(), table=None, share=SHARE, root=ROOT):
    """return the stamp findings for the table rows"""
    findings = []
    table = as_entries(table)
    after = hashed_after(table)
    for name, build, sources, _set, _after in table:
        if require_names and name not in require_names:
            continue
        bad = verdict(name, build, sources, bool(require_names), share, root, after[name])
        if bad:
            findings.append(bad)
    if require_names:
        known = {e.name for e in table}
        for name in require_names:
            if name not in known:
                findings.append("%s has no row in "
                                "artifacts.tsv" % name)
    return findings


def changed(table=None, share=SHARE, root=ROOT):
    """return the stamps make must rebuild, from the repo root"""
    owed = set()
    table = as_entries(table)
    after = hashed_after(table)
    for name, _build, sources, _set, _after in table:
        stamp = stamp_path(name, share, root)
        ok = os.path.exists(artifact_path(name, share, root)) and os.path.exists(stamp)
        if ok:
            with open(stamp) as f:
                ok = f.read().strip() == row_hash(sources, after[name], share, root)
        if not ok:
            owed.add(name)
    grew = True
    while grew:
        grew = False
        for e in table:
            if e.name not in owed and owed.intersection(e.after):
                owed.add(e.name)
                grew = True
    return [os.path.relpath(stamp_path(e.name, share, root), root) for e in table if e.name in owed]


BUILD_TREES = {"tools/build/graphics/gpu-driver.sh": ("mesa-src",)}


def pending_path(name, root=ROOT):
    """return the path of a row's pre-build hash"""
    return os.path.join(root, "var", "build-pending", name + ".srchash")


def outside_checkout(names, share=SHARE, root=ROOT, table=None):
    """return a finding for each row whose paths resolve outside the checkout"""
    top = os.path.realpath(root)
    scripts = {e.name: build_script(e.build) for e in as_entries(table)}
    refused = []
    for name in names:
        trees = [os.path.join(root, t) for t in BUILD_TREES.get(scripts.get(name, ""), ())]
        for path in [artifact_path(name, share, root), stamp_path(name, share, root), pending_path(name, root)] + trees:
            real = os.path.realpath(path)
            if real.startswith(top + os.sep):
                continue
            rel = os.path.relpath(path, root)
            parts = rel.split(os.sep)
            link = next((os.path.join(*parts[:i]) for i in range(1, len(parts) + 1)
                         if os.path.islink(os.path.join(root, *parts[:i]))), rel)
            target = os.path.realpath(os.path.join(root, link))
            refused.append("row %s path %s resolves to %s outside the checkout "
                           "through the link %s -> %s" % (name, rel, real, link, target))
            break
    return refused


def hasher(table, share, root):
    """return a function giving each row's current hash"""
    table = as_entries(table)
    sources = {e.name: e.sources for e in table}
    after = hashed_after(table)
    return lambda name: row_hash(sources[name], after[name], share, root)


def record_pending(names, table=None, share=SHARE, root=ROOT):
    """write each row hash to var/build-pending and delete the row stamp"""
    current = hasher(table, share, root)
    for name in names:
        path = pending_path(name, root)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(current(name) + "\n")
        try:
            os.remove(stamp_path(name, share, root))
        except FileNotFoundError:
            pass


def write_stamps(names, done=False, table=None, share=SHARE, root=ROOT):
    """write each row's stamp and return the refusals"""
    hash_of = hasher(table, share, root)
    refused = []
    for name in names:
        stamp = stamp_path(name, share, root)
        pending = pending_path(name, root)
        current = hash_of(name)
        want = current
        if os.path.exists(pending):
            with open(pending) as f:
                want = f.read().strip()
        if want != current:
            refused.append("%s sources changed during the build (pre-build %s, current %s)"
                           % (name, want[:12], current[:12]))
            try:
                os.remove(stamp)
            except FileNotFoundError:
                pass
        else:
            os.makedirs(os.path.dirname(stamp), exist_ok=True)
            with open(stamp, "w") as f:
                f.write(want + "\n")
        if done and os.path.exists(pending):
            os.remove(pending)
    return refused


def build_script(build):
    """return the script path from a build command"""
    return build.split()[0]



def is_rhizo_deb(deb):
    """return whether the basename of deb matches rhizo_*.deb"""
    return fnmatch.fnmatch(os.path.basename(deb), "rhizo_*.deb")


def deb_stamp_path(deb):
    """return the stamp file path for a .deb"""
    return deb + ".inputs"


def deb_dir():
    """return RHIZO_DEB_DIR or var/debs"""
    return os.environ.get("RHIZO_DEB_DIR") or DEB_DEFAULT_DIR


def find_deb(directory=None):
    """return the last sorted rhizo amd64 deb"""
    cands = sorted(glob.glob(os.path.join(directory or deb_dir(), "rhizo_*_amd64.deb")))
    return cands[-1] if cands else None


def tracked_files(root, include_untracked=True):
    """return the git-listed files in a root"""
    args = ["git", "ls-files", "-z", "-c"]
    if include_untracked:
        args += ["-o", "--exclude-standard"]
    out = subprocess.run(args, cwd=root, capture_output=True, env=GIT_ENV)
    if out.returncode != 0:
        raise RuntimeError("git ls-files failed in %s with exit status %d (%s)"
                            % (root, out.returncode,
                               out.stderr.decode(errors="replace").strip()))
    return [p for p in out.stdout.decode().split("\0") if p]


def git_head(root):
    """return the current git commit of a folder"""
    out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root,
                         capture_output=True, text=True, env=GIT_ENV)
    if out.returncode != 0:
        raise RuntimeError("git rev-parse HEAD failed in %s with exit status %d (%s)"
                            % (root, out.returncode, out.stderr.strip()))
    return out.stdout.strip()


def sha256_file(path):
    """return the sha256 of a file"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def deb_input_digest(root, affects_tsv=None, path_is_input=None, tracked=None):
    """return the sha256 digest of the routed inputs"""
    affects_tsv = affects_tsv or AFFECTS
    if tracked is None:
        tracked = tracked_files(root)
    if os.path.exists(affects_tsv):
        import affects
        rows = affects.load_affects(affects_tsv)
        tracked = [p for p in tracked if (path_is_input or affects.path_is_input)(p, DEB_TEST, rows)]
    h = hashlib.sha256()
    for rel in sorted(tracked):
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        try:
            with open(os.path.join(root, rel), "rb") as f:
                h.update(f.read())
        except OSError:
            h.update(b"<absent>")
        h.update(b"\0")
    return h.hexdigest()


def read_stamp(path):
    """read a stamp file into a dict"""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            k, v = line.split("\t", 1)
            out[k] = v
    return out


def deb_stamp(deb, root=ROOT, affects_tsv=None, path_is_input=None, tracked=None,
              expect_inputs=None):
    """write the stamp file for a deb"""
    digest = deb_input_digest(root, affects_tsv, path_is_input, tracked)
    if expect_inputs is not None and expect_inputs != digest:
        raise InputsChangedError(
            "%s routed inputs changed during dpkg-buildpackage (pre-build %s, "
            "post-build %s)"
            % (os.path.basename(deb), expect_inputs[:12], digest[:12]))
    with open(deb_stamp_path(deb), "w") as f:
        f.write("sha256\t%s\n" % sha256_file(deb))
        f.write("commit\t%s\n" % git_head(root))
        f.write("inputs\t%s\n" % digest)


def deb_require(deb, root=ROOT, affects_tsv=None, path_is_input=None,
                tracked=None, check_sha=True):
    """return the deb stamp finding, else None"""
    stamp = deb_stamp_path(deb)
    if not os.path.exists(stamp):
        return "no stamp"
    recorded = read_stamp(stamp)
    if check_sha and recorded.get("sha256") != sha256_file(deb):
        return "not the stamped package"
    try:
        current = deb_input_digest(root, affects_tsv, path_is_input, tracked)
    except RuntimeError as e:
        return "%s" % e
    if recorded.get("inputs") != current:
        return "inputs changed since the build at commit %s" % recorded.get("commit", "unknown")
    return None


def selftest():
    """check the stamp table and the stamp checks"""
    import shutil
    import tempfile
    n = 0
    table = rows()
    assert table, "rows() != []"
    n += 1
    for name, build, sources in table:
        assert os.path.exists(os.path.join(ROOT, build_script(build))), \
            "row %s build script exists (%s)" % (name, build)
        for rel in sources:
            assert os.path.exists(os.path.join(ROOT, rel)), \
                "row %s source exists (%s)" % (name, rel)
    n += 1
    for bad_text, why in (("a\tb.sh\tsrc\n", "expected 5"),
                          ("a\tb.sh\tsrc\tship\t-\n", "expected payload or test")):
        try:
            entries(text=bad_text)
            raise AssertionError("entries(%r) raises ValueError" % bad_text)
        except ValueError as e:
            assert why in str(e), e
    n += 1
    e = entries(text="t/x\tb.sh --flag\tsrc lib\ttest\ta b\n")[0]
    assert (e.name, e.build, e.sources, e.set, e.after) == ("t/x", "b.sh --flag", ["src", "lib"], "test", ["a", "b"]), e
    assert entries(text="t/x\tb.sh\tsrc\tpayload\t-\n")[0].after == []
    n += 1
    tmp = tempfile.mkdtemp()
    try:
        table = os.path.join(tmp, "tools", "build", "artifacts.tsv")
        os.makedirs(os.path.dirname(table))
        os.makedirs(os.path.join(tmp, "test"))
        open(table, "w").write("p\tb.sh\tsrc\tpayload\t-\n")
        assert [e.name for e in entries(table)] == ["p"], "entries(table) == [p] without a test table"
        open(test_table(table), "w").write("t\tt.sh\tsrc\ttest\tp\n")
        assert [(e.name, e.set) for e in entries(table)] == [("p", "payload"), ("t", "test")], "entries(table) == [p payload, t test]"
    finally:
        shutil.rmtree(tmp)
    n += 1
    tmp = tempfile.mkdtemp()
    try:
        root = os.path.join(tmp, "root")
        share = os.path.join(tmp, "share")
        os.makedirs(os.path.join(root, "src"))
        os.makedirs(share)
        srcfile = os.path.join(root, "src", "a.c")
        open(srcfile, "w").write("one\n")
        fixture = [("art", "tools/build-art.sh", ["src"])]
        assert check(table=fixture, share=share, root=root) == []
        n += 1
        out = check(require_names={"art"}, table=fixture, share=share, root=root)
        assert len(out) == 1 and "not staged" in out[0], out
        n += 1
        open(os.path.join(share, "art"), "w").write("built\n")
        out = check(table=fixture, share=share, root=root)
        assert len(out) == 1 and "no source stamp" in out[0], out
        n += 1
        open(stamp_path("art", share), "w").write(source_hash(["src"], root))
        assert check(table=fixture, share=share, root=root) == []
        n += 1
        open(srcfile, "w").write("two\n")
        out = check(table=fixture, share=share, root=root)
        assert len(out) == 1 and "different sources" in out[0] and "build-art.sh" in out[0], out
        n += 1
        open(srcfile, "w").write("one\n")
        open(stamp_path("art", share), "w").write(source_hash(["src"], root))
        os.remove(srcfile)
        out = check(table=fixture, share=share, root=root)
        assert len(out) == 1 and "different sources" in out[0], out
        n += 1
        open(srcfile, "w").write("one\n")
        open(stamp_path("art", share, root), "w").write(source_hash(["src"], root))
        assert changed(table=fixture, share=share, root=root) == [], "changed() == [] for a matching stamp"
        n += 1
        open(srcfile, "w").write("three\n")
        assert changed(table=fixture, share=share, root=root) == [os.path.relpath(stamp_path("art", share), root)]
        n += 1
        tc = [("toolchain/gen", "tools/build/toolchain/regen-aidl-glue.sh", ["src"])]
        assert stamp_path("toolchain/gen", share, root) == os.path.join(root, "toolchain", "gen.srchash")
        assert changed(table=tc, share=share, root=root) == ["toolchain/gen.srchash"]
        assert product_path("toolchain/gen") == "toolchain/gen" and product_path("a/b") == "var/share/a/b"
        n += 1
        out = check(require_names={"nope"}, table=fixture, share=share, root=root)
        assert len(out) == 1 and "no row in artifacts.tsv" in out[0], out
        n += 1
        art_stamp = stamp_path("art", share, root)
        art_pending = pending_path("art", root)
        open(srcfile, "w").write("one\n")
        assert write_stamps(["art"], table=fixture, share=share, root=root) == []
        before = source_hash(["src"], root)
        record_pending(["art"], table=fixture, share=share, root=root)
        assert not os.path.exists(art_stamp), "record_pending() deletes the art stamp"
        assert open(art_pending).read().strip() == before, "record_pending() writes the pre-build hash"
        assert not os.path.abspath(art_pending).startswith(os.path.abspath(share) + os.sep), \
            "pending_path(art) is outside share"
        assert changed(table=fixture, share=share, root=root) == [os.path.relpath(art_stamp, root)]
        n += 1
        assert write_stamps(["art"], table=fixture, share=share, root=root) == []
        assert open(art_stamp).read().strip() == before and os.path.exists(art_pending), \
            "write_stamps([art]) stamp == pre-build hash and art_pending exists"
        n += 1
        assert write_stamps(["art"], done=True, table=fixture, share=share, root=root) == []
        assert open(art_stamp).read().strip() == before and not os.path.exists(art_pending), \
            "write_stamps([art], done=True) stamp == pre-build hash and art_pending is deleted"
        n += 1
        record_pending(["art"], table=fixture, share=share, root=root)
        assert write_stamps(["art"], table=fixture, share=share, root=root) == []
        open(srcfile, "w").write("edited mid-build\n")
        got = write_stamps(["art"], done=True, table=fixture, share=share, root=root)
        assert len(got) == 1 and "art" in got[0] and "sources changed during the build" in got[0], got
        assert not os.path.exists(art_stamp), "write_stamps([art], done=True) after an edit deletes art_stamp"
        assert not os.path.exists(art_pending), "write_stamps([art], done=True) deletes art_pending"
        assert changed(table=fixture, share=share, root=root) == [os.path.relpath(art_stamp, root)]
        n += 1
        record_pending(["art"], table=fixture, share=share, root=root)
        open(srcfile, "w").write("edited again\n")
        got = write_stamps(["art"], table=fixture, share=share, root=root)
        assert len(got) == 1 and "art" in got[0], got
        assert not os.path.exists(art_stamp) and os.path.exists(art_pending), \
            "write_stamps([art]) after an edit deletes art_stamp and art_pending exists"
        n += 1
        os.remove(art_pending)
        assert write_stamps(["art"], table=fixture, share=share, root=root) == []
        assert open(art_stamp).read().strip() == source_hash(["src"], root), \
            "write_stamps([art]) without art_pending stamp == source_hash([src])"
        n += 1

        def entry(name, build, sources, after=()):
            """return a payload row"""
            return Entry(name, build, sources, "payload", list(after))

        def rel(name):
            """return the stamp path relative to the test root"""
            return os.path.relpath(stamp_path(name, share, root), root)

        for name in ("dsrc", "xsrc", "ysrc", "pqsrc"):
            open(os.path.join(root, name), "w").write(name + " one\n")
        for name in ("dep", "x", "y", "p", "q"):
            open(os.path.join(share, name), "w").write("built\n")
        chain = [entry("dep", "tools/build-dep.sh", ["dsrc"]),
                 entry("x", "tools/build-x.sh", ["xsrc"], ["dep", ".rhizo-inputs.tsv"]),
                 entry("y", "tools/build-y.sh", ["ysrc"], ["x"])]
        for name in ("dep", "x", "y"):
            assert write_stamps([name], table=chain, share=share, root=root) == []
        assert changed(table=chain, share=share, root=root) == [], "changed(chain) == [] after write_stamps in order"
        assert check(table=chain, share=share, root=root) == []
        assert open(stamp_path("dep", share, root)).read().strip() == source_hash(["dsrc"], root), \
            "dep stamp == source_hash([dsrc])"
        assert open(stamp_path("x", share, root)).read().strip() != source_hash(["xsrc"], root), \
            "x stamp != source_hash([xsrc])"
        n += 1
        open(os.path.join(root, "dsrc"), "w").write("dsrc two\n")
        assert changed(table=chain, share=share, root=root) == [rel("dep"), rel("x"), rel("y")], \
            "changed(chain) == dep x y after a write to dsrc (%s)" \
            % changed(table=chain, share=share, root=root)
        got = check(table=chain, share=share, root=root)
        assert len(got) == 1 and got[0].startswith("dep "), got
        n += 1
        assert write_stamps(["dep"], table=chain, share=share, root=root) == []
        assert changed(table=chain, share=share, root=root) == [rel("x"), rel("y")], \
            "changed(chain) == x y after write_stamps([dep]) (%s)" \
            % changed(table=chain, share=share, root=root)
        got = check(table=chain, share=share, root=root)
        assert len(got) == 1 and got[0].startswith("x "), got
        n += 1
        group = [entry("p", "tools/build-pq.sh", ["pqsrc"]), entry("q", "tools/build-pq.sh", ["pqsrc"], ["p"])]
        record_pending(["p", "q"], table=group, share=share, root=root)
        assert write_stamps(["p", "q"], done=True, table=group, share=share, root=root) == [], \
            "write_stamps([p, q], done=True) == [] for p and q of one build command"
        assert changed(table=group, share=share, root=root) == []
        n += 1
        assert outside_checkout(["art", "toolchain/gen"], os.path.join(root, "var", "share"), root) == [], \
            "outside_checkout([art, toolchain/gen]) == [] in root"
        other = os.path.join(tmp, "other")
        wt = os.path.join(tmp, "wt")
        for d in ("toolchain", "var/build-pending", "var/share"):
            os.makedirs(os.path.join(other, d))
        os.makedirs(os.path.join(wt, "var", "share"))
        os.symlink(os.path.join(other, "toolchain"), os.path.join(wt, "toolchain"))
        wt_share = os.path.join(wt, "var", "share")
        got = outside_checkout(["toolchain/gen"], wt_share, wt)
        assert len(got) == 1 and "toolchain/gen resolves to" in got[0] and "the link toolchain -> " + os.path.join(other, "toolchain") in got[0] \
            and got[0].endswith("the link toolchain -> %s" % os.path.join(other, "toolchain")), \
            "outside_checkout([toolchain/gen]) has the link toolchain -> other/toolchain (%s)" % got
        assert outside_checkout(["art"], wt_share, wt) == [], "outside_checkout([art]) == [] in wt"
        os.symlink(os.path.join(other, "var", "build-pending"), os.path.join(wt, "var", "build-pending"))
        got = outside_checkout(["art"], wt_share, wt)
        assert len(got) == 1 and "var/build-pending/art.srchash" in got[0] and "the link var/build-pending -> " in got[0], \
            "outside_checkout([art]) has the link var/build-pending (%s)" % got
        n += 1
        drv = [entry("drv", "tools/build/graphics/gpu-driver.sh fixture", ["drvsrc"])]
        os.makedirs(os.path.join(other, "mesa-src", "build-android-fixture"))
        os.makedirs(os.path.join(root, "mesa-src"))
        assert outside_checkout(["drv"], os.path.join(root, "var", "share"), root, table=drv) == [], \
            "outside_checkout([drv]) == [] in root"
        os.symlink(os.path.join(other, "mesa-src"), os.path.join(wt, "mesa-src"))
        os.rename(os.path.join(wt, "var", "build-pending"), os.path.join(wt, "var", "build-pending.link"))
        os.makedirs(os.path.join(wt, "var", "build-pending"))
        got = outside_checkout(["drv"], wt_share, wt, table=drv)
        assert len(got) == 1 and "row drv path mesa-src resolves to " in got[0] \
            and got[0].endswith("the link mesa-src -> %s" % os.path.join(other, "mesa-src")), \
            "outside_checkout([drv]) has the link mesa-src -> other/mesa-src (%s)" % got
        assert outside_checkout(["art"], wt_share, wt, table=drv) == [], \
            "outside_checkout([art], table=drv) == [] in wt"
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("ok stamps.py selftest assertions=%d" % n)


def deb_selftest():
    """check deb-stamp and deb-require on a fixture"""
    import shutil
    import tempfile
    n = 0
    tmp = tempfile.mkdtemp(prefix="stamps-deb-")
    try:
        def git(*a):
            """run git in the test folder"""
            subprocess.run(["git", *a], cwd=tmp, check=True, capture_output=True, env=GIT_ENV)

        os.makedirs(os.path.join(tmp, "test", "system", "run"))
        os.makedirs(os.path.join(tmp, "src", "install"))
        os.makedirs(os.path.join(tmp, "docs"))
        os.makedirs(os.path.join(tmp, "debs"))
        with open(os.path.join(tmp, ".gitignore"), "w") as f:
            f.write("debs/\n")
        affects = os.path.join(tmp, "test", "system", "run", "affects.tsv")
        with open(affects, "w") as f:
            f.write("src/install/foo.sh\tinstaller.sh\n")
            f.write("docs/bar.md\tNONE\n")
            f.write("docs/\tNONE\n")
        with open(os.path.join(tmp, "src", "install", "foo.sh"), "w") as f:
            f.write("echo one\n")
        with open(os.path.join(tmp, "docs", "bar.md"), "w") as f:
            f.write("doc one\n")
        git("init", "-q")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
        git("add", "-A")
        git("-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "fixture")

        deb = os.path.join(tmp, "debs", "rhizo_0.1.0_amd64.deb")
        with open(deb, "wb") as f:
            f.write(b"deb bytes one")

        assert is_rhizo_deb(deb), "is_rhizo_deb(rhizo_0.1.0_amd64.deb)"
        assert not is_rhizo_deb(os.path.join(tmp, "rhizo-sample_0.1.0_amd64.deb")), \
            "not is_rhizo_deb(rhizo-sample_0.1.0_amd64.deb)"
        n += 1

        def edit(rel, body):
            """write a file in the test folder"""
            with open(os.path.join(tmp, rel), "w") as f:
                f.write(body)

        absent = os.path.join(tmp, "test", "system", "run", "absent.tsv")
        tracked = ["docs/bar.md", "src/install/foo.sh"]
        before = deb_input_digest(tmp, absent, tracked=tracked)
        edit("docs/bar.md", "doc two\n")
        assert deb_input_digest(tmp, absent, tracked=tracked) != before, \
            "deb_input_digest() without affects.tsv changes after a write to docs/bar.md"
        edit("docs/bar.md", "doc one\n")
        n += 1
        if importlib.util.find_spec("affects") is None:
            print("ok stamps.py deb selftest assertions=%d affects=absent" % n)
            return

        def stamp(**kw):
            """call deb_stamp for the stub .deb"""
            deb_stamp(deb, root=tmp, affects_tsv=affects, **kw)

        def require(**kw):
            """return deb_require() for the stub .deb"""
            return deb_require(deb, root=tmp, affects_tsv=affects, **kw)

        stamp()
        assert require() is None, "deb_require() is None after deb_stamp()"
        n += 1

        edit("src/install/foo.sh", "echo two\n")
        reason = require()
        assert reason and reason.startswith("inputs changed"), \
            "deb_require() starts with inputs changed after a write to src/install/foo.sh (%r)" % reason
        n += 1
        edit("src/install/foo.sh", "echo one\n")
        assert require() is None
        n += 1

        with open(deb, "wb") as f:
            f.write(b"deb bytes two")
        reason = require()
        assert reason == "not the stamped package", \
            "deb_require() == 'not the stamped package' after a write to the deb (%r)" % reason
        n += 1
        with open(deb, "wb") as f:
            f.write(b"deb bytes one")
        assert require() is None
        n += 1

        os.remove(deb_stamp_path(deb))
        assert require() == "no stamp", "deb_require() == 'no stamp' without the stamp file"
        n += 1
        stamp()

        edit("docs/bar.md", "doc two\n")
        assert require() is None, "deb_require() is None after a write to NONE-routed docs/bar.md"
        n += 1
        edit("docs/bar.md", "doc one\n")

        edit("src/install/new.sh", "echo new\n")
        reason = require()
        assert reason and reason.startswith("inputs changed"), \
            "deb_require() starts with inputs changed after an untracked src/install/new.sh (%r)" % reason
        n += 1
        os.remove(os.path.join(tmp, "src", "install", "new.sh"))
        assert require() is None
        n += 1

        edit("docs/new.md", "doc new\n")
        assert require() is None, "deb_require() is None after an untracked docs/new.md"
        n += 1
        os.remove(os.path.join(tmp, "docs", "new.md"))

        clone = tmp + "-clone"
        subprocess.run(["git", "clone", "-q", tmp, clone], check=True, capture_output=True, env=GIT_ENV)
        try:
            clone_affects = os.path.join(clone, "test", "system", "run", "affects.tsv")
            os.makedirs(os.path.join(clone, "debs"), exist_ok=True)
            clone_deb = os.path.join(clone, "debs", "rhizo_0.1.0_amd64.deb")
            shutil.copyfile(deb, clone_deb)
            deb_stamp(clone_deb, root=clone, affects_tsv=clone_affects)
            shutil.copyfile(clone_deb, deb)
            shutil.copyfile(deb_stamp_path(clone_deb), deb_stamp_path(deb))
            assert require() is None, "deb_require() is None for a deb and stamp from a clone"
            n += 1
        finally:
            shutil.rmtree(clone, ignore_errors=True)

        pre = deb_input_digest(tmp, affects_tsv=affects)
        edit("src/install/foo.sh", "echo mid-build-edit\n")
        raised_inputs_changed = False
        try:
            deb_stamp(deb, root=tmp, affects_tsv=affects, expect_inputs=pre)
        except InputsChangedError:
            raised_inputs_changed = True
        assert raised_inputs_changed, \
            "deb_stamp(expect_inputs=pre) raises InputsChangedError after a write to src/install/foo.sh"
        edit("src/install/foo.sh", "echo one\n")
        n += 1
        pre = deb_input_digest(tmp, affects_tsv=affects)
        deb_stamp(deb, root=tmp, affects_tsv=affects, expect_inputs=pre)
        assert require() is None, "deb_require() is None after deb_stamp(expect_inputs=pre) with a matching digest"
        n += 1

        cli_tmp = tempfile.mkdtemp(prefix="stamps-cli-")
        try:
            cli_deb = os.path.join(cli_tmp, "rhizo_0.1.0_amd64.deb")
            with open(cli_deb, "wb") as f:
                f.write(b"cli deb bytes")
            wrong_pre = "0" * 64
            rc = main(["stamps.py", "deb-stamp", cli_deb, wrong_pre])
            assert rc == 3, "main(deb-stamp, wrong_pre) == 3 (rc=%r)" % rc
            assert not os.path.exists(deb_stamp_path(cli_deb)), \
                "main(deb-stamp, wrong_pre) writes no stamp"
            n += 1
            real_pre = deb_input_digest(ROOT)
            rc = main(["stamps.py", "deb-stamp", cli_deb, real_pre])
            assert rc == 0, "main(deb-stamp, real_pre) == 0 (rc=%r)" % rc
            n += 1
        finally:
            shutil.rmtree(cli_tmp, ignore_errors=True)

        nogit = tempfile.mkdtemp(prefix="stamps-nogit-")
        try:
            nogit_deb = os.path.join(nogit, "rhizo_0.1.0_amd64.deb")
            with open(nogit_deb, "wb") as f:
                f.write(b"deb bytes one")
            empty_digest = hashlib.sha256().hexdigest()
            with open(deb_stamp_path(nogit_deb), "w") as f:
                f.write("sha256\t%s\n" % sha256_file(nogit_deb))
                f.write("commit\tunknown\n")
                f.write("inputs\t%s\n" % empty_digest)
            reason = deb_require(nogit_deb, root=nogit, affects_tsv=affects)
            assert reason, \
                "deb_require() is not None for a root without .git"
            n += 1

            raised_nogit = False
            try:
                deb_stamp(nogit_deb, root=nogit, affects_tsv=affects)
            except RuntimeError:
                raised_nogit = True
            assert raised_nogit, \
                "deb_stamp() raises RuntimeError for a root without .git"
            n += 1
        finally:
            shutil.rmtree(nogit, ignore_errors=True)

        always_true = lambda p, g, rows: True
        stamp(path_is_input=always_true)
        edit("docs/bar.md", "doc mutated\n")
        got = require(path_is_input=always_true)
        assert got and got.startswith("inputs changed"), \
            "deb_require(path_is_input=always_true) starts with inputs changed after a write to docs/bar.md (%r)" % got
        edit("docs/bar.md", "doc one\n")
        n += 1

        always_false = lambda p, g, rows: False
        stamp(path_is_input=always_false)
        edit("src/install/foo.sh", "echo mutated\n")
        got = require(path_is_input=always_false)
        assert got is None, \
            "deb_require(path_is_input=always_false) is None after a write to src/install/foo.sh (%r)" % got
        edit("src/install/foo.sh", "echo one\n")
        n += 1

        tracked_only_at_stamp = tracked_files(tmp, include_untracked=False)
        stamp(tracked=tracked_only_at_stamp)
        edit("src/install/new.sh", "echo new\n")
        tracked_only_now = tracked_files(tmp, include_untracked=False)
        got = require(tracked=tracked_only_now)
        assert got is None, \
            "deb_require(tracked=tracked_only_now) is None after an untracked src/install/new.sh (%r)" % got
        os.remove(os.path.join(tmp, "src", "install", "new.sh"))
        n += 1

        stamp()
        with open(deb, "wb") as f:
            f.write(b"deb bytes two")
        got = require(check_sha=False)
        assert got is None, \
            "deb_require(check_sha=False) is None after a write to the deb (%r)" % got
        with open(deb, "wb") as f:
            f.write(b"deb bytes one")
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("ok stamps.py deb selftest assertions=%d" % n)
    return n


def main(argv):
    """run --selftest or the argv[1] mode"""
    if "--selftest" in argv:
        selftest()
        deb_selftest()
        return 0
    mode = argv[1] if len(argv) > 1 else "check"
    if mode in ("begin", "stamp"):
        done = mode == "stamp" and argv[2:3] == ["--done"]
        names = argv[3:] if done else argv[2:]
        if not names:
            print("stamps.py begin <name>... | stamp [--done] <name>...", file=sys.stderr)
            return 2
        table = entries()
        known = {e.name for e in table}
        missing = [n for n in names if n not in known]
        if missing:
            print("%s has no row in artifacts.tsv" % " ".join(missing),
                  file=sys.stderr)
            return 2
        linked = outside_checkout(names, table=table)
        if linked:
            for r in linked:
                print(r, file=sys.stderr)
            return 1
        if mode == "begin":
            record_pending(names, table)
            return 0
        refused = write_stamps(names, done, table)
        for r in refused:
            print(r, file=sys.stderr)
        return 1 if refused else 0
    if mode == "changed":
        for stamp in changed():
            print(stamp)
        return 0
    if mode == "products":
        for e in entries():
            if e.set == "payload":
                print(product_path(e.name))
        return 0
    if mode == "deb-digest":
        print(deb_input_digest(ROOT))
        return 0
    if mode == "deb-stamp":
        if len(argv) not in (3, 4):
            print("stamps.py deb-stamp <deb> [pre-digest|@file]", file=sys.stderr)
            return 2
        deb = argv[2]
        if not is_rhizo_deb(deb):
            print("%s is not a rhizo_*.deb" % deb, file=sys.stderr)
            return 2
        pre = None
        if len(argv) == 4:
            pre = argv[3]
            if pre.startswith("@"):
                with open(pre[1:]) as f:
                    pre = f.read().strip()
        try:
            deb_stamp(deb, expect_inputs=pre)
        except InputsChangedError as e:
            print("%s" % e, file=sys.stderr)
            return 3
        return 0
    if mode == "deb-require":
        if len(argv) >= 3:
            deb = argv[2]
        else:
            deb = find_deb()
            if deb is None:
                print("no rhizo_*.deb in %s" % deb_dir(),
                      file=sys.stderr)
                return 1
        reason = deb_require(deb)
        if reason:
            print("%s" % reason)
            return 1
        return 0
    if mode == "require":
        findings = check(require_names=set(argv[2:]))
    elif mode == "check" and argv[2:] == ["--names"]:
        for name, build, sources in rows():
            if verdict(name, build, sources, False):
                print(name)
        return 0
    elif mode == "check":
        findings = check()
    else:
        print("stamps.py "
              "{begin <name>...|stamp [--done] <name>...|changed|products|check [--names]|require <name>...|deb-stamp <deb>|deb-require [deb]}",
              file=sys.stderr)
        return 2
    for f in findings:
        print(f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
