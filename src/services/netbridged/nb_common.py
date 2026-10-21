import os
import sys
import time

LOG_PREFIX = "[netbridged]"


def log(fmt, *args):
    """write a log line to stderr"""
    msg = fmt % args if args else fmt
    print(f"{LOG_PREFIX} {msg}", file=sys.stderr, flush=True)


class HostState:
    """host resolver and proxy settings"""
    __slots__ = ("resolvers", "search", "resolv_source", "proxy_url",
                 "proxy_source", "no_proxy", "generation", "updated_at")

    def __init__(self):
        """start with empty lists"""
        self.resolvers = []
        self.search = []
        self.resolv_source = None
        self.proxy_url = None
        self.proxy_source = None
        self.no_proxy = []
        self.generation = 0
        self.updated_at = 0.0

    def describe(self):
        """return the host state as a line of key=value fields"""
        return ("resolvers=%s resolv_source=%s search=%s proxy=%s proxy_source=%s gen=%d"
                % (",".join(self.resolvers) or "-", self.resolv_source or "-",
                   ",".join(self.search) or "-", self.proxy_url or "-",
                   self.proxy_source or "-", self.generation))


class Service:
    """base class for netbridged services"""
    name = "service"

    def sockets(self):
        """return the sockets to poll for reading"""
        return []

    def on_readable(self, sock):
        """serve a readable socket"""

    def on_host_state(self, state):
        """update the service from the host state"""

    def next_tick(self, now):
        """return the time of the next tick"""
        return None

    def tick(self, now):
        """run the periodic work"""

    def close(self):
        """close every socket, ignoring errors"""
        for s in self.sockets():
            try:
                s.close()
            except OSError:
                pass


def read_first_existing(paths):
    """return the first readable path and its text"""
    for p in paths:
        try:
            with open(p) as f:
                return p, f.read()
        except OSError:
            continue
    return None, None


def sanitize_for_log(s, max_len=255):
    """escape control characters in a log string"""
    out = []
    for ch in s:
        if ord(ch) < 0x20 or ord(ch) == 0x7f:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    cleaned = "".join(out)
    if len(cleaned) > max_len:
        cleaned = cleaned[:max_len] + "...(truncated)"
    return cleaned


def monotonic():
    """return the monotonic clock in seconds"""
    return time.monotonic()


def now():
    """return the wall clock in seconds"""
    return time.time()


def env_flag(name, default=False):
    """return a boolean from an environment variable"""
    v = os.environ.get(name)
    if v is None:
        return default
    return v not in ("", "0", "no", "false")
