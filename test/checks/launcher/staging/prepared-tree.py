#!/usr/bin/env python3
import ast
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
from sandbox import core  # noqa: E402

LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
HALS = os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")
FLAGGED_SUBSTRINGS = ("/run/rhizo/vendor/bin", "/run/rhizo/vendor/lib")


_input_meta = core.input_meta
_output_meta = core.output_meta


def _write_manifest(tree, manifest):
    """write a manifest file into a tree"""
    with open(os.path.join(tree, "manifest.json"), "w") as f:
        json.dump(manifest, f)




def _make_fixture(root):
    """create a fixture prepared tree at root"""
    key = "abc123def456"
    tree = os.path.join(root, key)
    os.makedirs(tree, exist_ok=True)
    os.symlink(key, os.path.join(root, "current"))
    input_path = os.path.join(root, "input.bin")
    open(input_path, "wb").write(b"the input bytes")
    output_path = os.path.join(tree, "vendor", "bin", "hw", "rhizo-composer")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    open(output_path, "wb").write(b"the output bytes")
    manifest = {
        "layout_version": core.PREPARED_LAYOUT_VERSION,
        "gsi_fingerprint": core.GSI_FINGERPRINT,
        "kernel": os.uname().release,
        "gpu_driver": core.gpu_driver_dir(),
        "inputs": {input_path: _input_meta(input_path)},
        "outputs": {"vendor/bin/hw/rhizo-composer": _output_meta(output_path)},
    }
    _write_manifest(tree, manifest)
    return key, tree, input_path, output_path, manifest


def _with_fixture_host(root, fn):
    """run fn against a fixture PREPARED_ROOT"""
    saved_root, core.PREPARED_ROOT = core.PREPARED_ROOT, root
    try:
        return fn()
    finally:
        core.PREPARED_ROOT = saved_root


def _validate(root):
    """run validate_prepared on a fixture root"""
    return _with_fixture_host(root, core.validate_prepared)


