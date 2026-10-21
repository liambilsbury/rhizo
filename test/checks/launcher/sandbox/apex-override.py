#!/usr/bin/env python3
import os
import stat
import sys
import tempfile
import zipfile

USAGE = """Usage: apex-override.py --selftest"""

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

import boot as launcher3  # noqa: E402
from sandbox import rootfs  # noqa: E402


def _capex(path, payload, manifest=b"\x0a\x03abc"):
    """write a compressed APEX zip"""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("apex_manifest.pb", manifest)
        zf.writestr("original_apex", payload)


def _apex(path, payload):
    """write an uncompressed APEX zip"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("apex_manifest.pb", b"\x0a\x03abc")
        zf.writestr("apex_payload.img", payload)


def test_targets_map_each_override_to_the_capex_it_replaces():
    """check that each override maps to the compressed apex it replaces"""
    gsi = ["com.android.art.capex", "com.android.tzdata.apex", "com.android.wifi.capex"]
    targets, unmatched = rootfs.apex_override_targets(
        ["com.android.art.apex", "com.android.wifi.apex"], gsi)
    assert targets == {"com.android.art.capex": "com.android.art.apex",
                       "com.android.wifi.capex": "com.android.wifi.apex"}, targets
    assert unmatched == [], unmatched


def test_targets_replace_an_uncompressed_entry_under_its_own_name():
    """check that an uncompressed entry is replaced under its name"""
    targets, unmatched = rootfs.apex_override_targets(
        ["com.android.tzdata.apex"], ["com.android.tzdata.apex"])
    assert targets == {"com.android.tzdata.apex": "com.android.tzdata.apex"}, targets
    assert unmatched == []


def test_targets_leave_a_new_name_unbound_and_name_it():
    """check that a new name is left unbound and reported"""
    targets, unmatched = rootfs.apex_override_targets(
        ["com.example.new.apex", "notes.txt", "x.apex.part"], ["com.android.art.capex"])
    assert targets == {}, targets
    assert unmatched == ["com.example.new.apex"], unmatched


def test_extraction_is_byte_exact_and_deterministic(tmp):
    """check that extraction is byte-exact and gives the same result twice"""
    apex_dir = os.path.join(tmp, "apex"); os.makedirs(apex_dir)
    dest = os.path.join(tmp, "override"); os.makedirs(dest)
    payload_a = b"A" * 70000 + b"tail-a"
    payload_b = os.urandom(4096) * 3
    _capex(os.path.join(apex_dir, "com.android.a.capex"), payload_a)
    _capex(os.path.join(apex_dir, "com.android.b.capex"), payload_b)
    _apex(os.path.join(apex_dir, "com.android.plain.apex"), b"plain")
    logged = []
    staged, failed = launcher3._stage_decompressed_apexes(apex_dir, dest, log=logged.append)
    assert failed == [], failed
    assert staged == ["com.android.a.apex", "com.android.b.apex"], staged
    assert open(os.path.join(dest, "com.android.a.apex"), "rb").read() == payload_a
    assert open(os.path.join(dest, "com.android.b.apex"), "rb").read() == payload_b
    assert not os.path.exists(os.path.join(dest, "com.android.plain.apex")), \
        "an uncompressed GSI apex needs no override and must not get one"
    st = os.stat(os.path.join(dest, "com.android.a.apex"))
    assert st.st_mtime == 0, "mtime is the materializer's deterministic stamp, not now"
    assert stat.S_IMODE(st.st_mode) == 0o644
    assert not [n for n in os.listdir(dest) if n.endswith(".part")], "no temp file left behind"


def test_extraction_leaves_a_stem_that_already_has_a_payload(tmp):
    """check that extraction leaves a name that already has a payload"""
    apex_dir = os.path.join(tmp, "apex"); os.makedirs(apex_dir)
    dest = os.path.join(tmp, "override"); os.makedirs(dest)
    _capex(os.path.join(apex_dir, "com.android.tethering.capex"), b"google's tethering")
    with open(os.path.join(dest, "com.android.tethering.apex"), "wb") as f:
        f.write(b"the patched tethering payload")
    staged, failed = launcher3._stage_decompressed_apexes(apex_dir, dest, log=lambda m: None)
    assert staged == [] and failed == [], (staged, failed)
    assert open(os.path.join(dest, "com.android.tethering.apex"), "rb").read() == \
        b"the patched tethering payload", "the patched payload was overwritten"


def test_a_bad_capex_is_reported_and_the_rest_still_staged(tmp):
    """test staging of good and bad .capex files"""
    apex_dir = os.path.join(tmp, "apex"); os.makedirs(apex_dir)
    dest = os.path.join(tmp, "override"); os.makedirs(dest)
    _capex(os.path.join(apex_dir, "com.android.good.capex"), b"good")
    with open(os.path.join(apex_dir, "com.android.notazip.capex"), "wb") as f:
        f.write(b"this is not a zip file")
    with zipfile.ZipFile(os.path.join(apex_dir, "com.android.noentry.capex"), "w") as zf:
        zf.writestr("apex_manifest.pb", b"\x0a\x03abc")
    staged, failed = launcher3._stage_decompressed_apexes(apex_dir, dest, log=lambda m: None)
    assert staged == ["com.android.good.apex"], staged
    assert len(failed) == 2 and any("notazip" in f for f in failed) \
        and any("noentry" in f for f in failed), failed
    assert sorted(os.listdir(dest)) == ["com.android.good.apex"], \
        "a failed extraction must leave no file, partial or otherwise"


def test_a_missing_apex_dir_is_one_failure_not_a_crash(tmp):
    """check that a missing apex directory gives a failure"""
    staged, failed = launcher3._stage_decompressed_apexes(
        os.path.join(tmp, "absent"), tmp, log=lambda m: None)
    assert staged == [] and len(failed) == 1, (staged, failed)


def test_the_extraction_records_its_inputs_for_the_prepared_key(tmp):
    """check that extraction records its inputs for the prepared key"""
    from sandbox import core
    apex_dir = os.path.join(tmp, "apex"); os.makedirs(apex_dir)
    dest = os.path.join(tmp, "override"); os.makedirs(dest)
    _capex(os.path.join(apex_dir, "com.android.k.capex"), b"k")
    core.set_prepare_recording(True)
    try:
        launcher3._stage_decompressed_apexes(apex_dir, dest, log=lambda m: None)
        recorded = core.recorded_copies()
    finally:
        core.set_prepare_recording(False)
    assert recorded == [(os.path.join(apex_dir, "com.android.k.capex"),
                         os.path.join(dest, "com.android.k.apex"))], recorded


def test_extraction_labels_only_when_asked(tmp):
    """check the label write follows the label argument"""
    apex_dir = os.path.join(tmp, "apex"); os.makedirs(apex_dir)
    _capex(os.path.join(apex_dir, "com.android.a.capex"), b"payload")
    writes = []
    saved = os.setxattr
    os.setxattr = lambda path, name, value, *a, **kw: writes.append((os.path.basename(path), name, value))
    try:
        labeled = [("com.android.a.apex", "security.selinux", b"u:object_r:system_file:s0\0")]
        for label, want in ((False, []), (True, labeled)):
            dest = os.path.join(tmp, f"override-{label}"); os.makedirs(dest)
            writes.clear()
            staged, failed = launcher3._stage_decompressed_apexes(apex_dir, dest, log=lambda m: None, label=label)
            assert (staged, failed, writes) == (["com.android.a.apex"], [], want), (label, staged, failed, writes)
    finally:
        os.setxattr = saved


def test_a_policy_host_in_namespace_mode_refuses_android_labels():
    """check host_refuses_android_labels for each mode and context"""
    from sandbox import selinux_ns
    saved = launcher3.host_selinux_mode, selinux_ns.host_context
    try:
        for host_mode, ctx, want in ((True, "u:r:init:s0", False), (False, "kernel", False),
                                     (False, "system_u:system_r:initrc_t:s0", True)):
            launcher3.host_selinux_mode = lambda: host_mode
            selinux_ns.host_context = lambda: ctx
            got = launcher3.host_refuses_android_labels()
            assert got == want, (host_mode, ctx, got)
    finally:
        launcher3.host_selinux_mode, selinux_ns.host_context = saved


def test_the_per_boot_staging_skips_labels_the_host_refuses():
    """check the host gate covers each per-boot write"""
    import ast
    tree = ast.parse(open(os.path.join(REPO, "src", "androidd", "boot.py")).read())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "stage_apex_and_patches")
    asks = [n for n in ast.walk(fn)
            if isinstance(n, ast.Assign) and ast.unparse(n.value) == "host_refuses_android_labels()"]
    reads = [n for n in ast.walk(fn)
             if isinstance(n, ast.Call) and ast.unparse(n.func) == "host_refuses_android_labels"]
    assert len(asks) == 1 and len(reads) == 1, ("ask the host once", [ast.unparse(a) for a in asks], len(reads))
    gate = ast.unparse(asks[0].targets[0])
    calls = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
             and ast.unparse(n.func) in ("_stage_decompressed_apexes", "_stage_tethering_apex")]
    assert len(calls) == 3, [ast.unparse(c) for c in calls]
    for c in calls:
        kw = {k.arg: ast.unparse(k.value) for k in c.keywords}
        assert kw.get("label") == f"not {gate}", ast.unparse(c)
    writes = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func) == "os.setxattr"]
    gated = [w for i in ast.walk(fn) if isinstance(i, ast.If) and ast.unparse(i.test) == f"not {gate}"
             for w in ast.walk(i) if w in writes]
    assert len(gated) == len(writes), [ast.unparse(w) for w in writes]


def test_the_flat_rebuild_binds_each_override_under_the_capex_name():
    """search sandbox/rootfs.py for the APEX override lines"""
    src = open(os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")).read()
    for needle in ("apex_overrides, _apex_unmatched = apex_override_targets(",
                   "if _apex_name in apex_overrides:",
                   "for _apex_name, _override_file in apex_overrides.items():",
                   "_apex_expect_size[_apex_name] = os.path.getsize(apex_override_src)"):
        assert needle in src, f"sandbox/rootfs.py no longer carries: {needle}"
    assert 'apex_override_name = "com.android.tethering.capex"' not in src, \
        "the rebuild is back to the single tethering override"


def selftest():
    """run every test case"""
    cases = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    import inspect
    n = 0
    for case in cases:
        if inspect.signature(case).parameters:
            with tempfile.TemporaryDirectory(prefix="apex-override-") as tmp:
                case(tmp)
        else:
            case()
        n += 1
        print(f"  ok: {case.__name__}")
    print(f"check-apex-override selftest: {n} cases passed")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    print(USAGE, file=sys.stderr)
    sys.exit(2)
