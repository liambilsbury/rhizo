#!/usr/bin/env python3
import os
import socket
import sys
import time

TRAILER_PREFIX = b"\x00RHIZO_PROBE_RC="
NO_TRAILER = "RHIZO_PROBE_NO_TRAILER: connection closed without a completion marker"
TIMED_OUT = "RHIZO_PROBE_TIMEOUT: no completion trailer before deadline"


def write_or_discard(stream, data):
    """write bytes to a stream or discard them"""
    try:
        stream.buffer.write(data)
        stream.buffer.flush()
    except BrokenPipeError:
        devnull = os.open(os.devnull, os.O_WRONLY)
        os.dup2(devnull, stream.fileno())
        os.close(devnull)


def say(line):
    """write a line to stderr"""
    write_or_discard(sys.stderr, line.encode() + b"\n")


def main() -> int:
    """send a command to rhizo-probed"""
    if len(sys.argv) < 4:
        say("usage: probe-client.py <sock> <timeout-s> <command...>")
        return 96
    sock_path, timeout_s = sys.argv[1], float(sys.argv[2])
    cmd = " ".join(sys.argv[3:])
    deadline = time.time() + timeout_s

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(max(0.5, deadline - time.time()))
        s.connect(sock_path)
    except OSError as e:
        say(f"RHIZO_PROBE_UNREACHABLE: {e}")
        return 97

    buf = b""
    try:
        try:
            s.sendall(cmd.encode() + b"\n")
        except BrokenPipeError:
            say(NO_TRAILER)
            return 98
        try:
            s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                say(TIMED_OUT)
                write_or_discard(sys.stdout, buf)
                return 98
            s.settimeout(remaining)
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                say(TIMED_OUT)
                write_or_discard(sys.stdout, buf)
                return 98
            except ConnectionResetError:
                break
            if not chunk:
                break
            buf += chunk
            if TRAILER_PREFIX in buf:
                break
    finally:
        s.close()

    idx = buf.rfind(TRAILER_PREFIX)
    if idx < 0:
        write_or_discard(sys.stdout, buf)
        say(NO_TRAILER)
        return 98

    out = buf[:idx]
    rest = buf[idx + len(TRAILER_PREFIX):]
    end = rest.find(b"\x00")
    rc_str = rest[:end if end >= 0 else len(rest)]
    write_or_discard(sys.stdout, out)
    try:
        return int(rc_str)
    except ValueError:
        return 98


if __name__ == "__main__":
    sys.exit(main())
