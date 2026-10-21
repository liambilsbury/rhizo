#!/usr/bin/env python3
# check make test runs all of the test files and selftests

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


RUNNERS = ("python3", "bash", "sh", "env")
ASSIGN = re.compile(r"""(?:^|[\s;])([A-Za-z_]\w*)=("[^"]*"|'[^']*'|[^\s;"']+)""")
LOOP = re.compile(r"\bfor\s+([A-Za-z_]\w*)\s+in\s+(.+?);\s*do\b")
VAR = re.compile(r"\$\{?([A-Za-z_]\w*)\}?")
JOIN = re.compile(r"os\.path\.join\(([^()]*)\)")
LITERAL = re.compile(r"""["']([^"']+)["']""")
SPLIT = re.compile(r"""[\s`;|&<>()=,\[\]{}]+""")


def read(path):
    """return a file's text, or an empty string"""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def output(repo, *argv):
    """return the output of a command run in the checkout"""
    r = subprocess.run(argv, cwd=repo, capture_output=True, text=True, env=GIT_ENV)
    if r.returncode != 0:
        raise SystemExit("test-coverage: %s failed: %s" % (" ".join(argv), r.stderr.strip()))
    return r.stdout


def script_of(argv):
    """return the repo path of the script a test's argv runs"""
    for w in argv:
        if w not in RUNNERS:
            return os.path.normpath(os.path.join("test/checks", w))
    return None


