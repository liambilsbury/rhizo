#!/usr/bin/env python3
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nb_mdns  # noqa: E402

FAILURES = []


def fail(msg):
    """record a failure message"""
    FAILURES.append(msg)


def qname_bytes(name):
    """encode a dotted name as DNS labels"""
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def dns_header(qd=0, an=0, tid=0x1234, flags=0x0000):
    """build a DNS header with the given counts"""
    return struct.pack(">HHHHHH", tid, flags, qd, an, 0, 0)


def dns_query(name, qtype=12, qclass=1):
    """build a DNS query for a name"""
    return dns_header(qd=1) + qname_bytes(name) + struct.pack(">HH", qtype, qclass)


def recording_senders():
    """return sent payload lists and recording senders"""
    sent = {"veth": [], "uplink": []}
    senders = {side: (lambda payload, s=side: sent[s].append(payload)) for side in sent}
    return sent, senders


def test_relay_crosses_segments():
    """check that a message is relayed to the other segment"""
    seen = {}
    sent, senders = recording_senders()
    action, _reason = nb_mdns.relay_step(seen, 100.0, "veth", b"payload-a", senders)
    if action != "relay":
        fail(f"a new datagram from veth should relay, got {action!r}")
    if sent["uplink"] != [b"payload-a"]:
        fail(f"the datagram did not reach the uplink segment: {sent}")
    if sent["veth"]:
        fail(f"the datagram was relayed back onto the segment it arrived on: {sent}")


def test_dedupe_window():
    """check that a repeated message inside the window is dropped"""
    seen = {}
    _sent, senders = recording_senders()
    nb_mdns.relay_step(seen, 100.0, "veth", b"dup", senders)
    action, reason = nb_mdns.relay_step(seen, 100.3, "veth", b"dup", senders)
    if action != "drop" or reason != "loop":
        fail(f"a duplicate inside the window should drop as a loop, got {action}/{reason}")
    action, reason = nb_mdns.relay_step(seen, 101.5, "veth", b"dup", senders)
    if action != "relay":
        fail(f"a duplicate after the window should relay again, got {action}/{reason}")


def test_relay_no_peer_socket():
    """check that a message without a peer socket is dropped"""
    seen = {}
    action, reason = nb_mdns.relay_step(seen, 1.0, "veth", b"x", {})
    if action != "drop" or reason != "no_peer":
        fail(f"a side with no peer socket should drop as no_peer, got {action}/{reason}")


def test_expire_seen():
    """check that old seen entries expire"""
    seen = {b"a": 10.0, b"b": 10.9, b"c": 5.0}
    nb_mdns.expire_seen(seen, 11.0)
    if b"c" in seen:
        fail("expire_seen left an entry well past the window")
    if b"a" in seen:
        fail("expire_seen left an entry exactly at the window boundary")
    if b"b" not in seen:
        fail("expire_seen dropped an entry still inside the window")


def test_first_question_name():
    """check that the first question name is returned"""
    data = dns_query("_rhizotest._tcp.local", qtype=12)
    name = nb_mdns.first_dns_name(data)
    if name != "_rhizotest._tcp.local":
        fail(f"expected the first question name, got {name!r}")


def test_first_answer_name_when_no_questions():
    """check the first answer name with no questions"""
    body = qname_bytes("speaker.local") + struct.pack(">HHIH", 1, 1, 120, 4) + bytes(4)
    data = dns_header(qd=0, an=1) + body
    name = nb_mdns.first_dns_name(data)
    if name != "speaker.local":
        fail(f"expected the first answer name when there are no questions, got {name!r}")


def test_compression_pointer_decodes():
    """check that a compression pointer is followed"""
    prefix = b"\x00" * 12 + qname_bytes("foo.local")
    pointer_pos = len(prefix)
    buf = prefix + bytes([0xC0, 12])
    name, next_pos = nb_mdns.dns_name(buf, pointer_pos)
    if name != "foo.local":
        fail(f"a compression pointer did not resolve to the pointed-at name, got {name!r}")
    if next_pos != pointer_pos + 2:
        fail(f"a compressed name's next_pos should sit right after the pointer, got {next_pos}")


def test_dns_name_rejects_truncated_label():
    """check that a truncated label is refused"""
    name, pos = nb_mdns.dns_name(bytes([5]) + b"ab", 0)
    if name is not None or pos is not None:
        fail(f"a truncated label was decoded instead of refused: {(name, pos)}")


def test_malformed_name_yields_dash():
    """check that a malformed name logs as a dash"""
    broken = dns_header(qd=1) + bytes([5]) + b"ab"
    if nb_mdns.first_dns_name(broken) is not None:
        fail("a malformed name was decoded instead of refused")
    if nb_mdns.qname_or_dash(broken) != "-":
        fail("a malformed name did not fall back to '-'")


