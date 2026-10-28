import errno
import hashlib
import hmac
import importlib
import os
import socket
import struct

from nb_common import log, monotonic, sanitize_for_log
from nb_routes import (AF_NETLINK, NLM_F_DUMP, NetlinkQuery, attrs_of, interface_name, iter_attrs,
                       iter_nlmsgs, nla, u32_of, write_atomic)

WIFI_MODES = ("mirror", "fixed", "off")
FIXED_SSID = b"Rhizo"
FIXED_SIGNAL_MBM = -4000
SIGNAL_STEP_MBM = 300
SIGNAL_POLL_SECONDS = 5.0
IDLE_POLL_SECONDS = 30.0
RETRY_SECONDS = 5.0
UNAVAILABLE_RETRY_SECONDS = 30.0
BUILD_RETRY_SECONDS = 30.0
REPUSH_AFTER_SECONDS = 30.0
REPUSH_GAP_START_SECONDS = 60.0
REPUSH_GAP_MAX_SECONDS = 900.0
RECV_SIZE = 65536
MIN_SECRET_BYTES = 16
STATE_FILE = "wifi-mirror"
MACHINE_ID_PATH = "/etc/machine-id"
MACHINE_KEY_LABEL = b"rhizo netbridged wifi bssid"
ABSENT = (False, b"", b"", 0)

NETLINK_GENERIC = 16
SOL_NETLINK = 270
NETLINK_ADD_MEMBERSHIP = 1

GENL_ID_CTRL = 0x10
GENL_HDR = "=BBH"
GENL_HDRLEN = 4
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID = 1
CTRL_ATTR_FAMILY_NAME = 2
CTRL_ATTR_MCAST_GROUPS = 7
CTRL_ATTR_MCAST_GRP_NAME = 1
CTRL_ATTR_MCAST_GRP_ID = 2

NL80211_NAME = b"nl80211"
NL80211_MLME_GROUP = b"mlme"
NL80211_CMD_GET_INTERFACE = 5
NL80211_CMD_NEW_INTERFACE = 7
NL80211_CMD_GET_STATION = 17
NL80211_CMD_NEW_STATION = 19
NL80211_CMD_ASSOCIATE = 38
NL80211_CMD_DEAUTHENTICATE = 39
NL80211_CMD_DISASSOCIATE = 40
NL80211_CMD_CONNECT = 46
NL80211_CMD_ROAM = 47
NL80211_CMD_DISCONNECT = 48
NL80211_CMD_PORT_AUTHORIZED = 125
NL80211_ATTR_IFINDEX = 3
NL80211_ATTR_IFTYPE = 5
NL80211_ATTR_STA_INFO = 21
NL80211_ATTR_SSID = 52
NL80211_IFTYPE_STATION = 2
NL80211_IFTYPE_P2P_CLIENT = 8
NL80211_STA_INFO_SIGNAL = 7
NL80211_STA_INFO_SIGNAL_AVG = 13

NL80211_READS = frozenset((NL80211_CMD_GET_INTERFACE, NL80211_CMD_GET_STATION))
MLME_EVENTS = frozenset((
    NL80211_CMD_ASSOCIATE, NL80211_CMD_DEAUTHENTICATE, NL80211_CMD_DISASSOCIATE,
    NL80211_CMD_CONNECT, NL80211_CMD_ROAM, NL80211_CMD_DISCONNECT,
    NL80211_CMD_PORT_AUTHORIZED,
))
CLIENT_IFTYPES = frozenset((NL80211_IFTYPE_STATION, NL80211_IFTYPE_P2P_CLIENT))
NOT_WIRELESS_ERRNOS = frozenset((errno.ENODEV, errno.EINVAL, errno.EOPNOTSUPP))


def mac_str(b):
    """format a hardware address as colon-separated hex"""
    return ":".join("%02x" % x for x in b)


def derive_bssid(key, ssid):
    """return a locally administered unicast address keyed on the SSID"""
    mac = bytearray(hmac.new(key, ssid, hashlib.sha256).digest()[:6])
    mac[0] = (mac[0] | 0x02) & 0xFE
    return bytes(mac)


def machine_key():
    """return a BSSID key derived one-way from the machine id"""
    with open(MACHINE_ID_PATH) as f:
        text = f.read(64).strip()
    if len(text) != 32 or text.strip("0123456789abcdef"):
        raise ValueError("not a 128-bit machine id")
    return hmac.new(bytes.fromhex(text), MACHINE_KEY_LABEL, hashlib.sha256).digest()


