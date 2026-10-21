#!/usr/bin/env python3
"""check the refusal to load Android's policy under a login session"""
import ast
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SELINUX = os.path.join(ROOT, "src", "androidd", "sandbox", "selinux_labels.py")
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
REDEPLOY = os.path.join(ROOT, "test", "vm", "redeploy.sh")
CLI = os.path.join(ROOT, "src", "install", "cli", "rhizo.sh")
PRODUCT_DIRS = (os.path.join(ROOT, "debian"), os.path.join(ROOT, "src", "services"),
                os.path.join(ROOT, "src", "install"))
LIFTED = ("parse_sessions", "login_sessions", "systemd_version", "policy_load_refusal",
          "session_scopes", "read_sessions")
CONSTANTS = ("EXEMPT_CLASSES", "SESSION_PROPERTIES", "REEXEC_SYSTEMD", "RIG_LOAD_UNDER_LOGIN")
OVERRIDE = "RHIZO_RIG_LOAD_UNDER_LOGIN"

SHOW = """Id=4
Name=ubuntu
Remote=no
Type=wayland
Class=user
Seat=seat0
TTY=tty1
State=active

Id=5
Name=root
Remote=yes
Type=tty
Class=user
Seat=
TTY=pts/0
State=active

Id=6
Name=root
Remote=yes
Type=tty
Class=user
Seat=
TTY=
State=active

Id=c1
Name=gdm
Remote=no
Type=wayland
Class=greeter
Seat=seat0
TTY=tty1
State=online

Id=7
Name=lingeruser
Remote=no
Type=unspecified
Class=manager
Seat=
TTY=
State=active

Id=8
Name=root
Remote=no
Type=tty
Class=background
Seat=
TTY=pts/2
State=active

Id=9
Name=deskuser
Remote=no
Type=tty
Class=user
Seat=
TTY=ttyS0
State=closing

Id=10
Name=root
Remote=no
Type=tty
Class=user-light
Seat=
TTY=pts/3
State=active
"""
LOGINS = ["4", "5", "6", "c1", "9", "10"]


def lift(path, names):
    """load the named functions and constants of a module by AST"""
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    parts = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in names)
             or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names
                                                    for t in n.targets))]
    ns = {"re": re, "os": os, "glob": __import__("glob"), "subprocess": subprocess}
    exec(compile(ast.unparse(ast.Module(body=parts, type_ignores=[])), path, "exec"), ns)
    return ns


class _Logind:
    """fake subprocess.run for systemctl and loginctl"""

    def __init__(self, state, show=SHOW, raise_on=None):
        """keep logind's state, the show-session text and a command to fail"""
        self.state, self.show, self.raise_on = state, show, raise_on

    def __call__(self, argv, **_kw):
        """answer a command"""
        if self.raise_on and self.raise_on in argv:
            raise OSError("no %s" % self.raise_on)
        if "is-active" in argv:
            out = self.state
        elif "list-sessions" in argv:
            out = "4 1000 ubuntu seat0 tty1\n5 0 root - pts/0\n"
        else:
            out = self.show
        return type("R", (), {"stdout": out, "returncode": 0})()


