#!/usr/bin/env python3
import argparse
import importlib.util
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, "..", "..", "..", ".."))

USER_AT_DROPIN = "debian/dropins/user-at-prep.conf"
PREP_UNIT = "src/services/units/session/user-prep@.service"
RESET = "src/install/bootstrap/user-cgroup-reset.sh"
FILL = "src/install/bootstrap/skel-fill.sh"
RULES = "debian/rules"

PKG_ROOT = "debian/rhizo"
UNIT_DIR = "/usr/lib/systemd/system"
USER_AT_DIR = UNIT_DIR + "/user@.service.d"
PREP_NAME = "rhizo-user-prep@.service"
PREP_INSTANCE = "rhizo-user-prep@%i.service"
INSTALL_ROOT = "/usr/lib/rhizo/install"
RUNDIR_ROOT = "src/install/bootstrap/rundir-root.py"


def installed_as(rel):
    """return where the package installs a src/install file"""
    assert rel.startswith("src/install/"), rel
    return INSTALL_ROOT + "/" + rel[len("src/install/"):]


WANT_USER_AT = [("Unit", "Wants", PREP_INSTANCE), ("Unit", "After", PREP_INSTANCE)]
JOURNALD_GRANT = "/usr/bin/python3 " + installed_as(RUNDIR_ROOT) + " --own-runtime-dir"
PORTAL_GRANT = "/usr/bin/python3 " + installed_as(RUNDIR_ROOT) + " --own-portal-doc"
WANT_PREP = [("Unit", "Description", "Rhizo user manager setup for UID %i"),
             ("Unit", "After", "user-runtime-dir@%i.service"),
             ("Service", "Type", "oneshot"),
             ("Service", "User", "%i"),
             ("Service", "ExecStart", "-+" + installed_as(RESET) + " %i"),
             ("Service", "ExecStart", "-" + installed_as(FILL)),
             ("Service", "ExecStart", JOURNALD_GRANT),
             ("Service", "ExecStart", PORTAL_GRANT)]
DROPIN_WANTS = ((USER_AT_DROPIN, WANT_USER_AT, "user-at-dropin"),)
PRE_START_KEYS = ("ExecCondition", "ExecStartPre")
EXEC_KEYS = PRE_START_KEYS + ("ExecStart", "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost")

LAB_UID = 4242


def load_sibling(name):
    """return a module loaded from a file in the tools directory"""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(TOOLS, name))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


HOME = load_sibling("new-account-home.py")
read, unit_directives = HOME.read, HOME.unit_directives


def check_units(root):
    """return the unit directive failures"""
    fails = []
    for rel, want, name in DROPIN_WANTS + ((PREP_UNIT, WANT_PREP, "prep-unit"),):
        try:
            got = unit_directives(read(root, rel))
        except FileNotFoundError:
            fails.append("%s: %s is missing" % (name, rel))
            continue
        if got != want:
            fails.append("%s: %s holds %r, want exactly %r" % (name, rel, got, want))
    return fails


def rules_placements(root):
    """return the rules' install lines and their placements"""
    text = read(root, RULES)
    lines = HOME.recipe_lines(text)
    return lines, HOME.placements(lines, HOME.rules_vars(text))


def installed(path):
    """return the host path of a package file"""
    return HOME.live_path(path)


def check_rules(root):
    """return findings for the debian/rules installs"""
    lines, placed = rules_placements(root)
    if not any(t == HOME.INSTALL_TARGET for t, _, _ in lines):
        return ["rules-target: %s has no %s recipe" % (RULES, HOME.INSTALL_TARGET)]
    fails = []
    for src, want_mode, name, ok in (
            (USER_AT_DROPIN, "0644", "rules-user-at-dropin",
             lambda p: os.path.dirname(p) == USER_AT_DIR and p.endswith(".conf")),
            (PREP_UNIT, "0644", "rules-prep-unit", lambda p: p == UNIT_DIR + "/" + PREP_NAME),
            (RESET, "0755", "rules-reset", lambda p: p == installed_as(RESET))):
        hits = [p for p in placed if p[0] == src]
        if len(hits) != 1:
            fails.append("%s: %s installs %s %d times, want once" % (name, RULES, src, len(hits)))
            continue
        _, dest, mode, depth, _ = hits[0]
        if not installed(dest) or not ok(installed(dest)):
            fails.append("%s: %s lands at %s" % (name, src, dest))
        if mode != want_mode:
            fails.append("%s: %s installs with mode %s, want %s" % (name, src, mode, want_mode))
        if depth:
            fails.append("%s: %s's install sits inside a make conditional" % (name, src))
    for src, dest, _, _, _ in placed:
        if installed(dest) and os.path.dirname(installed(dest)) == USER_AT_DIR:
            keys = sorted({k for _, k, _ in unit_directives(read(root, src)) if k in EXEC_KEYS})
            if keys:
                fails.append("user-at-exec: %s sets %s on user@.service" %
                             (src, ", ".join(keys)))
    return fails


