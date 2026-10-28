#!/usr/bin/env python3

import os
import re
import subprocess
import sys
import time


def _instanced(base, sandbox_id, sep="-"):
    """return the instance name for the sandbox id"""
    return base if sandbox_id == 0 else "%s%s%d" % (base, sep, sandbox_id)


SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
RUN_ROOT = _instanced("/run/rhizo", SANDBOX_ID)
HOST_DATA = RUN_ROOT + "/data/"
CONTROL_OUT = HOST_DATA + "rhizo_control/control.out"
CONTROL_IN = "/data/rhizo_control/control"
SCALED_RE = re.compile(r"^display scaled id=(\d+) port=(\d+) scale=(\d+(?:\.\d+)?) dpi=(\d+)")
BORN_RE = re.compile(r"^display (?:pooled|powered|added) id=(\d+) port=(\d+)")
GONE_RE = re.compile(r"^display (?:remove id=(\d+) ok|spare-released id=(\d+))")
CURSOR_UNKNOWN_RE = re.compile(r"^display cursor-unknown id=(\d+) port=(-?\d+) digest=(\d+)")
BASE_SCALE = 1


def log(msg):
    """write a timestamped message to stderr"""
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def read_fd(fd, offset, end):
    """read the bytes of fd from offset"""
    chunks = []
    while offset < end:
        chunk = os.pread(fd, end - offset, offset)
        if not chunk:
            break
        chunks.append(chunk)
        offset += len(chunk)
    return b"".join(chunks)


PROBE_CLIENT = next((p for p in ("/root/share/rhizo-probe-client", "/usr/lib/rhizo/rhizo-probe-client") if os.access(p, os.X_OK)), "/usr/lib/rhizo/rhizo-probe-client")
PROBE_SOCK = HOST_DATA + "local/tmp/rhizo-probe.sock"
INIT_PID_FILE = _instanced("/root/.rhizo_init_pid", SANDBOX_ID)
PROC_ROOT = "/proc"
STACK_CGROUPS = ("/rhizo", "/system.slice/androidd.service/android")
DONE = "RHIZO_DISPLAYD_DONE="


def init_pid():
    """return the sandbox init pid from its file"""
    try:
        with open(INIT_PID_FILE) as f:
            pid = f.read().strip()
    except OSError:
        if SANDBOX_ID != 0:
            return None
        return stack_init_pid()
    if not pid.isdigit():
        return None
    try:
        with open("%s/%s/cmdline" % (PROC_ROOT, pid), "rb") as f:
            cmdline = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        return None
    return pid if "init second_stage" in cmdline else None


