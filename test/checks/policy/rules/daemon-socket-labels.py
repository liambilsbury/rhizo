#!/usr/bin/env python3
"""Check the daemon socket labels against the compiled policy"""

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

SOCKETS = (
    ("rhizo_rtd", "rhizo_rt_socket", "rtd", ("rhizo_power",)),
    ("rhizo_headroomd", "rhizo_headroom_socket", "headroomd", ("rhizo_power",)),
    ("rhizo_delayd", "rhizo_delay_socket", "delayd", ("rhizo_host_delay",)),
)
COLD_DIR = "tmpfs"
TT_RE = re.compile(r'^type_transition (\S+) (\S+):sock_file (\S+)(?: ("?)([^";\s]+)\4)?;$')


def created_type(tt_out, name, parent):
    """return the type sesearch gives a new sock_file in a parent"""
    named, plain = set(), set()
    for line in tt_out.splitlines():
        m = TT_RE.match(line.strip())
        if not m:
            continue
        if m.group(5) is None:
            plain.add(m.group(3))
        elif m.group(5) == name:
            named.add(m.group(3))
    pick = named or plain
    if len(pick) > 1:
        return None
    return next(iter(pick)) if pick else parent


def needs(daemon, parent, got, clients):
    """return the rules a socket's bind and connects need"""
    rows = [(daemon, parent, "dir", {"search", "write", "add_name", "remove_name"}),
            (daemon, got, "sock_file", {"create", "unlink"}),
            (daemon, COLD_DIR, "sock_file", {"unlink"})]
    for c in clients:
        rows += [(c, parent, "dir", {"search"}),
                 (c, got, "sock_file", {"write"}),
                 (c, daemon, "unix_stream_socket", {"connectto"})]
    return rows


def check(policy, sockets=SOCKETS, weakened=frozenset()):
    """return the problems with each daemon's socket label"""
    bad = []
    for daemon, sock, name, clients in sockets:
        for parent in (COLD_DIR, sock):
            where = "%s binding %s in a %s directory" % (daemon, name, parent)
            got = created_type(policy.type_trans(daemon, parent), name, parent)
            if got is None:
                bad.append("%s: the policy holds conflicting type_transitions" % where)
                continue
            if got != sock:
                bad.append("%s makes a %s socket, not %s" % (where, got, sock))
            for src, tgt, cls, perms in needs(daemon, parent, got, clients):
                if tgt in weakened:
                    bad.append("%s: policy.lab drops a deny on %s" % (where, tgt))
                    continue
                missing = perms - policy.perms(src, tgt, cls)
                if missing:
                    bad.append("%s: %s lacks %s on %s %s" % (where, src, " ".join(sorted(missing)), tgt, cls))
    return bad