LAB_SH = r'''
set -u
res=$1 body=$2 owner=$3
mount --make-rprivate / || exit 113
mount -t tmpfs -o mode=0755 rhizolab /mnt || exit 114
mkdir /mnt/cg && mount -t cgroup2 none /mnt/cg || exit 115
lab=/mnt/cg/rhizo-user-lab-$$
mkdir "$lab" || exit 116
mkdir /mnt/bin && cp "$body" /mnt/body.sh || exit 117
shift 3
for f; do install -m 0755 "$f" "/mnt/bin/$(basename "$f")" || exit 118; done
sh -c 'echo $$ > "$1/cgroup.procs" && exec unshare --cgroup bash /mnt/body.sh "$2"' in "$lab" "$res"
rc=$?
chown -R 0:0 "$lab" && find "$lab" -depth -type d -exec rmdir {} + || rc=119
chown -R "$owner" "$res"
exit $rc
'''

MODEL_SH = r'''
set -u
res=$1
mount -t tmpfs rhizolab /sys/fs/cgroup && mount -t cgroup2 none /sys/fs/cgroup || exit 120
U=%(uid)d
CG=/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service
mkdir -p "${CG%%/*}" || exit 121
nodac() { setpriv --bounding-set -dac_override,-dac_read_search "$@"; }
asuser() { setpriv --reuid=$U --regid=$U --clear-groups "$@"; }
say() { printf '%%s\n' "$*" >>"$res/result"; }
err() { tr '\n' ' ' <"$res/err"; }
# run a prep line
line() {
  local priv=$1 ignore=$2
  shift 2
  if [ "$priv" = 1 ]; then $run "$@" >"$res/err" 2>&1; else asuser "$@" >"$res/err" 2>&1; fi
  [ $? = 0 ] || [ "$ignore" = 1 ]
}
# create the cgroup directory
mk() { [ -d "$1" ] || $run mkdir -m 0755 "$1" 2>"$res/err"; }
# write a process id to cgroup.procs
attach() { $run sh -c 'echo "$2" > "$1/cgroup.procs"' at "$1" "$2" 2>"$res/err"; }
# chown the cgroup files to the account
grant() {
  $run sh -c 'chown '$U:$U' "$1" && chmod 0755 "$1" || exit 1
    for f in cgroup.procs cgroup.subtree_control cgroup.threads; do chown '$U:$U' "$1/$f" || exit 1; done
    chown -R '$U:$U' "$1/$2"' gr "$CG" "$1" 2>"$res/err"
}
mgr=
reap() { [ -z "$mgr" ] || { kill $mgr; wait $mgr 2>/dev/null; }; mgr=; }
# run the cgroup steps of a user@ start
start() {
  local key=$1 pre=$2 p ctl ok
  "$prep" || :
  mk "$CG" || { say "$key=realize: $(err)"; return 1; }
  for p in $(echo "$pre" | sed 's/./& /g'); do
    mk "$CG/.control" || { say "$key=control-subgroup: $(err)"; return 1; }
    sleep 600 & ctl=$!
    ok=0
    attach "$CG/.control" $ctl && grant .control && ok=1
    kill $ctl; wait $ctl 2>/dev/null
    [ $ok = 1 ] || [ "$p" = i ] || { say "$key=control-process: $(err)"; return 1; }
  done
  mk "$CG/init.scope" || { say "$key=init.scope: $(err)"; return 1; }
  sleep 600 & mgr=$!
  attach "$CG/init.scope" $mgr || { say "$key=attach: $(err)"; reap; return 1; }
  grant init.scope || { say "$key=grant: $(err)"; reap; return 1; }
  asuser mkdir "$CG/app.slice" 2>"$res/err" || { say "$key=manager-tree: $(err)"; reap; return 1; }
  say "$key=ok"
}
# remove the cgroup and record the result
stop() {
  asuser rmdir "$CG/app.slice"
  reap
  $run find "$CG" -depth -type d -exec rmdir {} \; 2>/dev/null
  if [ -d "$CG" ]; then say "$1=left"; else say "$1=clean"; fi
}
# run prep and compare the cgroup listings
live() {
  local before after
  before=$(find "$CG" -printf '%%P|%%u\n' | sort | md5sum)
  "$prep" || :
  after=$(find "$CG" -printf '%%P|%%u\n' | sort | md5sum)
  if [ "$before" = "$after" ] && grep -qx "$mgr" "$CG/init.scope/cgroup.procs"; then
    say "$1=untouched"
  else
    say "$1=changed: $(find "$CG" -printf '%%P|%%u ' 2>&1)"
  fi
}
reset_lab() { reap; [ ! -d "$CG" ] || { chown -R 0:0 "$CG" && find "$CG" -depth -type d -exec rmdir {} +; }; }
noprep() { :; }
%(prep_fns)s
%(scenarios)s
'''

