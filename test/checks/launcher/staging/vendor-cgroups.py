#!/usr/bin/env python3
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STAGED = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "vendor", "cgroups.json")

STOCK_V1 = {
    "blkio": {"Path": "/dev/blkio", "Mode": "0775", "UID": "system", "GID": "system"},
    "cpuset": {"Path": "/dev/cpuset", "Mode": "0755", "UID": "system", "GID": "system"},
}


def check(doc):
    """return findings for the cgroups.json shape"""
    failures = []

    def check_optional(entry, where):
        """record a failure when an entry lacks the Optional key"""
        if "Optional" not in entry:
            failures.append(("OPTIONAL-MISSING",
                             f"{where}: Optional is absent"))
            return
        if not isinstance(entry["Optional"], bool):
            failures.append(("OPTIONAL-NOT-BOOL",
                             f"{where}: Optional is {type(entry['Optional']).__name__}, "
                             "not a JSON boolean"))
            return
        if entry["Optional"] is not True:
            failures.append(("OPTIONAL-FALSE",
                             f"{where}: Optional is false"))

    cgroups = doc.get("Cgroups", [])
    if not isinstance(cgroups, list):
        failures.append(("NO-CGROUPS", "top-level Cgroups is missing or not an array"))
        cgroups = []
    for entry in cgroups:
        controller = entry.get("Controller")
        where = f"Cgroups[{controller or '?'}]"
        check_optional(entry, where)
        if controller == "cpu":
            failures.append(("CPU-UNDER-V1",
                             "cpu is declared under the top-level Cgroups array"))
        elif controller in STOCK_V1:
            for field, want in STOCK_V1[controller].items():
                got = entry.get(field)
                if got != want:
                    failures.append((f"{controller.upper()}-{field.upper()}-DRIFT",
                                     f"{where}.{field} is {got!r}, stock is {want!r}"))

    cg2 = doc.get("Cgroups2")
    if not isinstance(cg2, dict):
        failures.append(("NO-CGROUPS2", "top-level Cgroups2 is missing or not an object"))
        return failures
    check_optional(cg2, "Cgroups2 (root)")
    if "Mode" not in cg2:
        failures.append(("ROOT-NO-MODE",
                         "Cgroups2 root has no Mode"))
    if "UID" in cg2 or "GID" in cg2:
        failures.append(("ROOT-HAS-OWNER",
                         "Cgroups2 root restates UID/GID"))

    controllers = cg2.get("Controllers", [])
    if not isinstance(controllers, list):
        controllers = []
    names = {c.get("Controller") for c in controllers}
    for entry in controllers:
        check_optional(entry, f"Cgroups2.Controllers[{entry.get('Controller', '?')}]")
    if "cpu" not in names:
        failures.append(("NO-CPU", "no cpu entry under Cgroups2.Controllers"))
    for banned in ("freezer", "memory"):
        if banned in names:
            failures.append((f"RESTATES-{banned.upper()}",
                             f"{banned} is declared under Cgroups2.Controllers"))

    return failures


GOOD = {
    "Cgroups": [
        {"Controller": "blkio", "Path": "/dev/blkio", "Mode": "0775",
         "UID": "system", "GID": "system", "Optional": True},
        {"Controller": "cpuset", "Path": "/dev/cpuset", "Mode": "0755",
         "UID": "system", "GID": "system", "Optional": True},
    ],
    "Cgroups2": {
        "Path": "/sys/fs/cgroup",
        "Mode": "0775",
        "Optional": True,
        "Controllers": [
            {"Controller": "cpu", "Path": ".", "NeedsActivation": True,
             "MaxActivationDepth": 3, "Optional": True},
        ],
    },
}


