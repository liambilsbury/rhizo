#!/usr/bin/env python3
"""A primary display with no Wayland surface gets input devices."""
import os
import re
import sys

USAGE = """Usage: composer-headless-input.py [--selftest]"""

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

UINPUT = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "input", "uinput.cpp")
RC = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "init", "composer.rc")

SIGNATURE = "void TryStartPrimaryWaylandSurface()"
LATCH = re.compile(r"compare_exchange_strong\(\s*expected\s*,\s*true\s*\)\s*\)\s*return\s*;")
POOL = re.compile(r"uinput_\.PreCreatePool\(\s*\)\s*;")
BIND = re.compile(r"uinput_\.Create\(\s*kPrimaryDisplayId\s*,\s*0\s*,")


def code_only(text):
    """blank comments and strings in C++ text"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)


def function_body(text, signature):
    """return the braced body of a function"""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find("{", start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


def conditional(body, pos):
    """detect a branch around a statement"""
    depth = body[:pos].count("{") - body[:pos].count("}")
    if depth != 1:
        return True
    prefix = body[:pos]
    boundary = max(prefix.rfind(";"), prefix.rfind("{"), prefix.rfind("}"))
    return re.search(r"\b(if|else|while|for|switch)\b", prefix[boundary + 1:]) is not None


def check(source):
    """check the primary display input setup"""
    body = function_body(code_only(source), SIGNATURE)
    if body is None:
        return [("NO-FUNCTION", f"composer.cpp has no {SIGNATURE}")]
    latch = LATCH.search(body)
    if latch is None:
        return [("NO-LATCH", f"{SIGNATURE} has no run-once latch to measure its returns from")]
    bad = []
    calls = []
    for code, what, pattern in (("POOL", "uinput_.PreCreatePool()", POOL),
                                ("BIND", "uinput_.Create(kPrimaryDisplayId, 0, ...)", BIND)):
        m = pattern.search(body, latch.end())
        if m is None:
            bad.append((f"NO-{code}", f"{SIGNATURE} never calls {what}"))
            continue
        calls.append((code, m.start()))
        if re.search(r"\breturn\b", body[latch.end():m.start()]):
            bad.append((f"RETURN-BEFORE-{code}",
                        f"a return between the latch and {what} skips it whenever the "
                        "primary's Wayland surface does not come up"))
        if conditional(body, m.start()):
            bad.append((f"{code}-IN-BRANCH",
                        f"{what} runs under a branch, not on every path through {SIGNATURE}"))
    positions = dict(calls)
    if "POOL" in positions and "BIND" in positions and positions["BIND"] < positions["POOL"]:
        bad.append(("BIND-BEFORE-POOL",
                    "the primary is bound to port 0 before the pool that owns port 0 exists"))
    return bad


def service_groups(rc):
    """return the groups of the composer service"""
    m = re.search(r"^service vendor\.rhizo-composer .*?\n((?:[ \t]+.*\n|#.*\n)*)", rc, re.M)
    if m is None:
        return None
    g = re.search(r"^[ \t]+group[ \t]+(.*)$", m.group(1), re.M)
    return g.group(1).split() if g else []


def check_enforcing_pool(rc, uinput):
    """check the uinput pool and node publishing"""
    bad = []
    groups = service_groups(rc)
    if groups is None:
        bad.append(("NO-SERVICE", "rhizo-composer.rc has no vendor.rhizo-composer service"))
    elif "uhid" not in groups:
        bad.append(("RC-NO-UHID-GROUP",
                    "the composer is not in group uhid"))
    code = code_only(uinput)
    pool = function_body(code, "bool UinputDevices::CreatePoolDeviceLocked(")
    if pool is None:
        bad.append(("NO-POOL-FUNCTION", "uinput.cpp has no UinputDevices::CreatePoolDeviceLocked"))
    else:
        m = re.search(r"if \(ioctl\(t, UI_DEV_CREATE\) < 0\)", pool)
        if m is None or pool[:m.start()].count("{") - pool[:m.start()].count("}") != 1:
            bad.append(("TOUCH-DEFERRED",
                        "the pool does not create each port's touchscreen at once"))
    publish = function_body(code, "std::string PublishNode(")
    if publish is None:
        bad.append(("NO-PUBLISH", "uinput.cpp has no PublishNode"))
    else:
        keep = re.search(r"\.st_rdev\s*==\s*makedev\(major,\s*minor\)", publish)
        drop = publish.find("unlink(node.c_str())")
        if drop >= 0 and (keep is None or keep.start() > drop):
            bad.append(("PUBLISH-UNLINKS-LIVE-NODE",
                        "PublishNode unlinks the node before checking it is already this device's, "
                        "and under enforcement its own mknod is denied"))
    return bad


FIXED = """
  void TryStartPrimaryWaylandSurface() {
    bool expected = false;
    if (!bootPrimarySurfaceAttempted_.compare_exchange_strong(expected, true)) return;
    bool surface = EnsureWaylandConnected();
    if (surface && !wayland_.CreateDisplay(kPrimaryDisplayId, "Rhizo")) {
      klog("CreateDisplay FAILED, staying headless -- return");
      surface = false;
    }
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(kPrimaryDisplayId)) { if (surface) ds->waylandBacked = true; }
    }
    // a comment naming uinput_.PreCreatePool(); and return does not count
    uinput_.PreCreatePool();
    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);
  }
