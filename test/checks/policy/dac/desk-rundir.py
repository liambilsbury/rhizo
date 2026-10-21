#!/usr/bin/env python3
import argparse
import contextlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, "..", "..", "..", ".."))

HELPER = "src/install/bootstrap/rundir-root.py"
UNIT = "src/services/deskbridge/deskd.service"
PREP_UNIT = "src/services/units/session/user-prep@.service"
RULES = "debian/rules"
SYNC = "test/vm/sync.sh"
REDEPLOY = "test/vm/redeploy.sh"
FILES = (HELPER, UNIT, PREP_UNIT, RULES, SYNC, REDEPLOY)

HELPER_DEST = "/usr/lib/rhizo/install/bootstrap/rundir-root.py"
SYNC_LINE = "sync_one ./src/install/bootstrap/rundir-root.py var/share/install/bootstrap/rundir-root.py"
HELPER_RULES_DIR = "$(PAYLOAD)/install/bootstrap/"
RIG_SOURCE = "/root/share/install/bootstrap/rundir-root.py"
RIG_GROUP = "bootstrap"
RIG_DEST_DIR = "/usr/lib/rhizo/install/bootstrap/"
GROUP_LOOP = re.compile(r'^for (\w+) in ([^;\n]*); do\n(.*?)^done$', re.M | re.S)
NODAC = ("sudo", "-n", "setpriv", "--bounding-set", "-dac_override,-dac_read_search")
RM_RF = ("import os, sys\n"
         "p = sys.argv[1]\n"
         "try:\n"
         "    fd = os.open(p, os.O_RDONLY | os.O_NONBLOCK | os.O_DIRECTORY | os.O_CLOEXEC\n"
         "                 | os.O_NOFOLLOW | os.O_NOATIME)\n"
         "except OSError as e:\n"
         "    print('REFUSED open', e.strerror)\n"
         "    sys.exit(0)\n"
         "try:\n"
         "    for name in os.listdir(fd):\n"
         "        os.unlink(name, dir_fd=fd)\n"
         "    os.rmdir(p)\n"
         "    print('REMOVED')\n"
         "except OSError as e:\n"
         "    print('REFUSED', e.strerror)\n")
FUSERMOUNT_WALK = ("import os, sys\n"
                   "os.seteuid(int(sys.argv[2]))\n"
                   "os.chdir(sys.argv[1])\n"
                   "os.seteuid(0)\n"
                   "try:\n"
                   "    os.stat('.')\n"
                   "    print('RESOLVED')\n"
                   "except OSError as e:\n"
                   "    print('REFUSED', e.strerror)\n")


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel)) as f:
        return f.read()


def load_helper(root):
    """return the rundir helper loaded as a module from the root"""
    path = os.path.join(root, HELPER)
    h = types.ModuleType("rhizo_rundir_root")
    h.__file__ = path
    with open(path) as f:
        exec(compile(f.read(), path, "exec"), h.__dict__)
    return h


def check_functions(h):
    """return the ACL arithmetic failures"""
    found = []
    got = h.with_root_rwx(h.mode_acl(0o750))
    if h.root_perm(got) != h.RWX:
        found.append("acl.root-not-rwx: a 0750 directory's ACL gives uid 0 %o, not rwx" % h.root_perm(got))
    masks = [p for t, p, _ in got if t == h.ACL_MASK]
    if masks != [0o7]:
        found.append("acl.mask: the mask reads %s after the grant, not [7]" % masks)
    kept = sorted((t, p, i) for t, p, i in got if not (t == h.ACL_USER and i == 0) and t != h.ACL_MASK)
    if kept != sorted(h.mode_acl(0o750)):
        found.append("acl.moves-entries: owner, group and other read %s after the grant, not %s"
                     % (kept, sorted(h.mode_acl(0o750))))
    named = h.mode_acl(0o750) + [(h.ACL_USER, 5, 1234), (h.ACL_MASK, 5, h.ACL_UNDEFINED_ID)]
    back = h.parse_acl(h.pack_acl(h.with_root_rwx(named)))
    if (h.ACL_USER, 5, 1234) not in back:
        found.append("acl.drops-entries: another account's named entry is gone after the grant: %s" % back)
    if h.root_perm(h.mode_acl(0o750)) != 0:
        found.append("acl.control: a bare 0750 mode already gives uid 0 %o" % h.root_perm(h.mode_acl(0o750)))
    return found


