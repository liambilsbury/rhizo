#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal")
MAPPER = os.path.join(ROOT, "gralloc-mapper", "src", "mapper.cpp")
HEADER = os.path.join(ROOT, "common", "include", "rhizo/virtgpu_transfer.h")
FUNCS = ("lock", "unlock", "rereadLockedBuffer")


def body(text, signature):
    """return the block of the first matching definition"""
    m = re.search(signature, text)
    if not m:
        return None
    start = text.find("{", m.end())
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def check_mapper(text):
    """check the mapper's transfer error handling"""
    failures = []
    for name in FUNCS:
        fn = body(text, r"AIMapper_Error\s+%s\(" % name)
        if fn is None:
            failures.append(("MISSING", f"{name} not found"))
            continue
        gate = fn.find("VirtgpuTransferNeeded()")
        call = re.search(r"rhizo::VirtgpuTransfer(?:From|To)Host\(", fn)
        if gate < 0 or call is None or gate > call.start():
            failures.append(("UNGATED", f"{name} calls a transfer without VirtgpuTransferNeeded() before it"))
        log = fn.find("LogTransferFailure(")
        if log < 0:
            failures.append(("UNLOGGED", f"{name} never calls LogTransferFailure"))
        elif name != "unlock" and not re.search(r"LogTransferFailure\([^}]*return AIMAPPER_ERROR_NO_RESOURCES;", fn[log:]):
            failures.append(("SWALLOWED", f"{name} does not return NO_RESOURCES after LogTransferFailure"))
        if name == "unlock" and "xferFailed ? AIMAPPER_ERROR_NO_RESOURCES" not in fn:
            failures.append(("SWALLOWED", "unlock does not return NO_RESOURCES when the transfer failed"))
        before = fn[:call.start()] if call else ""
        if call and "=" not in before[before.rfind(";") + 1:] and "if (!" not in before[before.rfind(";") + 1:]:
            failures.append(("DROPPED", f"{name} ignores the transfer result"))
    return failures


def check_header(text):
    """check that OpenRenderNode refuses non-virtio nodes"""
    fn = body(text, r"inline int OpenRenderNode\(\)")
    if fn is None:
        return [("MISSING", "OpenRenderNode not found")]
    m = re.search(r"if \(!IsVirtgpuNode\(drmFd\)[^)]*\)[^{]*\{\s*close\(drmFd\);\s*return -1;", fn)
    return [] if m else [("BAREMETAL", "OpenRenderNode must close the fd and return -1 when the node is not virtio_gpu")]


GOOD_MAPPER = """
AIMapper_Error lock(a) { if ((u & R) && rhizo::VirtgpuTransferNeeded()) { bool ok = rhizo::VirtgpuTransferFromHost(a);
  if (!ok) { LogTransferFailure(ib, "lock"); munmap(a); return AIMAPPER_ERROR_NO_RESOURCES; } } return 0; }
AIMapper_Error unlock(a) { if (w && rhizo::VirtgpuTransferNeeded()) { bool ok = rhizo::VirtgpuTransferToHost(a);
  if (!ok) { LogTransferFailure(ib, "unlock"); xferFailed = true; } } return xferFailed ? AIMAPPER_ERROR_NO_RESOURCES : AIMAPPER_ERROR_NONE; }
AIMapper_Error rereadLockedBuffer(a) { if (x && rhizo::VirtgpuTransferNeeded()) { if (!rhizo::VirtgpuTransferFromHost(a)) {
  LogTransferFailure(ib, "r"); return AIMAPPER_ERROR_NO_RESOURCES; } } return 0; }
"""
GOOD_HEADER = """
inline int OpenRenderNode() { static const int fd = [] {
  int drmFd = open("x", 0); if (drmFd < 0) return -1;
  if (!IsVirtgpuNode(drmFd) || !InitVirglContext(drmFd)) { close(drmFd); return -1; }
  return drmFd; }(); return fd; }
"""


def selftest():
    """check each source shape against whether it must pass"""
    reread_bare = GOOD_MAPPER.replace("if (!rhizo::VirtgpuTransferFromHost(a))", "rhizo::VirtgpuTransferFromHost(a); if (0)")
    cases = [
        ("mapper wired", check_mapper(GOOD_MAPPER), True),
        ("reread drops the result", check_mapper(reread_bare), False),
        ("lock transfer ungated", check_mapper(GOOD_MAPPER.replace("(u & R) && rhizo::VirtgpuTransferNeeded()", "(u & R)")), False),
        ("unlock ungated only", check_mapper(GOOD_MAPPER.replace("(w && rhizo::VirtgpuTransferNeeded())", "(w)")), False),
        ("unlock returns success", check_mapper(GOOD_MAPPER.replace("xferFailed ? AIMAPPER_ERROR_NO_RESOURCES : ", "")), False),
        ("reread returns success after log", check_mapper(GOOD_MAPPER.replace('"r"); return AIMAPPER_ERROR_NO_RESOURCES', '"r"); return 0')), False),
        ("lock never logs", check_mapper(GOOD_MAPPER.replace('LogTransferFailure(ib, "lock")', "")), False),
        ("gate only in another function", check_mapper(GOOD_MAPPER.replace("(x && rhizo::VirtgpuTransferNeeded())", "(x)")), False),
        ("header closes non-virtio", check_header(GOOD_HEADER), True),
        ("header returns live fd", check_header(GOOD_HEADER.replace("!IsVirtgpuNode(drmFd) || ", "")), False),
    ]
    failed = False
    for name, failures, want_clean in cases:
        if (not failures) != want_clean:
            print(f"SELFTEST FAIL: {name} -- expected clean={want_clean}, got {failures}")
            failed = True
    if failed:
        return 1
    print("selftest ok: every fixture behaves as expected")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(MAPPER) as f:
        failures = check_mapper(f.read())
    with open(HEADER) as f:
        failures += check_header(f.read())
    for code, msg in failures:
        print(f"{code}: {msg}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
