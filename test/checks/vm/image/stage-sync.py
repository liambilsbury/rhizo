#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REDEPLOY = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
SYNC = os.path.join(HERE, "..", "..", "..", "vm", "sync.sh")
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
import unit_files  # noqa: E402
TOOL_DIRS = tool_dirs(ROOT)
UNIT_DIRS = sorted({os.path.dirname(rel) for rel in unit_files.unit_files(ROOT).values()})
TEST_DIRS = tuple(d for d in test_dirs(ROOT) if not d.startswith("test/checks"))
SOURCE_DIRS = [os.path.join(ROOT, d) for d in (
    *TEST_DIRS, *TOOL_DIRS,
    "src/androidd", "src/install", "src/services", *UNIT_DIRS)]
LAUNCHER_MODULE = re.compile(r"^(launcher|rhizo_[a-z_]+)\.py$")


EXTENSIONS = (".sh", ".path", ".service", ".py")
SHARE_LITERAL = re.compile(r"/root/share/([A-Za-z0-9._-]+)(?![A-Za-z0-9._/-])")


def stage_files(redeploy_text):
    """return the file names listed in the STAGE_FILES array"""
    m = re.search(r"STAGE_FILES=\((.*?)\n\)", redeploy_text, re.DOTALL)
    if not m:
        return []
    return [l.strip() for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith("#")]


def staged_names(redeploy_text):
    """return the staged names from the array and the share literals"""
    names = list(stage_files(redeploy_text))
    for n in SHARE_LITERAL.findall(redeploy_text):
        if n not in names:
            names.append(n)
    return names


def synced_names(sync_text):
    """return the share destination names of the sync_one lines"""
    return set(re.findall(r"sync_one\s+\S+\s+var/share/(\S+)", sync_text))


def check(redeploy_text, sync_text, source_dirs):
    """return the staged names absent from sync_text"""
    missing = []
    synced = synced_names(sync_text)
    for entry in staged_names(redeploy_text):
        if not entry.endswith(EXTENSIONS):
            continue
        if source_dirs is not None and (LAUNCHER_MODULE.match(entry) or not any(
                os.path.exists(os.path.join(d, entry)) for d in source_dirs)):
            continue
        if entry not in synced:
            missing.append(entry)
    return missing


SELFTEST_REDEPLOY = """
STAGE_FILES=(
  rhizo-launch.sh
  rhizo-release-idle-display.sh
  rhizo-display-pool-release.service
)
"""
SELFTEST_SYNC_COMPLETE = """
sync_one test/vm/rhizo-launch.sh var/share/rhizo-launch.sh
sync_one test/vm/rhizo-release-idle-display.sh var/share/rhizo-release-idle-display.sh
sync_one test/vm/rhizo-display-pool-release.service var/share/rhizo-display-pool-release.service
"""
SELFTEST_SYNC_MISSING = """
sync_one test/vm/rhizo-launch.sh var/share/rhizo-launch.sh
"""
SELFTEST_REDEPLOY_INSTALL = """
STAGE_FILES=(
  rhizo-launch.sh
)
stage_cmd+=$'\\n''install -m 0755 /root/share/appsync.py /usr/lib/rhizo/tools/
install -m 0644 /root/share/rhizo-cgroup-unfreeze.sh /usr/lib/rhizo/tools/rhizo-cgroup-unfreeze.sh
cp /root/share/rel/a17/netd.rc /root/netd.rc'
"""
SELFTEST_SYNC_INSTALL_PARTIAL = """
sync_one test/vm/rhizo-launch.sh var/share/rhizo-launch.sh
sync_one test/vm/rhizo-cgroup-unfreeze.sh var/share/rhizo-cgroup-unfreeze.sh
"""
SELFTEST_SYNC_NON_TOOLS_SOURCE = """
sync_one test/vm/rhizo-launch.sh var/share/rhizo-launch.sh
sync_one src/install/appsync.py var/share/appsync.py
sync_one test/vm/rhizo-cgroup-unfreeze.sh var/share/rhizo-cgroup-unfreeze.sh
"""


def selftest():
    """run the stage-sync cases on fixtures"""
    import tempfile
    with tempfile.TemporaryDirectory(prefix="check-stage-sync-selftest-") as fixture_dir:
        for name in ("rhizo-launch.sh", "rhizo-release-idle-display.sh", "rhizo-display-pool-release.service",
                     "appsync.py", "rhizo-cgroup-unfreeze.sh", "rhizo-display-list.sh"):
            open(os.path.join(fixture_dir, name), "w").close()
        cases = [
            ("every entry synced", SELFTEST_REDEPLOY, SELFTEST_SYNC_COMPLETE, [fixture_dir], []),
            ("two entries never synced", SELFTEST_REDEPLOY, SELFTEST_SYNC_MISSING, [fixture_dir],
             ["rhizo-release-idle-display.sh", "rhizo-display-pool-release.service"]),
            ("no source_dirs filter, all missing", SELFTEST_REDEPLOY, "", None,
             ["rhizo-launch.sh", "rhizo-release-idle-display.sh", "rhizo-display-pool-release.service"]),
            ("a /root/share literal nothing syncs", SELFTEST_REDEPLOY_INSTALL,
             SELFTEST_SYNC_INSTALL_PARTIAL, [fixture_dir], ["appsync.py"]),
            ("a /root/share literal synced from outside tools/", SELFTEST_REDEPLOY_INSTALL,
             SELFTEST_SYNC_NON_TOOLS_SOURCE, [fixture_dir], []),
        ]
        for label, redeploy_text, sync_text, source_dirs, want in cases:
            got = check(redeploy_text, sync_text, source_dirs)
            if got != want:
                print("SELFTEST FAILED: %s -- wanted %s, got %s" % (label, want, got), file=sys.stderr)
                return 1
    print("selftest ok: accepts every staged name with a sync_one line, from STAGE_FILES or a "
          "/root/share literal, and catches names with none")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not (os.path.exists(REDEPLOY) and os.path.exists(SYNC)):
        print("stage-sync.py: redeploy.sh or sync.sh not found", file=sys.stderr)
        return 1
    missing = check(open(REDEPLOY).read(), open(SYNC).read(), SOURCE_DIRS)
    if missing:
        print("names redeploy.sh reads from /root/share with no sync_one line in sync.sh (never reach share/, "
              "the guest-side cp then fails with no host-side signal until boot):", file=sys.stderr)
        for m in missing:
            print("  %s" % m, file=sys.stderr)
        return 1
    print("every name redeploy.sh stages out of share/ and sources in the tree has a sync_one line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
