"""relay the host's power supplies into the host-battery file"""
import errno
import fcntl
import json
import math
import os
import signal
import socket
import stat
import time

from sandbox import core
from sandbox.core import HOST_BATTERY_FILE, RHIZO_DEVICE_STATE_DIR, RHIZO_STATE_DIR, kmsg
from sandbox.rootfs import device_state_dir_refusal, parse_uevent

SUPPLY_CLASS = "/sys/class/power_supply"
NETLINK_KOBJECT_UEVENT = 15
UEVENT_GROUP = 1
UEVENT_MAX = 8192
DRAIN_MAX = 256
ATTR_MAX = 256
POLL_S = 30
RETRY_S = 1.0
COALESCE_S = 0.25
SLOW_SCAN_MS = 5000
CLEAR_TRIES = 5
CLEAR_RETRY_S = 0.2
TEMP_MIN_DC, TEMP_MAX_DC = -400, 1500
NO_BATTERY = b"version=1\npresent=0\nend=1\n"
FILE_MAX = 4096
HELPER_REPLY_MAX = 65536
NOBODY = 65534
PR_SET_PDEATHSIG, PR_SET_NO_NEW_PRIVS = 1, 38

CHARGER_KINDS = {
    "Mains": "ac", "UPS": "ac", "USB_DCP": "ac", "USB_HVDCP": "ac", "USB_CDP": "ac", "USB_ACA": "ac",
    "USB_C": "ac", "USB_PD": "ac",
    "USB": "usb", "USB_PD_DRP": "usb",
    "Wireless": "wireless",
}
STATUSES = {"Charging": "charging", "Discharging": "discharging", "Not charging": "not-charging", "Full": "full"}
BATTERY_ATTRS = ("status", "capacity", "health", "technology", "voltage_now", "voltage_min_design",
                 "current_now", "current_avg", "power_now", "power_avg", "temp", "charge_counter", "charge_now",
                 "charge_full", "charge_full_design", "energy_now", "energy_full", "energy_full_design", "cycle_count",
                 "time_to_full_now")
CHARGER_ATTRS = ("online", "current_max", "voltage_max", "voltage_max_design")
TEXT_ATTRS = ("status", "health", "technology")
SUMMED = (("current_now_ua", "current_now"), ("current_avg_ua", "current_avg"),
          ("charge_counter_uah", "charge_counter"), ("charge_full_uah", "charge_full"),
          ("charge_full_design_uah", "charge_full_design"), ("energy_now_uwh", "energy_now"))
MAXED = (("temp_dc", "temp"), ("cycle_count", "cycle_count"), ("time_to_full_s", "time_to_full_now"))
KEY_ORDER = ("batteries", "level", "status", "health", "technology", "voltage_uv", "current_now_ua",
             "current_avg_ua", "temp_dc", "charge_counter_uah", "charge_full_uah", "charge_full_design_uah",
             "energy_now_uwh", "cycle_count", "time_to_full_s", "ac_online", "usb_online", "wireless_online",
             "max_charging_current_ua", "max_charging_voltage_uv")


ABSENT, FAILED = "absent", "failed"


