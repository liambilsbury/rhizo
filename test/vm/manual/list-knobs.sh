#!/bin/bash
# list the RHIZO_* knobs and defaults
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit

WHICH="${1:---all}"

mapfile -t DIRS < <(python3 test/checks/lib/tree_dirs.py --test --tools)
(( ${#DIRS[@]} )) || { echo "list-knobs: test/checks/lib/tree_dirs.py listed no folder" >&2; exit 1; }
FILES=()
for d in "${DIRS[@]}" tools/mesa tools/patches; do FILES+=("$d"/*.sh "$d"/*.py); done
FILES+=(src/androidd/*.py src/androidd/*.sh src/services/*/*.py src/services/*/*.sh)

knobs=$(grep -rhoE 'RHIZO_[A-Z0-9_]+' \
          "${FILES[@]}" 2>/dev/null \
        | sort -u)

for k in $knobs; do
  files=$(grep -rlE "\\b$k\\b" "${FILES[@]}" 2>/dev/null \
          | sed 's|^|      |' | head -4)
  def=$(grep -rhoE "\\\$\\{$k:-[^}]*\\}" \
          "${FILES[@]}" 2>/dev/null \
        | head -1 | sed -E "s/.*:-([^}]*)\}/\1/")
  guest=no
  grep -qE "\\b$k\\b" src/androidd/boot.py 2>/dev/null && guest=yes
  assigned=no
  grep -rqE "(^|[[:space:];&|])(export[[:space:]]+)?$k=" \
      "${FILES[@]}" 2>/dev/null && assigned=yes
  case "$WHICH" in
    --unassigned) [[ "$assigned" == no ]] || continue ;;
  esac
  case "$WHICH" in
    --guest) [[ "$guest" == yes ]] || continue ;;
    --host)  [[ "$guest" == no  ]] || continue ;;
  esac
  printf '%s\n' "$k"
  printf '    default: %s\n' "${def:-<none>}"
  printf '    read by boot.py (guest-side): %s\n' "$guest"
  printf '    assigned somewhere in-tree: %s\n' "$assigned"
  printf '    read in:\n%s\n' "$files"
done