def logind_reads(ns):
    """run read_sessions against logind states and a fixture user.slice"""
    fails = []
    with tempfile.TemporaryDirectory() as d:
        empty = os.path.join(d, "empty")
        os.makedirs(os.path.join(empty, "user-1000.slice", "session-4.scope"))
        open(os.path.join(empty, "user-1000.slice", "session-4.scope", "cgroup.procs"), "w").close()
        live = os.path.join(d, "live")
        os.makedirs(os.path.join(live, "user-1000.slice", "session-4.scope"))
        with open(os.path.join(live, "user-1000.slice", "session-4.scope", "cgroup.procs"), "w") as f:
            f.write("1062\n")
        got = ns["read_sessions"](_Logind("active\n"), empty)
        if [s.get("Id") for s in (got or [])] != ["4", "5", "6", "c1", "7", "8", "9", "10"]:
            fails.append("read_sessions with logind active read %s" % got)
        for state in ("inactive\n", "activating\n"):
            if ns["read_sessions"](_Logind(state), empty) != []:
                fails.append("read_sessions with logind %s and no session scope holding a process did not "
                             "read as no sessions" % state.strip())
        for state, raise_on in (("inactive\n", None), ("failed\n", None), ("deactivating\n", None),
                                ("", None), ("active\n", "is-active")):
            if ns["read_sessions"](_Logind(state, raise_on=raise_on), live) is not None:
                fails.append("read_sessions with logind %r and a session scope holding a process read as "
                             "sessions known" % (state.strip() or "unreadable"))
        if ns["read_sessions"](_Logind("active\n", raise_on="show-session"), live) is not None:
            fails.append("read_sessions read a failed loginctl show-session as known")
    return fails


def guard_wiring(launcher_text):
    """check acquire_host_global_phase refuses before it hands back the lock"""
    tree = ast.parse(launcher_text)
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef)
               and n.name == "acquire_host_global_phase"), None)
    if fn is None:
        return ["boot.py has no acquire_host_global_phase"]
    loaded = next((i for i, s in enumerate(fn.body) if isinstance(s, ast.If)
                   and "policy_is_loaded" in ast.unparse(s.test)), None)
    ret = next((i for i, s in reversed(list(enumerate(fn.body))) if isinstance(s, ast.Return)
                and ast.unparse(s.value) == "host_lock_fd"), None)
    ask = next((i for i, s in enumerate(fn.body)
                if "check_policy_load()" in ast.unparse(s)), None)
    refuse = next((s for s in fn.body if isinstance(s, ast.If)
                   and "sys.exit" in ast.unparse(s) and "release_host_lock" in ast.unparse(s)), None)
    fails = []
    if None in (loaded, ret):
        return ["acquire_host_global_phase lost its policy_is_loaded() branch or its return host_lock_fd"]
    if ask is None or not loaded < ask < ret:
        fails.append("acquire_host_global_phase does not ask check_policy_load() between its "
                     "policy_is_loaded() branch and handing the first actor the lock")
    if refuse is None:
        fails.append("acquire_host_global_phase has no refusal branch that releases the host lock and exits")
    elif "write_policy_refusal" not in ast.unparse(refuse):
        fails.append("the refusal branch does not write the refusal record rhizo status reads")
    return fails


def rig_and_product(redeploy_text, product_texts):
    """check only the rig's launch env sets the override"""
    fails = []
    if ('LAUNCH_ENV+="%s=${%s:-1} "' % (OVERRIDE, OVERRIDE)) not in redeploy_text:
        fails.append("redeploy.sh does not put %s=${%s:-1} in the launch env" % (OVERRIDE, OVERRIDE))
    if not re.search(r"for u in androidd\.service androidd@\.service; do\n.*\n\s*printf \"\[Service\]\\nEnvironment=%s=1\\n\" "
                     r"> /etc/systemd/system/\$u\.d/" % OVERRIDE, redeploy_text):
        fails.append("redeploy.sh does not install %s=1 as a drop-in on androidd.service and androidd@.service"
                     % OVERRIDE)
    for path, text in product_texts:
        if OVERRIDE in text:
            fails.append("%s names %s"
                         % (os.path.relpath(path, ROOT), OVERRIDE))
    return fails


REFUSAL = "session 4 of ubuntu started first -- reboot"
START_STUBS = """
log() { :; }
app_fail() { echo "RHIZO_FAIL $*"; exit 1; }
require_probe_client() { :; }
refuse_start_without_setup() { :; }
refuse_start_without_mode() { :; }
instance_unit() { echo androidd.service; }
selinux_mode_is() { [[ "$MODE" == "$1" ]]; }
sandbox_init_pid() { :; }
start_verdict() { :; }
selinuxns_verdict() { :; }
start_verdict_ok() { return 1; }
android_sh() { :; }
sleep() { :; }
systemctl() {
  case $1 in
    start) [[ "$START" == ok ]] ;;
    is-active) echo "$STATE" ;;
  esac
}
"""


