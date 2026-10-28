#!/usr/bin/env python3
import errno
import os
import shutil
import subprocess
import sys

USAGE = """Usage: inbox_stage.py <run_root> <name> <src> <label|-> [size]"""

DIR_FLAGS = os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
ATTR_CURRENT = os.environ.get("RHIZO_ATTR_CURRENT", "/proc/self/attr/current")
LAUNCHER3 = os.environ.get("RHIZO_LAUNCHER", os.path.join(os.path.dirname(os.path.abspath(__file__)), "launcher3.py"))


def step(what, e):
    """return the OSError e rewritten to name the step that failed"""
    return OSError(e.errno, "%s: %s" % (what, e.strerror)) if e.errno else OSError("%s: %s" % (what, e))


def stage(run_root, name, src, label, mode=0o644, size=None, sandbox_id=None):
    """copy src into android's inbox through fds refusing symlinks"""
    try:
        fd = os.open(run_root, DIR_FLAGS)
    except OSError as e:
        raise step("open %s" % run_root, e)
    try:
        for part in ("data", "rhizo_inbox"):
            try:
                nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                raise step("open %s under %s without following a link" % (part, run_root), e)
            os.close(fd)
            fd = nxt
        try:
            os.unlink(name, dir_fd=fd)
        except FileNotFoundError:
            pass
        try:
            out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=fd)
        except OSError as e:
            raise step("create %s in the inbox" % name, e)
        try:
            write_labeled(out, name, src, label, mode, size, sandbox_id)
        except BaseException as e:
            try:
                os.unlink(name, dir_fd=fd)
            except OSError as ue:
                if isinstance(e, OSError):
                    first = e.strerror if e.errno else str(e)
                    raise OSError(e.errno, "%s; and %s stays in the inbox: %s" % (first, name, ue)) from e
                e.add_note("%s stays in the inbox: %s" % (name, ue))
            raise
        finally:
            os.close(out)
    finally:
        os.close(fd)


def copy_exactly(f_in, f_out, size):
    """copy size bytes and fail when the source holds fewer or more"""
    left = size
    while left:
        chunk = f_in.read(min(left, 1 << 20))
        if not chunk:
            raise OSError("the source holds %d bytes, fewer than the %d checked" % (size - left, size))
        f_out.write(chunk)
        left -= len(chunk)
    if f_in.read(1):
        raise OSError("the source holds more than the %d bytes checked" % size)


def host_policy_loaded(attr=ATTR_CURRENT):
    """return whether the host loaded its SELinux policy"""
    try:
        with open(attr) as f:
            return ":" in f.read().strip("\0\n")
    except FileNotFoundError:
        return False
    except OSError as e:
        if e.errno != errno.EINVAL:
            raise
        return False


def label_fd(fd, label):
    """label fd and return the label it reads"""
    os.setxattr(fd, "security.selinux", label.encode() + b"\0")
    return os.getxattr(fd, "security.selinux").rstrip(b"\0").decode(errors="replace")


def label_in_android_policy(fd, label, run=subprocess.run, sandbox_id=None):
    """label fd in Android's policy namespace"""
    argv = [sys.executable, LAUNCHER3, "in-android-policy", "label-fd", str(fd), label]
    env = None if sandbox_id is None else dict(os.environ, RHIZO_SANDBOX_ID=str(sandbox_id))
    try:
        r = run(argv, pass_fds=(fd,), capture_output=True, text=True, timeout=120, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise OSError("in-android-policy: %s" % e)
    lines = r.stdout.strip().splitlines()
    if r.returncode != 0 or not lines:
        raise OSError("in-android-policy exited %d: %s" % (r.returncode, (r.stdout + r.stderr).strip()[-300:]))
    return lines[-1]


def write_labeled(out, name, src, label, mode, size=None, sandbox_id=None):
    """copy src into the open descriptor, then set its mode and label"""
    try:
        with open(src, "rb") as f_in, os.fdopen(os.dup(out), "wb") as f_out:
            if size is None:
                shutil.copyfileobj(f_in, f_out)
            else:
                copy_exactly(f_in, f_out, size)
        os.fchmod(out, mode)
    except OSError as e:
        raise step("copy %s to %s" % (src, name), e)
    if not label:
        return
    try:
        got = label_in_android_policy(out, label, sandbox_id=sandbox_id) if host_policy_loaded() else label_fd(out, label)
    except OSError as e:
        raise step("label %s %s" % (name, label), e)
    if got != label:
        raise OSError("%s reads %s after labeling it %s" % (name, got, label))


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        sys.exit(USAGE)
    try:
        stage(sys.argv[1], sys.argv[2], sys.argv[3], None if sys.argv[4] == "-" else sys.argv[4],
              size=int(sys.argv[5]) if len(sys.argv) == 6 else None)
    except OSError as e:
        sys.exit("cannot stage %s in the inbox: %s" % (sys.argv[2], e))
