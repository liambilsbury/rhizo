#!/usr/bin/env python3
import argparse
import contextlib
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import types

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, "..", "..", "..", ".."))

HELPER = "src/install/bootstrap/console-vt.py"
SNIPPET = "debian/profile.d/console-vt.sh"
RULES = "debian/rules"
SNAPSHOT_ALLOW = "test/checks/data/host-snapshot-allow.tsv"
REDEPLOY = "test/vm/redeploy.sh"
UNIT = "src/services/units/session/session-vt@.service"
DROPIN = "debian/dropins/session-scope-vt.conf"
FILES = (HELPER, SNIPPET, RULES, SNAPSHOT_ALLOW, REDEPLOY, UNIT, DROPIN)

HELPER_DEST = "/usr/lib/rhizo/install/bootstrap/console-vt.py"
HELPER_RULES_DIR = "$(PAYLOAD)/install/bootstrap/"
SNIPPET_DEST = "/etc/profile.d/rhizo-console-vt.sh"
SNIPPET_INSTALL = "install -D -m 0644 %s $(PAYLOAD)/host-mode%s" % (SNIPPET, SNIPPET_DEST)
RIG_SNIPPET_INSTALL = "install -D -m 0644 /root/share/rhizo-console-vt.sh %s" % SNIPPET_DEST
UNIT_INSTALL = 'install -D -m 0644 "%s" "$(UNITS)/rhizo-session-vt@.service"' % UNIT
DROPIN_INSTALL = ('install -D -m 0644 %s "$(PAYLOAD)/host-mode/usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf"'
                  % DROPIN)
SESSION_EXEC = "%s --session %%i" % HELPER_DEST
SCOPE_DEP = "rhizo-session-vt@%j.service"
WANT_DROPIN = [("Unit", "Wants", SCOPE_DEP), ("Unit", "After", SCOPE_DEP)]
DROPIN_WANTS = ((DROPIN, WANT_DROPIN, "dropin"),)
NODAC = ("sudo", "-n", "setpriv", "--bounding-set", "-dac_override,-dac_read_search")
GDM_UID = 110
TTY_GID = 5
GRANT_AS_ROOT = ("import sys, types\n"
                 "m = types.ModuleType('rhizo_console_vt')\n"
                 "m.__file__ = sys.argv[1]\n"
                 "exec(compile(sys.stdin.read(), sys.argv[1], 'exec'), m.__dict__)\n"
                 "print(m.grant_root_named(sys.argv[2]))\n")
OPEN_RW = ("import os, sys\n"
           "try:\n"
           "    os.close(os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK))\n"
           "    print('OPENED')\n"
           "except OSError as e:\n"
           "    print('REFUSED', e.strerror)\n")


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel)) as f:
        return f.read()


def load_helper(root):
    """load the console-vt.py module"""
    path = os.path.join(root, HELPER)
    mod = types.ModuleType("rhizo_console_vt")
    mod.__file__ = path
    exec(compile(read(root, HELPER), path, "exec"), mod.__dict__)
    return mod


def fake_stat(mode, rdev):
    """return a stat result with a mode and device number"""
    return os.stat_result((mode, 0, 0, 1, 1000, 5, 0, 0, 0, 0), {"st_rdev": rdev})


