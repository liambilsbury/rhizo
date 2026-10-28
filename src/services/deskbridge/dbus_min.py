import os
import select
import socket
import struct
import time


class Variant:
    """value with a D-Bus signature"""

    __slots__ = ("sig", "value")

    def __init__(self, sig, value):
        """store the signature and value of a variant"""
        self.sig = sig
        self.value = value

    def __eq__(self, other):
        """return whether another object is a variant with the same signature and value"""
        return isinstance(other, Variant) and self.sig == other.sig and self.value == other.value

    def __repr__(self):
        """return the variant as text"""
        return "Variant(%r, %r)" % (self.sig, self.value)


class DBusError(Exception):
    """exception for a D-Bus error reply"""

    def __init__(self, name, text):
        """store the error name and text"""
        super().__init__("%s: %s" % (name, text))
        self.name = name
        self.text = text


METHOD_CALL = 1
METHOD_RETURN = 2
ERROR = 3
SIGNAL = 4

FLAG_NO_REPLY_EXPECTED = 0x1
FLAG_NO_AUTO_START = 0x2

_HEADER_PATH = 1
_HEADER_INTERFACE = 2
_HEADER_MEMBER = 3
_HEADER_ERROR_NAME = 4
_HEADER_REPLY_SERIAL = 5
_HEADER_DESTINATION = 6
_HEADER_SENDER = 7
_HEADER_SIGNATURE = 8
_HEADER_UNIX_FDS = 9

NAME_FLAG_ALLOW_REPLACEMENT = 0x1
NAME_FLAG_REPLACE_EXISTING = 0x2
NAME_FLAG_DO_NOT_QUEUE = 0x4

REQUEST_NAME_REPLY_PRIMARY_OWNER = 1
REQUEST_NAME_REPLY_IN_QUEUE = 2
REQUEST_NAME_REPLY_EXISTS = 3
REQUEST_NAME_REPLY_ALREADY_OWNER = 4

_BUS_DEST = "org.freedesktop.DBus"
_BUS_PATH = "/org/freedesktop/DBus"
_BUS_IFACE = "org.freedesktop.DBus"


_BASIC_ALIGN = {
    "y": 1, "b": 4, "n": 2, "q": 2, "u": 4, "i": 4,
    "x": 8, "t": 8, "d": 8, "s": 4, "o": 4, "g": 1, "v": 1,
}


def parse_one(sig, i):
    """parse a type from a signature"""
    c = sig[i]
    if c in _BASIC_ALIGN:
        return c, i + 1
    if c == "a":
        child, j = parse_one(sig, i + 1)
        return ("a", child), j
    if c == "(":
        children = []
        j = i + 1
        while sig[j] != ")":
            child, j = parse_one(sig, j)
            children.append(child)
        return ("r", children), j + 1
    if c == "{":
        key, j = parse_one(sig, i + 1)
        val, j = parse_one(sig, j)
        if sig[j] != "}":
            raise ValueError("dict entry not closed in signature %r" % sig)
        return ("e", [key, val]), j + 1
    raise ValueError("unsupported signature character %r in %r" % (c, sig))


def parse_signature(sig):
    """split a signature into type nodes"""
    nodes = []
    i = 0
    while i < len(sig):
        node, i = parse_one(sig, i)
        nodes.append(node)
    return nodes


def _align_of(node):
    """return the alignment of a type node"""
    if isinstance(node, str):
        return _BASIC_ALIGN[node]
    if node[0] == "a":
        return 4
    return 8



class _Writer:
    def __init__(self):
        """start an empty message buffer"""
        self.buf = bytearray()

    def align(self, n):
        """pad the buffer to a multiple of n bytes"""
        pad = (-len(self.buf)) % n
        self.buf += b"\x00" * pad