def glob_re(pattern):
    """return a regex for a path glob whose * and ? never cross a /"""
    return re.compile("".join("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c) for c in pattern) + r"\Z")


def resolve(word, bases, tracked):
    """return the tracked files a word names and whether it is a glob"""
    if "$" in word:
        word = word[VAR.search(word).end():] if VAR.search(word) else word
        word = word.split("$")[-1].lstrip("/")
    glob = "*" in word or "?" in word
    if not word or word.startswith("/") or not any(c in word for c in "/.*"):
        return set(), glob
    if glob and not re.search(r"[A-Za-z0-9]", word.rsplit("/", 1)[-1]):
        return set(), glob
    for base in bases:
        cand = os.path.normpath(os.path.join(base, word))
        if cand.startswith(".."):
            continue
        if "*" in cand or "?" in cand:
            pattern = glob_re(cand)
            hits = {f for f in tracked if pattern.match(f)}
        else:
            hits = {cand} if cand in tracked else set()
        if hits:
            return hits, glob
    return set(), glob


def code_of(line):
    """return a line without its trailing comment"""
    quote = None
    for i, c in enumerate(line):
        if quote:
            quote = None if c == quote else quote
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def named(rel, text, tracked):
    """return the files a script's code lines name"""
    bases = ("", os.path.dirname(rel), "test/checks")
    lines = [code_of(l) for l in text.split("\n") if l.strip() and not l.lstrip().startswith("#")]
    known = {}
    for line in lines:
        for name, value in ASSIGN.findall(line):
            if name not in known and "$(" not in value and "`" not in value:
                known[name] = value.strip("\"'")
        m = LOOP.search(line)
        if m:
            known[m.group(1)] = m.group(2).strip()
    every, with_selftest = set(), set()
    for line in lines:
        for _ in range(3):
            line = VAR.sub(lambda m: known.get(m.group(1), m.group(0)), line)
        words = SPLIT.split(re.sub("[\"']", "", line)) + ["/".join(LITERAL.findall(j)) for j in JOIN.findall(line)]
        hits = set()
        for w in words:
            found, glob = resolve(w, bases, tracked)
            hits |= found
            if not glob:
                every |= found
        if "--selftest" in line:
            with_selftest |= hits
    return every, with_selftest


def gaps(repo, entries, files):
    """return the test files and selftests none of these tests runs"""
    tracked = set(files)
    scripts, direct, covered = {}, set(), set()
    for e in entries:
        s = script_of(e["argv"])
        if s:
            scripts[s] = read(os.path.join(repo, s))
        hits = set()
        for w in e["argv"]:
            hits |= resolve(w, ("test/checks",), tracked)[0]
        covered |= hits
        if "--selftest" in e["argv"]:
            direct |= hits
    for rel, text in scripts.items():
        every, with_selftest = named(rel, text, tracked)
        covered |= every
        direct |= {f for f in with_selftest if f != rel}
    tests = [f for f in files if f.startswith(("src/", "kernel/")) and "/tests/" in f]
    grew = True
    while grew:
        grew = False
        for f in tests:
            if f in covered:
                more = named(f, read(os.path.join(repo, f)), tracked)[0] - covered
                if more:
                    covered |= more
                    grew = True
    found = ["%s: a tests file no test in make test runs or names" % f for f in tests if f not in covered]
    for f in files:
        if (f.startswith(("src/", "tools/")) and f.endswith((".py", ".sh")) and f not in direct
                and "/tests/" not in f and "--selftest" in read(os.path.join(repo, f))):
            found.append("%s: has a --selftest that no test in make test runs" % f)
    return found


def findings(repo):
    """return each test file and selftest make test does not run"""
    entries = json.loads(output(repo, "python3", "test/checks/lib/check_entries.py", "--json"))
    listed = set(output(repo, "python3", "test/checks/run-tests.py", "--list").splitlines())
    found = []
    for e in entries:
        name = e["label"] + (" (selftest)" if e["kind"] == "selftest" else "")
        if name not in listed:
            found.append("%s: declared in test/checks but not in run-tests.py --list" % e["label"])
    return found + gaps(repo, entries, output(repo, "git", "ls-files").splitlines())


def selftest():
    """check each kind of gap on a fixture checkout"""
    fail = 0
    work = tempfile.mkdtemp(prefix="test-coverage-")

    def put(rel, body):
        """write a fixture file"""
        path = os.path.join(work, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)

    def expect(what, want):
        """check the findings on the fixture as it stands are exactly want"""
        nonlocal fail
        subprocess.run(["git", "-C", work, "add", "-A"], check=True, capture_output=True, env=GIT_ENV)
        got = sorted(findings(work))
        ok = got == sorted(want)
        print("%s selftest: %s%s" % ("ok  " if ok else "FAIL", what, "" if ok else " -- got %s" % got))
        fail |= not ok

    try:
        subprocess.run(["git", "init", "-q", work], check=True, env=GIT_ENV)
        for rel in ("run-tests.py", "lib/check_entries.py"):
            put("test/checks/" + rel, open(os.path.join(REPO, "test/checks", rel)).read())
        put("src/x/tests/test_a.py", "import os\nFIXTURE = 'answer.txt'\n")
        put("src/x/tests/answer.txt", "42\n")
        put("src/x/tool.py", "import sys\nif sys.argv[1:] == ['--selftest']:\n    pass\n")
        put("src/x/selftest_b.py", "import sys\nassert '--selftest' or True\n")
        put("tools/t.sh", "#!/bin/bash\n[[ $1 == --selftest ]] && exit 0\n")
        put("test/checks/x/wrap.sh", "#!/bin/bash\n"
                                     "for t in ../../src/x/selftest_*.py; do python3 \"$t\" --selftest; done\n"
                                     "../../tools/t.sh --selftest\n")
        wrap_row = "x/wrap.sh\trun\t-\tthe x selftests pass\t-\t-\n"
        other_row = "x/other.sh\trun\t-\tother holds\t-\t-\n"
        put("test/checks/checks.tsv", wrap_row)
        rows = ["run\t-\ta passes\tpython3 ../../src/x/tests/test_a.py\n",
                "selftest\t-\ttool\tpython3 ../../src/x/tool.py --selftest\n"]
        put("test/checks/outside.tsv", "".join(rows))
        expect("a checkout whose tests are all run passes", [])
        put("kernel/tests/test-k.sh", "#!/bin/bash\nexit 0\n")
        expect("a kernel tests file no test runs is named",
               ["kernel/tests/test-k.sh: a tests file no test in make test runs or names"])
        put("test/checks/outside.tsv", "".join(rows) + "run\t-\tk passes\t../../kernel/tests/test-k.sh\n")
        expect("a kernel tests file a row runs passes", [])
        put("test/checks/outside.tsv", "".join(rows))
        os.remove(os.path.join(work, "kernel/tests/test-k.sh"))
        put("test/checks/outside.tsv", rows[1])
        expect("a src tests file no test runs is named, and what only it names",
               ["src/x/tests/answer.txt: a tests file no test in make test runs or names",
                "src/x/tests/test_a.py: a tests file no test in make test runs or names"])
        put("test/checks/outside.tsv", rows[0])
        expect("a src script with a selftest no test runs is named",
               ["src/x/tool.py: has a --selftest that no test in make test runs"])
        put("test/checks/outside.tsv", rows[0] + "run\t-\ttool mentioned\tpython3 ../../src/x/tool.py --check\n")
        expect("a test that runs the script without --selftest does not cover its selftest",
               ["src/x/tool.py: has a --selftest that no test in make test runs"])
        put("test/checks/outside.tsv", "".join(rows))
        put("test/checks/x/wrap.sh", "#!/bin/bash\n../../tools/t.sh --selftest\n")
        expect("a glob in a test's selftest line is how a script there is run; without it the script is named",
               ["src/x/selftest_b.py: has a --selftest that no test in make test runs"])
        put("test/checks/x/wrap.sh", "#!/bin/bash\n"
                                     "for t in ../../src/x/selftest_*.py; do python3 \"$t\" --selftest; done\n"
                                     "../../tools/t.sh --selftest\n")
        put("test/checks/checks.tsv", wrap_row + other_row)
        put("test/checks/x/other.sh", "#!/bin/bash\n# names src/x/tests/test_a.py\n"
                                      "cp ../../src/x/tests/pre-fix-test_a.py /dev/null  # src/x/tests/test_a.py\n"
                                      "# python3 ../../src/x/tool.py --selftest\n"
                                      "grep -q selftest ../../src/x/tool.py.orig --selftest\n")
        put("test/checks/outside.tsv", rows[1])
        expect("a longer name, a comment and a header comment naming a src test do not cover it",
               ["src/x/tests/answer.txt: a tests file no test in make test runs or names",
                "src/x/tests/test_a.py: a tests file no test in make test runs or names"])
        put("test/checks/outside.tsv", rows[0])
        expect("a commented-out selftest call and a longer name on a selftest line do not cover a selftest",
               ["src/x/tool.py: has a --selftest that no test in make test runs"])
        put("test/checks/x/other.sh", "#!/bin/bash\ncd \"$(dirname \"$0\")/../../..\"\n"
                                      "X=src/x\nfor t in \"$X\"/tool.py; do\n  python3 \"$t\" --selftest\ndone\n")
        expect("a selftest run through a literal variable and a for loop is covered", [])
        put("test/checks/x/other.sh", "#!/bin/bash\n"
                                      "python3 \"$REPO/src/x/tests/test_a.py\"\n")
        put("test/checks/outside.tsv", rows[1])
        expect("a src test named after an unknown root variable is resolved from the checkout root", [])
        put("test/checks/x/other.sh", "#!/bin/bash\n"
                                      "for f in ../../src/x/tests/*.py; do grep -q import \"$f\"; done\n")
        expect("a glob a test scans does not cover the src tests it matches",
               ["src/x/tests/answer.txt: a tests file no test in make test runs or names",
                "src/x/tests/test_a.py: a tests file no test in make test runs or names"])
        put("test/checks/x/other.sh", "#!/bin/bash\nHERE=\"$(dirname \"$0\")\"\n"
                                      "body() {\n  local root=\"$1\" b=\"$HERE/../../src/x/tests\" line\n"
                                      "  python3 \"$b/test_a.py\"\n}\nbody /tmp\n")
        expect("a src test reached through a second assignment on a local line is covered", [])
        os.remove(os.path.join(work, "test/checks/x/other.sh"))
        put("test/checks/checks.tsv", wrap_row)
        put("test/checks/outside.tsv", "".join(rows))
        runner = os.path.join(work, "test/checks/run-tests.py")
        real = open(runner).read()
        put("test/checks/run-tests.py", real.replace("        for e in selected:\n            print(label(e))",
                                                     "        for e in selected[1:]:\n            print(label(e))"))
        expect("a declared test the runner leaves out of its list is named",
               ["the x selftests pass: declared in test/checks but not in run-tests.py --list"])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("test-coverage.py selftest: %s" % ("FAILED" if fail else "ok"))
    return 1 if fail else 0


def main(argv):
    """print the coverage gaps, or run the selftest"""
    if argv == ["--selftest"]:
        return selftest()
    found = findings(REPO)
    for f in found:
        print("FAIL: %s" % f)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
