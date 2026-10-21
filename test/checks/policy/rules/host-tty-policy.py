#!/usr/bin/env python3
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

REQUIRED = {
    0x5401: "TCGETS (tcgetattr, isatty)",
    0x5402: "TCSETS (tcsetattr TCSANOW; foot's IUTF8 in its slave child)",
    0x5403: "TCSETSW (tcsetattr TCSADRAIN; readline's raw mode)",
    0x5404: "TCSETSF (tcsetattr TCSAFLUSH; getpass's and PAM misc_conv's no-echo password prompt)",
    0x5409: "TCSBRK (tcdrain)",
    0x540A: "TCXONC (tcflow)",
    0x540B: "TCFLSH (tcflush)",
    0x540E: "TIOCSCTTY (a new session takes its controlling terminal)",
    0x540F: "TIOCGPGRP (tcgetpgrp)",
    0x5410: "TIOCSPGRP (tcsetpgrp; a shell's job control)",
    0x5411: "TIOCOUTQ",
    0x5413: "TIOCGWINSZ",
    0x5414: "TIOCSWINSZ",
    0x5422: "TIOCNOTTY (setsid's detach from a controlling terminal)",
    0x5429: "TIOCGSID (tcgetsid)",
    0x5451: "FIOCLEX",
    0x542A: "TCGETS2 (glibc 2.42's tcgetattr)",
    0x542B: "TCSETS2 (glibc 2.42's tcsetattr TCSANOW)",
    0x542C: "TCSETSW2 (glibc 2.42's tcsetattr TCSADRAIN)",
    0x542D: "TCSETSF2 (glibc 2.42's tcsetattr TCSAFLUSH)",
}
FORBIDDEN = {
    0x5412: "TIOCSTI (injects input; AOSP neverallows it on devpts)",
    0x541C: "TIOCLINUX (console control)",
    0x541D: "TIOCCONS (redirects the console)",
    0x5423: "TIOCSETD (swaps the line discipline)",
}
TTY_DRIVER = (0x5400, 0x54FF)

_ALLOW = re.compile(r"^allow (\S+) (\S+):chr_file (?:\{ ([^{}]*) \}|(\S+));$")
_XPERM = re.compile(r"^allowxperm (\S+) (\S+):chr_file (\S+) (?:\{ ([^{}]*) \}|(\S+));$")
_SPAN = re.compile(r"^(0x[0-9A-Fa-f]+)(?:-(0x[0-9A-Fa-f]+))?$")
_DENY = re.compile(r"^\(deny (\S+) (\S+) \((\S+) \(([^()]*)\)\)\)$")

MINIMAL_CIL = """
(class chr_file (ioctl read write))
(classorder (chr_file))
(sid kernel)
(sidorder (kernel))
(user u)
(role r)
(type rhizo_host)
(type shell)
(type devpts)
(type proc)
(type sysfs)
(typeattribute domain)
(typeattributeset domain (rhizo_host shell))
(typeattribute fs_type)
(typeattributeset fs_type (devpts proc sysfs))
(roletype r domain)
(userrole u r)
(category c0)
(categoryorder (c0))
(sensitivity s0)
(sensitivityorder (s0))
(sensitivitycategory s0 (c0))
(userlevel u (s0))
(userrange u ((s0) (s0 (c0))))
(sidcontext kernel (u r rhizo_host ((s0) (s0))))
"""


def statements(text):
    """return every top-level CIL statement"""
    out, cur, depth = [], [], 0
    for line in text.splitlines():
        for ch in line.split(";", 1)[0]:
            if depth == 0 and ch != "(":
                continue
            cur.append(ch)
            depth += ch == "("
            depth -= ch == ")"
            if depth == 0:
                out.append(re.sub(r"\s+", " ", "".join(cur)).replace("( ", "(").replace(" )", ")"))
                cur = []
        if depth:
            cur.append(" ")
    return out


def is_type(policy, name):
    """return true for a plain type name"""
    r = subprocess.run(["seinfo", "-t", name, policy], capture_output=True, text=True)
    return r.returncode == 0 and re.search(r"^Types: 1$", r.stdout, re.M) is not None


def dropped_denies(fragment, policy=None):
    """return problems for dropped deny rules"""
    out = []
    for s in statements(fragment):
        if not s.startswith("(deny "):
            continue
        m = _DENY.match(s)
        if m is not None and m.group(3) == "chr_file" and m.group(2) != "devpts" \
                and m.group(1) != "rhizo_host" and policy is not None and is_type(policy, m.group(1)):
            continue
        if m is None or m.group(3) == "chr_file" or m.group(2) == "devpts":
            out.append("policy.lab drops %s" % s)
    return out


