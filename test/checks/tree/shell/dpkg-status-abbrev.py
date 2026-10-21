#!/usr/bin/env python3
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SITE = "db:Status-Abbrev"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
import unit_files  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
UNIT_DIRS = sorted({os.path.dirname(rel) for rel in unit_files.unit_files(REPO).values()})
TEST_DIRS = test_dirs(REPO)
SCAN_DIRS = (*TEST_DIRS, *TOOL_DIRS, "src/install", "src/androidd",
             "src/services", *UNIT_DIRS, "src/services/probe-client", "debian")
SCAN_FILES = ("test/checks/launcher/capabilities/capabilities.tsv", "test/system/cycle/claims.tsv",
              "test/checks/policy/access/host-desktop-access.tsv", "test/checks/policy/access/hotplug-access.tsv",
              "test/checks/launcher/instances/instances.tsv", "test/checks/policy/access/restart-access.tsv")
MIN_SCANNED = 700
SELF = os.path.abspath(__file__)
MAX_SOURCE = 2 * 1024 * 1024
WINDOW = 16

STATEMENT_FORMS = (
    re.compile(r"""tr -d ["']? ["']?\)"? *= *ii\b"""),
    re.compile(r"""substr\(\$2, *2, *1\)"""),
    re.compile(r"""\$1 *== *"ii \""""),
    re.compile(r"""\*"db:Status-Abbrev"\*\)"""),
)
PY_FORM = re.compile(r"abbrev\[1\]")
PY_RAW = re.compile(r"""(==|!=|\bin)\s*\(?\s*['"]ii['"]|startswith\(\s*['"]ii""")
ASSIGN = re.compile(r"^\s*(?:local\s+)?(\w+)=\$\(")
TR_TAIL = re.compile(r"""tr -d ["']? ["']?\)\s*"?\s*$""")

ABBREV_CASES = (("ii ", True), ("ii", False), ("iiR", False), ("iU ", False),
                ("rc ", False), ("hi ", False), ("ri ", False), (" ii", False), ("", False))


def source_files(root):
    """return the source files under the root"""
    seen = []
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            path = os.path.join(base, name)
            if (path in seen or os.path.islink(path) or not os.path.isfile(path)
                    or os.path.abspath(path) == SELF or os.path.getsize(path) > MAX_SOURCE):
                continue
            seen.append(path)
    for rel in SCAN_FILES:
        path = os.path.join(root, rel)
        if os.path.isfile(path) and path not in seen:
            seen.append(path)
    return seen


def function_index(root):
    """return the shell function bodies by name"""
    index = {}
    for path in source_files(root):
        if path.endswith(".py"):
            continue
        try:
            lines = open(path, encoding="utf-8").read().split("\n")
        except (UnicodeDecodeError, OSError):
            continue
        for i, l in enumerate(lines):
            m = re.match(r"^(\w+)\(\)\s*\{", l)
            if not m:
                continue
            body = []
            for b in lines[i + 1:]:
                if b.startswith("}"):
                    break
                body.append(unescape(b))
            rest = l[m.end():]
            if rest.strip():
                body.insert(0, rest.rsplit("}", 1)[0])
            index.setdefault(m.group(1), body)
    return index


def calls_with(l, name, index):
    """return the callee and argument position of each call to a name"""
    found = []
    for seg in re.split(r"&&|\|\||;|\||\bthen\b|\bif\b|\bwhile\b|!", l):
        try:
            words = shlex.split(seg, posix=True)
        except ValueError:
            continue
        if not words or words[0] not in index or words[0] == HELPER:
            continue
        for k, w in enumerate(words[1:], 1):
            if re.search(var_ref(name), w):
                found.append((words[0], k))
    return found


HELPER = "installer_abbrev_configured"
MAX_DEPTH = 3


def site_problems(root):
    """return the problems for status read sites that are not sanctioned"""
    problems = []
    index = function_index(root)
    for path in source_files(root):
            try:
                lines = open(path, encoding="utf-8").read().split("\n")
            except (UnicodeDecodeError, OSError):
                continue
            for i, line in enumerate(lines):
                if SITE not in line or line.lstrip().startswith("#"):
                    continue
                if path.endswith(".py"):
                    window = "\n".join(lines[i:i + WINDOW])
                    why = None if PY_FORM.search(window) and not PY_RAW.search(window) else "no abbrev[1] read"
                else:
                    why = shell_site_problem([unescape(l) for l in lines], i, index)
                if why:
                    problems.append("%s:%d: %s -- %s" % (os.path.relpath(path, root), i + 1, line.strip()[:160], why))
    return problems


