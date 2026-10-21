#!/usr/bin/env python3

import argparse
import os
import pwd
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD_DIR = os.path.dirname(HERE)
sys.path[:0] = [HERE, PAYLOAD_DIR, os.path.join(PAYLOAD_DIR, "..", "androidd")]
from sandbox import capabilities  # noqa: E402

AUTHORITY_URI = "content://com.rhizo.desktop.token"
TOKEN_RE = re.compile(r"^Result: Bundle\[\{token=([0-9a-f]{32})\}\]$", re.M)
STARTED_RE = re.compile(r"^Result: Bundle\[\{started=true\}\]$", re.M)
HEX_RUN_RE = re.compile(r"[0-9a-f]{32}")
ANDROID_PATH = "export PATH=/system/bin:/system/xbin:/vendor/bin; "
SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
RUN_ROOT = "/run/rhizo" if SANDBOX_ID == 0 else "/run/rhizo-%d" % SANDBOX_ID
BRIDGE_PKG = "com.rhizo.desktop"
BRIDGE_APK = "/system_ext/app/RhizoDesktop/RhizoDesktop.apk"
IME_ID = BRIDGE_PKG + "/.RhizoIme"
LISTENER = BRIDGE_PKG + "/" + BRIDGE_PKG + ".NotifListener"


def log(msg):
    """print a message"""
    print(msg, flush=True)


def redact(text):
    """replace 32-digit hex runs in the text"""
    return HEX_RUN_RE.sub("<redacted>", text)


def probe(args, cmd, timeout):
    """run a command over rhizo-probed"""
    try:
        proc = subprocess.run(
            ["/usr/bin/python3", args.probe_client, args.probe_sock, str(timeout), ANDROID_PATH + cmd],
            capture_output=True, text=True, timeout=timeout + 15)
    except subprocess.TimeoutExpired:
        return 98, "probe client outlived its own %ds deadline" % timeout
    return proc.returncode, proc.stdout + proc.stderr


def wait_for_unlock(args):
    """wait for user 0 to unlock"""
    deadline = time.monotonic() + args.boot_timeout
    last = "no answer"
    while time.monotonic() < deadline:
        rc, out = probe(args, "getprop sys.boot_completed; am get-started-user-state 0", 10)
        if rc == 0 and out.split() == ["1", "RUNNING_UNLOCKED"]:
            return True
        last = "rc=%d out=%r" % (rc, out.strip()[:160])
        time.sleep(1)
    log("FAIL: user 0 not RUNNING_UNLOCKED with sys.boot_completed=1 within %ds (last probe: %s)"
        % (args.boot_timeout, last))
    return False


def wanted_grants(policy):
    """return the grant set for the policy"""
    return {"ime": policy.scope("desktop.clipboard") in ("to-host", "both"),
            "listener": policy.allows("desktop.notifications"),
            "overlay": policy.allows("desktop.drag")}


def grant_commands(want):
    """return the shell commands for the grants"""
    ime = "ime enable %s; ime set %s" % (IME_ID, IME_ID) if want["ime"] else "ime disable %s" % IME_ID
    listener = "cmd notification %s %s" % ("allow_listener" if want["listener"] else "disallow_listener", LISTENER)
    overlay = "appops set %s SYSTEM_ALERT_WINDOW %s" % (BRIDGE_PKG, "allow" if want["overlay"] else "deny")
    return "; ".join((ime, listener, overlay))


def secure_setting(args, name):
    """read a Settings.Secure value"""
    rc, out = probe(args, "settings get secure %s" % name, 20)
    return out.strip() if rc == 0 else None


def held_grants(args):
    """read the grants set in Android"""
    held = {"ime": None, "listener": None, "overlay": None}
    default_ime = secure_setting(args, "default_input_method")
    enabled = secure_setting(args, "enabled_input_methods")
    if default_ime is not None and enabled is not None:
        ids = [e.split(";")[0] for e in enabled.split(":")]
        if default_ime == IME_ID and IME_ID in ids:
            held["ime"] = True
        elif default_ime != IME_ID and IME_ID not in ids:
            held["ime"] = False
    listeners = secure_setting(args, "enabled_notification_listeners")
    if listeners is not None:
        held["listener"] = LISTENER in listeners.split(":")
    rc, out = probe(args, "appops get %s SYSTEM_ALERT_WINDOW" % BRIDGE_PKG, 20)
    mode = re.search(r"^SYSTEM_ALERT_WINDOW: (allow|deny)\b", out, re.M) if rc == 0 else None
    if mode:
        held["overlay"] = mode.group(1) == "allow"
    return held


