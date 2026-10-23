import os
import shutil

from sandbox import capabilities
from sandbox import core
from sandbox import rootfs
from sandbox import guest_files
from sandbox import selinux_policy
from sandbox.core import (NETBPFLOAD_PRELOAD_PATH, NETBPFLOAD_PRELOAD_STAGE,
    RHIZO_ADB_ROOT, RHIZO_SF_ACQUIRED_BUFFERS, RUN_ROOT, SANDBOX_ID, SYSTEM_ADB_KEYS,
    beside, input_phys_prefix, kmsg, phase)

DESKTOP_DPI = 160
DESKTOP_WINDOW_DPI = 117


def _stage_gralloc_and_libs(gfx_src):
    """stage the graphics allocator and libraries"""
    import shutil as _shg2
    alloc_bin = f"{gfx_src}/rhizo-graphics-allocator"
    if os.path.exists(alloc_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-graphics-allocator"
        core.stage_bulk(alloc_bin, dst, 0o755)
    mapper_src = f"{gfx_src}/mapper.rhizo.so"
    if os.path.exists(mapper_src):
        core.stage_bulk(mapper_src, f"{RUN_ROOT}/vendor/lib64/hw/mapper.rhizo.so", 0o644)
    aidl_glue_dir = core.gsi_libs_dir()
    _mismatch = core.gsi_derived_mismatch()
    if _mismatch:
        kmsg(f"RHIZO_MARKER gsi_libs_mismatch=1 {_mismatch} -- "
             "install/prepare/fetch-gsi.sh --release <this release> --derive-only rebuilds the set")
    for _lib in core.KEYMINT_GSI_LIBS:
        _src = os.path.join(aidl_glue_dir, _lib)
        _dst = f"{RUN_ROOT}/vendor/lib64/{_lib}"
        if _mismatch:
            continue
        if os.path.exists(_src):
            core.stage_bulk(_src, _dst, 0o644)
            kmsg(f"{_lib} staged on /vendor/lib64")
        else:
            kmsg(f"{_lib} NOT FOUND at {_src}")
    m2test_src = f"{gfx_src}/m2_gate_test"
    if os.path.exists(m2test_src):
        _shg2.copy(m2test_src, f"{RUN_ROOT}/system_ext_upper/bin/hw/m2_gate_test")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/bin/hw/m2_gate_test", 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a").write(
            "/system_ext/bin/hw/m2_gate_test u:object_r:rhizo_m2test_exec:s0\n"
        )
    probe_src = beside("rhizo-wayland-probe")
    if os.path.exists(probe_src):
        _shg2.copy(probe_src, f"{RUN_ROOT}/system_ext_upper/bin/hw/rhizo-wayland-probe")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/bin/hw/rhizo-wayland-probe", 0o755)
    GPU_DRIVER_DIR = core.gpu_driver_dir()
    dri_gbm_src = beside(GPU_DRIVER_DIR, "lib", "dri_gbm.so")
    gpu_driver_lib = os.path.dirname(dri_gbm_src)
    missing = [n for n in ("libgbm_mesa.so", "libgallium_dri.so", "dri_gbm.so")
               if not os.path.exists(f"{gpu_driver_lib}/{n}")]
    if missing:
        marker = (f"RHIZO_MARKER gpu_driver_refused=allocator-incomplete "
                  f"dir={gpu_driver_lib} missing={','.join(missing)}")
        kmsg(marker)
        raise SystemExit(marker)
    core.stage_bulk(dri_gbm_src, f"{RUN_ROOT}/vendor/lib64/dri_gbm.so", 0o644)
    preload_src = f"{gfx_src}/rhizo_bpf_preload.so"
    if os.path.exists(preload_src):
        _shg2.copy(preload_src, f"{RUN_ROOT}/system_ext_upper/lib64/rhizo_bpf_preload.so")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/lib64/rhizo_bpf_preload.so", 0o644)
    preload_src = f"{gfx_src}/rhizo_netbpfload_preload"
    if os.path.exists(preload_src):
        os.makedirs(os.path.dirname(NETBPFLOAD_PRELOAD_STAGE), exist_ok=True)
        _shg2.copy(preload_src, NETBPFLOAD_PRELOAD_STAGE)
        os.chmod(NETBPFLOAD_PRELOAD_STAGE, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            f"{NETBPFLOAD_PRELOAD_PATH} u:object_r:bpfloader_exec:s0\n")
    else:
        kmsg(f"rhizo_netbpfload_preload NOT FOUND at {preload_src}")
    open(f"{RUN_ROOT}/vendor/etc/init/rhizo-graphics-allocator.rc","w").write(allocator_rc_text())


