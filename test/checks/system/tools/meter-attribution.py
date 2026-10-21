#!/usr/bin/env python3
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    """return the footprint meter module loaded from its file"""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "rhizo_meter", os.path.join(HERE, "..", "..", "..", "system", "tools", "stack-meter.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


STATUS_FIXTURE = (
    "Name:\tcom.rhizo.audiorouter\n"
    "State:\tS (sleeping)\n"
    "VmRSS:\t   45632 kB\n"
    "RssAnon:\t   30212 kB\n"
    "RssFile:\t   15300 kB\n"
    "RssShmem:\t     120 kB\n"
)

ROLLUP_FIXTURE = (
    "Rss:            12345 kB\n"
    "Pss:              6789 kB\n"
    "Pss_Anon:         6000 kB\n"
    "Shared_Clean:      100 kB\n"
    "Private_Dirty:    5900 kB\n"
    "Swap:               50 kB\n"
    "SwapPss:            50 kB\n"
    "AnonHugePages:    2048 kB\n"
)

SANDBOX_MOUNTINFO_FIXTURE = (
    "22 25 0:20 / / rw,relatime shared:1 - tmpfs tmpfs rw,mode=0755\n"
    "23 22 0:21 / /dev rw,nosuid shared:2 - tmpfs tmpfs rw,mode=0755\n"
    "24 23 0:22 / /dev/shm rw,nosuid,nodev shared:3 - tmpfs tmpfs rw,mode=1777\n"
    "25 23 0:23 / /dev/input rw,nosuid,nodev shared:4 - tmpfs tmpfs "
    "rw,mode=0755,uid=1000,gid=1000\n"
    "26 22 0:24 / /sys/kernel rw,nosuid,nodev,noexec shared:5 - tmpfs tmpfs rw\n"
    "27 22 0:9 / /proc rw,nosuid,nodev,noexec shared:6 - proc proc rw\n"
    "28 27 0:25 / /proc/sys/net/core rw,relatime shared:7 - tmpfs tmpfs rw,mode=0755\n"
    "29 22 0:10 / /sys rw,nosuid,nodev,noexec shared:8 - sysfs sysfs rw\n"
)

EXPECTED_SANDBOX_MOUNTPOINTS = {
    "/", "/dev", "/dev/shm", "/dev/input", "/sys/kernel", "/proc/sys/net/core",
}


def check_status_parse(parse_status_mem, problems):
    """check parse_status_mem on a status fixture"""
    got = parse_status_mem(STATUS_FIXTURE)
    want = {"rss_kb": 45632, "rss_anon_kb": 30212, "rss_file_kb": 15300, "rss_shmem_kb": 120}
    if got != want:
        problems.append("parse_status_mem(status fixture) = %r, want %r" % (got, want))
    old = parse_status_mem("Name:\tfoo\nVmRSS:\t   100 kB\n")
    if set(old) != {"rss_kb"}:
        problems.append("parse_status_mem on a kernel with no Rss* split "
                         "invented keys it never read: %r" % old)


def check_rollup_parse(parse_smaps_rollup, problems):
    """check the smaps rollup parser"""
    got = parse_smaps_rollup(ROLLUP_FIXTURE)
    want = {"pss_kb": 6789, "swap_kb": 50, "private_dirty_kb": 5900, "anon_huge_kb": 2048}
    if got != want:
        problems.append("parse_smaps_rollup(rollup fixture) = %r, want %r"
                         % (got, want))


def check_sandbox_mount_parse(parse_tmpfs_mounts, problems):
    """check the sandbox mount table parser"""
    got = set(parse_tmpfs_mounts(SANDBOX_MOUNTINFO_FIXTURE))
    if got != EXPECTED_SANDBOX_MOUNTPOINTS:
        problems.append(
            "parse_tmpfs_mounts on the sandbox's own post-pivot mount table "
            "found %r, want %r"
            % (got, EXPECTED_SANDBOX_MOUNTPOINTS))


STAT_FIXTURE = "4242 (binder:42_A woo)) S 1 4242 4242 0 -1 4194624 100 0 0 0\n"


def check_stat_comm_parse(parse_stat_comm, problems):
    """check the stat command parser"""
    got = parse_stat_comm(STAT_FIXTURE)
    if got != "binder:42_A woo)":
        problems.append("parse_stat_comm(stat fixture) = %r, want %r" % (got, "binder:42_A woo)"))


def check_residual_arithmetic(compute_shmem_summary, problems):
    """check compute_shmem_summary residual arithmetic"""
    sandbox_ok = {"status": "ok", "bytes_total": 300}
    r = compute_shmem_summary(
        total_shmem_bytes=1000, unevictable_bytes=0, mlocked_bytes=0,
        mount_bytes=200, mounts={}, classes={"gem-drm": 100}, deleted_file_bytes=0,
        sandbox=sandbox_ok)
    if r.get("residual_bytes") != 400:
        problems.append("compute_shmem_summary residual_bytes = %r, want 400 -- "
                         "sandbox tmpfs is not being subtracted"
                         % r.get("residual_bytes"))
    if r.get("residual_may_include_sandbox_tmpfs") is not False:
        problems.append(
            "sandbox read status=ok but residual_may_include_sandbox_tmpfs "
            "!= False: %r"
            % r.get("residual_may_include_sandbox_tmpfs"))

    sandbox_missing = {"status": "no_sandbox_init_found", "bytes_total": 0}
    r2 = compute_shmem_summary(
        total_shmem_bytes=1000, unevictable_bytes=0, mlocked_bytes=0,
        mount_bytes=200, mounts={}, classes={"gem-drm": 100}, deleted_file_bytes=0,
        sandbox=sandbox_missing)
    if r2.get("residual_may_include_sandbox_tmpfs") is not True:
        problems.append(
            "sandbox unreadable but residual_may_include_sandbox_tmpfs != True: %r"
            % r2.get("residual_may_include_sandbox_tmpfs"))


ROOT_RESOLVED_FIXTURE = {
    "/run/rhizo": {"dev": "0:30", "used_bytes": 5_000_000},
    "/dev/shm": {"dev": "0:31", "used_bytes": 1_000_000},
}
SANDBOX_RESOLVED_FIXTURE = {
    "/system": {"dev": "0:30", "used_bytes": 5_000_000},
    "/dev/shm": {"dev": "0:40", "used_bytes": 200_000},
}


def check_tmpfs_overlap_dedup(dedupe_tmpfs_overlap, problems):
    """check the tmpfs overlap dedupe counts a shared superblock once"""
    r = dedupe_tmpfs_overlap(ROOT_RESOLVED_FIXTURE, SANDBOX_RESOLVED_FIXTURE)
    if r.get("overlap_bytes") != 5_000_000:
        problems.append(
            "dedupe_tmpfs_overlap() overlap_bytes = %r, want 5000000 -- "
            "/run/rhizo and the sandbox's own bind mount of it (same dev "
            "0:30) were not recognized as the same superblock"
            % r.get("overlap_bytes"))
    if r.get("root_bytes") != 1_000_000:
        problems.append(
            "dedupe_tmpfs_overlap() root_bytes = %r, want 1000000"
            % r.get("root_bytes"))
    if "/run/rhizo" in r.get("kept", {}):
        problems.append(
            "dedupe_tmpfs_overlap() kept the overlapping mount %r in its "
            "own dict instead of netting it out" % r.get("kept"))
    if r.get("overlap_mounts") != ["/run/rhizo"]:
        problems.append(
            "dedupe_tmpfs_overlap() overlap_mounts = %r, want ['/run/rhizo']"
            % r.get("overlap_mounts"))


_STAT_A = "4242 (init) S 1 4242 4242 0 -1 4194624 100 0 0 0 50 20 0 0 20 0 4 0 123456789 0 0\n"
_STAT_SAME = "4242 (init) S 1 4242 4242 0 -1 4194624 999 0 0 0 999 999 0 0 20 0 4 0 123456789 0 0\n"
_STAT_RECYCLED_STARTTIME = "4242 (init) S 1 4242 4242 0 -1 4194624 100 0 0 0 50 20 0 0 20 0 4 0 999999999 0 0\n"
_STAT_RECYCLED_COMM = "4242 (other) S 1 4242 4242 0 -1 4194624 100 0 0 0 50 20 0 0 20 0 4 0 123456789 0 0\n"


def check_pid_identity_stable(pid_identity_stable, problems):
    """check pid_identity_stable on fixture stat text"""
    if pid_identity_stable(_STAT_A, _STAT_SAME) is not True:
        problems.append(
            "pid_identity_stable() said an unchanged (comm, starttime) pid "
            "was NOT stable across two reads that only moved utime/stime")
    if pid_identity_stable(_STAT_A, _STAT_RECYCLED_STARTTIME) is not False:
        problems.append(
            "pid_identity_stable() said a pid was stable across two reads "
            "with DIFFERENT starttimes")
    if pid_identity_stable(_STAT_A, _STAT_RECYCLED_COMM) is not False:
        problems.append(
            "pid_identity_stable() said a pid was stable across two reads "
            "with different comm")
    if pid_identity_stable(_STAT_A, "") is not False:
        problems.append(
            "pid_identity_stable() treated an unreadable second stat "
            "(empty text) as stable")


def _write_leaf(base, rel, pids, memory_stat_text):
    """write a cgroup leaf directory with its pids and memory stat"""
    d = os.path.join(base, rel)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "cgroup.procs"), "w") as f:
        f.write("\n".join(str(p) for p in pids) + ("\n" if pids else ""))
    with open(os.path.join(d, "memory.stat"), "w") as f:
        f.write(memory_stat_text)


