#!/usr/bin/env python3
import bz2
import os
import re
import subprocess
import sys
import tempfile

import setools
import setools.exception

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
DEB = os.path.join(REPO, "var", "host-policy", "selinux-policy-default_2.20240202-1_all.deb")
PP = "/usr/libexec/selinux/hll/pp"
RULE = "src/services/udev/70-uinput.rules"
UNIT = "src/services/inputd/inputd@.service"
SOURCE = "src/services/inputd/inputd.c"
RULES = "debian/rules"
UDEV = "udev_t"
SYSTEMD = "init_t"


def read(rel):
    """return a tree file's text"""
    with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
        return fh.read()


def build_policy(work):
    """build the package's policy and file_contexts"""
    root = os.path.join(work, "pkg")
    subprocess.run(["dpkg-deb", "-x", DEB, root], check=True, timeout=120)
    share = os.path.join(root, "usr", "share", "selinux", "default")
    cils = []
    for name in open(os.path.join(share, ".modules")).read().split():
        cil = os.path.join(work, name + ".cil")
        with open(os.path.join(share, name + ".pp.bz2"), "rb") as fh:
            subprocess.run([PP], input=bz2.decompress(fh.read()), stdout=open(cil, "wb"), check=True, timeout=60)
        cils.append(cil)
    policy, fc = os.path.join(work, "policy.33"), os.path.join(work, "file_contexts")
    subprocess.run(["secilc", "-m", "-M", "true", "-o", policy, "-f", fc] + cils, check=True, timeout=300,
                   capture_output=True)
    return policy, fc


def file_type(fc, path):
    """return a path's file_contexts type or None"""
    out = subprocess.run(["matchpathcon", "-f", fc, path], capture_output=True, text=True, timeout=30).stdout.split()
    return out[1].split(":")[2] if len(out) > 1 and out[1].count(":") >= 3 else None


class Policy:
    """query rights in a compiled policy"""

    def __init__(self, path):
        """load the policy and its booleans' defaults"""
        self.p = setools.SELinuxPolicy(path)
        self.bools = {b.name: b.state for b in self.p.bools()}

    def live(self, rule):
        """return whether a rule applies under default booleans"""
        try:
            cond = rule.conditional
        except setools.exception.RuleNotConditional:
            return True
        return cond.evaluate(**self.bools) == rule.conditional_block

    def allowed(self, src, tgt, cls, perm):
        """return whether src has perm on tgt's class"""
        q = setools.TERuleQuery(self.p, ruletype=["allow"], source=src, target=tgt, tclass=[cls], perms=[perm])
        return any(self.live(r) for r in q.results())

    def transition(self, src, tgt, cls, name=None):
        """return a type_transition's default type or None"""
        q = setools.TERuleQuery(self.p, ruletype=["type_transition"], source=src, target=tgt, tclass=[cls],
                                     source_indirect=False, target_indirect=False)
        for r in q.results():
            if not self.live(r):
                continue
            try:
                fname = r.filename
            except setools.exception.TERuleNoFilename:
                fname = None
            if fname in (None, name):
                return str(r.default)
        return None


def rule_program(rule_text):
    """return the program the rule's PROGRAM runs"""
    m = re.search(r'^PROGRAM=="([^" ]+)[^"]*"', rule_text, re.M)
    return m.group(1) if m else None


def owned_socket(unit_text):
    """return the supervisor and instance 0's owned socket"""
    m = re.search(r"^ExecStart=(\S+) supervise .*--owned-socket (\S+)", unit_text, re.M)
    return (m.group(1), m.group(2).replace("%i", "0")) if m else (None, None)