def allocator_rc_text():
    """return the graphics allocator's init rc"""
    software = core.software_rendering()
    mapper_verbose_line = (
        "    export RHIZO_MAPPER_VERBOSE 1\n" if os.environ.get("RHIZO_MAPPER_VERBOSE") else ""
    )
    no_kms_swrast_line = "    export MESA_ANDROID_NO_KMS_SWRAST 1\n" if software else ""
    alloc_ring_line = "    setenv RHIZO_ALLOC_RING 1\n" if os.environ.get("RHIZO_ALLOC_RING") else ""
    memfd_line = "    setenv RHIZO_ALLOCATOR memfd\n" if software else ""
    _alloc_restorecon = core.restorecon_line("/vendor/bin/hw/rhizo-graphics-allocator")
    _alloc_early_init = "on early-init\n" if (_alloc_restorecon or mapper_verbose_line or no_kms_swrast_line) else ""
    return (
        f"{_alloc_early_init}"
        f"{_alloc_restorecon}"
        f"{mapper_verbose_line}"
        f"{no_kms_swrast_line}"
        "\n"
        "service vendor.rhizo-graphics-allocator /vendor/bin/hw/rhizo-graphics-allocator\n"
        "    class core\n"
        "    user system\n"
        "    group system graphics\n"
        "    setenv GBM_BACKENDS_PATH /vendor/lib64\n"
        f"{alloc_ring_line}"
        f"{memfd_line}"
        "    stdio_to_kmsg\n"
    )


def gpu_mode_or_exit(policy_loaded=False):
    """log this launch's gpu mode or exit"""
    software = core.software_rendering()
    loaded = core.loaded_policy_dri() if policy_loaded else None
    reason = core.host_policy_refusal() or core.gpu_refusal(
        render_node_found=software or bool(rootfs.host_dri_sources()), loaded_dri=loaded)
    if reason:
        marker = f"RHIZO_MARKER gpu_driver_refused={reason}"
        kmsg(marker)
        raise SystemExit(marker)
    kmsg(f"RHIZO_MARKER gpu_mode={'software' if software else 'gpu'} driver={core.gpu_driver_dir()}")


def stream_socket_line(policy):
    """return the composer's stream socket line"""
    if not policy.allows("stream.enabled"):
        return ""
    if core.software_rendering():
        kmsg("RHIZO_MARKER stream_refused=devices-dri-off")
        return ""
    return "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\n"


def stage_software_rro():
    """stage the software rendering overlay"""
    if not core.software_rendering():
        return False
    src = beside("RhizoSoftwareRro.apk")
    if not os.path.exists(src):
        marker = f"RHIZO_MARKER gpu_driver_refused=software-rro-missing path={src}"
        kmsg(marker)
        raise SystemExit(marker)
    dst = f"{RUN_ROOT}/system_ext_upper/overlay/RhizoSoftwareRro.apk"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy(src, dst)
    os.chmod(dst, 0o644)
    with open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
        f.write("/system_ext/overlay/RhizoSoftwareRro\\.apk u:object_r:vendor_overlay_file:s0\n")
    kmsg("RHIZO_MARKER software_rro=staged (no screen-off fade, no gl in system_server)")
    return True


