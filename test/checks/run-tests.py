#!/usr/bin/env python3
# run the tests test/checks declares

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(HERE, "lib"))
import check_entries  # noqa: E402

GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
UNSET = ("RHIZO_VM", "RHIZO_VM_HOOK", "RHIZO_GUEST_OS", "RHIZO_DESKTOP_PROFILE", "RHIZO_RELEASE",
         "V", "MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES")
DEPTH = "RUN_TESTS_DEPTH"
FIXTURE = "RUN_TESTS_FIXTURE"
FLOOR = 700
IN_CONTAINER = os.path.join(REPO, "tools", "build", "env", "run.sh")
NOT_RUN_EXIT = 77


def depth():
    """return the runner depth this process inherited"""
    try:
        return int(os.environ.get(DEPTH, "0"))
    except ValueError:
        return 2


def label(e):
    """return the name a test is reported under"""
    return e["label"] + (" (selftest)" if e["kind"] == "selftest" else "")


def git(*args):
    """return git's output in the checkout, or None when git fails"""
    r = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, env=GIT_ENV)
    return r.stdout if r.returncode == 0 else None


def in_fixture():
    """return True when this runner is the selftest's fixture copy"""
    fixture = os.environ.get(FIXTURE)
    return bool(fixture) and HERE.startswith(os.path.join(fixture, ""))


