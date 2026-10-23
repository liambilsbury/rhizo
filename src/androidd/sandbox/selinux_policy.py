import os
import re
from sandbox import guest_files

CIL_FILENAME = "sepolicy/policy.cil"

SOFTWARE_CIL_FILENAME = "sepolicy/policy-software.cil"

PUBLIC_CIL_FILENAME = "plat_pub_versioned.cil"

DEV_TYPES = ("port_device", "udmabuf_device")

OPTIONAL_TYPES = ("sysfs_ublk", "priv_app_36")

OPTIONAL_POLICYCAPS = ("netlink_xperm",)

CAP2_ALL = ("block_suspend", "audit_read", "syslog", "wake_alarm", "bpf",
            "perfmon", "checkpoint_restore")

WAKEUP_CLASS = "/sys/class/wakeup"
WAKEUP_GENFSCON = '(genfscon sysfs "%s" (u object_r sysfs_wakeup ((s0) (s0))))\n'
NAMESPACE_LABEL_SERVICE = (
    "(type rhizo_input_label)\n"
    "(roletype object_r rhizo_input_label)\n"
    "(typeattributeset domain (rhizo_input_label))\n"
    "(allow kernel self (process (setcurrent)))\n"
    "(allow kernel rhizo_input_label (process (dyntransition)))\n"
    "(allow rhizo_input_label kernel (unix_stream_socket (read write)))\n"
    "(allow rhizo_input_label rootfs (dir (search)))\n"
    "(allow rhizo_input_label device (dir (search)))\n"
    "(allow rhizo_input_label input_device (dir (search)))\n"
    "(allow rhizo_input_label input_device (chr_file (getattr)))\n"
    "(allow rhizo_input_label rhizo_host_device (chr_file (getattr relabelfrom)))\n"
    "(allow rhizo_input_label hidraw_device (chr_file (getattr relabelto)))\n"
    "(allow rhizo_input_label proc (filesystem (getattr)))\n"
    "(allow rhizo_input_label proc (dir (search)))\n"
    "(allow rhizo_input_label proc (lnk_file (read)))\n"
    "(allow rhizo_input_label self (dir (search)))\n"
    "(allow rhizo_input_label self (lnk_file (read)))\n"
    "(validatetrans chr_file (or (not (eq t3 rhizo_input_label)) (eq t2 hidraw_device)))\n"
    "(deny domain rhizo_input_label (process (ptrace sigkill sigstop signal)))\n"
    "(typeattribute rhizo_input_label_guard)\n"
    "(typeattributeset rhizo_input_label_guard (all))\n"
    "(neverallow rhizo_input_label_guard rhizo_input_label (process (ptrace sigkill sigstop signal)))\n"
)
RELABEL_WALKED_DIRS = {
    "getattr open read search": (
        "block_device", "boringssl_self_test_marker", "device", "dmabuf_heap_device", "gpu_device", "input_device",
        "libprocessgroup_metadata_file", "media_rw_data_file", "properties_device", "rhizo_audio_socket",
        "rhizo_device_state_file", "rhizo_wayland_socket", "same_process_hal_file", "socket_device",
        "statsd_atoms_list_file", "system_aconfig_storage_file", "system_bootstrap_lib_file", "system_file",
        "system_lib_file", "system_perfetto_config_file", "system_seccomp_policy_file", "system_security_cacerts_file",
        "system_zoneinfo_file", "usb_device", "vendor_configs_file", "vendor_hal_file", "vendor_idc_file",
        "vendor_overlay_file", "vndk_sp_file",),
    "getattr search": (
        "apex_mnt_dir", "rhizo_wakeup_reasons_shadow", "system_data_file", "system_data_root_file",
        "system_userdir_file", "vendor_data_file", "vendor_userdir_file",),
    "search": (
        "cgroup_rc_file", "linkerconfig_file", "media_userdir_file", "metadata_file",),
    "getattr open read": (
        "audio_device", "fscklogs", "ot_daemon_socket", "rhizo_stream_socket",),
    "open read search": (
        "dm_user_device",),
}
DOMAIN_WALKED_DIRS = ("aconfig_storage_metadata_file", "coredump_file")
DOMAIN_WALK_PERMS = "getattr open read search"
WALK_RULE = "(optional rhizo_ns_walk_{type}\n(allow rhizo_ns_relabel {type} (dir ({perms})))\n)\n"
RELABEL_WALKED_DIR_RULES = "".join(
    WALK_RULE.format(type=t, perms=perms) for perms, types in RELABEL_WALKED_DIRS.items() for t in types)
