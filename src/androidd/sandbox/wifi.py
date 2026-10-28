import errno
import importlib.util
import os
import pwd
import shutil
import stat
import subprocess
import sys
import time

from sandbox import capabilities
from sandbox import core
from sandbox import guest_files
from sandbox import hals
from sandbox.core import RUN_ROOT, SANDBOX_ID, beside, kmsg

WLAN_MODULE = "rhizo_wlan"
GUEST_WLAN_IF = "wlan0"
NETBRIDGED_ACCOUNT = "rhizo-netbridged"
NETBRIDGED_PAYLOAD = "/usr/lib/rhizo/netbridged/netbridged.py"
WIFI_SECRET_NAME = "wifi-secret"
WIFI_SECRET_BYTES = 32
NETWORK_APK = "RhizoNetwork.apk"
OVERLAY_APKS = ("RhizoWifiRro.apk", "RhizoConnectivityRro.apk")
PUSH_SCRIPT = "rhizo-wifi-mirror-push"
MIRROR_STATE_NAME = "wifi-mirror"
PUSH_TIMEOUT_S = 900

APP_REL = "priv-app/RhizoNetwork/RhizoNetwork.apk"
PRIVAPP_REL = "etc/permissions/privapp-permissions-rhizo-network.xml"
APP_CONTEXTS = ("/product/priv-app/RhizoNetwork/RhizoNetwork\\.apk u:object_r:system_file:s0\n"
                "/product/overlay/RhizoWifiRro\\.apk u:object_r:vendor_overlay_file:s0\n"
                "/product/overlay/RhizoConnectivityRro\\.apk u:object_r:vendor_overlay_file:s0\n")
FIRST_ENABLE = (("system_ext_upper/bin/rhizo-wifi-first-enable.sh", "bin/wifi-first-enable.sh"),
                ("system_ext_upper/etc/init/rhizo-wifi-first-enable.rc", "init/wifi-first-enable.rc"))
HAL_RCS = (("rhizo-wifi.rc", "init/wifi.rc", "/vendor/bin/hw/rhizo-wifi-service"),
           ("rhizo-wifi-supplicant.rc", "init/wifi-supplicant.rc", "/vendor/bin/hw/rhizo-wifi-supplicant"))
WIFI_FEATURE = ('<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n'
                '    <feature name="android.hardware.wifi" />\n</permissions>\n')
ETHERNET_FEATURE = ('<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n'
                    '    <feature name="android.hardware.ethernet" />\n</permissions>\n')

_NB_WLAN = []


def secret_path():
    """return the per-install BSSID secret's path"""
    return os.path.join(core.RHIZO_STATE_DIR, WIFI_SECRET_NAME)


def mirror_state_path():
    """return the file netbridged writes the mirrored SSID to"""
    return f"/run/{core.NETBRIDGED_RUNTIME_DIR}/{MIRROR_STATE_NAME}"


def netbridged_main():
    """return netbridged's entry point"""
    return NETBRIDGED_PAYLOAD if os.path.exists(NETBRIDGED_PAYLOAD) else beside("netbridged", "netbridged.py")


def nb_wlan():
    """return netbridged's nb_wlan module"""
    if not _NB_WLAN:
        nb_dir = os.path.dirname(netbridged_main())
        if nb_dir not in sys.path:
            sys.path.append(nb_dir)
        spec = importlib.util.spec_from_file_location("nb_wlan", os.path.join(nb_dir, "nb_wlan.py"))
        if spec is None or spec.loader is None:
            raise ImportError(f"no nb_wlan.py in {nb_dir}")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _NB_WLAN.append(mod)
    return _NB_WLAN[0]


def _wlan_error(mod):
    """return the exception class nb_wlan raises"""
    return getattr(mod, "WlanError", OSError)


def module_loaded():
    """return true when rhizo_wlan is loaded"""
    return os.path.isdir(f"/sys/module/{WLAN_MODULE}")


