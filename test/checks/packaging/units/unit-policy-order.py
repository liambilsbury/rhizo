#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402

POSTINST = "debian/rhizo.postinst"
LIB = "src/install/lib/pkg-lib.sh"
TEST = "test/system/install/installer.sh"
SYNC = "/usr/lib/rhizo/streamd/capability-sync.sh"
CALL_RE = re.compile(r"^[ \t]*pkg_unit_policy[ \t]*$", re.M)


def read(path):
    """return the text of a file"""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def postinst_problems(root):
    """return the postinst order problems"""
    out = []
    path = os.path.join(root, POSTINST)
    text = read(path)
    if text.count("#DEBHELPER#") != 1:
        return ["%s: carries #DEBHELPER# %d times, not once" % (POSTINST, text.count("#DEBHELPER#"))]
    head, tail = text.split("#DEBHELPER#")
    if CALL_RE.search(head):
        out.append("%s: calls pkg_unit_policy before #DEBHELPER#" % POSTINST)
    if not re.search(r'^if \[ "\$1" = configure \]; then\n[ \t]+pkg_unit_policy\nfi$', tail, re.M):
        out.append("%s: no `if [ \"$1\" = configure ]; then pkg_unit_policy; fi` after #DEBHELPER#" % POSTINST)
    inlined = maint_inline.inlined(path)
    ihead = inlined.split("#DEBHELPER#")[0]
    if SYNC in ihead:
        out.append("%s: its configure arm runs %s before #DEBHELPER#, whose block then enables the socket "
                   "the sync disabled" % (POSTINST, os.path.basename(SYNC)))
    return out


def function_body(text, name):
    """return the lines of a shell function"""
    m = re.search(r"^%s\(\) \{(?:[ \t]*#[^\n]*)?\n(.*?)^\}$" % re.escape(name), text, re.M | re.S)
    return m.group(1) if m else ""


def library_problems(root):
    """return problems in pkg_unit_policy and pkg_configure"""
    out = []
    text = read(os.path.join(root, LIB))
    body = function_body(text, "pkg_unit_policy")
    if not body:
        return ["%s: defines no pkg_unit_policy" % LIB]
    if not re.search(r'^[ \t]*/usr/bin/rhizo profile "\$profile"[ \t]*$', body, re.M):
        out.append("%s: pkg_unit_policy does not apply `/usr/bin/rhizo profile \"$profile\"`" % LIB)
    if not re.search(r"^[ \t]*%s\b" % re.escape(SYNC), body, re.M):
        out.append("%s: pkg_unit_policy does not run %s" % (LIB, SYNC))
    steps = re.findall(r"pkg_step=(\w+);", function_body(text, "pkg_configure"))
    if not steps or steps[-1] != "pkg_unit_policy" or "pkg_start_listed_units" not in steps:
        out.append("%s: pkg_configure's steps are %s; pkg_unit_policy must be the last, after "
                   "pkg_start_listed_units" % (LIB, " ".join(steps) or "none"))
    return out


def test_problems(root):
    """return findings for the installer.sh socket check"""
    text = read(os.path.join(root, TEST))
    install = text.find("installer_install_reboot_prepare \"$leg\"")
    assert_at = text.find('installer_assert_policy_sockets "$leg"')
    competing = text.find('[[ "$leg" == competing ]] && return 0')
    if install < 0 or assert_at < install or (0 <= competing < assert_at):
        return ["%s: does not run installer_assert_policy_sockets after its install step, for every leg" % TEST]
    return []


def check(root):
    """return the problems from the postinst, library and test checks"""
    return postinst_problems(root) + library_problems(root) + test_problems(root)


