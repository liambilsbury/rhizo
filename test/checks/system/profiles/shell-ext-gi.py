#!/usr/bin/env python3
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GENERATOR = os.path.join(HERE, "..", "..", "..", "..", "tools", "build", "test-tools", "gen-gnome-harness-ext.sh")
DEFAULT_POOL = os.path.join(HERE, "..", "..", "..", "..", "var", "share", "gnome-debs")
VM_SERIES = "noble"
BASE_NAMESPACES = {"GLib", "GObject", "Gio"}


def extension_source(generator_text):
    """return the extension.js heredoc text"""
    m = re.search(r"cat > \"\$OUT_DIR/extension\.js\" <<'RHIZO_GNOME_EXT_EOF'\n(.*?)\nRHIZO_GNOME_EXT_EOF\n",
                  generator_text, re.S)
    return m.group(1) if m else None


def gi_calls(js):
    """return the namespace function calls in js"""
    code = re.sub(r"/\*.*?\*/", "", js, flags=re.S)
    code = "\n".join(re.sub(r"(^|[^:])//.*$", r"\1", line) for line in code.splitlines())
    names = {alias for alias, ns in re.findall(r"^import\s+(\w+)\s+from\s+'gi://(\w+)(?:\?[^']*)?';", code, re.M)
             if alias == ns}
    return {(ns, fn) for ns, fn in re.findall(r"\b([A-Z]\w*)\.([a-z_][a-z0-9_]*)\s*\(", code) if ns in names}


def check(js, resolve):
    """return three lists of call results"""
    failures, unverified, verified = [], [], []
    calls = gi_calls(js)
    if not calls:
        failures.append("the extension makes no gi:// namespace call at all")
        return failures, unverified, verified
    answers = resolve(sorted(f"{ns}.{fn}" for ns, fn in calls))
    for ns, fn in sorted(calls):
        call, a = f"{ns}.{fn}()", answers.get(f"{ns}.{fn}", {"unavailable": "the resolver gave no answer"})
        if "symbol" in a:
            verified.append(f"{call} ({a['symbol']} in {a['typelib']})")
        elif "missing" in a:
            failures.append(f"{call}: {a['typelib']} has no {fn}")
        elif ns in BASE_NAMESPACES:
            failures.append(f"{call}: cannot be checked against the vm's base image: {a['unavailable']}")
        else:
            unverified.append(f"{call}: {a['unavailable']}")
    return failures, unverified, verified


def resolve_here(calls, base_ok, pool_dirs, pool_root):
    """look up each call in a child process"""
    env = dict(os.environ, GI_TYPELIB_PATH=":".join(pool_dirs))
    req = json.dumps({"calls": calls, "base_ok": base_ok, "pool_root": pool_root})
    out = subprocess.run([sys.executable, os.path.abspath(__file__), "--resolve", req],
                         env=env, capture_output=True, text=True)
    if out.returncode != 0:
        why = (out.stderr.strip().splitlines() or ["no output"])[-1]
        return {c: {"unavailable": f"the GIRepository lookup failed: {why}"} for c in calls}
    return json.loads(out.stdout)


def resolve_child(req):
    """print the typelib lookup for each call"""
    import gi
    gi.require_version("GIRepository", "2.0")
    from gi.repository import GIRepository
    repo = GIRepository.Repository.get_default()
    answers = {}
    for call in req["calls"]:
        ns, fn = call.split(".", 1)
        base = ns in BASE_NAMESPACES
        if base and not req["base_ok"]:
            answers[call] = {"unavailable": f"this machine is not the vm's series ({VM_SERIES})"}
            continue
        try:
            repo.require(ns, None, 0)
        except Exception as e:
            answers[call] = {"unavailable": f"{ns} does not load: {e}"}
            continue
        path = repo.get_typelib_path(ns)
        from_pool = req["pool_root"] and path.startswith(req["pool_root"] + os.sep)
        if base == bool(from_pool):
            answers[call] = {"unavailable": f"{ns} loaded from {path}, not from "
                                            f"{'the base image' if base else 'the GNOME pool'}"}
            continue
        info = repo.find_by_name(ns, fn)
        if info is not None and info.get_type() == GIRepository.InfoType.FUNCTION:
            answers[call] = {"symbol": GIRepository.function_info_get_symbol(info), "typelib": path}
        else:
            answers[call] = {"missing": True, "typelib": path}
    print(json.dumps(answers))
    return 0


def vm_series_matches(os_release="/etc/os-release"):
    """return whether the guest's os release names the expected series"""
    try:
        with open(os_release) as f:
            return re.search(rf"^VERSION_CODENAME={VM_SERIES}$", f.read(), re.M) is not None
    except OSError:
        return False


def unpack_pool(pool, dest):
    """unpack the newest gnome-shell and gir1.2 debs"""
    newest = {}
    for deb in sorted(glob.glob(os.path.join(pool, "gnome-shell_*.deb")) + glob.glob(os.path.join(pool, "gir1.2-*.deb"))):
        newest[os.path.basename(deb).split("_", 1)[0]] = deb
    for deb in newest.values():
        subprocess.run(["dpkg-deb", "-x", deb, dest], check=True)
    return sorted({os.path.dirname(p) for p in glob.glob(os.path.join(dest, "**", "*.typelib"), recursive=True)})