def _stage_framework_rc():
    """stage the framework init .rc files"""
    _sf_density = 400
    _policy_for_density = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if _policy_for_density.scope("rhizo.profile") == "server":
        _sf_density = int(_policy_for_density.scope("server.display").rsplit("/", 1)[1])
    elif _policy_for_density.scope("rhizo.profile") == "desktop":
        _sf_density = DESKTOP_DPI
    density_line = "    setprop ro.sf.lcd_density %d\n" % _sf_density
    gl_preload = os.environ.get("RHIZO_DISABLE_GL_PRELOAD", "true")
    if gl_preload not in ("true", "false"):
        gl_preload = "true"
    gl_preload_line = "    setprop ro.zygote.disable_gl_preload %s\n" % gl_preload
    use_memfd_line = ("    setprop sys.use_memfd true\n"
                      if selinux_policy.platform_opens_ashmem([f"{core.GSI}/etc/selinux/plat_sepolicy.cil"]) else "")
    init_loglevel_line = "    loglevel 7\n" if os.environ.get("RHIZO_INIT_LOGLEVEL") == "7" else ""
    hwui_hint_manager_line = ("    setprop debug.hwui.use_hint_manager true\n"
                               if _policy_for_density.allows("rt.budgets") else "")
    sf_adpf_hint_line = ("    setprop debug.sf.enable_adpf_cpu_hint true\n"
                          if _policy_for_density.allows("rt.contain") else "")
    avoid_gfx_accel_line = ("    setprop ro.config.avoid_gfx_accel true\n"
                            if core.software_rendering() else "")
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-props.rc","w").write(guest_files.render(
                guest_files.read("init/props.rc"),
                whole={"density_line": density_line, "gl_preload_line": gl_preload_line,
                       "init_loglevel_line": init_loglevel_line, "use_memfd_line": use_memfd_line,
                       "hwui_hint_manager_line": hwui_hint_manager_line,
                       "sf_adpf_hint_line": sf_adpf_hint_line,
                       "avoid_gfx_accel_line": avoid_gfx_accel_line,
                       "sf_acquired_buffers": (
                           f"    setprop ro.surface_flinger.min_acquired_buffers {RHIZO_SF_ACQUIRED_BUFFERS}\n"
                           f"    setprop ro.surface_flinger.max_acquired_buffers {RHIZO_SF_ACQUIRED_BUFFERS}\n"
                           if RHIZO_SF_ACQUIRED_BUFFERS not in ("", "0") else "")},
                comment_prefix="#"))
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-class-start.rc","w").write(
        "on init\n"
        "    chmod 0666 /dev/kmsg\n"
        "\n"
        "on boot\n"
        "    chmod 0666 /dev/kmsg\n"
        "    class_start main\n"
        "    class_start late_start\n"
    )
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-keystore-debug.rc","w").write(
        "service rhizo-logcat-dump /system/bin/sh -c \"/system/bin/logcat -d -b all -v threadtime "
        "-f /data/local/tmp/rhizo-keystore-crash.log\"\n"
        "    disabled\n"
        "    oneshot\n"
        "    user shell\n"
        "    group shell log\n"
        "    seclabel u:r:shell:s0\n"
        "\n"
        "on property:init.svc.keystore2=restarting\n"
        "    start rhizo-logcat-dump\n"
    )
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-disable-unused.rc","w").write(
                guest_files.read("init/disable-unused.rc"))


def _stage_screen_off():
    """skip the screen-off staging"""
    return


def stage_adb_keys(sources, out_path):
    """write key lines from sources to out_path"""
    lines = []
    for src in sources:
        try:
            with open(src) as handle:
                lines += [line.rstrip("\n") for line in handle if line.strip()]
        except OSError:
            pass
    if not lines:
        try:
            os.unlink(out_path)
        except FileNotFoundError:
            pass
        return lines
    tmp = out_path + ".new"
    with open(tmp, "w") as out:
        out.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.rename(tmp, out_path)
    return lines


def _stage_adb(gfx_src):
    """stage the adbd init .rc and adb keys"""
    if RHIZO_ADB_ROOT:
        adbd_start_line = "    start rhizo-adbd-root\n"
        adbd_root_service = (
            "\nservice rhizo-adbd-root /apex/com.android.adbd/bin/adbd "
            "--root_seclabel=u:r:su:s0 --tim_seclabel=u:r:adbd_tradeinmode:s0\n"
            "    class core\n"
            "    socket adbd seqpacket 660 system system\n"
            "    disabled\n"
            "    seclabel u:r:adbd:s0\n"
            "    user root\n"
            "    restart_period 0\n"
            + ("    setenv LD_PRELOAD /system_ext/lib64/rhizo-adbd-debug-shim.so\n"
               if os.path.exists(f"{gfx_src}/rhizo-adbd-debug-shim.so") else ""))
        adbd_stock_guard = (
            "\non property:init.svc.adbd=running\n"
            "    stop adbd\n"
            "    stop rhizo-adbd-root\n"
            "    start rhizo-adbd-root\n")
    else:
        adbd_start_line = "    start adbd\n"
        adbd_root_service = ""
        adbd_stock_guard = ""
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-adbd.rc","w").write(guest_files.render(
                    guest_files.read("init/adbd.rc"),
                    whole={"adbd_stock_guard": adbd_stock_guard,
                           "adbd_start_line": adbd_start_line,
                           "adbd_root_service": adbd_root_service}, comment_prefix="#"))
    if RHIZO_ADB_ROOT:
        shim_src = f"{gfx_src}/rhizo-adbd-debug-shim.so"
        if os.path.exists(shim_src):
            import shutil as _shadbroot
            _shadbroot.copy(shim_src, f"{RUN_ROOT}/system_ext_upper/lib64/rhizo-adbd-debug-shim.so")
            os.chmod(f"{RUN_ROOT}/system_ext_upper/lib64/rhizo-adbd-debug-shim.so", 0o644)
    adbkey_pub_src = beside("adbkey.pub")
    adb_key_lines = stage_adb_keys((adbkey_pub_src, capabilities.OPERATOR_ADB_KEYS), SYSTEM_ADB_KEYS)
    if adb_key_lines:
        kmsg(f"adb_keys staged: {len(adb_key_lines)} key(s) from adbkey.pub and "
             f"{capabilities.OPERATOR_ADB_KEYS} into the sandbox's /adb_keys")
    else:
        kmsg(f"no key at {adbkey_pub_src} or {capabilities.OPERATOR_ADB_KEYS}; "
             "adb authorizes a host key on its first connection")