def sesearch(policy, *args):
    """return the output of sesearch on a policy"""
    r = subprocess.run(["sesearch", *args, policy], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("sesearch %s: rc=%d %s" % (" ".join(args), r.returncode, r.stderr.strip()))
    return r.stdout


def query(policy):
    """return the allow and allowxperm rules"""
    return (sesearch(policy, "--allow", "-s", "rhizo_host", "-t", "devpts", "-c", "chr_file", "-p", "ioctl"),
            sesearch(policy, "--allowxperm", "-s", "rhizo_host", "-t", "devpts", "-c", "chr_file"))


def judge(allow_out, xperm_out):
    """return problems in the devpts ioctl set"""
    bad, base, spans = [], False, []
    for line in (l.strip() for l in allow_out.splitlines()):
        if not line:
            continue
        m = _ALLOW.match(line)
        if m is None or "ioctl" not in (m.group(3) or m.group(4)).split():
            bad.append("an allow rule this check cannot read: %s" % line)
            continue
        base = True
    for line in (l.strip() for l in xperm_out.splitlines()):
        if not line:
            continue
        m = _XPERM.match(line)
        if m is None or m.group(3) != "ioctl":
            bad.append("an allowxperm rule this check cannot read: %s" % line)
            continue
        for tok in (m.group(4) or m.group(5)).split():
            sm = _SPAN.match(tok)
            if sm is None:
                bad.append("an allowxperm rule this check cannot read: %s" % line)
                break
            spans.append((int(sm.group(1), 16), int(sm.group(2) or sm.group(1), 16), line))
    if not base:
        bad.append("no allow grants rhizo_host ioctl on devpts chr_file: the allowx commands never apply")
    lo, hi = TTY_DRIVER
    restricted = any(a <= hi and b >= lo for a, b, _ in spans)

    def via(cmd):
        """return the grants that allow a command"""
        if not base:
            return []
        if not restricted:
            return ["the base ioctl, with no allowxperm restricting driver 0x54"]
        return [line for a, b, line in spans if a <= cmd <= b]

    for cmd, name in sorted(REQUIRED.items()):
        if not via(cmd):
            bad.append("missing 0x%04x %s" % (cmd, name))
    for cmd, name in sorted(FORBIDDEN.items()):
        rules = via(cmd)
        if rules:
            bad.append("grants 0x%04x %s via %s" % (cmd, name, " | ".join(sorted(set(rules)))))
    return bad


def problems(policy, fragment):
    """return the problems from dropped deny rules and the policy query"""
    return dropped_denies(fragment, policy) + judge(*query(policy))


def build_lab(lab_dir):
    """build the avc-lab policy and return its CIL"""
    spec = importlib.util.spec_from_file_location(
        "check_restart_access", os.path.join(HERE, "..", "access", "restart-access.py"))
    access = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(access)
    policy, _ = access.build_lab(REPO, lab_dir)
    with open(os.path.join(lab_dir, "rhizo_vendor_sepolicy.cil")) as f:
        return policy, f.read()


def selftest():
    """check each planted-defect policy against its finding"""
    fails = []
    tmp = tempfile.mkdtemp(prefix="check-host-tty-policy.")

    def compiled(label, rules):
        """compile a policy with extra rules"""
        src = os.path.join(tmp, "p.cil")
        out = os.path.join(tmp, "p.bin")
        with open(src, "w") as f:
            f.write(MINIMAL_CIL + rules)
        r = subprocess.run(["secilc", "-m", "-M", "true", "-G", "-c", "30", src, "-o", out, "-f", "/dev/null"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("%s: the fixture does not compile: %s" % (label, (r.stderr or r.stdout).strip()))
            return None
        return out

    def expect(label, rules, want, fragment=None):
        """record a failure unless the problems contain each wanted text"""
        policy = compiled(label, rules)
        if policy is None:
            return
        got = problems(policy, rules if fragment is None else fragment)
        for w in want:
            if not any(w in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, w, got))
        if not want and got:
            fails.append("%s: wanted no finding, got %r" % (label, got))

    try:
        base = "(allow rhizo_host devpts (chr_file (ioctl)))\n"
        good = base + "(allowx rhizo_host devpts (ioctl chr_file (%s)))\n" % " ".join(
            "0x%04x" % c for c in sorted(REQUIRED))
        console = ["grants 0x541c", "grants 0x541d", "grants 0x5423"]
        read_only = base + "(allowx rhizo_host devpts (ioctl chr_file (0x5401 0x540e 0x540f 0x5413)))\n"
        expect("a grant that reads termios but cannot set it", read_only, ["missing 0x5402", "missing 0x5403", "missing 0x5404", "missing 0x5410"])
        expect("the full set", good, [])
        expect("noble's encoding alone", good.replace(" 0x542a 0x542b 0x542c 0x542d", ""),
               ["missing 0x542a", "missing 0x542b", "missing 0x542c", "missing 0x542d"])
        expect("TIOCSTI added", good.replace("0x5451", "0x5451 0x5412"), ["grants 0x5412"])
        ranged = base + "(allowx rhizo_host devpts (ioctl chr_file ((range 0x5401 0x5414) 0x5422 0x5429 0x5451)))\n"
        expect("a range over TIOCSTI", ranged, ["grants 0x5412"])
        expect("no base ioctl", good.replace(base, "(allow rhizo_host devpts (chr_file (read write)))\n"),
               ["no allow grants rhizo_host ioctl", "missing 0x5401"])
        expect("the base ioctl with no allowx", base, ["grants 0x5412", "the base ioctl, with no allowxperm"] + console)
        expect("a commented-out allowx", good.replace("\n(allowx", "\n; (allowx"), ["grants 0x5412"])
        expect("another domain's grant", good.replace("rhizo_host", "shell"), ["missing 0x5402"])
        expect("TIOCSTI through an attribute rhizo_host is in",
               good + "(allowx domain devpts (ioctl chr_file (0x5412)))\n", ["grants 0x5412"])
        expect("every ioctl on an attribute holding devpts",
               good + "(typeattribute rhizo_fs_ok)\n"
               "(typeattributeset rhizo_fs_ok (and (fs_type) (not (proc sysfs))))\n"
               "(allowx rhizo_host rhizo_fs_ok (ioctl chr_file ((range 0x1 0xffff))))\n", console)
        expect("a (not ...) command set", good + "(allowx rhizo_host devpts (ioctl chr_file (not (0x5402))))\n",
               console)
        expect("a macro called with rhizo_host",
               good + "(macro host_console_tty ((type t)) (allowx t devpts (ioctl chr_file (0x541c 0x541d 0x5423))))\n"
               "(call host_console_tty (rhizo_host))\n", console)
        expect("the full set on another attribute's devpts rule", good + "(allowx rhizo_host fs_type (ioctl chr_file "
               "(0x5401)))\n", [])
        expect("a deny policy.lab drops", good, ["policy.lab drops (deny rhizo_host devpts"],
               fragment=good + "(deny rhizo_host devpts (chr_file (ioctl)))\n")
        expect("another plain type's chr_file deny", good, [],
               fragment=good + "(deny shell devpts_other (chr_file (ioctl)))\n")
        expect("a chr_file deny on an attribute", good, ["policy.lab drops (deny domain proc"],
               fragment=good + "(deny domain proc (chr_file (ioctl)))\n")
        expect("rhizo_host's own chr_file deny elsewhere", good, ["policy.lab drops (deny rhizo_host proc"],
               fragment=good + "(deny rhizo_host proc (chr_file (ioctl)))\n")
        expect("a deny on another class", good, [],
               fragment=good + "(deny rhizo_host binfmt_miscfs (filesystem (mount remount)))\n")
        for label, allow, xperm, want in (
                ("a conditional base ioctl", "allow rhizo_host devpts:chr_file ioctl; [ b ]:True\n", "",
                 "an allow rule this check cannot read"),
                ("an nlmsg xperm", "allow rhizo_host devpts:chr_file ioctl;\n",
                 "allowxperm rhizo_host devpts:chr_file nlmsg 0x10;\n", "an allowxperm rule this check cannot read"),
                ("an unparsed span", "allow rhizo_host devpts:chr_file ioctl;\n",
                 "allowxperm rhizo_host devpts:chr_file ioctl { 0x5401-x };\n",
                 "an allowxperm rule this check cannot read")):
            got = judge(allow, xperm)
            if not any(want in g for g in got):
                fails.append("%s: wanted a finding naming %r, got %r" % (label, want, got))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for f in fails:
        print("SELFTEST FAIL: " + f)
    if fails:
        return 1
    print("check-host-tty-policy selftest: ok (compiled fixtures: a grant that reads termios but cannot set it, noble's encoding without glibc 2.42's termios2, TIOCSTI directly, in a "
          "range and through an attribute, the console commands on an attribute holding devpts, in a (not ...) "
          "set and through a macro, a base ioctl no allowx restricts, no base ioctl, comments, another "
          "domain, a dropped deny and unreadable sesearch lines are caught; the full set passes)")
    return 0


def main():
    """run the check or its selftest"""
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    if args:
        print("usage: host-tty-policy.py [--selftest]", file=sys.stderr)
        return 2
    lab_dir = tempfile.mkdtemp(prefix="check-host-tty-lab.")
    try:
        policy, fragment = build_lab(lab_dir)
        found = problems(policy, fragment)
    finally:
        shutil.rmtree(lab_dir, ignore_errors=True)
    for p in found:
        print("FAIL: rhizo_host devpts ioctl: " + p)
    if found:
        return 1
    print("ok: the compiled policy gives rhizo_host the %d terminal ioctls on its own ptys and none of %s"
          % (len(REQUIRED), ", ".join(n.split()[0] for n in FORBIDDEN.values())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
