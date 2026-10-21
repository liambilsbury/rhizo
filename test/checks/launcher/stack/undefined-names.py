#!/usr/bin/env python3
"""fail when a launcher module reads an undefined name"""
import ast
import builtins
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE)))), "src", "androidd")
sys.path.insert(0, REPO)

def modules():
    """return the launcher module file names"""
    import glob
    found = sorted("sandbox/" + os.path.basename(f) for f in glob.glob(os.path.join(REPO, "sandbox", "*.py")))
    return ["boot.py"] + found

BUILTIN = set(dir(builtins)) | {"__file__", "__name__", "__doc__", "__spec__"}


def star_import_names(tree, vm):
    """return the names a star import adds"""
    out = set()
    for s in ast.walk(tree):
        if isinstance(s, ast.ImportFrom) and any(a.name == "*" for a in s.names):
            path = os.path.join(vm, (s.module or "").replace(".", "/") + ".py")
            if not os.path.exists(path):
                continue
            sub = ast.parse(open(path).read())
            for t in sub.body:
                if isinstance(t, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
                    out |= {x.id for x in ast.walk(t)
                            if isinstance(x, ast.Name) and isinstance(x.ctx, ast.Store)}
                elif isinstance(t, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    out.add(t.name)
                elif isinstance(t, (ast.Import, ast.ImportFrom)):
                    out |= {a.asname or a.name.split(".")[0] for a in t.names}
            out = {n for n in out if not n.startswith("_")}
    return out


def bound_in(node, include_nested_defs=True):
    """return the names bound in the subtree"""
    out = set()
    for n in ast.walk(node):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
            out.add(n.id)
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if n is not node or include_nested_defs:
                out.add(n.name)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            out.add(n.name)
        elif isinstance(n, ast.arg):
            out.add(n.arg)
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            out |= {a.asname or a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.Global):
            out |= set(n.names)
        elif isinstance(n, ast.Nonlocal):
            out |= set(n.names)
    return out


def check_source(src, vm, label):
    """return undefined names read in the source"""
    tree = ast.parse(src)
    module_scope = set()
    for s in tree.body:
        if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            module_scope.add(s.name)
        else:
            module_scope |= bound_in(s)
    module_scope |= star_import_names(tree, vm)
    visible = module_scope | BUILTIN

    bad = []

    def walk_scope(node, enclosing):
        """report undefined names in a function"""
        scope = enclosing | bound_in(node)
        for child in ast.iter_child_nodes(node):
            for n in ast.walk(child):
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id not in scope:
                    bad.append(f"{label}:{n.lineno}: {getattr(node,'name','module')}() reads "
                               f"'{n.id}', which nothing in scope defines")
        for n in ast.walk(node):
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n is not node:
                if _parent_func(node, n) is node:
                    walk_scope(n, scope)

    def _parent_func(root, target):
        """return the enclosing function of target"""
        best = root
        for n in ast.walk(root):
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n is not target:
                for c in ast.walk(n):
                    if c is target and (best is root or _depth(n) > _depth(best)):
                        best = n
        return best

    def _depth(n):
        """return the line number of a node"""
        return getattr(n, "lineno", 0)

    for fn in [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        walk_scope(fn, visible)

    top = ast.Module(body=[s for s in tree.body
                           if not isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef,
                                                 ast.ClassDef))], type_ignores=[])
    for n in ast.walk(top):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id not in visible:
            bad.append(f"{label}:{n.lineno}: module level reads '{n.id}', "
                       f"which nothing in scope defines")
    return bad


def signature_of(fn):
    """return the parameter lists of a function"""
    a = fn.args
    pos = [p.arg for p in a.posonlyargs + a.args]
    required = pos[:len(pos) - len(a.defaults)] if a.defaults else pos
    maxpos = None if a.vararg else len(pos)
    kwonly = [p.arg for p in a.kwonlyargs]
    kw_required = [p.arg for i, p in enumerate(a.kwonlyargs) if a.kw_defaults[i] is None]
    return (required, maxpos, set(pos) | set(kwonly), kw_required, a.kwarg is not None)


def project_signatures(vm, names):
    """return signatures of top-level launcher functions"""
    sigs = {}
    for m in names:
        path = os.path.join(vm, m)
        if not os.path.exists(path):
            continue
        for s in ast.parse(open(path).read()).body:
            if isinstance(s, ast.FunctionDef) and not s.decorator_list:
                sigs.setdefault(s.name, []).append(signature_of(s))
    return sigs


def _call_fits(call, sig):
    """return whether a call's arguments fit a function signature"""
    required, maxpos, params, kw_required, has_kwarg = sig
    if any(isinstance(a, ast.Starred) for a in call.args):
        return True
    if any(k.arg is None for k in call.keywords):
        return True
    npos = len(call.args)
    kws = {k.arg for k in call.keywords}
    if maxpos is not None and npos > maxpos:
        return False
    if not has_kwarg and any(k not in params for k in kws):
        return False
    if any(name not in kws for name in required[npos:]):
        return False
    if any(name not in kws for name in kw_required):
        return False
    return True


def check_calls(src, sigs, label):
    """report calls with mismatched arguments"""
    tree = ast.parse(src)
    shadowed = set()
    for s in tree.body:
        if not isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            shadowed |= {x.id for x in ast.walk(s)
                         if isinstance(x, ast.Name) and isinstance(x.ctx, ast.Store)}
    bad = []

    def scan(node, local_shadow):
        """record calls in a node that fit none of the known signatures"""
        for n in ast.walk(node):
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
                name = n.func.id
                if name in sigs and name not in shadowed and name not in local_shadow:
                    if not any(_call_fits(n, s) for s in sigs[name]):
                        got = f"{len(n.args)} positional" + (
                            f" + keywords {sorted(k.arg for k in n.keywords)}"
                            if n.keywords else "")
                        bad.append(f"{label}:{n.lineno}: {name}() called with {got}, "
                                   f"which no definition of it accepts")

    for fn in [n for n in tree.body if isinstance(n, ast.FunctionDef)]:
        scan(fn, bound_in(fn))
    top = ast.Module(body=[s for s in tree.body
                           if not isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef,
                                                 ast.ClassDef))], type_ignores=[])
    scan(top, set())
    return bad


