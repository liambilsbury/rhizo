#!/usr/bin/env python3
import base64
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, filename):
    """import a module from a file in the parent directory"""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


brokerd = load("rhizo_brokerd", "brokerd.py")
client = load("rhizo_broker_client", "broker-client.py")
inbox_stage = load("inbox_stage", "inbox_stage.py")

failures = []


def check(name, got, want):
    """print ok or FAIL for a comparison and record each failure"""
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s: got %r, want %r" % (name, got, want))
        failures.append(name)


def refusal(fn, *args):
    """return the Refused message a call raises, or None"""
    try:
        fn(*args)
    except brokerd.Refused as e:
        return str(e)
    return None


def unusable(fn, *args):
    """return the Unusable message a call raises, or None"""
    try:
        fn(*args)
    except client.Unusable as e:
        return str(e)
    return None


def test_launch_targets():
    """test the launch target checks"""
    for target in ("mailto:a@b", "tel:+1", "geo:0,0", "https://x/y",
                   "file:///tmp/x", "/tmp/x"):
        check("target %s accepted" % target, refusal(brokerd.check_launch_target, target), None)
    check("target relative.txt refused",
          refusal(brokerd.check_launch_target, "relative.txt"),
          "'relative.txt' is neither a URI nor an absolute path")
    check("target over the length limit refused",
          refusal(brokerd.check_launch_target, "https://x/" + "y" * 5000)[:24],
          "launch target is 5010 ch"[:24])


def launch_argv(*args):
    """return the argv for a launch request"""
    request = {"v": 1, "verb": "launch",
               "args": [base64.b64encode(a.encode()).decode() for a in args]}
    try:
        return brokerd.build_argv(request, [])
    except brokerd.Refused as e:
        return "refused: %s" % e


def test_launch_mime():
    """test the launch mime type checks"""
    check("a typed launch reaches the CLI as --mime",
          launch_argv("com.x", "/home/u/note.txt", "text/plain"),
          ["launch", "com.x", "/home/u/note.txt", "--mime", "text/plain"])
    check("a URL launch stays two arguments",
          launch_argv("com.x", "https://x/y"), ["launch", "com.x", "https://x/y"])
    check("mime text/Plain refused",
          refusal(brokerd.check_launch_mime, "text/Plain"),
          "'text/Plain' is not a lowercase type/subtype")
    for bad in ("text", "a/b/c", "/plain", "text/", "text plain", ""):
        check("mime %r refused" % bad, refusal(brokerd.check_launch_mime, bad) is None, False)
    for good in ("text/plain", "application/vnd.oasis.opendocument.text",
                 "application/x-7z-compressed", "image/svg+xml"):
        check("mime %s accepted" % good, refusal(brokerd.check_launch_mime, good), None)
    check("a refused mime never reaches the CLI",
          launch_argv("com.x", "/tmp/x", "a/b/c"),
          "refused: 'a/b/c' is not a lowercase type/subtype")
    check("a fourth argument is refused",
          launch_argv("com.x", "/tmp/x", "text/plain", "x"),
          "refused: launch takes 1 to 3 arguments, got 4")


def test_package_names():
    """test the package name checks"""
    check("package .. refused", refusal(brokerd.check_package, "..") is None, False)
    check("package .a refused", refusal(brokerd.check_package, ".a") is None, False)
    check("package a accepted", refusal(brokerd.check_package, "a"), None)
    check("package com.x accepted", refusal(brokerd.check_package, "com.x"), None)
    check("appsync's own pattern is the one in use",
          brokerd.PKG_RE.pattern, r"^[A-Za-z0-9_][A-Za-z0-9_.]*$")


def send_fds(n):
    """send descriptors through a socketpair to read_request"""
    import array
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    files = [tempfile.TemporaryFile() for _ in range(n)]
    b.sendmsg([b'{"v":1,"verb":"install","args":[]}\n'],
              [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                array.array("i", [f.fileno() for f in files]))])
    fds = []
    try:
        line = brokerd.read_request(a, fds)
        err = None
    except brokerd.Refused as e:
        line, err = None, str(e)
    for fd in fds:
        os.close(fd)
    for f in files:
        f.close()
    a.close()
    b.close()
    return line, err, len(fds)