def unescape(line):
    """return the line with the ssh escapes removed"""
    return line.replace('\\$', '$').replace('\\"', '"')


def statement_end(lines, i):
    """return the index after the end of a statement"""
    j = i
    while j < len(lines) - 1 and re.search(r"(\\|\||&&)\s*$", lines[j]):
        j += 1
    return j + 1


def var_ref(name):
    """return the regex matching a reference to a variable"""
    return r"\$\{?%s\b" % re.escape(name)


def shell_site_problem(lines, i, index):
    """return the problem with a shell read site, or None"""
    end = statement_end(lines, i)
    stmt = "\n".join(lines[i:end])
    if any(r.search(stmt) for r in STATEMENT_FORMS):
        return None
    m = ASSIGN.match(lines[i])
    if not m:
        return "no sanctioned form in the read's own statement"
    window = lines[end:end + WINDOW]
    for k, l in enumerate(window):
        a = ASSIGN.match(l) or re.match(r"^\s*(?:local\s+)?(\w+)=", l)
        if a and a.group(1) == m.group(1):
            window = window[:k]
            break
    sanctioned, raw = scan(window, m.group(1), bool(TR_TAIL.search(stmt)), index, 0)
    if raw:
        return "compares the field against a raw string: %s" % raw[0]
    if not sanctioned:
        return "%s is never read through a sanctioned form" % m.group(1)
    return None


def scan(lines, var, tr_form, index, depth):
    """return whether the variable has a sanctioned compare and the bad compares"""
    tracked = {var}
    for k, l in enumerate(lines):
        if re.search(r"done\s*<<<\s*\"?" + var_ref(var), l):
            for w in reversed(lines[:k]):
                r = re.search(r"\bwhile\b.*\bread\s+(?:-r\s+)?(\w+)\s*;?", w)
                if r:
                    tracked.add(r.group(1))
                    break
    sanctioned, raw = False, []
    in_case = False
    for l in lines:
        if in_case:
            if re.match(r"^\s*esac\b", l):
                in_case = False
                continue
            arm = re.match(r"^\s*\(?([^()]*?)\)", l)
            if arm and "ii" in arm.group(1):
                if re.fullmatch(r"""\s*(?:"ii "|'ii ')\s*""", arm.group(1)):
                    sanctioned = True
                else:
                    raw.append("case arm " + l.strip()[:80])
            continue
        refs = [t for t in tracked if re.search(var_ref(t), l)]
        if not refs:
            continue
        for t in refs:
            if re.search(r"\bcase\s+\"?" + var_ref(t), l):
                in_case = True
                continue
            if re.search(r"\b" + HELPER + r"\s+\"?" + var_ref(t), l):
                sanctioned = True
            for callee, pos in calls_with(l, t, index):
                if depth >= MAX_DEPTH:
                    continue
                ok, bad = scan(index[callee], str(pos), False, index, depth + 1)
                sanctioned = sanctioned or ok
                raw += ["%s: %s" % (callee, b) for b in bad]
            cmp = re.search(var_ref(t) + r"""[^}"\s]*\}?"?\s*(==|!=|=~|=)\s*([^\]&|;]*)""", l)
            if not cmp or "ii" not in cmp.group(2):
                continue
            if tr_form and t == var and cmp.group(1) in ("=", "==") and re.fullmatch(r'\s*"?ii"?\s*', cmp.group(2)):
                sanctioned = True
            else:
                raw.append(l.strip()[:80])
        a = re.match(r"^\s*(?:local\s+)?(\w+)=", l)
        if a:
            tracked.add(a.group(1))
        for extra in re.findall(r"\s(\w+)=\"?" + r"(?:%s)" % "|".join(var_ref(t) for t in refs), l):
            tracked.add(extra)
    return sanctioned, raw


