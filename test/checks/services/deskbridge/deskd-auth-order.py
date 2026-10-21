#!/usr/bin/env python3
import json
import os
import socket
import sys
import time

from desk_hello import android_hello, proof, send

TOKEN = "checktoken"
HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))


def forged_auth(sock):
    """send a hello with a wrong-token proof"""
    stream = sock.makefile("rwb")
    nonce = os.urandom(16).hex()
    send(stream, {"t": "hello", "nonce": nonce})
    challenge = json.loads(stream.readline())
    send(stream, {"t": "auth", "proof": proof("wrong-token-guess", "android", nonce, challenge["nonce"])})
    return stream


def ping(stream):
    """send a ping and return whether the reply is a pong"""
    stream.write(json.dumps({"t": "ping"}).encode() + b"\n")
    stream.flush()
    reply = stream.readline()
    return reply and json.loads(reply).get("t") == "pong"


def main():
    """run the auth order checks"""
    port = int(sys.argv[1])

    android_a = socket.create_connection(("127.0.0.1", port), timeout=5)
    stream_a, hello_a = android_hello(android_a, TOKEN)
    if not hello_a or hello_a.get("t") != "hello_ok":
        print("check-deskd-auth-order: android A's hello was refused: %r" % hello_a)
        return 1
    if not ping(stream_a):
        print("check-deskd-auth-order: android A cannot ping right after authenticating")
        return 1

    intruder = socket.create_connection(("127.0.0.1", port), timeout=5)
    time.sleep(0.5)
    if not ping(stream_a):
        print("check-deskd-auth-order: android A was dropped by a connection that "
              "never even sent a byte")
        return 1
    print("check-deskd-auth-order: a bare connection with no hello did not touch android A")

    stream_i = forged_auth(intruder)
    time.sleep(0.5)
    if not ping(stream_a):
        print("check-deskd-auth-order: android A was dropped by a connection that "
              "sent a WRONG proof")
        return 1
    if stream_i.readline():
        print("check-deskd-auth-order: a wrong proof got an answer instead of a closed connection")
        return 1
    print("check-deskd-auth-order: a wrong-proof hello did not touch android A and was refused")

    legacy = socket.create_connection(("127.0.0.1", port), timeout=5)
    stream_l = legacy.makefile("rwb")
    send(stream_l, {"t": "hello", "token": TOKEN})
    if stream_l.readline():
        print("check-deskd-auth-order: a hello carrying the token and no nonce was answered")
        return 1
    print("check-deskd-auth-order: a hello carrying the token and no nonce was refused")

    right = socket.create_connection(("127.0.0.1", port), timeout=5)
    stream_r, hello_r = android_hello(right, TOKEN)
    if not hello_r or hello_r.get("t") != "hello_ok":
        print("check-deskd-auth-order: a correct-token hello was refused: %r" % hello_r)
        return 1
    time.sleep(0.5)
    android_a.settimeout(2)
    data = android_a.recv(4096)
    if data:
        print("check-deskd-auth-order: android A is still receiving data (%r) after a "
              "correctly-authenticated newcomer connected" % data)
        return 1
    print("check-deskd-auth-order: a correctly-authenticated newcomer took over from "
          "android A, and only after proving the token")

    with open(DESKD_PATH) as f:
        src = f.read()
    if "hmac.compare_digest" not in src:
        print("check-deskd-auth-order: the proof compare is not hmac.compare_digest "
              "(a non-constant-time compare leaks how much of a guess was right)")
        return 1
    print("check-deskd-auth-order: the proof compare is hmac.compare_digest")

    return 0


if __name__ == "__main__":
    sys.exit(main())
