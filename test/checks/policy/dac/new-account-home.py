#!/usr/bin/env python3
import argparse
import hashlib
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, "..", "..", "..", ".."))

ACCOUNTS_DROPIN = "debian/dropins/accounts-daemon-skel.conf"
PREP_UNIT = "src/services/units/session/user-prep@.service"
HELPER = "src/install/bootstrap/skel-fill.sh"
RULES = "debian/rules"

PKG_ROOT = "debian/rhizo"
ACCOUNTS_UNIT_DIR = "/usr/lib/systemd/system/accounts-daemon.service.d"
HOST_MODE = "/usr/lib/rhizo/host-mode"
ACCOUNTS_DROPIN_DEST = "$(PAYLOAD)/host-mode/usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf"
HELPER_DEST = "/usr/lib/rhizo/install/bootstrap/skel-fill.sh"
WANT_ACCOUNTS = [("Service", "TemporaryFileSystem", "/etc/skel:ro")]
WANT_FILL = [("Service", "User", "%i"), ("Service", "ExecStart", "-" + HELPER_DEST)]
INSTALL_TARGET = "override_dh_auto_install"


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def unit_directives(text):
    """get the directives of a unit file"""
    out, sect = [], None
    for line in text.splitlines():
        s = line.strip()
        if not s or s[0] in "#;":
            continue
        m = re.fullmatch(r'\[(.+)\]', s)
        if m:
            sect = m.group(1)
            continue
        key, sep, value = s.partition("=")
        out.append((sect, key.strip(), value.strip() if sep else None))
    return out


def tmpfs_entries(root):
    """get the TemporaryFileSystem= entries of the accounts-daemon drop-in"""
    out = []
    for sect, key, value in unit_directives(read(root, ACCOUNTS_DROPIN)):
        if sect == "Service" and key == "TemporaryFileSystem" and value:
            out.extend(value.split())
    return out


DROPIN_WANTS = ((ACCOUNTS_DROPIN, WANT_ACCOUNTS, "accounts-dropin"),)


def check_dropins(root):
    """return the drop-in and prep unit findings"""
    fails = []
    for rel, want, name in DROPIN_WANTS:
        try:
            got = unit_directives(read(root, rel))
        except FileNotFoundError:
            fails.append("%s: %s is missing" % (name, rel))
            continue
        if got != want:
            fails.append("%s: %s holds %r, want exactly %r" % (name, rel, got, want))
    try:
        got = [d for d in unit_directives(read(root, PREP_UNIT)) if d in WANT_FILL]
    except FileNotFoundError:
        got = []
    if got != WANT_FILL:
        fails.append("prep-fill: %s runs %r, want %r" % (PREP_UNIT, got, WANT_FILL))
    return fails


def rules_vars(text):
    """return the variables assigned in the rules text"""
    return dict(re.findall(r'^([A-Z_]+)\s*:=\s*(\S+)\s*$', text, re.M))


def recipe_lines(text):
    """get the recipe lines of a makefile"""
    out, target, depth = [], None, 0
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        while line.endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i].strip()
        i += 1
        word = line.split()[0] if line.split() else ""
        if word in ("ifeq", "ifneq", "ifdef", "ifndef"):
            depth += 1
        elif word == "endif":
            depth -= 1
        elif line.startswith("\t"):
            if target:
                out.append((target, depth, line.strip()))
        elif line.strip() and not line.startswith("#") and word != "else":
            m = re.match(r'^([^\s:=#]+)\s*:(?!=)', line)
            target = m.group(1) if m else None
    return out


def parse_install(tokens):
    """parse an install command line"""
    mode, flags, tdir, i = None, set(), None, 1
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in ("-m", "-t") and i + 1 < len(tokens):
            if tokens[i] == "-m":
                mode = tokens[i + 1]
            else:
                tdir = tokens[i + 1]
            i += 2
        else:
            flags.add(tokens[i])
            i += 1
    return mode, flags, tdir, tokens[i:]


