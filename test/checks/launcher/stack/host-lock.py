#!/usr/bin/env python3
import fcntl
import functools
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

from sandbox import hostlock  # noqa: E402

REAL_STATE, REAL_VERDICT = hostlock.android_enforce_state, hostlock.selinuxns_verdict


def read_from(tmp, node, mode="host"):
    """point the Android state readers at a scratch mode file and node"""
    mode_file = os.path.join(tmp, "selinux-mode")
    if mode is not None:
        with open(mode_file, "w") as f:
            f.write(mode + "\n")
    other = os.path.join(tmp, "never-written")
    state_file, host_node = (node, other) if mode == "namespace" else (other, node)
    hostlock.android_enforce_state = functools.partial(
        REAL_STATE, mode_file=mode_file, state_file=state_file, host_node=host_node)
    hostlock.selinuxns_verdict = functools.partial(
        REAL_VERDICT, mode_file=mode_file, verdict_file=os.path.join(tmp, "verdict"))


def _acquire_and_record(lock_file, marker_acquired, hold_s, marker_released):
    """hold the host lock for hold_s seconds"""
    hostlock.HOST_LOCK_FILE = lock_file
    fd = hostlock.acquire_host_lock()
    with open(marker_acquired, "w") as f:
        f.write("%.6f" % time.time())
    time.sleep(hold_s)
    with open(marker_released, "w") as f:
        f.write("%.6f" % time.time())
    hostlock.release_host_lock(fd)
    os._exit(0)


def _wait_marker(path, deadline_s=10):
    """return the time written to a marker file, or None when it never appears"""
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        if os.path.exists(path):
            try:
                return float(open(path).read())
            except (OSError, ValueError):
                pass
        time.sleep(0.02)
    raise TimeoutError("marker %s never appeared" % path)


def test_second_racer_blocks_until_released(tmp):
    """check a second process waits for the lock"""
    lock_file = os.path.join(tmp, "host.lock")
    a_acquired, a_released = os.path.join(tmp, "a.acquired"), os.path.join(tmp, "a.released")
    owner = os.fork()
    if owner == 0:
        _acquire_and_record(lock_file, a_acquired, 0.4, a_released)
    _wait_marker(a_acquired)

    b_acquired = os.path.join(tmp, "b.acquired")
    racer = os.fork()
    if racer == 0:
        hostlock.HOST_LOCK_FILE = lock_file
        fd = hostlock.acquire_host_lock()
        with open(b_acquired, "w") as f:
            f.write("%.6f" % time.time())
        hostlock.release_host_lock(fd)
        os._exit(0)

    os.waitpid(owner, 0)
    os.waitpid(racer, 0)
    t_released = float(open(a_released).read())
    t_b_acquired = _wait_marker(b_acquired, deadline_s=1)
    assert t_b_acquired >= t_released, (
        "the racer acquired at %.6f, BEFORE the owner released at %.6f" % (t_b_acquired, t_released))


def test_wait_for_enforce_sees_the_flip(tmp, mode="host"):
    """check wait_for_enforce on a node flip"""
    node = os.path.join(tmp, "enforce")
    with open(node, "w") as f:
        f.write("0")
    read_from(tmp, node, mode)

    def _flip_soon():
        """write 1 to the node shortly after starting"""
        time.sleep(0.15)
        with open(node, "w") as f:
            f.write("1")

    flipper = os.fork()
    if flipper == 0:
        _flip_soon()
        os._exit(0)
    t0 = time.time()
    ok = hostlock.wait_for_enforce(deadline_s=5)
    elapsed = time.time() - t0
    os.waitpid(flipper, 0)
    assert ok, "wait_for_enforce did not see the flip to 1 within its deadline"
    assert elapsed < 5, "wait_for_enforce did not return promptly once enforce flipped (took %.2fs)" % elapsed


def test_wait_for_enforce_times_out(tmp):
    """check wait_for_enforce gives up at its deadline"""
    node = os.path.join(tmp, "enforce_never")
    with open(node, "w") as f:
        f.write("0")
    read_from(tmp, node)
    t0 = time.time()
    ok = hostlock.wait_for_enforce(deadline_s=0.3)
    elapsed = time.time() - t0
    assert not ok, "wait_for_enforce reported True against a node that never flipped"
    assert elapsed < 2, "wait_for_enforce ran well past its own deadline (%.2fs)" % elapsed


def test_wait_for_enforce_returns_on_final_verdicts(tmp):
    """check wait_for_enforce on each verdict and enforce state"""
    state_file = os.path.join(tmp, "android-enforce")
    verdict_file = os.path.join(tmp, "verdict")
    read_from(tmp, state_file, "namespace")
    for enforce, verdict, deadline_s, want in (
            ("0", "stopped", 5, "stopped"),
            ("0", "permissive", 5, "permissive"),
            ("0", "enforced", 5, "enforced"),
            ("1", "pending", 5, "enforced"),
            ("1", None, 5, "enforced"),
            ("0", "refused:x", 5, "refused:x"),
            ("0", "pending", 0.3, ""),
            ("0", "handed-off", 0.3, ""),
            ("0", None, 0.3, ""),
            (None, None, 0.3, "")):
        for path, value in ((state_file, enforce), (verdict_file, verdict)):
            if value is None:
                if os.path.exists(path):
                    os.unlink(path)
            else:
                with open(path, "w") as f:
                    f.write(value + "\n")
        got = hostlock.wait_for_enforce(deadline_s=deadline_s)
        assert got == want, ("wait_for_enforce with android-enforce=%r verdict=%r returned %r, want %r"
                             % (enforce, verdict, got, want))


