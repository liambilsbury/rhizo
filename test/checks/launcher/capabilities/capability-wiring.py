#!/usr/bin/env python3

import ast
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path[:0] = [os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")), HERE]

from sandbox import capabilities  # noqa: E402
from sandbox import hals  # noqa: E402


def read_text(path):
    """return the text of a file"""
    try:
        with open(path) as handle:
            return handle.read()
    except FileNotFoundError:
        return ""


def policy_from(text, tmpdir):
    """return the policy read from text written to a temporary file"""
    path = os.path.join(tmpdir, "policy.conf")
    with open(path, "w") as handle:
        handle.write(text)
    policy, err = capabilities.read_policy(path)
    if policy is None:
        raise AssertionError("fixture policy did not parse: %s" % err)
    return policy


def virtual_device_cases():
    """return the virtual device test cases"""
    import tempfile
    cases = []

    with tempfile.TemporaryDirectory() as tmp:
        upper = os.path.join(tmp, "upper")
        fc = os.path.join(tmp, "vendor_file_contexts")
        open(fc, "w").close()
        apk = os.path.join(tmp, "app.apk")
        rro = os.path.join(tmp, "rro.apk")
        with open(apk, "w") as h:
            h.write("fake apk")
        with open(rro, "w") as h:
            h.write("fake rro apk")

        staged = hals._stage_virtual_device(upper, fc, apk, rro)
        cases.append(("_stage_virtual_device reports staged when both inputs exist", staged))
        cases.append(("the apk lands under priv-app/RhizoVirtualDevice",
                      os.path.exists(os.path.join(upper, "priv-app/RhizoVirtualDevice/RhizoVirtualDevice.apk"))))
        cases.append(("the rro apk lands under overlay",
                      os.path.exists(os.path.join(upper, "overlay/RhizoAutomotiveProjectionRro.apk"))))
        cases.append(("the privapp allowlist is staged",
                      os.path.exists(os.path.join(upper, "etc/permissions/privapp-permissions-rhizo-virtualdevice.xml"))))
        with open(fc) as h:
            fc_text = h.read()
        cases.append(("the apk gets a file_contexts line",
                      "RhizoVirtualDevice\\.apk" in fc_text))
        cases.append(("the rro apk gets a file_contexts line",
                      "RhizoAutomotiveProjectionRro\\.apk" in fc_text))

    with tempfile.TemporaryDirectory() as tmp:
        upper = os.path.join(tmp, "upper")
        fc = os.path.join(tmp, "vendor_file_contexts")
        open(fc, "w").close()
        missing_staged = hals._stage_virtual_device(
            upper, fc, os.path.join(tmp, "no-app.apk"), os.path.join(tmp, "no-rro.apk"))
        cases.append(("a missing build stages nothing rather than a partial tree",
                      not missing_staged and not os.path.exists(upper)))

    prev = os.environ.get(capabilities.PATH_ENV)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            off_conf = os.path.join(tmp, "off.conf")
            with open(off_conf, "w") as h:
                h.write("[devices]\nvirtual = no\nbluetooth = no\n")
            os.environ[capabilities.PATH_ENV] = off_conf
            off_text = hals.vendor_manifest_xml()
            base_text = hals.guest_files.read("vendor/manifest.xml")
            cases.append(("devices.virtual off leaves vendor-manifest.xml unchanged",
                          off_text == base_text))
            cases.append(("the camera provider HAL is absent when off",
                          "ICameraProvider/virtual/0" not in off_text))

            on_conf = os.path.join(tmp, "on.conf")
            with open(on_conf, "w") as h:
                h.write("[devices]\nvirtual = yes\nbluetooth = no\n")
            os.environ[capabilities.PATH_ENV] = on_conf
            on_text = hals.vendor_manifest_xml()
            cases.append(("the camera provider HAL is present when on",
                          "ICameraProvider/virtual/0" in on_text))
    finally:
        if prev is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev

    cases.append(("devices.virtual defaults off",
                  capabilities.CAPABILITIES["devices.virtual"]["default"] is False))

    calls = []
    real_stage = hals._stage_virtual_device
    hals._stage_virtual_device = lambda *a: (calls.append(a), True)[1]
    prev = os.environ.get(capabilities.PATH_ENV)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            off_conf = os.path.join(tmp, "off.conf")
            with open(off_conf, "w") as h:
                h.write("[devices]\nvirtual = no\nbluetooth = no\n")
            os.environ[capabilities.PATH_ENV] = off_conf
            off_result = hals.stage_virtual_device()
            cases.append(("stage_virtual_device() off returns False", off_result is False))
            cases.append(("stage_virtual_device() off never calls _stage_virtual_device", calls == []))

            on_conf = os.path.join(tmp, "on.conf")
            with open(on_conf, "w") as h:
                h.write("[devices]\nvirtual = yes\nbluetooth = no\n")
            os.environ[capabilities.PATH_ENV] = on_conf
            on_result = hals.stage_virtual_device()
            cases.append(("stage_virtual_device() on calls _stage_virtual_device once", len(calls) == 1))
            cases.append(("stage_virtual_device() on targets the real /product upper tree",
                          bool(calls) and calls[0][0] == "/run/rhizo/product_upper"))
            cases.append(("stage_virtual_device() on returns what _stage_virtual_device returned",
                          on_result is True))
    finally:
        hals._stage_virtual_device = real_stage
        if prev is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev

    cil_text = open(os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")).read()
    mounts_text = open(os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")).read()
    cases += device_policy_cases(cil_text, mounts_text)
    return cases


def desktop_bridge_cases():
    """return the RhizoDesktop staging test cases"""
    import tempfile
    cases = []
    with tempfile.TemporaryDirectory() as tmp:
        upper = os.path.join(tmp, "upper")
        fc = os.path.join(tmp, "vendor_file_contexts")
        open(fc, "w").close()
        apk = os.path.join(tmp, "app.apk")
        with open(apk, "w") as h:
            h.write("fake apk")
        staged = hals._stage_desktop_bridge(upper, fc, apk)
        dst = os.path.join(upper, "app/RhizoDesktop/RhizoDesktop.apk")
        cases.append(("_stage_desktop_bridge reports staged when the apk exists", staged))
        cases.append(("the desktop bridge lands under /system_ext/app/RhizoDesktop, mode 0644",
                      os.path.exists(dst) and (os.stat(dst).st_mode & 0o777) == 0o644))
        cases.append(("the desktop bridge gets a system_file contexts line",
                      "/system_ext/app/RhizoDesktop/RhizoDesktop\\.apk u:object_r:system_file:s0"
                      in open(fc).read()))
        cases.append(("the desktop bridge is staged with no privapp allowlist",
                      not os.path.exists(os.path.join(upper, "etc/permissions"))))
        missing = hals._stage_desktop_bridge(
            os.path.join(tmp, "upper2"), fc, os.path.join(tmp, "no-app.apk"))
        cases.append(("a missing desktop bridge stages nothing",
                      not missing and not os.path.exists(os.path.join(tmp, "upper2"))))

        wanted = {}
        for label, text in (("defaults", ""),
                            ("all four off", "[desktop]\nclipboard = off\nnotifications = no\n"
                                             "drag = no\nopen_uri = \n"),
                            ("only open_uri", "[desktop]\nclipboard = off\nnotifications = no\n"
                                              "drag = no\n"),
                            ("only the pointer", "[desktop]\nclipboard = off\nnotifications = no\n"
                                                 "drag = no\nopen_uri = \npointer = yes\n")):
            wanted[label] = hals.desktop_bridge_wanted(policy_from(text or "\n", tmp))
        cases.append(("the desktop bridge is staged at the defaults", wanted["defaults"] is True))
        cases.append(("the desktop bridge is absent with all four crossings off", wanted["all four off"] is False))
        cases.append(("one crossing on stages the desktop bridge", wanted["only open_uri"] is True))
        cases.append(("desktop.pointer alone does not stage the desktop bridge",
                      wanted["only the pointer"] is False))

    calls = []
    real_stage = hals._stage_desktop_bridge
    hals._stage_desktop_bridge = lambda *a: (calls.append(a), True)[1]
    prev = os.environ.get(capabilities.PATH_ENV)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            off_conf = os.path.join(tmp, "off.conf")
            with open(off_conf, "w") as h:
                h.write("[desktop]\nclipboard = off\nnotifications = no\ndrag = no\nopen_uri = \n")
            os.environ[capabilities.PATH_ENV] = off_conf
            off_result = hals.stage_desktop_bridge()
            cases.append(("stage_desktop_bridge() with all four off never stages",
                          off_result is False and calls == []))
            os.environ[capabilities.PATH_ENV] = os.path.join(tmp, "absent.conf")
            on_result = hals.stage_desktop_bridge()
            cases.append(("stage_desktop_bridge() at the defaults stages onto the system_ext upper",
                          on_result is True and len(calls) == 1
                          and calls[0][0] == "%s/system_ext_upper" % hals.RUN_ROOT
                          and calls[0][2].endswith("/RhizoDesktop.apk")))
    finally:
        hals._stage_desktop_bridge = real_stage
        if prev is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev
    return cases


def device_policy_cases(cil_text, mounts_text):
    """return the device-state policy test cases"""
    cases = []
    cases.append(("priv_app is granted the device-state directory's watch/read permission",
                  "(allow priv_app rhizo_device_state_file (dir (search open read getattr watch)))"
                  in cil_text))
    cases.append(("priv_app is granted the device-state files' own read permission",
                  "(allow priv_app rhizo_device_state_file (file (read open getattr map ioctl)))"
                  in cil_text))
    bind_calls = mounts_text.count('mount(RHIZO_DEVICE_STATE_DIR, device_state_dst, None, MS_BIND)')
    remount_calls = mounts_text.count('mount(None, device_state_dst, None, MS_BIND | MS_REMOUNT | MS_RDONLY)')
    cases.append(("the device-state directory is bound exactly once (no separate VDM-only bind)",
                  bind_calls == 1))
    cases.append(("the one bind is remounted read-only exactly once",
                  remount_calls == 1))
    return cases


def _is_cap_guard(node, cap="trace.host_delay"):
    """test a node for a not-allows guard"""
    t = getattr(node, "test", None)
    if not (isinstance(node, ast.If) and isinstance(t, ast.UnaryOp) and isinstance(t.op, ast.Not)):
        return False
    c = t.operand
    return (isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr == "allows"
            and len(c.args) == 1 and isinstance(c.args[0], ast.Constant)
            and c.args[0].value == cap)


def bind_guarded(mounts_text, cap, path):
    """test path binds under a cap guard"""
    try:
        tree = ast.parse(mounts_text)
    except SyntaxError:
        return False
    parent = {}
    for n in ast.walk(tree):
        for c in ast.iter_child_nodes(n):
            parent[c] = n

    def under_orelse_of_guard(node):
        """check that a node is in the else branch of a capability guard"""
        child, up = node, parent.get(node)
        while up is not None:
            if _is_cap_guard(up, cap) and child in up.orelse:
                return True
            child, up = up, parent.get(up)
        return False

    mentions = [n for n in ast.walk(tree) if isinstance(n, ast.Constant)
                and isinstance(n.value, str) and path in n.value]
    binds = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and isinstance(n.func, ast.Attribute) and n.func.attr == "bind_private"
             and n.args and isinstance(n.args[0], ast.Constant) and n.args[0].value == path]
    return len(binds) == 1 and bool(mentions) and all(under_orelse_of_guard(m) for m in mentions)


def host_delay_bind_guarded(mounts_text):
    """return whether the host delay bind is guarded by its capability"""
    return bind_guarded(mounts_text, "trace.host_delay", "/run/rhizo-delay")


def _is_kmsg(call):
    """return whether a call is a call to kmsg"""
    return isinstance(call.func, ast.Name) and call.func.id == "kmsg"


def _only_kmsg_then_return(body):
    """test a guard body logs and returns"""
    if not body or not isinstance(body[-1], ast.Return):
        return False
    return all(isinstance(b, ast.Expr) and isinstance(b.value, ast.Call) and _is_kmsg(b.value)
               for b in body[:-1])


def host_delay_stage_guarded(hals_text):
    """check stage_host_delay returns at its guard"""
    try:
        tree = ast.parse(hals_text)
    except SyntaxError:
        return False
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "stage_host_delay"), None)
    if fn is None:
        return False
    for stmt in fn.body:
        if _is_cap_guard(stmt):
            return _only_kmsg_then_return(stmt.body)
        docstring = (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant)
                     and isinstance(stmt.value.value, str))
        policy_read = (isinstance(stmt, ast.Assign) and isinstance(stmt.value, ast.Call)
                       and isinstance(stmt.value.func, ast.Attribute)
                       and stmt.value.func.attr == "policy_or_deny"
                       and not any(isinstance(n, ast.Call) for a in stmt.value.args + [k.value for k in stmt.value.keywords]
                                   for n in ast.walk(a)))
        if not (docstring or policy_read):
            return False
    return False