def placements(lines, variables):
    """get the files the install target places"""
    def expand(s):
        """return the text with make variables substituted"""
        return re.sub(r'\$\((\w+)\)', lambda m: variables.get(m.group(1), m.group(0)), s)
    made, out = set(), []
    for target, depth, line in lines:
        if target != INSTALL_TARGET or line.split()[0] != "install":
            continue
        mode, flags, tdir, args = parse_install([expand(t) for t in shlex.split(line)])
        if "-d" in flags:
            made.update(a.rstrip("/") for a in args)
            continue
        if tdir:
            out.extend((s, tdir.rstrip("/") + "/" + os.path.basename(s), mode, depth, line)
                       for s in args)
            continue
        if len(args) < 2:
            continue
        srcs, dest = args[:-1], args[-1]
        if dest.endswith("/") or len(srcs) > 1 or dest in made:
            out.extend((s, dest.rstrip("/") + "/" + os.path.basename(s), mode, depth, line)
                       for s in srcs)
        else:
            out.append((srcs[0], dest, mode, depth, line))
            if "-D" in flags:
                d = os.path.dirname(dest)
                while d and d not in made:
                    made.add(d)
                    d = os.path.dirname(d)
    return out


def live_path(dest):
    """return a package file's path on the host"""
    path = dest[len(PKG_ROOT):] if dest.startswith(PKG_ROOT + "/") else None
    if path and path.startswith(HOST_MODE + "/"):
        path = path[len(HOST_MODE):]
    return path


def check_rules(root):
    """return the debian/rules install findings"""
    text = read(root, RULES)
    lines = recipe_lines(text)
    if not any(t == INSTALL_TARGET for t, _, _ in lines):
        return ["rules-target: %s has no %s recipe" % (RULES, INSTALL_TARGET)]
    variables = rules_vars(text)
    placed = placements(lines, variables)
    fails = []
    for src, want_mode, name, ok in (
            (ACCOUNTS_DROPIN, "0644", "rules-accounts-dropin",
             lambda p: os.path.dirname(p) == ACCOUNTS_UNIT_DIR and p.endswith(".conf")),
            (HELPER, "0755", "rules-helper", lambda p: p == HELPER_DEST)):
        hits = [p for p in placed if p[0] == src]
        if len(hits) != 1:
            fails.append("%s: %s's %s installs %s %d times, want once" %
                         (name, RULES, INSTALL_TARGET, src, len(hits)))
            continue
        _, dest, mode, depth, own = hits[0]
        if not live_path(dest) or not ok(live_path(dest)):
            fails.append("%s: %s lands at %s" % (name, src, dest))
        if mode != want_mode:
            fails.append("%s: %s installs with mode %s, want %s" % (name, src, mode, want_mode))
        if depth:
            fails.append("%s: %s's install sits inside a make conditional" % (name, src))
        for other in placed:
            if other[1] == dest and other[0] != src:
                fails.append("%s: %s also installs %s over %s" % (name, RULES, other[0], dest))
        for target, _, line in lines:
            if line == own:
                continue
            try:
                tokens = [t.rstrip("/") for t in shlex.split(
                    re.sub(r'\$\((\w+)\)', lambda m: variables.get(m.group(1), m.group(0)), line))]
            except ValueError:
                continue
            if tokens and tokens[0] == "install" and dest not in tokens:
                continue
            if any(t == dest or (t.startswith(PKG_ROOT + "/") and dest.startswith(t + "/"))
                   for t in tokens):
                fails.append("%s: %s's %s names %s or a directory above it: %s" %
                             (name, RULES, target, dest, line))
    return fails


HELPER_NS_SH = r'''
mount --bind "$1" /etc/login.defs || exit 113
mount --bind "$2" /etc/passwd || exit 114
mount --bind "$3" /etc/skel || exit 115
cd / || exit 116
umask 022
exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin sh "$4"
'''

FIXTURE_SKEL = (
    (".profile", "file", 0o644, "profile\n"),
    (".shared", "file", 0o664, "shared\n"),
    (".secret", "file", 0o600, "secret\n"),
    (".config", "dir", 0o700, None),
    (".config/app.conf", "file", 0o640, "conf\n"),
    (".link", "link", None, ".profile"),
)


def make_skel(path):
    """create a fixture skeleton directory"""
    os.mkdir(path)
    for rel, kind, mode, data in FIXTURE_SKEL:
        p = os.path.join(path, rel)
        if kind == "dir":
            os.mkdir(p)
        elif kind == "link":
            os.symlink(data, p)
            continue
        else:
            with open(p, "w") as fh:
                fh.write(data)
        os.chmod(p, mode)
    os.chmod(path, 0o755)


