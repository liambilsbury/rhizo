#!/usr/bin/env python3
"""host service for rt.budgets and rt.contain"""
import argparse
import collections
import ctypes
import json
import math
import os
import re
import selectors
import signal
import socket
import struct
import sys
import time

MAX_PACKET = 4096
INT64_MAX = 2 ** 63 - 1
REQUIRED_PEER_CTX = "u:r:rhizo_power:s0"
REFUSALS_MAX = 32
MIN_SHARE = 0.15
KEEP_SHARE = 0.08
SHARE_WINDOW_S = 1.0
IDLE_RELEASE_S = 1.0
MIN_THREAD_RUNTIME_NS = 200_000
HELPER_COMM_PREFIX = "hwuiTask"
BINDER_HELPER_RUNTIME_NS = MIN_THREAD_RUNTIME_NS
FRAME_CPU_HEADROOM = 1.25
FRAME_INTERVAL_HISTORY = 32
FRAME_PERIOD_STEPS = 4
FRAME_PERIOD_MAX_TARGETS = 4
REAPPLY_RUNTIME_DELTA = 0.10
REAPPLY_MIN_INTERVAL_S = 0.100
SWEEP_INTERVAL_S = 1.0
STATUS_WRITE_INTERVAL_S = 0.5
DRAIN_PASSES_MAX = 64
HISTORY_MAX = 16
SAMPLE_GAP_MIN_NS = 1_000_000

SELF_RESERVE_RUNTIME_NS = 2_000_000
SELF_RESERVE_PERIOD_NS = int(REAPPLY_MIN_INTERVAL_S * 1_000_000_000)

DEFAULT_SOCKET = "/run/rhizo-rt/rtd"
DEFAULT_STATUS_PATH = "/run/rhizo-rtd/status.json"
CARVE_RECORD_NAME = "carve.json"

CGROUP_FS = "/sys/fs/cgroup"
INIT_CGROUP_LEAF = "init"
UNIT_CGROUP_CHILD = "android"
TENANT_JOINT_CAP = 0.9
CARVE_STEP_BW = 0.05
CARVE_RAISE_MIN_S = 10.0
CPU_MAX_MIN_QUOTA_US = 1000
CARVE_EPS = 1e-9
RECLAIM_OVERRUN_MARGIN = 0.02
DEMAND_LOG_MIN_S = 10.0
HARD_PERIOD_NS = 2_000_000
HARD_PERIOD_ENV = "RHIZO_RTD_HARD_PERIOD"
CONTAIN_HEADROOM = 1.25
CONTAIN_RUN_HEADROOM = 2
CONTAIN_MIN_WINDOW_S = 0.5

SCHED_OTHER = 0
SCHED_FIFO = 1
SCHED_RR = 2
SCHED_BATCH = 3
SCHED_IDLE = 5
SCHED_DEADLINE = 6
_POLICY_NAME = {SCHED_OTHER: "other", SCHED_BATCH: "batch"}
_POLICY_FOR_NAME = {"other": SCHED_OTHER, "batch": SCHED_BATCH}


def thread_is_eligible(policy):
    """return true for SCHED_OTHER and SCHED_BATCH"""
    return policy in _POLICY_FOR_NAME.values()


def is_fifo_rr(policy):
    """return true for SCHED_FIFO and SCHED_RR"""
    return policy in (SCHED_FIFO, SCHED_RR)


_RT_POLICY_NAME = {SCHED_FIFO: "fifo", SCHED_RR: "rr"}
_RT_POLICY_FOR_NAME = {"fifo": SCHED_FIFO, "rr": SCHED_RR}
ANDROID_INIT_CTX = "u:r:init:s0"
ANDROID_INIT_ARGV = [b"/system/bin/init", b"second_stage"]
RHIZO_STACK_RE = re.compile(
    r"^/(rhizo(-[0-9]+)?|system\.slice/(system-androidd\.slice/)?androidd(@[0-9]+)?\.service/android)/")
AID_SYSTEM = 1000
POWER_HAL_PATH = "/vendor/bin/hw/rhizo-power-service"


def _in_sandbox_ns(view, pid, namespaces):
    """return true for a sandbox namespace pid"""
    return view.ns_ino(pid) in namespaces


def _contain_restore_args(ct):
    """return the restore arguments for a contained thread"""
    return ct.prior_policy, 0, ct.prior_priority


BINDER_POOL_RE = re.compile(r"^binder:(\d+)_\d+$")


def _binder_pool_tgid(comm):
    """return the pid in a binder comm"""
    m = BINDER_POOL_RE.match(comm)
    return int(m.group(1)) if m else None


def is_helper(comm, tgid_ns):
    """return true for hwuiTask and binder pool comms"""
    return comm.startswith(HELPER_COMM_PREFIX) or _binder_pool_tgid(comm) == tgid_ns


def helper_runtime_ns(comm, samples, period_ns):
    """return the runtime for hwuiTask and binder threads"""
    if comm.startswith(HELPER_COMM_PREFIX):
        return frame_cpu_runtime_ns(samples, period_ns) or MIN_THREAD_RUNTIME_NS
    return BINDER_HELPER_RUNTIME_NS


SCHED_FLAG_RESET_ON_FORK = 0x01
SCHED_FLAG_RECLAIM = 0x02

SYS_SCHED_SETATTR = 314
SYS_SCHED_GETATTR = 315

SID_RE = re.compile(r"^[^\s:]+$")


def log(msg):
    """write a message to stderr"""
    print(msg, file=sys.stderr, flush=True)


class ProtocolError(Exception):
    """exception for a malformed wire message"""


LIBC = ctypes.CDLL("libc.so.6", use_errno=True)


class SchedAttr(ctypes.Structure):
    """layout of struct sched_attr"""
    _fields_ = [
        ("size", ctypes.c_uint32),
        ("sched_policy", ctypes.c_uint32),
        ("sched_flags", ctypes.c_uint64),
        ("sched_nice", ctypes.c_int32),
        ("sched_priority", ctypes.c_uint32),
        ("sched_runtime", ctypes.c_uint64),
        ("sched_deadline", ctypes.c_uint64),
        ("sched_period", ctypes.c_uint64),
    ]


SCHED_ATTR_SIZE = ctypes.sizeof(SchedAttr)


def sched_setattr(tid, policy, flags=0, nice=0, priority=0, runtime=0, deadline=0, period=0):
    """call sched_setattr on a host tid"""
    attr = SchedAttr(size=SCHED_ATTR_SIZE, sched_policy=policy, sched_flags=flags,
                      sched_nice=nice, sched_priority=priority, sched_runtime=runtime,
                      sched_deadline=deadline, sched_period=period)
    ctypes.set_errno(0)
    rc = LIBC.syscall(SYS_SCHED_SETATTR, ctypes.c_int(tid), ctypes.byref(attr), ctypes.c_uint(0))
    if rc < 0:
        return False, ctypes.get_errno()
    return True, 0


def sched_getattr(tid):
    """call sched_getattr on a host tid"""
    attr = SchedAttr(size=SCHED_ATTR_SIZE)
    ctypes.set_errno(0)
    rc = LIBC.syscall(SYS_SCHED_GETATTR, ctypes.c_int(tid), ctypes.byref(attr),
                       ctypes.c_uint(SCHED_ATTR_SIZE), ctypes.c_uint(0))
    if rc < 0:
        return None, ctypes.get_errno()
    return attr, 0


def grant_deadline(tid, runtime_ns, period_ns, reclaim=True):
    """set SCHED_DEADLINE on a thread"""
    flags = SCHED_FLAG_RESET_ON_FORK | (SCHED_FLAG_RECLAIM if reclaim else 0)
    return sched_setattr(tid, SCHED_DEADLINE, flags=flags,
                          runtime=runtime_ns, deadline=period_ns, period=period_ns)


