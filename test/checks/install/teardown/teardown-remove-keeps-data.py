#!/usr/bin/env python3
import argparse
import fnmatch
import importlib.util
import os
import re
import shlex
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402
sys.path.insert(0, os.path.join(TOOLS, "..", "..", "lib"))
from unit_files import unit_files  # noqa: E402
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(TOOLS))))

LIB = "src/install/teardown/teardown-lib.sh"
TEARDOWN = "src/install/teardown/teardown.sh"
POSTRM_TEMPLATE = "debian/rhizo.postrm.in"
EMBEDDER = "debian/embed-teardown.py"
BOOTSTRAP = "src/install/bootstrap/bootstrap.sh"
BOOTSTRAP_LIBS = ("src/install/lib/host-flavor.sh", "src/install/bootstrap/bootloader.sh")

FORBIDDEN_BARE_ROOTS = ("/var/lib/rhizo", "/usr/lib/rhizo", "/etc/rhizo", "/srv/rhizo")
PURGE_FORBIDDEN_BARE_ROOTS = ("/var/lib/rhizo", "/usr/lib/rhizo", "/srv/rhizo")

ROOT_STATE = (
    "/root/.rhizo_init_pid", "/root/.rhizo_init_pid-*",
    "/root/.rhizo_cgroup_root", "/root/.rhizo_cgroup_root-*",
    "/root/.rhizo_cgroup_invocation", "/root/.rhizo_cgroup_invocation-*",
    "/run/rhizo-vbmeta-loop", "/run/rhizo-vbmeta-loop-*",
    "/run/udev/rhizo-input-*.sock",
    "/root/.rhizo_vbmeta_loop", "/root/.rhizo_vbmeta_loop-*",
    "/root/.rhizo_prepare_resume", "/root/.rhizo_prepare_resume-*",
    "/root/.rhizo_g_pid", "/root/.rhizo_supervisor_state", "/root/.rhizo_handoff.d",
    "/root/.rhizo_cache",
)
NONPURGE_ALLOWED = frozenset({
    "/var/lib/rhizo/prepared",
    "/var/lib/rhizo/templates",
    "/var/lib/rhizo/derived",
    "/var/lib/rhizo/.prepared",
    "/var/cache/rhizo",
    "/var/log/rhizo",
    "/usr/lib/rhizo/tools/app-events.py",
    "/etc/udev/rules.d/59-rhizo-loop-unbound.rules",
    "/etc/rhizo/desktop-user",
    "/etc/rhizo/install-failed",
    "/var/lib/rhizo/vendor", "/var/lib/rhizo/apex_override",
    "/var/lib/rhizo/instances/*/vendor", "/var/lib/rhizo/instances/*/apex_override",
    "/rhizoroot", "/mnt/rhizo-template-build", "/var/cache/rhizo-appsync",
}) | frozenset(ROOT_STATE)
PURGE_EXTRA = frozenset({
    "/var/lib/rhizo/data.img",
    "/var/lib/rhizo/data.img.meta",
    "/var/lib/rhizo/update",
    "/etc/rhizo",
    "/srv/rhizo/gsi_system*",
    "/var/lib/rhizo/instances",
    "/var/lib/rhizo/device-state", "/var/lib/rhizo/device-state-*",
    "/var/lib/rhizo/pool-members", "/var/lib/rhizo/pool-pending", "/var/lib/rhizo/pool.lock",
    "/var/lib/rhizo/captures",
    "/var/lib/rhizo/.upgrade-from", "/var/lib/rhizo/.created-by-install",
    "/var/lib/rhizo/rhizo-host-teardown.sh", "/var/lib/rhizo/rhizo-teardown-lib.sh",
})
CONF_TOKENS = ["/etc/modules-load.d/rhizo.conf"]
RHIZO_DESKTOP_USER = "/etc/rhizo/desktop-user"
RHIZO_INSTALL_FAILED = "/etc/rhizo/install-failed"
CONTEXT = "u:object_r:rhizo_host_exec:s0"
TEST_ATTR = "user.rhizo_selftest"


def run_bash(script, env=None, timeout=60):
    """run a script in bash"""
    e = dict(os.environ)
    e.pop("RHIZO_DATA_IMG", None)
    e.update(env or {})
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          timeout=timeout, env=e)


def read(root, rel):
    """return the text of a file under the root"""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def closes_on_line(line):
    """check a line for balanced braces"""
    depth, last, quote, esc = 0, "", None, False
    for i, c in enumerate(line):
        if esc:
            esc = False
        elif c == "\\" and quote != "'":
            esc = True
        elif quote:
            quote = None if c == quote else quote
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        elif c in "{}":
            depth += 1 if c == "{" else -1
            last = c
    return depth == 0 and last == "}"


def function_text(text, name):
    """return the text of a shell function"""
    m = re.search(r"^%s\(\) \{" % re.escape(name), text, re.M)
    if not m:
        return None
    end = text.find("\n", m.start())
    line = text[m.start():] if end < 0 else text[m.start():end]
    if closes_on_line(line):
        return line
    close = re.compile(r"^\}$", re.M).search(text, m.end())
    return text[m.start():close.end()] if close else None


def deferred_paths(helper_path, purge):
    """return the DEFERRED array"""
    r = run_bash('set -uo pipefail\nsource %s\nteardown_deferred_paths %d\nprintf "%%s\\n" "${DEFERRED[@]}"\n'
                 % (shlex.quote(helper_path), purge))
    if r.returncode != 0:
        return None, ("sourcing %s and calling teardown_deferred_paths %d failed (rc=%d): %s"
                      % (helper_path, purge, r.returncode, r.stderr.strip()))
    return [l for l in r.stdout.split("\n") if l], None


def check_purge_value(helper_path, purge):
    """return the problems when a purge value defers a forbidden path"""
    deferred, err = deferred_paths(helper_path, purge)
    if err:
        return ["purge=%d: %s" % (purge, err)]
    fails = []
    want = NONPURGE_ALLOWED | (PURGE_EXTRA if purge else frozenset())
    bare = PURGE_FORBIDDEN_BARE_ROOTS if purge else FORBIDDEN_BARE_ROOTS
    for p in deferred:
        if p in bare:
            fails.append("purge=%d: DEFERRED names the bare root %s -- the post-reboot rm -rf would "
                         "delete far more than this run made%s; got DEFERRED=%s"
                         % (purge, p, "" if purge else ", including data.img via its own parent", deferred))
        elif p not in want:
            fails.append("purge=%d: DEFERRED names %s, which is not an allowed deferred path for "
                         "purge=%d; got DEFERRED=%s" % (purge, p, purge, deferred))
    missing = want - set(deferred)
    if missing:
        fails.append("purge=%d: DEFERRED is missing expected path(s) %s; got DEFERRED=%s"
                     % (purge, sorted(missing), deferred))
    return fails


OS_RELEASE = {"ubuntu": 'ID=ubuntu\nVERSION_ID="24.04"\n', "cachyos": "ID=cachyos\n", "arch": "ID=arch\n"}


REGEN_COMMANDS = ("usr/sbin/update-grub", "usr/bin/grub-mkconfig", "usr/bin/limine-update", "usr/bin/sdboot-manage")


def sourcing(helper_path, flavor, tmp):
    """build the library source lines"""
    osr = os.path.join(tmp, "os-release-" + flavor)
    with open(osr, "w") as fh:
        fh.write(OS_RELEASE[flavor])
    root = os.path.join(tmp, "root")
    for rel in REGEN_COMMANDS:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
                fh.write("#!/bin/sh\nexit 0\n")
            os.chmod(p, 0o755)
    return ("RHIZO_OS_RELEASE=%s\nRHIZO_BL_ROOT=%s\n" % (shlex.quote(osr), shlex.quote(root))
            + "".join("source %s\n" % shlex.quote(os.path.join(REPO, lib)) for lib in BOOTSTRAP_LIBS)
            + "source %s\n" % shlex.quote(helper_path))


def render_unit(helper_path, purge, labeled, extra="", flavor="ubuntu", path=None):
    """render the cleanup unit text"""
    with tempfile.TemporaryDirectory() as tmp:
        r = run_bash("set -uo pipefail\n%steardown_deferred_paths %d\nLABELED=(%s)\n%s\n"
                     "teardown_final_cleanup_unit %d\n"
                     % (sourcing(helper_path, flavor, tmp), purge, " ".join(shlex.quote(p) for p in labeled),
                        extra, purge), env={"PATH": path} if path else None)
    if r.returncode != 0:
        return None, "teardown_final_cleanup_unit %d failed (rc=%d): %s" % (purge, r.returncode, r.stderr.strip())
    return r.stdout, None


def exec_values(unit):
    """return the ExecStart= commands of a unit"""
    out = []
    for line in unit.split("\n"):
        if line.startswith("ExecStart="):
            out.append(line[len("ExecStart="):].lstrip("-"))
    return out


