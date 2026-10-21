#!/usr/bin/env python3
"""Control-plane service"""
import fnmatch
import glob
import grp
import json
import os
import pwd
import selectors
import socket
import struct
import subprocess
import sys
import time

CLI = "/usr/bin/rhizo"
BASH = "/usr/bin/bash"
REQUEST_LIMIT = 65536
LOG_DIR = "/var/log/rhizo"
CAPTURE_DIR = "/var/lib/rhizo/captures"
CAPTURE_KEEP = 20
PEER_GROUP = "rhizo"
CONTROL_REPLY_TIMEOUT_S = 15.0
REQUEST_READ_TIMEOUT_S = 10.0
REPLY_TIMEOUT_S = 60.0
CLI_MAX_S = 600.0
CONTROL_POLL_S = 0.02
SWAYMSG_TIMEOUT_S = 15
GRIM_TIMEOUT_S = 30
PROC_NET_UNIX = "/proc/net/unix"
SESSION_ENV = "/run/rhizo-desktop/session.env"
UNIX_LISTENING = "00010000"

VERBS = {
    "instances": (False, None),
    "allocate": (False, ["instance", "allocate"]),
    "release": (True, ["instance", "release", "{id}"]),
    "install": (True, ["app", "install"]),
    "launch": (True, ["launch"]),
    "logs": (True, None),
    "screenshot": (True, None),
    "input": (True, None),
    "set": (True, ["-i", "{id}", "device", "set"]),
}

SET_SUBJECTS = {
    "battery": ("<pct> <charging|discharging>", 2),
    "thermal": ("<celsius>", 1),
    "gps": ("<lat> <lon>", 2),
}

TOUCH_SUBVERBS = {"down": ("<display> <x> <y>", 4), "move": ("<display> <x> <y>", 4),
                  "up": ("<display>", 2)}


class Refused(Exception):
    """exception for a failed request"""


def log(msg):
    """write a message to stderr"""
    print(msg, file=sys.stderr, flush=True)


def _instanced(base, inst_id, sep="-"):
    """return the base name for an instance id"""
    return base if inst_id == 0 else "%s%s%d" % (base, sep, inst_id)


def instance_run_root(inst_id):
    """return the run directory of an instance"""
    return _instanced("/run/rhizo", inst_id)


def instance_cgroup_root_file(inst_id):
    """return the cgroup root record path"""
    return _instanced("/root/.rhizo_cgroup_root", inst_id)


def read_request(sock, timeout=None):
    """read a JSON request line from the socket"""
    timeout = REQUEST_READ_TIMEOUT_S if timeout is None else timeout
    deadline = time.monotonic() + timeout
    buf = b""
    while b"\n" not in buf:
        if len(buf) > REQUEST_LIMIT:
            raise Refused("request line exceeds %d bytes with no newline" % REQUEST_LIMIT)
        left = deadline - time.monotonic()
        if left <= 0:
            raise Refused("no complete request line within %gs (%d byte(s) read)"
                          % (timeout, len(buf)))
        sock.settimeout(left)
        try:
            data = sock.recv(REQUEST_LIMIT)
        except socket.timeout:
            raise Refused("no complete request line within %gs (%d byte(s) read)"
                          % (timeout, len(buf)))
        if not data:
            raise Refused("connection closed before a complete request line arrived")
        buf += data
    return buf.split(b"\n", 1)[0]


def parse_request(line):
    """parse a request line"""
    try:
        request = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise Refused("request line is not JSON: %s" % e)
    if not isinstance(request, dict):
        raise Refused("request is not a JSON object")
    if request.get("v") != 1:
        raise Refused("unsupported protocol version %r" % (request.get("v"),))
    verb = request.get("verb")
    if verb not in VERBS:
        raise Refused("unknown verb %r" % (verb,))
    inst_id = request.get("id")
    if inst_id is not None:
        if not isinstance(inst_id, int) or isinstance(inst_id, bool):
            raise Refused("id must be an integer, got %r" % (inst_id,))
        if not 0 <= inst_id <= 99:
            raise Refused("id must be 0-99, got %r" % (inst_id,))
    args = request.get("args", [])
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise Refused("args must be a list of strings")
    for a in args:
        if len(a) > 4096:
            raise Refused("an argument exceeds 4096 characters")
    return verb, inst_id, args


