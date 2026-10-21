#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

IMPL_START = re.compile(r"^\s*RemoveOutcome RemoveDisplayImpl\(int64_t id, bool requireUnclaimed\)")
CLAIMED_CHECK_RE = re.compile(r"if\s*\(\s*requireUnclaimed\s*&&\s*ds->claimed\s*\)\s*return")
REMOVING_TRUE_RE = re.compile(r"ds->removing\s*=\s*true;")
VERB_CALL_RE = re.compile(
    r'noun,\s*"release-spare"\)\)\s*\{\s*'
    r"RemoveOutcome outcome = RemoveDisplayImpl\(a,\s*/\*requireUnclaimed=\*/true\);",
    re.DOTALL)


def strip_cpp_comments(text):
    """return the text without lines that start with a // comment"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def extract_function(lines, start_re, close_indent="  }"):
    """return the body lines of a matching function"""
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


def check_composer(text):
    """check that the release-spare claimed check is atomic"""
    code = strip_cpp_comments(text)
    lines = code.split("\n")
    failures = []

    impl_body = extract_function(lines, IMPL_START)
    if not impl_body:
        failures.append(("NO-IMPL", "RemoveDisplayImpl(int64_t id, bool requireUnclaimed) not "
                         "found"))
        return failures

    claimed_m = CLAIMED_CHECK_RE.search(impl_body)
    removing_m = REMOVING_TRUE_RE.search(impl_body)
    if not claimed_m:
        failures.append(("NO-CLAIMED-CHECK",
                         "no `if (requireUnclaimed && ds->claimed) return ...;` in "
                         "RemoveDisplayImpl"))
    if not removing_m:
        failures.append(("NO-REMOVING-MUTATION",
                         "no `ds->removing = true;` in RemoveDisplayImpl"))
    if claimed_m and removing_m and claimed_m.start() >= removing_m.start():
        failures.append(("CHECK-AFTER-MUTATION",
                         "the requireUnclaimed check comes AFTER `ds->removing = true;`"))

    if not VERB_CALL_RE.search(code):
        failures.append(("VERB-NOT-ATOMIC",
                         "the \"display release-spare\" verb does not call "
                         "RemoveDisplayImpl(a, /*requireUnclaimed=*/true) directly"))

    return failures


SELFTEST_GOOD = """
  RemoveOutcome RemoveDisplayImpl(int64_t id, bool requireUnclaimed) {
    if (requireUnclaimed && id == kPrimaryDisplayId) {
      return RemoveOutcome::kStillClaimed;
    }
    if (id == kPrimaryDisplayId) {
      return RemoveOutcome::kRefused;
    }
    {
      std::lock_guard<std::mutex> lg(mutex_);
      DisplayState* ds = FindLiveRaw(id);
      if (!ds) return RemoveOutcome::kRefused;
      if (requireUnclaimed && ds->claimed) return RemoveOutcome::kStillClaimed;
      ds->removing = true;
      removingDisplays_[id] = std::move(*ds);
      displays_.erase(id);
    }
    return RemoveOutcome::kOk;
  }

    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "release-spare")) {
      RemoveOutcome outcome = RemoveDisplayImpl(a, /*requireUnclaimed=*/true);
      if (outcome == RemoveOutcome::kOk) {
        WriteControlReply("display spare-released id=" + std::to_string(a));
      }
      return;
    }
"""

SELFTEST_CHECK_AFTER = SELFTEST_GOOD.replace(
    "      if (requireUnclaimed && ds->claimed) return RemoveOutcome::kStillClaimed;\n"
    "      ds->removing = true;\n",
    "      ds->removing = true;\n"
    "      if (requireUnclaimed && ds->claimed) return RemoveOutcome::kStillClaimed;\n")

SELFTEST_NO_CHECK = SELFTEST_GOOD.replace(
    "      if (requireUnclaimed && ds->claimed) return RemoveOutcome::kStillClaimed;\n", "")

SELFTEST_VERB_TOCTOU = SELFTEST_GOOD.replace(
    """    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "release-spare")) {
      RemoveOutcome outcome = RemoveDisplayImpl(a, /*requireUnclaimed=*/true);
      if (outcome == RemoveOutcome::kOk) {
        WriteControlReply("display spare-released id=" + std::to_string(a));
      }
      return;
    }""",
    """    if (n >= 3 && !strcmp(verb, "display") && !strcmp(noun, "release-spare")) {
      if (!FindLocked(a) || FindLocked(a)->claimed) { WriteControlReply("no"); return; }
      RemoveDisplayImpl(a, false);
      return;
    }""")


def selftest():
    """check each source shape against the failures it must produce"""
    cases = [
        ("the real shape", SELFTEST_GOOD, set()),
        ("claimed check after the mutation", SELFTEST_CHECK_AFTER, {"CHECK-AFTER-MUTATION"}),
        ("claimed check missing entirely", SELFTEST_NO_CHECK, {"NO-CLAIMED-CHECK"}),
        ("verb does its own check-then-call", SELFTEST_VERB_TOCTOU, {"VERB-NOT-ATOMIC"}),
    ]
    for label, text, want in cases:
        got = {rule for rule, _d in check_composer(text)}
        if got != want:
            print("SELFTEST FAILED: %s -- wanted %s, got %s"
                  % (label, sorted(want) or "no findings", sorted(got)), file=sys.stderr)
            return 1
    print("selftest ok: accepts the real shape, and catches the claimed check moved after the "
          "mutation, missing entirely, or the verb bypassing RemoveDisplayImpl's own atomic system test")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(COMPOSER):
        print("release-spare-atomic.py: %s not found" % COMPOSER, file=sys.stderr)
        return 1
    failures = check_composer(open(COMPOSER).read())
    if failures:
        print("release-spare's claimed check is not provably atomic with its teardown:",
              file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("release-spare's claimed check runs in the same locked section as the teardown "
          "it system tests, and the verb reaches it directly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