def pack_value(w, node, value):
    """append a value of the given type to the writer buffer"""
    if node == "y":
        w.buf.append(value & 0xFF)
    elif node == "b":
        w.align(4)
        w.buf += struct.pack("<I", 1 if value else 0)
    elif node == "n":
        w.align(2)
        w.buf += struct.pack("<h", value)
    elif node == "q":
        w.align(2)
        w.buf += struct.pack("<H", value)
    elif node == "u":
        w.align(4)
        w.buf += struct.pack("<I", value)
    elif node == "i":
        w.align(4)
        w.buf += struct.pack("<i", value)
    elif node == "x":
        w.align(8)
        w.buf += struct.pack("<q", value)
    elif node == "t":
        w.align(8)
        w.buf += struct.pack("<Q", value)
    elif node == "d":
        w.align(8)
        w.buf += struct.pack("<d", value)
    elif node in ("s", "o"):
        b = value.encode("utf-8")
        w.align(4)
        w.buf += struct.pack("<I", len(b))
        w.buf += b
        w.buf.append(0)
    elif node == "g":
        b = value.encode("ascii")
        w.buf.append(len(b))
        w.buf += b
        w.buf.append(0)
    elif node == "v":
        pack_value(w, "g", value.sig)
        child, _ = parse_one(value.sig, 0)
        pack_value(w, child, value.value)
    elif node[0] == "a":
        elem = node[1]
        w.align(4)
        len_pos = len(w.buf)
        w.buf += b"\x00\x00\x00\x00"
        w.align(_align_of(elem))
        start = len(w.buf)
        if elem[0] == "e":
            items = value.items() if isinstance(value, dict) else value
            for k, v in items:
                pack_value(w, elem, (k, v))
        else:
            for item in value:
                pack_value(w, elem, item)
        struct.pack_into("<I", w.buf, len_pos, len(w.buf) - start)
    elif node[0] == "r":
        w.align(8)
        for child, v in zip(node[1], value):
            pack_value(w, child, v)
    elif node[0] == "e":
        w.align(8)
        pack_value(w, node[1][0], value[0])
        pack_value(w, node[1][1], value[1])
    else:
        raise ValueError("unhandled type node %r" % (node,))


class _Reader:
    def __init__(self, data, pos):
        """start a reader over data at a position"""
        self.data = data
        self.pos = pos

    def align(self, n):
        """advance the position to a multiple of n bytes"""
        self.pos += (-self.pos) % n

    def take(self, n):
        """return the next n bytes and advance"""
        end = self.pos + n
        if end > len(self.data):
            raise ValueError("message truncated: wanted %d bytes at %d, have %d" % (n, self.pos, len(self.data)))
        b = self.data[self.pos:end]
        self.pos = end
        return b


def unpack_value(r, node):
    """read a value of the given type from the reader"""
    if node == "y":
        return r.take(1)[0]
    if node == "b":
        r.align(4)
        return struct.unpack("<I", r.take(4))[0] != 0
    if node == "n":
        r.align(2)
        return struct.unpack("<h", r.take(2))[0]
    if node == "q":
        r.align(2)
        return struct.unpack("<H", r.take(2))[0]
    if node == "u":
        r.align(4)
        return struct.unpack("<I", r.take(4))[0]
    if node == "i":
        r.align(4)
        return struct.unpack("<i", r.take(4))[0]
    if node == "x":
        r.align(8)
        return struct.unpack("<q", r.take(8))[0]
    if node == "t":
        r.align(8)
        return struct.unpack("<Q", r.take(8))[0]
    if node == "d":
        r.align(8)
        return struct.unpack("<d", r.take(8))[0]
    if node in ("s", "o"):
        r.align(4)
        n = struct.unpack("<I", r.take(4))[0]
        s = bytes(r.take(n)).decode("utf-8")
        r.take(1)
        return s
    if node == "g":
        n = r.take(1)[0]
        s = bytes(r.take(n)).decode("ascii")
        r.take(1)
        return s
    if node == "v":
        sig = unpack_value(r, "g")
        child, _ = parse_one(sig, 0)
        return Variant(sig, unpack_value(r, child))
    if node[0] == "a":
        elem = node[1]
        r.align(4)
        n = struct.unpack("<I", r.take(4))[0]
        r.align(_align_of(elem))
        end = r.pos + n
        if elem[0] == "e":
            result = {}
            while r.pos < end:
                k, v = unpack_value(r, elem)
                result[k] = v
            return result
        result = []
        while r.pos < end:
            result.append(unpack_value(r, elem))
        return result
    if node[0] == "r":
        r.align(8)
        return tuple(unpack_value(r, c) for c in node[1])
    if node[0] == "e":
        r.align(8)
        k = unpack_value(r, node[1][0])
        v = unpack_value(r, node[1][1])
        return (k, v)
    raise ValueError("unhandled type node %r" % (node,))



