#!/usr/bin/env python3
"""Tests for apid.py"""
import importlib.util
import json
import os
import select
import shutil
import signal
import socket
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, filename):
    """load a module from the parent directory by file name"""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


apid = load("rhizo_apid", "apid.py")

failures = []
checked = []


def check(name, got, want):
    """record and print a named check"""
    checked.append(name)
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s: got %r, want %r" % (name, got, want))
        failures.append(name)


def refusal(fn, *args):
    """return the refusal message raised by a call"""
    try:
        fn(*args)
    except apid.Refused as e:
        return str(e)
    return None


def resolved(fn, *args):
    """call fn and return {} on `Refused`"""
    try:
        return fn(*args)
    except apid.Refused:
        return {}


def req(**fields):
    """return an encoded request line"""
    fields.setdefault("v", 1)
    return json.dumps(fields).encode()


def test_parse_request_envelope():
    """check the request envelope rules for version and verb"""
    check("a missing version is refused",
          refusal(apid.parse_request, req(verb="instances", v=None)) is None, False)
    check("v=2 is refused", refusal(apid.parse_request, req(verb="instances", v=2)) is None, False)
    check("an unknown verb is refused", refusal(apid.parse_request, req(verb="reboot-host")) is None, False)
    check("a non-JSON line is refused",
          refusal(apid.parse_request, b"not json") is None, False)
    check("a non-object JSON line is refused",
          refusal(apid.parse_request, b"[1,2,3]") is None, False)
    check("instances with no id parses clean",
          apid.parse_request(req(verb="instances")), ("instances", None, []))
    check("release with id=3 parses clean",
          apid.parse_request(req(verb="release", id=3)), ("release", 3, []))


def test_parse_request_id_grammar():
    """check the request id range rules"""
    check("id=100 is refused (0-99 only)",
          refusal(apid.parse_request, req(verb="release", id=100)) is None, False)
    check("id=-1 is refused", refusal(apid.parse_request, req(verb="release", id=-1)) is None, False)
    check("id=0 is accepted (the default instance, e.g. for release)",
          apid.parse_request(req(verb="release", id=0))[1], 0)
    check("a bool id is refused (bool is an int subclass in python)",
          refusal(apid.parse_request, req(verb="release", id=True)) is None, False)
    check("a string id is refused",
          refusal(apid.parse_request, req(verb="release", id="3")) is None, False)


def test_parse_request_args_grammar():
    """check the request argument type and size rules"""
    check("args must be a list", refusal(apid.parse_request, req(verb="launch", args="x")) is None, False)
    check("args must be strings",
          refusal(apid.parse_request, req(verb="launch", args=[1, 2])) is None, False)
    check("an oversized argument is refused",
          refusal(apid.parse_request, req(verb="launch", args=["x" * 4097])) is None, False)
    check("args at the limit are accepted",
          apid.parse_request(req(verb="launch", id=1, args=["x" * 4096]))[2], ["x" * 4096])


def test_build_plan_allocate():
    """check the plan built for the allocate verb"""
    env, argv = apid.build_plan("allocate", None, [])
    check("allocate needs no env override", env, {})
    check("allocate's own argv", argv, ["instance", "allocate"])
    check("allocate takes no arguments", refusal(apid.build_plan, "allocate", None, ["x"]) is None, False)


def test_build_plan_release():
    """check the plan built for the release verb"""
    env, argv = apid.build_plan("release", 5, [])
    check("release scopes RHIZO_SANDBOX_ID", env, {"RHIZO_SANDBOX_ID": "5"})
    check("release's own argv", argv, ["instance", "release", "5"])
    check("release needs an id", refusal(apid.build_plan, "release", None, []) is None, False)


def test_build_plan_install():
    """check the plan built for the install verb"""
    env, argv = apid.build_plan("install", 2, ["/tmp/x.apk"])
    check("install scopes RHIZO_SANDBOX_ID", env, {"RHIZO_SANDBOX_ID": "2"})
    check("install's own argv", argv, ["app", "install", "/tmp/x.apk"])
    check("install needs an id", refusal(apid.build_plan, "install", None, ["/tmp/x.apk"]) is None, False)
    check("install takes exactly one path",
          refusal(apid.build_plan, "install", 2, []) is None, False)
    check("install takes exactly one path (not two)",
          refusal(apid.build_plan, "install", 2, ["/a", "/b"]) is None, False)


def test_build_plan_launch():
    """check the plan built for the launch verb"""
    env, argv = apid.build_plan("launch", 1, ["com.x"])
    check("launch's own argv, package only", argv, ["launch", "com.x"])
    env, argv = apid.build_plan("launch", 1, ["com.x", "https://example.test"])
    check("launch's own argv, package + target", argv, ["launch", "com.x", "https://example.test"])
    check("launch needs an id", refusal(apid.build_plan, "launch", None, ["com.x"]) is None, False)
    check("launch needs at least a package",
          refusal(apid.build_plan, "launch", 1, []) is None, False)
    check("launch takes at most 2 arguments",
          refusal(apid.build_plan, "launch", 1, ["com.x", "a", "b"]) is None, False)


def test_build_plan_verb_takes_no_id():
    """check that a verb taking no id refuses one"""
    check("allocate is refused an instance id",
          refusal(apid.build_plan, "allocate", 3, []) is None, False)


def test_instances_snapshot():
    """check the instance rows built from systemctl output"""
    def fake_list_units():
        """return canned systemctl list-units output"""
        return (
            "androidd.service      loaded active running Rhizo Android sandbox (androidd)\n"
            "androidd@1.service    loaded active running Rhizo Android sandbox (androidd), instance 1\n"
            "androidd@2.service    loaded active failed  Rhizo Android sandbox (androidd), instance 2\n"
        )
    with tempfile.TemporaryDirectory() as tmp:
        members = os.path.join(tmp, "pool-members")
        with open(members, "w") as f:
            f.write("2\n")
        rows = apid.instances_snapshot(list_units=fake_list_units, pool_members_path=members)
    check("three instances parsed", len(rows), 3)
    check("sorted by id", [r["id"] for r in rows], [0, 1, 2])
    check("id 0 comes from the bare unit name", rows[0]["unit"], "androidd.service")
    check("id 1 is not pooled", rows[1]["pooled"], False)
    check("id 2 IS pooled (listed in pool-members)", rows[2]["pooled"], True)
    check("state is the 4th systemctl column", rows[2]["state"], "failed")


def test_instances_snapshot_missing_pool_members_is_not_an_error():
    """check a missing pool-members file"""
    rows = apid.instances_snapshot(
        list_units=lambda: "androidd.service loaded active running x\n",
        pool_members_path="/does/not/exist/pool-members")
    check("no pool-members file -> pooled=False, not a crash", rows[0]["pooled"], False)


