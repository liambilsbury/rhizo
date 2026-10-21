#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HEADER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "wayland", "wayland_backend.h")
BACKEND = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "wayland", "wayland_backend.cpp")
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

STATS_FIELDS = ("tap_count=", "tap_last_ns=", "tap_min_ns=", "tap_max_ns=", "tap_sum_ns=",
               "tap_wire_delta_count=", "tap_wire_delta_last_ns=", "tap_wire_delta_min_ns=",
               "tap_wire_delta_max_ns=", "tap_wire_delta_sum_ns=",
               "tap_hop_uinput_ns=", "tap_hop_sf_present_ns=", "tap_hop_commit_ns=",
               "first_present_armed=", "first_present_arm_ns=", "first_present_sf_ns=",
               "first_present_commit_ns=", "first_present_ns=", "first_present_count=")


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


def block_at(text, open_idx):
    """return the text inside a brace pair"""
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i
        i += 1
    return None, -1


def check(header, backend, composer):
    """check the input-to-photon timing fields"""
    header = strip_comments(header)
    backend = strip_comments(backend)
    composer = strip_comments(composer)
    f = []

    ev = re.search(r"struct\s+WaylandInputEvent\s*\{", header)
    ev_body, _ = block_at(header, ev.end() - 1) if ev else (None, -1)
    if ev_body is None:
        f.append(("EVENT-STRUCT-MISSING", "WaylandInputEvent is missing from the header"))
    else:
        if not re.search(r"\btimeMsec\b", ev_body):
            f.append(("TIMEMSEC-FIELD-MISSING", "WaylandInputEvent has no timeMsec field"))
        if not re.search(r"\bqueuedNs\b", ev_body):
            f.append(("QUEUEDNS-FIELD-MISSING", "WaylandInputEvent has no queuedNs field"))

    qi = re.search(r"void\s+QueueInput\(([^)]*?)\)\s*\{", backend)
    if not qi:
        f.append(("QUEUEINPUT-MISSING", "QueueInput() is gone from the backend"))
    else:
        if "timeMsec" not in qi.group(1):
            f.append(("QUEUEINPUT-PARAM-MISSING", "QueueInput() takes no timeMsec "
                      "parameter"))
        qi_body, _ = block_at(backend, backend.index("{", qi.end() - 1))
        if qi_body is None:
            f.append(("QUEUEINPUT-MISSING", "QueueInput()'s body never closes"))
        else:
            if "ev.timeMsec = timeMsec" not in qi_body:
                f.append(("QUEUEINPUT-TIME-NOT-STORED", "QueueInput() takes timeMsec but never "
                          "stores it on the queued event"))
            if "ev.queuedNs = MonotonicNs()" not in qi_body:
                f.append(("QUEUEINPUT-NS-NOT-STAMPED", "QueueInput() never stamps queuedNs with "
                          "MonotonicNs()"))

    arm_fn = re.search(r"void\s+ArmTapLatency\((.*?)\)\s*\{", composer)
    if not arm_fn:
        f.append(("ARM-FUNCTION-MISSING", "ArmTapLatency() is gone"))
    else:
        arm_body, _ = block_at(composer, composer.index("{", arm_fn.end() - 1))
        if arm_body is None:
            f.append(("ARM-FUNCTION-MISSING", "ArmTapLatency()'s body never closes"))
        else:
            if "ds->tap.armed = true" not in arm_body:
                f.append(("ARM-FLAG-MISSING", "ArmTapLatency() never sets tap.armed"))
            if "ds->tap.armPresentCount = ds->presentCount" not in arm_body:
                f.append(("ARM-PRESENTCOUNT-SNAPSHOT-MISSING", "ArmTapLatency() never snapshots "
                          "presentCount"))

    if not re.search(r"ArmTapLatency\(\s*ev\.displayId\s*,\s*ev\.timeMsec\s*,\s*ev\.queuedNs\s*\)",
                     composer):
        f.append(("ARM-CALL-MISSING", "no press-branch call to ArmTapLatency(ev.displayId, "
                  "ev.timeMsec, ev.queuedNs)"))

    cond = re.search(r"if\s*\(ds->tap\.armed(.*?)\)\s*\{", composer, re.S)
    if not cond:
        f.append(("RESOLVE-MISSING", "WaylandPresented has no `if (ds->tap.armed ...)` block"))
    else:
        extra = cond.group(1)
        if "ds->presentCount" not in extra or "ds->tap.armPresentCount" not in extra or ">" not in extra:
            f.append(("RESOLVE-CONDITION-WEAKENED", "the resolve condition does not require "
                      "ds->presentCount > ds->tap.armPresentCount"))
        if not re.search(r"commitNs\s*>=\s*ds->tap\.sfPresentNs", extra):
            f.append(("RESOLVE-IGNORES-COMMIT-ORDER", "the resolve condition does not require "
                      "commitNs >= ds->tap.sfPresentNs"))
        resolve_body, _ = block_at(composer, cond.end() - 1)
        if resolve_body is None:
            f.append(("RESOLVE-MISSING", "the resolve block never closes"))
        else:
            if "ds->tap.armed = false" not in resolve_body:
                f.append(("RESOLVE-NEVER-DISARMS", "the resolve block never clears tap.armed"))
            guard = re.search(r"if\s*\(clockUsable\)\s*\{", resolve_body)
            if not guard:
                f.append(("CLOCKUSABLE-GUARD-MISSING", "the resolve block has no `if "
                          "(clockUsable)`"))
            else:
                guarded, guard_end = block_at(resolve_body, guard.end() - 1)
                outside = resolve_body[:guard.start()] + (resolve_body[guard_end + 1:]
                                                           if guard_end >= 0 else "")
                if guarded is None or "ds->tap.count++" not in guarded or "ds->tap.sumNs" not in guarded:
                    f.append(("CLOCKUSABLE-GUARD-BYPASSED", "the tap stats update is not nested "
                              "inside the clockUsable guard"))
                if "ds->tap.count++" in outside or "ds->tap.sumNs" in outside:
                    f.append(("CLOCKUSABLE-GUARD-BYPASSED", "the tap stats update also happens "
                              "outside the clockUsable guard"))
                klogs = list(re.finditer(r"klogf\(", resolve_body))
                if len(klogs) > 1:
                    f.append(("PER-SAMPLE-LOGGING", "more than one klogf() call in the tap "
                              "resolve path"))
                elif len(klogs) == 1 and guarded is not None:
                    once = re.search(r"if\s*\(ds->tap\.count\s*==\s*1\)\s*\{", guarded)
                    once_body, _ = block_at(guarded, once.end() - 1) if once else (None, -1)
                    if once_body is None or "klogf(" not in once_body:
                        f.append(("PER-SAMPLE-LOGGING", "the klogf() call in the tap resolve "
                                  "path is not gated behind tap.count == 1"))
                elif len(klogs) == 0:
                    f.append(("NO-ALIVE-KLOG", "the tap resolve path never logs anything"))

    stats = re.search(r'"display stats id="[^;]*?;', composer, re.S)
    stats_reply = stats.group(0) if stats else ""
    for field in STATS_FIELDS:
        if field not in stats_reply:
            f.append(("STATS-FIELD-MISSING", "the `display stats` reply is missing %r" % field))

    return f


