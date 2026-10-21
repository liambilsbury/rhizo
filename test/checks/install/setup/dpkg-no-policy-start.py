#!/usr/bin/env python3
import glob
import importlib.util
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "tools", "build", "packaging", "deb")))
import maint_inline  # noqa: E402
import deb_unit_lists  # noqa: E402
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402

FORBIDDEN = ("androidd.service", "rhizo-prepare.service", "rhizo-policy.service")
BOOT_TARGETS = {"multi-user.target", "graphical.target", "default.target", "basic.target",
                "sysinit.target", "sockets.target", "paths.target", "timers.target",
                "getty.target"}
MAINT_SCRIPTS = ("preinst", "postinst", "prerm", "postrm")
START_VERBS = {"start", "restart", "try-restart", "reload-or-restart", "try-reload-or-restart",
               "isolate"}
NOW_VERBS = {"enable", "reenable"}
VALUE_OPTS = {"-t", "--type", "-p", "--property", "-H", "--host", "-M", "--machine", "--root",
              "--state", "-n", "--lines", "-o", "--output", "-s", "--signal", "--kill-whom",
              "--job-mode"}
PULL_KEYS = ("Wants", "Requires", "BindsTo", "Upholds")
UNIT_RE = re.compile(r"^[A-Za-z0-9_.@:\\-]+\.(?:service|socket|path|timer|target|mount)$")
SRC_UNIT_RE = re.compile(r"^src/services/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.@-]+\.(?:service|socket|path|timer)$")
PUNCT = set("();<>|&\n")
PREFIX_WORDS = {"if", "then", "do", "else", "elif", "while", "until", "!", "exec", "command",
                "time", "{"}
UNRESOLVED = "<unresolved>"


def _load(name, filename):
    """return a module loaded from a file next to this check"""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SBO = _load("check_setup_boot_order", "setup-boot-order.py")


class CheckError(Exception):
    pass


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def _recipe(rules_text, target):
    """return the recipe of a make target"""
    m = re.search(r"^%s\s*:[^\n]*\n((?:\t[^\n]*\n|#[^\n]*\n|[ \t]*\n|"
                  r"(?:ifeq|ifneq|ifdef|ifndef|else|endif)\b[^\n]*\n)*)" % re.escape(target),
                  rules_text, re.M)
    return m.group(1).replace("\\\n", " ") if m else ""


def unit_layout(rules_text):
    """return the installed units from override_dh_auto_install"""
    out = {}
    for line in _recipe(rules_text, "override_dh_auto_install").splitlines():
        toks = line.split()
        if not toks or toks[0] != "install":
            continue
        dest = toks[-1].strip('"')
        scope = "user" if "$(USER_UNITS)" in dest else "system" if "$(UNITS)" in dest else None
        if scope is None:
            continue
        for src in toks[1:-1]:
            if SRC_UNIT_RE.match(src):
                name = os.path.basename(src) if dest.endswith("/") else os.path.basename(dest)
                out[name] = (src, scope)
    return out


def _package(control_text):
    """return the package name from the control file text"""
    m = re.search(r"^Package:\s*(\S+)", control_text, re.M)
    if not m:
        raise CheckError("debian/control names no Package:")
    return m.group(1)


def dh_generated(root, rules_text, layout):
    """return the maintainer script text from dh_installsystemd"""
    tmp = tempfile.mkdtemp(prefix="check-dpkg-no-policy-start.")
    try:
        deb = os.path.join(tmp, "debian")
        os.makedirs(deb)
        for f in ("control", "changelog"):
            shutil.copy(os.path.join(root, "debian", f), deb)
        with open(os.path.join(deb, "rules"), "w") as f:
            f.write(rules_text)
        pkg = _package(read(os.path.join(deb, "control")))
        for name, (src, scope) in layout.items():
            d = os.path.join(deb, pkg, "usr", "lib", "systemd", scope)
            os.makedirs(d, exist_ok=True)
            shutil.copy(os.path.join(root, src), os.path.join(d, name))
        if re.search(r"^override_dh_installsystemd\s*:", rules_text, re.M):
            cmd = ["make", "-s", "-f", "debian/rules", "override_dh_installsystemd"]
        else:
            cmd = ["dh_installsystemd"]
        for tool in set([cmd[0], "dh_installsystemd"]):
            if not shutil.which(tool):
                raise CheckError("%s is not installed -- cannot run the package's own step, so no "
                                 "verdict" % tool)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("MAKE", "MFLAGS", "DH_"))}
        r = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True, env=env)
        if r.returncode != 0:
            raise CheckError("`%s` failed (rc=%d): %s" % (" ".join(cmd), r.returncode,
                                                          (r.stderr or r.stdout).strip()[-400:]))
        out = {}
        for script in MAINT_SCRIPTS:
            parts = []
            p = os.path.join(deb, "%s.%s.debhelper" % (pkg, script))
            if os.path.exists(p):
                parts.append(read(p))
            for g in sorted(glob.glob(os.path.join(deb, ".debhelper", "generated", pkg,
                                                   script + ".*"))):
                parts.append(read(g))
            out[script] = "\n".join(parts)
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def unit_lists(postinst):
    """return the pacman package unit lists"""
    lists, problems = deb_unit_lists.unit_lists(postinst)
    return {deb_unit_lists.LIST_PATHS[k]: v for k, v in lists.items() if v}, problems


def rules_site_problems(rules_text):
    """return the debian/rules dh_installsystemd problems"""
    problems = []
    for m in re.finditer(r"^(execute_(?:before|after)_dh_installsystemd)\s*:", rules_text, re.M):
        problems.append("debian/rules has %s, which this check does not run" % m.group(1))
    for target in re.findall(r"^([A-Za-z0-9_%.-]+)\s*:(?!=)", rules_text, re.M):
        if target != "override_dh_installsystemd" and \
                re.search(r"\bdh_installsystemd\b", _recipe(rules_text, target)):
            problems.append("debian/rules' %s runs dh_installsystemd, and this check runs only "
                            "override_dh_installsystemd" % target)
    return problems


def _split(values):
    """return the words of every value"""
    return [u for v in values for u in v.split()]


def _triggered(name, d):
    """return the units a unit would start when triggered"""
    base = name.rsplit(".", 1)[0]
    if name.endswith((".path", ".timer")):
        return _split(d.get("Unit", [])) or [base + ".service"]
    if name.endswith(".socket"):
        if (d.get("Accept") or ["no"])[-1].lower() in ("yes", "true", "1", "on"):
            return []
        return _split(d.get("Service", [])) or [base + ".service"]
    return []


def _forbidden(name):
    """return whether a unit must never be started by dpkg"""
    return name in FORBIDDEN or name.startswith("androidd@")


def _installed_into(units):
    """return the units enabled into each unit"""
    out = {}
    for name, d in units.items():
        for t in _split(d.get("WantedBy", []) + d.get("RequiredBy", []) + d.get("UpheldBy", [])):
            out.setdefault(t, []).append(name)
    return out


def _template(name):
    """return the template name for an instance"""
    m = re.fullmatch(r"([^@/]+)@[^/]*(\.[a-z]+)", name)
    return m.group(1) + "@" + m.group(2) if m else name


def _name(units, name):
    """return the unit name or template name"""
    if name in units:
        return name
    t = _template(name)
    return t if t in units else name


def _definition(units, name):
    """return a unit's merged directives"""
    d, t = units.get(name, {}), _template(name)
    if t == name or t not in units:
        return d
    merged = {k: list(v) for k, v in units[t].items()}
    for k, v in d.items():
        merged.setdefault(k, []).extend(v)
    return merged


def _successors(units, into, u):
    """return the successor units of a unit"""
    d = _definition(units, u)
    nxt = [x for k in PULL_KEYS + ("OnSuccess", "OnFailure", "Also") for x in _split(d.get(k, []))]
    nxt += _triggered(u, d)
    nxt += into.get(u, []) + (into.get(_template(u), []) if _template(u) != u else [])
    return [_name(units, x) for x in nxt]


def _pull_kinds(units, into, a, b):
    """return the pull kinds from a to b"""
    d = _definition(units, a)
    kinds = ["%s=%s" % (k, b) for k in PULL_KEYS + ("OnSuccess", "OnFailure", "Also")
             if b in [_name(units, x) for x in _split(d.get(k, []))]]
    if b in [_name(units, x) for x in _triggered(a, d)]:
        kinds.append("triggering %s" % b)
    if b in [_name(units, x) for x in into.get(a, []) + into.get(_template(a), [])]:
        kinds.append("%s enabled into %s" % (b, a))
    return ", ".join(kinds) or "?"


def pull_path(units, start, want=_forbidden):
    """return the pull chain to a forbidden unit"""
    into = _installed_into(units)
    prev, todo = {start: None}, [start]
    while todo:
        u = todo.pop(0)
        if want(u):
            chain = []
            while u is not None:
                chain.append(u)
                u = prev[u]
            return chain[::-1]
        for v in _successors(units, into, u):
            if v not in prev:
                prev[v] = u
                todo.append(v)
    return None


def boot_pull_problems(units):
    """return the problems for units that boot targets pull in"""
    problems = []
    for name in sorted(units):
        d = units[name]
        targets = set(_split(d.get("WantedBy", []))) | set(_split(d.get("RequiredBy", [])))
        hit = sorted(targets & BOOT_TARGETS)
        if not hit:
            continue
        chain = pull_path(units, name, lambda u: u == "androidd.service" or u.startswith("androidd@"))
        if chain:
            problems.append("%s pulls %s at every boot (%s)" %
                            (" and ".join(hit), chain[-1], " -> ".join([hit[0]] + chain)))
    return problems


