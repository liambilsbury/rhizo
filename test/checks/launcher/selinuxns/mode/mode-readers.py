#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
SCAN_DIRS = ("src", "debian", "archlinux", "tools")
READ_RE = re.compile(r"(/run/|RUN_MOUNT/|RUN_MOUNT\}/)rhizo-selinux-mode\b|RHIZO_SELINUX_MODE_FILE|\bMODE_FILE\b"
                     r"|[\"']/run/?[\"']\s*,\s*[\"']rhizo-selinux-mode[\"']"
                     r"|hostlock\.(recorded_mode|android_enforce_state|selinuxns_verdict|wait_for_enforce)\b")
PY_JOIN_RE = re.compile(r"join\([^()\n]*,\s*[\"']rhizo-selinux-mode[\"']\s*\)|\{[^{}\n]+\}/rhizo-selinux-mode\b")
EXEC_RE = re.compile(r"^Exec[A-Za-z]*=.*$", re.M)
UNIT_RE = re.compile(r"\.(service|socket|path|timer|mount)$|\.(service|socket|path|timer|mount)\.d/[^/]+\.conf$")


def read_text(rel, text):
    """return the part of a file a reader check reads"""
    if UNIT_RE.search(rel):
        return "\n".join(EXEC_RE.findall(re.sub(r"\\\n", " ", text)))
    return text


def reads_record(rel, text):
    """return whether a file's text reads the mode record"""
    part = read_text(rel, text)
    return bool(READ_RE.search(part) or (rel.endswith(".py") and PY_JOIN_RE.search(part)))
READERS = {
    "src/install/cli/rhizo.sh": ("helper", "configured_selinux_mode"),
    "src/install/teardown/teardown.sh": ("helper", "--configured"),
    "src/install/lib/pkg-lib.sh": ("helper", "--configured"),
    "src/androidd/host/launch-app.sh": ("helper", "--configured"),
    "src/services/appsync/appsync.py": ("helper", "--configured"),
    "src/services/rtd/rtd.py": ("refuse", "reason=selinux-mode"),
    "src/services/inputd/inputd.c": ("refuse", "reason=selinux-mode"),
    "src/services/delayd/delayd.c": ("refuse", "reason=selinux-mode"),
    "src/services/headroomd/headroomd.c": ("refuse", "reason=selinux-mode"),
    "src/services/hostfs/hostfs.py": ("refuse", "the SELinux mode is {mode}"),
    "src/services/broker/brokerd.py": ("refuse", "cannot read the SELinux mode from"),
    "src/androidd/sandbox/hostlock.py": ("refuse", "selinux-mode-unreadable"),
    "src/androidd/sandbox/selinux_ns.py": ("writer", "def write_mode_file"),
    "src/androidd/boot.py": ("writer", "selinux_ns.write_mode_file("),
    "src/androidd/host/selinux-mode.py": ("writer", "record_mode("),
}
FALLBACK_RES = (
    re.compile(r"read(ing it)? as host", re.I),
    re.compile(r'(strip\(\)|read\(\)) or "host"'),
    re.compile(r'except (FileNotFoundError|OSError)[^\n]*:\n\s*return "host"'),
    re.compile(r'\|\|\s*(m|_m|mode|_mode|[A-Za-z_]*MODE[A-Za-z_]*)=host\b'),
    re.compile(r'2>/dev/null\)" != namespace'),
    re.compile(r'\$\(cat [^)]*2>/dev/null\)"?\s*(=|==|!=)\s*"?(host|namespace)\b'),
    re.compile(r'except[^:\n]*:\s*(\n\s*)?(mode|_mode|m)\s*=\s*["\']host["\']'),
    re.compile(r'if\s*\(\s*!\s*f\s*\)\s*return\s+0\s*;'),
)
HOSTLOCK = "src/androidd/sandbox/hostlock.py"
PARSE_CASES = (("host\n", "host"), ("namespace", "namespace"), ("host\n\n", "host"), ("host \n", None),
               (" namespace\n", None), ("namespace junk\n", None), ("name space\n", None), ("host\nnamespace\n", None))
LOOSE_PARSE_RES = (
    re.compile(r"\b(m|_m|mode|PKG_BOOT_MODE)=\$\((tr -d '\[:space:\]'|printf [^|)]*\| *tr -d '\[:space:\]')"),
    re.compile(r'm=\$\(printf %s \\"\$m\\" \| tr -d'),
    re.compile(r'strcspn\(buf, " \\t\\r\\n"\)'),
    re.compile(r"mode\s*=\s*f\.read\(\)\.strip\(\)"),
)
BROKERD = "src/services/broker/brokerd.py"