def build_plan(verb, inst_id, args):
    """return the env and argv for a verb"""
    if verb in LOCAL_HANDLERS:
        raise Refused("%s is served by this daemon itself, not through the CLI" % verb)
    needs_id, _template = VERBS[verb]
    if needs_id and inst_id is None:
        raise Refused("%s needs an instance id" % verb)
    if not needs_id and inst_id is not None and verb != "release":
        raise Refused("%s takes no instance id" % verb)
    env_overrides = {}
    if needs_id:
        env_overrides["RHIZO_SANDBOX_ID"] = str(inst_id)

    if verb == "release":
        return env_overrides, ["instance", "release", str(inst_id)]
    if verb == "install":
        if len(args) != 1:
            raise Refused("install takes exactly one argument (a host path), got %d" % len(args))
        return env_overrides, ["app", "install", args[0]]
    if verb == "launch":
        if not 1 <= len(args) <= 2:
            raise Refused("launch takes 1 or 2 arguments (package [url-or-path]), got %d" % len(args))
        return env_overrides, ["launch"] + args
    if verb == "allocate":
        if args:
            raise Refused("allocate takes no arguments")
        return env_overrides, ["instance", "allocate"]
    if verb == "set":
        if not args:
            raise Refused("set takes %s and its value(s)" % ", ".join(sorted(SET_SUBJECTS)))
        subject, values = args[0], args[1:]
        if subject not in SET_SUBJECTS:
            raise Refused("set takes %s, not %r" % (", ".join(sorted(SET_SUBJECTS)), subject))
        grammar, count = SET_SUBJECTS[subject]
        if len(values) != count:
            raise Refused("set %s takes %s, got %d value(s)" % (subject, grammar, len(values)))
        return env_overrides, ["-i", str(inst_id), "device", "set"] + args
    raise Refused("%s has no CLI mapping" % verb)