_DOMAIN_DIR_RULE = re.compile(r"\(allow domain (\S+) \(dir \(([^()]*)\)\)\)")
NAMESPACE_HELPER_DOMAINS = RELABEL_WALKED_DIR_RULES + """; the helper types are outside domain and coredomain
(typeattribute rhizo_ns_helper)
(type rhizo_ns_stage)
(type rhizo_ns_relabel)
(type rhizo_ns_label)
(typeattributeset rhizo_ns_helper (rhizo_ns_stage rhizo_ns_relabel rhizo_ns_label))
(roletype r rhizo_ns_stage)
(roletype r rhizo_ns_relabel)
(roletype r rhizo_ns_label)
(roletype object_r rhizo_ns_stage)
(roletype object_r rhizo_ns_relabel)
(roletype object_r rhizo_ns_label)
(allow kernel self (process (setcurrent)))
(allow kernel rhizo_ns_helper (process (dyntransition)))

; rights of all of the helper domains
(allow rhizo_ns_helper self (process (fork sigchld getattr getcap setcap getpgid setpgid getsession setrlimit signull)))
(allow rhizo_ns_helper self (fd (use)))
(allow rhizo_ns_helper self (dir (getattr open read search)))
(allow rhizo_ns_helper self (file (getattr open read write)))
(allow rhizo_ns_helper self (lnk_file (getattr read)))
(allow rhizo_ns_helper self (fifo_file (getattr open read write ioctl append)))
(allowx rhizo_ns_helper self (ioctl fifo_file (0x5401)))
(allow rhizo_ns_helper kernel (fd (use)))
(allow rhizo_ns_helper kernel (fifo_file (getattr open read write ioctl append)))
(allow rhizo_ns_helper kernel (file (getattr read write)))
(allow rhizo_ns_helper kernel (unix_stream_socket (getattr read write)))
(allowx rhizo_ns_helper kernel (ioctl fifo_file (0x5401)))
(allow rhizo_ns_helper unlabeled (file (getattr open read map execute execute_no_trans ioctl)))
(allowx rhizo_ns_helper unlabeled (ioctl file (0x5401)))
; allow FIOCLEX on host scripts
(allowx rhizo_ns_helper unlabeled (ioctl file (0x5451)))
(allow rhizo_ns_helper unlabeled (dir (getattr open read search)))
(allow rhizo_ns_helper unlabeled (lnk_file (getattr read)))
(allow rhizo_ns_helper init (process (sigchld)))
; setpcap for the verbs' capability drops
(allow rhizo_ns_helper self (capability (setpcap)))
; probes of proc, sysfs and selinuxfs
(allow rhizo_ns_helper proc (dir (search)))
(allow rhizo_ns_helper proc (lnk_file (read)))
(allow rhizo_ns_helper proc (filesystem (getattr)))
(allow rhizo_ns_helper labeledfs (filesystem (getattr)))
(allow rhizo_ns_helper sysfs (dir (search)))
(allow rhizo_ns_helper selinuxfs (filesystem (getattr)))

; rights of stage-gsi-labeled and its cp -a
(allow rhizo_ns_stage self (process (setfscreate)))
(allow rhizo_ns_stage self (capability (chown fowner fsetid)))
; leave dac_read_search and setfcap unlogged
(dontaudit rhizo_ns_stage self (capability (dac_read_search setfcap)))
(allow rhizo_ns_stage unlabeled (dir (add_name write)))
(allow rhizo_ns_stage rootfs (dir (search)))
(allow rhizo_ns_stage system_file_type (dir (getattr open read search add_name create write setattr)))
(allow rhizo_ns_stage vendor_file_type (dir (getattr open read search add_name create write setattr)))
(allow rhizo_ns_stage system_file_type (file (getattr open read ioctl create write setattr)))
(allow rhizo_ns_stage exec_type (file (getattr open read ioctl create write setattr)))
(allow rhizo_ns_stage vendor_file_type (file (getattr open read ioctl create write setattr)))
(allow rhizo_ns_stage system_file_type (lnk_file (getattr read create setattr)))
(allow rhizo_ns_stage vendor_file_type (lnk_file (getattr read create setattr)))
(allowx rhizo_ns_stage system_file_type (ioctl file (0x9409)))
(allowx rhizo_ns_stage exec_type (ioctl file (0x9409)))
(allowx rhizo_ns_stage vendor_file_type (ioctl file (0x9409)))

; rights of the relabeller, its primer, the stagers and the vendor prelabel
(allow rhizo_ns_relabel self (capability (chown fowner sys_admin sys_chroot)))
(dontaudit rhizo_ns_relabel self (capability (dac_read_search)))
(dontaudit rhizo_ns_relabel kernel (security (setenforce)))
; allow the cpu affinity read of python's start
(allow rhizo_ns_relabel self (process (getsched)))
; allow the overcommit sysctl read of python's allocator
(allow rhizo_ns_relabel proc_overcommit_memory (file (open read)))
; allow the terminal probes of python's stdio
(allow rhizo_ns_relabel self (file (ioctl)))
(allowx rhizo_ns_relabel self (ioctl file (0x5401)))
(allowx rhizo_ns_relabel self (ioctl fifo_file (0x542a)))
(allow rhizo_ns_relabel kernel (file (ioctl)))
(allowx rhizo_ns_relabel kernel (ioctl file (0x5401)))
(allowx rhizo_ns_relabel kernel (ioctl fifo_file (0x5413)))
(allow rhizo_ns_relabel unlabeled (chr_file (getattr open write ioctl)))
(allowx rhizo_ns_relabel unlabeled (ioctl chr_file (0x5401)))
(allow rhizo_ns_relabel rhizo_relabel_dest_file (file (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_file (lnk_file (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_file (dir (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_dev (chr_file (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_dev (blk_file (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_dev (lnk_file (relabelto)))
(allow rhizo_ns_relabel rhizo_relabel_dest_dev (dir (relabelto)))
(allow rhizo_ns_relabel rootfs (lnk_file (relabelto)))
(allow rhizo_ns_relabel rootfs (dir (relabelto)))
(allow rhizo_ns_relabel tmpfs (dir (relabelto)))
(allow rhizo_ns_relabel device (file (getattr relabelto)))
(allow rhizo_ns_relabel device (dir (relabelfrom)))
(allow rhizo_ns_relabel proc_sysrq (file (getattr relabelto)))
(allow rhizo_ns_relabel proc_bpf (file (getattr)))
(allow rhizo_ns_relabel proc_security (file (getattr)))
(allow rhizo_ns_relabel rhizo_wakeup_reasons_shadow (dir (relabelto getattr)))
(allow rhizo_ns_relabel rhizo_wakeup_reasons_shadow (file (relabelto getattr)))
(allow rhizo_ns_relabel rhizo_enforce_shadow (file (relabelto getattr)))
(allow rhizo_ns_relabel rhizo_power_shadow (file (relabelto getattr)))
(allow rhizo_ns_relabel apex_data_file (dir (relabelto)))
(allow rhizo_ns_relabel tmpfs (dir (relabelfrom)))
(allow rhizo_ns_relabel tmpfs (file (relabelfrom)))
(allow rhizo_ns_relabel tmpfs (lnk_file (relabelfrom)))
(allow rhizo_ns_relabel tmpfs (chr_file (relabelfrom)))
(allow rhizo_ns_relabel tmpfs (blk_file (relabelfrom)))
(allow rhizo_ns_relabel tmpfs (dir (getattr open read search)))
(allow rhizo_ns_relabel tmpfs (file (getattr)))
(allow rhizo_ns_relabel tmpfs (lnk_file (getattr)))
(allow rhizo_ns_relabel tmpfs (chr_file (getattr)))
(allow rhizo_ns_relabel tmpfs (blk_file (getattr)))
(allow rhizo_ns_relabel system_file (file (getattr open read relabelto ioctl)))
(allowx rhizo_ns_relabel system_file (ioctl file (0x5401)))
(allow rhizo_ns_relabel file_contexts_file (file (getattr open read map ioctl)))
(allowx rhizo_ns_relabel file_contexts_file (ioctl file (0x5401)))
(allow rhizo_ns_relabel rhizo_host_device (chr_file (relabelfrom)))
(allow rhizo_ns_relabel rootfs (dir (getattr open read search)))
(allow rhizo_ns_relabel rootfs (file (getattr open read)))
(allow rhizo_ns_relabel rootfs (lnk_file (getattr open read)))
(allow rhizo_ns_relabel vendor_file_type (dir (getattr open read search relabelto)))
(allow rhizo_ns_relabel vendor_file_type (file (getattr relabelto)))
(allow rhizo_ns_relabel vendor_file_type (lnk_file (getattr read relabelto)))
(allow rhizo_ns_relabel unlabeled (dir (getattr open read search write add_name remove_name create rmdir mounton relabelfrom)))
(allow rhizo_ns_relabel unlabeled (file (getattr open read write create unlink rename setattr append relabelfrom)))
(allow rhizo_ns_relabel unlabeled (lnk_file (getattr read create unlink relabelfrom)))
(allow rhizo_ns_relabel unlabeled (sock_file (write)))
(allow rhizo_ns_relabel file_type (file (getattr)))
(allow rhizo_ns_relabel file_type (lnk_file (getattr)))
(allow rhizo_ns_relabel file_type (sock_file (getattr)))
(allow rhizo_ns_relabel dev_type (chr_file (getattr)))
(allow rhizo_ns_relabel dev_type (blk_file (getattr)))
(allow rhizo_ns_relabel devpts (chr_file (getattr)))
(allow rhizo_ns_relabel property_type (file (getattr)))
(allow rhizo_ns_relabel selinuxfs (filesystem (mount)))
(allow rhizo_ns_relabel selinuxfs (file (getattr open read write)))
(allow rhizo_ns_relabel selinuxfs (dir (getattr open read search)))
(allow rhizo_ns_relabel tmpfs (filesystem (unmount)))
; allow the walk's probes of mounts and symlinks
(allow rhizo_ns_relabel tmpfs (filesystem (getattr)))
(allow rhizo_ns_relabel device (filesystem (getattr)))
(allow rhizo_ns_relabel devpts (filesystem (getattr)))
(allow rhizo_ns_relabel devpts (dir (search)))
(allow rhizo_ns_relabel proc (dir (getattr)))
(allow rhizo_ns_relabel proc_net (dir (search)))
(allow rhizo_ns_relabel device (lnk_file (getattr read)))
(allow rhizo_ns_relabel ptmx_device (lnk_file (getattr read)))
(allow rhizo_ns_relabel block_device (lnk_file (getattr read)))
(allow rhizo_ns_relabel binder_device (lnk_file (getattr read)))
(allow rhizo_ns_relabel hwbinder_device (lnk_file (getattr read)))
(allow rhizo_ns_relabel vndbinder_device (lnk_file (getattr read)))
(allow rhizo_ns_relabel properties_serial (file (getattr)))
(allow rhizo_ns_relabel property_info (file (getattr)))
(allow rhizo_ns_relabel system_file (lnk_file (read)))
(allow rhizo_ns_relabel system_lib_file (lnk_file (read)))
(allow rhizo_ns_relabel system_linker_exec (lnk_file (read)))
(allow rhizo_ns_relabel self (unix_stream_socket (create connect)))
; allow the primer's ctypes closure mapping
(allow rhizo_ns_relabel self (process (execmem)))
; allow stdio writes to /dev/null
(allow rhizo_ns_relabel null_device (chr_file (write)))
(allow rhizo_ns_relabel tmpfs (chr_file (write)))
; allow primer script and symlink reads on tmpfs
(allow rhizo_ns_relabel tmpfs (file (open read ioctl write map execute)))
(allowx rhizo_ns_relabel tmpfs (ioctl file (0x5401 0x5451 0x542a)))
(allow rhizo_ns_relabel tmpfs (lnk_file (read)))
; allow the relabeled host device nodes
(allow rhizo_ns_relabel rhizo_host_kmsg_device (chr_file (relabelto open write ioctl)))
(allowx rhizo_ns_relabel rhizo_host_kmsg_device (ioctl chr_file (0x5401 0x542a)))
(allow rhizo_ns_relabel null_device (chr_file (ioctl)))
(allowx rhizo_ns_relabel null_device (ioctl chr_file (0x5401 0x542a)))
(allow null_device device (filesystem (associate)))

; rights of the label, label-fd and hostfs-label-lower verbs
(allow rhizo_ns_label self (capability (setuid sys_ptrace sys_admin sys_chroot)))
(allow rhizo_ns_label rhizo_inbox_file (file (getattr relabelto)))
; allow labeling files in the device-state directory
(allow rhizo_ns_label rhizo_device_state_file (dir (search)))
(allow rhizo_ns_label rhizo_device_state_file (file (getattr relabelto)))
(allow rhizo_ns_label unlabeled (file (relabelfrom)))
(allow rhizo_ns_label init (dir (search)))
(allow rhizo_ns_label init (lnk_file (read)))
(allow rhizo_ns_label system_data_root_file (dir (getattr search)))
(allow rhizo_ns_label media_userdir_file (dir (search)))
(allow rhizo_ns_label media_rw_data_file (dir (getattr search add_name remove_name write create setattr rmdir relabelfrom relabelto)))
(allow rhizo_ns_label rootfs (dir (search)))
(allow rhizo_ns_label self (capability (setgid)))
(allow rhizo_ns_label self (unix_stream_socket (create connect)))
; allow the terminal probes of the verbs' stdio
(allow rhizo_ns_label unlabeled (chr_file (getattr ioctl)))
(allowx rhizo_ns_label unlabeled (ioctl chr_file (0x5401)))
(allowx rhizo_ns_label kernel (ioctl fifo_file (0x5413)))
"""
NAMESPACE_MESA_PROPS = (
    "(type vendor_rhizo_mesa_prop)\n"
    "(roletype object_r vendor_rhizo_mesa_prop)\n"
    "(typeattributeset property_type (vendor_rhizo_mesa_prop))\n"
    "(typeattributeset vendor_property_type (vendor_rhizo_mesa_prop))\n"
    "(typeattributeset vendor_restricted_property_type (vendor_rhizo_mesa_prop))\n"
    "(allow domain vendor_rhizo_mesa_prop (file (read open getattr map)))\n"
)
NAMESPACE_PROPERTY_CONTEXTS = "vendor.mesa. u:object_r:vendor_rhizo_mesa_prop:s0 prefix\n"
_GENFS_SYSFS = re.compile(r'^\(genfscon sysfs "([^"]+)" (?:\w+ )?\(\w+ \w+ (\w+) ', re.M)
_SYSFS_DEVICE_PATH = re.compile(r"/devices(?:/[A-Za-z0-9_.:@+,=-]+)+")
_WAKEUP_SOURCE_DIR = re.compile(r"wakeup[0-9]+")