def as_root(*cmd):
    """run a command through sudo"""
    r = subprocess.run(("sudo", "-n") + cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise OSError("sudo %s exited %d: %s" % (" ".join(cmd), r.returncode, r.stderr.strip()))
    return r.stdout


def remove_as_nodac_root(path):
    """run the systemd directory removal on path"""
    r = subprocess.run(NODAC + (sys.executable, "-c", RM_RF, path), capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("REMOVED", "REFUSED"))]
    return lines[0] if lines else "NO-ANSWER rc=%d %s" % (r.returncode, r.stderr.strip()[-200:])


def run_helper(h, path):
    """run rundir-root.py on path"""
    r = subprocess.run((sys.executable, h.__file__, path), capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()


def check_kernel(h):
    """return the runtime directory removal failures"""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return ["lab-not-measured: sudo -n cannot get root here, so no root-without-DAC removal ran"]
    if shutil.which("setpriv") is None:
        return ["lab-not-measured: setpriv is not on PATH"]
    base = "/dev/shm" if os.path.isdir("/dev/shm") else None
    found = []
    try:
        parent = as_root("mktemp", "-d", "-p", base or tempfile.gettempdir(), "desk-rundir.XXXXXX").strip()
    except OSError as e:
        return ["kernel.lab: %s" % e]
    try:
        as_root("chmod", "0755", parent)
        rundir = os.path.join(parent, "rhizo-desk")
        as_root("install", "-d", "-m", "0750", "-o", str(os.getuid()), "-g", str(os.getgid()), rundir)
        token = os.path.join(rundir, "token")
        fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, b"0123456789abcdef\n")
        os.close(fd)
        got = remove_as_nodac_root(rundir)
        if not got.startswith("REFUSED") or not os.path.exists(token):
            found.append("kernel.control-removed: root without DAC override removed the owner's 0750 "
                         "directory before any grant (%s)" % got)
            return found
        first = run_helper(h, rundir)
        again = run_helper(h, rundir)
        if first[0] != 0 or not first[1].endswith(": granted") or again[0] != 0 or not again[1].endswith(": already"):
            found.append("kernel.grant-result: first run gave %s, second %s, not rc 0 'granted' then "
                         "rc 0 'already'" % (first, again))
        got = remove_as_nodac_root(rundir)
        if got != "REMOVED" or os.path.lexists(rundir):
            found.append("kernel.root-refused: root without DAC override still cannot empty and remove "
                         "the owner-granted directory: %s" % got)
        foreign = os.path.join(parent, "foreign")
        as_root("install", "-d", "-m", "0755", "-o", "0", "-g", "0", foreign)
        rc, out = run_helper(h, foreign)
        if rc == 0 or "not-owner" not in out:
            found.append("kernel.foreign-dir: the helper on a directory root owns gave rc %d %r, not a "
                         "not-owner refusal" % (rc, out))
        link = os.path.join(parent, "link")
        as_root("ln", "-s", foreign, link)
        rc, out = run_helper(h, link)
        if rc == 0 or "not-a-dir" not in out:
            found.append("kernel.symlink: the helper on a symlink gave rc %d %r, not a not-a-dir refusal"
                         % (rc, out))
    except OSError as e:
        found.append("kernel.lab: %s" % e)
    finally:
        subprocess.run(("sudo", "-n", "rm", "-rf", "--", parent), capture_output=True)
    return found


def walk_as_nodac_root(path):
    """run the fusermount3 walk into path"""
    r = subprocess.run(NODAC + (sys.executable, "-c", FUSERMOUNT_WALK, path, str(os.getuid())),
                       capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("RESOLVED", "REFUSED"))]
    return lines[0] if lines else "NO-ANSWER rc=%d %s" % (r.returncode, r.stderr.strip()[-200:])


def portal_main(h, runtime_dir):
    """run rundir-root.py with --own-portal-doc"""
    h.own_runtime_dir = lambda: runtime_dir
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = h.main([h.PROG, "--own-portal-doc"])
    return rc, out.getvalue().strip()