def candidate_files(root):
    """return the scanned files under root"""
    if os.path.isdir(os.path.join(root, ".git")) or os.path.isfile(os.path.join(root, ".git")):
        out = subprocess.run(["git", "-C", root, "ls-files", "--", *SCAN_DIRS], capture_output=True, text=True,
                             check=True).stdout.split()
    else:
        out = []
        for d in SCAN_DIRS:
            for dirpath, _dirs, files in os.walk(os.path.join(root, d)):
                out += [os.path.relpath(os.path.join(dirpath, f), root) for f in files]
    return [f for f in out if "/tests/" not in f]


def scan_findings(root):
    """return findings for the reader table"""
    bad = []
    for rel in sorted(candidate_files(root)):
        try:
            with open(os.path.join(root, rel), encoding="utf-8") as f:
                text = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        if not reads_record(rel, text):
            continue
        if rel not in READERS:
            bad.append(f"{rel} reads the SELinux mode file and is not in the reader table")
            continue
        rule, mark = READERS[rel]
        if mark not in text:
            bad.append(f"{rel} lost its {rule} rule's mark {mark!r}")
        if rule != "writer":
            for rx in FALLBACK_RES:
                m = rx.search(text)
                if m:
                    bad.append(f"{rel} reads a mode failure as host: {m.group(0)!r}")
    for rel in READERS:
        if not os.path.exists(os.path.join(root, rel)):
            bad.append(f"the reader table lists {rel}, which is gone")
    return bad


def brokerd_findings(root):
    """return findings for brokerd's inbox_label on each record"""
    path = os.path.join(root, BROKERD)
    sys.path.insert(0, os.path.dirname(os.path.dirname(path)))
    spec = importlib.util.spec_from_file_location("_mode_readers_brokerd", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for label, text, want in (("namespace", "namespace\n", mod.INBOX_LABEL), ("host", "host\n", None),
                                  ("missing", None, "refused"), ("garbled", "permissive\n", "refused")):
            mode = os.path.join(tmp, "mode-" + label)
            if text is not None:
                with open(mode, "w") as f:
                    f.write(text)
            try:
                got = mod.inbox_label(mode)
            except mod.Refused:
                got = "refused"
            if got != want:
                bad.append(f"brokerd's inbox_label reads a {label} mode record as {got!r}, not {want!r}")
    return bad


def hostlock_findings(root):
    """return findings for hostlock on each record"""
    launcher_dir = os.path.join(root, "src", "androidd")
    code = (
        "import json, os, sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "from sandbox import hostlock as h\n"
        "mode, state, verdict, node = sys.argv[2:6]\n"
        "try:\n"
        "    rec = h.recorded_mode(mode)\n"
        "except Exception as e:\n"
        "    rec = type(e).__name__\n"
        "print(json.dumps([rec, h.android_enforce_state(mode, state, node), h.selinuxns_verdict(mode, verdict)]))\n")
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        state, verdict, node = (os.path.join(tmp, n) for n in ("android-enforce", "verdict", "host-enforce"))
        for path, text in ((state, "0\n"), (verdict, "pending\n"), (node, "1\n")):
            with open(path, "w") as f:
                f.write(text)
        for label, text, want in (("namespace", "namespace\n", ["namespace", "0", "pending"]),
                                  ("host", "host\n", ["host", "1", ""]),
                                  ("missing", None, ["ModeUnreadable", "", "refused:selinux-mode-unreadable"]),
                                  ("garbled", "permissive\n", ["ModeUnreadable", "", "refused:selinux-mode-unreadable"])):
            mode = os.path.join(tmp, "mode-" + label)
            if text is not None:
                with open(mode, "w") as f:
                    f.write(text)
            env = {**os.environ, "RHIZO_GSI": "/nonexistent-gsi-for-mode-readers"}
            r = subprocess.run([sys.executable, "-c", code, launcher_dir, mode, state, verdict, node],
                               capture_output=True, text=True, timeout=60, env=env)
            try:
                got = json.loads(r.stdout.strip().splitlines()[-1])
            except (ValueError, IndexError):
                got = f"exit {r.returncode}: {r.stderr.strip()[-200:]}"
            if got != want:
                bad.append(f"hostlock reads a {label} mode record as {got!r}, not {want!r}")
    return bad


def writer_findings(root):
    """return findings for write_mode_file replacing the record"""
    code = (
        "import json, os, sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "from sandbox import selinux_ns as ns\n"
        "path = sys.argv[2]\n"
        "seen = []\n"
        "real = os.replace\n"
        "def replace(src, dst):\n"
        "    seen.append([open(src).read(), open(dst).read(), os.path.dirname(src) == os.path.dirname(dst)])\n"
        "    real(src, dst)\n"
        "os.replace = replace\n"
        "ns.write_mode_file('namespace', path=path)\n"
        "print(json.dumps([seen, open(path).read(), sorted(os.listdir(os.path.dirname(path)))]))\n")
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "rhizo-selinux-mode")
        with open(path, "w") as f:
            f.write("host\n")
        r = subprocess.run([sys.executable, "-c", code, os.path.join(root, "src", "androidd"), path],
                           capture_output=True, text=True, timeout=60,
                           env={**os.environ, "RHIZO_GSI": "/nonexistent-gsi-for-mode-readers"})
    try:
        got = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return [f"write_mode_file could not be run: exit {r.returncode}: {r.stderr.strip()[-200:]}"]
    want = [[["namespace\n", "host\n", True]], "namespace\n", ["rhizo-selinux-mode"]]
    return [] if got == want else [f"write_mode_file is not an atomic replace of the record: {got!r}, not {want!r}"]


