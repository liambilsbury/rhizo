#!/usr/bin/env python3
import inspect
import os
import signal
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

import boot as launcher3  # noqa: E402


def _write_entry(handoff_dir, instance_id, pid1, entry):
    """write an entry file for an instance"""
    with open(os.path.join(handoff_dir, str(instance_id)), "wb") as f:
        f.write(launcher3.handoff_wire_format(pid1, entry))


def _write_temp_dotfile(handoff_dir, instance_id, pid):
    """write an empty temporary dotfile"""
    with open(os.path.join(handoff_dir, f".{instance_id}.{pid}.tmp"), "w") as f:
        f.write("")


def test_publish_survives_its_directory_path_going_away(tmp):
    """test hand_off_to_supervisor with a renamed directory"""
    handoff = os.path.join(tmp, "handoff.d")
    os.mkdir(handoff)
    logged = []
    saved_dir, saved_kmsg = launcher3.HANDOFF_DIR, launcher3.kmsg
    saved_usr1 = signal.getsignal(signal.SIGUSR1)
    launcher3.HANDOFF_DIR, launcher3.kmsg = handoff, logged.append
    signaled = []
    signal.signal(signal.SIGUSR1, lambda *_: signaled.append(sorted(os.listdir(moved))))
    try:
        fd, dir_fd, tmp_name = launcher3.open_handoff_entry(0)
        assert fd >= 0 and dir_fd >= 0, logged
        assert not os.path.isabs(tmp_name), \
            "a name resolved against the process's own root cannot survive the pivot: %r" % tmp_name
        moved = os.path.join(tmp, "pivoted-away")
        os.rename(handoff, moved)
        assert not os.path.exists(handoff), handoff
        ok = launcher3.hand_off_to_supervisor(os.getpid(), fd, dir_fd, tmp_name,
                                              4162, "second_stage", 0)
        assert ok, logged
        assert signaled == [["0"]], \
            "the supervisor was signaled %d time(s), seeing %r" % (len(signaled), signaled)
        try:
            os.fstat(dir_fd)
        except OSError:
            pass
        else:
            assert False, "hand_off_to_supervisor left its dir_fd open"
    finally:
        signal.signal(signal.SIGUSR1, saved_usr1)
        launcher3.HANDOFF_DIR, launcher3.kmsg = saved_dir, saved_kmsg
    assert sorted(os.listdir(moved)) == ["0"], os.listdir(moved)
    with open(os.path.join(moved, "0"), "rb") as f:
        assert f.read() == launcher3.handoff_wire_format(4162, "second_stage")
    claimed = launcher3.drain_handoffs(moved, active_ids=set(), pid_is_live=lambda p, log: True)
    assert claimed == [(0, 4162, "second_stage")], claimed
    src = inspect.getsource(launcher3.hand_off_to_supervisor)
    assert "src_dir_fd=" in src and "dst_dir_fd=" in src, src
    for path_route in ("HANDOFF_DIR", "/proc/self/fd", "os.readlink", "os.path.join"):
        assert path_route not in src, \
            "the publish resolves a path (%s)" % path_route


def test_failed_signal_withdraws_the_published_entry(tmp):
    """test that an unsignaled supervisor leaves no entry to claim"""
    gone = os.fork()
    if gone == 0:
        os._exit(0)
    os.waitpid(gone, 0)
    saved_dir, saved_kmsg = launcher3.HANDOFF_DIR, launcher3.kmsg
    launcher3.HANDOFF_DIR, launcher3.kmsg = tmp, lambda m: None
    try:
        fd, dir_fd, tmp_name = launcher3.open_handoff_entry(3)
        why = []
        ok = launcher3.hand_off_to_supervisor(gone, fd, dir_fd, tmp_name, 4162, "selinux_setup", 3, why=why)
    finally:
        launcher3.HANDOFF_DIR, launcher3.kmsg = saved_dir, saved_kmsg
    assert not ok and why == ["signal-ESRCH"], (ok, why)
    assert os.listdir(tmp) == [], "a handoff no supervisor was told of stays claimable: %r" % os.listdir(tmp)


