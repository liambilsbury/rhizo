import decimal
import errno
import math
import os
import re
import time

from sandbox import capabilities
from sandbox import core
from sandbox.core import RUN_ROOT, SANDBOX_ID, beside, kmsg

CONF_VERSION = 1
VECTOR_KINDS = (("accel", "accelerometer"), ("anglvel", "gyroscope"), ("magn", "magnetometer"))
SCALAR_KINDS = (("illuminance", "light"),)
KIND_ORDER = ("accelerometer", "gyroscope", "magnetometer", "light")
KIND_FEATURES = {"accelerometer": "android.hardware.sensor.accelerometer",
                 "gyroscope": "android.hardware.sensor.gyroscope",
                 "magnetometer": "android.hardware.sensor.compass",
                 "light": "android.hardware.sensor.light"}
UNIT_FACTOR = {"magnetometer": 100.0}
AXES = ("x", "y", "z")
IDENTITY = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)
NOMINAL_POWER_MA = 0.1
CONTINUOUS_FLOOR_US = 5000
ON_CHANGE_FLOOR_US = 100000
MAX_DELAY_US = 1000000
ASSUMED_REALBITS = 16
MAX_VECTOR_REALBITS = 22
PROBE_ATTEMPTS = 10
PROBE_INTERVAL_S = 0.1
PROBE_ROUNDS = 5
MAX_SENSORS = 32
ACCEL_MIN_RANGE = 39.1
GYRO_MIN_RANGE = 16.35
MAGN_MIN_RANGE = 899.9
MAGN_MAX_RESOLUTION = 0.6
MIN_BITS = 12

_DEVICE = re.compile(r"iio:device([0-9]+)")
_VECTOR_ATTR = re.compile(r"in_(accel|anglvel|magn)_([xyz])_(raw|input)")
_SCALAR_ATTR = re.compile(r"in_(illuminance)([0-9]*)_(raw|input)")
_PROXIMITY_ATTR = re.compile(r"in_(proximity)([0-9]*)_(raw|input)")
_ANY_CHANNEL = re.compile(r"in_([a-z]+?)[0-9]*(?:_[a-z0-9]+)*_(raw|input)")
_SCAN_TYPE = re.compile(r"(?:be|le):([su])([0-9]+)/([0-9]+)(?:X[0-9]+)?>>[0-9]+")


class SensorError(Exception):
    """a device channel that cannot be declared, with its reason"""


def _read(path):
    """return a sysfs attribute's text without its trailing newline"""
    with open(path) as f:
        return f.read().strip()


def _number(text):
    """return an attribute's text as a finite float"""
    value = float(text)
    if not math.isfinite(value):
        raise ValueError(f"not finite: {text!r}")
    return value


def _clean(text):
    """return text fit for a conf line"""
    return "".join(c if " " <= c < "\x7f" else "?" for c in text).strip()


def udev_properties(udev_root, devname, dev_attr):
    """return the udev db properties of an IIO device"""
    name = f"c{dev_attr}" if dev_attr else f"+iio:{devname}"
    props = {}
    try:
        with open(os.path.join(udev_root, "data", name)) as f:
            for line in f:
                if line.startswith("E:") and "=" in line:
                    key, value = line[2:].rstrip("\n").split("=", 1)
                    props[key] = value
    except OSError:
        pass
    return props


def parse_matrix(text):
    """return the nine floats of an IIO mount matrix, row-major"""
    rows = [r.strip() for r in text.split(";")]
    if len(rows) != 3:
        raise ValueError(f"{len(rows)} rows")
    values = []
    for row in rows:
        cols = [c.strip() for c in row.split(",")]
        if len(cols) != 3:
            raise ValueError(f"{len(cols)} columns")
        values += [_number(c) for c in cols]
    return tuple(v + 0.0 for v in values)


def mount_matrix(kind, iio_type, attrs, props, read, log, devname):
    """return the mount matrix and its source"""
    sources = []
    if kind == "accelerometer" and "ACCEL_MOUNT_MATRIX" in props:
        sources.append(("udev:ACCEL_MOUNT_MATRIX", lambda: props["ACCEL_MOUNT_MATRIX"]))
    for name in (f"in_{iio_type}_mount_matrix", "in_mount_matrix", "mount_matrix"):
        if name in attrs:
            sources.append((name, lambda n=name: read(n)))
    for source, get in sources:
        try:
            return parse_matrix(get()), source
        except (OSError, ValueError) as e:
            log(f"RHIZO_MARKER sensor_matrix_rejected={source} device={devname} kind={kind} why={_why(e)}")
    return IDENTITY, "identity"