def load_module(path, name, runtime_dir):
    """import a reader file as a module"""
    saved = os.environ.get("XDG_RUNTIME_DIR")
    os.environ["XDG_RUNTIME_DIR"] = runtime_dir
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        if saved is None:
            os.environ.pop("XDG_RUNTIME_DIR", None)
        else:
            os.environ["XDG_RUNTIME_DIR"] = saved


def parse_findings(root):
    """return readers breaking the shared parse rule"""
    bad = []
    for rel in sorted(READERS):
        if READERS[rel][0] == "writer":
            continue
        text = open(os.path.join(root, rel)).read()
        for rx in LOOSE_PARSE_RES:
            m = rx.search(text)
            if m:
                bad.append(f"{rel} parses the mode record loosely: {m.group(0)!r}")
    with tempfile.TemporaryDirectory() as tmp:
        brokerd = load_module(os.path.join(root, BROKERD), "_mode_parse_brokerd", tmp)
        hostfs = load_module(os.path.join(root, "src/services/hostfs/hostfs.py"), "_mode_parse_hostfs", tmp)
        appsync = load_module(os.path.join(root, "src/services/appsync/appsync.py"), "_mode_parse_appsync", tmp)
        sys.path.insert(0, os.path.join(root, "src", "androidd"))
        for text, want in PARSE_CASES:
            path = os.path.join(tmp, "mode")
            with open(path, "w") as f:
                f.write(text)
            try:
                got = "namespace" if brokerd.inbox_label(path) else "host"
            except brokerd.Refused:
                got = None
            mode = hostfs.read_selinux_mode(path)
            got_hostfs = mode if mode in ("host", "namespace") else None
            os.environ["RHIZO_SELINUX_MODE_FILE"] = path
            try:
                got_appsync = appsync.read_selinux_mode()
            except RuntimeError:
                got_appsync = None
            finally:
                os.environ.pop("RHIZO_SELINUX_MODE_FILE", None)
            for reader, value in (("brokerd", got), ("rhizo-hostfs", got_hostfs), ("rhizo-appsync", got_appsync)):
                if value != want:
                    bad.append(f"{reader} reads a record holding {text!r} as {value!r}, not {want!r}")
    return bad


def check(root=ROOT):
    """return every finding"""
    return (scan_findings(root) + brokerd_findings(root) + hostlock_findings(root) + writer_findings(root)
            + parse_findings(root))