def check_cgroup_leaf_memory(cgroup_leaf_memory, problems):
    """check cgroup_leaf_memory on a temporary cgroup tree"""
    base = tempfile.mkdtemp(prefix="rhizo-meter-cgtest-")
    try:
        _write_leaf(base, "apps/uid_10100/pid_501", [501],
                    "anon 5242880\nfile 102400\n")
        _write_leaf(base, "apps/uid_10100/pid_777", [777, 778],
                    "anon 999999\n")
        os.makedirs(os.path.join(base, "apps/uid_10100/pid_900"), exist_ok=True)
        with open(os.path.join(base, "apps/uid_10100/pid_900/cgroup.procs"), "w") as f:
            f.write("900\n")

        r = cgroup_leaf_memory(base)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    per_pid = r.get("per_pid", {})
    if per_pid.get(501, {}).get("anon_bytes") != 5242880:
        problems.append(
            "cgroup_leaf_memory() per_pid[501].anon_bytes = %r, want 5242880"
            % per_pid.get(501, {}).get("anon_bytes"))
    if 777 in per_pid or 778 in per_pid:
        problems.append(
            "cgroup_leaf_memory() put a two-pid leaf's process(es) into "
            "per_pid (%r)" % per_pid)
    unsplit = r.get("unsplit", {})
    matching = [v for v in unsplit.values() if v.get("pids") == [777, 778]]
    if not matching or matching[0].get("anon_bytes") != 999999:
        problems.append(
            "cgroup_leaf_memory() unsplit = %r, want the two-pid leaf's "
            "999999-byte anon reading" % unsplit)
    if 900 in per_pid:
        problems.append(
            "cgroup_leaf_memory() invented an anon reading for pid 900, "
            "whose cgroup has no memory.stat file at all")


