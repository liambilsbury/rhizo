#!/usr/bin/env python3
"""check the launcher's handling of devices.dri"""
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
from xml.etree import ElementTree

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-gpu-switch-launch")
failures = []


def check(ok, what):
    """print a result and remember a failure"""
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def with_policy(text, **env):
    """point the launcher at a policy file and set env"""
    fd, path = tempfile.mkstemp(suffix=".conf")
    os.write(fd, text.encode())
    os.close(fd)
    old = {k: os.environ.get(k) for k in ["RHIZO_POLICY_CONF", "RHIZO_GPU_DRIVER_DIR", "RHIZO_ABI32", *env]}
    os.environ["RHIZO_POLICY_CONF"] = path
    for k in ("RHIZO_GPU_DRIVER_DIR", "RHIZO_ABI32"):
        os.environ.pop(k, None)
    os.environ.update(env)
    return old


def restore(old):
    """remove the policy file and put the environment back"""
    os.unlink(os.environ["RHIZO_POLICY_CONF"])
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v


with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import core  # noqa: E402

log_fd, log_path = tempfile.mkstemp(suffix=".kmsg")
core.swap_kmsg_fd(log_fd)


def logged():
    """return the launcher's log lines written since the last call"""
    with open(log_path) as f:
        text = f.read()
    os.ftruncate(log_fd, 0)
    os.lseek(log_fd, 0, os.SEEK_SET)
    return text


old = with_policy("")
check(core.gpu_driver_dir() == "gpu_driver", "no policy: the virgl set")
check(not core.software_rendering(), "no policy: not software")
check(core.gpu_refusal(render_node_found=True) is None, "no policy and a node: no refusal")
reason = core.gpu_refusal(render_node_found=False)
check(reason is not None and reason.startswith("no-render-node") and "dri = off" in reason,
      "on without a node: refused as no-render-node, naming the switch")
restore(old)

old = with_policy("[devices]\ndri = off\n")
check(core.gpu_driver_dir() == "gpu_driver_software", "dri off: the software set")
check(core.software_rendering(), "dri off: software")
check(core.gpu_refusal(render_node_found=False) is None, "dri off without a node: no refusal")
restore(old)

old = with_policy("[devices]\ndri = off\n", RHIZO_ABI32="1")
check((core.gpu_refusal(render_node_found=False) or "").startswith("software-abi32"), "dri off with RHIZO_ABI32=1: refused")
restore(old)

old = with_policy("[devices]\ndri = off\n", RHIZO_GPU_DRIVER_DIR="gpu_driver_amd")
check(core.gpu_driver_dir() == "gpu_driver_amd", "RHIZO_GPU_DRIVER_DIR still wins")
restore(old)

old = with_policy("[devices]\ndri = no\n")
before = core.software_rendering()
with open(os.environ["RHIZO_POLICY_CONF"], "w") as f:
    f.write("[devices]\ndri = on\n")
