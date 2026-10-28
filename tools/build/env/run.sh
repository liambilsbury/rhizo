#!/bin/bash
# run a command inside the rhizo build container
set -euo pipefail
ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ENV_DIR/../../.." && pwd)"
ENGINE="${RHIZO_ENGINE:-$(command -v podman || command -v docker || true)}"
[[ -n "$ENGINE" ]] || { echo "run.sh: no podman or docker -- run make setup" >&2; exit 1; }
TAG="$(cat "$ENV_DIR/Containerfile" "$ENV_DIR/packages.txt" | sha256sum | cut -c1-12)"
IMAGE="localhost/rhizo-build:$TAG"

# build the image this definition names
build_image() {
  "$ENGINE" build -t "$IMAGE" -f "$ENV_DIR/Containerfile" "$ENV_DIR"
}

case "${1:-}" in
  --image) echo "$IMAGE"; exit 0 ;;
  --build-image) build_image; exit $? ;;
  "") echo "usage: $0 --image | --build-image | <command>..." >&2; exit 2 ;;
esac
"$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || build_image

CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
KERNEL_CACHE="${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}"
mkdir -p "$CACHE" "$KERNEL_CACHE"
case "$PWD/" in "$ROOT"/*) WORKDIR="$PWD" ;; *) WORKDIR="$ROOT" ;; esac
args=(--rm -i --network host -v "$ROOT:$ROOT" -w "$WORKDIR" -v "$CACHE:$CACHE" -v "$KERNEL_CACHE:$KERNEL_CACHE"
      -e RHIZO_INPUT_CACHE="$CACHE" -e RHIZO_KERNEL_CACHE="$KERNEL_CACHE" -e HOME=/tmp -e TERM="${TERM:-dumb}")
[[ -n "${RUN_TESTS_DEPTH:-}" ]] && args+=(-e RUN_TESTS_DEPTH="$RUN_TESTS_DEPTH")
[[ -t 0 && -t 1 ]] && args+=(-t)
GSI_KEYS="${RHIZO_GSI_KEYS:-$HOME/.config/rhizo/gsi-keys}"
mkdir -p "$GSI_KEYS" && chmod 0700 "$GSI_KEYS"
args+=(-v "$GSI_KEYS:$GSI_KEYS" -e RHIZO_GSI_KEYS="$GSI_KEYS")
if [[ -n "${RHIZO_AOSP_DIR:-}" ]]; then
  args+=(-v "$RHIZO_AOSP_DIR:$RHIZO_AOSP_DIR" -e RHIZO_AOSP_DIR="$RHIZO_AOSP_DIR")
fi
if [[ -n "${RHIZO_AOSP_A17_DIR:-}" ]]; then
  args+=(-v "$RHIZO_AOSP_A17_DIR:$RHIZO_AOSP_A17_DIR" -e RHIZO_AOSP_A17_DIR="$RHIZO_AOSP_A17_DIR")
fi
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
MAIN="${COMMON%/.git}"
if [[ -n "$MAIN" && "$MAIN" != "$ROOT" ]]; then
  args+=(-v "$MAIN:$MAIN")
fi
PARENT="$(dirname "$ROOT")"
if [[ "$PARENT" != / && "$PARENT" != /tmp ]] && ! [[ -n "$MAIN" && "$MAIN" != "$ROOT" && "$PARENT/" == "$MAIN"/* ]]; then
  args+=(--tmpfs "$PARENT:rw,exec,mode=1777")
fi
args+=(--tmpfs "/tmp:rw,exec,mode=1777")
[[ -e /dev/kvm ]] && args+=(--device /dev/kvm)
if [[ "$(basename "$ENGINE")" == podman ]]; then
  args+=(--userns=keep-id)
else
  args+=(--user "$(id -u):$(id -g)")
fi
exec "$ENGINE" run "${args[@]}" "$IMAGE" "$@"
