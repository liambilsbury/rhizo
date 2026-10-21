#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
RULES = os.path.join(ROOT, "debian", "rules")

ALLOWLIST = {
    "libc.so.6": "glibc itself",
    "ld-linux-x86-64.so.2": "glibc's own dynamic loader (amd64)",
    "ld-linux-aarch64.so.1": "glibc's own dynamic loader (arm64)",
    "libm.so.6": "glibc math (aapt2)",
    "libdl.so.2": "glibc dynamic loading (aapt2)",
    "libpthread.so.0": "glibc threads (aapt2, rhizo-audiod)",
    "librt.so.1": "glibc realtime/POSIX timers (aapt2)",
    "libgcc_s.so.1": "GCC's own runtime support library (aapt2)",
    "libpipewire-0.3.so.0": "rhizo-audiod links libpipewire-0.3-dev, MIT/LGPL-2.1+",
    "libwayland-client.so.0": "rhizo-wlbridge links libwayland-dev, MIT",
    "libva.so.2": "rhizo-streamd links libva-dev, MIT",
    "libva-drm.so.2": "rhizo-streamd links libva-dev, MIT",
}

DAEMON_BASENAMES = {"rhizo-hostfsd", "rhizo-probe-client", "rhizo-streamd",
                    "rhizo-audiod", "rhizo-wlbridge", "rhizo-delayd", "rhizo-headroomd"}

BIONIC_INTERP = ("/system/bin/linker", "/system/bin/linker64")


