#!/bin/bash
# check installer.sh for reads of var/debs
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST="$HERE/../system/install/installer.sh"

# print the FAIL lines for an installer.sh
check_snapshot_scope() {
  local f="$1" boundary assign_line require_line out=""
  boundary=$(grep -n '^RHIZO_DEB="\$EV_DEB_DIR/' "$f" | head -1 | cut -d: -f1)
  if [[ -z "$boundary" ]]; then
    echo "FAIL: installer.sh never assigns RHIZO_DEB from \$EV_DEB_DIR"
    return
  fi
  while IFS=: read -r rel line; do
    [[ -n "$rel" ]] || continue
    out+="FAIL: installer.sh:$((boundary + rel - 1)) reads a shared deb path after step 0's snapshot: ${line# }
"
  done < <(tail -n "+$((boundary + 1))" "$f" \
             | grep -nE '\$DEB_DIR\b|\$\{DEB_DIR\}|\$KERNEL_DEB_DIR\b|\$\{KERNEL_DEB_DIR\}|var/debs|\$\{debs\[')

  assign_line=$(grep -n 'RHIZO_DEB="\$EV_DEB_DIR/' "$f" | head -1 | cut -d: -f1)
  require_line=$(grep -n 'deb-require "\$RHIZO_DEB"' "$f" | head -1 | cut -d: -f1)
  if [[ -z "$assign_line" ]]; then
    out+="FAIL: installer.sh never assigns RHIZO_DEB from \$EV_DEB_DIR
"
  elif [[ -z "$require_line" ]]; then
    out+="FAIL: installer.sh has no deb-require \"\$RHIZO_DEB\" call to check the snapshot against
"
  elif (( assign_line >= require_line )); then
    out+="FAIL: installer.sh:$require_line calls deb-require before the \$EV_DEB_DIR snapshot is assigned at line $assign_line
"
  fi

  while IFS=: read -r rel line; do
    [[ -n "$rel" ]] || continue
    case "$line" in *'="$EV_DEB_DIR/'*) continue ;; esac
    out+="FAIL: installer.sh:$((boundary + rel - 1)) reassigns a deb variable without \$EV_DEB_DIR: ${line# }
"
  done < <(tail -n "+$((boundary + 1))" "$f" | grep -nE '^RHIZO_DEB=')

  while IFS=: read -r rel line; do
    [[ -n "$rel" ]] || continue
    case "$line" in *'KERNEL_DEBS+=("$EV_DEB_DIR/'*) continue ;; esac
    out+="FAIL: installer.sh:$rel adds a Rhizo kernel .deb to KERNEL_DEBS from outside \$EV_DEB_DIR: ${line# }
"
  done < <(grep -n 'KERNEL_DEBS+=(' "$f")

  printf '%s' "$out"
}

# check installer.sh runs rm -rf on EV_DEB_DIR
check_snapshot_clear() {
  if ! grep -q '^rm -rf "\$EV_DEB_DIR"$' "$1"; then
    echo "FAIL: installer.sh never clears \$EV_DEB_DIR before copying into it"
  fi
}

if [[ "${1:-}" == --selftest ]]; then
  n=0
  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  printf '\nscp "$DEB_DIR"/rhizo_*.deb somewhere\n' >> "$work/installer.sh"
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'reads a shared deb path after step 0' <<<"$out"; then
    echo "SELFTEST FAILED (later-read): a \$DEB_DIR read after the boundary was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  sed -i 's#RHIZO_DEB="\$EV_DEB_DIR/\$(basename "\${debs\[-1\]}")"#RHIZO_DEB="${debs[-1]}"#' "$work/installer.sh"
  if cmp -s "$TEST" "$work/installer.sh"; then
    echo "SELFTEST FAILED (revert-to-shared): the sed did not change the file" >&2
    rm -rf "$work"; exit 1
  fi
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'never assigns RHIZO_DEB from \$EV_DEB_DIR' <<<"$out"; then
    echo "SELFTEST FAILED (revert-to-shared): reverting RHIZO_DEB to the shared glob was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  python3 - "$work/installer.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
