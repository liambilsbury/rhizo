import hashlib
import os
import re
import shutil
import stat

from sandbox import capabilities
from sandbox import core
from sandbox import rootfs
from sandbox import guest_files
from sandbox import selinux_policy
from sandbox import sensors
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


def stage_rotation_rro(root=None, src=None):
    """stage the overlay that turns sensor rotation off"""
    root = root or RUN_ROOT
    src = src or beside("RhizoRotationRro.apk")
    if not os.path.exists(src):
        kmsg(f"RHIZO_MARKER rotation_rro=absent path={src} -- an accelerometer may rotate Android's displays")
        return False
    dst = f"{root}/product_upper/overlay/RhizoRotationRro.apk"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy(src, dst)
    os.chmod(dst, 0o644)
    with open(f"{root}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
        f.write("/product/overlay/RhizoRotationRro\\.apk u:object_r:vendor_overlay_file:s0\n")
    kmsg("RHIZO_MARKER rotation_rro=staged (config_supportAutoRotation=false)")
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
    stage_rotation_rro()
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
        _battery_source = battery_source_marked()
        core.set_staged_battery_source(_battery_source)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-health.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-health-service") +
            "\n" + health_service_rc(_battery_source))
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-health-service u:object_r:rhizo_health_exec:s0\n"
        )
        kmsg(f"rhizo-health-service staged on /vendor/bin/hw ({_battery_source} source)")
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
    camera_bin = f"{gfx_src}/{core.CAMERA_PROVIDER}"
    if os.path.isdir(gfx_src) and os.path.exists(camera_bin):
        core.stage_bulk(camera_bin, f"{RUN_ROOT}/vendor/bin/hw/{core.CAMERA_PROVIDER}", 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            f"/vendor/bin/hw/{core.CAMERA_PROVIDER} u:object_r:rhizo_camera_provider_exec:s0\n"
        )
        kmsg(f"{core.CAMERA_PROVIDER} staged on /vendor/bin/hw")
    else:
        kmsg(f"{core.CAMERA_PROVIDER} NOT FOUND at {camera_bin}")
    gnss_bin = f"{gfx_src}/rhizo-gnss-service"
    _gnss_source = gnss_source_marked()
    if os.path.isdir(gfx_src) and os.path.exists(gnss_bin):
        dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-gnss-service"
        core.stage_bulk(gnss_bin, dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-gnss-service u:object_r:rhizo_gnss_exec:s0\n"
        )
        if _gnss_source is None:
            kmsg("rhizo-gnss-service staged but not armed: devices.location is off on the desktop profile")
        else:
            _network = _gnss_source == "host" and stage_network_location()
            open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-location.xml", "w").write(
                gnss_feature_xml(_gnss_source, network_provider=_network))
            kmsg(f"rhizo-location.xml staged with the gnss HAL ({_gnss_source} source)")
            open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gnss.rc","w").write(
                core.early_init_restorecon("/vendor/bin/hw/rhizo-gnss-service") +
                "\n" + gnss_service_rc(_gnss_source))
            kmsg(f"rhizo-gnss-service staged on /vendor/bin/hw ({_gnss_source} source)")
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
    stage_wifi_hal_bins()
    stage_sensors_hal_bin()
    stage_codec2_store_bin()


WIFI_HAL_LABELS = {"rhizo-wifi-service": "rhizo_wifi_exec",
                   "rhizo-wifi-supplicant": "rhizo_wifi_supplicant_exec"}


def stage_wifi_hal_bins():
    """stage the Wi-Fi HAL binaries and their labels"""
    staged = []
    for src in core.wifi_hal_sources():
        name = os.path.basename(src)
        dst = f"{RUN_ROOT}/vendor/bin/hw/{name}"
        if core.is_prepared_bind_path(dst) and not os.path.exists(dst):
            kmsg(f"{name} is not in the prepared tree -- not staged")
            continue
        core.stage_bulk(src, dst, 0o755)
        with open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
            f.write(f"/vendor/bin/hw/{name} u:object_r:{WIFI_HAL_LABELS[name]}:s0\n")
        staged.append(name)
    kmsg(f"RHIZO_MARKER wifi_hal_bins={','.join(staged) or 'none'}")
    return staged


