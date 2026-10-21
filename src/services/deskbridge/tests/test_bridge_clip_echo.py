#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "..", "android", "apps", "desktop-bridge", "src", "com", "rhizo", "desktop", "HostClipEcho.java"))
TEST = os.path.join(HERE, "HostClipEchoTest.java")


def main():
    """build and run the HostClipEcho test"""
    for tool in ("javac", "java"):
        if shutil.which(tool) is None:
            print("FAIL no %s on PATH to build the android app's HostClipEcho" % tool)
            return 1
    work = tempfile.mkdtemp(prefix="test-bridge-clip-echo.")
    try:
        built = subprocess.run(["javac", "-nowarn", "-d", work, SRC, TEST], capture_output=True, text=True)
        if built.returncode != 0:
            print("FAIL javac: %s" % built.stderr.strip())
            return 1
        ran = subprocess.run(["java", "-cp", work, "com.rhizo.desktop.HostClipEchoTest"],
                             capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.stderr:
            sys.stdout.write(ran.stderr)
        return ran.returncode
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
