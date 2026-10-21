#!/usr/bin/env python3
# find the system tests and resolve a name to its file
import os

HEADER = "# test-boot-mode:"
SCAN_LINES = 400
SUPPORT = {"run", "lib", "guest", "host", "inject", "cts", "fixtures", "gnome-harness-ext", "manual", "cycle", "tools",
           "__pycache__"}
DEFAULT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))), "test", "system")


class DuplicateTest(Exception):
    """two system tests share a name"""


def is_system_test(path):
    """return whether a file is a system test"""
    if not path.endswith(".sh") or not os.path.isfile(path):
        return False
    try:
        with open(path, errors="replace") as f:
            for n, line in enumerate(f):
                if line.startswith(HEADER):
                    return True
                if n >= SCAN_LINES:
                    break
    except OSError:
        pass
    return False


def tests(directory):
    """return {name: path} for every system test under a directory"""
    found = {}
    for d, subdirs, files in os.walk(directory):
        subdirs[:] = sorted(x for x in subdirs if x not in SUPPORT)
        for n in sorted(files):
            p = os.path.join(d, n)
            if is_system_test(p):
                if n in found:
                    raise DuplicateTest("two system tests are named %s: %s and %s" % (n, found[n], p))
                found[n] = p
    return found


def system_tests(directory):
    """return the system test names under a directory, sorted"""
    return sorted(tests(directory))


def system_test_paths(directory):
    """return each system test's path, in name order"""
    found = tests(directory)
    return [found[n] for n in sorted(found)]


def test_path(name, directory=DEFAULT_DIR):
    """return the file of the named system test, or None"""
    return tests(directory).get(os.path.basename(name))


def selftest():
    """check discovery on fixture trees"""
    import tempfile
    fail = 0

    def write(root, rel, body):
        """write a fixture file, making its folders"""
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(body)

    test_body = "#!/bin/bash\n# test-boot-mode: cold-required\n"
    with tempfile.TemporaryDirectory() as tmp:
        write(tmp, "top.sh", test_body)
        write(tmp, "boot/nested.sh", test_body)
        write(tmp, "lifecycle/deep/deeper.sh", test_body)
        write(tmp, "fixtures/fake.sh", test_body)
        write(tmp, "run/heredoc.sh", "cat <<'X'\n" + test_body + "X\n")
        write(tmp, "lib/helper.sh", "#!/bin/bash\n")
        write(tmp, "boot/notes.txt", test_body)
        want = ["deeper.sh", "nested.sh", "top.sh"]
        try:
            got = system_tests(tmp)
        except Exception as e:  # noqa: BLE001
            got = "raised %r" % e
        if got == want:
            print("ok   selftest: tests at any depth are found, support folders and non-.sh files are not")
        else:
            print("SELFTEST FAIL: the fixture tree gave %s, wanted %s" % (got, want))
            fail = 1
        try:
            got = test_path("nested.sh", tmp)
        except Exception as e:  # noqa: BLE001
            got = "raised %r" % e
        if got == os.path.join(tmp, "boot", "nested.sh"):
            print("ok   selftest: a name resolves to its file in a subfolder")
        else:
            print("SELFTEST FAIL: test_path('nested.sh') gave %s" % got)
            fail = 1
        write(tmp, "desktop/top.sh", test_body)
        try:
            got = system_tests(tmp)
            print("SELFTEST FAIL: two tests named top.sh were accepted: %s" % got)
            fail = 1
        except Exception as e:  # noqa: BLE001
            if "top.sh" in str(e) and "desktop" in str(e):
                print("ok   selftest: two tests with one name are refused, naming both paths")
            else:
                print("SELFTEST FAIL: a duplicate name raised %r" % e)
                fail = 1
    print("system_tests.py selftest: %s" % ("FAILED" if fail else "ok"))
    return fail


def main(argv):
    """list or resolve the system tests or run the selftest"""
    import sys
    args = argv[1:]
    if args == ["--selftest"]:
        return selftest()
    try:
        if args[:1] == ["--path"] and len(args) in (2, 3):
            p = test_path(args[1], args[2] if len(args) == 3 else DEFAULT_DIR)
            if p is None:
                print("system_tests: no system test is named %s" % os.path.basename(args[1]), file=sys.stderr)
                return 1
            print(p)
            return 0
        if args[:1] == ["--map"] and len(args) in (1, 2):
            found = tests(args[1] if len(args) == 2 else DEFAULT_DIR)
            for n in sorted(found):
                print("%s\t%s" % (n, found[n]))
            return 0
        if len(args) <= 1 and not (args and args[0].startswith("--")):
            for n in system_tests(args[0] if args else DEFAULT_DIR):
                print(n)
            return 0
    except DuplicateTest as e:
        print("system_tests: %s" % e, file=sys.stderr)
        return 2
    print("usage: system_tests.py [DIR] | --path NAME [DIR] | --map [DIR] | --selftest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