SCENARIOS = (
    ("tree", "nodac", "prep_tree", None, "relogin"),
    ("n1", "nodac", "prep_tree", None, "n1"),
    ("stock", "nodac", "noprep", "", "relogin"),
    ("full", "", "noprep", "", "relogin"),
)

SCENARIO_SH = {
    "relogin": '''run=%(run)s prep=%(prep)s
if start %(n)s_start_1 %(pre)s; then live %(n)s_live; stop %(n)s_trim_1
  start %(n)s_start_2 %(pre)s && stop %(n)s_trim_2
fi
reset_lab
''',
    "n1": '''run=%(run)s prep=%(prep)s
mkdir -p "$CG/.control" && chown -R $U:$U "$CG"
start %(n)s_start_1 %(pre)s && stop %(n)s_trim_1
reset_lab
''',
}


def exec_line(value):
    """split an Exec*= value into flags and argv"""
    prefix = re.match(r'^[-@:+!]*', value).group(0)
    return "+" in prefix, "-" in prefix, shlex.split(value[len(prefix):])


def tree_start(root):
    """return the pre-start flags and prep lines"""
    lines, placed = rules_placements(root)
    by_dest = {installed(d): s for s, d, _, _, _ in placed if installed(d)}
    pre, wants, after = "", False, False
    for dest, src in sorted(by_dest.items()):
        if os.path.dirname(dest) != USER_AT_DIR:
            continue
        for sect, key, value in unit_directives(read(root, src)):
            if key in PRE_START_KEYS and value:
                pre += "i" if exec_line(value)[1] else "f"
            if sect == "Unit" and value and PREP_INSTANCE in value.split():
                wants |= key in ("Wants", "Requires", "BindsTo")
                after |= key == "After"
    prep = []
    if wants and after and UNIT_DIR + "/" + PREP_NAME in by_dest:
        unit = unit_directives(read(root, by_dest[UNIT_DIR + "/" + PREP_NAME]))
        for sect, key, value in unit:
            if sect != "Service" or key != "ExecStart" or not value:
                continue
            priv, ignore, argv = exec_line(value.replace("%i", str(LAB_UID)))
            src = by_dest.get(argv[0])
            if src is None:
                prep.append((priv, ignore, ["false"]))
            else:
                prep.append((priv, ignore, [os.path.join(root, src)] + argv[1:]))
    return pre, prep