FTRACE_GUARD = (
    "(deny init debugfs_tracing_debug (filesystem (mount remount)))\n"
    "(deny init debugfs (filesystem (mount remount)))\n"
    "(typeattribute rhizo_ftrace_guard)\n"
    "(typeattributeset rhizo_ftrace_guard (and (all) (not (rhizo_host))))\n"
    "(neverallow rhizo_ftrace_guard debugfs_tracing_debug (filesystem (mount remount)))\n"
    "(neverallow rhizo_ftrace_guard debugfs (filesystem (mount remount)))\n"
)


def declares_type(cils, type_name):
    """search the CILs for a type declaration"""
    needle = f"(type {type_name})"
    return any(needle in open(c).read() for c in cils)


def declares_policycap(cils, cap):
    """search the CILs for a policy capability"""
    needle = f"(policycap {cap})"
    return any(needle in open(c).read() for c in cils)


def platform_opens_ashmem(cils):
    """search the CILs for an open of the libcutils ashmem device granted to domain"""
    rule = re.compile(r"\(allow domain ashmem_libcutils_device \(chr_file \(([^)]*)\)\)\)")
    return any("open" in m.group(1).split() for c in cils for m in rule.finditer(open(c).read()))


def declares_perm(cils, common_name, perm):
    """search the common for a permission"""
    needle = f"(common {common_name} ("
    for c in cils:
        text = open(c).read()
        i = text.find(needle)
        if i == -1:
            continue
        close = text.index("))", i)
        if perm in text[i + len(needle):close].split():
            return True
    return False


