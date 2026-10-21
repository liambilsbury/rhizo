#!/usr/bin/env python3
import ast
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

PREPARE = "src/install/prepare/prepare.sh"
COMPOSER_RC = "src/androidd/guest/init/composer.rc"
MOUNTS = "src/androidd/sandbox/rootfs.py"
LAUNCHER = "src/androidd/boot.py"
TEST = "test/system/install/installer.sh"
FILES = (PREPARE, COMPOSER_RC, MOUNTS, LAUNCHER, TEST)

HELPER = "setup_boot_socket_state"
FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
HEREDOC_RE = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
BOUND_TEST_RE = re.compile(r'"?\$\{?socket_state\}?"?\s*==\s*"?bound"?(?![\w-])')
KEEP_RE = re.compile(r"(?:^|&&\s*|\|\|\s*)KEPT_RUNNING=1\b")
PARK_RE = re.compile(r"androidd-stop: supervisor \(([^|()]+)\|([^|()]+)\)")
STEP10_RE = re.compile(r'^\s*step "\[\$leg\] 10\.')
STEP_RE = re.compile(r'^\s*step "')
SETUP_RUN = 'test_pkgwin rhizo-install step7-install installer_install_reboot_prepare'

TEST_JOINS = (
    ("releasing the setup boot: socket", PREPARE),
    ("resident supervisor parked", PREPARE),
    ("wayland socket bind-mounted: ", MOUNTS),
)


def read(root, rel):
    """return the text of a file under the root, or None when unreadable"""
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def parse_shell(text):
    """parse a shell script into statements"""
    stmts, cur, cur_line = [], [], None
    quote, cont = None, False
    func_of, func = {}, None
    lines = text.split("\n")
    i = 0

    def flush():
        """append the current statement to the list and start a new one"""
        nonlocal cur, cur_line
        s = "".join(cur).strip()
        if s:
            stmts.append((cur_line, s))
        cur, cur_line = [], None

    while i < len(lines):
        line, n = lines[i], i + 1
        i += 1
        if quote is None and not cont:
            m = FUNC_RE.match(line)
            if m:
                func = m.group(1)
            elif line.startswith("}"):
                func_of[n] = func
                func = None
                continue
        func_of[n] = func
        start = len(cur)
        cont = False
        j = 0
        while j < len(line):
            c = line[j]
            if cur_line is None and not c.isspace():
                cur_line = n
            if quote == "'":
                if c == "'":
                    quote = None
                cur.append(c)
            elif quote == '"':
                if c == "\\" and j + 1 < len(line):
                    cur.append(line[j:j + 2])
                    j += 2
                    continue
                if c == '"':
                    quote = None
                cur.append(c)
            elif c == "#" and (j == 0 or line[j - 1] in " \t;("):
                break
            elif c in "'\"":
                quote = c
                cur.append(c)
            elif c == "\\" and j + 1 == len(line):
                cont = True
            elif c == ";":
                flush()
                start = 0
            else:
                cur.append(c)
            j += 1
        if quote is not None:
            cur.append("\n")
            continue
        m = HEREDOC_RE.search("".join(cur[start:]))
        if not cont:
            flush()
        if m:
            term = m.group(2)
            while i < len(lines) and lines[i].strip() != term:
                i += 1
            i += 1
    return stmts, func_of


def function_statements(stmts, func_of, name):
    """return the statements that belong to a named function"""
    return [(n, s) for n, s in stmts if func_of.get(n) == name]


def check_keep(prep):
    """return errors for unguarded KEPT_RUNNING=1 lines"""
    fails = []
    stmts, func_of = parse_shell(prep)
    stack = []
    for n, s in stmts:
        rest = s
        while rest:
            head, _, tail = rest.partition(" ")
            if head == "then" or head == "do":
                rest = tail.strip()
                continue
            break
        if re.match(r"if\b", rest):
            stack.append([rest[2:], False])
            continue
        if re.match(r"elif\b", rest) and stack:
            stack[-1] = [rest[4:], False]
            continue
        if re.match(r"else\b", rest) and stack:
            stack[-1][1] = True
            rest = rest[4:].strip()
        if re.match(r"fi\b", rest) and stack:
            stack.pop()
            continue
        m = KEEP_RE.search(rest)
        if not m:
            continue
        own = rest[:m.start()]
        guarded = bool(BOUND_TEST_RE.search(own)) or any(
            not in_else and BOUND_TEST_RE.search(cond) for cond, in_else in stack)
        fn = func_of.get(n) or "<top level>"
        if not guarded:
            conds = " / ".join(("else of " if e else "") + c.strip() for c, e in stack) or "no condition"
            fails.append(f"{PREPARE}:{n} {fn}() keeps the setup boot (KEPT_RUNNING=1) under "
                         f"'{conds}', which does not test socket_state == bound")
            continue
        for fn_n, fs in function_statements(stmts, func_of, func_of.get(n)):
            a = re.match(r"(?:local\s+)?socket_state=(.*)", fs)
            if a and a.group(1).strip() not in ('""', "") and not a.group(1).startswith(f"$({HELPER} "):
                fails.append(f"{PREPARE}:{fn_n} {fn}() sets socket_state from '{a.group(1)}', "
                             f"not from {HELPER} asking the sandbox")
    return fails


