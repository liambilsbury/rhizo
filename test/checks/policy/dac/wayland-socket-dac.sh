#!/bin/bash
# test the host wayland socket DAC lookup
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
LAUNCHER_DIR="$REPO/src/androidd"

# print a check message
say()  { printf 'check-wayland-socket-dac: %s\n' "$1"; }
# print a failure message to stderr
fail() { printf 'check-wayland-socket-dac: FAIL: %s\n' "$1" >&2; }

STATIC_PY='
import ast, os, sys
vm = sys.argv[1]
errs = []

def parse(name):
    path = os.path.join(vm, name)
    try:
        with open(path) as f:
            return ast.parse(f.read(), path)
    except (OSError, SyntaxError) as e:
        errs.append("%s does not parse: %s" % (name, e))
        return None

def top_def(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    return None

def dotted(f):
    if isinstance(f, ast.Name):
        return f.id
    if isinstance(f, ast.Attribute):
        base = dotted(f.value)
        return base and base + "." + f.attr
    return None

def calls(node):
    return [(dotted(c.func), [a.id if isinstance(a, ast.Name) else None for a in c.args])
            for c in ast.walk(node) if isinstance(c, ast.Call)]

mounts = parse("sandbox/rootfs.py")
env = parse("sandbox/core.py")
if mounts:
    r = top_def(mounts, "resolve_host_wayland_socket")
    iss = [n for n in (r.body if r else []) if isinstance(n, ast.FunctionDef) and n.name == "is_socket"]
    if not iss:
        errs.append("rootfs.resolve_host_wayland_socket() no longer defines is_socket()")
    else:
        cs = calls(iss[0])
        if ("core.stat_as_owner", ["path"]) not in [(n, a[:1]) for n, a in cs]:
            errs.append("resolve_host_wayland_socket() is_socket() no longer calls core.stat_as_owner(path)")
        bare = sorted({n for n, _ in cs if n in ("os.stat", "os.lstat")})
        if bare:
            errs.append("resolve_host_wayland_socket() is_socket() calls %s directly" % ", ".join(bare))
    b = top_def(mounts, "_bind_sockets_and_shadows")
    if b is None:
        errs.append("rootfs._bind_sockets_and_shadows() is gone")
    else:
        cs = calls(b)
        if ("core.bind_as_owner", ["host_wayland_socket", "dst"]) not in [(n, a[:2]) for n, a in cs]:
            errs.append("the wayland socket bind no longer calls core.bind_as_owner(host_wayland_socket, dst)")
        bare = sorted({n for n, a in cs if a[:1] == ["host_wayland_socket"]
                       and n in ("mount", "core.mount", "libc.mount", "bind_private", "core.bind_private")})
        if bare:
            errs.append("_bind_sockets_and_shadows() binds host_wayland_socket with a bare %s()" % ", ".join(bare))
if env:
    for fn in ("set_fsuid", "stat_as_owner", "bind_as_owner", "restore_dumpable"):
        if top_def(env, fn) is None:
            errs.append("core.%s() is missing" % fn)
    for fn in ("stat_as_owner", "bind_as_owner"):
        d = top_def(env, fn)
        if d and "restore_dumpable" not in [n for n, _ in calls(d)]:
            errs.append("core.%s() no longer calls restore_dumpable()" % fn)
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
'

# run the static parser and report findings
check_tree() {
  local dir="${1:-$LAUNCHER_DIR}" out rc line
  out=$(python3 -c "$STATIC_PY" "$dir" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    [[ -n "$out" ]] || out="the static parser exited $rc and printed nothing"
    while IFS= read -r line; do fail "$line"; done <<<"$out"
    return 1
  fi
  say "resolve_host_wayland_socket() still reaches a DAC-protected socket through core's fsuid mechanism"
  return 0
}

FIXTURE_UID=54321

MUTATE_PY='
import ast, sys
src, dst, which = sys.argv[1:4]
M = {
    "bind-owner-from-dst": ("bind_as_owner", "_dirname_owner(src)", "_dirname_owner(dst)"),
    "stat-no-fsuid-restore": ("stat_as_owner", "finally:\n        set_fsuid(prev, log)", "finally:\n        pass"),
    "stat-no-dumpable-restore": ("stat_as_owner", "        restore_dumpable(dumpable, log)\n", ""),
    "bind-no-dumpable-restore": ("bind_as_owner", "        restore_dumpable(dumpable, log)\n", ""),
    "is-socket-call-commented": ("resolve_host_wayland_socket", "st = core.stat_as_owner(path)\n",
                                 "# st = core.stat_as_owner(path)\n        st = os.stat(path)\n"),
    "bind-call-commented": ("_bind_sockets_and_shadows", "if core.bind_as_owner(host_wayland_socket, dst):\n",
                            "# if core.bind_as_owner(host_wayland_socket, dst):\n        if mount(host_wayland_socket, dst, None, MS_BIND):\n"),
}
fn, old, new = M[which]
with open(src) as f:
    text = f.read()
node = next((n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef) and n.name == fn), None)
if node is None:
    sys.exit("mutation %s: no def %s() in %s" % (which, fn, src))
lines = text.splitlines(keepends=True)
start = sum(len(l) for l in lines[:node.lineno - 1])
end = sum(len(l) for l in lines[:node.end_lineno])
seg = text[start:end]
if seg.count(old) != 1:
    sys.exit("mutation %s: anchor %r occurs %d times in %s()" % (which, old, seg.count(old), fn))
text = text[:start] + seg.replace(old, new) + text[end:]
ast.parse(text)
with open(dst, "w") as f:
    f.write(text)
'

LISTENER_PY='
import os, socket, sys
path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
os.chmod(path, 0o666)
s.listen(4)
s.settimeout(120)
print("listening pid=%d" % os.getpid(), flush=True)
try:
    while True:
        c, _ = s.accept()
        c.sendall(b"rhizo-dac-listener\n")
        c.close()
except socket.timeout:
    pass
'

USERNS_PY='
import ctypes, os, sys
CLONE_NEWUSER, CLONE_NEWNS = 0x10000000, 0x00020000
libc = ctypes.CDLL(None, use_errno=True)
uid, cmd = int(sys.argv[1]), sys.argv[2:]
go_r, go_w = os.pipe()
up_r, up_w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(go_w)
    os.close(up_r)
    if libc.unshare(CLONE_NEWUSER | CLONE_NEWNS) != 0:
        sys.stderr.write("unshare(CLONE_NEWUSER|CLONE_NEWNS): %s\n" % os.strerror(ctypes.get_errno()))
        os._exit(111)
    os.write(up_w, b"u")
    if os.read(go_r, 1) != b"g":
        os._exit(112)
    os.execvp(cmd[0], cmd)
os.close(go_r)
os.close(up_w)
if os.read(up_r, 1) == b"u":
    try:
        for kind in ("uid_map", "gid_map"):
            with open("/proc/%d/%s" % (pid, kind), "w") as f:
                f.write("0 0 1\n%d %d 1\n" % (uid, uid))
        os.write(go_w, b"g")
    except OSError as e:
        sys.stderr.write("writing the namespace id maps: %s\n" % e)
os.close(go_w)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
'

NS_SH='
mount --make-rprivate / || exit 113
if [ -e /dev/kmsg ]; then mount --bind /dev/null /dev/kmsg || exit 114; fi
exec setpriv --bounding-set -dac_override,-dac_read_search python3 -B "$@"
'

PROBE_PY='
import os, socket, stat, sys
sys.dont_write_bytecode = True
vm, src, dst = sys.argv[1:4]

def verdict(v, rc):
    print("PROBE: " + v, flush=True)
    sys.exit(rc)

def status(key, field):
    for line in open("/proc/self/status"):
        if line.startswith(key):
            return line.split()[field]

def fsuid():
    return int(status("Uid:", 4))

import ctypes
_libc = ctypes.CDLL(None, use_errno=True)

def dumpable():
    return _libc.prctl(3, 0, 0, 0, 0)

sys.path.insert(0, vm)
from sandbox import core
if os.path.dirname(os.path.realpath(core.__file__)) != os.path.realpath(os.path.join(vm, "sandbox")):
    verdict("WRONG-MODULE imported %s, not %s/sandbox/core.py" % (core.__file__, vm), 1)

eff = int(status("CapEff:", 1), 16)
for bit, name in ((1, "DAC_OVERRIDE"), (2, "DAC_READ_SEARCH")):
    if eff >> bit & 1:
        verdict("FIXTURE-HAS-CAP_%s (CapEff=%x)" % (name, eff), 1)
for bit, name in ((7, "SETUID"), (21, "SYS_ADMIN")):
    if not eff >> bit & 1:
        verdict("FIXTURE-LACKS-CAP_%s (CapEff=%x)" % (name, eff), 1)
try:
    os.stat(src)
    verdict("FIXTURE-NOT-DAC-PROTECTED (a plain os.stat reached %s)" % src, 1)
except PermissionError:
    pass
dump0 = dumpable()
if dump0 != 1:
    verdict("FIXTURE-NOT-DUMPABLE (dumpable %d before any switch)" % dump0, 1)
suid_dumpable = open("/proc/sys/fs/suid_dumpable").read().strip()
if suid_dumpable == "1":
    verdict("FIXTURE-SUID-DUMPABLE-IS-1 (an fsuid switch keeps dumpable 1 on this host, so a missing restore reads clean)", 1)

def log(m):
    sys.stderr.write("core: %s\n" % m)

before = fsuid()
st = core.stat_as_owner(src, log=log)
if fsuid() != before:
    verdict("STAT-FSUID-NOT-RESTORED (fsuid %d after stat_as_owner, %d before)" % (fsuid(), before), 1)
if st is None:
    verdict("STAT-AS-OWNER-FAILED (returned None for a live socket)", 1)
if not stat.S_ISSOCK(st.st_mode):
    verdict("STAT-NOT-A-SOCKET (mode %o)" % st.st_mode, 1)
if dumpable() != dump0:
    verdict("STAT-LEFT-UNDUMPABLE (dumpable %d after stat_as_owner, %d before)" % (dumpable(), dump0), 1)

open(dst, "w").close()
ok = core.bind_as_owner(src, dst, log=log)
if fsuid() != before:
    verdict("BIND-FSUID-NOT-RESTORED (fsuid %d after bind_as_owner, %d before)" % (fsuid(), before), 1)
if not ok:
    verdict("BIND-FAILED (bind_as_owner returned %r)" % (ok,), 1)
if dumpable() != dump0:
    verdict("BIND-LEFT-UNDUMPABLE (dumpable %d after bind_as_owner, %d before)" % (dumpable(), dump0), 1)
if not stat.S_ISSOCK(os.stat(dst).st_mode):
    verdict("BIND-NOT-A-SOCKET (bind_as_owner reported success, %s is not a socket)" % dst, 1)
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(10)
try:
    c.connect(dst)
    got = c.recv(64)
except OSError as e:
    verdict("BIND-CONNECT-FAILED (%s)" % e, 1)
if got != b"rhizo-dac-listener\n":
    verdict("BIND-WRONG-SOCKET (read %r)" % got, 1)
verdict("ARRIVED", 0)
'

# print the probe verdict from a fixture run
probe_env() {
  local dir="$1" tmp rundir lpid listener_pid="" out verdict waited
  tmp=$(mktemp -d) || { echo "NO-VERDICT mktemp -d failed"; return; }
  chmod 755 "$tmp"
  rundir="$tmp/rundir"
  printf '%s' "$PROBE_PY" > "$tmp/probe.py"
  mkdir -m 755 "$tmp/mod" "$tmp/mod/sandbox" && cp "$dir/sandbox/core.py" "$tmp/mod/sandbox/core.py" && chmod 644 "$tmp/mod/sandbox/core.py" \
    || { echo "NO-VERDICT could not copy $dir/sandbox/core.py into the fixture"; rm -rf "$tmp"; return; }
  if ! sudo -n install -d -o "$FIXTURE_UID" -g "$FIXTURE_UID" -m 0700 "$rundir" 2>"$tmp/setup.err" \
     || ! sudo -n install -d -o 0 -g 0 -m 0755 "$tmp/bind" 2>>"$tmp/setup.err"; then
    echo "NO-VERDICT fixture directories could not be made: $(tr '\n' ' ' <"$tmp/setup.err")"
    sudo -n rm -rf "$tmp" >/dev/null 2>&1
    return
  fi

  # shellcheck disable=SC2024
  sudo -n setpriv --reuid="$FIXTURE_UID" --regid="$FIXTURE_UID" --clear-groups \
    python3 -c "$LISTENER_PY" "$rundir/wayland-0" >"$tmp/listener.log" 2>&1 &
  lpid=$!
  for (( waited = 0; waited < 100; waited++ )); do
    listener_pid=$(sed -n 's/^listening pid=\([0-9]*\)$/\1/p' "$tmp/listener.log")
    [[ -n "$listener_pid" ]] && break
    [[ "$(ps -o stat= -p "$lpid" 2>/dev/null)" == [^Z]* ]] || break
    sleep 0.1
  done
  if [[ -z "$listener_pid" ]]; then
    echo "NO-VERDICT the fixture listener never came up (waited $waited x 0.1s, sudo pid $lpid state '$(ps -o stat= -p "$lpid" 2>/dev/null)'): $(tr '\n' ' ' <"$tmp/listener.log")"
    wait "$lpid" 2>/dev/null
    sudo -n rm -rf "$tmp" >/dev/null 2>&1
    return
  fi

  # shellcheck disable=SC2024
  sudo -n python3 -c "$USERNS_PY" "$FIXTURE_UID" sh -c "$NS_SH" probe \
    "$tmp/probe.py" "$tmp/mod" "$rundir/wayland-0" "$tmp/bind/wayland-0" >"$tmp/probe.out" 2>&1
  verdict=$(sed -n 's/^PROBE: //p' "$tmp/probe.out" | tail -1)

  sudo -n kill "$listener_pid" >/dev/null 2>&1
  wait "$lpid" 2>/dev/null
  if [[ -n "$verdict" ]]; then
    echo "$verdict"
  else
    out=$(grep -v 'unable to resolve host' "$tmp/probe.out" | tail -20 | tr '\n' '|')
    echo "NO-VERDICT the probe crashed or printed nothing; its output: ${out:-<empty>}"
  fi
  sudo -n rm -rf "$tmp" >/dev/null 2>&1
}

# create a scratch tree with a mutation
scratch_tree() {
  local which="$1" d target
  d=$(mktemp -d) || return 1
  mkdir -p "$d/sandbox" && cp "$LAUNCHER_DIR/sandbox/core.py" "$LAUNCHER_DIR/sandbox/rootfs.py" "$d/sandbox/" || { rm -rf "$d"; return 1; }
  case "$which" in
    none) ;;
    bind-owner-from-dst|stat-no-fsuid-restore|stat-no-dumpable-restore|bind-no-dumpable-restore) target=sandbox/core.py ;;
    *) target=sandbox/rootfs.py ;;
  esac
  if [[ "$which" != none ]] && ! python3 -c "$MUTATE_PY" "$LAUNCHER_DIR/$target" "$d/$target" "$which" >&2; then
    rm -rf "$d"
    return 1
  fi
  echo "$d"
}