def hard_grant(runtime_ns, period_ns, hard_period_ns=HARD_PERIOD_NS):
    """return runtime and period at hard_period_ns"""
    if hard_period_ns is None or period_ns <= hard_period_ns:
        return runtime_ns, period_ns
    return max(DL_RUNTIME_MIN_NS, runtime_ns * hard_period_ns // period_ns), hard_period_ns


def load_hard_period(environ=os.environ):
    """read the hard period setting from the environment"""
    return {None: ("2ms", HARD_PERIOD_NS), "2ms": ("2ms", HARD_PERIOD_NS),
            "frame": ("frame", None)}.get(environ.get(HARD_PERIOD_ENV))


def reserve_self(tid, runtime_ns=SELF_RESERVE_RUNTIME_NS, period_ns=SELF_RESERVE_PERIOD_NS):
    """reserve SCHED_DEADLINE bandwidth for a thread"""
    return sched_setattr(tid, SCHED_DEADLINE, flags=SCHED_FLAG_RECLAIM,
                          runtime=runtime_ns, deadline=period_ns, period=period_ns)


DL_RUNTIME_MIN_NS = 1 << 10
PERIOD_MAX_PATH = "/proc/sys/kernel/sched_deadline_period_max_us"


def park_period_ns(path=PERIOD_MAX_PATH):
    """return the longest deadline period in ns"""
    with open(path, "rb", buffering=0) as f:
        return int(f.read().strip()) * 1000


def parked_bw_units(period_ns):
    """convert the minimum runtime to bandwidth units"""
    return (DL_RUNTIME_MIN_NS << 20) // period_ns


def revoke_to_prior(tid, policy, nice, priority=0):
    """restore a thread to its prior policy"""
    try:
        period = park_period_ns()
    except (OSError, ValueError) as e:
        log("tid=%d: cannot read %s (%s) -- refusing" % (tid, PERIOD_MAX_PATH, e))
        return False, getattr(e, "errno", 0) or 22
    ok, errno = sched_setattr(tid, SCHED_DEADLINE, flags=SCHED_FLAG_RESET_ON_FORK,
                              runtime=DL_RUNTIME_MIN_NS, deadline=period, period=period)
    if not ok:
        return ok, errno
    return sched_setattr(tid, policy, nice=nice, priority=priority)


def set_rt_policy(tid, policy, priority):
    """set SCHED_FIFO or SCHED_RR on a thread"""
    return sched_setattr(tid, policy, priority=priority)


def online_cpu_count(path="/sys/devices/system/cpu/online"):
    """return the number of online CPUs"""
    try:
        with open(path) as f:
            spec = f.read().strip()
        total = 0
        for part in spec.split(","):
            if not part:
                continue
            if "-" in part:
                a, b = part.split("-")
                total += int(b) - int(a) + 1
            else:
                total += 1
        if total > 0:
            return total
    except (OSError, ValueError):
        pass
    return os.cpu_count() or 1


def cap_bandwidth(cap_percent, cpus):
    """return the CPU bandwidth cap in CPUs"""
    return (cap_percent / 100.0) * cpus


def bandwidth(runtime_ns, period_ns):
    """return the bandwidth fraction of a runtime in a period"""
    return runtime_ns / period_ns if period_ns > 0 else 0.0


def percentile(values, q):
    """return the nearest-rank percentile of values"""
    ordered = sorted(values)
    n = len(ordered)
    return ordered[min(n - 1, max(0, math.ceil(q * n) - 1))]


def p90(values):
    """return the 90th percentile of values"""
    return percentile(values, 0.9)


def frame_cpu_ns(samples):
    """return the CPU time per frame"""
    if not samples:
        return None
    return max(p90(samples), sum(samples) / len(samples))


def frame_cpu_runtime_ns(samples, period_ns):
    """return the runtime to reserve per frame"""
    need = frame_cpu_ns(samples)
    hi = 0.9 * period_ns
    if need is None or hi < MIN_THREAD_RUNTIME_NS:
        return None
    return int(max(MIN_THREAD_RUNTIME_NS, min(hi, FRAME_CPU_HEADROOM * need)))


def frame_period_ns(intervals, target_ns):
    """return the grant period for a session"""
    if not intervals or target_ns <= 0:
        return target_ns
    steps = sum(intervals) * FRAME_PERIOD_STEPS // (len(intervals) * target_ns)
    steps = max(FRAME_PERIOD_STEPS, min(FRAME_PERIOD_STEPS * FRAME_PERIOD_MAX_TARGETS, steps))
    return target_ns * steps // FRAME_PERIOD_STEPS


def thread_share(cpu_delta_ns, total_delta_ns):
    """return a thread's share of session CPU time"""
    if total_delta_ns <= 0:
        return 0.0
    return cpu_delta_ns / total_delta_ns


def next_held_shares(held, window_shares):
    """return the thread shares at or above threshold"""
    return {tid: sh for tid, sh in window_shares.items()
            if sh >= (KEEP_SHARE if tid in held else MIN_SHARE)}


def rate_limit_ok(last_apply_s, now_s, min_interval_s=REAPPLY_MIN_INTERVAL_S):
    """return whether enough time has passed since the last apply"""
    return (now_s - last_apply_s) >= min_interval_s


def plan_grants(requests, cap_bw):
    """plan thread runtimes under the bandwidth cap"""
    best = {}
    for period_ns, runtimes in requests:
        for tid, rt in runtimes.items():
            if tid not in best or bandwidth(rt, period_ns) > bandwidth(*best[tid]):
                best[tid] = (rt, period_ns)
    requested_bw = sum(bandwidth(rt, period) for rt, period in best.values())
    if requested_bw <= cap_bw:
        return best, requested_bw, requested_bw, False
    floors = {tid: min(rt, MIN_THREAD_RUNTIME_NS) for tid, (rt, _period) in best.items()}
    floor_bw = sum(bandwidth(floors[tid], period) for tid, (_rt, period) in best.items())
    if floor_bw > cap_bw:
        kept, used = {}, 0.0
        for tid, (_rt, period) in sorted(best.items(), key=lambda kv: (bandwidth(floors[kv[0]], kv[1][1]), kv[0])):
            if used + bandwidth(floors[tid], period) <= cap_bw:
                kept[tid] = (floors[tid], period)
                used += bandwidth(floors[tid], period)
        return kept, requested_bw, used, True
    scale = (cap_bw - floor_bw) / (requested_bw - floor_bw)
    planned = {tid: (floors[tid] + int((rt - floors[tid]) * scale + 1e-6), period) for tid, (rt, period) in best.items()}
    return planned, requested_bw, sum(bandwidth(rt, period) for rt, period in planned.values()), True


def parse_cpu_max(text):
    """parse a cpu.max line"""
    parts = text.split()
    if (len(parts) != 2 or not parts[1].isdigit() or int(parts[1]) <= 0
            or not (parts[0] == "max" or parts[0].isdigit())):
        raise ValueError("bad cpu.max line: %r" % text)
    return (None if parts[0] == "max" else int(parts[0])), int(parts[1])


def format_cpu_max(cpu_max):
    """format a quota and period as a cpu.max value"""
    quota, period = cpu_max
    return "%s %d" % ("max" if quota is None else quota, period)


def tenant_weight(cpu_max, cpus):
    """return a tenant's size in CPUs"""
    if cpu_max is None or cpu_max[0] is None:
        return float(cpus)
    return cpu_max[0] / cpu_max[1]


def plan_slices(tenants, budgets_cap_bw, contain_cap_bw):
    """split the bandwidth caps across tenants"""
    total = sum(weight for weight, _capped in tenants.values())
    out = {}
    for key, (weight, capped) in tenants.items():
        share = weight / total
        budgets, contain = budgets_cap_bw * share, contain_cap_bw * share
        if capped and budgets + contain > TENANT_JOINT_CAP * weight:
            scale = TENANT_JOINT_CAP * weight / (budgets + contain)
            budgets, contain = budgets * scale, contain * scale
        out[key] = (budgets, contain)
    return out


def quantize_carve(reserved_bw):
    """round the carve up in CARVE_STEP_BW steps"""
    return math.ceil(reserved_bw / CARVE_STEP_BW - CARVE_EPS) * CARVE_STEP_BW if reserved_bw > CARVE_EPS else 0.0


def next_carve(carve_bw, reserved_bw, last_raise_s, now_s, max_carve_bw):
    """return the carve to write"""
    need = quantize_carve(reserved_bw)
    ceiling = max(max_carve_bw, reserved_bw)
    if reserved_bw > carve_bw + CARVE_EPS:
        return min(need + CARVE_STEP_BW, ceiling)
    if carve_bw <= CARVE_EPS or now_s - last_raise_s < CARVE_RAISE_MIN_S:
        return None
    if reserved_bw <= CARVE_EPS:
        return 0.0
    if carve_bw - need >= 2 * CARVE_STEP_BW - CARVE_EPS:
        return min(need + CARVE_STEP_BW, ceiling)
    return None


def carve_quota_us(configured, carve_bw):
    """return the cpu.max quota with the carve removed"""
    quota, period = configured
    return min(quota, max(CPU_MAX_MIN_QUOTA_US, quota - math.ceil(carve_bw * period - 1e-6)))


def ceiling_cgroup(init_cgroup):
    """trim the leaf cgroup from a cgroup path"""
    path = init_cgroup.strip()
    if path.endswith(" (deleted)"):
        return None
    for leaf in (INIT_CGROUP_LEAF, UNIT_CGROUP_CHILD):
        if path.endswith("/" + leaf):
            path = path[:-len(leaf) - 1]
    return path.rstrip("/") or None


def contain_thread_runtime_ns(rate, period_ns, ceiling_ns, run_ns=None):
    """return the runtime for a contained thread"""
    return int(min(ceiling_ns, max(MIN_THREAD_RUNTIME_NS, rate * period_ns * CONTAIN_HEADROOM,
                                   CONTAIN_RUN_HEADROOM * (run_ns or 0))))


def _nonneg_int(token, what):
    """parse a non-negative 64-bit integer"""
    if not token.isdigit():
        raise ProtocolError("%s must be a non-negative integer, got %r" % (what, token))
    if len(token) > 19 or int(token) > INT64_MAX:
        raise ProtocolError("%s must fit in 64 bits, got %d digits" % (what, len(token)))
    return int(token)


def _id_list(token, what):
    """parse a comma-separated list of non-negative integers"""
    pieces = token.split(",") if token else []
    if not pieces or any(p == "" for p in pieces):
        raise ProtocolError("%s is empty or malformed: %r" % (what, token))
    return [_nonneg_int(p, what) for p in pieces]


def _sid(token):
    """check and return a session id"""
    if not SID_RE.match(token):
        raise ProtocolError("sid %r is empty or contains whitespace/':'" % token)
    return token


def parse_message(line):
    """parse a wire line into a dict"""
    parts = line.split()
    if not parts:
        raise ProtocolError("empty message")
    cmd = parts[0]
    if cmd == "open":
        if len(parts) != 6:
            raise ProtocolError("open takes 5 arguments, got %d" % (len(parts) - 1))
        return {"cmd": "open", "sid": _sid(parts[1]), "tgid": _nonneg_int(parts[2], "tgid"),
                "uid": _nonneg_int(parts[3], "uid"), "target_ns": _nonneg_int(parts[4], "target_ns"),
                "tids": _id_list(parts[5], "tid list")}
    if cmd == "threads":
        if len(parts) != 3:
            raise ProtocolError("threads takes 2 arguments, got %d" % (len(parts) - 1))
        return {"cmd": "threads", "sid": _sid(parts[1]), "tids": _id_list(parts[2], "tid list")}
    if cmd == "target":
        if len(parts) != 3:
            raise ProtocolError("target takes 2 arguments, got %d" % (len(parts) - 1))
        return {"cmd": "target", "sid": _sid(parts[1]), "target_ns": _nonneg_int(parts[2], "target_ns")}
    if cmd == "actual":
        if len(parts) != 3:
            raise ProtocolError("actual takes 2 arguments, got %d" % (len(parts) - 1))
        return {"cmd": "actual", "sid": _sid(parts[1]),
                "durations_ns": _id_list(parts[2], "actual duration list")}
    if cmd in ("pause", "resume", "close"):
        if len(parts) != 2:
            raise ProtocolError("%s takes 1 argument, got %d" % (cmd, len(parts) - 1))
        return {"cmd": cmd, "sid": _sid(parts[1])}
    raise ProtocolError("unknown command %r" % cmd)


class RealProcView:
    def pids(self):
        """return the process ids listed in /proc"""
        try:
            return [int(n) for n in os.listdir("/proc") if n.isdigit()]
        except OSError:
            return []

    def tids_of(self, pid):
        """return the thread ids of a process"""
        try:
            return [int(n) for n in os.listdir("/proc/%d/task" % pid) if n.isdigit()]
        except OSError:
            return []

    def _status_field(self, tid, name):
        """return the fields of a /proc/<tid>/status line"""
        try:
            with open("/proc/%d/status" % tid) as f:
                for line in f:
                    if line.startswith(name + ":"):
                        return line.split()[1:]
        except OSError:
            return None
        return None

    def nspid_last(self, tid):
        """return the last namespace thread id of a thread, or None"""
        fields = self._status_field(tid, "NSpid")
        if not fields:
            return None
        try:
            return int(fields[-1])
        except ValueError:
            return None

    def ns_ino(self, tid):
        """return the pid namespace inode of a thread, or None"""
        try:
            return os.stat("/proc/%d/ns/pid" % tid).st_ino
        except OSError:
            return None

    def tgid_of(self, tid):
        """return the thread group id of a thread, or None"""
        fields = self._status_field(tid, "Tgid")
        if not fields:
            return None
        try:
            return int(fields[0])
        except ValueError:
            return None

    def real_uid(self, tid):
        """return the real user id of a thread, or None"""
        fields = self._status_field(tid, "Uid")
        if not fields:
            return None
        try:
            return int(fields[0])
        except ValueError:
            return None

    def comm(self, tid):
        """return the command name of a thread, or an empty string"""
        try:
            with open("/proc/%d/comm" % tid) as f:
                return f.read().strip()
        except OSError:
            return ""

    def schedstat_sum_exec(self, tid):
        """return the total run time of a thread from schedstat"""
        try:
            with open("/proc/%d/schedstat" % tid) as f:
                fields = f.read().split()
            return int(fields[0])
        except (OSError, IndexError, ValueError):
            return None

    def schedstat_run(self, tid):
        """read sum_exec_ns and pcount from schedstat"""
        try:
            with open("/proc/%d/schedstat" % tid) as f:
                fields = f.read().split()
            return int(fields[0]), int(fields[2])
        except (OSError, IndexError, ValueError):
            return None

    def sched_probe(self, tid):
        """read the scheduling attributes of a thread"""
        attr, errno = sched_getattr(tid)
        if attr is None:
            return None
        return attr.sched_policy, attr.sched_nice, attr.sched_priority

    def start_time(self, tid):
        """return a thread's start time in ticks"""
        try:
            with open("/proc/%d/stat" % tid) as f:
                stat = f.read()
            return int(stat[stat.rindex(")") + 2:].split()[19])
        except (OSError, ValueError, IndexError):
            return None

    def context(self, pid):
        """return the security context of a process"""
        return read_proc_attr_current(pid)

    def cmdline(self, pid):
        """return the argv of a process"""
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                return f.read().split(b"\0")
        except OSError:
            return []

    def exe_id(self, pid):
        """return the device and inode of a process's executable"""
        try:
            st = os.stat("/proc/%d/exe" % pid)
        except OSError:
            return None
        return (st.st_dev, st.st_ino)

    def root_file_id(self, pid, path):
        """return the device and inode of a path under a process's root"""
        try:
            st = os.stat("/proc/%d/root%s" % (pid, path))
        except OSError:
            return None
        return (st.st_dev, st.st_ino)

    def cgroup_path(self, pid):
        """return the cgroup2 path of a process"""
        try:
            with open("/proc/%d/cgroup" % pid) as f:
                for line in f:
                    if line.startswith("0::"):
                        return line[3:].rstrip("\n")
        except OSError:
            return None
        return None


class FakeProcView:
    """fabricated /proc for --selftest"""

    def __init__(self, procs, pid_tids):
        """store the fake process table and thread map"""
        self.procs = procs
        self.pid_tids = pid_tids

    def pids(self):
        """return the fake process ids"""
        return list(self.pid_tids)

    def tids_of(self, pid):
        """return the fake thread ids of a process"""
        return list(self.pid_tids.get(pid, ()))

    def nspid_last(self, tid):
        """return the fake last namespace thread id of a thread"""
        return self.procs.get(tid, {}).get("nspid_last")

    def ns_ino(self, tid):
        """return the fake pid namespace inode of a thread"""
        return self.procs.get(tid, {}).get("ns_ino")

    def tgid_of(self, tid):
        """return the fake thread group id of a thread"""
        return self.procs.get(tid, {}).get("tgid")

    def real_uid(self, tid):
        """return the fake user id of a thread"""
        return self.procs.get(tid, {}).get("uid")

    def comm(self, tid):
        """return the fake command name of a thread"""
        return self.procs.get(tid, {}).get("comm", "")

    def schedstat_sum_exec(self, tid):
        """return the fake total run time of a thread"""
        return self.procs.get(tid, {}).get("schedstat")

    def schedstat_run(self, tid):
        """return the fake run time and run count of a thread"""
        p = self.procs.get(tid, {})
        return None if p.get("schedstat") is None else (p["schedstat"], p.get("pcount", 0))

    def sched_probe(self, tid):
        """return the fake scheduler probe of a thread"""
        return self.procs.get(tid, {}).get("sched")

    def start_time(self, tid):
        """return the fake start time of a thread"""
        return self.procs.get(tid, {}).get("start")

    def context(self, pid):
        """return the fake security context of a process"""
        return self.procs.get(pid, {}).get("ctx")

    def cmdline(self, pid):
        """return the fake argv of a process"""
        return self.procs.get(pid, {}).get("cmdline", [])

    def exe_id(self, pid):
        """return the fake executable identity of a process"""
        return self.procs.get(pid, {}).get("exe")

    def root_file_id(self, pid, path):
        """return the fake identity of a path under a process's root"""
        return self.procs.get(pid, {}).get("root_files", {}).get(path)

    def cgroup_path(self, pid):
        """return the fake cgroup path of a process"""
        return self.procs.get(pid, {}).get("cgroup")


def translate_tgid(view, ns_ino, tgid_ns):
    """return the host tgid for a sandbox tgid"""
    for pid in view.pids():
        if view.ns_ino(pid) == ns_ino and view.nspid_last(pid) == tgid_ns:
            return pid
    return None


def translate_tid(view, ns_ino, host_tgid, tid_ns, uid):
    """return the host tid for a sandbox tid"""
    candidate = None
    for pid in view.pids():
        if view.ns_ino(pid) != ns_ino:
            continue
        for tid in view.tids_of(pid):
            if view.nspid_last(tid) == tid_ns:
                candidate = tid
                break
        if candidate is not None:
            break
    if candidate is None:
        return None, "no host thread maps sandbox tid %d in this peer's namespace" % tid_ns
    owner_tgid = view.tgid_of(candidate)
    if owner_tgid != host_tgid:
        return None, ("tid %d belongs to host tgid %s, not the hint session's host tgid %s"
                       % (tid_ns, owner_tgid, host_tgid))
    real_uid = view.real_uid(candidate)
    if real_uid != uid:
        return None, "tid %d real uid=%s, session uid=%d" % (tid_ns, real_uid, uid)
    return candidate, None


def so_peercred(conn):
    """return the pid, uid and gid of the peer of a socket"""
    data = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", data)
    return pid, uid, gid


def read_proc_attr_current(pid):
    """return the security context of a process"""
    try:
        with open("/proc/%d/attr/current" % pid) as f:
            return f.read().strip("\0").strip()
    except OSError:
        return None


def read_cgroup_file(path):
    """read a cgroup file unbuffered"""
    with open(path, "rb", buffering=0) as f:
        return f.read().decode()


def write_cgroup_file(path, text):
    """write text to a cgroup file"""
    fd = os.open(path, os.O_WRONLY | os.O_TRUNC)
    try:
        os.write(fd, text.encode())
    finally:
        os.close(fd)


def write_status_atomic(path, status):
    """write the status file through a temp file"""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(status, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def build_status(cpus, cap_percent, cap_bw, granted_bw, sessions, refusals, grants=None, tenants=None):
    """build the status dictionary from the caps, grants and sessions"""
    return {
        "cpus": cpus,
        "cap_percent": cap_percent,
        "cap_bw": cap_bw,
        "granted_bw": granted_bw,
        "grants": {str(tid): [rt, period] for tid, (rt, period, _prior) in (grants or {}).items()},
        "sessions": sessions,
        "refusals": list(refusals),
        "tenants": tenants or {},
    }


class RefusalLog:
    """log of refusal and cap lines"""

    def __init__(self, maxlen=REFUSALS_MAX):
        """keep the last lines in a bounded queue"""
        self._d = collections.deque(maxlen=maxlen)
        self._last = {}

    def record(self, line, key=None):
        """append a line to the refusal log"""
        if self._last.get(key) == line:
            return
        self._last[key] = line
        self._d.append(line)
        log(line)

    def snapshot(self):
        """return the recorded refusal lines"""
        return list(self._d)


def refuse_peer(refusals, pid, ctx, why=None):
    """record a refused peer"""
    refusals.record("refused peer pid=%d ctx=%r" % (pid, ctx) + ("" if why is None else " why=%s" % why))


def refuse_tid(refusals, tid, sid_key, reason):
    """record a refused thread and the reason"""
    refusals.record("refused tid=%d session=%s: %s" % (tid, sid_key, reason))


def record_cap_decision(refusals, requested_bw, granted_bw, cap_bw, pool, tenant):
    """record a bandwidth cap decision for a pool and tenant"""
    refusals.record("cap: requested=%.6f granted=%.6f cap=%.6f pool=%s tenant=%s"
                    % (requested_bw, granted_bw, cap_bw, pool, tenant), key=(pool, tenant))


class Thread:
    __slots__ = ("ns_tid", "comm", "policy", "prior")

    def __init__(self, ns_tid, comm, policy, prior):
        """set the thread fields"""
        self.ns_tid = ns_tid
        self.comm = comm
        self.policy = policy
        self.prior = prior

    def to_status(self, grant):
        """return the status entry of a thread with its grant"""
        return {"ns_tid": self.ns_tid, "comm": self.comm,
                "policy": "deadline" if grant else self.policy,
                "runtime_ns": grant[0] if grant else 0, "prior": self.prior}


class ContainedThread:
    """record of a contained thread"""
    __slots__ = ("ns_tid", "comm", "prior_policy", "prior_priority", "tenant", "sample_t", "sample_ns",
                 "sample_pc", "rate", "run_ns", "unreadable", "sized_by")

    def __init__(self, ns_tid, comm, prior_policy, prior_priority, tenant=None):
        """set the contained thread fields"""
        self.ns_tid = ns_tid
        self.comm = comm
        self.prior_policy = prior_policy
        self.prior_priority = prior_priority
        self.tenant = tenant
        self.sample_t = None
        self.sample_ns = None
        self.sample_pc = None
        self.rate = None
        self.run_ns = None
        self.unreadable = False
        self.sized_by = None

    def to_status(self, grant):
        """return the status entry of a contained thread"""
        return {"ns_tid": self.ns_tid, "comm": self.comm,
                "policy": "deadline" if grant else _RT_POLICY_NAME.get(self.prior_policy, "?"),
                "runtime_ns": grant[0] if grant else 0, "cpu_rate": self.rate, "cpu_run_ns": self.run_ns, "sized_by": self.sized_by,
                "prior": "%s:%d" % (_RT_POLICY_NAME.get(self.prior_policy, "?"), self.prior_priority)}


class Session:
    def __init__(self, sid, conn_id, peer_pid, tgid_ns, host_tgid, uid, period_ns):
        """set the session fields"""
        self.sid = sid
        self.conn_id = conn_id
        self.peer_pid = peer_pid
        self.tgid_ns = tgid_ns
        self.host_tgid = host_tgid
        self.uid = uid
        self.period_ns = period_ns
        self.state = "active"
        self.threads = {}
        self.history = collections.deque(maxlen=HISTORY_MAX)
        self.frame_cpu = {}
        self.frame_interval = collections.deque(maxlen=FRAME_INTERVAL_HISTORY)
        self.reports = collections.deque(maxlen=2 * HISTORY_MAX)
        self.report_schedstat = {}
        self.sample_time = None
        self.frames_since_sample = 0
        self.prev_schedstat = {}
        self.window_start = None
        self.held = {}
        self.last_actual = None
        self.helpers = {}
        self.helpers_for = frozenset()
        self.helpers_scanned = None

    def idle(self, now):
        """return whether the session is idle"""
        return self.last_actual is None or now - self.last_actual > IDLE_RELEASE_S

    def grant_period_ns(self):
        """return the period to grant for the session's frame interval"""
        return frame_period_ns(self.frame_interval, self.period_ns)

    def forget_thread(self, tid):
        """forget a thread's frame and schedstat samples"""
        self.frame_cpu.pop(tid, None)
        self.report_schedstat.pop(tid, None)

    def thread_status(self, tid, th, grants):
        """return the status entry of a thread with its frame CPU time"""
        out = th.to_status(grants.get(tid))
        out["frame_cpu_ns"] = frame_cpu_ns(self.frame_cpu.get(tid))
        return out

    def to_status(self, grants, now):
        """return the status entry of a session"""
        state = "idle" if self.state == "active" and self.idle(now) else self.state
        return {
            "peer_pid": self.peer_pid, "tgid_ns": self.tgid_ns, "uid": self.uid,
            "state": state, "period_ns": self.period_ns,
            "frame_interval_mean_ns": sum(self.frame_interval) // len(self.frame_interval) if self.frame_interval else None,
            "grant_period_ns": self.grant_period_ns(),
            "reports": [[round((t - self.reports[-1][0]) * 1e3, 3), n] for t, n in self.reports],
            "reported_p90_ns": p90(self.history) if self.history else 0,
            "threads": {str(tid): self.thread_status(tid, th, grants) for tid, th in self.threads.items()},
            "helpers": {str(tid): self.thread_status(tid, th, grants) for tid, th in self.helpers.items()},
        }


class Connection:
    def __init__(self, conn_id, sock, peer_pid, ns_ino):
        """set the connection fields"""
        self.conn_id = conn_id
        self.sock = sock
        self.peer_pid = peer_pid
        self.ns_ino = ns_ino
        self.sessions = {}


class Tenant:
    """sandbox pid namespace with its cgroup"""
    __slots__ = ("key", "ns_ino", "cgroup")

    def __init__(self, ns_ino, cgroup):
        """store the pid namespace inode and cgroup"""
        self.ns_ino = ns_ino
        self.cgroup = cgroup
        self.key = cgroup if cgroup is not None else "ns-%s" % ns_ino


class CarveState:
    __slots__ = ("configured", "written", "carve_bw", "last_raise", "read_error")

    def __init__(self):
        """set the carve state fields"""
        self.configured = None
        self.written = None
        self.carve_bw = 0.0
        self.last_raise = -math.inf
        self.read_error = None


class CarveBook:
    """Carve-out of tenant cpu.max quotas"""

    def __init__(self, cgroup_fs, record_path, log_fn=log):
        """set the carve book fields"""
        self.cgroup_fs = cgroup_fs
        self.record_path = record_path
        self.log = log_fn
        self.states = {}
        self.grant_records = []

    def _path(self, key):
        """return the path of a cgroup's cpu.max file"""
        return os.path.join(self.cgroup_fs, key.lstrip("/"), "cpu.max")

    def _read(self, key):
        """read the cpu.max of a tenant cgroup"""
        try:
            return parse_cpu_max(read_cgroup_file(self._path(key))), None
        except FileNotFoundError:
            return None, None
        except (OSError, ValueError) as exc:
            return None, str(exc)

    def _persist(self):
        """write the carve and grant records to the record file"""
        carve = {key: {"configured": format_cpu_max(st.configured), "written": format_cpu_max(st.written)}
                 for key, st in self.states.items() if st.written is not None}
        record = {"carve": carve, "grants": self.grant_records}
        try:
            write_status_atomic(self.record_path, record)
        except OSError as exc:
            self.log("could not write %s: %s" % (self.record_path, exc))

    def set_grants(self, records):
        """record the held grants"""
        if records != self.grant_records:
            self.grant_records = records
            self._persist()

    def sync(self, key):
        """read the live cpu.max of a tenant"""
        st = self.states.setdefault(key, CarveState())
        live, error = self._read(key)
        if error is not None and error != st.read_error:
            self.log("carve: tenant=%s cannot read cpu.max: %s" % (key, error))
        st.read_error = error
        if live is None:
            changed = st.written is not None
            st.configured, st.written, st.carve_bw = None, None, 0.0
            if changed:
                self._persist()
            return st
        if st.written is not None and live != st.written:
            self.log("carve: tenant=%s live cpu.max=%s is not what was written (%s), adopting it as configured"
                     % (key, format_cpu_max(live), format_cpu_max(st.written)))
            st.written, st.carve_bw = None, 0.0
            self._persist()
        if st.written is None:
            st.configured = live
        return st

    def capped(self, key):
        """return whether a cgroup has a CPU quota"""
        st = self.states.get(key)
        return st is not None and st.configured is not None and st.configured[0] is not None

    def configured_weight(self, key, cpus):
        """return the weight of a cgroup's configured cpu.max"""
        st = self.states.get(key)
        return tenant_weight(st.configured if st is not None else None, cpus)

    def _max_carve(self, st):
        """return the largest bandwidth that may be carved from a cgroup"""
        return TENANT_JOINT_CAP * tenant_weight(st.configured, 0)

    def _write(self, key, st, target_bw, reserved_bw, now):
        """write the cgroup's cpu.max for a target bandwidth"""
        period = st.configured[1]
        new = (carve_quota_us(st.configured, target_bw), period) if target_bw > CARVE_EPS else st.configured
        try:
            write_cgroup_file(self._path(key), format_cpu_max(new))
        except OSError as exc:
            self.log("carve: tenant=%s cannot write cpu.max=%s: %s" % (key, format_cpu_max(new), exc))
            return False
        if target_bw < st.carve_bw:
            st.last_raise = now
        st.carve_bw = target_bw
        if target_bw > CARVE_EPS:
            st.written = new
            self.log("carve: tenant=%s reserved=%.6f cpu.max=%s configured=%s"
                     % (key, reserved_bw, format_cpu_max(new), format_cpu_max(st.configured)))
        else:
            st.written = None
            self.log("carve-restore: tenant=%s cpu.max=%s" % (key, format_cpu_max(new)))
        self._persist()
        return True

    def ensure(self, key, reserved_bw, now):
        """lower the cpu.max quota to fit reserved_bw"""
        if not self.capped(key):
            return True
        st = self.states[key]
        if reserved_bw <= st.carve_bw + CARVE_EPS:
            return True
        st = self.sync(key)
        if not self.capped(key):
            return True
        target = next_carve(st.carve_bw, reserved_bw, st.last_raise, now, self._max_carve(st))
        return target is None or self._write(key, st, target, reserved_bw, now)

    def settle(self, key, reserved_bw, now, check_live=False):
        """raise the cpu.max quota"""
        st = self.sync(key) if check_live else self.states.get(key)
        if st is None or not self.capped(key):
            return
        target = next_carve(st.carve_bw, reserved_bw, st.last_raise, now, self._max_carve(st))
        if target is not None:
            self._write(key, st, target, reserved_bw, now)

    def restore(self, key):
        """write the configured cpu.max back"""
        st = self.states.get(key)
        if st is None or st.written is None:
            return False
        wrote = False
        live, error = self._read(key)
        if live is None and error is None:
            self.log("carve-restore: tenant=%s cgroup is gone" % key)
        elif live is None:
            self.log("carve-restore: tenant=%s cannot read cpu.max: %s" % (key, error))
        elif live != st.written:
            self.log("carve-restore: tenant=%s left alone, live cpu.max=%s is not what was written (%s)"
                     % (key, format_cpu_max(live), format_cpu_max(st.written)))
        else:
            try:
                write_cgroup_file(self._path(key), format_cpu_max(st.configured))
                wrote = True
                self.log("carve-restore: tenant=%s cpu.max=%s" % (key, format_cpu_max(st.configured)))
            except OSError as exc:
                self.log("carve-restore: tenant=%s cannot write cpu.max=%s: %s"
                         % (key, format_cpu_max(st.configured), exc))
        st.written, st.carve_bw = None, 0.0
        self._persist()
        return wrote

    def release(self, key):
        """restore a cgroup's cpu.max and forget its state"""
        self.restore(key)
        self.states.pop(key, None)

    def restore_all(self):
        """restore the cpu.max of every cgroup"""
        for key in list(self.states):
            self.restore(key)

    def recover(self, revoke_grants=None):
        """revoke recorded grants and restore quotas"""
        try:
            with open(self.record_path) as f:
                record = json.load(f)
        except FileNotFoundError:
            return
        except (OSError, ValueError) as exc:
            self.log("carve: cannot read %s: %s" % (self.record_path, exc))
            return
        carve_rec, grants = (record.get("carve", {}), record.get("grants", [])) if (
            "carve" in record or "grants" in record) else (record, [])
        revoked = skipped = restored = 0
        if grants and revoke_grants is not None:
            revoked, skipped = revoke_grants(grants)
        loaded = []
        for key, rec in carve_rec.items():
            try:
                written, configured = parse_cpu_max(rec["written"]), parse_cpu_max(rec["configured"])
            except (KeyError, TypeError, ValueError) as exc:
                self.log("carve: record for tenant=%s is unreadable: %r (%s)" % (key, rec, exc))
                continue
            st = CarveState()
            st.configured, st.written = configured, written
            self.states[key] = st
            loaded.append(key)
        for key in loaded:
            restored += bool(self.restore(key))
        for key in loaded:
            self.states.pop(key, None)
        self.grant_records = []
        self._persist()
        if grants or carve_rec:
            self.log("recover: revoked=%d skipped=%d restored=%d" % (revoked, skipped, restored))


def sd_notify_ready():
    """send READY=1 to systemd"""
    path = os.environ.get("NOTIFY_SOCKET")
    if not path:
        return
    addr = "\0" + path[1:] if path.startswith("@") else path
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC)
    try:
        s.sendto(b"READY=1", addr)
    except OSError as exc:
        log("could not tell systemd it is ready: %s" % exc)
    finally:
        s.close()


class Daemon:
    def __init__(self, socket_path, status_path, cap_percent, view=None, clock=time.monotonic,
                 contain_enabled=False, contain_cap_percent=0,
                 contain_runtime_ns=0, contain_period_ns=0, self_reserve=False, cgroup_fs=CGROUP_FS,
                 hard_period=("2ms", HARD_PERIOD_NS), selinux_mode="host"):
        """set the initial rhizo-rtd state"""
        self.selinux_mode = selinux_mode
        self.socket_path = socket_path
        self.status_path = status_path
        self.cap_percent = cap_percent
        self.hard_period_name, self.hard_period_ns = hard_period
        self.cpus = online_cpu_count()
        self.cap_bw = cap_bandwidth(cap_percent, self.cpus)
        self.view = view if view is not None else RealProcView()
        self.clock = clock
        self.refusals = RefusalLog()
        self.connections = {}
        self.grants = {}
        self.identity = {}
        self._last_apply = {}
        self._next_conn_id = 1
        self._last_sweep = clock()
        self.sel = selectors.DefaultSelector()
        self.contain_enabled = contain_enabled
        self.contain_cap_percent = contain_cap_percent
        self.contain_cap_bw = cap_bandwidth(contain_cap_percent, self.cpus) if contain_enabled else 0.0
        self.contain_runtime_ns = contain_runtime_ns
        self.contain_period_ns = contain_period_ns
        self.contained = {}
        self.contain_grants = {}
        self.carve = CarveBook(cgroup_fs, os.path.join(os.path.dirname(status_path), CARVE_RECORD_NAME))
        self.tenant_table = {}
        self.grant_tenant = {}
        self.dl_cpu_ns = {}
        self.dl_sample = {}
        self.reclaim_revoked = {}
        self.reclaim_check = {}
        self.reclaim_retry = {}
        self.demand = {}
        self.demand_opened = clock()
        self.demand_last = {}
        self.demand_over = {}
        self.demand_logged = {}
        self._warned_tenants = set()
        self.sandbox_ns_ino = None
        self.self_reserve = self_reserve
        self.self_reservation = ({"runtime_ns": SELF_RESERVE_RUNTIME_NS,
                                   "period_ns": SELF_RESERVE_PERIOD_NS, "granted": False}
                                  if self_reserve else None)
        self._tick_needed = True
        self._status_at = None
        self._status_grants = None

    def total_granted_bw(self):
        """return the total granted bandwidth"""
        return sum(bandwidth(rt, period) for rt, period, _prior in self.grants.values())

    def _contain_tenant(self, tid):
        """return the tenant of a contained thread, or None"""
        ct = self.contained.get(tid)
        return ct.tenant if ct is not None else None

    def _tid_tenant(self, tid):
        """return the tenant of a contained or granted thread"""
        ct = self.contained.get(tid)
        return ct.tenant if ct is not None else self.grant_tenant.get(tid)

    def reserved_bw(self, key):
        """return a tenant's reserved bandwidth"""
        total = sum(bandwidth(rt, period) for tid, (rt, period, _prior) in self.grants.items()
                    if self.grant_tenant.get(tid) == key)
        return total + sum(bandwidth(rt, period) for tid, (rt, period) in self.contain_grants.items()
                           if self._contain_tenant(tid) == key)

    def sandbox_init_pids(self):
        """return the host pid of each sandbox init"""
        own = self.view.ns_ino(os.getpid())
        wanted = {c.ns_ino for c in self.connections.values() if c.ns_ino is not None}
        if self.sandbox_ns_ino is not None:
            wanted.add(self.sandbox_ns_ino)
        found = {ino: None for ino in wanted}
        for pid in self.view.pids():
            if self.view.nspid_last(pid) != 1:
                continue
            ino = self.view.ns_ino(pid)
            if ino is not None and ino != own and (ino in wanted or self.is_sandbox_init(pid)):
                found[ino] = pid
        return found

    def is_sandbox_init(self, pid):
        """return whether a pid namespace's pid 1 is a sandbox init"""
        if self.selinux_mode != "namespace":
            return self.view.context(pid) == ANDROID_INIT_CTX
        cgroup = self.view.cgroup_path(pid)
        return (self.view.cmdline(pid)[:2] == ANDROID_INIT_ARGV and cgroup is not None
                and RHIZO_STACK_RE.match(cgroup.rstrip("/") + "/") is not None)

    def namespace_peer_refusal(self, pid, uid):
        """return why a namespace-mode peer is not the power HAL, or None"""
        ino = self.view.ns_ino(pid)
        if ino is None:
            return "its-pid-namespace-unreadable"
        if ino == self.view.ns_ino(os.getpid()):
            return "not-in-a-sandbox-pid-namespace"
        init = None
        for cand in self.view.pids():
            if self.view.nspid_last(cand) == 1 and self.view.ns_ino(cand) == ino and self.is_sandbox_init(cand):
                init = cand
                break
        if init is None:
            return "its-pid-namespace-has-no-sandbox-init"
        if uid != AID_SYSTEM:
            return "uid-%d-not-%d" % (uid, AID_SYSTEM)
        want = self.view.root_file_id(init, POWER_HAL_PATH)
        if want is None or self.view.exe_id(pid) != want:
            return "executable-not-the-sandbox's-%s" % POWER_HAL_PATH
        return None

    def _resolve_tenant(self, ino, pid1):
        """find the tenant of a namespace from its pid 1 cgroup"""
        if pid1 is None:
            why = "no pid 1 found in its namespace"
        else:
            line = self.view.cgroup_path(pid1)
            cgroup = ceiling_cgroup(line) if line else None
            if cgroup is not None:
                return Tenant(ino, cgroup)
            why = "pid 1 (host pid %d) has cgroup %r" % (pid1, line)
        if ino not in self._warned_tenants:
            self._warned_tenants.add(ino)
            log("tenant ns=%s has no ceiling cgroup (%s): no cpu.max carve-out, its weight is every cpu" % (ino, why))
        return Tenant(ino, None)

    def refresh_tenants(self):
        """refresh the tenant table and cpu.max values"""
        table = {ino: self._resolve_tenant(ino, pid1) for ino, pid1 in self.sandbox_init_pids().items()}
        self.tenant_table = table
        live = {t.cgroup for t in table.values() if t.cgroup is not None}
        for cgroup in sorted(live):
            self.carve.sync(cgroup)
        for key in [k for k in self.carve.states if k not in live]:
            self.carve.release(key)

    def tenant_of_ino(self, ino):
        """return the tenant of a namespace inode"""
        return self.tenant_table.get(ino) or Tenant(ino, None)

    def tenants_now(self):
        """return the tenants of all sandboxes and connections"""
        out = {t.key: t for t in self.tenant_table.values()}
        for c in self.connections.values():
            tenant = self.tenant_of_ino(c.ns_ino)
            out.setdefault(tenant.key, tenant)
        return out

    def slices(self):
        """return the cap slice of each tenant"""
        weights = {key: (self.carve.configured_weight(key, self.cpus), self.carve.capped(key))
                   for key in self.tenants_now()}
        return plan_slices(weights, self.cap_bw, self.contain_cap_bw)

    def tenants_status(self):
        """return the status entry of each tenant"""
        slices = self.slices()
        out = {}
        for key, tenant in self.tenants_now().items():
            st = self.carve.states.get(key)
            budgets, contain = slices.get(key, (0.0, 0.0))
            last = self.demand_last.get(key, {})
            out[key] = {
                "ns_ino": tenant.ns_ino,
                "weight": self.carve.configured_weight(key, self.cpus),
                "slice_budgets": budgets, "slice_contain": contain,
                "reserved_bw": self.reserved_bw(key),
                "cpu_max_configured": format_cpu_max(st.configured) if st is not None and st.configured else None,
                "cpu_max_written": format_cpu_max(st.written) if st is not None and st.written else None,
                "reclaim": self._reclaim_for(key),
                "reclaim_revoked_at": self.reclaim_revoked.get(key),
                "dl_cpu_ns": self.dl_cpu_ns.get(key, 0),
                "request_p50": last.get("p50"), "request_p95": last.get("p95"), "request_max": last.get("max"),
                "request_samples": last.get("samples", 0), "request_window_s": last.get("window_s"),
                "request_windows": last.get("windows", 0), "windows_over_slice": self.demand_over.get(key, 0),
            }
        return out

    def _sample_demand(self, requested, slices):
        """record each tenant's requested bandwidth sample"""
        for key, (budgets, _contain) in slices.items():
            self.demand.setdefault(key, []).append((requested.get(key, 0.0), budgets))

    def _close_demand_window(self, now):
        """close the demand window into per-tenant stats"""
        live = set(self.tenants_now())
        window_s, self.demand_opened = now - self.demand_opened, now
        plans_by_key, self.demand = self.demand, {}
        for table in (self.demand_last, self.demand_over, self.demand_logged):
            for key in [k for k in table if k not in live]:
                del table[key]
        for key in sorted(live, key=str):
            plans = plans_by_key.get(key, [])
            reqs = [r for r, _slice in plans]
            self.demand_last[key] = {
                "p50": percentile(reqs, 0.5) if reqs else 0.0, "p95": percentile(reqs, 0.95) if reqs else 0.0,
                "max": max(reqs) if reqs else 0.0, "samples": len(reqs), "window_s": window_s,
                "windows": self.demand_last.get(key, {}).get("windows", 0) + 1}
            if not plans or not self.carve.capped(key) or any(r <= sl + CARVE_EPS for r, sl in plans):
                continue
            self.demand_over[key] = self.demand_over.get(key, 0) + 1
            if now - self.demand_logged.get(key, -math.inf) >= DEMAND_LOG_MIN_S:
                self.demand_logged[key] = now
                last = self.demand_last[key]
                log("demand-over-slice: tenant=%s p50=%.3f p95=%.3f max=%.3f slice=%.3f windows=%d"
                    % (key, last["p50"], last["p95"], last["max"], plans[-1][1], self.demand_over[key]))

    def _reclaim_for(self, key):
        """return whether a tenant has not had reclaim revoked"""
        return key not in self.reclaim_revoked

    def _for_tenant(self, desired, key):
        """return the plan adjusted for RECLAIM"""
        if self._reclaim_for(key):
            return desired
        return {tid: hard_grant(rt, period, self.hard_period_ns) for tid, (rt, period) in desired.items()}

    def _check_overruns(self, now):
        """revoke RECLAIM from overrunning capped tenants"""
        live = set(self.tenants_now())
        for key in [k for k in self.reclaim_revoked if k not in live]:
            del self.reclaim_revoked[key]
            self.reclaim_retry.pop(key, None)
        for key in list(self.reclaim_check):
            if key not in live or not self.carve.capped(key):
                del self.reclaim_check[key]
        for key in sorted(live, key=str):
            if not self.carve.capped(key):
                continue
            used_ns, reserved = self.dl_cpu_ns.get(key, 0), self.reserved_bw(key)
            prev = self.reclaim_check.get(key)
            if prev is not None and now - prev[1] <= 0:
                continue
            self.reclaim_check[key] = (used_ns, now, reserved)
            if prev is None or key in self.reclaim_revoked:
                continue
            used = (used_ns - prev[0]) / 1e9 / (now - prev[1])
            if used > max(prev[2], reserved) + RECLAIM_OVERRUN_MARGIN:
                self.reclaim_revoked[key] = now
                log("reclaim-off: tenant=%s used=%.3f reserved=%.3f" % (key, used, reserved))
                self.reclaim_retry[key] = {tid for tid in self.grants if self.grant_tenant.get(tid) == key} | {
                    tid for tid in self.contain_grants if self._contain_tenant(tid) == key}
        for key in [k for k, tids in self.reclaim_retry.items() if tids]:
            self._regrant_without_reclaim(key)

    def _regrant_without_reclaim(self, key):
        """regrant a tenant's threads with RECLAIM off"""
        failed = set()
        for tid in sorted(self.reclaim_retry.get(key, ())):
            if tid in self.grants and self.grant_tenant.get(tid) == key:
                rt, period = hard_grant(*self.grants[tid][:2], hard_period_ns=self.hard_period_ns)
            elif tid in self.contain_grants and self._contain_tenant(tid) == key:
                rt, period = hard_grant(*self.contain_grants[tid], hard_period_ns=self.hard_period_ns)
            else:
                continue
            if not self._same_thread(tid):
                continue
            ok, errno = grant_deadline(tid, rt, period, reclaim=False)
            if not ok:
                log("tid=%d: regrant without reclaim failed, errno=%d runtime=%d period=%d" % (tid, errno, rt, period))
                failed.add(tid)
            elif tid in self.grants:
                self.grants[tid] = (rt, period, self.grants[tid][2])
            else:
                self.contain_grants[tid] = (rt, period)
        self.reclaim_retry[key] = failed

    def _dl_start(self, tid):
        """store the thread's CPU time sample"""
        v = self.view.schedstat_sum_exec(tid)
        if v is not None:
            self.dl_sample[tid] = v

    def _dl_account(self, tid):
        """add the CPU time a thread used since its sample to its tenant"""
        prev, v = self.dl_sample.get(tid), self.view.schedstat_sum_exec(tid)
        if prev is None or v is None:
            return
        key = self._tid_tenant(tid)
        self.dl_cpu_ns[key] = self.dl_cpu_ns.get(key, 0) + max(0, v - prev)
        self.dl_sample[tid] = v

    def _dl_stop(self, tid):
        """account a thread's CPU time and drop its sample"""
        self._dl_account(tid)
        self.dl_sample.pop(tid, None)

    def _grant_records(self, ahead=()):
        """return a record per held grant"""
        out = []
        for tid, (_rt, _period, prior) in sorted(self.grants.items()):
            ident = self.identity.get(tid)
            if ident is not None:
                out.append({"tid": tid, "pool": "budgets", "identity": list(ident), "prior": prior,
                            "tenant": self.grant_tenant.get(tid)})
        for tid in sorted(self.contain_grants):
            ident, ct = self.identity.get(tid), self.contained.get(tid)
            if ident is not None and ct is not None:
                out.append({"tid": tid, "pool": "contain", "identity": list(ident), "policy": ct.prior_policy,
                            "priority": ct.prior_priority, "tenant": ct.tenant})
        return out + list(ahead)

    def _sync_record(self):
        """save the grant records into the carve book"""
        self.carve.set_grants(self._grant_records())

    def _record_ahead(self, rec):
        """record rec with the held grants"""
        self.carve.set_grants(self._grant_records([rec]))

    def _recover_grants(self, records):
        """revoke each recorded grant"""
        revoked = skipped = 0
        for rec in records:
            try:
                tid, ident = int(rec["tid"]), tuple(rec["identity"])
                if rec["pool"] == "budgets":
                    name, nice = rec["prior"].split(":")
                    policy, nice, priority = _POLICY_FOR_NAME.get(name, SCHED_OTHER), int(nice), 0
                else:
                    policy, nice, priority = int(rec["policy"]), 0, int(rec["priority"])
            except (KeyError, TypeError, ValueError, AttributeError) as exc:
                log("recover: unreadable grant record %r (%s)" % (rec, exc))
                skipped += 1
                continue
            have = (self.view.tgid_of(tid), self.view.real_uid(tid), self.view.start_time(tid))
            if have != ident:
                log("recover: tid=%d is gone or reused (recorded %r, now %r), skipped" % (tid, ident, have))
                skipped += 1
                continue
            probe = self.view.sched_probe(tid)
            if probe is None or probe[0] != SCHED_DEADLINE:
                log("recover: tid=%d is no longer SCHED_DEADLINE (probe %r), skipped" % (tid, probe))
                skipped += 1
                continue
            ok, errno = revoke_to_prior(tid, policy, nice, priority)
            if not ok:
                log("recover: tid=%d revoke failed, errno=%d" % (tid, errno))
                skipped += 1
                continue
            log("recover: revoke tid=%d -> policy %d nice %d priority %d" % (tid, policy, nice, priority))
            revoked += 1
        return revoked, skipped

    def _carve_ahead(self, tenant, desired, held, now):
        """lower the tenant's quota for a grant batch"""
        peak = sum(max(held.get(tid, 0.0), bandwidth(*d)) for tid, d in desired.items())
        others = self.reserved_bw(tenant) - sum(held.get(tid, 0.0) for tid in desired)
        self.carve.ensure(tenant, others + peak, now)

    def _reserve_self(self):
        """request the SCHED_DEADLINE reservation for rhizo-rtd"""
        if not self.self_reserve:
            return
        ok, errno = reserve_self(os.getpid())
        if ok:
            self.self_reservation = {"runtime_ns": SELF_RESERVE_RUNTIME_NS,
                                      "period_ns": SELF_RESERVE_PERIOD_NS, "granted": True}
            log("self-reserve: runtime=%d period=%d granted" % (SELF_RESERVE_RUNTIME_NS, SELF_RESERVE_PERIOD_NS))
        else:
            self.self_reservation = {"runtime_ns": SELF_RESERVE_RUNTIME_NS,
                                      "period_ns": SELF_RESERVE_PERIOD_NS, "granted": False, "errno": errno}
            log("self-reserve FAILED: runtime=%d period=%d errno=%d (%s) -- rhizo-rtd keeps running SCHED_OTHER"
                % (SELF_RESERVE_RUNTIME_NS, SELF_RESERVE_PERIOD_NS, errno, os.strerror(errno)))

    def write_status(self):
        """write the status file"""
        sessions = {}
        for conn in self.connections.values():
            for sid, s in conn.sessions.items():
                sessions["%s:%s" % (conn.conn_id, sid)] = s.to_status(self.grants, self.clock())
        status = build_status(self.cpus, self.cap_percent, self.cap_bw,
                               self.total_granted_bw(), sessions, self.refusals.snapshot(), self.grants,
                               self.tenants_status())
        status["hard_period"] = self.hard_period_name
        if self.contain_enabled:
            status["contain_percent"] = self.contain_cap_percent
            status["contain_cap_bw"] = self.contain_cap_bw
            status["contain_granted_bw"] = sum(bandwidth(rt, period)
                                                for rt, period in self.contain_grants.values())
            status["contain_grants"] = {str(tid): [rt, period]
                                         for tid, (rt, period) in self.contain_grants.items()}
            status["contained"] = {str(tid): th.to_status(self.contain_grants.get(tid))
                                    for tid, th in self.contained.items()}
        if self.self_reserve:
            status["self_reservation"] = self.self_reservation
        try:
            write_status_atomic(self.status_path, status)
        except OSError as exc:
            log("could not write %s: %s" % (self.status_path, exc))
        self._status_at, self._status_grants = self.clock(), self._grant_signature()

    def _grant_signature(self):
        """return the granted runtimes and periods of both pools"""
        return (sorted((tid, rt, period) for tid, (rt, period, _prior) in self.grants.items()),
                sorted(self.contain_grants.items()))

    def _write_status_when_due(self):
        """write the status file when due"""
        if (self._status_at is None or self._grant_signature() != self._status_grants
                or self.clock() - self._status_at >= STATUS_WRITE_INTERVAL_S):
            self.write_status()

    def accept(self, listener):
        """accept a connection and check its peer"""
        try:
            conn, _ = listener.accept()
        except OSError as exc:
            log("accept failed: %s" % exc)
            return
        try:
            pid, uid, _gid = so_peercred(conn)
        except OSError as exc:
            log("could not read SO_PEERCRED on a new connection: %s" % exc)
            conn.close()
            return
        ctx = read_proc_attr_current(pid)
        why = self.namespace_peer_refusal(pid, uid) if self.selinux_mode == "namespace" else None
        if why is not None or (self.selinux_mode != "namespace" and ctx != REQUIRED_PEER_CTX):
            refuse_peer(self.refusals, pid, ctx, why)
            conn.close()
            return
        try:
            ns_ino = os.stat("/proc/%d/ns/pid" % pid).st_ino
        except OSError as exc:
            log("refused peer pid=%d: cannot stat its pid namespace: %s" % (pid, exc))
            conn.close()
            return
        conn_id = self._next_conn_id
        self._next_conn_id += 1
        c = Connection(conn_id, conn, pid, ns_ino)
        self.connections[conn_id] = c
        conn.setblocking(False)
        self.sel.register(conn, selectors.EVENT_READ, c)
        self.sandbox_ns_ino = ns_ino
        self.refresh_tenants()
        log("accepted peer pid=%d as conn=%d" % (pid, conn_id))

    def on_readable(self, c):
        """read and dispatch a message"""
        try:
            data = c.sock.recv(MAX_PACKET + 1)
        except BlockingIOError:
            return False
        except OSError as exc:
            log("conn=%d: read error, closing: %s" % (c.conn_id, exc))
            self.drop_connection(c)
            return False
        if not data:
            log("conn=%d (peer pid=%d) closed" % (c.conn_id, c.peer_pid))
            self.drop_connection(c)
            return False
        if len(data) > MAX_PACKET:
            log("conn=%d: oversized message (%d bytes), closing" % (c.conn_id, len(data)))
            self.drop_connection(c)
            return False
        try:
            line = data.decode("ascii")
        except UnicodeDecodeError as exc:
            log("conn=%d: message is not ASCII, dropped: %s" % (c.conn_id, exc))
            return True
        try:
            msg = parse_message(line)
        except ProtocolError as exc:
            log("conn=%d: %s" % (c.conn_id, exc))
            return True
        self.dispatch(c, msg)
        return True

    def drop_connection(self, c):
        """drop a connection and its sessions"""
        c.sessions.clear()
        try:
            self.sel.unregister(c.sock)
        except (KeyError, ValueError):
            pass
        c.sock.close()
        del self.connections[c.conn_id]
        self.tick()
        self.write_status()

    def dispatch(self, c, msg):
        """run the method for the message command"""
        cmd = msg["cmd"]
        if cmd == "open":
            self.handle_open(c, msg)
        elif cmd == "threads":
            self.handle_threads(c, msg)
        elif cmd == "target":
            self.handle_target(c, msg)
        elif cmd == "actual":
            self.handle_actual(c, msg)
        elif cmd == "pause":
            self.handle_pause(c, msg)
        elif cmd == "resume":
            self.handle_resume(c, msg)
        elif cmd == "close":
            self.handle_close(c, msg)

    def _status_key(self, c, sid):
        """return the status key of a session"""
        return "%s:%s" % (c.conn_id, sid)

    def _register_tids(self, c, s, tid_list):
        """register the sandbox tids of a session"""
        for tid_ns in tid_list:
            host_tid, reason = translate_tid(self.view, c.ns_ino, s.host_tgid, tid_ns, s.uid)
            if host_tid is None:
                refuse_tid(self.refusals, tid_ns, self._status_key(c, s.sid), reason)
                continue
            if host_tid in s.threads:
                continue
            ident = (s.host_tgid, s.uid, self.view.start_time(host_tid))
            if host_tid in self.identity and self.identity[host_tid] != ident:
                self._forget(host_tid)
            self.identity[host_tid] = ident
            comm = self.view.comm(host_tid)
            if host_tid in self.grants:
                s.threads[host_tid] = Thread(tid_ns, comm, "other", prior=self.grants[host_tid][2])
                continue
            probe = self.view.sched_probe(host_tid)
            if probe is None:
                refuse_tid(self.refusals, tid_ns, self._status_key(c, s.sid),
                           "cannot read its current scheduling policy")
                continue
            policy, nice, _priority = probe
            if not thread_is_eligible(policy):
                s.threads[host_tid] = Thread(tid_ns, comm, "skipped", prior=None)
            else:
                s.threads[host_tid] = Thread(tid_ns, comm, "other", prior="%s:%d" % (_POLICY_NAME[policy], nice))

    def handle_open(self, c, msg):
        """open a session for a connection"""
        sid = msg["sid"]
        if sid in c.sessions:
            log("conn=%d: open re-uses sid=%s, replacing the old session" % (c.conn_id, sid))
            del c.sessions[sid]
        host_tgid = translate_tgid(self.view, c.ns_ino, msg["tgid"])
        if host_tgid is None:
            refuse_tid(self.refusals, msg["tgid"], self._status_key(c, sid),
                       "sandbox tgid not found in this peer's pid namespace")
            self.tick()
            return
        leader_uid = self.view.real_uid(host_tgid)
        if leader_uid != msg["uid"]:
            refuse_tid(self.refusals, msg["tgid"], self._status_key(c, sid),
                       "tgid real uid=%s does not match claimed uid=%d" % (leader_uid, msg["uid"]))
            self.tick()
            return
        s = Session(sid, c.conn_id, c.peer_pid, msg["tgid"], host_tgid, msg["uid"], msg["target_ns"])
        c.sessions[sid] = s
        log("session %s:%s opened tgid=%d uid=%d target_ns=%d tids=%s"
            % (c.conn_id, sid, msg["tgid"], msg["uid"], msg["target_ns"], ",".join(map(str, msg["tids"]))))
        self._register_tids(c, s, msg["tids"])
        self.tick()

    def handle_threads(self, c, msg):
        """update a session's thread list"""
        s = c.sessions.get(msg["sid"])
        if s is None:
            return
        wanted_ns = set(msg["tids"])
        for tid in [tid for tid, th in s.threads.items() if th.ns_tid not in wanted_ns]:
            del s.threads[tid]
            s.held.pop(tid, None)
            s.forget_thread(tid)
        have_ns = {th.ns_tid for th in s.threads.values()}
        self._register_tids(c, s, sorted(wanted_ns - have_ns))
        self.tick()

    def handle_target(self, c, msg):
        """set a session's target frame period"""
        s = c.sessions.get(msg["sid"])
        if s is None:
            return
        s.period_ns = msg["target_ns"]
        self.tick()

    def handle_actual(self, c, msg):
        """record a session's reported frame durations"""
        s = c.sessions.get(msg["sid"])
        if s is None:
            return
        now = self.clock()
        self._frame_sample(s, len(msg["durations_ns"]), now)
        for d in msg["durations_ns"]:
            s.history.append(d)
        s.last_actual = now
        self.tick()

    def _frame_sample(self, s, n, now):
        """record each thread's CPU per frame at a sample point"""
        if n < 1:
            return
        live = s.last_actual is not None and now - s.last_actual <= IDLE_RELEASE_S
        s.reports.append((now, n))
        interval_ns = sum(s.frame_interval) // len(s.frame_interval) if s.frame_interval else 0
        if live:
            interval = int((now - s.last_actual) * 1e9) // n
            s.frame_interval.extend([interval] * n)
        elapsed_ns = int((now - s.sample_time) * 1e9) if live and s.sample_time is not None else None
        if elapsed_ns is not None and elapsed_ns < (interval_ns // 4 if interval_ns > 0 else SAMPLE_GAP_MIN_NS):
            s.frames_since_sample += n
            return
        frames, s.frames_since_sample, s.sample_time = s.frames_since_sample + n, 0, now
        for tid in s.threads:
            v = self.view.schedstat_sum_exec(tid)
            if v is None:
                s.report_schedstat.pop(tid, None)
                continue
            prev = s.report_schedstat.get(tid)
            if prev is not None and elapsed_ns is not None:
                cpu = max(0, v - prev)
                sample = cpu // frames
                if interval_ns > 0 and elapsed_ns > 0:
                    sample = min(sample, cpu * interval_ns // elapsed_ns)
                s.frame_cpu.setdefault(tid, collections.deque(maxlen=HISTORY_MAX)).append(sample)
            s.report_schedstat[tid] = v

    def handle_pause(self, c, msg):
        """pause a session"""
        s = c.sessions.get(msg["sid"])
        if s is None:
            return
        s.state = "paused"
        log("session %s:%s paused" % (s.conn_id, s.sid))
        self.tick()

    def handle_resume(self, c, msg):
        """resume a session"""
        s = c.sessions.get(msg["sid"])
        if s is None:
            return
        s.state = "active"
        log("session %s:%s resumed" % (s.conn_id, s.sid))
        self.tick()

    def handle_close(self, c, msg):
        """close a session"""
        if c.sessions.pop(msg["sid"], None) is not None:
            log("session %s:%s closed" % (c.conn_id, msg["sid"]))
            self.tick()

    def _prior_of(self, host_tid):
        """return the prior policy of a thread"""
        for c in self.connections.values():
            for s in c.sessions.values():
                th = s.threads.get(host_tid) or s.helpers.get(host_tid)
                if th is not None and th.prior:
                    return th.prior, th.ns_tid
        return None, None

    def _same_thread(self, host_tid):
        """compare the tid's identity with its record"""
        want = self.identity.get(host_tid)
        have = (self.view.tgid_of(host_tid), self.view.real_uid(host_tid), self.view.start_time(host_tid))
        return want is not None and have == want

    def _forget(self, host_tid):
        """drop the thread's session and grant records"""
        log("tid(host)=%d is no longer the thread registered under it, dropping it" % host_tid)
        for c in self.connections.values():
            for s in c.sessions.values():
                s.threads.pop(host_tid, None)
                s.held.pop(host_tid, None)
                s.helpers.pop(host_tid, None)
                s.forget_thread(host_tid)
        self.grants.pop(host_tid, None)
        self.grant_tenant.pop(host_tid, None)
        self.contained.pop(host_tid, None)
        self.contain_grants.pop(host_tid, None)
        self.dl_sample.pop(host_tid, None)
        self.identity.pop(host_tid, None)

    def _grant(self, host_tid, runtime_ns, period_ns, tenant=None):
        """grant a deadline reservation to a thread"""
        if not self._same_thread(host_tid):
            self._forget(host_tid)
            return
        if host_tid in self.grants:
            prior, ns_tid = self.grants[host_tid][2], None
        else:
            prior, ns_tid = self._prior_of(host_tid)
            if prior is None:
                return
        who = ns_tid if ns_tid is not None else host_tid
        held = bandwidth(*self.grants[host_tid][:2]) if host_tid in self.grants else 0.0
        need = self.reserved_bw(tenant) - held + bandwidth(runtime_ns, period_ns)
        if not self.carve.ensure(tenant, need, self.clock()):
            refuse_tid(self.refusals, who, "-", "cpu.max carve-out for tenant %s failed, runtime=%r period=%r not granted"
                       % (tenant, runtime_ns, period_ns))
            return
        if host_tid not in self.grants:
            self._record_ahead({"tid": host_tid, "pool": "budgets", "identity": list(self.identity[host_tid]),
                                "prior": prior, "tenant": tenant})
        ok, errno = grant_deadline(host_tid, runtime_ns, period_ns, reclaim=self._reclaim_for(tenant))
        if not ok:
            refuse_tid(self.refusals, who, "-",
                       "sched_setattr grant failed, errno=%d runtime=%r period=%r"
                       % (errno, runtime_ns, period_ns))
            return
        log("%s tid=%d runtime=%d period=%d"
            % ("regrant" if host_tid in self.grants else "grant", host_tid, runtime_ns, period_ns))
        if host_tid not in self.grants:
            self._dl_start(host_tid)
        self.grants[host_tid] = (runtime_ns, period_ns, prior)
        self.grant_tenant[host_tid] = tenant

    def _revoke(self, host_tid):
        """revoke a thread's grant"""
        if not self._same_thread(host_tid):
            self._forget(host_tid)
            return
        _rt, _period, prior = self.grants[host_tid]
        name, nice = prior.split(":")
        ok, errno = revoke_to_prior(host_tid, _POLICY_FOR_NAME.get(name, SCHED_OTHER), int(nice))
        if not ok:
            log("tid=%d: revoke failed, errno=%d" % (host_tid, errno))
            return
        self._dl_stop(host_tid)
        del self.grants[host_tid]
        self.grant_tenant.pop(host_tid, None)
        log("revoke tid=%d -> %s" % (host_tid, prior))

    def sandbox_namespaces(self):
        """return the pid namespaces of all sandboxes"""
        return set(self.sandbox_init_pids())

    def contain_scan(self, refresh=True):
        """register FIFO and RR threads in sandboxes"""
        if not self.contain_enabled:
            return
        if refresh:
            self.refresh_tenants()
        namespaces = set(self.tenant_table)
        for pid in self.view.pids():
            if not _in_sandbox_ns(self.view, pid, namespaces):
                continue
            tenant = self.tenant_of_ino(self.view.ns_ino(pid)).key
            tids = self.view.tids_of(pid)
            for tid in tids:
                if tid in self.contained or tid in self.grants or tid in self.contain_grants:
                    continue
                probe = self.view.sched_probe(tid)
                if probe is None:
                    continue
                policy, _nice, priority = probe
                if not is_fifo_rr(policy):
                    continue
                ident = (self.view.tgid_of(tid), self.view.real_uid(tid), self.view.start_time(tid))
                if any(x is None for x in ident):
                    continue
                self.identity[tid] = ident
                self.contained[tid] = ContainedThread(tid, self.view.comm(tid), policy, priority, tenant)
            self._contain_pool_siblings(tids)
        for tid in [t for t in self.contained if not self._same_thread(t)]:
            self._forget(tid)

    def _contain_pool_siblings(self, tids):
        """register the binder pool siblings of contained threads"""
        prior = pool = tenant = None
        for tid in tids:
            ct = self.contained.get(tid)
            if ct is not None and is_fifo_rr(ct.prior_policy):
                pool = _binder_pool_tgid(ct.comm)
                if pool is not None:
                    prior = (ct.prior_policy, ct.prior_priority)
                    tenant = ct.tenant
                    break
        if prior is None:
            return
        prior_policy, prior_priority = prior
        for tid in tids:
            if tid in self.contained or tid in self.grants or tid in self.contain_grants:
                continue
            comm = self.view.comm(tid)
            if _binder_pool_tgid(comm) != pool:
                continue
            probe = self.view.sched_probe(tid)
            if probe is None or probe[0] != SCHED_OTHER:
                continue
            ident = (self.view.tgid_of(tid), self.view.real_uid(tid), self.view.start_time(tid))
            if any(x is None for x in ident):
                continue
            self.identity[tid] = ident
            self.contained[tid] = ContainedThread(tid, comm, prior_policy, prior_priority, tenant)

    def _contain_measure(self, now):
        """measure each contained thread's CPU use"""
        for tid, ct in self.contained.items():
            got = self.view.schedstat_run(tid)
            if got is None:
                if not ct.unreadable:
                    ct.unreadable = True
                    log("contain tid=%d: /proc/%d/schedstat is unreadable, the thread is left as it is" % (tid, tid))
                continue
            ct.unreadable = False
            v, pc = got
            if ct.sample_ns is None:
                ct.sample_t, ct.sample_ns, ct.sample_pc = now, v, pc
                continue
            window = now - ct.sample_t
            if window < CONTAIN_MIN_WINDOW_S:
                continue
            ct.rate = max(0, v - ct.sample_ns) / (window * 1e9)
            runs = pc - ct.sample_pc
            ct.run_ns = max(0, v - ct.sample_ns) // runs if runs > 0 else None
            ct.sample_t, ct.sample_ns, ct.sample_pc = now, v, pc

    def _contain_requests(self):
        """return the runtime and period per sized thread"""
        now = self.clock()
        named = {}
        for c in self.connections.values():
            for s in c.sessions.values():
                if s.state != "active" or s.period_ns <= 0 or s.idle(now):
                    continue
                for tid in s.threads:
                    if tid not in self.contained:
                        continue
                    rt = frame_cpu_runtime_ns(s.frame_cpu.get(tid), s.period_ns)
                    if rt is None:
                        continue
                    cur = named.get(tid)
                    if cur is None or bandwidth(rt, s.period_ns) > bandwidth(*cur):
                        named[tid] = (rt, s.period_ns)
        sized = {}
        for tid, ct in self.contained.items():
            if tid in named:
                sized[tid], ct.sized_by = named[tid], "session"
            elif ct.rate is not None:
                sized[tid] = (contain_thread_runtime_ns(ct.rate, self.contain_period_ns, self.contain_runtime_ns,
                                                         ct.run_ns),
                              self.contain_period_ns)
                ct.sized_by = "measured"
            else:
                ct.sized_by = None
        return sized

    def _grant_contain(self, host_tid, runtime_ns, period_ns):
        """grant a contained reservation to a thread"""
        if not self._same_thread(host_tid):
            self._forget(host_tid)
            return
        tenant = self._contain_tenant(host_tid)
        held = bandwidth(*self.contain_grants[host_tid]) if host_tid in self.contain_grants else 0.0
        need = self.reserved_bw(tenant) - held + bandwidth(runtime_ns, period_ns)
        if not self.carve.ensure(tenant, need, self.clock()):
            refuse_tid(self.refusals, host_tid, "contain", "cpu.max carve-out for tenant %s failed, runtime=%r period=%r "
                       "not granted" % (tenant, runtime_ns, period_ns))
            return
        ct = self.contained.get(host_tid)
        if host_tid not in self.contain_grants and ct is not None:
            self._record_ahead({"tid": host_tid, "pool": "contain", "identity": list(self.identity[host_tid]),
                                "policy": ct.prior_policy, "priority": ct.prior_priority, "tenant": ct.tenant})
        ok, errno = grant_deadline(host_tid, runtime_ns, period_ns, reclaim=self._reclaim_for(tenant))
        if not ok:
            refuse_tid(self.refusals, host_tid, "contain",
                       "sched_setattr grant failed, errno=%d runtime=%r period=%r"
                       % (errno, runtime_ns, period_ns))
            return
        if host_tid not in self.contain_grants:
            log("contain-grant tid=%d runtime=%d period=%d" % (host_tid, runtime_ns, period_ns))
            self._dl_start(host_tid)
        self.contain_grants[host_tid] = (runtime_ns, period_ns)

    def _revoke_contain(self, host_tid):
        """revoke a contained thread's grant"""
        if not self._same_thread(host_tid):
            self._forget(host_tid)
            return
        ct = self.contained.get(host_tid)
        if ct is None:
            self.contain_grants.pop(host_tid, None)
            return
        policy, nice, priority = _contain_restore_args(ct)
        ok, errno = revoke_to_prior(host_tid, policy, nice, priority)
        if not ok:
            log("contain tid=%d: revoke failed, errno=%d" % (host_tid, errno))
            return
        self._dl_stop(host_tid)
        del self.contain_grants[host_tid]
        log("contain-revoke tid=%d -> %s:%d" % (host_tid, _RT_POLICY_NAME.get(ct.prior_policy, "?"), ct.prior_priority))

    def _apply_contain(self, desired, cap_bw=None, tenant=None):
        """apply a tenant's contain plan"""
        cap = self.contain_cap_bw if cap_bw is None else cap_bw
        for tid in [tid for tid in self.contain_grants
                    if self._contain_tenant(tid) == tenant and tid not in desired]:
            self._revoke_contain(tid)
        near = {tid: self.contain_grants[tid] for tid, (rt, period) in desired.items()
                if tid in self.contain_grants and self.contain_grants[tid][1] == period
                and abs(rt - self.contain_grants[tid][0]) < REAPPLY_RUNTIME_DELTA * self.contain_grants[tid][0]}
        worst = sum(bandwidth(*near.get(tid, d)) for tid, d in desired.items())
        kept = {tid for tid, cur in near.items()
                if not (worst > cap and bandwidth(*cur) > bandwidth(*desired[tid]))}
        todo = {tid: d for tid, d in desired.items() if tid not in kept and self.contain_grants.get(tid) != d}
        held = {tid: bandwidth(*self.contain_grants[tid]) for tid in todo if tid in self.contain_grants}
        order = sorted(todo, key=lambda tid: bandwidth(*todo[tid]) - held.get(tid, 0.0))
        if any(bandwidth(*todo[tid]) > held.get(tid, 0.0) for tid in order):
            self._carve_ahead(tenant, todo, held, self.clock())
        for tid in order:
            self._grant_contain(tid, *todo[tid])

    def _update_window(self, s, now):
        """update the session's held thread shares"""
        if s.window_start is not None and now - s.window_start < SHARE_WINDOW_S:
            return
        vals = {}
        for tid, th in s.threads.items():
            if th.policy == "skipped":
                continue
            v = self.view.schedstat_sum_exec(tid)
            if v is not None:
                vals[tid] = v
        if s.window_start is None:
            s.window_start, s.prev_schedstat = now, vals
        else:
            deltas = {tid: max(0, v - s.prev_schedstat.get(tid, v)) for tid, v in vals.items()}
            total_delta = sum(deltas.values())
            if total_delta > 0:
                s.held = next_held_shares(s.held, {tid: thread_share(d, total_delta) for tid, d in deltas.items()})
            s.window_start, s.prev_schedstat = now, vals

    def _held_render_threads(self, s):
        """return the held threads of a session named RenderThread"""
        return frozenset(tid for tid in s.held if tid in s.threads and s.threads[tid].comm == "RenderThread")

    def _refresh_helpers(self, s, now):
        """refresh the session's hwuiTask and binder threads"""
        rts = self._held_render_threads(s)
        if not rts:
            s.helpers, s.helpers_for, s.helpers_scanned = {}, rts, None
            return
        if rts == s.helpers_for and s.helpers_scanned is not None and now - s.helpers_scanned < SHARE_WINDOW_S:
            return
        s.helpers_for, s.helpers_scanned = rts, now
        found = {}
        for tid in self.view.tids_of(s.host_tgid):
            if tid in s.threads:
                th = s.threads[tid]
                if tid not in s.held and th.policy != "skipped" and is_helper(th.comm, s.tgid_ns):
                    found[tid] = th
                continue
            comm = self.view.comm(tid)
            if not comm or not is_helper(comm, s.tgid_ns):
                continue
            if tid in s.helpers and self._same_thread(tid):
                found[tid] = s.helpers[tid]
                continue
            ident = (self.view.tgid_of(tid), self.view.real_uid(tid), self.view.start_time(tid))
            if ident[0] != s.host_tgid or ident[1] != s.uid or ident[2] is None:
                continue
            if tid in self.identity and self.identity[tid] != ident:
                self._forget(tid)
            if tid in self.grants:
                self.identity[tid] = ident
                found[tid] = Thread(self.view.nspid_last(tid), comm, "other", prior=self.grants[tid][2])
                continue
            probe = self.view.sched_probe(tid)
            if probe is None or not thread_is_eligible(probe[0]):
                continue
            self.identity[tid] = ident
            found[tid] = Thread(self.view.nspid_last(tid), comm, "other",
                                prior="%s:%d" % (_POLICY_NAME[probe[0]], probe[1]))
        s.helpers = found

    def tick(self):
        """plan and apply session budgets"""
        self._tick_needed = False
        now = self.clock()
        requests = {}
        for c in self.connections.values():
            key = self.tenant_of_ino(c.ns_ino).key
            for s in c.sessions.values():
                self._update_window(s, now)
                if s.state != "active" or s.period_ns <= 0 or s.idle(now):
                    continue
                reqs = {}
                for tid in s.held:
                    rt = frame_cpu_runtime_ns(s.frame_cpu.get(tid), s.period_ns) if tid in s.threads else None
                    if rt is not None:
                        reqs[tid] = rt
                self._refresh_helpers(s, now)
                if reqs and s.helpers:
                    for tid, th in s.helpers.items():
                        reqs.setdefault(tid, helper_runtime_ns(th.comm, s.frame_cpu.get(tid), s.period_ns))
                if reqs:
                    requests.setdefault(key, []).append((s.grant_period_ns(), reqs))
        slices = self.slices()
        keys = set(requests) | {self.grant_tenant.get(tid) for tid in self.grants}
        requested = {}
        for key in sorted(keys, key=lambda k: (k is None, str(k))):
            cap = slices.get(key, (0.0, 0.0))[0]
            desired, requested[key], grant_bw, capped = plan_grants(requests.get(key, []), cap)
            if capped:
                record_cap_decision(self.refusals, requested[key], grant_bw, cap, "budgets", key)
            self._apply(self._for_tenant(desired, key), now, cap, key)
        self._sample_demand(requested, slices)
        for key in list(self.carve.states):
            self.carve.settle(key, self.reserved_bw(key), now)
        self._sync_record()

    def _apply(self, desired, now, cap_bw=None, tenant=None):
        """apply a tenant's budgets plan"""
        cap = self.cap_bw if cap_bw is None else cap_bw
        for tid in [tid for tid in self.grants if self.grant_tenant.get(tid) == tenant and tid not in desired]:
            self._revoke(tid)
        down = {tid: d for tid, d in desired.items()
                if tid in self.grants and bandwidth(*self.grants[tid][:2]) > bandwidth(*d)}
        small = {tid for tid, (rt, period) in down.items()
                 if self.grants[tid][1] == period
                 and self.grants[tid][0] - rt < REAPPLY_RUNTIME_DELTA * self.grants[tid][0]}
        worst = sum(bandwidth(*(self.grants[tid][:2] if tid in small else d)) for tid, d in desired.items())
        for tid, (rt, period) in down.items():
            if tid not in small or worst > cap:
                self._grant(tid, rt, period, tenant)
        up = {tid: d for tid, d in desired.items()
              if tid not in self.grants
              or (bandwidth(*d) > bandwidth(*self.grants[tid][:2])
                  and (self.grants[tid][1] != d[1]
                       or d[0] - self.grants[tid][0] >= REAPPLY_RUNTIME_DELTA * self.grants[tid][0]))}
        if up and rate_limit_ok(self._last_apply.get(tenant, 0.0), now):
            held = {tid: bandwidth(*self.grants[tid][:2]) for tid in desired if tid in self.grants}
            self._carve_ahead(tenant, desired, held, now)
            for tid, (rt, period) in up.items():
                self._grant(tid, rt, period, tenant)
            self._last_apply[tenant] = now

    def sweep(self, write=True):
        """drop exited threads and apply contain plans"""
        now = self.clock()
        for tid in list(self.dl_sample):
            self._dl_account(tid)
        for pool in (self.grants, self.contain_grants):
            for tid in list(pool):
                probe = self.view.sched_probe(tid)
                if probe is not None and probe[0] != SCHED_DEADLINE:
                    log("tid(host)=%d left SCHED_DEADLINE outside the daemon (policy %d now)"
                        % (tid, probe[0]))
                    del pool[tid]
        for c in list(self.connections.values()):
            for sid, s in list(c.sessions.items()):
                exited = False
                for tid in list(s.threads):
                    if not self._same_thread(tid):
                        log("session=%s tid(host)=%d exited, dropping it" % (sid, tid))
                        del s.threads[tid]
                        s.held.pop(tid, None)
                        s.forget_thread(tid)
                        self.grants.pop(tid, None)
                        exited = True
                for tid in list(s.helpers):
                    if not self._same_thread(tid):
                        log("session=%s helper tid(host)=%d exited, dropping it" % (sid, tid))
                        del s.helpers[tid]
                        self.grants.pop(tid, None)
                if exited and not s.threads:
                    del c.sessions[sid]
                    log("session %s:%s dropped: every thread exited" % (c.conn_id, sid))
        if self.contain_enabled or self.connections:
            self.refresh_tenants()
        self._check_overruns(now)
        self.contain_scan(refresh=False)
        referenced = set(self.grants) | set(self.contained) | set(self.contain_grants)
        for c in self.connections.values():
            for s in c.sessions.values():
                referenced.update(s.threads)
                referenced.update(s.helpers)
        for tid in [t for t in self.identity if t not in referenced]:
            del self.identity[tid]
        for tid in [t for t in self.grant_tenant if t not in self.grants]:
            del self.grant_tenant[tid]
        for tid in [t for t in self.dl_sample if t not in self.grants and t not in self.contain_grants]:
            del self.dl_sample[tid]
        if self.contain_enabled:
            self._contain_measure(now)
            slices = self.slices()
            sized = {}
            for tid, size in self._contain_requests().items():
                sized.setdefault(self._contain_tenant(tid), {})[tid] = size
            keys = set(sized) | {self._contain_tenant(tid) for tid in self.contain_grants}
            for key in sorted(keys, key=lambda k: (k is None, str(k))):
                cap = slices.get(key, (0.0, 0.0))[1]
                cdesired, creq_bw, cgrant_bw, ccapped = plan_grants(
                    [(period, {tid: rt}) for tid, (rt, period) in sized.get(key, {}).items()], cap)
                if ccapped:
                    record_cap_decision(self.refusals, creq_bw, cgrant_bw, cap, "contain", key)
                self._apply_contain(self._for_tenant(cdesired, key), cap, key)
        for key in list(self.carve.states):
            self.carve.settle(key, self.reserved_bw(key), now)
        self._sync_record()
        self._close_demand_window(now)
        if write:
            self.write_status()

    def run(self):
        """listen on the socket and serve connections"""
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self.carve.recover(self._recover_grants)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o666)
        listener.listen(16)
        listener.setblocking(False)
        self.sel.register(listener, selectors.EVENT_READ, None)
        log("listening on %s (cap=%d%% of %d cpus -> %.3f)"
            % (self.socket_path, self.cap_percent, self.cpus, self.cap_bw))
        period = park_period_ns()
        units = parked_bw_units(period)
        log("revoke parks at runtime=%d period=%d: %d bandwidth units per revoke%s"
            % (DL_RUNTIME_MIN_NS, period, units,
               "" if units == 0 else " -- sched_deadline_period_max_us is too short"))
        self._reserve_self()
        self.write_status()
        sd_notify_ready()
        try:
            self._serve(listener)
        finally:
            self.revoke_everything()
            self._sync_record()
            self.carve.restore_all()
            self.write_status()
            log("stopped: every grant revoked")

    def revoke_everything(self):
        """revoke all grants"""
        for tid in list(self.grants):
            self._revoke(tid)
        done = set()
        while True:
            self.contain_scan(refresh=False)
            todo = [t for t in dict.fromkeys([*self.contained, *self.contain_grants]) if t not in done]
            if not todo:
                break
            for tid in todo:
                if tid in self.contain_grants:
                    self._revoke_contain(tid)
                else:
                    self._restore_ungranted_sibling(tid)
            done.update(todo)

    def _restore_ungranted_sibling(self, tid):
        """restore a thread's FIFO or RR policy"""
        ct = self.contained[tid]
        probe = self.view.sched_probe(tid)
        if not self._same_thread(tid) or probe is None or probe[0] != SCHED_OTHER or not is_fifo_rr(ct.prior_policy):
            return
        ok, errno = set_rt_policy(tid, ct.prior_policy, ct.prior_priority)
        if not ok:
            log("contain tid=%d: restoring %s:%d failed, errno=%d"
                % (tid, _RT_POLICY_NAME.get(ct.prior_policy, "?"), ct.prior_priority, errno))
            return
        log("contain-restore tid=%d -> %s:%d (never granted)"
            % (tid, _RT_POLICY_NAME.get(ct.prior_policy, "?"), ct.prior_priority))

    def _wake(self, listener, events):
        """handle a select's events"""
        self._tick_needed = True
        swept = False
        ready = []
        for key, _mask in events:
            if key.data is None:
                self.accept(listener)
                self._tick_needed = True
            elif self.on_readable(key.data):
                ready.append(key.data)
        passes = 1
        while True:
            now = self.clock()
            if now - self._last_sweep >= SWEEP_INTERVAL_S:
                self._last_sweep = now
                self.sweep(write=False)
                swept = True
                self._tick_needed = True
            if self._tick_needed:
                self.tick()
            if not ready or passes >= DRAIN_PASSES_MAX:
                break
            passes += 1
            ready = [c for c in ready if c.conn_id in self.connections and self.on_readable(c)]
        if swept:
            self.write_status()
        else:
            self._write_status_when_due()

    def _serve(self, listener):
        """serve socket events and run sweeps"""
        while True:
            self._wake(listener, self.sel.select(timeout=REAPPLY_MIN_INTERVAL_S))


def _import_capabilities():
    """import the capabilities module"""
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.normpath(os.path.join(here, "..", "..", "androidd")), here):
        if os.path.exists(os.path.join(candidate, "sandbox/capabilities.py")):
            sys.path.insert(0, candidate)
            break
    from sandbox import capabilities as rc
    return rc


def load_cap_percent(log_fn=log):
    """read rt.budget_percent from policy.conf"""
    rc = _import_capabilities()
    policy = rc.policy_or_deny(log=log_fn)
    percent = policy.scope("rt.budget_percent")
    if not isinstance(percent, int) or not 1 <= percent <= 90:
        log_fn("rt.budget_percent=%r is outside 1..90 -- refusing to start" % (percent,))
        sys.exit(1)
    return percent


def rt_budgets_enabled(log_fn=log):
    """read rt.budgets from policy.conf"""
    rc = _import_capabilities()
    policy = rc.policy_or_deny(log=log_fn)
    return policy.allows("rt.budgets")


def load_contain_config(log_fn=log):
    """read the rt.contain settings from policy.conf"""
    rc = _import_capabilities()
    policy = rc.policy_or_deny(log=log_fn)
    if not policy.allows("rt.contain"):
        return False, 0, 0, 0
    percent = policy.scope("rt.contain_percent")
    runtime_us = policy.scope("rt.contain_runtime_us")
    period_us = policy.scope("rt.contain_period_us")
    if not isinstance(percent, int) or not 1 <= percent <= 50:
        log_fn("rt.contain_percent=%r is outside 1..50 -- refusing to start" % (percent,))
        sys.exit(1)
    if not isinstance(runtime_us, int) or not 100 <= runtime_us <= 10000:
        log_fn("rt.contain_runtime_us=%r is outside 100..10000 -- refusing to start" % (runtime_us,))
        sys.exit(1)
    if not isinstance(period_us, int) or not 1000 <= period_us <= 1000000:
        log_fn("rt.contain_period_us=%r is outside 1000..1000000 -- refusing to start" % (period_us,))
        sys.exit(1)
    return True, percent, runtime_us * 1000, period_us * 1000


def _case(cases, name, ok, detail=""):
    """append a named selftest result"""
    cases.append((name, ok, detail))


def _seed_frames(s, tid, cpu_ns, n=10):
    """fill the frame CPU history of a thread"""
    s.frame_cpu[tid] = collections.deque([cpu_ns] * n, maxlen=HISTORY_MAX)


def _selftest_cap_math(cases):
    """test the cap bandwidth math"""
    _case(cases, "cap_bandwidth(25, 8) == 2.0", cap_bandwidth(25, 8) == 2.0)
    _case(cases, "bandwidth(500000, 1000000) == 0.5", bandwidth(500_000, 1_000_000) == 0.5)
    _case(cases, "bandwidth(x, 0) == 0.0 (no period)", bandwidth(1, 0) == 0.0)

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000})], 2.0)
    _case(cases, "a request well under the cap is granted unscaled, not flagged capped",
          granted == {1: (1_000_000, 1_000_000)} and req == 1.0 and grant == 1.0 and capped is False,
          "got %r %r %r %r" % (granted, req, grant, capped))

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000, 2: 1_000_000})], 1.0)
    _case(cases, "an over-cap request is scaled down to fit, and flagged capped",
          granted == {1: (500_000, 1_000_000), 2: (500_000, 1_000_000)} and capped is True,
          "got %r capped=%r" % (granted, capped))

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000})], 0.1)
    _case(cases, "a thread scaled under 200us by the cap is dropped",
          granted == {} and grant == 0.0 and capped is True, "got %r" % (granted,))

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000})], 0.2)
    _case(cases, "a scale that lands exactly on the 200us floor is kept",
          granted == {1: (200_000, 1_000_000)}, "got %r" % (granted,))

    granted, req, grant, capped = plan_grants([(10_000_000, {1: 1_000_000}), (10_000_000, {1: 3_000_000})], 4.0)
    _case(cases, "a thread two sessions name takes the larger request, counted once",
          granted == {1: (3_000_000, 10_000_000)} and abs(req - 0.3) < 1e-9, "got %r req=%r" % (granted, req))

    light = {tid: 2_000_000 for tid in range(1, 20)}
    granted, req, grant, capped = plan_grants([(16_667_000, light), (16_667_000, {100: 15_000_000, 101: 15_000_000})], 0.4)
    _case(cases, "heavy requests cannot push every light one under the 200us floor at once",
          set(granted) == set(light) | {100, 101} and capped is True and grant <= 0.4 + 1e-9
          and all(granted[t][0] >= MIN_THREAD_RUNTIME_NS for t in granted),
          "got %r grant=%r" % (sorted(granted.items()), grant))

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000, 2: 300_000})], 0.6)
    _case(cases, "over the cap, each thread keeps the floor and the rest is split by what it asked above it",
          granted == {1: (377_777, 1_000_000), 2: (222_222, 1_000_000)} and grant <= 0.6 + 1e-9,
          "got %r grant=%r" % (granted, grant))

    granted, req, grant, capped = plan_grants([(1_000_000, {1: 1_000_000, 2: 1_000_000, 3: 1_000_000})], 0.5)
    _case(cases, "when the floors alone pass the cap, as many floors as fit are kept",
          granted == {1: (200_000, 1_000_000), 2: (200_000, 1_000_000)} and capped is True,
          "got %r" % (granted,))