def wifi_hal_bins_staged():
    """return true when the Wi-Fi HAL binaries are staged"""
    return all(os.path.exists(f"{RUN_ROOT}/vendor/bin/hw/{n}") for n in core.WIFI_HAL_BINS)


def stage_codec2_store_bin():
    """stage the hardware Codec2 store binary and its label"""
    staged = []
    for src in core.codec2_store_sources():
        dst = f"{RUN_ROOT}/vendor/bin/hw/{core.CODEC2_STORE_BIN}"
        if core.is_prepared_bind_path(dst) and not os.path.exists(dst):
            kmsg(f"{core.CODEC2_STORE_BIN} is not in the prepared tree -- not staged")
            continue
        core.stage_bulk(src, dst, 0o755)
        with open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
            f.write(f"/vendor/bin/hw/{core.CODEC2_STORE_BIN} u:object_r:rhizo_codec2_exec:s0\n")
        staged.append(core.CODEC2_STORE_BIN)
    kmsg(f"RHIZO_MARKER codec2_store_bin={','.join(staged) or 'none'}")
    return staged


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


PAYLOAD_MANIFEST = "manifest.tsv"
PAYLOAD_LABEL = "u:object_r:system_file:s0"
AURORA_CONTEXTS = ("/product/app/AuroraStore(/.*)?",)
AURORA_REQUIRED = ("app/AuroraStore/AuroraStore.apk",)
GAPPS_CONTEXTS = ("/product/priv-app/(GmsCore|GoogleServicesFramework|Phonesky)(/.*)?",
                  "/product/etc/(permissions|default-permissions|sysconfig)/gapps-.*\\.xml")
GAPPS_REQUIRED = ("priv-app/GmsCore/GmsCore.apk",
                  "priv-app/GoogleServicesFramework/GoogleServicesFramework.apk",
                  "priv-app/Phonesky/Phonesky.apk",
                  "etc/permissions/gapps-rhizo.xml")
GAPPS_REFUSAL = ("Google apps are enabled, but this host has no valid Google apps payload for {release} ({why}). "
                 "Starting Android without it would erase Google Play services' data and this device's "
                 "registration, so Android was not started. Run 'sudo rhizo gapps enable' to fetch the payload "
                 "again, or 'sudo rhizo gapps disable' to start Android without Google apps.")
_MANIFEST_ROW = re.compile(r"([^\t]+)\t([0-9]+)\t([0-9a-f]{64})")
_REASON_BAD = re.compile(r"[^A-Za-z0-9_.:=,/@-]")
_COPY_CHUNK = 1 << 20


def payload_dir(root):
    """return the payload dir root/current links to, and why not"""
    current = os.path.join(root, "current")
    if not os.path.lexists(current):
        return None, "missing"
    real = os.path.realpath(current)
    if not os.path.islink(current) or os.path.dirname(real) != os.path.realpath(root):
        return None, "current-not-a-payload-link"
    if not os.path.isdir(real):
        return None, "current-dangling"
    return real, None


def _payload_entries(payload, lower, contexts, required):
    """return the manifest's rows, and why not"""
    try:
        with open(os.path.join(payload, PAYLOAD_MANIFEST), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeError):
        return None, "manifest-unreadable"
    allowed = [re.compile(c) for c in contexts]
    real_payload = os.path.realpath(payload)
    entries, seen = [], set()
    for n, line in enumerate(lines, 1):
        m = _MANIFEST_ROW.fullmatch(line)
        if m is None:
            return None, f"manifest-line-{n}"
        rel, size, digest = m.group(1), int(m.group(2)), m.group(3)
        parts = rel.split("/")
        if rel.startswith("/") or any(p in ("", ".", "..") for p in parts) or rel == PAYLOAD_MANIFEST:
            return None, f"unsafe-path:{rel}"
        if rel in seen:
            return None, f"duplicate:{rel}"
        if not any(rx.fullmatch(f"/product/{rel}") for rx in allowed):
            return None, f"not-allowed:{rel}"
        for i in range(1, len(parts) + 1):
            low = os.path.join(lower, *parts[:i])
            if os.path.lexists(low) and (i == len(parts) or os.path.islink(low) or not os.path.isdir(low)):
                return None, f"gsi-collision:{'/'.join(parts[:i])}"
        if os.path.realpath(os.path.join(payload, rel)) != os.path.join(real_payload, rel):
            return None, f"payload-symlink:{rel}"
        seen.add(rel)
        entries.append((rel, size, digest))
    if not entries:
        return None, "manifest-empty"
    missing = [r for r in required if r not in seen]
    if missing:
        return None, f"missing:{missing[0]}"
    return entries, None