def stub_dir(tmp, names):
    """write stub executables for the given names"""
    d = os.path.join(tmp, "stubs")
    os.makedirs(d, exist_ok=True)
    for n in names:
        p = os.path.join(d, n)
        with open(p, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(p, 0o755)
    return d


def label_trial(helper_path, purge):
    """run the unit's label lines on fixture files"""
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        ours = [os.path.join(tmp, n) for n in ("bash", "ld.so", "python3.12")]
        stranger = os.path.join(tmp, "stranger")
        for p in ours + [stranger]:
            open(p, "w").close()
        try:
            for p in ours:
                os.setxattr(p, TEST_ATTR, (CONTEXT + "\0").encode())
            os.setxattr(stranger, TEST_ATTR, b"u:object_r:someone_else:s0\0")
        except OSError as e:
            return ["this check's own premise failed, not the teardown: %s refuses user.* xattrs (%s)" % (tmp, e)]
        unit, err = render_unit(helper_path, purge, ours + [stranger])
        if err:
            return [err]
        if "setfattr" in unit:
            fails.append("purge=%d: the cleanup unit runs setfattr, which the attr package provides and a "
                         "stock Ubuntu 24.04 does not install"
                         % purge)
        label_lines = [v for v in exec_values(unit) if "security.selinux" in v]
        if not label_lines:
            fails.append("purge=%d: the cleanup unit clears no label although LABELED names %d file(s)"
                         % (purge, len(ours) + 1))
        env_path = stub_dir(tmp, ("rm", "systemctl", "userdel", "groupdel", "update-grub")) + ":" + os.environ["PATH"]
        for v in label_lines:
            argv = shlex.split(v.replace("security.selinux", TEST_ATTR))
            try:
                subprocess.run(argv, capture_output=True, text=True, timeout=30, cwd=tmp,
                               env=dict(os.environ, PATH=env_path))
            except (OSError, subprocess.TimeoutExpired) as e:
                fails.append("purge=%d: the cleanup unit's label line could not run: %s" % (purge, e))
        for p in ours:
            if TEST_ATTR in os.listxattr(p):
                fails.append("purge=%d: a label left on %s after the cleanup unit's own label line ran"
                             % (purge, os.path.basename(p)))
        if TEST_ATTR not in os.listxattr(stranger):
            fails.append("purge=%d: the cleanup unit stripped a label that was not Rhizo's (%s)"
                         % (purge, os.path.basename(stranger)))
    return fails


ACCOUNTS = ("rhizo-appwatch", "rhizo-netbridged")
ALL_OPTIONAL = "REGEN_DEFERRED=(grub-dropin limine) SWAPFILE_DEFERRED=1 ACCOUNT_DEFERRED='%s'" % " ".join(ACCOUNTS)
USERDEL_RE = re.compile(r"\buserdel ([A-Za-z0-9_.-]+)")


def check_unit_accounts(helper_path):
    """check the userdel lines in the cleanup unit"""
    fails = []
    unit, err = render_unit(helper_path, 1, [], extra="ACCOUNT_DEFERRED='%s root'" % " ".join(ACCOUNTS))
    if err:
        return [err]
    named = [m.group(1) for v in exec_values(unit) for m in USERDEL_RE.finditer(v)]
    for acct in ACCOUNTS:
        if named.count(acct) != 1:
            fails.append("the cleanup unit names userdel %s %d time(s) for an ACCOUNT_DEFERRED naming it once" % (acct, named.count(acct)))
    for acct in sorted(set(named) - set(ACCOUNTS)):
        fails.append("the cleanup unit would delete an account no teardown ever creates: %s" % acct)
    return fails


def unit_words(value):
    """return every word of a unit command"""
    argv = shlex.split(value)
    words = list(argv)
    if argv[:2] == ["/bin/sh", "-c"] and len(argv) > 2:
        words += re.split(r"[\s;{}&|]+", argv[2])
    return argv, words


def check_unit(helper_path):
    """check the rendered cleanup unit"""
    fails = []
    for purge in (0, 1):
        deferred, err = deferred_paths(helper_path, purge)
        if err:
            fails.append("purge=%d: %s" % (purge, err))
            continue
        units = {}
        for flavor in ("ubuntu", "cachyos"):
            units[flavor], err = render_unit(helper_path, purge, ["/usr/bin/bash"], extra=ALL_OPTIONAL, flavor=flavor)
            if err:
                fails.append("purge=%d (%s): %s" % (purge, flavor, err))
        if None in units.values():
            continue
        unit = units["ubuntu"]
        forbidden = PURGE_FORBIDDEN_BARE_ROOTS if purge else FORBIDDEN_BARE_ROOTS
        for flavor, text in units.items():
            for v in exec_values(text):
                bad = sorted(set(c for c in v if c in "%$\\"))
                if bad:
                    fails.append("purge=%d (%s): an ExecStart line carries %s, which systemd rewrites before the "
                                 "command runs: %s" % (purge, flavor, " ".join(bad), v[:120]))
            for v in exec_values(text):
                argv, words = unit_words(v)
                if argv and argv[0] == "/bin/rmdir":
                    continue
                for root in forbidden:
                    if root in words and not v.startswith("/bin/sh -c 'rm -rf "):
                        fails.append("purge=%d (%s): the cleanup unit line %r names the bare root %s -- only "
                                     "rmdir may" % (purge, flavor, v[:80], root))
        rm_lines = [v for v in exec_values(unit) if v.startswith("/bin/sh -c 'rm -rf ")]
        if len(rm_lines) != 1:
            fails.append("purge=%d: the cleanup unit has %d `/bin/sh -c 'rm -rf ...'` lines, want exactly one"
                         % (purge, len(rm_lines)))
        else:
            tokens = shlex.split(rm_lines[0])[2].split()[2:]
            if sorted(tokens) != sorted(deferred + CONF_TOKENS):
                fails.append("purge=%d: the cleanup unit's rm -rf names %s, not exactly DEFERRED plus "
                             "%s" % (purge, tokens, CONF_TOKENS[0]))
            for root in (PURGE_FORBIDDEN_BARE_ROOTS if purge else FORBIDDEN_BARE_ROOTS):
                if root in tokens:
                    fails.append("purge=%d: the cleanup unit's rm -rf names the bare root %s directly" % (purge, root))
        fails.extend(label_trial(helper_path, purge))
    return fails


def check_scheduled_unit(helper_path, unit):
    """check a cleanup unit read from a host"""
    deferred, err = deferred_paths(helper_path, 0)
    if err:
        return ["scheduled unit: %s" % err]
    purge_only, _ = deferred_paths(helper_path, 1)
    purge_only = set(purge_only or ()) - set(deferred)
    values = [line.split("=", 1)[1].lstrip("-@+!:") for line in unit.split("\n")
              if re.match(r"Exec[A-Za-z]*=", line)]
    if not [line for line in unit.split("\n") if line.startswith("ExecStart=")]:
        return ["scheduled unit: no ExecStart= line -- nothing was read to judge"]
    fails = []
    rm_lines = [v for v in values if v.startswith("/bin/sh -c 'rm -rf ")]
    if len(rm_lines) != 1:
        fails.append("scheduled unit: %d `/bin/sh -c 'rm -rf ...'` lines, want exactly one" % len(rm_lines))
    else:
        tokens = shlex.split(rm_lines[0])[2].split()[2:]
        extra = sorted(set(tokens) - set(deferred + CONF_TOKENS))
        if extra:
            fails.append("scheduled unit: the rm -rf names %s, which teardown_deferred_paths 0 never allows a "
                         "plain remove to defer" % " ".join(extra))
    for v in values:
        argv, words = unit_words(v)
        if argv and argv[0] == "/bin/rmdir":
            fails.append("scheduled unit: an rmdir line (%s) -- only a purge removes Rhizo's state dirs" % v[:80])
        for w in words:
            if w in FORBIDDEN_BARE_ROOTS:
                fails.append("scheduled unit: a line names the bare root %s: %s" % (w, v[:80]))
            elif w in purge_only:
                fails.append("scheduled unit: a line names %s, which only a purge may remove: %s" % (w, v[:80]))
            elif "data.img" in w:
                fails.append("scheduled unit: a line names the user's data (%s): %s" % (w, v[:80]))
            elif w.startswith("/srv/rhizo"):
                fails.append("scheduled unit: a line names the fetched image (%s): %s" % (w, v[:80]))
            elif w.startswith("/etc/rhizo/") and w not in (RHIZO_DESKTOP_USER, RHIZO_INSTALL_FAILED):
                fails.append("scheduled unit: a line names configuration a remove keeps (%s): %s" % (w, v[:80]))
            elif any(w.startswith(r + "/") for r in FORBIDDEN_BARE_ROOTS) and w not in deferred:
                fails.append("scheduled unit: a line names %s under a Rhizo root, which is not a path "
                             "teardown_deferred_paths 0 allows: %s" % (w, v[:80]))
    return fails


def unit_file_text(path):
    """return the unit text between the sentinels"""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().rstrip("\n").split("\n")
    if not lines or lines[0] != "UNIT_PRESENT":
        return None, "scheduled unit: the read does not start with UNIT_PRESENT"
    if lines[-1] != "UNIT_END":
        return None, "scheduled unit: the read was cut short -- no UNIT_END after the unit"
    return "\n".join(lines[1:-1]), None


def labeled_trial(teardown_text):
    """run selinux_xattr_report on fixture files"""
    fn = function_text(teardown_text, "selinux_xattr_report")
    if fn is None:
        return ["src/install/teardown/teardown.sh defines no selinux_xattr_report"]
    with tempfile.TemporaryDirectory() as tmp:
        ours, clear, link = (os.path.join(tmp, n) for n in ("python3.12", "dash", "python3"))
        for p in (ours, clear):
            open(p, "w").close()
        os.symlink(ours, link)
        try:
            os.setxattr(ours, TEST_ATTR, (CONTEXT + "\0").encode())
        except OSError as e:
            return ["this check's own premise failed, not the teardown: %s refuses user.* xattrs (%s)" % (tmp, e)]
        r = run_bash("HOST_EXEC_CONTEXT=%s\nHOST_EXEC_PATHS=(%s %s)\n%s\nselinux_xattr_report labeled\n"
                     % (shlex.quote(CONTEXT), shlex.quote(link), shlex.quote(clear),
                        fn.replace("security.selinux", TEST_ATTR)))
        got = [l for l in r.stdout.split("\n") if l]
    if got != [os.path.realpath(ours)]:
        return ["selinux_xattr_report labeled printed %r for a labeled file behind a symlink and a clear one, "
                "want only the labeled file's real path" % got]
    return []


def load_embedder(root):
    """return the teardown embedder module loaded from the root"""
    spec = importlib.util.spec_from_file_location("embed_teardown", os.path.join(root, EMBEDDER))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def case_branch(text, word):
    """return the body of a case branch for a word"""
    m = re.search(r"^  %s\)\n(.*?)^    ;;$" % re.escape(word), text, re.M | re.S)
    return m.group(1) if m else ""


HOST_COPY_RE = re.compile(r"(/var/lib/rhizo|/usr/lib/rhizo)\S*rhizo-host-teardown\.sh")
BY_NAME_RE = re.compile(r"\b(deluser|userdel|delgroup|groupdel)\b[^\n]*\b(rhizo-netbridged|rhizo-appwatch)\b")


def check_postrm(postrm_text, sources, embedder):
    """check the postrm's embedded teardown"""
    fails = []
    code = "\n".join(l for l in postrm_text.split("\n") if not l.lstrip().startswith("#"))
    for m in HOST_COPY_RE.finditer(code):
        fails.append("the postrm runs a teardown copy from %s, which is gone at purge after a prior "
                     "remove+reboot and never made by an "
                     "install that stopped at unpacked" % m.group(0))
    lines = postrm_text.split("\n")
    try:
        b, e = lines.index(embedder.BEGIN), lines.index(embedder.END)
        block = "\n".join(lines[b:e + 1]) + "\n"
    except ValueError:
        block = None
    runner = function_text(postrm_text, "rhizo_run_teardown")
    if block is None or "rhizo_teardown_write()" not in block:
        fails.append("the postrm carries no embedded teardown between its two marker lines")
    if runner is None:
        fails.append("the postrm defines no rhizo_run_teardown")
    if "rhizo_run_teardown --purge" not in case_branch(postrm_text, "purge"):
        fails.append("the postrm's purge branch does not call rhizo_run_teardown --purge")
    remove = case_branch(postrm_text, "remove")
    if not re.search(r"^\s*rhizo_run_teardown(\s|$)(?!.*--purge)", remove, re.M):
        fails.append("the postrm's remove branch does not call rhizo_run_teardown (without --purge)")
    for m in BY_NAME_RE.finditer(code):
        fails.append("the postrm deletes %s by name (%r) -- "
                     "only the teardown, on the install record, may" % (m.group(2), m.group(0)[:80]))
    if block is None or runner is None:
        return fails
    with tempfile.TemporaryDirectory() as tmp:
        stubs = os.path.join(tmp, "stubs")
        got = os.path.join(tmp, "got")
        os.makedirs(stubs)
        os.makedirs(got)
        with open(os.path.join(stubs, "bash"), "w") as fh:
            fh.write('#!/bin/sh\ncp -r "$(dirname "$1")"/../../. "$GOT"/ && printf "%s\\n" "$@" > "$GOT.argv"\nexit 7\n')
        os.chmod(os.path.join(stubs, "bash"), 0o755)
        with open(os.path.join(tmp, "defs.sh"), "w") as fh:
            fh.write(block + runner + "\n")
        r = subprocess.run(["sh", "-c", '. "$1"; PROG=rhizo; rhizo_run_teardown --purge; echo "rc=$?"',
                            "_", os.path.join(tmp, "defs.sh")],
                           capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, PATH=stubs + ":" + os.environ["PATH"], GOT=got))
        if "rc=7" not in r.stdout:
            fails.append("rhizo_run_teardown did not return the teardown's own status (stub exited 7, got %r; "
                         "stderr %r)" % (r.stdout.strip(), r.stderr.strip()[:300]))
        try:
            with open(got + ".argv") as fh:
                argv = fh.read().split("\n")[:-1]
        except OSError:
            argv = []
        if len(argv) != 2 or os.path.basename(argv[0]) != "teardown.sh" or argv[1] != "--purge":
            fails.append("rhizo_run_teardown --purge ran bash with %r, not <dir>/teardown.sh --purge" % argv)
        for src, name, _ in embedder.SOURCES:
            p = os.path.join(got, name)
            if not os.path.exists(p):
                fails.append("the postrm's embedded teardown never wrote %s beside the script it ran" % name)
                continue
            with open(p, "rb") as fh:
                if fh.read() != sources[src]:
                    fails.append("the postrm's embedded %s is outdated: it differs from %s -- run "
                                 "debian/embed-teardown.py --write" % (name, src))
    return fails


ACCOUNT_STUBS = {
    "getent": '#!/bin/sh\ndb=$FX_PASSWD; [ "$1" = group ] && db=$FX_GROUP\n'
              'awk -F: -v k="$2" \'$1 == k || $3 == k { print; f = 1 } END { exit !f }\' "$db" || exit 2\n',
    "userdel": '#!/bin/sh\necho "userdel $*" >> "$FX_LOG"\n'
               'grep -v "^$1:" "$FX_PASSWD" > "$FX_PASSWD.n"; mv "$FX_PASSWD.n" "$FX_PASSWD"\n'
               'grep -v "^$1:" "$FX_GROUP" > "$FX_GROUP.n"; mv "$FX_GROUP.n" "$FX_GROUP"\n',
    "groupdel": '#!/bin/sh\necho "groupdel $*" >> "$FX_LOG"\n'
                'grep -v "^$1:" "$FX_GROUP" > "$FX_GROUP.n"; mv "$FX_GROUP.n" "$FX_GROUP"\n',
}
APPWATCH = "rhizo-appwatch:x:1000:1000::/nonexistent:/usr/sbin/nologin"
NETBRIDGED = "rhizo-netbridged:x:109:112::/nonexistent:/usr/sbin/nologin"
NETBRIDGED_GROUP = "rhizo-netbridged:x:112:"


