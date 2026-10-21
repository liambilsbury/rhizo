#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.join(REPO, "test", "system", "run"))
import system_tests  # noqa: E402

VM_READ = re.compile(r"""getprop_vm\s+\S+\s+sys\.boot_completed\b""")
LIVE_CALL = re.compile(r"""\bgetprop_live\b(?!\(\))""")
LIVE_KEPT = re.compile(r"""^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(getprop_live\s[^)]*\)\s*(?:\|\||;\s*[A-Za-z_][A-Za-z0-9_]*=\$\?)""")
LOCAL_READ = re.compile(r"""\blocal\s+[^;]*=\$\(getprop_(?:live|vm)\b""")
CMD = r"""(?:^|[;&|(]|\bdo\b|\bthen\b|\belse\b)\s*"""
LOOP_OPEN = re.compile(CMD + r"""(while|until|for|select)\b""")
LOOP_CLOSE = re.compile(CMD + r"""(done)\b""")

HARNESS = r'''
source "$1" >/dev/null 2>&1
log() { :; }
_ssh_vm_out() { case "$NSENTER" in denied) return 126 ;; *) printf '%s' "$NSENTER"; return 0 ;; esac; }
ssh_vm() { case "$*" in *"/proc/4242"*) [[ "$ALIVE" == yes ]] ;; *) echo 1 ;; esac; }
boot_completed_marker() { echo 1; }
probe_cmd() { case "$PROBE" in down) return 98 ;; *) printf '%s\r\n' "$PROBE"; return 0 ;; esac; }
v=$(getprop_live 4242 sys.boot_completed); rc=$?
printf 'V=[%s] RC=%s\n' "$v" "$rc"
'''

CASES = (
    ("denied", "yes", "1", "1", True, "nsenter denied under enforcement, rhizo-probed reads 1"),
    ("denied", "yes", "down", "", False, "nsenter denied and rhizo-probed unreachable: not a reading"),
    ("denied", "no", "1", "", False, "the init is gone and rhizo-probed answers for another sandbox"),
    ("1", "yes", "down", "1", True, "nsenter reads 1 without asking rhizo-probed"),
    ("", "yes", "1", "1", True, "nsenter exits 0 printing nothing (a denied read), rhizo-probed reads 1"),
    ("", "yes", "", "", False, "both channels exit 0 printing nothing: not a reading"),
    ("", "yes", "down", "", False, "nsenter prints nothing and rhizo-probed is unreachable"),
)


def live_problems(common):
    """return the boot completed read problems"""
    problems = []
    for nsenter, alive, probe, want_v, want_ok, what in CASES:
        env = dict(os.environ, NSENTER=nsenter, ALIVE=alive, PROBE=probe)
        r = subprocess.run(["bash", "-c", HARNESS, "x", common], capture_output=True, text=True,
                           timeout=60, env=env)
        m = re.search(r"V=\[(.*)\] RC=(\d+)", r.stdout)
        if not m:
            problems.append("getprop_live did not run (%s): %s" % (what, (r.stdout + r.stderr).strip()[-200:]))
            continue
        v, rc = m.group(1), int(m.group(2))
        if (rc == 0) != want_ok or (want_ok and v != want_v):
            problems.append("getprop_live read %r status %d where %s wants %r status %s"
                            % (v, rc, what, want_v, "0" if want_ok else "non-zero"))
    return problems


def test_problems(path, text):
    """return the problems found in a shell script"""
    problems = []
    loops = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        read = VM_READ.search(line)
        waiting = any(k in ("while", "until") for k in loops)
        events = sorted([(m.start(1), m.group(1)) for m in LOOP_OPEN.finditer(line)]
                        + [(m.start(1), m.group(1)) for m in LOOP_CLOSE.finditer(line)])
        for pos, kw in events:
            if kw == "done":
                if loops:
                    loops.pop()
            else:
                loops.append(kw)
                if read and pos < read.start() and kw in ("while", "until"):
                    waiting = True
        if read and not waiting:
            problems.append("%s:%d: sys.boot_completed read through getprop_vm outside a wait; "
                            "use getprop_live and keep its status" % (path, n))
        if LOCAL_READ.search(line):
            problems.append("%s:%d: local var=$(getprop_...) returns local's status, not the read's" % (path, n))
        elif LIVE_CALL.search(line) and not LIVE_KEPT.search(line):
            problems.append("%s:%d: getprop_live read with its status dropped" % (path, n))
    return problems


def scan(root):
    """return the problems in every system test under the root"""
    problems = []
    for p in system_tests.system_test_paths(os.path.join(root, "test", "system")):
        with open(p, errors="replace") as f:
            problems += test_problems(os.path.relpath(p, root), f.read())
    return problems