def test_ancillary():
    """test read_request and build_argv with passed descriptors"""
    line, err, count = send_fds(3)
    check("a truncated control message is refused by name", err, "ancillary data truncated")

    line, err, count = send_fds(2)
    check("two descriptors reach the count check", (err, count), (None, 2))
    check("two descriptors refused by name",
          refusal(brokerd.build_argv, {"v": 1, "verb": "install", "args": []},
                  [os.open("/dev/null", os.O_RDONLY), os.open("/dev/null", os.O_RDONLY)]),
          "install needs exactly one SCM_RIGHTS descriptor, got 2")

    line, err, count = send_fds(1)
    check("one descriptor still arrives",
          (line, err, count), (b'{"v":1,"verb":"install","args":[]}', None, 1))
    check("install with no descriptor still refused",
          refusal(brokerd.build_argv, {"v": 1, "verb": "install", "args": []}, []),
          "install needs exactly one SCM_RIGHTS descriptor, got 0")


def test_client_launch_arg():
    """test the launch argument kinds"""
    for arg, kind in (("mailto:a@b", "uri"), ("tel:+1", "uri"), ("geo:0,0", "uri"),
                      ("https://x/y", "uri"), ("x.y+z-1:q", "uri"),
                      ("file:///tmp/x", "path"), ("FILE:///tmp/x", "path"),
                      ("/tmp/x", "path"), ("relative.txt", "path")):
        check("the client routes %s to the %s branch" % (arg, kind),
              client.launch_arg_kind(arg), kind)


def test_client_resolves_as_the_user():
    """test resolve_launch_file"""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = os.path.realpath(tmp)
        real = os.path.join(tmp, "a b.pdf")
        open(real, "w").close()
        check("a path resolves to itself", client.resolve_launch_file(real), real)
        check("a file:// URL resolves through its percent-encoding",
              client.resolve_launch_file("file://" + tmp + "/a%20b.pdf"), real)
        check("a directory does not name a readable file",
              unusable(client.resolve_launch_file, tmp),
              "%s does not name a readable file" % tmp)
        locked = os.path.join(tmp, "locked")
        os.mkdir(locked, 0o000)
        hidden = os.path.join(locked, "note.txt")
        check("a path this account cannot traverse fails by name",
              unusable(client.resolve_launch_file, hidden),
              "%s does not name a readable file" % hidden)
        os.chmod(locked, 0o755)


def stub_xdg_mime(bin_dir, body):
    """write an executable xdg-mime shell script with the given body"""
    path = os.path.join(bin_dir, "xdg-mime")
    with open(path, "w") as f:
        f.write("#!/bin/sh\n%s\n" % body)
    os.chmod(path, 0o755)


def test_client_types_the_file():
    """test the file mime lookup"""
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = os.path.join(tmp, "bin")
        os.mkdir(bin_dir)
        path = os.path.join(tmp, "report.pdf")
        open(path, "w").close()
        unknown = os.path.join(tmp, "x.zzzz")
        open(unknown, "w").close()
        saved = os.environ["PATH"]
        os.environ["PATH"] = bin_dir
        try:
            check("no xdg-mime on PATH fails by name", unusable(client.file_mime, path),
                  "no xdg-mime on this host to read %s's type -- install xdg-utils" % path)
            stub_xdg_mime(bin_dir, "exit 0")
            check("an empty xdg-mime answer reaches python's table",
                  client.file_mime(path), "application/pdf")
            check("a type neither source names fails by name",
                  unusable(client.file_mime, unknown),
                  "neither xdg-mime nor python's mimetypes named a type for %s" % unknown)
            stub_xdg_mime(bin_dir, 'echo "text/plain; charset=utf-8"')
            check("a parameter on the xdg-mime answer is dropped",
                  client.file_mime(unknown), "text/plain")
        finally:
            os.environ["PATH"] = saved



def status_argv(*args):
    """return the argv for a status request"""
    request = {"v": 1, "verb": "status",
               "args": [base64.b64encode(a.encode()).decode() for a in args]}
    try:
        return brokerd.build_argv(request, [])
    except brokerd.Refused as e:
        return "refused: %s" % e


def test_status_json():
    """test the argv built for status with and without --json"""
    check("status alone builds the bare argv", status_argv(), ["status"])
    check("status --json passes through", status_argv("--json"), ["status", "--json"])
    check("status with any other argument is refused by name",
          status_argv("--verbose"), "refused: status takes --json or nothing, got '--verbose'")
    check("status with two arguments is refused by count",
          status_argv("--json", "x"), "refused: status takes 0 to 1 arguments, got 2")