def reverse_pull_problems(units):
    """return reverse pull problems for androidd.service"""
    into = _installed_into(units)
    is_androidd = lambda u: u == "androidd.service"  # noqa: E731
    problems = []

    def who(u):
        """return the unit name for a report"""
        return "%s (every androidd@<id>)" % u if u == "androidd@.service" else u

    for root in sorted(set(u for u in units if u.startswith("androidd@")) | {"androidd@.service"}):
        chain = pull_path(units, root, is_androidd)
        if chain:
            problems.append("%s reaches androidd.service (%s, by %s) "
                            "-- no androidd@ instance may pull instance 0"
                            % (who(root), " -> ".join(chain), _pull_kinds(units, into, *chain[-2:])))
    for u in sorted(units):
        chain = None if is_androidd(u) else pull_path(units, u, is_androidd)
        if not chain:
            continue
        pullers = [p for p in set(units) | set(into) if p != u and u in _successors(units, into, p)]
        for puller in sorted(set(pullers) - {"androidd.service"}):
            problems.append("%s pulls %s, which reaches androidd.service (%s, by %s), so starting %s "
                            "starts instance 0's sandbox -- only androidd.service may pull a unit "
                            "that reaches it" % (who(puller), u, " -> ".join(chain),
                                                 _pull_kinds(units, into, *chain[-2:]), puller))
    return problems


def _logical(text):
    """return logical lines and their line numbers"""
    out, starts, heredoc, pending, first = [], [], None, "", None
    for n, line in enumerate(text.split("\n"), 1):
        if heredoc is not None:
            if line.strip() == heredoc[0]:
                heredoc = None
            continue
        if first is None:
            first = n
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        full = pending + line
        pending = ""
        if "<<" in full:
            try:
                toks = _lex(full)
            except ValueError:
                toks = []
            for k, t in enumerate(toks[:-1]):
                if t == "<<":
                    heredoc = (toks[k + 1].lstrip("-"), n)
        out.append(full)
        starts.append(first)
        first = None
    if heredoc is not None:
        raise CheckError("line %d opens a heredoc <<%s that never ends" % (heredoc[1], heredoc[0]))
    return out, starts