def test_two_coalesced_entries_drained_in_one_wake(tmp):
    """test draining two entries in a wake"""
    _write_entry(tmp, 1, 111, "second_stage")
    _write_entry(tmp, 2, 222, "second_stage")
    live = {111, 222}
    claimed = launcher3.drain_handoffs(tmp, active_ids=set(), pid_is_live=lambda p, log: p in live)
    got = {(i, p, e) for i, p, e in claimed}
    assert got == {(1, 111, "second_stage"), (2, 222, "second_stage")}, got
    assert os.listdir(tmp) == [], os.listdir(tmp)


def test_active_id_left_untouched(tmp):
    """test drain_handoffs skips ids in active_ids"""
    _write_entry(tmp, 3, 333, "second_stage")
    _write_entry(tmp, 4, 444, "second_stage")
    claimed = launcher3.drain_handoffs(tmp, active_ids={3}, pid_is_live=lambda p, log: True)
    assert claimed == [(4, 444, "second_stage")], claimed
    assert os.path.exists(os.path.join(tmp, "3")), "active id's entry was claimed"
    assert not os.path.exists(os.path.join(tmp, "4")), "id 4's entry was not claimed"


def test_dead_pid1_unlinked_and_skipped(tmp):
    """test drain_handoffs unlinks entries of exited pids"""
    _write_entry(tmp, 5, 555, "second_stage")
    logged = []
    claimed = launcher3.drain_handoffs(tmp, active_ids=set(),
                                        pid_is_live=lambda p, log: False, log=logged.append)
    assert claimed == [], claimed
    assert not os.path.exists(os.path.join(tmp, "5")), "a dead entry must still be unlinked"
    assert any("555" in m and "not live" in m for m in logged), logged


def test_temp_dotfile_ignored(tmp):
    """test drain_handoffs skips temporary dotfiles"""
    _write_temp_dotfile(tmp, 6, 12345)
    _write_entry(tmp, 7, 777, "second_stage")
    claimed = launcher3.drain_handoffs(tmp, active_ids=set(), pid_is_live=lambda p, log: True)
    assert claimed == [(7, 777, "second_stage")], claimed
    assert os.path.exists(os.path.join(tmp, ".6.12345.tmp")), "a dotfile must never be unlinked"


def test_single_entry_restart_shaped_wake_still_served(tmp):
    """test draining an entry in a wake"""
    _write_entry(tmp, 0, 999, "second_stage")
    claimed = launcher3.drain_handoffs(tmp, active_ids=set(), pid_is_live=lambda p, log: True)
    assert claimed == [(0, 999, "second_stage")], claimed


def test_malformed_and_unreadable_entries_are_not_fatal(tmp):
    """test drain_handoffs logs malformed entries"""
    with open(os.path.join(tmp, "not-a-number"), "w") as f:
        f.write("999 second_stage")
    with open(os.path.join(tmp, "8"), "w") as f:
        f.write("not-two-fields")
    _write_entry(tmp, 9, 888, "second_stage")
    logged = []
    claimed = launcher3.drain_handoffs(tmp, active_ids=set(),
                                        pid_is_live=lambda p, log: True, log=logged.append)
    assert claimed == [(9, 888, "second_stage")], claimed
    assert any("not-a-number" in m for m in logged), logged
    assert any("malformed" in m for m in logged), logged


def test_unlink_failure_is_logged_not_swallowed(tmp):
    """test drain_handoffs logs a failed unlink"""
    if os.geteuid() == 0:
        raise AssertionError("this case needs a non-root runner to make unlink fail")
    handoff = os.path.join(tmp, "handoff.d")
    os.mkdir(handoff)
    _write_entry(handoff, 0, 4162, "second_stage")
    logged = []
    os.chmod(handoff, 0o500)
    try:
        claimed = launcher3.drain_handoffs(handoff, active_ids=set(),
                                           pid_is_live=lambda p, log: True, log=logged.append)
    finally:
        os.chmod(handoff, 0o700)
    assert claimed == [(0, 4162, "second_stage")], claimed
    assert os.path.exists(os.path.join(handoff, "0")), "the entry vanished"
    assert any("claimed but not unlinked" in m for m in logged), logged


