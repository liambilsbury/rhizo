#!/usr/bin/env python3
import array
import base64
import errno
import grp
import importlib.util
import json
import mimetypes
import os
import pwd
import re
import select
import socket
import subprocess
import sys
import urllib.parse

SOCKET_PATH = "/run/rhizo-broker/broker.sock"
ENTRY_DIR = "/usr/share/applications"
HERE = os.path.dirname(os.path.abspath(__file__))
DBUS_MIN_CANDIDATES = [
    "/usr/lib/rhizo/dbus_min.py",
    os.path.join(HERE, "..", "dbus_min.py"),
    os.path.join(HERE, "..", "deskbridge", "dbus_min.py"),
]

CLI_VERBS = {
    ("launch",): "launch",
    ("app", "list"): "list",
    ("app", "install"): "install",
    ("app", "remove"): "remove",
    ("start",): "start",
    ("status",): "status",
}

URI_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
SIGNIN_URL = "https://www.google.com/android/uncertified"
GSF_ID_RE = re.compile(r"^-?[0-9]{1,20}$")

MAX_SANDBOX_ID = 99
SANDBOX_ID_RE = re.compile(r"^[0-9]+$")
ACTIVATION_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:/+=@-]{1,255}")


def fail(reason):
    """print the reason as a RHIZO_FAIL line and return 1"""
    print("RHIZO_FAIL %s" % reason, flush=True)
    return 1


def rhizo_membership(uid=None):
    """return the account name and its rhizo group state"""
    uid = os.getuid() if uid is None else uid
    try:
        user = pwd.getpwuid(uid)
    except KeyError:
        return "uid %d" % uid, False, False
    try:
        group = grp.getgrnam("rhizo")
    except KeyError:
        return user.pw_name, False, False
    member = user.pw_name in group.gr_mem or user.pw_gid == group.gr_gid
    return user.pw_name, member, group.gr_gid in os.getgroups() or os.getegid() == group.gr_gid


def unreachable_reason(err, user, member, holds):
    """explain why the broker socket refused this process"""
    if err.errno == errno.EACCES and member and not holds:
        return ("cannot reach %s: %s joined group rhizo after this login began -- reboot to finish the install, "
                "or log in again if Rhizo was already set up" % (SOCKET_PATH, user))
    return "cannot reach %s: %s -- this account may not be in group rhizo" % (SOCKET_PATH, err)


class Unusable(Exception):
    """exception for an unusable launch argument"""


def request_instance(env=None):
    """read the instance id from RHIZO_SANDBOX_ID"""
    raw = (os.environ if env is None else env).get("RHIZO_SANDBOX_ID")
    if not raw:
        return 0
    if not SANDBOX_ID_RE.match(raw):
        raise Unusable("RHIZO_SANDBOX_ID=%r is not an instance id -- 0 to %d, digits only"
                       % (raw, MAX_SANDBOX_ID))
    inst_id = int(raw, 10)
    if inst_id > MAX_SANDBOX_ID:
        raise Unusable("RHIZO_SANDBOX_ID=%r is out of range -- 0 to %d"
                       % (raw, MAX_SANDBOX_ID))
    return inst_id


def activation_token(verb, env=None):
    """return the XDG activation token for a launch"""
    token = (os.environ if env is None else env).get("XDG_ACTIVATION_TOKEN")
    if verb != "launch" or not token:
        return None
    if not ACTIVATION_TOKEN_RE.fullmatch(token):
        print("rhizo: XDG_ACTIVATION_TOKEN %r is not one word of [A-Za-z0-9_.:/+=@-], "
              "so the app's window opens without it" % token[:80], file=sys.stderr)
        return None
    return token


def launch_arg_kind(arg):
    """return uri for a URI other than file:, else path"""
    if URI_RE.match(arg) and not arg.lower().startswith("file:"):
        return "uri"
    return "path"


def resolve_launch_file(arg):
    """resolve a launch argument to a file path"""
    raw = arg[len("file://"):] if arg.lower().startswith("file://") else arg
    path = os.path.realpath(urllib.parse.unquote(raw))
    if not (os.path.isfile(path) and os.access(path, os.R_OK)):
        raise Unusable("%s does not name a readable file" % path)
    return path