def test_request_instance():
    """test the request instance id checks"""
    check("no id field means instance 0",
          brokerd.request_instance({"v": 1, "verb": "status"}), 0)
    check("an explicit 0 is instance 0",
          brokerd.request_instance({"v": 1, "verb": "status", "id": 0}), 0)
    check("an in-range id is carried through",
          brokerd.request_instance({"v": 1, "verb": "status", "id": 7}), 7)
    check("an id above the range is refused by name",
          refusal(brokerd.request_instance, {"v": 1, "verb": "status", "id": 100}),
          "id must be 0-99, got 100")
    check("a negative id is refused by name",
          refusal(brokerd.request_instance, {"v": 1, "verb": "status", "id": -1}),
          "id must be 0-99, got -1")
    check("a string id is refused by name",
          refusal(brokerd.request_instance, {"v": 1, "verb": "status", "id": "2"}),
          "id must be an integer, got '2'")
    check("a boolean id is refused by name",
          refusal(brokerd.request_instance, {"v": 1, "verb": "status", "id": True}),
          "id must be an integer, got True")

    check("instance 0's inbox is byte-identical to today",
          brokerd.inbox_dir(0), "/run/rhizo/data/rhizo_inbox")
    check("instance 3 gets its own inbox",
          brokerd.inbox_dir(3), "/run/rhizo-3/data/rhizo_inbox")


def sent_line(*args):
    """send a request and parse it"""
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.send_request(b, "status", [], None, *args)
        b.shutdown(socket.SHUT_WR)
        fds = []
        return brokerd.read_request(a, fds)
    finally:
        a.close()
        b.close()


def test_client_sends_the_instance():
    """test the instance id in requests"""
    check("the client resolves no RHIZO_SANDBOX_ID as instance 0",
          client.request_instance({}), 0)
    check("an empty RHIZO_SANDBOX_ID is instance 0 too",
          client.request_instance({"RHIZO_SANDBOX_ID": ""}), 0)
    check("an explicit 0 is instance 0",
          client.request_instance({"RHIZO_SANDBOX_ID": "0"}), 0)
    check("an in-range id is read off the environment",
          client.request_instance({"RHIZO_SANDBOX_ID": "2"}), 2)
    check("an id above the range is refused by name, never defaulted to 0",
          unusable(client.request_instance, {"RHIZO_SANDBOX_ID": "100"}),
          "RHIZO_SANDBOX_ID='100' is out of range -- 0 to 99")
    check("a non-numeric id is refused by name",
          unusable(client.request_instance, {"RHIZO_SANDBOX_ID": "two"}),
          "RHIZO_SANDBOX_ID='two' is not an instance id -- 0 to 99, digits only")
    check("a negative id is refused by name",
          unusable(client.request_instance, {"RHIZO_SANDBOX_ID": "-1"}),
          "RHIZO_SANDBOX_ID='-1' is not an instance id -- 0 to 99, digits only")
    check("an underscore-separated id is refused by name",
          unusable(client.request_instance, {"RHIZO_SANDBOX_ID": "1_0"}),
          "RHIZO_SANDBOX_ID='1_0' is not an instance id -- 0 to 99, digits only")

    bare = sent_line()
    check("a request with no id argument carries no id field",
          json.loads(bare).get("id", "<absent>"), "<absent>")
    check("instance 0 puts the same bytes on the wire as before the field existed",
          sent_line(0), bare)
    check("the daemon reads that line as instance 0",
          brokerd.request_instance(json.loads(bare)), 0)

    carried = sent_line(7)
    check("the id it was given is on the wire", json.loads(carried).get("id"), 7)
    check("and the daemon reads that same id back",
          brokerd.request_instance(json.loads(carried)), 7)