def selftest():
    """test the undefined name checks"""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        src = ("def a():\n    shared = 1\n    return shared\n"
               "def b():\n    return shared\n")
        bad = check_source(src, d, "t.py")
        if not any("'shared'" in x for x in bad):
            print("selftest FAIL: a cross-function local was not reported", file=sys.stderr)
            return 1
        ok = ("import os\nTOP = 1\n"
              "def a(arg, *, kw=2):\n"
              "    loc = TOP + arg + kw\n"
              "    try:\n        pass\n    except OSError as e:\n        print(e)\n"
              "    return [x for x in os.listdir('.') if x], loc\n"
              "def b():\n    def inner(): return 1\n    return inner()\n")
        bad = check_source(ok, d, "t.py")
        if bad:
            print(f"selftest FAIL: reported legitimate names: {bad}", file=sys.stderr)
            return 1
        os.makedirs(os.path.join(d, "sub"), exist_ok=True)
        open(os.path.join(d, "lib.py"), "w").write("CONST = 1\ndef helper(): pass\n")
        star = "from lib import *\ndef a():\n    return CONST + helper()\n"
        bad = check_source(star, d, "t.py")
        if bad:
            print(f"selftest FAIL: star-import names reported as undefined: {bad}", file=sys.stderr)
            return 1

    sigs = {"f": [signature_of(ast.parse("def f(a): pass").body[0])]}
    if not check_calls("def g():\n    return f(1, 2)\n", sigs, "t.py"):
        print("selftest FAIL: an over-supplied call was not reported", file=sys.stderr)
        return 1
    if check_calls("def g():\n    return f(1)\n", sigs, "t.py"):
        print("selftest FAIL: a correct call was reported", file=sys.stderr)
        return 1
    if not check_calls("def g():\n    return f()\n", sigs, "t.py"):
        print("selftest FAIL: a missing required argument was not reported", file=sys.stderr)
        return 1
    if not check_calls("def g():\n    return f(1, nope=2)\n", sigs, "t.py"):
        print("selftest FAIL: an unknown keyword was not reported", file=sys.stderr)
        return 1
    if check_calls("def g(f):\n    return f(1, 2)\n", sigs, "t.py"):
        print("selftest FAIL: a parameter-shadowed call was reported", file=sys.stderr)
        return 1
    if check_calls("f = min\ndef g():\n    return f(1, 2)\n", sigs, "t.py"):
        print("selftest FAIL: a module-shadowed call was reported", file=sys.stderr)
        return 1
    vsig = {"v": [signature_of(ast.parse("def v(*a): pass").body[0])]}
    if check_calls("def g(xs):\n    return v(1, 2, 3) + v(*xs)\n", vsig, "t.py"):
        print("selftest FAIL: a vararg call was reported", file=sys.stderr)
        return 1
    return 0


def main():
    """run the check on every launcher module or run the selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    found = modules()
    if len(found) < 2:
        return 1 if print("found no launcher modules to check",
                          file=sys.stderr) is None else 1
    sigs = project_signatures(REPO, found)
    for m in found:
        path = os.path.join(REPO, m)
        if not os.path.exists(path):
            bad.append(f"{m} is missing")
            continue
        src = open(path).read()
        bad += check_source(src, REPO, m)
        bad += check_calls(src, sigs, m)
    for b in bad:
        print(b, file=sys.stderr)
    if bad:
        print(f"\n{len(bad)} finding(s): a name that resolves to nothing or a call no "
              f"signature accepts.", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
