#!/usr/bin/env python3
import glob
import os
import re
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402
SANDBOX_KEYS = ("ReadWritePaths", "ReadOnlyPaths", "InaccessiblePaths", "ExecPaths", "NoExecPaths",
                "BindPaths", "BindReadOnlyPaths")
DIRECTORY_KEYS = {"RuntimeDirectory": "/run", "StateDirectory": "/var/lib", "CacheDirectory": "/var/cache",
                  "LogsDirectory": "/var/log", "ConfigurationDirectory": "/etc"}
VOLATILE = ("/run", "/var/run", "/tmp", "/dev/shm")
BASE_DIRS = {
    "/root": "root's home, made by the base system",
    "/lib/modules": "the installed kernels' module trees",
    "/etc/modules-load.d": "the distro's modules-load.d",
}
TMPFILES_CREATE_TYPES = ("d", "D", "v", "q", "Q")


def unit_texts(root):
    """return each unit and drop-in's text"""
    out = {}
    for path in unit_files.unit_paths(root, (".service",)) + sorted(glob.glob(os.path.join(root, "debian/dropins/*.conf"))):
        out[os.path.relpath(path, root)] = open(path).read()
    return out


def directives(text):
    """return each directive's key and value"""
    pairs, buf = [], ""
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.lstrip().startswith(("#", ";")):
            continue
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        line, buf = buf + line, ""
        m = re.match(r"^\s*([A-Za-z]+)\s*=(.*)$", line)
        if m:
            pairs.append((m.group(1), m.group(2).strip()))
    return pairs


def values(pairs, key):
    """return a key's whitespace-split values"""
    return [v for k, raw in pairs if k == key for v in raw.split()]


def made_directories(pairs):
    """return the directories of a unit's *Directory= settings"""
    made = set()
    for key, base in DIRECTORY_KEYS.items():
        for v in values(pairs, key):
            made.add(os.path.join(base, v.split(":", 1)[0]))
    return made


def shipped_tmpfiles(root):
    """return each shipped tmpfiles.d file's created paths"""
    rules = open(os.path.join(root, "debian", "rules")).read()
    shipped = {}
    for src, name in re.findall(r"install -D -m 0644 (\S+\.tmpfiles)\s*\\?\s*\n?\s*\S*/usr/lib/tmpfiles\.d/(\S+\.conf)",
                                rules):
        made = set()
        for line in open(os.path.join(root, src)).read().splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[0].rstrip("!-=+") in TMPFILES_CREATE_TYPES:
                made.add(fields[1])
        shipped[name] = made
    return shipped


def install_made(lib):
    """return pkg_state_dirs's directories"""
    body = re.search(r"^pkg_state_dirs\(\) \{\n(.*?)^\}", lib, re.S | re.M)
    if not body:
        return set()
    return {p for line in body.group(1).splitlines() if line.strip().startswith("mkdir -p")
            for p in line.split()[2:] if p.startswith("/")}


def sandbox_paths(pairs):
    """return (key, path) for each required path"""
    out = []
    for key in SANDBOX_KEYS:
        for v in values(pairs, key):
            if v.startswith("-"):
                continue
            path = v.lstrip("+")
            if key.startswith("Bind"):
                path = path.split(":", 1)[0]
            out.append((key, path))
    return out


def volatile(path):
    """test for a path under a boot-cleared tree"""
    return any(path == v or path.startswith(v + "/") for v in VOLATILE)


def findings(root=ROOT):
    """return (ok lines, findings) for every unit"""
    units = unit_texts(root)
    parsed = {name: directives(text) for name, text in units.items()}
    by_unit = {os.path.basename(n): p for n, p in parsed.items() if n.endswith(".service")}
    tmpfiles = shipped_tmpfiles(root)
    lib = open(os.path.join(root, "src", "install", "lib", "pkg-lib.sh")).read()
    created_at_install = {name for name in tmpfiles
                          if re.search(r"systemd-tmpfiles --create (\S+ )*" + re.escape(name) + r"\b", lib)}
    persistent = install_made(lib)
    oks, bad = [], []
    for name, pairs in sorted(parsed.items()):
        required = set(values(pairs, "Requires")) | set(values(pairs, "BindsTo"))
        ordered = required & set(values(pairs, "After"))
        own = made_directories(pairs)
        for key, path in sandbox_paths(pairs):
            what = f"{name}: {key}={path}"
            boot = sorted(t for t, made in tmpfiles.items() if path in made)
            pred = sorted(u for u in ordered if path in made_directories(by_unit.get(u, [])))
            if path in own:
                oks.append(f"{what}: the unit's own directory setting makes it")
            elif boot and boot[0] in created_at_install:
                oks.append(f"{what}: tmpfiles.d/{boot[0]} makes it at boot and the configure step at install")
            elif boot:
                bad.append(f"{what} comes from tmpfiles.d/{boot[0]} at boot, but the configure step never runs "
                           f"systemd-tmpfiles --create {boot[0]}")
            elif pred:
                oks.append(f"{what}: {pred[0]}, which it requires and orders after, makes it")
            elif volatile(path) and path in persistent:
                bad.append(f"{what} is under a tree cleared at boot and only pkg_state_dirs makes it")
            elif not volatile(path) and path in persistent:
                oks.append(f"{what}: pkg_state_dirs makes it at install and it persists")
            elif not volatile(path) and path in BASE_DIRS:
                oks.append(f"{what}: {BASE_DIRS[path]}")
            else:
                bad.append(f"{what} is made by nothing that runs before the unit: no shipped tmpfiles.d entry, no "
                           f"directory setting of the unit or of a predecessor it requires and orders after, no "
                           f"install-time directory")
    return oks, bad


