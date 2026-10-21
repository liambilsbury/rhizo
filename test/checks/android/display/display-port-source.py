#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

COMPOSER = os.path.join(REPO, "src", "android", "hal", "graphics-composer", "src", "composer.cpp")
GUEST = os.path.join(REPO, "src", "androidd", "guest", "bin", "launch-app.sh")
OUTER = os.path.join(REPO, "src", "androidd", "host", "launch-app.sh")

REPLY_RE = re.compile(r'WriteControlReply\("display added id="(.*?)\);', re.S)
ID_KEYED_RE = re.compile(r"(physicalPort=\$newid|\{port=\$newid)")
READS_PORT_RE = re.compile(r"grep -o 'port=\[0-9\]\*'")


def strip_sh_comments(text):
    """return the text without lines that start with #"""
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith("#"))


def strip_c_comments(text):
    """return the text without lines that start with //"""
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith("//"))


def check_reply(text):
    """check the composer reply for port="""
    m = REPLY_RE.search(strip_c_comments(text))
    if not m:
        return ["composer.cpp: no WriteControlReply for `display added id=` found at all"]
    if "port=" not in m.group(1):
        return ["composer.cpp: the `display added id=` reply carries no port= field"]
    return []


def check_script(name, text, must_read_port):
    """check that a script keys on the reported port"""
    bad = []
    body = strip_sh_comments(text)
    for hit in ID_KEYED_RE.findall(body):
        bad.append("%s: matches a framework dump on the display id (%s), not on the "
                   "port the composer reported" % (name, hit))
    if must_read_port and not READS_PORT_RE.search(body):
        bad.append("%s: never reads a port= out of the control reply" % name)
    return bad


SELFTEST_REPLY_OK = '''
      int64_t id = AddDisplay(w, h);
      int32_t port = -1;
      WriteControlReply("display added id=" + std::to_string(id) + " port=" +
                        std::to_string(port) + " " + std::to_string(w));
'''
SELFTEST_REPLY_BAD = '''
      int64_t id = AddDisplay(w, h);
      WriteControlReply("display added id=" + std::to_string(id) + " " + std::to_string(w));
'''
SELFTEST_SCRIPT_OK = """#!/system/bin/sh
newport=$(printf '%s\\n' "$reply" | grep -o 'port=[0-9]*' | head -1 | cut -d= -f2)
logid=$(dumpsys display | grep "physicalPort=$newport," | cut -d= -f2)
state=$(dumpsys display | awk -v want="address \\\\{port=$newport[,}]" '$0 ~ want')
"""
SELFTEST_SCRIPT_BAD = """#!/system/bin/sh
newport=$(printf '%s\\n' "$reply" | grep -o 'port=[0-9]*' | head -1 | cut -d= -f2)
logid=$(dumpsys display | grep "physicalPort=$newid," | cut -d= -f2)
"""


def selftest():
    """check each reply and script sample against its expected result"""
    cases = [
        ("composer reply with a port", check_reply(SELFTEST_REPLY_OK), 0),
        ("composer reply without a port", check_reply(SELFTEST_REPLY_BAD), 1),
        ("script keyed on the port", check_script("fix", SELFTEST_SCRIPT_OK, True), 0),
        ("script keyed on the id", check_script("fix", SELFTEST_SCRIPT_BAD, True), 1),
        ("script that never reads the port",
         check_script("fix", "logid=$(dumpsys display)\n", True), 1),
    ]
    for label, found, want in cases:
        if len(found) != want:
            print("SELFTEST FAILED: %s produced %d findings, expected %d: %s"
                  % (label, len(found), want, found), file=sys.stderr)
            return 1
    print("selftest ok: catches a portless reply, an id-keyed match, and a script "
          "that never reads the reported port")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    with open(COMPOSER) as f:
        bad += check_reply(f.read())
    with open(GUEST) as f:
        bad += check_script("src/androidd/guest/bin/launch-app.sh", f.read(), True)
    with open(OUTER) as f:
        bad += check_script("src/androidd/host/launch-app.sh", f.read(), False)
    if bad:
        for b in bad:
            print(b, file=sys.stderr)
        return 1
    print("the composer reports the port it assigned and both launch scripts key on it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