def helper_path(prep):
    """return the socket path from setup_boot_socket_state"""
    stmts, func_of = parse_shell(prep)
    body = " ".join(s for _, s in function_statements(stmts, func_of, HELPER))
    if not body:
        return None, False
    m = re.search(r"p=(/[^;\s'\"]+)", body)
    only_s = (len(re.findall(r"echo bound\b", body)) == 1
              and re.search(r"\[ -S \"?\$p\"? \]; then echo bound\b", body) is not None)
    return (m.group(1) if m else None), only_s


def composer_path(rc):
    """return the composer socket path set by the rc file, or None"""
    env = {}
    for line in rc.splitlines():
        m = re.match(r"\s*setenv\s+(XDG_RUNTIME_DIR|WAYLAND_DISPLAY)\s+(\S+)", line)
        if m:
            env.setdefault(m.group(1), set()).add(m.group(2))
    xdg, disp = env.get("XDG_RUNTIME_DIR", set()), env.get("WAYLAND_DISPLAY", set())
    if len(xdg) != 1 or len(disp) != 1:
        return None
    return os.path.join(next(iter(xdg)), next(iter(disp)))


def mounts_path(src):
    """return the composer socket path the mount helper binds, or None"""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None
    for fn in ast.walk(tree):
        if not (isinstance(fn, ast.FunctionDef) and fn.name == "_bind_sockets_and_shadows"):
            continue
        for node in ast.walk(fn):
            if not (isinstance(node, ast.Assign) and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "dst"
                    and isinstance(node.value, ast.JoinedStr)):
                continue
            parts = []
            for v in node.value.values:
                if isinstance(v, ast.Constant):
                    parts.append(str(v.value))
                elif not (isinstance(v.value, ast.Name) and v.value.id == "NEWROOT"):
                    parts = None
                    break
            if parts is not None and "rhizo_wayland" in "".join(parts):
                return "".join(parts)
    return None


def check_paths(prep, rc, mounts):
    """check that the socket paths agree"""
    fails = []
    p, only_s = helper_path(prep)
    c = composer_path(rc)
    b = mounts_path(mounts)
    if p is None:
        fails.append(f"{PREPARE} has no {HELPER}() naming the path it asks the sandbox about")
    elif not only_s:
        fails.append(f"{PREPARE} {HELPER}() answers bound on something other than a socket (-S) at {p}")
    if p is None or c is None or b is None or not p == c == b:
        fails.append("the setup boot's socket question and the composer disagree on the path: "
                     f"{PREPARE} {HELPER}() tests {p}, {COMPOSER_RC} opens "
                     f"XDG_RUNTIME_DIR/WAYLAND_DISPLAY = {c}, {MOUNTS} "
                     f"_bind_sockets_and_shadows() binds dst = {b}")
    return fails