class Message:
    """D-Bus message"""

    def __init__(self, mtype, flags, serial):
        """start a message with its type, flags and serial"""
        self.mtype = mtype
        self.flags = flags
        self.serial = serial
        self.path = None
        self.interface = None
        self.member = None
        self.error_name = None
        self.reply_serial = None
        self.destination = None
        self.sender = None
        self.signature = None
        self.body = []


def build_message(mtype, flags, serial, signature, args, path=None, interface=None,
                   member=None, error_name=None, reply_serial=None, destination=None):
    """build the bytes of a D-Bus message"""
    w = _Writer()
    w.buf += bytes([ord("l"), mtype, flags, 1])
    w.buf += b"\x00\x00\x00\x00"
    w.buf += struct.pack("<I", serial)

    fields = []
    if path is not None:
        fields.append((_HEADER_PATH, Variant("o", path)))
    if interface is not None:
        fields.append((_HEADER_INTERFACE, Variant("s", interface)))
    if member is not None:
        fields.append((_HEADER_MEMBER, Variant("s", member)))
    if error_name is not None:
        fields.append((_HEADER_ERROR_NAME, Variant("s", error_name)))
    if reply_serial is not None:
        fields.append((_HEADER_REPLY_SERIAL, Variant("u", reply_serial)))
    if destination is not None:
        fields.append((_HEADER_DESTINATION, Variant("s", destination)))
    if signature:
        fields.append((_HEADER_SIGNATURE, Variant("g", signature)))
    pack_value(w, ("a", ("r", ["y", "v"])), fields)
    w.align(8)

    body_start = len(w.buf)
    for node, val in zip(parse_signature(signature or ""), args):
        pack_value(w, node, val)
    struct.pack_into("<I", w.buf, 4, len(w.buf) - body_start)
    return bytes(w.buf)


def try_parse_message(buf):
    """parse a message from the buffer start"""
    if len(buf) < 16:
        return None
    if buf[0] != ord("l"):
        raise ValueError("unsupported byte order marker %r (only little-endian is spoken)" % buf[0])
    mtype = buf[1]
    flags = buf[2]
    body_length = struct.unpack_from("<I", buf, 4)[0]
    serial = struct.unpack_from("<I", buf, 8)[0]
    fields_len = struct.unpack_from("<I", buf, 12)[0]
    header_end = 16 + fields_len
    header_end_padded = header_end + ((-header_end) % 8)
    total = header_end_padded + body_length
    if len(buf) < total:
        return None

    r = _Reader(buf, 12)
    fields = unpack_value(r, ("a", ("r", ["y", "v"])))
    r.align(8)

    msg = Message(mtype, flags, serial)
    for code, variant in fields:
        if code == _HEADER_PATH:
            msg.path = variant.value
        elif code == _HEADER_INTERFACE:
            msg.interface = variant.value
        elif code == _HEADER_MEMBER:
            msg.member = variant.value
        elif code == _HEADER_ERROR_NAME:
            msg.error_name = variant.value
        elif code == _HEADER_REPLY_SERIAL:
            msg.reply_serial = variant.value
        elif code == _HEADER_DESTINATION:
            msg.destination = variant.value
        elif code == _HEADER_SENDER:
            msg.sender = variant.value
        elif code == _HEADER_SIGNATURE:
            msg.signature = variant.value

    body_nodes = parse_signature(msg.signature or "")
    br = _Reader(buf, header_end_padded)
    msg.body = [unpack_value(br, n) for n in body_nodes]
    return msg, total



