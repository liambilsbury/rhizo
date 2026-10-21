#!/usr/bin/env python3
import argparse
import errno
import json
import os
import re
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

SOURCE = "src/android/native/probed/probed.cpp"
BUILD = "tools/build/native/probed.sh"
TRAILER = b"\x00RHIZO_PROBE_RC="
ACL_XATTR = "system.posix_acl_access"
ACL_USER_OBJ, ACL_USER, ACL_GROUP_OBJ, ACL_GROUP, ACL_MASK, ACL_OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
RW = 0x04 | 0x02
READY_S = 10

PEER_UID_RE = re.compile(r"static\s+const\s+uid_t\s+kPeerUid\s*=\s*([^;]+);")
CHMOD_RE = re.compile(r"\bchmod\s*\([^,]+,\s*(0[0-7]+)\s*\)")


def function_body(text, head):
    """return the text of a top-level function"""
    at = text.find(head)
    if at < 0:
        return ""
    end = text.find("\n}\n", at)
    return text[at:end if end >= 0 else len(text)]


def static_problems(text, build_text):
    """list the defects in the source text"""
    found = []
    text = re.sub(r"//[^\n]*", "", text)
    m = PEER_UID_RE.search(text)
    if not m:
        found.append("%s declares no kPeerUid" % SOURCE)
    elif m.group(1).strip() != "0":
        found.append("%s serves peer uid %s, not root" % (SOURCE, m.group(1).strip()))
    if not re.search(r"getsockopt\s*\([^;]*SO_PEERCRED", text):
        found.append("%s never reads SO_PEERCRED" % SOURCE)
    conn = function_body(text, "static void handle_conn(")
    fork_at = conn.find("fork()")
    if fork_at < 0 or "peer_allowed(" not in conn[:fork_at]:
        found.append("%s handle_conn() does not check the peer before fork()" % SOURCE)
    body = function_body(text, "int main(")
    for mode in CHMOD_RE.findall(text):
        if int(mode, 8) & 0o077:
            found.append("%s chmods the socket %s, open to group or other" % (SOURCE, mode))
    if not CHMOD_RE.search(text):
        found.append("%s never chmods the socket" % SOURCE)
    rs, ls = body.find("restrict_socket("), body.find("listen(")
    if rs < 0 or ls < 0 or rs > ls:
        found.append("%s main() does not restrict the socket before listen()" % SOURCE)
    if "RHIZO_PROBED_" in build_text:
        found.append("%s overrides a RHIZO_PROBED_ macro in the shipped build" % BUILD)
    return found


