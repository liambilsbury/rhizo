#!/usr/bin/env python3
import glob
import importlib.util
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("RHIZO_CHECK_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")
TOOLS = os.path.join(REPO, "src", "services")
sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
from unit_files import installed_name, unit_path, unit_paths  # noqa: E402
CHECKS = os.path.join(REPO, "test", "checks")
DROPINS = os.path.join(REPO, "debian", "dropins")

SIX_UNITS = {
    "rhizo-resync.service": {
        "require": {"NoNewPrivileges": "yes", "ProtectSystem": "strict",
                    "ProtectHome": "yes", "PrivateTmp": "yes"},
        "forbid": (),
    },
    "rhizo-resync-rearm.service": {
        "require": {"NoNewPrivileges": "yes", "ProtectSystem": "strict",
                    "ProtectHome": "yes", "PrivateTmp": "yes"},
        "forbid": (),
    },
    "rhizo-display-pool.service": {
        "require": {"NoNewPrivileges": "yes", "ProtectSystem": "strict",
                    "ProtectHome": "read-only", "PrivateTmp": "yes"},
        "forbid": (),
    },
    "rhizo-display-pool-release.service": {
        "require": {"NoNewPrivileges": "yes",
                    "ProtectHome": "read-only", "PrivateTmp": "yes"},
        "forbid": ("ProtectSystem",),
    },
    "rhizo-app-events.service": {
        "require": {"NoNewPrivileges": "yes", "ProtectSystem": "strict",
                    "ProtectHome": "yes", "PrivateTmp": "yes"},
        "forbid": (),
    },
    "rhizo-prepare.service": {
        "require": {"NoNewPrivileges": "yes", "PrivateTmp": "yes"},
        "forbid": ("ProtectSystem", "ProtectHome"),
    },
}

BROKERD_UNIT = "rhizo-brokerd@.service"
BROKERD_REQUIRE = {"NoNewPrivileges": "yes", "ProtectHome": "read-only", "PrivateTmp": "yes"}

ANDROIDD_UNIT = "androidd.service"
ANDROIDD_FORBIDDEN = ("NoNewPrivileges", "SystemCallFilter", "RestrictAddressFamilies",
                      "MemoryDenyWriteExecute", "IPAddressDeny", "IPAddressAllow")

HOSTFS_UNIT = "rhizo-hostfs.service"
HOSTFS_FORBIDDEN = ("NoNewPrivileges",)

DROPIN_ALLOWED_KEYS = {
    "ConditionPathExists", "EnvironmentFile", "ExecStart", "ExecStop",
    "ExecStopPost", "ExecStartPre", "ExecStartPost", "StandardOutput", "StandardError",
}
HARDENING_KEYS = {
    "NoNewPrivileges", "ProtectSystem", "ProtectHome", "PrivateTmp",
    "ReadWritePaths", "ReadOnlyPaths", "CapabilityBoundingSet",
    "AmbientCapabilities", "User", "Group", "IPAddressDeny", "IPAddressAllow",
    "RestrictAddressFamilies", "SystemCallFilter", "MemoryDenyWriteExecute",
    "RuntimeDirectory",
}
WANTS_ONLY_DROPINS = {"androidd-desktop-daemons.conf", "androidd-rtd.conf", "androidd-delayd.conf",
                       "androidd-headroomd.conf", "androidd-btd.conf"}
PARTOF_ONLY_DROPINS = {"inputd-instance0.conf": "androidd.service"}
FOREIGN_UNIT_DROPINS = {"accounts-daemon-skel.conf": "policy/dac/new-account-home.py",
                        "user-at-prep.conf": "policy/dac/user-manager-start.py",
                        "session-scope-vt.conf": "policy/dac/console-vt.py",
                        "private-users-off.conf": "policy/access/hotplug-policy.py",
                        "avahi-daemon-policy.conf": "packaging/units/avahi-daemon-policy.py"}

CONT_RE = re.compile(r"\\\s*$")
KV_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*)=(.*)$")


def parse_unit(path):
    """parse a unit file into sections"""
    with open(path) as f:
        raw = f.read()
    lines = []
    buf = ""
    for line in raw.splitlines():
        if buf:
            line = buf + " " + line.strip()
            buf = ""
        if CONT_RE.search(line):
            buf = CONT_RE.sub("", line).rstrip()
            continue
        lines.append(line)
    sections = {}
    section = ""
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
            sections.setdefault(section, [])
            continue
        m = KV_RE.match(s)
        if not m:
            continue
        sections.setdefault(section, []).append((m.group(1), m.group(2).strip()))
    return sections