def cli_reads(cli_text):
    """run rhizo status and rhizo start's failures on a refusal"""
    funcs = []
    for name in ("policy_refusal_reason", "policy_refusal_note", "policy_status_line", "start_sandbox"):
        m = re.search(r"^%s\(\) \{[^\n]*\n.*?^\}\n" % name, cli_text, re.M | re.S)
        if not m:
            return ["rhizo.sh has no %s()" % name]
        funcs.append(m.group(0))
    fails = []
    with tempfile.TemporaryDirectory() as d:
        rec = os.path.join(d, "refused")
        with open(rec, "w") as f:
            f.write("refused_by=launcher\nreason=%s\n" % REFUSAL)

        def run(call, record, mode="host", start="fail", state="failed"):
            """run a CLI path on a fixture record"""
            script = (START_STUBS + "".join(funcs) + 'POLICY_REFUSED_FILE="$1"\nRHIZO_SANDBOX_ID=0\n'
                      'PROBE_SOCK=/run/x\nrhizo_policy_loaded() { return 1; }\n' + call + "\n")
            env = dict(os.environ, MODE=mode, START=start, STATE=state)
            return subprocess.run(["bash", "-c", script, "_", record], capture_output=True, text=True, env=env,
                                  timeout=60).stdout
        absent = os.path.join(d, "absent")
        if REFUSAL not in run("policy_status_line", rec):
            fails.append("rhizo status's policy_status_line() never reads the refusal record: %r"
                         % run("policy_status_line", rec))
        if REFUSAL in run("policy_status_line", absent):
            fails.append("rhizo status reported a refusal with no record")
        for mode in ("host", "namespace"):
            for what, start, state in (("a failed systemctl start", "fail", "failed"),
                                       ("a start that died before init", "ok", "failed")):
                out = run("start_sandbox", rec, mode, start, state)
                if not out.startswith("RHIZO_FAIL") or REFUSAL not in out:
                    fails.append("rhizo start's %s in %s mode does not name the refusal: %r" % (what, mode, out))
                out = run("start_sandbox", absent, mode, start, state)
                if "refused on this boot" in out:
                    fails.append("rhizo start's %s named a refusal with no record: %r" % (what, out))
    return fails