st = os.stat(os.environ["RHIZO_POLICY_CONF"])
os.utime(os.environ["RHIZO_POLICY_CONF"], ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
check(before and not core.software_rendering() and core.gpu_driver_dir() == "gpu_driver",
      "the same policy file rewritten from dri = no to dri = on (same size, new mtime): read again, the virgl set")
restore(old)

with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import hals  # noqa: E402

old = with_policy("[devices]\ndri = off\n")
rc = hals.allocator_rc_text()
check("export MESA_ANDROID_NO_KMS_SWRAST 1" in rc and rc.index("on early-init") < rc.index("export MESA_ANDROID_NO_KMS_SWRAST 1"),
      "software: mesa's no-device mode is exported at early-init")
check("setenv RHIZO_ALLOCATOR memfd" in rc, "software: the allocator makes memfd buffers")
restore(old)
old = with_policy("")
rc = hals.allocator_rc_text()
check("MESA_ANDROID_NO_KMS_SWRAST" not in rc and "RHIZO_ALLOCATOR" not in rc, "gpu: neither line")
restore(old)


def prepared_reason(gpu_driver):
    """return validate_prepared's refusal for a gpu_driver"""
    root = tempfile.mkdtemp(prefix="gpu-switch-launch-")
    os.makedirs(os.path.join(root, "abc123def456"))
    os.symlink("abc123def456", os.path.join(root, "current"))
    with open(os.path.join(root, "abc123def456", "manifest.json"), "w") as f:
        json.dump({"layout_version": core.PREPARED_LAYOUT_VERSION, "gsi_fingerprint": core.GSI_FINGERPRINT,
                   "kernel": os.uname().release, "gpu_driver": gpu_driver}, f)
    saved_root, core.PREPARED_ROOT = core.PREPARED_ROOT, root
    try:
        return core.validate_prepared()[1]
    finally:
        core.PREPARED_ROOT = saved_root
        shutil.rmtree(root)


old = with_policy("[devices]\ndri = off\n")
check(prepared_reason("gpu_driver") == "gpu-driver", "dri off on a tree prepared with the gpu: refused as gpu-driver")
check(prepared_reason("gpu_driver_software") is None, "dri off on a tree prepared in software: accepted")
restore(old)


def launch_gpu_mode(sources):
    """run the launch's gpu mode step against a resolver"""
    calls = []
    real = hals.rootfs.host_dri_sources
    hals.rootfs.host_dri_sources = lambda: (calls.append(1), dict(sources))[1]
    stopped = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            hals.gpu_mode_or_exit()
    except SystemExit as e:
        stopped = str(e)
    finally:
        hals.rootfs.host_dri_sources = real
    return stopped, len(calls), logged()


NODE = {"renderD128": "/dev/dri/renderD128"}
old = with_policy("")
stopped, calls, log = launch_gpu_mode(NODE)
check(stopped is None and calls == 1 and "RHIZO_MARKER gpu_mode=gpu driver=gpu_driver" in log,
      "gpu with a node: launches, asks the resolver once, logs gpu_mode=gpu")
stopped, calls, log = launch_gpu_mode({})
check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=no-render-node" in log and "dri = off" in log,
      "gpu without a node: stops with gpu_driver_refused=no-render-node, naming the switch")
restore(old)
old = with_policy("[devices]\ndri = off\n")
stopped, calls, log = launch_gpu_mode({})
check(stopped is None and calls == 0 and "RHIZO_MARKER gpu_mode=software driver=gpu_driver_software" in log,
      "software: launches without asking the resolver, logs gpu_mode=software")
restore(old)
old = with_policy("[devices]\ndri = off\n", RHIZO_ABI32="1")
stopped, calls, log = launch_gpu_mode({})
check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=software-abi32" in log, "software with RHIZO_ABI32=1: stops by name")
restore(old)
old = with_policy("[devices]\ndri = maybe\n")
check(not core.software_rendering() and core.gpu_driver_dir() == "gpu_driver",
      "a host policy that does not parse: not software and the virgl set, never a silent software mode")
reason = core.gpu_refusal(render_node_found=True) or ""
check(reason.startswith("host-policy-error") and "dri='maybe', expected yes or no" in reason,
      "a host policy that does not parse: refused as host-policy-error, naming the parse error")
stopped, calls, log = launch_gpu_mode(NODE)
check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=host-policy-error" in log and calls == 0,
      "a host policy that does not parse: the launch stops by name before it asks the resolver")
restore(old)

mode_dir = tempfile.mkdtemp(prefix="gpu-switch-launch-mode-")
saved_mode_state = getattr(core, "POLICY_MODE_STATE", None)
core.POLICY_MODE_STATE = os.path.join(mode_dir, "rhizo-policy-mode")


def recorded():
    """return the policy mode record's text, or None when there is none"""
    try:
        with open(core.POLICY_MODE_STATE) as f:
            return f.read()
    except OSError:
        return None


def record(text):
    """write the policy mode record, or remove it for None"""
    if text is None:
        if os.path.exists(core.POLICY_MODE_STATE):
            os.unlink(core.POLICY_MODE_STATE)
        return
    with open(core.POLICY_MODE_STATE, "w") as f:
        f.write(text)


def launch_with_policy_loaded(policy_loaded, sources):
    """run the launch's gpu mode step with or without a policy"""
    real = hals.rootfs.host_dri_sources
    hals.rootfs.host_dri_sources = lambda: dict(sources)
    stopped = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            hals.gpu_mode_or_exit(policy_loaded)
    except SystemExit as e:
        stopped = str(e)
    except TypeError as e:
        stopped = "TypeError: %s" % e
    finally:
        hals.rootfs.host_dri_sources = real
    return stopped, logged()