def _stage_net_rc(gfx_src):
    """stage the networking init .rc files"""
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-data-mirror.rc","w").write(
        "on post-fs-data\n"
        "    mkdir /data_mirror 0700 root root\n"
        "    mkdir /data_mirror/data_de 0700 root root\n"
        "    mkdir /data_mirror/data_de/null 0700 root root\n"
        "    mkdir /data_mirror/data_de/null/0 0771 system system\n"
        "    mount none /data/user_de/0 /data_mirror/data_de/null/0 bind\n"
        "    mkdir /data_mirror/data_ce 0700 root root\n"
        "    mkdir /data_mirror/data_ce/null 0700 root root\n"
        "    mkdir /data_mirror/data_ce/null/0 0771 system system\n"
        "    mount none /data/user/0 /data_mirror/data_ce/null/0 bind\n"
    )
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-bpfloader.rc","w").write(
        guest_files.render(guest_files.read("init/bpfloader.rc"),
                            inline={"NETBPFLOAD_PRELOAD_PATH": NETBPFLOAD_PRELOAD_PATH},
                            comment_prefix="#"))
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-mdnsd-netbpfload-stub.rc","w").write(
        "service mdnsd_netbpfload /system/bin/true\n"
        "    class core\n"
        "    user root\n"
        "    oneshot\n"
        "    disabled\n"
        "    override\n"
    )
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
        "/vendor/bin/hw/rhizo-graphics-allocator u:object_r:rhizo_gralloc_allocator_exec:s0\n"
        "/vendor/lib64/hw/mapper\\.rhizo\\.so u:object_r:same_process_hal_file:s0\n"
    )
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_service_contexts","a").write(
        "mapper/rhizo u:object_r:hal_graphics_allocator_service:s0\n"
    )
    kmsg(f"rhizo gralloc allocator+mapper staged from {gfx_src}")


