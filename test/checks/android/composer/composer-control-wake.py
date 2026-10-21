#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

WAKE_CALL_SITES = (
    ("MISSING-WAKE-SHUTDOWN", "Shutdown()",
     r"void Shutdown\(\)\s*\{\s*shuttingDown_\.store\(true,\s*std::memory_order_release\);"
     r"\s*vsyncCv_\.notify_all\(\);", 80),
    ("MISSING-WAKE-REMOVAL", "the pendingRemovals_ queue site",
     r"pendingRemovals_\.push_back\(displayId\);\s*\}", 80),
    ("MISSING-WAKE-RESIZE", "the pendingResizes_ queue site",
     r"pendingResizes_\[displayId\]\s*=\s*\{[^{}]*\};\s*\}", 80),
    ("MISSING-WAKE-REFRESH", "the pendingRefresh_ queue site",
     r"pendingRefresh_\[displayId\]\s*=\s*refreshNs;\s*\}", 80),
)


def strip_comments(text):
    """drop comments from C++ source text"""
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
    """check the control thread wake wiring"""
    text = strip_comments(text)
    failures = []

    if "eventfd(" not in text:
        failures.append(("NO-EVENTFD", "no eventfd() call"))

    if re.search(r"poll\(&pfd,\s*1,\s*100\)", text):
        failures.append(("OLD-POLL-STILL-PRESENT", "poll(&pfd, 1, 100) is still in the source"))

    for code, label, anchor, window in WAKE_CALL_SITES:
        m = re.search(anchor, text)
        if not m:
            failures.append((code, f"{label} not found in the source"))
            continue
        if not re.search(r"WakeControlThread\(\)", text[m.end():m.end() + window]):
            failures.append((code, f"{label} does not call WakeControlThread() within "
                             f"{window} chars of queuing its work"))

    if not re.search(r"pendingResizes_\.begin\(\)", text):
        failures.append(("RESIZE-DUE-SCAN-MISSING", "no scan of pendingResizes_ for its own "
                         "dueNs"))

    anchor = re.search(r"int timeoutMs = controlWakeFd_ < 0 \? 100 : -1;", text)
    if not anchor:
        failures.append(("NO-TIMEOUT-EXPRESSION",
                         "the control thread's poll timeout is not computed from "
                         "-1-plus-what-is-due"))
    else:
        window = text[anchor.end():anchor.end() + 1400]
        scan = re.search(r"for\s*\([^)]*:\s*awaitingSfRelease_\s*\)\s*\{(.*?)\}", window, re.S)
        if not scan:
            failures.append(("RELEASE-DEADLINE-SCAN-MISSING",
                             "the poll timeout is computed without scanning "
                             "awaitingSfRelease_"))
        else:
            body = scan.group(1)
            if "deadlineNs" not in body:
                failures.append(("RELEASE-DEADLINE-IGNORED",
                                 "the awaitingSfRelease_ scan does not read deadlineNs"))
            if not re.search(r"timeoutMs\s*=\s*static_cast<int>", body):
                failures.append(("RELEASE-DEADLINE-NOT-APPLIED",
                                 "the awaitingSfRelease_ scan never shrinks timeoutMs"))

        held = re.search(r"for\s*\([^)]*:\s*heldRefresh_\s*\)\s*\{(.*?)\}", window, re.S)
        if not held:
            failures.append(("HELD-REFRESH-SCAN-MISSING",
                             "the poll timeout is computed without scanning heldRefresh_"))
        elif not re.search(r"timeoutMs\s*=\s*static_cast<int>", held.group(1)):
            failures.append(("HELD-REFRESH-NOT-APPLIED",
                             "the heldRefresh_ scan never shrinks timeoutMs"))

    apply_at = [m.start() for m in re.finditer(r"ApplyRefresh\(id,\s*refreshNs\)", text)]
    if not apply_at:
        failures.append(("REFRESH-APPLY-MISSING", "the control thread never applies a refresh change"))
    for at in apply_at:
        if not re.search(r"RefreshDueNs\(id\)", text[max(0, at - 400):at]):
            failures.append(("REFRESH-UNHELD", "ApplyRefresh(id, refreshNs) is not preceded by "
                             "RefreshDueNs(id)"))

    if not re.search(r"ServiceSfReleases\(\)", text):
        failures.append(("RELEASE-SERVICE-MISSING",
                         "the control thread never calls ServiceSfReleases()"))

    for want in ('PR_SET_NAME, "rhizo-control"', 'PR_SET_NAME, "rhizo-vsync"'):
        if want not in text:
            failures.append(("THREAD-UNNAMED", f'{want} missing'))

    return failures