def load_key(path):
    """return the BSSID key and its source"""
    if not path:
        why = "no --wifi-secret-file given"
    else:
        try:
            with open(path, "rb") as f:
                data = f.read(4096)
        except OSError as e:
            why = e.strerror or str(e)
        else:
            if len(data) >= MIN_SECRET_BYTES:
                return data, "secret"
            why = "%d bytes, under %d" % (len(data), MIN_SECRET_BYTES)
    try:
        key = machine_key()
    except (OSError, ValueError) as e:
        log("NB_WIFI_NO_SECRET path=%s error=%s -- %s is unusable too (%s): presenting no network",
            path or "-", why, MACHINE_ID_PATH, getattr(e, "strerror", None) or e)
        return None, None
    log("NB_WIFI_NO_SECRET path=%s error=%s -- keying BSSIDs on %s instead",
        path or "-", why, MACHINE_ID_PATH)
    return key, "machine-id"


def read_state_seq(path):
    """return the state file's sequence number, or 0"""
    try:
        with open(path) as f:
            tokens = f.read(128).split()
        return max(0, int(tokens[0])) if tokens else 0
    except (OSError, ValueError):
        return 0


def parse_family(body):
    """return a generic netlink family's id and named multicast groups"""
    attrs = attrs_of(body)
    raw = attrs.get(CTRL_ATTR_FAMILY_ID)
    family = struct.unpack("=H", raw[:2])[0] if raw is not None and len(raw) >= 2 else None
    groups = {}
    for _index, group in iter_attrs(attrs.get(CTRL_ATTR_MCAST_GROUPS, b"")):
        g = attrs_of(group)
        name = g.get(CTRL_ATTR_MCAST_GRP_NAME, b"").split(b"\0", 1)[0]
        gid = u32_of(g.get(CTRL_ATTR_MCAST_GRP_ID))
        if name and gid is not None:
            groups[name] = gid
    return family, groups


def parse_interface(body):
    """return the ifindex, iftype and SSID of a NEW_INTERFACE message"""
    attrs = attrs_of(body)
    return (u32_of(attrs.get(NL80211_ATTR_IFINDEX)), u32_of(attrs.get(NL80211_ATTR_IFTYPE)),
            attrs.get(NL80211_ATTR_SSID, b""))


def parse_station_signal(body):
    """return the dBm signal of a NEW_STATION message, or None"""
    info = attrs_of(body).get(NL80211_ATTR_STA_INFO)
    if info is None:
        return None
    sta = attrs_of(info)
    for key in (NL80211_STA_INFO_SIGNAL, NL80211_STA_INFO_SIGNAL_AVG):
        raw = sta.get(key)
        if raw:
            dbm = struct.unpack("=b", raw[:1])[0]
            if dbm < 0:
                return dbm
    return None


def parse_mlme_ifindex(body):
    """return the ifindex an nl80211 event names, or None"""
    return u32_of(attrs_of(body).get(NL80211_ATTR_IFINDEX))


