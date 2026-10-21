#!/usr/bin/env python3
import errno
import importlib.util
import os
import subprocess
import sys
import tempfile

APPSYNC = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
                                        "src", "services", "appsync", "appsync.py"))


def load_appsync(path, name):
    """return the appsync module loaded from a file"""
    launcher = os.path.join(os.path.dirname(APPSYNC), "..", "..", "androidd")
    if launcher not in sys.path:
        sys.path.insert(0, launcher)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def names_eisdir_read(got):
    """whether got raises the mode read with EISDIR"""
    return got.startswith("raised: reading the SELinux mode file") and f"[Errno {errno.EISDIR}]" in got


def fake_helper(tmp, answer):
    """write a mode helper that prints answer"""
    path = os.path.join(tmp, "rhizo-selinux-mode")
    with open(path, "w") as f:
        if answer is None:
            f.write('#!/bin/sh\necho "cannot parse $2" >&2\nexit 1\n')
        else:
            f.write(f'#!/bin/sh\necho "$@" > "{tmp}/helper-argv"\necho {answer}\n')
    os.chmod(path, 0o755)
    return path


def mode_file(tmp, content):
    """write the mode file fixture"""
    path = os.path.join(tmp, "mode")
    if content == "directory":
        os.mkdir(path)
    elif content is not None:
        with open(path, "w") as f:
            f.write(content)
    return path


def answer(read):
    """return a mode read's answer"""
    try:
        return read()
    except RuntimeError as e:
        return f"raised: {e}"


def local_read(mod, tmp, content, helper_answer):
    """return the local reader's answer for a fixture"""
    os.environ["RHIZO_SELINUX_MODE_FILE"] = mode_file(tmp, content)
    os.environ["RHIZO_SELINUX_MODE_HELPER"] = fake_helper(tmp, helper_answer)
    os.environ["RHIZO_ANDROIDD_ENV"] = os.path.join(tmp, "androidd.env")
    return answer(mod.read_selinux_mode)


def remote_read(mod, tmp, content, helper_answer):
    """run a remote backend's mode read here"""
    path, helper = mode_file(tmp, content), fake_helper(tmp, helper_answer)
    env_file = os.path.join(tmp, "androidd.env")

    class Guest(mod.HostBackend):
        """backend running the guest command locally"""

        def host_run(self, cmd, timeout=30):
            """run cmd with the guest paths mapped here"""
            cmd = (cmd.replace(mod.SELINUX_MODE_FILE, path).replace(mod.SELINUX_MODE_HELPER, helper)
                   .replace(mod.ANDROIDD_ENV, env_file))
            r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
            return r.returncode, r.stdout

    return answer(Guest(local=False, init_pid=1).selinux_mode)


def route(mod, local, desk_mode, guest_mode):
    """return the route android_sh took"""
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["RHIZO_SELINUX_MODE_FILE"] = mode_file(tmp, desk_mode + "\n")
        seen = []

        class Stub(mod.HostBackend):
            """backend recording its routes"""

            def host_run(self, cmd, timeout=30):
                """answer the mode read and record other commands"""
                if "rhizo-selinux-mode" in cmd:
                    return 0, guest_mode + "\n"
                seen.append("nsenter" if "nsenter" in cmd else cmd)
                return 0, ""

            def probe_sh(self, cmd, timeout=30):
                """record the probe route"""
                seen.append("probe")
                return ""

        Stub(local=local, init_pid=4242).android_sh("true")
        return seen[0]


