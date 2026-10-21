#!/usr/bin/env python3
import ast
import os
import sys

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd", "boot.py")
VERB = "prepare_tree_verb"


def calls(node, name):
    """return the calls of name below node"""
    return [c for c in ast.walk(node) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name]


def check(source):
    """return the findings for prepare_tree_verb's namespace use"""
    tree = ast.parse(source)
    verb = next((n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == VERB), None)
    if verb is None:
        return [f"no {VERB}() to test"]
    bad = []
    if calls(verb, "_enter_compiled_policy_namespace"):
        bad.append(f"{VERB}() enters the policy namespace in its own process")
    forks = calls(verb, "_in_policy_namespace")
    if not forks:
        bad.append(f"{VERB}() never stages through _in_policy_namespace")
    work = [n for f in forks for n in ast.walk(f)]
    if any(c in work for c in calls(verb, "_build_prepared_manifest")):
        bad.append(f"{VERB}() builds its manifest inside the namespace child's work")
    if not calls(verb, "_build_prepared_manifest"):
        bad.append(f"{VERB}() builds no manifest")
    return bad


FIXTURE = '''
def prepare_tree_verb(dest):
    if host:
        recorded, why = _in_policy_namespace(policy, lambda: _stage_prepared_tree(part))
    else:
        recorded, why = _stage_prepared_tree(part)
    manifest = _build_prepared_manifest(part, recorded)
'''


def selftest():
    """assert each finding both ways"""
    bad = []
    if check(FIXTURE):
        bad.append(f"the fork-then-record form is flagged: {check(FIXTURE)}")
    cases = (
        ("in-process entry", FIXTURE.replace("    if host:", "    _enter_compiled_policy_namespace(policy)\n    if host:"),
         "enters the policy namespace in its own process"),
        ("manifest in the child", FIXTURE.replace("lambda: _stage_prepared_tree(part)",
                                                   "lambda: _build_prepared_manifest(part, [])"),
         "builds its manifest inside the namespace child's work"),
        ("no fork", FIXTURE.replace("_in_policy_namespace(policy, ", "_stage_with(policy, "), "never stages through"),
    )
    for label, src, needle in cases:
        if not any(needle in f for f in check(src)):
            bad.append(f"{label} was not flagged: {check(src)}")
    return bad


def main():
    """run the real check, or the selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check(open(LAUNCHER).read())
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