def stage_hals():
    """stage the HAL executables and libraries"""
    phase("B", "stage_hals")
    gfx_src = beside("gfx_hal")

    if os.path.isdir(gfx_src):
        _stage_gralloc_and_libs(gfx_src)
        _stage_framework_rc()
        _stage_screen_off()
        _stage_adb(gfx_src)
        _stage_net_rc(gfx_src)
    else:
        kmsg(f"gfx_hal NOT FOUND at {gfx_src} -- gralloc allocator/mapper absent")
    composer_bin = f"{gfx_src}/rhizo-composer"
    if os.path.isdir(gfx_src) and os.path.exists(composer_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-composer"
        core.stage_bulk(composer_bin, dst, 0o755)
        _server_policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
        _is_server = _server_policy.scope("rhizo.profile") == "server"
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-composer.rc","w").write(guest_files.render(
                    guest_files.read("init/composer.rc"),
                    whole={"early_init_restorecon": core.early_init_restorecon("/vendor/bin/hw/rhizo-composer"),
                           "no_resize": "    setenv RHIZO_NO_RESIZE 1\n" if os.environ.get("RHIZO_NO_RESIZE") else "",
                           "composer_verbose": "    setenv RHIZO_COMPOSER_VERBOSE 1\n" if os.environ.get("RHIZO_COMPOSER_VERBOSE") else "",
                           "composer_unreliable_fences": "    setenv RHIZO_COMPOSER_UNRELIABLE_FENCES 1\n" if os.environ.get("RHIZO_COMPOSER_UNRELIABLE_FENCES") else "",
                           "composer_pacing": f"    setenv RHIZO_COMPOSER_PACING {os.environ['RHIZO_COMPOSER_PACING']}\n" if os.environ.get("RHIZO_COMPOSER_PACING") else "",
                           "composer_debug": "    setenv RHIZO_COMPOSER_DEBUG 1\n" if os.environ.get("RHIZO_COMPOSER_DEBUG") else "",
                           "resize_trace": "    setenv RHIZO_RESIZE_TRACE 1\n" if os.environ.get("RHIZO_RESIZE_TRACE") == "1" else "",
                           "composer_vsync_min_gap": f"    setenv RHIZO_COMPOSER_VSYNC_MIN_GAP {os.environ['RHIZO_COMPOSER_VSYNC_MIN_GAP']}\n" if os.environ.get("RHIZO_COMPOSER_VSYNC_MIN_GAP") else "",
                           "composer_device": f"    setenv RHIZO_COMPOSER_DEVICE {os.environ['RHIZO_COMPOSER_DEVICE']}\n" if os.environ.get("RHIZO_COMPOSER_DEVICE") else "",
                           "display_pool_idle_s": f"    setenv RHIZO_DISPLAY_POOL_IDLE_S {os.environ['RHIZO_DISPLAY_POOL_IDLE_S']}\n" if os.environ.get("RHIZO_DISPLAY_POOL_IDLE_S") else "",
                           "display_geometry": f"    setenv RHIZO_DISPLAY_GEOMETRY {_server_policy.scope('server.display')}\n" if _is_server
                           else f"    setenv RHIZO_DISPLAY_GEOMETRY 1280x800@60/{DESKTOP_WINDOW_DPI}\n    setenv RHIZO_PRIMARY_WINDOW 0\n"
                           if _server_policy.scope("rhizo.profile") == "desktop" else "",
                           "display_pool_enabled": "    setenv RHIZO_DISPLAY_POOL_ENABLED 0\n" if _is_server else "",
                           "input_phys_prefix": f"    setenv RHIZO_INPUT_PHYS_PREFIX {input_phys_prefix(SANDBOX_ID)}\n" if SANDBOX_ID else "",
                           "stream_socket": stream_socket_line(_server_policy),
                           "clipboard_enabled": "    setenv RHIZO_COMPOSER_CLIPBOARD 0\n"
                               if not _server_policy.allows("desktop.clipboard") else ""},
                    comment_prefix="#"))
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-composer u:object_r:rhizo_composer_exec:s0\n"
            "/data/rhizo_control(/.*)? u:object_r:rhizo_control_file:s0\n"
        )
        kmsg("rhizo-composer staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-composer NOT FOUND at {composer_bin}")
    health_bin = f"{gfx_src}/rhizo-health-service"
    if os.path.isdir(gfx_src) and os.path.exists(health_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-health-service"
        core.stage_bulk(health_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-health.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-health-service") +
            "\n"
            "service vendor.rhizo-health /vendor/bin/hw/rhizo-health-service\n"
            "    class core\n"
            "    user system\n"
            "    group system\n"
            "    stdio_to_kmsg\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-health-service u:object_r:rhizo_health_exec:s0\n"
        )
        kmsg("rhizo-health-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-health-service NOT FOUND at {health_bin}")
    power_bin = core.release_hal_bin(gfx_src, "rhizo-power-service")
    if os.path.isdir(gfx_src) and os.path.exists(power_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-power-service"
        core.stage_bulk(power_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-power.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-power-service") +
            "\n"
            "service vendor.rhizo-power /vendor/bin/hw/rhizo-power-service\n"
            "    class core\n"
            "    user system\n"
            "    group system\n"
            "    stdio_to_kmsg\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-power-service u:object_r:rhizo_power_exec:s0\n"
        )
        kmsg(f"rhizo-power-service staged on /vendor/bin/hw from {power_bin}")
    else:
        kmsg(f"rhizo-power-service NOT FOUND at {power_bin}")
    bootctl_bin = f"{gfx_src}/rhizo-bootcontrol-service"
    if os.path.isdir(gfx_src) and os.path.exists(bootctl_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-bootcontrol-service"
        core.stage_bulk(bootctl_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-bootcontrol.rc","w").write(guest_files.render(
                    guest_files.read("init/bootcontrol.rc"),
                    whole={"early_init_restorecon": core.early_init_restorecon(
                        "/vendor/bin/hw/rhizo-bootcontrol-service")},
                    comment_prefix="#"))
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-bootcontrol-service u:object_r:rhizo_bootcontrol_exec:s0\n"
        )
        kmsg("rhizo-bootcontrol-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-bootcontrol-service NOT FOUND at {bootctl_bin}")
    gk_bin = f"{gfx_src}/rhizo-gatekeeper-service"
    if os.path.isdir(gfx_src) and os.path.exists(gk_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-gatekeeper-service"
        core.stage_bulk(gk_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gatekeeper.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-gatekeeper-service") +
            "\n"
            "service vendor.rhizo-gatekeeper /vendor/bin/hw/rhizo-gatekeeper-service\n"
            "    class early_hal\n"
            "    user system\n"
            "    group system\n"
            "    stdio_to_kmsg\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-gatekeeper-service u:object_r:rhizo_gatekeeper_exec:s0\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_service_contexts","a").write(
            "android.hardware.security.sharedsecret.ISharedSecret/gatekeeper "
            "u:object_r:hal_sharedsecret_service:s0\n"
        )
        kmsg("rhizo-gatekeeper-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-gatekeeper-service NOT FOUND at {gk_bin}")
    thermal_bin = f"{gfx_src}/rhizo-thermal-service"
    if os.path.isdir(gfx_src) and os.path.exists(thermal_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-thermal-service"
        core.stage_bulk(thermal_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-thermal.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-thermal-service") +
            "\n"
            "service vendor.rhizo-thermal /vendor/bin/hw/rhizo-thermal-service\n"
            "    class core\n"
            "    user system\n"
            "    group system\n"
            "    stdio_to_kmsg\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-thermal-service u:object_r:rhizo_thermal_exec:s0\n"
        )
        kmsg("rhizo-thermal-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-thermal-service NOT FOUND at {thermal_bin}")
    bluetooth_bin = f"{gfx_src}/rhizo-bluetooth-service"
    if os.path.isdir(gfx_src) and os.path.exists(bluetooth_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-bluetooth-service"
        core.stage_bulk(bluetooth_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-bluetooth-service u:object_r:rhizo_bluetooth_exec:s0\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-bluetooth.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-bluetooth-service") +
            "\n"
            "service vendor.rhizo-bluetooth /vendor/bin/hw/rhizo-bluetooth-service\n"
            "    class hal\n"
            "    user bluetooth\n"
            "    group bluetooth system\n"
            "    stdio_to_kmsg\n"
        )
        os.makedirs(f"{RUN_ROOT}/product_upper/etc/permissions", exist_ok=True)
        open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-bluetooth.xml", "w").write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<permissions>\n"
            '    <feature name="android.hardware.bluetooth" />\n'
            '    <feature name="android.hardware.bluetooth_le" />\n'
            "</permissions>\n"
        )
        kmsg("RHIZO_MARKER bluetooth_hal=staged armed=%d"
             % bluetooth_armed())
    else:
        kmsg(f"rhizo-bluetooth-service NOT FOUND at {bluetooth_bin}")
    gnss_bin = f"{gfx_src}/rhizo-gnss-service"
    _gnss_server = gnss_armed()
    if os.path.isdir(gfx_src) and os.path.exists(gnss_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-gnss-service"
        core.stage_bulk(gnss_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-gnss-service u:object_r:rhizo_gnss_exec:s0\n"
        )
        if not _gnss_server:
            kmsg("rhizo-gnss-service staged but not armed: rhizo.profile is not server")
        else:
            open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-location.xml", "w").write(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                "<permissions>\n"
                '    <feature name="android.hardware.location" />\n'
                '    <feature name="android.hardware.location.gps" />\n'
                "</permissions>\n"
            )
            kmsg("rhizo-location.xml staged with the gnss HAL")
            open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gnss.rc","w").write(
                core.early_init_restorecon("/vendor/bin/hw/rhizo-gnss-service") +
                "\n"
                "service vendor.rhizo-gnss /vendor/bin/hw/rhizo-gnss-service\n"
                "    class core\n"
                "    user system\n"
                "    group system\n"
                "    stdio_to_kmsg\n"
            )
            kmsg("rhizo-gnss-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-gnss-service NOT FOUND at {gnss_bin}")
    audio_core_bin = f"{gfx_src}/rhizo-audio-core-service"
    if os.path.isdir(gfx_src) and os.path.exists(audio_core_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-audio-core-service"
        core.stage_bulk(audio_core_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-audio-core.rc","w").write(guest_files.render(
                    guest_files.read("init/audio-core.rc"),
                    whole={"early_init_restorecon": core.early_init_restorecon(
                        "/vendor/bin/hw/rhizo-audio-core-service")},
                    comment_prefix="#"))
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-audio-core-service u:object_r:rhizo_audio_core_exec:s0\n"
        )
        kmsg("rhizo-audio-core-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-audio-core-service NOT FOUND at {audio_core_bin}")
    audio_effect_bin = f"{gfx_src}/rhizo-audio-effect-service"
    if os.path.isdir(gfx_src) and os.path.exists(audio_effect_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-audio-effect-service"
        core.stage_bulk(audio_effect_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-audio-effect.rc","w").write(guest_files.render(
                    guest_files.read("init/audio-effect.rc"),
                    whole={"early_init_restorecon": core.early_init_restorecon(
                        "/vendor/bin/hw/rhizo-audio-effect-service")},
                    comment_prefix="#"))
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-audio-effect-service u:object_r:rhizo_audio_effect_exec:s0\n"
        )
        kmsg("rhizo-audio-effect-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-audio-effect-service NOT FOUND at {audio_effect_bin}")