def snapshot(path):
    """list the entries under a directory"""
    out = []
    for dirpath, dirnames, filenames in os.walk(path):
        for name in sorted(dirnames + filenames):
            p = os.path.join(dirpath, name)
            st = os.lstat(p)
            rel = os.path.relpath(p, path)
            if stat.S_ISLNK(st.st_mode):
                out.append((rel, "link", None, os.readlink(p)))
            elif stat.S_ISDIR(st.st_mode):
                out.append((rel, "dir", stat.S_IMODE(st.st_mode), None))
            else:
                with open(p, "rb") as fh:
                    digest = hashlib.sha256(fh.read()).hexdigest()
                out.append((rel, "file", stat.S_IMODE(st.st_mode), digest))
    return sorted(out)


def run_helper(helper, work, home, uid_min):
    """run the helper against a fixture home and UID minimum"""
    defs = os.path.join(work, "login.defs")
    with open(defs, "w") as fh:
        fh.write("UID_MIN %d\nUID_MAX 60000\n" % uid_min)
    passwd = os.path.join(work, "passwd")
    with open(passwd, "w") as fh:
        fh.write("root:x:0:0:root:%s:/bin/sh\n" % home)
    r = subprocess.run(["unshare", "--user", "--map-root-user", "--mount", "sh", "-c",
                        HELPER_NS_SH, "ns", defs, passwd, os.path.join(work, "skel"), helper],
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout, r.stderr


def helper_findings(helper):
    """return the failures from running the helper against fixture homes"""
    fails = []
    with tempfile.TemporaryDirectory() as work:
        make_skel(os.path.join(work, "skel"))
        want = snapshot(os.path.join(work, "skel"))

        home = os.path.join(work, "home-empty")
        os.mkdir(home, 0o750)
        rc, out, err = run_helper(helper, work, home, 0)
        if rc >= 113:
            return ["helper-namespace: the unprivileged user namespace could not be set up "
                    "(rc=%d): %s" % (rc, err.strip())]
        if rc != 0 or snapshot(home) != want:
            fails.append("helper-fill: an empty home got %r (rc=%d, %s), want skel's %r" %
                         (snapshot(home), rc, err.strip(), want))
        if stat.S_IMODE(os.stat(home).st_mode) != 0o750:
            fails.append("helper-home-mode: the home went from 0750 to %o" %
                         stat.S_IMODE(os.stat(home).st_mode))
        before = snapshot(home)
        rc, out, err = run_helper(helper, work, home, 0)
        if rc != 0 or out.strip() or snapshot(home) != before:
            fails.append("helper-idempotent: a second run on a filled home printed %r (rc=%d) "
                         "and left %r" % (out.strip(), rc, snapshot(home)))

        home = os.path.join(work, "home-used")
        os.mkdir(home, 0o750)
        open(os.path.join(home, "keep"), "w").close()
        rc, out, err = run_helper(helper, work, home, 0)
        if rc != 0 or sorted(os.listdir(home)) != ["keep"]:
            fails.append("helper-nonempty: a home already holding a file ended with %r (rc=%d)" %
                         (sorted(os.listdir(home)), rc))

        home = os.path.join(work, "home-system")
        os.mkdir(home, 0o750)
        rc, out, err = run_helper(helper, work, home, 1)
        if rc != 0 or os.listdir(home):
            fails.append("helper-uid-range: an account below UID_MIN got %r (rc=%d)" %
                         (sorted(os.listdir(home)), rc))

        home = os.path.join(work, "home-absent")
        rc, out, err = run_helper(helper, work, home, 0)
        if rc != 0 or os.path.exists(home):
            fails.append("helper-missing-home: a home that does not exist ended rc=%d, exists=%s" %
                         (rc, os.path.exists(home)))
    return fails


def check(root, verbose=True):
    """return the failures from every home check"""
    fails = check_dropins(root) + check_rules(root)
    fails += helper_findings(os.path.join(root, HELPER))
    if verbose:
        for f in fails:
            print("FAIL: " + f)
        if not fails:
            print("new account home: accounts-daemon's adduser sees an empty /etc/skel, %s fills "
                  "an empty home as its owner before user@.service starts" % HELPER_DEST)
    return fails


USERNS_PY = r'''
import os, sys
def extents(kind):
    return "".join("%s %s %s\n" % (l.split()[0], l.split()[0], l.split()[2])
                   for l in open("/proc/self/" + kind))
maps = {k: extents(k) for k in ("uid_map", "gid_map")}
go_r, go_w = os.pipe()
up_r, up_w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(go_w)
    os.close(up_r)
    os.unshare(os.CLONE_NEWUSER | os.CLONE_NEWNS | os.CLONE_NEWCGROUP)
    os.write(up_w, b"u")
    if os.read(go_r, 1) != b"g":
        os._exit(112)
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(go_r)
os.close(up_w)
if os.read(up_r, 1) == b"u":
    try:
        for kind, text in maps.items():
            with open("/proc/%d/%s" % (pid, kind), "w") as f:
                f.write(text)
        os.write(go_w, b"g")
    except OSError as e:
        sys.stderr.write("writing the namespace id maps: %s\n" % e)
os.close(go_w)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
'''

E2E_SH = r'''
set -u
res=$1 helper=$2 owner=$3
shift 3
mount --make-rprivate / || exit 113
mount -t tmpfs -o mode=0755 rhizolab /mnt || exit 114
cp -a /etc /mnt/etc && mount --bind /mnt/etc /etc || exit 115
install -m 0755 "$helper" /mnt/fill || exit 116
mkdir /mnt/res && mount --bind "$res" /mnt/res || exit 117
res=/mnt/res
mount -t tmpfs -o mode=0755 rhizohome /home || exit 118
nodac() { setpriv --bounding-set -dac_override,-dac_read_search "$@"; }
say() { printf '%s\n' "$*" >>"$res/result"; }
state() {
  if id "$1" >/dev/null 2>&1; then say "exists_$1_$2=yes"; else say "exists_$1_$2=no"; fi
  if [ -d "/home/$1" ]; then
    say "home_$1_$2=$(stat -c %a "/home/$1"):$(ls -A "/home/$1" | wc -l)"
  else
    say "home_$1_$2=none"
  fi
}
snap() {
  local uid gid
  uid=$(id -u "$1") gid=$(id -g "$1")
  find "/home/$1" -printf '%P|%M|%U|%G|%s|%l\n' | sort |
    sed "s/|$uid|/|OWNER|/; s/|$gid|/|OWNERG|/" >"$res/$1.snap"
  (cd "/home/$1" && find . -type f -exec sha256sum {} + | sort -k2) >>"$res/$1.snap"
}
fill_as() {
  (cd / && setpriv --reuid="$(id -u "$1")" --regid="$(id -g "$1")" --init-groups \
     env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin \
     sh -c 'umask 022; exec "$0"' /mnt/fill) >"$res/fill-$1.log" 2>&1
  say "fill_rc_$1=$?"
}
adduser --quiet --disabled-password --gecos "Fixture ctla" ctla >"$res/ctla.log" 2>&1
say "rc_ctla=$?"; snap ctla
useradd -m -s /bin/bash ctlu >"$res/ctlu.log" 2>&1; say "rc_ctlu=$?"; snap ctlu

nodac adduser --quiet --disabled-password --gecos "Fixture stka" stka >"$res/stka.log" 2>&1
say "rc_stka=$?"; state stka after
nodac useradd -m -s /bin/bash stku >"$res/stku.log" 2>&1; say "rc_stku=$?"; state stku after

unshare -m sh -c '
  for e; do
    p=${e%%:*} o=
    [ "$p" = "$e" ] || o=,${e#*:}
    mkdir -p "$p" && mount -t tmpfs -o "mode=0755$o" tmpfs "$p" || exit 120
  done
  exec setpriv --bounding-set -dac_override,-dac_read_search \
    adduser --quiet --disabled-password --gecos "Fixture fixa" fixa' tfs "$@" >"$res/fixa.log" 2>&1
say "rc_fixa=$?"; state fixa before
fill_as fixa; state fixa after; snap fixa
nodac useradd -m -s /bin/bash fixu >"$res/fixu.log" 2>&1; say "rc_fixu=$?"
fill_as fixu; state fixu after; snap fixu

nodac useradd -m -s /bin/bash owna >/dev/null 2>&1
nodac useradd -m -s /bin/bash othr >/dev/null 2>&1
usermod -d /home/othr owna
fill_as owna; state othr after
nodac useradd -m -u 60001 -s /bin/bash hiuid >/dev/null 2>&1
fill_as hiuid; state hiuid after
chown -R "$owner" "$res"
'''


def parse_result(path):
    """return the key=value pairs of a result file"""
    out = {}
    with open(path) as fh:
        for line in fh:
            k, _, v = line.rstrip("\n").partition("=")
            out[k] = v
    return out


def e2e_findings(root, helper=None):
    """run adduser and useradd in a user namespace"""
    helper = helper or os.path.join(root, HELPER)
    for tool in ("sudo", "setpriv", "unshare", "adduser", "useradd"):
        if shutil.which(tool) is None and not os.path.exists("/usr/sbin/" + tool):
            return ["e2e-not-measured: %s is not on this host" % tool]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return ["e2e-not-measured: sudo -n cannot get root here"]
    with tempfile.TemporaryDirectory() as work:
        res = os.path.join(work, "res")
        os.mkdir(res)
        script = os.path.join(work, "e2e.sh")
        with open(script, "w") as fh:
            fh.write(E2E_SH)
        r = subprocess.run(["sudo", "-n", "python3", "-c", USERNS_PY, "bash", script, res,
                            helper, "%d:%d" % (os.getuid(), os.getgid())] + tmpfs_entries(root),
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0 or not os.path.exists(os.path.join(res, "result")):
            return ["e2e-lab: the namespace lab exited rc=%d: %s" %
                    (r.returncode, r.stderr.strip()[-400:])]
        got = parse_result(os.path.join(res, "result"))

        def snap(name):
            """return the snapshot recorded for a case"""
            with open(os.path.join(res, name + ".snap")) as fh:
                return fh.read()

        def log(name):
            """return the log recorded for a case on one line"""
            with open(os.path.join(res, name + ".log")) as fh:
                return " | ".join(fh.read().split("\n")).strip(" |")

        fails = []
        ctla, ctlu = snap("ctla"), snap("ctlu")
        if got.get("rc_ctla") != "0" or got.get("rc_ctlu") != "0" or ".bashrc|" not in ctla:
            return ["e2e-control: full-root adduser rc=%s, useradd rc=%s, home %r" %
                    (got.get("rc_ctla"), got.get("rc_ctlu"), ctla)]
        if got.get("rc_stka") == "0" or got.get("exists_stka_after") != "no":
            fails.append("e2e-no-defect: stock adduser without DAC override ended rc=%s, "
                         "account %s; the lab is not taking the capability away" %
                         (got.get("rc_stka"), got.get("exists_stka_after")))
        if got.get("rc_stku") != "0" or got.get("home_stku_after") != "750:0":
            fails.append("e2e-no-defect: stock useradd -m without DAC override ended rc=%s, "
                         "home %s, want an empty 0750 home" %
                         (got.get("rc_stku"), got.get("home_stku_after")))
        if (got.get("rc_fixa") != "0" or got.get("exists_fixa_before") != "yes"
                or got.get("home_fixa_before") != "750:0"):
            fails.append("e2e-adduser-fixed: accounts-daemon's adduser under the drop-in's "
                         "TemporaryFileSystem=%s ended rc=%s, account %s, home %s: %s" %
                         (tmpfs_entries(root), got.get("rc_fixa"), got.get("exists_fixa_before"),
                          got.get("home_fixa_before"), log("fixa")))
        elif got.get("fill_rc_fixa") != "0" or snap("fixa") != ctla:
            fails.append("e2e-adduser-filled: the filled home differs from full-root adduser's "
                         "(fill rc=%s):\n%s\nwant:\n%s" %
                         (got.get("fill_rc_fixa"), snap("fixa"), ctla))
        if (got.get("rc_fixu") != "0" or got.get("fill_rc_fixu") != "0"
                or snap("fixu") != ctlu):
            fails.append("e2e-useradd-fixed: useradd -m then the helper ended rc=%s/%s with:\n%s\n"
                         "want:\n%s" % (got.get("rc_fixu"), got.get("fill_rc_fixu"),
                                        snap("fixu"), ctlu))
        if got.get("fill_rc_owna") != "0" or got.get("home_othr_after") != "750:0":
            fails.append("e2e-foreign-home: the helper, run for an account whose home belongs "
                         "to another, ended rc=%s and left that home %s" %
                         (got.get("fill_rc_owna"), got.get("home_othr_after")))
        if got.get("fill_rc_hiuid") != "0" or got.get("home_hiuid_after") != "750:0":
            fails.append("e2e-uid-max: the helper, run for uid 60001 above UID_MAX, ended rc=%s "
                         "and left its home %s" %
                         (got.get("fill_rc_hiuid"), got.get("home_hiuid_after")))
        return fails


FIXTURE_FILES = (ACCOUNTS_DROPIN, PREP_UNIT, HELPER, RULES)


def make_fixture(tmp):
    """copy the checked files into a fixture tree"""
    for rel in FIXTURE_FILES:
        dst = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, rel), dst)


