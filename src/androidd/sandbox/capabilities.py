import configparser
import os
import re

CAPABILITIES = {
    "network.enabled": {
        "kind": "bool", "default": True,
    },
    "network.services": {
        "kind": "set", "default": frozenset({"dhcp", "dns", "ra", "proxy"}),
        "choices": ("dhcp", "dns", "ra", "proxy", "mdns"),
    },
    "network.proxy_connect": {
        "kind": "enum", "default": "deny-local",
        "choices": ("deny-local", "any"),
    },

    "desktop.clipboard": {
        "kind": "enum", "default": "both",
        "choices": ("off", "to-host", "to-android", "both"),
    },
    "desktop.notifications": {"kind": "bool", "default": True},
    "desktop.drag": {"kind": "bool", "default": True},
    "desktop.pointer": {"kind": "bool", "default": False},
    "desktop.open_uri": {
        "kind": "set", "default": frozenset({"http", "https"}),
        "choices": ("http", "https", "mailto", "tel", "geo", "file"),
    },
    "desktop.default_handler": {"kind": "bool", "default": False},

    "devices.tun": {"kind": "bool", "default": True},
    "devices.dri": {"kind": "bool", "default": True},
    "devices.uinput": {"kind": "bool", "default": True},
    "devices.bluetooth": {"kind": "bool", "default": True},

    "audio.out": {"kind": "bool", "default": True},

    "devices.virtual": {"kind": "bool", "default": False},
    "rhizo.profile": {
        "kind": "enum", "default": "desktop",
        "choices": ("desktop", "server"),
    },

    "server.adb_reach": {
        "kind": "enum", "default": "host",
        "choices": ("host", "lan"),
    },
    "server.idle_stop_s": {"kind": "int", "default": 0},
    "server.display": {"kind": "display", "default": "1280x800@60/400"},
    "server.screen_off_s": {"kind": "int", "default": 60},

    "instance.cpu_max": {"kind": "cgroup-cpu-max", "default": None},
    "instance.memory_max": {"kind": "cgroup-mem-max", "default": None},
    "stream.enabled": {"kind": "bool", "default": False},

    "rt.budgets": {"kind": "bool", "default": False},
    "rt.budget_percent": {"kind": "int", "default": 25, "min": 1, "max": 90},
    "rt.contain": {"kind": "bool", "default": False},
    "rt.contain_percent": {"kind": "int", "default": 10, "min": 1, "max": 50},
    "rt.contain_runtime_us": {"kind": "int", "default": 2000, "min": 100, "max": 10000},
    "rt.contain_period_us": {"kind": "int", "default": 16667, "min": 1000, "max": 1000000},

    "trace.ftrace": {"kind": "bool", "default": False},

    "trace.host_delay": {"kind": "bool", "default": False},

    "power.cpu_headroom": {"kind": "bool", "default": False},
}

SERVER_PROFILE_DEFAULTS = {
    "desktop.clipboard": "off",
    "desktop.notifications": False,
    "desktop.drag": False,
    "desktop.pointer": False,
    "desktop.open_uri": frozenset(),
    "desktop.default_handler": False,
    "audio.out": False,
    "server.idle_stop_s": 600,
}

HOST_WIDE = ("trace.ftrace", "trace.host_delay", "power.cpu_headroom", "devices.dri")

SHARE_CONFIG = "/etc/rhizo/hostfs.conf"

OPERATOR_ADB_KEYS = "/etc/rhizo/adb_keys"

DEFAULT_PATH = "/etc/rhizo/policy.conf"

PATH_ENV = "RHIZO_POLICY_CONF"

INSTANCE_CONF_DIR = "/etc/rhizo/instances"


def instance_config_path(sandbox_id):
    """return the instance overlay file path"""
    path = "%s/%s.conf" % (INSTANCE_CONF_DIR, sandbox_id)
    return path if os.path.exists(path) else None


def config_path():
    """return the policy file path"""
    return os.environ.get(PATH_ENV) or DEFAULT_PATH


# resolved capability values
class Policy:
    def __init__(self, values, source):
        """store the resolved capability values and their source"""
        self._values = values
        self.source = source

    def allows(self, capability):
        """return true for an enabled capability"""
        value = self._values[capability]
        if isinstance(value, bool):
            return value
        if isinstance(value, frozenset):
            return bool(value)
        return value != "off"

    def scope(self, capability):
        """return the value of a capability"""
        return self._values[capability]

    def __eq__(self, other):
        """compare two policies by their capability values"""
        return isinstance(other, Policy) and self._values == other._values