def test_instances_snapshot_list_units_failure_is_refused():
    """test the refusal of a failed systemctl call"""
    def raising_list_units():
        """raise a refusal as if systemctl could not run"""
        raise apid.Refused("cannot run systemctl: [Errno 2] No such file or directory")
    check("a systemctl failure is refused by name, not an uncaught exception",
          refusal(apid.instances_snapshot, raising_list_units) is not None, True)


def test_instances_snapshot_ignores_unrelated_units():
    """check that units outside the androidd family are ignored"""
    rows = apid.instances_snapshot(
        list_units=lambda: (
            "androidd.service loaded active running x\n"
            "rhizo-hostfs.service loaded active running y\n"
            "androidd@notanumber.service loaded active running z\n"
        ),
        pool_members_path="/does/not/exist")
    check("only real androidd/androidd@<N> units are kept", [r["unit"] for r in rows], ["androidd.service"])


def test_tail_logs():
    """check that the log tail returns the last lines requested"""
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "boot.log"), "w") as f:
            f.write("line1\nline2\nline3\n")
        lines = apid.tail_logs(0, lines=2, log_dir=tmp)
        check("tail_logs returns the last N lines", lines, ["line2", "line3"])

        with open(os.path.join(tmp, "boot-1.log"), "w") as f:
            f.write("a\nb\n")
        lines = apid.tail_logs(1, lines=200, log_dir=tmp)
        check("instance N reads boot-N.log, not the bare name", lines, ["a", "b"])


def test_tail_logs_missing_file():
    """check that a missing boot log is refused by name"""
    with tempfile.TemporaryDirectory() as tmp:
        check("a missing log file is refused by name",
              "no boot log for instance 7" in (refusal(apid.tail_logs, 7, 200, tmp) or ""), True)


STUB_WORDS = ("not implemented", "unimplemented", "not_implemented")


def test_every_verb_has_something_behind_it():
    """test each verb has a local handler or a CLI argv"""
    check("the daemon keeps no NOT_IMPLEMENTED table at all",
          getattr(apid, "NOT_IMPLEMENTED", None), None)
    for verb in sorted(apid.VERBS):
        served = verb in apid.LOCAL_HANDLERS or (apid.VERBS.get(verb) or (None, None))[1] is not None
        check("%s has something behind it (a local handler or a CLI argv)" % verb, served, True)


def test_every_verb_refuses_only_for_its_own_reasons():
    """test the refusals of each CLI verb"""
    for verb in sorted(apid.VERBS):
        if verb in apid.LOCAL_HANDLERS or verb not in apid.VERBS:
            continue
        msg = (refusal(apid.build_plan, verb, 0, []) or "").lower()
        check("%s's own refusal path never says 'not implemented'" % verb,
              any(w in msg for w in STUB_WORDS), False)


def test_instance_paths_id_zero_is_unchanged():
    """check that instance 0 keeps the unnumbered paths"""
    check("instance 0's run root is the bare path every existing tool expects",
          apid.instance_run_root(0), "/run/rhizo")
    check("instance 3's run root carries its own id", apid.instance_run_root(3), "/run/rhizo-3")
    check("instance 0's cgroup record is the bare path",
          apid.instance_cgroup_root_file(0), "/root/.rhizo_cgroup_root")
    check("instance 3's cgroup record carries its own id",
          apid.instance_cgroup_root_file(3), "/root/.rhizo_cgroup_root-3")


def test_build_plan_set():
    """check the plan built for the set verb"""
    env, argv = apid.build_plan("set", 2, ["battery", "55", "charging"])
    check("set scopes RHIZO_SANDBOX_ID too", env, {"RHIZO_SANDBOX_ID": "2"})
    check("set battery's own argv carries the -i selector",
          argv, ["-i", "2", "device", "set", "battery", "55", "charging"])
    _, argv = apid.build_plan("set", 0, ["thermal", "41.5"])
    check("set thermal on instance 0 still passes -i 0 explicitly",
          argv, ["-i", "0", "device", "set", "thermal", "41.5"])
    _, argv = apid.build_plan("set", 7, ["gps", "48.4", "-123.3"])
    check("set gps's own argv", argv, ["-i", "7", "device", "set", "gps", "48.4", "-123.3"])


def test_build_plan_set_grammar():
    """check the argument rules of the set verb"""
    check("set needs an id",
          refusal(apid.build_plan, "set", None, ["battery", "5", "charging"]) is None, False)
    check("set needs a subject", refusal(apid.build_plan, "set", 1, []) is None, False)
    check("an unknown subject is refused by name",
          "wifi" in (refusal(apid.build_plan, "set", 1, ["wifi", "on"]) or ""), True)
    check("battery takes a level and a state",
          refusal(apid.build_plan, "set", 1, ["battery", "55"]) is None, False)
    check("thermal takes one value",
          refusal(apid.build_plan, "set", 1, ["thermal", "41.5", "extra"]) is None, False)
    check("gps takes a lat and a lon",
          refusal(apid.build_plan, "set", 1, ["gps", "48.4"]) is None, False)


SWAY_TREE = {
    "nodes": [{
        "nodes": [
            {"pid": 4001, "app_id": "rhizo", "name": "Rhizo",
             "rect": {"x": 0, "y": 0, "width": 960, "height": 1080},
             "nodes": [], "floating_nodes": []},
            {"pid": 4002, "app_id": "rhizo", "name": "Rhizo",
             "rect": {"x": 960, "y": 0, "width": 960, "height": 1080},
             "nodes": [], "floating_nodes": []},
        ],
        "floating_nodes": [],
    }],
    "floating_nodes": [],
}


def test_window_rect_for_pids():
    """check that the window is chosen by the instance's process ids"""
    check("the toplevel whose client pid is in this instance's cgroup wins",
          apid.window_rect_for_pids(SWAY_TREE, {4002, 4099}),
          {"x": 960, "y": 0, "width": 960, "height": 1080})
    check("a pid set matching no toplevel resolves to nothing, never to a peer's window",
          apid.window_rect_for_pids(SWAY_TREE, {5000}), None)
    check("a zero-area toplevel is not a window",
          apid.window_rect_for_pids(
              {"nodes": [{"pid": 7, "rect": {"x": 0, "y": 0, "width": 0, "height": 0},
                          "nodes": [], "floating_nodes": []}], "floating_nodes": []}, {7}),
          None)


LAUNCHER_PID = 900
SUPERVISOR_PID = 940
INIT_PID = 941
COMPOSER_PID = 4002