def parse_acl(blob):
    """return the entries of a posix acl xattr"""
    if len(blob) < 4 or (len(blob) - 4) % 8:
        return None
    return [struct.unpack_from("<HHI", blob, 4 + 8 * i) for i in range((len(blob) - 4) // 8)]


def socket_problems(path):
    """list the socket mode and acl problems"""
    found = []
    mode = os.stat(path).st_mode
    if mode & 0o007:
        found.append("the socket is mode %04o, open to other" % stat.S_IMODE(mode))
    try:
        entries = parse_acl(os.getxattr(path, ACL_XATTR))
    except OSError as e:
        if e.errno not in (errno.ENODATA, errno.ENOTSUP):
            raise
        entries = []
    if entries is None:
        return found + ["the socket's acl xattr does not parse"]
    named = [(t, p, i) for t, p, i in entries if t in (ACL_USER, ACL_GROUP)]
    if (ACL_USER, RW, 0) not in named:
        found.append("the socket has no acl entry giving uid 0 rw")
    for t, p, i in named:
        if (t, p, i) != (ACL_USER, RW, 0):
            found.append("the socket's acl admits %s %d" % ("user" if t == ACL_USER else "group", i))
    for t, p, _ in entries:
        if t in (ACL_GROUP_OBJ, ACL_OTHER) and p:
            found.append("the socket's acl gives %s perm %o" % ("group" if t == ACL_GROUP_OBJ else "other", p))
    return found


def build_host(src, out_dir):
    """compile src for this host"""
    binary = os.path.join(out_dir, "probed")
    sock = os.path.join(out_dir, "p.sock")
    proc = subprocess.run(["g++", "-O1", "-o", binary, '-DRHIZO_PROBED_SOCK="%s"' % sock,
                           '-DRHIZO_PROBED_SH="/bin/sh"', src], capture_output=True, text=True)
    if proc.returncode != 0:
        return None, None, "the host build failed: %s" % proc.stderr.strip()[-400:]
    return binary, sock, None


def run_leg(binary, sock, marker):
    """run the binary and send a command"""
    server = subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              start_new_session=True)
    result = {"connected": False, "reply": "", "trailer": False, "ran": False, "socket": [], "exit": None}
    try:
        deadline = time.monotonic() + READY_S
        conn = None
        while conn is None and time.monotonic() < deadline and server.poll() is None:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                c.connect(sock)
                conn = c
            except (FileNotFoundError, ConnectionRefusedError):
                c.close()
                time.sleep(0.02)
        if conn is None:
            if server.poll() is None:
                server.kill()
            result["exit"] = server.wait()
            result["reply"] = server.stderr.read().decode(errors="replace").strip()[-300:]
            return result
        result["connected"] = True
        result["socket"] = socket_problems(sock)
        conn.settimeout(READY_S)
        buf = b""
        try:
            conn.sendall(("touch %s\n" % marker).encode())
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            buf += b" <no EOF within %ds>" % READY_S
        except OSError as e:
            buf += b" <%s>" % e.strerror.encode()
        conn.close()
        result["trailer"] = TRAILER in buf
        result["reply"] = buf.replace(b"\x00", b" ").decode(errors="replace").strip()[:300]
        result["ran"] = os.path.exists(marker)
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait()
    return result


def functional_problems(src):
    """build and run the host binary"""
    if os.geteuid() == 0:
        return ["the functional legs need a non-root runner to hold a non-root peer"]
    found = []
    tmp = tempfile.mkdtemp(prefix="probed-")
    try:
        binary, sock, err = build_host(src, tmp)
        if err:
            return [err]
        leg = run_leg(binary, sock, os.path.join(tmp, "ran-as-%d" % os.getuid()))
        if not leg["connected"]:
            return ["the daemon never listened (exit %s): %s" % (leg["exit"], leg["reply"])]
        found += leg["socket"]
        if leg["ran"] or leg["trailer"]:
            found.append("a uid %d peer had its command run" % os.getuid())
        elif "RHIZO_PROBE_REFUSED" not in leg["reply"]:
            found.append("a uid %d peer was dropped without RHIZO_PROBE_REFUSED: %r" % (os.getuid(), leg["reply"]))
        os.unlink(sock)
        proc = subprocess.run(["unshare", "-r", sys.executable, os.path.abspath(__file__), "--root-leg", binary, sock,
                               os.path.join(tmp, "ran-as-root")], capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            return found + ["the uid 0 leg did not run (rc %d): %s" % (proc.returncode, proc.stderr.strip()[-300:])]
        root = json.loads(proc.stdout)
        if not (root["connected"] and root["ran"] and root["trailer"]):
            found.append("a uid 0 peer was not served: %r" % root["reply"])
    finally:
        shutil.rmtree(tmp)
    return found


def check(root):
    """check the probed-peer source"""
    src = os.path.join(root, SOURCE)
    text = open(src, encoding="utf-8").read()
    build_text = open(os.path.join(root, BUILD), encoding="utf-8").read()
    return static_problems(text, build_text) + functional_problems(src)


def selftest():
    """run each planted-defect case"""
    bad = 0

    def run(name, plant, want):
        """run the check on a copy of the source with a planted change"""
        nonlocal bad
        tmp = tempfile.mkdtemp(prefix="check-probed-peer.self.")
        try:
            for rel in (SOURCE, BUILD):
                os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
                shutil.copy(os.path.join(REPO, rel), os.path.join(tmp, rel))
            for rel, (old, new) in plant.items():
                path = os.path.join(tmp, rel)
                text = open(path, encoding="utf-8").read()
                if old not in text:
                    print("SELFTEST FAIL: %s: the plant anchor %r is not in %s" % (name, old, rel))
                    bad += 1
                    return
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text.replace(old, new, 1))
            got = check(tmp)
        finally:
            shutil.rmtree(tmp)
        hit = [p for p in got if want and want in p]
        if want is None and got:
            print("SELFTEST FAIL: %s: flagged %s" % (name, got))
            bad += 1
        elif want is not None and not hit:
            print("SELFTEST FAIL: %s: wanted a finding with %r, got %s" % (name, want, got))
            bad += 1
        else:
            print("SELFTEST OK: %s" % name)

    uid = os.getuid()
    test = "    if (!peer_allowed(cfd, &cred)) {\n        refuse(cfd, &cred);\n        return;\n    }\n"
    acl_user = "{ACL_USER, ACL_READ | ACL_WRITE, (__u32)kPeerUid},"
    restrict = ("    if (restrict_socket(SOCK_PATH) != 0) {\n"
                "        note(\"restrict %s to owner and uid %d: %s\", SOCK_PATH, (int)kPeerUid, strerror(errno));\n"
                "        return 1;\n    }\n")
    run("the tree as committed passes", {}, None)
    run("a daemon with no peer check is flagged at runtime", {SOURCE: (test, "")}, "peer had its command run")
    run("a daemon with no peer check is flagged in the source", {SOURCE: (test, "")}, "does not check the peer before fork()")
    run("a peer check that passes everyone is flagged",
        {SOURCE: ("return cred->uid == kPeerUid;", "return true;")}, "peer had its command run")
    run("a non-root peer uid is flagged in the source",
        {SOURCE: ("kPeerUid = 0;", "kPeerUid = %d;" % uid)}, "serves peer uid %d" % uid)
    run("a non-root peer uid locks root out",
        {SOURCE: ("kPeerUid = 0;", "kPeerUid = %d;" % uid)}, "uid 0 peer was not served")
    run("the retired 0666 socket is flagged",
        {SOURCE: ("if (chmod(path, 0600) != 0) return -1;", "if (chmod(path, 0666) != 0) return -1;")},
        "chmods the socket 0666")
    run("a socket with no acl and 0666 is flagged at runtime",
        {SOURCE: ('    return setxattr(path, "system.posix_acl_access", &acl, sizeof(acl), 0);',
                  "    (void)acl;\n    return chmod(path, 0666);")},
        "open to other")
    run("a socket with no uid 0 acl entry is flagged",
        {SOURCE: (acl_user, "{ACL_USER, ACL_READ | ACL_WRITE, (__u32)%d}," % (uid + 1))}, "no acl entry giving uid 0")
    run("an acl open to other is flagged",
        {SOURCE: ("{ACL_OTHER, 0,", "{ACL_OTHER, ACL_READ | ACL_WRITE,")}, "acl gives other perm")
    run("restricting after listen() is flagged",
        {SOURCE: (restrict + "    if (listen(lfd, 32) < 0) { perror(\"listen\"); return 1; }\n",
                  "    if (listen(lfd, 32) < 0) { perror(\"listen\"); return 1; }\n" + restrict)},
        "before listen()")
    run("a shipped build overriding the socket is flagged",
        {BUILD: ("tools/build/hal/hal.sh rhizo-probed src/android/native/probed/probed.cpp\n",
                 "RHIZO_PROBED_SOCK=/tmp/x tools/build/hal/hal.sh rhizo-probed src/android/native/probed/probed.cpp\n")},
        "overrides a RHIZO_PROBED_ macro")
    return 1 if bad else 0


def main():
    """run the check, its selftest or a root leg and print the result"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--root-leg", nargs=3, metavar=("BINARY", "SOCK", "MARKER"), help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.root_leg:
        print(json.dumps(run_leg(*args.root_leg)))
        return 0
    if args.selftest:
        return selftest()
    problems = check(args.root)
    for p in problems:
        print("FAIL: " + p)
    if problems:
        return 1
    print("check-probed-peer: rhizo-probed serves only uid 0, and its socket admits only its owner and root")
    return 0


if __name__ == "__main__":
    sys.exit(main())