def derive(cils):
    """return the device carveout and cap2 filter"""
    dev_carveout = " ".join(t for t in DEV_TYPES if declares_type(cils, t))
    declared = {p for p in CAP2_ALL if declares_perm(cils, "cap2", p)}

    def cap2(*wanted):
        """return the wanted capabilities the policy declares"""
        return " ".join(p for p in wanted if p in declared)

    return dev_carveout, cap2


def sysfs_genfs(texts):
    """return each sysfs genfscon's path and type"""
    return [m.groups() for text in texts for m in _GENFS_SYSFS.finditer(text)]


def sysfs_label(genfs, path):
    """return a sysfs path's genfscon type"""
    best = ("", "sysfs")
    for prefix, label in genfs:
        if path.startswith(prefix) and len(prefix) > len(best[0]):
            best = (prefix, label)
    return best[1]


def host_wakeup_genfs(cils, log, path=None):
    """return the host's wakeup genfscons for the cils and template"""
    template = open(path).read() if path else guest_files.read(CIL_FILENAME)
    return wakeup_genfscons([open(c).read() for c in cils] + [template], WAKEUP_CLASS, log)


def wakeup_genfscons(texts, class_dir, log):
    """return sysfs_wakeup genfscons for plain-sysfs wakeup sources"""
    try:
        names = sorted(os.listdir(class_dir))
    except FileNotFoundError:
        return ""
    except OSError as e:
        log(f"RHIZO_MARKER wakeup_genfs=failed reason=cannot list {class_dir}: {e.strerror}")
        return ""
    genfs = sysfs_genfs(texts)
    root = os.path.realpath(os.path.join(class_dir, "..", ".."))
    labeled = set()
    for name in names:
        path = "/" + os.path.relpath(os.path.realpath(os.path.join(class_dir, name)), root)
        if sysfs_label(genfs, path) != "sysfs":
            continue
        if not _SYSFS_DEVICE_PATH.fullmatch(path) or not _WAKEUP_SOURCE_DIR.fullmatch(os.path.basename(path)):
            log(f"RHIZO_MARKER wakeup_genfs=skipped source={name} path={path!r} -- not labeled: "
                "not a plain /devices/.../wakeupN path")
            continue
        parent = os.path.dirname(path)
        labeled.add(parent if os.path.basename(parent) == "wakeup" else parent + "/wakeup")
    return "".join(WAKEUP_GENFSCON % p for p in sorted(labeled))