def launcher_cgroup_tree(tmp, name="cgroup", composer_pid=COMPOSER_PID):
    """write a launcher cgroup tree"""
    cg = os.path.join(tmp, name)
    leaves = {"": [],
              "launcher": [LAUNCHER_PID],
              "init": [SUPERVISOR_PID, INIT_PID],
              "system": [],
              os.path.join("apps", "uid_10100", "pid_%d" % composer_pid): [composer_pid]}
    for leaf, pids in leaves.items():
        d = os.path.join(cg, leaf)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cgroup.procs"), "w") as f:
            f.write("".join("%d\n" % pid for pid in pids))
    return cg


def root_only_pids(cgroup_root):
    """read pids from the root cgroup.procs"""
    with open(os.path.join(cgroup_root, "cgroup.procs")) as f:
        return {int(token) for token in f.read().split() if token.isdigit()}


def test_instance_pids_reads_the_whole_recorded_cgroup_tree():
    """check that instance pids come from the whole recorded cgroup tree"""
    with tempfile.TemporaryDirectory() as tmp:
        cg = launcher_cgroup_tree(tmp)
        check("every pid anywhere in the instance's own cgroup tree",
              apid.instance_pids(cg),
              {LAUNCHER_PID, SUPERVISOR_PID, INIT_PID, COMPOSER_PID})
        check("the stack root itself holds no process, by design and necessity",
              root_only_pids(cg), set())
        check("so the root-only read this replaced finds NONE of this instance's pids",
              root_only_pids(cg) & apid.instance_pids(cg), set())
        check("a cgroup that does not exist is refused by name",
              "cgroup.procs" in (refusal(apid.instance_pids, os.path.join(tmp, "gone")) or ""), True)


def test_instance_pids_tolerates_a_cgroup_that_vanished_mid_walk():
    """test a cgroup vanishing during the walk"""
    with tempfile.TemporaryDirectory() as tmp:
        cg = launcher_cgroup_tree(tmp)
        gone = os.path.join(cg, "apps", "uid_10100", "pid_5050")
        os.makedirs(gone)
        os.symlink(os.path.join(gone, "never"), os.path.join(gone, "cgroup.procs"))
        check("a leaf that went away is skipped, and the rest of the tree still reads",
              apid.instance_pids(cg),
              {LAUNCHER_PID, SUPERVISOR_PID, INIT_PID, COMPOSER_PID})


def test_instance_pids_is_the_same_read_at_id_zero():
    """test instance_pids at instance id 0"""
    with tempfile.TemporaryDirectory() as tmp:
        zero = launcher_cgroup_tree(tmp, name="rhizo", composer_pid=4002)
        one = launcher_cgroup_tree(tmp, name="rhizo-1", composer_pid=4001)
        check("instance 0's own pids, from a root as empty as any peer's",
              apid.instance_pids(zero),
              {LAUNCHER_PID, SUPERVISOR_PID, INIT_PID, 4002})
        check("and never a peer's composer",
              4001 in apid.instance_pids(zero), False)
        check("the peer reads its own, out of its own tree",
              4001 in apid.instance_pids(one), True)


def one_by_one_png():
    """build a 1x1 PNG with zlib"""
    import binascii
    import zlib

    def chunk(tag, payload):
        """return a PNG chunk with its length and checksum"""
        body = tag + payload
        return (len(payload).to_bytes(4, "big") + body
                + binascii.crc32(body).to_bytes(4, "big"))

    ihdr = (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + bytes([8, 2, 0, 0, 0])
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b""))


def test_png_dimensions():
    """check that PNG dimensions are read and malformed files refused"""
    with tempfile.TemporaryDirectory() as tmp:
        good = os.path.join(tmp, "good.png")
        with open(good, "wb") as f:
            f.write(one_by_one_png())
        check("a real PNG's own IHDR dimensions", apid.png_dimensions(good), (1, 1))
        empty = os.path.join(tmp, "empty.png")
        open(empty, "wb").close()
        check("an empty file is not an image, and is refused by name",
              "not a PNG" in (refusal(apid.png_dimensions, empty) or ""), True)
        junk = os.path.join(tmp, "junk.png")
        with open(junk, "wb") as f:
            f.write(b"this is not a png at all, but it is not empty either")
        check("a non-empty non-PNG is refused too -- a file appearing is not a capture",
              "not a PNG" in (refusal(apid.png_dimensions, junk) or ""), True)


def write_stub(path, body):
    """write an executable bash stub script"""
    with open(path, "w") as f:
        f.write("#!/bin/bash\n" + body)
    os.chmod(path, 0o755)


def screenshot_fixture(tmp, grim_body):
    """create a fake host with sway and grim"""
    cg = launcher_cgroup_tree(tmp)
    record = os.path.join(tmp, "cgroup-root-record")
    with open(record, "w") as f:
        f.write(cg + "\n")
    with open(os.path.join(tmp, "tree.json"), "w") as f:
        json.dump(SWAY_TREE, f)
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    write_stub(os.path.join(bindir, "swaymsg"), "cat %s\n" % os.path.join(tmp, "tree.json"))
    write_stub(os.path.join(bindir, "grim"), grim_body)
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    return record, os.path.join(tmp, "captures")


def test_screenshot_captures_this_instance_s_own_window():
    """test a capture of the instance window"""
    saved_path = os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            png = os.path.join(tmp, "src.png")
            with open(png, "wb") as f:
                f.write(one_by_one_png())
            record, captures = screenshot_fixture(
                tmp,
                'printf "%s\\n" "$@" > ' + os.path.join(tmp, "grim-argv") + '\n'
                'id -u > ' + os.path.join(tmp, "grim-uid") + '\n'
                'cat ' + png + '\n')
            saved_identity = apid.tool_identity
            apid.tool_identity = lambda runtime_dir, euid=None: {"user": os.getuid(), "group": os.getgid()}
            try:
                got = resolved(apid.capture_screenshot, 1, captures, record,
                               {"WAYLAND_DISPLAY": "wayland-0"})
            finally:
                apid.tool_identity = saved_identity
            argv_path = os.path.join(tmp, "grim-argv")
            grim_argv = (open(argv_path).read().split("\n")[:-1]
                         if os.path.exists(argv_path) else [])
            uid_path = os.path.join(tmp, "grim-uid")
            grim_uid = open(uid_path).read().strip() if os.path.exists(uid_path) else ""
        check("the capture names the file it wrote",
              os.path.basename(got.get("path", "")).startswith("instance-1-"), True)
        check("the capture is a real image, not an empty file", got.get("bytes", 0) > 0, True)
        check("the capture reports the region it took", got.get("region"),
              {"x": 960, "y": 0, "width": 960, "height": 1080})
        check("grim was asked for exactly that instance's own geometry",
              grim_argv[:2], ["-g", "960,0 960x1080"])
        check("grim writes its PNG to stdout, which the session's owner can", grim_argv[2:], ["-"])
        check("grim runs as the identity tool_identity() names", grim_uid, str(os.getuid()))
    finally:
        os.environ["PATH"] = saved_path