def test_kernel_domain_launcher_reexecs_only_after_the_phase(tmp):
    """test launcher_must_reexec over its inputs"""
    must = launcher3.launcher_must_reexec
    assert must(True, "u:r:kernel:s0", False), "kernel + loaded + first pass must re-exec"
    assert must(True, "kernel", False), "the bare pre-load SID spelling counts as kernel too"
    assert not must(True, "u:r:rhizo_host:s0", False), "a rhizo_host launcher is already where it needs to be"
    assert not must(False, "kernel", False), "the first instance owns the phase and never re-execs"
    assert not must(True, "u:r:kernel:s0", True), "a second pass still in kernel continues and fails loudly, never loops"


def test_literal_cgroup_root_only_for_the_recording_supervisor_or_its_restart(tmp):
    """test keeps_literal_cgroup_root over its inputs"""
    keeps = launcher3.keeps_literal_cgroup_root
    assert keeps(True, "u:r:kernel:s0", False), "the first instance on a host boot, as kernel, makes the literal root"
    assert keeps(True, "kernel", False), "the bare pre-load SID spelling counts as kernel"
    assert keeps(True, "u:r:rhizo_host:s0", True), "instance 0's restart finds its root and keeps it, unchanged"
    assert not keeps(True, "u:r:rhizo_host:s0", False), "an instance above 0, first boot as rhizo_host, cannot make one and must not try"
    assert not keeps(False, "u:r:kernel:s0", False), "without resident dispatch the unit's delegated cgroup is the rule already"


def _assert_supervisor_order(src):
    """assert the order of the supervisor source steps"""
    first_pass = src.index("run_sandbox_or_refuse(entry)")
    move = src.index("park_supervisor_in_host_cgroup(")
    park = src.index("parked sigblk=")
    drain = src.index("drain_handoffs(")
    assert first_pass < move < park, "the move must follow the first stack and precede the first park"
    assert park < drain, "the first park must precede the first drain"


def test_supervisor_parks_outside_every_instance_tree(tmp):
    """test the supervisor cgroup path against instance trees"""
    cg = launcher3.SUPERVISOR_CGROUP
    assert cg.startswith("/sys/fs/cgroup/") and cg.count("/") == 4, "a direct child of the cgroup root: %r" % cg
    for n in (0, 1, 2, 9):
        root = launcher3.core.paths_for(n).cgroup_root.rstrip("/")
        assert cg != root and not cg.startswith(root + "/"), (cg, root)
        assert not root.startswith(cg + "/"), (cg, root)
    src = inspect.getsource(launcher3.run_kernel_domain_supervisor)
    _assert_supervisor_order(src)


def test_supervisor_order_check_catches_a_defect(tmp):
    """test _assert_supervisor_order rejects an early drain"""
    good = ("run_sandbox_or_refuse(entry)\n...\npark_supervisor_in_host_cgroup(x)\n...\nparked sigblk=y\n...\n"
            "drain_handoffs(z)\n")
    _assert_supervisor_order(good)
    bad = ("run_sandbox_or_refuse(entry)\n...\ndrain_handoffs(z)\n...\npark_supervisor_in_host_cgroup(x)\n...\n"
           "parked sigblk=y\n")
    try:
        _assert_supervisor_order(bad)
    except AssertionError as e:
        assert "first park must precede the first drain" in str(e), e
    else:
        assert False, "a drain planted before the first park was not flagged"


def test_missing_directory_returns_empty_not_raise(tmp):
    """test drain_handoffs on a missing directory"""
    missing = os.path.join(tmp, "does-not-exist")
    logged = []
    claimed = launcher3.drain_handoffs(missing, active_ids=set(), log=logged.append)
    assert claimed == [], claimed
    assert any("unreadable" in m for m in logged), logged



