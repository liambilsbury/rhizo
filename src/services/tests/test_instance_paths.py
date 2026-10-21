#!/usr/bin/env python3
import errno
import importlib.util
import os
import socket
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))

failures = []
checked = []


def check(name, got, want):
    """record and print a named check"""
    checked.append(name)
    if got == want:
        print("ok   %s" % name)
    else:
        print("FAIL %s: got %r, want %r" % (name, got, want))
        failures.append(name)


def load_at(module_name, relpath, sandbox_id):
    """load a module under a sandbox id"""
    before = os.environ.get("RHIZO_SANDBOX_ID")
    if sandbox_id is None:
        os.environ.pop("RHIZO_SANDBOX_ID", None)
    else:
        os.environ["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    try:
        spec = importlib.util.spec_from_file_location(
            "%s_at_%s" % (module_name, sandbox_id), os.path.join(HOST, relpath))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if before is None:
            os.environ.pop("RHIZO_SANDBOX_ID", None)
        else:
            os.environ["RHIZO_SANDBOX_ID"] = before


def test_keymapd_paths():
    """test keymapd paths at each sandbox id"""
    absent = load_at("keymapd", "keymapd/keymapd.py", None)
    zero = load_at("keymapd", "keymapd/keymapd.py", 0)
    two = load_at("keymapd", "keymapd/keymapd.py", 2)
    check("keymapd HOST_DATA at id 0", zero.HOST_DATA, "/run/rhizo/data/")
    check("keymapd HOST_DATA with no id in the environment",
          absent.HOST_DATA, "/run/rhizo/data/")
    check("keymapd CONTROL_DIR at id 0", zero.CONTROL_DIR, "/run/rhizo/data/rhizo_control")
    check("keymapd CONTROL_OUT at id 0", zero.CONTROL_OUT,
          "/run/rhizo/data/rhizo_control/control.out")
    check("keymapd CONTROL_FIFO at id 0", zero.CONTROL_FIFO,
          "/run/rhizo/data/rhizo_control/control")
    check("keymapd HOST_DATA at id 2", two.HOST_DATA, "/run/rhizo-2/data/")
    check("keymapd CONTROL_OUT at id 2", two.CONTROL_OUT,
          "/run/rhizo-2/data/rhizo_control/control.out")
    check("keymapd CONTROL_FIFO at id 2", two.CONTROL_FIFO,
          "/run/rhizo-2/data/rhizo_control/control")
    check("keymapd SANDBOX_DATA is the sandbox's own path at both ids",
          (zero.SANDBOX_DATA, two.SANDBOX_DATA), ("/data/", "/data/"))


def test_displayd_paths():
    """test displayd paths at ids 0 and 2"""
    absent = load_at("displayd", "displayd/displayd.py", None)
    zero = load_at("displayd", "displayd/displayd.py", 0)
    two = load_at("displayd", "displayd/displayd.py", 2)
    check("displayd CONTROL_OUT at id 0", zero.CONTROL_OUT,
          "/run/rhizo/data/rhizo_control/control.out")
    check("displayd CONTROL_OUT with no id in the environment", absent.CONTROL_OUT,
          "/run/rhizo/data/rhizo_control/control.out")
    check("displayd PROBE_SOCK at id 0", zero.PROBE_SOCK,
          "/run/rhizo/data/local/tmp/rhizo-probe.sock")
    check("displayd INIT_PID_FILE at id 0", zero.INIT_PID_FILE, "/root/.rhizo_init_pid")
    check("displayd CONTROL_OUT at id 2", two.CONTROL_OUT,
          "/run/rhizo-2/data/rhizo_control/control.out")
    check("displayd PROBE_SOCK at id 2", two.PROBE_SOCK,
          "/run/rhizo-2/data/local/tmp/rhizo-probe.sock")
    check("displayd INIT_PID_FILE at id 2", two.INIT_PID_FILE, "/root/.rhizo_init_pid-2")
    check("displayd CONTROL_IN is the sandbox's own path at both ids",
          (zero.CONTROL_IN, two.CONTROL_IN),
          ("/data/rhizo_control/control", "/data/rhizo_control/control"))


def test_displayd_init_pid_is_this_instance_s():
    """test init_pid with a missing pid file"""
    two = load_at("displayd", "displayd/displayd.py", 2)
    two.INIT_PID_FILE = os.path.join(HERE, "no-such-init-pid-file")
    check("displayd init_pid at id 2 with no pid file", two.init_pid(), None)


def test_deskd_paths():
    """check deskd paths for no id, id 0 and id 2"""
    absent = load_at("deskd", "deskbridge/deskd.py", None)
    zero = load_at("deskd", "deskbridge/deskd.py", 0)
    two = load_at("deskd", "deskbridge/deskd.py", 2)
    check("deskd HOST_DATA at id 0", zero.HOST_DATA, "/run/rhizo/data/")
    check("deskd HOST_DATA with no id in the environment", absent.HOST_DATA, "/run/rhizo/data/")
    check("deskd CONTROL_DIR at id 0", zero.CONTROL_DIR, "/run/rhizo/data/rhizo_control")
    check("deskd CONTROL_FIFO at id 0", zero.CONTROL_FIFO,
          "/run/rhizo/data/rhizo_control/control")
    check("deskd LAUNCH_LOG at id 0", zero.LAUNCH_LOG, "/run/rhizo-launch/rhizo-launch.log")
    check("deskd HOST_DATA at id 2", two.HOST_DATA, "/run/rhizo-2/data/")
    check("deskd CONTROL_FIFO at id 2", two.CONTROL_FIFO,
          "/run/rhizo-2/data/rhizo_control/control")
    check("deskd LAUNCH_LOG at id 2", two.LAUNCH_LOG,
          "/run/rhizo-launch-2/rhizo-launch.log")


def test_deskd_drop_paths_stay_inside_this_instance_s_tree():
    """test resolve_drop_path at id 2"""
    two = load_at("deskd", "deskbridge/deskd.py", 2)
    check("deskd resolves a drop into this instance's tree",
          two.resolve_drop_path("/data/local/tmp/x"), "/run/rhizo-2/data/local/tmp/x")
    check("deskd still refuses a drop that escapes it",
          two.resolve_drop_path("/data/../../etc/shadow"), None)


def test_server_idle_names():
    """check the idle service names for no id, id 0 and id 2"""
    absent = load_at("idle", "server-idle/server-idle.py", None)
    zero = load_at("idle", "server-idle/server-idle.py", 0)
    two = load_at("idle", "server-idle/server-idle.py", 2)
    check("idle timer unit at id 0", zero.TIMER_UNIT, "rhizo-server-idle-stop")
    check("idle timer unit with no id in the environment",
          absent.TIMER_UNIT, "rhizo-server-idle-stop")
    check("idle androidd unit at id 0", zero.ANDROIDD_UNIT, "androidd.service")
    check("idle guest address at id 0", zero.ADB_GUEST_ADDR, "192.168.100.50")
    check("idle timer unit at id 2", two.TIMER_UNIT, "rhizo-server-idle-stop-2")
    check("idle androidd unit at id 2", two.ANDROIDD_UNIT, "androidd@2.service")
    check("idle guest address at id 2", two.ADB_GUEST_ADDR, "192.168.102.50")


def ct_message(kind, src, sport, proto=6, dport=40000, ct_id=7, flags=None, tcp_state=None):
    """return a ctnetlink message"""
    def nla(attr, payload, nested=False):
        """return a netlink attribute, padded"""
        body = struct.pack("=HH", 4 + len(payload), attr | (0x8000 if nested else 0)) + payload
        return body + bytes(-len(body) % 4)
    ip = nla(1, nla(1, socket.inet_aton(src)) + nla(2, socket.inet_aton("10.0.0.9")), nested=True)
    pr = nla(2, nla(1, bytes([proto])) + nla(2, struct.pack("!H", sport)) + nla(3, struct.pack("!H", dport)), nested=True)
    orig = nla(1, nla(1, nla(1, socket.inet_aton("10.0.0.9")), nested=True), nested=True)
    payload = struct.pack("=BBH", 2, 0, 0) + orig + nla(2, ip + pr, nested=True) + nla(12, struct.pack("!I", ct_id))
    if tcp_state is not None:
        payload += nla(4, nla(1, nla(1, bytes([tcp_state])), nested=True), nested=True)
    if flags is None:
        flags = 0x400 | 0x200 if kind == 1 << 8 else 0
    return struct.pack("=IHHII", 16 + len(payload), kind, flags, 0, 0) + payload


def idle_events(sandbox_id, messages):
    """return what conntrack_events yields for messages at sandbox_id"""
    module = load_at("idle", "server-idle/server-idle.py", sandbox_id)

    class FakeSock:
        """Socket holding canned conntrack messages"""
        def __init__(self):
            """store the joined messages and end of stream"""
            self.chunks = [b"".join(messages), b""]

        def recv(self, size):
            """return the next chunk"""
            return self.chunks.pop(0)

    return module, list(module.conntrack_events(FakeSock()))


def test_conntrack_filter_is_scoped_on_the_reply_tuple():
    """test the ctnetlink event filter"""
    new, delete = 1 << 8 | 0, 1 << 8 | 2
    module, got = idle_events(0, [ct_message(new, "192.168.100.50", 5555), ct_message(delete, "192.168.100.50", 5555)])
    check("idle detector counts a NEW and a DESTROY on the adb reply tuple at id 0", got,
          [("NEW", ("10.0.0.9", 40000, 7)), ("DESTROY", ("10.0.0.9", 40000, 7))])
    check("idle detector subscribes to the NEW, UPDATE and DESTROY groups",
          module.NF_NETLINK_CONNTRACK_NEW | module.NF_NETLINK_CONNTRACK_UPDATE | module.NF_NETLINK_CONNTRACK_DESTROY, 7)
    time_wait, close, established = 7, 8, 3
    _m, got = idle_events(0, [ct_message(new, "192.168.100.50", 5555, flags=0, tcp_state=established),
                              ct_message(new, "192.168.100.50", 5555, flags=0, tcp_state=time_wait),
                              ct_message(new, "192.168.100.50", 5555, flags=0, tcp_state=close),
                              ct_message(new, "192.168.100.50", 5555, flags=0)])
    check("an update into time_wait or close is a CLOSE, an established or stateless update nothing",
          [e for e, _k in got], ["CLOSE", "CLOSE"])
    _m, got = idle_events(0, [ct_message(new, "192.168.100.50", 5556), ct_message(new, "192.168.101.50", 5555),
                              ct_message(new, "192.168.100.50", 5555, proto=17)])
    check("idle detector ignores another port, another sandbox's address and udp", got, [])
    _m, got = idle_events(2, [ct_message(new, "192.168.102.50", 5555), ct_message(new, "192.168.100.50", 5555)])
    check("idle detector scopes on the reply tuple's source address at id 2", [e for e, _k in got], ["NEW"])


def test_conntrack_overrun_is_named_and_resynced():
    """test the ENOBUFS overrun path"""
    new = 1 << 8 | 0
    module = load_at("idle", "server-idle/server-idle.py", 0)

    class OverrunSock:
        """Socket that overruns once"""
        def __init__(self):
            """store the overrun, a message and the end"""
            self.steps = [OSError(errno.ENOBUFS, "No buffer space available"),
                          ct_message(new, "192.168.100.50", 5555), b""]

        def recv(self, size):
            """return or raise the next step"""
            step = self.steps.pop(0)
            if isinstance(step, Exception):
                raise step
            return step

    check("an ENOBUFS recv yields OVERRUN and the stream goes on",
          [e for e, _k in module.conntrack_events(OverrunSock())], ["OVERRUN", "NEW"])

    class DumpSock:
        """Socket answering a table dump"""
        def __init__(self, replies):
            """store the replies"""
            self.replies, self.sent = replies, []

        def send(self, data):
            """record the request"""
            self.sent.append(data)

        def recv(self, size):
            """return the next reply"""
            return self.replies.pop(0)

    done = struct.pack("=IHHII", 20, 3, 2, 1, 0) + bytes(4)
    dump = DumpSock([ct_message(new, "192.168.100.50", 5555, dport=41000, ct_id=1)
                     + ct_message(new, "192.168.101.50", 5555, ct_id=2), done])
    check("the table dump keys the adb session's entries only", module.conntrack_sessions(dump),
          {("10.0.0.9", 41000, 1)})
    dump = DumpSock([ct_message(new, "192.168.100.50", 5555, dport=41000, ct_id=1, flags=2, tcp_state=3)
                     + ct_message(new, "192.168.100.50", 5555, dport=41001, ct_id=3, flags=2, tcp_state=7), done])
    check("the table dump leaves out an adb entry lingering in time_wait", module.conntrack_sessions(dump),
          {("10.0.0.9", 41000, 1)})
    check("the table dump asks for a dump of the conntrack table",
          struct.unpack_from("=HH", dump.sent[0], 4), (1 << 8 | 1, 1 | 0x300))
    error = struct.pack("=IHHII", 36, 2, 0, 1, 0) + struct.pack("=i", -errno.EPERM) + bytes(16)
    try:
        module.conntrack_sessions(DumpSock([error]))
        raised = None
    except OSError as e:
        raised = e.errno
    check("a dump error is raised by its errno", raised, errno.EPERM)

    timer = []
    module.arm_timer = lambda s: timer.append(("arm", s))
    module.cancel_timer = lambda: timer.append(("cancel",))
    stale, a, b = ("10.0.0.9", 40001, 11), ("10.0.0.9", 40002, 12), ("10.0.0.9", 40003, 13)

    sessions = module.Sessions({stale})
    module.handle("OVERRUN", None, sessions, 600, lambda: {stale})
    check("an overrun does not count an entry from before the start", (sessions.counted, timer[-1]), (set(), ("arm", 600)))
    module.handle("DESTROY", stale, sessions, 600, lambda: set())
    check("a DESTROY of an uncounted entry arms nothing more", len(timer), 1)

    sessions = module.Sessions({stale})
    module.handle("OVERRUN", None, sessions, 600, lambda: {stale, a})
    check("an overrun counts an entry opened since the start", (sessions.counted, timer[-1]), ({a}, ("cancel",)))
    module.handle("NEW", a, sessions, 600, lambda: set())
    check("a NEW queued behind the recount does not count its session twice", sessions.counted, {a})
    module.handle("DESTROY", a, sessions, 600, lambda: set())
    check("that session's DESTROY arms the timer", (sessions.counted, timer[-1]), (set(), ("arm", 600)))

    sessions = module.Sessions(set())
    module.handle("NEW", a, sessions, 600, lambda: set())
    module.handle("NEW", b, sessions, 600, lambda: set())
    module.handle("OVERRUN", None, sessions, 600, lambda: {b})
    check("an overrun drops a session whose DESTROY was lost", sessions.counted, {b})
    module.handle("DESTROY", a, sessions, 600, lambda: set())
    check("the lost session's DESTROY queued behind the recount arms nothing", timer[-1], ("cancel",))
    module.handle("DESTROY", b, sessions, 600, lambda: set())
    check("the last counted session's DESTROY arms the timer", timer[-1], ("arm", 600))

    sessions = module.Sessions(set())
    module.handle("NEW", a, sessions, 600, lambda: set())
    module.handle("NEW", b, sessions, 600, lambda: set())
    module.handle("CLOSE", a, sessions, 600, lambda: set())
    check("a CLOSE with another session still counted arms nothing", timer[-1], ("cancel",))
    module.handle("CLOSE", b, sessions, 600, lambda: set())
    check("the last counted session's CLOSE arms the timer", (sessions.counted, timer[-1]), (set(), ("arm", 600)))
    armed = len(timer)
    module.handle("DESTROY", b, sessions, 600, lambda: set())
    check("that session's later DESTROY arms nothing more", len(timer), armed)

    reused = ("10.0.0.9", 40001, 21)
    sessions = module.Sessions({stale})
    module.handle("OVERRUN", None, sessions, 600, lambda: {reused})
    check("a new conntrack id on a reused tuple counts as a new session", sessions.counted, {reused})
    check("the start line names the uncounted entries",
          module.start_line(3).startswith("started this run's own session count at 0 -- the 3 adb entries"), True)


def test_conntrack_overrun_drops_the_stale_backlog():
    """test the drain before an overrun's re-read"""
    import inspect
    new = 1 << 8 | 0
    module = load_at("idle", "server-idle/server-idle.py", 0)

    class BacklogSock:
        """Socket overrunning over a stale backlog"""
        def __init__(self, steps):
            """store the steps"""
            self.steps = steps

        def recv(self, size, flags=0):
            """return or raise the next step"""
            if not self.steps:
                if flags & socket.MSG_DONTWAIT:
                    raise BlockingIOError(errno.EAGAIN, "empty")
                return b""
            step = self.steps.pop(0)
            if isinstance(step, Exception):
                raise step
            return step

    timer = []
    module.arm_timer = lambda s: timer.append(("arm", s))
    module.cancel_timer = lambda: timer.append(("cancel",))
    module.read_table = lambda: set()
    stale = ct_message(new, "192.168.100.50", 5555, dport=41000, ct_id=5)
    sock = BacklogSock([OSError(errno.ENOBUFS, "No buffer space available"), stale])
    sessions = module.Sessions(set())
    reread = getattr(module, "reread_table", None)
    if reread is None:
        check("the detector has a reread_table that drains before the dump", False, True)
        return
    for event, key in module.conntrack_events(sock):
        module.handle(event, key, sessions, 600, lambda: reread(sock))
    check("a NEW queued before an overrun goes with the drained backlog", (sessions.counted, timer[-1]), (set(), ("arm", 600)))
    check("main re-reads the table through the drain", "reread_table(sock)" in inspect.getsource(module.main), True)

    live = ("10.0.0.9", 40009, 9)
    sessions = module.Sessions({live})
    module.handle("NEW", live, sessions, 600, lambda: set())
    module.handle("OVERRUN", None, sessions, 600, lambda: {live})
    check("a session opened during the start's dump stays counted across a resync", sessions.counted, {live})

    start = getattr(module, "start_sessions", None)
    if start is None:
        check("the detector has a start_sessions that compares two dumps", False, True)
        return
    old, gone = ("10.0.0.7", 40007, 7), ("10.0.0.8", 40008, 8)
    sessions = start({old, gone}, {old, live})
    check("two start dumps: the second's new entries count, the shared ones stay uncounted",
          (sessions.before, sessions.counted), ({old}, {live}))
    timer.clear()
    module.handle("OVERRUN", None, sessions, 600, lambda: {old, live})
    check("a session opened between the bind and the start's dump survives an overrun that drains its NEW",
          (sessions.counted, timer[-1]), ({live}, ("cancel",)))
    src = inspect.getsource(module.main)
    order = [src.find(s) for s in ("first = read_table()", "sock.bind(", "second = read_table()")]
    check("main dumps the table before the bind and again after it", -1 not in order and order == sorted(order), True)


def test_start_scripts_are_instance_zero_only_now():
    """run the start scripts at id 2"""
    for argv, unit, bare in (
            (["start-unit.sh", "keymapd"], "rhizo-keymapd.service", "\tTABLE_UNIT\t"),
            (["start-unit.sh", "displayd"], "rhizo-displayd.service", "\tTABLE_UNIT\t"),
            (["start-deskd.sh"], "rhizo-deskd.service", "UNIT=TABLE_UNIT"),
    ):
        script = " ".join(argv)
        path = os.path.join(REPO, "test", "vm", "start", argv[0])
        text = open(path).read()
        check("%s names the bare unit %s, not a per-instance derivation" % (script, unit),
              bare.replace("TABLE_UNIT", unit) in text, True)
        check("%s no longer derives a per-instance name from SANDBOX_ID" % script,
              "SBIDVALUE" in text or "UNITNAME" in text, False)
        proc = subprocess.run([path] + argv[1:], capture_output=True, text=True,
                              env=dict(os.environ, RHIZO_SANDBOX_ID="2"))
        check("%s refuses above instance 0" % script, proc.returncode, 1)
        check("%s says why it refused" % script,
              "instance-0-only" in proc.stdout + proc.stderr, True)


def test_start_audio_is_instance_zero_only():
    """test start-audio.sh at instance ids 0 and 2"""
    proc = subprocess.run([os.path.join(REPO, "test", "vm", "start", "start-audio.sh")],
                          capture_output=True, text=True,
                          env=dict(os.environ, RHIZO_SANDBOX_ID="2"))
    check("start-audio.sh refuses above instance 0", proc.returncode, 1)
    check("start-audio.sh says why it refused",
          "instance-0-only" in proc.stdout + proc.stderr, True)
    conf = os.path.join(HERE, "audio-off-%d.conf" % os.getpid())
    with open(conf, "w") as handle:
        handle.write("[audio]\nout = false\n")
    try:
        proc = subprocess.run([os.path.join(REPO, "test", "vm", "start", "start-audio.sh")],
                              capture_output=True, text=True,
                              env=dict(os.environ, RHIZO_SANDBOX_ID="0",
                                       RHIZO_POLICY_CONF=conf))
    finally:
        os.unlink(conf)
    check("start-audio.sh at id 0 reaches its capability gate", proc.returncode, 0)
    check("start-audio.sh at id 0 stops for the capability, not the instance",
          "audio.out is off" in proc.stdout + proc.stderr, True)


def test_every_definition_has_a_docstring():
    """test this file's functions and classes for docstrings"""
    import ast
    with open(os.path.abspath(__file__)) as f:
        tree = ast.parse(f.read())
    missing = ["%s:%d" % (n.name, n.lineno) for n in ast.walk(tree)
               if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and ast.get_docstring(n) is None]
    check("every function and class here has a docstring", missing, [])


def test_start_audio_stops_the_daemon_by_unit_not_by_name():
    """check start-audio.sh for pkill and systemctl"""
    code = [line for line in open(os.path.join(REPO, "test", "vm", "start", "start-audio.sh")).read().splitlines()
            if not line.lstrip().startswith("#")]
    check("start-audio.sh no longer kills rhizo-audiod by name",
          [line for line in code if "pkill -9 rhizo-audiod" in line], [])
    check("start-audio.sh stops its own unit instead",
          any("systemctl stop $UNIT" in line for line in code), True)


for fn in (
    test_keymapd_paths,
    test_displayd_paths,
    test_displayd_init_pid_is_this_instance_s,
    test_deskd_paths,
    test_deskd_drop_paths_stay_inside_this_instance_s_tree,
    test_server_idle_names,
    test_conntrack_filter_is_scoped_on_the_reply_tuple,
    test_conntrack_overrun_is_named_and_resynced,
    test_conntrack_overrun_drops_the_stale_backlog,
    test_start_scripts_are_instance_zero_only_now,
    test_start_audio_is_instance_zero_only,
    test_start_audio_stops_the_daemon_by_unit_not_by_name,
    test_every_definition_has_a_docstring,
):
    fn()

print("%d checks run, %d failed" % (len(checked), len(failures)))
sys.exit(1 if failures else 0)