def _stage_virtual_device(upper, vendor_file_contexts_path, apk_src, rro_src):
    """stage RhizoVirtualDevice and its RRO APK"""
    missing = [name for name, path in (("apk", apk_src), ("rro", rro_src))
               if not os.path.exists(path)]
    if missing:
        kmsg(f"RHIZO_MARKER virtual_device=absent missing={','.join(missing)} "
             f"apk={apk_src} rro={rro_src}")
        return False
    for d in ("priv-app/RhizoVirtualDevice", "overlay", "etc/permissions"):
        os.makedirs(os.path.join(upper, d), exist_ok=True)
    apk_dst = os.path.join(upper, "priv-app/RhizoVirtualDevice/RhizoVirtualDevice.apk")
    rro_dst = os.path.join(upper, "overlay/RhizoAutomotiveProjectionRro.apk")
    shutil.copy(apk_src, apk_dst)
    os.chmod(apk_dst, 0o644)
    shutil.copy(rro_src, rro_dst)
    os.chmod(rro_dst, 0o644)
    with open(os.path.join(upper, "etc/permissions/privapp-permissions-rhizo-virtualdevice.xml"), "w") as f:
        f.write(guest_files.read("permissions/privapp-virtualdevice.xml"))
    with open(vendor_file_contexts_path, "a") as f:
        f.write(
            "/product/priv-app/RhizoVirtualDevice/RhizoVirtualDevice\\.apk u:object_r:system_file:s0\n"
            "/product/overlay/RhizoAutomotiveProjectionRro\\.apk u:object_r:vendor_overlay_file:s0\n")
    kmsg("RHIZO_MARKER virtual_device=staged apk=/product/priv-app/RhizoVirtualDevice "
         "rro=/product/overlay/RhizoAutomotiveProjectionRro.apk")
    return True