def _cgroup_fixture(tmp, ids=(0, 1, 2), leaf=True):
    """build a fake cgroup2 tree and root records"""
    fs = os.path.join(tmp, "sys", "fs", "cgroup")
    records = {}
    for i in ids:
        root = os.path.join(fs, "rhizo" if i == 0 else "rhizo-%d" % i)
        os.makedirs(root, exist_ok=True)
        open(os.path.join(root, "cgroup.procs"), "w").close()
        if leaf:
            os.makedirs(os.path.join(root, launcher3.CGROUP_INIT_LEAF))
            open(os.path.join(root, launcher3.CGROUP_INIT_LEAF, "cgroup.procs"), "w").close()
        record = os.path.join(tmp, "cgroup-root-%d" % i)
        with open(record, "w") as f:
            f.write(root)
        records[i] = (root, record)
    return fs, records


def _leaf_procs(root):
    """return the pids in the init leaf cgroup under a root"""
    with open(os.path.join(root, launcher3.CGROUP_INIT_LEAF, "cgroup.procs")) as f:
        return f.read().strip()


def test_joined_init_lands_in_the_instance_its_handoff_names(tmp):
    """test the init pid joins its instance's cgroup"""
    fs, rec = _cgroup_fixture(tmp)
    logged = []
    ok = launcher3.join_instance_init_cgroup(1, 4242, logged.append,
                                             root_file=rec[1][1], cgroup_fs=fs)
    assert ok, logged
    assert _leaf_procs(rec[1][0]) == "4242", _leaf_procs(rec[1][0])
    assert _leaf_procs(rec[0][0]) == "", _leaf_procs(rec[0][0])
    assert _leaf_procs(rec[2][0]) == "", _leaf_procs(rec[2][0])
    with open(os.path.join(rec[1][0], "cgroup.procs")) as f:
        assert f.read() == "", "the root took the pid the leaf should have"


def test_instance_0_leaf_is_the_one_its_own_boot_already_creates(tmp):
    """test the instance 0 init cgroup path"""
    assert launcher3.instance_init_cgroup("/sys/fs/cgroup/rhizo") == \
        "/sys/fs/cgroup/rhizo/init"
    fs, rec = _cgroup_fixture(tmp, ids=(0,))
    logged = []
    assert launcher3.join_instance_init_cgroup(0, 11, logged.append,
                                               root_file=rec[0][1], cgroup_fs=fs), logged
    assert _leaf_procs(rec[0][0]) == "11", _leaf_procs(rec[0][0])


def test_unit_delegated_record_is_honored_not_a_derived_path(tmp):
    """test the cgroup root comes from the record"""
    fs = os.path.join(tmp, "sys", "fs", "cgroup")
    root = os.path.join(fs, "system.slice", "androidd@1.service", "android")
    os.makedirs(os.path.join(root, launcher3.CGROUP_INIT_LEAF))
    open(os.path.join(root, launcher3.CGROUP_INIT_LEAF, "cgroup.procs"), "w").close()
    record = os.path.join(tmp, "cgroup-root-1")
    with open(record, "w") as f:
        f.write(root + "\n")
    logged = []
    assert launcher3.join_instance_init_cgroup(1, 33, logged.append,
                                               root_file=record, cgroup_fs=fs), logged
    assert _leaf_procs(root) == "33", _leaf_procs(root)
    assert not os.path.exists(os.path.join(fs, "rhizo-1")), \
        "the id-derived path exists"


def test_record_outside_the_cgroup_filesystem_is_refused(tmp):
    """test a record outside the cgroup filesystem fails"""
    fs, rec = _cgroup_fixture(tmp, ids=(1,))
    elsewhere = os.path.join(tmp, "elsewhere")
    os.makedirs(os.path.join(elsewhere, launcher3.CGROUP_INIT_LEAF))
    open(os.path.join(elsewhere, launcher3.CGROUP_INIT_LEAF, "cgroup.procs"), "w").close()
    bad = os.path.join(tmp, "cgroup-root-bad")
    with open(bad, "w") as f:
        f.write(elsewhere)
    logged = []
    assert launcher3.join_instance_init_cgroup(1, 44, logged.append,
                                               root_file=bad, cgroup_fs=fs) is False
    assert _leaf_procs(elsewhere) == "", _leaf_procs(elsewhere)
    assert any("names no cgroup under" in m for m in logged), logged
    assert launcher3.join_instance_init_cgroup(1, 44, logged.append,
                                               root_file=rec[1][1], cgroup_fs=fs), logged
    assert _leaf_procs(rec[1][0]) == "44", _leaf_procs(rec[1][0])