GOOD_HEADER = """
struct WaylandInputEvent {
  int64_t displayId = -1;
  double x = 0;
  double y = 0;
  uint32_t code = 0;
  int32_t value = 0;
  uint32_t timeMsec = 0;
  int64_t queuedNs = 0;
};
"""

GOOD_BACKEND = """
void QueueInput(int64_t displayId, WaylandInputEvent::Kind kind, double x, double y,
                uint32_t code, int32_t value, uint32_t timeMsec) {
  if (!inputCb || displayId < 0) return;
  WaylandInputEvent ev;
  ev.displayId = displayId;
  ev.code = code;
  ev.value = value;
  ev.timeMsec = timeMsec;
  ev.queuedNs = MonotonicNs();
  pendingInput.push_back(ev);
}
"""

GOOD_COMPOSER = """
  void ArmTapLatency(int64_t displayId, uint32_t timeMsec, int64_t queuedNs) {
    std::lock_guard<std::mutex> lg(mutex_);
    DisplayState* ds = FindLocked(displayId);
    if (!ds) return;
    ds->tap.armed = true;
    ds->tap.armTimeMsec = timeMsec;
    ds->tap.armQueuedNs = queuedNs;
    ds->tap.armPresentCount = ds->presentCount;
  }

  void OnWaylandInput() {
    switch (ev.kind) {
      case Kind::PointerButton:
        if (ev.code == 0x110) {
          if (ev.value) {
            pointerDown_.insert(ev.displayId);
            ArmTapLatency(ev.displayId, ev.timeMsec, ev.queuedNs);
          }
        }
        break;
    }
  }

  void WaylandPresented(int64_t displayId, int64_t presentedNs, int64_t refreshNs, bool discarded,
                        int64_t commitNs) {
    {
      const bool clockUsable = wayland_.PresentationClockId() == CLOCK_MONOTONIC && presentedNs > 0;
      if (ds->tap.armed && ds->presentCount > ds->tap.armPresentCount &&
          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {
        if (clockUsable) {
          const int64_t deltaNs = presentedNs - ds->tap.armQueuedNs;
          ds->tap.sumNs += deltaNs;
          ds->tap.lastNs = deltaNs;
          ds->tap.count++;
          if (ds->tap.count == 1) {
            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);
          }
        }
        ds->tap.armed = false;
      }
    }
  }

  void ControlStats() {
    reply = "display stats id=" + std::to_string(a) +
            " presents=" + std::to_string(ds->presentCount) +
            " tap_count=" + std::to_string(ds->tap.count) +
            " tap_last_ns=" + std::to_string(ds->tap.lastNs) +
            " tap_min_ns=" + std::to_string(ds->tap.minNs) +
            " tap_max_ns=" + std::to_string(ds->tap.maxNs) +
            " tap_sum_ns=" + std::to_string(ds->tap.sumNs) +
            " tap_wire_delta_count=" + std::to_string(ds->tap.wireDeltaCount) +
            " tap_wire_delta_last_ns=" + std::to_string(ds->tap.wireDeltaLastNs) +
            " tap_wire_delta_min_ns=" + std::to_string(ds->tap.wireDeltaMinNs) +
            " tap_wire_delta_max_ns=" + std::to_string(ds->tap.wireDeltaMaxNs) +
            " tap_wire_delta_sum_ns=" + std::to_string(ds->tap.wireDeltaSumNs) +
            " tap_hop_uinput_ns=" + std::to_string(ds->tap.hopUinputNs) +
            " tap_hop_sf_present_ns=" + std::to_string(ds->tap.hopSfPresentNs) +
            " tap_hop_commit_ns=" + std::to_string(ds->tap.hopCommitNs) +
            " first_present_armed=" + std::to_string(ds->firstPresent.armed ? 1 : 0) +
            " first_present_arm_ns=" + std::to_string(ds->firstPresent.armNs) +
            " first_present_sf_ns=" + std::to_string(ds->firstPresent.sfPresentNs) +
            " first_present_commit_ns=" + std::to_string(ds->firstPresent.commitNs) +
            " first_present_ns=" + std::to_string(ds->firstPresent.presentedNs) +
            " first_present_count=" + std::to_string(ds->firstPresent.count);
  }
"""


