import os
import socket
import subprocess

from nb_common import HostState, log, now

RESOLV_SOURCES = (
    "/etc/resolv.conf",
    "/run/systemd/resolve/resolv.conf",
)

PROXY_FILE_SOURCES = (
    "/etc/rhizo/proxy.conf",
    "/etc/environment",
)

POLL_SECONDS = 1.0


def _stat_key(path):
    """return the inode, size and modification time of a path"""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def _nameserver_addr(token):
    """return a nameserver address in canonical form"""
    addr, _, scope = token.partition("%")
    family = socket.AF_INET6 if ":" in addr else socket.AF_INET
    try:
        addr = socket.inet_ntop(family, socket.inet_pton(family, addr))
    except OSError:
        return None
    if scope and addr.startswith(("fe8", "fe9", "fea", "feb")):
        return addr + "%" + scope
    return addr


def parse_resolv_conf(text):
    """parse nameserver and search lines"""
    servers, search = [], []
    for line in text.splitlines():
        line = line.split("#", 1)[0].split(";", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "nameserver":
            addr = _nameserver_addr(parts[1])
            if addr is not None:
                servers.append(addr)
        elif len(parts) >= 2 and parts[0] in ("search", "domain"):
            search.extend(parts[1:])
    return servers, search


def parse_proxy_env_text(text):
    """parse proxy variables from an environment file"""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip().lower()
        v = v.strip().strip('"').strip("'")
        if k in ("https_proxy", "http_proxy", "no_proxy", "all_proxy"):
            out[k] = v
    return out


def _gsettings_proxy():
    """return the GNOME proxy URL"""
    try:
        mode = subprocess.run(["gsettings", "get", "org.gnome.system.proxy", "mode"],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    if mode.returncode != 0:
        return None
    if "manual" not in mode.stdout:
        return None
    try:
        host = subprocess.run(["gsettings", "get", "org.gnome.system.proxy.http", "host"],
                              capture_output=True, text=True, timeout=5)
        port = subprocess.run(["gsettings", "get", "org.gnome.system.proxy.http", "port"],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    h = host.stdout.strip().strip("'")
    p = port.stdout.strip()
    if not h or not p.isdigit() or p == "0":
        return None
    return f"http://{h}:{p}"


class HostStateWatcher:
    """polled host DNS and proxy state"""

    def __init__(self, on_change, poll_seconds=POLL_SECONDS):
        """store the change callback and poll interval"""
        self.on_change = on_change
        self.poll_seconds = poll_seconds
        self.state = HostState()
        self._keys = {}
        self._next = 0.0

    def next_tick(self, _now):
        """return the time of the next poll"""
        return self._next

    def tick(self, mono):
        """refresh the host state when any watched file changed"""
        self._next = mono + self.poll_seconds
        keys = {p: _stat_key(p) for p in RESOLV_SOURCES + PROXY_FILE_SOURCES}
        if keys == self._keys and self.state.generation:
            return
        self._keys = keys
        self.refresh()

    def refresh(self, reason="poll"):
        """read resolvers and proxy from the host"""
        s = self.state
        old = (list(s.resolvers), s.proxy_url)

        resolvers, search, source = [], [], None
        for path in RESOLV_SOURCES:
            try:
                with open(path) as f:
                    text = f.read()
            except OSError:
                continue
            resolvers, search = parse_resolv_conf(text)
            source = path
            if resolvers:
                break
        s.resolvers, s.search, s.resolv_source = resolvers, search, source

        proxy, psource = None, None
        for path in PROXY_FILE_SOURCES:
            try:
                with open(path) as f:
                    got = parse_proxy_env_text(f.read())
            except OSError:
                continue
            cand = got.get("https_proxy") or got.get("http_proxy") or got.get("all_proxy")
            if cand:
                proxy, psource = cand, path
                s.no_proxy = [x.strip() for x in got.get("no_proxy", "").split(",") if x.strip()]
                break
        if proxy is None:
            cand = (os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY")
                    or os.environ.get("http_proxy") or os.environ.get("HTTP_PROXY"))
            if cand:
                proxy, psource = cand, "environ"
        if proxy is None:
            cand = _gsettings_proxy()
            if cand:
                proxy, psource = cand, "gsettings"
        s.proxy_url, s.proxy_source = proxy, psource

        if (list(s.resolvers), s.proxy_url) == old and s.generation:
            return
        s.generation += 1
        s.updated_at = now()
        log("NB_HOSTSTATE reason=%s %s", reason, s.describe())
        self.on_change(s)


def split_proxy_url(url):
    """split a proxy URL into host and port"""
    if not url:
        return None
    u = url.strip()
    if u.startswith("http://"):
        u = u[len("http://"):]
    elif "://" in u:
        return None
    u = u.split("/", 1)[0]
    if "@" in u:
        u = u.rsplit("@", 1)[1]
    if ":" not in u:
        return (u, 80)
    host, _, port = u.rpartition(":")
    if not port.isdigit():
        return None
    return (host, int(port))
