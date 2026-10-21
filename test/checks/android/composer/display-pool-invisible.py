#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

ADD_DISPLAY_START = re.compile(r"^\s*int64_t AddDisplay\(int32_t width, int32_t height")
REMOVE_IMPL_START = re.compile(r"^\s*RemoveOutcome RemoveDisplayImpl\(int64_t id, bool requireUnclaimed\)")
KICK_VSYNC_TESTD_RE = re.compile(r"if\s*\(\s*wayland\s*\)\s*wayland_\.KickVsync\(")
VSYNC_LOOP_GUARD_RE = re.compile(r"if\s*\(\s*!\s*ds\.claimed\s*\)\s*continue;")
PRESENT_FRAME_RE = re.compile(r"wayland_\.PresentFrame(?:WhenSignaled)?\(")
GUARDED_PRESENT_RE = re.compile(
    r"if\s*\(\s*ds\.waylandBacked\s*\)\s*\{[^}]*wayland_\.PresentFrame(?:WhenSignaled)?\(")
CREATE_DISPLAY_CALL_RE = re.compile(r"wayland_\.CreateDisplay\(")
IF_OPEN_RE = re.compile(r"if\s*\(")
DESTROY_DISPLAY_CALL_RE = re.compile(r"wayland_\.DestroyDisplay\(")
DESTROY_DISPLAY_TESTD_LINE_RE = re.compile(
    r"if\s*\(\s*wasWayland\s*\)\s*wayland_\.DestroyDisplay\(")
DESTROY_DISPLAY_TESTD_BLOCK_RE = re.compile(
    r"if\s*\(\s*wasWayland\s*\)\s*\{[^}]*wayland_\.DestroyDisplay\(")


def strip_cpp_comments(text):
    """strip whole-line // comments from the text"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def extract_function(lines, start_re, close_indent="  }"):
    """return the lines of a function body"""
    body, in_fn = [], False
    for line in lines:
        if not in_fn and start_re.match(line):
            in_fn = True
            continue
        if in_fn:
            if line.rstrip() == close_indent:
                break
            body.append(line)
    return "\n".join(body)


def find_matching(text, open_idx, open_ch, close_ch):
    """return the index of the matching close character"""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return -1


def reachable_only_when_claimed(body, call_pos):
    """check for a claimed branch around the call"""
    for m in IF_OPEN_RE.finditer(body, 0, call_pos):
        open_paren = m.end() - 1
        close_paren = find_matching(body, open_paren, "(", ")")
        if close_paren == -1 or close_paren >= call_pos:
            continue
        after = body[close_paren + 1:]
        gap = len(after) - len(after.lstrip(" \t\n"))
        if after[gap:gap + 1] != "{":
            continue
        brace_open = close_paren + 1 + gap
        brace_close = find_matching(body, brace_open, "{", "}")
        if brace_close == -1 or not (brace_open < call_pos < brace_close):
            continue
        cond = body[open_paren + 1:close_paren]
        if re.search(r"\bclaimed\b", cond):
            return True
    return False


def check_composer(text):
    """return the failures from the composer checks"""
    code = strip_cpp_comments(text)
    lines = code.split("\n")
    failures = []

    add_body = extract_function(lines, ADD_DISPLAY_START)
    if not add_body:
        failures.append(("NO-ADDDISPLAY",
                         "AddDisplay() not found"))
        return failures

    create_calls = [m.start() for m in CREATE_DISPLAY_CALL_RE.finditer(add_body)]
    if not create_calls:
        failures.append(("NO-CREATEDISPLAY",
                         "AddDisplay() never calls wayland_.CreateDisplay"))
    elif not all(reachable_only_when_claimed(add_body, pos) for pos in create_calls):
        failures.append(("UNCLAIMED-CREATE",
                         "wayland_.CreateDisplay in AddDisplay is reachable without `claimed` "
                         "being true"))

    if not KICK_VSYNC_TESTD_RE.search(add_body):
        failures.append(("UNGATED-KICKVSYNC",
                         "wayland_.KickVsync in AddDisplay is not gated by `if (wayland)`"))

    if not VSYNC_LOOP_GUARD_RE.search(code):
        failures.append(("NO-VSYNC-GUARD",
                         "no `if (!ds.claimed) continue;` in the software vsync loop"))

    present_sites = PRESENT_FRAME_RE.findall(code)
    if len(present_sites) != 1:
        failures.append(("PRESENT-SITE-COUNT",
                         "found %d wayland_.PresentFrame[WhenSignaled]( call sites, expected exactly 1"
                         % len(present_sites)))
    elif not GUARDED_PRESENT_RE.search(code):
        failures.append(("UNGUARDED-PRESENT",
                         "the one wayland_.PresentFrame[WhenSignaled]( call site is not guarded by "
                         "`if (ds.waylandBacked)`"))

    remove_body = extract_function(lines, REMOVE_IMPL_START)
    if not remove_body:
        failures.append(("NO-REMOVEDISPLAYIMPL",
                         "RemoveDisplayImpl not found"))
        return failures
    destroy_sites = DESTROY_DISPLAY_CALL_RE.findall(remove_body)
    gated = (len(DESTROY_DISPLAY_TESTD_LINE_RE.findall(remove_body))
             + len(DESTROY_DISPLAY_TESTD_BLOCK_RE.findall(remove_body)))
    if not destroy_sites:
        failures.append(("NO-DESTROYDISPLAY",
                         "wayland_.DestroyDisplay not found in RemoveDisplayImpl"))
    elif gated < len(destroy_sites):
        failures.append(("UNGATED-DESTROY",
                         "found %d wayland_.DestroyDisplay( call site(s) but only %d gated by "
                         "`if (wasWayland)`" % (len(destroy_sites), gated)))

    return failures


SELFTEST_GOOD = """
  int64_t AddDisplay(int32_t width, int32_t height, bool claimed = true) {
    int64_t id;
    int32_t port;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      port = *freePorts_.begin();
      freePorts_.erase(freePorts_.begin());
      id = nextDisplayId_++;
      DisplayState& ds = displays_[id];
      ds.id = id;
      ds.port = port;
      ds.claimed = claimed;
    }
    bool wayland = false;
    if (claimed && EnsureWaylandConnected()) {
      std::string title = "Rhizo display " + std::to_string(id);
      wayland = wayland_.CreateDisplay(id, title);
    }
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (DisplayState* ds = FindLocked(id)) ds->waylandBacked = wayland;
    }
    if (wayland) wayland_.KickVsync(id);
    uinput_.Create(id, port, width, height);
    return id;
  }

  void StartVsyncThreadOnce() {
    for (auto& [id, ds] : displays_) {
      if (!ds.vsyncEnabled) continue;
      if (!ds.claimed) continue;
      if (ds.waylandBacked && now - ds.lastVsyncNs < kVsyncWatchdogNs) continue;
      due.push_back(id);
    }
  }

  void PresentBufferedFrame() {
    if (ds.waylandBacked) {
      rhizo::WaylandFrame wf;
      wf.slot = buf.slot;
      if (!wayland_.PresentFrame(ds.id, wf)) {
        klogf("PresentBufferedFrame: WaylandBackend::PresentFrame FAILED");
      }
    }
  }

  RemoveOutcome RemoveDisplayImpl(int64_t id, bool requireUnclaimed) {
    if (id == kPrimaryDisplayId) {
      bool wasWayland;
      if (wasWayland) {
        wayland_.DestroyDisplay(id);
        uinput_.Destroy(id);
      }
      return RemoveOutcome::kRefused;
    }
    bool wasWayland = false;
    if (wasWayland) wayland_.DestroyDisplay(id);
    uinput_.Destroy(id);
    return RemoveOutcome::kOk;
  }