def _selftest_runtime_rule(cases):
    """check the runtime sizing rule"""
    P = 16_666_667
    _case(cases, "no samples yet -> no runtime to grant", frame_cpu_runtime_ns(None, P) is None
          and frame_cpu_runtime_ns([], P) is None)
    rt = frame_cpu_runtime_ns([2_000_000] * 10, P)
    _case(cases, "a flat 2ms of CPU per frame is granted 2.5ms", rt == 2_500_000, "got %r" % rt)
    rt = frame_cpu_runtime_ns([1_000], P)
    _case(cases, "a near-zero CPU per frame clamps to the 200us floor", rt == MIN_THREAD_RUNTIME_NS, "got %r" % rt)
    rt = frame_cpu_runtime_ns([100_000_000], P)
    _case(cases, "an oversized CPU per frame clamps to 0.9 x period", rt == int(0.9 * P), "got %r" % rt)
    _case(cases, "a period whose 0.9x is under the 200us floor refuses rather than guesses",
          frame_cpu_runtime_ns([100_000], 200_000) is None)
    tail = [100_000] * 15 + [20_000_000]
    rt = frame_cpu_runtime_ns(tail, 100_000_000)
    mean = sum(tail) / len(tail)
    _case(cases, "a heavy-tailed history is granted 1.25 x its mean, not its p90",
          p90(tail) == 100_000 and rt == int(1.25 * mean), "got %r mean %r" % (rt, mean))
    _case(cases, "frame_cpu_ns is None with no samples and max(p90, mean) otherwise",
          frame_cpu_ns([]) is None and frame_cpu_ns(tail) == mean and frame_cpu_ns([5, 5, 5]) == 5)

    _case(cases, "a new thread under 0.15 is not held", next_held_shares({}, {1: 0.10}) == {})
    _case(cases, "a new thread at 0.15 is held", next_held_shares({}, {1: 0.15}) == {1: 0.15})
    _case(cases, "a held thread at 0.10 stays held", next_held_shares({1: 0.5}, {1: 0.10}) == {1: 0.10})
    _case(cases, "a held thread under 0.08 is dropped", next_held_shares({1: 0.5}, {1: 0.05}) == {})

    _case(cases, "rate_limit_ok: under 100ms since the last apply is not ok",
          rate_limit_ok(0.0, 0.050) is False)
    _case(cases, "rate_limit_ok: 100ms or more since the last apply is ok",
          rate_limit_ok(0.0, 0.100) is True)

    _case(cases, "thread_is_eligible: SCHED_OTHER is touched", thread_is_eligible(SCHED_OTHER) is True)
    _case(cases, "thread_is_eligible: SCHED_BATCH is touched", thread_is_eligible(SCHED_BATCH) is True)
    _case(cases, "thread_is_eligible: SCHED_FIFO is left alone", thread_is_eligible(SCHED_FIFO) is False)
    _case(cases, "thread_is_eligible: SCHED_RR is left alone", thread_is_eligible(SCHED_RR) is False)
    _case(cases, "thread_is_eligible: SCHED_IDLE is left alone", thread_is_eligible(SCHED_IDLE) is False)
    _case(cases, "thread_is_eligible: an already-SCHED_DEADLINE thread is left alone",
          thread_is_eligible(SCHED_DEADLINE) is False)