ACCUMULATING_KEYS = {"IPAddressAllow", "IPAddressDeny", "ReadWritePaths",
                     "ReadOnlyPaths", "InaccessiblePaths",
                     "RestrictAddressFamilies", "SystemCallFilter"}


def service_keys(path):
    """return the Service directives of a unit file"""
    sections = parse_unit(path)
    out = {}
    for k, v in sections.get("Service", []):
        if v == "":
            out.pop(k, None)
        elif k in ACCUMULATING_KEYS and k in out:
            out[k] = out[k] + " " + v
        else:
            out[k] = v
    return out


def check_protecthome_readwrite(fails):
    """check units for ProtectHome plus ReadWritePaths on /root"""
    for path in unit_paths(REPO, (".service",)):
        keys = service_keys(path)
        home = keys.get("ProtectHome")
        if not home or home.lower() in ("no", "false", "off", "0"):
            continue
        rw = keys.get("ReadWritePaths", "")
        for token in rw.split():
            bare = token.lstrip("-+!")
            if bare == "/root" or bare == "/home" or bare.startswith(("/root/", "/home/")):
                fails.append(
                    f"{os.path.basename(path)}: ProtectHome={home} makes {bare} read-only, and the "
                    f"ReadWritePaths= naming it does not re-open it")


def check_units(fails):
    """record each service unit missing a hardening setting"""
    all_services = unit_paths(REPO, (".service",))
    if not all_services:
        fails.append(f"no *.service file found under {TOOLS}")
        return
    by_name = {installed_name(os.path.basename(p)): p for p in all_services}

    for name, spec in SIX_UNITS.items():
        path = by_name.get(name)
        if not path:
            fails.append(f"{name}: not found under {TOOLS}")
            continue
        keys = service_keys(path)
        for want_key, want_val in spec["require"].items():
            got = keys.get(want_key)
            if got != want_val:
                fails.append(f"{name}: expected {want_key}={want_val}, got {want_key}={got!r}")
        for forbidden_key in spec["forbid"]:
            if forbidden_key in keys:
                fails.append(f"{name}: {forbidden_key}={keys[forbidden_key]!r} is present "
                             "and must not be")

    path = by_name.get(BROKERD_UNIT)
    if not path:
        fails.append(f"{BROKERD_UNIT}: not found under {TOOLS}")
    else:
        keys = service_keys(path)
        for want_key, want_val in BROKERD_REQUIRE.items():
            got = keys.get(want_key)
            if got != want_val:
                fails.append(f"{BROKERD_UNIT}: expected {want_key}={want_val}, got {want_key}={got!r}")

    path = by_name.get(ANDROIDD_UNIT)
    if not path:
        fails.append(f"{ANDROIDD_UNIT}: not found under {TOOLS}")
    else:
        keys = service_keys(path)
        for forbidden_key in ANDROIDD_FORBIDDEN:
            if forbidden_key in keys:
                fails.append(f"{ANDROIDD_UNIT}: {forbidden_key}={keys[forbidden_key]!r} is present")

    path = by_name.get(HOSTFS_UNIT)
    if not path:
        fails.append(f"{HOSTFS_UNIT}: not found under {TOOLS}")
    else:
        keys = service_keys(path)
        for forbidden_key in HOSTFS_FORBIDDEN:
            if forbidden_key in keys:
                fails.append(f"{HOSTFS_UNIT}: {forbidden_key}={keys[forbidden_key]!r} is present")


def foreign_dropins_held(holder):
    """return the drop-in paths in DROPIN_WANTS"""
    spec = importlib.util.spec_from_file_location("holder", os.path.join(CHECKS, holder))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return {rel for rel, _want, _name in getattr(mod, "DROPIN_WANTS", ())}