def _selftest_validate_prepared():
    """check validate_prepared refusals on fixture trees"""
    n = 0

    with tempfile.TemporaryDirectory() as root:
        _make_fixture(root)
        got = _validate(root)
        assert got[0] is not None and got[1] is None, f"all-good fixture should validate clean: {got}"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, *_ = _make_fixture(root)
        os.unlink(os.path.join(tree, "manifest.json"))
        got = _validate(root)
        assert got == (None, "manifest-unreadable"), f"missing manifest: {got}"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        manifest["layout_version"] = "999"
        _write_manifest(tree, manifest)
        got = _validate(root)
        assert got == (None, "layout-version"), f"layout mismatch: {got}"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        manifest["gpu_driver"] = "gpu_driver_lavapipe"
        _write_manifest(tree, manifest)
        got = _validate(root)
        assert got == (None, "gpu-driver"), f"tree built with another driver set: {got}"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _make_fixture(root)
        saved = os.environ.get("RHIZO_GPU_DRIVER_DIR")
        os.environ["RHIZO_GPU_DRIVER_DIR"] = "gpu_driver_lavapipe"
        try:
            got = _validate(root)
        finally:
            if saved is None:
                del os.environ["RHIZO_GPU_DRIVER_DIR"]
            else:
                os.environ["RHIZO_GPU_DRIVER_DIR"] = saved
        assert got == (None, "gpu-driver"), f"launch naming another driver set: {got}"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, input_path, _output_path, manifest = _make_fixture(root)
        original = open(input_path, "rb").read()
        mutated = b"the OTHER bytes"
        assert len(mutated) == len(original), "fixture bug: lengths must match"
        open(input_path, "wb").write(mutated)
        st = os.stat(input_path)
        os.utime(input_path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
        got = _validate(root)
        assert got[0] is None and got[1] == f"input-changed:{input_path}", (
            f"same-size content change should refuse via the slow path: {got}")
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, _input_path, output_path, manifest = _make_fixture(root)
        replacement = output_path + ".replacement"
        open(replacement, "wb").write(b"the output bytes")
        os.replace(replacement, output_path)
        got = _validate(root)
        assert got == (None, "output-tampered:vendor/bin/hw/rhizo-composer"), (
            f"a replaced output (new inode, same content) should refuse: {got}")
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        manifest["outputs"]["vendor/bin/hw/rhizo-composer"]["label"] = "u:object_r:wrong_type:s0"
        _write_manifest(tree, manifest)
        got = _validate(root)
        assert got == (None, "output-tampered:vendor/bin/hw/rhizo-composer"), (
            f"a recorded label that disagrees with the real one should refuse: {got}")
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        manifest.update(layout_version="9", binder_srcversion="5089F74B1F87474A94CE73F")
        _write_manifest(tree, manifest)
        got = _validate(root)
        assert got == (None, "layout-version"), f"a tree a binder-module launcher wrote must be rebuilt: {got}"
        n += 1

    n += _selftest_rekey_prepared_kernel()
    return n


def _rekey(root):
    """run rekey_prepared_kernel on a fixture root"""
    return _with_fixture_host(root, core.rekey_prepared_kernel)


def _selftest_rekey_prepared_kernel():
    """test re-keying a prepared tree"""
    n = 0
    old = "6.8.0-136-generic-fixture"

    with tempfile.TemporaryDirectory() as root:
        key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        manifest["kernel"] = old
        _write_manifest(tree, manifest)
        assert _validate(root) == (None, "kernel"), "fixture bug: an old-kernel tree must refuse first"
        got = _rekey(root)
        assert got == (key, "rekeyed"), f"a tree that differs only in its kernel should re-key: {got}"
        got = _validate(root)
        assert got == (key, None), f"the re-keyed tree should validate on this kernel: {got}"
        after = json.load(open(os.path.join(tree, "manifest.json")))
        assert after["kernel"] == os.uname().release and after["kernel_history"] == [old], (
            f"the manifest should name this kernel and keep the old one: {after.get('kernel')}, "
            f"{after.get('kernel_history')}")
        assert not os.path.exists(os.path.join(tree, "manifest.json.tmp")), "the temp manifest was left behind"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        key, tree, _input_path, _output_path, manifest = _make_fixture(root)
        before = os.stat(os.path.join(tree, "manifest.json")).st_mtime_ns
        got = _rekey(root)
        assert got == (key, "unchanged"), f"a tree already on this kernel should be left: {got}"
        assert os.stat(os.path.join(tree, "manifest.json")).st_mtime_ns == before, "an unchanged tree was rewritten"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        _key, tree, input_path, _output_path, manifest = _make_fixture(root)
        manifest["kernel"] = old
        _write_manifest(tree, manifest)
        open(input_path, "wb").write(b"a different input, which no kernel update explains")
        got = _rekey(root)
        assert got == (None, f"input-changed:{input_path}"), f"a changed input must block the re-key: {got}"
        assert json.load(open(os.path.join(tree, "manifest.json")))["kernel"] == old, "a refused re-key moved the kernel"
        n += 1

    with tempfile.TemporaryDirectory() as root:
        got = _rekey(root)
        assert got == (None, "manifest-unreadable"), f"no tree to re-key should say so: {got}"
        n += 1

    return n



def _instanced_roots():
    """return the instanced root names and base paths"""
    tree = ast.parse(open(os.path.join(REPO, "src", "androidd", "sandbox", "core.py")).read())
    roots = {}
    for node in tree.body:
        if not (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)):
            continue
        call = node.value
        if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                and call.func.id in ("_instanced", "_instanced_for")):
            continue
        base = call.args[0] if call.args else None
        if isinstance(base, ast.Constant) and isinstance(base.value, str):
            roots[node.targets[0].id] = base.value
    return roots


INSTANCED_ROOTS = _instanced_roots()


def _joined_str_text(node, string_vars):
    """return the literal text of an f-string"""
    parts = []
    for v in node.values:
        if isinstance(v, ast.Constant) and isinstance(v.value, str):
            parts.append(v.value)
        elif isinstance(v, ast.FormattedValue):
            parts.append(_literal_text(v.value, string_vars))
    return "".join(parts)


def _literal_text(node, string_vars):
    """return the text of a string node, or an empty string"""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return _joined_str_text(node, string_vars)
    if isinstance(node, ast.Name):
        return string_vars.get(node.id, "")
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "core":
        return string_vars.get(node.attr, "")
    return ""