def ship_set(root):
    """return the paths from print-ship-set"""
    out = subprocess.run(["make", "-s", "-f", os.path.join(root, "debian", "rules"),
                          "print-ship-set"],
                         cwd=os.path.join(root, "debian"), capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("make -f debian/rules print-ship-set failed: %s" % out.stderr.strip())
    return [p for p in out.stdout.split() if p]


def interp_of(path):
    """return the .interp string of an ELF file"""
    out = subprocess.run(["readelf", "-p", ".interp", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    m = re.search(r"\]\s+(\S+)\s*$", out.stdout, re.M)
    return m.group(1) if m else None


def is_elf(path):
    """return whether a file starts with the ELF magic"""
    try:
        with open(path, "rb") as fh:
            return fh.read(4) == b"\x7fELF"
    except OSError:
        return False


def needed_of(path):
    """return the shared libraries an ELF file needs"""
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("readelf -d %s failed: %s" % (path, out.stderr.strip()))
    return re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", out.stdout)


LIBSTDCXX_MARKER = "_ZSt9terminatev"


def libstdcxx_state(path):
    """return the libstdc++ link state of a binary"""
    needed = needed_of(path)
    if any(n.startswith("libstdc++.so") for n in needed):
        return "clean"
    out = subprocess.run(["nm", "--defined-only", path], capture_output=True, text=True)
    if not out.stdout.strip():
        return "stripped"
    if re.search(r"\bT\s+%s\b" % re.escape(LIBSTDCXX_MARKER), out.stdout):
        return "embedded"
    return "clean"


def check(root):
    """check the shipped host ELF files"""
    fails = []
    checked = 0
    for rel in ship_set(root):
        if not rel.startswith("var/share/"):
            continue
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            fails.append("%s: in the ship set but not built -- run its own "
                         "build-*.sh" % rel)
            continue
        if not os.path.isfile(path) or not is_elf(path):
            continue
        interp = interp_of(path)
        if interp is not None and any(interp.startswith(b) for b in BIONIC_INTERP):
            continue
        base = os.path.basename(rel)
        if interp is None:
            if base in DAEMON_BASENAMES:
                fails.append("%s: statically linked daemon -- no .interp section "
                             "at all" % rel)
                checked += 1
            continue
        checked += 1
        for lib in needed_of(path):
            if lib not in ALLOWLIST:
                fails.append("%s: DT_NEEDED %s is not on the allowlist -- add a row "
                             "to ALLOWLIST in host-elf-links.py or fix the build" % (rel, lib))
        if base in DAEMON_BASENAMES:
            state = libstdcxx_state(path)
            if state == "embedded":
                fails.append("%s: carries defined C++ symbols with no libstdc++.so.* "
                             "in its DT_NEEDED" % rel)
            elif state == "stripped":
                fails.append("%s: unverifiable: stripped -- its own symbol table is "
                             "gone" % rel)
    if checked == 0:
        fails.append("no host ELF was found in the ship set")
    return fails, checked


def _build_fixture_elf(work, name, needed, cxx_symbol=False, static_cxx_ok=True):
    """build a small glibc ELF file"""
    src = os.path.join(work, name + ".c")
    if cxx_symbol:
        src = os.path.join(work, name + ".cpp")
        with open(src, "w") as fh:
            fh.write("#include <string>\nstd::string f(){ return std::string(\"x\"); }\n"
                     "int main(){ f(); return 0; }\n")
        cc = ["g++", "-O0"]
        if static_cxx_ok:
            cc.append("-static-libstdc++")
    else:
        with open(src, "w") as fh:
            fh.write("int main(){ return 0; }\n")
        cc = ["gcc", "-O0"]
    out_path = os.path.join(work, name)
    extra = []
    for lib in needed:
        if lib == "libm.so.6":
            extra.append("-lm")
    subprocess.run(cc + [src, "-o", out_path] + extra, check=True,
                   capture_output=True)
    return out_path


def selftest():
    """check the host-elf-links checks on fixtures"""
    import shutil
    if shutil.which("gcc") is None or shutil.which("readelf") is None:
        print("host-elf-links.py selftest: SKIPPED (no gcc/readelf on this host)")
        return 0
    fail = 0
    with tempfile.TemporaryDirectory() as work:
        clean = _build_fixture_elf(work, "clean", [])
        if not is_elf(clean):
            print("SELFTEST FAILED: is_elf() did not recognize a real ELF"); fail = 1
        interp = interp_of(clean)
        if not interp or "ld-linux" not in interp:
            print("SELFTEST FAILED: interp_of() did not find glibc's own loader: %r" % interp)
            fail = 1
        needed = needed_of(clean)
        if not needed or any(n not in ALLOWLIST for n in needed):
            print("SELFTEST FAILED: a plain gcc binary's own DT_NEEDED set is not "
                 "fully on ALLOWLIST: %r" % needed)
            fail = 1

        clean_needed = needed_of(clean)
        if "libc.so.6" not in clean_needed:
            print("SELFTEST FAILED: a plain gcc binary has no libc.so.6 DT_NEEDED: %r"
                 % clean_needed)
            fail = 1
        saved = ALLOWLIST.pop("libc.so.6", None)
        try:
            unlisted = [n for n in clean_needed if n not in ALLOWLIST]
            if not unlisted:
                print("SELFTEST FAILED: removing libc.so.6 from the allowlist did not "
                     "leave it unlisted in a real binary's own DT_NEEDED")
                fail = 1
        finally:
            if saved is not None:
                ALLOWLIST["libc.so.6"] = saved

        try:
            static_cxx = _build_fixture_elf(work, "static_cxx", [], cxx_symbol=True,
                                             static_cxx_ok=True)
            if libstdcxx_state(static_cxx) != "embedded":
                print("SELFTEST FAILED: a -static-libstdc++ binary was not flagged "
                     "as embedding libstdc++")
                fail = 1
            dyn_cxx_path = os.path.join(work, "dyn_cxx")
            subprocess.run(["g++", "-O0", os.path.join(work, "static_cxx.cpp"),
                           "-o", dyn_cxx_path], check=True, capture_output=True)
            if libstdcxx_state(dyn_cxx_path) != "clean":
                print("SELFTEST FAILED: a dynamically-linked C++ binary (real "
                     "libstdc++.so.* in DT_NEEDED) was flagged as embedding it")
                fail = 1
            stripped_path = os.path.join(work, "static_cxx_stripped")
            subprocess.run(["strip", "-o", stripped_path, static_cxx],
                           check=True, capture_output=True)
            if libstdcxx_state(stripped_path) != "stripped":
                print("SELFTEST FAILED: a stripped binary (nm finds no symbols) "
                     "was not reported as unverifiable")
                fail = 1
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            print("host-elf-links.py selftest: g++/strip case skipped (%s)" % exc)

        global ship_set
        real_ship_set = ship_set

        ship_set = lambda _root: ["var/share/rhizo-wlbridge-missing"]
        try:
            problems, seen = check(work)
        finally:
            ship_set = real_ship_set
        if not any("in the ship set but not built" in p for p in problems):
            print("SELFTEST FAILED: a ship-set path with nothing built at it was "
                 "not flagged: %r" % problems)
            fail = 1

        try:
            static_full = os.path.join(work, "var", "share", "rhizo-hostfsd")
            os.makedirs(os.path.dirname(static_full), exist_ok=True)
            plain_src = os.path.join(work, "static_full.c")
            with open(plain_src, "w") as fh:
                fh.write("int main(){ return 0; }\n")
            subprocess.run(["gcc", "-O0", "-static", plain_src, "-o", static_full],
                           check=True, capture_output=True)
            if interp_of(static_full) is not None:
                print("host-elf-links.py selftest: -static case skipped "
                     "(gcc did not actually produce a static binary here)")
            else:
                ship_set = lambda _root: ["var/share/rhizo-hostfsd"]
                try:
                    problems, seen = check(work)
                finally:
                    ship_set = real_ship_set
                if not any("statically linked daemon" in p for p in problems):
                    print("SELFTEST FAILED: a fully static daemon (no .interp) was "
                         "not flagged: %r" % problems)
                    fail = 1
        except (subprocess.CalledProcessError, FileNotFoundError) as exc:
            print("host-elf-links.py selftest: -static case skipped (%s)" % exc)

    if fail:
        print("host-elf-links.py selftest: FAILED")
        return 1
    print("host-elf-links.py selftest: ok")
    return 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: host-elf-links.py [--selftest]", file=sys.stderr)
        return 2
    fails, checked = check(ROOT)
    for f in fails:
        print("host-elf-links: " + f, file=sys.stderr)
    if fails:
        return 1
    print("host-elf-links: %d shipped host ELF(s), every DT_NEEDED on the allowlist, "
         "no daemon embeds libstdc++" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