def check_portal_doc(h):
    """return the document portal mount failures"""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return ["lab-not-measured: sudo -n cannot get root here, so no root-without-DAC walk ran"]
    if shutil.which("setpriv") is None:
        return ["lab-not-measured: setpriv is not on PATH"]
    base = "/dev/shm" if os.path.isdir("/dev/shm") else tempfile.gettempdir()
    found = []
    try:
        parent = as_root("mktemp", "-d", "-p", base, "portal-doc.XXXXXX").strip()
    except OSError as e:
        return ["portal.lab: %s" % e]
    try:
        as_root("chown", "%d:%d" % (os.getuid(), os.getgid()), parent)
        as_root("chmod", "0700", parent)
        doc = os.path.join(parent, "doc")
        os.mkdir(doc, 0o700)
        got = walk_as_nodac_root(doc)
        if not got.startswith("REFUSED"):
            found.append("portal.control-resolved: root without DAC override resolved '.' in the owner's 0700 "
                         "mountpoint before any grant (%s)" % got)
            return found
        if h.grant(parent, os.getuid()) != "granted":
            found.append("portal.lab: the runtime dir's own grant did not apply")
            return found
        first, again = portal_main(h, parent), portal_main(h, parent)
        if first[0] != 0 or not first[1].endswith(": granted") or again[0] != 0 or not again[1].endswith(": already"):
            found.append("portal.grant-result: --own-portal-doc gave %s, then %s, not rc 0 'granted' then "
                         "rc 0 'already'" % (first, again))
        perm = h.root_perm(h.parse_acl(os.getxattr(doc, h.ACL_XATTR)))
        if perm != h.X:
            found.append("portal.too-wide: uid 0 holds %o on the mountpoint, not search alone" % perm)
        got = walk_as_nodac_root(doc)
        if got != "RESOLVED":
            found.append("portal.root-refused: root without DAC override still cannot resolve '.' in the "
                         "granted mountpoint: %s" % got)
        os.rmdir(doc)
        rc, out = portal_main(h, parent)
        st = os.stat(doc) if os.path.isdir(doc) else None
        if rc != 0 or st is None or st.st_uid != os.getuid() or st.st_mode & 0o707 != 0o700:
            found.append("portal.not-made: with no mountpoint, --own-portal-doc gave rc %d %r and left %s"
                         % (rc, out, "no directory" if st is None else "mode %o uid %d" % (st.st_mode, st.st_uid)))
    except OSError as e:
        found.append("portal.lab: %s" % e)
    finally:
        subprocess.run(("sudo", "-n", "rm", "-rf", "--", parent), capture_output=True)
    return found


def unit_keys(text):
    """parse a unit file into key values"""
    keys, section = {}, None
    for line in re.sub(r"\\\n\s*", " ", text).splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        if sep:
            keys.setdefault((section, key.strip()), []).append(value.strip())
    return keys


def check_unit(root):
    """return the rhizo-deskd.service runtime directory failures"""
    unit = unit_keys(read(root, UNIT))
    found = []
    names = unit.get(("Service", "RuntimeDirectory"), [])
    if len(names) != 1 or not re.fullmatch(r"[a-z0-9-]+", names[0]):
        return ["unit.runtime-dir: %s's RuntimeDirectory= reads %s, not one plain name" % (UNIT, names)]
    rundir = "/run/" + names[0]
    user = unit.get(("Service", "User"), [])
    if not user or user[-1] in ("", "root", "0"):
        found.append("unit.user: %s's User= reads %s" % (UNIT, user))
    want = "/usr/bin/python3 %s %s" % (HELPER_DEST, rundir)
    pre = unit.get(("Service", "ExecStartPre"), [])
    if want not in pre:
        found.append("unit.no-grant: %s has no `ExecStartPre=%s` running as its User=, so PID 1 cannot "
                     "remove %s at the stop (ExecStartPre= reads %s)" % (UNIT, want, rundir, pre))
    start = " ".join(unit.get(("Service", "ExecStart"), []))
    m = re.search(r"--token-file\s+(\S+)", start)
    if not m or os.path.dirname(m.group(1)) != rundir:
        found.append("unit.token-elsewhere: rhizo-deskd's --token-file is %s, not a file in %s"
                     % (m.group(1) if m else None, rundir))
    preserve = unit.get(("Service", "RuntimeDirectoryPreserve"), ["no"])
    if preserve[-1] != "no":
        found.append("unit.preserved: RuntimeDirectoryPreserve=%s keeps %s and its token across stops"
                     % (preserve[-1], rundir))
    return found


