#!/usr/bin/env python3
# fail when the gralloc mapper has exit-time destructors
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
MAPPER = os.path.join(ROOT, "src", "android", "hal", "gralloc-mapper", "src", "mapper.cpp")
BUILD = os.path.join(ROOT, "tools", "build", "hal", "mapper.sh")
CLANGXX = os.path.join(ROOT, "toolchain", "ndk_extract", "android-ndk-r27c", "toolchains", "llvm", "prebuilt",
                       "linux-x86_64", "bin", "x86_64-linux-android35-clang++")
HAL_INCLUDES = ("toolchain/gen/header", "toolchain/include_platform")
WARNING = "[-Wexit-time-destructors]"


def include_dirs():
    """return the include dirs hal.sh compiles the mapper with"""
    with open(BUILD) as f:
        extra = re.findall(r"--extra-inc\s+(\S+)", f.read())
    return [os.path.join(ROOT, d) for d in HAL_INCLUDES + tuple(extra)]


def exit_destructors(path):
    """return the compiler's exit-time destructor warnings for a source file"""
    cmd = [CLANGXX, "-fsyntax-only", "-std=c++17", "-fno-rtti", "-fPIC", "-DBINDER_STABILITY_SUPPORT",
           "-Wno-everything", "-Wexit-time-destructors"]
    for d in include_dirs():
        cmd += ["-I", d]
    cp = subprocess.run(cmd + [path], capture_output=True, text=True, timeout=300)
    if cp.returncode != 0:
        raise RuntimeError("%s does not compile:\n%s" % (path, cp.stderr))
    return [line for line in cp.stderr.splitlines() if WARNING in line]


FIXTURES = [
    ("namespace-scope mutex", "#include <mutex>\nstd::mutex g_mutex;\n", False),
    ("namespace-scope map", "#include <unordered_map>\nstd::unordered_map<int, int> g_map;\n", False),
    ("function-static mutex", "#include <mutex>\nstd::mutex& M() { static std::mutex m; return m; }\n", False),
    ("leaked mutex and map", "#include <mutex>\n#include <unordered_map>\nstd::mutex& g_mutex = *new std::mutex;\n"
     "std::unordered_map<int, int>& g_map = *new std::unordered_map<int, int>;\n", True),
    ("trivial statics", "static const bool on = true;\nint F() { static const int fd = 3; return fd; }\n", True),
]


def selftest():
    """check each fixture against its expected result"""
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        for i, (name, src, want_clean) in enumerate(FIXTURES):
            path = os.path.join(tmp, "f%d.cpp" % i)
            with open(path, "w") as f:
                f.write(src)
            got = exit_destructors(path)
            if (not got) != want_clean:
                print(f"SELFTEST FAIL: {name} -- expected clean={want_clean}, got {got}")
                failed = True
    if failed:
        return 1
    print("selftest ok: every fixture behaves as expected")
    return 0


def main():
    """fail when the mapper declares state that exit() destroys"""
    if "--selftest" in sys.argv:
        return selftest()
    found = exit_destructors(MAPPER)
    for line in found:
        print("EXIT-DESTRUCTOR: " + line.replace(ROOT + "/", ""))
    if found:
        print("libui frees buffers on binder threads during exit(): the mapper's state must not be destroyed")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