def check_functions(h):
    """check the ACL and VT functions"""
    found = []
    login = h.mode_acl(0o600)
    got = h.with_root_rw(login)
    if h.root_perm(got, 1000) & h.RW != h.RW:
        found.append("acl.root-not-rw: a 0600 VT's ACL gives uid 0 %o, not rw" % h.root_perm(got, 1000))
    if [p for t, p, _ in got if t == h.ACL_GROUP_OBJ] != [0]:
        found.append("acl.group-changed: the tty group's own entry moved off --- (%s)" % got)
    if [p for t, p, _ in got if t == h.ACL_OTHER] != [0]:
        found.append("acl.other-changed: other moved off --- (%s)" % got)
    named = [(h.ACL_USER_OBJ, 6, h.ACL_UNDEFINED_ID), (h.ACL_USER, 4, 1234), (h.ACL_USER, 4, 0),
             (h.ACL_GROUP_OBJ, 0, h.ACL_UNDEFINED_ID), (h.ACL_GROUP, 2, 5),
             (h.ACL_MASK, 0, h.ACL_UNDEFINED_ID), (h.ACL_OTHER, 0, h.ACL_UNDEFINED_ID)]
    got = h.parse_acl(h.pack_acl(h.with_root_rw(named)))
    if (h.ACL_USER, 4, 1234) not in got or (h.ACL_GROUP, 2, 5) not in got:
        found.append("acl.drops-entries: another named entry was lost: %s" % got)
    if [p for t, p, i in got if t == h.ACL_USER and i == 0] != [6]:
        found.append("acl.root-entry: uid 0's existing r-- entry did not become rw: %s" % got)
    if [p for t, p, _ in got if t == h.ACL_MASK] != [6]:
        found.append("acl.mask: the mask is not the group class union rw: %s" % got)
    if [t for t, _, _ in got] != sorted(t for t, _, _ in got):
        found.append("acl.order: entries are not in the kernel's tag order: %s" % got)
    chr_mode = stat.S_IFCHR | 0o620
    for name, st, want in (("tty1", fake_stat(chr_mode, os.makedev(4, 1)), True),
                           ("tty63", fake_stat(chr_mode, os.makedev(4, 63)), True),
                           ("tty0", fake_stat(chr_mode, os.makedev(4, 0)), False),
                           ("ttyS0", fake_stat(chr_mode, os.makedev(4, 64)), False),
                           ("null", fake_stat(chr_mode, os.makedev(1, 3)), False),
                           ("regular", fake_stat(stat.S_IFREG | 0o600, os.makedev(4, 1)), False)):
        if h.is_vt(st) != want:
            found.append("vt.%s: is_vt says %s for %s" % ("refuses-vt" if want else "accepts-" + name,
                                                          not want, name))
    return found + check_session_functions(h)


SESSION_FUNCTIONS = ("root_keeps_rw", "grant_root_named", "vt_path", "grant_session")


def missing_session_functions(h):
    """return the missing session-mode functions"""
    return [name for name in SESSION_FUNCTIONS if not callable(getattr(h, name, None))]


def check_session_functions(h):
    """check the session functions"""
    missing = missing_session_functions(h)
    if missing:
        return ["session.missing: %s has no %s"
                % (HELPER, ", ".join(missing))]
    found = []
    greeter = h.mode_acl(0o620)
    if h.root_keeps_rw(greeter):
        found.append("keep.minimal: a root:tty 0620 VT with no entry reads as open to root once "
                     "gdm owns it: %s" % greeter)
    if not h.root_keeps_rw(h.with_root_rw(greeter)):
        found.append("keep.granted: the granted 0620 VT does not read as open to root once gdm owns "
                     "it: %s" % h.with_root_rw(greeter))
    restored = [(t, 2 if t == h.ACL_MASK else p, i) for t, p, i in h.with_root_rw(greeter)]
    if h.root_keeps_rw(restored):
        found.append("keep.masked: an entry whose mask logind's 0620 restore cut to -w- reads as "
                     "open to root: %s" % restored)
    for text, want in (("1", "/dev/tty1"), ("63\n", "/dev/tty63"), ("0", None), ("", None),
                       ("64", None), ("-1", None), ("1 2", None), ("²", None)):
        got = h.vt_path(text)
        if got != want:
            found.append("vt.path: VTNr %r gives %r, not %r" % (text, got, want))
    asked = []
    for sid in ("", "c1;id", "../c1", "c-1", "4\n"):
        try:
            h.grant_session(sid, vtnr_of=lambda s: asked.append(s) or "0")
            found.append("session.id: %r was taken for a logind session id" % sid)
        except ValueError:
            pass
    if asked:
        found.append("session.id: logind was asked about %s before the id was checked" % asked)
    for sid, vtnr in (("c1", "0"), ("4", "")):
        try:
            got = h.grant_session(sid, vtnr_of=lambda s, v=vtnr: v)
        except (OSError, ValueError) as e:
            got = "%s: %s" % (type(e).__name__, e)
        if got != (None, "no-vt"):
            found.append("session.no-vt: session %s with VTNr %r gives %s, not (None, 'no-vt')"
                         % (sid, vtnr, got))
    for argv, want in ((["console-vt.py", "--session"], 2),
                       (["console-vt.py", "--session", "c1;id"], 1)):
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            got = h.main(argv)
        if got != want:
            found.append("session.cli: %s exits %s, not %d" % (" ".join(argv[1:]), got, want))
    return found