def stage_virtual_device():
    """stage RhizoVirtualDevice into the product tree"""
    policy = capabilities.policy_or_deny(log=kmsg)
    if not policy.allows("devices.virtual"):
        kmsg("RHIZO_MARKER virtual_device=off")
        return False
    return _stage_virtual_device(
        f"{RUN_ROOT}/product_upper",
        f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
        beside("virtual-device", "RhizoVirtualDevice.apk"),
        beside("virtual-device", "RhizoAutomotiveProjectionRro.apk"))


DESKTOP_BRIDGE_CAPABILITIES = ("desktop.clipboard", "desktop.notifications",
                              "desktop.drag", "desktop.open_uri")


def desktop_bridge_wanted(policy):
    """return true for an allowed desktop capability"""
    return any(policy.allows(c) for c in DESKTOP_BRIDGE_CAPABILITIES)


def _stage_desktop_bridge(upper, vendor_file_contexts_path, apk_src):
    """stage the RhizoDesktop APK"""
    if not os.path.exists(apk_src):
        kmsg(f"RHIZO_MARKER desktop_bridge=absent apk={apk_src}")
        return False
    dst_dir = os.path.join(upper, "app/RhizoDesktop")
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, "RhizoDesktop.apk")
    shutil.copy(apk_src, dst)
    os.chmod(dst, 0o644)
    with open(vendor_file_contexts_path, "a") as f:
        f.write("/system_ext/app/RhizoDesktop/RhizoDesktop\\.apk u:object_r:system_file:s0\n")
    kmsg("RHIZO_MARKER desktop_bridge=staged apk=/system_ext/app/RhizoDesktop")
    return True


