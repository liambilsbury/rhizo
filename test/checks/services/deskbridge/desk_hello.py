import hashlib
import hmac
import json
import os


def proof(token, role, android_nonce, host_nonce):
    """return the proof of a token for a role and two nonces"""
    msg = ("rhizo-desk %s\n%s\n%s" % (role, android_nonce, host_nonce)).encode("ascii")
    return hmac.new(token.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def send(stream, obj):
    """write an object as a line of JSON and flush"""
    stream.write(json.dumps(obj).encode() + b"\n")
    stream.flush()


def android_hello(sock, token):
    """run the hello for RhizoDesktop"""
    stream = sock.makefile("rwb")
    android_nonce = os.urandom(16).hex()
    send(stream, {"t": "hello", "nonce": android_nonce})
    line = stream.readline()
    if not line:
        return stream, None
    challenge = json.loads(line)
    if challenge.get("t") != "challenge" or challenge.get("proof") != proof(
            token, "host", android_nonce, challenge.get("nonce", "")):
        return stream, {"t": "host-unproven", "line": challenge}
    send(stream, {"t": "auth", "proof": proof(token, "android", android_nonce, challenge["nonce"])})
    line = stream.readline()
    return stream, (json.loads(line) if line else None)
