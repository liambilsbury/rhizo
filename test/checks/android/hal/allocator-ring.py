#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-allocator", "src", "allocator.cpp")

RING_KEYS = ("ino=", "id=", "pid=", "size=", "usage=", "fmt=", "name=")


def strip_comments(text):
    """remove C++ comments from the text"""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            i = text.find("\n", i)
            if i == -1:
                i = n
            continue
        if two == "/*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        c = text[i]
        if c in ('"', "'"):
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                done = text[i] == c
                i += 1
                if done:
                    break
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(text):
    """check the allocator's ring record write order"""
    text = strip_comments(text)
    failures = []

    fd_m = re.search(r"gbm_bo_get_fd\(bo\)", text)
    fstat_m = re.search(r"\bfstat\(", text)
    encode_m = re.search(r"rhizo::Encode\(", text)

    if not fd_m:
        failures.append(("NO-GET-FD", "gbm_bo_get_fd(bo) not found"))
    if not fstat_m:
        failures.append(("NO-FSTAT", "no fstat() call"))
    if not encode_m:
        failures.append(("NO-ENCODE", "rhizo::Encode( not found"))
    if fd_m and fstat_m and encode_m and not (fd_m.start() < fstat_m.start() < encode_m.start()):
        failures.append(("FSTAT-OUT-OF-ORDER", "fstat() does not sit between "
                         "gbm_bo_get_fd(bo) and rhizo::Encode("))

    if not re.search(r'getenv\("RHIZO_ALLOC_RING"\)', text):
        failures.append(("NO-TEST", 'no getenv("RHIZO_ALLOC_RING")'))

    klog_m = re.search(r'"alloc ino=[^"]*"', text)
    if not klog_m:
        failures.append(("NO-RING-KLOG", 'no klog format string starting "alloc ino="'))
    else:
        line = klog_m.group(0)
        for key in RING_KEYS:
            if not re.search(r"\b" + re.escape(key), line):
                failures.append((f"MISSING-KEY-{key.rstrip('=')}", 'the "alloc ino=" klog '
                                 f'format string is missing "{key}"'))

    return failures


GOOD_SRC = """
bool AllocRingEnabled() { return getenv("RHIZO_ALLOC_RING") != nullptr; }
int boFd = gbm_bo_get_fd(bo);
if (boFd < 0) { return -1; }
ino_t allocRingIno = 0;
if (AllocRingEnabled()) {
  struct stat st{};
  if (fstat(boFd, &st) == 0) allocRingIno = st.st_ino;
}
native_handle_t* nh = rhizo::Encode(boFd, width, height);
if (AllocRingEnabled()) {
  char buf[256];
  snprintf(buf, sizeof(buf),
           "alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s",
           (unsigned long long)allocRingIno, (unsigned long long)bufferId,
           AIBinder_getCallingPid(), (unsigned long long)allocSize, (unsigned long long)usage,
           width, height, pixelFormat, (int)nameLen, name);
  klog(buf);
}
"""

BAD_NO_FSTAT = GOOD_SRC.replace(
    "  struct stat st{};\n  if (fstat(boFd, &st) == 0) allocRingIno = st.st_ino;\n", "")
BAD_FSTAT_AFTER_ENCODE = GOOD_SRC.replace(
    "ino_t allocRingIno = 0;\nif (AllocRingEnabled()) {\n  struct stat st{};\n"
    "  if (fstat(boFd, &st) == 0) allocRingIno = st.st_ino;\n}\n"
    "native_handle_t* nh = rhizo::Encode(boFd, width, height);\n",
    "ino_t allocRingIno = 0;\n"
    "native_handle_t* nh = rhizo::Encode(boFd, width, height);\n"
    "if (AllocRingEnabled()) {\n  struct stat st{};\n"
    "  if (fstat(boFd, &st) == 0) allocRingIno = st.st_ino;\n}\n")
BAD_NO_TEST = GOOD_SRC.replace('getenv("RHIZO_ALLOC_RING")', 'getenv("SOMETHING_ELSE")')
BAD_MISSING_ID_KEY = GOOD_SRC.replace(
    '"alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s"',
    '"alloc ino=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s"')
BAD_MISSING_NAME_KEY = GOOD_SRC.replace(
    '"alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s"',
    '"alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x"')
BAD_NO_KLOG = GOOD_SRC.replace(
    'if (AllocRingEnabled()) {\n  char buf[256];\n  snprintf(buf, sizeof(buf),\n'
    '           "alloc ino=%llu id=%llu pid=%d size=%llu usage=0x%llx %dx%d fmt=0x%x name=%.*s",\n'
    '           (unsigned long long)allocRingIno, (unsigned long long)bufferId,\n'
    '           AIBinder_getCallingPid(), (unsigned long long)allocSize, (unsigned long long)usage,\n'
    '           width, height, pixelFormat, (int)nameLen, name);\n  klog(buf);\n}\n', "")


def selftest():
    """check each source shape against whether it must pass"""
    cases = [
        ("fully wired", GOOD_SRC, True),
        ("no fstat at all", BAD_NO_FSTAT, False),
        ("fstat moved past Encode", BAD_FSTAT_AFTER_ENCODE, False),
        ("getenv system test renamed away from RHIZO_ALLOC_RING", BAD_NO_TEST, False),
        ("klog format string missing id=", BAD_MISSING_ID_KEY, False),
        ("klog format string missing name=", BAD_MISSING_NAME_KEY, False),
        ("the ring klog call deleted entirely", BAD_NO_KLOG, False),
    ]
    failed = False
    for name, src, want_clean in cases:
        got_clean = not check(src)
        if got_clean != want_clean:
            print(f"SELFTEST FAIL: {name} -- expected clean={want_clean}, got clean={got_clean}")
            failed = True
    if failed:
        return 1
    print("selftest ok: every fixture behaves as expected")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(SRC_PATH) as f:
        text = f.read()
    failures = check(text)
    if failures:
        for code, msg in failures:
            print(f"{code}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
