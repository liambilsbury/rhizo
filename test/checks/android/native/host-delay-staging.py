#!/usr/bin/env python3
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path[:0] = [os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")), HERE]

from sandbox import capabilities  # noqa: E402
from sandbox import hals  # noqa: E402


def conf(tmp, name, text):
    """write a config file under a directory and return its path"""
    path = os.path.join(tmp, name)
    with open(path, "w") as handle:
        handle.write(text)
    return path


def main():
    """check the host-delay staging cases"""
    cases = []
    markers = []
    real_kmsg, real_stage = hals.kmsg, hals._stage_host_delay
    hals.kmsg = markers.append
    prev = os.environ.get(capabilities.PATH_ENV)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            hals._stage_host_delay = lambda *a: (calls.append(a), True)[1]
            os.environ[capabilities.PATH_ENV] = conf(tmp, "off.conf", "[trace]\nhost_delay = no\n")
            cases.append(("stage_host_delay() off returns False", hals.stage_host_delay() is False))
            cases.append(("stage_host_delay() off never reaches the staging half", calls == []))
            cases.append(("off logs host_delay_daemon=withheld",
                          "RHIZO_MARKER host_delay_daemon=withheld" in markers))
            os.environ[capabilities.PATH_ENV] = conf(tmp, "none.conf", "\n")
            cases.append(("the default policy withholds it", hals.stage_host_delay() is False
                          and calls == []))
            os.environ[capabilities.PATH_ENV] = conf(tmp, "bad.conf", "[trace\nhost_delay = yes\n")
            cases.append(("an unparseable policy withholds it", hals.stage_host_delay() is False
                          and calls == []))
            os.environ[capabilities.PATH_ENV] = conf(tmp, "on.conf", "[trace]\nhost_delay = yes\n")
            cases.append(("stage_host_delay() on stages", hals.stage_host_delay() is True
                          and len(calls) == 1))
            cases.append(("on stages from the launcher's own beside() path, into system_ext_upper",
                          len(calls) == 1 and calls[0][3].endswith("/rhizo-host-delay")
                          and calls[0][0].endswith("/system_ext_upper")))
            hals._stage_host_delay = real_stage

            upper = os.path.join(tmp, "system_ext_upper")
            fc = os.path.join(tmp, "vendor_file_contexts")
            sc = os.path.join(tmp, "vendor_service_contexts")
            binary = os.path.join(tmp, "rhizo-host-delay")
            markers.clear()
            cases.append(("a missing binary stages nothing and says so",
                          hals._stage_host_delay(upper, fc, sc, binary) is False
                          and not os.path.exists(upper) and not os.path.exists(fc)
                          and not os.path.exists(sc)
                          and any("host_delay_daemon=absent" in m for m in markers)))
            with open(binary, "wb") as handle:
                handle.write(b"\x7fELF-fixture")
            markers.clear()
            staged = hals._stage_host_delay(upper, fc, sc, binary)
            dst = os.path.join(upper, "bin/hw/rhizo-host-delay")
            rc_path = os.path.join(upper, "etc/init/rhizo-host-delay.rc")
            cases.append(("the binary lands on /system_ext/bin/hw, executable",
                          staged is True and os.path.isfile(dst) and os.stat(dst).st_mode & 0o777 == 0o755
                          and open(dst, "rb").read() == b"\x7fELF-fixture"))
            rc = open(rc_path).read() if os.path.exists(rc_path) else ""
            rc_lines = [ln.strip() for ln in rc.splitlines() if ln.strip() and not ln.strip().startswith("#")]
            cases.append(("the rc is the staged rhizo-host-delay.rc",
                          rc == open(os.path.join(REPO, "src", "androidd", "guest", "init", "host-delay.rc")).read()))
            cases.append(("the rc runs the service as system, class core, restarting",
                          "service rhizo_host_delay /system_ext/bin/hw/rhizo-host-delay" in rc_lines
                          and "class core" in rc_lines and "user system" in rc_lines
                          and "group system" in rc_lines and "oneshot" not in rc_lines))
            cases.append(("the rc names no seclabel: the policy's type_transition enters the domain",
                          not any(ln.startswith("seclabel") for ln in rc_lines)))
            cases.append(("the rc labels the binary itself at early-init",
                          "restorecon /system_ext/bin/hw/rhizo-host-delay" in rc_lines))
            cases.append(("the exec's file-contexts line is the one the policy expects",
                          open(fc).read() ==
                          "/system_ext/bin/hw/rhizo-host-delay u:object_r:rhizo_host_delay_exec:s0\n"))
            cases.append(("the service name is labeled rhizo_host_delay_service",
                          open(sc).read() == "rhizo.host_delay u:object_r:rhizo_host_delay_service:s0\n"))
            cases.append(("staging logs host_delay_daemon=staged",
                          any(m.startswith("RHIZO_MARKER host_delay_daemon=staged") for m in markers)))
    finally:
        hals.kmsg, hals._stage_host_delay = real_kmsg, real_stage
        if prev is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev

    failed = [name for name, ok in cases if not ok]
    for name, ok in cases:
        print("%s: %s" % ("ok" if ok else "FAIL", name))
    if failed:
        print("check-host-delay-staging: %d of %d cases FAILED" % (len(failed), len(cases)))
        return 1
    print("check-host-delay-staging: %d cases passed" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