def find_bad_copies(path):
    """return the shutil copies into prepared paths"""
    tree = ast.parse(open(path).read(), filename=path)
    findings = []

    def collect(node, shutil_aliases, string_vars):
        """record shutil aliases and string variables assigned in a node"""
        for n in ast.walk(node):
            if isinstance(n, ast.Import):
                for alias in n.names:
                    if alias.name == "shutil":
                        shutil_aliases.add(alias.asname or alias.name)
            elif isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
                text = _literal_text(n.value, string_vars)
                if text:
                    string_vars[n.targets[0].id] = text

    module_shutil_aliases = set()
    module_string_vars = dict(INSTANCED_ROOTS)
    for top in tree.body:
        if not isinstance(top, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            collect(top, module_shutil_aliases, module_string_vars)

    def scan_scope(node):
        """record the bare copies in a scope"""
        shutil_aliases = set(module_shutil_aliases)
        string_vars = dict(module_string_vars)
        collect(node, shutil_aliases, string_vars)
        for n in ast.walk(node):
            if not isinstance(n, ast.Call):
                continue
            f = n.func
            if not (isinstance(f, ast.Attribute) and f.attr in ("copy", "copy2", "copyfile")):
                continue
            if not (isinstance(f.value, ast.Name) and f.value.id in shutil_aliases):
                continue
            dest_node = n.args[1] if len(n.args) > 1 else next(
                (kw.value for kw in n.keywords if kw.arg == "dst"), None)
            if dest_node is None:
                continue
            dest_text = _literal_text(dest_node, string_vars)
            if any(sub in dest_text for sub in FLAGGED_SUBSTRINGS):
                findings.append((n.lineno, dest_text))

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            scan_scope(node)
    module_level = ast.Module(body=[n for n in tree.body
                                     if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef,
                                                             ast.ClassDef, ast.Import, ast.ImportFrom))],
                               type_ignores=[])
    scan_scope(module_level)
    return findings


def _selftest_find_bad_copies():
    """test find_bad_copies on fixture files"""
    n = 0
    with tempfile.TemporaryDirectory() as d:
        bad = os.path.join(d, "bad.py")
        open(bad, "w").write(
            "import shutil as _sh\n"
            "def f(src):\n"
            "    dst = \"/run/rhizo/vendor/lib64/hw/evil.so\"\n"
            "    _sh.copy(src, dst)\n"
        )
        findings = find_bad_copies(bad)
        assert len(findings) == 1 and findings[0][0] == 4, (
            f"a bare copy into a prepared path should be caught, once, at its own line: {findings}")
        n += 1

    with tempfile.TemporaryDirectory() as d:
        clean = os.path.join(d, "clean.py")
        open(clean, "w").write(
            "from sandbox import core\n"
            "def f(src):\n"
            "    dst = \"/run/rhizo/vendor/lib64/hw/fine.so\"\n"
            "    core.stage_bulk(src, dst, 0o644)\n"
        )
        findings = find_bad_copies(clean)
        assert findings == [], f"a stage_bulk() call is not a bare copy: {findings}"
        n += 1

    with tempfile.TemporaryDirectory() as d:
        elsewhere = os.path.join(d, "elsewhere.py")
        open(elsewhere, "w").write(
            "import shutil as _sh\n"
            "def f(src):\n"
            "    _sh.copy(src, \"/run/rhizo/system_ext_upper/lib64/fine.so\")\n"
        )
        findings = find_bad_copies(elsewhere)
        assert findings == [], f"a copy outside vendor/{{bin,lib,lib64}} is not this check's concern: {findings}"
        n += 1

    with tempfile.TemporaryDirectory() as d:
        run_root_bad = os.path.join(d, "run_root_bad.py")
        open(run_root_bad, "w").write(
            "import shutil as _sh\n"
            "def f(src):\n"
            "    _sh.copy(src, f\"{RUN_ROOT}/vendor/lib64/hw/evil.so\")\n"
        )
        findings = find_bad_copies(run_root_bad)
        assert len(findings) == 1 and findings[0][0] == 3, (
            "a bare copy into an f\"{RUN_ROOT}/vendor/lib64/...\" destination "
            f"should be caught, once, at its own line: {findings}")
        n += 1

    with tempfile.TemporaryDirectory() as d:
        run_root_clean = os.path.join(d, "run_root_clean.py")
        open(run_root_clean, "w").write(
            "from sandbox import core\n"
            "def f(src):\n"
            "    core.stage_bulk(src, f\"{RUN_ROOT}/vendor/lib64/hw/fine.so\", 0o644)\n"
        )
        findings = find_bad_copies(run_root_clean)
        assert findings == [], (
            f"a stage_bulk() call to an f\"{{RUN_ROOT}}/...\" destination is not a bare copy: {findings}")
        n += 1

    with tempfile.TemporaryDirectory() as d:
        run_root_elsewhere = os.path.join(d, "run_root_elsewhere.py")
        open(run_root_elsewhere, "w").write(
            "import shutil as _sh\n"
            "def f(src):\n"
            "    _sh.copy(src, f\"{RUN_ROOT}/system_ext_upper/lib64/fine.so\")\n"
        )
        findings = find_bad_copies(run_root_elsewhere)
        assert findings == [], (
            f"an f\"{{RUN_ROOT}}/...\" copy outside vendor/{{bin,lib,lib64}} is not this check's concern: {findings}")
        n += 1

    return n



