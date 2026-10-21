#!/bin/bash
# build plat_pub_versioned.cil into var/share
set -euo pipefail

# print a prefixed progress line
log() { echo "[plat-pub-versioned] $*" >&2; }

OUT=""
case "${1:-}" in
  "") ;;
  --out) [[ $# -eq 2 ]] || { echo "usage: $0 [--out FILE]" >&2; exit 2; }; OUT="$(realpath -m -- "$2")" ;;
  *) echo "usage: $0 [--out FILE]" >&2; exit 2 ;;
esac
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(pwd)"
OUT="${OUT:-$ROOT/var/share/plat_pub_versioned.cil}"
[[ -d "$ROOT/aosp-android16-qpr2" ]] || { log "ERROR: no aosp-android16-qpr2/ checkout in $ROOT"; exit 1; }
AOSP_DIR="$(cd "$ROOT/aosp-android16-qpr2" && pwd)"
SEPOLICY="$AOSP_DIR/system/sepolicy"
PUBLIC="$SEPOLICY/prebuilts/api/202404/public"
REQD_MASK="$SEPOLICY/reqd_mask"
M4="$AOSP_DIR/prebuilts/build-tools/linux-x86/bin/m4"
HOST_BIN="$AOSP_DIR/out/host/linux-x86/bin"
J="${RHIZO_BUILD_J:-18}"

[[ -d "$PUBLIC" && -d "$REQD_MASK" ]] || { log "ERROR: $AOSP_DIR has no system/sepolicy 202404 prebuilts"; exit 1; }
[[ -x "$M4" ]] || { log "ERROR: no m4 at $M4"; exit 1; }

M4_DEFS=(
  -D mls_num_sens=1 -D mls_num_cats=1024 -D target_arch=x86_64
  -D target_with_asan=false -D target_with_dexpreopt=true
  -D target_with_native_coverage=false -D target_build_variant=user
  -D target_full_treble=true -D target_compatible_property=true
  -D target_treble_sysprop_neverallow=true -D target_enforce_sysprop_owner=true
  -D target_exclude_build_test=false
  -D target_requires_insecure_execmem_for_swiftshader=false
  -D target_enforce_debugfs_restriction=true -D target_recovery=false
  -D target_board_api_level=202404
  -D target_flag_RELEASE_AVF_ENABLE_DEVICE_ASSIGNMENT=true
  -D target_flag_RELEASE_AVF_ENABLE_EARLY_VM=true
  -D target_flag_RELEASE_AVF_ENABLE_LLPVM_CHANGES=true
  -D target_flag_RELEASE_AVF_ENABLE_MICROFUCHSIA=
  -D target_flag_RELEASE_AVF_ENABLE_NETWORK=true
  -D target_flag_RELEASE_AVF_ENABLE_VM_TO_TEE_SERVICES_ALLOWLIST=true
  -D target_flag_RELEASE_AVF_ENABLE_WIDEVINE_PVM=true
  -D target_flag_RELEASE_AVF_SUPPORT_CUSTOM_VM_WITH_PARAVIRTUALIZED_DEVICES=true
  -D target_flag_RELEASE_BLUETOOTH_SOCKET_SERVICE=
  -D target_flag_RELEASE_HARDWARE_BLUETOOTH_RANGING_SERVICE=true
  -D target_flag_RELEASE_RANGING_STACK=true
  -D target_flag_RELEASE_READ_FROM_NEW_STORAGE=true
  -D target_flag_RELEASE_SEPOLICY_RESTRICT_KERNEL_KEYRING_SEARCH=
  -D target_flag_RELEASE_SUPERVISION_SERVICE=true
  -D target_flag_RELEASE_TELEPHONY_MODULE=
  -D target_flag_RELEASE_UNLOCKED_STORAGE_API=
)

PUBLIC_TE_ORDER=(
  hal_drm.te modprobe.te webview_zygote.te hal_codec2.te hal_keymaster.te postinstall.te
  recovery.te nfc.te shared_relro.te hal_remoteaccess.te hal_uwb.te hal_graphics_composer.te
  logd.te fastbootd.te hal_graphics_allocator.te toolbox.te hal_usb.te lmkd.te
  flags_health_check.te watchdogd.te fsck.te extra_free_kbytes.te healthd.te gmscore_app.te
  system_suspend_internal_server.te update_engine.te hal_memtrack.te dumpstate.te vndservicemanager.te display_service_server.te
  hal_nlinterceptor.te tee.te cameraserver.te evsmanagerd.te hwservice.te priv_app.te
  virtual_touchpad.te hal_usb_gadget.te app.te ppp.te hal_tetheroffload.te hal_face.te
  uncrypt.te gpuservice.te hal_ivn.te netutils_wrapper.te mtp.te system_suspend_server.te
  usbd.te profman.te perfetto.te rs.te network_stack.te bluetooth.te
  prng_seeder.te rootdisk_sysdev.te hal_secure_element.te hal_neverallows.te hal_cas.te hal_input_processor.te
  netd.te isolated_compute_app.te hal_gatekeeper.te inputflinger.te sdcardd.te incidentd.te
  bufferhubd.te vendor_modprobe.te hal_bootctl.te hal_vehicle.te gatekeeperd.te keystore.te
  logpersist.te artd.te hal_vr.te hal_can.te fsck_untrusted.te runas_app.te
  hal_tv_tuner.te hal_allocator.te hal_keymint.te hal_weaver.te runas.te heapprofd.te
  secure_element.te hal_authsecret.te audioserver.te zygote.te statsd.te hal_vibrator.te
  hal_input_classifier.te shell.te mediaprovider.te stats_service_server.te hal_macsec.te hal_ir.te
  adbd.te system_server.te ephemeral_app.te blkid.te hal_dumpstate.te hal_tv_hdmi_cec.te
  radio.te rkpd_app.te traced.te surfaceflinger.te simpleperf_app_runner.te domain.te
  recovery_persist.te userdata_sysdev.te hal_omx.te dhcp.te hal_confirmationui.te installd.te
  keystore_keys.te hal_atrace.te vdc.te fingerprintd.te performanced.te vold_prepare_subdirs.te
  crash_dump.te bpfloader.te scheduler_service_server.te hal_health_storage.te servicemanager.te charger_type.te
  camera_service_server.te mediaserver.te app_zygote.te mdnsd.te rss_hwm_reset.te su.te
  mediatranscoding.te charger.te hal_neuralnetworks.te hal_audio.te hal_secretkeeper.te hal_rebootescrow.te
  hal_fastboot.te mediaswcodec.te system_app.te hal_broadcastradio.te vendor_toolbox.te service.te
  vendor_init.te file.te hal_bluetooth.te hal_oemlock.te hal_thermal.te hal_contexthub.te
  hal_tv_cec.te hal_tv_hdmi_earc.te kernel.te hal_fingerprint.te hal_sensors.te hal_power.te
  update_engine_common.te hwservicemanager.te net.te ueventd.te incident_helper.te hal_tv_hdmi_connection.te
  mediadrmserver.te update_verifier.te property.te atrace.te device.te platform_app.te
  hal_lowpan.te hal_wifi_supplicant.te mediametrics.te drmserver.te hal_nfc.te e2fs.te
  otapreopt_chroot.te hal_threadnetwork.te wificond.te aidl_lazy_test_server.te traced_probes.te traced_perf.te
  hal_power_stats.te hal_gnss.te dnsmasq.te init.te tombstoned.te remote_provisioning_service_server.te
  mediaextractor.te hal_wifi_hostapd.te hal_identity.te bootstat.te hal_authgraph.te hal_configstore.te
  traceur_app.te hal_remotelyprovisionedcomponent_avf.te hal_telephony.te apexd.te vold.te blkid_untrusted.te
  hal_tv_input.te hal_health.te slideshow.te incident.te hal_camera.te hal_evs.te
  vendor_shell.te untrusted_app.te charger_vendor.te hal_audiocontrol.te sgdisk.te vndservice.te
  hal_wifi.te bootanim.te isolated_app.te recovery_refresh.te simpleperf.te hal_light.te
  sensor_service_server.te vendor_misc_writer.te credstore.te idmap.te llkd.te asan_extract.te
)

# build checkpolicy, version_policy and build_sepolicy into out/host
build_tools() {
  log "building checkpolicy version_policy build_sepolicy (lunch aosp_x86_64 bp2a userdebug, -j$J) ..."
  ( set +u
    cd "$AOSP_DIR"
    source build/envsetup.sh >/dev/null
    lunch aosp_x86_64 bp2a userdebug >/dev/null
    m -j"$J" checkpolicy version_policy build_sepolicy
  ) >&2 || { log "ERROR: soong could not build the sepolicy host tools"; return 1; }
  local t
  for t in checkpolicy version_policy build_sepolicy; do
    [[ -x "$HOST_BIN/$t" ]] || { log "ERROR: no $HOST_BIN/$t after the build"; return 1; }
  done
}

# check the public .te set against PUBLIC_TE_ORDER
check_te_order() {
  local want have
  want=$(printf '%s\n' "${PUBLIC_TE_ORDER[@]}" | sort)
  have=$(cd "$PUBLIC" && ls -- *.te | sort)
  [[ "$want" == "$have" ]] || {
    log "ERROR: PUBLIC_TE_ORDER does not list exactly $PUBLIC/*.te:"
    diff <(echo "$want") <(echo "$have") | sed 's/^/    /' >&2
    return 1
  }
}

# trim reqd_mask/access_vectors to the CTS 16.1_r4 permissions
trim_access_vectors() {
  local src=$1 dst=$2 dropped
  awk '
    /^common cap2$/ { in_cap2 = 1 }
    /^class netlink_(route|tcpdiag|xfrm|audit)_socket$/ { in_nl = 1 }
    /^}/ { in_cap2 = 0; in_nl = 0 }
    in_cap2 && /^[ \t]*(checkpoint_restore|bpf)[ \t]*$/ { next }
    in_nl && /^[ \t]*nlmsg[ \t]*$/ { next }
    { print }
  ' "$src" > "$dst"
  dropped=$(( $(wc -l < "$src") - $(wc -l < "$dst") ))
  (( dropped == 6 )) || { log "ERROR: the trim dropped $dropped lines of $src, expected 6"; return 1; }
}