def check_leaf_memory_rows(leaf_memory_rows, problems):
    """check leaf_memory_rows against fixture cgroup data"""
    leaf_memory = {"per_pid": {
        501: {"cgroup": "apps/uid_10100/pid_501",
              "memory_stat": {"anon": 5242880, "shmem": 102400, "slab": 40960,
                               "file_mapped": 8192, "unevictable": 0}},
        502: {"cgroup": "apps/uid_10100/pid_502",
              "memory_stat": {"anon": 1048576, "shmem": 0}},
        1: {"cgroup": ".", "memory_stat": {"anon": 999999999}},
    }, "unsplit": {}}
    got = leaf_memory_rows(leaf_memory)
    if [r["pid"] for r in got] != [501, 502]:
        problems.append(
            "leaf_memory_rows() returned pids %r, want [501, 502] in order" % [r.get("pid") for r in got])
        return
    if got[0].get("anon") != 5242880 or got[0].get("shmem") != 102400:
        problems.append(
            "leaf_memory_rows() row for pid 501 = %r, want anon/shmem "
            "from its own memory.stat" % got[0])
    if "unevictable" in got[1]:
        problems.append(
            "leaf_memory_rows() row for pid 502 invented unevictable=%r "
            "for a memory.stat that never reported that key" % got[1].get("unevictable"))


