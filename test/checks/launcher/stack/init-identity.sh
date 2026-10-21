#!/bin/bash
# test the Android init lookup rule
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1

SH_COPIES=(src/services/appsync/resync.sh src/androidd/host/fill-display-pool.sh src/services/appsync/remove-entries.sh
           src/androidd/host/launch-app.sh test/system/guest/capture-packets.sh test/system/android/device-filter.sh)

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0
# print a failure and mark the check failed
bad() { echo "FAIL: $*"; fail=1; }

# create a fake proc entry
fakeproc() {
  local root="$1" pid="$2" cg="$3"; shift 3
  mkdir -p "$root/$pid"
  printf '%s\0' "$@" > "$root/$pid/cmdline"
  printf '0::%s\n' "$cg" > "$root/$pid/cgroup"
}
# build the fake proc tree
build_fixture() {
  rm -rf "$1"; mkdir -p "$1"
  fakeproc "$1" 1200 /user.slice/user-1000.slice/session-3.scope /system/bin/init second_stage
  fakeproc "$1" 1300 /rhizo-host /system/bin/init second_stage
  fakeproc "$1" 1400 /rhizophone/init /system/bin/init second_stage
  fakeproc "$1" 1500 /rhizo-2/init /system/bin/init second_stage
  fakeproc "$1" 1600 /rhizo/system/uid_1000/pid_1600 /system/bin/surfaceflinger
  mkdir -p "$1/1700"
  case "$2" in
    rhizo) fakeproc "$1" 4242 /rhizo/init /system/bin/init second_stage
           fakeproc "$1" 10001 /rhizo/init /system/bin/init second_stage ;;
    unit) fakeproc "$1" 4343 /system.slice/androidd.service/android/init /system/bin/init second_stage
          fakeproc "$1" 10002 /system.slice/androidd.service/android/init /system/bin/init second_stage ;;
  esac
}
# print the runner output for each fixture
fixture_verdicts() {
  local kind out
  for kind in none rhizo unit; do
    build_fixture "$tmp/proc" "$kind"
    out=$("$@" "$tmp/proc" 2>&1 | tr '\n' ' ')
    printf '%s=%s\n' "$kind" "${out% }"
  done
}
WANT=$'none=\nrhizo=4242\nunit=4343'

# print a function's definition from a file
lift() {
  awk -v f="$2" '$0 ~ "^" f "\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$1"
}
# run stack_init_pid under the given shell
run_sh_copy() {
  RHIZO_PROC_ROOT="$3" "$1" -c 'set -eu; . "$1"; stack_init_pid; echo "rc=$?"' _ "$2" | grep -v '^rc=0$'
}

# check each shell copy of stack_init_pid under dash and bash
check_sh_copies() {
  local f body sh got
  for f in "${SH_COPIES[@]}"; do
    body=$(lift "$f" stack_init_pid)
    if [[ -z "$body" ]]; then bad "$f defines no stack_init_pid()"; continue; fi
    printf '%s\n' "$body" > "$tmp/fn.sh"
    for sh in dash bash; do
      got=$(fixture_verdicts run_sh_copy "$sh" "$tmp/fn.sh")
      [[ "$got" == "$WANT" ]] || bad "$f's stack_init_pid under $sh answered $(tr '\n' ' ' <<<"$got"), want $(tr '\n' ' ' <<<"$WANT")"
    done
  done
}

# run the scan body on a proc root
run_guest_body() {
  RHIZO_PROC_ROOT="$1" bash -c "$(source test/vm/common.sh >/dev/null 2>&1; printf '%s' "$RHIZO_INIT_SCAN_BODY")" | head -1
}
# check that common.sh's init scan body gives the wanted verdicts
check_guest_body() {
  local got
  if ! (source test/vm/common.sh >/dev/null 2>&1; [[ -n "${RHIZO_INIT_SCAN_BODY:-}" ]]); then
    bad "test/vm/common.sh defines no RHIZO_INIT_SCAN_BODY"; return
  fi
  got=$(fixture_verdicts run_guest_body)
  [[ "$got" == "$WANT" ]] || bad "common.sh's RHIZO_INIT_SCAN_BODY answered $(tr '\n' ' ' <<<"$got"), want $(tr '\n' ' ' <<<"$WANT")"
}

