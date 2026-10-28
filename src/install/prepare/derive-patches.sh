#!/bin/bash
# derive stock file patches for a GSI release
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

LABEL="" FROM_TREE="" OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-tree) FROM_TREE="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    -*) echo "usage: $0 <a15|a16|a17> | --from-tree DIR --out DIR" >&2; exit 2 ;;
    *) LABEL="$1"; shift ;;
  esac
done

if [[ -n "$FROM_TREE" ]]; then
  [[ -n "$OUT_DIR" ]] || { echo "--from-tree needs --out DIR" >&2; exit 2; }
  log() { echo "[derive-patches] $*" >&2; }
  [[ -d "$FROM_TREE" ]] || { log "FAIL: no tree at $FROM_TREE"; exit 1; }
  LABEL="${LABEL:-a16}"
  OUT="$OUT_DIR"
  mkdir -p "$OUT" || { log "FAIL: cannot create $OUT"; exit 1; }
  ROOT="$FROM_TREE"
  [[ -d "$ROOT/etc/init" ]] || ROOT="$FROM_TREE/system"
else
  source ../../../tools/env.sh
  [[ -z "$LABEL" ]] && { echo "usage: $0 <a15|a16|a17> | --from-tree DIR --out DIR" >&2; exit 2; }
  IMG="$VAR_DIR/share/gsi_$LABEL.img"
  [[ -f "$IMG" ]] || { [[ "$LABEL" == a16 ]] && IMG="$VAR_DIR/gsi/system.img"; }
  [[ -f "$IMG" ]] || { log "FAIL: no image for '$LABEL' -- run tools/fetch-gsi.sh $LABEL first"; exit 1; }
  OUT="$VAR_DIR/share/rel/$LABEL"
  mkdir -p "$OUT"
  M=$(mktemp -d)
  cleanup() { sudo umount "$M" 2>/dev/null; rmdir "$M" 2>/dev/null; }
  trap cleanup EXIT
  sudo mount -o ro,loop "$IMG" "$M" || { log "FAIL: cannot mount $IMG"; exit 1; }
  ROOT="$M/system"; [[ -d "$ROOT/etc/init" ]] || ROOT="$M"
fi

miss=0
SUDO=sudo
(( EUID == 0 )) && SUDO=""
# copy a stock file into the output directory
grab() {
  local src="$ROOT/$1" dst="$OUT/$2"
  if [[ ! -f "$src" ]]; then log "  MISSING in $LABEL: $1"; miss=1; return 1; fi
  if ! $SUDO cp "$src" "$dst"; then
    log "  MISSING in $LABEL: $1 (unreadable: $src)"; miss=1; return 1
  fi
  $SUDO chown "$(id -u):$(id -g)" "$dst"
  return 0
}

# comment out onrestart zygote lines in a file
kill_cascade() {
  sed -i -E 's|^([[:space:]]*)(onrestart restart (--only-if-running )?zygote.*)$|\1# DISABLED by rhizo (M7 derive-patches.sh): \2|' "$1"
}

# comment out reboot_on_failure lines in a file
kill_reboot_on_failure() {
  sed -i -E 's|^([[:space:]]*)(reboot_on_failure .*)$|\1# DISABLED by rhizo (M7 derive-patches.sh): \2|' "$1"
}

# insert disabled into a service
disable_service() {
  sed -i -E '0,/^[[:space:]]*class /{s|^([[:space:]]*class .*)$|\1\n    disabled|}' "$1"
}

# append the config.disable_ properties to a file
append_disable_props() {
  cat config-disable.prop >> "$1"
}

log "=== deriving $LABEL patches from its own stock files"

if grab etc/init/netd.rc netd.rc; then
  if grep -qE '^\s*capabilities .*\bBPF\b' "$OUT/netd.rc"; then
    log "  netd.rc: already grants BPF"
  else
    sed -i -E 's|^([[:space:]]*capabilities .*[^[:space:]])$|\1 BPF|' "$OUT/netd.rc"
    grep -qE '^\s*capabilities .*\bBPF\b' "$OUT/netd.rc" \
      && log "  netd.rc: +BPF capability" || { log "  netd.rc: FAILED to add BPF"; miss=1; }
  fi
  kill_cascade "$OUT/netd.rc"
fi

grab etc/init/surfaceflinger.rc surfaceflinger.rc && kill_cascade "$OUT/surfaceflinger.rc"

grab etc/init/vold.rc vold.rc

