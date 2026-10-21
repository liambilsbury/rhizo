#!/usr/bin/env python3
# check sourced libraries read files from their location

import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}

SOURCE = re.compile(r"""(?:^|[;&|({]|\bthen\b|\bdo\b|\belse\b)[ \t]*(?:source|\.)[ \t]+("(?:\$\([^)\n]*\)|[^"\n])+"|'[^'\n]+'|[^;&|\s]+)""", re.M)
CWD_PATH = re.compile(r"""(?:(?<=^)|(?<=[\s=(`"'|;&<>]))(\.\.?/[\w./@+-]*[\w@+-])""", re.M)
OWN_PATH = re.compile(r"""(?:\$\{?_[A-Z0-9_]+_DIR\}?|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\))/([\w./@+-]*[\w@+-])""")
REPO_VAR = re.compile(r"""^"?\$\{?(?:REPO|ROOT)\}?/(.+?)"?$""")
RENAMED = {"test/system/lib/desktop-lib.sh": "HERE"}


def tracked(root):
    """list the files git tracks under root"""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True, env=GIT_CLEAN_ENV).stdout
    return [p for p in out.decode().split("\0") if p]


def read(root, rel):
    """return a tracked file's text, or an empty string"""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def code_lines(text):
    """yield the numbered non-comment lines outside heredocs"""
    end = None
    for n, line in enumerate(text.splitlines(), 1):
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if line.lstrip().startswith("#"):
            continue
        yield n, line
        if m:
            end = m.group(1)


OWN_DIR_PREFIX = re.compile(r"""^(?:\$\{?(?:HERE|TOOLS|TOOLS_DIR|SELF_DIR|BENCH_DIR|BENCH_ROOT|LC_TOOLS_DIR|_[A-Z0-9_]+_DIR)\}?"""
                            r"""|\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\))/""")


def resolve_source(target, sourcer, files):
    """return the repo paths a source statement names"""
    t = target.strip("\"'")
    d = os.path.dirname(sourcer)
    m = REPO_VAR.match(t)
    if m:
        p = m.group(1)
    elif OWN_DIR_PREFIX.match(t):
        p = os.path.join(d, OWN_DIR_PREFIX.sub("", t))
    elif "$" in t:
        return []
    else:
        p = os.path.join(d, t)
    if "$" not in p:
        p = os.path.normpath(p)
        if p not in files and not m and not t.startswith(("./", "../", "/")):
            p = os.path.normpath(t)
        return [p] if p in files else []
    pattern = re.compile("^" + ".*".join(re.escape(os.path.normpath(x)) if x else "" for x in re.split(r"\$\{?\w+\}?", p)) + "$")
    return [f for f in files if pattern.match(f)]


def sourced(root, files):
    """return {script: the shell files under test/ it sources}"""
    out = {}
    for f in files:
        if not f.endswith(".sh"):
            continue
        for _, line in code_lines(read(root, f)):
            for m in SOURCE.finditer(line):
                for p in resolve_source(m.group(1), f, files):
                    if p.startswith("test/") and p.endswith(".sh"):
                        out.setdefault(f, set()).add(p)
    return out


def libraries(root, files):
    """return the folders of the scripts sourcing each library"""
    libs = {}
    for f, ps in sourced(root, files).items():
        for p in ps:
            libs.setdefault(p, set()).add(os.path.dirname(f))
    return libs


def renamed_reads(root, files):
    """list the reads of variables a sourced library no longer sets"""
    out = []
    for f, ps in sorted(sourced(root, files).items()):
        for lib in sorted(ps & set(RENAMED)):
            var = RENAMED[lib]
            lines = list(code_lines(read(root, f)))
            if any(re.search(r"(?:^|[\s;&(])(?:export\s+|local\s+|declare\s+\S*\s*)?%s=" % var, t) for _, t in lines):
                continue
            for n, t in lines:
                if re.search(r"\$\{?%s\b" % var, t):
                    out.append("%s:%d: reads %s, which %s does not set" % (f, n, var, lib))
    return out


def findings(root, resolve=False):
    """list each library line reading a path from its caller's folder"""
    files = tracked(root)
    fileset = set(files)
    dirs = {os.path.dirname(f) for f in files}
    while True:
        more = {os.path.dirname(d) for d in dirs if d} - dirs
        if not more:
            break
        dirs |= more
    out = renamed_reads(root, fileset)
    libs = libraries(root, fileset)
    for lib in sorted(libs):
        d = os.path.dirname(lib)
        for n, line in code_lines(read(root, lib)):
            for m in CWD_PATH.finditer(line):
                hits = [os.path.normpath(os.path.join(c, m.group(1).rstrip("/"))) for c in {d} | libs[lib]]
                if any(p in fileset or p in dirs for p in hits):
                    out.append("%s:%d: %s is read from the caller's folder, not the library's own" % (lib, n, m.group(1)))
            if resolve:
                for m in OWN_PATH.finditer(line):
                    p = os.path.normpath(os.path.join(d, m.group(1).rstrip("/")))
                    if p not in fileset and p not in dirs and "*" not in m.group(1):
                        out.append("%s:%d: %s names %s, which does not exist" % (lib, n, m.group(0), p))
    return out