"""

EARLY_RETURNS = """
  void TryStartPrimaryWaylandSurface() {
    bool expected = false;
    if (!bootPrimarySurfaceAttempted_.compare_exchange_strong(expected, true)) return;
    if (!EnsureWaylandConnected()) return;
    if (!wayland_.CreateDisplay(kPrimaryDisplayId, "Rhizo")) {
      klog("CreateDisplay FAILED, staying headless");
      return;
    }
    uinput_.PreCreatePool();
    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);
  }
"""

BLOCK_BRANCH = FIXED.replace(
    "    uinput_.PreCreatePool();\n",
    "    if (surface) {\n      uinput_.PreCreatePool();\n    }\n")
BARE_BRANCH = FIXED.replace(
    "    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);\n",
    "    if (surface) uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);\n")
SWAPPED = FIXED.replace(
    "    uinput_.PreCreatePool();\n    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);\n",
    "    uinput_.Create(kPrimaryDisplayId, 0, primaryW, primaryH);\n    uinput_.PreCreatePool();\n")
NO_POOL = FIXED.replace("    uinput_.PreCreatePool();\n", "")


GOOD_RC = """service vendor.rhizo-composer /vendor/bin/hw/rhizo-composer
    class core
    user system
# a comment line inside the service
    group system graphics uhid
    capabilities SYS_ADMIN DAC_OVERRIDE MKNOD

service other /x
    group uhid
"""

GOOD_UINPUT = """
std::string PublishNode(int fd) {
  unsigned major = 0, minor = 0;
  std::string node = "/dev/input/event1";
  struct stat st {};
  if (lstat(node.c_str(), &st) == 0 && S_ISCHR(st.st_mode) && st.st_rdev == makedev(major, minor)) {
    return node;
  }
  unlink(node.c_str());
  return node;
}
bool UinputDevices::CreatePoolDeviceLocked(int32_t port) {
  int t = 3;
  if (ioctl(t, UI_DEV_CREATE) < 0) {
    return false;
  }
  return true;
}
"""


def selftest():
    """check the enforcing and permissive source shapes"""
    enforcing = (
        ("enforcing: the fixed shape", GOOD_RC, GOOD_UINPUT, set()),
        ("enforcing: the service without the uhid group", GOOD_RC.replace("graphics uhid", "graphics"), GOOD_UINPUT,
         {"RC-NO-UHID-GROUP"}),
        ("enforcing: the touchscreen made on a later present", GOOD_RC,
         GOOD_UINPUT.replace("  if (ioctl(t, UI_DEV_CREATE) < 0) {\n    return false;\n  }\n",
                             "  if (presented) {\n    if (ioctl(t, UI_DEV_CREATE) < 0) {\n"
                             "      return false;\n    }\n  }\n"),
         {"TOUCH-DEFERRED"}),
        ("enforcing: unlink before the rdev check", GOOD_RC,
         GOOD_UINPUT.replace("  struct stat st {};\n", "  unlink(node.c_str());\n  struct stat st {};\n"),
         {"PUBLISH-UNLINKS-LIVE-NODE"}),
        ("enforcing: no rdev check at all", GOOD_RC,
         GOOD_UINPUT.replace("st.st_rdev == makedev(major, minor)", "true"),
         {"PUBLISH-UNLINKS-LIVE-NODE"}),
        ("enforcing: no composer service", "service x /y\n    group uhid\n", GOOD_UINPUT,
         {"NO-SERVICE"}),
    )
    failed = 0
    for name, rc, uinput, want in enforcing:
        got = {code for code, _ in check_enforcing_pool(rc, uinput)}
        if got != want:
            print(f"SELFTEST FAIL: {name}: wanted {sorted(want)}, got {sorted(got)}")
            failed += 1
    cases = (
        ("the fixed shape", FIXED, set()),
        ("early returns before the pool and the binding", EARLY_RETURNS, {"RETURN-BEFORE-POOL", "RETURN-BEFORE-BIND"}),
        ("the pool inside an if block", BLOCK_BRANCH, {"POOL-IN-BRANCH"}),
        ("the binding under a braceless if", BARE_BRANCH, {"BIND-IN-BRANCH"}),
        ("the binding before the pool", SWAPPED, {"BIND-BEFORE-POOL"}),
        ("no pool at all", NO_POOL, {"NO-POOL"}),
        ("no such function", "void SomethingElse() {}", {"NO-FUNCTION"}),
    )
    for name, source, want in cases:
        got = {code for code, _ in check(source)}
        if got != want:
            print(f"SELFTEST FAIL: {name}: wanted {sorted(want)}, got {sorted(got)}")
            failed += 1
    if failed:
        return 1
    print(f"check-composer-headless-input selftest: {len(cases) + len(enforcing)} cases OK")
    return 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(USAGE)
        return 2
    texts = {}
    for path in (COMPOSER, RC, UINPUT):
        with open(path) as f:
            texts[path] = f.read()
    bad = check(texts[COMPOSER]) + check_enforcing_pool(texts[RC], texts[UINPUT])
    for code, message in bad:
        print(f"FAIL {code}: {message}")
    if bad:
        return 1
    print("OK: the primary display's input pool and binding depend on neither its Wayland surface "
          "nor a boot that is not yet enforcing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
