#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROTATOR = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "capture-kernel-log.sh")


def write_blocking_dmesg(path):
    """write a dmesg stub that prints lines forever"""
    with open(path, "w") as f:
        f.write("#!/bin/sh\nwhile :; do echo \"line $$\"; sleep 0.05; done\n")
    os.chmod(path, 0o755)


def alive_stub_pids(stub_path):
    """return the pids with stub_path in the cmdline"""
    found = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % d, "rb") as f:
                cmdline = f.read()
        except OSError:
            continue
        if stub_path.encode() in cmdline:
            found.append(int(d))
    return found


def kill_tree(pid):
    """kill a process, ignoring errors"""
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


def main():
    """run the singleton check"""
    bad = []
    if not os.path.exists(ROTATOR):
        print("FAIL: %s not found" % ROTATOR)
        return 1

    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "rhizo-avc.log")
        stub = os.path.join(d, "dmesg")
        write_blocking_dmesg(stub)
        env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])

        first = subprocess.Popen(["/bin/sh", ROTATOR, log], env=env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 5
        while not alive_stub_pids(stub) and time.time() < deadline:
            time.sleep(0.05)
        if not alive_stub_pids(stub):
            bad.append("the first invocation never started its dmesg stub")

        second = subprocess.Popen(["/bin/sh", ROTATOR, log], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            rc = second.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bad.append("a second invocation against the same log is still running 5s later")
            kill_tree(second.pid)
            second.wait(timeout=5)
        else:
            if rc != 0:
                bad.append("a second invocation against the same log exited %d, not 0" % rc)

        time.sleep(0.3)
        stubs = alive_stub_pids(stub)
        if len(stubs) != 1:
            bad.append("%d dmesg stub process(es) alive after a second start, want exactly 1 (%r)"
                      % (len(stubs), stubs))

        if first.poll() is not None:
            bad.append("the first invocation's own shell exited")

        kill_tree(first.pid)
        for p in alive_stub_pids(stub):
            kill_tree(p)
        try:
            first.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bad.append("the first invocation did not exit after SIGKILL")

    for b in bad:
        print("FAIL: %s" % b)
    if not bad:
        print("check-avc-capture-singleton: a second rhizo-avc-capture.sh against the same log "
              "exits immediately, and exactly one dmesg+sh pair ever runs")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
