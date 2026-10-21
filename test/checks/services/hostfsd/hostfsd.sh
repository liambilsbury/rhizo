#!/bin/bash
# run the rhizo-hostfsd selftest
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

SRC="../../src/services/hostfs/hostfsd.c"
BIN="${RHIZO_HOSTFSD_BIN:-}"

MIN_ASSERTIONS=102
GROUP_MARKERS=(
  "dispatch: a slow READ does not block a concurrent READ on a different handle|READ runs off the dispatch thread and does not serialize behind another READ"
  "dispatch: CREATE onto a symlinked name is refused|CREATE opens the caller's name O_NOFOLLOW"
  "dispatch: a refused CREATE did not create the symlink's target outside the share|a refused CREATE touches nothing outside --root"
  "dispatch: a forged fh naming a descriptor the daemon holds for itself is refused by READ|the handle table refuses a forged fh"
  "dispatch: a released fh is refused, not replayed against whatever took its number|a released handle stays refused"
  "dispatch: a READDIR offset this daemon never issued is refused, not fed to seekdir|readdir offsets are validated before seekdir"
  "dispatch: FSYNCDIR with fh=0 is refused, not dereferenced|the directory opcodes check their handle"
  "dispatch: LOOKUP fills the inode table to its bound and then refuses with EMFILE|the inode table is bounded"
  "dispatch: descriptors remain for real work once the inode bound has engaged|the bound leaves a descriptor reserve"
  "dispatch: OPENDIR with an empty body is refused EINVAL|op_opendir length-checks its body"
  "dispatch: a reply larger than the descriptor takes at once is written whole|a short writev is not a finished reply"
  "no_new_privs is set on the process the kernel sees|no_new_privs is set on the serving process"
  "dispatch: the seccomp filter is attached, by the kernel's own Seccomp: line|the seccomp filter attaches"
  "seccomp: RENAME2 is answered under the filter|the opcode sweep runs under the filter"
)

# write a passing stub of rhizo-hostfsd
write_ok_stub() {
  local m
  { printf '#!/bin/sh\n'
    for m in "${GROUP_MARKERS[@]}"; do printf 'echo "SELFTEST OK:   %s"\n' "${m%%|*}"; done
    printf 'i=0; while [ $i -lt %d ]; do echo "SELFTEST OK:   stub filler $i"; i=$((i+1)); done\n' \
           "$MIN_ASSERTIONS"
    printf 'exit 0\n'; } > "$1"
  chmod +x "$1"
}

