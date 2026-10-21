#!/usr/bin/env python3
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM_DIR = os.path.join(HERE, "..", "..", "system")
TABLE = os.path.join(HERE, "..", "..", "..", "tools", "build", "artifacts.tsv")
sys.path.insert(0, os.path.join(SYSTEM_DIR, "run"))
import system_tests  # noqa: E402

EXEMPT = []

REF_RE = re.compile(r'\$(?:VAR_DIR"?/share|SHARE_DIR)/([A-Za-z0-9_./*${}-]+\.apk)')
PATTERN_RE = re.compile(
    r'^([A-Za-z0-9_./-]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?([A-Za-z0-9_./-]*\.apk)$')


def load_stamps():
    """return the build stamps module loaded from its file"""
    spec = importlib.util.spec_from_file_location(
        "stamps", os.path.join(HERE, "..", "..", "..", "tools", "build", "stamps.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def strip_comments(text):
    """remove whole-line comments from text"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("#"))


def find_apk_refs(body):
    """return the distinct apk references in a body"""
    seen = []
    for m in REF_RE.finditer(body):
        raw = m.group(1)
        if raw not in seen:
            seen.append(raw)
    return seen


def array_literal(body, name):
    """return the words of a NAME=(...) array"""
    m = re.search(r'\b%s=\(([^)]*)\)' % re.escape(name), body)
    return m.group(1).split() if m else None


def function_taking_param(body, var):
    """find the function with parameter var"""
    for fm in re.finditer(r'^(\w+)\(\)\s*\{', body, re.M):
        end = body.find("\n}", fm.end())
        fbody = body[fm.end():end if end != -1 else len(body)]
        if re.search(r'\blocal\s+%s="\$[0-9]"' % re.escape(var), fbody) or \
           re.search(r'(?<![.\w])%s="\$[0-9]"' % re.escape(var), fbody):
            return fm.group(1)
    return None


def iterable_for(body, var, _depth=0):
    """return the for loop words for var"""
    if _depth > 4:
        return None
    m = re.search(r'for\s+%s\s+in\s+"\$\{(\w+)\[@\]\}"' % re.escape(var), body)
    if m:
        return array_literal(body, m.group(1))
    m = re.search(r'for\s+%s\s+in\s+([^\n;]+?)\s*;?\s*do\b' % re.escape(var), body)
    if m and "$" not in m.group(1):
        return m.group(1).split()
    fn = function_taking_param(body, var)
    if not fn:
        return None
    call = re.search(r'(?<![.\w])%s\s+"\$(\w+)"' % re.escape(fn), body)
    if not call:
        return None
    return iterable_for(body, call.group(1), _depth + 1)


def resolve_pattern(body, raw):
    """expand an apk reference to artifact names"""
    m = PATTERN_RE.match(raw)
    if not m:
        return None
    prefix, var, suffix = m.groups()
    words = iterable_for(body, var)
    if words is None:
        return None
    return [prefix + w + suffix for w in words]


def check_coverage(tests_dir, table=TABLE, exempt=EXEMPT):
    """return the untracked APK references"""
    mod = load_stamps()
    known = {n for n, _, _ in mod.rows(table)}
    findings = []
    exempt_map = {}
    for test, artifact, unblocker in exempt:
        if not unblocker.strip():
            findings.append("EXEMPT entry for %s %s has an empty unblocker" % (test, artifact))
            continue
        exempt_map[(test, artifact)] = unblocker

    for path in system_tests.system_test_paths(tests_dir):
        base = os.path.basename(path)
        with open(path) as f:
            body = strip_comments(f.read())
        for raw in find_apk_refs(body):
            if (base, raw) in exempt_map:
                continue
            if "$" in raw:
                names = resolve_pattern(body, raw)
                if names is None:
                    findings.append(
                        "%s reads a pattern %s this checker could not expand "
                        "to a fixed list of names -- give it a staged-"
                        "artifacts.tsv row per name it can build, or an "
                        "EXEMPT entry naming why not" % (base, raw))
                    continue
                for name in names:
                    if name not in known and (base, name) not in exempt_map:
                        findings.append(
                            "%s reads %s (from pattern %s), which has no "
                            "artifacts.tsv row and no EXEMPT entry"
                            % (base, name, raw))
            elif "*" in raw:
                findings.append(
                    "%s reads a glob %s" % (base, raw))
            else:
                if raw not in known:
                    findings.append(
                        "%s reads %s, which has no artifacts.tsv row "
                        "and no EXEMPT entry" % (base, raw))
    return findings


def selftest():
    """run the coverage checks on fixture tests"""
    import shutil
    import tempfile
    n = 0
    tmp = tempfile.mkdtemp()
    try:
        test = os.path.join(tmp, "fixture.sh")
        table = os.path.join(tmp, "artifacts.tsv")

        def write_test(body):
            """write a test file with the given body"""
            with open(test, "w") as f:
                f.write(body)

        def write_table(rows):
            """write a table file with the given rows"""
            with open(table, "w") as f:
                for row in rows:
                    f.write("\t".join(tuple(row) + ("test", "-")) + "\n")

        good_test = '''#!/bin/bash
# test-boot-mode: no-vm -- fixture
PLAIN_APK="$VAR_DIR/share/fixture-plain.apk"
VPN_APK="$VAR_DIR/share/fixture-vpn.apk"
PROBE_APK="$SHARE_DIR/fixture-probe.apk"
FIXTURES=(alpha beta)
run_one() {
  local name="$1" apk
  apk="$VAR_DIR/share/fixture-multi-$name.apk"
}
for fx in "${FIXTURES[@]}"; do run_one "$fx"; done
GLOB_APKS=("$VAR_DIR"/share/extra-apps/*.apk)
'''
        good_table = [
            ("fixture-plain.apk", "build.sh", "src"),
            ("fixture-vpn.apk", "build.sh", "src"),
            ("fixture-probe.apk", "build.sh", "src"),
            ("fixture-multi-alpha.apk", "build.sh", "src"),
            ("fixture-multi-beta.apk", "build.sh", "src"),
        ]
        good_exempt = [("fixture.sh", "extra-apps/*.apk", "fixture unblocker")]

        write_test(good_test)
        write_table(good_table)
        assert check_coverage(tmp, table, good_exempt) == [], check_coverage(tmp, table, good_exempt)
        n += 1

        write_table([r for r in good_table if r[0] != "fixture-vpn.apk"])
        out = check_coverage(tmp, table, good_exempt)
        assert any("fixture-vpn.apk" in f and "fixture.sh" in f for f in out), out
        n += 1
        write_table(good_table)
        assert check_coverage(tmp, table, good_exempt) == []
        n += 1

        write_test(good_test.replace('FIXTURES=(alpha beta)', 'RENAMED=(alpha beta)'))
        out = check_coverage(tmp, table, good_exempt)
        assert any("fixture-multi-$name.apk" in f and "could not expand" in f for f in out), out
        n += 1
        write_test(good_test)
        assert check_coverage(tmp, table, good_exempt) == []
        n += 1

        out = check_coverage(tmp, table, [("fixture.sh", "extra-apps/*.apk", "")])
        assert any("empty unblocker" in f for f in out), out
        n += 1

        out = check_coverage(tmp, table, [])
        assert any("extra-apps/*.apk" in f and "glob" in f for f in out), out
        n += 1

        print("check-staged-coverage selftest: %d assertions passed" % n)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    """run the coverage check or its selftest and print the result"""
    if "--selftest" in argv:
        selftest()
        return 0
    tests_dir = os.environ.get("RHIZO_CHECK_TESTS", SYSTEM_DIR)
    findings = check_coverage(tests_dir)
    for f in findings:
        print("check-staged-coverage: " + f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
