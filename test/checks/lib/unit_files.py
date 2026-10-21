#!/usr/bin/env python3
# where the shipped systemd units live
import os
import re

UNITS_ROOT = os.path.join("src", "services")
UNIT_SUFFIXES = (".service", ".socket", ".path", ".timer", ".mount", ".target", ".tmpfiles", ".desktop")
PATH_RE = r"src/services/(?:[A-Za-z0-9_.-]+/)*?"
OWN_NAMES = ("androidd.service", "androidd@.service", "rhizo.desktop")


def installed_name(name):
    """return the name the unit file called name installs as"""
    return name if name in OWN_NAMES or name.endswith(".mount") else "rhizo-" + name


def unit_files(root, suffixes=UNIT_SUFFIXES):
    """map each installed unit name to its repo-relative path"""
    found = {}
    base = os.path.join(root, UNITS_ROOT)
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(x for x in dirs if not x.endswith(".d") and x != "__pycache__")
        for f in sorted(files):
            if f.endswith(suffixes):
                found[installed_name(f)] = os.path.relpath(os.path.join(d, f), root)
    return found


def unit_paths(root, suffixes=UNIT_SUFFIXES):
    """return the absolute paths of every unit file"""
    return [os.path.join(root, rel) for _, rel in sorted(unit_files(root, suffixes).items())]


def unit_path(root, name):
    """return the absolute path of the unit installed as name"""
    rel = unit_files(root).get(name)
    return os.path.join(root, rel) if rel else os.path.join(root, UNITS_ROOT, "units", name)


def dropin_paths(root):
    """return the absolute paths of every drop-in .conf"""
    out = []
    for d, dirs, files in os.walk(os.path.join(root, UNITS_ROOT)):
        dirs.sort()
        if d.endswith(".d"):
            out += [os.path.join(d, f) for f in sorted(files) if f.endswith(".conf")]
    return out


def is_unit_path(rel):
    """return whether a repo-relative path names a unit file under src/services"""
    return re.fullmatch(PATH_RE + r"[A-Za-z0-9_.@-]+", rel) is not None and rel.endswith(UNIT_SUFFIXES)