def _selftest_protocol(cases):
    """check the protocol parser on good and bad messages"""
    good = [
        ("open 1 100 1000 16666667 200,201,202",
         {"cmd": "open", "sid": "1", "tgid": 100, "uid": 1000, "target_ns": 16666667,
          "tids": [200, 201, 202]}),
        ("threads 1 200,203", {"cmd": "threads", "sid": "1", "tids": [200, 203]}),
        ("target 1 20000000", {"cmd": "target", "sid": "1", "target_ns": 20000000}),
        ("actual 1 1500000,1600000", {"cmd": "actual", "sid": "1", "durations_ns": [1500000, 1600000]}),
        ("pause 1", {"cmd": "pause", "sid": "1"}),
        ("resume 1", {"cmd": "resume", "sid": "1"}),
        ("close 1", {"cmd": "close", "sid": "1"}),
        ("target 1 9223372036854775807", {"cmd": "target", "sid": "1", "target_ns": 9223372036854775807}),
    ]
    for line, want in good:
        try:
            got = parse_message(line)
            _case(cases, "parses %r" % line, got == want, "got %r want %r" % (got, want))
        except ProtocolError as exc:
            _case(cases, "parses %r" % line, False, "raised %s" % exc)

    bad = [
        "", "bogus", "open 1 100 1000", "open 1 100 1000 16666667 ",
        "open 1 100 1000 16666667 200,,201", "threads 1 abc", "target 1 -5",
        "pause", "pause 1 2", "close one:two",
        "target 1 9223372036854775808", "target 1 " + "9" * 4000, "actual 1 1500000," + "1" * 20,
    ]
    for line in bad:
        try:
            parse_message(line)
            _case(cases, "refuses %r" % line[:60], False, "parsed instead of raising")
        except ProtocolError:
            _case(cases, "refuses %r" % line[:60], True)


def _fake_tree():
    """return a fake process tree for translation"""
    procs = {
        100: {"ns_ino": 777, "nspid_last": 10, "tgid": 100, "uid": 1000, "comm": "app",
              "sched": (SCHED_OTHER, 0, 0)},
        200: {"ns_ino": 777, "nspid_last": 20, "tgid": 100, "uid": 1000, "comm": "RenderThread",
              "sched": (SCHED_OTHER, -10, 0), "schedstat": 1_000_000},
        201: {"ns_ino": 777, "nspid_last": 21, "tgid": 100, "uid": 1000, "comm": "UIThread",
              "sched": (SCHED_BATCH, -5, 0), "schedstat": 200_000},
        202: {"ns_ino": 777, "nspid_last": 22, "tgid": 100, "uid": 1000, "comm": "GpuThread",
              "sched": (SCHED_FIFO, 0, 2)},
        999: {"ns_ino": 555, "nspid_last": 20, "tgid": 999, "uid": 7777, "comm": "other-app",
              "sched": (SCHED_OTHER, 0, 0)},
    }
    pid_tids = {100: [100, 200, 201, 202], 999: [999]}
    return FakeProcView(procs, pid_tids)


def _selftest_translation(cases):
    """test sandbox tid translation"""
    view = _fake_tree()
    host_tgid = translate_tgid(view, 777, 10)
    _case(cases, "translate_tgid resolves the sandbox tgid to its host tgid", host_tgid == 100,
          "got %r" % host_tgid)
    _case(cases, "translate_tgid never matches a tid outside the peer's own namespace",
          translate_tgid(view, 777, 999999) is None)

    host_tid, reason = translate_tid(view, 777, 100, 20, 1000)
    _case(cases, "translate_tid resolves an owned sandbox tid", host_tid == 200, "reason=%r" % reason)

    host_tid, reason = translate_tid(view, 777, 100, 999, 1000)
    _case(cases, "translate_tid refuses a sandbox tid that does not exist",
          host_tid is None and "no host thread" in reason, "got %r %r" % (host_tid, reason))

    host_tid, reason = translate_tid(view, 555, 999, 20, 7777)
    _case(cases, "translate_tid in a different namespace resolves its OWN tid, not the peer's",
          host_tid == 999, "got %r %r" % (host_tid, reason))

    host_tid, reason = translate_tid(view, 777, 999999, 20, 1000)
    _case(cases, "translate_tid refuses a tid whose owning tgid does not match the session's",
          host_tid is None and "belongs to host tgid" in reason, "got %r %r" % (host_tid, reason))

    host_tid, reason = translate_tid(view, 777, 100, 20, 1)
    _case(cases, "translate_tid refuses a uid that does not match the real owner",
          host_tid is None and "real uid" in reason, "got %r %r" % (host_tid, reason))


def _selftest_status_json(cases):
    """check the status JSON and refusal log"""
    import tempfile
    refusals = RefusalLog(maxlen=3)
    for i in range(5):
        refusals.record("refused peer pid=%d ctx=None" % i)
    _case(cases, "RefusalLog keeps only the last N lines",
          refusals.snapshot() == ["refused peer pid=2 ctx=None", "refused peer pid=3 ctx=None",
                                    "refused peer pid=4 ctx=None"],
          "got %r" % refusals.snapshot())
    repeated = RefusalLog(maxlen=8)
    for line in ("cap: requested=1.0 granted=0.5 cap=0.5",) * 3 + ("cap: requested=0.9 granted=0.5 cap=0.5",):
        repeated.record(line)
    _case(cases, "RefusalLog keeps a decision repeated tick after tick once",
          repeated.snapshot() == ["cap: requested=1.0 granted=0.5 cap=0.5",
                                  "cap: requested=0.9 granted=0.5 cap=0.5"],
          "got %r" % repeated.snapshot())

    status = build_status(8, 25, 2.0, 0.5, {"1:1": {"state": "active"}}, refusals.snapshot())
    for key in ("cpus", "cap_percent", "cap_bw", "granted_bw", "sessions", "refusals"):
        _case(cases, "status has key %r" % key, key in status)

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "status.json")
        write_status_atomic(path, status)
        with open(path) as f:
            back = json.load(f)
        _case(cases, "a written status.json round-trips byte-for-value", back == status,
              "got %r" % back)
        _case(cases, "no .tmp file is left behind after an atomic write",
              not any(n.endswith(".tmp.%d" % os.getpid()) for n in os.listdir(tmp)))

    for line, prefix in (("refused peer pid=1 ctx='u:r:other:s0'", "refused peer pid="),
                         ("refused tid=5 session=1:1: no host thread maps it", "refused tid="),
                         ("cap: requested=1.000000 granted=0.500000 cap=0.500000", "cap: requested=")):
        _case(cases, "refusal line %r carries its contract prefix" % line, line.startswith(prefix))


def _selftest_switched_away(cases):
    """test dropping grants switched off SCHED_DEADLINE"""
    import tempfile
    procs = {101: {"tgid": 100, "uid": 10050, "start": 600, "sched": (SCHED_OTHER, 0, 0)},
             102: {"tgid": 100, "uid": 10050, "start": 601, "sched": (SCHED_DEADLINE, 0, 0)}}
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                   view=FakeProcView(procs, {100: [101, 102]}))
        d.grants = {101: (1_000_000, 16_666_667, "other:0"), 102: (1_000_000, 16_666_667, "other:0")}
        d.identity = {101: (100, 10050, 600), 102: (100, 10050, 601)}
        d.sweep()
        _case(cases, "a grant switched off SCHED_DEADLINE outside the daemon is dropped, one still held stays",
              101 not in d.grants and 102 in d.grants, "grants %r" % sorted(d.grants))


def _selftest_selinux_mode(cases):
    """test the mode reader on each record kind"""
    import contextlib, io, tempfile
    with tempfile.TemporaryDirectory() as tmp:
        mode, garbled, empty = os.path.join(tmp, "mode"), os.path.join(tmp, "garbled"), os.path.join(tmp, "empty")
        open(mode, "w").write("namespace\n")
        open(garbled, "w").write("namespaces\n")
        trailing, spaced = os.path.join(tmp, "trailing"), os.path.join(tmp, "spaced")
        open(trailing, "w").write("namespace junk\n")
        open(spaced, "w").write(" host\n")
        open(empty, "w").close()
        for label, path, want, noisy in (("a recorded mode is read", mode, "namespace", False),
                                         ("an absent file is a logged failure", mode + ".none", None, True),
                                         ("an unreadable file is a logged failure", tmp, None, True),
                                         ("a file holding neither mode is a logged failure", garbled, None, True),
                                         ("a mode with trailing text is a logged failure", trailing, None, True),
                                         ("a mode with leading space is a logged failure", spaced, None, True),
                                         ("an empty file is a logged failure", empty, None, True)):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                got = read_selinux_mode(path)
            _case(cases, "read_selinux_mode: " + label, got == want and bool(err.getvalue()) == noisy,
                  "got %r, stderr %r" % (got, err.getvalue()))


def _selftest_sweep(cases):
    """test sweep on exited threads and sessions"""
    import tempfile
    gone = 2 ** 22 + 1
    live = os.getpid()
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25)
        c = Connection(1, None, 1, None)
        d.connections[1] = c
        for sid, tids in ((1, [gone]), (2, [gone, live])):
            s = Session(sid, 1, 1, 100, 100, 1000, 16_666_667)
            for t in tids:
                s.threads[t] = Thread(t, "t", "other", "other:0")
            c.sessions[sid] = s
        d.identity[gone] = (live, os.getuid(), 1)
        d.identity[live] = (d.view.tgid_of(live), d.view.real_uid(live), d.view.start_time(live))
        d.sweep()
        _case(cases, "the sweep drops a session once every thread it named has exited",
              1 not in c.sessions, "sessions %r" % sorted(c.sessions))
        _case(cases, "the sweep keeps a session with a live thread, minus the exited one",
              2 in c.sessions and list(c.sessions[2].threads) == [live],
              "session 2: %r" % (list(c.sessions[2].threads) if 2 in c.sessions else None))
        _case(cases, "the sweep forgets the exited thread's identity and keeps the live one's",
              gone not in d.identity and live in d.identity, "identity %r" % sorted(d.identity))


def _selftest_identity(cases):
    """test reused tid handling in grant and revoke"""
    import tempfile
    global grant_deadline, revoke_to_prior
    real_grant, real_revoke = grant_deadline, revoke_to_prior
    calls = []
    revoke_ok = [False]
    grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append(("grant", tid)) or (True, 0))
    revoke_to_prior = lambda tid, policy, nice: (calls.append(("revoke", tid)) or (revoke_ok[0], 1))
    try:
        procs = {100: {"tgid": 100, "uid": 10050, "start": 500},
                 101: {"tgid": 100, "uid": 10050, "start": 600}}
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                       view=FakeProcView(procs, {100: [100, 101]}))
            c = Connection(1, None, 1, None)
            d.connections[1] = c
            s = Session("1", 1, 1, 10, 100, 10050, 16_666_667)
            s.threads[101] = Thread(11, "RenderThread", "other", "other:-4")
            c.sessions["1"] = s
            d.identity[101] = (100, 10050, 600)
            d._grant(101, 2_000_000, 16_666_667)
            _case(cases, "the registered thread is granted", calls == [("grant", 101)] and 101 in d.grants,
                  "calls %r grants %r" % (calls, d.grants))
            del calls[:]
            d._revoke(101)
            _case(cases, "a revoke the kernel refused keeps the grant counted for the cap",
                  calls == [("revoke", 101)] and 101 in d.grants, "calls %r grants %r" % (calls, d.grants))
            revoke_ok[0] = True
            del calls[:]
            d._revoke(101)
            _case(cases, "a revoke the kernel took drops the grant", calls == [("revoke", 101)] and 101 not in d.grants,
                  "calls %r grants %r" % (calls, d.grants))
            d._grant(101, 2_000_000, 16_666_667)
            procs[101] = {"tgid": 4242, "uid": 0, "start": 900}
            del calls[:]
            d._revoke(101)
            _case(cases, "a reused tid is never revoked: the record goes, no syscall touches the new thread",
                  calls == [] and 101 not in d.grants and 101 not in s.threads,
                  "calls %r grants %r threads %r" % (calls, d.grants, list(s.threads)))
            s.threads[101] = Thread(11, "RenderThread", "other", "other:-4")
            d.identity[101] = (100, 10050, 600)
            d._grant(101, 2_000_000, 16_666_667)
            _case(cases, "a reused tid is never granted", calls == [] and 101 not in d.grants,
                  "calls %r grants %r" % (calls, d.grants))
    finally:
        grant_deadline, revoke_to_prior = real_grant, real_revoke


def _selftest_apply(cases):
    """test grants against the cap"""
    import tempfile
    global grant_deadline
    real_grant = grant_deadline
    calls = []
    grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append((tid, rt)) or (True, 0))
    p = 10_000_000
    try:
        procs = {101: {"tgid": 100, "uid": 10050, "start": 1}, 102: {"tgid": 100, "uid": 10050, "start": 2}}
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                       view=FakeProcView(procs, {100: [101, 102]}))
            c = Connection(1, None, 1, None)
            d.connections[1] = c
            s = Session("1", 1, 1, 10, 100, 10050, p)
            for t in (101, 102):
                s.threads[t] = Thread(t, "t", "other", "other:0")
                d.identity[t] = (100, 10050, procs[t]["start"])
            c.sessions["1"] = s

            def held(cap, last_apply, b=190_000):
                """set up the granted threads for a cap check"""
                del calls[:]
                d.cap_bw, d._last_apply = cap, {None: last_apply}
                d.grants = {101: (210_000, p, "other:0"), 102: (b, p, "other:0")}

            def total():
                """return the total bandwidth of the granted threads"""
                return sum(bandwidth(rt, per) for rt, per, _prior in d.grants.values())
            plan = {101: (195_000, p), 102: (205_000, p)}
            held(0.04, 0.0, b=180_000)
            d._apply(plan, 10.0)
            _case(cases, "a decrease the hysteresis would keep is applied when the kept set would pass the cap",
                  sorted(calls) == [(101, 195_000), (102, 205_000)] and total() <= 0.04 + 1e-12,
                  "calls %r total %.4f" % (calls, total()))
            held(1.0, 0.0)
            d._apply(plan, 10.0)
            _case(cases, "a decrease inside the hysteresis is kept while the set fits the cap",
                  calls == [] and d.grants[101][0] == 210_000, "calls %r grants %r" % (calls, d.grants))
            held(1.0, 10.0)
            d._apply({101: (150_000, p), 102: (300_000, p)}, 10.05)
            _case(cases, "a large decrease applies at once, and an increase waits for the rate limit",
                  calls == [(101, 150_000)] and d.grants[102][0] == 190_000, "calls %r" % (calls,))
            del calls[:]
            d._apply({101: (150_000, p), 102: (300_000, p)}, 10.2)
            _case(cases, "the increase applies once the rate limit allows", calls == [(102, 300_000)],
                  "calls %r" % (calls,))
    finally:
        grant_deadline = real_grant


def _helper_fake_tree():
    """return a fake process tree with hwuiTask threads"""
    procs = {
        100: {"tgid": 100, "uid": 10050, "start": 1, "comm": "ndroid.settings", "nspid_last": 10},
        201: {"tgid": 100, "uid": 10050, "start": 2, "comm": "RenderThread", "nspid_last": 21,
              "sched": (SCHED_OTHER, -10, 0)},
        202: {"tgid": 100, "uid": 10050, "start": 3, "comm": "ndroid.settings", "nspid_last": 22,
              "sched": (SCHED_OTHER, -10, 0)},
        203: {"tgid": 100, "uid": 10050, "start": 4, "comm": "hwuiTask0", "nspid_last": 23,
              "sched": (SCHED_OTHER, -2, 0)},
        204: {"tgid": 100, "uid": 10050, "start": 5, "comm": "hwuiTask1", "nspid_last": 24,
              "sched": (SCHED_OTHER, -2, 0)},
        206: {"tgid": 100, "uid": 10050, "start": 6, "comm": "hwuiTask9", "nspid_last": 26,
              "sched": (SCHED_FIFO, 0, 2)},
        207: {"tgid": 100, "uid": 10050, "start": 14, "comm": "binder:10_1", "nspid_last": 27,
              "sched": (SCHED_OTHER, 0, 0)},
        208: {"tgid": 100, "uid": 10050, "start": 15, "comm": "binder:10_2", "nspid_last": 28,
              "sched": (SCHED_OTHER, 0, 0)},
        209: {"tgid": 100, "uid": 10050, "start": 16, "comm": "binder:99_1", "nspid_last": 29,
              "sched": (SCHED_OTHER, 0, 0)},
        300: {"tgid": 300, "uid": 10060, "start": 7, "comm": "other.app", "nspid_last": 30},
        301: {"tgid": 300, "uid": 10060, "start": 8, "comm": "RenderThread", "nspid_last": 31,
              "sched": (SCHED_OTHER, -10, 0)},
        302: {"tgid": 300, "uid": 10060, "start": 9, "comm": "hwuiTask0", "nspid_last": 32,
              "sched": (SCHED_OTHER, -2, 0)},
        303: {"tgid": 300, "uid": 10060, "start": 17, "comm": "binder:30_1", "nspid_last": 33,
              "sched": (SCHED_OTHER, 0, 0)},
    }
    return FakeProcView(procs, {100: [100, 201, 202, 203, 204, 206, 207, 208, 209], 300: [300, 301, 302, 303]})


def _selftest_helpers(cases):
    """test hwuiTask thread grants"""
    import tempfile
    global grant_deadline, revoke_to_prior
    real_grant, real_revoke = grant_deadline, revoke_to_prior
    calls = []
    grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append(("grant", tid, rt)) or (True, 0))
    revoke_to_prior = lambda tid, policy, nice, priority=0: (
        calls.append(("revoke", tid, policy, nice)) or (True, 0))
    p = 16_666_667
    now = [10.0]
    try:
        view = _helper_fake_tree()
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                       clock=lambda: now[0])
            d.cap_bw = 1.0
            c = Connection(1, None, 1, None)
            d.connections[1] = c
            s = Session("1", 1, 1, 10, 100, 10050, p)
            s.threads[201] = Thread(21, "RenderThread", "other", "other:-10")
            s.threads[202] = Thread(22, "ndroid.settings", "other", "other:-10")
            for t in (201, 202):
                d.identity[t] = (100, 10050, view.procs[t]["start"])
            s.held = {201: 0.9}
            s.history.extend([5_000_000] * 10)
            _seed_frames(s, 201, 4_500_000)
            s.last_actual = now[0]
            c.sessions["1"] = s
            s2 = Session("2", 1, 1, 30, 300, 10060, p)
            s2.threads[301] = Thread(31, "RenderThread", "other", "other:-10")
            d.identity[301] = (300, 10060, view.procs[301]["start"])
            s2.history.extend([5_000_000] * 10)
            _seed_frames(s2, 301, 4_500_000)
            s2.last_actual = now[0]
            c.sessions["2"] = s2

            d.tick()
            granted = {t: rt for kind, t, rt, *_ in [(x[0], x[1], x[2]) for x in calls] if kind == "grant"}
            _case(cases, "a held RenderThread's hwuiTask helpers are granted, each at the floor while it has no samples",
                  granted.get(203) == MIN_THREAD_RUNTIME_NS and granted.get(204) == MIN_THREAD_RUNTIME_NS
                  and 201 in granted, "calls %r" % (calls,))
            _case(cases, "a SCHED_FIFO thread named like a helper is never granted as one",
                  206 not in granted, "calls %r" % (calls,))
            _case(cases, "a held RenderThread's binder pool threads are granted, each at the 200us floor",
                  granted.get(207) == BINDER_HELPER_RUNTIME_NS and granted.get(208) == BINDER_HELPER_RUNTIME_NS,
                  "calls %r" % (calls,))
            _case(cases, "a binder thread whose comm names another pid is never granted as a helper",
                  209 not in granted, "calls %r" % (calls,))
            _case(cases, "a process whose RenderThread is not held gets no helper grant",
                  302 not in granted and 301 not in granted and 303 not in granted, "calls %r" % (calls,))

            view.procs[205] = {"tgid": 100, "uid": 10050, "start": 10, "comm": "hwuiTask2", "nspid_last": 25,
                               "sched": (SCHED_OTHER, -2, 0)}
            view.pid_tids[100].append(205)
            del calls[:]
            now[0] += 0.5
            s.last_actual = now[0]
            d.tick()
            early = 205 in {x[1] for x in calls if x[0] == "grant"}
            now[0] += SHARE_WINDOW_S
            s.last_actual = now[0]
            d.tick()
            _case(cases, "a later-born helper joins within one share window",
                  not early and 205 in {x[1] for x in calls if x[0] == "grant"}, "calls %r" % (calls,))

            del calls[:]
            s.held = {}
            now[0] += 0.2
            s.last_actual = now[0]
            d.tick()
            revoked = {x[1]: (x[2], x[3]) for x in calls if x[0] == "revoke"}
            _case(cases, "when the RenderThread is no longer held, its helpers are restored to their exact prior",
                  all(revoked.get(t) == (SCHED_OTHER, -2) for t in (203, 204, 205))
                  and all(revoked.get(t) == (SCHED_OTHER, 0) for t in (207, 208)) and not s.helpers,
                  "calls %r" % (calls,))

            s.held = {201: 0.9}
            s.helpers_scanned = None
            d.cap_bw = 0.35
            d.refusals = RefusalLog()
            now[0] += 0.2
            s.last_actual = now[0]
            d.tick()
            want = (bandwidth(frame_cpu_runtime_ns(s.frame_cpu[201], p), p)
                    + 3 * bandwidth(MIN_THREAD_RUNTIME_NS, p) + 2 * bandwidth(BINDER_HELPER_RUNTIME_NS, p))
            lines = [r for r in d.refusals.snapshot() if r.startswith("cap: requested=")]
            got = float(lines[-1].split()[1].split("=")[1]) if lines else None
            held_bw = sum(bandwidth(rt, per) for rt, per, _prior in d.grants.values())
            _case(cases, "helpers count against rt.budgets' own cap: the plan asks for them and stays inside it",
                  got is not None and abs(got - want) < 1e-5 and held_bw <= 0.35 + 1e-9,
                  "requested %r want %.6f held %.6f lines %r" % (got, want, held_bw, lines))

            view.procs.update({
                400: {"tgid": 400, "uid": 10070, "start": 11, "comm": "named.app", "nspid_last": 40},
                401: {"tgid": 400, "uid": 10070, "start": 12, "comm": "RenderThread", "nspid_last": 41,
                      "sched": (SCHED_OTHER, -10, 0)},
                402: {"tgid": 400, "uid": 10070, "start": 13, "comm": "hwuiTask0", "nspid_last": 42,
                      "sched": (SCHED_OTHER, -2, 0)},
            })
            view.pid_tids[400] = [400, 401, 402]
            s3 = Session("3", 1, 1, 40, 400, 10070, p)
            s3.threads[401] = Thread(41, "RenderThread", "other", "other:-10")
            s3.threads[402] = Thread(42, "hwuiTask0", "other", "other:-2")
            for t in (401, 402):
                d.identity[t] = (400, 10070, view.procs[t]["start"])
            s3.held = {401: 0.95}
            s3.history.extend([5_000_000] * 10)
            _seed_frames(s3, 401, 4_500_000)
            _seed_frames(s3, 402, 3_000_000)
            s3.last_actual = now[0]
            c.sessions["3"] = s3
            d.cap_bw = 4.0
            del calls[:]
            now[0] += 0.2
            for se in (s, s3):
                se.last_actual = now[0]
            d.tick()
            _case(cases, "a helper the session itself names, under the held share, is still granted as a helper",
                  402 in {x[1] for x in calls if x[0] == "grant"} and 402 in s3.helpers,
                  "calls %r helpers %r" % (calls, sorted(s3.helpers)))
            sized = {x[1]: x[2] for x in calls if x[0] == "grant"}
            _case(cases, "a hwuiTask helper the session names is sized from its own samples, not a fixed 2ms",
                  sized.get(402) == 3_750_000, "calls %r" % (calls,))
    finally:
        grant_deadline, revoke_to_prior = real_grant, real_revoke