def findings(pol, fc, rule_text, unit_text, source_text, rules_text):
    """return each access the policy refuses udev_t"""
    bad = []
    program = rule_program(rule_text)
    if not program:
        return ["%s names no PROGRAM" % RULE]
    payload = re.search(r"^PAYLOAD\s*:?=\s*(\S+)", rules_text, re.M)
    installed = rules_text.replace("$(PAYLOAD)", payload.group(1)) if payload else rules_text
    if not re.search(r"^\tinstall\b.*\sdebian/rhizo%s$" % re.escape(program), installed, re.M):
        bad.append("%s installs nothing at %s, the program %s runs" % (RULES, program, RULE))
    ptype = file_type(fc, program)
    if not ptype:
        bad.append("file_contexts gives %s no type" % program)
    else:
        dom = pol.transition(UDEV, ptype, "process")
        if dom:
            if not (pol.allowed(UDEV, dom, "process", "transition") and pol.allowed(dom, ptype, "file", "entrypoint")):
                bad.append("udev_t execs %s (%s) into %s, which the policy does not allow" % (program, ptype, dom))
        elif not pol.allowed(UDEV, ptype, "file", "execute_no_trans"):
            bad.append("udev_t may not run %s: file_contexts makes it %s, and udev_t has no execute_no_trans on it"
                       % (program, ptype))
    supervisor, sock = owned_socket(unit_text)
    if not sock:
        bad.append("%s gives the supervisor no --owned-socket"
                   % UNIT)
        m = re.search(r"^ExecStart=(\S+) supervise .*--socket (\S+)", unit_text, re.M)
        if not m:
            return bad + ["%s gives the supervisor no --socket" % UNIT]
        supervisor, sock = m.group(1), m.group(2).replace("%i", "0")
    default = re.search(r'const char \*sockets = "([^"]+)"', source_text)
    if default and sock and not re.fullmatch(default.group(1).replace(".", r"\.").replace("*", "[^/]*"), sock):
        bad.append("rhizo-inputd owned asks %s by default, not the unit's owned socket %s" % (default.group(1), sock))
    fmt = re.search(r'#define OWNED_SOCKET_FMT "([^"]+)"', source_text)
    if not fmt:
        bad.append("rhizo-inputd has no default owned socket")
    elif fmt.group(1).replace("%u", "0") != sock:
        bad.append("rhizo-inputd's default owned socket %s is not the unit's %s" % (fmt.group(1), sock))
    no_udev = re.search(r"^#define NO_UDEV_EXIT (\d+)", source_text, re.M)
    prevent = " ".join(re.findall(r"^RestartPreventExitStatus=(.*)$", unit_text, re.M)).split()
    if not no_udev:
        bad.append("rhizo-inputd names no exit status for a host without /run/udev")
    elif no_udev.group(1) not in prevent:
        bad.append("%s's RestartPreventExitStatus=%s lacks NO_UDEV_EXIT %s" % (UNIT, " ".join(prevent), no_udev.group(1)))
    after = " ".join(re.findall(r"^After=(.*)$", unit_text, re.M)).split()
    if "systemd-udevd.service" not in after:
        bad.append("%s is not ordered After=systemd-udevd.service" % UNIT)
    sdir = os.path.dirname(sock)
    dtype = file_type(fc, sdir)
    if not dtype:
        bad.append("file_contexts gives %s no type" % sdir)
        return bad
    for perm in ("search", "read"):
        if not pol.allowed(UDEV, dtype, "dir", perm):
            bad.append("udev_t may not %s %s (%s)" % (perm, sdir, dtype))
    for perm in ("create", "connect", "write", "read"):
        if not pol.allowed(UDEV, UDEV, "unix_stream_socket", perm):
            bad.append("udev_t may not %s its own seqpacket socket" % perm)
    stype = file_type(fc, supervisor)
    sdom = pol.transition(SYSTEMD, stype, "process") if stype else None
    if not sdom:
        if not (stype and pol.allowed(SYSTEMD, stype, "file", "execute_no_trans")):
            return bad + ["systemd (init_t) may not run %s (%s)" % (supervisor, stype)]
        sdom = SYSTEMD
    socktype = pol.transition(sdom, dtype, "sock_file", os.path.basename(sock)) or dtype
    if not (pol.allowed(sdom, dtype, "dir", "add_name") and pol.allowed(sdom, socktype, "sock_file", "create")):
        bad.append("the supervisor (%s) may not create %s (%s) in %s" % (sdom, sock, socktype, dtype))
    if not pol.allowed(UDEV, socktype, "sock_file", "write"):
        bad.append("udev_t may not write %s (%s)" % (sock, socktype))
    if not pol.allowed(UDEV, sdom, "unix_stream_socket", "connectto"):
        bad.append("udev_t may not connect to the supervisor's domain %s" % sdom)
    return bad


