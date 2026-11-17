#!/usr/bin/env python3
"""HCI user-channel fd server for Android's Bluetooth HAL"""
import argparse
import array
import ctypes
import errno
import os
import re
import signal
import socket
import struct
import sys
import time

AF_BLUETOOTH = 31
BTPROTO_HCI = 1
HCI_CHANNEL_USER = 1
HCI_CHANNEL_CONTROL = 3
MGMT_INDEX_NONE = 0xFFFF
MGMT_OP_READ_INDEX_LIST = 0x0003
MGMT_OP_READ_INFO = 0x0004
MGMT_OP_SET_POWERED = 0x0005
MGMT_EV_CMD_COMPLETE = 0x0001
MGMT_EV_CMD_STATUS = 0x0002
MGMT_EV_INDEX_ADDED = 0x0004
MGMT_SETTING_POWERED = 0x1
INDEX_RETURN_TIMEOUT_S = 10
POWER_ON_ATTEMPTS = 5
POWER_ON_RETRY_S = 2
AID_BLUETOOTH = 1002
SO_PEERPIDFD = 77
REFUSAL_LOG_S = 10
UID_MAX = 0xFFFFFFFE
SANDBOX_CHILD = re.compile(rb"(?:/rhizo(?:-[0-9]+)?|/system\.slice/androidd(?:@[0-9]+)?\.service/android)/.",
                           re.DOTALL)
LIBC = ctypes.CDLL(None, use_errno=True)
STATE = {"lent": False, "stopping": False, "refusal_logged": None, "refusals_unlogged": 0}


def log(msg):
    """print msg to stdout"""
    print(msg, flush=True)


def hci_socket(index, channel):
    """open an HCI socket bound to index on channel"""
    s = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW | socket.SOCK_CLOEXEC, BTPROTO_HCI)
    addr = struct.pack("<HHH", AF_BLUETOOTH, index, channel)
    if LIBC.bind(s.fileno(), addr, len(addr)) != 0:
        err = ctypes.get_errno()
        s.close()
        raise OSError(err, "failed to bind hci index %d channel %d (%s)" % (index, channel, os.strerror(err)))
    return s


def mgmt(op, index, params=b""):
    """write a mgmt command and return the reply parameters"""
    with hci_socket(MGMT_INDEX_NONE, HCI_CHANNEL_CONTROL) as s:
        s.settimeout(3)
        s.send(struct.pack("<HHH", op, index, len(params)) + params)
        while True:
            reply = s.recv(1024)
            event, event_index, length = struct.unpack_from("<HHH", reply)
            if event not in (MGMT_EV_CMD_COMPLETE, MGMT_EV_CMD_STATUS) or event_index != index:
                continue
            reply_op, status = struct.unpack_from("<HB", reply, 6)
            if reply_op != op:
                continue
            if status != 0:
                raise OSError("mgmt op 0x%04x on index %d failed with status %d" % (op, index, status))
            return reply[9:6 + length]


def first_index():
    """return the first index in the MGMT_OP_READ_INDEX_LIST reply, or None"""
    reply = mgmt(MGMT_OP_READ_INDEX_LIST, MGMT_INDEX_NONE)
    count = struct.unpack_from("<H", reply)[0]
    return struct.unpack_from("<H", reply, 2)[0] if count else None


def powered(index):
    """return whether the controller is powered"""
    current_settings = struct.unpack_from("<I", mgmt(MGMT_OP_READ_INFO, index), 13)[0]
    return bool(current_settings & MGMT_SETTING_POWERED)


def open_user_channel(index):
    """power index off and bind a user channel on index"""
    was_powered = powered(index)
    if was_powered:
        mgmt(MGMT_OP_SET_POWERED, index, b"\x00")
    try:
        return hci_socket(index, HCI_CHANNEL_USER), was_powered
    except OSError:
        if was_powered:
            mgmt(MGMT_OP_SET_POWERED, index, b"\x01")
        raise


def wait_index_added(events, index):
    """read mgmt events until MGMT_EV_INDEX_ADDED for index"""
    events.settimeout(INDEX_RETURN_TIMEOUT_S)
    while True:
        event, event_index, _ = struct.unpack_from("<HHH", events.recv(1024))
        if event == MGMT_EV_INDEX_ADDED and event_index == index:
            return


def restore_controller(events, index, was_powered):
    """wait for MGMT_EV_INDEX_ADDED and power index on if was_powered"""
    try:
        wait_index_added(events, index)
    except socket.timeout:
        log("no MGMT_EV_INDEX_ADDED for controller %d within %d s" % (index, INDEX_RETURN_TIMEOUT_S))
        return
    if not was_powered:
        return
    for attempt in range(1, POWER_ON_ATTEMPTS + 1):
        try:
            mgmt(MGMT_OP_SET_POWERED, index, b"\x01")
        except OSError as e:
            log("controller %d power-on attempt %d failed (%s)" % (index, attempt, e))
            time.sleep(POWER_ON_RETRY_S)
            continue
        if attempt > 1:
            log("controller %d powered on at attempt %d" % (index, attempt))
        return
    log("controller %d is still powered off after %d attempts" % (index, POWER_ON_ATTEMPTS))


def on_term(signum, frame):
    """exit unless STATE lent is True, else set STATE stopping"""
    if not STATE["lent"]:
        sys.exit(0)
    if not STATE["stopping"]:
        log("SIGTERM while the controller is lent to Android")
    STATE["stopping"] = True


