#!/usr/bin/env python3

import argparse
import errno
import os
import re
import select
import sys
import time

ANCHOR_TEXT = "RHIZO_MARKER launch_start sandbox=%d"
DONE_TEXT = "RHIZO_MARKER sys.boot_completed=1 sandbox=%d"
LEGACY_ANCHOR = re.compile(rb"RHIZO_MARKER launch_start(?! sandbox=)")
LEGACY_DONE = re.compile(rb"RHIZO_MARKER sys\.boot_completed=1(?! sandbox=)")


def markers(instance):
    """return the launch and completion marker patterns"""
    anchor = re.compile(re.escape((ANCHOR_TEXT % instance).encode()) + rb"(?![0-9])")
    done = re.compile(re.escape((DONE_TEXT % instance).encode()) + rb"(?![0-9])")
    if instance == 0:
        return ([anchor, LEGACY_ANCHOR], [done, LEGACY_DONE])
    return ([anchor], [done])


class MarkerStream:
    """boot marker scan of kmsg records"""

    def __init__(self, anchors, dones):
        """store the anchor and done patterns"""
        self.anchors, self.dones = anchors, dones
        self.completed = False

    def feed(self, rec):
        """record whether a done marker follows the latest anchor in a kmsg record"""
        starts = [m.end() for pattern in self.anchors for m in pattern.finditer(rec)]
        if starts:
            self.anchored, self.completed = True, False
        if getattr(self, "anchored", False):
            at = max(starts) if starts else 0
            if any(pattern.search(rec, at) for pattern in self.dones):
                self.completed = True


def drain(read, stream):
    """read records and feed them to the stream"""
    while True:
        try:
            rec = read()
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return None
            if e.errno == errno.EPIPE:
                continue
            return e
        if not rec:
            return None
        stream.feed(rec)


def scan(buf, anchors, dones):
    """return whether the buffer holds a completed boot after its last anchor"""
    stream = MarkerStream(anchors, dones)
    stream.feed(buf)
    return stream.completed


def instance_arg(value):
    """parse an instance number from 0 to 99"""
    if not value.isdigit() or not 0 <= int(value) <= 99:
        raise argparse.ArgumentTypeError("must be 0-99, got %r" % value)
    return int(value)


def selftest():
    """check marker matching against built buffers"""
    zero_a, zero_d = markers(0)
    one_a, one_d = markers(1)
    two_a, two_d = markers(2)
    ten_a, ten_d = markers(10)

    def ring(*lines):
        """join lines into a byte buffer with newlines"""
        return b"".join(line + b"\n" for line in lines)

    own = ring(b"RHIZO_MARKER launch_start sandbox=2",
               b"RHIZO_MARKER sys.boot_completed=1 sandbox=2")
    sibling = ring(b"RHIZO_MARKER launch_start sandbox=0",
                   b"RHIZO_MARKER sys.boot_completed=1 sandbox=0")
    interleaved = ring(b"RHIZO_MARKER launch_start sandbox=2",
                       b"RHIZO_MARKER launch_start sandbox=0",
                       b"RHIZO_MARKER sys.boot_completed=1 sandbox=0")
    earlier = ring(b"RHIZO_MARKER launch_start sandbox=2",
                   b"RHIZO_MARKER sys.boot_completed=1 sandbox=2",
                   b"RHIZO_MARKER launch_start sandbox=2")
    two_digit = ring(b"RHIZO_MARKER launch_start sandbox=10",
                     b"RHIZO_MARKER sys.boot_completed=1 sandbox=10")
    legacy = ring(b"RHIZO_MARKER launch_start",
                  b"RHIZO_MARKER sys.boot_completed=1")

    cases = [
        ("instance 2's own pair is not read as its own boot",
         scan(own, two_a, two_d)),
        ("instance 0's pair satisfies a wait for instance 2 -- the id is not being read",
         not scan(sibling, two_a, two_d)),
        ("instance 0 loses its own pair once instance 2 has booted into the same ring",
         scan(sibling + own, zero_a, zero_d)),
        ("a sibling's completion after instance 2's launch reads as instance 2's",
         not scan(interleaved, two_a, two_d)),
        ("instance 0's completion is not seen in a ring holding both instances",
         scan(interleaved, zero_a, zero_d)),
        ("a completion that predates this run's own launch_start still answers True",
         not scan(earlier, two_a, two_d)),
        ("instance 10's pair satisfies a wait for instance 1 -- the id matches as a prefix",
         not scan(two_digit, one_a, one_d)),
        ("instance 10 cannot see its own pair",
         scan(two_digit, ten_a, ten_d)),
        ("an id-free pair from an older launcher no longer answers at instance 0",
         scan(legacy, zero_a, zero_d)),
        ("an id-free pair answers a wait for instance 2",
         not scan(legacy, two_a, two_d)),
        ("instance 2's launch is read as the legacy id-free form at instance 0",
         not scan(ring(b"RHIZO_MARKER launch_start sandbox=2"), zero_a, zero_d)),
    ] + marker_drift_cases() + stream_cases(two_a, two_d)

    bad = [finding for finding, ok in cases if not ok]
    for finding in bad:
        print("selftest FAIL: %s" % finding, file=sys.stderr)
    if bad:
        return 1
    print("await-boot-completed selftest: %d assertions passed" % len(cases))
    return 0