def check_prep_unit(root):
    """return the rhizo-user-prep@.service failures"""
    unit = unit_keys(read(root, PREP_UNIT))
    found = []
    if unit.get(("Service", "User"), []) != ["%i"]:
        found.append("prep.user: %s's User= reads %s, not the account it prepares"
                     % (PREP_UNIT, unit.get(("Service", "User"), [])))
    want = "/usr/bin/python3 %s --own-portal-doc" % HELPER_DEST
    if want not in unit.get(("Service", "ExecStart"), []):
        found.append("prep.no-portal-grant: %s has no `ExecStart=%s` as the account" % (PREP_UNIT, want))
    return found


def rules_commands(text):
    """return the debian/rules recipe commands"""
    return [c.strip() for c in re.sub(r"\\\n\s*", " ", text).splitlines() if c.startswith("\t")]


def rig_installs_helper(text):
    """return whether redeploy.sh installs RIG_SOURCE into RIG_DEST_DIR"""
    for ln in text.splitlines():
        words = ln.split()
        if ln.startswith("install -m 0755 ") and RIG_SOURCE in words and words[-1].strip('"') == RIG_DEST_DIR:
            return True
    for var, groups, body in GROUP_LOOP.findall(text):
        if RIG_GROUP not in groups.split():
            continue
        src, dest = '/root/share/install/"$%s"/*' % var, '"/usr/lib/rhizo/install/$%s/"' % var
        if any(ln.split()[:3] == ["install", "-m", "0755"] and src in ln.split() and ln.split()[-1] == dest
               for ln in body.splitlines()):
            return True
    return False


def check_static(root):
    """return the packaging and rig failures"""
    found = []
    cmds = rules_commands(read(root, RULES))
    if not any(c.startswith("install -m 0755 ") and HELPER in c.split()
               and c.split()[-1] == HELPER_RULES_DIR for c in cmds):
        found.append("rules.helper-not-installed: no `install -m 0755 ... %s ... %s` "
                     "line, so %s does not exist" % (HELPER, HELPER_RULES_DIR, HELPER_DEST))
    if SYNC_LINE not in read(root, SYNC).splitlines():
        found.append("rig.not-synced: %s has no `%s` line" % (SYNC, SYNC_LINE))
    if not rig_installs_helper(read(root, REDEPLOY)):
        found.append("rig.not-staged: %s installs no %s into %s, by name or by its %s group's loop" % (REDEPLOY, RIG_SOURCE, RIG_DEST_DIR, RIG_GROUP))
    return found


def check(root, verbose=True):
    """return the failures from every rundir check"""
    h = load_helper(root)
    found = (check_functions(h) + check_kernel(h) + check_portal_doc(h) + check_unit(root)
             + check_prep_unit(root) + check_static(root))
    if verbose:
        for f in found:
            print("FAIL %s" % f)
        if not found:
            print("ok: uid 0 gets rwx on the owner-granted directory and no other entry moves; root "
                  "without DAC override removes it and its token only after the owner's grant; "
                  "rhizo-deskd.service runs the grant as its User= on the RuntimeDirectory= holding the "
                  "token; root gets search alone on the portal's mountpoint and resolves '.' in it only "
                  "after the grant, which rhizo-user-prep@.service runs as the account; rules, the rig and "
                  "the docs carry it")
    return found


