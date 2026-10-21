#!/usr/bin/env python3
import argparse
import concurrent.futures
import glob
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

DESKD_UNIT = "src/services/deskbridge/deskd.service"
TOKEN_UNIT = "src/services/deskbridge/desk-token.service"
TOKEN_UNIT_NAME = "rhizo-desk-token.service"
DELIVERER = "src/services/deskbridge/desk-token.py"
MANIFEST = "src/android/apps/desktop-bridge/AndroidManifest.xml"
BRIDGE_SRC = "src/android/apps/desktop-bridge/src/com/rhizo/desktop"
PROVIDER_SRC = BRIDGE_SRC + "/TokenProvider.java"
CAPS_TSV = "test/checks/launcher/capabilities/capabilities.tsv"
RULES = "debian/rules"
AUTHORITY = "com.rhizo.desktop.token"
CAPS_MODULE = "src/androidd/sandbox/capabilities.py"
POINTER = "desktop.pointer"
BRIDGE_APK = "/system_ext/app/RhizoDesktop/RhizoDesktop.apk"
BRIDGE_IME = "com.rhizo.desktop/.RhizoIme"
BRIDGE_LISTENER = "com.rhizo.desktop/com.rhizo.desktop.NotifListener"
LATIN_IME = "com.android.inputmethod.latin/.LatinIME"

BROADCAST_RE = re.compile(r"StartReceiver|com\.rhizo\.desktop\.START|--es\s+token\b")
LOG_TOKEN_RE = re.compile(r"Logs\.\w+\([^;]*\+\s*[\w.]*[tT]oken\b")


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def code(line):
    """return whether a line is code rather than a comment"""
    return not line.lstrip().startswith(("#", "//"))


def unit_text(root, rel):
    """return a unit file's text with continuations joined"""
    return re.sub(r"\\\n", " ", read(root, rel))


def unit_key(text, key):
    """return every value of a key in a unit file"""
    return [m.group(1).strip() for m in re.finditer(r"^%s=(.*)$" % re.escape(key), text, re.M)]


def token_file(text):
    """return the --token-file value from ExecStart="""
    for val in unit_key(text, "ExecStart"):
        m = re.search(r"--token-file\s+(\S+)", val)
        if m:
            return m.group(1)
    return None


RIG_SRC_FILES = (
    "src/install/prepare/align-apex.py", "src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
    "src/install/prepare/materialize-data-template.py", "src/install/prepare/data-template.sh",
    "src/androidd/host/capture-kernel-log.sh", "src/androidd/host/parse-display-list.sh",
    "src/androidd/host/launch-app.sh", "src/androidd/host/release-idle-display.sh",
    "src/androidd/host/fill-display-pool.sh", "src/androidd/host/unfreeze-cgroup.sh",
    "src/services/appsync/appsync.py", "src/services/appsync/app-events.py",
    "src/androidd/sandbox/capability-allowed.sh", "src/androidd/host/kernel-check.sh",
    "src/services/hostfs/hostfs.py", "src/services/appsync/remove-entries.sh", "src/services/appsync/resync.sh",
    "src/services/probe-client/probe-client.py")
CHECK_HELPERS_PY = ("desk_hello.py", "layout-expect.py", "parse-avc.py")


