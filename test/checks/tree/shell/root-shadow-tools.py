#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

PACKAGED = "/usr/lib/rhizo/tools"
TOOLS = ("rhizo-launch.sh", "appsync.py", "resync.sh")
REDEPLOY = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
USER_ENTRIES = "/root/.local/share/applications/rhizo-*.desktop"

_QUOTE = "[\"']"
INVOKE = tuple(
    re.compile(pat % re.escape(t))
    for t in TOOLS
    for pat in (
        r"(?:python3|python|sh|bash|dash|exec)\s+" + _QUOTE + r"?/root/%s",
        r"(?:^|[;&|]|" + _QUOTE + r")\s*/root/%s(?=[\s\"']|$)",
    )
)
NAMES_ONLY = re.compile(
    r"(?:\[\s*-[erfxs]\s+|\btest\s+-[erfxs]\s+|\becho\b|\bprintf\b|\bls\b|\brm\b)")


def check_text(name, text):
    """return the lines of a text that name a shadowed root tool"""
    found = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split(" #", 1)[0]
        if "/root/" not in code:
            continue
        for pat in INVOKE:
            m = pat.search(code)
            if not m:
                continue
            if NAMES_ONLY.search(code[:m.start()][-40:]):
                continue
            found.append("%s:%d: invokes %s; name %s/<tool> instead"
                         % (name, n, m.group(0).strip(), PACKAGED))
            break
    return found


def missing_removals(text):
    """return the retired paths that have no rm -f"""
    missing = ["/root/%s" % t for t in TOOLS
               if not re.search(r"\brm -f\b[^\n']*/root/%s(?=[\s']|$)" % re.escape(t), text, re.M)]
    if not re.search(r"\brm -f\b[^\n']*%s" % re.escape(USER_ENTRIES), text):
        missing.append(USER_ENTRIES)
    return missing


REDEPLOY_GOOD = "stage_cmd+=$'\\n''rm -f /root/rhizo-launch.sh /root/appsync.py /root/resync.sh %s'\n" % USER_ENTRIES

SELFTEST_GOOD = '''
ssh_vm -t 60 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG $ACT"
# historical: this used to read /root/rhizo-launch.sh
[ -e /root/appsync.py ] && \\
  echo "[rhizo-resync] ignoring the leftover /root/appsync.py -- $APPSYNC is the deployed one" >&2
rm -f /root/appsync.py
'''

SELFTEST_BAD = {
    "ssh body": 'ssh_vm -t 60 "/root/rhizo-launch.sh $PKG $ACT"\n',
    "interpreter": 'python3 /root/appsync.py --local "$INIT"\n',
    "sh": 'sh /root/resync.sh\n',
    "bare": '/root/rhizo-launch.sh com.example .Main\n',
}


def selftest():
    """check the good fixture and each planted-defect fixture"""
    bad = check_text("fixture", SELFTEST_GOOD)
    if bad:
        print("SELFTEST FAILED: a packaged call, a comment, the deliberate "
              "leftover-file warning or an rm was flagged: %s" % bad, file=sys.stderr)
        return 1
    for label, fixture in SELFTEST_BAD.items():
        if not check_text("fixture", fixture):
            print("SELFTEST FAILED: the '%s' invocation was not caught" % label,
                  file=sys.stderr)
            return 1
    if missing_removals(REDEPLOY_GOOD):
        print("SELFTEST FAILED: a redeploy removing every retired copy was flagged: %s"
              % missing_removals(REDEPLOY_GOOD), file=sys.stderr)
        return 1
    for gone, want in (("/root/rhizo-launch.sh ", "/root/rhizo-launch.sh"), (" " + USER_ENTRIES, USER_ENTRIES)):
        if want not in missing_removals(REDEPLOY_GOOD.replace(gone, " ", 1)):
            print("SELFTEST FAILED: a redeploy that leaves %s on the vm disk was not caught" % want,
                  file=sys.stderr)
            return 1
    print("selftest ok: catches a redeploy that leaves a retired /root copy or per-user entry behind")
    print("selftest ok: catches an ssh body, an interpreter, an sh and a bare "
          "invocation; passes the packaged path, a comment, the deliberate "
          "[ -e ] leftover-file warning and an rm")
    return 0


def main():
    """run the check on the repo or run the selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    findings = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", "share", "staged", "detached")
                   and not d.startswith(("share-", "marginal-app-scratch", "driver-proof"))]
        for fn in files:
            if not fn.endswith((".sh", ".py")) or fn == os.path.basename(__file__):
                continue
            p = os.path.join(root, fn)
            try:
                findings += check_text(os.path.relpath(p, REPO),
                                       open(p, encoding="utf-8", errors="replace").read())
            except OSError:
                continue
    for path in missing_removals(open(REDEPLOY, encoding="utf-8").read()):
        findings.append("redeploy.sh never removes %s" % path)
    if findings:
        print("check-root-shadow-tools: a tool is invoked through /root, where a "
              "vm disk keeps a copy no deploy refreshes:", file=sys.stderr)
        for f in findings:
            print("  " + f, file=sys.stderr)
        return 1
    print("no tracked script invokes rhizo-launch.sh, appsync.py or "
          "resync.sh through /root")
    return 0


if __name__ == "__main__":
    sys.exit(main())
