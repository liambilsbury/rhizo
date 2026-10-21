#!/usr/bin/env python3
import ast
import contextlib
import io
import os
import signal
import sys
import tempfile
import time

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-supervisor-log-pump")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher

WAIT_S = 10


def log_opening_block():
    """return the supervisor's log-opening statement"""
    tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    sup = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_kernel_domain_supervisor")
    blocks = [t for t in sup.body if "SUPERVISOR_LOG" in ast.unparse(t)]
    if len(blocks) != 1:
        raise AssertionError(f"run_kernel_domain_supervisor has {len(blocks)} log-opening blocks, want 1")
    return compile(ast.Module(body=[blocks[0]], type_ignores=[]), "boot.py", "exec")


def children(pid):
    """return pid's child pids"""
    with open(f"/proc/{pid}/task/{pid}/children") as f:
        return [int(c) for c in f.read().split()]


def await_text(path, text):
    """wait for text to reach path"""
    deadline = time.monotonic() + WAIT_S
    while time.monotonic() < deadline:
        try:
            if text in open(path).read():
                return True
        except (FileNotFoundError, NotADirectoryError):
            pass
        time.sleep(0.02)
    return False


def stop_scenario(tmp, parking, blocked_log=False, dead_pump=False, join_ok=True):
    """run a supervisor through its unit's stop"""
    log, kmsg_path, moved_path = f"{tmp}/supervisor.log", f"{tmp}/kmsg", f"{tmp}/moved"
    if blocked_log:
        open(f"{tmp}/file", "w").close()
        log = f"{tmp}/file/supervisor.log"
    host_cgroup = f"{tmp}/rhizo-host"
    if parking:
        os.makedirs(host_cgroup, exist_ok=True)
    go_r, go_w = os.pipe()
    ready_r, ready_w = os.pipe()
    sup = os.fork()
    if sup == 0:
        os.close(go_w)
        os.close(ready_r)
        code = 3
        try:
            kmsg_fd = os.open(kmsg_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            launcher.core._KMSG_FD = kmsg_fd
            launcher.kmsg = lambda m: os.write(kmsg_fd, f"{m}\n".encode())
            launcher.SUPERVISOR_CGROUP = host_cgroup
            launcher.join_cgroup = ((lambda path, pid, log: open(moved_path, "a").write(f"{path} {pid}\n") > 0)
                                    if join_ok else (lambda path, pid, log: False))
            if dead_pump:
                launcher.core._run_log_pump = lambda *a: os._exit(1)
            unit_r, unit_w = os.pipe()
            if os.fork() == 0:
                os.close(unit_w)
                while os.read(unit_r, 65536):
                    pass
                os._exit(0)
            os.close(unit_r)
            os.dup2(unit_w, 1)
            os.dup2(unit_w, 2)
            os.close(unit_w)
            scope = dict(vars(launcher), RHIZO_LOG_DIR=os.path.dirname(log), SUPERVISOR_LOG=log)
            exec(log_opening_block(), scope)
            print("before the stop", flush=True)
            os.write(ready_w, b"1")
            os.read(go_r, 1)
            print("after the stop", flush=True)
            joiner = os.fork()
            if joiner == 0:
                jcode = 4
                try:
                    print("joiner after the stop", flush=True)
                    jcode = 0
                finally:
                    os._exit(jcode)
            _, jstatus = os.waitpid(joiner, 0)
            code = 0 if os.waitstatus_to_exitcode(jstatus) == 0 else 5
        except BaseException as e:
            os.write(2, f"supervisor raised {e!r}\n".encode())
        finally:
            os._exit(code)
    os.close(go_r)
    os.close(ready_w)
    ready = os.read(ready_r, 1) == b"1"
    os.close(ready_r)
    moved = set()
    if os.path.exists(moved_path):
        moved = {int(l.split()[1]) for l in open(moved_path) if l.split()[0] == host_cgroup}
    killed = []
    if ready:
        for pid in children(sup):
            if pid not in moved:
                os.kill(pid, signal.SIGKILL)
                killed.append(pid)
        await_text(log, "before the stop")
    deadline = time.monotonic() + WAIT_S
    for pid in killed:
        while time.monotonic() < deadline and os.path.exists(f"/proc/{pid}") \
                and open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[0] != "Z":
            time.sleep(0.01)
    os.write(go_w, b"1")
    os.close(go_w)
    _, status = os.waitpid(sup, 0)
    if parking and not (blocked_log or dead_pump):
        await_text(log, "joiner after the stop")
    text = open(log).read() if os.path.isfile(log) else ""
    kmsg_text = open(kmsg_path).read() if os.path.exists(kmsg_path) else ""
    return os.waitstatus_to_exitcode(status), text, kmsg_text, moved, killed


def line_write_failures():
    """return the line-write findings"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        calls = []
        real_write = os.write

        def recording_write(fd, data):
            """record a write to the stream's fd"""
            if fd == w:
                calls.append(bytes(data))
            return real_write(fd, data)
        os.write = recording_write
        stream = launcher.LogPipeStream(w)
        print("first line", file=stream, flush=True)
        print("second", "line", file=stream, flush=True)
        stream.write("partial")
        stream.flush()
        os.write = real_write
        os.write(w, ("\nCALLS " + repr(calls) + "\n").encode())
        os._exit(0)
    os.close(w)
    data = b""
    while chunk := os.read(r, 65536):
        data += chunk
    os.close(r)
    os.waitpid(pid, 0)
    want = "CALLS [b'first line\\n', b'second line\\n', b'partial']"
    if want not in data.decode():
        return [f"LogPipeStream: want each line in one write, {want}; got {data.decode()[-200:]!r}"]
    return []


def devnull_refused_failures(tmp):
    """return findings for a dead pump and a refused /dev/null"""
    kmsg_path = f"{tmp}/kmsg-devnull"
    r, w = os.pipe()
    result_r, result_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        os.close(result_r)
        launcher.core._KMSG_FD = os.open(kmsg_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        real_open = os.open

        def refusing_open(path, *args, **kwargs):
            """refuse /dev/null the way a host policy does"""
            if path == os.devnull:
                raise PermissionError(13, "Permission denied", path)
            return real_open(path, *args, **kwargs)
        os.open = refusing_open
        try:
            stream = launcher.LogPipeStream(w)
            print("a line after the pump died", file=stream, flush=True)
            print("another line", file=stream, flush=True)
            os.write(result_w, b"ALIVE")
        except BaseException as e:
            os.write(result_w, f"RAISED {e!r}".encode())
        os._exit(0)
    os.close(w)
    os.close(r)
    os.close(result_w)
    out = b""
    while chunk := os.read(result_r, 4096):
        out += chunk
    os.close(result_r)
    os.waitpid(pid, 0)
    kmsg_text = open(kmsg_path).read() if os.path.exists(kmsg_path) else ""
    bad = []
    if out != b"ALIVE":
        bad.append(f"a supervisor whose log pump is gone and whose /dev/null is refused: want its log lines dropped "
                   f"and the supervisor running; got {out.decode(errors='replace')!r}")
    if "EPIPE" not in kmsg_text:
        bad.append(f"the closed log pipe with /dev/null refused was not reported to kmsg as EPIPE: {kmsg_text!r}")
    return bad


def main():
    """return the failures"""
    bad = line_write_failures()
    with tempfile.TemporaryDirectory() as tmp:
        bad += devnull_refused_failures(tmp)
    with tempfile.TemporaryDirectory() as tmp:
        code, text, kmsg_text, moved, killed = stop_scenario(tmp, parking=True)
        if code != 0 or not moved or set(killed) & moved or "after the stop" not in text \
                or "joiner after the stop" not in text:
            bad.append(f"a parked supervisor through its unit's stop: want its pump moved to its parking cgroup, the "
                       f"supervisor and a joiner alive and logging; got exit {code}, moved {sorted(moved)}, killed "
                       f"{killed}, log {text!r}")
    with tempfile.TemporaryDirectory() as tmp:
        code, text, kmsg_text, moved, killed = stop_scenario(tmp, parking=False)
        if code != 0 or not moved or set(killed) & moved or not os.path.isdir(f"{tmp}/rhizo-host"):
            bad.append(f"a supervisor whose parking cgroup does not exist yet, as in host mode before the primer runs: "
                       f"want the cgroup made and its pump moved into it; got exit {code}, "
                       f"moved {sorted(moved)}, killed {killed}, kmsg {kmsg_text!r}")
    with tempfile.TemporaryDirectory() as tmp:
        code, text, kmsg_text, moved, killed = stop_scenario(tmp, parking=True, join_ok=False)
        if code != 0 or not killed or "EPIPE" not in kmsg_text:
            bad.append(f"a supervisor whose log pump the stop killed: want it and a joiner alive and the closed pipe "
                       f"reported to kmsg as EPIPE; got exit {code}, killed {killed}, kmsg {kmsg_text!r}")
    for label, kwargs in (("an unopenable supervisor log", {"blocked_log": True}),
                          ("a log pump that dies at start", {"dead_pump": True})):
        with tempfile.TemporaryDirectory() as tmp:
            code, text, kmsg_text, moved, killed = stop_scenario(tmp, parking=True, **kwargs)
            if code != 0 or not killed or "supervisor_log=unusable" not in kmsg_text:
                bad.append(f"{label}: want the supervisor and a joiner alive through the unit pump's death and the "
                           f"log named unusable in kmsg; got exit {code}, killed {killed}, kmsg {kmsg_text!r}")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("supervisor-log-pump:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