def _selftest_helpers_red_check(cases):
    """run the grant cases with unmatched thread names"""
    global HELPER_COMM_PREFIX
    original = HELPER_COMM_PREFIX
    HELPER_COMM_PREFIX = "no-such-thread-name"
    broken = []
    _selftest_helpers(broken)
    HELPER_COMM_PREFIX = original
    caught = any(name.startswith("a held RenderThread's hwuiTask helpers are granted") and not ok
                 for name, ok, _ in broken)
    _case(cases, "red-check: a helper finder that matches nothing makes the helper grant case fail "
                 "(not silently pass)", caught, "broken-run cases: %r" % (broken,))
    global BINDER_POOL_RE
    original_re = BINDER_POOL_RE
    BINDER_POOL_RE = re.compile(r"^no-such-thread-name$")
    broken = []
    _selftest_helpers(broken)
    BINDER_POOL_RE = original_re
    caught = any(name.startswith("a held RenderThread's binder pool threads are granted") and not ok
                 for name, ok, _ in broken)
    _case(cases, "red-check: a binder pool match that matches nothing makes the binder helper case fail",
          caught, "broken-run cases: %r" % (broken,))


def _contain_fake_tree():
    """return a fake process tree with FIFO threads"""
    procs = {
        100: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "surfaceflinger",
              "sched": (SCHED_FIFO, 0, 2), "start": 10, "schedstat": 0},
        101: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "RenderEngine",
              "sched": (SCHED_FIFO, 0, 2), "start": 11, "schedstat": 0},
        102: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "InputReader",
              "sched": (SCHED_RR, 0, 5), "start": 12, "schedstat": 0},
        103: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "TimerDispatch",
              "sched": (SCHED_OTHER, 0, 0), "start": 13, "schedstat": 0},
        900: {"ns_ino": 555, "tgid": 900, "uid": 0, "comm": "host-fifo-thing",
              "sched": (SCHED_FIFO, 0, 1), "start": 1},
    }
    pid_tids = {100: [100, 101, 102, 103], 900: [900]}
    return FakeProcView(procs, pid_tids)


def _contain_sweeps(d, now):
    """run two sweeps a window apart"""
    d.sweep()
    now[0] += SHARE_WINDOW_S
    d.sweep()


def _selftest_contain_scan(cases):
    """test the rt.contain scan"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                   view=_contain_fake_tree(), contain_enabled=True, contain_cap_percent=10,
                   contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
        d.sandbox_ns_ino = 777
        d.contain_scan()
        _case(cases, "the scan contains every FIFO/RR thread inside the sandbox's own namespace",
              set(d.contained) == {100, 101, 102}, "got %r" % sorted(d.contained))
        _case(cases, "a SCHED_OTHER thread inside the sandbox is never contained", 103 not in d.contained)
        _case(cases, "a FIFO thread outside the sandbox's own pid namespace is never touched",
              900 not in d.contained)
        ct100, ct102 = d.contained.get(100), d.contained.get(102)
        _case(cases, "a contained thread's prior policy and priority are recorded exactly",
              ct100 is not None and ct100.prior_policy == SCHED_FIFO and ct100.prior_priority == 2
              and ct102 is not None and ct102.prior_policy == SCHED_RR and ct102.prior_priority == 5,
              "got %r" % {tid: (ct.prior_policy, ct.prior_priority) for tid, ct in d.contained.items()})


def _selftest_contain_discovery(cases):
    """test rt.contain sandbox discovery"""
    import tempfile
    procs = {
        300: {"ns_ino": 888, "nspid_last": 1, "ctx": ANDROID_INIT_CTX, "tgid": 300, "uid": 0,
              "comm": "init", "sched": (SCHED_OTHER, 0, 0), "start": 5},
        310: {"ns_ino": 888, "nspid_last": 40, "ctx": "u:r:surfaceflinger:s0", "tgid": 310, "uid": 1000,
              "comm": "surfaceflinger", "sched": (SCHED_FIFO, 0, 2), "start": 6},
        400: {"ns_ino": 999, "nspid_last": 1, "ctx": "u:r:rhizo_host:s0", "tgid": 400, "uid": 0,
              "comm": "other-init", "sched": (SCHED_OTHER, 0, 0), "start": 7},
        410: {"ns_ino": 999, "nspid_last": 9, "ctx": "u:r:rhizo_host:s0", "tgid": 410, "uid": 0,
              "comm": "other-fifo", "sched": (SCHED_FIFO, 0, 3), "start": 8},
    }
    view = FakeProcView(procs, {300: [300], 310: [310], 400: [400], 410: [410]})
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                   view=view, contain_enabled=True, contain_cap_percent=10,
                   contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
        _case(cases, "a sandbox is found by its Android init with no power HAL connected",
              d.sandbox_namespaces() == {888}, "got %r" % d.sandbox_namespaces())
        d.contain_scan()
        _case(cases, "the scan contains the FIFO thread of a sandbox found by its init alone",
              set(d.contained) == {310}, "got %r" % sorted(d.contained))
        _case(cases, "a namespace whose pid 1 is not Android's init is never touched",
              410 not in d.contained)


def _selftest_contain_disabled(cases):
    """test rt.contain switched off"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                   view=_contain_fake_tree())
        d.sandbox_ns_ino = 777
        d.contain_scan()
        _case(cases, "rt.contain off: the scan contains nothing, whatever /proc shows",
              d.contained == {}, "got %r" % d.contained)
        d.sweep()
        _case(cases, "rt.contain off: a sweep still contains nothing", d.contained == {},
              "got %r" % d.contained)
        with open(d.status_path) as f:
            status = json.load(f)
        _case(cases, "rt.contain off: status.json carries no contain key at all",
              "contain_percent" not in status and "contained" not in status, "got keys %r" % sorted(status))


def _selftest_contain_sizing(cases):
    """test contained thread sizing"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25,
                   view=_contain_fake_tree(), contain_enabled=True, contain_cap_percent=10,
                   contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
        d.sandbox_ns_ino = 777
        d.contain_scan()
        c = Connection(1, None, 1, 777)
        d.connections[1] = c
        s = Session("1", 1, 1, 10, 100, 1000, 16_666_667)
        s.history.extend([4_000_000] * 10)
        _seed_frames(s, 101, 2_400_000)
        s.last_actual = d.clock()
        s.threads[101] = Thread(11, "RenderEngine", "skipped", prior=None)
        s.threads[102] = Thread(12, "TimerDispatch", "skipped", prior=None)
        s.held = {101: 0.6}
        c.sessions["1"] = s
        reqs = d._contain_requests()
        _case(cases, "a thread an active ADPF session holds is sized by the per-frame CPU rule from its own samples",
              reqs.get(101) == (3_000_000, 16_666_667), "got %r" % (reqs.get(101),))
        _case(cases, "a thread no session names has no size before its first window is measured",
              100 not in reqs and 102 not in reqs, "got 100=%r 102=%r" % (reqs.get(100), reqs.get(102)))
        d._contain_measure(100.0)
        d._contain_measure(101.0)
        reqs = d._contain_requests()
        _case(cases, "a thread no session names, idle over its first window, is sized at the 200us floor",
              reqs.get(100) == (MIN_THREAD_RUNTIME_NS, 16_666_667)
              and reqs.get(102) == (MIN_THREAD_RUNTIME_NS, 16_666_667),
              "got 100=%r 102=%r" % (reqs.get(100), reqs.get(102)))


def _selftest_contain_apply(cases):
    """test rt.contain grants and revokes"""
    import tempfile
    global grant_deadline, revoke_to_prior
    real_grant, real_revoke = grant_deadline, revoke_to_prior
    calls = []
    grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append(("grant", tid, rt, period)) or (True, 0))
    revoke_to_prior = lambda tid, policy, nice, priority=0: (
        calls.append(("revoke", tid, policy, priority)) or (True, 0))
    try:
        with tempfile.TemporaryDirectory() as tmp:
            now = [100.0]
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, clock=lambda: now[0],
                       view=_contain_fake_tree(), contain_enabled=True, contain_cap_percent=50,
                       contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
            d.sandbox_ns_ino = 777
            _contain_sweeps(d, now)
            _case(cases, "a sweep with rt.contain on grants every contained thread SCHED_DEADLINE",
                  {c[1] for c in calls if c[0] == "grant"} == {100, 101, 102}, "calls %r" % (calls,))
            del calls[:]
            d._apply_contain({}, 0.0, "ns-777")
            _case(cases, "revoking every contained thread restores its own exact prior policy and priority",
                  sorted(calls) == sorted([("revoke", 100, SCHED_FIFO, 2), ("revoke", 101, SCHED_FIFO, 2),
                                            ("revoke", 102, SCHED_RR, 5)]),
                  "calls %r" % (calls,))
            _case(cases, "after the revoke, rt.contain's own grant pool is empty",
                  d.contain_grants == {}, "got %r" % d.contain_grants)
    finally:
        grant_deadline, revoke_to_prior = real_grant, real_revoke


def _selftest_contain_identity(cases):
    """test reused tid handling in rt.contain"""
    import tempfile
    global grant_deadline, revoke_to_prior
    real_grant, real_revoke = grant_deadline, revoke_to_prior
    calls = []
    grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append(("grant", tid)) or (True, 0))
    revoke_to_prior = lambda tid, policy, nice, priority=0: (calls.append(("revoke", tid)) or (True, 0))
    try:
        view = FakeProcView({101: {"tgid": 100, "uid": 10050, "start": 600}}, {100: [101]})
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                       contain_enabled=True, contain_cap_percent=50,
                       contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
            d.contained[101] = ContainedThread(11, "RenderEngine", SCHED_FIFO, 2)
            d.identity[101] = (100, 10050, 600)
            d._grant_contain(101, 2_000_000, 16_666_667)
            _case(cases, "the registered contained thread is granted",
                  calls == [("grant", 101)] and 101 in d.contain_grants, "calls %r" % (calls,))
            del calls[:]
            d._revoke_contain(101)
            _case(cases, "revoking it restores its own prior policy/priority",
                  calls == [("revoke", 101)] and 101 not in d.contain_grants, "calls %r" % (calls,))
            d._grant_contain(101, 2_000_000, 16_666_667)
            view.procs[101] = {"tgid": 4242, "uid": 0, "start": 900}
            del calls[:]
            d._revoke_contain(101)
            _case(cases, "a reused tid is never revoked by rt.contain: no syscall touches the new thread",
                  calls == [] and 101 not in d.contain_grants and 101 not in d.contained,
                  "calls %r grants %r contained %r" % (calls, d.contain_grants, list(d.contained)))
            d.contained[101] = ContainedThread(11, "RenderEngine", SCHED_FIFO, 2)
            d.identity[101] = (100, 10050, 600)
            d._grant_contain(101, 2_000_000, 16_666_667)
            _case(cases, "a reused tid is never granted by rt.contain", calls == [] and 101 not in d.contain_grants,
                  "calls %r" % (calls,))
    finally:
        grant_deadline, revoke_to_prior = real_grant, real_revoke


def _selftest_contain_cap(cases):
    """test the rt.contain cap"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, contain_enabled=True,
                   contain_cap_percent=10)
        _case(cases, "contain_cap_bw is contain_cap_percent/100 x online cpus, distinct from rt.budgets' cap_bw",
              abs(d.contain_cap_bw - 0.10 * d.cpus) < 1e-9 and d.contain_cap_bw != d.cap_bw,
              "contain_cap_bw=%r cap_bw=%r cpus=%r" % (d.contain_cap_bw, d.cap_bw, d.cpus))
        desired, req_bw, grant_bw, capped = plan_grants(
            [(16_666_667, {1: 4_000_000, 2: 4_000_000})], 0.1)
        _case(cases, "two contained threads whose combined request exceeds rt.contain's own cap are scaled down",
              capped is True and grant_bw <= 0.1 + 1e-9,
              "got %r capped=%r" % (desired, capped))


def _pool_sibling_fake_tree():
    """return a fake tree with binder pool threads"""
    procs = {
        100: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "surfaceflinger",
              "sched": (SCHED_OTHER, 0, 0), "start": 1},
        101: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "binder:11_1",
              "sched": (SCHED_FIFO, 0, 2), "start": 2, "schedstat": 0},
        103: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "binder:11_3",
              "sched": (SCHED_OTHER, 0, 0), "start": 3, "schedstat": 0},
        104: {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "TimerDispatch",
              "sched": (SCHED_OTHER, 0, 0), "start": 4},
        200: {"ns_ino": 777, "tgid": 200, "uid": 1000, "comm": "system_server",
              "sched": (SCHED_OTHER, 0, 0), "start": 5},
        201: {"ns_ino": 777, "tgid": 200, "uid": 1000, "comm": "binder:22_1",
              "sched": (SCHED_OTHER, 0, 0), "start": 6},
        202: {"ns_ino": 777, "tgid": 200, "uid": 1000, "comm": "binder:22_2",
              "sched": (SCHED_OTHER, 0, 0), "start": 7},
    }
    pid_tids = {100: [100, 101, 103, 104], 200: [200, 201, 202]}
    return FakeProcView(procs, pid_tids)


def _selftest_contain_pool_siblings(cases):
    """test binder pool sibling containment"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        now = [100.0]
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, clock=lambda: now[0],
                   view=_pool_sibling_fake_tree(), contain_enabled=True, contain_cap_percent=50,
                   contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
        d.sandbox_ns_ino = 777
        d.contain_scan()
        _case(cases, "a pool's already-FIFO thread is contained the ordinary way",
              101 in d.contained, "got %r" % sorted(d.contained))
        ct103 = d.contained.get(103)
        _case(cases, "a later-born SCHED_OTHER sibling of a contained pool thread is contained too",
              ct103 is not None, "got %r" % sorted(d.contained))
        _case(cases, "the sibling's recorded prior is its contained pool-mate's, not a guess",
              ct103 is not None and ct103.prior_policy == SCHED_FIFO and ct103.prior_priority == 2,
              "got %r" % (ct103,))
        _case(cases, "a SCHED_OTHER thread of the same process that is not pool-named is never swept in",
              104 not in d.contained)
        _case(cases, "a process whose own pool threads are all SCHED_OTHER (no contained sibling "
                     "to copy a prior from) gets nothing",
              201 not in d.contained and 202 not in d.contained)

        global grant_deadline, revoke_to_prior
        real_grant, real_revoke = grant_deadline, revoke_to_prior
        calls = []
        grant_deadline = lambda tid, rt, period, reclaim=True: (calls.append(("grant", tid)) or (True, 0))
        revoke_to_prior = lambda tid, policy, nice, priority=0: (
            calls.append(("revoke", tid, policy, priority)) or (True, 0))
        try:
            _contain_sweeps(d, now)
            del calls[:]
            d._apply_contain({}, 0.0, "ns-777")
            _case(cases, "revoking the sibling restores it to its pool-mate's own policy and priority",
                  ("revoke", 103, SCHED_FIFO, 2) in calls, "calls %r" % (calls,))

            global set_rt_policy
            real_set = set_rt_policy
            set_rt_policy = lambda tid, policy, priority: (calls.append(("set", tid, policy, priority)) or (True, 0))
            try:
                d2 = Daemon(os.path.join(tmp, "rtd2"), os.path.join(tmp, "status2.json"), 25, clock=lambda: now[0],
                            view=_pool_sibling_fake_tree(), contain_enabled=True, contain_cap_percent=50,
                            contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
                d2.sandbox_ns_ino = 777
                d2.contain_scan()
                d2.view.procs[105] = {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "binder:11_5",
                                      "sched": (SCHED_OTHER, 0, 0), "start": 8, "schedstat": 0}
                d2.view.pid_tids[100].append(105)
                del calls[:]
                d2.revoke_everything()
                sets = [c for c in calls if c[0] == "set"]
                _case(cases, "the stop puts a never-granted pool sibling, and one born after the last scan, on its "
                             "pool-mates' FIFO/RR prior, and touches no other thread",
                      sorted(sets) == [("set", 103, SCHED_FIFO, 2), ("set", 105, SCHED_FIFO, 2)],
                      "calls %r contained %r" % (calls, sorted(d2.contained)))

                d3 = Daemon(os.path.join(tmp, "rtd3"), os.path.join(tmp, "status3.json"), 25, clock=lambda: now[0],
                            view=_pool_sibling_fake_tree(), contain_enabled=True, contain_cap_percent=50,
                            contain_runtime_ns=2_000_000, contain_period_ns=16_666_667)
                d3.sandbox_ns_ino = 777
                _contain_sweeps(d3, now)

                def revoke_and_spawn(tid, policy, nice, priority=0):
                    """revoke, then spawn a SCHED_OTHER pool thread"""
                    if 106 not in d3.view.procs:
                        d3.view.procs[106] = {"ns_ino": 777, "tgid": 100, "uid": 1000, "comm": "binder:11_6",
                                              "sched": (SCHED_OTHER, 0, 0), "start": 9, "schedstat": 0}
                        d3.view.pid_tids[100].append(106)
                    calls.append(("revoke", tid, policy, priority))
                    return True, 0

                revoke_to_prior = revoke_and_spawn
                del calls[:]
                d3.revoke_everything()
                _case(cases, "the stop puts a pool thread spawned while its pool was SCHED_DEADLINE "
                             "on the pool's FIFO/RR prior",
                      ("set", 106, SCHED_FIFO, 2) in calls,
                      "calls %r contained %r" % (calls, sorted(d3.contained)))
            finally:
                set_rt_policy = real_set
        finally:
            grant_deadline, revoke_to_prior = real_grant, real_revoke


def _selftest_contain_red_check(cases):
    """run rt.contain assertions against patched functions"""
    global is_fifo_rr
    original_eligible = is_fifo_rr
    is_fifo_rr = lambda policy: False
    broken_cases = []
    _selftest_contain_scan(broken_cases)
    is_fifo_rr = original_eligible
    caught = any(name.startswith("the scan contains every FIFO/RR thread") and not ok
                 for name, ok, _ in broken_cases)
    _case(cases, "red-check: an is_fifo_rr that never matches makes the scan's own "
                 "assertion fail (not silently pass)", caught, "broken-run cases: %r" % (broken_cases,))

    global _in_sandbox_ns
    original_in_ns = _in_sandbox_ns
    _in_sandbox_ns = lambda view, pid, ino: True
    broken_cases2 = []
    _selftest_contain_scan(broken_cases2)
    _in_sandbox_ns = original_in_ns
    caught2 = any("outside the sandbox's own pid namespace is never touched" in name and not ok
                  for name, ok, _ in broken_cases2)
    _case(cases, "red-check: an _in_sandbox_ns that always agrees makes the outside-namespace "
                 "assertion fail (not silently pass)", caught2, "broken-run cases: %r" % (broken_cases2,))

    global _contain_restore_args
    original_restore = _contain_restore_args
    _contain_restore_args = lambda ct: (ct.prior_policy, 0, 0)
    broken_cases3 = []
    _selftest_contain_apply(broken_cases3)
    _contain_restore_args = original_restore
    caught3 = any("restores its own exact prior policy and priority" in name and not ok
                  for name, ok, _ in broken_cases3)
    _case(cases, "red-check: dropping the restored priority makes the exact-restore assertion "
                 "fail (not silently pass)", caught3, "broken-run cases: %r" % (broken_cases3,))

    original_same_thread = Daemon._same_thread
    Daemon._same_thread = lambda self, tid: True
    broken_cases4 = []
    _selftest_contain_identity(broken_cases4)
    Daemon._same_thread = original_same_thread
    caught4 = any(name.startswith("a reused tid is never revoked by rt.contain") and not ok
                  for name, ok, _ in broken_cases4)
    _case(cases, "red-check: a _same_thread that always agrees makes the reused-tid assertion "
                 "fail (not silently pass)", caught4, "broken-run cases: %r" % (broken_cases4,))

    global _binder_pool_tgid
    original_pool_tgid = _binder_pool_tgid
    _binder_pool_tgid = lambda comm: None
    broken_cases5 = []
    _selftest_contain_pool_siblings(broken_cases5)
    _binder_pool_tgid = original_pool_tgid
    caught5 = any(name.startswith("a later-born SCHED_OTHER sibling") and not ok
                  for name, ok, _ in broken_cases5)
    _case(cases, "red-check: a _binder_pool_tgid that never matches makes the pool-sibling "
                 "assertion fail (not silently pass)", caught5, "broken-run cases: %r" % (broken_cases5,))


def _selftest_peer_check(cases):
    """test the peer context check on accept"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        listener.bind(d.socket_path)
        listener.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        client.connect(d.socket_path)
        d.accept(listener)
        client.settimeout(2)
        try:
            closed = client.recv(1) == b""
        except OSError:
            closed = True
        client.close()
        listener.close()
        own = "refused peer pid=%d " % os.getpid()
        _case(cases, "a peer whose context is not %s is refused and its connection closed" % REQUIRED_PEER_CTX,
              not d.connections and closed and any(r.startswith(own) for r in d.refusals.snapshot()),
              "connections=%r closed=%r refusals=%r" % (d.connections, closed, d.refusals.snapshot()))
        n = Daemon(os.path.join(tmp, "rtd-ns"), os.path.join(tmp, "status-ns.json"), 25, selinux_mode="namespace")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        listener.bind(n.socket_path)
        listener.listen(1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        client.connect(n.socket_path)
        n.accept(listener)
        client.settimeout(2)
        try:
            closed = client.recv(1) == b""
        except OSError:
            closed = True
        client.close()
        listener.close()
        _case(cases, "namespace mode: a host peer is refused at accept and its connection closed",
              not n.connections and closed
              and any(r.startswith(own) and r.endswith("why=not-in-a-sandbox-pid-namespace") for r in n.refusals.snapshot()),
              "connections=%r closed=%r refusals=%r" % (n.connections, closed, n.refusals.snapshot()))


def _selftest_namespace_peer(cases):
    """test the namespace-mode sandbox init and power HAL peer checks"""
    import tempfile
    hal = (37, 452115)
    own = os.getpid()
    procs = {
        own: {"ns_ino": 1, "nspid_last": own},
        10: {"ns_ino": 701, "nspid_last": 1, "cmdline": ANDROID_INIT_ARGV + [b""], "cgroup": "/rhizo/init",
             "ctx": "kernel", "root_files": {POWER_HAL_PATH: hal}},
        20: {"ns_ino": 701, "nspid_last": 116, "uid": AID_SYSTEM, "exe": hal},
        30: {"ns_ino": 701, "nspid_last": 300, "uid": 2000, "exe": (37, 999)},
        31: {"ns_ino": 701, "nspid_last": 301, "uid": 2000, "exe": hal},
        40: {"ns_ino": 701, "nspid_last": 400, "uid": AID_SYSTEM, "exe": (37, 5)},
        50: {"ns_ino": 1, "nspid_last": 50, "uid": AID_SYSTEM, "exe": hal},
        60: {"ns_ino": 900, "nspid_last": 1, "cmdline": [b"/sbin/init", b""], "cgroup": "/user.slice/podman"},
        61: {"ns_ino": 900, "nspid_last": 7, "uid": AID_SYSTEM, "exe": hal},
        70: {"ns_ino": 901, "nspid_last": 1, "cmdline": ANDROID_INIT_ARGV + [b""], "cgroup": "/user.slice/app.scope",
             "root_files": {POWER_HAL_PATH: hal}},
        71: {"ns_ino": 901, "nspid_last": 9, "uid": AID_SYSTEM, "exe": hal},
        80: {"ns_ino": 902, "nspid_last": 1, "cmdline": ANDROID_INIT_ARGV + [b""],
             "cgroup": "/system.slice/androidd.service/android"},
    }
    view = FakeProcView(procs, {pid: [pid] for pid in procs})
    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                   selinux_mode="namespace")
        h = Daemon(os.path.join(tmp, "rtd2"), os.path.join(tmp, "status2.json"), 25, view=view)
    got = {pid: d.namespace_peer_refusal(pid, procs[pid]["uid"]) for pid in (20, 30, 31, 40, 50, 61, 71)}
    _case(cases, "namespace mode: the sandbox's power HAL (uid system, the sandbox's %s) is accepted"
          % POWER_HAL_PATH, got[20] is None, "got %r" % got)
    _case(cases, "namespace mode: a sandbox peer of another uid is refused, even running the power HAL's binary",
          (got[30] or "").startswith("uid-2000") and (got[31] or "").startswith("uid-2000"), "got %r" % got)
    _case(cases, "namespace mode: a uid-system sandbox peer running another executable is refused",
          (got[40] or "").startswith("executable-not"), "got %r" % got)
    _case(cases, "namespace mode: a host peer outside all of the sandbox pid namespaces is refused",
          got[50] == "not-in-a-sandbox-pid-namespace", "got %r" % got)
    _case(cases, "namespace mode: a peer whose pid namespace's init is not a sandbox init is refused "
                 "(another container; an init argv outside a Rhizo cgroup stack)",
          got[61] == got[71] == "its-pid-namespace-has-no-sandbox-init", "got %r" % got)
    inits = d.sandbox_init_pids()
    _case(cases, "namespace mode: the sandbox inits are found by argv and Rhizo cgroup stack, not by context",
          inits == {701: 10, 902: 80}, "got %r" % inits)
    hinits = h.sandbox_init_pids()
    _case(cases, "host mode: a sandbox init is found by its context alone (none reads %s here)"
          % ANDROID_INIT_CTX, hinits == {}, "got %r" % hinits)


def _selftest_red_check(cases):
    """run assertions against patched plan_grants and translate_tid"""
    global plan_grants
    original = plan_grants

    def broken_plan_grants(requests, cap_bw):
        """plan grants without the cap"""
        best = {}
        for period_ns, runtimes in requests:
            for tid, rt in runtimes.items():
                best[tid] = (rt, period_ns)
        req_bw = sum(bandwidth(rt, period) for rt, period in best.values())
        return best, req_bw, req_bw, False

    plan_grants = broken_plan_grants
    broken_cases = []
    _selftest_cap_math(broken_cases)
    plan_grants = original
    broke_the_right_ones = (
        any(name.startswith("an over-cap request") and not ok for name, ok, _ in broken_cases)
        and any(name.startswith("a thread scaled under 200us") and not ok
                for name, ok, _ in broken_cases))
    _case(cases, "red-check: a cap function that never scales down makes the cap "
                 "assertions fail (not silently pass)", broke_the_right_ones,
          "broken-run cases: %r" % (broken_cases,))

    def broken_translate_tid(view, ns_ino, host_tgid, tid_ns, uid):
        """find a thread by namespace thread id only"""
        for pid in view.pids():
            for tid in view.tids_of(pid):
                if view.nspid_last(tid) == tid_ns:
                    return tid, None
        return None, "not found"

    global translate_tid
    original_tt = translate_tid
    translate_tid = broken_translate_tid
    broken_cases2 = []
    _selftest_translation(broken_cases2)
    translate_tid = original_tt
    caught = any("refuses a tid whose owning tgid" in name and not ok for name, ok, _ in broken_cases2)
    _case(cases, "red-check: a translate_tid with no ownership check makes the forged-tid "
                 "assertion fail (not silently pass)", caught, "broken-run cases: %r" % (broken_cases2,))


def _selftest_parked_bw(cases):
    """check the bandwidth parked by a revoke"""
    _case(cases, "the default 4.19s period parks a revoke at zero bandwidth",
          parked_bw_units(4194304 * 1000) == 0)
    _case(cases, "a 1s period max leaves one unit per revoke, which startup reports",
          parked_bw_units(1000 * 1000 * 1000) == 1)


def _selftest_self_reserve(cases):
    """test the SCHED_DEADLINE reservation for rhizo-rtd"""
    global sched_setattr, reserve_self
    bw = bandwidth(SELF_RESERVE_RUNTIME_NS, SELF_RESERVE_PERIOD_NS)
    _case(cases, "the self-reservation is a small share of one CPU", 0 < bw <= 0.05, "got %.4f" % bw)

    real_setattr = sched_setattr
    captured = []

    def fake_setattr(tid, policy, flags=0, nice=0, priority=0, runtime=0, deadline=0, period=0):
        """record the scheduler call and report success"""
        captured.append((tid, policy, flags, runtime, deadline, period))
        return True, 0

    sched_setattr = fake_setattr
    try:
        ok, errno = reserve_self(4242, 2_000_000, 16_666_667)
    finally:
        sched_setattr = real_setattr
    _case(cases, "reserve_self grants SCHED_DEADLINE with RECLAIM set and RESET_ON_FORK clear",
          ok and errno == 0
          and captured == [(4242, SCHED_DEADLINE, SCHED_FLAG_RECLAIM, 2_000_000, 16_666_667, 16_666_667)],
          "captured %r" % (captured,))

    import tempfile
    real_reserve = reserve_self
    calls = []
    reserve_self = lambda tid, runtime_ns=SELF_RESERVE_RUNTIME_NS, period_ns=SELF_RESERVE_PERIOD_NS: (
        calls.append((tid, runtime_ns, period_ns)) or (True, 0))
    try:
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, self_reserve=True)
            d._reserve_self()
            _case(cases, "self_reserve on: reserve_self is called once for this process' own pid",
                  calls == [(os.getpid(), SELF_RESERVE_RUNTIME_NS, SELF_RESERVE_PERIOD_NS)],
                  "calls %r" % (calls,))
            d.write_status()
            with open(d.status_path) as f:
                status = json.load(f)
            _case(cases, "a granted self-reservation is reported in status.json",
                  status.get("self_reservation") == {"runtime_ns": SELF_RESERVE_RUNTIME_NS,
                                                      "period_ns": SELF_RESERVE_PERIOD_NS, "granted": True},
                  "got %r" % status.get("self_reservation"))
    finally:
        reserve_self = real_reserve

    del calls[:]
    reserve_self = lambda tid, runtime_ns=SELF_RESERVE_RUNTIME_NS, period_ns=SELF_RESERVE_PERIOD_NS: (False, 11)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, self_reserve=True)
            d._reserve_self()
            d.write_status()
            with open(d.status_path) as f:
                status = json.load(f)
            sr = status.get("self_reservation")
            _case(cases, "a refused self-reservation is reported, errno and all, and the daemon keeps running",
                  sr == {"runtime_ns": SELF_RESERVE_RUNTIME_NS, "period_ns": SELF_RESERVE_PERIOD_NS,
                         "granted": False, "errno": 11},
                  "got %r" % sr)
    finally:
        reserve_self = real_reserve

    with tempfile.TemporaryDirectory() as tmp:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, self_reserve=False)
        d._reserve_self()
        d.write_status()
        with open(d.status_path) as f:
            status = json.load(f)
        _case(cases, "self_reserve off: status.json carries no self_reservation key at all",
              "self_reservation" not in status, "got keys %r" % sorted(status))


