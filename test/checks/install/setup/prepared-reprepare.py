#!/usr/bin/env python3
import ast, contextlib, io, os, subprocess, sys, tempfile
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
LAUNCHER = os.path.join(REPO, "src", "androidd")
CLI = os.path.join(REPO, "src", "install", "cli", "rhizo.sh")
UNIT = os.path.join(REPO, "src", "services", "units", "boot", "prepare.service")
PREPARE = os.path.join(REPO, "src", "install", "prepare", "prepare.sh")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-prepared-reprepare")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import core

bad = []
request_fn = getattr(core, "request_reprepare", None)
clear_fn = getattr(core, "clear_prepared_refusal", None)
reasons = getattr(core, "REPREPARE_REASONS", None)

unit = open(UNIT).read()
want_condition = "ConditionPathExists=|%s" % getattr(core, "PREPARE_REQUEST", "<no PREPARE_REQUEST>")
if want_condition not in unit.splitlines():
    bad.append(("rhizo-prepare.service runs on a pending request", want_condition))
if 'PREPARE_REQUEST="${RHIZO_PREPARE_REQUEST:-$STATE_DIR/prepare-request}"' not in open(PREPARE).read() \
        or getattr(core, "PREPARE_REQUEST", None) != "/var/lib/rhizo/prepare-request":
    bad.append(("the launcher writes the request prepare reads", "/var/lib/rhizo/prepare-request",
                getattr(core, "PREPARE_REQUEST", None)))

tree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/core.py")).read())
fns = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
returned = set()
for name in ("validate_prepared", "_check_input", "_check_output"):
    for r in (n for n in ast.walk(fns[name]) if isinstance(n, ast.Return) and n.value is not None):
        value = r.value.elts[1] if isinstance(r.value, ast.Tuple) else r.value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            returned.add(value.value)
        elif isinstance(value, ast.JoinedStr) and isinstance(value.values[0], ast.Constant):
            returned.add(value.values[0].value.split(":", 1)[0])
if reasons is None or not returned or not returned <= set(reasons):
    bad.append(("every refusal validate_prepared returns is repairable", sorted(returned), reasons))

logs = []
core.kmsg = logs.append
if request_fn is None or clear_fn is None:
    bad.append(("core defines request_reprepare and clear_prepared_refusal", request_fn, clear_fn))