def host_delay_cases(mounts_text, unit_text, hals_text):
    """return the trace.host_delay test cases"""
    import tempfile
    cases = []
    cases.append(("trace.host_delay is off by default",
                  not capabilities.defaults().allows("trace.host_delay")))
    cases.append(("an unparseable policy denies trace.host_delay",
                  not capabilities.deny_all().allows("trace.host_delay")))
    with tempfile.TemporaryDirectory() as tmp:
        on = policy_from("[trace]\nhost_delay = yes\n", tmp)
        cases.append(("trace.host_delay turns on when granted", on.allows("trace.host_delay")))
        overlay = os.path.join(tmp, "instance.conf")
        with open(overlay, "w") as h:
            h.write("[trace]\nhost_delay = yes\n")
        base = os.path.join(tmp, "base.conf")
        with open(base, "w") as h:
            h.write("\n")
        policy, err = capabilities.read_policy(base, overlay)
        cases.append(("an instance overlay may not set trace.host_delay", policy is None and err is not None))
    cases.append(("the unit's ExecCondition gates on trace.host_delay",
                  "\nExecCondition=/usr/lib/rhizo/tools/capability-allowed.sh trace.host_delay\n"
                  in "\n" + unit_text))
    cases.append(("the host-delay socket dir is only ever named inside the capability's own else branch",
                  host_delay_bind_guarded(mounts_text)))
    cases.append(("the Android host-delay daemon returns before any call that could write "
                  "unless trace.host_delay is allowed", host_delay_stage_guarded(hals_text)))
    return cases


