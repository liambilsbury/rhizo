#!/usr/bin/env python3
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import install_dirs  # noqa: E402
import unit_files as tree_units  # noqa: E402
UNIT_SUFFIXES = (".service", ".path", ".timer", ".socket")
GLOBS = ["src/services/**/*" + s for s in UNIT_SUFFIXES] + ["src/services/**/*.d/*.conf", "debian/dropins/*.conf"]
RULES = os.path.join(ROOT, "debian", "rules")
INSTALL_RE = re.compile(r'install\s[^\n]*?(\S+\.conf)\s*\\\s*\n\s*"?([^"\s]+)"?\s*$', re.M)

MEANING = {"s": "the user's shell", "h": "the user's home", "u": "the user name",
           "U": "the user id", "d": "the credentials directory", "g": "the group",
           "G": "the group id", "H": "the host name", "t": "the runtime root",
           "n": "the full unit name", "N": "the unit name without its suffix",
           "p": "the unit prefix", "f": "the unescaped instance/prefix path",
           "x": "unknown -- systemd refuses the unit"}
TEMPLATE_ONLY = {"i", "I"}
PREFIX_ONLY = {"j"}
PREFIX_DIR_RE = re.compile(r"-\.[a-z]+\.d/[^/]+$")
BRACE_RE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(:[-+]|\})")


def logical_lines(text):
    """return directives with continuation lines joined"""
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


def dropin_targets(rules_text):
    """map drop-in sources to install destinations"""
    targets = {}
    for m in INSTALL_RE.finditer(rules_text):
        targets.setdefault(m.group(1), []).append(m.group(2))
    return targets


def is_template(name, targets):
    """test for a template unit"""
    if name.endswith(".conf"):
        dests = targets.get(name, [])
        return bool(dests) and all("@." in d for d in dests)
    return "@" in os.path.basename(name)


def is_prefix_dropin(name, targets):
    """test for a prefix drop-in"""
    if not name.endswith(".conf"):
        return False
    dests = targets.get(name, [])
    return bool(dests) and all(PREFIX_DIR_RE.search(d) for d in dests)


HEREDOC_SOURCES = [os.path.join(d, "*.sh") for d in install_dirs(ROOT)] + [
    "debian/*.postinst", "debian/*.preinst", "debian/*.prerm", "debian/*.postrm.in"]
HEREDOC_RE = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
SECTION_RE = re.compile(r"^\[(Unit|Service|Install|Path|Timer|Socket|Mount)\]\s*$", re.M)
EXEC_SECTIONS = ("[Service]", "[Socket]", "[Mount]", "[Swap]")


def heredoc_units(text):
    """return the unit text bodies from heredocs"""
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = HEREDOC_RE.search(line)
        if not m or line.lstrip().startswith("#"):
            continue
        strip, quoted, delim = m.group(1) == "-", bool(m.group(2)), m.group(3)
        body = []
        for j in range(i + 1, len(lines)):
            end = lines[j].lstrip("\t") if strip else lines[j]
            if end == delim:
                break
            body.append(lines[j])
        text_body = "\n".join(body)
        if SECTION_RE.search(text_body):
            out.append((i + 2, text_body, quoted))
    return out


def check_text(name, text, targets=None, brace_check=True):
    """return findings for a unit file"""
    findings = []
    template = is_template(name, targets or {})
    prefix = is_prefix_dropin(name, targets or {})
    section = None
    for lineno, line in logical_lines(text):
        if line.lstrip().startswith("["):
            section = line.strip()
            continue
        key = line.split("=", 1)[0].strip()
        if key.startswith("Exec") and section is not None and section not in EXEC_SECTIONS:
            findings.append(f"{name}:{lineno}: {key}= sits in {section}, where systemd ignores it as an "
                            f"unknown key -- it belongs in [Service]")
        i = 0
        while i < len(line):
            if line[i] != "%":
                i += 1
                continue
            nxt = line[i + 1] if i + 1 < len(line) else ""
            if nxt == "%":
                i += 2
                continue
            if nxt in TEMPLATE_ONLY and template:
                i += 2
                continue
            if nxt in PREFIX_ONLY and prefix:
                i += 2
                continue
            what = MEANING.get(nxt, "a systemd specifier" if nxt.isalpha() else "an invalid specifier")
            findings.append(f"{name}:{lineno}: {key}= has a bare %{nxt}, which systemd replaces with {what} "
                            f"before the command runs -- write %%{nxt} for a literal")
            i += 2
        if brace_check and key.startswith("Exec"):
            for m in BRACE_RE.finditer(line):
                var = m.group(1)
                findings.append(f"{name}:{lineno}: {key}= has ${{{var}...}}, which systemd resolves from the "
                                f"unit's environment before sh runs -- write $${{{var}...}} for the script's own variable")
    return findings