def check_dropin_coherence(fails):
    """record a failure for each drop-in that disagrees with its unit"""
    dropins = sorted(glob.glob(os.path.join(DROPINS, "*.conf")))
    if not dropins:
        fails.append(f"no *.conf drop-in found under {DROPINS}")
        return
    for path in dropins:
        sections = parse_unit(path)
        holder = FOREIGN_UNIT_DROPINS.get(os.path.basename(path))
        if holder:
            held = foreign_dropins_held(holder)
            if "debian/dropins/" + os.path.basename(path) not in held:
                fails.append(f"{os.path.basename(path)}: exempt as a foreign-unit drop-in, "
                             f"but {holder}'s DROPIN_WANTS ({sorted(held)}) does not hold it")
            continue
        if os.path.basename(path) in WANTS_ONLY_DROPINS:
            for section, pairs in sections.items():
                for key, _val in pairs:
                    if key != "Wants":
                        fails.append(f"{os.path.basename(path)}: sets {key}=, and "
                                     "WANTS_ONLY_DROPINS allows only Wants=")
            continue
        partof = PARTOF_ONLY_DROPINS.get(os.path.basename(path))
        if partof:
            pairs = [(k, v) for _s, kv in sections.items() for k, v in kv]
            if pairs != [("PartOf", partof)]:
                fails.append(f"{os.path.basename(path)}: sets {pairs}, and "
                             f"PARTOF_ONLY_DROPINS allows only PartOf={partof}")
            continue
        for section, pairs in sections.items():
            for key, _val in pairs:
                if key in HARDENING_KEYS:
                    fails.append(f"{os.path.basename(path)}: sets {key}=, a hardening directive")
                elif key not in DROPIN_ALLOWED_KEYS:
                    fails.append(f"{os.path.basename(path)}: sets {key}=, not a recognized path-rewrite "
                                 f"key ({sorted(DROPIN_ALLOWED_KEYS)})")


def _extract(text, start_marker, end_marker, start=0):
    """return the text between a start marker and an end marker, or None"""
    i = text.find(start_marker, start)
    if i < 0:
        return None
    j = text.find(end_marker, i)
    if j < 0:
        return None
    return text[i:j + len(end_marker)]


def check_netbridged_privilege(fails):
    """check the rhizo-netbridged systemd-run properties"""
    if not os.path.isfile(LAUNCHER):
        fails.append(f"{LAUNCHER} not found")
        return
    with open(LAUNCHER) as f:
        text = f.read()
    region = _extract(text, 'run("systemd-run", f"--unit={NETBRIDGED_UNIT}"', "check=True)")
    if not region:
        fails.append("src/androidd/boot.py: no systemd-run invocation for rhizo-netbridged "
                     "ending in check=True) found")
        return
    m = re.search(r'NETBRIDGED_USER\s*=\s*"([^"]+)"', text)
    if not m:
        fails.append("src/androidd/boot.py: no NETBRIDGED_USER = \"...\" assignment found")
    elif m.group(1) in ("root", ""):
        fails.append(f"src/androidd/boot.py: NETBRIDGED_USER is {m.group(1)!r}, want a non-root system account")
    if "User=" not in region:
        fails.append("rhizo-netbridged systemd-run: no User= property -- runs as root")
    for cap_prop in ("CapabilityBoundingSet", "AmbientCapabilities"):
        cm = re.search(cap_prop + r'=([A-Z_ ]+)"', region)
        if not cm:
            fails.append(f"rhizo-netbridged systemd-run: no {cap_prop}= property found")
            continue
        caps = set(cm.group(1).split())
        expected = {"CAP_NET_RAW", "CAP_NET_BIND_SERVICE"}
        if caps != expected:
            fails.append(f"rhizo-netbridged systemd-run: {cap_prop}={sorted(caps)}, expected exactly "
                         f"{sorted(expected)}")
    if "NoNewPrivileges=yes" not in region:
        fails.append("rhizo-netbridged systemd-run: no NoNewPrivileges=yes")
    if 'f"RuntimeDirectory={NETBRIDGED_RUNTIME_DIR}"' not in region:
        fails.append("rhizo-netbridged systemd-run: no RuntimeDirectory={NETBRIDGED_RUNTIME_DIR}")


