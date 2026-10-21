#!/bin/bash

# test the GSI update from a15 to a16
lc_assert_gsi.update() {
  lc_need_guest gsi.update || return 1
  _lc_step_passed 6.gsi-update-leg \
    || { fail "gsi.update: step 6's 6.gsi-update-leg did not pass"; return 1; }
  [[ "$LC_GSI_ARM_STATUS" == "RHIZO_GSI_UPDATE current=a15 candidate=a16 tries=3 previous=-" ]] \
    || { fail "gsi.update: the a15->a16 arm line was '${LC_GSI_ARM_STATUS:-<not recorded -- step 6 did not run>}', want current=a15 candidate=a16 tries=3 previous=-"; return 1; }
  [[ "$LC_GSI_CONFIRM_STATUS" == "RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=a15" ]] \
    && pass "gsi.update: gsi_leg_update armed and confirmed the a15->a16 trial exactly (arm: $LC_GSI_ARM_STATUS; confirm: $LC_GSI_CONFIRM_STATUS)" \
    || { fail "gsi.update: the confirm line was '${LC_GSI_CONFIRM_STATUS:-<not recorded>}', want current=a16 candidate=- tries=- previous=a15"; return 1; }
}

# assert the manual rollback returned to a15
lc_assert_gsi.manual-rollback() {
  lc_need_guest gsi.manual-rollback || return 1
  local bad=""
  [[ "$LC_GSI_ROLLBACK_STATUS" == "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-" ]] \
    || bad+="status after manual rollback was '${LC_GSI_ROLLBACK_STATUS:-<not recorded>}' (want current=a15 candidate=- tries=- previous=-); "
  [[ "$LC_GSI_ROLLBACK_DATA_RELEASE_OK" == 1 ]] \
    || bad+="no RHIZO_MARKER data_release=a15 seen on the rolled-back boot (LC_GSI_ROLLBACK_DATA_RELEASE_OK=${LC_GSI_ROLLBACK_DATA_RELEASE_OK:-<not recorded>}); "
  [[ -z "$bad" ]] \
    && pass "gsi.manual-rollback: gsi_leg_manual_rollback returned to current=a15 with /data's own release marker reading a15" \
    || { fail "gsi.manual-rollback: $bad"; return 1; }
}

# assert the exhausted trial rolled back to a15
lc_assert_gsi.automatic-rollback() {
  lc_need_guest gsi.automatic-rollback || return 1
  local bad=""
  [[ "$LC_GSI_EXHAUST_TRIES_STATUS" == "RHIZO_GSI_UPDATE current=a15 candidate=a16 tries=0 previous=-" ]] \
    || bad+="tries-exhausted status was '${LC_GSI_EXHAUST_TRIES_STATUS:-<not recorded>}' (want current=a15 candidate=a16 tries=0 previous=-); "
  [[ "$LC_GSI_AUTOROLLBACK_MARKER_SEEN" == 1 ]] \
    || bad+="no RHIZO_MARKER gsi_update_rolled_back=a16-to-a15 seen in rhizo-update-begin.service's journal; "
  [[ "$LC_GSI_EXHAUST_FINAL_STATUS" == "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-" ]] \
    || bad+="final status was '${LC_GSI_EXHAUST_FINAL_STATUS:-<not recorded>}' (want current=a15 candidate=- tries=- previous=-); "
  [[ -z "$bad" ]] \
    && pass "gsi.automatic-rollback: gsi_leg_exhaustion rolled back on its own -- tries=0 then gsi_update_rolled_back=a16-to-a15 then current=a15, nobody ran a rollback command" \
    || { fail "gsi.automatic-rollback: $bad"; return 1; }
}

# test a GSI fetch failure
lc_assert_gsi.refused-fetch() {
  lc_need_guest gsi.refused-fetch || return 1
  local bad=""
  [[ "$LC_GSI_REFUSED_SHA_MISMATCH" == 1 ]] \
    || bad+="no RHIZO_GSI_FAILED reason=sha256-mismatch from the real fetch script (LC_GSI_REFUSED_SHA_MISMATCH=${LC_GSI_REFUSED_SHA_MISMATCH:-<not recorded>}); "
  [[ "$LC_GSI_REFUSED_LAST" == "RHIZO_GSI_UPDATE_FAILED reason=fetch" ]] \
    || bad+="a broken RHIZO_FETCH_GSI printed '${LC_GSI_REFUSED_LAST:-<not recorded>}' (want RHIZO_GSI_UPDATE_FAILED reason=fetch); "
  if [[ -z "$LC_GSI_REFUSED_STATUS_BEFORE" || -z "$LC_GSI_REFUSED_STATUS_AFTER" ]]; then
    bad+="could not read gsi status on one side of the refused fetch (before='${LC_GSI_REFUSED_STATUS_BEFORE:-}' after='${LC_GSI_REFUSED_STATUS_AFTER:-}'); "
  elif [[ "$LC_GSI_REFUSED_STATUS_BEFORE" != "$LC_GSI_REFUSED_STATUS_AFTER" ]]; then
    bad+="gsi status changed after a refused fetch (before='$LC_GSI_REFUSED_STATUS_BEFORE' after='$LC_GSI_REFUSED_STATUS_AFTER'); "
  fi
  [[ -z "$bad" ]] \
    && pass "gsi.refused-fetch: a broken fetch refused cleanly (RHIZO_GSI_UPDATE_FAILED reason=fetch) and left gsi status unchanged ($LC_GSI_REFUSED_STATUS_AFTER)" \
    || { fail "gsi.refused-fetch: $bad"; return 1; }
}