# comment out the reboot bootloader exec line
kill_vndk_reboot() {
  sed -i -E 's|^([[:space:]]*)(exec .*/system/bin/reboot.*)$|\1# DISABLED by rhizo (derive-patches.sh): \2|' "$1"
}
if grab system_ext/etc/gsi/init.vndk-nodef.rc init.vndk-nodef.rc; then
  kill_vndk_reboot "$OUT/init.vndk-nodef.rc"
  grep -q 'DISABLED by rhizo' "$OUT/init.vndk-nodef.rc" \
    && log "  init.vndk-nodef.rc: reboot exec disabled" \
    || { log "  init.vndk-nodef.rc: exec line NOT FOUND -- stock content changed"; miss=1; }
fi

for svc in cameraserver wificond; do
  if [[ -f "$ROOT/etc/init/$svc.rc" ]]; then
    grab "etc/init/$svc.rc" "$svc.rc" && disable_service "$OUT/$svc.rc"
    rm -f "$OUT/system_ext-$svc.rc"
  elif [[ -f "$ROOT/system_ext/etc/init/$svc.rc" ]]; then
    grab "system_ext/etc/init/$svc.rc" "system_ext-$svc.rc" && disable_service "$OUT/system_ext-$svc.rc"
    rm -f "$OUT/$svc.rc"
  else
    log "  $svc.rc: absent in $LABEL, nothing to disable"
    rm -f "$OUT/$svc.rc" "$OUT/system_ext-$svc.rc"
  fi
done

grab product/etc/build.prop product-build.prop && append_disable_props "$OUT/product-build.prop"

# patch audioserver.rc for the rhizo audio hal
derive_audioserver_rc() {
  local f="$1"
  sed -i -E '/^[[:space:]]*#/d' "$f"
  sed -i -E '0,/^[[:space:]]*class core$/{s|^([[:space:]]*)class core$|\1class main\n\1stdio_to_kmsg|}' "$f"
  sed -i -E 's|^([[:space:]]*group audio camera drmrpc media mediadrm net_bt net_bt_admin net_bw_acct) wakelock$|\1 net_bw_stats net_raw system|' "$f"
  sed -i -E 's|^([[:space:]]*)(onrestart restart\|stop\|start) audio_?proxy_service$|&\n\1\2 vendor.rhizo-audio-core|' "$f"
  grep -qx '    class main' "$f" && grep -qx '    stdio_to_kmsg' "$f" && grep -q ' net_raw system$' "$f" \
    && [[ $(grep -c 'vendor.rhizo-audio-core$' "$f") -eq 6 ]]
}
# move mediametrics.rc to class core
derive_mediametrics_rc() {
  sed -i -E '0,/^[[:space:]]*class main$/{s|^([[:space:]]*)class main$|\1class core|}' "$1"
  grep -qx '    class core' "$1"
}
if [[ "$LABEL" == a16 || "$LABEL" == a17 || "$LABEL" == a15 ]]; then
  if grab etc/init/audioserver.rc audioserver.rc; then
    derive_audioserver_rc "$OUT/audioserver.rc" && log "  audioserver.rc: class main, audio HAL restarts" \
      || { log "  audioserver.rc: an edit did not apply -- stock content changed"; miss=1; }
  fi
  if grab etc/init/mediametrics.rc mediametrics.rc; then
    derive_mediametrics_rc "$OUT/mediametrics.rc" && log "  mediametrics.rc: class core" \
      || { log "  mediametrics.rc: class main NOT FOUND -- stock content changed"; miss=1; }
  fi
fi

for z in init.zygote64.rc init.zygote64_32.rc; do
  if grab "etc/init/hw/$z" "$z"; then
    kill_cascade "$OUT/$z"
    if [[ "$z" == init.zygote64.rc ]] && ! grep -q 'stdio_to_kmsg' "$OUT/$z"; then
      sed -i -E '0,/^service /{s|^(service .*)$|\1\n    stdio_to_kmsg|}' "$OUT/$z"
    fi
  fi
done

echo >&2
for f in "$OUT"/*.rc; do [[ -e "$f" ]] && kill_reboot_on_failure "$f"; done

log "derived into $OUT:"
for f in "$OUT"/*.rc; do
  [[ -e "$f" ]] || continue
  n=$(grep -c 'DISABLED by rhizo' "$f")
  log "  $(basename "$f")  (${n} hazardous line(s) disabled)"
done
for f in "$OUT"/*.prop; do
  [[ -e "$f" ]] || continue
  n=$(grep -c '^config\.disable_' "$f")
  log "  $(basename "$f")  (${n} config.disable_* line(s) appended)"
done
(( miss )) && { log "WARNING: some stock files were missing -- see above"; exit 1; }

if [[ "$LABEL" == a16 && -z "$FROM_TREE" ]]; then
  for f in "$OUT"/*.rc "$OUT"/product-build.prop; do
    [[ -e "$f" ]] || continue
    cp --remove-destination "$f" "$VAR_DIR/share/$(basename "$f")"
  done
  log "synced share/rel/a16 -> share/ (the plain-boot baseline)"
fi

log "OK"