def check_input_rules(fails):
    """check the INPUT rules in boot.py"""
    if not os.path.isfile(LAUNCHER):
        return
    with open(LAUNCHER) as f:
        text = f.read()

    for m in re.finditer(r'run\(\s*"(ip6?tables)"\s*,((?:\s*"[^"]*"\s*,?)+)', text):
        args_text = m.group(2)
        args = re.findall(r'"([^"]*)"', args_text)
        if "-P" in args or "-F" in args:
            fails.append(f"src/androidd/boot.py: {m.group(1)} call carries -P or -F "
                         f"({args})")

    input_block = _extract(text, "def _input_allow(proto, port):", '_deny_spec = ["-i", HOST_IF, "-j", "DROP"]')
    if not input_block:
        fails.append("src/androidd/boot.py: no _input_allow()/_deny_spec INPUT block found")
        return
    if "capabilities.sandbox_input_ports(" not in input_block:
        fails.append("src/androidd/boot.py: the INPUT allowlist does not come from "
                     "capabilities.sandbox_input_ports()")
    if 'add_once("iptables", None, "INPUT"' not in input_block:
        fails.append("src/androidd/boot.py: _input_allow() does not add through add_once()")
    if 'add_once("ip6tables", None, "INPUT", *spec)' not in input_block:
        fails.append("src/androidd/boot.py: _input_allow() opens a port for IPv4 only")
    est_block = _extract(text, "_est_spec = [", "for _proto, _port in capabilities.sandbox_input_ports(")
    if not est_block or "ESTABLISHED,RELATED" not in est_block or '"INPUT"' not in est_block:
        fails.append("src/androidd/boot.py: the INPUT chain has no ESTABLISHED,RELATED accept "
                     "before the allowlist")
    deny_region = _extract(text, '_deny_spec = ["-i", HOST_IF, "-j", "DROP"]',
                           'add_once("iptables", None, "INPUT", *_deny_spec)')
    if not deny_region:
        fails.append("src/androidd/boot.py: no same-interface INPUT DROP catch-all added through add_once() after "
                     "the allowlist")
    if 'add_once("ip6tables", None, "INPUT", *_deny_spec)' not in text \
            or 'add_once("ip6tables", None, "INPUT", *_est_spec)' not in text:
        fails.append("src/androidd/boot.py: the IPv6 INPUT chain lacks the same-interface DROP or the "
                     "ESTABLISHED,RELATED accept")
    check_rule_placement(text, fails)


def check_rule_placement(text, fails):
    """check iptables rules use add_once()"""
    at = text.find("def setup_veth_and_nat(")
    end = text.find("\ndef ", at + 1) if at >= 0 else -1
    body = text[at:end if end >= 0 else len(text)] if at >= 0 else None
    if not body:
        fails.append("src/androidd/boot.py: no setup_veth_and_nat() found")
        return
    for m in re.finditer(r'run\(\s*"(ip6?tables)"\s*,((?:\s*"[^"]*"\s*,?)+)', body):
        args = re.findall(r'"([^"]*)"', m.group(2))
        if "-A" in args or "-I" in args:
            fails.append("src/androidd/boot.py: setup_veth_and_nat() adds %s %s past add_once()" % (m.group(1), " ".join(args)))
    add = _extract(body, "def add_once(", "rule_add_args(chain, spec, top)")
    if not add or '"-C", chain' not in add:
        fails.append("src/androidd/boot.py: add_once() does not check -C before it adds")
    src = _extract(text, "def rule_add_args(", "\n\n")
    if not src:
        fails.append("src/androidd/boot.py: no rule_add_args() found")
        return
    ns = {}
    exec(src, ns)
    f = ns["rule_add_args"]
    plain = f("INPUT", ["-j", "DROP"])
    top = {}
    placed = [f("INPUT", ["-p", "udp"], top), f("INPUT", ["-j", "DROP"], top), f("FORWARD", ["-j", "ACCEPT"], top)]
    if plain != ["-A", "INPUT", "-j", "DROP"]:
        fails.append("src/androidd/boot.py: rule_add_args() with no ufw gives %s, not -A" % plain)
    if placed != [["-I", "INPUT", "1", "-p", "udp"], ["-I", "INPUT", "2", "-j", "DROP"], ["-I", "FORWARD", "1", "-j", "ACCEPT"]]:
        fails.append("src/androidd/boot.py: rule_add_args() behind ufw gives %s, not -I at 1, 2, ... per chain in the "
                     "order added" % placed)