def account_trial(helper_path, passwd, group, record, fn="teardown_remove_appwatch_account"):
    """run an account removal against stub tools"""
    with tempfile.TemporaryDirectory() as tmp:
        stubs = os.path.join(tmp, "stubs")
        os.makedirs(stubs)
        for name, body in ACCOUNT_STUBS.items():
            with open(os.path.join(stubs, name), "w") as fh:
                fh.write(body)
            os.chmod(os.path.join(stubs, name), 0o755)
        fx = {k: os.path.join(tmp, k) for k in ("passwd", "group", "record", "log")}
        for k, v in (("passwd", passwd), ("group", group)):
            with open(fx[k], "w") as fh:
                fh.write("".join(l + "\n" for l in v))
        if record is not None:
            with open(fx["record"], "w") as fh:
                fh.write("".join(l + "\n" for l in record))
        open(fx["log"], "w").close()
        run_bash("source %s\n%s %s\n"
                 % (shlex.quote(helper_path), fn, shlex.quote(fx["record"])),
                 env={"PATH": stubs + ":" + os.environ["PATH"], "FX_PASSWD": fx["passwd"],
                      "FX_GROUP": fx["group"], "FX_LOG": fx["log"]})
        with open(fx["log"]) as fh:
            calls = [l for l in fh.read().split("\n") if l]
        left = None
        if os.path.exists(fx["record"]):
            with open(fx["record"]) as fh:
                left = [l for l in fh.read().split("\n") if l]
        with open(fx["passwd"]) as fh:
            users = [l.split(":")[0] for l in fh.read().split("\n") if l]
    return calls, left, users


def check_accounts(helper_path):
    """return the problems in which accounts the teardown removes"""
    fails = []
    calls, left, users = account_trial(helper_path, [APPWATCH], ["rhizo-appwatch:x:1000:"],
                                       ["group:rhizo", "user:rhizo-appwatch", "group:rhizo-appwatch"])
    if "rhizo-appwatch" in users:
        fails.append("the appwatch user was left although the install record says this install created it "
                     "(calls: %s)" % (calls or "none"))
    elif left != ["group:rhizo"]:
        fails.append("the install record still names the removed account, or lost another token: %r" % left)
    for label, record in (("no install record at all", None),
                          ("a record naming only group rhizo", ["group:rhizo"])):
        calls, _, users = account_trial(helper_path, [APPWATCH], ["rhizo-appwatch:x:1000:"], record)
        if calls or "rhizo-appwatch" not in users:
            fails.append("the appwatch user was removed although this install did not create it (%s; calls: %s)"
                         % (label, calls))
    calls, _, users = account_trial(helper_path, ["tester:x:1000:1000::/home/tester:/bin/bash"],
                                    ["tester:x:1000:"], ["user:rhizo-appwatch"])
    if calls or "tester" not in users:
        fails.append("a person at uid 1000 was touched by the appwatch removal (calls: %s)" % calls)
    nb = "teardown_remove_netbridged_account"
    calls, left, users = account_trial(helper_path, [APPWATCH, NETBRIDGED], [NETBRIDGED_GROUP],
                                       ["user:rhizo-netbridged", "group:rhizo-netbridged", "group:rhizo"], fn=nb)
    if "rhizo-netbridged" in users:
        fails.append("the netbridged user was left although the install record says this install created it "
                     "(calls: %s)" % (calls or "none"))
    elif left != ["group:rhizo"] or "rhizo-appwatch" not in users:
        fails.append("the netbridged removal left its own tokens, or took another's: record %r, users %r" % (left, users))
    for label, record in (("no install record at all", None),
                          ("a record naming only the appwatch account", ["user:rhizo-appwatch"])):
        calls, _, users = account_trial(helper_path, [NETBRIDGED], [NETBRIDGED_GROUP], record, fn=nb)
        if calls or "rhizo-netbridged" not in users:
            fails.append("the netbridged user was removed although this install did not create it (%s; calls: %s)"
                         % (label, calls))
    return fails


POSTINST = "debian/rhizo.postinst"


def netbridged_create_block(postinst_text):
    """return the netbridged account creation block"""
    m = re.search(r"^    if ! getent passwd rhizo-netbridged .*?^    fi$", postinst_text, re.M | re.S)
    return m.group(0) if m else None


def create_trial(block, passwd, group, libs=()):
    """run the creation block on fixtures"""
    with tempfile.TemporaryDirectory() as tmp:
        stubs = os.path.join(tmp, "stubs")
        os.makedirs(stubs)
        create = ('#!/bin/sh\nfor a; do n=$a; done\n'
                  'echo "$n:x:109:112::/nonexistent:/usr/sbin/nologin" >> "$FX_PASSWD"\n'
                  'grep -q "^$n:" "$FX_GROUP" || echo "$n:x:112:" >> "$FX_GROUP"\n')
        for name, body in (("getent", ACCOUNT_STUBS["getent"]), ("adduser", create), ("useradd", create)):
            with open(os.path.join(stubs, name), "w") as fh:
                fh.write(body)
            os.chmod(os.path.join(stubs, name), 0o755)
        state = os.path.join(tmp, "state")
        os.makedirs(state)
        fx = {k: os.path.join(tmp, k) for k in ("passwd", "group")}
        for k, v in (("passwd", passwd), ("group", group)):
            with open(fx[k], "w") as fh:
                fh.write("".join(l + "\n" for l in v))
        script = "set -e\nPROG=rhizo\n%s%s\n" % ("".join(". %s\n" % shlex.quote(lib) for lib in libs),
                                                  block.replace("/var/lib/rhizo", state))
        r = subprocess.run(["sh", "-c", script],
                           capture_output=True, text=True, timeout=30,
                           env=dict(os.environ, PATH=stubs + ":" + os.environ["PATH"],
                                    FX_PASSWD=fx["passwd"], FX_GROUP=fx["group"]))
        if r.returncode != 0:
            return None, "postinst's rhizo-netbridged creation exited %d: %s" % (r.returncode, r.stderr.strip()[:300])
        try:
            with open(os.path.join(state, ".created-by-install")) as fh:
                return [l for l in fh.read().split("\n") if l], None
        except OSError:
            return [], None


def check_netbridged_create(postinst_text, libs=()):
    """check postinst records rhizo-netbridged user and group"""
    block = netbridged_create_block(postinst_text)
    if block is None:
        return ["debian/rhizo.postinst has no rhizo-netbridged creation this check can find"]
    fails = []
    for passwd, group, want, meaning in (
            ([], [], ["user:rhizo-netbridged", "group:rhizo-netbridged"],
             "postinst creates rhizo-netbridged and its group without recording them"),
            ([], [NETBRIDGED_GROUP], ["user:rhizo-netbridged"],
             "postinst records a rhizo-netbridged group that existed before it"),
            ([NETBRIDGED], [NETBRIDGED_GROUP], [],
             "postinst records a rhizo-netbridged account that existed before it")):
        got, err = create_trial(block, passwd, group, libs)
        if err:
            return [err]
        if got != want:
            fails.append("postinst: %s (record %r, want %r)" % (meaning, got, want))
    return fails


UNITS_LISTING = ("rhizo-netbridged.service loaded active running /usr/bin/python3 ...\n"
                 "rhizo-netbridged-3.service loaded active running /usr/bin/python3 ...\n"
                 "rhizo-netbridged-helper.service loaded inactive dead someone else's\n"
                 "androidd.service loaded active running Rhizo\n")


def check_netbridged_units(helper_path):
    """check the teardown's handling of the netbridged units"""
    with tempfile.TemporaryDirectory() as tmp:
        stubs = os.path.join(tmp, "stubs")
        os.makedirs(stubs)
        with open(os.path.join(stubs, "systemctl"), "w") as fh:
            fh.write("#!/bin/sh\n[ \"$1\" = list-units ] && printf '%%s' %s\n" % shlex.quote(UNITS_LISTING))
        os.chmod(os.path.join(stubs, "systemctl"), 0o755)
        r = run_bash("source %s\nteardown_netbridged_units\n" % shlex.quote(helper_path),
                     env={"PATH": stubs + ":" + os.environ["PATH"]})
    got = [l for l in r.stdout.split("\n") if l]
    want = ["rhizo-netbridged.service", "rhizo-netbridged-3.service"]
    if got != want:
        return ["teardown_netbridged_units named %r from a listing holding %r"
                % (got, want)]
    return []


PREINST = "debian/rhizo.preinst"


def adoption_block(preinst_text):
    """return the preinst's adoption block"""
    m = re.search(r"^    RECORD=/var/lib/rhizo/\.created-by-install\n.*?(?=^    META=)", preinst_text, re.M | re.S)
    return m.group(0) if m else None


def adoption_trial(block, old_version, passwd, group):
    """run the adoption block on fixtures"""
    with tempfile.TemporaryDirectory() as tmp:
        stubs = os.path.join(tmp, "stubs")
        os.makedirs(stubs)
        with open(os.path.join(stubs, "getent"), "w") as fh:
            fh.write(ACCOUNT_STUBS["getent"])
        os.chmod(os.path.join(stubs, "getent"), 0o755)
        state = os.path.join(tmp, "state")
        fx = {k: os.path.join(tmp, k) for k in ("passwd", "group")}
        for k, v in (("passwd", passwd), ("group", group)):
            with open(fx[k], "w") as fh:
                fh.write("".join(l + "\n" for l in v))
        body = block.replace("/var/lib/rhizo", state)
        args = "upgrade %s" % shlex.quote(old_version) if old_version else "install"
        r = subprocess.run(["sh", "-c", "set -e\nPROG=rhizo\nset -- %s\n%s\n" % (args, body)],
                           capture_output=True, text=True, timeout=30,
                           env=dict(os.environ, PATH=stubs + ":" + os.environ["PATH"],
                                    FX_PASSWD=fx["passwd"], FX_GROUP=fx["group"]))
        if r.returncode != 0:
            return None, "preinst's adoption job exited %d: %s" % (r.returncode, r.stderr.strip()[:300])
        try:
            with open(os.path.join(state, ".created-by-install")) as fh:
                return [l for l in fh.read().split("\n") if l], None
        except OSError:
            return [], None


def check_adoption(preinst_text):
    """check the preinst adoption of 0.1.0 accounts"""
    block = adoption_block(preinst_text)
    if block is None:
        return ["debian/rhizo.preinst has no adoption job for the account 0.1.0 created unrecorded"]
    fails = []
    group = ["rhizo-appwatch:x:1000:"]
    cases = (
        ("0.1.0", [APPWATCH], ["user:rhizo-appwatch", "group:rhizo-appwatch"],
         "the appwatch user 0.1.0 created is left unrecorded by an upgrade from 0.1.0"),
        ("0.1.0", ["rhizo-appwatch:x:1000:1000::/home/rhizo-appwatch:/bin/bash"], [],
         "an upgrade adopted a rhizo-appwatch in a shape 0.1.0 never made"),
        ("0.1.1", [APPWATCH], [],
         "an upgrade from a version that records adopted an unrecorded rhizo-appwatch"),
        (None, [APPWATCH], [],
         "a first install adopted an existing rhizo-appwatch"),
    )
    for old, passwd, want, meaning in cases:
        got, err = adoption_trial(block, old, passwd, group)
        if err:
            return [err]
        if got != want:
            fails.append("preinst: %s (from %s: record %r, want %r)" % (meaning, old or "nothing", got, want))
    nb_home = "rhizo-netbridged:x:109:112::/home/rhizo-netbridged:/bin/bash"
    nb_person = "rhizo-netbridged:x:1001:112::/nonexistent:/usr/sbin/nologin"
    for old, passwd, nb_group, want, meaning in (
            ("0.1.0", [NETBRIDGED], [NETBRIDGED_GROUP], ["user:rhizo-netbridged", "group:rhizo-netbridged"],
             "the rhizo-netbridged account 0.1.0 created is left unrecorded by an upgrade from 0.1.0"),
            ("0.1.0", [NETBRIDGED], ["rhizo-netbridged:x:200:"], ["user:rhizo-netbridged"],
             "an upgrade adopted a rhizo-netbridged group that is not the account's own"),
            ("0.1.0", [nb_home], [NETBRIDGED_GROUP], [],
             "an upgrade adopted a rhizo-netbridged in a shape 0.1.0 never made (a home and a shell)"),
            ("0.1.0", [nb_person], [NETBRIDGED_GROUP], [],
             "an upgrade adopted a rhizo-netbridged in a shape 0.1.0 never made (not a system uid)"),
            ("0.1.1", [NETBRIDGED], [NETBRIDGED_GROUP], ["user:rhizo-netbridged", "group:rhizo-netbridged"],
             "the rhizo-netbridged account 0.1.1 created is left unrecorded by an upgrade from 0.1.1"),
            ("0.1.2", [NETBRIDGED], [NETBRIDGED_GROUP], [],
             "an upgrade from a version that records adopted an unrecorded rhizo-netbridged"),
            (None, [NETBRIDGED], [NETBRIDGED_GROUP], [],
             "a first install adopted an existing rhizo-netbridged")):
        got, err = adoption_trial(block, old, passwd, nb_group)
        if err:
            return [err]
        if got != want:
            fails.append("preinst: %s (from %s: record %r, want %r)" % (meaning, old or "nothing", got, want))
    return fails