GOOD_SRC = """
#include <sys/eventfd.h>
void vsync() { prctl(PR_SET_NAME, "rhizo-vsync"); }
void f() {
  prctl(PR_SET_NAME, "rhizo-control");
  controlWakeFd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  int timeoutMs = controlWakeFd_ < 0 ? 100 : -1;
  for (auto it = pendingResizes_.begin(); it != pendingResizes_.end(); ++it) { int x = 1; }
  for (const auto& [id, held] : heldRefresh_) {
    int64_t remainMs = (held.second - now + 999999) / 1000000;
    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
  }
  for (const auto& [id, ar] : awaitingSfRelease_) {
    int64_t remainMs = ar.released ? 0 : (ar.deadlineNs - now) / 1000000;
    if (remainMs < 0) remainMs = 0;
    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);
  }
  ServiceSfReleases();
  for (const auto& [id, refreshNs] : refreshes) {
    const int64_t due = RefreshDueNs(id);
    if (due > NowNanos()) continue;
    ApplyRefresh(id, refreshNs);
  }
  struct pollfd pfds[2] = {{fd, POLLIN, 0}, {controlWakeFd_, POLLIN, 0}};
  poll(pfds, 2, timeoutMs);
}
void Shutdown() {
    shuttingDown_.store(true, std::memory_order_release);
    vsyncCv_.notify_all();
    WakeControlThread();
}
void a() {
  {
    pendingRemovals_.push_back(displayId);
  }
  WakeControlThread();
}
void b() {
  {
    pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};
  }
  WakeControlThread();
}
void c() {
  {
    pendingRefresh_[displayId] = refreshNs;
  }
  WakeControlThread();
}
"""

BAD_NO_EVENTFD = GOOD_SRC.replace("eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)", "-1")
BAD_OLD_POLL = GOOD_SRC + "\nvoid old() { poll(&pfd, 1, 100); }\n"
BAD_NO_SHUTDOWN_WAKE = GOOD_SRC.replace(
    "    vsyncCv_.notify_all();\n    WakeControlThread();\n}",
    "    vsyncCv_.notify_all();\n}")
BAD_NO_REMOVAL_WAKE = GOOD_SRC.replace(
    "    pendingRemovals_.push_back(displayId);\n  }\n  WakeControlThread();",
    "    pendingRemovals_.push_back(displayId);\n  }")
BAD_NO_RESIZE_WAKE = GOOD_SRC.replace(
    "    pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};\n  }\n  WakeControlThread();",
    "    pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};\n  }")
BAD_NO_REFRESH_WAKE = GOOD_SRC.replace(
    "    pendingRefresh_[displayId] = refreshNs;\n  }\n  WakeControlThread();",
    "    pendingRefresh_[displayId] = refreshNs;\n  }")
BAD_NO_DUE_SCAN = GOOD_SRC.replace("pendingResizes_.begin()", "pendingResizesXX.begin()")
BAD_NO_RELEASE_SCAN = GOOD_SRC.replace(
    "  for (const auto& [id, ar] : awaitingSfRelease_) {\n"
    "    int64_t remainMs = ar.released ? 0 : (ar.deadlineNs - now) / 1000000;\n"
    "    if (remainMs < 0) remainMs = 0;\n"
    "    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);\n"
    "  }\n", "")
