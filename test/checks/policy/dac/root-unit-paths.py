#!/usr/bin/env python3
import glob
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import install_dirs  # noqa: E402
import unit_files  # noqa: E402
GLOBS = ["debian/dropins/*.conf"]
UNIT_SUFFIXES = (".service", ".path", ".timer", ".socket")
HEREDOC_SOURCES = [os.path.join(d, "*.sh") for d in install_dirs(ROOT)] + [
    "debian/*.postinst", "debian/*.preinst", "debian/*.prerm", "debian/*.postrm.in"]
HEREDOC_RE = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
SECTION_RE = re.compile(r"^\[(Unit|Service|Install|Path|Timer|Socket|Mount)\]\s*$", re.M)

USER_DIR_RE = re.compile(r"(?<![\w.-])/(?:run/user|home)/\S*")
DROPIN_INSTALL_RE = re.compile(
    r'install\s[^\n]*?(\S+\.conf)\s*\\\s*\n\s*"?([^"\s]+)"?\s*$', re.M)
UNIT_NAME_RE = re.compile(unit_files.PATH_RE + r"([A-Za-z0-9_.@-]+\.(?:service|path|socket|timer))"
                          r"(?![A-Za-z0-9_.@-])")

PID1_ANY_UNIT = re.compile(
    r"^(?:(?:Condition|Assert)(?:PathExists|PathExistsGlob|PathIsDirectory|"
    r"PathIsSymbolicLink|PathIsMountPoint|PathIsReadWrite|PathIsEncrypted|"
    r"DirectoryNotEmpty|FileNotEmpty|FileIsExecutable)|EnvironmentFile|"
    r"ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|ExecPaths|NoExecPaths|"
    r"BindPaths|BindReadOnlyPaths|StandardOutput|StandardError|StandardInput|"
    r"PIDFile)$")
PID1_PATH_UNIT = re.compile(r"^(?:PathExists|PathExistsGlob|PathChanged|PathModified|"
                            r"DirectoryNotEmpty)$")
PID1_SOCKET_UNIT = re.compile(r"^Listen(?:Stream|Datagram|SequentialPacket|FIFO|Special|"
                              r"MessageQueue|USBFunction)$")
EXEC_KEY = re.compile(r"^Exec(?:Start|StartPre|StartPost|Condition|Stop|StopPost|Reload)$")
EXEC_PREFIX = re.compile(r"^[-@:+!|]*")
ROOT_USERS = {"", "root", "0"}


def unit_name(rel):
    """return the name the unit file at rel installs as"""
    base = os.path.basename(rel)
    return unit_files.installed_name(base) if unit_files.is_unit_path(rel) else base


def logical_lines(text):
    """return the directive lines with continuations joined"""
    out, buf, start = [], "", 0
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if line.lstrip().startswith(("#", ";")) or (not buf and not line.strip()):
            continue
        if not buf:
            start = n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def directives(text):
    """return the directives of a unit text"""
    out = []
    for lineno, line in logical_lines(text):
        if line.lstrip().startswith("[") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out.append((lineno, key.strip(), value.strip()))
    return out


def unit_user(text):
    """return the last User= value in a unit"""
    user = None
    for _, key, value in directives(text):
        if key == "User":
            user = value
    return user


def user_units(rules_text):
    """return the units installed into USER_UNITS"""
    out = set()
    for stanza in rules_text.split("install "):
        if "$(USER_UNITS)" in stanza:
            out.update(unit_files.installed_name(n) for n in UNIT_NAME_RE.findall(stanza))
    return out


def dropin_units(rules_text):
    """return the units each drop-in installs under"""
    out = {}
    for src, dest in DROPIN_INSTALL_RE.findall(rules_text):
        unit_dir = os.path.basename(os.path.dirname(dest))
        if unit_dir.endswith(".d"):
            out.setdefault(src, []).append(unit_dir[:-2])
    return out