def run_fixture(files, resolve=False):
    """return the findings for files committed to a scratch repo"""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "init", "-q", tmp], check=True, env=GIT_CLEAN_ENV)
        for rel, body in files.items():
            path = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(body)
        subprocess.run(["git", "-C", tmp, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        return findings(tmp, resolve)


def selftest():
    """check each finding on fixtures, flagged and clean"""
    good = {
        "test/vm/common.sh": "",
        "test/vm/start/start-sway.sh": "",
        "test/system/a.sh": 'cd "$(dirname "${BASH_SOURCE[0]}")"\nsource ../vm/common.sh\nsource ./x-lib.sh\n../vm/start/start-sway.sh\n',
        "test/system/x-lib.sh": ('_X_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\n'
                                 'go() { "$_X_LIB_DIR/../vm/start/start-sway.sh"; }\n'
                                 '# ../vm/start/start-sway.sh in a comment is not code\n'
                                 'cat <<EOF\n../vm/start/start-sway.sh in a heredoc is text\nEOF\n'
                                 'ssh_vm "apt-get install -y ./rhizo_*.deb"\n'),
        "test/system/lib/desktop-lib.sh": 'LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n',
        "test/system/lib/stats.py": "",
        "test/system/lib/d.sh": ('HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
                                 'source "$(dirname "${BASH_SOURCE[0]}")/desktop-lib.sh"\n'
                                 '"$HERE/stats.py"\n"$LIB_ROOT/stats.py"\n'),
    }
    cases = [
        ({"test/system/x-lib.sh": "go() { ../vm/start/start-sway.sh; }\n"}, False,
         "test/system/x-lib.sh:1: ../vm/start/start-sway.sh is read from the caller's folder"),
        ({"test/system/x-lib.sh": "scp ./a.sh host:\n"}, False, "./a.sh is read from the caller's folder"),
        ({"test/system/x-lib.sh": '_X_LIB_DIR=.\ngo() { "$_X_LIB_DIR/../vm/gone.sh"; }\n'}, True,
         "names test/vm/gone.sh, which does not exist"),
        ({"test/system/x-lib.sh": ('_X_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)\n'
                                   'source "$_X_LIB_DIR/y-lib.sh"\n'),
          "test/system/y-lib.sh": "go() { ../vm/start/start-sway.sh; }\n"}, False,
         "test/system/y-lib.sh:1: ../vm/start/start-sway.sh is read from the caller's folder"),
        ({"test/system/a.sh": 'source "$(dirname "${BASH_SOURCE[0]}")/y-lib.sh"\n',
          "test/system/y-lib.sh": "go() { ../vm/start/start-sway.sh; }\n"}, False,
         "test/system/y-lib.sh:1: ../vm/start/start-sway.sh is read from the caller's folder"),
        ({"test/system/a.sh": 'cd "$REPO"\nsource test/system/y-lib.sh\n',
          "test/system/y-lib.sh": "go() { ../vm/start/start-sway.sh; }\n"}, False,
         "test/system/y-lib.sh:1: ../vm/start/start-sway.sh is read from the caller's folder"),
        ({"test/system/lib/d.sh": 'source "$(dirname "${BASH_SOURCE[0]}")/desktop-lib.sh"\n"$HERE/stats.py"\n'},
         False, "test/system/lib/d.sh:2: reads HERE, which test/system/lib/desktop-lib.sh does not set"),
    ]
    fail = 0
    got = run_fixture(good, resolve=True)
    if got:
        print("SELFTEST FAIL: a clean fixture was flagged: %s" % got)
        fail = 1
    else:
        print("ok   selftest: an own-folder path, a comment, a heredoc, a guest-side ./ path and a test script's own ../ pass")
    for over, resolve, want in cases:
        files = dict(good)
        files.update(over)
        got = run_fixture(files, resolve)
        if any(want in g for g in got):
            print("ok   selftest: %r is caught (%s)" % (sorted(over), want))
        else:
            print("SELFTEST FAIL: %r gave %s, wanted %r" % (over, got, want))
            fail = 1
    print("lib-anchored.py selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


def main(argv):
    """print the findings on this checkout, or run the selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    resolve = "--resolve" in argv[1:]
    bad = findings(REPO, resolve)
    for b in bad:
        print("FAIL: " + b)
    if bad:
        return 1
    print("check-lib-anchored: every library a test script sources reaches other files from its own folder%s"
          % (", and every such path exists" if resolve else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
