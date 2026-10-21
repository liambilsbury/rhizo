#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCH = os.path.join(REPO, "src", "androidd", "host", "launch-app.sh")
GUEST = os.path.join(REPO, "src", "androidd", "guest", "bin", "launch-app.sh")
BACKEND = os.path.join(REPO, "src", "android", "hal", "graphics-composer", "src", "wayland", "wayland_backend.cpp")
COMPOSER = os.path.join(REPO, "src", "android", "hal", "graphics-composer", "src", "composer.cpp")
TOKEN = "gnome-shell/rhizo-com.x.desktop/2301-2-host_TIME4051"


def function_body(src, name):
    """return the text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}\n" % re.escape(name), src, re.M | re.S)
    return m.group(0) if m else None


def run_token_fn(body, token):
    """return activation_token_arg output and log lines"""
    with tempfile.TemporaryDirectory() as tmp:
        script = 'set -eu\nPKG=com.x\nLOG="%s/log"\n: > "$LOG"\n' % tmp + body + "activation_token_arg\n"
        env = dict(os.environ)
        env.pop("XDG_ACTIVATION_TOKEN", None)
        if token is not None:
            env["XDG_ACTIVATION_TOKEN"] = token
        r = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
        if r.returncode != 0:
            return None, ["sh exited %d: %s" % (r.returncode, r.stderr.strip())]
        return r.stdout, open(f"{tmp}/log").read().splitlines()


def check_launch(src, guest):
    """check the activation token handling"""
    bad = []
    body = function_body(src, "activation_token_arg")
    if body is None:
        return ["rhizo-launch.sh has no activation_token_arg()"]
    if not re.search(r"^activation_arg=\$\(activation_token_arg\)$", src, re.M):
        bad.append("rhizo-launch.sh never takes activation_arg from activation_token_arg")
    if not re.search(r"rhizo-launch-app\.sh [^\n]*'\$on_top_deadline' '\$activation_arg'[ \"]", src):
        bad.append("the dispatch does not pass activation_arg as the guest script's 15th argument")
    out, log = run_token_fn(body, TOKEN)
    if out != TOKEN:
        bad.append("a valid token came back as %r" % (out,))
    out, log = run_token_fn(body, None)
    if out != "":
        bad.append("no token came back as %r, want nothing" % (out,))
    for badtok in ("a b", "x;reboot", "a'b", "t" * 256):
        out, log = run_token_fn(body, badtok)
        if out != "" or not any("not sent" in line for line in log or []):
            bad.append("token %r was passed on (%r) or not logged as not sent (%r)" % (badtok[:20], out, log))
    if not re.search(r'^ACTIVATION_TOKEN="\$\{15\}"$', guest, re.M):
        bad.append("the guest script does not read its 15th argument as ACTIVATION_TOKEN")
    am = guest.find('echo "stage=am-start t=$t9 rc=$rc"')
    send = re.search(r'if \[ -n "\$ACTIVATION_TOKEN" \] && \[ -n "\$cid" \]; then\s*echo display activate "\$cid" "\$ACTIVATION_TOKEN" > "\$CTL"', guest)
    if am < 0 or not send or send.start() < am:
        bad.append("the guest script does not send display activate for its own composer display, and only when it has one, after am start")
    if re.search(r'display activate "\$\{cid:-\$logid\}"', guest):
        bad.append("the guest script can send an Android logical id as the composer display to activate")
    return bad


def check_composer(backend, composer):
    """return the problems in the backend and composer activation handling"""
    bad = []
    if not re.search(r"bool bufferCommitted = false;", backend) or \
            not re.search(r"std::string heldActivationToken;", backend):
        bad.append("DisplayState carries no bufferCommitted/heldActivationToken")
    act = re.search(r"bool WaylandBackend::ActivateDisplay\(.*?\n\}\n", backend, re.S)
    if not act:
        return bad + ["no WaylandBackend::ActivateDisplay definition"]
    a = act.group(0)
    hold = re.search(r"if \(!token\.empty\(\) && !ds->bufferCommitted\) \{[^}]*"
                     r"ds->heldActivationToken = token;[^}]*return true;", a, re.S)
    first_activate = a.find("xdg_activation_v1_activate(")
    if not hold or (first_activate >= 0 and hold.start() > first_activate):
        bad.append("ActivateDisplay does not hold a given token for an unmapped display before activating")
    pres = re.search(r"bool WaylandBackend::PresentFrame\(int64_t displayId, const WaylandFrame& frame\) \{.*?\n\}\n",
                     backend, re.S)
    p = pres.group(0) if pres else ""
    commit = p.rfind("wl_surface_commit(ds.surface);")
    apply_ = re.search(r"if \(!ds\.bufferCommitted\) \{\s*ds\.bufferCommitted = true;.*?"
                       r"xdg_activation_v1_activate\(impl->activationManager, ds\.heldActivationToken\.c_str\(\), ds\.surface\);"
                       r".*?ds\.heldActivationToken\.clear\(\);", p, re.S)
    if commit < 0 or not apply_ or apply_.start() < commit:
        bad.append("PresentFrame does not activate with the held token after its first buffer commit")
    if '"display activate-held id="' not in composer:
        bad.append("the composer's display activate reply does not say when a token was held")
    return bad


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def run():
    """run the launch and composer checks and print the failures"""
    bad = check_launch(read(LAUNCH), read(GUEST)) + check_composer(read(BACKEND), read(COMPOSER))
    for b in bad:
        print("FAIL: %s" % b)
    return 1 if bad else 0


def selftest():
    """check the real sources and each planted-defect copy of them"""
    bad = []
    launch, guest, backend, composer = read(LAUNCH), read(GUEST), read(BACKEND), read(COMPOSER)
    real = check_launch(launch, guest) + check_composer(backend, composer)
    if real:
        bad.append("the real sources fail: %r" % real)
    mutations = [
        ("launch: the argument left off the dispatch", lambda s: check_launch(s, guest),
         lambda s: s.replace(" '$activation_arg'", "", 1), launch),
        ("launch: the grammar case dropped", lambda s: check_launch(s, guest),
         lambda s: s.replace("*[!A-Za-z0-9_.:/+=@-]*)", "*[!A-Za-z0-9_.:/+=@\\ \\;\\'-]*)", 1), launch),
        ("launch: the length bound dropped", lambda s: check_launch(s, guest),
         lambda s: s.replace("-gt 255 ]", "-gt 999 ]", 1), launch),
        ("guest: the send dropped", lambda s: check_launch(launch, s),
         lambda s: s.replace('echo display activate "$cid" "$ACTIVATION_TOKEN" > "$CTL"', ":", 1), guest),
        ("guest: the guard on a composer id dropped", lambda s: check_launch(launch, s),
         lambda s: s.replace(' && [ -n "$cid" ]; then\n  echo display activate', '; then\n  echo display activate', 1), guest),
        ("composer: the hold dropped", lambda b: check_composer(b, composer),
         lambda s: s.replace("ds->heldActivationToken = token;", "", 1), backend),
        ("composer: the apply dropped", lambda b: check_composer(b, composer),
         lambda s: s.replace("ds.heldActivationToken.clear();", "", 1), backend),
    ]
    for name, fn, mutate, src in mutations:
        mutated = mutate(src)
        if mutated == src:
            bad.append("%s: the mutation did not apply" % name)
        elif not fn(mutated):
            bad.append("%s: passes the check" % name)
    for b in bad:
        print("SELFTEST FAIL: %s" % b)
    if not bad:
        print("check-launch-activation --selftest: each mutation of the launch, guest or composer side is caught")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else run())