def unit_files():
    """return the unit files matching the globs"""
    files = tree_units.unit_paths(ROOT, UNIT_SUFFIXES) + tree_units.dropin_paths(ROOT)
    files += glob.glob(os.path.join(ROOT, "debian/dropins/*.conf"))
    return sorted(files)


def run():
    """check every unit file for specifiers and print the problems"""
    files = unit_files()
    if not files:
        print("check-unit-specifiers: FAIL -- no unit files found under " + ", ".join(GLOBS), file=sys.stderr)
        return 1
    with open(RULES, encoding="utf-8") as fh:
        targets = dropin_targets(fh.read())
    bad = []
    for f in files:
        with open(f, encoding="utf-8") as fh:
            bad += check_text(os.path.relpath(f, ROOT), fh.read(), targets)
    ndocs = 0
    for g in HEREDOC_SOURCES:
        for f in sorted(glob.glob(os.path.join(ROOT, g))):
            with open(f, encoding="utf-8") as fh:
                for lineno, body, quoted in heredoc_units(fh.read()):
                    ndocs += 1
                    name = "%s:%d (heredoc)" % (os.path.relpath(f, ROOT), lineno)
                    bad += check_text(name, body, targets, brace_check=quoted)
    for b in bad:
        print("FAIL: " + b, file=sys.stderr)
    if bad:
        return 1
    print(f"check-unit-specifiers: {len(files)} unit files and {ndocs} heredoc unit(s), "
          f"no bare specifier, unescaped ${{...}} or Exec*= key outside its section")
    return 0


