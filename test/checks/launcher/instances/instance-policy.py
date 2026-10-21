#!/usr/bin/env python3
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

from sandbox import capabilities as caps  # noqa: E402
import boot as launcher3  # noqa: E402


def _write(path, text):
    """write text to a file"""
    with open(path, "w") as f:
        f.write(text)


def test_overlay_layers_on_top_of_base(tmp):
    """check the overlay and base keys both apply"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[instance]\ncpu_max = 100000 1000000\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None, err
    assert policy.scope("server.idle_stop_s") == 900, policy.scope("server.idle_stop_s")
    assert policy.scope("instance.cpu_max") == "100000 1000000", policy.scope("instance.cpu_max")


def test_overlay_overrides_base_on_the_same_key(tmp):
    """check the overlay overrides the base key"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[server]\nidle_stop_s = 60\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None, err
    assert policy.scope("server.idle_stop_s") == 60, policy.scope("server.idle_stop_s")


def test_overlay_overrides_a_server_profile_default(tmp):
    """check the overlay overrides a profile default"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[rhizo]\nprofile = server\n")
    _write(overlay, "[server]\nidle_stop_s = 30\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None, err
    assert policy.scope("server.idle_stop_s") == 30, policy.scope("server.idle_stop_s")
    assert policy.scope("audio.out") is False, policy.scope("audio.out")


def test_malformed_overlay_denies_never_defaults(tmp):
    """check a malformed overlay returns an error"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[instance]\ncpu_max = not-a-real-value\n")
    policy, err = caps.read_policy(base, overlay)
    assert policy is None, "a malformed overlay must refuse, not parse partially"
    assert err is not None and "cpu_max" in err, err
    denied = caps.deny_all()
    assert denied.scope("instance.cpu_max") != caps.CAPABILITIES["instance.cpu_max"]["default"], (
        "deny_all() left instance.cpu_max at its own uncapped default")