def selftest(pol, fc):
    """check the tree passes and planted defects fail"""
    texts = [read(RULE), read(UNIT), read(SOURCE), read(RULES)]
    bad = []
    got = findings(pol, fc, *texts)
    if got:
        bad.append("the tree's own files have findings: %r" % got)
    old_rule = re.sub(r'PROGRAM=="\S+', 'PROGRAM=="/usr/lib/rhizo/rhizo-inputd', texts[0])
    old_rules = texts[3].replace("debian/rhizo/usr/lib/udev/rhizo-input-owned", "debian/rhizo/usr/lib/rhizo/rhizo-inputd")
    old_unit = re.sub(r" --owned-socket \S+", "", texts[1])
    for name, args, want in (
            ("the program under /usr/lib/rhizo", [old_rule, texts[1], texts[2], old_rules], "no execute_no_trans"),
            ("no owned socket", [texts[0], old_unit, texts[2], texts[3]], "no --owned-socket"),
            ("the socket under /run/rhizo-input-0", [texts[0], texts[1].replace("/run/udev/rhizo-input-%i.sock",
                                                                                "/run/rhizo-input-%i/udev.sock"),
                                                     texts[2], texts[3]], "no type"),
            ("the helper asking another path", [texts[0], texts[1], texts[2].replace('"/run/udev/rhizo-input-*.sock"',
                                                                                      '"/run/rhizo-input-*/udev.sock"'),
                                                texts[3]], "asks /run/rhizo-input-*/udev.sock"),
            ("no install of the program", [texts[0], texts[1], texts[2],
                                           texts[3].replace("debian/rhizo/usr/lib/udev/rhizo-input-owned", "x")],
             "installs nothing"),
            ("no default owned socket", [texts[0], texts[1], re.sub(r"#define OWNED_SOCKET_FMT .*", "", texts[2]),
                                         texts[3]], "has no default owned socket"),
            ("another default owned socket", [texts[0], texts[1], texts[2].replace(
                '#define OWNED_SOCKET_FMT "/run/udev/rhizo-input-%u.sock"',
                '#define OWNED_SOCKET_FMT "/run/udev/rhizo-%u.sock"'), texts[3]], "is not the unit's"),
            ("no udevd ordering", [texts[0], texts[1].replace(" systemd-udevd.service", ""), texts[2], texts[3]],
             "is not ordered After=systemd-udevd.service"),
            ("no no-udev exit", [texts[0], texts[1], re.sub(r"#define NO_UDEV_EXIT .*", "", texts[2]), texts[3]],
             "names no exit status for a host without /run/udev"),
            ("no-udev exit restarted", [texts[0], re.sub(r"^RestartPreventExitStatus=.*$", "RestartPreventExitStatus=1",
                                                         texts[1], flags=re.M), texts[2], texts[3]],
             "lacks NO_UDEV_EXIT")):
        got = findings(pol, fc, *args)
        if not any(want in g for g in got):
            bad.append("%s was not named: %r" % (name, got))
    return bad


def main():
    """run the check or its selftest"""
    for need in (DEB, PP):
        if not os.path.exists(need):
            print("FAIL %s is missing (tools/fetch/host-policy.sh fetches the policy)" % need)
            return 1
    with tempfile.TemporaryDirectory() as work:
        policy, fc = build_policy(work)
        pol = Policy(policy)
        if "--selftest" in sys.argv[1:]:
            bad = selftest(pol, fc)
        else:
            bad = findings(pol, fc, read(RULE), read(UNIT), read(SOURCE), read(RULES))
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