def check_attribute_unreadable_anon(attribute_unreadable_anon, problems):
    """check attribute_unreadable_anon against cgroup fixtures"""
    leaf_memory = {
        "per_pid": {501: {"cgroup": "apps/uid_10100/pid_501", "anon_bytes": 5242880}},
        "unsplit": {},
    }
    got = attribute_unreadable_anon([501, 909], leaf_memory)
    if got != [{"pid": 501, "cgroup": "apps/uid_10100/pid_501", "anon_kb": 5120}]:
        problems.append(
            "attribute_unreadable_anon([501, 909], ...) = %r, want a single "
            "501 entry at 5120 kB and pid 909 left out entirely (no cgroup "
            "answer exists for it)" % got)


def check_host_side_exclusion(summarize_host_side, problems):
    """check summarize_host_side on cgroup and host processes"""
    found = {
        "launcher3.py": [{"pid": 501, "cmdline": "python3 launcher3.py second_stage",
                           "rss_kb": 15000, "pss_kb": 15000}],
        "sway": [{"pid": 700, "cmdline": "/usr/bin/sway", "rss_kb": 84400, "pss_kb": 84400}],
    }
    in_cgroup_pids = {501}
    summary, excluded = summarize_host_side(found, in_cgroup_pids)
    if summary.get("launcher3.py", {}).get("pss_kb_sum") != 0:
        problems.append(
            "launcher3.py pss_kb_sum = %r, want 0"
            % summary.get("launcher3.py", {}).get("pss_kb_sum"))
    if summary.get("sway", {}).get("pss_kb_sum") != 84400:
        problems.append(
            "sway pss_kb_sum = %r, want 84400"
            % summary.get("sway", {}).get("pss_kb_sum"))
    if not any(e.get("pid") == 501 for e in excluded):
        problems.append(
            "launcher3.py's pid 501 was held out of the totals but not named "
            "in `excluded`")


def run_checks(parse_status_mem, parse_smaps_rollup, parse_tmpfs_mounts,
               parse_stat_comm, compute_shmem_summary, summarize_host_side,
               dedupe_tmpfs_overlap, pid_identity_stable, cgroup_leaf_memory,
               attribute_unreadable_anon):
    """run every attribution check and return the problems"""
    problems = []
    check_status_parse(parse_status_mem, problems)
    check_rollup_parse(parse_smaps_rollup, problems)
    check_sandbox_mount_parse(parse_tmpfs_mounts, problems)
    check_stat_comm_parse(parse_stat_comm, problems)
    check_residual_arithmetic(compute_shmem_summary, problems)
    check_tmpfs_overlap_dedup(dedupe_tmpfs_overlap, problems)
    check_pid_identity_stable(pid_identity_stable, problems)
    check_cgroup_leaf_memory(cgroup_leaf_memory, problems)
    check_attribute_unreadable_anon(attribute_unreadable_anon, problems)
    check_host_side_exclusion(summarize_host_side, problems)
    return problems


def check_init_matcher(mod, problems):
    """check _is_sandbox_init_cmdline on init and decoy argv"""
    real = "/system/bin/init\0second_stage\0"
    if not mod._is_sandbox_init_cmdline(real):
        problems.append("the real sandbox init argv %r is no longer matched" % real)
    decoys = [
        "/bin/bash\0-c\0grep -n 'init second_stage' stack-meter.py\0",
        "python3\0launcher3.py\0second_stage\0",
        "/system/bin/init\0",
        "",
    ]
    for d in decoys:
        if mod._is_sandbox_init_cmdline(d):
            problems.append("a process whose argv is %r was matched as the "
                             "sandbox's init" % d)


