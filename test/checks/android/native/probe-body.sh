#!/bin/bash
# test probe_cmd with a multi-line body

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# serve a request line per connection
serve() {
  exec python3 - "$1" "$2" <<'EOF'
import os, socket, subprocess, sys
sock_path, ready = sys.argv[1], sys.argv[2]
MAX_CMD = 65536
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(8)
with open(ready, "w") as f:
    f.write("READY\n")
while True:
    c, _ = srv.accept()
    buf = b""
    while len(buf) < MAX_CMD - 1:
        chunk = c.recv(MAX_CMD - 1 - len(buf))
        if not chunk:
            break
        buf += chunk
        if b"\n" in chunk:
            break
    line = buf.split(b"\n", 1)[0]
    p = subprocess.run(["sh", "-c", line], input=b"CALLER\n", stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    c.sendall(p.stdout + b"\0RHIZO_PROBE_RC=%d\0" % p.returncode)
    c.close()
EOF
}

# start serve and print its pid
start() {
  mkfifo "$2"
  if [[ -n "${3:-}" ]]; then PATH="$3" serve "$1" "$2" >/dev/null & else serve "$1" "$2" >/dev/null & fi
  local pid=$! r=""
  read -r -t 20 r < "$2"
  [[ "$r" == READY ]] || { kill "$pid" 2>/dev/null; return 1; }
  echo "$pid"
}

# print a line per failed assertion
verdict() {
  local common="$1" t="$2" srv bad
  mkdir -p "$t/share" "$t/badbin"
  printf '#!/bin/sh\nexec python3 %s "$@"\n' "$TOOLS_DIR/../../src/services/probe-client/probe-client.py" > "$t/share/rhizo-probe-client"
  chmod +x "$t/share/rhizo-probe-client"
  printf '#!/bin/sh\necho "base64: refused" >&2\nexit 1\n' > "$t/badbin/base64"
  chmod +x "$t/badbin/base64"
  srv=$(start "$t/probe.sock" "$t/ready") || { echo "HARNESS: the fixture probe server never came up"; return; }
  bad=$(start "$t/bad.sock" "$t/bad-ready" "$t/badbin:$PATH") \
    || { kill "$srv" 2>/dev/null; echo "HARNESS: the fixture probe server without base64 never came up"; return; }
  (
    # shellcheck source=/dev/null
    source "$common"
    # shellcheck disable=SC2034
    VAR_DIR="$t" PROBE_SOCK="$t/probe.sock" TMPDIR="$t"
    export LC_ALL=C.UTF-8
    out=$(probe_cmd 10 $'echo L1\necho L2\n')
    [[ "$out" == *L1* && "$out" == *L2* ]] \
      || echo "a multi-line body ran without its later lines: got '${out//$'\n'/\\n}', want L1 and L2"
    exact=$'printf \'%s|\' "a b" \'$HOME\'\nprintf \'%s\' "tail$((1+1))"\n'
    out=$(probe_cmd 10 "$exact")
    [[ "$out" == 'a b|$HOME|tail2' ]] \
      || echo "a quoted multi-line body did not run as written: got '${out//$'\n'/\\n}', want 'a b|\$HOME|tail2'"
    out=$(probe_cmd 10 $'read -r x; echo "stdin=$x"\necho end\n')
    [[ "$out" == *stdin=CALLER* ]] \
      || echo "a multi-line body did not read the caller's stdin: got '${out//$'\n'/\\n}', want stdin=CALLER"
    out=$(probe_cmd 10 $'echo a\nexit 7\n'); rc=$?
    (( rc == 7 )) || echo "a multi-line body's exit status did not survive the wrapper: rc=$rc, want 7"
    big=$(printf 'echo %s\n' "$(head -c 48000 /dev/zero | tr '\0' x)")
    out=$(probe_cmd 10 "$big" 2>"$t/big.err"); rc=$?
    if (( rc != 96 )) || ! grep -q 'probe_cmd: body is' "$t/big.err"; then
      echo "a body over the size limit was not refused loudly: rc=$rc stderr='$(head -c 200 "$t/big.err")'"
    fi
    wide=$(printf 'echo %s\n' "$(printf '%30000s' '' | sed 's/ /é/g')")
    out=$(probe_cmd 10 "$wide" 2>"$t/wide.err"); rc=$?
    (( rc == 96 )) || echo "a non-ASCII body over the byte limit was not refused: rc=$rc, its size was counted in characters"
    ssh_vm() { :; }
    out=$(android_sh 1 "$big" 2>/dev/null); rc=$?
    (( rc == 96 )) || echo "android_sh did not pass probe_cmd's 96 through for a refused body: rc=$rc"
    # shellcheck disable=SC2034
    PROBE_SOCK="$t/bad.sock"
    out=$(probe_cmd 10 $'echo L1\necho L2\n'); rc=$?
    [[ "$rc" == 95 && "$out" == *RHIZO_PROBE_DECODE_FAILED* && "$out" != *L1* ]] \
      || echo "a multi-line body the sandbox could not decode did not fail by name: rc=$rc out='${out//$'\n'/\\n}', want rc 95 and RHIZO_PROBE_DECODE_FAILED"
    out=$(android_sh 1 $'echo L1\necho L2' 2>/dev/null); rc=$?
    (( rc == 95 )) || echo "android_sh did not pass probe_cmd's 95 through for an undecoded body: rc=$rc"
  )
  kill "$srv" "$bad" 2>/dev/null
}

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

# run verdict on a mutated common.sh
mutant() {
  if cmp -s "$vmcopy/common-$1.sh" "$TOOLS_DIR/../vm/common.sh"; then
    echo "SELFTEST FAILED: the $1 mutation did not change a copy of common.sh" >&2; exit 1
  fi
  rm -rf "${work:?}/$1"; mkdir "$work/$1"
  why=$(verdict "$vmcopy/common-$1.sh" "$work/$1")
  [[ "$why" == HARNESS:* ]] && { echo "SELFTEST FAILED: $why" >&2; exit 1; }
  grep -q "^$2" <<<"$why" || { echo "SELFTEST FAILED: the $1 mutation was not caught by '$2': '$why'" >&2; exit 1; }
}

if [[ "${1:-}" == "--selftest" ]]; then
  vmcopy="$work/test/vm"; mkdir -p "$vmcopy" "$work/src/androidd"
  cp "$TOOLS_DIR/../../src/androidd/host/parse-display-list.sh" "$work/src/androidd/"
  awk '
    /^probe_cmd\(\) \{/ { inf = 1 }
    inf && /if \[\[ "\$body" == \*\$.\\n.\* \]\]; then/ { skip = 1 }
    inf && skip { if (/^  fi$/) { skip = 0 } ; next }
    inf && /\(\( nbytes > / { skip2 = 1 }
    inf && skip2 { if (/^  fi$/) { skip2 = 0 } ; next }
    inf && /^}/ { inf = 0 }
    { print }
  ' "$TOOLS_DIR/../vm/common.sh" > "$vmcopy/common-raw.sh"
  mutant raw 'a multi-line body ran without its later lines'
  mutant raw 'a body over the size limit was not refused loudly'
  echo "selftest ok: a probe_cmd sending the body as is runs line 1 only and sends an oversized body unrefused"
  enc="\$(printf '%s' \"\$body\" | base64 -w0)"
  python3 - "$TOOLS_DIR/../vm/common.sh" "$vmcopy" "$enc" <<'EOF'
import sys
src, work, enc = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
line = 'body="s=\\$(echo %s | base64 -d) && [ -n \\"\\$s\\" ] || { echo RHIZO_PROBE_DECODE_FAILED; exit 95; }; sh -c \\"\\$s\\""' % enc
assert s.count(line) == 1, "probe_cmd's wrapper line not found"
muts = {
    "pipe": 'body="echo %s | base64 -d | sh"' % enc,
    "status": line[:-1] + '; true"',
    "unguarded": 'body="sh -c \\"\\$(echo %s | base64 -d)\\""' % enc,
}
for name, new in muts.items():
    open("%s/common-%s.sh" % (work, name), "w").write(s.replace(line, new))
for name, old, new in (("bytes", 'nbytes=$(LC_ALL=C; echo "${#body}")', 'nbytes=${#body}'),
                       ("passthrough", "if (( rc >= 95 && rc <= 98 )); then", "if (( rc == 97 || rc == 98 )); then")):
    assert s.count(old) == 1, old
    open("%s/common-%s.sh" % (work, name), "w").write(s.replace(old, new))
EOF
  mutant pipe "a multi-line body did not read the caller's stdin"
  mutant status "a multi-line body's exit status did not survive the wrapper"
  mutant unguarded 'a multi-line body the sandbox could not decode did not fail by name'
  mutant bytes 'a non-ASCII body over the byte limit was not refused'
  mutant passthrough "android_sh did not pass probe_cmd's 96 through"
  mutant passthrough "android_sh did not pass probe_cmd's 95 through"
  echo "selftest ok: a body piped into sh, a lost exit status, an unguarded decode, a character count and an android_sh swallowing 95/96 are each caught"
  mkdir "$work/fixed"
  why=$(verdict "$TOOLS_DIR/../vm/common.sh" "$work/fixed")
  [[ -z "$why" ]] || { echo "SELFTEST FAILED: the real probe_cmd was flagged: $why" >&2; exit 1; }
  echo "selftest ok: the real probe_cmd runs every line with the caller's stdin and its exit status, refuses an oversized body in bytes, fails an undecoded body by name, and android_sh passes 95/96 through"
  exit 0
fi

why=$(verdict "$TOOLS_DIR/../vm/common.sh" "$work")
if [[ -n "$why" ]]; then
  sed 's/^/check-probe-body: /' <<<"$why"
  exit 1
fi
echo "check-probe-body: ok -- probe_cmd delivers a multi-line body whole with the caller's stdin and its exit status, refuses one over the byte limit, fails an undecoded one by name, and android_sh passes those through"