def _selftest_slices(cases):
    """check how pool caps are sliced between tenants"""
    two = plan_slices({"A": (1.0, True), "B": (1.0, True)}, 1.0, 0.4)
    _case(cases, "slice: equal weights split each pool's cap equally",
          two == {"A": (0.5, 0.2), "B": (0.5, 0.2)}, "got %r" % (two,))
    prop = plan_slices({"A": (1.0, False), "B": (3.0, False)}, 1.0, 0.4)
    _case(cases, "slice: each pool's cap is split in proportion to the tenants' configured cpu.max",
          abs(prop["A"][0] - 0.25) < 1e-12 and abs(prop["B"][0] - 0.75) < 1e-12
          and abs(prop["A"][1] - 0.1) < 1e-12 and abs(prop["B"][1] - 0.3) < 1e-12, "got %r" % (prop,))
    _case(cases, "slice: the slices of uncapped tenants sum to the host cap",
          abs(sum(v[0] for v in prop.values()) - 1.0) < 1e-12)
    _case(cases, "slice: max and no cpu.max weigh as the online cpu count, a quota as quota over period",
          tenant_weight((None, 100000), 8) == 8.0 and tenant_weight(None, 8) == 8.0
          and tenant_weight((150000, 100000), 8) == 1.5, "got %r" % (tenant_weight((150000, 100000), 8),))
    _case(cases, "slice: a cpu.max line parses to (quota, period) and max to a None quota",
          parse_cpu_max("100000 100000\n") == (100000, 100000) and parse_cpu_max("max 100000") == (None, 100000)
          and format_cpu_max((None, 100000)) == "max 100000", "got %r" % (parse_cpu_max("max 100000"),))
    bad = []
    for line in ("", "max", "1 0", "x 100", "1 2 3"):
        try:
            parse_cpu_max(line)
            bad.append(line)
        except ValueError:
            pass
    _case(cases, "slice: a malformed cpu.max line is refused", not bad, "parsed %r" % (bad,))
    capped = plan_slices({"A": (1.0, True), "B": (4.0, False)}, 4.0, 2.0)
    _case(cases, "slice: a capped tenant's two slices are scaled together to 0.9 of its weight, an uncapped one's are not",
          abs(sum(capped["A"]) - 0.9) < 1e-12 and abs(capped["A"][0] / capped["A"][1] - 2.0) < 1e-9
          and capped["B"] == (3.2, 1.6), "got %r" % (capped,))
    one = plan_slices({"A": (8.0, False)}, 2.0, 0.8)
    _case(cases, "slice: one uncapped tenant gets the whole of each pool", one == {"A": (2.0, 0.8)}, "got %r" % (one,))
    _case(cases, "slice: a tenant's pool with the capability off has a zero slice",
          plan_slices({"A": (1.0, True)}, 0.5, 0.0) == {"A": (0.5, 0.0)})


class _SchedLog:
    """log of sched_setattr and revoke calls"""

    def __init__(self, probe=lambda: None):
        """start with no recorded calls and the given probe"""
        self.calls = []
        self.probe = probe

    def __enter__(self):
        """replace the scheduler calls with recording stubs"""
        global sched_setattr, revoke_to_prior
        self.real = sched_setattr, revoke_to_prior
        sched_setattr = lambda tid, policy, flags=0, nice=0, priority=0, runtime=0, deadline=0, period=0: (
            self.calls.append(("grant", tid, runtime, flags, self.probe(), period)) or (True, 0))
        revoke_to_prior = lambda tid, policy, nice, priority=0: (
            self.calls.append(("revoke", tid, 0, 0, self.probe(), 0)) or (True, 0))
        return self

    def __exit__(self, *_exc):
        """restore the scheduler calls"""
        global sched_setattr, revoke_to_prior
        sched_setattr, revoke_to_prior = self.real

    def grants(self, kind="grant"):
        """return the recorded runtimes of a kind by thread"""
        return {c[1]: c[2] for c in self.calls if c[0] == kind}


def _two_tenant_tree(a_app_tids=(101, 102), a_fifo=(111, 112, 113), b_fifo=(211,)):
    """build the process view of two sandboxes"""
    procs = {
        10: {"ns_ino": 701, "nspid_last": 1, "cgroup": "/rhizo/init", "ctx": ANDROID_INIT_CTX, "tgid": 10,
             "uid": 0, "start": 1, "sched": (SCHED_OTHER, 0, 0)},
        20: {"ns_ino": 702, "nspid_last": 1, "cgroup": "/system.slice/androidd@1.service/android/init",
             "ctx": ANDROID_INIT_CTX, "tgid": 20, "uid": 0, "start": 2, "sched": (SCHED_OTHER, 0, 0)},
    }
    pid_tids = {10: [10], 20: [20]}
    for tgid, ns, uid, apps, fifo in ((100, 701, 10050, a_app_tids, a_fifo), (200, 702, 10060, (201, 202), b_fifo)):
        pid_tids[tgid] = [tgid] + list(apps)
        procs[tgid] = {"ns_ino": ns, "nspid_last": tgid, "tgid": tgid, "uid": uid, "start": tgid, "comm": "app",
                       "sched": (SCHED_OTHER, 0, 0), "schedstat": 0}
        for tid in apps:
            procs[tid] = {"ns_ino": ns, "nspid_last": tid, "tgid": tgid, "uid": uid, "start": tid, "comm": "t%d" % tid,
                          "sched": (SCHED_OTHER, 0, 0), "schedstat": 0}
        fifo_tgid = tgid + 10
        pid_tids[fifo_tgid] = [fifo_tgid] + list(fifo)
        procs[fifo_tgid] = {"ns_ino": ns, "nspid_last": fifo_tgid, "tgid": fifo_tgid, "uid": 1000, "start": fifo_tgid,
                            "comm": "sf", "sched": (SCHED_OTHER, 0, 0), "schedstat": 0}
        for tid in fifo:
            procs[tid] = {"ns_ino": ns, "nspid_last": tid, "tgid": fifo_tgid, "uid": 1000, "start": tid,
                          "comm": "f%d" % tid, "sched": (SCHED_FIFO, 0, 2), "schedstat": 0}
    return FakeProcView(procs, pid_tids)


def _two_tenant_daemon(tmp, view, now, cpu_a="max 100000", cpu_b="max 100000", cap_bw=1.0, contain_cap_bw=0.0):
    """build rhizo-rtd over the two tenant tree"""
    for rel, text in (("rhizo", cpu_a), ("system.slice/androidd@1.service", cpu_b)):
        os.makedirs(os.path.join(tmp, "cg", rel))
        with open(os.path.join(tmp, "cg", rel, "cpu.max"), "w") as f:
            f.write(text)
    d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view, clock=lambda: now[0],
               contain_enabled=contain_cap_bw > 0, contain_cap_percent=10, contain_runtime_ns=5_000_000,
               contain_period_ns=10_000_000, cgroup_fs=os.path.join(tmp, "cg"))
    d.cpus, d.cap_bw, d.contain_cap_bw = 4, cap_bw, contain_cap_bw
    d.carve.log = lambda msg: d.carve_lines.append(msg)
    d.carve_lines = []
    for i, ns in enumerate((701, 702), 1):
        d.connections[i] = Connection(i, None, i, ns)
    d.refresh_tenants()
    return d


def _add_session(d, conn_id, tgid, uid, tids, history_ns, share, now, period=10_000_000):
    """add a session with threads to a daemon"""
    s = Session(str(conn_id), conn_id, conn_id, tgid, tgid, uid, period)
    for tid in tids:
        s.threads[tid] = Thread(tid, "t%d" % tid, "other", "other:0")
        d.identity[tid] = (tgid, uid, tid)
    s.held = {tid: share for tid in tids}
    s.history.extend([history_ns] * 10)
    for tid in tids:
        _seed_frames(s, tid, int(history_ns * share))
    s.last_actual = now[0]
    d.connections[conn_id].sessions[str(conn_id)] = s
    return s


def _selftest_tenant_isolation(cases):
    """check that tenants do not affect each other's grants"""
    import tempfile

    def run(a_hist_ns, a_tids):
        """run two tenants and return what was granted"""
        with tempfile.TemporaryDirectory() as tmp, _SchedLog():
            now = [100.0]
            d = _two_tenant_daemon(tmp, _two_tenant_tree(a_app_tids=a_tids), now)
            _add_session(d, 1, 100, 10050, list(a_tids), a_hist_ns, 0.5, now)
            _add_session(d, 2, 200, 10060, [201, 202], 3_200_000, 0.5, now)
            d.tick()
            b = {t: g for t, g in d.grants.items() if t in (201, 202)}
            a_bw = sum(bandwidth(rt, p) for t, (rt, p, _x) in d.grants.items() if t in a_tids)
            return b, a_bw, list(d.refusals.snapshot())
    quiet_b, quiet_a, _ = run(2_000_000, (101, 102))
    greedy_b, greedy_a, lines = run(30_000_000, (101, 102, 103, 104, 105, 106))
    _case(cases, "tenants: tenant A asking 10x more and adding threads leaves tenant B's planned grants identical",
          quiet_b == greedy_b and len(quiet_b) == 2, "quiet %r greedy %r" % (quiet_b, greedy_b))
    _case(cases, "tenants: tenant A's own grants are held to its slice of the cap, not to the whole cap",
          quiet_a < 0.5 and 0.49 <= greedy_a <= 0.5 + 1e-6, "quiet %.4f greedy %.4f" % (quiet_a, greedy_a))
    _case(cases, "tenants: the cap line for the squeezed tenant names its pool and tenant after the old fields",
          any(l.startswith("cap: requested=") and " granted=" in l and " cap=0.500000 pool=budgets tenant=/rhizo" in l
              for l in lines), "lines %r" % (lines,))
    _case(cases, "tenants: the cap line formatter appends pool and tenant without moving the old fields",
          "cap: requested=1.000000 granted=0.500000 cap=0.500000 pool=contain tenant=/x"
          == (lambda r: (record_cap_decision(r, 1.0, 0.5, 0.5, "contain", "/x"), r.snapshot()[0])[1])(RefusalLog()))


def _selftest_tenant_hysteresis(cases):
    """test tenant hysteresis on small grant decreases"""
    import tempfile
    p = 10_000_000
    with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, cgroup_fs=os.path.join(tmp, "cg"))
        d.cap_bw = 1.0
        for t in (101, 102):
            d.identity[t] = (100, 10050, t)
        s = Session("1", 1, 1, 10, 100, 10050, p)
        for t in (101, 102):
            s.threads[t] = Thread(t, "t", "other", "other:0")
        c = Connection(1, None, 1, None)
        c.sessions["1"] = s
        d.connections[1] = c
        procs = {t: {"tgid": 100, "uid": 10050, "start": t} for t in (101, 102)}
        d.view = FakeProcView(procs, {100: [101, 102]})

        def held():
            """set up the first tenant's granted threads"""
            del sl.calls[:]
            d.grants = {101: (210_000, p, "other:0"), 102: (190_000, p, "other:0")}
            d.grant_tenant = {101: "A", 102: "A"}
        plan = {101: (195_000, p), 102: (190_000, p)}
        held()
        d._apply(plan, 10.0, 0.5, "A")
        _case(cases, "tenant hysteresis: a 7% decrease is kept while the tenant's set fits its slice",
              sl.calls == [], "calls %r" % (sl.calls,))
        held()
        d._apply(plan, 10.0, 0.039, "A")
        _case(cases, "tenant hysteresis: the same decrease is applied when the set passes the tenant's slice, "
                     "though the host cap is not passed",
              sl.grants() == {101: 195_000}, "calls %r" % (sl.calls,))
        held()
        d.grants[103] = (1_000_000, p, "other:0")
        d.grant_tenant[103] = "B"
        d._apply({}, 10.0, 0.5, "A")
        _case(cases, "tenant hysteresis: planning one tenant never revokes another's grants",
              sorted(sl.grants("revoke")) == [101, 102] and 103 in d.grants, "calls %r" % (sl.calls,))


def _selftest_carve_math(cases):
    """check the carve math"""
    s = CARVE_STEP_BW
    _case(cases, "carve: reservations are quantized up to a whole step",
          quantize_carve(0.0) == 0.0 and abs(quantize_carve(0.012) - s) < 1e-12
          and abs(quantize_carve(0.25) - 0.25) < 1e-12 and abs(quantize_carve(0.2501) - 0.30) < 1e-12,
          "got %r %r %r" % (quantize_carve(0.012), quantize_carve(0.25), quantize_carve(0.2501)))
    first = next_carve(0.0, 0.25, -math.inf, 100.0, 0.9)
    _case(cases, "carve: reservations past the carve lower the quota at once, with one step of headroom",
          abs(first - 0.30) < 1e-12, "got %r" % first)
    _case(cases, "carve: reservations inside the carve write nothing",
          next_carve(0.30, 0.28, -math.inf, 100.0, 0.9) is None and next_carve(0.30, 0.25, -math.inf, 100.0, 0.9) is None)
    _case(cases, "carve: a fall of one step does not raise the quota, a fall of two does",
          next_carve(0.30, 0.25, -math.inf, 100.0, 0.9) is None
          and abs(next_carve(0.30, 0.20, -math.inf, 100.0, 0.9) - 0.25) < 1e-12,
          "got %r %r" % (next_carve(0.30, 0.25, -math.inf, 100.0, 0.9), next_carve(0.30, 0.20, -math.inf, 100.0, 0.9)))
    _case(cases, "carve: a raise within 10 s of the last one waits, one after it goes",
          next_carve(0.30, 0.0, 95.0, 100.0, 0.9) is None and next_carve(0.30, 0.0, 85.0, 100.0, 0.9) == 0.0)
    _case(cases, "carve: the carve never passes 0.9 of the limit unless the reservations themselves do",
          next_carve(0.0, 0.88, -math.inf, 0.0, 0.9) == 0.9 and next_carve(0.0, 0.95, -math.inf, 0.0, 0.9) == 0.95,
          "got %r %r" % (next_carve(0.0, 0.88, -math.inf, 0.0, 0.9), next_carve(0.0, 0.95, -math.inf, 0.0, 0.9)))
    _case(cases, "carve: the quota written is the configured one less the carve, in whole microseconds",
          carve_quota_us((100000, 100000), 0.30) == 70000 and carve_quota_us((50000, 100000), 0.125) == 37500)
    _case(cases, "carve: the quota is never written under the kernel's 1000us minimum or above the configured one",
          carve_quota_us((20000, 100000), 0.9) == CPU_MAX_MIN_QUOTA_US and carve_quota_us((500, 100000), 0.3) == 500,
          "got %r %r" % (carve_quota_us((20000, 100000), 0.9), carve_quota_us((500, 100000), 0.3)))
    _case(cases, "tenant cgroup: a unit's android/init, a bare init leaf and a bare android child all name the ceiling",
          ceiling_cgroup("/system.slice/androidd@1.service/android/init") == "/system.slice/androidd@1.service"
          and ceiling_cgroup("/rhizo/init") == "/rhizo" and ceiling_cgroup("/rhizo") == "/rhizo"
          and ceiling_cgroup("/u/androidd@2.service/android") == "/u/androidd@2.service"
          and ceiling_cgroup("/init") is None and ceiling_cgroup("/rhizo/init (deleted)") is None,
          "got %r" % (ceiling_cgroup("/system.slice/androidd@1.service/android/init"),))


def _read_file(path):
    """return the stripped contents of a file"""
    with open(path) as f:
        return f.read().strip()


def _selftest_carve_daemon(cases):
    """test the cpu.max carve for grants and revokes"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        now = [100.0]
        cpu_a = os.path.join(tmp, "cg", "rhizo", "cpu.max")
        with _SchedLog(probe=lambda: _read_file(cpu_a)) as sl:
            d = _two_tenant_daemon(tmp, _two_tenant_tree(), now, cpu_a="100000 100000", cpu_b="200000 100000",
                                   cap_bw=1.2)
            s = _add_session(d, 1, 100, 10050, [101, 102], 2_000_000, 0.5, now)
            _add_session(d, 2, 200, 10060, [201], 2_000_000, 0.5, now)
            d.tick()
            at_grant = {c[1]: c[4] for c in sl.calls if c[0] == "grant"}
            _case(cases, "carve: the quota is lowered by the reservation, one step of headroom included, before the first grant",
                  at_grant.get(101) == "70000 100000" and at_grant.get(102) == "70000 100000"
                  and _read_file(cpu_a) == "70000 100000", "at grant %r file %r" % (at_grant, _read_file(cpu_a)))
            writes = [m for m in d.carve_lines if m.startswith("carve: tenant=/rhizo ")]
            _case(cases, "carve: a batch of grants costs one cpu.max write, and the log line names reserved, quota and configured",
                  len(writes) == 1 and writes[0].startswith("carve: tenant=/rhizo reserved=0.250000 cpu.max=70000 100000 "
                                                            "configured=100000 100000"), "lines %r" % (d.carve_lines,))
            _case(cases, "carve: the carve covers every reservation the kernel holds for the tenant",
                  100000 - int(_read_file(cpu_a).split()[0]) >= d.reserved_bw("/rhizo") * 100000 > 0,
                  "reserved %r file %r" % (d.reserved_bw("/rhizo"), _read_file(cpu_a)))
            other = _read_file(os.path.join(tmp, "cg", "system.slice", "androidd@1.service", "cpu.max"))
            _case(cases, "carve: another tenant's quota moves only for its own reservations",
                  other == "180000 100000", "got %r" % other)
            _case(cases, "carve: a persistent record names the cgroup, its configured value and what was written",
                  json.load(open(os.path.join(tmp, "carve.json")))["carve"].get("/rhizo") ==
                  {"configured": "100000 100000", "written": "70000 100000"},
                  "got %r" % (_read_file(os.path.join(tmp, "carve.json")),))
            del sl.calls[:]
            now[0] += 1.0
            s.held = {101: 0.5}
            s.last_actual = now[0]
            for t in (201,):
                d.connections[2].sessions["2"].last_actual = now[0]
            d.tick()
            at_revoke = [c[4] for c in sl.calls if c[0] == "revoke"]
            _case(cases, "carve: the quota goes up only after the revoke has landed, and keeps a step of headroom",
                  at_revoke == ["70000 100000"] and _read_file(cpu_a) == "80000 100000",
                  "at revoke %r file %r" % (at_revoke, _read_file(cpu_a)))
            now[0] += 5.0
            s.held = {}
            s.last_actual = now[0]
            d.connections[2].sessions["2"].last_actual = now[0]
            d.tick()
            held_back = _read_file(cpu_a)
            now[0] += 6.0
            s.last_actual = now[0]
            d.connections[2].sessions["2"].last_actual = now[0]
            d.tick()
            _case(cases, "carve: a raise within 10 s of the last one waits, and the configured quota is restored once the reservations end",
                  held_back == "80000 100000" and _read_file(cpu_a) == "100000 100000"
                  and any(m == "carve-restore: tenant=/rhizo cpu.max=100000 100000" for m in d.carve_lines),
                  "waiting %r then %r lines %r" % (held_back, _read_file(cpu_a), d.carve_lines))
            s.held = {101: 0.5, 102: 0.5}
            s.last_actual = now[0]
            d.connections[2].sessions["2"].last_actual = now[0]
            d.tick()
            lowered = _read_file(cpu_a)
            d.revoke_everything()
            d.carve.restore_all()
            _case(cases, "carve: the daemon's exit restores every configured quota after its grants are revoked",
                  lowered == "70000 100000" and _read_file(cpu_a) == "100000 100000"
                  and _read_file(os.path.join(tmp, "cg", "system.slice", "androidd@1.service", "cpu.max")) == "200000 100000"
                  and not d.grants, "lowered %r now %r" % (lowered, _read_file(cpu_a)))
            now[0] += 1.0
            for ss in (s, d.connections[2].sessions["2"]):
                ss.last_actual = now[0]
            d.tick()
            with open(cpu_a, "w") as f:
                f.write("50000 100000")
            now[0] += 1.0
            d.refresh_tenants()
            st = d.carve.states["/rhizo"]
            _case(cases, "carve: a live cpu.max that is not what was written is adopted as the configured value",
                  st.configured == (50000, 100000) and st.written is None
                  and d.carve.configured_weight("/rhizo", 4) == 0.5
                  and any("adopting it as configured" in m for m in d.carve_lines),
                  "configured %r written %r lines %r" % (st.configured, st.written, d.carve_lines[-2:]))
            now[0] += 1.0
            for ss in (s, d.connections[2].sessions["2"]):
                ss.last_actual = now[0]
            d.tick()
            _case(cases, "carve: reservations held across an adoption lower the adopted quota again",
                  _read_file(cpu_a) == "20000 100000",
                  "file %r" % _read_file(cpu_a))
            d.revoke_everything()
            for t in list(d.tenant_table):
                if d.tenant_table[t].cgroup == "/rhizo":
                    d.view.pid_tids.pop(10)
                    d.view.procs.pop(10)
            d.connections.pop(1)
            import shutil
            shutil.rmtree(os.path.join(tmp, "cg", "rhizo"))
            d.refresh_tenants()
            _case(cases, "carve: a tenant whose namespace and cgroup are gone is released without an error",
                  "/rhizo" not in d.carve.states and not any("cannot" in m for m in d.carve_lines),
                  "states %r lines %r" % (sorted(d.carve.states), d.carve_lines[-2:]))


def _selftest_carve_recover(cases):
    """check recovery of the carve record"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        for name in ("a", "b"):
            os.makedirs(os.path.join(tmp, "cg", name))
            with open(os.path.join(tmp, "cg", name, "cpu.max"), "w") as f:
                f.write("30000 100000")
        record = os.path.join(tmp, "carve.json")
        with open(record, "w") as f:
            json.dump({"/a": {"configured": "100000 100000", "written": "30000 100000"},
                       "/b": {"configured": "100000 100000", "written": "40000 100000"},
                       "/gone": {"configured": "100000 100000", "written": "30000 100000"}}, f)
        lines = []
        book = CarveBook(os.path.join(tmp, "cg"), record, log_fn=lines.append)
        book.recover()
        _case(cases, "carve: a restart restores a recorded quota whose live value is still the one written",
              _read_file(os.path.join(tmp, "cg", "a", "cpu.max")) == "100000 100000", "lines %r" % (lines,))
        _case(cases, "carve: a restart leaves a quota someone else rewrote since, and a cgroup that is gone, alone",
              _read_file(os.path.join(tmp, "cg", "b", "cpu.max")) == "30000 100000"
              and any("left alone" in m for m in lines) and any("cgroup is gone" in m for m in lines),
              "lines %r" % (lines,))
        _case(cases, "carve: the record is empty once recovery is done", json.load(open(record)) == {"carve": {}, "grants": []})


def _selftest_no_reclaim(cases):
    """test RECLAIM flags and tenant status fields"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
        now = [100.0]
        d = _two_tenant_daemon(tmp, _two_tenant_tree(), now, cpu_a="100000 100000", cpu_b="max 100000", cap_bw=2.0)
        _add_session(d, 1, 100, 10050, [101], 2_000_000, 0.5, now)
        _add_session(d, 2, 200, 10060, [201], 2_000_000, 0.5, now)
        d.tick()
        flags = {c[1]: c[3] for c in sl.calls if c[0] == "grant"}
        _case(cases, "reclaim: a capped tenant's threads are granted with RESET_ON_FORK | RECLAIM until it overruns",
              flags.get(101) == SCHED_FLAG_RESET_ON_FORK | SCHED_FLAG_RECLAIM, "flags %r" % (flags,))
        _case(cases, "reclaim: an uncapped tenant's threads keep RESET_ON_FORK | RECLAIM",
              flags.get(201) == SCHED_FLAG_RESET_ON_FORK | SCHED_FLAG_RECLAIM, "flags %r" % (flags,))
        d.write_status()
        status = json.load(open(d.status_path))
        a, b = status["tenants"]["/rhizo"], status["tenants"]["/system.slice/androidd@1.service"]
        _case(cases, "status: tenants map each cgroup to its namespace, weight, slices, reservation, cpu.max and reclaim",
              set(a) == {"ns_ino", "weight", "slice_budgets", "slice_contain", "reserved_bw", "cpu_max_configured",
                         "cpu_max_written", "reclaim", "reclaim_revoked_at", "dl_cpu_ns", "request_p50",
                         "request_p95", "request_max", "request_samples", "request_window_s", "request_windows",
                         "windows_over_slice"}
              and a["ns_ino"] == 701 and a["weight"] == 1.0 and a["cpu_max_configured"] == "100000 100000"
              and a["cpu_max_written"] == "80000 100000" and a["reclaim"] is True
              and a["reclaim_revoked_at"] is None and b["reclaim_revoked_at"] is None
              and b["weight"] == 4.0 and b["cpu_max_written"] is None and b["reclaim"] is True
              and abs(a["slice_budgets"] - 0.4) < 1e-9, "a %r b %r" % (a, b))
        _case(cases, "status: every existing key is still there",
              all(k in status for k in ("cpus", "cap_percent", "cap_bw", "granted_bw", "grants", "sessions", "refusals")),
              "keys %r" % sorted(status))
        d.view.procs[101]["schedstat"] += 7_000
        d.view.procs[201]["schedstat"] += 3_000
        d.sweep()
        _case(cases, "status: dl_cpu_ns sums a tenant's schedstat growth while its threads held a grant",
              d.dl_cpu_ns.get("/rhizo") == 7_000 and d.dl_cpu_ns.get("/system.slice/androidd@1.service") == 3_000,
              "got %r" % (d.dl_cpu_ns,))


def _mark_deadline(d):
    """mark the granted threads SCHED_DEADLINE"""
    for tid in list(d.grants) + list(d.contain_grants):
        d.view.procs[tid]["sched"] = (SCHED_DEADLINE, 0, 0)


def _selftest_demand(cases):
    """test each tenant's planned budgets against its slice"""
    import tempfile
    global log
    real_log, lines = log, []
    log = lines.append
    try:
        with tempfile.TemporaryDirectory() as tmp, _SchedLog():
            now = [100.0]
            d = _two_tenant_daemon(tmp, _two_tenant_tree(), now, cpu_a="100000 100000", cpu_b="max 100000")
            a_key, b_key = "/rhizo", "/system.slice/androidd@1.service"
            sa = _add_session(d, 1, 100, 10050, [101], 4_000_000, 0.5, now)
            sb = _add_session(d, 2, 200, 10060, [201], 16_000_000, 0.5, now)

            def window(pause_tick=None):
                """plan four times and close the sweep window"""
                mark = len(lines)
                for i in range(4):
                    now[0] += 0.25
                    sa.last_actual = sb.last_actual = now[0]
                    sa.state = "paused" if i == pause_tick else "active"
                    d.tick()
                sa.state = "active"
                _mark_deadline(d)
                d.sweep()
                return d.tenants_status(), [m for m in lines[mark:] if m.startswith("demand-over-slice: ")]
            d.sweep()
            st, over = window()
            a, b = st[a_key], st[b_key]
            _case(cases, "demand: status carries each tenant's planned budgets request over the last window beside its slice",
                  a["request_samples"] == 4 and abs(a["request_window_s"] - 1.0) < 1e-9 and a["request_windows"] == 2
                  and abs(a["request_p50"] - 0.25) < 1e-9 and abs(a["request_p95"] - 0.25) < 1e-9
                  and abs(a["request_max"] - 0.25) < 1e-9 and abs(a["slice_budgets"] - 0.2) < 1e-9
                  and abs(b["request_p95"] - 0.9) < 1e-9 and abs(b["slice_budgets"] - 0.8) < 1e-9, "a %r b %r" % (a, b))
            _case(cases, "demand: a capped tenant whose every plan in a window asked past its slice is counted and logged",
                  a["windows_over_slice"] == 1
                  and over == ["demand-over-slice: tenant=/rhizo p50=0.250 p95=0.250 max=0.250 slice=0.200 windows=1"],
                  "a %r lines %r" % (a, over))
            _case(cases, "demand: an uncapped tenant asking past its slice is never counted or logged",
                  b["windows_over_slice"] == 0
                  and not any(m.startswith("demand-over-slice: tenant=" + b_key) for m in lines), "b %r" % (b,))
            st, over = window(pause_tick=2)
            _case(cases, "demand: one plan inside the slice in a window keeps that window from counting",
                  st[a_key]["windows_over_slice"] == 1 and not over and st[a_key]["request_p50"] == 0.25
                  and st[a_key]["request_samples"] == 4, "a %r lines %r" % (st[a_key], over))
            logged = []
            for _ in range(10):
                st, over = window()
                logged.append(over)
            _case(cases, "demand: the line is rate-limited to one per 10 s per tenant while every window is counted",
                  st[a_key]["windows_over_slice"] == 11 and not any(logged[:8]) and not logged[9]
                  and logged[8] == ["demand-over-slice: tenant=/rhizo p50=0.250 p95=0.250 max=0.250 slice=0.200 windows=10"],
                  "a %r lines %r" % (st[a_key], logged))
            del d.connections[1].sessions["1"]
            st, over = window()
            _case(cases, "demand: a tenant with nothing to plan reports a zero request for the window, not its last busy one",
                  st[a_key]["request_max"] == 0.0 and st[a_key]["request_samples"] == 4 and not over,
                  "a %r" % (st[a_key],))
            for i in range(1, 21):
                d._sample_demand({a_key: i / 100}, {a_key: (0.2, 0.0)})
            d._close_demand_window(now[0])
            last = d.demand_last[a_key]
            _case(cases, "demand: p50 and p95 are nearest-rank over the window's plans",
                  (last["p50"], last["p95"], last["max"], last["samples"]) == (0.10, 0.19, 0.20, 20), "got %r" % (last,))
    finally:
        log = real_log


