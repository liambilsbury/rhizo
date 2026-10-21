#!/usr/bin/env python3
import os
import subprocess
import sys
import glob


def tree(m):
    """return the system directory of a mounted image"""
    return os.path.join(m, "system") if os.path.isdir(os.path.join(m, "system", "lib64")) else m


def is_elf(p):
    """return whether a file starts with the ELF magic"""
    try:
        with open(p, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def readelf(args, path):
    """return the readelf output for a file"""
    try:
        return subprocess.run(["readelf", *args, path], capture_output=True,
                               text=True, timeout=180).stdout
    except OSError:
        return ""


def needed(path):
    """return the shared libraries a file needs"""
    return [l.split("[", 1)[1].split("]", 1)[0]
            for l in readelf(["-dW"], path).splitlines()
            if "(NEEDED)" in l and "[" in l]


def syms(path):
    """return imported and exported dynamic symbol names"""
    und, dfn = set(), set()
    for line in readelf(["-sW", "--dyn-syms"], path).splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":"):
            continue
        n = f[7].split("@")[0]
        if not n:
            continue
        if f[6] == "UND":
            if f[4] != "WEAK":
                und.add(n)
        else:
            dfn.add(n)
    return und, dfn


def index(root):
    """map each soname to its path"""
    prov = {}
    for sub in ("lib64", "system_ext/lib64", "product/lib64", "lib64/vndk-sp", "lib64/egl", "lib64/hw"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for p in glob.glob(os.path.join(d, "*.so")):
            prov.setdefault(os.path.basename(p), p)
    return prov


def target_und(tgt):
    """return undefined symbols of the target binaries"""
    und = set()
    for d in ("lib64", "bin", "system_ext/lib64"):
        p = os.path.join(tgt, d)
        try:
            entries = sorted(os.listdir(p))
        except OSError:
            continue
        for f in entries[:500]:
            fp = os.path.join(p, f)
            try:
                if os.path.isfile(fp) and is_elf(fp):
                    und |= syms(fp)[0]
            except OSError:
                continue
    return und


def ndk_bionic_syms(sysroot_lib_dir):
    """return the symbols in the NDK bionic stubs"""
    syms_ = set()
    if not sysroot_lib_dir or not os.path.isdir(sysroot_lib_dir):
        return syms_
    for n in ("libc.so", "libm.so", "libdl.so", "libc++_shared.so"):
        p = os.path.join(sysroot_lib_dir, n)
        if os.path.isfile(p):
            syms_ |= syms(p)[1]
    return syms_


def check(our_dir, tgt_root, ndk_sysroot_lib_dir=None):
    """check the ELF binaries against the target tree"""
    tgt = tree(tgt_root)
    our = sorted(p for p in glob.glob(os.path.join(our_dir, "*")) if os.path.isfile(p) and is_elf(p))
    if not our:
        print(f"SKIP: no ELF binaries at {our_dir}")
        return 0

    ptgt = index(tgt)
    stgt = set()
    for p in ptgt.values():
        stgt |= syms(p)[1]
    for so, p in {os.path.basename(p): p for p in our}.items():
        ptgt.setdefault(so, p)
        stgt |= syms(p)[1]
    tund = target_und(tgt)
    tund |= ndk_bionic_syms(ndk_sysroot_lib_dir)

    lost_lib, lost_sym = [], []
    for b in our:
        name = os.path.basename(b)
        for so in needed(b):
            if so not in ptgt:
                lost_lib.append((name, so))
        und, _ = syms(b)
        for s in und:
            if s not in stgt and s not in tund:
                lost_sym.append((name, s))

    print("=== arm64 static ABI check: our binaries -> a16-arm64 ===")
    print(f"our arm64 ELFs checked : {len(our)}")
    print(f"libs indexed in target : {len(ptgt)}")
    print(f"target's own UND set   : {len(tund)} symbols (filters APEX-provided bionic/libc++)")

    ok = True
    if lost_lib:
        ok = False
        print(f"\nLIBRARIES OUR ARM64 BINARIES NEED BUT a16-arm64 DOES NOT SHIP ({len(lost_lib)}):")
        for n, so in sorted(set(lost_lib)):
            print(f"  {n}: needs {so}")
    if lost_sym:
        ok = False
        print(f"\nSYMBOLS OUR ARM64 BINARIES IMPORT BUT a16-arm64 DOES NOT EXPORT ({len(lost_sym)}):")
        by = {}
        for n, s in lost_sym:
            by.setdefault(n, []).append(s)
        for n in sorted(by):
            for s in sorted(by[n])[:15]:
                print(f"  {n}: {s}")
            if len(by[n]) > 15:
                print(f"  {n}: ... and {len(by[n]) - 15} more")

    if ok:
        print("\nCLEAN: every needed library and imported symbol resolves against a16-arm64.")
        return 0
    print("\nNOT CLEAN -- see the gaps above.")
    return 1


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
DEFAULT_NDK_SYSROOT_LIB = os.path.join(
    _REPO_ROOT, "toolchain", "ndk_extract", "android-ndk-r27c", "toolchains",
    "llvm", "prebuilt", "linux-x86_64", "sysroot", "usr", "lib",
    "aarch64-linux-android", "35")

if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print("usage: abi-arm64.py <our_dir> <tgt_root> [ndk_sysroot_lib_dir]", file=sys.stderr)
        sys.exit(2)
    ndk_dir = sys.argv[3] if len(sys.argv) == 4 else DEFAULT_NDK_SYSROOT_LIB
    sys.exit(check(sys.argv[1], sys.argv[2], ndk_dir))
