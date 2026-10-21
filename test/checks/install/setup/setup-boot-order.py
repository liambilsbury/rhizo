#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
PREPARE_SH = os.path.join(ROOT, "src", "install", "prepare", "prepare.sh")
RULES = os.path.join(ROOT, "debian", "rules")
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
from unit_files import installed_name, unit_path  # noqa: E402

PREPARE_UNIT = "rhizo-prepare.service"
POLICY_UNIT = "rhizo-policy.service"
SETUP_BOOT_UNIT = "androidd.service"
BOOT_TARGETS = ("multi-user.target", "graphical.target")
SELINUX_CONDITION = "/sys/fs/selinux/enforce"
DEPS = ("After", "Before", "Wants", "Requires", "BindsTo", "WantedBy")


def parse_unit(text, into=None):
    """merge a unit file into a directive table"""
    out = into if into is not None else {}
    for line in text.replace("\\\n", " ").splitlines():
        line = line.strip()
        if not line or line[0] in "#;[" or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key, val = key.strip(), val.strip()
        if not val:
            out[key] = []
            continue
        vals = val.split() if key in DEPS else [val]
        out.setdefault(key, []).extend(vals)
    return out


def packaged_units(rules_text, root):
    """return the units debian/rules installs"""
    units = {}
    for rel in sorted(set(re.findall(
            r"(src/services/(?:[A-Za-z0-9_.-]+/)*?[A-Za-z0-9_.@-]+\.(?:service|path|socket|target))(?![A-Za-z0-9_.@-])",
            rules_text))):
        path = os.path.join(root, rel)
        if os.path.exists(path):
            with open(path) as f:
                units[installed_name(os.path.basename(rel))] = parse_unit(f.read())
    for src, unit in re.findall(
            r"(debian/dropins/\S+\.conf)[\s\\\"]+\S*?/([A-Za-z0-9_.@-]+)\.d/[^\s\"]+\.conf", rules_text):
        if unit in units:
            with open(os.path.join(root, src)) as f:
                parse_unit(f.read(), units[unit])
    return units


def _function_body(text, name):
    """return the body of a named shell function, or None"""
    m = re.search(r"^%s\(\)\s*\{[^\n]*\n(.*?)^\}" % re.escape(name), text, re.S | re.M)
    return m.group(1) if m else None


ANDROIDD_RE = re.compile(r"\$\{?ANDROIDD_UNIT\}?|androidd(@\S*)?\.service")
START_VERBS = {"start", "restart", "try-restart", "reload-or-restart", "try-reload-or-restart",
               "force-reload", "condrestart", "isolate"}
NONSTART_VERBS = {"stop", "cat", "show", "status", "is-active", "is-failed", "is-enabled", "kill",
                  "reset-failed", "reload", "daemon-reload", "disable", "mask", "unmask", "list-units",
                  "list-dependencies", "show-environment", "freeze", "unfreeze", "clean"}
ENABLE_VERBS = {"enable", "reenable"}
_CMD_POS = r"(?:^|[;&|({`]|\$\(|\b(?:if|then|do|else|elif|while|until)\b|!)\s*"
_CMD_POS_END = re.compile(_CMD_POS + r"$")
_REDIRECT = re.compile(r"^\d*(?:>>?|<)|^&>")


def _code_lines(body):
    """yield the code lines of body"""
    for line in body.replace("\\\n", " ").splitlines():
        yield re.split(r"(?:^|\s)#", line, maxsplit=1)[0]


def _in_quotes(prefix):
    """check prefix for an open quote"""
    return len(re.findall(r'(?<!\\)"', prefix)) % 2 == 1 or prefix.count("'") % 2 == 1


