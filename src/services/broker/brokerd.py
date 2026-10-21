#!/usr/bin/env python3
import base64
import json
import os
import re
import secrets
import selectors
import socket
import stat
import struct
import subprocess
import sys

_here = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_here, os.path.join(_here, "..")]
import inbox_stage  # noqa: E402

CLI = "/usr/bin/rhizo"
BASH = "/usr/bin/bash"
INBOX_SANDBOX_DIR = "/data/rhizo_inbox"
INBOX_LABEL = "u:object_r:rhizo_inbox_file:s0"
SELINUX_MODE_FILE = os.environ.get("RHIZO_SELINUX_MODE_FILE", "/run/rhizo-selinux-mode")
APK_SIZE_LIMIT = 512 * 1024 * 1024
REQUEST_LIMIT = 65536

MAX_SANDBOX_ID = 99


def request_instance(request):
    """return the instance id of a request, refusing an out of range"""
    inst_id = request.get("id", 0)
    if not isinstance(inst_id, int) or isinstance(inst_id, bool):
        raise Refused("id must be an integer, got %r" % (inst_id,))
    if not 0 <= inst_id <= MAX_SANDBOX_ID:
        raise Refused("id must be 0-%d, got %r" % (MAX_SANDBOX_ID, inst_id))
    return inst_id


def run_root(inst_id):
    """return the runtime tree root of an instance"""
    return "/run/rhizo" if inst_id == 0 else "/run/rhizo-%d" % inst_id


def inbox_dir(inst_id):
    """return the install inbox directory of an instance"""
    return run_root(inst_id) + "/data/rhizo_inbox"


PKG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.]*$")
URI_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
ABS_PATH_RE = re.compile(r"^/[^\x00-\x1f]{0,4095}$")
MIME_RE = re.compile(r"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$")
ACTIVATION_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:/+=@-]{1,255}")
PKG_LIMIT = 255
TARGET_LIMIT = 4096
MIME_LIMIT = 255

VERBS = {
    "launch": (["launch"], (1, 3)),
    "install": (["app", "install"], (0, 1)),
    "remove": (["app", "remove"], (1, 1)),
    "list": (["app", "list"], (0, 0)),
    "start": (["start"], (0, 0)),
    "status": (["status"], (0, 1)),
}


def log(msg):
    """write a message to stderr"""
    print(msg, file=sys.stderr, flush=True)


class Refused(Exception):
    """exception for a failed request"""


def close_all(fds):
    """close each file descriptor, ignoring errors"""
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