def launcher_strings(src, func):
    """return the strings in a launcher function"""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return []
    out = []
    for fn in ast.walk(tree):
        if isinstance(fn, ast.FunctionDef) and fn.name == func:
            out += [n.value for n in ast.walk(fn)
                    if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    return out


def check_park(prep, launcher):
    """check the park line against the launcher's androidd stop"""
    m = PARK_RE.search(prep)
    if not m:
        return [f"{PREPARE} reads no androidd-stop park line after releasing the setup boot"]
    fails = []
    said = launcher_strings(launcher, "androidd_stop")
    for alt in (m.group(1), m.group(2)):
        line = "androidd-stop: supervisor " + alt
        if not any(line in s for s in said):
            fails.append(f"{PREPARE} waits for '{line}', which {LAUNCHER} androidd_stop() never "
                         "logs")
    if f'"supervisor {m.group(1)}"' not in prep:
        fails.append(f"{PREPARE} accepts a park on a line other than 'supervisor {m.group(1)}'")
    return fails


def _stops_androidd(s):
    """return whether a statement stops androidd"""
    return "systemctl stop androidd.service" in s or ("systemctl stop" in s and "ANDROIDD_UNIT" in s)


def _starts_androidd(s):
    """return whether a statement starts androidd"""
    return "systemctl start androidd.service" in s or ("systemctl start" in s and "ANDROIDD_UNIT" in s)


def check_knobs(prep):
    """check the setup boot env settings"""
    stmts, func_of = parse_shell(prep)
    if not any(_stops_androidd(s) for _, s in stmts):
        return [f"{PREPARE} stops no androidd unit by any spelling this check knows"]
    body = function_statements(stmts, func_of, "run_setup_boot")
    start = next((i for i, (_, s) in enumerate(body) if _starts_androidd(s)), None)
    if start is None:
        return [f"{PREPARE} run_setup_boot() starts no androidd.service"]
    for _, s in body[:start]:
        if ("RHIZO_RESIDENT_G=1" in s and "RHIZO_RESIDENT_DISPATCH=1" in s
                and re.search(r">>?\s*\"?\$(?:env_file|RUNTIME_ENV)", s)):
            return []
    return [f"{PREPARE} releases the setup boot, but run_setup_boot() writes no "
            "RHIZO_RESIDENT_G=1 and RHIZO_RESIDENT_DISPATCH=1 into the unit's env before "
            "starting it"]


def quoted_literals(code, needle):
    """return the quoted literals in code that contain a needle"""
    return [a or b for a, b in re.findall(r"'([^'\n]*)'|\"([^\"\n]*)\"", code)
            if needle in (a or b)]


def check_test(test, texts):
    """check the installer.sh system test"""
    fails = []
    lines = test.split("\n")
    code = [(n, ln) for n, ln in enumerate(lines, 1) if not ln.lstrip().startswith("#")]
    s10 = next((i for i, (_, ln) in enumerate(code) if STEP10_RE.match(ln)), None)
    if s10 is None:
        return [f"{TEST} has no step 10"]
    e10 = next((i for i in range(s10 + 1, len(code)) if STEP_RE.match(code[i][1])), len(code))
    region = code[s10:e10]
    for n, ln in region:
        if re.search(r"is-active androidd\.service.*\|\|.*systemctl start", ln):
            fails.append(f"{TEST}:{n} step 10 accepts whatever sandbox is already running "
                         "(is-active || start) instead of starting the one it tests")
    region_code = "\n".join(ln for _, ln in region)
    if not quoted_literals(region_code, "wayland socket bind-mounted: "):
        fails.append(f"{TEST} step 10 never asserts the sandbox it tests bound the compositor socket")

    ret = next((i for i, (_, ln) in enumerate(code) if ln.strip().startswith(SETUP_RUN)), None)
    sway = next((i for i, (_, ln) in enumerate(code)
                 if "../../vm/start/start-sway.sh" in ln and "--stage-login" not in ln), None)
    if ret is None or sway is None or not ret < sway < s10:
        where = "never" if sway is None else f"at line {code[sway][0]}"
        fails.append(f"{TEST} starts the session {where}; it must start after the install's "
                     "setup boot, and before step 10")
    pre10 = "\n".join(ln for _, ln in code[ret + 1 if ret is not None else 0:s10])
    if not quoted_literals(pre10, "releasing the setup boot: socket"):
        fails.append(f"{TEST} never asserts prepare released its setup boot before step 10")

    for needle, product in TEST_JOINS:
        for lit in quoted_literals("\n".join(ln for _, ln in code), needle):
            if lit not in (texts.get(product) or ""):
                fails.append(f"{TEST} matches '{lit}', which {product} never prints")
    return fails


INSTALLER_LIB = "test/system/lib/installer-lib.sh"


def check(root):
    """run all the setup boot release checks"""
    texts = {rel: read(root, rel) for rel in FILES}
    missing = [rel for rel, t in texts.items() if t is None]
    if missing:
        return [f"cannot read {rel}" for rel in missing]
    prep = texts[PREPARE]
    test_text = texts[TEST]
    installer_lib = read(root, INSTALLER_LIB)
    if installer_lib is not None:
        test_text = test_text + "\n" + installer_lib
    return (check_keep(prep)
            + check_paths(prep, texts[COMPOSER_RC], texts[MOUNTS])
            + check_park(prep, texts[LAUNCHER])
            + check_knobs(prep)
            + check_test(test_text, texts))


PRE_FIX_TAIL = """  if (( KEEP_RUNNING )); then
    log "leaving androidd.service running -- this host has no second start to spend"
    sync; sync
    KEPT_RUNNING=1
  else
  log "stopping androidd.service"
  systemctl stop androidd.service
  sync; sync
  fi
"""


def mutate(root, rel, old, new):
    """replace a text in a file under the root"""
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(old) != 1:
        raise SystemExit(f"selftest fixture anchor found {text.count(old)} times in {rel}: {old!r}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(old, new))


def fixture():
    """return a temporary copy of the checked files"""
    tmp = tempfile.mkdtemp(prefix="check-setup-boot-release.")
    for rel in FILES:
        os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), os.path.join(tmp, rel))
    return tmp


