#!/bin/bash
# test _plasma_inject with a stubbed systemctl
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
lib=$(realpath "${1:-../system/lib/plasma-lib.sh}") || exit 1
# shellcheck source=../system/lib/plasma-lib.sh
source "$lib" || { echo "FAIL check-plasma-inject: $lib did not source"; exit 1; }

tmp=$(mktemp -d) || exit 1
dev=""
trap '[[ -n "$dev" ]] && kill "$dev" 2>/dev/null; chmod -R u+rwx "$tmp"; rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/systemctl" <<EOF
#!/bin/bash
[ "\$*" = "is-active -q $PLASMA_INJECT_UNIT" ] || { echo "unexpected systemctl \$*" >&2; exit 64; }
[ "\$(cat "$tmp/unit")" = active ]
EOF
chmod +x "$tmp/bin/systemctl"
echo active > "$tmp/unit"
PLASMA_INJECT_FIFO="$tmp/fifo" PLASMA_INJECT_OUT="$tmp/out"
mkfifo "$PLASMA_INJECT_FIFO"
: > "$PLASMA_INJECT_OUT"
( exec 3<>"$PLASMA_INJECT_FIFO" 4>>"$PLASMA_INJECT_OUT"
  while IFS= read -r l <&3; do
    case "$l" in
      *4294967296*) echo "err not a whole number from 0 to 4294967295: 4294967296" ;;
      *) echo ok ;;
    esac >&4
  done ) &
dev=$!
# run the command with the stub systemctl
gcmd_plasma() { PATH="$tmp/bin:$PATH" bash -c "$1"; }

fails=0 n=0
# check _plasma_inject stderr and exit code
expect() {
  local name="$1" want_rc="$2" want_err="$3" err rc
  shift 3
  err=$(_plasma_inject "$@" 2>&1 >/dev/null); rc=$?
  n=$(( n + 1 ))
  if [[ "$rc" != "$want_rc" || ( -n "$want_err" && "$err" != *"$want_err"* ) || ( -z "$want_err" && -n "$err" ) ]]; then
    echo "FAIL $name: rc $rc, stderr '$(head -n 3 <<<"$err")'; want rc $want_rc${want_err:+ and '$want_err'}"
    fails=$(( fails + 1 ))
  fi
}

expect all-accepted 0 '' "move 1 2" "button 272 1" "button 272 0"
expect negative-coordinates 0 '' "move -37 10" "move 4 -29"
expect one-refused 1 "kde-inject refused an event: not a whole number from 0 to 4294967295: 4294967296" \
  "key 30 1" "key 4294967296 1" "key 30 0"
expect after-refusal 0 '' "key 31 1" "key 31 0"
expect shell-refused 2 "not an event line: 'key -1 1'" "key -1 1"
echo inactive > "$tmp/unit"
expect unit-stopped 1 "the session input device $PLASMA_INJECT_UNIT is not running" "key 30 1"
echo active > "$tmp/unit"
mv "$PLASMA_INJECT_OUT" "$tmp/out.kept"
expect answers-missing 1 "the session input device's answers $PLASMA_INJECT_OUT are missing or unreadable" "key 30 1"
mkdir "$PLASMA_INJECT_OUT"
expect answers-directory 1 "the session input device's answers $PLASMA_INJECT_OUT did not read" "key 30 1"
rmdir "$PLASMA_INJECT_OUT"
mv "$tmp/out.kept" "$PLASMA_INJECT_OUT"
if (( EUID == 0 )); then
  echo "SKIP answers-unreadable: running as root, which reads a mode-000 file"
else
  chmod 000 "$PLASMA_INJECT_OUT"
  expect answers-unreadable 1 "the session input device's answers $PLASMA_INJECT_OUT are missing or unreadable" "key 30 1"
  chmod 644 "$PLASMA_INJECT_OUT"
fi
expect accepted-again 0 '' "key 32 1" "key 32 0"

if (( fails )); then
  echo "check-plasma-inject: $fails of $n cases failed"
  exit 1
fi
echo "check-plasma-inject: $n cases: one answer counted per line, a refused line, a stopped unit and an answers file missing, unreadable or a directory each fail by name, the next call counts clean, negative coordinates pass"
