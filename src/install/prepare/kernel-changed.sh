#!/bin/bash

# print the kernel in the current tree manifest
tree_kernel() {
  python3 - "$1" 2>/dev/null <<'PY'
import json, os, sys
root = sys.argv[1]
try:
    key = os.path.basename(os.readlink(os.path.join(root, "current")))
    with open(os.path.join(root, key, "manifest.json")) as f:
        print(json.load(f).get("kernel") or "")
except (OSError, ValueError, AttributeError):
    pass
PY
}

# compare the marker kernel with the current kernel
kernel_changed() {
  local marker="$1" current="$2" root="${3:-}" marker_kernel tree
  [[ -s "$marker" ]] || return 1
  marker_kernel=$(sed -n 's/^kernel=//p' "$marker" | tail -1)
  [[ -n "$marker_kernel" ]] || return 1
  [[ "$marker_kernel" != "$current" ]] && return 0
  [[ -n "$root" ]] || return 1
  tree=$(tree_kernel "$root")
  [[ -n "$tree" && "$tree" != "$current" ]]
}

# print the marker version and payload version
payload_changed() {
  local marker_version="" payload_version=""
  [[ -s "$1" ]] && marker_version=$(sed -n 's/^version=//p' "$1" | tail -1)
  [[ -s "$2" ]] && payload_version=$(< "$2")
  [[ -n "$marker_version" && -n "$payload_version" && "$marker_version" != "$payload_version" ]] || return 1
  echo "$marker_version $payload_version"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
set -uo pipefail
MARKER="${RHIZO_PREPARED_MARKER:-/var/lib/rhizo/.prepared}"
PREPARED_ROOT="${RHIZO_PREPARED_ROOT:-/var/lib/rhizo/prepared}"
PAYLOAD_VERSION="${RHIZO_PAYLOAD_VERSION:-/usr/lib/rhizo/VERSION}"

if [[ "${1:-}" == --selftest ]]; then
  TMP=$(mktemp -d) || exit 1
  trap 'rm -rf "$TMP"' EXIT

  printf 'kernel=6.8.0-136-generic\nversion=0.1.1\n' > "$TMP/prepared-old"
  kernel_changed "$TMP/prepared-old" "6.8.0-140-generic" \
    || { echo "SELFTEST FAILED: a differing kernel= was not reported as changed" >&2; exit 1; }

  printf 'kernel=6.8.0-140-generic\nversion=0.1.1\n' > "$TMP/prepared-same"
  kernel_changed "$TMP/prepared-same" "6.8.0-140-generic" \
    && { echo "SELFTEST FAILED: a matching kernel= was reported as changed" >&2; exit 1; }

  kernel_changed "$TMP/absent" "6.8.0-140-generic" \
    && { echo "SELFTEST FAILED: a missing marker was reported as changed" >&2; exit 1; }

  printf 'version=0.1.1\n' > "$TMP/prepared-no-kernel-line"
  kernel_changed "$TMP/prepared-no-kernel-line" "6.8.0-140-generic" \
    && { echo "SELFTEST FAILED: a marker with no kernel= line was reported as changed" >&2; exit 1; }

  mkdir -p "$TMP/root/abc123def456"
  ln -s abc123def456 "$TMP/root/current"
  printf '{"kernel": "6.8.0-136-generic"}' > "$TMP/root/abc123def456/manifest.json"
  printf 'kernel=6.8.0-142-generic\nversion=0.1.2\n' > "$TMP/prepared-moved"
  kernel_changed "$TMP/prepared-moved" "6.8.0-142-generic" "$TMP/root" \
    || { echo "SELFTEST FAILED: a tree still naming the old kernel under a moved marker was not reported as changed" >&2; exit 1; }

  printf '{"kernel": "6.8.0-142-generic"}' > "$TMP/root/abc123def456/manifest.json"
  kernel_changed "$TMP/prepared-moved" "6.8.0-142-generic" "$TMP/root" \
    && { echo "SELFTEST FAILED: a tree and a marker both on this kernel were reported as changed" >&2; exit 1; }

  kernel_changed "$TMP/prepared-moved" "6.8.0-142-generic" "$TMP/no-tree" \
    && { echo "SELFTEST FAILED: a host with no prepared tree was reported as changed" >&2; exit 1; }

  printf '0.1.4\n' > "$TMP/VERSION"
  condition() {
    printf '%s' "$1" > "$TMP/marker"
    RHIZO_PREPARED_MARKER="$TMP/marker" RHIZO_PREPARED_ROOT="$TMP/no-tree" RHIZO_PAYLOAD_VERSION="$TMP/VERSION" \
      bash "$0"
  }
  condition "kernel=$(uname -r)"$'\nversion=0.1.4\n' \
    && { echo "SELFTEST FAILED: a marker naming this payload's version was reported as changed" >&2; exit 1; }
  condition "kernel=$(uname -r)"$'\nversion=0.1.3\n' \
    || { echo "SELFTEST FAILED: a marker naming another payload's version was not reported as changed" >&2; exit 1; }
  condition "kernel=$(uname -r)"$'\n' \
    && { echo "SELFTEST FAILED: a marker with no version= line was reported as changed" >&2; exit 1; }
  condition "kernel=$(uname -r)"$'\nversion=\n' \
    && { echo "SELFTEST FAILED: a marker with an empty version= was reported as changed" >&2; exit 1; }
  rm "$TMP/VERSION"
  condition "kernel=$(uname -r)"$'\nversion=0.1.3\n' \
    && { echo "SELFTEST FAILED: a payload with no VERSION file was reported as changed" >&2; exit 1; }
  condition "kernel=0.0.0-not-this-kernel"$'\nversion=0.1.4\n' \
    || { echo "SELFTEST FAILED: a differing kernel= with no VERSION file was not reported as changed" >&2; exit 1; }

  echo "rhizo-kernel-changed --selftest: ok (13 cases)"
  exit 0
fi

if kernel_changed "$MARKER" "$(uname -r)" "$PREPARED_ROOT" || payload_changed "$MARKER" "$PAYLOAD_VERSION" >/dev/null
then
  exit 0
fi
exit 1