GOOD = r'''
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
bc=$(getprop_live "$INIT" sys.boot_completed); bc_rc=$?
    x=$(getprop_live "$INIT" sys.boot_completed) || x="<unreadable rc=$?>"
getprop_live() {  # a definition, not a call
# bc=$(getprop_vm "$INIT" sys.boot_completed)
while :; do
  [[ -n "$INIT" ]] && bc2=$(getprop_vm "$INIT" sys.boot_completed)
  [[ "$bc2" == "1" ]] && break
done
f() {
  local bc
  until [[ "$bc" == 1 ]]; do
    for i in 1 2; do
      bc=$(getprop_vm "$INIT" sys.boot_completed)
    done
  done
}
while :; do bc=$(getprop_vm "$INIT" sys.boot_completed); [[ "$bc" == 1 ]] && break; done
'''

BAD = (
    'boot_end=$(getprop_vm "$INIT" sys.boot_completed)\n',
    'boot_end=$(getprop_vm "$INIT" sys.boot_completed | tr -d \'\\r\')\n',
    'else\n  bc=$(getprop_vm "$INIT" sys.boot_completed)\nfi\n',
    'f() {\n  local raw\n  raw=$(getprop_vm "$INIT" sys.boot_completed)\n}\n',
    'while :; do sleep 1; done\nbc=$(getprop_vm "$INIT" sys.boot_completed)\n',
    'for i in 1 2; do\n  bc=$(getprop_vm "$INIT" sys.boot_completed)\ndone\n',
    '[[ "$(getprop_vm "$INIT" sys.boot_completed)" == 1 ]] || fail x\n',
    '    bc=$(st_zero "$(getprop_vm "$INIT" sys.boot_completed)")\n',
    'f() {\n  local v=$(getprop_live "$INIT" sys.boot_completed) || v=x\n}\n',
    '[[ "$(getprop_live "$INIT" sys.boot_completed)" == 1 ]] || fail x\n',
    'boot_end=$(getprop_live "$INIT" sys.boot_completed)\n',
    'boot_end=$(getprop_live "$INIT" sys.boot_completed) | tr -d x\n',
)

BROKEN_LIVE = (
    ("falls back to the dmesg marker",
     'getprop_live() { local v; v=$(_ssh_vm_out 8 x); [[ -z "$v" ]] && v=$(boot_completed_marker); printf "%s" "$v"; }\n'),
    ("drops rhizo-probed's status",
     'getprop_live() { _ssh_vm_out 8 x && return 0; probe_cmd 30 x | tr -d "\\r"; return 0; }\n'),
    ("never asks rhizo-probed",
     'getprop_live() { _ssh_vm_out 8 x; }\n'),
    ("asks rhizo-probed for a gone init",
     'getprop_live() { local v; v=$(_ssh_vm_out 8 x) && { printf "%s" "$v"; return 0; }; '
     'v=$(probe_cmd 30 x); local rc=$?; printf "%s" "$v" | tr -d "\\r"; return $rc; }\n'),
)


def selftest():
    """check the good reads and each planted-defect read"""
    failed = False
    got = test_problems("x.sh", GOOD)
    if got:
        print("SELFTEST FAILED: correct reads refused: %s" % got, file=sys.stderr)
        failed = True
    for b in BAD:
        if not test_problems("x.sh", b):
            print("SELFTEST FAILED: a read that loses its status passed: %r" % b, file=sys.stderr)
            failed = True
    if live_problems(os.path.join(REPO, "test", "vm", "common.sh")):
        print("SELFTEST FAILED: the tree's getprop_live fails its own cases", file=sys.stderr)
        failed = True
    with tempfile.TemporaryDirectory() as tmp:
        lib = os.path.join(tmp, "common.sh")
        for what, body in BROKEN_LIVE:
            with open(lib, "w") as f:
                f.write(body)
            if not live_problems(lib):
                print("SELFTEST FAILED: a getprop_live that %s passed" % what, file=sys.stderr)
                failed = True
    if failed:
        return 1
    print("selftest ok: passes the correct reads, refuses %d that lose a status, and catches %d broken "
          "getprop_live bodies" % (len(BAD), len(BROKEN_LIVE)))
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    problems = live_problems(os.path.join(REPO, "test", "vm", "common.sh")) + scan(REPO)
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        print("check-boot-completed-read: a system test reads sys.boot_completed with getprop_live and checks its status")
        return 1
    print("check-boot-completed-read: getprop_live reads the property itself with a status, and every "
          "getprop_vm sys.boot_completed read in a system test sits inside a wait")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