def _copy_verified(src, dst, size, digest, made_files):
    """copy and hash src to dst, and return why not"""
    try:
        sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return "unreadable"
    try:
        st = os.fstat(sfd)
        if not stat.S_ISREG(st.st_mode):
            return "not-a-file"
        if st.st_size != size:
            return "size-mismatch"
        try:
            dfd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
        except OSError:
            return "upper-collision"
        made_files.append(dst)
        h, n = hashlib.sha256(), 0
        try:
            while True:
                chunk = os.read(sfd, _COPY_CHUNK)
                if not chunk:
                    break
                h.update(chunk)
                n += len(chunk)
                view = memoryview(chunk)
                while view:
                    view = view[os.write(dfd, view):]
            os.fchmod(dfd, 0o644)
        finally:
            os.close(dfd)
    except OSError:
        return "copy-failed"
    finally:
        os.close(sfd)
    if n != size:
        return "size-mismatch"
    if h.hexdigest() != digest:
        return "sha256-mismatch"
    return None


def _make_dirs(upper, rel, made_dirs):
    """create upper and rel's parent dirs at 0755"""
    path = None
    for part in [upper] + rel.split("/")[:-1]:
        path = part if path is None else os.path.join(path, part)
        if not os.path.isdir(path):
            os.makedirs(path, 0o755)
            os.chmod(path, 0o755)
            made_dirs.append(path)


def _reason(why):
    """return why as a short marker-safe word"""
    return _REASON_BAD.sub("_", why)[:160]


def _stage_payload(payload, upper, lower, vendor_file_contexts_path, contexts, required=()):
    """copy a payload's verified manifest files into upper"""
    entries, why = _payload_entries(payload, lower, contexts, required)
    if why:
        return why
    made_dirs, made_files = [], []
    for rel, size, digest in entries:
        try:
            _make_dirs(upper, rel, made_dirs)
        except OSError:
            why = f"upper-collision:{rel}"
            break
        why = _copy_verified(os.path.join(payload, rel), os.path.join(upper, rel), size, digest, made_files)
        if why:
            why = f"{why}:{rel}"
            break
    if why:
        for path in reversed(made_files):
            try: os.unlink(path)
            except OSError: pass
        for path in reversed(made_dirs):
            try: os.rmdir(path)
            except OSError: pass
        return why
    with open(vendor_file_contexts_path, "a") as f:
        f.write("".join(f"{c} {PAYLOAD_LABEL}\n" for c in contexts))
    return None


