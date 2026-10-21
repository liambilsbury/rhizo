#!/usr/bin/env python3
"""What a key sequence produces under a keyboard layout."""
import ctypes
import ctypes.util
import os
import random
import sys

USAGE = """Usage: layout-expect.py <layout> [--count N] [--ascii-only] [--seq CODES]
  prints line 1: the expected text
         line 2: the evdev scancodes to inject, space separated
  --ascii-only  keep ASCII keys
  --seq         use these scancodes"""

POOL = list(range(2, 12)) + list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51))


class RuleNames(ctypes.Structure):
    _fields_ = [("rules", ctypes.c_char_p), ("model", ctypes.c_char_p),
                ("layout", ctypes.c_char_p), ("variant", ctypes.c_char_p),
                ("options", ctypes.c_char_p)]


def keymap_chars(layout):
    """return the unshifted character for each scancode"""
    libname = ctypes.util.find_library("xkbcommon")
    if not libname:
        sys.exit("layout-expect.py: libxkbcommon is not installed")
    xkb = ctypes.CDLL(libname)
    xkb.xkb_context_new.restype = ctypes.c_void_p
    xkb.xkb_keymap_new_from_names.restype = ctypes.c_void_p
    xkb.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(RuleNames), ctypes.c_int]
    xkb.xkb_state_new.restype = ctypes.c_void_p
    xkb.xkb_state_new.argtypes = [ctypes.c_void_p]
    xkb.xkb_state_key_get_utf8.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                           ctypes.c_char_p, ctypes.c_size_t]
    xkb.xkb_state_key_get_utf8.restype = ctypes.c_int

    ctx = xkb.xkb_context_new(0)
    if not ctx:
        sys.exit("layout-expect.py: xkb_context_new failed")
    names = RuleNames(None, None, layout.encode(), None, None)
    keymap = xkb.xkb_keymap_new_from_names(ctx, ctypes.byref(names), 0)
    if not keymap:
        sys.exit(f"layout-expect.py: no xkb keymap for layout '{layout}'")
    state = xkb.xkb_state_new(keymap)
    out = {}
    buf = ctypes.create_string_buffer(32)
    for code in POOL:
        n = xkb.xkb_state_key_get_utf8(state, code + 8, buf, ctypes.sizeof(buf))
        if n > 0:
            out[code] = buf.value.decode("utf-8", "replace")
    return out


def main():
    """print the layout text and scancodes"""
    args = sys.argv[1:]
    if not args:
        print(__doc__ + "\n\n" + USAGE, file=sys.stderr)
        sys.exit(2)
    layout = args[0]
    count = 6
    ascii_only = False
    fixed = None
    i = 1
    while i < len(args):
        if args[i] == "--count":
            count = int(args[i + 1]); i += 2
        elif args[i] == "--ascii-only":
            ascii_only = True; i += 1
        elif args[i] == "--seq":
            fixed = [int(c) for c in args[i + 1].split()]; i += 2
        else:
            sys.exit(f"layout-expect.py: unknown argument {args[i]}")

    chars = keymap_chars(layout)
    usable = {c: t for c, t in chars.items()
              if t and t.isprintable() and (not ascii_only or (len(t) == 1 and 0x20 < ord(t) < 0x7f))}
    if fixed is not None:
        missing = [c for c in fixed if c not in usable]
        if missing:
            sys.exit(f"layout-expect.py: layout '{layout}' gives no usable character for {missing}")
        seq = fixed
    else:
        if len(usable) < count:
            sys.exit(f"layout-expect.py: layout '{layout}' offers only {len(usable)} usable keys")
        seed = os.environ.get("RHIZO_LAYOUT_SEED")
        rng = random.Random(int(seed)) if seed else random.SystemRandom()
        seq = rng.sample(sorted(usable), count)
    print("".join(usable[c] for c in seq))
    print(" ".join(str(c) for c in seq))


if __name__ == "__main__":
    main()