def test_activation_token():
    """test the activation token checks"""
    token = "gnome-shell/rhizo-com.x.desktop/2301-2-host_TIME4051"
    check("the client takes the launcher's token for a launch",
          client.activation_token("launch", {"XDG_ACTIVATION_TOKEN": token}), token)
    check("no token in the environment sends none",
          client.activation_token("launch", {}), None)
    check("a verb other than launch sends none",
          client.activation_token("status", {"XDG_ACTIVATION_TOKEN": token}), None)
    check("a token with a space is left behind, not sent",
          client.activation_token("launch", {"XDG_ACTIVATION_TOKEN": "a b"}), None)

    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.send_request(b, "launch", ["com.x"], None, 0, token)
        b.shutdown(socket.SHUT_WR)
        line = brokerd.read_request(a, [])
    finally:
        a.close()
        b.close()
    request = json.loads(line)
    check("the token is on the wire", request.get("activation_token"), token)
    check("and the daemon reads it back",
          brokerd.request_activation_token(request), token)
    check("a request with no token field carries none",
          brokerd.request_activation_token({"v": 1, "verb": "launch"}), None)
    check("a token on a verb other than launch is refused by name",
          refusal(brokerd.request_activation_token,
                  {"v": 1, "verb": "status", "activation_token": token}),
          "activation_token is for launch only, got it on 'status'")
    for bad in ("a b", "", "x\n", "a;b", "t" * 256, 7):
        check("token %r refused" % (bad,),
              refusal(brokerd.request_activation_token,
                      {"v": 1, "verb": "launch", "activation_token": bad}) is None, False)

    env = brokerd.child_env(3, token, {"PATH": "/usr/bin", "XDG_ACTIVATION_TOKEN": "leftover"})
    check("the CLI runs with the request's token",
          (env.get("XDG_ACTIVATION_TOKEN"), env.get("RHIZO_SANDBOX_ID"), env.get("PATH")),
          (token, "3", "/usr/bin"))
    env = brokerd.child_env(0, None, {"PATH": "/usr/bin", "XDG_ACTIVATION_TOKEN": "leftover"})
    check("with no token the CLI inherits none from the daemon's own environment",
          env.get("XDG_ACTIVATION_TOKEN", "<absent>"), "<absent>")


def test_unreachable_reason():
    """check the reboot hint for a login older than the rhizo membership"""
    denied = PermissionError(13, "Permission denied")
    late = client.unreachable_reason(denied, "deskuser", True, False)
    check("a login older than the account's group membership is told it joined later",
          "deskuser joined group rhizo after this login began" in late, True)
    check("and that a reboot finishes the install", "reboot to finish the install" in late, True)
    check("and is not told it may not be in the group", "may not be in group rhizo" in late, False)
    check("an account outside the group keeps the group hint",
          client.unreachable_reason(denied, "other", False, False),
          "cannot reach /run/rhizo-broker/broker.sock: [Errno 13] Permission denied -- this account may not be in group rhizo")
    check("a login that holds the group keeps the plain refusal",
          "joined group rhizo" in client.unreachable_reason(denied, "deskuser", True, True), False)
    check("a uid with no passwd entry is named instead of raising",
          client.rhizo_membership(4242424), ("uid 4242424", False, False))
    missing = FileNotFoundError(2, "No such file or directory")
    check("a missing socket is not read as a late membership",
          "joined group rhizo" in client.unreachable_reason(missing, "deskuser", True, False), False)


def test_inbox_stage():
    """check the inbox writer refuses a symlinked path"""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "a.apk")
        with open(src, "wb") as f:
            f.write(b"apk bytes")
        real = os.path.join(tmp, "run", "data")
        os.makedirs(os.path.join(real, "rhizo_inbox"))
        inbox_stage.stage(os.path.join(tmp, "run"), "ok.apk", src, None)
        staged = os.path.join(real, "rhizo_inbox", "ok.apk")
        with open(staged, "rb") as f:
            check("a real inbox gets the bytes", f.read(), b"apk bytes")
        check("and mode 0644", os.stat(staged).st_mode & 0o7777, 0o644)
        for linked in ("rhizo_inbox", "data"):
            root = os.path.join(tmp, "link-" + linked)
            target = os.path.join(tmp, "target-" + linked)
            os.makedirs(os.path.join(target, "rhizo_inbox"))
            os.makedirs(os.path.join(root, "data"))
            if linked == "rhizo_inbox":
                os.symlink(os.path.join(target, "rhizo_inbox"), os.path.join(root, "data", "rhizo_inbox"))
                landed = os.path.join(target, "rhizo_inbox")
            else:
                os.rmdir(os.path.join(root, "data"))
                os.symlink(target, os.path.join(root, "data"))
                landed = os.path.join(target, "rhizo_inbox")
            try:
                inbox_stage.stage(root, "x.apk", src, None)
                raised = None
            except OSError as e:
                raised = str(e)
            check("a symlinked %s is refused, naming the step" % linked,
                  raised is not None and "without following a link" in raised, True)
            check("and nothing lands in the link's target", os.listdir(landed), [])