def set_grants(args, want):
    """set the grants and read them back"""
    rc, out = probe(args, "pm path %s" % BRIDGE_PKG, 20)
    if rc != 0 or out.strip() != "package:" + BRIDGE_APK:
        log("FAIL: %s is not the system app at %s (rc=%d: %s)" % (BRIDGE_PKG, BRIDGE_APK, rc, out.strip()[:300]))
        return False
    deadline = time.monotonic() + args.grant_timeout
    while True:
        rc, out = probe(args, grant_commands(want), 30)
        held = held_grants(args)
        if held == want:
            log("RHIZO_DESK_BRIDGE_GRANTS %s" % " ".join(
                "%s=%s" % (k, "on" if want[k] else "off") for k in sorted(want)))
            return True
        if time.monotonic() >= deadline:
            break
        time.sleep(1)
    log("FAIL: the android app's grants did not match the policy %ds after setting them: wanted %s, held %s (write rc=%d: %s)"
        % (args.grant_timeout, want, held, rc, out.strip()[:300]))
    return False


def replace_file(path, token):
    """write the token file with mode 0600"""
    tmp = path + ".new"
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(token + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.rename(tmp, path)


def write_token(path, token, user):
    """write the token file for the user"""
    if os.geteuid() == user.pw_uid:
        try:
            replace_file(path, token)
        except OSError as exc:
            log("FAIL: writing %s as %s: %s" % (path, user.pw_name, exc))
            return False
        return True
    pid = os.fork()
    if pid == 0:
        try:
            os.setgroups([])
            os.setgid(user.pw_gid)
            os.setuid(user.pw_uid)
            replace_file(path, token)
        except OSError as exc:
            log("FAIL: writing %s as %s: %s" % (path, user.pw_name, exc))
            os._exit(1)
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    return os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0


def main():
    """set the grants and write the token file"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--deskd-unit", default="rhizo-deskd.service")
    ap.add_argument("--boot-timeout", type=int, default=300)
    ap.add_argument("--grant-timeout", type=int, default=60)
    ap.add_argument("--probe-client", default=os.path.join(PAYLOAD_DIR, "probe-client.py"))
    ap.add_argument("--probe-sock", default=RUN_ROOT + "/data/local/tmp/rhizo-probe.sock")
    args = ap.parse_args()

    shown = subprocess.run(["systemctl", "show", "-p", "User", "--value", args.deskd_unit],
                           capture_output=True, text=True)
    name = shown.stdout.strip()
    if shown.returncode != 0 or not name:
        log("FAIL: %s has no User= to own the token (rc=%d: %s)" % (args.deskd_unit, shown.returncode, shown.stderr.strip()))
        return 1
    try:
        user = pwd.getpwnam(name)
    except KeyError:
        log("FAIL: %s runs as %s, which has no passwd entry" % (args.deskd_unit, name))
        return 1
    if not wait_for_unlock(args):
        return 1
    policy = capabilities.policy_or_deny(log=log, instance_id=SANDBOX_ID)
    if not set_grants(args, wanted_grants(policy)):
        return 1
    run_dir = os.path.dirname(args.token_file)
    if not os.path.isdir(run_dir):
        log("FAIL: %s does not exist -- %s is not running" % (run_dir, args.deskd_unit))
        return 1

    rc, out = probe(args, "content call --uri %s --method mint --arg %d" % (AUTHORITY_URI, args.port), 30)
    found = TOKEN_RE.search(out)
    if rc != 0 or not found:
        log("FAIL: mint over rhizo-probed (rc=%d): %s" % (rc, redact(out.strip())[:600]))
        return 1
    if not write_token(args.token_file, found.group(1), user):
        return 1

    rc, out = probe(args, "content call --uri %s --method start" % AUTHORITY_URI, 30)
    if rc != 0 or not STARTED_RE.search(out):
        log("FAIL: start over rhizo-probed (rc=%d): %s" % (rc, redact(out.strip())[:600]))
        return 1
    log("RHIZO_DESK_TOKEN_DELIVERED port=%d owner=%s" % (args.port, user.pw_name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