def _why(e):
    """return a short reason for an exception"""
    if isinstance(e, OSError) and e.errno:
        return errno.errorcode.get(e.errno, str(e.errno))
    return re.sub(r"[^A-Za-z0-9_.:-]+", "-", str(e))[:60] or type(e).__name__


def accel_location(props, attrs, read):
    """return where an accelerometer sits"""
    if props.get("ACCEL_LOCATION"):
        return props["ACCEL_LOCATION"]
    for name, base in (("label", "accel-base"), ("location", "base")):
        if name in attrs:
            try:
                if read(name) == base:
                    return "base"
            except OSError:
                pass
    return "display"


def realbits(base, attrs, read):
    """return the signedness and realbits of a channel's scan type"""
    for rel in (f"scan_elements/{base}_type", f"buffer0/{base}_type"):
        if rel in attrs:
            try:
                m = _SCAN_TYPE.fullmatch(read(rel))
            except OSError:
                m = None
            if m:
                return m.group(1) == "s", int(m.group(2))
    return None


def _first(attrs, names):
    """return the first of names that exists"""
    return next((n for n in names if n in attrs), None)


def _channel(kind, iio_type, stem, generic, attrs, read):
    """return a channel's value attribute, scale and offset"""
    raw, processed = f"{stem}_raw", f"{stem}_input"
    factor = UNIT_FACTOR.get(kind, 1.0)
    scale_attr = _first(attrs, (f"{stem}_scale", f"{generic}_scale"))
    offset_attr = _first(attrs, (f"{stem}_offset", f"{generic}_offset"))
    if raw in attrs and scale_attr:
        try:
            scale = _number(read(scale_attr))
            offset = _number(read(offset_attr)) if offset_attr else 0.0
        except (OSError, ValueError) as e:
            raise SensorError(f"scale-unreadable:{_why(e)}")
        if scale != 0:
            return {"attr": raw, "scale": scale * factor, "offset": offset, "scale_attr": scale_attr,
                    "offset_attr": offset_attr, "processed": False, "base": stem}
    if processed in attrs and kind == "light":
        return {"attr": processed, "scale": factor, "offset": 0.0, "scale_attr": None, "offset_attr": None,
                "processed": True, "base": stem}
    if processed in attrs:
        raise SensorError("processed-no-range")
    raise SensorError("no-scale")


def _resolution_of_text(text):
    """return the LSB of a processed value's printed precision"""
    decimals = len(text.split(".", 1)[1]) if "." in text else 0
    return 10.0 ** -decimals


def _cdd_gaps(s):
    """return the CDD and CTS floors a sensor misses"""
    gaps, kind = [], s["kind"]
    bits = s["range"] / s["resolution"] if s["resolution"] else 0
    if kind == "accelerometer":
        if s["range"] < ACCEL_MIN_RANGE:
            gaps.append("range")
    if kind == "gyroscope":
        if s["range"] < GYRO_MIN_RANGE:
            gaps.append("range")
    if kind in ("accelerometer", "gyroscope"):
        if bits < 2 ** (MIN_BITS - 1) - 1:
            gaps.append("resolution-bits")
        if s["min_delay_us"] > 20000:
            gaps.append("rate-50hz")
        elif s["min_delay_us"] > 10000:
            gaps.append("rate-100hz")
    if kind == "magnetometer":
        if s["range"] < MAGN_MIN_RANGE:
            gaps.append("range")
        if s["resolution"] > MAGN_MAX_RESOLUTION:
            gaps.append("resolution")
        if s["min_delay_us"] > 100000:
            gaps.append("rate-10hz")
    if kind in ("gyroscope", "magnetometer"):
        gaps.append("calibration")
    return gaps