def heredoc_units(text):
    """return the unit text heredoc bodies"""
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = HEREDOC_RE.search(line)
        if not m or line.lstrip().startswith("#"):
            continue
        strip, delim = m.group(1) == "-", m.group(3)
        body = []
        for j in range(i + 1, len(lines)):
            end = lines[j].lstrip("\t") if strip else lines[j]
            if end == delim:
                break
            body.append(lines[j])
        joined = "\n".join(body)
        if SECTION_RE.search(joined):
            out.append((i + 2, joined))
    return out


def findings_for(label, suffix, text, user):
    """return the findings for a unit text"""
    out = []
    for lineno, key, value in directives(text):
        hit = USER_DIR_RE.search(value)
        if not hit:
            continue
        why = None
        if PID1_ANY_UNIT.match(key):
            why = "PID 1 resolves it as root before any User= applies"
        elif suffix == "path" and PID1_PATH_UNIT.match(key):
            why = "PID 1 watches and globs it as root"
        elif suffix == "socket" and PID1_SOCKET_UNIT.match(key):
            why = "PID 1 binds it as root"
        elif EXEC_KEY.match(key):
            prefix = EXEC_PREFIX.match(value).group(0)
            if "+" in prefix or "!" in prefix:
                why = "its %r prefix runs it with root's own credentials" % prefix
            elif (user or "") in ROOT_USERS:
                why = "the unit has no User= of its own, so it runs as root" if not user \
                    else "the unit runs as User=%s" % user
        if why:
            out.append("root-unit-names-user-dir: %s:%d: %s= names %s, and %s"
                       % (label, lineno, key, hit.group(0), why))
    return out


def check(root):
    """return the findings and counts for a tree"""
    with open(os.path.join(root, "debian", "rules"), encoding="utf-8") as fh:
        rules_text = fh.read()
    users = user_units(rules_text)
    dropins = dropin_units(rules_text)
    files = sorted({f for g in GLOBS for f in glob.glob(os.path.join(root, g))}
                   | set(unit_files.unit_paths(root, UNIT_SUFFIXES)) | set(unit_files.dropin_paths(root)))
    texts = {}
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as fh:
            texts[os.path.relpath(f, root)] = fh.read()
    by_name = {unit_name(rel): text for rel, text in texts.items()
               if not rel.endswith(".conf")}

    bad, counts = [], {"system": 0, "system-path": 0, "user": 0, "dropin": 0, "heredoc": 0}
    for name in sorted(users):
        if name not in by_name:
            bad.append("user-unit-missing: debian/rules installs %s into "
                       "$(USER_UNITS) and no such file exists" % name)
    for rel, text in sorted(texts.items()):
        base = unit_name(rel)
        if rel.endswith(".conf"):
            if rel.startswith("src/services/"):
                targets = [os.path.basename(os.path.dirname(rel))[:-2]]
            else:
                targets = dropins.get(rel, [])
            for target in targets:
                if target in users:
                    continue
                counts["dropin"] += 1
                user = unit_user(text)
                if user is None:
                    user = unit_user(by_name.get(target, ""))
                bad += findings_for("%s (in %s)" % (rel, target), target.rpartition(".")[2],
                                    text, user)
            continue
        if base in users:
            counts["user"] += 1
            continue
        suffix = base.rpartition(".")[2]
        counts["system"] += 1
        if suffix == "path":
            counts["system-path"] += 1
        bad += findings_for(rel, suffix, text, unit_user(text))
    for g in HEREDOC_SOURCES:
        for f in sorted(glob.glob(os.path.join(root, g))):
            with open(f, encoding="utf-8", errors="replace") as fh:
                for lineno, body in heredoc_units(fh.read()):
                    counts["heredoc"] += 1
                    label = "%s:%d (heredoc)" % (os.path.relpath(f, root), lineno)
                    bad += findings_for(label, "service", body, unit_user(body))
    return bad, counts


