#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path[:0] = [os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")), HERE]

from sandbox import capabilities  # noqa: E402


def policy_from(text, tmpdir, name):
    """write policy text to a file and read it back as a policy"""
    path = os.path.join(tmpdir, name)
    with open(path, "w") as handle:
        handle.write(text)
    return capabilities.read_policy(path)


MAC_BIND_RE = re.compile(
    r"""^\s*GUEST_MAC\s*=\s*([A-Za-z_][A-Za-z0-9_]*|"[^"]*"|'[^']*')""", re.M)
MAC_SET_RE = re.compile(
    r'"ip"\s*,\s*"link"\s*,\s*"add"\s*,\s*TMP_GUEST_IF\s*,\s*"address"\s*,\s*GUEST_MAC')
MAC_VALUE_RE = re.compile(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\Z")
ENV_MARK = "SERVER_PROFILE_ENV_JSON:"
POOL_FIELDS = ("NET_POOL_START", "NET_POOL_END")
PROBE_IDS = (0, 1, 99)


def _env_constants(sandbox_id, fields, vm_dir):
    """return core constants for a sandbox id"""
    src = ("import sys, json; sys.path.insert(0, %r); from sandbox import core as e; "
           "print(%r + json.dumps({k: getattr(e, k, None) for k in %r}))"
           % (vm_dir, ENV_MARK, list(fields)))
    env = dict(os.environ)
    env["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    proc = subprocess.run([sys.executable, "-c", src], env=env,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        if line.startswith(ENV_MARK):
            return json.loads(line[len(ENV_MARK):])
    return None


def _well_formed(mac):
    """return whether a MAC value is well formed"""
    return bool(mac) and bool(MAC_VALUE_RE.match(str(mac)))


def _local_unicast(mac):
    """return whether a MAC is well formed, locally administered and unicast"""
    return _well_formed(mac) and (int(str(mac).split(":")[0], 16) & 0x03) == 0x02


def _nb_dhcp():
    """import nb_dhcp from the netbridged source"""
    netbridged = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "services", "netbridged"))
    if netbridged not in sys.path:
        sys.path.insert(0, netbridged)
    import nb_dhcp  # noqa: E402
    return nb_dhcp


def _leases_for(nb, mac_a, mac_b, pool_start, pool_end):
    """return the DHCP addresses allocated to two MACs from a pool"""
    svc = types.SimpleNamespace(
        leases={}, pool_start=nb.ip_to_int(pool_start),
        pool_end=nb.ip_to_int(pool_end),
        cfg=types.SimpleNamespace(lease_seconds=3600))
    svc._wall_for_mono = lambda m: 0
    svc._save_leases = lambda: None
    alloc = nb.DhcpService._allocate
    return alloc(svc, mac_a), alloc(svc, mac_b)


def mac_cases(vm_dir=os.path.join(REPO, "src", "androidd")):
    """return the veth MAC test cases"""
    cases = []
    launcher = open(os.path.join(vm_dir, "boot.py")).read()
    bound = MAC_BIND_RE.search(launcher)
    token = bound.group(1) if bound else None
    literal = token.strip("\"'") if token and token[:1] in "\"'" else None
    name = token if token and literal is None else None

    cases.append(("the sandbox veth is created with an explicit MAC",
                  bool(token) and bool(MAC_SET_RE.search(launcher))))
    cases.append(("the veth MAC is derived per instance, never a literal",
                  name is not None))

    fields = POOL_FIELDS + ((name,) if name else ())
    by_id = {}
    for probe in PROBE_IDS:
        vals = _env_constants(probe, fields, vm_dir) or {}
        by_id[probe] = (vals.get(name) if name else literal,
                        vals.get("NET_POOL_START"), vals.get("NET_POOL_END"))

    macs = [mac for mac, _, _ in by_id.values()]
    cases.append(("every id in range derives a well-formed MAC",
                  all(_well_formed(mac) for mac in macs)))
    cases.append(("that MAC is locally administered and unicast",
                  all(_local_unicast(mac) for mac in macs)))
    cases.append(("no two instances present the same MAC",
                  len(set(macs)) == len(PROBE_IDS)))

    nb = _nb_dhcp()
    restart_keeps, change_moves = True, True
    for _probe, (mac, pool_start, pool_end) in sorted(by_id.items()):
        if not (_well_formed(mac) and pool_start and pool_end):
            restart_keeps = change_moves = False
            continue
        first, again = _leases_for(nb, mac, mac, pool_start, pool_end)
        restart_keeps = restart_keeps and first == pool_start and again == pool_start
        rnd_first, rnd_again = _leases_for(nb, "52:54:00:aa:bb:01",
                                           "52:54:00:aa:bb:02", pool_start, pool_end)
        change_moves = change_moves and rnd_first == pool_start and rnd_again != pool_start
    cases.append(("a restart on that MAC is handed POOL_START again", restart_keeps))
    cases.append(("a changing MAC would move the sandbox off POOL_START", change_moves))
    return cases