def refusal(policy, release=None, prepared=None, exists=os.path.exists, payload=None, root=None):
    """return why this launch gives Android no Wi-Fi, or None"""
    release = core.RHIZO_RELEASE if release is None else release
    prepared = core.prepared_key() if prepared is None else prepared
    payload = payload or beside()
    root = root or RUN_ROOT
    if os.environ.get("RHIZO_POLICY_ONLY") == "1":
        return "policy-only"
    if not policy.allows("network.enabled"):
        return "network-disabled"
    if not policy.allows("network.wifi"):
        return "policy"
    if release not in core.WIFI_RELEASES:
        return f"release-{release}"
    sources = core.wifi_hal_sources(release, payload, exists)
    if len(sources) != len(core.WIFI_HAL_BINS):
        return "hal-absent"
    if prepared and not all(exists(f"{root}/vendor/bin/hw/{n}") for n in core.WIFI_HAL_BINS):
        return "hal-not-in-prepared-tree"
    if not exists(os.path.join(payload, NETWORK_APK)):
        return "network-app-absent"
    if not exists(os.path.join(payload, PUSH_SCRIPT)):
        return "push-helper-absent"
    try:
        pwd.getpwnam(NETBRIDGED_ACCOUNT)
    except KeyError:
        return "no-netbridged-account"
    return None


def load_module(run=subprocess.run):
    """load rhizo_wlan and return why its family is unusable"""
    try:
        wlan = nb_wlan()
    except (ImportError, OSError, SyntaxError) as e:
        kmsg(f"nb_wlan could not be loaded: {e!r}")
        return "nb_wlan-unavailable"
    r = run(["modprobe", WLAN_MODULE], capture_output=True, text=True)
    if r.returncode != 0:
        kmsg(f"modprobe {WLAN_MODULE} rc={r.returncode}: {(r.stderr or '').strip()}")
        return "module-unavailable"
    try:
        if not wlan.wlan_available():
            return "family-unavailable"
    except (OSError, _wlan_error(wlan)) as e:
        kmsg(f"nb_wlan.wlan_available() raised {e!r}")
        return "family-unavailable"
    return None


def untraversable_parent(path, uid, gid, lstat=os.lstat):
    """return the first directory above path uid:gid cannot search"""
    d = os.path.dirname(os.path.abspath(path))
    while True:
        st = lstat(d)
        bits = (stat.S_IXUSR if st.st_uid == uid else stat.S_IXGRP if st.st_gid == gid else stat.S_IXOTH)
        if not stat.S_ISDIR(st.st_mode) or not st.st_mode & bits:
            return d
        if d == "/":
            return None
        d = os.path.dirname(d)


def ensure_secret(path=None, account=NETBRIDGED_ACCOUNT):
    """create the per-install BSSID secret readable by netbridged's group"""
    path = path or secret_path()
    entry = pwd.getpwnam(account)
    gid = entry.pw_gid
    blocked = untraversable_parent(path, entry.pw_uid, gid)
    if blocked:
        raise PermissionError(f"{account} cannot search {blocked}, so it could not read {path}")
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None and not (stat.S_ISREG(st.st_mode) and st.st_size == WIFI_SECRET_BYTES):
        kmsg(f"{path} is not a {WIFI_SECRET_BYTES}-byte file -- replacing it")
        st = None
    if st is None:
        tmp = path + ".part"
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.fchown(fd, 0, gid)
            os.fchmod(fd, 0o640)
            os.write(fd, os.urandom(WIFI_SECRET_BYTES))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp, path)
        kmsg(f"RHIZO_MARKER wifi_secret=created path={path}")
        return path
    if (st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)) != (0, gid, 0o640):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fchown(fd, 0, gid)
            os.fchmod(fd, 0o640)
        finally:
            os.close(fd)
    return path


def plan(policy=None, run=subprocess.run):
    """record whether this launch gives Android Wi-Fi"""
    policy = policy or capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    mode = policy.scope("network.wifi")
    why = refusal(policy)
    if why is None:
        why = load_module(run)
    if why is None:
        try:
            ensure_secret()
        except (OSError, KeyError) as e:
            kmsg(f"{secret_path()} could not be made: {e!r}")
            why = "secret-failed"
    core.set_wifi_armed(why is None)
    if why is None:
        kmsg(f"RHIZO_MARKER wifi={mode}")
        return True
    kmsg(f"RHIZO_MARKER wifi=off reason={why}" + (" module=loaded-earlier" if module_loaded() else ""))
    return False