def selftest():
    """check the real shape and each planted-defect copy of it"""
    cases = [("the real shape", GOOD_HEADER, GOOD_BACKEND, GOOD_COMPOSER, set())]

    def bad_header(label, old, new, rules):
        """record a planted case with a replaced header text"""
        assert GOOD_HEADER.count(old) == 1, old
        cases.append((label, GOOD_HEADER.replace(old, new, 1), GOOD_BACKEND, GOOD_COMPOSER, rules))

    def bad_backend(label, old, new, rules):
        """record a planted case with a replaced backend text"""
        assert GOOD_BACKEND.count(old) == 1, old
        cases.append((label, GOOD_HEADER, GOOD_BACKEND.replace(old, new, 1), GOOD_COMPOSER, rules))

    def bad_composer(label, old, new, rules):
        """record a planted case with a replaced composer text"""
        assert GOOD_COMPOSER.count(old) == 1, old
        cases.append((label, GOOD_HEADER, GOOD_BACKEND, GOOD_COMPOSER.replace(old, new, 1), rules))

    bad_header("timeMsec field dropped", "  uint32_t timeMsec = 0;\n", "",
               {"TIMEMSEC-FIELD-MISSING"})
    bad_header("queuedNs field dropped", "  int64_t queuedNs = 0;\n", "",
               {"QUEUEDNS-FIELD-MISSING"})

    bad_backend("QueueInput loses its timeMsec parameter",
               "uint32_t code, int32_t value, uint32_t timeMsec) {",
               "uint32_t code, int32_t value) {",
               {"QUEUEINPUT-PARAM-MISSING"})
    bad_backend("QueueInput takes timeMsec but never stores it",
               "  ev.timeMsec = timeMsec;\n", "", {"QUEUEINPUT-TIME-NOT-STORED"})
    bad_backend("QueueInput never stamps its own clock",
               "  ev.queuedNs = MonotonicNs();\n", "", {"QUEUEINPUT-NS-NOT-STAMPED"})

    bad_composer("ArmTapLatency deleted entirely",
                "  void ArmTapLatency(int64_t displayId, uint32_t timeMsec, int64_t queuedNs) {\n"
                "    std::lock_guard<std::mutex> lg(mutex_);\n"
                "    DisplayState* ds = FindLocked(displayId);\n"
                "    if (!ds) return;\n"
                "    ds->tap.armed = true;\n"
                "    ds->tap.armTimeMsec = timeMsec;\n"
                "    ds->tap.armQueuedNs = queuedNs;\n"
                "    ds->tap.armPresentCount = ds->presentCount;\n"
                "  }\n", "",
                {"ARM-FUNCTION-MISSING"})
    bad_composer("arm never sets the armed flag", "    ds->tap.armed = true;\n", "",
                {"ARM-FLAG-MISSING"})
    bad_composer("arm never snapshots presentCount",
                "    ds->tap.armPresentCount = ds->presentCount;\n", "",
                {"ARM-PRESENTCOUNT-SNAPSHOT-MISSING"})
    bad_composer("the press branch never arms the measurement",
                "            ArmTapLatency(ev.displayId, ev.timeMsec, ev.queuedNs);\n", "",
                {"ARM-CALL-MISSING"})
    bad_composer("the resolve block is deleted",
                "      if (ds->tap.armed && ds->presentCount > ds->tap.armPresentCount &&\n"
                "          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {\n"
                "        if (clockUsable) {\n"
                "          const int64_t deltaNs = presentedNs - ds->tap.armQueuedNs;\n"
                "          ds->tap.sumNs += deltaNs;\n"
                "          ds->tap.lastNs = deltaNs;\n"
                "          ds->tap.count++;\n"
                "          if (ds->tap.count == 1) {\n"
                '            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          }\n"
                "        }\n"
                "        ds->tap.armed = false;\n"
                "      }\n", "",
                {"RESOLVE-MISSING"})
    bad_composer("the advance condition is weakened to any feedback",
                "if (ds->tap.armed && ds->presentCount > ds->tap.armPresentCount &&\n"
                "          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {",
                "if (ds->tap.armed &&\n          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {",
                {"RESOLVE-CONDITION-WEAKENED"})
    bad_composer("the commit-order guard is dropped",
                " &&\n          ds->tap.sfPresentNs != 0 && commitNs >= ds->tap.sfPresentNs) {",
                ") {",
                {"RESOLVE-IGNORES-COMMIT-ORDER"})
    bad_composer("the resolve block never disarms",
                "        ds->tap.armed = false;\n", "", {"RESOLVE-NEVER-DISARMS"})
    bad_composer("the clockUsable guard is removed, exposing the update unconditionally",
                "        if (clockUsable) {\n"
                "          const int64_t deltaNs = presentedNs - ds->tap.armQueuedNs;\n"
                "          ds->tap.sumNs += deltaNs;\n"
                "          ds->tap.lastNs = deltaNs;\n"
                "          ds->tap.count++;\n"
                "          if (ds->tap.count == 1) {\n"
                '            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          }\n"
                "        }\n",
                "        const int64_t deltaNs = presentedNs - ds->tap.armQueuedNs;\n"
                "        ds->tap.sumNs += deltaNs;\n"
                "        ds->tap.lastNs = deltaNs;\n"
                "        ds->tap.count++;\n"
                "        if (ds->tap.count == 1) {\n"
                '          klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "        }\n",
                {"CLOCKUSABLE-GUARD-MISSING"})
    bad_composer("the count update also happens outside the guard",
                "          ds->tap.count++;\n",
                "          ds->tap.count++;\n"
                "        }\n"
                "        ds->tap.count++;\n"
                "        {\n",
                {"CLOCKUSABLE-GUARD-BYPASSED"})
    bad_composer("a klogf is added for every resolved tap, not just the first",
                "          if (ds->tap.count == 1) {\n"
                '            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          }\n",
                '          klogf("display %lld input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          if (ds->tap.count == 1) {\n"
                '            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          }\n",
                {"PER-SAMPLE-LOGGING"})
    bad_composer("the once-only klog loses its count==1 system test",
                "          if (ds->tap.count == 1) {\n"
                '            klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n'
                "          }\n",
                '          klogf("display %lld first input-to-photon: press->presented %lldns", displayId, deltaNs);\n',
                {"PER-SAMPLE-LOGGING"})
    bad_composer("the display stats reply drops a tap field",
                '" tap_count=" + std::to_string(ds->tap.count) +\n            ', "",
                {"STATS-FIELD-MISSING"})

    rc = 0
    for label, header, backend, composer, want in cases:
        got = {rule for rule, _ in check(header, backend, composer)}
        if want:
            missing = want - got
            if missing:
                print("SELFTEST FAILED: %s -- wanted %s, got %s"
                      % (label, sorted(want), sorted(got) or "no findings"), file=sys.stderr)
                rc = 1
        elif got:
            print("SELFTEST FAILED: %s -- wanted no findings, got %s"
                  % (label, sorted(got)), file=sys.stderr)
            rc = 1
    if rc == 0:
        print("selftest ok: accepts the real shape and catches %d reverted defects"
              % (len(cases) - 1))
    return rc


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    for path in (HEADER, BACKEND, COMPOSER):
        if not os.path.exists(path):
            print("composer-input-to-photon.py: %s not found" % path, file=sys.stderr)
            return 1
    failures = check(open(HEADER).read(), open(BACKEND).read(), open(COMPOSER).read())
    if failures:
        print("the input-to-photon instrument is not fully wired:", file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("input-to-photon is armed on press, resolved only past a real fed frame on a "
          "checked clock, disarms, logs at most once, and every field reaches `display stats`")
    return 0


if __name__ == "__main__":
    sys.exit(main())
