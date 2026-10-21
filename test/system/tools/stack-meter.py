#!/usr/bin/env python3
"""measure CPU and memory use of the Rhizo stack"""

import argparse
import errno
import json
import os
import re
import sys
import time

USAGE = """Usage:
  stack-meter.py --sample 30                 # CPU delta over 30s + memory total
  stack-meter.py --once                      # memory snapshot, no window
  stack-meter.py --sample 30 --format json --out /tmp/idle.json
  stack-meter.py --sample 30 --cgroup /sys/fs/cgroup/system.slice/androidd.service/android
  stack-meter.py --tmpfs                     # bytes used per tmpfs mount + data.img
  stack-meter.py --dmabuf                    # dma-buf/GEM totals by exporter
  stack-meter.py --host                      # RSS/PSS of host-side product processes
  stack-meter.py --owners                    # every dma-buf's holding pids, in|host
  stack-meter.py --vmas                      # mapping counts by process class/backing
  stack-meter.py --mounts                    # mount x namespace count and mnt_cache
  stack-meter.py --slab                      # slabinfo active+total, SLUB aliases
"""

CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024

HOST_SIDE_PATTERNS = {
    "launcher3.py": "launcher3.py",
    "host-primer": "rhizo-host-primer.py",
    "sway": "/sway",
    "rhizo-audiod": "rhizo-audiod",
    "app-events.py": "app-events.py",
    "netbridged.py": "netbridged.py",
    "rhizo-hostfsd": "rhizo-hostfsd",
}

_SHELL_WRAPPER_BASENAMES = {"sh", "bash", "dash"}


def _is_shell_wrapper_argv(argv):
    """return true for a shell running -c"""
    if not argv:
        return False
    if os.path.basename(argv[0]) not in _SHELL_WRAPPER_BASENAMES:
        return False
    return "-c" in argv[1:]

TMPFS_PATHS_OF_INTEREST = (
    "/run/rhizo",
    "/run/rhizo/data",
    "/dev/shm",
)


def read_or_errno(path):
    """return a file's text or read errno"""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError as exc:
        return None, exc.errno
    try:
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", "replace"), None
    except OSError as exc:
        return None, exc.errno
    finally:
        os.close(fd)


def read(path, default=""):
    """return the text of a file"""
    text, _ = read_or_errno(path)
    return default if text is None else text


def find_cgroup(explicit):
    """return the stack cgroup path"""
    if explicit:
        return explicit if os.path.isdir(explicit) else None
    for cand in ("/sys/fs/cgroup/rhizo",
                 "/sys/fs/cgroup/system.slice/androidd.service/android"):
        if os.path.isdir(cand):
            return cand
    return None


GUEST_MARKER = "/root/boot.log"


def cgroup_members(cg):
    """return the pids in the cgroup subtree"""
    pids = []
    for root, _dirs, files in os.walk(cg):
        if "cgroup.procs" not in files:
            continue
        for line in read(os.path.join(root, "cgroup.procs")).split():
            if line.isdigit():
                pids.append(int(line))
    return sorted(set(pids))


def parse_memory_stat(text):
    """parse the numeric lines of memory.stat"""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                continue
    return out


def cgroup_leaf_memory(cg):
    """return memory.stat for each leaf cgroup"""
    per_pid = {}
    unsplit = {}
    for root, _dirs, files in os.walk(cg):
        if "cgroup.procs" not in files or "memory.stat" not in files:
            continue
        pids = [int(x) for x in read(os.path.join(root, "cgroup.procs")).split()
                if x.isdigit()]
        if not pids:
            continue
        mstat = parse_memory_stat(read(os.path.join(root, "memory.stat")))
        rel = os.path.relpath(root, cg)
        entry = {"cgroup": rel, "memory_stat": mstat, "anon_bytes": mstat.get("anon")}
        if len(pids) == 1:
            per_pid[pids[0]] = entry
        else:
            unsplit[rel] = dict(entry, pids=pids)
    return {"per_pid": per_pid, "unsplit": unsplit}


_LEAF_MEMORY_COLUMNS = ("anon", "shmem", "slab", "file_mapped", "unevictable")
_APP_LEAF_RE = re.compile(r"^apps/uid_\d+/pid_\d+$")


def leaf_memory_rows(leaf_memory):
    """return the memory rows of app leaf cgroups"""
    rows = []
    for pid, entry in leaf_memory.get("per_pid", {}).items():
        cg = entry.get("cgroup", "")
        if not _APP_LEAF_RE.match(cg):
            continue
        mstat = entry.get("memory_stat", {})
        row = {"pid": pid, "cgroup": cg}
        for key in _LEAF_MEMORY_COLUMNS:
            if key in mstat:
                row[key] = mstat[key]
        rows.append(row)
    rows.sort(key=lambda r: r["pid"])
    return rows


def argv0(pid):
    """return argv[0] of a process"""
    raw = read("/proc/%d/cmdline" % pid)
    if raw:
        return raw.split("\0")[0] or "<empty>"
    return "[%s]" % read("/proc/%d/comm" % pid, "?").strip()


def proc_cpu(pid):
    """return cpu ticks and context switch counts"""
    stat = read("/proc/%d/stat" % pid)
    if not stat:
        return None
    close = stat.rfind(")")
    if close < 0:
        return None
    fields = stat[close + 2:].split()
    if len(fields) < 13:
        return None
    ticks = int(fields[11]) + int(fields[12])
    vol = nonvol = 0
    for line in read("/proc/%d/status" % pid).splitlines():
        if line.startswith("voluntary_ctxt_switches:"):
            vol = int(line.split()[1])
        elif line.startswith("nonvoluntary_ctxt_switches:"):
            nonvol = int(line.split()[1])
    return {"ticks": ticks, "vol": vol, "nonvol": nonvol}


_STATUS_MEM_KEYS = {
    "VmRSS:": "rss_kb",
    "RssAnon:": "rss_anon_kb",
    "RssFile:": "rss_file_kb",
    "RssShmem:": "rss_shmem_kb",
}


def parse_status_mem(text):
    """parse the Vm and Rss lines of status"""
    out = {}
    for line in text.splitlines():
        for prefix, key in _STATUS_MEM_KEYS.items():
            if line.startswith(prefix):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        out[key] = int(parts[1])
                    except ValueError:
                        pass
                break
    return out


_ROLLUP_KEYS = {
    "Pss:": "pss_kb",
    "Swap:": "swap_kb",
    "Private_Dirty:": "private_dirty_kb",
    "AnonHugePages:": "anon_huge_kb",
}


def parse_smaps_rollup(text):
    """parse the values in smaps_rollup"""
    out = {}
    for line in text.splitlines():
        for prefix, key in _ROLLUP_KEYS.items():
            if line.startswith(prefix):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        out[key] = int(parts[1])
                    except ValueError:
                        pass
                break
    return out


def proc_mem(pid, want_pss):
    """return the memory fields of a process"""
    out = {"rss_kb": 0, "pss_kb": 0, "swap_kb": 0}
    out.update(parse_status_mem(read("/proc/%d/status" % pid)))
    if want_pss:
        out.update(parse_smaps_rollup(read("/proc/%d/smaps_rollup" % pid)))
    return out