CASES = (
    ("the pre-fix keep block in run_setup_boot", ("run_setup_boot()",),
     [(PREPARE, '  keep_or_release_setup_boot "$probe" "$sock"\n', PRE_FIX_TAIL)]),
    ("a keep that tests only --keep-running", ("keep_or_release_setup_boot()",),
     [(PREPARE, 'if (( KEEP_RUNNING )) && [[ "$socket_state" == bound ]]; then',
       "if (( KEEP_RUNNING )); then")]),
    ("a keep on a socket that is not bound", ("keep_or_release_setup_boot()",),
     [(PREPARE, '[[ "$socket_state" == bound ]]', '[[ "$socket_state" != bound ]]')]),
    ("a socket state not asked of the sandbox", ("socket_state from 'bound'",),
     [(PREPARE, 'socket_state=$(setup_boot_socket_state "$1" "$2")', "socket_state=bound")]),
    ("the composer opening wayland-1", (PREPARE, COMPOSER_RC, MOUNTS, "wayland-1"),
     [(COMPOSER_RC, "setenv WAYLAND_DISPLAY wayland-0", "setenv WAYLAND_DISPLAY wayland-1")]),
    ("a bind renamed in sandbox/rootfs.py", ("rhizo_wayland/wayland-9",),
     [(MOUNTS, 'dst = f"{NEWROOT}/dev/socket/rhizo_wayland/wayland-0"',
       'dst = f"{NEWROOT}/dev/socket/rhizo_wayland/wayland-9"')]),
    ("the helper answering bound on a regular file", ("other than a socket",),
     [(PREPARE, "if [ -S $p ]; then echo bound", "if [ -e $p ]; then echo bound")]),
    ("a reworded park line", ("supervisor parked, stack is stopped",),
     [(LAUNCHER, 'kmsg("androidd-stop: supervisor parked, stack is stopped")',
       'kmsg("androidd-stop: supervisor parked and the stack is stopped")')]),
    ("the resident knobs removed", ("RHIZO_RESIDENT_G=1",),
     [(PREPARE, "printf 'RHIZO_WIPE_DATA=0\\nRHIZO_RESIDENT_G=1\\nRHIZO_RESIDENT_DISPATCH=1\\n'",
       "printf 'RHIZO_WIPE_DATA=0\\n'")]),
    ("step 10 accepting a running sandbox", ("is-active || start",),
     [(TEST, "ssh_vm -t 600 'systemctl start androidd.service'",
       "ssh_vm -t 600 'systemctl is-active androidd.service >/dev/null 2>&1 || systemctl start androidd.service'")]),
    ("step 10 without the socket assertion", ("never asserts the sandbox it tests",),
     [(TEST, "*'wayland socket bind-mounted: '*", "*'wayland socket '*")]),
    ("the session started before prepare", ("starts the session",),
     [(TEST, '  step "[$leg] 7-9. one command, one reboot, setup finished on its own"\n',
       '  ../../vm/start/start-sway.sh >/dev/null 2>&1\n  step "[$leg] 7-9. one command, one reboot, setup finished on its own"\n')]),
    ("the session left to step 5's staged login", ("starts the session",),
     [(TEST, 'if ! ../../vm/start/start-sway.sh >"$EV/$leg-sway.log" 2>&1; then',
       'if ! true >"$EV/$leg-sway.log" 2>&1; then')]),
    ("the system test grepping a release line prepare never prints", ("never prints",),
     [(PREPARE, 'log "releasing the setup boot: socket $socket_state',
       'log "released the setup boot: socket $socket_state')]),
)


def selftest():
    """run each planted-defect case"""
    bad = 0
    for name, wants, edits in CASES:
        tmp = fixture()
        try:
            for rel, old, new in edits:
                mutate(tmp, rel, old, new)
            fails = check(tmp)
        finally:
            shutil.rmtree(tmp)
        text = "\n".join(fails)
        missed = [w for w in wants if w not in text]
        if not fails or missed:
            bad += 1
            print(f"SELFTEST FAIL: {name}: not caught by name (missing {missed}); got:\n  "
                  + "\n  ".join(fails or ["<no failure>"]))
        else:
            print(f"ok   {name}")
    tmp = fixture()
    try:
        fails = check(tmp)
    finally:
        shutil.rmtree(tmp)
    if fails:
        bad += 1
        print("SELFTEST FAIL: the unmodified tree does not pass:\n  " + "\n  ".join(fails))
    else:
        print("ok   the unmodified tree passes")
    if bad:
        print(f"check-setup-boot-release selftest: {bad} case(s) failed")
        return 1
    print(f"check-setup-boot-release selftest: {len(CASES) + 1} cases passed")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    fails = check(ROOT)
    for f in fails:
        print("FAIL: " + f)
    if fails:
        return 1
    print("check-setup-boot-release: a setup boot is kept only with a bound socket, released "
          "only to a parked supervisor, and the system tests the sandbox it starts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