def read_request(sock, fds):
    """read the request line and passed file descriptors"""
    buf = b""
    while b"\n" not in buf:
        if len(buf) > REQUEST_LIMIT:
            raise Refused("request line exceeds %d bytes with no newline" % REQUEST_LIMIT)
        data, ancdata, flags, _addr = sock.recvmsg(REQUEST_LIMIT, socket.CMSG_SPACE(4))
        if flags & socket.MSG_CTRUNC:
            raise Refused("ancillary data truncated")
        for level, ctype, cdata in ancdata:
            if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
                usable = len(cdata) - len(cdata) % 4
                fds.extend(struct.unpack("%di" % (usable // 4), cdata[:usable]))
        if not data:
            raise Refused("connection closed before a complete request line arrived")
        buf += data
    return buf.split(b"\n", 1)[0]


def decode_args(raw_args):
    """decode the base64 arguments of a request into strings"""
    out = []
    for a in raw_args:
        if not isinstance(a, str):
            raise Refused("argument %r is not a string" % (a,))
        try:
            out.append(base64.b64decode(a, validate=True).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise Refused("argument is not base64-encoded utf-8: %s" % e)
    return out


def request_activation_token(request):
    """return the activation token of a request, or None"""
    if "activation_token" not in request:
        return None
    token = request["activation_token"]
    if request.get("verb") != "launch":
        raise Refused("activation_token is for launch only, got it on %r" % (request.get("verb"),))
    if not isinstance(token, str) or not ACTIVATION_TOKEN_RE.fullmatch(token):
        raise Refused("activation_token %r is not one word of [A-Za-z0-9_.:/+=@-], 1-255 long"
                      % (token if not isinstance(token, str) else token[:80],))
    return token


def child_env(inst_id, token, base=None):
    """build the environment for the CLI from the instance id and token"""
    env = dict(os.environ if base is None else base, RHIZO_SANDBOX_ID=str(inst_id))
    env.pop("XDG_ACTIVATION_TOKEN", None)
    if token:
        env["XDG_ACTIVATION_TOKEN"] = token
    return env


def check_package(name):
    """refuse a package name that is too long or malformed"""
    if len(name) > PKG_LIMIT:
        raise Refused("package name is %d characters, limit is %d" % (len(name), PKG_LIMIT))
    if not PKG_RE.match(name):
        raise Refused("%r is not a package name" % name[:120])


def check_launch_target(target):
    """refuse a launch target that is not a URI or absolute path"""
    if len(target) > TARGET_LIMIT:
        raise Refused("launch target is %d characters, limit is %d" % (len(target), TARGET_LIMIT))
    if not (URI_RE.match(target) or ABS_PATH_RE.match(target)):
        raise Refused("%r is neither a URI nor an absolute path" % target[:120])


def check_launch_mime(mime):
    """refuse a launch mime type that is too long or malformed"""
    if len(mime) > MIME_LIMIT:
        raise Refused("mime type is %d characters, limit is %d" % (len(mime), MIME_LIMIT))
    if not MIME_RE.match(mime):
        raise Refused("%r is not a lowercase type/subtype" % mime[:120])


def inbox_label(mode_file=SELINUX_MODE_FILE):
    """return the inbox file label for namespace mode"""
    try:
        with open(mode_file) as f:
            mode = f.read().rstrip("\n")
    except OSError as e:
        raise Refused("cannot read the SELinux mode from %s: %s" % (mode_file, e))
    if mode not in ("host", "namespace"):
        raise Refused("the SELinux mode in %s reads %r, not host or namespace" % (mode_file, mode))
    return INBOX_LABEL if mode == "namespace" else None


def materialize_apk(fd, root, mode_file=SELINUX_MODE_FILE, inst_id=0):
    """copy the passed apk into the inbox"""
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise Refused("the passed descriptor is not a regular file (st_mode %o)" % st.st_mode)
    if st.st_size == 0:
        raise Refused("the passed file is empty")
    if st.st_size > APK_SIZE_LIMIT:
        raise Refused("the passed file is %d bytes, limit is %d" % (st.st_size, APK_SIZE_LIMIT))
    inbox = root + "/data/rhizo_inbox"
    if not os.path.isdir(inbox):
        raise Refused("no %s -- the sandbox has not booted with an install inbox" % inbox)
    label = inbox_label(mode_file)
    name = secrets.token_hex(8) + ".apk"
    try:
        inbox_stage.stage(root, name, "/proc/self/fd/%d" % fd, label, size=st.st_size, sandbox_id=inst_id)
    except OSError as e:
        raise Refused("cannot stage %s in %s: %s" % (name, inbox, e))
    log("wrote %s to %s" % (name, inbox))
    return os.path.join(INBOX_SANDBOX_DIR, name)


def build_argv(request, fds, inst_id=0):
    """build the CLI argv from a request"""
    if not isinstance(request, dict):
        raise Refused("request is not a JSON object")
    if request.get("v") != 1:
        raise Refused("unsupported protocol version %r" % (request.get("v"),))
    verb = request.get("verb")
    if verb not in VERBS:
        raise Refused("unknown verb %r" % (verb,))
    raw_args = request.get("args", [])
    if not isinstance(raw_args, list):
        raise Refused("args is not a list")
    args = decode_args(raw_args)
    cli_argv, (low, high) = VERBS[verb]
    if not low <= len(args) <= high:
        raise Refused("%s takes %d to %d arguments, got %d" % (verb, low, high, len(args)))
    if verb == "install":
        if len(fds) != 1:
            raise Refused("install needs exactly one SCM_RIGHTS descriptor, got %d" % len(fds))
        return cli_argv + ["--from-inbox", materialize_apk(fds[0], run_root(inst_id), inst_id=inst_id)]
    if fds:
        raise Refused("%s takes no descriptor, got %d" % (verb, len(fds)))
    if verb == "status" and args and args[0] != "--json":
        raise Refused("status takes --json or nothing, got %r" % (args[0],))
    if verb in ("launch", "remove"):
        check_package(args[0])
    if verb == "launch" and len(args) >= 2:
        check_launch_target(args[1])
    if verb == "launch" and len(args) == 3:
        check_launch_mime(args[2])
        return cli_argv + [args[0], args[1], "--mime", args[2]]
    return cli_argv + args


def relay(sock, argv, inst_id, token=None):
    """run the CLI and send its output to the socket"""
    env = child_env(inst_id, token)
    try:
        child = subprocess.Popen([BASH, CLI] + argv, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=env)
    except OSError as e:
        sock.sendall(("E cannot run %s %s: %s\n" % (BASH, CLI, e)).encode())
        return 127
    sel = selectors.DefaultSelector()
    tails = {child.stdout: b"", child.stderr: b""}
    prefixes = {child.stdout: b"", child.stderr: b"E "}
    for stream in tails:
        sel.register(stream, selectors.EVENT_READ)
    while sel.get_map():
        for key, _events in sel.select():
            stream = key.fileobj
            chunk = os.read(stream.fileno(), 65536)
            if not chunk:
                if tails[stream]:
                    sock.sendall(prefixes[stream] + tails[stream] + b"\n")
                    tails[stream] = b""
                sel.unregister(stream)
                stream.close()
                continue
            pending = tails[stream] + chunk
            lines = pending.split(b"\n")
            tails[stream] = lines.pop()
            for line in lines:
                sock.sendall(prefixes[stream] + line + b"\n")
                if stream is child.stderr or line.startswith(b"RHIZO_FAIL"):
                    log("child: %s" % line.decode("utf-8", "replace")[:300])
    return child.wait()


def main():
    """serve a request from the socket"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=0)
    cred = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", cred)
    try:
        with open("/proc/self/attr/current") as f:
            domain = f.read().strip("\0\n")
    except OSError as e:
        domain = "unreadable (%s)" % e
    log("peer uid=%d gid=%d pid=%d domain=%s" % (uid, gid, pid, domain))

    fds = []
    try:
        line = read_request(sock, fds)
        try:
            request = json.loads(line.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as e:
            raise Refused("request line is not JSON: %s" % e)
        inst_id = request_instance(request) if isinstance(request, dict) else 0
        argv = build_argv(request, fds, inst_id)
        token = request_activation_token(request)
    except Refused as e:
        log("refused: %s" % e)
        sock.sendall(("RHIZO_FAIL %s\nRHIZO_BROKER_RC=2\n" % e).encode())
        return 0
    finally:
        close_all(fds)

    log("running %s %s for instance %d" % (CLI, " ".join(argv), inst_id))
    rc = relay(sock, argv, inst_id, token)
    log("%s %s exited %d" % (CLI, " ".join(argv[:2]), rc))
    sock.sendall(("RHIZO_BROKER_RC=%d\n" % rc).encode())
    return 0


if __name__ == "__main__":
    sys.exit(main())
