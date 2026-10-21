#!/usr/bin/env python3
# the shared rule on where a tracked path sits


def outside_layout(p):
    """return whether a path is a root file or a dot-directory"""
    return "/" not in p or p.startswith(".")


def in_layout(p):
    """return whether a path is inside the approved layout's folders"""
    return not outside_layout(p)
