#!/usr/bin/env python3
# list all of the tests the runner knows

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

KINDS = ("run", "selftest", "helper")
FLAGS = ("serial", "volatile")
RUNNER = "run-tests.py"
TABLE = "checks.tsv"
RUNNER_FILES = (RUNNER, "check_entries.py")
EXEMPT_DIRS = ("lib", "data", "manual")
HEADER_LINE = re.compile(r"(?i)^#\s*checks?[-_ ]?(?:run|selftest|args|flags|needs|helper)\b")
GIT_CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


class EntryError(Exception):
    """a declaration the runner cannot trust, named by file and line"""


def find_checks_dir(start):
    """find the folder holding the runner"""
    d = os.path.abspath(start)
    for _ in range(3):
        if os.path.isfile(os.path.join(d, RUNNER)):
            return d
        d = os.path.dirname(d)
    raise EntryError("no %s in %s or the two folders above it" % (RUNNER, start))


def tracked(checks):
    """list the files git tracks under the checks folder, relative to it"""
    out = subprocess.run(["git", "-C", checks, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."],
                         check=True, capture_output=True, env=GIT_CLEAN_ENV).stdout
    return sorted(set(p for p in out.decode().split("\0") if p and os.path.isfile(os.path.join(checks, p))))


def read(path):
    """return a file's text, or an empty string when it is not text"""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def table_rows(path):
    """yield (line number, fields) of each tsv row"""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if line.strip() and not line.startswith("#"):
                yield n, line.split("\t")


def leading_block(text):
    """yield (number, line) of a file's leading comment lines"""
    lines = text.split("\n")
    start = 1 if lines and lines[0].startswith("#!") else 0
    for n in range(start, len(lines)):
        if not lines[n].strip():
            continue
        if not lines[n].startswith("#"):
            return
        yield n + 1, lines[n]


def words_of(cell):
    """return a space-separated cell's words, none for -"""
    return [] if cell == "-" else cell.split()


def make_entry(kind, flags, label, argv, where, needs=()):
    """build an entry, refusing bad input"""
    if kind not in ("run", "selftest"):
        raise EntryError("%s: unknown kind %s" % (where, kind))
    if not label:
        raise EntryError("%s: a check with no label" % where)
    bad = [f for f in flags if f not in FLAGS]
    if bad:
        raise EntryError("%s: unknown flag %s" % (where, " ".join(bad)))
    if not argv:
        raise EntryError("%s: a check with no command" % where)
    return {"kind": kind, "flags": flags, "label": label, "argv": argv, "needs": list(needs)}


def table_entries(checks, files):
    """return the entries checks.tsv declares and the set of paths it names"""
    out, named = [], set()
    for n, row in table_rows(os.path.join(checks, TABLE)):
        where = "%s:%d" % (TABLE, n)
        if len(row) != 6:
            raise EntryError("%s: want path, kind, flags, label, args and needs, tab-separated" % where)
        rel, kind, flags, label, args, needs = row
        if kind not in KINDS:
            raise EntryError("%s: unknown kind %s" % (where, kind))
        if rel not in files:
            raise EntryError("%s: %s is not a file under test/checks" % (where, rel))
        if not rel.endswith((".py", ".sh")):
            raise EntryError("%s: %s is not a .py or .sh file" % (where, rel))
        named.add(rel)
        if kind == "helper":
            if label == "-":
                raise EntryError("%s: a helper row that does not say what runs it" % where)
            continue
        own = "./" + rel
        argv = (["python3", own] if rel.endswith(".py") else [own]) + ([] if args == "-" else shlex.split(args))
        e = make_entry(kind, words_of(flags), "" if label == "-" else label, argv, where, words_of(needs))
        e["file"], e["line"] = rel, n
        out.append(e)
    return out, named


def outside_entries(checks):
    """return the entries outside.tsv declares"""
    out = []
    for n, row in table_rows(os.path.join(checks, "outside.tsv")):
        where = "outside.tsv:%d" % n
        if len(row) not in (4, 5):
            raise EntryError("%s: want kind, flags, label, argv and optional needs, tab-separated" % where)
        kind, flags, label, argv = row[:4]
        needs = row[4].split() if len(row) == 5 and row[4] != "-" else []
        e = make_entry(kind, [] if flags == "-" else flags.split(), label, shlex.split(argv), where, needs)
        e["file"], e["line"] = "outside.tsv", n
        out.append(e)
    return out


def entries(checks):
    """return every entry in run order"""
    files = tracked(checks)
    scripts = [rel for rel in files if rel.endswith((".py", ".sh"))]
    for rel in scripts:
        for n, line in leading_block(read(os.path.join(checks, rel))):
            if line.startswith("# check-") or HEADER_LINE.match(line):
                raise EntryError("%s:%d: %r -- a check is registered in %s, not in its own header"
                                 % (rel, n, line, TABLE))
    out, named = table_entries(checks, set(files))
    for rel in scripts:
        if rel not in named and rel not in RUNNER_FILES and rel.split("/")[0] not in EXEMPT_DIRS:
            raise EntryError("%s: has no row in %s; add it as a check, or as a helper naming what runs it"
                             % (rel, TABLE))
    out += outside_entries(checks)
    seen = {}
    for e in out:
        key = (e["kind"], e["label"])
        if key in seen:
            raise EntryError("%s and %s both declare the %s %r" % (seen[key], e["file"], e["kind"], e["label"]))
        seen[key] = e["file"]
    return out


def words(e):
    """return the runner words for an entry"""
    return e["flags"] + [e["label"]] + e["argv"]


def selftest():
    """check reading, ordering and every refusal on fixture folders"""
    import shutil
    fail = 0
    made = []

    def build(files, untracked=None):
        """write the files into a new git repo and return its root"""
        root = tempfile.mkdtemp(prefix="check-entries-")
        made.append(root)
        subprocess.run(["git", "init", "-q", root], check=True, env=GIT_CLEAN_ENV)
        files = dict({"run-tests.py": "#!/usr/bin/env python3\n"}, **files)
        for batch in (files, untracked or {}):
            for rel, body in batch.items():
                os.makedirs(os.path.dirname(os.path.join(root, rel)) or root, exist_ok=True)
                with open(os.path.join(root, rel), "w") as f:
                    f.write(body)
            if batch is files:
                subprocess.run(["git", "-C", root, "add", "-A"], check=True, env=GIT_CLEAN_ENV)
        return root

    def got(files, untracked=None):
        """return the entries of a built repo, or None and the refusal text"""
        try:
            return entries(build(files, untracked)), None
        except EntryError as e:
            return None, str(e)

    def expect(what, files, want=None, refuse=None, untracked=None):
        """record a failure unless a built repo gives the wanted result"""
        nonlocal fail
        es, err = got(files, untracked)
        if refuse is not None:
            ok = err is not None and refuse in err
            detail = err if es is None else "accepted: %s" % [words(e) for e in es]
        else:
            ok = es is not None and [[e["kind"]] + words(e) for e in es] == want
            detail = err if es is None else [[e["kind"]] + words(e) for e in es]
        print("%s selftest: %s%s" % ("ok  " if ok else "FAIL", what, "" if ok else " -- got %s" % detail))
        fail |= not ok

    def table(*rows):
        """return a checks.tsv body of the given rows, its column comment first"""
        return "# path, kind, flags, label, args, needs\n" + "".join("\t".join(r) + "\n" for r in rows)

    sh = "#!/bin/bash\n# check the thing\nset -u\n"
    expect("two rows for one file run in table order, with args, flags and needs",
           {"two.sh": sh, TABLE: table(("two.sh", "run", "-", "the thing holds", "-", "sh"),
                                       ("two.sh", "selftest", "serial", "thing check", "--selftest", "-"))},
           want=[["run", "the thing holds", "./two.sh"],
                 ["selftest", "serial", "thing check", "./two.sh", "--selftest"]])
    expect("a python selftest with no args runs with no argument",
           {"sub/p.py": "import os\n", TABLE: table(("sub/p.py", "selftest", "-", "p check", "-", "-"))},
           want=[["selftest", "p check", "python3", "./sub/p.py"]])
    expect("args are split the way a shell splits them",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "--name 'two words'", "-"))},
           want=[["run", "a holds", "./a.sh", "--name", "two words"]])
    expect("an outside.tsv row runs its argv from test/checks, after the table's checks",
           {"outside.tsv": "selftest\t-\tvm tool check\t../vm/x.sh --selftest\n",
            "a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"))},
           want=[["run", "a holds", "./a.sh"], ["selftest", "vm tool check", "../vm/x.sh", "--selftest"]])
    expect("a helper row, a lib/ file and a manual/ file need no check row",
           {"a.sh": sh, "helper.py": "X = 1\n", "lib/tool.sh": "#!/bin/bash\n", "manual/hand.sh": "#!/bin/bash\n",
            TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"), ("helper.py", "helper", "-", "a.sh runs it", "-", "-"))},
           want=[["run", "a holds", "./a.sh"]])
    expect("a script with no row is refused",
           {"a.sh": sh, "lost.py": "#!/usr/bin/env python3\n", TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"))},
           refuse="lost.py: has no row in checks.tsv")
    expect("a script not yet added to git with no row is refused too",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"))},
           untracked={"b.sh": "#!/bin/bash\n"}, refuse="b.sh: has no row")
    expect("a check not yet added to git is still run",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"), ("b.sh", "run", "-", "b holds", "-", "-"))},
           untracked={"b.sh": sh}, want=[["run", "a holds", "./a.sh"], ["run", "b holds", "./b.sh"]])
    expect("a row naming a missing file is refused",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"), ("gone.sh", "run", "-", "gone", "-", "-"))},
           refuse="gone.sh is not a file under test/checks")
    expect("a row naming a file that is not a script is refused",
           {"a.txt": "x\n", TABLE: table(("a.txt", "run", "-", "a holds", "-", "-"))}, refuse="not a .py or .sh file")
    expect("a row of five columns is refused",
           {"a.sh": sh, TABLE: "a.sh\trun\t-\ta holds\t-\n"}, refuse="want path, kind, flags")
    expect("an unknown kind is refused",
           {"a.sh": sh, TABLE: table(("a.sh", "check", "-", "a holds", "-", "-"))}, refuse="unknown kind check")
    expect("an unknown flag is refused",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "fast", "a holds", "-", "-"))}, refuse="unknown flag fast")
    expect("a check with no label is refused",
           {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "-", "-", "-"))}, refuse="a check with no label")
    expect("a helper row that names no runner is refused",
           {"a.sh": sh, TABLE: table(("a.sh", "helper", "-", "-", "-", "-"))}, refuse="does not say what runs it")
    expect("a duplicate label for the same kind is refused",
           {"a.sh": sh, "b.sh": sh, TABLE: table(("a.sh", "run", "-", "same", "-", "-"), ("b.sh", "run", "-", "same", "-", "-"))},
           refuse="both declare the run 'same'")
    for line in ("# check-run: x", "#check-run: x", "# Check-run: x", "# check_run: x", "# checks-run: x"):
        expect("a header line (%s) left in a check file is refused, not ignored" % line,
               {"a.sh": "#!/bin/bash\n%s\n" % line, TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"))},
               refuse="not in its own header")
    expect("the runner's own files need no row",
           {"a.sh": sh, "run-tests.py": "#!/usr/bin/env python3\nX = 1\n", TABLE: table(("a.sh", "run", "-", "a holds", "-", "-"))},
           want=[["run", "a holds", "./a.sh"]])

    def needs_of(what, files, want):
        """check the needs each fixture entry reads are exactly want"""
        nonlocal fail
        es, err = got(files)
        have = err if es is None else [e["needs"] for e in es]
        ok = have == want
        print("%s selftest: %s%s" % ("ok  " if ok else "FAIL", what, "" if ok else " -- got %s" % have))
        fail |= not ok

    needs_of("a row's needs column gives its needs, - needs nothing",
             {"a.sh": sh, TABLE: table(("a.sh", "run", "-", "a holds", "-", "qemu-img var/share/"),
                                       ("a.sh", "selftest", "-", "a check", "--selftest", "-"))},
             [["qemu-img", "var/share/"], []])
    needs_of("an outside.tsv row's fifth column is its needs, a four-column row needs nothing",
             {"outside.tsv": "selftest\t-\tx check\t../x.sh --selftest\tmesa-src/ gcc\n"
                             "selftest\t-\ty check\t../y.sh --selftest\n"
                             "selftest\t-\tz check\t../z.sh --selftest\t-\n"},
             [["mesa-src/", "gcc"], [], []])
    expect("an outside.tsv row of six columns is refused",
           {"outside.tsv": "selftest\t-\tx check\t../x.sh\t-\textra\n"}, refuse="want kind, flags, label")
    for root in made:
        shutil.rmtree(root, ignore_errors=True)
    print("check_entries.py selftest: %s" % ("FAILED" if fail else "ok"))
    return 1 if fail else 0


def main(argv):
    """print every entry, or run the selftest"""
    args = argv[1:]
    if args == ["--selftest"]:
        return selftest()
    checks = None
    if "--checks" in args:
        i = args.index("--checks")
        checks = args[i + 1]
        del args[i:i + 2]
    mode = args[0] if args else "--list"
    try:
        es = entries(find_checks_dir(checks or os.path.dirname(os.path.abspath(__file__))))
    except EntryError as e:
        print("check_entries: %s" % e, file=sys.stderr)
        return 1
    if mode == "--nul":
        out = sys.stdout.buffer
        for e in es:
            w = words(e)
            out.write(b"".join(x.encode() + b"\0" for x in [e["kind"], str(len(w))] + w))
    elif mode == "--json":
        print(json.dumps([{"kind": e["kind"], "flags": sorted(e["flags"]), "label": e["label"],
                           "argv": e["argv"], "needs": e["needs"], "file": e["file"]} for e in es], indent=1))
    elif mode == "--list":
        for e in es:
            print("%s\t%s\t%s" % (e["kind"], e["file"], e["label"]))
    else:
        print("usage: check_entries.py [--nul | --json | --list] [--checks DIR] | --selftest", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