def test_inbox_stage_limits():
    """check the inbox writer's size limits and cleanup"""
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "run")
        inbox = os.path.join(root, "data", "rhizo_inbox")
        os.makedirs(inbox)
        src = os.path.join(tmp, "a.apk")

        def attempt(name, label=None, size=None):
            """stage src and return the error text or None"""
            try:
                inbox_stage.stage(root, name, src, label, size=size)
            except OSError as e:
                return str(e)
            return None

        with open(src, "wb") as f:
            f.write(b"x" * 100)
        check("a source of the checked size copies", (attempt("ok.apk", size=100), os.listdir(inbox)),
              (None, ["ok.apk"]))
        with open(src, "wb") as f:
            f.write(b"x" * 150)
        err = attempt("grown.apk", size=100)
        check("a source that grew past the checked size is refused by name",
              err is not None and "more than the 100 bytes checked" in err, True)
        check("and leaves no file", "grown.apk" in os.listdir(inbox), False)
        with open(src, "wb") as f:
            f.write(b"x" * 40)
        err = attempt("shrunk.apk", size=100)
        check("a source that shrank is refused by name",
              err is not None and "holds 40 bytes, fewer than the 100 checked" in err, True)
        check("and leaves no file", "shrunk.apk" in os.listdir(inbox), False)
        real_set, real_get = os.setxattr, os.getxattr
        os.setxattr = lambda *a, **k: None
        os.getxattr = lambda *a, **k: b"u:object_r:other:s0\0"
        try:
            err = attempt("badlabel.apk", label="u:object_r:rhizo_inbox_file:s0")
        finally:
            os.setxattr, os.getxattr = real_set, real_get
        check("a label that does not read back is refused by name", err is not None and "reads u:object_r:other:s0" in err, True)
        check("and leaves no file", "badlabel.apk" in os.listdir(inbox), False)
        wrapper = ("import os, runpy, sys\n"
                   "real, calls = os.unlink, []\n"
                   "def unlink(path, *a, **k):\n"
                   "    calls.append(path)\n"
                   "    if len(calls) > 1:\n"
                   "        raise PermissionError(1, 'Operation not permitted')\n"
                   "    return real(path, *a, **k)\n"
                   "os.unlink = unlink\n"
                   "os.setxattr = lambda *a, **k: (_ for _ in ()).throw(OSError(95, 'Operation not supported'))\n"
                   "sys.argv = sys.argv[1:]\n"
                   "runpy.run_path(sys.argv[0], run_name='__main__')\n")
        stage_py = os.path.join(HERE, "..", "inbox_stage.py")
        r = subprocess.run([sys.executable, "-c", wrapper, stage_py, root, "stuck.apk", src,
                            "u:object_r:rhizo_inbox_file:s0"], capture_output=True, text=True)
        check("the CLI form prints the first error and the leftover on stderr, exit 1",
              (r.returncode, "cannot stage stuck.apk in the inbox:" in r.stderr, "label stuck.apk" in r.stderr,
               "Operation not supported" in r.stderr, "stuck.apk stays in the inbox: [Errno 1] Operation not permitted" in r.stderr),
              (1, True, True, True, True))
        if "stuck.apk" in os.listdir(inbox):
            os.unlink(os.path.join(inbox, "stuck.apk"))
        real_write, real_unlink, unlinks = inbox_stage.write_labeled, os.unlink, []

        class Interrupted(Exception):
            """an error the callers do not catch"""

        def interrupted(*a, **k):
            """raise an error that is not an OSError"""
            raise Interrupted("stopped mid-copy")

        def cleanup_fails(path, *a, **k):
            """pass the pre-clean unlink, fail the cleanup"""
            unlinks.append(path)
            if len(unlinks) > 1:
                raise PermissionError(1, "Operation not permitted")
            return real_unlink(path, *a, **k)

        inbox_stage.write_labeled, os.unlink = interrupted, cleanup_fails
        try:
            inbox_stage.stage(root, "halted.apk", src, None)
            notes = None
        except Interrupted as e:
            notes = getattr(e, "__notes__", [])
        finally:
            inbox_stage.write_labeled, os.unlink = real_write, real_unlink
        check("an error that is not an OSError still reports the file its failed cleanup left",
              notes is not None and any("halted.apk stays in the inbox: [Errno 1] Operation not permitted" in n
                                        for n in notes), True)
        if "halted.apk" in os.listdir(inbox):
            os.unlink(os.path.join(inbox, "halted.apk"))
        mode_file = os.path.join(tmp, "mode")
        with open(mode_file, "w") as f:
            f.write("namespace\n")
        real_set, real_unlink, unlinks = os.setxattr, os.unlink, []

        def second_unlink_fails(path, *a, **k):
            """let the pre-clean unlink pass and fail the cleanup one"""
            unlinks.append(path)
            if len(unlinks) > 1:
                raise PermissionError(1, "Operation not permitted")
            return real_unlink(path, *a, **k)

        os.setxattr = lambda *a, **k: (_ for _ in ()).throw(OSError(95, "Operation not supported"))
        os.unlink = second_unlink_fails
        before = set(os.listdir(inbox))
        fd = os.open(src, os.O_RDONLY)
        try:
            text = refusal(brokerd.materialize_apk, fd, root, mode_file)
        finally:
            os.close(fd)
            os.unlink, os.setxattr = real_unlink, real_set
        check("the broker's refusal names the step and the leftover",
              (text is not None and text.startswith("cannot stage "), "Operation not supported" in (text or ""),
               "stays in the inbox: [Errno 1] Operation not permitted" in (text or "")), (True, True, True))
        left = sorted(set(os.listdir(inbox)) - before)
        check("the broker left exactly the one file its refusal names",
              (len(left), bool(left) and ("stage %s " % left[0]) in (text or "")), (1, True))
        for leftover in left:
            real_unlink(os.path.join(inbox, leftover))