def edit(tmp, rel, old, new):
    """replace a text in a fixture file, failing when it is absent"""
    path = os.path.join(tmp, rel)
    text = open(path).read()
    assert text.count(old) >= 1, "selftest fixture edit found no %r in %s" % (old, rel)
    with open(path, "w") as fh:
        fh.write(text.replace(old, new, 1))


def plant_conditional(tmp):
    """make the skeleton drop-in install conditional in the rules"""
    edit(tmp, RULES, "\tinstall -D -m 0644 debian/dropins/accounts-daemon-skel.conf",
         "ifeq ($(RHIZO_SKEL),1)\n\tinstall -D -m 0644 debian/dropins/accounts-daemon-skel.conf")
    edit(tmp, RULES, ACCOUNTS_DROPIN_DEST + "\n", ACCOUNTS_DROPIN_DEST + "\nendif\n")


HELPER_COPY = ('if ! find "$SKEL" -mindepth 1 -maxdepth 1 \\\n'
               '     -exec cp -RP --preserve=mode,timestamps --update=none -t "$home" -- {} +; then')


E2E_PLANTS = (
    ("a drop-in hiding the wrong path", "e2e-adduser-fixed:", {"e2e-adduser-fixed:"},
     lambda t: edit(t, ACCOUNTS_DROPIN, "/etc/skel:ro", "/etc/skel.d:ro")),
    ("a helper resetting the home's mode", "e2e-useradd-fixed:",
     {"e2e-useradd-fixed:", "e2e-adduser-filled:"},
     lambda t: edit(t, HELPER, HELPER_COPY,
                    'if ! cp -RP --preserve=mode,timestamps "$SKEL"/. "$home"/; then')),
    ("a helper with no UID_MAX bound", "e2e-uid-max:", {"e2e-uid-max:"},
     lambda t: edit(t, HELPER, ' && [ "$uid" -le "$(login_def UID_MAX 60000)" ]', "")),
)