class Nl80211Reader:
    """nl80211 queries of the host's wireless interfaces"""

    def __init__(self, query):
        """use a request-reply transport"""
        self.query = query
        self.family = None
        self.mlme_group = None

    def _genl(self, family, cmd, attrs, flags=0):
        """send a generic netlink read and return its replies"""
        if not ((family == GENL_ID_CTRL and cmd == CTRL_CMD_GETFAMILY)
                or (family is not None and family == self.family and cmd in NL80211_READS)):
            raise ValueError("refusing generic netlink cmd %d to family %s: the host reader only reads"
                             % (cmd, family))
        version = 1 if family == GENL_ID_CTRL else 0
        payload = struct.pack(GENL_HDR, cmd, version, 0) + b"".join(attrs)
        out = []
        for mtype, _flags, body in self.query.request(NETLINK_GENERIC, family, flags, payload):
            if mtype == family and len(body) >= GENL_HDRLEN:
                out.append((body[0], body[GENL_HDRLEN:]))
        return out

    def resolve(self):
        """find nl80211's family id and mlme group"""
        try:
            replies = self._genl(GENL_ID_CTRL, CTRL_CMD_GETFAMILY,
                                 [nla(CTRL_ATTR_FAMILY_NAME, NL80211_NAME + b"\0")])
        except OSError as e:
            if e.errno == errno.ENOENT:
                return False
            raise
        for _cmd, body in replies:
            family, groups = parse_family(body)
            if family is not None:
                self.family = family
                self.mlme_group = groups.get(NL80211_MLME_GROUP)
                return True
        return False

    def interface(self, ifindex):
        """return a wireless interface's ifindex, iftype and ssid, or None"""
        if self.family is None:
            return None
        try:
            replies = self._genl(self.family, NL80211_CMD_GET_INTERFACE,
                                 [nla(NL80211_ATTR_IFINDEX, struct.pack("=I", ifindex))])
        except OSError as e:
            if e.errno in NOT_WIRELESS_ERRNOS:
                return None
            raise
        for cmd, body in replies:
            if cmd == NL80211_CMD_NEW_INTERFACE:
                info = parse_interface(body)
                if info[0] == ifindex:
                    return info
        return None

    def station_signal(self, ifindex):
        """return a client interface's station signal in dBm, or None"""
        if self.family is None:
            return None
        replies = self._genl(self.family, NL80211_CMD_GET_STATION,
                             [nla(NL80211_ATTR_IFINDEX, struct.pack("=I", ifindex))], NLM_F_DUMP)
        for cmd, body in replies:
            if cmd == NL80211_CMD_NEW_STATION:
                dbm = parse_station_signal(body)
                if dbm is not None:
                    return dbm
        return None

    def close(self):
        """close the transport"""
        close = getattr(self.query, "close", None)
        if close is not None:
            close()


def open_mlme_events(group):
    """open a generic netlink socket joined to nl80211's mlme group"""
    sock = socket.socket(AF_NETLINK, socket.SOCK_RAW | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC,
                         NETLINK_GENERIC)
    try:
        sock.bind((0, 0))
        sock.setsockopt(SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, group)
    except OSError:
        sock.close()
        raise
    return sock