def stack_init_pid():
    """find the init second_stage pid in instance 0"""
    for entry in sorted(os.listdir(PROC_ROOT), key=lambda e: int(e) if e.isdigit() else -1):
        if not entry.isdigit():
            continue
        try:
            with open("%s/%s/cmdline" % (PROC_ROOT, entry), "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
            with open("%s/%s/cgroup" % (PROC_ROOT, entry)) as f:
                cgroups = f.read().splitlines()
        except OSError:
            continue
        if "init second_stage" not in cmdline:
            continue
        for line in cgroups:
            if line.startswith("0::") and any(line[3:].startswith(r + "/") for r in STACK_CGROUPS):
                return entry
    return None


def android(cmd):
    """run a command in the sandbox through rhizo-probed"""
    body = "export PATH=/system/bin:/system/xbin:/vendor/bin; %s; echo %s$?" % (cmd, DONE)
    try:
        out = subprocess.run([PROBE_CLIENT, PROBE_SOCK, "30", body],
                             capture_output=True, text=True, timeout=45).stdout
    except Exception as e:
        log("probe channel failed: %s" % e)
        return None
    if DONE not in out:
        log("no completion trailer from the sandbox")
        return None
    return out[:out.rindex(DONE)]


def announce_born(composer_id, port):
    """reset density and send the cursor scale"""
    if composer_id not in _density_checked and reset_density_override(port):
        _density_checked.add(composer_id)
    return tell_composer_cursor_scale(composer_id, port)


_density_checked = set()


def reset_density_override(port):
    """clear the wm density override on a port"""
    logical = logical_id_for_port(port)
    if logical is None:
        return False
    out = android("wm density -d %s" % logical)
    if out is None:
        return False
    if "Override density" in out:
        android("wm density reset -d %s" % logical)
        log("display %s (port %d) was born under a density override -- cleared: %s"
            % (logical, port, " ".join(out.split())))
    remember_base(port, logical)
    return True


_base = {}


def remember_base(port, logical, reported_dpi=None):
    """record a port's density and DPI at its scale if the framework holds that DPI"""
    physical = physical_density(logical)
    held = device_dpi(port)
    if not (physical and held):
        return False
    if reported_dpi is not None and abs(held - reported_dpi) >= 1:
        log("display %s (port %d): framework holds %gdpi, not %ddpi; base kept at %r"
            % (logical, port, held, reported_dpi, _base.get(port)))
        return False
    _base[port] = (physical, held)
    return True


def wanted_density(port, physical, reported_dpi, held_dpi):
    """return the density for a scale"""
    base = _base.get(port)
    if base and (base[0] != physical or base[1] != held_dpi):
        return scaled_density(base[0], reported_dpi, base[1])
    return scaled_density(physical, reported_dpi, held_dpi)


def logical_id_for_port(port):
    """return the framework display id for a port"""
    dump = android("dumpsys display | grep mViewports=")
    if dump is None:
        return None
    for m in re.finditer(r"DisplayViewport\{.*?\}", dump):
        v = m.group(0)
        p = re.search(r"physicalPort=(\d+)", v)
        d = re.search(r"displayId=(\d+)", v)
        if p and d and int(p.group(1)) == port:
            return d.group(1)
    return None


PHYSICAL_DENSITY_RE = re.compile(r"Physical density:\s*(\d+)")


def physical_density(logical):
    """return the framework density of a display"""
    out = android("wm density -d %s" % logical)
    if out is None:
        return None
    m = PHYSICAL_DENSITY_RE.search(out)
    return int(m.group(1)) if m else None


def device_dpi(port):
    """return the framework DPI for a port"""
    dump = android("dumpsys display | grep -a 'DisplayDeviceInfo{'")
    if dump is None:
        return None
    for line in dump.splitlines():
        if re.search(r"port=%d\b" % port, line):
            m = re.search(r"([\d.]+) x [\d.]+ dpi", line)
            return float(m.group(1)) if m and float(m.group(1)) > 0 else None
    return None


def scaled_density(physical, reported_dpi, held_dpi):
    """return the density times the DPI ratio"""
    return int(round(physical * reported_dpi / held_dpi))


def composer_dpi(port, reported_dpi, held_dpi, scale):
    """return the composer's unrounded DPI"""
    base = _base.get(port)
    if base:
        return base[1] * scale
    if abs(reported_dpi - held_dpi) <= 0.5:
        return held_dpi
    return float(reported_dpi)


_scales = {}
_default = {}


def follow_default_display():
    """hold Android's default display at the most scaled window's density"""
    if not _scales:
        return True
    scale = max(_scales.values())
    got = android("wm density -d 0")
    m = PHYSICAL_DENSITY_RE.search(got or "")
    if not m:
        return False
    physical = int(m.group(1))
    want = int(round(physical * scale))
    held = re.search(r"Override density:\s*(\d+)", got)
    if (int(held.group(1)) if held else physical) == want:
        _default["want"] = want
        return True
    if want == physical:
        android("wm density reset -d 0")
    else:
        android("wm density %d -d 0" % want)
    back = android("wm density -d 0") or ""
    over = re.search(r"Override density:\s*(\d+)", back)
    if (int(over.group(1)) if over else physical) != want:
        log("the default display did not take %ddpi: %s" % (want, " ".join(back.split())))
        return False
    log("the default display is now %ddpi -- %d x %g, the most scaled window's scale, so apps and Google Play "
        "see the host's density" % (want, physical, scale))
    _default["want"] = want
    return True


def flat_pointer_gain(speed):
    """return the flat pointer gain for a pointer speed setting"""
    return 1.0 + (speed + 7) * (3.5 - 1.0) / 14.0


SENSITIVITY_FACTORS = (1, 2, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20)


def curve_base_gain(speed):
    """return the gain of the acceleration curve's slowest segment for a pointer speed setting"""
    return 0.64 * SENSITIVITY_FACTORS[speed + 7] / 10.0 * 3.19


UNSCALED_RE = re.compile(r"^\s*Display with Mouse Scaling Disabled:\s*\{([^}]*)\}", re.M)
UNACCELERATED_RE = re.compile(r"^\s*Display with Mouse Pointer Acceleration Disabled:\s*\{([^}]*)\}", re.M)

UNBOUND = "unbound"
NO_CONSTANT_GAIN = "no-constant-gain"
ACCELERATED = "accelerated"


def cursor_gain(dump, port, acceleration_off):
    """return the mouse gain for a port"""
    unscaled = UNSCALED_RE.search(dump)
    unaccelerated = UNACCELERATED_RE.search(dump)
    speed = re.search(r"^\s*Pointer Speed:\s*(-?\d+)\s*$", dump, re.M)
    reader = dump.find("Input Reader State")
    if reader < 0 or not speed or not (unscaled or unaccelerated):
        return None, UNBOUND
    for block in re.split(r"\n(?=  Device -?\d+: )", dump[reader:])[1:]:
        assoc = re.search(r"^\s*AssociatedDisplayPort:\s*(\d+)\s*$", block, re.M)
        if not assoc or int(assoc.group(1)) != port or "Cursor Input Mapper:" not in block:
            continue
        mapper = block[block.index("Cursor Input Mapper:"):]
        display = re.search(r"^\s*DisplayId:\s*(\d+)\s*$", mapper, re.M)
        xs = re.search(r"^\s*XScale:\s*([0-9.]+)\s*$", mapper, re.M)
        ys = re.search(r"^\s*YScale:\s*([0-9.]+)\s*$", mapper, re.M)
        if not (display and xs and ys):
            return None, UNBOUND
        if unscaled:
            if display.group(1) in set(re.findall(r"-?\d+", unscaled.group(1))):
                return 1000, None
            if not acceleration_off:
                return None, NO_CONSTANT_GAIN
            gain = flat_pointer_gain(int(speed.group(1)))
        else:
            if display.group(1) not in set(re.findall(r"-?\d+", unaccelerated.group(1))):
                if xs.group(1) != ys.group(1) or not -7 <= int(speed.group(1)) <= 7:
                    return None, NO_CONSTANT_GAIN
                gain = curve_base_gain(int(speed.group(1)))
                return int(round(float(xs.group(1)) * gain * 1000.0)), ACCELERATED
            gain = 1.0
        if xs.group(1) != ys.group(1):
            return None, NO_CONSTANT_GAIN
        return int(round(float(xs.group(1)) * gain * 1000.0)), None
    return None, UNBOUND


def cursor_gain_milli(dump, port, acceleration_off=True):
    """return the gain from cursor_gain"""
    return cursor_gain(dump, port, acceleration_off)[0]


ACCEL_SETTING = "mouse_pointer_acceleration_enabled"


def acceleration_off():
    """turn off mouse pointer acceleration"""
    got = (android("settings get system %s" % ACCEL_SETTING) or "").strip()
    if got == "0":
        return True
    android("settings put system %s 0" % ACCEL_SETTING)
    back = (android("settings get system %s" % ACCEL_SETTING) or "").strip()
    if back == "0":
        log("mouse pointer acceleration was %r -- turned off" % (got or "unset"))
        return True
    log("mouse pointer acceleration still %r after turning it off (was %r)" % (back, got))
    return None


def tell_composer_cursor_scale(composer_id, port):
    """send the composer the cursor scale"""
    dump = android("dumpsys input") or ""
    off = False
    if UNSCALED_RE.search(dump):
        off = acceleration_off()
        if off is None:
            return UNBOUND
    milli, why = cursor_gain(dump, port, off)
    if milli is None:
        if why == NO_CONSTANT_GAIN:
            log("composer display %s (port %d): mouse acceleration cannot be turned off -- "
                "no cursor scale sent" % (composer_id, port))
        return why
    accel = " 1" if why == ACCELERATED else ""
    out = android("echo display cursor-scale %s %d%s > %s" % (composer_id, milli, accel, CONTROL_IN))
    if out is None:
        log("could not tell the composer display %s's cursor scale" % composer_id)
        return UNBOUND
    log("composer display %s (port %d): mouse deltas scale by %d/1000%s"
        % (composer_id, port, milli,
           " below Android's first acceleration threshold" if accel else ""))
    return "told"


def apply(composer_id, port, scale, dpi):
    """apply a display scaled line"""
    logical = logical_id_for_port(port)
    if logical is None:
        return False
    _density_checked.add(composer_id)
    physical = physical_density(logical)
    if physical is None:
        return False
    if scale <= BASE_SCALE:
        android("wm density reset -d %s" % logical)
        got = android("wm density -d %s" % logical)
        if got is None or "Override density" in got:
            log("display %s (port %d): density override still set after the reset: %s"
                % (logical, port, " ".join((got or "no answer").split())))
        else:
            log("display %s (port %d) back to its density" % (logical, port))
            remember_base(port, logical, dpi)
        if tell_composer_cursor_scale(composer_id, port) == UNBOUND:
            log("display %s (port %d): no mouse bound to it to read a cursor scale from" % (logical, port))
        return True
    held = device_dpi(port)
    if held is None:
        log("display %s (port %d): the framework's DPI for it was not read; not scaling its density"
            % (logical, port))
        return False
    want = wanted_density(port, physical, composer_dpi(port, dpi, held, scale), held)
    if want == physical:
        android("wm density reset -d %s" % logical)
        got = android("wm density -d %s" % logical)
        if got is None or "Override density" in got:
            log("display %s (port %d): density override still set after the reset: %s"
                % (logical, port, " ".join((got or "no answer").split())))
            return False
        moved = PHYSICAL_DENSITY_RE.search(got)
        if moved and int(moved.group(1)) != physical:
            log("display %s (port %d): its density moved %d -> %s under the reset; scaling again"
                % (logical, port, physical, moved.group(1)))
            return False
        log("display %s (port %d) is %ddpi at scale %g by its density -- no override"
            % (logical, port, want, scale))
        if tell_composer_cursor_scale(composer_id, port) == UNBOUND:
            log("display %s (port %d): no mouse bound to it to read a cursor scale from" % (logical, port))
        return True
    android("wm density %d -d %s" % (want, logical))
    got = android("wm density -d %s" % logical) or ""
    moved = PHYSICAL_DENSITY_RE.search(got)
    if moved and int(moved.group(1)) != physical:
        log("display %s (port %d): its density moved %d -> %s under the write of %d; scaling again"
            % (logical, port, physical, moved.group(1), want))
        return False
    if ("Override density: %d" % want) not in got:
        log("density %d did not stick on display %s: %s" % (want, logical, got.strip()))
        return True
    log("display %s (port %d) is now %ddpi -- %d at %gdpi held, scale %g (composer reported %d)"
        % (logical, port, want, physical, held, scale, dpi))
    if tell_composer_cursor_scale(composer_id, port) == UNBOUND:
        log("display %s (port %d): no mouse bound to it to read a cursor scale from" % (logical, port))
    return True


MOUSE_CONTROLLERS_RE = re.compile(r"^\s*MousePointerControllers:\s*$", re.M)
OTHER_CONTROLLERS_RE = re.compile(r"^\s*(?:TouchPointerControllers|StylusPointerControllers|"
                                  r"DrawingTabletControllers):\s*$", re.M)
CONTROLLER_RE = re.compile(r"^\s*(-?\d+)\s*:\s*PointerController:", re.M)
RESOLVED_TYPE_RE = re.compile(r"resolvedPointerType:\s*(-?\d+)")
POINTER_GREP = ("dumpsys input | grep -E "
                "'PointerControllers:|DrawingTabletControllers:|PointerController:|resolvedPointerType:'")
# Android draws a new type's image a frame or two late; the composer drops a reply older than the image
POINTER_TYPE_SETTLE_S = 0.15


def resolved_pointer_type(dump, logical):
    """return the resolvedPointerType of a display's mouse pointer in dumpsys input"""
    m = MOUSE_CONTROLLERS_RE.search(dump)
    if not m:
        return None
    body = dump[m.end():]
    other = OTHER_CONTROLLERS_RE.search(body)
    if other:
        body = body[:other.start()]
    starts = list(CONTROLLER_RE.finditer(body))
    for i, c in enumerate(starts):
        if c.group(1) != str(logical):
            continue
        end = starts[i + 1].start() if i + 1 < len(starts) else len(body)
        t = RESOLVED_TYPE_RE.search(body, c.end(), end)
        return int(t.group(1)) if t else None
    return None


def tell_composer_pointer_type(composer_id, port, digest, sleep=time.sleep):
    """send the composer the pointer type its display's cursor image draws"""
    logical = logical_id_for_port(port)
    if logical is None:
        return False
    pointer_type = resolved_pointer_type(android(POINTER_GREP) or "", logical)
    if pointer_type is None:
        log("display %s (port %d): no resolvedPointerType in dumpsys input for cursor image %d"
            % (logical, port, digest))
        return False
    sleep(POINTER_TYPE_SETTLE_S)
    if android("echo display cursor-type %s %d %d > %s" % (composer_id, digest, pointer_type, CONTROL_IN)) is None:
        log("could not tell the composer display %s its pointer type" % composer_id)
        return False
    return True


INIT_POLL_S = 0.5


def wait_for_init(sleep=time.sleep):
    """wait for the sandbox init pid"""
    logged = False
    while True:
        pid = init_pid()
        if pid:
            return pid
        if not logged:
            log("waiting for the sandbox's init second_stage (%s)" % INIT_PID_FILE)
            logged = True
        sleep(INIT_POLL_S)


def process_started_at(pid):
    """return a process start time in epoch seconds"""
    try:
        fields = read_whole("%s/%s/stat" % (PROC_ROOT, pid)).rsplit(")", 1)[1].split()
        btime = next(int(l.split()[1]) for l in read_whole("%s/stat" % PROC_ROOT).splitlines()
                     if l.startswith("btime "))
        return btime + int(fields[19]) / float(os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, IndexError, StopIteration):
        return None


def read_whole(path):
    """read the whole text of a file"""
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", "replace")
    finally:
        os.close(fd)


def start_offset(path, pid):
    """return the offset to start reading control.out"""
    try:
        st = os.stat(path)
    except OSError:
        return 0
    started = process_started_at(pid)
    if started is not None and st.st_mtime >= started:
        return 0
    return st.st_size


def plan(lines):
    """list the actions for reply lines"""
    gone_after = {}
    for i, line in enumerate(lines):
        m = GONE_RE.match(line.strip())
        if m:
            gone_after[int(m.group(1) or m.group(2))] = i
    out = []
    last_cursor = {}
    for i, line in enumerate(lines):
        m = CURSOR_UNKNOWN_RE.match(line.strip())
        if m:
            last_cursor[int(m.group(1))] = i
    for i, line in enumerate(lines):
        text = line.strip()
        m = CURSOR_UNKNOWN_RE.match(text)
        if m:
            cid = int(m.group(1))
            if last_cursor[cid] == i and gone_after.get(cid, -1) < i:
                out.append(("cursor", (cid, int(m.group(2)), int(m.group(3)))))
            continue
        m = SCALED_RE.match(text)
        if m:
            cid, port, scale, dpi = m.groups()
            out.append(("scaled", (int(cid), int(port), float(scale), int(dpi))))
            continue
        m = BORN_RE.match(text)
        if m:
            cid = int(m.group(1))
            if gone_after.get(cid, -1) > i:
                continue
            out.append(("born", (cid, int(m.group(2)))))
            continue
        m = GONE_RE.match(text)
        if m:
            out.append(("gone", (int(m.group(1) or m.group(2)),)))
    return out


PENDING_LOG_S = 60
_now = time.monotonic


def open_control():
    """open control.out for reading"""
    try:
        return os.open(CONTROL_OUT, os.O_RDONLY | os.O_CLOEXEC)
    except OSError:
        return None


def seat_locked():
    """return LockedHint of seat0's active session, or None"""
    sid = subprocess.run(["loginctl", "show-seat", "seat0", "-p", "ActiveSession", "--value"],
                         capture_output=True, text=True, timeout=5).stdout.strip()
    if not sid:
        return None
    hint = subprocess.run(["loginctl", "show-session", sid, "-p", "LockedHint", "--value"],
                          capture_output=True, text=True, timeout=5).stdout.strip()
    return hint == "yes"


def follow_desktop_lock(state):
    """sleep or wake Android with the desktop lock"""
    state["passes"] = state.get("passes", 0) + 1
    if state["passes"] % 4:
        return
    try:
        locked = seat_locked()
    except (OSError, subprocess.SubprocessError) as e:
        log("lock check failed: %s" % e)
        return
    if locked is None or locked == state.get("locked"):
        return
    key = "KEYCODE_SLEEP" if locked else "KEYCODE_WAKEUP"
    if android("input keyevent %s" % key) is not None:
        log("desktop %s -> android %s" % ("locked" if locked else "unlocked", key))
        state["locked"] = locked


def main():
    """watch control.out and apply display changes"""
    pid = wait_for_init()
    log("watching %s for scale changes (sandbox init pid %s)" % (CONTROL_OUT, pid))
    offset = start_offset(CONTROL_OUT, pid)
    fd = open_control()
    tail = ""
    pending = {}
    scales = {}
    lock_state = {}
    default_due = False
    while True:
        try:
            if fd is not None and os.fstat(fd).st_nlink == 0:
                os.close(fd)
                fd = None
            if fd is None:
                fd = open_control()
                offset, tail = 0, ""
            size = os.fstat(fd).st_size if fd is not None else 0
            if size < offset:
                offset, tail = 0, ""
            if size > offset:
                chunk = read_fd(fd, offset, size).decode("utf-8", "replace")
                offset = size
                tail += chunk
                lines = tail.split("\n")
                tail = lines.pop()
                if any(BORN_RE.match(l.strip()) or SCALED_RE.match(l.strip()) for l in lines):
                    for entry in list(pending.values()) + list(scales.values()):
                        entry[1], entry[2] = _now(), False
                for kind, args in plan(lines):
                    if kind == "cursor":
                        tell_composer_pointer_type(*args)
                    elif kind == "scaled":
                        _scales[args[0]] = args[2]
                        default_due = True
                        scales.pop(args[0], None)
                        if not apply(*args):
                            scales[args[0]] = [args, _now(), False]
                    elif kind == "born":
                        cid, port = args
                        for other in [c for c, e in pending.items() if c != cid and e[0] == port]:
                            del pending[other]
                            _density_checked.discard(other)
                        for other in [c for c, e in scales.items() if c != cid and e[0][1] == port]:
                            del scales[other]
                        pending[cid] = [port, _now(), False]
                        _scales.setdefault(cid, float(BASE_SCALE))
                        default_due = True
                    else:
                        _scales.pop(args[0], None)
                        default_due = True
                        pending.pop(args[0], None)
                        scales.pop(args[0], None)
                        _density_checked.discard(args[0])
            for cid in list(scales):
                args, since, parked = scales[cid]
                if parked:
                    continue
                if apply(*args):
                    del scales[cid]
                elif _now() - since > PENDING_LOG_S:
                    log("composer display %s (port %d): the framework has no display on that port "
                        "%ds after it was scaled to %g -- stopped asking" % (cid, args[1], PENDING_LOG_S, args[2]))
                    scales[cid][2] = True
            for cid in list(pending):
                port, since, parked = pending[cid]
                if parked:
                    continue
                if announce_born(cid, port) != UNBOUND:
                    del pending[cid]
                elif _now() - since > PENDING_LOG_S:
                    log("composer display %s (port %d): no mouse bound on that port, or no settings "
                        "provider, for %ds -- stopped asking" % (cid, port, PENDING_LOG_S))
                    pending[cid][2] = True
            if default_due and follow_default_display():
                default_due = False
        except Exception as e:
            log("watch error: %s" % e)
        follow_desktop_lock(lock_state)
        time.sleep(0.5)


if __name__ == "__main__":
    main()
