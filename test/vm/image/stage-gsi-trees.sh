#!/bin/bash
# extract the GSI images into /srv/rhizo trees
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ./release-map.sh

FORCE=0 DERIVE_REL=0
targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --derive-rel) DERIVE_REL=1; shift ;;
    *) targets+=("$1"); shift ;;
  esac
done
(( ${#targets[@]} )) || targets=("${RELEASE_LABELS[@]}")

for r in "${targets[@]}"; do
  release_known "$r" || { log "stage-gsi-trees: unknown release '$r' -- known: ${RELEASE_LABELS[*]}"; exit 2; }
done

if ! wait_for_ssh 30 >/dev/null 2>&1; then
  log "stage-gsi-trees: vm $RHIZO_VM is not reachable"
  exit 2
fi

if [[ "$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null')" == 1 ]]; then
  log "stage-gsi-trees: vm $RHIZO_VM is already enforcing"
  log "  redeploy.sh's staging step stages the trees on its new, permissive boot"
  log "  to stage here: RHIZO_VM=$RHIZO_VM test/vm/redeploy.sh --no-launch, then re-run this script"
  exit 1
fi

if ! guest_mount_share 60; then
  log "stage-gsi-trees: the 9p share is not mounted at /root/share on vm $RHIZO_VM"
  exit 1
fi

# derive a release's patched stock files into var/share/rel
derive_rel() {
  local r="$1" tree="$2" dest="$VAR_DIR/share/rel/$1" out f l
  local -a names
  out=$(ssh_vm -t 300 "r='$r'; t='$tree'; "'
    o=/root/rel-$r
    rm -rf "$o"
    bash /root/share/derive-patches.sh "$r" --from-tree "$t" --out "$o" > "$o.log" 2>&1
    echo "DERIVE_RC=$?"
    tail -n 20 "$o.log" | sed "s/^/DERIVE_LOG /"
    for f in "$o"/*; do [ -f "$f" ] && echo "DERIVED ${f##*/}"; done
  ' 2>&1 | tr -d '\r')
  if [[ "$(sed -n 's/^DERIVE_RC=//p' <<<"$out")" != 0 ]]; then
    log "  derive-patches.sh did not finish for $r on vm $RHIZO_VM:"
    while IFS= read -r l; do log "    $l"; done < <(sed -n 's/^DERIVE_LOG //p' <<<"$out")
    grep -q '^DERIVE_RC=' <<<"$out" || log "    ${out:-<no output>}"
    return 1
  fi
  mapfile -t names < <(sed -n 's/^DERIVED //p' <<<"$out")
  (( ${#names[@]} )) || { log "  derive-patches.sh wrote no file for $r"; return 1; }
  mkdir -p "$dest" || return 1
  for f in "${names[@]}"; do
    if ! timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:/root/rel-$r/$f" "$dest/.$f.part" \
       || ! mv -f "$dest/.$f.part" "$dest/$f"; then
      rm -f "$dest/.$f.part"
      log "  could not copy /root/rel-$r/$f back from vm $RHIZO_VM"
      return 1
    fi
  done
  log "  derived ${#names[@]} files into var/share/rel/$r: ${names[*]}"
}

FAILED=0
for r in "${targets[@]}"; do
  tree="${GSI_DIR[$r]}"
  img="/root/share/${GSI_IMG[$r]}"
  log "=== $r: $img -> $tree"
  out=$(ssh_vm -t 1200 "t='$tree'; i='$img'; f='$FORCE'; need='$RHIZO_GSI_STAGE_SPACE_KB'; "'
    set -e
    if [ "$f" != 1 ] && [ -x "$t/bin/init" ]; then echo TREE_ALREADY_OK; exit 0; fi
    test -f "$i" || { echo "NO_IMAGE $i"; exit 1; }
    avail=$(df -k --output=avail /srv 2>/dev/null | tail -1 | tr -d " ")
    [ "${avail:-0}" -ge "$need" ] || { echo "LOW_SPACE ${avail}k available under /srv, need ${need}k"; exit 1; }
    mkdir -p /srv/rhizo /mnt/gsi_src
    mountpoint -q /mnt/gsi_src && umount /mnt/gsi_src
    mount -o ro,loop "$i" /mnt/gsi_src
    rm -rf "$t.part"
    cp -a /mnt/gsi_src/system "$t.part"
    umount /mnt/gsi_src
    rm -rf "$t"
    mv "$t.part" "$t"
    test -x "$t/bin/init" || { echo "NO_INIT after staging"; exit 1; }
    sync
    echo TREE_STAGED
' 2>&1 | tr -d '\r')
  case "$out" in
    *TREE_ALREADY_OK*) log "  already staged (pass --force to redo it)" ;;
    *TREE_STAGED*)     log "  staged" ;;
    *)                 log "  FAILED: ${out:-<no output>}"; FAILED=1; continue ;;
  esac
  (( DERIVE_REL )) && { derive_rel "$r" "$tree" || FAILED=1; }
done

if (( FAILED )); then
  log "stage-gsi-trees: at least one tree did not stage, or its share/rel files did not derive"
  exit 1
fi
log "stage-gsi-trees: every requested tree is in place"
exit 0