def lab_findings(root):
    """return findings from the cgroup lab run"""
    for tool in ("sudo", "setpriv", "unshare"):
        if shutil.which(tool) is None:
            return ["lab-not-measured: %s is not on this host" % tool]
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return ["lab-not-measured: sudo -n cannot get root here"]
    pre, prep = tree_start(root)
    files, calls = [], []
    for priv, ignore, argv in prep:
        if os.path.isabs(argv[0]):
            files.append(argv[0])
            argv = ["/mnt/bin/" + os.path.basename(argv[0])] + argv[1:]
        calls.append("  line %d %d %s || return 1" % (priv, ignore, " ".join(shlex.quote(a) for a in argv)))
    prep_fns = "prep_tree() {\n%s\n}" % ("\n".join(calls) or "  :")
    scen = []
    for name, run, fn, fixed_pre, kind in SCENARIOS:
        p = pre if fixed_pre is None else fixed_pre
        scen.append(SCENARIO_SH[kind] % {"n": name, "run": run or "''", "prep": fn,
                                         "pre": shlex.quote(p)})
    body = MODEL_SH % {"uid": LAB_UID, "prep_fns": prep_fns, "scenarios": "".join(scen)}
    with tempfile.TemporaryDirectory() as work:
        res = os.path.join(work, "res")
        os.mkdir(res)
        lab, model = os.path.join(work, "lab.sh"), os.path.join(work, "model.sh")
        with open(lab, "w") as fh:
            fh.write(LAB_SH)
        with open(model, "w") as fh:
            fh.write(body)
        r = subprocess.run(["sudo", "-n", "python3", "-c", HOME.USERNS_PY, "bash", lab, res, model,
                            "%d:%d" % (os.getuid(), os.getgid())] + files,
                           capture_output=True, text=True, timeout=300)
        result = os.path.join(res, "result")
        if r.returncode != 0 or not os.path.exists(result):
            return ["lab-broken: the cgroup lab exited rc=%d: %s" % (r.returncode, r.stderr.strip()[-400:])]
        got = HOME.parse_result(result)
    return verdict(got)


NODAC = ("sudo", "-n", "setpriv", "--bounding-set", "-dac_override,-dac_read_search")
READLINK_PY = ("import os, sys\n"
               "try:\n"
               "    print('READ', os.readlink(sys.argv[1]))\n"
               "except OSError as e:\n"
               "    print('REFUSED', e.strerror)\n")


def journald_readlink(path):
    """return the readlink result for path"""
    r = subprocess.run(NODAC + (sys.executable, "-c", READLINK_PY, path), capture_output=True, text=True)
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("READ", "REFUSED"))]
    return lines[0] if lines else "NO-ANSWER rc=%d %s" % (r.returncode, r.stderr.strip()[-200:])


def journald_grant_line(root):
    """return the prep unit's rundir grant argv"""
    for sect, key, value in unit_directives(read(root, PREP_UNIT)):
        if sect != "Service" or key != "ExecStart" or not value:
            continue
        priv, _ignore, argv = exec_line(value)
        if not priv and argv[-1:] == ["--own-runtime-dir"] and any(a.endswith("/rundir-root.py") for a in argv):
            return argv
    return None


def journald_findings(root):
    """return findings from the journald readlink lab"""
    if journald_grant_line(root) is None:
        return ["journald-grant: %s runs no rundir-root.py --own-runtime-dir as the account" % PREP_UNIT]
    if shutil.which("setpriv") is None or subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode:
        return ["lab-not-measured: sudo -n or setpriv is missing, so no root-without-DAC readlink ran"]
    found = []
    r = subprocess.run(("sudo", "-n", "mktemp", "-d", "-p", "/dev/shm", "run-user.XXXXXX"),
                       capture_output=True, text=True)
    if r.returncode != 0:
        return ["journald-lab: sudo mktemp exited %d: %s" % (r.returncode, r.stderr.strip())]
    parent = r.stdout.strip()
    try:
        subprocess.run(("sudo", "-n", "chmod", "0755", parent), check=True, capture_output=True)
        rundir = os.path.join(parent, str(os.getuid()))
        subprocess.run(("sudo", "-n", "install", "-d", "-m", "0700", "-o", str(os.getuid()),
                        "-g", str(os.getgid()), rundir), check=True, capture_output=True)
        os.makedirs(os.path.join(rundir, "systemd", "units"))
        link = os.path.join(rundir, "systemd", "units", "invocation:app.service")
        os.symlink("0123456789abcdef0123456789abcdef", link)
        got = journald_readlink(link)
        if not got.startswith("REFUSED"):
            return ["journald-control: root without DAC override read %s before any grant (%s)" % (link, got)]
        helper = os.path.join(root, RUNDIR_ROOT)
        own = subprocess.run((sys.executable, "-c", "import runpy, sys; print(runpy.run_path(sys.argv[1])"
                              "['own_runtime_dir']())", helper), capture_output=True, text=True)
        if own.stdout.strip() != "/run/user/%d" % os.getuid():
            found.append("journald-own-dir: --own-runtime-dir resolves to %r for uid %d, not /run/user/%d"
                         % ((own.stdout + own.stderr).strip(), os.getuid(), os.getuid()))
        h = subprocess.run((sys.executable, helper, rundir), capture_output=True, text=True)
        if h.returncode != 0:
            found.append("journald-grant-run: the grant on %s exited %d: %s"
                         % (rundir, h.returncode, (h.stdout + h.stderr).strip()))
        got = journald_readlink(link)
        if got != "READ 0123456789abcdef0123456789abcdef":
            found.append("journald-refused: after the account's grant, root without DAC override still "
                         "cannot read a user unit's invocation id: %s" % got)
    except (OSError, subprocess.CalledProcessError) as e:
        found.append("journald-lab: %s" % e)
    finally:
        subprocess.run(("sudo", "-n", "rm", "-rf", "--", parent), capture_output=True)
    return found