def cgroup_stats(cg):
    """return the cpu and memory counters"""
    out = {}
    usage = None
    for line in read(os.path.join(cg, "cpu.stat")).splitlines():
        if line.startswith("usage_usec"):
            usage = int(line.split()[1])
    out["cpu_usage_usec"] = usage

    def _int_file(name):
        """return the integer in a cgroup file, or None"""
        v = read(os.path.join(cg, name)).strip()
        return int(v) if v.isdigit() else None

    out["memory_current"] = _int_file("memory.current")
    out["memory_swap_current"] = _int_file("memory.swap.current")
    out["memory_peak"] = _int_file("memory.peak")
    out["memory_swap_peak"] = _int_file("memory.swap.peak")
    out["memory_zswap_current"] = _int_file("memory.zswap.current")
    out["memory_zswap_max"] = _int_file("memory.zswap.max")
    zw = read(os.path.join(cg, "memory.zswap.writeback")).strip()
    out["memory_zswap_writeback"] = zw if zw else None

    mstat = parse_memory_stat(read(os.path.join(cg, "memory.stat")))
    out["memory_stat"] = mstat or None
    out["freezer"] = read(os.path.join(cg, "cgroup.freeze")).strip() or None
    out["events"] = read(os.path.join(cg, "cgroup.events")).strip().replace("\n", " ") or None
    out["controllers"] = read(os.path.join(cg, "cgroup.controllers")).strip() or None
    return out


def swap_available():
    """return whether any swap device is active"""
    lines = read("/proc/swaps").splitlines()
    return len(lines) > 1


def pidtree_members(root_pid):
    """return the pids in a process group"""
    out = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        stat = read("/proc/%d/stat" % pid)
        if not stat:
            continue
        close = stat.rfind(")")
        if close < 0:
            continue
        fields = stat[close + 2:].split()
        if len(fields) < 3:
            continue
        try:
            pgrp = int(fields[2])
        except ValueError:
            continue
        if pgrp == root_pid:
            out.append(pid)
    return sorted(out)


def pidtree_stats(pids):
    """return cgroup counters computed from /proc"""
    anon_kb = shmem_kb = 0
    for pid in pids:
        mem = parse_status_mem(read("/proc/%d/status" % pid))
        anon_kb += mem.get("rss_anon_kb") or 0
        shmem_kb += mem.get("rss_shmem_kb") or 0
    return {
        "cpu_usage_usec": None,
        "memory_current": None,
        "memory_swap_current": None,
        "memory_peak": None,
        "memory_swap_peak": None,
        "memory_zswap_current": None,
        "memory_zswap_max": None,
        "memory_zswap_writeback": None,
        "memory_stat": {"anon": anon_kb * 1024, "shmem": shmem_kb * 1024},
        "freezer": None,
        "events": None,
        "controllers": None,
    }


def snapshot(pids, want_pss):
    """return the cpu and memory data per process"""
    snap, unreadable = {}, 0
    for pid in pids:
        cpu = proc_cpu(pid)
        if cpu is None:
            unreadable += 1
            continue
        cpu.update(proc_mem(pid, want_pss))
        cpu["argv0"] = argv0(pid)
        snap[pid] = cpu
    return snap, unreadable


