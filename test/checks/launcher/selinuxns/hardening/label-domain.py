#!/usr/bin/env python3
import ast, contextlib, ctypes, io, os, select, signal, socket, struct, subprocess, sys
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-label-domain")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_policy
    from sandbox import selinux_ns as ns
    from sandbox import guest_files

CONTEXT = b"u:r:rhizo_input_label:s0"
DOMAIN = "rhizo_input_label"
KERNEL = b"u:r:kernel:s0"
ZERO_CAPS = "0000000000000000"
LSM_ID_SELINUX, NR_SET, NR_GET, ATTR_CURRENT = 101, 460, 459, 100
SERVICE_GRANTS = {
    ("kernel", "unix_stream_socket"): {"read", "write"},
    ("rootfs", "dir"): {"search"},
    ("device", "dir"): {"search"},
    ("input_device", "dir"): {"search"},
    ("input_device", "chr_file"): {"getattr"},
    ("rhizo_host_device", "chr_file"): {"getattr", "relabelfrom"},
    ("hidraw_device", "chr_file"): {"getattr", "relabelto"},
    ("proc", "filesystem"): {"getattr"},
    ("proc", "dir"): {"search"},
    ("proc", "lnk_file"): {"read"},
    ("self", "dir"): {"search"},
    ("self", "lnk_file"): {"read"},
}
PIN = ["validatetrans", "chr_file", ["or", ["not", ["eq", "t3", DOMAIN]], ["eq", "t2", "hidraw_device"]]]
bad = []


def section(name, fn):
    """record a section's findings"""
    try:
        for f in fn() or []:
            bad.append((name,) + (f if isinstance(f, tuple) else (f,)))
    except Exception as e:
        bad.append((name, "raised", repr(e)))


def lsm_entry(context):
    """return context as a SELinux lsm_ctx struct"""
    ctx = context + b"\0"
    return struct.pack("<QQQQ", LSM_ID_SELINUX, 0, 32 + len(ctx), len(ctx)) + ctx


class FakeSys:
    """Fake LSM attribute syscalls"""

    def __init__(self, set_errno=0, readback=CONTEXT, get_errno=0):
        """store the fake syscall results"""
        self.set_errno, self.readback, self.get_errno, self.calls = set_errno, readback, get_errno, []

    def syscall(self, nr, *args):
        """return the fake result for a syscall"""
        nr = getattr(nr, "value", nr)
        if nr == NR_SET:
            attr, buf, size, flags = args
            size = getattr(size, "value", size)
            self.calls.append(("set", getattr(attr, "value", attr), bytes(buf.raw[:size]), size,
                               getattr(flags, "value", flags)))
            if self.set_errno:
                ctypes.set_errno(self.set_errno)
                return -1
            return 0
        if nr == NR_GET:
            attr, buf, size_ref, flags = args
            self.calls.append(("get", getattr(attr, "value", attr)))
            if self.get_errno:
                ctypes.set_errno(self.get_errno)
                return -1
            data = lsm_entry(self.readback)
            ctypes.memmove(buf, data, len(data))
            size_ref._obj.value = len(data)
            return 1
        raise AssertionError(f"unexpected syscall {nr}")


def with_sys(fake, fn):
    """call fn under a fake ns._libc"""
    saved = ns._libc
    ns._libc = fake
    try:
        return fn()
    finally:
        ns._libc = saved


def enter_findings():
    """check enter_label_domain's results"""
    out = []
    if getattr(ns, "LABEL_SERVICE_CONTEXT", None) != CONTEXT:
        out.append(("the label service's context", CONTEXT, getattr(ns, "LABEL_SERVICE_CONTEXT", None)))
    fake = FakeSys()
    got = with_sys(fake, ns.enter_label_domain)
    if got != "":
        out.append(("a set and exact read-back of the label service's context failed", got))
    sets = [c for c in fake.calls if c[0] == "set"]
    want = lsm_entry(CONTEXT)
    if [c[1:] for c in sets] != [(ATTR_CURRENT, want, len(want), 0)]:
        out.append(("one lsm_set_self_attr(LSM_ATTR_CURRENT) carrying the context and its NUL", sets))
    if not any(c[0] == "get" and c[1] == ATTR_CURRENT for c in fake.calls[len(sets):]):
        out.append(("the context was not read back through lsm_get_self_attr after the set", fake.calls))
    got = with_sys(FakeSys(set_errno=13), ns.enter_label_domain)
    if got != "setcon:13":
        out.append(("a refused set", "setcon:13", got))
    for readback in (KERNEL, CONTEXT + b"x", b"u:r:rhizo_input_label"):
        got = with_sys(FakeSys(readback=readback), ns.enter_label_domain)
        if got != "setcon-readback:" + readback.decode():
            out.append(("a read-back of", readback, "setcon-readback:" + readback.decode(), got))
    got = with_sys(FakeSys(get_errno=22), ns.enter_label_domain)
    if not got.startswith("setcon-readback:") or "22" not in got:
        out.append(("an unreadable context", "setcon-readback:...22", got))
    return out