STEP_RESULT = {"realize": "Result=resources", "control-subgroup": "Result=resources",
               "init.scope": "Result=resources, `Failed to create subcgroup 'init.scope'`",
               "attach": "status=219/CGROUP", "grant": "status=219/CGROUP",
               "control-process": "status=219/CGROUP from ExecStartPre",
               "manager-tree": "the manager's own units fail"}


def why(value):
    """return a value with the result of the step that produced it"""
    step = (value or "<not run>").split(":")[0]
    return "%s (%s)" % (value or "<not run>", STEP_RESULT.get(step, "not started"))


def verdict(got):
    """return the failures in the lab results"""
    fails = []
    if got.get("full_start_1") != "ok" or got.get("full_start_2") != "ok":
        fails.append("lab-control: with full root a stock user@ started %s, then %s" %
                     (why(got.get("full_start_1")), why(got.get("full_start_2"))))
    if got.get("stock_start_1") != "ok":
        fails.append("lab-control: without DAC override a stock user@ first start ended %s" %
                     why(got.get("stock_start_1")))
    elif got.get("stock_start_2") == "ok":
        fails.append("lab-no-defect: without DAC override a stock user@ started again after its "
                     "cgroup was %s" %
                     got.get("stock_trim_1"))
    if got.get("tree_start_1") != "ok":
        fails.append("start-first: with the tree's units the first user@ start fails at %s" %
                     why(got.get("tree_start_1")))
    else:
        if got.get("tree_live") != "untouched":
            fails.append("reset-live: the prep unit, run while the manager is up, %s" %
                         got.get("tree_live"))
        if got.get("tree_start_2") != "ok":
            fails.append("start-again: after a logout left the cgroup %s, the next user@ start "
                         "fails at %s" % (got.get("tree_trim_1"), why(got.get("tree_start_2"))))
    if got.get("n1_start_1") != "ok":
        fails.append("start-after-n1: the first start after the ExecStartPre drop-in's failed one "
                     "fails at %s" % why(got.get("n1_start_1")))
    return fails


def check(root, verbose=True):
    """return the failures from every user manager check"""
    fails = check_units(root) + check_rules(root) + lab_findings(root) + journald_findings(root)
    if verbose:
        for f in fails:
            print("FAIL: " + f)
        if not fails:
            print("user manager start: user@.service runs no Exec line of Rhizo's, %s clears the "
                  "cgroup a stopped manager left, and two starts pass on a real cgroup2 tree "
                  "without DAC override; the account's grant on its runtime dir lets journald, root "
                  "without DAC override, read a user unit's invocation id" % PREP_NAME)
    return fails


FIXTURE_FILES = (USER_AT_DROPIN, PREP_UNIT, RESET, FILL, RULES, RUNDIR_ROOT)


def make_fixture(tmp):
    """copy the checked files into a fixture tree"""
    for rel in FIXTURE_FILES:
        dst = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, rel), dst)


def edit(tmp, rel, old, new):
    """replace a text in a fixture file"""
    HOME.edit(tmp, rel, old, new)


