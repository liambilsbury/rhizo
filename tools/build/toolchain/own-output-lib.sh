#!/bin/bash
# refuse a toolchain output folder that resolves into another checkout

# refuse an output folder that resolves outside this checkout
own_output() {
  local top d real link
  top=$(realpath -m "$REPO_ROOT")
  for d in "$@"; do
    real=$(realpath -m "$d")
    [[ "$real" == "$top"/* ]] && continue
    link="$d"
    while [[ "$link" != "$REPO_ROOT" && "$link" != / && ! -L "$link" ]]; do link=$(dirname "$link"); done
    log "${d#"$REPO_ROOT"/} resolves to $real, outside this checkout -- build it there, or give this checkout its own: rm ${link#"$REPO_ROOT"/} && cp -a --reflink=auto $(realpath -m "$link") ${link#"$REPO_ROOT"/}"
    return 1
  done
}