RULES = """binary:
\tinstall -D -m 0644 src/services/units/rhizo-x.tmpfiles \\
\t                   debian/rhizo/usr/lib/tmpfiles.d/rhizo-x.conf
"""
LIB = """pkg_state_dirs() {
  mkdir -p /etc/rhizo /var/lib/rhizo %s
}

pkg_user_units_and_desktop() {
  %s
}
"""


def fixture(tmp, units, tmpfiles="d /run/rhizo-x 0755 root root -\n", create=True, state=""):
    """write a tree with the given units"""
    for sub in ("src/services/units", "debian/dropins", "src/install/lib"):
        os.makedirs(os.path.join(tmp, sub), exist_ok=True)
    for name, text in units.items():
        with open(os.path.join(tmp, "src", "services", "units", name), "w") as f:
            f.write(text)
    with open(os.path.join(tmp, "debian", "rules"), "w") as f:
        f.write(RULES)
    with open(os.path.join(tmp, "src", "services", "units", "rhizo-x.tmpfiles"), "w") as f:
        f.write(tmpfiles)
    with open(os.path.join(tmp, "src", "install", "lib", "pkg-lib.sh"), "w") as f:
        f.write(LIB % (state, "systemd-tmpfiles --create rhizo-x.conf" if create else ":"))


def selftest():
    """run the check on each fixture case"""
    unit = "[Unit]\nAfter=%s\n%s\n[Service]\nProtectSystem=strict\n%s\n"
    cases = (
        ("a run path no tmpfiles entry makes", {"a.service": unit % ("", "", "ReadWritePaths=/run/rhizo-y")},
         {}, "ReadWritePaths=/run/rhizo-y is made by nothing"),
        ("a run path a shipped entry makes", {"a.service": unit % ("", "", "ReadWritePaths=/run/rhizo-x")},
         {}, None),
        ("an entry the configure step never creates", {"a.service": unit % ("", "", "ReadWritePaths=/run/rhizo-x")},
         {"create": False}, "never runs systemd-tmpfiles --create rhizo-x.conf"),
        ("the unit's own RuntimeDirectory", {"a.service": unit % ("", "", "RuntimeDirectory=rhizo-z\n"
                                                                    "ReadWritePaths=/run/rhizo-z")}, {}, None),
        ("a predecessor it requires and orders after",
         {"a.service": unit % ("b.service", "Requires=b.service", "ReadWritePaths=/run/rhizo-z"),
          "b.service": "[Service]\nRuntimeDirectory=rhizo-z\n"}, {}, None),
        ("a predecessor with no Requires=",
         {"a.service": unit % ("b.service", "Wants=b.service", "ReadWritePaths=/run/rhizo-z"),
          "b.service": "[Service]\nRuntimeDirectory=rhizo-z\n"}, {}, "ReadWritePaths=/run/rhizo-z is made by nothing"),
        ("an optional path", {"a.service": unit % ("", "", "ReadWritePaths=-/run/rhizo-y")}, {}, None),
        ("a bind source", {"a.service": unit % ("", "", "BindPaths=/run/rhizo-y:/x")}, {},
         "BindPaths=/run/rhizo-y is made by nothing"),
        ("a persistent install directory", {"a.service": unit % ("", "", "ReadWritePaths=/var/lib/rhizo")}, {}, None),
        ("a volatile path the install makes", {"a.service": unit % ("", "", "ReadWritePaths=/run/rhizo-y")},
         {"state": "/run/rhizo-y"}, "is under a tree cleared at boot"),
        ("an unprovided persistent path", {"a.service": unit % ("", "", "ReadOnlyPaths=/srv/other")}, {},
         "ReadOnlyPaths=/srv/other is made by nothing"),
        ("a base-system directory", {"a.service": unit % ("", "", "ReadWritePaths=/root")}, {}, None),
    )
    failed = []
    for label, units, kwargs, want in cases:
        with tempfile.TemporaryDirectory() as tmp:
            fixture(tmp, units, **kwargs)
            _oks, bad = findings(tmp)
        hit = [b for b in bad if want and want in b]
        if want and not hit:
            failed.append(f"{label}: not flagged ({bad})")
        if not want and bad:
            failed.append(f"{label}: flagged {bad}")
    for f in failed:
        print("FAIL", f)
    print("unit-sandbox-paths: selftest", "FAIL" if failed else "ok")
    return 1 if failed else 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    oks, bad = findings()
    for line in oks:
        print("ok:", line)
    for line in bad:
        print("FAIL:", line)
    print("unit-sandbox-paths:", "FAIL" if bad else "ok")
    sys.exit(1 if bad else 0)