def test_empty_and_missing_records_are_refused(tmp):
    """test empty and missing records fail"""
    fs, rec = _cgroup_fixture(tmp, ids=(1,))
    empty = os.path.join(tmp, "cgroup-root-empty")
    open(empty, "w").close()
    logged = []
    assert launcher3.join_instance_init_cgroup(1, 55, logged.append,
                                               root_file=empty, cgroup_fs=fs) is False
    assert any("names no cgroup under" in m for m in logged), logged
    logged = []
    assert launcher3.join_instance_init_cgroup(1, 55, logged.append,
                                               root_file=os.path.join(tmp, "no-such-record"),
                                               cgroup_fs=fs) is False
    assert any("unreadable" in m for m in logged), logged
    assert launcher3.join_instance_init_cgroup(1, 55, logged.append,
                                               root_file=rec[1][1], cgroup_fs=fs), logged


def test_missing_init_leaf_is_refused_and_never_created(tmp):
    """test a missing init leaf fails"""
    fs, rec = _cgroup_fixture(tmp, ids=(1,), leaf=False)
    logged = []
    assert launcher3.join_instance_init_cgroup(1, 66, logged.append,
                                               root_file=rec[1][1], cgroup_fs=fs) is False
    assert not os.path.exists(os.path.join(rec[1][0], launcher3.CGROUP_INIT_LEAF)), \
        "the leaf was created rather than required"
    assert any("is not a directory this domain can see" in m for m in logged), logged


def test_derivation_never_returns_the_root_itself(tmp):
    """check the init cgroup derivation"""
    for root in ("/sys/fs/cgroup/rhizo", "/sys/fs/cgroup/rhizo-2/",
                 "/sys/fs/cgroup/system.slice/androidd.service/android"):
        leaf = launcher3.instance_init_cgroup(root)
        assert leaf is not None, root
        assert leaf.startswith(root.rstrip("/") + "/"), (root, leaf)
        assert leaf != root.rstrip("/"), root
    for bad in ("", "   ", "\n", "/sys/fs/cgroup", "/sys/fs/cgroup/",
                "/tmp/evil", "rhizo-1"):
        assert launcher3.instance_init_cgroup(bad) is None, repr(bad)


def test_placement_precedes_every_namespace_join(tmp):
    """check the cgroup move precedes setns"""
    body = "\n".join(line for line in
                     inspect.getsource(launcher3._join_and_exec_init).splitlines()
                     if not line.lstrip().startswith("#"))
    move = body.index("join_instance_init_cgroup(")
    for later in ('/ns/{name}"', "libc.setns(", "libc.unshare(CLONE_NEWPID)", "os.fork()"):
        assert later in body, later
        assert move < body.index(later), \
            "the cgroup move must come before %s" % later


class _Ring:
    """fake kmsg record source"""

    def __init__(self, records):
        """keep the records to return"""
        self.records, self.at, self.reads = list(records), 0, 0

    def read(self, n):
        """return the next record, or raise BlockingIOError when none is left"""
        if self.at >= len(self.records):
            raise BlockingIOError(11, "no record")
        self.at += 1
        self.reads += 1
        return self.records[self.at - 1]


_AUDIT = (b"6,1,1,-;audit: avc:  denied  { getattr } for pid=4115 comm=\"python3\" "
          b"path=\"/sys/devices/pci0000:00/0000:00:06.0/virtio4/block/vda/queue/x\" permissive=0\n")
_START = b"6,2,2,-;L3: " + launcher3.MARKER_LAUNCH_START_TEXT.encode() + b"\n"
_DONE = b"5,3,3,-;" + launcher3.MARKER_BOOT_COMPLETED_TEXT.encode() + b"\n"