def test_materialize_label():
    """check the inbox file label in namespace mode"""
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "run")
        os.makedirs(os.path.join(root, "data", "rhizo_inbox"))
        apk = os.path.join(tmp, "a.apk")
        with open(apk, "wb") as f:
            f.write(b"apk bytes")
        mode_file = os.path.join(tmp, "mode")
        calls = []
        real_set, real_get = os.setxattr, os.getxattr
        os.setxattr = lambda path, name, value, *a, **k: calls.append((name, value))
        os.getxattr = lambda path, name, *a, **k: calls[-1][1]
        try:
            for mode, want in (("namespace", [("security.selinux", b"u:object_r:rhizo_inbox_file:s0\0")]),
                               ("host", [])):
                with open(mode_file, "w") as f:
                    f.write(mode + "\n")
                del calls[:]
                fd = os.open(apk, os.O_RDONLY)
                try:
                    sandbox = brokerd.materialize_apk(fd, root, mode_file)
                finally:
                    os.close(fd)
                check("%s mode: the inbox file's label writes" % mode, calls, want)
                staged = os.path.join(root, "data", "rhizo_inbox", os.path.basename(sandbox))
                check("%s mode: the apk lands in the inbox" % mode, os.path.isfile(staged), True)
            sizes, real_stage = [], brokerd.inbox_stage.stage
            brokerd.inbox_stage.stage = lambda *a, **k: (sizes.append(k.get("size")), real_stage(*a, **k))[1]
            try:
                fd = os.open(apk, os.O_RDONLY)
                try:
                    brokerd.materialize_apk(fd, root, mode_file)
                finally:
                    os.close(fd)
            finally:
                brokerd.inbox_stage.stage = real_stage
            check("the broker hands stage the size it checked", sizes, [9])
            fd = os.open(apk, os.O_RDONLY)
            try:
                missing = refusal(brokerd.materialize_apk, fd, root, os.path.join(tmp, "absent"))
            finally:
                os.close(fd)
            check("an unreadable mode file refuses the install", missing is not None
                  and "cannot read the SELinux mode" in missing, True)
        finally:
            os.setxattr, os.getxattr = real_set, real_get


test_inbox_stage()
test_inbox_stage_limits()
test_materialize_label()
test_activation_token()
test_client_launch_arg()
test_client_sends_the_instance()
test_client_resolves_as_the_user()
test_client_types_the_file()
test_launch_targets()
test_launch_mime()
test_package_names()
test_ancillary()
test_status_json()
test_request_instance()
test_unreachable_reason()
print("%d checks failed" % len(failures))
sys.exit(1 if failures else 0)