PLANTS = (
    ("the shipped ExecStartPre drop-in back",
     {"user-at-dropin:", "user-at-exec:", "start-first:", "start-after-n1:"},
     lambda t: edit(t, USER_AT_DROPIN, "[Unit]\n",
                    "[Service]\nExecStartPre=-/usr/lib/rhizo/install/bootstrap/skel-fill.sh\n[Unit]\n")),
    ("a second user@ drop-in running an ExecStartPre", {"user-at-exec:", "start-first:", "start-after-n1:"},
     lambda t: (open(os.path.join(t, "debian/dropins/user-at-extra.conf"), "w").write(
         "[Service]\nExecStartPre=/bin/true\n"),
                open(os.path.join(t, RULES), "a").write(
         "\noverride_dh_auto_install:\n\tinstall -D -m 0644 debian/dropins/user-at-extra.conf "
         "\"$(UNITS)/user@.service.d/extra.conf\"\n"))),
    ("the reset run as the account", {"prep-unit:", "start-again:", "start-after-n1:"},
     lambda t: edit(t, PREP_UNIT, "-+/usr/lib/rhizo", "-/usr/lib/rhizo")),
    ("the drop-in no longer ordering the prep unit first",
     {"user-at-dropin:", "start-again:", "start-after-n1:"},
     lambda t: edit(t, USER_AT_DROPIN, "After=rhizo-user-prep@%i.service\n", "")),
    ("a reset that removes a running manager's cgroup", {"reset-live:"},
     lambda t: edit(t, RESET, '  *"populated 0"*) ;;\n  *) exit 0 ;;\n', '  *) ;;\n')),
    ("a reset that removes without giving the tree back to root", {"start-again:", "start-after-n1:"},
     lambda t: edit(t, RESET, 'chown -R 0:0 "$cg" || ', "")),
    ("the reset helper left out of the payload", {"rules-reset:", "start-again:", "start-after-n1:"},
     lambda t: edit(t, RULES, "\t                src/install/bootstrap/skel-fill.sh src/install/bootstrap/user-cgroup-reset.sh \\\n",
                    "\t                src/install/bootstrap/skel-fill.sh \\\n")),
    ("the reset helper installed flat under the payload's install dir", {"rules-reset:", "start-again:", "start-after-n1:"},
     lambda t: edit(t, RULES, "\t                $(PAYLOAD)/install/bootstrap/\n", "\t                $(PAYLOAD)/install/\n")),
    ("the prep unit left out of the package", {"rules-prep-unit:", "start-again:", "start-after-n1:"},
     lambda t: edit(t, RULES, '\tinstall -D -m 0644 "src/services/units/session/user-prep@.service" "$(UNITS)/rhizo-user-prep@.service"\n', "")),
    ("a journald grant on another runtime dir", {"journald-own-dir:"},
     lambda t: edit(t, RUNDIR_ROOT, 'return "/run/user/%d" % os.getuid()', 'return "/run/user/%d0" % os.getuid()')),
    ("the journald grant dropped from the prep unit", {"prep-unit:", "journald-grant:"},
     lambda t: edit(t, PREP_UNIT, "ExecStart=" + JOURNALD_GRANT + "\n", "")),
    ("a journald grant that gives root nothing", {"journald-refused:"},
     lambda t: edit(t, RUNDIR_ROOT, "    kept.append((ACL_USER, perm, 0))\n", "    kept.append((ACL_USER, 0, 0))\n")),
)


def selftest():
    """check each planted-defect copy against its finding"""
    asserts = 0
    with tempfile.TemporaryDirectory() as tmp:
        make_fixture(tmp)
        fails = check(tmp, verbose=False)
        assert not fails, "the tree's own files, copied, were flagged: %r" % fails
        asserts += 1
    for what, want, plant in PLANTS:
        with tempfile.TemporaryDirectory() as tmp:
            make_fixture(tmp)
            plant(tmp)
            got = {f.split(":")[0] + ":" for f in check(tmp, verbose=False)}
            assert got == want, "%s gave %r, want exactly %r" % (what, sorted(got), sorted(want))
            asserts += 1
    print("check-user-manager-start selftest: %d assertions, %d planted defects each named, "
          "systemd 255's cgroup steps run on a real cgroup2 tree without DAC override" %
          (asserts, len(PLANTS)))
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
            print("check-user-manager-start selftest: FAILED, %s" % e)
            return 1
    return 1 if check(args.root) else 0


if __name__ == "__main__":
    sys.exit(main())