def vendor_property_contexts(namespace):
    """return the mode's vendor property_contexts text"""
    return NAMESPACE_PROPERTY_CONTEXTS if namespace else ""


def domain_walked_dir_rules(cils):
    """return the walk rules for the types the cils let domain walk"""
    walked = set()
    for c in cils:
        for m in _DOMAIN_DIR_RULE.finditer(open(c).read()):
            if m.group(1) in DOMAIN_WALKED_DIRS and set(DOMAIN_WALK_PERMS.split()) <= set(m.group(2).split()):
                walked.add(m.group(1))
    return "".join(WALK_RULE.format(type=t, perms=DOMAIN_WALK_PERMS) for t in sorted(walked))


def render(template, dev_carveout, cap2, declared=frozenset(), ftrace=False, namespace=False, wakeup_genfs="",
           domain_walks=""):
    """render the policy template for a release"""
    whole = {
        "ftrace_guard": "" if ftrace else FTRACE_GUARD,
        "namespace_label_service": NAMESPACE_LABEL_SERVICE if namespace else "",
        "namespace_helper_domains": NAMESPACE_HELPER_DOMAINS + domain_walks if namespace else "",
        "namespace_mesa_props": NAMESPACE_MESA_PROPS if namespace else "",
        "host_wakeup_genfs": wakeup_genfs,
        "sysfs_uinput_mirror": SYSFS_MIRROR_ANCHOR,
        "late_block_ublk":
            "(allow kernel sysfs_ublk (file (getattr mounton)))\n"
            "(allow rhizo_host sysfs_ublk (file (getattr mounton)))\n"
            if "sysfs_ublk" in declared else "",
        "vold_uevent_ublk":
            "(deny vold sysfs_ublk (file (write append)))\n"
            "(dontaudit vold sysfs_ublk (file (write append)))\n"
            if "sysfs_ublk" in declared else "",
        "priv_app_36_grants":
            "".join(line.replace("(allow priv_app ", "(allow priv_app_36 ", 1)
                    for line in template.splitlines(keepends=True) if line.startswith("(allow priv_app "))
            if "priv_app_36" in declared else "",
        "host_netlink_nlmsg":
            "(allow rhizo_host self (netlink_route_socket (nlmsg)))\n"
            "(allowx rhizo_host self (nlmsg netlink_route_socket ((range 0x0 0xffff))))\n"
            "(allow rhizo_host self (netlink_audit_socket (nlmsg)))\n"
            if "netlink_xperm" in declared else "",
        "vendor_ashmem_open":
            "(allow domain ashmem_libcutils_device (chr_file (open)))\n"
            if "vendor_ashmem_open" in declared else "",
        "dev_ok_rule":
            f"(typeattributeset rhizo_dev_ok (and (dev_type) (not ({dev_carveout}))))\n"
            if dev_carveout else "(typeattributeset rhizo_dev_ok (dev_type))\n",
        "cap2_checkpoint_restore":
            f"(allow rhizo_host self (capability2 ({cap2('checkpoint_restore')})))\n"
            if cap2("checkpoint_restore") else "",
        "cap2_bpf_perfmon":
            f"(allow rhizo_host self (capability2 ({cap2('bpf', 'perfmon')})))\n"
            if cap2("bpf", "perfmon") else "",
        "cap2_netd_bpf":
            f"(allow netd self (capability2 ({cap2('bpf')})))\n"
            if cap2("bpf") else "",
    }
    inline = {
        "cap2_carveout": cap2("block_suspend", "audit_read", "syslog",
                              "wake_alarm", "bpf", "perfmon"),
        "cap2_syslog": cap2("syslog"),
    }
    return guest_files.render(template, whole, inline, comment_prefix=";")