def _unescape(s):
    """decode %xx escapes in a string into bytes"""
    out = bytearray()
    i = 0
    while i < len(s):
        if s[i] == "%":
            out += bytes.fromhex(s[i + 1:i + 3])
            i += 3
        else:
            out.append(ord(s[i]))
            i += 1
    return out.decode("utf-8")


def parse_unix_address(address):
    """parse path or abstract from a bus address"""
    for entry in address.split(";"):
        if not entry.startswith("unix:"):
            continue
        kv = {}
        for pair in entry[len("unix:"):].split(","):
            if not pair:
                continue
            k, _, v = pair.partition("=")
            kv[k] = _unescape(v)
        if "path" in kv:
            return kv["path"], None
        if "abstract" in kv:
            return None, kv["abstract"]
        raise ValueError("unix transport has neither path= nor abstract=: %r" % entry)
    raise ValueError("no unix: transport in bus address %r" % address)


def _read_sasl_line(sock, timeout=5.0):
    """read an SASL line from the bus socket within a timeout"""
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while not buf.endswith(b"\r\n"):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([sock], [], [], remaining)[0]:
            raise TimeoutError("no SASL line from the bus within %.1fs" % timeout)
        b = sock.recv(1)
        if not b:
            raise ConnectionError("bus closed during SASL handshake")
        buf += b
    return buf[:-2].decode("ascii")