def run():
    """print the findings and return an exit status"""
    bad, counts = check(ROOT)
    if not counts["system-path"]:
        bad.append("premise: read no system .path unit under %s"
                   % ", ".join(GLOBS))
    if not counts["user"]:
        bad.append("premise: debian/rules installs no unit into $(USER_UNITS)")
    for b in bad:
        print("check-root-unit-paths: FAIL: " + b, file=sys.stderr)
    if bad:
        return 1
    print("check-root-unit-paths: %d system units (%d .path), %d drop-ins and %d heredoc "
          "units name nothing under /run/user/ or /home/ as root; %d user units run as "
          "their owner" % (counts["system"], counts["system-path"], counts["dropin"],
                           counts["heredoc"], counts["user"]))
    return 0


RULES_FIXTURE = """\
\tinstall -m 0644 src/services/units/sys.path src/services/units/sys.service $(UNITS)/
\tinstall -D -m 0644 src/services/units/watch.path \\
\t                   $(USER_UNITS)/rhizo-watch.path
\tinstall -D -m 0644 debian/dropins/root-paths.conf \\
\t                   $(UNITS)/rhizo-sys.service.d/10-root-paths.conf
\tinstall -D -m 0644 debian/dropins/user-paths.conf \\
\t                   $(UNITS)/rhizo-owned.service.d/10-user-paths.conf
"""