def _write(path, text):
    """write text to path, making its directory"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def _unlink(path):
    """remove path if it exists"""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def _copy(src, dst):
    """copy src to dst as a 0644 file"""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy(src, dst)
    os.chmod(dst, 0o644)


def _stage_hal_rcs(on, root):
    """stage or remove the Wi-Fi HALs' init files"""
    for name, guest, exe in HAL_RCS:
        dst = f"{root}/vendor/etc/init/{name}"
        if on:
            _write(dst, guest_files.render(guest_files.read(guest),
                                           whole={"early_init_restorecon": core.early_init_restorecon(exe)},
                                           comment_prefix="#"))
        else:
            _unlink(dst)


WIFICOND_RCS = (("wificond.rc", "system_upper/etc/init/wificond.rc", "etc/init/wificond.rc"),
                ("system_ext-wificond.rc", "system_ext_upper/etc/init/wificond.rc", "system_ext/etc/init/wificond.rc"))


def _stage_wificond_rc(on, root, payload):
    """disable the GSI's wificond.rc while Wi-Fi is off"""
    if on:
        for _name, rel, _label in WIFICOND_RCS:
            _unlink(os.path.join(root, rel))
        return
    patches = core.stock_patches_dir()
    staged = []
    for name, rel, label in WIFICOND_RCS:
        dst = os.path.join(root, rel)
        src = os.path.join(patches, name) if patches else ""
        if name == "wificond.rc" and not os.path.exists(src):
            src = os.path.join(payload, name)
        if os.path.exists(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)
            kmsg(f"patched {label} staged")
            staged.append(label)
        else:
            _unlink(dst)
    if not staged:
        kmsg(f"patched wificond.rc NOT FOUND in {patches} or {payload}")


def _stage_network_app(on, root, payload):
    """stage or remove the network app and Wi-Fi overlays"""
    upper = f"{root}/product_upper"
    app, privapp = (os.path.join(upper, r) for r in (APP_REL, PRIVAPP_REL))
    overlays = [(os.path.join(payload, name), os.path.join(upper, "overlay", name)) for name in OVERLAY_APKS]
    if not on:
        for path in [app, privapp] + [dst for _src, dst in overlays]:
            _unlink(path)
        try:
            os.rmdir(os.path.dirname(app))
        except OSError:
            pass
        return
    _copy(os.path.join(payload, NETWORK_APK), app)
    _write(privapp, guest_files.read("permissions/privapp-network.xml"))
    for src, dst in overlays:
        if os.path.exists(src):
            _copy(src, dst)
        else:
            kmsg(f"{os.path.basename(src)} NOT FOUND at {src}")
    with open(f"{root}/vendor/etc/selinux/vendor_file_contexts", "a") as f:
        f.write(APP_CONTEXTS)


def apply_shape(rewrite_manifest=False, root=None, payload=None):
    """stage or remove this launch's Wi-Fi files"""
    root = root or RUN_ROOT
    payload = payload or beside()
    on = core.wifi_armed()
    _stage_hal_rcs(on, root)
    if rewrite_manifest:
        _write(f"{root}/vendor/manifest.xml", hals.vendor_manifest_xml())
    perms = f"{root}/product_upper/etc/permissions"
    if on:
        _write(f"{perms}/rhizo-wifi.xml", WIFI_FEATURE)
        _unlink(f"{perms}/rhizo-ethernet.xml")
    else:
        _unlink(f"{perms}/rhizo-wifi.xml")
        _write(f"{perms}/rhizo-ethernet.xml", ETHERNET_FEATURE)
    _stage_wificond_rc(on, root, payload)
    _stage_network_app(on, root, payload)
    for rel, guest in FIRST_ENABLE:
        if on:
            _write(os.path.join(root, rel), guest_files.read(guest))
        else:
            _unlink(os.path.join(root, rel))
    kmsg(f"RHIZO_MARKER wifi_shape={'wifi' if on else 'ethernet'}")


def disarm(reason):
    """fall back to ethernet without the wireless pair"""
    core.set_wifi_armed(False)
    kmsg(f"RHIZO_MARKER wifi=off reason={reason}")
    apply_shape(rewrite_manifest=True)