LINT_ALLOW=(
  src/androidd/boot.py
  src/androidd/sandbox/rootfs.py
  test/checks/launcher/stack/init-identity.sh
  test/checks/vm/boot/explain-boot-stage.sh
  test/checks/services/hostfsd/hostfs-init-resolution.py
  test/checks/system/tools/meter-attribution.py
  test/checks/install/setup/cli-pool.sh
  test/checks/vm/start/adb-bridge-explained.sh
  test/checks/system/common/system-network-observe.py
  test/checks/system/desktop/display-windowinput-harness.py
  test/checks/system/install/system-install-legs.py
  test/system/cycle/cycle.sh
  test/system/cycle/cycle-selftest.sh
  test/checks/tree/shell/remote-bodies.py
  test/checks/launcher/launch/display-pool-restart-prime.sh
  test/checks/services/resync/resync-boot-wait.py
  test/checks/services/resync/resync-drain.py
)
RULE_NAMES='stack_init_pid|guest_init_pid|RHIZO_INIT_SCAN_BODY|_in_rhizo_stack|_in_stack_cgroup|sandbox_init_alive|INSTANCE0_STACK_CGROUPS|androidd\.service/android'

# scan source files for name-only init lookups
lint() {
  local f code allowed a
  local -a files
  if [[ -n "${1:-}" ]]; then
    mapfile -t files < <(cd "$1" && find . -type f | sed 's|^\./||')
  else
    mapfile -t files < <(git ls-files -- test tools src debian \
      | grep -E '\.(sh|py|bash)$|^[^.]*$' | grep -vE '/tests/|^src/services/tests/|/share[^/]*/')
  fi
  for f in "${files[@]}"; do
    [[ -f "${1:+$1/}$f" ]] || continue
    code=$(grep -vE '^[[:space:]]*#' "${1:+$1/}$f" 2>/dev/null | grep -E '\[?s\]?econd_stage') || continue
    allowed=0
    for a in "${LINT_ALLOW[@]}"; do [[ "$f" == "$a" ]] && allowed=1; done
    (( allowed )) && continue
    local pg='pgrep[^|;]*-[a-zA-Z]*f[^|;]*\[?s\]?econd_stage|"pgrep", *"-f", *"[^"]*second_stage'
    if grep -qE "$pg" <<<"$code"; then
      bad "$f finds init with pgrep -f by name: $(grep -m1 -E "$pg" <<<"$code" | sed 's/^[[:space:]]*//' | cut -c1-120)"
      continue
    fi
    grep -vE '^[[:space:]]*#' "${1:+$1/}$f" | grep -E 'cmdline' >/dev/null || continue
    grep -qE "$RULE_NAMES" "${1:+$1/}$f" \
      || bad "$f reads a second_stage command line with no stack-cgroup rule: $(head -1 <<<"$code" | sed 's/^[[:space:]]*//' | cut -c1-120)"
  done
}

if [[ "${1:-}" == --selftest ]]; then
  cat > "$tmp/nameonly.sh" <<'EOF'
stack_init_pid() {
  for _sip_d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$_sip_d/cmdline")" in *"init second_stage"*) echo "${_sip_d##*/}"; return 0 ;; esac
  done
  return 0
}
EOF
  got=$(fixture_verdicts run_sh_copy dash "$tmp/nameonly.sh")
  [[ "$got" != "$WANT" ]] || { echo "SELFTEST FAIL: a name-only scan passed the fixture"; exit 1; }
  mkdir -p "$tmp/tree/tools/planted"
  printf '#!/bin/sh\nINIT=$(pgrep -f "init second_stage" | head -1)\n' > "$tmp/tree/tools/planted/planted-pgrep.sh"
  printf 'import os\nfor p in os.listdir("/proc"):\n    if b"second_stage" in open("/proc/%%s/cmdline" %% p, "rb").read():\n        print(p)\n' \
    > "$tmp/tree/tools/planted/planted-walk.py"
  out=$(fail=0; lint "$tmp/tree"; echo "fail=$fail")
  grep -q 'planted-pgrep.sh finds init with pgrep -f by name' <<<"$out" \
    && grep -q 'planted-walk.py reads a second_stage command line with no stack-cgroup rule' <<<"$out" \
    || { echo "SELFTEST FAIL: the lint did not name both planted lookups: $out"; exit 1; }
  echo "ok   check-init-identity selftest: a name-only scan fails the fixture, and the lint names a planted pgrep -f and a planted name-only /proc read"
  exit 0
fi

check_sh_copies
check_guest_body
lint
if (( fail )); then exit 1; fi
echo "ok   every lookup of the sandbox's init takes the one inside its stack cgroup: ${#SH_COPIES[@]} shell copies and common.sh's guest body pass the decoy fixture under dash and bash, and no tracked source finds it by name"
