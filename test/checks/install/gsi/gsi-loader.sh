#!/bin/bash
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
cd "${RHIZO_CHECK_ROOT:-$(dirname "$SELF")/../../../..}" || exit

SHELL_HELPER=test/vm/common.sh
PY_HELPER=src/androidd/sandbox/core.py

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/tools" "$t/test/vm" "$t/src/androidd/sandbox"
  fail_case() {
    RHIZO_CHECK_ROOT="$t" "$SELF" >/dev/null 2>&1
    local got=$?
    if (( got != 1 )); then
      echo "SELFTEST FAILED: $1 -- expected rc=1 (defect found), got rc=$got" >&2
      exit 1
    fi
  }
  printf 'LD_LIBRARY_PATH=%%s/lib64/bootstrap:%%s/lib64 x/bin/bootstrap/linker64\n' > "$t/test/vm/common.sh"
  printf 'LD_LIBRARY_PATH=%%s/lib64/bootstrap:%%s/lib64 x/bin/bootstrap/linker64\n' > "$t/src/androidd/sandbox/core.py"
  printf 'a=$(x/bin/bootstrap/linker64 y)\n' > "$t/tools/sometest.sh"
  fail_case "a third hand-written copy"
  rm -f "$t/tools/sometest.sh"
  printf 'LD_LIBRARY_PATH=%%s/lib64/bootstrap:%%s/lib64x x/bin/bootstrap/linker64\n' > "$t/test/vm/common.sh"
  fail_case "the two helpers drifting apart"
  printf 'LD_LIBRARY_PATH=%%s/lib64/bootstrap:%%s/lib64 x/bin/bootstrap/linker64\n' > "$t/test/vm/common.sh"
  git -C "$t" init -q || exit 1
  printf 'pkg/\n' > "$t/.gitignore"
  mkdir -p "$t/pkg/usr/lib/rhizo/sandbox"
  printf 'a=$(x/bin/bootstrap/linker64 y)\n' > "$t/pkg/usr/lib/rhizo/sandbox/core.py"
  RHIZO_CHECK_ROOT="$t" "$SELF" >/dev/null 2>&1
  got=$?
  if (( got != 0 )); then
    echo "SELFTEST FAILED: an ignored package payload's copy -- expected rc=0, got rc=$got" >&2
    exit 1
  fi
  printf 'a=$(x/bin/bootstrap/linker64 y)\n' > "$t/tools/sometest.sh"
  fail_case "an untracked third copy in a git work tree"
  echo "selftest ok: detects a third copy, an untracked one and a helper drift, and skips an ignored payload"
  exit 0
fi

rc=0

# list the .sh and .py files
candidates() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z --cached --others --exclude-standard -- '*.sh' '*.py'
  else
    find . -type f \( -name '*.sh' -o -name '*.py' \) -print0
  fi
}

mapfile -t offenders < <(
  candidates | xargs -0 -r grep -l 'bootstrap/linker64' 2>/dev/null |
  sed 's|^\./||' | grep -v '^var/' | grep -v '^test/checks/install/gsi/gsi-loader.sh$' |
  grep -vx "$SHELL_HELPER" | grep -vx "$PY_HELPER" | sort)
if (( ${#offenders[@]} )); then
  echo "these spell out the GSI bootstrap-linker invocation instead of using a helper:" >&2
  printf '  %s\n' "${offenders[@]}" >&2
  echo "  shell: gsi_bootstrap_cmd <tree> <binary> [args]   (test/vm/common.sh)" >&2
  echo "  python: gsi_bootstrap_cmd(binary, args)           (sandbox/core.py)  " >&2
  rc=1
fi

for f in "$SHELL_HELPER" "$PY_HELPER"; do
  n=$(grep -c 'bootstrap/linker64' "$f" 2>/dev/null || echo 0)
  if [[ "$n" != 1 ]]; then
    echo "$f: expected exactly 1 bootstrap/linker64 invocation, found $n" >&2
    rc=1
  fi
done

# print the LD_LIBRARY_PATH value in a file
libs_of() {
  grep -o 'LD_LIBRARY_PATH=[^ "]*' "$1" 2>/dev/null | head -1 |
    sed 's/%s//g; s/{GSI}//g; s/\$tree//g; s/\$GSI//g; s/[{}"'"'"']//g'
}
sh_libs=$(libs_of "$SHELL_HELPER")
py_libs=$(libs_of "$PY_HELPER")
if [[ -z "$sh_libs" || -z "$py_libs" ]]; then
  echo "could not read the library path out of one of the helpers" >&2
  echo "  $SHELL_HELPER: '${sh_libs:-<none>}'   $PY_HELPER: '${py_libs:-<none>}'" >&2
  rc=1
elif [[ "$sh_libs" != "$py_libs" ]]; then
  echo "the two GSI loader helpers disagree on the library path:" >&2
  echo "  $SHELL_HELPER: $sh_libs" >&2
  echo "  $PY_HELPER: $py_libs" >&2
  rc=1
fi

(( rc == 0 )) && echo "the GSI bootstrap-linker invocation lives in its two helpers and they agree"
exit $rc