def stage_aurora():
    """stage Aurora Store into the product tree"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if not policy.allows("apps.aurora"):
        kmsg("RHIZO_MARKER aurora=off")
        return False
    payload, why = payload_dir(core.AURORA_ROOT)
    if why == "missing":
        kmsg(f"RHIZO_MARKER aurora=absent root={core.AURORA_ROOT}")
        return False
    if payload is not None:
        why = _stage_payload(payload, f"{RUN_ROOT}/product_upper", f"{core.GSI}/product",
                             f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
                             AURORA_CONTEXTS, AURORA_REQUIRED)
    if why:
        kmsg(f"RHIZO_MARKER aurora=refused:{_reason(why)} root={core.AURORA_ROOT}")
        return False
    kmsg(f"RHIZO_MARKER aurora=staged dir={payload}")
    return True


def stage_gapps():
    """stage the Google apps payload into the product tree"""
    if not os.path.exists(os.path.join(core.GAPPS_ROOT, "enabled")):
        kmsg("RHIZO_MARKER gapps=off")
        return None
    release = core.RHIZO_RELEASE
    payload, why = payload_dir(os.path.join(core.GAPPS_ROOT, release))
    if payload is not None:
        why = _stage_payload(payload, f"{RUN_ROOT}/product_upper", f"{core.GSI}/product",
                             f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
                             GAPPS_CONTEXTS, GAPPS_REQUIRED)
    if why:
        why = _reason(why)
        kmsg(f"RHIZO_MARKER gapps=refused:{why} release={release}")
        kmsg(GAPPS_REFUSAL.format(release=release, why=why))
        return _reason(f"gapps:{release}:{why}")
    kmsg(f"RHIZO_MARKER gapps=staged release={release} dir={payload}")
    return None


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


LOCATION_GUEST_SOCKET = "/dev/socket/rhizo_location/locationd"
NETWORK_LOCATION_FEATURE = "android.hardware.location.network"
GNSS_FEATURES = {
    "operator": ("android.hardware.location", "android.hardware.location.gps"),
    "host": ("android.hardware.location", "android.hardware.location.network"),
}
NETWORK_LOCATION_APK = "RhizoNetworkLocation.apk"
NETWORK_LOCATION_PACKAGE = "com.rhizo.networklocation"
NETWORK_LOCATION_PERMISSIONS = ("android.permission.ACCESS_COARSE_LOCATION",
                                "android.permission.ACCESS_FINE_LOCATION",
                                "android.permission.ACCESS_BACKGROUND_LOCATION")
GNSS_SERVICE = {
    "operator": ("", "system", "system"),
    "host": (" --source host:" + LOCATION_GUEST_SOCKET, "gps", "gps"),
}


def gnss_source(policy=None):
    """return this profile's gnss HAL source"""
    if policy is None:
        policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if policy.scope("rhizo.profile") == "server":
        return "operator"
    return "host" if policy.allows("devices.location") else None


def gnss_source_marked():
    """return and log the gnss HAL's source"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    source = gnss_source(policy)
    kmsg(f"RHIZO_MARKER location_source={source or 'off'}")
    if source == "operator" and policy.allows("devices.location"):
        kmsg("RHIZO_MARKER location_capability=ignored -- the server profile reports only the operator's fix")
    return source


def gnss_armed():
    """return true when the profile starts the gnss HAL"""
    return gnss_source() is not None


def gnss_feature_xml(source, network_provider=True):
    """return the location feature file of a gnss source"""
    names = [n for n in GNSS_FEATURES[source] if network_provider or n != NETWORK_LOCATION_FEATURE]
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            "<permissions>\n"
            + "".join('    <feature name="%s" />\n' % name for name in names)
            + "</permissions>\n")


def _stage_network_location(upper, vendor_file_contexts_path, apk_src):
    """stage the network location provider as a priv-app"""
    if not os.path.exists(apk_src):
        kmsg(f"RHIZO_MARKER network_location=absent apk={apk_src} -- no network provider, "
             f"no {NETWORK_LOCATION_FEATURE}")
        return False
    for d in ("priv-app/RhizoNetworkLocation", "etc/default-permissions"):
        os.makedirs(os.path.join(upper, d), exist_ok=True)
    dst = os.path.join(upper, "priv-app/RhizoNetworkLocation", NETWORK_LOCATION_APK)
    shutil.copy(apk_src, dst)
    os.chmod(dst, 0o644)
    with open(os.path.join(upper, "etc/default-permissions/default-permissions-rhizo-networklocation.xml"),
              "w") as f:
        f.write(guest_files.read("permissions/default-permissions-networklocation.xml"))
    with open(vendor_file_contexts_path, "a") as f:
        f.write("/system_ext/priv-app/RhizoNetworkLocation/RhizoNetworkLocation\\.apk "
                "u:object_r:system_file:s0\n")
    kmsg("RHIZO_MARKER network_location=staged apk=/system_ext/priv-app/RhizoNetworkLocation")
    return True


def stage_network_location():
    """stage the network location provider"""
    return _stage_network_location(
        f"{RUN_ROOT}/system_ext_upper",
        f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts",
        beside("RhizoNetworkLocation.apk"))


def network_location_armed():
    """return true when the launch stages the network location provider"""
    return gnss_source() == "host" and os.path.exists(beside("RhizoNetworkLocation.apk"))


def gnss_service_rc(source):
    """return the init service of a gnss source"""
    argv, user, group = GNSS_SERVICE[source]
    return ("service vendor.rhizo-gnss /vendor/bin/hw/rhizo-gnss-service%s\n"
            "    class core\n"
            "    user %s\n"
            "    group %s\n"
            "    stdio_to_kmsg\n" % (argv, user, group))


HEALTH_SERVICE_ARGV = {"operator": "", "off": "", "host": " --source host"}


def battery_source(policy=None):
    """return this profile's health HAL battery source"""
    if policy is None:
        policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    profile = policy.scope("rhizo.profile")
    if profile == "server":
        return "operator"
    return "host" if policy.allows("devices.battery") else "off"


