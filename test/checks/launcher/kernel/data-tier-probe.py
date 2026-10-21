#!/usr/bin/env python3
import contextlib
import errno
import gzip
import io
import os
import sys
import tempfile

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-data-tier-probe")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher


def main():
    """return the failures"""
    bad, logs = [], []
    saved = (launcher.kmsg, launcher.core.module_entry, launcher._kconfig_has)
    launcher.kmsg = logs.append
    try:
        for label, err in (("EACCES", PermissionError(errno.EACCES, "Permission denied", "modules.dep")),
                           ("EIO", OSError(errno.EIO, "Input/output error", "modules.dep"))):
            logs.clear()

            def unreadable(name, err=err):
                """fail the modules.dep read"""
                raise err

            launcher.core.module_entry = unreadable
            launcher._kconfig_has = lambda line: False
            try:
                got = launcher._probe_data_tier()
            except Exception as e:
                got = repr(e)
            if got not in ("quota", "plain") or not any("modules.dep unreadable" in m for m in logs):
                bad.append(f"modules.dep {label}: want a tier and the input named, got {got!r} {logs}")
        launcher.core.module_entry, launcher._kconfig_has = saved[1], saved[2]
        with tempfile.TemporaryDirectory() as tmp:
            good, corrupt, directory = (os.path.join(tmp, n) for n in ("good.gz", "corrupt.gz", "dir.gz"))
            with gzip.open(good, "wt") as f:
                f.write("CONFIG_A=y\nCONFIG_QFMT_V2=y\n")
            with open(corrupt, "wb") as f:
                f.write(b"not gzip at all")
            os.mkdir(directory)
            for label, path, want, named in (("a config with the line", good, True, False),
                                             ("a corrupt config", corrupt, False, True),
                                             ("a config that is a directory", directory, False, True),
                                             ("no config", os.path.join(tmp, "absent.gz"), False, False)):
                logs.clear()
                try:
                    got = launcher._kconfig_has("CONFIG_QFMT_V2=y", path)
                except Exception as e:
                    got = repr(e)
                if got is not want or any(path in m for m in logs) != named:
                    article = "a" if named else "no"
                    bad.append(f"{label}: want {want} and {article} named read error, got {got!r} {logs}")
    finally:
        launcher.kmsg, launcher.core.module_entry, launcher._kconfig_has = saved
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("data-tier-probe:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