def check_desk_daemons(fails):
    """check the hardening keys of the desktop units"""
    for unit, label, needed in (
        ("rhizo-deskd.service", "rhizo-deskd",
         {"NoNewPrivileges": "yes", "IPAddressDeny": "any",
          "IPAddressAllow": "192.168.100.0/24"}),
        ("rhizo-audiod.service", "rhizo-audiod",
         {"NoNewPrivileges": "yes", "RestrictAddressFamilies": "AF_UNIX"}),
        ("rhizo-keymapd.service", "rhizo-keymapd", {"NoNewPrivileges": "yes"}),
        ("rhizo-displayd.service", "rhizo-displayd", {"NoNewPrivileges": "yes"}),
    ):
        path = unit_path(REPO, unit)
        if not os.path.isfile(path):
            fails.append(f"{path} not found")
            continue
        keys = service_keys(path)
        for key, want in needed.items():
            got = keys.get(key)
            if got != want:
                fails.append(f"{unit}: {label} is missing {key}={want!r} "
                             f"(got {got!r})")


def check(_argv=None):
    """return the failures from every hardening check"""
    fails = []
    check_netbridged_privilege(fails)
    check_input_rules(fails)
    check_units(fails)
    check_protecthome_readwrite(fails)
    check_dropin_coherence(fails)
    check_desk_daemons(fails)
    for line in fails:
        print(f"FAIL: {line}", file=sys.stderr)
    if fails:
        return 1
    print("netbridged runs unprivileged with exactly its two proven capabilities, "
          "the INPUT chain confines the sandbox to what the host actually serves, "
          "and every unit carries its required hardening with androidd.service "
          "and rhizo-hostfs.service correctly exempted")
    return 0


GOOD_LAUNCHER = '''
def rule_add_args(chain, spec, top=None):
    if top is None:
        return ["-A", chain, *spec]
    pos = top.get(chain, 1)
    top[chain] = pos + 1
    return ["-I", chain, str(pos), *spec]


def setup_veth_and_nat():
    HOST_IF = "vethrhz0"
    NETBRIDGED_USER = "rhizo-netbridged"
    NETBRIDGED_EXTRA_ARGS = []
    def run(*a, **k):
        class R: returncode = 1
        return R()
    tops = {"iptables": None, "ip6tables": None}
    def add_once(binary, table, chain, *spec):
        args = [binary] + (["-t", table] if table else [])
        top = tops[binary] if table is None else None
        if run(*args, "-C", chain, *spec, check=False).returncode != 0:
            run(*args, *rule_add_args(chain, spec, top), check=False)
        elif top is not None:
            rule_add_args(chain, spec, top)
    run("sysctl","-w","net.ipv4.ip_forward=1")
    add_once("iptables","nat","POSTROUTING","-s","x","-o","y","-j","MASQUERADE")
    add_once("iptables",None,"FORWARD","-i",HOST_IF,"-o","y","-j","ACCEPT")
    PROXY_PORT = 8118
    DESKD_PORT = 47100
    def _input_allow(proto, port):
        spec = ["-i", HOST_IF, "-p", proto, "--dport", str(port), "-j", "ACCEPT"]
        add_once("iptables", None, "INPUT", *spec)
        add_once("ip6tables", None, "INPUT", *spec)
    _est_spec = ["-i", HOST_IF, "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT"]
    add_once("iptables", None, "INPUT", *_est_spec)
    add_once("ip6tables", None, "INPUT", *_est_spec)
    for _proto, _port in capabilities.sandbox_input_ports(
            NB_SERVICES, PROXY_PORT, DESKD_PORT):
        _input_allow(_proto, _port)
    _deny_spec = ["-i", HOST_IF, "-j", "DROP"]
    add_once("iptables", None, "INPUT", *_deny_spec)
    add_once("ip6tables", None, "INPUT", *_deny_spec)
    run("systemd-run", f"--unit={NETBRIDGED_UNIT}", "--collect",
        "-p", f"RuntimeDirectory={NETBRIDGED_RUNTIME_DIR}",
        "-p", f"User={NETBRIDGED_USER}",
        "-p", "CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE",
        "-p", "AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE",
        "-p", "NoNewPrivileges=yes",
        "-p", "StandardOutput=file:/tmp/x",
        "python3", "x",
        *NETBRIDGED_EXTRA_ARGS,
        check=True)
'''

BAD_LAUNCHER_ROOT = GOOD_LAUNCHER.replace('NETBRIDGED_USER = "rhizo-netbridged"', 'NETBRIDGED_USER = "root"')
BAD_LAUNCHER_FLUSH = GOOD_LAUNCHER.replace(
    'add_once("iptables",None,"FORWARD","-i",HOST_IF,"-o","y","-j","ACCEPT")',
    'add_once("iptables",None,"FORWARD","-i",HOST_IF,"-o","y","-j","ACCEPT")\n'
    '    run("iptables", "-F", check=False)')