def create_pair(host_if, mac, netns_pid, account=NETBRIDGED_ACCOUNT):
    """create the wireless pair with wlan0 in Android's netns"""
    try:
        wlan = nb_wlan()
        owner = pwd.getpwnam(account).pw_uid
        wlan.create(host_if, GUEST_WLAN_IF, mac, netns_pid, owner)
    except Exception as e:  # noqa: BLE001
        kmsg(f"nb_wlan.create({host_if}, {GUEST_WLAN_IF}, {mac}, {netns_pid}) failed: {e!r}")
        return "create-failed"
    kmsg(f"RHIZO_MARKER wifi_pair=created host={host_if} guest={GUEST_WLAN_IF} netns_pid={netns_pid}")
    return None


def destroy_pair(host_if):
    """destroy host_if's wireless pair"""
    if not module_loaded():
        return False
    try:
        wlan = nb_wlan()
    except (ImportError, OSError, SyntaxError) as e:
        kmsg(f"nb_wlan could not be loaded to destroy {host_if}'s pair: {e!r}")
        return False
    try:
        wlan.destroy(host_if)
    except OSError as e:
        if e.errno not in (errno.ENODEV, errno.ENOENT):
            kmsg(f"nb_wlan.destroy({host_if}) failed: {e!r}")
        return False
    kmsg(f"RHIZO_MARKER wifi_pair=destroyed host={host_if}")
    return True


def clear_pair(host_if, attempts=10, delay=0.5, exists=os.path.lexists):
    """destroy host_if's pair after a timed-out create"""
    for _ in range(attempts):
        destroy_pair(host_if)
        if not exists(f"/sys/class/net/{host_if}"):
            return True
        time.sleep(delay)
    return False


def netbridged_args(policy):
    """return netbridged's Wi-Fi arguments"""
    if not core.wifi_armed():
        return []
    return ["--wifi-mode", policy.scope("network.wifi"), "--wifi-secret-file", secret_path()]


def push_unit_argv():
    """return the push helper's command line"""
    return [beside(PUSH_SCRIPT), mirror_state_path(), f"{RUN_ROOT}/data/local/tmp/rhizo-probe.sock"]


def stop_push_unit(run, block=True):
    """stop a previous launch's push unit"""
    units = [f"{core.WIFI_PUSH_UNIT}.path", f"{core.WIFI_PUSH_UNIT}.service"]
    run("systemctl", "stop", *(() if block else ("--no-block",)), *units, check=False)
    run("systemctl", "reset-failed", *units, check=False)


def start_push_unit(run):
    """start the path-activated push of the mirrored SSID into Android"""
    run("systemd-run", f"--unit={core.WIFI_PUSH_UNIT}", "--collect",
        f"--path-property=PathModified={mirror_state_path()}",
        "-p", "Type=oneshot",
        "-p", f"TimeoutStartSec={PUSH_TIMEOUT_S}",
        f"--setenv=RHIZO_SANDBOX_ID={SANDBOX_ID}",
        f"--setenv=RHIZO_WIFI_PUSH_TIMEOUT_S={PUSH_TIMEOUT_S}",
        "-p", "NoNewPrivileges=yes",
        "-p", "ProtectSystem=strict",
        "-p", "ReadWritePaths=/run",
        "-p", f"StandardOutput=append:{core.WIFI_PUSH_LOG}",
        "-p", f"StandardError=append:{core.WIFI_PUSH_LOG}",
        *push_unit_argv(),
        check=True)
    # a state file written before the path unit existed triggers nothing
    run("systemctl", "start", "--no-block", f"{core.WIFI_PUSH_UNIT}.service", check=False)
    kmsg(f"RHIZO_MARKER wifi_push={core.WIFI_PUSH_UNIT} path={mirror_state_path()}")


def release_instance(log=kmsg):
    """destroy this instance's pair and stop its push unit"""
    def run(*args, check=False):
        """run a command and log a failure"""
        r = subprocess.run(list(args), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            log(f"{' '.join(args)} -> rc={r.returncode} {r.stderr.strip()[:200]}")
        return r
    stop_push_unit(run, block=False)
    destroy_pair(core.VETH_HOST_IF)