def headroom_cases(mounts_text, unit_text):
    """return the power.cpu_headroom test cases"""
    import tempfile
    cases = []
    cases.append(("power.cpu_headroom is off by default",
                  not capabilities.defaults().allows("power.cpu_headroom")))
    cases.append(("an unparseable policy denies power.cpu_headroom",
                  not capabilities.deny_all().allows("power.cpu_headroom")))
    with tempfile.TemporaryDirectory() as tmp:
        on = policy_from("[power]\ncpu_headroom = yes\n", tmp)
        cases.append(("power.cpu_headroom turns on when granted", on.allows("power.cpu_headroom")))
        overlay = os.path.join(tmp, "instance.conf")
        with open(overlay, "w") as h:
            h.write("[power]\ncpu_headroom = yes\n")
        base = os.path.join(tmp, "base.conf")
        with open(base, "w") as h:
            h.write("\n")
        policy, err = capabilities.read_policy(base, overlay)
        cases.append(("an instance overlay may not set power.cpu_headroom", policy is None and err is not None))
    cases.append(("the unit's ExecCondition gates on power.cpu_headroom",
                  "\nExecCondition=/usr/lib/rhizo/tools/capability-allowed.sh power.cpu_headroom\n"
                  in "\n" + unit_text))
    cases.append(("the headroom socket dir is only ever named inside the capability's own else branch",
                  bind_guarded(mounts_text, "power.cpu_headroom", "/run/rhizo-headroom")))
    return cases