LIVE_KEYMINT_TT = "(typetransition init rhizo_keymint_exec process hal_keymint_system)\n"
CTS_KEYMINT_BLOCK = (
    "(type rhizo_keymint)\n"
    "(roletype object_r rhizo_keymint)\n"
    "(typeattributeset domain (rhizo_keymint))\n"
    "(typeattributeset halserverdomain (rhizo_keymint))\n"
    "(typeattributeset hal_keymint (rhizo_keymint))\n"
    "(typeattributeset hal_keymint_server (rhizo_keymint))\n"
    "(typetransition init rhizo_keymint_exec process rhizo_keymint)\n"
)


_DEV_OK_RE = re.compile(
    r"\(typeattributeset rhizo_dev_ok \(and \(dev_type\) \(not \(([^)]*)\)\)\)\)")


def _drop_udmabuf_from_dev_ok(rendered):
    """remove udmabuf_device from the rhizo_dev_ok exclusion list"""
    def repl(m):
        """rebuild the rhizo_dev_ok line without udmabuf_device"""
        types = [t for t in m.group(1).split() if t != "udmabuf_device"]
        if not types:
            return "(typeattributeset rhizo_dev_ok (dev_type))"
        return f"(typeattributeset rhizo_dev_ok (and (dev_type) (not ({' '.join(types)}))))"
    return _DEV_OK_RE.sub(repl, rendered)


_CIL_TOKEN = re.compile(r';[^\n]*|"[^"]*"|[()]|[^\s();"]+')

AV_RULE_HEADS = ("allow", "allowx", "auditallow", "deny", "dontaudit", "neverallow")