def _lex(buf):
    """return the shell tokens of a text"""
    lex = shlex.shlex(buf, posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.commenters = "#"
    lex.wordchars += "$@{}[]:=,.-/+%*~^!?"
    return list(lex)


def _strip_prefix(toks):
    """drop keywords and assignments from a command"""
    rest = list(toks)
    while rest and (rest[0] in PREFIX_WORDS or re.fullmatch(r"[A-Za-z_]\w*=.*", rest[0], re.S)):
        rest.pop(0)
    return rest


def _substitutions(tok):
    """return the substitution commands in a token"""
    out, i = [], 0
    while True:
        i = tok.find("$(", i)
        if i < 0:
            break
        if tok.startswith("$((", i):
            i += 3
            continue
        depth, j = 1, i + 2
        while j < len(tok) and depth:
            depth += {"(": 1, ")": -1}.get(tok[j], 0)
            j += 1
        out.append(tok[i + 2:j - 1] if depth == 0 else tok[i + 2:])
        i = j
    parts = tok.split("`")
    out += parts[1::2]
    return out


def _nested(toks):
    """return script text nested in a command"""
    out = [s for t in toks for s in _substitutions(t)]
    for k, t in enumerate(toks[:-1]):
        if os.path.basename(t) in ("sh", "bash", "dash") and re.fullmatch(r"-\w*c\w*", toks[k + 1]) \
                and k + 2 < len(toks):
            out.append(toks[k + 2])
    if toks and toks[0] == "eval":
        out.append(" ".join(toks[1:]))
    return out


def segments(text, depth=0, redirects=False):
    """return the commands of a script"""
    lines, starts = _logical(text)
    segs, i = [], 0
    while i < len(lines):
        j, buf = i, lines[i]
        while True:
            try:
                toks = _lex(buf)
                break
            except ValueError:
                j += 1
                if j >= len(lines):
                    raise CheckError("line %d opens a quote that never closes" % starts[i])
                buf += "\n" + lines[j]
        cur = []
        for tok in toks + [";"]:
            if tok and set(tok) <= PUNCT and not (redirects and set(tok) & set("<>")):
                if cur:
                    segs.append((starts[i], cur))
                    if depth < 4:
                        for inner in _nested(cur):
                            try:
                                segs += [(starts[i], t) for _, t in segments(inner, depth + 1, redirects)]
                            except CheckError:
                                segs.append((starts[i], inner.split()))
                cur = []
            else:
                cur.append(tok)
        i = j + 1
    return segs


def _function_spans(text):
    """return the top-level functions with their line spans"""
    lines, spans, i = text.split("\n"), [], 0
    while i < len(lines):
        m = re.match(r"([A-Za-z_][\w.-]*)\(\)\s*\{(.*)$", lines[i])
        if not m:
            i += 1
            continue
        rest = re.sub(r"\s+#.*$", "", m.group(2)).rstrip()
        if rest.endswith("}"):
            spans.append((m.group(1), rest[:-1], i, i))
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != "}":
            j += 1
        spans.append((m.group(1), "\n".join(lines[i + 1:j]), i, j))
        i = j + 1
    return spans


def function_bodies(text):
    """return the body of every function in a script"""
    return {name: body for name, body, _, _ in _function_spans(text)}


def _outside_functions(text):
    """return the script text with the function bodies blanked"""
    lines = text.split("\n")
    for _, _, a, b in _function_spans(text):
        lines[a:b + 1] = [""] * (b + 1 - a)
    return "\n".join(lines)


ASSIGN_ARR = re.compile(r"(?m)^[ \t]*(?:(?:local|declare|readonly|export|typeset)(?:[ \t]+-\w+)*"
                        r"[ \t]+)?([A-Za-z_]\w*)=\(([^)]*)\)")
ASSIGN = re.compile(r"(?m)(?:^[ \t]*|[;&|][ \t]*|\b(?:then|do|else)[ \t]+)"
                    r"(?:(?:local|declare|readonly|export|typeset)(?:[ \t]+-\w+)*[ \t]+)?"
                    r"([A-Za-z_]\w*)=(\"[^\"\n]*\"|'[^'\n]*'|[^\s;&|()]*)")
FOR = re.compile(r"(?m)\bfor[ \t]+([A-Za-z_]\w*)[ \t]+in[ \t]+([^;\n]*)")


LIST_LOOP = re.compile(r"\bwhile[ \t]+read[ \t]+(?:-r[ \t]+)?([A-Za-z_]\w*)[ \t]*;[ \t]*do\b"
                       r"(?:(?!\bdone\b).)*\bdone[ \t]*<[ \t]*(\"[^\"\n]*\"|[^\s;]+)", re.S)


def variables(text, lists=None):
    """return the words assigned to each variable"""
    out = {}

    def words(s):
        """return the words of a shell string, or an unresolved marker"""
        try:
            return shlex.split(s, comments=True)
        except ValueError:
            return [UNRESOLVED]
    for m in ASSIGN_ARR.finditer(text):
        out.setdefault(m.group(1), []).extend(words(m.group(2)))
    for m in ASSIGN.finditer(text):
        if text[m.end():m.end() + 1] == "(":
            if m.group(2).endswith("$"):
                out.setdefault(m.group(1), []).append(UNRESOLVED)
            continue
        out.setdefault(m.group(1), []).extend(words(m.group(2)) or [""])
    for m in FOR.finditer(text.replace("\\\n", " ")):
        out.setdefault(m.group(1), []).extend(words(m.group(2)))
    bound = {}
    if lists:
        plain = Scope(dict(out), dict(out))
        for m in LIST_LOOP.finditer(text):
            vals = expand(m.group(2).strip('"'), plain)
            if len(vals) == 1 and vals[0] in lists:
                bound.setdefault(m.group(1), []).append(lists[vals[0]])
    reads = {}
    for _, toks in segments(text):
        rest = _strip_prefix(toks)
        if rest and rest[0] in ("read", "mapfile", "readarray"):
            names, skip = [], False
            for t in rest[1:]:
                if skip:
                    skip = False
                elif re.fullmatch(r"-[A-Za-z]*[pdtunNCc]", t):
                    skip = True
                elif re.fullmatch(r"[A-Za-z_]\w*", t):
                    names.append(t)
            for name in names:
                reads[name] = reads.get(name, 0) + 1
        elif rest and rest[0] == "printf" and "-v" in rest[:-1]:
            out.setdefault(rest[rest.index("-v") + 1], []).append(UNRESOLVED)
    for name, n in reads.items():
        if len(bound.get(name, [])) == n:
            out.setdefault(name, []).extend(u for units in bound[name] for u in units)
        else:
            out.setdefault(name, []).append(UNRESOLVED)
    return out


class Scope:
    def __init__(self, local, glob_):
        """keep the local and global variable scopes"""
        self.local, self.glob = local, glob_

    def lookup(self, name):
        """return the value of a variable"""
        return self.local.get(name) or self.glob.get(name) or []


def expand(word, scope, depth=0):
    """return the expansions of a shell word"""
    if "$" not in word and "`" not in word:
        return [word]
    if depth > 6 or "$(" in word or "`" in word:
        return [UNRESOLVED]
    m = re.fullmatch(r"\$\{?([A-Za-z_]\w*)(?:\[[@*]\])?\}?", word)
    d = re.fullmatch(r"\$\{([A-Za-z_]\w*):?-([^}]*)\}", word)
    if m or d:
        name = (m or d).group(1)
        vals = scope.lookup(name) or ([d.group(2)] if d else [])
        if not vals:
            return [UNRESOLVED]
        return [x for v in vals for x in expand(v, scope, depth + 1)]
    parts = re.split(r"(\$\{?[A-Za-z_]\w*\}?)", word)
    combos = [""]
    for part in parts:
        if part.startswith("$"):
            vals = [x for x in expand(part, scope, depth + 1)]
            if UNRESOLVED in vals or "$" in part[1:].strip("{}"):
                return [UNRESOLVED]
            combos = [c + v for c in combos for v in vals][:64]
        elif "$" in part:
            return [UNRESOLVED]
        else:
            combos = [c + part for c in combos]
    return combos


def _invocation(args, scope):
    """parse the options of a systemctl call"""
    user, now, pos, i = False, False, [], 0
    while i < len(args):
        a = args[i]
        if a in ("--user", "--global"):
            user = True
        elif a == "--now":
            now = True
        elif a.startswith("-"):
            if a in VALUE_OPTS:
                i += 1
        else:
            pos.append(a)
        i += 1
    if not pos:
        return None
    return user, set(expand(pos[0], scope)), now, pos[1:]


def wrappers(text):
    """return the function names with systemctl calls"""
    out = set()
    for name, body in function_bodies(text).items():
        for _, toks in segments(body):
            for i, t in enumerate(toks):
                if os.path.basename(t) == "systemctl":
                    args = toks[i + 1:]
                    if any(a in ("$@", "$*") for a in args) and "--user" not in args:
                        out.add(name)
    return out


def _unit_of(val):
    """return the unit for a systemctl operand"""
    if UNIT_RE.match(val):
        return val
    if re.fullmatch(r"[A-Za-z0-9_@-]+", val):
        return val + ".service"
    return None


def _start_calls(toks, scope, wrapped):
    """return the start commands in a segment"""
    out = []
    rest = _strip_prefix(toks)
    if len(rest) >= 3 and os.path.basename(rest[0]) in ("service", "invoke-rc.d") \
            and set(expand(rest[2], scope)) & (START_VERBS | {UNRESOLVED}):
        out.append((" ".join(rest), [rest[1]]))
    for i, t in enumerate(toks):
        if os.path.basename(t) not in ("systemctl", "deb-systemd-invoke") and t not in wrapped:
            continue
        inv = _invocation(toks[i + 1:], scope)
        if inv is None:
            continue
        user, verbs, now, operands = inv
        literal_start = bool(verbs & START_VERBS) or bool(now and verbs & NOW_VERBS)
        if user or not (literal_start or UNRESOLVED in verbs):
            continue
        if literal_start and not operands:
            operands = [UNRESOLVED]
        out.append((" ".join(toks[i:]), operands))
    return out


def starts_in(body, label, scope, units, wrapped=frozenset()):
    """return problems for forbidden or unresolved starts"""
    problems = []
    for line, toks in segments(body):
        for cmd, operands in _start_calls(toks, scope, wrapped):
            if len(cmd) > 100:
                cmd = cmd[:100] + " ..."
            for op in operands:
                for val in ([UNRESOLVED] if op == UNRESOLVED else expand(op, scope)):
                    if val == UNRESOLVED or re.search(r"[*?\[]", val):
                        problems.append("%s:%s: `%s` starts '%s', which this check cannot resolve "
                                        "to unit names -- name each literally" %
                                        (label, line, cmd, op if op != UNRESOLVED else "<no operand>"))
                        continue
                    unit = _unit_of(val)
                    if unit is None:
                        continue
                    chain = pull_path(units, unit)
                    if chain and len(chain) == 1:
                        problems.append("%s:%s: `%s` starts %s" % (label, line, cmd, unit))
                    elif chain:
                        problems.append("%s:%s: `%s` starts %s, which pulls %s (%s)" %
                                        (label, line, cmd, unit, chain[-1], " -> ".join(chain)))
    return problems


def cli_calls(body):
    """return the rhizo command verbs in a script"""
    verbs = []
    for _, toks in segments(body):
        rest = _strip_prefix(toks)
        if len(rest) >= 2 and rest[0] in ("/usr/bin/rhizo", "rhizo"):
            verbs.append(rest[1])
    return verbs


def _calls(body, defined):
    """return the defined functions that a body calls"""
    out = set()
    for _, toks in segments(body):
        rest = _strip_prefix(toks)
        if rest and rest[0] in defined:
            out.add(rest[0])
    return out


def _execs(body):
    """return the installed files that a body executes"""
    out = set()
    for _, toks in segments(body):
        for t in toks:
            m = re.fullmatch(r"\$\{?INSTALL_DIR\}?/([A-Za-z0-9_./-]+)", t)
            if m:
                out.add(m.group(1))
    return out


def payload_runs(body):
    """return the line and path of payload runs"""
    out = []
    for line, toks in segments(body):
        rest = _strip_prefix(toks)
        while rest and os.path.basename(rest[0]) in ("python3", "python", "bash", "sh", "dash", "env",
                                                     "runuser", "setsid", "nohup"):
            rest = [t for t in rest[1:] if not t.startswith("-")]
        if rest and re.fullmatch(r"/usr/lib/rhizo/\S+", rest[0]):
            out.append((line, rest[0]))
    return out


SOURCE_DIRS = ("src", "tools")


def payload_source(root, installed):
    """return the source files of a payload path"""
    base = os.path.basename(installed)
    hits = []
    for d in SOURCE_DIRS:
        top = os.path.join(root, d)
        cand = [os.path.join(dp, base) for dp, _, files in os.walk(top) if base in files]
        hits += [c for c in cand if os.path.isfile(c)]
    return sorted(set(hits))


def script_body(root, rel, lists=None):
    """return the script text and its scope"""
    text = read(os.path.join(root, rel))
    v = variables(text, lists)
    return (rel, text, Scope(v, v), wrappers(text))


PY_UNIT_DIR_WRITE = re.compile(r"systemd/system[^\"'\s]*\.(?:d|wants|requires|upholds)\b|add-wants|add-requires")


def payload_bodies(root, rel, seen):
    """return the shell bodies of payload programs"""
    bodies, problems = [], []
    for line, installed in payload_runs(read(os.path.join(root, rel))):
        srcs = payload_source(root, installed)
        if len(srcs) != 1:
            problems.append("%s:%s: runs %s, and this check finds %s source for it in %s" % (rel, line, installed,
                                                       "no" if not srcs else "more than one",
                                                       ", ".join(SOURCE_DIRS)))
            continue
        srel = os.path.relpath(srcs[0], root)
        if srel in seen:
            continue
        seen.add(srel)
        text = read(srcs[0])
        if srel.endswith(".py"):
            if "systemctl" in text and any(u in text for u in FORBIDDEN + ("androidd@",)):
                problems.append("%s:%s: runs %s (%s), a python program that names systemctl and %s; "
                                "this check reads shell only" %
                                (rel, line, installed, srel,
                                 next(u for u in FORBIDDEN + ("androidd@",) if u in text)))
            m = PY_UNIT_DIR_WRITE.search(text)
            if m:
                problems.append("%s:%s: runs %s (%s), a python program that names '%s', a unit's drop-in "
                                "or pull link; this check reads shell only" %
                                (rel, line, installed, srel, m.group(0)))
            continue
        bodies.append(script_body(root, srel))
    return bodies, problems


def cli_bodies(root, verb, seen_scripts):
    """return the CLI function bodies for a verb"""
    rel = os.path.join("src", "install", "cli", "rhizo.sh")
    text = read(os.path.join(root, rel))
    fns = function_bodies(text)
    entry = "cmd_" + verb.replace("-", "_")
    if entry not in fns:
        return [], ["a maintainer script runs `rhizo %s`, and %s has no %s() to check" % (verb, rel, entry)]
    glob_vars = variables(_outside_functions(text))
    wrapped = wrappers(text)
    bodies, todo, done = [], [entry], set()
    while todo:
        fn = todo.pop()
        if fn in done:
            continue
        done.add(fn)
        body = fns[fn]
        bodies.append(("%s %s()" % (rel, fn), body, Scope(variables(body), glob_vars), wrapped))
        todo += sorted(_calls(body, fns) - done)
        for script in sorted(_execs(body)):
            srel = os.path.join("src", "install", script)
            if srel not in seen_scripts and os.path.isfile(os.path.join(root, srel)):
                seen_scripts.add(srel)
                bodies.append(script_body(root, srel))
    return bodies, []


def dpkg_bodies(root, lists=None):
    """return the script bodies and problems"""
    bodies, problems, seen = [], [], set()
    for script in MAINT_SCRIPTS:
        found = glob.glob(os.path.join(root, "debian", "*." + script))
        found += glob.glob(os.path.join(root, "debian", "*." + script + ".in"))
        for path in sorted(p for p in found if not os.path.isfile(p + ".in")):
            rel = os.path.relpath(path, root)
            try:
                libs = [os.path.relpath(lib, root) for lib in maint_inline.sourced(path)]
            except FileNotFoundError as e:
                problems.append("%s: %s" % (rel, e))
                libs = []
            for srel in [rel] + [lib for lib in libs if lib not in seen]:
                seen.add(srel)
                try:
                    bodies.append(script_body(root, srel, lists))
                    for verb in cli_calls(read(os.path.join(root, srel))):
                        b, p = cli_bodies(root, verb, seen)
                        bodies, problems = bodies + b, problems + p
                    b, p = payload_bodies(root, srel, seen)
                    bodies, problems = bodies + b, problems + p
                except CheckError as e:
                    problems.append("%s: %s" % (srel, e))
    return bodies, problems


NO_RESET = PULL_KEYS + ("OnSuccess", "OnFailure", "Also", "WantedBy", "RequiredBy", "UpheldBy",
                        "Unit", "Service")
LINK_KEYS = {"wants": "Wants", "requires": "Requires", "upholds": "Upholds"}
_UNIT_NAME = r"[A-Za-z0-9_.@:\\%-]+\.(?:service|socket|path|timer|target|mount|automount|swap|slice|scope)"
_SYSTEM_DIR = r"(?:/etc|/run|/usr/lib|/lib)/systemd/system(?:\.control|\.attached)?/"
DROPIN_RE = re.compile(r"%s(%s)\.d(?:/([^/]+))?" % (_SYSTEM_DIR, _UNIT_NAME))
LINK_RE = re.compile(r"%s(%s)\.(wants|requires|upholds)(?:/([^/]+))?" % (_SYSTEM_DIR, _UNIT_NAME))
PACKAGED_UNIT_RE = re.compile(r"(src/services/(?:[A-Za-z0-9_.-]+/)*?[A-Za-z0-9_.@-]+\.(?:service|path|socket|timer|target))"
                              r"(?![A-Za-z0-9_.@-])")
UNREAD = "\x00?\x00"
REDIRECTS = (">", ">>", ">|", "&>", "&>>")
NON_WRITERS = {"rm", "rmdir", "mkdir", "test", "[", "[[", "readlink", "ls", "stat", "grep", "chmod",
               "chown", "chcon", "restorecon", "basename", "dirname", "realpath", "log", "echo", "printf",
               "cat", "local", "true", ":", "unlink"}


def parse_into(text, into):
    """merge a unit file into a directive map"""
    for line in text.replace("\\\n", " ").splitlines():
        line = line.strip()
        if not line or line[0] in "#;[" or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if key in NO_RESET:
            into.setdefault(key, []).extend(val.split())
        elif not val:
            into[key] = []
        else:
            into.setdefault(key, []).append(val)
    return into


def unit_dir_entry(path):
    """classify a path under a system unit directory"""
    p = os.path.normpath(path) if path.startswith("/") else path
    m = LINK_RE.fullmatch(p)
    if m:
        return ("link", m.group(1), LINK_KEYS[m.group(2)], m.group(3))
    m = DROPIN_RE.fullmatch(p)
    if m:
        return ("dropin", m.group(1), m.group(2))
    return None


_ESCAPES = {"n": "\n", "t": "\t", "\\": "\\", "a": "\a", "b": "\b", "f": "\f", "r": "\r", "v": "\v",
            "e": "\x1b", '"': '"', "'": "'"}


def _unescape(s):
    """return the text with printf backslash escapes decoded"""
    def one(m):
        """return the character for a backslash escape"""
        e = m.group(1)
        if e[0] in "01234567" and len(e) > 1 or e[0] == "0":
            return chr(int(e.lstrip("0") or "0", 8) & 0xff)
        if e[0] == "x":
            return chr(int(e[1:], 16))
        return _ESCAPES.get(e, "\\" + e)
    return re.sub(r"\\(0[0-7]{0,3}|[1-7][0-7]{0,2}|x[0-9A-Fa-f]{1,2}|.)", one, s, flags=re.S)


def _word(tok, scope):
    """return the single value of a word"""
    vals = expand(tok, scope)
    return vals[0] if len(vals) == 1 and vals[0] != UNRESOLVED else UNREAD


def _printf_text(args, scope):
    """return the output text of printf arguments"""
    if args[:1] == ["-v"]:
        return None
    args = args[1:] if args[:1] == ["--"] else args
    if not args:
        return ""
    fmt = _word(args[0], scope)
    if fmt == UNREAD:
        return UNREAD
    fmt, vals, out = _unescape(fmt), [_word(a, scope) for a in args[1:]], []
    spec = re.compile(r"%(%|[-+ #0]*\d*(?:\.\d*)?([sbqdiouxXcfeEgG]))")
    while True:
        used = 0

        def conv(m):
            """return the replacement for a printf conversion"""
            nonlocal used
            if m.group(1) == "%":
                return "%"
            v = vals[used] if used < len(vals) else ""
            used += 1
            return _unescape(v) if m.group(2) == "b" else v
        out.append(spec.sub(conv, fmt))
        vals = vals[used:]
        if not vals or not used:
            return "".join(out)


def _echo_text(args, scope):
    """return the text an echo command prints"""
    newline, esc = True, False
    while args and re.fullmatch(r"-[neE]+", args[0]):
        newline = newline and "n" not in args[0]
        esc = "e" in args[0] or (esc and "E" not in args[0])
        args = args[1:]
    text = " ".join(_word(a, scope) for a in args)
    return (_unescape(text) if esc else text) + ("\n" if newline else "")


def heredoc_bodies(text):
    """return the heredoc bodies of each command"""
    out, pending, first, waiting = {}, "", None, []
    for n, line in enumerate(text.split("\n"), 1):
        if waiting:
            delim, strip, expands, buf, key = waiting[0]
            ln = line.lstrip("\t") if strip else line
            if ln.strip() == delim:
                out.setdefault(key, []).append(("\n".join(buf) + "\n", expands))
                waiting.pop(0)
            else:
                buf.append(ln)
            continue
        if first is None:
            first = n
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        full, pending = pending + line, ""
        if "<<" in full:
            try:
                lex = shlex.shlex(full, posix=False, punctuation_chars="();<>|&\n")
                lex.whitespace, lex.commenters = " \t\r", "#"
                lex.wordchars += "$@{}[]:=,.-/+%*~^!?"
                toks = list(lex)
            except ValueError:
                toks = []
            for k, t in enumerate(toks[:-1]):
                if t == "<<" or t == "<<-":
                    raw = toks[k + 1]
                    strip = t == "<<-" or raw.startswith("-")
                    word = raw.lstrip("-")
                    waiting.append((word.strip("'\"").replace("\\", ""), strip,
                                    not re.search(r"['\"\\]", word), [], first))
        first = None
    return out


def _heredoc_text(body, expands, scope):
    """return the text of a here-document"""
    if not expands:
        return body
    body = re.sub(r"\$\([^)]*\)|`[^`]*`", UNREAD, body)
    return re.sub(r"\$\{?[A-Za-z_]\w*\}?", lambda m: _word(m.group(0), scope), body)


def _unread_directives(text):
    """return the unreadable lines of a drop-in"""
    bad = []
    for line in text.replace("\\\n", " ").splitlines():
        s = line.strip()
        if UNREAD not in s or s[:1] in "#;":
            continue
        key = s.partition("=")[0].strip()
        if "=" not in s or UNREAD in key:
            bad.append("a line (%s)" % s.replace(UNREAD, "<?>"))
        elif key in NO_RESET:
            bad.append("%s= from a value" % key)
    return bad


def _operands(args, value_opts):
    """return the arguments that are not options or option values"""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a in value_opts:
            i += 1
        elif not a.startswith("-") or a == "-":
            out.append(a)
        i += 1
    return out


def _copy_source(root, src):
    """return the source files of a copied path"""
    base = os.path.basename(src)
    hits = [h for h in payload_source(root, src)]
    hits += [os.path.join(dp, base) for dp, _, files in os.walk(os.path.join(root, "debian")) if base in files]
    return sorted(set(hits))


class Writes:
    """unit drop-ins and pull links"""

    def __init__(self):
        """start empty lists of drop-ins, links and problems"""
        self.dropins, self.links, self.problems = [], [], []

    def dropin(self, label, line, path, text, how):
        """record a drop-in written into a unit directory"""
        entry = unit_dir_entry(path)
        if entry[2] is None or not entry[2].endswith(".conf"):
            if entry[2] is None:
                self.problems.append("%s:%s: `%s` writes into %s, a drop-in directory, in a shape this "
                                     "check cannot read -- write each .conf by name" % (label, line, how, path))
            return
        bad = _unread_directives(text) if text is not None else ["the whole file"]
        if bad:
            self.problems.append("%s:%s: `%s` writes the drop-in %s with %s this check cannot read -- "
                                 "write it as literal text" %
                                 (label, line, how, path, ", ".join(bad)))
            return
        self.dropins.append((entry[1], os.path.basename(path), text))

    def link(self, unit, key, member):
        """record a link from a unit to a member"""
        self.links.append((unit, key, member))


def _group_text(segs, end, scope):
    """return the output text of a brace group"""
    depth, i = 0, end - 1
    while i >= 0:
        toks = segs[i][1]
        if toks[:1] == ["}"]:
            depth += 1
        elif toks[:1] == ["{"]:
            if depth == 0:
                break
            depth -= 1
        i -= 1
    if i < 0:
        return UNREAD
    parts = []
    for _, toks in segs[i:end]:
        rest = _strip_prefix(toks[1:] if toks[:1] == ["{"] else toks)
        if not rest or rest[0] in (":", "true"):
            continue
        if rest[0] == "echo":
            parts.append(_echo_text(rest[1:], scope))
        elif rest[0] == "printf":
            parts.append(_printf_text(rest[1:], scope) or "")
        else:
            return UNREAD
    return "".join(parts)


def body_writes(root, label, text, scope, wrapped, out):
    """record the drop-in and link writes"""
    segs = segments(text, redirects=True)
    docs = heredoc_bodies(text)
    used = {}
    for idx, (line, toks) in enumerate(segs):
        words, targets, herestr, heredoc, k = [], [], None, None, 0
        while k < len(toks):
            t = toks[k]
            if t in REDIRECTS and k + 1 < len(toks):
                targets.append(toks[k + 1])
                if words and re.fullmatch(r"\d+", words[-1]):
                    words.pop()
                k += 2
                continue
            if t in ("<", ">&", "<&", "<>") and k + 1 < len(toks):
                k += 2
                continue
            if t == "<<<" and k + 1 < len(toks):
                herestr = toks[k + 1]
                k += 2
                continue
            if t == "<<" and k + 1 < len(toks):
                n = used.get(line, 0)
                used[line] = n + 1
                heredoc = (docs.get(line) or [])[n:n + 1]
                heredoc = heredoc[0] if heredoc else ("", False)
                k += 2
                continue
            words.append(t)
            k += 1
        rest = _strip_prefix(words)
        cmd = os.path.basename(rest[0]) if rest else ""
        how = " ".join(toks)
        how = how[:100] + " ..." if len(how) > 100 else how

        def paths(tok):
            """return the resolved values of a token"""
            vals = expand(tok, scope)
            if UNRESOLVED in vals:
                if "systemd/system" in tok:
                    out.problems.append("%s:%s: `%s` names %s, which this check cannot resolve -- "
                                        "name it literally" % (label, line, how, tok))
                return []
            return [v for v in vals if unit_dir_entry(v)]

        for tgt in targets:
            for path in paths(tgt):
                entry = unit_dir_entry(path)
                if entry[0] == "link":
                    out.link(entry[1], entry[2], entry[3] or UNREAD)
                    continue
                if cmd == "printf":
                    body = _printf_text(rest[1:], scope)
                elif cmd == "echo":
                    body = _echo_text(rest[1:], scope)
                elif cmd == "cat" and heredoc is not None:
                    body = _heredoc_text(heredoc[0], heredoc[1], scope)
                elif cmd == "cat" and herestr is not None:
                    body = _word(herestr, scope) + "\n"
                elif cmd == "cat" and len(rest) == 2:
                    srcs = _copy_source(root, _word(rest[1], scope))
                    body = read(srcs[0]) if len(srcs) == 1 else None
                elif rest[:1] == ["}"]:
                    body = _group_text(segs, idx, scope)
                else:
                    body = None
                out.dropin(label, line, path, body, how)
        for i, t in enumerate(words):
            if os.path.basename(t) != "systemctl" and t not in wrapped:
                continue
            args = words[i + 1:]
            if "--user" in args or "--global" in args:
                continue
            pos = _operands(args, VALUE_OPTS)
            verbs = set(expand(pos[0], scope)) if pos else set()
            if "edit" in verbs:
                out.problems.append("%s:%s: `%s` writes a drop-in this check cannot read" % (label, line, how))
            adds = [v for v in verbs if re.fullmatch(r"add-(?:wants|requires|upholds)", v)]
            adds += ["add-wants", "add-requires"] if UNRESOLVED in verbs else []
            for verb in adds:
                for member in pos[2:]:
                    for owner in expand(pos[1], scope):
                        for v in expand(member, scope):
                            if UNRESOLVED in (owner, v):
                                out.problems.append("%s:%s: `%s` may add a pull this check cannot resolve "
                                                    "-- name the verb and both units literally"
                                                    % (label, line, how))
                            else:
                                out.link(_unit_of(owner) or owner, LINK_KEYS[verb[4:]], _unit_of(v) or v)
        if not rest or cmd in NON_WRITERS or cmd == "systemctl" or rest[0] in wrapped:
            continue
        if cmd in ("cp", "install", "mv", "ln"):
            if cmd == "install" and "-d" in rest[1:]:
                continue
            ops = _operands(rest[1:], {"-m", "--mode", "-o", "--owner", "-g", "--group", "-S", "-t",
                                       "--target-directory", "--suffix"})
            tdir = rest[rest.index("-t") + 1] if "-t" in rest[1:-1] else None
            dest, srcs = (tdir, ops) if tdir else (ops[-1] if ops else "", ops[:-1])
            for src in srcs:
                paths(src)
            dvals = expand(dest, scope) if dest else []
            if UNRESOLVED in dvals:
                paths(dest)
                continue
            for dval in dvals:
                into_dir = re.fullmatch(_SYSTEM_DIR.rstrip("/"), os.path.normpath(dval)) if dval else None
                for src in srcs:
                    sval = _word(src, scope)
                    full = os.path.join(dval, os.path.basename(sval)) if sval != UNREAD else UNREAD
                    entry = unit_dir_entry(dval) or (unit_dir_entry(full) if into_dir else None)
                    if entry is None:
                        continue
                    if into_dir:
                        out.problems.append("%s:%s: `%s` lays %s down whole, which this check cannot read "
                                            "-- write each drop-in or link by name" % (label, line, how, full))
                        continue
                    if entry[0] == "link":
                        member = entry[3] or (os.path.basename(sval) if sval != UNREAD else UNREAD)
                        out.link(entry[1], entry[2], member)
                        continue
                    full = dval if entry[2] else full
                    found = _copy_source(root, sval) if cmd != "ln" else []
                    out.dropin(label, line, full, read(found[0]) if len(found) == 1 else None, how)
            continue
        for tok in rest[1:]:
            for p in paths(tok):
                entry = unit_dir_entry(p)
                if entry[0] == "link":
                    out.link(entry[1], entry[2], entry[3] or UNREAD)
                else:
                    out.dropin(label, line, p, None, how)


def rules_writes(rules_text, root, out):
    """add debian/rules drop-ins and links to out"""
    mvars = {}
    for m in re.finditer(r"^([A-Za-z_]\w*)\s*:?=[ \t]*((?:[^\n]*\\\n)*[^\n]*)", rules_text, re.M):
        mvars.setdefault(m.group(1), m.group(2).replace("\\\n", " ").strip())

    def subst(s, depth=0):
        """return the text with make variables substituted"""
        r = re.sub(r"\$[({]([A-Za-z_]\w*)[)}]", lambda m: mvars.get(m.group(1), m.group(0)), s)
        return subst(r, depth + 1) if r != s and depth < 5 else r

    def installed(tok):
        """return the installed path of a token, or None"""
        m = re.fullmatch(r"(?:\$\(CURDIR\)/)?debian/[^/]+(/.*)", tok)
        return m.group(1) if m and unit_dir_entry(m.group(1)) else None

    lines = rules_text.replace("\\\n", " ").split("\n")
    for n, raw in enumerate(lines, 1):
        if not raw.startswith("\t"):
            continue
        try:
            toks = shlex.split(subst(raw.strip().lstrip("@-+")))
        except ValueError:
            toks = raw.split()
        cmds, cur = [], []
        for t in toks + [";"]:
            if t in (";", "&&", "||", "|"):
                if cur:
                    cmds.append(cur)
                cur = []
            else:
                cur.append(t)
        for cmd in cmds:
            named = [installed(t) for t in cmd[1:] if installed(t)]
            if not named:
                continue
            name = os.path.basename(cmd[0])
            how = " ".join(cmd)[:100]
            if name in ("mkdir", "rm", "rmdir", "chmod", "test") or (name == "install" and "-d" in cmd):
                continue
            if name not in ("install", "cp", "ln"):
                out.problems.append("debian/rules: `%s` names %s, a drop-in or pull link this check cannot "
                                    "read -- install it with src/install/cp/ln" % (how, named[0]))
                continue
            ops = _operands(cmd[1:], {"-m", "--mode", "-o", "--owner", "-g", "--group", "-S", "-t"})
            dest, srcs = ops[-1], ops[:-1]
            dpath = installed(dest)
            if dpath is None:
                continue
            entry = unit_dir_entry(dpath)
            for src in srcs:
                if entry[0] == "link":
                    out.link(entry[1], entry[2], entry[3] or os.path.basename(src))
                    continue
                full = dpath if entry[2] else os.path.join(dpath, os.path.basename(src))
                spath = os.path.join(root, src)
                body = read(spath) if name != "ln" and os.path.isfile(spath) else None
                out.dropin("debian/rules", n, full, body, how)


def unit_model(rules_text, root, bodies):
    """return the units and the problem list"""
    units = {}
    for rel in sorted(set(PACKAGED_UNIT_RE.findall(rules_text))):
        path = os.path.join(root, rel)
        if os.path.exists(path):
            units[unit_files.installed_name(os.path.basename(rel))] = parse_into(read(path), {})
    out = Writes()
    rules_writes(rules_text, root, out)
    for label, text, scope, wrapped in bodies:
        body_writes(root, label, text, scope, wrapped, out)
    for unit, _, text in sorted(out.dropins, key=lambda d: (d[0], d[1])):
        parse_into(text, units.setdefault(unit, {}))
    for unit, key, member in out.links:
        if member == UNREAD:
            out.problems.append("a pull link into %s.%s/ names a unit this check cannot resolve"
                                % (unit, key.lower()))
            continue
        units.setdefault(unit, {}).setdefault(key, []).append(member)
    for f in sorted(glob.glob(os.path.join(root, "debian", "*.links")) +
                    glob.glob(os.path.join(root, "debian", "*.install"))):
        for line in read(f).splitlines():
            if re.search(r"systemd/system/[^ ]*\.(?:d|wants|requires|upholds)(?:/|\s|$)", line):
                out.problems.append("%s lays %s down through debhelper, which this check does not model "
                                    "-- install it from override_dh_auto_install" %
                                    (os.path.relpath(f, root), line.strip()))
    return units, out.problems


def rules_boot_only(rules_text):
    """return the boot-only unit names from the rules text, or None"""
    m = re.search(r"^BOOT_ONLY_UNITS\s*:?=((?:[^\n]*\\\n)*[^\n]*)", rules_text, re.M)
    return None if m is None else m.group(1).replace("\\\n", " ").split()


def parity_problems(rules_text, installer_text):
    """compare the rules and installer boot-only unit sets"""
    want = rules_boot_only(rules_text)
    m = re.search(r'^INSTALLER_BOOT_ONLY_UNITS="([^"]*)"', installer_text, re.M)
    if want is None:
        return ["debian/rules defines no BOOT_ONLY_UNITS, the set dpkg must never start"]
    if m is None:
        return ["test/system/lib/installer-lib.sh defines no INSTALLER_BOOT_ONLY_UNITS"]
    got = m.group(1).split()
    if set(got) != set(want):
        return ["installer-lib.sh's INSTALLER_BOOT_ONLY_UNITS (%s) is not debian/rules' BOOT_ONLY_UNITS "
                "(%s): missing %s, extra %s" % (" ".join(got), " ".join(want),
                                                 sorted(set(want) - set(got)) or "none",
                                                 sorted(set(got) - set(want)) or "none")]
    return []


def check(root):
    """check for unit starts at dpkg install time"""
    rules = read(os.path.join(root, "debian", "rules"))
    layout = unit_layout(rules)
    if not layout:
        return ["debian/rules' override_dh_auto_install installs no src/services unit -- nothing to model"]
    problems = rules_site_problems(rules)
    for f in sorted(glob.glob(os.path.join(root, "debian", "*"))):
        if re.search(r"\.(?:service|socket|path|timer|mount|target)$", f):
            problems.append("%s is a unit dh_installsystemd installs by itself, which this check does "
                            "not model -- ship it from src/services through override_dh_auto_install"
                            % os.path.relpath(f, root))
    generated = {}
    try:
        generated = dh_generated(root, rules, layout)
    except CheckError as e:
        problems.append("the package's dh_installsystemd step: %s" % e)
    lists, list_problems = unit_lists(generated.get("postinst", ""))
    problems += ["the generated postinst: %s" % p for p in list_problems] if generated else []
    bodies, found = dpkg_bodies(root, lists)
    for script, text in generated.items():
        v = variables(text)
        bodies.append(("dh_installsystemd's generated %s" % script, text, Scope(v, v), frozenset()))
    units, unread = unit_model(rules, root, bodies)
    problems += found + unread
    for label, text, scope, wrapped in bodies:
        try:
            problems += starts_in(text, label, scope, units, wrapped)
        except CheckError as e:
            problems.append("%s: %s" % (label, e))
    problems += boot_pull_problems(units)
    problems += reverse_pull_problems(units)
    problems += parity_problems(rules, read(os.path.join(root, "test", "system", "lib", "installer-lib.sh")))
    return problems


FX_CONTROL = """Source: rhizo
Section: misc
Priority: optional
Maintainer: Fixture <fixture@example.invalid>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.6.2

Package: rhizo
Architecture: all
Description: fixture
 fixture
"""
FX_CHANGELOG = """rhizo (0.0.1) noble; urgency=medium

  * fixture

 -- Fixture <fixture@example.invalid>  Thu, 01 Jan 2026 00:00:00 +0000
"""
FX_BOOT_ONLY = ("androidd.service rhizo-prepare.service rhizo-policy.service rhizo-update-begin.service "
                "rhizo-update-confirm.service")
FX_RULES = """#!/usr/bin/make -f
UNITS    := debian/rhizo/usr/lib/systemd/system
USER_UNITS := debian/rhizo/usr/lib/systemd/user

%:
\tdh $@

override_dh_auto_install:
\tinstall -D -m 0644 src/services/units/boot/androidd.service $(UNITS)/androidd.service
\tinstall -D -m 0644 src/services/units/boot/prepare.service $(UNITS)/rhizo-prepare.service
\tinstall -D -m 0644 src/services/units/boot/policy.service $(UNITS)/rhizo-policy.service
\tinstall -D -m 0644 src/services/units/boot/update-confirm.service $(UNITS)/rhizo-update-confirm.service
\tinstall -D -m 0644 src/services/hostfs/hostfs.service $(UNITS)/rhizo-hostfs.service
\tinstall -D -m 0644 src/services/broker/brokerd.socket $(UNITS)/rhizo-brokerd.socket
\tinstall -D -m 0644 src/services/broker/brokerd@.service $(UNITS)/rhizo-brokerd@.service
\tinstall -D -m 0644 src/services/units/display-pool/display-pool.path $(UNITS)/rhizo-display-pool.path
\tinstall -D -m 0644 src/services/units/display-pool/display-pool.service $(UNITS)/rhizo-display-pool.service
\tinstall -D -m 0644 src/services/units/boot/androidd@.service $(UNITS)/androidd@.service
\tinstall -D -m 0644 src/services/units/boot/update-begin.service $(UNITS)/rhizo-update-begin.service
\tinstall -D -m 0644 src/services/units/session/desktop-session.path \\
\t                   $(USER_UNITS)/rhizo-desktop-session.path
\tinstall -D -m 0644 debian/dropins/hostfs-paths.conf \\
\t                   $(UNITS)/rhizo-hostfs.service.d/10-packaged-paths.conf
@DROPINS@
BOOT_ONLY_UNITS := @BOOT_ONLY@
@OVERRIDE@"""
FX_OVERRIDE = """override_dh_installsystemd:
\tdh_installsystemd --no-start --no-stop-on-upgrade $(BOOT_ONLY_UNITS)
\tdh_installsystemd $(addprefix -X,$(BOOT_ONLY_UNITS))
"""
FX_UNITS = {
    "androidd.service": "[Unit]\nWants=rhizo-policy.service rhizo-update-confirm.service\n"
                        "After=rhizo-policy.service\n[Service]\nExecStart=/bin/true\n",
    "androidd@.service": "[Unit]\nWants=rhizo-policy.service rhizo-update-begin.service\n"
                         "After=rhizo-policy.service\n[Service]\nExecStart=/bin/true\n",
    "rhizo-prepare.service": "[Unit]\nConditionPathExists=/sys/fs/selinux/enforce\n[Service]\n"
                             "Type=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n",
    "rhizo-policy.service": "[Unit]\nConditionPathExists=/sys/fs/selinux/enforce\n[Service]\n"
                            "Type=oneshot\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n",
    "rhizo-update-begin.service": "[Unit]\nBefore=androidd.service\n"
                                  "ConditionPathExists=/var/lib/rhizo/update/state\n[Service]\n"
                                  "Type=oneshot\nExecStart=/bin/true\n",
    "rhizo-update-confirm.service": "[Unit]\nAfter=androidd.service\nBindsTo=androidd.service\n"
                                    "ConditionPathExists=/var/lib/rhizo/update/state\n[Service]\n"
                                    "ExecStart=/bin/true\n",
    "rhizo-hostfs.service": "[Unit]\nAfter=androidd.service\nPartOf=androidd.service\n[Service]\n"
                            "ExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n",
    "rhizo-brokerd.socket": "[Socket]\nListenStream=/run/rhizo-broker.sock\nAccept=yes\n"
                            "[Install]\nWantedBy=sockets.target\n",
    "rhizo-brokerd@.service": "[Service]\nExecStart=/bin/true\n",
    "rhizo-display-pool.path": "[Path]\nPathExists=/run/rhizo-display-pool/consumed\nUnit=rhizo-display-pool.service\n"
                          "[Install]\nWantedBy=multi-user.target\n",
    "rhizo-display-pool.service": "[Service]\nExecStart=/bin/true\n",
    "rhizo-desktop-session.path": "[Path]\nPathExists=/run/user/1000/x\n[Install]\nWantedBy=default.target\n",
}
FX_POSTINST = """#!/bin/sh
set -e
case "$1" in
  configure)
    /usr/bin/rhizo install || { echo "[rhizo] install failed" >&2; exit 1; }
    systemctl enable rhizo-prepare.service
    systemctl start rhizo-display-pool.path
    echo "[rhizo] watch it: systemctl start androidd.service"
    runuser -u x -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start androidd.service
    for u in rhizo-hostfs.service rhizo-display-pool.path; do
      systemctl restart "$u"
    done
    cat > /etc/x.service <<EOF
ExecStart=/bin/sh -c 'systemctl start androidd.service'
EOF
    owner="$(cat /etc/rhizo/desktop-user)"
    mkdir -p /etc/systemd/system/rhizo-hostfs.service.d
    printf '[Service]\\nUser=%s\\nGroup=%s\\n' "$owner" "$owner" \\
      > /etc/systemd/system/rhizo-hostfs.service.d/20-desktop-user.conf
    for unit in rhizo-display-pool.service; do
      mkdir -p "/etc/systemd/system/$unit.d"
      printf '[Service]\\nUser=%s\\n' "$owner" > "/etc/systemd/system/$unit.d/20-desktop-user.conf"
    done
    @EXTRA@
    ;;
esac
#DEBHELPER#
exit 0
"""
FX_PRERM = """#!/bin/sh
set -e
case "$1" in
  remove) systemctl stop androidd.service rhizo-policy.service 2>/dev/null || true
          rm -f /etc/systemd/system/rhizo-hostfs.service.d/20-desktop-user.conf ;;
esac
#DEBHELPER#
exit 0
"""
FX_CLI = """#!/bin/bash
INSTALL_DIR=/usr/lib/rhizo/install
SERVER_API_UNIT=rhizo-brokerd.socket
POLICY_UNIT=rhizo-policy.service
user_sc() { runuser -u x -- systemctl --user "$@"; }
sc() {
  systemctl "$@"
}
helper() {
  systemctl enable --now "$SERVER_API_UNIT" || return 1
  user_sc start androidd.service
  systemctl enable "$POLICY_UNIT"
  @HELPER@
}
cmd_install() {
  if ! helper; then
    return 1
  fi
  exec "$INSTALL_DIR/bootstrap/bootstrap.sh" "$@"
}
cmd_start() {
  systemctl start androidd.service
}
"""
FX_BOOTSTRAP = "#!/bin/bash\nupdate-grub\n@BOOT@\n"
FX_INSTALLER = 'INSTALLER_BOOT_ONLY_UNITS="@LIST@"\n'


FX_DROPIN = "[Service]\nExecStart=\nExecStart=/usr/bin/true\n"


def _fixture(tmp, boot_only=FX_BOOT_ONLY, installer_list=None, override=FX_OVERRIDE, units=None,
             postinst_extra="", helper="", bootstrap="", extra_files=None, dropins=(), rules_extra=""):
    """write a fixture package tree under tmp"""
    for d in ("test/system", "tools/build", "src/services/units", "src/install", "debian/dropins"):
        os.makedirs(os.path.join(tmp, d), exist_ok=True)
    files = {
        "debian/control": FX_CONTROL,
        "debian/changelog": FX_CHANGELOG,
        "debian/rules": FX_RULES.replace("@BOOT_ONLY@", boot_only).replace("@OVERRIDE@", override)
                                .replace("@DROPINS@", "".join(
                                    "\tinstall -D -m 0644 %s \\\n\t    \"$(UNITS)/%s\"\n" % (src, dest)
                                    for src, dest, _ in dropins) + rules_extra),
        "debian/dropins/hostfs-paths.conf": FX_DROPIN,
        "debian/rhizo.postinst": FX_POSTINST.replace("@EXTRA@", postinst_extra),
        "debian/rhizo.prerm": FX_PRERM,
        "src/install/cli/rhizo.sh": FX_CLI.replace("@HELPER@", helper or ":"),
        "src/install/bootstrap/bootstrap.sh": FX_BOOTSTRAP.replace("@BOOT@", bootstrap),
        "test/system/lib/installer-lib.sh": FX_INSTALLER.replace(
            "@LIST@", boot_only if installer_list is None else installer_list),
    }
    where = {unit_files.installed_name(os.path.basename(rel)): rel
             for rel in PACKAGED_UNIT_RE.findall(files["debian/rules"])}
    for name, text in dict(FX_UNITS, **(units or {})).items():
        files[where.get(name, "src/services/units/" + name)] = text
    files.update(extra_files or {})
    files.update({src: text for src, _, text in dropins})
    for rel, text in files.items():
        os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
        with open(os.path.join(tmp, rel), "w") as f:
            f.write(text)


def _bash(script):
    """run a bash script and return its exit code and combined output"""
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, cwd=HERE)
    return r.returncode, r.stdout + r.stderr