def file_mime(path):
    """return the MIME type of a file"""
    try:
        out = subprocess.run(["xdg-mime", "query", "filetype", path],
                             stdout=subprocess.PIPE).stdout
    except FileNotFoundError:
        raise Unusable("no xdg-mime on this host to read %s's type -- install xdg-utils" % path)
    mime = "".join(out.decode("utf-8", "replace").split(";", 1)[0].split())
    if not mime:
        mime = "".join((mimetypes.guess_type(path)[0] or "").split())
    if not mime:
        raise Unusable("neither xdg-mime nor python's mimetypes named a type for %s" % path)
    return mime


def load_dbus_min():
    """import dbus_min.py"""
    for cand in DBUS_MIN_CANDIDATES:
        path = os.path.normpath(cand)
        if not os.path.exists(path):
            continue
        spec = importlib.util.spec_from_file_location("dbus_min", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    return None


class Notifier:
    """desktop notifications over D-Bus"""

    def __init__(self, label):
        """store the label and start with no bus connection"""
        self.label = label
        self.bus = None
        self.dbus_min = None
        self.unavailable = None

    def give_up(self, reason):
        """record why notifications are unavailable and print it"""
        self.unavailable = reason
        print("rhizo: %s, so no desktop notification was raised" % reason, file=sys.stderr)

    def connect(self):
        """connect to the session bus"""
        if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            self.give_up("no session bus (DBUS_SESSION_BUS_ADDRESS is unset)")
            return
        self.dbus_min = load_dbus_min()
        if self.dbus_min is None:
            self.give_up("no dbus_min.py at " + ", nor at ".join(DBUS_MIN_CANDIDATES))
            return
        try:
            self.bus = self.dbus_min.Connection.connect()
            self.bus.hello()
        except (self.dbus_min.DBusError, TimeoutError, ConnectionError, OSError) as e:
            self.bus = None
            self.give_up("the session bus at %s refused this client: %s"
                         % (os.environ["DBUS_SESSION_BUS_ADDRESS"], e))

    def post(self, summary):
        """send a desktop notification at normal urgency"""
        if self.bus is None and self.unavailable is None:
            self.connect()
        if self.bus is None:
            return
        try:
            self.bus.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                          "org.freedesktop.Notifications", "Notify", "susssasa{sv}i",
                          ["Rhizo", 0, "", summary, "", [], {}, -1])
        except (self.dbus_min.DBusError, TimeoutError, ConnectionError, OSError) as e:
            print("rhizo: the desktop refused the notification %r: %s" % (summary, e),
                  file=sys.stderr)

    def handle(self, line):
        """post a notification for an install, remove or failure line"""
        if line.startswith("RHIZO_APP installed="):
            self.post("Installed %s" % (sentinel_label(line) or self.label))
        elif line.startswith("RHIZO_APP removed="):
            self.post("Removed %s" % self.label)
        elif line.startswith("RHIZO_FAIL "):
            self.post(line[len("RHIZO_FAIL "):])


def copy_to_clipboard(text, env=None):
    """copy text to the session's clipboard and return success"""
    env = os.environ if env is None else env
    if env.get("WAYLAND_DISPLAY"):
        argv = ["wl-copy"]
    elif env.get("DISPLAY"):
        argv = ["xclip", "-selection", "clipboard"]
    else:
        print("rhizo: no WAYLAND_DISPLAY or DISPLAY, so the clipboard was not set", file=sys.stderr)
        return False
    try:
        rc = subprocess.run(argv, input=text.encode(), stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=10).returncode
    except (OSError, subprocess.TimeoutExpired) as e:
        print("rhizo: %s did not take the text: %s" % (argv[0], e), file=sys.stderr)
        return False
    return rc == 0


