#!/usr/bin/env python3
import glob
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))


def _load_stamps():
    """return the build stamps module loaded from its file"""
    spec = importlib.util.spec_from_file_location("stamps", os.path.join(ROOT, "tools", "build", "stamps.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


sf = _load_stamps()

VETTED = {
    "_ZN7android19elapsedRealtimeNanoEv": "int64_t elapsedRealtimeNano(): no std type",
    "_ZN7android4base9ShouldLogENS0_11LogSeverityEPKc": "bool ShouldLog(LogSeverity, const char*): no std type",
}
KNOWN_BAD = {
    "_ZN7android4base10LogMessage6streamEv":
        "returns libbase's std::__1::ostream&, which this binary's static std::__ndk1 code "
        "dereferences; log through liblog's C API instead",
}
ANDROID_SYM = re.compile(r"^_Z(?:T[VIS]|Th n?\d+_|Tv n?\d+_n?\d+_|Tc\w*?_)?N[KVrRO]*7android".replace(" ", ""))
HAL_CALL = re.compile(r'(?<![\w.-])hal\.sh"?\s+([A-Za-z0-9_.+-]+)')
EXEMPT_SCRIPTS = {
    "tools/build/hal/keymint-bespoke-aes-only.sh":
        "the AES-only keymint; the shipped rhizo-keymint-service is keymint.sh's",
}


def _run(argv):
    """return the output of a command"""
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout


def is_elf(path):
    """return whether a file starts with the ELF magic"""
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def carries_ndk1(path):
    """return whether a file carries the __ndk1 namespace"""
    with open(path, "rb") as f:
        return b"__ndk1" in f.read()


def android_imports(path):
    """return the sorted Android symbols a file imports"""
    out = _run(["nm", "-D", "--undefined-only", path])
    syms = (ln.split()[-1].split("@")[0] for ln in out.splitlines() if ln.strip())
    return sorted({s for s in syms if ANDROID_SYM.match(s)})


def demangle(sym):
    """return the demangled form of a symbol, or the symbol itself"""
    try:
        return _run(["c++filt", sym]).strip()
    except (OSError, subprocess.CalledProcessError):
        return sym


def check_binary(path):
    """return the findings for an ELF file"""
    if not carries_ndk1(path):
        return []
    bad = []
    for sym in android_imports(path):
        if sym in VETTED:
            continue
        why = KNOWN_BAD.get(sym, "not vetted: read its signature and, if no std object crosses, add it to VETTED")
        bad.append("%s imports %s -- %s" % (path, demangle(sym), why))
    return bad


def hal_scripts(root):
    """map each build script to its hal.sh outputs"""
    found = {}
    for script in sorted(glob.glob(os.path.join(root, "tools/build/**/*.sh"), recursive=True)):
        rel = os.path.relpath(script, root)
        if rel == "tools/build/hal/hal.sh":
            continue
        for line in open(script, errors="replace"):
            if line.lstrip().startswith("#"):
                continue
            m = HAL_CALL.search(line)
            if m:
                found.setdefault(rel, set()).add(m.group(1))
    return found


def required_rows(root, table):
    """return artifacts.tsv rows and missing-row findings"""
    scripts = hal_scripts(root)
    rows = [r for r in table if sf.build_script(r[1]) in scripts]
    owned = {sf.build_script(r[1]) for r in rows}
    bad = ["%s builds %s through hal.sh but has no artifacts.tsv row" % (s, ", ".join(sorted(names)))
           for s, names in sorted(scripts.items()) if s not in owned and s not in EXEMPT_SCRIPTS]
    return rows, bad


def check(share, root=ROOT, table=None):
    """check the libc++ boundary of the shared files"""
    table = sf.rows() if table is None else table
    rows, bad = required_rows(root, table)
    seen = set()
    for name, build, sources in rows:
        path = os.path.join(share, name)
        changed = sf.verdict(name, build, sources, True, share, root)
        if changed:
            bad.append(changed)
        if os.path.isfile(path) and is_elf(path):
            seen.add(os.path.realpath(path))
            bad += check_binary(path)
    for pat in ("gfx_hal/*", "gfx_hal_32/*", "rel/*/*", "rhizo-*"):
        for p in sorted(glob.glob(os.path.join(share, pat))):
            if os.path.isfile(p) and not os.path.islink(p) and is_elf(p) and os.path.realpath(p) not in seen:
                seen.add(os.path.realpath(p))
                bad += check_binary(p)
    return len(seen), bad


def selftest():
    """build ELF fixtures and run the checks"""
    cc = shutil.which("cc")
    if not cc:
        print("check-libcxx-boundary selftest: FAILED, no host cc to build the fixtures")
        return 1
    fail = 0
    tmp = tempfile.mkdtemp()
    try:
        root = os.path.join(tmp, "root")
        share = os.path.join(root, "var", "share")
        os.makedirs(os.path.join(share, "gfx_hal"))
        os.makedirs(os.path.join(root, "tools", "build", "hal"))
        ndk1_def = "_ZNSt6__ndk18ios_base4initEPv"

        def build(rel, imports=(), ndk1=True, data_imports=(), extra=()):
            """build a test object with the given imports"""
            src = os.path.join(tmp, os.path.basename(rel) + ".c")
            with open(src, "w") as f:
                for i, s in enumerate(imports):
                    f.write('extern int f%d(void) __asm__("%s");\n' % (i, s))
                for i, s in enumerate(data_imports):
                    f.write('extern char d%d[] __asm__("%s");\n' % (i, s))
                if ndk1:
                    f.write('int nd(void) __asm__("%s");\nint nd(void) { return 0; }\n' % ndk1_def)
                calls = "".join(" + f%d()" % i for i in range(len(imports)))
                calls += "".join(" + (int)(long)d%d" % i for i in range(len(data_imports)))
                f.write("int entry(void) { return 0%s; }\n" % calls)
            out = os.path.join(share, rel)
            subprocess.run([cc, "-shared", "-fPIC", "-Wl,--unresolved-symbols=ignore-all", "-Wl,--no-as-needed",
                            "-o", out, src] + list(extra), check=True)
            return out

        for lib in ("libc++.so", "libc++_shared.so"):
            subprocess.run([cc, "-shared", "-fPIC", "-o", os.path.join(tmp, lib), "-x", "c", "/dev/null"], check=True)
        stream = "_ZN7android4base10LogMessage6streamEv"
        vetted = "_ZN7android19elapsedRealtimeNanoEv"
        bad_bin = build("gfx_hal/rhizo-bad", [stream, vetted])
        good_bin = build("gfx_hal/rhizo-good", [vetted])
        new_bin = build("gfx_hal/rhizo-new", ["_ZN7android4base8GetFooV2Ev"])
        plat_bin = build("gfx_hal/libplatform.so", [stream], ndk1=False, extra=["-L", tmp, "-l:libc++.so"])
        mixed_bin = build("gfx_hal/rhizo-mixed", [stream], extra=["-L", tmp, "-l:libc++.so"])
        ndk_bin = build("gfx_hal/rhizo-ndk-shared", [stream], extra=["-L", tmp, "-l:libc++_shared.so"])
        vt_bin = build("gfx_hal/rhizo-vtable", data_imports=["_ZTVN7android4base10LogMessageE"])
        thunk_bin = build("gfx_hal/rhizo-thunk", ["_ZThn8_N7android7RefBase10onFirstRefEv"])

        for name in ("matching", "changed", "gone", "rowless"):
            with open(os.path.join(root, "tools/build/%s.sh" % name), "w") as f:
                f.write("# tools/build/hal/hal.sh rhizo-commented x.cpp\ntools/build/hal.sh rhizo-%s x.cpp \\\n" % name)
        with open(os.path.join(root, "tools", "build", "hal", "keymint-bespoke-aes-only.sh"), "w") as f:
            f.write("tools/build/hal/hal.sh rhizo-keymint-service x.cpp\n")
        with open(os.path.join(root, "src.cpp"), "w") as f:
            f.write("int x;\n")
        table = [("gfx_hal/rhizo-%s" % n, "tools/build/%s.sh" % n, ["src.cpp"]) for n in ("matching", "changed", "gone")]
        matching_bin = build("gfx_hal/rhizo-matching", [vetted])
        build("gfx_hal/rhizo-changed", [vetted])
        with open(sf.stamp_path("gfx_hal/rhizo-matching", share), "w") as f:
            f.write(sf.source_hash(["src.cpp"], root))
        with open(sf.stamp_path("gfx_hal/rhizo-changed", share), "w") as f:
            f.write("0" * 64)

        n, bad = check(share, root, table)
        text = "\n".join(bad)

        def expect(ok, what):
            """record a failure unless the condition holds"""
            nonlocal fail
            if not ok:
                print("SELFTEST FAILED: %s:\n%s" % (what, text))
                fail = 1

        expect(n == 10, "expected 10 ELF targets, scanned %d" % n)
        expect(any(bad_bin in b and "LogMessage::stream()" in b and "__ndk1" in b for b in bad),
               "an __ndk1 binary importing LogMessage::stream() must be named")
        expect(good_bin not in text, "a binary importing only vetted calls was flagged")
        expect(any(new_bin in b and "not vetted" in b for b in bad), "an unvetted android:: import must fail")
        expect(plat_bin not in text, "a library with no __ndk1 of its own was flagged")
        expect(any(mixed_bin in b and "LogMessage::stream()" in b for b in bad),
               "needing libc++.so must not exempt a binary that carries __ndk1")
        expect(any(ndk_bin in b and "LogMessage::stream()" in b for b in bad),
               "needing the NDK's libc++_shared.so must not exempt a binary")
        expect(any(vt_bin in b and "vtable for android::base::LogMessage" in b for b in bad),
               "an imported android:: vtable must be checked")
        expect(any(thunk_bin in b and "non-virtual thunk" in b for b in bad), "an imported android:: thunk must be checked")
        expect(matching_bin not in text and "rhizo-matching" not in text, "a matching required binary was flagged")
        expect(any("rhizo-changed" in b and "different sources" in b for b in bad), "a changed required binary must fail")
        expect(any("rhizo-gone" in b and "not staged" in b for b in bad), "a missing required binary must fail")
        expect(any("tools/build/rowless.sh" in b and "no artifacts.tsv row" in b for b in bad),
               "a hal.sh caller with no row must fail")
        expect("rhizo-commented" not in text and "bespoke" not in text, "a comment or an exempt caller was required")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("check-libcxx-boundary selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


def main():
    """run the check or its selftest and print the result"""
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    share = sys.argv[1] if len(sys.argv) > 1 else sf.SHARE
    n, bad = check(share)
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("OK: %d binaries, every hal.sh product staged and matching, none hands a std::__1 object to std::__ndk1 code" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
