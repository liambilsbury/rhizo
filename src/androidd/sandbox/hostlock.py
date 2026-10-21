import fcntl
import os
import time

from sandbox.core import HOST_LOCK_FILE
from sandbox.selinux_ns import ANDROID_ENFORCE_FILE, MODE_FILE, VERDICT_FILE

ENFORCE_NODE = "/sys/fs/selinux/enforce"
MODE_UNREADABLE_VERDICT = "refused:selinux-mode-unreadable"


class ModeUnreadable(Exception):
    """Unreadable or garbled SELinux mode record"""


def acquire_host_lock():
    """lock HOST_LOCK_FILE and return the fd"""
    fd = os.open(HOST_LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def release_host_lock(fd):
    """unlock and close the lock fd"""
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def recorded_mode(mode_file=MODE_FILE):
    """return the recorded SELinux mode or raise ModeUnreadable"""
    try:
        with open(mode_file) as f:
            mode = f.read().rstrip("\n")
    except OSError as e:
        raise ModeUnreadable(f"{mode_file}: {e}") from e
    if mode not in ("host", "namespace"):
        raise ModeUnreadable(f"{mode_file} reads {mode!r}")
    return mode


def android_enforce_state(mode_file=MODE_FILE, state_file=ANDROID_ENFORCE_FILE, host_node=ENFORCE_NODE):
    """return Android's enforce state, empty when unknown"""
    try:
        return open(state_file if recorded_mode(mode_file) == "namespace" else host_node).read().strip()
    except (OSError, ModeUnreadable):
        return ""


def selinuxns_verdict(mode_file=MODE_FILE, verdict_file=VERDICT_FILE):
    """return this start's SELinux namespace verdict"""
    try:
        mode = recorded_mode(mode_file)
    except ModeUnreadable:
        return MODE_UNREADABLE_VERDICT
    if mode != "namespace":
        return ""
    try:
        return open(verdict_file).read().strip()
    except OSError:
        return ""


def is_final_verdict(verdict):
    """return whether verdict is final"""
    return verdict in ("enforced", "permissive", "stopped") or verdict.startswith("refused:")


def wait_for_enforce(deadline_s=60):
    """wait for Android's enforce state to read 1 or a final verdict"""
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        if android_enforce_state() == "1":
            return "enforced"
        verdict = selinuxns_verdict()
        if is_final_verdict(verdict):
            return verdict
        time.sleep(0.25)
    return ""


def release_when_ready(fd, supervisor_alive, log=lambda _m: None, deadline_s=60):
    """release the host lock"""
    outcome = wait_for_enforce(deadline_s)
    if outcome and outcome != "enforced":
        os.close(fd)
        log(f"host lock released (Android's start {outcome}, no supervisor wait)")
        return
    ok_enforce = outcome == "enforced"
    if not ok_enforce:
        log(f"host lock releaser: enforce=1 not observed within {deadline_s}s -- releasing anyway")
    deadline = time.time() + deadline_s
    ok_sup = supervisor_alive()
    while not ok_sup and time.time() < deadline:
        time.sleep(0.25)
        ok_sup = supervisor_alive()
    if not ok_sup:
        log(f"host lock releaser: supervisor never recorded itself within {deadline_s}s -- releasing anyway")
    os.close(fd)
    log(f"host lock released (enforce_seen={ok_enforce} supervisor_seen={ok_sup})")