if hasattr(core, "record_policy_mode") and hasattr(core, "loaded_policy_dri"):
    old = with_policy("[devices]\ndri = off\n")
    record(None)
    with contextlib.redirect_stdout(io.StringIO()):
        ok = core.record_policy_mode()
    check(ok and recorded() == "dri=off\n" and core.loaded_policy_dri() == "off"
          and "RHIZO_MARKER policy_dri=off" in logged(),
          "software: the policy's mode is recorded as dri=off and read back as off")
    restore(old)
    old = with_policy("")
    with contextlib.redirect_stdout(io.StringIO()):
        core.record_policy_mode()
    check(recorded() == "dri=on\n" and core.loaded_policy_dri() == "on", "gpu: the record is replaced with dri=on")
    restore(old)
    logged()
    record(None)
    check(core.loaded_policy_dri() is None, "no record: no loaded mode")
    record("dri=maybe\n")
    check(core.loaded_policy_dri() is None, "a record naming neither on nor off: no loaded mode")
    saved, core.POLICY_MODE_STATE = core.POLICY_MODE_STATE, os.path.join(mode_dir, "absent-dir", "mode")
    with contextlib.redirect_stdout(io.StringIO()):
        failed = core.record_policy_mode()
    check(failed is False and "could not record" in logged(), "a record that cannot be written says so and returns False")
    core.POLICY_MODE_STATE = saved

    old = with_policy("")
    record("dri=off\n")
    stopped, log = launch_with_policy_loaded(True, NODE)
    check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=policy-reload-needed" in log and "reboot" in log,
          "gpu under a policy loaded for software: stops with gpu_driver_refused=policy-reload-needed, naming the reboot")
    stopped, log = launch_with_policy_loaded(False, NODE)
    check(stopped is None and "RHIZO_MARKER gpu_mode=gpu" in log,
          "gpu with a software record from an earlier boot and no policy loaded yet: launches (the first start of a boot)")
    record("dri=on\n")
    stopped, log = launch_with_policy_loaded(True, NODE)
    check(stopped is None and "RHIZO_MARKER gpu_mode=gpu" in log, "gpu under a policy loaded for gpu: launches")
    record(None)
    stopped, log = launch_with_policy_loaded(True, NODE)
    check(stopped is None and "RHIZO_MARKER gpu_mode=gpu" in log, "gpu under a loaded policy with no record: launches")
    restore(old)
    old = with_policy("[devices]\ndri = off\n")
    record("dri=on\n")
    stopped, log = launch_with_policy_loaded(True, {})
    check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=policy-reload-needed" in log and "reboot" in log,
          "software under a policy loaded for gpu: stops with gpu_driver_refused=policy-reload-needed, naming the reboot")
    record("dri=off\n")
    stopped, log = launch_with_policy_loaded(True, {})
    check(stopped is None and "RHIZO_MARKER gpu_mode=software" in log, "software under a policy loaded for software: launches")
    restore(old)
else:
    check(False, "src/androidd/sandbox/core.py defines record_policy_mode() and loaded_policy_dri()")

from sandbox import capabilities  # noqa: E402
overlay_dir = tempfile.mkdtemp(prefix="gpu-switch-launch-overlay-")
saved_overlay_dir, capabilities.INSTANCE_CONF_DIR = capabilities.INSTANCE_CONF_DIR, overlay_dir
OVERLAY = os.path.join(overlay_dir, "%s.conf" % core.SANDBOX_ID)


def overlay(text):
    """write this instance's policy overlay, or remove it for None"""
    if text is None:
        if os.path.exists(OVERLAY):
            os.unlink(OVERLAY)
        return
    with open(OVERLAY, "w") as f:
        f.write(text)


old = with_policy("")
overlay("[devices]\ndri = off\n")
check(not core.software_rendering() and core.gpu_driver_dir() == "gpu_driver",
      "gpu host policy, an overlay setting devices.dri (refused as host-wide, deny-all): the mode is still gpu")
reason = core.gpu_refusal(render_node_found=True, loaded_dri="on") or ""
check(reason.startswith("instance-policy-error") and "[devices] dri is host-wide" in reason,
      "gpu host policy, a refused overlay: the launch stops naming the overlay's own error")
