#!/usr/bin/env python3
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "hostfs", "hostfs.py")
HOME = "/home/fixture"

CASES = (
    ("a localized Download folder",
     'XDG_DOWNLOAD_DIR="$HOME/Téléchargements"\n', "Download", HOME + "/Téléchargements"),
    ("an absolute path", 'XDG_MUSIC_DIR="/srv/music"\n', "Music", "/srv/music"),
    ("a key the file leaves out", 'XDG_DOWNLOAD_DIR="$HOME/Téléchargements"\n', "Movies", HOME + "/Videos"),
    ("no file at all", None, "Documents", HOME + "/Documents"),
    ("a key set to $HOME alone", 'XDG_PICTURES_DIR="$HOME"\n', "Pictures", None),
    ("a comment and a quoted value", '# written by xdg-user-dirs-update\nXDG_VIDEOS_DIR="$HOME/Vidéos"\n',
     "Movies", HOME + "/Vidéos"),
)


def load(path):
    """return the hostfs module loaded from a path"""
    spec = importlib.util.spec_from_file_location("rhizo_hostfs", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def findings(tool):
    """check xdg_share_dirs() against each case"""
    bad = []
    for label, text, collection, want in CASES:
        got = dict(tool.xdg_share_dirs(HOME, text)).get(collection)
        if got != want:
            bad.append("%s: %s maps to %r, not %r" % (label, collection, got, want))
    return bad


def selftest():
    """run the cases with an English-only lookup"""
    tool = load(TOOL)
    if findings(tool):
        print("FAIL the tree's own xdg_share_dirs(): %s" % findings(tool))
        return 1
    real = tool.xdg_share_dirs
    tool.xdg_share_dirs = lambda home, text: [(c, os.path.join(home, d)) for c, _, d in tool.XDG_DEFAULTS]
    got = findings(tool)
    tool.xdg_share_dirs = real
    if not any(g.startswith("a localized Download folder") for g in got):
        print("FAIL an English-only lookup was not caught: %s" % got)
        return 1
    print("check-hostfs-xdg-dirs selftest: ok (an English-only lookup fails %d of %d cases)"
          % (len(got), len(CASES)))
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    bad = findings(load(TOOL))
    for b in bad:
        print("FAIL %s" % b)
    if bad:
        return 1
    print("hostfs.py's default shares follow the home's user-dirs.dirs: localized and absolute "
          "folders, the English default for a key left out, and none for a key set to $HOME")
    return 0


if __name__ == "__main__":
    sys.exit(main())
