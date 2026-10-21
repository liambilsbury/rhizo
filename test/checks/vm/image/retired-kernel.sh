#!/bin/bash
# check no rig boot reaches for the retired 6.12.99-rhizo kernel
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/test/vm/image/release-map.sh"

FAILURES=()
# record a failure
fail() { FAILURES+=("$1"); }

hits=$(git -C "$ROOT" grep -nE 'RHIZO_KERNEL:-rhizo|(^|[;&|[:space:]])(export )?RHIZO_KERNEL=["'"'"']?rhizo(["'"'"';&[:space:]]|$)' \
  -- test/system test/vm)
while IFS= read -r h; do
  [[ -n "$h" ]] && fail "$h: defaults or forces RHIZO_KERNEL=rhizo, the retired 6.12.99-rhizo kernel"
done <<<"$hits"

remnants=$(git -C "$ROOT" grep -nE 'kernel-rhizo\.sh|kbuild-612-saved|binder_linux-rhizo\.ko|-6\.12\.99-rhizo\.ko|binder_linux-6\.12\.99\.ko|compat-6\.12\.99\.ko|6\.12\.99-061299-generic|--kernel rhizo' \
  -- src test tools debian ':!test/checks/vm/image/retired-kernel.sh')
while IFS= read -r h; do
  [[ -n "$h" ]] && fail "$h: names a builder, a module or an option of a retired 6.12.99 kernel leg"
done <<<"$remnants"

for k in rhizo 6.12; do
  out=$(RHIZO_PRINT_ARGV=1 RHIZO_VM=0 RHIZO_KERNEL="$k" bash "$ROOT/test/vm/run-vm.sh" 2>&1 >/dev/null) \
    && fail "run-vm.sh accepted RHIZO_KERNEL=$k, a retired kernel leg"
  [[ "$out" == *"retired"* ]] || fail "run-vm.sh does not refuse RHIZO_KERNEL=$k by name (got: $(tail -1 <<<"$out"))"
done

for rel in "${RELEASE_LABELS[@]}"; do
  [[ "${GSI_KERNEL[$rel]:-}" == rhizo ]] || continue
  why=$(release_retired "$rel") \
    || { fail "$rel boots the 6.12.99-rhizo kernel, but release-map.sh does not name it retired"; continue; }
  [[ -z "${RELEASE_BUILD_CMD[$rel]:-}" ]] \
    || fail "$rel is retired, but release-map.sh still offers ${RELEASE_BUILD_CMD[$rel]} to build it"
  out=$("$ROOT/tools/build/release.sh" "$rel" 2>&1) \
    && fail "tools/build/release.sh $rel exited 0 for a retired release"
  [[ "$out" == *"$why"* ]] || fail "tools/build/release.sh $rel does not name why it is retired (got: $(tail -1 <<<"$out"))"
  targets=$(sed -n 's/^TARGETS="\(.*\)"$/\1/p' "$ROOT/test/system/install/version-swap.sh")
  [[ ",$targets," == *",$rel,"* ]] && fail "version-swap.sh's default targets ($targets) still boot $rel"
  grep -qw "$rel" "$ROOT/test/system/install/gsi-update.sh" \
    && fail "gsi-update.sh still names $rel, which this rig cannot boot, in its trials"
done

if (( ${#FAILURES[@]} )); then
  printf 'FAIL: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "check-retired-kernel: no rig boot defaults to a retired 6.12.99 kernel, run-vm.sh refuses both by name, nothing builds, stages or names their modules, and every release that needs the rhizo one is refused by name and out of the update trials"