def test_screenshot_refuses_an_empty_capture():
    """test the refusal of an empty capture"""
    saved_path = os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            record, captures = screenshot_fixture(tmp, 'true\n')
            msg = refusal(apid.capture_screenshot, 1, captures, record,
                          {"WAYLAND_DISPLAY": "wayland-0"})
        check("an empty grim output is refused by name", "not a PNG" in (msg or ""), True)
    finally:
        os.environ["PATH"] = saved_path


def test_screenshot_refuses_when_the_instance_has_no_window():
    """test the refusal of a missing window"""
    saved_path = os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            record, captures = screenshot_fixture(tmp, 'true\n')
            leaf = os.path.join(tmp, "cgroup", "apps", "uid_10100", "pid_%d" % COMPOSER_PID)
            with open(os.path.join(leaf, "cgroup.procs"), "w") as f:
                f.write("9999\n")
            msg = refusal(apid.capture_screenshot, 1, captures, record,
                          {"WAYLAND_DISPLAY": "wayland-0"})
        check("no toplevel of this instance's own is refused by name, never a peer's window",
              "no toplevel" in (msg or ""), True)
    finally:
        os.environ["PATH"] = saved_path


def test_screenshot_refuses_a_failing_grim():
    """check that a failing grim capture is refused"""
    saved_path = os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            record, captures = screenshot_fixture(tmp, 'echo "grim: no outputs" >&2\nexit 1\n')
            msg = refusal(apid.capture_screenshot, 1, captures, record,
                          {"WAYLAND_DISPLAY": "wayland-0"})
        check("grim's own failure reaches the caller", "no outputs" in (msg or ""), True)
    finally:
        os.environ["PATH"] = saved_path


def test_sweep_captures_bounds_one_instance_without_touching_another():
    """test the capture sweep per instance"""
    with tempfile.TemporaryDirectory() as tmp:
        for ns in (10, 2, 300):
            open(os.path.join(tmp, "instance-1-%d.png" % ns), "w").close()
        open(os.path.join(tmp, "instance-10-5.png"), "w").close()
        open(os.path.join(tmp, "instance-2-5.png"), "w").close()
        apid.sweep_captures(1, tmp, keep=2)
        left = sorted(os.listdir(tmp))
    check("the oldest capture goes, by its own timestamp and not by name order",
          left, ["instance-1-10.png", "instance-1-300.png", "instance-10-5.png", "instance-2-5.png"])


def test_sweep_captures_survives_a_capture_dir_that_is_not_there():
    """check that sweeping a missing capture directory is not an error"""
    check("a sweep over a directory that does not exist is not an error",
          apid.sweep_captures(1, "/does/not/exist/captures"), None)


def unix_table(tmp, listening=(), connected=()):
    """write a fake /proc/net/unix table"""
    path = os.path.join(tmp, "proc_net_unix")
    rows = ["Num       RefCount Protocol Flags    Type St Inode Path"]
    rows += ["0000000000000000: 00000002 00000000 00010000 0001 01 %d %s" % (100 + i, p)
             for i, p in enumerate(listening)]
    rows += ["0000000000000000: 00000003 00000000 00000000 0001 03 %d %s" % (200 + i, p)
             for i, p in enumerate(connected)]
    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")
    return path


def find(env, run_user_root, table, session_env_path, inst_id=None, published_root="/run"):
    """call find_compositor on fixture tables"""
    return resolved(apid.find_compositor, env, run_user_root, inst_id, published_root, table,
                    session_env_path)


def find_refusal(env, run_user_root, table, session_env_path, inst_id=None, published_root="/run"):
    """return the refusal message from find_compositor"""
    return refusal(apid.find_compositor, env, run_user_root, inst_id, published_root, table,
                   session_env_path) or ""


def test_find_compositor():
    """test find_compositor against fixture tables"""
    with tempfile.TemporaryDirectory() as tmp:
        session = os.path.join(tmp, "1000")
        no_env = os.path.join(tmp, "no-session.env")
        check("no compositor socket anywhere is refused by name, never guessed",
              "no Wayland compositor socket" in find_refusal({}, tmp, unix_table(tmp), no_env), True)
        os.makedirs(session)
        open(os.path.join(session, "wayland-1"), "w").close()
        check("a socket file on disk the table does not list is not a session -- the glob is gone",
              "no Wayland compositor socket" in find_refusal({}, tmp, unix_table(tmp), no_env), True)
        table = unix_table(tmp, [os.path.join(session, "wayland-1"),
                                 os.path.join(session, "sway-ipc.1000.42.sock")])
        env = find({}, tmp, table, no_env)
        check("the session's own wayland socket", env.get("WAYLAND_DISPLAY"), "wayland-1")
        check("the session's own runtime dir", env.get("XDG_RUNTIME_DIR"), session)
        check("the session's own sway ipc socket",
              env.get("SWAYSOCK"), os.path.join(session, "sway-ipc.1000.42.sock"))
        check("a bound socket nothing listens on is not a session",
              "no Wayland compositor socket" in
              find_refusal({}, tmp, unix_table(tmp, connected=[os.path.join(session, "wayland-1")]),
                           no_env), True)
        other = os.path.join(tmp, "1001")
        table = unix_table(tmp, [os.path.join(session, "wayland-1"), os.path.join(other, "wayland-1")])
        check("two sessions are refused rather than one picked arbitrarily",
              "more than one" in find_refusal({}, tmp, table, no_env), True)
        check("a socket deeper than a runtime dir is not a session",
              "no Wayland compositor socket" in
              find_refusal({}, tmp, unix_table(tmp, [os.path.join(session, "sub", "wayland-1")]),
                           no_env), True)
    check("an inherited session is used as given, not rediscovered",
          find({"WAYLAND_DISPLAY": "wayland-9", "XDG_RUNTIME_DIR": "/run/user/0"},
               "/does/not/exist", "/does/not/exist/table", "/does/not/exist/env").get("WAYLAND_DISPLAY"),
          "wayland-9")