def rig_files(root):
    """return the rig shell and python files"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
    from tree_dirs import test_dirs, tool_dirs
    out = []
    for d in [os.path.join(root, t) for t in (*tool_dirs(root), "tools/mesa", "tools/patches", *test_dirs(root))]:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".sh") or (name.endswith(".py") and (
                    not os.path.relpath(d, root).startswith("test/checks") or name in CHECK_HELPERS_PY)):
                out.append(os.path.relpath(os.path.join(d, name), root))
    out += [f for f in RIG_SRC_FILES if os.path.isfile(os.path.join(root, f))]
    return out


def bridge_capabilities(root):
    """return the capabilities deskd.py enforces"""
    caps = set()
    for line in read(root, CAPS_TSV).splitlines():
        cols = line.split("\t")
        if len(cols) > 2 and not line.startswith("#") and "src/services/deskbridge/deskd.py:" in cols[2]:
            caps.add(cols[0])
    caps.discard(POINTER)
    return caps


def check_rig(root, token_path):
    """check rig files for bridge token handling"""
    problems = []
    for rel in rig_files(root):
        lines = read(root, rel).splitlines()
        for i, line in enumerate(lines):
            if not code(line):
                continue
            where = "%s:%d" % (rel, i + 1)
            if BROADCAST_RE.search(line):
                problems.append("%s hand-delivers the token by broadcast (%s)"
                                % (where, BROADCAST_RE.search(line).group(0)))
            if token_path and token_path in line:
                problems.append("%s names rhizo-deskd's token file %s"
                                % (where, token_path))
            if AUTHORITY in line:
                problems.append("%s calls the token provider %s itself" % (where, AUTHORITY))
    return problems


def check_units(root):
    """check the deskd and token unit wiring"""
    problems = []
    deskd = unit_text(root, DESKD_UNIT)
    tok = unit_text(root, TOKEN_UNIT)
    deskd_file = token_file(deskd)
    if deskd_file is None:
        return ["%s passes deskd.py no --token-file" % DESKD_UNIT], None
    if token_file(tok) != deskd_file:
        problems.append("%s delivers to %s, but %s reads %s" % (TOKEN_UNIT, token_file(tok), DESKD_UNIT, deskd_file))
    if not any(TOKEN_UNIT_NAME in w.split() for w in unit_key(deskd, "Wants")):
        problems.append("%s has no Wants=%s" % (DESKD_UNIT, TOKEN_UNIT_NAME))
    for key, want in (("PartOf", "rhizo-deskd.service"), ("After", "rhizo-deskd.service"),
                      ("Type", "oneshot"), ("RemainAfterExit", "yes")):
        if not any(want in v.split() for v in unit_key(tok, key)):
            problems.append("%s has no %s=%s" % (TOKEN_UNIT, key, want))
    for line in deskd.splitlines():
        if line.startswith("ExecStartPre") and deskd_file in line:
            problems.append("%s mints on the host again (%s)" % (DESKD_UNIT, line.strip()))
    want = bridge_capabilities(root)
    conds = {}
    for rel, text in ((DESKD_UNIT, deskd), (TOKEN_UNIT, tok)):
        vals = unit_key(text, "ExecCondition")
        words = vals[0].split() if len(vals) == 1 else []
        if len(words) < 2 or not words[0].endswith("/capability-allowed.sh") or words[1] != "--any":
            problems.append("%s has no single ExecCondition=.../capability-allowed.sh --any (got %s)" % (rel, vals))
            continue
        conds[rel] = set(words[2:])
        if conds[rel] != want:
            problems.append("%s system tests on %s, but deskd.py enforces %s" % (rel, sorted(conds[rel]), sorted(want)))
    return problems, deskd_file


def check_android(root):
    """check the desktop bridge manifest and token provider"""
    problems = []
    manifest = read(root, MANIFEST)
    if BROADCAST_RE.search(manifest):
        problems.append("%s still declares the broadcast entry (%s)" % (MANIFEST, BROADCAST_RE.search(manifest).group(0)))
    prov = re.search(r"<provider\s[^>]*android:name=\"\.TokenProvider\"[^>]*>", manifest, re.S)
    if not prov or ('android:authorities="%s"' % AUTHORITY) not in prov.group(0) \
            or 'android:exported="true"' not in prov.group(0):
        problems.append("%s declares no exported .TokenProvider on %s" % (MANIFEST, AUTHORITY))
    bridge = read(root, BRIDGE_SRC + "/BridgeService.java")
    if "DeskAuth.handshake(" not in bridge or re.search(r'put\("token"', bridge):
        problems.append("%s/BridgeService.java does not open the channel with DeskAuth.handshake, or writes a token field" % BRIDGE_SRC)
    src = read(root, PROVIDER_SRC)
    if not re.search(r"Binder\.getCallingUid\(\)", src) or "Process.ROOT_UID" not in src or "Process.SHELL_UID" not in src:
        problems.append("%s does not hold call() to Binder.getCallingUid() in {ROOT_UID, SHELL_UID}" % PROVIDER_SRC)
    for path in sorted(glob.glob(os.path.join(root, BRIDGE_SRC, "*.java"))):
        rel = os.path.relpath(path, root)
        for i, line in enumerate(read(root, rel).splitlines()):
            if code(line) and LOG_TOKEN_RE.search(line):
                problems.append("%s:%d logs a token (%s)" % (rel, i + 1, line.strip()))
    return problems


def check_package(root):
    """check that the packaging installs the delivery files"""
    rules = read(root, RULES)
    problems = []
    for need in (DELIVERER, TOKEN_UNIT):
        if not re.search(r"^\tinstall\b.*\b%s\b" % re.escape(need), rules, re.M) \
                and not re.search(r"\b%s\b[^\n]*\\\n(?:[^\n]*\\\n)*[^\n]*\$\(UNITS\)/" % re.escape(need), rules):
            problems.append("%s never installs %s" % (RULES, need))
    return problems


FAKE_PROBE = r'''import json, os, sys
cmd = sys.argv[3]
with open(os.environ["FAKE_PROBE_RECORD"], "a") as fh:
    fh.write(json.dumps(sys.argv) + "\n")
token = os.environ["FAKE_TOKEN"]
state_path = os.environ["FAKE_STATE"]
with open(state_path) as fh:
    st = json.load(fh)
body = cmd.split("; ", 1)[1] if cmd.startswith("export PATH=") else cmd
ids = lambda: [e.split(";")[0] for e in st["ime_enabled"]]
user0 = st.get("user0", ["RUNNING_UNLOCKED"])
known = lambda ime: ime == "com.android.inputmethod.latin/.LatinIME" or bool(st["android"]) and user0[0] == "RUNNING_UNLOCKED"
out = []
for part in body.split("; "):
    w = part.split()
    if part == "getprop sys.boot_completed":
        out.append("1")
    elif part == "am get-started-user-state 0":
        out.append(user0[0])
        if len(user0) > 1:
            st["user0"] = user0[1:]
    elif w[:2] == ["pm", "path"]:
        out.extend(["package:" + st["android"]] if st["android"] else [])
    elif w[:2] == ["ime", "enable"]:
        if not known(w[2]):
            out.append("Unknown input method %s cannot be enabled for user #0" % w[2])
        elif w[2] not in ids():
            st["ime_enabled"].append(w[2])
    elif w[:2] == ["ime", "set"]:
        if not known(w[2]):
            out.append("Unknown input method %s cannot be selected for user #0" % w[2])
        elif w[2] in ids():
            st["default_ime"] = w[2]
    elif w[:2] == ["ime", "disable"]:
        st["ime_enabled"] = [e for e in st["ime_enabled"] if e.split(";")[0] != w[2]]
        if st["default_ime"] == w[2]:
            st["default_ime"] = ids()[0] if ids() else "null"
    elif w[:3] == ["cmd", "notification", "allow_listener"]:
        st["listeners"] = [l for l in st["listeners"] if l != w[3]] + [w[3]]
    elif w[:3] == ["cmd", "notification", "disallow_listener"]:
        st["listeners"] = [l for l in st["listeners"] if l != w[3]]
    elif w[:2] == ["appops", "set"] and w[3] == "SYSTEM_ALERT_WINDOW":
        if st.get("lost_writes"):
            st["lost_writes"] -= 1
        elif os.environ["FAKE_PROBE_MODE"] != "stuck":
            st["overlay"] = w[4]
    elif w[:2] == ["appops", "get"]:
        out.append("SYSTEM_ALERT_WINDOW: %s; time=+1s12ms ago" % st["overlay"] if st["overlay"] else "No operations.")
    elif w[:3] == ["settings", "get", "secure"]:
        out.append({"default_input_method": st["default_ime"],
                    "enabled_input_methods": ":".join(st["ime_enabled"]) or "null",
                    "enabled_notification_listeners": ":".join(st["listeners"]) or "null"}[w[3]])
    elif "--method mint" in part:
        if os.environ["FAKE_PROBE_MODE"] == "fail":
            out.append("Error while accessing provider:com.rhizo.desktop.token")
            out.append("java.lang.IllegalStateException: leaked " + token)
        else:
            out.append("Result: Bundle[{token=%s}]" % token)
    elif "--method start" in part:
        try:
            held = open(os.environ["FAKE_TOKEN_FILE"]).read().strip()
        except OSError:
            held = ""
        out.append("Result: Bundle[{started=true}]" if held == token else "started before rhizo-deskd held the token")
    else:
        out.append("unexpected command " + part)
with open(state_path, "w") as fh:
    json.dump(st, fh)
print("\n".join(out))
'''

LATIN_ENTRY = LATIN_IME + ";-921088104"
DELIVERER_RUNS = {
    "ok": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                 "listeners": [], "overlay": None},
           {"ime": True, "listener": True, "overlay": "allow"}),
    "off": ("[desktop]\nclipboard = to-android\nnotifications = no\ndrag = no\n",
            {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY, BRIDGE_IME], "default_ime": BRIDGE_IME,
             "listeners": [BRIDGE_LISTENER], "overlay": "allow"},
            {"ime": False, "listener": False, "overlay": "deny"}),
    "fail": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                  "listeners": [], "overlay": None}, None),
    "dataapp": ("", {"android": "/data/app/~~Zx9/com.rhizo.desktop-Q1w/base.apk", "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                     "listeners": [], "overlay": None}, None),
    "restarted": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                       "listeners": [], "overlay": None, "lost_writes": 1},
                  {"ime": True, "listener": True, "overlay": "allow"}),
    "stuck": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                   "listeners": [], "overlay": None}, None),
    "locked": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                    "listeners": [], "overlay": None,
                    "user0": ["RUNNING_LOCKED", "RUNNING_LOCKED", "RUNNING_UNLOCKING", "RUNNING_UNLOCKED"]},
               {"ime": True, "listener": True, "overlay": "allow"}),
    "neverunlocked": ("", {"android": BRIDGE_APK, "ime_enabled": [LATIN_ENTRY], "default_ime": LATIN_IME,
                           "listeners": [], "overlay": None, "user0": ["RUNNING_LOCKED"]}, None),
}


def grants_of(st):
    """return the RhizoDesktop grants from a fake state"""
    ime_ids = [e.split(";")[0] for e in st["ime_enabled"]]
    return {"ime": st["default_ime"] == BRIDGE_IME and BRIDGE_IME in ime_ids,
            "listener": BRIDGE_LISTENER in st["listeners"], "overlay": st["overlay"]}

FAKE_SYSTEMCTL = """#!/bin/sh
[ "$1 $2 $3 $4" = "show -p User --value" ] && { id -un; exit 0; }
echo "unexpected systemctl $*" >&2
exit 1
"""


def check_deliverer(root):
    """run the deliverer against the scripted probe channel"""
    problems = []
    token = "0123456789abcdef0123456789abcdef"
    for mode, (policy_text, state, want) in DELIVERER_RUNS.items():
        tmp = tempfile.mkdtemp(prefix="check-desk-token-delivery.")
        try:
            bindir = os.path.join(tmp, "bin")
            os.makedirs(bindir)
            os.makedirs(os.path.join(tmp, "rhizo-desk"))
            with open(os.path.join(bindir, "systemctl"), "w") as fh:
                fh.write(FAKE_SYSTEMCTL)
            os.chmod(os.path.join(bindir, "systemctl"), 0o755)
            probe = os.path.join(tmp, "probe.py")
            with open(probe, "w") as fh:
                fh.write(FAKE_PROBE)
            state_path = os.path.join(tmp, "state.json")
            with open(state_path, "w") as fh:
                json.dump(state, fh)
            policy = os.path.join(tmp, "policy.conf")
            if policy_text:
                with open(policy, "w") as fh:
                    fh.write(policy_text)
            record = os.path.join(tmp, "record")
            tfile = os.path.join(tmp, "rhizo-desk", "token")
            env = dict(os.environ, PATH=bindir + os.pathsep + os.environ.get("PATH", ""),
                       FAKE_PROBE_RECORD=record, FAKE_TOKEN=token, FAKE_PROBE_MODE=mode, FAKE_TOKEN_FILE=tfile,
                       FAKE_STATE=state_path, RHIZO_POLICY_CONF=policy, RHIZO_SANDBOX_ID="0")
            proc = subprocess.run([sys.executable, os.path.join(root, DELIVERER), "--port", "47100",
                                   "--token-file", tfile, "--probe-client", probe,
                                   "--probe-sock", os.path.join(tmp, "sock"), "--boot-timeout", "5",
                                   "--grant-timeout", "2"],
                                  capture_output=True, text=True, env=env, timeout=60)
            said = proc.stdout + proc.stderr
            argvs = [json.loads(l) for l in open(record)] if os.path.exists(record) else []
            with open(state_path) as fh:
                held = grants_of(json.load(fh))
            if token in said:
                problems.append("%s (%s): its own output carries the token: %s" % (DELIVERER, mode, said.strip()[:300]))
            if any(token in " ".join(a) for a in argvs):
                problems.append("%s (%s): the token went into a probe client's argv" % (DELIVERER, mode))
            if want is not None:
                if held != want:
                    problems.append("%s (%s): the policy decides the android app's grants %s, Android was left holding %s"
                                    % (DELIVERER, mode, want, held))
                if "RHIZO_DESK_BRIDGE_GRANTS " not in said:
                    problems.append("%s (%s): never logged RHIZO_DESK_BRIDGE_GRANTS: %s" % (DELIVERER, mode, said.strip()[:300]))
                if proc.returncode != 0 or "RHIZO_DESK_TOKEN_DELIVERED" not in said:
                    problems.append("%s (%s): rc=%d without RHIZO_DESK_TOKEN_DELIVERED: %s" % (DELIVERER, mode, proc.returncode, said.strip()[:300]))
                if not os.path.exists(tfile) or open(tfile).read() != token + "\n":
                    problems.append("%s (%s): %s does not hold exactly the minted token" % (DELIVERER, mode, tfile))
                elif stat.S_IMODE(os.stat(tfile).st_mode) != 0o600:
                    problems.append("%s (%s): the token file is mode %o, not 0600" % (DELIVERER, mode, stat.S_IMODE(os.stat(tfile).st_mode)))
                if not any("--method start" in a[-1] for a in argvs):
                    problems.append("%s (%s): never asked the app to reconnect (--method start)" % (DELIVERER, mode))
            elif mode == "dataapp":
                if proc.returncode == 0 or os.path.exists(tfile) or any("--method mint" in a[-1] for a in argvs):
                    problems.append("%s (dataapp): with the android app on /data, not /system_ext, it still minted or exited 0 (rc=%d): %s"
                                    % (DELIVERER, proc.returncode, said.strip()[:300]))
            elif mode == "neverunlocked":
                wrote = [a[-1] for a in argvs if " ime " in " " + a[-1]]
                if proc.returncode == 0 or os.path.exists(tfile) or wrote or "RUNNING_UNLOCKED" not in said:
                    problems.append("%s (neverunlocked): with user 0 never unlocked it still wrote %s, delivered, or failed "
                                    "without naming RUNNING_UNLOCKED (rc=%d): %s"
                                    % (DELIVERER, wrote or "no grant", proc.returncode, said.strip()[:300]))
            elif mode == "stuck":
                if proc.returncode == 0 or "RHIZO_DESK_BRIDGE_GRANTS " in said or os.path.exists(tfile):
                    problems.append("%s (stuck): Android ignored the overlay write and it still reported its grants set (rc=%d): %s"
                                    % (DELIVERER, proc.returncode, said.strip()[:300]))
            else:
                if proc.returncode == 0:
                    problems.append("%s (fail): a failed mint exited 0" % DELIVERER)
                if os.path.exists(tfile):
                    problems.append("%s (fail): a failed mint still wrote %s" % (DELIVERER, tfile))
                if "<redacted>" not in said:
                    problems.append("%s (fail): the failed mint's output reached the log unredacted or not at all: %s" % (DELIVERER, said.strip()[:300]))
        finally:
            shutil.rmtree(tmp)
    return problems

HARNESS_JAVA = r"""package com.rhizo.desktop;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