def probe_root(path):
    """probe a root read-write open of a path"""
    r = subprocess.run(NODAC + (sys.executable, "-c", OPEN_RW, path), capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("OPENED", "REFUSED"))]
    return lines[0] if lines else "NO-ANSWER rc=%d %s" % (r.returncode, r.stderr.strip()[-200:])


def lab_dir():
    """return a new world-readable lab directory"""
    base = "/dev/shm" if os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK) else None
    d = tempfile.mkdtemp(prefix="console-vt.", dir=base)
    os.chmod(d, 0o755)
    return d


def check_kernel(h):
    """check ACL writes on a lab file"""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return ["lab-not-measured: sudo -n cannot get root here, so no root-without-DAC probe ran"]
    if shutil.which("setpriv") is None:
        return ["lab-not-measured: setpriv is not on PATH"]
    found = []
    d = lab_dir()
    try:
        login = os.path.join(d, "login-tty")
        with open(login, "w"):
            pass
        os.chmod(login, 0o600)
        got = probe_root(login)
        if not got.startswith("REFUSED"):
            found.append("kernel.control-open: root without DAC override opened a 0600 node it "
                         "does not own before any grant (%s)" % got)
        seeded = os.path.join(d, "seeded-tty")
        with open(seeded, "w"):
            pass
        os.chmod(seeded, 0o600)
        h.grant_root(seeded, os.getuid())
        os.chmod(seeded, 0o600)
        got = probe_root(seeded)
        if not got.startswith("REFUSED"):
            found.append("kernel.chmod-kept-entry: an entry set before login's chmod still opened "
                         "(%s)" % got)
        try:
            first = h.grant_root(login, os.getuid())
            again = h.grant_root(login, os.getuid())
        except OSError as e:
            return found + ["kernel.acl-write: the helper could not write the ACL: %s" % e]
        if first != "granted" or again != "already":
            found.append("kernel.grant-result: first call said %r, second %r, not 'granted' then "
                         "'already'" % (first, again))
        got = probe_root(login)
        if got != "OPENED":
            found.append("kernel.root-refused: root without DAC override still cannot open the "
                         "owner-granted node read-write: %s" % got)
        if os.lstat(login).st_mode & 0o7777 != 0o660:
            found.append("kernel.mode: the node reads mode %o after the grant, not 660 (owner rw, "
                         "mask rw)" % (os.lstat(login).st_mode & 0o7777))
        found += check_greeter_kernel(h, d)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return found