def _sampling_frequency(iio_type, attrs, read):
    """return the device's reported sampling rate, or None"""
    name = _first(attrs, (f"in_{iio_type}_sampling_frequency", "sampling_frequency"))
    if not name:
        return None
    try:
        hz = _number(read(name))
    except (OSError, ValueError):
        return None
    return hz if hz > 0 else None


def _device_sensors(dev_dir, attrs, read, props, devname, log):
    """return an IIO device's declarable sensors and skipped kinds"""
    found, skipped = [], []
    for iio_type, kind in VECTOR_KINDS:
        axes = [a for a in AXES if f"in_{iio_type}_{a}_raw" in attrs or f"in_{iio_type}_{a}_input" in attrs]
        if not axes:
            continue
        if kind == "accelerometer":
            where = accel_location(props, attrs, read)
            if where != "display":
                skipped.append((kind, f"location-{_clean(where) or 'unknown'}"))
                continue
        if axes != list(AXES):
            skipped.append((kind, "axes-missing"))
            continue
        try:
            channels = [_channel(kind, iio_type, f"in_{iio_type}_{a}", f"in_{iio_type}", attrs, read)
                        for a in AXES]
        except SensorError as e:
            skipped.append((kind, str(e)))
            continue
        matrix, source = mount_matrix(kind, iio_type, attrs, props, read, log, devname)
        found.append({"kind": kind, "iio_type": iio_type, "channels": channels,
                      "matrix": matrix, "matrix_source": source})
    for iio_type, kind in SCALAR_KINDS:
        stems = sorted({f"in_{m.group(1)}{m.group(2)}" for m in map(_SCALAR_ATTR.fullmatch, attrs) if m})
        if not stems:
            continue
        try:
            channel = _channel(kind, iio_type, stems[0], f"in_{iio_type}", attrs, read)
        except SensorError as e:
            skipped.append((kind, str(e)))
            continue
        found.append({"kind": kind, "iio_type": iio_type, "channels": [channel], "matrix": None,
                      "matrix_source": None})
    if any(_PROXIMITY_ATTR.fullmatch(a) for a in attrs):
        # CTS requires a wake-up proximity sensor reporting 0/5 cm
        skipped.append(("proximity", "not-exposed"))
    if not found and not skipped:
        types = sorted({m.group(1) for m in map(_ANY_CHANNEL.fullmatch, attrs) if m})
        skipped.append(("+".join(types) or "none", "not-a-sensor-kind"))
    return found, skipped


def _attrs(dev_dir):
    """return the device's attribute names, scan elements included"""
    names = set()
    try:
        entries = os.listdir(dev_dir)
    except OSError:
        return names
    for name in entries:
        path = os.path.join(dev_dir, name)
        if name in ("scan_elements", "buffer0") and os.path.isdir(path):
            try:
                names.update(f"{name}/{n}" for n in os.listdir(path))
            except OSError:
                pass
        elif not os.path.isdir(path) or os.path.islink(path):
            names.add(name)
    return names


def _properties(s, attrs, read, round_us):
    """fill a probed sensor's range, resolution, power, delays and mode"""
    channels = s["channels"]
    capped = False
    if s["kind"] == "light" and channels[0]["processed"]:
        resolution = _resolution_of_text(s["probe_text"][0])
        rng, assumed = (2 ** ASSUMED_REALBITS - 1) * 1.0, True
    else:
        resolution = max(abs(c["scale"]) for c in channels)
        rng, assumed = 0.0, False
        for c in channels:
            got = realbits(c["base"], attrs, read)
            if got is None:
                got, assumed = (s["kind"] != "light", ASSUMED_REALBITS), True
            signed, bits = got
            if s["kind"] != "light" and bits > MAX_VECTOR_REALBITS:
                bits, capped = MAX_VECTOR_REALBITS, True
            top = 2 ** (bits - 1) - 1 if signed else 2 ** bits - 1
            rng = max(rng, (top + abs(c["offset"])) * abs(c["scale"]))
    s["range"], s["resolution"], s["range_assumed"], s["range_capped"] = rng, resolution, assumed, capped
    s["power"] = NOMINAL_POWER_MA
    cost = int(math.ceil(2 * round_us))
    if s["kind"] == "light":
        s["mode"] = "on_change"
        s["min_delay_us"] = max(ON_CHANGE_FLOOR_US, cost)
    else:
        s["mode"] = "continuous"
        hz = _sampling_frequency(s["iio_type"], attrs, read)
        s["min_delay_us"] = max(CONTINUOUS_FLOOR_US, int(math.ceil(1e6 / hz)) if hz else 0, cost)
    s["max_delay_us"] = max(MAX_DELAY_US, s["min_delay_us"])