def check_no_sandbox_here(mod, problems):
    """check the find_sandbox_init_pid and sandbox_tmpfs_usage results"""
    pid = mod.find_sandbox_init_pid()
    if pid is not None:
        problems.append("find_sandbox_init_pid() returned %r on a box running "
                         "no sandbox"
                         % pid)
    status = mod.sandbox_tmpfs_usage()
    if status.get("status") != "no_sandbox_init_found":
        problems.append("sandbox_tmpfs_usage() status=%r with no sandbox "
                         "present, want 'no_sandbox_init_found'"
                         % status.get("status"))
    if status.get("bytes_total") != 0:
        problems.append("sandbox_tmpfs_usage() bytes_total=%r with no sandbox "
                         "found" % status.get("bytes_total"))


def check_scan_names_init_by_stack_cgroup(mod, problems):
    """check the init scan on a fake /proc"""
    base = tempfile.mkdtemp(prefix="rhizo-meter-initscan-")
    orig_root, orig_pidfile = getattr(mod, "_PROC_ROOT", None), mod._RHIZO_INIT_PID_FILE
    try:
        def proc(pid, cg):
            """write a fake process directory with a command line and cgroup"""
            os.makedirs(os.path.join(base, str(pid)))
            with open(os.path.join(base, str(pid), "cmdline"), "w") as f:
                f.write("/system/bin/init\0second_stage\0")
            with open(os.path.join(base, str(pid), "cgroup"), "w") as f:
                f.write("0::%s\n" % cg)
        proc(1200, "/user.slice/user-1000.slice/session-3.scope")
        proc(1300, "/rhizo-host")
        proc(1500, "/rhizo-2/init")
        mod._PROC_ROOT = base
        mod._RHIZO_INIT_PID_FILE = os.path.join(base, "no-pid-file")
        got = mod.find_sandbox_init_pid()
        if got is not None:
            problems.append("find_sandbox_init_pid() named %r from stand-ins outside the stack cgroup, "
                            "want None" % got)
        proc(4242, "/rhizo/init")
        proc(10001, "/rhizo/init")
        got = mod.find_sandbox_init_pid()
        if got != 4242:
            problems.append("find_sandbox_init_pid() named %r past stand-ins, want the init in rhizo/init (4242)" % got)
        shutil.rmtree(os.path.join(base, "4242"))
        shutil.rmtree(os.path.join(base, "10001"))
        proc(4343, "/system.slice/androidd.service/android/init")
        got = mod.find_sandbox_init_pid()
        if got != 4343:
            problems.append("find_sandbox_init_pid() named %r, want the init under androidd.service's "
                            "android/ cgroup (4343)" % got)
    finally:
        mod._PROC_ROOT, mod._RHIZO_INIT_PID_FILE = orig_root, orig_pidfile
        shutil.rmtree(base)


def check_sandbox_pid_reuse_guard_wired(mod, problems):
    """check sandbox_tmpfs_usage calls pid_identity_stable"""
    orig_read, orig_find = mod.read, mod.find_sandbox_init_pid
    calls = {"stat": 0}

    def fake_read(path, default=""):
        """read a fake stat that changes its start time on the second read"""
        if path == "/proc/4242/stat":
            calls["stat"] += 1
            return _STAT_A if calls["stat"] == 1 else _STAT_RECYCLED_STARTTIME
        if path == "/proc/4242/mountinfo":
            return SANDBOX_MOUNTINFO_FIXTURE
        return orig_read(path, default)

    mod.read = fake_read
    mod.find_sandbox_init_pid = lambda: 4242
    try:
        status = mod.sandbox_tmpfs_usage()

        if status.get("status") != "pid_identity_changed_during_read":
            problems.append(
                "sandbox_tmpfs_usage() status=%r when pid 4242's (comm, "
                "starttime) changed between being accepted and its "
                "mountinfo read being trusted, want "
                "'pid_identity_changed_during_read'"
                % status.get("status"))

        calls["stat"] = 0

        def fake_read_stable(path, default=""):
            """read a fake stat that stays the same"""
            if path == "/proc/4242/stat":
                calls["stat"] += 1
                return _STAT_A
            if path == "/proc/4242/mountinfo":
                return SANDBOX_MOUNTINFO_FIXTURE
            return orig_read(path, default)

        mod.read = fake_read_stable
        status2 = mod.sandbox_tmpfs_usage()
        if status2.get("status") not in ("ok", "partial"):
            problems.append(
                "sandbox_tmpfs_usage() status=%r for a pid whose identity "
                "did NOT change" % status2.get("status"))
    finally:
        mod.read, mod.find_sandbox_init_pid = orig_read, orig_find


