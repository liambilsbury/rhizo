#!/usr/bin/env python3
import ast
import glob
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("RHIZO_CHECK_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(ROOT, "src", "androidd")
SHARE = os.path.join(ROOT, "var", "share")
STAGED = os.path.join(LAUNCHER, "guest")
TOOLS = os.path.join(ROOT, "tools", "build")

SETENV = re.compile(r"^\s*setenv\s+(RHIZO_[A-Z0-9_]+)", re.M)
EXPORT = re.compile(r"^\s*export\s+(RHIZO_[A-Z0-9_]+)", re.M)
SERVICE = re.compile(r"^\s*service\s+\S+\s+(\S+)", re.M)
MISSING_TEMPLATE = "@@RHIZO_MISSING_TEMPLATE:"


def launcher_modules():
    """return the launcher python module paths"""
    return sorted(glob.glob(os.path.join(LAUNCHER, "boot.py"))
                  + glob.glob(os.path.join(LAUNCHER, "sandbox", "*.py")))


def _rc_path_label(node):
    """return the .rc path in an AST node"""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value if node.value.endswith(".rc") else None
    if isinstance(node, ast.JoinedStr) and node.values:
        last = node.values[-1]
        if (isinstance(last, ast.Constant) and isinstance(last.value, str)
                and last.value.endswith(".rc")):
            return "".join(v.value if isinstance(v, ast.Constant) else "{...}"
                           for v in node.values)
    return None


def rc_writes(py_path):
    """yield each .rc write call in a module"""
    with open(py_path) as f:
        tree = ast.parse(f.read(), py_path)
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "write"):
            continue
        opener = node.func.value
        if not (isinstance(opener, ast.Call) and isinstance(opener.func, ast.Name)
                and opener.func.id == "open" and opener.args):
            continue
        rc_path = _rc_path_label(opener.args[0])
        if rc_path is None:
            continue
        yield rc_path, node


def local_strings(py_path):
    """map each local name to its string constants"""
    with open(py_path) as f:
        tree = ast.parse(f.read(), py_path)
    seen = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if not isinstance(target, ast.Name):
                continue
            for sub in ast.walk(node.value):
                if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                    seen.setdefault(target.id, []).append(sub.value)
    return seen


def rendered_text(node, locals_):
    """return the text of a write call"""
    parts = []
    for sub in ast.walk(node):
        if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
            parts.append(sub.value)
        if isinstance(sub, ast.Name):
            parts.extend(locals_.get(sub.id, []))
        if (isinstance(sub, ast.Call) and isinstance(sub.func, ast.Attribute)
                and sub.func.attr == "read" and sub.args
                and isinstance(sub.args[0], ast.Constant)
                and isinstance(sub.args[0].value, str)):
            name = sub.args[0].value
            path = os.path.join(STAGED, name)
            try:
                with open(path) as f:
                    parts.append(f.read())
            except OSError:
                parts.append(f"{MISSING_TEMPLATE}{name}@@")
    return "\n".join(parts)


