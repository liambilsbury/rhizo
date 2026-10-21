#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd")

FIELDS = ["SANDBOX_ID", "RUN_ROOT", "SELINUXNS_RECORDS_DIR", "CGROUP_ROOT", "INIT_PID_FILE", "G_PID_FILE",
          "CGROUP_ROOT_FILE", "VETH_HOST_IF", "NET_OCTET3", "NET_SUBNET",
          "NET_HOST_ADDR", "NET_POOL_START", "NET_POOL_END", "RHIZO_DATA_IMG",
          "NET_GUEST_MAC"]

EXPECT_0 = {
    "SANDBOX_ID": 0, "RUN_ROOT": "/run/rhizo", "SELINUXNS_RECORDS_DIR": "/run/rhizo-selinuxns",
    "CGROUP_ROOT": "/sys/fs/cgroup/rhizo",
    "INIT_PID_FILE": "/root/.rhizo_init_pid", "G_PID_FILE": "/root/.rhizo_g_pid",
    "CGROUP_ROOT_FILE": "/root/.rhizo_cgroup_root", "VETH_HOST_IF": "vethrhz0",
    "NET_OCTET3": 100, "NET_SUBNET": "192.168.100.0/24",
    "NET_HOST_ADDR": "192.168.100.1/24", "NET_POOL_START": "192.168.100.50",
    "NET_POOL_END": "192.168.100.100", "RHIZO_DATA_IMG": "/var/lib/rhizo/data.img",
    "NET_GUEST_MAC": "02:52:48:5a:00:01",
}

EXPECT_3 = {
    "SANDBOX_ID": 3, "RUN_ROOT": "/run/rhizo-3", "SELINUXNS_RECORDS_DIR": "/run/rhizo-selinuxns-3",
    "CGROUP_ROOT": "/sys/fs/cgroup/rhizo-3",
    "INIT_PID_FILE": "/root/.rhizo_init_pid-3", "G_PID_FILE": "/root/.rhizo_g_pid",
    "CGROUP_ROOT_FILE": "/root/.rhizo_cgroup_root-3", "VETH_HOST_IF": "vethrhz3",
    "NET_OCTET3": 103, "NET_SUBNET": "192.168.103.0/24",
    "NET_HOST_ADDR": "192.168.103.1/24", "NET_POOL_START": "192.168.103.50",
    "NET_POOL_END": "192.168.103.100",
    "RHIZO_DATA_IMG": "/var/lib/rhizo/instances/3/data.img",
    "NET_GUEST_MAC": "02:52:48:5a:00:04",
}

HOST_GLOBAL_FIELDS = {"G_PID_FILE"}

_MARK = "SANDBOX_ID_JSON:"


def _probe_src(vm_dir):
    """return a program that prints the id-derived fields"""
    return (
        "import sys, json; sys.path.insert(0, %r); from sandbox import core as e; "
        "print(%r + json.dumps({k: getattr(e, k) for k in %r}))" % (vm_dir, _MARK, FIELDS)
    )


PATHS_FOR_MARK = "PATHS_FOR_JSON:"
_PATHS_FOR_FIELDS = {
    "run_root": "RUN_ROOT", "records_dir": "SELINUXNS_RECORDS_DIR", "cgroup_root": "CGROUP_ROOT",
    "init_pid_file": "INIT_PID_FILE", "cgroup_root_file": "CGROUP_ROOT_FILE",
    "veth_host_if": "VETH_HOST_IF", "net_subnet": "NET_SUBNET",
    "net_host_addr": "NET_HOST_ADDR",
}


def _paths_for_probe_src(vm_dir):
    """return a program that prints the paths derived for two ids"""
    return (
        "import sys, json; sys.path.insert(0, %r); from sandbox import core as e; "
        "print(%r + json.dumps({i: e.paths_for(i)._asdict() for i in (0, 3)}))"
        % (vm_dir, PATHS_FOR_MARK)
    )


def _parse(stdout, mark=_MARK):
    """parse the marked line of probe stdout"""
    for line in stdout.splitlines():
        if line.startswith(mark):
            return json.loads(line[len(mark):])
    raise ValueError("no %s line in probe stdout: %r" % (mark, stdout[:400]))


def _load(sandbox_id, vm_dir=LAUNCHER):
    """run the core probe in a subprocess"""
    env = dict(os.environ)
    if sandbox_id is None:
        env.pop("RHIZO_SANDBOX_ID", None)
    else:
        env["RHIZO_SANDBOX_ID"] = str(sandbox_id)
    return subprocess.run([sys.executable, "-c", _probe_src(vm_dir)], env=env,
                           capture_output=True, text=True)