def _drop_statements_naming(rendered, types):
    """remove the AV rules naming one of types"""
    if not types:
        return rendered
    out, depth, start, kept_to, head, prev, names = [], 0, 0, 0, None, None, set()
    for m in _CIL_TOKEN.finditer(rendered):
        token = m.group()
        if token[0] == ";":
            continue
        if token == "(":
            if depth == 0:
                start, head, names = m.start(), None, set()
            depth += 1
        elif token == ")":
            depth -= 1
            if depth < 0:
                raise ValueError(f"a ) at offset {m.start()} closes no statement")
            if depth == 0 and names & types:
                if head not in AV_RULE_HEADS:
                    raise ValueError(
                        f"{rendered[start:m.end()]} names {sorted(names & types)} outside an AV rule "
                        f"({', '.join(AV_RULE_HEADS)})")
                out.append(rendered[kept_to:start])
                kept_to = m.end() + (rendered[m.end():m.end() + 1] == "\n")
        elif token[0] != '"':
            if depth == 1 and prev == "(":
                head = token
            names.add(token)
        prev = token
    out.append(rendered[kept_to:])
    return "".join(out)


def public_cil_path():
    """return the path of plat_pub_versioned.cil"""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    beside = os.path.join(here, PUBLIC_CIL_FILENAME)
    built = os.path.normpath(os.path.join(here, "..", "..", "var", "share", PUBLIC_CIL_FILENAME))
    if not os.path.exists(beside) and os.path.exists(built):
        return built
    return beside


def cts_vendor_adapt(rendered, public_cils=None):
    """adapt the policy for vendor_sepolicy.cil"""
    n = rendered.count(LIVE_KEYMINT_TT)
    if n != 1:
        raise ValueError(
            f"keymint typetransition appears {n} times in the rendered policy, "
            f"expected exactly 1; update LIVE_KEYMINT_TT")
    rendered = rendered.replace(LIVE_KEYMINT_TT, CTS_KEYMINT_BLOCK)
    cils = [public_cil_path()] if public_cils is None else public_cils
    lacking = {t for t in OPTIONAL_TYPES if not declares_type(cils, t)}
    return _drop_udmabuf_from_dev_ok(_drop_statements_naming(rendered, lacking))


_ATTRIBUTE_SET = re.compile(r"\(typeattributeset\s+(\S+)\s+\(")


def _set_expression(text, start):
    """parse the CIL set expression at start"""
    stack, name = [[]], ""
    for i in range(start, len(text)):
        c = text[i]
        if c not in "() \t\n":
            name += c
            continue
        if name:
            stack[-1].append(name)
            name = ""
        if c == "(":
            stack.append([])
        elif c == ")":
            done = stack.pop()
            stack[-1].append(done)
            if len(stack) == 1:
                return done
    raise ValueError(f"unbalanced typeattributeset expression at offset {start}")


def _attribute_sets(texts):
    """return a lookup of attribute set expressions"""
    where = {}
    for text in texts:
        for m in _ATTRIBUTE_SET.finditer(text):
            where.setdefault(m.group(1), []).append((text, m.end() - 1))
    return lambda name: [_set_expression(t, i) for t, i in where.get(name, ())]


def _includes(expr, type_name, sets, memo):
    """search an expression for type_name"""
    if isinstance(expr, str):
        if expr == type_name:
            return True
        if expr not in memo:
            memo[expr] = False
            memo[expr] = any(_includes(e, type_name, sets, memo) for e in sets(expr))
        return memo[expr]
    head = expr[0] if expr else None
    if head == "all":
        return True
    if head == "not":
        return not _includes(expr[1], type_name, sets, memo)
    if head == "and":
        return all(_includes(e, type_name, sets, memo) for e in expr[1:])
    if head == "or":
        return any(_includes(e, type_name, sets, memo) for e in expr[1:])
    if head == "xor":
        return (_includes(expr[1], type_name, sets, memo)
                != _includes(expr[2], type_name, sets, memo))
    return any(_includes(e, type_name, sets, memo) for e in expr)


SYSFS_MIRROR_TYPE = "rhizo_sysfs_uinput"
SYSFS_MIRROR_CLASSES = ("dir", "file", "lnk_file")
SYSFS_MIRROR_ANCHOR = "; rhizo_sysfs_uinput holds every sysfs rule\n"
_AV_RULE = re.compile(r"^\((allow|deny|dontaudit)\s+(\S+)\s+(\S+)\s+\((\w+)\s+\(([^()]*)\)\)\)", re.M)
_ANY_AV = re.compile(r"\((allow|deny|dontaudit)\s+(\S+)\s+(\S+)\s")
_AVX_RULE = re.compile(r"^\((allowx|dontauditx|auditallowx)\s+(\S+)\s+(\S+)\s+(\(\w+\s+(\w+)\s.*\))\)$", re.M)
_ANY_AVX = re.compile(r"\((allowx|dontauditx|auditallowx)\s+(\S+)\s+(\S+)\s")


_GENERATED_ATTRIBUTE = re.compile(r"base_typeattr_\d+")


def _mirror_name(name):
    """return the mirror's stable name for a subject"""
    return f"rhizo_mirror_{name}" if _GENERATED_ATTRIBUTE.fullmatch(name) else name


def _cil_expression(expr):
    """write a parsed set expression as CIL"""
    if isinstance(expr, str):
        return _mirror_name(expr)
    return "(" + " ".join(_cil_expression(e) for e in expr) + ")"