def verdict(read_text):
    """return the output of installer_policy_socket_problems"""
    r = subprocess.run(["bash", "-c", 'source "$1"; installer_policy_socket_problems "$2"', "verdict",
                        os.path.join(ROOT, "test", "system", "lib", "installer-lib.sh"), read_text],
                       capture_output=True, text=True, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit("installer_policy_socket_problems exited %d: %s" % (r.returncode, r.stderr.strip()))
    return r.stdout.strip()


def selftest():
    """check each planted-defect copy against its finding"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-unit-policy-order.")
    try:
        def tree(edit_postinst=None, edit_lib=None, edit_test=None):
            """copy the checked files into a new tree"""
            root = os.path.join(tmp, "t%d" % len(os.listdir(tmp)))
            for rel, edit in ((POSTINST, edit_postinst), (LIB, edit_lib), (TEST, edit_test)):
                os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
                text = read(os.path.join(ROOT, rel))
                new = edit(text) if edit else text
                if edit and new == text:
                    raise SystemExit("selftest: an edit of %s changed nothing" % rel)
                with open(os.path.join(root, rel), "w", encoding="utf-8") as fh:
                    fh.write(new)
            return root

        def case(name, want, **edits):
            """check the findings carry the wanted text"""
            got = check(tree(**edits))
            if want is None:
                if got:
                    fails.append("%s: want no finding, got %s" % (name, got))
            elif not any(want in g for g in got):
                fails.append("%s: no finding carries %r; got %s" % (name, want, got or "none"))

        block = 'if [ "$1" = configure ]; then\n  pkg_unit_policy\nfi\n'
        case("the real tree", None)
        case("the call before #DEBHELPER#", "calls pkg_unit_policy before #DEBHELPER#",
             edit_postinst=lambda t: t.replace(block, "").replace(
                 "    pkg_reboot_notice \"${2:-}\"\n", "    pkg_reboot_notice \"${2:-}\"\n    pkg_unit_policy\n"))
        case("no call after #DEBHELPER#", "no `if [ \"$1\" = configure ]",
             edit_postinst=lambda t: t.replace(block, ""))
        case("the sync left in the configure arm", "runs capability-sync.sh before #DEBHELPER#",
             edit_lib=lambda t: t.replace("  systemctl start rhizo-stream-capability.path\n",
                                          "  systemctl start rhizo-stream-capability.path\n  %s\n" % SYNC))
        case("pkg_unit_policy without the profile", "does not apply `/usr/bin/rhizo profile",
             edit_lib=lambda t: t.replace('  /usr/bin/rhizo profile "$profile"\n', ""))
        case("pkg_unit_policy without the sync", "pkg_unit_policy does not run",
             edit_lib=lambda t: t.replace("  %s \\\n" % SYNC, "  true \\\n"))
        case("pkg_configure with the policy before the starts", "pkg_unit_policy must be the last",
             edit_lib=lambda t: t.replace(
                 '    pkg_step=pkg_start_listed_units; pkg_start_listed_units "$1" || start_rc=$?\n'
                 "    pkg_step=pkg_unit_policy; pkg_unit_policy\n",
                 "    pkg_step=pkg_unit_policy; pkg_unit_policy\n"
                 '    pkg_step=pkg_start_listed_units; pkg_start_listed_units "$1" || start_rc=$?\n'))
        case("the system test without the assertion", "does not run installer_assert_policy_sockets",
             edit_test=lambda t: t.replace('  installer_assert_policy_sockets "$leg"', '  : "$leg"'))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    good = ("PROFILE desktop\nSTREAM disable\nSOCKET rhizo-api.socket disabled inactive\n"
            "SOCKET rhizo-streamd.socket disabled inactive\nDONE")
    reads = [
        ("a new desktop install with stream off", good, None),
        ("the api socket debhelper enabled on a desktop", good.replace(
            "rhizo-api.socket disabled inactive", "rhizo-api.socket enabled active"),
         "rhizo-api.socket is 'enabled active'"),
        ("the stream socket left listening with stream off", good.replace(
            "rhizo-streamd.socket disabled inactive", "rhizo-streamd.socket disabled active"),
         "rhizo-streamd.socket is 'disabled active'"),
        ("a server profile wants its api socket", good.replace("PROFILE desktop", "PROFILE server"),
         "rhizo-api.socket is 'disabled inactive', where the server profile"),
        ("a server profile with its api socket", good.replace("PROFILE desktop", "PROFILE server").replace(
            "rhizo-api.socket disabled inactive", "rhizo-api.socket enabled active"), None),
        ("stream on wants its socket", good.replace("STREAM disable", "STREAM enable"),
         "rhizo-streamd.socket is 'disabled inactive'"),
        ("an unread profile", good.replace("PROFILE desktop\n", ""), "names no profile"),
        ("a sync that gave no decision", good.replace("STREAM disable", "STREAM error: x"), "no decision"),
        ("a read cut short", good.replace("\nDONE", ""), "incomplete read"),
    ]
    for name, text, want in reads:
        got = verdict(text)
        if want is None and got:
            fails.append("verdict, %s: want none, got %r" % (name, got))
        elif want is not None and want not in got:
            fails.append("verdict, %s: want %r, got %r" % (name, want, got or "none"))

    if fails:
        for f in fails:
            print("SELFTEST FAILED: " + f, file=sys.stderr)
        return 1
    print("check-unit-policy-order selftest: ok (8 tree cases, %d socket reads)" % len(reads))
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: unit-policy-order.py [--selftest]", file=sys.stderr)
        return 2
    problems = check(ROOT)
    for p in problems:
        print("FAIL: unit-policy-order: " + p, file=sys.stderr)
    if problems:
        return 1
    print("unit-policy-order: the profile and the stream sync run after the package manager's unit steps "
          "in the postinst and pkg_configure, and installer.sh asserts both sockets")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