def wait_exit(pid):
    """wait for pid to exit"""
    pidfd = os.pidfd_open(pid)
    exited, _, _ = select.select([pidfd], [], [], 10)
    os.close(pidfd)
    if not exited:
        os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    return bool(exited), os.waitstatus_to_exitcode(status)


def recv_within(sock, seconds=10):
    """return the next message on sock"""
    ready, _, _ = select.select([sock], [], [], seconds)
    return sock.recv(512) if ready else b"<nothing in %ds>" % seconds


def status_of(pid):
    """return /proc/<pid>/status as a dict"""
    return {k: v.strip() for k, v in (l.split(":\t", 1) for l in open(f"/proc/{pid}/status").read().splitlines()
                                      if ":\t" in l)}


def dropped_before_entry():
    """return an error unless privileges are dropped"""
    st = status_of("self")
    got = {k: st.get(k) for k in ("CapEff", "CapPrm", "CapBnd", "NoNewPrivs")}
    want = dict.fromkeys(("CapEff", "CapPrm", "CapBnd"), ZERO_CAPS)
    want["NoNewPrivs"] = "1"
    return "" if got == want else f"order:{got}"


def service_process_cases():
    """check the forked label service in each case"""
    out = []
    last_cap = int(open("/proc/sys/kernel/cap_last_cap").read())
    if status_of("self").get("CapBnd", ZERO_CAPS) == ZERO_CAPS:
        return [("the user-namespace run holds no capability to drop",)]
    real_libc, real_enter, real_sys = ns.libc, getattr(ns, "enter_label_domain", None), ns._libc
    for case in ("serves", "setcon-fails", "readback-wrong", "pair-closed"):
        g_end, svc_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        mnt_r, mnt_w = os.pipe()
        release = socket.socketpair()

        class FakeLibc:
            """Fake libc with a setns"""

            def setns(self, fd, flags):
                """fake setns into the mount namespace"""
                return 0 if (fd, flags) == (mnt_r, ns.CLONE_NEWNS) else -1

            def __getattr__(self, name):
                """return the real libc function"""
                return getattr(real_libc, name)

        ns.libc = FakeLibc()
        if case in ("serves", "pair-closed"):
            ns.enter_label_domain = dropped_before_entry
        if case == "readback-wrong":
            ns._libc = FakeSys(readback=KERNEL)
        try:
            pid = ns.start_label_service(svc_end, mnt_r, last_cap, release)
        finally:
            ns.libc, ns._libc = real_libc, real_sys
            if real_enter is not None:
                ns.enter_label_domain = real_enter
        if case == "serves":
            early = recv_within(g_end, 2)
            if early != b"<nothing in 2s>":
                out.append(("serves", "a service not yet released sends nothing", early))
            release[0].send(b"1")
        if case == "pair-closed":
            release[0].close()
        first = recv_within(g_end)
        if case == "pair-closed":
            if first == b"ready":
                out.append((case, "a service whose release pair closed never reports ready", first))
        elif case == "serves":
            if first != b"ready":
                out.append(("serves", "the service's first message after a verified domain entry", b"ready", first))
            else:
                g_end.send(b"/dev/input/event9 13:73 1")
                answer = recv_within(g_end)
                if not answer.startswith((b"failed:", b"refused:")):
                    out.append(("serves", "the service's answer to a request for an absent node", answer))
        elif case == "setcon-fails":
            if not first.startswith(b"error:setcon:"):
                out.append(("setcon-fails", "a service whose context set fails sends", b"error:setcon:...", first))
        elif first != b"error:setcon-readback:" + KERNEL:
            out.append(("readback-wrong", "a service reading back kernel sends", b"error:setcon-readback:" + KERNEL,
                        first))
        if case != "serves":
            try:
                g_end.send(b"/dev/input/event9 13:73 1")
                extra = recv_within(g_end, 2)
            except OSError:
                extra = b""
            if extra.startswith((b"failed:", b"refused:", b"label ")):
                out.append((case, "a service that never entered its domain answered a request", extra))
        g_end.close()
        exited, code = wait_exit(pid)
        if not exited:
            out.append((case, "the service did not exit within 10s"))
        elif (code == 0) != (case == "serves"):
            out.append((case, "the service's exit code", code))
        release[0].close()
        for fd in (mnt_r, mnt_w):
            os.close(fd)
    return out