def _probe_once(s, read, clock):
    """return a sensor's mean channel read round in microseconds"""
    texts = None
    total = 0.0
    for _ in range(PROBE_ROUNDS):
        start = clock()
        got = [read(c["attr"]) for c in s["channels"]]
        total += clock() - start
        for t in got:
            _number(t)
        texts = texts or got
    s["probe_text"] = texts
    return total / PROBE_ROUNDS * 1e6


def probe(candidates, log, sleep=time.sleep, clock=time.monotonic):
    """return the candidates whose channels read within the retries"""
    pending, done, last = list(range(len(candidates))), {}, {}
    for attempt in range(PROBE_ATTEMPTS):
        if attempt:
            sleep(PROBE_INTERVAL_S)
        still = []
        for i in pending:
            s = candidates[i]
            try:
                done[i] = _probe_once(s, s["read"], clock)
            except (OSError, ValueError) as e:
                last[i] = _why(e)
                still.append(i)
        pending = still
        if not pending:
            break
    for i in pending:
        s = candidates[i]
        log(f"RHIZO_MARKER sensor_skipped={s['kind']} device={s['devname']} reason=read-failed:{last[i]}")
    return [(candidates[i], done[i]) for i in sorted(done)]


def enumerate(sys_root="/sys", udev_root="/run/udev", reader=None, log=kmsg, sleep=time.sleep,
              clock=time.monotonic):
    """return the host's declarable IIO sensors, in handle order"""
    reader = reader or _read
    real_root = os.path.realpath(sys_root)
    bus = os.path.join(sys_root, "bus", "iio", "devices")
    try:
        names = os.listdir(bus)
    except OSError:
        names = []
    devices = sorted((int(m.group(1)), n) for n, m in ((n, _DEVICE.fullmatch(n)) for n in names) if m)
    candidates = []
    for number, devname in devices:
        dev_dir = os.path.realpath(os.path.join(bus, devname))
        if not dev_dir.startswith(real_root + "/devices/"):
            log(f"RHIZO_MARKER sensor_skipped=none device={devname} reason=outside-sys-devices")
            continue
        devpath = dev_dir[len(real_root):]

        def read(rel, d=dev_dir):
            """read an attribute of this device"""
            return reader(os.path.join(d, rel))
        attrs = _attrs(dev_dir)
        try:
            dev_attr = read("dev") if "dev" in attrs else ""
        except OSError:
            dev_attr = ""
        try:
            iio_name = _clean(read("name")) if "name" in attrs else ""
        except OSError:
            iio_name = ""
        props = udev_properties(udev_root, devname, dev_attr)
        found, skipped = _device_sensors(dev_dir, attrs, read, props, devname, log)
        for kind, why in skipped:
            log(f"RHIZO_MARKER sensor_skipped={kind} device={devname} reason={why}")
        for s in found:
            s.update(iio=number, devname=devname, devpath=devpath, device="/sys" + devpath, read=read,
                     attrs=attrs, vendor=iio_name or "Linux IIO",
                     name=f"Rhizo IIO {s['kind']} ({devname}{' ' + iio_name if iio_name else ''})")
            candidates.append(s)
    sensors = []
    for s, round_us in probe(candidates, log, sleep, clock):
        _properties(s, s["attrs"], s["read"], round_us)
        sensors.append(s)
    sensors.sort(key=lambda s: (s["iio"], KIND_ORDER.index(s["kind"])))
    if len(sensors) > MAX_SENSORS:
        for s in sensors[MAX_SENSORS:]:
            log(f"RHIZO_MARKER sensor_skipped={s['kind']} device={s['devname']} reason=limit-{MAX_SENSORS}")
        sensors = sensors[:MAX_SENSORS]
    out = []
    for s in sensors:
        if s["range_assumed"]:
            log(f"RHIZO_MARKER sensor_range_assumed={ASSUMED_REALBITS}bit kind={s['kind']} device={s['devname']}")
        if s["range_capped"]:
            log(f"RHIZO_MARKER sensor_range_capped={MAX_VECTOR_REALBITS}bit kind={s['kind']} device={s['devname']}")
        for gap in _cdd_gaps(s):
            log(f"RHIZO_MARKER sensor_cdd_gap={gap} kind={s['kind']} device={s['devname']}")
        out.append({k: v for k, v in s.items() if k not in ("read", "attrs", "probe_text", "iio_type")})
    return out


