#!/bin/bash
# test the container mounts run.sh gives a checkout
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
RUN_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/tools/build/env/run.sh"
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
printf '#!/bin/bash\n[[ "$1" == run ]] || exit 0\nshift\nprintf "%%s\\n" "$@"\n' > "$tmp/bin/podman"
chmod +x "$tmp/bin/podman"

# make a git checkout carrying run.sh at the path it expects
make_checkout() {
  mkdir -p "$1/tools/build/env"
  cp "$RUN_SH" "$1/tools/build/env/run.sh"
  : > "$1/tools/build/env/Containerfile"; : > "$1/tools/build/env/packages.txt"
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@t commit -qm fixture
}

# print the arguments run.sh hands the engine for a checkout
engine_args() {
  (cd "$1" && HOME="$tmp/home" RHIZO_ENGINE="$tmp/bin/podman" RHIZO_INPUT_CACHE="$tmp/cache" \
     RHIZO_KERNEL_CACHE="$tmp/kcache" RHIZO_AOSP_DIR='' tools/build/env/run.sh true)
}

make_checkout "$tmp/clones/rhizo"
out=$(engine_args "$tmp/clones/rhizo")
grep -qx "$tmp/clones:rw,exec,mode=1777" <<<"$out" \
  || { echo "FAIL a plain clone's parent $tmp/clones gets no writable tmpfs: $(tr '\n' ' ' <<<"$out")"; fail=1; }

git -C "$tmp/clones/rhizo" worktree add -q "$tmp/clones/rhizo/.worktrees/wt" -b wt 2>/dev/null
out=$(engine_args "$tmp/clones/rhizo/.worktrees/wt")
grep -qx -- "-v" <<<"$out" && grep -qx "$tmp/clones/rhizo:$tmp/clones/rhizo" <<<"$out" \
  || { echo "FAIL a worktree's main checkout is not mounted: $(tr '\n' ' ' <<<"$out")"; fail=1; }
! grep -q "^$tmp/clones/rhizo/.worktrees:" <<<"$out" \
  || { echo "FAIL a worktree inside its main checkout got a tmpfs over .worktrees"; fail=1; }

grep -qx "$tmp/kcache:$tmp/kcache" <<<"$out" && grep -qx "RHIZO_KERNEL_CACHE=$tmp/kcache" <<<"$out" \
  || { echo "FAIL RHIZO_KERNEL_CACHE=$tmp/kcache is not mounted at its own path and passed in: $(tr '\n' ' ' <<<"$out")"; fail=1; }
out=$(cd "$tmp/clones/rhizo/.worktrees/wt" && HOME="$tmp/home" RHIZO_ENGINE="$tmp/bin/podman" RHIZO_INPUT_CACHE="$tmp/cache" \
  env -u RHIZO_KERNEL_CACHE RHIZO_AOSP_DIR= tools/build/env/run.sh true)
kcache="$tmp/home/.cache/rhizo/kernel"
grep -qx "$kcache:$kcache" <<<"$out" && grep -qx "RHIZO_KERNEL_CACHE=$kcache" <<<"$out" && [[ -d "$kcache" ]] \
  || { echo "FAIL the default kernel cache $kcache is not made, mounted and passed in: $(tr '\n' ' ' <<<"$out")"; fail=1; }

under_tmp=$(mktemp -d /tmp/build-env-mounts.XXXXXX)
make_checkout "$under_tmp"
out=$(engine_args "$under_tmp")
rm -rf "$under_tmp"
[[ $(grep -c '^/tmp:' <<<"$out") == 1 ]] \
  || { echo "FAIL a checkout directly under /tmp mounts /tmp more than once: $(tr '\n' ' ' <<<"$out")"; fail=1; }

(( fail == 0 )) && echo "build-env-mounts: ok"
exit "$fail"
