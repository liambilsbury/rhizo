#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

ID_DERIVED_RE = re.compile(r"port\s*=\s*[^;]*\bid\b[^;]*%[^;]*;")
ALLOC_RE = re.compile(r"freePorts_\s*\.\s*(?:erase|extract)\s*\(")
RELEASE_RE = re.compile(r"freePorts_\s*\.\s*insert\s*\(")
REFUSE_RE = re.compile(r"freePorts_\s*\.\s*empty\s*\(\s*\)")
AWAIT_RE = re.compile(r"awaitingSfRelease_")
ORPHAN_RE = re.compile(r"orphanedPorts_")


def strip_c_comments(text):
    """drop whole-line // comments from C source"""
    out = []
    for line in text.split("\n"):
        if line.strip().startswith("//"):
            continue
        out.append(line)
    return "\n".join(out)


def check_composer(text):
    """return port lifetime failures in the composer source"""
    code = strip_c_comments(text)
    failures = []
    m = ID_DERIVED_RE.search(code)
    if m:
        failures.append(("ID-DERIVED-PORT",
                         "a display port is computed from the display id: %s"
                         % m.group(0).strip()))
    if not REFUSE_RE.search(code):
        failures.append(("NO-REFUSAL",
                         "nothing tests freePorts_.empty()"))
    if not ALLOC_RE.search(code):
        failures.append(("NO-ALLOC",
                         "no port is ever taken out of freePorts_"))
    if not RELEASE_RE.search(code):
        failures.append(("NO-RELEASE",
                         "no port is ever put back into freePorts_"))
    if not AWAIT_RE.search(code):
        failures.append(("NO-RELEASE-WAIT",
                         "nothing tracks the release SurfaceFlinger owes for a disconnected "
                         "display"))
    if not ORPHAN_RE.search(code):
        failures.append(("NO-ORPHAN-RECORD",
                         "a display SurfaceFlinger never releases has nowhere to leave its "
                         "port"))
    for m in RELEASE_RE.finditer(code):
        before = code[max(0, m.start() - 400):m.start()]
        if "returnPort" not in before:
            failures.append(("PORT-RETURNED-UNCONDITIONALLY",
                             "a port goes back into freePorts_ with no returnPort system test above "
                             "it"))
    return failures


SELFTEST_GOOD = """
      if (freePorts_.empty()) {
        klogf("AddDisplay: refusing -- all 8 external input ports are in use");
        return -1;
      }
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      ds.port = port;
...
      AwaitingRelease& ar = awaitingSfRelease_[id];
      if (!returnPort && taken.port >= 1) orphanedPorts_[id] = taken.port;
    if (taken.port >= 1 && returnPort) {
      std::lock_guard<std::mutex> lg(mutex_);
      freePorts_.insert(taken.port);
    } else if (taken.port >= 1) {
      LifecycleKlogf(id, "SF-ORPHANED port=%d withheld", taken.port);
    }
"""

SELFTEST_UNCONDITIONAL_RETURN = """
      if (freePorts_.empty()) return -1;
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      ds.port = port;
...
    if (taken.port >= 1) {
      std::lock_guard<std::mutex> lg(mutex_);
      freePorts_.insert(taken.port);
    }
"""

SELFTEST_NO_ORPHAN_RECORD = SELFTEST_GOOD.replace(
    "      if (!returnPort && taken.port >= 1) orphanedPorts_[id] = taken.port;\n", "")

SELFTEST_MODULO = """
      port = 1 + static_cast<int32_t>((id - kPrimaryDisplayId - 1) % 8);
      ds.port = port;
"""

SELFTEST_NO_RELEASE = """
      if (freePorts_.empty()) return -1;
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      ds.port = port;
"""

SELFTEST_NO_REFUSAL = """
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      ds.port = port;
      freePorts_.insert(taken.port);
"""

SELFTEST_MODULO_COMMENTED = """
      // ports used to cycle: port = 1 + ((id - kPrimaryDisplayId - 1) % 8);
      port = 1 + static_cast<int32_t>((id - kPrimaryDisplayId - 1) % 8);
      if (freePorts_.empty()) return -1;
      freePorts_.erase(freePorts_.begin());
      freePorts_.insert(1);
"""


def selftest():
    """check each source shape against the findings it must produce"""
    cases = [
        ("the real shape", SELFTEST_GOOD, set()),
        ("the id-derived modulo", SELFTEST_MODULO, {"ID-DERIVED-PORT"}),
        ("allocates but never releases", SELFTEST_NO_RELEASE, {"NO-RELEASE"}),
        ("releases but never refuses", SELFTEST_NO_REFUSAL, {"NO-REFUSAL"}),
        ("modulo with an explanatory comment above it", SELFTEST_MODULO_COMMENTED,
         {"ID-DERIVED-PORT"}),
        ("the port returned on this side's own schedule", SELFTEST_UNCONDITIONAL_RETURN,
         {"PORT-RETURNED-UNCONDITIONALLY", "NO-RELEASE-WAIT", "NO-ORPHAN-RECORD"}),
        ("an unreleased display's port with nowhere to go", SELFTEST_NO_ORPHAN_RECORD,
         {"NO-ORPHAN-RECORD"}),
    ]
    for label, text, want in cases:
        got = {rule for rule, _d in check_composer(text)}
        if not want.issubset(got) or (not want and got):
            print("SELFTEST FAILED: %s -- wanted %s, got %s"
                  % (label, sorted(want) or "no findings", sorted(got)), file=sys.stderr)
            return 1
    print("selftest ok: accepts the real allocator, and catches the id-derived modulo "
          "(bare and comment-shadowed), an allocator that never returns a port, one that "
          "wraps instead of refusing, one that returns a port before SurfaceFlinger has "
          "released the display, and one with nowhere to leave an unreleased port")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(COMPOSER):
        print("display-port-lifetime.py: %s not found" % COMPOSER, file=sys.stderr)
        return 1
    failures = check_composer(open(COMPOSER).read())
    if failures:
        print("display ports are not allocated for the life of a display:", file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("display ports are taken per live display and given back only once "
          "SurfaceFlinger has released it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
