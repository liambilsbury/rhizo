#!/usr/bin/env python3
import configparser
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "test", "checks", "lib"))
import unit_files  # noqa: E402


def unit(name):
    """return a unit file's sections"""
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.optionxform = str
    parser.read(unit_files.unit_path(ROOT, name))
    return parser


def positive(value):
    """return whether value is a positive integer"""
    return value is not None and value.isdigit() and int(value) > 0


def main():
    """return the failures"""
    deskd, token = unit("rhizo-deskd.service"), unit("rhizo-desk-token.service")
    service, head = deskd["Service"], deskd["Unit"]
    bad = []
    if service.get("Restart") != "on-failure":
        bad.append(f"rhizo-deskd.service Restart={service.get('Restart')}: want on-failure")
    if not positive(service.get("RestartSec")):
        bad.append(f"rhizo-deskd.service RestartSec={service.get('RestartSec')}: want a positive number of seconds")
    if not (positive(head.get("StartLimitIntervalSec")) and positive(head.get("StartLimitBurst"))):
        bad.append(f"rhizo-deskd.service [Unit] StartLimitIntervalSec={head.get('StartLimitIntervalSec')} "
                   f"StartLimitBurst={head.get('StartLimitBurst')}: want both set")
    if "RuntimeDirectoryPreserve" in service:
        bad.append("rhizo-deskd.service keeps its runtime directory and token across a restart")
    if token["Unit"].get("PartOf") != "rhizo-deskd.service":
        bad.append(f"rhizo-desk-token.service PartOf={token['Unit'].get('PartOf')}: want rhizo-deskd.service")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-restart:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