def _classify_systemctl(rest):
    """classify the arguments of a systemctl call"""
    rest = re.split(r"\s*(?:;|&&|\|\||\||\)|`)", rest, maxsplit=1)[0]
    tokens = [t.strip("\"'") for t in rest.split() if not _REDIRECT.match(t)]
    positional = [t for t in tokens if not t.startswith("-")]
    if not positional:
        return None, None
    verb, operands = positional[0], positional[1:]
    on_androidd = any(ANDROIDD_RE.search(o) for o in operands)
    on_var = any("$" in o and not ANDROIDD_RE.search(o) for o in operands)
    starts = verb in START_VERBS or (verb in ENABLE_VERBS and "--now" in tokens)
    if "$" in verb:
        return ("unclassified", "its verb is computed at runtime") if on_androidd or on_var else (None, None)
    if starts and on_androidd:
        return "start", [t for t in tokens if not ANDROIDD_RE.search(t)]
    if starts and on_var:
        return "unclassified", "it starts a unit named at runtime, which may be androidd"
    if starts or verb in NONSTART_VERBS or verb in ENABLE_VERBS:
        return None, None
    return ("unclassified", f"`{verb}` is no verb this check knows") if on_androidd or on_var else (None, None)


def _androidd_calls(body):
    """return the systemctl calls on androidd"""
    starts, unclassified = [], []
    for code in _code_lines(body):
        for m in re.finditer(r"\bsystemctl\b", code):
            prefix, rest = code[:m.start()], code[m.end():]
            if not _CMD_POS_END.search(prefix):
                if not _in_quotes(prefix) and ANDROIDD_RE.search(rest.split("#", 1)[0]):
                    unclassified.append((code.strip(), "systemctl is not in command position"))
                continue
            kind, what = _classify_systemctl(rest)
            if kind == "start":
                starts.append(what)
            elif kind == "unclassified":
                unclassified.append((code.strip(), what))
    return starts, unclassified


def _called(body, text, exclude):
    """return the names of functions called in body"""
    names = set()
    for code in _code_lines(body):
        for m in re.finditer(_CMD_POS + r"([A-Za-z_][A-Za-z0-9_]*)\b", code):
            n = m.group(1)
            if n not in exclude and not _in_quotes(code[:m.start(1)]) and _function_body(text, n) is not None:
                names.add(n)
    return names


def setup_boot_calls(prepare_text):
    """return the androidd starts in run_setup_boot()"""
    body = _function_body(prepare_text, "run_setup_boot")
    if body is None:
        return None, []
    starts, unclassified = _androidd_calls(body)
    unclassified = [("run_setup_boot", line, why) for line, why in unclassified]
    seen = {"run_setup_boot"}
    todo = sorted(_called(body, prepare_text, seen))
    while todo:
        name = todo.pop(0)
        if name in seen:
            continue
        seen.add(name)
        fn = _function_body(prepare_text, name)
        got, unread = _androidd_calls(fn)
        starts += [a for a in got if "--no-block" not in a]
        unclassified += [(name, line, why) for line, why in unread]
        todo += sorted(_called(fn, prepare_text, seen))
    return starts, unclassified


def setup_boot_starts(prepare_text):
    """return the starts from setup_boot_calls()"""
    return setup_boot_calls(prepare_text)[0]


def closure(units, start, keys=("Wants", "Requires", "BindsTo")):
    """return start and its required units"""
    seen, todo = set(), [start]
    while todo:
        u = todo.pop()
        if u in seen:
            continue
        seen.add(u)
        for k in keys:
            todo.extend(units.get(u, {}).get(k, []))
    return seen


