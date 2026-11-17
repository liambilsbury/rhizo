#!/usr/bin/env python3
"""android.hardware.security.keymint-service relink with static libraries"""
import contextlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

USAGE = """relink-keymint-static.py <AOSP_DIR> <OUT_SERVICE_BIN> [x86_64|aarch64]
relink-keymint-static.py --selftest"""

LLNDK_NEEDED = ("libbinder_ndk.so", "liblog.so", "libc.so", "libm.so", "libdl.so")
NON_CFI_SHARED = ("libcrypto.so", "libc++.so")
SHARED_NEEDED = LLNDK_NEEDED + NON_CFI_SHARED

STATIC_CLOSURE = (
    ("system/keymaster/libkeymint", "libkeymint", True),
    ("system/keymaster/lib_android_keymaster_keymint_utils", "lib_android_keymaster_keymint_utils", True),
    ("system/keymaster/libpuresoftkeymasterdevice", "libpuresoftkeymasterdevice", True),
    ("system/keymaster/libkeymaster_portable", "libkeymaster_portable", True),
    ("system/keymaster/libsoft_attestation_cert", "libsoft_attestation_cert", True),
    ("system/keymaster/libcppcose_rkp", "libcppcose_rkp", True),
    ("hardware/interfaces/security/keymint/aidl/android.hardware.security.keymint-V4-ndk",
     "android.hardware.security.keymint-V4-ndk", True),
    ("hardware/interfaces/security/rkp/aidl/android.hardware.security.rkp-V3-ndk",
     "android.hardware.security.rkp-V3-ndk", True),
    ("hardware/interfaces/security/sharedsecret/aidl/android.hardware.security.sharedsecret-V1-ndk",
     "android.hardware.security.sharedsecret-V1-ndk", True),
    ("hardware/interfaces/security/secureclock/aidl/android.hardware.security.secureclock-V1-ndk",
     "android.hardware.security.secureclock-V1-ndk", True),
    ("system/libcppbor/libcppbor", "libcppbor", True),
    ("system/libbase/libbase", "libbase", True),
)


def sh(cmd, cwd):
    """run a shell command and return the command stdout"""
    r = subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"[relink-keymint-static] {cmd} failed", file=sys.stderr)
        print(r.stdout[-4000:], file=sys.stderr)
        print(r.stderr[-4000:], file=sys.stderr)
        sys.exit(1)
    return r.stdout


def die(msg):
    """print an error and exit 1"""
    print(f"[relink-keymint-static] {msg}", file=sys.stderr)
    sys.exit(1)


def check_closure(closure):
    """return the non-CFI archives of a closure"""
    return [name for _, name, cfi in closure if not cfi]


def archives(variant, closure=STATIC_CLOSURE):
    """return the static archive paths of the closure"""
    non_cfi = check_closure(closure)
    if non_cfi:
        die(f"STATIC_CLOSURE has non-CFI archives {', '.join(non_cfi)}")
    return [f"out/soong/.intermediates/{d}/android_vendor_{variant}_static_cfi/{name}.a"
            for d, name, _ in closure]


def get_link_command(aosp_dir, ninja_file, target):
    """return the final ninja link command"""
    out = sh(f"ninja -f {ninja_file} -t commands {target}", cwd=aosp_dir)
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        die(f"no ninja commands for {target}")
    return lines[-1]


def static_rsp(tokens, static):
    """replace shared libraries with the static closure"""
    builtins = next((t for t in tokens if re.search(r"/libclang_rt\.builtins-[^/]+-android\.a$", t)), None)
    if not builtins:
        die("the link rsp has no libclang_rt.builtins-*-android.a")
    ubsan = re.sub(r"builtins(-[^/]+-android\.a)$", r"ubsan_minimal\1", builtins)
    shared = [t for t in tokens if t.endswith(".so")]
    dropped = sorted(os.path.basename(t) for t in shared if os.path.basename(t) not in SHARED_NEEDED)
    kept_shared = [t for t in shared if os.path.basename(t) in SHARED_NEEDED]
    missing = sorted(set(SHARED_NEEDED) - {os.path.basename(t) for t in kept_shared})
    if missing:
        die(f"the link rsp has no {', '.join(missing)}")
    rest = [t for t in tokens if not t.endswith(".so")]
    group = ["-Wl,--start-group"] + static + [ubsan] + ["-Wl,--end-group"]
    return rest + group + kept_shared, dropped, [ubsan]


