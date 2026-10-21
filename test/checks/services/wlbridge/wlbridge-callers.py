#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SRC = os.path.join(REPO, "src", "services", "deskbridge", "wlbridge.c")

LAUNCHES = {
    "test/system/lib/desktop-assert-lib.sh": r"'\S*/rhizo-wlbridge-test\b[^\n]*",
    "src/services/deskbridge/deskd.py": r"^\s*argv = \[path,[^\n]*",
}

SHORTCIRCUIT = r'argv\[1\],\s*"(--[\w-]+)"\)\)\s*return'


def required_args(src):
    """return the required rhizo-wlbridge flags"""
    names = set(re.findall(r'"rhizo-wlbridge: (--[\w-]+) is required', src))
    return sorted(names)


def shortcircuit_args(src):
    """return the selftest flags from wlbridge.c"""
    return sorted(set(re.findall(SHORTCIRCUIT, src)))


def check(texts, src):
    """return a list of failure strings"""
    need = required_args(src)
    if not need:
        return ["wlbridge.c no longer refuses to start without any argument"]
    skip = shortcircuit_args(src)
    out = []
    for caller, pattern in sorted(LAUNCHES.items()):
        text = texts.get(caller)
        if text is None:
            out.append("%s is named in LAUNCHES and does not exist" % caller)
            continue
        found = re.findall(pattern, text, re.M)
        if not found:
            out.append("%s: no launch of rhizo-wlbridge matches this check's "
                       "pattern any more" % caller)
            continue
        for line in found:
            if any(s in line for s in skip):
                continue
            for arg in need:
                if arg not in line:
                    out.append("%s launches rhizo-wlbridge without %s, which it "
                               "refuses to start without (exit 2): %s"
                               % (caller, arg, line.strip()[:100]))
    return out


def load():
    """return the caller texts that exist and the bridge source text"""
    texts = {}
    for caller in LAUNCHES:
        path = os.path.join(REPO, caller)
        if os.path.exists(path):
            texts[caller] = open(path).read()
    return texts, open(SRC).read()


def selftest():
    """test the check with planted defects"""
    texts, src = load()
    fail = 0
    if required_args(src) != ["--caps"]:
        print("check-wlbridge-callers selftest: FAILED -- expected the binary to "
              "require exactly --caps, read %r" % required_args(src))
        fail = 1
    if "--selftest-base64" not in shortcircuit_args(src):
        print("check-wlbridge-callers selftest: FAILED -- --selftest-base64 no "
              "longer reads as short-circuiting")
        fail = 1
    if check(texts, src):
        print("check-wlbridge-callers selftest: FAILED -- the real tree does not "
              "pass: %r" % check(texts, src))
        fail = 1

    for caller, marker in (("test/system/lib/desktop-assert-lib.sh", " --caps $CLIP_BRIDGE_CAPS"),
                           ("src/services/deskbridge/deskd.py", '"--caps", ')):
        broken = dict(texts)
        broken[caller] = texts[caller].replace(marker, "")
        if broken[caller] == texts[caller]:
            print("check-wlbridge-callers selftest: FAILED -- could not remove "
                  "%s's --caps to test it" % caller)
            fail = 1
        elif not any(caller in m and "--caps" in m for m in check(broken, src)):
            print("check-wlbridge-callers selftest: FAILED -- %s without --caps "
                  "was not caught" % caller)
            fail = 1

    moved = dict(texts)
    moved["test/system/lib/desktop-assert-lib.sh"] = texts["test/system/lib/desktop-assert-lib.sh"].replace(
        "rhizo-wlbridge-test", "rhizo-something-else")
    if not any("no launch of rhizo-wlbridge matches" in m for m in check(moved, src)):
        print("check-wlbridge-callers selftest: FAILED -- a caller whose launch "
              "moved passed vacuously")
        fail = 1

    sc = dict(texts)
    sc["test/system/lib/desktop-assert-lib.sh"] = (
        "setsid sh -c '/root/rhizo-wlbridge-test --selftest-base64' &\n")
    if any("without --caps" in m for m in check(sc, src)):
        print("check-wlbridge-callers selftest: FAILED -- a --selftest-base64 "
              "invocation was flagged for not passing --caps")
        fail = 1

    if fail:
        return 1
    print("check-wlbridge-callers selftest: ok (a caller missing a required "
          "argument, a launch that moved, and a selftest invocation are all "
          "judged correctly)")
    return 0


def main(argv):
    """run the check or its selftest"""
    if "--selftest" in argv:
        return selftest()
    texts, src = load()
    fails = check(texts, src)
    for m in fails:
        print("check-wlbridge-callers: " + m, file=sys.stderr)
    if fails:
        return 1
    print("check-wlbridge-callers: every launch passes %s"
          % ", ".join(required_args(src)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