"""

SELFTEST_CREATE_UNGATED = SELFTEST_GOOD.replace(
    "if (claimed && EnsureWaylandConnected()) {",
    "if (EnsureWaylandConnected()) {")

SELFTEST_NO_VSYNC_GUARD = SELFTEST_GOOD.replace(
    "      if (!ds.claimed) continue;\n", "")

SELFTEST_UNGUARDED_PRESENT = SELFTEST_GOOD.replace(
    "    if (ds.waylandBacked) {\n      rhizo::WaylandFrame wf;",
    "    {\n      rhizo::WaylandFrame wf;")

SELFTEST_UNGATED_DESTROY = SELFTEST_GOOD.replace(
    "    bool wasWayland = false;\n    if (wasWayland) wayland_.DestroyDisplay(id);\n",
    "    bool wasWayland = false;\n    wayland_.DestroyDisplay(id);\n")


def selftest():
    """check each source shape against the findings it must produce"""
    cases = [
        ("the real shape", SELFTEST_GOOD, set()),
        ("CreateDisplay outside the claimed branch", SELFTEST_CREATE_UNGATED,
         {"UNCLAIMED-CREATE"}),
        ("missing vsync-loop guard", SELFTEST_NO_VSYNC_GUARD, {"NO-VSYNC-GUARD"}),
        ("unguarded present call site", SELFTEST_UNGUARDED_PRESENT, {"UNGUARDED-PRESENT"}),
        ("ungated DestroyDisplay call", SELFTEST_UNGATED_DESTROY, {"UNGATED-DESTROY"}),
    ]
    for label, text, want in cases:
        got = {rule for rule, _d in check_composer(text)}
        if got != want:
            print("SELFTEST FAILED: %s -- wanted %s, got %s"
                  % (label, sorted(want) or "no findings", sorted(got)), file=sys.stderr)
            return 1
    print("selftest ok: accepts the real shape, and catches CreateDisplay reachable without "
          "the claimed system test, a vsync loop with no claimed guard, an unguarded present "
          "call site, and an ungated DestroyDisplay call")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(COMPOSER):
        print("display-pool-invisible.py: %s not found" % COMPOSER, file=sys.stderr)
        return 1
    failures = check_composer(open(COMPOSER).read())
    if failures:
        print("a spare display's invisibility is not guaranteed by the source:", file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("an unclaimed spare has no Wayland surface, drives no vsync, presents nowhere, and "
          "its removal only reaches the backend when it was Wayland-backed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