BAD_LAUNCHER_V4_ONLY = GOOD_LAUNCHER.replace(
    '        add_once("ip6tables", None, "INPUT", *spec)\n', "").replace(
    '    add_once("ip6tables", None, "INPUT", *_deny_spec)\n', "")
BAD_LAUNCHER_NO_EST = GOOD_LAUNCHER.replace(
    '    _est_spec = ["-i", HOST_IF, "-m", "state", "--state", "ESTABLISHED,RELATED", "-j", "ACCEPT"]\n'
    '    add_once("iptables", None, "INPUT", *_est_spec)\n', "")
BAD_LAUNCHER_BYPASS = GOOD_LAUNCHER.replace(
    '    add_once("iptables", None, "INPUT", *_deny_spec)\n',
    '    add_once("iptables", None, "INPUT", *_deny_spec)\n    run("iptables", "-A", "INPUT", "-j", "DROP", check=False)\n')
BAD_LAUNCHER_APPENDS = GOOD_LAUNCHER.replace('    return ["-I", chain, str(pos), *spec]\n',
                                             '    return ["-A", chain, *spec]\n')
BAD_LAUNCHER_NO_CHECK = GOOD_LAUNCHER.replace(
    '        if run(*args, "-C", chain, *spec, check=False).returncode != 0:\n'
    '            run(*args, *rule_add_args(chain, spec, top), check=False)\n'
    '        elif top is not None:\n'
    '            rule_add_args(chain, spec, top)\n',
    '        run(*args, *rule_add_args(chain, spec, top), check=False)\n')

GOOD_SERVICE = {
    "rhizo-resync.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\n",
    "rhizo-resync-rearm.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\n",
    "rhizo-display-pool.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=read-only\nPrivateTmp=yes\n",
    "rhizo-display-pool-release.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectHome=read-only\nPrivateTmp=yes\n",
    "rhizo-app-events.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\nPrivateTmp=yes\n",
    "rhizo-prepare.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nPrivateTmp=yes\nReadWritePaths=/var/lib/rhizo /srv/rhizo /root\n",
    "rhizo-brokerd@.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectHome=read-only\nPrivateTmp=yes\n",
    "androidd.service": "[Service]\nExecStart=/bin/true\nDelegate=yes\n",
    "rhizo-hostfs.service": "[Service]\nExecStart=/bin/true\nType=oneshot\n",
}

GOOD_DROPIN = "[Service]\nExecStart=\nExecStart=/usr/lib/rhizo/x.sh\n"
GOOD_DESKD_SERVICE = ("[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"
                     "IPAddressDeny=any\nIPAddressAllow=192.168.100.0/24\n")
GOOD_AUDIOD_SERVICE = ("[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"
                      "RestrictAddressFamilies=AF_UNIX\n")
GOOD_KEYMAPD_SERVICE = "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"
GOOD_DISPLAYD_SERVICE = "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"
GOOD_DESK_UNITS = {
    "rhizo-deskd.service": GOOD_DESKD_SERVICE,
    "rhizo-audiod.service": GOOD_AUDIOD_SERVICE,
    "rhizo-keymapd.service": GOOD_KEYMAPD_SERVICE,
    "rhizo-displayd.service": GOOD_DISPLAYD_SERVICE,
}
BAD_DESKD_NO_ALLOW = "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nIPAddressDeny=any\n"
GOOD_KEYMAPD_SH = 'systemd-run --unit=rhizo-keymapd --collect \\\n  -p NoNewPrivileges=yes \\\n  /usr/local/bin/rhizo-keymapd >/dev/null 2>&1\n'
GOOD_DISPLAYD_SH = 'systemd-run --unit=rhizo-displayd --collect \\\n  -p NoNewPrivileges=yes \\\n  /usr/local/bin/rhizo-displayd >/dev/null 2>&1\n'