BAD_RELEASE_SCAN_INERT = GOOD_SRC.replace(
    "    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);\n"
    "  }\n  ServiceSfReleases();",
    "  }\n  ServiceSfReleases();")
BAD_NO_RELEASE_SERVICE = GOOD_SRC.replace("  ServiceSfReleases();\n", "")
BAD_NO_HELD_SCAN = GOOD_SRC.replace(
    "  for (const auto& [id, held] : heldRefresh_) {\n"
    "    int64_t remainMs = (held.second - now + 999999) / 1000000;\n"
    "    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);\n"
    "  }\n", "")
BAD_HELD_SCAN_INERT = GOOD_SRC.replace(
    "    int64_t remainMs = (held.second - now + 999999) / 1000000;\n"
    "    if (timeoutMs < 0 || remainMs < timeoutMs) timeoutMs = static_cast<int>(remainMs);\n",
    "    int64_t remainMs = (held.second - now + 999999) / 1000000;\n")
BAD_REFRESH_UNHELD = GOOD_SRC.replace(
    "    const int64_t due = RefreshDueNs(id);\n    if (due > NowNanos()) continue;\n", "")
BAD_UNNAMED = GOOD_SRC.replace('prctl(PR_SET_NAME, "rhizo-vsync");', "")

BAD_COMMENTED_SHUTDOWN = GOOD_SRC.replace(
    "    vsyncCv_.notify_all();\n    WakeControlThread();\n}",
    "    vsyncCv_.notify_all();\n    // WakeControlThread();\n}")
BAD_COMMENTED_REMOVAL = GOOD_SRC.replace(
    "    pendingRemovals_.push_back(displayId);\n  }\n  WakeControlThread();",
    "    pendingRemovals_.push_back(displayId);\n  }\n  // WakeControlThread();")
BAD_COMMENTED_RESIZE = GOOD_SRC.replace(
    "    pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};\n  }\n  WakeControlThread();",
    "    pendingResizes_[displayId] = {workW, workH, scale120, NowNanos()};\n  }\n  // WakeControlThread();")
BAD_COMMENTED_REFRESH = GOOD_SRC.replace(
    "    pendingRefresh_[displayId] = refreshNs;\n  }\n  WakeControlThread();",
    "    pendingRefresh_[displayId] = refreshNs;\n  }\n  /* WakeControlThread(); */")


def selftest():
    """check each source shape against whether it must pass"""
    cases = [
        ("fully wired", GOOD_SRC, True),
        ("no eventfd", BAD_NO_EVENTFD, False),
        ("old unconditional poll left in place", BAD_OLD_POLL, False),
        ("Shutdown() never wakes the control thread", BAD_NO_SHUTDOWN_WAKE, False),
        ("the removal queue site never wakes the thread", BAD_NO_REMOVAL_WAKE, False),
        ("the resize queue site never wakes the thread", BAD_NO_RESIZE_WAKE, False),
        ("the refresh queue site never wakes the thread", BAD_NO_REFRESH_WAKE, False),
        ("no due-time scan for the timeout", BAD_NO_DUE_SCAN, False),
        ("no scan of the awaited releases", BAD_NO_RELEASE_SCAN, False),
        ("the awaited-release scan never shrinks the timeout", BAD_RELEASE_SCAN_INERT, False),
        ("nothing services an awaited release", BAD_NO_RELEASE_SERVICE, False),
        ("no scan of the held refresh changes", BAD_NO_HELD_SCAN, False),
        ("the held-refresh scan never shrinks the timeout", BAD_HELD_SCAN_INERT, False),
        ("a refresh change applied without its hold", BAD_REFRESH_UNHELD, False),
        ("vsync thread left unnamed", BAD_UNNAMED, False),
        ("Shutdown()'s wake is commented out", BAD_COMMENTED_SHUTDOWN, False),
        ("the removal site's wake is commented out", BAD_COMMENTED_REMOVAL, False),
        ("the resize site's wake is commented out", BAD_COMMENTED_RESIZE, False),
        ("the refresh site's wake is block-commented out", BAD_COMMENTED_REFRESH, False),
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
