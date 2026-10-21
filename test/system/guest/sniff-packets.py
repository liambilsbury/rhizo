#!/usr/bin/env python3
import argparse
import ctypes
import os
import signal
import socket
import struct
import sys
import time

ETH_P_ALL = 0x0003
SO_RCVBUF = 8
SO_RCVBUFFORCE = 33
SOL_PACKET = 263
PACKET_STATISTICS = 6
PCAP_MAGIC = 0xA1B2C3D4
DLT_EN10MB = 1

_stop = False


def _on_signal(_sig, _frm):
    """set the stop flag when a signal arrives"""
    global _stop
    _stop = True


def read_ifindex(iface):
    """return the index of a network interface"""
    try:
        return socket.if_nametoindex(iface)
    except OSError:
        with open(f"/sys/class/net/{iface}/ifindex") as f:
            return int(f.read().strip())


def bind_by_index(sock, ifindex):
    """bind the packet socket to an interface index"""
    sll = struct.pack("HHiHBB8s", socket.AF_PACKET, socket.htons(ETH_P_ALL),
                      ifindex, 0, 0, 0, b"")
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    if libc.bind(sock.fileno(), ctypes.c_char_p(sll), len(sll)) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"bind(sockaddr_ll ifindex={ifindex}): {os.strerror(err)}")


def main():
    """capture an interface to a pcap file"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--snaplen", type=int, default=262144)
    ap.add_argument("--seconds", type=float, default=0.0)
    a = ap.parse_args()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    try:
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    except OSError as e:
        print(f"SNIFF_FAILED socket: {e}", file=sys.stderr, flush=True)
        return 1
    try:
        try:
            s.setsockopt(socket.SOL_SOCKET, SO_RCVBUFFORCE, 64 * 1024 * 1024)
        except OSError:
            s.setsockopt(socket.SOL_SOCKET, SO_RCVBUF, 32 * 1024 * 1024)
        ifindex = read_ifindex(a.iface)
        bind_by_index(s, ifindex)
    except OSError as e:
        print(f"SNIFF_FAILED bind {a.iface}: {e}", file=sys.stderr, flush=True)
        return 1

    f = open(a.out, "wb", buffering=1 << 20)
    f.write(struct.pack("<IHHiIII", PCAP_MAGIC, 2, 4, 0, 0, a.snaplen, DLT_EN10MB))
    f.flush()

    print(f"SNIFF_LISTENING iface={a.iface} ifindex={ifindex} out={a.out}",
          file=sys.stderr, flush=True)

    s.settimeout(0.25)
    n = nbytes = 0
    deadline = time.time() + a.seconds if a.seconds > 0 else None
    while not _stop:
        if deadline is not None and time.time() >= deadline:
            break
        try:
            data = s.recv(a.snaplen)
        except socket.timeout:
            continue
        except OSError as e:
            print(f"SNIFF_RECV_ERROR {e}", file=sys.stderr, flush=True)
            break
        now = time.time()
        f.write(struct.pack("<IIII", int(now), int((now % 1) * 1_000_000),
                            len(data), len(data)))
        f.write(data)
        n += 1
        nbytes += len(data)

    f.close()
    drops = -1
    try:
        st = s.getsockopt(SOL_PACKET, PACKET_STATISTICS, 8)
        drops = struct.unpack("II", st)[1]
    except OSError:
        pass
    s.close()
    print(f"SNIFF_STOPPED iface={a.iface} packets={n} bytes={nbytes} drops={drops}",
          file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
