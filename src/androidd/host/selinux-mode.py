#!/usr/bin/env python3
"""print the SELinux mode this host would start Android in"""
import argparse, contextlib, os, sys
_here = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.dirname(_here) if os.path.basename(_here) == "host" else _here)
KEPT_ENV = "/var/lib/rhizo/host-mode-kept.env"
RUNTIME_ENV = "/var/lib/rhizo/androidd-runtime.env"


def read_env_file(path):
    """return KEY=VALUE pairs from an env file, ignoring comments"""
    env = {}
    try:
        with open(path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return env
    except OSError as e:
        sys.exit(f"rhizo-selinux-mode: cannot read {path}: {e}")
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("\"'")
    return env


def record_mode(ns, mode, path):
    """write mode to the mode file"""
    if not mode.startswith("refuse:"):
        ns.write_mode_file(mode, path=path)
        return
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    print(f"rhizo-selinux-mode: no mode recorded in {path}: {ns.refusal_text(mode[len('refuse:'):])} ({mode})",
          file=sys.stderr)


def main():
    """print or record the SELinux mode"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--env-file", default="/etc/rhizo/androidd.env")
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--is", dest="want")
    group.add_argument("--is-startable", action="store_true")
    group.add_argument("--why", action="store_true")
    group.add_argument("--mode-and-why", action="store_true")
    group.add_argument("--configured", action="store_true")
    group.add_argument("--landlock-abi", action="store_true")
    group.add_argument("--host-state", action="store_true")
    group.add_argument("--write-mode-file", action="store_true")
    a = ap.parse_args()
    file_env = read_env_file(a.env_file)
    file_env.update(read_env_file(os.environ.get("RHIZO_RUNTIME_ENV", RUNTIME_ENV)))
    file_env.update(read_env_file(os.environ.get("RHIZO_HOST_MODE_KEPT_FILE", KEPT_ENV)))
    if "RHIZO_GSI" in file_env:
        os.environ.setdefault("RHIZO_GSI", file_env["RHIZO_GSI"])
    if a.configured:
        print(os.environ.get("RHIZO_SELINUX_MODE") or file_env.get("RHIZO_SELINUX_MODE") or "namespace")
        return
    os.environ.setdefault("RHIZO_GSI", "/srv/rhizo/gsi_system")
    with contextlib.redirect_stdout(sys.stderr):
        from sandbox import selinux_ns as ns
    if a.landlock_abi:
        print(ns.landlock_abi())
        return
    if a.host_state:
        print(ns.host_policy_state())
        return
    mode = ns.selinux_mode({**file_env, **{k: v for k, v in os.environ.items() if k == "RHIZO_SELINUX_MODE"}})
    if a.write_mode_file:
        record_mode(ns, mode, os.environ.get("RHIZO_SELINUX_MODE_FILE", ns.MODE_FILE))
        return
    if a.why:
        if mode.startswith("refuse:"):
            print(ns.refusal_text(mode[len("refuse:"):]))
        return
    if a.mode_and_why:
        print(mode + ("\t" + ns.refusal_text(mode[len("refuse:"):]) if mode.startswith("refuse:") else ""))
        return
    if a.is_startable:
        if mode == "host" and not os.path.exists(ns.HOST_ENFORCE_NODE):
            print(f"host mode cannot start Android: no {ns.HOST_ENFORCE_NODE} on this boot", file=sys.stderr)
            sys.exit(1)
        sys.exit(1 if mode.startswith("refuse:") else 0)
    if a.want:
        sys.exit(0 if mode == a.want else 1)
    print(mode)


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        sys.exit(255 if e.code == 2 else e.code)
    except BaseException as e:
        print(f"rhizo-selinux-mode: {e!r}", file=sys.stderr)
        sys.exit(255)