def open_signin(line):
    """open Google's registration page and copy the device ID"""
    fields = dict(f.split("=", 1) for f in line.split()[1:] if "=" in f)
    url, gsf_id = fields.get("url"), fields.get("id", "-")
    if url != SIGNIN_URL:
        print("rhizo: %r names %r, not %s, so nothing was opened" % (line, url, SIGNIN_URL), file=sys.stderr)
        return
    if GSF_ID_RE.match(gsf_id):
        copy_to_clipboard(gsf_id)
    else:
        print("rhizo: Google has not given this device an ID to register yet", file=sys.stderr)
    try:
        subprocess.Popen(["xdg-open", url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        print("rhizo: could not run xdg-open %s: %s" % (url, e), file=sys.stderr)


def sentinel_label(line):
    """read the label from a sentinel line"""
    fields = dict(f.split("=", 1) for f in line.split() if "=" in f)
    if "label" in fields:
        try:
            return base64.b64decode(fields["label"], validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as e:
            print("rhizo: %r carries an undecodable label: %s" % (line, e), file=sys.stderr)
    pkg = fields.get("installed")
    return entry_label(pkg) or pkg if pkg else None


def entry_label(pkg):
    """return the Name= value of a desktop entry"""
    path = os.path.join(ENTRY_DIR, "rhizo-%s.desktop" % pkg)
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("Name="):
                    return line[len("Name="):].strip()
    except OSError:
        return None
    return None


def send_request(sock, verb, args, fd, inst_id=0, token=None):
    """send the JSON request to the socket"""
    request = {"v": 1, "verb": verb,
               "args": [base64.b64encode(a.encode()).decode() for a in args]}
    if token:
        request["activation_token"] = token
    if inst_id:
        request["id"] = inst_id
    payload = (json.dumps(request) + "\n").encode()
    if fd is None:
        sock.sendall(payload)
        return
    sock.sendmsg([payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                              array.array("i", [fd]))])


def stream_reply(sock, notifier, idle_timeout=300):
    """print the reply and return the trailer status"""
    rc = None
    buf = b""
    while True:
        if not select.select([sock], [], [], idle_timeout)[0]:
            print("rhizo: broker went quiet for %ds" % idle_timeout, file=sys.stderr)
            break
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
        lines = buf.split(b"\n")
        buf = lines.pop()
        for raw in lines:
            line = raw.decode("utf-8", "replace")
            if line.startswith("RHIZO_BROKER_RC="):
                try:
                    rc = int(line[len("RHIZO_BROKER_RC="):])
                except ValueError:
                    print("rhizo: broker sent an unreadable trailer %r" % line, file=sys.stderr)
                continue
            if line.startswith("E "):
                print(line[2:], file=sys.stderr, flush=True)
                continue
            print(line, flush=True)
            notifier.handle(line)
            if line.startswith("RHIZO_GAPPS_SIGNIN "):
                open_signin(line)
    if buf:
        print(buf.decode("utf-8", "replace"), flush=True)
    return rc


def main(argv):
    """send a request to rhizo-brokerd"""
    verb = None
    for shape, wire in CLI_VERBS.items():
        if tuple(argv[:len(shape)]) == shape:
            verb, rest = wire, argv[len(shape):]
            break
    if verb is None:
        return fail("%r is not a verb this account can ask for -- launch, app list, "
                    "app install, app remove, start and status are" % " ".join(argv))

    try:
        inst_id = request_instance()
    except Unusable as e:
        return fail(str(e))

    fd = None
    if verb == "install":
        if len(rest) != 1:
            return fail("app install takes one file")
        try:
            fd = os.open(rest[0], os.O_RDONLY)
        except OSError as e:
            return fail("cannot read %s: %s" % (rest[0], e))
        rest = []

    if verb == "launch" and len(rest) == 2 and launch_arg_kind(rest[1]) == "path":
        try:
            path = resolve_launch_file(rest[1])
            rest = [rest[0], path, file_mime(path)]
        except Unusable as e:
            return fail(str(e))

    label = "Rhizo"
    if verb in ("launch", "remove") and rest:
        label = entry_label(rest[0]) or rest[0]
    notifier = Notifier(label)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except OSError as e:
        return fail(unreachable_reason(e, *rhizo_membership()))
    send_request(sock, verb, rest, fd, inst_id, activation_token(verb))
    if fd is not None:
        os.close(fd)
    sock.shutdown(socket.SHUT_WR)
    rc = stream_reply(sock, notifier)
    if rc is None:
        notifier.handle("RHIZO_FAIL the broker closed the connection with no RHIZO_BROKER_RC trailer")
        return fail("the broker closed the connection with no RHIZO_BROKER_RC trailer")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