def read_attr_status(root, rel, denied=None):
    """return an attribute's text and error status under root"""
    try:
        if isinstance(root, int):
            fd = os.open(rel, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=root)
        else:
            fd = os.open(os.path.join(root, rel), os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, ABSENT
    except OSError as e:
        if denied is not None and isinstance(e, PermissionError):
            denied.add(os.path.basename(rel))
        return None, FAILED
    try:
        return os.read(fd, ATTR_MAX).decode("ascii", "replace").strip(), None
    except OSError:
        return None, FAILED
    finally:
        os.close(fd)


def read_attr(root, rel):
    """return the stripped text of rel under root, or None"""
    return read_attr_status(root, rel)[0]


def supply_names(root):
    """return the supply names under root, sorted"""
    try:
        return sorted(n for n in os.listdir(root) if not n.startswith("."))
    except OSError:
        return []


def scan(root, denied=None):
    """return the counted batteries and chargers under root"""

    def get(rel):
        """read an attribute under root"""
        return read_attr_status(root, rel, denied)

    batteries, chargers = [], []
    for name in supply_names(root):
        kind = get(f"{name}/type")[0]
        scope, scope_err = get(f"{name}/scope")
        if kind is None or scope_err == FAILED or scope == "Device":
            continue
        if kind == "Battery":
            present, present_err = get(f"{name}/present")
            if present not in (None, "1"):
                continue
            read = {a: get(f"{name}/{a}") for a in BATTERY_ATTRS}
            if present_err == FAILED and read["status"][1] == FAILED and read["capacity"][1] == FAILED:
                continue
            if get(f"{name}/type")[0] != kind:
                continue
            batteries.append((name, {a: text for a, (text, _) in read.items()}))
        elif kind in CHARGER_KINDS:
            chargers.append((name, CHARGER_KINDS[kind], {a: get(f"{name}/{a}")[0] for a in CHARGER_ATTRS}))
    return batteries, chargers


def _int(text):
    """return text as an integer, or None"""
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def _round(x):
    """return x rounded half up"""
    return int(math.floor(x + 0.5))


def _token(text):
    """return a kernel enum string as a host-battery token"""
    return "".join(c for c in text.lower().replace(" ", "-") if c.isalnum() or c == "-")


def battery_values(attrs, dropped=None):
    """return a battery's plausible values in host-battery units"""
    num = {a: _int(attrs.get(a)) for a in BATTERY_ATTRS if a not in TEXT_ATTRS}
    for name, plausible in (("temp", lambda x: TEMP_MIN_DC <= x <= TEMP_MAX_DC),
                            ("energy_now", lambda x: x >= 0), ("time_to_full_now", lambda x: x >= 0)):
        if num[name] is not None and not plausible(num[name]):
            num[name] = None
            if dropped is not None:
                dropped.add(name)
    status = STATUSES.get(attrs.get("status"), "unknown")
    volts = next((v for v in (num["voltage_min_design"], num["voltage_now"]) if v and v > 0), None)

    def charge(charge_attr, energy_attr):
        """return the charge attribute, else the energy over the voltage"""
        if num[charge_attr] is not None:
            return num[charge_attr]
        if num[energy_attr] is not None and volts:
            return _round(num[energy_attr] * 1e6 / volts)
        return None

    def energy(energy_attr, charge_attr):
        """return the energy attribute, else the charge times the voltage"""
        if num[energy_attr] is not None:
            return num[energy_attr]
        if num[charge_attr] is not None and volts:
            return _round(num[charge_attr] * volts / 1e6)
        return None

    counter = num["charge_counter"] if num["charge_counter"] is not None else charge("charge_now", "energy_now")
    v = {"status": status, "capacity": num["capacity"], "voltage_now": num["voltage_now"],
         "temp": num["temp"], "cycle_count": num["cycle_count"], "time_to_full_now": num["time_to_full_now"],
         "energy_now": num["energy_now"], "charge_counter": counter,
         "charge_full": charge("charge_full", "energy_full"),
         "charge_full_design": charge("charge_full_design", "energy_full_design"),
         "level_now": energy("energy_now", "charge_now"), "level_full": energy("energy_full", "charge_full")}
    for key in ("charge_counter", "charge_full", "charge_full_design"):
        if v[key] is not None and v[key] < 0:
            v[key] = None
    volts_now = num["voltage_now"] if num["voltage_now"] and num["voltage_now"] > 0 else None
    for key, rate in (("current_now", "power_now"), ("current_avg", "power_avg")):
        c = num[key]
        if c is None and num[rate] is not None and volts_now:
            c = _round(num[rate] * 1e6 / volts_now)
        # ACPI reports an unsigned current while discharging
        v[key] = -c if c is not None and c > 0 and status == "discharging" else c
    health = attrs.get("health")
    v["health"] = _token(health) if health else None
    tech = attrs.get("technology")
    v["technology"] = tech if tech and tech != "Unknown" else None
    return v


def _level(values):
    """return the batteries' combined level"""
    if all(b["level_now"] is not None and b["level_full"] for b in values) and (
            len(values) > 1 or values[0]["capacity"] is None):
        total = sum(b["level_full"] for b in values)
        return _round(100 * sum(b["level_now"] for b in values) / total) if total > 0 else None
    caps = [b["capacity"] for b in values if b["capacity"] is not None]
    return _round(sum(caps) / len(caps)) if caps else None


def _status(values):
    """return the batteries' combined status"""
    states = [b["status"] for b in values]
    for want in ("charging", "discharging"):
        if want in states:
            return want
    if all(s == "full" for s in states):
        return "full"
    return "not-charging" if "not-charging" in states else "unknown"


def _health(values):
    """return the batteries' worst health"""
    healths = [b["health"] for b in values if b["health"]]
    if not healths:
        return None
    bad = next((h for h in healths if h not in ("good", "unknown")), None)
    return bad or ("good" if "good" in healths else "unknown")


def _max_charging(chargers):
    """return the strongest online charger's current and voltage"""
    pairs = []
    for _, _, attrs in chargers:
        current = _int(attrs.get("current_max"))
        volts = next((v for v in (_int(attrs.get("voltage_max")), _int(attrs.get("voltage_max_design")))
                      if v is not None), None)
        if _online(attrs) and current and volts and current > 0 and volts > 0:
            pairs.append((current * volts, current, volts))
    return max(pairs)[1:] if pairs else None


def _online(attrs):
    """return true when a charger reads online"""
    online = _int(attrs.get("online"))
    return online is not None and online > 0


def aggregate(batteries, chargers, dropped=None):
    """return host-battery's key and value pairs in v1 order"""
    if not batteries:
        return None
    values = [battery_values(attrs, dropped) for _, attrs in batteries]
    level = _level(values)
    if level is None:
        return None
    out = {"batteries": len(values), "level": max(0, min(100, level)),
           "status": _status(values), "health": _health(values), "technology": values[0]["technology"],
           "voltage_uv": values[0]["voltage_now"]}
    for key, field in SUMMED:
        have = [b[field] for b in values]
        out[key] = sum(have) if all(x is not None for x in have) else None
    for key, field in MAXED:
        have = [b[field] for b in values if b[field] is not None]
        out[key] = max(have) if have else None
    for kind in ("ac", "usb", "wireless"):
        out[f"{kind}_online"] = int(any(_online(a) for _, k, a in chargers if k == kind))
    pair = _max_charging(chargers)
    out["max_charging_current_ua"], out["max_charging_voltage_uv"] = pair if pair else (None, None)
    return [(k, out[k]) for k in KEY_ORDER if out[k] is not None]


def render(pairs):
    """return the host-battery v1 bytes of aggregated pairs"""
    if not pairs:
        return NO_BATTERY
    return ("version=1\npresent=1\n" + "".join(f"{k}={v}\n" for k, v in pairs) + "end=1\n").encode()


def describe(pairs, batteries=0):
    """return the log line of a write"""
    if not pairs:
        return "rhizo-battery: present=0 batteries=%d" % batteries
    kv = dict(pairs)
    return "rhizo-battery: level=%s status=%s ac=%s batteries=%s" % (
        kv.get("level", "-"), kv.get("status", "-"), kv.get("ac_online", "-"), kv.get("batteries", "-"))


def write_in_place(dir_fd, name, data):
    """rewrite name under dir_fd in place under an exclusive lock"""
    fd = os.open(name, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, f"{name} is not a regular file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        os.pwrite(fd, data, 0)
        os.ftruncate(fd, len(data))
        return True
    finally:
        os.close(fd)


def _errname(e):
    """return an OSError's errno name"""
    return errno.errorcode.get(getattr(e, "errno", None), e.__class__.__name__)


def read_host(root):
    """scan, aggregate and render the supplies under root"""
    dropped, denied = set(), set()
    batteries, chargers = scan(root, denied)
    pairs = aggregate(batteries, chargers, dropped)
    return render(pairs), pairs, len(batteries), dropped, denied


def drop_privileges(uid=NOBODY, gid=NOBODY, ops=os, no_new_privs=None, status_path="/proc/self/status"):
    """drop all groups and capabilities and become uid:gid"""
    ops.setgroups([])
    ops.setresgid(gid, gid, gid)
    ops.setresuid(uid, uid, uid)
    if (no_new_privs or _no_new_privs)() != 0:
        raise OSError(errno.EPERM, "no_new_privs refused")
    if ops.getresuid() != (uid, uid, uid) or ops.getresgid() != (gid, gid, gid) or ops.getgroups():
        raise OSError(errno.EPERM, "the drop to %d:%d did not hold" % (uid, gid))
    with open(status_path) as handle:
        caps = {k: v.strip() for k, _, v in (l.partition(":") for l in handle) if k in ("CapPrm", "CapEff", "CapAmb")}
    if len(caps) != 3 or any(int(v, 16) for v in caps.values()):
        raise OSError(errno.EPERM, "capabilities survived the drop: %s" % caps)


def _no_new_privs():
    """set no_new_privs on this process"""
    return core.libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)


def _serve(sock, supplies_fd, parent, drop, scan_fn, timer, keep=()):
    """run the scan helper as nobody, scanning per request"""
    core.libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)
    if os.getppid() != parent:
        return 1
    core.stdio_to_null()
    owned = {sock.fileno(), supplies_fd, *keep}
    for name in os.listdir("/proc/self/fd"):
        if int(name) > 2 and int(name) not in owned:
            try:
                os.close(int(name))
            except OSError:
                pass
    refused = None
    if drop:
        try:
            drop_privileges()
        except OSError as e:
            refused = "privilege-drop:%s" % _errname(e)
    while True:
        if not sock.recv(16):
            return 0
        start = timer()
        if refused:
            reply = {"error": refused}
        else:
            try:
                data, pairs, batteries, dropped, denied = scan_fn(supplies_fd)
                reply = {"data": data.decode("ascii"), "pairs": pairs, "batteries": batteries,
                         "dropped": sorted(dropped), "denied": sorted(denied)}
            except Exception as e:
                reply = {"error": "scan:%s" % e.__class__.__name__}
        reply["ms"] = int((timer() - start) * 1000)
        sock.send(json.dumps(reply).encode()[:HELPER_REPLY_MAX])