def _os_calls(fn, name):
    """return the sorted line numbers of calls to an os function"""
    return sorted(n.lineno for n in ast.walk(fn)
                  if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                  and n.func.attr == name and isinstance(n.func.value, ast.Name)
                  and n.func.value.id == "os")


def find_unsynced_publish(path, func="prepare_tree_verb"):
    """list the missing os.sync() calls"""
    tree = ast.parse(open(path).read(), filename=path)
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == func), None)
    if fn is None:
        return [f"no {func}() in {path}"]
    syncs, renames, replaces = (_os_calls(fn, a) for a in ("sync", "rename", "replace"))
    missing = []
    if not renames or not any(s < renames[0] for s in syncs):
        missing.append(f"no os.sync() before the os.rename at line {renames[0] if renames else '?'}")
    if not replaces or not any(s > replaces[-1] for s in syncs):
        missing.append(f"no os.sync() after the os.replace at line {replaces[-1] if replaces else '?'}")
    return missing


def _selftest_find_unsynced_publish():
    """check the unsynced publish detection"""
    n = 0
    body = ("import os\n"
            "def prepare_tree_verb(dest):\n"
            "    open(dest + '/part/manifest.json', 'w').write('{}')\n"
            "{pre}"
            "    os.rename(dest + '/part', dest + '/k')\n"
            "    os.symlink('k', dest + '/current.tmp')\n"
            "    os.replace(dest + '/current.tmp', dest + '/current')\n"
            "{post}")
    sync = "    os.sync()\n"
    cases = (("both", sync, sync, 0), ("neither", "", "", 2),
             ("before-only", sync, "", 1), ("after-only", "", sync, 1))
    for label, pre, post, want in cases:
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "boot.py")
            open(src, "w").write(body.replace("{pre}", pre).replace("{post}", post))
            got = find_unsynced_publish(src)
            assert len(got) == want, f"{label}: want {want} finding(s), got {got}"
            n += 1
    return n


def selftest():
    """run every selftest group and print the assertion count"""
    n = _selftest_validate_prepared()
    n += _selftest_find_bad_copies()
    n += _selftest_find_unsynced_publish()
    print("check-prepared-tree selftest: %d assertions passed" % n)


def main():
    """run the check on the launcher and hals sources"""
    findings = find_bad_copies(LAUNCHER) + find_bad_copies(HALS)
    unsynced = find_unsynced_publish(LAUNCHER)
    if not findings and not unsynced:
        return 0
    for lineno, dest in findings:
        print(f"check-prepared-tree: a bare copy at line {lineno} writes into a "
              f"prepared bind path ({dest!r}) -- use core.stage_bulk() instead")
    for what in unsynced:
        print(f"check-prepared-tree: prepare_tree_verb publishes `current` unsynced: {what}")
    return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    sys.exit(main())