def main():
    """run the attribution checks on the meter module"""
    mod = load()
    needed = ("parse_status_mem", "parse_smaps_rollup", "parse_tmpfs_mounts",
              "parse_stat_comm", "compute_shmem_summary", "summarize_host_side",
              "find_sandbox_init_pid", "sandbox_tmpfs_usage",
              "dedupe_tmpfs_overlap", "pid_identity_stable",
              "cgroup_leaf_memory", "attribute_unreadable_anon", "leaf_memory_rows")
    missing = [n for n in needed if not hasattr(mod, n)]
    if missing:
        print("FAIL: stack-meter.py is missing %s" % missing, file=sys.stderr)
        return 1

    problems = run_checks(mod.parse_status_mem, mod.parse_smaps_rollup,
                           mod.parse_tmpfs_mounts, mod.parse_stat_comm,
                           mod.compute_shmem_summary, mod.summarize_host_side,
                           mod.dedupe_tmpfs_overlap, mod.pid_identity_stable,
                           mod.cgroup_leaf_memory, mod.attribute_unreadable_anon)
    check_leaf_memory_rows(mod.leaf_memory_rows, problems)
    check_init_matcher(mod, problems)
    check_no_sandbox_here(mod, problems)
    check_scan_names_init_by_stack_cgroup(mod, problems)
    check_sandbox_pid_reuse_guard_wired(mod, problems)

    if problems:
        for p in problems:
            print("FAIL: " + p, file=sys.stderr)
        return 1
    print("meter attribution: ok (per-process anon, sandbox tmpfs, "
          "host-side cgroup exclusion all hold)")
    return 0


def _broken_parse_status_mem(text):
    """parse VmRSS from status text"""
    for line in text.splitlines():
        if line.startswith("VmRSS:"):
            return {"rss_kb": int(line.split()[1])}
    return {}


def _broken_parse_smaps_rollup(text):
    """parse Pss and Swap from smaps_rollup text"""
    out = {}
    for line in text.splitlines():
        if line.startswith("Pss:"):
            out["pss_kb"] = int(line.split()[1])
        elif line.startswith("Swap:"):
            out["swap_kb"] = int(line.split()[1])
    return out


def _broken_parse_tmpfs_mounts_unread(_text):
    """return an empty tmpfs mount table"""
    return {}


def _broken_parse_stat_comm(stat_text):
    """parse comm from the second stat word"""
    try:
        return stat_text.split()[1].strip("()")
    except IndexError:
        return None


def _broken_compute_shmem_summary(total_shmem_bytes, unevictable_bytes, mlocked_bytes,
                                   mount_bytes, mounts, classes, deleted_file_bytes,
                                   sandbox):
    """compute the shmem residual from mounts and classes"""
    class_bytes = sum(classes.values())
    return {
        "shmem_total_bytes": total_shmem_bytes,
        "tmpfs_mount_bytes": mount_bytes,
        "mapped_by_class_bytes": classes,
        "residual_bytes": total_shmem_bytes - mount_bytes - class_bytes,
    }


def _broken_dedupe_tmpfs_overlap(root_resolved, _sandbox_resolved):
    """return the root tmpfs mounts and byte total"""
    kept = {mp: v["used_bytes"] for mp, v in root_resolved.items()
            if "used_bytes" in v}
    return {"kept": kept, "root_bytes": sum(kept.values()),
            "overlap_bytes": 0, "overlap_mounts": []}