class ScanHelper:
    """a forked process that scans the supplies dirfd as nobody"""

    def __init__(self, supplies_fd, timer=time.monotonic, scan_fn=None, drop=True, keep=()):
        """fork the helper over a seqpacket pair"""
        ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET | socket.SOCK_CLOEXEC)
        parent = os.getpid()
        pid = os.fork()
        if pid == 0:
            code = 1
            try:
                ours.close()
                code = _serve(theirs, supplies_fd, parent, drop, scan_fn or read_host, timer, keep)
            except BaseException:
                code = 1
            finally:
                os._exit(code)
        theirs.close()
        os.close(supplies_fd)
        ours.setblocking(False)
        self.pid, self.owner, self.sock, self.fd = pid, parent, ours, ours.fileno()

    def submit(self):
        """send the helper a scan request"""
        try:
            self.sock.send(b"s")
        except (BrokenPipeError, ConnectionResetError):
            raise RuntimeError("the scan helper exited") from None

    def take(self):
        """return the helper's finished scan, or None"""
        try:
            raw = self.sock.recv(HELPER_REPLY_MAX)
        except BlockingIOError:
            return None
        except ConnectionResetError:
            raw = b""
        if not raw:
            raise RuntimeError("the scan helper exited")
        reply = json.loads(raw)
        ms = reply.get("ms")
        if not isinstance(ms, int) or ms < 0:
            raise ValueError("the scan helper sent no scan time")
        if "error" in reply:
            return RuntimeError("scan helper: %s" % reply["error"]), ms
        data, pairs, batteries = reply.get("data"), reply.get("pairs"), reply.get("batteries")
        if not (isinstance(data, str) and len(data) <= FILE_MAX and data.startswith("version=1\npresent=")
                and data.endswith("\nend=1\n") and isinstance(batteries, int) and batteries >= 0):
            raise ValueError("the scan helper sent a malformed reading")
        dropped, denied = set(reply.get("dropped") or ()), set(reply.get("denied") or ())
        return (data.encode("ascii"), [tuple(p) for p in pairs] if pairs else None, batteries, dropped, denied), ms

    def close(self):
        """close g's end and kill the helper"""
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        if self.pid and os.getpid() == self.owner:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, os.WNOHANG)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None