def _selftest_hard_grants(cases):
    """test HARD_PERIOD_NS grants for non-RECLAIM tenants"""
    import tempfile
    _case(cases, "hard grant: a long period becomes HARD_PERIOD_NS at the same bandwidth, rounded down",
          hard_grant(2_500_000, 10_000_000) == (500_000, HARD_PERIOD_NS)
          and hard_grant(3_333_334, 16_666_667) == (3_333_334 * HARD_PERIOD_NS // 16_666_667, HARD_PERIOD_NS),
          "got %r %r" % (hard_grant(2_500_000, 10_000_000), hard_grant(3_333_334, 16_666_667)))
    _case(cases, "hard grant: a period at or under HARD_PERIOD_NS is kept, and a runtime never drops under the kernel's minimum",
          hard_grant(300_000, HARD_PERIOD_NS) == (300_000, HARD_PERIOD_NS) and hard_grant(900_000, 1_000_000) == (900_000, 1_000_000)
          and hard_grant(2_000, 1_000_000_000) == (DL_RUNTIME_MIN_NS, HARD_PERIOD_NS),
          "got %r" % (hard_grant(2_000, 1_000_000_000),))
    global log
    real_log = log
    log = lambda msg: None
    try:
        with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
            now = [100.0]
            d = _two_tenant_daemon(tmp, _two_tenant_tree(), now, cpu_a="100000 100000", cpu_b="max 100000", cap_bw=2.0)
            a_key = "/rhizo"
            sa = _add_session(d, 1, 100, 10050, [101], 2_000_000, 0.5, now)
            sb = _add_session(d, 2, 200, 10060, [201], 2_000_000, 0.5, now)
            d.reclaim_revoked[a_key] = now[0]
            d.tick()
            got = {c[1]: (c[2], c[5], c[3]) for c in sl.calls if c[0] == "grant"}
            want_a = hard_grant(1_250_000, 10_000_000)
            _case(cases, "hard grant: a tenant without RECLAIM is planned at HARD_PERIOD_NS with its thread's bandwidth",
                  got.get(101) == want_a + (SCHED_FLAG_RESET_ON_FORK,) and d.grants[101][:2] == want_a,
                  "got %r" % (got,))
            _case(cases, "hard grant: a tenant keeping RECLAIM keeps its frame-sized period",
                  got.get(201) == (1_250_000, 10_000_000, SCHED_FLAG_RESET_ON_FORK | SCHED_FLAG_RECLAIM),
                  "got %r" % (got,))
            mark = len(sl.calls)
            for _ in range(3):
                now[0] += 0.2
                sa.last_actual = sb.last_actual = now[0]
                d.tick()
            _case(cases, "hard grant: an unchanged plan at the hard period makes no further kernel call",
                  sl.calls[mark:] == [], "calls %r" % (sl.calls[mark:],))
    finally:
        log = real_log


def _selftest_reclaim_revoke(cases):
    """test revoking RECLAIM from an overrunning tenant"""
    import tempfile
    global log
    real_log, lines = log, []
    log = lines.append
    try:
        with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
            now = [100.0]
            view = _two_tenant_tree()
            d = _two_tenant_daemon(tmp, view, now, cpu_a="100000 100000", cpu_b="max 100000",
                                   cap_bw=2.0, contain_cap_bw=0.5)
            _add_session(d, 1, 100, 10050, [101], 2_000_000, 0.5, now)
            _add_session(d, 2, 200, 10060, [201], 2_000_000, 0.5, now)
            a_key, b_key = "/rhizo", "/system.slice/androidd@1.service"
            d.tick()
            _mark_deadline(d)
            d.sweep()
            now[0] += 1.0
            view.procs[101]["schedstat"] += 20_000_000
            view.procs[201]["schedstat"] += 20_000_000
            d.sweep()
            _mark_deadline(d)
            flags = {c[1]: c[3] for c in sl.calls if c[0] == "grant"}
            keep = SCHED_FLAG_RESET_ON_FORK | SCHED_FLAG_RECLAIM
            _case(cases, "reclaim: a capped honest tenant keeps RECLAIM on both pools",
                  d._reclaim_for(a_key) and not d.reclaim_revoked
                  and flags.get(101) == keep and set(d.contain_grants) >= {111, 112, 113}
                  and all(flags.get(t) == keep for t in (111, 112, 113)),
                  "revoked %r flags %r contain %r" % (d.reclaim_revoked, flags, sorted(d.contain_grants)))
            held = {t: v[:2] for t, v in d.grants.items() if d.grant_tenant.get(t) == a_key}
            held.update({t: v for t, v in d.contain_grants.items() if d._contain_tenant(t) == a_key})
            b_before = {t: v for t, v in d.grants.items() if d.grant_tenant.get(t) == b_key}
            mark = len(sl.calls)
            mark_log = len(lines)
            now[0] += 1.0
            view.procs[111]["schedstat"] += 900_000_000
            view.procs[201]["schedstat"] += 20_000_000
            d.sweep()
            _mark_deadline(d)
            off = [m for m in lines[mark_log:] if m.startswith("reclaim-off: tenant=/rhizo used=")]
            _case(cases, "reclaim: a window over reservation plus margin revokes a capped tenant's RECLAIM and logs reclaim-off",
                  not d._reclaim_for(a_key) and d.reclaim_revoked.get(a_key) == now[0] and len(off) == 1
                  and " reserved=" in off[0], "revoked %r log %r" % (d.reclaim_revoked, off))
            after = [c for c in sl.calls[mark:] if c[0] == "grant"]
            regrants = {}
            for c in after:
                if c[1] in held:
                    regrants.setdefault(c[1], (c[2], c[5], c[3]))
            no_reclaim = all(c[3] == SCHED_FLAG_RESET_ON_FORK for c in after if c[1] in held)
            _case(cases, "reclaim: a revoked tenant's held grants in both pools are regranted at the same bandwidth in "
                         "HARD_PERIOD_NS periods without RECLAIM",
                  {101, 111, 112, 113} <= set(regrants)
                  and all(regrants[t] == hard_grant(*held[t]) + (SCHED_FLAG_RESET_ON_FORK,) for t in {101, 111, 112, 113})
                  and no_reclaim
                  and all(d.grants[t][1] == HARD_PERIOD_NS for t in held if t in d.grants)
                  and all(d.contain_grants[t][1] == HARD_PERIOD_NS for t in held if t in d.contain_grants),
                  "held %r regrants %r" % (held, regrants))
            _case(cases, "reclaim: another tenant's RECLAIM and grants are untouched by one tenant's overrun",
                  d._reclaim_for(b_key) and b_key not in d.reclaim_revoked
                  and not [c for c in after if c[1] in (201, 211) and c[3] != keep]
                  and {t: v for t, v in d.grants.items() if d.grant_tenant.get(t) == b_key} == b_before
                  and d.tenants_status()[b_key]["reclaim"] is True,
                  "calls %r" % (after,))
            st = d.tenants_status()[a_key]
            _case(cases, "status: a revoked tenant reports reclaim False and the time it lost it",
                  st["reclaim"] is False and st["reclaim_revoked_at"] == now[0], "status %r" % (st,))
            when = d.reclaim_revoked[a_key]
            for _ in range(3):
                now[0] += 1.0
                d.sweep()
                _mark_deadline(d)
            _case(cases, "reclaim: revocation is sticky, quiet windows after an overrun do not restore RECLAIM",
                  d.reclaim_revoked.get(a_key) == when and not d._reclaim_for(a_key)
                  and not [c for c in sl.calls[mark:] if c[0] == "grant" and c[1] in held and c[3] & SCHED_FLAG_RECLAIM],
                  "revoked %r" % (d.reclaim_revoked,))
            d.connections.pop(1)
            view.pid_tids.pop(10)
            view.procs.pop(10)
            d.refresh_tenants()
            d.sweep()
            _case(cases, "reclaim: revocation is cleared once the tenant's key is gone",
                  a_key not in d.reclaim_revoked and a_key not in d.reclaim_check, "revoked %r" % (d.reclaim_revoked,))
        with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
            now = [100.0]
            view = _two_tenant_tree()
            d = _two_tenant_daemon(tmp, view, now, cpu_a="max 100000", cpu_b="max 100000", cap_bw=2.0)
            _add_session(d, 1, 100, 10050, [101], 2_000_000, 0.5, now)
            d.tick()
            _mark_deadline(d)
            d.sweep()
            now[0] += 1.0
            view.procs[101]["schedstat"] += 3_000_000_000
            d.sweep()
            _case(cases, "reclaim: an uncapped tenant is never revoked however much its grants use",
                  not d.reclaim_revoked and d.dl_cpu_ns.get("/rhizo") == 3_000_000_000
                  and d.tenants_status()["/rhizo"]["reclaim"] is True,
                  "revoked %r used %r" % (d.reclaim_revoked, d.dl_cpu_ns))
    finally:
        log = real_log


def _selftest_record_ahead(cases):
    """check that grant records are written before the scheduler calls"""
    import tempfile
    global log
    real_log = log
    log = lambda _msg: None
    try:
        with tempfile.TemporaryDirectory() as tmp:
            record_path = os.path.join(tmp, "carve.json")

            def recorded():
                """return the thread ids in the grant record file"""
                try:
                    return {r["tid"] for r in json.load(open(record_path)).get("grants", [])}
                except (OSError, ValueError):
                    return set()
            with _SchedLog(probe=recorded) as sl:
                now = [100.0]
                view = _two_tenant_tree()
                d = _two_tenant_daemon(tmp, view, now, cpu_a="100000 100000", cpu_b="max 100000",
                                       cap_bw=2.0, contain_cap_bw=0.5)
                _add_session(d, 1, 100, 10050, [101, 102], 2_000_000, 0.5, now)
                d.tick()
                _mark_deadline(d)
                d.sweep()
                now[0] += 1.0
                d.sweep()
            first = {}
            for kind, tid, _rt, _flags, seen, _period in sl.calls:
                if kind == "grant" and tid not in first:
                    first[tid] = seen
            late = sorted(tid for tid, seen in first.items() if tid not in seen)
            _case(cases, "record: a new grant is in the record on disk before its sched_setattr runs, in both pools",
                  bool(first) and not late and {101, 111} <= set(first),
                  "first grants %r, recorded only after the grant: %r" % (sorted(first), late))
    finally:
        log = real_log


def _selftest_crash_recovery(cases):
    """test restoring grants from the crash record"""
    import tempfile
    global log, revoke_to_prior
    real = log, revoke_to_prior
    lines, revokes = [], []
    log = lines.append
    try:
        with tempfile.TemporaryDirectory() as tmp, _SchedLog():
            now = [100.0]
            view = _two_tenant_tree()
            d = _two_tenant_daemon(tmp, view, now, cpu_a="100000 100000", cpu_b="max 100000",
                                   cap_bw=2.0, contain_cap_bw=0.5)
            s = _add_session(d, 1, 100, 10050, [101, 102], 2_000_000, 0.5, now)
            s.threads[101].prior = "other:-4"
            view.procs[113]["sched"] = (SCHED_FIFO, 0, 7)
            cpu_a = os.path.join(tmp, "cg", "rhizo", "cpu.max")
            record_path = os.path.join(tmp, "carve.json")
            d.tick()
            _mark_deadline(d)
            d.sweep()
            now[0] += 1.0
            d.sweep()
            _mark_deadline(d)
            rec = {r["tid"]: r for r in json.load(open(record_path))["grants"]}
            _case(cases, "record: it holds identity, prior and tenant for every grant in both pools",
                  rec.get(101) == {"tid": 101, "pool": "budgets", "identity": [100, 10050, 101],
                                   "prior": "other:-4", "tenant": "/rhizo"}
                  and rec.get(111) == {"tid": 111, "pool": "contain", "identity": [110, 1000, 111],
                                       "policy": SCHED_FIFO, "priority": 2, "tenant": "/rhizo"}
                  and rec.get(113, {}).get("priority") == 7 and set(rec) == set(d.grants) | set(d.contain_grants),
                  "record %r grants %r contain %r" % (rec, sorted(d.grants), sorted(d.contain_grants)))
            wrote = []
            plain_set = d.carve.set_grants

            def counting_set(records):
                """set the grants and note whether the record was replaced"""
                before = d.carve.grant_records
                plain_set(records)
                wrote.append(d.carve.grant_records is not before)
            d.carve.set_grants = counting_set
            for _ in range(2):
                now[0] += 1.0
                d.sweep()
            d._sync_record()
            quiet = list(wrote)
            d._revoke(102)
            d._sync_record()
            d._sync_record()
            d.carve.set_grants = plain_set
            gone = {r["tid"] for r in json.load(open(record_path))["grants"]}
            _case(cases, "record: the granted set is rewritten when its tids change and only then",
                  quiet and not any(quiet) and wrote[len(quiet):] == [True, False] and 102 not in gone and 101 in gone,
                  "quiet %r then %r gone %r" % (quiet, wrote[len(quiet):], sorted(gone)))
            d.grants[102] = (1_000_000, 10_000_000, "other:0")
            d.grant_tenant[102] = "/rhizo"
            d._sync_record()
            view.procs[102]["start"] = 9999
            view.procs[112]["sched"] = (SCHED_FIFO, 0, 2)
            lowered = _read_file(cpu_a)

            def stub_revoke(tid, policy, nice, priority=0):
                """record a revoke and report success"""
                revokes.append((tid, policy, nice, priority, _read_file(cpu_a)))
                return True, 0
            revoke_to_prior = stub_revoke
            d2 = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                        clock=lambda: now[0], cgroup_fs=os.path.join(tmp, "cg"))
            d2.carve.log = lines.append
            d2.carve.recover(d2._recover_grants)
            got = {r[0]: r[1:4] for r in revokes}
            _case(cases, "recover: a recorded live DEADLINE thread goes back to its exact prior in both pools",
                  got.get(101) == (SCHED_OTHER, -4, 0) and got.get(111) == (SCHED_FIFO, 0, 2)
                  and got.get(113) == (SCHED_FIFO, 0, 7), "revokes %r" % (revokes,))
            _case(cases, "recover: a reused tid and a thread no longer SCHED_DEADLINE are skipped, not revoked",
                  102 not in got and 112 not in got
                  and any("tid=102 is gone or reused" in m for m in lines)
                  and any("tid=112 is no longer SCHED_DEADLINE" in m for m in lines),
                  "revokes %r lines %r" % (revokes, [m for m in lines if m.startswith("recover")]))
            _case(cases, "recover: cpu.max is restored only after every revoke",
                  revokes and all(r[4] == lowered for r in revokes) and lowered != "100000 100000"
                  and _read_file(cpu_a) == "100000 100000", "at revokes %r then %r (lowered %r)"
                  % ([r[4] for r in revokes], _read_file(cpu_a), lowered))
            summary = [m for m in lines if m.startswith("recover: revoked=")]
            with open(record_path, "w") as f:
                json.dump({"carve": {}, "grants": [rec[101]]}, f)
            d3 = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                        clock=lambda: now[0], cgroup_fs=os.path.join(tmp, "cg"))
            d3.carve.log = lines.append
            d3.carve.recover(d3._recover_grants)
            _case(cases, "recover: the record is left empty and one summary line counts revoked, skipped and restored",
                  json.load(open(record_path)) == {"carve": {}, "grants": []}
                  and len(summary) == 1 and summary[0].startswith("recover: revoked=%d skipped=2 restored=" % len(got)),
                  "record %r summary %r" % (_read_file(record_path), summary))
    finally:
        log, revoke_to_prior = real


def _frame_rig(tmp, period=10_000_000, cpu_a="max 100000"):
    """build a tenant with a held thread"""
    now = [100.0]
    view = _two_tenant_tree()
    d = _two_tenant_daemon(tmp, view, now, cpu_a=cpu_a, cap_bw=2.0)
    s = _add_session(d, 1, 100, 10050, [101], 0, 1.0, now, period)
    s.frame_cpu.clear()
    s.history.clear()

    def report(dt, cpu_ns, n=1):
        """advance the clock, add CPU time and report frames"""
        now[0] += dt
        view.procs[101]["schedstat"] += cpu_ns
        d.handle_actual(d.connections[1], {"sid": "1", "durations_ns": [5_000_000] * n})
    return d, view, now, s, report


def _selftest_frame_cpu(cases):
    """test grants against the CPU used per frame"""
    import tempfile
    P = 10_000_000
    _case(cases, "an hwuiTask helper holds its own per-frame CPU, the floor with no samples",
          helper_runtime_ns("hwuiTask0", [3_000_000] * 10, P) == 3_750_000
          and helper_runtime_ns("hwuiTask0", None, P) == MIN_THREAD_RUNTIME_NS)
    _case(cases, "a binder pool helper holds the floor whatever CPU it was sampled at",
          helper_runtime_ns("binder:10_1", [3_000_000] * 10, P) == BINDER_HELPER_RUNTIME_NS == 200_000)

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        for _ in range(5):
            report(0.01, 800_000)
        small = d.grants.get(101)
        report(0.02, 6_000_000)
        report(0.02, 6_000_000)
        now[0] += REAPPLY_MIN_INTERVAL_S
        d.tick()
        early = d.grants.get(101)
        for _ in range(FRAME_INTERVAL_HISTORY + 1):
            report(0.02, 6_000_000)
        now[0] += REAPPLY_MIN_INTERVAL_S
        d.tick()
        want = int(FRAME_CPU_HEADROOM * 6_000_000)
        _case(cases, "a thread granted below its need grows past the undersized grant from its next heavy reports to at least its CPU in each granted period, and to its heavy frame's runtime once the interval history holds only its slower frames",
              small is not None and small[0] == 1_000_000 and early[0] > small[0] and early[0] >= 0.3 * early[1]
              and frame_cpu_runtime_ns(s.frame_cpu[101], s.period_ns) == want
              and d.grants[101][0] >= (1 - REAPPLY_RUNTIME_DELTA) * want,
              "first %r after 2 heavy reports %r now %r want %d" % (small, early, d.grants.get(101), want))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        P = 16_666_667
        d, view, now, s, report = _frame_rig(tmp, period=P)
        trace = [100_000] * 58 + [6_000_000] * 2
        for cpu in trace:
            report(0.016667, cpu)
        now[0] += REAPPLY_MIN_INTERVAL_S
        d.tick()
        avg_grant = FRAME_CPU_HEADROOM * sum(trace) / len(trace)
        _case(cases, "a thread idling at 0.1ms then drawing 6ms frames is sized to the heavy frame within 2 reports",
              avg_grant < 2_000_000 and d.grants[101][0] >= int(FRAME_CPU_HEADROOM * 6_000_000)
              and d.grants[101][0] > avg_grant,
              "grant %r per-second average x1.25 %.0f" % (d.grants.get(101), avg_grant))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        report(0.01, 1_000_000)
        report(0.01, 1_000_000)
        report(5.0, 900_000_000)
        gap_samples, gap_base = list(s.frame_cpu[101]), s.report_schedstat[101]
        report(0.01, 1_000_000)
        _case(cases, "a report after a gap longer than IDLE_RELEASE_S rebases: the CPU used in the gap is no sample",
              gap_samples == [1_000_000] and gap_base == view.procs[101]["schedstat"] - 1_000_000
              and list(s.frame_cpu[101]) == [1_000_000, 1_000_000], "samples %r" % (list(s.frame_cpu[101]),))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        report(0.01, 1_000_000)
        report(0.04, 8_000_000, n=4)
        _case(cases, "a batched report of n durations records the CPU delta divided by n",
              list(s.frame_cpu[101]) == [2_000_000], "samples %r" % (list(s.frame_cpu[101]),))

    import contextlib
    with tempfile.TemporaryDirectory() as tmp, _SchedLog(), contextlib.redirect_stderr(open(os.devnull, "w")):
        d, view, now, s, report = _frame_rig(tmp, cpu_a="100000 100000")
        for i in range(400):
            report(0.01, 20_000_000 if i % 16 == 15 else 100_000)
            _mark_deadline(d)
            if i % 100 == 99:
                d.sweep()
                _mark_deadline(d)
        _case(cases, "an honest heavy-tail capped tenant (15 x 0.1ms + 1 x 20ms frames) keeps RECLAIM",
              101 in d.grants and d.dl_cpu_ns.get("/rhizo", 0) > 0 and not d.reclaim_revoked,
              "revoked %r grants %r used %r" % (d.reclaim_revoked, d.grants, d.dl_cpu_ns))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog(), contextlib.redirect_stderr(open(os.devnull, "w")):
        d, view, now, s, report = _frame_rig(tmp)
        d.identity[102] = (100, 10050, 102)
        s.threads[102] = Thread(102, "t102", "other", "other:0")
        for tid in (101, 102):
            _seed_frames(s, tid, 1_000_000)
            s.report_schedstat[tid] = 5
        view.procs[101]["start"] = 9999
        d.sweep()
        left = 101 in s.frame_cpu or 101 in s.report_schedstat
        view.procs[102]["start"] = 8888
        d._forget(102)
        _case(cases, "a dropped or reused tid's samples are discarded by the sweep and by _forget",
              not left and 102 not in s.frame_cpu and 102 not in s.report_schedstat,
              "frame_cpu %r report %r" % (sorted(s.frame_cpu), sorted(s.report_schedstat)))