def tree_digest():
    """return a hash of HEAD and every changed path"""
    head = git("rev-parse", "HEAD")
    r = subprocess.run(["git", "-C", REPO, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                       capture_output=True, env=GIT_ENV)
    if head is None or r.returncode != 0:
        return None
    h = hashlib.sha256(head.encode())
    fields = r.stdout.split(b"\0")
    i = 0
    while i < len(fields):
        entry, i = fields[i], i + 1
        if not entry:
            continue
        rel = entry[3:]
        h.update(entry + b"\0")
        path = os.path.join(REPO, rel.decode(errors="replace"))
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as f:
                h.update(hashlib.sha256(f.read()).digest())
        if entry[:1] in (b"R", b"C"):
            i += 1
    return h.hexdigest()


def stamp():
    """return the HEAD and tree digest a record must match"""
    head = git("rev-parse", "HEAD")
    return {"head": head.strip() if head else None, "digest": tree_digest()}


def run_container(args):
    """run the selection in the build container"""
    tests = os.path.join(REPO, "var", "tests")
    os.makedirs(tests, exist_ok=True)
    fd, record = tempfile.mkstemp(prefix="container-", suffix=".json", dir=tests)
    os.close(fd)
    os.remove(record)
    passed = (["-v"] if args.verbose else []) + ["-j", str(args.jobs), "--record", record]
    script = 'python3 test/checks/run-tests.py "$@"; exit $?'
    try:
        rc = subprocess.run([IN_CONTAINER, "bash", "-c", script, "bash", *passed], cwd=REPO).returncode
        if rc > 1:
            print("run-tests.py: the container pass exited %d" % rc)
            return rc
        return main((["-v"] if args.verbose else []) + ["-j", str(args.jobs), "--after", record])
    finally:
        if os.path.exists(record):
            os.remove(record)


def sibling_dir(name):
    """return the path of a sibling checkout"""
    var = "RHIZO_%s_DIR" % name[len("rhizo-"):].upper().replace("-", "_") if name.startswith("rhizo-") else ""
    if var and os.environ.get(var):
        return os.environ[var]
    common = subprocess.run(["git", "-C", REPO, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, env=GIT_ENV).stdout.strip()
    main = os.path.dirname(common) if common else REPO
    return os.path.join(os.path.dirname(main), name)


def missing(needs):
    """return the absent needs"""
    out = []
    for n in needs:
        if n.startswith("../"):
            name, _, rest = n[3:].partition("/")
            if not os.path.exists(os.path.join(sibling_dir(name), rest)):
                out.append(n)
        elif "/" in n:
            if not os.path.exists(os.path.join(REPO, os.path.expanduser(n))):
                out.append(n)
        elif shutil.which(n) is None:
            out.append(n)
    return out


def not_run_reason(out):
    """return a NOT RUN test's reason line"""
    lines = [line for line in out.splitlines() if line.startswith("NOT RUN")]
    return lines[0] if lines else (out.strip().splitlines() or ["it printed no reason"])[-1]


def run_one(e):
    """run a test from test/checks"""
    env = {k: v for k, v in os.environ.items() if k not in UNSET}
    env[DEPTH] = str(depth() + 1)
    r = subprocess.run(e["argv"], cwd=HERE, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, env=env)
    return r.returncode, r.stdout.decode(errors="replace")


def main(argv):
    """run the selected tests in parallel"""
    ap = argparse.ArgumentParser(prog="run-tests.py", description="run the tests test/checks declares")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every test as it is reported (V=1)")
    ap.add_argument("-j", "--jobs", type=int, default=min(8, os.cpu_count() or 1), help="tests run at once")
    ap.add_argument("--list", action="store_true", help="print the tests and run none")
    ap.add_argument("--record", metavar="FILE", help="write the counts and the skipped tests to FILE, print no summary")
    ap.add_argument("--after", metavar="FILE",
                    help="run only the tests FILE's run skipped or could not run, with their needs met here, "
                         "then sum both runs")
    ap.add_argument("--container", action="store_true",
                    help="run in the build container, then here the tests it skipped for a tool this host has")
    args = ap.parse_args(argv)
    nested = depth() >= 2 or (depth() == 1 and not in_fixture())
    if nested and not args.list:
        print("run-tests.py: refuses to start inside a test it is running (%s=%d)" % (DEPTH, depth()))
        return 2
    verbose = args.verbose or os.environ.get("V") == "1"
    try:
        entries = check_entries.entries(HERE)
    except check_entries.EntryError as e:
        print("run-tests.py: %s" % e, file=sys.stderr)
        return 2
    if len(entries) < FLOOR and not in_fixture() and not args.list:
        print("run-tests.py: read %d tests, fewer than the %d test/checks declares" % (len(entries), FLOOR))
        return 2
    if args.container:
        return run_container(args)
    selected = entries
    if args.list:
        for e in selected:
            print(label(e))
        return 0
    before = {"passed": 0, "failed": 0}
    if args.after:
        try:
            with open(args.after) as f:
                before = json.load(f)
        except (OSError, ValueError) as e:
            print("run-tests.py: no record of the first run at %s (%s)" % (args.after, e), file=sys.stderr)
            return 2
        now = stamp()
        for key, what in (("head", "HEAD"), ("digest", "tree")):
            if before.get(key) != now[key]:
                print("run-tests.py: the record at %s is from another %s (%s, here %s)"
                      % (args.after, what, before.get(key), now[key]))
                return 2
        rerun = set(map(tuple, before["skipped"])) | set(map(tuple, before.get("not_run", [])))
        selected = [e for e in selected if (e["kind"], e["label"]) in rerun]
    if args.record:
        if os.path.exists(args.record):
            os.remove(args.record)
        record_stamp = stamp()
    results = [None] * len(selected)
    todo, alone = [], []
    for i, e in enumerate(selected):
        absent = missing(e["needs"])
        if absent:
            results[i] = ("skip", "needs " + " ".join(absent))
        else:
            (alone if "serial" in e["flags"] else todo).append(i)
    done = [0]
    show = sys.stderr.isatty()

    def one(i):
        """run test i and record its result"""
        rc, out = run_one(selected[i])
        results[i] = ("ok", "") if rc == 0 else ("NOT RUN", not_run_reason(out)) if rc == NOT_RUN_EXIT \
            else ("FAIL", out)
        done[0] += 1
        if show:
            print("\r%d/%d" % (done[0], len(todo) + len(alone)), end="", file=sys.stderr, flush=True)

    start = time.monotonic()
    with ThreadPoolExecutor(max(1, args.jobs)) as pool:
        list(pool.map(one, todo))
    for i in alone:
        one(i)
    if show:
        print("\r", end="", file=sys.stderr)
    counts = {"ok": 0, "FAIL": 0, "skip": 0, "NOT RUN": 0}
    for e, (verdict, detail) in zip(selected, results):
        counts[verdict] += 1
        if verdict == "FAIL":
            print("FAIL %s" % label(e))
            print("".join("    " + line + "\n" for line in detail.rstrip("\n").split("\n")), end="")
        elif verdict == "NOT RUN":
            print("NOT RUN %s: %s" % (label(e), detail))
        elif verbose:
            print("%-4s %s%s" % (verdict, label(e), " -- " + detail if detail else ""))
    if verbose:
        print("%.0fs" % (time.monotonic() - start))
    if args.record:
        os.makedirs(os.path.dirname(os.path.abspath(args.record)), exist_ok=True)
        with open(args.record, "w") as f:
            json.dump(dict(record_stamp, passed=counts["ok"], failed=counts["FAIL"],
                           skipped=[[e["kind"], e["label"]] for e, r in zip(selected, results) if r[0] == "skip"],
                           not_run=[[e["kind"], e["label"]] for e, r in zip(selected, results)
                                    if r[0] == "NOT RUN"]), f)
        return 1 if counts["FAIL"] else 0
    passed, failed = counts["ok"] + before["passed"], counts["FAIL"] + before["failed"]
    print("%d passed, %d failed, %d skipped, %d not run" % (passed, failed, counts["skip"], counts["NOT RUN"]))
    return 1 if failed or counts["NOT RUN"] else 0


def selftest():
    """run the runner on a fixture checkout"""
    if depth() >= 2:
        print("run-tests.py: --selftest refuses to start inside a test of its own fixture (%s=%d)" % (DEPTH, depth()))
        return 2
    fail = 0
    work = tempfile.mkdtemp(prefix="run-tests-")
    os.makedirs(os.path.join(work, "tmp"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k != "V"}
    env.update({DEPTH: "1", FIXTURE: work, "TMPDIR": os.path.join(work, "tmp")})

    def git(*a):
        """run git in the fixture checkout"""
        subprocess.run(["git", "-C", work, *a], check=True, capture_output=True, env=env)

    def put(rel, body, mode=0o755):
        """write a fixture file"""
        path = os.path.join(work, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, mode)

    rows = {}

    def put_table():
        """write the fixture checks.tsv from the rows so far"""
        put("test/checks/checks.tsv", "# path, kind, flags, label, args, needs\n" + "".join(rows.values()), 0o644)

    def put_check(rel, body, kind, label, flags="-", args="-", needs="-"):
        """write a fixture check file and its checks.tsv row"""
        put("test/checks/" + rel, body)
        rows[rel] = "\t".join((rel, kind, flags, label, args, needs)) + "\n"
        put_table()

    def drop_check(rel):
        """remove a fixture check file and its checks.tsv row"""
        os.remove(os.path.join(work, "test/checks", rel))
        del rows[rel]
        put_table()

    def run(*args, extra=None, drop=()):
        """run the fixture's runner"""
        r = subprocess.run([sys.executable, os.path.join(work, "test/checks/run-tests.py"), *args],
                           capture_output=True, text=True, timeout=120,
                           env={k: v for k, v in dict(env, **(extra or {})).items() if k not in drop})
        return r.returncode, r.stdout + r.stderr

    def check(what, ok, detail=""):
        """print a finding and remember a failure"""
        nonlocal fail
        print("%s selftest: %s%s" % ("ok  " if ok else "FAIL", what, "" if ok else " -- %s" % detail))
        fail |= not ok

    try:
        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
        for rel, src in (("run-tests.py", os.path.abspath(__file__)),
                         ("lib/check_entries.py", os.path.join(HERE, "lib", "check_entries.py"))):
            put("test/checks/" + rel, open(src).read())
        put_check("a/pass.sh", "#!/bin/bash\necho quiet-pass-output\n", "run", "passes")
        put_check("a/fail.sh", "#!/bin/bash\necho boom-output\nexit 1\n", "run", "fails")
        put_check("a/needs.sh", "#!/bin/bash\nexit 1\n", "run", "needs a tool", needs="no-such-tool-xyz")
        put_check("a/needs-path.sh", "#!/bin/bash\nexit 1\n", "run", "needs a path", needs="var/absent/")
        put_check("a/met.sh", "#!/bin/bash\n", "run", "needs what is here", needs="sh src/")
        put_check("a/self.py", "#!/usr/bin/env python3\n"
                               "import sys\nsys.exit(0 if sys.argv[1:] == ['--selftest'] else 1)\n",
                  "selftest", "self", args="--selftest")
        put_check("a/serial.sh", "#!/bin/bash\n", "run", "runs alone", flags="serial")
        put_check("a/notrun.sh", "#!/bin/bash\n"
                                 "[ -e \"$RUN_TESTS_FIXTURE/var/host-can-run\" ] && [ -z \"$FIXTURE_CONTAINER\" ] "
                                 "&& exit 0\necho 'NOT RUN: the probe -- refused here'\nexit 77\n",
                  "run", "cannot run a section")
        put("src/a", "a\n", 0o644)
        put("src/b", "b\n", 0o644)
        put(".gitignore", "/var/\n/tools-here/\n", 0o644)
        git("add", "-A")
        git("commit", "-q", "-m", "fixture")

        rc, out = run()
        lines = out.strip().split("\n")
        check("a failing test fails the run", rc == 1, "rc %d" % rc)
        check("the last line counts passes, failures, skips and not-runs",
              lines[-1] == "4 passed, 1 failed, 2 skipped, 1 not run", repr(lines[-1]))
        check("an exit-77 test is named NOT RUN with its reason, never a pass",
              "NOT RUN cannot run a section: NOT RUN: the probe -- refused here" in out, out)
        check("a failure is named and its output shown", "FAIL fails" in out and "boom-output" in out, out)
        check("a passing test prints nothing in the quiet run",
              "quiet-pass-output" not in out and "passes" not in out, out)
        check("a skip is not listed in the quiet run", "needs a tool" not in out, out)

        saved = os.environ.pop("RHIZO_FIXTURE_SIBLING_DIR", None)
        check("a ../NAME/ need beside the main checkout that is not there is missing",
              missing(["../rhizo-fixture-sibling/"]) == ["../rhizo-fixture-sibling/"], missing(["../rhizo-fixture-sibling/"]))
        os.environ["RHIZO_FIXTURE_SIBLING_DIR"] = work
        check("a ../NAME/ need is met by the checkout its RHIZO_<NAME>_DIR names",
              missing(["../rhizo-fixture-sibling/src/a"]) == [], missing(["../rhizo-fixture-sibling/src/a"]))
        os.environ.pop("RHIZO_FIXTURE_SIBLING_DIR")
        if saved is not None:
            os.environ["RHIZO_FIXTURE_SIBLING_DIR"] = saved

        rc, out = run("-v")
        check("-v lists each passing test", "ok   passes" in out and "ok   self (selftest)" in out, out)
        check("-v names what a skipped test needs", "skip needs a tool -- needs no-such-tool-xyz" in out
              and "skip needs a path -- needs var/absent/" in out, out)
        check("-v keeps a passing test's output to itself", "quiet-pass-output" not in out, out)
        rc2, out2 = run(extra={"V": "1"})
        check("V=1 is -v", "ok   passes" in out2, out2)
        put_check("a/env.sh", "#!/bin/bash\n[ -z \"${V+x}${MAKEFLAGS+x}${MAKELEVEL+x}\" ]\n",
                  "run", "sees no make variable")
        rc2, out2 = run(extra={"V": "1", "MAKEFLAGS": " -- V=1", "MAKELEVEL": "1"})
        check("a test never sees V or make's own variables", "FAIL sees no make variable" not in out2, out2)
        drop_check("a/env.sh")

        drop_check("a/fail.sh")
        git("add", "-A")
        git("commit", "-q", "-m", "drop the failing test")
        rc, out = run()
        check("a run with a NOT RUN and no failure is not a pass", rc == 1 and out.strip().split("\n")[-1]
              == "4 passed, 0 failed, 2 skipped, 1 not run", "rc %d %r" % (rc, out))
        put("var/host-can-run", "", 0o644)
        rc, out = run()
        check("a run with no failure and nothing not run exits 0 and says so", rc == 0
              and out.strip().split("\n")[-1] == "5 passed, 0 failed, 2 skipped, 0 not run", "rc %d %r" % (rc, out))

        record = os.path.join(work, "var", "tests", "container.json")
        rc, out = run("--record", record, extra={"FIXTURE_CONTAINER": "1"})
        check("--record prints the failures but no summary line", rc == 0 and "passed" not in out
              and os.path.exists(record), "rc %d %r" % (rc, out))
        check("--record keeps a NOT RUN apart from the passes", os.path.exists(record)
              and json.load(open(record)).get("not_run") == [["run", "cannot run a section"]]
              and json.load(open(record)).get("passed") == 4, open(record).read() if os.path.exists(record) else "")
        tools = os.path.join(work, "tools-here")
        put("tools-here/no-such-tool-xyz", "#!/bin/bash\n")
        rc, out = run("--after", record, "-v", extra={"PATH": tools + os.pathsep + env["PATH"]})
        check("--after runs here a test the recorded run skipped for a tool this place has",
              "FAIL needs a tool" in out and "ok   needs a tool" not in out, out)
        check("--after runs here a test the recorded run could not run", "ok   cannot run a section" in out, out)
        check("--after counts both runs in one summary line", rc == 1 and out.strip().split("\n")[-1]
              == "5 passed, 1 failed, 1 skipped, 0 not run", "rc %d %r" % (rc, out))
        check("--after leaves out a test the recorded run already ran", out.count("passes") == 0, out)
        rc, out = run("--after", record + ".absent")
        check("--after with no record fails, never reports a pass", rc == 2, "rc %d %r" % (rc, out))
        good = json.load(open(record))
        for what, change in (("HEAD", {"head": "0" * 40}), ("tree", {"digest": "0" * 64})):
            with open(record, "w") as f:
                json.dump(dict(good, **change), f)
            rc, out = run("--after", record, extra={"PATH": tools + os.pathsep + env["PATH"]})
            check("--after refuses a record of another %s" % what, rc == 2 and "another" in out
                  and "passed," not in out, "rc %d %r" % (rc, out))
        with open(record, "w") as f:
            json.dump(good, f)
        put("src/b", "b-edited\n", 0o644)
        rc, out = run("--after", record, extra={"PATH": tools + os.pathsep + env["PATH"]})
        check("--after refuses a record when a file changed since it was written", rc == 2
              and "another tree" in out, "rc %d %r" % (rc, out))
        git("checkout", "-q", "--", "src/b")

        put("tools/build/env/run.sh", "#!/bin/bash\nexport PATH=/usr/bin:/bin FIXTURE_CONTAINER=1\nexec \"$@\"\n")
        rc, out = run("--container", extra={"PATH": tools + os.pathsep + env["PATH"]})
        lines = out.strip().split("\n")
        check("--container runs the container pass, then here the tests it skipped for a tool this host has or could "
              "not run, in one summary", rc == 1 and "FAIL needs a tool" in out
              and lines[-1] == "5 passed, 1 failed, 1 skipped, 0 not run" and out.count("passed,") == 1,
              "rc %d %r" % (rc, out))
        os.remove(os.path.join(work, "var", "host-can-run"))
        rc, out = run("--container", extra={"PATH": tools + os.pathsep + env["PATH"]})
        lines = out.strip().split("\n")
        check("--container keeps a test the host cannot run either NOT RUN, never a pass", rc == 1
              and lines[-1] == "4 passed, 1 failed, 1 skipped, 1 not run", "rc %d %r" % (rc, out))
        put("var/host-can-run", "", 0o644)
        left = os.listdir(os.path.join(work, "var", "tests")) if os.path.isdir(os.path.join(work, "var", "tests")) else []
        check("--container leaves no record behind", left == ["container.json"] or left == [], left)
        put("tools/build/env/run.sh", "#!/bin/bash\nexit 3\n")
        rc, out = run("--container")
        check("--container fails with the container's own exit status when that pass errs",
              rc == 3 and "container pass exited 3" in out and "passed," not in out, "rc %d %r" % (rc, out))
        put("tools/build/env/run.sh", "#!/bin/bash\nexit 0\n")
        rc, out = run("--container")
        check("--container fails when the container pass wrote no record", rc == 2 and "passed," not in out,
              "rc %d %r" % (rc, out))
        os.remove(os.path.join(work, "tools/build/env/run.sh"))
        rc, out = run(drop=(FIXTURE, DEPTH))
        check("a checkout declaring fewer tests than the floor is refused before any test runs",
              rc == 2 and "fewer than" in out and "passed," not in out, "rc %d %r" % (rc, out))

        rc, out = run("--list")
        listed = out.strip().split("\n")
        check("--list prints every test, the selftest marked", rc == 0 and "self (selftest)" in listed
              and "runs alone" in listed and len(listed) == 7, out)

        put("test/checks/a/unlisted.sh", "#!/bin/bash\n")
        rc, out = run()
        check("a check file with no checks.tsv row stops the run before any test",
              rc == 2 and "unlisted.sh: has no row in checks.tsv" in out and "passed," not in out,
              "rc %d %r" % (rc, out))
        os.remove(os.path.join(work, "test/checks/a/unlisted.sh"))
        put_check("a/gone.sh", "#!/bin/bash\n", "run", "gone")
        os.remove(os.path.join(work, "test/checks/a/gone.sh"))
        rc, out = run()
        check("a checks.tsv row naming a missing file stops the run before any test",
              rc == 2 and "a/gone.sh is not a file under test/checks" in out and "passed," not in out,
              "rc %d %r" % (rc, out))
        del rows["a/gone.sh"]
        put_table()

        rc, out = run(extra={DEPTH: "1"}, drop=(FIXTURE,))
        check("the runner refuses to start inside a test it runs", rc == 2 and "refuses to start" in out,
              "rc %d %r" % (rc, out))
        rc, out = run("--list", extra={DEPTH: "1"}, drop=(FIXTURE,))
        check("--list, which runs nothing, works inside a test", rc == 0 and "passes" in out, "rc %d %r" % (rc, out))
        put_check("a/selfcall.sh", "#!/bin/bash\nexec python3 ./run-tests.py --selftest\n",
                  "run", "calls the runner's selftest")
        put_check("a/suitecall.sh", "#!/bin/bash\nexec python3 ./run-tests.py\n", "run", "calls the runner")
        rc, out = run("-j", "1")
        nested = [d for d in os.listdir(os.path.join(work, "tmp")) if d.startswith("run-tests-")]
        check("a test that calls the runner's selftest is refused, not forked",
              rc == 1 and "FAIL calls the runner's selftest" in out and "--selftest refuses to start" in out
              and not nested, "rc %d nested %s %r" % (rc, nested, out[-600:]))
        check("a test that calls the runner is refused, not forked",
              "FAIL calls the runner" in out and "run-tests.py: refuses to start inside a test" in out, out[-600:])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("run-tests.py selftest: %s" % ("FAILED" if fail else "ok"))
    return 1 if fail else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    sys.exit(main(sys.argv[1:]))