def helper_problems(lib):
    """return the problems in installer_abbrev_configured's answers"""
    problems = []
    for abbrev, want in ABBREV_CASES:
        r = subprocess.run(["bash", "-c", 'source "$1" >/dev/null 2>&1; installer_abbrev_configured "$2"',
                            "x", lib, abbrev], capture_output=True, text=True)
        if r.returncode not in (0, 1):
            problems.append("installer_abbrev_configured did not run for %r: rc=%d %s"
                            % (abbrev, r.returncode, r.stderr.strip()[:160]))
        elif (r.returncode == 0) != want:
            problems.append("installer_abbrev_configured reads %r as %s" % (abbrev, "configured" if r.returncode == 0
                                                                             else "not configured"))
    return problems


def check(root):
    """return the problems from the site scan and the helper check"""
    return site_problems(root) + helper_problems(os.path.join(root, "test", "system", "lib", "installer-lib.sh"))


FIXED_LIB = r'''
installer_abbrev_configured() {
  [[ ${#1} -eq 3 && "${1:0:2}" == ii && "${1:2:1}" == " " ]]
}

lib_pkg_ready() {
  local want="$1" ab="$2"
  installer_abbrev_configured "$ab"
}

lib_abbrev_is_ii() {
  [[ "$1" == ii* ]]
}
'''

SANCTIONED_SITES = r'''
state=$(ssh_vm -t 20 "dpkg-query -W -f='\${Version}\t\${db:Status-Abbrev}' rhizo")
installer_abbrev_configured "${state#*$'\t'}" || fail "not configured"
[ "$(dpkg-query -W -f="\${db:Status-Abbrev}" $p 2>/dev/null | tr -d " ")" = ii ] || echo $p
st=\$(dpkg-query -W -f='\${db:Status-Abbrev}' \$p 2>/dev/null | tr -d ' ')
    if [ "\$st" = ii ]; then
have=$(dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n' \
    | awk -F'\t' 'substr($2, 2, 1) !~ /[nc]/ { print $1 }')
dpkg-query -W -f="\${db:Status-Abbrev}\t\${binary:Package}\n" | awk -F "\t" "\$1 == \"ii \" { print \$2 }"
        *"db:Status-Abbrev"*) printf 'rhizo=iU \nDONE\n' ;;
states=$(ssh_vm -t 30 "dpkg-query -W -f='\${Package}=\${db:Status-Abbrev}\n' rhizo 2>&1; echo DONE")
while IFS= read -r line; do
  [[ "$line" == DONE ]] && continue
  installer_abbrev_configured "${line#*=}" || unconf=1
done <<<"$states"
[[ "$states" != *$'\n'DONE ]] && fail "no DONE"
cs=$(dpkg-query -W -f='${db:Status-Abbrev}' rhizo)
case "$cs" in
  "ii ") pass ok ;;
  *) fail no ;;
esac
hs=$(dpkg-query -W -f='${db:Status-Abbrev}' rhizo)
lib_pkg_ready rhizo "$hs" || fail no
'''

BROKEN_SITES = (
    'n1=$(ssh_vm "dpkg-query -W -f=\'\\${Version} \\${db:Status-Abbrev}\' rhizo")\n'
    'if [[ "$n1" == "$v ii" ]]; then pass ok; fi\n',
    's=$(ssh_vm "dpkg-query -W -f=\'\\${Version} \\${db:Status-Abbrev}\' rhizo-addon")\n'
    'if [[ "$s" == *" ii" ]]; then pass ok; fi\n',
    'dpkg-query -W -f="\\${db:Status-Abbrev}\\t\\${binary:Package}\\n" | awk -F "\\t" "\\$1 ~ /^ii/ { print \\$2 }"\n',
    'a=$(ssh_vm "dpkg-query -W -f=\'\\${db:Status-Abbrev}\' rhizo")\n'
    'if [[ "$a" == ii ]]; then pass ok; fi\n'
    'b=$(ssh_vm "dpkg-query -W -f=\'\\${db:Status-Abbrev}\' rhizo-addon")\n'
    'installer_abbrev_configured "$b" && pass ok\n',
    'a=$(ssh_vm "dpkg-query -W -f=\'\\${db:Status-Abbrev}\' rhizo")\n'
    'installer_abbrev_configured "$a" || fail no\n'
    '[[ "$a" == *" ii" ]] && pass ok\n',
    'st=$(dpkg-query -W -f=\'${db:Status-Abbrev}\' rhizo)\n'
    '[ "$st" = ii ] || echo rhizo\n',
    'states=$(ssh_vm "dpkg-query -W -f=\'\\${Package}=\\${db:Status-Abbrev}\\n\' rhizo")\n'
    'while IFS= read -r line; do\n'
    '  [[ "${line#*=}" == ii* ]] || bad=1\n'
    'done <<<"$states"\n'
    'b=$(ssh_vm "dpkg-query -W -f=\'\\${db:Status-Abbrev}\' rhizo-addon")\n'
    'installer_abbrev_configured "$b" && pass ok\n',
    'st=$(dpkg-query -W -f=\'${db:Status-Abbrev}\' rhizo)\n'
    'case "$st" in\n'
    '  ii*) pass ok ;;\n'
    '  *) fail no ;;\n'
    'esac\n',
    'st=$(dpkg-query -W -f=\'${db:Status-Abbrev}\' rhizo)\n'
    'lib_abbrev_is_ii "$st" || fail no\n',
)