with contextlib.redirect_stdout(io.StringIO()):
    core.record_policy_mode()
check(recorded() == "dri=on\n", "gpu host policy, a refused overlay: the first launch records and compiles the gpu policy, never the software one")
logged()
record("dri=on\n")
stopped, log = launch_with_policy_loaded(True, NODE)
check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=instance-policy-error" in log
      and "policy-reload-needed" not in log and "[devices] dri is host-wide" in log,
      "gpu host policy loaded for gpu, a refused overlay: refused as instance-policy-error naming the overlay, never policy-reload-needed")
overlay("[instance]\ncpu_max = 50000 100000\n")
check(core.gpu_refusal(render_node_found=True, loaded_dri="on") is None,
      "gpu host policy, an overlay that parses: no refusal")
restore(old)
old = with_policy("[devices]\ndri = off\n")
overlay("[devices]\ndri = on\n")
check(core.software_rendering() and core.gpu_refusal(render_node_found=False, loaded_dri="off") is None,
      "software host policy, an overlay setting devices.dri: still software, and nothing a software launch needs is withheld")
restore(old)
overlay(None)
capabilities.INSTANCE_CONF_DIR = saved_overlay_dir
shutil.rmtree(overlay_dir)
logged()
core.POLICY_MODE_STATE = saved_mode_state
shutil.rmtree(mode_dir)
logged()


def stream_line():
    """return the composer's stream socket line under the current policy"""
    with contextlib.redirect_stdout(io.StringIO()):
        return hals.stream_socket_line(hals.capabilities.policy_or_deny())


ARMED = "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\n"
old = with_policy("[stream]\nenabled = on\n")
check(stream_line() == ARMED and not logged(), "gpu with stream on: the stream export is armed")
restore(old)
old = with_policy("[devices]\ndri = off\n[stream]\nenabled = on\n")
check(stream_line() == "" and "RHIZO_MARKER stream_refused=devices-dri-off" in logged(),
      "software with stream on: not armed, stream_refused=devices-dri-off")
restore(old)
old = with_policy("[devices]\ndri = off\n")
check(stream_line() == "" and "stream_refused" not in logged(), "software with stream off: nothing to refuse")
restore(old)

def staged_software_rro(apk):
    """stage the software overlay into a fixture run root"""
    root = tempfile.mkdtemp(prefix="gpu-switch-launch-rro-")
    share, run = os.path.join(root, "share"), os.path.join(root, "run")
    os.makedirs(share)
    os.makedirs(os.path.join(run, "vendor", "etc", "selinux"))
    if apk:
        with open(os.path.join(share, "RhizoSoftwareRro.apk"), "wb") as f:
            f.write(b"fixture overlay")
    saved = hals.RUN_ROOT, hals.beside
    hals.RUN_ROOT, hals.beside = run, lambda *p: os.path.join(share, *p)
    stopped = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            hals.stage_software_rro()
    except SystemExit as e:
        stopped = str(e)
    finally:
        hals.RUN_ROOT, hals.beside = saved
    overlay = os.path.join(run, "system_ext_upper", "overlay", "RhizoSoftwareRro.apk")
    contexts_path = os.path.join(run, "vendor", "etc", "selinux", "vendor_file_contexts")
    staged = open(overlay, "rb").read() if os.path.exists(overlay) else None
    contexts = open(contexts_path).read() if os.path.exists(contexts_path) else ""
    shutil.rmtree(root)
    return stopped, staged, contexts, logged()


def props_rc():
    """render the framework props rc into a fixture run root"""
    run = tempfile.mkdtemp(prefix="gpu-switch-launch-props-")
    os.makedirs(os.path.join(run, "system_ext_upper", "etc", "init"))
    saved = hals.RUN_ROOT
    hals.RUN_ROOT = run
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            hals._stage_framework_rc()
        with open(os.path.join(run, "system_ext_upper", "etc", "init", "rhizo-props.rc")) as f:
            return f.read()
    finally:
        hals.RUN_ROOT = saved
        shutil.rmtree(run)


SOFTWARE_RRO_BOOLS = ("config_displayColorFadeDisabled", "config_avoidGfxAccel", "config_disableTaskSnapshots")
overlay_bools = {b.get("name"): (b.text or "").strip()
                 for b in ElementTree.parse(os.path.join(ROOT, "src", "android", "apps", "software-rro", "res", "values",
                                                         "bools.xml")).getroot().iter("bool")}