# build the fixture tree for sync.sh --check
fixture_vm() {
  local d="$1" root out e
  root=$(cd ../.. && pwd)
  mkdir -p "$d/test/vm" "$d/test/checks" "$d/tools/build" "$d/var/share" || return 1
  ln -s "$root/src" "$root/debian" "$root/archlinux" "$root/docs" "$d/" || return 1
  ln -s "$root/test/system" "$root/test/apps" "$d/test/" || return 1
  ln -s "$root/tools/patches" "$root/tools/mesa" "$d/tools/" || return 1
  for e in "$root"/test/vm/* ; do ln -s "$e" "$d/test/vm/" || return 1; done
  (cd "$root" && find test/checks tools/build tools/fetch -type f) | while IFS= read -r e; do
    mkdir -p "$d/$(dirname "$e")" && ln -s "$root/$e" "$d/$e" || exit 1
  done || return 1
  rm "$d/test/vm/sync.sh" "$d/test/checks/services/hostfsd/hostfsd.sh" "$d/tools/build/services/hostfsd.sh" || return 1
  cp ../vm/sync.sh "$d/test/vm/" || return 1
  cp services/hostfsd/hostfsd.sh "$d/test/checks/services/hostfsd/" || return 1
  cp ../../tools/build/services/hostfsd.sh "$d/tools/build/services/" || return 1
  out=$("$d/test/vm/sync.sh" 2>&1) || {
    echo "check-hostfsd --selftest: FAIL -- fixture staging failed: $out" >&2
    return 1
  }
  write_ok_stub "$d/var/share/rhizo-hostfsd"
  touch -d @0 "$d/var/share/rhizo-hostfsd"
  cp -al "$d/var/share" "$d/var/share-1"
  echo 'rig_other_shares() { echo var/share-1/; }' > "$d/share-1-hook.sh"
}

# run sync.sh --check and this script twice
check_all_twice() {
  local fx="$1" v="" rc
  for _ in 1 2; do
    rc=0
    RHIZO_VM_HOOK="$fx/share-1-hook.sh" "$fx/test/vm/sync.sh" --check >/dev/null 2>&1 || rc=1
    "$fx/test/checks/services/hostfsd/hostfsd.sh" >/dev/null 2>&1 || rc=1
    if (( rc )); then v+="FAIL "; else v+="ok "; fi
  done
  echo "${v% }"
}

# rewrite the copy to build into share/
reintroduce_share_build() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace('BIN="$BUILD_DIR/rhizo-hostfsd"', 'BIN="$PWD/../../var/share/rhizo-hostfsd"')
src = src.replace('if ! build_out=$(../../tools/build/services/hostfsd.sh "$BIN" 2>&1); then',
                  'if [[ "$SRC" -nt "$BIN" ]] && ! build_out=$(../../tools/build/services/hostfsd.sh "$BIN" 2>&1); then')
open(path, "w").write(src)
PY
  grep -q 'BIN="$PWD/../../var/share/rhizo-hostfsd"' "$1" && grep -q '"$SRC" -nt "$BIN"' "$1" || {
    echo "check-hostfsd --selftest: FAIL -- could not reintroduce the build-into-share/ shape" >&2
    return 1
  }
}

if [[ "${1:-}" == "--selftest" ]]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  printf '#!/bin/sh\nexit 1\n' > "$tmp/fake"; chmod +x "$tmp/fake"
  out=$(RHIZO_HOSTFSD_BIN="$tmp/fake" "$SELF" 2>&1); rc=$?
  if (( rc == 0 )); then
    echo "check-hostfsd --selftest: FAIL -- a daemon whose selftest fails was reported clean" >&2
    exit 1
  fi
  if ! grep -q "rhizo-hostfsd --selftest FAILED" <<<"$out"; then
    echo "check-hostfsd --selftest: FAIL -- expected 'rhizo-hostfsd --selftest FAILED', got: $out" >&2
    exit 1
  fi
  write_ok_stub "$tmp/ok"
  if ! RHIZO_HOSTFSD_BIN="$tmp/ok" "$SELF" >/dev/null 2>&1; then
    echo "check-hostfsd --selftest: FAIL -- a passing daemon selftest was reported as a failure" >&2
    exit 1
  fi
  fixture="$tmp/fixture"
  fixture_vm "$fixture" || exit 1
  verdicts=$(check_all_twice "$fixture")
  if [[ "$verdicts" != "ok ok" ]]; then
    echo "check-hostfsd --selftest: FAIL -- two runs on one tree read '$verdicts'" >&2
    exit 1
  fi
  if [[ ! "$fixture/var/share/rhizo-hostfsd" -ef "$fixture/var/share-1/rhizo-hostfsd" ]]; then
    echo "check-hostfsd --selftest: FAIL -- the check replaced share/rhizo-hostfsd under its vm" >&2
    exit 1
  fi
  reintroduce_share_build "$fixture/test/checks/services/hostfsd/hostfsd.sh" || exit 1
  verdicts=$(check_all_twice "$fixture")
  if [[ "$verdicts" != "ok FAIL" ]]; then
    echo "check-hostfsd --selftest: FAIL -- the build-into-share/ shape read '$verdicts' instead of flipping the second run" >&2
    exit 1
  fi
  echo "check-hostfsd --selftest: both directions hold; two runs agree with the daemon older than its source, and the build-into-share/ shape flips the second (ok FAIL)"
  exit 0
fi

SCRATCH=()
# remove all of the scratch paths
cleanup() { local p; for p in ${SCRATCH+"${SCRATCH[@]}"}; do rm -rf "$p"; done; }
trap cleanup EXIT

if [[ -z "$BIN" ]]; then
  [[ -f "$SRC" ]] || { echo "check-hostfsd: missing $SRC" >&2; exit 1; }
  BUILD_DIR=$(mktemp -d); SCRATCH+=("$BUILD_DIR")
  BIN="$BUILD_DIR/rhizo-hostfsd"
  if ! build_out=$(../../tools/build/services/hostfsd.sh "$BIN" 2>&1); then
    echo "check-hostfsd: rhizo-hostfsd does not build" >&2
    printf '%s\n' "$build_out" >&2
    exit 1
  fi
fi

[[ -x "$BIN" ]] || { echo "check-hostfsd: no daemon at $BIN" >&2; exit 1; }

OUT_FILE=$(mktemp); SCRATCH+=("$OUT_FILE")
"$BIN" --selftest >"$OUT_FILE" 2>&1
rc=$?
if (( rc != 0 )); then
  echo "check-hostfsd: rhizo-hostfsd --selftest FAILED" >&2
  grep -iE "fail|error" "$OUT_FILE" | head -10 >&2
  exit 1
fi

n=$(grep -c "^SELFTEST OK:" "$OUT_FILE")
(( n >= MIN_ASSERTIONS )) || {
  echo "check-hostfsd: only $n assertion(s) ran, expected at least $MIN_ASSERTIONS" >&2
  exit 1
}

(( ${#GROUP_MARKERS[@]} > 0 )) || {
  echo "check-hostfsd: no assertion groups are enumerated" >&2
  exit 1
}
missing=0
for marker in "${GROUP_MARKERS[@]}"; do
  if ! grep -F -- "${marker%%|*}" "$OUT_FILE" | grep -q "^SELFTEST OK:"; then
    echo "check-hostfsd: nothing asserted that ${marker#*|}" >&2
    missing=1
  fi
done
(( missing == 0 )) || exit 1

if [[ -f "$SRC" ]]; then
  inst_line=$(grep -n 'seccomp_install() != 0' "$SRC" | head -1 | cut -d: -f1)
  serve_line=$(grep -n '^ *serve_forever();' "$SRC" | head -1 | cut -d: -f1)
  if [[ -z "$inst_line" || -z "$serve_line" ]]; then
    echo "check-hostfsd: the daemon no longer installs a seccomp filter before serve_forever()" >&2
    exit 1
  fi
  if (( inst_line > serve_line )); then
    echo "check-hostfsd: seccomp_install() runs at line $inst_line, after serve_forever() at $serve_line" >&2
    exit 1
  fi
fi

echo "rhizo-hostfsd selftest: $n assertions, all ${#GROUP_MARKERS[@]} assertion groups present"