def battery_source_marked():
    """return and log the health HAL's battery source"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    source = battery_source(policy)
    kmsg(f"RHIZO_MARKER battery_source={source}")
    if source == "operator" and policy.allows("devices.battery"):
        kmsg("RHIZO_MARKER battery_capability=ignored -- the server profile reports only the operator's battery")
    return source


def health_service_rc(source):
    """return the init service of a battery source"""
    return ("service vendor.rhizo-health /vendor/bin/hw/rhizo-health-service%s\n"
            "    class core\n"
            "    user system\n"
            "    group system\n"
            "    stdio_to_kmsg\n" % HEALTH_SERVICE_ARGV[source])


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


CAMERA_MANIFEST_HAL = (
    '    <hal format="aidl">\n'
    '        <name>android.hardware.camera.provider</name>\n'
    '        <version>3</version>\n'
    '        <fqname>ICameraProvider/internal/0</fqname>\n'
    '    </hal>\n'
)
CAMERA_SOCKET_CONTEXTS = "/dev/socket/rhizo_camera(/.*)? u:object_r:rhizo_camera_socket:s0\n"


def _stage_camera(vendor_init, system_ext_init, permissions, vendor_file_contexts_path, vendor_etc):
    """stage the camera provider's rc, socket label, features and profiles"""
    for d in (vendor_init, system_ext_init, permissions, vendor_etc):
        os.makedirs(d, exist_ok=True)
    with open(os.path.join(vendor_init, "rhizo-camera-provider.rc"), "w") as f:
        f.write(guest_files.render(guest_files.read("init/camera-provider.rc"),
                                   whole={"early_init_restorecon": core.early_init_restorecon(
                                       f"/vendor/bin/hw/{core.CAMERA_PROVIDER}")},
                                   comment_prefix="#"))
    with open(os.path.join(system_ext_init, "rhizo-camera-socket.rc"), "w") as f:
        f.write(guest_files.read("init/camera-socket.rc"))
    with open(os.path.join(permissions, "rhizo-camera.xml"), "w") as f:
        f.write(guest_files.read("permissions/camera.xml"))
    # MediaProfiles falls back to H.263 CIF in 3GPP without this file
    with open(os.path.join(vendor_etc, "media_profiles_V1_0.xml"), "w") as f:
        f.write(guest_files.read("vendor/media_profiles_V1_0.xml"))
    with open(vendor_file_contexts_path, "a") as f:
        f.write(CAMERA_SOCKET_CONTEXTS)
    kmsg("RHIZO_MARKER camera=staged provider=ICameraProvider/internal/0 features=camera.any,camera.external"
         " media_profiles=h264+aac/mp4")
    return True