def defaults():
    """return the policy of built-in defaults"""
    return Policy({k: v["default"] for k, v in CAPABILITIES.items()},
                  "built-in defaults")


def deny_all():
    """return the policy that turns every optional capability off"""
    values = {}
    for name, spec in CAPABILITIES.items():
        if spec["kind"] == "bool":
            values[name] = False
        elif spec["kind"] == "set":
            values[name] = frozenset()
        elif spec["kind"] == "int":
            values[name] = spec.get("min", 0)
        elif spec["kind"] == "display":
            values[name] = spec["default"]
        elif spec["kind"] == "cgroup-cpu-max":
            values[name] = "1000 100000"
        elif spec["kind"] == "cgroup-mem-max":
            values[name] = _CGROUP_MEM_MAX_DENY
        else:
            values[name] = "off" if "off" in spec["choices"] else spec["choices"][0]
    return Policy(values, "deny-all")


def _parse_bool(raw):
    """parse a yes/no value into a bool and an error"""
    lowered = raw.strip().lower()
    if lowered in ("yes", "true", "on", "1"):
        return True, None
    if lowered in ("no", "false", "off", "0"):
        return False, None
    return None, "expected yes or no"


def _parse_set(raw, choices):
    """parse a comma-separated subset into a frozenset and an error"""
    items = [tok.strip() for tok in raw.split(",") if tok.strip()]
    for item in items:
        if item not in choices:
            return None, "expected a comma-separated subset of %s" % "/".join(choices)
    return frozenset(items), None


_INT_RE = re.compile(r"^[0-9]+$")


def _parse_int(raw, spec=None):
    """parse a bounded non-negative integer into an int and an error"""
    stripped = raw.strip()
    if not _INT_RE.match(stripped):
        return None, "expected a non-negative integer"
    value = int(stripped)
    lo, hi = (spec or {}).get("min"), (spec or {}).get("max")
    if (lo is not None and value < lo) or (hi is not None and value > hi):
        return None, "expected an integer between %d and %d" % (lo, hi)
    return value, None


_DISPLAY_RE = re.compile(r"^([0-9]+)x([0-9]+)@([0-9]+)/([0-9]+)$")


def _parse_display(raw):
    """parse a WxH@fps/dpi value into a normalized string and an error"""
    m = _DISPLAY_RE.match(raw.strip())
    if not m:
        return None, "expected WxH@fps/dpi, e.g. 1280x800@60/400"
    w, h, fps, dpi = (int(g) for g in m.groups())
    if w <= 0 or h <= 0 or fps <= 0 or dpi <= 0:
        return None, "expected WxH@fps/dpi with every value positive"
    return "%dx%d@%d/%d" % (w, h, fps, dpi), None


_CGROUP_CPU_MAX_RE = re.compile(r"^([0-9]+)\s+([0-9]+)$")


def _parse_cgroup_cpu_max(raw):
    """parse a cgroup cpu.max value into a string and an error"""
    stripped = raw.strip()
    if stripped == "max":
        return "max", None
    m = _CGROUP_CPU_MAX_RE.match(stripped)
    if not m:
        return None, 'expected "<quota> <period>" or the literal "max"'
    quota, period = int(m.group(1)), int(m.group(2))
    if quota <= 0 or period <= 0:
        return None, 'expected "<quota> <period>" with both positive, or "max"'
    return "%d %d" % (quota, period), None