else:
    with tempfile.TemporaryDirectory() as tmp:
        root, request = os.path.join(tmp, "prepared"), os.path.join(tmp, "prepare-request")
        record = os.path.join(root, "refusal")
        os.makedirs(os.path.join(root, "aaaaaaaaaaaa"))
        os.symlink("aaaaaaaaaaaa", os.path.join(root, "current"))
        enabled = [True]

        def ask(reason):
            """request a re-prepare against the fixture paths"""
            return request_fn(reason, prepared_root=root, request=request, unit_enabled=lambda: enabled[0])

        def fields(path):
            """return a key=value file's fields, or None when absent"""
            try:
                return dict(l.split("=", 1) for l in open(path).read().splitlines() if "=" in l)
            except FileNotFoundError:
                return None

        tampered = "output-tampered:vendor/bin/hw/rhizo-keymint-service"
        got = ask(tampered)
        if got != "requested" or (fields(request) or {}).get("release") != "current" \
                or fields(request).get("wipe_data") != "0" or fields(request).get("origin") != "prepared-refused" \
                or fields(record) != \
                {"key": "aaaaaaaaaaaa", "reason": tampered, "outcome": "requested"}:
            bad.append(("a first refusal", "requested, release=current wipe_data=0, recorded", got, fields(request),
                        fields(record)))
        if not any(l == "RHIZO_MARKER prepared_reprepare=requested reason=" + tampered for l in logs):
            bad.append(("a first refusal's marker", logs))
        before = open(request).read()
        got = ask(tampered)
        if got != "pending" or open(request).read() != before:
            bad.append(("a refusal while a request waits", "pending, request unchanged", got))
        os.unlink(request)
        got = ask("output-tampered:vendor/lib64/libfoo.so")
        if got != "repeated" or os.path.exists(request):
            bad.append(("the rebuilt tree refused again for the same reason", "repeated, no request", got,
                        fields(request)))
        os.unlink(os.path.join(root, "current"))
        os.symlink("bbbbbbbbbbbb", os.path.join(root, "current"))
        got = ask(tampered)
        if got != "requested":
            bad.append(("a tree of new inputs refused", "requested", got))
        os.unlink(request)
        clear_fn(prepared_root=root)
        if os.path.exists(record):
            bad.append(("an accepted tree clears the record", record))
        os.unlink(os.path.join(root, "current"))
        os.symlink("aaaaaaaaaaaa", os.path.join(root, "current"))
        got = ask(tampered)
        if got != "requested":
            bad.append(("a refusal after an accepted tree", "requested", got))
        os.unlink(request)
        with open(record, "w") as f:
            f.write("key=aaaaaaaaaaaa\nreason=%s\noutcome=rebuild-failed\nfailed=verify-failed\n" % tampered)
        got = ask(tampered)
        if got != "rebuild-failed" or os.path.exists(request) \
                or (fields(record) or {}).get("failed") != "verify-failed":
            bad.append(("a tree whose rebuild failed at boot", "rebuild-failed, no request, failed kept", got,
                        fields(record)))
        clear_fn(prepared_root=root)

        def query_fails():
            """raise as a systemctl that cannot run does"""
            raise FileNotFoundError(2, "No such file or directory", "systemctl")

        got = request_fn(tampered, prepared_root=root, request=request, unit_enabled=query_fails)
        if got != "unit-query-failed" or os.path.exists(request) \
                or "No such file or directory" not in (fields(record) or {}).get("error", ""):
            bad.append(("a failed systemctl query", "unit-query-failed, no request, the error recorded", got,
                        fields(record)))
        clear_fn(prepared_root=root)
        enabled[0] = False
        got = ask(tampered)
        if got != "no-prepare-unit" or os.path.exists(request) or (fields(record) or {}).get("outcome") != got:
            bad.append(("no enabled rhizo-prepare.service", "no request, the refusal recorded", got, fields(record)))
        clear_fn(prepared_root=root)
        enabled[0] = True
        got = ask("bind-failed")
        if got != "not-repairable" or os.path.exists(request) or os.path.exists(record):
            bad.append(("a refusal a rebuild cannot repair", "nothing written", got))
        clear_fn(prepared_root=root)

        def status_line(outcome, pending, extra=""):
            """print the CLI's refusal line for a fixture record"""
            state = os.path.join(tmp, "state-" + outcome + str(pending).replace("\n", "").replace("=", ""))
            os.makedirs(os.path.join(state, "prepared"))
            with open(os.path.join(state, "prepared", "refusal"), "w") as f:
                f.write("key=aaaaaaaaaaaa\nreason=%s\noutcome=%s\n%s" % (tampered, outcome, extra))
            if pending:
                with open(os.path.join(state, "prepare-request"), "w") as f:
                    f.write("release=current\nvariant=\nwipe_data=0\n" + (pending if isinstance(pending, str) else ""))
            env = dict(os.environ, RHIZO_STATE_DIR=state, RHIZO_CLI_SOURCE_ONLY="1")
            r = subprocess.run(["bash", "-c", 'source "$1" && prepared_refusal_status', "x", CLI], env=env,
                               capture_output=True, text=True, timeout=60)
            return r.returncode, r.stdout.strip()

        for outcome, pending, extra, want in (
                ("rebuild-failed", False, "failed=verify-failed\n",
                 "refused (%s) at the last start; its rebuild at boot failed (verify-failed): run "
                 "'sudo rhizo prepare'" % tampered),
                ("unit-query-failed", False, "error=FileNotFoundError(2)\n",
                 "refused (%s) at the last start; cannot read whether rhizo-prepare.service is "
                 "enabled (FileNotFoundError(2)): run 'sudo rhizo prepare'" % tampered),
                ("requested", True, "",
                 "refused (%s) at the last start; a re-prepare is pending for the next boot" % tampered),
                ("requested", False, "", "refused (%s) at the last start; "
                                         "the next start checks the rebuilt tree" % tampered),
                ("repeated", False, "", "refused (%s) again after its rebuild at the last start: run "
                                        "'sudo rhizo prepare'" % tampered),
                ("no-prepare-unit", False, "", "refused (%s) at the last start; rhizo-prepare.service is not "
                                               "enabled: run 'sudo rhizo prepare'" % tampered)):
            got = status_line(outcome, pending, extra)
            if got != (0, want):
                bad.append(("rhizo status", outcome, "pending" if pending else "no request", want, got))
        r = subprocess.run(["bash", "-c", 'source "$1" && prepared_refusal_status', "x", CLI],
                           env=dict(os.environ, RHIZO_STATE_DIR=os.path.join(tmp, "empty"), RHIZO_CLI_SOURCE_ONLY="1"),
                           capture_output=True, text=True, timeout=60)
        if (r.returncode, r.stdout) != (0, ""):
            bad.append(("rhizo status with no refusal", "nothing", r.returncode, r.stdout, r.stderr[-200:]))
        if 'prepared_refusal_status' not in open(CLI).read().split("cmd_status()", 1)[-1]:
            bad.append(("cmd_status prints the refusal line", "a prepared_refusal_status call"))

        def prepare_run(origin, args):
            """run prepare.sh on a fixture request"""
            state = os.path.join(tmp, "prep-%s-%d" % (origin or "user", len(args)))
            prepared = os.path.join(state, "prepared")
            os.makedirs(prepared)
            req = os.path.join(state, "prepare-request")
            with open(req, "w") as f:
                f.write("release=current\nvariant=\nwipe_data=0\n" + ("origin=%s\n" % origin if origin else ""))
            with open(os.path.join(prepared, "refusal"), "w") as f:
                f.write("key=aaaaaaaaaaaa\nreason=%s\noutcome=requested\n" % tampered)
            env = dict(os.environ, RHIZO_STATE_DIR=state, RHIZO_PREPARE_REQUEST=req, RHIZO_PREPARED_ROOT=prepared)
            r = subprocess.run(["bash", PREPARE, "--release", "current"] + args, env=env, capture_output=True,
                               text=True, timeout=60)
            return r.returncode, fields(req), fields(os.path.join(prepared, "refusal"))

        rc, req_left, rec = prepare_run("prepared-refused", ["--sandbox-id", "1"])
        if rc != 1 or req_left is not None or rec != {"key": "aaaaaaaaaaaa", "reason": tampered,
                                                      "outcome": "rebuild-failed", "failed": "instance-setup-boot"}:
            bad.append(("a launcher-made rebuild refused at boot", "request dropped, rebuild-failed recorded", rc,
                        req_left, rec))
        rc, req_left, rec = prepare_run("", ["--sandbox-id", "1"])
        if rc != 1 or req_left is None or (rec or {}).get("outcome") != "requested":
            bad.append(("a user's deferred prepare refused at boot", "request and record kept", rc, req_left, rec))

        lifted = subprocess.run(["sed", "-n", "".join("/^%s() {/,/^}/p;" % fn for fn in (
            "refuse", "failstop", "write_rebuild_record", "drop_failed_auto_request", "on_prepare_exit",
            "arm_auto_request")), PREPARE], capture_output=True, text=True).stdout

        def ended(name, request, end, runs=1, sealed=False):
            """arm and end a request and return its traces"""
            state = os.path.join(tmp, "trap-" + name)
            os.makedirs(os.path.join(state, "prepared"))
            req = os.path.join(state, "prepare-request")
            open(req, "w").write(request)
            if sealed:
                os.chmod(req, 0o444)
            script = ("set -u\nlog() { :; }\nAUTO_REQUEST=0\nPREPARE_REQUEST=%s\n"
                      "PREPARED_ROOT=%s/prepared\n%s\narm_auto_request\n%s\n" % (req, state, lifted, end))
            out = ""
            for _ in range(runs):
                out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60).stdout
            return out, fields(req), fields(os.path.join(state, "prepared", "refusal")) or {}

        launcher_request = "release=current\norigin=prepared-refused\n"
        for end, want in (("exit 5", "exit-5"), ("kill -TERM $$", "exit-143"), ("exit 0", "exit-0")):
            _, req_left, rec = ended(want, launcher_request, end)
            if req_left is not None or rec.get("outcome") != "rebuild-failed" or rec.get("failed") != want:
                bad.append(("a rebuild ended by " + end, "request dropped, failed=" + want, req_left, rec))
        out, req_left, rec = ended("unmarkable", launcher_request, "exit 0", sealed=True)
        if "RHIZO_PREPARE_FAILED reason=attempt-unrecorded" not in out or req_left is not None \
                or (rec.get("outcome"), rec.get("failed")) != ("rebuild-failed", "attempt-unrecorded"):
            bad.append(("a request the run cannot mark attempted", "failed=attempt-unrecorded", out, req_left, rec))
        _, req_left, _ = ended("killed", launcher_request, "kill -KILL $$")
        if "attempt" not in (req_left or {}):
            bad.append(("a launcher request's run", "an attempt line written before the rebuild", req_left))
        out, req_left, rec = ended("killed-then-boot", launcher_request, "kill -KILL $$", runs=2)
        if "RHIZO_PREPARE_REFUSED reason=rebuild-killed" not in out or req_left is not None \
                or (rec.get("outcome"), rec.get("failed")) != ("rebuild-failed", "rebuild-killed"):
            bad.append(("the boot after a killed rebuild", "refused unrun, failed=rebuild-killed", out, req_left, rec))
        prep = open(PREPARE).read()
        arm_site = prep.split("== prepared-refused ]]; then\n", 1)[-1].split("\nfi\n", 1)[0].strip()
        if arm_site != "arm_auto_request":
            bad.append(("prepare arms a launcher request", "arm_auto_request", arm_site))

        cli_lines = open(CLI).read().splitlines()
        for fn, words in (("prepared_refusal_status", 8), ("cmd_status", None)):
            at = cli_lines.index(fn + "() {")
            above = cli_lines[at - 1]
            if not above.startswith("# ") or cli_lines[at - 2].startswith("#") \
                    or (words is not None and len(above[2:].split()) > words):
                bad.append(("the comment above " + fn, "one line", words, cli_lines[at - 2:at]))

ltree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
ifs = [n for n in ast.walk(ltree) if isinstance(n, ast.If) and ast.unparse(n.test) == "_prepared_key"]
text = ast.unparse(ifs[0]) if len(ifs) == 1 else ""
if "core.clear_prepared_refusal()" not in ast.unparse(ast.Module(body=ifs[0].body, type_ignores=[])) if ifs \
        else True:
    bad.append(("an accepted tree clears the refusal record", "clear_prepared_refusal() under if _prepared_key"))
orelse = ast.unparse(ast.Module(body=ifs[0].orelse, type_ignores=[])) if ifs else ""
if "if not host_selinux_mode():" not in orelse or "core.request_reprepare(_prepared_reason)" not in orelse:
    bad.append(("a namespace-mode refusal requests a re-prepare", "request_reprepare under not host_selinux_mode()",
                orelse))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
