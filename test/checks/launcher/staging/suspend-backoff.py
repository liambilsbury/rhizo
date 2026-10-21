#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROP_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "vendor", "build.prop")
MOUNTS_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "sandbox", "rootfs.py")


def check(prop_text, mounts_text):
    """return the suspend backoff failures"""
    failures = []

    if not re.search(r"^suspend\.short_suspend_backoff_enabled=true$", prop_text, re.M):
        failures.append(("BACKOFF-NOT-ENABLED",
                         "suspend.short_suspend_backoff_enabled=true is missing"))

    m = re.search(r"^suspend\.short_suspend_threshold_millis=(\d+)$", prop_text, re.M)
    threshold_ms = None
    if not m:
        failures.append(("THRESHOLD-MISSING",
                         "suspend.short_suspend_threshold_millis is missing"))
    else:
        threshold_ms = int(m.group(1))
        if threshold_ms <= 0:
            failures.append(("THRESHOLD-ZERO",
                             f"suspend.short_suspend_threshold_millis={threshold_ms}, want > 0"))

    m = re.search(r'last_suspend_time",\s*"w"\)\.write\("([\d.eE+-]+)\s+([\d.eE+-]+)\\n"\)',
                   mounts_text)
    if not m:
        failures.append(("SHADOW-CONTENT-UNPARSEABLE",
                         "could not find the last_suspend_time write() call's literal content "
                         "in sandbox/rootfs.py"))
    else:
        suspend_time_s = float(m.group(2))
        if suspend_time_s <= 0:
            failures.append(("SHADOW-TIME-ZERO",
                             f"last_suspend_time's suspend-time field is {suspend_time_s}s, want > 0"))
        elif threshold_ms is not None and suspend_time_s * 1000 >= threshold_ms:
            failures.append(("SHADOW-TIME-NOT-SHORT",
                             f"last_suspend_time reports {suspend_time_s * 1000}ms, which is "
                             f">= the {threshold_ms}ms threshold"))

    return failures


GOOD_PROP = ("suspend.short_suspend_backoff_enabled=true\n"
             "suspend.short_suspend_threshold_millis=1000\n")
GOOD_MOUNTS = 'open(f"{X}/last_suspend_time", "w").write("0 0.001\\n")'


def selftest():
    """check each property and mount sample"""
    cases = [
        ("both properties + a real short shadow time", GOOD_PROP, GOOD_MOUNTS, True),
        ("backoff not enabled",
         "suspend.short_suspend_threshold_millis=1000\n", GOOD_MOUNTS, False),
        ("threshold missing", "suspend.short_suspend_backoff_enabled=true\n",
         GOOD_MOUNTS, False),
        ("threshold zero",
         "suspend.short_suspend_backoff_enabled=true\n"
         "suspend.short_suspend_threshold_millis=0\n", GOOD_MOUNTS, False),
        ("shadow reverted to the old static zero", GOOD_PROP,
         'open(f"{X}/last_suspend_time", "w").write("0 0\\n")', False),
        ("shadow time not below the threshold", GOOD_PROP,
         'open(f"{X}/last_suspend_time", "w").write("0 5\\n")', False),
    ]
    failed = False
    for name, prop_text, mounts_text, want_clean in cases:
        got_clean = not check(prop_text, mounts_text)
        if got_clean != want_clean:
            print(f"SELFTEST FAIL: {name} -- expected clean={want_clean}, got clean={got_clean}")
            failed = True
    if failed:
        return 1
    print("selftest ok: every fixture behaves as expected")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(PROP_PATH) as f:
        prop_text = f.read()
    with open(MOUNTS_PATH) as f:
        mounts_text = f.read()
    failures = check(prop_text, mounts_text)
    if failures:
        for code, msg in failures:
            print(f"{code}: {msg}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
