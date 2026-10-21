#!/usr/bin/env python3
import ast, contextlib, ctypes, errno, io, os, struct, sys
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-handle-filter")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs

ALLOW, DENY = 0x7fff0000, 0x00050000 | errno.EPERM
X86_64, I386, AARCH64, ARM = 0xc000003e, 0x40000003, 0xc00000b7, 0x40000028
WANT_NR = {X86_64: (304, 0x40000000 | 304), I386: (342,), AARCH64: (265,), ARM: (371,)}
PR_SET_NO_NEW_PRIVS = 38
bad = []


def run_bpf(prog, arch, nr):
    """run a classic BPF seccomp program on (arch, nr)"""
    ins = [struct.unpack("<HBBI", prog[i:i + 8]) for i in range(0, len(prog), 8)]
    data, pc, acc = {0: nr, 4: arch}, 0, 0
    for _ in range(len(ins) + 1):
        code, jt, jf, k = ins[pc]
        if code == 0x20:
            acc, pc = data[k], pc + 1
        elif code == 0x15:
            pc += 1 + (jt if acc == k else jf)
        elif code == 0x06:
            return k
        else:
            return f"bad opcode {code:#x}"
    return "no return"


table = getattr(rootfs, "OPEN_BY_HANDLE_NR", None)
program = getattr(rootfs, "open_by_handle_program", None)
install = getattr(rootfs, "install_handle_filter", None)
if table != WANT_NR:
    bad.append(("OPEN_BY_HANDLE_NR", WANT_NR, table))
if program is None or install is None:
    bad.append(("sandbox.rootfs", "open_by_handle_program and install_handle_filter", program, install))
else:
    prog = program()
    for arch, nrs in (table or {}).items():
        for nr in nrs:
            got = run_bpf(prog, arch, nr)
            if got != DENY:
                bad.append((f"arch {arch:#x} nr {nr:#x}", hex(DENY), got if isinstance(got, str) else hex(got)))
    for label, arch, nr in (("openat, x86_64", X86_64, 257), ("openat, aarch64", AARCH64, 56),
                            ("ioctl, x86_64", X86_64, 16), ("name_to_handle_at, x86_64", X86_64, 303),
                            ("i386's number under x86_64", X86_64, 342), ("x86_64's number under i386", I386, 304),
                            ("x86_64's number under arm", ARM, 304), ("an unknown arch", 0xc0000015, 304)):
        got = run_bpf(prog, arch, nr)
        if got != ALLOW:
            bad.append((label, hex(ALLOW), got if isinstance(got, str) else hex(got)))

    def installed_in_child(fake_libc):
        """install the filter in a forked child under no_new_privs"""
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            try:
                if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
                    raise OSError("prctl(PR_SET_NO_NEW_PRIVS) failed")
                if fake_libc is not None:
                    rootfs.libc = fake_libc
                logs = []
                ok = install(log=logs.append)
                os.write(w, repr((ok, logs)).encode())
            except BaseException as e:
                os.write(w, repr(("raised", repr(e))).encode())
            os._exit(0)
        os.close(w)
        data = b""
        while chunk := os.read(r, 65536):
            data += chunk
        os.close(r)
        _, status = os.waitpid(pid, 0)
        return ast.literal_eval(data.decode()) if data else None, os.waitstatus_to_exitcode(status)

    class RefusingLibc:
        """libc stand-in failing every syscall with EACCES"""

        @staticmethod
        def syscall(*args):
            """fail with EACCES"""
            ctypes.set_errno(errno.EACCES)
            return -1

    got = installed_in_child(None)
    if got != ((True, ["RHIZO_MARKER handle_filter=installed"]), 0):
        bad.append(("install_handle_filter on this kernel", "True with the installed marker", got))
    got = installed_in_child(RefusingLibc)
    if got != ((False, [f"RHIZO_MARKER handle_filter=failed errno={errno.EACCES}"]), 0):
        bad.append(("install_handle_filter refused", "False with the failed marker", got))

    def install_under(arch, call):
        """run call(log) under arch with a recording libc"""
        numbers, logs = [], []

        class RecordingLibc:
            """libc stand-in recording each syscall number and succeeding"""

            @staticmethod
            def syscall(nr, *args):
                """record the number and return 0"""
                numbers.append(nr)
                return 0

        saved = (rootfs.libc, rootfs.HOST_ARCH)
        rootfs.libc, rootfs.HOST_ARCH = RecordingLibc, arch
        try:
            got = call(logs.append)
        except Exception as e:
            got = repr(e)
        finally:
            rootfs.libc, rootfs.HOST_ARCH = saved
        return got, logs, numbers

    uinput = getattr(rootfs, "install_uinput_filter", None)
    for arch, want_nr in ((rootfs.HOST_ARCH_AMD64, 317), ("aarch64", 277), ("riscv64", None)):
        got = install_under(arch, lambda log: install(log=log))
        want = ((True, ["RHIZO_MARKER handle_filter=installed"], [want_nr]) if want_nr else
                (False, [f"RHIZO_MARKER handle_filter=failed reason=no-seccomp-nr arch={arch}"], []))
        if got != want:
            bad.append(("install_handle_filter on " + arch, want, got))
        got = install_under(arch, lambda log: uinput(None, log=log))
        want = (("refusing", ["RHIZO_MARKER input_owner=refusing reason=no-supervisor -- every UI_DEV_CREATE fails "
                              "ENOSYS"], [want_nr]) if want_nr else
                ("", [f"RHIZO_MARKER input_owner=failed reason=seccomp:no-nr-for-{arch}"], []))
        if got != want:
            bad.append(("install_uinput_filter on " + arch, want, got))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "enter_sandbox_init")
gates = [n for n in fn.body if isinstance(n, ast.If) and ast.unparse(n.test) == "not install_handle_filter()"]
calls = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func) == "install_handle_filter"]
drops = [n.lineno for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func) == "drop_caps"]
if len(gates) != 1 or len(calls) != 1 or len(drops) != 1:
    bad.append(("enter_sandbox_init", "one top-level 'if not install_handle_filter()' and one drop_caps()",
                len(gates), len(calls), len(drops)))
else:
    if not gates[0].lineno < drops[0]:
        bad.append(("call order", "install_handle_filter before drop_caps", gates[0].lineno, drops[0]))
    gate = compile(ast.Module(body=gates, type_ignores=[]), "boot.py", "exec")
    for installed, want in ((False, [1]), (True, [])):
        exits, logs = [], []

        class FakeOs:
            """os stand-in recording _exit"""
            _exit = staticmethod(exits.append)

        exec(gate, {"install_handle_filter": lambda: installed, "kmsg": logs.append, "os": FakeOs})
        if exits != want or bool(logs) != (not installed):
            bad.append((f"install_handle_filter returns {installed}", f"exits {want}", exits, logs))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