assign_i = next(i for i, l in enumerate(lines) if l.startswith('RHIZO_DEB="$EV_DEB_DIR/'))
assign_line = lines.pop(assign_i)
require_i = next(i for i, l in enumerate(lines) if 'deb-require "$RHIZO_DEB"' in l)
lines.insert(require_i + 2, assign_line)
open(p, "w").write("\n".join(lines))
PY
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'calls deb-require before the \$EV_DEB_DIR snapshot is assigned' <<<"$out"; then
    echo "SELFTEST FAILED (reordered): deb-require running before the snapshot assignment was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  sed -i 's#^step "1\. the artifact carries#RHIZO_DEB="${debs[-1]}"\nstep "1. the artifact carries#' "$work/installer.sh"
  if cmp -s "$TEST" "$work/installer.sh"; then
    echo "SELFTEST FAILED (rhizo-deb-reassigned-later): the sed did not change the file" >&2
    rm -rf "$work"; exit 1
  fi
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -qE 'reads a shared deb path after step 0|reassigns a deb variable' <<<"$out"; then
    echo "SELFTEST FAILED (rhizo-deb-reassigned-later): reassigning RHIZO_DEB from the shared glob after the snapshot was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  sed -i 's#package-tree\.py "\$RHIZO_DEB" "\$REPO_ROOT"#package-tree.py "${debs[-1]}" "$REPO_ROOT"#' "$work/installer.sh"
  if cmp -s "$TEST" "$work/installer.sh"; then
    echo "SELFTEST FAILED (tree-check-shared): the sed did not change the file" >&2
    rm -rf "$work"; exit 1
  fi
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'reads a shared deb path after step 0' <<<"$out"; then
    echo "SELFTEST FAILED (tree-check-shared): checking the shared glob instead of \$RHIZO_DEB was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  python3 - "$work/installer.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
t2 = t.replace('rm -rf "$EV_DEB_DIR"\n', "", 1)
assert t2 != t, "seed did not change the file"
open(p, "w").write(t2)
PY
  out=$(check_snapshot_clear "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'never clears \$EV_DEB_DIR' <<<"$out"; then
    echo "SELFTEST FAILED (clear-dropped): dropping the rm -rf \$EV_DEB_DIR line was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  sed -i 's#KERNEL_DEBS+=("\$EV_DEB_DIR/\$(basename "\$k")")#KERNEL_DEBS+=("$k")#' "$work/installer.sh"
  if cmp -s "$TEST" "$work/installer.sh"; then
    echo "SELFTEST FAILED (kernel-deb-shared): the sed did not change the file" >&2
    rm -rf "$work"; exit 1
  fi
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'adds a Rhizo kernel .deb to KERNEL_DEBS from outside \$EV_DEB_DIR' <<<"$out"; then
    echo "SELFTEST FAILED (kernel-deb-shared): a kernel .deb taken from the shared dir was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  work=$(mktemp -d)
  cp "$TEST" "$work/installer.sh"
  printf '\ndeb_pool_kernel_debs "$RHIZO_DEB" "$KERNEL_DEB_DIR"\n' >> "$work/installer.sh"
  out=$(check_snapshot_scope "$work/installer.sh")
  rm -rf "$work"
  if ! grep -q 'reads a shared deb path after step 0' <<<"$out"; then
    echo "SELFTEST FAILED (kernel-dir-later-read): a \$KERNEL_DEB_DIR read after the boundary was not caught: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  out="$(check_snapshot_scope "$TEST")$(check_snapshot_clear "$TEST")"
  if [[ -n "$out" ]]; then
    echo "SELFTEST FAILED (real file): the unmutated installer.sh was flagged: $out" >&2
    exit 1
  fi
  n=$((n + 1))

  echo "check-installer-deb-snapshot selftest: $n planted cases caught by name; the real file passes"
  exit 0
fi

out="$(check_snapshot_scope "$TEST")$(check_snapshot_clear "$TEST")"
if [[ -n "$out" ]]; then
  printf '%s' "$out"
  exit 1
fi
echo "installer.sh reads var/debs and the Rhizo kernel's .deb dir only at step 0, into its own evidence snapshot"