class WifiMirror:
    """present the host's current connection through the Rhizo Wi-Fi driver"""
    name = "wifi"

    def __init__(self, cfg, uplinks, wlan=None, reader=None, clock=monotonic, sockets=True,
                 ifname=interface_name):
        """read the BSSID key and prepare the nl80211 reader"""
        if cfg.wifi_mode not in ("mirror", "fixed"):
            raise ValueError("wifi mode %r presents nothing" % cfg.wifi_mode)
        if wlan is None:
            import nb_wlan
            wlan = nb_wlan
        self.mode = cfg.wifi_mode
        self.host_if = cfg.veth_if
        self.log_ssid = bool(getattr(cfg, "wifi_log_ssid", False))
        self.state_path = os.path.join(cfg.state_dir, STATE_FILE)
        self.uplinks = uplinks
        self.wlan = wlan
        self.reader = reader if reader is not None else Nl80211Reader(NetlinkQuery())
        self.clock = clock
        self.ifname = ifname
        self.use_sockets = sockets
        self.key, self.key_source = load_key(getattr(cfg, "wifi_secret_file", ""))
        self.applied = None
        self.kind = "none"
        self._online = None
        self.uplink_name = "-"
        self.seq = read_state_seq(self.state_path)
        self._ifcache = {}
        self._uplink_ifindex = None
        self._genl = None
        self._pending = None
        self._retry_at = None
        self._poll_at = None
        self._poll_interval = SIGNAL_POLL_SECONDS
        self._available = False
        self._errors = {}
        self._resolve_tried = False
        self._last_write_at = None
        self._last_repush_at = None
        self._repush_gap = REPUSH_GAP_START_SECONDS
        self._disconnected_since = None

    def start(self):
        """follow the host's routes and nl80211 events"""
        if self.key is not None:
            self._resolve()
        self.uplinks.listeners.append(self.on_routes)
        log("NB_WIFI_UP mode=%s host_if=%s key=%s routes=%s nl80211=%s mlme=%s",
            self.mode, self.host_if, self.key_source or "none",
            "ok" if self.uplinks.known else "-",
            "-" if self.mode == "fixed" else ("yes" if self.reader.family is not None else "no"),
            "yes" if self._genl is not None else "no")
        self.evaluate("startup")

    def sockets(self):
        """return the mlme socket to poll"""
        return [self._genl] if self._genl is not None else []

    def on_host_state(self, _state):
        """ignore resolver and proxy changes"""

    def on_routes(self, reason):
        """re-evaluate the state when the host's default routes change"""
        self._ifcache.clear()
        self.evaluate(reason)

    def _resolve(self):
        """find nl80211 and join its mlme group"""
        if self.mode != "mirror" or self.reader.family is not None:
            return
        try:
            found = self.reader.resolve()
        except OSError as e:
            self._error("resolve", e)
            return
        self._errors.pop("resolve", None)
        if not found:
            if not self._resolve_tried:
                log("NB_WIFI_NL80211 found=0 -- every uplink reads as wired until cfg80211 loads")
            self._resolve_tried = True
            return
        if self.reader.mlme_group is None or not self.use_sockets:
            return
        try:
            self._genl = open_mlme_events(self.reader.mlme_group)
        except OSError as e:
            log("NB_WIFI_MLME_UNAVAILABLE error=%s", e)

    def feed(self, data):
        """read a datagram from the mlme socket"""
        family = self.reader.family
        if family is None:
            return
        for mtype, _flags, _seq, payload in iter_nlmsgs(data):
            if mtype != family or len(payload) < GENL_HDRLEN or payload[0] not in MLME_EVENTS:
                continue
            ifindex = parse_mlme_ifindex(payload[GENL_HDRLEN:])
            self._ifcache.pop(ifindex, None)
            if ifindex is None or ifindex == self._uplink_ifindex:
                if self._pending is None:
                    self._pending = "mlme"

    def process(self):
        """apply the changes of the fed datagrams"""
        reason, self._pending = self._pending, None
        if reason is not None:
            self.evaluate(reason)

    def deliver(self, data):
        """feed an mlme datagram and apply it"""
        self.feed(data)
        self.process()

    def on_readable(self, sock):
        """drain the mlme socket and apply the changes"""
        while True:
            try:
                data = sock.recv(RECV_SIZE)
            except BlockingIOError:
                break
            except OSError as e:
                if e.errno != errno.ENOBUFS:
                    raise
                self._ifcache.clear()
                if self._pending is None:
                    self._pending = "overrun"
                continue
            if not data:
                break
            self.feed(data)
        self.process()

    def _interface(self, ifindex):
        """return an interface's cached nl80211 view"""
        if ifindex in self._ifcache:
            return self._ifcache[ifindex]
        self._resolve()
        try:
            info = self.reader.interface(ifindex)
        except OSError as e:
            self._error("get_interface", e)
            return False
        self._errors.pop("get_interface", None)
        self._ifcache[ifindex] = info
        return info

    def _signal(self, ifindex, ssid):
        """return the host's signal in mBm"""
        try:
            dbm = self.reader.station_signal(ifindex)
        except OSError as e:
            self._error("get_station", e)
            dbm = None
        else:
            self._errors.pop("get_station", None)
        if dbm is not None:
            return dbm * 100
        a = self.applied
        if a is not None and a[0] and a[1] == ssid:
            return a[3]
        return FIXED_SIGNAL_MBM

    def _present(self, ssid, signal_mbm):
        """return an SSID's presented tuple"""
        return (True, ssid, derive_bssid(self.key, ssid), signal_mbm)

    def compute(self):
        """return the network to present, its uplink kind and route"""
        if self.key is None:
            return ABSENT, "no-key", None
        if not self.uplinks.known:
            return None, "unknown", None
        up = self.uplinks.uplink()
        if up is None:
            self._uplink_ifindex = None
            return self._present(FIXED_SSID, FIXED_SIGNAL_MBM), "none", None
        if up.ifindex != self._uplink_ifindex:
            self._ifcache.clear()
            self._uplink_ifindex = up.ifindex
        if self.mode == "fixed":
            return self._present(FIXED_SSID, FIXED_SIGNAL_MBM), "fixed", up
        info = self._interface(up.ifindex)
        if info is False:
            return None, "unknown", up
        if info is None or info[1] not in CLIENT_IFTYPES:
            return self._present(FIXED_SSID, FIXED_SIGNAL_MBM), "wired", up
        ssid = info[2] or FIXED_SSID
        return self._present(ssid, self._signal(up.ifindex, ssid)), "wireless", up

    def evaluate(self, reason, from_poll=False):
        """present the network of the host's connection"""
        desired, kind, up = self.compute()
        if desired is None:
            self._arm_retry(RETRY_SECONDS)
            return
        self.kind = kind
        self.uplink_name = (self.ifname(up.ifindex) or str(up.ifindex)) if up is not None else "-"
        seq_before = self.seq
        self.apply(desired, reason)
        self._note_reachability(desired, kind, seq_before)
        if from_poll:
            return
        if self._polls():
            self._poll_interval = SIGNAL_POLL_SECONDS
            self._poll_at = self.clock() + self._poll_interval
        else:
            self._poll_at = None

    def _note_reachability(self, desired, kind, seq_before):
        """re-publish an unchanged SSID when the uplink comes or goes"""
        a = self.applied
        if a is None or not a[0] or a[:3] != desired[:3]:
            return
        online = kind != "none"
        was, self._online = self._online, online
        if was is None or was == online or self.seq != seq_before:
            return
        self._write_state(a[1], "reachability")

    def _polls(self):
        """return True while the driver presents a network"""
        return self.applied is not None and self.applied[0]

    def _signal_polls(self):
        """return True while the presented network mirrors a wireless uplink"""
        return self.mode == "mirror" and self.kind == "wireless"

    def _differs(self, desired):
        """return True when the desired and applied networks differ"""
        a = self.applied
        if a is None or a[:3] != desired[:3]:
            return True
        return desired[0] and abs(desired[3] - a[3]) >= SIGNAL_STEP_MBM

    def _driver_available(self):
        """return True once wlan_available() returns true"""
        if self._available:
            return True
        try:
            self._available = bool(self.wlan.wlan_available())
        except Exception as e:  # noqa: BLE001
            self._error("wlan_available", e)
            self._available = False
        else:
            if not self._available:
                self._error("wlan_available", "the Rhizo Wi-Fi driver is not loaded")
        if not self._available:
            self._arm_retry(UNAVAILABLE_RETRY_SECONDS)
            return False
        self._errors.pop("wlan_available", None)
        return True

    def apply(self, desired, reason):
        """pass a changed network to the driver and record it"""
        if not self._differs(desired) or not self._driver_available():
            return
        present, ssid, bssid, signal_mbm = desired
        try:
            if present:
                self.wlan.set_state(self.host_if, True, ssid=ssid, bssid=bssid,
                                    signal_mbm=signal_mbm)
            else:
                self.wlan.set_state(self.host_if, False)
        except Exception as e:  # noqa: BLE001
            self._error("set_state", e)
            self._arm_retry(RETRY_SECONDS)
            return
        if self._errors.pop("set_state", None) is not None:
            log("NB_WIFI_RECOVERED call=set_state")
        prev, self.applied = self.applied, desired
        if prev is None or prev[:2] != desired[:2]:
            self._reset_repush()
        log("NB_WIFI reason=%s mode=%s uplink=%s kind=%s present=%d ssid=%s bssid=%s signal_mbm=%s",
            reason, self.mode, self.uplink_name, self.kind, int(present),
            self._ssid_for_log(ssid) if present else "-",
            mac_str(bssid) if present else "-",
            signal_mbm if present else "-")
        if present and (prev is None or not prev[0] or prev[1] != ssid):
            self._write_state(ssid, "ssid")

    def _ssid_for_log(self, ssid):
        """return the SSID as logged"""
        if ssid == FIXED_SSID:
            return "Rhizo"
        if self.log_ssid:
            text = sanitize_for_log(ssid.decode("utf-8", "backslashreplace"))
            return "%s(hex=%s)" % (text.replace(" ", "\\x20"), ssid.hex())
        return "hidden(len=%d)" % len(ssid)

    def _write_state(self, ssid, reason):
        """publish the presented SSID to the suggestion helper"""
        self.seq += 1
        self._last_write_at = self.clock()
        try:
            write_atomic(self.state_path, "%d %s\n" % (self.seq, ssid.hex()), 0o600)
        except OSError as e:
            log("NB_WIFI_STATE_FAILED path=%s error=%s", self.state_path, e)
            return
        log("NB_WIFI_STATE reason=%s seq=%d path=%s", reason, self.seq, self.state_path)

    def _repush(self, mono):
        """rewrite the state file while Android stays unassociated"""
        a = self.applied
        if a is None or not a[0] or self._last_write_at is None:
            return
        if mono - max(self._disconnected_since, self._last_write_at) <= REPUSH_AFTER_SECONDS:
            return
        if self._last_repush_at is not None:
            if mono - self._last_repush_at < self._repush_gap:
                return
            self._repush_gap = min(self._repush_gap * 2, REPUSH_GAP_MAX_SECONDS)
        self._last_repush_at = mono
        self._write_state(a[1], "repush")

    def _reset_repush(self):
        """start the re-push backoff over"""
        self._last_repush_at = None
        self._repush_gap = REPUSH_GAP_START_SECONDS

    def _error(self, call, e):
        """log an error once until its call succeeds again"""
        key = (getattr(e, "errno", None), str(e))
        if self._errors.get(call) == key:
            return
        self._errors[call] = key
        log("NB_WIFI_ERROR call=%s errno=%s error=%s -- retrying on the next event",
            call, key[0] if key[0] is not None else "-", sanitize_for_log(key[1]))

    def _arm_retry(self, delay):
        """schedule a retry no later than delay from now"""
        at = self.clock() + delay
        if self._retry_at is None or at < self._retry_at:
            self._retry_at = at

    def poll(self, mono):
        """read Android's association and poll the signal or re-push"""
        connected = None
        try:
            connected = bool(self.wlan.get_state(self.host_if).get("connected"))
        except Exception as e:  # noqa: BLE001
            self._error("get_state", e)
        else:
            self._errors.pop("get_state", None)
        if connected:
            self._disconnected_since = None
            self._reset_repush()
            if self._signal_polls():
                self._poll_interval = SIGNAL_POLL_SECONDS
                self.evaluate("signal", from_poll=True)
            else:
                self._poll_interval = IDLE_POLL_SECONDS
        else:
            if connected is False:
                if self._disconnected_since is None:
                    self._disconnected_since = mono
                self._repush(mono)
            self._poll_interval = min(self._poll_interval * 2, IDLE_POLL_SECONDS)
        self._poll_at = mono + self._poll_interval if self._polls() else None

    def next_tick(self, _mono):
        """return the next retry or poll time, or None"""
        due = [t for t in (self._retry_at, self._poll_at) if t is not None]
        return min(due) if due else None

    def tick(self, mono):
        """run a due retry or poll"""
        if self._retry_at is not None and mono >= self._retry_at:
            self._retry_at = None
            self.evaluate("retry")
        if self._poll_at is not None and mono >= self._poll_at:
            self.poll(mono)

    def close(self):
        """stop following the host"""
        try:
            self.uplinks.listeners.remove(self.on_routes)
        except ValueError:
            pass
        if self._genl is not None:
            try:
                self._genl.close()
            except OSError:
                pass
            self._genl = None
        self.reader.close()