def selftest():
    """test the unit specifier checks"""
    cases = [
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'printf \"X=%s\\n\" \"$Y\"'\n", True, "bare %s in ExecStart"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'printf \"X=%%s\\n\" \"$Y\"'\n", False, "%%s escaped"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c '\\\n  set -eu; \\\n  printf \"H=%s\" x'\n", True,
         "bare %s on a continuation line"),
        ("a.service", "[Service]\n# printf %s in a comment\nExecStart=/bin/true\n", False, "comment ignored"),
        ("a@.service", "[Service]\nEnvironmentFile=-/etc/x/%i.env\n", False, "%i in a template"),
        ("a.service", "[Service]\nEnvironmentFile=-/etc/x/%i.env\n", True, "%i outside a template"),
        ("a.service", "[Service]\nExecStartPost=/bin/sh -c 'printf \"k=%d\" 1'\n", True, "bare %d"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'H=1; echo \"${H:-x}\"'\n", True, "${H:-x} in ExecStart"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'H=1; echo \"$${H:-x}\"'\n", False, "$${H:-x} escaped"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'echo ${H}'\n", True, "${H} in ExecStart"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'echo \"$H $(id -u)\"'\n", False, "braceless $H left alone"),
        ("a.service", "[Service]\nEnvironment=A=${B}\n", False, "${} outside Exec is not this checker's"),
        ("a.service", "[Unit]\nExecCondition=/bin/false\n\n[Service]\nExecStart=/bin/true\n", True,
         "ExecCondition in [Unit]"),
        ("a.service", "[Unit]\nDescription=x\n\n[Service]\nExecCondition=/bin/false\nExecStart=/bin/true\n", False,
         "ExecCondition in [Service]"),
        ("a.socket", "[Socket]\nListenStream=/run/x\nExecStartPre=/bin/true\n", False, "ExecStartPre in [Socket]"),
        ("a.path", "[Path]\nPathExists=/x\nExecStart=/bin/true\n", True, "ExecStart in [Path]"),
    ]
    rules = ('\tinstall -D -m 0644 debian/dropins/t.conf \\\n'
             '\t                   "$(UNITS)/x@.service.d/10-t.conf"\n'
             '\tinstall -D -m 0644 debian/dropins/p.conf \\\n'
             '\t                   $(UNITS)/x.service.d/10-p.conf\n')
    rules += ('\tinstall -D -m 0644 debian/dropins/both.conf \\\n'
              '\t                   $(UNITS)/x.service.d/10-b.conf\n'
              '\tinstall -D -m 0644 debian/dropins/both.conf \\\n'
              '\t                   "$(UNITS)/x@.service.d/10-b.conf"\n')
    rules += ('\tinstall -D -m 0644 debian/dropins/s.conf \\\n'
              '\t                   "$(UNITS)/session-.scope.d/10-s.conf"\n'
              '\tinstall -D -m 0644 debian/dropins/q.conf \\\n'
              '\t                   $(UNITS)/x.service.d/10-q.conf\n')
    targets = dropin_targets(rules)
    cases += [
        ("debian/dropins/t.conf", "[Service]\nStandardOutput=append:/var/log/x-%i.log\n", False,
         "%i in a drop-in debian/rules installs under a template's .d/"),
        ("debian/dropins/p.conf", "[Service]\nStandardOutput=append:/var/log/x-%i.log\n", True,
         "%i in a drop-in for a plain unit"),
        ("debian/dropins/both.conf", "[Service]\nStandardOutput=append:/var/log/x-%i.log\n", True,
         "%i in a drop-in installed under a plain unit AND a template (template last)"),
        ("debian/dropins/a@b.conf", "[Service]\nStandardOutput=append:/var/log/x-%i.log\n", True,
         "%i in a drop-in whose own file name has '@' but no template destination"),
        ("debian/dropins/s.conf", "[Unit]\nWants=y@%j.service\n", False,
         "%j in a drop-in debian/rules installs under a prefix drop-in dir"),
        ("debian/dropins/q.conf", "[Unit]\nWants=y@%j.service\n", True,
         "%j in a drop-in for a plain unit"),
        ("debian/dropins/s.conf", "[Unit]\nWants=y@%i.service\n", True,
         "%i in a prefix drop-in, which names no instance"),
        ("a.scope", "[Unit]\nWants=y@%j.service\n", True, "%j in a unit file"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'a; \\\n  # note\n  echo ${H}'\n", True,
         "${H} after a comment line inside a continuation"),
        ("a.service", "[Service]\nExecStart=/bin/sh -c 'a; \\\n  ; note\n  [ -e /x ] && printf \"k=%s\" 1'\n",
         True, "%s after a ; comment inside a continuation, on a line starting with ["),
    ]
    heredoc_script = ("cat > /etc/systemd/system/x.service <<'UNIT'\n[Unit]\nDescription=x\n\n[Service]\n"
                      "ExecStart=/bin/sh -c 'printf \"%s\" 1'\nUNIT\n"
                      "cat > /etc/default/grub.d/x.cfg <<EOF\nGRUB_CMDLINE_LINUX=\"%s ${A}\"\nEOF\n")
    docs = heredoc_units(heredoc_script)
    if len(docs) != 1 or not check_text("h", docs[0][1], targets, brace_check=docs[0][2]):
        failed_docs = True
    else:
        failed_docs = False
    failed = 0
    for name, text, expect, what in cases:
        got = bool(check_text(name, text, targets))
        if got != expect:
            failed += 1
            print(f"SELFTEST FAIL: {what}: expected {'a finding' if expect else 'clean'}, got "
                  f"{'a finding' if got else 'clean'}", file=sys.stderr)
    refresh = "src/services/units/boot/kernel-refresh.service"
    cond = "ExecCondition=/usr/lib/rhizo/install/prepare/kernel-changed.sh\n"
    with open(os.path.join(ROOT, refresh), encoding="utf-8") as fh:
        text = fh.read()
    if cond not in text or "\n[Service]\n" not in text:
        failed += 1
        print(f"SELFTEST FAIL: {refresh} no longer carries {cond!r} to plant against", file=sys.stderr)
    elif check_text(refresh, text):
        failed += 1
        print(f"SELFTEST FAIL: the real {refresh} is not clean", file=sys.stderr)
    elif not check_text(refresh, text.replace(cond, "", 1).replace("\n[Service]\n", "\n" + cond + "\n[Service]\n", 1)):
        failed += 1
        print(f"SELFTEST FAIL: {refresh} with its ExecCondition planted back under [Unit] was reported clean",
              file=sys.stderr)
    for rel, good, bad_form in [
        ("src/services/units/session/desktop-session.service", 'printf "HOME=%%s\\n"', 'printf "HOME=%s\\n"'),
        ("src/services/units/session/desktop-session.service", '"$${HOME_DIR:-/home/rhizo}"', '"${HOME_DIR:-/home/rhizo}"'),
        ("src/services/units/boot/prepare.service", "kernel=%%s", "kernel=%s"),
    ]:
        with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
            text = fh.read()
        if good not in text:
            failed += 1
            print(f"SELFTEST FAIL: {rel} no longer carries {good!r} to plant against", file=sys.stderr)
            continue
        if check_text(rel, text):
            failed += 1
            print(f"SELFTEST FAIL: the real {rel} is not clean", file=sys.stderr)
        if not check_text(rel, text.replace(good, bad_form, 1)):
            failed += 1
            print(f"SELFTEST FAIL: {rel} with {bad_form!r} planted back was reported clean", file=sys.stderr)
    if failed_docs:
        failed += 1
        print("SELFTEST FAIL: a quoted heredoc unit with a bare %s was not found and flagged "
              "(or the grub heredoc was read as a unit)", file=sys.stderr)
    if failed:
        print(f"check-unit-specifiers --selftest: {failed} case(s) FAILED", file=sys.stderr)
        return 1
    print(f"check-unit-specifiers --selftest: OK ({len(cases)} fixtures + 4 planted real defects)")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else run())