ROOT_LITERAL_RE = re.compile(r"(_instanced(?:_for)?\(\s*)?[\"']?(/root/\.rhizo_[A-Za-z0-9_.]*[A-Za-z0-9_])(-?)")


def root_state(helper_path):
    """return the root state paths the teardown library lists"""
    r = run_bash('source %s\nprintf "%%s\\n" "${RHIZO_TEARDOWN_LIB_ROOT_STATE[@]}"\n' % shlex.quote(helper_path))
    return [l for l in r.stdout.split("\n") if l]


def check_root_state(helper_path, product_texts):
    """check the /root state names in product files"""
    fails = []
    patterns = root_state(helper_path)
    if not patterns:
        return ["the lib defines no RHIZO_TEARDOWN_LIB_ROOT_STATE"]
    for name, text in sorted(product_texts.items()):
        for m in re.finditer(r"/root/\.rhizo_(?![A-Za-z0-9_])", text):
            fails.append("%s builds a /root/.rhizo_ name this check cannot read (%r) -- name it literally"
                         % (name, text[m.start():m.start() + 30].split("\n")[0]))
        for m in ROOT_LITERAL_RE.finditer(text):
            instanced, path, dash = bool(m.group(1)), m.group(2), m.group(3)
            wants = [path + "-1"] if dash else [path] + ([path + "-1"] if instanced else [])
            for w in wants:
                if not any(fnmatch.fnmatchcase(w, p) for p in patterns):
                    fails.append("%s names %s, which no teardown removes (not covered by "
                                 "RHIZO_TEARDOWN_LIB_ROOT_STATE)" % (name, w.replace("-1", "-<id>")))
    return sorted(set(fails))


TEARDOWN_CALLS = (
    ('teardown_deferred_paths "$PURGE"',
     "DEFERRED is not built by teardown_deferred_paths"),
    ('cleanup_unit_text=$(teardown_final_cleanup_unit "$PURGE")',
     "the cleanup unit is not the text this check renders and runs"),
    ('cat > /etc/systemd/system/rhizo-final-cleanup.service <<<"$cleanup_unit_text"',
     "the rendered cleanup unit is not what lands on disk"),
    ("mapfile -t LABELED < <(selinux_xattr_report labeled)",
     "the cleanup unit is never told which files still carry the label"),
    ('teardown_remove_appwatch_account "$INSTALL_RECORD"',
     "the uid-1000 account this install created is never removed"),
    ('teardown_remove_netbridged_account "$INSTALL_RECORD"',
     "the rhizo-netbridged account this install created is never removed"),
    ("done < <(teardown_netbridged_units)",
     "the network daemon still runs as rhizo-netbridged when userdel runs"),
    ("done < <(root_state_present)",
     "the /root/.rhizo_* state is never removed"),
    ('done < <(unit_enable_links "$( (( PURGE )) && echo all || echo foreign)")',
     "the enablement links `rhizo profile` made are never removed"),
    ("\nremove_cmdline_tokens\n",
     "step 1 never runs: rhizo's cmdline tokens stay in the bootloader's files"),
    ("  list_cmdline_tokens || cmdline_rc=$?\n",
     "--verify never reads the bootloader's files"),
    ('  if (( cmdline_rc == 2 )); then\n    failstop "verify-cannot-read"',
     "a --verify whose uid cannot read what the next boot reads concludes anyway, VERIFIED or not-clean"),
    ('  for kind in "${REGEN_DEFERRED[@]}"; do\n    regen_names+=", $(bootloader_regen_label "$kind")"\n',
     "the scheduled line never names the regenerations the next boot's cleanup runs"),
    ("${LABELED[*]}}$regen_names$(",
     "the scheduled line drops the regenerations it named"),
    ('  report_stranded_tokens apply "$detected" "$targets"\n',
     "a run never names rhizo's tokens left on a config nothing installed can regenerate"),
)


FLIP_RE = re.compile(r"(>\s*\S*/sys/fs/selinux/enforce|\btee\b[^\n|;]*/sys/fs/selinux/enforce"
                     r"|open\([^)\n]*selinux/enforce[^)\n]*['\"][wa]|\bsetenforce\b)")
ENFORCE_VAR_RE = re.compile(r"^\s*(?:readonly\s+|local\s+)?([A-Za-z_]\w*)=[\"']?/sys/fs/selinux/enforce[\"']?\s*$", re.M)
DEFERRED_WRITE_RE = re.compile(r"\bDEFERRED(\+?=|\[[^]\n]*\]\+?=)(?!\(\)\s*$)", re.M)


def code_only(text):
    """drop whole-line comments from the text"""
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def enforce_writes(body, var_names):
    """return the enforce node writes in the body"""
    found = [m.group(0).strip() for m in FLIP_RE.finditer(body)]
    for var in var_names:
        ref = r'"?\$\{?%s\}?"?' % re.escape(var)
        found += [m.group(0).strip() for m in re.finditer(r">\s*%s|\btee\b[^\n|;]*%s" % (ref, ref), body)]
    return found


def check_teardown_calls(text, lib_text=""):
    """find teardown calls missing from the teardown script"""
    fails = []
    code = code_only(text)
    for call, why in TEARDOWN_CALLS:
        if call not in code:
            fails.append("src/install/teardown/teardown.sh does not call %r -- %s" % (call, why))
    var_names = ENFORCE_VAR_RE.findall(code + "\n" + code_only(lib_text))
    for name, body in (("src/install/teardown/teardown.sh", code), ("src/install/teardown/teardown-lib.sh", code_only(lib_text))):
        for write in enforce_writes(body, var_names):
            fails.append("%s flips enforcement (%r)" % (name, write))
    for m in DEFERRED_WRITE_RE.finditer(code):
        line = code[code.rfind("\n", 0, m.start()) + 1:code.find("\n", m.start())]
        if line.strip() != "DEFERRED=()":
            fails.append("src/install/teardown/teardown.sh writes DEFERRED itself (%r)" % line.strip())
    return fails


STEP1_CALL = "remove_cmdline_tokens"
FINAL_MARK = "if (( ! ANY_CHANGE )); then"
END_WORD_RE = re.compile(r"\b(failstop|refuse|exit)\b")
SHARED_HELPERS = ("log", "failstop", "refuse", "mark_change")