def _frame_cpu_of(cycle, cycles=20):
    """return a thread's frame_cpu_ns after a repeated report cycle"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        for _ in range(cycles):
            for gap, cpu_ns, n in cycle:
                report(gap, cpu_ns, n)
        return frame_cpu_ns(s.frame_cpu.get(101))


def _selftest_frame_arrival(cases):
    """test the CPU per frame of late and bunched reports"""
    rate = 300_000 / 0.010
    vm = _frame_cpu_of([(gap, int(rate * gap), 2) for gap in (0.0466, 0.0002, 0.0132, 0.020, 0.020)])
    _case(cases, "a steady 0.3 ms per 10 ms frame thread reported in pairs at 46.6, 0.2, 13.2, 20, 20 ms gaps reads 0.3 ms per frame within 5%",
          vm is not None and abs(vm - 300_000) <= 15_000, "frame_cpu_ns %r" % (vm,))
    pc_rate = 12 * 300_000 / 0.100
    pc = _frame_cpu_of([(gap, int(pc_rate * gap), 2) for gap in (0.049, 0.00025, 0.0005, 0.01025, 0.020, 0.020)])
    _case(cases, "a steady 0.3 ms per frame thread reported in pairs at 49, 0.25, 0.5, 10.25, 20, 20 ms gaps reads 0.3 ms per frame within 5%",
          pc is not None and abs(pc - 300_000) <= 15_000, "frame_cpu_ns %r" % (pc,))
    steady = _frame_cpu_of([(0.020, 600_000, 2)])
    _case(cases, "a steady thread reported in pairs every 20 ms reads the 0.3 ms per frame the count split read, within 1%",
          steady is not None and abs(steady - 300_000) <= 3_000, "frame_cpu_ns %r" % (steady,))
    burst = _frame_cpu_of([(0.0988, 300_000, 1)] + [(0.0003, 300_000, 1)] * 4)
    _case(cases, "an app drawing 5 back-to-back 0.3 ms frames every 100 ms reads 0.3 ms per frame within 10%",
          burst is not None and abs(burst - 300_000) <= 30_000, "frame_cpu_ns %r" % (burst,))
    spread = {spacing: _frame_cpu_of([(0.100 - 4 * spacing, 300_000, 1)] + [(spacing, 300_000, 1)] * 4)
              for spacing in (0.002, 0.010)}
    long_burst = _frame_cpu_of([(0.5, 300_000, 1)] + [(0.0003, 300_000, 1)] * 39, cycles=6)
    _case(cases, "an app drawing 5 0.3 ms frames 2 or 10 ms apart every 100 ms, or 40 back to back every 0.5 s, reads 0.3 ms per frame within 10%, not its CPU rate inside the burst",
          all(v is not None and abs(v - 300_000) <= 30_000 for v in list(spread.values()) + [long_burst]),
          "frame_cpu_ns %r, 40 frames %r" % (spread, long_burst))


def _selftest_contain_measured(cases):
    """test sizing of contained threads from CPU use"""
    import tempfile
    _case(cases, "contain sizing: measured use x 1.25 sets the runtime, the floor and the ceiling bound it",
          contain_thread_runtime_ns(0.3, 10_000_000, 10_000_000) == 3_750_000
          and contain_thread_runtime_ns(0.0, 10_000_000, 10_000_000) == MIN_THREAD_RUNTIME_NS
          and contain_thread_runtime_ns(0.9, 10_000_000, 5_000_000) == 5_000_000,
          "got %r %r %r" % (contain_thread_runtime_ns(0.3, 10_000_000, 10_000_000),
                            contain_thread_runtime_ns(0.0, 10_000_000, 10_000_000),
                            contain_thread_runtime_ns(0.9, 10_000_000, 5_000_000)))
    with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
        now = [100.0]
        view = _two_tenant_tree()
        d = _two_tenant_daemon(tmp, view, now, contain_cap_bw=0.5)
        d.sweep()
        _case(cases, "contain sizing: a thread the scan found is not granted before its first window is measured",
              d.contain_grants == {} and {111, 112, 113, 211} <= set(d.contained),
              "grants %r contained %r" % (d.contain_grants, sorted(d.contained)))
        now[0] += 1.0
        for tid in (111, 112, 113):
            view.procs[tid]["schedstat"] += 1_000_000_000
        view.procs[211]["schedstat"] += 120_000_000
        view.procs[10]["schedstat"] = 0
        d.sweep()
        g = d.contain_grants
        _case(cases, "contain sizing: after one window each thread is granted from its own measured use",
              g.get(211) == (1_500_000, 10_000_000) and set(g) >= {111, 112, 113}
              and d.contained[211].rate == 0.12, "grants %r" % (g,))
        _case(cases, "contain sizing: an idle contained thread holds the floor, not the declared runtime",
              all(d.contained[t].rate is not None for t in d.contained)
              and contain_thread_runtime_ns(0.0, 10_000_000, d.contain_runtime_ns) == MIN_THREAD_RUNTIME_NS)
        _case(cases, "contain tenants: tenant A's busy threads are held to A's slice and tenant B's grant is untouched",
              sum(bandwidth(*g[t]) for t in (111, 112, 113)) <= 0.25 + 1e-6 and g[211] == (1_500_000, 10_000_000),
              "grants %r" % (g,))
        before = dict(g)
        for tid in g:
            view.procs[tid]["sched"] = (SCHED_DEADLINE, 0, 0)
        now[0] += 1.0
        for tid in (111, 112, 113):
            view.procs[tid]["schedstat"] += 1_000_000_000
        view.procs[211]["schedstat"] += 125_000_000
        d.sweep()
        _case(cases, "contain sizing: a change under 10% is not regranted, a steady thread keeps its grant",
              d.contain_grants == before and not [c for c in sl.calls if c[0] == "grant" and c[1] == 211][1:],
              "grants %r" % (d.contain_grants,))
        c = d.connections[1]
        s = Session("1", 1, 1, 100, 110, 1000, 16_666_667)
        s.history.extend([4_000_000] * 10)
        s.last_actual = now[0]
        s.threads[111] = Thread(11, "RenderEngine", "other", prior="other:0")
        _seed_frames(s, 111, 2_400_000)
        s.held = {111: 0.6}
        c.sessions["1"] = s
        _case(cases, "contain sizing: a thread an active ADPF session holds keeps the per-frame size over a measured one",
              d._contain_requests().get(111) == (3_000_000, 16_666_667), "got %r" % (d._contain_requests().get(111),))
        s2 = Session("2", 1, 1, 100, 110, 1000, 16_666_667)
        s2.threads[112] = Thread(12, "surfaceflinger", "skipped", prior=None)
        c.sessions["2"] = s2
        for _ in range(4):
            now[0] += 0.016
            view.procs[112]["schedstat"] += 400_000
            d.handle_actual(c, {"sid": "2", "durations_ns": [3_000_000]})
        got = d._contain_requests().get(112)
        _case(cases, "contain sizing: a FIFO thread its own session names, registered skipped, is sized from its CPU per frame",
              got == (500_000, 16_666_667) and d.contained[112].sized_by == "session",
              "got %r sized_by %r samples %r" % (got, d.contained[112].sized_by, list(s2.frame_cpu.get(112, []))))


def _selftest_contain_per_run(cases):
    """check per-run sizing of contained threads"""
    import tempfile
    rt = contain_thread_runtime_ns
    _case(cases, "contain per-run sizing: an idle thread holds the floor",
          rt(0.0, 16_666_667, 16_666_667, None) == MIN_THREAD_RUNTIME_NS,
          "got %r" % (rt(0.0, 16_666_667, 16_666_667, None),))
    _case(cases, "contain per-run sizing: a thread of 103us runs at 0.0032 CPU holds 2 x the run, not the floor",
          rt(0.0032, 16_666_667, 16_666_667, 103_000) == 206_000,
          "got %r" % (rt(0.0032, 16_666_667, 16_666_667, 103_000),))
    _case(cases, "contain per-run sizing: a busy thread's per-period term wins when larger",
          rt(0.3, 10_000_000, 10_000_000, 100_000) == 3_750_000,
          "got %r" % (rt(0.3, 10_000_000, 10_000_000, 100_000),))
    _case(cases, "contain per-run sizing: the ceiling bounds the per-run term",
          rt(0.0, 10_000_000, 1_000_000, 4_000_000) == 1_000_000,
          "got %r" % (rt(0.0, 10_000_000, 1_000_000, 4_000_000),))
    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        now = [100.0]
        view = _two_tenant_tree()
        d = _two_tenant_daemon(tmp, view, now, contain_cap_bw=0.5)
        d.sweep()
        now[0] += 1.0
        view.procs[211]["schedstat"] += 3_100_000
        view.procs[211]["pcount"] = 30
        d.sweep()
        ct = d.contained[211]
        got = d._contain_requests().get(211)
        _case(cases, "contain per-run sizing: 3.1ms over 30 schedules gives a 103333ns run and sizes 206666",
              ct.run_ns == 103_333 and got == (206_666, d.contain_period_ns)
              and ct.to_status(None)["cpu_run_ns"] == 103_333,
              "run_ns %r got %r" % (ct.run_ns, got))
        now[0] += 1.0
        d.sweep()
        got = d._contain_requests().get(211)
        _case(cases, "contain per-run sizing: a window with no schedule-in clears the run and the thread falls to the floor",
              ct.run_ns is None and got == (MIN_THREAD_RUNTIME_NS, d.contain_period_ns)
              and ct.to_status(None)["cpu_run_ns"] is None,
              "run_ns %r got %r" % (ct.run_ns, got))


def _selftest_frame_period(cases):
    """test grant periods against the frame interval"""
    import contextlib
    import tempfile
    T = 11_666_666
    _case(cases, "frame period: the target with no interval yet",
          frame_period_ns([], T) == T and frame_period_ns(None, T) == T)
    _case(cases, "frame period: a 33.3 ms mean at an 11.67 ms target is 11 quarters of it, rounded down",
          frame_period_ns([33_333_333] * 32, T) == T * 11 // 4
          and frame_period_ns([40_000_000, 26_666_666] * 16, T) == T * 11 // 4,
          "got %r" % (frame_period_ns([40_000_000, 26_666_666] * 16, T),))
    _case(cases, "frame period: an interval jittering inside one quarter keeps one period",
          frame_period_ns([32_200_000] * 16, T) == frame_period_ns([34_900_000] * 16, T) == T * 11 // 4)
    _case(cases, "frame period: frames faster than the target keep the target, and a slow session stops at 4 targets",
          frame_period_ns([5_000_000] * 16, T) == T and frame_period_ns([900_000_000] * 16, T) == 4 * T,
          "got %r %r" % (frame_period_ns([5_000_000] * 16, T), frame_period_ns([900_000_000] * 16, T)))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        for _ in range(4):
            report(0.03, 1_000_000)
        report(0.06, 2_000_000, n=2)
        report(5.0, 900_000_000)
        _case(cases, "frame period: each live report adds its interval over the frames it carries, a gap adds none",
              list(s.frame_interval) == [30_000_000] * 6, "intervals %r" % (list(s.frame_interval),))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, report = _frame_rig(tmp)
        for _ in range(16):
            report(0.005, 1_000_000)
            report(0.026, 1_000_000)
        _case(cases, "frame period: reports read in bursts (5 then 26 ms) recur at their mean, rounded down to 15 ms, not at either gap",
              s.grant_period_ns() == 15_000_000, "period %r" % (s.grant_period_ns(),))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
        d, view, now, s, report = _frame_rig(tmp)
        for _ in range(6):
            report(0.03, 2_000_000)
        now[0] += REAPPLY_MIN_INTERVAL_S
        d.tick()
        _case(cases, "frame period: a thread drawing every 3 targets is granted its frame's runtime once per frame",
              d.grants.get(101, ())[:2] == (2_500_000, 30_000_000)
              and abs(d.reserved_bw("/rhizo") - 2_500_000 / 30_000_000) < 1e-9,
              "grant %r reserved %r" % (d.grants.get(101), d.reserved_bw("/rhizo")))
        _case(cases, "frame period: status reports the session's mean interval and its grant period",
              s.to_status(d.grants, now[0])["grant_period_ns"] == 30_000_000
              and s.to_status(d.grants, now[0])["frame_interval_mean_ns"] == 30_000_000)

    with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
        p = 16_666_667
        now = [10.0]
        view = _helper_fake_tree()
        d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view, clock=lambda: now[0])
        d.cap_bw = 1.0
        d.connections[1] = Connection(1, None, 1, None)
        s = Session("1", 1, 1, 10, 100, 10050, p)
        s.threads[201] = Thread(21, "RenderThread", "other", "other:-10")
        d.identity[201] = (100, 10050, view.procs[201]["start"])
        s.held = {201: 0.9}
        _seed_frames(s, 201, 4_000_000)
        s.frame_interval.extend([3 * p] * 16)
        s.last_actual = now[0]
        d.connections[1].sessions["1"] = s
        d.tick()
        periods = {c[1]: c[5] for c in sl.calls if c[0] == "grant"}
        _case(cases, "frame period: a held RenderThread's hwuiTask and binder helpers recur at its session's frame period",
              all(periods.get(t) == 3 * p for t in (201, 203, 204, 207, 208)), "periods %r" % (periods,))

    with tempfile.TemporaryDirectory() as tmp, _SchedLog(), contextlib.redirect_stderr(open(os.devnull, "w")):
        d, view, now, s, report = _frame_rig(tmp, cpu_a="100000 100000")
        for i in range(400):
            report(0.03, 3_000_000 if i % 4 == 3 else 1_000_000)
            _mark_deadline(d)
            if i % 50 == 49:
                d.sweep()
                _mark_deadline(d)
        st = d.carve.states.get("/rhizo")
        used = d.dl_cpu_ns.get("/rhizo", 0) / 1e9 / (400 * 0.03)
        reserved = d.reserved_bw("/rhizo")
        _case(cases, "frame period: an honest capped tenant drawing every 3 targets reserves what it uses with headroom",
              not d.reclaim_revoked and used <= reserved <= 3 * used and d.grants[101][1] == 30_000_000,
              "used %.4f reserved %.4f grant %r revoked %r" % (used, reserved, d.grants.get(101), d.reclaim_revoked))
        _case(cases, "frame period: the carve never takes less than the reserved bandwidth, and is sized from it",
              st is not None and reserved <= st.carve_bw <= quantize_carve(reserved) + CARVE_STEP_BW + 1e-9,
              "carve %r reserved %.4f" % (st and st.carve_bw, reserved))

    _case(cases, "hard period knob: unset and 2ms are the default 2 ms, frame keeps the grant's own period, anything else refuses",
          load_hard_period({}) == ("2ms", HARD_PERIOD_NS) == load_hard_period({HARD_PERIOD_ENV: "2ms"})
          and load_hard_period({HARD_PERIOD_ENV: "frame"}) == ("frame", None)
          and load_hard_period({HARD_PERIOD_ENV: "5ms"}) is None and load_hard_period({HARD_PERIOD_ENV: ""}) is None)
    _case(cases, "hard period knob: with no hard period a grant keeps its own runtime and period",
          hard_grant(2_500_000, 30_000_000, None) == (2_500_000, 30_000_000))
    global log
    real_log = log
    log = lambda msg: None
    try:
        for name, hp, want in (("2ms", HARD_PERIOD_NS, hard_grant(1_250_000, 10_000_000)),
                               ("frame", None, (1_250_000, 10_000_000))):
            with tempfile.TemporaryDirectory() as tmp, _SchedLog() as sl:
                now = [100.0]
                d = _two_tenant_daemon(tmp, _two_tenant_tree(), now, cpu_a="100000 100000", cap_bw=2.0)
                d.hard_period_name, d.hard_period_ns = name, hp
                _add_session(d, 1, 100, 10050, [101], 2_000_000, 0.5, now)
                d.reclaim_revoked["/rhizo"] = now[0]
                d.tick()
                d.write_status()
                with open(os.path.join(tmp, "status.json")) as f:
                    reported = json.load(f).get("hard_period")
                got = {c[1]: (c[2], c[5], c[3]) for c in sl.calls if c[0] == "grant"}
                _case(cases, "hard period knob %s: a tenant without RECLAIM is granted at %r and status says %s"
                      % (name, want[1], name),
                      got.get(101) == want + (SCHED_FLAG_RESET_ON_FORK,) and reported == name,
                      "got %r status %r" % (got, reported))
    finally:
        log = real_log


class _ReplaySocket:
    """queue of packets a replayed connection reads"""

    def __init__(self):
        """start with no queued packet"""
        self.queue = collections.deque()

    def recv(self, _size):
        """return the next queued packet"""
        if not self.queue:
            raise BlockingIOError
        return self.queue.popleft()

    def close(self):
        """close nothing"""


def _replay_view():
    """build the process view of a sandbox"""
    procs = {10: {"ns_ino": 701, "nspid_last": 1, "cgroup": "/rhizo/init", "ctx": ANDROID_INIT_CTX, "tgid": 10,
                  "uid": 0, "start": 1, "sched": (SCHED_OTHER, 0, 0)}}
    pid_tids = {10: [10]}
    ui = {400: "ndroid.systemui", 401: "RenderThread", 402: "hwuiTask0", 403: "hwuiTask1", 404: "binder:400_1"}
    pid_tids[400] = list(ui)
    for tid, comm in ui.items():
        procs[tid] = {"ns_ino": 701, "nspid_last": tid, "tgid": 400, "uid": 10072, "start": tid, "comm": comm,
                      "sched": (SCHED_OTHER, -10 if comm == "RenderThread" else 0, 0), "schedstat": 0}
    for tgid in (300, 301, 302):
        pid_tids[tgid] = [tgid]
        procs[tgid] = {"ns_ino": 701, "nspid_last": tgid, "tgid": tgid, "uid": 10108, "start": tgid,
                       "comm": "libpipeline.so", "sched": (SCHED_OTHER, 0, 0), "schedstat": 0}
    return FakeProcView(procs, pid_tids)


def _replay_script():
    """return the replayed packets"""
    out = []

    def at(us, packet, cpu=None, starts=None):
        """add a packet at a microsecond offset"""
        out.append((us, len(out), packet, cpu or {}, starts or {}))

    def deferred(us):
        """return the arrival time of a report"""
        slot = us // 100_000 * 100_000
        return slot + 30_000 if us - slot < 30_000 else us

    for us, line in ((0, "open 1 400 10072 16666667 401,400"), (1_000, "open 2 300 10108 10000000 300"),
                     (2_000, "open 3 301 10108 10000000 301"), (3_000, "open 4 302 10108 10000000 302"),
                     (4_000, "open 5 302 10108 10000000 302,999"), (5_000, "open 6 300 4321 10000000 300")):
        at(us, line.encode())
    us = 10_000
    while us < 3_700_000:
        if not 2_200_000 <= us < 2_500_000:
            heavy = 1_100_000 <= us < 1_900_000
            at(deferred(us), b"actual 1 %d" % (16_000_000 if heavy else 4_000_000),
               {401: 15_000_000 if heavy else 3_000_000, 400: 1_000_000, 402: 500_000, 404: 50_000})
        us += 16_667
    seed, k = 12345, 0
    while 100_000 + 20_000 * k < 3_500_000:
        end = 100_000 + 20_000 * k
        for sid, tgid, off in ((2, 300, 300), (3, 301, 700), (4, 302, 900)):
            cpu = 2 * (28_000 if sid == 2 else 32_000)
            if sid == 3:
                cpu = 0
                for _ in range(2):
                    seed = (seed * 1103515245 + 12345) % 2 ** 31
                    cpu += 380_000 + seed % 400_000
            at(deferred(end + off), b"actual %d 9000000,9100000" % sid, {tgid: cpu})
        k += 1
    at(2_200_000, b"pause 1")
    at(2_500_000, b"resume 1")
    at(2_700_000, b"target 1 11666666")
    at(2_800_000, b"threads 1 401,400,403")
    at(3_000_000, None, starts={403: 9_999})
    at(3_600_000, b"close 3")
    at(3_710_000, b"actual 1 4000000", {401: 3_000_000, 400: 1_000_000})
    at(5_000_000, b"")
    out.sort(key=lambda e: (e[0], e[1]))
    return [(100.0 + us / 1e6, packet, cpu, starts) for us, _i, packet, cpu, starts in out]


def _replay_run(coalesce):
    """replay the report script and return every decision"""
    import tempfile
    global sched_setattr, revoke_to_prior, write_status_atomic, log
    real = sched_setattr, revoke_to_prior, write_status_atomic, log
    now, record, writes, ticks, run, view = [100.0], [], [], [0], {}, _replay_view()

    def note(msg):
        """record a log line or scheduler call with the replay time"""
        record.append("%.6f %s" % (now[0], msg))

    def set_policy(tid, policy, nice, priority, what):
        """record a scheduler call and set the fake policy"""
        note(what)
        view.procs[tid]["sched"] = (policy, nice, priority)
        return True, 0
    sched_setattr = lambda tid, policy, flags=0, nice=0, priority=0, runtime=0, deadline=0, period=0: set_policy(
        tid, policy, nice, priority,
        "sched_setattr tid=%d policy=%d flags=%d runtime=%d period=%d" % (tid, policy, flags, runtime, period))
    revoke_to_prior = lambda tid, policy, nice, priority=0: set_policy(
        tid, policy, nice, priority, "revoke_to_prior tid=%d policy=%d nice=%d" % (tid, policy, nice))
    write_status_atomic = lambda path, status: writes.append((now[0], path, json.loads(json.dumps(status))))
    log = note
    try:
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "cg", "rhizo"))
            with open(os.path.join(tmp, "cg", "rhizo", "cpu.max"), "w") as f:
                f.write("200000 100000")
            d = Daemon(os.path.join(tmp, "rtd"), os.path.join(tmp, "status.json"), 25, view=view,
                       clock=lambda: now[0], cgroup_fs=os.path.join(tmp, "cg"))
            d.cpus, d.cap_bw = 4, 0.3
            d.carve.log = note
            c = Connection(1, _ReplaySocket(), 50, 701)
            d.connections[1] = c
            d.sandbox_ns_ino = 701
            d.refresh_tenants()
            key = selectors.SelectorKey(None, 0, selectors.EVENT_READ, c)
            real_tick = d.tick

            def counted_tick():
                """count a tick and run it"""
                ticks[0] += 1
                real_tick()
            d.tick = counted_tick
            script = _replay_script()
            end = script[-1][0] + 0.5
            i, last, wakes, left = 0, script[0][0], 0, 0
            while True:
                if c.sock.queue and 1 in d.connections:
                    wake = last
                elif i < len(script):
                    wake = min(script[i][0], last + REAPPLY_MIN_INTERVAL_S)
                elif last + REAPPLY_MIN_INTERVAL_S <= end:
                    wake = last + REAPPLY_MIN_INTERVAL_S
                else:
                    break
                now[0] = wake
                while i < len(script) and script[i][0] <= wake:
                    _t, packet, cpu, starts = script[i]
                    for tid, ns in cpu.items():
                        view.procs[tid]["schedstat"] += ns
                    for tid, start in starts.items():
                        view.procs[tid]["start"] = start
                    if packet is not None:
                        c.sock.queue.append(packet)
                    i += 1
                events = [(key, selectors.EVENT_READ)] if c.sock.queue and 1 in d.connections else []
                if coalesce:
                    d._wake(None, events)
                    left = max(left, len(c.sock.queue) if 1 in d.connections else 0)
                else:
                    for k, _mask in events:
                        d.on_readable(k.data)
                    t = d.clock()
                    if t - d._last_sweep >= SWEEP_INTERVAL_S:
                        d._last_sweep = t
                        d.sweep()
                    d.tick()
                    d.write_status()
                wakes += 1
                last = wake
            run.update(record=record, ticks=ticks[0], wakes=wakes, left=left, packets=len(script),
                       writes=[(t, st) for t, path, st in writes if path == d.status_path])
    finally:
        sched_setattr, revoke_to_prior, write_status_atomic, log = real
    return run


def _replay_decisions(record):
    """mask the per-plan demand statistics of a replay record"""
    return [re.sub(r" p50=\S+ p95=\S+", "", line) if " demand-over-slice: " in line else line for line in record]


def _status_without_plan_counts(status):
    """return a status without per-plan counts"""
    out = json.loads(json.dumps(status))
    for t in out.get("tenants", {}).values():
        for k in ("request_p50", "request_p95", "request_samples"):
            t.pop(k, None)
    return out


REPLAY_DECISIONS_SHA256 = "7b084e3c389c57d8d2aabf1284c76f38a5d1483f22d84a3ea1e2ced2c2a0db3e"


def _selftest_report_replay(cases):
    """compare uncoalesced and coalesced report replays"""
    import hashlib
    old, new = _replay_run(False), _replay_run(True)
    digest = hashlib.sha256("\n".join(_replay_decisions(old["record"])).encode()).hexdigest()
    _case(cases, "the replay through the loop before coalescing decides what the elapsed-time frame CPU split recorded (recorded digest)",
          digest == REPLAY_DECISIONS_SHA256, "digest %s over %d lines" % (digest, len(old["record"])))
    a, b = _replay_decisions(old["record"]), _replay_decisions(new["record"])
    first = next((j for j, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    kinds = collections.Counter(line.split(" ", 2)[1] for line in a)
    _case(cases, "the coalescing loop makes every grant, regrant, revoke, pause, refusal and cap decision at the same time as before",
          a == b and kinds["grant"] > 0 and kinds["regrant"] > 0 and kinds["revoke"] > 0 and kinds["refused"] >= 2
          and kinds["session"] > 0 and kinds["cap:"] > 0 and kinds["reclaim-off:"] > 0,
          "%d vs %d lines, first difference at %d: %r vs %r; kinds %r"
          % (len(a), len(b), first, a[first:first + 1], b[first:first + 1], dict(kinds)))
    old_at, new_at = dict(old["writes"]), dict(new["writes"])
    differ = [t for t, st in new_at.items() if _status_without_plan_counts(st) != _status_without_plan_counts(old_at.get(t))]
    _case(cases, "the last status the coalescing loop writes at each time equals the old loop's last one then, request counts aside",
          new_at and not differ, "%d write times, differing at %r" % (len(new_at), differ[:3]))
    grant_times = sorted({float(line.split(" ", 1)[0]) for line in b if " sched_setattr " in line or " revoke_to_prior " in line})
    write_times = [t for t, _st in new["writes"]]
    late = [t for t in grant_times if not any(t <= w <= t + 1.0 for w in write_times)]
    _case(cases, "a grant change reaches status.json within 1 s", grant_times and not late, "late after %r" % late[:3])
    _case(cases, "the coalescing loop writes status.json a tenth as often or less, and ticks less, than the old loop",
          10 * len(new["writes"]) <= len(old["writes"]) and new["ticks"] < old["ticks"],
          "writes %d vs %d, ticks %d vs %d" % (len(new["writes"]), len(old["writes"]), new["ticks"], old["ticks"]))
    _case(cases, "a wake reads every queued packet, so a burst costs one wake",
          new["left"] == 0 and new["wakes"] < old["wakes"],
          "left %d, wakes %d vs %d" % (new["left"], new["wakes"], old["wakes"]))


def _selftest_status_trailing(cases):
    """check a status change is written by a later wake"""
    import tempfile
    global write_status_atomic
    real = write_status_atomic
    writes = []
    try:
        with tempfile.TemporaryDirectory() as tmp, _SchedLog():
            d, view, now, s, _report = _frame_rig(tmp)
            write_status_atomic = lambda path, status: writes.append((now[0], path, json.loads(json.dumps(status))))
            s.held = {}
            c = d.connections[1]
            c.sock = _ReplaySocket()
            key = selectors.SelectorKey(None, 0, selectors.EVENT_READ, c)
            for dt in (0.0, 0.1):
                now[0] += dt
                view.procs[101]["schedstat"] += 1_000_000
                c.sock.queue.append(b"actual 1 5000000")
                d._wake(None, [(key, selectors.EVENT_READ)])
            second = now[0]
            mine = lambda: [(t, st) for t, path, st in writes if path == d.status_path]
            after_second = len(mine())
            for _ in range(int(STATUS_WRITE_INTERVAL_S / REAPPLY_MIN_INTERVAL_S) + 1):
                now[0] += REAPPLY_MIN_INTERVAL_S
                d._wake(None, [])
            last_t, last = mine()[-1]
            _case(cases, "a report inside the status write interval is not written at once but by a later wake within the interval",
                  after_second == 1 and second < last_t <= second + STATUS_WRITE_INTERVAL_S + REAPPLY_MIN_INTERVAL_S + 1e-9
                  and len(last["sessions"]["1:1"]["reports"]) == 2,
                  "writes %r" % [(t, len(st["sessions"]["1:1"]["reports"])) for t, st in mine()])
    finally:
        write_status_atomic = real


class _CountingView(FakeProcView):
    """fake process view that counts schedstat reads"""

    def __init__(self, view):
        """wrap another fake view's tables"""
        super().__init__(view.procs, view.pid_tids)
        self.reads = 0

    def schedstat_sum_exec(self, tid):
        """count and return the fake total run time of a thread"""
        self.reads += 1
        return super().schedstat_sum_exec(tid)


def _selftest_window_reads(cases):
    """check a tick inside a share window reads no schedstat"""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp, _SchedLog():
        d, view, now, s, _report = _frame_rig(tmp)
        d.view = counting = _CountingView(view)
        d.tick()
        first = counting.reads
        now[0] += 0.5
        d.tick()
        inside = counting.reads - first
        now[0] += 0.5
        d.tick()
        rolled = counting.reads - first - inside
        _case(cases, "a tick reads the session threads' schedstat when the share window opens or rolls, and none inside it",
              first == 1 and inside == 0 and rolled == 1, "reads %d, %d, %d" % (first, inside, rolled))


def _selftest_domain(cases):
    """test enter_domain's marker for each recorded SELinux mode"""
    import tempfile
    global log, SELINUXFS, ATTR_DIR
    saved = log, SELINUXFS, ATTR_DIR, read_selinux_mode.__defaults__
    lines = []
    log = lines.append
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "current"), "w") as f:
                f.write("kernel\0")
            mode = os.path.join(tmp, "mode")
            SELINUXFS, ATTR_DIR, read_selinux_mode.__defaults__ = tmp, tmp, (mode,)
            for text, want, refuse in (("namespace\n", "rtd_domain state=no-selinux mode=namespace", False),
                                       ("host\n", "rtd_domain state=deferred", False),
                                       ("namespaces\n", "rtd_domain failed reason=selinux-mode", True),
                                       (None, "rtd_domain failed reason=selinux-mode", True)):
                if text is None:
                    os.unlink(mode)
                else:
                    with open(mode, "w") as f:
                        f.write(text)
                del lines[:]
                code = None
                try:
                    enter_domain(DOMAIN, ["rtd.py"])
                except SystemExit as e:
                    code = e.code
                _case(cases, "a mode file reading %r logs %s" % (text, want), any(want in m for m in lines), lines)
                _case(cases, "a mode file reading %r %s" % (text, "refuses the start" if refuse else "lets it go on"),
                      code == (SELINUX_MODE_EXIT if refuse else None), "exit %r" % code)
    finally:
        log, SELINUXFS, ATTR_DIR, read_selinux_mode.__defaults__ = saved


def run_selftest():
    """run the selftest groups and print results"""
    cases = []
    groups = [
        _selftest_cap_math,
        _selftest_parked_bw,
        _selftest_runtime_rule,
        _selftest_protocol,
        _selftest_translation,
        _selftest_status_json,
        _selftest_sweep,
        _selftest_switched_away,
        _selftest_selinux_mode,
        _selftest_identity,
        _selftest_apply,
        _selftest_helpers,
        _selftest_helpers_red_check,
        _selftest_contain_scan,
        _selftest_contain_discovery,
        _selftest_contain_disabled,
        _selftest_contain_sizing,
        _selftest_contain_apply,
        _selftest_contain_identity,
        _selftest_contain_cap,
        _selftest_contain_pool_siblings,
        _selftest_contain_red_check,
        _selftest_slices,
        _selftest_tenant_isolation,
        _selftest_tenant_hysteresis,
        _selftest_carve_math,
        _selftest_carve_daemon,
        _selftest_carve_recover,
        _selftest_no_reclaim,
        _selftest_reclaim_revoke,
        _selftest_hard_grants,
        _selftest_demand,
        _selftest_crash_recovery,
        _selftest_record_ahead,
        _selftest_contain_measured,
        _selftest_contain_per_run,
        _selftest_frame_cpu,
        _selftest_frame_arrival,
        _selftest_frame_period,
        _selftest_window_reads,
        _selftest_status_trailing,
        _selftest_report_replay,
        _selftest_self_reserve,
        _selftest_peer_check,
        _selftest_namespace_peer,
        _selftest_domain,
        _selftest_red_check,
    ]
    for group in groups:
        try:
            group(cases)
        except Exception as exc:
            _case(cases, "%s raised %s: %s" % (group.__name__, type(exc).__name__, exc), False)

    failed = 0
    for name, ok, detail in cases:
        if ok:
            print("SELFTEST OK:   %s" % name)
        else:
            failed += 1
            print("SELFTEST FAIL: %s%s" % (name, (" -- %s" % detail) if detail else ""))
    if not cases:
        print("SELFTEST FAIL: no cases asserted")
        return 1
    print("rhizo-rtd selftest: %d/%d case(s) passed" % (len(cases) - failed, len(cases)))
    return 0 if failed == 0 else 1


def run_selftest_root():
    """test sched_setattr inside a new pid namespace"""
    if os.geteuid() != 0:
        print("SELFTEST-ROOT FAIL: must run as root (real threads, real sched_setattr)")
        return 1

    CLONE_NEWPID = 0x20000000
    libc = ctypes.CDLL("libc.so.6", use_errno=True)

    assertions = []

    def arec(name, ok, detail=""):
        """record and print a selftest-as-root assertion"""
        assertions.append((name, ok, detail))
        print("%s: %s%s" % ("SELFTEST-ROOT OK" if ok else "SELFTEST-ROOT FAIL", name,
                             (" -- %s" % detail) if detail else ""))

    r, w = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(r)
        rc = libc.unshare(CLONE_NEWPID)
        if rc != 0:
            os.write(w, b"unshare-failed:%d" % ctypes.get_errno())
            os._exit(1)
        grandchild = os.fork()
        if grandchild == 0:
            import threading
            ready = threading.Event()
            tids = []

            def spin():
                """record the thread id and wait"""
                tids.append(threading.get_native_id())
                ready.set()
                time.sleep(5)

            t = threading.Thread(target=spin, daemon=True)
            t.start()
            ready.wait(timeout=2)
            ns_tid = tids[0] if tids else 0
            os.write(w, ("ready:%d:%d" % (os.getpid(), ns_tid)).encode())
            time.sleep(5)
            os._exit(0)
        os.waitpid(grandchild, 0)
        os._exit(0)
    os.close(w)
    msg = os.read(r, 256).decode(errors="replace")
    os.close(r)

    if not msg.startswith("ready:"):
        arec("real pid namespace + real thread creation", False, "child reported %r" % msg)
        print("rhizo-rtd selftest-root: 0 assertions passed")
        return 1
    _, ns_pid_str, ns_tid_str = msg.split(":")
    ns_pid, ns_tid = int(ns_pid_str), int(ns_tid_str)
    arec("a child pid namespace boots and starts a real second thread", True)

    view = RealProcView()
    own_ino = view.ns_ino(os.getpid())
    host_ns_ino = None
    grandchild_host = None
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline and grandchild_host is None:
        for pid in view.pids():
            ppid = view._status_field(pid, "PPid")
            ino = view.ns_ino(pid)
            if ppid and int(ppid[0]) == child and ino is not None and ino != own_ino:
                host_ns_ino, grandchild_host = ino, pid
                break
    host_tgid = translate_tgid(view, host_ns_ino, ns_pid) if grandchild_host else None
    arec("translate_tgid finds the child's host tgid from its sandbox pid",
         host_tgid is not None and host_tgid == grandchild_host,
         "ns_pid=%d host=%r translated=%r" % (ns_pid, grandchild_host, host_tgid))

    if host_tgid is not None:
        host_tid, reason = translate_tid(view, host_ns_ino, host_tgid, ns_tid, os.getuid())
        arec("translate_tid finds the real second thread's host tid",
             host_tid is not None, "reason=%r" % reason)

        if host_tid is not None:
            forged_host, forged_reason = translate_tid(view, host_ns_ino, host_tgid, 999999, os.getuid())
            arec("translate_tid refuses a sandbox tid outside the child's own tgid",
                 forged_host is None, "got %r" % forged_host)

            probe = view.sched_probe(host_tid)
            arec("sched_getattr reads the real thread's starting policy/nice", probe is not None)
            prior_policy, prior_nice, _prior_priority = probe if probe else (SCHED_OTHER, 0, 0)

            ok, errno = grant_deadline(host_tid, 2_000_000, 16_666_667)
            arec("sched_setattr grants SCHED_DEADLINE on the real thread", ok, "errno=%d" % errno)

            if ok:
                after = view.sched_probe(host_tid)
                arec("the granted thread now reads back as SCHED_DEADLINE",
                     after is not None and after[0] == SCHED_DEADLINE, "got %r" % (after,))

                attr, _err = sched_getattr(host_tid)
                arec("a default grant reads back with SCHED_FLAG_RECLAIM set",
                     attr is not None and bool(attr.sched_flags & SCHED_FLAG_RECLAIM),
                     "flags %r" % (attr.sched_flags if attr else None))
                ok_nr, errno_nr = grant_deadline(host_tid, 2_000_000, 16_666_667, reclaim=False)
                attr, _err = sched_getattr(host_tid)
                arec("a reclaim=False grant, a capped tenant's, reads back without SCHED_FLAG_RECLAIM",
                     ok_nr and attr is not None and not attr.sched_flags & SCHED_FLAG_RECLAIM,
                     "errno=%d flags %r" % (errno_nr, attr.sched_flags if attr else None))

                ok2, errno2 = revoke_to_prior(host_tid, prior_policy, prior_nice)
                arec("revoke restores the prior policy and nice", ok2, "errno=%d" % errno2)
                if ok2:
                    restored = view.sched_probe(host_tid)
                    arec("the revoked thread reads back as its ORIGINAL policy",
                         restored is not None and restored[0] == prior_policy,
                         "got %r want %r" % (restored, prior_policy))

                period_ns = 16_666_667
                granted, _req, _grant, capped = plan_grants([(period_ns, {host_tid: 4_000_000})], 0.1)
                arec("plan_grants scales a request that would exceed a tiny cap",
                     capped is True and host_tid in granted and granted[host_tid][0] < 4_000_000,
                     "got %r" % (granted,))
                if host_tid in granted:
                    ok3, errno3 = grant_deadline(host_tid, granted[host_tid][0], period_ns)
                    arec("the kernel accepts the cap-scaled runtime as a real grant",
                         ok3, "errno=%d" % errno3)
                    if ok3:
                        revoke_to_prior(host_tid, prior_policy, prior_nice)

                dropped, _req2, _grant2, capped2 = plan_grants([(period_ns, {host_tid: 4_000_000})], 0.001)
                arec("plan_grants drops a request a nearly spent cap would cut under 200us",
                     dropped == {} and capped2 is True, "got %r" % (dropped,))

    if grandchild_host is not None:
        try:
            os.kill(grandchild_host, 9)
        except ProcessLookupError:
            pass
    try:
        os.waitpid(child, 0)
    except OSError:
        pass

    passed = sum(1 for _n, ok, _d in assertions if ok)
    failed = len(assertions) - passed
    if not assertions:
        print("rhizo-rtd selftest-root: 0 assertions passed")
        return 1
    if failed:
        print("rhizo-rtd selftest-root: %d/%d assertions passed" % (passed, len(assertions)))
        return 1
    print("rhizo-rtd selftest-root: %d assertions passed" % passed)
    return 0


DOMAIN = "u:r:rhizo_rtd:s0"
SELINUXFS = "/sys/fs/selinux"
ATTR_DIR = "/proc/self/attr"
ENTERING_ENV = "RHIZO_RTD_ENTERING"


SELINUX_MODE_EXIT = 78


def read_selinux_mode(path=os.environ.get("RHIZO_SELINUX_MODE_FILE", "/run/rhizo-selinux-mode")):
    """return the recorded SELinux mode, or None"""
    try:
        with open(path) as f:
            mode = f.read().rstrip("\n")
    except OSError as e:
        log("RHIZO_MARKER rtd_domain failed reason=selinux-mode mode-file=%s errno=%s" % (path, e.errno))
        return None
    if mode not in ("host", "namespace"):
        log("RHIZO_MARKER rtd_domain failed reason=selinux-mode mode-file=%s value=%r" % (path, mode))
        return None
    return mode


def enter_domain(ctx, argv):
    """re-exec argv in the SELinux context ctx and return the mode"""
    mode = read_selinux_mode()
    if mode is None:
        sys.exit(SELINUX_MODE_EXIT)
    if mode == "namespace":
        log("RHIZO_MARKER rtd_domain state=no-selinux mode=namespace want=%s" % ctx)
        return mode
    try:
        os.stat(SELINUXFS)
    except FileNotFoundError:
        log("RHIZO_MARKER rtd_domain state=no-selinux want=%s" % ctx)
        return mode
    except OSError:
        pass
    with open(os.path.join(ATTR_DIR, "current")) as f:
        cur = f.read().rstrip("\0\n")
    if cur == ctx:
        os.environ.pop(ENTERING_ENV, None)
        log("RHIZO_MARKER rtd_domain entered=%s" % ctx)
        return mode
    if cur == "kernel":
        log("RHIZO_MARKER rtd_domain state=deferred current=%s want=%s" % (cur, ctx))
        return mode
    if cur == "u:r:kernel:s0":
        log("RHIZO_MARKER rtd_domain failed reason=domain-kernel current=%s want=%s" % (cur, ctx))
        sys.exit(1)
    if os.environ.get(ENTERING_ENV):
        log("RHIZO_MARKER rtd_domain failed reason=domain-refused current=%s want=%s" % (cur, ctx))
        sys.exit(1)
    with open(os.path.join(ATTR_DIR, "exec"), "w") as f:
        f.write(ctx)
    os.environ[ENTERING_ENV] = "1"
    os.execv(sys.executable, [sys.executable] + argv)


def main(argv=None):
    """parse arguments and run rhizo-rtd"""
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--status-path", default=DEFAULT_STATUS_PATH)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--selftest-root", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        return run_selftest()
    if args.selftest_root:
        return run_selftest_root()

    selinux_mode = enter_domain(DOMAIN, sys.argv)
    hard_period = load_hard_period()
    if hard_period is None:
        log("%s=%r is neither 2ms nor frame -- refusing to start" % (HARD_PERIOD_ENV, os.environ.get(HARD_PERIOD_ENV)))
        return 1
    log("hard-period: %s" % hard_period[0])
    cap_percent = load_cap_percent()
    contain_enabled, contain_percent, contain_runtime_ns, contain_period_ns = load_contain_config()
    budgets_enabled = rt_budgets_enabled()
    os.makedirs(os.path.dirname(args.status_path), exist_ok=True)
    daemon = Daemon(args.socket, args.status_path, cap_percent,
                     contain_enabled=contain_enabled, contain_cap_percent=contain_percent,
                     contain_runtime_ns=contain_runtime_ns, contain_period_ns=contain_period_ns,
                     self_reserve=(budgets_enabled or contain_enabled), hard_period=hard_period,
                     selinux_mode=selinux_mode)
    signal.signal(signal.SIGTERM, lambda _sig, _frame: sys.exit(0))
    daemon.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