def built_names():
    """return the hal.sh output names"""
    names = set()
    for wrapper in sorted(glob.glob(os.path.join(TOOLS, "**", "*.sh"), recursive=True)):
        with open(wrapper, errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#"):
                    continue
                m = re.search(r"(?:^|/)hal\.sh\s+(\S+)", line)
                if m and not m.group(1).startswith("-") and "$" not in m.group(1):
                    names.add(m.group(1))
    return names


def share_index(names):
    """map file names to their var/share paths"""
    found = {}
    for dirpath, _dirnames, filenames in os.walk(SHARE):
        for name in filenames:
            if name in names:
                found.setdefault(name, []).append(os.path.join(dirpath, name))
    return found


_BYTES = {}


def elf_bytes(path):
    """return the bytes of an ELF file"""
    if path not in _BYTES:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            data = b""
        _BYTES[path] = data if data[:4] == b"\x7fELF" else None
    return _BYTES[path]


def carries(path, knob):
    """return whether the binary contains the knob's name"""
    data = elf_bytes(path)
    return data is not None and knob.encode() in data


def check(env_only=False):
    """check each launcher knob appears in a binary"""
    fails = []
    names = built_names()
    if not names:
        print(f"no hal.sh output name found under {TOOLS}", file=sys.stderr)
        return 1
    index = share_index(names)
    ours = [p for paths in index.values() for p in paths if elf_bytes(p) is not None]
    if not ours:
        print(f"no staged ELF under {SHARE} matches any tools/build/ wrapper output name",
              file=sys.stderr)
        return 1

    examined = 0
    matched = []
    for module in launcher_modules():
        locals_ = local_strings(module)
        for rc, node in rc_writes(module):
            text = rendered_text(node, locals_)
            setenvs = sorted(set(SETENV.findall(text)))
            exports = sorted(set(EXPORT.findall(text)))
            if not setenvs and not exports:
                continue
            where = f"{os.path.basename(module)} -> {rc}"
            if MISSING_TEMPLATE in text:
                missing = re.findall(re.escape(MISSING_TEMPLATE) + r"([^@]+)@@", text)
                fails.append(f"{where}: renders {', '.join(missing)} from "
                             f"{STAGED}, which cannot be read")
                continue
            execs = [os.path.basename(p) for p in SERVICE.findall(text)]

            for knob in setenvs:
                examined += 1
                if knob in os.environ:
                    matched.append(knob)
                elif env_only:
                    continue
                if not execs:
                    fails.append(f"{where}: sets {knob} but defines no service")
                    continue
                for exe in execs:
                    paths = [p for p in index.get(exe, []) if elf_bytes(p) is not None]
                    if not paths:
                        fails.append(f"{where}: sets {knob} for {exe}, and no "
                                     f"staged ELF named {exe} exists under {SHARE}")
                        continue
                    blind = [p for p in paths if not carries(p, knob)]
                    if blind:
                        fails.append(
                            f"{where}: sets {knob} for {exe}, which carries no "
                            f"such string ({', '.join(blind)})")

            for knob in exports:
                examined += 1
                if knob in os.environ:
                    matched.append(knob)
                elif env_only:
                    continue
                if not any(carries(p, knob) for p in ours):
                    fails.append(
                        f"{where}: exports {knob} into init's environment and no "
                        "artifact this repo builds carries that string")

    if not examined:
        print("no RHIZO_* setenv or export was found in any .rc the launcher "
              "writes", file=sys.stderr)
        return 1
    for line in fails:
        print(f"FAIL: {line}", file=sys.stderr)
    if fails:
        return 1
    if env_only:
        if matched:
            print("knobs set here that reach a binary reading them: "
                  + ", ".join(sorted(set(matched))))
        return 0
    print("every RHIZO_* knob the launcher can render reaches a staged binary "
          f"that reads it ({examined} checked)")
    return 0


FIXTURE_LAUNCHER = '''\
blind_line = "    setenv RHIZO_FIXTURE_BLIND 1\\n"
open("/run/rhizo/vendor/etc/init/rhizo-fixture.rc", "w").write(
    "service vendor.rhizo-fixture /vendor/bin/hw/rhizo-fixture-hal\\n"
    "    setenv RHIZO_FIXTURE_READ 1\\n"
    f"{blind_line}"
)
open("/run/rhizo/vendor/etc/init/rhizo-fixture-export.rc", "w").write(
    "on early-init\\n"
    "    export RHIZO_FIXTURE_NOWHERE 1\\n"
)
'''
FIXTURE_WRAPPER = "tools/build/hal/hal.sh rhizo-fixture-hal vendor-hal/fixture/src/f.cpp\n"


def selftest():
    """run the check over a fixture tree"""
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "tools", "build"))
        os.makedirs(os.path.join(tmp, "src", "androidd", "guest"))
        os.makedirs(os.path.join(tmp, "var", "share", "gfx_hal"))
        with open(os.path.join(tmp, "src", "androidd", "boot.py"), "w") as f:
            f.write(FIXTURE_LAUNCHER)
        with open(os.path.join(tmp, "tools", "build", "fixture.sh"), "w") as f:
            f.write(FIXTURE_WRAPPER)
        with open(os.path.join(tmp, "var", "share", "gfx_hal", "rhizo-fixture-hal"), "wb") as f:
            f.write(b"\x7fELF" + b"\0" * 12 + b"RHIZO_FIXTURE_READ\0")
        env = dict(os.environ, RHIZO_CHECK_ROOT=tmp)
        run = subprocess.run([sys.executable, os.path.abspath(__file__)],
                             capture_output=True, text=True, env=env)
        out = run.stdout + run.stderr
        for knob, why in (("RHIZO_FIXTURE_BLIND", "a setenv knob the service's own binary cannot read"),
                          ("RHIZO_FIXTURE_NOWHERE", "an exported knob no built artifact reads")):
            if knob not in out:
                print(f"SELFTEST FAILED: {why} went unreported\n"
                      f"  the check produced:\n{out}", file=sys.stderr)
                return 1
        if "RHIZO_FIXTURE_READ" in out:
            print("SELFTEST FAILED: the knob the binary does carry was reported too"
                  f"\n  the check produced:\n{out}",
                  file=sys.stderr)
            return 1
        if run.returncode == 0:
            print(f"SELFTEST FAILED: exit 0 with defects reported\n{out}", file=sys.stderr)
            return 1
        with open(os.path.join(tmp, "var", "share", "gfx_hal", "rhizo-fixture-hal"), "wb") as f:
            f.write(b"\x7fELF" + b"\0" * 12 + b"RHIZO_FIXTURE_READ\0RHIZO_FIXTURE_BLIND\0"
                    b"RHIZO_FIXTURE_NOWHERE\0")
        run = subprocess.run([sys.executable, os.path.abspath(__file__)],
                             capture_output=True, text=True, env=env)
        if run.returncode != 0:
            print("SELFTEST FAILED: a fixture whose binary carries every knob still "
                  f"failed\n{run.stdout}{run.stderr}", file=sys.stderr)
            return 1
    print("selftest ok: reports a setenv knob the service binary cannot read and an "
          "exported knob nothing reads, stays quiet on the knobs that are carried")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--selftest" in args:
        sys.exit(selftest())
    sys.exit(check(env_only="--env" in args))