class WifiSupervisor:
    """run the mirror, rebuilding it while it fails to start"""
    name = "wifi"

    def __init__(self, cfg, uplinks, build=None, clock=monotonic):
        """store the mirror's builder"""
        self.mode = cfg.wifi_mode
        self.clock = clock
        self.build = build if build is not None else (lambda: WifiMirror(cfg, uplinks))
        self.mirror = None
        self._retry_at = None
        self._failure = None

    def start(self):
        """build and start the mirror, or schedule another try"""
        mirror = None
        try:
            mirror = self.build()
            mirror.start()
        except Exception as e:  # noqa: BLE001
            if mirror is not None:
                try:
                    mirror.close()
                except Exception:  # noqa: BLE001
                    pass
            failure = str(e) or type(e).__name__
            if failure != self._failure:
                log("NB_WIFI_FAILED mode=%s error=%s -- retrying every %ds",
                    self.mode, sanitize_for_log(failure), int(BUILD_RETRY_SECONDS))
            self._failure = failure
            self._retry_at = self.clock() + BUILD_RETRY_SECONDS
            return
        if self._failure is not None:
            log("NB_WIFI_RECOVERED call=build")
        self._failure = None
        self._retry_at = None
        self.mirror = mirror

    def sockets(self):
        """return the mirror's sockets"""
        return self.mirror.sockets() if self.mirror is not None else []

    def on_readable(self, sock):
        """pass a readable socket to the mirror"""
        if self.mirror is not None:
            self.mirror.on_readable(sock)

    def on_host_state(self, _state):
        """ignore resolver and proxy changes"""

    def next_tick(self, mono):
        """return the mirror's next tick, or the next build attempt"""
        if self.mirror is not None:
            return self.mirror.next_tick(mono)
        return self._retry_at

    def tick(self, mono):
        """tick the mirror, or try building it again"""
        if self.mirror is not None:
            self.mirror.tick(mono)
        elif self._retry_at is not None and mono >= self._retry_at:
            importlib.invalidate_caches()
            self.start()

    def close(self):
        """close the mirror"""
        if self.mirror is not None:
            self.mirror.close()