def check(selinux_text, launcher_text, redeploy_text, cli_text, product_texts):
    """check the refusal end to end"""
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as tf:
        tf.write(selinux_text)
    try:
        ns = lift(tf.name, set(LIFTED) | set(CONSTANTS))
    finally:
        os.unlink(tf.name)
    missing = [n for n in LIFTED + CONSTANTS if n not in ns]
    if missing:
        return ["sandbox/selinux_labels.py no longer defines %s" % ", ".join(missing)]
    fails = []
    sessions = ns["parse_sessions"](SHOW)
    if [s.get("Id") for s in sessions] != ["4", "5", "6", "c1", "7", "8", "9", "10"] or sessions[0].get("Seat") != "seat0":
        fails.append("parse_sessions read %s" % sessions)
    for text, want in (("Id=1\nName=a\nId=2\nName=b\n", [("1", "a"), ("2", "b")]),
                       ("Name=a\nId=1\n\nName=b\nId=2\n", [("1", "a"), ("2", "b")])):
        recs = [(r.get("Id"), r.get("Name")) for r in ns["parse_sessions"](text)]
        if recs != want:
            fails.append("parse_sessions split %r into %s, want %s" % (text, recs, want))
    got = [s.get("Id") for s in ns["login_sessions"](sessions)]
    if got != LOGINS:
        fails.append("login_sessions chose %s, want %s (seat, tty, ssh with and without a pty, greeter, a "
                     "run0 user-light class; linger manager and background pty session left out)" % (got, LOGINS))
    for text, want in (("systemd 255 (255.4-1ubuntu8.16)\n+PAM +AUDIT\n", 255),
                       ("systemd 249 (249.11-0ubuntu3)\n", 249), ("", 0), ("bash: systemctl: not found\n", 0)):
        if ns["systemd_version"](text) != want:
            fails.append("systemd_version read %r as %r, want %r" % (text, ns["systemd_version"](text), want))
    fails += logind_reads(ns)
    refusal = ns["policy_load_refusal"]
    why = refusal(sessions, 255, ["user@1000.service"], False)
    if not why or "session 4 of ubuntu" not in why or "reboot" not in why:
        fails.append("a tty1/wayland login predating the load was not refused by name with a reboot: %r" % why)
    if refusal(sessions, 255, ["user@1000.service"], True) is not None:
        fails.append("the rig override did not let the load go ahead")
    ssh_only = [s for s in sessions if s.get("Id") in ("5", "7", "8")]
    why = refusal(ssh_only, 255, ["user@0.service", "user@1001.service"], False)
    if not why or "session 5 of root" not in why or "reboot" not in why:
        fails.append("an ssh login predating the load was not refused by name with a reboot: %r" % why)
    if refusal(ssh_only, 255, ["user@0.service", "user@1001.service"], True) is not None:
        fails.append("the rig override did not let the load go ahead under an ssh login")
    no_login = [s for s in sessions if s.get("Id") in ("7", "8")]
    if refusal(no_login, 255, ["user@1001.service"], False) is not None:
        fails.append("a linger manager and a background pty session refused the load")
    try:
        unreadable = refusal(None, 255, [], False)
    except (TypeError, AttributeError) as e:
        unreadable = None
        fails.append("unreadable login sessions raised %r instead of refusing" % e)
    if not unreadable:
        fails.append("unreadable login sessions let the load go ahead")
    old = refusal(no_login, 249, ["user@1001.service"], True)
    if not old or "249" not in old or "250" not in old:
        fails.append("a user manager on systemd 249 did not refuse the load: %r" % old)
    if refusal(no_login, 249, [], False) is not None:
        fails.append("systemd 249 with no user manager refused the load")
    fails += guard_wiring(launcher_text)
    fails += rig_and_product(redeploy_text, product_texts)
    fails += cli_reads(cli_text)
    return fails


def product_files():
    """return (path, text) for every tracked product file"""
    names = subprocess.run(["git", "-C", ROOT, "ls-files", "--"] + [os.path.relpath(d, ROOT) for d in PRODUCT_DIRS],
                           capture_output=True, text=True, check=True).stdout.split()
    out = []
    for rel in names:
        p = os.path.join(ROOT, rel)
        try:
            with open(p, encoding="utf-8") as fh:
                out.append((p, fh.read()))
        except (UnicodeDecodeError, OSError):
            pass
    return out


def real_inputs():
    """return the real files the check reads"""
    texts = []
    for p in (SELINUX, LAUNCHER, REDEPLOY, CLI):
        with open(p, encoding="utf-8") as fh:
            texts.append(fh.read())
    return texts + [product_files()]