def selftest():
    """run the checker against fixture trees"""
    work = tempfile.mkdtemp(prefix="check-root-unit-paths.")
    failed = 0
    try:
        def write(rel, text):
            """write a fixture file under the work directory"""
            path = os.path.join(work, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)

        def reset():
            """rebuild the fixture tree with the default files"""
            shutil.rmtree(os.path.join(work, "src"), ignore_errors=True)
            shutil.rmtree(os.path.join(work, "debian"), ignore_errors=True)
            write("debian/rules", RULES_FIXTURE)
            write("src/services/units/sys.path", "[Path]\nPathExists=/run/rhizo-x/trigger\n")
            write("src/services/units/sys.service", "[Service]\nExecStart=/bin/true\n")
            write("src/services/units/owned.service", "[Service]\nUser=ubuntu\nExecStart=/bin/true\n")
            write("src/services/units/watch.path", "[Path]\nPathExistsGlob=/run/user/1000/wayland-*\n")

        def case(what, files, want):
            """check a fixture case names the wanted text"""
            nonlocal failed
            reset()
            for rel, text in files.items():
                write(rel, text)
            got, _ = check(work)
            hit = [g for g in got if want and want in g]
            if want is None and got:
                print("SELFTEST FAIL: %s: flagged %s" % (what, got))
                failed += 1
            elif want is not None and not hit:
                print("SELFTEST FAIL: %s: wanted a finding with %r, got %s" % (what, want, got))
                failed += 1

        case("the clean fixture passes, its user .path included", {}, None)
        case("a system .path watching /run/user/ is flagged",
             {"src/services/units/sys.path": "[Path]\nPathExistsGlob=/run/user/1000/wayland-*\n"},
             "sys.path:2: PathExistsGlob= names /run/user/1000/wayland-*, and PID 1 watches")
        case("a system .path watching /home/ is flagged",
             {"src/services/units/sys.path": "[Path]\nPathChanged=/home/u/Downloads\n"},
             "PathChanged= names /home/u/Downloads")
        case("a rootless ExecStart naming /run/user/ is flagged",
             {"src/services/units/sys.service":
              "[Service]\nExecStart=/bin/sh -c '\\\n  ls /run/user/1000'\n"},
             "sys.service:2: ExecStart= names /run/user/1000', and the unit has no User=")
        case("User=root is root",
             {"src/services/units/sys.service":
              "[Service]\nUser=root\nExecStart=/bin/ls /home/u\n"}, "runs as User=root")
        case("the same ExecStart under User=ubuntu passes",
             {"src/services/units/sys.service":
              "[Service]\nUser=ubuntu\nExecStart=/bin/sh -c 'ls /run/user/$(id -u)/wayland-1'\n"},
             None)
        case("a + prefix under User=ubuntu is flagged",
             {"src/services/units/sys.service":
              "[Service]\nUser=ubuntu\nExecStartPre=+/bin/test -S /run/user/1000/bus\n"},
             "its '+' prefix runs it with root")
        case("a ! prefix under User=ubuntu is flagged",
             {"src/services/units/sys.service":
              "[Service]\nUser=ubuntu\nExecStartPre=-!/bin/test -S /run/user/1000/bus\n"},
             "its '-!' prefix runs it with root")
        case("EnvironmentFile= under User=ubuntu is flagged",
             {"src/services/units/sys.service":
              "[Service]\nUser=ubuntu\nEnvironmentFile=/run/user/1000/session.env\n"},
             "EnvironmentFile= names /run/user/1000/session.env, and PID 1 resolves it")
        case("ConditionPathExists= is flagged",
             {"src/services/units/sys.service":
              "[Unit]\nConditionPathExists=/home/u/.config/x\n[Service]\nUser=ubuntu\n"},
             "ConditionPathExists= names /home/u/.config/x")
        case("ReadWritePaths= under User=ubuntu is flagged",
             {"src/services/units/sys.service":
              "[Service]\nUser=ubuntu\nReadWritePaths=/home/u/Downloads\n"},
             "ReadWritePaths= names /home/u/Downloads")
        case("a .socket listening in /run/user/ is flagged",
             {"src/services/units/sys.socket": "[Socket]\nListenStream=/run/user/1000/x.sock\n"},
             "ListenStream= names /run/user/1000/x.sock, and PID 1 binds")
        case("a comment naming /run/user/ passes",
             {"src/services/units/sys.service":
              "# PID 1 cannot read /run/user/1000\n[Service]\nExecStart=/bin/true\n"}, None)
        case("/run/user without a component and /var/home/ pass",
             {"src/services/units/sys.service":
              "[Service]\nExecStart=/bin/ls /run/user /var/home/x\n"}, None)
        case("a drop-in adding a rootless ExecStart to a system unit is flagged",
             {"debian/dropins/root-paths.conf": "[Service]\nExecStart=\nExecStart=/bin/ls /home/u\n"},
             "root-paths.conf (in rhizo-sys.service):3: ExecStart= names /home/u")
        case("a drop-in under a unit with User=ubuntu inherits it",
             {"debian/dropins/user-paths.conf": "[Service]\nExecStart=\nExecStart=/bin/ls /home/u\n"},
             None)
        case("a rig drop-in directory counts as the unit it names",
             {"src/services/units/run-x.mount.d/y.conf": "[Unit]\nConditionPathExists=/run/user/1000/z\n"},
             "y.conf (in run-x.mount):2: ConditionPathExists=")
        case("a heredoc unit an install script writes is flagged",
             {"src/install/prepare/x.sh": "cat > /etc/systemd/system/x.service <<'UNIT'\n[Service]\n"
                                    "ExecStart=/bin/ls /run/user/1000\nUNIT\n"},
             "src/install/prepare/x.sh:2 (heredoc):2: ExecStart= names /run/user/1000")
        case("a user unit debian/rules names that is not in the tree is flagged",
             {"debian/rules": RULES_FIXTURE.replace("src/services/units/watch.path", "src/services/units/gone.path")},
             "user-unit-missing: debian/rules installs rhizo-gone.path")
        case("the desktop-session .path shipped into $(UNITS) is flagged",
             {"debian/rules": RULES_FIXTURE.replace(
                 "src/services/units/watch.path \\\n\t                   $(USER_UNITS)/rhizo-watch.path",
                 "src/services/units/watch.path \\\n\t                   $(UNITS)/rhizo-watch.path")},
             "watch.path:2: PathExistsGlob= names /run/user/1000/wayland-*")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if failed:
        print("check-root-unit-paths selftest: FAILED (%d)" % failed)
        return 1
    print("check-root-unit-paths selftest: ok (a system .path, .socket, Condition*=, "
          "EnvironmentFile=, ReadWritePaths=, rootless or +/! Exec*=, drop-in and heredoc naming "
          "/run/user/ or /home/ are each flagged; the same under User=, in a user unit, in a "
          "comment, or on /run/user itself are not)")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    if sys.argv[1:]:
        print("usage: root-unit-paths.py [--selftest]", file=sys.stderr)
        sys.exit(2)
    sys.exit(run())