class BatteryRelay:
    """the host battery relay in g's resident loop"""

    def __init__(self, sock, state_fd, worker, written=NO_BATTERY, log=kmsg, clock=time.monotonic, poll_s=POLL_S):
        """store the relay's host handles and host-battery's bytes"""
        self.sock, self.state_fd, self.worker = sock, state_fd, worker
        self.written, self.batteries, self.summary, self.dropped = written, None, None, set()
        self.log, self.clock, self.poll_s = log, clock, poll_s
        self.due, self.last_start, self.in_flight, self.next_poll = clock(), None, False, None
        self.pending, self.retry_at = None, None
        self.failed, self.done, self.clear_at, self.clear_tries = "", False, None, 0

    def begin(self):
        """arm the relay when host-battery is staged"""
        try:
            staged = stat.S_ISREG(os.stat(HOST_BATTERY_FILE, dir_fd=self.state_fd, follow_symlinks=False).st_mode)
        except FileNotFoundError:
            staged = False
        if not staged:
            self.failed = "unstaged"
            self.close()
            self.log("RHIZO_MARKER battery_relay=failed reason=unstaged -- no host-battery was staged, "
                     "Android reports no battery")
        return staged

    def fds(self):
        """return the descriptors to select on"""
        if self.done or self.failed:
            return []
        return ([self.sock] if self.sock is not None else []) + [self.worker.fd]

    def wait_s(self):
        """return seconds to the next timed step, or None"""
        if self.done:
            return None
        times = ([self.clear_at] if self.failed else
                 [self.next_poll, self.retry_at] + ([] if self.in_flight else [self.due]))
        times = [t for t in times if t is not None]
        return max(0.0, min(times) - self.clock()) if times else None

    def handle(self, ready):
        """handle ready descriptors and due timers"""
        if self.done:
            return
        now = self.clock()
        if self.failed:
            if self.clear_at is not None and now >= self.clear_at:
                self._clear()
            return
        if self.sock is not None and self.sock in ready and self._drain():
            self._want(now + COALESCE_S)
        if self.next_poll is not None and now >= self.next_poll:
            self.next_poll = None
            self._want(now)
        if self.worker.fd in ready:
            got = self.worker.take()
            if got is not None:
                self._landed(*got)
        if not self.failed and self.retry_at is not None and now >= self.retry_at:
            self._write(*self.pending)
        if not self.failed and self.due is not None and not self.in_flight and now >= self.due:
            self.in_flight, self.last_start, self.due = True, now, None
            self.worker.submit()

    def _want(self, at):
        """schedule a scan at or after at"""
        if self.due is None:
            self.due = at if self.last_start is None else max(at, self.last_start + COALESCE_S)

    def _drain(self):
        """return true when a queued uevent names a power supply"""
        hit = False
        for _ in range(DRAIN_MAX):
            try:
                buf, addr = self.sock.recvfrom(UEVENT_MAX)
            except BlockingIOError:
                break
            except OSError as e:
                if e.errno != errno.ENOBUFS:
                    raise
                hit = True
                continue
            if not (isinstance(addr, tuple) and addr and addr[0] == 0):
                continue
            ev = parse_uevent(buf)
            if ev and ev.get("SUBSYSTEM") == "power_supply":
                hit = True
        return hit

    def _landed(self, result, ms):
        """log a finished scan and write it when it changed"""
        self.in_flight = False
        if isinstance(result, Exception):
            raise result
        data, pairs, batteries, dropped, denied = result
        if ms > SLOW_SCAN_MS:
            self.log(f"RHIZO_MARKER battery_relay=slow scan_ms={ms}")
        for name in sorted(dropped - self.dropped):
            self.log(f"rhizo-battery: ignoring {name}, outside what a battery reports")
        for name in sorted(denied - self.dropped):
            self.log(f"RHIZO_MARKER battery_relay=denied attr={name} -- the scan helper, as nobody, may not read it")
        self.dropped |= dropped | denied
        if self.batteries is None:
            self.log(f"RHIZO_MARKER battery_relay=listening batteries={batteries} "
                     f"poll={self.poll_s if batteries else 'none'}")
        self.batteries = batteries
        self.next_poll = self.clock() + self.poll_s if batteries else None
        if data != self.written:
            self._write(data, pairs)

    def _write(self, data, pairs):
        """rewrite host-battery in place, retrying while it is locked"""
        try:
            wrote = write_in_place(self.state_fd, HOST_BATTERY_FILE, data)
        except OSError as e:
            self.stop(f"write:{_errname(e)}")
            return
        if not wrote:
            self.pending, self.retry_at = (data, pairs), self.clock() + RETRY_S
            return
        self.written, self.pending, self.retry_at = data, None, None
        line = describe(pairs, self.batteries or 0)
        if line != self.summary:
            self.summary = line
            self.log(line)

    def stop(self, why):
        """stop relaying and clear host-battery to no battery"""
        if self.failed:
            return
        self.failed = why
        self._close_sources()
        self.log(f"RHIZO_MARKER battery_relay=failed reason={why}")
        if self.state_fd is None:
            self._finish("last-reading")
        else:
            self._clear()

    def _clear(self):
        """write no battery to host-battery"""
        try:
            cleared = write_in_place(self.state_fd, HOST_BATTERY_FILE, NO_BATTERY)
        except FileNotFoundError:
            return self._finish("absent")
        except OSError:
            return self._finish("last-reading")
        if cleared:
            return self._finish("no-battery")
        self.clear_tries += 1
        if self.clear_tries >= CLEAR_TRIES:
            return self._finish("last-reading")
        self.clear_at = self.clock() + CLEAR_RETRY_S
        return None

    def _finish(self, state):
        """end the relay and log what host-battery holds now"""
        self.done, self.clear_at = True, None
        self.close()
        self.log(f"RHIZO_MARKER battery_relay=stopped host_battery={state} -- {FINISHED[state]}")

    def _close_sources(self):
        """close the uevent socket and the scan worker"""
        if self.sock is not None:
            self.sock.close()
            self.sock = None
        if self.worker is not None:
            self.worker.close()
            self.worker = None

    def close(self):
        """close the relay's descriptors"""
        self._close_sources()
        if self.state_fd is not None:
            os.close(self.state_fd)
            self.state_fd = None
        self.done = True