def _num(x):
    """return a float as conf text without an exponent"""
    text = format(x + 0.0, ".12g")
    if "e" in text:
        text = format(decimal.Decimal(text), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def guest_path(s, attr):
    """return an attribute's path under the device's guest bind"""
    return f"{core.SENSORS_GUEST_DIR}/{s['iio']}/{attr}"


def render_conf(sensors):
    """return /vendor/etc/rhizo-sensors.conf for a sensor list"""
    lines = [f"rhizo-sensors {CONF_VERSION}"]
    for handle, s in zip(range(1, len(sensors) + 1), sensors):
        lines += [f"sensor {handle}", f"kind {s['kind']}", f"name {s['name']}", f"vendor {s['vendor']}",
                  f"device {s['device']}"]
        for c in s["channels"]:
            lines.append(" ".join(("channel", guest_path(s, c["attr"]), _num(c["scale"]), _num(c["offset"]),
                                   guest_path(s, c["scale_attr"]) if c["scale_attr"] else "-",
                                   guest_path(s, c["offset_attr"]) if c["offset_attr"] else "-")))
        if s["matrix"] is not None:
            lines.append("matrix " + " ".join(_num(v) for v in s["matrix"]))
        lines += [f"range {_num(s['range'])}", f"resolution {_num(s['resolution'])}", f"power {_num(s['power'])}",
                  f"min_delay_us {s['min_delay_us']}", f"max_delay_us {s['max_delay_us']}", f"mode {s['mode']}",
                  "end"]
    return "\n".join(lines) + "\n"


def feature_xml(sensors):
    """return the permissions file declaring a feature per kind present"""
    kinds = {s["kind"] for s in sensors}
    return ('<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n'
            + "".join(f'    <feature name="{KIND_FEATURES[k]}" />\n' for k in KIND_ORDER if k in kinds)
            + "</permissions>\n")


def kinds_of(sensors):
    """return the kinds present, in handle order, without repeats"""
    return [k for k in KIND_ORDER if any(s["kind"] == k for s in sensors)]


def refusal(policy, release=None, payload=None, prepared=None, root=None, exists=os.path.exists):
    """return why this launch declares no sensors"""
    release = core.RHIZO_RELEASE if release is None else release
    prepared = core.prepared_key() if prepared is None else prepared
    root = root or RUN_ROOT
    if os.environ.get("RHIZO_POLICY_ONLY") == "1":
        return "off", "policy-only"
    if not policy.allows("devices.sensors"):
        return "off", "policy"
    if release not in core.SENSORS_RELEASES:
        return "release", f"release-{release}"
    if core.sensors_hal_source(release, payload or beside(), exists) is None:
        return "absent", "hal-absent"
    if prepared and not exists(f"{root}/vendor/bin/hw/{core.SENSORS_BIN}"):
        return "absent", "hal-not-in-prepared-tree"
    return None


def marker(state, sensors, reason=None):
    """return the plan's marker line"""
    kinds = ",".join(kinds_of(sensors)) or "-"
    return (f"RHIZO_MARKER sensors={state} count={len(sensors)} kinds={kinds}"
            + (f" reason={reason}" if reason else ""))


def plan(policy=None, enum=None, log=kmsg, **refusal_args):
    """record and return this launch's sensor plan"""
    policy = policy or capabilities.policy_or_deny(log=log, instance_id=SANDBOX_ID)
    refused = refusal(policy, **refusal_args)
    sensors = [] if refused else (enum or enumerate)()
    state, reason = refused or (("staged", None) if sensors else ("none", None))
    core.set_sensors_plan(sensors if state == "staged" else ())
    log(marker(state, core.sensors_plan(), reason))
    return core.sensors_plan()
