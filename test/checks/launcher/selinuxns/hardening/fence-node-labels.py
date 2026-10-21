#!/usr/bin/env python3
import contextlib
import io
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "src", "androidd"))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-fence-node-labels")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import rootfs  # noqa: E402
    from sandbox import selinux_policy  # noqa: E402
    from sandbox import selinux_ns  # noqa: E402
from policy_lab_cache import release_cil_dir  # noqa: E402

LAB = os.path.join(ROOT, "test", "checks", "lib", "avc-lab.sh")
DOMAIN = selinux_ns.LABEL_SERVICE_CONTEXT.decode().split(":")[2]
RELEASES = (("a15", "gsi_a15"), ("a16", "system"), ("a17", "gsi_a17"))
DIR_TYPES = {"/dev": "device", "/dev/input": "input_device"}
KIND_DIRS = {"evdev": "/dev/input", "hidraw": "/dev"}


def statements(text):
    """return text's top-level CIL statements"""
    stack = [[]]
    for token in selinux_policy._CIL_TOKEN.findall(text):
        if token == "(":
            stack.append([])
        elif token == ")":
            done = stack.pop()
            stack[-1].append(done)
        elif token[0] != ";":
            stack[-1].append(token)
    return stack[0]


def holds(expr, t1, t2, t3):
    """evaluate a validatetrans expression"""
    op = expr[0]
    if op == "and":
        return holds(expr[1], t1, t2, t3) and holds(expr[2], t1, t2, t3)
    if op == "or":
        return holds(expr[1], t1, t2, t3) or holds(expr[2], t1, t2, t3)
    if op == "not":
        return not holds(expr[1], t1, t2, t3)
    names = {"t1": t1, "t2": t2, "t3": t3}
    value = names[expr[1]]
    other = names.get(expr[2], expr[2]) if isinstance(expr[2], str) else expr[2]
    same = value in other if isinstance(other, list) else value == other
    return same if op == "eq" else not same


def node_findings(release, trans, grants, pins, ueventd=None):
    """compare each fence node kind's born and wanted labels"""
    out = []
    for kind, (_uid, _gid, label, relabel) in sorted(rootfs._NODE_KIND.items()):
        dir_type = DIR_TYPES[KIND_DIRS[kind]]
        born = trans.get(dir_type, dir_type)
        want = label.split(":")[2]
        if not relabel:
            if born != want:
                out.append(f"{release}: a {kind} node is born {born}, not {want}, and nothing relabels it")
            if "getattr" not in grants.get(want, set()):
                out.append(f"{release}: the label service cannot read a {kind} node's {want} label")
            continue
        missing = {"getattr", "relabelfrom"} - grants.get(born, set())
        if missing:
            out.append(f"{release}: a {kind} node is born {born}, and the label service lacks {sorted(missing)} on it")
        if {"getattr", "relabelto"} - grants.get(want, set()):
            out.append(f"{release}: the label service cannot relabel a {kind} node to {want}")
        if not all(holds(p, born, want, DOMAIN) for p in pins):
            out.append(f"{release}: a validatetrans forbids the service's {born} to {want} relabel")
        if all(holds(p, born, "input_device", DOMAIN) for p in pins):
            out.append(f"{release}: no validatetrans keeps the service's relabel of a {born} node off any type "
                       f"but {want}")
        raced = {"setattr", "relabelfrom"} & (ueventd or {}).get(born, set())
        if raced:
            out.append(f"{release}: ueventd holds {sorted(raced)} on a {kind} node born {born}")
    return out


