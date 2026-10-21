#!/usr/bin/env python3
"""set a policy file's [devices] dri to follow the vm's gpu"""
import configparser
import sys

FALSE_SPELLINGS = ("no", "false", "off", "0")


def is_off(value):
    """tell whether a dri value reads as false"""
    return value is not None and value.strip().lower() in FALSE_SPELLINGS


def main(mode, path):
    """apply the mode to the policy file"""
    p = configparser.ConfigParser()
    p.read(path)
    old = p.get("devices", "dri", fallback=None) if p.has_section("devices") else None
    if (mode == "off") == is_off(old):
        print("unchanged")
        return
    if mode == "off":
        if not p.has_section("devices"):
            p.add_section("devices")
        p.set("devices", "dri", "off")
    else:
        p.set("devices", "dri", "on")
    with open(path, "w") as f:
        p.write(f)
    print("changed")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