for name in SOFTWARE_RRO_BOOLS:
    check(overlay_bools.get(name) == "true",
          f"the software overlay sets {name} true")
RRO_CONTEXT = "/system_ext/overlay/RhizoSoftwareRro\\.apk u:object_r:vendor_overlay_file:s0\n"
AVOID_GFX_ACCEL = "    setprop ro.config.avoid_gfx_accel true\n"
if hasattr(hals, "stage_software_rro"):
    old = with_policy("[devices]\ndri = off\n")
    stopped, staged, contexts, log = staged_software_rro(apk=True)
    check(stopped is None and staged == b"fixture overlay" and contexts == RRO_CONTEXT and "software_rro=staged" in log,
          "software: the framework overlay is staged on /system_ext/overlay and labeled vendor_overlay_file")
    stopped, staged, contexts, log = staged_software_rro(apk=False)
    check(stopped is not None and "RHIZO_MARKER gpu_driver_refused=software-rro-missing" in log and staged is None,
          "software with no overlay beside the launcher: stops with gpu_driver_refused=software-rro-missing")
    restore(old)
    old = with_policy("")
    stopped, staged, contexts, log = staged_software_rro(apk=True)
    check(stopped is None and staged is None and "RhizoSoftwareRro" not in contexts,
          "gpu: the framework overlay is not staged and gets no label line")
    restore(old)
else:
    check(False, "src/androidd/sandbox/hals.py defines stage_software_rro()")
old = with_policy("[devices]\ndri = off\n")
rc = props_rc()
check(AVOID_GFX_ACCEL in rc and rc.index("on early-init") < rc.find(AVOID_GFX_ACCEL),
      "software: init sets ro.config.avoid_gfx_accel at early-init from /system_ext")
restore(old)
old = with_policy("")
check("avoid_gfx_accel" not in props_rc(), "gpu: ro.config.avoid_gfx_accel is not set")
restore(old)
check("avoid_gfx_accel" not in hals.guest_files.read("vendor/build.prop"),
      "the vendor build.prop never carries ro.config.avoid_gfx_accel")

with contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher  # noqa: E402
    from sandbox import selinux_policy  # noqa: E402
FRAGMENT = os.path.join(ROOT, "src", "androidd", "guest", "sepolicy", "policy-software.cil")
GSI_CILS = ("etc/selinux/plat_sepolicy.cil", "system_ext/etc/selinux/system_ext_sepolicy.cil",
            "product/etc/selinux/product_sepolicy.cil")


def policy_compile(root, between=lambda: None):
    """run the launcher's policy compile on fixture cils"""
    gsi, cache, out = (os.path.join(root, d) for d in ("gsi", "cache", "out"))
    for rel in GSI_CILS:
        os.makedirs(os.path.dirname(os.path.join(gsi, rel)), exist_ok=True)
        with open(os.path.join(gsi, rel), "w") as f:
            f.write("; fixture %s\n" % rel)
    os.makedirs(out, exist_ok=True)
    pc, rhizo_cil = os.path.join(out, "precompiled_sepolicy"), os.path.join(out, "rhizo_vendor_sepolicy.cil")
    with open(pc, "wb") as f:
        f.write(b"fixture policy")
    saved = launcher.GSI, launcher.RHIZO_CACHE_DIR, launcher.gsi_bootstrap_cmd, os.geteuid
    launcher.GSI, launcher.RHIZO_CACHE_DIR = gsi, cache
    launcher.gsi_bootstrap_cmd = lambda binary, args="": "true"
    os.geteuid = lambda: 0
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            _rc, cils, content, _err = launcher.compile_precompiled_sepolicy(pc, rhizo_cil)
        between()
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            launcher.prepare_sepolicy_verb(True)
    finally:
        launcher.GSI, launcher.RHIZO_CACHE_DIR, launcher.gsi_bootstrap_cmd, os.geteuid = saved
    with open(rhizo_cil) as f:
        rendered = f.read()
    return [os.path.relpath(c, gsi) if c.startswith(gsi) else c for c in cils], content, rendered, printed.getvalue()


def cache_entries(root):
    """return the cache file names the compile wrote under root"""
    cache = os.path.join(root, "cache")
    return sorted(os.listdir(cache)) if os.path.isdir(cache) else []