def bluetooth_cases():
    """return the Bluetooth test cases"""
    import tempfile
    cases = []
    prev_conf, prev_sysfs = os.environ.get(capabilities.PATH_ENV), hals.BLUETOOTH_SYSFS
    try:
        with tempfile.TemporaryDirectory() as tmp:
            with_hci = os.path.join(tmp, "with-hci")
            os.makedirs(os.path.join(with_hci, "hci0"))
            without_hci = os.path.join(tmp, "without-hci")
            os.makedirs(without_hci)
            for granted in ("yes", "no"):
                conf = os.path.join(tmp, granted + ".conf")
                with open(conf, "w") as h:
                    h.write("[devices]\nbluetooth = %s\n" % granted)
                os.environ[capabilities.PATH_ENV] = conf
                for sysfs, controller in ((with_hci, True), (without_hci, False),
                                          (os.path.join(tmp, "absent"), False)):
                    hals.BLUETOOTH_SYSFS = sysfs
                    want = granted == "yes" and controller
                    declared = "IBluetoothHci/default" in hals.vendor_manifest_xml()
                    cases.append(("bluetooth=%s, controller=%s: the manifest declares IBluetoothHci exactly when armed"
                                  % (granted, controller), declared == want and hals.bluetooth_armed() == want))
    finally:
        hals.BLUETOOTH_SYSFS = prev_sysfs
        if prev_conf is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev_conf
    cases.append(("the staged manifest hardcodes no Bluetooth HAL",
                  "IBluetoothHci" not in hals.guest_files.read("vendor/manifest.xml")))
    return cases