def attribute_unreadable_anon(unreadable_pids, leaf_memory):
    """return anon memory for unreadable pids"""
    attributed = []
    for pid in unreadable_pids:
        entry = leaf_memory.get("per_pid", {}).get(pid)
        if entry is None or entry.get("anon_bytes") is None:
            continue
        attributed.append({"pid": pid, "cgroup": entry["cgroup"],
                            "anon_kb": entry["anon_bytes"] // 1024})
    return attributed


def measure(cg, list_pids, get_stats, window, want_pss):
    """measure cpu and memory use of a cgroup"""
    pids = list_pids()
    before, _ = snapshot(pids, want_pss and window == 0)
    cg_before = get_stats(pids)
    t0 = time.monotonic()

    if window:
        time.sleep(window)
        pids = list_pids()
        after, unreadable = snapshot(pids, want_pss)
        cg_after = get_stats(pids)
    else:
        after, cg_after = before, cg_before
        unreadable = len(pids) - len(before)
    elapsed = time.monotonic() - t0

    rows = []
    for pid, now in after.items():
        was = before.get(pid)
        d_ticks = now["ticks"] - was["ticks"] if was else now["ticks"]
        rows.append({
            "pid": pid,
            "argv0": now["argv0"],
            "cpu_ticks": d_ticks,
            "cpu_seconds": round(d_ticks / CLK_TCK, 3),
            "ctxt_vol": now["vol"] - was["vol"] if was else now["vol"],
            "ctxt_nonvol": now["nonvol"] - was["nonvol"] if was else now["nonvol"],
            "rss_kb": now["rss_kb"],
            "rss_anon_kb": now.get("rss_anon_kb"),
            "rss_file_kb": now.get("rss_file_kb"),
            "rss_shmem_kb": now.get("rss_shmem_kb"),
            "pss_kb": now["pss_kb"],
            "swap_kb": now["swap_kb"],
            "private_dirty_kb": now.get("private_dirty_kb"),
            "anon_huge_kb": now.get("anon_huge_kb"),
            "new": was is None,
        })
    rows.sort(key=lambda r: (-r["cpu_ticks"], -r["rss_kb"]))

    unreadable_pids = [p for p in pids if p not in after]
    unreadable_attribution = attribute_unreadable_anon(
        unreadable_pids, cgroup_leaf_memory(cg))

    total_ticks = sum(r["cpu_ticks"] for r in rows)
    cg_cpu_sec = None
    if cg_before["cpu_usage_usec"] is not None and cg_after["cpu_usage_usec"] is not None:
        cg_cpu_sec = round((cg_after["cpu_usage_usec"] - cg_before["cpu_usage_usec"]) / 1e6, 3)

    return {
        "cgroup": cg,
        "window_s": round(elapsed, 2),
        "procs_in_cgroup": len(pids),
        "procs_seen": len(rows),
        "procs_unreadable": unreadable,
        "procs_unreadable_attributed": len(unreadable_attribution),
        "procs_unreadable_anon_kb_from_cgroup": sum(
            a["anon_kb"] for a in unreadable_attribution),
        "procs_unreadable_attribution": unreadable_attribution,
        "procs": len(rows),
        "procs_gone": len([p for p in before if p not in after]),
        "procs_new": len([r for r in rows if r["new"]]),
        "cpu_seconds": cg_cpu_sec if cg_cpu_sec is not None else round(total_ticks / CLK_TCK, 3),
        "cpu_pct_of_one_core": (round(100.0 * cg_cpu_sec / elapsed, 3) if cg_cpu_sec is not None and elapsed
                                else (round(100.0 * (total_ticks / CLK_TCK) / elapsed, 3) if elapsed else 0.0)),
        "cpu_source": "cgroup cpu.stat" if cg_cpu_sec is not None else "summed per-process (INCOMPLETE)",
        "cpu_seconds_seen_procs": round(total_ticks / CLK_TCK, 3),
        "cgroup_cpu_seconds": cg_cpu_sec,
        "ctxt_switches": sum(r["ctxt_vol"] + r["ctxt_nonvol"] for r in rows),
        "ctxt_switches_per_sec": (round(sum(r["ctxt_vol"] + r["ctxt_nonvol"] for r in rows) / elapsed, 2)
                                  if elapsed else 0.0),
        "rss_sum_kb": sum(r["rss_kb"] for r in rows),
        "rss_anon_sum_kb": sum(r["rss_anon_kb"] for r in rows if r["rss_anon_kb"] is not None),
        "rss_file_sum_kb": sum(r["rss_file_kb"] for r in rows if r["rss_file_kb"] is not None),
        "rss_shmem_sum_kb": sum(r["rss_shmem_kb"] for r in rows if r["rss_shmem_kb"] is not None),
        "procs_with_rss_anon_split": len([r for r in rows if r["rss_anon_kb"] is not None]),
        "private_dirty_sum_kb": sum(r["private_dirty_kb"] for r in rows if r["private_dirty_kb"] is not None),
        "anon_huge_sum_kb": sum(r["anon_huge_kb"] for r in rows if r["anon_huge_kb"] is not None),
        "procs_with_private_dirty": len([r for r in rows if r["private_dirty_kb"] is not None]),
        "pss_sum_kb": sum(r["pss_kb"] for r in rows),
        "swap_sum_kb": sum(r["swap_kb"] for r in rows),
        "swap_configured": swap_available(),
        "cgroup_before": cg_before,
        "cgroup_after": cg_after,
        "processes": rows,
    }


def tmpfs_usage():
    """return the bytes used per tmpfs mount"""
    out = {}
    for path in TMPFS_PATHS_OF_INTEREST:
        if not os.path.ismount(path):
            out[path] = {"mounted": False}
            continue
        try:
            st = os.statvfs(path)
        except OSError as e:
            out[path] = {"mounted": True, "error": str(e)}
            continue
        used = (st.f_blocks - st.f_bfree) * st.f_frsize
        total = st.f_blocks * st.f_frsize
        out[path] = {"mounted": True, "used_bytes": used, "total_bytes": total}
    img = "/run/rhizo/data.img"
    if os.path.exists(img):
        st = os.stat(img)
        out[img] = {
            "nominal_bytes": st.st_size,
            "allocated_bytes": st.st_blocks * 512,
        }
    return out


def dmabuf_usage():
    """return the dma-buf totals per exporter"""
    path = "/sys/kernel/debug/dma_buf/bufinfo"
    raw = read(path)
    if not raw:
        return {"available": False, "path": path}
    return parse_bufinfo(raw, path)


def parse_bufinfo(raw, path="/sys/kernel/debug/dma_buf/bufinfo"):
    """parse the bufinfo column table"""
    by_exporter = {}
    buffers = []
    total_bytes = 0
    cols = None
    for line in raw.splitlines():
        parts = line.split()
        if not parts:
            continue
        if cols is None:
            if "size" in parts and "exp_name" in parts:
                cols = {name: i for i, name in enumerate(parts)}
            continue
        if not parts[0].isdigit():
            continue
        need = ("size", "exp_name")
        if any(c not in cols or cols[c] >= len(parts) for c in need):
            continue
        size = int(parts[cols["size"]])
        exp = parts[cols["exp_name"]]
        rec = {"exporter": exp, "size_bytes": size}
        for extra in ("count", "ino"):
            if extra in cols and cols[extra] < len(parts):
                try:
                    rec[extra] = int(parts[cols[extra]])
                except ValueError:
                    pass
        total_bytes += size
        by_exporter[exp] = by_exporter.get(exp, {"count": 0, "bytes": 0})
        by_exporter[exp]["count"] += 1
        by_exporter[exp]["bytes"] += size
        buffers.append(rec)
    if cols is None:
        return {"available": False, "path": path,
                "error": "bufinfo header row not found; format not recognized"}
    return {
        "available": True,
        "path": path,
        "total_bytes": total_bytes,
        "buffer_count": len(buffers),
        "by_exporter": by_exporter,
        "buffers": buffers,
    }


_SMAPS_HEADER = re.compile(
    r"^[0-9a-f]+-[0-9a-f]+ (?P<perms>[-rwxsp]{4}) [0-9a-f]+ [0-9a-f]+:[0-9a-f]+ \d+\s*(?P<name>.*)$")


def parse_tmpfs_mounts(mountinfo_text):
    """return tmpfs mountpoints and device ids"""
    mounts = {}
    seen_dev = set()
    for line in mountinfo_text.splitlines():
        parts = line.split(" - ")
        if len(parts) < 2 or not parts[1].split():
            continue
        if parts[1].split()[0] != "tmpfs":
            continue
        fields = parts[0].split()
        if len(fields) < 5:
            continue
        mountpoint, dev = fields[4], fields[2]
        if dev in seen_dev:
            continue
        seen_dev.add(dev)
        mounts[mountpoint] = dev
    return mounts


def resolve_tmpfs_bytes(mounts, root_prefix=""):
    """return the used bytes of each tmpfs mount"""
    out = {}
    for mountpoint, dev in mounts.items():
        path = root_prefix + mountpoint
        try:
            st = os.statvfs(path)
        except OSError as e:
            out[mountpoint] = {"dev": dev, "error": str(e)}
            continue
        out[mountpoint] = {"dev": dev,
                            "used_bytes": (st.f_blocks - st.f_bfree) * st.f_frsize}
    return out


def dedupe_tmpfs_overlap(root_resolved, sandbox_resolved):
    """return the tmpfs overlap between two tables"""
    sandbox_devs = {v["dev"] for v in sandbox_resolved.values() if "used_bytes" in v}
    kept = {}
    root_bytes = 0
    overlap_bytes = 0
    overlap_mounts = []
    for mountpoint, v in root_resolved.items():
        if "used_bytes" not in v or not v["used_bytes"]:
            continue
        if v["dev"] in sandbox_devs:
            overlap_bytes += v["used_bytes"]
            overlap_mounts.append(mountpoint)
            continue
        kept[mountpoint] = v["used_bytes"]
        root_bytes += v["used_bytes"]
    return {
        "kept": kept,
        "root_bytes": root_bytes,
        "overlap_bytes": overlap_bytes,
        "overlap_mounts": overlap_mounts,
    }


_RHIZO_INIT_PID_FILE = "/root/.rhizo_init_pid"
_PROC_ROOT = "/proc"
_STACK_CGROUPS = ("/rhizo", "/system.slice/androidd.service/android")


def _in_stack_cgroup(pid):
    """return true for a stack cgroup process"""
    for line in read("%s/%s/cgroup" % (_PROC_ROOT, pid)).splitlines():
        if line.startswith("0::"):
            cg = line[3:]
            return any(cg.startswith(root + "/") for root in _STACK_CGROUPS)
    return False
_SANDBOX_INIT_MARKER = "init second_stage"


def _is_sandbox_init_cmdline(cmdline):
    """return true for the sandbox init cmdline"""
    argv = [f for f in cmdline.split("\0") if f]
    if len(argv) < 2 or argv[1] != "second_stage":
        return False
    return argv[0] == "init" or argv[0].endswith("/init")


def parse_stat_comm(stat_text):
    """return comm from a stat line"""
    if not stat_text or "(" not in stat_text or ")" not in stat_text:
        return None
    return stat_text[stat_text.index("(") + 1:stat_text.rindex(")")]


def parse_stat_identity(stat_text):
    """return comm and starttime from a stat line"""
    if not stat_text or "(" not in stat_text or ")" not in stat_text:
        return None
    comm = stat_text[stat_text.index("(") + 1:stat_text.rindex(")")]
    try:
        starttime = stat_text[stat_text.rindex(")") + 2:].split()[19]
    except IndexError:
        return None
    return comm, starttime


def pid_identity_stable(before_stat_text, after_stat_text):
    """compare two stat reads of a pid"""
    before = parse_stat_identity(before_stat_text)
    after = parse_stat_identity(after_stat_text)
    return before is not None and before == after


def find_sandbox_init_pid(override_pid=None):
    """return the init pid of the sandbox"""
    if override_pid is not None:
        return override_pid if read("%s/%d/stat" % (_PROC_ROOT, override_pid), default=None) else None
    try:
        with open(_RHIZO_INIT_PID_FILE) as f:
            pid = int(f.read().strip())
        if parse_stat_comm(read("%s/%d/stat" % (_PROC_ROOT, pid))) == "init":
            return pid
    except (OSError, ValueError):
        pass
    candidates = []
    for entry in os.listdir(_PROC_ROOT):
        if not entry.isdigit():
            continue
        cmdline = read("%s/%s/cmdline" % (_PROC_ROOT, entry))
        if cmdline and _is_sandbox_init_cmdline(cmdline) and _in_stack_cgroup(entry):
            candidates.append(int(entry))
    return min(candidates) if candidates else None


def sandbox_tmpfs_usage(sandbox_init_pid=None):
    """return the tmpfs mounts of the sandbox init"""
    pid = find_sandbox_init_pid(sandbox_init_pid) if sandbox_init_pid is not None else find_sandbox_init_pid()
    if pid is None:
        status = "sandbox_init_pid_not_live" if sandbox_init_pid else "no_sandbox_init_found"
        return {"status": status, "init_pid": None,
                "requested_pid": sandbox_init_pid,
                "mounts": {}, "bytes_total": 0, "unresolved": {}}
    before_stat = read("/proc/%d/stat" % pid, default=None)
    raw = read("/proc/%d/mountinfo" % pid, default=None)
    after_stat = read("/proc/%d/stat" % pid, default=None)
    if before_stat is None or not pid_identity_stable(before_stat, after_stat):
        return {"status": "pid_identity_changed_during_read", "init_pid": pid,
                "mounts": {}, "bytes_total": 0, "unresolved": {}}
    if raw is None:
        return {"status": "mountinfo_unreadable", "init_pid": pid,
                "mounts": {}, "bytes_total": 0, "unresolved": {}}
    if not raw:
        return {"status": "mountinfo_empty", "init_pid": pid,
                "mounts": {}, "bytes_total": 0, "unresolved": {}}
    mounts = parse_tmpfs_mounts(raw)
    resolved = resolve_tmpfs_bytes(mounts, root_prefix="/proc/%d/root" % pid)
    ok_bytes = sum(v["used_bytes"] for v in resolved.values() if "used_bytes" in v)
    unresolved = {mp: v["error"] for mp, v in resolved.items() if "error" in v}
    return {
        "status": "partial" if unresolved else "ok",
        "init_pid": pid,
        "mounts": resolved,
        "bytes_total": ok_bytes,
        "unresolved": unresolved,
    }


def compute_shmem_summary(total_shmem_bytes, unevictable_bytes, mlocked_bytes,
                           mount_bytes, mounts, classes, deleted_file_bytes,
                           sandbox):
    """compute the shmem residual and summary"""
    sandbox_bytes = sandbox.get("bytes_total", 0)
    class_bytes = sum(classes.values())
    residual = total_shmem_bytes - mount_bytes - sandbox_bytes - class_bytes
    return {
        "shmem_total_bytes": total_shmem_bytes,
        "unevictable_bytes": unevictable_bytes,
        "mlocked_bytes": mlocked_bytes,
        "tmpfs_mount_bytes": mount_bytes,
        "tmpfs_mounts": mounts,
        "sandbox_tmpfs": sandbox,
        "sandbox_tmpfs_bytes": sandbox_bytes,
        "mapped_by_class_bytes": classes,
        "deleted_file_mapped_bytes": deleted_file_bytes,
        "residual_bytes": residual,
        "residual_may_include_sandbox_tmpfs": sandbox.get("status") != "ok",
    }


def shmem_attribution(sandbox_init_pid=None):
    """return the shmem split into classes"""
    meminfo = {}
    for line in read("/proc/meminfo").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].endswith(":"):
            try:
                meminfo[parts[0][:-1]] = int(parts[1]) * 1024
            except ValueError:
                pass
    root_mounts = parse_tmpfs_mounts(read("/proc/self/mountinfo"))
    root_resolved = resolve_tmpfs_bytes(root_mounts)
    sandbox = sandbox_tmpfs_usage(sandbox_init_pid)
    dedup = dedupe_tmpfs_overlap(root_resolved, sandbox.get("mounts", {}))
    mounts = dedup["kept"]
    classes = {"gem-drm": 0, "memfd": 0, "ashmem": 0, "sysv-shm": 0}
    deleted_file_bytes = 0
    procs_seen = procs_unreadable = procs_no_mm = 0
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        smaps = read("/proc/%s/smaps" % entry, default=None)
        if smaps is None:
            procs_unreadable += 1
            continue
        if not smaps:
            procs_no_mm += 1
            continue
        procs_seen += 1
        cls = None
        for line in smaps.splitlines():
            header = _SMAPS_HEADER.match(line)
            if header:
                name, cls = header.group("name").strip(), None
                if "s" not in header.group("perms"):
                    continue
                if "/dev/dri/" in name or "renderD" in name:
                    cls = "gem-drm"
                elif name.startswith("/memfd:"):
                    cls = "memfd"
                elif "ashmem" in name:
                    cls = "ashmem"
                elif name.startswith("/SYSV"):
                    cls = "sysv-shm"
                elif name.endswith("(deleted)"):
                    cls = "deleted-file"
            elif cls and line.startswith("Rss:"):
                try:
                    rss = int(line.split()[1]) * 1024
                except (ValueError, IndexError):
                    continue
                if cls == "deleted-file":
                    deleted_file_bytes += rss
                else:
                    classes[cls] += rss
    summary = compute_shmem_summary(
        total_shmem_bytes=meminfo.get("Shmem", 0),
        unevictable_bytes=meminfo.get("Unevictable", 0),
        mlocked_bytes=meminfo.get("Mlocked", 0),
        mount_bytes=dedup["root_bytes"],
        mounts=mounts,
        classes=classes,
        deleted_file_bytes=deleted_file_bytes,
        sandbox=sandbox,
    )
    summary.update({
        "tmpfs_overlap_bytes": dedup["overlap_bytes"],
        "tmpfs_overlap_mounts": dedup["overlap_mounts"],
        "procs_seen": procs_seen,
        "procs_no_mm": procs_no_mm,
        "procs_unreadable": procs_unreadable,
    })
    return summary


def summarize_host_side(found, in_cgroup_pids):
    """sum rss and pss per host label"""
    summary = {}
    excluded = []
    for label, procs in found.items():
        kept = [p for p in procs if p["pid"] not in in_cgroup_pids]
        excluded.extend({"label": label, **p} for p in procs if p["pid"] in in_cgroup_pids)
        summary[label] = {
            "count": len(kept),
            "rss_kb_sum": sum(p["rss_kb"] for p in kept),
            "pss_kb_sum": sum(p["pss_kb"] for p in kept),
        }
    return summary, excluded


def host_side_usage(cg=None):
    """return rss and pss of host-side processes"""
    if cg is None:
        cg = find_cgroup(None)
    in_cgroup_pids = set(cgroup_members(cg)) if cg else set()
    found = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        raw = read("/proc/%d/cmdline" % pid)
        if not raw:
            continue
        argv = [f for f in raw.split("\0") if f]
        if _is_shell_wrapper_argv(argv):
            continue
        cmdline = " ".join(argv)
        for label, pattern in HOST_SIDE_PATTERNS.items():
            if pattern in cmdline:
                mem = proc_mem(pid, want_pss=True)
                found.setdefault(label, []).append({
                    "pid": pid,
                    "cmdline": cmdline.strip(),
                    "rss_kb": mem["rss_kb"],
                    "pss_kb": mem["pss_kb"],
                })
                break
    summary, excluded = summarize_host_side(found, in_cgroup_pids)
    return {"by_process": found, "summary": summary,
            "rss_kb_total": sum(s["rss_kb_sum"] for s in summary.values()),
            "pss_kb_total": sum(s["pss_kb_sum"] for s in summary.values()),
            "cgroup_checked": cg is not None,
            "cgroup": cg,
            "excluded_in_stack_cgroup": excluded}


def walker_context():
    """return the SELinux context of this process"""
    ctx = read("/proc/self/attr/current", default=None)
    if ctx is None:
        return "unreadable"
    ctx = ctx.strip("\0 \n")
    return ctx or "none"


def parse_fdinfo_dmabuf(text):
    """parse a dma-buf fdinfo record"""
    fields = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        fields[key.strip()] = val.strip()
    if "exp_name" not in fields:
        return None
    rec = {"exp_name": fields["exp_name"], "ino": None, "size": None, "count": None}
    for key, out in (("ino", "ino"), ("size", "size"), ("count", "count")):
        if key in fields:
            try:
                rec[out] = int(fields[key])
            except ValueError:
                pass
    return rec


_MAPS_LINE = re.compile(
    r"^[0-9a-f]+-[0-9a-f]+ [-rwxsp]{4} [0-9a-f]+ ([0-9a-f]+:[0-9a-f]+) (\d+)\s*(.*)$")

_DMABUF_MAP_PREFIXES = ("/dmabuf", "anon_inode:dmabuf")


def is_dmabuf_mapping(name):
    """return true for a dma-buf mapping name"""
    return name.startswith(_DMABUF_MAP_PREFIXES)


def parse_maps_dmabuf_vmas(maps_text, known_inos):
    """count dma-buf mappings per inode"""
    per_ino = {}
    devs = set()
    unjoined = 0
    for line in maps_text.splitlines():
        m = _MAPS_LINE.match(line)
        if not m:
            continue
        dev, ino, name = m.group(1), int(m.group(2)), m.group(3).strip()
        if not is_dmabuf_mapping(name):
            continue
        devs.add(dev)
        if ino in known_inos:
            per_ino[ino] = per_ino.get(ino, 0) + 1
        else:
            unjoined += 1
    return per_ino, unjoined, devs


def combine_dmabuf_holders(buffers, holders):
    """join fd and mapping counts to dma-buf rows"""
    by_ino = {}
    for b in buffers:
        ino = b.get("ino")
        if ino is None:
            continue
        by_ino[ino] = {
            "ino": ino,
            "exporter": b.get("exporter"),
            "size_bytes": b.get("size_bytes", 0),
            "count": b.get("count"),
            "holders": [],
        }
    orphan_holders = []
    for h in holders:
        rec = by_ino.get(h["ino"])
        if rec is None:
            orphan_holders.append(h)
            continue
        rec["holders"].append({k: h[k] for k in ("pid", "comm", "cgroup", "fds", "vmas")})
    rows = []
    for ino in sorted(by_ino):
        rec = by_ino[ino]
        rec["holders"].sort(key=lambda x: x["pid"])
        rec["fds"] = sum(h["fds"] for h in rec["holders"])
        rec["vmas"] = sum(h["vmas"] for h in rec["holders"])
        rec["holder_refs"] = rec["fds"] + rec["vmas"]
        rec["kernel_refs"] = (None if rec["count"] is None
                              else rec["count"] - rec["holder_refs"])
        rec["over_counted"] = (rec["kernel_refs"] is not None
                               and rec["kernel_refs"] < 0)
        if any(h["cgroup"] == "in" for h in rec["holders"]):
            rec["scope"] = "in"
        elif rec["holders"]:
            rec["scope"] = "host"
        else:
            rec["scope"] = "unowned"
        rows.append(rec)
    totals = {}
    for scope in ("in", "host", "unowned"):
        sel = [r for r in rows if r["scope"] == scope]
        totals[scope] = {"objs": len(sel), "bytes": sum(r["size_bytes"] for r in sel)}
    return {
        "buffers": rows,
        "buffer_count": len(rows),
        "by_scope": totals,
        "buffers_without_holders": [r["ino"] for r in rows if not r["holders"]],
        "buffers_over_counted": [
            {"ino": r["ino"], "count": r["count"], "holder_refs": r["holder_refs"]}
            for r in rows if r["over_counted"]],
        "buffers_with_kernel_refs": [
            {"ino": r["ino"], "count": r["count"], "holder_refs": r["holder_refs"],
             "kernel_refs": r["kernel_refs"]}
            for r in rows if (r["kernel_refs"] or 0) > 0],
        "holders_without_buffer": orphan_holders,
    }


def collect_dmabuf_holders(known_inos, in_cgroup_pids):
    """collect dma-buf fd and mapping counts per pid"""
    holders = {}
    procs_seen = procs_denied = procs_gone = 0
    fdinfo_dmabuf = fdinfo_unparsed = fdinfo_unjoined = maps_unjoined = 0
    map_devs = set()
    for entry in sorted(os.listdir("/proc")):
        if not entry.isdigit():
            continue
        pid = int(entry)
        fddir = "/proc/%d/fdinfo" % pid
        try:
            fds = os.listdir(fddir)
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                procs_gone += 1
            else:
                procs_denied += 1
            continue
        procs_seen += 1
        comm = parse_stat_comm(read("/proc/%d/stat" % pid)) or ""
        scope = "in" if pid in in_cgroup_pids else "host"
        per_ino_fds = {}
        for fd in fds:
            rec = parse_fdinfo_dmabuf(read(os.path.join(fddir, fd)))
            if rec is None:
                continue
            fdinfo_dmabuf += 1
            if rec["ino"] is None:
                fdinfo_unparsed += 1
                continue
            if rec["ino"] not in known_inos:
                fdinfo_unjoined += 1
                continue
            per_ino_fds[rec["ino"]] = per_ino_fds.get(rec["ino"], 0) + 1
        per_ino_vmas, unjoined, devs = parse_maps_dmabuf_vmas(
            read("/proc/%d/maps" % pid), known_inos)
        maps_unjoined += unjoined
        map_devs |= devs
        for ino in set(per_ino_fds) | set(per_ino_vmas):
            holders.setdefault(ino, []).append({
                "pid": pid, "comm": comm, "cgroup": scope,
                "fds": per_ino_fds.get(ino, 0), "vmas": per_ino_vmas.get(ino, 0),
                "ino": ino})
    if not fdinfo_dmabuf:
        fmt = "no dma-buf fd seen"
    elif fdinfo_unparsed == fdinfo_dmabuf:
        fmt = "unrecognized: no dma-buf fdinfo carried an ino: row"
    elif fdinfo_unparsed:
        fmt = "partial: %d of %d dma-buf fdinfo rows carried no ino:" % (
            fdinfo_unparsed, fdinfo_dmabuf)
    else:
        fmt = "ok"
    flat = [h for ino in sorted(holders) for h in holders[ino]]
    return {"holders": flat, "procs_seen": procs_seen,
            "procs_unreadable": procs_denied + procs_gone,
            "procs_denied": procs_denied,
            "procs_gone": procs_gone,
            "dmabuf_map_devs": sorted(map_devs),
            "fdinfo_dmabuf_rows": fdinfo_dmabuf,
            "fdinfo_unparsed": fdinfo_unparsed,
            "fdinfo_unjoined": fdinfo_unjoined,
            "fdinfo_format": fmt,
            "maps_unjoined": maps_unjoined}


def dmabuf_owners(cg=None):
    """return the per-process dma-buf report"""
    buf = dmabuf_usage()
    if not buf.get("available"):
        return {"available": False, "reason": buf.get("error", "bufinfo unreadable"),
                "path": buf.get("path")}
    if cg is None:
        cg = find_cgroup(None)
    in_cgroup_pids = set(cgroup_members(cg)) if cg else set()
    known = {b["ino"] for b in buf["buffers"] if b.get("ino") is not None}
    walk = collect_dmabuf_holders(known, in_cgroup_pids)
    out = combine_dmabuf_holders(buf["buffers"], walk["holders"])
    out.update({
        "available": True,
        "cgroup": cg,
        "cgroup_checked": cg is not None,
        "bufinfo_rows_without_ino": len([b for b in buf["buffers"] if b.get("ino") is None]),
        "walker_context": walker_context(),
        "procs_seen": walk["procs_seen"],
        "procs_unreadable": walk["procs_unreadable"],
        "procs_denied": walk["procs_denied"],
        "procs_gone": walk["procs_gone"],
        "dmabuf_map_devs": walk["dmabuf_map_devs"],
        "fdinfo_dmabuf_rows": walk["fdinfo_dmabuf_rows"],
        "fdinfo_unparsed": walk["fdinfo_unparsed"],
        "fdinfo_unjoined": walk["fdinfo_unjoined"],
        "fdinfo_format": walk["fdinfo_format"],
        "maps_unjoined": walk["maps_unjoined"],
    })
    return out


_VMA_BACKINGS = ("anon", "so", "dex", "dmabuf", "ashmem", "other")


def classify_vma_backing(name):
    """return the backing class of a maps line"""
    if not name:
        return "anon"
    if name.startswith("["):
        return "anon"
    if name.startswith("/dmabuf") or "/dev/dri/" in name or "renderD" in name:
        return "dmabuf"
    if "ashmem" in name or name.startswith("/memfd:"):
        return "ashmem"
    base = name[:-10] if name.endswith(" (deleted)") else name
    if base.endswith(".so") or ".so." in base:
        return "so"
    for ext in (".oat", ".odex", ".vdex", ".art"):
        if base.endswith(ext):
            return "dex"
    return "other"


def classify_proc(cmdline, ppid, zygote_pid):
    """return the class name of a process"""
    argv = cmdline.split("\0")[0] if cmdline else ""
    if argv in ("zygote64", "zygote"):
        return "zygote"
    if argv == "system_server":
        return "system_server"
    if zygote_pid is not None and ppid == zygote_pid:
        return "zygote-child"
    for prefix, label in (("/system/bin/", "system-bin"),
                          ("/apex/", "apex"),
                          ("/vendor/bin/hw/", "vendor-hal")):
        if argv.startswith(prefix):
            return label
    return "other"


def parse_status_ppid(text):
    """return PPid from a status file"""
    for line in text.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def summarize_counts(per_proc):
    """return statistics of per-process counts"""
    vals = sorted(per_proc)
    n = len(vals)
    if not n:
        return {"n": 0, "sum": 0, "mean": 0.0, "median": 0.0}
    mid = n // 2
    median = float(vals[mid]) if n % 2 else (vals[mid - 1] + vals[mid]) / 2.0
    return {"n": n, "sum": sum(vals), "mean": round(sum(vals) / n, 2),
            "median": round(median, 2)}


def build_vma_report(procs):
    """build the vma tables from process readings"""
    by_class = {}
    by_backing = {b: [] for b in _VMA_BACKINGS}
    for p in procs:
        by_class.setdefault(p["class"], []).append(p["vmas"])
        for backing in _VMA_BACKINGS:
            by_backing[backing].append(p["backing"].get(backing, 0))
    child_sets = [set(p["names"]) for p in procs if p["class"] == "zygote-child"]
    common = sorted(set.intersection(*child_sets)) if child_sets else []
    return {
        "by_process_class": {k: summarize_counts(v) for k, v in sorted(by_class.items())},
        "by_backing": {k: summarize_counts(v) for k, v in by_backing.items()},
        "zygote_children": len(child_sets),
        "zygote_child_common_mappings": common,
        "zygote_child_common_count": len(common),
    }


def vma_usage(cg=None):
    """return mapping counts per process class"""
    if cg is None:
        cg = find_cgroup(None)
    in_cgroup_pids = set(cgroup_members(cg)) if cg else set()
    zygote_pid = None
    entries = []
    for entry in sorted(os.listdir("/proc")):
        if not entry.isdigit():
            continue
        pid = int(entry)
        cmdline = read("/proc/%d/cmdline" % pid)
        if cmdline.split("\0")[0] in ("zygote64", "zygote"):
            zygote_pid = pid
        entries.append((pid, cmdline))
    procs = []
    procs_denied = procs_gone = procs_no_mm = 0
    for pid, cmdline in entries:
        maps, err = read_or_errno("/proc/%d/maps" % pid)
        if maps is None:
            if err == errno.ENOENT:
                procs_gone += 1
            else:
                procs_denied += 1
            continue
        if not maps:
            procs_no_mm += 1
            continue
        ppid = parse_status_ppid(read("/proc/%d/status" % pid))
        backing = {b: 0 for b in _VMA_BACKINGS}
        names = set()
        total = 0
        for line in maps.splitlines():
            m = _MAPS_LINE.match(line)
            if not m:
                continue
            total += 1
            name = m.group(3).strip()
            backing[classify_vma_backing(name)] += 1
            if name:
                names.add(name)
        procs.append({"pid": pid, "cgroup": "in" if pid in in_cgroup_pids else "host",
                      "class": classify_proc(cmdline, ppid, zygote_pid),
                      "vmas": total, "backing": backing, "names": names})
    report = build_vma_report(procs)
    report.update({
        "cgroup": cg, "cgroup_checked": cg is not None,
        "walker_context": walker_context(),
        "zygote_pid": zygote_pid,
        "procs_seen": len(procs),
        "procs_no_mm": procs_no_mm,
        "procs_unreadable": procs_denied + procs_gone,
        "procs_denied": procs_denied,
        "procs_gone": procs_gone,
        "processes": [{k: p[k] for k in ("pid", "cgroup", "class", "vmas", "backing")}
                      for p in sorted(procs, key=lambda p: -p["vmas"])],
    })
    return report


def parse_slabinfo(text):
    """parse the caches in slabinfo"""
    caches = {}
    for line in text.splitlines():
        if line.startswith("#") or line.startswith("slabinfo"):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            active, total, objsize = int(parts[1]), int(parts[2]), int(parts[3])
        except ValueError:
            continue
        caches[parts[0]] = {
            "name": parts[0], "active_objs": active, "num_objs": total,
            "objsize": objsize, "active_bytes": active * objsize,
            "total_bytes": total * objsize,
        }
    return caches


SLAB_ALIAS_NAMES = ("cred_jar", "vm_area_struct", "mnt_cache", "task_struct")


def slab_aliases(names=SLAB_ALIAS_NAMES, root="/sys/kernel/slab"):
    """read the alias target of each SLUB cache"""
    out = {}
    for name in names:
        path = os.path.join(root, name)
        try:
            out[name] = os.path.basename(os.readlink(path))
        except OSError as exc:
            out[name] = "unreadable (%s)" % exc.strerror
    return out


def slab_usage():
    """return slabinfo totals and alias targets"""
    text = read("/proc/slabinfo")
    if not text:
        return {"available": False, "path": "/proc/slabinfo"}
    caches = parse_slabinfo(text)
    if not caches:
        return {"available": False, "path": "/proc/slabinfo",
                "error": "slabinfo parsed to no caches; format not recognized"}
    rows = sorted(caches.values(), key=lambda c: -c["total_bytes"])
    return {
        "available": True,
        "caches": rows,
        "active_bytes_total": sum(c["active_bytes"] for c in rows),
        "total_bytes_total": sum(c["total_bytes"] for c in rows),
        "aliases": slab_aliases(),
    }


def count_mount_namespaces():
    """count the distinct mount namespaces"""
    seen = set()
    readable = denied = gone = 0
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            seen.add(os.readlink("/proc/%s/ns/mnt" % entry))
            readable += 1
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                gone += 1
            else:
                denied += 1
    return {"count": len(seen), "readable_pids": readable,
            "denied_pids": denied, "gone_pids": gone,
            "complete": denied == 0}


def mnt_ns_qualifier(denied):
    """return the qualifier for the namespace count"""
    if not denied:
        return "every pid's mnt ns link read"
    return ("floor only: %d pid(s) denied, each possibly a namespace nothing "
            "else counted" % denied)


def mount_product(mount_count, ns, mnt_cache):
    """return mounts times namespaces times objsize"""
    if mount_count is None or not mnt_cache:
        return None
    objs = mount_count * ns["count"]
    return {
        "mounts_x_namespaces": objs,
        "objsize": mnt_cache["objsize"],
        "bytes": objs * mnt_cache["objsize"],
        "mb": round(objs * mnt_cache["objsize"] / 1048576.0, 2),
        "namespaces_complete": ns["complete"],
    }


def mounts_usage(sandbox_init_pid=None):
    """return the mount and namespace counts"""
    pid = find_sandbox_init_pid(sandbox_init_pid)
    mountinfo = read("/proc/%d/mountinfo" % pid, default=None) if pid else None
    mount_count = len(mountinfo.splitlines()) if mountinfo else None
    ns = count_mount_namespaces()
    caches = parse_slabinfo(read("/proc/slabinfo"))
    mnt_cache = caches.get("mnt_cache")
    out = {
        "subject_init_pid": pid,
        "mount_count": mount_count,
        "mount_count_source": ("/proc/%d/mountinfo" % pid) if pid else "no subject init pid found",
        "mnt_ns_count": ns["count"],
        "mnt_ns_readable_pids": ns["readable_pids"],
        "mnt_ns_denied_pids": ns["denied_pids"],
        "mnt_ns_gone_pids": ns["gone_pids"],
        "mnt_ns_complete": ns["complete"],
        "mnt_ns_qualifier": mnt_ns_qualifier(ns["denied_pids"]),
        "mnt_cache": mnt_cache,
        "mnt_cache_alias": slab_aliases(("mnt_cache",)).get("mnt_cache"),
    }
    out["product"] = mount_product(mount_count, ns, mnt_cache)
    return out


DEBUG_PROC_READ_ENV = "RHIZO_DEBUG_PROC_READ"
_ANDROIDD_ENV_FILE = "/root/androidd.env"


def debug_proc_read_enabled(environ=None, env_text=None):
    """read the RHIZO_DEBUG_PROC_READ setting"""
    environ = os.environ if environ is None else environ
    if environ.get(DEBUG_PROC_READ_ENV) == "1":
        return True
    if env_text is None:
        env_text = read(_ANDROIDD_ENV_FILE)
    for line in env_text.splitlines():
        if line.strip() == "%s=1" % DEBUG_PROC_READ_ENV:
            return True
    return False


def procs_unreadable_refusal(denied, enabled):
    """return the refusal text for denied pids"""
    if not enabled or not denied:
        return None
    return ("%s=1 on this boot and %d process(es) were still DENIED"
            % (DEBUG_PROC_READ_ENV, denied))


def emit_tsv(m, top, fh):
    """write the meter result as tab-separated rows"""
    w = lambda *a: print(*a, sep="\t", file=fh)
    w("#", "rhizo-meter", "cgroup=%s" % m["cgroup"], "window_s=%s" % m["window_s"])
    for k in ("procs_in_cgroup", "procs_seen", "procs_unreadable",
              "debug_proc_read", "procs_unreadable_refusal",
              "procs_unreadable_attributed", "procs_unreadable_anon_kb_from_cgroup",
              "procs_new",
              "procs_gone", "cpu_seconds", "cpu_pct_of_one_core", "cpu_source",
              "cpu_seconds_seen_procs", "cgroup_cpu_seconds", "ctxt_switches", "ctxt_switches_per_sec",
              "rss_sum_kb", "rss_anon_sum_kb", "rss_file_sum_kb", "rss_shmem_sum_kb",
              "procs_with_rss_anon_split", "private_dirty_sum_kb", "anon_huge_sum_kb",
              "procs_with_private_dirty", "pss_sum_kb", "swap_sum_kb", "swap_configured"):
        w(k, m[k])
    for side in ("cgroup_before", "cgroup_after"):
        for k, v in m[side].items():
            w("%s.%s" % (side, k), v)
    w("#")
    w("pid", "cpu_seconds", "cpu_ticks", "ctxt_vol", "ctxt_nonvol",
      "rss_kb", "rss_anon_kb", "rss_file_kb", "rss_shmem_kb",
      "pss_kb", "swap_kb", "private_dirty_kb", "anon_huge_kb", "new", "argv0")
    for r in m["processes"][:top]:
        w(r["pid"], r["cpu_seconds"], r["cpu_ticks"], r["ctxt_vol"], r["ctxt_nonvol"],
          r["rss_kb"], r["rss_anon_kb"], r["rss_file_kb"], r["rss_shmem_kb"],
          r["pss_kb"], r["swap_kb"], r["private_dirty_kb"], r["anon_huge_kb"],
          int(r["new"]), r["argv0"])


def main():
    """run the selected measurements"""
    ap = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sample", type=float, default=0, metavar="SECONDS",
                    help="measure CPU over this window (0 = memory snapshot only)")
    ap.add_argument("--once", action="store_true", help="same as --sample 0")
    ap.add_argument("--cgroup", help="the stack's cgroup (default: autodetect)")
    ap.add_argument("--pidtree", type=int, metavar="PID",
                    help="measure a bare process's own group instead of a cgroup -- "
                         "for a host with no writable cgroup v2 subtree at all (this "
                         "host's own /sys/fs/cgroup). PID must be a process group leader (its own "
                         "pid == its own pgid, e.g. launched via `setsid`); every "
                         "pid in that SAME process group is measured. anon/shmem "
                         "come from summing /proc/<pid>/status (RssAnon/RssShmem) "
                         "across the group; slab has no per-process meaning and is "
                         "left OUT of memory_stat entirely (never defaulted to 0); "
                         "cpu falls back to summed per-process utime+stime, same as "
                         "a cgroup whose own cpu.stat is unavailable. Mutually "
                         "exclusive with --cgroup.")
    ap.add_argument("--sandbox-init-pid", type=int, metavar="PID",
                    help="with --shmem: attribute a comparator's Shmem instead of "
                         "Rhizo's own -- PID is that comparator's own container "
                         "init, host-visible, resolved by the caller")
    ap.add_argument("--format", choices=("tsv", "json"), default="tsv")
    ap.add_argument("--out", help="write here instead of stdout")
    ap.add_argument("--top", type=int, default=25, help="processes to list (tsv only)")
    ap.add_argument("--no-pss", action="store_true",
                    help="skip smaps_rollup; faster, but RSS double-counts shared pages")
    ap.add_argument("--tmpfs", action="store_true",
                    help="report tmpfs mount usage + data.img allocated size, then exit")
    ap.add_argument("--dmabuf", action="store_true",
                    help="report dma-buf/GEM totals by exporter, then exit")
    ap.add_argument("--host", action="store_true",
                    help="report RSS/PSS of host-side product processes, then exit")
    ap.add_argument("--shmem", action="store_true",
                    help="split Shmem into tmpfs mounts, mapped classes and an "
                         "explicit residual, then exit")
    ap.add_argument("--leaf-memory", action="store_true",
                    help="per-app-cgroup memory.stat table (anon/shmem/slab/"
                         "file_mapped/unevictable per apps/uid_*/pid_* leaf), then exit")
    ap.add_argument("--owners", action="store_true",
                    help="every dma-buf in bufinfo with the pids holding its fds and "
                         "mappings, in-cgroup or host-side, then exit")
    ap.add_argument("--vmas", action="store_true",
                    help="per-process mapping counts by process class and by backing, "
                         "then exit")
    ap.add_argument("--mounts", action="store_true",
                    help="mount count, mount-namespace count and mnt_cache, the "
                         "arithmetic behind every mount lever, then exit")
    ap.add_argument("--slab", action="store_true",
                    help="slabinfo with active AND total objects plus the SLUB alias "
                         "readlinks, then exit")
    args = ap.parse_args()

    if args.pidtree and args.cgroup:
        print("stack-meter: --pidtree and --cgroup are mutually exclusive", file=sys.stderr)
        return 2

    if (args.tmpfs or args.dmabuf or args.host or args.shmem or args.owners
            or args.vmas or args.mounts or args.slab):
        out = {}
        if args.tmpfs:
            out["tmpfs"] = tmpfs_usage()
        if args.dmabuf:
            out["dmabuf"] = dmabuf_usage()
        if args.host:
            out["host"] = host_side_usage()
        if args.shmem:
            out["shmem"] = shmem_attribution(args.sandbox_init_pid)
        if args.owners:
            out["owners"] = dmabuf_owners(args.cgroup)
        if args.vmas:
            out["vmas"] = vma_usage(args.cgroup)
        if args.mounts:
            out["mounts"] = mounts_usage(args.sandbox_init_pid)
        if args.slab:
            out["slab"] = slab_usage()
        enabled = debug_proc_read_enabled()
        refusal = None
        for section in ("owners", "vmas"):
            data = out.get(section)
            if isinstance(data, dict):
                data["debug_proc_read"] = enabled
                refusal = refusal or procs_unreadable_refusal(
                    data.get("procs_denied", 0), enabled)
        fh = open(args.out, "w") if args.out else sys.stdout
        try:
            if args.format == "json":
                json.dump(out, fh, indent=1, sort_keys=True)
                fh.write("\n")
            else:
                for section, data in out.items():
                    print("#", section, file=fh)
                    print(json.dumps(data, indent=1, sort_keys=True), file=fh)
        finally:
            if args.out:
                fh.close()
        if refusal:
            print("stack-meter: %s" % refusal, file=sys.stderr)
            return 3
        return 0

    if args.pidtree:
        if args.leaf_memory:
            print("stack-meter: --leaf-memory needs a real cgroup (per-app "
                  "apps/uid_*/pid_* leaves), not --pidtree", file=sys.stderr)
            return 2
        if not os.path.isdir("/proc/%d" % args.pidtree):
            print("stack-meter: --pidtree %d: no such process" % args.pidtree,
                  file=sys.stderr)
            return 2
        cg_label = "pidtree:%d" % args.pidtree
        list_pids = lambda: pidtree_members(args.pidtree)
        get_stats = pidtree_stats
    else:
        cg = find_cgroup(args.cgroup)
        if not cg:
            if not os.path.exists(GUEST_MARKER):
                print("stack-meter: %s is absent -- run stack-meter.py inside the "
                      "guest (test/vm/common.sh's ssh_vm)"
                      % GUEST_MARKER, file=sys.stderr)
            else:
                print("stack-meter: no stack cgroup found on this guest (looked for "
                      "/sys/fs/cgroup/rhizo and .../androidd.service/android; pass "
                      "--cgroup)", file=sys.stderr)
            return 2

        if args.leaf_memory:
            rows = leaf_memory_rows(cgroup_leaf_memory(cg))
            fh = open(args.out, "w") if args.out else sys.stdout
            try:
                if args.format == "json":
                    json.dump(rows, fh, indent=1, sort_keys=True)
                    fh.write("\n")
                else:
                    print("pid\tcgroup\t" + "\t".join(_LEAF_MEMORY_COLUMNS), file=fh)
                    for row in rows:
                        print("%d\t%s\t%s" % (row["pid"], row["cgroup"],
                              "\t".join(str(row.get(c, "")) for c in _LEAF_MEMORY_COLUMNS)), file=fh)
            finally:
                if args.out:
                    fh.close()
            return 0
        cg_label = cg
        list_pids = lambda: cgroup_members(cg)
        get_stats = lambda pids: cgroup_stats(cg)

    window = 0 if args.once else args.sample
    m = measure(cg_label, list_pids, get_stats, window, not args.no_pss)
    m["debug_proc_read"] = debug_proc_read_enabled()
    m["procs_unreadable_refusal"] = procs_unreadable_refusal(
        m["procs_unreadable"], m["debug_proc_read"])
    m["measurement_mode"] = "pidtree" if args.pidtree else "cgroup"

    fh = open(args.out, "w") if args.out else sys.stdout
    try:
        if args.format == "json":
            json.dump(m, fh, indent=1, sort_keys=True)
            fh.write("\n")
        else:
            emit_tsv(m, args.top, fh)
    finally:
        if args.out:
            fh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