# test the check with planted defects
selftest() {
  local rc=0 tool d out got which needle

  check_tree "$LAUNCHER_DIR" || rc=1
  for which in is-socket-call-commented bind-call-commented stat-no-dumpable-restore; do
    case "$which" in
      is-socket-call-commented) needle="no longer calls core.stat_as_owner(path)" ;;
      bind-call-commented) needle="no longer calls core.bind_as_owner(host_wayland_socket, dst)" ;;
      stat-no-dumpable-restore) needle="core.stat_as_owner() no longer calls restore_dumpable()" ;;
    esac
    d=$(scratch_tree "$which") && [[ -n "$d" ]] \
      || { fail "selftest: could not plant $which in a scratch tree"; rc=1; continue; }
    out=$(check_tree "$d" 2>&1)
    got=$?
    rm -rf "$d"
    if (( got == 0 )) || ! grep -qF "$needle" <<<"$out"; then
      fail "selftest: the static check did not flag $which by name (rc=$got): $(tr '\n' '|' <<<"$out")"
      rc=1
    else
      say "selftest: static check flags $which"
    fi
  done

  if [[ -z "${CHECK_DAC_INNER:-}" ]]; then
    local shim
    shim=$(mktemp -d) || { fail "selftest: mktemp -d failed"; return 1; }
    printf '#!/bin/sh\nexit 1\n' > "$shim/sudo"
    chmod +x "$shim/sudo"
    out=$(CHECK_DAC_INNER=1 PATH="$shim:$PATH" "$HERE/policy/dac/wayland-socket-dac.sh" --selftest 2>&1)
    got=$?
    rm -rf "$shim"
    if (( got == 0 )) || ! grep -qF "dynamic half NOT MEASURED (sudo -n cannot get root here)" <<<"$out"; then
      fail "selftest: a host where sudo -n cannot get root passed the selftest unmeasured (rc=$got): $(tr '\n' '|' <<<"$out")"
      rc=1
    else
      say "selftest: a host where sudo -n cannot get root fails the selftest, naming the unmeasured half"
    fi
  fi

  for tool in sudo setpriv python3; do
    command -v "$tool" >/dev/null 2>&1 \
      || { fail "selftest: dynamic half NOT MEASURED (no $tool here)"; return 1; }
  done
  sudo -n true 2>/dev/null \
    || { fail "selftest: dynamic half NOT MEASURED (sudo -n cannot get root here)"; return 1; }

  got=$(probe_env "$LAUNCHER_DIR")
  if [[ "$got" == ARRIVED ]]; then
    say "selftest: measured live -- the real stat_as_owner() and bind_as_owner() reach a 0700 uid-$FIXTURE_UID socket with dac_override and dac_read_search dropped, restore fsuid and the dumpable flag, and the bound path connects"
  else
    fail "selftest: the real core did not reach the fixture socket -- $got"
    rc=1
  fi

  for which in bind-owner-from-dst stat-no-fsuid-restore stat-no-dumpable-restore bind-no-dumpable-restore; do
    case "$which" in
      bind-owner-from-dst) needle="BIND-FAILED" ;;
      stat-no-fsuid-restore) needle="STAT-FSUID-NOT-RESTORED" ;;
      stat-no-dumpable-restore) needle="STAT-LEFT-UNDUMPABLE" ;;
      bind-no-dumpable-restore) needle="BIND-LEFT-UNDUMPABLE" ;;
    esac
    d=$(scratch_tree "$which") && [[ -n "$d" ]] \
      || { fail "selftest: could not plant $which in a scratch sandbox/core.py"; rc=1; continue; }
    got=$(probe_env "$d")
    rm -rf "$d"
    if [[ "$got" != "$needle"* ]]; then
      fail "selftest: the probe did not catch $which as $needle -- got: $got"
      rc=1
    else
      say "selftest: probe catches $which ($got)"
    fi
  done
  return $rc
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") check_tree; exit $? ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