_CGROUP_MEM_MAX_RE = re.compile(r"^([0-9]+)([KMG]?)$")
_MEM_SUFFIX_BYTES = {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
_CGROUP_MEM_MAX_DENY = str(_MEM_SUFFIX_BYTES["M"])


def _parse_cgroup_mem_max(raw):
    """parse a cgroup memory.max value into a string and an error"""
    stripped = raw.strip()
    if stripped == "max":
        return "max", None
    m = _CGROUP_MEM_MAX_RE.match(stripped)
    if not m:
        return None, 'expected a byte count, optionally suffixed K/M/G, or the literal "max"'
    value = int(m.group(1)) * _MEM_SUFFIX_BYTES[m.group(2)]
    if value <= 0:
        return None, 'expected a positive byte count, or "max"'
    return "%d" % value, None


def _apply_overlay(values, parser, path):
    """validate the parser's keys and copy them into values"""
    for section in parser.sections():
        for key in parser[section]:
            name = "%s.%s" % (section, key)
            spec = CAPABILITIES.get(name)
            if spec is None:
                return "%s: [%s] %s is not a capability" % (path, section, key)
            raw = parser[section][key]
            if spec["kind"] == "bool":
                parsed, err = _parse_bool(raw)
            elif spec["kind"] == "set":
                parsed, err = _parse_set(raw, spec["choices"])
            elif spec["kind"] == "int":
                parsed, err = _parse_int(raw, spec)
            elif spec["kind"] == "display":
                parsed, err = _parse_display(raw)
            elif spec["kind"] == "cgroup-cpu-max":
                parsed, err = _parse_cgroup_cpu_max(raw)
            elif spec["kind"] == "cgroup-mem-max":
                parsed, err = _parse_cgroup_mem_max(raw)
            else:
                parsed, err = raw.strip(), None
                if parsed not in spec["choices"]:
                    parsed, err = None, "expected one of %s" % "/".join(spec["choices"])
            if err is not None:
                return "%s: [%s] %s=%r, %s" % (path, section, key, raw, err)
            values[name] = parsed
    return None


def _load_parser(path):
    """read a config file into a parser"""
    parser = configparser.ConfigParser()
    try:
        with open(path, "r") as handle:
            parser.read_file(handle, source=path)
    except OSError as exc:
        return None, "%s: cannot read: %s" % (path, exc)
    except configparser.Error as exc:
        return None, "%s: not a valid config file: %s" % (path, exc)
    return parser, None


def read_policy(path=None, overlay_path=None):
    """read the policy file and instance overlay into a Policy and an error"""
    path = path or config_path()
    have_overlay = overlay_path and os.path.exists(overlay_path)
    if not os.path.exists(path) and not have_overlay:
        return defaults(), None

    if os.path.exists(path):
        parser, err = _load_parser(path)
        if parser is None:
            return None, err
    else:
        parser = configparser.ConfigParser()

    values = {k: v["default"] for k, v in CAPABILITIES.items()}
    if (parser.has_option("rhizo", "profile")
            and parser["rhizo"]["profile"].strip() == "server"):
        values.update(SERVER_PROFILE_DEFAULTS)

    err = _apply_overlay(values, parser, path)
    if err is not None:
        return None, err

    if have_overlay:
        overlay_parser, err = _load_parser(overlay_path)
        if overlay_parser is None:
            return None, err
        for name in HOST_WIDE:
            section, key = name.split(".", 1)
            if overlay_parser.has_option(section, key):
                return None, "%s: [%s] %s is host-wide, set it in %s" % (
                    overlay_path, section, key, path)
        err = _apply_overlay(values, overlay_parser, overlay_path)
        if err is not None:
            return None, err

    return Policy(values, path), None


def policy_or_deny(path=None, log=None, instance_id=None):
    """return the policy or the deny-all policy"""
    overlay_path = instance_config_path(instance_id) if instance_id is not None else None
    policy, err = read_policy(path, overlay_path)
    if policy is None:
        if log is not None:
            log("%s -- denying every optional capability" % err)
        return deny_all()
    return policy


def ftrace_allowed(log=None):
    """return true when the trace.ftrace capability is enabled"""
    return policy_or_deny(log=log).allows("trace.ftrace")


def shares_enabled(policy):
    """return true unless the profile is server"""
    return policy.scope("rhizo.profile") != "server"


def is_adb_pubkey_line(line):
    """return true when the line starts with an adb public key"""
    key = line.split()[0] if line.split() else ""
    return (key.startswith("QAAA")
            and len(key) >= 200
            and re.fullmatch(r"[A-Za-z0-9+/]+=*", key) is not None)


def has_adb_key(paths):
    """return true when any of the files holds an adb public key"""
    for path in paths:
        try:
            with open(path) as handle:
                if any(is_adb_pubkey_line(line) for line in handle):
                    return True
        except OSError:
            continue
    return False


def sandbox_input_ports(services, proxy_port, deskd_port):
    """return the host ports the sandbox services listen on"""
    ports = []
    if "dhcp" in services:
        ports.append(("udp", 67))
    if "dns" in services:
        ports += [("udp", 53), ("tcp", 53)]
    if "proxy" in services:
        ports.append(("tcp", proxy_port))
    if "mdns" in services:
        ports.append(("udp", 5353))
    ports.append(("tcp", deskd_port))
    return ports