def test_find_compositor_reads_the_session_the_desktop_user_resolved():
    """test find_compositor with session.env"""
    with tempfile.TemporaryDirectory() as tmp:
        sock = os.path.join(tmp, "1000", "wayland-0")
        second = os.path.join(tmp, "1001", "wayland-1")
        senv = os.path.join(tmp, "session.env")
        with open(senv, "w") as f:
            f.write("XDG_RUNTIME_DIR=%s\nWAYLAND_DISPLAY=wayland-0\nRHIZO_WAYLAND_HOST_SOCKET=%s\n"
                    % (os.path.dirname(sock), sock))
        env = find({}, tmp, unix_table(tmp, [sock, second]), senv)
        check("session.env's socket settles a host with two sessions",
              (env.get("XDG_RUNTIME_DIR"), env.get("WAYLAND_DISPLAY")), (os.path.dirname(sock), "wayland-0"))
        env = find({}, tmp, unix_table(tmp, [second]), senv)
        check("a session.env naming a socket nothing listens on is passed over",
              env.get("XDG_RUNTIME_DIR"), os.path.dirname(second))


def test_find_compositor_honors_the_product_s_own_override():
    """test the RHIZO_WAYLAND_HOST_SOCKET override"""
    with tempfile.TemporaryDirectory() as tmp:
        no_env = os.path.join(tmp, "no-session.env")
        sock = os.path.join(tmp, "wayland-rhizo")
        open(sock, "w").close()
        table = unix_table(tmp)
        env = find({"RHIZO_WAYLAND_HOST_SOCKET": sock}, "/does/not/exist", table, no_env)
        check("the named socket wins over any session search", env.get("WAYLAND_DISPLAY"), "wayland-rhizo")
        check("its own directory becomes the runtime dir", env.get("XDG_RUNTIME_DIR"), tmp)
        hidden = os.path.join(tmp, "1000", "wayland-1")
        env = find({"RHIZO_WAYLAND_HOST_SOCKET": hidden}, "/does/not/exist", unix_table(tmp, [hidden]), no_env)
        check("a named socket root cannot see on disk counts when the kernel lists it",
              env.get("WAYLAND_DISPLAY"), "wayland-1")
        check("a named socket that is not there is refused by name, never fallen back from",
              "RHIZO_WAYLAND_HOST_SOCKET" in
              find_refusal({"RHIZO_WAYLAND_HOST_SOCKET": sock + "-gone"}, "/does/not/exist", table, no_env),
              True)


def test_find_compositor_tries_wayland_rhizo_only_after_a_real_desktop_s():
    """test the wayland-rhizo candidate order"""
    with tempfile.TemporaryDirectory() as tmp:
        no_env = os.path.join(tmp, "no-session.env")
        session = os.path.join(tmp, "0")
        rig = os.path.join(session, "wayland-rhizo")
        check("the rig's own socket name is found when it is the only one",
              find({}, tmp, unix_table(tmp, [rig]), no_env).get("WAYLAND_DISPLAY"), "wayland-rhizo")
        check("a real desktop's socket wins over the rig's own name",
              find({}, tmp, unix_table(tmp, [rig, os.path.join(session, "wayland-1")]),
                   no_env).get("WAYLAND_DISPLAY"), "wayland-1")


def test_find_compositor_falls_back_to_this_instance_s_own_published_socket():
    """test the per-instance published socket"""
    with tempfile.TemporaryDirectory() as tmp:
        no_env = os.path.join(tmp, "no-session.env")
        table = unix_table(tmp)
        empty = os.path.join(tmp, "no-sessions")
        os.makedirs(empty)
        for leaf in ("rhizo-wayland", "rhizo-wayland-5"):
            os.makedirs(os.path.join(tmp, leaf))
            open(os.path.join(tmp, leaf, "wayland-0"), "w").close()
        check("instance 0 finds the BARE per-instance directory, byte-identical as ever",
              find({}, empty, table, no_env, 0, tmp).get("XDG_RUNTIME_DIR"),
              os.path.join(tmp, "rhizo-wayland"))
        check("instance 5 finds its own, not instance 0's",
              find({}, empty, table, no_env, 5, tmp).get("XDG_RUNTIME_DIR"),
              os.path.join(tmp, "rhizo-wayland-5"))
        check("an instance with nothing published is refused by name, never given a peer's",
              "no Wayland compositor socket" in find_refusal({}, empty, table, no_env, 7, tmp), True)
        check("the refusal names every path it tried, so an operator can see where to look",
              os.path.join(tmp, "rhizo-wayland-7", "wayland-0") in
              find_refusal({}, empty, table, no_env, 7, tmp), True)


def test_listening_unix_paths():
    """check the listening unix socket paths"""
    with tempfile.TemporaryDirectory() as tmp:
        table = unix_table(tmp, ["/run/user/1000/wayland-0"], ["/run/user/1000/pipewire-0"])
        with open(table, "a") as f:
            f.write("0000000000000000: 00000002 00000000 00010000 0001 01 300 @abstract\n")
            f.write("0000000000000000: 00000002 00000000 00010000 0001 01 301\n")
        check("only listening sockets bound to a path are read",
              apid.listening_unix_paths(table), {"/run/user/1000/wayland-0"})
    check("an unreadable table is refused by name, never read as no sockets",
          "cannot read" in (refusal(apid.listening_unix_paths, "/does/not/exist") or ""), True)


def test_tool_identity():
    """check which identity the tools run as"""
    with tempfile.TemporaryDirectory() as tmp:
        mine = os.stat(tmp)
        want = {} if mine.st_uid == 0 else {"user": mine.st_uid, "group": mine.st_gid, "extra_groups": []}
        check("root runs the tools as the runtime dir's owner", apid.tool_identity(tmp, euid=0), want)
    check("a root-owned session needs no switch", apid.tool_identity("/", euid=0), {})
    check("a caller that is not root switches nothing", apid.tool_identity("/", euid=1000), {})
    check("no runtime dir, no switch", apid.tool_identity(None, euid=0), {})
    check("a runtime dir that is gone is refused by name",
          "cannot stat" in (refusal(apid.tool_identity, "/does/not/exist", 0) or ""), True)


def control_fixture(tmp, reply):
    """create a control FIFO with a reply thread"""
    ctl_dir = os.path.join(tmp, "data", "rhizo_control")
    os.makedirs(ctl_dir)
    ctl = os.path.join(ctl_dir, "control")
    out = os.path.join(ctl_dir, "control.out")
    os.mkfifo(ctl)
    with open(out, "w") as f:
        f.write("display list 1(960x1080,p=3,v=1)\n")
    read_fd = os.open(ctl, os.O_RDONLY | os.O_NONBLOCK)
    seen = []

    def composer():
        """read a command from the control FIFO and reply"""
        deadline = time.monotonic() + 5
        buf = b""
        while time.monotonic() < deadline and b"\n" not in buf:
            try:
                buf += os.read(read_fd, 4096)
            except BlockingIOError:
                time.sleep(0.01)
        seen.append(buf.decode().strip())
        if reply is not None:
            with open(out, "a") as f:
                f.write(reply + "\n")

    t = threading.Thread(target=composer)
    t.start()
    return seen, t, read_fd