check_te_order
build_tools
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trim_access_vectors "$REQD_MASK/access_vectors" "$WORK/access_vectors"

TES=()
for f in "${PUBLIC_TE_ORDER[@]}"; do TES+=("$PUBLIC/$f"); done

log "m4 -> 202404_reqd_policy_mask.conf, 202404_plat_pub_policy.conf"
"$M4" --fatal-warnings "${M4_DEFS[@]}" -s \
  "$SEPOLICY/flagging/flagging_macros" "$REQD_MASK/security_classes" \
  "$REQD_MASK/initial_sids" "$WORK/access_vectors" \
  "$REQD_MASK/mls_macros" "$REQD_MASK/mls_decl" "$REQD_MASK/mls" \
  "$REQD_MASK/reqd_mask.te" "$REQD_MASK/roles_decl" "$REQD_MASK/roles" \
  "$REQD_MASK/users" "$REQD_MASK/initial_sid_contexts" \
  > "$WORK/reqd_policy_mask.conf"
"$M4" --fatal-warnings "${M4_DEFS[@]}" -s \
  "$SEPOLICY/flagging/flagging_macros" "$REQD_MASK/security_classes" \
  "$REQD_MASK/initial_sids" "$WORK/access_vectors" \
  "$PUBLIC/global_macros" "$PUBLIC/neverallow_macros" \
  "$REQD_MASK/mls_macros" "$REQD_MASK/mls_decl" "$REQD_MASK/mls" \
  "$PUBLIC/te_macros" "$PUBLIC/ioctl_defines" "$PUBLIC/ioctl_macros" \
  "$PUBLIC/attributes" "${TES[@]}" "$REQD_MASK/reqd_mask.te" \
  "$REQD_MASK/roles_decl" "$PUBLIC/roles" "$REQD_MASK/roles" \
  "$REQD_MASK/users" "$REQD_MASK/initial_sid_contexts" \
  > "$WORK/plat_pub_policy.conf"

log "checkpolicy -> CIL, filter out the reqd_mask-only part"
"$HOST_BIN/checkpolicy" -C -M -L -c 30 -o "$WORK/reqd_policy_mask.cil" "$WORK/reqd_policy_mask.conf"
"$HOST_BIN/checkpolicy" -C -M -L -c 30 -o "$WORK/plat_pub_policy.cil" "$WORK/plat_pub_policy.conf"
"$HOST_BIN/build_sepolicy" filter_out -f "$WORK/reqd_policy_mask.cil" -t "$WORK/plat_pub_policy.cil"

log "version_policy -n 202404"
"$HOST_BIN/version_policy" -b "$WORK/plat_pub_policy.cil" -t "$WORK/plat_pub_policy.cil" \
  -n 202404 -o "$WORK/plat_pub_versioned.cil"

mkdir -p "$(dirname "$OUT")"
grep -v '^;;' "$WORK/plat_pub_versioned.cil" > "$OUT.part"
mv "$OUT.part" "$OUT"

log "wrote $OUT ($(stat -c%s "$OUT") bytes, sha256 $(sha256sum "$OUT" | cut -d' ' -f1))"