public class Harness {
    public static void main(String[] args) throws Exception {
        Socket s = new Socket();
        s.connect(new InetSocketAddress("127.0.0.1", Integer.parseInt(args[0])), 5000);
        s.setSoTimeout(5000);
        final BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
        final Writer w = new OutputStreamWriter(s.getOutputStream(), StandardCharsets.UTF_8);
        try {
            DeskAuth.handshake(new DeskAuth.Lines() {
                public String read() throws IOException {
                    return r.readLine();
                }

                public void write(String line) throws IOException {
                    w.write(line + "\n");
                    w.flush();
                }
            }, args[1], new SecureRandom());
            System.out.println("HANDSHAKE " + r.readLine());
        } catch (DeskAuth.HostUnproven e) {
            System.out.println("HOST_UNPROVEN " + e.getMessage());
        }
        s.close();
    }
}
"""

FAKE_WLBRIDGE = """#!/usr/bin/env python3
import sys
print("ready", flush=True)
for line in sys.stdin:
    if line.strip() == "quit":
        break
    if line.startswith("get "):
        print("nodata %s" % line.split(" ", 1)[1].strip(), flush=True)
"""

MUTUAL_TOKEN = "fedcba9876543210fedcba9876543210"
_compiled = {}


def free_port():
    """return a free TCP port on the loopback address"""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def compile_android_auth(root, work):
    """compile DeskAuth.java and return the classes directory"""
    src = read(root, BRIDGE_SRC + "/DeskAuth.java")
    if src in _compiled:
        return _compiled[src]
    for tool in ("javac", "java"):
        if shutil.which(tool) is None:
            return "no %s on this host" % tool
    pkg = os.path.join(work, "src", "com", "rhizo", "desktop")
    os.makedirs(pkg)
    with open(os.path.join(pkg, "DeskAuth.java"), "w") as fh:
        fh.write(src)
    with open(os.path.join(pkg, "Harness.java"), "w") as fh:
        fh.write(HARNESS_JAVA)
    classes = tempfile.mkdtemp(prefix="check-desk-token-delivery.classes.")
    proc = subprocess.run(["javac", "-d", classes, os.path.join(pkg, "DeskAuth.java"), os.path.join(pkg, "Harness.java")],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return "javac refused %s/DeskAuth.java: %s" % (BRIDGE_SRC, proc.stderr.strip()[:400])
    _compiled[src] = classes
    return classes


def run_android(classes, port, token):
    """run the Java harness and return its output"""
    proc = subprocess.run(["java", "-cp", classes, "com.rhizo.desktop.Harness", str(port), token],
                          capture_output=True, text=True, timeout=30)
    return (proc.stdout + proc.stderr).strip()


def unproven_server(port, record, ready):
    """accept a connection and record its bytes"""
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    srv.settimeout(20)
    ready.set()
    try:
        conn, _ = srv.accept()
    except OSError:
        srv.close()
        return
    conn.settimeout(3)
    got = b""
    try:
        while b"\n" not in got:
            chunk = conn.recv(4096)
            if not chunk:
                break
            got += chunk
        conn.sendall(json.dumps({"t": "challenge", "nonce": os.urandom(16).hex(), "proof": os.urandom(32).hex()},
                                separators=(",", ":")).encode() + b"\n")
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            got += chunk
    except OSError:
        pass
    record.append(got)
    conn.close()
    srv.close()


def check_mutual(root):
    """check the RhizoDesktop hello with rhizo-deskd"""
    problems = []
    work = tempfile.mkdtemp(prefix="check-desk-token-delivery.mutual.")
    deskd = None
    try:
        classes = compile_android_auth(root, work)
        if not os.path.isdir(classes):
            return [classes]

        port = free_port()
        record, ready = [], threading.Event()
        t = threading.Thread(target=unproven_server, args=(port, record, ready))
        t.start()
        ready.wait(10)
        said = run_android(classes, port, MUTUAL_TOKEN)
        t.join(30)
        got = record[0] if record else b""
        lines = [l for l in got.split(b"\n") if l.strip()]
        if not said.startswith("HOST_UNPROVEN"):
            problems.append("DeskAuth: the android app went on with a server that never proved the token (%s)" % said[:200])
        if len(lines) != 1 or b'"hello"' not in lines[0] or b'"nonce"' not in lines[0]:
            problems.append("DeskAuth: an unproven server received %d line(s) from the android app, wanted only its nonce hello: %r"
                            % (len(lines), got[:300]))
        if MUTUAL_TOKEN.encode() in got:
            problems.append("DeskAuth: the token itself reached a server that never proved it")

        wl = os.path.join(work, "fake-wlbridge.py")
        with open(wl, "w") as fh:
            fh.write(FAKE_WLBRIDGE)
        os.chmod(wl, 0o755)
        port = free_port()
        log_path = os.path.join(work, "deskd.log")
        env = dict(os.environ, RHIZO_POLICY_CONF=os.path.join(work, "absent-policy.conf"))
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        with open(log_path, "w") as log_fh:
            deskd = subprocess.Popen([sys.executable, os.path.join(root, "src", "services", "deskbridge", "deskd.py"), "--port", str(port),
                                      "--token", MUTUAL_TOKEN, "--bridge", wl, "--bind", "127.0.0.1"],
                                     stdout=log_fh, stderr=subprocess.STDOUT, env=env)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and "listening on" not in open(log_path).read():
            if deskd.poll() is not None:
                break
            time.sleep(0.1)
        if "listening on" not in open(log_path).read():
            return problems + ["rhizo-deskd never listened: %s" % open(log_path).read()[-400:]]
        said = run_android(classes, port, MUTUAL_TOKEN)
        if said != 'HANDSHAKE {"t":"hello_ok"}':
            problems.append("the android app and the real rhizo-deskd, holding one token, did not complete the hello (%s)" % said[:200])
        wrong = run_android(classes, port, "0" * 32)
        if not wrong.startswith("HOST_UNPROVEN"):
            problems.append("an android app holding another token accepted the real rhizo-deskd's proof (%s)" % wrong[:200])
        time.sleep(0.3)
        authed = open(log_path).read().count("android app authenticated")
        if authed != (1 if said.startswith("HANDSHAKE") else 0):
            problems.append("rhizo-deskd logged 'android app authenticated' %d time(s) across one right and one wrong token" % authed)
    finally:
        if deskd is not None and deskd.poll() is None:
            deskd.terminate()
            try:
                deskd.wait(10)
            except subprocess.TimeoutExpired:
                deskd.kill()
        shutil.rmtree(work)
    return problems


def check(root):
    """return the problems from every check on the tree"""
    try:
        problems, token_path = check_units(root)
        problems += check_rig(root, token_path)
        problems += check_android(root)
        problems += check_package(root)
    except FileNotFoundError as exc:
        return ["%s is missing" % exc.filename]
    return problems + check_deliverer(root) + check_mutual(root)


def selftest():
    """run each planted-defect case"""
    cases = []

    def one(name, plant, want):
        """run the check on a planted tree copy"""
        tmp = tempfile.mkdtemp(prefix="check-desk-token-delivery.self.")
        try:
            for rel in ("tools", "test/vm", "test/system", "test/checks", "src/services/deskbridge",
                        "src/services/broker", "src/services/broker/inbox_stage.py", "src/services/units",
                        "src/android/apps/desktop-bridge"):
                if os.path.isdir(os.path.join(REPO, rel)):
                    shutil.copytree(os.path.join(REPO, rel), os.path.join(tmp, rel), symlinks=True,
                                    ignore=shutil.ignore_patterns("__pycache__"))
                else:
                    os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                    shutil.copy(os.path.join(REPO, rel), os.path.join(tmp, rel))
            for rel in (CAPS_TSV, RULES, CAPS_MODULE):
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                shutil.copy(os.path.join(REPO, rel), os.path.join(tmp, rel))
            for rel, (old, new) in plant.items():
                path = os.path.join(tmp, rel)
                text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
                if old is not None and old not in text:
                    return True, "SELFTEST FAIL: %s: the plant anchor %r is not in %s" % (name, old, rel)
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text.replace(old, new, 1) if old is not None else text + new)
            got = check(tmp)
        finally:
            shutil.rmtree(tmp)
        hit = [p for p in got if want and want in p]
        if want is None and got:
            return True, "SELFTEST FAIL: %s: flagged %s" % (name, got)
        if want is not None and not hit:
            return True, "SELFTEST FAIL: %s: wanted a finding with %r, got %s" % (name, want, got)
        return False, "SELFTEST OK: %s" % name

    def run(name, plant, want):
        """record a planted case to run later"""
        cases.append((name, plant, want))

    test = "test/system/desktop/desktop.sh"
    cycle = "test/system/cycle/cycle.sh"
    old_broadcast = ('android_sh "$INIT" "am broadcast -f 0x00000020 -n $BRIDGE_PKG/$BRIDGE_PKG.StartReceiver '
                     '-a com.rhizo.desktop.START --es token $token --ei port $DESK_PORT" >/dev/null 2>&1\n')
    run("the tree as committed passes", {}, None)
    run("the retired system test broadcast is flagged", {test: (None, old_broadcast)}, "hand-delivers the token by broadcast")
    run("a cycle reading the token file is flagged",
        {cycle: (None, 'tok=$(ssh_vm "runuser -u ubuntu -- cat /run/rhizo-desk/token")\n')}, "names rhizo-deskd's token file")
    run("a system test calling the provider itself is flagged",
        {test: (None, 'android_sh "$INIT" "content call --uri content://com.rhizo.desktop.token --method mint --arg 47100"\n')},
        "calls the token provider")
    run("a python rig helper reading the token file is flagged",
        {"test/vm/desk-token-peek.py": (None, 'print(open("/run/rhizo-desk/token").read())\n')}, "names rhizo-deskd's token file")
    run("a comment naming the broadcast is not flagged", {test: (None, "# the old path was am broadcast ... --es token\n")}, None)
    run("deskd without Wants= on the delivery is flagged",
        {DESKD_UNIT: ("Wants=rhizo-desk-token.service\n", "")}, "has no Wants=rhizo-desk-token.service")
    run("a delivery unit not PartOf deskd is flagged", {TOKEN_UNIT: ("PartOf=rhizo-deskd.service\n", "")}, "has no PartOf=rhizo-deskd.service")
    run("a delivery unit that exits inactive is flagged", {TOKEN_UNIT: ("RemainAfterExit=yes\n", "")}, "has no RemainAfterExit=yes")
    run("a delivery to another file than deskd reads is flagged",
        {TOKEN_UNIT: ("--token-file /run/rhizo-desk/token", "--token-file /run/rhizo-desk/other")}, "delivers to /run/rhizo-desk/other")
    run("the retired host mint is flagged",
        {DESKD_UNIT: ("ExecCondition=", "ExecStartPre=/bin/sh -c 'head -c 16 /dev/urandom > /run/rhizo-desk/token'\nExecCondition=")},
        "mints on the host again")
    run("a delivery gated on fewer capabilities than deskd is flagged",
        {TOKEN_UNIT: (" desktop.open_uri\n", "\n")}, "system tests on")
    run("a deskd with no capability gate is flagged",
        {DESKD_UNIT: ("ExecCondition=", "#ExecCondition=")}, "has no single ExecCondition")
    run("the broadcast receiver back in the manifest is flagged",
        {MANIFEST: ("<provider android:name=\".TokenProvider\"",
                    "<receiver android:name=\".StartReceiver\" android:exported=\"true\"/>\n        <provider android:name=\".TokenProvider\"")},
        "still declares the broadcast entry")
    run("an unexported provider is flagged",
        {MANIFEST: ('android:authorities="com.rhizo.desktop.token"\n                  android:exported="true"',
                    'android:authorities="com.rhizo.desktop.token"\n                  android:exported="false"')},
        "declares no exported .TokenProvider")
    run("a provider with no caller check is flagged",
        {PROVIDER_SRC: ("uid != Process.SHELL_UID", "uid != 2000")}, "does not hold call()")
    run("the android app logging its token is flagged",
        {BRIDGE_SRC + "/BridgeService.java": ('Logs.i("RHIZO_DESK_CONNECTED port=" + port);',
                                             'Logs.i("RHIZO_DESK_CONNECTED token=" + token);')}, "logs a token")
    run("a package that drops the delivery unit is flagged",
        {RULES: ("\tinstall -D -m 0644 src/services/deskbridge/desk-token.service $(UNITS)/rhizo-desk-token.service\n", "")}, "never installs src/services/deskbridge/desk-token.service")
    run("a deliverer logging the raw mint output is flagged",
        {DELIVERER: ('log("FAIL: mint over rhizo-probed (rc=%d): %s" % (rc, redact(out.strip())[:600]))',
                     'log("FAIL: mint over rhizo-probed (rc=%d): %s" % (rc, out.strip()[:600]))')},
        "unredacted or not at all")
    run("a deliverer passing the token in argv is flagged",
        {DELIVERER: ('"content call --uri %s --method start" % AUTHORITY_URI',
                     '"content call --uri %s --method start --arg %s" % (AUTHORITY_URI, found.group(1))')},
        "went into a probe client's argv")
    run("a deliverer that starts the app before deskd holds the token is flagged",
        {DELIVERER: ("    if not write_token(args.token_file, found.group(1), user):\n        return 1\n\n", "")},
        "without RHIZO_DESK_TOKEN_DELIVERED")
    run("a deliverer that never asks the app to reconnect is flagged",
        {DELIVERER: ('    rc, out = probe(args, "content call --uri %s --method start" % AUTHORITY_URI, 30)\n',
                     '    rc, out = 0, "Result: Bundle[{started=true}]"\n')},
        "never asked the app to reconnect")
    run("a deliverer that never sets the android app's grants is flagged",
        {DELIVERER: ("    if not set_grants(args, wanted_grants(policy)):\n        return 1\n", "")},
        "(ok): the policy decides the android app's grants")
    run("a deliverer that leaves a withheld crossing's grant in place is flagged",
        {DELIVERER: ('else "ime disable %s" % IME_ID', 'else "true"')}, "(off): ")
    run("a deliverer that grants the listener whatever the policy says is flagged",
        {DELIVERER: ('"listener": policy.allows("desktop.notifications")', '"listener": True')},
        "(off): the policy decides the android app's grants")
    run("a deliverer that trusts its writes without reading them back is flagged",
        {DELIVERER: ("        held = held_grants(args)\n", "        held = dict(want)\n")}, "(stuck)")
    run("a deliverer that grants on sys.boot_completed before user 0 unlocks is flagged",
        {DELIVERER: ('out.split() == ["1", "RUNNING_UNLOCKED"]', 'out.split()[:1] == ["1"]')}, "(locked)")
    run("a deliverer that writes grants without waiting at all is flagged",
        {DELIVERER: ("    if not wait_for_unlock(args):\n        return 1\n", "")}, "(neverunlocked)")
    run("a deliverer that mints for a /data copy of the android app is flagged",
        {DELIVERER: ('    if rc != 0 or out.strip() != "package:" + BRIDGE_APK:\n', '    if rc != 0:\n')},
        "(dataapp)")
    run("an android app that skips the host's proof is flagged",
        {BRIDGE_SRC + "/DeskAuth.java": ("if (!MessageDigest.isEqual(want, m.group(2).getBytes(StandardCharsets.US_ASCII))) {",
                                        "if (want.length == 0) {")},
        "went on with a server that never proved the token")
    run("an android app that puts the token in its hello is flagged",
        {BRIDGE_SRC + "/DeskAuth.java": ('io.write("{\\"t\\":\\"hello\\",\\"nonce\\":\\"" + androidNonce + "\\"}");',
                                        'io.write("{\\"t\\":\\"hello\\",\\"nonce\\":\\"" + androidNonce + "\\",\\"token\\":\\"" + token + "\\"}");')},
        "the token itself reached a server")
    run("a deskd that signs its proof with the android app's label is flagged",
        {"src/services/deskbridge/deskd.py": ('"proof": desk_proof(token, "host", android_nonce, host_nonce)',
                                            '"proof": desk_proof(token, "android", android_nonce, host_nonce)')},
        "did not complete the hello")
    run("a BridgeService back on the token hello is flagged",
        {BRIDGE_SRC + "/BridgeService.java": ("            DeskAuth.handshake(new DeskAuth.Lines() {",
                                             "            new JSONObject().put(\"token\", token);\n            DeskAuth.handshake(new DeskAuth.Lines() {")},
        "does not open the channel with DeskAuth.handshake")
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda c: one(*c), cases))
    for _failed, line in results:
        print(line)
    return 1 if any(failed for failed, _ in results) else 0


def main():
    """run the check or its selftest and print the result"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    problems = check(args.root)
    for p in problems:
        print("FAIL: " + p)
    if problems:
        return 1
    print("check-desk-token-delivery: no rig code hand-delivers the bridge token, and the product's own delivery is wired, shipped and keeps the token out of argv and logs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