# test the prepare of release a15
lc_assert_gsi.prepare-release() {
  lc_need_guest gsi.prepare-release || return 1
  [[ "$LC_GSI_PREPARE_LINE" == "RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=a15" ]] \
    || { fail "gsi.prepare-release: rhizo prepare --release a15 --wipe-data printed '${LC_GSI_PREPARE_LINE:-<not recorded -- step 6 did not run>}', want RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=a15"; return 1; }
  _lc_step_passed 6.prepare-a15 \
    && pass "gsi.prepare-release: rhizo prepare deferred a15 to the reboot, whose setup prepared it on a new /data and booted it ($LC_GSI_PREPARE_LINE)" \
    || { fail "gsi.prepare-release: step 6's 6.prepare-a15 did not pass"; return 1; }
}

# test app data across the GSI update
lc_assert_gsi.app-survives() {
  lc_need_guest gsi.app-survives || return 1
  [[ "$LC_GSI_PLANTED_ON" == a15 ]] \
    || { fail "gsi.app-survives: the fixture was planted on '${LC_GSI_PLANTED_ON:-<not planted>}', want a15"; return 1; }
  _lc_step_passed 6.gsi-update-leg \
    || { fail "gsi.app-survives: step 6's 6.gsi-update-leg did not pass"; return 1; }
  [[ -n "$LC_GSI_DATA_TOKEN" ]] \
    || { fail "gsi.app-survives: step 6 recorded no data value planted in a15's /data"; return 1; }
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "gsi.app-survives: no sandbox init pid after the GSI update/rollback legs"; return 1; }
  [[ -n "$DESKAPP_PKG" ]] || { fail "gsi.app-survives: no DESKAPP_PKG from step 2's fixture plant"; return 1; }
  # shellcheck disable=SC2034
  INIT="$init"
  declare -F assert_booted_release >/dev/null 2>&1 \
    || { fail "gsi.app-survives: assert_booted_release (gsi-update-lib.sh) is not sourced"; return 1; }
  local before=$FAILED
  assert_booted_release a16 "${GSI_DIR[a16]}"
  (( FAILED == before )) || return 1
  if declare -F pkg_installed >/dev/null 2>&1; then
    pkg_installed gsi.app-survives "$init" "$DESKAPP_PKG" \
      || { fail "gsi.app-survives: $DESKAPP_PKG is gone from pm list packages after the GSI update/rollback legs"; return 1; }
  else
    local pkgs; pkgs=$(android_sh "$init" "pm list packages")
    grep -qx "package:$DESKAPP_PKG" <<<"$pkgs" \
      || { fail "gsi.app-survives: $DESKAPP_PKG is gone from pm list packages after the GSI update/rollback legs"; return 1; }
  fi
  local got
  got=$(android_sh "$init" "settings get global $LC_GSI_DATA_KEY" | tr -d '[:space:]')
  [[ "$got" == "$LC_GSI_DATA_TOKEN" ]] \
    || { fail "gsi.app-survives: settings get global $LC_GSI_DATA_KEY on a16 reads '${got:-<empty>}', want '$LC_GSI_DATA_TOKEN' planted in a15's /data"; return 1; }
  if declare -F assert_deskapp_launches >/dev/null 2>&1; then
    assert_deskapp_launches "gsi.app-survives"
    (( FAILED == before )) || return 1
    pass "gsi.app-survives: on a16, $DESKAPP_PKG is installed and launches, and a15's $LC_GSI_DATA_KEY=$LC_GSI_DATA_TOKEN reads back unchanged"
    return 0
  fi
  fail "gsi.app-survives: assert_deskapp_launches (gsi-update-lib.sh) is not sourced"
  return 1
}