def _mirror_attributes(sources, sets):
    """return copies of the generated attributes"""
    out, todo, seen = [], sorted(s for s in sources if _GENERATED_ATTRIBUTE.fullmatch(s)), set()
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        exprs = sets(name)
        if not exprs:
            raise ValueError(f"{name} names a sysfs rule's subject but no typeattributeset defines it")
        out.append(f"(optional {_mirror_name(name)}_block\n(typeattribute {_mirror_name(name)})\n"
                   + "".join(f"(typeattributeset {_mirror_name(name)} {_cil_expression(e)})\n" for e in exprs)
                   + ")\n")
        todo += [n for e in exprs for n in _flatten(e) if _GENERATED_ATTRIBUTE.fullmatch(n)]
    return "".join(sorted(out))


def _flatten(expr):
    """yield the names in a set expression"""
    if isinstance(expr, str):
        yield expr
    else:
        for e in expr:
            yield from _flatten(e)


def sysfs_mirror(cils, policy):
    """return the rules copying sysfs onto SYSFS_MIRROR_TYPE"""
    texts = [open(c).read() for c in cils] + [re.sub(r";[^\n]*", "", policy)]
    sets, on_sysfs, on_mirror = _attribute_sets(texts), {}, {}
    perms, xperms = {}, set()
    for text in texts:
        read = {m.start() for m in _AV_RULE.finditer(text)} | {m.start() for m in _AVX_RULE.finditer(text)}
        for m in list(_ANY_AV.finditer(text)) + list(_ANY_AVX.finditer(text)):
            if (m.start() not in read and _includes(m.group(3), "sysfs", sets, on_sysfs)
                    and not _includes(m.group(3), SYSFS_MIRROR_TYPE, sets, on_mirror)):
                rule = text[m.start():text.find("\n", m.start())]
                raise ValueError(f"{rule} is a rule on sysfs in a form the {SYSFS_MIRROR_TYPE} mirror cannot "
                                 "read; give it one class and one permission list")
        for kind, source, target, cls, names in _AV_RULE.findall(text):
            if (cls in SYSFS_MIRROR_CLASSES and _includes(target, "sysfs", sets, on_sysfs)
                    and not _includes(target, SYSFS_MIRROR_TYPE, sets, on_mirror)):
                perms.setdefault((kind, source, cls), set()).update(names.split())
        for kind, source, target, permx, cls in _AVX_RULE.findall(text):
            if (cls in SYSFS_MIRROR_CLASSES and _includes(target, "sysfs", sets, on_sysfs)
                    and not _includes(target, SYSFS_MIRROR_TYPE, sets, on_mirror)):
                xperms.add((kind, source, permx))
    rules = [f"({kind} {_mirror_name(source)} {SYSFS_MIRROR_TYPE} ({cls} ({' '.join(sorted(names))})))\n"
             for (kind, source, cls), names in sorted(perms.items())]
    rules += [f"({kind} {_mirror_name(source)} {SYSFS_MIRROR_TYPE} {permx})\n"
              for kind, source, permx in sorted(xperms)]
    sources = {source for _kind, source, _cls in perms} | {source for _kind, source, _permx in xperms}
    return _mirror_attributes(sources, sets) + "".join(
        f"(optional {SYSFS_MIRROR_TYPE}_rule_{i}\n{rule})\n" for i, rule in enumerate(rules))


def render_sysfs_mirror(cils, rendered):
    """replace the mirror marker with this release's sysfs mirror"""
    count = rendered.count(SYSFS_MIRROR_ANCHOR)
    if count != 1:
        raise ValueError(f"the rendered policy holds {count} sysfs_uinput_mirror markers, not one; "
                         f"restore the marker in {CIL_FILENAME}")
    return rendered.replace(SYSFS_MIRROR_ANCHOR, sysfs_mirror(cils, rendered))


def template_path():
    """return the path of the staged policy template"""
    return guest_files.path(CIL_FILENAME)


def software_cils(software):
    """return the execmem fragment list for software mode"""
    return [guest_files.path(SOFTWARE_CIL_FILENAME)] if software else []


def build(cils, path=None, ftrace=False, namespace=True, wakeup_genfs=""):
    """return the rendered SELinux policy"""
    dev_carveout, cap2 = derive(cils)
    template = open(path).read() if path else guest_files.read(CIL_FILENAME)
    declared = frozenset(t for t in OPTIONAL_TYPES if declares_type(cils, t)) | frozenset(
        c for c in OPTIONAL_POLICYCAPS if declares_policycap(cils, c)) | (
        frozenset() if platform_opens_ashmem(cils) else frozenset({"vendor_ashmem_open"}))
    rendered = render(template, dev_carveout, cap2, declared, ftrace, namespace, wakeup_genfs if namespace else "",
                      domain_walked_dir_rules(cils) if namespace else "")
    return render_sysfs_mirror(cils, rendered)