def selftest():
    """test the cgroups.json checks"""
    import copy

    cases = []
    cases.append(("the real shape", GOOD, set()))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Controllers"][0]["Optional"] = "true"
    cases.append(("Optional as a string", bad, {"OPTIONAL-NOT-BOOL"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["UID"] = "system"
    bad["Cgroups2"]["GID"] = "system"
    cases.append(("root restates UID/GID", bad, {"ROOT-HAS-OWNER"}))

    bad = copy.deepcopy(GOOD)
    del bad["Cgroups2"]["Mode"]
    cases.append(("root missing Mode", bad, {"ROOT-NO-MODE"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups"].append({"Controller": "cpu", "Path": "/dev/cpuctl",
                           "Mode": "0755", "UID": "system", "GID": "system", "Optional": True})
    cases.append(("cpu left under v1 Cgroups", bad, {"CPU-UNDER-V1"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Controllers"] = []
    cases.append(("no cpu controller at all", bad, {"NO-CPU"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Controllers"].append({"Controller": "memory", "Path": ".",
                                           "NeedsActivation": True, "Optional": True})
    cases.append(("memory restated", bad, {"RESTATES-MEMORY"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Controllers"].append({"Controller": "freezer", "Path": ".",
                                           "Optional": True})
    cases.append(("freezer restated", bad, {"RESTATES-FREEZER"}))

    bad = copy.deepcopy(GOOD)
    del bad["Cgroups"][0]["Optional"]
    cases.append(("blkio Optional missing", bad, {"OPTIONAL-MISSING"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups"][0]["Optional"] = False
    cases.append(("blkio Optional false", bad, {"OPTIONAL-FALSE"}))

    bad = copy.deepcopy(GOOD)
    del bad["Cgroups2"]["Optional"]
    cases.append(("Cgroups2 root Optional missing", bad, {"OPTIONAL-MISSING"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Optional"] = False
    cases.append(("Cgroups2 root Optional false", bad, {"OPTIONAL-FALSE"}))

    bad = copy.deepcopy(GOOD)
    del bad["Cgroups2"]["Controllers"][0]["Optional"]
    cases.append(("cpu controller Optional missing", bad, {"OPTIONAL-MISSING"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups2"]["Controllers"][0]["Optional"] = False
    cases.append(("cpu controller Optional false", bad, {"OPTIONAL-FALSE"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups"][0]["Mode"] = "0755"
    cases.append(("blkio Mode drifts from stock", bad, {"BLKIO-MODE-DRIFT"}))

    bad = copy.deepcopy(GOOD)
    del bad["Cgroups"][1]["UID"]
    cases.append(("cpuset UID dropped", bad, {"CPUSET-UID-DRIFT"}))

    bad = copy.deepcopy(GOOD)
    bad["Cgroups"][1]["GID"] = "root"
    cases.append(("cpuset GID drifts from stock", bad, {"CPUSET-GID-DRIFT"}))

    for label, doc, want in cases:
        got = {rule for rule, _detail in check(doc)}
        if got != want:
            print("SELFTEST FAILED: %s -- wanted %s, got %s"
                  % (label, sorted(want) or "no findings", sorted(got)), file=sys.stderr)
            return 1
    print("selftest ok: accepts the real shape, and catches a string/missing/false Optional "
          "on blkio, the Cgroups2 root and the cpu controller; a root that restates UID/GID; "
          "a root missing Mode; cpu left under v1 Cgroups; a missing cpu controller; "
          "freezer/memory restated; and blkio/cpuset drifting from the stock Path/Mode/UID/GID")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(STAGED):
        print(f"vendor-cgroups.py: {STAGED} not found", file=sys.stderr)
        return 1
    try:
        doc = json.loads(open(STAGED).read())
    except ValueError as e:
        print(f"vendor-cgroups.py: {STAGED} does not parse as JSON: {e}", file=sys.stderr)
        return 1
    failures = check(doc)
    if failures:
        print(f"{STAGED} has the wrong shape:", file=sys.stderr)
        for rule, detail in failures:
            print(f"  [{rule}] {detail}", file=sys.stderr)
        return 1
    print("vendor-cgroups.json: Optional is present and true throughout, blkio/cpuset match "
          "stock Path/Mode/UID/GID, the v2 root carries Mode with no UID/GID, cpu lives only "
          "under Cgroups2, and freezer/memory are untouched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