def _write_fixture(root, launcher_text, services, dropins, desk_units=None):
    """write a fixture tree"""
    os.makedirs(os.path.join(root, "src", "services", "units"), exist_ok=True)
    os.makedirs(os.path.join(root, "src", "androidd"), exist_ok=True)
    os.makedirs(os.path.join(root, "test", "checks"), exist_ok=True)
    os.makedirs(os.path.join(root, "debian", "dropins"), exist_ok=True)
    with open(os.path.join(root, "src", "androidd", "boot.py"), "w") as f:
        f.write(launcher_text)
    for name, content in services.items():
        where = ("test", "checks") if name.endswith(".py") else ("src", "services", "units")
        name = name if name.endswith(".py") else _source_name(name)
        os.makedirs(os.path.dirname(os.path.join(root, *where, name)), exist_ok=True)
        with open(os.path.join(root, *where, name), "w") as f:
            f.write(content)
    for name, content in dropins.items():
        with open(os.path.join(root, "debian", "dropins", name), "w") as f:
            f.write(content)
    for name, content in (desk_units or GOOD_DESK_UNITS).items():
        with open(os.path.join(root, "src", "services", "units", _source_name(name)), "w") as f:
            f.write(content)


def _source_name(name):
    """return the source file name of the unit installed as name"""
    return name[len("rhizo-"):] if name.startswith("rhizo-") else name