def step1_state(text):
    """return remove_cmdline_tokens calls and globals"""
    defined = set(re.findall(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", text, re.M))
    reach, todo = set(), [STEP1_CALL]
    while todo:
        fn = todo.pop()
        body = None if fn in reach or fn in SHARED_HELPERS else function_text(text, fn)
        if body is None:
            continue
        reach.add(fn)
        rest = body.split("\n", 1)[-1]
        todo += [n for n in defined if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(n), rest)]
    written = set()
    for fn in reach:
        body = function_text(text, fn)
        local = {re.split(r"[=\[]", w, 1)[0] for m in re.finditer(r"^\s*local\s+(.*)$", body, re.M)
                 for w in m.group(1).split() if not w.startswith("-")}
        written |= {n for n in re.findall(r"(?<![\w$])([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]\n]*\])?\+?=(?!=)", body)
                    if n not in local}
    return reach, written


def top_level_statements(lines, first):
    """return the top-level statements with line numbers"""
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*\(\) \{", line):
            if not closes_on_line(line):
                while i < len(lines) and lines[i] != "}":
                    i += 1
            i += 1
            continue
        if line.lstrip().startswith("#") or not line.strip():
            i += 1
            continue
        num, stmt = first + i, line
        while stmt.endswith("\\") and i + 1 < len(lines):
            i += 1
            stmt = stmt[:-1] + " " + lines[i].strip()
        out.append((num, stmt))
        i += 1
    return out


def check_step1_keeps_status(text):
    """return errors for exits past step one"""
    lines = text.split("\n")
    try:
        start = lines.index(STEP1_CALL)
        end = next(i for i, l in enumerate(lines) if l.startswith(FINAL_MARK))
    except (ValueError, StopIteration):
        return ["src/install/teardown/teardown.sh has no top-level %s call or no %r section to read between"
                % (STEP1_CALL, FINAL_MARK)]
    reach, written = step1_state(text)
    reads = [re.compile(r"\$\{?#?%s\b" % re.escape(n)) for n in sorted(written)]
    calls = re.compile(r"(?<![\w-])(%s|bootloader_[A-Za-z_]+)(?![\w-])" % "|".join(map(re.escape, sorted(reach))))
    fails = []
    for num, stmt in top_level_statements(lines[start + 1:end], start + 2):
        code = re.sub(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", lambda m: '"' + " " * (len(m.group()) - 2) + '"', stmt)
        ended = END_WORD_RE.search(code)
        if not ended:
            continue
        alt = code.find("||")
        if alt < 0 or ended.start() < alt:
            fails.append("src/install/teardown/teardown.sh:%d ends the run after step 1 other than as the failure of the "
                         "command before it (%r)" % (num, stmt.strip()[:100]))
        elif any(r.search(stmt[:alt]) for r in reads) or calls.search(stmt[:alt]):
            fails.append("src/install/teardown/teardown.sh:%d ends the run on what step 1 left, a command that reads "
                         "step 1's state (%r)"
                         % (num, stmt.strip()[:100]))
    return fails


BOOTSTRAP_FUNCS = ("zswap_live", "cmdline_lacks", "live_applied", "bootstrap_already_applied")
TOKENS = "security=selinux zswap.enabled=1 loop.max_loop=64"


def bootstrap_trial(text, live, dropin, grubcfg):
    """run bootstrap_already_applied on fixtures"""
    funcs = [function_text(text, f) for f in BOOTSTRAP_FUNCS]
    if None in funcs:
        return None, "src/install/bootstrap/bootstrap.sh defines no %s" % BOOTSTRAP_FUNCS[funcs.index(None)]
    with tempfile.TemporaryDirectory() as tmp:
        dp, gp = os.path.join(tmp, "etc/default/grub.d/90-rhizo.cfg"), os.path.join(tmp, "boot/grub/grub.cfg")
        os.makedirs(os.path.dirname(dp))
        os.makedirs(os.path.dirname(gp))
        if grubcfg is not None:
            with open(gp, "w") as fh:
                fh.write(grubcfg)
        rec = os.path.join(tmp, "var/lib/rhizo/.created-by-install")
        os.makedirs(os.path.dirname(rec))
        with open(rec, "w") as fh:
            fh.write("rhizo-kernel-default -\n")
        want_dropin = "" if dropin != "WANT" else 'bootloader_write "$BL_KIND" "$ALL_TOKENS" || exit 1\n'
        if dropin not in (None, "WANT"):
            with open(dp, "w") as fh:
                fh.write(dropin)
        script = ("RHIZO_BL_ROOT=%s\n" % shlex.quote(tmp)
                  + "".join(". %s\n" % shlex.quote(os.path.join(REPO, lib)) for lib in BOOTSTRAP_LIBS)
                  + "FLAVOR=ubuntu\nBL_KIND=grub-dropin\nALL_TOKENS=%s\nZSWAP_TOKENS=zswap.enabled=1\n" % shlex.quote(TOKENS)
                  + "INSTALL_RECORD=%s\n" % shlex.quote(rec)
                  + "uname() { echo %s; }\n" % ("7.1.0-rc1-rhizo" if live else "6.8.0-136-generic")
                  + "lsm_active() { echo %s; }\n" % ("lockdown,capability,selinux" if live else "lockdown,capability,apparmor")
                  + "selinux_present() { %s; }\nzswap_on() { %s; }\n" % (("true", "true") if live else ("false", "false"))
                  + "\n".join(funcs) + "\n" + want_dropin
                  + "if bootstrap_already_applied; then echo APPLIED; else echo NOT; fi\n")
        r = run_bash(script)
    if r.stdout.strip() not in ("APPLIED", "NOT"):
        return None, "bootstrap_already_applied could not run: %s" % r.stderr.strip()[:300]
    return r.stdout.strip() == "APPLIED", None


def check_bootstrap(text):
    """check bootstrap_already_applied"""
    fails = []
    grub_all = "linux /vmlinuz ro " + TOKENS + "\n"
    cases = (
        (True, None, "linux /vmlinuz ro\n", False,
         "a reinstall on the boot of an `apt remove` (drop-in gone, grub.cfg regenerated, SELinux still live) "
         "reads as applied: nothing is written and the next boot comes up with no SELinux"),
        (True, "WANT", "linux /vmlinuz ro\n", False,
         "a grub.cfg missing the tokens reads as applied"),
        (True, "# someone else's\n", grub_all, False,
         "a drop-in that differs from what this run writes reads as applied"),
        (False, "WANT", grub_all, False,
         "a kernel without SELinux reads as applied"),
        (True, "WANT", grub_all, True,
         "a host whose kernel, drop-in and grub.cfg all carry Rhizo's tokens does not read as applied"),
    )
    for live, dropin, grubcfg, want, meaning in cases:
        got, err = bootstrap_trial(text, live, dropin, grubcfg)
        if err:
            return [err]
        if got != want:
            fails.append("bootstrap: " + meaning)
    m = re.search(r"^if (\S+); then\n(?:.*\n){0,2}?.*RHIZO_BOOTSTRAP_ALREADY_APPLIED=1", text, re.M)
    if not m or m.group(1) != "bootstrap_already_applied":
        fails.append("bootstrap: the RHIZO_BOOTSTRAP_ALREADY_APPLIED exit is gated on %r, not "
                     "bootstrap_already_applied" % (m.group(1) if m else "nothing this check can find"))
    return fails


PREPARE_UNIT = "src/services/units/boot/prepare.service"
PREPARE_SH = "src/install/prepare/prepare.sh"
MODE_HELPER = "src/androidd/host/selinux-mode.py"
MODE_HELPER_INSTALLED = "/usr/lib/rhizo/rhizo-selinux-mode"
KERNEL_ANSWERS = {"rhizo": (True, 6), "stock": (False, 4)}
MODE_HELPER_RUN = """import contextlib, runpy, sys
launcher, helper, node, supported, abi = sys.argv[1:6]
sys.path.insert(0, launcher)
with contextlib.redirect_stdout(sys.stderr):
    from sandbox import selinux_ns as ns
ns.namespace_supported = lambda: supported == "1"
ns.landlock_abi = lambda: int(abi)
ns.host_context = lambda: "kernel"
ns.HOST_ENFORCE_NODE = node
sys.argv = [helper] + sys.argv[6:]
runpy.run_path(helper, run_name="__main__")
"""
HOST_BOOT = {"mode": "host", "kernel": "stock", "selinux": True}
NAMESPACE_BOOT = {"mode": "namespace", "kernel": "rhizo", "selinux": False}


def boot_label(boot):
    """return the label of a stand-in boot"""
    return "%s mode, %s kernel, %s" % (boot["mode"], boot["kernel"],
                                      "host SELinux active" if boot["selinux"] else "no host SELinux")


def exec_condition_runs(value, helper_text, launcher_dir, boot, tmp, enforce):
    """run an ExecCondition helper on a stand-in boot"""
    argv = shlex.split(value)
    if argv[:1] != [MODE_HELPER_INSTALLED]:
        return None, "this check cannot evaluate rhizo-prepare.service's ExecCondition=%s" % value
    helper = os.path.join(tmp, "rhizo-selinux-mode")
    with open(helper, "w") as fh:
        fh.write(helper_text)
    env_file = os.path.join(tmp, "androidd.env")
    with open(env_file, "w") as fh:
        fh.write("RHIZO_SELINUX_MODE=host\n" if boot["mode"] == "host" else "")
    supported, abi = KERNEL_ANSWERS[boot["kernel"]]
    r = subprocess.run([sys.executable, "-B", "-c", MODE_HELPER_RUN, launcher_dir, helper, enforce,
                        "1" if supported else "0", str(abi)] + argv[1:] + ["--env-file", env_file],
                       capture_output=True, text=True, timeout=60,
                       env={"PATH": os.environ["PATH"], "RHIZO_GSI": os.path.join(tmp, "no-gsi")})
    if r.returncode == 0:
        return True, None
    if 1 <= r.returncode <= 254:
        return False, None
    return None, "ExecCondition=%s fails rhizo-prepare.service on a %s boot (exit %d): %s" % (
        value, boot_label(boot), r.returncode, r.stderr.strip()[-300:])


def prepare_runs(unit_text, helper_text, launcher_dir, boot, marker, tree, tree_dir=True):
    """evaluate the prepare unit's conditions and ExecCondition"""
    conds = [l for l in unit_text.split("\n") if l.startswith("Condition")]
    if not conds:
        return None, "rhizo-prepare.service carries no Condition line at all"
    exec_conds = [l.split("=", 1)[1] for l in unit_text.split("\n") if l.startswith("ExecCondition=")]
    with tempfile.TemporaryDirectory() as tmp:
        state = os.path.join(tmp, "var-lib-rhizo")
        os.makedirs(os.path.join(state, "prepared") if tree_dir else state)
        if tree:
            os.makedirs(os.path.join(state, "prepared", "0123abcd"))
        if marker:
            with open(os.path.join(state, ".prepared"), "w") as fh:
                fh.write("kernel=6.8.0-1-generic\nversion=0\n")
        enforce = os.path.join(tmp, "enforce")
        if boot["selinux"]:
            open(enforce, "w").close()
        lines = [c.replace("/var/lib/rhizo", state).replace("/sys/fs/selinux/enforce", enforce) for c in conds]
        try:
            r = subprocess.run(["systemd-analyze", "condition"] + lines, capture_output=True, text=True, timeout=30)
        except OSError as e:
            return None, "this check's own premise failed, not the unit: systemd-analyze cannot run (%s)" % e
        if r.returncode not in (0, 1) or ("Conditions succeeded" not in r.stdout + r.stderr
                                          and "Conditions failed" not in r.stdout + r.stderr):
            return None, "systemd-analyze condition could not judge the unit's conditions: %s" % (r.stdout + r.stderr).strip()[:300]
        if r.returncode != 0:
            return False, None
        for value in exec_conds:
            runs, err = exec_condition_runs(value, helper_text, launcher_dir, boot, tmp, enforce)
            if not runs:
                return runs, err
    return True, None


def kernel_refresh_trial(prepare_text, marker, tree):
    """run the kernel-refresh block on fixtures"""
    m = re.search(r'^if \[\[ "\$MODE" == kernel-refresh \]\]; then\n.*?^fi$', prepare_text, re.M | re.S)
    if not m:
        return "absent-block", "src/install/prepare/prepare.sh has no kernel-refresh block"
    with tempfile.TemporaryDirectory() as tmp:
        state = os.path.join(tmp, "var-lib-rhizo")
        os.makedirs(os.path.join(state, "prepared"))
        if tree:
            os.makedirs(os.path.join(state, "prepared", "0123abcd"))
        if marker:
            with open(os.path.join(state, ".prepared"), "w") as fh:
                fh.write("kernel=6.8.0-1-generic\nversion=0\n")
        stubs = os.path.join(tmp, "stubs")
        os.makedirs(stubs)
        for name, body in (("uname", "echo 6.8.0-2-generic"),):
            with open(os.path.join(stubs, name), "w") as fh:
                fh.write("#!/bin/sh\n%s\n" % body)
            os.chmod(os.path.join(stubs, name), 0o755)
        block = m.group(0).replace("/var/lib/rhizo", state)
        block = block.replace('[[ $EUID -eq 0 ]] || refuse "not-root" "must run as root"', ":")
        r = run_bash(". %s\n" % shlex.quote(os.path.join(REPO, "src", "install", "prepare", "kernel-changed.sh")) +
                     'MODE=kernel-refresh\nlog() { :; }\nmark_change() { :; }\nrefuse() { echo "REFUSED $1"; exit 1; }\n'
                     "host_kernel_lacks() { :; }\n"
                     "write_modules_load_conf() { :; }\n" + block + "\n",
                     env={"PATH": stubs + ":" + os.environ["PATH"]})
        if "RHIZO_PREPARE_KERNEL_REFRESHED=1" not in r.stdout:
            return "not-run", "the kernel-refresh block did not run to its sentinel: %s" % (r.stdout + r.stderr).strip()[:300]
        try:
            with open(os.path.join(state, ".prepared")) as fh:
                return fh.read(), None
        except OSError:
            return None, None


def check_reinstall(unit_text, prepare_text, helper_text, launcher_dir):
    """check the prepare unit conditions in both modes"""
    fails = []
    cases = []
    for boot in (HOST_BOOT, NAMESPACE_BOOT):
        cases += [
            (boot, True, False, True,
             "a marker with no prepared tree behind it (remove -> reboot -> reinstall) makes rhizo-prepare.service "
             "skip"),
            (boot, False, False, True, "a host with neither marker nor tree does not run setup"),
            (boot, True, True, False, "a host whose marker and tree both exist runs setup again on every boot"),
        ]
    cases += [
        (dict(HOST_BOOT, selinux=False), False, False, False,
         "setup runs on a boot with no SELinux"),
        (dict(NAMESPACE_BOOT, kernel="stock"), False, False, False,
         "setup runs on a kernel without SELinux namespaces"),
    ]
    for boot, marker, tree, want, meaning in cases:
        got, err = prepare_runs(unit_text, helper_text, launcher_dir, boot, marker, tree)
        if err:
            return [err]
        if got != want:
            fails.append("reinstall: %s: %s" % (boot_label(boot), meaning))
    for boot in (HOST_BOOT, NAMESPACE_BOOT):
        got, err = prepare_runs(unit_text, helper_text, launcher_dir, boot, True, False, tree_dir=False)
        if err:
            return [err]
        if not got:
            fails.append("reinstall: %s: a marker with no /var/lib/rhizo/prepared directory at all makes setup skip"
                         % boot_label(boot))
    got, err = kernel_refresh_trial(prepare_text, marker=False, tree=False)
    if err:
        fails.append("reinstall: " + err)
    elif got is not None:
        fails.append("reinstall: --kernel-refresh wrote a prepared marker on a host with no prepared tree")
    got, err = kernel_refresh_trial(prepare_text, marker=True, tree=True)
    if err:
        fails.append("reinstall: " + err)
    elif not (got or "").startswith("kernel=6.8.0-2-generic"):
        fails.append("reinstall: --kernel-refresh did not move a real tree's marker to the running kernel (got %r)" % got)
    return fails


def enable_links_trial(teardown_text, mode):
    """run unit_enable_links on fixture links"""
    fn = function_text(teardown_text, "unit_enable_links")
    if fn is None:
        return None, "src/install/teardown/teardown.sh defines no unit_enable_links"
    with tempfile.TemporaryDirectory() as tmp:
        etc, dsh = os.path.join(tmp, "etc"), os.path.join(tmp, "dsh")
        links = {
            "multi-user.target.wants/rhizo-prepare.service": True,
            "androidd.service.wants/rhizo-server-idle.service": False,
            "sockets.target.wants/rhizo-api.socket": False,
            "multi-user.target.wants/androidd@1.service": False,
            "multi-user.target.wants/someone-else.service": False,
        }
        for rel, dsh_made in links.items():
            os.makedirs(os.path.dirname(os.path.join(etc, rel)), exist_ok=True)
            os.symlink("/usr/lib/systemd/system/" + os.path.basename(rel), os.path.join(etc, rel))
            if dsh_made:
                os.makedirs(os.path.dirname(os.path.join(dsh, rel)), exist_ok=True)
                open(os.path.join(dsh, rel), "w").close()
        units = re.search(r"^UNITS=\(.*?\)$", teardown_text, re.M | re.S)
        if units is None:
            return None, "src/install/teardown/teardown.sh has no UNITS=( ... ) array for unit_enable_links to walk"
        body = fn.replace("/etc/systemd/system", etc)
        r = run_bash("%s\nDSH_STATE=%s\n%s\nunit_enable_links %s\n" % (units.group(0), shlex.quote(dsh), body, mode))
        return sorted(os.path.relpath(l, etc) for l in r.stdout.split("\n") if l), None


def check_enable_links(teardown_text):
    """return the problems in the unit enable links the teardown leaves"""
    fails = []
    got, err = enable_links_trial(teardown_text, "foreign")
    if err:
        return [err]
    want = ["androidd.service.wants/rhizo-server-idle.service", "multi-user.target.wants/androidd@1.service",
            "sockets.target.wants/rhizo-api.socket"]
    if "multi-user.target.wants/rhizo-prepare.service" in got:
        fails.append("links: a remove takes deb-systemd-helper's own enablement")
    for w in want:
        if w not in got:
            fails.append("links: a remove leaves %s, which `rhizo profile` made and nothing else removes" % w)
    got, _ = enable_links_trial(teardown_text, "all")
    if "multi-user.target.wants/rhizo-prepare.service" not in (got or []):
        fails.append("links: a purge leaves a Rhizo unit's enablement link")
    if "multi-user.target.wants/someone-else.service" in (got or []):
        fails.append("links: the sweep took a link to a unit that is not Rhizo's")
    return fails


def product_root_texts(root):
    """return a map of source paths to texts"""
    out = {}
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
    from tree_dirs import test_dirs
    rig = tuple((t, (".py", ".sh"), True) for t in test_dirs(root)
                if t.split("/")[1] in ("system", "benchmarks", "vm"))
    install_dir = os.path.join(root, "src/install")
    install = tuple(("src/install/" + n, (".sh",), False) for n in sorted(os.listdir(install_dir))
                    if os.path.isdir(os.path.join(install_dir, n)) and n != "tests")
    for d, exts, rhizo_only in (("src/androidd", (".py", ".sh"), False), ("src/androidd/sandbox", (".py",), False),
                                ("src/androidd/host", (".py", ".sh"), False), ("src/install", (".sh",), False),
                                *install, *rig):
        for n in sorted(os.listdir(os.path.join(root, d))):
            rel = os.path.join(d, n)
            if n.endswith(exts) and rel not in (LIB, TEARDOWN) and (not rhizo_only or n.startswith("rhizo-")):
                out[rel] = read(root, rel)
    for dirpath, _, names in os.walk(os.path.join(root, "src", "services")):
        if "/tests" in dirpath:
            continue
        for n in sorted(names):
            if n.endswith((".py", ".sh")):
                rel = os.path.relpath(os.path.join(dirpath, n), root)
                out[rel] = read(root, rel)
    return out


HOST_DIR_LITERALS = (
    re.compile(r"""NEWROOT\s*=\s*["'](/[^"']+)["']"""),
    re.compile(r"""["'](/mnt/rhizo[-\w.]*)["']"""),
    re.compile(r"""(/var/cache/rhizo[-\w.]*)"""),
)
UNIT_DIR_KEYS = {"CacheDirectory": "/var/cache", "StateDirectory": "/var/lib", "LogsDirectory": "/var/log"}


def launch_dirs(root):
    """return the host dirs the product makes"""
    found = {}
    for name, text in product_root_texts(root).items():
        for pattern in HOST_DIR_LITERALS:
            for m in pattern.finditer(text):
                found.setdefault(m.group(1), name)
    for n, rel in sorted(unit_files(root).items()):
        for line in read(root, rel).splitlines():
            key, _, value = line.partition("=")
            if key.strip() in UNIT_DIR_KEYS:
                for word in value.split():
                    found.setdefault(os.path.join(UNIT_DIR_KEYS[key.strip()], word.split(":")[0]), n)
    return found


def check_launch_dirs(helper_path, root):
    """return each product-made host dir a purge leaves"""
    deferred, err = deferred_paths(helper_path, 1)
    if err:
        return [err]
    fails = []
    for path, source in sorted(launch_dirs(root).items()):
        if not any(path == d or path.startswith(d.rstrip("/") + "/") or fnmatch.fnmatchcase(path, d)
                   for d in deferred):
            fails.append("%s makes %s, which no purge removes (not under any DEFERRED path)" % (source, path))
    return fails


def check_mounts_reaching(helper_path):
    """return the by-filesystem unmount findings"""
    info = ("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n"
            "2 1 0:40 / /rhizoroot/sub rw - tmpfs tmpfs rw\n"
            "3 1 8:1 /rhizoroot/inner /elsewhere rw - ext4 /dev/sda1 rw\n"
            "4 1 8:1 /var/x /tmp/y rw - ext4 /dev/sda1 rw\n")
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        table = os.path.join(tmp, "mountinfo")
        with open(table, "w") as fh:
            fh.write(info)
        r = run_bash("source %s\nteardown_mounts_reaching /rhizoroot %s\n" % (shlex.quote(helper_path),
                                                                              shlex.quote(table)))
        got = [l for l in r.stdout.split("\n") if l]
        if r.returncode != 0 or sorted(got) != ["/elsewhere", "/rhizoroot/sub"]:
            fails.append("teardown_mounts_reaching /rhizoroot finds %s (rc=%d), want the tmpfs below it and the bind "
                         "of its filesystem at /elsewhere, by filesystem" % (got, r.returncode))
        r = run_bash("source %s\nteardown_detach_mount() { return 32; }\nteardown_unmount_reaching /rhizoroot %s\n"
                     % (shlex.quote(helper_path), shlex.quote(table)))
        if r.returncode == 0 or r.stdout.strip() not in ("/elsewhere", "/rhizoroot/sub"):
            fails.append("teardown_unmount_reaching with a mount that will not go: want rc!=0 and the mount named; "
                         "got rc=%d %r" % (r.returncode, r.stdout))
    return fails


def check(root, verbose=True):
    """return the problems in the teardown files under a root"""
    helper = os.path.join(root, LIB)
    fails = []
    for rel in (LIB, TEARDOWN, POSTRM_TEMPLATE, EMBEDDER, BOOTSTRAP, PREINST, POSTINST, PREPARE_UNIT, PREPARE_SH,
                MODE_HELPER):
        if not os.path.isfile(os.path.join(root, rel)):
            fails.append("no %s" % rel)
    if not fails:
        for purge in (0, 1):
            fails.extend(check_purge_value(helper, purge))
        fails.extend(check_unit(helper))
        fails.extend(check_unit_accounts(helper))
        fails.extend(check_teardown_calls(read(root, TEARDOWN), read(root, LIB)))
        fails.extend(check_step1_keeps_status(read(root, TEARDOWN)))
        fails.extend(labeled_trial(read(root, TEARDOWN)))
        embedder = load_embedder(root)
        sources = embedder.read_sources(root)
        fails.extend(check_postrm(embedder.postrm_text(root), sources, embedder))
        fails.extend(check_accounts(helper))
        fails.extend(check_netbridged_units(helper))
        fails.extend(check_netbridged_create(maint_inline.inlined(os.path.join(root, POSTINST)),
                                             maint_inline.sourced(os.path.join(root, POSTINST))))
        fails.extend(check_adoption(read(root, PREINST)))
        fails.extend(check_root_state(helper, product_root_texts(root)))
        fails.extend(check_bootstrap(read(root, BOOTSTRAP)))
        fails.extend(check_reinstall(read(root, PREPARE_UNIT), read(root, PREPARE_SH), read(root, MODE_HELPER),
                                     os.path.join(root, os.path.dirname(os.path.dirname(MODE_HELPER)))))
        fails.extend(check_enable_links(read(root, TEARDOWN)))
        fails.extend(check_launch_dirs(helper, root))
        fails.extend(check_mounts_reaching(helper))
    if verbose:
        for f in fails:
            print("FAIL: teardown-remove-keeps-data: %s" % f, file=sys.stderr)
    return fails


def mutate(text, old, new):
    """return the text with a planted replacement"""
    if old not in text:
        raise AssertionError("selftest cannot plant its defect: %r is no longer in the real file" % old[:80])
    return text.replace(old, new, 1)


def with_lib(text, fn):
    """run a function on a temporary teardown library"""
    with tempfile.TemporaryDirectory() as tmp:
        p = os.path.join(tmp, "rhizo-teardown-lib.sh")
        with open(p, "w") as fh:
            fh.write(text)
        return fn(p)


def expect(name, fails, needle, counter):
    """record the name of a planted defect unless the failures name it"""
    assert any(needle in f for f in fails), (
        "planted defect not caught by name (%s): expected %r, got:\n%s" % (name, needle, "\n".join(fails) or "(clean)"))
    counter.append(name)


def selftest():
    """run each check on mutated source copies"""
    lib = read(REPO, LIB)
    teardown = read(REPO, TEARDOWN)
    bootstrap = read(REPO, BOOTSTRAP)
    embedder = load_embedder(REPO)
    postrm = embedder.postrm_text(REPO)
    sources = embedder.read_sources(REPO)
    caught = []

    two = 'a() { x; }\nb() {\n  y\n}\nc() {  # takes ${X}\n  z\n}\nd() { echo "}"; }\ne() {  # closes with }\n  w\n}\n'
    for fn, want in (("a", "a() { x; }"), ("b", "b() {\n  y\n}"), ("c", "c() {  # takes ${X}\n  z\n}"),
                     ("d", 'd() { echo "}"; }'), ("e", "e() {  # closes with }\n  w\n}")):
        assert function_text(two, fn) == want, "%s() lifted as %r" % (fn, function_text(two, fn))

    real = check(REPO, verbose=False)
    assert not real, "the real tree must pass clean, got:\n" + "\n".join(real)

    old_literal = mutate(lib, "teardown_deferred_paths() {\n",
                         "teardown_deferred_paths() {\n  DEFERRED=(/var/lib/rhizo /usr/lib/rhizo /etc/rhizo /srv/rhizo); return 0\n")
    expect("the old bug: every run schedules the four bare roots",
           with_lib(old_literal, lambda p: check_purge_value(p, 0)), "the bare root /var/lib/rhizo", caught)
    no_data = mutate(lib, '      "$RHIZO_TEARDOWN_LIB_DATA_IMG"\n', "")
    expect("purge=1 silently drops data.img",
           with_lib(no_data, lambda p: check_purge_value(p, 1)), "/var/lib/rhizo/data.img", caught)
    leak = mutate(lib, '    "$RHIZO_TEARDOWN_LIB_APPWATCH_BIN"\n',
                  '    "$RHIZO_TEARDOWN_LIB_APPWATCH_BIN"\n    "$RHIZO_TEARDOWN_LIB_ETC_RHIZO"\n')
    expect("purge=0 leaks /etc/rhizo into a plain remove",
           with_lib(leak, lambda p: check_purge_value(p, 0)), "purge=0: DEFERRED names the bare root /etc/rhizo", caught)
    no_root = mutate(lib, "RHIZO_TEARDOWN_LIB_LAUNCH_DIRS=(/rhizoroot ", "RHIZO_TEARDOWN_LIB_LAUNCH_DIRS=(")
    expect("a purge leaves the sandbox root mount point",
           with_lib(no_root, lambda p: check_launch_dirs(p, REPO)), "makes /rhizoroot, which no purge removes", caught)
    in_unit = mutate(lib, "rm -rf __RHIZO_TEARDOWN_DEFERRED__ ", "rm -rf __RHIZO_TEARDOWN_DEFERRED__ /var/lib/rhizo ")
    expect("the old bug restored straight into the unit text",
           with_lib(in_unit, check_unit), "names the bare root /var/lib/rhizo directly", caught)
    lib_path = os.path.join(REPO, LIB)
    remove_unit, err = render_unit(lib_path, 0, ["/usr/bin/bash"], extra="REGEN_DEFERRED=(grub-dropin) MODULE_LABELS_DEFERRED=1")
    assert not err, err
    assert not check_scheduled_unit(lib_path, remove_unit), (
        "the rendered remove unit must pass as scheduled, got:\n" + "\n".join(check_scheduled_unit(lib_path, remove_unit)))
    with tempfile.TemporaryDirectory() as tmp:
        read_back = os.path.join(tmp, "final-cleanup-unit.txt")
        with open(read_back, "w") as fh:
            fh.write("UNIT_PRESENT\n" + remove_unit + "\nUNIT_END\n")
        text, err = unit_file_text(read_back)
        assert not err and text.strip() == remove_unit.strip(), "the system test's sentinels must be stripped: %s" % err
        with open(read_back, "w") as fh:
            fh.write("UNIT_PRESENT\n" + remove_unit[:remove_unit.index("\n", remove_unit.index("rm -rf"))] + "\n")
        expect("a unit read cut short after its rm -rf line", [unit_file_text(read_back)[1] or ""],
               "cut short", caught)
    for name, old, new, needle in (
        ("the scheduled rm -rf names data.img", "/var/lib/rhizo/prepared ", "/var/lib/rhizo/data.img /var/lib/rhizo/prepared ",
         "never allows a plain remove to defer"),
        ("the scheduled rm -rf names the bare state root", "/var/lib/rhizo/prepared ", "/var/lib/rhizo /var/lib/rhizo/prepared ",
         "the bare root /var/lib/rhizo"),
        ("the scheduled rm -rf names the admin's hostfs.conf", "/var/lib/rhizo/prepared ",
         "/etc/rhizo/hostfs.conf /var/lib/rhizo/prepared ", "configuration a remove keeps (/etc/rhizo/hostfs.conf)"),
        ("the scheduled rm -rf names a kept instance's data", "/var/lib/rhizo/prepared ",
         "/var/lib/rhizo/instances /var/lib/rhizo/prepared ", "only a purge may remove"),
        ("the scheduled rm -rf names the fetched image", "/var/lib/rhizo/prepared ",
         "/srv/rhizo/gsi_system /var/lib/rhizo/prepared ", "the fetched image (/srv/rhizo/gsi_system)"),
        ("a purge's rmdir line on a remove", "[Install]", "ExecStart=-/bin/rmdir /var/lib/rhizo /srv/rhizo\n\n[Install]",
         "only a purge removes Rhizo's state dirs"),
        ("a glob over the state root on a line of its own", "[Install]",
         "ExecStart=/bin/rm -rf /var/lib/rhizo/*\n\n[Install]", "/var/lib/rhizo/* under a Rhizo root"),
        ("a kept instance's dir on a line of its own", "[Install]",
         "ExecStart=/bin/rm -rf /var/lib/rhizo/instances/1\n\n[Install]", "/var/lib/rhizo/instances/1 under a Rhizo root"),
        ("gsi update's rollback copy on a line of its own", "[Install]",
         "ExecStart=/bin/rm -rf /var/lib/rhizo/update/rollback\n\n[Install]",
         "/var/lib/rhizo/update/rollback under a Rhizo root"),
        ("the admin's hostfs.conf in an ExecStartPre", "[Service]\n",
         "[Service]\nExecStartPre=/bin/rm -f /etc/rhizo/hostfs.conf\n", "configuration a remove keeps (/etc/rhizo/hostfs.conf)"),
    ):
        expect(name, check_scheduled_unit(lib_path, mutate(remove_unit, old, new)), needle, caught)
    expect("a scheduled unit with no ExecStart", check_scheduled_unit(lib_path, "[Unit]\n"), "nothing was read", caught)

    expect("the generator call replaced by a hardcoded DEFERRED=(/var/lib/rhizo)",
           check_teardown_calls(mutate(teardown, 'teardown_deferred_paths "$PURGE"', "DEFERRED=(/var/lib/rhizo)")),
           "does not call 'teardown_deferred_paths", caught)

    old_label_line = ("ExecStart=/bin/sh -c 'for f in /usr/lib/systemd/systemd /usr/sbin/sshd /usr/bin/bash "
                      "/usr/bin/dash /usr/bin/systemctl /usr/bin/python3; do setfattr -x security.selinux "
                      "\"$f\" 2>/dev/null; done'")
    old_unit = re.sub(r'(?m)^    label_line="ExecStart=/usr/bin/python3 .*$',
                      lambda _: "    label_line=%s" % shlex.quote(old_label_line), lib, count=1)
    assert old_unit != lib, "selftest cannot plant the setfattr label line: the label line moved"
    fails = with_lib(old_unit, check_unit)
    expect("a label left: a setfattr loop over six fixed paths", fails, "a label left on bash", caught)
    expect("a label left: the unit names setfattr", fails, "runs setfattr", caught)
    fixed = mutate(lib, "$RHIZO_TEARDOWN_LIB_HOST_EXEC_CONTEXT ${LABELED[*]:-}\"",
                   "$RHIZO_TEARDOWN_LIB_HOST_EXEC_CONTEXT /usr/bin/bash /usr/bin/dash\"")
    expect("a label left: the loader, never in the fixed list",
           with_lib(fixed, check_unit), "a label left on ld.so", caught)
    expect("a label left: the teardown never tells the unit which files carry it",
           check_teardown_calls(mutate(teardown, "mapfile -t LABELED < <(selinux_xattr_report labeled)",
                                       "LABELED=()")),
           "never told which files still carry the label", caught)
    greedy = mutate(lib, "os.getxattr(p,a).rstrip(bytes(1))==c]", "True]")
    expect("a label that was never Rhizo's is stripped",
           with_lib(greedy, check_unit), "stripped a label that was not Rhizo's", caught)

    old_postrm = mutate(postrm, "rhizo_run_teardown --purge ||",
                        '[ -x /var/lib/rhizo/rhizo-host-teardown.sh ] && /var/lib/rhizo/rhizo-host-teardown.sh --purge ||')
    lines = old_postrm.split("\n")
    old_postrm = "\n".join(lines[:lines.index(embedder.BEGIN)] + lines[lines.index(embedder.END) + 1:])
    fails = check_postrm(old_postrm, sources, embedder)
    expect("the teardown unreachable at purge after a prior remove+reboot (a host copy, nothing embedded)",
           fails, "which is gone at purge after a prior", caught)
    expect("the teardown unreachable at purge: no embedded copy", fails, "carries no embedded teardown", caught)
    outdated_sources = dict(sources)
    outdated_sources[TEARDOWN] = sources[TEARDOWN] + b"# a change made after the last --write\n"
    expect("an outdated embedded teardown", check_postrm(postrm, outdated_sources, embedder),
           "embedded install/teardown/teardown.sh is outdated", caught)
    expect("the purge branch runs the teardown without --purge",
           check_postrm(mutate(postrm, "rhizo_run_teardown --purge ||", "rhizo_run_teardown ||"), sources, embedder),
           "does not call rhizo_run_teardown --purge", caught)
    expect("the runner swallows the teardown's status",
           check_postrm(mutate(postrm, '  return "$rhizo_td_rc"\n', "  return 0\n"), sources, embedder),
           "did not return the teardown's own status", caught)

    ignores = mutate(lib, 'if grep -qx "user:$name" "$record"; then', "if false; then")
    expect("the appwatch user left when Rhizo created it",
           with_lib(ignores, check_accounts), "the appwatch user was left although", caught)
    by_name = mutate(lib, 'if grep -qx "user:$name" "$record"; then', 'if getent passwd "$name" >/dev/null; then')
    expect("the appwatch user removed when Rhizo did NOT create it",
           with_lib(by_name, check_accounts), "removed although this install did not create it", caught)
    preinst = read(REPO, PREINST)
    expect("the appwatch user 0.1.0 created left unrecorded: no adoption job",
           check_adoption(mutate(preinst, "    RECORD=/var/lib/rhizo/.created-by-install\n", "    RECORD=/nowhere\n")),
           "has no adoption job", caught)
    expect("adoption on the name alone: removed when Rhizo did NOT create it",
           check_adoption(mutate(preinst, '      if [ "$(echo "$entry" | cut -d: -f3,6,7)" = "1000:/nonexistent:/usr/sbin/nologin" ]; then',
                                 '      if [ -n "$entry" ]; then')),
           "a shape 0.1.0 never made", caught)
    expect("adoption from any version: removed when Rhizo did NOT create it",
           check_adoption(mutate(preinst, 'dpkg --compare-versions "$2" lt 0.1.1', "true")),
           "from a version that records", caught)
    expect("the teardown never calls the account removal",
           check_teardown_calls(mutate(teardown, 'teardown_remove_appwatch_account "$INSTALL_RECORD"', "true")),
           "never removed", caught)

    nb_call = '  teardown_remove_recorded_account "$1" "$RHIZO_TEARDOWN_LIB_NETBRIDGED_ACCOUNT"\n'
    expect("rhizo-netbridged deleted by name, record or not",
           with_lib(mutate(lib, nb_call, "  getent passwd rhizo-netbridged >/dev/null && userdel rhizo-netbridged\n"),
                    check_accounts),
           "the netbridged user was removed although this install did not create it", caught)
    expect("the netbridged user left when Rhizo created it",
           with_lib(mutate(lib, nb_call, "  true\n"), check_accounts),
           "the netbridged user was left although", caught)
    expect("the teardown never removes rhizo-netbridged",
           check_teardown_calls(mutate(teardown, 'netbridged_out=$(teardown_remove_netbridged_account "$INSTALL_RECORD")',
                                       "netbridged_out=$(true)"), lib),
           "the rhizo-netbridged account this install created is never removed", caught)
    expect("the network daemon still runs as rhizo-netbridged when userdel runs",
           check_teardown_calls(mutate(teardown, "done < <(teardown_netbridged_units)", "done < <(true)"), lib),
           "still runs as rhizo-netbridged when userdel runs", caught)
    expect("the netbridged unit match takes a stranger's unit",
           with_lib(mutate(lib, "$1 ~ /^rhizo-netbridged(-[0-9]+)?\\.service$/", "$1 ~ /^rhizo-netbridged/"),
                    check_netbridged_units),
           "teardown_netbridged_units named", caught)
    expect("the cleanup unit deletes an account no teardown creates",
           with_lib(mutate(lib, '      [[ "$name" == "$known" ]] || continue\n', ""), check_unit_accounts),
           "would delete an account no teardown ever creates: root", caught)
    expect("the cleanup unit renders only the first deferred account",
           with_lib(mutate(lib, "  for name in $account; do\n", "  for name in ${account%% *}; do\n"),
                    check_unit_accounts),
           "names userdel rhizo-netbridged 0 time(s)", caught)
    postinst = maint_inline.inlined(os.path.join(REPO, POSTINST))
    postinst_libs = maint_inline.sourced(os.path.join(REPO, POSTINST))
    expect("postinst creates rhizo-netbridged unrecorded",
           check_netbridged_create(mutate(postinst, "      } >> /var/lib/rhizo/.created-by-install \\\n",
                                          "      } > /dev/null \\\n"), postinst_libs),
           "without recording them", caught)
    expect("postinst records a group it did not create",
           check_netbridged_create(mutate(postinst, '        [ "$nb_had_group" = 1 ] || echo group:rhizo-netbridged\n',
                                          "        echo group:rhizo-netbridged\n"), postinst_libs),
           "records a rhizo-netbridged group that existed before it", caught)
    expect("the rhizo-netbridged 0.1.0 created left unrecorded: no adoption",
           check_adoption(mutate(preinst, '        echo user:rhizo-netbridged >> "$RECORD"\n', "        true\n")),
           "rhizo-netbridged account 0.1.0 created is left unrecorded", caught)
    expect("rhizo-netbridged adopted from any version",
           check_adoption(mutate(preinst, '"$RECORD" 2>/dev/null \\\n       && dpkg --compare-versions "$2" lt 0.1.2; then\n      nb=$(',
                                 '"$RECORD" 2>/dev/null; then\n      nb=$(')),
           "adopted an unrecorded rhizo-netbridged", caught)
    expect("rhizo-netbridged adopted with a home and a shell",
           check_adoption(mutate(preinst, '      if [ "$(echo "$nb" | cut -d: -f6,7)" = "/nonexistent:/usr/sbin/nologin" ] \\\n',
                                 '      if [ -n "$nb" ] \\\n')),
           "(a home and a shell)", caught)
    expect("rhizo-netbridged adopted at a person's uid",
           check_adoption(mutate(preinst, '         && [ -n "$nb_uid" ] && [ "$nb_uid" -lt 1000 ]; then\n',
                                 "         ; then\n")),
           "(not a system uid)", caught)
    expect("the postrm deletes rhizo-netbridged by name",
           check_postrm(mutate(postrm, "    remove_payload_bytecode\n    ;;\n  purge)",
                               "    remove_payload_bytecode\n"
                               "    if getent passwd rhizo-netbridged >/dev/null 2>&1; then\n"
                               "      deluser --system rhizo-netbridged 2>/dev/null || true\n"
                               "    fi\n    ;;\n  purge)"), sources, embedder),
           "the postrm deletes rhizo-netbridged by name", caught)

    no_gpid = mutate(lib, "  /root/.rhizo_g_pid\n", "")
    expect("a /root/.rhizo_ file the teardown never removes",
           with_lib(no_gpid, lambda p: check_root_state(p, product_root_texts(REPO))),
           "names /root/.rhizo_g_pid, which no teardown removes", caught)
    no_inst = mutate(lib, ' "/root/.rhizo_init_pid-*"', "")
    expect("an instance's copy the teardown never removes",
           with_lib(no_inst, lambda p: check_root_state(p, product_root_texts(REPO))),
           "/root/.rhizo_init_pid-<id>, which no teardown removes", caught)

    enforcing_note = '  elif [[ "$(cat "$TEARDOWN_SELINUX_ENFORCE" 2>/dev/null)" == 1 ]]; then\n'
    flip = mutate(teardown, enforcing_note, enforcing_note + '    echo 0 > "$TEARDOWN_SELINUX_ENFORCE" 2>/dev/null\n')
    expect("the teardown flips enforcement through its enforce node variable", check_teardown_calls(flip),
           "flips enforcement ('> \"$TEARDOWN_SELINUX_ENFORCE\"')", caught)
    flip = mutate(teardown, enforcing_note, enforcing_note + "    echo 0 > /sys/fs/selinux/enforce\n")
    expect("the teardown flips enforcement at the literal node", check_teardown_calls(flip),
           "flips enforcement ('> /sys/fs/selinux/enforce')", caught)

    live_only = mutate(bootstrap,
                       "  live_applied && bootloader_config_current \"$BL_KIND\" \"$ALL_TOKENS\" || return 1\n",
                       "  live_applied; return\n")
    expect("bootstrap: live state alone reads a same-boot reinstall as applied",
           check_bootstrap(live_only), "reads as applied: nothing is written", caught)
    call_site = mutate(bootstrap, "if bootstrap_already_applied; then", "if live_applied; then")
    expect("bootstrap: the ALREADY_APPLIED exit gated on the live kernel alone",
           check_bootstrap(call_site), "gated on 'live_applied'", caught)

    unit = read(REPO, PREPARE_UNIT)
    prep = read(REPO, PREPARE_SH)
    mode_helper = read(REPO, MODE_HELPER)
    launcher_dir = os.path.join(REPO, os.path.dirname(os.path.dirname(MODE_HELPER)))
    old_unit_conds = mutate(unit, "ConditionPathExists=|!/var/lib/rhizo/.prepared\n"
                                  "ConditionDirectoryNotEmpty=|!/var/lib/rhizo/prepared\n",
                            "ConditionPathExists=!/var/lib/rhizo/.prepared\n")
    expect("the marker alone decides, and outlives its tree",
           check_reinstall(old_unit_conds, prep, mode_helper, launcher_dir),
           "a marker with no prepared tree behind it", caught)
    old_refresh = re.sub(r'(?ms)^  if \[\[ -z "\$\(ls -A /var/lib/rhizo/prepared 2>/dev/null\)" \]\]; then\n.*?^  fi\n', "", prep, count=1)
    assert old_refresh != prep, "selftest cannot plant the old kernel-refresh: its tree check moved"
    expect("--kernel-refresh writes a marker with no tree behind it",
           check_reinstall(unit, old_refresh, mode_helper, launcher_dir),
           "wrote a prepared marker on a host with no prepared tree", caught)
    host_any_boot = mutate(mode_helper, "        if mode == \"host\" and not os.path.exists(ns.HOST_ENFORCE_NODE):\n",
                           "        if False:\n")
    expect("host mode: --is-startable passes a boot with no host enforce node",
           check_reinstall(unit, prep, host_any_boot, launcher_dir),
           "host mode, stock kernel, no host SELinux: setup runs on a boot with no SELinux", caught)
    host_node_cond = mutate(unit, "ConditionDirectoryNotEmpty=|!/var/lib/rhizo/prepared\n",
                            "ConditionDirectoryNotEmpty=|!/var/lib/rhizo/prepared\n"
                            "ConditionPathExists=/sys/fs/selinux/enforce\n")
    expect("namespace mode: the unit keeps the host enforce node condition",
           check_reinstall(host_node_cond, prep, mode_helper, launcher_dir),
           "namespace mode, rhizo kernel, no host SELinux: a host with neither marker nor tree does not run setup",
           caught)
    no_exec_cond = mutate(unit, "ExecCondition=/usr/lib/rhizo/rhizo-selinux-mode --is-startable\n", "")
    expect("namespace mode: the unit has no mode condition",
           check_reinstall(no_exec_cond, prep, mode_helper, launcher_dir),
           "namespace mode, stock kernel, no host SELinux: setup runs on a kernel without SELinux namespaces", caught)
    other_exec_cond = mutate(unit, "ExecCondition=/usr/lib/rhizo/rhizo-selinux-mode --is-startable\n",
                             "ExecCondition=/bin/true\n")
    expect("an ExecCondition this check cannot evaluate",
           check_reinstall(other_exec_cond, prep, mode_helper, launcher_dir),
           "cannot evaluate rhizo-prepare.service's ExecCondition=/bin/true", caught)
    usage_error = mutate(unit, "rhizo-selinux-mode --is-startable\n", "rhizo-selinux-mode --is-startable --bogus\n")
    expect("an ExecCondition that fails the unit",
           check_reinstall(usage_error, prep, mode_helper, launcher_dir), "fails rhizo-prepare.service", caught)

    rm_root = mutate(lib, 'rmdir_line="ExecStart=-/bin/rmdir $RHIZO_TEARDOWN_LIB_STATE_ROOT /srv/rhizo"',
                     'rmdir_line="ExecStart=-/bin/rm -rf $RHIZO_TEARDOWN_LIB_STATE_ROOT /srv/rhizo"')
    expect("the original bug back on purge, as an optional unit line",
           with_lib(rm_root, check_unit), "names the bare root /var/lib/rhizo -- only rmdir", caught)
    pct = mutate(lib, "print('cleared',p)", "print('cleared %s' % p)")
    expect("a systemd specifier in the label line",
           with_lib(pct, check_unit), "which systemd rewrites before the command runs", caught)
    expect("the teardown reports a symlink, not the labeled file, to the unit",
           labeled_trial(mutate(teardown, "        if current == ctx:\n            print(real)",
                                 "        if current == ctx:\n            print(p)")),
           "want only the labeled file's real path", caught)
    expect("the teardown widens DEFERRED after the generator",
           check_teardown_calls(mutate(teardown, 'teardown_deferred_paths "$PURGE"\n',
                                       'teardown_deferred_paths "$PURGE"\nDEFERRED+=(/var/lib/rhizo)\n'), lib),
           "writes DEFERRED itself", caught)
    expect("a call present only as a comment",
           check_teardown_calls(mutate(teardown, '(( account_rc )) && ACCOUNT_DEFERRED="$APPWATCH_ACCOUNT"\n',
                                       '(( account_rc )) && ACCOUNT_DEFERRED="$APPWATCH_ACCOUNT"\n').replace(
                                           'account_out=$(teardown_remove_appwatch_account "$INSTALL_RECORD")',
                                           '# account_out=$(teardown_remove_appwatch_account "$INSTALL_RECORD")', 1), lib),
           "never removed", caught)
    expect("a flip written into the lib",
           check_teardown_calls(teardown, lib + "\nrelax() { echo 0 | tee /sys/fs/selinux/enforce; }\n"),
           "teardown-lib.sh flips enforcement", caught)
    no_idle = mutate(teardown, "rhizo-server-idle.service rhizo-server-idle@.service",
                     "rhizo-server-idle@.service")
    expect("a unit dropped from the teardown's own UNITS array",
           check_enable_links(no_idle), "a remove leaves androidd.service.wants/rhizo-server-idle.service", caught)
    expect("a /root/.rhizo_ name built at run time",
           with_lib(lib, lambda p: check_root_state(p, {"x.py": 'f"/root/.rhizo_{name}"\n'})),
           "builds a /root/.rhizo_ name this check cannot read", caught)

    expect("a remove that takes deb-systemd-helper's links too",
           check_enable_links(mutate(teardown, '      [[ "$1" == foreign && -e "$DSH_STATE/${l#/etc/systemd/system/}" ]] && continue\n', "")),
           "takes deb-systemd-helper's own enablement", caught)
    expect("the profile's links left behind",
           check_teardown_calls(mutate(teardown, 'done < <(unit_enable_links "$( (( PURGE )) && echo all || echo foreign)")',
                                       'done < <(true)')),
           "the enablement links `rhizo profile` made are never removed", caught)

    for name, old, new in (
            ("step 1 never called", "\nremove_cmdline_tokens\n", "\ntrue\n"),
            ("--verify skips the bootloader's files", "  list_cmdline_tokens || cmdline_rc=$?\n", ""),
            ("--verify concludes what it cannot read", '    failstop "verify-cannot-read"', "    :"),
            ("the scheduled line's regeneration names never collected",
             '    regen_names+=", $(bootloader_regen_label "$kind")"\n', "    :\n"),
            ("the scheduled line drops the regeneration names", "${LABELED[*]}}$regen_names$(", "${LABELED[*]}}$("),
            ("tokens nothing can regenerate away never named",
             '  report_stranded_tokens apply "$detected" "$targets"\n', "")):
        planted = mutate(teardown, old, new)
        missed = [why for call, why in TEARDOWN_CALLS if call not in code_only(planted)]
        assert missed, "planting %r left every call in place" % name
        expect(name, check_teardown_calls(planted, lib), missed[0], caught)

    left_end = '    [[ "$4" == "has cmdlines that cannot be read" ]] || LEFT_CONFIGS+=("$gen"$\'\\t\'"$2")\n  fi\n  return 1\n'
    armed = mutate(teardown, left_end, left_end.replace("  return 1\n", "  LEFT_TOKENS=1\n  return 1\n"))
    for name, top, needle in (
            ("the review's plant: step 1's leftover arms a failstop above the final section",
             '(( ${LEFT_TOKENS:-0} )) && failstop "bootloader-tokens-left" '
             '"rhizo\'s tokens stay on a next-boot cmdline"\n',
             "ends the run after step 1 other than as the failure"),
            ("the same in an if block",
             'if (( ${LEFT_TOKENS:-0} )); then\n  failstop "bootloader-tokens-left" "x"\nfi\n',
             "ends the run after step 1 other than as the failure"),
            ("the same as a failed test of step 1's state",
             '[[ -z "${LEFT_TOKENS:-}" ]] || failstop "bootloader-tokens-left" "x"\n',
             "ends the run on what step 1 left"),
            ("the same as a failed step 1 call",
             'report_stranded_tokens apply "" "" || failstop "bootloader-tokens-left" "x"\n',
             "ends the run on what step 1 left")):
        expect(name, check_step1_keeps_status(mutate(armed, FINAL_MARK, top + "\n" + FINAL_MARK)), needle, caught)

    print("check-teardown-remove-keeps-data selftest: the real tree passes, %d planted defects each named" % len(caught))
    return 0


def main():
    """run the check or its selftest and print the result"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", default=REPO)
    ap.add_argument("--unit-file", help="judge a rhizo-final-cleanup.service a plain remove scheduled on a host")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.unit_file:
        text, err = unit_file_text(args.unit_file)
        fails = [err] if err else check_scheduled_unit(os.path.join(args.root, LIB), text)
        for f in fails:
            print("FAIL: teardown-remove-keeps-data: %s" % f, file=sys.stderr)
        if not fails:
            print("check-teardown-remove-keeps-data: the scheduled cleanup unit names only what "
                  "teardown_deferred_paths 0 allows a plain remove to defer")
        return 1 if fails else 0
    fails = check(args.root)
    if not fails:
        print("check-teardown-remove-keeps-data: remove keeps data, the cleanup unit clears every label it is "
              "given, the postrm carries a current teardown, accounts go only on the record, every /root state "
              "file is covered, nothing flips enforcement, and the bootstrap re-applies after a same-boot remove")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