def selftest():
    """check each planted-defect copy against its finding"""
    asserts = 0
    with tempfile.TemporaryDirectory() as tmp:
        make_fixture(tmp)
        fails = check(tmp, verbose=False)
        assert not fails, "the tree's own files, copied, were flagged: %r" % fails
        asserts += 1

    planted = (
        ("a commented-out TemporaryFileSystem", "accounts-dropin:",
         lambda t: edit(t, ACCOUNTS_DROPIN, "TemporaryFileSystem=", "#TemporaryFileSystem=")),
        ("a second directive in accounts-daemon's unit", "accounts-dropin:",
         lambda t: edit(t, ACCOUNTS_DROPIN, "[Service]\n", "[Service]\nProtectHome=true\n")),
        ("the prep unit's fill naming another path", "prep-fill:",
         lambda t: edit(t, PREP_UNIT, "/install/bootstrap/skel-fill.sh", "/rhizo-skel-fill")),
        ("the prep unit running the fill as root", "prep-fill:",
         lambda t: edit(t, PREP_UNIT, "ExecStart=-/usr/lib/rhizo/install/bootstrap/skel-fill.sh",
                        "ExecStart=-+/usr/lib/rhizo/install/bootstrap/skel-fill.sh")),
        ("the helper left out of the payload", "rules-helper:",
         lambda t: edit(t, RULES, "\t                src/install/bootstrap/skel-fill.sh src/install/bootstrap/user-cgroup-reset.sh \\\n",
                        "\t                src/install/bootstrap/user-cgroup-reset.sh \\\n")),
        ("the helper installed flat under the payload's install dir", "rules-helper:",
         lambda t: edit(t, RULES, "\t                $(PAYLOAD)/install/bootstrap/\n", "\t                $(PAYLOAD)/install/\n")),
        ("accounts-daemon's drop-in installed beside the unit dir", "rules-accounts-dropin:",
         lambda t: edit(t, RULES, "accounts-daemon.service.d/rhizo-skel.conf",
                        "accounts-daemon.d/rhizo-skel.conf")),
        ("accounts-daemon's drop-in installed only under a conditional", "rules-accounts-dropin:",
         plant_conditional),
        ("the helper copying skel's directory onto the home", "helper-home-mode:",
         lambda t: edit(t, HELPER, HELPER_COPY,
                        'if ! cp -RP --preserve=mode,timestamps "$SKEL"/. "$home"/; then')),
        ("the helper dropping skel's modes", "helper-fill:",
         lambda t: edit(t, HELPER, "--preserve=mode,timestamps --update=none",
                        "--update=none")),
        ("the helper filling a home already in use", "helper-nonempty:",
         lambda t: edit(t, HELPER, '[ -z "$entries" ] || exit 0\n', "")),
        ("accounts-daemon's drop-in installed as a file named after the unit dir",
         "rules-accounts-dropin:",
         lambda t: edit(t, RULES, "\tinstall -D -m 0644 debian/dropins/accounts-daemon-skel.conf \\\n"
                        "\t                   " + ACCOUNTS_DROPIN_DEST,
                        "\tinstall -m 0644 debian/dropins/accounts-daemon-skel.conf \\\n"
                        "\t                   " + os.path.dirname(ACCOUNTS_DROPIN_DEST))),
        ("a later target deleting accounts-daemon's drop-in", "rules-accounts-dropin:",
         lambda t: open(os.path.join(t, RULES), "a").write(
             "\nexecute_after_dh_install:\n"
             "\trm -f " + ACCOUNTS_DROPIN_DEST + "\n")),
        ("a later target deleting the payload's install dir", "rules-helper:",
         lambda t: open(os.path.join(t, RULES), "a").write(
             "\nexecute_after_dh_install:\n\trm -rf $(PAYLOAD)/install\n")),
        ("the helper filling a system account's home", "helper-uid-range:",
         lambda t: edit(t, HELPER, '|| exit 0\n\nhome=$(getent', '|| true\n\nhome=$(getent')),
    )
    for what, prefix, plant in planted:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(tmp)
            plant(tmp)
            fails = check(tmp, verbose=False)
            assert any(f.startswith(prefix) for f in fails), (
                "%s was not caught as %r: %r" % (what, prefix, fails))
            asserts += 1

    fails = e2e_findings(ROOT)
    assert not fails, "the tree's mitigation, run against the real tools: %r" % fails
    asserts += 1
    for what, want, allowed, plant in E2E_PLANTS:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(tmp)
            plant(tmp)
            got = {f.split(":")[0] + ":" for f in e2e_findings(tmp)}
            assert want in got and got <= allowed, (
                "%s, run against the real tools, gave %r, want %r and nothing outside %r" %
                (what, sorted(got), want, sorted(allowed)))
            asserts += 1
    print("check-new-account-home selftest: %d assertions, %d planted defects each named, "
          "the real adduser and useradd measured without DAC override" %
          (asserts, len(planted) + len(E2E_PLANTS)))
    return 0


def main():
    """run the check or its selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=ROOT)
    args = ap.parse_args()
    if args.selftest:
        try:
            return selftest()
        except AssertionError as e:
            print("check-new-account-home selftest: FAILED, %s" % e)
            return 1
    return 1 if check(args.root) else 0


if __name__ == "__main__":
    sys.exit(main())