def selftest():
    """run the check on fixture trees"""
    fails = []

    def case(name, want, **kw):
        """check the findings for a fixture"""
        tmp = tempfile.mkdtemp(prefix="check-dpkg-no-policy-start.fx.")
        try:
            _fixture(tmp, **kw)
            got = check(tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if not want:
            if got:
                fails.append("%s: want no finding, got %s" % (name, got))
            return
        for w in want:
            if not any(all(part in p for part in w) for p in got):
                fails.append("%s: no finding carries %s; got %s" % (name, w, got or "none"))

    case("the real shape: no-start boot-only units, a --user start, a quoted message, a heredoc, "
         "cmd_start out of reach", [])
    case("no override: bare dh_installsystemd starts and restarts every unit", [
        ("generated postinst", "starts androidd.service"),
        ("generated postinst", "starts rhizo-prepare.service"),
        ("generated postinst", "starts rhizo-policy.service"),
        ("generated postinst", "rhizo-update-confirm.service, which pulls androidd.service")],
        override="")
    lst = FX_BOOT_ONLY.replace(" rhizo-policy.service", "")
    case("rhizo-policy.service left out of the no-start call",
         [("generated postinst", "starts rhizo-policy.service")], boot_only=lst)
    case("--no-start with restart-after-upgrade try-restarts", [("try-restart", "rhizo-policy.service")],
         override=FX_OVERRIDE.replace("--no-stop-on-upgrade", "--restart-after-upgrade"))
    lst = FX_BOOT_ONLY.replace(" rhizo-update-confirm.service", "")
    case("a unit bound to androidd left startable",
         [("starts rhizo-update-confirm.service, which pulls androidd.service",
           "rhizo-update-confirm.service -> androidd.service")], boot_only=lst)
    case("a boot-only unit bound to androidd gains WantedBy=multi-user.target",
         [("multi-user.target pulls androidd.service", "rhizo-update-confirm.service -> androidd.service")],
         units={"rhizo-update-confirm.service": FX_UNITS["rhizo-update-confirm.service"]
                + "[Install]\nWantedBy=multi-user.target\n"})
    case("the instance template pulls the unit bound to androidd, so a server never starts instance 0 on its own",
         [("androidd@.service (every androidd@<id>) pulls rhizo-update-confirm.service",
           "BindsTo=androidd.service", "starts instance 0's sandbox")],
         units={"androidd@.service": FX_UNITS["androidd@.service"].replace(
             "rhizo-update-begin.service", "rhizo-update-begin.service rhizo-update-confirm.service")})
    case("OnFailure= naming the unit bound to androidd",
         [("rhizo-display-pool.service pulls rhizo-update-confirm.service", "BindsTo=androidd.service")],
         units={"rhizo-display-pool.service": "[Unit]\nOnFailure=rhizo-update-confirm.service\n[Service]\n"
                                         "ExecStart=/bin/true\n"})
    case("a .path whose unit is androidd.service",
         [("starts rhizo-display-pool.path, which pulls androidd.service",),
          ("multi-user.target pulls androidd.service", "rhizo-display-pool.path")],
         units={"rhizo-display-pool.path": "[Path]\nPathExists=/run/x\nUnit=androidd.service\n"
                                      "[Install]\nWantedBy=multi-user.target\n"})
    case("the old postinst's same-boot prepare",
         [("debian/rhizo.postinst:", "`systemctl start --no-block rhizo-prepare.service` starts "
                                     "rhizo-prepare.service")],
         postinst_extra="systemctl start --no-block rhizo-prepare.service")
    case("a loop variable", [("debian/rhizo.postinst:", "restart", "starts rhizo-policy.service")],
         postinst_extra='for w in rhizo-policy.service; do systemctl restart "$w"; done')
    case("enable --now", [("enable --now androidd.service", "starts androidd.service")],
         postinst_extra="systemctl enable --now androidd.service")
    case("behind env", [("starts androidd.service",)],
         postinst_extra="env FOO=1 systemctl start androidd.service")
    case("an operand from a command substitution", [("cannot resolve",)],
         postinst_extra='systemctl start "$(pick_unit)"')
    case("an instance of androidd@", [("starts androidd@2.service",)],
         postinst_extra="systemctl start androidd@2.service")
    case("the CLI verb the postinst runs, through a global",
         [("src/install/cli/rhizo.sh helper():", "starts rhizo-policy.service")],
         helper='systemctl start "$POLICY_UNIT"')
    case("the CLI through a systemctl wrapper",
         [("src/install/cli/rhizo.sh helper():", "sc start rhizo-prepare.service", "starts rhizo-prepare.service")],
         helper="sc start rhizo-prepare.service")
    case("a script the CLI execs", [("src/install/bootstrap/bootstrap.sh:", "starts androidd.service")],
         bootstrap="systemctl start androidd.service")
    case("the vm system tests' list drifted", [("INSTALLER_BOOT_ONLY_UNITS", "missing ['rhizo-policy.service']")],
         installer_list=FX_BOOT_ONLY.replace(" rhizo-policy.service", ""))
    case("a recipe that cannot run", [("dh_installsystemd step", "failed")],
         override=FX_OVERRIDE.replace("$(BOOT_ONLY_UNITS)\n", "$(BOOT_ONLY_UNITS) no-such.service\n", 1))
    case("a quoted command substitution", [("starts androidd.service",)],
         postinst_extra='out="$(systemctl start androidd.service 2>&1)"')
    case("sh -c", [("starts androidd.service",)], postinst_extra="sh -c 'systemctl start androidd.service'")
    case("the SysV front end", [("service androidd start", "starts androidd.service")],
         postinst_extra="service androidd start")
    case("units from stdin", [("<no operand>", "cannot resolve")],
         postinst_extra="echo androidd.service | xargs systemctl start")
    case("a literal overwritten by a command's output", [("cannot resolve",)],
         postinst_extra='w=rhizo-hostfs.service; w=$(pick); systemctl start "$w"')
    case("a name read at run time", [("cannot resolve",)],
         postinst_extra='read -r v < /etc/unit; systemctl start "$v"')
    case("a glob", [("rhizo-pol*.service", "cannot resolve")],
         postinst_extra="systemctl start 'rhizo-pol*.service'")
    case("the CLI behind an assignment prefix", [("src/install/cli/rhizo.sh cmd_start():", "starts androidd.service")],
         postinst_extra="RHIZO_X=1 /usr/bin/rhizo start")
    lib_call = ". /usr/lib/rhizo/install/lib/pkg-lib.sh\n    pkg_step"
    case("a start in the payload library the postinst sources",
         [("src/install/lib/pkg-lib.sh:", "starts androidd.service")], postinst_extra=lib_call,
         extra_files={"src/install/lib/pkg-lib.sh": "pkg_step() {\n  systemctl start androidd.service\n}\n"})
    case("the CLI verb the sourced library runs", [("src/install/cli/rhizo.sh cmd_start():", "starts androidd.service")],
         postinst_extra=lib_call,
         extra_files={"src/install/lib/pkg-lib.sh": "pkg_step() {\n  /usr/bin/rhizo start\n}\n"})
    listed = ("PKG_UNITS_START=/usr/lib/rhizo/install/units.start\npkg_step() {\n  :\n}\n"
              "pkg_start_listed() {\n  while read -r start_unit; do\n    systemctl start \"$start_unit\"\n"
              "  done < \"$PKG_UNITS_START\"\n}\n")
    case("the library starts each unit the pacman package's units.start lists: debhelper's own starts", [],
         postinst_extra=lib_call, extra_files={"src/install/lib/pkg-lib.sh": listed})
    case("units.start lists what debhelper starts, rhizo-policy.service among it",
         [("src/install/lib/pkg-lib.sh:", "starts rhizo-policy.service")],
         boot_only=FX_BOOT_ONLY.replace(" rhizo-policy.service", ""), postinst_extra=lib_call,
         extra_files={"src/install/lib/pkg-lib.sh": listed})
    case("a start read from a file that is no unit list", [("src/install/lib/pkg-lib.sh:", "cannot resolve")],
         postinst_extra=lib_call,
         extra_files={"src/install/lib/pkg-lib.sh": listed.replace("install/units.start", "install/other.list")})
    case("a sourced library that is not in the tree", [("debian/rhizo.postinst:", "does not exist")],
         postinst_extra=lib_call)
    case("a heredoc operator inside a quoted message", [("starts androidd.service",)],
         postinst_extra='echo "feed it: cat <<EOF"\n    systemctl start androidd.service')
    case("a target the boot-only units are enabled into",
         [("starts multi-user.target, which pulls", "multi-user.target -> rhizo-p")],
         postinst_extra="systemctl start multi-user.target")
    case("OnFailure= naming androidd",
         [("starts rhizo-display-pool.path, which pulls androidd.service",
           "rhizo-display-pool.service -> androidd.service")],
         units={"rhizo-display-pool.service": "[Unit]\nOnFailure=androidd.service\n[Service]\nExecStart=/bin/true\n"})
    case("dh_installsystemd run from execute_after_", [("execute_after_dh_installsystemd",)],
         override=FX_OVERRIDE + "execute_after_dh_installsystemd:\n\ttrue\n")
    case("dh_installsystemd run from another target",
         [("override_dh_installinit runs dh_installsystemd",)],
         override=FX_OVERRIDE + "override_dh_installinit:\n\tdh_installsystemd androidd.service\n")
    case("a unit shipped from debian/", [("debian/rhizo.service is a unit dh_installsystemd installs",)],
         extra_files={"debian/rhizo.service": "[Service]\nExecStart=/bin/true\n"})
    case("a payload script the postinst runs",
         [("src/services/x/rhizo-x-sync.sh:", "starts androidd.service")],
         postinst_extra="/usr/lib/rhizo/x/rhizo-x-sync.sh || true",
         extra_files={"src/services/x/rhizo-x-sync.sh": "#!/bin/sh\nsystemctl start androidd.service\n"})
    case("a payload with no source in the tree", [("runs /usr/lib/rhizo/x/gone.sh", "finds no source")],
         postinst_extra="/usr/lib/rhizo/x/gone.sh")
    case("a python payload naming systemctl and androidd",
         [("rhizo-x.py", "a python program that names systemctl and androidd.service")],
         postinst_extra="/usr/bin/python3 /usr/lib/rhizo/x/rhizo-x.py --once",
         extra_files={"src/services/x/rhizo-x.py": "import subprocess\n"
                                          "subprocess.run(['systemctl', 'start', 'androidd.service'])\n"})
    case("a python payload that names neither", [],
         postinst_extra="/usr/bin/python3 /usr/lib/rhizo/x/rhizo-y.py",
         extra_files={"src/services/x/rhizo-y.py": "print('hello')\n"})

    tmpl = FX_UNITS["androidd@.service"]
    begin = FX_UNITS["rhizo-update-begin.service"]
    root_hit = "androidd@.service (every androidd@<id>) reaches androidd.service"
    case("the template Wants=androidd.service",
         [(root_hit, "androidd@.service -> androidd.service", "starts instance 0's sandbox")],
         units={"androidd@.service": tmpl.replace("[Service]", "Wants=androidd.service\n[Service]")})
    case("the template Requires=androidd.service", [(root_hit, "androidd@.service -> androidd.service")],
         units={"androidd@.service": tmpl.replace("[Service]", "Requires=androidd.service\n[Service]")})
    case("a unit the template pulls Wants=androidd.service",
         [(root_hit, "androidd@.service -> rhizo-update-begin.service -> androidd.service"),
          ("androidd@.service (every androidd@<id>) pulls rhizo-update-begin.service, which reaches "
           "androidd.service",)],
         units={"rhizo-update-begin.service": begin.replace("[Service]", "Wants=androidd.service\n[Service]")})
    case("an instance of a template the template pulls",
         [(root_hit, "androidd@.service -> rhizo-brokerd@.service -> androidd.service")],
         units={"androidd@.service": tmpl.replace("rhizo-update-begin.service",
                                                  "rhizo-update-begin.service rhizo-brokerd@%i.service"),
                "rhizo-brokerd@.service": "[Unit]\nWants=androidd.service\n[Service]\nExecStart=/bin/true\n"})
    case("a unit enabled into the template reaches androidd.service",
         [(root_hit, "androidd@.service -> rhizo-display-pool.service -> androidd.service")],
         units={"rhizo-display-pool.service": "[Unit]\nWants=androidd.service\n[Service]\nExecStart=/bin/true\n"
                                         "[Install]\nWantedBy=androidd@.service\n"})
    case("a drop-in the package ships onto a unit it does not ship",
         [("user@.service pulls rhizo-update-confirm.service, which reaches androidd.service",)],
         dropins=[("debian/dropins/user-x.conf", "user@.service.d/rhizo-x.conf",
                   "[Unit]\nWants=rhizo-update-confirm.service\n")])
    case("a drop-in the package ships from outside debian/dropins",
         [(root_hit, "androidd@.service -> androidd.service")],
         dropins=[("src/services/units/androidd@.service.d/x.conf", "androidd@.service.d/20-x.conf",
                   "[Unit]\nWants=androidd.service\n")])
    case("a drop-in's empty Wants= cannot take back the unit's own pull",
         [(root_hit, "androidd@.service -> androidd.service")],
         units={"androidd@.service": tmpl.replace("[Service]", "Requires=androidd.service\n[Service]")},
         dropins=[("debian/dropins/reset.conf", "androidd@.service.d/30-reset.conf",
                   "[Unit]\nRequires=\nWants=\n")])
    case("a drop-in the postinst writes with printf",
         [("androidd@.service (every androidd@<id>) pulls rhizo-update-confirm.service, which reaches "
           "androidd.service",)],
         postinst_extra="printf '[Unit]\\nWants=rhizo-update-confirm.service\\n' "
                        "> /etc/systemd/system/androidd@.service.d/30-x.conf")
    case("a drop-in the postinst writes through a loop variable", [(root_hit,)],
         postinst_extra='for u in androidd@.service; do printf "[Unit]\\nRequires=androidd.service\\n" '
                        '> "/etc/systemd/system/$u.d/30-x.conf"; done')
    case("a drop-in the postinst writes from a heredoc",
         [("rhizo-display-pool.path pulls rhizo-display-pool.service, which reaches androidd.service",),
          ("starts rhizo-display-pool.path, which pulls androidd.service",)],
         postinst_extra="cat > /etc/systemd/system/rhizo-display-pool.service.d/30-x.conf <<EOF\n"
                        "[Unit]\nRequires=androidd.service\nEOF")
    case("a drop-in the postinst writes from echoes in a group", [(root_hit,)],
         postinst_extra="{\n      echo '[Unit]'\n      echo 'Wants=androidd.service'\n"
                        "    } > /etc/systemd/system/androidd@.service.d/30-x.conf")
    case("a drop-in written in a shape this check cannot read",
         [("/etc/systemd/system/androidd@.service.d/30-x.conf", "cannot read")],
         postinst_extra="python3 -c 'print(1)' > /etc/systemd/system/androidd@.service.d/30-x.conf")
    case("a drop-in whose unit this check cannot resolve", [("cannot resolve", "30-x.conf")],
         postinst_extra='printf "[Unit]\\n" > "/etc/systemd/system/$(pick).d/30-x.conf"')
    case("a pull from a printf argument this check cannot read", [("cannot read", "Wants=")],
         postinst_extra='printf "[Unit]\\nWants=%s\\n" "$(pick)" > /etc/systemd/system/androidd@.service.d/30-x.conf')
    case("a .wants link the postinst makes",
         [("androidd@.service (every androidd@<id>) pulls rhizo-update-confirm.service",)],
         postinst_extra="ln -sf /usr/lib/systemd/system/rhizo-update-confirm.service "
                        "/etc/systemd/system/androidd@.service.wants/rhizo-update-confirm.service")
    case("systemctl add-wants",
         [("androidd@.service (every androidd@<id>) pulls rhizo-update-confirm.service",)],
         postinst_extra="systemctl add-wants androidd@.service rhizo-update-confirm.service")
    case("a drop-in the postinst copies from a tracked file", [(root_hit,)],
         postinst_extra="cp /usr/share/rhizo/x-pull.conf /etc/systemd/system/androidd@.service.d/30-x.conf",
         extra_files={"src/services/x/x-pull.conf": "[Unit]\nWants=androidd.service\n"})
    case("a drop-in the postinst copies into its directory", [(root_hit,)],
         postinst_extra="install -m 0644 /usr/share/rhizo/x-pull.conf /etc/systemd/system/androidd@.service.d/",
         extra_files={"src/services/x/x-pull.conf": "[Unit]\nWants=androidd.service\n"})
    case("a drop-in directory the postinst copies whole",
         [("lays /etc/systemd/system/androidd@.service.d down whole", "cannot read")],
         postinst_extra="cp -r /usr/share/rhizo/androidd@.service.d /etc/systemd/system/")
    case("a .wants link the rules install",
         [("androidd@.service (every androidd@<id>) pulls rhizo-update-confirm.service",)],
         rules_extra="\tln -s ../rhizo-update-confirm.service "
                     "$(UNITS)/androidd@.service.wants/rhizo-update-confirm.service\n")
    case("a drop-in the rules write in a shape this check cannot read",
         [("debian/rules", "androidd@.service.d/20-x.conf", "cannot read")],
         rules_extra="\tprintf '[Unit]\\nWants=androidd.service\\n' > $(UNITS)/androidd@.service.d/20-x.conf\n")
    case("a drop-in the CLI verb the postinst runs writes", [(root_hit,)],
         helper="printf '[Unit]\\nWants=androidd.service\\n' > /etc/systemd/system/androidd@.service.d/30-x.conf")

    lib = os.path.join(ROOT, "test", "system", "lib", "installer-lib.sh")
    same = "MARK androidd.service 0 0\\nMARK rhizo-prepare.service 5 7\\nMARK rhizo-policy.service 5 9\\n" \
           "MARK rhizo-update-begin.service 0 0\\nMARK rhizo-update-confirm.service 0 0\\n" \
           "MARK rhizo-selinux-mode.service 0 0\\nMARK rhizo-host-labels.service 0 0\\nDONE"
    moved = same.replace("androidd.service 0 0", "androidd.service 0 88")
    for name, before, after, want in (
            ("unchanged marks", same, same, None),
            ("androidd started during the install", same, moved, "androidd.service got a start job"),
            ("a unit file dpkg removed and put back, reloaded at 0 0", same,
             same.replace("rhizo-policy.service 5 9", "rhizo-policy.service 0 0"), None),
            ("a condition-skipped start", same, same.replace("rhizo-prepare.service 5 7", "rhizo-prepare.service 6 7"),
             "rhizo-prepare.service got a start job"),
            ("a read with no DONE", same, same.replace("\\nDONE", ""), "incomplete read"),
            ("a unit missing from the read", same, same.replace("MARK rhizo-policy.service 5 9\\n", ""),
             "rhizo-policy.service has no readable start marks")):
        rc, out = _bash('log() { :; }; source "%s"; installer_start_mark_problems "$(printf "%s")" "$(printf "%s")"'
                        % (lib, before, after))
        if want is None and (rc != 0 or out.strip()):
            fails.append("start marks, %s: want no problem, got rc=%d %r" % (name, rc, out))
        elif want is not None and want not in out:
            fails.append("start marks, %s: want %r, got rc=%d %r" % (name, want, rc, out))

    claim = os.path.join(ROOT, "test", "system", "cycle", "claims-server.sh")
    assert_lib = os.path.join(ROOT, "test", "system", "lib", "server-assert-lib.sh")
    harness = r'''
FAILED=0
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }
pass() { echo "PASS $*"; }
log() { :; }
source "%s"
source "%s"
lc_need_guest() { return 0; }
lc_need_assert_lib() { return 0; }
adb_endpoint_now() { :; }
lc_resolve_init() { echo 4242; }
lc_sandbox_up() { INIT=4242; }
ssh_vm() {
  case "${*: -1}" in
    *"-p TriggeredBy,WantedBy --value androidd.service"*) echo "$PROBE_DONE_TAG" ;;
    *"RequiredBy,BoundBy,UpheldBy"*) printf 'REV rhizo-update-confirm.service %%s\n%%s\n' "$PULLERS" "$PROBE_DONE_TAG" ;;
    *"is-active androidd.service"*) echo inactive ;;
    *) return 0 ;;
  esac
}
lc_assert_server.explicit-start-only
echo "RC=$? FAILED=$FAILED"
''' % (assert_lib, claim)
    for pullers, want in (("androidd.service", "RC=0 FAILED=0"),
                          ("multi-user.target androidd.service",
                           "rhizo-update-confirm.service is started by multi-user.target")):
        rc, out = _bash("PULLERS='%s'\n%s" % (pullers, harness))
        if want not in out:
            fails.append("server.explicit-start-only with pullers '%s': want %r, got %r" % (pullers, want, out[-600:]))

    for f in fails:
        print("SELFTEST FAILED: " + f)
    print("dpkg-no-policy-start.py selftest: " + ("FAILED" if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: dpkg-no-policy-start.py [--selftest]", file=sys.stderr)
        return 2
    problems = check(ROOT)
    for p in problems:
        print("dpkg-no-policy-start: " + p)
    if problems:
        return 1
    print("dpkg-no-policy-start: no dpkg path starts %s or a unit that pulls one, no boot target pulls "
          "androidd.service, and the vm system tests watch debian/rules' BOOT_ONLY_UNITS" % ", ".join(FORBIDDEN))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