def test_input_injects_a_touch_on_this_instance_s_own_composer():
    """check that an input event reaches the instance's composer"""
    with tempfile.TemporaryDirectory() as tmp:
        seen, t, read_fd = control_fixture(tmp, "inject down id=1")
        try:
            got = apid.inject_touch(1, ["down", "1", "480", "540"], run_root=tmp, timeout=5)
        finally:
            t.join()
            os.close(read_fd)
    check("the composer received this instance's own inject line",
          seen, ["inject touch down 1 480 540"])
    check("the composer's own reply is relayed", got["reply"], "inject down id=1")


def test_input_up_takes_no_coordinates():
    """check that an up event is sent without coordinates"""
    with tempfile.TemporaryDirectory() as tmp:
        seen, t, read_fd = control_fixture(tmp, "inject up id=1")
        try:
            apid.inject_touch(1, ["up", "1"], run_root=tmp, timeout=5)
        finally:
            t.join()
            os.close(read_fd)
    check("an up carries only the display", seen, ["inject touch up 1"])


def test_input_relays_the_composer_s_own_refusal():
    """check that the composer's refusal is relayed to the caller"""
    with tempfile.TemporaryDirectory() as tmp:
        _seen, t, read_fd = control_fixture(tmp, "inject-failed id=4 reason=unknown-display")
        try:
            msg = refusal(apid.inject_touch, 1, ["down", "4", "1", "2"], tmp, 5)
        finally:
            t.join()
            os.close(read_fd)
    check("the composer's own reason reaches the caller, not a generic failure",
          "unknown-display" in (msg or ""), True)


def test_input_times_out_by_name_on_a_silent_composer():
    """check that a silent composer is refused by timeout"""
    with tempfile.TemporaryDirectory() as tmp:
        _seen, t, read_fd = control_fixture(tmp, None)
        try:
            msg = refusal(apid.inject_touch, 1, ["down", "1", "5", "6"], tmp, 0.5)
        finally:
            t.join()
            os.close(read_fd)
    check("a composer that never answers fails by name, never returns success",
          "did not answer" in (msg or ""), True)


def test_input_never_reads_a_reply_that_predates_its_own_command():
    """test input against an old control.out reply"""
    with tempfile.TemporaryDirectory() as tmp:
        ctl_dir = os.path.join(tmp, "data", "rhizo_control")
        os.makedirs(ctl_dir)
        os.mkfifo(os.path.join(ctl_dir, "control"))
        with open(os.path.join(ctl_dir, "control.out"), "w") as f:
            f.write("inject down id=1\n")
        read_fd = os.open(os.path.join(ctl_dir, "control"), os.O_RDONLY | os.O_NONBLOCK)
        try:
            msg = refusal(apid.inject_touch, 1, ["down", "1", "5", "6"], tmp, 0.5)
        finally:
            os.close(read_fd)
    check("an earlier 'inject down id=1' already in control.out is not this command's reply",
          "did not answer" in (msg or ""), True)


def test_input_grammar():
    """check the grammar of the input verb"""
    check("input needs a sub-verb", refusal(apid.inject_touch, 1, []) is None, False)
    check("an unknown sub-verb is refused by name",
          "swipe" in (refusal(apid.inject_touch, 1, ["swipe", "1", "2", "3"]) or ""), True)
    check("down needs a display and both coordinates",
          refusal(apid.inject_touch, 1, ["down", "1", "480"]) is None, False)
    check("a non-numeric coordinate is refused",
          refusal(apid.inject_touch, 1, ["down", "1", "x", "5"]) is None, False)


def test_input_refuses_a_sandbox_that_is_not_running():
    """check that input is refused when the sandbox is not running"""
    with tempfile.TemporaryDirectory() as tmp:
        msg = refusal(apid.inject_touch, 1, ["down", "1", "5", "6"], tmp, 0.5)
    check("no control FIFO under the instance's run root is refused by name",
          "control" in (msg or ""), True)


def test_authorize_peer():
    """test the peer group authorization"""
    def lookup():
        """return a fixed group lookup with a member"""
        return 2001, ["alice"]
    users = {1000: "alice", 1001: "mallory"}
    check("a member of group rhizo is allowed",
          apid.authorize_peer(1000, 4000, lookup, users.get), True)
    check("a peer whose PRIMARY group is rhizo is allowed even if not in the member list",
          apid.authorize_peer(1001, 2001, lookup, users.get), True)
    check("root is allowed -- it owns the socket and the unit runs as root",
          apid.authorize_peer(0, 0, lookup, users.get), True)
    check("a peer in neither is refused by name",
          "mallory" in (refusal(apid.authorize_peer, 1001, 4000, lookup, users.get) or ""), True)
    check("a uid with no passwd entry is refused, never allowed by default",
          refusal(apid.authorize_peer, 1234, 4000, lookup, users.get) is None, False)

    def no_group():
        """raise as if the rhizo group did not exist"""
        raise KeyError("rhizo")
    check("a host with no rhizo group refuses every peer rather than allowing one",
          refusal(apid.authorize_peer, 1000, 4000, no_group, users.get) is None, False)


def serve_one(request, group_lookup=None, uid_name=None):
    """run main over a socket and return output"""
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "api.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        conn, _ = srv.accept()
        client.sendall(request)
        saved = os.dup(0)
        try:
            os.dup2(conn.fileno(), 0)
            rc = apid.main(group_lookup=group_lookup, uid_name=uid_name)
        finally:
            os.dup2(saved, 0)
            os.close(saved)
        conn.close()
        chunks = []
        while True:
            data = client.recv(65536)
            if not data:
                break
            chunks.append(data)
        client.close()
        srv.close()
    return rc, b"".join(chunks)


def cli_stub(tmp):
    """write a stub rhizo CLI on PATH"""
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    stub = os.path.join(bindir, "rhizo")
    write_stub(stub,
               'printf "%s\\n" "$@" > ' + os.path.join(tmp, "argv") + '\n'
               'echo "$RHIZO_SANDBOX_ID" > ' + os.path.join(tmp, "sandbox-id") + '\n'
               'echo first out line\n'
               'echo the error line >&2\n'
               'printf "a trailing line with no newline"\n'
               'exit 7\n')
    os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
    return stub


