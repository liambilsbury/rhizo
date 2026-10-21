#!/bin/bash
# print the presented frame count for a display
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
INIT="${1:?init pid}"; CID="${2:?composer display id}"; FIELD="${3:-presented}"
case "$FIELD" in
  presented|presents) ;;
  *) echo "presented-count.sh: field must be 'presented' or 'presents', got '$FIELD'" >&2; exit 2 ;;
esac
before=$(rhizo_ctl_out "$INIT" | grep -c "display stats id=$CID ")
rhizo_ctl "$INIT" "display stats $CID" >/dev/null || exit 1
for _ in $(seq 1 20); do
  out=$(rhizo_ctl_out "$INIT")
  if (( $(grep -c "display stats id=$CID " <<<"$out") > before )); then
    grep -oE "display stats id=$CID .*" <<<"$out" | tail -1 \
      | grep -oE " $FIELD=[0-9]+" | tail -1 | grep -oE "[0-9]+$"
    exit 0
  fi
  sleep 0.2
done
echo "presented-count.sh: no stats reply for display $CID within 4s" >&2
exit 1