def llndk_names(aosp_dir, product_out):
    """return the libraries in llndk.libraries.txt of the checkout"""
    p = os.path.join(aosp_dir, "out/target/product", product_out, "system/etc/llndk.libraries.txt")
    try:
        with open(p) as f:
            return {l.strip() for l in f if l.strip()}
    except OSError:
        die(f"failed to read {p}")


def dyn_syms(path):
    """return the undefined and defined dynamic symbols"""
    und, dfn = set(), set()
    out = subprocess.run(["readelf", "-sW", "--dyn-syms", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0][:-1].isdigit():
            continue
        n = f[7].split("@")[0]
        if n:
            (und if f[6] == "UND" else dfn).add((n, f[4]))
    return und, dfn


def needed(path):
    """return the NEEDED libraries of an ELF file"""
    out = subprocess.run(["readelf", "-dW", path], capture_output=True, text=True).stdout
    return [l.split("[", 1)[1].split("]", 1)[0] for l in out.splitlines() if "(NEEDED)" in l]


CODE = ("FUNC", "IFUNC", "GNU_IFUNC")
_LTO_SUFFIX = re.compile(r"(?:\.cfi_jt|\.cfi|\.llvm\.\d+)+$")


def defined_functions(path):
    """return the functions an ELF file defines"""
    out = subprocess.run(["readelf", "-sW", path], capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0][:-1].isdigit() or f[6] == "UND" or f[3] not in CODE:
            continue
        n = _LTO_SUFFIX.sub("", f[7].split("@")[0])
        if n:
            names.add(n)
    return names


def verify_problems(aosp_dir, linked, shared_stubs, llndk):
    """return the problems found in a linked service"""
    problems = []
    got = needed(linked)
    bad = [n for n in got if n not in SHARED_NEEDED or (n in LLNDK_NEEDED and n not in llndk)]
    if bad:
        problems.append(("NEEDED-NOT-SHARED", f"{linked} NEEDED has {', '.join(bad)} "
                         "outside LLNDK and NON_CFI_SHARED"))
    absent = [n for n in NON_CFI_SHARED if n not in got]
    if absent:
        problems.append(("NON-CFI-NOT-NEEDED", f"{linked} NEEDED has no {', '.join(absent)}"))
    rp = subprocess.run(["readelf", "-dW", linked], capture_output=True, text=True).stdout
    if "(RUNPATH)" in rp or "(RPATH)" in rp:
        problems.append(("RUNPATH", f"{linked} has a RUNPATH or RPATH"))
    stubs = {os.path.basename(s): os.path.join(aosp_dir, s) for s in shared_stubs}
    own = defined_functions(linked)
    for lib in NON_CFI_SHARED:
        if lib not in stubs:
            problems.append(("NON-CFI-NO-STUB", f"the link has no {lib} stub"))
            continue
        copied = sorted(own & {n for n, _ in dyn_syms(stubs[lib])[1]})
        if copied:
            problems.append(("NON-CFI-LINKED-IN", f"{linked} defines {len(copied)} functions that {lib} "
                             f"exports ({', '.join(copied[:10])})"))
    provided = set()
    for stub in stubs.values():
        provided |= {n for n, _ in dyn_syms(stub)[1]}
    und = {n for n, bind in dyn_syms(linked)[0] if bind != "WEAK"}
    unresolved = sorted(und - provided)
    if unresolved:
        problems.append(("UNRESOLVED", f"{linked} imports {len(unresolved)} symbols undefined in the "
                         f"NEEDED libraries ({', '.join(unresolved[:10])})"))
    return problems, got, len(und)


def verify(aosp_dir, linked, shared_stubs, llndk):
    """verify the linked service"""
    problems, got, n_und = verify_problems(aosp_dir, linked, shared_stubs, llndk)
    if problems:
        die(", ".join(f"{c} ({m})" for c, m in problems))
    return got, n_und


def main():
    """relink the keymint service with static libraries"""
    if len(sys.argv) not in (3, 4):
        print(__doc__ + "\n" + USAGE, file=sys.stderr)
        sys.exit(2)
    aosp_dir, out_service = sys.argv[1:3]
    arch = sys.argv[3] if len(sys.argv) == 4 else "x86_64"
    if arch == "x86_64":
        product, variant, product_out = "aosp_x86_64", "x86_64", "generic_x86_64"
    elif arch == "aarch64":
        product, variant, product_out = "aosp_arm64", "arm64_armv8-a", "generic_arm64"
    else:
        die(f"unknown ARCH {arch}, expected x86_64 or aarch64")
    ninja_file = f"out/combined-{product}.ninja"
    llndk = llndk_names(aosp_dir, product_out)
    not_llndk = [n for n in LLNDK_NEEDED if n not in llndk]
    if not_llndk:
        die(f"llndk.libraries.txt has no {', '.join(not_llndk)}")

    static = archives(variant)
    sh(f"ninja -f {ninja_file} " + " ".join(static), cwd=aosp_dir)

    target = ("out/soong/.intermediates/hardware/interfaces/security/keymint/aidl/default/"
              "android.hardware.security.keymint-service/"
              f"android_vendor_{variant}_cfi/unstripped/android.hardware.security.keymint-service")
    cmd = get_link_command(aosp_dir, ninja_file, target)
    rsp_tok = next((t for t in cmd.split() if t.startswith("@") and t.endswith(".rsp")), None)
    if not rsp_tok or f"-o {target}" not in cmd:
        die(f"the link command for {target} has no .rsp or no -o {target}")
    with open(os.path.join(aosp_dir, rsp_tok[1:])) as f:
        tokens = f.read().split()
    new_tokens, dropped, runtimes = static_rsp(tokens, static)
    for p in static + runtimes:
        if not os.path.isfile(os.path.join(aosp_dir, p)):
            die(f"no static input {p}")

    tmp = tempfile.mkdtemp(prefix="rhizo-relink-keymint-")
    new_rsp = os.path.join(tmp, "service.rsp")
    with open(new_rsp, "w") as f:
        f.write(" ".join(new_tokens))
    linked = os.path.join(tmp, "rhizo-keymint-service.linked")
    sh(cmd.replace(rsp_tok, f"@{new_rsp}").replace(f"-o {target}", f"-o {linked}"), cwd=aosp_dir)

    got, n_und = verify(aosp_dir, linked, [t for t in new_tokens if t.endswith(".so")], llndk)

    strip_tool = sh("find prebuilts/clang/host/linux-x86 -maxdepth 3 -iname llvm-strip | head -1",
                    cwd=aosp_dir).strip()
    sh(f"cp {linked} {linked}.stripped && {strip_tool} --strip-all {linked}.stripped", cwd=aosp_dir)
    sh(f"cp --remove-destination {linked}.stripped {out_service}", cwd=aosp_dir)
    os.chmod(out_service, 0o755)
    sh(f"rm -rf {tmp}", cwd=aosp_dir)
    print(f"[relink-keymint-static] wrote {out_service} NEEDED={','.join(got)} "
          f"imports={n_und} static={','.join(sorted(dropped))}")


def elf_fixtures(tmp):
    """build stub libraries and test executables"""
    marker = "__attribute__((weak)) char __llvm_fs_discriminator__;\n"
    src = {"libcrypto.so": "void CMAC_CTX_free(void *p) { (void)p; }\n" + marker,
           "libc++.so": "void *_Znwm(unsigned long n) { (void)n; return 0; }\n" + marker}
    cc = ["cc", "-nostdlib", "-fno-stack-protector", "-fPIC"]
    for lib in SHARED_NEEDED:
        body = src.get(lib, "void %s_fn(void) {}\n" % re.sub(r"\W", "_", lib))
        with open(os.path.join(tmp, lib + ".c"), "w") as f:
            f.write(body)
        r = subprocess.run(cc + ["-shared", "-Wl,-soname," + lib, "-o", os.path.join(tmp, lib),
                                 os.path.join(tmp, lib + ".c")], capture_output=True, text=True)
        if r.returncode != 0:
            return f"cc {lib} failed ({r.stderr.strip()[:300]})"
    calls = ("extern void CMAC_CTX_free(void *);\nextern void *_Znwm(unsigned long);\n" + marker
             + "void _start(void) { CMAC_CTX_free(_Znwm(1)); }\n")
    exes = {
        "complete": (calls, SHARED_NEEDED),
        "no-libcrypto": ("extern void *_Znwm(unsigned long);\n"
                         "void _start(void) { (void)_Znwm(1); }\n",
                         tuple(n for n in SHARED_NEEDED if n != "libcrypto.so")),
        "static-copy": ("__attribute__((used)) static void CMAC_CTX_free(void *p) { (void)p; }\n"
                        "void *cxx_new(unsigned long n) __asm__(\"_Znwm.cfi\");\n"
                        "void *cxx_new(unsigned long n) { (void)n; return 0; }\n"
                        "void _start(void) { CMAC_CTX_free(cxx_new(1)); }\n", SHARED_NEEDED),
    }
    out = {}
    for case, (body, libs) in exes.items():
        with open(os.path.join(tmp, case + ".c"), "w") as f:
            f.write(body)
        out[case] = os.path.join(tmp, case)
        r = subprocess.run(cc + ["-o", out[case], os.path.join(tmp, case + ".c"), "-Wl,--no-as-needed"]
                           + [os.path.join(tmp, lib) for lib in libs], capture_output=True, text=True)
        if r.returncode != 0:
            return f"cc {case} failed ({r.stderr.strip()[:300]})"
    return list(SHARED_NEEDED), out


def selftest():
    """test the link and verify functions"""
    fails = []
    if check_closure(STATIC_CLOSURE):
        fails.append(f"check_closure(STATIC_CLOSURE) == [] ({check_closure(STATIC_CLOSURE)})")
    bad = STATIC_CLOSURE + (("external/boringssl/libcrypto_static", "libcrypto_static", False),)
    if check_closure(bad) != ["libcrypto_static"]:
        fails.append(f"check_closure(bad) == ['libcrypto_static'] ({check_closure(bad)})")
    so = "out/soong/.intermediates/x/{}/android_vendor_x86_64_shared/{}"
    tokens = (["main.o", "prebuilts/clang/c/android_libc++/platform/x86_64/lib/libc++demangle.a",
               "prebuilts/clang/c/lib/clang/21/lib/linux/libclang_rt.builtins-x86_64-android.a"]
              + [so.format(n, n) for n in SHARED_NEEDED + ("libkeymint.so", "libutils.so")])
    new, dropped, runtimes = static_rsp(tokens, ["libkeymint.a"])
    kept = sorted(os.path.basename(t) for t in new if t.endswith(".so"))
    if kept != sorted(SHARED_NEEDED):
        fails.append(f"kept {kept} == {sorted(SHARED_NEEDED)}")
    if dropped != ["libkeymint.so", "libutils.so"]:
        fails.append(f"dropped {dropped} == ['libkeymint.so', 'libutils.so']")
    linked_in = [t for t in new if t.endswith(".a")]
    for name in ("libc++_static.a", "libc++abi.a", "libcrypto_static.a"):
        if any(t.endswith("/" + name) or t == name for t in linked_in):
            fails.append(f"{name} in linked_in")
    if "libkeymint.a" not in linked_in or not any("ubsan_minimal" in t for t in linked_in):
        fails.append(f"libkeymint.a and ubsan_minimal in linked_in ({linked_in})")
    tmp = tempfile.mkdtemp(prefix="relink-keymint-selftest.")
    try:
        built = elf_fixtures(tmp)
        if isinstance(built, str):
            fails.append(f"elf_fixtures() failed ({built})")
        else:
            stubs, exes = built
            for case, want, names in (
                    ("complete", set(), ()),
                    ("no-libcrypto", {"NON-CFI-NOT-NEEDED"}, ("libcrypto.so",)),
                    ("static-copy", {"NON-CFI-LINKED-IN"}, ("CMAC_CTX_free", "_Znwm"))):
                problems, _, _ = verify_problems(tmp, exes[case], stubs, set(LLNDK_NEEDED))
                got = {c for c, _ in problems}
                text = " ".join(m for _, m in problems)
                if got != want or any(n not in text for n in names):
                    fails.append(f"verify_problems({case}) {problems} == {sorted(want)} "
                                 f"with {', '.join(names) or 'nothing'}")
            said = io.StringIO()
            try:
                with contextlib.redirect_stderr(said):
                    verify(tmp, exes["static-copy"], stubs, set(LLNDK_NEEDED))
                fails.append("verify(static-copy) raises SystemExit")
            except SystemExit:
                if "NON-CFI-LINKED-IN" not in said.getvalue():
                    fails.append(f"verify(static-copy) stderr has NON-CFI-LINKED-IN ({said.getvalue()})")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print(f"FAIL {f}")
    print(("FAIL" if fails else "ok") + " relink-keymint-static.py --selftest")
    return 1 if fails else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    main()
