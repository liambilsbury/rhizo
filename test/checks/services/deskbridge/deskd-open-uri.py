#!/usr/bin/env python3
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))


def load_deskd():
    """return the deskd module loaded from its file"""
    spec = importlib.util.spec_from_file_location("rhizo_deskd_under_test", DESKD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _FakeStderr:
    def __init__(self, text):
        """keep the text as bytes"""
        self.text = text.encode()

    def read(self):
        """return the bytes"""
        return self.text

    def close(self):
        """do nothing"""
        pass


class _FakePopen:
    """fake xdg-open child process"""
    rc, err = 0, ""

    def __init__(self, argv, **_kw):
        """keep the arguments and a fake stderr"""
        self.argv = argv
        self.stderr = _FakeStderr(self.err)

    def poll(self):
        """return the fake exit code"""
        return self.rc


def make_instance(deskd, opens, schemes=None):
    """build a Deskd instance with fake openers"""
    inst = object.__new__(deskd.Deskd)
    inst.openers = []
    inst.open_times = []
    inst.android, inst.android_ok = None, False
    if schemes is None:
        schemes = deskd.capabilities.defaults().scope("desktop.open_uri")
    inst.uri_schemes = schemes

    def fake_popen(argv, **kw):
        """record the arguments and return a fake process"""
        opens.append(argv)
        return _FakePopen(argv, **kw)

    deskd.shutil.which = lambda name: "/usr/bin/xdg-open"
    deskd.subprocess.Popen = fake_popen
    return inst


def test_file_scheme_refused(deskd):
    """check that a file URI never reaches xdg-open"""
    opens = []
    inst = make_instance(deskd, opens)
    inst.open_on_host({"uri": "file:///etc/shadow"})
    if opens:
        print("check-deskd-open-uri: file:// reached xdg-open: %r" % opens)
        return False
    print("check-deskd-open-uri: file:// was refused (not in the scheme allowlist)")
    return True


def test_capability_off_refuses_everything(deskd):
    """check that no URI opens when the capability is withheld"""
    opens = []
    inst = make_instance(deskd, opens, schemes=frozenset())
    for uri in ("https://example.com/", "http://example.com/", "mailto:a@b"):
        inst.open_on_host({"uri": uri})
    if opens:
        print("check-deskd-open-uri: desktop.open_uri withheld and a URI still "
              "reached xdg-open: %r" % opens)
        return False
    print("check-deskd-open-uri: desktop.open_uri withheld refuses every scheme")
    return True


def test_leading_dash_refused(deskd):
    """check that an argument with a leading dash never reaches xdg-open"""
    opens = []
    inst = make_instance(deskd, opens)
    inst.open_on_host({"uri": "-foreground"})
    if opens:
        print("check-deskd-open-uri: a leading-dash argument reached xdg-open: %r" % opens)
        return False
    print("check-deskd-open-uri: a leading-dash argument was refused (no scheme matches it)")
    return True


def test_allowed_scheme_still_works(deskd):
    """check that an allowed scheme still opens unchanged"""
    opens = []
    inst = make_instance(deskd, opens)
    inst.open_on_host({"uri": "https://example.com/page"})
    if not opens or opens[0][-1] != "https://example.com/page":
        print("check-deskd-open-uri: an allowlisted https:// URI was refused or altered: %r" % opens)
        return False
    print("check-deskd-open-uri: an allowlisted https:// URI still reaches xdg-open")
    return True


def test_oversized_uri_refused(deskd):
    """check that a URI over the length cap is refused"""
    opens = []
    inst = make_instance(deskd, opens)
    huge = "https://example.com/" + ("a" * deskd.MAX_URI_LEN)
    inst.open_on_host({"uri": huge})
    if opens:
        print("check-deskd-open-uri: a %d-character URI (cap %d) reached xdg-open"
              % (len(huge), deskd.MAX_URI_LEN))
        return False
    print("check-deskd-open-uri: a URI over MAX_URI_LEN was refused")
    return True


def test_rate_limited(deskd):
    """check that opens beyond the rate limit are refused"""
    opens = []
    inst = make_instance(deskd, opens)
    total = deskd.OPEN_RATE_LIMIT + 3
    for i in range(total):
        inst.open_on_host({"uri": "https://example.com/%d" % i})
    if len(opens) != deskd.OPEN_RATE_LIMIT:
        print("check-deskd-open-uri: sent %d opens within the rate window, %d reached xdg-open, "
              "wanted exactly OPEN_RATE_LIMIT=%d" % (total, len(opens), deskd.OPEN_RATE_LIMIT))
        return False
    print("check-deskd-open-uri: %d opens in one burst were capped at OPEN_RATE_LIMIT=%d"
          % (total, deskd.OPEN_RATE_LIMIT))
    return True


def test_outcome_reported(deskd):
    """test the open_failed messages and log lines"""
    ok = True
    for uri, rc, err, want_failed, want_log in (
            ("file:///etc/shadow", 0, "", True, "not in the allowlist"),
            ("https://example.com/fails", 4, "xdg-open: no method available for opening", True,
             "xdg-open failed for https://example.com/fails: rc=4 xdg-open: no method available"),
            ("https://example.com/opens", 0, "", False, "xdg-open opened https://example.com/opens")):
        opens, sent, logs = [], [], []
        inst = make_instance(deskd, opens)
        inst.to_android = sent.append
        deskd.log = logs.append
        _FakePopen.rc, _FakePopen.err = rc, err
        inst.open_on_host({"uri": uri})
        inst.reap_openers()
        _FakePopen.rc, _FakePopen.err = 0, ""
        failed = [m for m in sent if m.get("t") == "open_failed"]
        if want_failed and (len(failed) != 1 or failed[0].get("uri") != uri or not failed[0].get("why")):
            print("check-deskd-open-uri: %s (xdg-open rc %d) sent the android app %r, want one open_failed "
                  "naming it and why" % (uri, rc, sent))
            ok = False
        if not want_failed and failed:
            print("check-deskd-open-uri: %s opened, yet the android app was told it failed: %r" % (uri, failed))
            ok = False
        if not any(want_log in m for m in logs):
            print("check-deskd-open-uri: %s logged %r, want a line holding %r" % (uri, logs, want_log))
            ok = False
    if ok:
        print("check-deskd-open-uri: a refused open and a failed xdg-open reach the android app as open_failed, "
              "and a clean xdg-open exit is logged")
    return ok


def main():
    """run the URI checks and return the exit code"""
    deskd = load_deskd()
    ok = True
    ok = test_file_scheme_refused(deskd) and ok
    ok = test_capability_off_refuses_everything(deskd) and ok
    ok = test_leading_dash_refused(deskd) and ok
    ok = test_allowed_scheme_still_works(deskd) and ok
    ok = test_oversized_uri_refused(deskd) and ok
    ok = test_rate_limited(deskd) and ok
    ok = test_outcome_reported(deskd) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