def as_root(*cmd):
    """run a command with sudo"""
    r = subprocess.run(("sudo", "-n") + cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise OSError("sudo %s exited %d: %s" % (" ".join(cmd), r.returncode, r.stderr.strip()))
    return r.stdout


def grant_as_nodac_root(h, path):
    """run grant_root_named in a subprocess"""
    with open(h.__file__) as f:
        source = f.read()
    r = subprocess.run(NODAC + (sys.executable, "-c", GRANT_AS_ROOT, h.__file__, path),
                       input=source, capture_output=True, text=True)
    if r.returncode != 0:
        return "FAILED rc=%d %s" % (r.returncode, r.stderr.strip()[-200:])
    return r.stdout.strip()


def restore_vt(path):
    """reset a VT node to mode 0620 root"""
    as_root("chmod", "0620", path)
    as_root("chown", "0", path)


def check_greeter_kernel(h, d):
    """check the gdm greeter VT grants"""
    found = []
    vt = os.path.join(d, "greeter-tty")
    try:
        as_root("install", "-m", "0620", "-o", "0", "-g", str(TTY_GID), "/dev/null", vt)
        as_root("chown", str(GDM_UID), vt)
        got = probe_root(vt)
        if not got.startswith("REFUSED"):
            found.append("kernel.greeter-control-open: root without DAC override opened a 0620 node "
                         "gdm owns with no grant (%s)" % got)
        restore_vt(vt)
        if missing_session_functions(h):
            return found + ["kernel.greeter-root-refused: %s has no grant_root_named, and root was "
                            "refused gdm's VT above" % HELPER]
        first = grant_as_nodac_root(h, vt)
        as_root("chown", str(GDM_UID), vt)
        got = probe_root(vt)
        if first != "granted" or got != "OPENED":
            found.append("kernel.greeter-root-refused: root granted itself the entry while it owned "
                         "the VT (%s), and once gdm owned it root's open read %s" % (first, got))
        again = grant_as_nodac_root(h, vt)
        if again != "already":
            found.append("kernel.greeter-regrant: a second grant on gdm's VT said %r, not 'already'"
                         % again)
        entries = h.read_acl(vt, os.lstat(vt))
        group = [p for t, p, _ in entries if t == h.ACL_GROUP_OBJ]
        if group != [2]:
            found.append("kernel.group-widened: the tty group's own entry reads %s after the grant, "
                         "not -w-" % group)
        restore_vt(vt)
        as_root("chown", str(GDM_UID), vt)
        got = probe_root(vt)
        if not got.startswith("REFUSED"):
            found.append("kernel.restore-kept-entry: after logind's 0620 restore and the next "
                         "greeter's chown, root still opened the VT with no new grant (%s)" % got)
    except OSError as e:
        found.append("kernel.greeter-lab: %s" % e)
    return found


def run_snippet(snippet_text, work, vtnr, helper_rc=0):
    """run the snippet in sh"""
    rec = os.path.join(work, "calls")
    fake = os.path.join(work, "helper")
    with open(fake, "w") as f:
        f.write("#!/bin/sh\necho \"$*\" >> %s\nexit %d\n" % (rec, helper_rc))
    os.chmod(fake, 0o755)
    if os.path.exists(rec):
        os.remove(rec)
    text = snippet_text.replace(HELPER_DEST, fake)
    path = os.path.join(work, "snippet.sh")
    with open(path, "w") as f:
        f.write(text)
    env = {k: v for k, v in os.environ.items() if k != "XDG_VTNR"}
    if vtnr is not None:
        env["XDG_VTNR"] = vtnr
    r = subprocess.run(["sh", "-c", '. "$1"; echo ALIVE', "sh", path], env=env,
                       capture_output=True, text=True)
    calls = open(rec).read().split("\n")[:-1] if os.path.exists(rec) else []
    return calls, "ALIVE" in r.stdout


def check_snippet(root):
    """check the profile snippet"""
    text = read(root, SNIPPET)
    found = []
    if HELPER_DEST not in text:
        return ["snippet.no-helper-call: %s never runs %s" % (SNIPPET, HELPER_DEST)]
    with tempfile.TemporaryDirectory() as work:
        calls, alive = run_snippet(text, work, "1")
        if calls != ["/dev/tty1"]:
            found.append("snippet.no-grant: XDG_VTNR=1 ran the helper as %s, not once on /dev/tty1" % calls)
        if not alive:
            found.append("snippet.ends-login-shell: the login shell stopped after sourcing it")
        calls, alive = run_snippet(text, work, "1", helper_rc=1)
        if not alive:
            found.append("snippet.ends-login-shell: a failing helper ended the login shell")
        for vt in (None, "", "abc", "1;id", "1 2"):
            calls, alive = run_snippet(text, work, vt)
            if calls:
                found.append("snippet.runs-without-vt: XDG_VTNR=%r ran the helper as %s" % (vt, calls))
            if not alive:
                found.append("snippet.ends-login-shell: XDG_VTNR=%r ended the login shell" % vt)
    return found


def rules_commands(text):
    """return the recipe lines of debian/rules"""
    return [c.strip() for c in re.sub(r"\\\n\s*", " ", text).splitlines() if c.startswith("\t")]


def check_static(root):
    """return the failed static checks"""
    found = []
    cmds = rules_commands(read(root, RULES))
    if not any(c == SNIPPET_INSTALL for c in cmds):
        found.append("rules.snippet-not-installed: no `%s` recipe line" % SNIPPET_INSTALL)
    if not any(c.startswith("install -m 0755 ") and HELPER in c.split()
               and c.split()[-1] == HELPER_RULES_DIR for c in cmds):
        found.append("rules.helper-not-installed: no `install -m 0755 ... %s ... %s`"
                     " line, so %s does not exist" % (HELPER, HELPER_RULES_DIR, HELPER_DEST))
    if RIG_SNIPPET_INSTALL not in read(root, REDEPLOY).splitlines():
        found.append("rig.snippet-not-staged: %s has no `%s` line" % (REDEPLOY, RIG_SNIPPET_INSTALL))
    rows = [ln.split("\t") for ln in read(root, SNAPSHOT_ALLOW).splitlines()
            if ln and not ln.startswith("#")]
    if any(r[0] in ("remove", "remove?") and r[1] == "etc\\t" + SNIPPET_DEST for r in rows if len(r) > 2):
        found.append("snapshot.remove-row: %s allows %s after a remove" % (SNAPSHOT_ALLOW, SNIPPET_DEST))
    return found + check_session_static(root, cmds)


def unit_directives(text):
    """return the unit file directives"""
    out, section = [], None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        if sep:
            out.append((section, key.strip(), value.strip()))
    return out


def unit_keys(text):
    """map each unit file key to its values"""
    keys = {}
    for section, key, value in unit_directives(text):
        keys.setdefault((section, key), []).append(value)
    return keys


def check_session_static(root, cmds):
    """return the failed scope drop-in and unit checks"""
    found = []
    if not any(" ".join(c.split()) == DROPIN_INSTALL for c in cmds):
        found.append("rules.dropin-not-installed: no `%s` recipe line" % DROPIN_INSTALL)
    if not any(" ".join(c.split()) == UNIT_INSTALL for c in cmds):
        found.append("rules.unit-not-installed: no `%s` recipe line" % UNIT_INSTALL)
    absent = [rel for rel in (DROPIN, UNIT) if not os.path.isfile(os.path.join(root, rel))]
    if absent:
        return found + ["session.files-missing: %s not in the tree" % ", ".join(absent)]
    directives = unit_directives(read(root, DROPIN))
    dropin = unit_keys(read(root, DROPIN))
    for key in ("Wants", "After"):
        if dropin.get(("Unit", key)) != [SCOPE_DEP]:
            found.append("dropin.%s: %s's [Unit] %s= reads %s, not [%s], so a session's scope %s"
                         % (key.lower(), DROPIN, key, dropin.get(("Unit", key)), SCOPE_DEP,
                            "never pulls the unit in" if key == "Wants" else "starts before the grant"))
    extra = [d for d in directives if d not in WANT_DROPIN]
    if extra:
        found.append("dropin.extra: %s sets more than the two ordering lines on every session scope: %s"
                     % (DROPIN, extra))
    unit = unit_keys(read(root, UNIT))
    want = {("Service", "Type"): ["oneshot"], ("Service", "ExecStart"): [SESSION_EXEC],
            ("Unit", "DefaultDependencies"): ["no"], ("Unit", "CollectMode"): ["inactive-or-failed"]}
    for key, value in want.items():
        if unit.get(key) != value:
            found.append("unit.%s: %s's [%s] %s= reads %s, not %s"
                         % (key[1].lower(), UNIT, key[0], key[1], unit.get(key), value))
    for key in ("User", "Group", "DynamicUser"):
        if ("Service", key) in unit:
            found.append("unit.not-root: %s sets %s=" % (UNIT, key))
    if any(section == "Install" for section, _ in unit):
        found.append("unit.install: %s has an [Install] section; only the scope drop-in may pull it in"
                     % UNIT)
    return found


def check(root, verbose=True):
    """return the failures from every console VT check"""
    h = load_helper(root)
    found = check_functions(h) + check_kernel(h) + check_snippet(root) + check_static(root)
    if verbose:
        for f in found:
            print("FAIL %s" % f)
        if not found:
            print("ok: uid 0 gets rw on an owner-granted VT and no other entry moves; root without "
                  "DAC override opens it only after the owner's grant; the snippet runs it only for "
                  "a numeric XDG_VTNR and never ends the shell; root's own grant on a root:tty VT "
                  "keeps it open to root once gdm owns it, and logind's restore voids it; every "
                  "session scope runs the grant first; rules and snapshot carry it")
    return found


def selftest():
    """check each planted-defect copy against its finding"""
    cases = [
        ("the helper keeps the old mask", HELPER, "            mask |= p\n", "            mask |= 0\n",
         "kernel.root-refused"),
        ("the helper takes a serial port for a VT", HELPER, "MAX_VT = 63", "MAX_VT = 255",
         "vt.accepts-ttyS0"),
        ("the helper takes tty0", HELPER, "1 <= os.minor(st.st_rdev)", "0 <= os.minor(st.st_rdev)",
         "vt.accepts-tty0"),
        ("the helper drops other named entries", HELPER,
         "kept = [e for e in entries if e[0] != ACL_MASK and not (e[0] == ACL_USER and e[2] == 0)]",
         "kept = [e for e in entries if e[0] in (ACL_USER_OBJ, ACL_GROUP_OBJ, ACL_OTHER)]",
         "acl.drops-entries"),
        ("the snippet no longer runs the helper", SNIPPET,
         '    *) /usr/lib/rhizo/install/bootstrap/console-vt.py "/dev/tty$XDG_VTNR" ;;\n', "    *) ;;\n",
         "snippet.no-grant"),
        ("the snippet names no helper at all", SNIPPET, "/usr/lib/rhizo/install/bootstrap/console-vt.py",
         "/usr/lib/rhizo/install/rhizo-console-vt", "snippet.no-helper-call", -1),
        ("the snippet ends the login when the helper fails", SNIPPET,
         '"/dev/tty$XDG_VTNR" ;;', '"/dev/tty$XDG_VTNR" || exit 1 ;;', "snippet.ends-login-shell"),
        ("the snippet takes a non-numeric XDG_VTNR", SNIPPET, "    *[!0-9]*) ;;\n", "",
         "snippet.runs-without-vt"),
        ("debian/rules stops installing the snippet", RULES, "\t" + SNIPPET_INSTALL + "\n", "",
         "rules.snippet-not-installed"),
        ("debian/rules stops installing the helper", RULES,
         "\t                src/install/bootstrap/console-vt.py src/install/bootstrap/rundir-root.py \\\n",
         "\t                src/install/bootstrap/rundir-root.py \\\n", "rules.helper-not-installed"),
        ("debian/rules installs the helper flat under the payload's install dir", RULES,
         "\t                $(PAYLOAD)/install/bootstrap/\n", "\t                $(PAYLOAD)/install/\n",
         "rules.helper-not-installed"),
        ("the host snapshot allows the snippet after a remove", SNAPSHOT_ALLOW,
         "remove\tetc\\t/etc/rhizo*\t", "remove\tetc\\t" + SNIPPET_DEST + "\tkept\nremove\tetc\\t/etc/rhizo*\t",
         "snapshot.remove-row"),
        ("redeploy.sh stops staging the snippet", REDEPLOY, RIG_SNIPPET_INSTALL + "\n", "",
         "rig.snippet-not-staged"),
        ("the session grant keeps root's rights only while root owns the VT", HELPER,
         "    if root_keeps_rw(entries):\n", "    if root_perm(entries, st.st_uid) & RW == RW:\n",
         "kernel.greeter-root-refused"),
        ("root_keeps_rw ignores the mask", HELPER,
         "    return root_perm(entries, ACL_UNDEFINED_ID) & RW == RW\n",
         "    return any(t == ACL_USER and i == 0 and p & RW == RW for t, p, i in entries)\n",
         "keep.masked"),
        ("vt_path takes VTNr 0", HELPER, "not 1 <= int(text) <= MAX_VT", "not 0 <= int(text) <= MAX_VT",
         "vt.path"),
        ("grant_session takes any session id", HELPER, "    if not SESSION_ID.fullmatch(session_id):\n",
         "    if session_id is None:\n", "session.id"),
        ("a bare --session is read as a VT path", HELPER, ' or argv[1].startswith("-"):', ":",
         "session.cli"),
        ("the drop-in stops ordering the scope after the unit", DROPIN,
         "After=rhizo-session-vt@%j.service\n", "", "dropin.after"),
        ("the drop-in names the unit by the scope's empty instance", DROPIN, "%j", "%i", "dropin.wants",
         -1),
        ("the drop-in also confines every session scope", DROPIN, "[Unit]\n",
         "[Scope]\nTasksMax=16\n\n[Unit]\n", "dropin.extra"),
        ("the unit runs the console mode", UNIT, "console-vt.py --session %i",
         "console-vt.py /dev/tty%i", "unit.execstart"),
        ("the unit takes the default dependencies", UNIT, "DefaultDependencies=no\n", "",
         "unit.defaultdependencies"),
        ("the unit runs as the session's account", UNIT, "Type=oneshot\n", "Type=oneshot\nUser=%i\n",
         "unit.not-root"),
        ("debian/rules stops installing the drop-in", RULES,
         '\tinstall -D -m 0644 debian/dropins/session-scope-vt.conf \\\n'
         '\t                   "$(PAYLOAD)/host-mode/usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf"\n', "",
         "rules.dropin-not-installed"),
        ("debian/rules stops installing the unit", RULES, "\t" + UNIT_INSTALL + "\n", "",
         "rules.unit-not-installed"),
    ]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for rel in FILES:
            os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
            shutil.copy(os.path.join(ROOT, rel), os.path.join(tmp, rel))
        clean = check(tmp, verbose=False)
        if clean:
            bad.append("the tree's own files fail: %s" % clean)
        for label, rel, old, new, want, *count in cases:
            path = os.path.join(tmp, rel)
            orig = read(tmp, rel)
            if old not in orig:
                bad.append("%s: planting text not found in %s: %r" % (label, rel, old))
                continue
            with open(path, "w") as f:
                f.write(orig.replace(old, new, count[0] if count else 1))
            try:
                got = check(tmp, verbose=False)
            finally:
                with open(path, "w") as f:
                    f.write(orig)
            if not any(g.split(":")[0] == want for g in got):
                bad.append("%s: want %s, got %s" % (label, want, [g.split(":")[0] for g in got]))
    for b in bad:
        print("FAIL selftest: %s" % b)
    if bad:
        return 1
    print("check-console-vt selftest: ok (tree clean, %d planted defects each caught by name)" % len(cases))
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=ROOT)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return 1 if check(args.root) else 0


if __name__ == "__main__":
    sys.exit(main())