def selftest():
    """check each planted-defect copy against its finding"""
    cases = [
        ("the helper keeps the old mask", HELPER, "            mask |= perm\n", "            mask |= 0\n",
         "kernel.root-refused"),
        ("the helper grants rw, not rwx", HELPER, "    kept.append((ACL_USER, perm, 0))\n",
         "    kept.append((ACL_USER, perm & 0o6, 0))\n", "acl.root-not-rwx"),
        ("the helper drops other named entries", HELPER,
         "kept = [e for e in entries if e[0] != ACL_MASK and not (e[0] == ACL_USER and e[2] == 0)]",
         "kept = [e for e in entries if e[0] in (ACL_USER_OBJ, ACL_GROUP_OBJ, ACL_OTHER)]",
         "acl.drops-entries"),
        ("the helper widens the group entry", HELPER, "    kept.append((ACL_USER, perm, 0))\n",
         "    kept.append((ACL_USER, perm, 0))\n"
         "    kept = [(t, RWX if t == ACL_GROUP_OBJ else p, i) for t, p, i in kept]\n",
         "acl.moves-entries"),
        ("the helper grants any owner's directory", HELPER, "        if st.st_uid != uid:\n",
         "        if st.st_uid == -1:\n", "kernel.foreign-dir"),
        ("the helper follows a symlink", HELPER,
         "os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC",
         "os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC", "kernel.symlink"),
        ("the helper reports a grant it did not write", HELPER,
         "        os.setxattr(fd, ACL_XATTR, pack_acl(with_root(entries, perm)))\n", "",
         "kernel.root-refused"),
        ("the portal grant gives rwx", HELPER, 'perm, why = X, "fusermount3', 'perm, why = RWX, "fusermount3',
         "portal.too-wide"),
        ("the helper grants rwx whatever is asked", HELPER, "    kept.append((ACL_USER, perm, 0))\n",
         "    kept.append((ACL_USER, RWX, 0))\n", "portal.too-wide"),
        ("user-prep drops the portal grant", PREP_UNIT,
         "ExecStart=/usr/bin/python3 /usr/lib/rhizo/install/bootstrap/rundir-root.py --own-portal-doc\n", "",
         "prep.no-portal-grant"),
        ("user-prep runs the portal grant as root", PREP_UNIT,
         "ExecStart=/usr/bin/python3 /usr/lib/rhizo/install/bootstrap/rundir-root.py --own-portal-doc",
         "ExecStart=+/usr/bin/python3 /usr/lib/rhizo/install/bootstrap/rundir-root.py --own-portal-doc",
         "prep.no-portal-grant"),
        ("the unit drops the grant", UNIT,
         "ExecStartPre=/usr/bin/python3 /usr/lib/rhizo/install/bootstrap/rundir-root.py /run/rhizo-desk\n", "",
         "unit.no-grant"),
        ("the unit runs the grant as root", UNIT, "ExecStartPre=/usr/bin/python3", "ExecStartPre=+/usr/bin/python3",
         "unit.no-grant"),
        ("the unit grants another directory", UNIT, "rundir-root.py /run/rhizo-desk",
         "rundir-root.py /run/rhizo-desktop", "unit.no-grant"),
        ("the token moves out of the runtime directory", UNIT, "--token-file /run/rhizo-desk/token",
         "--token-file /run/rhizo-desktop/token", "unit.token-elsewhere"),
        ("the unit preserves its runtime directory", UNIT, "RuntimeDirectoryMode=0750\n",
         "RuntimeDirectoryMode=0750\nRuntimeDirectoryPreserve=yes\n", "unit.preserved"),
        ("the unit runs as root", UNIT, "User=ubuntu\n", "User=root\n", "unit.user"),
        ("debian/rules stops installing the helper", RULES,
         "\t                src/install/bootstrap/console-vt.py src/install/bootstrap/rundir-root.py \\\n",
         "\t                src/install/bootstrap/console-vt.py \\\n", "rules.helper-not-installed"),
        ("debian/rules installs the helper flat under the payload's install dir", RULES,
         "\t                $(PAYLOAD)/install/bootstrap/\n", "\t                $(PAYLOAD)/install/\n",
         "rules.helper-not-installed"),
        ("sync.sh stops syncing the helper", SYNC, SYNC_LINE + "\n", "", "rig.not-synced"),
        ("redeploy.sh stops staging the helper's group", REDEPLOY, "for _group in bootstrap ", "for _group in ",
         "rig.not-staged"),
        ("redeploy.sh installs the helper's group flat under the install dir", REDEPLOY,
         '"/usr/lib/rhizo/install/$_group/"', '"/usr/lib/rhizo/install/"', "rig.not-staged"),
        ("redeploy.sh's loop installs from another share dir", REDEPLOY,
         '/root/share/install/"$_group"/*', '/root/share/"$_group"/*', "rig.not-staged"),
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
    print("check-desk-rundir selftest: ok (tree clean, %d planted defects each caught by name)" % len(cases))
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