def test_malformed_overlay_key_not_a_capability(tmp):
    """check an unknown overlay key returns an error"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[server]\nnot_a_real_key = 1\n")
    policy, err = caps.read_policy(base, overlay)
    assert policy is None, "an overlay typo must refuse, not parse partially"
    assert err is not None and "not_a_real_key" in err, err


def test_overlay_refuses_a_host_wide_key(tmp):
    """check a host-wide overlay key returns an error"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[trace]\nftrace = no\n")
    _write(overlay, "[trace]\nftrace = yes\n")
    policy, err = caps.read_policy(base, overlay)
    assert policy is None, "an overlay setting a host-wide key must refuse"
    assert err is not None and "host-wide" in err, err
    _write(base, "[trace]\nftrace = yes\n")
    _write(overlay, "[instance]\ncpu_max = 50000 100000\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None and policy.allows("trace.ftrace"), err


def test_overlay_refuses_devices_dri(tmp):
    """check an instance overlay refuses devices.dri"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[devices]\ndri = on\n")
    _write(overlay, "[devices]\ndri = off\n")
    policy, err = caps.read_policy(base, overlay)
    assert policy is None, "an overlay setting devices.dri must refuse: the software policy grant loads once per host boot"
    assert err is not None and "[devices] dri is host-wide" in err, err
    _write(base, "[devices]\ndri = off\n")
    _write(overlay, "[devices]\nuinput = no\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None and not policy.allows("devices.dri") and not policy.allows("devices.uinput"), err


def test_no_overlay_is_byte_identical_to_today(tmp):
    """check read_policy with overlay_path omitted"""
    base = os.path.join(tmp, "policy.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    with_none, err1 = caps.read_policy(base, None)
    without_arg, err2 = caps.read_policy(base)
    assert err1 is None and err2 is None, (err1, err2)
    assert with_none == without_arg, "overlay_path=None must match the no-arg call exactly"


def test_missing_overlay_file_is_a_no_op(tmp):
    """check a missing overlay reads the base file"""
    base = os.path.join(tmp, "policy.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    missing_overlay = os.path.join(tmp, "does-not-exist.conf")
    policy, err = caps.read_policy(base, missing_overlay)
    assert err is None, err
    assert policy.scope("server.idle_stop_s") == 900, policy.scope("server.idle_stop_s")


def test_instance_config_path_presence(tmp):
    """check instance_config_path for present and absent files"""
    real_dir = caps.INSTANCE_CONF_DIR
    try:
        caps.INSTANCE_CONF_DIR = tmp
        assert caps.instance_config_path(5) is None
        _write(os.path.join(tmp, "5.conf"), "[server]\nidle_stop_s = 30\n")
        assert caps.instance_config_path(5) == os.path.join(tmp, "5.conf")
    finally:
        caps.INSTANCE_CONF_DIR = real_dir


def test_cgroup_cpu_max_grammar(tmp):
    """check cpu_max parsing of valid and invalid values"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "")
    for raw, want in (("100000 1000000", "100000 1000000"), ("max", "max")):
        _write(overlay, "[instance]\ncpu_max = %s\n" % raw)
        policy, err = caps.read_policy(base, overlay)
        assert err is None, err
        assert policy.scope("instance.cpu_max") == want, (raw, policy.scope("instance.cpu_max"))
    for bad in ("0 1000000", "100000 0", "-1 1000000", "not-numbers"):
        _write(overlay, "[instance]\ncpu_max = %s\n" % bad)
        policy, err = caps.read_policy(base, overlay)
        assert policy is None, "cpu_max=%r must refuse: got %r" % (bad, policy)


def test_overlay_sets_the_memory_ceiling(tmp):
    """check memory_max spellings convert to bytes"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "")
    for raw, want in (("2G", "2147483648"), ("2147483648", "2147483648"),
                      ("1800M", "1887436800"), ("max", "max")):
        _write(overlay, "[instance]\nmemory_max = %s\n" % raw)
        policy, err = caps.read_policy(base, overlay)
        assert err is None, err
        assert policy.scope("instance.memory_max") == want, (raw, policy.scope("instance.memory_max"))
    for bad in ("0", "0M", "-1", "2GB", "1.5G", "not-a-number", "2 G"):
        _write(overlay, "[instance]\nmemory_max = %s\n" % bad)
        policy, err = caps.read_policy(base, overlay)
        assert policy is None, "memory_max=%r must refuse: got %r" % (bad, policy)
        assert err is not None and "memory_max" in err, (bad, err)


def test_memory_max_unset_leaves_the_host_default(tmp):
    """check the memory_max default"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "0.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[instance]\ncpu_max = 100000 1000000\n")
    policy, err = caps.read_policy(base, overlay)
    assert err is None, err
    assert policy.scope("instance.memory_max") is None, policy.scope("instance.memory_max")
    assert caps.defaults().scope("instance.memory_max") is None


def test_malformed_memory_max_denies_never_defaults(tmp):
    """check a malformed memory_max returns an error"""
    base = os.path.join(tmp, "policy.conf")
    overlay = os.path.join(tmp, "3.conf")
    _write(base, "[server]\nidle_stop_s = 900\n")
    _write(overlay, "[instance]\nmemory_max = plenty\n")
    policy, err = caps.read_policy(base, overlay)
    assert policy is None, "a malformed memory_max must refuse, not parse partially"
    assert err is not None and "memory_max" in err, err
    denied = caps.deny_all().scope("instance.memory_max")
    assert denied != caps.CAPABILITIES["instance.memory_max"]["default"], (
        "deny_all() left instance.memory_max at its own uncapped default")
    assert denied.isdigit() and int(denied) > 0, denied


def test_ceiling_readback_reads_what_the_kernel_stores(tmp):
    """check _confirm_ceiling against cgroup file readbacks"""
    page = os.sysconf("SC_PAGE_SIZE")
    for name, wrote, got, ok in (
        ("memory.max", 2147483648, "2147483648\n", True),
        ("memory.max", 2147483648 + page - 1, "2147483648\n", True),
        ("memory.max", 2147483648, "9223372036854771712\n", False),
        ("memory.max", 2147483648, "max\n", False),
        ("memory.max", "max", "max\n", True),
        ("pids.max", 4096, "4096\n", True),
        ("pids.max", 4096, "max\n", False),
        ("cpu.max", "max", "max 100000\n", True),
        ("cpu.max", "100000 1000000", "100000 1000000\n", True),
        ("cpu.max", "100000 1000000", "max 1000000\n", False),
    ):
        path = os.path.join(tmp, name)
        _write(path, got)
        try:
            launcher3._confirm_ceiling(path, wrote)
            raised = False
        except OSError:
            raised = True
        assert raised != ok, "%s: wrote %r, file says %r, expected ok=%s" % (name, wrote, got, ok)


def test_write_cgroup_ceilings_fails_a_write_that_did_not_take(tmp):
    """check write_cgroup_ceilings returns False for a bad readback"""
    root = os.path.join(tmp, "ceiling-root")
    os.mkdir(root)
    _write(os.path.join(root, "cgroup.controllers"), "cpu memory pids\n")
    for name in ("memory.max", "pids.max", "cpu.max"):
        _write(os.path.join(root, name), "")
    logged = []
    assert launcher3.write_cgroup_ceilings(root, 2147483648, 4096,
                                           cpu_max="100000 1000000", log=logged.append), logged
    assert open(os.path.join(root, "memory.max")).read() == "2147483648"
    os.unlink(os.path.join(root, "memory.max"))
    os.symlink("/dev/null", os.path.join(root, "memory.max"))
    logged = []
    assert not launcher3.write_cgroup_ceilings(root, 2147483648, 4096,
                                               cpu_max="100000 1000000", log=logged.append)
    assert any("memory.max" in line and "reads back" in line for line in logged), logged


def test_policy_or_deny_uses_instance_config_path(tmp):
    """check policy_or_deny reads the instance overlay"""
    real_dir, real_default = caps.INSTANCE_CONF_DIR, caps.DEFAULT_PATH
    had_env = caps.PATH_ENV in os.environ
    saved_env = os.environ.pop(caps.PATH_ENV, None)
    try:
        caps.INSTANCE_CONF_DIR = tmp
        caps.DEFAULT_PATH = os.path.join(tmp, "policy.conf")
        _write(caps.DEFAULT_PATH, "[server]\nidle_stop_s = 900\n")
        _write(os.path.join(tmp, "7.conf"), "[server]\nidle_stop_s = 5\n")
        with_overlay = caps.policy_or_deny(instance_id=7)
        assert with_overlay.scope("server.idle_stop_s") == 5, with_overlay.scope("server.idle_stop_s")
        no_overlay = caps.policy_or_deny(instance_id=8)
        assert no_overlay.scope("server.idle_stop_s") == 900, no_overlay.scope("server.idle_stop_s")
        no_id = caps.policy_or_deny()
        assert no_id.scope("server.idle_stop_s") == 900, no_id.scope("server.idle_stop_s")
    finally:
        caps.INSTANCE_CONF_DIR, caps.DEFAULT_PATH = real_dir, real_default
        if had_env:
            os.environ[caps.PATH_ENV] = saved_env


def selftest():
    """run every policy test and print the count"""
    n = 0
    for fn in (
        test_overlay_layers_on_top_of_base,
        test_overlay_overrides_base_on_the_same_key,
        test_overlay_overrides_a_server_profile_default,
        test_malformed_overlay_denies_never_defaults,
        test_malformed_overlay_key_not_a_capability,
        test_overlay_refuses_a_host_wide_key,
        test_overlay_refuses_devices_dri,
        test_no_overlay_is_byte_identical_to_today,
        test_missing_overlay_file_is_a_no_op,
        test_instance_config_path_presence,
        test_cgroup_cpu_max_grammar,
        test_overlay_sets_the_memory_ceiling,
        test_memory_max_unset_leaves_the_host_default,
        test_malformed_memory_max_denies_never_defaults,
        test_ceiling_readback_reads_what_the_kernel_stores,
        test_write_cgroup_ceilings_fails_a_write_that_did_not_take,
        test_policy_or_deny_uses_instance_config_path,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            fn(tmp)
        n += 1
    print("check-instance-policy selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    print("check-instance-policy: --selftest is the only mode")
    sys.exit(2)