class LabPolicy:
    """the compiled lab policy"""

    def __init__(self, access, policy):
        """keep the restart-access module and the policy path"""
        self.access = access
        self.policy = policy

    def type_trans(self, src, tgt):
        """return sesearch's sock_file type_transition lines for a source and target"""
        r = subprocess.run(["bash", "test/checks/lib/avc-lab.sh", "search", "--type_trans", "-s", src, "-t", tgt,
                            "-c", "sock_file", "--policy", self.policy], cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("sesearch --type_trans -s %s -t %s: rc=%d %s"
                               % (src, tgt, r.returncode, r.stderr.strip()[:300]))
        return r.stdout

    def perms(self, src, tgt, cls):
        """return the perms the policy allows a source on a target class"""
        have, err = self.access.granted(REPO, self.policy, src, tgt, cls)
        if have is None:
            raise RuntimeError("sesearch --allow -s %s -t %s -c %s: %s" % (src, tgt, cls, err))
        return have


class FakePolicy:
    """a policy made of type_transition lines and grants"""

    def __init__(self, tts, grants):
        """keep the type_transition lines and the grants"""
        self.tts = tts
        self.grants = grants

    def type_trans(self, src, tgt):
        """return the type_transition lines for a source and target"""
        return "\n".join(self.tts.get((src, tgt), ())) + "\n"

    def perms(self, src, tgt, cls):
        """return the granted perms"""
        return set(self.grants.get((src, tgt, cls), ()))


def good_fake():
    """return the type_transition lines and grants that pass"""
    tts, grants = {}, {}
    for daemon, sock, _name, clients in SOCKETS:
        tts[(daemon, COLD_DIR)] = ["type_transition %s %s:sock_file %s;" % (daemon, COLD_DIR, sock)]
        for parent in (COLD_DIR, sock):
            for src, tgt, cls, perms in needs(daemon, parent, sock, clients):
                grants.setdefault((src, tgt, cls), set()).update(perms)
    return tts, grants


def selftest():
    """check each planted defect against its finding"""
    fails = []
    counts = {"defect": 0, "pass": 0}

    def expect(label, problems, needle):
        """check the problems against the needle"""
        counts["pass" if needle is None else "defect"] += 1
        if needle is None:
            if problems:
                fails.append("%s: flagged a passing policy: %s" % (label, problems))
        elif not any(needle in p for p in problems):
            fails.append("%s: not flagged (want %r, got %s)" % (label, needle, problems))

    def fake(edit_tts=None, edit_grants=None):
        """return a FakePolicy from the passing one with an edit applied"""
        tts, grants = good_fake()
        if edit_tts:
            edit_tts(tts)
        if edit_grants:
            edit_grants(grants)
        return FakePolicy(tts, grants)

    expect("good", check(fake()), None)
    expect("no rtd type_transition", check(fake(lambda t: t.pop(("rhizo_rtd", COLD_DIR)))),
           "rhizo_rtd binding rtd in a tmpfs directory makes a tmpfs socket, not rhizo_rt_socket")
    expect("no rtd type_transition, the client's write", check(fake(lambda t: t.pop(("rhizo_rtd", COLD_DIR)))),
           "rhizo_power lacks write on tmpfs sock_file")
    expect("named for another file", check(fake(lambda t: t.update({("rhizo_rtd", COLD_DIR): [
        'type_transition rhizo_rtd tmpfs:sock_file rhizo_rt_socket "other";']}))), "makes a tmpfs socket")
    expect("named for rtd, quoted", check(fake(lambda t: t.update({("rhizo_rtd", COLD_DIR): [
        'type_transition rhizo_rtd tmpfs:sock_file rhizo_rt_socket "rtd";']}))), None)
    expect("named for rtd, bare", check(fake(lambda t: t.update({("rhizo_rtd", COLD_DIR): [
        "type_transition rhizo_rtd tmpfs:sock_file rhizo_rt_socket rtd;"]}))), None)
    expect("named beats plain", check(fake(lambda t: t.update({("rhizo_rtd", COLD_DIR): [
        "type_transition rhizo_rtd tmpfs:sock_file tmpfs;",
        'type_transition rhizo_rtd tmpfs:sock_file rhizo_rt_socket "rtd";']}))), None)
    expect("conflicting", check(fake(lambda t: t[("rhizo_rtd", COLD_DIR)].append(
        "type_transition rhizo_rtd tmpfs:sock_file rhizo_headroom_socket;"))), "conflicting type_transitions")
    expect("wrong type", check(fake(lambda t: t.update({("rhizo_headroomd", COLD_DIR): [
        "type_transition rhizo_headroomd tmpfs:sock_file rhizo_rt_socket;"]}))),
        "makes a rhizo_rt_socket socket, not rhizo_headroom_socket")
    expect("a relabeled directory hands its own type down", check(fake(lambda t: t.update({
        ("rhizo_delayd", "rhizo_delay_socket"): ["type_transition rhizo_delayd rhizo_delay_socket:sock_file tmpfs;"]}))),
        "rhizo_delayd binding delayd in a rhizo_delay_socket directory makes a tmpfs socket")
    expect("client write", check(fake(edit_grants=lambda g: g[("rhizo_power", "rhizo_rt_socket", "sock_file")].discard(
        "write"))), "rhizo_power lacks write on rhizo_rt_socket sock_file")
    expect("client search", check(fake(edit_grants=lambda g: g[("rhizo_host_delay", COLD_DIR, "dir")].discard(
        "search"))), "rhizo_host_delay lacks search on tmpfs dir")
    expect("connectto", check(fake(edit_grants=lambda g: g.pop(("rhizo_power", "rhizo_headroomd", "unix_stream_socket")))),
           "rhizo_power lacks connectto on rhizo_headroomd unix_stream_socket")
    expect("daemon create", check(fake(edit_grants=lambda g: g[("rhizo_rtd", "rhizo_rt_socket", "sock_file")].discard(
        "create"))), "rhizo_rtd lacks create on rhizo_rt_socket sock_file")
    expect("old socket unlink", check(fake(edit_grants=lambda g: g[("rhizo_rtd", COLD_DIR, "sock_file")].discard(
        "unlink"))), "rhizo_rtd lacks unlink on tmpfs sock_file")
    expect("weakened", check(fake(), weakened={"rhizo_rt_socket"}), "policy.lab drops a deny on rhizo_rt_socket")
    for f in fails:
        print("daemon-socket-labels selftest: " + f, file=sys.stderr)
    if fails:
        print("daemon-socket-labels selftest: FAILED (%d)" % len(fails))
        return 1
    print("daemon-socket-labels selftest: ok -- %d planted defects flagged, %d passing policies not"
          % (counts["defect"], counts["pass"]))
    return 0


def load_access():
    """return the restart-access module loaded from its file"""
    spec = importlib.util.spec_from_file_location("check_restart_access", os.path.join(HERE, "..", "access", "restart-access.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv):
    """run the check against policy.lab, or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: daemon-socket-labels.py [--selftest]", file=sys.stderr)
        return 2
    access = load_access()
    lab_dir = tempfile.mkdtemp(prefix="check-daemon-socket-labels.")
    try:
        policy, weakened = access.build_lab(REPO, lab_dir)
        bad = check(LabPolicy(access, policy), weakened=weakened)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for b in bad:
        print("daemon-socket-labels: " + b, file=sys.stderr)
    if bad:
        print("daemon-socket-labels: FAILED (%d)" % len(bad))
        return 1
    print("daemon-socket-labels: %s each bind their socket with its own type in a tmpfs or a relabeled directory, "
          "and their sandbox clients may reach it" % ", ".join(d for d, _s, _n, _c in SOCKETS))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