def load_hals(path):
    """load sandbox/hals.py from a path"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("rhizo_hals_under_test_%d" % id(path), path)
    module = importlib.util.module_from_spec(spec)
    devnull = open(os.devnull, "w")
    saved = sys.stdout, sys.stderr
    sys.stdout = sys.stderr = devnull
    try:
        spec.loader.exec_module(module)
    finally:
        sys.stdout, sys.stderr = saved
        devnull.close()
    return module


DAY_MS = 24 * 3600 * 1000
WEEK_MS = 7 * DAY_MS


def adbkeystore_authorized(system_keys, user_keys, temp_record, now_ms, allowed_ms=WEEK_MS):
    """return the keys adbd authorizes"""
    record = dict(temp_record)
    for k in user_keys:
        if k not in record:
            record[k] = now_ms
    record = {k: t for k, t in record.items() if not now_ms > t + allowed_ms}
    user_after = [k for k in user_keys if k in record]
    return set(system_keys) | set(user_after), user_after, record


RIG = "QAAArig rig@host"
OPERATOR = "QAAAoperator operator@host"
DIALOG_OLD = "QAAAdialogold user@host"
DIALOG_NEW = "QAAAdialognew user@host"
ADB_SYSTEM = "registered keys are staged into the sandbox's /adb_keys, never /data/misc/adb"
ADB_NONE = "no registered key stages no /adb_keys"
ADB_EXPIRY = ("a restart with an old temp-keys record keeps the staged keys authorized, "
              "and a dialog-granted key older than 7 days is still pruned")


def adb_keys_cases(hals_path=os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")):
    """return the stage_adb_keys test cases"""
    hals = load_hals(hals_path)
    cases = []
    if not hasattr(hals, "stage_adb_keys"):
        return [(ADB_SYSTEM + " (no stage_adb_keys in sandbox/hals.py)", False),
                (ADB_NONE + " (no stage_adb_keys in sandbox/hals.py)", False),
                (ADB_EXPIRY + " (no stage_adb_keys in sandbox/hals.py)", False)]
    with tempfile.TemporaryDirectory() as tmp:
        rig, op = os.path.join(tmp, "adbkey.pub"), os.path.join(tmp, "operator-keys")
        open(rig, "w").write(RIG + "\n")
        open(op, "w").write("\n" + OPERATOR + "\n")
        misc = os.path.join(tmp, "data", "misc", "adb")
        os.makedirs(misc)
        user_file, temp_file = os.path.join(misc, "adb_keys"), os.path.join(misc, "adb_temp_keys.xml")
        open(user_file, "w").write("%s\n%s\n%s\n" % (RIG, DIALOG_OLD, DIALOG_NEW))
        open(temp_file, "w").write("framework-owned\n")
        before = {f: open(f).read() for f in (user_file, temp_file)}
        out = os.path.join(tmp, "adb_keys")
        try:
            hals.stage_adb_keys((rig, op), out)
            error = None
        except OSError as exc:
            error = exc
        staged = open(out).read().split("\n") if os.path.exists(out) else []
        mode = os.stat(out).st_mode & 0o777 if os.path.exists(out) else None
        untouched = all(os.path.exists(f) and open(f).read() == before[f] for f in before)
        cases.append((ADB_SYSTEM + ("" if error is None else " (%s)" % error),
                      error is None and [l for l in staged if l] == [RIG, OPERATOR] and mode == 0o644
                      and untouched))
        now = 1790472000000
        record = {RIG: now - 30 * DAY_MS, DIALOG_OLD: now - 8 * DAY_MS, DIALOG_NEW: now - 2 * DAY_MS}
        ok_keys, user_after, _ = adbkeystore_authorized([l for l in staged if l], open(user_file).read().splitlines(),
                                                        record, now)
        bare, _, _ = adbkeystore_authorized([], open(user_file).read().splitlines(), record, now)
        cases.append((ADB_EXPIRY,
                      error is None and {RIG, OPERATOR, DIALOG_NEW} <= ok_keys and DIALOG_OLD not in ok_keys
                      and DIALOG_OLD not in user_after and RIG not in bare))
        os.remove(rig)
        os.remove(op)
        try:
            hals.stage_adb_keys((rig, op), out)
            error = None
        except OSError as exc:
            error = exc
        cases.append((ADB_NONE + ("" if error is None else " (%s)" % error),
                      error is None and not os.path.exists(out)))
    return cases


def check():
    """return the config test cases"""
    cases = []
    with tempfile.TemporaryDirectory() as tmp:
        default = capabilities.defaults()
        cases.append(("an unconfigured host runs desktop",
                      default.scope("rhizo.profile") == "desktop"))
        cases.append(("an unconfigured host's idle_stop_s is 0 (never)",
                      default.scope("server.idle_stop_s") == 0))
        cases.append(("an unconfigured host's adb_reach is host",
                      default.scope("server.adb_reach") == "host"))
        cases.append(("an unconfigured host's display is the documented default",
                      default.scope("server.display") == "1280x800@60/400"))
        cases.append(("an unconfigured host's screen_off_s is 60",
                      default.scope("server.screen_off_s") == 60))

        policy, err = policy_from("[server]\ndisplay = not-a-geometry\n", tmp, "bad-display.conf")
        cases.append(("a malformed display value refuses the file",
                      policy is None and err is not None))
        policy, err = policy_from("[server]\ndisplay = 0x800@60/160\n", tmp, "zero-display.conf")
        cases.append(("a zero width in display refuses the file",
                      policy is None and err is not None))
        policy, err = policy_from("[server]\ndisplay = 1280x800@60\n", tmp, "short-display.conf")
        cases.append(("a display value missing /dpi refuses the file",
                      policy is None and err is not None))

        policy, err = policy_from("[server]\nidle_stop_s = -1\n", tmp, "neg-idle.conf")
        cases.append(("a negative idle_stop_s refuses the file",
                      policy is None and err is not None))
        policy, err = policy_from("[server]\nidle_stop_s = 3.5\n", tmp, "float-idle.conf")
        cases.append(("a non-integer idle_stop_s refuses the file",
                      policy is None and err is not None))
        policy, err = policy_from("[server]\nidle_stop_s = 0\n", tmp, "zero-idle.conf")
        cases.append(("an explicit idle_stop_s=0 parses", policy is not None))

        policy, err = policy_from("[server]\nadb_reach = wan\n", tmp, "bad-reach.conf")
        cases.append(("an unknown adb_reach refuses the file",
                      policy is None and err is not None))

        policy, err = policy_from("[rhizo]\nprofile = server\n", tmp, "server.conf")
        cases.append(("profile=server parses", policy is not None))
        if policy is not None:
            cases.append(("profile=server turns desktop.clipboard off",
                          policy.scope("desktop.clipboard") == "off"))
            cases.append(("profile=server turns desktop.notifications off",
                          policy.scope("desktop.notifications") is False))
            cases.append(("profile=server turns desktop.drag off",
                          policy.scope("desktop.drag") is False))
            cases.append(("profile=server turns desktop.pointer off",
                          policy.scope("desktop.pointer") is False))
            cases.append(("profile=server empties desktop.open_uri",
                          policy.scope("desktop.open_uri") == frozenset()))
            cases.append(("profile=server turns desktop.default_handler off",
                          policy.scope("desktop.default_handler") is False))
            cases.append(("profile=server turns audio.out off",
                          policy.scope("audio.out") is False))
            cases.append(("profile=server raises idle_stop_s to 600",
                          policy.scope("server.idle_stop_s") == 600))
            cases.append(("profile=server leaves display at its own default",
                          policy.scope("server.display") == "1280x800@60/400"))

        policy, err = policy_from(
            "[rhizo]\nprofile = server\n\n[desktop]\nclipboard = both\n",
            tmp, "server-explicit.conf")
        cases.append(("an explicit key under server still parses", policy is not None))
        if policy is not None:
            cases.append(("an explicit desktop.clipboard=both under server still wins",
                          policy.scope("desktop.clipboard") == "both"))
            cases.append(("an unrelated swapped default still applies beside the explicit key",
                          policy.scope("audio.out") is False))

        policy, err = policy_from("[server]\nscreen_off_s = 30\n", tmp, "desktop-explicit.conf")
        cases.append(("desktop profile with an unrelated explicit key parses",
                      policy is not None))
        if policy is not None:
            cases.append(("desktop profile's idle_stop_s stays 0",
                          policy.scope("server.idle_stop_s") == 0))
            cases.append(("desktop profile's own explicit screen_off_s wins",
                          policy.scope("server.screen_off_s") == 30))
            cases.append(("desktop profile's clipboard stays the desktop default",
                          policy.scope("desktop.clipboard") == "both"))

        denied = capabilities.policy_or_deny(
            os.path.join(tmp, "does-not-exist-and-parser-cannot-open-a-dir") + "/x")
        cases.append(("a policy that cannot be read denies down to desktop",
                      denied.scope("rhizo.profile") == "desktop"))
        cases.append(("a policy that cannot be read denies adb_reach down to host",
                      denied.scope("server.adb_reach") == "host"))

        empty_dir = os.path.join(tmp, "no-keys-here")
        blank = os.path.join(tmp, "blank-key-file")
        with open(blank, "w") as handle:
            handle.write("\n\n")
        sshkey = os.path.join(tmp, "ssh-key-file")
        with open(sshkey, "w") as handle:
            handle.write("ssh-rsa AAAAfake operator@host\n")
        comment = os.path.join(tmp, "comment-only-key-file")
        with open(comment, "w") as handle:
            handle.write("# the operator's key goes here\n")
        real = os.path.join(tmp, "real-key-file")
        with open(real, "w") as handle:
            handle.write("QAAA" + "B" * 512 + "= operator@host\n")
        cases.append(("has_adb_key is false with no key file at all",
                      not capabilities.has_adb_key([os.path.join(empty_dir, "adb_keys")])))
        cases.append(("has_adb_key is false with only a blank key file",
                      not capabilities.has_adb_key([blank])))
        cases.append(("has_adb_key is false for an ssh key",
                      not capabilities.has_adb_key([sshkey])))
        cases.append(("has_adb_key is false for a comment line alone",
                      not capabilities.has_adb_key([comment])))
        short = os.path.join(tmp, "short-key-file")
        with open(short, "w") as handle:
            handle.write("QAAABBBB= operator@host\n")
        cases.append(("has_adb_key is false for a QAAA blob too short to be a key",
                      not capabilities.has_adb_key([short])))
        cases.append(("has_adb_key is true once a real adb key line exists",
                      capabilities.has_adb_key([blank, real])))

    cases += mac_cases()
    cases += adb_keys_cases()
    cil = open(os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")).read()
    cases.append(("rhizo_host may sigkill adbd",
                  re.search(r"^\(allow rhizo_host adbd \(process \([^)]*\bsigkill\b", cil, re.M) is not None))

    with open(os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")) as handle:
        cases += gnss_cases(handle.read())

    cases += manifest_cases()

    return cases


GNSS_BINARY = "the gnss binary is staged on every profile"
GNSS_LOCATION = "the location feature is armed only under profile=server"
GNSS_RC = "the gnss service rc is armed only under profile=server"
GNSS_FEATURES = "that feature file declares location and location.gps"
GNSS_AFTER = "    audio_core_bin = "


def gnss_cases(hals):
    """return the gnss staging cases for the text of sandbox/hals.py"""
    start, end = hals.find("gnss_bin = "), hals.find(GNSS_AFTER)
    gnss_block = hals[start:end] if 0 <= start < end else ""
    cases = []
    cases.append((GNSS_BINARY,
                  "stage_bulk(gnss_bin" in gnss_block
                  and gnss_block.index("stage_bulk(gnss_bin")
                      < gnss_block.index("if not _gnss_server")))
    cases.append((GNSS_LOCATION,
                  "rhizo-location.xml" in gnss_block
                  and gnss_block.index("if not _gnss_server")
                      < gnss_block.index("rhizo-location.xml")))
    cases.append((GNSS_RC,
                  "rhizo-gnss.rc" in gnss_block
                  and gnss_block.index("if not _gnss_server")
                      < gnss_block.index("rhizo-gnss.rc")))
    cases.append((GNSS_FEATURES,
                  "android.hardware.location" in gnss_block
                  and "android.hardware.location.gps" in gnss_block))
    return cases


def manifest_cases():
    """return the vendor manifest gnss HAL cases"""
    import xml.etree.ElementTree as ET
    from sandbox import hals
    cases = []
    prev = os.environ.get(capabilities.PATH_ENV)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            for profile in ("desktop", "server"):
                conf = os.path.join(tmp, profile + ".conf")
                with open(conf, "w") as handle:
                    handle.write("[rhizo]\nprofile = %s\n" % profile)
                os.environ[capabilities.PATH_ENV] = conf
                text = hals.vendor_manifest_xml()
                declared = {h.findtext("name") for h in ET.fromstring(text).iter("hal")
                            if h.get("format") == "aidl"}
                started = {"android.hardware.gnss"} if profile == "server" else set()
                cases.append(("%s manifest declares gnss exactly when the gnss HAL starts" % profile,
                              ("android.hardware.gnss" in declared) == bool(started)))
                cases.append(("%s manifest keeps its sepolicy version" % profile,
                              "<sepolicy>" in text and "<version>202504</version>" in text))
    finally:
        if prev is None:
            os.environ.pop(capabilities.PATH_ENV, None)
        else:
            os.environ[capabilities.PATH_ENV] = prev
    with open(os.path.join(REPO, "src", "androidd", "guest", "vendor", "manifest.xml")) as handle:
        cases.append(("the staged manifest hardcodes no gnss HAL", "android.hardware.gnss" not in handle.read()))
    return cases


MAC_BIND = "GUEST_MAC=NET_GUEST_MAC"
MAC_SET = '"ip","link","add",TMP_GUEST_IF,"address",GUEST_MAC,'
MAC_DERIVE = 'NET_GUEST_MAC = "02:52:48:5a:00:%02x" % (SANDBOX_ID + 1)'
DERIVED = "the veth MAC is derived per instance, never a literal"
DISTINCT = "no two instances present the same MAC"
EXPLICIT = "the sandbox veth is created with an explicit MAC"
WELL_FORMED = "every id in range derives a well-formed MAC"
LOCAL_UNICAST = "that MAC is locally administered and unicast"

MAC_MUTATIONS = (
    ("the launcher spells a MAC literal again",
     (MAC_BIND, 'GUEST_MAC="02:52:48:5a:00:01"'), None,
     (DERIVED, DISTINCT), (EXPLICIT, LOCAL_UNICAST)),
    ("the derivation stopped varying with the sandbox id",
     None, (MAC_DERIVE, 'NET_GUEST_MAC = "02:52:48:5a:00:01"'),
     (DISTINCT,), (DERIVED, EXPLICIT, LOCAL_UNICAST, WELL_FORMED)),
    ("the derived MAC is globally administered",
     None, (MAC_DERIVE, 'NET_GUEST_MAC = "00:52:48:5a:00:%02x" % (SANDBOX_ID + 1)'),
     (LOCAL_UNICAST,), (DERIVED, EXPLICIT, WELL_FORMED, DISTINCT)),
    ("the derived MAC is multicast",
     None, (MAC_DERIVE, 'NET_GUEST_MAC = "03:52:48:5a:00:%02x" % (SANDBOX_ID + 1)'),
     (LOCAL_UNICAST,), (DERIVED, EXPLICIT, WELL_FORMED, DISTINCT)),
    ("the last octet overflows at the top of the id range",
     None, (MAC_DERIVE, 'NET_GUEST_MAC = "02:52:48:5a:00:%02x" % (SANDBOX_ID + 200)'),
     (WELL_FORMED,), (DERIVED, EXPLICIT, DISTINCT)),
    ("the veth is created with no address at all",
     (MAC_SET, '"ip","link","add",TMP_GUEST_IF,'), None,
     (EXPLICIT,), (DERIVED, LOCAL_UNICAST, WELL_FORMED, DISTINCT)),
)


def _fixture(tmp, launcher_src, env_src):
    """write launcher and env sources into a fixture directory"""
    for name, src in (("boot.py", launcher_src), ("sandbox/core.py", env_src)):
        os.makedirs(os.path.dirname(os.path.join(tmp, name)), exist_ok=True)
        with open(os.path.join(tmp, name), "w") as handle:
            handle.write(src)
    return tmp


def _failed_labels(vm_dir):
    """return the labels of the MAC cases that fail in a vm directory"""
    return {label for label, ok in mac_cases(vm_dir) if not ok}


def mac_selftest():
    """run mac_cases() on mutated copies"""
    bad = []
    launcher_src = open(os.path.join(REPO, "src", "androidd", "boot.py")).read()
    env_src = open(os.path.join(REPO, "src", "androidd", "sandbox", "core.py")).read()
    for needle, where, src in ((MAC_BIND, "launcher3.py", launcher_src),
                               (MAC_SET, "launcher3.py", launcher_src),
                               (MAC_DERIVE, "sandbox/core.py", env_src)):
        if src.count(needle) != 1:
            bad.append("selftest FAIL: mutation target %r occurs %d times in %s, "
                       "not once"
                       % (needle, src.count(needle), where))
    if bad:
        return bad

    with tempfile.TemporaryDirectory() as tmp:
        found = _failed_labels(_fixture(tmp, launcher_src, env_src))
        if found:
            bad.append("selftest FAIL: an unmutated copy of the real pair must "
                       "pass every MAC case, but these failed: %s" % sorted(found))

    for name, launcher_edit, env_edit, must_fail, must_pass in MAC_MUTATIONS:
        mutated_launcher = launcher_src.replace(*launcher_edit) if launcher_edit else launcher_src
        mutated_env = env_src.replace(*env_edit) if env_edit else env_src
        with tempfile.TemporaryDirectory() as tmp:
            found = _failed_labels(_fixture(tmp, mutated_launcher, mutated_env))
        for label in must_fail:
            if label not in found:
                bad.append("selftest FAIL: %s is not caught by %r (failed: %s)"
                           % (name, label, sorted(found)))
        for label in must_pass:
            if label in found:
                bad.append("selftest FAIL: %s also broke %r, which must stay "
                           "passing" % (name, label))
    return bad


ADB_MUTATIONS = (
    ("the staged keys go back into the framework-owned /data/misc/adb",
     ('    with open(tmp, "w") as out:\n', '    out_path = os.path.join(os.path.dirname(out_path), "data/misc/adb/adb_keys")\n'
      '    os.makedirs(os.path.dirname(out_path), exist_ok=True)\n    tmp = out_path\n    with open(tmp, "w") as out:\n'),
     ADB_SYSTEM),
    ("an empty key set leaves the last /adb_keys in place",
     ('        os.unlink(out_path)\n', '        pass\n'), ADB_NONE),
)


def adb_selftest():
    """run the adb key checks on mutated copies"""
    bad = []
    src = open(os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")).read()
    for name, (old, new), label in ADB_MUTATIONS:
        if src.count(old) != 1:
            bad.append("selftest FAIL: adb mutation target for %r occurs %d times in sandbox/hals.py"
                       % (name, src.count(old)))
            continue
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "hals.py")
            with open(path, "w") as handle:
                handle.write(src.replace(old, new, 1))
            failed = [l for l, ok in adb_keys_cases(path) if not ok]
        if not any(l.startswith(label) for l in failed):
            bad.append("selftest FAIL: %s is not caught by %r (failed: %s)" % (name, label, failed))
    ok, _, _ = adbkeystore_authorized([RIG], [DIALOG_OLD], {DIALOG_OLD: 0}, 8 * DAY_MS)
    if DIALOG_OLD in ok or RIG not in ok:
        bad.append("selftest FAIL: the AdbKeyStore model keeps a week-old user key or drops a system key")
    ok, _, _ = adbkeystore_authorized([], [DIALOG_NEW], {}, 8 * DAY_MS)
    if DIALOG_NEW not in ok:
        bad.append("selftest FAIL: the AdbKeyStore model drops a user key it has no record of")
    return bad


GNSS_MUTATIONS = (
    ("the gnss service rc written after the gnss block, on every profile",
     (('            open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gnss.rc","w").write(',
       '            open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gnss-off.rc","w").write('),),
     '    open(f"{RUN_ROOT}/vendor/etc/init/rhizo-gnss.rc","w").write("")\n',
     GNSS_RC, (GNSS_BINARY, GNSS_LOCATION, GNSS_FEATURES)),
    ("the location feature written after the gnss block, on every profile",
     (('            open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-location.xml", "w").write(',
       '            open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-location-off.xml", "w").write('),
      ('            kmsg("rhizo-location.xml staged with the gnss HAL")',
       '            kmsg("rhizo-location-off.xml staged with the gnss HAL")')),
     '    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-location.xml", "w").write("")\n',
     GNSS_LOCATION, (GNSS_BINARY, GNSS_RC, GNSS_FEATURES)),
)


def gnss_selftest():
    """run gnss_cases() on the real sandbox/hals.py and on mutated copies"""
    bad = []
    src = open(os.path.join(REPO, "src", "androidd", "sandbox", "hals.py")).read()
    failed = [l for l, ok in gnss_cases(src) if not ok]
    if failed:
        bad.append("selftest FAIL: the real sandbox/hals.py must pass every gnss case, but these failed: %s" % failed)
    for name, edits, appended, must_fail, must_pass in GNSS_MUTATIONS:
        if any(src.count(old) != 1 for old, _ in edits) or src.count(GNSS_AFTER) != 1:
            bad.append("selftest FAIL: gnss mutation target for %r does not occur exactly once in sandbox/hals.py"
                       % name)
            continue
        mutated = src
        for old, new in edits:
            mutated = mutated.replace(old, new, 1)
        cut = mutated.index("\n", mutated.index(GNSS_AFTER)) + 1
        mutated = mutated[:cut] + appended + mutated[cut:]
        failed = [l for l, ok in gnss_cases(mutated) if not ok]
        if must_fail not in failed:
            bad.append("selftest FAIL: %s is not caught by %r (failed: %s)" % (name, must_fail, failed))
        for label in must_pass:
            if label in failed:
                bad.append("selftest FAIL: %s also broke %r, which must stay passing" % (name, label))
    return bad


def selftest():
    """run every selftest and the check"""
    bad = mac_selftest() + adb_selftest() + gnss_selftest()
    for line in bad:
        print(line)
    if bad:
        return 1
    print("check-server-profile selftest: a MAC literal in the launcher, a "
          "derivation that stopped varying with the id, a globally administered "
          "MAC, a multicast one, an octet that overflows at id 99 and a veth "
          "created with no address are each caught by name, as are registered adb "
          "keys staged into the framework-owned /data/misc/adb, an empty key set "
          "leaving an old /adb_keys, and a gnss rc or location feature written past "
          "the gnss block; an unmutated copy passes every case")
    return main()


def main():
    """run the server profile cases and print the result"""
    cases = check()
    bad = 0
    for label, ok in cases:
        print("%s %s" % ("OK" if ok else "FAIL", label))
        if not ok:
            bad += 1
    if bad:
        print("FAIL: %d of %d server-profile checks failed" % (bad, len(cases)))
        return 1
    print("server profile: %d checks, the config surface parses strictly and "
          "profile=server swaps defaults with explicit keys still winning" % len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else main())