def check(vm_dir=LAUNCHER):
    """return the problems in the values derived for each sandbox id"""
    bad = []

    r0 = _load(None, vm_dir)
    if r0.returncode != 0:
        return ["RHIZO_SANDBOX_ID unset: import failed -- %s" % r0.stderr.strip()[:400]]
    vals0 = _parse(r0.stdout)
    for k, want in EXPECT_0.items():
        if vals0.get(k) != want:
            bad.append("id 0 (unset): %s = %r, want %r" % (k, vals0.get(k), want))

    r3 = _load(3, vm_dir)
    if r3.returncode != 0:
        return bad + ["RHIZO_SANDBOX_ID=3: import failed -- %s" % r3.stderr.strip()[:400]]
    vals3 = _parse(r3.stdout)
    for k, want in EXPECT_3.items():
        if vals3.get(k) != want:
            bad.append("id 3: %s = %r, want %r" % (k, vals3.get(k), want))
    for k in FIELDS:
        if k in HOST_GLOBAL_FIELDS:
            continue
        if k in vals0 and k in vals3 and vals0[k] == vals3[k]:
            bad.append("%s is IDENTICAL at id 0 and id 3 (%r)" % (k, vals0[k]))
    for k in HOST_GLOBAL_FIELDS:
        if k in vals0 and k in vals3 and vals0[k] != vals3[k]:
            bad.append("%s DIFFERS between id 0 (%r) and id 3 (%r)" % (k, vals0[k], vals3[k]))

    r100 = _load(100, vm_dir)
    if r100.returncode == 0:
        bad.append("RHIZO_SANDBOX_ID=100 imported successfully")
    elif "refused" not in (r100.stderr or ""):
        bad.append("RHIZO_SANDBOX_ID=100 failed for the wrong reason -- %s"
                   % r100.stderr.strip()[:300])

    r_bad = _load("nope", vm_dir)
    if r_bad.returncode == 0:
        bad.append("RHIZO_SANDBOX_ID=nope imported successfully")

    r_neg = _load(-1, vm_dir)
    if r_neg.returncode == 0:
        bad.append("RHIZO_SANDBOX_ID=-1 imported successfully")
    elif "refused" not in (r_neg.stderr or ""):
        bad.append("RHIZO_SANDBOX_ID=-1 failed for the wrong reason -- %s"
                   % r_neg.stderr.strip()[:300])

    bad += check_paths_for(vals0, vals3, vm_dir)

    return bad


def check_paths_for(vals0, vals3, vm_dir=LAUNCHER):
    """compare paths_for() with the module constants"""
    bad = []
    env = dict(os.environ)
    env.pop("RHIZO_SANDBOX_ID", None)
    r = subprocess.run([sys.executable, "-c", _paths_for_probe_src(vm_dir)], env=env,
                        capture_output=True, text=True)
    if r.returncode != 0:
        return ["paths_for probe: import failed -- %s" % r.stderr.strip()[:400]]
    by_id = _parse(r.stdout, PATHS_FOR_MARK)
    for probe_id, expect in ((0, vals0), (3, vals3)):
        got = by_id[str(probe_id)]
        for pf_field, const in _PATHS_FOR_FIELDS.items():
            if const not in expect:
                continue
            if got.get(pf_field) != expect[const]:
                bad.append("paths_for(%d).%s = %r, want %r (%s's own value)"
                           % (probe_id, pf_field, got.get(pf_field), expect[const], const))
    return bad


def _mutation_selftest():
    """run check() on a mutated sandbox/core.py copy"""
    real_src = open(os.path.join(LAUNCHER, "sandbox/core.py")).read()

    with tempfile.TemporaryDirectory() as good_dir:
        os.makedirs(os.path.join(good_dir, "sandbox"))
        open(os.path.join(good_dir, "sandbox/core.py"), "w").write(real_src)
        found = check(good_dir)
        assert found == [], "an unmutated copy must derive everything the real tree does: %s" % found

    needle = 'return base if sandbox_id == 0 else f"{base}{sep}{sandbox_id}"'
    assert real_src.count(needle) == 1, "mutation target not found (or not unique) in sandbox/core.py"
    mutated_src = real_src.replace(
        needle, 'return base if sandbox_id == -1 else f"{base}{sep}{sandbox_id}"')

    with tempfile.TemporaryDirectory() as bad_dir:
        os.makedirs(os.path.join(bad_dir, "sandbox"))
        open(os.path.join(bad_dir, "sandbox/core.py"), "w").write(mutated_src)
        found = check(bad_dir)
        assert any("RUN_ROOT" in f and "/run/rhizo-0" in f for f in found), \
            "a broken id-0 special case in _instanced_for must be caught, by name, at RUN_ROOT: %s" % found

    print("check-sandbox-id selftest: a broken _instanced_for id-0 special case "
          "is caught by name (RUN_ROOT), an unmutated copy passes")


def selftest():
    """run the check and the mutation selftest"""
    found = check()
    assert found == [], "the real tree must derive every expected value: %s" % found
    print("check-sandbox-id selftest: id 0 matches every existing literal, "
          "id 3 derives a full distinct set, id 100, id -1 and a non-numeric id are all refused")
    _mutation_selftest()


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = check()
    for f in findings:
        print("check-sandbox-id: " + f)
    sys.exit(1 if findings else 0)