root = tempfile.mkdtemp(prefix="gpu-switch-launch-policy-")
old = with_policy("")
cils, content, rendered, line = policy_compile(root)
gpu_entries = cache_entries(root)
check(cils == [*GSI_CILS, os.path.join(root, "out", "rhizo_vendor_sepolicy.cil")] and content == rendered,
      "gpu: the policy compile reads the gsi's cils and the rendered fragment only, and the vendor policy is that fragment")
check(len(gpu_entries) == 1 and line.strip() == "PREPARE_SEPOLICY_CHECK cache=%s hit=1" % os.path.join(root, "cache", gpu_entries[0]),
      "gpu: prepare-sepolicy --check names the entry the compile cached")
entry = os.path.join(root, "cache", gpu_entries[0])
OLD = 1000000000
os.utime(entry, (OLD, OLD))
policy_compile(root, between=lambda: check(os.stat(entry).st_mtime > OLD, "gpu: a compile cache hit refreshes the entry's mtime"))
os.utime(entry, (OLD, OLD))
policy_compile(root, between=lambda: os.utime(entry, (OLD, OLD)))
check(os.stat(entry).st_mtime > OLD, "gpu: a prepare-sepolicy --check hit refreshes the entry's mtime")
restore(old)
old = with_policy("[devices]\ndri = off\n")
fragment = open(FRAGMENT).read() if os.path.exists(FRAGMENT) else None
cils, content, rendered, line = policy_compile(root)
entries = cache_entries(root)
software_entry = [e for e in entries if e not in gpu_entries]
check(fragment is not None and cils[-1] == FRAGMENT and content == rendered + fragment,
      "software: rhizo-policy-software.cil joins the policy compile after the rendered fragment and the vendor policy carries it")
check(len(software_entry) == 1 and line.strip() == "PREPARE_SEPOLICY_CHECK cache=%s hit=1" % os.path.join(root, "cache", software_entry[0]),
      "software: the policy caches under its own key and prepare-sepolicy --check names that key")
check(hasattr(selinux_policy, "software_cils") and selinux_policy.software_cils(False) == [],
      "selinux_policy.software_cils(False) adds nothing to a gpu compile")
restore(old)
shutil.rmtree(root)
logged()

runs = []
real_resolve = hals.rootfs._resolve_dri_sources
hals.rootfs._resolve_dri_sources = lambda env, resolver, log: (runs.append(1), dict(NODE))[1]
try:
    first, second = hals.rootfs.host_dri_sources(), hals.rootfs.host_dri_sources()
finally:
    hals.rootfs._resolve_dri_sources = real_resolve
    del hals.rootfs._HOST_DRI_SOURCES[:]
check(first == second == NODE and len(runs) == 1, "the launch's refusal and its mknod share one resolver run")


def body(path, name):
    """return the source of a function in a launcher file"""
    with open(os.path.join(ROOT, "src", "androidd", path)) as f:
        parts = f.read().split(f"\ndef {name}(", 1)
    check(len(parts) == 2, f"src/androidd/{path} defines {name}()")
    return parts[1].split("\ndef ", 1)[0] if len(parts) == 2 else ""


run_sandbox = body("boot.py", "run_sandbox")
check(-1 < run_sandbox.find("gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())") < run_sandbox.find("privileged_setup()"),
      "run_sandbox settles the gpu mode, against a host-mode policy already loaded, before privileged_setup stages anything")
compile_body = body("boot.py", "compile_sepolicy")
staged_at = compile_body.find("precompiled policy staged")
record_at = compile_body.find("if not (host_selinux_mode() and policy_is_loaded()):\n            core.record_policy_mode()")
check(-1 < staged_at < record_at < compile_body.find("spawn_host_primer()"),
      "compile_sepolicy records the policy's mode once it is staged, only while no host-mode policy is loaded, before the primer starts")
check("stream_socket_line(_server_policy)" in body("sandbox/hals.py", "stage_hals"),
      "the composer's stream line comes from stream_socket_line")
check("stage_software_rro()" in body("boot.py", "stage_apex_and_patches"),
      "the launch stages the software overlay beside the boot overlay")

os.close(log_fd)
os.unlink(log_path)
sys.exit(1 if failures else 0)