def serve_connection(conn):
    """pass the controller to a HAL connection"""
    request = conn.recv(64)
    if request != b"open":
        log("recv returned %r, expected b'open'" % request)
        return
    index = first_index()
    if index is None:
        conn.send(b"fail no controller")
        log("MGMT_OP_READ_INDEX_LIST returned no controller")
        return
    try:
        user_channel, was_powered = open_user_channel(index)
    except OSError as e:
        conn.send(("fail %s" % e).encode()[:120])
        log("failed to open the user channel (%s)" % e)
        return
    with hci_socket(MGMT_INDEX_NONE, HCI_CHANNEL_CONTROL) as events:
        with user_channel:
            fds = array.array("i", [user_channel.fileno()])
            STATE["lent"] = True
            conn.sendmsg([b"ok"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)])
            log("passed controller %d to Android, was_powered=%s" % (index, "on" if was_powered else "off"))
            conn.recv(1)
        restore_controller(events, index, was_powered)
    STATE["lent"] = False
    log("controller %d returned to BlueZ" % index)


def cgroup_allowed(path, cgroup_root):
    """return whether path (bytes) is under cgroup_root, or strictly below a sandbox root if cgroup_root is None"""
    if not path.startswith(b"/") or b"/../" in path or b"/./" in path or path.endswith(b"/.."):
        return False
    if cgroup_root is not None:
        return cgroup_root == b"/" or path == cgroup_root or path.startswith(cgroup_root + b"/")
    return SANDBOX_CHILD.match(path) is not None


def read_cgroup(pid, proc="/proc"):
    """return the 0:: path of proc/pid/cgroup as bytes split on newline bytes, or None"""
    try:
        with open("%s/%d/cgroup" % (proc, pid), "rb") as f:
            data = f.read()
    except OSError:
        return None
    for line in data.split(b"\n"):
        if line.startswith(b"0::"):
            return line[3:]
    return None


def shown(path):
    """return repr(path) without the b'' quotes"""
    return repr(path)[2:-1]


def uid_arg(text):
    """return int(text) for ASCII decimal digits up to UID_MAX, else raise ArgumentTypeError"""
    if not text.isascii() or not text.isdigit() or int(text) > UID_MAX:
        raise argparse.ArgumentTypeError("%r is not a uid" % text)
    return int(text)


def pidfd_alive(pidfd):
    """return whether pidfd_send_signal(pidfd, 0) returns or raises an OSError other than ProcessLookupError"""
    try:
        signal.pidfd_send_signal(pidfd, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def peer_allowed(sock, uid, cgroup_root):
    """return whether the peer uid of sock is uid and the peer cgroup passes cgroup_allowed, and the refusal"""
    try:
        cred = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("iII"))
    except OSError as e:
        return False, "a peer with no SO_PEERCRED (%s)" % e.strerror
    pid, peer_uid, _ = struct.unpack("iII", cred)
    if peer_uid != uid:
        return False, "uid %d pid %d, uid is not %d (bluetooth)" % (peer_uid, pid, uid)
    pidfd = None
    try:
        pidfd = sock.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD)
    except OSError as e:
        if e.errno not in (errno.ENOPROTOOPT, errno.EINVAL):
            return False, "uid %d pid %d, getsockopt SO_PEERPIDFD failed (%s)" % (peer_uid, pid, e.strerror)
    cgroup = read_cgroup(pid)
    alive = True
    if pidfd is not None:
        try:
            alive = pidfd_alive(pidfd)
        finally:
            os.close(pidfd)
    if cgroup is None or not alive:
        return False, "uid %d pid %d, %s" % (peer_uid, pid, "failed to read /proc/<pid>/cgroup" if alive
                                             else "pidfd_send_signal failed with ESRCH")
    root = os.fsencode(cgroup_root) if isinstance(cgroup_root, str) else cgroup_root
    if not cgroup_allowed(cgroup, root):
        return False, "uid %d pid %d, cgroup '%s' is not below a sandbox root" % (peer_uid, pid, shown(cgroup))
    return True, ""


def log_refusal(why):
    """log a refused connection if REFUSAL_LOG_S passed since the last refusal line"""
    now = time.monotonic()
    if STATE["refusal_logged"] is not None and now - STATE["refusal_logged"] < REFUSAL_LOG_S:
        STATE["refusals_unlogged"] += 1
        return
    more = STATE["refusals_unlogged"]
    log("refused a connection from %s%s" %
        (why, " unlogged_refusals=%d" % more if more else ""))
    STATE["refusal_logged"] = now
    STATE["refusals_unlogged"] = 0


def serve(path, peer_uid, peer_cgroup):
    """accept HAL connections one at a time"""
    if os.path.lexists(path):
        os.unlink(path)
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET | socket.SOCK_CLOEXEC) as server:
        server.bind(path)
        if os.geteuid() == 0:
            os.chown(path, -1, AID_BLUETOOTH)
        os.chmod(path, 0o660)
        server.listen(1)
        log("listening on %s" % path)
        if peer_uid != AID_BLUETOOTH or peer_cgroup is not None:
            log("--peer-uid %d --peer-cgroup %s" %
                (peer_uid, peer_cgroup if peer_cgroup is not None else "unset"))
        else:
            log("peer uid=%d cgroup below /rhizo[-N] or androidd[@N].service/android" % AID_BLUETOOTH)
        while True:
            conn, _ = server.accept()
            with conn:
                try:
                    allowed, why = peer_allowed(conn, peer_uid, peer_cgroup)
                except Exception as e:
                    allowed, why = False, "a peer where peer_allowed raised %s" % type(e).__name__
                if allowed:
                    serve_connection(conn)
                else:
                    log_refusal(why)
            if STATE["stopping"]:
                return


def main(argv=None):
    """parse arguments and serve"""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--peer-uid", type=uid_arg, default=AID_BLUETOOTH)
    parser.add_argument("--peer-cgroup")
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, on_term)
    serve(args.socket, args.peer_uid, args.peer_cgroup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