def stream_cases(anchors, dones):
    """return the test cases for the kmsg stream"""
    audit = b"6,1,1,-;audit: avc:  denied  { getattr } for pid=4115 comm=\"python3\" path=\"/sys/x\"\n"
    start = b"6,2,2,-;RHIZO_MARKER launch_start sandbox=2\n"
    done = b"5,3,3,-;RHIZO_MARKER sys.boot_completed=1 sandbox=2\n"

    class Ring:
        def __init__(self, records):
            """store the records and the read counters"""
            self.records, self.at, self.reads = list(records), 0, 0

        def read(self):
            """return the next record or raise EAGAIN when none are left"""
            if self.at >= len(self.records):
                raise BlockingIOError(errno.EAGAIN, "no record")
            self.at += 1
            self.reads += 1
            return self.records[self.at - 1]

    big = Ring([audit] * ((9 << 20) // len(audit)) + [start, done])
    big_stream = MarkerStream(anchors, dones)
    drain(big.read, big_stream)
    later = Ring([audit] * 50 + [start])
    later_stream = MarkerStream(anchors, dones)
    drain(later.read, later_stream)
    first = later_stream.completed
    later.records += [audit, done]
    later.reads = 0
    drain(later.read, later_stream)
    return [
        ("a completion past 9 MB of ring was not seen", big_stream.completed),
        ("an anchor with no completion read as a completed boot", not first),
        ("a completion logged after the drain was not seen", later_stream.completed),
        ("the wait read %d records, not the 2 logged since the drain -- a rescan" % later.reads,
         later.reads == 2),
    ]


def marker_drift_cases():
    """return the launcher marker check cases"""
    here = os.path.dirname(os.path.abspath(__file__))
    launcher = os.path.join(here, os.pardir, os.pardir, "androidd", "boot.py")
    try:
        with open(launcher) as f:
            src = f.read()
    except OSError as e:
        return [("cannot read %s (%s)" % (launcher, e), False)]
    cases = []
    for text in (ANCHOR_TEXT, DONE_TEXT):
        writes = '"' + text + '" % SANDBOX_ID'
        cases.append(("boot.py does not build %s" % writes, writes in src))
        anchored = 'rb"' + text.replace("sys.", "sys\\.") + '(?![0-9])" % _SANDBOX_ID'
        cases.append(("the host primer's anchor is not %s" % anchored, anchored in src))
    return cases


def main():
    """wait for the boot completion marker in kmsg"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, default=900.0)
    ap.add_argument("--instance", type=instance_arg,
                    default=os.environ.get("RHIZO_SANDBOX_ID", "0"))
    ap.add_argument("--kmsg", default=os.environ.get("RHIZO_KMSG", "/dev/kmsg"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.timeout <= 0:
        print(f"bad timeout value: {args.timeout}", file=sys.stderr)
        return 1
    anchors, dones = markers(args.instance)

    deadline = time.monotonic() + args.timeout
    try:
        fd = os.open(args.kmsg, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        print(f"open {args.kmsg}: {e}", file=sys.stderr)
        return 1

    stream = MarkerStream(anchors, dones)
    read = lambda: os.read(fd, 65536)  # noqa: E731
    try:
        err = drain(read, stream)
        if err is not None:
            print(f"read {args.kmsg}: {err}", file=sys.stderr)
            return 1
        if stream.completed:
            return 0

        poller = select.poll()
        poller.register(fd, select.POLLIN)
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                print("no completion marker for instance %d within %ss"
                      % (args.instance, args.timeout), file=sys.stderr)
                return 1
            if not poller.poll(left * 1000):
                continue
            err = drain(read, stream)
            if err is not None:
                print(f"read {args.kmsg}: {err}", file=sys.stderr)
                return 1
            if stream.completed:
                return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main())