FINISHED = {"no-battery": "host-battery reads no battery, Android reports no battery",
            "absent": "host-battery is gone, Android reports no battery",
            "last-reading": "host-battery still holds the last reading written, which Android keeps showing"}


def open_uevent_socket():
    """return a nonblocking socket on the kernel's uevent group"""
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC,
                         NETLINK_KOBJECT_UEVENT)
    try:
        sock.bind((0, UEVENT_GROUP))
    except OSError:
        sock.close()
        raise
    return sock


def open_relay(supplies=SUPPLY_CLASS, state_dir=RHIZO_DEVICE_STATE_DIR, state_root=RHIZO_STATE_DIR, log=kmsg,
               open_socket=open_uevent_socket, clock=time.monotonic, worker_fn=ScanHelper):
    """return a relay over newly opened host handles, or None"""
    opened, sock, step = [], None, "supplies"
    try:
        supplies_fd = os.open(supplies, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        opened.append(supplies_fd)
        step = "state-dir"
        why = device_state_dir_refusal(state_dir, state_root)
        if why:
            raise ValueError(why)
        os.makedirs(state_dir, exist_ok=True)
        state_fd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        opened.append(state_fd)
        step = "uevent"
        sock = open_socket()
        step = "worker"
        worker = worker_fn(supplies_fd)
    except Exception as e:
        for fd in opened:
            os.close(fd)
        if sock is not None:
            sock.close()
        why = str(e) if isinstance(e, ValueError) else _errname(e)
        log(f"RHIZO_MARKER battery_relay=failed reason=open:{step}:{why} -- Android reports no battery")
        return None
    return BatteryRelay(sock, state_fd, worker, NO_BATTERY, log=log, clock=clock)


def arm(source, host_mode=False, domain="", log=kmsg, open_fn=None):
    """open the relay for the host battery source"""
    if source != "host":
        core.set_host_battery(None)
        return None
    core.set_host_battery(NO_BATTERY)
    if host_mode and (domain == "kernel" or domain.startswith("u:r:kernel:")):
        log("RHIZO_MARKER battery_relay=failed reason=host-mode-kernel-domain -- Android reports no battery")
        return None
    return (open_fn or open_relay)(log=log)


SHUTDOWN_DIR = "bootstat"
SHUTDOWN_FILE = "persist.sys.boot.reason"
SHUTDOWN_MAX = 128


class ShutdownReason:
    """the shutdown reason Android's init persists under /metadata"""

    def __init__(self, metadata_dir, log=kmsg):
        """open the sandbox's /metadata and stamp the reason file"""
        self.log = log
        try:
            self.fd = os.open(metadata_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        except OSError as e:
            self.fd = -1
            log(f"shutdown reason: {metadata_dir} unopenable ({_errname(e)}) -- no android_shutdown marker")
        self.before = self._stamp()

    def _open(self):
        """return the reason file's fd without following links, or -1"""
        if self.fd < 0:
            return -1
        try:
            dfd = os.open(SHUTDOWN_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self.fd)
        except OSError:
            return -1
        try:
            fd = os.open(SHUTDOWN_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dfd)
        except OSError:
            return -1
        finally:
            os.close(dfd)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            return -1
        return fd

    def _stamp(self):
        """return the reason file's identity and change time, or None"""
        fd = self._open()
        if fd < 0:
            return None
        try:
            st = os.fstat(fd)
            return (st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size)
        finally:
            os.close(fd)

    def reason(self):
        """return the reason when the file changed during this launch"""
        fd = self._open()
        if fd < 0:
            return None
        try:
            st = os.fstat(fd)
            if (st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size) == self.before:
                return None
            raw = os.read(fd, SHUTDOWN_MAX).decode("ascii", "replace").strip()
        except OSError:
            return None
        finally:
            os.close(fd)
        return "".join(c if c.isalnum() or c in ",._:-" else "_" for c in raw) or None

    def report(self):
        """log the android_shutdown marker for a changed reason"""
        why = self.reason()
        if why:
            self.log(f"RHIZO_MARKER android_shutdown reason={why}")
        return why

    def close(self):
        """close the /metadata dirfd"""
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1
