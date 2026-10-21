#!/usr/bin/env python3
import fcntl
import importlib.util
import os
import socket
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
ENV = os.path.join(ROOT, "src", "androidd", "sandbox", "core.py")
HOSTOPS = os.path.join(ROOT, "src", "install", "prepare", "hostops.py")


def load(path, name):
    """return a module loaded from a file"""
    for d in (os.path.dirname(ENV), os.path.dirname(HOSTOPS)):
        if d not in sys.path:
            sys.path.insert(0, d)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def record(n):
    """return kernel log record n in /dev/kmsg's format"""
    return f"6,{n},{n * 1000},-;message {n}\n".encode()


def follow_findings(env, backlog_of):
    """return the findings for a fake ring"""
    ring, live = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    for n in range(1, 16):
        live.send(record(n))
    real_open = os.open

    def fake_open(path, flags, *args):
        """return a fake ring fd"""
        if path != "/fake/kmsg":
            return real_open(path, flags, *args)
        fd = os.dup(ring.fileno())
        if flags & os.O_NONBLOCK:
            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
        return fd

    got = []
    os.open = fake_open
    try:
        kwargs = backlog_of()
        gen = env.kmsg_records(follow=True, path="/fake/kmsg", **kwargs)
        try:
            for _ in range(10):
                got.append(next(gen)[1])
        except StopIteration:
            pass
        except OSError as e:
            return [f"the follower fails on the ring: {e}"]
        live.send(record(16))
        live.close()
        got += [m for _u, m in gen]
    finally:
        os.open = real_open
        ring.close()
    want = [f"message {n}" for n in range(6, 17)]
    if got != want:
        return [f"the follower yields {got}, not the last 10 records then the new one ({want[0]}..{want[-1]})"]
    return []


def check(env_path=ENV, hostops_path=HOSTOPS, tag=""):
    """return every finding"""
    env = load(env_path, f"_kmsg_env{tag}")
    hostops = load(hostops_path, f"_kmsg_hostops{tag}")
    seen = {}

    def recorder(**kwargs):
        """record kmsg_records' arguments"""
        seen.update(kwargs)
        return iter(())

    saved = hostops.core.kmsg_records
    hostops.core.kmsg_records = recorder
    try:
        hostops.kmsg_follow()
    finally:
        hostops.core.kmsg_records = saved
    bad = []
    if seen.get("follow") is not True or seen.get("backlog") != 10 or seen.get("from_end"):
        bad.append(f"hostops kmsg-follow reads kmsg_records({seen}), not follow=True with a backlog of 10")
    try:
        bad += follow_findings(env, lambda: {"backlog": 10})
    except TypeError as e:
        bad.append(f"kmsg_records takes no backlog: {e}")
    return bad


def selftest():
    """flag each mutant and pass the real sources"""
    env_src, hostops_src = open(ENV).read(), open(HOSTOPS).read()
    cases = (
        ("a follower from the ring's end", "hostops", "KMSG_FOLLOW_BACKLOG = 10\n", "KMSG_FOLLOW_BACKLOG = 0\n",
         "not follow=True with a backlog of 10"),
        ("a backlog that replays the whole ring", "env",
         "        ring = None if backlog is None else collections.deque(maxlen=backlog)\n",
         "        ring = None\n", "not the last 10 records"),
    )
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "androidd", "sandbox"))
        os.makedirs(os.path.join(tmp, "install", "prepare"))
        for n, (label, which, old, new, needle) in enumerate(cases):
            srcs = {"env": env_src, "hostops": hostops_src}
            if srcs[which].count(old) != 1:
                return [f"the {label} mutant found {srcs[which].count(old)} anchors"]
            srcs[which] = srcs[which].replace(old, new)
            env_path = os.path.join(tmp, "androidd", "sandbox", "core.py")
            hostops_path = os.path.join(tmp, "install", "prepare", "hostops.py")
            for path, key in ((env_path, "env"), (hostops_path, "hostops")):
                with open(path, "w") as f:
                    f.write(srcs[key])
            got = check(env_path, hostops_path, f"_m{n}")
            if not any(needle in g for g in got):
                bad.append(f"the {label} mutant was not flagged: {got}")
    real = check(tag="_real")
    if real:
        bad.append(f"the real sources have findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check()
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