def mine():
    """return the gid and an empty member list"""
    return os.getgid(), []


def test_socket_relays_a_cli_verb_line_by_line():
    """check that the socket relays a CLI verb output line by line"""
    saved_cli, saved_path = apid.CLI, os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            apid.CLI = cli_stub(tmp)
            rc, out = serve_one(json.dumps({"v": 1, "verb": "set", "id": 3,
                                            "args": ["battery", "55", "charging"]}).encode() + b"\n",
                                group_lookup=mine, uid_name=lambda uid: "self")
            argv = open(os.path.join(tmp, "argv")).read().split("\n")[:-1]
            sandbox_id = open(os.path.join(tmp, "sandbox-id")).read().strip()
        lines = out.decode().splitlines()
        check("main() returns 0 -- a verb's own failure is the client's to read", rc, 0)
        check("the CLI saw the -i selector and the device verb",
              argv, ["-i", "3", "device", "set", "battery", "55", "charging"])
        check("the CLI also ran scoped to that instance", sandbox_id, "3")
        check("stdout is relayed unprefixed", "first out line" in lines, True)
        check("stderr is relayed with its own prefix", "E the error line" in lines, True)
        check("a final line with no trailing newline is still relayed",
              "a trailing line with no newline" in lines, True)
        check("the child's exit status is the last thing the client reads",
              lines[-1], "RHIZO_API_RC=7")
    finally:
        apid.CLI, os.environ["PATH"] = saved_cli, saved_path


def test_socket_refuses_a_peer_outside_group_rhizo():
    """test refusal of a peer outside group rhizo"""
    saved_cli, saved_path = apid.CLI, os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            apid.CLI = cli_stub(tmp)
            rc, out = serve_one(json.dumps({"v": 1, "verb": "set", "id": 3,
                                            "args": ["battery", "55", "charging"]}).encode() + b"\n",
                                group_lookup=lambda: (999999, ["someone-else"]),
                                uid_name=lambda uid: "mallory")
            ran = os.path.exists(os.path.join(tmp, "argv"))
        answer = json.loads(out.decode().splitlines()[0])
        if os.geteuid() == 0:
            check("a root peer is allowed by its own rule, whatever the group says", ran, True)
        else:
            check("the refusal names the peer", "mallory" in answer.get("error", ""), True)
            check("nothing ran as root for an unauthorized peer", ran, False)
        check("main() still returns 0, having answered the client", rc, 0)
    finally:
        apid.CLI, os.environ["PATH"] = saved_cli, saved_path


def test_socket_answers_a_local_verb_without_running_anything():
    """check that the socket answers a local verb without running the CLI"""
    saved_cli, saved_path, saved_log_dir = apid.CLI, os.environ["PATH"], apid.LOG_DIR
    try:
        with tempfile.TemporaryDirectory() as tmp:
            apid.CLI = cli_stub(tmp)
            with open(os.path.join(tmp, "boot-4.log"), "w") as f:
                f.write("alpha\nbeta\n")
            apid.LOG_DIR = tmp
            rc, out = serve_one(json.dumps({"v": 1, "verb": "logs", "id": 4}).encode() + b"\n",
                                group_lookup=mine, uid_name=lambda uid: "self")
            ran = os.path.exists(os.path.join(tmp, "argv"))
        check("logs answers from the instance's own boot log",
              json.loads(out.decode().splitlines()[0]), {"lines": ["alpha", "beta"]})
        check("a locally-served verb execs no CLI at all", ran, False)
        check("main() returns 0", rc, 0)
    finally:
        apid.CLI, os.environ["PATH"], apid.LOG_DIR = saved_cli, saved_path, saved_log_dir


def test_socket_refuses_a_malformed_request_before_running_anything():
    """check that a malformed request is refused before anything runs"""
    saved_cli, saved_path = apid.CLI, os.environ["PATH"]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            apid.CLI = cli_stub(tmp)
            rc, out = serve_one(b"{not json}\n", group_lookup=mine, uid_name=lambda uid: "self")
            ran = os.path.exists(os.path.join(tmp, "argv"))
        check("a non-JSON request is answered with a structured error",
              "error" in json.loads(out.decode().splitlines()[0]), True)
        check("nothing ran for a request that never parsed", ran, False)
        check("main() returns 0", rc, 0)
    finally:
        apid.CLI, os.environ["PATH"] = saved_cli, saved_path



def serve_bounded(request, budget, group_lookup=None, uid_name=None,
                  buf_bytes=None, drain=True, dribble=False):
    """run main over a socket in a child"""
    tmp = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp, "api.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if buf_bytes:
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, buf_bytes)
        srv.bind(path)
        srv.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if buf_bytes:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, buf_bytes)
        client.connect(path)
        conn, _ = srv.accept()
        if request:
            client.sendall(request)
        watch_r, watch_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            rc = 70
            try:
                os.close(watch_r)
                client.close()
                srv.close()
                os.dup2(conn.fileno(), 0)
                rc = apid.main(group_lookup=group_lookup, uid_name=uid_name)
            except BaseException:
                rc = 71
            finally:
                os._exit(rc if isinstance(rc, int) and 0 <= rc < 126 else 72)
        os.close(watch_w)
        feeder = None
        if dribble:
            stop = threading.Event()

            def feed():
                """send bytes to the peer until stopped"""
                while not stop.wait(0.05):
                    try:
                        client.sendall(b"x")
                    except OSError:
                        return
            feeder = (threading.Thread(target=feed, daemon=True), stop)
            feeder[0].start()
        finished = bool(select.select([watch_r], [], [], budget)[0])
        if feeder is not None:
            feeder[1].set()
            feeder[0].join(5)
        if not finished:
            os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        os.close(watch_r)
        rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
        conn.close()
        out = b""
        if drain and finished:
            client.settimeout(5)
            try:
                while True:
                    data = client.recv(65536)
                    if not data:
                        break
                    out += data
            except (socket.timeout, OSError):
                pass
        client.close()
        srv.close()
        return finished, rc, out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_a_silent_peer_does_not_hold_the_connection():
    """check that a silent peer does not hold the connection"""
    saved = apid.REQUEST_READ_TIMEOUT_S
    try:
        apid.REQUEST_READ_TIMEOUT_S = 0.5
        finished, rc, out = serve_bounded(b"", 20, group_lookup=mine,
                                          uid_name=lambda uid: "self")
        check("a peer that sends nothing is let go of, not waited on forever", finished, True)
        check("main() still returns 0 -- the peer is told, not crashed on", rc, 0)
        error = json.loads(out.decode().splitlines()[0])["error"] if finished and out else ""
        check("the refusal names the read budget it blew", "no complete request line within" in error, True)
    finally:
        apid.REQUEST_READ_TIMEOUT_S = saved