def _broken_pid_identity_stable(before_stat_text, _after_stat_text):
    """test the stat text for an open parenthesis"""
    return bool(before_stat_text) and "(" in before_stat_text


def _broken_cgroup_leaf_memory(_cg):
    """return empty per-pid and unsplit memory tables"""
    return {"per_pid": {}, "unsplit": {}}


def _broken_attribute_unreadable_anon(_unreadable_pids, _leaf_memory):
    """return an empty anon list"""
    return []


def _broken_leaf_memory_rows(leaf_memory):
    """build table rows for every cgroup leaf"""
    rows = []
    for pid, entry in leaf_memory.get("per_pid", {}).items():
        row = {"pid": pid, "cgroup": entry.get("cgroup", "")}
        row.update(entry.get("memory_stat", {}))
        rows.append(row)
    rows.sort(key=lambda r: r["pid"])
    return rows


def _broken_summarize_host_side(found, _in_cgroup_pids):
    """sum rss and pss for every host-side match"""
    summary = {
        label: {
            "count": len(procs),
            "rss_kb_sum": sum(p["rss_kb"] for p in procs),
            "pss_kb_sum": sum(p["pss_kb"] for p in procs),
        }
        for label, procs in found.items()
    }
    return summary, []


def _try_reintroduce(name, check_fn, broken_fn, blind_spot):
    """return whether a check flags a reintroduced defect"""
    problems = []
    check_fn(broken_fn, problems)
    if not problems:
        print("selftest FAIL: %s passed %s (%s)" % (name, check_fn.__name__, blind_spot), file=sys.stderr)
        return False
    return True


def selftest():
    """check that each reintroduced defect is flagged"""
    cases = [
        ("the pre-fix status parser (VmRSS only)", check_status_parse,
         _broken_parse_status_mem, "blind spot 1 (per-process anon)"),
        ("the pre-fix rollup parser (Pss/Swap only)", check_rollup_parse,
         _broken_parse_smaps_rollup, "blind spot 1 (per-process anon)"),
        ("a parser that never reads the sandbox's mount table",
         check_sandbox_mount_parse, _broken_parse_tmpfs_mounts_unread,
         "blind spot 2 (sandbox-namespace tmpfs)"),
        ("a naive word-position comm parser", check_stat_comm_parse,
         _broken_parse_stat_comm, "the init pid-reuse guard"),
        ("the pre-fix residual formula (no sandbox term)",
         check_residual_arithmetic, _broken_compute_shmem_summary,
         "blind spot 2 (sandbox-namespace tmpfs)"),
        ("a blind sum of two overlapping mount tables",
         check_tmpfs_overlap_dedup, _broken_dedupe_tmpfs_overlap,
         "defect 1 (tmpfs mount double-count)"),
        ("a comm-only guard with no reverify",
         check_pid_identity_stable, _broken_pid_identity_stable,
         "defect 2 (pid-reuse guard parity)"),
        ("no cgroup-side memory attribution at all",
         check_cgroup_leaf_memory, _broken_cgroup_leaf_memory,
         "defect 4 (SELinux-denied anon)"),
        ("no filling of the unreadable-anon gap",
         check_attribute_unreadable_anon, _broken_attribute_unreadable_anon,
         "defect 4 (SELinux-denied anon)"),
        ("--leaf-memory with no apps/uid_*/pid_* filter",
         check_leaf_memory_rows, _broken_leaf_memory_rows,
         "the per-app-cgroup table (A0.2)"),
        ("a summarizer with no cgroup check", check_host_side_exclusion,
         _broken_summarize_host_side, "the launcher3.py double count"),
    ]
    ok = True
    for name, check_fn, broken_fn, blind_spot in cases:
        ok = _try_reintroduce(name, check_fn, broken_fn, blind_spot) and ok

    if not ok:
        return 1
    print("selftest: all %d reintroduced defects were caught" % len(cases))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