def instances_snapshot(list_units=None, pool_members_path="/var/lib/rhizo/pool-members"):
    """list the androidd service instances"""
    if list_units is None:
        def list_units():
            """run systemctl and return its list of androidd units"""
            try:
                out = subprocess.run(
                    ["systemctl", "list-units", "androidd.service", "androidd@*",
                     "--all", "--no-legend", "--no-pager", "--plain"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                raise Refused("systemctl list-units timed out after 15s")
            except OSError as e:
                raise Refused("cannot run systemctl: %s" % e)
            return out.stdout
    pooled = set()
    try:
        with open(pool_members_path) as f:
            pooled = {line.strip() for line in f if line.strip()}
    except OSError:
        pass
    result = []
    for line in list_units().splitlines():
        parts = line.split()
        if not parts:
            continue
        unit = parts[0]
        state = parts[3] if len(parts) > 3 else "unknown"
        if unit == "androidd.service":
            iid = 0
        elif unit.startswith("androidd@") and unit.endswith(".service"):
            token = unit[len("androidd@"):-len(".service")]
            if not token.isdigit():
                continue
            iid = int(token)
        else:
            continue
        result.append({"id": iid, "unit": unit, "state": state, "pooled": str(iid) in pooled})
    result.sort(key=lambda r: r["id"])
    return result


def tail_logs(inst_id, lines=200, log_dir=None):
    """return the last lines of an instance's boot log"""
    log_dir = LOG_DIR if log_dir is None else log_dir
    path = os.path.join(log_dir, "boot.log" if inst_id == 0 else "boot-%d.log" % inst_id)
    if not os.path.exists(path):
        raise Refused("no boot log for instance %d at %s" % (inst_id, path))
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise Refused("cannot read %s: %s" % (path, e))
    text = data.decode("utf-8", "replace")
    return text.splitlines()[-lines:]


def instance_pids(cgroup_root):
    """return the pids in the cgroup tree"""
    root_procs = os.path.join(cgroup_root, "cgroup.procs")
    if not os.path.exists(root_procs):
        raise Refused("cannot read %s: no such cgroup" % root_procs)
    pids = set()
    for dirpath, _dirs, files in os.walk(cgroup_root):
        if "cgroup.procs" not in files:
            continue
        path = os.path.join(dirpath, "cgroup.procs")
        try:
            with open(path) as f:
                text = f.read()
        except FileNotFoundError:
            continue
        except OSError as e:
            raise Refused("cannot read %s: %s" % (path, e))
        pids.update(int(token) for token in text.split() if token.isdigit())
    return pids


def window_rect_for_pids(tree, pids):
    """find the window rect for the pids"""
    for node in list(tree.get("nodes", [])) + list(tree.get("floating_nodes", [])):
        rect = node.get("rect") or {}
        if (node.get("pid") in pids
                and rect.get("width", 0) > 0 and rect.get("height", 0) > 0):
            return {"x": rect.get("x", 0), "y": rect.get("y", 0),
                    "width": rect["width"], "height": rect["height"]}
        found = window_rect_for_pids(node, pids)
        if found is not None:
            return found
    return None


def png_dimensions(path):
    """return the PNG width and height"""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        size = os.path.getsize(path)
    except OSError as e:
        raise Refused("cannot read %s: %s" % (path, e))
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise Refused("%s is not a PNG: %d byte(s), no IHDR header" % (path, size))
    width = int.from_bytes(head[16:20], "big")
    height = int.from_bytes(head[20:24], "big")
    if width == 0 or height == 0:
        raise Refused("%s is not a PNG of any real size: %dx%d" % (path, width, height))
    return width, height


def listening_unix_paths(proc_net_unix=PROC_NET_UNIX):
    """return the paths of listening unix sockets"""
    try:
        with open(proc_net_unix) as f:
            rows = f.read().splitlines()[1:]
    except OSError as e:
        raise Refused("cannot read %s: %s" % (proc_net_unix, e))
    out = set()
    for row in rows:
        fields = row.split(None, 7)
        if len(fields) == 8 and fields[3] == UNIX_LISTENING and fields[7].startswith("/"):
            out.add(fields[7])
    return out


def session_env(path=SESSION_ENV):
    """read KEY=value lines from the session file"""
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise Refused("cannot read %s: %s" % (path, e))
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def find_compositor(env=None, run_user_root="/run/user", inst_id=None, published_root="/run",
                    proc_net_unix=PROC_NET_UNIX, session_env_path=SESSION_ENV):
    """find the Wayland session for a capture"""
    env = os.environ if env is None else env
    tried = []

    explicit = env.get("RHIZO_WAYLAND_HOST_SOCKET")
    if explicit:
        listening = listening_unix_paths(proc_net_unix)
        if explicit not in listening and not os.path.exists(explicit):
            raise Refused("RHIZO_WAYLAND_HOST_SOCKET=%s does not exist" % explicit)
        return _compositor_env(os.path.dirname(explicit), os.path.basename(explicit),
                               run_user_root, listening)

    if env.get("WAYLAND_DISPLAY") and env.get("XDG_RUNTIME_DIR"):
        inherited = {"WAYLAND_DISPLAY": env["WAYLAND_DISPLAY"],
                     "XDG_RUNTIME_DIR": env["XDG_RUNTIME_DIR"]}
        if env.get("SWAYSOCK"):
            inherited["SWAYSOCK"] = env["SWAYSOCK"]
        return inherited

    listening = listening_unix_paths(proc_net_unix)

    written = session_env(session_env_path).get("RHIZO_WAYLAND_HOST_SOCKET")
    if written and written in listening:
        return _compositor_env(os.path.dirname(written), os.path.basename(written),
                               run_user_root, listening)
    tried.append("%s (%s)" % (session_env_path, "names %s, which nothing listens on" % written
                              if written else "no socket named"))

    by_session = {}
    for path in listening:
        runtime_dir, name = os.path.split(path)
        if os.path.dirname(runtime_dir) == run_user_root.rstrip("/") and name.startswith("wayland-"):
            by_session.setdefault(runtime_dir, set()).add(name)
    sessions = []
    for runtime_dir in sorted(by_session):
        names = by_session[runtime_dir]
        numbered = sorted(n for n in names if n[len("wayland-"):].isdigit())
        display = numbered[0] if numbered else ("wayland-rhizo" if "wayland-rhizo" in names else None)
        if display:
            sessions.append((runtime_dir, display))
    tried.append("%s under %s" % (proc_net_unix, run_user_root))
    if len(sessions) > 1:
        raise Refused("more than one Wayland session under %s (%s)"
                      % (run_user_root, ", ".join(s for s, _ in sessions)))
    if sessions:
        return _compositor_env(sessions[0][0], sessions[0][1], run_user_root, listening)

    if inst_id is not None:
        published = os.path.join(published_root, _instanced("rhizo-wayland", inst_id), "wayland-0")
        tried.append(published)
        if os.path.exists(published):
            return _compositor_env(os.path.dirname(published), "wayland-0", run_user_root, listening)

    raise Refused("no Wayland compositor socket found (tried %s); name it by exporting "
                  "RHIZO_WAYLAND_HOST_SOCKET, or WAYLAND_DISPLAY and XDG_RUNTIME_DIR, into "
                  "rhizo-api@.service" % ", ".join(tried))


def _compositor_env(runtime_dir, display, run_user_root, listening):
    """return the grim and swaymsg environment"""
    found = {"XDG_RUNTIME_DIR": runtime_dir, "WAYLAND_DISPLAY": display}
    is_ipc = lambda p: fnmatch.fnmatchcase(os.path.basename(p), "sway-ipc.*.sock")
    ipc = sorted(p for p in listening if os.path.dirname(p) == runtime_dir and is_ipc(p))
    if not ipc:
        ipc = sorted(p for p in listening
                     if os.path.dirname(os.path.dirname(p)) == run_user_root.rstrip("/") and is_ipc(p))
    if ipc:
        found["SWAYSOCK"] = ipc[0]
    return found


def tool_identity(runtime_dir, euid=None):
    """return the uid and gid of the session"""
    euid = os.geteuid() if euid is None else euid
    if euid != 0 or not runtime_dir:
        return {}
    try:
        st = os.stat(runtime_dir)
    except OSError as e:
        raise Refused("cannot stat %s to find whose session it is: %s" % (runtime_dir, e))
    if st.st_uid == 0:
        return {}
    return {"user": st.st_uid, "group": st.st_gid, "extra_groups": []}


def _run_tool(argv, env, timeout, what, text=True, **identity):
    """run a tool with a timeout"""
    try:
        return subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=text, timeout=timeout, **identity)
    except subprocess.TimeoutExpired:
        raise Refused("%s did not finish within %gs" % (what, timeout))
    except FileNotFoundError as e:
        raise Refused("cannot run %s: %s" % (argv[0], e))
    except OSError as e:
        raise Refused("cannot run %s%s: %s" % (argv[0], " as uid %d" % identity["user"]
                                               if identity else "", e))


def capture_screenshot(inst_id, capture_dir=None, cgroup_root_file=None, compositor_env=None):
    """capture a PNG of the instance window"""
    capture_dir = CAPTURE_DIR if capture_dir is None else capture_dir
    record = instance_cgroup_root_file(inst_id) if cgroup_root_file is None else cgroup_root_file
    env = dict(os.environ)
    env.update(find_compositor(inst_id=inst_id) if compositor_env is None else compositor_env)
    identity = tool_identity(env.get("XDG_RUNTIME_DIR"))

    try:
        with open(record) as f:
            cgroup_root = f.read().strip()
    except OSError as e:
        raise Refused("instance %d has no recorded cgroup root (%s): %s"
                      % (inst_id, record, e))
    if not cgroup_root:
        raise Refused("instance %d's cgroup record %s is empty" % (inst_id, record))
    pids = instance_pids(cgroup_root)

    done = _run_tool(["swaymsg", "-t", "get_tree"], env, SWAYMSG_TIMEOUT_S, "swaymsg -t get_tree",
                     **identity)
    if done.returncode != 0:
        raise Refused("cannot read the compositor's window tree: %s"
                      % (done.stderr.strip() or "swaymsg exited %d" % done.returncode))
    try:
        tree = json.loads(done.stdout)
    except ValueError as e:
        raise Refused("the compositor's window tree is not JSON: %s" % e)

    rect = window_rect_for_pids(tree, pids)
    if rect is None:
        raise Refused("instance %d has no toplevel of its own on this compositor (%d pid(s) in %s)"
                      % (inst_id, len(pids), cgroup_root))

    try:
        os.makedirs(capture_dir, exist_ok=True)
    except OSError as e:
        raise Refused("cannot create %s: %s" % (capture_dir, e))
    out = os.path.join(capture_dir, "instance-%d-%d.png" % (inst_id, time.time_ns()))
    geometry = "%d,%d %dx%d" % (rect["x"], rect["y"], rect["width"], rect["height"])
    done = _run_tool(["grim", "-g", geometry, "-"], env, GRIM_TIMEOUT_S, "grim", text=False, **identity)
    if done.returncode != 0:
        raise Refused("grim could not capture instance %d at %s: %s"
                      % (inst_id, geometry, done.stderr.decode(errors="replace").strip()
                         or "exited %d" % done.returncode))
    try:
        with open(out, "wb") as f:
            f.write(done.stdout)
    except OSError as e:
        raise Refused("cannot write %s: %s" % (out, e))
    width, height = png_dimensions(out)
    result = {"path": out, "bytes": os.path.getsize(out), "region": rect,
              "width": width, "height": height}
    sweep_captures(inst_id, capture_dir)
    return result


def sweep_captures(inst_id, capture_dir, keep=CAPTURE_KEEP):
    """delete old captures of the instance"""
    def taken_at(path):
        """return the capture time encoded in a screenshot file name"""
        return int(os.path.basename(path).rsplit("-", 1)[1][:-len(".png")])

    mine = sorted(glob.glob(os.path.join(capture_dir, "instance-%d-*.png" % inst_id)), key=taken_at)
    for old in mine[:-keep] if keep else mine:
        try:
            os.unlink(old)
        except OSError as e:
            log("could not remove %s: %s" % (old, e))


def control_send(inst_id, line, reply_prefixes, run_root=None, timeout=None):
    """send a line and return the reply"""
    root = instance_run_root(inst_id) if run_root is None else run_root
    timeout = CONTROL_REPLY_TIMEOUT_S if timeout is None else timeout
    control = os.path.join(root, "data", "rhizo_control", "control")
    control_out = os.path.join(root, "data", "rhizo_control", "control.out")
    try:
        start = os.path.getsize(control_out)
    except OSError:
        start = 0
    try:
        fd = os.open(control, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        raise Refused("instance %d's composer control channel (%s) is not open: %s"
                      % (inst_id, control, e))
    try:
        os.write(fd, (line + "\n").encode())
    except OSError as e:
        raise Refused("cannot send %r to instance %d (%s): %s" % (line, inst_id, control, e))
    finally:
        os.close(fd)

    deadline = time.monotonic() + timeout
    while True:
        try:
            with open(control_out, "rb") as f:
                f.seek(start)
                appended = f.read().decode("utf-8", "replace")
        except OSError:
            appended = ""
        for reply in appended.splitlines():
            if reply.startswith(reply_prefixes):
                return reply
        if time.monotonic() >= deadline:
            raise Refused("instance %d's composer did not answer %r within %gs"
                          % (inst_id, line, timeout))
        time.sleep(CONTROL_POLL_S)


def inject_touch(inst_id, args, run_root=None, timeout=None):
    """inject a touch through the control FIFO"""
    if not args:
        raise Refused("input takes %s and its arguments" % ", ".join(sorted(TOUCH_SUBVERBS)))
    sub = args[0]
    if sub not in TOUCH_SUBVERBS:
        raise Refused("input takes %s, not %r" % (", ".join(sorted(TOUCH_SUBVERBS)), sub))
    grammar, tokens = TOUCH_SUBVERBS[sub]
    if len(args) != tokens:
        raise Refused("input %s takes %s, got %d argument(s)" % (sub, grammar, len(args) - 1))
    for value in args[1:]:
        if not value.lstrip("-").isdigit():
            raise Refused("input %s takes whole numbers (%s), got %r" % (sub, grammar, value))
    reply = control_send(inst_id, "inject touch " + " ".join(args),
                         ("inject %s id=" % sub, "inject-failed"),
                         run_root=run_root, timeout=timeout)
    if reply.startswith("inject-failed"):
        raise Refused("instance %d's composer refused the injection: %s" % (inst_id, reply))
    return {"injected": sub, "reply": reply}


def _serve_instances(inst_id, args):
    """serve the instances verb"""
    if inst_id is not None:
        raise Refused("instances takes no instance id")
    if args:
        raise Refused("instances takes no arguments")
    rows = instances_snapshot()
    log("instances -> %d row(s)" % len(rows))
    return {"instances": rows}


def _serve_logs(inst_id, args):
    """serve the logs verb with the tail of an instance's boot log"""
    if inst_id is None:
        raise Refused("logs needs an instance id")
    if args:
        raise Refused("logs takes no arguments")
    return {"lines": tail_logs(inst_id)}


def _serve_screenshot(inst_id, args):
    """serve the screenshot verb by capturing the instance's screen"""
    if inst_id is None:
        raise Refused("screenshot needs an instance id")
    if args:
        raise Refused("screenshot takes no arguments")
    return capture_screenshot(inst_id)


def _serve_input(inst_id, args):
    """serve the input verb by injecting a touch event"""
    if inst_id is None:
        raise Refused("input needs an instance id")
    return inject_touch(inst_id, args)


LOCAL_HANDLERS = {
    "instances": _serve_instances,
    "logs": _serve_logs,
    "screenshot": _serve_screenshot,
    "input": _serve_input,
}


def authorize_peer(uid, gid, group_lookup=None, uid_name=None):
    """check the peer uid and gid"""
    if uid == 0:
        return True
    if group_lookup is None:
        def group_lookup():
            """return the rhizo group's gid and member names"""
            entry = grp.getgrnam(PEER_GROUP)
            return entry.gr_gid, entry.gr_mem
    if uid_name is None:
        def uid_name(u):
            """return the user name of a uid"""
            return pwd.getpwuid(u).pw_name
    try:
        group_gid, members = group_lookup()
    except KeyError as e:
        raise Refused("this host has no %r group (%s)"
                      % (PEER_GROUP, e))
    if gid == group_gid:
        return True
    try:
        name = uid_name(uid)
    except KeyError:
        name = None
    if not name:
        raise Refused("peer uid=%d has no passwd entry (group %s)" % (uid, PEER_GROUP))
    if name in members:
        return True
    raise Refused("peer %s (uid=%d gid=%d) is not in group %s" % (name, uid, gid, PEER_GROUP))


def relay(sock, env_overrides, argv, timeout=None):
    """relay the CLI's output for a request"""
    timeout = CLI_MAX_S if timeout is None else timeout
    env = dict(os.environ)
    env.update(env_overrides)
    try:
        child = subprocess.Popen([BASH, CLI] + argv, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as e:
        sock.sendall(("E cannot run %s %s: %s\n" % (BASH, CLI, e)).encode())
        return 127
    sel = selectors.DefaultSelector()
    tails = {child.stdout: b"", child.stderr: b""}
    prefixes = {child.stdout: b"", child.stderr: b"E "}
    for stream in tails:
        sel.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    while sel.get_map():
        left = deadline - time.monotonic()
        if left <= 0:
            child.kill()
            child.wait()
            sock.sendall(("E %s %s exceeded %gs and was killed\n"
                          % (CLI, " ".join(argv[:2]), timeout)).encode())
            return 124
        for key, _events in sel.select(left):
            stream = key.fileobj
            chunk = os.read(stream.fileno(), 65536)
            if not chunk:
                if tails[stream]:
                    sock.sendall(prefixes[stream] + tails[stream] + b"\n")
                    tails[stream] = b""
                sel.unregister(stream)
                stream.close()
                continue
            pending = tails[stream] + chunk
            lines = pending.split(b"\n")
            tails[stream] = lines.pop()
            for line in lines:
                sock.sendall(prefixes[stream] + line + b"\n")
                if stream is child.stderr:
                    log("child: %s" % line.decode("utf-8", "replace")[:300])
    return child.wait()


def main(group_lookup=None, uid_name=None):
    """serve a connection from rhizo-api.socket"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=0)
    cred = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    pid, uid, gid = struct.unpack("3i", cred)
    log("peer uid=%d gid=%d pid=%d" % (uid, gid, pid))

    try:
        line = read_request(sock)
        sock.settimeout(REPLY_TIMEOUT_S)
        authorize_peer(uid, gid, group_lookup, uid_name)
        verb, inst_id, args = parse_request(line)

        handler = LOCAL_HANDLERS.get(verb)
        if handler is not None:
            payload = json.dumps(handler(inst_id, args))
            sock.sendall((payload + "\n").encode())
            log("%s%s -> ok" % (verb, "" if inst_id is None else " id=%d" % inst_id))
            return 0

        env_overrides, argv = build_plan(verb, inst_id, args)
    except Refused as e:
        log("refused: %s" % e)
        sock.settimeout(REPLY_TIMEOUT_S)
        try:
            sock.sendall((json.dumps({"error": str(e)}) + "\n").encode())
        except OSError as send_err:
            log("could not send the refusal to the peer: %s" % send_err)
            return 1
        return 0

    log("running %s %s" % (CLI, " ".join(argv)))
    try:
        rc = relay(sock, env_overrides, argv)
        log("%s %s exited %d" % (CLI, " ".join(argv[:2]), rc))
        sock.sendall(("RHIZO_API_RC=%d\n" % rc).encode())
    except OSError as e:
        log("peer stopped reading its own reply (%s) -- dropping the connection" % e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
