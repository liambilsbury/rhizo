#!/usr/bin/env python3
"""pass the host's bluetooth controller to android's bluetooth HAL as an HCI user-channel fd"""
import argparse
import array
import ctypes
import os
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
LIBC = ctypes.CDLL(None, use_errno=True)
STATE = {"lent": False, "stopping": False}


def log(msg):
    """print a line to the log"""
    print("rhizo-btd: " + msg, flush=True)


def hci_socket(index, channel):
    """open an HCI socket bound to index on channel"""
    s = socket.socket(AF_BLUETOOTH, socket.SOCK_RAW | socket.SOCK_CLOEXEC, BTPROTO_HCI)
    addr = struct.pack("<HHH", AF_BLUETOOTH, index, channel)
    if LIBC.bind(s.fileno(), addr, len(addr)) != 0:
        err = ctypes.get_errno()
        s.close()
        raise OSError(err, "bind hci index %d channel %d: %s" % (index, channel, os.strerror(err)))
    return s


def mgmt(op, index, params=b""):
    """send a mgmt command and return its reply parameters"""
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
                raise OSError("mgmt op 0x%04x on index %d: status %d" % (op, index, status))
            return reply[9:6 + length]


def first_index():
    """return the first controller index mgmt lists, or None"""
    reply = mgmt(MGMT_OP_READ_INDEX_LIST, MGMT_INDEX_NONE)
    count = struct.unpack_from("<H", reply)[0]
    return struct.unpack_from("<H", reply, 2)[0] if count else None


def powered(index):
    """return whether the controller is powered"""
    current_settings = struct.unpack_from("<I", mgmt(MGMT_OP_READ_INFO, index), 13)[0]
    return bool(current_settings & MGMT_SETTING_POWERED)


def open_user_channel(index):
    """power the controller off and bind a user channel on it"""
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
    """read mgmt events until the index is added"""
    events.settimeout(INDEX_RETURN_TIMEOUT_S)
    while True:
        event, event_index, _ = struct.unpack_from("<HHH", events.recv(1024))
        if event == MGMT_EV_INDEX_ADDED and event_index == index:
            return


def restore_controller(events, index, was_powered):
    """wait for the index to return and restore its power"""
    try:
        wait_index_added(events, index)
    except socket.timeout:
        log("controller %d not added back to mgmt within %d s" % (index, INDEX_RETURN_TIMEOUT_S))
        return
    if not was_powered:
        return
    for attempt in range(1, POWER_ON_ATTEMPTS + 1):
        try:
            mgmt(MGMT_OP_SET_POWERED, index, b"\x01")
        except OSError as e:
            log("controller %d power-on attempt %d failed: %s" % (index, attempt, e))
            time.sleep(POWER_ON_RETRY_S)
            continue
        if attempt > 1:
            log("controller %d powered on at attempt %d" % (index, attempt))
        return
    log("controller %d left powered off after %d attempts" % (index, POWER_ON_ATTEMPTS))


def on_term(signum, frame):
    """exit at once, or after the lent controller is back with BlueZ"""
    if not STATE["lent"]:
        sys.exit(0)
    if not STATE["stopping"]:
        log("stop requested while Android holds the controller: returning it to BlueZ first")
    STATE["stopping"] = True


def serve_connection(conn):
    """pass the controller to a HAL connection"""
    request = conn.recv(64)
    if request != b"open":
        log("unexpected request %r" % request)
        return
    index = first_index()
    if index is None:
        conn.send(b"fail no controller")
        log("open refused: no controller")
        return
    try:
        user_channel, was_powered = open_user_channel(index)
    except OSError as e:
        conn.send(("fail %s" % e).encode()[:120])
        log("open refused: %s" % e)
        return
    with hci_socket(MGMT_INDEX_NONE, HCI_CHANNEL_CONTROL) as events:
        with user_channel:
            fds = array.array("i", [user_channel.fileno()])
            STATE["lent"] = True
            conn.sendmsg([b"ok"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)])
            log("controller %d passed to Android, powered %s before" % (index, "on" if was_powered else "off"))
            conn.recv(1)
        restore_controller(events, index, was_powered)
    STATE["lent"] = False
    log("controller %d returned to BlueZ" % index)


def serve(path):
    """accept HAL connections one at a time"""
    if os.path.lexists(path):
        os.unlink(path)
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET | socket.SOCK_CLOEXEC) as server:
        server.bind(path)
        os.chmod(path, 0o666)
        server.listen(1)
        log("listening on %s" % path)
        while True:
            conn, _ = server.accept()
            with conn:
                serve_connection(conn)
            if STATE["stopping"]:
                return


def main(argv=None):
    """parse arguments and serve"""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", required=True)
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, on_term)
    serve(args.socket)
    return 0


if __name__ == "__main__":
    sys.exit(main())
