#!/usr/bin/env python3

import base64
import json
import socket
import struct
import sys
import time
import zlib

from desk_hello import android_hello


def png(width, height, rgb):
    """return a minimal true-color PNG"""
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(tag, data):
        """return a PNG chunk of a tag and data"""
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


def main():
    """send a notification and check the record"""
    port, work, selftest = int(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
    icon = png(4, 4, [17, 200, 99])
    title = "Rhizo äö \U0001f600"
    body_text = "notification-body-nonce"

    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    stream, hello = android_hello(sock, "checktoken")
    if not hello or hello.get("t") != "hello_ok":
        print("check-deskd-notify: the bridge refused the hello: %r" % hello)
        return 1

    stream.write(json.dumps({
        "t": "notify", "key": "k1", "pkg": "com.example.poster",
        "title": title, "body": body_text,
        "icon_b64": base64.b64encode(icon).decode(),
    }).encode() + b"\n")
    stream.flush()

    deadline = time.monotonic() + 10
    records = []
    while time.monotonic() < deadline:
        try:
            with open(work + "/notif.jsonl") as f:
                records = [json.loads(line) for line in f if line.strip()]
        except FileNotFoundError:
            records = []
        if records:
            break
        time.sleep(0.2)

    if len(records) != 1:
        print("check-deskd-notify: the sink recorded %d notifications, wanted 1" % len(records))
        return 1
    rec = records[0]

    if selftest:
        icon = icon[:-1] + bytes([icon[-1] ^ 0xFF])

    problems = []
    if rec.get("summary") != title:
        problems.append("summary %r, sent %r" % (rec.get("summary"), title))
    if rec.get("body") != body_text:
        problems.append("body %r, sent %r" % (rec.get("body"), body_text))
    if "default" not in (rec.get("actions") or []):
        problems.append("actions %r carry no 'default'"
                        % (rec.get("actions"),))
    path = (rec.get("hints") or {}).get("image-path")
    if not path:
        problems.append("no image-path hint")
    else:
        with open(path, "rb") as f:
            got = f.read()
        if got != icon:
            problems.append("the icon on the desktop side is %d bytes and differs from the %d sent"
                            % (len(got), len(icon)))

    if problems:
        for p in problems:
            print("check-deskd-notify: " + p)
        return 1
    print("check-deskd-notify: title, body, default action and icon bytes all crossed intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
