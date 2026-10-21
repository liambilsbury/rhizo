#!/bin/bash
# test booting Android releases
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../../vm/image/release-map.sh

test_init version-swap
source ../lib/gsi-update-cleanup.sh

# remove the release switch state from the vm
version_swap_cleanup() {
  local out rc raw vrc left
  out=$(test_scratch_log cleanup-body)
  ssh_vm -t 90 '
    systemctl stop androidd.service
    rm -f /var/lib/rhizo/.rhizo_release_switch_pending
    sed -i -E "/^('"$GSI_UPDATE_OWNED_ENV_KEYS"')=/d" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null
    rm -f /var/lib/rhizo/data.img /var/lib/rhizo/data.img.meta
    sync
  ' > "$out" 2>&1
  rc=$?
  raw=$(ssh_vm -t 30 '
    [ -e /var/lib/rhizo/.rhizo_release_switch_pending ] && echo "release-switch-pending-present"
    [ -e /var/lib/rhizo/data.img ] && echo "data-img-present"
    grep -Eq "^('"$GSI_UPDATE_OWNED_ENV_KEYS"')=" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null && echo "owned-env-keys-present"
    exit 0
  ' 2>/dev/null)
  vrc=$?
  left=$(tr '\n' ' ' <<<"$raw" | sed 's/ *$//')
  if (( vrc != 0 )); then
    log "CLEANUP_UNVERIFIED: vm $RHIZO_VM did not answer the check (ssh rc=$vrc, body rc=$rc, see $out)"
  elif [[ -z "$left" ]]; then
    log "CLEANUP_OK: the pending switch marker, androidd.env's switch keys and the a15 /data are gone from vm $RHIZO_VM (body rc=$rc)"
  else
    log "CLEANUP_INCOMPLETE: $left (body rc=$rc, see $out) -- test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM --yes clears the marker and keys; a /data left on a15 needs RHIZO_VM=$RHIZO_VM test/vm/image/prepare-guest.sh --wipe-data"
  fi
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=version_swap_cleanup

TARGETS="a16,a15"
[[ "${1:-}" == "--targets" ]] && TARGETS="${2:-$TARGETS}"

# write the apex listing and hashes to files
_capture_data_apex_listing() {
  local prefix="$1"
  ssh_vm -t 30 'stat -c "%A %U %C %s %N" /run/rhizo/data/apex/decompressed/* /run/rhizo/data/apex/active/* 2>/dev/null' \
    | sort > "$prefix-lsZ.txt"
  ssh_vm -t 30 'sha256sum /run/rhizo/data/apex/decompressed/*.apex 2>/dev/null' \
    | sort > "$prefix-sha.txt"
}

# boot and check an Android release
run_target() {
  local name="$1"
  local gsidir="${GSI_DIR[$name]}"
  local kernel="${GSI_KERNEL[$name]}" why
  if why=$(release_retired "$name"); then
    fail "$name: $why"
    return 1
  fi
  log "==================================================================="
  step "$name: ${GSI_DESC[$name]}"
  log "==================================================================="

  export RHIZO_KERNEL="$kernel"

  RHIZO_GSI="$gsidir" RHIZO_SKIP_BOOT=0 test_boot --no-preflight || { fail "$name: boot failed, see the CAUSE= line above"; return 1; }

  local booted_kernel
  booted_kernel=$(ssh_vm -t 10 'uname -r' 2>/dev/null)
  log "  booted kernel: ${booted_kernel:-<unreadable>} (requested: ${kernel:-default})"
  echo "$name ${kernel:-default} $booted_kernel" >> "$EV/kernels.txt"

  ../../vm/sync.sh >/dev/null 2>&1 || { fail "$name: sync.sh failed"; return 1; }

  local rel
  rel=$(ssh_vm -t 20 "grep -hE '^ro\.system\.build\.version\.release=|^ro\.build\.version\.sdk=' '$gsidir/build.prop' 2>/dev/null | sort -u | tr '\n' ' '")
  log "  tree reports: ${rel:-<unreadable>}"
  echo "$name $gsidir $rel" >> "$EV/targets.txt"

  local args=(--skip-kill --boot-wait 300)
  if [[ "$name" != "a16" ]]; then
    args+=(--gsi "$gsidir" --release "$name")
  fi

  if [[ "$name" != "a16" ]] && ! ../../vm/image/stage-gsi-trees.sh "$name" > "$EV/$name-stage-tree.log" 2>&1; then
    fail "$name: its GSI tree did not stage before its data template, see $EV/$name-stage-tree.log"
    return 1
  fi

  local data_state="wiped" tmpl_key=""
  tmpl_key=$(resolve_data_template "$name" user)
  if [[ -n "$tmpl_key" ]]; then
    export RHIZO_DATA_TEMPLATE="$tmpl_key"
    data_state="template@$tmpl_key"
    log "  data template resolved: key=$tmpl_key (format=${GSI_DATA_FORMAT[$name]:-unknown})"
  else
    unset RHIZO_DATA_TEMPLATE
    fail "$name: no data template resolved on the idle guest test_boot brought up -- data-template.sh's reason is logged above"
  fi
  echo "$name $data_state" >> "$EV/data-states.txt"

  RHIZO_WIPE_DATA=1 RHIZO_RELEASE_SWITCH=1 ../../vm/redeploy.sh "${args[@]}" > "$EV/$name-redeploy.log" 2>&1
  local rdrc=$?

  local INIT
  INIT=$(guest_init_pid 15)
  if [[ -z "$INIT" ]]; then
    fail "$name: init second_stage never started (redeploy rc=$rdrc, see $EV/$name-redeploy.log)"
    return 1
  fi
  log "  init second_stage pid=$INIT"

  ssh_vm -t 30 'dmesg' > "$EV/$name-dmesg.txt" 2>&1
  local skips decompresses marker fallback activated
  skips=$(grep -ac "apexd: .*Skipping decompression" "$EV/$name-dmesg.txt" || true)
  decompresses=$(grep -ac "apexd: Decompressing" "$EV/$name-dmesg.txt" || true)
  activated=$(grep -acE "apexd: Activated [0-9]+ packages" "$EV/$name-dmesg.txt" || true)
  marker=$(grep -ac "RHIZO_MARKER data_template=" "$EV/$name-dmesg.txt" || true)
  fallback=$(grep -a "RHIZO_MARKER data_template_fallback=" "$EV/$name-dmesg.txt" || true)
  if [[ "$data_state" == template@* ]]; then
    if (( activated >= 1 )) && (( skips == 0 )) && (( decompresses == 0 )) && (( marker >= 1 )) && [[ -z "$fallback" ]]; then
      pass "$name: data template applied cleanly (apexd activated its packages with 0 skipped, 0 decompressed; marker present, no fallback)"
    else
      fail "$name: data template drift -- activated=$activated skips=$skips decompresses=$decompresses marker=$marker fallback='${fallback:-none}' (expected apexd's own 'Activated N packages' line, 0 skip, 0 decompress, marker present, no fallback) -- see $EV/$name-dmesg.txt"
    fi
  else
    skip "$name: no template was resolved for this leg, apexd-drift canary not applicable"
  fi

  local deadline=$(( $(date +%s) + 300 )) bc=""
  while (( $(date +%s) < deadline )); do
    bc=$(getprop_vm "$INIT" sys.boot_completed)
    [[ "$bc" == "1" ]] && break
    sleep 8
  done
  echo "sys.boot_completed=$bc" > "$EV/$name-boot_completed.txt"
  if [[ "$bc" == "1" ]]; then pass "$name: sys.boot_completed=1"
  else fail "$name: sys.boot_completed='$bc' after 300s"; fi

  local pkgs
  pkgs=$(ANDROID_SH_TIMEOUT=90 android_sh "$INIT" "pm list packages" 2>&1)
  echo "$pkgs" > "$EV/$name-packages.txt"
  local n
  n=$(grep -c '^package:' "$EV/$name-packages.txt" || true)
  if (( n > 0 )); then pass "$name: pm list packages -> $n real 'package:' lines"
  else fail "$name: pm list packages returned no 'package:' lines"; fi

  local ss1 ss2
  ss1=$(system_server_pid "$INIT"); sleep 20; ss2=$(system_server_pid "$INIT")
  if [[ -n "$ss1" && "$ss1" == "$ss2" ]]; then pass "$name: system_server pid stable ($ss1)"
  else fail "$name: system_server unstable ($ss1 -> $ss2)"; fi

  # test-log-window: safe -- $INIT is this target's fresh boot, captured
  logcat_vm "$INIT" -d -t 8000 > "$EV/$name-logcat-tail.txt" 2>&1
  local crashes
  crashes=$(grep -cE "$TEST_FATAL_RE" "$EV/$name-logcat-tail.txt" || true)
  if ! test_logcat_capture_read "$EV/$name-logcat-tail.txt"; then
    fail "$name: the logcat tail holds no logcat line"
  elif (( crashes == 0 )); then pass "$name: zero fatal crash signatures in logcat tail"
  else
    fail "$name: $crashes fatal crash signature(s) -- see $EV/$name-logcat-tail.txt"
    test_fatal_lines "$EV/$name-logcat-tail.txt"
  fi

  if [[ "$data_state" == template@* ]]; then
    kill_vm; boot_vm
    wait_for_boot_slot || fail "$name: equivalence template-capture boot never got a qemu slot"
    if ! wait_for_ssh 300; then
      fail "$name: equivalence template-capture guest never came back up"
    else
      RHIZO_DATA_TEMPLATE="$tmpl_key" RHIZO_DEBUG_PERMISSIVE_DOMAIN=rhizo_host RHIZO_WIPE_DATA=1 \
        RHIZO_RELEASE_SWITCH=1 ../../vm/redeploy.sh "${args[@]}" > "$EV/$name-equiv-template-redeploy.log" 2>&1
      local eq_t_rdrc=$?
      local eq_t_init eq_dl eq_bc
      eq_t_init=$(guest_init_pid 15)
      eq_dl=$(( $(date +%s) + 300 )); eq_bc=""
      while [[ -n "$eq_t_init" ]] && (( $(date +%s) < eq_dl )); do
        eq_bc=$(getprop_vm "$eq_t_init" sys.boot_completed)
        [[ "$eq_bc" == "1" ]] && break
        sleep 8
      done
      if [[ "$eq_bc" != "1" ]]; then
        fail "$name: equivalence template-capture boot never reached sys.boot_completed (redeploy rc=$eq_t_rdrc) -- see $EV/$name-equiv-template-redeploy.log"
      else
        _capture_data_apex_listing "$EV/$name-template"
        kill_vm; boot_vm
        wait_for_boot_slot || fail "$name: equivalence oracle boot never got a qemu slot"
        if ! wait_for_ssh 300; then
          fail "$name: equivalence oracle guest never came back up"
        else
          unset RHIZO_DATA_TEMPLATE
          RHIZO_DEBUG_PERMISSIVE_DOMAIN=rhizo_host RHIZO_WIPE_DATA=1 \
            RHIZO_RELEASE_SWITCH=1 ../../vm/redeploy.sh "${args[@]}" > "$EV/$name-equiv-oracle-redeploy.log" 2>&1
          local eq_o_rdrc=$?
          local eq_o_init
          eq_o_init=$(guest_init_pid 15)
          eq_dl=$(( $(date +%s) + 300 )); eq_bc=""
          while [[ -n "$eq_o_init" ]] && (( $(date +%s) < eq_dl )); do
            eq_bc=$(getprop_vm "$eq_o_init" sys.boot_completed)
            [[ "$eq_bc" == "1" ]] && break
            sleep 8
          done
          if [[ "$eq_bc" != "1" ]]; then
            fail "$name: equivalence oracle boot never reached sys.boot_completed (redeploy rc=$eq_o_rdrc) -- see $EV/$name-equiv-oracle-redeploy.log"
          else
            _capture_data_apex_listing "$EV/$name-oracle"
            local lsdiff shadiff
            lsdiff=$(diff "$EV/$name-template-lsZ.txt" "$EV/$name-oracle-lsZ.txt")
            shadiff=$(diff "$EV/$name-template-sha.txt" "$EV/$name-oracle-sha.txt")
            { echo "=== stat listing diff (mode/owner/label/size/name, template vs genuine wipe) ==="
              echo "$lsdiff"
              echo "=== sha256 diff ==="
              echo "$shadiff"
            } > "$EV/$name-equivalence-diff.txt"
            if [[ -z "$lsdiff" && -z "$shadiff" ]]; then
              pass "$name: template /data/apex is byte-identical to a genuine wipe (file set, size, mode, owner, label, sha256)"
            else
              fail "$name: template /data/apex differs from a genuine wipe -- see $EV/$name-equivalence-diff.txt"
            fi
          fi
        fi
      fi
    fi
  else
    skip "$name: no template resolved this leg -- equivalence assertion not applicable"
  fi
}

: > "$EV/targets.txt"
: > "$EV/kernels.txt"
IFS=',' read -ra order <<< "$TARGETS"
for t in "${order[@]}"; do
  release_known "$t" || { fail "unknown target '$t'"; continue; }
  run_target "$t" || true
done

log "==================================================================="
if (( FAILED )); then
  test_record_verdict FAILED
  log "VERSION-SWAP SYSTEM TEST FAILED -- evidence in $EV"
  exit 1
fi
test_record_verdict PASSED
log "VERSION-SWAP SYSTEM TEST PASSED -- evidence in $EV"
log "The same unchanged vendor side reached M1 on every target above."
exit 0