def selftest():
    """flag each mutant and pass the real tree"""
    bad = []
    cases = (
        ("an unlisted reader", "src/services/new-reader.py", None,
         'MODE = open("/run/rhizo-selinux-mode").read()\n', "is not in the reader table"),
        ("a reader without its mark", "src/androidd/host/launch-app.sh", "--configured", "--conf", "lost its helper"),
        ("a host fallback", "src/services/appsync/appsync.py", '            mode = f.read().rstrip("\\n")\n',
         '            mode = f.read().strip() or "host"\n', "reads a mode failure as host"),
        ("a reader through MODE_FILE", "src/services/new-reader.py", None,
         "from sandbox.selinux_ns import MODE_FILE\nMODE = open(MODE_FILE).read()\n", "is not in the reader table"),
        ("a reader building the path", "src/services/new-join.py", None,
         'import os\nMODE = open(os.path.join("/run", "rhizo-selinux-mode")).read()\n', "is not in the reader table"),
        ("a unit reading the record", "src/services/units/new-reader.service", None,
         "[Service]\nExecStartPre=/bin/sh -c 'test \"$(cat /run/rhizo-selinux-mode)\" = host'\n", "is not in the reader table"),
        ("a Python reader joining a variable directory", "src/services/new-var-join.py", None,
         'import os\nRUN = os.environ.get("RUN", "/run")\n'
         'MODE = open(os.path.join(RUN, "rhizo-selinux-mode")).read()\n',
         "is not in the reader table"),
        ("a Python reader formatting a variable directory", "src/services/new-fstring.py", None,
         'import os\nRUN = os.environ.get("RUN", "/run")\nMODE = open(f"{RUN}/rhizo-selinux-mode").read()\n',
         "is not in the reader table"),
        ("a unit reading the record on a continued Exec line", "src/services/units/new-continued.service", None,
         "[Service]\nExecStartPre=/bin/sh -c \\\n  'test \"$(cat /run/rhizo-selinux-mode)\" = host'\n",
         "is not in the reader table"),
        ("a drop-in reading the record", "src/services/units/androidd.service.d/new-reader.conf", None,
         "[Service]\nExecStartPre=/bin/sh -c \\\n  'cat /run/rhizo-selinux-mode'\n", "is not in the reader table"),
        ("a shell reader hiding a failed read", "src/androidd/host/launch-app.sh", "--configured",
         '--configured; [ "$(cat /run/rhizo-selinux-mode 2>/dev/null)" = namespace ]', "reads a mode failure as host"),
        ("a Python reader assigning host on a failed read", "src/services/appsync/appsync.py", '            mode = f.read().rstrip("\\n")\n',
         '            mode = f.read().strip()\n    except OSError:\n        mode = "host"\n', "reads a mode failure as host"),
        ("a C reader returning host on a failed open", "src/services/delayd/delayd.c", '\tFILE *f = fopen(path, "re");\n',
         '\tFILE *f = fopen(path, "re");\n\tif (!f) return 0;\n', "reads a mode failure as host"),
        ("hostlock reading a missing record as host", HOSTLOCK, "        raise ModeUnreadable(f\"{mode_file}: {e}\") from e\n",
         "        return \"host\"\n", "hostlock reads a missing mode record"),
        ("write_mode_file truncating in place", "src/androidd/sandbox/selinux_ns.py", "def write_mode_file(mode, path=MODE_FILE):\n",
         "def write_mode_file(mode, path=MODE_FILE):\n    os.makedirs(os.path.dirname(path), exist_ok=True)\n"
         "    with open(path, 'w') as f:\n        f.write(mode + '\\n')\n    return\n", "not an atomic replace"),
        ("a reader stripping spaces from the record", "src/services/hostfs/hostfs.py",
         '            return f.read().rstrip("\\n")\n', "            return f.read().strip()\n",
         "rhizo-hostfs reads a record holding 'host \\n'"),
        ("a shell reader deleting spaces from the record", "src/androidd/host/launch-app.sh", '    _m=$(cat "$_mf") || return 1\n',
         '    _m=$(cat "$_mf") || return 1\n    _m=$(printf \'%s\' "$_m" | tr -d \'[:space:]\')\n', "parses the mode record loosely"),
        ("brokerd reading a garbled mode as host", BROKERD,
         '    if mode not in ("host", "namespace"):\n', '    if mode not in ("host", "namespace", "permissive"):\n',
         "garbled mode record"),
    )
    for label, rel, old, new, needle in cases:
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(os.path.join(ROOT, "src", "androidd"), os.path.join(tmp, "src", "androidd"),
                            ignore=shutil.ignore_patterns("__pycache__"))
            for r in list(READERS) + ["src/services/broker/inbox_stage.py"]:
                os.makedirs(os.path.dirname(os.path.join(tmp, r)), exist_ok=True)
                shutil.copy(os.path.join(ROOT, r), os.path.join(tmp, r))
            path = os.path.join(tmp, rel)
            if old is None:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(new)
            else:
                text = open(path).read()
                if old not in text:
                    bad.append(f"the {label} mutant found no anchor {old!r}")
                    continue
                with open(path, "w") as f:
                    f.write(text.replace(old, new, 1))
            got = check(tmp)
        if not any(needle in g for g in got) or any("exit " in g or "could not be run" in g for g in got):
            bad.append(f"the {label} mutant was not flagged by name: {got}")
    with tempfile.TemporaryDirectory() as tmp:
        unit = os.path.join(tmp, "src", "services", "units", "androidd.service.d", "note.conf")
        os.makedirs(os.path.dirname(unit))
        with open(unit, "w") as f:
            f.write("# the mode helper writes /run/rhizo-selinux-mode\n[Service]\nExecStartPre=/bin/true\n")
        got = scan_findings(tmp)
        if any("note.conf" in g for g in got):
            bad.append(f"a drop-in whose comment names the record was flagged: {got}")
    real = check()
    if real:
        bad.append(f"the real tree has findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check()
    for b in bad:
        print("FAIL", b)
    print("mode-readers: ok" if not bad else "mode-readers: FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