def stage_desktop_bridge():
    """stage the RhizoDesktop APK"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if not desktop_bridge_wanted(policy):
        kmsg("RHIZO_MARKER desktop_bridge=off")
        return False
    return _stage_desktop_bridge(
        f"{RUN_ROOT}/system_ext_upper",
        f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
        beside("RhizoDesktop.apk"))


def _stage_host_delay(upper, vendor_file_contexts_path, vendor_service_contexts_path, daemon_src):
    """stage the rhizo-host-delay binary and .rc"""
    if not os.path.exists(daemon_src):
        kmsg(f"RHIZO_MARKER host_delay_daemon=absent daemon={daemon_src}")
        return False
    for d in ("bin/hw", "etc/init"):
        os.makedirs(os.path.join(upper, d), exist_ok=True)
    dst = os.path.join(upper, "bin/hw/rhizo-host-delay")
    shutil.copy(daemon_src, dst)
    os.chmod(dst, 0o755)
    with open(os.path.join(upper, "etc/init/rhizo-host-delay.rc"), "w") as f:
        f.write(guest_files.read("init/host-delay.rc"))
    with open(vendor_file_contexts_path, "a") as f:
        f.write("/system_ext/bin/hw/rhizo-host-delay u:object_r:rhizo_host_delay_exec:s0\n")
    with open(vendor_service_contexts_path, "a") as f:
        f.write("rhizo.host_delay u:object_r:rhizo_host_delay_service:s0\n")
    kmsg("RHIZO_MARKER host_delay_daemon=staged daemon=/system_ext/bin/hw/rhizo-host-delay")
    return True


def stage_host_delay():
    """stage rhizo-host-delay onto /system_ext"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if not policy.allows("trace.host_delay"):
        kmsg("RHIZO_MARKER host_delay_daemon=withheld")
        return False
    return _stage_host_delay(
        f"{RUN_ROOT}/system_ext_upper",
        f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
        f"{RUN_ROOT}/vendor/etc/selinux/vendor_service_contexts",
        beside("rhizo-host-delay"))


GNSS_MANIFEST_HAL = (
    '    <hal format="aidl">\n'
    '        <name>android.hardware.gnss</name>\n'
    '        <version>6</version>\n'
    '        <fqname>IGnss/default</fqname>\n'
    '    </hal>\n'
)


def gnss_armed():
    """return true when the profile starts the gnss HAL"""
    return capabilities.policy_or_deny(log=kmsg).scope("rhizo.profile") == "server"


BLUETOOTH_SYSFS = "/sys/class/bluetooth"


def host_has_bluetooth_controller():
    """return true when the host has an hci controller"""
    try:
        return any(name.startswith("hci") for name in os.listdir(BLUETOOTH_SYSFS))
    except OSError:
        return False


def bluetooth_armed():
    """return true when devices.bluetooth is on and the host has a controller"""
    return (capabilities.policy_or_deny(log=kmsg).allows("devices.bluetooth")
            and host_has_bluetooth_controller())


def vendor_manifest_xml():
    """return the /vendor/manifest.xml text"""
    text = guest_files.read("vendor/manifest.xml")
    if core.RHIZO_RELEASE == "a15":
        # a15's framework matrix accepts vendor sepolicy up to 202404; 202504 fails isBuildConsistent()
        text = text.replace("<version>202504</version>", "<version>202404</version>")
    if gnss_armed():
        text = text.replace("</manifest>", GNSS_MANIFEST_HAL + "</manifest>")
    policy = capabilities.policy_or_deny(log=kmsg)
    if not policy.allows("devices.virtual"):
        return text
    if "</manifest>" not in text:
        kmsg("RHIZO_MARKER camera_provider_hal=absent -- vendor-manifest.xml has no </manifest>")
        return text
    camera_hal = (
        '    <hal format="aidl">\n'
        '        <name>android.hardware.camera.provider</name>\n'
        '        <version>3</version>\n'
        '        <fqname>ICameraProvider/virtual/0</fqname>\n'
        '    </hal>\n'
    )
    kmsg("RHIZO_MARKER camera_provider_hal=staged")
    return text.replace("</manifest>", camera_hal + "</manifest>")
