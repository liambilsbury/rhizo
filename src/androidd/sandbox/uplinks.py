import re
import subprocess

from sandbox import core
from sandbox.core import SANDBOX_ID, beside, kmsg

FWD_CHAIN = f"RHIZO-FWD-{SANDBOX_ID}"
NAT_CHAIN = f"RHIZO-NAT-{SANDBOX_ID}"
SCRIPT = "rhizo-nat-uplinks"
STATE_NAME = "uplinks"
MAX_IFS = 8
_IFNAME = re.compile(r"[A-Za-z0-9_.][A-Za-z0-9_.-]{0,14}")


def valid_ifname(name):
    """return whether this instance may NAT out of name"""
    return (bool(_IFNAME.fullmatch(name)) and name not in (".", "..", "lo")
            and not name.startswith("vethrhz"))


def default_route_ifaces(family, run=subprocess.run):
    """return the interfaces carrying a default route for a family"""
    r = run(["ip", family, "route", "show", "default"], capture_output=True, text=True)
    found = []
    for line in (r.stdout or "").splitlines():
        parts = line.split()
        for i, tok in enumerate(parts[:-1]):
            if tok == "dev" and valid_ifname(parts[i + 1]) and parts[i + 1] not in found:
                found.append(parts[i + 1])
    return found[:MAX_IFS]


def state_path():
    """return the file netbridged writes the current uplinks to"""
    return f"/run/{core.NETBRIDGED_RUNTIME_DIR}/{STATE_NAME}"


def ensure_chains(run, binary):
    """create this instance's forward and NAT chains if missing"""
    for table, chain in ((None, FWD_CHAIN), ("nat", NAT_CHAIN)):
        args = [binary] + (["-t", table] if table else [])
        if run(*args, "-S", chain, check=False).returncode != 0:
            run(*args, "-N", chain, check=False)


def fill_chains(run, binary, ifaces):
    """point the chains at ifaces alone"""
    run(binary, "-F", FWD_CHAIN, check=False)
    run(binary, "-t", "nat", "-F", NAT_CHAIN, check=False)
    run(binary, "-A", FWD_CHAIN, "-j", "DROP", check=False)
    for pos, name in enumerate(ifaces, 1):
        run(binary, "-I", FWD_CHAIN, str(pos), "-o", name, "-j", "ACCEPT", check=False)
        run(binary, "-t", "nat", "-A", NAT_CHAIN, "-o", name, "-j", "MASQUERADE", check=False)


def stale_nat_rule(rule, host_if, source):
    """return whether a rule is this instance's stale rule"""
    if len(rule) < 2 or rule[0] != "-A":
        return False
    chain, rest = rule[1], rule[2:]
    if chain == "POSTROUTING":
        if not (len(rest) >= 2 and rest[0] == "-s" and _same_net(rest[1], source)):
            return False
        tail = rest[2:]
        return ((len(tail) == 4 and tail[0] == "-o" and tail[2:] == ["-j", "MASQUERADE"])
                or tail == ["!", "-o", "vethrhz+", "-j", "MASQUERADE"])
    if chain != "FORWARD":
        return False
    if rest == ["-i", host_if, "!", "-o", "vethrhz+", "-j", "ACCEPT"]:
        return True
    if len(rest) == 6 and rest[:3] == ["-i", host_if, "-o"] and rest[4:] == ["-j", "ACCEPT"]:
        return rest[3] != host_if
    if len(rest) == 10 and rest[0] == "-i" and rest[2:4] == ["-o", host_if] and rest[8:] == ["-j", "ACCEPT"]:
        return (rest[4:7] in (["-m", "state", "--state"], ["-m", "conntrack", "--ctstate"])
                and set(rest[7].split(",")) == {"ESTABLISHED", "RELATED"} and rest[1] != host_if)
    return False


def _same_net(a, b):
    """return whether two CIDR strings name the same network"""
    import ipaddress
    try:
        return ipaddress.ip_network(a, strict=False) == ipaddress.ip_network(b, strict=False)
    except ValueError:
        return False


def unit_argv():
    """return the uplinks helper's command line"""
    return [beside(SCRIPT), str(SANDBOX_ID), state_path()]


def stop_unit(run, block=True):
    """stop a previous launch's uplinks unit"""
    units = [f"{core.NAT_UPLINKS_UNIT}.path", f"{core.NAT_UPLINKS_UNIT}.service"]
    run("systemctl", "stop", *(() if block else ("--no-block",)), *units, check=False)
    run("systemctl", "reset-failed", *units, check=False)


def start_unit(run):
    """start the path-activated rewrite of the chains"""
    run("systemd-run", f"--unit={core.NAT_UPLINKS_UNIT}", "--collect",
        f"--path-property=PathModified={state_path()}",
        "-p", "Type=oneshot",
        "-p", "TimeoutStartSec=60",
        "-p", "NoNewPrivileges=yes",
        "-p", "ProtectSystem=strict",
        "-p", "ReadWritePaths=/run",
        "-p", "CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW",
        "-p", f"StandardOutput=append:{core.NAT_UPLINKS_LOG}",
        "-p", f"StandardError=append:{core.NAT_UPLINKS_LOG}",
        *unit_argv(),
        check=True)
    # a file written before the path unit existed triggers nothing
    run("systemctl", "start", "--no-block", f"{core.NAT_UPLINKS_UNIT}.service", check=False)
    kmsg(f"RHIZO_MARKER nat_uplinks={core.NAT_UPLINKS_UNIT} path={state_path()}")


def release(host_if, sources, log=kmsg):
    """remove this instance's jumps and chains and stop its unit"""
    def run(*args, check=False):
        """run a command and return its result"""
        return subprocess.run(list(args), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    stop_unit(run, block=False)
    for binary, source in zip(("iptables", "ip6tables"), sources):
        for _ in range(4):
            if run(binary, "-D", "FORWARD", "-i", host_if, "-j", FWD_CHAIN).returncode != 0:
                break
        for _ in range(4):
            if run(binary, "-t", "nat", "-D", "POSTROUTING", "-s", source, "-j", NAT_CHAIN).returncode != 0:
                break
        for table, chain in ((None, FWD_CHAIN), ("nat", NAT_CHAIN)):
            args = [binary] + (["-t", table] if table else [])
            run(*args, "-F", chain)
            r = run(*args, "-X", chain)
            if r.returncode != 0 and "No chain" not in r.stderr and "does not exist" not in r.stderr:
                log(f"{' '.join(args)} -X {chain} -> rc={r.returncode} {r.stderr.strip()[:200]}")
    log(f"RHIZO_MARKER nat_uplinks=released chains={FWD_CHAIN},{NAT_CHAIN}")