class Connection:
    """D-Bus connection over a unix socket"""
    def __init__(self, sock):
        """wrap a connected socket with empty message queues"""
        self.sock = sock
        self.unique_name = None
        self._serial = 0
        self._inbuf = bytearray()
        self._pending = []
        self._objects = {}

    @classmethod
    def connect(cls, address=None):
        """connect to the session bus and authenticate"""
        if address is None:
            address = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
            if not address:
                raise RuntimeError("DBUS_SESSION_BUS_ADDRESS is not set")
        path, abstract = parse_unix_address(address)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(("\0" + abstract) if abstract is not None else path)
        conn = cls(sock)
        conn._authenticate()
        return conn

    def _authenticate(self):
        """authenticate to the bus with the EXTERNAL mechanism"""
        self.sock.sendall(b"\0")
        hex_uid = str(os.getuid()).encode("ascii").hex()
        self.sock.sendall(("AUTH EXTERNAL " + hex_uid + "\r\n").encode("ascii"))
        reply = _read_sasl_line(self.sock)
        if reply.startswith("REJECTED"):
            raise DBusError("org.freedesktop.DBus.Error.AuthFailed", reply)
        if not reply.startswith("OK "):
            raise DBusError("org.freedesktop.DBus.Error.AuthFailed", "unexpected SASL reply: %s" % reply)
        self.sock.sendall(b"BEGIN\r\n")

    def fileno(self):
        """return the socket's file descriptor"""
        return self.sock.fileno()

    def close(self):
        """close the socket"""
        self.sock.close()

    def _drain(self):
        """return every complete message in the input buffer"""
        msgs = []
        while True:
            parsed = try_parse_message(self._inbuf)
            if parsed is None:
                break
            msg, consumed = parsed
            del self._inbuf[:consumed]
            msgs.append(msg)
        return msgs

    def _pump(self, timeout):
        """read available bytes from the socket into the input buffer"""
        if not select.select([self.sock], [], [], timeout)[0]:
            return
        data = self.sock.recv(65536)
        if not data:
            raise ConnectionError("bus connection closed")
        self._inbuf += data
        self._pending.extend(self._drain())

    def dispatch(self):
        """return the messages read from the socket"""
        self._pump(0)
        msgs, self._pending = self._pending, []
        return msgs

    def _send(self, mtype, flags, signature, args, **kw):
        """send a message with the next serial and return the serial"""
        self._serial += 1
        self.sock.sendall(build_message(mtype, flags, self._serial, signature, args, **kw))
        return self._serial

    def call_async(self, dest, path, iface, member, signature, args):
        """send a method call and return its serial"""
        return self._send(METHOD_CALL, 0, signature, args, path=path,
                          interface=iface, member=member, destination=dest)

    def call(self, dest, path, iface, member, signature, args, timeout=5.0):
        """call a method and return the reply body"""
        serial = self.call_async(dest, path, iface, member, signature, args)
        deadline = time.monotonic() + timeout
        while True:
            for i, m in enumerate(self._pending):
                if m.reply_serial == serial and m.mtype in (METHOD_RETURN, ERROR):
                    del self._pending[i]
                    if m.mtype == ERROR:
                        raise DBusError(m.error_name, m.body[0] if m.body else "")
                    return m.body
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no reply to %s.%s within %.1fs" % (iface, member, timeout))
            self._pump(remaining)

    def hello(self):
        """say hello to the bus and return the unique name"""
        body = self.call(_BUS_DEST, _BUS_PATH, _BUS_IFACE, "Hello", "", [])
        self.unique_name = body[0]
        return self.unique_name

    def request_name(self, name, flags=0):
        """request a well-known bus name and return the reply code"""
        body = self.call(_BUS_DEST, _BUS_PATH, _BUS_IFACE, "RequestName", "su", [name, flags])
        return body[0]

    def add_match(self, rule):
        """add a match rule to the bus"""
        self.call(_BUS_DEST, _BUS_PATH, _BUS_IFACE, "AddMatch", "s", [rule])

    def send_reply(self, msg, signature, args):
        """send a method return for a message"""
        self._send(METHOD_RETURN, FLAG_NO_REPLY_EXPECTED, signature, args,
                    reply_serial=msg.serial, destination=msg.sender)

    def send_error(self, msg, error_name, text):
        """send an error reply for a message"""
        self._send(ERROR, FLAG_NO_REPLY_EXPECTED, "s", [text],
                    error_name=error_name, reply_serial=msg.serial, destination=msg.sender)

    def emit_signal(self, path, iface, member, signature, args, destination=None):
        """emit a signal"""
        self._send(SIGNAL, FLAG_NO_REPLY_EXPECTED, signature, args, path=path,
                    interface=iface, member=member, destination=destination)

    _INTROSPECT_DOCTYPE = (
        '<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" '
        '"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">'
    )
    _STANDARD_INTERFACES = (
        '<interface name="org.freedesktop.DBus.Introspectable">'
        '<method name="Introspect"><arg name="xml_data" type="s" direction="out"/></method>'
        "</interface>"
        '<interface name="org.freedesktop.DBus.Peer">'
        '<method name="Ping"/>'
        "</interface>"
    )

    def register_object(self, path, interfaces_xml):
        """set the introspection XML of an object path"""
        self._objects[path] = interfaces_xml

    def handle_standard(self, msg):
        """reply to Introspect and Ping calls"""
        if msg.mtype != METHOD_CALL:
            return False
        if msg.member == "Ping" and msg.interface in (None, "org.freedesktop.DBus.Peer"):
            self.send_reply(msg, "", [])
            return True
        if msg.member == "Introspect" and msg.interface in (None, "org.freedesktop.DBus.Introspectable"):
            extra = self._objects.get(msg.path, "")
            xml = self._INTROSPECT_DOCTYPE + "<node>" + self._STANDARD_INTERFACES + extra + "</node>"
            self.send_reply(msg, "s", [xml])
            return True
        return False
