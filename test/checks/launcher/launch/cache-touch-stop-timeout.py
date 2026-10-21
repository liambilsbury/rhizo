#!/usr/bin/env python3
import ast, contextlib, io, os, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-cache-touch")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher

bad = []
logs = []
launcher.kmsg = logs.append
real_utime = os.utime

with tempfile.TemporaryDirectory() as tmp:
    entry = os.path.join(tmp, "precompiled_sepolicy.x")
    open(entry, "w").write("p")
    real_utime(entry, (1, 1))
    launcher.touch_cache_entry(entry)
    if os.stat(entry).st_mtime < 1000 or logs:
        bad.append(("a writable entry is touched silently", os.stat(entry).st_mtime, logs))

    def erofs(path, *a, **k):
        """raise the OSError a read-only cache raises"""
        raise OSError(30, "Read-only file system")

    os.utime = erofs
    try:
        launcher.touch_cache_entry(entry)
    except OSError as e:
        bad.append(("a read-only entry does not raise", repr(e)))
    finally:
        os.utime = real_utime
    if len(logs) != 1 or "EROFS" not in logs[0] or entry not in logs[0]:
        bad.append(("a read-only entry is logged by errno name", logs))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
helper = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "touch_cache_entry")
inside = {id(c) for c in ast.walk(helper)}
bare = [c.lineno for c in ast.walk(tree) if isinstance(c, ast.Call) and ast.unparse(c.func) == "os.utime"
        and id(c) not in inside and len(c.args) == 1]
if bare:
    bad.append(("a bare os.utime on a cache entry", bare))

stop = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "androidd_stop")
reads = [c.lineno for c in ast.walk(stop) if isinstance(c, ast.Constant) and c.value == "RHIZO_STOP_TIMEOUT"]
if len(reads) != 1:
    bad.append(("androidd_stop parses RHIZO_STOP_TIMEOUT once", reads))

for b in bad:
    print("FAIL", b)
print("ok" if not bad else "FAIL")
sys.exit(1 if bad else 0)