def compiled_inputs(cil_dir, rendered):
    """compile the render and return its transitions and grants"""
    with tempfile.TemporaryDirectory() as tmp:
        render = os.path.join(tmp, "rhizo.cil")
        with open(render, "w") as f:
            f.write(rendered)
        out_dir = os.path.join(tmp, "out")
        r = subprocess.run([LAB, "build", "--keep-deny", "--render", render, "--out", out_dir], capture_output=True,
                           text=True, timeout=900, env={**os.environ, "RHIZO_POLICY_LAB_CIL_DIR": cil_dir})
        if r.returncode != 0:
            raise RuntimeError("the lab policy did not build: " + r.stderr.strip()[-300:])
        pol = os.path.join(out_dir, "policy.lab")
        trans = {}
        for t in DIR_TYPES.values():
            text = subprocess.run(["sesearch", "-T", "-s", "kernel", "-t", t, "-c", "chr_file", pol],
                                  capture_output=True, text=True, timeout=300, check=True).stdout
            plain = [l.split()[-1].rstrip(";") for l in text.splitlines() if len(l.split()) == 4]
            if plain:
                trans[t] = plain[0]
        text = subprocess.run(["sesearch", "-A", "-s", DOMAIN, "-c", "chr_file", pol], capture_output=True,
                              text=True, timeout=300, check=True).stdout
        ueventd = {}
        for t in set(trans.values()) | set(DIR_TYPES.values()):
            found = subprocess.run(["sesearch", "-A", "-s", "ueventd", "-t", t, "-c", "chr_file", pol],
                                   capture_output=True, text=True, timeout=300, check=True).stdout
            ueventd[t] = {p for line in found.splitlines() if line.startswith("allow ")
                          for p in line.replace("{", " ").replace("}", " ").replace(";", " ").split()[3:]}
    grants = {}
    for line in text.splitlines():
        words = line.replace("{", " ").replace("}", " ").replace(";", " ").split()
        if len(words) > 3 and words[0] == "allow":
            grants.setdefault(words[2].split(":")[0], set()).update(words[3:])
    return trans, grants, ueventd


def findings():
    """compile each release's namespace render and compare"""
    out, cases = [], []
    for release, image in RELEASES:
        cil_dir = release_cil_dir(ROOT, image)
        if not cil_dir or not os.path.isdir(cil_dir):
            out.append(f"{release}: no cached CILs for {image}.img; run test/checks/lib/policy-lab.sh once")
            continue
        cils = [os.path.join(cil_dir, n) for n in ("plat_sepolicy.cil", "system_ext_sepolicy.cil",
                                                   "product_sepolicy.cil")]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            rendered = selinux_policy.build(cils, namespace=True)
        pins = [s[2] for s in statements(rendered) if s and s[0] == "validatetrans" and s[1] == "chr_file"]
        cases.append((release, cil_dir, rendered, pins))
    with ThreadPoolExecutor(3) as pool:
        got = list(pool.map(lambda c: (c, compiled_inputs(c[1], c[2])), cases))
    for (release, _d, _r, pins), (trans, grants, ueventd) in got:
        out += node_findings(release, trans, grants, pins, ueventd)
    return out


def selftest():
    """judge fixture policies"""
    bad = []
    pin = statements(f"(validatetrans chr_file (or (not (eq t3 {DOMAIN})) (eq t2 hidraw_device)))")[0][2]
    old_pin = statements(f"(validatetrans chr_file (or (not (and (eq t3 {DOMAIN}) (eq t1 device))) "
                         "(eq t2 hidraw_device)))")[0][2]
    trans = {"device": "rhizo_host_device"}
    good = {"input_device": {"getattr"}, "rhizo_host_device": {"getattr", "relabelfrom"},
            "hidraw_device": {"getattr", "relabelto"}}
    old = {"input_device": {"getattr"}, "device": {"getattr", "relabelfrom"},
           "hidraw_device": {"getattr", "relabelto"}}
    cases = (("the fixed policy", trans, good, [pin], None),
             ("a hidraw node born rhizo_host_device the service cannot read", trans, old, [old_pin],
              "born rhizo_host_device, and the label service lacks"),
             ("a pin that lets the service relabel a host node anywhere", trans, good, [old_pin],
              "keeps the service's relabel of a rhizo_host_device node off"),
             ("an event node born a host type", {**trans, "input_device": "rhizo_host_device"}, good, [pin],
              "evdev node is born rhizo_host_device"))
    for name, t, g, p, want in cases:
        got = node_findings("a16", t, g, p, {"rhizo_host_device": {"getattr", "unlink"}})
        if want is None and got:
            bad.append(f"{name} was flagged: {got}")
        elif want is not None and not any(want in f for f in got):
            bad.append(f"{name} passed: {got}")
    raced = node_findings("a16", trans, good, [pin], {"rhizo_host_device": {"getattr", "setattr", "unlink"}})
    if not any("ueventd holds ['setattr'] on a hidraw node born rhizo_host_device" in f for f in raced):
        bad.append(f"ueventd's setattr on a hidraw node's born type passed: {raced}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else findings()
    for b in bad:
        print("FAIL: " + b, file=sys.stderr)
    if bad:
        return 1
    print("fence-node-labels: " + ("selftest ok" if "--selftest" in sys.argv[1:] else
                                   "every fenced node kind reaches its label on a15, a16 and a17"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