def check(mod):
    """return every finding for an appsync module"""
    bad = []
    for local, desk, guest, want in ((True, "namespace", "host", "probe"), (True, "host", "namespace", "nsenter"),
                                     (False, "host", "namespace", "probe"), (False, "namespace", "host", "nsenter")):
        got = route(mod, local, desk, guest)
        if got != want:
            bad.append(f"local={local} desk={desk} guest={guest} routes {got}, not {want}")
    cases = (
        ("a recorded namespace mode", "namespace\n", "host", "namespace"),
        ("a recorded host mode", "host\n", "namespace", "host"),
        ("a missing mode file with namespace configured", None, "namespace", "namespace"),
        ("a missing mode file with host configured", None, "host", "host"),
        ("an empty mode file with namespace configured", "\n", "namespace", "namespace"),
        ("a missing mode file whose helper fails", None, None, None),
        ("a garbled mode file", "permissive\n", "host", "raised:"),
    )
    if not hasattr(mod, "configured_selinux_mode"):
        return bad + ["appsync has no configured_selinux_mode to read an unrecorded mode through rhizo-selinux-mode"]
    for where, read in (("local", local_read), ("remote", remote_read)):
        for label, content, helper_answer, want in cases:
            if want is None:
                want = ("raised: the SELinux mode helper" if where == "local"
                        else "raised: reading the guest's SELinux mode failed")
            with tempfile.TemporaryDirectory() as tmp:
                got = read(mod, tmp, content, helper_answer)
                argv = open(os.path.join(tmp, "helper-argv")).read().split() if os.path.exists(
                    os.path.join(tmp, "helper-argv")) else None
            if not (got == want or (want.startswith("raised:") and got.startswith(want))):
                bad.append(f"{where}: {label} reads {got!r}, not {want!r}")
            if content in (None, "\n") and helper_answer and argv is not None and argv[1:] != [
                    os.path.join(tmp, "androidd.env"), "--configured"]:
                bad.append(f"{where}: {label} runs the helper with {argv}, not --env-file <androidd.env> --configured")
    with tempfile.TemporaryDirectory() as tmp:
        got = local_read(mod, tmp, "directory", "host")
        if not names_eisdir_read(got):
            bad.append(f"local: an unreadable mode file reads {got!r}, not a raise naming the path and error")
    for what, rc, out, want in (("an ssh failure", 255, "ssh: connect to host 127.0.0.1 port 2222: Connection refused", "exited 255"),
                                ("a failed command with a valid-looking answer", 1, "namespace\n", "exited 1"),
                                ("a garbled answer", 0, "Warning: permanently added\nnamespace\n", "output 'Warning"),
                                ("an empty answer", 0, "", "output ''")):

        class Stub(mod.HostBackend):
            """backend answering every command alike"""

            def host_run(self, cmd, timeout=30, rc=rc, out=out):
                """return the fixed status and output"""
                return rc, out

        got = answer(Stub(local=False, init_pid=1).selinux_mode)
        if want not in got or "reading the guest's SELinux mode failed" not in got:
            bad.append(f"remote: {what} reads {got!r}, not a raise naming {want!r}")
    reads = []

    class Counting(mod.HostBackend):
        """backend counting its mode reads"""

        def host_run(self, cmd, timeout=30):
            """count the mode reads"""
            reads.append(cmd)
            return 0, "namespace\n"

        def probe_sh(self, cmd, timeout=30):
            """answer the probe route"""
            return ""

    c = Counting(local=False, init_pid=1)
    c.selinux_mode(), c.selinux_mode(), c.android_sh("true")
    if len([r for r in reads if "rhizo-selinux-mode" in r]) != 1:
        bad.append(f"a backend reads the mode {len(reads)} times, not once")
    return bad


def selftest():
    """flag each mutant and pass the real appsync"""
    src = open(APPSYNC).read()
    cases = (
        ("missing mode file read as host", "    except FileNotFoundError:\n        mode = \"\"\n",
         "    except FileNotFoundError:\n        return \"host\"\n", "local: a missing mode file with namespace configured"),
        ("helper failure read as host", "    if r.returncode != 0 or mode not in SELINUX_MODES:\n",
         "    if r.returncode != 0 or mode not in SELINUX_MODES:\n        return \"host\"\n", "whose helper fails"),
        ("remote read skipping the helper", "then {helper}; else echo", "then echo host; else echo",
         "remote: a missing mode file with namespace configured"),
    )
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, (label, old, new, needle) in enumerate(cases):
            if src.count(old) != 1:
                return [f"the {label} mutant found {src.count(old)} anchors"]
            path = os.path.join(tmp, f"appsync_m{n}.py")
            with open(path, "w") as f:
                f.write(src.replace(old, new))
            got = check(load_appsync(path, f"_appsync_mode_m{n}"))
            if not any(needle in g for g in got):
                bad.append(f"the {label} mutant was not flagged: {got}")
    raised = "raised: reading the SELinux mode file /run/m failed: [Errno %d] %s: '/run/m'"
    for text, want in ((raised % (errno.EISDIR, "Ist ein Verzeichnis"), True),
                       (raised % (errno.EISDIR, "Is a directory"), True),
                       (raised % (errno.EACCES, "Is a directory"), False)):
        if names_eisdir_read(text) != want:
            bad.append(f"the EISDIR read reads {text!r} as {not want}: it must go by errno, not the locale's words")
    real = check(load_appsync(APPSYNC, "_appsync_mode_real"))
    if real:
        bad.append(f"the real appsync has findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check(load_appsync(APPSYNC, "_appsync_mode"))
    for b in bad:
        print("FAIL: appsync-mode:", b)
    print("ok: appsync-mode" if not bad else "FAIL: appsync-mode")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
