#!/bin/bash
# scan scripts for an unguarded git init
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
Q="'"

# check a file for a git init call
is_candidate() {
  grep -qE "(^|[;&|(\`]|\\\$\()[[:space:]]*git([[:space:]]+-[cC][[:space:]]+[^[:space:]]+)*[[:space:]]+init([[:space:]]|\$)" "$1" && return 0
  grep -qE "[\"$Q]git[\"$Q]" "$1" && grep -qE "[\"$Q]init[\"$Q]" "$1" && return 0
  return 1
}

# check a file for GIT_ variable removal
is_guarded() {
  grep -qE '^[[:space:]]*unset[[:space:]]+[^#]*GIT_DIR' "$1" && grep -q 'GIT_INDEX_FILE' "$1" && return 0
  grep -qE "startswith\([\"$Q]GIT_[\"$Q]\)" "$1" && return 0
  return 1
}

# print the unguarded git init files from stdin
scan() {
  local f rc=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    case "$f" in *.sh|*.py) ;; *) continue ;; esac
    if is_candidate "$f" && ! is_guarded "$f"; then
      printf '%s\n' "$f"
      rc=1
    fi
  done
  return $rc
}

if [[ "${1:-}" == "--selftest" ]]; then
  D="$(mktemp -d)"
  trap 'rm -rf "$D"' EXIT
  printf '#!/bin/bash\nset -uo pipefail\nS=$(mktemp -d)\ngit -C "$S" init -q\n' > "$D/bad.sh"
  printf '#!/bin/bash\nset -uo pipefail\nunset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE\nS=$(mktemp -d)\ngit -C "$S" init -q\n' > "$D/good.sh"
  printf 'import os\nGIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}\ndef g(*a):\n    return ["git", *a]\ng("init", "-q")\n' > "$D/good.py"
  printf 'import subprocess\nsubprocess.run(["git", "init", "-q", "/tmp/x"])\n' > "$D/bad.py"
  out=$(printf '%s\n' "$D/bad.sh" "$D/good.sh" "$D/good.py" "$D/bad.py" | scan)
  grep -q "$D/bad.sh"  <<<"$out" || { echo "check-git-init-env-guard: selftest FAILED -- an unguarded shell git init was not caught" >&2; exit 1; }
  grep -q "$D/bad.py"  <<<"$out" || { echo "check-git-init-env-guard: selftest FAILED -- an unguarded python git init was not caught" >&2; exit 1; }
  grep -q "$D/good.sh" <<<"$out" && { echo "check-git-init-env-guard: selftest FAILED -- a guarded shell script was reported" >&2; exit 1; }
  grep -q "$D/good.py" <<<"$out" && { echo "check-git-init-env-guard: selftest FAILED -- a guarded python script was reported" >&2; exit 1; }
  echo "check-git-init-env-guard: selftest ok (catches both unguarded shapes, clears both guarded ones)"
  exit 0
fi

out=$(git -C "$ROOT" ls-files -z | grep -zE '^[^./][^/]*/' | tr '\0' '\n' | sed "s|^|$ROOT/|" | scan)
if [[ -n "$out" ]]; then
  echo "check-git-init-env-guard: these run git init without first dropping a hook's GIT_* environment," >&2
  echo "so under the pre-commit hook the init lands in the real repo (core.bare=true):" >&2
  sed 's|^|  |' <<<"$out" >&2
  echo "Add, above the first git call:" >&2
  echo "  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \\" >&2
  echo "        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES" >&2
  exit 1
fi
echo "check-git-init-env-guard: every git init drops the inherited git environment first"