def test_ipv6_needs_global_address(d):
    """check that IPv6 needs a global address"""
    link_local_only = os.path.join(d, "if_inet6_ll")
    with open(link_local_only, "w") as f:
        f.write("fe80000000000000021aa2fffe173d3c 02 40 20 80        eth0\n")
    if nb_mdns.has_global_ipv6("eth0", path=link_local_only):
        fail("a link-local-only interface was reported as having a global IPv6 address")

    with_global = os.path.join(d, "if_inet6_global")
    with open(with_global, "w") as f:
        f.write("fe80000000000000021aa2fffe173d3c 02 40 20 80        eth0\n")
        f.write("fd00000000000000000000000000abcd 02 40 00 80        eth0\n")
    if not nb_mdns.has_global_ipv6("eth0", path=with_global):
        fail("an interface with a global-scope address was not detected")
    if nb_mdns.has_global_ipv6("ens3", path=with_global):
        fail("has_global_ipv6 matched an interface that was not in the fixture")


def test_ipv6_missing_file_is_false():
    """check a missing IPv6 address file"""
    if nb_mdns.has_global_ipv6("eth0", path="/nonexistent/rhizo-selftest/if_inet6"):
        fail("a missing if_inet6 file should read as no global address, not True")


def test_is_valid_message_accepts_well_formed():
    """check that a well-formed message is accepted"""
    if not hasattr(nb_mdns, "is_valid_message"):
        fail("mdns-validate: no is_valid_message()")
        return
    good = dns_query("_rhizotest._tcp.local", qtype=12)
    if not nb_mdns.is_valid_message(good):
        fail("mdns-validate: a well-formed query was rejected")


def test_is_valid_message_rejects_truncated():
    """check that a truncated message is rejected"""
    if not hasattr(nb_mdns, "is_valid_message"):
        return
    truncated = dns_header(qd=1) + bytes([5]) + b"ab"
    if nb_mdns.is_valid_message(truncated):
        fail("mdns-validate: a truncated question section was accepted as well-formed")


def test_is_valid_message_rejects_absurd_counts():
    """check that absurd record counts are rejected"""
    if not hasattr(nb_mdns, "is_valid_message"):
        return
    absurd = dns_header(qd=60000) + qname_bytes("x") + struct.pack(">HH", 12, 1)
    if nb_mdns.is_valid_message(absurd):
        fail("mdns-validate: a header claiming 60000 questions was accepted as well-formed")


def test_is_valid_message_rejects_empty():
    """check that an empty payload is rejected"""
    if not hasattr(nb_mdns, "is_valid_message"):
        return
    if nb_mdns.is_valid_message(b""):
        fail("mdns-validate: an empty payload was accepted as well-formed")


def test_rate_limiter():
    """check that the rate limiter drops packets over the limit"""
    if not hasattr(nb_mdns, "_RateLimiter"):
        fail("mdns-rate-limit: no _RateLimiter")
        return
    rl = nb_mdns._RateLimiter(3)
    allowed = [rl.allow(100.0) for _ in range(5)]
    if allowed != [True, True, True, False, False]:
        fail(f"rate-limit: a limit of 3/s allowed {allowed}, wanted 3 True then False")
    if not rl.allow(101.1):
        fail("rate-limit: a new window a second later was still refused")


def test_seen_size_cap():
    """test expire_seen against MAX_SEEN"""
    if not hasattr(nb_mdns, "MAX_SEEN"):
        fail("resource-bounds: no MAX_SEEN -- the mDNS dedupe table is unbounded")
        return
    seen = {}
    now = 1000.0
    for i in range(nb_mdns.MAX_SEEN + 50):
        seen[i.to_bytes(8, "big")] = now
    nb_mdns.expire_seen(seen, now)
    if len(seen) > nb_mdns.MAX_SEEN:
        fail(f"seen-cap: expire_seen left {len(seen)} entries, over MAX_SEEN={nb_mdns.MAX_SEEN}")


def run_all():
    """run every check and collect the failures"""
    FAILURES.clear()
    test_relay_crosses_segments()
    test_dedupe_window()
    test_relay_no_peer_socket()
    test_expire_seen()
    test_first_question_name()
    test_first_answer_name_when_no_questions()
    test_compression_pointer_decodes()
    test_dns_name_rejects_truncated_label()
    test_malformed_name_yields_dash()
    with tempfile.TemporaryDirectory() as d:
        test_ipv6_needs_global_address(d)
    test_ipv6_missing_file_is_false()
    test_is_valid_message_accepts_well_formed()
    test_is_valid_message_rejects_truncated()
    test_is_valid_message_rejects_absurd_counts()
    test_is_valid_message_rejects_empty()
    test_rate_limiter()
    test_seen_size_cap()
    return list(FAILURES)


def run_all_broken():
    """run the relay test with other_side replaced"""
    real_other_side = nb_mdns.other_side
    nb_mdns.other_side = lambda side: side
    try:
        FAILURES.clear()
        test_relay_crosses_segments()
        return list(FAILURES)
    finally:
        nb_mdns.other_side = real_other_side


def main():
    """run the mDNS checks"""
    selftest = "--selftest" in sys.argv
    if selftest:
        broken = run_all_broken()
        if not broken:
            print("FAIL: breaking other_side() did not make any assertion fail", file=sys.stderr)
            return 1
        print(f"selftest_mdns: selftest ok -- {len(broken)} assertion(s) "
              "caught the broken run")
        return 0

    problems = run_all()
    for msg in problems:
        print(f"FAIL: {msg}", file=sys.stderr)
    if problems:
        print("selftest_mdns: nb_mdns.py does not do what it claims to", file=sys.stderr)
        return 1
    print("selftest_mdns: all fixtures behaved correctly, all bad ones refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