BROKEN_HELPERS = (
    ('[[ "${1// }" == ii ]]', "'ii'"),
    ('[[ "$1" == ii* ]]', "'iiR'"),
    ('[[ "${1:0:2}" == ii ]]', "'iiR'"),
)


def _tree(tmp, lib, sites):
    """write a fixture tree holding the library and the sites"""
    os.makedirs(os.path.join(tmp, "test", "system", "lib"))
    with open(os.path.join(tmp, "test", "system", "lib", "installer-lib.sh"), "w") as f:
        f.write(lib)
    with open(os.path.join(tmp, "test", "system", "x.sh"), "w") as f:
        f.write(sites)
    return tmp


def selftest():
    """check the sanctioned forms and each planted-defect form"""
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        got = check(_tree(tmp, FIXED_LIB, SANCTIONED_SITES))
    if got:
        print("SELFTEST FAILED: the sanctioned forms were refused: %s" % got, file=sys.stderr)
        failed = True
    for site in BROKEN_SITES:
        with tempfile.TemporaryDirectory() as tmp:
            got = check(_tree(tmp, FIXED_LIB, site))
        if not any("x.sh:1:" in p for p in got):
            print("SELFTEST FAILED: a raw compare was not refused: %r (got %s)" % (site, got), file=sys.stderr)
            failed = True
    for site, why in ((BROKEN_SITES[-2], "raw string: case arm ii*)"),
                      (BROKEN_SITES[-1], "raw string: lib_abbrev_is_ii:")):
        with tempfile.TemporaryDirectory() as tmp:
            got = check(_tree(tmp, FIXED_LIB, site))
        if not any(why in p for p in got):
            print("SELFTEST FAILED: %r was not refused as %r (got %s)" % (site, why, got), file=sys.stderr)
            failed = True
    for body, wrong in BROKEN_HELPERS:
        lib = FIXED_LIB.replace('[[ ${#1} -eq 3 && "${1:0:2}" == ii && "${1:2:1}" == " " ]]', body)
        with tempfile.TemporaryDirectory() as tmp:
            got = check(_tree(tmp, lib, ""))
        if not any("reads %s as" % wrong in p for p in got):
            print("SELFTEST FAILED: helper %r was not caught on %s (got %s)" % (body, wrong, got), file=sys.stderr)
            failed = True
    if failed:
        return 1
    print("selftest ok: passes every sanctioned form, refuses %d raw compares and %d helpers that misread "
          "the three-character field" % (len(BROKEN_SITES), len(BROKEN_HELPERS)))
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    problems = check(REPO)
    scanned = len(source_files(REPO))
    if scanned < MIN_SCANNED:
        problems.append("scanned %d files, expected at least %d" % (scanned, MIN_SCANNED))
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        print("check-dpkg-status-abbrev: read ${db:Status-Abbrev} as its three-character field "
              "(installer_abbrev_configured), never as a raw string")
        return 1
    print("check-dpkg-status-abbrev: every ${db:Status-Abbrev} read takes the field whole, and "
          "installer_abbrev_configured accepts only 'ii '")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
