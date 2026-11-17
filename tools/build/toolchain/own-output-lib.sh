#!/bin/bash
# own_output() check for toolchain output folders outside REPO_ROOT

# return 1 for an output folder that resolves outside REPO_ROOT
own_output() {
  local top d real link
  top=$(realpath -m "$REPO_ROOT")
  for d in "$@"; do
    real=$(realpath -m "$d")
    [[ "$real" == "$top"/* ]] && continue
    link="$d"
    while [[ "$link" != "$REPO_ROOT" && "$link" != / && ! -L "$link" ]]; do link=$(dirname "$link"); done
    log "${d#"$REPO_ROOT"/} resolves to $real outside $REPO_ROOT through the link ${link#"$REPO_ROOT"/}"
    return 1
  done
}
