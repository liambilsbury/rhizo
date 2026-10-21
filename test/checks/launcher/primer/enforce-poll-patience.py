#!/usr/bin/env python3
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

REDEPLOY_PATH = os.path.join(HERE, "..", "..", "..", "vm", "redeploy.sh")
LAUNCHER_PATH = os.path.join(REPO, "src", "androidd", "boot.py")

BASE_DEADLINE_RE = re.compile(
    r'enforce_base_deadline=\$\(\(\s*\$\(date \+%s\)\s*\+\s*(\d+)\s*\)\)')
CEILING_DEADLINE_RE = re.compile(
    r'enforce_ceiling=\$\(\(\s*\$\(date \+%s\)\s*\+\s*(\d+)\s*\)\)')

LIVENESS_NEEDLE = "pgrep -f rhizo-host-primer"

MODE_REFUSAL_RE = re.compile(
    r'^if \[\[ "\$\{RHIZO_SELINUX_MODE:-host\}" != host \]\]; then\n(?:[^\n]*\n)*?  exit 2\nfi$', re.M)
STAGING_START = "stage_cmd='set -e"


def _host_primer_src(launcher_src):
    """return the HOST_PRIMER_SRC string literal"""
    tree = ast.parse(launcher_src)
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(t, ast.Name) and t.id == "HOST_PRIMER_SRC" for t in node.targets):
            continue
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            return node.value.value
    return None


def _primer_restart_timeout(launcher_text):
    """return the timeout of the primer restart call"""
    primer_src = _host_primer_src(launcher_text)
    if primer_src is None:
        return None
    for node in ast.walk(ast.parse(primer_src)):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "run"):
            continue
        if not node.args or not isinstance(node.args[0], ast.List):
            continue
        elts = node.args[0].elts
        strs = [e.value for e in elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
        names = [e.id for e in elts if isinstance(e, ast.Name)]
        if "systemctl" in strs and "restart" in strs and "u" in names:
            for kw in node.keywords:
                if kw.arg == "timeout" and isinstance(kw.value, ast.Constant):
                    return kw.value.value
    return None


def check(redeploy_text, launcher_text):
    """return the findings for both file contents"""
    bad = []

    primer_timeout = _primer_restart_timeout(launcher_text)
    if primer_timeout is None:
        return ["launcher3.py: no subprocess.run([\"systemctl\", \"restart\", u], "
                "timeout=N) call found in HOST_PRIMER_SRC's restart pass"]

    mb = BASE_DEADLINE_RE.search(redeploy_text)
    mc = CEILING_DEADLINE_RE.search(redeploy_text)
    if not mb or not mc:
        return ["redeploy.sh: the enforce poll no longer sets both "
                "enforce_base_deadline and enforce_ceiling from "
                "\"$(date +%s) + N\""]
    base, ceiling = int(mb.group(1)), int(mc.group(1))

    if LIVENESS_NEEDLE not in redeploy_text:
        bad.append(
            "redeploy.sh: the enforce poll no longer checks `%s` before "
            "failing past its base %ds deadline" % (LIVENESS_NEEDLE, base))

    refusal = MODE_REFUSAL_RE.search(redeploy_text)
    staging = redeploy_text.find(STAGING_START)
    if refusal is None or staging < 0 or refusal.start() > staging:
        bad.append(
            "redeploy.sh: no `if [[ \"${RHIZO_SELINUX_MODE:-host}\" != host ]]` block exits 2 before %s" % STAGING_START)

    if ceiling - base < primer_timeout:
        bad.append(
            "redeploy.sh's enforce poll extends only %ds past its base %ds "
            "wait, but launcher3.py's own stuck-unit restart timeout is "
            "%ds" % (ceiling - base, base, primer_timeout))

    return bad


def read_sources():
    """return the text of the redeploy and launcher files"""
    return open(REDEPLOY_PATH).read(), open(LAUNCHER_PATH).read()


def selftest():
    """run the check on seeded regressions"""
    redeploy_text, launcher_text = read_sources()
    n = 0

    found = check(redeploy_text, launcher_text)
    assert found == [], "the real tree must pass clean: %s" % found
    n += 1

    no_liveness = redeploy_text.replace(LIVENESS_NEEDLE, "true")
    assert no_liveness != redeploy_text, "fixture did not apply"
    found = check(no_liveness, launcher_text)
    assert any("no longer checks" in f and "before failing past its base" in f
               for f in found), \
        "a poll with no primer liveness check must be reported: %s" % found
    n += 1

    narrow_ceiling = redeploy_text.replace(
        "enforce_ceiling=$(( $(date +%s) + 150 ))",
        "enforce_ceiling=$(( $(date +%s) + 65 ))", 1)
    assert narrow_ceiling != redeploy_text, "fixture did not apply"
    found = check(narrow_ceiling, launcher_text)
    assert any("extends only 5s past its base 60s wait" in f for f in found), \
        "a ceiling narrower than the primer's own timeout must be reported: %s" % found
    n += 1

    refusal = MODE_REFUSAL_RE.search(redeploy_text)
    assert refusal is not None, "fixture did not apply"
    no_refusal = redeploy_text[:refusal.start()] + redeploy_text[refusal.end():]
    found = check(no_refusal, launcher_text)
    assert any("block exits 2 before" in f for f in found), \
        "a redeploy with no namespace-mode refusal must be reported: %s" % found
    n += 1

    launch = no_refusal.find('\nLAUNCH_ENV=""\n')
    assert launch > no_refusal.find(STAGING_START) >= 0, "fixture did not apply"
    late_refusal = no_refusal[:launch + 1] + refusal.group(0) + "\n" + no_refusal[launch + 1:]
    found = check(late_refusal, launcher_text)
    assert any("block exits 2 before" in f for f in found), \
        "a namespace-mode refusal placed after staging starts must be reported: %s" % found
    n += 1

    raised_primer_timeout = launcher_text.replace(
        '"--job-mode=ignore-dependencies", u],\n                                    timeout=20,',
        '"--job-mode=ignore-dependencies", u],\n                                    timeout=120,', 1)
    assert raised_primer_timeout != launcher_text, "fixture did not apply"
    found = check(redeploy_text, raised_primer_timeout)
    assert any("launcher3.py's own stuck-unit restart timeout is 120s" in f
               for f in found), \
        "a primer timeout raised without a matching ceiling must be reported: %s" % found
    n += 1

    print("check-enforce-poll-patience selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = check(*read_sources())
    for f in findings:
        print("check-enforce-poll-patience: " + f)
    sys.exit(1 if findings else 0)