def check():
    """run the capability wiring cases"""
    import tempfile
    fails = []
    ports = capabilities.sandbox_input_ports

    with tempfile.TemporaryDirectory() as tmp:
        default = capabilities.defaults()
        services = default.scope("network.services")

        cases = []
        cases.append(("mdns is not started by default", "mdns" not in services))
        cases.append(("no mdns port is opened by default",
                      ("udp", 5353) not in ports(services, 8118, 47100)))

        granted = policy_from("[network]\nservices = dhcp, dns, ra, proxy, mdns\n", tmp)
        granted_services = granted.scope("network.services")
        cases.append(("mdns starts when it is granted", "mdns" in granted_services))
        cases.append(("the mdns port opens when it is granted",
                      ("udp", 5353) in ports(granted_services, 8118, 47100)))

        narrow = policy_from("[network]\nservices = dhcp\n", tmp)
        narrow_ports = ports(narrow.scope("network.services"), 8118, 47100)
        cases.append(("withholding dns closes both dns ports",
                      ("udp", 53) not in narrow_ports and ("tcp", 53) not in narrow_ports))
        cases.append(("withholding proxy closes the proxy port",
                      ("tcp", 8118) not in narrow_ports))
        cases.append(("a granted service keeps its port", ("udp", 67) in narrow_ports))

        broken = os.path.join(tmp, "broken.conf")
        with open(broken, "w") as handle:
            handle.write("[network]\nservices = dhcp, nonsense\n")
        denied = capabilities.policy_or_deny(broken)
        cases.append(("an unparseable policy denies every service",
                      denied.scope("network.services") == frozenset()))
        cases.append(("an unparseable policy denies the clipboard",
                      not denied.allows("desktop.clipboard")))

        typo = os.path.join(tmp, "typo.conf")
        with open(typo, "w") as handle:
            handle.write("[desktop]\nnotifcations = no\n")
        _, err = capabilities.read_policy(typo)
        cases.append(("a misspelled capability refuses the file", err is not None))

        absent = capabilities.policy_or_deny(os.path.join(tmp, "nope.conf"))
        cases.append(("an absent policy runs the documented defaults",
                      absent == capabilities.defaults()))

    mounts = os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")
    with open(mounts) as handle:
        mounts_text = handle.read()
    guards = {
        "devices.dri": 'dri_nodes = ("renderD128", "card0") if policy.allows("devices.dri")',
        "devices.uinput": 'if not policy.allows("devices.uinput"):',
        "devices.tun": 'if not policy.allows("devices.tun"):',
    }
    for capability, guard in sorted(guards.items()):
        cases.append(("%s gates its own mknod" % capability, guard in mounts_text))
    for node, capability in (("/dev/uinput", "devices.uinput"), ("/dev/tun", "devices.tun")):
        mknod_at = mounts_text.find('os.mknod(f"{NEWROOT}%s"' % node)
        guard_at = mounts_text.find(guards[capability])
        cases.append(("%s is withheld before it is created" % node,
                      -1 < guard_at < mknod_at))

    nb_dir = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "services", "netbridged"))
    if nb_dir not in sys.path:
        sys.path.insert(0, nb_dir)
    nb_proxy_path = os.path.join(nb_dir, "nb_proxy.py")
    spec = importlib.util.spec_from_file_location("nb_proxy_for_wiring", nb_proxy_path)
    nb_proxy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nb_proxy)
    default_target = nb_proxy.target_policy_for_mode(nb_proxy.CONNECT_POLICY_DEFAULT)
    for probe in ("127.0.0.1", "169.254.169.254", "::1"):
        cases.append(("the default proxy policy refuses %s" % probe,
                      not default_target.is_allowed(probe)))
    cases.append(("the default proxy policy still allows an ordinary address",
                  default_target.is_allowed("93.184.216.34")))
    cases.append(("an unset proxy mode is deny-local",
                  nb_proxy.CONNECT_POLICY_DEFAULT == nb_proxy.CONNECT_POLICY_DENY_LOCAL))

    deskd_path = os.path.join(REPO, "src", "services", "deskbridge", "deskd.py")
    spec = importlib.util.spec_from_file_location("rhizo_deskd_for_wiring", deskd_path)
    deskd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(deskd)
    with tempfile.TemporaryDirectory() as tmp:
        cases.append(("the default policy grants clipboard and drag, not pointer",
                      deskd.wlbridge_caps(capabilities.defaults())
                      == {"clipboard", "drag"}))
        cases.append(("a denied policy grants no wayland global at all",
                      deskd.wlbridge_caps(capabilities.deny_all()) == set()))
        off = policy_from("[desktop]\nclipboard = off\ndrag = no\npointer = no\n", tmp)
        cases.append(("withholding all three leaves no global to bind",
                      deskd.wlbridge_caps(off) == set()))
        clip_only = policy_from("[desktop]\ndrag = no\npointer = no\n", tmp)
        cases.append(("clipboard alone binds no pointer",
                      deskd.wlbridge_caps(clip_only) == {"clipboard"}))
        drag_only = policy_from("[desktop]\nclipboard = off\npointer = no\n", tmp)
        cases.append(("drag no longer implies the pointer",
                      deskd.wlbridge_caps(drag_only) == {"drag"}))
        pointer_only = policy_from("[desktop]\nclipboard = off\ndrag = no\npointer = yes\n", tmp)
        cases.append(("pointer alone binds only the pointer",
                      deskd.wlbridge_caps(pointer_only) == {"pointer"}))

    wlbridge = os.path.join(REPO, "src", "services", "deskbridge", "wlbridge.c")
    with open(wlbridge) as handle:
        wl_text = handle.read()
    binds = {
        "clipboard": "zwlr_data_control_manager_v1_interface.name",
        "pointer": "zwlr_virtual_pointer_manager_v1_interface.name",
        "drag": "wl_data_device_manager_interface.name",
    }
    for cap, iface in sorted(binds.items()):
        at = wl_text.find(iface)
        guard = wl_text.find("if (!cap_%s) return;" % cap, at)
        next_branch = wl_text.find("} else if", at + 1)
        cases.append(("rhizo-wlbridge refuses to bind %s without the capability" % cap,
                      -1 < at < guard < (next_branch if next_branch > 0 else len(wl_text))))
    cases.append(("rhizo-wlbridge requires --caps rather than defaulting open",
                  '"rhizo-wlbridge: --caps is required' in wl_text))

    cases += virtual_device_cases()
    cases += desktop_bridge_cases()
    cases += bluetooth_cases()
    cases += host_delay_cases(mounts_text, read_text(os.path.join(HERE, "..", "..", "..", "..", "src", "services", "delayd", "delayd.service")),
                              read_text(os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")))
    cases += headroom_cases(mounts_text, read_text(os.path.join(HERE, "..", "..", "..", "..", "src", "services", "headroomd", "headroomd.service")))

    if not cases:
        return ["no wiring cases ran"]
    for label, held in cases:
        if not held:
            fails.append(label)
    return fails


def selftest():
    """assert each inverted claim fails"""
    import tempfile
    ports = capabilities.sandbox_input_ports
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        inverted = [
            ("default policy does NOT start mdns",
             "mdns" in capabilities.defaults().scope("network.services")),
            ("withholding a service does NOT keep its port",
             ("udp", 53) in ports(frozenset({"dhcp"}), 8118, 47100)),
            ("an unparseable policy does NOT fall back to defaults",
             capabilities.policy_or_deny(
                 os.path.join(tmp, "no.conf")) == capabilities.deny_all()),
        ]
        upper = os.path.join(tmp, "device-upper")
        fc = os.path.join(tmp, "device-fc")
        open(fc, "w").close()
        missing_staged = hals._stage_virtual_device(
            upper, fc, os.path.join(tmp, "no-app.apk"), os.path.join(tmp, "no-rro.apk"))
        inverted.append(("_stage_virtual_device does NOT report staged with missing inputs",
                         missing_staged))
        inverted.append(("_stage_virtual_device does NOT create the upper tree with missing inputs",
                         os.path.exists(upper)))
        desk_upper = os.path.join(tmp, "desk-upper")
        inverted.append(("_stage_desktop_bridge does NOT report staged with no apk",
                         hals._stage_desktop_bridge(desk_upper, fc, os.path.join(tmp, "no-app.apk"))))
        inverted.append(("desktop.pointer alone does NOT stage the desktop bridge",
                         hals.desktop_bridge_wanted(policy_from(
                             "[desktop]\nclipboard = off\nnotifications = no\ndrag = no\nopen_uri = \n"
                             "pointer = yes\n", tmp))))

    real_cil = open(os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")).read()
    real_mounts = open(os.path.join(REPO, "src", "androidd", "sandbox", "rootfs.py")).read()

    no_dir_grant = real_cil.replace(
        "(allow priv_app rhizo_device_state_file (dir (search open read getattr watch)))", "")
    cil_cases = dict(device_policy_cases(no_dir_grant, real_mounts))
    inverted.append(("removing the priv_app dir grant does NOT still pass that case",
                     cil_cases["priv_app is granted the device-state directory's watch/read permission"]))

    no_file_grant = real_cil.replace(
        "(allow priv_app rhizo_device_state_file (file (read open getattr map ioctl)))", "")
    cil_cases = dict(device_policy_cases(no_file_grant, real_mounts))
    inverted.append(("removing the priv_app file grant does NOT still pass that case",
                     cil_cases["priv_app is granted the device-state files' own read permission"]))

    doubled_bind = real_mounts.replace(
        "if mount(RHIZO_DEVICE_STATE_DIR, device_state_dst, None, MS_BIND):",
        "if mount(RHIZO_DEVICE_STATE_DIR, device_state_dst, None, MS_BIND):\n"
        "        pass\n"
        "    if mount(RHIZO_DEVICE_STATE_DIR, device_state_dst, None, MS_BIND):", 1)
    mount_cases = dict(device_policy_cases(real_cil, doubled_bind))
    inverted.append(("a second bind call does NOT still pass the exactly-once case",
                     mount_cases["the device-state directory is bound exactly once (no separate VDM-only bind)"]))

    missing_remount = real_mounts.replace(
        "if device_state_bound and not mount(None, device_state_dst, None, MS_BIND | MS_REMOUNT | MS_RDONLY):",
        "if False:", 1)
    inverted.append(("the remount mutant's anchor is NOT in sandbox/rootfs.py", missing_remount == real_mounts))
    mount_cases = dict(device_policy_cases(real_cil, missing_remount))
    inverted.append(("a deleted remount call does NOT still pass the remount-once case",
                     mount_cases["the one bind is remounted read-only exactly once"]))

    fixture_unit = ("[Service]\nExecCondition=/usr/lib/rhizo/tools/capability-allowed.sh trace.host_delay\n")
    fixture_mounts = (
        'def f(policy):\n'
        '    if not policy.allows("trace.host_delay"):\n        state = "withheld"\n'
        '    elif not os.path.isdir("/run/rhizo-delay"):\n        state = "absent"\n'
        '    else:\n        core.bind_private("/run/rhizo-delay", dst)\n')
    fixture_hals = (
        'def stage_host_delay():\n    """doc"""\n'
        '    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)\n'
        '    if not policy.allows("trace.host_delay"):\n        kmsg("m")\n        return False\n'
        '    return _stage(a, b)\n')
    staged_case = "the Android host-delay daemon returns before any call that could write unless trace.host_delay is allowed"
    bind_case = "the host-delay socket dir is only ever named inside the capability's own else branch"
    held = dict(host_delay_cases(fixture_mounts, fixture_unit, fixture_hals))
    inverted.append(("the clean host-delay fixture does NOT fail a case", not all(held.values())))
    guard_line = '    if not policy.allows("trace.host_delay"):\n        kmsg("m")\n        return False\n'
    for label, mounts_text, unit_text, hals_text, case in (
            ("an ExecCondition that drops the capability does NOT pass", fixture_mounts,
             fixture_unit.replace(" trace.host_delay", ""), fixture_hals,
             "the unit's ExecCondition gates on trace.host_delay"),
            ("a bind in the guard's own branch does NOT pass",
             fixture_mounts.replace('state = "withheld"', 'core.bind_private("/run/rhizo-delay", d)'),
             fixture_unit, fixture_hals, bind_case),
            ("a bind before the guard does NOT pass",
             fixture_mounts.replace("def f(policy):\n", 'def f(policy):\n    core.bind_private("/run/rhizo-delay", d)\n'),
             fixture_unit, fixture_hals, bind_case),
            ("a bind through another helper still naming the dir after the guard does NOT pass",
             fixture_mounts + '    other("/run/rhizo-delay")\n', fixture_unit, fixture_hals, bind_case),
            ("a bind with no bind_private call does NOT pass",
             fixture_mounts.replace("core.bind_private(", "mount("), fixture_unit, fixture_hals, bind_case),
            ("a second bind does NOT pass",
             fixture_mounts + '    core.bind_private("/run/rhizo-delay", dst2)\n', fixture_unit, fixture_hals, bind_case),
            ("a write before the staging guard does NOT pass", fixture_mounts, fixture_unit,
             fixture_hals.replace(guard_line, '    open(x, "w")\n' + guard_line), staged_case),
            ("a write through an unlisted helper before the staging guard does NOT pass", fixture_mounts,
             fixture_unit, fixture_hals.replace(guard_line, '    install_things(x)\n' + guard_line), staged_case),
            ("a call nested in the policy read does NOT pass", fixture_mounts, fixture_unit,
             fixture_hals.replace("log=kmsg,", "log=prep(),"), staged_case),
            ("a staging guard that does something besides log and return does NOT pass", fixture_mounts,
             fixture_unit, fixture_hals.replace('kmsg("m")', 'prep(x)'), staged_case),
            ("a staging guard that falls through does NOT pass", fixture_mounts, fixture_unit,
             fixture_hals.replace("        return False\n", "        pass\n"), staged_case),
            ("a staging guard on another capability does NOT pass", fixture_mounts, fixture_unit,
             fixture_hals.replace("trace.host_delay", "trace.ftrace"), staged_case),
            ("a missing stage_host_delay does NOT pass", fixture_mounts, fixture_unit, "", staged_case)):
        inverted.append((label, dict(host_delay_cases(mounts_text, unit_text, hals_text))[case]))

    hr_unit = "[Service]\nExecCondition=/usr/lib/rhizo/tools/capability-allowed.sh power.cpu_headroom\n"
    hr_mounts = (
        'def f(policy):\n'
        '    if not policy.allows("power.cpu_headroom"):\n        state = "withheld"\n'
        '    elif not os.path.isdir("/run/rhizo-headroom"):\n        state = "absent"\n'
        '    else:\n        core.bind_private("/run/rhizo-headroom", dst)\n')
    hr_bind_case = "the headroom socket dir is only ever named inside the capability's own else branch"
    held = dict(headroom_cases(hr_mounts, hr_unit))
    inverted.append(("the clean headroom fixture does NOT fail a case", not all(held.values())))
    for label, mounts_text, unit_text, case in (
            ("a headroom ExecCondition that drops the capability does NOT pass", hr_mounts,
             hr_unit.replace(" power.cpu_headroom", ""), "the unit's ExecCondition gates on power.cpu_headroom"),
            ("a headroom bind in the guard's own branch does NOT pass",
             hr_mounts.replace('state = "withheld"', 'core.bind_private("/run/rhizo-headroom", d)'),
             hr_unit, hr_bind_case),
            ("a headroom bind before the guard does NOT pass",
             hr_mounts.replace("def f(policy):\n", 'def f(policy):\n    core.bind_private("/run/rhizo-headroom", d)\n'),
             hr_unit, hr_bind_case),
            ("a headroom bind through another helper still naming the dir after the guard does NOT pass",
             hr_mounts + '    other("/run/rhizo-headroom")\n', hr_unit, hr_bind_case),
            ("a headroom bind with no bind_private call does NOT pass",
             hr_mounts.replace("core.bind_private(", "mount("), hr_unit, hr_bind_case),
            ("a second headroom bind does NOT pass",
             hr_mounts + '    core.bind_private("/run/rhizo-headroom", dst2)\n', hr_unit, hr_bind_case),
            ("a headroom guard on another capability does NOT pass",
             hr_mounts.replace("power.cpu_headroom", "trace.host_delay"), hr_unit, hr_bind_case)):
        inverted.append((label, dict(headroom_cases(mounts_text, unit_text))[case]))

    for label, wrong in inverted:
        print("SELFTEST %s: %s" % ("OK" if not wrong else "FAIL", label))
        if wrong:
            bad += 1
    fails = check()
    print("SELFTEST %s: the live wiring holds (%d failing case(s))"
          % ("OK" if not fails else "FAIL", len(fails)))
    for line in fails:
        print("    %s" % line)
    return 1 if (bad or fails) else 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    fails = check()
    for line in fails:
        print("FAIL: capability wiring: %s" % line)
    if not fails:
        print("capability wiring: a withheld capability is absent from the argv, "
              "the firewall allowlist and the handler defaults")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