def stage_camera():
    """stage the camera provider while devices.camera is on"""
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if not policy.allows("devices.camera"):
        kmsg("RHIZO_MARKER camera=off")
        return False
    if not core.camera_armed():
        kmsg(f"RHIZO_MARKER camera=absent provider={core.CAMERA_PROVIDER_SRC}")
        return False
    return _stage_camera(f"{RUN_ROOT}/vendor/etc/init", f"{RUN_ROOT}/system_ext_upper/etc/init",
                         f"{RUN_ROOT}/product_upper/etc/permissions",
                         f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", f"{RUN_ROOT}/vendor/etc")


SENSORS_MANIFEST_HAL = (
    '    <hal format="aidl">\n'
    '        <name>android.hardware.sensors</name>\n'
    '        <version>3</version>\n'
    '        <fqname>ISensors/default</fqname>\n'
    '    </hal>\n'
)
SENSORS_EXEC_LABEL = "u:object_r:rhizo_sensors_exec:s0"
SENSORS_FILES = ("vendor/etc/rhizo-sensors.conf", "vendor/etc/init/rhizo-sensors.rc",
                 "product_upper/etc/permissions/rhizo-sensors.xml")


def stage_sensors_hal_bin():
    """stage the sensors HAL binary and its label"""
    src = core.sensors_hal_source()
    dst = f"{RUN_ROOT}/vendor/bin/hw/{core.SENSORS_BIN}"
    if src is None:
        kmsg(f"RHIZO_MARKER sensors_hal_bin=none release={core.RHIZO_RELEASE}")
        return False
    if core.is_prepared_bind_path(dst) and not os.path.exists(dst):
        kmsg("RHIZO_MARKER sensors_hal_bin=none reason=not-in-prepared-tree")
        return False
    core.stage_bulk(src, dst, 0o755)
    with open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
        f.write(f"/vendor/bin/hw/{core.SENSORS_BIN} {SENSORS_EXEC_LABEL}\n")
    kmsg(f"RHIZO_MARKER sensors_hal_bin=staged path=/vendor/bin/hw/{core.SENSORS_BIN}")
    return True


def _stage_sensors(root, plan):
    """stage the files of a non-empty sensor plan"""
    conf, rc, features = (os.path.join(root, rel) for rel in SENSORS_FILES)
    for d in (conf, rc, features):
        os.makedirs(os.path.dirname(d), exist_ok=True)
    with open(conf, "w") as f:
        f.write(sensors.render_conf(plan))
    with open(rc, "w") as f:
        f.write(guest_files.render(guest_files.read("init/sensors.rc"),
                                   whole={"early_init_restorecon": core.early_init_restorecon(
                                       f"/vendor/bin/hw/{core.SENSORS_BIN}")},
                                   comment_prefix="#"))
    with open(features, "w") as f:
        f.write(sensors.feature_xml(plan))
    with open(os.path.join(root, "vendor/etc/selinux/vendor_file_contexts"), "a") as f:
        f.write("/vendor/etc/rhizo-sensors\\.conf u:object_r:vendor_configs_file:s0\n"
                f"{core.SENSORS_GUEST_DIR} {core.SENSORS_GUEST_DIR_LABEL}\n")
    kmsg(f"RHIZO_MARKER sensors_shape=staged count={len(plan)} kinds={','.join(sensors.kinds_of(plan))}")
    return True


def stage_sensors(root=None):
    """stage or remove the sensors HAL's per-launch files"""
    root = root or RUN_ROOT
    plan = core.sensors_plan()
    if plan:
        return _stage_sensors(root, plan)
    for rel in SENSORS_FILES:
        try:
            os.unlink(os.path.join(root, rel))
        except FileNotFoundError:
            pass
    return False


def vendor_manifest_xml():
    """return the /vendor/manifest.xml text"""
    text = guest_files.read("vendor/manifest.xml")
    if core.RHIZO_RELEASE == "a15":
        # a15's framework matrix accepts vendor sepolicy up to 202404; 202504 fails isBuildConsistent()
        text = text.replace("<version>202504</version>", "<version>202404</version>")
    if gnss_armed():
        text = text.replace("</manifest>", GNSS_MANIFEST_HAL + "</manifest>")
    if core.camera_armed():
        text = text.replace("</manifest>", CAMERA_MANIFEST_HAL + "</manifest>")
    if core.wifi_armed():
        text = text.replace("</manifest>", guest_files.read("vendor/manifest-wifi.xml") + "</manifest>")
    if core.sensors_armed():
        text = text.replace("</manifest>", SENSORS_MANIFEST_HAL + "</manifest>")
    if core.codec2_armed():
        text = text.replace("</manifest>", guest_files.read("vendor/manifest-codec2.xml") + "</manifest>")
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