def _primer_watch_class():
    """compile _KmsgWatch out of HOST_PRIMER_SRC"""
    import ast
    import errno
    import re
    tree = ast.parse(launcher3.HOST_PRIMER_SRC)
    cls = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_KmsgWatch"]
    assert cls, "HOST_PRIMER_SRC defines no _KmsgWatch"
    ns = {"os": os, "errno": errno, "re": re,
          "_MARKER_LAUNCH_START": launcher3.MARKER_LAUNCH_START,
          "_MARKER_BOOT_COMPLETED": launcher3.MARKER_BOOT_COMPLETED}
    exec(compile(ast.Module(body=cls, type_ignores=[]), "HOST_PRIMER_SRC", "exec"), ns)
    polls = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_boot_marker_seen"]
    assert polls and "_boot_watch.seen()" in ast.unparse(polls[0]), \
        "the primer's _boot_marker_seen does not poll its one _KmsgWatch"
    return ns["_KmsgWatch"]


def _watches():
    """return the two boot watch classes with their owners"""
    return (("g's BootMarkerWatch", launcher3.BootMarkerWatch), ("the primer's _KmsgWatch", _primer_watch_class()))


def test_boot_watch_reads_past_a_flooded_ring(tmp):
    """check boot watch on a 9 MB ring"""
    for who, cls in _watches():
        ring = _Ring([_AUDIT] * ((9 << 20) // len(_AUDIT)) + [_START, _DONE])
        watch = cls(read=ring.read, batch=4096)
        calls, most = 0, 0
        while not watch.seen():
            calls += 1
            most = max(most, ring.reads)
            ring.reads = 0
            assert calls <= len(ring.records) // 4096 + 2, \
                "%s: completion past 9 MB of ring not seen after %d calls" % (who, calls)
        assert most <= 4096, "%s: one seen() read %d records, past its batch" % (who, most)


def test_boot_watch_reads_each_record_once(tmp):
    """check that each boot watch reads each record once"""
    for who, cls in _watches():
        ring = _Ring([_AUDIT] * 100 + [_START])
        watch = cls(read=ring.read)
        assert not watch.seen(), "%s: an anchor with no completion read as a completed boot" % who
        ring.records += [_AUDIT] * 3 + [_DONE]
        ring.reads = 0
        assert watch.seen(), "%s: a completion logged after the first call was not seen" % who
        assert ring.reads == 4, "%s: the second call read %d records, not the 4 logged since" \
            % (who, ring.reads)


def test_boot_watch_is_anchored_on_this_run(tmp):
    """check that each boot watch ignores completions from before this run"""
    for who, cls in _watches():
        earlier = _Ring([_START, _DONE, _START, _AUDIT])
        assert not cls(read=earlier.read).seen(), \
            "%s: a completion from before this run's launch_start read as this run's" % who
        other = _DONE.replace(b"sandbox=%d" % launcher3.SANDBOX_ID, b"sandbox=%d9" % launcher3.SANDBOX_ID)
        sibling = _Ring([_START, other])
        assert not cls(read=sibling.read).seen(), "%s: another instance's completion read as this one's" % who
        ok = _Ring([_START, _DONE])
        assert cls(read=ok.read).seen(), "%s: this run's own pair not seen" % who


def test_g_keeps_one_boot_watch_across_its_loop(tmp):
    """check that the launcher builds a boot watch before its loop"""
    src = inspect.getsource(launcher3.run_sandbox)
    made, polled = src.find("_boot_watch = BootMarkerWatch()"), src.find("_boot_watch.seen()")
    loop = src.find("while True:", made)
    assert made >= 0 and polled >= 0, "g does not poll boot completion through one BootMarkerWatch"
    assert made < loop < polled, "g builds its BootMarkerWatch inside the loop, re-reading the ring each pass"


def _record(tmp, root=None, inv=None):
    """write the cgroup root and invocation record files"""
    root_file, inv_file = os.path.join(tmp, "cgroup_root-1"), os.path.join(tmp, "cgroup_invocation-1")
    for path, text in ((root_file, root), (inv_file, inv)):
        if text is not None:
            with open(path, "w") as f:
                f.write(text)
    return root_file, inv_file


def test_a_start_removes_another_invocations_cgroup_record(tmp):
    """check that a start removes another invocation's cgroup record"""
    saved = launcher3.kmsg
    launcher3.kmsg = lambda m: None
    try:
        for label, inv in (("an earlier invocation's", "aaaa\n"), ("an unstamped", None)):
            root_file, inv_file = _record(tmp, "/sys/fs/cgroup/rhizo-1", inv)
            launcher3.clear_earlier_cgroup_record(root_file, inv_file, "bbbb")
            assert not os.path.exists(root_file) and not os.path.exists(inv_file), \
                "%s cgroup record survived a new start, and a reader takes its root for this one's" % label
        root_file, inv_file = _record(tmp, "/sys/fs/cgroup/system.slice/x/android", "bbbb\n")
        launcher3.clear_earlier_cgroup_record(root_file, inv_file, "bbbb")
        assert os.path.exists(root_file) and os.path.exists(inv_file), \
            "a re-exec of the same start removed its own cgroup record"
    finally:
        launcher3.kmsg = saved


def test_the_cgroup_record_names_its_invocation(tmp):
    """check that the cgroup record names its invocation"""
    root_file, inv_file = _record(tmp)
    launcher3.write_cgroup_record("/sys/fs/cgroup/system.slice/x/android", root_file, inv_file, "cccc")
    with open(root_file) as f:
        assert f.read() == "/sys/fs/cgroup/system.slice/x/android", "the root record holds the wrong path"
    with open(inv_file) as f:
        assert f.read().strip() == "cccc", "the record does not name the invocation that wrote it"
    src = inspect.getsource(launcher3.main)
    assert "clear_earlier_cgroup_record()" in src, "main() never clears another start's cgroup record"
    setup = inspect.getsource(launcher3)
    assert "open(CGROUP_ROOT_FILE, \"w\")" not in setup, \
        "a cgroup root is written without the invocation that wrote it"


def selftest():
    """run every case and print the failures"""
    bad = []
    cases = (
        test_publish_survives_its_directory_path_going_away,
        test_failed_signal_withdraws_the_published_entry,
        test_two_coalesced_entries_drained_in_one_wake,
        test_active_id_left_untouched,
        test_dead_pid1_unlinked_and_skipped,
        test_temp_dotfile_ignored,
        test_single_entry_restart_shaped_wake_still_served,
        test_malformed_and_unreadable_entries_are_not_fatal,
        test_missing_directory_returns_empty_not_raise,
        test_unlink_failure_is_logged_not_swallowed,
        test_kernel_domain_launcher_reexecs_only_after_the_phase,
        test_literal_cgroup_root_only_for_the_recording_supervisor_or_its_restart,
        test_supervisor_parks_outside_every_instance_tree,
        test_supervisor_order_check_catches_a_defect,
        test_joined_init_lands_in_the_instance_its_handoff_names,
        test_instance_0_leaf_is_the_one_its_own_boot_already_creates,
        test_unit_delegated_record_is_honored_not_a_derived_path,
        test_record_outside_the_cgroup_filesystem_is_refused,
        test_empty_and_missing_records_are_refused,
        test_missing_init_leaf_is_refused_and_never_created,
        test_derivation_never_returns_the_root_itself,
        test_placement_precedes_every_namespace_join,
        test_boot_watch_reads_past_a_flooded_ring,
        test_boot_watch_reads_each_record_once,
        test_boot_watch_is_anchored_on_this_run,
        test_g_keeps_one_boot_watch_across_its_loop,
        test_a_start_removes_another_invocations_cgroup_record,
        test_the_cgroup_record_names_its_invocation,
    )
    for fn in cases:
        try:
            with tempfile.TemporaryDirectory() as tmp:
                fn(tmp)
        except Exception as e:
            bad.append("%s: %s" % (fn.__name__, e))
    for b in bad:
        print("selftest FAIL: " + b)
    if bad:
        return False
    print("check-handoff-protocol selftest: %d cases passed" % len(cases))
    return True


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    print("check-handoff-protocol: --selftest is the only mode")
    sys.exit(2)
