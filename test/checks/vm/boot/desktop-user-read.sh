#!/bin/bash
# test the desktop-user read in redeploy.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# print the desktop-user read command from redeploy.sh
read_line() {
  local fn out
  fn=$(sed -n '/^resolve_desktop_session() {/,/^}/p' "$1")
  [[ -n "$fn" ]] || return 1
  out=$(ssh_vm() { printf '%s\n' "${*: -1}"; }
        # shellcheck disable=SC2034
        rig_desktop_user=rig-user
        eval "$fn"
        resolve_desktop_session) || return 1
  printf '%s\n' "${out%%$'\n'*}"
}

# print the user and stderr from the read
run_read() {
  local out
  out=$(bash -c "${1//\/etc\/rhizo\/desktop-user/$2}"$'\n''echo "user=$u"' 2>"$SCRATCH/err")
  echo "$out stderr=[$(tr '\n' ' ' <"$SCRATCH/err")]"
}

# test for a non-root user id
unreadable_case_runs() { (( EUID != 0 )); }
SKIP_UNREADABLE="the unreadable-file case: this runs as root, which reads a mode-000 file"

# print each difference in the desktop-user read
problems() {
  local line got
  if ! line=$(read_line "$1"); then
    echo "no resolve_desktop_session in $1"
    return
  fi
  got=$(run_read "$line" "$SCRATCH/absent")
  [[ "$got" == "user=rig-user stderr=[]" ]] || echo "with no desktop-user file the read gives: $got"
  : > "$SCRATCH/empty"
  got=$(run_read "$line" "$SCRATCH/empty")
  [[ "$got" == "user=rig-user stderr=[]" ]] || echo "with an empty desktop-user file the read gives: $got"
  printf ' named\n' > "$SCRATCH/named"
  got=$(run_read "$line" "$SCRATCH/named")
  [[ "$got" == "user=named stderr=[]" ]] || echo "with a desktop-user file naming 'named' the read gives: $got"
  if unreadable_case_runs; then
    rm -f "$SCRATCH/unreadable"
    printf 'named\n' > "$SCRATCH/unreadable"
    chmod 000 "$SCRATCH/unreadable"
    got=$(run_read "$line" "$SCRATCH/unreadable")
    [[ "$got" == "user=rig-user stderr=["*"$SCRATCH/unreadable: Permission denied"*"]" ]] \
      || echo "with an unreadable desktop-user file the read gives: $got, not the rig's user and the shell's Permission denied"
  fi
}

# test the read check against fixture files
selftest() {
  local fails=0 out
  fixture() {
    printf 'resolve_desktop_session() {\n  ssh_vm -t 30 "%s\nuid=x"\n}\n' "$2" > "$SCRATCH/$1.sh"
  }
  expect() {
    out=$(problems "$SCRATCH/$1.sh")
    if [[ -z "$2" && -z "$out" ]] || [[ -n "$2" && "$out" == *"$2"* ]]; then
      echo "ok   selftest: $1"
    else
      echo "FAIL selftest: $1: got '$out', want '${2:-nothing}'"; fails=1
    fi
  }
  fixture tested 'u=; if [ -e /etc/rhizo/desktop-user ]; then u=\$(tr -d '"'"'[:space:]'"'"' < /etc/rhizo/desktop-user); fi; [ -n \"\$u\" ] || u=$rig_desktop_user'
  expect tested ""
  fixture loud 'u=\$(tr -d '"'"'[:space:]'"'"' < /etc/rhizo/desktop-user 2>/dev/null); [ -n \"\$u\" ] || u=$rig_desktop_user'
  expect loud "with no desktop-user file the read gives: user=rig-user stderr=[bash: line 1: $SCRATCH/absent: No such file or directory"
  fixture hidden 'u=\$(tr -d '"'"'[:space:]'"'"' 2>/dev/null < /etc/rhizo/desktop-user); [ -n \"\$u\" ] || u=$rig_desktop_user'
  if unreadable_case_runs; then
    expect hidden "with an unreadable desktop-user file the read gives: user=rig-user stderr=[], not the rig's user and the shell's Permission denied"
  else
    echo "SKIP selftest: hidden -- $SKIP_UNREADABLE"
  fi
  fixture no-fallback 'u=; if [ -e /etc/rhizo/desktop-user ]; then u=\$(tr -d '"'"'[:space:]'"'"' < /etc/rhizo/desktop-user); fi'
  expect no-fallback "with no desktop-user file the read gives: user= stderr=[]"
  fixture no-read 'u=$rig_desktop_user'
  expect no-read "with a desktop-user file naming 'named' the read gives: user=rig-user"
  printf 'echo nothing here\n' > "$SCRATCH/none.sh"
  expect none "no resolve_desktop_session in $SCRATCH/none.sh"
  (( fails )) && { echo "desktop-user read selftest FAILED"; return 1; }
  echo "desktop-user read selftest: every case passed"
}

if [[ "${1:-}" == --selftest ]]; then
  selftest
  exit
fi
out=$(problems "$HERE/../vm/redeploy.sh")
if [[ -n "$out" ]]; then
  echo "FAIL: redeploy.sh's resolve_desktop_session reads /etc/rhizo/desktop-user wrongly:"
  sed 's/^/  /' <<<"$out"
  exit 1
fi
unreadable_case_runs || echo "SKIP $SKIP_UNREADABLE"
echo "redeploy.sh reads /etc/rhizo/desktop-user silently when it is missing and loudly when it cannot, falling back to the rig's user"