def test_a_dribbling_peer_cannot_extend_the_read_budget():
    """check that a peer sending slowly cannot extend the read budget"""
    saved = apid.REQUEST_READ_TIMEOUT_S
    try:
        apid.REQUEST_READ_TIMEOUT_S = 1.0
        finished, rc, out = serve_bounded(b"", 20, group_lookup=mine,
                                          uid_name=lambda uid: "self", dribble=True)
        check("a peer dribbling bytes with no newline is cut off at the budget", finished, True)
        check("main() returns 0 -- the peer is told why", rc, 0)
        error = json.loads(out.decode().splitlines()[0])["error"] if finished and out else ""
        check("the refusal names the read budget the dribble blew",
              "no complete request line within" in error, True)
        check("and says how far the request line got", "byte(s) read" in error, True)
    finally:
        apid.REQUEST_READ_TIMEOUT_S = saved


def test_a_peer_that_stops_reading_does_not_hold_the_connection():
    """test the drop of a non-reading peer"""
    saved_cli, saved_path, saved_reply = apid.CLI, os.environ["PATH"], apid.REPLY_TIMEOUT_S
    try:
        with tempfile.TemporaryDirectory() as tmp:
            bindir = os.path.join(tmp, "bin")
            os.makedirs(bindir)
            apid.CLI = os.path.join(bindir, "rhizo")
            write_stub(apid.CLI, 'for i in $(seq 1 400); do printf "%0500d\\n" "$i"; done\n')
            os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
            apid.REPLY_TIMEOUT_S = 1.0
            request = json.dumps({"v": 1, "verb": "allocate"}).encode() + b"\n"
            finished, rc, _ = serve_bounded(request, 20, group_lookup=mine,
                                            uid_name=lambda uid: "self",
                                            buf_bytes=2048, drain=False)
        check("a peer that stops reading its own reply is dropped", finished, True)
        check("and the connection reports that it was dropped", rc, 1)
    finally:
        apid.CLI, os.environ["PATH"], apid.REPLY_TIMEOUT_S = saved_cli, saved_path, saved_reply


def test_a_cli_verb_that_never_returns_is_killed():
    """check that a CLI verb that never returns is killed"""
    saved_cli, saved_path, saved_max = apid.CLI, os.environ["PATH"], apid.CLI_MAX_S
    try:
        with tempfile.TemporaryDirectory() as tmp:
            bindir = os.path.join(tmp, "bin")
            os.makedirs(bindir)
            apid.CLI = os.path.join(bindir, "rhizo")
            write_stub(apid.CLI, 'echo started\nsleep 120\n')
            os.environ["PATH"] = bindir + os.pathsep + os.environ["PATH"]
            apid.CLI_MAX_S = 1.0
            request = json.dumps({"v": 1, "verb": "allocate"}).encode() + b"\n"
            finished, rc, out = serve_bounded(request, 30, group_lookup=mine,
                                              uid_name=lambda uid: "self")
        lines = out.decode().splitlines()
        check("a CLI verb that never returns does not hold the connection", finished, True)
        check("main() still returns 0 -- the client reads the reason", rc, 0)
        check("the reason names the ceiling the verb blew",
              any(l.startswith("E ") and "exceeded 1s and was killed" in l for l in lines), True)
        check("and the client's last line is a status, not silence",
              lines[-1] if lines else "", "RHIZO_API_RC=124")
    finally:
        apid.CLI, os.environ["PATH"], apid.CLI_MAX_S = saved_cli, saved_path, saved_max


for fn in (
    test_parse_request_envelope,
    test_parse_request_id_grammar,
    test_parse_request_args_grammar,
    test_build_plan_allocate,
    test_build_plan_release,
    test_build_plan_install,
    test_build_plan_launch,
    test_build_plan_verb_takes_no_id,
    test_every_verb_has_something_behind_it,
    test_every_verb_refuses_only_for_its_own_reasons,
    test_instance_paths_id_zero_is_unchanged,
    test_build_plan_set,
    test_build_plan_set_grammar,
    test_window_rect_for_pids,
    test_instance_pids_reads_the_whole_recorded_cgroup_tree,
    test_instance_pids_tolerates_a_cgroup_that_vanished_mid_walk,
    test_instance_pids_is_the_same_read_at_id_zero,
    test_png_dimensions,
    test_screenshot_captures_this_instance_s_own_window,
    test_screenshot_refuses_an_empty_capture,
    test_screenshot_refuses_when_the_instance_has_no_window,
    test_screenshot_refuses_a_failing_grim,
    test_sweep_captures_bounds_one_instance_without_touching_another,
    test_sweep_captures_survives_a_capture_dir_that_is_not_there,
    test_find_compositor,
    test_find_compositor_reads_the_session_the_desktop_user_resolved,
    test_listening_unix_paths,
    test_tool_identity,
    test_find_compositor_honors_the_product_s_own_override,
    test_find_compositor_tries_wayland_rhizo_only_after_a_real_desktop_s,
    test_find_compositor_falls_back_to_this_instance_s_own_published_socket,
    test_input_injects_a_touch_on_this_instance_s_own_composer,
    test_input_up_takes_no_coordinates,
    test_input_relays_the_composer_s_own_refusal,
    test_input_times_out_by_name_on_a_silent_composer,
    test_input_never_reads_a_reply_that_predates_its_own_command,
    test_input_grammar,
    test_input_refuses_a_sandbox_that_is_not_running,
    test_authorize_peer,
    test_socket_relays_a_cli_verb_line_by_line,
    test_socket_refuses_a_peer_outside_group_rhizo,
    test_socket_answers_a_local_verb_without_running_anything,
    test_socket_refuses_a_malformed_request_before_running_anything,
    test_instances_snapshot,
    test_instances_snapshot_missing_pool_members_is_not_an_error,
    test_instances_snapshot_list_units_failure_is_refused,
    test_instances_snapshot_ignores_unrelated_units,
    test_tail_logs,
    test_tail_logs_missing_file,
    test_a_silent_peer_does_not_hold_the_connection,
    test_a_dribbling_peer_cannot_extend_the_read_budget,
    test_a_peer_that_stops_reading_does_not_hold_the_connection,
    test_a_cli_verb_that_never_returns_is_killed,
):
    fn()

print("%d checks run, %d failed" % (len(checked), len(failures)))
sys.exit(1 if failures else 0)