def wait_cycle(units, start_argv, prepare_unit=PREPARE_UNIT, setup_unit=SETUP_BOOT_UNIT):
    """return the wait cycle through prepare_unit"""
    mode = next((a.split("=", 1)[1] for a in start_argv if a.startswith("--job-mode=")), "replace")
    ignore_order = mode == "ignore-dependencies"
    ignore_reqs = mode in ("ignore-dependencies", "ignore-requirements")
    jobs = set()
    for name, d in units.items():
        if any(t in BOOT_TARGETS for t in d.get("WantedBy", [])):
            jobs |= closure(units, name)
    jobs |= {setup_unit} if ignore_reqs else closure(units, setup_unit)
    jobs = {j for j in jobs if j in units}
    waits = {j: set() for j in jobs}
    for a in jobs:
        if a == setup_unit and ignore_order:
            continue
        for b in jobs:
            if b != a and (b in units[a].get("After", []) or a in units[b].get("Before", [])):
                waits[a].add(b)
    waits.setdefault(prepare_unit, set()).add(setup_unit)
    path, on_path = [prepare_unit], {prepare_unit}

    def walk(u):
        """return a wait cycle path back to the prepare unit"""
        for v in sorted(waits.get(u, ())):
            if v == prepare_unit:
                return path + [v]
            if v not in on_path:
                path.append(v)
                on_path.add(v)
                found = walk(v)
                if found:
                    return found
                on_path.discard(path.pop())
        return None
    return walk(prepare_unit)


def condition_problems(units):
    """return the problems with the policy unit's SELinux condition"""
    policy = units.get(POLICY_UNIT)
    if policy is None:
        return [f"{POLICY_UNIT} is not among the packaged units"]
    if SELINUX_CONDITION not in policy.get("ConditionPathExists", []):
        return [f"{POLICY_UNIT} has no ConditionPathExists={SELINUX_CONDITION}: on a boot "
                f"SELinux is not the active LSM it runs, reads AppArmor's label and fails"]
    return []


VERIFY_BAD = re.compile(r"Unknown (key|section)|Failed to parse|Invalid|Missing '='|"
                        r"ordering cycle|Found ordering cycle")
VERIFY_NOT_INSTALLED = re.compile(r"^\S+\.(service|path|socket|target): Command /usr/lib/rhizo/\S+ is not "
                                  r"executable: No such file or directory$")
CANARY_NAME = "rhizo-verify-canary.service"
CANARY_UNIT = "[Unit]\nExecCondition=/bin/true\n[Service]\nType=oneshot\nExecStart=/bin/true\n"
CANARY_FLAG = re.compile(r"Unknown key (name )?'ExecCondition'")


