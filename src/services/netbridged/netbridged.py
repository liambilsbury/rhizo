#!/usr/bin/env python3
import argparse
import os
import select
import signal
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from nb_common import log, monotonic  # noqa: E402
from nb_hoststate import HostStateWatcher  # noqa: E402

ALL_SERVICES = ("dhcp", "dns", "ra", "mdns", "proxy")

_stop = False


def _on_signal(_sig, _frm):
    """set the stop flag"""
    global _stop
    _stop = True


def build_service(name, cfg):
    """import and construct a service"""
    try:
        if name == "dhcp":
            from nb_dhcp import DhcpService
            return DhcpService(cfg)
        if name == "dns":
            from nb_dns import DnsService
            return DnsService(cfg)
        if name == "ra":
            from nb_ra import RaService
            return RaService(cfg)
        if name == "mdns":
            from nb_mdns import MdnsService
            return MdnsService(cfg)
        if name == "proxy":
            from nb_proxy import ProxyService
            return ProxyService(cfg)
    except Exception as e:  # noqa: BLE001
        log("NB_SERVICE_FAILED name=%s error=%s", name, e)
        return None
    log("NB_SERVICE_UNKNOWN name=%s", name)
    return None


def main():
    """run the rhizo-netbridged services"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--veth-if", default="vethrhz0")
    ap.add_argument("--veth-addr", default="192.168.100.1")
    ap.add_argument("--subnet", default="192.168.100.0/24")
    ap.add_argument("--uplink", default="ens3")
    ap.add_argument("--pool-start", default="192.168.100.50")
    ap.add_argument("--pool-end", default="192.168.100.100")
    ap.add_argument("--lease-seconds", type=int, default=600)
    ap.add_argument("--ula-prefix", default="fd00:12ab:cd34::")
    ap.add_argument("--proxy-port", type=int, default=8118)
    ap.add_argument("--proxy-connect-policy", choices=("deny-local", "any"),
                    default="deny-local",
                    help="network.proxy_connect's own value: deny-local refuses "
                         "loopback/link-local/multicast/host-address CONNECT "
                         "targets by default, any dials whatever the client asks")
    ap.add_argument("--proxy-allow", action="append", default=[], metavar="CIDR",
                    help="allow a proxy CONNECT/absolute-URI target inside this "
                         "CIDR even though deny-local would refuse it")
    ap.add_argument("--proxy-host-addr", dest="proxy_host_addrs", action="append",
                    default=[], metavar="IP",
                    help="deny this address as a proxy CONNECT target under "
                         "deny-local -- pass every address the host itself owns")
    ap.add_argument("--mdns-uplink-if", default="")
    ap.add_argument("--local-a", action="append", default=[],
                    metavar="NAME=IP",
                    help="answer NAME authoritatively and never forward it")
    ap.add_argument("--local-aaaa", action="append", default=[],
                    metavar="NAME=IPV6",
                    help="answer NAME's AAAA authoritatively and never forward it")
    ap.add_argument("--services", default=",".join(ALL_SERVICES))
    ap.add_argument("--state-dir", default="/run/rhizo-netbridged")
    ap.add_argument("--portal", default=None, metavar="IP",
                    help="seed the state-dir portal file at startup, as if "
                         "start-netfix.sh portal on IP had already run")
    cfg = ap.parse_args()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    os.makedirs(cfg.state_dir, exist_ok=True)

    if cfg.portal:
        try:
            with open(os.path.join(cfg.state_dir, "portal"), "w") as f:
                f.write(cfg.portal + "\n")
            log("NB_PORTAL_SEED ip=%s", cfg.portal)
        except OSError as e:
            log("NB_PORTAL_SEED_FAILED ip=%s error=%s", cfg.portal, e)
    else:
        # systemd can keep the RuntimeDirectory across a restart
        try:
            os.unlink(os.path.join(cfg.state_dir, "portal"))
            log("NB_PORTAL_CLEARED reason=not-seeded")
        except FileNotFoundError:
            pass
        except OSError as e:
            log("NB_PORTAL_CLEAR_FAILED error=%s", e)

    wanted = [s.strip() for s in cfg.services.split(",") if s.strip()]
    services = []
    for name in wanted:
        svc = build_service(name, cfg)
        if svc is not None and hasattr(svc, "unhealthy"):
            try:
                reason = svc.unhealthy()
            except Exception as e:  # noqa: BLE001
                reason = "unhealthy() raised: %s" % e
            if reason:
                log("NB_SERVICE_FAILED name=%s error=%s", name, reason)
                svc = None
        if svc is not None:
            services.append(svc)
            log("NB_SERVICE_UP name=%s", svc.name)
    if not services:
        log("NB_FAILED no service started")
        return 1

    def publish(state):
        """pass the host state to every service"""
        for svc in services:
            try:
                svc.on_host_state(state)
            except Exception as e:  # noqa: BLE001
                log("NB_SERVICE_ERROR name=%s where=on_host_state error=%s", svc.name, e)

    watcher = HostStateWatcher(publish)
    watcher.refresh(reason="startup")

    log("NB_READY veth=%s addr=%s services=%s",
        cfg.veth_if, cfg.veth_addr, ",".join(s.name for s in services))

    poller = select.poll()
    registered = {}

    def reregister():
        """register every service socket with the poller again"""
        for fd in list(registered):
            poller.unregister(fd)
            registered.pop(fd)
        for svc in services:
            for sock in svc.sockets():
                fd = sock.fileno()
                if fd < 0 or fd in registered:
                    continue
                poller.register(fd, select.POLLIN)
                registered[fd] = (svc, sock)

    reregister()
    generation = -1

    while not _stop:
        mono = monotonic()
        deadlines = [watcher.next_tick(mono)]
        for svc in services:
            d = svc.next_tick(mono)
            if d is not None:
                deadlines.append(d)
        wait_ms = max(0, int((min(deadlines) - mono) * 1000)) if deadlines else 1000
        wait_ms = min(wait_ms, 1000)

        try:
            events = poller.poll(wait_ms)
        except OSError as e:
            if getattr(e, "errno", None) == 4:
                continue
            raise

        for fd, _ev in events:
            entry = registered.get(fd)
            if entry is None:
                continue
            svc, sock = entry
            try:
                svc.on_readable(sock)
            except Exception as e:  # noqa: BLE001
                log("NB_SERVICE_ERROR name=%s where=on_readable error=%s", svc.name, e)

        mono = monotonic()
        watcher.tick(mono)
        for svc in services:
            d = svc.next_tick(mono)
            if d is not None and d <= mono:
                try:
                    svc.tick(mono)
                except Exception as e:  # noqa: BLE001
                    log("NB_SERVICE_ERROR name=%s where=tick error=%s", svc.name, e)

        want = {s.fileno() for svc in services for s in svc.sockets() if s.fileno() >= 0}
        if want != set(registered) or watcher.state.generation != generation:
            generation = watcher.state.generation
            reregister()

    for svc in services:
        try:
            svc.close()
        except Exception as e:  # noqa: BLE001
            log("NB_SERVICE_ERROR name=%s where=close error=%s", svc.name, e)
    log("NB_STOPPED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