NOT_RUN = []


def service_process_findings():
    """run the forked-service cases in a user namespace"""
    probe = subprocess.run(["unshare", "-r", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        NOT_RUN.append(f"the forked-service cases -- unshare -r refused: {probe.stderr.strip() or probe.returncode}")
        return []
    r = subprocess.run(["unshare", "-r", sys.executable, os.path.abspath(__file__), "--service-process"],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0 or "SERVICE-PROCESS-DONE" not in r.stdout:
        return [("the user-namespace run did not finish", r.returncode, (r.stdout + r.stderr)[-600:])]
    return [tuple(l.split("\t")[1:]) for l in r.stdout.splitlines() if l.startswith("FINDING\t")]


def exits_with_relabeller(call):
    """return whether call exits with a relabeller's result"""
    return (isinstance(call, ast.Call) and ast.unparse(call.func) in ("os._exit", "sys.exit") and call.args
            and isinstance(call.args[0], ast.Call)
            and ast.unparse(call.args[0].func).endswith(("run_relabeller", "run_handoff_relabeller")))


def handoff_relabeller_findings(fn, done_writers=("_write_done",)):
    """check the verb returns run_relabeller's result or refuses"""
    out = []

    def writes_done(stmt):
        """return whether stmt calls a done-byte writer"""
        return any(isinstance(c, ast.Call) and ast.unparse(c.func) in done_writers for c in ast.walk(stmt))

    last = fn.body[-1] if fn is not None and fn.body else None
    if not (isinstance(last, ast.Return) and isinstance(last.value, ast.Call)
            and ast.unparse(last.value.func) == "run_relabeller"):
        out.append(("run_handoff_relabeller ends by returning run_relabeller's result",))
    for node in ast.walk(fn) if fn is not None else ():
        body = getattr(node, "body", None)
        for i, stmt in enumerate(body if isinstance(body, list) else ()):
            if isinstance(stmt, ast.Return) and stmt is not last \
                    and not writes_done(stmt) and not any(writes_done(s) for s in body[:i]):
                out.append(("run_handoff_relabeller writes its done byte before an early return", ast.unparse(stmt)))
    return out


def relabeller_findings():
    """check the relabeller's exits and fork sites"""
    out = []
    src = ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read())
    funcs = {f.name: f for f in src.body if isinstance(f, ast.FunctionDef)}
    if not any(exits_with_relabeller(c) for c in ast.walk(funcs["start_relabeller"])):
        out.append(("the cold start's relabeller child exits with run_relabeller's result",))
    main = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    if not any(exits_with_relabeller(c) for c in ast.walk(main)):
        out.append(("the handoff's selinuxns-relabeller verb exits with run_relabeller's result",))
    writers = ("_write_done",) + tuple(n for n, f in funcs.items() if n != "run_handoff_relabeller"
                                       and any(isinstance(c, ast.Call) and ast.unparse(c.func) == "_write_done"
                                               for c in ast.walk(f)))
    out += handoff_relabeller_findings(funcs.get("run_handoff_relabeller"), writers)
    for planted in ("def f():\n    return 0\n", "def f():\n    if x:\n        return 1\n    return run_relabeller()\n",
                    "def f():\n    if x:\n        return g()\n    return run_relabeller()\n"):
        if not handoff_relabeller_findings(ast.parse(planted).body[0], writers):
            out.append(("the handoff relabeller scan flags a planted verb", planted))
    forks = {f.name for f in funcs.values()
             if any(isinstance(c, ast.Call) and ast.unparse(c.func) == "os.fork" for c in ast.walk(f))}
    want = {"start_relabeller", "start_label_service", "start_view_keeper", "start_handoff_relabeller"}
    if forks != want:
        out.append(("the fork sites in selinux_ns, each one reviewed for the kernel domain", want, forks))
    called = [ast.unparse(c.func) for c in ast.walk(funcs["run_relabeller"]) if isinstance(c, ast.Call)]
    if "start_label_service" not in called or any(n in called for n in ("os.fork", "signal.pause", "os.waitpid")):
        out.append(("run_relabeller starts the label service and then returns", called))
    return out


def statements(text):
    """return text's top-level CIL statements"""
    stack = [[]]
    for token in selinux_policy._CIL_TOKEN.findall(text):
        if token == "(":
            stack.append([])
        elif token == ")":
            done = stack.pop()
            stack[-1].append(done)
        elif token[0] != ";":
            stack[-1].append(token)
    return stack[0]


def rendered(namespace):
    """return the policy template rendered for a mode"""
    return selinux_policy.render(guest_files.read(selinux_policy.CIL_FILENAME), "", lambda *wanted: "",
                               namespace=namespace)


def av_rules(stmts, head):
    """return the perms of each AV rule with head"""
    rules = {}
    for s in stmts:
        if s and s[0] == head and len(s) == 4 and isinstance(s[3], list) and len(s[3]) == 2:
            rules.setdefault((s[1], s[2], s[3][0]), set()).update(s[3][1])
    return rules


def policy_findings():
    """check the label service's domain in both renders"""
    out = []
    if CONTEXT.split(b":")[2].decode() != DOMAIN:
        out.append(("the context names the domain the policy declares", CONTEXT, DOMAIN))
    ns_text, host_text = rendered(True), rendered(False)
    stmts = statements(ns_text)
    if ["type", DOMAIN] not in stmts:
        out.append(("the namespace policy declares the label service's domain", DOMAIN))
    attrs = {s[1] for s in stmts if s and s[0] == "typeattributeset" and len(s) == 3
             and isinstance(s[2], list) and DOMAIN in s[2]}
    if attrs != {"domain"}:
        out.append(("the label service's domain carries the domain attribute alone", {"domain"}, attrs))
    allows = av_rules(stmts, "allow")
    mine = {(t, c): p for (s, t, c), p in allows.items() if s == DOMAIN}
    if mine != SERVICE_GRANTS:
        out.append(("the label service's own grants", SERVICE_GRANTS, mine))
    into = {(s, c): p for (s, t, c), p in allows.items() if t == DOMAIN}
    if into != {("kernel", "process"): {"dyntransition"}}:
        out.append(("only kernel may enter the label service's domain, by dyntransition", into))
    if "setcurrent" not in allows.get(("kernel", "self", "process"), set()):
        out.append(("kernel holds setcurrent for the setcon", allows.get(("kernel", "self", "process"))))
    denied = av_rules(stmts, "deny").get(("domain", DOMAIN, "process"), set())
    if not {"ptrace", "sigkill", "sigstop", "signal"} <= denied:
        out.append(("every domain is denied ptrace and signals on the label service", denied))
    everyone = {s[1] for s in stmts if s and s[0] == "typeattributeset" and s[2:] == [["all"]]}
    guarded = {p for (src, t, c), perms in av_rules(stmts, "neverallow").items()
               if src in everyone and t == DOMAIN and c == "process" for p in perms}
    if not {"ptrace", "sigkill", "sigstop", "signal"} <= guarded:
        out.append(("a neverallow over every type guards that deny", guarded))
    if allows.get(("kernel", "device", "chr_file"), set()) & {"getattr", "relabelfrom"}:
        out.append(("kernel keeps the hidraw node's getattr or relabelfrom in namespace mode", allows.get(("kernel", "device", "chr_file"))))
    pins = [x for x in stmts if x and x[0] == "validatetrans"]
    if pins != [PIN]:
        out.append(("one validatetrans pins the service's device relabel to hidraw_device", PIN, pins))
    if DOMAIN in host_text or "setcurrent" in host_text:
        out.append(("host mode renders the label service's domain or its setcon",))
    out += permissive_findings(ns_text, host_text)
    if not permissive_findings(ns_text + f"(typepermissive {DOMAIN})\n", host_text):
        out.append(("the permissive scan finds a planted typepermissive",))
    return out


def permissive_findings(ns_text, host_text):
    """return each typepermissive either mode's render carries"""
    return [("a render makes a domain permissive", mode, s)
            for mode, text in (("namespace", ns_text), ("host", host_text))
            for s in statements(text) if s and s[0] == "typepermissive"]


if "--service-process" in sys.argv[1:]:
    for f in service_process_cases():
        print("FINDING\t" + "\t".join(map(str, f)))
    print("SERVICE-PROCESS-DONE")
    sys.exit(0)
for name, fn in (("enter", enter_findings), ("service process", service_process_findings),
                 ("relabeller", relabeller_findings), ("policy", policy_findings)):
    section(name, fn)
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
for why in NOT_RUN:
    print(f"NOT RUN: {why}")
print("ok (forked-service group NOT RUN)" if NOT_RUN else "ok")