def verify_problems(paths, analyze="systemd-analyze"):
    """return the systemd-analyze verify problems"""
    if not shutil.which(analyze):
        return [f"{analyze} not found -- cannot verify the unit files"]
    tmp = tempfile.mkdtemp(prefix="check-setup-boot-order.")
    try:
        canary = os.path.join(tmp, CANARY_NAME)
        with open(canary, "w") as f:
            f.write(CANARY_UNIT)
        r = subprocess.run([analyze, "verify", "--man=no", canary] + list(paths), capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    lines = (r.stdout + r.stderr).splitlines()
    ours = [ln for ln in lines if CANARY_NAME not in ln]
    problems = [ln for ln in ours if VERIFY_BAD.search(ln)]
    if not any(CANARY_NAME in ln and CANARY_FLAG.search(ln) for ln in lines):
        problems.append(f"systemd-analyze verify did not flag the canary's ExecCondition= in [Unit] (rc={r.returncode}): "
                        f"{' | '.join(lines[-3:]) or '<no output>'}")
    unexplained = [ln for ln in ours if not VERIFY_BAD.search(ln) and not VERIFY_NOT_INSTALLED.match(ln)]
    if r.returncode != 0:
        problems += [f"systemd-analyze verify exited {r.returncode}: {ln}" for ln in unexplained]
        if not ours:
            problems.append(f"systemd-analyze verify exited {r.returncode} naming nothing about the units")
    return problems


def check(units, prepare_text, unit_paths=()):
    """check the boot order of the setup units"""
    problems = []
    starts, unclassified = setup_boot_calls(prepare_text)
    if not starts:
        problems.append(f"no systemctl start of $ANDROIDD_UNIT in {os.path.relpath(PREPARE_SH, ROOT)}'s "
                        "run_setup_boot() -- nothing to model")
    for fn, line, why in unclassified:
        problems.append(f"{fn}(): cannot tell whether `{line}` starts androidd ({why})")
    for argv in starts or ():
        cyc = wait_cycle(units, argv)
        if cyc:
            problems.append("setup boot `systemctl %s $ANDROIDD_UNIT` deadlocks: %s"
                            % (" ".join(argv), " waits for ".join(cyc)))
    problems += condition_problems(units)
    if unit_paths:
        problems += verify_problems(unit_paths)
    return problems


def _units(**texts):
    """return parsed units keyed by service name from unit texts"""
    return {name.replace("_", "-").replace("-service", ".service"): parse_unit(t)
            for name, t in texts.items()}


PREPARE_FIXTURE = """run_setup_boot() {
  systemctl daemon-reload
  if ! systemctl start %s "$ANDROIDD_UNIT"; then
    failstop "setup-boot-start-failed" "systemctl start $ANDROIDD_UNIT failed"
  fi
  keep_or_release_setup_boot "$probe" "$sock"
}
keep_or_release_setup_boot() {  # start androidd.service
  systemctl start %s "$ANDROIDD_UNIT"
}
"""


def _prepare(setup_flags, keep_flags="--no-block"):
    """return the prepare script fixture with the given flags"""
    return PREPARE_FIXTURE % (setup_flags, keep_flags)


def selftest():
    """run the boot order checks on fixtures"""
    fails = []
    base = dict(
        rhizo_prepare_service="[Unit]\nAfter=systemd-modules-load.service\n"
                              "Before=display-manager.service\n[Install]\nWantedBy=multi-user.target\n",
        rhizo_policy_service=f"[Unit]\nConditionPathExists={SELINUX_CONDITION}\n"
                             "After=rhizo-prepare.service\nBefore=display-manager.service\n"
                             "[Install]\nWantedBy=multi-user.target\n",
        androidd_service="[Unit]\nAfter=rhizo-policy.service\nWants=rhizo-policy.service\n",
    )

    def expect(name, units, flags, want_cycle, keep="--no-block"):
        """record a failure unless the cycle finding matches"""
        found = [p for p in check(units, _prepare(flags, keep)) if "deadlocks" in p]
        if bool(found) != want_cycle:
            fails.append(f"{name}: want {'a cycle' if want_cycle else 'no cycle'}, got {found or 'none'}")
        return found

    got = expect("prepare, androidd and policy ordered in a loop, an ordinary start", _units(**base), "", True)
    if got and "rhizo-prepare.service waits for androidd.service waits for rhizo-policy.service " \
               "waits for rhizo-prepare.service" not in got[0]:
        fails.append(f"the cycle is not named hop by hop: {got[0]}")
    expect("prepare, androidd and policy ordered in a loop, --job-mode=ignore-dependencies", _units(**base),
           "--job-mode=ignore-dependencies", False)
    expect("--no-block still waits on boot_completed", _units(**base), "--no-block", True)
    expect("ignore-requirements still honors the policy job's order", _units(**base),
           "--job-mode=ignore-requirements", True)
    no_wants = dict(base, androidd_service="[Unit]\nAfter=rhizo-policy.service\n")
    expect("After= alone, the boot job queued", _units(**no_wants), "", True)
    refresh = dict(base,
                   rhizo_policy_service=f"[Unit]\nConditionPathExists={SELINUX_CONDITION}\n",
                   androidd_service="[Unit]\n",
                   rhizo_kernel_refresh_service="[Unit]\nAfter=rhizo-prepare.service\n"
                                                "Before=androidd.service\n"
                                                "[Install]\nWantedBy=multi-user.target\n")
    expect("a Before=androidd unit ordered after prepare", _units(**refresh), "", True)
    expect("the same, ignore-dependencies", _units(**refresh), "--job-mode=ignore-dependencies", False)
    acyclic = dict(base, rhizo_policy_service=f"[Unit]\nConditionPathExists={SELINUX_CONDITION}\n"
                                              "[Install]\nWantedBy=multi-user.target\n")
    expect("policy not ordered after prepare", _units(**acyclic), "", False)
    bound = dict(base, rhizo_policy_service=f"[Unit]\nConditionPathExists={SELINUX_CONDITION}\n",
                 androidd_service="[Unit]\nBindsTo=x.service\nAfter=x.service\n",
                 x_service="[Unit]\nAfter=rhizo-prepare.service\n")
    expect("a BindsTo= unit ordered after prepare", _units(**bound), "", True)
    expect("the same, ignore-dependencies", _units(**bound), "--job-mode=ignore-dependencies", False)
    reset = _units(**base)
    parse_unit("[Unit]\nAfter=\nWants=\n", reset["androidd.service"])
    expect("a drop-in reset androidd's ordering", reset, "", False)
    if not any("nothing to model" in p for p in check(_units(**base), "run_setup_boot() {\n}\n")):
        fails.append("a run_setup_boot() with no start was not flagged")
    if not any("nothing to model" in p for p in check(_units(**base), "other() {\n  systemctl start x\n}\n")):
        fails.append("a prepare script with no run_setup_boot() was not flagged")
    stop_only = "run_setup_boot() {\n  systemctl stop \"$ANDROIDD_UNIT\"\n}\n"
    if not any("nothing to model" in p for p in check(_units(**base), stop_only)):
        fails.append("a stop was read as the setup boot's start")
    message_only = 'run_setup_boot() {\n  failstop "x" "systemctl start $ANDROIDD_UNIT failed"\n}\n'
    if not any("nothing to model" in p for p in check(_units(**base), message_only)):
        fails.append("a failstop message naming systemctl start was read as a call")
    got_starts = setup_boot_starts(_prepare("--job-mode=ignore-dependencies"))
    if got_starts != [["start", "--job-mode=ignore-dependencies"]]:
        fails.append("the fixture's one blocking start was not read with its flag: %r" % got_starts)
    expect("a helper's blocking start", _units(**base), "--job-mode=ignore-dependencies", True, keep="")
    expect("a helper's --no-block start", _units(**base), "--job-mode=ignore-dependencies", False)
    tmp = tempfile.mkdtemp(prefix="check-setup-boot-order.")
    try:
        os.makedirs(os.path.join(tmp, "src", "services", "units", "boot"))
        os.makedirs(os.path.join(tmp, "debian", "dropins"))
        for name, body in (("androidd.service", "[Unit]\nAfter=rhizo-policy.service\n"),
                           ("androidd@.service", "[Unit]\n")):
            with open(os.path.join(tmp, "src", "services", "units", "boot", name), "w") as f:
                f.write(body)
        for name, body in (("a.conf", "[Unit]\nWants=x.service\n"), ("b.conf", "[Unit]\nWants=y.service\n")):
            with open(os.path.join(tmp, "debian", "dropins", name), "w") as f:
                f.write(body)
        rules = ("\tinstall -m 0644 src/services/units/boot/androidd.service src/services/units/boot/androidd@.service $(UNITS)/\n"
                 "\tinstall -D -m 0644 debian/dropins/a.conf \\\n"
                 "\t                   $(UNITS)/androidd.service.d/20-a.conf\n"
                 "\tinstall -D -m 0644 debian/dropins/b.conf \\\n"
                 "\t                   \"$(UNITS)/androidd@.service.d/10-b.conf\"\n")
        got_units = packaged_units(rules, tmp)
        if got_units.get("androidd.service", {}).get("Wants") != ["x.service"] \
                or got_units.get("androidd@.service", {}).get("Wants") != ["y.service"]:
            fails.append("a drop-in installed across a line continuation was not applied: %r" % got_units)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    no_cond = dict(base, rhizo_policy_service="[Unit]\nAfter=rhizo-prepare.service\n")
    if not condition_problems(_units(**no_cond)):
        fails.append(f"{POLICY_UNIT} without ConditionPathExists={SELINUX_CONDITION} was not flagged")
    if condition_problems(_units(**base)):
        fails.append(f"{POLICY_UNIT} with ConditionPathExists={SELINUX_CONDITION} was flagged")
    tmp = tempfile.mkdtemp(prefix="check-setup-boot-order.")
    try:
        bad = os.path.join(tmp, "rhizo-x.service")
        good = os.path.join(tmp, "rhizo-y.service")
        with open(bad, "w") as f:
            f.write("[Unit]\nExecCondition=/bin/true\n[Service]\nType=oneshot\nExecStart=/bin/true\n")
        with open(good, "w") as f:
            f.write("[Unit]\nDescription=y\n[Service]\nType=oneshot\nExecCondition=/bin/true\n"
                    "ExecStart=/bin/true\n")
        if not any("Unknown key" in p and "rhizo-x.service" in p for p in verify_problems([bad])):
            fails.append("ExecCondition= in [Unit] was not flagged by systemd-analyze verify")
        if verify_problems([good]):
            fails.append(f"a well-formed unit was flagged: {verify_problems([good])}")
        uninstalled = os.path.join(tmp, "rhizo-u.service")
        elsewhere = os.path.join(tmp, "rhizo-e.service")
        with open(uninstalled, "w") as f:
            f.write("[Unit]\nDescription=u\n[Service]\nType=oneshot\nExecStart=/usr/lib/rhizo/install/nope.sh\n")
        with open(elsewhere, "w") as f:
            f.write("[Unit]\nDescription=e\n[Service]\nType=oneshot\nExecStart=/opt/nope/x\n")
        if verify_problems([uninstalled]):
            fails.append(f"a unit whose only complaint is an uninstalled /usr/lib/rhizo command was flagged: "
                         f"{verify_problems([uninstalled])}")
        if not any("exited 1: " in p and "/opt/nope/x" in p for p in verify_problems([elsewhere])):
            fails.append(f"a non-zero verify for a missing /opt command was not flagged: {verify_problems([elsewhere])}")
        for name, body, want in (
                ("broken", 'echo "Failed to initialize manager: Operation not permitted" >&2; exit 1\n',
                 "exited 1: Failed to initialize manager"),
                ("blind", "exit 0\n", "did not flag the canary"),
                ("pre-262", f'for a; do case "$a" in *{CANARY_NAME}) echo "$a:2: Unknown key name '
                 f"'ExecCondition' in section 'Unit', ignoring.\" >&2;; *rhizo-x.service) echo \"$a:2: Unknown key name "
                 f"'ExecCondition' in section 'Unit', ignoring.\" >&2;; esac; done; exit 0\n", "")):
            fake = os.path.join(tmp, "systemd-analyze-" + name)
            with open(fake, "w") as f:
                f.write("#!/bin/sh\n" + body)
            os.chmod(fake, 0o755)
            if name == "pre-262":
                if verify_problems([good], analyze=fake):
                    fails.append(f"a pre-262 systemd-analyze's canary wording was not read: {verify_problems([good], analyze=fake)}")
                if not any("Unknown key name" in p and "rhizo-x.service" in p for p in verify_problems([bad], analyze=fake)):
                    fails.append("a pre-262 systemd-analyze's wording for a bad unit was not flagged")
                continue
            got = verify_problems([good], analyze=fake)
            if not any(want in p for p in got):
                fails.append(f"a systemd-analyze that is {name} was not flagged naming {want!r}: {got}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    ign = '  if ! systemctl start --job-mode=ignore-dependencies "$ANDROIDD_UNIT"; then\n    failstop x y\n  fi\n'
    for name, body, helpers, want in (
            ("a restart", ign + '  systemctl restart "$ANDROIDD_UNIT"\n', "", "deadlocks"),
            ("the braced variable", ign + '  systemctl start "${ANDROIDD_UNIT}"\n', "", "deadlocks"),
            ("the literal unit name", ign + "  systemctl start androidd.service\n", "", "deadlocks"),
            ("enable --now", ign + '  systemctl enable --now "$ANDROIDD_UNIT"\n', "", "deadlocks"),
            ("a helper called inside if", ign + "  if ! boot_it; then failstop x y; fi\n",
             'boot_it() {\n  systemctl start "$ANDROIDD_UNIT"\n}\n', "deadlocks"),
            ("a helper called inside $( )", ign + "  out=$(boot_it)\n",
             'boot_it() {\n  systemctl start "$ANDROIDD_UNIT"\n}\n', "deadlocks"),
            ("a helper two calls down", ign + "  outer\n",
             'outer() {\n  inner\n}\ninner() {\n  systemctl start "$ANDROIDD_UNIT"\n}\n', "deadlocks"),
            ("a helper two calls down, --no-block", ign + "  outer\n",
             'outer() {\n  inner\n}\ninner() {\n  systemctl start --no-block "$ANDROIDD_UNIT"\n}\n', None),
            ("a computed verb", ign + '  systemctl "$verb" "$ANDROIDD_UNIT"\n', "", "its verb is computed at runtime"),
            ("a start of a unit named at runtime", ign + '  systemctl start "$unit"\n', "",
             "starts a unit named at runtime"),
            ("an unknown verb", ign + '  systemctl frobnicate "$ANDROIDD_UNIT"\n', "", "no verb this check knows"),
            ("systemctl behind a wrapper", ign + '  timeout 60 systemctl start "$ANDROIDD_UNIT"\n', "",
             "systemctl is not in command position"),
            ("the calls that start nothing",
             ign + '  env=$(systemctl cat "$ANDROIDD_UNIT" 2>/dev/null | sed -n p)\n'
             '  systemctl is-active "$ANDROIDD_UNIT" >/dev/null\n  systemctl stop "$ANDROIDD_UNIT"\n'
             '  log "systemctl restart $ANDROIDD_UNIT is not run here"\n', "", None)):
        got = check(_units(**base), "run_setup_boot() {\n" + body + "}\n" + helpers)
        hit = [p for p in got if want and want in p]
        if want and not hit:
            fails.append(f"{name}: no problem naming {want!r}, got {got}")
        if not want and got:
            fails.append(f"{name}: flagged {got}")
    for f in fails:
        print("SELFTEST FAILED: " + f)
    print("setup-boot-order.py selftest: " + ("FAILED" if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: setup-boot-order.py [--selftest]", file=sys.stderr)
        return 2
    with open(RULES) as f:
        rules = f.read()
    with open(PREPARE_SH) as f:
        prepare = f.read()
    units = packaged_units(rules, ROOT)
    for need in (PREPARE_UNIT, POLICY_UNIT, SETUP_BOOT_UNIT):
        if need not in units:
            print(f"setup-boot-order: {need} is not among the units debian/rules installs")
            return 1
    if not any("prepare.sh" in e and "--kernel-refresh" not in e
               for e in units[PREPARE_UNIT].get("ExecStart", [])):
        print(f"setup-boot-order: {PREPARE_UNIT}'s ExecStart no longer runs prepare.sh")
        return 1
    paths = [unit_path(ROOT, u) for u in (PREPARE_UNIT, POLICY_UNIT, SETUP_BOOT_UNIT, "rhizo-kernel-refresh.service")]
    problems = check(units, prepare, paths)
    for p in problems:
        print("setup-boot-order: " + p)
    if problems:
        return 1
    print(f"setup-boot-order: no wait-for cycle through {PREPARE_UNIT}'s setup boot across "
          f"{len(units)} packaged units, {POLICY_UNIT} skips a boot without selinuxfs, "
          "and systemd-analyze verify reads every directive (its canary flagged in the same run)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