def test_release_when_ready_releases_on_a_stopped_start(tmp):
    """check release_when_ready releases at once on stopped"""
    lock_file = os.path.join(tmp, "host4.lock")
    state_file = os.path.join(tmp, "android-enforce")
    with open(state_file, "w") as f:
        f.write("0\n")
    with open(os.path.join(tmp, "verdict"), "w") as f:
        f.write("stopped\n")
    read_from(tmp, state_file, "namespace")
    hostlock.HOST_LOCK_FILE = lock_file
    fd = hostlock.acquire_host_lock()
    polled, logged = [], []
    hostlock.release_when_ready(fd, lambda: polled.append(1) or False, logged.append, deadline_s=5)
    assert logged == ["host lock released (Android's start stopped, no supervisor wait)"] and not polled, (
        "release_when_ready on a stopped verdict logged %r and polled the supervisor %d times" % (logged, len(polled)))
    fd2 = os.open(lock_file, os.O_RDWR)
    try:
        fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise AssertionError("the lock was still held after release_when_ready returned on a stopped verdict")
    finally:
        os.close(fd2)


def test_release_when_ready_waits_for_both_signals(tmp):
    """check release_when_ready waits for both signals"""
    lock_file = os.path.join(tmp, "host2.lock")
    node = os.path.join(tmp, "enforce2")
    with open(node, "w") as f:
        f.write("0")
    read_from(tmp, node)
    hostlock.HOST_LOCK_FILE = lock_file
    fd = hostlock.acquire_host_lock()

    sup_marker = os.path.join(tmp, "supervisor_alive")

    def supervisor_alive():
        """return whether the supervisor marker exists"""
        return os.path.exists(sup_marker)

    logged = []

    def flip_enforce_then_supervisor():
        """write 1 to the node shortly after starting"""
        time.sleep(0.1)
        with open(node, "w") as f:
            f.write("1")

    flipper = os.fork()
    if flipper == 0:
        flip_enforce_then_supervisor()
        os._exit(0)

    releaser = os.fork()
    done_marker = os.path.join(tmp, "release_done")
    if releaser == 0:
        hostlock.release_when_ready(fd, supervisor_alive, logged.append, deadline_s=5)
        with open(done_marker, "w") as f:
            f.write("done")
        os._exit(0)
    os.close(fd)

    time.sleep(0.3)
    assert not os.path.exists(done_marker), (
        "release_when_ready returned before the supervisor predicate went "
        "true")
    with open(sup_marker, "w") as f:
        f.write("1")
    os.waitpid(flipper, 0)
    os.waitpid(releaser, 0)
    assert os.path.exists(done_marker), "release_when_ready never returned once both signals were true"
    t0 = time.time()
    fd2 = hostlock.acquire_host_lock()
    assert time.time() - t0 < 1, "the lock was still held after release_when_ready returned"
    hostlock.release_host_lock(fd2)


def test_release_when_ready_releases_on_timeout(tmp):
    """check release_when_ready releases at its deadline"""
    lock_file = os.path.join(tmp, "host3.lock")
    node = os.path.join(tmp, "enforce3")
    with open(node, "w") as f:
        f.write("0")
    read_from(tmp, node)
    hostlock.HOST_LOCK_FILE = lock_file
    fd = hostlock.acquire_host_lock()
    logged = []
    t0 = time.time()
    hostlock.release_when_ready(fd, lambda: False, logged.append, deadline_s=0.3)
    elapsed = time.time() - t0
    assert elapsed < 2, "release_when_ready did not honor its deadline (%.2fs)" % elapsed
    assert any("releasing anyway" in m for m in logged), (
        "no loud log on a timed-out release: %r" % logged)
    t0 = time.time()
    fd2 = hostlock.acquire_host_lock()
    assert time.time() - t0 < 1, "the lock was still held after a timed-out release_when_ready"
    hostlock.release_host_lock(fd2)


def selftest():
    """run every host lock test and print the count"""
    real_lock_file = hostlock.HOST_LOCK_FILE
    n = 0
    try:
        with tempfile.TemporaryDirectory() as tmp:
            test_second_racer_blocks_until_released(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_wait_for_enforce_sees_the_flip(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_wait_for_enforce_sees_the_flip(tmp, "namespace")
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_wait_for_enforce_times_out(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_wait_for_enforce_returns_on_final_verdicts(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_release_when_ready_releases_on_a_stopped_start(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_release_when_ready_waits_for_both_signals(tmp)
            n += 1
        with tempfile.TemporaryDirectory() as tmp:
            test_release_when_ready_releases_on_timeout(tmp)
            n += 1
    finally:
        hostlock.HOST_LOCK_FILE = real_lock_file
        hostlock.android_enforce_state, hostlock.selinuxns_verdict = REAL_STATE, REAL_VERDICT
    print("check-host-lock selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    print("check-host-lock: --selftest is the only mode")
    sys.exit(2)