def selftest():
    """run the selftest cases and print results"""
    bad = 0

    def expect(name, cond):
        """print an ok or FAIL line for a case and count the failures"""
        nonlocal bad
        print(f"{'ok  ' if cond else 'FAIL'} {name}")
        bad += 0 if cond else 1

    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.normpath(DEFAULT_POOL))))
    expect("the default gnome pool sits in the checkout's own var/share",
           os.path.isfile(os.path.join(root, "debian", "control")))
    head = ("import Gio from 'gi://Gio';\nimport GLib from 'gi://GLib';\n"
            "import Clutter from 'gi://Clutter';\n")
    old = head + "Ping() { return `pid=${GLib.getpid()}`; }\nGio.bus_own_name(1);\n"
    new = head + "Ping() { return `pid=${GLib.file_read_link('/proc/self')}`; }\nGio.bus_own_name(1);\n"

    table = {"GLib.file_read_link": {"symbol": "g_file_read_link", "typelib": "GLib-2.0.typelib"},
             "GLib.getpid": {"missing": True, "typelib": "GLib-2.0.typelib"},
             "Gio.bus_own_name": {"symbol": "g_bus_own_name_with_closures", "typelib": "Gio-2.0.typelib"},
             "Clutter.get_default_backend": {"unavailable": "no pool"}}
    fake = lambda calls: {c: table[c] for c in calls if c in table}
    f, _, _ = check(old, fake)
    expect("GLib.getpid() is failed by name when its typelib has no getpid",
           f == ["GLib.getpid(): GLib-2.0.typelib has no getpid"])
    f, u, v = check(new, fake)
    expect("GLib.file_read_link() and Gio.bus_own_name() pass when their typelibs carry them",
           f == [] and u == [] and len(v) == 2)
    f, _, v = check(head + "// GLib.getpid() used to be here\n/* GLib.getpid() */\nGio.bus_own_name(1);\n", fake)
    expect("a call inside a comment is not a call", f == [] and len(v) == 1)
    f, u, _ = check(head + "Clutter.get_default_backend();\n", fake)
    expect("a pool call that cannot be looked up is named unverified, never passed or failed",
           f == [] and u == ["Clutter.get_default_backend(): no pool"])
    f, _, _ = check(new, lambda calls: {c: {"unavailable": "not noble"} for c in calls})
    expect("a base-image call that cannot be looked up fails rather than passing unverified",
           len(f) == 2 and all("cannot be checked against the vm's base image" in x for x in f))
    f, _, _ = check(new, lambda calls: {})
    expect("a resolver that answers nothing fails every base-image call", len(f) == 2)
    expect("an unparsed source (no gi:// call) fails", check("", fake)[0] != [])
    gen = "cat > \"$OUT_DIR/extension.js\" <<'RHIZO_GNOME_EXT_EOF'\n" + old + "\nRHIZO_GNOME_EXT_EOF\n"
    expect("the extension source is read from the generator's own heredoc", extension_source(gen) == old)

    if vm_series_matches():
        real = lambda calls: resolve_here(calls, True, [], "")
        f, _, _ = check(old, real)
        expect("the real lookup fails GLib.getpid() against this series' GLib typelib",
               any(x.startswith("GLib.getpid(): ") and "has no getpid" in x for x in f))
        f, _, v = check(new, real)
        expect("the real lookup passes GLib.file_read_link() and Gio.bus_own_name() (a shadowed binding)",
               f == [] and any("g_bus_own_name_with_closures" in x for x in v))
        tmp = tempfile.mkdtemp()
        f, u, _ = check("import GLib from 'gi://GLib';\nGLib.file_read_link('/');\n",
                        lambda calls: resolve_here(calls, True, [tmp], tmp))
        expect("a base namespace still resolves from the base image with a pool path prepended", f == [] and u == [])
        os.rmdir(tmp)
    else:
        expect(f"this machine is the vm's series ({VM_SERIES})", False)
    print(f"{bad} selftest checks failed")
    return 1 if bad else 0


def main():
    """run the check, the resolve helper or the selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", default=DEFAULT_POOL)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--resolve", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.resolve:
        return resolve_child(json.loads(args.resolve))
    if args.selftest:
        return selftest()
    with open(GENERATOR) as f:
        js = extension_source(f.read())
    if js is None:
        print(f"FAIL: no extension.js heredoc found in {GENERATOR}")
        return 1
    base_ok = vm_series_matches()
    with tempfile.TemporaryDirectory() as tmp:
        pool_dirs = unpack_pool(args.pool, tmp) if os.path.isdir(args.pool) else []
        failures, unverified, verified = check(js, lambda calls: resolve_here(calls, base_ok, pool_dirs, tmp))
    for line in verified:
        print(f"ok   {line}")
    for line in unverified:
        print(f"UNVERIFIED {line}")
    for line in failures:
        print(f"FAIL {line}")
    if failures:
        return 1
    print(f"{len(verified)} gi:// calls verified, {len(unverified)} unverified (pool: {args.pool})"
          if unverified else f"{len(verified)} gi:// calls verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