def _run_checker(root):
    """run this checker on a root and return its exit code and output"""
    env = dict(os.environ, RHIZO_CHECK_ROOT=root)
    r = subprocess.run([sys.executable, os.path.abspath(__file__)], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


def selftest():
    """run the checker on each fixture"""
    good_dropins = {"x-packaged-paths.conf": GOOD_DROPIN}
    cases = [
        ("clean fixture", GOOD_LAUNCHER, GOOD_SERVICE, good_dropins, None, True, None),
        ("netbridged runs as root", BAD_LAUNCHER_ROOT, GOOD_SERVICE, good_dropins, None, False, "root"),
        ("iptables -F present", BAD_LAUNCHER_FLUSH, GOOD_SERVICE, good_dropins, None, False, "-P or -F"),
        ("an iptables add past add_once()", BAD_LAUNCHER_BYPASS, GOOD_SERVICE, good_dropins, None, False,
         "past add_once()"),
        ("rules still append behind ufw", BAD_LAUNCHER_APPENDS, GOOD_SERVICE, good_dropins, None, False,
         "behind ufw"),
        ("add_once() adds with no -C", BAD_LAUNCHER_NO_CHECK, GOOD_SERVICE, good_dropins, None, False,
         "does not check -C"),
        ("INPUT lacks ESTABLISHED,RELATED", BAD_LAUNCHER_NO_EST, GOOD_SERVICE, good_dropins, None,
         False, "ESTABLISHED,RELATED"),
        ("the INPUT allowlist is IPv4 only", BAD_LAUNCHER_V4_ONLY, GOOD_SERVICE, good_dropins, None,
         False, "IPv4 only"),
        ("androidd.service gains NoNewPrivileges", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "androidd.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"},
         good_dropins, None, False, "androidd.service"),
        ("rhizo-hostfs.service gains NoNewPrivileges", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "rhizo-hostfs.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"},
         good_dropins, None, False, "rhizo-hostfs.service"),
        ("a no-privilege unit missing PrivateTmp", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "rhizo-resync.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nProtectSystem=strict\nProtectHome=yes\n"},
         good_dropins, None, False, "PrivateTmp"),
        ("drop-in sets a hardening key", GOOD_LAUNCHER, GOOD_SERVICE,
         {"x-packaged-paths.conf": "[Service]\nExecStart=/x\nNoNewPrivileges=no\n"}, None,
         False, "hardening directive"),
        ("the Wants=-only drop-in sets a hardening key", GOOD_LAUNCHER, GOOD_SERVICE,
         {**{"x-packaged-paths.conf": GOOD_DROPIN},
          "androidd-desktop-daemons.conf": "[Unit]\nWants=rhizo-deskd.service\n[Service]\nUser=root\n"},
         None, False, "WANTS_ONLY_DROPINS"),
        ("the PartOf=-only drop-in names the unit", GOOD_LAUNCHER, GOOD_SERVICE,
         {**good_dropins, "inputd-instance0.conf": "[Unit]\nPartOf=androidd.service\n"},
         None, True, None),
        ("the PartOf=-only drop-in names another unit", GOOD_LAUNCHER, GOOD_SERVICE,
         {**good_dropins, "inputd-instance0.conf": "[Unit]\nPartOf=rhizo-hostfs.service\n"},
         None, False, "PARTOF_ONLY_DROPINS"),
        ("the PartOf=-only drop-in also sets User=", GOOD_LAUNCHER, GOOD_SERVICE,
         {**good_dropins, "inputd-instance0.conf": "[Unit]\nPartOf=androidd.service\n[Service]\nUser=root\n"},
         None, False, "PARTOF_ONLY_DROPINS"),
        ("ProtectHome plus a ReadWritePaths on /root", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "rhizo-resync.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectSystem=strict\nProtectHome=yes\nReadWritePaths=/var/lib/rhizo /root\n"},
         good_dropins, None, False, "does not re-open it"),
        ("ProtectHome with no /root ReadWritePath is fine", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "rhizo-resync.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectSystem=strict\nProtectHome=yes\nReadWritePaths=/var/lib/rhizo\n"},
         good_dropins, None, True, None),
        ("deskd missing IPAddressDeny", GOOD_LAUNCHER, GOOD_SERVICE, good_dropins,
         {**GOOD_DESK_UNITS, "rhizo-deskd.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nIPAddressAllow=192.168.100.0/24\n"},
         False, "IPAddressDeny"),
        ("deskd has IPAddressDeny=any but no IPAddressAllow at all", GOOD_LAUNCHER, GOOD_SERVICE, good_dropins,
         {**GOOD_DESK_UNITS, "rhizo-deskd.service": BAD_DESKD_NO_ALLOW}, False, "IPAddressAllow"),
        ("audiod missing RestrictAddressFamilies", GOOD_LAUNCHER, GOOD_SERVICE, good_dropins,
         {**GOOD_DESK_UNITS, "rhizo-audiod.service": "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\n"},
         False, "RestrictAddressFamilies"),
        ("keymapd missing NoNewPrivileges", GOOD_LAUNCHER, GOOD_SERVICE, good_dropins,
         {**GOOD_DESK_UNITS, "rhizo-keymapd.service": "[Service]\nExecStart=/bin/true\n"},
         False, "rhizo-keymapd.service: rhizo-keymapd is missing"),
        ("deskd IPAddressAllow=any then =192.168.100.0/24 (accumulates, must fail)",
         GOOD_LAUNCHER, GOOD_SERVICE, good_dropins,
         {**GOOD_DESK_UNITS, "rhizo-deskd.service":
          "[Service]\nExecStart=/bin/true\nNoNewPrivileges=yes\nIPAddressDeny=any\n"
          "IPAddressAllow=any\nIPAddressAllow=192.168.100.0/24\n"},
         False, "IPAddressAllow"),
        ("a foreign-unit drop-in its holder's DROPIN_WANTS leaves out", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "policy/dac/new-account-home.py":
          "# debian/dropins/accounts-daemon-skel.conf\nDROPIN_WANTS = ()\n"},
         {**good_dropins, "accounts-daemon-skel.conf": "[Service]\nProtectHome=no\n"},
         None, False, "does not hold it"),
        ("a foreign-unit drop-in its holder's DROPIN_WANTS holds", GOOD_LAUNCHER,
         {**GOOD_SERVICE, "policy/dac/new-account-home.py":
          "DROPIN_WANTS = (('debian/dropins/accounts-daemon-skel.conf', None, 'x'),)\n"},
         {**good_dropins, "accounts-daemon-skel.conf": "[Service]\nTemporaryFileSystem=/etc/skel:ro\n"},
         None, True, None),
    ]
    for name, launcher_text, services, dropins, desk_units, want_pass, must_mention in cases:
        with tempfile.TemporaryDirectory() as tmp:
            _write_fixture(tmp, launcher_text, services, dropins, desk_units)
            rc, out = _run_checker(tmp)
            if want_pass:
                if rc != 0:
                    print(f"SELFTEST FAILED: {name!r} should have passed, but the checker said:\n{out}",
                         file=sys.stderr)
                    return 1
            else:
                if rc == 0:
                    print(f"SELFTEST FAILED: {name!r} should have failed, but the checker exited 0",
                         file=sys.stderr)
                    return 1
                if must_mention and must_mention not in out:
                    print(f"SELFTEST FAILED: {name!r} failed for the wrong reason -- expected {must_mention!r} "
                         f"in the output:\n{out}", file=sys.stderr)
                    return 1
    print(f"selftest ok: {len(cases)} fixtures, each failing (or passing) for the specific reason checked")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(check(sys.argv[1:]))
