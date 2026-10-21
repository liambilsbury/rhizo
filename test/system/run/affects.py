#!/usr/bin/env python3
# route a changed path to the system tests it affects


def load_affects(tsv_path):
    """read the rows of affects.tsv"""
    with open(tsv_path) as f:
        return parse_affects(f.read())


def parse_affects(text):
    """parse affects.tsv text into prefix and test rows"""
    rows = []
    for line in text.splitlines():
        if not line or line.startswith("#") or "\t" not in line:
            continue
        prefix, tests = line.split("\t", 1)
        rows.append((prefix, tests))
    return rows


def outside_layout(path):
    """check for a root file or root dot-dir"""
    return "/" not in path or path.startswith(".")


def tests_for_path(path, rows):
    """return the test list for a path"""
    best, best_len = "", 0
    for prefix, tests in rows:
        if path.startswith(prefix) and len(prefix) > best_len:
            best, best_len = tests, len(prefix)
    return best or ("NONE" if outside_layout(path) else "ALL")


def path_is_input(path, test, rows):
    """return whether a path is an input of the test"""
    g = tests_for_path(path, rows)
    if g == "ALL":
        return True
    if g == "NONE":
        return False
    return test in g.split(",")


def test_is_mapped(test, rows):
    """check affects.tsv rows for a test"""
    for _, tests in rows:
        if tests == "ALL":
            return True
        if tests != "NONE" and test in tests.split(","):
            return True
    return False