def selftest():
    """plant defects in the real files and require each to be flagged"""
    fail = 0
    real = real_inputs()
    got = check(*real)
    if got:
        print("SELFTEST FAILED: the real tree was flagged: %s" % got)
        fail = 1
    cases = [
        (0, "ssh logins left out", "if s.get(\"Class\") not in EXEMPT_CLASSES]",
         "if s.get(\"Class\") not in EXEMPT_CLASSES and s.get(\"Remote\") != \"yes\"]", "an ssh login predating"),
        (0, "the override ignored", "    if not rig:\n", "    if True:\n", "the rig override"),
        (0, "unreadable sessions accepted", "        if sessions is None:\n", "        if False:\n",
         "unreadable login sessions"),
        (0, "the systemd version gate dropped", "if managers and version < REEXEC_SYSTEMD:",
         "if False:", "systemd 249 did not refuse"),
        (0, "records not split at a blank line", "        if not sep:\n            cur = None\n",
         "        if not sep:\n            pass\n", "parse_sessions split"),
        (0, "a background session counted", 'EXEMPT_CLASSES = ("background", ',
         'EXEMPT_CLASSES = ("nothing", ', "login_sessions chose"),
        (0, "an unknown class let through", 'if s.get("Class") not in EXEMPT_CLASSES]',
         'if s.get("Class") in ("user", "greeter")]', "login_sessions chose"),
        (0, "logind not active read as no sessions", "        return None if session_scopes(cg_root) else []\n",
         "        return []\n", "read as sessions known"),
        (1, "the guard not asked", "    refusal = check_policy_load()\n", "    refusal = None\n",
         "does not ask check_policy_load()"),
        (1, "the refusal not recorded", "        write_policy_refusal(refusal)\n", "        pass\n",
         "does not write the refusal record"),
        (2, "the rig override not set", 'LAUNCH_ENV+="%s=${%s:-1} "' % (OVERRIDE, OVERRIDE), "",
         "does not put"),
        (2, "the rig drop-in not installed", "Environment=RHIZO_RIG_LOAD_UNDER_LOGIN=1", "Environment=X=1",
         "as a drop-in"),
        (3, "rhizo status blind to the refusal", "  refused=$(policy_refusal_reason)\n", "  refused=\n",
         "never reads the refusal record"),
        (3, "rhizo start's failed systemctl start silent on the refusal",
         '|| app_fail "$(policy_refusal_note "$unit")systemctl start', '|| app_fail "systemctl start',
         "a failed systemctl start in host mode does not name the refusal"),
        (3, "a dead start silent on the refusal", '&& app_fail "$(policy_refusal_note "$unit")$unit went',
         '&& app_fail "$unit went', "a start that died before init in namespace mode does not name"),
        (3, "the unit-form note dropping the refusal",
         '  [[ -n "$why" ]] && printf "Android\'s policy was refused on this boot: %s. " "$why"',
         '  [[ -n "$why" && -z "${1:-}" ]] && printf "Android\'s policy was refused on this boot: %s. " "$why"',
         "does not name the refusal"),
    ]
    for idx, name, old, new, needle in cases:
        if old not in real[idx]:
            print("SELFTEST FAILED: %s: the planted defect no longer matches its source -- %r is gone"
                  % (name, old[:60]))
            fail = 1
            continue
        planted = list(real)
        planted[idx] = real[idx].replace(old, new, 1)
        problems = check(*planted)
        if not any(needle in p for p in problems):
            print("SELFTEST FAILED: %s was not flagged with %r (got %s)" % (name, needle, problems))
            fail = 1
    product = list(real)
    product[4] = real[4] + [(os.path.join(ROOT, "debian", "androidd.env"), "%s=1\n" % OVERRIDE)]
    if not any("names %s" % OVERRIDE in p for p in check(*product)):
        print("SELFTEST FAILED: a shipped file setting the override was not flagged")
        fail = 1
    print("login-refusal.py selftest: %s (%d planted defects)" % ("FAILED" if fail else "ok", len(cases) + 1))
    return fail


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: login-refusal.py [--selftest]", file=sys.stderr)
        return 2
    fails = check(*real_inputs())
    for f in fails:
        print("login-refusal: " + f, file=sys.stderr)
    if fails:
        return 1
    print("login-refusal: a login session that predates the load, at the machine or over ssh, refuses it "
          "by name with a reboot, linger managers and background sessions do not, unreadable sessions and "
          "an old systemd refuse, only redeploy.sh's launch env overrides it, and rhizo status and rhizo "
          "start name the refusal")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
